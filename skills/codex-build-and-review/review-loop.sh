#!/bin/sh
# review-loop.sh — bookkeeping for the codex-build-and-review loop.
#
# The loop's judgment (what to build, which lenses, when to stop) belongs to the root agent.
# This script owns only the parts that must NOT be done from memory across a long turn:
# parsing subagent output, deduping findings across rounds, suppressing already-adjudicated
# items, escalating re-flagged fixes, and accumulating the ledger.
#
#   init                          -> mint a run dir outside the repo; print its paths
#   focus  RUN ROUND N "lens"     -> write lens N's focus file for ROUND; print its path
#   collect RUN ROUND             -> parse reviewer output; print groups for the fixers
#   absorb RUN ROUND              -> parse fixer output into the ledger; print counts
#   resolve RUN N built|accepted "note"
#                                 -> record the human's decision on ledger item N
#   report RUN                    -> print the final blocked / fixed / needs-decision report
#   snapshot RUN                  -> start a run: record the tree under review; print the run number
#   ledger RUN                    -> write this run's findings and dispositions for the observer
#   observer-due RUN              -> "yes", or "no: <reason>"
#   landed RUN                    -> list findings sitting in code the loop itself wrote
#   classes RUN                   -> score the observer's classes; print what to show the human
#   decide RUN KIND "class" "note"-> record the human's call on a class
#                                    (KIND: adopted | smaller-fix | accepted)
#
# POSIX sh + awk. No dependencies.

set -eu

SKILL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

die() { echo "review-loop: $*" >&2; exit 1; }

# The suppression list every later reviewer reads. Regenerated from the ledger so it can never
# drift from it.
regen_adjudicated() {
  if [ -s "$1/state/hitl.tsv" ]; then
    awk -F '\t' '{ printf "%d. [%s] %s — %s: %s\n", NR, $2, $3, $4, substr($5, 1, 240) }' "$1/state/hitl.tsv"
  else
    printf 'Nothing adjudicated yet.\n'
  fi > "$1/adjudicated.md"
}

usage() {
  sed -n '4,24p' "$0" | sed 's/^# \{0,1\}//'
}

need_run() {
  [ -n "${1:-}" ] || die "missing RUN dir argument"
  [ -d "$1/state" ] || die "$1 is not a run dir (no state/) — did you run 'init'?"
}

# ---------------------------------------------------------------- init

cmd_init() {
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/cbr-run.XXXXXX")
  mkdir -p "$RUN/state" "$RUN/lens" "$RUN/findings" "$RUN/fix" "$RUN/results"
  for f in reviewer-brief.md fixer-brief.md observer-brief.md; do
    [ -f "$SKILL_DIR/$f" ] || die "$f missing from $SKILL_DIR"
    cp "$SKILL_DIR/$f" "$RUN/$f"
  done
  # The brief is shared with the Claude loop, which returns classes through a schema. Here a parser
  # reads a file, so this copy gains the format.
  cat >> "$RUN/observer-brief.md" <<'OBSERVER_FORMAT'

## Hand-back format

Write your classes to the CLASSES path in your spawn message, in exactly this format. A parser reads
it, so the markers and field names are literal. Each field stays on one line. Repeat `SIBLING:` per
sibling, with `confirmed`, `refuted`, or `unchecked` first. Write an empty file if no class survived.

```
--- CLASS ---
SUMMARY: Same-day reruns can replace rows a reader already selected.
INVARIANT: A visible marker means its rows are one complete run.
MEMBERS: R1.4 R2.1 R2.3
LENSES: 2
RUNG: structural
CHANGE: Key rows by attempt and publish with a single marker write.
ELIMINATED: R1.4 R2.1 R2.3
SIBLING: confirmed src/history.ts:42 a failed copy drops a complete day
NEW_RISK: A read missing the attempt filter double-counts.
LANDED: R2.1
RECOMMENDATION: adopt
--- END ---
```

Then reply with a single line and nothing else: `DONE <n> class(es)`, or `ERROR <one-line reason>`.
OBSERVER_FORMAT
  cp "$SKILL_DIR/handoff-template.md" "$RUN/HANDOFF.md"
  : > "$RUN/state/fixed.tsv"
  : > "$RUN/state/hitl.tsv"
  : > "$RUN/state/blocked.tsv"
  : > "$RUN/state/rounds.tsv"
  printf 'Nothing adjudicated yet.\n' > "$RUN/adjudicated.md"
  echo "RUN=$RUN"
  echo "HANDOFF=$RUN/HANDOFF.md"
  echo "REVIEWER_BRIEF=$RUN/reviewer-brief.md"
  echo "FIXER_BRIEF=$RUN/fixer-brief.md"
  echo "OBSERVER_BRIEF=$RUN/observer-brief.md"
}

