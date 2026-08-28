#!/usr/bin/env bash
# Turns what refinement could not resolve into candidate knowledge.
#
# Every verdict already records `terms_unresolved`: the ticket's own words that
# the bundle could not answer. Across the four tickets of the example set under
# fixtures/solved/ that list holds 23 words, including some of the most central
# ones in that domain, and nothing read it. This is what reads it.
#
#   orc-gap-loop.sh                      rank, report, propose; write no concept
#   orc-gap-loop.sh --draft              also draft the proposal into the bundle
#   orc-gap-loop.sh --basis LIST         which localisations count (default
#                                        search,none; `any` for all four)
#   orc-gap-loop.sh --min-tickets N      raise the recurrence bar
#   orc-gap-loop.sh --terms              the proposed terms, one per line
#   orc-gap-loop.sh --no-record          rank without appending to the ledger
#   orc-gap-loop.sh --bundle DIR         read and draft into DIR instead of .okf
#   orc-gap-loop.sh --ledger FILE        append the record to FILE instead of
#                                        data/gaps.jsonl
#
# ## What it ranks
#
# The interesting runs are the ones where `locality_basis` was `search` or
# `none`: those are the tickets refinement could not route through the bundle,
# which is exactly where a missing concept costs something. A run that localised
# through the bundle still leaves a gap, and `--basis` will count it, but it is
# not the default because the two are different findings.
#
# The count is by *ticket*, not by occurrence. A word said five times in one
# ticket is one ticket's word.
#
# ## The bar, and why it is set where it is
#
# A term appearing often is not the same as a term worth a concept. The bundle's
# scope rule is explicit that forty vague concepts are worse than twelve sharp
# ones, because refinement believes all forty - so a loop that drafted a concept
# for every frequent word would degrade the bundle while looking productive.
#
# Five things exclude a term, and each is named in the table rather than dropped
# silently:
#
#   one ticket only  a word one ticket said is that ticket's word. Two tickets is
#                    the same corroboration rule the bundle already applies to a
#                    phrase only one repository says.
#   code-shaped      a path, a snake_case identifier, a Ruby namespace. That is
#                    something the refiner arrived at rather than something a
#                    reporter wrote, and it is already an answer to a question
#                    nobody asked.
#   too long or too short   at most three words, because a name is at most three
#                    words and the fourth makes it a sentence; at least four
#                    characters, because a shorter string matches everything.
#   decided already  a person has agreed to this word or refused it, in
#                    bin/orc-verify.sh. Either way it is not a candidate any
#                    more, and this is checked before the four below because a
#                    human's decision outranks every mechanical reason.
#   already in the bundle   a concept already says this word. Then refinement's
#                    failure was a reading failure rather than a missing-knowledge
#                    one, and drafting an entry for it would be a second answer to
#                    the same question - the one thing this bundle may not
#                    contain. The comparison is on folded text, so
#                    `waiting_for_images` in a concept answers "waiting for
#                    images" in a ticket.
#
# `--min-tickets` raises that bar and cannot lower it. A bar an operator can set
# to one is not a bar.
#
# ## What it drafts, and what it never does
#
# One concept: the product's words refinement met and the bundle could not
# explain, each with what the repositories do and do not say about it. One
# concept rather than one per term, for the scope reason above.
#
# Most rows are questions rather than answers, and that is the honest outcome
# rather than a weakness: if the evidence resolved a term, the drafter would
# already have put it in the bundle. Evidence still decides which is which, and a
# term the repositories cannot establish is said to be unestablished rather than
# resolved - exactly as the drafter already treats a term it cannot prove is
# live.
#
# The drafting is not done here. bin/orc-okf-draft.sh does it, through the
# same publish() that writes every other drafted concept, which is why the
# guarantees come for free rather than being restated: `generated:` and no
# `verified:`, a concept a human verified reported and left exactly as it was
# found with no flag that overrules that, a second run that is a no-op, and an
# index that lists what exists. Two things that draft concepts would disagree
# eventually, and then nobody could tell which produced what.
#
# So this proposes and a person consents, the same rule config/projects.yml and a
# Jira write get: with no `--draft` it reports what would be drafted and writes
# nothing into the bundle.
#
# ## The record, and what a reset does to it
#
# `terms_unresolved` lives in state/ and nowhere else, and state/ is a cache.
# bin/orc-reconcile.sh rebuilds everything else in there out of the comments on
# the tickets and cannot rebuild this, because a refinement comment deliberately
# carries no term list. So the gap is re-derivable only by refining the ticket
# again, under whatever prompt is current rather than the one that produced the
# observation. That is not history.
#
# Both halves of the answer therefore apply. This loop keeps its own durable
# record - data/gaps.jsonl, one append-only line per ticket and prompt version,
# outside the two directories a reset clears - and that record still holds only
# what somebody ran the loop to capture, so it has to run before the cache is
# cleared. bin/orc-reset.sh counts what state/ holds that the ledger does not and
# says so before it removes anything.
#
# Exit codes: 0 nothing is proposed, 1 something is.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd awk sort

