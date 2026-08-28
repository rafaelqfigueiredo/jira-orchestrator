#!/usr/bin/env bash
# From a fresh checkout to a working knowledge bundle, in one command.
#
#   orc-onboard.sh --org acme                 the whole thing, interactively
#   orc-onboard.sh --org example --offline    the same, from a fixture listing
#   orc-onboard.sh --org acme --select api,dashboard --yes
#   orc-onboard.sh reset --org acme           discard the bundle first
#
# Six steps, none of them new:
#
#   1  can this machine read GitHub                bin/orc-repos-discover.sh
#   2  what is in the organisation                 bin/orc-repos-discover.sh
#   3  which of those matter                       the operator
#   4  those, written into config/projects.yml     here, and only here
#   5  clone them                                  bin/orc-repos-sync.sh
#   6  draft the bundle from them                  bin/orc-okf-draft.sh
#
# The value is not machinery, it is that step 4 used to be a human copying a
# proposal into a file by hand between two scripts. Everything else is composed,
# and deliberately so: the real default branch of each repository, the protocol
# these credentials can actually use and why, the ranking by recent activity, the
# repositories with no default branch to check out - all of that is
# bin/orc-repos-discover.sh's, and this script carries it through rather than
# working any of it out again.
#
# It composes discovery rather than calling gh, and that is a rule
# bin/orc-check.sh enforces: gh lives in one script. --check-access is in
# discovery for the same reason.
#
# ## The consent step
#
# config/projects.yml is the reviewed half of the split, and until now nothing
# was allowed to write it. Discovery proposed, a human pasted, and the paste was
# the consent. This script replaces the paste with a selection, which is a change
# to a load-bearing thing, so here is the argument.
#
# What the paste actually provided was not the typing. It was that a person saw
# the exact bytes and chose them. A selection preserves both halves as long as:
#
#   the exact text about to be written is printed first, unindented and whole,
#   not summarised and not reflowed - an indented preview is not the bytes;
#
#   the text printed is discovery's own proposal, character for character, not
#   something re-rendered from a parsed feed - which is why this script parses
#   the proposal rather than reading the listing again. Re-rendering would let
#   the reviewed file end up spelled differently from the proposal somebody read,
#   and then "the bytes you saw are the bytes written" would be a promise instead
#   of a structural fact;
#
#   the write is confined to exactly what was selected, adds nothing inferred and
#   changes no existing line. It is an append, so it cannot rewrite one.
#
# bin/orc-check.sh asserts all three, because the old consent step was guarded
# mechanically and the new one has to be too. What the friction of pasting
# provided beyond that was tedium, and tedium is not consent: a step boring
# enough to be done by triple-click is weaker evidence that somebody read it than
# a list where each line was chosen.
#
# ## Running it twice
#
# Merge, append-only, and it says what it left alone.
#
# A project already in the config is listed as configured and is not selectable.
# It is never rewritten, because the entry may carry things discovery cannot know
# and a human decided: a subsystem: join, verify: local, a repo: path outside
# clones/. Overwriting it with a discovery-shaped block would discard exactly the
# knowledge somebody added, which is the same mistake as overwriting a verified
# concept. Changing an existing entry stays a human's edit to a reviewed file.
#
# So a second run cannot duplicate a block, cannot drop a hand-added project and
# cannot clobber a selection. What it can do is add what was not there before.
#
# ## reset
#
# A subcommand, not a flag. A flag lives in the same lexical space as --offline
# and --yes and gets pasted along with them out of a scrollback; a subcommand is
# the first word, so a command line that discards a bundle reads as a different
# command from one that does not, at the start of the line rather than the end.
#
# It discards the bundle: every markdown file in it, verified concepts included.
# bin/orc-okf-draft.sh refuses to overwrite a verified concept and that
# refusal has no override, which is right - replacing a checked concept with an
# unchecked one is a downgrade wearing the costume of an update. This does not
# overrule that refusal. It deletes the concepts, so there is nothing left to
# refuse, and it says in those words what is being lost.
#
# Loudness scales with what is at stake. Nothing verified: one line saying so,
# and it proceeds. Something verified: the count, the paths, who checked each one
# and when, and a typed phrase naming the count. The phrase rather than y/N
# because it cannot be produced by muscle memory or by a stray newline, and
# because it is wrong if the count has changed since it was printed - so a phrase
# copied out of yesterday's terminal after somebody verified a seventh concept
# does not work. There is no flag that skips it. --yes covers the config write
# and explicitly does not cover this.
#
# git is the undo, so it insists git actually holds what is about to go: inside a
# work tree, every markdown file in the bundle must be tracked and unmodified, or
# it refuses and names the ones that are not. Outside a work tree there is no undo
# at all, and it says so and asks for the phrase however little is verified.
#
# Confirmed first, removed last. Asked up front because that is when the operator
# is thinking about the bundle rather than watching clones tick past; performed
# immediately before the draft that replaces it, because a discovery that fails
# or a selection that is abandoned must leave the bundle exactly as it was.
#
# reset means the bundle and nothing else. config/projects.yml is source and this
# script only ever appends to it. clones/ and state/ are caches with their own
# rebuilds - bin/orc-repos-sync.sh --prune and bin/orc-reconcile.sh - and neither
# is this command's to throw away.
#
# Exit codes: 0 the bundle is drafted and every repository was usable, 1 something
# needs attention and the report names it.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd git awk sed

