#!/usr/bin/env bash
# Apply the kv-export overlay to a Strata source tree.
#
#   kvx/apply.sh <strata-source-dir> [--with-dsv41] [--check]
#
#   --with-dsv41   also apply patches/dsv41-dockerfile.patch (the optional strata-dsv41 build in the Dockerfile)
#   --check        only report whether the patches would apply; change nothing
#
# Every selected patch is checked before any is applied, so a patch that does not fit leaves the tree as it was (the
# other patch included).  A patch the tree already carries is said so and skipped.  In a git checkout (the directory
# is the top of a work tree) a patch that does not apply as it is is retried with `git apply --3way`, which merges
# against the blobs the patch names; that needs the files it touches to have no uncommitted edits (checked first).
# A 3-way merge that conflicts leaves the usual conflict markers in the files and the index, and this script lists
# them.  Anywhere else there is no 3-way merge, and the files whose hunks do not fit are listed.
#
# Exit status: 0 applied (cleanly or by 3-way merge, which is said) or already applied, 1 conflicts, hunks that do
# not fit or uncommitted edits in the way, 2 usage (or an empty kv-export.patch).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir= dsv41=0 check=0 status=0
for a in "$@"; do
    case "$a" in
        --with-dsv41) dsv41=1 ;;
        --check) check=1 ;;
        -h|--help) sed -n '2,/^set /{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "apply: unknown option $a" >&2; exit 2 ;;
        *) [ -z "$dir" ] || { echo "apply: one source directory only" >&2; exit 2; }; dir=$a ;;
    esac
