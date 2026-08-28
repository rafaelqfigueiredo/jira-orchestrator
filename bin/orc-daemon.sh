#!/usr/bin/env bash
# The loop. Run this; everything else is called from here.
#
# Phase 1 is refinement only: sync the clones, poll, judge, comment, label. There
# is no dispatch,
# no sandbox and no implementation agent, so there is nothing in flight to
# supervise and the loop is a plain interval rather than a blocking watch.
#
#   orc-daemon.sh                 one pass over the fixtures, then exit
#   orc-daemon.sh --loop          keep polling
#   orc-daemon.sh --once          one pass, whatever the mode
#
# A pass also asks, at most once an hour, whether the knowledge bundle still says
# what the repositories say, and warns by name when it does not. It never drafts:
# see bundle_drift below for why the warning lives here and why it stops at a
# warning. ORC_BUNDLE_CHECK=off turns the asking off, ORC_BUNDLE_CHECK_TTL
# changes how often it happens.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

INTERVAL="${ORC_POLL_INTERVAL:-60}"
once=""
extra_args=""

while [ $# -gt 0 ]; do
  case "$1" in
    --once)     once=1 ;;
    --loop)     once=0 ;;
    --interval) INTERVAL="$2"; shift ;;
    --force)    extra_args="--force" ;;
    -h|--help)  orc_usage "$0"; exit 0 ;;
    *)          orc_die "unknown option: $1" ;;
  esac
  shift
done

# Fixture mode describes a frozen world, so looping over it forever would only
# reprint the same verdicts. One pass unless asked otherwise.
if [ -z "$once" ]; then
  if [ "$ORC_JIRA_MODE" = "fixture" ]; then once=1; else once=0; fi
fi

log "orchestrator starting: phase 1, refinement only"
orc_mode_banner

# One sync per pass rather than one per ticket. Refinement asks for a fetch too,
# and the freshness cache in state/ makes that a no-op the rest of the pass, but
# doing it here means the report is printed once and read once.
sync_repos() {
  case "${ORC_REPO_SYNC:-auto}" in
    off) return 0 ;;
    auto) [ -n "$(managed_projects)" ] || return 0 ;;
  esac
  "$ORC_ROOT/bin/orc-repos-sync.sh" \
    || log "at least one clone is stuck; tickets about it will say so rather than guess"
}

# How long a bundle check is considered fresh, and how long it may take. It
# re-renders every concept from every configured repository, so it costs about
# what one refinement's reading costs: too much for every poll, nothing at all
# once an hour. Same stamp shape as the clone fetch above, in the same state/
# cache, for the same reason.
BUNDLE_CHECK_TTL="${ORC_BUNDLE_CHECK_TTL:-3600}"
BUNDLE_CHECK_TIMEOUT="${ORC_BUNDLE_CHECK_TIMEOUT:-120}"
BUNDLE_STATE="$STATE_DIR/.bundle"

concepts_n() { [ "$1" = "1" ] && printf '1 concept' || printf '%s concepts' "$1"; }

