// include/strata/program/kv_export.hpp - kv-export: the engine's side of moving a conversation between hosts
// (header-only: generate.cpp is its one user, and its templates take generate.cpp's own types).
//
// Four commands on the engine's stdin, between requests, beside SAVE and RESTORE (KV-EXPORT.md documents them, the
// session files and the delta files; all of it is a contract, byte for byte):
//
// IMPORT <path> reads a session file like RESTORE but parks it in the conversation cache
// instead of replacing the live session, so a conversation replicated from another host waits for its
// next turn without evicting this host's own, and the request path restores it as any parked one
// (batch slots included).  Answers IMPORTED <tokens> <bytes> <ms>, or SERR as RESTORE does.
//
// SAVEC <slot|-1> <n> <hash> <path> saves one conversation by where it is: batch slot <slot>
// (idle, still holding it) or the live session (-1), only if its first <n> tokens hash (FNV-1a 64 over
// the int32 ids, 16 hex digits) to <hash> - the server names the conversation by the prompt it sent, so
// a slot another conversation took meanwhile is refused instead of saved under the wrong name.
//
// SAVEX <slot|-1> <n> <hash> <base> <path> is SAVEC that also remembers what it wrote and, given
// the id of an earlier SAVEX of the same conversation (<base>, 16 hex digits; 0: none), writes a delta file
// (STRSDLT) against it when it can.  Answers SAVEDX <tokens> <bytes> <ms> <id> <base|0>.
//
// HELD <n> <hash> asks whether the engine still holds a conversation whose first <n> tokens
// hash to <hash>, named as SAVEC names one: the live session, a batch slot (idle or decoding) or a parked
// conversation.  Answers HELD <tokens>, the longest such conversation's length (0: none).  Read only:
// nothing is moved, saved or touched, so a node can ask before every turn whether an IMPORT is needed.
//
// This header holds what stands on its own: the parsing and the answers, the HELD lookup, picking a batch slot as a
// save's source, the save of a parked conversation, the IMPORT's parking, and the lineage store that lets a SAVEX
// write a delta.  What is woven into upstream's SAVE / RESTORE handler in generate.cpp stays there, each piece marked
// "kv-export": the save reading its source instead of the live session, the deepest checkpoint going into the file by
// reference, the save's timing breakdown, and the refusals --batch no longer applies to SAVEC / IMPORT.
#pragma once

#include "strata/core/conversation_cache.hpp"
#include "strata/core/conversation_file.hpp"
#include "strata/kernels/qsa.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <iterator>
#include <new>
#include <optional>
#include <random>
#include <string>
#include <utility>
#include <vector>

namespace strata::core {
struct SessionState;   // session.hpp
struct QsaState;       // layer.hpp
}