# Resolved from dirname $0 rather than from ORC_ROOT, which is overridable: a run
# that pointed it elsewhere would compose two scripts that are not these ones.
DRAFTER="$(cd "$(dirname "$0")" && pwd)/orc-okf-draft.sh"
BUNDLE="$BUNDLE_DIR"
GAP_CONCEPT="$ORC_ACCUMULATING_VOCAB"
TAB=$(printf '\t')

MIN_TICKETS=2
MAX_WORDS=3
MIN_CHARS=4
BASIS="search,none"

draft=0
record=1
as_terms=0

# Spelled out rather than assembled from $0: bin/orc-check.sh reads the script
# names this repository speaks out of the source, and a name built at run time is
# invisible to it.
SELF="bin/orc-gap-loop.sh"

# Every command this script prints is a command somebody pastes, so it carries
# the flags the run that printed it was given. Without them the hint under a
# `--basis any` report described a different run: four terms cleared the bar, and
# the command it printed reran under the default basis and drafted nothing.
#
# In the spelling they were given rather than the one they resolved to - `--basis
# any` rather than the four names it expands to - because what an operator
# recognises is their own words.
#
# HINT_FLAGS and hint_flag are in orc-lib.sh, because the rule holds for every
# script that prints its own name. The mode and the basis are kept apart from the
# rest here because two hints replace them: a hint chooses the mode itself, and
# the line saying what the filter left out has to offer `--basis any` while
# keeping every other flag the run was given.
HINT_MODE=""
HINT_BASIS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --draft)       draft=1; HINT_MODE=" --draft" ;;
    --basis)       shift; [ $# -gt 0 ] || orc_die "--basis needs a list"; BASIS="$1"
                   HINT_BASIS=" --basis $(hint_word "$1")" ;;
    --min-tickets) shift; [ $# -gt 0 ] || orc_die "--min-tickets needs a number"; MIN_TICKETS="$1"
                   hint_flag --min-tickets "$1" ;;
    --bundle)      shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1"
                   hint_flag --bundle "$1" ;;
    --ledger)      shift; [ $# -gt 0 ] || orc_die "--ledger needs a file"; GAP_LEDGER="$1"
                   hint_flag --ledger "$1" ;;
    --no-record)   record=0; hint_flag --no-record ;;
    # No hint state: this half prints the terms and nothing else, so it prints no
    # hint at all. The report offers the command that reproduces it instead.
    --terms)       as_terms=1 ;;
    -h|--help)     orc_usage "$0"; exit 0 ;;
    -*)            orc_die "unknown option: $1" ;;
    *)             orc_die "unexpected argument: $1" ;;
  esac
  shift
done

