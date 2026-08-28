#!/usr/bin/env bash
# Back to a clean slate between test runs, in one command.
#
#   orc-reset.sh                 clear state/, and prune the clones proved safe
#   orc-reset.sh --dry-run       print exactly what would go, and remove nothing
#   orc-reset.sh --yes           no confirmation, for a loop or a script
#   orc-reset.sh --state-only    the cache only; no clone is read or touched
#
# Two halves, and they are deliberately not the same kind of thing.
#
# state/ goes unconditionally and with no ceremony. It is a cache over Jira and
# git by design and bin/orc-reconcile.sh rebuilds it, so anything that would make
# deleting it painful is a bug rather than a reason to ask twice.
#
# clones/ is disk that may hold the only copy of somebody's afternoon, so nothing
# here decides what may go. bin/orc-repos-sync.sh --prune decides: it removes
# only what clone_removal_safety proved holds nothing that exists nowhere else -
# clean working tree including untracked files, no stash, no commit or branch
# that no remote has, no detached HEAD holding unique work - and refuses every
# other one by name with the reason. This composes that command. It does not
# repeat the reasoning and it does not remove a clone itself.
#
# So there is no recursive remove in this script and there must never be one.
# There is exactly one in this repository, fenced in bin/orc-repos-sync.sh
# between the SOLE-CLONE-REMOVE-REGION markers, and bin/orc-check.sh fails if a
# second appears anywhere. That is not a rule to be worked around: rm cannot
# refuse, so its safety has to be established before it is called rather than
# inside the command, and the proof for a clone is clone_removal_safety plus a
# flag an operator typed. A second remove here would be a second place that
# proof would have to be made, and a proof made twice is a proof that can
# disagree with itself.
#
# state/ is therefore cleared as what it is - flat files removed as flat files,
# then rmdir over the directories deepest first. rmdir refuses a directory that
# still holds something instead of discarding it, which is a report rather than a
# loss, and that refusal is the only reason this needs no recursive remove.
#
# The clones go first and state/ goes last. --prune syncs as well as prunes, and
# a sync writes its freshness stamps and git's own output into state/ - cleared
# first, a reset would end with a state/ the reset itself had refilled. For the
# same reason the cache is enumerated twice: once to say what is there, and again
# at the moment it is cleared, because by then the sync has added to it.
#
# ## What a local reset cannot do, and says so on the way out
#
# It does not make the same tickets judge again.
#
# Every comment refinement posts carries the revision of the ticket text it
# judged, and bin/orc-reconcile.sh reads those markers back out of Jira. That is
# exactly what keeps a wiped state/ from re-judging a whole project and posting a
# second comment on every ticket in it: the memory is on the tickets, and the
# cache is a cache of it.
#
# So a reset followed by a run re-learns what was already judged and judges
# nothing. An operator who was not told that concludes refinement is broken when
# it is working precisely as designed, which makes a silent reset worse than no
# reset command at all. The closing report says it in those words and names the
# ways forward, because a diagnostic that misleads is worse than one that says
# nothing.
#
# ## What it never touches
#
# data/gaps.jsonl, which is where bin/orc-gap-loop.sh keeps what refinement could
# not resolve. That list is the one thing under state/ nothing can rebuild - a
# refinement comment carries no term list, so bin/orc-reconcile.sh cannot read it
# back - so it lives outside both caches on purpose, and this reports what state/
# holds that the ledger has not seen before it removes anything.
#
# .okf/ and config/projects.yml. Both are source, a human consented to what is in
# them, and neither is derived from anything this could rebuild. Discarding the
# bundle is bin/orc-onboard.sh reset, which asks for a typed phrase naming how
# many verified concepts are about to go - and that is the right weight for it,
# which is the whole reason it is not folded in here, where what is at stake is
# two caches and the ceremony is one y/N.
#
# Exit codes: 0 the reset did what it printed, 1 it was declined, or something it
# proved safe to remove is still on disk afterwards.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd git du find sort

# Beside this script, not under ORC_ROOT: ORC_ROOT is overridable, and a run that
# pointed it elsewhere would compose a script that is not this one.
BIN=$(cd "$(dirname "$0")" && pwd)
SYNC="$BIN/orc-repos-sync.sh"

assume_yes=0
dry_run=0
state_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)        assume_yes=1 ;;
    --dry-run)    dry_run=1 ;;
    --state-only) state_only=1 ;;
    -h|--help)    orc_usage "$0"; exit 0 ;;
    -*)           orc_die "unknown option: $1" ;;
    *)            orc_die "this takes no arguments, only flags: $1" ;;
  esac
  shift
