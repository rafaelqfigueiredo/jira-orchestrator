#!/usr/bin/env bash
# Clones the repositories config/projects.yml names, and fast-forwards the ones
# already on disk. The orchestrator owns its clones; nothing else may assume a
# path happens to exist.
#
# Fast-forward only, and that is the entire safety model:
#
#   no force, no reset, no stash, no checkout of an existing clone, no clean,
#   no pull, and nothing discarded for any reason.
#
# A clone that cannot move forward without losing something is reported and left
# exactly as it was found. The only thing worse than a stale checkout is a
# supervisor that "fixes" one by throwing away whatever was in it, and section 6
# is explicit that the orchestrator never writes to a target repository -
# fast-forwarding a clone it created itself is the single sanctioned exception.
#
#   orc-repos-sync.sh                  every project in the config
#   orc-repos-sync.sh api dashboard    only these
#   orc-repos-sync.sh --status         report what is on disk, write nothing
#   orc-repos-sync.sh --force          ignore the freshness cache
#   orc-repos-sync.sh --quiet          the table only, no preamble
#   orc-repos-sync.sh --prune          also delete the orphaned clones that have
#                                      been proved to hold nothing unique
#
# Every repository reports exactly one outcome:
#
#   ok         already level with the branch the config names
#   cloned     it was not on disk; it is now, on that branch
#   advanced   fast-forwarded, and by how many commits
#   unmanaged  no remote here, so this clone is not the orchestrator's to move
#   ORPHANED   a clone on disk that no project in the config names. Reported and
#              never removed by a sync: the operator who deleted a line from the
#              config was thinking about the config, and this is the largest
#              discard in the codebase turning up at the moment nobody is looking
#              for it. --prune removes it, and only after clone_removal_safety
#              has proved there is nothing in it that exists nowhere else.
#              Not a failure, so it does not change the exit code.
#   AUTH       git could not authenticate to the remote. Its own outcome, and
#              not counted as stuck: nothing is in the way of the clone, the
#              remote is spelled in a protocol these credentials cannot use.
#              Never repaired here - the config is source, so this reports the
#              mismatch and prints the command that converts it.
#   STUCK      something is in the way. Named, counted, and untouched.
#
# Failures are grouped by cause rather than by repository. Ten repositories that
# failed for one reason are one report naming ten projects, because ten copies of
# one box bury the summary line underneath them.
#
# Exit codes: 0 every repository is usable, 1 at least one is not.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

require_cmd git du

# How long a fetch is considered fresh. Refinement calls this script before it
# reasons, and a five-ticket pass must not mean five fetches of the same three
# repositories. The stamps live in state/, which is a cache: deleting them costs
# one extra fetch and nothing else.
TTL="${ORC_REPO_SYNC_TTL:-300}"
SYNC_DIR="$STATE_DIR/.repos"
STUCK_LOUD_AFTER=3
# What counts as "a run" for the stuck counter, and it is a window rather than an
# invocation of this script. The daemon syncs once per pass and refinement asks
# again per ticket, so a five-ticket pass is six invocations and exactly one run.
# Counting invocations announced "STUCK 3 RUNS IN A ROW" during the first pass,
# which was false, and a counter that cries wolf on run one is worse than no
# counter. The window is the freshness window because it is the same window for
# the same reason: repeated attempts inside it are one attempt.
STUCK_RUN_WINDOW="${ORC_STUCK_RUN_WINDOW:-$TTL}"

status_only=0
force=0
quiet=0
prune=0
wanted=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status)  status_only=1 ;;
    --force)   force=1 ;;
    --quiet)   quiet=1 ;;
    --prune)   prune=1 ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    -*)        orc_die "unknown option: $1" ;;
    *)         wanted="$wanted $1" ;;
  esac
  shift
done

# One says it writes nothing and the other says it deletes. Guessing which one
# the operator meant is not this script's business.
if [ "$status_only" = "1" ] && [ "$prune" = "1" ]; then
  orc_die "--status writes nothing and --prune deletes; pick one"
fi

mkdir -p "$SYNC_DIR"

