# kv-export (fork of Strata)

Branch `kv-export-0.2` of github.com/janit/Strata, based on Strata v0.2.3.1 (7ddc17a; branch `kv-export` is the same work
on v0.1.45). It adds what a
serving fleet needs to move a conversation between Strata processes on different hosts. Everything
else behaves exactly as upstream does.

A session that spills from its host to another one normally pays a cold prefill there (41 s for 50k
tokens on one RTX A4000). With these additions, the host that served the turn saves the
conversation by its client session id. A replica on another host is parked there and continues
warm when the session arrives (about 1 s).

## Additions

### Saving a conversation by client session: `POST /slots/session?action=save`

```
POST /slots/session?action=save
{"session": "<X-Session-Affinity, else X-Session-Id, of the session's requests>", "filename": "<name>"}
-> 200 {"id_slot", "session", "filename", "n_saved", "n_written", "timings": {"save_ms"}}
   404  no request of that session on this server (the last 1024 sessions are remembered)
   409  that conversation is no longer held (another request took its slot)
```

- The server remembers the prompt ids of each session's last request. The session is the first
  non-empty header of `X-Session-Affinity` and `X-Session-Id`, taken as it is (the order viiwork
  routes by), printable ASCII only, at most 256 bytes.
- With parallel requests it saves from the idle batch slot that holds the longest conversation
  starting with those ids, else from the live session. When the live session has moved on
  (another session's request took it and parked this conversation), the engine saves the longest
  parked conversation that starts with them, straight from RAM. That file is the one a save of it
  as the live session would write (`session_file_write_parked`: only the deepest checkpoint). It takes the control lines like an
  admission, so slots that are already decoding carry on.
- The engine command is `SAVEC <slot|-1> <n> <hash> <path>`. The engine refuses unless its
  conversation's first `n` ids hash (FNV-1a 64 over little-endian int32,
  `session_ids_fnv1a64`) to `hash`, so a slot that changed hands is never saved under the wrong
  name. It also refuses a slot that is decoding, partial, tainted or has pictures.
- A batch slot's draft K/V is its own with `--batch-mtp`. Otherwise it is the solo drafter's,
  which only proposes drafts: the verifier decides, so the output is the same.

### Importing into the parking cache: `POST /slots/0?action=import`

```
POST /slots/0?action=import {"filename": "<name>"}
-> 200 {"id_slot": 0, "filename", "n_imported", "n_read", "timings": {"import_ms"}}
```

- The file is read and validated like a restore (`IMPORT <path>`), then parked in the
  conversation cache. The live session and the batch slots are untouched, and a later request
  whose prompt matches resumes from it, as it would from any parked conversation.
- Needs `--conversation-cache-mib` > 0. It works beside `--batch` (parallel requests), where it
  takes the control lines like an admission.

### Asking whether a conversation is still held: `POST /slots/session?action=held`

```
POST /slots/session?action=held {"session": "<X-Session-Id>"}
POST /slots/session?action=held {"session": "<X-Session-Id>", "n": <tokens>, "hash": "<16 hex>"}
-> 200 {"session", "n_held"}
```

- With `n` and `hash` (FNV-1a 64 over the first `n` token ids as little-endian int32, as SAVEC
  names a conversation) the engine is asked for that conversation, not the session's: a node
  sends its replica's own ids. Without them the server uses the session's last prompt here,
  which after a compaction on another host is a different branch, so a node could be told
  "held" for a conversation the next turn cannot use.

- `n_held` is the length of the longest conversation the engine still holds that starts with
  the session's last prompt on this server: the live session, a batch slot or a parked
  conversation (`HELD <n> <hash>`, named as SAVEC names one). It is 0 when there is none, and
  when this server never saw the session.
- Read only: nothing is saved, moved or touched, and the server is not marked busy. With
  `--batch` it takes the control lines between two admissions, like a save.
