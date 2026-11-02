#!/usr/bin/env bash
# watch-pr.sh — event stream for one pull request, built for the Monitor tool.
#
# Prints one line when something changes and stays silent otherwise:
#   watching:        first arm of a new state dir (snapshot of where the PR stands)
#   check-failed:    a check on the head commit failed
#   check-cancelled: a check on the head commit was cancelled
#   ci-finished:     no checks pending, some failed or were cancelled
#   ci-green:        no checks pending, none failed
#   ci-missing:      the required workflow never started for the head commit
#   thread:          an unresolved inline thread needs an answer
#   thread-update:   someone replied on a thread after its first comment
#   review:          a review was submitted
#   top-level:       a PR-level comment was posted
#   conflict:        the PR conflicts with its base
#   quiet:           CI settled and nothing new for --quiet-after seconds (exits 0)
#   closed:          the PR merged or closed (exits 0)
#   already-watching: another copy is already watching with this state dir (exits 0)
#   watch-error:     gh keeps failing, or the arguments are wrong
#
# Events already printed are recorded in --state-dir, so running again with the
# same dir never repeats one. Works with macOS bash 3.2.

set -u

PR=""
REPO=""
STATE_DIR=""
INTERVAL=45
QUIET_AFTER=900
CI_GRACE=600
REQUIRE_WORKFLOW="CI/CD"
ONCE=0
IGNORE_AUTHORS="${ALAN_SHIP_IGNORE_AUTHORS:-linear-code[bot],vercel[bot],github-actions[bot]}"

usage() {
  cat <<'EOF'
Usage: watch-pr.sh <pr-number> [options]

  --state-dir DIR          where seen events are kept (default: $TMPDIR/alan-ship/<repo>-<pr>)
  --repo OWNER/NAME        default: the repo of the current directory
  --interval SECONDS       gap between GitHub checks (default 45)
  --quiet-after SECONDS    exit once CI is settled and nothing new arrived for this long (default 900)
  --ci-grace SECONDS       how long the required workflow may take to appear (default 600)
  --require-workflow NAME  workflow that must run before CI counts as done (default "CI/CD"; '' disables)
  --once                   check once, print any events, exit

  ALAN_SHIP_IGNORE_AUTHORS  comma-separated logins whose top-level comments are skipped
EOF
}

die() {
  printf 'watch-error: %s\n' "$1"
  exit 2
}

need_value() {
  [ "$2" -ge 2 ] || die "$1 needs a value"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --state-dir) need_value "$1" $#; STATE_DIR="$2"; shift 2 ;;
    --interval) need_value "$1" $#; INTERVAL="$2"; shift 2 ;;
    --quiet-after) need_value "$1" $#; QUIET_AFTER="$2"; shift 2 ;;
    --ci-grace) need_value "$1" $#; CI_GRACE="$2"; shift 2 ;;
    --require-workflow) need_value "$1" $#; REQUIRE_WORKFLOW="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) PR="$1"; shift ;;
  esac
done

case "$PR" in
  '' | *[!0-9]*) die "pass the PR number, e.g. watch-pr.sh 1234" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || REPO=""
fi
[ -n "$REPO" ] || die "could not work out the repo; pass --repo owner/name"
OWNER=${REPO%%/*}
NAME=${REPO#*/}

ME=$(gh api user --jq .login 2>/dev/null) || ME=""
[ -n "$ME" ] || die "gh is not signed in (run: gh auth status)"

[ -n "$STATE_DIR" ] || STATE_DIR="${TMPDIR:-/tmp}/alan-ship/${OWNER}-${NAME}-${PR}"
mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"

SEEN="$STATE_DIR/seen"
LAST_EVENT="$STATE_DIR/last_event"
HEAD_FILE="$STATE_DIR/head"
PR_JSON="$STATE_DIR/pr.json"
CHECKS_JSON="$STATE_DIR/checks.json"
FAILING_KEYS="$STATE_DIR/failing.keys"
ERR="$STATE_DIR/gh.err"
PID_FILE="$STATE_DIR/pid"
SLEEP_PID=""

# One watcher per state dir: two copies would race on the seen file.
if [ "$ONCE" != 1 ]; then
  other=$(cat "$PID_FILE" 2>/dev/null)
  case "$other" in
    '' | *[!0-9]*) other="" ;;
  esac
  if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null &&
    ps -p "$other" -o command= 2>/dev/null | grep -q 'watch-pr\.sh'; then
    printf 'already-watching: PR #%s is already being watched (pid %s); this copy exits\n' "$PR" "$other"
    exit 0
  fi
  printf '%s\n' "$$" >"$PID_FILE"
  cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    if [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then rm -f "$PID_FILE"; fi
  }
  trap cleanup EXIT
  trap 'exit 143' TERM INT HUP
fi

if [ -f "$SEEN" ]; then FIRST_RUN=0; else FIRST_RUN=1; fi

