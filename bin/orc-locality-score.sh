#!/usr/bin/env bash
# Scores refinement's locality against tickets your team has already solved.
#
# Your git history is an answer key nobody is using: for a ticket whose work has
# merged, the files the fix touched are the diff of the commits that name it. So
# the most valuable half of a verdict - which files an implementing agent should
# open first - can be measured against real tickets, with no Jira account and
# nothing posted anywhere.
#
# The tickets are fixtures, read exactly the way fixture mode already reads them,
# because their text has to stay the same for two runs to be comparable. There is
# deliberately no live Jira path here.
#
# ORC_SOLVED_DIR chooses the set, and a real one is your own organisation's
# tickets kept outside this repository - fixtures are committed, and ticket text
# carries reporter names and whatever somebody pasted in. What ships here is an
# invented example set that runs offline and scores nothing, because none of its
# tickets names a repository this template configures. See fixtures/solved/.
#
#   bin/orc-locality-score.sh                    every ticket in the fixture set
#   ORC_SOLVED_DIR=~/orc-solved bin/...          your own set, from outside the tree
#   bin/orc-locality-score.sh RW-118 RW-152      only these
#   bin/orc-locality-score.sh --verdicts DIR     score verdicts already on disk
#   bin/orc-locality-score.sh --save DIR         keep the verdicts this run produced
#   bin/orc-locality-score.sh --json             machine-readable
#   bin/orc-locality-score.sh --timeout 0        no per-ticket limit
#
# --refiner claude is the default and the only mode that measures anything: a
# canned verdict would score whoever wrote it. --save keeps what the agent
# actually said and --verdicts scores it again later, which is how the same table
# is reproduced offline without paying for the agent calls twice. A saved verdict
# is a recording of one prompt version, not an expectation: it carries the
# prompt_version it was produced under, and the table prints it.
#
# The table is stdout. Which ticket is being refined, what its answer key came
# from and how long the call took are stderr, and none of it is discarded: these
# are sequential agent calls, and a harness that prints nothing for two minutes
# is indistinguishable from one that has hung.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

PROMPT="$ORC_ROOT/prompts/refine.md"
REFINER="${ORC_REFINER:-claude}"
FIXTURES="${ORC_SOLVED_DIR:-$ORC_ROOT/fixtures/solved}"
# Same reasoning as golden/run.sh: there is no version of measuring a prompt that
# wants a fetch, so this is pinned rather than left to `auto`.
export ORC_REPO_SYNC=off
TIMEOUT="${ORC_GOLDEN_TIMEOUT:-1320}"
verdicts_dir=""
save_dir=""
as_json=0
keys=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fixtures) FIXTURES="$2"; shift ;;
    --verdicts) verdicts_dir="$2"; shift ;;
    --save)     save_dir="$2"; shift ;;
    --prompt)   PROMPT="$2"; shift ;;
    --refiner)  REFINER="$2"; shift ;;
    --timeout)  TIMEOUT="$2"; shift ;;
    --json)     as_json=1 ;;
    -h|--help)  orc_usage "$0"; exit 0 ;;
    -*)         orc_die "unknown option: $1" ;;
    *)          keys="$keys $1" ;;
  esac
  shift
done

