// src/core/session_delta_file.hpp - kv-export: the delta file writer's own pieces (STRSDLT v1), private to
// conversation_file.cpp.  Pure host code: no CUDA.
//
// conversation_file.cpp writes a delta file through the same walk as a session file (write_impl, put_payload,
// Out::source), so the places where the two differ stay woven into those functions, each marked "kv-export".  What
// stands on its own lives here, so an upstream merge of conversation_file.cpp meets a few lines instead of these
// definitions: the delta file's magic, end mark and 80-byte header, a host image's K/V as sources (so an image can be
// hashed in chunks or written as a delta), the check of a delta's keep values, and the chunk hasher a K/V part's
// bytes pass through.  The types the options carry (SessionDelta, SessionKvChunks, kSessionChunk) are public, in
// include/strata/core/session_delta.hpp.  KV-EXPORT.md documents the format; it is a contract, byte for byte.
#pragma once

#include "strata/core/conversation_file.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace strata::core::session_delta_detail {

// kv-export: delta files (STRSDLT v1): an 80-byte header, the same trailer size
inline constexpr char kDeltaMagic[8] = {'S', 'T', 'R', 'S', 'D', 'L', 'T', '\x01'};
inline constexpr char kDeltaEnd[8] = {'S', 'T', 'R', 'S', 'D', 'E', 'N', 'D'};
inline constexpr size_t kDeltaHeader = 80;

// kv-export: the 80-byte STRSDLT v1 header
inline void delta_header_bytes(uint8_t* h, const SessionFileIdentity& id, uint64_t payload, const SessionDelta& d,
                               uint64_t full_size) {
    std::memset(h, 0, kDeltaHeader);
    std::memcpy(h, kDeltaMagic, 8);
    const uint32_t version = 1, size = kDeltaHeader;
    std::memcpy(h + 8, &version, 4);
    std::memcpy(h + 12, &size, 4);
    std::memcpy(h + 16, &id.model, 8);
    std::memcpy(h + 24, &id.config, 8);
    std::memcpy(h + 32, &payload, 8);
    std::memcpy(h + 40, &d.base, 8);
    std::memcpy(h + 48, &d.id, 8);
    std::memcpy(h + 56, &full_size, 8);
    const uint64_t hh = session_hash64(h, 72, 0);
    std::memcpy(h + 72, &hh, 8);
}

// kv-export: an image's own K/V as sources, so a host image can be hashed in chunks or written as a delta
inline std::vector<SessionKvSource> image_sources(const SavedConversation& image) {
    std::vector<SessionKvSource> out;
    for (const auto& k : image.kv) {
        SessionKvSource s;
        s.format = k.format; s.cells = k.cells; s.heads = k.heads; s.head_dim = k.head_dim;
        s.page_size = k.page_size; s.pooled_rows = k.pooled_rows; s.idx_dim = k.idx_dim;
        const std::array<const ConversationBuffer*, 5> parts = {&k.k, &k.v, &k.k_scale, &k.v_scale, &k.pooled};
        for (size_t i = 0; i < 5; ++i) s.sizes[i] = parts[i]->size();
        s.read = [parts](size_t part, size_t offset, void* dst, size_t n) {
            if (part >= 5 || offset > parts[part]->size() || n > parts[part]->size() - offset) return false;
            uint8_t* d = static_cast<uint8_t*>(dst);
            return parts[part]->visit(offset, n, [&](const uint8_t* p, size_t c, size_t at) {
                std::memcpy(d + (at - offset), p, c);
                return true;
            });
        };
        s.error = [] { return std::string("K/V read out of range"); };
        out.push_back(std::move(s));
    }
    return out;
}

// kv-export: a delta's keep values against its sources: whole chunks, within the part and the base's chunks
inline bool delta_valid(const SessionDelta& d, const std::vector<SessionKvSource>& kv, std::string& error) {
    if (!d.id || !d.base_chunks || d.keep.size() != kv.size() || d.base_chunks->size() != kv.size()) {
        error = "session file: the delta does not describe these K/V layers";
        return false;
    }
    for (size_t j = 0; j < kv.size(); ++j)
        for (size_t p = 0; p < 5; ++p) {
            const uint64_t keep = d.keep[j][p];
            if (keep % kSessionChunk || keep > kv[j].sizes[p] || keep / kSessionChunk > (*d.base_chunks)[j][p].size()) {
                error = "session file: delta keep " + std::to_string(keep) + " of layer " + std::to_string(j) +
                        " part " + std::to_string(p) + " is not whole chunks of both the part and the base";
                return false;
            }
        }
    return true;
}

// kv-export: the chunk hashes of one K/V part as its bytes pass (Out::source): the session_hash64 (seed 0) of each
// kSessionChunk bytes, the last chunk possibly shorter.  A delta's kept bytes are the base's, so their hashes are the
// base's first keep / kSessionChunk, taken over without reading those bytes.
struct KvChunkHasher {
    std::vector<uint64_t> list;
    SessionHasher piece{0};
    size_t in_piece = 0;
    void start(size_t n_chunks, const SessionDelta* delta, size_t layer, size_t part, size_t keep) {
        list.reserve(n_chunks);
        if (keep) list.assign(delta->base_chunks->at(layer)[part].begin(),
                              delta->base_chunks->at(layer)[part].begin() + (ptrdiff_t) (keep / kSessionChunk));
    }
    void update(const uint8_t* p, size_t c) {
        while (c) {
            const size_t t = std::min<size_t>(c, kSessionChunk - in_piece);
            piece.update(p, t);
            in_piece += t; p += t; c -= t;
            if (in_piece == kSessionChunk) { list.push_back(piece.digest()); piece = SessionHasher(0); in_piece = 0; }
        }
    }
    // the last, shorter chunk (after a part that ended without error)
    void finish() { if (in_piece) list.push_back(piece.digest()); }
};

} // namespace strata::core::session_delta_detail
