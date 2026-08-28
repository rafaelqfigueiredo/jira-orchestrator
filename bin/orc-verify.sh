#!/usr/bin/env bash
# The review queue: what is waiting for somebody to say it is true, and the two
# ways of saying so.
#
#   orc-verify.sh queue                  what awaits a decision, newest first
#   orc-verify.sh queue --decided        what has already been decided, and by whom
#   orc-verify.sh show N                 one item in full, with what the bundle
#                                        already claims about the same subject
#   orc-verify.sh verify N --agree       sign it as it stands
#   orc-verify.sh verify N --as "TEXT"   sign it, in your own words
#   orc-verify.sh verify N --edit        sign it, after editing it in $EDITOR
#   orc-verify.sh reject N --reason "…"  refuse it, and record why
#   orc-verify.sh render                 rebuild the signed files from the ledger
#
#   --by WHO      whose signature this is (default: your git email)
#   --yes         answer the confirmation, for a scripted run
#   --bundle DIR  read and write DIR instead of .okf
#
# N is a position in the queue, or the eight-character id printed beside it. The
# id is what a script should use: a position moves when the queue moves. An id
# out of `queue --decided` still resolves, which is how a decision is taken back.
#
# ## Why this exists at all
#
# Every fact in the bundle is either drafted or signed, and `prompts/refine.md`
# tells refinement to quote a signed one and to treat a drafted one as a lead to
# confirm. That makes the signature the single act the whole knowledge model
# rests on - and until this existed, performing it meant opening a markdown file,
# understanding OKF frontmatter and hand-editing a block. The one step everything
# else depends on was the most confusing step in the system, which makes it a
# bottleneck on the entire loop rather than a detail of it.
#
# ## Nothing is signed that was not displayed
#
# `verify` prints the whole record - the ticket, the question, the reply word for
# word, what would be written, who said it and when - and then asks. There is no
# flag that skips the display. `--yes` answers the question; it does not remove
# it, and the record is printed either way.
#
# A sign-off that does not show what is being signed is theatre, and a queue that
# let you sign by number alone would be exactly that: one stale index away from
# putting somebody's name on a fact they never read.
#
# ## Two granularities, because there are two kinds of file
#
# A concept file is signed whole, exactly as it always was: `verified:` goes into
# its frontmatter and bin/orc-okf-draft.sh then refuses to re-draft it. That is
# the right meaning for a file rendered from the repositories - signing it says
# "this is mine now", and freezing it is the point rather than a side effect.
#
# An accumulating file cannot be signed that way. domain/open-vocabulary.md grows
# a row whenever refinement fails to resolve a word, and domain/reporter-answers.md
# grows one whenever somebody answers a question. A `verified:` date on either
# would freeze the one file in the bundle whose whole job is to keep growing: the
# drafter would report it SKIPPED for ever while real answers piled up outside it.
#
# So a fact inside an accumulating file is signed by *promotion*. Agreeing moves
# it out into a file this system never drafts - domain/verified-answers.md or
# domain/verified-vocabulary.md - and the row it came from stops being proposed.
# The drafter is not taught anything: its no-overwrite guarantee stays a simple
# whole-file rule, and "verify" is a move rather than an edit in place. Teaching
# it to merge a person's rows into a machine's table is the one shape that would
# put a human and a machine editing the same file, which is how a bundle ends up
# holding two answers to one question with nothing to say which was meant.
#
# Signing one of the two accumulating files whole is refused, and the refusal
# names the per-fact path. There is no flag that overrules it.
#
# ## A refusal is as much a decision as an agreement
#
# It has to be recorded, and it is the half with nowhere else to live: agreeing
# leaves a promoted row behind, while refusing leaves nothing at all - and
# without a record the harvest would propose the identical answer on every run
# for ever, which is how a review queue becomes something nobody opens.
#
# So both go to data/verifications.jsonl, one append-only line each, outside the
# caches for the same reason data/gaps.jsonl is: refining again re-reads the
# tickets and drafting again re-reads the repositories, and nothing re-reads
# somebody's judgement. Commit it - it is the only copy.
#
# A refused answer is keyed on that answer's own words, so somebody else
# answering the same question differently is still proposed. A refused *word* is
# keyed on the word alone, because refusing a word is a judgement about the word
# rather than about whichever sentence the evidence currently produces for it.
#
# Deciding again appends, and the reader takes the last line - so a decision is
# reversible without the ledger ever being rewritten, and `queue --decided`
# followed by `verify <id>` is the way back.
#
# ## What agreeing may not do
#
# A word cannot be agreed to bare. The drafted row says what the repositories say
# *about* a word, which is a weaker and different claim from what the word means,
# so signing it unchanged would file the evidence as the definition. `--as` or
# `--edit` is required there, and the queue says so on the row rather than in a
# document somebody has to go and find.
#
# An answer can, because the proposal is already a person's own words and
# promoting the quotation verbatim is the honest thing to do with it.
#
# ## Where the queue comes from
#
# Answers from state/<key>.answers.json, which bin/orc-harvest.sh writes in the
# same pass that drafts the concept, so what is offered here and what the bundle
# says come out of one reading rather than two. Words from the drafted table in
# domain/open-vocabulary.md, with the tickets that used each one read out of the
# gap ledger. Concepts from the bundle itself: a `.md` file with no `verified:`.
#
# state/ is a cache, so an answer row can be in the bundle with no record behind
# it. That is named rather than guessed at: re-running the harvest rebuilds every
# row exactly.
#
# Exit codes: 0 nothing awaits a decision, 1 something does. `queue` also prints
# an advisory list of verified concepts whose signature is older than
# ORC_VERIFY_STALE_DAYS - see print_aged_signatures. It is out of that
# accounting on purpose: those concepts are already decided, so they move
# neither the counts nor the exit status, and a finished bundle still exits 0.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd awk sort

BUNDLE="$BUNDLE_DIR"

# Spelled out rather than assembled from $0: bin/orc-check.sh reads the script
# names this repository speaks out of the source, and a name built at run time is
# invisible to it.
SELF="bin/orc-verify.sh"

# The region of an index.md this script owns, and nothing else in the file. Same
# rule the drafter's region follows: an index is a human's file, and a machine
# that rewrote it whole would discard prose for the sake of a listing.
VERIFY_BEGIN='<!-- BEGIN verified by bin/orc-verify.sh -->'
VERIFY_END='<!-- END verified by bin/orc-verify.sh -->'

# \002 between the fields of an item and \001 inside one, the same separators the
# harvest and the drafter use: six of the thirteen fields are empty for one kind
# of item or another, and `IFS=$'\t' read` collapses a run of tabs and shifts
# every later field left.
FS=$'\002'
NFS=$'\001'

cmd=""
by=""
assume_yes=0
show_decided=0
agree=0
do_edit=0
as_text=""
reason=""
target=""
have_as=0

while [ $# -gt 0 ]; do
  case "$1" in
    queue|show|verify|reject|render)
      [ -z "$cmd" ] || orc_die "one command at a time (already have '$cmd', then '$1')"
      cmd="$1" ;;
    --decided)  show_decided=1 ;;
    --agree)    agree=1 ;;
    --edit)     do_edit=1 ;;
    --as)       shift; [ $# -gt 0 ] || orc_die "--as needs the text to sign"; as_text="$1"; have_as=1 ;;
    --reason)   shift; [ $# -gt 0 ] || orc_die "--reason needs a sentence"; reason="$1" ;;
    --by)       shift; [ $# -gt 0 ] || orc_die "--by needs a name"; by="$1" ;;
    --yes)      assume_yes=1 ;;
    --bundle)   shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1"
                hint_flag --bundle "$1" ;;
    -h|--help)  orc_usage "$0"; exit 0 ;;
    -*)         orc_die "unknown option: $1" ;;
    *)          [ -z "$target" ] || orc_die "unexpected argument: $1"; target="$1" ;;
  esac
  shift