case "$TIMEOUT" in ''|*[!0-9]*) orc_die "--timeout must be a number of seconds (got '$TIMEOUT')" ;; esac
case "$PROMPT" in /*) : ;; *) PROMPT="$ORC_ROOT/$PROMPT" ;; esac
[ -f "$PROMPT" ] || orc_die "prompt not found: $PROMPT"
[ -d "$FIXTURES/issues" ] || orc_die "no solved-ticket fixtures at $FIXTURES/issues"

if [ -z "$keys" ]; then
  for _f in "$FIXTURES"/issues/*.json; do
    [ -e "$_f" ] || continue
    keys="$keys $(basename "$_f" .json)"
  done
  unset _f
fi
[ -n "$keys" ] || orc_die "no tickets to score in $FIXTURES/issues"

# --- the answer key ---------------------------------------------------------
#
# Every configured repository is asked what it merged for this ticket, as
# repository plus repository-relative path.
#
# Both halves are needed because a verdict spells a path either way. Given one
# repository the refiner writes `app/models/case.rb`; given three it disambiguates
# with `api/app/models/case.rb`, which is the more useful spelling and is what it
# actually did on a ticket that spanned three repositories.
# A comparison that knew only one of those forms reported 45 named files and no
# hits at all - a formatting difference presented as a locality failure, which is
# worse than no measurement, so both spellings count.
#
# Provenance travels with it. When a score is bad the first question is whether
# refinement was wrong or the checkout does not contain the work at all, and
# those have different fixes.

answer_key() {
  local key="$1" name path commits
  for name in $(project_names); do
    path=$(project_repo_path "$name")
    [ -n "$path" ] || continue
    is_git_repo "$path" || continue
    commits=$(ticket_merged_commits "$path" "$key" | grep -c . | tr -d ' ')
    [ "${commits:-0}" -gt 0 ] || continue
    ticket_merged_paths "$path" "$key" | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s\t%s\n' "$name" "$p"
    done
  done
}

answer_key_provenance() {
  local key="$1" name path commits out=""
  for name in $(project_names); do
    path=$(project_repo_path "$name")
    [ -n "$path" ] || continue
    is_git_repo "$path" || continue
    commits=$(ticket_merged_commits "$path" "$key" | grep -c . | tr -d ' ')
    [ "${commits:-0}" -gt 0 ] || continue
    out="$out${out:+, }$(repo_provenance "$name") ($commits commit(s))"
  done
  printf '%s' "$out"
}

# --- score ------------------------------------------------------------------

total=$(printf '%s' "$keys" | wc -w | tr -d ' ')
label=$(prompt_version "$PROMPT")
refiner_label="$REFINER"
[ -n "$verdicts_dir" ] && refiner_label="verdicts on disk"
if [ -n "$verdicts_dir" ]; then
  log "solved set: $total ticket(s), scoring verdicts already on disk in $verdicts_dir"
else
  log "solved set: $total ticket(s), prompt=$(basename "$PROMPT"), refiner=$REFINER, timeout=${TIMEOUT}s per ticket"
fi

# Refinement reads the solved tickets the way fixture mode reads any ticket, and
# keeps its bookkeeping in a directory that goes away with the run: scoring is a
# measurement and must leave nothing in state/ behind.
state=$(mktemp -d)
# Flat files, removed as flat files. There is exactly one recursive remove in this
# repository - in the sync script, behind its own fence, where a removal has to
# prove what it would discard - and a temporary directory is not a reason for a
# second one.
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() { rm -f "$state"/* "$state"/.[!.]* 2>/dev/null; rmdir "$state" 2>/dev/null; return 0; }
trap cleanup EXIT
export ORC_FIXTURE_DIR="$FIXTURES"
export ORC_STATE_DIR="$state"

rows='[]'
i=0
# A recording made under one prompt says nothing about another, and the label
# above the table is the *current* prompt's. Left unsaid, a --verdicts run would
# print today's version over yesterday's numbers, which is the kind of
# diagnostic that misleads rather than the kind that says nothing.
stale=""
for key in $keys; do
  i=$(( i + 1 ))
  # Before the call, not after it. A heartbeat that arrives once the slow thing
  # has finished is not a heartbeat.
  log "[$i/$total] $key: refining"
  started=$(orc_epoch)
  if [ -n "$verdicts_dir" ]; then
    if [ -f "$verdicts_dir/$key.json" ]; then
      actual=$(cat "$verdicts_dir/$key.json")
    else
      actual=""
      log "[$i/$total] $key: no verdict at $verdicts_dir/$key.json"
    fi
    rc=0
  else
    actual=$(run_with_timeout "$TIMEOUT" \
      "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force \
      --prompt "$PROMPT" --refiner "$REFINER" "$key")
    rc=$?
  fi
  elapsed=$(( $(orc_epoch) - started ))

  if [ "$rc" = "124" ]; then
    log "[$i/$total] $key: TIMEOUT after ${elapsed}s (limit ${TIMEOUT}s). Raise --timeout, or 0 for no limit."
    actual='{"verdict":"TIMEOUT"}'
  elif [ -z "$actual" ] || ! printf '%s' "$actual" | jq -e . >/dev/null 2>&1; then
    log "[$i/$total] $key: no usable verdict after ${elapsed}s (exited $rc); its output is above"
    actual='{"verdict":"ERROR"}'
  else
    log "[$i/$total] $key: $(printf '%s' "$actual" | jq -r '.verdict // "?"') in ${elapsed}s, \
locality_basis=$(printf '%s' "$actual" | jq -r '.locality_basis // "-"'), \
$(printf '%s' "$actual" | jq -r '(.files // []) | length') file(s) named, \
$(printf '%s' "$actual" | jq -r '(.terms_unresolved // []) | length') term(s) unresolved"
  fi

  if [ -n "$verdicts_dir" ]; then
    recorded=$(printf '%s' "$actual" | jq -r '.prompt_version // ""')
    if [ -n "$recorded" ] && [ "$recorded" != "$label" ]; then
      stale="$stale$key recorded under $recorded
"
      log "[$i/$total] $key: recorded under $recorded, not the current $label"
    fi
  fi

  # A failed call is a row in the table and never a recording: saving TIMEOUT or
  # ERROR would let a later --verdicts run reproduce a number that measured
  # nothing.
  if [ -n "$save_dir" ] && printf '%s' "$actual" | jq -e '.verdict | . == "ready" or . == "needs_input" or . == "duplicate"' >/dev/null 2>&1; then
    mkdir -p "$save_dir"
    printf '%s' "$actual" | jq . > "$save_dir/$key.json"
    log "[$i/$total] $key: verdict saved to $save_dir/$key.json"
  fi

  pairs=$(answer_key "$key" | sort -u \
    | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0) | split("\t"))
               | map({repo: .[0], path: .[1]})')
  provenance=$(answer_key_provenance "$key")
  if [ "$(printf '%s' "$pairs" | jq 'length')" != "0" ]; then
    log "[$i/$total] $key: answer key is $(printf '%s' "$pairs" | jq 'map(.path) | unique | length') path(s) from $provenance"
  else
    log "[$i/$total] $key: no answer key - no commit reachable from any configured clone's branch names this ticket, so it is reported and left out of the totals"
  fi

  row=$(jq -nc --argjson a "$actual" --arg key "$key" --arg prov "$provenance" \
    --argjson pairs "$pairs" '
    ($a.files // []) as $named
    | ($pairs | map(.path) + map(.repo + "/" + .path) | unique) as $keyset
    | ($pairs | map(.path) | unique) as $files_touched
    | ($pairs | map(. as $e
        | select(($named | index($e.path)) != null
                 or ($named | index($e.repo + "/" + $e.path)) != null)
        | $e.path) | unique) as $found
    | {
        key: $key,
        verdict: ($a.verdict // "ERROR"),
        locality_basis: ($a.locality_basis // "-"),
        prompt_version: ($a.prompt_version // null),
        terms_unresolved: (($a.terms_unresolved // []) | length),
        provenance: $prov,
        has_key: (($files_touched | length) > 0),
        touched: ($files_touched | length),
        named: ($named | length),
        hit: ([$named[] | select(. as $x | ($keyset | index($x)) != null)] | length),
        found: ($found | length)
      }
    | . + {extra: (.named - .hit), missed: (.touched - .found)}')
  rows=$(jq -c --argjson r "$row" '. + [$r]' <<< "$rows")
done

summary=$(jq -c --arg label "$label" --arg refiner "$refiner_label" \
  --arg prompt "${PROMPT#"$ORC_ROOT"/}" '
  ([.[] | select(.has_key)]) as $scored | {
    label: $label, prompt: $prompt,
    refiner: $refiner,
    tickets: length,
    scored: ($scored | length),
    unscorable: ([.[] | select(.has_key | not) | .key]),
    named: ([$scored[] | .named] | add // 0),
    hit: ([$scored[] | .hit] | add // 0),
    found: ([$scored[] | .found] | add // 0),
    extra: ([$scored[] | .extra] | add // 0),
    touched: ([$scored[] | .touched] | add // 0),
    missed: ([$scored[] | .missed] | add // 0),
    terms_unresolved: ([.[] | .terms_unresolved] | add // 0)
  }' <<< "$rows")

if [ "$as_json" = "1" ]; then
  jq -nc --argjson r "$rows" --argjson s "$summary" '{summary:$s, rows:$r}'
  exit 0
fi

pct() { jq -nr --argjson n "$1" --argjson d "$2" 'if $d == 0 then "-" else "\(($n * 100 / $d) | round)%" end'; }

printf '\n  locality against solved tickets: %s  (prompt=%s, refiner=%s)\n\n' \
  "$label" "$(jq -r '.prompt' <<< "$summary")" "$refiner_label"
printf '  %-11s %-12s %-8s %-8s %-6s %-5s %-6s %s\n' KEY VERDICT BASIS TOUCHED NAMED HIT EXTRA MISSED
printf '  %s\n' "-------------------------------------------------------------------------------"
jq -r '.[] | if .has_key
  then "\(.key)\t\(.verdict)\t\(.locality_basis)\t\(.touched)\t\(.named)\t\(.hit)\t\(.extra)\t\(.missed)"
  else "\(.key)\t\(.verdict)\t\(.locality_basis)\tno key\t\(.named)\t-\t-\t-" end' <<< "$rows" \
  | awk -F'\t' '{printf "  %-11s %-12s %-8s %-8s %-6s %-5s %-6s %s\n", $1, $2, $3, $4, $5, $6, $7, $8}'
printf '  %s\n' "-------------------------------------------------------------------------------"

jq -r '"\n  \(.scored) of \(.tickets) ticket(s) scored: \(.named) file(s) named, \(.hit) of them in the merged diff, \(.missed) touched file(s) not named.  terms unresolved: \(.terms_unresolved)"' <<< "$summary"
printf '  precision %s of named files, recall %s of touched files.\n' \
  "$(pct "$(jq -r .hit <<< "$summary")" "$(jq -r .named <<< "$summary")")" \
  "$(pct "$(jq -r .found <<< "$summary")" "$(jq -r .touched <<< "$summary")")"

unscorable=$(jq -r '.unscorable | join(", ")' <<< "$summary")
[ -n "$unscorable" ] && printf '  no answer key, left out of both figures: %s\n' "$unscorable"
if [ -n "$stale" ]; then
  printf '\n  These numbers were NOT produced by %s. Re-record before reading them\n' "$label"
  printf '  as a measurement of the current prompt:\n'
  printf '%s' "$stale" | sed 's/^/    /'
fi

# Said where the numbers are, rather than in a README nobody opens next to them.
cat <<'NOTE'

  Read these as a proxy and not as a grade. A merged diff is what happened
  rather than what should have happened: it carries files the change touched
  incidentally, and it misses a file the fix should have touched and did not.

  Both figures distort in the same direction on a large ticket. When an epic
  merged as a dozen commits across three repositories, the diff lists everything
  it moved rather than where to start: recall against that is structurally small
  and says little about the verdict, while precision is flattered, because almost
  any file a search turns up in that area was touched by something.

  The figure worth watching is which way each moves when the bundle changes,
  against the same tickets and the same answer key.

NOTE

# Every row printed. Nothing is a pass or a fail here: this measures, and a
# harness that decided a threshold by itself would be inventing the bar.
exit 0
