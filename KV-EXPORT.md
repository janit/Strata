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
| save | 0.68 s, blocking every slot of the engine (ext4; tmpfs is slower, 1.12 s) |
| save, split | checkpoints 81 ms, live state off the device 152 ms, K/V streamed into the file and written 450 ms |
| import | 0.92–1.5 s, holding the engine |
| next turn after import | 0.8–2.0 s, against 41 s cold; output identical to the original host |

Consecutive turns' files differ in 240 MB of 1.0 GB. The K/V is byte-identical up to the reuse
point; the running state (118 MB fp32) is rewritten twice, in the live copy and in the deepest
checkpoint. The checkpoint matters: a client that re-renders the last reply resumes from it.

## Next: a shorter save

The save pauses every slot, and its write phase grows with the conversation (about 2 s at 200k).
The engine log now splits the write into K/V reads (device to host) and disk. Which of the two
dominates decides the approach:

- **Disk dominates:** write only what changed. Keep a 64 KiB page hash list per save and compare
  the K/V read from the device against it, then write the running state plus the K/V from the
  first changed page. This is verified by content, so no tracking of where the engine rewrites
  K/V is needed, and a wrong guess cannot write a valid-looking file with stale contents.
- **Device reads dominate:** stage through pinned memory, and/or track the first rewritten cell
  per source (the solo path's `read_from`, the batch admissions, conversation swaps, the draft)
  to skip reading the unchanged prefix at all. This is faster but riskier: every K/V writer must
  be covered.

Background writing (capture to RAM, reply, write the file afterwards) does not help as things
stand: a parking capture of the same 50k conversation takes 0.78–0.97 s.

## Tests

- `serve/test_kv_export.py`: session header, ids hash vector, the session memory, save solo and
  in parallel (which slot is chosen, 404, 409, the control lines given back), import solo and in
  parallel.
- `src/core/conversation_file_test.cpp`: `session_ids_fnv1a64` against the same vector.
