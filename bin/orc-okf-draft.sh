#!/usr/bin/env bash
# Drafts knowledge-bundle concepts from the repositories config/projects.yml
# names. Nothing else populates the bundle: refinement reads it and until this
# existed nothing wrote it, so it stayed at whatever a human had typed while the
# code moved away underneath.
#
#   orc-okf-draft.sh                    every configured repository
#   orc-okf-draft.sh api dashboard      only these
#   orc-okf-draft.sh --check            write nothing, report what would move
#   orc-okf-draft.sh --drifted          --check, but print only the paths of
#                                       the concepts that moved, one per line
#   orc-okf-draft.sh --bundle DIR       write into DIR instead of .okf
#   orc-okf-draft.sh --quiet            the table only, no preamble
#   orc-okf-draft.sh --gap-terms FILE   also draft what bin/orc-gap-loop.sh ranked
#   orc-okf-draft.sh --answers FILE     also draft what bin/orc-harvest.sh read
#
# The bundle's job is to turn a ticket written in *product* language into a named
# repository and a set of probable files, in that order. So the only thing worth
# reading out of a repository is evidence that crosses from one to the other.
# Four artefacts carry it, and they are the four this script reads:
#
#   the translatable string catalogues, which are the product's own dictionary -
#   a product phrase on one side and the code key it is filed under on the other,
#   already machine-readable, in every language the product ships
#
#   the frozen constants and enums a model declares, and the comments a human
#   wrote above them, which is where domain meaning is actually written down
#
#   the schema constraints that encode a rule rather than a layout: a partial
#   unique index, a composite unique index, a check constraint, and the columns
#   a table refuses to be without
#
#   the retirement signals - an identifier that filters a term out, a migration
#   whose table is gone - because a word that means one thing in code somebody is
#   shipping and another in rows nobody has written in years is the ambiguity that
#   decides a verdict, and a concept asserting either of the two meanings is worse
#   than no concept at all
#
# What it deliberately does not read: the names of files. `app/models/` listed
# with citations is a dictionary from the code's vocabulary to itself, and it can
# only help a ticket already written in code terms - which did not need help. A
# path list is what `git ls-files` is for.
#
# What it drafts, and deliberately nothing else:
#
#   one Subsystem concept per configured repository - what it is, what it does
#   NOT own, and which product phrases only its own catalogue says. The negative
#   half is what prevents a whole class of wrong file list; the phrases are what
#   route a ticket quoting one of them to this repository and no other.
#
#   one Glossary concept - the product-phrase-to-code-key dictionary derived from
#   the catalogues, plus the vocabulary the evidence says is not live any more
#
#   one Reference concept - the domain rules written down as constants, enums,
#   comments and schema constraints
#
#   one Capability concept per cross-cutting thing the evidence shows in more
#   than one repository. Today that is localisation and nothing else.
#
#   one Glossary concept of the words real tickets used that the bundle could not
#   explain, and only when a caller passes --gap-terms. Those words come from
#   bin/orc-gap-loop.sh, which ranks what refinement recorded as unresolved; what
#   the repositories say about each one is decided here, by the same evidence and
#   the same rules as every other row. One concept and not one per word, for the
#   scope reason below.
#
#   one Reference concept of what people answered when refinement asked them a
#   product question, and only when a caller passes --answers. Those rows come
#   from bin/orc-harvest.sh, which reads them out of the Jira comments. It is the
#   one concept here whose evidence is a person rather than a repository, which is
#   precisely why it is drafted through the same publish() as the rest: an answer
#   arriving with a stronger claim than a repository's is the failure that would
#   cost the most.
#
# Not a concept per model, not a concept per endpoint, not a concept per screen.
# The design says a few dozen files of roughly one screen each, and a bundle
# that grows past that has started absorbing documentation - at which point
# refinement is reading a wiki instead of resolving a term. Forty vague concepts
# are worse than twelve sharp ones, because refinement will believe all forty.
#
# Nothing here pins a commit, and that is a decision rather than an omission.
# Drift is decided by re-rendering the body and comparing bytes, so a commit id
# in a concept means every push to any repository marks every concept stale while
# nothing about its meaning moved - which turns --check into noise and trains a
# reader to ignore it. A commit belongs on a verdict, which has to say what code
# it reasoned against. It does not belong on a concept describing what a
# repository owns. The release branch is named instead, because that is the fact
# a ticket depends on, and a repository that does not release from main is
# ordinary rather than exceptional. `last_modified:` is left off a source for the same reason: on a moving
# branch the honest value is a commit date, and a commit date is the pinning.
#
# Every source names something a reader can actually fetch - a tree URL, a blob
# URL, a blob URL with a line anchor. A source whose resource is a sentence
# describing what was read is decoration, and it was removed.
#
# Every outcome:
#
#   drafted    the concept did not exist; it does now
#   updated    the evidence moved, so the draft moved with it
#   unchanged  byte-identical to what was already there
#   SKIPPED    a human has verified this concept. It is theirs. What would have
#              changed is reported and the file is not touched.
#   skipped    the repository was not in a state worth reading
#
# Read-only against every repository, through git_read and plain file reads.
# Writes only inside the bundle, and only ever a whole concept file or the
# region of an index.md this script owns.
#
# Nothing it writes is verified, and nothing it writes may pretend to be. A
# drafted concept carries generated: and no verified:, which is what makes it an
# unverified draft under OKF §5.3 - a fact a human has not checked. Refinement
# is told to weight it lower, in prompts/refine.md, because a drafted figure
# read as an established one is exactly how a wrong number ends up quoted in a
# task brief.
#
# And a draft says what it could not determine. Some of what the bundle needs is
# in no artefact - that a concept was retired as a company decision is not in any
# repository - so the target is not omniscience. A concept that names its hole is
# more useful than one that fills the space with filenames, because the hole is
# a question a human can answer and the filenames are not.
#
# Exit codes: 0 nothing needs attention, 1 something does (--check: drift).
# --drifted adds 2, meaning it could not decide: a repository it would have had
# to read was not readable, so a shrunken index listing would have looked like
# drift when the only thing that moved was a checkout. Its caller reads the
# output rather than the code - empty output is never drift, whatever the exit
# status says - because a diagnostic that misleads is worse than one that says
# nothing, and a script that dies has an exit status too.
# This script's output is markdown, so a backtick in a printf format string is a
# code span rather than a command substitution that lost its quotes.
# shellcheck disable=SC2016
set -uo pipefail
# Drift is decided by re-rendering a body and comparing bytes, and roughly
# fifteen sorts decide the order those bytes come out in. Collation is a locale's
# opinion: given two project names differing only in an underscore,
# en_US.UTF-8 ignores that punctuation and sorts one first, C reads the
# underscore and sorts it last. Unpinned, the same repositories at the same
# commits drift or do not depending on the operator's environment, which makes
# the warning noise.
export LC_ALL=C
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd git awk sed

BUNDLE="$BUNDLE_DIR"
check_only=0
list_only=0
quiet=0
wanted=""
# The terms bin/orc-gap-loop.sh has ranked and proposed, as
# display<TAB>folded<TAB>tickets<TAB>runs. Given one, this script drafts the
# open-vocabulary concept alongside everything else it drafts.
#
# It is one more concept on a normal run rather than a mode of its own, and that
# is deliberate. An index region is replaced whole, so a run that published only
# the gap concept would rewrite the bundle's front door with one entry on it and
# drop the subsystems from the listing. The evidence the gap concept needs - the
# catalogues, the declared terms, the phrase table - is the evidence this script
# already reads to draft the rest, so there is nothing extra to gather either.
gap_terms=""
# The answers bin/orc-harvest.sh read out of Jira, as
# key<FS>question<FS>asked<FS>answer<FS>author<FS>answered<FS>matched<FS>contested<FS>collision.
# One more concept on a normal run, for the same reason --gap-terms is: an index
# region is replaced whole, so a run that published only this concept would
# rewrite the bundle's front door with one entry on it.
answers=""
# The command a --check run's drift line names, for a caller that has one. Only
# the caller knows the flags it was given, and a --gap-terms or --answers run is
# that caller's run rather than this script's: told to run bin/orc-gap-loop.sh
# --draft after a --basis any report, an operator reran under the default basis
# and drafted nothing. Unset, the line names this run instead, and HINT_FLAGS is
# how it carries this run's own flags.
drift_command=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   check_only=1 ;;
    --drifted) check_only=1; list_only=1; quiet=1 ;;
    --bundle)  shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1"
               hint_flag --bundle "$1" ;;
    --gap-terms) shift; [ $# -gt 0 ] || orc_die "--gap-terms needs a file"; gap_terms="$1" ;;
    --answers) shift; [ $# -gt 0 ] || orc_die "--answers needs a file"; answers="$1" ;;
    --drift-command) shift; [ $# -gt 0 ] || orc_die "--drift-command needs a command"; drift_command="$1" ;;
    --quiet)   quiet=1 ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    -*)        orc_die "unknown option: $1" ;;
    *)         wanted="$wanted $1"; hint_flag "$1" ;;
  esac
  shift
done

# --check, --drifted and --quiet are deliberately not carried: they are what made
# this run a report, and the command it names is the one that would draft.
if [ -z "$drift_command" ]; then
  if [ -n "$gap_terms" ]; then
    # A caller that ranked the terms and did not say how it was run. Nothing in
    # this repository takes that path, and naming this script would still be
    # wrong: run without --gap-terms it reports that nothing moved.
    drift_command="bin/orc-gap-loop.sh --draft"
  else
    drift_command="bin/orc-okf-draft.sh$HINT_FLAGS"
  fi
fi

# The producer, in §7's spelling. A stable id rather than a version hash: the
# actor says who made the content, and re-versioning it on every edit to this
# script would rewrite every concept for a reason no reader cares about.
PRODUCER="process:orc-okf-draft"

[ -z "$gap_terms" ] || [ -f "$gap_terms" ] || orc_die "--gap-terms names no file: $gap_terms"
[ -z "$answers" ] || [ -f "$answers" ] || orc_die "--answers names no file: $answers"

# Flat on purpose. Nothing here creates a subdirectory, so the cleanup is a
# plain rm -f and this script never needs a recursive remove - the one that
# lives in bin/orc-repos-sync.sh behind its own fence stays the only one.
WORK=$(mktemp -d) || orc_die "could not create a working directory"
# shellcheck disable=SC2329  # the EXIT trap below is the caller
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

# --- what a concept file already says ---------------------------------------

# A concept a human has verified is theirs. concept_is_verified lives in
# orc-lib.sh, because bin/orc-onboard.sh counts the same concepts before it
# discards a bundle and a refusal that disagreed with a discard about what
# "verified" means would be the worst pair of bugs available here.

concept_generated_at() {
  [ -f "$1" ] || return 0
  concept_frontmatter "$1" | awk '
    /^generated:[[:space:]]*\{/ {
      if (match($0, /at:[[:space:]]*[^,}[:space:]]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/at:[[:space:]]*/, "", s); print s; exit
      }
      next
    }
    /^generated:[[:space:]]*$/ { inb = 1; next }
    inb && /^[[:space:]]+at:[[:space:]]*/ {
      s = $0; sub(/^[[:space:]]*at:[[:space:]]*/, "", s); print s; exit
    }
    inb && /^[^[:space:]]/ { inb = 0 }
  '
}

# --- outcomes ---------------------------------------------------------------

rows=""          # concept<TAB>outcome<TAB>detail
skipped_drafts=""  # the concepts a human owns, reported rather than written
n_drafted=0 n_updated=0 n_unchanged=0 n_verified=0 n_unread=0
drift=0

row() { rows="$rows$1	$2	$3
"; }

# publish <relative path> <rendered body>
#
# The body arrives with @@AT@@ still in it. That is what makes a second run a
# no-op: the timestamp is filled in last, and when the rendered content matches
# what is already on disk the file keeps the date it already had. A generated:
# date records when this content was produced, so a rerun that produced the same
# content has no business moving it - and a bundle whose every file changes on
# every run is a diff nobody reads.
# The outcome of the last publish, for a caller that has to know whether this
# script owns the concept it just looked at. A listing that calls a verified
# concept "drafted" is the same contradiction in a smaller place.
PUBLISH_OUTCOME=""

publish() {
  local rel="$1" body="$2"
  local file old_at cand
  file="$BUNDLE/$rel"
  PUBLISH_OUTCOME="drafted"

  if concept_is_verified "$file"; then
    PUBLISH_OUTCOME="skipped-verified"
    n_verified=$(( n_verified + 1 ))
    row "$rel" "SKIPPED" "would have been re-drafted; left exactly as it was found"
    skipped_drafts="$skipped_drafts$rel
"
    return 0
  fi

  if [ -f "$file" ]; then
    old_at=$(concept_generated_at "$file")
    if [ -n "$old_at" ]; then
      printf '%s\n' "${body//@@AT@@/$old_at}" > "$WORK/candidate"
      if cmp -s "$WORK/candidate" "$file"; then
        PUBLISH_OUTCOME="unchanged"
        n_unchanged=$(( n_unchanged + 1 ))
        row "$rel" "unchanged" "the evidence has not moved since $old_at"
        return 0
      fi
    fi
  fi

  if [ "$check_only" = "1" ]; then
    drift=1
    if [ -f "$file" ]; then
      n_updated=$(( n_updated + 1 )); row "$rel" "would update" "the evidence moved"
    else
      n_drafted=$(( n_drafted + 1 )); row "$rel" "would draft" "not in the bundle yet"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$file")" || orc_die "could not create $(dirname "$file")"
  cand="${body//@@AT@@/$(orc_now)}"
  if [ -f "$file" ]; then
    PUBLISH_OUTCOME="updated"
    printf '%s\n' "$cand" > "$file" || orc_die "could not write $file"
    n_updated=$(( n_updated + 1 )); row "$rel" "updated" "the evidence moved"
  else
    printf '%s\n' "$cand" > "$file" || orc_die "could not write $file"
    n_drafted=$(( n_drafted + 1 )); row "$rel" "drafted" "new"
  fi
}

# --- the repositories worth reading -----------------------------------------
#
# Same discipline as refinement: a checkout that is not the code a ticket about
# it would be about is not read at all. A draft reasoned against a branch nobody
# is shipping is the failure this whole codebase is arranged to avoid, and it is
# worse here than in a verdict because a concept persists.

targets=""        # project<TAB>path<TAB>branch
unread=""         # project<TAB>why

for _p in $(project_names); do
  if [ -n "$wanted" ]; then
    case " $wanted " in *" $_p "*) : ;; *) continue ;; esac
  fi
  IFS=$'\t' read -r _st _sha _br _detail <<< "$(repo_state "$_p")"
  _path=$(project_repo_path "$_p")
  case "$_st" in
    ok|unmanaged)
      is_git_repo "$_path" || { unread="$unread$_p	$_path is not a git repository, so nothing in it can be cited
"; continue; }
      targets="$targets$_p	$_path	${_br:-detached}
"
      ;;
    # Nothing configured is a valid setup rather than a repository that failed
    # to appear: bin/orc-repos-sync.sh already says so, and repeating it here as
    # a failure would make an exit code out of a config that is simply quiet.
    unconfig) : ;;
    *)
      unread="$unread$_p	$_detail
"
      ;;
  esac
