#!/usr/bin/env bash
# Runs every ticket in the golden set through refinement and reports how far the
# verdicts are from the ones a human wrote down.
#
# Section 11: refinement agreement is the only metric that matters in phase 1.
# Section 15: the golden set comes first, and every prompt change runs against
# it like a test suite.
#
#   golden/run.sh                          replay the canned verdicts, offline
#   golden/run.sh --refiner claude         call the real agent (needs network)
#   golden/run.sh --prompt /tmp/prev-refine.md  --refiner claude
#   golden/run.sh --json                   machine-readable, for golden/diff.sh
#   golden/run.sh --timeout 0              no per-ticket limit
#
# Two columns say n/a or stand on their own rather than being averaged in.
#
# LOCALITY is scored only under --refiner replay. The expectations name paths in
# an invented dashboard product and the configured repositories are the real
# ones, so no refiner reading actual code can name those files: the canned
# verdict scores 2/2 because it was written to, and a real agent scores 0/2
# because the paths do not exist. Neither number is about locality. The
# expectations stay - they are a real check on the replay harness - and off
# replay the column says n/a instead of reporting a proxy for nothing.
#
# A TIMEOUT is counted in its own column and left out of the agreement figure.
# A killed call is not a wrong answer, and scoring it as one means the next
# prompt change that adds a step of reasoning reads as a prompt regression.
#
# Nothing here writes to Jira or to state/: it runs refinement in --judge-only
# mode, which is the same code path the daemon uses to reach a verdict and none
# of the code path that acts on one.
#
# The table is stdout. Everything else - the ticket being started, how long the
# last one took, and every word refinement or the agent wrote - is stderr, and
# none of it is discarded.
#
# It used to end the refinement call in 2>/dev/null, which is why a real run
# looked frozen: five sequential agent calls at tens of seconds each, printing
# nothing, with any error, question or prompt from the agent thrown away. A slow
# run and a wedged run have to look different, so this one says what it is doing
# as it does it and gives every ticket a deadline.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")/../bin" && pwd)/orc-lib.sh"

PROMPT="$ORC_ROOT/prompts/refine.md"
REFINER="${ORC_REFINER:-replay}"

# The harness replays canned verdicts against fixture tickets, so it has no
# reason to touch a remote and is pinned rather than left to `auto`. Unpinned, a
# checkout of this repository whose config names real repositories would make a
# metrics run clone them - network the harness never asked for, minutes added to
# something people run after every prompt edit, and a fetch failure showing up as
# a verdict that disagrees. Pinned, not defaulted: there is no version of
# measuring prompt agreement that wants a fetch.
export ORC_REPO_SYNC=off
# The fixture fleet, materialised into state/ for the run.
#
# Until this existed the harness ran against config/projects.yml, which ships
# with no product repository at all, so every golden ticket was judged under "No
# repository is available to search". That is not the daemon's situation, and it
# makes a whole class of finding unmeasurable: an integration gap is read out of
# the code, in the places that assume a set is complete, and a refiner with no
# code reads none of them.
#
# In state/ rather than a scratch directory with a cleanup trap, because state/ is
# already a cache with a command that clears it, and the rule that a recursive
# remove lives in exactly one place in this repository is worth more than a tidy
# temporary directory. fixtures/repos.sh has the rest of that reasoning.
#
# Overridable, and that is deliberate rather than an oversight: measuring what
# this fleet does to the set means running the same prompt with and without it,
# and ORC_PROJECTS_FILE=config/projects.yml is that run. Absent - a sandbox with
# no fixtures/ in it - the harness runs exactly as it used to.
if [ -z "${ORC_PROJECTS_FILE:-}" ] && [ -x "$ORC_ROOT/fixtures/repos.sh" ]; then
  ORC_PROJECTS_FILE=$("$ORC_ROOT/fixtures/repos.sh" "$STATE_DIR/golden-repos") \
    || orc_die "could not materialise the fixture repositories"
  export ORC_PROJECTS_FILE
fi
# Said out loud, because a measurement run whose instrument changed silently is a
# measurement nobody can compare with the last one.
log "repositories: ${ORC_PROJECTS_FILE:-$ORC_ROOT/config/projects.yml}"