# ---------------------------------------------------------------- focus

cmd_focus() {
  RUN=${1:-}; ROUND=${2:-}; N=${3:-}
  need_run "$RUN"
  [ -n "$ROUND" ] && [ -n "$N" ] || die "usage: focus RUN ROUND N \"lens text\""
  shift 3
  LENS=$*
  [ -n "$LENS" ] || die "lens text is empty"
  mkdir -p "$RUN/lens/r$ROUND" "$RUN/findings/r$ROUND"
  OUT="$RUN/findings/r$ROUND/lens$N.md"
  F="$RUN/lens/r$ROUND/lens$N.focus"
  {
    printf 'FOCUS: %s\n\n' "$LENS"
    printf 'Write your findings to this file (create it): %s\n\n' "$OUT"
    printf 'ALREADY ADJUDICATED — DO NOT RE-REPORT. Each item below was already decided by a\n'
    printf 'code-reading fixer or by the human. Re-raising one wastes the round even if the code\n'
    printf 'still looks wrong. Report only issues NOT in this list:\n\n'
    cat "$RUN/adjudicated.md"
  } > "$F"
  echo "$F"
}

# ---------------------------------------------------------------- collect

cmd_collect() {
  RUN=${1:-}; ROUND=${2:-}
  need_run "$RUN"
  [ -n "$ROUND" ] || die "usage: collect RUN ROUND"
  SRC="$RUN/findings/r$ROUND"
  [ -d "$SRC" ] || die "no findings dir for round $ROUND ($SRC)"
  mkdir -p "$RUN/fix/r$ROUND" "$RUN/results/r$ROUND"

  # Remember which run this round belongs to, so the ledger can keep runs apart. Rounds number
  # straight through a continue; runs are what the observer compares across.
  CURRENT=$(cat "$RUN/state/run" 2>/dev/null || :)
  if [ -n "$CURRENT" ] && ! grep -q "^$ROUND	" "$RUN/state/rounds.tsv" 2>/dev/null; then
    printf '%s\t%s\n' "$ROUND" "$CURRENT" >> "$RUN/state/rounds.tsv"
  fi

  NORM="$RUN/state/r$ROUND.norm.tsv"
  : > "$NORM"
  FILES=$(find "$SRC" -maxdepth 1 -name '*.md' | sort)
  [ -n "$FILES" ] || { echo "BLOCKED: no reviewer wrote a findings file for round $ROUND"; \
    printf '%s\tno-output\tno reviewer wrote a findings file\n' "$ROUND" >> "$RUN/state/blocked.tsv"; \
    echo "FRESH: 0"; return 0; }

  # Reviewer-level failures first: a lens that errored did NOT review, so this round's
  # coverage is incomplete. That is never the same thing as a clean review.
  for f in $FILES; do
    v=$(awk '/^VERDICT:/ { sub(/^VERDICT:[ \t]*/, ""); print tolower($0); exit }' "$f")
    s=$(awk '/^SUMMARY:/ { sub(/^SUMMARY:[ \t]*/, ""); print; exit }' "$f")
    case "$v" in
      error|"")
        lens=$(basename "$f" .md)
        reason=${s:-"reviewer wrote no usable VERDICT line"}
        echo "BLOCKED: r$ROUND $lens — $reason"
        printf '%s\t%s\t%s\n' "$ROUND" "$lens" "$reason" >> "$RUN/state/blocked.tsv"
        ;;
    esac
  done

  awk '
    function esc(s) { gsub(/\t/, " ", s); return s }
    function flush() {
      if (file != "" && title != "")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", esc(file), esc(lines), esc(sev), esc(conf), esc(title), esc(claim), esc(rec), lens
      else if (file != "" || title != "" || claim != "")
        malformed++
      file=""; lines=""; sev=""; conf=""; title=""; claim=""; rec=""; sect=""
    }
    function val(line) { gsub(/\r/, "", line); sub(/^[A-Z_]+:[ \t]*/, "", line); sub(/[ \t]+$/, "", line); return line }
    /^--- *FINDING *---/ { flush(); inb=1; lens=FILENAME; sub(/.*\//, "", lens); sub(/\.md$/, "", lens); next }
    /^--- *END *---/     { if (inb) flush(); inb=0; next }
    !inb { next }
    /^FILE:/        { file=val($0); sect=""; next }
    /^LINES:/       { lines=val($0); sect=""; next }
    /^SEVERITY:/    { sev=tolower(val($0)); sect=""; next }
    /^CONFIDENCE:/  { conf=val($0); sect=""; next }
    /^TITLE:/       { title=val($0); sect=""; next }
    /^CLAIM:/          { claim=val($0); sect="claim"; next }
    /^RECOMMENDATION:/ { rec=val($0); sect="rec"; next }
    {
      if (sect == "claim") claim = claim (claim=="" ? "" : "\\n") $0
      else if (sect == "rec") rec = rec (rec=="" ? "" : "\\n") $0
    }
    END { flush(); if (malformed) printf "MALFORMED\t%d\n", malformed > "/dev/stderr" }
  ' $FILES >> "$NORM"

  FRESH="$RUN/state/r$ROUND.fresh.tsv"
  : > "$FRESH"

  # Classify against the ledger:
  #   already with the human  -> drop (they own it)
  #   already auto-fixed      -> the fix did not hold; escalate, do NOT re-fix it blind
  #   otherwise               -> fresh work for a fixer
  awk -F '\t' -v hitlf="$RUN/state/hitl.tsv" -v fixedf="$RUN/state/fixed.tsv" \
      -v freshf="$FRESH" -v round="$ROUND" '
    function key(file, lines, title,   ls, p) {
      split(lines, p, "-"); ls = p[1] + 0
      return file ":" ls ":" tolower(title)
    }
    BEGIN {
      while ((getline line < hitlf)  > 0) { split(line, a, "\t"); h[a[1]] = 1 }
      while ((getline line < fixedf) > 0) { split(line, a, "\t"); fx[a[1]] = a[3] }
    }
    {
      k = key($1, $2, $5)
      if (k in seen) { dup++; next }
      seen[k] = 1
      if (k in h) { supp++; next }
      if (k in fx) {
        printf "ESCALATE_ITEM\t%s\t%s\t%s\t%s\n", k, $1, $5, $7
        esc++
        next
      }
      printf "%s\t%s\n", k, $0 > freshf
      fresh++
    }
    END {
      printf "SUPPRESSED: %d\n", supp + 0
      printf "DUPLICATE: %d\n", dup + 0
      printf "ESCALATED: %d\n", esc + 0
      printf "FRESH: %d\n", fresh + 0
    }
  ' "$NORM" > "$RUN/state/r$ROUND.classify.txt"

  # Re-flagged fixes go straight to the human — a fix codex still objects to needs eyes, not
  # another blind pass by the same fixer.
  awk -F '\t' -v round="$ROUND" -v out="$RUN/state/hitl.tsv" '
    $1 == "ESCALATE_ITEM" {
      printf "%s\t%s\t%s\tunclear\tRe-flagged after an auto-fix in an earlier round — the fix did not satisfy the reviewer. Needs your eyes. Reviewer says: %s\t%s\n", $2, $3, $4, $5, round >> out
    }
  ' "$RUN/state/r$ROUND.classify.txt"

  grep -v "^ESCALATE_ITEM	" "$RUN/state/r$ROUND.classify.txt" || true

  # One group per file: no two fixers ever edit the same file, so they are parallel-safe.
  INDEX="$RUN/fix/r$ROUND/INDEX"
  : > "$INDEX"
  if [ -s "$FRESH" ]; then
    cut -f2 "$FRESH" | sort -u | while IFS= read -r file; do
      [ -n "$file" ] || continue
      slug=$(printf '%s' "$file" | sed 's|[^A-Za-z0-9._-]|_|g')
      path="$RUN/fix/r$ROUND/$slug.md"
      awk -F '\t' -v want="$file" -v file="$file" '
        function unesc(s) { gsub(/\\n/, "\n", s); return s }
        BEGIN { printf "# Review findings for %s\n", file }
        $2 == want {
          n++
          printf "\n## %d. [%s] %s\n", n, $4, $6
          printf "Location: %s:%s — reviewer confidence %s\n", $2, $3, $5
          printf "\nCLAIM:\n%s\n", unesc($7)
          printf "\nRECOMMENDATION:\n%s\n", unesc($8)
        }
      ' "$FRESH" > "$path"
      printf 'GROUP\t%s\t%s\n' "$file" "$path" >> "$INDEX"
    done
  fi
  cat "$INDEX"
}

# ---------------------------------------------------------------- absorb

cmd_absorb() {
  RUN=${1:-}; ROUND=${2:-}
  need_run "$RUN"
  [ -n "$ROUND" ] || die "usage: absorb RUN ROUND"
  SRC="$RUN/results/r$ROUND"
  FRESH="$RUN/state/r$ROUND.fresh.tsv"
  [ -f "$FRESH" ] || die "no fresh findings recorded for round $ROUND — run 'collect' first"
  RES=$(find "$SRC" -maxdepth 1 -name '*.md' 2>/dev/null | sort || true)

  if [ -z "$RES" ]; then
    echo "BLOCKED: no fixer wrote a results file for round $ROUND"
    printf '%s\tfixers\tno fixer wrote a results file\n' "$ROUND" >> "$RUN/state/blocked.tsv"
    echo "FIXED: 0"; echo "HITL: 0"
    return 0
  fi

  # Results carry the finding TITLE, not its key: match back through this round's fresh set so
  # a fix is recorded against the same identity the next round's dedup will look up.
  awk -F '\t' -v freshf="$FRESH" -v round="$ROUND" \
      -v fixedf="$RUN/state/fixed.tsv" -v hitlf="$RUN/state/hitl.tsv" '
    function esc(s) { gsub(/\t/, " ", s); gsub(/\n/, " ", s); return s }
    function norm(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return tolower(s) }
    function flush(   k, f) {
      if (title == "") { title=""; action=""; ca=""; im=""; detail=""; sect=""; return }
      t = norm(title)
      k = key[t]; f = kfile[t]
      if (k == "") { k = "UNMATCHED:" t; f = "UNKNOWN"; unmatched++ }
      if (action == "fixed") {
        printf "%s\t%s\t%s\t%s\n", k, f, esc(title), esc(detail) >> fixedf
        nfixed++
      } else {
        if (action == "") action = "unclear"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", k, f, esc(title), action, esc(detail), round >> hitlf
        nhitl++
      }
      title=""; action=""; ca=""; im=""; detail=""; sect=""
    }
    function val(line) { gsub(/\r/, "", line); sub(/^[A-Z_]+:[ \t]*/, "", line); sub(/[ \t]+$/, "", line); return line }
    BEGIN {
      FS = "\t"
      while ((getline line < freshf) > 0) {
        split(line, a, "\t")
        key[norm(a[6])] = a[1]
        kfile[norm(a[6])] = a[2]
      }
    }
    /^--- *RESULT *---/ { flush(); inb=1; next }
    /^--- *END *---/    { if (inb) flush(); inb=0; next }
    !inb { next }
    /^TITLE:/          { title=val($0); sect=""; next }
    /^ACTION:/         { action=tolower(val($0)); sect=""; next }
    /^CLAIM_ACCURACY:/ { ca=val($0); sect=""; next }
    /^INTENT_MATCH:/   { im=val($0); sect=""; next }
    /^DETAIL:/         { detail=val($0); sect="detail"; next }
    { if (sect == "detail") detail = detail (detail=="" ? "" : " ") $0 }
    END {
      flush()
      printf "FIXED: %d\n", nfixed + 0
      printf "HITL: %d\n", nhitl + 0
      if (unmatched) printf "UNMATCHED: %d (a fixer edited a finding title — check %s)\n", unmatched, round
    }
  ' $RES

  regen_adjudicated "$RUN"
}

# ---------------------------------------------------------------- resolve

# Record what the human decided about one open item, by its number in `report`.
#   built    -> you implemented their decision. The item leaves the human's column and joins the
#               auto-fixed set, so a later reviewer re-flagging it ESCALATES instead of being
#               silently suppressed — their decision still has to survive review.
#   accepted -> they judged it fine as-is. It stays suppressed for good.
# Resolve in DESCENDING index order: 'built' removes a row, which renumbers everything under it.
cmd_resolve() {
  RUN=${1:-}; IDX=${2:-}; KIND=${3:-}
  need_run "$RUN"
  [ -n "$IDX" ] && [ -n "$KIND" ] || die "usage: resolve RUN N built|accepted \"note\""
  shift 3
  NOTE=$*
  H="$RUN/state/hitl.tsv"
  line=$(awk -v n="$IDX" 'NR == n' "$H")
  [ -n "$line" ] || die "no item #$IDX in the ledger (run 'report' to see it)"
  case "$KIND" in
    built)
      k=$(printf '%s' "$line" | cut -f1)
      awk -F '\t' -v k="$k" '$1 != k' "$RUN/state/fixed.tsv" > "$RUN/state/fixed.tsv.tmp" \
        && mv "$RUN/state/fixed.tsv.tmp" "$RUN/state/fixed.tsv"
      printf '%s\n' "$line" | awk -F '\t' -v note="$NOTE" '
        { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, (note == "" ? "built from the human decision" : note) }' \
        >> "$RUN/state/fixed.tsv"
      awk -v n="$IDX" 'NR != n' "$H" > "$H.tmp" && mv "$H.tmp" "$H"
      ;;
    accepted)
      awk -F '\t' -v n="$IDX" -v note="$NOTE" 'BEGIN { OFS = "\t" }
        NR == n { $4 = "accepted"; $5 = "Human decision: " (note == "" ? "accepted as-is" : note) }
        { print }' "$H" > "$H.tmp" && mv "$H.tmp" "$H"
      ;;
    *) die "kind must be 'built' or 'accepted'" ;;
  esac
  regen_adjudicated "$RUN"
  printf 'OK: item %s recorded as %s\n' "$IDX" "$KIND"
}

