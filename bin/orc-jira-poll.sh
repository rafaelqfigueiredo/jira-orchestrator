#!/usr/bin/env bash
# Prints one issue key per line, oldest change first, for issues updated since
# the watermark.
#
# Polling rather than webhooks: the trial must not require an inbound endpoint.
# It is the wrong intake mechanism for production and the right one for one
# person on one laptop. Rate limiting (429 with Retry-After) is honoured in
# _jira_http, which every request in this repository goes through.
#
# The watermark is state, so it is disposable: bin/orc-reconcile.sh rebuilds it
# from the issues themselves.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

WATERMARK="$STATE_DIR/.jira-watermark"
since=$(cat "$WATERMARK" 2>/dev/null || true)

# Jira compares JQL timestamps to the minute, so the watermark is stored that
# way and the same string is used to filter fixtures.
normalise() { printf '%s' "$1" | cut -c1-16 | tr 'T' ' '; }

# The opt-in clause is part of the query rather than a filter over the results,
# so a card nobody asked for costs no page of results and no read. It is empty
# unless the operator named a label.
#
# It sits beside the watermark rather than replacing it, and the two compose the
# way an operator would hope: labelling a card is itself an edit, so Jira moves
# that card's `updated` to the moment the label was added and the next poll sees
# it. A gate that only ever admitted cards edited after labelling would be
# useless for the thing it was built for, which is labelling cards that already
# exist.
#
# The one case it does not cover is a card labelled while the gate was off, or
# before the watermark: nothing has touched it since, so its `updated` is behind
# and the poll is right not to offer it. state/ is a cache - deleting
# state/.jira-watermark asks from the beginning again, which is `-7d` below.
#
# Fixture mode reads a canned page instead of asking this question, and the
# response names `updated` and nothing else, so a fixture run's gate is
# refinement's rather than the poll's. It is not duplicated here: the gate is one
# rule in one place, and a second copy of it that only fixture mode ran would be
# the copy nobody noticed had drifted.
fetch_page() {
  jira_search_all "search/issues-changed" \
    "project = $JIRA_PROJECT$(opt_in_clause) AND updated >= \"${since:--7d}\" ORDER BY updated ASC" \
    updated 50
}

# The cursor loop is jira_search_all, in orc-lib.sh, because bin/orc-harvest.sh
# reads the project the same way and two spellings of "when has a cursor ended"
# would eventually disagree about the page that has a token and no issues on it -
# which is the page every wrong termination condition drops.
issues=$(fetch_page) || orc_die "poll failed"

selected=""
newest="$since"
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  k=$(printf '%s' "$issue" | jq -r '.key')
  u=$(normalise "$(printf '%s' "$issue" | jq -r '.fields.updated // ""')")
  if [ -n "$since" ] && [ -n "$u" ]; then
    # The watermark is inclusive, so an issue updated in the same minute as the
    # last poll is seen again rather than missed. Refinement is idempotent on
    # ticket content, so seeing one twice costs nothing.
    [ "$u" \< "$since" ] && continue
  fi
  selected="$selected$k
"
  if [ -z "$newest" ] || [ "$u" \> "$newest" ]; then newest="$u"; fi
done <<< "$issues"

# The gate is named in the log rather than left to be inferred from a count: a
# poll that reports nothing while a board is full of tickets is exactly when an
# operator needs to be told which question was asked. Said only when the query
# actually carried the clause, so a fixture run - which reads a canned page -
# does not report a narrowing that never happened.
gated=""
if [ -n "$LABEL_OPT_IN" ] && [ "$ORC_JIRA_MODE" != "fixture" ]; then
  gated=" labelled $LABEL_OPT_IN and"
fi
count=$(printf '%s' "$selected" | grep -c . || true)
if [ "$count" = "0" ]; then
  log "no issues${gated} updated since ${since:-the beginning}"
else
  log "$count issue(s)${gated} updated since ${since:-the beginning}"
fi

printf '%s' "$selected"

# An `if` rather than a `&&` chain, because this is the last statement in the
# script and its status is the script's. Nothing updated means no newest, and a
# poll that found nothing has not failed - the daemon reads a non-zero status
# here as "poll failed" and abandons the whole pass.
if [ -n "$newest" ]; then printf '%s\n' "$newest" > "$WATERMARK"; fi
