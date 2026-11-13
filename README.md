# kvx: kv-export as an overlay on upstream Strata

This branch (`kvx` of github.com/janit/Strata) holds kv-export (see `KV-EXPORT.md`) as an overlay and
nothing else: two patches against an upstream Strata release and the scripts that apply them. A build
takes upstream's own tag, branch or commit, patches it, runs the tests and builds the image. There is
no merged fork branch to keep up.

**`kvx` is the source of truth.** The branches `kv-export`, `kv-export-0.2`, `kv-export-0.2.6`,
`kv-export-0.2.13` and `kv-export-hooks` are frozen history; the last of them stop at tag
`v0.2.13-kvx2`, whose patches are the ones here.

```
BASE                            the upstream release the patches are made against (v0.2.13.1)
patches/kv-export.patch         kv-export: hooks in upstream's files plus its own files (no Dockerfile)
patches/dsv41-dockerfile.patch  the Dockerfile alone: the optional strata-dsv41 build (unrelated to kv-export)
apply.sh                        apply the patches to a Strata source tree
build.sh                        upstream ref -> checkout + apply + tests + docker build
dev.sh                          upstream ref -> a development checkout with the overlay as one commit
make-patches.sh                 a development checkout -> patches/ (and BASE)
lib.sh                          what build.sh and dev.sh share (sourced, not run)
KV-EXPORT.md                    a copy of the one the patch adds, so the contract reads without applying it
LICENSE                         upstream Strata's license
```

The patches are under the same license as Strata (MIT, `LICENSE`).

## Why an overlay

kv-export touches upstream in a few dozen lines of hooks; everything else is files of its own. As a
merged branch, every upstream release meant a merge, a branch per release and the question of which
branch is current. As an overlay, the change is the patch: it applies to whatever upstream ships, a
release that moved the hooks' surroundings is a 3-way merge or a conflict in a known place, and the
only thing to maintain is the patch itself.

## Building

`v0.2.14` in the examples stands for the next upstream release; use a tag upstream has (`v0.2.13.1`,
say), a branch (`main`) or a commit id.

```sh
./build.sh v0.2.14                                  # strata-cuda:v0.2.14-kvx, archs 86;89;120
./build.sh v0.2.14 --with-dsv41 --tag strata-cuda:kvx-0.2.14
./build.sh v0.2.14 --target engine-build --build-arg BUILD_VISION=0
                                                    # compile check of the engine only:
                                                    # strata-cuda:v0.2.14-kvx-engine-build
./build.sh main --no-build                          # does upstream's tip still take the patch and pass?
./apply.sh ~/some/strata-checkout --check           # report only, change nothing
```