# ---------------------------------------------------------------- report

cmd_report() {
  RUN=${1:-}
  need_run "$RUN"
  if [ -s "$RUN/state/blocked.tsv" ]; then
    echo "## BLOCKED — the review did NOT fully run. Coverage is incomplete; this is not a clean bill."
    awk -F '\t' '{ printf "- round %s, %s: %s\n", $1, $2, $3 }' "$RUN/state/blocked.tsv"
    echo
  fi
  echo "## AUTO-FIXED ($(wc -l < "$RUN/state/fixed.tsv" | tr -d ' '))"
  if [ -s "$RUN/state/fixed.tsv" ]; then
    awk -F '\t' '{ printf "- %s — %s: %s\n", $2, $3, $4 }' "$RUN/state/fixed.tsv"
  else
    echo "- none"
  fi
  echo
  open=$(awk -F '\t' '$4 != "accepted"' "$RUN/state/hitl.tsv" | wc -l | tr -d ' ')
  echo "## NEEDS YOUR DECISION ($open) — the #N is what 'resolve' takes"
  if [ "$open" -gt 0 ]; then
    awk -F '\t' '$4 != "accepted" { printf "- #%d [%s] %s — %s\n  %s\n", NR, $4, $2, $3, $5 }' "$RUN/state/hitl.tsv"
  else
    echo "- none"
  fi
  closed=$(awk -F '\t' '$4 == "accepted"' "$RUN/state/hitl.tsv" | wc -l | tr -d ' ')
  if [ "$closed" -gt 0 ]; then
    echo
    echo "## ACCEPTED BY YOU ($closed) — suppressed for the rest of the run"
    awk -F '\t' '$4 == "accepted" { printf "- #%d %s — %s\n  %s\n", NR, $2, $3, $5 }' "$RUN/state/hitl.tsv"
  fi
}

