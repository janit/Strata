#!/usr/bin/env bash
# Regenerate patches/ (and BASE, and the copy of KV-EXPORT.md) from a dev checkout made by ./dev.sh.
#
#   ./make-patches.sh <dev-dir>              write patches/*.patch
#   ./make-patches.sh --check <dev-dir>      exit 1 if anything here differs from what would be written
#
#   kv-export.patch         git diff <base> HEAD in the dev checkout, without the Dockerfile
#   dsv41-dockerfile.patch  the Dockerfile alone (the optional strata-dsv41 build, unrelated to kv-export); only from
#                           a checkout made with --with-dsv41, else kept as it is (and such a checkout must leave the
#                           Dockerfile alone)
#   BASE                    the upstream ref the dev checkout was made from, when it differs (a branch name is
#                           written as its commit id, since a branch moves)
#   KV-EXPORT.md            a copy of the one the patch carries, for reading the contract without applying it
#
# <base> is the upstream commit dev.sh recorded (.git/kvx/base).  The patches are made from commits, never from the
# working tree, so a dev checkout with uncommitted or untracked files is refused: commit first.  --full-index keeps
# the whole blob ids in the patch, so `git apply --3way` can fall back to a merge on a release whose files moved on.
# Every option that shapes a diff is pinned here (context, algorithm, prefixes, order, the attributes file that could
# name a diff driver, GIT_DIFF_OPTS, ...), so the patches depend on the commits alone, never on the user's git config
# or environment.  .git/info/attributes cannot be switched off from the command line, so a checkout with one is
# refused.  They are written to a temporary directory and moved into
# patches/ only when kv-export.patch is not empty.
set -euo pipefail
unset GIT_DIFF_OPTS     # it overrides -U3

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,/^set /{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

check=0 dev=
for a in "$@"; do
    case "$a" in
        --check) check=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "make-patches: unknown option $a" >&2; exit 2 ;;
        *) [ -z "$dev" ] || { echo "make-patches: one dev checkout only" >&2; exit 2; }; dev=$a ;;
    esac
done
[ -n "$dev" ] || { usage >&2; exit 2; }
[ -d "$dev" ] || { echo "make-patches: no such directory: $dev" >&2; exit 2; }
dev=$(cd "$dev" && pwd -P)
gd=$(git -C "$dev" rev-parse --absolute-git-dir 2>/dev/null) && [ -f "$gd/kvx/base" ] && [ -f "$gd/kvx/base-ref" ] ||
    { echo "make-patches: $dev is not a dev checkout made by ./dev.sh (no .git/kvx/base)" >&2; exit 2; }
top=$(git -C "$dev" rev-parse --show-toplevel)
[ "$(cd "$top" && pwd -P)" = "$dev" ] || { echo "make-patches: $dev is not the top of its checkout ($top is)" >&2; exit 2; }

base=$(tr -d '[:space:]' < "$gd/kvx/base")
base_ref=$(tr -d '[:space:]' < "$gd/kvx/base-ref")
dsv41=$(tr -d '[:space:]' 2>/dev/null < "$gd/kvx/dsv41" || echo 1)
git -C "$dev" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "make-patches: the base $base is not in $dev" >&2; exit 2; }
git -C "$dev" merge-base --is-ancestor "$base" HEAD ||
    { echo "make-patches: HEAD of $dev does not descend from its base $base_ref ($base)" >&2; exit 2; }
if [ -s "$gd/info/attributes" ]; then
    echo "make-patches: $gd/info/attributes exists and can change the patches (a diff driver rewrites hunk headers);" >&2
    echo "  move it aside while making the patches" >&2
    exit 2
fi
if [ -n "$(git -C "$dev" status --porcelain)" ]; then
    echo "make-patches: $dev has uncommitted or untracked files; the patches are made from HEAD, so commit first:" >&2
    git -C "$dev" status --short | sed 's/^/    /' >&2
    exit 1
fi

# BASE names the release: a tag or a commit id as it is, a branch (main) as the commit, since a branch moves
if git -C "$dev" rev-parse -q --verify "refs/tags/$base_ref^{commit}" >/dev/null ||
   printf '%s' "$base_ref" | grep -qxE '[0-9a-f]{40}'; then new_base=$base_ref; else new_base=$base; fi
old_base=$(tr -d '[:space:]' < "$here/BASE")

git_opts=(-c core.quotePath=true -c core.attributesFile=/dev/null -c diff.context=3 -c diff.interHunkContext=0 -c diff.algorithm=myers
          -c diff.indentHeuristic=true -c diff.suppressBlankEmpty=false -c diff.noprefix=false
          -c diff.mnemonicPrefix=false -c diff.relative=false -c diff.orderFile=/dev/null)
