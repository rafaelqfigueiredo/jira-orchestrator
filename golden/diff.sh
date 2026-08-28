#!/usr/bin/env bash
# Runs two prompt versions against the same golden set and shows what changed.
#
# Section 15: prompts are versioned code, humans merge the changes, and the
# evidence for changing them is generated automatically. This is the evidence.
# Without it you improve one class of ticket while silently regressing another
# and do not find out for weeks.
#
#   golden/diff.sh OLD.md NEW.md
#   golden/diff.sh OLD.md NEW.md --refiner claude   judge both with the real agent
#
# Both sides are named explicitly, because no earlier prompt version is kept on
# disk: git is where they live. To measure a change you are about to keep, take
# the version you are changing out of git and diff against that.
#
#   git show HEAD:prompts/refine.md > /tmp/prev-refine.md
#   golden/diff.sh /tmp/prev-refine.md prompts/refine.md --refiner claude
#
# With --refiner replay both sides read canned files, so it only demonstrates the
# harness, and only for a prompt golden/replay-map.tsv names. To learn something
# about a prompt change, use --refiner claude.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")/../bin" && pwd)/orc-lib.sh"

REFINER="${ORC_REFINER:-replay}"
A=""
B="prompts/refine.md"
positional=0

while [ $# -gt 0 ]; do
  case "$1" in
    --refiner) REFINER="$2"; shift ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    -*)        orc_die "unknown option: $1" ;;
    *)
      positional=$(( positional + 1 ))
      [ "$positional" = "1" ] && A="$1"
      [ "$positional" = "2" ] && B="$1"
      ;;
  esac
  shift
done

# Only stdout is captured, which is the JSON. Nothing is redirected, so the inner
# run's progress log and anything the refiner said reach the operator's terminal
# live - the same rule golden/run.sh already follows, and for the same reason: a
# side that takes twenty minutes and prints nothing is indistinguishable from a
# wedged one, and when a ticket comes back ERROR the log is the only thing that
# says whether it timed out, answered unparseably, or refused.
run_side() {
  "$ORC_ROOT/golden/run.sh" --prompt "$1" --refiner "$REFINER" --json
}

[ -n "$A" ] || orc_die "name the two prompts to compare: golden/diff.sh OLD.md NEW.md (see --help)"
[ -f "$A" ] || orc_die "no such prompt: $A"
[ -f "$B" ] || orc_die "no such prompt: $B"
log "A: $A"
log "B: $B"
a=$(run_side "$A") || true
b=$(run_side "$B") || true
[ -n "$a" ] && [ -n "$b" ] || orc_die "one of the runs produced nothing"

printf '\n  %-11s %-13s %-17s %-17s %s\n' KEY EXPECTED "A" "B" CHANGE
printf '  %s\n' "------------------------------------------------------------------------"

jq -rn --argjson a "$a" --argjson b "$b" '
  ($a.rows | INDEX(.key)) as $ai
  | ($b.rows | INDEX(.key)) as $bi
  | $b.rows | sort_by(.key)[]
  | .key as $k
  | $ai[$k] as $x | $bi[$k] as $y
  | [
      $k,
      $y.expected,
      "\($x.actual) (\($x.questions)q)",
      "\($y.actual) (\($y.questions)q)",
      (if ($x.pass and ($y.pass|not)) then "REGRESSED"
       elif (($x.pass|not) and $y.pass) then "fixed"
       elif ($x.actual != $y.actual) then "changed"
       else "same" end)
    ] | @tsv' \
  | awk -F'\t' '{printf "  %-11s %-13s %-17s %-17s %s\n", $1, $2, $3, $4, $5}'

printf '  %s\n' "------------------------------------------------------------------------"

jq -rn --argjson a "$a" --argjson b "$b" '
  "\n  A  \($a.summary.label): agreement \($a.summary.verdict_agreement)/\($a.summary.tickets), passing \($a.summary.passed)/\($a.summary.tickets), \($a.summary.questions_total) questions, locality \($a.summary.locality_hit)/\($a.summary.locality_expected)",
  "  B  \($b.summary.label): agreement \($b.summary.verdict_agreement)/\($b.summary.tickets), passing \($b.summary.passed)/\($b.summary.tickets), \($b.summary.questions_total) questions, locality \($b.summary.locality_hit)/\($b.summary.locality_expected)",
  ""'

# Both sides run the same code, so the second read is on both of them and this
# axis is not what a prompt diff varies. It is still worth printing: a prompt
# change that moves how often the two reads disagree has moved the first read's
# judgment on the rounds that matter most, and nothing else in this table says so.
jq -rn --argjson a "$a" --argjson b "$b" '
  if ($a.summary.misread_ran > 0) or ($b.summary.misread_ran > 0) then
    "  read a second time: A \($a.summary.misread_ran), B \($b.summary.misread_ran)   the two reads disagreed on: A \($a.summary.misread_disagreed), B \($b.summary.misread_disagreed)\n"
  else empty end'

regressions=$(jq -rn --argjson a "$a" --argjson b "$b" '
  ($a.rows | INDEX(.key)) as $ai
  | [ $b.rows[] | select(($ai[.key].pass == true) and (.pass != true)) ] | length')

if [ "$regressions" != "0" ]; then
  printf '  %s ticket(s) that passed under A fail under B. Do not merge this prompt change.\n\n' "$regressions"
  exit 1
fi
printf '  No regressions against A.\n\n'