done
[ -n "$dir" ] || { echo "usage: kvx/apply.sh <strata-source-dir> [--with-dsv41] [--check]" >&2; exit 2; }
[ -d "$dir" ] || { echo "apply: no such directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)      # physical, as git reports its top level (a symlinked path is still a git checkout)
[ -f "$dir/src/program/generate.cpp" ] && [ -f "$dir/serve/server.py" ] ||
    { echo "apply: $dir does not look like a Strata source tree (no src/program/generate.cpp, serve/server.py)" >&2; exit 2; }

patches=("$here/patches/kv-export.patch")
[ "$dsv41" = 1 ] && patches+=("$here/patches/dsv41-dockerfile.patch")

is_git=0
if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [ "$(cd "$top" && pwd -P)" = "$dir" ]; then is_git=1; fi

# git apply on the tree: in a git checkout against its index; elsewhere plainly, with GIT_CEILING_DIRECTORIES keeping
# git from finding a repository above the directory (which would make the paths relative to that repository instead)
ga() {
    if [ "$is_git" = 1 ]; then git -C "$dir" apply "$@"
    else (cd "$dir" && GIT_CEILING_DIRECTORIES=$(dirname "$dir") git apply "$@"); fi
}

# the files a failed `git apply` names ("error: patch failed: F:L", "error: F: does not exist in index", ...)
failed_files() { sed -n -e 's/^error: patch failed: \(.*\):[0-9][0-9]*$/\1/p' -e 's/^error: \([^:]*\): .*$/\1/p' | sort -u; }

# the files of a patch (git checkout only) that have uncommitted edits, or are untracked but in the patch's way
dirty_files() {   # dirty_files <patch>
    local f
    git -C "$dir" apply --numstat "$1" | cut -f3- | while IFS= read -r f; do
        if git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
            git -C "$dir" diff --quiet -- "$f" || echo "$f"
        elif [ -e "$dir/$f" ] || [ -L "$dir/$f" ]; then
            echo "$f (untracked)"
        fi
    done
}

# pass 1: what each patch is to this tree - clean (applies as it is), applied (already in it), or nofit
names=() states=() outs=() paths=()
for p in "${patches[@]}"; do
    name=$(basename "$p")
    [ -f "$p" ] || { echo "apply: missing $p (run kvx/make-patches.sh)" >&2; exit 2; }
    if [ ! -s "$p" ]; then
        # an empty kv-export.patch is a broken overlay, never "nothing to do": the image would carry no kv-export
        [ "$name" = kv-export.patch ] && { echo "apply: $p is empty (run kvx/make-patches.sh)" >&2; exit 2; }
        echo "apply: $name is empty, skipped"
        continue
    fi
    if out=$(ga --check "$p" 2>&1); then state=clean
    elif ga --reverse --check "$p" >/dev/null 2>&1; then state=applied
    else state=nofit
    fi
    names+=("$name") states+=("$state") outs+=("$out") paths+=("$p")
done

# pass 2: anything that stops the run before a file is changed
stop=0
for i in "${!names[@]}"; do
    [ "${states[$i]}" = nofit ] || continue
    name=${names[$i]} p=${paths[$i]}
    if [ "$is_git" = 0 ]; then
        echo "apply: ${name}: does NOT apply to $dir (not a git checkout, so no 3-way merge)." >&2
        echo "  files whose hunks do not fit:" >&2
        printf '%s\n' "${outs[$i]}" | failed_files | sed 's/^/    /' >&2
        echo "  use a git checkout of the release for a 3-way merge; see kvx/README.md, 'On a conflict'." >&2
        stop=1
        continue
    fi
    dirty=$(dirty_files "$p")
    if [ -n "$dirty" ]; then
        echo "apply: ${name}: does not apply as it is, and a 3-way merge needs the files it touches to have no" >&2
        echo "  uncommitted edits; commit or stash these, then run again:" >&2
        printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        stop=1
    fi
done
if [ "$stop" = 1 ]; then
    if [ "$check" = 1 ]; then status=1; else echo "apply: nothing was changed." >&2; exit 1; fi
fi

# pass 3: apply (or, with --check, report)
for i in "${!names[@]}"; do
    name=${names[$i]} p=${paths[$i]} out=${outs[$i]}
    case "${states[$i]}" in
        applied) echo "apply: ${name}: already applied to this tree; nothing to do"; continue ;;
        clean)
            [ "$check" = 1 ] && { echo "apply: ${name}: applies cleanly"; continue; }
            ga "$p"
            echo "apply: ${name}: applied cleanly"
            continue ;;
    esac
    [ "$is_git" = 1 ] || continue                   # reported in pass 2
    [ "$stop" = 1 ] && continue                     # --check only (else pass 2 exited): reported there
    # a 3-way trial in throwaway copies of the index (--cached: the work tree is not touched, and pass 2 found the
    # files the patch touches to match the index, so the real run starts from what the trial starts from); a
    # conflict is left at higher stages of that index, where ls-files -u finds it.  A trial that leaves the tree as
    # it was means the overlay is in already (merged before, so the reverse check above did not match it)
    tmpidx=$(mktemp); rm -f "$tmpidx"; orgidx=$(mktemp); rm -f "$orgidx"
    idx=$(git -C "$dir" rev-parse --path-format=absolute --git-path index)
    if [ -f "$idx" ]; then cp "$idx" "$orgidx"; else GIT_INDEX_FILE=$orgidx git -C "$dir" read-tree HEAD; fi
    cp "$orgidx" "$tmpidx"
    trial=0
    if out3=$(GIT_INDEX_FILE=$tmpidx git -C "$dir" apply --3way --cached "$p" 2>&1); then
        trial=1
        if [ "$(GIT_INDEX_FILE=$tmpidx git -C "$dir" write-tree 2>/dev/null)" = \
             "$(GIT_INDEX_FILE=$orgidx git -C "$dir" write-tree 2>/dev/null || echo unwritable)" ]; then
            trial=same
        fi
    else
        conflicts=$(GIT_INDEX_FILE=$tmpidx git -C "$dir" ls-files -u | cut -f2 | sort -u)
    fi
    rm -f "$tmpidx" "$orgidx"
    if [ "$trial" = same ]; then
        echo "apply: ${name}: already in this tree (a 3-way merge changes nothing); nothing to do"
        continue
    fi
    if [ "$check" = 1 ]; then
        if [ "$trial" = 1 ]; then
            echo "apply: ${name}: does not apply as it is; applies with a 3-way merge to:"
            printf '%s\n' "$out" | failed_files | sed 's/^/  /'
        else
            status=1
            echo "apply: ${name}: CONFLICTS in a 3-way merge:"
            printf '%s\n' "$conflicts" | sed '/^$/d; s/^/  conflict: /'
            printf '%s\n' "$out3" | failed_files | grep -vxF -f <(printf '%s\n' "$conflicts") | sed 's/^/  no merge possible: /' || true
        fi
        continue
    fi
    if out3=$(git -C "$dir" apply --3way "$p" 2>&1); then
        echo "apply: ${name}: did not apply as it is; applied with a 3-way merge:"
        printf '%s\n' "$out" | failed_files | sed 's/^/  merged: /'
        continue
    fi
    conflicts=$(git -C "$dir" diff --name-only --diff-filter=U)
    echo "apply: ${name}: CONFLICTS - the 3-way merge stopped." >&2
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
done
exit "$status"
