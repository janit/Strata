# kv-export (fork of Strata)

Branch `kv-export` of github.com/janit/Strata, based on Strata v0.1.45 (477ac13). It adds what a
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

`slot_save_path` (or `--slot-save-path`) names the folder for both, as for upstream's
save/restore. Upstream's `/slots/0?action=save|restore` still refuse parallel requests.

## Measurements (one RTX A4000 per process, IQ3_XXS, 64k context)

| 50k-token conversation | |
|---|---|
| session file | 1.0 GB (about 20 KiB per token) |
| save | 0.56 s, blocking every slot of the engine (ext4; tmpfs is slower). It was 0.80 s before the two changes below |
| save, split | live state off the device 80–90 ms; K/V off the device 65–120 ms; payload hash 170 ms; disk the rest |
| import | 0.92–1.5 s, holding the engine |
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
writer thread instead was no faster, and on a faster disk it would be slower. To go below 0.5 s
per GB, write fewer bytes:

- **Incremental save:** the running state plus the K/V from the first changed page. Either keep a
  page hash list per save and compare by content (safe; costs a full K/V read, 65–120 ms), or track
  the first rewritten cell per source (faster; every K/V writer must be covered, or a valid-looking
  file has stale contents).
- **No file at all:** stream the save to the replicating process, which sends only what the
  receiver lacks. That needs a stream target instead of `Publisher`'s temporary file and rename.

## Tests

- `serve/test_kv_export.py`: session header, ids hash vector, the session memory, save solo and
  in parallel (which slot is chosen, 404, 409, the control lines given back), import solo and in
  parallel.
- `src/core/conversation_file_test.cpp`: `session_ids_fnv1a64` against the same vector; a parked
  image's file equals the file of the image holding only its deepest checkpoint; write-behind and
  in-place writes are byte-identical; checkpoints by reference equal checkpoints copied into the
  image. It also runs under ThreadSanitizer, except the address-space limit test, which
  ThreadSanitizer cannot run.