as_json=0
label=""
# Deliberately longer than orc-refine.sh's own ORC_AGENT_TIMEOUT, so the inner
# limit fires first and names the agent. This one is the backstop for everything
# else in a refinement that can block, and it is per ticket, so one wedged ticket
# costs one ticket. A fetch is not among those things any more: see ORC_REPO_SYNC
# above.
#
# The inner limit is per agent call and one refinement makes up to two of them -
# the first read and the adversarial re-read on a round about to become terminal
# - so this has to outlast both. Level with one call, it would fire during the
# second and report a wedged refinement where the agent was merely thinking
# twice, which is the misleading-diagnostic rule in the place it was first
# written for. bin/orc-check.sh compares the two against orc-refine.sh's own
# count of how many calls it can make.
TIMEOUT="${ORC_GOLDEN_TIMEOUT:-1320}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)  PROMPT="$2"; shift ;;
    --refiner) REFINER="$2"; shift ;;
    --label)   label="$2"; shift ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --json)    as_json=1 ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    *)         orc_die "unknown option: $1" ;;
  esac
  shift
done

case "$TIMEOUT" in ''|*[!0-9]*) orc_die "--timeout must be a number of seconds (got '$TIMEOUT')" ;; esac

case "$PROMPT" in /*) : ;; *) PROMPT="$ORC_ROOT/$PROMPT" ;; esac
[ -f "$PROMPT" ] || orc_die "prompt not found: $PROMPT"
[ -n "$label" ] || label=$(prompt_version "$PROMPT")

EXPECTED="$ORC_ROOT/golden/expected"
ls "$EXPECTED"/*.json >/dev/null 2>&1 || orc_die "no expectations in $EXPECTED"

total=$(find "$EXPECTED" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')
log "golden set: $total ticket(s), prompt=$(basename "$PROMPT"), refiner=$REFINER, timeout=${TIMEOUT}s per ticket"

rows='[]'
i=0
for exp_file in "$EXPECTED"/*.json; do
  key=$(jq -r '.key' "$exp_file")
  expected=$(cat "$exp_file")

  i=$(( i + 1 ))
  # Printed before the call, not after it. A heartbeat that arrives once the slow
  # thing has finished is not a heartbeat.
  log "[$i/$total] $key: refining"
  started=$(orc_epoch)
  # No 2>/dev/null. Whatever refinement or the agent has to say goes straight to
  # the operator's terminal, which is the entire point.
  actual=$(run_with_timeout "$TIMEOUT" \
    "$ORC_ROOT/bin/orc-refine.sh" --judge-only --prompt "$PROMPT" --refiner "$REFINER" "$key")
  rc=$?
  elapsed=$(( $(orc_epoch) - started ))

  if [ "$rc" = "124" ]; then
    log "[$i/$total] $key: TIMEOUT after ${elapsed}s (limit ${TIMEOUT}s); killed and recorded as TIMEOUT. Raise --timeout, or 0 for no limit."
    actual='{"verdict":"TIMEOUT"}'
  elif [ -z "$actual" ] || ! printf '%s' "$actual" | jq -e . >/dev/null 2>&1; then
    log "[$i/$total] $key: no usable verdict after ${elapsed}s (refinement exited $rc); its output is above"
    actual='{"verdict":"ERROR"}'
  else
    log "[$i/$total] $key: $(printf '%s' "$actual" | jq -r '.verdict // "?"') in ${elapsed}s"
  fi

  row=$(jq -nc --argjson e "$expected" --argjson a "$actual" '
    # What the round asks: the questions the first read wrote, plus the ones the
    # second read found. Both, because on a card the first read called ready its
    # own list is empty by construction while the comment still carries
    # questions - a row reporting none there would say a needs_input verdict
    # asked nothing, and an unbounded second read would go unnoticed. The two
    # harness-promoted questions are still not counted: those are the harness
    # asking, and this column has always been the budget the refiner is held to.
    ((($a.questions // []) | length) + (($a.misread.findings // []) | length)) as $q
    | ($a.files // []) as $f
    | ($e.expect_files // []) as $ef
    | ($e.expect_split // false) as $es
    | {
        key: $e.key,
        expected: $e.verdict,
        actual: ($a.verdict // "ERROR"),
        verdict_match: (($a.verdict // "") == $e.verdict),
        # A refinement now reaches a verdict twice on a round about to become
        # terminal, and the two can disagree. Both are reported: the acted one
        # is what this row is scored on, and the first read is what the same
        # prompt would have produced with no second read at all - which makes
        # every run its own A/B on that pass, with no cross-run variance in it.
        first_read: ($a.verdict_first_read // ($a.verdict // "ERROR")),
        misread_ran: ($a.misread.ran // false),
        misread_found: (($a.misread.findings // []) | length),
        misread_disagreed: ($a.misread.disagreed // false),
        questions: $q,
        max_questions: $e.max_questions,
        questions_ok: ($q <= $e.max_questions),
        expect_files: ($ef | length),
        files_named: ($f | length),
        files_hit: ([$ef[] | select(. as $x | ($f | index($x)) != null)] | length),
        timed_out: (($a.verdict // "") == "TIMEOUT"),
        duplicate_expected: $e.duplicate_of,
        duplicate_actual: ($a.duplicate_of // null),
        duplicate_ok: (if $e.duplicate_of == null then true else ($a.duplicate_of == $e.duplicate_of) end),
        split_expected: $es,
        split_ok: (if $es then ((($a.split_into // []) | length) >= 3) else true end)
      }
    | . + {pass: (.verdict_match and .questions_ok and .duplicate_ok and .split_ok)}')
  rows=$(jq -c --argjson r "$row" '. + [$r]' <<< "$rows")
done

# A timed-out ticket is named and left out of both figures rather than averaged
# in at zero, the same way bin/orc-locality-score.sh treats a ticket with no
# answer key. `answered` is the denominator that goes with them.
summary=$(jq -c --arg label "$label" --arg refiner "$REFINER" --arg prompt "${PROMPT#"$ORC_ROOT"/}" '{
  label: $label, prompt: $prompt, refiner: $refiner,
  tickets: length,
  timeouts: ([.[] | select(.timed_out)] | length),
  answered: ([.[] | select(.timed_out | not)] | length),
  verdict_agreement: ([.[] | select((.timed_out | not) and .verdict_match)] | length),
  passed: ([.[] | select((.timed_out | not) and .pass)] | length),
  questions_total: ([.[] | .questions] | add // 0),
  misread_ran: ([.[] | select(.misread_ran)] | length),
  misread_disagreed: ([.[] | select(.misread_disagreed)] | length),
  locality_scored: ($refiner == "replay"),
  locality_expected: ([.[] | .expect_files] | add // 0),
  locality_hit: ([.[] | .files_hit] | add // 0)
}' <<< "$rows")

if [ "$as_json" = "1" ]; then
  jq -nc --argjson r "$rows" --argjson s "$summary" '{summary:$s, rows:$r}'
else
  printf '\n  golden set: %s  (prompt=%s, refiner=%s)\n\n' \
    "$label" "$(jq -r '.prompt' <<< "$summary")" "$REFINER"
  printf '  %-11s %-12s %-12s %-5s %-9s %-11s %s\n' KEY EXPECTED ACTUAL Q/MAX LOCALITY DUPLICATE RESULT
  printf '  %s\n' "-------------------------------------------------------------------------------"
  jq -r --argjson s "$summary" '.[] |
    "\(.key)\t\(.expected)\t\(.actual)\t\(.questions)/\(.max_questions)\t\(if $s.locality_scored then "\(.files_hit)/\(.expect_files)" else "n/a" end)\t\(.duplicate_actual // "-")\t\(if .pass then "ok" elif .timed_out then "TIMEOUT" else "MISMATCH" end)"' <<< "$rows" \
    | awk -F'\t' '{printf "  %-11s %-12s %-12s %-5s %-9s %-11s %s\n", $1, $2, $3, $4, $5, $6, $7}'
  printf '  %s\n' "-------------------------------------------------------------------------------"
  jq -r '"\n  verdict agreement: \(.verdict_agreement)/\(.answered)   fully passing: \(.passed)/\(.answered)   questions asked: \(.questions_total)   timed out: \(.timeouts)"
    + (if .locality_scored then "   locality: \(.locality_hit)/\(.locality_expected)" else "" end) + "\n"' <<< "$summary"

  # Said once, under the table, rather than as a ninth column. The second read
  # costs an agent call on every round about to become terminal, and how often it
  # then finds nothing is the figure that argues for or against keeping it - so
  # the line prints whenever the pass ran at all, including when it agreed every
  # time, because that is the result worth recording.
  jq -r 'if .misread_ran > 0 then
      "  read a second time: \(.misread_ran) of \(.answered)   the two reads disagreed on: \(.misread_disagreed)\n"
    else empty end' <<< "$summary"
  jq -r '.[] | select(.misread_disagreed) |
    "  \(.key): the first read said \(.first_read) and the second found \(.misread_found) reading(s) that would build something else; acted on as \(.actual)"' <<< "$rows"

  jq -r '.[] | select(.pass | not) |
    if .timed_out then
      "  \(.key): killed by the per-ticket limit before it answered; it is counted as a timeout, not as a disagreement"
    else
      "  \(.key): expected \(.expected) with at most \(.max_questions) question(s), got \(.actual) with \(.questions)"
    end' <<< "$rows"
fi

failed=$(jq -r '[.[] | select(.pass | not)] | length' <<< "$rows")
[ "$failed" = "0" ]