# --- BEGIN SOLE-CLONE-WRITE-REGION ------------------------------------------
# The only code in this repository that writes to a clone. Three commands, and
# every one of them refuses rather than discards:
#
#   git clone --branch    only when the directory does not exist, and always on
#                         the branch the config names, never on whatever the
#                         remote calls its default
#   git fetch             objects and remote-tracking refs. Touches no local
#                         branch and no working tree.
#   git merge --ff-only   moves the branch pointer or fails. It cannot rewrite
#                         history, and it cannot overwrite an uncommitted edit.
#
# bin/orc-check.sh fails if a mutating git command appears anywhere outside
# these markers, and fails if this region ever grows a fourth command.
#
# GIT_TERMINAL_PROMPT=0 is not a fourth command and it changes nothing about what
# these three do. It stops git asking a question nobody is there to answer: an
# unauthenticated https remote otherwise blocks on a username prompt forever,
# which reads as a hang and reports nothing.
_repo_clone() { GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$3" "$1" "$2"; }
_repo_fetch() { GIT_TERMINAL_PROMPT=0 git -C "$1" fetch --quiet --prune "$ORC_REPO_REMOTE"; }
_repo_ff()    { git -C "$1" merge --quiet --ff-only "$2"; }
# --- END SOLE-CLONE-WRITE-REGION --------------------------------------------

# --- BEGIN SOLE-CLONE-REMOVE-REGION -----------------------------------------
# The only code in this repository that deletes a clone, and deliberately its own
# region rather than a fourth line in the one above.
#
# The write region's promise is absolute and mechanically checked: three
# commands, and every one of them refuses rather than discards. A deletion cannot
# join a list whose defining property is that nothing on it can discard anything.
# It would still count as three git commands - it is not a git command - so the
# region would keep passing its own check while its comment had quietly become
# false, and a guard that reads as true while being false is worse than no guard.
#
# The two writes also earn their safety in different places. A fast-forward is
# safe because git itself refuses the move when it would lose something: the
# proof is inside the command, which is why the write region can promise
# something about its contents alone. A removal has no such command - rm cannot
# refuse - so the proof has to be established before it is called, and lives in
# clone_removal_safety plus a flag the operator typed. Two different proofs, two
# different fences.
#
# One function, two callers, and each states its proof:
#
#   the clone that failed   a directory this invocation created seconds ago and
#                           that git then failed to fill. Nothing was ever in it
#                           that anybody put there.
#   --prune                 clone_removal_safety returned safe, and the operator
#                           passed the flag. Neither one alone is enough.
#
# bin/orc-check.sh fails if a recursive remove appears anywhere in this script
# outside these markers.
_clone_remove() {
  local path="$1" real depth
  [ -n "$path" ] || orc_die "refusing to remove an empty path"
  [ ! -L "$path" ] || orc_die "refusing to remove $path: it is a symlink, so the clone is elsewhere"
  [ -d "$path" ] || orc_die "refusing to remove $path: it is not a directory"
  real=$(orc_real_path "$path")
  [ "$real" != "$(orc_real_path "$CLONE_DIR")" ] \
    || orc_die "refusing to remove $path: that is the clone tree, not a clone in it"
  [ "$real" != "$(orc_real_path "$ORC_ROOT")" ] \
    || orc_die "refusing to remove $path: that is the orchestrator itself"
  # A clone lives somewhere. "/" and "/Users" are not somewhere, and a config
  # that names one of them is a typo whose report would arrive far too late to be
  # of any use.
  depth=$(printf '%s' "$real" | awk -F/ '{print NF - 1}')
  [ "${depth:-0}" -ge 2 ] \
    || orc_die "refusing to remove $path: too close to the root to be a clone"
  rm -rf "$path"
}
# --- END SOLE-CLONE-REMOVE-REGION -------------------------------------------

# The stamp shape itself is in orc-lib.sh, shared with the bundle drift check:
# both are "was this expensive read done recently enough", and two answers to
# that question would eventually disagree about a stamp that is missing or
# unreadable. --force is the one thing only this caller has an opinion about.
fresh_enough() {
  [ "$force" = "0" ] || return 1
  stamp_is_fresh "$SYNC_DIR/$1.fetched" "$TTL"
}

mark_fetched() { stamp_write "$SYNC_DIR/$1.fetched"; }

# A repository that keeps failing to advance is the failure this reporting
# exists for, so the count survives across runs and the banner is unmissable.
#
# The file holds the count and when it was last bumped, because a count with no
# timestamp cannot tell six invocations in one pass from six passes, and the
# difference is the whole meaning of the number.
_stuck_read() {
  local f="$SYNC_DIR/$1.stuck" n="" t=""
  # Tested rather than redirected away: a failing input redirection is reported by
  # the shell before the 2>/dev/null on the same line is in effect, so the usual
  # trick leaks "No such file or directory" for what is simply a first run.
  if [ -f "$f" ]; then
    IFS=$'\t' read -r n t < "$f"
  fi
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  case "${t:-}" in ''|*[!0-9]*) t=0 ;; esac
  printf '%s\t%s' "$n" "$t"
}