done

[ -n "$cmd" ] || cmd="queue"

case "$cmd" in
  show|verify|reject) [ -n "$target" ] || orc_die "$cmd needs the number or the id of a queue item" ;;
esac

# Whose signature this is. From git rather than from $USER, because a signature
# has to name somebody a later reader could go and ask, and the email in a
# repository's own config is the identity every commit in it already carries.
#
# Never invented: with no git identity and no --by the run stops, the same way
# `ask` stops when there is nobody on stdin. A fact attributed to nobody in
# particular is worse than an unsigned one, because it reads as checked and
# leaves nobody to ask about it.
if [ -z "$by" ]; then
  by=$(git -C "$ORC_ROOT" config user.email 2>/dev/null)
fi
case "$cmd" in
  verify|reject)
    [ -n "$by" ] || orc_die "nobody to attribute this decision to: set git config user.email, or pass --by"
    case "$by" in
      *[[:space:]]*) orc_die "--by is an identity rather than a sentence, so it may not hold a space (got '$by')" ;;
    esac
    case "$by" in *:*) : ;; *) by="person:$by" ;; esac
  ;;
esac

WORK=$(mktemp -d) || orc_die "could not create a working directory"
# shellcheck disable=SC2329  # the EXIT trap below is the caller
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

# A signature carries a date and not a time. It says which day somebody read a
# fact, which is the honest resolution for a human act; the ledger keeps the full
# instant, because that is what orders two decisions about one subject.
signed_today() { date -u +%F; }

# How many verified concepts still count as fresh. A signature past this is only
# ever reported, never acted on: see print_aged_signatures. Validated where it
# is read rather than trusted, because a non-number would silently disable the
# section the way a bad label silently rewrites a JQL.
STALE_DAYS="${ORC_VERIFY_STALE_DAYS:-180}"

# Whole days between an ISO date and now, or nothing when the date cannot be
# read. Only the date part is used: a signature is a day, and the offset on a
# longer timestamp is not worth parsing for a threshold measured in months. BSD
# and GNU date spell the parse incompatibly and neither takes the other's
# flags, so both are tried; BSD's -f fills missing time fields from the current
# clock, so the time is pinned to midnight explicitly.
days_since() {
  local d="${1%%T*}" ep now
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  ep=$(date -j -u -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null) \
    || ep=$(date -u -d "$d" +%s 2>/dev/null) \
    || return 1
  now=$(orc_epoch)
  printf '%s' "$(( (now - ep) / 86400 ))"
}

# A round phrase for a day count. The aged-signature section is about months and
# years, and the exact day is in nobody's decision there.
humanize_days() {
  if [ "$1" -ge 365 ]; then
    printf '%s year(s) ago' "$(( $1 / 365 ))"
  else
    printf '%s month(s) ago' "$(( $1 / 30 ))"
  fi
}

