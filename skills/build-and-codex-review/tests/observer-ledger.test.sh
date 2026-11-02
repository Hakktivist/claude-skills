#!/bin/sh
# Exercises observer-ledger.sh against a throwaway git repo.
#   sh skills/build-and-codex-review/tests/observer-ledger.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SH="$HERE/../observer-ledger.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/obs-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "     wanted [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) check "$1" yes yes ;; *) check "$1" "$2" "contains: $3" ;; esac; }
lacks() { case "$2" in *"$3"*) check "$1" "$2" "lacks: $3" ;; *) check "$1" yes yes ;; esac; }

REPO="$ROOT/repo"; LOOP="$ROOT/loop"; mkdir -p "$REPO/sub" "$LOOP"
cd "$REPO"; git init -q; git config user.email t@t; git config user.name t
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > a.ts
printf 'node_modules\n' > .gitignore
git add -A; git commit -qm base
printf 'staged\n' > staged.ts; git add staged.ts
index_before=$(git diff --cached --name-only | tr '\n' ' ')
head_before=$(git rev-parse HEAD)

check 'first snapshot is run 1' "$(sh "$SH" snapshot "$LOOP")" 1
check 'snapshot leaves the index alone' "$(git diff --cached --name-only | tr '\n' ' ')" "$index_before"
check 'snapshot leaves HEAD alone' "$(git rev-parse HEAD)" "$head_before"
check 'no refs or stashes created' "$(git for-each-ref | wc -l | tr -d ' ')$(git stash list | wc -l | tr -d ' ')" "10"
check 'a retry on the same tree keeps the run number' "$(sh "$SH" snapshot "$LOOP")" 1
check 'run 1 has no delta' "$(ls "$LOOP/observer/deltas" | wc -l | tr -d ' ')" 0

printf '### R1.1 [high] (lens1, round 1) Old\na.ts:2\nClaim: c\nDisposition: fixed — d\n\n' > "$LOOP/observer/ledger/run-1.md"
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\nEIGHT\nnine\nten\n' > a.ts
printf 'new file\n' > sub/untracked.ts
mkdir -p node_modules; printf 'x\n' > node_modules/ignored.js
check 'next snapshot is run 2' "$(cd sub && sh "$SH" snapshot "$LOOP")" 2
d=$(cat "$LOOP/observer/deltas/run-2.patch")
has 'delta has the tracked edit' "$d" 'EIGHT'
has 'delta has the untracked file' "$d" 'sub/untracked.ts'
lacks 'delta skips ignored files' "$d" 'node_modules'

cat > "$LOOP/observer/ledger/run-2.md" <<'L'
### R2.1 [high] (lens1, round 1) In the patch
a.ts:8
Claim: c
Disposition: unclear — d

### R2.2 [high] (lens2, round 1) Not in the patch
a.ts:2
Claim: c
Disposition: fixed — d

### R2.3 [high] (lens1, round 2) Later round, lines have moved
a.ts:8
Claim: c
Disposition: fixed — d

### R2.4 [medium] (lens1, round 1) New file
sub/untracked.ts:1
Claim: c
Disposition: fixed — d
L
l=$(sh "$SH" landed "$LOOP")
has 'finding inside a loop-written hunk is marked' "$l" 'R2.1 a.ts:8'
has 'finding in a new file is marked' "$l" 'R2.4 sub/untracked.ts:1'
lacks 'finding outside the delta is not marked' "$l" 'R2.2'
lacks 'round 2+ lines are not compared' "$l" 'R2.3'
lacks 'run 1 has nothing to compare' "$l" 'R1.1'

sh "$SH" decide "$LOOP" accepted "Reruns can race" "same-day reruns are forbidden" >/dev/null
has 'decision is recorded' "$(cat "$LOOP/observer/decisions.md")" 'Reruns can race — accepted: same-day reruns are forbidden'
sh "$SH" decide "$LOOP" maybe "x" "y" >/dev/null 2>&1
check 'unknown decision kind is refused' "$?" 1

check 'outside a repo, snapshot still returns a number' "$(cd "$ROOT" && sh "$SH" snapshot "$LOOP" 2>/dev/null)" 3
check 'no delta after a failed snapshot' "$(ls "$LOOP/observer/deltas" | grep -c run-3)" 0
echo 'late' >> a.ts
check 'a later snapshot recovers' "$(sh "$SH" snapshot "$LOOP" 2>/dev/null)" 4
has 'delta falls back to the last good tree' "$(cat "$LOOP/observer/deltas/run-4.patch")" 'late'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