stuck_count() { _stuck_read "$1" | cut -f1; }

# Bumped once per run, not once per invocation.
stuck_bump() {
  local n t now
  IFS=$'\t' read -r n t <<< "$(_stuck_read "$1")"
  now=$(orc_epoch)
  if [ "$n" -gt 0 ] && [ "$STUCK_RUN_WINDOW" -gt 0 ] \
     && [ "$(( now - t ))" -lt "$STUCK_RUN_WINDOW" ]; then
    : # same run, already counted
  else
    n=$(( n + 1 ))
  fi
  printf '%s\t%s\n' "$n" "$now" > "$SYNC_DIR/$1.stuck"
}

stuck_clear() { rm -f "$SYNC_DIR/$1.stuck"; }

# "1 repository" and "10 repositories". "repository/ies" is a placeholder that
# shipped, and this report is read at the moment somebody is already annoyed.
repos_n() {
  if [ "$1" = "1" ]; then printf '1 repository'; else printf '%s repositories' "$1"; fi
}

# An orphan is a directory, not a repository the orchestrator has any opinion
# about, and calling it one in the report invites the reader to look for it in the
# config it is not in.
clones_n() {
  if [ "$1" = "1" ]; then printf '1 clone'; else printf '%s clones' "$1"; fi
}

rows=""
# kind<TAB>project<TAB>reason<TAB>remote, one line per failure. Reported grouped
# by kind and reason, so a shared cause is stated once.
fails=""
# path<TAB>safe|unsafe<TAB>reason<TAB>size<TAB>branch<TAB>sha, one line per clone
# the config does not name. Recorded before anything is removed, because the row
# has to be printable after the directory is gone.
orphans=""
pruned=""   # path<TAB>kb
kept=""     # path<TAB>reason
n_ok=0 n_cloned=0 n_advanced=0 n_stuck=0 n_unmanaged=0 n_auth=0 n_orphaned=0
n_orphan_safe=0 kb_orphan_safe=0