A checkout of this branch is all `build.sh` needs, wherever it is (`<overlay>` below). It makes a scratch checkout under
`~/strata-kvx-build/<ref>/src` (`KVX_SCRATCH` overrides the parent). Upstream is
`https://github.com/Niko1221/Strata.git` (`STRATA_UPSTREAM` overrides it), and the ref is fetched from
it with `--depth 1`: a tag, a branch (`main` always means upstream's branch) or a commit id with all
40 digits. When `BASE` is not the ref, `BASE` is fetched too, so a patch that does not apply as it is
can fall back to a 3-way merge against the blobs it was made from.

`STRATA_REPO`, when set, names a local Strata clone (`~/strata-fork` on the build host, say), and
supplies objects only: the scratch checkout is a `git clone --shared --no-tags` of it, so nothing it
already has is downloaded or copied, but a tag or a branch is still resolved by upstream, so a tag only
the fork has (`v0.2.13-kvx2`) is refused as it is without `STRATA_REPO`. A commit id is a content
address rather than a name: one `STRATA_REPO` has (4 to 40 hex digits) is used from it without asking
upstream. Whatever is fetched goes into the scratch checkout only, so `STRATA_REPO` gains no tag or
object. A ref git would not take as a name (`..`, for one) is refused before any directory is touched,
and a ref that already carries the overlay (applying it changes nothing) is refused after `apply.sh`.

After `apply.sh`, the patched tree is committed in the scratch checkout with `git commit-tree`, author
`kvx` and the upstream commit's own date, and with no hook, signature, encoding or line-ending setting
of the user's taking part, so the same upstream commit and the same patches always give the same
commit id, on any machine, whether it came from GitHub or from `STRATA_REPO`. That id is passed as `STRATA_COMMIT`,
which upstream's image records (`STRATA_BUILD_COMMIT`) and the dsv41 build stamps into `--version`.
The image carries the labels `kvx.upstream` (the ref), `kvx.upstream-commit`, `kvx.commit` (the
patched commit), `kvx.dsv41` and `kvx.overlay` (this branch's commit, `dirty` when the overlay
checkout has changes, `unknown` outside git). With `--target` and no `--tag`, the image is named
`strata-cuda:<ref>-kvx-<stage>`, so a build stage never takes the runnable image's name. The CPU tests
run first; the build runs under `nice -n 10`. The Dockerfile itself still downloads llama.cpp at
upstream's pinned commit, as upstream's build always does.

## Changing kv-export, or moving to a new upstream release

The patches are never edited by hand. Make a development checkout, work there, and write the patches
back:

`<overlay>` is wherever this branch is checked out.

```sh
<overlay>/dev.sh v0.2.14 ~/strata-kvx-dev/v0.2.14 --with-dsv41
        # upstream v0.2.14 (tag kvx-base), and on it one commit "kv-export overlay" on branch kvx-dev
cd ~/strata-kvx-dev/v0.2.14
#   ... on a conflict: resolve, git add, git commit -m "kv-export overlay" (see "On a conflict")
#   ... edit, commit
<overlay>/dev.sh --test ~/strata-kvx-dev/v0.2.14     # CPU tests + serve/test_kv_export.py
<overlay>/make-patches.sh ~/strata-kvx-dev/v0.2.14   # patches/, BASE, KV-EXPORT.md
<overlay>/build.sh v0.2.14 --target engine-build --build-arg BUILD_VISION=0 --archs 120
                                                     # the CUDA compile check
```

Without `STRATA_REPO` the dev checkout is shallow (`--depth 1`): upstream's history is not in it, so
`log`, `blame` and a rebase onto a newer release do not work there. Set `STRATA_REPO` to a full clone
for those. Work in progress is never moved between checkouts by git: write it into `patches/` with
`make-patches.sh` and commit it on this branch first, then make a new checkout with `dev.sh`.

`dev.sh` records the base in the checkout (`.git/kvx/base`, `.git/kvx/base-ref`, `.git/kvx/dsv41`;
not directly in `.git`, where a file would shadow the `kvx-base` tag).
`make-patches.sh` diffs the base against the checkout's `HEAD`: `kv-export.patch` is everything but
the Dockerfile, `dsv41-dockerfile.patch` the Dockerfile alone. It refuses a checkout with uncommitted
or untracked files (the patches are made from commits), never writes an empty `kv-export.patch`, and
pins every diff option itself (the attributes file and `GIT_DIFF_OPTS` among them), so the patches
do not depend on anyone's git config. `.git/info/attributes` cannot be switched off that way, so a
checkout that has one is refused. A checkout made
without `--with-dsv41` leaves `dsv41-dockerfile.patch` as it is and must not change the Dockerfile.
When the checkout's base is another release, `BASE` follows it (a branch is written as its commit id,
since a branch moves); that needs a checkout made with `--with-dsv41`, so that both patches move to
the new release together, and one made without it is refused. `make-patches.sh --check <dir>` changes nothing and exits 1 if anything here
would change.

Moving to a new release is the same flow, in this order: commit any work in progress on this branch
(`make-patches.sh` on the old checkout), then `dev.sh <new-tag> <dir> --with-dsv41` applies the
overlay with a 3-way merge where it has to, the conflicts (if any) are fixed in that checkout, the tests and the CUDA compile
check pass, and `make-patches.sh` writes patches made against the new release, with `BASE` set to
it. Commit the result on this branch.

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