# Repository-relative when the ledger is inside this checkout, absolute when a
# run pointed elsewhere - either way a path, and a path has no space in it, which
# is what separates an address from a sentence about one.
ledger_resource() {
  case "$VERIFY_LEDGER" in
    "$ORC_ROOT"/*) printf '%s' "${VERIFY_LEDGER#"$ORC_ROOT"/}" ;;
    *)             printf '%s' "$VERIFY_LEDGER" ;;
  esac
}

md_cell() { printf '%s' "$1" | sed -e 's/|/\\|/g'; }
yaml_scalar() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

# --- one labelled field, wrapped ------------------------------------------

# `label` then the value, wrapped at 76 columns with the continuation lined up
# under the value rather than under the label.
#
# Wrapped rather than left to the terminal, because what a reviewer is reading
# here is prose - a question, a sentence somebody typed into a comment, a
# paragraph saying what agreeing will do - and a terminal breaking that mid-word
# at column 80 is exactly the thing that makes somebody stop reading and sign by
# number instead. Nothing is truncated: a long value gets more lines.
labelled() {
  local pad="$1" label="$2" text="$3"
  [ -n "$text" ] || return 0
  printf '%s' "$text" | awk -v pad="$pad" -v label="$label" -v w=76 '
    BEGIN { lead = sprintf("%s%-10s ", pad, label); cont = sprintf("%s%-10s ", pad, "") }
    {
      n = split($0, word, " ")
      out = ""
      for (i = 1; i <= n; i++) {
        cand = (out == "" ? word[i] : out " " word[i])
        if (length(cand) + length(lead) <= w) { out = cand; continue }
        print (shown ? cont : lead) out; shown = 1
        out = word[i]
      }
      if (out != "") { print (shown ? cont : lead) out; shown = 1 }
    }'
}

# Every note on an item, each one wrapped under the same label.
notes_of() {
  local pad="$1" notes="$2" n
  [ -n "$notes" ] || return 0
  printf '%s\n' "$notes" | tr "$NFS" '\n' | while IFS= read -r n; do
    [ -n "$n" ] || continue
    labelled "$pad" note "$n"
  done
}

# --- the items ---------------------------------------------------------------
#
# One record per thing a person could decide about, in one shape whatever it came
# from, so the queue, the display and the two write paths read the same thirteen
# fields rather than each knowing about three kinds of item.
#
#   1 kind  2 id  3 at  4 subject key  5 proposal fold  6 ticket  7 subject
#   8 proposal  9 who  10 how  11 notes  12 bundle path  13 the whole reply
#   14 when it was asked

item() {
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$1" "$FS" "$2" "$FS" "$3" "$FS" "$4" "$FS" "$5" "$FS" "$6" "$FS" \
    "$7" "$FS" "$8" "$FS" "$9" "$FS" "${10}" "$FS" "${11}" "$FS" "${12}" "$FS" \
    "${13}" "$FS" "${14}"
}

# One field of an item, by position. A queue line carries the position in front,
# so every reader below is one past the numbering in the comment above.
field() { printf '%s' "$1" | awk -F"$FS" -v n="$2" '{ print $n; exit }'; }

: > "$WORK/items"
n_no_record=0

# Answers, from what the harvest read out of the comments. One item per *answer*
# rather than per question: two people who disagree are two decisions, and
# agreeing with one of them may not quietly settle the other.
collect_answers() {
  local f key q asked ans who at how verb contradicts contested collides
  local skey pfold id notes
  for f in "$STATE_DIR"/*.answers.json; do
    [ -e "$f" ] || continue
    while IFS="$FS" read -r key q asked ans who at how verb contradicts contested collides; do
      [ -n "$q" ] || continue
      skey=$(answer_subject_key "$key" "$q")
      pfold=$(printf '%s' "$ans" | _terms_fold)
      [ -z "$(decision_for answer "$skey" "$pfold")" ] || continue
      id=$(decision_id answer "$skey" "$pfold")
      notes=""
      # The loudest note on the row, and it goes first: a contradiction is
      # worse than a gap, because a gap announces itself and this hides inside
      # something that otherwise reads as an ordinary answer. Nothing here
      # decides which side is right - the same rule two disagreeing people get.
      if [ -n "$contradicts" ]; then
        notes="This answer conflicts with $contradicts. Nothing here decides which is right; that is what this review is for."
      fi
      [ "$contested" != "yes" ] || notes="$notes${notes:+$NFS}Somebody else answered this same question differently. Both are in this queue, and agreeing with one does not settle the other."
      if [ -n "$collides" ]; then
        notes="$notes${notes:+$NFS}A concept somebody already signed speaks to a word refinement could not resolve on this ticket ($collides). Either that signature is stale or refinement could not find it."
      fi
      if [ "$how" = "by reading" ]; then
        notes="$notes${notes:+$NFS}matched by reading the reply, not by a number the reporter wrote - the weakest of the four rules, and the only one that can put a sentence under the wrong question. show prints the whole reply to check it against."
      fi
      item answer "$id" "$at" "$skey" "$pfold" "$key" "$q" "$ans" "$who" "$how" "$notes" "" "$verb" "$asked" \
        >> "$WORK/items"
    done <<< "$(jq -r --arg fs "$FS" '.key as $k | (.answers // [])[]
      | [ $k, .question, (.asked_at // ""), .answer, (.author // ""), (.answered_at // ""),
          (.matched_by // ""), (.verbatim // ""), (.contradicts // ""),
          (if .contested then "yes" else "" end), (.collides_with // "") ] | join($fs)' "$f" 2>/dev/null)"
  done
}

# The words the gap loop proposed and the drafter rendered, read out of the table
# it rendered them into - because that table is what a reviewer is being asked to
# sign, and re-deriving the row would mean re-reading every repository.
#
# `\|` is how the drafter escapes a pipe inside a cell, so it is put out of the
# way before the row is split and put back afterwards. A cell holding a raw pipe
# would otherwise become two columns.
vocabulary_rows() {
  local f="$BUNDLE/$ORC_ACCUMULATING_VOCAB"
  [ -f "$f" ] || return 0
  awk -F'|' -v fs="$FS" '
    /^\| Word \| Tickets \|/ { inside = 1; next }
    inside && /^\|[- ]*\|/   { next }
    inside && !/^\|/         { inside = 0 }
    inside {
      line = $0
      gsub(/\\\|/, "\003", line)
      n = split(line, c, "|")
      if (n < 5) next
      for (i = 2; i <= 4; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", c[i])
        gsub(/\003/, "|", c[i])
      }
      print c[2] fs c[3] fs c[4]
    }' "$f"
}

# Which tickets said each folded term, and when it was last recorded. The drafted
# table says how many tickets used a word; a reviewer needs to know which ones,
# because that is where the word can be read in context.
gap_term_provenance() {
  [ -f "$GAP_LEDGER" ] || return 0
  jq -rR 'fromjson? | select(type == "object") | . as $o
          | (.terms_unresolved // [])[]
          | [ ($o.key // ""), ., ($o.recorded_at // "") ] | @tsv' "$GAP_LEDGER" 2>/dev/null \
  | awk -F'\t' "$ORC_FOLD_AWK"'
      {
        f = orc_fold($2)
        if (f == "") next
        if (!((f SUBSEP $1) in seen)) {
          seen[f SUBSEP $1] = 1
          keys[f] = keys[f] (keys[f] == "" ? "" : ", ") $1
        }
        if ($3 > last[f]) last[f] = $3
      }
      END { for (f in keys) printf "%s\t%s\t%s\n", f, keys[f], last[f] }'
}

collect_words() {
  local word count finding folded id notes tickets at prov
  prov="$WORK/gap-prov"
  gap_term_provenance > "$prov"
  while IFS="$FS" read -r word count finding; do
    [ -n "$word" ] || continue
    folded=$(printf '%s' "$word" | _terms_fold)
    [ -n "$folded" ] || continue
    [ -z "$(decision_for word "$folded" "")" ] || continue
    id=$(decision_id word "$folded" "")
    tickets=$(awk -F'\t' -v f="$folded" '$1 == f { print $2; exit }' "$prov")
    at=$(awk -F'\t' -v f="$folded" '$1 == f { print $3; exit }' "$prov")
    [ -n "$tickets" ] || tickets="$count ticket(s), which the gap ledger does not name"
    # Short, and the reasoning is in the section preamble above rather than
    # repeated on every word row. A paragraph a reader has already read three
    # times is a paragraph they skip on the fourth, and then they skip the row
    # note that was specific to one row.
    notes="needs a definition: --as \"what it means\" or --edit, because --agree is refused for a word"
    item word "$id" "$at" "$folded" "" "$tickets" "$word" "$finding" "" "" "$notes" "" "" "" \
      >> "$WORK/items"
  done <<< "$(vocabulary_rows)"
}

# Every concept nobody has signed. The two accumulating files are deliberately
# not among them: signing one whole would freeze the file that has to keep
# growing, which is the reason per-fact promotion exists at all.
collect_concepts() {
  local f rel title at lines id notes
  [ -d "$BUNDLE" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$BUNDLE"/}
    case "$rel" in index.md|*/index.md) continue ;; esac
    case " $ORC_ACCUMULATING_CONCEPTS " in *" $rel "*) continue ;; esac
    concept_is_verified "$f" && continue
    title=$(concept_field "$f" title)
    [ -n "$title" ] || title="$rel"
    at=$(awk '
      /^generated:/ { inb = 1; next }
      inb && /^[[:space:]]+at:/ { s = $0; sub(/^[[:space:]]*at:[[:space:]]*/, "", s); print s; exit }
      inb && /^[^[:space:]]/ { exit }' "$f")
    lines=$(grep -c . "$f" | tr -d ' ')
    id=$(decision_id concept "$rel" "")
    notes="$lines line(s) to read before signing; this queue says what the file is, not what it claims"
    item concept "$id" "$at" "$rel" "" "" "$title" "$rel" "" "" "$notes" "$rel" "" "" \
      >> "$WORK/items"
  done <<< "$(find "$BUNDLE" -name '*.md' -type f 2>/dev/null | sort)"
}

collect_answers
collect_words
collect_concepts

# Newest first, and facts ahead of concepts. A fact is one row somebody can
# settle in a sentence; a concept is a file to read. Ordered by date alone, the
# actionable half would sit under every concept drafted on the day the bundle was
# first written.
#
# Numbered after the sort and in the order the two groups are printed in, so the
# numbers down the screen run 1, 2, 3 with no gaps. A queue whose visible numbers
# skip is a queue somebody types the wrong one out of.
awk -F"$FS" -v fs="$FS" '{ print ($1 == "concept" ? "1" : "0") fs $0 }' "$WORK/items" \
  | sort -t"$FS" -k1,1 -k4,4r \
  | awk -F"$FS" -v fs="$FS" '{ p = index($0, fs); print ++n fs substr($0, p + 1) }' \
  > "$WORK/queue"

n_items=$(grep -c . "$WORK/queue" | tr -d ' ')
n_facts=$(awk -F"$FS" '$2 != "concept"' "$WORK/queue" | grep -c . | tr -d ' ')
n_concepts=$(( n_items - n_facts ))

