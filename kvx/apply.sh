#!/usr/bin/env bash
# Apply the kv-export overlay to a Strata source tree.
#
#   kvx/apply.sh <strata-source-dir> [--with-dsv41] [--check]
#
#   --with-dsv41   also apply patches/dsv41-dockerfile.patch (the optional strata-dsv41 build in the Dockerfile)
#   --check        only report whether the patches would apply; change nothing
#
# In a git checkout (the directory is the top of a work tree) a patch that does not apply as it is is retried with
# `git apply --3way`, which merges against the blobs the patch names; a 3-way merge that conflicts leaves the usual
# conflict markers in the files and the index, and this script lists them.  Anywhere else the patch is applied plainly
# (all or nothing) and the files whose hunks do not fit are listed.
#
# Exit status: 0 applied (cleanly or by 3-way merge, which is said), 1 conflicts or hunks that do not fit, 2 usage.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir= dsv41=0 check=0 status=0
for a in "$@"; do
    case "$a" in
        --with-dsv41) dsv41=1 ;;
        --check) check=1 ;;
        -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "apply: unknown option $a" >&2; exit 2 ;;
        *) [ -z "$dir" ] || { echo "apply: one source directory only" >&2; exit 2; }; dir=$a ;;
    esac
done
[ -n "$dir" ] || { echo "usage: kvx/apply.sh <strata-source-dir> [--with-dsv41] [--check]" >&2; exit 2; }
[ -d "$dir" ] || { echo "apply: no such directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd)
[ -f "$dir/src/program/generate.cpp" ] && [ -f "$dir/serve/server.py" ] ||
    { echo "apply: $dir does not look like a Strata source tree (no src/program/generate.cpp, serve/server.py)" >&2; exit 2; }

patches=("$here/patches/kv-export.patch")
[ "$dsv41" = 1 ] && patches+=("$here/patches/dsv41-dockerfile.patch")

is_git=0
if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [ "$(cd "$top" && pwd)" = "$dir" ]; then is_git=1; fi

# the files a failed `git apply` names ("error: patch failed: F:L", "error: F: does not exist in index", ...)
failed_files() { sed -n -e 's/^error: patch failed: \(.*\):[0-9][0-9]*$/\1/p' -e 's/^error: \([^:]*\): .*$/\1/p' | sort -u; }

for p in "${patches[@]}"; do
    name=$(basename "$p")
    [ -f "$p" ] || { echo "apply: missing $p (run kvx/make-patches.sh)" >&2; exit 2; }
    if [ ! -s "$p" ]; then echo "apply: $name is empty, skipped"; continue; fi
    if [ "$is_git" = 1 ]; then
        if out=$(git -C "$dir" apply --check "$p" 2>&1); then
            [ "$check" = 1 ] && { echo "apply: $name: applies cleanly"; continue; }
            git -C "$dir" apply "$p"
            echo "apply: $name: applied cleanly"
            continue
        fi
        if [ "$check" = 1 ]; then
            # a 3-way trial in a throwaway index holding HEAD (--cached: the work tree is not touched; a conflict is
            # left at higher stages of that index, where ls-files -u finds it)
            tmpidx=$(mktemp); rm -f "$tmpidx"
            GIT_INDEX_FILE=$tmpidx git -C "$dir" read-tree HEAD
            if out3=$(GIT_INDEX_FILE=$tmpidx git -C "$dir" apply --3way --cached "$p" 2>&1); then
                echo "apply: $name: does not apply as it is; applies with a 3-way merge (against HEAD) to:"
                printf '%s\n' "$out" | failed_files | sed 's/^/  /'
            else
                conflicts=$(GIT_INDEX_FILE=$tmpidx git -C "$dir" ls-files -u | cut -f2 | sort -u)
                status=1
                echo "apply: $name: CONFLICTS in a 3-way merge (against HEAD):"
                printf '%s\n' "$conflicts" | sed '/^$/d; s/^/  conflict: /'
                printf '%s\n' "$out3" | failed_files | grep -vxF -f <(printf '%s\n' "$conflicts") | sed 's/^/  no merge possible: /' || true
            fi
            rm -f "$tmpidx"
            continue
        fi
        if out3=$(git -C "$dir" apply --3way "$p" 2>&1); then
            echo "apply: $name: did not apply as it is; applied with a 3-way merge:"
            printf '%s\n' "$out" | failed_files | sed 's/^/  merged: /'
            continue
        fi
        conflicts=$(git -C "$dir" diff --name-only --diff-filter=U)
        echo "apply: $name: CONFLICTS - the 3-way merge stopped." >&2
        if [ -n "$conflicts" ]; then
            echo "  files with conflict markers (resolve, then git add):" >&2
            printf '%s\n' "$conflicts" | sed 's/^/    /' >&2
        fi
        nomerge=$(printf '%s\n' "$out3" | failed_files | grep -vxF -f <(printf '%s\n' "$conflicts") || true)
        if [ -n "$nomerge" ]; then
            echo "  files that could not be merged at all (blob unknown here, or the file is gone):" >&2
            printf '%s\n' "$nomerge" | sed 's/^/    /' >&2
        fi
        echo "  see kvx/README.md, 'On a conflict'.  git output:" >&2
        printf '%s\n' "$out3" | sed 's/^/    | /' >&2
        exit 1
    else
        # not a git checkout: plain apply, all or nothing; GIT_CEILING_DIRECTORIES keeps git from finding a repository
        # above the directory (which would make the paths relative to that repository instead)
        if out=$(cd "$dir" && GIT_CEILING_DIRECTORIES=$(dirname "$dir") git apply --check "$p" 2>&1); then
            [ "$check" = 1 ] && { echo "apply: $name: applies cleanly"; continue; }
            (cd "$dir" && GIT_CEILING_DIRECTORIES=$(dirname "$dir") git apply "$p")
            echo "apply: $name: applied cleanly"
            continue
        fi
        echo "apply: $name: does NOT apply to $dir (not a git checkout, so no 3-way merge); nothing was changed." >&2
        echo "  files whose hunks do not fit:" >&2
        printf '%s\n' "$out" | failed_files | sed 's/^/    /' >&2
        echo "  use a git checkout of the release for a 3-way merge; see kvx/README.md, 'On a conflict'." >&2
        [ "$check" = 1 ] && { status=1; continue; }
        exit 1
    fi
done
exit "$status"
