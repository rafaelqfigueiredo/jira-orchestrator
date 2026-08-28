#!/usr/bin/env bash
# Runs one ticket through refinement and acts on the verdict.
#
# Read-only by construction: it reads the ticket, the knowledge bundle and the
# repositories config/projects.yml names, and the only things it ever writes are
# a Jira comment, a label, an assignee and a duplicate link - all of which go
# through jira_write. It never touches a repository itself, and asserts as much
# around the agent call. Fetching is delegated to bin/orc-repos-sync.sh, which
# fast-forwards or refuses, and is the only thing here that writes to a clone.
#
# A round about to become terminal - a ready verdict, or the split-ready
# combination - gets a second agent call before anything is acted on: the
# adversarial re-read, which asks what in the ticket admits two readings that
# would produce different software. Two reads disagreeing about whether anything
# is left to ask is itself a finding, and the round is not treated as terminal
# while one is open. prompts/misread.md is the second prompt.
#
#   orc-refine.sh ORC-101                 refine and act
#   orc-refine.sh --judge-only ORC-101    print the verdict JSON, write nothing
#   orc-refine.sh --force ORC-101         refine again even if the ticket is unchanged
#
# Exit codes: 0 judged and acted on, 3 nothing to do, 2 the refiner failed.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

PROMPT="$ORC_ROOT/prompts/refine.md"
REFINER="${ORC_REFINER:-auto}"
judge_only=0
force=0
key=""

while [ $# -gt 0 ]; do
  case "$1" in
    --judge-only) judge_only=1 ;;
    --force)      force=1 ;;
    --prompt)     PROMPT="$2"; shift ;;
    --refiner)    REFINER="$2"; shift ;;
    -h|--help)    orc_usage "$0"; exit 0 ;;
    -*)           orc_die "unknown option: $1" ;;
    *)            key="$1" ;;
  esac
  shift
done

[ -n "$key" ] || orc_die "usage: orc-refine.sh [--judge-only] [--force] [--prompt FILE] [--refiner claude|replay] JIRA-KEY"
[ -f "$PROMPT" ] || orc_die "prompt not found: $PROMPT"

# 'auto' keeps the offline demo honest: fixture mode replays canned verdicts so
# the loop runs with no network, anything else calls the real agent.
if [ "$REFINER" = "auto" ]; then
  if [ "$ORC_JIRA_MODE" = "fixture" ]; then REFINER=replay; else REFINER=claude; fi
fi

# --- gather -----------------------------------------------------------------

issue=$(jira_read "/issue/$key?fields=summary,description,labels,issuetype,reporter,status,updated,comment")
[ -n "$issue" ] || orc_die "$key: could not read the issue"

summary=$(printf '%s' "$issue" | jq -r '.fields.summary // ""')
itype=$(printf '%s' "$issue" | jq -r '.fields.issuetype.name // "Task"')
reporter_id=$(printf '%s' "$issue" | jq -r '.fields.reporter.accountId // ""')
labels=$(printf '%s' "$issue" | jq -r '.fields.labels[]?' | tr '\n' ' ')
description=$(description_text "$issue")
hash=$(content_hash "$summary$description")
pversion=$(prompt_version "$PROMPT")

# The other half of "has anything happened here". The content hash covers the
# summary and the description and nothing else, so a reporter answering every
# question asked of them moved nothing refinement was keyed on and the loop
# stopped dead: the poll saw the ticket, the harvest matched the reply, and this
# script skipped it as unchanged. Read from the issue as it was fetched above,
# before this run posts anything, so the value recorded at the end is what this
# round actually saw rather than its own comment.
newest_comment_id=$(comment_field "$(newest_foreign_comment "$issue")" '.id')

# The opt-in gate, asked first because it is the cheapest question and the most
# decisive: a card nobody asked for is not judged, however much its text changed.
# The poll has already narrowed the intake in JQL, so this is that same rule
# applied to a key named on a command line - without it the gate would hold for
# the daemon and not for the operator, which is two behaviours from one setting.
#
# --force does not open it. Force is about a ticket that has been judged already
# and has not changed since; the gate is about whether the ticket is in scope at
# all, and those are different questions.
#
# --judge-only is deliberately outside it. That path writes nothing, and it is how
# golden/run.sh and bin/orc-locality-score.sh measure the prompt against fixture
# tickets that carry no labels at all: gated, a label configured for the real
# board would quietly turn every row of both reports into an error about a label.
if [ "$judge_only" = "0" ] && ! has_opt_in "$labels"; then
  log "$key: not labelled $LABEL_OPT_IN, which is the label refinement is gated on; leaving it alone"
  exit 3
fi

# Two things now re-open a round, and the skip is keyed on both rather than on
# one of them: the ticket's own text moving, and somebody other than this system
# commenting since it last judged.
#
# The skip itself is not softened, because that guard is what stops the daemon
# re-judging the whole board on every pass. A card nobody has touched still
# skips.
#
# The comment has to be somebody else's, and that is the whole risk here: a
# round ends by posting a question comment, so a rule that counted any new
# comment would re-trigger on its own footprint for ever. comment_is_ours draws
# that line in one place and newest_foreign_comment is the reader built on it,
# so this script never spells the marker for itself.
new_activity=0
if [ "$(meta_get "$key" comment_seen)" != "$newest_comment_id" ]; then new_activity=1; fi

if [ "$judge_only" = "0" ] && [ "$force" = "0" ]; then
  if [ "$(meta_get "$key" content_hash)" = "$hash" ] && [ "$new_activity" = "0" ] \
     && [ -n "$(meta_get "$key" verdict)" ]; then
    log "$key: unchanged and nothing new said since the last refinement ($(meta_get "$key" verdict)), skipping"
    exit 3
  fi
  # Jira is the other half of the memory: a refinement comment already on the
  # ticket means an earlier run got there, even if state/ was wiped.
  if [ -n "$(latest_marker_comment "$issue")" ]; then
    if [ "$(meta_get "$key" content_hash)" = "$hash" ] && [ "$new_activity" = "0" ]; then
      log "$key: already carries a refinement comment, and nothing has been said since, skipping"
      exit 3
    fi
  fi
  # Named rather than inferred from the absence of a skip line, because these are
  # the two different reasons a round is running and an operator watching a loop
  # that would not advance needs to see which one fired.
  if [ "$new_activity" = "1" ] && [ "$(meta_get "$key" content_hash)" = "$hash" ]; then
    log "$key: the ticket is unchanged but carries a comment this system did not write, judging again"
  fi
fi