# ---------------------------------------------------------------- observer

current_run() { cat "$1/state/run" 2>/dev/null || :; }

cmd_snapshot() {
  RUN=${1:-}
  need_run "$RUN"
  K=$(sh "$SKILL_DIR/observer-ledger.sh" snapshot "$RUN")
  printf '%s' "$K" > "$RUN/state/run"
  echo "$K"
}

# Render this run in the format the shared observer brief describes, plus an id -> finding-key index
# so `classes` can point at the numbers `report` prints.
cmd_ledger() {
  RUN=${1:-}
  need_run "$RUN"
  K=$(current_run "$RUN")
  [ -n "$K" ] || die "no run recorded — run 'snapshot' first"
  ROUNDS=$(awk -F '\t' -v k="$K" '$2 == k { print $1 }' "$RUN/state/rounds.tsv" | sort -n)
  FILES=""
  for r in $ROUNDS; do
    [ -f "$RUN/state/r$r.fresh.tsv" ] && FILES="$FILES $RUN/state/r$r.fresh.tsv"
  done
  mkdir -p "$RUN/observer/ledger"
  OUT="$RUN/observer/ledger/run-$K.md"
  INDEX="$RUN/observer/ledger/run-$K.index.tsv"
  : > "$INDEX"
  rm -f "$OUT"
  [ -n "$FILES" ] || return 0
  # shellcheck disable=SC2086
  awk -v k="$K" -v fixedf="$RUN/state/fixed.tsv" -v hitlf="$RUN/state/hitl.tsv" -v indexf="$INDEX" '
    BEGIN {
      FS = "\t"
      while ((getline line < fixedf) > 0) { split(line, a, "\t"); disp[a[1]] = "fixed"; note[a[1]] = a[4] }
      while ((getline line < hitlf)  > 0) { split(line, a, "\t"); disp[a[1]] = a[4]; note[a[1]] = a[5] }
      printf "## Run %s\n\n", k
    }
    FNR == 1 { round++ }
    {
      id = "R" k "." (++n)
      split($3, p, "-"); start = p[1] + 0; if (start < 1) start = 1
      claim = $7; gsub(/\\n/, " ", claim); claim = substr(claim, 1, 700)
      d = ($1 in disp) ? disp[$1] " — " substr(note[$1], 1, 400) : "not recorded"
      printf "### %s [%s] (%s, round %d) %s\n%s:%d\nClaim: %s\nDisposition: %s\n\n", id, $4, $9, round, $6, $2, start, claim, d
      printf "%s\t%s\n", id, $1 >> indexf
    }
  ' $FILES > "$OUT"
  if [ -s "$INDEX" ]; then echo "$OUT"; else rm -f "$OUT"; fi
}