row() { rows="$rows$1	$2	$3	$4	$5
"; }

fail_add() {
  fails="$fails$1	$2	$3	${4:--}
"
}

mark_stuck() {
  local name="$1" reason="$2" sha="${3:--}" branch="${4:--}"
  stuck_bump "$name"
  row "$name" "STUCK" "$branch" "$sha" "$reason"
  fail_add "STUCK" "$name" "$reason"
  n_stuck=$(( n_stuck + 1 ))
}

# Authentication is not stuckness. Nothing is in the way of this clone and there
# is nothing on disk to repair: the remote is spelled in a protocol these
# credentials cannot use, which is a one-line fix in a file only a human may
# change. Reported as itself so it is not looked for in the wrong place.
mark_auth() {
  local name="$1" reason="$2" remote="$3"
  stuck_clear "$name"
  row "$name" "AUTH" "-" "-" "$reason"
  fail_add "AUTH" "$name" "$reason" "$remote"
  n_auth=$(( n_auth + 1 ))
}

# git_failure <project> <what> <remote> [sha] [branch]
#
# One place decides which of the two a git failure is, and it reports the first
# meaningful line of git's own stderr either way. The full capture stays on disk.
git_failure() {
  local name="$1" what="$2" remote="$3" sha="${4:--}" branch="${5:--}"
  local err="$SYNC_DIR/$name.err" first
  first=$(git_first_error "$err" | cut -c1-100)
  if git_error_is_auth "$err"; then
    mark_auth "$name" "$first" "$remote"
  else
    mark_stuck "$name" "$what: $first" "$sha" "$branch"
  fi
}

# Reports the state of one repository without touching it, and returns 1 when
# that state means the caller must not touch it either.
report_state() {
  local name="$1" st sha br detail
  IFS=$'\t' read -r st sha br detail <<< "$(repo_state "$name")"
  case "$st" in
    ok)        stuck_clear "$name"; row "$name" "ok" "$br" "$sha" "$detail"; n_ok=$(( n_ok + 1 )) ;;
    unmanaged) stuck_clear "$name"; row "$name" "unmanaged" "$br" "$sha" "$detail"; n_unmanaged=$(( n_unmanaged + 1 )) ;;
    # Nothing configured is a valid setup - refinement localises from the
    # knowledge bundle alone and says so - not a clone that failed to appear.
    unconfig)  stuck_clear "$name"; row "$name" "unmanaged" "-" "-" "$detail"; n_unmanaged=$(( n_unmanaged + 1 )) ;;
    absent)    mark_stuck "$name" "$detail" ;;
    *)         mark_stuck "$name" "$detail" "$sha" "$br" ;;
  esac
}

sync_one() {
  local name="$1" remote path want st sha br detail before after behind actual

  remote=$(project_field "$name" remote)
  path=$(project_repo_path "$name")
  want=$(project_default_branch "$name")

  if [ -z "$remote" ]; then
    report_state "$name"
    return 0
  fi
  if [ -z "$path" ]; then
    mark_stuck "$name" "no repo path could be resolved"
    return 0
  fi
  if [ -z "$want" ]; then
    # Never guessed. A refinement reasoned against the wrong branch is worse
    # than one that says it could not read the code at all.
    mark_stuck "$name" "no default_branch in $(basename "$PROJECTS_FILE"); it is never assumed"
    return 0
  fi

  if [ ! -e "$path" ]; then
    if [ "$status_only" = "1" ]; then
      report_state "$name"
      return 0
    fi
    mkdir -p "$(dirname "$path")"
    if ! _repo_clone "$remote" "$path" "$want" 2>"$SYNC_DIR/$name.err"; then
      # A directory this invocation created a moment ago and that git then failed
      # to fill. Removing it is the one deletion that needs no proof, and it goes
      # through the same function as the one that does, so a recursive remove
      # appears in exactly one place.
      [ -d "$path" ] && _clone_remove "$path"
      git_failure "$name" "clone failed" "$remote"
      return 0
    fi
    mark_fetched "$name"
    stuck_clear "$name"
    sha=$(git_read "$path" rev-parse HEAD | cut -c1-12)
    row "$name" "cloned" "$want" "$sha" "cloned from $remote"
    n_cloned=$(( n_cloned + 1 ))
    return 0
  fi

  if ! is_git_repo "$path"; then
    mark_stuck "$name" "$path exists but is not a git repository"
    return 0
  fi

  # Never re-point a remote. If the config and the clone disagree about which
  # repository this is, a human decides which one is wrong.
  actual=$(git_read "$path" remote get-url "$ORC_REPO_REMOTE" 2>/dev/null)
  if [ "$(remote_key "$actual")" != "$(remote_key "$remote")" ]; then
    mark_stuck "$name" "$ORC_REPO_REMOTE is ${actual:-unset}, the config says $remote"
    return 0
  fi

  # Anything dirty, detached or diverged is reported and left alone. Fetching
  # would be harmless, but "left untouched" is easier to trust than "touched
  # only in ways we believe to be harmless".
  IFS=$'\t' read -r st sha br detail <<< "$(repo_state "$name")"
  case "$st" in
    stale)
      case "$detail" in
        *"behind $ORC_REPO_REMOTE"*|*"is unknown here"*) : ;;
        *) mark_stuck "$name" "$detail" "$sha" "$br"; return 0 ;;
      esac
      ;;
  esac

  if [ "$status_only" = "1" ]; then
    report_state "$name"
    return 0
  fi

  before=$(git_read "$path" rev-parse HEAD)
  if fresh_enough "$name"; then
    log "$name: fetched less than ${TTL}s ago, not fetching again"
  elif ! _repo_fetch "$path" 2>"$SYNC_DIR/$name.err"; then
    git_failure "$name" "fetch failed" "$remote" "$(printf '%s' "$before" | cut -c1-12)" "$br"
    return 0
  else
    mark_fetched "$name"
  fi

  IFS=$'\t' read -r st sha br detail <<< "$(repo_state "$name")"
  if [ "$st" = "ok" ]; then
    stuck_clear "$name"
    row "$name" "ok" "$br" "$sha" "$detail"
    n_ok=$(( n_ok + 1 ))
    return 0
  fi

  behind=$(printf '%s' "$detail" | sed -n 's/^\([0-9]*\) commit(s) behind.*/\1/p')
  if [ -z "$behind" ]; then
    mark_stuck "$name" "$detail" "$sha" "$br"
    return 0
  fi

  if ! _repo_ff "$path" "$ORC_REPO_REMOTE/$want" 2>"$SYNC_DIR/$name.err"; then
    mark_stuck "$name" "fast-forward refused: $(git_first_error "$SYNC_DIR/$name.err" | cut -c1-100)" "$sha" "$br"
    return 0
  fi

  after=$(git_read "$path" rev-parse HEAD | cut -c1-12)
  if [ "$after" = "$(printf '%s' "$before" | cut -c1-12)" ]; then
    mark_stuck "$name" "fast-forward reported success but the branch did not move" "$after" "$br"
    return 0
  fi
  stuck_clear "$name"
  row "$name" "advanced" "$want" "$after" "$behind commit(s) from $ORC_REPO_REMOTE/$want"
  n_advanced=$(( n_advanced + 1 ))
}