case "$MIN_TICKETS" in ''|*[!0-9]*) orc_die "--min-tickets must be a number (got '$MIN_TICKETS')" ;; esac
# Upward only. The point of the bar is that a frequent word is not automatically
# a concept, and a bar set to one deletes the point rather than relaxing it.
[ "$MIN_TICKETS" -ge 2 ] || orc_die "--min-tickets may be raised and not lowered: two tickets is the corroboration rule the bundle already uses, and one would propose a concept for a word one ticket said"

case "$BASIS" in any|all) BASIS="bundle,search,both,none" ;; esac

WORK=$(mktemp -d) || orc_die "could not create a working directory"
# shellcheck disable=SC2329  # the EXIT trap below is the caller
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

# --- the record -------------------------------------------------------------

n_recorded=0
if [ "$record" = "1" ]; then
  # Fed from a here-string rather than a pipe, so the counter survives the loop
  # and the last line of the list is not silently skipped.
  while IFS="$TAB" read -r _key _pv _file; do
    [ -n "$_file" ] || continue
    mkdir -p "$(dirname "$GAP_LEDGER")" || orc_die "could not create $(dirname "$GAP_LEDGER")"
    gap_observation "$_file" >> "$GAP_LEDGER" || orc_die "could not append to $GAP_LEDGER"
    n_recorded=$(( n_recorded + 1 ))
  done <<< "$(gap_unrecorded)"
  unset _key _pv _file
fi

# Every observation there is: the ledger, with what state/ currently holds laid
# over it. State wins on a collision, because a ticket refined again under the
# same prompt has one current gap rather than two.
state_json=$(gap_state_verdicts | while IFS="$TAB" read -r _k _p _f; do
  [ -n "$_f" ] || continue
  gap_observation "$_f"
done | jq -sc '.')
if [ -f "$GAP_LEDGER" ]; then
  ledger_json=$(jq -sRc '[splits("\n") | select(length > 0) | fromjson? | select(type == "object")]' "$GAP_LEDGER")
else
  ledger_json='[]'
