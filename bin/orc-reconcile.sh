#!/usr/bin/env bash
# Rebuilds state/ from Jira and git.
#
# Section 18: if losing state/ is a disaster, the design has a bug. Ticket
# status lives in Jira, code lives in git, and state/ is a cache over both. The
# test of that claim is this script, run after deleting the directory:
#
#   rm -rf state/ && bin/orc-reconcile.sh
#
# What it recovers, and from where:
#   labels          -> the phase and the last verdict
#   comment marker  -> which prompt version judged the ticket, and the revision
#                      of the ticket text it judged, so refinement stays
#                      idempotent across the wipe
#   the comments    -> which of them were already there when it judged, so a
#                      reply that has arrived since still re-opens the round and
#                      one that was already answered does not
#   updated         -> the poll watermark
#   the clones      -> which repository, and at which commit, a locality claim
#                      would be made against now
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

log "reconciling state from Jira and git (mode=$ORC_JIRA_MODE)"
mkdir -p "$STATE_DIR"

# The status is read before anything is piped: in a pipeline it would be jq's,
# and jq always succeeds on an empty stream - so a failed search would arrive
# spelled "the project is empty".
issues=$(jira_search_all "search/project-issues" \
  "project = $JIRA_PROJECT ORDER BY updated ASC" updated 100) \
  || orc_die "could not list the issues in $JIRA_PROJECT"
keys=$(printf '%s' "$issues" | jq -r '.key')

[ -n "$keys" ] || { log "no issues found in project $JIRA_PROJECT; nothing to rebuild"; exit 0; }

# What the clones are at now, one line per project. A reconciled ticket records
# this rather than a single repository, because a ticket can span three of them
# and a bare sha with no repository name tells you nothing.
reasoned_against=""
for name in $(project_names); do
  line=$(repo_provenance "$name")
  reasoned_against="$reasoned_against$line;"
  log "  $line"
done
reasoned_against=${reasoned_against%;}
[ -n "$reasoned_against" ] || log "no projects configured; locality provenance will be blank"

newest=""
n_total=0 n_refined=0

normalise() { printf '%s' "$1" | cut -c1-16 | tr 'T' ' '; }

for key in $keys; do
  issue=$(jira_read "/issue/$key?fields=summary,description,labels,issuetype,status,updated,comment") || continue
  n_total=$(( n_total + 1 ))

  labels=$(printf '%s' "$issue" | jq -r '.fields.labels[]?' | tr '\n' ' ')
  updated=$(printf '%s' "$issue" | jq -r '.fields.updated // ""')

  # The most recent comment this system left, if any. It carries its own
  # provenance, which is the point of putting a marker line in every comment.
  # The reader lives in orc-lib.sh, because bin/orc-harvest.sh reads the same
  # comments for the opposite half - what a person wrote that this did not.
  marker=$(latest_marker_comment "$issue")
  prompt_version=$(marker_value "$marker" prompt)
  ticket_rev=$(marker_value "$marker" ticket-rev)
  refined_at=$(comment_field "$marker" '.created')

  # The newest comment somebody else had left by the time that marker comment
  # was posted, which is what the refinement that posted it saw. Refinement
  # skips a ticket whose text is unchanged and whose newest foreign comment is
  # still the one it recorded, so losing this field would make the first pass
  # after a wipe re-judge every ticket that has ever been replied to - and
  # recording the wrong side of it, the newest comment as it stands now, would
  # be worse: it would swallow a reply nobody has answered yet and strand the
  # loop. The position of this system's own last comment in the thread is what
  # tells the two apart, with no timestamp arithmetic in it.
  comment_seen=$(comment_field "$(foreign_comment_at_last_refinement "$issue")" '.id')

  verdict=""
  phase="unrefined"
  case " $labels " in
    *" $LABEL_IN_PROGRESS "*) phase="implementing" ;;
    *" $LABEL_READY "*)       phase="refined"; verdict="ready" ;;
    *" $LABEL_NEEDS_INPUT "*) phase="refined"; verdict="needs_input" ;;
    *" $LABEL_DUPLICATE "*)   phase="refined"; verdict="duplicate" ;;
  esac
  # A marker comment with no label still means it was judged; the label may have
  # been removed by a human, which is itself a signal worth keeping.
  if [ -z "$verdict" ] && [ -n "$prompt_version" ]; then
    phase="refined"
    verdict="unknown"
  fi

  rm -f "$STATE_DIR/$key.meta"
  meta_set "$key" key "$key"
  meta_set "$key" phase "$phase"
  meta_set "$key" updated "$updated"
  meta_set "$key" labels "${labels% }"
  [ -n "$verdict" ]        && meta_set "$key" verdict "$verdict"
  [ -n "$prompt_version" ] && meta_set "$key" prompt_version "$prompt_version"
  [ -n "$ticket_rev" ]     && meta_set "$key" content_hash "$ticket_rev"
  [ -n "$refined_at" ]     && meta_set "$key" refined_at "$refined_at"
  [ -n "$comment_seen" ]   && meta_set "$key" comment_seen "$comment_seen"
  [ -n "$reasoned_against" ] && meta_set "$key" reasoned_against "$reasoned_against"
  status_add "$key" "reconciled: phase=$phase verdict=${verdict:-none}"

  [ -n "$verdict" ] && n_refined=$(( n_refined + 1 ))

  u=$(normalise "$updated")
  if [ -z "$newest" ] || [ "$u" \> "$newest" ]; then newest="$u"; fi

  printf '  %-10s %-14s %-12s %s\n' "$key" "$phase" "${verdict:-none}" "${prompt_version:-no prompt marker}"
done

[ -n "$newest" ] && printf '%s\n' "$newest" > "$STATE_DIR/.jira-watermark"
beat

log "rebuilt $n_total ticket(s), $n_refined already refined; watermark ${newest:-unset}"
log "state/ is a cache. This script is the proof."
