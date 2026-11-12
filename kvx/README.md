# kvx: kv-export as a patch overlay

`kvx/` turns this branch's kv-export work (see `KV-EXPORT.md`) into something that can be injected
into a build of any upstream Strata release: two patches, a script that applies them, and a
script that checks out a release, applies them, runs the tests and builds the image. The
directory is not part of the patches; it exists only on branch `kv-export-hooks`.

```
kvx/
  BASE                          the upstream tag the patches are made against (v0.2.13.1)
  patches/kv-export.patch       git diff BASE..branch, without kvx/ and without the Dockerfile
  patches/dsv41-dockerfile.patch  the Dockerfile alone: the optional strata-dsv41 build (unrelated to kv-export)
  make-patches.sh               regenerate (or --check) both patches from the branch
  apply.sh                      apply them to a Strata source tree
  build.sh                      checkout + apply + tests + docker build of an upstream release
```

## The contract it keeps

kv-export is called by viiwork. Its surface is a contract and must not change by a byte or a
field from one release to the next:

- HTTP: `POST /slots/session?action=save` (body `session`, `filename`, optional `base`),
  `POST /slots/session?action=held` (`session`, optional `n` and `hash`),
  `POST /slots/0?action=import` (`filename`), with the status codes and bodies `KV-EXPORT.md` gives.
- Engine stdin commands and their answers: `SAVEC`, `SAVEX`, `IMPORT`, `HELD` / `SAVED`,
  `SAVEDX`, `IMPORTED`, `HELD`, `SERR`, `SESSION`, `SWAIT`.
- On-disk formats: session files (`STRSESS`) and delta files (`STRSDLT` v1), and the ids hash
  (FNV-1a 64 over little-endian int32, `session_ids_fnv1a64` / `fnv1a64_ids`).

