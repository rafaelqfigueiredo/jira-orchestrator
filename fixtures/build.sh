#!/usr/bin/env bash
# Builds fixtures/issues/*.json and fixtures/search/*.json from the readable
# markdown in fixtures/src/. Descriptions become real ADF, because that is what
# Jira v3 returns and the pipeline has to handle the real shape.
#
# Also builds fixtures/scenarios/mid-flight/, the same tickets as they would
# look after the orchestrator had already run against them: labels applied and
# a refinement comment posted. That scenario is what makes the reconcile
# acceptance test meaningful - see bin/orc-reconcile.sh.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")/../bin" && pwd)/orc-lib.sh"

SRC="$ORC_ROOT/fixtures/src"
OUT="$ORC_ROOT/fixtures"
MID="$OUT/scenarios/mid-flight"
OVERLAY="$SRC/overlays/mid-flight.tsv"
ANSWERS="$SRC/answers"

mkdir -p "$OUT/issues" "$OUT/search" "$MID/issues" "$MID/search"
rm -f "$OUT/issues"/*.json "$MID/issues"/*.json

fm() {
  awk -v want="$2" '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { exit }
    inside {
      i = index($0, ":")
      if (i > 0) {
        k = substr($0, 1, i-1)
        v = substr($0, i+1)
        sub(/^[ \t]+/, "", v)
        if (k == want) { print v; exit }
      }
    }' "$1"
}

body_of() {
  awk 'NR==1 && $0=="---" { inside=1; next }
       inside && $0=="---" { inside=0; started=1; next }
       started { print }' "$1"
}

labels_json() {
  [ -z "$1" ] && { printf '[]'; return 0; }
  printf '%s' "$1" | tr ',' '\n' | jq -R 'select(length>0)' | jq -sc .
}

# A refinement comment as the orchestrator would have left it, so reconcile has
# a real footprint to recognise.
# The timestamp is the ticket's own last-updated value rather than the clock, so
# a rebuild is a no-op and a diff under fixtures/ means somebody changed a
# ticket. A generator that rewrites its output on every run makes review
# meaningless and turns `git status` into noise.
prior_comment() {
  local key="$1" verdict="$2" rev="$3" at="$4" questions="$5" doc
  doc=$(adf_new)
  doc=$(adf_heading "$doc" 3 "Refinement: $verdict")
  doc=$(adf_para "$doc" "Recorded by an earlier run of the orchestrator against $key.")
  # The questions go in as the orderedList orc-refine.sh builds, because that
  # node is the numbering a reporter answers against. A fixture that rendered
  # them as prose would let bin/orc-harvest.sh pass while matching nothing that
  # a real comment carries.
  if [ -n "$questions" ]; then
    doc=$(adf_para "$doc" "Answering these in the description is enough to unblock it:")
    doc=$(adf_ordered "$doc" "$(printf '%s' "$questions" | tr '|' '\n')")
  fi
  doc=$(adf_para_em "$doc" "$ORC_COMMENT_MARKER prompt=refine-seed0001 ticket-rev=$rev")
  jq -nc --argjson c "$doc" --arg t "$at" '{
    id: "10001", created: $t, updated: $t,
    author: {accountId: "orc-service-account", displayName: "Orchestrator"},
    body: {type: "doc", version: 1, content: $c}
  }'
}

# A person's reply, from fixtures/src/answers/. Authored as markdown for the
# same reason the tickets are: what these fixtures have to exercise is the shape
# a reporter's comment actually arrives in - a numbered list, a "Zu 1:" in front
# of a sentence, or a paragraph addressing nothing - and that is unreadable as
# hand-written ADF.
answer_comment() {
  local f="$1" doc
  doc=$(body_of "$f" | adf_from_markdown | jq -c '.content')
  jq -nc --argjson c "$doc" \
    --arg id "$(fm "$f" id)" --arg t "$(fm "$f" created)" \
    --arg aid "$(fm "$f" author_id)" --arg an "$(fm "$f" author_name)" '{
    id: $id, created: $t, updated: $t,
    author: {accountId: $aid, displayName: $an},
    body: {type: "doc", version: 1, content: $c}
  }'
}

# Every reply to one ticket, oldest first, as Jira returns them.
answers_of() {
  local key="$1" f
  for f in "$ANSWERS"/*.md; do
    [ -e "$f" ] || continue
    [ "$(fm "$f" key)" = "$key" ] || continue
    answer_comment "$f"
  done | jq -sc 'sort_by(.created)'
}

build_issue() {
  local f="$1" key summary itype status labels reporter_id reporter_name created updated
  local desc n comments dest
  key=$(fm "$f" key)
  summary=$(fm "$f" summary)
  itype=$(fm "$f" type)
  status=$(fm "$f" status)
  labels=$(fm "$f" labels)
  reporter_id=$(fm "$f" reporter_id)
  reporter_name=$(fm "$f" reporter_name)
  created=$(fm "$f" created)
  updated=$(fm "$f" updated)
  desc=$(body_of "$f" | adf_from_markdown)
  n=$(printf '%s' "$key" | sed 's/[^0-9]//g')

  local overlay_labels="" overlay_verdict="" overlay_questions=""
  if [ "$2" = "mid-flight" ] && [ -f "$OVERLAY" ]; then
    overlay_labels=$(awk -F'\t' -v k="$key" '$1==k {print $2}' "$OVERLAY")
    overlay_verdict=$(awk -F'\t' -v k="$key" '$1==k {print $3}' "$OVERLAY")
    overlay_questions=$(awk -F'\t' -v k="$key" '$1==k {print $4}' "$OVERLAY")
    [ -n "$overlay_labels" ] && labels="$overlay_labels"
  fi

  comments='[]'
  if [ -n "$overlay_verdict" ]; then
    # The same hash orc-refine.sh computes, so a reconciled state is correctly
    # idempotent: an unchanged ticket is not judged twice.
    local rev
    rev=$(content_hash "$summary$(printf '%s' "$desc" | adf_to_text)")
    comments=$(jq -nc \
      --argjson q "$(prior_comment "$key" "$overlay_verdict" "$rev" "$updated" "$overlay_questions")" \
      --argjson a "$(answers_of "$key")" '[$q] + $a')
  fi

  dest="$OUT/issues"
  [ "$2" = "mid-flight" ] && dest="$MID/issues"

  jq -n \
    --arg id "1$n" --arg key "$key" --arg summary "$summary" \
    --arg itype "$itype" --arg status "$status" \
    --arg rid "$reporter_id" --arg rname "$reporter_name" \
    --arg created "$created" --arg updated "$updated" \
    --argjson desc "$desc" --argjson labels "$(labels_json "$labels")" \
    --argjson comments "$comments" \
    '{
      id: $id, key: $key,
      fields: {
        summary: $summary,
        description: $desc,
        labels: $labels,
        issuetype: {name: $itype},
        status: {name: $status, statusCategory: {key: (if $status=="Done" then "done" else "new" end), name: $status}},
        reporter: {accountId: $rid, displayName: $rname},
        created: $created,
        updated: $updated,
        comment: {comments: $comments, total: ($comments|length), maxResults: 100, startAt: 0}
      }
    }' > "$dest/$key.json"
}

# The response shape of /rest/api/3/search/jql: `isLast`, no `total`, and a
# `nextPageToken` only when there is a further page. A single fixture page is
# always the last one, so it carries no token, which is what tells the poll's
# cursor loop to stop.
build_search() {
  local dir="$1"
  local issues
  issues=$(jq -sc 'sort_by(.fields.updated)' "$dir"/issues/*.json)

  printf '%s' "$issues" | jq '{
    isLast: true,
    issues: [.[] | {id, key, fields: {updated: .fields.updated}}]
  }' > "$dir/search/issues-changed.json"

  printf '%s' "$issues" | jq '[.[] | select(.fields.status.statusCategory.key != "done")] | {
    isLast: true,
    issues: [.[] | {id, key, fields: {summary: .fields.summary, status: .fields.status, issuetype: .fields.issuetype, updated: .fields.updated}}]
  }' > "$dir/search/open-issues.json"

  printf '%s' "$issues" | jq '{
    isLast: true,
    issues: [.[] | {id, key, fields: {summary: .fields.summary, labels: .fields.labels, status: .fields.status, updated: .fields.updated}}]
  }' > "$dir/search/project-issues.json"
}

for f in "$SRC"/ORC-*.md; do
  [ -e "$f" ] || continue
  build_issue "$f" plain
  build_issue "$f" mid-flight
done

build_search "$OUT"
build_search "$MID"

log "built $(find "$OUT/issues" -name '*.json' | wc -l | tr -d ' ') issue fixtures and their search responses"
log "built the mid-flight scenario under fixtures/scenarios/mid-flight"
log "  including $(find "$ANSWERS" -name '*.md' | wc -l | tr -d ' ') reply comment(s) for bin/orc-harvest.sh to read"
