#!/usr/bin/env bash
# Turns a reporter's answer to a refinement question into a drafted row with its
# provenance attached.
#
#   orc-harvest.sh                       read the comments, report, write nothing
#   orc-harvest.sh --draft               also draft the answers into the bundle
#   orc-harvest.sh --nudge               also ask again where a reply was not understood
#   orc-harvest.sh --key ORC-102         one ticket rather than the project
#   orc-harvest.sh --rows                the drafted rows, machine-readable
#   orc-harvest.sh --bundle DIR          read and draft into DIR instead of .okf
#   orc-harvest.sh --quiet               the tables only, no preamble
#
# The reviewing half is bin/orc-verify.sh: it lists every drafted row awaiting a
# decision, shows one before it is signed, and records the refusals. A row it has
# already settled is not proposed here again.
#
# ## Why this is worth doing at all
#
# `prompts/refine.md` asks every question that blocks readiness in one round -
# there is no cap on how many - and forbids asking anything answerable by
# reading the code. So every question refinement asks is, by construction,
# something no repository says - which is exactly the knowledge
# `bin/orc-okf-draft.sh` cannot generate and `bin/orc-gap-loop.sh` can only
# report the absence of.
#
# The reporter then answers, in a Jira comment, at the moment they are thinking
# about it and in a place they were already standing. Author and timestamp come
# free. Nothing was reading those replies.
#
# ## What it must never do
#
# It must never write `verified:`, and that is the whole design rather than a
# safety rail bolted to the side of it. Three separate reasons, and any one of
# them is enough:
#
#   A reporter's answer is scoped to their ticket, not to the product. "Which
#   case list?" answered with "the doctor queue" resolves that ticket; it does
#   not define the term. Promoting a ticket-scoped answer into general knowledge
#   is how a confidently wrong fact gets in, and carrying `verified:` it would
#   never be corrected: the drafter refuses to overwrite a verified concept, and
#   the prompt tells refinement to quote one as established.
#
#   `verified:` means a person read *the concept* and agrees with it. A support
#   agent answering a question about their own ticket has done no such thing and
#   may be guessing. Treating the two as equivalent launders an opinion into
#   knowledge.
#
#   The bundle already refuses to promote a phrase unless two repositories say
#   it. One person saying something once is weaker evidence than that, not
#   stronger, so it cannot arrive with a stronger claim attached.
#
# So the answer becomes a drafted row carrying its provenance - what was asked,
# what was said, who said it, when, and on which ticket. `generated:`, no
# `verified:`. The sign-off a human still has to give is unchanged; what changes
# is that they are reviewing a proposed answer with a named source instead of a
# blank question.
#
# ## How an answer is matched to its question
#
# Mechanical first, always. Three rules, tried in order, none of them reading
# what the answer means:
#
#   by number      A block that opens by addressing a question - `2.`, `(2)`,
#                  `#2`, `re 2:`, `Q2`, `answer 2` - answers that question, and
#                  so does every block after it until one addresses another. A
#                  reply is paragraphs, and the substance of a numbered answer
#                  is usually in the ones underneath the number rather than on
#                  the line carrying it. The number has to be one refinement
#                  actually asked, so on a three-question ticket only 1, 2 and 3
#                  address anything and "1988 was the year" addresses nothing.
#   by position    The reply is an ordered list with exactly as many items as
#                  there were questions, and no item addressed one by number.
#                  Then item i answers question i, which is what the person
#                  typing the list meant.
#   the only one   Refinement asked exactly one question and the reply addresses
#                  nothing by number. There is only one thing it can be about.
#
# Only when none of those three fire does a fourth rule read the reply for
# meaning:
#
#   by reading     The reply is split into sentence-sized fragments and each one
#                  is scored against every open question by the folded content
#                  words the two sides share. A fragment goes to the question it
#                  shares the most words with, provided that is a unique
#                  maximum greater than zero; a fragment that shares nothing, or
#                  ties between two questions, answers nothing. Some questions in
#                  the same reply can be answered this way and others not: a
#                  reply answering only some of them attributes only those, and
#                  that is normal rather than a failure to parse the rest.
#
# A comment that still satisfies none of the four is reported rather than
# guessed at (`unattributed`): a row whose question is a guess is worse than no
# row.
#
# by-reading exists because people answer several questions in one paragraph
# with no numbering at all, and today's mechanical rules drop every one of
# those replies on the floor. Reading for meaning can misattribute a fragment in
# a way the first three rules structurally cannot - so every row records which
# of the four matched it, and a reviewer signing off sees which kind of evidence
# they are looking at before they sign. The risk this takes is bounded by the
# same gate that bounds everything else this script produces: a misread becomes
# a DRAFTED row a human rejects, never a verified fact. The cost of being wrong
# here is a rejected proposal; the cost of not trying is losing every prose
# answer anyone writes.
#
# The numbering a reply refers to is the numbering of the most recent question
# comment above it, which is what makes "answered three days later" and "refined
# again in between" both work. A comment posted before anything was asked is not
# an answer to anything and is skipped.
#
# What is kept is the answer verbatim, minus the token that addressed the
# question - the whole run of blocks that answer belongs to, for a numbered one
# - or, for a fragment matched by reading, the fragment itself. Not a
# definition extracted from it: reading a comment wrongly writes a wrong row,
# and a row that quotes a person and names them is reviewable by the person who
# said it. Every row also carries the whole reply it was drawn from, unedited,
# because the extraction is exactly what a reviewer needs to check against its
# source - most visibly for a `by reading` row, where the two can differ.
#
# ## Two people, two answers
#
# That is a finding rather than a tie to break. Every answer is kept, the row
# says the question is contested and prints both with their authors, and the
# report has a section for it. Nothing here picks a winner, and a drafted row
# that quietly dropped one of two answers would be the most expensive kind of
# wrong: it would look settled.
#
# ## A reply that answers without deciding
#
# Being matched to a question and resolving it are different claims, and only
# the first was ever checked. "Whatever's easiest for engineering" addresses a
# question by every rule above exactly as cleanly as "19 euros" does, and a
# loop reading the question as settled when nothing was decided is how the
# whole chain built on top of "answered" this week - the completeness rule, the
# terminal signal, the split proposal - reaches a conclusion nobody actually
# reached.
#
# So a matched reply is checked a second time, for whether it commits to
# anything at all: `answer_is_deferring` in `bin/orc-lib.sh`, a bounded set of
# the stock phrasings that hand a decision back to whoever asked rather than a
# guess at meaning. It is not asked of the model that judges the ticket -
# `bin/orc-harvest.sh` makes no agent call at all, and this project's own
# findings this week say a prompt-side "notice this" instruction has shipped
# twice without proving itself, while every derived check it shipped alongside
# one did. See the comment on `ORC_DEFERRAL_PHRASE` for the full reasoning and
# what it costs to be wrong.
#
# It judges the whole answer, which for a numbered one is the whole run of
# blocks that answer belongs to rather than the block that carried the number.
# The gate reads exactly the string the row would carry, because a gate that
# reads a prefix of what it gates is protecting something other than what it
# judged. That became load-bearing the moment a numbered answer stopped being
# one block: a run's later paragraphs are drafted now, so a gate still reading
# only the opening would let a decision handed back three paragraphs down onto
# a row without ever having looked at it - the widening would have widened what
# is drafted and left the check where it was.
#
# The phrase list matches anywhere in what it is given, so a wider scope can
# only ever find more deferrals, never fewer. An answer that decides and then
# adds "either way is fine" about some detail is asked again once, and that
# direction is the one this project already accepts: a wrong yes costs a
# round-trip, a wrong no reaches a reviewer who has to read every word before
# signing anything. The list is the gate; the review is the backstop.
#
# A reply judged as deferring is not drafted: it does not become a row, it does
# not count as an answer, and the question it was matched to stays open. That
# is the `terms_off_to_ask` / `off_ticket_question` precedent applied here - a
# harness-side finding is promoted rather than silently discounted - so the
# reply feeds the same asking-again machinery a reply nobody could address at
# all already has: eligible for `--nudge` once, and reported under its own
# heading rather than `--nudge`ed a second time if the round was already a
# reask.
#
# ## A new answer checked against what is already settled
#
# Nothing checked a fresh answer against the ticket's own description, or
# against an answer already signed on this same ticket. A contradiction is
# worse than a gap: an open question announces itself as unresolved, and a
# contradiction hides inside something that now reads as a settled fact.
#
# `answer_contradiction` in `bin/orc-lib.sh` catches the one shape of that
# which is both mechanical and the paradigm case: two different numbers about
# what reads as the same subject, sharing enough of the question's own words
# with the description or the earlier answer to be plausibly about it. It does
# not understand either text, and it does not catch a disagreement stated in
# words rather than figures - that is a named and accepted gap, not a claim of
# full contradiction detection.
#
# The reporter's disagreement rule applies here exactly as it does to two
# people answering one question differently: nothing here picks a winner. A
# candidate contradiction is not resolved and not asked about on the ticket -
# it is a note that travels on the row into `state/<key>.answers.json`, and
# `bin/orc-verify.sh` is where it surfaces, because that is the one place a
# human already reads a fact in full before agreeing to it. Reusing that
# review step rather than inventing a Jira question for something the harness
# only suspects keeps a false positive cheap: it costs one line a reviewer
# reads and can dismiss, not a round-trip to the reporter.
#
# ## When the bundle already claimed to know
#
# The loudest thing this can produce. `terms_unresolved` on the verdict says
# which of the ticket's words refinement looked up and could not answer; when a
# *verified* concept turns out to say one of those words, and a person then had
# to answer a question about the ticket by hand, one of two things is true: the
# verified fact is stale, or refinement could not find it. Both are worth
# somebody's afternoon, and neither is visible from anywhere else.
#
# So that collision gets a banner and is named on the row. It is not the same
# check `bin/orc-gap-loop.sh` makes when it drops a term because "the bundle
# already says it" - that one is about any concept, and it exists to stop a
# second answer being drafted. This one is about a concept a human signed, and it
# exists to say that the signature may be wrong.
#
# ## Where it writes
#
# The bundle, through `bin/orc-okf-draft.sh --answers` and nothing else. Two
# things that wrote concepts would disagree eventually and nobody could say which
# produced what, so `publish()` stays the only writer and every guarantee it
# carries is inherited rather than restated: `generated:` and no `verified:`, a
# verified concept reported and left alone with no flag that overrules it, a
# second run that is a no-op, and an index listing what is on disk.
#
# It writes nothing to Jira on its own. The one exception is `--nudge`, and it
# is a comment, never a label, an assignee or a duplicate link.
#
# ## Asking again
#
# A comment that lands in `unattributed` - not silence, a reply somebody
# actually wrote, that still matched nothing by number, by position, by being
# the only question, or by reading - is a reply nobody understood, not a reply
# nobody gave. `--nudge` turns the questions still open on that ticket into a
# second question comment, so the reporter gets a chance to answer directly
# instead of the row simply being dropped.
#
# It reuses the machinery a question comment already has rather than inventing
# a second kind of record: the new comment carries the same
# `ORC_COMMENT_MARKER`, an `orderedList` of the still-open questions, and
# `comment_is_ours` treats it exactly like any other question comment - it
# becomes the questions in force, and every existing address rule matches a
# reply to it with no new parsing. What marks it as a *second* ask rather than
# the first is one more field on the marker line, `reask=1`, read the same way
# `prompt=` and `ticket-rev=` are.
#
# Silence is never nudged. A ticket nobody has replied to at all stays in
# `still unanswered`, unchanged - re-pinging silence on a timer is a different
# feature, and not this one. A reply that was understood but only partly, by
# reading, is not nudged either: it answered what it answered, and a reply
# addressing two of three questions has not left the third one unclear, it has
# simply not touched it.
#
# It asks at most once. A round whose own question comment already carries
# `reask=1` is not nudged again, however unclear the next reply still is - it
# is reported instead, under its own heading, because a human has to take it
# from there. There is no flag that overrides that.
#
# ## Why there is no ledger here, and there is one for the gap
#
# `data/gaps.jsonl` exists because `terms_unresolved` lives only in `state/`,
# `state/` is a cache, and a refinement comment carries no term list - so a reset
# loses observations nothing can rebuild. None of that is true here. The
# questions are in a Jira comment and the answers are in Jira comments, and Jira
# is not a cache. Re-running this pass re-derives every row exactly, so a record
# of its own would be a second cache pretending to be a source.
#
# What it does write to `state/` is one file per ticket, for the report to read
# back. Delete it and nothing is lost.
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
ANSWER_CONCEPT="$ORC_ACCUMULATING_ANSWERS"

