#!/usr/bin/env bash
# Build a Strata image of an upstream ref with kv-export injected.  Needs only a checkout of this branch (kvx).
#
#   ./build.sh <upstream-ref> [--archs "86;89;120"] [--tag <image>] [--with-dsv41] [--skip-tests]
#              [--target <stage>] [--build-arg K=V ...] [--no-build]
#
#   <upstream-ref>   a tag of upstream Strata (v0.2.13.1), a branch of it (main: always upstream's branch, never a
#                    local one) or a commit id (all 40 digits, or 4-40 when $STRATA_REPO has it)
#   --archs          CUDA_ARCHITECTURES for the image (default "86;89;120": A4000/3090, 4090, 5090)
#   --tag            image name (default strata-cuda:<upstream-ref>-kvx, or strata-cuda:<upstream-ref>-kvx-<stage>
#                    with --target, so a stage never takes the runnable image's name)
#   --with-dsv41     also apply the optional Dockerfile patch that builds strata-dsv41
#   --skip-tests     do not run the CPU tests before the build
#   --target         build only that Dockerfile stage (engine-build is the quick compile check)
#   --build-arg      passed to docker build as it is (repeatable)
#   --no-build       stop after the tests
#
# Environment: STRATA_UPSTREAM (default https://github.com/Niko1221/Strata.git), STRATA_REPO (optional: a local
# Strata clone whose objects the scratch checkout borrows, so nothing is downloaded that it already has; without it
# the ref is fetched from upstream with --depth 1), KVX_SCRATCH (default ~/strata-kvx-build).
#
# Steps: a scratch checkout of the ref in $KVX_SCRATCH/<ref>/src (lib.sh, kvx_checkout); ./apply.sh applies the
# patches (a 3-way merge is reported; a conflict stops the build); the result is committed in the scratch checkout
# with a fixed author and the upstream commit's own date (so the same upstream commit and patches give the same
# commit id, whichever way it was fetched; that id becomes STRATA_COMMIT and the engine's --version build id); the
# CPU session-file tests and serve/test_kv_export.py run; `nice -n 10 docker build` builds the image.  Nothing is
# pushed, tagged or changed in $STRATA_REPO.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,/^set /{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
# shellcheck source=lib.sh
. "$here/lib.sh"

ref='' archs="86;89;120" image='' dsv41=0 tests=1 build=1 target=''
extra=()
while [ $# -gt 0 ]; do
    case "$1" in
        --archs) archs=${2:?--archs needs a value}; shift 2 ;;
        --tag) image=${2:?--tag needs a value}; shift 2 ;;
        --with-dsv41) dsv41=1; shift ;;
        --skip-tests) tests=0; shift ;;
        --no-build) build=0; shift ;;
        --target) target=${2:?--target needs a value}; shift 2 ;;
        --build-arg) extra+=(--build-arg "${2:?--build-arg needs K=V}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "build: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) [ -z "$ref" ] || { echo "build: one upstream ref only" >&2; exit 2; }; ref=$1; shift ;;
    esac
done
[ -n "$ref" ] || { usage >&2; exit 2; }

# the ref names a directory below (and the rm -rf of its src/), so it is checked before anything is touched
safe=$(kvx_safe "$ref" build)
scratch=${KVX_SCRATCH:-$HOME/strata-kvx-build}/$safe
image=${image:-strata-cuda:$safe-kvx${target:+-$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '-')}}
src=$scratch/src
log() { printf '\n== kvx: %s\n' "$*"; }

# the overlay's own commit, for the image label: "dirty" when this checkout has changes, "unknown" outside git
overlay=unknown
if top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) && [ "$(cd "$top" && pwd -P)" = "$(cd "$here" && pwd -P)" ]; then
    if [ -n "$(git -C "$here" status --porcelain)" ]; then overlay=dirty; else overlay=$(git -C "$here" rev-parse HEAD); fi
fi

log "scratch checkout of $ref in $src${STRATA_REPO:+ (objects shared with $STRATA_REPO)}"
mkdir -p "$scratch"
kvx_checkout "$src" "$ref" shared
commit=$kvx_commit
echo "kvx: upstream $ref = $commit; overlay $overlay"

log "applying the overlay"
apply_args=("$src")
[ "$dsv41" = 1 ] && apply_args+=(--with-dsv41)
"$here/apply.sh" "${apply_args[@]}"
[ -z "$(git -C "$src" diff --name-only --diff-filter=U)" ] || { echo "build: conflicts left in $src" >&2; exit 1; }

date=$(git -C "$src" log -1 --format=%cI "$commit")
git -C "$src" add -A
GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date \
    git -C "$src" -c user.name=kvx -c user.email=kvx@localhost -c commit.gpgsign=false \
    commit -q --no-verify -m "kvx: kv-export on $ref$([ "$dsv41" = 1 ] && echo ' (with strata-dsv41)')" \
        -m "upstream $commit; patches $(kvx_patch_sums "$dsv41")"
built=$(git -C "$src" rev-parse HEAD)
echo "kvx: patched tree committed in the scratch checkout as $built"

if [ "$tests" = 1 ]; then
    log "CPU tests"
    kvx_tests "$src" "$scratch/bin"
fi

[ "$build" = 1 ] || { log "done (no build): $src at $built"; exit 0; }

log "docker build -> $image (archs $archs${target:+, target $target})"
cmd=(nice -n 10 docker build
     --build-arg "CUDA_ARCHITECTURES=$archs" --build-arg "STRATA_COMMIT=$built"
     --label "kvx.upstream=$ref" --label "kvx.upstream-commit=$commit" --label "kvx.commit=$built"
     --label "kvx.dsv41=$dsv41" --label "kvx.overlay=$overlay")
[ -n "$target" ] && cmd+=(--target "$target")
cmd+=("${extra[@]}" -t "$image" "$src")
printf '%q ' "${cmd[@]}"; echo
start=$SECONDS
"${cmd[@]}"
log "built $image ($(docker image inspect -f '{{.Id}}' "$image")) from $ref + kv-export in $(( (SECONDS - start) / 60 )) min"