The tests that pin it travel inside the patch: `serve/test_kv_export.py` (26 tests) and the
kv-export checks in `src/core/conversation_file_test.cpp` (232 checks in all, with upstream's own),
plus upstream's `src/core/session_save_reclaim_test.cpp` (119), which the save path also touches.
`build.sh` runs all three before it builds.

## Using it on a new upstream release

```sh
kvx/build.sh v0.2.14                                # strata-cuda:v0.2.14-kvx, archs 86;89;120
kvx/build.sh v0.2.14 --with-dsv41 --tag strata-cuda:kvx-0.2.14
kvx/build.sh v0.2.14 --target engine-build --build-arg BUILD_VISION=0 --tag strata-kvh-check:0.2.14
                                                    # compile check of the engine only
kvx/build.sh main --no-build                        # does upstream's tip still take the patch and pass?
kvx/apply.sh ~/some/strata-checkout --check         # report only, change nothing
```

`build.sh` makes a scratch clone under `~/strata-kvx-build/<tag>/src` with `git clone --shared
~/strata-fork` (no object is copied; `STRATA_REPO` and `KVX_SCRATCH` override the two paths). A tag
this host does not have is fetched from `~/strata-fork`'s `origin` remote into the scratch clone
only, so `~/strata-fork` gains no tag. After `apply.sh`, the patched tree is committed in the scratch
clone with author `kvx` and the release's own commit date, so the same release and the same
patches always give the same commit id. That id is passed as `STRATA_COMMIT`, which upstream's
image records (`STRATA_BUILD_COMMIT`) and the dsv41 build stamps into `--version`; the image also
carries the labels `kvx.upstream`, `kvx.upstream-commit`, `kvx.commit` and `kvx.dsv41`. The build
runs under `nice -n 10`. The Dockerfile itself still downloads llama.cpp at upstream's pinned
commit, as upstream's build always does.

When a release applies cleanly and the tests pass, the image is ready. To move the branch itself
onto the release (so that the next patch is made against it), merge the tag into the branch as
before, then `kvx/make-patches.sh <new-tag>` and write the new tag into `kvx/BASE`.

## On a conflict

`apply.sh` tries each patch as it is first. In a git checkout a patch that does not fit is retried
with `git apply --3way`, which merges each file against the upstream blob the patch was made from
(the patches carry full blob ids). It then says one of three things:

- **applied cleanly**: nothing to do.
- **applied with a 3-way merge**, listing the merged files: upstream changed lines near a hook, and
  git merged them. Read the merged hunks (`git diff --cached` in the checkout); `build.sh` carries
  on to the tests, which are the real check.
- **CONFLICTS**, listing the files with conflict markers (and any file that could not be merged at
  all, e.g. upstream removed or renamed it). Nothing is built.

Outside a git checkout there is no 3-way merge: the patch applies whole or not at all, and the
files whose hunks do not fit are listed.

To resolve one:

1. Look the file up in **Hook sites** below. Every hook is a few lines, marked `kv-export` in a
   comment, and none holds logic of its own. The logic is in the kv-export files, which upstream
   never touches, so they always apply.
2. Usually upstream rewrote the statement a hook sits in. Re-place the hook in upstream's new
   statement so that it does the same thing, keeping upstream's code as it now is.
3. If upstream changed something kv-export calls (a signature, a member that moved, the session
   command loop, the control-line locking), the kv-export file has to follow. Make that change on
   the branch, not in the scratch checkout: merge the release into `kv-export-hooks`, fix it there,
   run the tests and the CUDA compile check, then `kvx/make-patches.sh <new-tag>`.
4. Whatever is changed, the contract above must not: the same commands, answers, status codes,
   bodies and file bytes. `serve/test_kv_export.py` and `conversation_file_test` say so, and a
   differential run against the previous image settles anything they do not cover.

## Hook sites

What the patch changes in upstream's own files. Everything else in the patch is a new file:
`include/strata/program/kv_export.hpp`, `include/strata/core/session_delta.hpp`,
`src/core/session_delta_file.hpp`, `serve/kv_export.py`, `serve/test_kv_export.py` and `KV-EXPORT.md`.

### `serve/server.py` (+29 / -12)

- Imports, after `from serve import images as images_api`: `from serve import kv_export` and the
  re-exported names (`KV_SESSION`, `KV_SESSIONS_KEPT`, `SESSION_ANSWERS`, `fnv1a64_ids`,
  `kv_session_id`, `session_answer`, `session_command`).
- `StrataEngine.session_file` / `_session_file`: a third argument, `conv`, passed through.
- `_session_file`: the command line and the awaited answer come from
  `session_command(action, path, conv)` instead of upstream's `SAVE`/`RESTORE` check and
  `want = ...`, and the stdin write is under `with getattr(self, "wlock", None) or contextlib.nullcontext():`.
- `_session_file`'s answer loop: `if head == want and want in SESSION_ANSWERS:` returns
  `session_answer(...)` (HELD, SAVEDX); a malformed answer is `out_of_step(line)`.
- Before `class Service`: `kv_export.bind(SessionRefused, slot_filename_problem)`, and
  `class Service(kv_export.KvExport)`.
- `Service.slot_action`: the arguments `session=None, base=None, conv=None`; `slot == "session"`
  goes to `self.session_save(...)`, `action == "import" and slot == "0"` to `self.session_import(...)`;
  the error text `"action must be save, restore or import"`.
- `Service.stream`: `self.kv_note(getattr(KV_SESSION, "sid", None), ids)`, which remembers the
  session's prompt.
- `make_handler`, the `/slots/` POST: `KV_SESSION.sid = kv_session_id(self.headers)` and the
  extra `slot_action` arguments `req.get("session"), req.get("base"), (req.get("n"), req.get("hash"))`.

### `serve/session_save_retry.py` (+5 / -4)

- `session_file(service, action, path, refused_type, conv=None)`: `conv` passed through to
  `engine.session_file` on every try (only when it is set, so upstream's two-argument call is
  unchanged).

### `src/program/generate.cpp` (+80 / -22)

- `#include "strata/program/kv_export.hpp"` after `conv_cache.hpp`.
- `strata::program::kv_export::SaveLineages lineages;` after the conversation cache is built (what
  every SAVEX wrote, for later deltas).
- The serve loop's session-command gate (`if (line.rfind("SAVE ", 0) == 0 || ...`): `HELD` handled
  by `kv_export::held(...)`; `SAVEC`/`SAVEX`/`IMPORT` added to the condition; `parse_save(...)` for
  SAVEC/SAVEX, the `IMPORT ` path offset, and `import` in the refuse lambda's label.
- The refusals: `--batch` is refused for SAVE/RESTORE only, not SAVEC/IMPORT; IMPORT refuses without a
  conversation cache.
- The save branch: a `kv_export::SaveSource` (the live session, or `slot_source(...)` for a batch
  slot), `save_parked(...)` when the live session moved on, and `src.*` in place of
  `live`/`live_imgs`/`ss`/`mtp.kv_state()` through upstream's preflight and capture.
  `session_save_reclaim` runs only when the source is the live session.
- The deepest checkpoint by reference: `session_deepest_checkpoint` plus
  `admit(session_save_peak_bytes(nullptr, sl), why)` in place of `session_save_checkpoints`,
  validated by `kv_export::deepest_fits(...)`, and passed as `wo.checkpoints`.
- SAVEX: `lineages.prepare(...)` before `session_file_write` and `lineages.answer(...)` after it;
  the longer stderr line (checkpoints, live, K/V reads and disk times).
- The restore branch: `if (import) { kv_export::park_import(...); continue; }` after the file is read
  and validated.

These are the hooks that cannot shrink further: they sit inside upstream's own statements (see
the C++ refactor commit for why each stays).