fi
obs=$(jq -nc --argjson l "$ledger_json" --argjson s "$state_json" '
  ($l + $s)
  | map(select((.key // "") != ""))
  | reduce .[] as $o ({}; .[$o.key + "" + ($o.prompt_version // "")] = $o)
  | [ .[] ]')

n_obs=$(jq 'length' <<< "$obs")
basis_json=$(printf '%s' "$BASIS" | tr ',' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))')
kept=$(jq -c --argjson b "$basis_json" '[ .[] | select((.locality_basis // "none") as $x | $b | index($x)) ]' <<< "$obs")
n_kept=$(jq 'length' <<< "$kept")

# --- ranking ----------------------------------------------------------------

jq -r '.[] | . as $o | (.terms_unresolved // [])[] | [$o.key, .] | @tsv' <<< "$kept" > "$WORK/raw"

: > "$WORK/folded"
while IFS="$TAB" read -r _tkey _term; do
  [ -n "$_term" ] || continue
  _f=$(printf '%s' "$_term" | _terms_fold)
  [ -n "$_f" ] || continue
  printf '%s\t%s\t%s\n' "$_f" "$_term" "$_tkey" >> "$WORK/folded"
done < "$WORK/raw"
unset _tkey _term _f

# folded<TAB>display<TAB>tickets<TAB>occurrences<TAB>ticket keys
#
# The display spelling is the one the most tickets used, and the first of those
# alphabetically when they tie: "Gender" and "gender" are one word, and the table
# has to print one of them without the choice moving between runs.
awk -F'\t' '
  {
    f = $1; disp = $2; k = $3
    occ[f]++
    if (!((f SUBSEP k) in seen)) {
      seen[f SUBSEP k] = 1
      tickets[f]++
      keys[f] = keys[f] (keys[f] == "" ? "" : " ") k
    }
    n = ++spell[f SUBSEP disp]
    if (n > bestn[f] || (n == bestn[f] && disp < best[f])) { bestn[f] = n; best[f] = disp }
  }
  END { for (f in occ) printf "%s\t%s\t%d\t%d\t%s\n", f, best[f], tickets[f], occ[f], keys[f] }
' "$WORK/folded" | sort -t"$TAB" -k3,3nr -k4,4nr -k1,1 > "$WORK/ranked"

# --- the bar ----------------------------------------------------------------
#
# The bundle as one folded string, minus the concept this loop owns. Including it
# would make every term it drafted read as already answered on the next run, and
# the concept would then be re-drafted empty out of its own output.
# A function rather than a `case` inside the substitution below: bash 3.2 reads
# the closing paren of a case pattern inside $( ) as the end of the substitution,
# and macOS ships 3.2.
bundle_concepts() {
  local f rel
  find "$BUNDLE" -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$BUNDLE"/}
    [ "$rel" != "$GAP_CONCEPT" ] || continue
    case "$rel" in index.md|*/index.md) continue ;; esac
    cat "$f"
  done
}
bundle_text=$(bundle_concepts | _terms_fold)

: > "$WORK/judged"
: > "$WORK/proposed"
while IFS="$TAB" read -r folded display tickets occ keys; do
  [ -n "$folded" ] || continue
  words=$(printf '%s' "$folded" | awk '{ print NF }')
  # A decision a person made comes first, ahead of every mechanical reason. Both
  # outcomes exclude the word and each says which it was: agreed, the meaning is
  # in a file this system never drafts and a row here would be a second answer;
  # refused, a word proposed again on every run is how a review queue becomes
  # something nobody opens.
  #
  # Keyed on the word alone rather than on the sentence the evidence currently
  # produces for it, because refusing a word is a judgement about the word - a
  # re-drafted sentence must not bring it back.
  decided=$(decision_for word "$folded" "")
  if [ -n "$decided" ]; then
    case "$decided" in
      agree) outcome="agreed on review; it is knowledge now, not a candidate" ;;
      *)     outcome="refused on review" ;;
    esac
  elif [ "$tickets" -lt "$MIN_TICKETS" ]; then
    outcome="$(plural "$tickets" ticket tickets) only"
  elif printf '%s' "$display" | grep -qE "$ORC_CODE_SHAPED_TERM"; then
    outcome="code-shaped, not a reporter's word"
  elif [ "$words" -gt "$MAX_WORDS" ]; then
    outcome="$words words, a sentence rather than a name"
  elif [ "${#folded}" -lt "$MIN_CHARS" ]; then
    outcome="too short to search for"
  elif orc_folded_says "$bundle_text" "$folded"; then
    outcome="the bundle already says it"
  else
    outcome="proposed"
    printf '%s\t%s\t%s\t%s\n' "$display" "$folded" "$tickets" "$occ" >> "$WORK/proposed"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$display" "$tickets" "$occ" "$outcome" "$folded" "$keys" >> "$WORK/judged"
done < "$WORK/ranked"

n_terms=$(grep -c . "$WORK/ranked" | tr -d ' ')
n_proposed=$(grep -c . "$WORK/proposed" | tr -d ' ')

# The machine-readable half, for a caller that wants the terms and not a table
# whose columns are padded to the longest value in them.
if [ "$as_terms" = "1" ]; then
  awk -F'\t' '{ print $1 }' "$WORK/proposed"
  [ "$n_proposed" = "0" ] && exit 0
  exit 1
fi

# --- report -----------------------------------------------------------------

printf '\n  gap-driven candidates: %s from %s of %s recorded run(s)  (basis=%s)\n\n' \
  "$(plural "$n_terms" "term" "terms")" "$n_kept" "$n_obs" "$BASIS"

if [ "$n_terms" = "0" ]; then
  say "No run in the record localised through $BASIS and left a term unresolved."
  say "Nothing is proposed, and nothing is wrong: an empty gap list is what a bundle that answers its tickets looks like."
else
  printf '  %-32s %-8s %-6s %s\n' TERM TICKETS RUNS OUTCOME
  printf '  %s\n' "---------------------------------------------------------------------------"
  awk -F'\t' '{ printf "  %-32s %-8s %-6s %s\n", $1, $2, $3, $4 }' "$WORK/judged"
  printf '  %s\n' "---------------------------------------------------------------------------"
fi

# What the basis filter cost, said out loud rather than left for somebody to
# work out from a smaller number. The four recordings this was built against all
# localised through `both`, so a default that silently dropped them would have
# read as "no gaps" on the only data there was.
excluded=$(jq -r --argjson b "$basis_json" '
  [ .[] | select(((.locality_basis // "none") as $x | $b | index($x)) | not) ]
  | group_by(.locality_basis // "none")
  | map("\(.[0].locality_basis // "none"): \(length)") | join(", ")' <<< "$obs")
if [ -n "$excluded" ]; then
  gap
  say "Left out by --basis $BASIS: $excluded. Those runs did localise through the bundle, so a term they left unresolved is a weaker finding rather than none. This counts them:"
  say "  $SELF$HINT_MODE --basis any$HINT_FLAGS"
fi

if [ "$n_recorded" != "0" ]; then
  gap
  say "$(plural "$n_recorded" "run" "runs") copied out of $STATE_DIR into ${GAP_LEDGER#"$ORC_ROOT"/}, which is where they survive a reset. Commit it: it is the only copy."
fi

# --- the proposal, drafted by the one thing that drafts ----------------------

rc=0
if [ "$n_proposed" = "0" ]; then
  gap
  say "Nothing clears the bar, so no concept is proposed. Every exclusion above names its reason."
else
  step "the proposal"
  say "$(plural "$n_proposed" "term" "terms") got past the bar. $(basename "$DRAFTER") drafts the concept, because it is the only thing in this repository that writes one:"
  gap
  if [ "$draft" = "1" ]; then
    "$DRAFTER" --gap-terms "$WORK/proposed" --bundle "$BUNDLE" --quiet || rc=$?
  else
    # The drafter prints the drift line, and only this script knows what flags
    # this run was given, so the command it is to name is handed to it.
    "$DRAFTER" --gap-terms "$WORK/proposed" --bundle "$BUNDLE" --check --quiet \
      --drift-command "$SELF --draft$HINT_BASIS$HINT_FLAGS" || rc=$?
    gap
    say "Nothing was written into $BUNDLE. To draft it:"
    say "  $SELF --draft$HINT_BASIS$HINT_FLAGS"
    gap
    say "Or the words alone, one per line, for something that wants a list rather than a table:"
    say "  $SELF --terms$HINT_BASIS$HINT_FLAGS"
  fi
fi

banner "A DRAFTED ROW IS A LEAD AND NOT A FACT

Everything drafted from this carries \`generated:\` and no \`verified:\`, which is what OKF reads as unverified, and prompts/refine.md tells refinement to treat one as a lead to confirm rather than as knowledge to quote. A date goes on it when a person has read the row and agrees with it, and that is the only way any of this becomes knowledge.

Most rows are questions rather than answers. That is the honest outcome rather than a shortfall: if the repositories resolved a term, bin/orc-okf-draft.sh would already have put it in the bundle, so what reaches here is mostly what no artefact says. A row that names its hole gives somebody a question to answer; one that filled the space would read as complete and give them nothing.

What this ranked lives in ${GAP_LEDGER#"$ORC_ROOT"/} and in $STATE_DIR, and only the first of those survives bin/orc-reset.sh. Run this before a reset, or the gap of every run since the last one is gone: a refinement comment carries no term list, so bin/orc-reconcile.sh cannot bring it back."

[ "$n_proposed" = "0" ] || exit 1
exit "$rc"