# Clones the config no longer names, and whether removing one could lose
# anything. Reads only: the answer is recorded here and acted on nowhere unless
# --prune was passed.
#
# Orphan-ness is decided against the whole config and never against the project
# names given on the command line. `orc-repos-sync.sh api --prune` must not
# conclude that dashboard is an orphan because it went unmentioned, which is why
# this reads the config directly instead of the filtered list the sync loop uses.
scan_orphans() {
  local path verdict reason kb br sha safety
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Two steps deliberately. `IFS=$'\t' read ... <<< "$(f)"` runs f with IFS
    # already set to a tab, and a reader that word-splits anything then answers a
    # different question than the same reader called any other way.
    safety=$(clone_removal_safety "$path")
    IFS=$'\t' read -r verdict reason <<< "$safety"
    kb=$(dir_size_kb "$path")
    br=""; sha=""
    if is_git_repo "$path"; then
      sha=$(git_read "$path" rev-parse HEAD 2>/dev/null | cut -c1-12)
      br=$(git_read "$path" symbolic-ref --short -q HEAD 2>/dev/null)
    fi
    orphans="$orphans$path	$verdict	$reason	${kb:-0}	${br:-detached}	${sha:--}
"
    n_orphaned=$(( n_orphaned + 1 ))
    if [ "$verdict" = "safe" ]; then
      n_orphan_safe=$(( n_orphan_safe + 1 ))
      kb_orphan_safe=$(( kb_orphan_safe + ${kb:-0} ))
    fi
  done < <(orphan_clones)
}