# Open tickets, so a duplicate can be named rather than merely suspected.
open_list=$(jira_search "search/open-issues" \
  "project = $JIRA_PROJECT AND statusCategory != Done ORDER BY updated DESC" \
  summary,status,issuetype 50 \
  | jq -r --arg self "$key" '.issues[]? | select(.key != $self)
      | "\(.key) [\(.fields.issuetype.name // "?")/\(.fields.status.name // "?")] \(.fields.summary)"')

# --- knowledge and repository context ---------------------------------------

if okf --version >/dev/null 2>&1; then
  knowledge="The knowledge bundle is at $BUNDLE_DIR and the okf CLI is available.
Query it, do not guess:
  okf search $BUNDLE_DIR <term>     find concepts by text
  okf catalog $BUNDLE_DIR           list every concept with its metadata
  okf graph $BUNDLE_DIR             the link graph
Reading the files under $BUNDLE_DIR directly is equally fine.

Every concept's frontmatter says how far it has been checked. A verified: date
means a person confirmed it; generated: alone means a machine drafted it from
the repository and nobody has read it since. okf catalog prints both, so you can
tell before you rely on one. Weight them as the prompt says."
else
  knowledge="The knowledge bundle is at $BUNDLE_DIR. The okf CLI is not installed here,
so read the markdown files directly: start at $BUNDLE_DIR/index.md.

Every concept's frontmatter says how far it has been checked. A verified: date
means a person confirmed it; generated: alone means a machine drafted it from
the repository and nobody has read it since. Weight them as the prompt says."
fi

# --- the repositories this ticket may be reasoned against -------------------
# Knowledge first, config second. The bundle turns the ticket's words into a
# subsystem; config/projects.yml then says where that subsystem is checked out
# and which branch a ticket about it is about. This script offers the paths and
# records the provenance. Resolving the ticket's language to one of them is the
# refiner's job, and when the bundle does not know a term the right answer is a
# question rather than the likeliest guess.

repo_sync_if_asked() {
  case "${ORC_REPO_SYNC:-auto}" in
    off) log "ORC_REPO_SYNC=off: reasoning against whatever is on disk"; return 0 ;;
    on)  : ;;
    auto)
      # A fetch is only meaningful for a project the config gives a remote for,
      # and the shipped config gives none, so fixture mode stays runnable with
      # no network and no credentials.
      [ -n "$(managed_projects)" ] || return 0
      ;;
    *) orc_die "ORC_REPO_SYNC must be auto, on or off (got '$ORC_REPO_SYNC')" ;;
  esac
  # The sync script is the only thing in this repository that writes to a clone,
  # and it fast-forwards or refuses. A stuck clone is not fatal here: refinement
  # will decline to search it and say so on the ticket.
  # The report goes to stderr: this script's stdout is the verdict JSON in
  # --judge-only mode, and the golden harness parses it.
  "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet >&2 \
    || log "at least one clone is stuck; refinement will not search it"
}

repo_sync_if_asked

# --- design context (Figma) --------------------------------------------------
# Every Figma frame the ticket's own description already links, read the same
# way a repository is: written to files under state/ and named in the context
# below for the agent to open with Read. No FIGMA_TOKEN, and no link in the
# ticket, both leave this empty - see figma_design_context for why absent
# token is today's behaviour rather than a degraded one.
design_ctx=$(figma_design_context "$key" "$issue")

searchable=""      # name<TAB>path, the ones a verdict may name files from
provenance=""      # one line per project: what was reasoned against, and at which commit
stale_lines=""     # the ones that were on disk and not usable

for _p in $(project_names); do
  IFS=$'\t' read -r _st _sha _br _detail <<< "$(repo_state "$_p")"
  _path=$(project_repo_path "$_p")
  case "$_st" in
    ok|unmanaged)
      searchable="$searchable$_p	$_path
"
      ;;
    stale)
      stale_lines="$stale_lines$_p: $_detail
"
      ;;
  esac
  provenance="$provenance$(repo_provenance "$_p")
"
done
unset _p _st _sha _br _detail _path

if [ -n "$searchable" ]; then
  repo_ctx="Repositories to search, READ ONLY. Each is at the commit named, which is the
tip of the branch a ticket about it is about:

$(printf '%s' "$searchable" | while IFS=$'\t' read -r n p; do
    [ -n "$n" ] || continue
    sub=$(project_field "$n" subsystem)
    printf '  %-14s %-24s %s\n' "$n" "${sub:-(not in the bundle)}" "$p"
  done)
$(if printf '%s' "$searchable" | while IFS=$'\t' read -r n _; do
      [ -n "$(project_field "$n" subsystem)" ] && exit 1
    done; then :; else printf '%s' "
The middle column is the concept in the knowledge bundle each repository is the
code for. Resolve the ticket to a concept first and follow it here. A repository
with no concept named is one the bundle does not describe, and improvising in it
is exactly the guess you are here to avoid."
  fi)

Provenance, which every verdict carries:

$(printf '%s' "$provenance" | sed 's/^/  /')"
  if [ -n "$stale_lines" ]; then
    repo_ctx="$repo_ctx

These are on disk but were NOT searched, because the checkout is not the code a
ticket about them would be about. Treat them as unread: name no path in them,
and say so in not_verified.

$(printf '%s' "$stale_lines" | sed 's/^/  /')"
  fi
else
  repo_ctx="No repository is available to search in this run. Localise from the knowledge
bundle alone, set locality_basis accordingly, and say so in not_verified. Do not
name a path you have not seen.

$(printf '%s' "$provenance" | sed 's/^/  /')"
fi

# What this ticket has already had answered, across every prior round - read
# mechanically from $STATE_DIR/<key>.answers.json rather than trusted to
# either pass noticing on its own. bin/orc-harvest.sh already matched each of
# these to the question it addressed and already excluded a deferral from the
# match (answer_is_deferring in orc-lib.sh), so what is here is a genuine,
# settled answer and nothing else.
#
# Both passes read this. The first pass's own repeat-avoidance normally comes
# from reading domain/reporter-answers.md itself, which needs a drafter run in
# between; this is the same memory available immediately, with no such
# dependency. The second pass has nothing else to check its own "do not
# re-ask what has been settled" instruction against: without it, a second read
# re-raises the same disagreement round after round despite having been given an
# identical answer each time, because nothing tells it what a prior round had
# already asked and been told.
prior_qa=""
while IFS="$ORC_ANSWERED_FS" read -r _pq _pa; do
  [ -n "$_pq" ] || continue
  prior_qa="$prior_qa- Q: $_pq
  A: $_pa
"
done <<< "$(answered_qa_for "$key")"
unset _pq _pa
prior_qa_ctx=""
[ -n "$prior_qa" ] && prior_qa_ctx="# Settled: already asked and answered on an earlier round

Do not ask about any of these again, in these words or in any others, and do
not treat a rephrasing of one of them as a new finding.

$prior_qa"

# Everything the refiner is told about this ticket, held on its own because two
# passes read it. The second one is handed the identical context - same ticket,
# same bundle, same repositories at the same commits - so that what differs
# between the two answers is the question each was asked and nothing else.
ticket_ctx="# Ticket under refinement

key: $key
type: $itype
status: $(printf '%s' "$issue" | jq -r '.fields.status.name // "?"')
labels: ${labels:-none}
summary: $summary

description:
$description

# Other open tickets in this project

${open_list:-none}
$([ -n "$prior_qa_ctx" ] && printf '\n%s\n' "$prior_qa_ctx")
# Knowledge

$knowledge

$repo_ctx
$([ -n "$design_ctx" ] && printf '\n%s\n' "$design_ctx")"

agent_input="$(cat "$PROMPT")

$ticket_ctx

Reply with the single JSON object described above and nothing else."

# --- run the refiner --------------------------------------------------------

extract_json() {
  local raw="$1" candidate
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then printf '%s' "$raw"; return 0; fi
  # A literal code fence, not a variable: single quotes are correct here.
  # shellcheck disable=SC2016
  candidate=$(printf '%s' "$raw" | sed -n '/```/,/```/p' | sed '1d;$d')
  if [ -n "$candidate" ] && printf '%s' "$candidate" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$candidate"; return 0
  fi
  candidate=$(printf '%s' "$raw" | awk '/\{/{f=1} f' | awk 'BEGIN{RS="";} {print}' )
  if printf '%s' "$candidate" | jq -e . >/dev/null 2>&1; then printf '%s' "$candidate"; return 0; fi
  return 1
}

# Every repository the agent was given, by commit and by working-tree state, so
# the fence around the agent call notices a change in any of them rather than
# only in the first.
repo_fingerprint() {
  local name path out=""
  [ -n "$searchable" ] || { printf 'no-repo'; return 0; }
  while IFS=$'\t' read -r name path; do
    [ -n "$path" ] || continue
    is_git_repo "$path" || continue
    out="$out$name:$(git_read "$path" rev-parse HEAD 2>/dev/null):$(content_hash "$(git_read "$path" status --porcelain 2>/dev/null)")|"
  done <<< "$searchable"
  printf '%s' "${out:-no-repo}"
}