The tests that pin it travel inside the patch: `serve/test_kv_export.py` (27 tests) and the
kv-export checks in `src/core/conversation_file_test.cpp` (232 checks in all, with upstream's own),
plus upstream's `src/core/session_save_reclaim_test.cpp` (119), which the save path also touches.
`build.sh` and `dev.sh --test` run all three.

## On a conflict

`apply.sh` checks every selected patch before it applies any, so a patch that does not fit leaves
the tree as it was, the other patch included. It tries each patch as it is first. In a git
checkout a patch that does not fit is retried with `git apply --3way`, which merges each file
against the upstream blob the patch was made from (the patches carry full blob ids, and `build.sh`
and `dev.sh` fetch `BASE` so those blobs are there); that needs the files the patch touches to have no
uncommitted edits, so `apply.sh` lists any such file and stops before changing anything. `--check`
runs the same 3-way merge on a copy of the index, so it says what the real run will. It then says
one of four things:

- **already applied** (or **already in this tree**, when the overlay was merged earlier): nothing
  to do.
- **applied cleanly**: nothing to do.
- **applied with a 3-way merge**, listing the merged files: upstream changed lines near a hook, and
  git merged them. Read the merged hunks (`git diff --cached` in the checkout); `build.sh` carries
  on to the tests, which are the real check.
- **CONFLICTS**, listing the files with conflict markers (and any file that could not be merged at
  all, e.g. upstream removed or renamed it). Nothing is built.

Outside a git checkout there is no 3-way merge: the patch applies whole or not at all, and the
files whose hunks do not fit are listed. An empty `kv-export.patch` is an error, never "nothing to
do".

To resolve one, in a `dev.sh` checkout of the new release:

1. Look the file up in **Hook sites** below. Every hook is a few lines, marked `kv-export` in a
   comment, and none holds logic of its own. The logic is in the kv-export files, which upstream
   never touches, so they always apply.
2. Usually upstream rewrote the statement a hook sits in. Re-place the hook in upstream's new
   statement so that it does the same thing, keeping upstream's code as it now is.
3. If upstream changed something kv-export calls (a signature, a member that moved, the session
   command loop, the control-line locking), the kv-export file has to follow, in the same checkout.
4. `git add` the files, `git commit -m "kv-export overlay"`, then `dev.sh --test`, the CUDA compile
   check (`build.sh <tag> --target engine-build`, after `make-patches.sh`) and `make-patches.sh`.
5. Whatever is changed, the contract above must not: the same commands, answers, status codes,
   bodies and file bytes. `serve/test_kv_export.py` and `conversation_file_test` say so, and a
   differential run against the previous image settles anything they do not cover.

## Hook sites

What the patch changes in upstream's own files (paths in the Strata tree). Everything else in the
patch is a new file: `include/strata/program/kv_export.hpp`, `include/strata/core/session_delta.hpp`,
`src/core/session_delta_file.hpp`, `serve/kv_export.py`, `serve/test_kv_export.py` and `KV-EXPORT.md`.

### `serve/server.py` (+29 / -12)

- Imports, after `from serve import images as images_api`: `from serve import kv_export` and the
  re-exported names (`KV_SESSION`, `SESSION_ANSWERS`, `fnv1a64_ids`,
  `kv_session_id`, `session_answer`, `session_command`).
- `StrataEngine.session_file` / `_session_file`: a third argument, `conv`, passed through.
- `_session_file`: the command line and the awaited answer come from
  `session_command(action, path, conv)` instead of upstream's `SAVE`/`RESTORE` check and
  `want = ...`, and the stdin write is under `with getattr(self, "wlock", None) or contextlib.nullcontext():`.
- `_session_file`'s answer loop: `if head == want and want in SESSION_ANSWERS:` returns
  `session_answer(...)` (HELD, SAVEDX); a malformed answer is `out_of_step(line)`.
- `class Service(kv_export.KvExport)`, and as its first statement the class attributes
  `kv_refused, kv_filename_problem = SessionRefused, staticmethod(slot_filename_problem)`: class
  attributes rather than globals of `serve/kv_export.py`, because server.py usually runs as
  `__main__` and upstream modules (`serve/replicas.py`, `serve/split.py`) import `serve.server`
  while serving, which loads a second copy whose `SessionRefused` the running engine never raises.
  The session memory's limits (`KV_SESSIONS_KEPT`, `KV_SESSIONS_BYTES`) are set on
  `serve.kv_export`, not on `serve.server`.
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
the C++ refactor commit on the frozen `kv-export-hooks` branch for why each stays).

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
| v0.2.13.1 (BASE) | clean | clean | 232 + 119 checks, test_kv_export 27 |
| main at 13eedf55 (2026-11-12, 160 commits past v0.2.13.1) | clean | clean | same (test_kv_export 27) |
| v0.2.12 | clean | clean | same (test_kv_export 27) |

"Clean" means `git apply` without a 3-way merge. Built with CUDA: v0.2.13.1 with dsv41 (archs
86;89;120, from the frozen branch), and the overlay's own `build.sh v0.2.13.1 --target engine-build`
(arch 120). For the other two refs the CUDA compile of `generate.cpp` was not checked.

The table is the state on the day it was written. `.github/workflows/upstream-check.yml` repeats the
check every Monday and on each push to this branch: BASE, upstream's newest `v*` tag and upstream
`main`, each with both patches (`build.sh <ref> --with-dsv41 --no-build`), then upstream's own serve
suite on the patched tree (`tools/check --only py-serve`). A red run, or a summary that says a ref
took only a 3-way merge, means the patches need the flow above. It builds no image and compiles no
CUDA, so a hook that still applies but no longer compiles shows up only in `build.sh --target
engine-build`.