done

# One says it removes nothing and the other says it does not ask. Together they
# read as "remove everything without asking", which is the one thing --dry-run
# exists to be incapable of.
if [ "$dry_run" = "1" ] && [ "$assume_yes" = "1" ]; then
  orc_die "--dry-run removes nothing, so there is nothing for --yes to consent to; pick one"
fi

n_lines() { printf '%s' "$1" | grep -c . | tr -d ' '; }

# --- what is in the cache ---------------------------------------------------
#
# Files and symlinks in one list, directories in another and deepest first. A
# symlink is removed as the link it is and never followed: what it points at is
# somewhere else, and this has no claim on it.
state_files() {
  [ -d "$STATE_DIR" ] || return 0
  find "$STATE_DIR" -mindepth 1 \( -type f -o -type l \) 2>/dev/null | sort
}

state_subdirs() {
  [ -d "$STATE_DIR" ] || return 0
  find "$STATE_DIR" -mindepth 1 -depth -type d 2>/dev/null
}

# --- what is in the clone tree ----------------------------------------------
#
# The same readers bin/orc-repos-sync.sh uses to decide, called here only to say
# in advance what that command will conclude. Asking the same functions is the
# point: a report that worked the safety rule out for itself could disagree with
# the command that acts on it, and then one of the two numbers would be a lie.
orphans=""   # path<TAB>safe|unsafe<TAB>reason<TAB>kb
n_orphan=0 n_safe=0 kb_safe=0

scan_clones() {
  local path safety verdict reason kb
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Two steps deliberately. `IFS=$'\t' read ... <<< "$(f)"` runs f with IFS
    # already set to a tab, and a reader that word-splits anything then answers a
    # different question than the same reader called any other way.
    safety=$(clone_removal_safety "$path")
    IFS=$'\t' read -r verdict reason <<< "$safety"
    kb=$(dir_size_kb "$path")
    orphans="$orphans$path	$verdict	$reason	${kb:-0}
"
    n_orphan=$(( n_orphan + 1 ))
    if [ "$verdict" = "safe" ]; then
      n_safe=$(( n_safe + 1 ))
      kb_safe=$(( kb_safe + ${kb:-0} ))
    fi
  done < <(orphan_clones)
}

# The clones the config still names and that are on disk. Reported so the listing
# above cannot be read as the whole tree: a reset that said nothing about these
# would look like it had considered them and decided.
configured_on_disk() {
  local name p
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    p=$(project_repo_path "$name")
    [ -n "$p" ] && [ -d "$p" ] && printf '%s\n' "$p"
  done < <(project_names)
}

# --- the report -------------------------------------------------------------

files=$(state_files)
n_files=$(n_lines "$files")
kb_state=0
[ -d "$STATE_DIR" ] && kb_state=$(dir_size_kb "$STATE_DIR")

[ "$state_only" = "1" ] || scan_clones
cfg_clones=$(configured_on_disk)
n_cfg=$(n_lines "$cfg_clones")

if [ "$dry_run" = "1" ]; then step "what a reset would remove"; else step "what this removes"; fi

say "state/  ($STATE_DIR)"
if [ "$n_files" = "0" ]; then
  say "    nothing in it already"
else
  say "    $(plural "$n_files" file files), $(human_kb "${kb_state:-0}")"
  say "    a cache over Jira and git; bin/orc-reconcile.sh rebuilds it"
fi
gap

if [ "$state_only" = "1" ]; then
  say "clones/ left alone entirely, because --state-only was passed."
elif [ "$n_orphan" = "0" ]; then
  say "clones/ nothing on disk that $(basename "$PROJECTS_FILE") does not name, so a prune has nothing to offer."
else
  say "clones/ $(plural "$n_orphan" clone clones) on disk that $(basename "$PROJECTS_FILE") does not name."
  say "    Each was checked for anything that exists nowhere else: uncommitted"
  say "    changes, a stash, commits or branches no remote has, a detached HEAD"
  say "    holding unique work."
  gap
  while IFS=$'\t' read -r path verdict reason kb; do
    [ -n "$path" ] || continue
    say "    $path"
    # The same two words bin/orc-repos-sync.sh uses for the same verdict, so the
    # two listings cannot be read as two different judgements.
    if [ "$verdict" = "safe" ]; then
      say "      safe to remove, $(human_kb "$kb")"
    else
      say "      UNSAFE, so it stays: $reason"
    fi
  done <<< "$orphans"
  gap
  if [ "$n_safe" = "0" ]; then
    say "    Not one of them can be shown to hold only what a remote already has,"
    say "    so every one is kept. There is no flag here that overrules that."
  else
    say "    That is $(human_kb "$kb_safe") in $(plural "$n_safe" clone clones)."
  fi
