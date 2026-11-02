#!/bin/sh
# Drives a two-run loop through review-loop.sh in a throwaway git repo. No agents involved.
#   sh skills/codex-build-and-review/tests/review-loop-observer.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SH="$HERE/../review-loop.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rl-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "     wanted [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) check "$1" yes yes ;; *) check "$1" "$2" "contains: $3" ;; esac; }
lacks() { case "$2" in *"$3"*) check "$1" "$2" "lacks: $3" ;; *) check "$1" yes yes ;; esac; }

finding() { # file lines title
  printf -- '--- FINDING ---\nFILE: %s\nLINES: %s\nSEVERITY: high\nCONFIDENCE: 0.9\nTITLE: %s\nCLAIM:\nclaim of %s\nspanning lines\nRECOMMENDATION:\nfix %s\n--- END ---\n' "$1" "$2" "$3" "$3" "$3"
}
result() { # title action
  printf -- '--- RESULT ---\nTITLE: %s\nACTION: %s\nCLAIM_ACCURACY: 95\nINTENT_MATCH: 95\nDETAIL:\ndetail of %s\n--- END ---\n' "$1" "$2" "$1"
}

cd "$ROOT"; git init -q; git config user.email t@t; git config user.name t
printf 'one\ntwo\nthree\nfour\nfive\n' > a.ts; git add -A; git commit -qm base

out=$(sh "$SH" init); RUN=$(printf '%s\n' "$out" | sed -n 's/^RUN=//p')
BRIEF=$(printf '%s\n' "$out" | sed -n 's/^OBSERVER_BRIEF=//p')
check 'init prints the observer brief' "$BRIEF" "$RUN/observer-brief.md"
has 'the run copy has the method' "$(cat "$BRIEF")" 'A check is not a fix for a class'
has 'the run copy has the hand-back format' "$(cat "$BRIEF")" '--- CLASS ---'
lacks 'the run copy is a real file' "$(ls -l "$BRIEF")" '->'

check 'first snapshot is run 1' "$(sh "$SH" snapshot "$RUN")" 1
mkdir -p "$RUN/findings/r1" "$RUN/results/r1"
{ echo 'VERDICT: needs-attention'; echo 'SUMMARY: s'; finding a.ts 2-3 'First bug'; finding b.ts 1-1 'Auto fixed'; } > "$RUN/findings/r1/lens1.md"
{ echo 'VERDICT: needs-attention'; echo 'SUMMARY: s'; finding c.ts 5-5 'Second lens'; } > "$RUN/findings/r1/lens2.md"
sh "$SH" collect "$RUN" 1 >/dev/null
result 'First bug' needs-pick > "$RUN/results/r1/a.md"
result 'Auto fixed' fixed > "$RUN/results/r1/b.md"
result 'Second lens' intent-check > "$RUN/results/r1/c.md"
sh "$SH" absorb "$RUN" 1 >/dev/null

sh "$SH" ledger "$RUN" >/dev/null
L1="$RUN/observer/ledger/run-1.md"
has 'ledger uses the shared header' "$(cat "$L1")" '### R1.2 [high] (lens1, round 1) Auto fixed'
has 'ledger keeps the raising lens' "$(cat "$L1")" '(lens2, round 1) Second lens'
has 'ledger records line start' "$(cat "$L1")" 'a.ts:2'
has 'ledger puts the claim on one line' "$(cat "$L1")" 'Claim: claim of First bug spanning lines'
has 'ledger records dispositions' "$(cat "$L1")" 'Disposition: needs-pick — detail of First bug'
has 'ledger records fixes too' "$(cat "$L1")" 'Disposition: fixed — detail of Auto fixed'
has 'run 1 is not due' "$(sh "$SH" observer-due "$RUN")" 'no'

printf 'one\nTWO\nthree\nfour\nfive\n' > a.ts
check 'second snapshot is run 2' "$(sh "$SH" snapshot "$RUN")" 2
mkdir -p "$RUN/findings/r2" "$RUN/results/r2"
{ echo 'VERDICT: needs-attention'; echo 'SUMMARY: s'; finding a.ts 2-2 'In the loop code'; } > "$RUN/findings/r2/lens1.md"
sh "$SH" collect "$RUN" 2 >/dev/null
result 'In the loop code' needs-pick > "$RUN/results/r2/a.md"
sh "$SH" absorb "$RUN" 2 >/dev/null
sh "$SH" ledger "$RUN" >/dev/null
L2="$RUN/observer/ledger/run-2.md"
has 'run 2 ids restart under the run number' "$(cat "$L2")" '### R2.1 [high] (lens1, round 1) In the loop code'
check 'run 2 is due' "$(sh "$SH" observer-due "$RUN")" yes
has 'landed passes through' "$(sh "$SH" landed "$RUN")" 'R2.1 a.ts:2'