# Removes the ones that were proved safe and refuses the rest with the reason.
# The refusal is the point: an operator who typed --prune has already decided they
# want the disk back, and the only thing standing between that decision and
# somebody's uncommitted afternoon is this function declining to act on it.
prune_orphans() {
  local path verdict reason kb
  while IFS=$'\t' read -r path verdict reason kb _rest; do
    [ -n "$path" ] || continue
    if [ "$verdict" = "safe" ]; then
      _clone_remove "$path"
      pruned="$pruned$path	$kb
"
    else
      kept="$kept$path	$reason
"
    fi
  done <<< "$orphans"
}

orphan_rows() {
  local path verdict reason kb br sha cfg detail
  cfg=$(basename "$PROJECTS_FILE")
  while IFS=$'\t' read -r path verdict reason kb br sha; do
    [ -n "$path" ] || continue
    if _line_is_in "$path	$kb" "$pruned"; then
      detail="not in $cfg; $(human_kb "$kb"); REMOVED by --prune"
    elif [ "$verdict" = "safe" ]; then
      detail="not in $cfg; $(human_kb "$kb"); safe to remove"
    else
      detail="not in $cfg; $(human_kb "$kb"); UNSAFE: $reason"
    fi
    row "$(basename "$path")" "ORPHANED" "$br" "$sha" "$detail"
  done <<< "$orphans"
}

names="$wanted"
if [ -z "$names" ]; then
  names=$(project_names)
else
  for name in $names; do
    [ -n "$(project_field "$name" repo)$(project_field "$name" remote)" ] \
      || orc_die "$name is not in $(basename "$PROJECTS_FILE")"
  done
fi
# Before the early exit, not after it. A config emptied of every project is
# exactly when the clone tree is entirely orphaned, and "nothing to sync" is the
# least useful thing that could be said at that moment.
scan_orphans

if [ -z "$names" ] && [ "$n_orphaned" = "0" ]; then
  log "no projects in $PROJECTS_FILE; nothing to sync"
  exit 0
fi

if [ "$quiet" = "0" ]; then
  if [ -z "$names" ]; then
    log "no projects in $PROJECTS_FILE, and $(clones_n "$n_orphaned") on disk it does not name"
  elif [ "$status_only" = "1" ]; then
    log "reading the clones named in $PROJECTS_FILE; writing nothing"
  else
    log "syncing the clones named in $PROJECTS_FILE (fast-forward only)"
  fi
fi

for name in $names; do
  sync_one "$name"
done

[ "$prune" = "0" ] || prune_orphans
orphan_rows

# Column widths come from the content, because they have to: a real fleet's
# project names run past twenty characters, which is wider than any number
# anyone would hardcode, and a name that overflows its column pushes every
# column after it out of line - that makes the whole table unreadable rather
# than just that one row.
printf '\n'
printf '%s' "$rows" | awk -F'\t' '
  NF {
    n++; p[n] = $1; o[n] = $2; b[n] = $3; c[n] = $4; d[n] = $5
    if (length($1) > w1) w1 = length($1)
    if (length($2) > w2) w2 = length($2)
    if (length($3) > w3) w3 = length($3)
    if (length($4) > w4) w4 = length($4)
    if (length($5) > w5) w5 = length($5)
  }
  END {
    if (length("PROJECT") > w1) w1 = length("PROJECT")
    if (length("OUTCOME") > w2) w2 = length("OUTCOME")
    if (length("BRANCH")  > w3) w3 = length("BRANCH")
    if (length("COMMIT")  > w4) w4 = length("COMMIT")
    if (length("DETAIL")  > w5) w5 = length("DETAIL")
    fmt = "  %-" w1 "s  %-" w2 "s  %-" w3 "s  %-" w4 "s  %s\n"
    printf fmt, "PROJECT", "OUTCOME", "BRANCH", "COMMIT", "DETAIL"
    # DETAIL is the last column and is not padded, so it is not allowed to drive
    # the rule: one long path in it would otherwise draw a 240-column line under a
    # table that is 90 wide.
    if (w5 > 60) w5 = 60
    width = w1 + w2 + w3 + w4 + w5 + 8
    rule = ""
    for (i = 0; i < width; i++) rule = rule "-"
    printf "  %s\n", rule
    for (i = 1; i <= n; i++) printf fmt, p[i], o[i], b[i], c[i], d[i]
    printf "  %s\n", rule
  }'