# An answer row in the bundle with no record behind it. state/ is a cache, so
# this is ordinary rather than damage - and it is named rather than passed over,
# because such a row cannot be reviewed until the harvest has run again.
if [ -f "$BUNDLE/$ORC_ACCUMULATING_ANSWERS" ]; then
  n_drafted_answers=$(awk '
    /^\| Question \| Answered \|/ { inside = 1; next }
    inside && /^\|[- ]*\|/ { next }
    inside && !/^\|/ { inside = 0 }
    inside { c++ }
    END { print c + 0 }' "$BUNDLE/$ORC_ACCUMULATING_ANSWERS")
  _have=0
  for _f in "$STATE_DIR"/*.answers.json; do [ -e "$_f" ] && _have=1; done
  [ "$n_drafted_answers" = "0" ] || [ "$_have" = "1" ] || n_no_record="$n_drafted_answers"
  unset _f _have
fi

# --- resolving what the operator named ---------------------------------------

# By id when it looks like one, by position otherwise. The id is what survives
# the queue moving under a script; the position is what a person read off the
# screen a second earlier.
# An id nothing in the queue matches, rebuilt out of the decision that took it
# off the queue. This is what makes deciding again the way back from a refusal:
# `queue --decided` prints the id, and that id still resolves. Without it the
# ledger would be append-only in the useless sense - a refusal recorded and no
# command able to speak about it again.
from_ledger() {
  [ -f "$VERIFY_LEDGER" ] || return 0
  jq -rR --arg w "$1" --arg fs "$FS" '
    fromjson? | select(type == "object") | select((.id // "") == $w)
    | [ "-", (.kind // ""), (.id // ""), (.at // ""), (.subject_key // ""),
        (.proposal_fold // ""), (.ticket // ""), (.subject // ""), (.proposal // ""),
        (.authors // ""), (.evidence // ""),
        ("This was decided already: " + (.decision // "?") + " by " + (.by // "?")
         + " on " + ((.at // "")[0:10])
         + ((if (.reason // "") == "" then "" else " - \"" + .reason + "\"" end))
         + ". Deciding again appends a line and the newest one counts; nothing is rewritten."),
        "", "", "" ]
    | join($fs)' "$VERIFY_LEDGER" 2>/dev/null | tail -1
}

# Whether what the operator typed is one of the three forms at all, decided in
# the caller's own shell.
#
# Deliberately not an orc_die inside resolve: resolve is read inside $( ), and an
# orc_die there kills only the subshell - the run then carries on past the
# refusal with an empty answer and reports "no such item", which is a different
# and wrong diagnosis of a plain typo. The rule is the repository's own, and this
# is the third place it has been needed.
target_is_addressable() {
  case "$1" in
    *.md) return 0 ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

resolve() {
  local want="$1" line
  case "$want" in
    *.md) awk -F"$FS" -v w="$want" '$13 == w { print; exit }' "$WORK/queue" ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      line=$(awk -F"$FS" -v w="$want" '$3 == w { print; exit }' "$WORK/queue")
      [ -n "$line" ] || line=$(from_ledger "$want")
      printf '%s\n' "$line" ;;
    *) awk -F"$FS" -v w="$want" '$1 == w { print; exit }' "$WORK/queue" ;;
  esac
}

# --- what has already been said about the same subject -----------------------

# The loudest thing this can print. Two people agreeing is corroboration; two
# people disagreeing is the strongest signal the system can produce, and the
# moment somebody is about to sign the second of the two is the only place it is
# visible.
prior_decisions() {
  [ -f "$VERIFY_LEDGER" ] || return 0
  jq -rR --arg k "$1" --arg s "$2" '
    fromjson? | select(type == "object")
    | select((.kind // "") == $k and (.subject_key // "") == $s)
    | "\(.decision // "?")\t\(.by // "?")\t\(.at // "?")\t\(.text // .proposal // "")"' \
    "$VERIFY_LEDGER" 2>/dev/null
}

signed_concepts_saying() {
  local folded="$1" rel text
  [ -n "$folded" ] || return 0
  while IFS=$'\t' read -r rel text; do
    [ -n "$rel" ] || continue
    orc_folded_says "$text" "$folded" || continue
    printf '%s\n' "$rel"
  done <<< "$(bundle_verified_folded "$BUNDLE")"
}

# --- display -----------------------------------------------------------------

# The whole record, and nothing in it abbreviated. What is being signed is a
# sentence somebody wrote, and a column padded to the longest one would either
# cut it or run to a hundred and seventy characters - so every field is a line
# with a label in front of it.
show_item() {
  local line="$1" n kind id at skey ticket subject proposal who how notes rel verb asked
  local prior said
  n=$(field "$line" 1);       kind=$(field "$line" 2);     id=$(field "$line" 3)
  at=$(field "$line" 4);      skey=$(field "$line" 5)
  ticket=$(field "$line" 7);  subject=$(field "$line" 8)
  proposal=$(field "$line" 9); who=$(field "$line" 10);    how=$(field "$line" 11)
  notes=$(field "$line" 12);  rel=$(field "$line" 13);     verb=$(field "$line" 14)
  asked=$(field "$line" 15)

  gap
  case "$kind" in
    answer)
      printf '  %s  [%s]  an answer somebody wrote on %s\n' "$n" "$id" "$ticket"
      gap
      labelled "  " asked "$subject"
      labelled "  " "" "asked on ${asked%%T*}, by refinement"
      labelled "  " answered "$proposal"
      labelled "  " by "${who:-nobody Jira names}, on ${at%%T*}"
      labelled "  " matched "$how"
      if [ -n "$verb" ] && [ "$verb" != "$proposal" ]; then
        gap
        say "the whole reply it was drawn from, unedited:"
        labelled "  " "" "$verb"
      fi
      gap
      say "Agreeing promotes that quotation, word for word, into"
      say "  $ORC_VERIFIED_ANSWERS"
      say "which nothing here drafts, and the row it came from stops being proposed."
      ;;
    word)
      printf '  %s  [%s]  a word tickets used that the bundle cannot explain\n' "$n" "$id"
      gap
      labelled "  " word "$subject"
      labelled "  " "said by" "$ticket"
      labelled "  " evidence "$proposal"
      gap
      say "Agreeing writes YOUR sentence about this word into"
      say "  $ORC_VERIFIED_VOCABULARY"
      say "so it needs one: --as \"what it means\" or --edit. Bare --agree is refused here,"
      say "because the evidence line says what the repositories say about the word rather"
      say "than what the word means."
      ;;
    concept)
      printf '  %s  [%s]  a drafted concept nobody has signed\n' "$n" "$id"
      gap
      labelled "  " file "$rel"
      labelled "  " title "$subject"
      labelled "  " drafted "${at:-at no recorded time}"
      gap
      say "Agreeing writes verified: into its frontmatter. Read the file first:"
      say "  $BUNDLE/$rel"
      ;;
  esac

  if [ -n "$notes" ]; then
    gap
    notes_of "  " "$notes"
  fi

  prior=$(prior_decisions "$kind" "$skey")
  if [ -n "$prior" ]; then
    gap
    say "somebody has already decided about this same subject:"
    printf '%s\n' "$prior" | while IFS=$'\t' read -r _d _b _a _t; do
      [ -n "$_d" ] || continue
      say "  $_d by $_b on ${_a%%T*}: $_t"
    done
    say "Two people agreeing is corroboration. Two people disagreeing is a finding, and"
    say "this is the only place either one is visible."
  fi

  if [ "$kind" = "word" ]; then
    said=$(signed_concepts_saying "$skey")
    if [ -n "$said" ]; then
      gap
      say "a concept somebody has already signed says this word:"
      printf '%s\n' "$said" | while IFS= read -r _c; do [ -n "$_c" ] && say "  $_c"; done
      say "Either that signature is stale, or refinement could not find it. Those have"
      say "different fixes, and neither is repaired here."
    fi
  fi

  # Only the outcomes this item actually has. A printed command that would be
  # refused is the misleading-diagnostic rule in a new place: somebody pastes the
  # --agree line under a word, is told no, and reads the refusal as a bug.
  gap
  case "$kind" in
    answer)
      say "$SELF verify $id --agree$HINT_FLAGS"
      say "$SELF verify $id --as \"…\"$HINT_FLAGS"
      say "$SELF reject $id --reason \"…\"$HINT_FLAGS"
      ;;
    word)
      say "$SELF verify $id --as \"what it means\"$HINT_FLAGS"
      say "$SELF verify $id --edit$HINT_FLAGS"
      say "$SELF reject $id --reason \"…\"$HINT_FLAGS"
      ;;
    concept)
      say "$SELF verify $id --agree$HINT_FLAGS"
      ;;
  esac
}

# --- the queue ---------------------------------------------------------------

queue_row() {
  local line="$1" n kind id at ticket subject proposal who how notes rel
  n=$(field "$line" 1);        kind=$(field "$line" 2);   id=$(field "$line" 3)
  at=$(field "$line" 4);       ticket=$(field "$line" 7); subject=$(field "$line" 8)
  proposal=$(field "$line" 9); who=$(field "$line" 10);   how=$(field "$line" 11)
  notes=$(field "$line" 12);   rel=$(field "$line" 13)

  case "$kind" in
    answer)
      printf '\n  %-3s [%s]  answer   %-10s %s  %s  (matched %s)\n' \
        "$n" "$id" "$ticket" "${at%%T*}" "${who:-nobody Jira names}" "$how"
      labelled "    " asked "$subject"
      labelled "    " answered "$proposal"
      ;;
    word)
      printf '\n  %-3s [%s]  word     said by %s\n' "$n" "$id" "$ticket"
      labelled "    " word "$subject"
      labelled "    " evidence "$proposal"
      ;;
    concept)
      printf '\n  %-3s [%s]  concept  %-32s drafted %s\n' "$n" "$id" "$rel" "${at%%T*}"
      labelled "    " title "$subject"
      ;;
  esac
  notes_of "    " "$notes"
}

# --- signatures nobody has renewed in a long time ---------------------------
#
# Advisory, and deliberately outside the queue's own accounting. A `verified:`
# concept is frozen by design: bin/orc-okf-draft.sh will not re-draft it and
# prompts/refine.md tells the refiner to quote it as knowledge with no checking
# against code. That is the right trade, and it is also why a signature that
# has since gone false is the most confidently-wrong answer this system can
# produce - and nothing else ever asks whether one still holds.
#
# It informs a person and never the refiner. Age does not correlate with
# staleness - an architectural fact signed two years ago can be perfectly true
# while one signed last week is already false - so nothing here is un-signed, no
# weight in prompts/refine.md changes, and no age reaches the refiner's
# context. This is a reading list, not a verdict.
#
# The two rendered files (verified-answers.md, verified-vocabulary.md) are left
# out: they carry one date per person who ever signed a row, so an old newest
# date there means "this person has not signed lately" rather than "this
# knowledge is unreviewed", and their staleness is a per-row question the
# ordinary queue already handles a row at a time.
#
# A signature leaves this list by being renewed: re-reading the concept and
# signing it again moves the date forward. For a drafted concept that means
# removing its verified: block (which returns it to the drafted-concept queue)
# and signing the fresh draft; for a promoted row it means deciding it again.
# Either way concept_verified_at then reads the newer date.
aged_signatures() {
  local f rel at by days
  [ -d "$BUNDLE" ] || return 0
  case "$STALE_DAYS" in ''|*[!0-9]*) return 0 ;; esac
  find "$BUNDLE" -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$BUNDLE"/}
    case "$rel" in index.md|*/index.md) continue ;; esac
    case " $ORC_ACCUMULATING_CONCEPTS $ORC_VERIFIED_ANSWERS $ORC_VERIFIED_VOCABULARY " in
      *" $rel "*) continue ;;
    esac
    concept_is_verified "$f" || continue
    at=$(concept_verified_at "$f")
    [ -n "$at" ] || continue
    days=$(days_since "$at") || continue
    [ "$days" -ge "$STALE_DAYS" ] || continue
    by=$(concept_verified_by "$f" | awk -F', ' -v a="$at" '$2 == a { print $1; exit }')
    printf '%s\t%s\t%s\n' "$rel" "${by:-nobody named}" "$days"
  done
}