# Beside this script, not under ORC_ROOT: ORC_ROOT is overridable, and a run that
# pointed it elsewhere would compose three scripts that are not these ones.
BIN=$(cd "$(dirname "$0")" && pwd)
DISCOVER="$BIN/orc-repos-discover.sh"
SYNC="$BIN/orc-repos-sync.sh"
DRAFTER="$BIN/orc-okf-draft.sh"
BUNDLE="$BUNDLE_DIR"

org=""
limit=20
offline=0
protocol=""
selection=""
have_selection=0
assume_yes=0
do_reset=0

# The subcommand is the first word or it is not there at all. Accepted only in
# that position, so `--offline reset` is an unknown option rather than a discard
# somebody did not mean to type.
if [ $# -gt 0 ] && [ "$1" = "reset" ]; then do_reset=1; shift; fi

while [ $# -gt 0 ]; do
  case "$1" in
    --org)      shift; [ $# -gt 0 ] || orc_die "--org needs an organisation"; org="$1" ;;
    --limit)    shift; [ $# -gt 0 ] || orc_die "--limit needs a number"; limit="$1" ;;
    --offline)  offline=1 ;;
    --protocol) shift; [ $# -gt 0 ] || orc_die "--protocol needs ssh or https"; protocol="$1" ;;
    --select)   shift; [ $# -gt 0 ] || orc_die "--select needs a selection"; selection="$1"; have_selection=1 ;;
    --yes)      assume_yes=1 ;;
    --bundle)   shift; [ $# -gt 0 ] || orc_die "--bundle needs a directory"; BUNDLE="$1" ;;
    -h|--help)  orc_usage "$0"; exit 0 ;;
    -*)         orc_die "unknown option: $1" ;;
    *)          [ -n "$org" ] && orc_die "unexpected argument: $1"; org="$1" ;;
  esac
  shift
done

case "$limit" in ''|*[!0-9]*) orc_die "--limit must be a number (got '$limit')" ;; esac
case "$protocol" in ''|ssh|https) : ;; *) orc_die "--protocol must be ssh or https (got '$protocol')" ;; esac
# Both of these are word-split unquoted further down - the org into discovery's
# argument list, the selection into tokens - so anything that is not a plain word
# is refused here rather than becoming a glob or a second argument.
case "$org" in
  ''|*[!A-Za-z0-9._-]*) [ -z "$org" ] || orc_die "an organisation name is letters, digits, dot, dash and underscore (got '$org')" ;;
esac
case "$selection" in
  *[!A-Za-z0-9._,\ -]*) orc_die "a selection is numbers, ranges and names (got '$selection')" ;;
esac

WORK=$(mktemp -d) || orc_die "could not create a working directory"
# Flat, so the cleanup is a plain rm -f: the one recursive remove in this
# repository lives behind its own fence in bin/orc-repos-sync.sh and stays alone.
# shellcheck disable=SC2329  # the EXIT trap below is the caller
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

# --- what a reset would cost ------------------------------------------------