# How long the agent gets before the call is treated as wedged rather than slow.
# There was no limit anywhere, so a single stuck call blocked the whole run for
# as long as anyone was willing to wait, and reported nothing when they gave up.
# 0 switches the limit off.
#
# It was 300s, and the hardest ticket in the solved set - four deliverables
# stated as one - was killed at 303s and recorded as an error, which took real
# agreement from 5/5 to 4/5. The healthy tickets on that run took 118s to 200s,
# so the limit was sitting at two thirds of ordinary work and every step of
# reasoning a prompt gained came out of the margin. This is three times the
# slowest ticket that answered: a limit is for a wedged call, and one tight
# enough to catch a slow one turns thinking into a defect.
AGENT_TIMEOUT="${ORC_AGENT_TIMEOUT:-600}"

# The most agent calls one refinement can make: the first read, and the
# adversarial re-read on a round about to become terminal. Named because the
# limit above is per call and the limits outside this script are per refinement,
# and bin/orc-check.sh compares them - an outer limit that only outlasts one call
# would fire during the second and report a wedged refinement where the agent was
# merely thinking twice.
# shellcheck disable=SC2034  # read by bin/orc-check.sh out of this file
AGENT_CALLS_MAX=2

# run_claude <input> <what to call this pass in the log>
run_claude() {
  command -v claude >/dev/null 2>&1 || orc_die "the claude CLI is not installed; use --refiner replay"
  local input="$1" what="$2"
  local before after raw out started elapsed rc
  before=$(repo_fingerprint)
  out=$(mktemp)
  started=$(orc_epoch)
  # The agent's own stderr is not redirected, deliberately. It was swallowed, so
  # an agent that errored, asked a question or waited on input looked exactly
  # like an agent that was merely slow - and the operator had nothing to read
  # either way. This script's stdout is the verdict JSON; stderr is free.
  printf '%s' "$input" \
    | run_with_timeout "$AGENT_TIMEOUT" claude -p \
        --allowedTools "Read,Grep,Glob,Bash(okf:*)" \
        --output-format json > "$out"
  rc=$?
  elapsed=$(( $(orc_epoch) - started ))
  raw=$(jq -r '.result // empty' < "$out" 2>/dev/null)
  rm -f "$out"

  # The fence is checked whether or not the call succeeded. A killed agent can
  # have left a repository modified on its way out, and that is exactly the thing
  # this assertion exists to notice.
  #
  # Reported rather than fatal here, because this function is read inside $( )
  # and an orc_die in a command substitution kills the subshell and lets the run
  # carry on - the same rule ask and jira_search_all already follow. The status
  # is distinct so the caller can tell a fence break from an agent that merely
  # failed, and both call sites turn it into a fatal in the parent shell.
  after=$(repo_fingerprint)
  if [ "$before" != "$after" ]; then
    log "$key: refinement changed the target repository during $what. Refinement is read-only; this is a bug and no verdict will be acted on.
  before: $before
  after:  $after"
    return 99
  fi

  case "$rc" in
    0)
      log "$key: $what answered in ${elapsed}s"
      ;;
    124)
      log "$key: $what did not answer within ${AGENT_TIMEOUT}s and was killed (waited ${elapsed}s). Raise ORC_AGENT_TIMEOUT, or 0 for no limit."
      return 124
      ;;
    *)
      log "$key: $what exited $rc after ${elapsed}s; whatever it printed is above, not swallowed"
      return "$rc"
      ;;
  esac
  printf '%s' "$raw"
}

run_replay() {
  local map="$ORC_ROOT/golden/replay-map.tsv" rel tag file
  rel=${PROMPT#"$ORC_ROOT"/}
  tag=$(awk -F'\t' -v p="$rel" '$1==p {print $2}' "$map" 2>/dev/null)
  [ -n "$tag" ] || orc_die "replay mode: $rel is not listed in golden/replay-map.tsv"
  file="$VERDICT_DIR/$tag/$key.json"
  [ -f "$file" ] || orc_die "replay mode: no canned verdict at $file"
  cat "$file"
}

case "$REFINER" in
  claude)
    raw=$(run_claude "$agent_input" "the refiner"); rc=$?
    [ "$rc" = "99" ] && orc_die "$key: refinement is read-only and this run was not; nothing will be acted on"
    [ "$rc" = "0" ] || { log "$key: no verdict, because the refiner did not produce one"; exit 2; }
    ;;
  replay) raw=$(run_replay) ;;
  *)      orc_die "unknown refiner: $REFINER (expected claude or replay)" ;;
esac

verdict_json=$(extract_json "$raw") \
  || { log "$key: the refiner did not return JSON"; printf '%s\n' "$raw" | head -20 >&2; exit 2; }

verdict=$(printf '%s' "$verdict_json" | jq -r '.verdict // ""')
case "$verdict" in
  ready|needs_input|duplicate) : ;;
  *) log "$key: unrecognised verdict '$verdict'"; exit 2 ;;
esac