print_aged_signatures() {
  local rows n
  rows=$(aged_signatures)
  [ -n "$rows" ] || return 0
  n=$(printf '%s\n' "$rows" | grep -c .)
  step "$(plural "$n" "verified concept" "verified concepts") not re-read in over $STALE_DAYS days"
  say "Advisory: none of the counts or the exit status above move for this. These"
  say "concepts are already decided, and refinement quotes a signed concept as"
  say "knowledge - so one that has gone stale is worth a fresh read. Age is not"
  say "staleness, nothing here is un-signed, and the refiner is never told an age."
  say "Signing one again moves its date forward and drops it from this list."
  printf '%s\n' "$rows" | while IFS=$'\t' read -r _rel _by _days; do
    [ -n "$_rel" ] || continue
    gap
    say "$_rel"
    say "    last signed by $_by, $(humanize_days "$_days")"
  done
}

print_queue() {
  if [ "$n_items" = "0" ]; then
    printf '\n  nothing awaits a decision\n\n'
    # Congratulating somebody on an empty review queue when the bundle was never
    # drafted is the misleading-diagnostic rule again: the two look identical
    # from here and need opposite things done about them.
    if [ ! -d "$BUNDLE" ]; then
      say "There is no bundle at $BUNDLE yet, so there is nothing to review rather than nothing left. bin/orc-onboard.sh drafts one, and bin/orc-cycle.sh keeps it current."
    else
      say "No drafted row and no unsigned concept is left in $BUNDLE. That is what a bundle somebody has been through looks like, rather than an empty one."
    fi
    print_aged_signatures
    return 0
  fi

  printf '\n  awaiting a decision: %s, %s\n' \
    "$(plural "$n_facts" "fact" "facts")" \
    "$(plural "$n_concepts" "drafted concept" "drafted concepts")"
  gap
  say "A fact is one row inside a file this system keeps adding rows to. Agreeing moves"
  say "it out into a file nothing here drafts, and the row stops being proposed;"
  say "refusing records that, so the identical row is never proposed again."
  say "A concept is a whole file. Agreeing freezes it: the drafter then reports what it"
  say "would have re-written instead of re-writing it."
  gap
  say "Three outcomes, and nothing is signed that was not printed first:"
  say "  $SELF show N$HINT_FLAGS"
  say "  $SELF verify N --agree$HINT_FLAGS"
  say "  $SELF verify N --as \"…\"$HINT_FLAGS"
  say "  $SELF reject N --reason \"…\"$HINT_FLAGS"

  if [ "$n_facts" != "0" ]; then
    step "facts"
    say "An answer is somebody's own words, so agreeing promotes the quotation as it"
    say "stands. A word is not: the evidence line under it says what the repositories"
    say "say ABOUT the word rather than what it means, so a word is signed with"
    say "--as \"what it means\" or --edit and bare --agree is refused."
    awk -F"$FS" '$2 != "concept"' "$WORK/queue" | while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      queue_row "$_l"
    done
  fi
  if [ "$n_concepts" != "0" ]; then
    step "drafted concepts"
    say "Each of these is a whole file carrying generated: and no verified:. Agreeing"
    say "writes verified: into its frontmatter, and bin/orc-okf-draft.sh then reports"
    say "what it would have re-drafted instead of re-drafting it. Read the file first."
    awk -F"$FS" '$2 == "concept"' "$WORK/queue" | while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      queue_row "$_l"
    done
  fi

  if [ "$n_no_record" != "0" ]; then
    gap
    banner "AN ANSWER IS IN THE BUNDLE WITH NO RECORD BEHIND IT

$ORC_ACCUMULATING_ANSWERS holds $n_no_record row(s) and $STATE_DIR holds no harvest record at all, so those rows cannot be reviewed here.

state/ is a cache and this is what clearing it looks like rather than damage. Re-reading the comments rebuilds every row exactly:

  bin/orc-harvest.sh"
  fi

  print_aged_signatures
}