bundle_markdown() {
  [ -d "$BUNDLE" ] || return 0
  find "$BUNDLE" -name '*.md' -type f 2>/dev/null | sort
}

bundle_other_files() {
  [ -d "$BUNDLE" ] || return 0
  find "$BUNDLE" -type f ! -name '*.md' 2>/dev/null | sort
}

# The git work tree the bundle sits in, if there is one. is_git_repo answers a
# different question - is this path the top of a repository - and a bundle is
# normally a directory some way inside one.
bundle_worktree() {
  [ -d "$BUNDLE" ] || return 1
  git_read "$BUNDLE" rev-parse --show-toplevel 2>/dev/null | grep .
}

# Tracked and unmodified, or the paths that are not. git is the undo, and a
# discard whose undo does not exist is not a reset.
unsaved_bundle_files() {
  local top f rel
  top=$(bundle_worktree) || return 0
  bundle_markdown | while IFS= read -r f; do
    rel=${f#"$top"/}
    if [ -z "$(git_read "$top" ls-files -- "$rel" 2>/dev/null)" ]; then
      printf '%s\tnever committed\n' "$rel"
    elif [ -n "$(git_read "$top" diff --name-only HEAD -- "$rel" 2>/dev/null)" ]; then
      printf '%s\tmodified since the last commit\n' "$rel"
    fi
  done
}

reset_confirmed=0

confirm_reset() {
  local md n verified nv other unsaved undo body phrase f top=""

  md=$(bundle_markdown)
  n=$(printf '%s' "$md" | grep -c . | tr -d ' ')
  step "0. the bundle is about to be discarded"

  if [ "$n" = "0" ]; then
    say "There is no markdown in $BUNDLE, so there is nothing to discard."
    say "Carrying on: step 6 drafts a bundle where there was none."
    reset_confirmed=1
    return 0
  fi

  verified=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    concept_is_verified "$f" || continue
    verified="$verified    $(printf '%-44s %s' "${f#"$BUNDLE"/}" "$(concept_verified_by "$f" | head -1)")
"
  done <<< "$md"
  nv=$(printf '%s' "$verified" | grep -c . | tr -d ' ')

  # git is the undo, and a discard whose undo does not exist is not a reset. Two
  # different situations, and they are not the same refusal: git could hold these
  # and does not, or there is no git here to hold anything.
  unsaved=$(unsaved_bundle_files)
  if [ -n "$unsaved" ]; then
    banner "REFUSING: GIT DOES NOT HOLD ALL OF THIS YET

git is the undo for this discard and it is the only one. These files are not in it, so removing them would remove them for good:

$(printf '%s' "$unsaved" | awk -F'\t' '{printf "    %s  (%s)\n", $1, $2}')

Commit them, or move them out of the bundle, then run this again. Nothing has been discarded and nothing has been written."
    exit 1
  fi

  if top=$(bundle_worktree); then
    undo="Every one of these files is committed, so git is the undo and the only one: check ${BUNDLE#"$top"/} out again from HEAD and what you had is back. The command is not printed here on purpose - bin/orc-check.sh forbids a state-changing git invocation anywhere in this script and cannot tell one in a string from one being run, which is the right way round for it to be wrong."
  else
    undo="This bundle is not in a git working tree, so there is no undo at all - not for a verified concept and not for a draft either:

    $BUNDLE"
  fi

  other=$(bundle_other_files)
  if [ -n "$other" ]; then
    other="

Left alone, because a bundle is markdown and the drafter could never put these back:

$(printf '%s' "$other" | awk -v b="$BUNDLE/" '{ sub("^" b, ""); printf "    %s\n", $0 }')"
  fi

  if [ "$nv" != "0" ]; then
    phrase="discard $(plural "$nv" concept concepts) verified by a person"
    body="DISCARDING THE BUNDLE

    $BUNDLE

$(plural "$n" "markdown file" "markdown files"), $nv of them carrying a verified: date, which means a person read $(if [ "$nv" = "1" ]; then printf 'it'; else printf 'them'; fi) and confirmed what $(if [ "$nv" = "1" ]; then printf 'it says'; else printf 'they say'; fi):

$verified
bin/orc-okf-draft.sh refuses to overwrite any of those and that refusal has no override, which is right: replacing a checked concept with an unchecked one is a downgrade wearing the costume of an update. This does not overrule it. It deletes them, so there is nothing left to refuse - and what comes back is drafted and unverified, because the reading somebody did is not in a draft.
$other

$undo"
  elif [ -z "$top" ]; then
    phrase="discard $(plural "$n" file files) nothing can bring back"
    body="DISCARDING THE BUNDLE

    $BUNDLE

$(plural "$n" "markdown file" "markdown files"), none carrying a verified: date, so this throws away nobody's reading - but with no git behind it, a draft is as unrecoverable as a verified concept would be.
$other

$undo"
  else
    banner "DISCARDING THE BUNDLE

    $BUNDLE

$(plural "$n" "markdown file" "markdown files"), none carrying a verified: date. Nothing here was checked by anybody, so this throws away no reading a person did, and a confirmation over a rebuildable draft would be a ceremony. Carrying on without asking.
$other

$undo"
    reset_confirmed=1
    return 0
  fi

  banner "$body

Type this exactly to proceed. Anything else stops.

    $phrase"

  ask "reset has no flag that answers this, deliberately"
  if [ "$ANSWER" != "$phrase" ]; then
    gap
    say "That was not it, so nothing was discarded and nothing was written."
    exit 1
  fi
  gap
  reset_confirmed=1
}

# --- the discard itself -----------------------------------------------------
#
# rm -f over a file list, never a directory tree: bin/orc-check.sh fails if a
# second recursive remove appears anywhere in this repository, and it is right to.
# It removes and nothing else: putting the root index back is write_index_skeleton's
# job, and step 6 does that on every run rather than only after a discard.
discard_bundle() {
  local md f n
  md=$(bundle_markdown)
  [ -n "$md" ] || { say "nothing in $BUNDLE to remove"; return 0; }
  # Fed from a here-string rather than a pipe. $( ) strips the trailing newline, so
  # `read` returns false on the last path and a piped loop silently skips it - which
  # left the one verified concept in the bundle standing after a discard that had
  # already announced it was gone.
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f" || orc_die "could not remove $f"
    n=$(( n + 1 ))
  done <<< "$md"
  say "removed $(plural "$n" "markdown file" "markdown files") from $BUNDLE"
}

# The one file this script writes into the bundle, and it writes it only when
# there is no root index at all.
#
# bin/orc-okf-draft.sh owns a region of an index.md and creates the file when
# it is missing, but it writes no frontmatter - it has no business declaring what
# version of OKF a bundle is. A bundle whose root index carries no okf_version is
# a directory of markdown that happens to look like one, which is what a first
# onboarding used to produce and what a reset used to leave behind. So: written
# when absent, and otherwise left alone, because an index.md that exists is a
# human's file.
write_index_skeleton() {
  [ -f "$BUNDLE/index.md" ] && return 0
  mkdir -p "$BUNDLE" || orc_die "could not create $BUNDLE"
  cat > "$BUNDLE/index.md" <<'MD'
---
okf_version: "0.2"
---

# Knowledge bundle

Durable knowledge the refinement pass queries when it judges a ticket. Task
state does not live here: tickets, verdicts and phases belong in `state/`,
which is a rebuildable cache. This bundle is source, reviewed like code.

Everything below this line was drafted off the repositories and verified by
nobody. Read a concept before you rely on it, and record that you did.
MD
  say "wrote ${BUNDLE#"$ORC_ROOT"/}/index.md, so the bundle declares which OKF version it is"
}

# --- step 0 -----------------------------------------------------------------

[ "$do_reset" = "1" ] && confirm_reset

# --- step 1: can this machine read GitHub -----------------------------------

step "1. GitHub access"
access_args=""
[ "$offline" = "1" ] && access_args="--offline"
[ -n "$org" ] && access_args="$access_args --org $org"
# shellcheck disable=SC2086
if access=$($DISCOVER --check-access $access_args 2>&1); then
  printf '%s\n' "$access" | sed 's/^/  /'
else
  printf '%s\n' "$access" | sed 's/^/  /'
  gap
  orc_die "no way to list an organisation yet; nothing was written"
fi

# --- step 2: the organisation's repositories --------------------------------

[ -n "$org" ] || orc_die "which organisation? pass --org ORG"

step "2. the $org organisation"

disc_args="--org $org --limit $limit"
[ "$offline" = "1" ] && disc_args="$disc_args --offline"
[ -n "$protocol" ] && disc_args="$disc_args --protocol $protocol"
# shellcheck disable=SC2086
$DISCOVER $disc_args > "$WORK/proposal" 2>"$WORK/proposal.err" \
  || { sed 's/^/  /' < "$WORK/proposal.err"; orc_die "discovery could not list $org"; }

# The proposal, split into the per-project blocks it is made of. Each block is
# kept as the exact bytes discovery printed, because those bytes are what the
# operator is shown and what lands in the config; anything re-rendered here could
# differ from what was read.
#
# The index is one TSV line per repository discovery had something to say about:
#   kind  name  branch  pushed  language  description
# where kind is offer, configured or skipped.
awk -v work="$WORK" '
  function flush() {
    if (name != "" && kind == "offer") {
      f = work "/block-" name
      printf "%s", block > f
      close(f)
    }
    if (name != "") {
      # Never an empty field: read with IFS=tab treats two tabs as one separator,
      # so one empty value shifts every column after it left.
      if (desc == "") desc = "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", kind, name, branch, pushed, lang, desc
    }
    name = ""; branch = "-"; pushed = "-"; lang = "-"; desc = ""; block = ""; kind = ""
  }
  BEGIN { branch = "-"; pushed = "-"; lang = "-"; desc = ""; kind = "" }

  # A repository the remote gives no default branch for. Discovery has already
  # decided there is nothing to clone; this only has to carry the reason.
  /^# [A-Za-z0-9_.\/-]+: skipped\./ {
    flush()
    kind = "skipped"; name = $2; sub(/:$/, "", name)
    desc = "no default branch on the remote, so there is nothing to check out"
    next
  }

  # A project the config already names. Discovery shows it commented out for
  # comparison; here it is a row that cannot be selected.
  /^# [A-Za-z0-9_.\/-]+ is already in / {
    flush()
    kind = "configured"; name = $2
    desc = "already in the config, left exactly as it is"
    next
  }

  /^[A-Za-z0-9_.\/-]+:[[:space:]]*$/ {
    if (kind != "configured") flush()
    if (kind == "configured") { block = ""; next }
    kind = "offer"; name = $0; sub(/:.*$/, "", name)
    block = $0 "\n"
    next
  }

  kind == "configured" { if ($0 !~ /^#/) { flush() } ; next }

  kind == "offer" && /^[[:space:]]/ {
    block = block $0 "\n"
    i = index($0, ":")
    k = substr($0, 1, i - 1); sub(/^[[:space:]]+/, "", k)
    v = substr($0, i + 1); sub(/^[[:space:]]+/, "", v)
    if (k == "default_branch") branch = v
    else if ($0 ~ /^[[:space:]]+# .*, last pushed /) {
      s = $0; sub(/^[[:space:]]+# /, "", s)
      pushed = s; sub(/^.*, last pushed /, "", pushed)
      desc = s; sub(/, last pushed [^,]*$/, "", desc)
    }
    else if ($0 ~ /^[[:space:]]+# /) { lang = $0; sub(/^[[:space:]]+# /, "", lang) }
    next
  }

  kind == "offer" && /^[[:space:]]*$/ { flush(); next }
  kind == "offer" { flush() }
  END { flush() }
' "$WORK/proposal" > "$WORK/index.tsv"

offers=$(awk -F'\t' '$1 == "offer" { print $2 }' "$WORK/index.tsv")
n_offers=$(printf '%s' "$offers" | grep -c . | tr -d ' ')

# The parse is the seam between two scripts, so it is checked against the thing it
# parsed rather than trusted. A silent mismatch here would offer a shorter list
# than discovery proposed, and the operator would have no way to tell.
proposed=$(grep -cE '^[A-Za-z0-9_.\/-]+:[[:space:]]*$' "$WORK/proposal" | tr -d ' ')
if [ "$n_offers" != "$proposed" ]; then
  orc_die "read $n_offers selectable project(s) out of a proposal that names $proposed; the proposal format moved and this parse did not follow it"
fi

printf '  %-4s %-26s %-9s %-11s %-13s %s\n' '#' PROJECT BRANCH PUSHED LANGUAGE DESCRIPTION
printf '  %s\n' "---------------------------------------------------------------------------------------------"
i=0
while IFS=$'\t' read -r kind name branch pushed lang desc; do
  [ -n "$name" ] || continue
  if [ "$kind" = "offer" ]; then
    i=$(( i + 1 ))
    printf '  %-4s %-26s %-9s %-11s %-13s %s\n' "$i" "$name" "$branch" "$pushed" "$lang" "$desc"
  else
    printf '  %-4s %-26s %-9s %-11s %-13s %s\n' '-' "$name" "$branch" "$pushed" "$lang" "$desc"
  fi
done < "$WORK/index.tsv"
printf '  %s\n' "---------------------------------------------------------------------------------------------"
gap

# Discovery's own sentence about the protocol, carried through rather than
# re-derived. A remote spelled in a protocol these credentials cannot use fails on
# every repository at once, so the reason belongs in front of the operator here
# too, in the words the script that decided it used.
awk '/^# Remotes are proposed over/ { on = 1 } on && /^#/ { sub(/^# ?/, ""); print "  " $0; next } on { exit }' \
  "$WORK/proposal"
gap

[ "$n_offers" = "0" ] && {
  say "Nothing in $org is available to add: the config already names every"
  say "repository the listing offered, or none of them has a branch to check out."
  say "Skipping to step 5."
}

# --- step 3: which of those matter ------------------------------------------

# A selection resolves to project names, in CHOSEN. Not on stdout, for the same
# reason ask() does not use stdout: $( ) is a subshell, an orc_die in one kills
# only the subshell, and a run that carried on past "that is not one of the
# repositories offered" with an empty selection would silently write nothing and
# report success.
#
# Numbers are the ranking's, which is pushedAt order, so a selection takes names
# too: a script that pinned numbers would select a different repository the week
# the ranking moved.
CHOSEN=""
resolve_selection() {
  local raw="$1" tok lo hi j nm out=""
  raw=$(printf '%s' "$raw" | tr ',' ' ')
  for tok in $raw; do
    case "$tok" in
      all)  out="$offers"; break ;;
      none) out=""; break ;;
      [0-9]*-[0-9]*)
        lo=${tok%%-*}; hi=${tok##*-}
        [ "$lo" -le "$hi" ] 2>/dev/null || orc_die "'$tok' is not a range"
        j=$lo
        while [ "$j" -le "$hi" ]; do
          nm=$(printf '%s\n' "$offers" | sed -n "${j}p")
          [ -n "$nm" ] || orc_die "there is no $j in that list"
          out="$out$nm
"
          j=$(( j + 1 ))
        done
        ;;
      [0-9]*)
        nm=$(printf '%s\n' "$offers" | sed -n "${tok}p")
        [ -n "$nm" ] || orc_die "there is no $tok in that list"
        out="$out$nm
"
        ;;
      *)
        printf '%s\n' "$offers" | grep -qxF "$tok" \
          || orc_die "'$tok' is not one of the repositories offered above"
        out="$out$tok
"
        ;;
    esac
  done
  CHOSEN=$(printf '%s' "$out" | grep -v '^$' | awk '!seen[$0]++')
}

