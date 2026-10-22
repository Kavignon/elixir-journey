#!/bin/sh
# Adoption requires the alias/plugin/test audit in ../README.md.
set -eu
usage() { echo 'usage: scripts/verify.sh fast|full'; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in fast|full) mode=$1 ;; *) usage >&2; exit 2 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
[ -f mix.exs ] || { echo 'BLOCKED: no mix.exs at the script installation root' >&2; exit 2; }
for tool in git mix; do
    command -v "$tool" >/dev/null 2>&1 || { echo "BLOCKED: missing $tool" >&2; exit 3; }
done
head=$(git rev-parse --verify HEAD 2>/dev/null) || { echo 'BLOCKED: verification requires a Git checkout with HEAD' >&2; exit 3; }
fingerprint() {
    changes=$(git diff --no-ext-diff --no-textconv --binary HEAD -- .) || return 1
    printf '%s' "$changes" | git hash-object --stdin
}
before=$(fingerprint)
echo "HEAD context: $head (not a commit-verification claim)"
echo 'Scope: working-tree inputs; NOT the staged snapshot. Untracked files may affect checks.'
state=$(git status --short --untracked-files=normal -- .)
if [ -n "$state" ]; then
    echo 'WARNING: dirty/untracked inputs; staged and unstaged changes may differ:' >&2
    printf '%s\n' "$state" >&2
fi
if ! git diff --quiet -- . && ! git diff --cached --quiet -- .; then
    echo 'WARNING: staged AND unstaged changes; partial staging is not verified.' >&2
fi
finish() {
    result=$?
    trap - EXIT
    after=$(fingerprint) || { echo 'FAIL: could not fingerprint tracked inputs' >&2; exit 1; }
    after_head=$(git rev-parse --verify HEAD) || exit 1
    if [ "$before" != "$after" ] || [ "$head" != "$after_head" ]; then
        echo 'FAIL: tracked inputs or HEAD changed during verification; no files restored.' >&2
        result=1
    fi
    echo "Gate $mode exit=$result; evidence applies to working-tree inputs only."
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run() {
    printf 'RUN'; printf ' %s' "$@"; printf '\n'
    if "$@"; then
        echo 'RESULT exit=0'
    else
        result=$?
        echo "RESULT exit=$result" >&2
        exit "$result"
    fi
}
run env MIX_ENV=dev mix format --check-formatted
run env MIX_ENV=dev mix compile --warnings-as-errors
if [ "$mode" = full ]; then
    run env MIX_ENV=test mix test
fi