fi
gap

if [ "$n_cfg" != "0" ] && [ "$state_only" = "0" ]; then
  say "Left where they are: $(plural "$n_cfg" clone clones) $(basename "$PROJECTS_FILE") still names. A clone the config points at is not stale state - bin/orc-repos-sync.sh brings it level with the branch the config names, and clearing the freshness stamps above is what makes the next sync do the reading again rather than trust its own window."
  gap
fi
say "Untouched either way: .okf/ and $(basename "$PROJECTS_FILE"). Both are source, and discarding the bundle is bin/orc-onboard.sh reset, which asks for a typed phrase naming the verified concepts about to go."
gap
# Asked at the moment somebody is about to clear a cache they have been signing
# things out of, because that is when the question occurs to them.
say "So is every decision somebody signed off. ${VERIFY_LEDGER#"$ORC_ROOT"/} is in data/ rather than in either cache, for the same reason ${GAP_LEDGER#"$ORC_ROOT"/} is: nothing can re-derive a person's judgement. The answer rows bin/orc-verify.sh reviews are re-read from the Jira comments by bin/orc-harvest.sh, so what goes here is the reading rather than the decision."

# --- the one thing in the cache nothing can rebuild --------------------------
#
# Every other file under state/ is a cache of something Jira or git still holds,
# which is why clearing it needs one y/N. A verdict's list of the ticket's words
# refinement could not resolve is the exception: a refinement comment deliberately
# carries no term list, so bin/orc-reconcile.sh cannot read it back, and
# re-deriving it means refining the ticket again under whatever prompt is current
# rather than the one that produced the observation.
#
# bin/orc-gap-loop.sh copies it into a ledger outside both caches. What it has not
# copied yet goes with this, and that is worth one paragraph before the y/N rather
# than a discovery afterwards - the same reason the ticket-marker report exists.
gap_record_warning() {
  local unrecorded n
  unrecorded=$(gap_unrecorded)
  n=$(n_lines "$unrecorded")
  [ "$n" != "0" ] || return 0
  banner "A GAP RECORD IS ABOUT TO GO WITH THE CACHE

$(plural "$n" "verdict record" "verdict records") under state/ names words refinement could not resolve, and ${GAP_LEDGER#"$ORC_ROOT"/} has not seen $(plural "$n" "it" "them") yet. That list is the one thing in this cache nothing can rebuild: a refinement comment carries no term list on purpose, so bin/orc-reconcile.sh has nothing to read it back out of, and refining the ticket again answers under whatever prompt is current rather than the one that produced the observation.

$(printf '%s' "$unrecorded" | awk -F'\t' 'NF { printf "  %s (prompt %s)\n", $1, $2 }')
Run this first and it becomes a record that survives every reset after it:

  bin/orc-gap-loop.sh

Nothing here writes to that ledger. This command clears caches, and a command that quietly wrote a record on its way past would be doing something an operator asking for a clean slate did not ask for."
}
gap_record_warning

# --- what a reset cannot do -------------------------------------------------
#
# Printed on a dry run too, and printed when there was nothing to remove. The
# operator ran this expecting a fresh start, and that expectation is the thing
# being corrected rather than the removal.
ticket_memory() {
  banner "THE SAME TICKETS WILL STILL NOT BE RE-JUDGED

That is by design, and no local reset can change it. Every comment refinement posts carries the revision of the ticket text it judged, and bin/orc-reconcile.sh reads those markers back out of Jira - which is exactly what stops a cleared cache from judging a whole project a second time and commenting on every ticket in it.

So pointing the daemon at the same project after this re-learns what was already judged and then judges nothing. Nothing is broken when that happens, and it is the property that makes the cache disposable in the first place.

There are three ways to get a run that judges something, and none of them is a flag on this command.

A ticket nothing has judged yet. Or one whose summary or description has changed since it was judged: the marker records the text rather than the fact, so an edited ticket is judged again on its own.

The orchestrator's own comments and labels taken off the tickets you want judged again, by hand in Jira. The comments are the ones whose last line reads $ORC_COMMENT_MARKER; the labels are $LABEL_READY, $LABEL_NEEDS_INPUT, $LABEL_DUPLICATE and $LABEL_IN_PROGRESS.

Or bin/orc-daemon.sh --force, which judges again whatever the marker says. That is the quickest, and it is honest about what it leaves behind: a second comment beside the first, rather than a ticket that looks as though nothing had judged it.

Nothing here removes a comment or a label. A tool that deleted its own comments out of a project it was pointed at is a tool that could delete a person's, and those comments are the only record a cleared cache is rebuilt from."
}

if [ "$dry_run" = "1" ]; then
  step "nothing was removed"
  say "--dry-run, so every line above is what a run without it would do."
  ticket_memory
  exit 0
fi

if [ "$assume_yes" = "0" ]; then
  gap
  say "Type y to proceed. Anything else stops, and nothing has been removed yet."
  ask "--yes answers this for a script or a loop, and --dry-run prints this report without asking"
  case "$ANSWER" in
    y|Y|yes|YES) gap ;;
    *) gap; say "Nothing was removed."; exit 1 ;;
  esac