chosen=""
if [ "$n_offers" != "0" ]; then
  step "3. which of these should the orchestrator reason about"
  if [ "$have_selection" = "0" ]; then
    say "Numbers, ranges, names, all, or none. (e.g. 1 3, or 1-3, or api,dashboard)"
    ask "pass --select to answer it without a terminal"
    selection="$ANSWER"
    gap
  else
    say "--select $selection"
    gap
  fi
  resolve_selection "$selection"
fi
chosen="$CHOSEN"

n_chosen=$(printf '%s' "$chosen" | grep -c . | tr -d ' ')

# --- step 4: written into the config ----------------------------------------

if [ "$n_chosen" != "0" ]; then
  : > "$WORK/append"
  printf '\n# Selected in bin/orc-onboard.sh from the %s organisation, as\n' "$org" >> "$WORK/append"
  printf '# bin/orc-repos-discover.sh proposed them.\n\n' >> "$WORK/append"
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    [ -f "$WORK/block-$nm" ] || orc_die "internal: no proposed block for $nm"
    cat "$WORK/block-$nm" >> "$WORK/append"
    printf '\n' >> "$WORK/append"
  done <<< "$chosen"

  step "4. exactly this, appended to ${PROJECTS_FILE#"$ORC_ROOT"/}"
  printf '  %s\n' "-----------------------------------------------------------------------------"
  cat "$WORK/append"
  printf '  %s\n' "-----------------------------------------------------------------------------"
  gap
  known_n=$(project_names | grep -c . | tr -d ' ')
  if [ "$known_n" = "0" ]; then
    say "Those bytes and no others, at the end of a file that names nothing yet."
  else
    say "Those bytes and no others, at the end of a file that already names $(plural "$known_n" project projects)."
    say "Nothing already in it is touched, reordered or rewritten: an entry a human"
    say "edited is that human's, the same way a verified concept is."
  fi
  gap

  if [ "$assume_yes" = "0" ]; then
    say "Write it? Type y to write, anything else to stop."
    ask "pass --yes to answer it without a terminal"
    gap
    case "$ANSWER" in
      y|Y|yes|YES) : ;;
      *) say "Nothing was written."; exit 1 ;;
    esac
  fi

  [ -f "$PROJECTS_FILE" ] || {
    mkdir -p "$(dirname "$PROJECTS_FILE")" || orc_die "could not create $(dirname "$PROJECTS_FILE")"
    printf '# The mechanics of every repository the orchestrator may reason about.\n' > "$PROJECTS_FILE"
    printf '# Source: in git, reviewed, and changed only by a human - or by a\n' >> "$PROJECTS_FILE"
    printf '# bin/orc-onboard.sh selection a human read and confirmed.\n' >> "$PROJECTS_FILE"
  }
  # An append, so no byte already in the file can be changed by it, and one
  # append, so a failure cannot leave half a block behind.
  cat "$WORK/append" >> "$PROJECTS_FILE" || orc_die "could not write $PROJECTS_FILE"
  say "written. Read it back with: git diff ${PROJECTS_FILE#"$ORC_ROOT"/}"
