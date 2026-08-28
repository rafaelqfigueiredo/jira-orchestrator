#!/usr/bin/env bash
# The whole pass, in one command.
#
# A cycle is four scripts run in order - bin/orc-daemon.sh to refine,
# bin/orc-harvest.sh to read what reporters answered, bin/orc-gap-loop.sh to
# rank what stayed unresolved, bin/orc-okf-draft.sh to draft - and until now
# running all four, in order, with the right flags on each, was the operator's
# job. This composes them the way bin/orc-onboard.sh composes discovery, sync
# and the drafter: it calls each script as a subprocess and reports what each
# one said. It reimplements nothing.
#
#   orc-cycle.sh                      one pass: refine, harvest, gap-rank, draft
#   orc-cycle.sh --force              forwarded to refine (bin/orc-daemon.sh --force)
#   orc-cycle.sh --bundle DIR         forwarded to harvest, gap-rank and draft
#   orc-cycle.sh --basis LIST         forwarded to gap-rank (bin/orc-gap-loop.sh --basis)
#   orc-cycle.sh --min-tickets N      forwarded to gap-rank
#
# Each step's own flags stay reachable by calling that script directly - this
# is the common path through all four, not a superset of everything any one of
# them can do. bin/orc-harvest.sh --key ORC-102, for one ticket rather than the
# whole project, is still bin/orc-harvest.sh's to offer.
#
# ## What each call actually drafts
#
# bin/orc-harvest.sh --draft writes domain/reporter-answers.md, through the
# same publish() as every other concept. bin/orc-gap-loop.sh --draft writes
# domain/open-vocabulary.md the same way. Both exist on disk before the fourth
# call runs, so the plain bin/orc-okf-draft.sh at the end - no --answers, no
# --gap-terms - drafts everything else (the subsystems, the glossary, the
# reference, the capabilities) and still lists both of the concepts the
# earlier two steps just wrote: the index lists what is on disk, not what a
# given run happened to pass. Nothing here reads an answer or a gap term, and
# nothing here renders either concept - that machinery stays in the two
# scripts that already own it, which is what "reimplements nothing" means in
# practice rather than in the abstract.
#
# A drift warning bin/orc-daemon.sh prints during the refine step, about the
# real bundle at $ORC_ROOT/.okf, is resolved by the fourth step in the same
# run: that banner only ever warns, and this script is what actually redrafts.
#
# ## Write gates
#
# Untouched, on purpose. A Jira write still needs ORC_JIRA_MODE=live and
# DRY_RUN=0, both, and this script neither reads nor sets either one:
# bin/orc-daemon.sh enforces them on the refine step, and bin/orc-harvest.sh
# writes nothing to Jira at all, ever. LABEL_OPT_IN is the daemon's own gate on
# which tickets are in scope for refinement; this script does not read it,
# does not pass it, and does not widen what it gates - passing through is the
# whole of this script's involvement with it.
#
# A bundle draft is a different kind of write: a local, git-reviewed file
# rather than a post to Jira, and it happens for real on every run of this
# script, in every Jira mode, exactly as running bin/orc-okf-draft.sh by hand
# already does. A concept a human has verified is still never touched -
# bin/orc-okf-draft.sh refuses that on its own - and this script does not
# quiet the report of it: no step below is run with --quiet, so the SKIPPED
# banner naming what was left alone prints in the composed output rather than
# being buried in composition.
#
# ## A step failing
#
# All four run regardless of what the ones before them returned: a refine pass
# that failed does not hide a harvest that would have worked, and the report
# says what ran and what each one's own exit code was. A step's own exit code
# means what that step's own header already documents - 0 is its own clean
# report, 1 is its own "something is in this report worth reading," the same
# convention every script here already uses for itself. This script's own exit
# code is 1 if any step's was, and 0 only if every one of them was clean.
#
# Exit codes: 0 nothing needs attention anywhere in the pass, 1 something does.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

# Beside this script, not under ORC_ROOT: ORC_ROOT is overridable, and a run
# that pointed it elsewhere would compose four scripts that are not these ones.
BIN=$(cd "$(dirname "$0")" && pwd)
DAEMON="$BIN/orc-daemon.sh"
HARVEST="$BIN/orc-harvest.sh"
GAPLOOP="$BIN/orc-gap-loop.sh"
DRAFTER="$BIN/orc-okf-draft.sh"

# Spelled out rather than assembled from $0: bin/orc-check.sh reads the script
# names this repository speaks out of the source, and a name built at run time
# is invisible to it.
SELF="bin/orc-cycle.sh"

BUNDLE=""
BASIS=""
MIN_TICKETS=""
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force)       force=1; hint_flag --force ;;
    --bundle)      shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1"
                   hint_flag --bundle "$1" ;;
    --basis)       shift; [ $# -gt 0 ] || orc_die "--basis needs a list"; BASIS="$1"
                   hint_flag --basis "$1" ;;
    --min-tickets) shift; [ $# -gt 0 ] || orc_die "--min-tickets needs a number"; MIN_TICKETS="$1"
                   hint_flag --min-tickets "$1" ;;
    -h|--help)     orc_usage "$0"; exit 0 ;;
    -*)            orc_die "unknown option: $1" ;;
    *)             orc_die "unexpected argument: $1" ;;
  esac
  shift