### `src/core/conversation_file.cpp` (+182 / -29)

- `#include "session_delta_file.hpp"` and `using namespace` for its helpers (delta header and end
  mark, `delta_valid`, `KvChunkHasher`).
- `FileSink` write-behind (a writer thread filling the next 16 MiB block) and `FileSource`
  read-ahead: new members and branches inside upstream's classes.
- `Out`: source/disk timing, and the delta/size/keep framing in `Out::source` (the chunk hashing
  itself is `KvChunkHasher`).
- `put_payload`: the by-reference checkpoint list and the deepest-only branch.
- `write_impl`: the checkpoint and delta checks, the full-size pass, the delta header and end mark,
  `source_ms`/`disk_ms`.
- `write_guarded`: the deepest-only flag.
- `session_file_write_parked` at the end (it needs the anonymous `write_guarded`).

### `include/strata/core/conversation_file.hpp` (+19)

- `#include "strata/core/session_delta.hpp"`.
- `SessionStatus::source_ms`, `disk_ms`.
- `SessionWriteOptions::checkpoints`, `write_behind`, `kv_chunks`, `delta`.
- The `session_file_write_parked` declaration.

### `include/strata/core/conversation_cache.hpp` (+2)

- `ConversationCache::at(index)`: read access to a parked entry (for SAVEC by session and HELD).

### `src/core/conversation_file_test.cpp` (+264)

- The kv-export checks, appended to upstream's test (hash vector, parked image file, write-behind,
  checkpoints by reference, delta round trips and damage).

### Build files

None. The new C++ is header-only, so `CMakeLists.txt`, `cmake/strata_gpu_engine.cmake`,
`metal/CMakeLists.txt` and `sycl/CMakeLists.txt` are untouched, and the CPU test command lines
need no extra source.

### `Dockerfile` (dsv41-dockerfile.patch only, optional)

- `ARG BUILD_DSV41=1` and `ARG STRATA_COMMIT=` in the engine stage, the `build-dsv41` cmake run,
  and copying `strata-dsv41` and its libraries into the engine package. Not needed by kv-export.

## Tried against

| upstream ref | kv-export.patch | dsv41-dockerfile.patch | CPU tests after applying |
|---|---|---|---|
| v0.2.13.1 (BASE) | clean | clean | 232 + 119 checks, test_kv_export 26 |
| main at 13eedf55 (2026-11-12, 160 commits past v0.2.13.1) | clean | clean | same |
| v0.2.12 | clean | clean | same |

"Clean" means `git apply` without a 3-way merge. Only the v0.2.13.1 image was built with CUDA
(`kvx/build.sh v0.2.13.1 --archs "86;89;120" --with-dsv41`); for the other two refs the CUDA compile
of `generate.cpp` was not checked.