print_decided() {
  local n
  if [ ! -f "$VERIFY_LEDGER" ]; then
    printf '\n  nothing has been decided yet\n\n'
    say "$(ledger_resource) does not exist. It is written the first time somebody agrees to or refuses a row."
    return 0
  fi
  n=$(jq -rR 'fromjson? | select(type == "object") | .id // ""' "$VERIFY_LEDGER" 2>/dev/null \
      | grep -c . | tr -d ' ')
  printf '\n  decisions recorded: %s\n' "$n"
  gap
  say "Newest last, and the newest one about a subject is the one that counts - so"
  say "deciding again is how a decision is taken back, and nothing in the ledger is"
  say "ever rewritten. The id beside a decision still resolves: verify or reject it"
  say "again to overrule it."
  gap
  jq -rR 'fromjson? | select(type == "object")
    | "  \((.at // "?")[0:10])  \(.decision // "?")  [\(.id // "?")]  \(.kind // "?")  \(.by // "?")\n    \(.subject // "")\n    \(if (.decision // "") == "reject" then "refused: " + (.reason // "no reason recorded") else (.text // .proposal // "") end)\n"' \
    "$VERIFY_LEDGER" 2>/dev/null
}

# --- the signed files, rendered from the ledger ------------------------------
#
# One direction only: the ledger is what somebody decided, and these two files
# are the readable view of it. Rendered rather than appended to, so the two can
# never disagree about what was signed - the same relationship every drafted
# concept has with the repositories it was read from.
#
# The frontmatter carries one `verified:` entry per person who has signed
# anything in the file, with the latest date each of them signed on.
# concept_verified_by in orc-lib.sh already reads exactly that shape, so a report
# about to discard the bundle can name the people rather than a count.