done
unset _p _st _sha _br _detail _path

n_unread=$(printf '%s' "$unread" | grep -c . | tr -d ' ')

target_names() { printf '%s' "$targets" | awk -F'\t' 'NF { print $1 }'; }
target_field() { printf '%s' "$targets" | awk -F'\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'; }

# --- what each repository is ------------------------------------------------

# The stack, from the file that decides it rather than from the language
# GitHub guesses. NativeScript is tested before Nuxt because a NativeScript-Vue
# app also carries a package.json full of Vue.
stack_of() {
  local p="$1"
  if [ -f "$p/Gemfile" ] && [ -f "$p/config/application.rb" ]; then printf 'Ruby on Rails'; return; fi
  if [ -f "$p/nativescript.config.ts" ] || [ -f "$p/nativescript.config.js" ]; then printf 'NativeScript (Vue)'; return; fi
  if [ -f "$p/nuxt.config.ts" ] || [ -f "$p/nuxt.config.js" ]; then printf 'Nuxt (Vue)'; return; fi
  if [ -f "$p/dbt_project.yml" ]; then printf 'dbt'; return; fi
  if [ -f "$p/package.json" ]; then printf 'Node'; return; fi
  printf 'not recognised from its tree'
}

stack_tag() {
  case "$1" in
    'Ruby on Rails') printf 'rails' ;;
    'NativeScript'*) printf 'nativescript' ;;
    'Nuxt'*)         printf 'nuxt' ;;
    'dbt')           printf 'dbt' ;;
    *)               printf 'unclassified' ;;
  esac
}

# The capability matrix, and the whole reason the negative half of a concept can
# be stated at all: id | what it is, in words a ticket would use | the paths that
# prove it. First path that exists wins, and it becomes the citation.
#
# Deliberately coarse. A finer matrix would be a concept per endpoint by another
# name, and the thing that stops a wrong file list is not detail - it is knowing
# that this repository decides nothing about permissions and that one does.
MARKERS='data-model|the domain records and their migrations|app/models db/migrate
http-api|the HTTP API the other surfaces call|app/controllers server/api server/routes
authorization|who may see and do what|app/models/ability.rb app/abilities app/policies
background-work|work that runs outside a request|app/workers app/jobs
transactional-email|transactional email|app/mailers
notifications|push and in-app notifications|app/notifications
web-screens|the web screens|pages layouts
mobile-screens|the mobile screens|src/pages app/screens
mobile-packaging|the store build and its native resources|App_Resources fastlane
client-state|client-side state held between screens|store stores src/stores app/stores
strings|a translatable string catalogue|config/locales locales i18n src/i18n app/i18n'

marker_ids()   { printf '%s\n' "$MARKERS" | awk -F'|' 'NF { print $1 }'; }
marker_label() { printf '%s\n' "$MARKERS" | awk -F'|' -v i="$1" '$1 == i { print $2; exit }'; }
marker_paths() { printf '%s\n' "$MARKERS" | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'; }

# The path inside <repo> that proves <marker>, or nothing.
marker_evidence() {
  local p="$1" id="$2" c
  for c in $(marker_paths "$id"); do
    [ -e "$p/$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# project<TAB>marker<TAB>evidence path, for every marker every readable
# repository proves. Built once: the negative half of a concept is a question
# about the other repositories, so no concept can be rendered until every
# repository has been looked at.
: > "$WORK/matrix"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  _path=$(target_field "$_n" 2)
  for _m in $(marker_ids); do
    _ev=$(marker_evidence "$_path" "$_m") && printf '%s\t%s\t%s\n' "$_n" "$_m" "$_ev" >> "$WORK/matrix"
  done
done < <(target_names)
unset _n _path _m _ev

has_marker() { awk -F'\t' -v n="$1" -v m="$2" '$1 == n && $2 == m { found = 1 } END { exit !found }' "$WORK/matrix"; }
evidence_of() { awk -F'\t' -v n="$1" -v m="$2" '$1 == n && $2 == m { print $3; exit }' "$WORK/matrix"; }
owners_of()  { awk -F'\t' -v m="$2" -v skip="$1" '$2 == m && $1 != skip { print $1 "\t" $3 }' "$WORK/matrix"; }

# --- citable addresses ------------------------------------------------------

# A source has to be reachable by somebody who is not this machine, so a path
# inside a repository is cited at its remote when there is one. Without a remote
# the local path is the honest answer: it is where the claim actually came from,
# and inventing a URL for it would be provenance nobody could follow.
repo_url() {
  local r
  r=$(project_field "$1" remote)
  [ -n "$r" ] || return 0
  remote_as_https "$r" | sed -e 's/\.git$//'
}

# What the concept claims to *be*, which OKF spells `resource:` and which is the
# only thing that lets anything tell two concepts about one repository apart.
# Always set, so the identity is never missing: the remote when there is one,
# and otherwise the path the config itself names. A project with no remote is an
# unmanaged checkout whose path came out of config/projects.yml, so writing it
# here puts nothing machine-specific in the bundle that the config did not
# already have.
repo_identity() {
  local url
  url=$(repo_url "$1")
  if [ -n "$url" ]; then printf '%s' "$url"; else printf '%s' "$(target_field "$1" 2)"; fi
}

tree_resource() {
  local name="$1" url
  url=$(repo_url "$name")
  if [ -n "$url" ]; then
    printf '%s/tree/%s' "$url" "$(target_field "$name" 3)"
  else
    printf '%s' "$(target_field "$name" 2)"
  fi
}

# One file, at the branch a ticket about it would be about. A blob URL is
# retrievable, which is the whole test a source has to pass; the optional line
# anchor makes a claim about a comment block land on the comment block.
#
# A directory gets tree_path_resource instead: GitHub serves a directory under
# /tree/ and answers 404 for it under /blob/, and a source that 404s is worse
# than no source because it looks like one.
tree_path_resource() {
  local name="$1" rel="$2" url
  url=$(repo_url "$name")
  if [ -n "$url" ]; then
    printf '%s/tree/%s/%s' "$url" "$(target_field "$name" 3)" "$rel"
  else
    printf '%s/%s' "$(target_field "$name" 2)" "$rel"
  fi
}

blob_resource() {
  local name="$1" rel="$2" line="${3:-}" url
  url=$(repo_url "$name")
  if [ -n "$url" ]; then
    printf '%s/blob/%s/%s' "$url" "$(target_field "$name" 3)" "$rel"
    [ -n "$line" ] && printf '#L%s' "$line"
  else
    printf '%s/%s' "$(target_field "$name" 2)" "$rel"
    [ -n "$line" ] && printf ':%s' "$line"
  fi
}

# A frontmatter value, quoted.
#
# These values are prose read out of repositories, and prose contains colons.
# An unquoted YAML scalar carrying ": " is a parse error rather than a string,
# which fails the bundle at §11 condition 1 - the one conformance rule a
# consumer is not allowed to be tolerant about.
yaml_scalar() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# A cell in a markdown table. A pipe in a product string closes the column, and
# these strings are read out of repositories rather than written here.
md_cell() {
  printf '%s' "$1" | sed -e 's/|/\\|/g'
}

# --- the string catalogues, which are the product's own dictionary ----------
#
# The one artefact in the tree that already holds the translation the bundle
# needs: a product phrase on one side, the code key it is filed under on the
# other. Nothing was reading it.

LANGUAGES='de en es fr it nl pl'

catalogue_format() {
  case "$1" in
    *.yml|*.yaml) printf 'Rails YAML' ;;
    *.json)       printf 'JSON' ;;
    *.js|*.ts)    printf 'JavaScript module' ;;
    *)            printf 'unrecognised' ;;
  esac
}

# The language a catalogue file is for, from its name. A repository may spell it
# `en.default.json` rather than `en.json`, so the first two-letter component that
# is a language wins rather than the first component.
catalogue_language() {
  local base part
  base=$(printf '%s' "$1" | sed 's#.*/##')
  for part in $(printf '%s' "$base" | tr '.' ' '); do
    case " $LANGUAGES " in *" $part "*) printf '%s' "$part"; return 0 ;; esac
  done
  return 1
}