- Why: the conversation cache evicts oldest first and does not say which conversation it
  evicted. A node that imported a replica earlier asks before the next turn, and imports again
  when the engine no longer holds the conversation (viiwork, janit/viiwork#1).

`slot_save_path` (or `--slot-save-path`) names the folder for both, as for upstream's
save/restore. Upstream's `/slots/0?action=save|restore` still refuse parallel requests.

## Measurements (one RTX A4000 per process, IQ3_XXS, 64k context)

| 50k-token conversation | |
|---|---|
| session file | 1.0 GB (about 20 KiB per token) |
| save | 0.56 s, blocking every slot of the engine (ext4; tmpfs is slower). It was 0.80 s before the two changes below |
| save, split | live state off the device 80–90 ms; K/V off the device 65–120 ms; payload hash 170 ms; disk the rest |
| import | 0.64 s (about 1.1 s for the first imports into a process, which allocate fresh RAM); the reader reads the next block on a thread while it parses the current one |
| next turn after import | 0.8–2.0 s, against 41 s cold; output identical to the original host |

Consecutive turns' files differ in 240 MB of 1.0 GB. The K/V is byte-identical up to the reuse
point; the running state (118 MB fp32) is rewritten twice, in the live copy and in the deepest
checkpoint. The checkpoint matters: a client that re-renders the last reply resumes from it.

## A shorter save

Two changes, both in the session writer and both producing the same bytes (pinned by tests):

- **The deepest checkpoint by reference** (`SessionWriteOptions::checkpoints`). A save copied it
  (118 MB) twice before writing it. The engine now checks it as the view did, as a prefix of the
  live tokens and pictures with one carve's state.
- **Write-behind** (`SessionWriteOptions::write_behind`, on by default). Each full 16 MiB block
  goes to a writer thread while the next one is filled, so the disk overlaps the K/V reads and the
  hashing.

A live save and a save of the same conversation after it was parked go through different code. In
one process they wrote byte-identical files, which is the correctness check that does not depend on
the engine being deterministic. It is not: two fresh processes given the same prompt write
different files (one token more, K/V that differs from about cell 49,152). Compare continuations
across processes by their answers, not their bytes.

On teddy (a 97% full NVMe, 1.2–1.3 GB/s direct writes) a save is now disk-bound: hashing on the
writer thread instead was no faster, and on a faster disk it would be slower. Writing fewer bytes is the incremental save below.

## Incremental saves

```
POST /slots/session?action=save {"session", "filename", "base": "<save_id of an earlier save>"}   (base optional)
-> 200 {..., "save_id": "<16 hex>", "base": "<16 hex>" | null, "delta": true | false}
```

Every save by session has a `save_id` (engine command `SAVEX`, answer `SAVEDX`). Given the id
of an earlier save of the same conversation that the engine still remembers (its last 64 saves,
per process), it writes a **delta file** instead of a session file. A delta keeps the bytes of the
cells before the first token that differs from the base's tokens: whole pages, whole indexer rows,
the draft one cell less, rounded down to whole 256 KiB chunks. A kept cell always holds the key and
value of the same token at the same position as in the new state, so a delta never carries a cell
of another token. A conversation with pictures, a different control vector or another
K/V layout saves in full. `"delta": false` means a full session file (no base, an unknown base, or
nothing to keep).

**STRSDLT v1** (little-endian):

- **Header, 80 bytes:** `STRSDLT\x01`, u32 version 1, u32 header size 80, u64 model fingerprint,
  u64 config fingerprint, u64 payload length (the bytes between header and trailer), u64 base
  save_id, u64 new save_id, u64 size of the session file it rebuilds, u64 reserved 0, u64
  `session_hash64(first 72 bytes, 0)`.
- **Payload:** the STRSESS payload in order. Each K/V buffer's u64 size is followed by u64 keep (a
  multiple of 262144), then the bytes from keep on, then u64 n = ceil(size / 262144) and n chunk
  hashes. Chunk hash i is `session_hash64` (seed 0) of bytes [i*262144, min(size, (i+1)*262144))
  of the whole new part.
- **Trailer:** u64 `session_hash64(payload, 0)`, then `STRSDEND`.

Rebuild: the session file's header for the new payload length, the payload with each K/V buffer as
u64 size, the base part's first keep bytes and the delta's tail, then the trailer (the payload's
`session_hash64` and `STRSEND\x01`). Check every chunk hash against the rebuilt part.
`rebuild()` in `src/core/conversation_file_test.cpp` is the reference.

What the chunk hashes protect is the receiver's copy (damage at rest, a wrong apply). Kept chunks
carry the base's hashes, so they cannot catch a keep that went past a real change: that is the
engine's rule above.

**Byte for byte, or the same tokens.** The rule is by tokens, not bytes. When the engine reused every
cell of the base since that save (the usual case: each turn appends to the conversation), base +
delta rebuilds the engine's own full save of the same state byte for byte. When the conversation
diverged inside the base (an edited or regenerated message), the engine resumes from its deepest
checkpoint before the divergence and reads the cells after it again. Their bytes then differ
slightly (float noise from another prefill chunk), and the delta keeps the base's copies of those
cells up to the divergence. They hold the same tokens, so this is the same kind of difference as
between two processes, never a stale cell. Tracking every point the engine read again since a base
would make this exact too; it was not worth the complexity.

