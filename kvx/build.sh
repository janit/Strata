#!/usr/bin/env bash
# Build a Strata image of an upstream release with kv-export injected.
#
#   kvx/build.sh <upstream-tag> [--archs "86;89;120"] [--tag <image>] [--with-dsv41] [--skip-tests]
#                [--target <stage>] [--build-arg K=V ...] [--no-build]
#
#   <upstream-tag>   a tag of upstream Strata (github.com/Niko1221/Strata), e.g. v0.2.13.1; a commit id (4-40 hex
#                    digits) works too and is fetched from upstream only when $STRATA_REPO does not have it; any
#                    other name (main) is always fetched from upstream, so it means upstream's branch, not a local one
#   --archs          CUDA_ARCHITECTURES for the image (default "86;89;120": A4000/3090, 4090, 5090)
#   --tag            image name (default strata-cuda:<upstream-tag>-kvx, or strata-cuda:<upstream-tag>-kvx-<stage>
#                    with --target, so a stage never takes the runnable image's name)
#   --with-dsv41     also apply the optional Dockerfile patch that builds strata-dsv41
#   --skip-tests     do not run the CPU tests before the build
#   --target         build only that Dockerfile stage (engine-build is the quick compile check)
#   --build-arg      passed to docker build as it is (repeatable)
#   --no-build       stop after the tests
#
# Steps: a scratch checkout of the release under $KVX_SCRATCH (default ~/strata-kvx-build/<tag>), made with
# `git clone --shared` from $STRATA_REPO (default ~/strata-fork) so no object is copied or downloaded twice; the tag
# is fetched from that repository's `origin` remote only when it is missing.  kvx/apply.sh applies the patches (a
# 3-way merge is reported; a conflict stops the build), the result is committed in the scratch clone with a fixed
# author and the release's own commit date (so the same release and patches give the same commit id, which becomes
# STRATA_COMMIT and the engine's --version build id), the CPU session-file tests and serve/test_kv_export.py run,
# and `nice -n 10 docker build` builds the image.  Nothing is pushed, tagged or changed in $STRATA_REPO.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,/^set /{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ref= archs="86;89;120" image= dsv41=0 tests=1 build=1 target=
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
        *) [ -z "$ref" ] || { echo "build: one upstream tag only" >&2; exit 2; }; ref=$1; shift ;;
    esac
done
[ -n "$ref" ] || { usage >&2; exit 2; }

# the ref names a directory below (and the rm -rf of its src/): refuse anything git would not take as a name, and
# anything whose directory name starts with a dot ("." and ".." among them)
git check-ref-format --allow-onelevel "$ref" || { echo "build: not a valid tag, branch or commit name: $ref" >&2; exit 2; }
repo=${STRATA_REPO:-$HOME/strata-fork}
safe=$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '-')
case "$safe" in .*|-*) echo "build: refusing the ref $ref (its scratch directory would be $safe)" >&2; exit 2 ;; esac
scratch=${KVX_SCRATCH:-$HOME/strata-kvx-build}/$safe
image=${image:-strata-cuda:$safe-kvx${target:+-$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '-')}}
src=$scratch/src
log() { printf '\n== kvx: %s\n' "$*"; }

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "build: $repo is not a git repository (set STRATA_REPO)" >&2; exit 2; }
upstream_url=$(git -C "$repo" remote get-url origin)

log "scratch checkout of $ref in $src (objects shared with $repo)"
rm -rf "$src"
mkdir -p "$scratch"
git clone -q --shared --no-checkout "$repo" "$src"
if git -C "$src" rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null; then
    commit=$(git -C "$src" rev-parse "refs/tags/$ref^{commit}")
elif git -C "$repo" rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null; then
    commit=$(git -C "$repo" rev-parse "refs/tags/$ref^{commit}")
elif printf '%s' "$ref" | grep -qxE '[0-9a-f]{4,40}' && local_commit=$(git -C "$repo" rev-parse -q --verify "$ref^{commit}"); then
    commit=$local_commit                    # a commit id this host has (the shared clone sees its objects)
else
    echo "kvx: $ref is not a tag or a commit in $repo; fetching it from $upstream_url"
    if git -C "$src" fetch -q --no-tags "$upstream_url" "refs/tags/$ref:refs/tags/$ref" 2>/dev/null; then
        commit=$(git -C "$src" rev-parse "refs/tags/$ref^{commit}")
    else
        git -C "$src" fetch -q --no-tags "$upstream_url" "$ref"
        commit=$(git -C "$src" rev-parse "FETCH_HEAD^{commit}")
    fi
fi
git -C "$src" -c advice.detachedHead=false checkout -q --detach "$commit"
echo "kvx: upstream $ref = $commit"

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
        -m "upstream $commit; patches $(cd "$here/patches" && sha256sum kv-export.patch $([ "$dsv41" = 1 ] && echo dsv41-dockerfile.patch) | awk '{printf "%s %.12s  ", $2, $1}')"
built=$(git -C "$src" rev-parse HEAD)
echo "kvx: patched tree committed in the scratch clone as $built"

if [ "$tests" = 1 ]; then
    log "CPU tests"
    bin=$scratch/bin; mkdir -p "$bin"
    (
        cd "$src"
        for t in conversation_file_test session_save_reclaim_test; do
            echo "-- $t"
            g++ -std=c++20 -O2 -pthread -Iinclude "src/core/$t.cpp" src/core/conversation_file.cpp -o "$bin/$t"
            "$bin/$t" | tail -n 1
        done
        echo "-- serve/test_kv_export.py"
        cd serve && python3 -m pytest -q -p no:cacheprovider test_kv_export.py 2>&1 | tail -n 3
        exit "${PIPESTATUS[0]}"
    )
fi

[ "$build" = 1 ] || { log "done (no build): $src at $built"; exit 0; }

log "docker build -> $image (archs $archs${target:+, target $target})"
cmd=(nice -n 10 docker build
     --build-arg "CUDA_ARCHITECTURES=$archs" --build-arg "STRATA_COMMIT=$built"
     --label "kvx.upstream=$ref" --label "kvx.upstream-commit=$commit" --label "kvx.commit=$built"
     --label "kvx.dsv41=$dsv41")
[ -n "$target" ] && cmd+=(--target "$target")
cmd+=("${extra[@]}" -t "$image" "$src")
printf '%q ' "${cmd[@]}"; echo
start=$SECONDS
"${cmd[@]}"
log "built $image ($(docker image inspect -f '{{.Id}}' "$image")) from $ref + kv-export in $(( (SECONDS - start) / 60 )) min"