# Every verdict names what it was reasoned against, whether or not a comment is
# posted. When a named file turns out not to exist, the first question is whether
# the refiner was wrong or the checkout was old, and those have different fixes.
reasoned_against=$(printf '%s' "$provenance" | grep -c . | tr -d ' ')
reasoned_json=$(printf '%s' "$provenance" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')

# The gap the run leaves behind, and the two audits of it. Which of the ticket's
# words were looked up, which the bundle answered and which it could not is what
# the gap-driven loop ranks and what the reliability report counts, so it is
# recorded on every verdict whether or not a comment is posted.
#
# Both audits report and neither repairs. The refiner's own lists go into the
# record verbatim, and what is wrong with them travels beside them: a measurement
# corrected on the way in measures the correction.
terms_off=$(terms_off_ticket "$summary
$description" "$verdict_json")
terms_contra=$(terms_contradiction "$verdict_json")

# The set the ticket extends, and the places that already enumerate it.
#
# This one is not in the ticket and cannot be got out of it by reading harder. A
# card that adds one more of something the product enumerates elsewhere says
# nothing about the report that groups them - the word for that report is not in
# the reporter's vocabulary for this ticket, however long the ticket is, so
# reading the ticket harder never surfaces it. So it is read out of the code, in
# the repositories this run was already given, and it is a finding with a path
# behind it rather than a suspicion.
integration_findings=""
if [ -n "$searchable" ]; then
  integration_findings=$(integration_gaps "$summary
$description" "$searchable")
fi
if [ -n "$integration_findings" ]; then
  log "$key: the ticket names a member of a set the code enumerates elsewhere: $(printf '%s' "$integration_findings" | cut -d"$ORC_INTEGRATION_FS" -f3 | tr '\n' ';' | sed 's/;$//')"
fi

# A ticket that contradicts what the code already does, read the same way as
# the set above - not out of the ticket's own words, but out of a rule the
# code states. A database check constraint is the mechanical evidence: a small
# number with a repository behind it, the same shape answer_contradicts_text
# was built to compare, rather than a guess about what "differently" means.
contradiction_findings=""
if [ -n "$searchable" ]; then
  contradiction_findings=$(code_contradictions "$summary
$description" "$searchable")
fi
if [ -n "$contradiction_findings" ]; then
  log "$key: the ticket describes a number the code's own rules already state differently: $(printf '%s' "$contradiction_findings" | cut -d"$ORC_CONTRADICTION_FS" -f5 | tr '\n' ';' | sed 's/;$//')"
fi

# The three questions this harness can promote onto the ticket on the refiner's
# behalf, and all three are decided the same way.
#
# A term the ticket does not say is a meaning this run supplied and nobody gave
# it, which is the plainest evidence there is that the ticket is ambiguous on
# that word. A set the ticket extends carries work in the places that already
# enumerate its members, and whether the new one belongs there is a decision
# nobody has made. A number the code already enforces differently is a decision
# nobody has made either: the ticket may be wrong, or it may be asking for the
# rule to change, and only a person can say which.
#
# All three are derived rather than asked of the refiner as fields of their
# own, the same reason split_ready and terms_contradiction are: this run knows
# which words the ticket holds and what the code enumerates and enforces, so a
# self-declared "I looked for this" can disagree with the lists beside it and a
# derived one cannot.
#
# needs_input only. A ready comment carries no question list, and a harness that
# added one would be overruling a verdict rather than reporting on it - nothing
# here does that. A duplicate is being closed against another ticket, and a
# question about this one's words belongs on whichever ticket survives. All
# three still log the finding and still record it.
#
# In a function because the round can be judged twice. What is promoted depends
# on what has already been asked, and the second read below can add questions -
# so this runs once against the refiner's own list, which is what decides whether
# the round is terminal enough to earn a second read at all, and once more
# afterwards with that read's questions in hand. Where no second read happened
# the two calls agree by construction and the second is a no-op.
#
# The off-ticket promotion's own memory, on top of what THIS round already
# asked. Two gaps, both reachable without this: a term this round both
# resolved and promoted in the same breath, because nothing checked a
# promotion against this round's own terms_resolved; and a term promoted,
# answered, then re-promoted verbatim rounds later, because nothing checked a
# promotion against a PRIOR round at all. The refiner's own questions never
# show this failure, because the refiner reads domain/reporter-answers.md
# itself, every round - so both gaps get the same grounding, read the same
# mechanical way rather than trusted as a self-report: this round's own
# resolved terms are read off $verdict_json, and every prior round's answered
# question is read off $STATE_DIR/<key>.answers.json via answered_questions_for
# in orc-lib.sh, which is exactly what bin/orc-harvest.sh already matched a
# reply against - never a deferral, because answer_is_deferring already
# excluded those there.
resolved_this_round=$(printf '%s' "$verdict_json" | jq -r '
  (.terms_resolved // []) | map(if type == "object" then (.term // "") else tostring end)
  | .[] | select(length > 0)')
prior_answered_qs=$(answered_questions_for "$key")

# Globals rather than a printed pair, for the reason `ask` sets globals: read
# inside $( ) there would be one subshell per value and no way to return two.
promoted_terms=""
promoted_integration=""
promoted_contradiction=""
promotions() {
  local asked="$1"
  promoted_terms=""
  promoted_integration=""
  promoted_contradiction=""
  [ "$verdict" = "needs_input" ] || return 0
  promoted_terms=$(terms_off_to_ask "$terms_off" "$asked
$resolved_this_round
$prior_answered_qs")
  if [ -n "$integration_findings" ]; then
    promoted_integration=$(integration_to_ask "$integration_findings" "$asked")
  fi
  if [ -n "$contradiction_findings" ]; then
    promoted_contradiction=$(code_contradiction_to_ask "$contradiction_findings" "$asked")
  fi
  return 0
}

refiner_questions=$(printf '%s' "$verdict_json" | jq -r '.questions // [] | .[]? | tostring')
promotions "$refiner_questions"

# --- the adversarial re-read ------------------------------------------------
#
# The first pass enumerates what it still wants to know. A sentence with no gap
# in it passes that question cleanly while parsing two ways, so a card can be
# complete in every respect the bar names and still be about to be built wrong.
# Four independent single-round samples of one real card asked 1, 4, 4 and 8
# questions, and the one-question sample asserted a meaning the ticket never
# gave: a single pass is close to a lottery, and another sample of the same
# question is another ticket in it.
#
# So the second call asks a structurally different question - what in this text
# admits two readings that would produce different software - and it is handed
# the first read's own conclusion as the reading it is trying to find an
# alternative to. That is what makes it a re-read rather than a second guess.
#
# Gated on the round being about to become terminal, where a wrong call is most
# expensive: the card is about to be handed to somebody to build, or carved into
# slices drawn around this reading. Everywhere else another round is coming
# anyway, and the cost of being wrong is one more exchange rather than a week of
# somebody's work. That gate also bounds the cost - agent time doubles on the
# subset of calls approaching terminal, not on every ticket every round.
#
# A promotion above already un-terminates the round, so a card carrying one does
# not earn a second read either: it is going back to the reporter regardless.
MISREAD_PROMPT="$ORC_ROOT/prompts/misread.md"
misread_json='{"misreadings":[]}'
misread_qs=""
misread_ran=false
misread_status="not run: this round was not about to become terminal"
misread_pversion=""
misread_disagreed=false
# How many of this round's own findings were dropped as the same disagreement
# already asked and answered on a prior round - see misread_to_ask below.
misread_already_settled_count=0
verdict_first_read="$verdict"
# A ready comment's notes and not_verified may name code, because its audience
# includes an implementing agent. A comment that has stopped being one may not.
misread_prose_withheld=false

if ! verdict_is_terminal_shape "$verdict_json"; then
  : # the status set above already says so
elif [ -n "$promoted_terms" ] || [ -n "$promoted_integration" ] || [ -n "$promoted_contradiction" ]; then
  misread_status="not run: a promoted question had already un-terminated this round"
fi

if [ -z "$promoted_terms" ] && [ -z "$promoted_integration" ] && [ -z "$promoted_contradiction" ] \
   && verdict_is_terminal_shape "$verdict_json"; then
  if [ "$REFINER" = "claude" ]; then
    [ -f "$MISREAD_PROMPT" ] || orc_die "the second-read prompt is missing: $MISREAD_PROMPT"
    misread_pversion=$(prompt_version "$MISREAD_PROMPT")
    log "$key: this round would be terminal, so it gets a second, adversarial read"
    misread_input="$(cat "$PROMPT")

$ticket_ctx

$(cat "$MISREAD_PROMPT")

# What the first read concluded

$(printf '%s' "$verdict_json" | jq '{verdict, one_line, acceptance_criteria, split_into, questions}')

Reply with the single JSON object described under \"The contract\" above and nothing else."
    misread_raw=$(run_claude "$misread_input" "the adversarial re-read"); rc=$?
    if [ "$rc" = "99" ]; then
      orc_die "$key: refinement is read-only and this run was not; nothing will be acted on"
    elif [ "$rc" != "0" ]; then
      # Counted as an error, never as agreement and never as a disagreement -
      # the same rule golden/run.sh follows for a killed call. The first read is
      # still a verdict, and failing the whole refinement because a second
      # opinion did not arrive would throw away work that was done; announcing a
      # disagreement nobody stated would be worse still, because the comment
      # would then hand the card back with no question on it.
      misread_ran=true
      misread_status="error: the second read did not answer, so the round stands as the first one judged it"
      log "$key: $misread_status"
    elif misread_json=$(extract_json "$misread_raw"); then
      misread_ran=true
      # The second read's own findings, minus any that are the same
      # disagreement as one already asked and answered on a prior round of
      # this same ticket - misread_to_ask in orc-lib.sh, the same
      # derived-not-asked-of-the-model pattern terms_off_to_ask and
      # code_contradiction_to_ask already follow, extended to the pass that
      # had no such check at all. Everything the second read found is still
      # recorded below; this only decides what gets to un-terminate the round.
      misread_qs_all=$(misread_questions "$misread_json")
      misread_asked_json=$(misread_to_ask "$misread_json" "$prior_answered_qs")
      misread_qs=$(misread_questions "$misread_asked_json")
      misread_already_settled_count=$(( $(printf '%s' "$misread_qs_all" | grep -c .) - $(printf '%s' "$misread_qs" | grep -c .) ))
      if [ "$misread_already_settled_count" -gt 0 ]; then
        log "$key: the second read found $misread_already_settled_count reading(s) already asked and answered on an earlier round; not re-raised"
      fi
      misread_status="answered"
    else
      misread_ran=true
      misread_json='{"misreadings":[]}'
      misread_status="error: the second read did not return JSON, so the round stands as the first one judged it"
      log "$key: $misread_status"
      printf '%s\n' "$misread_raw" | head -20 >&2
    fi
  else
    # Replay has no second opinion to give. A canned one is a canned agreement,
    # which measures nothing, and inventing one would make fixture mode claim a
    # scrutiny it never performed. Fixture mode stays exactly as it was.
    misread_status="not run: only the real refiner has a second read"
  fi
fi

# Two reads disagreeing about whether anything is left to ask is itself the
# finding, and nothing here picks a winner. The union is asked and the cautious
# side is taken: the round is not terminal, so the split proposal and the
# rewritten description are both withheld, and a card the first read called ready
# goes back to the reporter with the question on it.
#
# That is not this harness overruling a verdict, which is the thing the two
# promotions above deliberately do not do. Those are the harness asking. This is
# the refiner asking, on a second reading of the same ticket under the same bar,
# and the readiness bar already says which way to fall when a judgment is torn:
# a deferred ticket costs a day and a misunderstood one costs a week.
if [ -n "$misread_qs" ]; then
  misread_disagreed=true
  log "$key: the second read found $(printf '%s' "$misread_qs" | grep -c .) reading(s) of this ticket that would build something else, so the round is not treated as terminal"
  if [ "$verdict" = "ready" ]; then
    verdict=needs_input
    misread_prose_withheld=true
    log "$key: the first read said ready and the second disagreed; the card goes back to the reporter, and the prose the first read wrote for an implementing agent is withheld"
  fi
fi

# Asked again with the second read's questions in hand, so a term or a set it
# already named is not asked about a second time underneath its own question.
promotions "$refiner_questions
$misread_qs"
terms_off_asked="$promoted_terms"
integration_asked="$promoted_integration"
contradiction_asked="$promoted_contradiction"
if [ -n "$integration_asked" ]; then
  log "$key: and asked about on the ticket, because where a new one belongs is a product decision"
fi
if [ -n "$contradiction_asked" ]; then
  log "$key: and asked about on the ticket, because whether the existing rule or the ticket's number is the one to keep is a product decision"
fi

gap_json=$(jq -nc \
  --argjson resolved "$(printf '%s' "$verdict_json" | jq -c '.terms_resolved // []')" \
  --argjson unresolved "$(printf '%s' "$verdict_json" | jq -c '.terms_unresolved // []')" \
  --argjson off "$(printf '%s' "$terms_off" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
  --argjson asked "$(printf '%s' "$terms_off_asked" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
  --arg contra "$terms_contra" \
  '{terms_resolved: $resolved, terms_unresolved: $unresolved, terms_off_ticket: $off,
    terms_off_asked: $asked,
    terms_contradiction: (if $contra == "" then null else $contra end)}')

[ -n "$terms_contra" ] && log "$key: $terms_contra"
if [ -n "$terms_off" ]; then
  log "$key: term(s) recorded that the ticket does not say, kept in the record and discounted by the report: $(printf '%s' "$terms_off" | tr '\n' ';' | sed 's/;$//')"
fi
if [ -n "$terms_off_asked" ]; then
  log "$key: and asked about on the ticket, because a meaning nobody gave is the reporter's to settle: $(printf '%s' "$terms_off_asked" | tr '\n' ';' | sed 's/;$//')"
fi

# The terminal signal for an oversized card: every blocking question already
# has an answer and only the split remains. Computed here rather than trusted
# from the refiner's own output, so it cannot say something the questions and
# split_into arrays beside it do not back up.
#
# A promoted term is an open question like any other, so it is not terminal
# while one is standing. That is the case this was worth getting right: a card
# read in words the ticket does not use, announced as having nothing left to ask,
# proposes a split drawn around a meaning nobody confirmed - and the split is the
# one thing on the comment a reporter is expected to act on rather than answer.
#
# An integration question is the same case: a card whose split is drawn around a
# set the ticket is extending, announced as having nothing left to ask, while
# nobody has said whether the new member belongs where the existing ones already
# are - the slices would be drawn around the wrong scope.
#
# A contradiction question is the same case again: a card whose split is drawn
# around a number the code already enforces differently, announced as having
# nothing left to ask, is a split drawn around a rule nobody has confirmed
# still holds.
#
# A misreading found by the second read is the same case again, and it is the one
# the whole second call exists for: a card whose split is drawn around a sentence
# nobody has said which way to read is a split drawn around the wrong scope, and
# the proposal is the one thing on the comment a reporter is expected to act on
# rather than answer.
split_ready=false
if [ -z "$terms_off_asked" ] && [ -z "$integration_asked" ] && [ -z "$contradiction_asked" ] \
   && [ -z "$misread_qs" ] && verdict_split_ready "$verdict_json"; then split_ready=true; fi

# What the ticket ends up asking: the refiner's questions from both of its reads,
# then the three this harness promotes.
#
# The second read's questions come immediately after the first read's, because
# they are the same refiner's questions under the same bar - one list of what it
# wants to know, arrived at by two different acts. The promoted ones follow,
# because they are findings about how the ticket was read rather than things
# either pass wanted to know.
#
# Assembled here rather than beside the comment it renders, for the reason the
# rewrite's own audit below is: the verdict record and --judge-only both have to
# carry it. Nothing else on the record says what the ticket was actually asked -
# `questions` is the refiner's own array, and three of the four sources here
# appear in no array the refiner wrote - so a report reading the record saw a
# round with a promoted question standing on it as a round that asked nothing.
asked_questions=$refiner_questions
if [ -n "$misread_qs" ]; then
  if [ -n "$asked_questions" ]; then
    asked_questions="$asked_questions
$misread_qs"
  else
    asked_questions=$misread_qs
  fi
fi
# The two findings about the product first, and the off-ticket one last: it is
# a question about how this run read the ticket rather than about the product
# itself.
if [ -n "$integration_asked" ]; then
  integration_question_text=$(integration_question "$integration_asked")
  if [ -n "$asked_questions" ]; then
    asked_questions="$asked_questions
$integration_question_text"
  else
    asked_questions=$integration_question_text
  fi
fi
if [ -n "$contradiction_asked" ]; then
  contradiction_question_text=$(code_contradiction_question "$contradiction_asked")
  if [ -n "$asked_questions" ]; then
    asked_questions="$asked_questions
$contradiction_question_text"
  else
    asked_questions=$contradiction_question_text
  fi
fi
if [ -n "$terms_off_asked" ]; then
  off_question=$(off_ticket_question "$terms_off_asked")
  if [ -n "$asked_questions" ]; then
    asked_questions="$asked_questions
$off_question"
  else
    asked_questions=$off_question
  fi
fi

# The one round shape that cannot advance the loop from either side: needs_input,
# not terminal, and nothing on the comment to answer. Derived from the list the
# comment is about to carry rather than trusted from the refiner, the same way
# split_ready, terms_contradiction and the integration and contradiction
# findings are - a refiner told not to return this shape can still return it,
# and a self-report cannot disagree with itself.
round_stuck=false
if round_is_stuck "$verdict" "$split_ready" "$asked_questions"; then
  round_stuck=true
  log "$key: needs_input with nothing to ask and nothing to split - the round cannot be acted on and would not advance the loop"
fi

# The two states in which the card is settled, and the only two that carry the
# rewritten description.
#
# A ready ticket is settled by definition: an agent could start now. A
# split-ready one is settled in every way a card proposing a split can be -
# nothing left to ask, only the split left to run. Everything else is not: an
# ordinary needs_input still has an answer outstanding, so a description
# rewritten around this round's reading could contradict the next round's, which
# is the same reason the split proposal itself is withheld until the terminal
# state. A duplicate is being closed against another ticket, and rewriting the
# text of a card nobody will open again is work aimed at nobody.
#
# Decided here rather than beside the comment it renders, because the rewrite's
# own audit below has to reach --judge-only and the verdict record as well.
settled=false
if [ "$verdict" = "ready" ] || [ "$split_ready" = "true" ]; then settled=true; fi

rewritten_description=$(printf '%s' "$verdict_json" | jq -r '.rewritten_description // empty')

# Whether the rewrite kept the ticket's own copy, and what happens when it did
# not.
#
# Paraphrasing a specification is what this field is for. Paraphrasing the
# user-facing copy inside one destroys it: a rewrite will return a card's exact
# strings as descriptions of themselves, so a banner becomes "a warning before
# the return is started" and a button label becomes "a button letting a clerk
# unlock one by hand". Read as prose that is an improvement; pasted onto the
# card, which is the one thing the fold asks the reporter to do, it is a
# deletion.
#
# So the strings are found in the ticket mechanically and their absence is
# reported - never repaired. Nothing here edits the refiner's text, for the
# reason the two audits beside terms_resolved do not either: a measurement
# corrected on the way in measures the correction, and a description saying
# something no refiner said is worse than a wrong one, because nothing in it
# traces back.
#
# And a non-empty list annotates the fold rather than withholding it. Withholding
# was tried first and it was the wrong answer: a terminal round then ends with no
# rewritten description on the card at all, over a couple of strings, one of
# which the extractor should never have nominated. A settled card's whole output
# is that description, so a check meant to protect it that ends by deleting it
# has taken more than it saved.
#
# So the fold is always offered on a settled round, and when a string went
# missing it opens by naming the strings and asking for them to be put back
# before the text is pasted. That is strictly more than withholding leaves
# behind: a reader can paste and reinstate, or decide not to paste, where a
# withheld fold leaves only the second. The strings are named in the ticket's
# own spelling, which is what makes reinstating them a copy rather than a
# translation back.
#
# The objection withholding was chosen on - that a caveat inside a fold titled
# "to copy across" sits in the one place a reader has already decided to skip -
# is answered by putting it in the fold's own title as well, which is the half
# of the fold somebody reads before deciding. And the caveat is safe to print
# for a reason the extractor already guarantees rather than one asserted here:
# every candidate has been through _verbatim_keep, which refuses a code-shaped
# one, so a dropped string cannot carry a path, a column or a class name onto a
# comment held to the reporter bar.
#
# It is not this harness overruling a verdict, which is the thing the three
# promoted questions deliberately do not do. The verdict stands, the label
# stands, the questions stand, and no question is added: "you dropped a string"
# is a finding about this run's own output rather than a product decision
# anybody could answer, so there is nobody to ask.
#
# Copy fidelity is one layer and content coverage is the one over it. The same
# run also lost requirements that are plain unquoted English - a tab layout, a
# rule about what a second follow-up shows - which are not quoted, not in
# another language, and so were never nominated as copy at all. The field is
# meant to be the ticket's whole content with the answers folded in, and a
# summary pasted over a description deletes whatever it left out.
#
# So rewrite_uncovered names the ticket's own statements the rewrite no longer
# says, and unlike the copy list it is recorded and nothing else: no fold is
# withheld, no question is added, and nothing on the comment changes. The two
# signals are not the same strength. "These characters are gone" is exact; "half
# the words of this sentence are nowhere in the rewrite" is a proxy on prose the
# field is *meant* to reword, and this repository's own rule is that a safe
# which was guessed is worse than no feature at all.
#
# A proportional threshold - act once more than some share of the ticket's
# statements are uncovered - was weighed and refused on the arithmetic. On the
# card this was found on, three lost statements sit in a description of some
# forty of them: any threshold that fired there would fire on a single
# misjudged survivor on a clean card, and a lever that cannot catch the evidence
# it was built for while it can annotate a good rewrite is worse than no lever.
# What this list is for first is measuring whether the prompt half worked; a
# threshold set from a known false-positive rate is a later task's, and it needs
# this record to exist before it can be set at all.
#
# So the two checks cannot fight each other, and that falls out of only one of
# them reaching the comment. The copy list annotates the fold and the coverage
# list touches it not at all, so there is no combination of the two that leaves
# a settled card with nothing - which is what the shape they were first given
# could do, since a withheld fold and a recorded-only finding compose to a
# comment holding neither.
rewrite_verbatim=""
rewrite_dropped_list=""
rewrite_uncovered_list=""
rewrite_annotated=false
if [ -n "$rewritten_description" ]; then
  rewrite_verbatim=$(ticket_verbatim_copy "$description")
  rewrite_dropped_list=$(rewrite_dropped "$rewrite_verbatim" "$rewritten_description")
  rewrite_uncovered_list=$(rewrite_uncovered "$description" "$rewritten_description")
fi
if [ -n "$rewrite_uncovered_list" ]; then
  log "$key: the rewritten description no longer says $(printf '%s' "$rewrite_uncovered_list" | grep -c .) statement(s) the ticket makes: $(printf '%s' "$rewrite_uncovered_list" | tr '\n' ';' | sed 's/;$//')"
fi
if [ -n "$rewrite_dropped_list" ]; then
  log "$key: the rewritten description drops $(printf '%s' "$rewrite_dropped_list" | grep -c .) string(s) the ticket states exactly: $(printf '%s' "$rewrite_dropped_list" | tr '\n' ';' | sed 's/;$//')"
  if [ "$settled" = "true" ]; then
    rewrite_annotated=true
    log "$key: so it is offered to copy across with those strings named on it, to be put back before it is pasted"
  fi
fi

# What the second read did, on every verdict and whether or not it changed one.
# A pass that ran and found nothing is the result that argues against keeping it,
# and a pass that never ran is a different fact from one that ran and agreed - so
# the status says which, rather than a boolean saying neither.
misread_json_record=$(jq -nc \
  --argjson ran "$misread_ran" --arg status "$misread_status" \
  --arg pv "$misread_pversion" --argjson dis "$misread_disagreed" \
  --argjson f "$(printf '%s' "$misread_json" | jq -c '.misreadings // []')" \
  --argjson asc "$misread_already_settled_count" \
  '{ran: $ran, status: $status,
    prompt_version: (if $pv == "" then null else $pv end),
    disagreed: $dis, findings: $f, already_settled_count: $asc}')

# The verdict as it is recorded: the refiner's object, plus what this run knows
# about it. Built in one place so --judge-only and the state record cannot drift
# apart - the golden harness reads the first and the reports read the second.
#
# `verdict` is the one acted on, which is the second read's when the two
# disagreed; `verdict_first_read` is what the first pass said. Both, because a
# record carrying only the acted one loses the disagreement, and one carrying
# only the refiner's own would report a verdict this run did not act on - and the
# golden harness reads that field.
verdict_record() {
  printf '%s' "$verdict_json" | jq --arg k "$key" --arg p "$pversion" \
    --argjson r "$reasoned_json" --argjson g "$gap_json" --argjson sr "$split_ready" \
    --argjson ig "$(integration_gaps_json "$integration_findings")" \
    --argjson ia "$(printf '%s' "$integration_asked" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0)) | map(split("\u0002")[2] // "")')" \
    --argjson cg "$(code_contradictions_json "$contradiction_findings")" \
    --argjson ca "$(printf '%s' "$contradiction_asked" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0)) | map(split("\u0002")[4] // "")')" \
    --argjson rv "$(printf '%s' "$rewrite_verbatim" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
    --argjson rd "$(printf '%s' "$rewrite_dropped_list" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
    --argjson ru "$(printf '%s' "$rewrite_uncovered_list" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
    --argjson ra "$rewrite_annotated" \
    --argjson qa "$(printf '%s' "$asked_questions" | jq -Rsc 'rtrimstr("\n") | split("\n") | map(select(length > 0))')" \
    --argjson st "$round_stuck" \
    --arg v "$verdict" --arg vf "$verdict_first_read" --argjson mr "$misread_json_record" \
    '. + {key:$k, prompt_version:$p, reasoned_against:$r, split_ready:$sr,
          integration_gaps:$ig, integration_asked:$ia,
          contradiction_gaps:$cg, contradiction_asked:$ca,
          rewrite_verbatim:$rv, rewrite_dropped:$rd, rewrite_uncovered:$ru,
          rewrite_annotated:$ra,
          questions_asked:$qa, round_stuck:$st,
          verdict:$v, verdict_first_read:$vf, misread:$mr} + $g'
}

if [ "$judge_only" = "1" ]; then
  verdict_record | jq -c .
  exit 0
fi

# --- act --------------------------------------------------------------------

# A stuck round is recorded and then refused, and the refusal is the whole point:
# posting it is the harm. The label would move the card to "waiting on the
# reporter" and the assignee would hand it to them, while the comment asks them
# nothing and proposes nothing - so somebody is pinged about a card there is no
# way to act on, and the next round reads the same ticket to the same place.
# Written first so the finding is durable and a report can count it, then loud:
# bin/orc-daemon.sh counts a non-zero refinement as a failure and names the
# ticket, which is what a stall needs and what it never had.
#
# The ticket is left exactly as it was found. Nothing in state/ records the round
# as refined either, so the next pass judges it again rather than treating a
# round that produced nothing as a round that produced a verdict.
if [ "$round_stuck" = "true" ]; then
  verdict_record > "$STATE_DIR/$key.verdict.json"
  status_add "$key" "not refined: needs_input with nothing to ask and nothing to split"
  orc_die "$key: the refiner returned needs_input with no question and no split, so there is nothing to post that anybody could act on; nothing was written to the ticket"
fi

get()      { printf '%s' "$verdict_json" | jq -r "$1 // empty"; }
get_lines() { printf '%s' "$verdict_json" | jq -r "$1 // [] | .[]? | tostring"; }

one_line=$(get '.one_line')
notes=$(get '.notes')
not_verified=$(get '.not_verified')
# The first read wrote these two for an implementing agent, under the one verdict
# where the reporter bar lets them name a path, a field or one of this system's
# own nouns. The round is no longer that verdict, and text written for one
# audience is not re-addressed by being reprinted for another - so both are
# withheld and the fact is recorded. Withheld rather than scanned and kept when
# clean, because a scanner here would be a second spelling of the one
# bin/orc-check.sh holds, and two spellings of a safety bar eventually disagree
# about what it forbids.
if [ "$misread_prose_withheld" = "true" ]; then
  notes=""
  not_verified=""
fi
duplicate_of=$(get '.duplicate_of')
files=$(get_lines '.files')
subsystems=$(get_lines '.subsystems')
split_into_json=$(printf '%s' "$verdict_json" | jq -c '.split_into // []')
criteria=$(get_lines '.acceptance_criteria')
footer="$ORC_COMMENT_MARKER prompt=$pversion ticket-rev=$hash"

# Two audiences, and only one of them is reading Jira by choice.
#
# A ready ticket is picked up by an implementing agent, so its comment carries
# the locality and the exact commit the search was done at.
#
# A needs_input or duplicate comment is addressed to the person who filed the
# ticket - a reporter, a support agent, a clinician - and asks them for product
# judgment. File paths, subsystem names and commit hashes are noise to them, and
# a reporter who is asked to read engineering detail to answer a question about
# their own product is how this gets switched off in a fortnight. The locality is
# not lost: it is in the verdict record under state/, which is what the next
# phase reads.
#
# On a ready comment the two audiences read the same comment, and there the
# engineering half is not noise - it is what the implementing agent came for. It
# is still the longer half, and printed flat it pushes the summary and the
# criteria off the top of the card, so a person opening the ticket reads three
# headings of paths before the sentence saying what the ticket is about. So it
# goes behind a fold: nothing is dropped and nothing is shortened, and the first
# thing on the card is the thing a person came for.
#
# The fold is one node rather than a wrapper around the rest. ADF's expand is a
# top-level block, so it is a sibling of the paragraphs around it, and where it
# sits in the document is where the collapsed line sits on the card.
add_locality_fold() {
  local doc="$1" inner
  inner=$(adf_new)
  if [ -n "$files" ]; then
    inner=$(adf_heading "$inner" 3 "Probable files")
    inner=$(adf_bullets "$inner" "$files")
  fi
  if [ -n "$subsystems" ]; then
    inner=$(adf_heading "$inner" 3 "Subsystems")
    inner=$(adf_bullets "$inner" "$subsystems")
  fi
  # The places that already enumerate a set this ticket extends. Here rather than
  # in a question, because on a ready verdict there is no question list to join
  # and because this half of the finding is a list of paths - which is exactly
  # what this fold's audience came for. Nothing is asserted about what should
  # happen there: the sites are named and the implementing agent decides.
  if [ -n "$integration_findings" ]; then
    inner=$(adf_heading "$inner" 3 "Already enumerates a set this ticket extends")
    inner=$(adf_bullets "$inner" "$(integration_site_lines "$integration_findings")")
  fi
  if [ -n "$provenance" ]; then
    inner=$(adf_heading "$inner" 3 "Reasoned against")
    inner=$(adf_bullets "$inner" "$provenance")
  fi
  # The title names the audience, because that is what tells a person reading the
  # card that they are allowed to skip it.
  adf_expand "$doc" "For the implementing agent: files, subsystems, commits" "$inner"
}

# The synthesis the loop never did. Refinement asks, the reporter answers in a
# comment, and the description stays exactly as it was filed - a multi-round run
# ends on the same ticket revision it started on, every question asked, answered
# and signed, and the card's own text untouched. What the loop produced was an
# ambiguous description plus a thread of archaeology,
# and the next person to open the ticket - or the agent that picks it up - has to
# reconstruct the settled truth by reading it in order.
#
# So once the card is settled the comment carries the description as it now
# reads: the original intent with every answer folded into the sentence it
# belongs in, and the ambiguities gone. It replaces the description rather than
# annotating it, which is why it is one piece of prose and never a list of what
# was asked.
#
# It is offered, never applied. Nothing here writes to the description field and
# nothing ever will: the text on a card is the reporter's, and a system that
# rewrote it would be making a product decision on their behalf under the cover
# of a formatting one. So the fold says in the first line that the ticket has not
# been changed, because a fold titled "rewritten" read from the outside could be
# taken for something that already happened.
#
# Folded for the same reason the engineering half of a ready comment is: it is
# the longest thing on the comment, and flat it would push the questions or the
# split - the things somebody is meant to act on - off the top of the card.
add_description_fold() {
  local doc="$1" inner body title
  [ -n "$rewritten_description" ] || { printf '%s' "$doc"; return 0; }
  # Built through the same converter every other document in this system is
  # built by, so a paragraph, a bullet and a heading in here are the same nodes
  # they are anywhere else - and an expand is not one of the things it can
  # produce, which is what keeps this fold free of a nested one.
  body=$(adf_from_markdown <<< "$rewritten_description" | jq -c '.content')
  [ "$(jq 'length' <<< "$body")" -gt 0 ] || { printf '%s' "$doc"; return 0; }
  inner=$(adf_new)
  title="The ticket, rewritten with every answer folded in - to copy across"
  if [ "$rewrite_annotated" = "true" ]; then
    # The caveat goes above the text and into the title, because the title is
    # the half of a fold somebody reads before deciding to open it. The strings
    # are listed in the ticket's own spelling, so putting them back is a copy
    # rather than a translation back - and they are safe to print because every
    # one of them has already been refused if it was code-shaped.
    title="$title, once the wording listed inside is put back"
    inner=$(adf_para "$inner" "The ticket has not been changed. This is how its description reads with every answer folded in. It says some of the ticket's own wording differently, so put these back before you copy it across:")
    inner=$(adf_bullets "$inner" "$rewrite_dropped_list")
  else
    inner=$(adf_para "$inner" "The ticket has not been changed. This is how its description reads with every answer folded in; copy it across when you are happy with it.")
  fi
  inner=$(jq -c --argjson b "$body" '. + $b' <<< "$inner")
  adf_expand "$doc" "$title" "$inner"
}

doc=$(adf_new)

case "$verdict" in
  ready)
    doc=$(adf_heading "$doc" 3 "Refinement: ready")
    [ -n "$one_line" ] && doc=$(adf_para "$doc" "$one_line")
    if [ -n "$criteria" ]; then
      doc=$(adf_heading "$doc" 3 "Acceptance criteria, as the ticket states them")
      doc=$(adf_bullets "$doc" "$criteria")
    fi
    [ -n "$notes" ] && doc=$(adf_para "$doc" "$notes")
    [ "$settled" = "true" ] && doc=$(add_description_fold "$doc")
    doc=$(add_locality_fold "$doc")
    ;;
  needs_input)
    if [ "$split_ready" = "true" ]; then
      doc=$(adf_heading "$doc" 3 "Refinement: nothing left to ask, only the split remains")
    else
      doc=$(adf_heading "$doc" 3 "Refinement: this needs a little more before an agent can pick it up")
    fi
    [ -n "$one_line" ] && doc=$(adf_para "$doc" "$one_line")
    if [ -n "$asked_questions" ]; then
      doc=$(adf_para "$doc" "Answering these in the description is enough to unblock it:")
      doc=$(adf_ordered "$doc" "$asked_questions")
    fi
    # A round with open questions may still compute a candidate split_into
    # internally (verdict_split_ready needs it, and it is useful signal), but
    # it is rendered only once the loop reaches the terminal state: an early
    # split proposal changes shape round to round and the reporter should
    # never see one that could still contradict the next.
    if [ "$split_ready" = "true" ] && [ "$(jq 'length' <<< "$split_into_json")" -gt 0 ]; then
      doc=$(adf_para "$doc" "Every question here is answered. The ticket is ready to be split into:")
      doc=$(adf_bullets_titled "$doc" "$split_into_json")
    fi
    [ "$settled" = "true" ] && doc=$(add_description_fold "$doc")
    [ -n "$notes" ] && doc=$(adf_para "$doc" "$notes")
    ;;
  duplicate)
    doc=$(adf_heading "$doc" 3 "Refinement: looks like a duplicate")
    if [ -n "$duplicate_of" ]; then
      doc=$(adf_para "$doc" "This looks like the same defect as $duplicate_of.")
    else
      log "$key: duplicate verdict without naming a ticket; treating as needs_input"
      verdict=needs_input
      doc=$(adf_new)
      doc=$(adf_heading "$doc" 3 "Refinement: possible duplicate, ticket not identified")
    fi
    [ -n "$notes" ] && doc=$(adf_para "$doc" "$notes")
    ;;
esac

[ -n "$not_verified" ] && doc=$(adf_para "$doc" "Not verified: $not_verified")
doc=$(adf_rule "$doc")
doc=$(adf_para_em "$doc" "$footer")

jira_comment_adf "$key" "$(adf_comment_body "$doc")"

case "$verdict" in
  ready)
    jira_add_label "$key" "$LABEL_READY"
    ;;
  needs_input)
    jira_add_label "$key" "$LABEL_NEEDS_INPUT"
    # Section 3: hand it back to the person who can answer.
    jira_assign "$key" "$reporter_id"
    ;;
  duplicate)
    jira_add_label "$key" "$LABEL_DUPLICATE"
    [ -n "$duplicate_of" ] && jira_link_duplicate "$key" "$duplicate_of"
    ;;