Checked on real saves in one process (Strata v0.2.3.1, RTX A4000, 50k tokens). Each test compared
base + delta with the device's own full save of the same state:

| KV format | appended turn | diverged turn (another question after the same document) |
|---|---|---|
| int8 | identical (live, batch and parked paths) | cells 49,152-49,663 differ, all before the first differing token (50,003) |
| q4_0 | identical | identical |
| k8v4 | identical (batch path) | cells 49,152-49,663 differ, all before 50,003 |
| fp16 | identical (parked path) | cells 49,152-49,919 differ, all before 50,003 |

The delta is about 240 MB in every format, mostly the running state, which is rewritten whole. The
full file is 0.69 GB (q4_0), 0.86 GB (k8v4), 1.0 GB (int8) or 1.65 GB (fp16). Every answer was correct.

| 50k-token turn, RTX A4000 | full save | delta |
|---|---|---|
| live session | 1.0 GB, 0.71 s | 244 MB, 0.30 s |
| batch backend (parallel 2) | 1.0 GB, 0.63 s | 244 MB, 0.26 s |
| parked conversation | 1.0 GB, 0.64 s | 244 MB, 0.19 s |

## Where the files go

Session and delta files are a cache: a lost file costs one cold prefill (about 40 s at 50k tokens on
an RTX A4000), never a wrong answer. Durability does not matter; write endurance and write speed
do. A serving host writes a delta of about 240 MB every turn of a long session, and the host that
keeps the replica writes as much again. A full save on teddy is bound by its disk (1.2 GB/s), and
every slot of the engine waits while it runs.

Put `slot_save_path` (and viiwork's `kv_share.dir`) on their own drive, not the system disk.
Prefer Intel Optane, rated for 30–100 drive writes a day. Use the same mount path on every host
of a group. About 1 GB per 50k-token conversation, so even a 280 GB drive holds a few hundred.
tmpfs measured slower than ext4 with O_DIRECT (1.12 vs 0.68 s for a full save).

## Server memory

The server remembers the prompt of each session's last request so that it can find the
conversation again. It keeps the last 1024 sessions, packed as int32 (4 bytes a token), with at
most 64 MiB in total; the oldest go first. It hashes a prompt before taking the control lines (36
ms per 50k tokens), not while holding them.

## On v0.2.3.1

Merged from v0.1.45 with no change to the additions: upstream did not touch the session-file or
conversation-cache code, and the session commands keep v0.1.45's answers (`SERR`, `SESSION`,
`SWAIT`). Checked again on teddy with this branch's image: base + delta rebuilt the full save byte
for byte on the live, batch and parked paths (244 MB deltas in 0.19–0.26 s, full saves 0.56–0.70
s), and a 50k-token conversation saved on one process, imported into another (1.2 s), went on
there in 1.9 s with 50,029 tokens cached.

Two upstream changes matter to a caller:

- The conversation cache is on by default (sized from the free RAM), so IMPORT no longer needs an
  explicit `--conversation-cache-mib`; `0` still turns it off.
- The image layout is new: the server runs from `/opt/strata/terminal` with its own Python
  (`/opt/strata/terminal/python/bin/python3 -m serve.server`), and the engine is
  `/opt/strata/components/engine/<version>/strata`, whose folder must be in the config's
  `lib_dirs` (it carries libcudart). The root `Dockerfile` needs
  `--build-arg STRATA_COMMIT=$(git rev-parse HEAD)` (fixed here; upstream's fails without it).

## Tests

- `serve/test_kv_export.py`: session header, ids hash vector, the session memory, save solo and
  in parallel (which slot is chosen, 404, 409, the control lines given back), import solo and in
  parallel.
- `src/core/conversation_file_test.cpp`: `session_ids_fnv1a64` against the same vector; a parked
  image's file equals the file of the image holding only its deepest checkpoint; write-behind and
  in-place writes are byte-identical; checkpoints by reference equal checkpoints copied into the
  image; delta saves (base + delta rebuild the full file byte for byte, also for a parked image;
  a damaged base or delta is caught; a keep that is not whole chunks of the part and the base is
  refused). It also runs under ThreadSanitizer, except the address-space limit test, which
  ThreadSanitizer cannot run.
- `serve/test_kv_export.py` also covers the base field: a delta answer, an unknown base, malformed
  ids, and an answer out of step, which ends the engine.
