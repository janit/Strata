# Shared by build.sh and dev.sh (sourced, not run): where upstream is, how a ref is checked out, the CPU tests.
# The sourcing script sets $here (the overlay checkout) and runs under `set -euo pipefail`.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # $here comes from the sourcing script, which reads $kvx_commit

kvx_upstream=${STRATA_UPSTREAM:-https://github.com/Niko1221/Strata.git}
kvx_base=$(tr -d '[:space:]' < "$here/BASE")

# kvx_safe <ref> <who>: refuse anything git would not take as a name, and anything whose directory name would start
# with a dot or a dash ("." and ".." among them); print the directory-safe spelling of the ref
kvx_safe() {
    local safe
    git check-ref-format --allow-onelevel "$1" || { echo "$2: not a valid tag, branch or commit name: $1" >&2; return 2; }
    safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
    case "$safe" in .*|-*) echo "$2: refusing the ref $1 (its directory would be $safe)" >&2; return 2 ;; esac
    printf '%s\n' "$safe"
}

# kvx_fetch <src> <ref> <depth-args...>: fetch a tag, a branch or a full commit id from upstream into <src>; prints
# the commit.  A tag is tried first and kept as refs/tags/<ref>; anything else is fetched as it is (FETCH_HEAD).
kvx_fetch() {
    local src=$1 ref=$2; shift 2
    if git -C "$src" fetch -q "$@" --no-tags "$kvx_upstream" "+refs/tags/$ref:refs/tags/$ref" 2>/dev/null; then
        git -C "$src" rev-parse "refs/tags/$ref^{commit}"
    elif git -C "$src" fetch -q "$@" --no-tags "$kvx_upstream" "$ref"; then
        git -C "$src" rev-parse "FETCH_HEAD^{commit}"
    else
        echo "kvx: $ref is not a tag, branch or commit of $kvx_upstream (a commit id needs all 40 digits unless" >&2
        echo "  \$STRATA_REPO has it)" >&2
        return 1
    fi
}

# kvx_checkout <src> <ref> <shared|own>: a fresh git checkout of upstream <ref> in <src> (removed first), detached at
# the commit, which is left in $kvx_commit.
#
# A tag or a branch is always resolved by upstream ($kvx_upstream), so it means upstream's tag or branch and nothing
# else.  $STRATA_REPO (a local Strata clone, optional) only supplies objects: the checkout is cloned from it without
# its tags or branches, `shared` borrowing its objects (git clone --shared: nothing copied, for a throwaway scratch
# tree) and `own` taking a local copy (hard links where it can) that survives anything done to $STRATA_REPO, and the
# ref is then fetched from upstream into it, which downloads only what $STRATA_REPO lacks.  A commit id is a content
# address rather than a name: one that $STRATA_REPO has (4 to 40 hex digits) is used from it without asking upstream;
# otherwise it is fetched from upstream and needs all 40 digits.  Without $STRATA_REPO the ref is fetched with
# --depth 1.  Either way the BASE release is fetched too when it is missing, so `git apply --3way` finds the blobs the
# patches were made against.
kvx_checkout() {
    local src=$1 ref=$2 mode=$3 repo=${STRATA_REPO:-} depth=() c=
    rm -rf "$src"
    if [ -n "$repo" ]; then
        git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "kvx: STRATA_REPO=$repo is not a git repository" >&2; return 2; }
        if [ "$mode" = shared ]; then git clone -q --shared --no-checkout --no-tags "$repo" "$src"
        else git clone -q --no-checkout --no-tags "$repo" "$src"; fi
        git -C "$src" remote remove origin     # its branches are not upstream's; only its objects are used
        if printf '%s' "$ref" | grep -qxE '[0-9a-f]{4,40}' && c=$(git -C "$src" rev-parse -q --verify "$ref^{commit}"); then
            echo "kvx: $ref is a commit in $repo ($c)"
        else
            c=
        fi
    else
        mkdir -p "$src"
        git init -q "$src"
        depth=(--depth 1)
    fi
    # the files checked out and later committed must not depend on the user's git config: no line-ending conversion,
    # no attributes file (filters, eol) and, in a scratch tree, no global ignore list keeping a new file out of the commit
    git -C "$src" config core.autocrlf false
    git -C "$src" config core.attributesFile /dev/null
    [ "$mode" = own ] || git -C "$src" config core.excludesFile /dev/null
    if [ -z "$c" ]; then
        echo "kvx: fetching $ref from $kvx_upstream${depth[*]:+ (${depth[*]})}"
        c=$(kvx_fetch "$src" "$ref" "${depth[@]}")
    fi
    if ! git -C "$src" rev-parse -q --verify "$kvx_base^{commit}" >/dev/null &&
       ! git -C "$src" rev-parse -q --verify "refs/tags/$kvx_base^{commit}" >/dev/null; then
        echo "kvx: fetching BASE $kvx_base too (the blobs a 3-way merge of the patches needs)"
        kvx_fetch "$src" "$kvx_base" "${depth[@]}" >/dev/null ||
            echo "kvx: note: no $kvx_base; a patch that does not apply as it is cannot fall back to a 3-way merge" >&2
    fi
    git -C "$src" -c advice.detachedHead=false checkout -q --detach "$c"
    kvx_commit=$c
}

# kvx_patch_sums <dsv41>: "kv-export.patch 0123456789ab  ..." for commit messages
kvx_patch_sums() {
    local files=(kv-export.patch)
    [ "$1" = 1 ] && files+=(dsv41-dockerfile.patch)
    (cd "$here/patches" && sha256sum "${files[@]}") |
        awk '{printf "%s %.12s  ", $2, $1}'
}

# kvx_tests <src> <bin-dir>: the CPU session-file tests and serve/test_kv_export.py, on a patched tree
kvx_tests() {
    local src=$1 bin=$2
    mkdir -p "$bin"
    (
        cd "$src" || exit
        for t in conversation_file_test session_save_reclaim_test; do
            echo "-- $t"
            g++ -std=c++20 -O2 -pthread -Iinclude "src/core/$t.cpp" src/core/conversation_file.cpp -o "$bin/$t"
            "$bin/$t" | tail -n 1
        done
        echo "-- serve/test_kv_export.py"
        cd serve && python3 -m pytest -q -p no:cacheprovider test_kv_export.py 2>&1 | tail -n 3
        exit "${PIPESTATUS[0]}"
    )
}