printf '  ok=%s cloned=%s advanced=%s unmanaged=%s ORPHANED=%s AUTH=%s STUCK=%s\n\n' \
  "$n_ok" "$n_cloned" "$n_advanced" "$n_unmanaged" "$n_orphaned" "$n_auth" "$n_stuck"

# The orphan report, before the failure banners because those end the output and
# an orphan is not a failure. Never truncated and never summarised away: the paths
# in it are the only actionable thing it contains.
orphan_report() {
  local body listing path kb reason
  [ "$n_orphaned" != "0" ] || return 0

  # Every paragraph is one source line. banner() rewraps prose and passes any
  # line that starts with whitespace through untouched, so a paragraph broken
  # across source lines comes out ragged and a path never comes out broken.
  if [ "$prune" = "1" ]; then
    body="PRUNED - of $(clones_n "$n_orphaned") the config does not name."
    if [ -n "$pruned" ]; then
      body="$body

Removed:
"
      while IFS=$'\t' read -r path kb; do
        [ -n "$path" ] || continue
        body="$body
  $path  ($(human_kb "$kb"))"
      done <<< "$pruned"
    else
      body="$body

Nothing was removed. Not one of them could be shown to hold only what a remote already has, and --prune is not a way to overrule that."
    fi
    if [ -n "$kept" ]; then
      body="$body

Kept, because removing one of these would discard the only copy of something:
"
      while IFS=$'\t' read -r path reason; do
        [ -n "$path" ] || continue
        body="$body
  $path
    $reason"
      done <<< "$kept"
      body="$body

--prune does not override those and there is no flag that does. Push or discard what is in them yourself, then run this again."
    fi
    banner "$body"
    return 0
  fi

  # Path on its own line, reason indented under it. Both on one line put a clone
  # path and a sentence of prose in the same 200 columns, and banner() will not
  # wrap a line that starts with whitespace - correctly, because it cannot tell
  # which half of it is a path.
  # Same thresholds as human_kb, because a listing that says 2248K under a summary
  # that says 2.2M reads as two different measurements of two different things.
  listing=$(printf '%s' "$orphans" | awk -F'\t' '
    function human(k) {
      if (k < 1024) return sprintf("%dK", k)
      if (k < 1048576) return sprintf("%.1fM", k / 1024)
      return sprintf("%.1fG", k / 1048576)
    }
    NF {
      printf "  %s\n", $1
      printf "    %s\n", ($2 == "safe" ? "safe to remove, " human($4) : "UNSAFE: " $3)
    }')
  body="ORPHANED CLONES - $(clones_n "$n_orphaned") on disk that $(basename "$PROJECTS_FILE") does not name.

Nothing was removed, and a bare sync never will. A line leaving the config is not consent to delete what it used to point at, and a deletion triggered by that edit would arrive while you were thinking about something else entirely.

Each one was checked for anything that exists nowhere else: uncommitted changes, a stash, commits or branches no remote has, a detached HEAD holding unique work. Only the ones where there was nothing at all are offered.

$listing
"
  if [ "$n_orphan_safe" = "0" ]; then
    body="$body
Not one of them can be removed safely, so --prune would refuse every one. What to do with them is a decision, and it is yours rather than this script's."
  else
    body="$body
That is $(human_kb "$kb_orphan_safe") in $(clones_n "$n_orphan_safe"). This removes the safe ones and refuses every other one, naming the reason:

  $0 --prune"
  fi
  banner "$body"
}

orphan_report

# One report per cause, not per repository. Ten repositories that failed for one
# reason are one banner naming ten projects: the tenth copy of a box says nothing
# the first said, and between them they push the summary line off the screen.
groups=$(printf '%s' "$fails" | awk -F'\t' 'NF && !seen[$1 "\t" $3]++ { print $1 "\t" $3 }')

# The command that converts an ssh config to https. Printed, never run: the
# config is source and a human consented to what is in it, the same way a Jira
# write needs two switches.
#
# It deletes its own .bak. The suffix is there because the sed macOS ships
# requires an argument to -i and will not take an empty one, so the file is a
# portability artefact rather than a safety net, and leaving it behind is a
# liability: an untracked copy of the config sitting in the working tree is a
# thing to commit by accident. The undo for this edit is git, because the config
# is tracked - and that is said in words rather than printed as a command,
# because bin/orc-check.sh forbids a state-changing git invocation anywhere in
# this script outside the write region and cannot tell a string from a call.
convert_command() {
  local host
  host=$(printf '%s' "$1" | sed -e 's#^ssh://##' -e 's#^git+ssh://##' -e 's#^[^@/]*@##' -e 's#[:/].*$##')
  [ -n "$host" ] || return 1
  printf "sed -i.bak 's#git@%s:#https://%s/#' %s && rm -f %s.bak" \
    "$host" "$host" "$PROJECTS_FILE" "$PROJECTS_FILE"
}

while IFS=$'\t' read -r kind reason; do
  [ -n "$kind" ] || continue
  names=$(printf '%s' "$fails" \
    | awk -F'\t' -v k="$kind" -v r="$reason" '$1 == k && $3 == r { printf "%s ", $2 }' \
    | sed 's/ $//')
  count=$(printf '%s' "$names" | wc -w | tr -d ' ')

  case "$kind" in
    AUTH)
      remote=$(printf '%s' "$fails" \
        | awk -F'\t' -v k="$kind" -v r="$reason" '$1 == k && $3 == r { print $4; exit }')
      body="AUTHENTICATION FAILED - $(repos_n "$count"), one cause. git said:
  $reason