# The newest decision about each (subject, proposal), keeping only the ones that
# ended in agreement. group_by sorts by its key and jq's sort is stable, so the
# last line in a group is the line appended last - which is what makes deciding
# again overrule an earlier decision with nothing rewritten.
#
# The two halves of the key are joined with a character neither of them can hold:
# both are folded text, `[a-z0-9 ]` plus a ticket key, so concatenating them bare
# would let one pair's boundary fall where another pair's content does. Spelled as
# a pipe rather than as the raw control byte it used to be - an invisible
# separator inside a jq program is a byte the next edit drops with nothing saying
# so.
agreed_of() {
  [ -f "$VERIFY_LEDGER" ] || { printf '[]'; return 0; }
  jq -sR --arg k "$1" '
    [ splits("\n") | select(length > 0) | fromjson? | select(type == "object") ]
    | map(select((.kind // "") == $k))
    | group_by((.subject_key // "") + "|" + (.proposal_fold // ""))
    | map(last)
    | map(select((.decision // "") == "agree"))
    | sort_by(.at)' "$VERIFY_LEDGER" 2>/dev/null
}

verified_block() {
  jq -r '
    group_by(.by // "?")
    | map({by: (.[0].by // "?"), at: (map(.at // "") | max)})
    | sort_by(.by) | .[] | "  - by: \(.by)\n    at: \(.at[0:10])"' <<< "$1"
}

render_verified_answers() {
  local rows="$1" n cell
  n=$(jq 'length' <<< "$rows")
  printf -- '---\n'
  printf 'type: Reference\n'
  printf 'title: Answers a person signed\n'
  printf 'description: %s\n' "$(yaml_scalar "Answers reporters gave that somebody has read and agreed to, one row per fact, each naming who signed it.")"
  printf 'tags: [verified, refinement, provenance]\n'
  printf 'status: stable\n'
  printf 'verified:\n%s\n' "$(verified_block "$rows")"
  printf 'sources:\n'
  while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    printf -- '  - id: ticket-%s\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$_k" | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the comments on $_k, where the question was asked and answered")" \
      "$(yaml_scalar "$(ticket_resource "$_k")")"
  done <<< "$(jq -r '[ .[] | .ticket // "" ] | map(select(length > 0)) | unique | .[]' <<< "$rows")"
  unset _k
  printf -- '  - id: decisions\n    title: %s\n    resource: %s\n' \
    "$(yaml_scalar "the ledger of what somebody agreed to or refused, one append-only line per decision")" \
    "$(yaml_scalar "$(ledger_resource)")"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Signed, not drafted.** Every row here was a proposal in
\`$ORC_ACCUMULATING_ANSWERS\` until somebody read it and agreed. Nothing in this
repository writes this file except \`$SELF\`, which renders it from the decisions
in \`$(ledger_resource)\`[^decisions] - so the drafter cannot re-draft over it and
does not have to know it exists.

That is what makes a fact inside an accumulating file signable at all. The file
answers arrive in has to keep growing, and a \`verified:\` date on it would freeze
exactly the file that must not be frozen. So agreeing moves the row here instead,
and the drafter's promise to leave a signed concept alone stays a simple rule
about whole files.

# What a signature here means, and what it does not

Somebody read this answer and agreed that it holds. That is a stronger claim than
the drafted row it came from and still a narrower one than a repository's: it is
one person's reading of one reply, on one ticket. It is not a claim that the
product works this way in general, and nothing here promotes it to one.

$(plural "$n" "answer" "answers") signed.

| Question | The answer, as signed | Ticket | Signed |
|---|---|---|---|
EOF
  while IFS=$'\t' read -r _subject _text _proposal _ticket _signer _at _authors _evidence; do
    [ -n "$_subject" ] || continue
    cell="$_text"
    [ "$_text" = "$_proposal" ] || cell="$cell<br>*signed in the reviewer's own words. What was written on the ticket:* \"$_proposal\""
    [ -z "$_authors" ] || cell="$cell<br>answered by $_authors${_evidence:+, matched $_evidence}"
    printf '| %s | %s | %s[^ticket-%s] | %s, %s |\n' \
      "$(md_cell "$_subject")" "$(md_cell "$cell")" "$_ticket" \
      "$(printf '%s' "$_ticket" | tr -c 'A-Za-z0-9' '-')" \
      "$(md_cell "$_signer")" "${_at%%T*}"
  done <<< "$(jq -r '.[] | [ (.subject // ""), (.text // .proposal // ""), (.proposal // ""),
                             (.ticket // ""), (.by // ""), (.at // ""), (.authors // ""),
                             (.evidence // "") ] | @tsv' <<< "$rows")"
  unset _subject _text _proposal _ticket _signer _at _authors _evidence

  cat <<EOF

# What this does not say

- Whether an answer is still true. A signature carries the day it was given and
  nothing revisits it, so a row about a flow that has since changed reads exactly
  like a row about one that has not.
- Whether it holds past the ticket it was given on. One person read one reply and
  agreed with it; the bundle promotes a phrase only when two repositories say it,
  and that is a different and higher bar.
- What the people who never replied would have said. Those questions are still in
  $ORC_ACCUMULATING_ANSWERS or in nothing at all, and silence is not agreement.
EOF
}

render_verified_vocabulary() {
  local rows="$1" n
  n=$(jq 'length' <<< "$rows")
  printf -- '---\n'
  printf 'type: Glossary\n'
  printf 'title: Vocabulary a person signed\n'
  printf 'description: %s\n' "$(yaml_scalar "Words real tickets used that somebody has now defined, one row per word, each naming who defined it.")"
  printf 'tags: [verified, terminology, refinement]\n'
  printf 'status: stable\n'
  printf 'verified:\n%s\n' "$(verified_block "$rows")"
  printf 'sources:\n'
  printf -- '  - id: decisions\n    title: %s\n    resource: %s\n' \
    "$(yaml_scalar "the ledger of what somebody agreed to or refused, one append-only line per decision")" \
    "$(yaml_scalar "$(ledger_resource)")"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Signed, not drafted.** Each word here reached
\`$ORC_ACCUMULATING_VOCAB\` because at least two tickets used it and nothing in
this bundle could explain it. The sentence beside it is not what the repositories
said: it is what a person wrote when they were asked what the word means, which is
exactly the half no artefact in the tree holds.

Nothing in this repository writes this file except \`$SELF\`, which renders it
from \`$(ledger_resource)\`[^decisions]. The drafted table it came from keeps
growing; this one grows only when somebody signs something.

$(plural "$n" "word" "words") defined.

| Word | What it means | Signed | Tickets that used it |
|---|---|---|---|
EOF
  while IFS=$'\t' read -r _word _text _signer _at _tickets; do
    [ -n "$_word" ] || continue
    printf '| %s | %s | %s, %s | %s |\n' \
      "$(md_cell "$_word")" "$(md_cell "$_text")" \
      "$(md_cell "$_signer")" "${_at%%T*}" "$(md_cell "$_tickets")"
  done <<< "$(jq -r '.[] | [ (.subject // ""), (.text // ""), (.by // ""), (.at // ""),
                             (.ticket // "") ] | @tsv' <<< "$rows")"
  unset _word _text _signer _at _tickets

  cat <<EOF

# What this does not say

- Where the word lives in the code. The evidence that reached the drafted table
  stays with the decision rather than being promoted here, because a definition
  and a grep target are different things and a reader who wants the second one
  wants the repository.
- Whether a definition is complete. One person answered one question about one
  word, so a term that means two things in two subsystems reads here as though it
  means one.
- Which of these deserves a concept of its own. A word worth a paragraph is worth
  a concept, and deciding that is somebody's judgement rather than this file's.
EOF
}

# The region this script owns in an index, replaced where it already is rather
# than stripped and re-appended. The drafter owns a region of the same files, and
# two writers that each moved their own region to the end would swap places on
# every run - a bundle whose index changes every time is a diff nobody reads.
#
# The file is cut into what is above the region and what is below it, and the new
# region goes between them. Deliberately not `awk -v body=...`: BSD awk refuses a
# newline inside a -v assignment and writes nothing at all, which emptied an
# index file rather than failing, and macOS ships that awk.
verify_index_region() {
  local rel="$1" heading="$2" listing="$3" file body
  file="$BUNDLE/$rel"
  : > "$WORK/ix-head"
  : > "$WORK/ix-tail"
  if [ -f "$file" ] && grep -qF "$VERIFY_BEGIN" "$file"; then
    awk -v b="$VERIFY_BEGIN" '$0 == b { exit } { print }' "$file" > "$WORK/ix-head"
    awk -v e="$VERIFY_END" 'past { print } $0 == e { past = 1 }' "$file" > "$WORK/ix-tail"
  elif [ -f "$file" ]; then
    cat "$file" > "$WORK/ix-head"
    [ -z "$listing" ] || [ ! -s "$WORK/ix-head" ] || printf '\n' >> "$WORK/ix-head"
  fi
  if [ -z "$listing" ]; then
    [ -f "$file" ] || return 0
    cat "$WORK/ix-head" "$WORK/ix-tail" > "$WORK/index-new"
  else
    body="$VERIFY_BEGIN

# $heading

$listing$VERIFY_END"
    { cat "$WORK/ix-head"; printf '%s\n' "$body"; cat "$WORK/ix-tail"; } > "$WORK/index-new"
  fi
  if [ -f "$file" ] && cmp -s "$WORK/index-new" "$file"; then return 0; fi
  mkdir -p "$(dirname "$file")" || orc_die "could not create $(dirname "$file")"
  cp "$WORK/index-new" "$file" || orc_die "could not write $file"
  printf '%s\n' "$rel" >> "$WORK/written"
}

WROTE=""

# rm -f of one named file, never a tree. There is nothing to prove beforehand
# because there is nothing only in it: the file is rendered from the ledger, so
# the ledger is where the content lives and this is a view of it.
write_or_remove() {
  local rel="$1" rows="$2" renderer="$3" file
  file="$BUNDLE/$rel"
  if [ "$(jq 'length' <<< "$rows")" = "0" ]; then
    [ -f "$file" ] || return 0
    rm -f "$file" || orc_die "could not remove $file"
    printf '%s\n' "$rel" >> "$WORK/written"
    return 0
  fi
  mkdir -p "$(dirname "$file")" || orc_die "could not create $(dirname "$file")"
  "$renderer" "$rows" > "$WORK/rendered" || orc_die "could not render $rel"
  if [ -f "$file" ] && cmp -s "$WORK/rendered" "$file"; then return 0; fi
  cp "$WORK/rendered" "$file" || orc_die "could not write $file"
  printf '%s\n' "$rel" >> "$WORK/written"
}

render_all() {
  local answers words listing
  : > "$WORK/written"
  answers=$(agreed_of answer)
  words=$(agreed_of word)
  write_or_remove "$ORC_VERIFIED_ANSWERS"    "$answers" render_verified_answers
  write_or_remove "$ORC_VERIFIED_VOCABULARY" "$words"   render_verified_vocabulary

  listing=""
  [ ! -f "$BUNDLE/$ORC_VERIFIED_ANSWERS" ] || listing="$listing* [Answers a person signed]($(basename "$ORC_VERIFIED_ANSWERS")) - answers reporters gave that somebody has read and agreed to.
"
  [ ! -f "$BUNDLE/$ORC_VERIFIED_VOCABULARY" ] || listing="$listing* [Vocabulary a person signed]($(basename "$ORC_VERIFIED_VOCABULARY")) - words real tickets used, with what somebody says each one means.
"
  verify_index_region "domain/index.md" "Signed by a person" "$listing"

  listing=""
  [ ! -f "$BUNDLE/$ORC_VERIFIED_ANSWERS" ] || listing="$listing* [Answers a person signed]($ORC_VERIFIED_ANSWERS) - answers reporters gave that somebody has read and agreed to.
"
  [ ! -f "$BUNDLE/$ORC_VERIFIED_VOCABULARY" ] || listing="$listing* [Vocabulary a person signed]($ORC_VERIFIED_VOCABULARY) - words real tickets used, with what somebody says each one means.
"
  [ -z "$listing" ] || listing="Signed off by a person, one fact at a time, through \`$SELF\`. Every row
names who signed it and when.

$listing"
  verify_index_region "index.md" "Signed by a person" "$listing"

  WROTE=$(sort -u "$WORK/written" 2>/dev/null)
}

# --- writing a decision ------------------------------------------------------

RESOLVED=""

append_decision() {
  local decision="$1" text="$2" why="$3" line
  local kind id skey pfold ticket subject proposal who how
  line="$RESOLVED"
  kind=$(field "$line" 2);     id=$(field "$line" 3)
  skey=$(field "$line" 5);     pfold=$(field "$line" 6)
  ticket=$(field "$line" 7);   subject=$(field "$line" 8)
  proposal=$(field "$line" 9); who=$(field "$line" 10);  how=$(field "$line" 11)
  mkdir -p "$(dirname "$VERIFY_LEDGER")" || orc_die "could not create $(dirname "$VERIFY_LEDGER")"
  jq -nc --arg id "$id" --arg kind "$kind" --arg d "$decision" \
        --arg sk "$skey" --arg pf "$pfold" --arg t "$ticket" --arg s "$subject" \
        --arg p "$proposal" --arg x "$text" --arg by "$by" --arg at "$(orc_now)" \
        --arg r "$why" --arg a "$who" --arg e "$how" '{
    id: $id, kind: $kind, decision: $d, subject_key: $sk, proposal_fold: $pf,
    ticket: $t, subject: $s, proposal: $p, text: $x, authors: $a, evidence: $e,
    by: $by, at: $at, reason: $r
  }' >> "$VERIFY_LEDGER" || orc_die "could not append to $VERIFY_LEDGER"
}

# The frontmatter edit, and the only thing in here that touches a concept file.
# A new top-level key inserted at the end of the frontmatter: a `sources:` entry
# is indented, so a key in column zero closes that list rather than joining it.
sign_concept() {
  local rel="$1" file
  file="$BUNDLE/$rel"
  [ -f "$file" ] || orc_die "$rel is not in $BUNDLE any more"
  ! concept_is_verified "$file" || orc_die "$rel already carries a verified: block"
  awk -v by="$by" -v at="$(signed_today)" '
    NR == 1 && $0 == "---" { print; opened = 1; next }
    opened && $0 == "---" && !done {
      printf "verified:\n  - by: %s\n    at: %s\n", by, at
      done = 1
      print
      next
    }
    { print }
    END { if (!done) exit 3 }' "$file" > "$WORK/signed" \
    || orc_die "$rel has no frontmatter to sign, so it is not an OKF concept"
  cp "$WORK/signed" "$file" || orc_die "could not write $file"
}

# Read through `ask`, which sets a global rather than printing, so a refusal is
# an orc_die in this shell rather than in a subshell that a caller carries on
# past with an empty answer.
confirm() {
  if [ "$assume_yes" = "1" ]; then
    gap
    say "$1  --yes"
    return 0
  fi
  gap
  say "$1  [y/N]"
  ask "pass --yes to answer it in a scripted run"
  case "$ANSWER" in
    y|Y|yes|YES) return 0 ;;
    *) orc_die "not confirmed; nothing was written" ;;
  esac
}

# --- run ---------------------------------------------------------------------

case "$cmd" in
  queue)
    if [ "$show_decided" = "1" ]; then print_decided; exit 0; fi
    print_queue
    [ "$n_items" = "0" ] && exit 0
    exit 1
    ;;
  render)
    render_all
    if [ ! -f "$VERIFY_LEDGER" ]; then
      printf '\n  nothing has been signed yet, so there is nothing to render\n\n'
      say "$(ledger_resource) does not exist. It is written the first time somebody agrees to or refuses a row, and these two files are the view of it."
    elif [ -z "$WROTE" ]; then
      printf '\n  the signed files already match %s; nothing was written\n\n' "$(ledger_resource)"
    else
      printf '\n  rendered from %s\n\n' "$(ledger_resource)"
      printf '%s\n' "$WROTE" | while IFS= read -r _w; do [ -n "$_w" ] && say "  $BUNDLE/$_w"; done
      gap
    fi
    exit 0
    ;;
esac

# The two accumulating files are not in the queue at all, so a path is the only
# way anybody asks for one - and somebody who has just read domain/reporter-answers.md
# and wants to sign it will. Answered here rather than with "no such item",
# because the refusal is the explanation.
case " $ORC_ACCUMULATING_CONCEPTS " in
  *" $target "*)
    orc_die "$target is not signed whole: it grows a row on every run, and a verified: date would freeze the one kind of file in this bundle whose job is to keep growing. Its rows are signed one at a time, and they are in $SELF queue$HINT_FLAGS" ;;
esac

target_is_addressable "$target" \
  || orc_die "'$target' is none of the three things this takes: a queue position, the eight-character id printed beside one, or a path in the bundle"

RESOLVED=$(resolve "$target" | grep . || true)
if [ -z "$RESOLVED" ]; then
  case "$target" in
    *.md)
      if [ ! -f "$BUNDLE/$target" ]; then
        orc_die "$target is not in $BUNDLE"
      elif concept_is_verified "$BUNDLE/$target"; then
        orc_die "$target is already signed: $(concept_verified_by "$BUNDLE/$target" | tr '\n' ';')"
      fi ;;
  esac
  orc_die "no item '$target' awaits a decision; $SELF queue$HINT_FLAGS lists what does"
fi

kind=$(field "$RESOLVED" 2)
id=$(field "$RESOLVED" 3)
proposal=$(field "$RESOLVED" 9)
rel=$(field "$RESOLVED" 13)

case "$cmd" in
  show)
    show_item "$RESOLVED"
    gap
    exit 0
    ;;

  reject)
    [ -n "$reason" ] || orc_die "reject needs --reason: this is the only record a refusal leaves, and one with no reason on it tells the next reader nothing"
    [ "$kind" != "concept" ] || orc_die "a drafted concept cannot be refused: bin/orc-okf-draft.sh re-renders it from the repositories on the next run, so the refusal would be undone rather than recorded. Fix the evidence, or delete the file"
    show_item "$RESOLVED"
    confirm "Record that this is refused, so it is never proposed again?"
    append_decision reject "" "$reason"
    gap
    say "refused, and recorded in $(ledger_resource)."
    say "Neither $ORC_ACCUMULATING_ANSWERS nor $ORC_ACCUMULATING_VOCAB proposes it again."
    say "Commit that file: it is the only copy, and a refusal leaves nothing else behind."
    gap
    exit 0
    ;;

  verify)
    n_ways=$(( agree + do_edit + have_as ))
    [ "$n_ways" != "0" ] || orc_die "verify needs to know how: --agree signs it as it stands, --as \"TEXT\" signs it in your own words, --edit opens it in \$EDITOR"
    [ "$n_ways" = "1" ] || orc_die "--agree, --as and --edit are three ways of signing one thing; pick one"

    text="$proposal"
    if [ "$have_as" = "1" ]; then
      text="$as_text"
    elif [ "$do_edit" = "1" ]; then
      ed="${VISUAL:-${EDITOR:-}}"
      [ -n "$ed" ] || orc_die "--edit needs \$EDITOR or \$VISUAL set; --as \"TEXT\" does the same thing without one"
      printf '%s\n' "$proposal" > "$WORK/edit"
      $ed "$WORK/edit" || orc_die "the editor exited non-zero, so nothing was written"
      text=$(awk '
        NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); out = (out == "" ? $0 : out " " $0) }
        END { print out }' "$WORK/edit")
    fi

    case "$kind" in
      word)
        [ "$agree" = "0" ] || orc_die "a word cannot be agreed to as it stands: the row says what the repositories say ABOUT the word rather than what it means, so signing it unchanged would file the evidence as the definition. Use --as \"what it means\" or --edit"
        ;;
      concept)
        [ "$agree" = "1" ] || orc_die "a concept is signed whole or not at all: --as and --edit change one fact, and a concept file is not one fact. Edit the file and then --agree"
        ;;
    esac
    [ -n "$text" ] || orc_die "nothing left to sign; an empty fact is not a fact"

    show_item "$RESOLVED"
    if [ "$text" != "$proposal" ]; then
      gap
      say "you are signing this rather than what was proposed:"
      say "  $text"
    fi

    case "$kind" in
      concept) confirm "Sign $rel whole, so it is never re-drafted?" ;;
      *)       confirm "Sign this as $by, and promote it out of the drafted file?" ;;
    esac

    if [ "$kind" = "concept" ]; then
      sign_concept "$rel"
      gap
      say "signed. $BUNDLE/$rel carries verified: $by, $(signed_today)."
      say "bin/orc-okf-draft.sh reports what it would have re-drafted rather than re-drafting it."
      say "Delete that block by hand if you ever want the draft back."
      gap
      exit 0
    fi

    append_decision agree "$text" ""
    render_all
    gap
    say "signed, and promoted out of the drafted file."
    if [ -n "$WROTE" ]; then
      printf '%s\n' "$WROTE" | while IFS= read -r _w; do [ -n "$_w" ] && say "  $BUNDLE/$_w"; done
    fi
    say "  $(ledger_resource)"
    gap
    say "Commit both. The bundle files can be rendered again from the ledger; the ledger cannot be derived from anything."
    gap
    exit 0
    ;;
esac