# shellcheck disable=SC2016
QUERY='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
  number state mergeable headRefOid baseRefName
  reviewThreads(first:100){nodes{
    id isResolved isOutdated path line originalLine
    first:comments(first:1){nodes{databaseId body author{login __typename}}}
    last:comments(last:1){nodes{databaseId body author{login __typename}}}
  }}
  reviews(last:50){nodes{databaseId state body author{login __typename}}}
  comments(last:50){nodes{databaseId body author{login __typename}}}
}}}'

# shellcheck disable=SC2016
JQ_DEFS='
def who: (.author // {login: "ghost", __typename: "User"}) as $a
  | if $a.__typename == "Bot" and ($a.login | endswith("[bot]") | not)
    then $a.login + "[bot]" else $a.login end;
def clip($n): (. // "") | gsub("\\s+"; " ") | gsub("<!--.*?-->"; "")
  | gsub("!\\[[^\\]]*\\]\\([^)]*\\)"; "") | gsub("</?[a-zA-Z][^>]*>"; "")
  | gsub(" +"; " ") | sub("^ "; "")
  | if length > $n then .[0:$n] + "…" else . end;
def needs_answer: select(.isResolved | not)
  | select(.last.nodes[0] != null and (.last.nodes[0] | who) != $me);
'

# shellcheck disable=SC2016
JQ_EVENTS="$JQ_DEFS"'
($pr[0].data.repository.pullRequest) as $p
| ($ignore | split(",")) as $ign
| (
    (if $p.mergeable == "CONFLICTING"
     then "conflict:\($sha)\tconflict: PR #\($p.number) conflicts with \($p.baseRefName)"
     else empty end),
    ($checks[0][] | select(.bucket == "fail" or .bucket == "cancel")
      | ((.workflow // "") + "/" + .name) as $id
      | "fail:\($sha):\($id)\t"
        + (if .bucket == "cancel" then "check-cancelled" else "check-failed" end)
        + ": \($id | ltrimstr("/")) \(.link // "")"),
    ($p.reviewThreads.nodes[] | needs_answer
      | .first.nodes[0] as $f | .last.nodes[0] as $l
      | "thread:\(.id):\($l.databaseId)\t"
        + (if $f.databaseId == $l.databaseId then "thread" else "thread-update" end)
        + ": \($l | who) \(.path):\(.line // .originalLine // "?")"
        + (if .isOutdated then " (outdated)" else "" end)
        + " — \($l.body | clip(140)) [comment \($f.databaseId)]"),
    ($p.reviewThreads.nodes[] | select(.isResolved)
      | .first.nodes[0] as $f | .last.nodes[0] as $l
      | select($l != null and $f.databaseId != $l.databaseId and ($l | who) != $me)
      | "rthread:\(.id):\($l.databaseId)\tthread-update: \($l | who) \(.path):\(.line // .originalLine // "?")"
        + " (resolved) — \($l.body | clip(140)) [comment \($f.databaseId)]"),
    ($p.reviews.nodes[] | who as $w | select($w != $me and .state != "PENDING")
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or ((.body // "") | length) > 0)
      | "review:\(.databaseId)\treview: \($w) \(.state)"
        + (if ((.body // "") | length) > 0 then " — \(.body | clip(140))" else "" end)),
    ($p.comments.nodes[] | who as $w | select($w != $me and ($ign | index($w) | not))
      | "comment:\(.databaseId)\ttop-level: \($w) — \(.body | clip(140))")
  )
'

now() { date +%s; }

mark() { printf '%s\n' "$1" >>"$SEEN"; }

emit() {
  if ! grep -qxF -- "$1" "$SEEN" 2>/dev/null; then
    printf '%s\n' "$2"
    mark "$1"
    now >"$LAST_EVENT"
  fi
}

forget() {
  grep -vxF -- "$1" "$SEEN" >"$SEEN.tmp" 2>/dev/null
  mv "$SEEN.tmp" "$SEEN"
}

# One look at GitHub. Returns 1 when gh failed so the caller can retry later.
cycle() {
  gh api graphql -f query="$QUERY" -f o="$OWNER" -f r="$NAME" -F n="$PR" >"$PR_JSON" 2>"$ERR" || return 1
  jq -e '.data.repository.pullRequest' "$PR_JSON" >/dev/null 2>&1 || {
    printf 'no pull request #%s in %s\n' "$PR" "$REPO" >"$ERR"
    return 1
  }

  gh pr checks "$PR" --repo "$REPO" --json name,bucket,workflow,link >"$CHECKS_JSON" 2>"$ERR"
  if ! jq -e 'type == "array"' "$CHECKS_JSON" >/dev/null 2>&1; then
    if grep -qi 'no checks reported' "$ERR"; then
      printf '[]' >"$CHECKS_JSON"
    else
      return 1
    fi
  fi

  local state sha short prev_sha since age
  state=$(jq -r '.data.repository.pullRequest.state' "$PR_JSON")
  if [ "$state" != "OPEN" ]; then
    printf 'closed: PR #%s is %s — watch ended\n' "$PR" "$state"
    exit 0
  fi

  sha=$(jq -r '.data.repository.pullRequest.headRefOid' "$PR_JSON")
  short=$(printf '%s' "$sha" | cut -c1-7)
  prev_sha=$(cut -d' ' -f1 "$HEAD_FILE" 2>/dev/null)
  if [ "$sha" != "$prev_sha" ]; then
    printf '%s %s\n' "$sha" "$(now)" >"$HEAD_FILE"
    now >"$LAST_EVENT"
  fi
  since=$(cut -d' ' -f2 "$HEAD_FILE")
  age=$(($(now) - since))

  local total pending failed cancelled passed skipped has_required
  read -r total pending failed cancelled passed skipped has_required <<EOF
$(jq -r --arg w "$REQUIRE_WORKFLOW" '[
    length,
    (map(select(.bucket == "pending")) | length),
    (map(select(.bucket == "fail")) | length),
    (map(select(.bucket == "cancel")) | length),
    (map(select(.bucket == "pass")) | length),
    (map(select(.bucket == "skipping")) | length),
    (if $w == "" then 1 elif (map(select(.workflow == $w)) | length) > 0 then 1 else 0 end)
  ] | @tsv' "$CHECKS_JSON")
EOF

  local open_threads
  open_threads=$(jq -r --arg me "$ME" "$JQ_DEFS"'[.data.repository.pullRequest.reviewThreads.nodes[] | needs_answer] | length' "$PR_JSON")

  local baseline=0
  if [ "$FIRST_RUN" = 1 ]; then
    : >"$SEEN"
    baseline=1
    FIRST_RUN=0
    printf 'watching: PR #%s head %s — checks: %s passed, %s pending, %s failed; %s review thread(s) need an answer\n' \
      "$PR" "$short" "$passed" "$pending" "$((failed + cancelled))" "$open_threads"
  fi

  # A check that failed earlier and is now running again or passing must be able to fail again.
  jq -r --arg sha "$sha" '.[] | select(.bucket == "fail" or .bucket == "cancel")
    | "fail:\($sha):\((.workflow // "") + "/" + .name)"' "$CHECKS_JSON" >"$FAILING_KEYS"
  {
    grep -v '^fail:' "$SEEN"
    if [ -s "$FAILING_KEYS" ]; then grep '^fail:' "$SEEN" | grep -xFf "$FAILING_KEYS"; fi
  } >"$SEEN.tmp" 2>/dev/null
  mv "$SEEN.tmp" "$SEEN"
  if [ "$pending" -gt 0 ]; then
    forget "green:$sha"
    forget "finished:$sha"
  fi

  local key line
  while IFS=$'\t' read -r key line; do
    [ -n "$key" ] || continue
    if [ "$baseline" = 1 ]; then
      case "$key" in
        review:* | comment:* | rthread:*)
          mark "$key"
          continue
          ;;
      esac
    fi
    emit "$key" "$line"
  done < <(jq -rn --slurpfile pr "$PR_JSON" --slurpfile checks "$CHECKS_JSON" \
    --arg me "$ME" --arg sha "$sha" --arg ignore "$IGNORE_AUTHORS" "$JQ_EVENTS" 2>>"$ERR")

  if [ "$pending" -eq 0 ] && [ "$total" -gt 0 ]; then
    if [ $((failed + cancelled)) -gt 0 ]; then
      emit "finished:$sha" "ci-finished: $failed failed, $cancelled cancelled, $passed passed (head $short)"
    elif [ "$has_required" = 1 ]; then
      emit "green:$sha" "ci-green: $passed passed, $skipped skipped (head $short)"
    fi
  fi
  if [ "$has_required" != 1 ] && [ "$age" -ge "$CI_GRACE" ]; then
    emit "missing:$sha" "ci-missing: no \"$REQUIRE_WORKFLOW\" run for head $short after $((CI_GRACE / 60))m — $total other check(s) present"
  fi

  [ "$ONCE" = 1 ] && return 0

  local settled=0 idle
  if [ "$pending" -eq 0 ]; then
    if [ "$total" -gt 0 ] && [ "$has_required" = 1 ]; then
      settled=1
    elif [ "$age" -ge "$CI_GRACE" ]; then
      settled=1
    fi
  fi
  idle=$(($(now) - $(cat "$LAST_EVENT")))
  if [ "$settled" = 1 ] && [ "$idle" -ge "$QUIET_AFTER" ]; then
    printf 'quiet: nothing new for %sm — %s failing check(s), %s review thread(s) still need an answer (head %s). Watch ended.\n' \
      "$((QUIET_AFTER / 60))" "$((failed + cancelled))" "$open_threads" "$short"
    exit 0
  fi
  return 0
}

now >"$LAST_EVENT"
failures=0
while :; do
  if cycle; then
    failures=0
  else
    failures=$((failures + 1))
    if [ "$ONCE" = 1 ]; then
      printf 'watch-error: %s\n' "$(tail -n 1 "$ERR" 2>/dev/null)"
      exit 1
    fi
    if [ "$failures" -eq 5 ]; then
      printf 'watch-error: gh failed 5 times in a row: %s\n' "$(tail -n 1 "$ERR" 2>/dev/null)"
    fi
  fi
  [ "$ONCE" = 1 ] && exit 0
  # Sleep in the background so a kill from the Monitor ends the script at once.
  sleep "$INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
done