# Is the bundle still what the repositories say?
#
# bin/orc-okf-draft.sh --check has always answered this correctly and nothing
# in the ordinary path ever asked, so a drafted concept whose evidence had moved
# went on being read by refinement as a live lead and nobody was told. This is
# where the asking belongs: it is the only script that runs unattended and
# repeatedly, so the answer arrives without anybody remembering to look, and it
# already syncs once per pass so a second once-per-pass report reads as of a
# piece with the first. bin/orc-refine.sh would be closer to the reading and is
# the wrong place anyway: it runs once per ticket, so a five-ticket pass would
# print one banner five times - which is the mistake the stuck counter already
# learned about one layer further down.
#
# It warns and it stops there. .okf/ is source: a human consented to what is in
# it, exactly as with config/projects.yml and with a Jira write. Detect, then let
# a human decide. So this names the concepts and prints the command, and there is
# no switch here that drafts.
bundle_drift() {
  local drifted rc
  case "${ORC_BUNDLE_CHECK:-auto}" in
    off) return 0 ;;
    auto) [ -d "$BUNDLE_DIR" ] || return 0 ;;
  esac
  stamp_is_fresh "$BUNDLE_STATE/checked" "$BUNDLE_CHECK_TTL" && return 0

  # Sorted, so the recorded cause is the set of drifted concepts rather than the
  # order the generator happened to visit them in. Reordering config/projects.yml
  # is not a new cause and must not re-announce an old one.
  drifted=$(run_with_timeout "$BUNDLE_CHECK_TIMEOUT" \
    "$ORC_ROOT/bin/orc-okf-draft.sh" --drifted)
  # Read before the sort. A pipe would make the exit status sort's, and sort
  # always succeeds - so "could not decide" would arrive spelled as "clean".
  rc=$?
  drifted=$(printf '%s' "$drifted" | sort)
  mkdir -p "$BUNDLE_STATE" 2>/dev/null
  # Stamped whether or not it decided. The stamp is about what the read costs,
  # and a read that timed out or met an unreadable checkout cost the same as one
  # that answered.
  stamp_write "$BUNDLE_STATE/checked"

  # Empty output is never drift, whatever the exit status was. A shrunken listing
  # from a checkout that could not be read is not the bundle moving, and saying
  # it was would send somebody to draft over a concept that is still correct.
  if [ -z "$drifted" ]; then
    [ "$rc" = "0" ] || { log "could not tell whether the bundle still matches the repositories; bin/orc-repos-sync.sh says why"; return 0; }
    if [ -f "$BUNDLE_STATE/announced" ]; then
      rm -f "$BUNDLE_STATE/announced"
      log "the bundle matches the repositories again"
    fi
    return 0
  fi

  # One warning per cause, and the cause is *which* concepts moved rather than
  # the fact that some did. A banner on every poll is one an operator learns to
  # scroll past, and then the one that mattered goes past unread with it.
  printf '%s\n' "$drifted" > "$BUNDLE_STATE/announced.new"
  if [ -f "$BUNDLE_STATE/announced" ] \
     && cmp -s "$BUNDLE_STATE/announced.new" "$BUNDLE_STATE/announced"; then
    rm -f "$BUNDLE_STATE/announced.new"
    return 0
  fi
  mv "$BUNDLE_STATE/announced.new" "$BUNDLE_STATE/announced"

  banner "THE BUNDLE IS NOT WHAT THE REPOSITORIES SAY - $(concepts_n "$(printf '%s\n' "$drifted" | grep -c .)").

Refinement reads a drafted concept as a live lead. Each of these was drafted from evidence that has moved since, so the lead now points at code that is not there any more:

$(printf '%s\n' "$drifted" | sed 's#^#  .okf/#')

Nothing here re-drafted any of them, and nothing here will. .okf/ is source, a human consented to what is in it, and the rule is the same one config/projects.yml and a Jira write get: detect, then let a human decide. Read what moved, then draft:

  bin/orc-okf-draft.sh --check
  bin/orc-okf-draft.sh

Said once per set of drifted concepts rather than once per pass, so it stays worth reading: this will not print again until that set changes. state/ is a cache, so deleting state/.bundle asks again."
}

pass() {
  local keys key labels verdict
  local n_ready=0 n_needs=0 n_dup=0 n_skipped=0 n_failed=0

  sync_repos
  bundle_drift
  keys=$("$ORC_ROOT/bin/orc-jira-poll.sh") || { log "poll failed"; return 1; }

  for key in $keys; do
    [ -n "$key" ] || continue
    labels=$(jira_read "/issue/$key?fields=labels" | jq -r '.fields.labels[]?' | tr '\n' ' ')

    case " $labels " in
      *" $LABEL_IN_PROGRESS "*)
        log "$key: labelled $LABEL_IN_PROGRESS, leaving it alone"
        n_skipped=$(( n_skipped + 1 ))
        continue
        ;;
      *" $LABEL_READY "*)
        log "$key: already $LABEL_READY; phase 1 stops here"
        n_skipped=$(( n_skipped + 1 ))
        continue
        ;;
    esac

    # shellcheck disable=SC2086
    "$ORC_ROOT/bin/orc-refine.sh" $extra_args "$key"
    case "$?" in
      0)
        verdict=$(meta_get "$key" verdict)
        case "$verdict" in
          ready)       n_ready=$(( n_ready + 1 )) ;;
          needs_input) n_needs=$(( n_needs + 1 )) ;;
          duplicate)   n_dup=$(( n_dup + 1 )) ;;
          *)           n_skipped=$(( n_skipped + 1 )) ;;
        esac
        ;;
      3) n_skipped=$(( n_skipped + 1 )) ;;
      *) log "$key: refinement failed"; n_failed=$(( n_failed + 1 )) ;;
    esac
  done

  log "pass complete: ready=$n_ready needs_input=$n_needs duplicate=$n_dup untouched=$n_skipped failed=$n_failed"
  [ "$n_failed" = "0" ]
}

rc=0
while :; do
  beat
  pass || rc=1
  [ "$once" = "1" ] && break
  log "sleeping ${INTERVAL}s"
  sleep "$INTERVAL"
done

if ! orc_writes_are_live; then
  log "nothing was sent. The full transcript of what would have been posted is in state/.would-write.log"
fi
exit "$rc"
