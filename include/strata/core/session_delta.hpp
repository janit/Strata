// kv-export: incremental session saves and the conversation naming they share with the server - the public half of
// the delta file format (STRSDLT v1) that conversation_file.cpp writes.  Pure host code: no CUDA.
//
// Kept out of conversation_file.hpp so an upstream merge meets one #include there and not the types themselves;
// conversation_file.hpp includes this header, so every user of SessionWriteOptions sees them as before.  The writer's
// own pieces (the delta header bytes, an image's K/V as sources, the keep checks, the chunk hasher) are private to
// src/core (session_delta_file.hpp).  KV-EXPORT.md documents the file format byte by byte; it is a contract.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace strata::core {

// kv-export: FNV-1a 64 over token ids as little-endian int32 - how SAVEC and the server (serve/server.py
// fnv1a64_ids) name a conversation by its prompt.  {0, 1, -1, 151643} -> 0x2401b33d3e943579.
inline uint64_t session_ids_fnv1a64(const int32_t* ids, size_t n) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < n; ++i) {
        const uint32_t v = (uint32_t) ids[i];
        for (int k = 0; k < 4; ++k) { h ^= (v >> (8 * k)) & 0xff; h *= 1099511628211ULL; }
    }
    return h;
}

// kv-export: incremental saves.  Every K/V part (k, v, k_scale, v_scale, pooled of each layer) is also described by
// the session_hash64 (seed 0) of each kSessionChunk bytes of it (the last chunk may be shorter): a save can return
// them, and a delta save against a base reuses the base's for the bytes it keeps.
constexpr uint64_t kSessionChunk = 256u << 10;
using SessionKvChunks = std::vector<std::array<std::vector<uint64_t>, 5>>;   // per K/V layer, per part
// A delta file (STRSDLT v1) instead of a session file: each K/V part is written as (size, keep, the bytes from keep
// on, the chunk hashes of the whole new part).  keep[layer][part] is a multiple of kSessionChunk (or 0) and at most the
// part's size and the base's: the receiver rebuilds the session file from the base save it holds.
struct SessionDelta {
    uint64_t base = 0, id = 0;                    // the base save's id and this save's
    std::vector<std::array<uint64_t, 5>> keep;   // per K/V layer
    const SessionKvChunks* base_chunks = nullptr; // the base's chunk hashes: the first keep / kSessionChunk are reused
};

} // namespace strata::core