cat > "$RUN/observer/classes-run-2.txt" <<'C'
--- CLASS ---
SUMMARY: Medium one, single lens.
INVARIANT: y holds
MEMBERS: R1.2 R2.1 R1.3
LENSES: 1
RUNG: chokepoint
CHANGE: one helper
ELIMINATED: R1.2 R2.1 R1.3
SIBLING: confirmed src/z.ts:9 same shape
NEW_RISK: small
LANDED: R2.1
RECOMMENDATION: smaller-fix
--- END ---
--- CLASS ---
SUMMARY: High one.
INVARIANT: x holds
MEMBERS: R1.1 R2.1 R1.3
LENSES: 2
RUNG: structural
CHANGE: remove the second writer
ELIMINATED: R1.1 R2.1
SIBLING: refuted src/q.ts:1 not the same
SIBLING: confirmed src/a.ts:42 same shape
NEW_RISK: migration
LANDED: R2.1
RECOMMENDATION: adopt
--- END ---
--- CLASS ---
SUMMARY: Same run only.
INVARIANT: z
MEMBERS: R1.1 R1.2 R1.3
LENSES: 2
RUNG: structural
CHANGE: c
ELIMINATED: R1.1 R1.2 R1.3
NEW_RISK: r
LANDED:
RECOMMENDATION: adopt
--- END ---
--- CLASS ---
SUMMARY: Sibling claimed without evidence.
INVARIANT: w
MEMBERS: R1.1 R2.1 R1.3
LENSES: 2
RUNG: structural
CHANGE: c
ELIMINATED: R1.1 R2.1 R1.3
SIBLING: confirmed looks likely
NEW_RISK: r
LANDED:
RECOMMENDATION: accept
--- END ---
C
c=$(sh "$SH" classes "$RUN")
first=$(printf '%s\n' "$c" | grep '^CLASS' | head -1)
has 'high sorts first' "$first" 'CLASS C1 high structural — High one.'
has 'single lens is capped at medium' "$c" 'medium chokepoint — Medium one, single lens.'
has 'a sibling needs file:line to count' "$c" 'medium structural — Sibling claimed without evidence.'
lacks 'a class in one run is hidden' "$c" 'Same run only.'
has 'hidden classes are counted' "$c" 'HIDDEN: 1'
has 'open decisions are listed with report numbers' "$c" 'Decisions: #1 #2 #3'
has 'the change is marked unverified' "$c" 'Change (unverified): remove the second writer'
has 'loop-written members are shown' "$c" 'In loop-written code: R2.1'

# R1.1 is named only in ELIMINATED, and R1.10-style prefixes must not pull it into the class.
cat > "$RUN/observer/classes-run-2.txt" <<'C'
--- CLASS ---
SUMMARY: Prefix trap.
MEMBERS: R1.3 R2.1 R1.10
LENSES: 2
RUNG: structural
CHANGE: c
ELIMINATED: R1.10 R1.1 R1.10
SIBLING: confirmed src/a.ts:1 same
NEW_RISK: r
LANDED:
RECOMMENDATION: adopt
--- END ---
C
c=$(sh "$SH" classes "$RUN")
has 'an id outside the class does not count as eliminated' "$c" 'CLASS C1 medium structural — Prefix trap.'
has 'a prefix id does not pull in another decision' "$c" 'Decisions: #2 #3'
sh "$SH" decide "$RUN" accepted 'High one.' 'not reachable' >/dev/null
has 'decide passes through' "$(cat "$RUN/observer/decisions.md")" 'High one. — accepted: not reachable'

mkdir -p "$RUN/findings/r3"
sh "$SH" snapshot "$RUN" >/dev/null
printf 'VERDICT: error\nSUMMARY: broke\n' > "$RUN/findings/r3/lens1.md"
sh "$SH" collect "$RUN" 3 >/dev/null
sh "$SH" ledger "$RUN" >/dev/null
has 'a run with no findings is not due' "$(sh "$SH" observer-due "$RUN")" 'no'

sh "$SH" snapshot "$RUN" >/dev/null
mkdir -p "$RUN/findings/r4"
{ echo 'VERDICT: needs-attention'; echo 'SUMMARY: s'; finding a.ts 1-1 'Partly blocked'; } > "$RUN/findings/r4/lens1.md"
printf 'VERDICT: error\nSUMMARY: broke\n' > "$RUN/findings/r4/lens2.md"
sh "$SH" collect "$RUN" 4 >/dev/null
sh "$SH" ledger "$RUN" >/dev/null
has 'a blocked run is not due' "$(sh "$SH" observer-due "$RUN")" 'no: blocked'

OTHER=$(sh "$SH" init | sed -n 's/^RUN=//p')
mkdir -p "$OTHER/findings/r1"
{ echo 'VERDICT: approve'; echo 'SUMMARY: s'; } > "$OTHER/findings/r1/lens1.md"
sh "$SH" collect "$OTHER" 1 >/dev/null
has 'a loop that never snapshotted says so' "$(sh "$SH" observer-due "$OTHER")" 'no: no snapshot'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
