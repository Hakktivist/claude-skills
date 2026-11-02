#!/usr/bin/env bash
# reply-thread.sh — answer one inline review thread and resolve it.
#
#   reply-thread.sh <pr> --list
#       unresolved threads: comment id, author, path:line, excerpt
#   reply-thread.sh <pr> <comment-id> '<addressed|wontfix> - <one line>' [--dry-run]
#       reply on that comment's thread, then resolve the thread
#
# The reply must be "addressed - ..." or "wontfix - ..." on a single line; anything
# else is refused. Replies only ever go on an inline thread, never top-level.
# Works with macOS bash 3.2.

set -u

REPO=""
DRY_RUN=0
LIST=0
ARGS=()

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --list) LIST=1; shift ;;
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

PR="${ARGS[0]-}"
case "$PR" in
  '' | *[!0-9]*) die "pass the PR number first" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || REPO=""
fi
[ -n "$REPO" ] || die "could not work out the repo; pass --repo owner/name"
OWNER=${REPO%%/*}
NAME=${REPO#*/}

# shellcheck disable=SC2016
QUERY='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
  reviewThreads(first:100){nodes{
    id isResolved isOutdated path line originalLine
    comments(first:50){nodes{databaseId body author{login}}}
  }}
}}}'

THREADS=$(gh api graphql -f query="$QUERY" -f o="$OWNER" -f r="$NAME" -F n="$PR") || die "could not read the threads of PR #$PR"

if [ "$LIST" = 1 ]; then
  printf '%s' "$THREADS" | jq -r '
    .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
    | .comments.nodes[0] as $f
    | "\($f.databaseId)\t\($f.author.login // "ghost")\t\(.path):\(.line // .originalLine // "?")"
      + (if .isOutdated then " (outdated)" else "" end)
      + "\t" + (($f.body // "") | gsub("\\s+"; " ") | .[0:120])'
  exit 0
fi

COMMENT_ID="${ARGS[1]-}"
BODY="${ARGS[2]-}"
case "$COMMENT_ID" in
  '' | *[!0-9]*) die "pass the comment id (see --list)" ;;
esac

case "$BODY" in
  *$'\n'*) die "the reply must be one line" ;;
esac
printf '%s' "$BODY" | grep -Eq '^(addressed|wontfix) - [^[:space:]].*$' ||
  die "the reply must read 'addressed - <one line>' or 'wontfix - <one line>'"
[ "${#BODY}" -le 200 ] || die "the reply is ${#BODY} characters; keep it to one short line (200 max)"

THREAD=$(printf '%s' "$THREADS" | jq -c --argjson id "$COMMENT_ID" '
  [.data.repository.pullRequest.reviewThreads.nodes[]
    | select(any(.comments.nodes[]; .databaseId == $id))][0] // empty')
[ -n "$THREAD" ] || die "no inline thread on PR #$PR contains comment $COMMENT_ID"

THREAD_ID=$(printf '%s' "$THREAD" | jq -r '.id')
FIRST_ID=$(printf '%s' "$THREAD" | jq -r '.comments.nodes[0].databaseId')
WHERE=$(printf '%s' "$THREAD" | jq -r '"\(.path):\(.line // .originalLine // "?")"')
RESOLVED=$(printf '%s' "$THREAD" | jq -r '.isResolved')

if [ "$DRY_RUN" = 1 ]; then
  printf 'dry run: would reply on %s (comment %s) and resolve thread %s — %s\n' "$WHERE" "$FIRST_ID" "$THREAD_ID" "$BODY"
  exit 0
fi

gh api "repos/$REPO/pulls/$PR/comments/$FIRST_ID/replies" -f body="$BODY" --silent ||
  die "the reply on $WHERE was not posted"

if [ "$RESOLVED" != "true" ]; then
  # shellcheck disable=SC2016
  gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
    -f id="$THREAD_ID" --silent || die "replied on $WHERE but could not resolve the thread"
fi

printf 'replied and resolved: %s — %s\n' "$WHERE" "$BODY"