esac

meta_set "$key" verdict "$verdict"
meta_set "$key" phase "refined"
meta_set "$key" content_hash "$hash"
# The newest comment somebody else had left by the time this round read the
# ticket, so the next pass can tell a reply that has arrived since from the
# question comment this round is about to post. Its id rather than its created
# timestamp: an id is compared for equality, where two timestamps carrying their
# own timezone offsets cannot be ordered lexically and this needs no ordering -
# "the newest one is not the one I saw" is the whole question.
#
# bin/orc-reconcile.sh rebuilds it, so state/ stays a cache: the position of this
# system's own last comment in the thread says which comments were already there
# when it judged.
meta_set "$key" comment_seen "$newest_comment_id"
meta_set "$key" prompt_version "$pversion"
meta_set "$key" refined_at "$(orc_now)"
# What the ticket was asked, which is the refiner's questions plus any promoted
# term, and then the promoted count on its own so the two are separable.
meta_set "$key" question_count "$(printf '%s' "$asked_questions" | grep -c . || true)"
meta_set "$key" terms_off_asked_count "$(printf '%s' "$gap_json" | jq '.terms_off_asked | length')"
# The second read, in the three figures a report about it wants: whether it ran
# at all, what it found, and whether it moved the round. A pass that costs an
# agent call and finds nothing every time is the result that argues against
# keeping it, and these are what would show that.
meta_set "$key" misread_ran "$(if [ "$misread_ran" = "true" ]; then printf 'yes'; else printf 'no'; fi)"
meta_set "$key" misread_status "$misread_status"
meta_set "$key" misread_question_count "$(printf '%s' "$misread_qs" | grep -c . || true)"
meta_set "$key" misread_already_settled_count "$misread_already_settled_count"
meta_set "$key" misread_disagreed "$(if [ "$misread_disagreed" = "true" ]; then printf 'yes'; else printf 'no'; fi)"
meta_set "$key" verdict_first_read "$verdict_first_read"
meta_set "$key" integration_gap_count "$(printf '%s' "$integration_findings" | grep -c . || true)"
meta_set "$key" integration_asked_count "$(printf '%s' "$integration_asked" | grep -c . || true)"
meta_set "$key" contradiction_gap_count "$(printf '%s' "$contradiction_findings" | grep -c . || true)"
meta_set "$key" contradiction_asked_count "$(printf '%s' "$contradiction_asked" | grep -c . || true)"
meta_set "$key" file_count "$(printf '%s' "$files" | grep -c . || true)"
meta_set "$key" reasoned_against "$(printf '%s' "$provenance" | tr '\n' ';' | sed 's/;$//')"
meta_set "$key" repo_count "$reasoned_against"
meta_set "$key" terms_resolved_count "$(printf '%s' "$gap_json" | jq '.terms_resolved | length')"
meta_set "$key" terms_unresolved_count "$(printf '%s' "$gap_json" | jq '.terms_unresolved | length')"
meta_set "$key" terms_contradiction "$(if [ -n "$terms_contra" ]; then printf 'yes'; else printf 'no'; fi)"
meta_set "$key" split_ready "$(if [ "$split_ready" = "true" ]; then printf 'yes'; else printf 'no'; fi)"
# Always no by the time this is written, because a stuck round refuses to act
# before it reaches here. Recorded anyway so a report reading state/ never has to
# infer it from an absence, the same reason description_rewritten is recorded on
# every verdict rather than only where it is rendered.
meta_set "$key" round_stuck "$(if [ "$round_stuck" = "true" ]; then printf 'yes'; else printf 'no'; fi)"
# Recorded on every verdict rather than only where it is rendered, because the
# question worth answering later is whether the refiner produced a rewrite at
# all - a settled card saying no is the prompt half failing, and an unsettled
# one saying yes is a rewrite that was written and thrown away.
meta_set "$key" description_rewritten "$(if [ -n "$rewritten_description" ]; then printf 'yes'; else printf 'no'; fi)"
# What the ticket stated exactly, how much of it the rewrite lost, and whether
# that cost the card its fold. Split the way integration_gaps/integration_asked
# and contradiction_gaps/contradiction_asked are: found is one fact, acted on is
# another, and a report reading only the second could not tell a clean rewrite
# from a ticket with no copy in it.
meta_set "$key" rewrite_verbatim_count "$(printf '%s' "$rewrite_verbatim" | grep -c . || true)"
meta_set "$key" rewrite_dropped_count "$(printf '%s' "$rewrite_dropped_list" | grep -c . || true)"
meta_set "$key" rewrite_uncovered_count "$(printf '%s' "$rewrite_uncovered_list" | grep -c . || true)"
meta_set "$key" rewrite_annotated "$(if [ "$rewrite_annotated" = "true" ]; then printf 'yes'; else printf 'no'; fi)"
[ -n "$duplicate_of" ] && meta_set "$key" duplicate_of "$duplicate_of"
verdict_record > "$STATE_DIR/$key.verdict.json"
status_add "$key" "refined: $verdict (prompt=$pversion)"

log "$key: $verdict"
