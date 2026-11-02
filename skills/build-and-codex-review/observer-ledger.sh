#!/bin/sh
# observer-ledger.sh — bookkeeping the review-loop observer needs across runs. A run is one
# build-and-review or continue invocation; LOOP_DIR is the stable dir holding HANDOFF.md.
#
#   snapshot LOOP_DIR                 -> record the tree about to be reviewed; print the run number
#   landed LOOP_DIR                   -> list findings that sit in code the loop itself wrote
#   decide LOOP_DIR KIND "class" "note"
#                                     -> record the human's call on a class
#                                        (KIND: adopted | smaller-fix | accepted)
#
# Shared by build-and-codex-review and codex-build-and-review. POSIX sh + awk + git.

set -eu

die() { echo "observer-ledger: $*" >&2; exit 1; }

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

obs_dir() {
  [ -n "${1:-}" ] && [ -d "$1" ] || die "LOOP_DIR '${1:-}' is not a directory"
  OBS="$1/observer"
  mkdir -p "$OBS/trees" "$OBS/deltas" "$OBS/ledger"
}

# Hash the whole working tree through a throwaway index: tracked edits, staged changes and
# untracked files, minus ignored ones. This writes only unreferenced blobs and trees (git gc prunes
# them), so the real index, HEAD, refs and stash are untouched. The index is copied, not started
# empty, so git keeps its stat cache and does not rehash a large repo.
write_tree() {
  TOP=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  T=$(mktemp -d "${TMPDIR:-/tmp}/obs-index.XXXXXX") || return 1
  (
    cd "$TOP"
    cp "$(git rev-parse --git-path index)" "$T/index" 2>/dev/null || :
    GIT_INDEX_FILE="$T/index" git add -A . >/dev/null 2>&1
    GIT_INDEX_FILE="$T/index" git write-tree
  )
  rc=$?
  rm -rf "$T"
  return $rc
}

latest_run() {
  ls "$OBS/trees" 2>/dev/null | sed -n 's/^run-\([0-9][0-9]*\)\.sha$/\1/p' | sort -n | tail -1
}

cmd_snapshot() {
  obs_dir "${1:-}"
  last=$(latest_run)
  last=${last:-0}
  tree=$(write_tree) || tree=""

  # A relaunch of a run that never recorded anything reviews the same tree. Reusing its number
  # stops a failed start from counting as a run the observer thinks it has already seen.
  if [ -n "$tree" ] && [ "$last" -gt 0 ] && [ ! -f "$OBS/ledger/run-$last.md" ] \
    && [ "$(cat "$OBS/trees/run-$last.sha")" = "$tree" ]; then
    echo "$last"
    return 0
  fi

  K=$((last + 1))
  printf '%s' "$tree" > "$OBS/trees/run-$K.sha"
  if [ -z "$tree" ]; then
    # Never block a review on bookkeeping. The run still counts; it just has no delta.
    echo "observer-ledger: could not snapshot the tree for run $K" >&2
    echo "$K"
    return 0
  fi

  i=$last
  prev=""
  while [ "$i" -gt 0 ] && [ -z "$prev" ]; do
    prev=$(cat "$OBS/trees/run-$i.sha" 2>/dev/null || :)
    i=$((i - 1))
  done
  if [ -n "$prev" ]; then
    git diff --unified=0 "$prev" "$tree" > "$OBS/deltas/run-$K.patch" \
      || echo "observer-ledger: no delta for run $K" >&2
  fi
  echo "$K"
}

# Round-1 findings only. Their line numbers come from the tree the run started on, which is what
# the delta's new side describes. Later rounds review a tree the run's own fixers already moved.
cmd_landed() {
  obs_dir "${1:-}"
  top=$(git rev-parse --show-toplevel 2>/dev/null || :)
  for f in "$OBS"/ledger/run-*.md; do
    [ -f "$f" ] || continue
    k=$(basename "$f" .md); k=${k#run-}
    d="$OBS/deltas/run-$k.patch"
    [ -s "$d" ] || continue
    awk -v top="$top" '
      NR == FNR {
        if ($0 ~ /^\+\+\+ /) { file = $2; sub(/^b\//, "", file); next }
        if ($0 ~ /^@@ /) {
          split($3, h, ","); start = substr(h[1], 2) + 0
          len = (h[2] == "" ? 1 : h[2] + 0)
          if (len < 1) len = 1
          n = ++count[file]; lo[file, n] = start - 2; hi[file, n] = start + len + 1
        }
        next
      }
      /^### R[0-9]+\.[0-9]+ / { id = $2; first = ($0 ~ /, round 1\) /); want = 1; next }
      want {
        want = 0
        if (!first) next
        path = $0; line = $0
        sub(/:[0-9]+$/, "", path); sub(/^.*:/, "", line)
        if (top != "" && index(path, top "/") == 1) path = substr(path, length(top) + 2)
        for (i = 1; i <= count[path]; i++)
          if (line + 0 >= lo[path, i] && line + 0 <= hi[path, i]) { print id, path ":" line; break }
      }
    ' "$d" "$f"
  done
}

cmd_decide() {
  obs_dir "${1:-}"
  KIND=${2:-}; CLASS=${3:-}; NOTE=${4:-}
  case "$KIND" in
    adopted|smaller-fix|accepted) ;;
    *) die "kind must be adopted, smaller-fix or accepted" ;;
  esac
  [ -n "$CLASS" ] || die "class summary is empty"
  printf -- '- %s — %s: %s\n' "$CLASS" "$KIND" "${NOTE:-no note}" >> "$OBS/decisions.md"
  echo "OK: recorded $KIND"
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true
case "$cmd" in
  snapshot) cmd_snapshot "$@" ;;
  landed)   cmd_landed "$@" ;;
  decide)   cmd_decide "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$cmd' (try --help)" ;;
esac