cmd_observer_due() {
  RUN=${1:-}
  need_run "$RUN"
  K=$(current_run "$RUN")
  if [ -z "$K" ]; then echo "no: no snapshot was taken for this run"; return 0; fi
  if [ "$K" -lt 2 ]; then echo "no: first run"; return 0; fi
  if [ ! -s "$RUN/observer/ledger/run-$K.md" ]; then echo "no: no findings this run"; return 0; fi
  blocked=$(awk -F '\t' -v k="$K" -v bf="$RUN/state/blocked.tsv" '
    $2 == k { mine[$1] = 1 }
    END { while ((getline line < bf) > 0) { split(line, a, "\t"); if (a[1] in mine) n++ } print n + 0 }
  ' "$RUN/state/rounds.tsv")
  if [ "$blocked" -gt 0 ]; then echo "no: blocked this run"; return 0; fi
  echo yes
}

# The same rule as classConfidence in the Claude loop: confidence is counted, never taken from the
# observer. A class needs 2+ distinct bugs across 2+ runs to be shown at all. High also needs 3+ bugs,
# a sibling confirmed at a file:line, most members eliminated, and 2+ lenses.
cmd_classes() {
  RUN=${1:-}
  need_run "$RUN"
  K=$(current_run "$RUN")
  F="$RUN/observer/classes-run-$K.txt"
  [ -f "$F" ] || die "no classes file at $F"
  cat "$RUN"/observer/ledger/run-*.index.tsv > "$RUN/state/ledger-index.tsv" 2>/dev/null || :
  awk -v hitlf="$RUN/state/hitl.tsv" -v indexf="$RUN/state/ledger-index.tsv" -v report="$RUN/observer/report-run-$K.md" '
    function val(line) { gsub(/\r/, "", line); sub(/^[A-Z_]+:[ \t]*/, "", line); sub(/[ \t]+$/, "", line); return line }
    function reset() { summary=""; rung=""; change=""; risk=""; rec=""; members=""; elim=""; landed=""; lenses=0; confirmed=0 }
    function flush(   m, n, i, id, seen, runs, nruns, distinct, gone, counted, e, ne, parts, conf, nums, out) {
      n = split(members, m, " ")
      distinct = 0; nruns = 0
      for (i = 1; i <= n; i++) {
        id = m[i]
        if (id !~ /^R[0-9]+\.[0-9]+$/ || (id in seen)) continue
        seen[id] = 1; distinct++
        split(id, parts, "."); if (!(parts[1] in runs)) { runs[parts[1]] = 1; nruns++ }
      }
      if (distinct < 2 || nruns < 2) { hidden++; return }
      ne = split(elim, e, " "); gone = 0
      for (i = 1; i <= ne; i++) if ((e[i] in seen) && !(e[i] in counted)) { counted[e[i]] = 1; gone++ }
      conf = (distinct >= 3 && confirmed >= 1 && gone * 2 > distinct && lenses >= 2) ? "high" : "medium"
      nums = ""
      for (i = 1; i <= maxpos; i++) if ((i in pos) && (idof[i] in seen)) nums = nums " #" i
      out = sprintf("%s %s — %s\n  Change (unverified): %s\n  New risk: %s\n  Recommendation: %s\n", conf, rung, summary, change, risk, rec)
      if (landed != "") out = out "  In loop-written code: " landed "\n"
      if (nums != "") out = out "  Decisions:" nums "\n"
      if (conf == "high") hi[++nh] = out; else me[++nm] = out
    }
    BEGIN {
      FS = "\t"
      while ((getline line < indexf) > 0) { split(line, a, "\t"); keyid[a[2]] = a[1] }
      while ((getline line < hitlf) > 0) {
        r++; split(line, a, "\t")
        if (a[4] != "accepted" && (a[1] in keyid)) { pos[r] = 1; idof[r] = keyid[a[1]]; maxpos = r }
      }
      FS = " "; reset()
    }
    /^--- *CLASS *---/ { reset(); inb = 1; next }
    /^--- *END *---/   { if (inb) flush(); inb = 0; next }
    !inb { next }
    /^SUMMARY:/        { summary = val($0); next }
    /^MEMBERS:/        { members = val($0); next }
    /^LENSES:/         { lenses = val($0) + 0; next }
    /^RUNG:/           { rung = val($0); next }
    /^CHANGE:/         { change = val($0); next }
    /^ELIMINATED:/     { elim = val($0); next }
    /^SIBLING:/        { if (val($0) ~ /^confirmed .*[^ ]:[0-9]+/) confirmed++; next }
    /^NEW_RISK:/       { risk = val($0); next }
    /^LANDED:/         { landed = val($0); next }
    /^RECOMMENDATION:/ { rec = val($0); next }
    END {
      c = 0
      for (i = 1; i <= nh; i++) printf "CLASS C%d %s", ++c, hi[i]
      for (i = 1; i <= nm; i++) printf "CLASS C%d %s", ++c, me[i]
      printf "SHOWN: %d\nHIDDEN: %d\n", c, hidden + 0
      if (c) printf "REPORT: %s\n", report
    }
  ' "$F"
}

# ----------------------------------------------------------------

cmd=${1:-}
[ $# -gt 0 ] && shift || true
case "$cmd" in
  init)    cmd_init "$@" ;;
  focus)   cmd_focus "$@" ;;
  collect) cmd_collect "$@" ;;
  absorb)  cmd_absorb "$@" ;;
  resolve) cmd_resolve "$@" ;;
  report)  cmd_report "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  ledger)  cmd_ledger "$@" ;;
  observer-due) cmd_observer_due "$@" ;;
  landed)  sh "$SKILL_DIR/observer-ledger.sh" landed "$@" ;;
  classes) cmd_classes "$@" ;;
  decide)  sh "$SKILL_DIR/observer-ledger.sh" decide "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$cmd' (try --help)" ;;
esac
