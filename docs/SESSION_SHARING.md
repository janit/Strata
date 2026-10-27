# Moving a conversation between servers

When several Strata servers sit behind one router, a client session sometimes moves to another server: its own is
full, restarting or slower than a free one. The new server has none of the conversation's K/V, so its first turn reads
the whole prompt again. On one RTX A4000 that is 41 s for a 50k-token conversation.

Three server endpoints let a router avoid that. The server that served a turn saves the conversation by the client's
session id; the router copies the file to the server the session may move to; that server parks it in its conversation
cache, and the session continues there warm when it arrives (0.8-2.0 s for the same 50k tokens).

All three need `--slot-save-path DIR` (or `"slot_save_path"`), like the [session files](DETAILS.md#session-files-disk) they
build on. Without it the server keeps no record of sessions and the endpoints answer `501`. Copying files between
hosts is the caller's job; Strata only writes and reads them in `DIR`.

## Save a conversation by client session

```
POST /slots/session?action=save
{"session": "<the session id of its requests>", "filename": "<name>", "base": "<save_id>"}   (base optional)
-> 200 {"id_slot", "session", "filename", "n_saved", "n_written", "save_id", "base", "delta", "timings": {"save_ms"}}
   404  no request of that session on this server
   409  the conversation is no longer held (another request took its slot, or it was evicted)
```

- A request's session is the first non-empty header of `X-Session-Affinity` and `X-Session-Id`, taken as it is
  (printable ASCII, at most 256 bytes). The server remembers the prompt of each session's last request: the last 1024
  sessions, packed as int32, at most 64 MiB in all, oldest first out.
- It saves the conversation that starts with that prompt: the idle batch slot holding the longest one, else the live
  session, else the longest parked conversation (written from RAM). This works with `--batch`; the save takes the
  control lines like an admission, so slots that are already decoding carry on.
- The engine command is `SAVEC <slot|-1> <n> <hash> <path>`. The engine refuses unless the first `n` ids of what it is
  about to save hash (FNV-1a 64 over little-endian int32, `session_ids_fnv1a64`) to `hash`, so a slot that changed hands
  is never written under the wrong name. It also refuses a slot that is decoding, partial, tainted or has pictures.

## Import a file into the conversation cache

```
POST /slots/0?action=import {"filename": "<name>"}
-> 200 {"id_slot": 0, "filename", "n_imported", "n_read", "timings": {"import_ms"}}
```

- The file is read and checked as a restore reads it (`IMPORT <path>`), then parked in the conversation cache. The live
  session and the batch slots are untouched. A later request whose prompt matches resumes from it, as from any parked
  conversation.
- Needs the conversation cache (on by default; `--conversation-cache-mib 0` turns it off and the import is refused).
  Works beside `--batch`.

## Ask whether a conversation is still held

```
POST /slots/session?action=held {"session": "<session id>"}
-> 200 {"session", "n_held"}
```

- `n_held` is the length of the longest conversation the engine still holds that starts with the session's last
  prompt on this server: the live session, a batch slot or a parked one (`HELD <n> <hash>`). It is 0 when there is none,
  and when this server never saw the session.
- Read only: nothing is saved, moved or touched. The conversation cache evicts oldest first and does not say what it
  evicted, so a caller that imported a conversation earlier asks before the next turn and imports it again if needed.

## Incremental saves

Every save by session answers a `save_id`. Given the `save_id` of an earlier save of the same conversation as `base`,
the engine writes a **delta file** instead of a session file, if it still remembers that save (its last 64, per
process). Consecutive turns of a 50k conversation differ in about 240 MB of about 1.0 GB, mostly the running state,
which is rewritten whole. `"delta": false` means a full session file: no base, an unknown base, or nothing to keep.
Conversations with pictures, a different control vector or another K/V layout always save in full.

A delta keeps the bytes of the cells before the first token that differs from the base's tokens: whole pages, whole
indexer rows, the draft one cell less, rounded down to whole 256 KiB chunks. A kept cell always holds the key and value
of the same token at the same position as in the new state, so a delta never carries another token's cell.

**STRSDLT v1** (little-endian):

- **Header, 80 bytes:** `STRSDLT\x01`, u32 version 1, u32 header size 80, u64 model fingerprint, u64 config fingerprint,
  u64 payload length, u64 base save_id, u64 new save_id, u64 size of the session file it rebuilds, u64 reserved 0, u64
  `session_hash64(first 72 bytes, 0)`.
- **Payload:** the STRSESS payload in order. Each K/V buffer's u64 size is followed by u64 keep (a multiple of 262144),
  the bytes from keep on, then u64 n = ceil(size / 262144) and n chunk hashes. Chunk hash i is `session_hash64` (seed 0)
  of bytes [i*262144, min(size, (i+1)*262144)) of the whole new buffer.
- **Trailer:** u64 `session_hash64(payload, 0)`, then `STRSDEND`.

To rebuild the session file: its header for the new payload length; the payload with each K/V buffer as u64 size, the
base's first keep bytes and the delta's tail; then the trailer (the payload's `session_hash64` and `STRSEND\x01`).
Check every chunk hash against the rebuilt buffer. `rebuild()` in `src/core/conversation_file_test.cpp` is the
reference. The chunk hashes protect the receiver's copy (damage at rest, a wrong apply); kept chunks carry the base's
hashes, so the keep rule above is what keeps a delta correct.

When each turn appends to the conversation, base + delta rebuilds the engine's own full save of the same state byte for
byte. After an edited or regenerated message the engine resumes from a checkpoint before the change and reads the cells
after it again; those differ from the base's copies by float noise, for the same tokens.

## Where the files go

Session and delta files are a cache: a missing or refused file costs one cold prefill, never a wrong answer. Write speed
and endurance matter, durability does not. A host writes a delta of about 240 MB per long turn, and the host that keeps
the replica writes as much again. Put `DIR` on its own drive rather than the system disk, and use the same path on every
host. About 1 GB per 50k-token conversation with int8 K/V (0.69 GB q4_0, 0.86 GB k8v4, 1.65 GB fp16).

## Measurements

One RTX A4000 per process, Qwen3.8-Flash-Next IQ3_XXS, 64k context, int8 K/V, ext4, Strata v0.2.3.1 with these
changes:

| 50k-token conversation | |
|---|---|
| full save | 1.0 GB, 0.56-0.71 s; every slot of the engine waits while it runs |
| delta save | 244 MB: 0.30 s live, 0.26 s from a batch slot, 0.19 s parked |
| import | 0.64-1.1 s |
| next turn after import | 0.8-2.0 s, against 41 s cold; same output as on the original server |

Two hosts with one RTX 5090 each, Strata v0.2.6 with these changes: a conversation of 82.9k tokens continued on the
other host in 3.65 s against 24.5 s cold.

## Limits

- Not supported with `--layer-split`, `--peer-device` or `--prompt-cache 0`, and conversations with pictures are not
  saved by session, as for the session files.
- `save_id`s live for one process: after a restart the next save is a full file.
- A save blocks every slot of the engine for its duration.
- Run on Linux with CUDA only.