# repo<TAB>relative path<TAB>language, for every catalogue file every repository
# with a catalogue keeps.
catalogue_files_of() {
  local n="$1" p dir f rel lang
  p=$(target_field "$n" 2)
  dir=$(evidence_of "$n" strings)
  [ -n "$dir" ] || return 0
  [ -d "$p/$dir" ] || return 0
  find "$p/$dir" -maxdepth 2 -type f \( -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.js' \) 2>/dev/null \
    | sort | while IFS= read -r f; do
    rel=${f#"$p/"}
    lang=$(catalogue_language "$rel") || continue
    printf '%s\t%s\t%s\n' "$n" "$rel" "$lang"
  done
}

# keypath<TAB>value, out of a Rails YAML, a pretty-printed JSON or a JS module.
#
# One awk for all three, because all three carry their structure in the
# indentation and that is the only structure this needs. A real parser would buy
# nothing here: the question asked of a catalogue is "which key is this string
# filed under", and a line's indentation answers it.
#
# camelCase keys are folded to snake_case, because two of these catalogues spell
# `followUpTour` what the API spells `follow_up`, and a dictionary that cannot
# see through that spelling difference is a dictionary of one repository.
FLATTEN_AWK='
function unquote(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  sub(/,$/, "", s)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
  return s
}
function snake(k,  i, ch, out) {
  out = ""
  for (i = 1; i <= length(k); i++) {
    ch = substr(k, i, 1)
    if (ch ~ /[A-Z]/) out = out "_" tolower(ch); else out = out ch
  }
  gsub(/__+/, "_", out); gsub(/\._/, ".", out); sub(/^_/, "", out)
  return out
}
{
  line = $0
  if (line ~ /^[[:space:]]*$/) next
  if (line ~ /^[[:space:]]*(\/\/|#)/) next
  if (line ~ /^[[:space:]]*[]}][,;]?[[:space:]]*$/) next
  if (line ~ /^export default/) next
  if (line ~ /^[[:space:]]*[{[][[:space:]]*$/) next
  if (line ~ /^[[:space:]]*-[[:space:]]/) next

  indent = match(line, /[^ ]/) - 1
  body = substr(line, indent + 1)
  if (!match(body, /^("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z0-9_.@-]+)[[:space:]]*:/)) next
  raw = substr(body, RSTART, RLENGTH)
  sub(/[[:space:]]*:$/, "", raw)
  key = unquote(raw)
  rest = substr(body, RSTART + RLENGTH)
  sub(/^[[:space:]]*/, "", rest)

  depth = int(indent / 2)
  path[depth] = key
  for (d = depth + 1; d <= maxdepth; d++) path[d] = ""
  if (depth > maxdepth) maxdepth = depth

  if (rest == "" || rest ~ /^[{[]/) next
  val = unquote(rest)
  if (val == "") next
  out = ""
  for (d = 0; d <= depth; d++) {
    if (path[d] == "") continue
    out = (out == "" ? path[d] : out "." path[d])
  }
  sub(/^[a-z][a-z]\./, "", out)
  print snake(out) "\t" val
}'

# repo<TAB>language<TAB>keypath<TAB>value<TAB>relative path, for every string every
# catalogue holds. The path is last so that everything reading the first four
# fields is unaffected by its being there.
: > "$WORK/catalogues"
: > "$WORK/strings"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  catalogue_files_of "$_n" >> "$WORK/catalogues"
done < <(target_names)
while IFS=$'\t' read -r _n _rel _lang; do
  [ -n "$_n" ] || continue
  awk "$FLATTEN_AWK" "$(target_field "$_n" 2)/$_rel" 2>/dev/null \
    | awk -F'\t' -v n="$_n" -v l="$_lang" -v r="$_rel" 'NF == 2 { print n "\t" l "\t" $1 "\t" $2 "\t" r }' >> "$WORK/strings"
done < "$WORK/catalogues"
unset _n _rel _lang

catalogue_repos() { awk -F'\t' '{ print $1 }' "$WORK/catalogues" | sort -u; }
catalogue_langs_of() { awk -F'\t' -v n="$1" '$1 == n { print $3 }' "$WORK/catalogues" | sort -u; }

# --- the domain vocabulary the code declares --------------------------------
#
# The other half of the dictionary: the code keys a phrase can resolve *to*.
#
# Deliberately not "every identifier". A column name that thirty tables carry -
# `name`, `status`, `created_at`, `description` - is a field name rather than a
# domain term, and a dictionary entry mapping "Description" to `description` is
# the circular translation this script exists to stop writing. So a column earns
# a place only when at most GENERIC_COLUMN_MAX tables declare it; a model, a
# table, an enum, a frozen constant and a scope always do, because a human named
# each one after a thing in the domain.
GENERIC_COLUMN_MAX=2

SCHEMA_COLUMN_TYPES='string|bigint|integer|datetime|boolean|text|jsonb|json|decimal|float|date|uuid|time'

is_rails() { [ -f "$1/Gemfile" ] && [ -d "$1/app/models" ]; }

# The class a Rails file declares, from its path. The convention is the parser:
# app/models/medical_case/follow_up.rb is MedicalCase::FollowUp, and reading the
# `class` lines to learn the same thing would be a Ruby parser written in awk.
class_of_path() {
  printf '%s' "$1" | sed -e 's#^app/models/##' -e 's#\.rb$##' \
    | awk -F'/' '{
        out = ""
        for (i = 1; i <= NF; i++) {
          n = split($i, part, "_"); seg = ""
          for (j = 1; j <= n; j++) seg = seg toupper(substr(part[j], 1, 1)) substr(part[j], 2)
          out = (out == "" ? seg : out "::" seg)
        }
        print out
      }'
}

# term<TAB>kind, the domain vocabulary one Rails repository declares.
code_terms_of() {
  local p="$1"
  is_rails "$p" || return 0

  find "$p/app/models" -name '*.rb' 2>/dev/null \
    | sed -e 's#.*/##' -e 's/\.rb$//' | grep -v '^application_record$' | sed 's/$/\tmodel/'

  if [ -f "$p/db/schema.rb" ]; then
    awk -F'"' '/^  create_table /{ print $2 "\ttable"; t = $2; sub(/s$/, "", t); print t "\ttable" }' "$p/db/schema.rb"
    awk -F'"' -v types="$SCHEMA_COLUMN_TYPES" -v max="$GENERIC_COLUMN_MAX" '
      $0 ~ "^    t\\.(" types ") " { c = $2; sub(/_id$/, "", c); n[c]++ }
      END { for (k in n) if (n[k] <= max) print k "\tcolumn" }
    ' "$p/db/schema.rb"
  fi

  find "$p/app/models" -name '*.rb' 2>/dev/null | sort | while IFS= read -r f; do
    awk '
      /^[[:space:]]*enum[[:space:]]+:?[a-z_]+/ {
        name = $0
        sub(/^[[:space:]]*enum[[:space:]]+:?/, "", name)
        sub(/[^a-z_].*$/, "", name)
        print name "\tenum"
        inb = 1
        next
      }
      inb && /^[[:space:]]*[a-z_]+:[[:space:]]*[0-9-]/ {
        v = $0; sub(/^[[:space:]]*/, "", v); sub(/:.*$/, "", v)
        print v "\tenum"
      }
      inb && /^[[:space:]]*[]}]/ { inb = 0 }
      /^[[:space:]]*scope[[:space:]]+:[a-z_0-9]+/ {
        s = $0; sub(/^[[:space:]]*scope[[:space:]]+:/, "", s); sub(/[^a-z_0-9].*$/, "", s)
        print s "\tscope"
      }
      /^[[:space:]]*[A-Z][A-Z0-9_]+[[:space:]]*=/ {
        c = $0; sub(/^[[:space:]]*/, "", c); sub(/[[:space:]]*=.*$/, "", c)
        print tolower(c) "\tconstant"
      }
    ' "$f"
  done
}

: > "$WORK/terms"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  code_terms_of "$(target_field "$_n" 2)" >> "$WORK/terms"
done < <(target_names)
unset _n

# One line per term, with the most specific kind that claimed it. Underscores,
# letters and digits only, and at least five characters: a shorter word matches
# too many key paths to say anything, and a candidate carrying a dot could never
# be found by searching for it.
awk -F'\t' '
  BEGIN { split("model table enum constant scope column", order, " "); for (i in order) rank[order[i]] = i }
  $1 ~ /^[a-z][a-z0-9_]{4,}$/ {
    if (!($1 in best) || rank[$2] < rank[best[$1]]) best[$1] = $2
  }
  END { for (t in best) print t "\t" best[t] }
' "$WORK/terms" | sort > "$WORK/terms.sorted" && mv "$WORK/terms.sorted" "$WORK/terms"

# --- product phrase to code key ---------------------------------------------
#
# One rule decides what a phrase resolves to, and it is a rule about ambiguity
# rather than about frequency: every key the phrase is filed under must contain
# the term. A phrase that appears once under `follow_up` and once under
# `prescription` resolves to neither, and saying it resolves to one of them is
# the kind of confident wrong answer this bundle exists to prevent.
#
# And the same corroboration rule the bundle already used, kept: a phrase has to
# be said by at least two of the configured repositories. A string only one
# surface holds is that surface's copy, not the product's vocabulary - it earns
# a place on that subsystem's own concept instead, where it routes a ticket.
# Three words, because a name is at most three words and a fourth makes it a
# sentence. A sentence is copy: it belongs to the surface that says it, not to the
# product's vocabulary, and mapping one to a code key attaches a whole paragraph
# to whichever word happens to be in its key.
PHRASE_MAX_WORDS=3
PHRASE_MIN_REPOS=2
PHRASE_CAP=110

# Routing wants the opposite of a name: the longer and more distinctive a string
# is, the better it identifies the one surface that says it.
SURFACE_PHRASE_MAX_WORDS=6

# phrase<TAB>lang<TAB>term<TAB>kind<TAB>repos<TAB>hits<TAB>repo list<TAB>langs<TAB>example key
#
# Everything a row needs is accumulated as the lines go past. The version that
# worked it out in END, by scanning the repo set once per candidate pair, was
# quadratic in the size of two sets with tens of thousands of members each and
# did not finish.
PHRASE_AWK='
# An accented letter folds to its unaccented base, so a word and its accented
# spelling are one word rather than two. Byte pairs rather than a bracketed
# character class, because a multibyte character inside [...] is a locale
# question and this is not one: in UTF-8 the Latin-1 letters are C3 80-BF, and
# the two bytes the ranges skip - C3 97 and C3 B7 - are the multiplication and
# division signs rather than letters.
function ascii(w,  t) {
  t = tolower(w)
  gsub("\303[\200-\205\240-\245]", "a", t)
  gsub("\303[\207\247]", "c", t)
  gsub("\303[\210-\213\250-\253]", "e", t)
  gsub("\303[\214-\217\254-\257]", "i", t)
  gsub("\303[\221\261]", "n", t)
  gsub("\303[\222-\226\262-\266]", "o", t)
  gsub("\303[\231-\234\271-\274]", "u", t)
  gsub("\303[\235\275\277]", "y", t)
  gsub("\303\237", "ss", t)
  gsub(/[^a-z0-9]/, "", t)
  return t
}
# A row saying the product word for X is X tells a reader nothing they did not
# have. Plurals and inflections count as the same word, which is why this is a
# prefix test rather than equality.
function circular(phrase, t,  a, b) {
  a = ascii(phrase); b = t; gsub(/_/, "", b)
  if (length(a) < 5 || length(b) < 5) return 0
  if (substr(a, 1, length(b)) == b) return 1
  if (substr(b, 1, length(a)) == a) return 1
  return 0
}
BEGIN {
  FS = "\t"
  while ((getline line < TERMS) > 0) { split(line, f, "\t"); term[++nt] = f[1]; kind[f[1]] = f[2] }
}
{
  repo = $1; lang = $2; key = $3; val = $4
  # A string carrying interpolation, markup or a URL is a template rather than a
  # phrase, and a template tokenises into things that are not words.
  if (val ~ /%|\{\{|<|http|[|]/) next
  gsub(/^[[:space:]]+|[[:space:]:!?.,;]+$/, "", val)
  if (length(val) < 4) next
  nw = split(val, w, /[[:space:]]+/)
  if (nw > MAXW) next
  # A multi-word string starting in lower case is the middle of a sentence,
  # broken across keys the way legal copy is. A single lower-case word is a value
  # label - "private", "statutory" - and stays.
  #
  # Lower case covers the accented letters too, as byte pairs rather than as a
  # bracketed character class, because a multibyte character inside [...] is a
  # locale question and this is not one. C3 9F-BF is every lower-case Latin-1
  # letter from the sharp s upwards, which is where an accented product word
  # starts.
  if (nw > 1 && val ~ "^([a-z]|\303[\237-\277])") next

  # The same key appears once per language, so the terms it spells are worked out
  # once and remembered.
  if (!(key in cached)) {
    hits = ""
    for (i = 1; i <= nt; i++) if (index(key, term[i])) hits = hits term[i] "\n"
    cached[key] = hits
  }
  if (!(lang SUBSEP key in keylang)) {
    keylang[lang SUBSEP key] = 1
    langsof[key] = langsof[key] lang " "
  }

  id = lang SUBSEP val
  total[id]++
  if (!(id SUBSEP key in haskey)) { haskey[id SUBSEP key] = 1; keysof[id] = keysof[id] key "\n" }

  nseg = split(key, seg, ".")
  n = split(cached[key], t, "\n")
  for (i = 1; i <= n; i++) {
    if (t[i] == "") continue
    pk = id SUBSEP t[i]
    hit[pk]++
    # Does the key name this term as its subject, or only as the field the string
    # fills? `follow_up_declined.body` is about a follow-up; `uv_index.description`
    # is a description of something else. Only the first routes anything.
    for (j = 1; j < nseg; j++) if (index(seg[j], t[i])) { inner[pk] = 1; break }
    if (!(pk SUBSEP repo in hasrepo)) {
      hasrepo[pk SUBSEP repo] = 1
      nrepo[pk]++
      repolist[pk] = repolist[pk] (repolist[pk] == "" ? "" : ", ") repo
    }
    example[pk] = key
  }
}
END {
  for (pk in hit) {
    split(pk, f, SUBSEP)
    id = f[1] SUBSEP f[2]
    if (hit[pk] != total[id]) continue        # the phrase is filed elsewhere too
    if (nrepo[pk] < MINREPOS) continue
    if (circular(f[2], f[3])) continue
    # A single word is a term whatever position the key spells it in. A phrase is
    # only a term when the key is about it.
    if (split(f[2], w, /[[:space:]]+/) > 1 && !(pk in inner)) continue
    # Of the terms that qualify, the longest is the most specific: a phrase under
    # `insurance_number` is also under `insurance`, and only one of those two is
    # worth searching for.
    if (length(f[3]) > length(bestterm[id])) { bestterm[id] = f[3]; best[id] = pk }
  }
  for (id in bestterm) {
    split(id, f, SUBSEP)
    pk = best[id]
    nk = split(keysof[id], ks, "\n")
    langs = ""
    delete seen
    for (i = 1; i <= nk; i++) {
      if (ks[i] == "") continue
      nl = split(langsof[ks[i]], ls, " ")
      for (j = 1; j <= nl; j++) if (ls[j] != "" && !(ls[j] in seen)) { seen[ls[j]] = 1; langs = langs (langs == "" ? "" : " ") ls[j] }
    }
    printf "%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\n", \
      f[2], f[1], bestterm[id], kind[bestterm[id]], nrepo[pk], hit[pk], repolist[pk], langs, example[pk]
  }
}'

if [ -s "$WORK/terms" ] && [ -s "$WORK/strings" ]; then
  awk -v TERMS="$WORK/terms" -v MAXW="$PHRASE_MAX_WORDS" -v MINREPOS="$PHRASE_MIN_REPOS" \
      "$PHRASE_AWK" "$WORK/strings" > "$WORK/phrases.all"
else
  : > "$WORK/phrases.all"
fi

# Selected by strength - how many repositories say it, then how many entries -
# and then printed in the order a dictionary is read. Both the cap and what it
# dropped are stated in the drafted file, because a table that stops at a
# hundred rows without saying so reads as a table that found a hundred things.
sort -t'	' -k5,5nr -k6,6nr -k1,1 "$WORK/phrases.all" | head -"$PHRASE_CAP" \
  | sort -t'	' -k3,3 -k1,1 > "$WORK/phrases"
n_phrases_all=$(grep -c . "$WORK/phrases.all" | tr -d ' ')
n_phrases=$(grep -c . "$WORK/phrases" | tr -d ' ')

# The phrases one surface says and no other. Not corroborated by a second
# repository, and that is exactly what makes them useful here: an uncorroborated
# string cannot tell you what the product calls something, but it can tell you
# which repository a ticket quoting it is about.
#
# Selected longest first, which is the opposite of the dictionary's rule and right
# for the opposite reason: "Learn more" sits on every surface's button and
# identifies nothing, while a five-word string that appears in exactly one
# catalogue is as close to a fingerprint as a string gets.
SURFACE_PHRASE_CAP=15
SURFACE_PHRASE_AWK='
BEGIN {
  FS = "\t"
  while ((getline line < TERMS) > 0) { split(line, f, "\t"); term[++nt] = f[1] }
}
{
  repo = $1; key = $3; val = $4
  if (val ~ /%\{|\{\{|<|http|[|]/) next
  gsub(/^[[:space:]]+|[[:space:]:!?.,;]+$/, "", val)
  if (length(val) < 10) next
  if (split(val, w, /[[:space:]]+/) < 2) next
  if (split(val, w, /[[:space:]]+/) > MAXW) next
  if (!(key in cached)) {
    cached[key] = 0
    for (i = 1; i <= nt; i++) if (index(key, term[i])) { cached[key] = 1; break }
  }
  if (!cached[key]) next
  if (!(val SUBSEP repo in seenpair)) { seenpair[val SUBSEP repo] = 1; nrepo[val]++; onerepo[val] = repo }
  count[val SUBSEP repo]++
  where[val SUBSEP repo] = key
}
END {
  for (v in nrepo) {
    if (nrepo[v] != 1) continue
    r = onerepo[v]
    printf "%s\t%s\t%d\t%s\n", r, v, length(v), where[v SUBSEP r]
  }
}'

if [ -s "$WORK/terms" ] && [ -s "$WORK/strings" ]; then
  awk -v TERMS="$WORK/terms" -v MAXW="$SURFACE_PHRASE_MAX_WORDS" "$SURFACE_PHRASE_AWK" "$WORK/strings" \
    | sort -t'	' -k1,1 -k3,3nr -k2,2 > "$WORK/surface-phrases"
else
  : > "$WORK/surface-phrases"
fi

# --- what the evidence says about a word refinement could not resolve --------
#
# bin/orc-gap-loop.sh ranks the words real tickets used that this bundle could
# not explain. It decides which of them recur and which are worth asking about;
# this decides what the repositories actually say about each one, which is the
# half that has to be evidence rather than frequency.
#
# Five findings, and the drafted row says which one it is. Only the first is an
# answer:
#
#   below the cap   every catalogue key the phrase appears under names the same
#                   code key, and at least PHRASE_MIN_REPOS repositories say it -
#                   so the dictionary's own rule resolves it, and the only reason
#                   it is not in the product vocabulary is that PHRASE_CAP cut
#                   the table. That is a resolution, and the strongest kind
#                   available here, because it passed the same ambiguity and
#                   corroboration rules every other row did.
#   an identifier   the code declares something whose name folds to this word.
#                   A lead: it is what to search for, and whether it is what the
#                   reporter meant is not established.
#   said and unfiled  two or more repositories say the word, under keys that name
#                   nothing the code declares. The word is the product's; what it
#                   means in code is not established, and that is a question for
#                   a person.
#   one surface     one repository says it. That is that surface's copy rather
#                   than the product's word - it routes a ticket and defines
#                   nothing, the same reading the subsystem concepts already give
#                   an uncorroborated string.
#   nothing at all  no configured repository says the word in any form. Either it
#                   is said somewhere that has no catalogue, or it is not the
#                   product's word, and nothing here can tell those apart.
#
# A term is never promoted past the finding its evidence supports. That is the
# same rule the retirement section already follows: a word the evidence cannot
# establish is said to be unestablished, because a concept asserting a meaning it
# cannot support is worse than no concept - you cannot tell which answer you got.
#
# display \002 tickets \002 runs \002 capped key \002 capped repos \002
# identifier \002 kind \002 repos \002 repo list \002 example keys
#
# \002 rather than a tab, and not as a style choice: six of those ten fields are
# empty on a term the evidence says nothing about, and `IFS=$'\t' read` collapses
# a run of tabs and shifts every later field one to the left - the same trap the
# constants reader below has to avoid, for the same reason.
GAP_FS=$'\002'
GAP_EVIDENCE_AWK='
function says(hay, needle) { return index(" " hay, " " needle) > 0 }
BEGIN { FS = "\t" }
FILENAME == GAPS {
  n++
  disp[n] = $1; fold[n] = $2; tickets[n] = $3; runs[n] = $4
  next
}
FILENAME == PHRASES_ALL {
  p = orc_fold($1)
  for (i = 1; i <= n; i++) {
    if (p != fold[i]) continue
    if (length($3) > length(capkey[i])) { capkey[i] = $3; caprepos[i] = $5 }
  }
  next
}
FILENAME == PHRASES_KEPT {
  p = orc_fold($1)
  for (i = 1; i <= n; i++) if (p == fold[i]) inbook[i] = 1
  next
}
FILENAME == CODE_TERMS {
  c = orc_fold($1)
  for (i = 1; i <= n; i++) if (c == fold[i]) { ident[i] = $1; kind[i] = $2 }
  next
}
FILENAME == STRINGS {
  v = orc_fold($4)
  for (i = 1; i <= n; i++) {
    if (!says(v, fold[i])) continue
    if (!((i SUBSEP $1) in seenrepo)) {
      seenrepo[i SUBSEP $1] = 1
      nrepo[i]++
      repolist[i] = repolist[i] (repolist[i] == "" ? "" : ", ") $1
    }
    if (nkeys[i] < KEYCAP && !((i SUBSEP $3) in seenkey)) {
      seenkey[i SUBSEP $3] = 1
      nkeys[i]++
      keylist[i] = keylist[i] (keylist[i] == "" ? "" : ", ") $3
    }
  }
  next
}
END {
  for (i = 1; i <= n; i++) {
    # A phrase the kept table already carries is in the bundle, so it is not
    # below the cap - it is in the book, and the gap loop excludes those anyway.
    if (inbook[i]) { capkey[i] = ""; caprepos[i] = "" }
    printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%d%s%s%s%s\n", \
      disp[i], FS2, tickets[i], FS2, runs[i], FS2, capkey[i], FS2, caprepos[i], FS2, \
      ident[i], FS2, kind[i], FS2, nrepo[i] + 0, FS2, repolist[i], FS2, keylist[i]
  }
}'

# At most three keys per term. A row is read by somebody deciding whether the
# word is worth a concept, and a list of forty catalogue keys answers a different
# question than the one they asked.
GAP_KEY_CAP=3

# Copied rather than read in place, so the renderer names one path and a caller
# that hands over a temporary file is not depended on for the length of the run.
: > "$WORK/answer-rows"
[ -n "$answers" ] && [ -s "$answers" ] && cat "$answers" > "$WORK/answer-rows"

: > "$WORK/gap-rows"
if [ -n "$gap_terms" ] && [ -s "$gap_terms" ]; then
  awk -v GAPS="$gap_terms" -v PHRASES_ALL="$WORK/phrases.all" \
      -v PHRASES_KEPT="$WORK/phrases" -v CODE_TERMS="$WORK/terms" \
      -v STRINGS="$WORK/strings" -v KEYCAP="$GAP_KEY_CAP" -v FS2="$GAP_FS" \
      "$ORC_FOLD_AWK$GAP_EVIDENCE_AWK" \
      "$gap_terms" "$WORK/phrases.all" "$WORK/phrases" "$WORK/terms" "$WORK/strings" \
    > "$WORK/gap-rows"
fi

# --- the domain rules a model writes down -----------------------------------
#
# A frozen constant is a domain vocabulary somebody decided on, and the comment
# above it is the only place the reasoning is written down at all. Both are read
# verbatim: paraphrasing a comment about which recommendation categories offer a
# follow-up would be this script deciding what the domain means.

CONSTANT_COMMENT_MAX=24

# repo \002 relpath \002 line \002 class \002 constant \002 values \002 comment
#
# \002 rather than a tab, and that is not a style choice. A tab is IFS whitespace,
# so `IFS=$'\t' read` collapses a run of them and an empty field in the middle of
# a record silently shifts every field after it left by one. A constant with no
# values is exactly that case. \001 carries the newlines inside the comment, which
# is multi-line while everything else here is one record per line.
CONSTANT_FS=$'\002'
constants_of() {
  local p="$1" f rel cls
  is_rails "$p" || return 0
  find "$p/app/models" -name '*.rb' 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$p/"}
    cls=$(class_of_path "$rel")
    awk -v rel="$rel" -v cls="$cls" -v cmax="$CONSTANT_COMMENT_MAX" -v fs="$CONSTANT_FS" '
      function flush() { delete com; ncom = 0 }
      /^[[:space:]]*#/ {
        line = $0; sub(/^[[:space:]]*#[[:space:]]?/, "", line)
        com[++ncom] = line
        next
      }
      /^[[:space:]]*$/ { flush(); next }
      /^[[:space:]]*[A-Z][A-Z0-9_]+[[:space:]]*=/ {
        name = $0; sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*=.*$/, "", name)
        text = $0; sub(/^[^=]*=[[:space:]]*/, "", text)
        start = NR
        # The value may span lines. It ends where the brackets balance, which is
        # cheaper to count than to parse and is exact for a literal.
        buf = text
        for (;;) {
          depth = 0
          n = length(buf)
          for (i = 1; i <= n; i++) {
            ch = substr(buf, i, 1)
            if (ch == "{" || ch == "[" || ch == "(") depth++
            else if (ch == "}" || ch == "]" || ch == ")") depth--
          }
          if (depth <= 0) break
          if ((getline nxt) <= 0) break
          sub(/^[[:space:]]*/, "", nxt)
          buf = buf " " nxt
        }
        c = ""
        if (ncom > 0 && ncom <= cmax) { for (i = 1; i <= ncom; i++) c = c (i > 1 ? "\001" : "") com[i] }
        long = (ncom > cmax) ? ncom : 0
        print rel fs start fs cls fs name fs buf fs long fs c
        flush()
        next
      }
      { flush() }
    ' "$f"
  done
}

: > "$WORK/constants"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  constants_of "$(target_field "$_n" 2)" | sed "s#^#$_n$CONSTANT_FS#" >> "$WORK/constants"
done < <(target_names)
unset _n

# The values a constant enumerates, in the spelling a reader would search for.
# A map is printed as its pairs because the mapping *is* the fact: `cat3` means
# `onsite` is the whole content of TICKET_CATEGORIES.
CONSTANT_VALUES_AWK='
{
  text = $0
  if (text ~ /=>/) {
    out = ""
    while (match(text, /'"'"'[^'"'"']+'"'"'[[:space:]]*=>[[:space:]]*('"'"'[^'"'"']*'"'"'|nil|\[\]|[A-Za-z0-9_.]+)/)) {
      pair = substr(text, RSTART, RLENGTH)
      text = substr(text, RSTART + RLENGTH)
      gsub(/'"'"'/, "", pair); gsub(/[[:space:]]*=>[[:space:]]*/, " to ", pair)
      out = out (out == "" ? "" : ", ") pair
    }
    print out
    next
  }
  if (match(text, /%w\[[^]]*\]/)) {
    v = substr(text, RSTART + 3, RLENGTH - 4)
    gsub(/[[:space:]]+/, ", ", v); gsub(/^, |, $/, "", v)
    print v
    next
  }
  out = ""
  while (match(text, /'"'"'[^'"'"']*'"'"'|"[^"]*"/)) {
    v = substr(text, RSTART + 1, RLENGTH - 2)
    text = substr(text, RSTART + RLENGTH)
    if (v != "") out = out (out == "" ? "" : ", ") v
  }
  print out
}'

constant_values() { printf '%s\n' "$1" | awk "$CONSTANT_VALUES_AWK"; }

# A constant enumerating fourteen mappings of four keys each is a dump nobody
# reads, and the file it came from is one click away. The cap is stated in the
# text it produces rather than applied silently.
CONSTANT_VALUE_CAP=24
constant_values_capped() {
  printf '%s' "$1" | awk -F', ' -v cap="$CONSTANT_VALUE_CAP" '
    NF <= cap { print; next }
    {
      out = $1
      for (i = 2; i <= cap; i++) out = out ", " $i
      printf "%s, and %d more\n", out, NF - cap
    }'
}

# A constant earns a row when a human wrote a comment above it, or when one of
# its values surfaces in the product's own strings - a value that reached a key
# path in a catalogue crossed from the code into what a person reads, which is
# the same corroboration test the phrase table uses, run the other way.
: > "$WORK/keytokens"
awk -F'\t' '{ n = split($3, p, /[._]/); for (i = 1; i <= n; i++) if (length(p[i]) >= 4) print p[i] }' \
  "$WORK/strings" 2>/dev/null | sort -u > "$WORK/keytokens"

constant_is_surfaced() {
  local v
  for v in $(printf '%s' "$1" | tr ',' ' '); do
    [ ${#v} -ge 4 ] || continue
    grep -qxF "$v" "$WORK/keytokens" && return 0
  done
  return 1
}

# --- the schema constraints that are rules ----------------------------------
#
# Most of a schema is layout. A handful of lines in it are rules nobody wrote
# down anywhere else: a unique index with a WHERE clause says at most one row may
# exist in a named state, and a check constraint says what a row may not be.
#
# The NOT NULL columns of such a table are reported with them, and only of such a
# table. Fifty-nine required foreign keys across a schema is a listing; the four
# on a table whose uniqueness is already conditional are the rest of one rule.
SCHEMA_RULES_AWK='
/^  create_table "/ { t = $0; sub(/^  create_table "/, "", t); sub(/".*$/, "", t); next }
/^    t\.index .*unique: true/ {
  cols = $0; sub(/^[^[]*\[/, "", cols); sub(/\].*$/, "", cols); gsub(/"/, "", cols)
  if ($0 ~ /where: /) {
    w = $0; sub(/^.*where: "/, "", w); sub(/".*$/, "", w)
    print t "\tpartial-unique\t" cols "\t" w
  } else if (cols ~ /, /) {
    print t "\tcomposite-unique\t" cols "\t"
  }
  next
}
/^    t\.check_constraint / {
  c = $0; sub(/^[[:space:]]*t\.check_constraint "/, "", c); sub(/", name:.*$/, "", c); sub(/"$/, "", c)
  print t "\tcheck\t\t" c
  next
}
$0 ~ ("^    t\\.(" types ") .*null: false") {
  c = $0; sub(/^[^"]*"/, "", c); sub(/".*$/, "", c)
  print t "\trequired\t" c "\t"
  next
}'

: > "$WORK/schema-rules"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  _path=$(target_field "$_n" 2)
  [ -f "$_path/db/schema.rb" ] || continue
  awk -v types="$SCHEMA_COLUMN_TYPES" "$SCHEMA_RULES_AWK" "$_path/db/schema.rb" \
    | sed "s#^#$_n	#" >> "$WORK/schema-rules"
done < <(target_names)
unset _n _path

# The tables whose schema is already known to encode a rule. Their required
# columns are part of that rule; every other table's are layout.
awk -F'\t' '$3 == "partial-unique" || $3 == "check" { print $1 "\t" $2 }' "$WORK/schema-rules" \
  | sort -u > "$WORK/ruled-tables"

# --- vocabulary the evidence says is not live -------------------------------
#
# The trap this exists for: a word that means one thing in code somebody is
# shipping and another in rows nobody has written in five years. A ticket using
# it is ambiguous in a way that decides the verdict, so a concept asserting
# either meaning is worse than no concept - and the ambiguity itself is a fact a
# generator can see.
#
# The unit is an entity: something a migration once created a table for. That is
# the level at which the ambiguity bites - a ticket says "aftercare" and means
# either a kind of case or a kind of row - and it is also the filter that keeps
# this section short, because `legacy_values` in a rake task names no entity and
# is therefore not a finding.
#
# Two signals nominate such an entity, and both are somebody's deliberate act
# rather than an inference:
#
#   an identifier filters it out. A `without_legacy_aftercares` scope exists
#     because live code has to exclude aftercares from what it counts, and the
#     identifier names the thing being excluded.
#   neither the table nor a model for it is in the tree now, and the files named
#     after it are cold. Whatever is left of it is rows. Cold is required here
#     and not above: a dropped table whose name is still being touched every
#     month is live vocabulary that moved, not vocabulary that was retired.
#
# A third signal only ever enriches a term one of those two already nominated: a
# comment saying something is deprecated. Every repository has forty of those and
# most are about a mobile app version, so a comment that nominated on its own
# would fill this section with noise and teach a reader to skip it.
#
# And one measurement reported alongside rather than as a signal: when the files
# named after the term were last committed, against when the repository was.
# Cold files prove nothing on their own - plenty of correct code is old - but
# next to a scope that filters the term out they say which way it went.
RETIREMENT_COLD_DAYS=365

# The word a legacy identifier is about, or nothing.
#
# `without_legacy_aftercares` is about aftercares. `JSON_TO_LEGACY` is about a
# serialisation format, `presentation_needed_legacy_key` is about a key, and
# neither is a domain term - which is why the captured part has to be a single
# word of at least five letters. Precision over recall on purpose: a term wrongly
# called retired sends a refiner to ask a question that did not need asking, and
# the drafted section says in words that it is a floor.
RETIRED_FROM_IDENTIFIER='
function retired_term(id,   lower, t) {
  lower = tolower(id)
  if (match(lower, /legacy_[a-z0-9_]+$/)) t = substr(lower, RSTART + 7)
  else if (match(lower, /^[a-z0-9_]+_legacy$/)) { t = lower; sub(/_legacy$/, "", t) }
  else return ""
  if (t ~ /_/) return ""
  sub(/s$/, "", t)
  if (length(t) < 5) return ""
  return t
}'

# When were the files named after this term last committed, and when was the
# repository? git log against a pathspec, which git_read allows and which is the
# only measurement here that needs git at all.
term_last_commit() {
  local n="$1" term="$2" p
  p=$(target_field "$n" 2)
  git_read "$p" log -1 --format=%cd --date=short -- "*${term}*" 2>/dev/null
}
repo_last_commit() {
  git_read "$(target_field "$1" 2)" log -1 --format=%cd --date=short 2>/dev/null
}

days_between() {
  local a="$1" b="$2" ax bx
  ax=$(printf '%s' "$a" | tr -d '-'); bx=$(printf '%s' "$b" | tr -d '-')
  [ -n "$ax" ] && [ -n "$bx" ] || return 1
  awk -v a="$ax" -v b="$bx" 'BEGIN {
    ya = substr(a,1,4); ma = substr(a,5,2); da = substr(a,7,2)
    yb = substr(b,1,4); mb = substr(b,5,2); db = substr(b,7,2)
    print int((yb - ya) * 365.25 + (mb - ma) * 30.44 + (db - da))
  }'
}

# Cold means: nobody has touched a file named after it in RETIREMENT_COLD_DAYS,
# measured against the repository's own last commit rather than against today, so
# an old checkout does not make everything in it look retired.
term_is_cold() {
  local when head age
  when=$(term_last_commit "$1" "$2")
  head=$(repo_last_commit "$1")
  [ -n "$when" ] && [ -n "$head" ] || return 1
  age=$(days_between "$when" "$head")
  [ -n "$age" ] && [ "$age" -ge "$RETIREMENT_COLD_DAYS" ]
}

# The entities a migration ever created a table for: term<TAB>plural<TAB>date.
# Single-word names only - a `join_table_medical_case_therapy` is plumbing rather
# than a thing anybody writes a ticket about.
entities_ever_created() {
  local p="$1"
  [ -d "$p/db/migrate" ] || return 0
  find "$p/db/migrate" -name '*_create_*.rb' 2>/dev/null | sed 's#.*/##' | sort | awk '
    {
      stamp = substr($0, 1, 8)
      plural = $0; sub(/^[0-9]+_create_/, "", plural); sub(/\.rb$/, "", plural)
      if (plural ~ /_/ || length(plural) < 6) next
      name = plural; sub(/s$/, "", name)
      printf "%s\t%s\t%s-%s-%s\t%s\n", name, plural, substr(stamp,1,4), substr(stamp,5,2), substr(stamp,7,2), $0
    }'
}

# repo<TAB>term<TAB>signal<TAB>detail<TAB>relpath<TAB>line
retirement_signals_of() {
  local n="$1" p term plural detail file
  p=$(target_field "$n" 2)
  is_rails "$p" || return 0
  entities_ever_created "$p" | cut -f1 | sort -u > "$WORK/entities.$$"

  # One grep for the whole repository rather than one per term. Identifiers, not
  # words: the thing being excluded is spelled inside the identifier that
  # excludes it, so splitting on the underscore first would lose exactly the
  # evidence being looked for.
  grep -rnE '[A-Za-z0-9_]*[Ll]egacy[A-Za-z0-9_]*|[A-Za-z0-9_]*LEGACY[A-Za-z0-9_]*' \
    "$p/app" "$p/lib" 2>/dev/null \
    | awk -v plen="${#p}" -v entities="$WORK/entities.$$" "$RETIRED_FROM_IDENTIFIER"'
        BEGIN { while ((getline e < entities) > 0) entity[e] = 1 }
        {
          colon = index($0, ":")
          file = substr($0, plen + 2, colon - plen - 2)
          rest = substr($0, colon + 1)
          lineno = substr(rest, 1, index(rest, ":") - 1)
          text = substr(rest, index(rest, ":") + 1)
          nid = split(text, ids, /[^A-Za-z0-9_]+/)
          for (i = 1; i <= nid; i++) {
            t = retired_term(ids[i])
            if (t == "" || !(t in entity)) continue
            print t "\tfiltered-out\t" ids[i] "\t" file "\t" lineno
          }
        }' | sort -u -t'	' -k1,1 -k3,3

  # An entity whose table and model are both gone, and whose files nobody has
  # touched in a year. What is left of it is rows, and the migration's own
  # filename dates it.
  entities_ever_created "$p" | while IFS=$'\t' read -r term plural detail file; do
    [ -n "$term" ] || continue
    [ -f "$p/app/models/$term.rb" ] && continue
    grep -qE "^  create_table \"$plural\"" "$p/db/schema.rb" 2>/dev/null && continue
    grep -qE "^  create_table \"$term\"" "$p/db/schema.rb" 2>/dev/null && continue
    term_is_cold "$n" "$term" || continue
    printf '%s\tmigration-only\t%s created a table called `%s`\tdb/migrate/%s\t\n' "$term" "$detail" "$plural" "$file"
  done

  rm -f "$WORK/entities.$$"
}

: > "$WORK/retired.raw"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  retirement_signals_of "$_n" | sed "s#^#$_n	#" >> "$WORK/retired.raw"
done < <(target_names)
unset _n

awk -F'\t' '$3 == "filtered-out" || $3 == "migration-only" { print $2 }' "$WORK/retired.raw" \
  | sort -u > "$WORK/retired.terms"

# Now, and only now, the comments. A comment saying something is deprecated is
# evidence about a term already nominated and nomination material about nothing:
# left to nominate, it would list every mobile app version anybody ever waited to
# stop supporting.
if [ -s "$WORK/retired.terms" ]; then
  while IFS= read -r _n; do
    [ -n "$_n" ] || continue
    _path=$(target_field "$_n" 2)
    is_rails "$_path" || continue
    grep -rnE '^[[:space:]]*#.*(deprecat|Deprecat|legacy|Legacy|obsolete|no longer)' \
      "$_path/app" "$_path/lib" 2>/dev/null \
      | awk -v plen="${#_path}" -v want="$WORK/retired.terms" '
          BEGIN { while ((getline t < want) > 0) term[t] = 1 }
          {
            colon = index($0, ":")
            file = substr($0, plen + 2, colon - plen - 2)
            rest = substr($0, colon + 1)
            lineno = substr(rest, 1, index(rest, ":") - 1)
            text = substr(rest, index(rest, ":") + 1)
            sub(/^[[:space:]]*#[[:space:]]?/, "", text)
            ntok = split(text, tok, /[^A-Za-z0-9]+/)
            delete said
            for (i = 1; i <= ntok; i++) {
              t = tolower(tok[i]); sub(/s$/, "", t)
              if (!(t in term) || (t in said)) continue
              said[t] = 1
              print t "\tdeprecation-comment\t" text "\t" file "\t" lineno
            }
          }' | sed "s#^#$_n	#" >> "$WORK/retired.raw"
  done < <(target_names)
  unset _n _path
fi

# --- one subsystem concept --------------------------------------------------

# What this repository is, in one sentence, from the markers rather than from a
# guess about its name. A repository whose tree says nothing recognisable gets a
# sentence saying exactly that, because "not classified" is a true statement and
# an invented role is not.
role_sentence() {
  local n="$1"
  if has_marker "$n" data-model && has_marker "$n" http-api; then
    printf 'the system of record: it holds the domain records and serves the HTTP API every other surface reads'
  elif has_marker "$n" mobile-screens && has_marker "$n" mobile-packaging; then
    printf 'a packaged mobile client: it renders screens against the API and ships through the app stores'
  elif has_marker "$n" web-screens; then
    printf 'a web client: it renders screens against the API and holds no record of its own'
  elif has_marker "$n" mobile-screens; then
    printf 'a mobile client: it renders screens against the API and holds no record of its own'
  elif has_marker "$n" data-model; then
    printf 'a data-owning service: it holds domain records but serves no HTTP API of its own'
  else
    printf 'not classified by this draft: none of the markers that would place it were found in its tree'
  fi
}

render_subsystem() {
  local n="$1" path branch stack tag role m ev owners cat nsurface

  path=$(target_field "$n" 2)
  branch=$(target_field "$n" 3)
  stack=$(stack_of "$path")
  tag=$(stack_tag "$stack")
  role=$(role_sentence "$n")
  cat=$(evidence_of "$n" strings)
  nsurface=$(awk -F'\t' -v n="$n" '$1 == n' "$WORK/surface-phrases" | grep -c . | tr -d ' ')

  printf -- '---\n'
  printf 'type: Subsystem\n'
  printf 'title: %s\n' "$(yaml_scalar "$n")"
  printf 'description: %s\n' "$(yaml_scalar "$stack - $role.")"
  printf 'resource: %s\n' "$(repo_identity "$n")"
  printf 'tags: [drafted, subsystem, %s]\n' "$tag"
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'
  printf -- '  - id: %s-tree\n    title: %s\n    resource: %s\n' \
    "$n" "$(yaml_scalar "$n, on the branch it releases from")" "$(yaml_scalar "$(tree_resource "$n")")"
  if [ "$nsurface" -gt 0 ]; then
    printf -- '  - id: %s-strings\n    title: %s\n    resource: %s\n' \
      "$n" "$(yaml_scalar "the string catalogue $n keeps")" "$(yaml_scalar "$(tree_path_resource "$n" "$cat")")"
  fi
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified.** Everything below was read out of the repository by
\`bin/orc-okf-draft.sh\`; nobody has checked it. Treat a claim here as a
lead, not as a fact, until this concept carries a \`verified:\` date.

\`$n\` is $stack, and it is $role.[^$n-tree]

It releases from \`$branch\`. A ticket about this repository is a ticket about
that branch, and no commit is named here on purpose: a concept describes what a
repository owns, which does not change when somebody pushes.

# What it does not own

The half that stops a wrong file list. A ticket whose subject is one of these
does not belong here however plausibly it is worded, and the repository that
does own it is named.[^$n-tree]

EOF

  printf '| Not here | Where it is instead |\n|---|---|\n'
  local none=1
  for m in $(marker_ids); do
    has_marker "$n" "$m" && continue
    owners=$(owners_of "$n" "$m" | awk -F'\t' '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 } END { print "" }')
    [ -n "$owners" ] || continue
    none=0
    printf '| %s | %s |\n' "$(marker_label "$m")" "$owners"
  done
  [ "$none" = "1" ] && printf '| - | Nothing the other configured repositories have is missing here. |\n'

  printf '\n# What it does own\n\n'
  printf '| Capability | Where it is here |\n|---|---|\n'
  for m in $(marker_ids); do
    ev=$(evidence_of "$n" "$m") || true
    [ -n "$ev" ] || continue
    printf '| %s | `%s` |\n' "$(marker_label "$m")" "$ev"
  done
  printf '\nA directory, not a file list.[^%s-tree] The files under it are what a\n' "$n"
  printf 'search is for, and a listing of them in a concept would be stale by the time\n'
  printf 'anybody read it.\n'

  if [ "$nsurface" -gt 0 ]; then
    cat <<EOF

# Phrases only this surface says

Product strings that are in this repository's catalogue and in no other
configured repository's.[^$n-strings] They are not the product's shared
vocabulary - [the product vocabulary](/domain/product-vocabulary.md) is - and
that is what makes them useful here: a ticket quoting one of them is a ticket
about this repository, because nothing else says it.

EOF
    printf '| Phrase | Filed under |\n|---|---|\n'
    awk -F'\t' -v n="$n" -v cap="$SURFACE_PHRASE_CAP" '
      $1 == n && shown < cap { shown++; v = $2; gsub(/\|/, "\\|", v); printf "| %s | `%s` |\n", v, $4 }
    ' "$WORK/surface-phrases"
    if [ "$nsurface" -gt "$SURFACE_PHRASE_CAP" ]; then
      printf '\n%s of %s shown, longest first: length is what makes a string identify\n' \
        "$SURFACE_PHRASE_CAP" "$nsurface"
      printf 'one surface. The rest are in the catalogue at `%s`.\n' "$cat"
    fi
  fi

  cat <<EOF

# What this draft could not determine

- Whether this repository is still the surface a given feature is delivered on.
  A path exists or it does not; whether anybody is still shipping through it is
  a product fact and is in no file here.
- Which of the paths above a ticket actually lands in. That is a search, and it
  is the implementing agent's job rather than this concept's.
- Anything about the other repositories beyond which of the same coarse
  capabilities they carry. "Where it is instead" names a repository, never a
  file.

# What a refiner should do with this

Resolve the ticket's words through
[the product vocabulary](/domain/product-vocabulary.md) first and
[the domain rules](/domain/domain-rules.md) second, then come here for the
repository, and only then search. Nothing in this file was verified, so a path
named here is a place to look rather than a place to point at in a verdict.
EOF
}

# --- the product's own dictionary -------------------------------------------

render_vocabulary() {
  local cats nrepos t

  cats=$(awk -F'\t' '{ print $1 }' "$WORK/catalogues" | sort -u | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')
  nrepos=$(catalogue_repos | grep -c . | tr -d ' ')

  printf -- '---\n'
  printf 'type: Glossary\n'
  printf 'title: Product vocabulary\n'
  printf 'description: %s\n' "$(yaml_scalar "What the product calls a thing, and the code key it is filed under, derived from the translatable string catalogues.")"
  printf 'tags: [drafted, terminology, refinement]\n'
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'

  # One source per catalogue file, because each one is a document a reader can
  # open. A single source saying "the catalogues" would not be retrievable, and
  # a source nobody can follow is decoration.
  while IFS=$'\t' read -r _n _rel _lang; do
    [ -n "$_n" ] || continue
    printf -- '  - id: cat-%s-%s\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$_n" | tr -c 'A-Za-z0-9' '-')" \
      "$(printf '%s' "$_rel" | sed 's#.*/##' | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the $_lang catalogue of $_n")" \
      "$(yaml_scalar "$(blob_resource "$_n" "$_rel")")"
  done < "$WORK/catalogues"
  printf -- '  - id: declared-terms\n    title: %s\n    resource: %s\n' \
    "$(yaml_scalar "the domain vocabulary the API declares: models, tables, enums, frozen constants and scopes")" \
    "$(yaml_scalar "$(vocabulary_term_resource)")"
  if [ -s "$WORK/retired.terms" ]; then
    printf -- '  - id: retirement-signals\n    title: %s\n    resource: %s\n' \
      "$(yaml_scalar "the scopes, constants and migrations that name a term live code excludes")" \
      "$(yaml_scalar "$(retirement_resource)")"
  fi
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified.** Derived by \`bin/orc-okf-draft.sh\` from the
translatable string catalogues of $nrepos repositories:
$cats.
They are the one artefact in this product that already holds a product phrase on
one side and a code key on the other. Nobody has checked a row of it.

This is a dictionary in the direction refinement actually needs it: a ticket is
written in the words on the left, and the thing worth searching for is on the
right. It is not a listing of what the code calls its own files - that would
only help a ticket already written in code terms, and such a ticket did not need
help.

The curated distinctions - the ones that bite - are a human's to write down and
to verify. Nothing here is that, and nothing here links to it: a concept that
cites a file nobody has written sends a reader looking for knowledge that does
not exist.

# What was read

EOF
  printf '| Repository | Catalogue | Language | Strings |\n|---|---|---|---|\n'
  while IFS=$'\t' read -r _n _rel _lang; do
    [ -n "$_n" ] || continue
    printf '| %s | [`%s`](%s) | %s | %s |[^cat-%s-%s]\n' \
      "$_n" "$_rel" "$(blob_resource "$_n" "$_rel")" "$_lang" \
      "$(awk -F'\t' -v r="$_rel" '$5 == r { c++ } END { print c + 0 }' "$WORK/strings")" \
      "$(printf '%s' "$_n" | tr -c 'A-Za-z0-9' '-')" \
      "$(printf '%s' "$_rel" | sed 's#.*/##' | tr -c 'A-Za-z0-9' '-')"
  done < "$WORK/catalogues"

  cat <<EOF

The code keys are the domain vocabulary the API declares - its models, tables,
enums, frozen constants and scopes.[^declared-terms]

# How a row got here

A phrase is listed when **every** catalogue key it appears under contains the
code key, and when at least $PHRASE_MIN_REPOS of the configured repositories say
it.

The first half is a rule about ambiguity rather than about frequency. A phrase
filed once under \`follow_up\` and once under \`prescription\` resolves to
neither, and picking one of the two would be exactly the confidently wrong
answer this bundle exists to prevent.

The second half is corroboration: a string only one surface holds is that
surface's copy rather than the product's vocabulary. Those are not lost - they
are on the subsystem concept for the repository that says them, where they route
a ticket instead of defining a word.

Left out on purpose, and each exclusion has one reason:

- Phrases longer than $PHRASE_MAX_WORDS words. A name is at most three words; the
  fourth makes it a sentence, and a sentence is one surface's copy rather than the
  product's vocabulary.
- Anything carrying interpolation, markup or a URL - that is a template, and a
  template tokenises into things that are not words.
- A multi-word string starting in lower case, which is the middle of a sentence
  broken across keys the way legal copy is.
- Any code key that more than $GENERIC_COLUMN_MAX tables declare as a column:
  \`name\`, \`slug\`, \`created_at\`, \`country_code\` are field names rather than
  domain terms.
- A row whose two sides are the same word. "Coupon" resolving to \`coupon\` is
  true and tells a reader nothing they did not already have.
EOF

  if [ "$n_phrases" -gt 0 ]; then
    cat <<EOF

# What the product calls it, and what the code calls it

Sorted by code key, so the reverse lookup works too: everything the product
says for one code key is in one run of rows.

EOF
    printf '| Product phrase | Language | Code key | Said by | Also in | Example key |\n|---|---|---|---|---|---|\n'
    while IFS=$'\t' read -r phrase lang term kind _nrep _hits repos langs example; do
      [ -n "$phrase" ] || continue
      printf '| %s | %s | `%s` (%s) | %s | %s | `%s` |\n' \
        "$(md_cell "$phrase")" "$lang" "$term" "$kind" "$repos" \
        "$(printf '%s' "$langs" | tr ' ' ',' | sed 's/,/, /g')" "$example"
    done < "$WORK/phrases"
    if [ "$n_phrases_all" -gt "$n_phrases" ]; then
      cat <<EOF

$n_phrases of $n_phrases_all rows, the ones said by the most repositories first.
The rule is stated above so the rest can be derived; a table that stopped at a
hundred rows without saying so would read as a table that found a hundred
things.
EOF
    fi
  fi

  if [ -s "$WORK/retired.terms" ]; then
    cat <<EOF

# Vocabulary the evidence says is not live

**Read this before resolving any word in it.** These are terms live code is
deliberately excluding, or whose only remaining trace is rows. A ticket using
one of them is ambiguous in a way that decides the verdict, and this draft
cannot tell you which meaning the reporter had in mind.[^retirement-signals]

EOF
    printf '| Term | What the evidence shows | Where |\n|---|---|---|\n'
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      retirement_row "$t"
    done < "$WORK/retired.terms"

    cat <<EOF

## Why, when, and by whom are not here

Nothing above says *why*, or *when*, or whether the word is still used by people
in the building. A concept can be retired as a company decision and leave no
trace in any repository at all, so a term absent from this table is not
established as live - it has only failed to trip one of the two signals.

If a ticket uses one of these words, the question to ask the reporter is which
of the two things they mean. That question is answerable by a person in one
sentence and by this script never.
EOF
  fi

  cat <<EOF

# What this draft could not determine

- What any term *means*. Every row says where a word is filed, which is a
  different claim and a weaker one. The distinctions that bite are a person's to
  write down, and this draft is not where they live.
- Any word the product says somewhere without a string catalogue - in a support
  macro, in a sales deck, out loud in a stand-up. Those are the words a ticket is
  most likely to be written in and the ones nothing here can see.
- Which spelling is authored and which is translated. A row in a language other
  than the one a copywriter types into may be a translator's choice rather than
  the product's word.
- Whether a string is still on a screen. A catalogue keeps a key long after the
  component that read it was deleted.
EOF
}

# The addresses the two derived sources point at. A term set and a signal set are
# both readings of files, so the resource is the file that was read - the schema
# for the vocabulary, and the model that declares the filtering scope.
vocabulary_term_resource() {
  local n
  for n in $(target_names); do
    if [ -f "$(target_field "$n" 2)/db/schema.rb" ]; then
      blob_resource "$n" "db/schema.rb"; return 0
    fi
  done
  printf '%s' "$(tree_resource "$(target_names | head -1)")"
}

retirement_resource() {
  local n rel line
  IFS=$'\t' read -r n rel line <<< "$(awk -F'\t' '
    $3 == "filtered-out" { print $1 "\t" $5 "\t" $6; exit }
  ' "$WORK/retired.raw")"
  if [ -n "$n" ] && [ -n "$rel" ]; then
    blob_resource "$n" "$rel" "$line"
  else
    printf '%s' "$(tree_resource "$(target_names | head -1)")"
  fi
}

# One row per retired-looking term: every signal that fired, and the cold
# measurement beside them rather than mixed into them.
retirement_row() {
  local t="$1" what where n rel line sig detail cold
  what=""; where=""
  while IFS=$'\t' read -r n sig detail rel line; do
    [ -n "$n" ] || continue
    case "$sig" in
      filtered-out)
        what="$what${what:+; }live code excludes it through \`$detail\`" ;;
      migration-only)
        what="$what${what:+; }a migration dated $detail, and neither that table nor a model for it is in the tree now" ;;
      deprecation-comment)
        what="$what${what:+; }a comment says: \"$detail\"" ;;
    esac
    where="$where${where:+, }\`$rel\`${line:+:$line}"
  done <<< "$(awk -F'\t' -v t="$t" '$2 == t { print $1 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' "$WORK/retired.raw")"

  # The term's own last-commit date and nothing else. Naming the repository's head
  # date beside it would put a value in the concept that moves on every push,
  # which is the drift this whole rewrite removed.
  n=$(awk -F'\t' -v t="$t" '$2 == t { print $1; exit }' "$WORK/retired.raw")
  cold=$(term_last_commit "$n" "$t")
  if [ -n "$cold" ]; then
    if term_is_cold "$n" "$t"; then
      what="$what${what:+; }no commit has touched a file named after it since $cold, more than a year of this repository's own history ago"
    else
      what="$what${what:+; }its files are not cold, though: last touched $cold"
    fi
  fi
  printf '| `%s` | %s. | %s |\n' "$t" "$what" "$where"
}

# --- the domain rules a model writes down -----------------------------------

render_domain_rules() {
  local rails n cls name rel line long comment values tbl

  rails=$(printf '%s' "$targets" | awk -F'\t' 'NF { print $1 }' | while IFS= read -r n; do
    is_rails "$(target_field "$n" 2)" && printf '%s\n' "$n"; done)

  printf -- '---\n'
  printf 'type: Reference\n'
  printf 'title: Domain rules the code writes down\n'
  printf 'description: %s\n' "$(yaml_scalar "The frozen constants, enums, comments and schema constraints that state a domain rule rather than a layout.")"
  printf 'tags: [drafted, domain, refinement]\n'
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf -- '  - id: rules-%s-schema\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the schema $n keeps, on the branch it releases from")" \
      "$(yaml_scalar "$(blob_resource "$n" "db/schema.rb")")"
    printf -- '  - id: rules-%s-models\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the models $n declares its constants and enums in")" \
      "$(yaml_scalar "$(tree_path_resource "$n" "app/models")")"
  done <<< "$rails"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified.** Read out of the code by
\`bin/orc-okf-draft.sh\`. Nobody has checked a line of it.

Three kinds of thing are in here, and they have one property in common: each one
is a place where somebody wrote down what the domain *means* rather than where a
file lives.

- A **frozen constant** is a vocabulary somebody decided on, and the comment
  above it is often the only written explanation of the decision anywhere.
- An **enum** is a state machine, complete. A ticket that quotes one of these
  words has named a column on a record.
- A handful of **schema constraints** are rules: a unique index with a WHERE
  clause says at most one row may exist in a named state, and a check constraint
  says what a row may not be. The rest of a schema is layout and is not here.

Comments are quoted verbatim. Paraphrasing a comment that explains which
recommendation categories offer a follow-up would be this script deciding what
the domain means, which is the one thing a draft must not do.

# What was read

EOF
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf -- '- %s: the constants and enums in [`app/models`](%s)[^rules-%s-models], and the constraints in [`db/schema.rb`](%s)[^rules-%s-schema].\n' \
      "$n" "$(tree_path_resource "$n" "app/models")" "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')" \
      "$(blob_resource "$n" "db/schema.rb")" "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')"
  done <<< "$rails"
  printf '\n'

  if [ -s "$WORK/constants-kept" ]; then
    cat <<EOF

# What the code decided, and why

A constant is here when a human wrote a comment above it, or when one of its
values surfaces in the product's own strings - a value that reached a key path in
a catalogue crossed from the code into what a person reads.

EOF
    while IFS="$CONSTANT_FS" read -r n rel line cls name values long comment; do
      [ -n "$name" ] || continue
      printf '## `%s::%s`\n\n' "$cls" "$name"
      if [ -n "$values" ]; then
        printf '%s\n\n' "$values"
      fi
      if [ -n "$comment" ]; then
        printf '```\n'
        printf '%s\n' "$comment" | tr '\001' '\n'
        printf '```\n\n'
      elif [ "${long:-0}" != "0" ]; then
        printf 'A %s-line comment stands above it, too long to quote here:\n' "$long"
        printf '[%s:%s](%s).\n\n' "$rel" "$line" "$(blob_resource "$n" "$rel" "$line")"
      fi
      printf '%s, [`%s:%s`](%s).[^rules-%s-models]\n\n' \
        "$n" "$rel" "$line" "$(blob_resource "$n" "$rel" "$line")" \
        "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')"
    done < "$WORK/constants-kept"
  fi

  if [ -s "$WORK/enums" ]; then
    cat <<EOF
# Every state machine, complete

Values are listed complete, including the ones no client ever says: a state
machine reported with eight of its nine states is worse than one not reported at
all.

EOF
    printf '| Column | Values |\n|---|---|\n'
    awk -F'\t' '
      { key = $1 "." $2; if (!(key in seen)) { seen[key] = 1; order[++k] = key }
        vals[key] = vals[key] (vals[key] == "" ? "" : ", ") "`" $3 "`"
        repo[key] = $4 }
      END { for (i = 1; i <= k; i++) printf "| `%s` (%s) | %s |\n", order[i], repo[order[i]], vals[order[i]] }
    ' "$WORK/enums"
    printf '\n'
  fi

  if [ -s "$WORK/ruled-tables" ]; then
    cat <<EOF
# Where the schema is the rule

A partial unique index and a check constraint are the two places a database
refuses a row for a domain reason. The required columns of those same tables are
listed with them, because they are the rest of the same rule - the required
columns of every other table are layout and are not here.

EOF
    while IFS=$'\t' read -r n tbl; do
      [ -n "$tbl" ] || continue
      printf '## `%s` (%s)\n\n' "$tbl" "$n"
      awk -F'\t' -v n="$n" -v t="$tbl" '
        $1 == n && $2 == t && $3 == "partial-unique" { printf "- At most one row per `%s` where `%s`.\n", $4, $5 }
        $1 == n && $2 == t && $3 == "check" { printf "- A check constraint: `%s`.\n", $5 }
        $1 == n && $2 == t && $3 == "composite-unique" { printf "- `%s` is unique as a combination.\n", $4 }
      ' "$WORK/schema-rules"
      printf -- '- Refuses to exist without: '
      awk -F'\t' -v n="$n" -v t="$tbl" '
        $1 == n && $2 == t && $3 == "required" { printf "%s`%s`", (c++ ? ", " : ""), $4 }
        END { print (c ? "." : "nothing beyond its primary key.") }
      ' "$WORK/schema-rules"
      printf '\n'
      printf 'Read from [`db/schema.rb`](%s).[^rules-%s-schema]\n\n' \
        "$(blob_resource "$n" "db/schema.rb")" "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')"
    done < "$WORK/ruled-tables"
  fi

  cat <<EOF
# What this draft could not determine

- Why any of it is the way it is, beyond what a comment happens to say. A
  constant with no comment above it is a decision with no written reason, and
  this draft cannot invent one.
- Whether a value is still reached. A constant can enumerate five things while
  the product only offers three, and nothing in the tree says which three.
- What any of the rows say. A schema constraint describes what the database will
  refuse; it says nothing about what is already stored, and the two disagree
  wherever a constraint was added after the rows.
EOF
}

# --- the words the bundle could not explain ---------------------------------
#
# The one concept drafted from what refinement failed at rather than from what a
# repository holds. One concept and not one per term: the scope rule is that a
# few dozen sharp files beat forty vague ones, because refinement believes all
# forty, and a loop that answered a frequent word with a file of its own would
# degrade the bundle while looking productive.
#
# What each row says is decided by the evidence and never by how often the word
# came up. Most rows are therefore questions, which is the honest outcome: a term
# the repositories do resolve is already in the product vocabulary, so what
# reaches here is mostly what no artefact says.

# The address of the record the rows were ranked from. Repository-relative when
# it is inside this checkout, absolute when a run pointed elsewhere - either way
# a path, and a path has no spaces in it, which is what separates an address from
# a sentence about one.
gap_record_resource() {
  case "$GAP_LEDGER" in
    "$ORC_ROOT"/*) printf '%s' "${GAP_LEDGER#"$ORC_ROOT"/}" ;;
    *)             printf '%s' "$GAP_LEDGER" ;;
  esac
}

# The sentence a row's evidence supports, and not one word more.
gap_finding() {
  local capkey="$1" caprepos="$2" ident="$3" kind="$4" nrepo="$5" repos="$6" keys="$7"
  if [ -n "$capkey" ]; then
    printf 'Resolves to `%s`. Every catalogue key it appears under names that code key and %s repositories say it, which is the same rule every row of the product vocabulary passed - it is absent from that table because the table stops at %s rows, not because the evidence is.' \
      "$capkey" "$caprepos" "$PHRASE_CAP"
  elif [ -n "$ident" ]; then
    printf 'The code declares `%s`, a %s. A lead rather than an answer: that is the thing to search for, and whether it is what the reporter meant is not established here.' \
      "$ident" "$kind"
  elif [ "${nrepo:-0}" -ge "$PHRASE_MIN_REPOS" ]; then
    printf '%s repositories say the word (%s), under %s. None of those keys names anything the code declares, so the word is the product'"'"'s and what it means in code is not established. That is a question for somebody who knows the product.' \
      "$nrepo" "$repos" "$(printf '`%s`' "$keys")"
  elif [ "${nrepo:-0}" = "1" ]; then
    printf 'Only %s says it, under %s. One surface'"'"'s copy rather than the product'"'"'s word: it routes a ticket quoting it to that repository and defines nothing.' \
      "$repos" "$(printf '`%s`' "$keys")"
  else
    printf 'No configured repository says it at all - not in a string catalogue, not as an identifier. Either it is said somewhere that has no catalogue, or it is not the product'"'"'s word, and nothing here can tell those two apart.'
  fi
}

render_gap_vocabulary() {
  local n_rows n_answered
  n_rows=$(grep -c . "$WORK/gap-rows" | tr -d ' ')
  n_answered=$(awk -F"$GAP_FS" '$4 != "" { c++ } END { print c + 0 }' "$WORK/gap-rows")

  printf -- '---\n'
  printf 'type: Glossary\n'
  printf 'title: Open vocabulary\n'
  printf 'description: %s\n' "$(yaml_scalar "Words real tickets used that this bundle could not explain, each with what the repositories do and do not say about it.")"
  printf 'tags: [drafted, terminology, refinement, gap]\n'
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'
  printf -- '  - id: gap-record\n    title: %s\n    resource: %s\n' \
    "$(yaml_scalar "the record of what refinement could not resolve, one line per run")" \
    "$(yaml_scalar "$(gap_record_resource)")"
  printf -- '  - id: declared-terms\n    title: %s\n    resource: %s\n' \
    "$(yaml_scalar "the domain vocabulary the API declares: models, tables, enums, frozen constants and scopes")" \
    "$(yaml_scalar "$(vocabulary_term_resource)")"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified.** These are words that came out of real tickets, not out
of a repository. Refinement records the ticket's own words it looked up and could
not answer, \`bin/orc-gap-loop.sh\` ranks them across runs[^gap-record], and this
is what the configured repositories turn out to say about the ones that recur.
Nobody has checked a row of it.

Read it as a list of questions with their evidence attached rather than as a
dictionary. Of the $n_rows words on it, $n_answered resolve to something the code
declares. That is not a shortfall: a word the evidence resolves is already in the
product vocabulary, so what arrives here is mostly what no artefact in the tree
says at all - which is exactly the half a person can answer in a sentence and no
script can answer ever.

# How a row got here

A word is on this table when at least two separate tickets used it and
refinement could not resolve it, when it is a word rather than an identifier or a
sentence, and when no concept in this bundle already says it. The last of those
matters most: a word this bundle already explains was a reading failure rather
than a missing one, and answering it a second time here would leave two answers
to one question with nothing to say which was meant.

What each row then says is decided by the evidence, in the order below, and never
by how often the word came up.

A phrase resolves only under the rule the product vocabulary already uses: every
catalogue key it appears under names the same code key, and at least
$PHRASE_MIN_REPOS of the configured repositories say it.
Failing that, an identifier the code declares[^declared-terms] is offered as a
lead rather than as a meaning.
Failing that, the row says how many repositories say the word and under which
keys, and stops there.

A word the evidence cannot establish is said to be unestablished. A concept that
asserted a meaning it could not support would be worse than no concept, because
you could not tell which answer you had got.

# The words

EOF
  printf '| Word | Tickets | What the evidence says |\n|---|---|---|\n'
  while IFS="$GAP_FS" read -r disp tickets _runs capkey caprepos ident kind nrepo repos keys; do
    [ -n "$disp" ] || continue
    printf '| %s | %s | %s |\n' \
      "$(md_cell "$disp")" "$tickets" \
      "$(md_cell "$(gap_finding "$capkey" "$caprepos" "$ident" "$kind" "$nrepo" "$repos" "$keys")")"
  done < "$WORK/gap-rows"

  cat <<EOF

# What this draft could not determine

- What any of these words means. Every row says what the repositories say about
  a word, which is a different claim and a weaker one. A row that resolves to a
  code key says where to look and not what the thing is.
- Whether a word with no evidence is the product's or the reporter's. A support
  macro, a sales deck and a stand-up all produce words that no catalogue and no
  identifier has ever held, and those are the words a ticket is most likely to be
  written in.
- Which of these is worth a concept. Recurrence is a signal about attention, not
  about importance: a word two tickets happened to use may still be a detail, and
  a word used once may be the centre of the product. Somebody has to decide that,
  and this table is the input to that decision rather than the decision.
- Why refinement could not resolve it. The record says a word went unanswered; it
  does not say whether the bundle lacked the knowledge, held it somewhere the
  search did not reach, or held it in words the ticket did not use.
EOF
}

# --- what a person answered, and nothing more -------------------------------
#
# The rows bin/orc-harvest.sh read out of Jira: a question refinement asked, the
# answer somebody wrote underneath it, who wrote it and when.
#
# This is the only concept in the bundle whose evidence is a person rather than a
# repository, and that is exactly why it is the one that must not be promoted. A
# reporter answering a question about their own ticket has told you what is true
# of that ticket. They have not read this concept, and they have not said the
# answer holds for the product - which is what `verified:` means everywhere else
# in here. The bundle will not promote a phrase unless two repositories say it;
# one person saying something once is weaker than that, not stronger.
#
# So the row is a quotation with a name and a date on it, never a definition
# extracted from one. Reading a comment wrongly writes a wrong row, and a
# quotation is reviewable by the person who said it in a way a paraphrase is not.

ANSWER_FS=$'\002'

# ticket_resource is in orc-lib.sh: bin/orc-verify.sh cites the same ticket as
# the source of the same answer, and two spellings of one address would put two
# different links to one comment in one bundle.

# The rows for one question, oldest answer first, as one cell. Every answer
# names how it was matched, because a reviewer signing off should see which
# kind of evidence they are looking at - mechanical or read for meaning. A row
# matched by reading also carries the whole reply it was pulled from: the
# extraction can differ from the source in exactly the way the mechanical
# rules cannot, so the source is what a reviewer checks it against.
answer_cell() {
  local key="$1" question="$2"
  awk -F"$ANSWER_FS" -v k="$key" -v q="$question" '
    $1 == k && $2 == q { printf "%s\001%s\001%s\001%s\001%s\n", $4, $5, $6, $7, $8 }' "$WORK/answer-rows" \
  | sort -t$'\001' -k3,3 -k2,2 \
  | awk -F'\001' '{
      at = $3; sub(/T.*$/, "", at)
      how = $4; verbatim = $5
      printf "%s%s - %s, %s *(%s)*", (NR > 1 ? "<br>" : ""), $1, $2, at, how
      if (how == "by reading" && verbatim != "" && verbatim != $1) {
        printf "<br>&nbsp;&nbsp;the full reply: \"%s\"", verbatim
      }
    }'
}

render_reporter_answers() {
  local n_rows n_questions n_contested n_collisions n_contradicted

  n_rows=$(grep -c . "$WORK/answer-rows" | tr -d ' ')
  n_questions=$(awk -F"$ANSWER_FS" '{ print $1 "\001" $2 }' "$WORK/answer-rows" | sort -u | grep -c .)
  n_contradicted=$(awk -F"$ANSWER_FS" '$9 != "" { print $1 "\001" $2 }' "$WORK/answer-rows" | sort -u | grep -c .)
  n_contested=$(awk -F"$ANSWER_FS" '$10 == "yes" { print $1 "\001" $2 }' "$WORK/answer-rows" | sort -u | grep -c .)
  n_collisions=$(awk -F"$ANSWER_FS" '$11 != "" { print $1 }' "$WORK/answer-rows" | sort -u | grep -c .)

  printf -- '---\n'
  printf 'type: Reference\n'
  printf 'title: Answers people gave\n'
  printf 'description: %s\n' "$(yaml_scalar "What a reporter answered when refinement asked them a product question, quoted with who said it and when.")"
  printf 'tags: [drafted, refinement, provenance, unverified]\n'
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'
  while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    printf -- '  - id: ticket-%s\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$_k" | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the comments on $_k, where the question was asked and answered")" \
      "$(yaml_scalar "$(ticket_resource "$_k")")"
  done <<< "$(awk -F"$ANSWER_FS" '{ print $1 }' "$WORK/answer-rows" | sort -u)"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified, and this concept in particular.** Every other concept in
this bundle was read out of a repository. This one was read out of what a person
typed into a Jira comment when refinement asked them something the code could not
answer[^ticket-$(awk -F"$ANSWER_FS" 'NR == 1 { printf "%s", $1 }' "$WORK/answer-rows" | tr -c 'A-Za-z0-9' '-')].

That makes it the most useful thing in here and the least safe. Useful, because
\`prompts/refine.md\` may only ask questions that no repository answers, so every
row below is knowledge \`bin/orc-okf-draft.sh\` structurally cannot produce.
Unsafe, because an answer is scoped to the ticket it was given on: "the doctor
queue" resolves that ticket and does not define the term, and a person answering
about their own ticket has not read this file and has not said it holds for the
product.

A \`verified:\` date here would mean somebody read the concept and agrees with it.
Answering a question is not that. Until a person does read it, treat every row as
a lead with a name attached - which is still a large improvement on the question
with nobody's name on it that it replaces.

# What is on the table

$(plural "$n_rows" answer answers) to $(plural "$n_questions" question questions). Each row quotes what was said
rather than a definition drawn out of it, because a comment read wrongly writes a
wrong row, and a quotation with an author is something that author can correct.

EOF

  if [ "$n_contradicted" != "0" ]; then
    cat <<EOF
$(plural "$n_contradicted" "answer" "answers") name a figure that conflicts with the
ticket's own description, or with an answer already signed on the same ticket. The
row names what it conflicts with. Nothing here decides which is right - a
contradiction is a finding, the same way two people answering one question
differently is, and it is recorded rather than resolved.

EOF
  fi

  if [ "$n_contested" != "0" ]; then
    cat <<EOF
$(plural "$n_contested" "question was" "questions were") answered by more than one
person, and those people did not say the same thing. Both answers are on the row
and neither is marked as the right one. A disagreement is a finding: it usually means the
question was ambiguous or the two people work with different parts of the
product, and picking one of them here would hide that.

EOF
  fi

  if [ "$n_collisions" != "0" ]; then
    cat <<EOF
On $(plural "$n_collisions" "ticket" "tickets") here, refinement could not resolve a word
that a concept somebody has verified does say. The row names it. Either the verified
fact is stale or refinement could not find it, and those have different fixes -
so it is recorded here rather than repaired, the same way every other gap in this
bundle is.

EOF
  fi

  printf '| Question | Answered | Ticket | Asked |\n|---|---|---|---|\n'
  while IFS= read -r _pair; do
    [ -n "$_pair" ] || continue
    _key=${_pair%%$'\001'*}
    _q=${_pair#*$'\001'}
    _asked=$(awk -F"$ANSWER_FS" -v k="$_key" -v q="$_q" '$1 == k && $2 == q { print $3; exit }' "$WORK/answer-rows")
    _contra=$(awk -F"$ANSWER_FS" -v k="$_key" -v q="$_q" '$1 == k && $2 == q { print $9; exit }' "$WORK/answer-rows")
    _flag=$(awk -F"$ANSWER_FS" -v k="$_key" -v q="$_q" '$1 == k && $2 == q && $10 == "yes" { print "yes"; exit }' "$WORK/answer-rows")
    _coll=$(awk -F"$ANSWER_FS" -v k="$_key" -v q="$_q" '$1 == k && $2 == q { print $11; exit }' "$WORK/answer-rows")
    _note=""
    [ -z "$_contra" ] || _note="$_note<br>**This conflicts with $_contra.**"
    [ -z "$_flag" ] || _note="$_note<br>**Answered differently by two people. Neither is settled.**"
    [ -z "$_coll" ] || _note="$_note<br>**A verified concept already speaks to this ticket's unresolved words: $_coll.**"
    printf '| %s | %s%s | %s[^ticket-%s] | %s |\n' \
      "$(md_cell "$_q")" "$(md_cell "$(answer_cell "$_key" "$_q")")" "$(md_cell "$_note")" \
      "$_key" "$(printf '%s' "$_key" | tr -c 'A-Za-z0-9' '-')" "${_asked%%T*}"
  done <<< "$(awk -F"$ANSWER_FS" '{ print $1 "\001" $2 }' "$WORK/answer-rows" | awk '!seen[$0]++')"
  unset _pair _key _q _asked _contra _flag _coll _note

  cat <<EOF

# What this draft could not determine

- Whether any of these answers is true of the product. Each is true of the ticket
  it was given on, which is a narrower claim and the only one the evidence
  supports. Somebody who knows the product has to decide which of them generalise.
- Which of them are still true. An answer carries the date it was given and
  nothing revisits it, so a row about a flow that has since changed reads exactly
  like a row about one that has not.
- What the people who did not answer would have said. These are the questions
  somebody replied to; the ones nobody replied to are not here, and silence is
  not agreement.
- Whether a disagreement is about the product or about the question. Two people
  answering differently is recorded and never resolved, because the two readings
  need different work and this cannot tell them apart.
EOF
}

# --- one cross-cutting capability, and only where the evidence is -----------
#
# Not a hardcoded list of things a product might have. A capability is drafted
# only when more than one repository carries the evidence for it, which is what
# makes it cross-cutting rather than a subsystem's business restated.

localisation_repos() { awk -F'\t' '$2 == "strings" { print $1 }' "$WORK/matrix"; }

render_localisation() {
  local n path dir files managed

  printf -- '---\n'
  printf 'type: Capability\n'
  printf 'title: Localisation\n'
  printf 'description: %s\n' "$(yaml_scalar "Every surface carries its own string catalogue, in its own format, at its own path.")"
  printf 'tags: [drafted, i18n, cross-cutting]\n'
  printf 'status: draft\n'
  printf 'generated:\n  by: %s\n  at: @@AT@@\n' "$PRODUCER"
  printf 'sources:\n'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    dir=$(evidence_of "$n" strings)
    printf -- '  - id: cat-dir-%s\n    title: %s\n    resource: %s\n' \
      "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')" \
      "$(yaml_scalar "the catalogue directory of $n")" \
      "$(yaml_scalar "$(tree_path_resource "$n" "$dir")")"
  done <<< "$(localisation_repos)"
  printf -- '---\n\n'

  cat <<EOF
# Overview

**Drafted, not verified.** Detected by \`bin/orc-okf-draft.sh\` because more
than one repository carries a string catalogue, which is what makes this
cross-cutting rather than one subsystem's business.

There is no shared catalogue. Each surface keeps its own, in its own format, at
its own path, and the namespaces do not agree on a spelling across them - two of
them file under \`followUpTour\` what the API files under \`follow_up\`. A ticket
that says a piece of user-facing text is wrong has not yet said which catalogue, and
the answer is a different file in a different format depending on the surface -
which is exactly the class of ticket that gets a confident wrong file list.

These same files are where
[the product vocabulary](/domain/product-vocabulary.md) comes from, so a copy
change and a term resolution read the same evidence.

# Where the strings are

EOF

  printf '| Subsystem | Catalogue | Format | Languages | Strings |\n|---|---|---|---|---|\n'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    path=$(target_field "$n" 2)
    dir=$(evidence_of "$n" strings)
    files=$(catalogue_langs_of "$n" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')
    printf '| %s | [`%s`](%s)[^cat-dir-%s] | %s | %s | %s |\n' \
      "$n" "$dir" "$(tree_path_resource "$n" "$dir")" "$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '-')" \
      "$(catalogue_format "$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' "$WORK/catalogues")")" \
      "${files:--}" \
      "$(awk -F'\t' -v n="$n" '$1 == n { c++ } END { print c + 0 }' "$WORK/strings")"
  done <<< "$(localisation_repos)"

  managed=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    path=$(target_field "$n" 2)
    [ -f "$path/localazy.json" ] && managed="$managed, $n"
  done <<< "$(localisation_repos)"
  managed=${managed#, }

  if [ -n "$managed" ]; then
    cat <<EOF

# Some of them are managed elsewhere

\`localazy.json\` is present in $managed.

In those a translation is pushed and pulled by a tool rather than edited by hand,
so a change committed straight into the catalogue can be overwritten by the next
sync. Which file is the source and which is downloaded is not something this
draft established - that is a question for whoever verifies this concept.
EOF
  fi

  cat <<EOF

# What this draft could not determine

- Which language is authored and which is translated. A catalogue holding four
  languages does not say which one a copywriter types into.
- Whether a key with no string in a language falls back or renders blank. That
  is framework configuration rather than a fact about these files.
EOF
}

# --- the index a directory keeps --------------------------------------------
#
# An index.md is a human's file. This script owns one region of it and nothing
# else: the listing of what it drafted, between two markers, replaced whole on
# every run. Rewriting the file would be the same mistake as rewriting a
# verified concept - a machine discarding prose somebody wrote because it had a
# listing to update.
INDEX_BEGIN='<!-- BEGIN drafted by bin/orc-okf-draft.sh -->'
INDEX_END='<!-- END drafted by bin/orc-okf-draft.sh -->'

# index_region <index relative path> <heading> <listing>
index_region() {
  local rel="$1" heading="$2" listing="$3"
  local file body
  file="$BUNDLE/$rel"

  [ -n "$listing" ] || return 0

  body="$INDEX_BEGIN

# $heading

$listing
$INDEX_END"

  if [ -f "$file" ]; then
    awk -v b="$INDEX_BEGIN" -v e="$INDEX_END" '
      $0 == b { skipping = 1 }
      !skipping { print }
      $0 == e { skipping = 0 }
    ' "$file" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$WORK/index-head"
  else
    : > "$WORK/index-head"
  fi

  if [ -s "$WORK/index-head" ]; then
    { cat "$WORK/index-head"; printf '\n%s\n' "$body"; } > "$WORK/index-new"
  else
    printf '%s\n' "$body" > "$WORK/index-new"
  fi

  if [ -f "$file" ] && cmp -s "$WORK/index-new" "$file"; then
    row "$rel" "unchanged" "the drafted listing already matches"
    n_unchanged=$(( n_unchanged + 1 ))
    return 0
  fi
  if [ "$check_only" = "1" ]; then
    drift=1
    row "$rel" "would update" "the drafted listing moved"
    n_updated=$(( n_updated + 1 ))
    return 0
  fi
  mkdir -p "$(dirname "$file")" || orc_die "could not create $(dirname "$file")"
  cp "$WORK/index-new" "$file" || orc_die "could not write $file"
  row "$rel" "updated" "the drafted listing moved"
  n_updated=$(( n_updated + 1 ))
}

# --- draft ------------------------------------------------------------------

# The enums, kept separately from the term set because the drafted concept lists
# them complete: model<TAB>enum<TAB>value<TAB>project.
: > "$WORK/enums"
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  _path=$(target_field "$_n" 2)
  is_rails "$_path" || continue
  find "$_path/app/models" -name '*.rb' 2>/dev/null | sort | while IFS= read -r _f; do
    awk -v model="$(class_of_path "${_f#"$_path/"}")" '
      /^[[:space:]]*enum[[:space:]]+:?[a-z_]+/ {
        name = $0
        sub(/^[[:space:]]*enum[[:space:]]+:?/, "", name)
        sub(/[^a-z_].*$/, "", name)
        inb = 1
        next
      }
      inb && /^[[:space:]]*[a-z_]+:[[:space:]]*[0-9-]/ {
        v = $0; sub(/^[[:space:]]*/, "", v); sub(/:.*$/, "", v)
        print model "\t" name "\t" v
      }
      inb && /^[[:space:]]*[]}]/ { inb = 0 }
    ' "$_f"
  done | sed "s#\$#\t$_n#" >> "$WORK/enums"
done < <(target_names)
unset _n _path _f

# The constants worth a row. Three ways in, and a scalar with no comment above it
# is none of them: a lone threshold is a tuning number rather than a domain
# vocabulary, and a number with no written reason is not knowledge.
: > "$WORK/constants-kept"
while IFS="$CONSTANT_FS" read -r _n _rel _line _cls _name _text _long _comment; do
  [ -n "$_name" ] || continue
  _values=$(constant_values "$_text")
  _nvalues=$(printf '%s' "$_values" | awk -F', ' '{ print NF }')
  if [ -z "$_comment" ] && [ "${_long:-0}" = "0" ]; then
    [ "${_nvalues:-0}" -ge 2 ] || constant_is_surfaced "$_values" || continue
  fi
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$_n" "$CONSTANT_FS" "$_rel" "$CONSTANT_FS" "$_line" "$CONSTANT_FS" "$_cls" "$CONSTANT_FS" \
    "$_name" "$CONSTANT_FS" "$(constant_values_capped "$_values")" "$CONSTANT_FS" \
    "$_long" "$CONSTANT_FS" "$_comment" >> "$WORK/constants-kept"
done < "$WORK/constants"
unset _n _rel _line _cls _name _text _long _comment _values _nvalues

# Where a repository's concept goes. The config's own join field decides it when
# a human has set one, because that field exists precisely so refinement can go
# from a resolved subsystem to a path without guessing that a project key and a
# concept id happen to match. Without one the project key is the fallback, and
# the report prints the line to paste so the join stops being a coincidence.
concept_path_for() {
  local sub existing
  sub=$(project_field "$1" subsystem)
  if [ -n "$sub" ]; then
    printf '%s.md' "${sub%.md}"
    return 0
  fi
  # A concept already claiming this repository is this repository's concept,
  # whatever it happens to be called. Writing a second one under the project key
  # is how the bundle ended up answering "the dashboard" two different ways, one
  # of them verified and one not, with nothing to say which was meant. The
  # config's subsystem: field still wins when a human has set it; this is the
  # case where nobody has, which is the case that went wrong.
  existing=$(concept_claiming_repo "$BUNDLE" "$(repo_identity "$1")")
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi
  printf 'subsystems/%s.md' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')"
}

subsystem_listing=""
root_listing=""
proposals=""

while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  _rel=$(concept_path_for "$_n")
  publish "$_rel" "$(render_subsystem "$_n")"
  if [ "$PUBLISH_OUTCOME" != "skipped-verified" ]; then
  root_listing="$root_listing* [$_n]($_rel) - $(stack_of "$(target_field "$_n" 2)"), drafted from \`$(target_field "$_n" 3)\`.
"
  case "$_rel" in
    subsystems/*)
      subsystem_listing="$subsystem_listing* [$_n](${_rel#subsystems/}) - $(stack_of "$(target_field "$_n" 2)"), drafted from \`$(target_field "$_n" 3)\`.
" ;;
  esac
  fi
  [ -n "$(project_field "$_n" subsystem)" ] || proposals="$proposals  $_n:
    subsystem: ${_rel%.md}
"
done < <(target_names)
unset _n _rel

domain_listing=""
capability_listing=""

if [ -s "$WORK/phrases" ] || [ -s "$WORK/retired.terms" ]; then
  publish "domain/product-vocabulary.md" "$(render_vocabulary)"
  if [ "$PUBLISH_OUTCOME" != "skipped-verified" ]; then
    domain_listing="$domain_listing* [Product vocabulary](product-vocabulary.md) - what the product calls a thing, and the code key it is filed under.
"
    root_listing="$root_listing* [Product vocabulary](domain/product-vocabulary.md) - what the product calls a thing, and the code key it is filed under.
"
  fi
fi

if [ -s "$WORK/constants-kept" ] || [ -s "$WORK/enums" ] || [ -s "$WORK/ruled-tables" ]; then
  publish "domain/domain-rules.md" "$(render_domain_rules)"
  if [ "$PUBLISH_OUTCOME" != "skipped-verified" ]; then
    domain_listing="$domain_listing* [Domain rules the code writes down](domain-rules.md) - the constants, enums, comments and schema constraints that state a rule.
"
    root_listing="$root_listing* [Domain rules the code writes down](domain/domain-rules.md) - the constants, enums, comments and schema constraints that state a rule.
"
  fi
fi

# The gap concept, when a caller has proposed terms for it. Published here with
# everything else rather than in a mode of its own, because an index region is
# replaced whole: a run that wrote only this concept would rewrite the bundle's
# front door with one entry on it.
if [ -s "$WORK/gap-rows" ]; then
  publish "$ORC_ACCUMULATING_VOCAB" "$(render_gap_vocabulary)"
fi
# Listed from what is on disk rather than from what this run published, so a
# plain run - which renders no gap rows and therefore touches this concept not at
# all - does not drop it out of the listing and call that an update. A concept
# somebody has verified is theirs and is not listed as a draft.
if [ -f "$BUNDLE/$ORC_ACCUMULATING_VOCAB" ] \
   && ! concept_is_verified "$BUNDLE/$ORC_ACCUMULATING_VOCAB"; then
  domain_listing="$domain_listing* [Open vocabulary](open-vocabulary.md) - words real tickets used that this bundle could not explain, and what the repositories say about them.
"
  root_listing="$root_listing* [Open vocabulary](domain/open-vocabulary.md) - words real tickets used that this bundle could not explain, and what the repositories say about them.
"
fi

# What people answered, when a caller has harvested any. Same placement and same
# reason as the gap concept above: the index region is replaced whole, so this is
# one more concept on a normal run rather than a mode of its own.
if [ -s "$WORK/answer-rows" ]; then
  publish "$ORC_ACCUMULATING_ANSWERS" "$(render_reporter_answers)"
fi
# Listed from what is on disk, so a run with no --answers leaves the concept in
# the listing rather than dropping it and calling that an update.
if [ -f "$BUNDLE/$ORC_ACCUMULATING_ANSWERS" ] \
   && ! concept_is_verified "$BUNDLE/$ORC_ACCUMULATING_ANSWERS"; then
  domain_listing="$domain_listing* [Answers people gave](reporter-answers.md) - what a reporter answered when refinement asked, quoted with who said it and when.
"
  root_listing="$root_listing* [Answers people gave](domain/reporter-answers.md) - what a reporter answered when refinement asked, quoted with who said it and when.
"
fi

if [ "$(localisation_repos | grep -c .)" -ge 2 ]; then
  publish "capabilities/localisation.md" "$(render_localisation)"
  if [ "$PUBLISH_OUTCOME" != "skipped-verified" ]; then
    capability_listing="* [Localisation](localisation.md) - every surface carries its own string catalogue, in its own format.
"
    root_listing="$root_listing* [Localisation](capabilities/localisation.md) - every surface carries its own string catalogue, in its own format.
"
  fi
fi

# The root index is the bundle's front door, and an enumeration that is missing
# an entry cannot be found by searching for it - the one kind of drift grep is
# blind to. So the drafts are listed there too, under their own heading rather
# than folded into a human's list.
[ -n "$root_listing" ] && root_listing="Drafted by \`bin/orc-okf-draft.sh\` and not verified by anybody. They
carry \`generated:\` and no \`verified:\`, and refinement is told to weight them
lower than a concept a person has checked.

$root_listing"
index_region "index.md"              "Drafted from the repositories" "$root_listing"
index_region "subsystems/index.md"   "Drafted subsystems"   "$subsystem_listing"
index_region "domain/index.md"       "Drafted"              "$domain_listing"
index_region "capabilities/index.md" "Drafted capabilities" "$capability_listing"

# --- the drifted concepts, for a caller rather than a reader -----------------
#
# One path per line and nothing else, so a caller does not have to parse a table
# whose columns are padded to the longest value in them.
if [ "$list_only" = "1" ]; then
  if [ "$n_unread" != "0" ]; then exit 2; fi
  printf '%s' "$rows" | awk -F'\t' '$2 ~ /^would / { print $1 }'
  [ "$drift" = "0" ] || exit 1
  exit 0
fi

# --- report -----------------------------------------------------------------
#
# Ruled rather than boxed, and never truncated. Same reason as everywhere else:
# a box pads to one width, which means either cutting a path or widening the
# whole report to the longest one in it.
banner() {
  local rule="=================================================================="
  printf '  %s\n' "$rule"
  printf '%s' "$1" | awk -v w=76 '
    $0 == "" { print ""; next }
    /^[[:space:]]/ { print "  " $0; next }
    {
      m = split($0, word, " ")
      out = word[1]
      for (i = 2; i <= m; i++) {
        if (length(out) + 1 + length(word[i]) <= w) { out = out " " word[i]; continue }
        print "  " out
        out = word[i]
      }
      print "  " out
    }'
  printf '  %s\n\n' "$rule"
}

concepts_n() { [ "$1" = "1" ] && printf '1 concept' || printf '%s concepts' "$1"; }

if [ "$quiet" != "1" ]; then
  printf '\n  Bundle: %s\n' "$BUNDLE"
  if [ "$check_only" = "1" ]; then
    printf '  Reading %s. Writing nothing.\n' "$(concepts_n "$(printf '%s' "$rows" | grep -c .)")"
  fi
  printf '  Drafted from: %s\n' "$(target_names | tr '\n' ' ' | sed 's/ $//;s/^$/nothing/')"
  printf '  Read: %s catalogue file(s), %s string(s), %s declared term(s), %s constant(s).\n' \
    "$(grep -c . "$WORK/catalogues" | tr -d ' ')" \
    "$(grep -c . "$WORK/strings" | tr -d ' ')" \
    "$(grep -c . "$WORK/terms" | tr -d ' ')" \
    "$(grep -c . "$WORK/constants-kept" | tr -d ' ')"
fi

printf '\n'
printf '%s' "$rows" | awk -F'\t' '
  NF {
    n++; c[n] = $1; o[n] = $2; d[n] = $3
    if (length($1) > w1) w1 = length($1)
    if (length($2) > w2) w2 = length($2)
  }
  END {
    if (length("CONCEPT") > w1) w1 = length("CONCEPT")
    if (length("OUTCOME") > w2) w2 = length("OUTCOME")
    fmt = "  %-" w1 "s  %-" w2 "s  %s\n"
    printf fmt, "CONCEPT", "OUTCOME", "DETAIL"
    width = w1 + w2 + 34
    rule = ""
    for (i = 0; i < width; i++) rule = rule "-"
    printf "  %s\n", rule
    for (i = 1; i <= n; i++) printf fmt, c[i], o[i], d[i]
    printf "  %s\n", rule
    if (n == 0) printf "  nothing to draft\n"
  }'
printf '  drafted=%s updated=%s unchanged=%s SKIPPED=%s unread=%s\n\n' \
  "$n_drafted" "$n_updated" "$n_unchanged" "$n_verified" "$n_unread"

if [ -n "$skipped_drafts" ]; then
  body="VERIFIED, SO NOT TOUCHED - $(concepts_n "$n_verified") a human has checked.

A concept carrying a verified: date is somebody's reviewed work, and a re-draft would replace it with an unverified one. That is a downgrade wearing the costume of an update, so it does not happen and there is no flag that makes it happen.

Each of these would have been rewritten. None of them was:

$(printf '%s' "$skipped_drafts" | sed 's#^#  #')
Delete the verified: line yourself if you want the draft back. Then this script will write it, and it will be a draft again - which is the honest state for a file no human has read since the code moved."
  banner "$body"
fi

if [ -n "$unread" ]; then
  body="NOT READ - $(repos=$(printf '%s' "$unread" | grep -c . | tr -d ' '); [ "$repos" = "1" ] && printf '1 repository' || printf '%s repositories' "$repos").

Nothing was drafted from these, and nothing about them was guessed. A concept reasoned against a checkout that is not the code anybody is shipping is worse than a missing concept: the missing one asks a question and the wrong one answers it.
"
  while IFS=$'\t' read -r name why; do
    [ -n "$name" ] || continue
    body="$body
  $name
    $why"
  done <<< "$unread"
  body="$body

bin/orc-repos-sync.sh reports and repairs what it can. Run it, then run this again."
  banner "$body"
fi

# Not gated on --quiet. The join is a finding rather than preamble: a drafted
# concept the config cannot reach is one refinement will never follow.
if [ -n "$proposals" ]; then
  body="THE CONFIG DOES NOT NAME THESE CONCEPTS YET.

config/projects.yml has a subsystem: field whose whole job is the join: it lets refinement go from a subsystem it resolved to a repository it may search, instead of hoping a project key and a concept id happen to match. These drafts landed at a path the config does not point at.

Nothing here edited the config, and nothing here will. It is source, a human consented to what is in it, and the same rule applies as to a Jira write: detect, then let a human decide. Add the field under each project:

$proposals"
  banner "$body"
fi

if [ "$check_only" = "1" ] && [ "$drift" = "1" ]; then
  # Named for what the caller actually ran, flags included. Told to run this
  # script when what moved is the open-vocabulary concept, an operator would run
  # it without --gap-terms and be told nothing had moved - a diagnostic that
  # misleads is worse than one that says nothing, and one naming a command that
  # reproduces a different run is the same failure by another route.
  #
  # On its own line, not inside the sentence: a full stop after the last flag is
  # part of the word somebody pastes, and `--min-tickets 2.` is not a number.
  if [ -n "$answers" ]; then
    printf '  The bundle is not what the repositories and the answered questions say. Run:\n\n    %s\n\n' "$drift_command"
  elif [ -n "$gap_terms" ]; then
    printf '  The bundle is not what the repositories and the gap record say. Run:\n\n    %s\n\n' "$drift_command"
  else
    printf '  The bundle is not what the repositories say. Run:\n\n    %s\n\n' "$drift_command"
  fi
  exit 1
fi
if [ "$n_unread" != "0" ]; then
  exit 1
fi
exit 0