diff_opts=(--no-color --no-ext-diff --no-textconv --no-renames --full-index --binary --src-prefix=a/ --dst-prefix=b/
           -U3 --inter-hunk-context=0 --diff-algorithm=myers --indent-heuristic --no-relative -O/dev/null)
gen() {   # gen <out-dir>
    git -C "$dev" "${git_opts[@]}" diff "${diff_opts[@]}" "$base" HEAD -- . ':(exclude)Dockerfile' > "$1/kv-export.patch"
    git -C "$dev" "${git_opts[@]}" diff "${diff_opts[@]}" "$base" HEAD -- Dockerfile > "$1/dsv41-dockerfile.patch"
    git -C "$dev" show HEAD:KV-EXPORT.md > "$1/KV-EXPORT.md" 2>/dev/null || : > "$1/KV-EXPORT.md"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
gen "$tmp"
outputs=(kv-export.patch)
if [ "$dsv41" = 1 ]; then
    outputs+=(dsv41-dockerfile.patch)
elif [ -s "$tmp/dsv41-dockerfile.patch" ]; then
    echo "make-patches: $dev was made without --with-dsv41 but its commits change the Dockerfile; kv-export does not" >&2
    echo "  touch the Dockerfile, so take that change out, or make the checkout with --with-dsv41" >&2
    exit 1
fi

if [ "$check" = 1 ]; then
    rc=0
    for p in "${outputs[@]}"; do
        cmp -s "$tmp/$p" "$here/patches/$p" || { echo "make-patches: patches/$p is out of date ($base_ref..HEAD)"; rc=1; }
    done
    [ "$new_base" = "$old_base" ] || { echo "make-patches: BASE is $old_base, the dev checkout is on $new_base"; rc=1; }
    if [ -s "$tmp/KV-EXPORT.md" ] && ! cmp -s "$tmp/KV-EXPORT.md" "$here/KV-EXPORT.md"; then
        echo "make-patches: KV-EXPORT.md differs from the one in the patch"; rc=1
    fi
    [ "$dsv41" = 1 ] || echo "make-patches: note: made without --with-dsv41, so dsv41-dockerfile.patch was not checked"
    [ "$rc" = 0 ] && echo "make-patches: patches are up to date ($base_ref..HEAD)"
    exit "$rc"
fi

# dsv41-dockerfile.patch is kept only while BASE stays: kept across a move, it would still be made against the old
# release, whose Dockerfile blob a 3-way merge on the new one (fetched with BASE alone) would not have
if [ "$dsv41" != 1 ] && [ "$new_base" != "$old_base" ]; then
    echo "make-patches: $dev is on $new_base, BASE is $old_base, and the checkout was made without --with-dsv41, so" >&2
    echo "  dsv41-dockerfile.patch would stay made against $old_base; make the checkout with --with-dsv41 to move BASE" >&2
    exit 1
fi
# an empty kv-export.patch (nothing committed on the base) never replaces the committed one
[ -s "$tmp/kv-export.patch" ] || { echo "make-patches: $base_ref..HEAD has no kv-export change; patches/ left as it was" >&2; exit 1; }
mkdir -p "$here/patches"
for p in "${outputs[@]}"; do mv -f "$tmp/$p" "$here/patches/$p"; done
if [ "$dsv41" = 1 ] && [ ! -s "$here/patches/dsv41-dockerfile.patch" ]; then
    echo "make-patches: note: $base_ref..HEAD does not change the Dockerfile; dsv41-dockerfile.patch is empty" >&2
fi
[ "$dsv41" = 1 ] || echo "make-patches: note: made without --with-dsv41; dsv41-dockerfile.patch kept as it was"
if [ -s "$tmp/KV-EXPORT.md" ]; then cp "$tmp/KV-EXPORT.md" "$here/KV-EXPORT.md"; fi
if [ "$new_base" != "$old_base" ]; then
    printf '%s\n' "$new_base" > "$here/BASE"
    echo "make-patches: BASE $old_base -> $new_base"
fi
for p in kv-export.patch dsv41-dockerfile.patch; do
    printf '%-24s %s\n' "$p" "$(git -C "$dev" apply --numstat "$here/patches/$p" 2>/dev/null | awk '{a+=$1; d+=$2; n++} END {printf "%d files, +%d -%d", n, a, d}')"
done
echo "make-patches: from $base_ref ($(git -C "$dev" rev-parse --short "$base"))..$(git -C "$dev" rev-parse --short HEAD) of $dev"