done

RESOLVED_BUNDLE="${BUNDLE:-$BUNDLE_DIR}"

bundle_args=""
[ -n "$BUNDLE" ] && bundle_args=" --bundle $BUNDLE"

gap_args="$bundle_args"
[ -n "$BASIS" ] && gap_args="$gap_args --basis $BASIS"
[ -n "$MIN_TICKETS" ] && gap_args="$gap_args --min-tickets $MIN_TICKETS"

daemon_args="--once"
[ "$force" = "1" ] && daemon_args="$daemon_args --force"

orc_mode_banner

# --- step 1: refine ----------------------------------------------------------

step "1. refine - $(basename "$DAEMON") $daemon_args"
# shellcheck disable=SC2086
"$DAEMON" $daemon_args
rc_refine=$?

# --- step 2: harvest -----------------------------------------------------------

step "2. harvest - $(basename "$HARVEST") --draft$bundle_args"
# shellcheck disable=SC2086
"$HARVEST" --draft $bundle_args
rc_harvest=$?

# --- step 3: gap-rank ----------------------------------------------------------

step "3. gap-rank - $(basename "$GAPLOOP") --draft$gap_args"
# shellcheck disable=SC2086
"$GAPLOOP" --draft $gap_args
rc_gap=$?

# --- step 4: draft -------------------------------------------------------------

step "4. draft - $(basename "$DRAFTER")$bundle_args"
# shellcheck disable=SC2086
"$DRAFTER" $bundle_args
rc_draft=$?

# --- what now awaits a human's verified sign-off --------------------------------
#
# Reusing concept_is_verified rather than re-deciding what "verified" means:
# bin/orc-onboard.sh's own closing step counts the same way, and a third
# reading of that frontmatter disagreeing with either of the other two would be
# the worst possible bug to have.
step "5. what now awaits a human's verified sign-off"

concept_list=$(find "$RESOLVED_BUNDLE" -name '*.md' -type f 2>/dev/null | sort)
n_md=0
n_ver=0
unverified=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n_md=$(( n_md + 1 ))
  if concept_is_verified "$f"; then
    n_ver=$(( n_ver + 1 ))
  else
    unverified="$unverified  ${f#"$RESOLVED_BUNDLE"/}
"
  fi
done <<< "$concept_list"
n_unv=$(( n_md - n_ver ))

if [ "$n_md" = "0" ]; then
  say "$RESOLVED_BUNDLE holds no markdown yet; step 4 above says why."
elif [ "$n_unv" = "0" ]; then
  say "Every one of $(plural "$n_md" "concept" "concepts") in $RESOLVED_BUNDLE already carries a verified: date."
else
  say "$(plural "$n_unv" "concept" "concepts") in $RESOLVED_BUNDLE carry generated: and no verified: date, out of $(plural "$n_md" "markdown file" "markdown files") total. prompts/refine.md treats each as a lead to confirm rather than knowledge to quote, until somebody reads it and dates it:"
  gap
  printf '%s' "$unverified"
  gap
  # Named rather than called. This script composes four steps and no fifth, and
  # a review is a person's turn rather than a step in a pass: the two
  # accumulating concepts above are signed one row at a time, which this listing
  # of whole files cannot show.
  say "That listing is whole files. The rows inside the two concepts a pass keeps"
  say "adding to are signed one at a time, and this is the queue of both:"
  gap
  say "  bin/orc-verify.sh queue$bundle_args"
fi

# --- summary ----------------------------------------------------------------
#
# A step's own exit code keeps that step's own meaning - 0 is its own clean
# report, 1 is its own "something in this report is worth reading" - the same
# convention every script composed here already uses for itself. This is not a
# second judgment layered over theirs, only their own numbers laid out
# together.
gap
step "summary"
printf '  %-10s %-3s %s\n' STEP RC 'meaning, in that step'"'"'s own words'
printf '  %s\n' "-----------------------------------------------------------------"
printf '  %-10s %-3s %s\n' refine   "$rc_refine"  "$( [ "$rc_refine"  = "0" ] && printf 'clean pass' || printf 'at least one refinement failed - see above' )"
printf '  %-10s %-3s %s\n' harvest  "$rc_harvest" "$( [ "$rc_harvest" = "0" ] && printf 'nothing harvested' || printf 'answers harvested and drafted - see above' )"
printf '  %-10s %-3s %s\n' gap-rank "$rc_gap"     "$( [ "$rc_gap"     = "0" ] && printf 'nothing proposed' || printf 'terms proposed and drafted - see above' )"
printf '  %-10s %-3s %s\n' draft    "$rc_draft"   "$( [ "$rc_draft"   = "0" ] && printf 'nothing needs attention' || printf 'unread repositories, drift or a proposal - see above' )"
printf '  %s\n' "-----------------------------------------------------------------"
gap
say "Rerun this exact pass: $SELF$HINT_FLAGS"

rc=0
[ "$rc_refine" = "0" ]  || rc=1
[ "$rc_harvest" = "0" ] || rc=1
[ "$rc_gap" = "0" ]     || rc=1
[ "$rc_draft" = "0" ]   || rc=1
exit "$rc"