else
  step "4. nothing selected, so nothing written"
  say "${PROJECTS_FILE#"$ORC_ROOT"/} is untouched."
fi

# --- step 5: clone them -----------------------------------------------------

step "5. the clones"
sync_rc=0
"$SYNC" --quiet || sync_rc=$?
[ "$sync_rc" = "0" ] || say "at least one repository is not usable; the report above names it"

# --- step 6: draft the bundle -----------------------------------------------

if [ "$reset_confirmed" = "1" ]; then
  step "6a. discarding the bundle"
  discard_bundle
fi

step "6. the bundle, drafted from those repositories"
write_index_skeleton
draft_rc=0
"$DRAFTER" --bundle "$BUNDLE" || draft_rc=$?

step "done"
say "config:  ${PROJECTS_FILE#"$ORC_ROOT"/}  ($(plural "$(project_names | grep -c . | tr -d ' ')" project projects))"
say "clones:  ${CLONE_DIR#"$ORC_ROOT"/}"
n_md=0
n_ver=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n_md=$(( n_md + 1 ))
  concept_is_verified "$f" && n_ver=$(( n_ver + 1 ))
done <<< "$(bundle_markdown)"
if [ "$n_ver" = "0" ]; then
  say "bundle:  ${BUNDLE#"$ORC_ROOT"/}  ($(plural "$n_md" "markdown file" "markdown files"), none verified by anybody yet)"
else
  say "bundle:  ${BUNDLE#"$ORC_ROOT"/}  ($(plural "$n_md" "markdown file" "markdown files"), $n_ver of them verified by a person)"
fi
gap
say "Next: read the unverified ones. A concept nobody has checked is a lead, not"
say "knowledge, and prompts/refine.md tells refinement to treat it that way."
say "Recording that you read one is what turns it into the other."

[ "$sync_rc" = "0" ] && [ "$draft_rc" = "0" ]
