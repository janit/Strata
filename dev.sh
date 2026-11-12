#!/usr/bin/env bash
# Make a development checkout: upstream Strata at <upstream-ref> with the overlay applied as one commit.
#
#   ./dev.sh <upstream-ref> [<dir>] [--with-dsv41]
#   ./dev.sh --test <dir>                     run the CPU tests in an existing dev checkout
#
#   <upstream-ref>   a tag (v0.2.14), a branch of upstream (main) or a commit id, as for build.sh
#   <dir>            where the checkout goes (default $KVX_DEV/<upstream-ref>, KVX_DEV default ~/strata-kvx-dev);
#                    it must not exist, or be empty
#   --with-dsv41     also apply dsv41-dockerfile.patch, so make-patches.sh regenerates it too (without it the
#                    checkout leaves the Dockerfile as upstream has it, and make-patches.sh keeps that patch as it is)
#
# The checkout is a git repository on branch kvx-dev: upstream's own commit for <upstream-ref> is the base (tag
# kvx-base, and recorded in .git/kvx-base, with the ref's name in .git/kvx-base-ref), and on it one commit,
# "kv-export overlay", made by ./apply.sh.  Develop there: edit, commit, run `./dev.sh --test <dir>`, then
# `./make-patches.sh <dir>` writes the commits since the base back into patches/.  A remote `upstream` points at
# $STRATA_UPSTREAM.  STRATA_REPO, when set, is cloned from instead of downloading what it has (a copy, not shared).
#
# When the patches do not apply as they are, apply.sh merges them 3-way; on a conflict this stops with the conflict
# markers in place: resolve them, `git add` the files, `git commit -m "kv-export overlay"`, then test and
# make-patches.sh as above.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,/^set /{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
# shellcheck source=lib.sh
. "$here/lib.sh"

ref='' dir='' dsv41=0 test=0
for a in "$@"; do
    case "$a" in
        --with-dsv41) dsv41=1 ;;
        --test) test=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "dev: unknown option $a" >&2; usage >&2; exit 2 ;;
        *) if [ "$test" = 1 ] && [ -z "$dir" ]; then dir=$a
           elif [ -z "$ref" ] && [ "$test" = 0 ]; then ref=$a
           elif [ -z "$dir" ]; then dir=$a
           else echo "dev: too many arguments" >&2; exit 2; fi ;;
    esac
done

if [ "$test" = 1 ]; then
    [ -n "$dir" ] && [ -z "$ref" ] || { echo "usage: ./dev.sh --test <dir>" >&2; exit 2; }
    gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) && [ -f "$gd/kvx-base" ] ||
        { echo "dev: $dir is not a dev checkout made by dev.sh (no .git/kvx-base)" >&2; exit 2; }
    kvx_tests "$(cd "$dir" && pwd)" "$gd/kvx-bin"
    exit
fi

[ -n "$ref" ] || { usage >&2; exit 2; }
safe=$(kvx_safe "$ref" dev)
dir=${dir:-${KVX_DEV:-$HOME/strata-kvx-dev}/$safe}
if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
    echo "dev: $dir exists and is not empty; pick another directory or remove it" >&2; exit 2
fi
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)

echo "== kvx: upstream $ref in $dir"
kvx_checkout "$dir" "$ref" own
base=$kvx_commit
git -C "$dir" checkout -q -b kvx-dev
git -C "$dir" tag -f kvx-base "$base" >/dev/null
git -C "$dir" remote remove origin 2>/dev/null || true     # $STRATA_REPO, when cloned from: not a place to push to
git -C "$dir" remote add upstream "$kvx_upstream"
gd=$(git -C "$dir" rev-parse --absolute-git-dir)
printf '%s\n' "$base" > "$gd/kvx-base"
printf '%s\n' "$ref" > "$gd/kvx-base-ref"
printf '%s\n' "$dsv41" > "$gd/kvx-dsv41"
echo "kvx: base $ref = $base (tag kvx-base)"

echo "== kvx: applying the overlay"
apply_args=("$dir")
[ "$dsv41" = 1 ] && apply_args+=(--with-dsv41)
rc=0
"$here/apply.sh" "${apply_args[@]}" || rc=$?
if [ "$rc" != 0 ]; then
    echo "dev: the overlay did not go in cleanly (see above).  In $dir: resolve the conflicts, git add the files," >&2
    echo "  git commit -m 'kv-export overlay', then $here/dev.sh --test $dir and $here/make-patches.sh $dir" >&2
    exit "$rc"
fi

who=()
[ -n "$(git -C "$dir" config user.name || true)" ] || who+=(-c user.name=kvx)
[ -n "$(git -C "$dir" config user.email || true)" ] || who+=(-c user.email=kvx@localhost)
git -C "$dir" add -A
git -C "$dir" "${who[@]}" commit -q --no-verify -m "kv-export overlay" \
    -m "patches $(kvx_patch_sums "$dsv41")on upstream $ref ($base)"
echo "kvx: overlay committed as $(git -C "$dir" rev-parse --short HEAD) on branch kvx-dev"
cat <<EOF

Next: edit and commit in $dir, then
  $here/dev.sh --test $dir
  $here/make-patches.sh $dir
EOF
