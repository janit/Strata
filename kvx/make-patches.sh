#!/usr/bin/env bash
# Regenerate kvx/patches/ from this branch.
#
#   kvx/make-patches.sh [<upstream-tag>] [<ref>]     write kvx/patches/*.patch
#   kvx/make-patches.sh --check [<upstream-tag>] [<ref>]
#                                                   exit 1 if the committed patches differ from what would be written
#
# <upstream-tag> is the upstream release the branch is based on (default: the tag in kvx/BASE); <ref> is the commit to
# take the change from (default HEAD).  The patches are made from commits, never from the working tree, so commit
# first; a dirty tree outside kvx/ is reported.
#
#   kv-export.patch         git diff <tag> <ref>, without kvx/ (the overlay itself) and without the Dockerfile
#   dsv41-dockerfile.patch  the Dockerfile alone (the optional strata-dsv41 build, unrelated to kv-export)
#
# --full-index keeps the whole blob ids in the patch, so `git apply --3way` can fall back to a merge on a release
# whose files moved on.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)

check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
base=${1:-$(tr -d '[:space:]' < "$here/BASE")}
ref=${2:-HEAD}

git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "make-patches: no such tag or commit: $base" >&2; exit 2; }
git -C "$repo" rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "make-patches: no such ref: $ref" >&2; exit 2; }

if [ "$ref" = HEAD ] && [ -n "$(git -C "$repo" status --porcelain --untracked-files=no -- . ':(exclude)kvx')" ]; then
    echo "make-patches: note: uncommitted changes outside kvx/ are not in the patches (they are made from $ref)" >&2
fi

diff_opts=(--no-color --no-ext-diff --no-renames --full-index --binary --src-prefix=a/ --dst-prefix=b/)
gen() {   # gen <out-dir>
    git -C "$repo" -c core.quotePath=true diff "${diff_opts[@]}" "$base" "$ref" -- . ':(exclude)kvx' ':(exclude)Dockerfile' > "$1/kv-export.patch"
    git -C "$repo" -c core.quotePath=true diff "${diff_opts[@]}" "$base" "$ref" -- Dockerfile > "$1/dsv41-dockerfile.patch"
}

if [ "$check" = 1 ]; then
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    gen "$tmp"
    rc=0
    for p in kv-export.patch dsv41-dockerfile.patch; do
        if ! cmp -s "$tmp/$p" "$here/patches/$p"; then echo "make-patches: kvx/patches/$p is out of date ($base..$ref)"; rc=1; fi
    done
    [ "$rc" = 0 ] && echo "make-patches: patches are up to date ($base..$ref)"
    exit "$rc"
fi

mkdir -p "$here/patches"
gen "$here/patches"
[ -s "$here/patches/kv-export.patch" ] || { echo "make-patches: $base..$ref has no kv-export change" >&2; exit 1; }
if [ ! -s "$here/patches/dsv41-dockerfile.patch" ]; then
    echo "make-patches: note: $base..$ref does not change the Dockerfile; dsv41-dockerfile.patch is empty" >&2
fi
for p in kv-export.patch dsv41-dockerfile.patch; do
    printf '%-24s %s\n' "$p" "$(git -C "$repo" apply --numstat "$here/patches/$p" 2>/dev/null | awk '{a+=$1; d+=$2; n++} END {printf "%d files, +%d -%d", n, a, d}')"
done
echo "make-patches: from $base..$(git -C "$repo" rev-parse --short "$ref")"