# Spelled out rather than assembled from $0: bin/orc-check.sh reads the script
# names this repository speaks out of the source, and a name built at run time is
# invisible to it.
SELF="bin/orc-harvest.sh"

# Every command this script prints is a command somebody pastes, so it carries
# the flags the run that printed it was given - otherwise the hint under a
# --key ORC-102 report describes a run over the whole project. HINT_FLAGS and
# hint_flag are in orc-lib.sh, because the rule holds for every script that names
# itself. There is no mode variable here because every command this prints is the
# drafting one: a report is what you get without --draft, so the hint under it can
# only be the run with it.

# \002, for the same reason bin/orc-okf-draft.sh uses it: three of the nine fields
# on a row are empty on an answer that is uncontested and collides with nothing,
# and `IFS=$'\t' read` collapses a run of tabs and shifts every later field left.
#
# The one comment_blocks already uses, rather than a second \002 spelled here. A
# row is built out of block text, so the separator a block arrives under and the
# separator a row is written with have to be the same character - and two
# constants holding it would be two places to change it.
FS2="$COMMENT_BLOCK_FS"

draft=0
nudge=0
quiet=0
as_rows=0
only_key=""

while [ $# -gt 0 ]; do
  case "$1" in
    --draft)   draft=1 ;;
    --nudge)   nudge=1 ;;
    --key)     shift; [ $# -gt 0 ] || orc_die "--key needs an issue key"; only_key="$1"
               hint_flag --key "$1" ;;
    --bundle)  shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1"
               hint_flag --bundle "$1" ;;
    --rows)    as_rows=1; quiet=1 ;;
    --quiet)   quiet=1 ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    -*)        orc_die "unknown option: $1" ;;
    *)         orc_die "unexpected argument: $1" ;;
  esac
  shift