namespace strata::program::kv_export {

// ---- parsing ---------------------------------------------------------------------------------------------------

// SAVEC / SAVEX: where the conversation is (a batch slot, or -1: the live session), how it is named (the FNV-1a 64 of
// its first <n> token ids, session_ids_fnv1a64) and, for SAVEX, the id of the earlier save a delta may be written
// against (0: none)
struct SaveCommand {
    long long slot = -1, n = 0;
    unsigned long long hash = 0, base = 0;
};

// the conversation <ids> is the one named: its first <n> tokens hash to <hash>
inline bool names(long long n, unsigned long long hash, const std::vector<int32_t>& ids) {
    return n > 0 && (size_t) n <= ids.size() && strata::core::session_ids_fnv1a64(ids.data(), (size_t) n) == hash;
}
inline bool names(const SaveCommand& c, const std::vector<int32_t>& ids) { return names(c.n, c.hash, ids); }

// what a save reads: the live session's tokens, pictures, checkpoints and state, or (SAVEC) an idle batch slot's
struct SaveSource {
    const std::vector<int32_t>* ids = nullptr;
    const std::vector<strata::core::ConversationImageKey>* imgs = nullptr;
    const std::vector<strata::core::ConversationCheckpoint>* checks = nullptr;
    bool cvec = false, ok = false;
    strata::core::SessionState* ss = nullptr;
    const strata::core::QsaState* draft = nullptr;
};

// SAVEC of batch slot <c.slot>: the slot's conversation as the source, or false after refusing (a slot that is not
// there, decoding, holds no complete conversation or has pictures).  `Slots` is generate.cpp's BSlot list, `SlotStates`
// its per-stage, per-slot session states and `SlotDrafters` the per-slot MTP drafters (--batch-mtp).
template <class Slots, class SlotStates, class SlotDrafters, class Refuse>
bool slot_source(const SaveCommand& c, const Slots& bs, bool layer_split, const SlotStates& bslot_ss, bool batch_mtp,
                 const SlotDrafters& slot_mtp, SaveSource& src, Refuse&& refuse) {
    static const std::vector<strata::core::ConversationImageKey> no_imgs;
    if (c.slot >= (long long) bs.size()) { refuse("no such batch slot"); return false; }
    if (layer_split) { refuse("SAVEC of a batch slot does not support --layer-split"); return false; }
    const auto& sl = bs[(size_t) c.slot];
    if (sl.active) { refuse("the batch slot is decoding"); return false; }
    if (!sl.cached || sl.partial || sl.tainted) { refuse("the batch slot holds no complete conversation"); return false; }
    if (sl.img) { refuse("the batch slot's conversation has pictures"); return false; }
    src.ids = &sl.ids;
    src.imgs = &no_imgs;
    src.checks = &sl.checks;
    src.cvec = sl.cvec;
    src.ok = true;
    src.ss = bslot_ss[0][(size_t) c.slot].get();
    // the slot's own drafter with --batch-mtp; else the solo drafter's K/V, which was built for another conversation:
    // it only proposes drafts (the verifier decides), as when a slot goes back to the solo path
    if (batch_mtp && (size_t) c.slot < slot_mtp.size()) src.draft = &slot_mtp[(size_t) c.slot]->kv_state();
    return true;
}

// SAVEC <slot|-1> <n> <hash> <path> or SAVEX <slot|-1> <n> <hash> <base> <path>: the fields and the path (to the end
// of the line), or false after answering the refusal
inline bool parse_save(const std::string& line, bool savex, SaveCommand& c, std::string& path) {
    int used = 0;
    if (savex) {
        if (std::sscanf(line.c_str() + 6, "%lld %lld %llx %llx %n", &c.slot, &c.n, &c.hash, &c.base, &used) != 4 ||
            used <= 0) {
            std::printf("SERR invalid 0 expected: SAVEX <slot|-1> <n> <hash> <base> <path>\n");
            std::fflush(stdout);
            return false;
        }
    } else {
        if (std::sscanf(line.c_str() + 6, "%lld %lld %llx %n", &c.slot, &c.n, &c.hash, &used) != 3 || used <= 0) {
            std::printf("SERR invalid 0 expected: SAVEC <slot|-1> <n> <hash> <path>\n");
            std::fflush(stdout);
            return false;
        }
    }
    path = line.substr(6 + (size_t) used);
    return true;
}

// The deepest checkpoint goes into a save's file by reference rather than through the view (which checks a checkpoint
// it carries): so it is checked here as the view would - a prefix of the source's tokens and of their pictures, one
// carve's state (`validate`: conversation_checkpoint_validate against the source's session state, called last).
template <class Validate>
bool deepest_fits(const SaveSource& src, const strata::core::ConversationCheckpoint& deepest, Validate&& validate) {
    auto same_pictures = [&](const strata::core::ConversationCheckpoint& c) {
        size_t k = 0;
        for (const auto& key : *src.imgs) {
            if ((uint64_t) key.start >= c.ids.size()) break;
            if (k >= c.imgs.size() || !(c.imgs[k++] == key)) return false;
        }
        return k == c.imgs.size();
    };
    return !(!deepest.stage_parts.empty() || deepest.ids.empty() || !same_pictures(deepest) ||
             deepest.ids.size() > src.ids->size() ||
             !std::equal(deepest.ids.begin(), deepest.ids.end(), src.ids->begin()) || !validate(deepest));
}

// ---- HELD ------------------------------------------------------------------------------------------------------

// HELD <n> <hash>: the longest conversation the engine holds under that name - the live session, a batch slot (idle
// or decoding; `Slots` is generate.cpp's BSlot list) or a parked conversation - answered as HELD <tokens>.  Nothing is
// moved, saved or touched.
template <class Slots>
void held(const std::string& line, bool live_ok, const std::vector<int32_t>& live, const Slots& bs,
          const strata::core::ConversationCache& conversations) {
    long long held_n = 0;
    unsigned long long held_hash = 0;
    if (std::sscanf(line.c_str() + 5, "%lld %llx", &held_n, &held_hash) != 2 || held_n <= 0) {
        std::printf("SERR invalid 0 expected: HELD <n> <hash>\n");
        std::fflush(stdout);
        return;
    }
    auto named = [&](const std::vector<int32_t>& ids) { return names(held_n, held_hash, ids); };
    size_t held = 0;
    if (live_ok && live.size() > held && named(live)) held = live.size();
    for (const auto& sl : bs)
        if (sl.cached && !sl.partial && !sl.tainted && sl.ids.size() > held && named(sl.ids)) held = sl.ids.size();
    for (size_t i = 0; i < conversations.size(); ++i) {
        const auto& e = conversations.at(i);
        if (e.live.ids.size() > held && named(e.live.ids)) held = e.live.ids.size();
    }
    std::printf("HELD %zu\n", held);
    std::fflush(stdout);
}

// ---- incremental saves (SAVEX) ---------------------------------------------------------------------------------

// Every SAVEX remembers what it wrote (a lineage: the tokens, the K/V layout and the chunk hashes of every K/V part),
// so a later save of the same conversation can write a delta against it.  Kept bytes are the BASE's: a K/V cell before
// the first token that differs from the base's tokens holds the same token's key and value (computed by an earlier
// read: Strata's own retained-K/V reuse keeps such cells the same way).  Pictures or a control vector change what a
// token's K/V means, so they always save in full.
struct KvGeo {
    int format = 0;
    int64_t cells = 0, heads = 0, head_dim = 0, page_size = 0, idx_dim = 0;
    std::array<uint64_t, 5> sizes{};
    bool operator==(const KvGeo& b) const {   // the per-cell layout; cells and sizes may differ
        return format == b.format && heads == b.heads && head_dim == b.head_dim && page_size == b.page_size &&
               idx_dim == b.idx_dim;
    }
};
struct SaveLineage {
    uint64_t id = 0;
    std::vector<int32_t> ids;
    bool cvec = false, pictures = false;
    std::vector<KvGeo> geo;
    strata::core::SessionKvChunks chunks;
};
// one SAVEX on its way: the delta it writes (none: in full), the chunk hashes it writes and its new id
struct SaveX {
    std::optional<strata::core::SessionDelta> delta;
    strata::core::SessionKvChunks chunks;
    std::vector<KvGeo> geo;
    uint64_t id = 0;
};

class SaveLineages {
public:
    static uint64_t new_save_id() {
        static std::mt19937_64 rng{std::random_device{}() ^ ((uint64_t) std::random_device{}() << 32) ^
                                   (uint64_t) std::chrono::steady_clock::now().time_since_epoch().count()};
        uint64_t v = 0;
        while (!v) v = rng();
        return v;
    }
    static std::vector<KvGeo> geo_of_sources(const std::vector<strata::core::SessionKvSource>& kv) {
        std::vector<KvGeo> g;
        for (const auto& k : kv) g.push_back({k.format, k.cells, k.heads, k.head_dim, k.page_size, k.idx_dim, {
            k.sizes[0], k.sizes[1], k.sizes[2], k.sizes[3], k.sizes[4]}});
        return g;
    }
    static std::vector<KvGeo> geo_of_image(const strata::core::SavedConversation& im) {
        std::vector<KvGeo> g;
        for (const auto& k : im.kv) g.push_back({k.format, k.cells, k.heads, k.head_dim, k.page_size, k.idx_dim, {
            k.k.size(), k.v.size(), k.k_scale.size(), k.v_scale.size(), k.pooled.size()}});
        return g;
    }
    // a delta against `base` for this conversation, or nothing (save in full): the bytes of every K/V part that
    // hold the cells before the first token differing from the base's - whole pages, whole indexer rows, the
    // draft one cell less (its last cell may not have been computed) - in whole chunks the base has too
    void plan_delta(uint64_t base, const std::vector<int32_t>& ids, bool cvec, bool pictures,
                    const std::vector<KvGeo>& geo, std::optional<strata::core::SessionDelta>& out) {
        out.reset();
        if (!base || pictures) return;
        auto it = std::find_if(lineages_.begin(), lineages_.end(), [&](const SaveLineage& l) { return l.id == base; });
        if (it == lineages_.end() || it->pictures || it->cvec != cvec || it->geo.size() != geo.size()) return;
        for (size_t j = 0; j < geo.size(); ++j) if (!(it->geo[j] == geo[j])) return;
        const size_t common = (size_t) (std::mismatch(ids.begin(), ids.begin() + (ptrdiff_t) std::min(ids.size(), it->ids.size()),
                                                      it->ids.begin()).first - ids.begin());
        const int64_t idx_block = strata::kernels::qsa_real_shapes().idx_block;
        strata::core::SessionDelta d;
        d.base = base;
        d.base_chunks = &it->chunks;
        d.keep.assign(geo.size(), {});
        for (size_t j = 0; j < geo.size(); ++j) {
            const bool draft = j + 1 == geo.size();
            const int64_t u = std::max<int64_t>(0, (int64_t) common - (draft ? 1 : 0));
            const KvGeo& n = geo[j];
            for (size_t p = 0; p < 5; ++p) {
                uint64_t keep = 0;
                if (p < 4) {
                    const int64_t whole = n.page_size > 0 ? u / n.page_size * n.page_size : 0;
                    if (n.cells > 0) keep = n.sizes[p] / (uint64_t) n.cells * (uint64_t) whole;
                } else if (!draft && idx_block > 0) {
                    keep = (uint64_t) (u / idx_block) * (uint64_t) n.idx_dim * 4;
                }
                keep = std::min({keep, n.sizes[p], it->geo[j].sizes[p]});
                keep = keep / strata::core::kSessionChunk * strata::core::kSessionChunk;
                keep = std::min<uint64_t>(keep, it->chunks[j][p].size() * strata::core::kSessionChunk);
                d.keep[j][p] = keep;
            }
        }
        out = std::move(d);
    }
    void remember(uint64_t id, const std::vector<int32_t>& ids, bool cvec, bool pictures,
                  std::vector<KvGeo>&& geo, strata::core::SessionKvChunks&& chunks) {
        lineages_.push_back({id, ids, cvec, pictures, std::move(geo), std::move(chunks)});
        while (lineages_.size() > kLineages) lineages_.pop_front();
    }
    void touch(uint64_t id) {   // a base used again stays (most recently used last)
        auto it = std::find_if(lineages_.begin(), lineages_.end(), [&](const SaveLineage& l) { return l.id == id; });
        if (it != lineages_.end() && std::next(it) != lineages_.end()) {
            SaveLineage l = std::move(*it);
            lineages_.erase(it);
            lineages_.push_back(std::move(l));
        }
    }
    // a SAVEX about to write: its geometry, the delta against `base` when there can be one, a new id, and the write
    // options that write that delta and hand back the chunk hashes
    void prepare(SaveX& x, uint64_t base, const std::vector<int32_t>& ids, bool cvec, bool pictures,
                 std::vector<KvGeo>&& geo, strata::core::SessionWriteOptions& wo) {
        x.geo = std::move(geo);
        plan_delta(base, ids, cvec, pictures, x.geo, x.delta);
        x.id = new_save_id();
        if (x.delta) { x.delta->id = x.id; wo.delta = &*x.delta; }
        wo.kv_chunks = &x.chunks;
    }
    // a save written: SAVEX remembers it (and keeps its base) and answers SAVEDX <tokens> <bytes> <ms> <id> <base|0>;
    // SAVEC answers SAVED <tokens> <bytes> <ms>.  `ms` is read when the answer is printed.
    template <class Ms>
    void answer(bool savex, SaveX& x, uint64_t base, const std::vector<int32_t>& ids, bool cvec, bool pictures,
                size_t bytes, Ms&& ms) {
        if (savex) {
            if (x.delta) touch(base);
            remember(x.id, ids, cvec, pictures, std::move(x.geo), std::move(x.chunks));
            std::printf("SAVEDX %zu %zu %.1f %016llx %016llx\n", ids.size(), bytes, ms(),
                        (unsigned long long) x.id, (unsigned long long) (x.delta ? base : 0));
        } else {
            std::printf("SAVED %zu %zu %.1f\n", ids.size(), bytes, ms());
        }
    }
private:
    std::deque<SaveLineage> lineages_;   // most recently used last
    static constexpr size_t kLineages = 64;   // at least the last two saves of each of 32 sessions
};

// ---- SAVEC / SAVEX of a parked conversation ----------------------------------------------------------------------

// The live session moved on (another conversation's request took it and parked this one): save the longest parked
// conversation it names, straight from RAM.  The file is the one a SAVE of it as the live session writes (only the
// deepest checkpoint).  A batch slot's conversation (slot >= 0) is never looked for among the parked ones.  Answers
// as the save does, or refuses through generate.cpp's `refuse` (which prints SERR).
template <class Refuse, class Ms>
void save_parked(const std::string& path, const SaveCommand& c, bool savex,
                 const strata::core::ConversationCache& conversations, SaveLineages& lineages,
                 const strata::core::SessionFileIdentity& id, std::string& err, uint64_t min_free_bytes,
                 strata::core::SessionProgress progress, strata::core::SessionPhase phase, Refuse&& refuse, Ms&& ms) {
    const strata::core::SavedConversation* parked = nullptr;
    for (size_t i = 0; c.slot < 0 && i < conversations.size(); ++i) {
        const auto& e = conversations.at(i);
        if (e.stage_images.empty() && e.live.imgs.empty() && names(c, e.live.ids) &&
            (!parked || e.live.ids.size() > parked->live.ids.size())) parked = &e;
    }
    if (!parked) { refuse("that conversation is no longer held there"); return; }
    size_t bytes = 0;
    strata::core::SessionWriteOptions wo;
    wo.min_free_bytes = min_free_bytes;
    wo.progress = std::move(progress);
    wo.phase = std::move(phase);
    strata::core::SessionStatus st;
    SaveX x;
    if (savex)
        lineages.prepare(x, c.base, parked->live.ids, parked->cvec, !parked->live.imgs.empty(),
                         SaveLineages::geo_of_image(*parked), wo);
    try {
        if (!strata::core::session_file_write_parked(path, *parked, id, bytes, err, wo, &st)) {
            refuse(err, st.error, st.published);
            return;
        }
    } catch (const std::bad_alloc&) {
        refuse("not enough RAM to save the session", strata::core::SessionError::memory);
        return;
    }
    std::fprintf(stderr, "strata serve: session saved %zu tokens (parked%s), %zu bytes to %s in "
                 "%.1f ms (disk %.1f ms)\n", parked->live.ids.size(), x.delta ? ", delta" : "", bytes,
                 path.c_str(), ms(), st.disk_ms);
    lineages.answer(savex, x, c.base, parked->live.ids, parked->cvec, !parked->live.imgs.empty(), bytes, ms);
    std::fflush(stdout);
}

// ---- IMPORT ----------------------------------------------------------------------------------------------------

// A session file read and validated like RESTORE, parked in the conversation cache instead of replacing the live
// session: host memory only (the device state, the live session and the batch slots are untouched).  Answers
// IMPORTED <tokens> <bytes> <ms>, or refuses through generate.cpp's `refuse`.
template <class Refuse, class Ms>
void park_import(strata::core::SavedConversation& image, size_t bytes, double read_ms, const std::string& path,
                 strata::core::ConversationCache& conversations, Refuse&& refuse, Ms&& ms) {
    const size_t tokens = image.live.ids.size(), held = image.bytes();
    if (!conversations.wants((int64_t) tokens)) {
        refuse("shorter than --conversation-cache-min-tokens");
        return;
    }
    if (!conversations.put(std::move(image))) {
        refuse("no room in the conversation cache (--conversation-cache-mib / -slots)",
               strata::core::SessionError::memory);
        return;
    }
    std::fprintf(stderr, "strata serve: session imported %zu tokens, %zu bytes (%zu in RAM) from %s "
                 "in %.1f ms (read+check %.1f ms); parked=%zu bytes=%zu evictions=%zu\n", tokens,
                 bytes, held, path.c_str(), ms(), read_ms, conversations.size(),
                 conversations.bytes(), conversations.evictions());
    std::printf("IMPORTED %zu %zu %.1f\n", tokens, bytes, ms());
    std::fflush(stdout);
}

} // namespace strata::program::kv_export