fi

# --- the clones, delegated --------------------------------------------------

failed=""

prune_clones() {
  local rc=0 path verdict _reason _kb
  step "clones"
  if [ "$n_orphan" = "0" ]; then
    say "nothing to prune."
    return 0
  fi
  say "$(basename "$SYNC") --prune is the only thing in this repository that may remove a clone, so it does the removing and reports it."
  gap
  "$SYNC" --prune --quiet || rc=$?
  if [ "$rc" != "0" ]; then
    say "That command reports at least one repository it could not advance, and its report above names which and why. That is its sync half rather than a failed prune: nothing it could not read was removed."
  fi
  # Verified rather than trusted. It is the one thing this script promises about
  # a directory it did not touch itself.
  while IFS=$'\t' read -r path verdict _reason _kb; do
    [ -n "$path" ] || continue
    [ "$verdict" = "safe" ] || continue
    [ -e "$path" ] || continue
    failed="$failed  $path
"
  done <<< "$orphans"
}

[ "$state_only" = "1" ] || prune_clones

# --- the cache --------------------------------------------------------------
#
# rm -f over a file list and rmdir over the directories, deepest first. Never a
# directory tree: bin/orc-check.sh fails if a second recursive remove appears
# anywhere in this repository, and the reason it is right to is in the header.
#
# Both loops are fed from a here-string. $( ) strips the trailing newline, so
# `read` returns false on a partial last line and a piped loop silently skips it,
# which is how a confirmed discard once announced a file it had left on disk.
clear_state() {
  local f d now dirs n=0 kept=0
  step "state"
  # Enumerated again here rather than reusing the list the report was built from.
  # The prune above syncs as well as prunes, and a sync writes its freshness
  # stamps and git's own output into state/ - so the cache at this moment is not
  # the cache that was measured, and clearing the measured one would leave the
  # difference behind. Which is the whole reason the clones go first.
  now=$(state_files)
  # Captured before either loop rather than read out of a command substitution on
  # the here-string, so neither reader runs with the loop's own IFS in effect.
  dirs=$(state_subdirs)
  if [ -z "$now" ] && [ -z "$dirs" ]; then
    say "already empty."
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f" || orc_die "could not remove $f"
    n=$(( n + 1 ))
  done <<< "$now"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # rmdir refuses a directory that still holds something. That refusal is the
    # report - a recursive remove here would discard whatever it was instead.
    if ! rmdir "$d" 2>/dev/null; then
      say "left $d alone: rmdir refused it, so there is still something in there"
      kept=$(( kept + 1 ))
    fi
  done <<< "$dirs"
  say "removed $(plural "$n" file files) from $STATE_DIR"
  [ "$kept" = "0" ] || say "$(plural "$kept" directory directories) stayed, named above"
}

clear_state

# --- what is left ------------------------------------------------------------

if [ -n "$failed" ]; then
  banner "SOMETHING PROVED SAFE TO REMOVE IS STILL THERE

$failed
Each of those was reported as holding nothing that exists nowhere else, and is on disk after the prune ran. That is a disagreement between the check and the removal rather than a clone to delete by hand, and the removal is the half to trust: read the report above before doing anything to them yourself."
  exit 1
fi

ticket_memory
exit 0