done

WORK=$(mktemp -d) || orc_die "could not create a working directory"
# shellcheck disable=SC2329  # the EXIT trap below is the caller
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

: > "$WORK/rows"             # key FS question FS asked FS answer FS author FS at FS how FS verbatim FS contradicts FS contested FS collision
: > "$WORK/unattributed"     # key FS author FS at FS text
: > "$WORK/unanswered"       # key FS question FS asked
: > "$WORK/collisions"       # key FS term FS concept
: > "$WORK/nudge-candidates" # key FS question FS asked - eligible for a first ask-again
: > "$WORK/already-reasked"  # key FS question FS asked - asked again once already, still unclear
: > "$WORK/decided"         # key FS question FS decision FS answer - already agreed or refused
: > "$WORK/vague"           # key FS question FS author FS text - matched, judged not to resolve anything
: > "$WORK/vague-nudge-candidates" # key FS question FS asked - a deferral, eligible for a first ask-again

# --- addressing ---------------------------------------------------------------

# ref_split <max> <text>
#
# `N FS rest` when the text opens by addressing question N and N is one that was
# asked, nothing otherwise. The bound is what keeps a date, a quantity or a
# version number from reading as an address: on a ticket with three questions
# only 1, 2 and 3 address anything.
#
# The single-letter forms need the digit against them - `q2`, `a2` - while the
# words may be spaced. "A 1 star review" opens a sentence and addresses nothing;
# "Q 2 weeks ago" is the same trap with the other letter.
ref_split() {
  awk -v max="$1" -v fs="$FS2" '
    {
      line = $0
      lower = tolower(line)
      if (match(lower, /^[ \t]*[([]?[0-9][0-9]?[).:][ \t]*/)) tok = substr(line, RSTART, RLENGTH)
      else if (match(lower, /^[ \t]*#[0-9][0-9]?[ \t]*/)) tok = substr(line, RSTART, RLENGTH)
      else if (match(lower, /^[ \t]*(ad|re|question|answer)[ \t]*#?[0-9][0-9]?[).:]?[ \t]+/)) tok = substr(line, RSTART, RLENGTH)
      else if (match(lower, /^[ \t]*[qa]#?[0-9][0-9]?[).:]?[ \t]+/)) tok = substr(line, RSTART, RLENGTH)
      else next
      n = tok
      gsub(/[^0-9]/, "", n)
      if (n + 0 < 1 || n + 0 > max + 0) next
      rest = substr(line, length(tok) + 1)
      sub(/^[ \t]+/, "", rest)
      if (rest == "") next
      print n fs rest
    }' <<< "$2"
}

# read_for_meaning <questions-file> <blocks-file>
#
# The fallback, and the only one of the four rules that reads what a reply
# means rather than how it addresses a question. Reached only when none of the
# three mechanical rules matched and more than one question is open - with one
# question open "the only one" already answered it, mechanically.
#
# Every block's text is split into sentence-sized fragments, each fragment is
# scored against every open question by the folded content words the two sides
# share, and a fragment goes to the question with the strict, unique maximum -
# zero or a tie answers nothing, because a guessed question is worse than none.
# Fragments that land on the same question are joined in the order they were
# written, so `n FS text` comes out at most once per question that got
# anything.
#
# A short stopword list is folded out of both sides before they are compared,
# because "the" and "was" are shared by every sentence in every language this
# reads and would swamp a signal that is supposed to come from the words that
# are actually about something. The list is ORC_CONTENT_STOPWORDS in
# bin/orc-lib.sh rather than a copy of its own: rewrite_uncovered scores a
# statement against a rewrite by exactly this measure, and two copies of the
# list would make two comparisons of the same kind disagree about what a
# content word is.
read_for_meaning() {
  local qfile="$1" blocks="$2"
  awk -F"$FS2" -v fs="$FS2" -v qfile="$qfile" -v stop="$ORC_CONTENT_STOPWORDS" '
    BEGIN {
      while ((getline line < qfile) > 0) { nq++; qk[nq] = foldkeys(line) }
      close(qfile)
      n_sw = split(stop, swlist, " ")
      for (i = 1; i <= n_sw; i++) sw[swlist[i]] = 1
    }
    function foldkeys(s,   t, n, i, arr, out) {
      t = tolower(s)
      gsub(/[^a-z0-9]/, " ", t)
      gsub(/  +/, " ", t)
      sub(/^ /, "", t); sub(/ $/, "", t)
      n = split(t, arr, " ")
      out = ""
      for (i = 1; i <= n; i++) if (length(arr[i]) > 1 && !(arr[i] in sw)) out = out " " arr[i]
      return out
    }
    function overlap(a, b,    na, arra, i, c) {
      na = split(a, arra, " "); c = 0
      for (i = 1; i <= na; i++) if (arra[i] != "" && index(" " b " ", " " arra[i] " ") > 0) c++
      return c
    }
    function best(fragkeys,   bq, bn, tie, i, c) {
      bq = 0; bn = 0; tie = 0
      for (i = 1; i <= nq; i++) {
        c = overlap(fragkeys, qk[i])
        if (c > bn) { bn = c; bq = i; tie = 0 }
        else if (c == bn && c > 0) { tie = 1 }
      }
      if (bn == 0 || tie) return 0
      return bq
    }
    {
      text = $3
      if (text == "") next
      n = split(text, sentences, /[.!?]+ */)
      for (i = 1; i <= n; i++) {
        frag = sentences[i]
        gsub(/^ +| +$/, "", frag)
        if (frag == "") continue
        q = best(foldkeys(frag))
        if (q > 0) {
          if (!(q in seen)) { ans[q] = frag; seen[q] = 1 }
          else ans[q] = ans[q] " " frag
        }
      }
    }
    END {
      for (i = 1; i <= nq; i++) if (i in seen) printf "%d%s%s\n", i, fs, ans[i]
    }' "$blocks"
}

# --- one ticket ---------------------------------------------------------------

# The questions of the question comment currently in force, one per line, and
# when it was asked. Files rather than variables because the walk below reads
# them by line number.
n_tickets=0 n_answers=0 n_contested=0 n_unattributed=0 n_questions=0 n_unanswered=0 n_nudged=0 n_decided=0
n_vague=0 n_contradicted=0

# post_reask <key> <questions-file> <prompt> <ticket-rev>
#
# One new question comment, carrying only the questions still open on this
# round, and marked `reask=1` so a later pass can tell it apart from the first
# ask. `jira_comment_adf` goes through `jira_write`, which previews rather than
# posts unless both write switches are live - --nudge decides whether this is
# reached at all, and the switches decide what happens once it is.
#
# The text is held to the same bar `prompts/refine.md` holds a needs_input
# comment to: no path, no identifier, none of this system's own nouns - the
# audience is the person who wrote the reply that could not be understood, not
# an engineer. The questions themselves need no re-checking: they are quoted
# from a comment that already passed that bar once.
post_reask() {
  local key="$1" qfile="$2" prompt="$3" rev="$4" doc footer qs
  qs=$(cat "$qfile")
  [ -n "$qs" ] || return 0
  doc=$(adf_new)
  doc=$(adf_heading "$doc" 3 "Refinement: still not clear")
  doc=$(adf_para "$doc" "Your last reply didn't make this clear enough to act on. Could you answer directly:")
  doc=$(adf_ordered "$doc" "$qs")
  doc=$(adf_rule "$doc")
  footer="$ORC_COMMENT_MARKER"
  [ -n "$prompt" ] && footer="$footer prompt=$prompt"
  [ -n "$rev" ] && footer="$footer ticket-rev=$rev"
  footer="$footer reask=1"
  doc=$(adf_para_em "$doc" "$footer")
  jira_comment_adf "$key" "$(adf_comment_body "$doc")"
  n_nudged=$(( n_nudged + 1 ))
}

harvest_issue() {
  local key="$1" issue="$2"
  local comment author at nq i q text refs matched ord n_ordered full_verbatim reading contradiction open_n

  : > "$WORK/questions"
  local asked_at=""
  local answered_any=0
  local round_unattributed=0 round_vague=0 round_is_reask="" round_prompt="" round_rev=""
  : > "$WORK/ticket-rows"

  # Read once per ticket and held in a global rather than threaded through every
  # call site between here and answer_contradiction in bin/orc-lib.sh, which
  # reads it back out of $DESCRIPTION_TEXT - plumbing a value four calls deep for
  # its own sake is not what the extra parameter would buy.
  DESCRIPTION_TEXT=$(description_text "$issue")

  while IFS= read -r comment; do
    [ -n "$comment" ] || continue

    if comment_is_ours "$comment"; then
      # A fresh question comment replaces the one in force. Refinement judging
      # the ticket again renumbers, and a reply is numbered against whatever is
      # above it. A reask is a question comment like any other, so this same
      # branch is what makes it the questions in force too - matching a reply
      # to it needs no rule of its own.
      comment_questions "$comment" > "$WORK/questions"
      if [ -s "$WORK/questions" ]; then
        asked_at=$(comment_field "$comment" '.created')
        round_unattributed=0
        round_vague=0
        round_is_reask=$(marker_value "$comment" reask)
        round_prompt=$(marker_value "$comment" prompt)
        round_rev=$(marker_value "$comment" ticket-rev)
      fi
      continue
    fi

    nq=$(grep -c . "$WORK/questions" | tr -d ' ')
    # Nothing has been asked yet, so nothing here is an answer. A comment that
    # predates the question is somebody's own note.
    [ "$nq" -gt 0 ] || continue

    author=$(comment_field "$comment" '.author.displayName')
    [ -n "$author" ] || author="somebody Jira does not name"
    at=$(comment_field "$comment" '.created')

    comment_blocks "$comment" > "$WORK/blocks"
    full_verbatim=$(awk -F"$FS2" '{ print $3 }' "$WORK/blocks" | tr '\n' ' ' | sed 's/ *$//')

    # by number. A block that addresses a question opens that question's answer,
    # and every block after it belongs to that answer until the next block
    # addresses one - the boundary is where the reply itself moves on, which is
    # the only place a rule that never reads meaning can put it.
    #
    # Reading a numbered answer as its opening block alone truncated every reply
    # whose substance was in the paragraphs underneath: a reporter who wrote
    # "3. Here is the wording:" and then three paragraphs of it had all three
    # dropped, and the drafted row looked complete while saying nothing. The
    # whole reply was on the row as `verbatim` the entire time, so the loss was
    # never in the record - only in the extraction.
    #
    # Three boundaries, each decided rather than fallen into:
    #
    #   Before the first address, nothing. A preamble is written before the
    #   reply has addressed anything, so attributing it to the first ordinal
    #   would attribute text to a question the reply had not reached yet - the
    #   same reading that makes a comment posted before any question was asked
    #   not an answer to one. It stays on `verbatim`.
    #   After the last address, everything. A sign-off is part of the run it
    #   was written into, and telling a closing line apart from a final
    #   paragraph of the answer means reading what it means, which this path
    #   never does. The last answer is also the one most likely to carry the
    #   substance, so guessing wrong there costs exactly what this fixed.
    #   Order is the order the reply is written in, never the ordinal's value.
    #   `3.` before `1.` opens each of them where it stands, and a repeated
    #   ordinal is one answer in two pieces, joined in the order written -
    #   the reading read_for_meaning already takes when two fragments land on
    #   one question, and the reading the "one person twice" rule already
    #   takes of somebody adding to what they said.
    #
    # A run only ever extends an answer whose question the reply addressed, so
    # no block can reach a question the reply never touched: a reply numbering
    # 1 and 3 attributes to 1 and 3 and leaves 2 open, exactly as before.
    matched=0
    : > "$WORK/matched"
    : > "$WORK/numbered"
    open_n=""
    while IFS="$FS2" read -r _kind ord text; do
      [ -n "$text" ] || continue
      refs=$(ref_split "$nq" "$text")
      if [ -n "$refs" ]; then
        matched=1
        open_n="${refs%%"$FS2"*}"
        printf '%s%s%s\n' "$open_n" "$FS2" "${refs#*"$FS2"}" >> "$WORK/numbered"
      elif [ -n "$open_n" ]; then
        printf '%s%s%s\n' "$open_n" "$FS2" "$text" >> "$WORK/numbered"
      fi
    done < "$WORK/blocks"
    if [ "$matched" = "1" ]; then
      awk -F"$FS2" -v fs="$FS2" '
        { if (!($1 in ans)) { order[++n] = $1; ans[$1] = $2 }
          else ans[$1] = ans[$1] " " $2 }
        END { for (i = 1; i <= n; i++) printf "%s%sby number%s%s\n", order[i], fs, fs, ans[order[i]] }
      ' "$WORK/numbered" >> "$WORK/matched"
    fi

    # by position: an ordered list of exactly as many items as there were
    # questions. Only when nothing was addressed by number, because a reply that
    # numbers one answer and leaves the rest as prose is not a list of answers.
    if [ "$matched" = "0" ]; then
      n_ordered=$(awk -F"$FS2" '$1 == "ordered" { c++ } END { print c + 0 }' "$WORK/blocks")
      if [ "$n_ordered" = "$nq" ]; then
        matched=1
        while IFS="$FS2" read -r _kind ord text; do
          [ "$_kind" = "ordered" ] || continue
          printf '%s%sby position%s%s\n' "$ord" "$FS2" "$FS2" "$text" >> "$WORK/matched"
        done < "$WORK/blocks"
      fi
    fi

    # the only one
    if [ "$matched" = "0" ] && [ "$nq" = "1" ]; then
      if [ -n "$full_verbatim" ]; then
        matched=1
        printf '1%sthe only question%s%s\n' "$FS2" "$FS2" "$full_verbatim" >> "$WORK/matched"
      fi
    fi

    # by reading: the fallback, and the only rule that reads what the reply
    # means. Reached only past the three mechanical rules above, and only when
    # more than one question is open - with exactly one open, "the only one"
    # already settled it without reading anything.
    if [ "$matched" = "0" ] && [ "$nq" -gt "1" ]; then
      reading=$(read_for_meaning "$WORK/questions" "$WORK/blocks")
      if [ -n "$reading" ]; then
        matched=1
        while IFS="$FS2" read -r i text; do
          [ -n "$text" ] || continue
          printf '%s%sby reading%s%s\n' "$i" "$FS2" "$FS2" "$text" >> "$WORK/matched"
        done <<< "$reading"
      fi
    fi

    if [ "$matched" = "0" ]; then
      [ -n "$full_verbatim" ] || continue
      printf '%s%s%s%s%s%s%s\n' "$key" "$FS2" "$author" "$FS2" "$at" "$FS2" "$full_verbatim" >> "$WORK/unattributed"
      n_unattributed=$(( n_unattributed + 1 ))
      round_unattributed=1
      continue
    fi

    while IFS="$FS2" read -r i how text; do
      [ -n "$text" ] || continue
      q=$(sed -n "${i}p" "$WORK/questions")
      [ -n "$q" ] || continue
      # A row somebody has already decided about is not proposed again. Agreed,
      # the fact has been promoted out of the drafted concept and into a file a
      # person owns, so re-drafting it would put two answers to one question in
      # one bundle; refused, it would be proposed on every run for ever, which
      # is what makes a review queue something an operator stops opening.
      #
      # Keyed on this answer's own words rather than on the question, so a
      # *different* answer to the same question is a new proposal and is offered.
      decided=$(decision_for answer "$(answer_subject_key "$key" "$q")" \
                "$(printf '%s' "$text" | _terms_fold)")
      if [ -n "$decided" ]; then
        printf '%s%s%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$decided" "$FS2" "$text" \
          >> "$WORK/decided"
        n_decided=$(( n_decided + 1 ))
        continue
      fi
      # Matched to a question is not the same claim as resolving it. A reply
      # that hands the decision back - "whatever's easiest for engineering" -
      # is not drafted as an answer: the question it was matched to stays open,
      # and it feeds the same asking-again machinery an unaddressed reply does.
      # See ORC_DEFERRAL_PHRASE in bin/orc-lib.sh for what this catches and why.
      #
      # $text is the whole answer, so this reads every paragraph of a numbered
      # one rather than the line the number was on - the gate judges exactly the
      # string the row would carry, which is the only scope that stays honest
      # now that a run's later paragraphs reach the row.
      if answer_is_deferring "$text"; then
        printf '%s%s%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$author" "$FS2" "$text" \
          >> "$WORK/vague"
        n_vague=$(( n_vague + 1 ))
        round_vague=1
        continue
      fi
      # A candidate disagreement with the description or an earlier signed
      # answer on this ticket - a note that travels on the row rather than
      # something decided here. See answer_contradiction in bin/orc-lib.sh.
      contradiction=$(answer_contradiction "$key" "$q" "$text" || true)
      [ -n "$contradiction" ] && n_contradicted=$(( n_contradicted + 1 ))
      printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
        "$key" "$FS2" "$q" "$FS2" "$asked_at" "$FS2" "$text" "$FS2" "$author" "$FS2" "$at" "$FS2" "$how" "$FS2" "$full_verbatim" "$FS2" "$contradiction" \
        >> "$WORK/ticket-rows"
      answered_any=1
      n_answers=$(( n_answers + 1 ))
    done < "$WORK/matched"
  done <<< "$(issue_comments "$issue")"

  nq=$(grep -c . "$WORK/questions" | tr -d ' ')
  n_questions=$(( n_questions + nq ))
  i=1
  : > "$WORK/round-unclear"
  while [ "$i" -le "$nq" ]; do
    q=$(sed -n "${i}p" "$WORK/questions")
    # A question whose only answer was decided about is answered, not silent.
    # Reported as unanswered it would read as a reporter who never replied, and
    # somebody would go and ask them again for something already signed.
    if ! awk -F"$FS2" -v q="$q" '$2 == q { found = 1 } END { exit !found }' "$WORK/ticket-rows" \
       && ! awk -F"$FS2" -v k="$key" -v q="$q" '$1 == k && $2 == q { found = 1 } END { exit !found }' "$WORK/decided"; then
      # A question whose only reply was judged deferring is not silence either:
      # somebody wrote something, it stays open, and it goes into round-unclear
      # like anything else that is not settled - but it is not reported as
      # "nobody replied", because somebody did.
      if ! awk -F"$FS2" -v k="$key" -v q="$q" '$1 == k && $2 == q { found = 1 } END { exit !found }' "$WORK/vague"; then
        printf '%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$asked_at" >> "$WORK/unanswered"
        n_unanswered=$(( n_unanswered + 1 ))
      fi
      printf '%s\n' "$q" >> "$WORK/round-unclear"
    fi
    i=$(( i + 1 ))
  done

  # Asking again is for a reply nobody understood, or one that was understood
  # and still decided nothing - never for silence, and never for a reply that
  # was understood and resolved only part of what was asked. All three leave a
  # question in round-unclear; round_unattributed and round_vague are what tell
  # them apart from a partial reading-matched reply, which leaves one too.
  if [ -s "$WORK/round-unclear" ] && { [ "$round_unattributed" = "1" ] || [ "$round_vague" = "1" ]; }; then
    if [ "$round_is_reask" = "1" ]; then
      while IFS= read -r q; do
        [ -n "$q" ] || continue
        printf '%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$asked_at" >> "$WORK/already-reasked"
      done < "$WORK/round-unclear"
    else
      # Reported separately by cause, because the two are not the same claim:
      # "nobody could understand this" is wrong to say about a reply that was
      # perfectly clear and simply decided nothing.
      while IFS= read -r q; do
        [ -n "$q" ] || continue
        if [ "$round_unattributed" = "1" ]; then
          printf '%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$asked_at" >> "$WORK/nudge-candidates"
        fi
        if [ "$round_vague" = "1" ]; then
          printf '%s%s%s%s%s\n' "$key" "$FS2" "$q" "$FS2" "$asked_at" >> "$WORK/vague-nudge-candidates"
        fi
      done < "$WORK/round-unclear"
      [ "$nudge" = "1" ] && post_reask "$key" "$WORK/round-unclear" "$round_prompt" "$round_rev"
    fi
  fi

  [ "$answered_any" = "1" ] || return 0
  n_tickets=$(( n_tickets + 1 ))
  ticket_collisions "$key"
  finish_ticket_rows "$key"
}

# --- what a verified concept already claims -----------------------------------

# The concepts a human has signed, as one folded string each, computed once.
# bundle_verified_folded is in orc-lib.sh, because bin/orc-verify.sh asks the
# same question of the same files - what does a signed concept already say about
# this - and two readers of that would eventually disagree about one concept.
bundle_verified_folded "$BUNDLE" > "$WORK/verified"

# The words refinement looked up on this ticket and could not answer, from the
# durable ledger and from whatever state/ currently holds. Both, because the
# ledger survives a reset and state/ holds the run nobody has recorded yet.
unresolved_terms() {
  local key="$1"
  {
    [ -f "$GAP_LEDGER" ] && jq -rR --arg k "$key" \
      'fromjson? | select(type == "object") | select((.key // "") == $k)
       | (.terms_unresolved // [])[]' "$GAP_LEDGER" 2>/dev/null
    [ -f "$STATE_DIR/$key.verdict.json" ] && jq -r '(.terms_unresolved // [])[]' \
      "$STATE_DIR/$key.verdict.json" 2>/dev/null
  } | sort -u
}

ticket_collisions() {
  local key="$1" term folded rel text
  [ -s "$WORK/verified" ] || return 0
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    folded=$(printf '%s' "$term" | _terms_fold)
    [ -n "$folded" ] || continue
    while IFS=$'\t' read -r rel text; do
      [ -n "$rel" ] || continue
      orc_folded_says "$text" "$folded" || continue
      printf '%s%s%s%s%s\n' "$key" "$FS2" "$term" "$FS2" "$rel" >> "$WORK/collisions"
    done < "$WORK/verified"
  done <<< "$(unresolved_terms "$key")"
}

# --- contested, and the finished rows -----------------------------------------

# A question is contested when two different people answered it and did not say
# the same thing. Two answers from one person are a correction or an addition,
# and calling that a disagreement would put a banner on somebody thinking out
# loud.
finish_ticket_rows() {
  local key="$1" q contested collision
  [ -s "$WORK/ticket-rows" ] || return 0
  collision=$(awk -F"$FS2" -v k="$key" '$1 == k { print $3 }' "$WORK/collisions" \
              | sort -u | tr '\n' ' ' | sed 's/ *$//')
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    contested=""
    if awk -F"$FS2" -v q="$q" '
         $2 == q {
           if (!($5 in who))          { who[$5] = 1;          nwho++ }
           if (!(tolower($4) in said)) { said[tolower($4)] = 1; nsaid++ }
         }
         END { exit !(nwho > 1 && nsaid > 1) }' "$WORK/ticket-rows"; then
      contested="yes"
      n_contested=$(( n_contested + 1 ))
    fi
    awk -F"$FS2" -v q="$q" -v c="$contested" -v col="$collision" -v fs="$FS2" \
      '$2 == q { print $0 fs c fs col }' "$WORK/ticket-rows" >> "$WORK/rows"
  done <<< "$(awk -F"$FS2" '{ print $2 }' "$WORK/ticket-rows" | awk '!seen[$0]++')"

  mkdir -p "$STATE_DIR"
  awk -F"$FS2" -v k="$key" '$1 == k' "$WORK/rows" \
    | jq -Rs --arg k "$key" 'split("\n") | map(select(length > 0) | split("")
        | {question: .[1], asked_at: .[2], answer: .[3], author: .[4], answered_at: .[5],
           matched_by: .[6], verbatim: .[7], contradicts: .[8], contested: (.[9] == "yes"), collides_with: .[10]})
      | {key: $k, answers: .}' > "$STATE_DIR/$key.answers.json"
}

# --- the tickets ---------------------------------------------------------------
#
# The whole project, the way bin/orc-reconcile.sh reads it, and deliberately not
# gated on LABEL_OPT_IN. The gate is about intake - which cards this system is
# allowed to judge - and every question read here was asked by a run that had
# already passed it.

if [ -n "$only_key" ]; then
  keys="$only_key"
else
  issues=$(jira_search_all "search/project-issues" \
    "project = $JIRA_PROJECT ORDER BY updated ASC" updated 100) \
    || orc_die "could not list the issues in $JIRA_PROJECT"
  keys=$(printf '%s' "$issues" | jq -r '.key')
fi

[ -n "$keys" ] || { log "no issues found in project $JIRA_PROJECT; nothing to harvest"; exit 0; }

n_read=0
for key in $keys; do
  issue=$(jira_read "/issue/$key?fields=summary,description,labels,updated,comment") || continue
  n_read=$(( n_read + 1 ))
  harvest_issue "$key" "$issue"
done

n_rows=$(grep -c . "$WORK/rows" | tr -d ' ')

if [ "$as_rows" = "1" ]; then
  cat "$WORK/rows"
  [ "$n_rows" = "0" ] && exit 0
  exit 1
fi

# --- report --------------------------------------------------------------------

printf '\n  answers harvested: %s to %s, from %s of %s ticket(s) read\n' \
  "$(plural "$n_answers" "answer" "answers")" \
  "$(plural "$n_questions" "question" "questions")" "$n_tickets" "$n_read"

if [ "$n_rows" = "0" ]; then
  say "Nobody has answered a question refinement asked. That is the ordinary state of a board nobody has been through yet, rather than a failure here."
else
  [ "$quiet" = "1" ] || say "Every answer below is quoted as it was written, under the question it was given for."
  # Nothing here is truncated, and the question is why the shape is what it is:
  # a question is a sentence and a column padded to the longest one would be
  # either cut or 120 characters wide. So the question is a line and its answers
  # are indented under it.
  awk -F"$FS2" '
    { key = $1; q = $2 }
    (key SUBSEP q) != last {
      printf "\n  %s  %s\n", key, q
      last = key SUBSEP q
    }
    {
      at = $6; sub(/T.*$/, "", at)
      note = ""
      if ($9 != "") note = "  -  disagrees with what is already known, see below"
      if ($10 == "yes") note = "  -  answered differently by two people"
      printf "    %-20s %-11s %s  [%s]%s\n", $5, at, $4, $7, note
    }' "$WORK/rows"
fi

if [ "$n_unanswered" != "0" ]; then
  step "still unanswered"
  say "$(plural "$n_unanswered" "question" "questions") nobody has replied to. This is a report and not a nudge: nothing here writes to Jira."
  gap
  awk -F"$FS2" '{ printf "  %-10s %s\n", $1, $2 }' "$WORK/unanswered"
fi

if [ "$n_unattributed" != "0" ]; then
  step "read, and deliberately not attributed"
  say "$(plural "$n_unattributed" "comment" "comments") came after a question and addressed none of them by number, by position, by being the only one there was, or by any word it shared with one."
  [ "$quiet" = "1" ] || say "Attributing them would mean guessing what they are about, and a row whose question is a guess is worse than no row. Ask the person to answer with the number, or answer it into the bundle by hand."
  gap
  awk -F"$FS2" '{
    at = $3; sub(/T.*$/, "", at)
    printf "  %s  %s, %s\n    %s\n", $1, $2, at, $4
  }' "$WORK/unattributed"
fi

if [ "$n_vague" != "0" ]; then
  step "answered, but nothing was decided"
  say "$(plural "$n_vague" "reply" "replies") addressed a question directly and settled nothing - a deferral rather than an answer. Not drafted: the question stays open."
  gap
  awk -F"$FS2" '{ printf "  %s  %s\n    %s: %s\n", $1, $2, $3, $4 }' "$WORK/vague"
fi

n_nudge_candidates=$(grep -c . "$WORK/nudge-candidates" | tr -d ' ')
if [ "$n_nudge_candidates" != "0" ]; then
  if [ "$nudge" = "1" ]; then
    step "asked again"
    say "$(plural "$n_nudged" "ticket" "tickets") got a new comment naming the question(s) a reply did not make clear."
  else
    step "a reply nobody could understand"
    say "$(plural "$n_nudge_candidates" "question" "questions") got a reply that addressed none of them, by any rule. Run with --nudge to ask again."
  fi
  gap
  awk -F"$FS2" '{ printf "  %-10s %s\n", $1, $2 }' "$WORK/nudge-candidates"
fi

n_vague_nudge_candidates=$(grep -c . "$WORK/vague-nudge-candidates" | tr -d ' ')
if [ "$n_vague_nudge_candidates" != "0" ]; then
  if [ "$nudge" = "1" ]; then
    step "asked again, for a deferral"
    say "$(plural "$n_vague_nudge_candidates" "question" "questions") whose only reply deferred also got a new comment naming them."
  else
    step "a reply that did not settle anything"
    say "$(plural "$n_vague_nudge_candidates" "question" "questions") got a reply that addressed them and decided nothing. Run with --nudge to ask again."
  fi
  gap
  awk -F"$FS2" '{ printf "  %-10s %s\n", $1, $2 }' "$WORK/vague-nudge-candidates"
fi

n_already_reasked=$(grep -c . "$WORK/already-reasked" | tr -d ' ')
if [ "$n_already_reasked" != "0" ]; then
  step "asked again once, still not clear"
  say "$(plural "$n_already_reasked" "question" "questions") already got a second question comment and the reply after it still did not settle them. This is not asked a third time; it needs a person."
  gap
  awk -F"$FS2" '{ printf "  %-10s %s\n", $1, $2 }' "$WORK/already-reasked"
fi

if [ "$n_contested" != "0" ]; then
  step "answered twice, differently"
  say "$(plural "$n_contested" "question" "questions") got answers from more than one person that do not say the same thing. Every answer is kept and the row says it is contested; nothing here picks one."
  gap
  awk -F"$FS2" '
    $10 == "yes" {
      if (($1 SUBSEP $2) != last) { printf "  %s  %s\n", $1, $2; last = $1 SUBSEP $2 }
      printf "    %s: %s\n", $5, $4
    }' "$WORK/rows"
fi

if [ "$n_contradicted" != "0" ]; then
  step "disagrees with what is already known"
  say "$(plural "$n_contradicted" "answer" "answers") name a figure that conflicts with the ticket's own description or with an answer already signed on this ticket. Nothing here decides which is right - the note travels on the row, and bin/orc-verify.sh shows it before anybody signs."
  gap
  awk -F"$FS2" '$9 != "" { printf "  %s  %s\n    \"%s\" conflicts with %s.\n", $1, $2, $4, $9 }' "$WORK/rows"
fi

if [ "$n_decided" != "0" ]; then
  step "already decided, so not proposed again"
  say "$(plural "$n_decided" "answer" "answers") a person has already agreed to or refused. An agreed answer has been promoted into a file this system never drafts, and proposing it here as well would put two answers to one question in one bundle; a refused one would come back on every run."
  say "Keyed on the answer's own words, so somebody else answering the same question differently is still proposed."
  gap
  awk -F"$FS2" '{ printf "  %-10s %-7s %s\n    %s\n", $1, $3, $2, $4 }' "$WORK/decided"
fi

n_collisions=$(sort -u "$WORK/collisions" | grep -c . | tr -d ' ')
if [ "$n_collisions" != "0" ]; then
  gap
  banner "A PERSON ANSWERED SOMETHING A VERIFIED CONCEPT ALREADY CLAIMS

$(sort -u "$WORK/collisions" | awk -F"$FS2" '{ printf "  %s: \"%s\" is said by %s\n", $1, $2, $3 }')

Refinement looked those words up on those tickets, could not resolve them, and asked a person - while a concept somebody signed off says them. Either that verified fact is stale, or refinement could not find it. Those have different fixes and this is the only place either one is visible.

Nothing is changed on either side. A concept a human verified is theirs, here as everywhere, and the answer is drafted with the collision named on its row so whoever reviews it sees both at once."
fi

# --- the proposal, drafted by the one thing that drafts -------------------------

rc=0
if [ "$n_rows" = "0" ]; then
  gap
  say "Nothing is proposed, so no concept is drafted."
else
  step "the proposal"
  say "$(plural "$n_rows" "row" "rows"). $(basename "$DRAFTER") drafts the concept, because it is the only thing in this repository that writes one:"
  gap
  if [ "$draft" = "1" ]; then
    "$DRAFTER" --answers "$WORK/rows" --bundle "$BUNDLE" --quiet || rc=$?
  else
    # The drift line names this run's command rather than the drafter's own,
    # because only the caller knows the flags it was given. A --key run told to
    # run the drafter would reproduce neither.
    "$DRAFTER" --answers "$WORK/rows" --bundle "$BUNDLE" --check --quiet \
      --drift-command "$SELF --draft$HINT_FLAGS" || rc=$?
    gap
    say "Nothing was written into $BUNDLE. To draft it:"
    gap
    say "  $SELF --draft$HINT_FLAGS"
  fi
fi

# Only when there is something to say it about. A run that harvested nothing
# printing a paragraph about what a row would have carried is a banner an
# operator learns to scroll past, and then the one that mattered goes with it.
[ "$n_rows" = "0" ] || [ "$quiet" = "1" ] || banner "AN ANSWERED QUESTION IS STILL NOT A VERIFIED FACT

$ANSWER_CONCEPT carries \`generated:\` and no \`verified:\`, and it must. A person answering a question about their own ticket has told you what is true of that ticket; they have not read the concept and they have not said it is true of the product. Those are different claims, and the bundle only promotes a phrase two repositories say - one person saying something once is weaker evidence than that, not stronger.

What the row is for is that the human sign-off now starts from a proposed answer with a name and a date on it rather than from a blank question. Put a \`verified:\` date on it when somebody has read the concept and agrees with it, and not before.

Nothing here writes to Jira, and re-running rebuilds every row from the comments, so there is no ledger to keep and nothing to lose."

[ "$n_rows" = "0" ] || exit 1
exit "$rc"