Affected: $names
"
      if [ "$(remote_protocol "$remote")" = "ssh" ]; then
        body="$body
Those remotes are ssh, and the credentials on this machine cannot read them: no key, or none that GitHub accepts. If your GitHub access is over https instead, the config names the right repositories in the wrong protocol, which is the whole failure. bin/orc-repos-discover.sh detects your protocol and says which it chose, so run that if you are not sure.

Nothing here rewrote the config: that file is source and you consented to what is in it. This is the exact conversion:

$(convert_command "$remote" | sed 's/^/  /')

The .bak in there is not a safety net, which is why the command deletes it: the sed macOS ships insists on a suffix, and an untracked copy of your config left in the working tree is something to commit by mistake rather than protection against one. $(basename "$PROJECTS_FILE") is tracked, so git is the undo if the conversion turns out to be wrong.

Then run this script again."
      else
        body="$body
Those remotes are not ssh, so this is a credential problem rather than a protocol one: whatever git authenticates with is missing or expired. The config names the right repositories the right way, so it is not what needs changing."
      fi
      body="$body

Nothing was cloned, and nothing already on disk was touched. git's full output, one file per project:

  $SYNC_DIR/<project>.err"
      banner "$body"
      ;;
    *)
      worst=0
      for name in $names; do
        n=$(stuck_count "$name")
        [ "$n" -gt "$worst" ] && worst="$n"
      done
      if [ "$worst" -ge "$STUCK_LOUD_AFTER" ]; then
        body="STUCK $worst RUNS IN A ROW
$(repos_n "$count"), one cause:

  $reason

Nothing was changed. These are the clones to fix by hand:"
        for name in $names; do
          body="$body
  $(project_repo_path "$name")"
        done
        banner "$body"
      else
        printf '  STUCK: %s - %s\n' "$names" "$reason"
      fi
      ;;
  esac
done <<< "$groups"

if [ "$n_auth" != "0" ] || [ "$n_stuck" != "0" ]; then
  printf '\n'
  [ "$n_stuck" = "0" ] || printf '  %s could not be advanced, and none of them were touched.\n' "$(repos_n "$n_stuck")"
  [ "$n_auth" = "0" ]  || printf '  %s could not be read at all: that is a config or credential fix, not a clone fix.\n' "$(repos_n "$n_auth")"
  printf '  Refinement will not search a clone it could not verify; it will say so on the ticket.\n\n'
  exit 1
fi
exit 0
