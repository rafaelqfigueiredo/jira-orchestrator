#!/usr/bin/env bash
# Shared helpers for the orchestrator. Source this, do not execute it.
#
# Three access modes, selected by ORC_JIRA_MODE:
#
#   fixture   reads come from fixtures/, writes are printed and discarded
#   dry-run   reads hit the real API, writes are printed and discarded
#   live      reads and writes hit the real API (also needs DRY_RUN=0)
#
# fixture is the default so a clone with no credentials and no network works.
# Every write funnels through jira_write, and every curl invocation in the
# codebase - Jira's and Figma's - lives between the SOLE-CURL-REGION markers.
# bin/orc-check.sh enforces both of those mechanically.

set -uo pipefail

ORC_ROOT="${ORC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Overridable so a test run cannot touch the real cache. Environment only:
# it is deliberately not something config/.env should be setting.
STATE_DIR="${ORC_STATE_DIR:-$ORC_ROOT/state}"
FIXTURE_DIR="${ORC_FIXTURE_DIR:-$ORC_ROOT/fixtures}"
# Canned refiner output is keyed by prompt version and ticket, not by which
# fixture world is loaded, so it does not follow ORC_FIXTURE_DIR. Read by
# orc-refine.sh, which sources this file.
# shellcheck disable=SC2034
VERDICT_DIR="${ORC_VERDICT_DIR:-$ORC_ROOT/fixtures/verdicts}"
# Where the orchestrator keeps the clones it owns. Derived state: gitignored,
# disposable, rebuilt by bin/orc-repos-sync.sh. Nothing in here is a system of
# record, and nothing in here may be edited by anything but that script.
CLONE_DIR="${ORC_CLONE_DIR:-$ORC_ROOT/clones}"
# The mechanics half of the split: remote, default branch, verification
# strategy. Reviewed in git. What a subsystem *means* is the knowledge bundle's
# job, not this file's. Environment only, like ORC_STATE_DIR: a test run must be
# able to point at its own config without config/.env having a say.
PROJECTS_FILE="${ORC_PROJECTS_FILE:-$ORC_ROOT/config/projects.yml}"
mkdir -p "$STATE_DIR"

# config/.env fills in what the environment has not already said. A value given
# on the command line wins, so `ORC_JIRA_MODE=dry-run bin/orc-daemon.sh` means
# what it says even when a .env file exists.
_ORC_ENV_KEYS="ORC_JIRA_MODE DRY_RUN ORC_REFINER ORC_FIXTURE_DIR ORC_VERDICT_DIR
ORC_POLL_INTERVAL ORC_HTTP_RETRIES ORC_COMMENT_MARKER
ORC_AGENT_TIMEOUT ORC_GOLDEN_TIMEOUT
ORC_CLONE_DIR ORC_REPO_SYNC ORC_REPO_SYNC_TTL
ORC_BUNDLE_DIR ORC_SOLVED_DIR
ORC_BUNDLE_CHECK ORC_BUNDLE_CHECK_TTL ORC_BUNDLE_CHECK_TIMEOUT
ORC_VERIFY_STALE_DAYS
JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN JIRA_PROJECT JIRA_DUPLICATE_LINK_TYPE
TARGET_REPO LABEL_READY LABEL_NEEDS_INPUT LABEL_IN_PROGRESS LABEL_DUPLICATE
LABEL_OPT_IN FIGMA_TOKEN"

if [ -f "$ORC_ROOT/config/.env" ]; then
  for _k in $_ORC_ENV_KEYS; do
    eval "_v=\${$_k:-}"
    [ -n "${_v:-}" ] && eval "_ORC_PRE_$_k=\$_v"
  done
  # shellcheck disable=SC1091
  . "$ORC_ROOT/config/.env"
  for _k in $_ORC_ENV_KEYS; do
    eval "_v=\${_ORC_PRE_$_k:-}"
    [ -n "${_v:-}" ] && eval "$_k=\$_v"
    unset "_ORC_PRE_$_k"
  done
  unset _k _v
fi

# The knowledge bundle. Hardcoded to $ORC_ROOT/.okf, this was both why the repo
# could not be handed to another installation and why pointing the drafter
# somewhere else meant a whole separate checkout - one fix removes both. `.okf`
# under ORC_ROOT stays the default, so a clone with nothing configured still runs
# against the bundle it ships with.
#
# Unlike STATE_DIR and PROJECTS_FILE, this one is deliberately readable from
# config/.env: where an installation keeps its bundle is a per-installation fact
# somebody sets once, not something a single run overrides. That is also why it
# is assigned here rather than above - read before the .env block, the default
# would already be baked in and the setting would silently do nothing. A
# `--bundle DIR` flag still wins over both.
# shellcheck disable=SC2034  # read by the scripts that source this file
BUNDLE_DIR="${ORC_BUNDLE_DIR:-$ORC_ROOT/.okf}"

ORC_JIRA_MODE="${ORC_JIRA_MODE:-fixture}"
DRY_RUN="${DRY_RUN:-1}"
JIRA_PROJECT="${JIRA_PROJECT:-ORC}"
JIRA_BASE_URL="${JIRA_BASE_URL:-}"
JIRA_EMAIL="${JIRA_EMAIL:-}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
# Read-only, and never required: a ticket with no Figma link needs it not at
# all, and fixture mode needs it not at all either, the same way JIRA_API_TOKEN
# is unused there. Absent in live or dry-run mode, every figma_* read below
# degrades to "reason without the design" rather than failing the refinement -
# see the design-context rule.
FIGMA_TOKEN="${FIGMA_TOKEN:-}"
TARGET_REPO="${TARGET_REPO:-}"
LABEL_READY="${LABEL_READY:-agent-ready}"
LABEL_NEEDS_INPUT="${LABEL_NEEDS_INPUT:-needs-refinement}"
LABEL_IN_PROGRESS="${LABEL_IN_PROGRESS:-agent-working}"
LABEL_DUPLICATE="${LABEL_DUPLICATE:-possible-duplicate}"

# The four above are labels this system writes, and each one asserts a state it
# reached itself. This one is the only label it reads: a human puts it on a card
# to say "refine this", and nothing here ever adds or removes it. Empty means the
# gate is off and every ticket in the project is in scope, which is what an
# installation that never heard of this setting keeps doing. Validated where it
# is used, below, because orc_die does not exist yet on this line.
LABEL_OPT_IN="${LABEL_OPT_IN:-}"

# Every comment this system posts carries this line, so refinement is
# recognisable in a comment list and reconcile can find its own footprints.
ORC_COMMENT_MARKER="${ORC_COMMENT_MARKER:-orchestrator/refinement}"

# --- reports ----------------------------------------------------------------

# A ruled block, deliberately not a box.
#
# A box has to pad every line to one width, which leaves two options and both are
# bad: cut the long lines - the old one cut the only actionable thing in it to
# /Users/.../jira-orchestrat, and half a path is unusable rather than merely
# shorter - or widen the box to the longest path inside it, which is a hundred and
# seventy columns of pipe characters wrapped around one useful line. Rules above
# and below pad nothing and cut nothing.
#
# A line beginning with whitespace is a path or a command: passed through exactly
# as written and never wrapped, because a broken command cannot be copied.
# Everything else is prose and wraps at 76 columns.
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

# The three shapes a report is built out of, so two scripts printing a step and
# an indented line cannot drift into printing them differently.
step() { printf '\n== %s ==\n\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
gap()  { printf '\n'; }

# One word of a command a script prints for somebody to paste.
#
# A hint has to reproduce the run that printed it, which means carrying that
# run's own flags, and a value among them can hold a space: a bundle under
# "Application Support" pasted bare is two arguments and an unknown option.
# Quoted only when it needs to be, because '--draft' with quotes round it reads
# as a command somebody typed wrong.
hint_word() {
  case "$1" in
    ''|*[!A-Za-z0-9,._/=:@+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The flags a run was given, quoted and joined, ready to go after a command the
# run prints. Filled from an argument loop and read wherever a script names
# itself, because a hint that drops a flag describes a different run than the one
# that printed it: bin/orc-gap-loop.sh printed `--draft` under a `--basis any`
# report, and that command reran under the default basis and drafted nothing.
#
# Each flag carries its own leading space, so a hint is a concatenation rather
# than a builder that has to know which of its parts are empty.
HINT_FLAGS=""
hint_flag() {
  local a
  for a in "$@"; do HINT_FLAGS="$HINT_FLAGS $(hint_word "$a")"; done
}

# --- logging ----------------------------------------------------------------

# The header comment of a script, as its usage text. Read from the file rather
# than from a line range: every range here had rotted into printing the first few
# lines of code, because a header that grows does not update the number.
orc_usage() {
  awk 'NR > 1 { if (/^#/) print; else exit }' "$1"
}

orc_now()  { date -u +%FT%TZ; }
log()      { printf '%s %s\n' "$(orc_now)" "$*" >&2; }
orc_die()  { log "FATAL: $*"; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || orc_die "required command not found: $c"
  done
}

require_cmd jq date

# --- asking a human ---------------------------------------------------------

# A question, answered from the terminal or from a pipe. The answer lands in
# ANSWER rather than on stdout, because a reader inside $( ) is a subshell and an
# orc_die in one kills only the subshell - the run would carry on past a refusal
# with an empty answer, which is the one thing a confirmation may never do.
#
# Never invented: with nothing on stdin it says what would have supplied the
# answer, because a non-interactive run that guessed would be a run that
# consented on the operator's behalf.
#
# One implementation, shared, for the same reason the freshness stamp is: two
# would eventually disagree about what to do when there is nobody there, and that
# is the half of it that is load-bearing.
ANSWER=""
ask() {
  local hint="$1"
  printf '  > '
  # shellcheck disable=SC2034  # the caller reads ANSWER; that is the whole point
  if ! IFS= read -r ANSWER; then
    printf '\n'
    orc_die "nothing on stdin to answer that question with; $hint"
  fi
}

# "1 concept" and "6 concepts". These reports are read at the moment somebody is
# about to throw something away, and a phrase they have to type carries a count -
# a placeholder plural there reads as a bug in the thing asking.
plural() {
  if [ "$1" = "1" ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi
}

# --- wall-clock limits ------------------------------------------------------

# run_with_timeout <seconds> <command...>
#
# Runs a command with a wall-clock limit and no coreutils. macOS ships no
# timeout(1), and reaching for perl or python would make a language runtime a
# dependency of a shell script that otherwise needs git, jq and date.
#
# Exit status is the command's own, or 124 on expiry, which is the status
# timeout(1) uses so a caller that already knows that convention is right.
# A limit of 0 means no limit, so a caller can switch the guard off without
# growing a second code path.
#
# TERM first, then KILL, and to the whole process group rather than the one
# child. Signalling only the child is the mistake that looks like it works: the
# child dies, its own children do not, and they go on holding the stdout pipe the
# caller is reading - so a command substitution around this function waits out the
# full original hang and the limit achieves nothing. `set -m` is what puts the
# child in a process group of its own, so a negative pid can address the group.
run_with_timeout() {
  local limit="$1"; shift
  local pid waited=0 rc
  case "$limit" in ''|*[!0-9]*) limit=0 ;; esac
  if [ "$limit" = "0" ]; then "$@"; return $?; fi

  # stdin is passed on explicitly, because bash assigns /dev/null to a background
  # job's stdin and the agent is fed its prompt on stdin. An explicit redirection
  # is what overrides that default, so this is not decoration: without it the
  # command runs with no input and fails in a way that has nothing to do with the
  # timeout. If stdin cannot be duplicated there is nothing to pass on anyway.
  if exec 3<&0; then
    set -m
    "$@" <&3 &
    pid=$!
    set +m
    exec 3<&-
  else
    set -m
    "$@" &
    pid=$!
    set +m
  fi

  # Job control also means a Ctrl-C in the terminal no longer reaches the child,
  # because it is no longer in the foreground process group. Pass the signal on,
  # or an interrupted run leaves the agent it was waiting for still running.
  # shellcheck disable=SC2064
  trap '_kill_tree TERM '"$pid" INT TERM

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      _kill_tree TERM "$pid"
      waited=0
      while [ "$waited" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$(( waited + 1 ))
      done
      _kill_tree KILL "$pid"
      wait "$pid" 2>/dev/null
      trap - INT TERM
      return 124
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  wait "$pid"; rc=$?
  trap - INT TERM
  return "$rc"
}

# The group first, then the process, because the group only exists if `set -m`
# succeeded and there is no reliable way to ask.
_kill_tree() {
  kill "-$1" "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null || true
}

# Seconds since the epoch, for reporting how long something actually took. A
# run that is slow and a run that is wedged look identical without it.
orc_epoch() { date -u +%s; }

case "$ORC_JIRA_MODE" in
  fixture|dry-run|live) : ;;
  *) orc_die "ORC_JIRA_MODE must be fixture, dry-run or live (got '$ORC_JIRA_MODE')" ;;
esac

# Writes reach Jira only when the mode says live AND DRY_RUN is explicitly off.
# Two independent switches, both defaulting to safe, so neither one flipped by
# accident is enough to post anything.
orc_writes_are_live() {
  [ "$ORC_JIRA_MODE" = "live" ] && [ "$DRY_RUN" = "0" ]
}

orc_mode_banner() {
  if orc_writes_are_live; then
    log "mode=live DRY_RUN=0 -- writes WILL reach $JIRA_BASE_URL"
  else
    log "mode=$ORC_JIRA_MODE DRY_RUN=$DRY_RUN -- writes are printed, not sent"
  fi
}

# --- state ------------------------------------------------------------------
# state/ is a cache over Jira and git. Losing it is a restart, not an incident:
# bin/orc-reconcile.sh rebuilds it. Nothing here is a system of record.

meta_set() {
  local key="$1" field="$2" value="$3" file="$STATE_DIR/$1.meta"
  if [ -f "$file" ] && grep -q "^$field=" "$file"; then
    local tmp
    tmp=$(mktemp)
    grep -v "^$field=" "$file" > "$tmp"
    printf '%s=%s\n' "$field" "$value" >> "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$field" "$value" >> "$file"
  fi
}

meta_get() {
  grep "^$2=" "$STATE_DIR/$1.meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

status_add() {
  printf '%s %s\n' "$(orc_now)" "$2" >> "$STATE_DIR/$1.status"
}

beat() { orc_now > "$STATE_DIR/.last-beat"; }

# --- freshness stamps -------------------------------------------------------
#
# A file holding one epoch second, and the question "was that written less than
# N seconds ago". Two things in here are expensive enough that repeating them
# inside one pass is waste and cheap enough that a slightly stale answer costs
# nothing: fetching a clone, and re-rendering the bundle to see whether its
# evidence moved. They share this one implementation, because two of them would
# drift apart on what a missing or corrupt stamp means and the second reader
# would be the one that got it wrong.
#
# The stamps live under STATE_DIR, which is a cache: deleting one costs a repeat
# of the work it was suppressing and nothing else.

stamp_write() {
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  orc_epoch > "$1"
}

# Seconds since the stamp was written, or a failure if there is no usable one.
stamp_age() {
  local written
  [ -f "$1" ] || return 1
  written=$(cat "$1" 2>/dev/null)
  case "$written" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( $(orc_epoch) - written ))"
}

# stamp_is_fresh <file> <ttl seconds>. A TTL of zero means nothing is ever
# fresh, which is how a check run asks for the work to happen every time.
stamp_is_fresh() {
  local age
  [ "$2" -gt 0 ] || return 1
  age=$(stamp_age "$1") || return 1
  [ "$age" -lt "$2" ]
}

# Refinement is idempotent on ticket content: a poll cycle that sees an
# unchanged ticket must not post the same comment again.
# shasum on macOS, sha1sum on most Linuxes. Only one of them is usually present.
_sha1() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 1
  else sha1sum
  fi
}

content_hash() {
  printf '%s' "$1" | _sha1 | cut -c1-12
}

prompt_version() {
  local f="${1:-$ORC_ROOT/prompts/refine.md}"
  [ -f "$f" ] || { printf 'unknown'; return 0; }
  printf '%s-%s' "$(basename "$f" .md)" "$(_sha1 < "$f" | cut -c1-8)"
}

# --- projects and clones ----------------------------------------------------
# Section 18's split, made concrete. Three different kinds of thing, three
# different homes, and confusing them is how a system ends up committing a clone
# or asking a human to retype a remote:
#
#   mechanics   config/projects.yml: remote, default branch, verify strategy.
#               Source. In git, reviewed, and only ever changed by a human.
#   meaning     .okf/: what a subsystem is, which project owns it, and what
#               people call it in a ticket when they are not being precise.
#   clones      $CLONE_DIR: derived state. Disposable, gitignored, rebuilt by
#               bin/orc-repos-sync.sh, and never committed.
#
# Refinement routes knowledge first and config second: the bundle turns the
# ticket's words into a subsystem, and only then does this file say where that
# subsystem is checked out and on which branch.
#
# The parser is deliberately a YAML subset - top-level project name, two-space
# indented `key: value` under it - because a config a human reviews line by line
# does not need anchors, and depending on yq would cost the offline guarantee.

# Every project the config names, in file order.
project_names() {
  [ -f "$PROJECTS_FILE" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[A-Za-z0-9_.\/-]+:[[:space:]]*(#.*)?$/ { sub(/:.*$/, ""); print }
  ' "$PROJECTS_FILE"
}

# project_field <project> <key>
project_field() {
  [ -f "$PROJECTS_FILE" ] || return 0
  awk -v want="$1" -v field="$2" -v sq="'" '
    /^[[:space:]]*#/ { next }
    /^[A-Za-z0-9_.\/-]+:[[:space:]]*(#.*)?$/ { cur = $0; sub(/:.*$/, "", cur); next }
    /^[[:space:]]+[A-Za-z0-9_]+:/ {
      if (cur != want) next
      i = index($0, ":")
      k = substr($0, 1, i - 1); sub(/^[[:space:]]+/, "", k)
      v = substr($0, i + 1)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub("^" sq "|" sq "$", "", v)
      if (k == field) { print v; exit }
    }
  ' "$PROJECTS_FILE"
}

# Projects the orchestrator owns a clone of, which is to say the ones it may
# fetch. A project with no remote is somebody else's checkout.
managed_projects() {
  local name
  for name in $(project_names); do
    [ -n "$(project_field "$name" remote)" ] && printf '%s\n' "$name"
  done
}

# Where the clone lives. A relative path in the config is relative to
# $CLONE_DIR, so a config that names only a remote still resolves to somewhere.
#
# TARGET_REPO fills in for a project the config gives no path for, which keeps
# the original single-repository setup working unchanged. It cannot override a
# path the config states, because it has no way to say which project it means
# and a config that names three repositories would silently collapse to one.
project_repo_path() {
  local name="$1" p
  p=$(project_field "$name" repo)
  if [ -z "$p" ] && [ -n "$TARGET_REPO" ] && [ -z "$(project_field "$name" remote)" ]; then
    p="$TARGET_REPO"
  fi
  if [ -z "$p" ]; then
    [ -n "$(project_field "$name" remote)" ] || return 0
    p="$CLONE_DIR/$name"
  fi
  case "$p" in
    /*) printf '%s' "$p" ;;
    ~/*) printf '%s' "$HOME/${p#\~/}" ;;
    *)  printf '%s' "$CLONE_DIR/$p" ;;
  esac
}

# The branch a ticket is about. Never defaulted: "main" is wrong in more
# repositories than people expect, and a wrong guess here is a whole refinement
# reasoned against the wrong code. A managed project without one is an error the
# caller reports rather than papers over.
project_default_branch() {
  project_field "$1" default_branch
}

# Two remote strings can name the same repository. Compare what they point at,
# not how they were typed, so ssh and https forms of one remote do not read as
# a mismatch.
remote_key() {
  printf '%s' "$1" \
    | sed -e 's#^[a-z+]*://##' -e 's#^[^@/]*@##' -e 's#^\([^/:]*\):#\1/#' \
          -e 's#\.git$##' -e 's#/$##' \
    | tr '[:upper:]' '[:lower:]'
}

# ssh or https, as the string is actually spelled. remote_key deliberately
# cannot tell them apart, because for "is this the same repository" they are the
# same; for "can this machine read it" they are not, and that is this one's job.
remote_protocol() {
  case "$1" in
    ssh://*|*@*:*) printf 'ssh' ;;
    http://*|https://*) printf 'https' ;;
    *) printf 'other' ;;
  esac
}

# The same repository, spelled for the other protocol. A machine authenticating
# with a token cannot read an ssh remote and a machine with only a key cannot
# read an https one, so the spelling is not cosmetic: it decides whether ten
# clones work or none do.
remote_as_https() {
  printf '%s' "$1" \
    | sed -e 's#^ssh://##' -e 's#^git+ssh://##' -e 's#^\([^@/]*\)@\([^:/]*\)[:/]#https://\2/#'
}

remote_as_ssh() {
  printf '%s' "$1" | sed -e 's#^https\{0,1\}://\([^/]*\)/#git@\1:#'
}

# remote_in_protocol <ssh|https> <url>
remote_in_protocol() {
  local out
  case "$1" in
    https) out=$(remote_as_https "$2") ;;
    ssh)   out=$(remote_as_ssh "$2") ;;
    *)     out="$2" ;;
  esac
  case "$out" in *.git) : ;; *) out="$out.git" ;; esac
  printf '%s' "$out"
}

# --- which repository a concept claims to be ---------------------------------
#
# OKF gives `resource:` one meaning: this concept *is* that addressable asset.
# For a Subsystem concept the asset is a repository, so two concepts carrying
# the same one are two answers to the same question - and refinement resolving
# a term gets whichever it happened to read first. A bundle that contradicts
# itself is worse than a sparse one, because you cannot tell which answer you
# got.
#
# These readers are shared deliberately: bin/orc-okf-draft.sh uses them to
# find the concept a repository already has instead of writing a second one, and
# bin/orc-check.sh uses them to fail when one appears anyway. One implementation,
# so the detection and the prevention cannot drift apart.

# repo_ref_key <url-or-path>
#
# The repository a reference names, reduced to something two spellings agree on.
# remote_key already folds ssh and https together and drops .git; this drops what
# a forge appends after the repository, so a concept citing a file and a concept
# citing the tree read as one repository.
#
# It never truncates by depth. A local path is a repository reference too, and
# cutting one to three segments would make two unrelated clones under the same
# parent collide - a false duplicate is a failing check nobody can fix.
repo_ref_key() {
  local k
  k=$(remote_key "$1")
  [ -n "$k" ] || return 0
  printf '%s' "$k" | sed -E -e 's#/(-/)?(tree|blob|raw|commit|src|browse)/.*$##' -e 's#/$##'
}

# Does this string name a repository, rather than describe one?
#
# `sources[].resource` is allowed to be a scope descriptor - "every path named
# below, as it exists in X" is legal provenance - and prose must never be
# mistaken for an address.
is_repo_ref() {
  case "$1" in
    ssh://*|http://*|https://*|git://*|git+ssh://*) return 0 ;;
    /*) return 0 ;;
    *@*:*) case "$1" in *' '*) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}

# The frontmatter of a concept file, or nothing.
concept_frontmatter() {
  [ -f "$1" ] || return 0
  awk 'NR == 1 && $0 == "---" { inf = 1; next } inf && $0 == "---" { exit } inf' "$1"
}

# concept_field <file> <key> - a top-level frontmatter scalar, unquoted.
# Top-level only: an indented `resource:` belongs to a sources entry, which is a
# citation rather than a claim about what this concept is.
concept_field() {
  concept_frontmatter "$1" | awk -v key="$2" '
    $0 ~ "^" key ":" {
      v = substr($0, index($0, ":") + 1)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\x27|\x27$/, "", v)
      print v
      exit
    }'
}

# Has a person read this concept and said so?
#
# The distinction the whole bundle rests on: a concept carrying a verified: date
# was confirmed by somebody, one carrying only generated: was drafted off a
# repository and nobody has looked at it since, and both read as confident prose.
# bin/orc-okf-draft.sh refuses to overwrite one of these and
# bin/orc-onboard.sh counts them before it discards a bundle, so the reader lives
# here: a refusal and a discard that disagreed about what "verified" means would
# be the worst possible pair of bugs to have.
#
# Both spellings are recognised. The hand-written concepts in this bundle use a
# flow mapping and the drafts use block style, and a reader that knew only one of
# them would happily overwrite somebody's reviewed file.
concept_is_verified() {
  [ -f "$1" ] || return 1
  concept_frontmatter "$1" | grep -qE '^verified:[[:space:]]*[^[:space:]]|^verified:[[:space:]]*$'
}

# Who confirmed it and when, as "by, at" lines - so a report about to discard a
# concept can name the person rather than a count.
concept_verified_by() {
  concept_frontmatter "$1" | awk '
    /^verified:/ { inv = 1; next }
    inv && /^[^[:space:]-]/ { inv = 0 }
    inv {
      if (match($0, /by:[[:space:]]*[^,}[:space:]]+/)) {
        b = substr($0, RSTART, RLENGTH); sub(/by:[[:space:]]*/, "", b)
      }
      if (match($0, /at:[[:space:]]*[^,}[:space:]]+/)) {
        a = substr($0, RSTART, RLENGTH); sub(/at:[[:space:]]*/, "", a)
      }
      if (b != "" && a != "") { print b ", " a; b = ""; a = "" }
    }'
}

# The day the signature was last renewed, as it is written in the frontmatter.
#
# Re-verifying appends a verified: entry rather than replacing one, so a concept
# several people have signed carries several dates and the newest is the one
# that says how long ago somebody last confirmed it. Read through
# concept_verified_by rather than re-parsing the block, so the two cannot
# disagree about which entries are entries. bin/orc-verify.sh's advisory
# aged-signature section is the only reader; nothing weights the refiner by it.
concept_verified_at() {
  concept_verified_by "$1" | awk '{ print $NF }' | sort | tail -n 1
}

# bundle_repo_claims <bundle>
#
# concept<TAB>repository key, one line per concept that claims to be a
# repository. Hidden directories are skipped: the reader excludes them, so a
# concept under one is not in the bundle at all.
bundle_repo_claims() {
  local dir="$1" f rel res key
  [ -d "$dir" ] || return 0
  find "$dir" -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$dir"/}
    # Hidden components are tested on the path *relative to the bundle*, never on
    # the absolute one. The bundle itself is normally called `.okf`, so filtering
    # the full path threw away every concept in it and quietly answered "no
    # concept claims this repository" for all of them - which is the exact answer
    # that lets a duplicate be written.
    case "$rel" in .*|*/.*) continue ;; esac
    case "$rel" in index.md|*/index.md|log.md|*/log.md) continue ;; esac
    res=$(concept_field "$f" resource)
    [ -n "$res" ] || continue
    is_repo_ref "$res" || continue
    key=$(repo_ref_key "$res")
    [ -n "$key" ] || continue
    printf '%s\t%s\n' "$rel" "$key"
  done
}

# bundle_repo_duplicates <bundle>
#
# One line per repository more than one concept claims: key<TAB>concepts.
bundle_repo_duplicates() {
  bundle_repo_claims "$1" | awk -F'\t' '
    { n[$2]++; c[$2] = c[$2] (c[$2] == "" ? "" : ", ") $1 }
    END { for (k in n) if (n[k] > 1) print k "\t" c[k] }
  ' | sort
}

# The concept that already claims a repository, if one does.
concept_claiming_repo() {
  local want
  want=$(repo_ref_key "$2")
  [ -n "$want" ] || return 0
  bundle_repo_claims "$1" | awk -F'\t' -v w="$want" '$2 == w { print $1; exit }'
}

# --- reading git's own diagnostics ------------------------------------------

# git_first_error <file>
#
# The first meaningful line of a git stderr capture, never the last.
#
# git puts the cause first and generic advice after it. The four lines of a
# failed ssh clone end with "and the repository exists.", so reporting the tail
# turns "Permission denied (publickey)" - a missing key, one fix - into
# something that reads like a repository that is not there, which is a
# different fix entirely. A diagnostic that misleads is worse than none.
git_first_error() {
  local f="$1" line
  [ -s "$f" ] || { printf 'git said nothing at all'; return 0; }
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      # Progress and generic advice. Everything else is the cause.
      Cloning\ into\ *|Fetching\ *|Receiving\ *|Resolving\ *|Counting\ *|Enumerating\ *) continue ;;
      remote:\ Enumerating*|remote:\ Counting*|remote:\ Compressing*|remote:\ Total*) continue ;;
      Please\ make\ sure*|and\ the\ repository\ exists*) continue ;;
      Warning:\ Permanently\ added*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$f"
  # Nothing but noise. The whole capture, flattened, beats a fragment of it.
  tr '\n' ' ' < "$f" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'
}

# Did git fail because it could not authenticate, as opposed to anything else?
#
# Its own outcome, because it is the one failure that is never about the
# repository and never fixed by looking at the clone: the remote is spelled in a
# protocol these credentials cannot use.
git_error_is_auth() {
  grep -qiE 'permission denied|publickey|authentication failed|could not read from remote repository|invalid username or password|terminal prompts disabled|no such identity|host key verification failed' "$1" 2>/dev/null
}

# Is this path the root of a git repository in its own right?
#
# Not `-d "$path/.git"`: in a worktree .git is a file, and a plain directory
# nested inside another repository would answer yes to rev-parse while belonging
# to something else entirely. Clones live under the orchestrator's own tree, so
# that second case is not hypothetical.
is_git_repo() {
  local p="$1" top
  [ -d "$p" ] || return 1
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$p" 2>/dev/null && pwd -P)" ]
}

# git_read <repo> <args...>
#
# Read-only git. The subcommand is checked against a list of readers, so this
# helper cannot become a writer by someone adding an argument to a call site:
# the write path is three commands in bin/orc-repos-sync.sh and nowhere else.
git_read() {
  local repo="$1"; shift
  case "${1:-}" in
    rev-parse|rev-list|symbolic-ref|show-ref|for-each-ref|log|show|grep|status|diff \
      |ls-files|ls-tree|cat-file|describe|count-objects) : ;;
    remote) [ "${2:-}" = "get-url" ] || orc_die "git_read refuses 'git remote ${2:-}'" ;;
    config) [ "${2:-}" = "--get" ]   || orc_die "git_read refuses 'git config ${2:-}'" ;;
    *) orc_die "git_read refuses 'git ${1:-}': it is not a read-only command" ;;
  esac
  git -C "$repo" "$@"
}

# Can this machine read this remote, with the credentials it actually has?
#
# A URL, not a repository, so it cannot go through git_read - that one is
# repository-scoped. ls-remote is a reader either way, and it lives in a named
# wrapper for the same reason git_read exists: so the read stays a read.
#
# Batch mode throughout. A probe that stops to ask for a passphrase is a hang,
# and the answer this function exists to give is "no" rather than a prompt.
remote_is_readable() {
  GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}" \
    git ls-remote --exit-code -h "$1" HEAD >/dev/null 2>&1
}

ORC_REPO_REMOTE=origin

# repo_state <project>
#
# One tab-separated line: state, short sha, branch, detail. The states, and why
# each one exists:
#
#   unconfig    no remote and no path: there is nothing to manage and nothing to
#               search, which is a valid setup and not a failure.
#   absent      a remote is configured and nothing is on disk yet.
#               bin/orc-repos-sync.sh clones it.
#   unmanaged   a path with no remote in the config. The orchestrator does not
#               own it, so it is used as it is and its condition is reported.
#   ok          on the configured default branch, clean, and level with the
#               remote-tracking ref. The only state that may be searched.
#   stale       on disk, but not the code the ticket is about. Refinement will
#               not search it: a stale checkout produces a confidently wrong
#               verdict, and six weeks later nobody can tell that apart from a
#               bad judgment. They have different fixes, so they need different
#               reports.
repo_state() {
  local name="$1" path remote want sha cur dirty counts ahead behind
  path=$(project_repo_path "$name")
  remote=$(project_field "$name" remote)
  want=$(project_default_branch "$name")

  if [ -z "$path" ]; then
    printf 'unconfig\t-\t-\tno repo path and no remote in %s\n' "$(basename "$PROJECTS_FILE")"
    return 0
  fi
  if [ ! -e "$path" ]; then
    printf 'absent\t-\t-\tnot cloned yet: %s\n' "$path"
    return 0
  fi
  if ! is_git_repo "$path"; then
    printf 'stale\t-\t-\t%s exists but is not a git repository\n' "$path"
    return 0
  fi

  sha=$(git_read "$path" rev-parse HEAD 2>/dev/null | cut -c1-12)
  cur=$(git_read "$path" symbolic-ref --short -q HEAD 2>/dev/null)
  dirty=$(git_read "$path" status --porcelain 2>/dev/null | grep -c . | tr -d ' ')

  if [ -z "$remote" ]; then
    local detail="no remote configured, so this clone is not the orchestrator's to manage"
    [ "${dirty:-0}" -gt 0 ] && detail="$detail; $dirty uncommitted change(s)"
    printf 'unmanaged\t%s\t%s\t%s\n' "${sha:--}" "${cur:-detached}" "$detail"
    return 0
  fi

  if [ -z "$want" ]; then
    printf 'stale\t%s\t%s\tno default_branch configured for %s, and it is never assumed\n' \
      "${sha:--}" "${cur:-detached}" "$name"
    return 0
  fi
  if [ -z "$cur" ]; then
    printf 'stale\t%s\tdetached\tdetached HEAD, expected %s\n' "${sha:--}" "$want"
    return 0
  fi
  if [ "$cur" != "$want" ]; then
    printf 'stale\t%s\t%s\ton %s, but the ticket targets %s\n' "$sha" "$cur" "$cur" "$want"
    return 0
  fi
  if [ "${dirty:-0}" -gt 0 ]; then
    printf 'stale\t%s\t%s\t%s uncommitted change(s) in the working tree\n' "$sha" "$cur" "$dirty"
    return 0
  fi
  if ! git_read "$path" rev-parse --verify --quiet "refs/remotes/$ORC_REPO_REMOTE/$want" >/dev/null 2>&1; then
    printf 'stale\t%s\t%s\t%s/%s is unknown here; run bin/orc-repos-sync.sh\n' \
      "$sha" "$cur" "$ORC_REPO_REMOTE" "$want"
    return 0
  fi
  counts=$(git_read "$path" rev-list --left-right --count "HEAD...$ORC_REPO_REMOTE/$want" 2>/dev/null)
  ahead=$(printf '%s' "$counts" | awk '{print $1+0}')
  behind=$(printf '%s' "$counts" | awk '{print $2+0}')
  if [ "${ahead:-0}" -gt 0 ]; then
    printf 'stale\t%s\t%s\tdiverged: %s local commit(s) not on %s/%s\n' \
      "$sha" "$cur" "$ahead" "$ORC_REPO_REMOTE" "$want"
    return 0
  fi
  if [ "${behind:-0}" -gt 0 ]; then
    printf 'stale\t%s\t%s\t%s commit(s) behind %s/%s; run bin/orc-repos-sync.sh\n' \
      "$sha" "$cur" "$behind" "$ORC_REPO_REMOTE" "$want"
    return 0
  fi
  printf 'ok\t%s\t%s\tlevel with %s/%s\n' "$sha" "$cur" "$ORC_REPO_REMOTE" "$want"
}

# A repository and the exact commit a judgment was reasoned against. Every
# verdict and every comment carries this, because when a named file turns out
# not to exist the first question is whether the refiner was wrong or the
# checkout was old, and those have different fixes.
repo_provenance() {
  local name="$1" st sha br detail
  IFS=$'\t' read -r st sha br detail <<< "$(repo_state "$name")"
  case "$st" in
    ok)        printf '%s %s@%s' "$name" "$br" "$sha" ;;
    unmanaged) printf '%s %s@%s (unmanaged: %s)' "$name" "$br" "$sha" "$detail" ;;
    stale)     printf '%s STALE, not searched: %s' "$name" "$detail" ;;
    unconfig)  printf '%s nothing configured to search' "$name" ;;
    *)         printf '%s not searched: %s' "$name" "$detail" ;;
  esac
}

# --- clones the config no longer names --------------------------------------
#
# Removing a project from config/projects.yml does not remove its clone from
# disk, and nothing used to look, so the directory sat there unreferenced and
# unreported. These readers find it and decide whether deleting it could lose
# anything. Deciding is all they do: the deletion lives in bin/orc-repos-sync.sh
# behind a flag, because a line disappearing from a YAML file is the last thing
# that should be allowed to discard 2.2M of somebody's disk.

# The physical path a spelling refers to, canonicalised as far as it exists.
#
# A path that is not on disk still has to compare equal to the same path once it
# is, and on macOS /tmp and /private/tmp are one directory under two names -
# enough for a configured clone and the directory it actually occupies to read
# as two different places, which would report a managed clone as an orphan.
orc_real_path() {
  local p="$1" tail=""
  while [ -n "$p" ] && [ ! -d "$p" ]; do
    tail="/$(basename "$p")$tail"
    p=$(dirname "$p")
    case "$p" in /|.|'') break ;; esac
  done
  [ -d "$p" ] && p=$(cd "$p" && pwd -P)
  case "$p" in /) p="" ;; esac
  printf '%s' "$p$tail"
}

# Every path the config resolves to, physical, one per line.
#
# Compared as paths rather than as project names: a config may point a project at
# a directory whose basename is something else entirely, and a name comparison
# would then call that directory an orphan while the orchestrator was syncing it.
#
# Read line by line rather than by word-splitting $(project_names). Every reader
# below is called through `IFS=$'\t' read -r ... <<< "$(...)"`, and in bash that
# prefix is already in effect while the command substitution runs: a function
# that word-splits with $IFS answers a different question depending on who asked
# it. One of these read "safe" for a clone holding an unpushed branch for exactly
# that reason, so none of them relies on the ambient IFS any more.
_configured_clone_paths() {
  local name p
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    p=$(project_repo_path "$name")
    [ -n "$p" ] || continue
    orc_real_path "$p"
    printf '\n'
  done < <(project_names)
}

# Immediate children of the clone tree that no project in the config names.
#
# Immediate children only: a clone is full of directories and not one of them is
# a clone. A symlink is skipped rather than classified, because what it points at
# is somebody else's checkout and this tree has no claim on it.
orphan_clones() {
  local entry configured real
  [ -d "$CLONE_DIR" ] || return 0
  configured=$(_configured_clone_paths)
  for entry in "$CLONE_DIR"/*; do
    [ -d "$entry" ] || continue
    if [ -L "$entry" ]; then continue; fi
    real=$(orc_real_path "$entry")
    if _line_is_in "$real" "$configured"; then continue; fi
    printf '%s\n' "$entry"
  done
}

# Is this exact string one of the lines in that list?
#
# A string comparison rather than grep -qxF, which is not the same question: a
# fixed pattern containing a newline is several patterns to grep, so any one of
# them matching would answer yes. That is how a clone with an unpushed branch was
# once declared safe to delete.
_line_is_in() {
  local want="$1" line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done <<< "$2"
  return 1
}

# Does this branch name exist on a remote, under that name or the one it tracks?
_branch_is_on_a_remote() {
  local path="$1" br="$2" merge rem
  if _line_is_in "$br" \
     "$(git_read "$path" for-each-ref --format='%(refname:strip=3)' refs/remotes 2>/dev/null)"; then
    return 0
  fi
  # A branch may track a remote branch of another name. Its configured upstream
  # is the authority on that, not the spelling of its own name.
  merge=$(git_read "$path" config --get "branch.$br.merge" 2>/dev/null)
  [ -n "$merge" ] || return 1
  rem=$(git_read "$path" config --get "branch.$br.remote" 2>/dev/null)
  [ -n "$rem" ] || return 1
  git_read "$path" rev-parse --verify --quiet \
    "refs/remotes/$rem/${merge#refs/heads/}" >/dev/null 2>&1
}

# clone_removal_safety <path>
#
# One tab-separated line: "safe<TAB>why" or "unsafe<TAB>which of them it is".
#
# Provably safe, not probably safe. The entire value of a --prune flag is that
# the verdict behind it was earned, so every question here is a form of "is there
# anything in this directory that exists nowhere else", and anything that cannot
# be answered is unsafe. A wrong "safe" is an operator's work deleted by a tool
# they were told to trust, which is worse than having no flag at all.
#
# Every check leans the same way. The remote-tracking refs are a local cache, so
# a stale one makes this answer "unsafe" about work that is in fact pushed - a
# clone kept for no reason, which costs disk, against a clone deleted for a bad
# reason, which costs work.
clone_removal_safety() {
  local path="$1" dirty stashes unpushed head_extra br

  if [ ! -d "$path" ]; then
    printf 'unsafe\t%s is not a directory\n' "$path"
    return 0
  fi
  if ! is_git_repo "$path"; then
    printf 'unsafe\tnot a git repository, so nothing in it can be shown to exist elsewhere\n'
    return 0
  fi
  if [ -z "$(git_read "$path" remote get-url "$ORC_REPO_REMOTE" 2>/dev/null)" ]; then
    printf 'unsafe\tno %s remote, so nothing in it can be shown to exist elsewhere\n' "$ORC_REPO_REMOTE"
    return 0
  fi

  # Untracked files count, and --porcelain reports them. A file nobody has added
  # yet is still a file that exists in exactly one place.
  dirty=$(git_read "$path" status --porcelain 2>/dev/null | grep -c . | tr -d ' ')
  if [ "${dirty:-0}" -gt 0 ]; then
    printf 'unsafe\t%s uncommitted change(s) in the working tree\n' "$dirty"
    return 0
  fi

  # A stash is committed work that no branch points at, so neither the porcelain
  # status nor a walk over the branches sees it.
  if git_read "$path" rev-parse --verify --quiet refs/stash >/dev/null 2>&1; then
    stashes=$(git_read "$path" rev-list --walk-reflogs --count refs/stash 2>/dev/null)
    if [ "${stashes:-1}" = "1" ]; then
      printf 'unsafe\t1 stash entry\n'
    else
      printf 'unsafe\t%s stash entries\n' "${stashes:-1}"
    fi
    return 0
  fi

  unpushed=$(git_read "$path" rev-list --count --branches --not --remotes 2>/dev/null)
  if [ "${unpushed:-0}" -gt 0 ]; then
    printf 'unsafe\t%s commit(s) on a local branch and on no remote\n' "$unpushed"
    return 0
  fi

  # A branch whose name is on no remote. Every commit on it may be on the remote
  # already - a branch cut from origin/staging and not committed to is exactly
  # that - but the branch itself exists only here, and a branch nobody else has
  # is work in progress under another name.
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    if _branch_is_on_a_remote "$path" "$br"; then continue; fi
    printf 'unsafe\tbranch %s exists on no remote\n' "$br"
    return 0
  done < <(git_read "$path" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)

  # A detached HEAD is not itself a reason - a clone parked on a commit the remote
  # has holds nothing unique. A detached HEAD with commits on no remote is.
  if ! git_read "$path" symbolic-ref -q --short HEAD >/dev/null 2>&1; then
    head_extra=$(git_read "$path" rev-list --count HEAD --not --remotes 2>/dev/null)
    if [ "${head_extra:-0}" -gt 0 ]; then
      printf 'unsafe\tdetached HEAD at %s with %s commit(s) on no remote\n' \
        "$(git_read "$path" rev-parse --short=12 HEAD 2>/dev/null)" "$head_extra"
      return 0
    fi
  fi

  printf 'safe\tclean, and every commit and branch in it is on %s\n' "$ORC_REPO_REMOTE"
}

# What an operator needs in order to care: how much disk this is.
#
# Measured once, in kilobytes, and rendered from that one number, so a per-clone
# size and a total of them cannot disagree with each other.
dir_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1 + 0; exit}'; }

human_kb() {
  awk -v k="${1:-0}" 'BEGIN {
    if (k < 1024) { printf "%dK", k; exit }
    if (k < 1048576) { printf "%.1fM", k / 1024; exit }
    printf "%.1fG", k / 1048576
  }'
}

# --- http -------------------------------------------------------------------

# --- BEGIN SOLE-CURL-REGION -------------------------------------------------
# The only place in this repository that performs network I/O. Everything else
# goes through jira_read, jira_write, or the figma_* reads below.
# bin/orc-check.sh fails if curl appears anywhere outside these markers - it
# does not require there to be only one function in here, only that a stray
# curl elsewhere in the tree is caught, so a second external read earns its own
# function in this same fence rather than a second fence somewhere else.
_jira_http() {
  local method="$1" path="$2" body="${3:-}"
  local url="$JIRA_BASE_URL/rest/api/3$path"
  local max="${ORC_HTTP_RETRIES:-4}" attempt=1
  local cfg out hdr status wait

  [ -n "$JIRA_BASE_URL" ]   || orc_die "JIRA_BASE_URL is unset; cannot reach Jira"
  [ -n "$JIRA_EMAIL" ]      || orc_die "JIRA_EMAIL is unset; cannot authenticate"
  [ -n "$JIRA_API_TOKEN" ]  || orc_die "JIRA_API_TOKEN is unset; cannot authenticate"

  # Credentials go in a 0600 config file rather than on the command line, so
  # the token never appears in the process table.
  cfg=$(mktemp); out=$(mktemp); hdr=$(mktemp)
  chmod 600 "$cfg"
  printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_API_TOKEN" > "$cfg"
  # shellcheck disable=SC2064
  trap "rm -f '$cfg' '$out' '$hdr'" RETURN

  while :; do
    local -a args
    args=( --config "$cfg" -sS -X "$method"
           -H 'Content-Type: application/json'
           -H 'Accept: application/json'
           -D "$hdr" -o "$out" -w '%{http_code}' )
    [ -n "$body" ] && args+=( --data-binary "$body" )

    status=$(curl "${args[@]}" "$url" 2>>"$hdr")

    case "$status" in
      2*)
        cat "$out"
        return 0
        ;;
      429|503)
        # Section 16: rate limits come back as 429 with Retry-After. Honour it.
        wait=$(grep -i '^retry-after:' "$hdr" | tail -1 | tr -d '\r' | awk '{print $2}')
        case "$wait" in
          ''|*[!0-9]*) wait=$(( attempt * attempt * 5 )) ;;
        esac
        if [ "$attempt" -ge "$max" ]; then
          log "giving up on $method $path after $attempt attempts (last status $status)"
          return 1
        fi
        log "throttled ($status) on $method $path, waiting ${wait}s (attempt $attempt/$max)"
        sleep "$wait"
        attempt=$(( attempt + 1 ))
        ;;
      *)
        log "$method $path failed with status $status"
        head -c 2000 "$out" >&2 || true
        printf '\n' >&2
        return 1
        ;;
    esac
  done
}

# _figma_http <method> <path>
#
# GET only - refinement never writes to Figma - and never orc_die, unlike
# _jira_http above. Jira is mandatory infrastructure this system cannot run
# without; a design file is optional context, and the whole point of the
# design-context rule is that a missing token, a stale link now answering 404,
# or a network blip degrades to "reason without the design" rather than taking
# a ticket refinement down. Every caller reads this inside $( ) for exactly
# that reason: a failure returns 1 and prints nothing, and the caller decides
# what "nothing" means.
#
# The token goes in the same kind of 0600 --config file _jira_http uses,
# rather than on the command line as -H, so it never appears in the process
# table either.
_figma_http() {
  local method="$1" path="$2"
  local url="https://api.figma.com$path"
  local max="${ORC_HTTP_RETRIES:-4}" attempt=1
  local cfg out hdr status wait

  cfg=$(mktemp); out=$(mktemp); hdr=$(mktemp)
  chmod 600 "$cfg"
  printf 'header = "X-Figma-Token: %s"\n' "$FIGMA_TOKEN" > "$cfg"
  # shellcheck disable=SC2064
  trap "rm -f '$cfg' '$out' '$hdr'" RETURN

  while :; do
    local -a args
    args=( --config "$cfg" -sS -X "$method" -H 'Accept: application/json'
           -D "$hdr" -o "$out" -w '%{http_code}' )
    status=$(curl "${args[@]}" "$url" 2>>"$hdr")

    case "$status" in
      2*)
        cat "$out"
        return 0
        ;;
      429)
        wait=$(grep -i '^retry-after:' "$hdr" | tail -1 | tr -d '\r' | awk '{print $2}')
        case "$wait" in
          ''|*[!0-9]*) wait=$(( attempt * attempt * 5 )) ;;
        esac
        if [ "$attempt" -ge "$max" ]; then
          log "giving up on Figma $method $path after $attempt attempts (last status $status)"
          return 1
        fi
        log "throttled ($status) on Figma $method $path, waiting ${wait}s (attempt $attempt/$max)"
        sleep "$wait"
        attempt=$(( attempt + 1 ))
        ;;
      *)
        log "Figma $method $path failed with status $status; reasoning without this design"
        return 1
        ;;
    esac
  done
}

# _figma_download <url> <out-file>
#
# The images endpoint never returns pixels itself - it returns a pre-signed
# URL to fetch them from, on a different host and needing no token - so a
# rendered PNG always costs this second request. Same failure contract as
# _figma_http: log and return 1, never orc_die.
_figma_download() {
  local url="$1" out_file="$2" hdr status
  hdr=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$hdr'" RETURN
  local -a args
  args=( -sS -D "$hdr" -o "$out_file" -w '%{http_code}' )
  status=$(curl "${args[@]}" "$url" 2>>"$hdr")
  case "$status" in
    2*) return 0 ;;
    *)
      log "Figma image download failed with status $status; reasoning without the rendered image"
      rm -f "$out_file"
      return 1
      ;;
  esac
}
# --- END SOLE-CURL-REGION ---------------------------------------------------

# --- jira reads -------------------------------------------------------------

# jira_read <path> [fixture-name]
#
# In fixture mode the path is resolved to a file under fixtures/. Read sites
# that are not /issue/<KEY> name their fixture explicitly rather than having
# this function parse JQL, because an unparsed query silently resolving to the
# wrong file is a worse failure than a missing argument.
jira_read() {
  local path="$1" hint="${2:-}"
  if [ "$ORC_JIRA_MODE" != "fixture" ]; then
    _jira_http GET "$path"
    return $?
  fi

  local file
  if [ -n "$hint" ]; then
    file="$FIXTURE_DIR/$hint.json"
  else
    local bare key
    bare=${path%%\?*}
    case "$bare" in
      /issue/*)
        key=${bare#/issue/}
        key=${key%%/*}
        file="$FIXTURE_DIR/issues/$key.json"
        ;;
      *)
        orc_die "fixture mode: no fixture mapping for '$path' (pass a fixture name)"
        ;;
    esac
  fi

  [ -f "$file" ] || orc_die "fixture mode: missing fixture $file (for $path)"
  cat "$file"
}

# --- the opt-in gate --------------------------------------------------------
#
# When the operator names a label, only cards carrying it are polled and
# refined. Off unless named, so an installation that never set it keeps seeing
# every ticket in the project - a gate that switched itself on would start
# ignoring tickets silently, which is the one failure mode worse than refining
# too much.
#
# A Jira label holds no space and no quote, so a value that does is a typo in
# config/.env rather than a label. Left alone it would not fail: it would build a
# different JQL from the one the operator wrote, and a JQL that parses is a
# filter nobody knows about. Checked once, here, where every consumer picks it
# up, and never inside `$( )` - orc_die in a subshell kills the subshell and lets
# the run carry on with an empty answer.
case "$LABEL_OPT_IN" in
  *[[:space:]]*|*'"'*|*"'"*|*\\*)
    orc_die "LABEL_OPT_IN is not a label: '$LABEL_OPT_IN' holds a space or a quote, which no Jira label can, and which would change the JQL rather than fail it"
    ;;
esac

# The JQL fragment that narrows a search to the opt-in label, or nothing at all.
# In the JQL rather than in a filter afterwards, so an unlabelled card costs no
# page of results and no read.
opt_in_clause() {
  [ -n "$LABEL_OPT_IN" ] || return 0
  printf ' AND labels = "%s"' "$LABEL_OPT_IN"
}

# has_opt_in <space-separated labels>
#
# True when the ticket carries the label, and true of everything when no label is
# named, so a caller asks "is this ticket in scope" rather than "is the gate
# configured".
has_opt_in() {
  [ -n "$LABEL_OPT_IN" ] || return 0
  case " $1 " in *" $LABEL_OPT_IN "*) return 0 ;; esac
  return 1
}

# jira_search <fixture-name> <jql> <fields> <max-results> [next-page-token]
#
# The one place the search endpoint is spelled. `/rest/api/3/search` was removed
# and answers 410; `/search/jql` replaced it, and it differs in three ways that
# a caller has to know about:
#
#   - paging is a cursor. The response carries `nextPageToken` and nothing that
#     can be counted up, so a page can only be asked for by handing back the
#     token the previous page returned. The token is absent on the last page.
#   - there is no `total`. An approximate one is a separate request to
#     /search/jql's sibling, and nothing here needs it.
#   - `fields` defaults to the issue id alone rather than to the navigable set,
#     so every field a caller reads has to be named. `id` and `key` come back
#     regardless: they are issue properties rather than fields.
#
# Three read sites shared the old spelling and the last endpoint removal was
# predicted to be one script's problem. It was three. Hence one function.
jira_search() {
  local hint="$1" jql="$2" fields="$3" max="$4" token="${5:-}" path
  path="/search/jql?jql=$(printf '%s' "$jql" | jq -sRr @uri)"
  path="$path&maxResults=$max&fields=$(printf '%s' "$fields" | jq -sRr @uri)"
  [ -n "$token" ] && path="$path&nextPageToken=$(printf '%s' "$token" | jq -sRr @uri)"
  jira_read "$path" "$hint"
}

# jira_search_all <fixture-name> <jql> <fields> <max-results>
#
# Every issue the query matches, one compact JSON object per line, across as many
# pages as the cursor has.
#
# The termination rule is the absence of a token and nothing else. An offset loop
# could stop on a short page or on a count; a cursor has neither, and the
# endpoint is documented to answer with a token beside a page it has no issues
# for - so stopping on an empty page silently drops every ticket after it while
# reporting success. A cursor that comes back unchanged is the one way the loop
# can fail to terminate, and it is a server fault rather than a scale a page cap
# could be sized against.
#
# It reports that by logging and returning non-zero rather than by calling
# orc_die. Every caller reads this inside `$( )`, and orc_die in a command
# substitution kills the subshell and lets the run carry on with a partial
# answer - which here would be a truncated list of tickets that nothing said was
# truncated.
jira_search_all() {
  local hint="$1" jql="$2" fields="$3" max="$4" token="" prev page
  while :; do
    page=$(jira_search "$hint" "$jql" "$fields" "$max" "$token") || {
      log "search failed for $hint"; return 1; }
    printf '%s' "$page" | jq -c '.issues[]?'
    prev="$token"
    token=$(printf '%s' "$page" | jq -r '.nextPageToken // empty')
    [ -n "$token" ] || break
    if [ "$token" = "$prev" ]; then
      log "search paging stalled: Jira returned the same nextPageToken twice"
      return 1
    fi
  done
}

# --- jira writes ------------------------------------------------------------

# jira_write <method> <path> <json-body>
#
# The single write path. In fixture and dry-run mode it prints a readable
# preview and returns success without touching the network.
jira_write() {
  local method="$1" path="$2" body="${3:-}"

  if [ "$method" = "GET" ]; then
    orc_die "jira_write called with GET; use jira_read"
  fi

  if ! orc_writes_are_live; then
    _write_preview "$method" "$path" "$body"
    return 0
  fi

  _jira_http "$method" "$path" "$body" >/dev/null
}

_write_preview() {
  local method="$1" path="$2" body="${3:-}" log_file="$STATE_DIR/.would-write.log"
  {
    printf '\n'
    printf '  +----------------------------------------------------------------+\n'
    # Not padded to a right border and not cut at 49 columns. The body lines below
    # have no right border either, and the path is the one thing in this header
    # that identifies the write - half of it identifies nothing.
    printf '  | WOULD %-6s %s\n' "$method" "$path"
    printf '  +----------------------------------------------------------------+\n'
    if [ -n "$body" ]; then
      local rendered
      rendered=$(printf '%s' "$body" | adf_to_text 2>/dev/null || true)
      if [ -n "$rendered" ]; then
        printf '%s\n' "$rendered" | sed 's/^/  | /'
        printf '  +-- raw ---------------------------------------------------------+\n'
      fi
      printf '%s' "$body" | jq -S . 2>/dev/null | sed 's/^/  | /' \
        || printf '%s\n' "$body" | sed 's/^/  | /'
    fi
    printf '  +----------------------------------------------------------------+\n'
  } | tee -a "$log_file"
}

# --- ADF --------------------------------------------------------------------
# Section 16: v3 comments must be Atlassian Document Format, not a plain
# string. Building the document node by node keeps the text out of the JSON
# entirely, so a ticket containing quotes, braces or newlines cannot break the
# payload or inject structure.
#
# Usage: start with adf_new, pipe the document through the builders, finish
# with adf_comment_body.
#
#   doc=$(adf_new)
#   doc=$(adf_heading "$doc" 3 "Refinement")
#   doc=$(adf_para    "$doc" "One paragraph.")
#   body=$(adf_comment_body "$doc")

adf_new() { printf '[]'; }

adf_para() {
  jq -c --arg t "$2" \
    '. + [{type:"paragraph",content:[{type:"text",text:$t}]}]' <<< "$1"
}

adf_para_em() {
  jq -c --arg t "$2" \
    '. + [{type:"paragraph",content:[{type:"text",text:$t,marks:[{type:"em"}]}]}]' <<< "$1"
}

adf_heading() {
  jq -c --argjson l "$2" --arg t "$3" \
    '. + [{type:"heading",attrs:{level:$l},content:[{type:"text",text:$t}]}]' <<< "$1"
}

# adf_bullets <doc> <newline-separated-items>
adf_bullets() {
  local doc="$1" items="$2" tmp
  [ -n "$items" ] || { printf '%s' "$doc"; return 0; }
  tmp=$(mktemp)
  printf '%s' "$items" > "$tmp"
  jq -c --rawfile items "$tmp" '
    . + [{
      type: "bulletList",
      content: ($items | rtrimstr("\n") | split("\n") | map(select(length > 0)) | map({
        type: "listItem",
        content: [{type:"paragraph",content:[{type:"text",text:.}]}]
      }))
    }]' <<< "$doc"
  rm -f "$tmp"
}

# adf_ordered <doc> <newline-separated-items>
adf_ordered() {
  local doc="$1" items="$2" tmp
  [ -n "$items" ] || { printf '%s' "$doc"; return 0; }
  tmp=$(mktemp)
  printf '%s' "$items" > "$tmp"
  jq -c --rawfile items "$tmp" '
    . + [{
      type: "orderedList",
      attrs: {order: 1},
      content: ($items | rtrimstr("\n") | split("\n") | map(select(length > 0)) | map({
        type: "listItem",
        content: [{type:"paragraph",content:[{type:"text",text:.}]}]
      }))
    }]' <<< "$doc"
  rm -f "$tmp"
}

# adf_bullets_titled <doc> <json-array-of-{title,description}>
#
# split_into's shape: one bullet per proposed slice, the title in bold so a
# reader can scan the list of names before reading any of the boundaries, the
# description following it in plain text on the same line - one bullet, not a
# heading plus a paragraph, because this is still a Jira comment held to the
# same brevity rule as everything else in it.
adf_bullets_titled() {
  local doc="$1" items="$2"
  [ "$(jq 'length' <<< "$items")" -gt 0 ] || { printf '%s' "$doc"; return 0; }
  jq -c --argjson items "$items" '
    . + [{
      type: "bulletList",
      content: ($items | map({
        type: "listItem",
        content: [{
          type: "paragraph",
          content: (
            [{type:"text", text:(.title // ""), marks:[{type:"strong"}]}]
            + (if (.description // "") == "" then []
               else [{type:"text", text:(": " + .description)}] end)
          )
        }]
      }))
    }]' <<< "$doc"
}

adf_code() {
  local doc="$1" text="$2" tmp
  tmp=$(mktemp)
  printf '%s' "$text" > "$tmp"
  jq -c --rawfile t "$tmp" \
    '. + [{type:"codeBlock",attrs:{},content:[{type:"text",text:($t|rtrimstr("\n"))}]}]' <<< "$doc"
  rm -f "$tmp"
}

adf_rule() { jq -c '. + [{type:"rule"}]' <<< "$1"; }

# adf_expand <doc> <title> <inner-doc>
#
# A collapsible section. `inner-doc` is a document built with these same
# builders, so what goes inside a fold is built node by node exactly like what
# goes outside one, and the title goes in through --arg like every other piece
# of text here.
#
# What the published ADF schema says about this node, since it is the one node in
# this file with rules the others do not have:
#   - it is a top-level block, so it is a sibling of the paragraphs around it
#     rather than a wrapper over them. Inside a table cell the node is
#     nestedExpand instead, and nothing here builds tables.
#   - `content` needs at least one child, which is why an empty inner document
#     adds no node at all rather than an empty fold. Same shape as adf_bullets:
#     nothing in, nothing added.
#   - a heading, a bulletList, a paragraph, a codeBlock and a rule are all legal
#     children; another expand is not.
#   - `title` is an optional string and `marks` must be empty.
adf_expand() {
  local doc="$1" title="$2" inner="$3"
  [ "$(jq 'length' <<< "$inner")" -gt 0 ] || { printf '%s' "$doc"; return 0; }
  jq -c --arg t "$title" --argjson c "$inner" \
    '. + [{type:"expand",attrs:{title:$t},content:$c}]' <<< "$doc"
}

adf_comment_body() {
  jq -c --argjson content "$1" '{body:{type:"doc",version:1,content:$content}}' <<< '{}'
}

# Renders an ADF payload back to plain text so a dry run shows the comment as a
# human would read it, not as JSON.
adf_to_text() {
  jq -r '
    def inline: [.[]? | select(.type=="text") | .text] | join("");
    def block:
      if   .type=="heading"     then "## " + (.content|inline)
      elif .type=="paragraph"   then (.content|inline)
      elif .type=="codeBlock"   then (.content|inline | split("\n") | map("    "+.) | join("\n"))
      elif .type=="rule"        then "---"
      elif .type=="bulletList"  then [.content[]? | "  - " + ([.content[]?|select(.type=="paragraph")|.content|inline]|join(""))] | join("\n")
      elif .type=="orderedList" then [.content[]? | "  * " + ([.content[]?|select(.type=="paragraph")|.content|inline]|join(""))] | join("\n")
      elif .type=="expand"      then (["[+] " + (.attrs.title // "")] + [.content[]? | block]) | join("\n")
      else "" end;
    (.body // .) | (.content // []) | [.[] | block] | join("\n")
  ' 2>/dev/null
}

# --- jira actions -----------------------------------------------------------
# Everything below writes through jira_write. Nothing here talks to curl.

jira_comment_adf() {
  jira_write POST "/issue/$1/comment" "$2"
}

jira_add_label() {
  jira_write PUT "/issue/$1" "$(jq -nc --arg l "$2" '{update:{labels:[{add:$l}]}}')"
}

jira_remove_label() {
  jira_write PUT "/issue/$1" "$(jq -nc --arg l "$2" '{update:{labels:[{remove:$l}]}}')"
}

jira_assign() {
  local key="$1" account_id="$2"
  [ -n "$account_id" ] || { log "$key: no account id to assign to, skipping"; return 0; }
  jira_write PUT "/issue/$key/assignee" "$(jq -nc --arg a "$account_id" '{accountId:$a}')"
}

# Links two issues as duplicates. The link type name differs per site; the
# default Jira Cloud set calls it "Duplicate".
jira_link_duplicate() {
  local key="$1" other="$2" type="${JIRA_DUPLICATE_LINK_TYPE:-Duplicate}"
  jira_write POST "/issueLink" "$(jq -nc \
    --arg t "$type" --arg in "$key" --arg out "$other" \
    '{type:{name:$t},inwardIssue:{key:$in},outwardIssue:{key:$out}}')"
}

# --- figma reads (design context) --------------------------------------------
# A ticket's description already carries whatever Figma frames the reporter
# meant, as ordinary URLs Jira may have wrapped in a link mark or an inline
# card - so this reads the description's raw ADF for every string that looks
# like a Figma URL, rather than the plain-text rendering adf_to_text produces,
# because that rendering keeps a text node's visible text and drops every
# mark's attrs: a link whose display text is not the URL itself, or a
# smart-embedded frame with no visible text at all, would otherwise vanish
# before this ever saw it.

# figma_urls_in_issue <issue-json>
#
# Every figma.com URL string found anywhere in the description, one per line,
# however Jira represented it - a plain string description, a text node's own
# text, a link mark's href, an inline card's url. `.. | strings` walks the
# whole document regardless of shape, which is what makes this robust to that
# variation without three separate cases to keep in sync.
figma_urls_in_issue() {
  local issue_json="$1" desc
  desc=$(printf '%s' "$issue_json" | jq -c '.fields.description // empty' 2>/dev/null)
  [ -n "$desc" ] || return 0
  printf '%s' "$desc" | jq -r 'if type == "string" then . else [.. | strings] | join("\n") end' 2>/dev/null \
    | grep -oE 'https?://[a-zA-Z0-9.-]*figma\.com/[^[:space:]"'"'"'<>()]*'
}

# figma_safe_id <node-id>
#
# Filesystem-safe form of a node id ("1:23" -> "1-23"), for fixture filenames
# and for the files this run writes under state/design/.
figma_safe_id() { printf '%s' "$1" | tr ':' '-'; }

# figma_parse_url <url>
#
# "file_key<TAB>node_id" for one Figma URL, or nothing. A link with no
# node-id names a whole file rather than a frame - there is no single thing to
# fetch or to hand the refiner, so it is skipped rather than guessed at. The
# node-id query parameter is dash-separated in a URL a browser produced
# ("1-23") and may be percent-encoded if pasted from elsewhere ("1%3A23"); the
# API wants a colon ("1:23").
figma_parse_url() {
  local url="$1" fkey nid
  fkey=$(printf '%s' "$url" | sed -nE 's#.*figma\.com/(file|design|proto)/([A-Za-z0-9]+)/.*#\2#p')
  [ -n "$fkey" ] || return 0
  nid=$(printf '%s' "$url" | grep -oE 'node-id=[^&]+' | head -1 | cut -d= -f2-)
  [ -n "$nid" ] || return 0
  nid=$(printf '%s' "$nid" | sed -E 's/%3[Aa]/:/g; s/^([0-9]+)-([0-9]+)$/\1:\2/')
  printf '%s\t%s\n' "$fkey" "$nid"
}

# figma_links_in_issue <issue-json>
#
# Every file-key/node-id pair the ticket's description already links, one per
# line, deduplicated. Nothing here invents a node or asks a human for one.
figma_links_in_issue() {
  local issue_json="$1" url
  figma_urls_in_issue "$issue_json" | while IFS= read -r url; do
    figma_parse_url "$url"
  done | sort -u
}

# figma_fetch_node <file-key> <node-id>
#
# The nodes endpoint: layer names, types and text content for one frame.
# Fixture mode reads a canned file the same way jira_read does and needs no
# token, matching the standing rule that fixture mode runs with no network and
# no credentials at all. Anywhere else this needs FIGMA_TOKEN. Every failure -
# no fixture, no token, a stale link answering 404, a network error - returns
# 1 rather than dying: see the design-context rule below for why.
figma_fetch_node() {
  local fkey="$1" nid="$2" safe file
  safe=$(figma_safe_id "$nid")
  if [ "$ORC_JIRA_MODE" = "fixture" ]; then
    file="$FIXTURE_DIR/figma/nodes/${fkey}_${safe}.json"
    [ -f "$file" ] || return 1
    cat "$file"
    return 0
  fi
  [ -n "$FIGMA_TOKEN" ] || return 1
  _figma_http GET "/v1/files/$fkey/nodes?ids=$(printf '%s' "$nid" | jq -sRr @uri)"
}

# figma_fetch_image <file-key> <node-id> <out-file>
#
# The images endpoint, then the extra hop it always requires: the response
# names a pre-signed URL for the rendered PNG rather than returning it, so
# this is two requests behind one call. Same fixture-mode and failure contract
# as figma_fetch_node.
figma_fetch_image() {
  local fkey="$1" nid="$2" out="$3" safe file resp render_url
  safe=$(figma_safe_id "$nid")
  if [ "$ORC_JIRA_MODE" = "fixture" ]; then
    file="$FIXTURE_DIR/figma/images/${fkey}_${safe}.png"
    [ -f "$file" ] || return 1
    cp "$file" "$out"
    return 0
  fi
  [ -n "$FIGMA_TOKEN" ] || return 1
  resp=$(_figma_http GET "/v1/images/$fkey?ids=$(printf '%s' "$nid" | jq -sRr @uri)&format=png") || return 1
  render_url=$(printf '%s' "$resp" | jq -r --arg n "$nid" '.images[$n] // empty' 2>/dev/null)
  [ -n "$render_url" ] || return 1
  _figma_download "$render_url" "$out"
}

# figma_node_summary <nodes-json> <node-id>
#
# The node's layer tree as indented text: type, name, and whatever a TEXT
# layer's characters say. This is what stands in for the design when no image
# is fetched, and it is what a fetched image is captioned with either way -
# an image shows spacing, this says what the words are.
figma_node_summary() {
  local json="$1" nid="$2"
  jq -r --arg n "$nid" '
    .nodes[$n].document as $doc
    | def walk(node; depth):
        (node | ("  " * depth) + "- " + (.type // "?") + " \"" + (.name // "") + "\""
             + (if (.characters // "") != "" then ": \"" + .characters + "\"" else "" end)),
        ((node.children // [])[] | walk(.; depth + 1));
    if $doc == null then empty else walk($doc; 0) end
  ' <<< "$json" 2>/dev/null
}

# figma_wants_image <nodes-json> <node-id>
#
# Whether layout or spacing plausibly matters enough to justify fetching a
# render as well as the text. A frame, component, instance, section or group
# is a composition an image can show that a layer list cannot; several
# children under any other node type is the same case without a container
# type saying so; a lone text layer's characters already are its whole
# content, and an image of it would tell the refiner nothing the summary
# above did not.
figma_wants_image() {
  local json="$1" nid="$2"
  jq -e --arg n "$nid" '
    .nodes[$n].document as $doc
    | ($doc.type // "") as $t
    | (["FRAME","COMPONENT","COMPONENT_SET","INSTANCE","SECTION","GROUP"] | index($t) != null) as $container
    | (($doc.children // []) | length) as $n_children
    | $container or ($n_children > 1)
  ' <<< "$json" >/dev/null 2>&1
}

# figma_design_context <key> <issue-json>
#
# Every Figma frame the ticket already links, folded into refinement's context
# the same way repository content is: written to files under state/ and named
# here for the agent to open with its Read tool, rather than inlined whole -
# an image is binary and a node tree can run long, and this is the same shape
# searchable already uses for a repository path.
#
# No token configured is not a failure, it is today's behaviour: nothing is
# attempted and nothing is added to the context, the exact bar the acceptance
# criteria draws, because a reporter's raw URL is already in the ticket text
# the refiner reads regardless and it already says it cannot open a design it
# has no way to fetch. A token that IS configured but a call that fails - a
# stale link, a bad token, a network blip - is a different case and is
# reported by name in the context, the same way a stale repository clone is
# reported on the ticket rather than silently skipped.
figma_design_context() {
  local key="$1" issue_json="$2"
  if [ "$ORC_JIRA_MODE" != "fixture" ] && [ -z "$FIGMA_TOKEN" ]; then
    return 0
  fi

  local links fkey nid safe node_json dir out_md img_path opened="" failed=""
  links=$(figma_links_in_issue "$issue_json")
  [ -n "$links" ] || return 0

  dir="$STATE_DIR/design/$key"
  mkdir -p "$dir"
  rm -f "$dir"/*.md "$dir"/*.png 2>/dev/null

  while IFS=$'\t' read -r fkey nid; do
    [ -n "$fkey" ] || continue
    safe=$(figma_safe_id "$nid")
    if ! node_json=$(figma_fetch_node "$fkey" "$nid") || ! printf '%s' "$node_json" | jq -e . >/dev/null 2>&1; then
      failed="$failed  Figma file $fkey, node $nid: could not open (missing/invalid token, a stale link, or a network error)
"
      continue
    fi
    out_md="$dir/${fkey}_${safe}.md"
    {
      printf 'Figma file %s, node %s\n\n' "$fkey" "$nid"
      figma_node_summary "$node_json" "$nid"
    } > "$out_md"
    if figma_wants_image "$node_json" "$nid"; then
      img_path="$dir/${fkey}_${safe}.png"
      if figma_fetch_image "$fkey" "$nid" "$img_path"; then
        opened="$opened  $out_md (layer/text structure) and $img_path (rendered image) - Figma file $fkey, node $nid
"
      else
        opened="$opened  $out_md (layer/text structure; the rendered image could not be fetched) - Figma file $fkey, node $nid
"
      fi
    else
      opened="$opened  $out_md (layer/text structure; no image fetched - a single text layer has no layout to show) - Figma file $fkey, node $nid
"
    fi
  done <<< "$links"

  [ -n "$opened$failed" ] || return 0

  local ctx="# Design

The ticket links the Figma frame(s) below. Read the files named here with your
Read tool before answering - they are the design, and reasoning without them
when they were fetched successfully is the failure this section exists to fix."
  if [ -n "$opened" ]; then
    ctx="$ctx

Opened:
$(printf '%s' "$opened" | sed 's/^/  /')"
  fi
  if [ -n "$failed" ]; then
    ctx="$ctx

Could not open. Reason about the ticket without these, and say so in not_verified:
$(printf '%s' "$failed" | sed 's/^/  /')"
  fi
  printf '%s' "$ctx"
}

# --- markdown -> ADF --------------------------------------------------------
# Jira v3 returns descriptions as ADF, so the fixtures store them that way.
# Authoring them as JSON by hand is unmaintainable, and the golden set has to
# be cheap to grow (section 15 wants twenty to thirty tickets), so fixture
# sources are markdown and fixtures/build.sh converts them here. Keeping the
# conversion in the library means every ADF document in the system - posted or
# canned - is built by the same code.
#
# Supported subset: '## heading', '- bullet', '1. ordered', fenced code, and
# blank-line-separated paragraphs. Anything else is treated as paragraph text.
adf_from_markdown() {
  local doc para list olist code in_code line
  doc=$(adf_new); para=""; list=""; olist=""; code=""; in_code=0

  _flush_para()  { [ -n "$para" ]  && { doc=$(adf_para "$doc" "$para"); para=""; }; return 0; }
  _flush_list()  { [ -n "$list" ]  && { doc=$(adf_bullets "$doc" "$list"); list=""; }; return 0; }
  _flush_olist() { [ -n "$olist" ] && { doc=$(adf_ordered "$doc" "$olist"); olist=""; }; return 0; }
  _flush_all()   { _flush_para; _flush_list; _flush_olist; }

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '```'*)
        if [ "$in_code" = 1 ]; then
          doc=$(adf_code "$doc" "$code"); code=""; in_code=0
        else
          _flush_all; in_code=1
        fi
        continue
        ;;
    esac
    if [ "$in_code" = 1 ]; then
      code="$code$line
"
      continue
    fi
    case "$line" in
      '')
        _flush_all
        ;;
      '#'*)
        _flush_all
        local level text
        text=${line##\#}
        level=2
        case "$line" in
          '###'*) level=3; text=${line#\#\#\# } ;;
          '##'*)  level=3; text=${line#\#\# } ;;
          '#'*)   level=2; text=${line#\# } ;;
        esac
        doc=$(adf_heading "$doc" "$level" "$text")
        ;;
      '- '*|'* '*)
        _flush_para; _flush_olist
        list="$list${line#??}
"
        ;;
      [0-9].' '*|[0-9][0-9].' '*)
        _flush_para; _flush_list
        olist="$olist${line#*. }
"
        ;;
      *)
        _flush_list; _flush_olist
        if [ -n "$para" ]; then para="$para $line"; else para="$line"; fi
        ;;
    esac
  done
  [ "$in_code" = 1 ] && doc=$(adf_code "$doc" "$code")
  _flush_all

  jq -c --argjson c "$doc" -n '{type:"doc",version:1,content:$c}'
}

# Any Jira description, ADF object or legacy plain string, as plain text.
description_text() {
  local issue_json="$1" kind
  kind=$(printf '%s' "$issue_json" | jq -r '.fields.description | type')
  case "$kind" in
    object) printf '%s' "$issue_json" | jq -c '.fields.description' | adf_to_text ;;
    string) printf '%s' "$issue_json" | jq -r '.fields.description' ;;
    *)      printf '' ;;
  esac
}

# --- reading the comments on a ticket ---------------------------------------
#
# Two passes read comments, and they read them for opposite reasons.
# bin/orc-reconcile.sh looks for the orchestrator's own footprint - the marker
# line saying which prompt judged the ticket and against which revision of its
# text - and bin/orc-harvest.sh looks for everything that is not that: what a
# person wrote underneath a question refinement asked them.
#
# One reader, because the two halves are defined against each other. A comment is
# the orchestrator's when it carries the marker and somebody else's when it does
# not, and two implementations of that test would eventually disagree about a
# comment - at which point one pass would attribute a machine's words to a human,
# which is the one mistake a record of who said what may not make.

# True when this comment is one the orchestrator left.
comment_is_ours() {
  printf '%s' "$1" | jq -e --arg m "$ORC_COMMENT_MARKER" '(tostring) | contains($m)' >/dev/null 2>&1
}

# Every comment on an issue, oldest first, one compact JSON object per line.
issue_comments() {
  printf '%s' "$1" | jq -c '.fields.comment.comments[]? // empty'
}

# The last comment the orchestrator left on an issue, or nothing.
latest_marker_comment() {
  printf '%s' "$1" | jq -c --arg m "$ORC_COMMENT_MARKER" '
    [.fields.comment.comments[]? | select((tostring) | contains($m))] | last // empty'
}

# The newest comment on an issue that the orchestrator did not leave, or nothing.
#
# The other half of latest_marker_comment, and the reason refinement runs again
# at all after the first round: a reporter answering the questions is the whole
# point of asking them, and the ticket's own text does not move when they do.
# So this is what a description edit is to the content hash - the second thing
# the skip is keyed on.
#
# "Newest" is this array's own order rather than a comparison of timestamps.
# Jira returns the comments oldest first, which latest_marker_comment already
# relies on, and a created value carries a timezone offset that makes a lexical
# compare of two of them wrong. One assumption, in the two places that read
# these comments as a sequence.
newest_foreign_comment() {
  local c newest=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    comment_is_ours "$c" || newest="$c"
  done <<< "$(issue_comments "$1")"
  printf '%s' "$newest"
}

# The same thing as it stood when the orchestrator last commented, which is what
# a refinement running at that moment would have seen.
#
# This is what makes the field rebuildable, and state/ is a cache: the position
# of the orchestrator's own last comment splits the thread into what was there
# when it judged and what has arrived since, with no timestamp arithmetic and
# nothing recorded outside Jira. A ticket the orchestrator has never commented
# on has never been refined, so there is nothing to have seen and nothing is
# returned.
foreign_comment_at_last_refinement() {
  local c newest="" at_ours="" saw_ours=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if comment_is_ours "$c"; then
      saw_ours=1
      at_ours="$newest"
    else
      newest="$c"
    fi
  done <<< "$(issue_comments "$1")"
  [ "$saw_ours" = "1" ] || return 0
  printf '%s' "$at_ours"
}

# marker_value <comment-json-or-text> <field>
#
# What the marker line says about one thing: `prompt`, `ticket-rev`. Read off the
# comment as a whole rather than off a located line, because the marker is a
# paragraph inside an ADF document and locating it would mean rendering the
# document first - and a value that is absent is absent either way.
marker_value() {
  printf '%s' "$1" | sed -n "s/.*$2=\([A-Za-z0-9._-]*\).*/\1/p" | head -1
}

comment_field() { printf '%s' "$1" | jq -r "$2 // \"\""; }

# The questions one comment asks, one per line, in the order the reader sees
# them numbered.
#
# Read out of the orderedList node rather than out of rendered text. Refinement
# builds that node itself, so the question side of a match needs no parsing at
# all: the number a reporter replies to is the position in this list, and the
# text is exactly what was asked.
comment_questions() {
  printf '%s' "$1" | jq -r '
    def inline: [.[]? | select(.type=="text") | .text] | join("");
    (.body // .) | (.content // [])
    | map(select(.type == "orderedList")) | first // {}
    | (.content // [])
    | .[] | [.content[]? | select(.type=="paragraph") | .content | inline] | join(" ")'
}

# The blocks of one comment, as `kind FS ordinal FS text`, one per line, where FS
# is \002. A newline inside a block becomes a space, and a \001 or \002 the
# comment itself carried becomes one too - a reporter can type anything, and a
# separator arriving inside a field would shift every later field left.
#
# \002 rather than a tab because the ordinal is empty on every block that is not
# an ordered-list item, and `IFS=$'\t' read` collapses a run of tabs and shifts
# every later field left.
#
# The ordinal is the whole reason an ordered list is read as a list here: a
# reporter who answers three questions as a three-item list has addressed them by
# position, and rendering that list to text throws the position away.
# shellcheck disable=SC2034  # read by bin/orc-harvest.sh, which sources this
COMMENT_BLOCK_FS=$'\002'
comment_blocks() {
  printf '%s' "$1" | jq -r '
    def inline: [.[]? | select(.type=="text") | .text] | join("");
    def flat: gsub("[\n\u0001\u0002]"; " ");
    def row($kind; $ord; $text): [$kind, ($ord | tostring), $text] | join("\u0002");
    (.body // .) | (.content // [])
    | map(
        if .type == "orderedList" then
          [ (.content // []) | to_entries[]
            | row("ordered"; .key + 1;
                  ([.value.content[]? | select(.type=="paragraph") | .content | inline] | join(" ") | flat)) ]
        elif .type == "bulletList" then
          [ (.content // [])[]
            | row("text"; "";
                  ([.content[]? | select(.type=="paragraph") | .content | inline] | join(" ") | flat)) ]
        elif (.content | type) == "array" then
          [ row("text"; ""; (.content | inline | flat)) ]
        else [] end)
    | flatten | .[] | select(test("[^\u0002]$"))'
}

# --- the gap a verdict leaves behind ----------------------------------------
#
# A verdict records which of the ticket's words refinement looked up, which of
# them the bundle answered, and which it could not. The unresolved half is the
# payload: it is what the gap-driven loop ranks and what the reliability report
# counts, and a run that resolves nothing and says so is worth more than one that
# quietly improvises.
#
# Two things can go wrong with that record, and both get a mechanical audit:
# a term that is not the ticket's own word, and a clean sheet earned by looking
# nothing up. Both audits report and neither repairs. Rewriting the refiner's own
# answer would leave the record saying something no refiner said, and a
# measurement corrected on the way in measures the correction.

# One term, folded so that case, hyphenation and surrounding punctuation do not
# make two spellings of the same word look like two words. "Follow-up case" and
# "follow up case" fold to the same string; so do "Ménière" and "ménière".
# The comparison below then requires a word boundary only at the start, so a
# plural or an inflected ending does not read as a different word either.
_terms_fold() {
  tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# Every term a verdict says it looked up, resolved or not, one per line.
# terms_resolved carries the concept that answered each term, so its entries are
# objects; terms_unresolved has no concept to name, which is the whole point of
# it, so its entries are plain strings. Both spellings are accepted here.
verdict_terms() {
  printf '%s' "$1" | jq -r '
    (((.terms_resolved // []) + (.terms_unresolved // []))
     | map(if type == "object" then (.term // "") else tostring end))
    | .[] | select(length > 0)'
}

# A term is code-shaped when it looks like something a refiner arrived at rather
# than something a reporter wrote: a path, a snake_case or CamelCase identifier,
# a Ruby namespace. `follow_up` resolved tells nobody anything; "revisit"
# unresolved is a gap somebody can fill.
ORC_CODE_SHAPED_TERM='(^|[^A-Za-z0-9])(app|src|lib|spec|db|config)/|\.[a-z]{2,4}$|::|[a-z0-9]_[a-z0-9]|[a-z][A-Z]'

# terms_off_ticket <ticket-text> <verdict-json>
#
# The recorded terms the ticket did not say: code-shaped, or absent from the
# ticket's own words once both sides are folded. One per line, in the spelling
# the verdict used, so the report can name what it is discounting.
terms_off_ticket() {
  local text="$1" json="$2" folded term folded_term
  folded=" $(printf '%s' "$text" | _terms_fold) "
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    if printf '%s' "$term" | grep -qE "$ORC_CODE_SHAPED_TERM"; then
      printf '%s\n' "$term"
      continue
    fi
    folded_term=$(printf '%s' "$term" | _terms_fold)
    [ -n "$folded_term" ] || { printf '%s\n' "$term"; continue; }
    case "$folded" in
      *" $folded_term"*) : ;;
      *) printf '%s\n' "$term" ;;
    esac
  done <<< "$(verdict_terms "$json")"
}

# A discounted term is a meaning nobody gave, and on a needs_input verdict it is
# the reporter's question rather than only a line in the log. Which of them can
# be asked is decided here, and it is two tests rather than one.
#
# Code-shaped is the first: `follow_up` recorded instead of the ticket's own word
# is a bookkeeping failure with nothing in it for a reporter, and asking somebody
# what an identifier means spends their goodwill on our own records. That is the
# same asymmetry ORC_CODE_SHAPED_TERM was written for.
#
# The second is that the term is about to be quoted onto a comment held to the
# reporter bar, and that bar is scanned. This is deliberately stricter than the
# code-shape rule rather than a second spelling of it: every path, extension,
# namespace and snake_case token that scanner catches carries one of these
# characters, and the one shape that carries none - CamelCase - is what the
# code-shape rule above catches. So the two together cannot put on a comment
# something the scanner would then fail on, and neither has to be kept in step
# with the other's wording.
ORC_TERM_CODE_PUNCT='[][/\.:_(){}<>=|#$@`"]'

# terms_off_to_ask <off-ticket terms, one per line> <questions already asked, one per line>
#
# The discounted terms that become a question, one per line, in the spelling the
# verdict used - because the question quotes it back.
#
# A term the refiner already asked about is left out. The prompt asks it to turn
# a meaning it cannot ground in the ticket into a question of its own, and when
# it does the term is still recorded off-ticket; asking again underneath would be
# the same question twice on one comment.
terms_off_to_ask() {
  local asked term folded
  asked=" $(printf '%s' "$2" | _terms_fold) "
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    if printf '%s' "$term" | grep -qE "$ORC_CODE_SHAPED_TERM"; then continue; fi
    if printf '%s' "$term" | grep -q "$ORC_TERM_CODE_PUNCT"; then continue; fi
    folded=$(printf '%s' "$term" | _terms_fold)
    [ -n "$folded" ] || continue
    if orc_folded_says "$asked" "$folded"; then continue; fi
    printf '%s\n' "$term"
  done <<< "$1"
}

# One question, however many terms it names, because they are one finding: the
# ticket was read in words it does not use. One question per term would spend a
# round-trip's worth of the reporter's patience on what is a single ask.
_quoted_and_list() {
  local out="" term n=0 total
  total=$(printf '%s' "$1" | grep -c . || true)
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    n=$((n + 1))
    if [ "$n" = 1 ]; then out="\"$term\""
    elif [ "$n" = "$total" ]; then out="$out and \"$term\""
    else out="$out, \"$term\""
    fi
  done <<< "$1"
  printf '%s' "$out"
}

# off_ticket_question <terms, one per line>
#
# It quotes the words that were supplied rather than naming the ticket's own,
# because the ticket's own is exactly what is not known: all this run can say is
# what it had to assume. Held to the question bar like every other question on
# the comment - one sentence, product words, answerable in a line - and the
# answer decides what gets built, which is the third test.
off_ticket_question() {
  local list count
  count=$(printf '%s' "$1" | grep -c . || true)
  list=$(_quoted_and_list "$1")
  if [ "$count" = 1 ]; then
    printf 'This ticket has been read as being about %s, which is not a word it uses - what do you mean by it?' "$list"
  else
    printf 'This ticket has been read as being about %s, which are not words it uses - what do you mean by them?' "$list"
  fi
}

# --- whether a matched reply actually resolves anything ----------------------
#
# bin/orc-harvest.sh matches a reply to its question by number, by position, by
# being the only question there was, or by reading - and every one of those four
# rules answers "who is this reply about", never "did it decide anything". A
# reply that hands the decision back to whoever asked - "whatever's easiest for
# engineering" - passes all four exactly as cleanly as "19 euros" does, and the
# loop then reads the question as settled when nothing was.
#
# This is a closed linguistic register rather than an open one: the reply
# defers to someone else's judgement, or declares no preference, in one of a
# fairly small number of stock phrasings - "your call", "up to you", "no
# preference", "whatever's easiest". That is a narrower and more mechanical
# thing to catch than "does this reply mean the same as the question" or "does
# this reply conflict with that one", which is why it is caught here rather
# than deferred to a prompt.
#
# It is deliberately not a single literal string match, the same way
# ORC_CODE_SHAPED_TERM is not one pattern for "looks like an identifier": a
# bounded set of surface forms for the deferral register, matched against
# folded text so contractions and case do not multiply the list. It is also
# deliberately not a model call. This project has now shipped two prompt-side
# "notice this and ask about it" instructions - the scope-ambiguity bullet and
# the discount-and-promote question - and in both cases the fixture that was
# supposed to prove the miss never reproduced it, while what actually closed the
# gap each time was the derived half sitting beside the prompt one. Every derived check this project
# has shipped and proven end to end - verdict_split_ready, integration_gaps,
# terms_off_to_ask - reads a closed-form fact: an array on the verdict JSON, or
# a set the code enumerates. Whether a sentence commits to an answer is not
# that kind of fact in general, and building one call site here that judges it
# with a model would be the first agent call bin/orc-harvest.sh has ever made,
# for a question this project's own findings say a prompt is the less-proven
# way to answer. A phrase list is honestly what this is: it is wrong in the
# direction this project already accepts, because the cost of being wrong is
# not symmetric. A genuine decision that happens to use one of these phrases in
# passing gets re-asked once, which costs a round-trip. A deferral this list
# misses reaches bin/orc-verify.sh looking like an ordinary answer - and a
# human still has to read every word of it before signing, because nothing here
# is ever agreed to unread. The list is the gate; the review is the backstop.
ORC_DEFERRAL_PHRASE='(^| )(your call|your choice|your decision|not my call|not my decision|up to (you|whoever|the team|engineering)|you (decide|choose|pick)|(your|engineering s|the team s) (best )?(judgement|judgment)|no (strong )?(preference|opinion|feelings)|do not care|don t care|does not matter|doesn t matter|do not mind|don t mind|not fussed|not bothered|either (way|one) (is fine|works)|whatever (is easiest|s easiest|is easier|works|s fine|is fine|you think|you prefer|you decide|makes sense|is best|s best)|whichever (is easiest|works|you prefer)|i do not know|i don t know)( |$)'

# answer_is_deferring <matched answer text>
#
# True when the text is a deferral rather than a decision. Resolution, not
# length, is the test: a short answer that names a value ("19 euros") is not
# deferring, and a long answer that never commits to anything still is.
answer_is_deferring() {
  printf '%s' " $(printf '%s' "$1" | _terms_fold) " | grep -Eq "$ORC_DEFERRAL_PHRASE"
}

# terms_contradiction <verdict-json>
#
# Prints what a verdict's gap record contradicts, or nothing.
#
# One shape, and it is the loophole that matters: `locality_basis: none` says the
# bundle answered nothing and nothing was searched, so a term refinement could
# not resolve exists by construction. An empty terms_unresolved next to it is a
# clean sheet earned by looking nothing up, and the point of recording the gap is
# to make exactly that visible.
terms_contradiction() {
  printf '%s' "$1" | jq -r '
    if (.locality_basis == "none") and (((.terms_unresolved // []) | length) == 0)
    then "locality_basis is none with nothing unresolved: a run that looked nothing up cannot also have no gap"
    else empty end'
}

# verdict_split_ready <verdict-json>
#
# True only for the terminal signal on an oversized card: verdict is
# needs_input, every blocking question already has an answer (questions is
# empty), and a split is still proposed (split_into is not). That is a card
# that has been through this loop before and has nothing left to ask - only
# the split remains.
#
# Computed here rather than asked of the refiner as its own field, the same
# reason terms_contradiction is computed rather than reported: a self-declared
# boolean can disagree with the two arrays it is meant to summarise, and a
# derived one cannot.
verdict_split_ready() {
  printf '%s' "$1" | jq -e '
    (.verdict == "needs_input")
    and (((.questions // []) | length) == 0)
    and (((.split_into // []) | length) > 0)
  ' >/dev/null
}

# round_is_stuck <verdict> <split_ready> <the questions the ticket is being asked>
#
# The one shape a needs_input round may never reach: not terminal, and asking
# nothing. There is nothing for the reporter to answer and no split for them to
# run, so the comment cannot be acted on from either side and the next round
# reads the same ticket to the same conclusion. It is a stall dressed as
# progress, and until this existed nothing named it.
#
# Read off the list the comment is actually about to carry rather than off the
# refiner's own `questions` array, for the reason every other derived check here
# is derived: three of the four questions a needs_input comment can hold are
# promoted by this harness and appear in no array the refiner wrote, so a test
# against `questions` would call a round stuck while a promoted question was
# standing on it - which is exactly the reading that made this look like a
# missing terminal state rather than a real second-read disagreement.
#
# Only needs_input can reach it. A ready comment carries no question list at all
# and a duplicate is being closed against another ticket, so neither is a stall.
round_is_stuck() {
  [ "$1" = "needs_input" ] || return 1
  [ "$2" != "true" ] || return 1
  [ -z "$(printf '%s' "$3" | tr -d '[:space:]')" ] || return 1
  return 0
}

# --- the adversarial re-read ------------------------------------------------
#
# The first pass asks what it still wants to know. A sentence with no gap in it -
# every word defined, every criterion stated, nothing absent - passes that
# question cleanly while still parsing two ways, so the pass that enumerates
# gaps structurally cannot find one. The second pass asks the other question
# instead: what in this text admits two readings that would produce different
# software.
#
# Two derivations live here rather than in bin/orc-refine.sh, because both are
# read by bin/orc-check.sh directly as well as through a refinement.

# verdict_is_terminal_shape <verdict-json>
#
# The refiner's own output says this round is about to become terminal: it is
# returning ready, or it is returning the split-ready combination. Those are the
# two rounds where a wrong reading is most expensive - the card is about to be
# handed to somebody to build, or carved into slices drawn around this reading -
# and they are the gate on the second call.
#
# Read off the refiner's two arrays and its verdict, deliberately not off
# `confidence`. That field is self-reported and nothing has ever validated it,
# and the failure this pass exists for is a confidently wrong read: the sample
# that asked one question and asserted a meaning the ticket never gave would
# have said `high`, and gating on it would switch the pass off in exactly the
# case it was built for. Ticket size was weighed and refused for the reason the
# scout report gives - split_into is only populated once the model has already
# decided to split, which is the judgement in question.
verdict_is_terminal_shape() {
  printf '%s' "$1" | jq -e '.verdict == "ready"' >/dev/null && return 0
  verdict_split_ready "$1"
}

# misread_questions <misread-json>
#
# One question per line. Nothing is filtered and nothing is rewritten: these are
# the refiner's own questions, written under the whole of the question bar the
# first pass was held to, and its own questions are not filtered either. An
# entry with no question in it renders no bullet, which is why the empty ones
# go.
misread_questions() {
  printf '%s' "$1" | jq -r '.misreadings // [] | .[]? | .question // "" | tostring' \
    | grep -v '^$' || true
}

# The same folding, for an awk that has to do it over tens of thousands of
# catalogue strings rather than over a dozen terms. A shell loop is the right
# shape for a verdict's term list and the wrong shape for a corpus, so the rule
# exists twice - and because it does, bin/orc-check.sh folds the same strings
# both ways and fails if the two disagree. Two spellings of one rule are only
# safe while something is comparing them.
# shellcheck disable=SC2034  # read by bin/orc-okf-draft.sh, which sources this
ORC_FOLD_AWK='
function orc_fold(s,  t) {
  t = tolower(s)
  gsub(/[^a-z0-9]/, " ", t)
  gsub(/  +/, " ", t)
  sub(/^ /, "", t); sub(/ $/, "", t)
  return t
}'

# orc_folded_says <folded haystack> <folded needle>
#
# Both sides already folded. A word boundary is required at the start and not at
# the end, so a plural or an inflected ending still reads as the same word -
# the same asymmetry terms_off_ticket uses, for the same reason.
orc_folded_says() {
  case " $1" in *" $2"*) return 0 ;; *) return 1 ;; esac
}

# --- a new member of a set the code already enumerates ----------------------
#
# A ticket that adds one more of something the product already enumerates
# somewhere carries work it never mentions. A card introducing a new kind of
# case says nothing about the report that groups cases by kind, and the report
# under-reports from the day the feature ships - not because the reporter was
# careless, but because the word for that report is not in their vocabulary for
# this ticket. Refinement misses it round after round for the same reason, and
# it is found by hand afterwards.
#
# It is the one gap class in this system that reading the ticket harder cannot
# close. Failure states, empty states and permissions are all in the ticket if
# you look; this one is only in the code, in the places that assume the set
# being extended is complete. So it is found mechanically here rather than hoped
# for in the prompt, which is this project's repeated measured finding about
# which of the two is a strong lever.
#
# The unit is an **enum**, deliberately and narrowly. An enum is the one
# declaration in a Rails codebase that says "these are all the members there
# are" - the drafted domain-rules concept already calls it a state machine,
# complete. A frozen constant is a list somebody froze, and deciding which
# frozen lists are sets and which are configuration is a judgement
# bin/orc-okf-draft.sh already makes for a different purpose; copying that
# judgement here would be a second spelling of it. Constants are the obvious
# widening and they are left out until the enum half has been measured.
#
# What this can and cannot prove is worth being plain about, because the whole
# value of the finding is that it can name the place it came from. It proves:
# the code declares a closed set, the ticket names members of it, the ticket
# also names something in the same shape that the set does not have, and other
# files enumerate the set's members. It does not prove the ticket is *adding*
# that member rather than describing one - nothing in a description says so
# mechanically. Every filter below exists to make the difference not matter: a
# phrase said once is not what a ticket is introducing, a set with no
# enumeration site outside its own model has no integration work to report, and
# a place the ticket already names is not a place it forgot.

# The enum declarations one Rails file holds, as key<TAB>values<TAB>line.
#
# Both spellings Rails accepts: values beside the key on one line, and values in
# a block underneath it. A block is flushed when the next enum starts as well as
# when it closes, because two enums in a row would otherwise overwrite the first
# before it was ever printed.
#
# Three characters minimum on a value, and a short list of struck-out keywords,
# because `%i[a b]` contributes the `i` of its own sigil and `prefix: true`
# contributes both of its words. A two-character member name is not a product
# word, so the floor costs nothing real.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_ENUM_DECL_AWK='
function flush() {
  if (key != "" && vals != "") print key "\t" vals "\t" line
  key = ""; vals = ""; inb = 0
}
function keep(v) {
  if (length(v) < 3) return 0
  if (v == key) return 0
  if (v ~ /^(prefix|suffix|default|validate|scopes|instance_methods|true|false|nil)$/) return 0
  return 1
}
/^[[:space:]]*enum[[:space:]]+:?[a-z_]+/ {
  flush()
  name = $0
  sub(/^[[:space:]]*enum[[:space:]]+:?/, "", name)
  sub(/[^a-z_].*$/, "", name)
  key = name; line = NR; inb = 1
  rest = $0
  sub(/^[[:space:]]*enum[[:space:]]+:?/, "", rest)
  sub(/^[a-z_]+:?/, "", rest)
  n = split(rest, tok, /[^a-z_0-9]+/)
  for (i = 1; i <= n; i++)
    if (tok[i] ~ /^[a-z][a-z_0-9]*$/ && keep(tok[i]))
      vals = vals (vals == "" ? "" : ",") tok[i]
  next
}
inb && /^[[:space:]]*[a-z_]+:?[[:space:]]*(=>)?[[:space:]]*[0-9-]/ {
  v = $0; sub(/^[[:space:]]*/, "", v); sub(/[^a-z_0-9].*$/, "", v)
  if (keep(v)) vals = vals (vals == "" ? "" : ",") v
  next
}
inb && /^[[:space:]]*[]})]/ { flush(); next }
inb && /^[[:space:]]*(def|end|validates|validate|belongs_to|has_many|has_one|scope|before_|after_)/ { flush() }
END { flush() }
'

# enum_sets_of <repository path>
#
# key<TAB>values<TAB>relpath, one line per enum the repository declares. Models
# only: an enum declared anywhere else is a local convenience rather than a set
# the product has a word for. Two members minimum, because a one-member set is
# a declaration somebody has not finished rather than a set anything enumerates.
enum_sets_of() {
  local p="$1" f rel
  [ -d "$p/app/models" ] || return 0
  find "$p/app/models" -name '*.rb' -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$p"/}
    awk "$ORC_ENUM_DECL_AWK" "$f" | while IFS=$'\t' read -r k v _l; do
      [ -n "$k" ] && [ -n "$v" ] || continue
      case "$v" in *,*) : ;; *) continue ;; esac
      printf '%s\t%s\t%s\n' "$k" "$v" "$rel"
    done
  done
}

# A word without its plural. Enough of a rule to strip an `s` without turning
# `status` into `statu`, and no more: what it feeds is a comparison against the
# ticket's own words, where a wrong stem costs a missed finding rather than a
# wrong one.
_singular() {
  case "$1" in
    *ies)                    printf '%s' "${1%ies}y" ;;
    *us|*ss|*is)             printf '%s' "$1" ;;
    *sses|*ches|*shes|*xes)  printf '%s' "${1%es}" ;;
    *s)                      printf '%s' "${1%s}" ;;
    *)                       printf '%s' "$1" ;;
  esac
}

# The noun a set is a set *of*, from the set's own key.
#
# `case_type` is a set of cases, not a set of types, so the head is the word in
# front of the classifier. A key that is nothing but a classifier - `status`,
# `kind` - names no noun at all and is skipped: it is the shape a hundred
# unrelated models share, and matching the ticket against it would find every
# sentence with the word "status" in it.
_set_head_noun() {
  local words last rest
  words=$(printf '%s' "$1" | tr '_' ' ' | _terms_fold)
  last=$(_singular "${words##* }")
  rest=${words% *}
  [ "$rest" = "$words" ] && rest=""
  case "$last" in
    type|kind|category|status|state|class|level|tier|group|variant|flavour|flavor|code|name|reason)
      [ -n "$rest" ] || return 0
      last=$(_singular "${rest##* }") ;;
  esac
  [ "${#last}" -ge 3 ] || return 0
  printf '%s' "$last"
}

# The words a set's key is made of, as a reader would say them. Folded, so it is
# the product's phrase rather than the identifier: `case_type` becomes "case
# type", which is a thing a depot manager can be asked about, and `case_type` is
# not.
_set_words() { printf '%s' "$1" | tr '_' ' ' | _terms_fold; }

# The verbs that make naming a set's key an enumeration of it rather than one
# use of it. `Case.group(:case_type).count` walks the whole set; `case.case_type
# == :reopened` reads one member. A closed list, because a heuristic about what
# a line is doing is exactly the guesswork that would put an unfounded place in
# front of a reporter - and only verbs that aggregate, since the key has to
# follow the verb for the pattern below to match at all: `each` and `map` were on
# this list and could only ever have matched `each(:case_type)`, which nobody
# writes.
ORC_ENUM_GROUPING_VERBS='group|group_by|count|distinct|pluck|tally'

# The file extensions a place that enumerates a set can be written in. A fleet's
# report is Ruby and its dashboard is TypeScript, and a set enumerated in one is
# as much affected work as a set enumerated in the other.
ORC_SITE_EXTENSIONS='rb ts tsx js jsx vue'

# enumeration_sites <repository path> <key> <values, comma-separated> <declaring relpath, or empty>
#
# The files in this repository that enumerate the set, one relpath per line.
#
# Two ways in, and both are about the set as a whole. Naming two or more of its
# members is literally a listing of them. Naming the key beside one of the verbs
# above is the same thing written as a query. A file naming one member is not a
# site: that is a single branch, and every codebase has hundreds.
#
# The declaring model is excluded, and so are tests, migrations and vendored
# trees: the model is the ticket's own work, and the rest are not places the
# product does anything.
enumeration_sites() {
  local path="$1" key="$2" values="$3" decl="$4" vre inc f rel named
  vre=$(printf '%s' "$values" | tr ',' '|')
  [ -n "$vre" ] || return 0
  inc=""
  for _e in $ORC_SITE_EXTENSIONS; do inc="$inc --include=*.$_e"; done
  unset _e
  # shellcheck disable=SC2086  # inc is a deliberately word-split list of globs
  grep -rIlE "($vre)|($key)" $inc \
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      --exclude-dir=spec --exclude-dir=test --exclude-dir=tmp --exclude-dir=migrate \
      "$path" 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$path"/}
    [ "$rel" != "$decl" ] || continue
    named=$(grep -oIE "(^|[^A-Za-z0-9_])($vre)([^A-Za-z0-9_]|\$)" "$f" 2>/dev/null \
      | grep -oE "($vre)" | sort -u | grep -c . | tr -d ' ')
    if [ "${named:-0}" -ge 2 ]; then printf '%s\n' "$rel"; continue; fi
    if grep -qIE "($ORC_ENUM_GROUPING_VERBS)[[:space:]]*[({]?[[:space:]]*:?\"?'?$key" "$f" 2>/dev/null; then
      printf '%s\n' "$rel"
    fi
  done
}

# The nouns this system uses for itself. A place named after one of them is not
# a place a reporter has a word for, so it never reaches a question - the same
# bar bin/orc-check.sh scans the whole comment against, applied before the
# sentence is built rather than after.
ORC_JARGON_WORD='(^| )(bundles?|concepts?|repository|repositories|commits?|branch|branches|prompts?|refiners?|verdicts?|subsystems?)( |$)'

# The subject of a file, as somebody who does not have the repository would name
# it: the filename's own words, minus the ones that describe a layer rather than
# a thing. app/reports/case_statistics.rb is "case statistics", and that is a
# phrase a reporter can be asked about.
#
# Empty when nothing survives - an `index.rb` is named after its position - and
# an empty subject is a site that is recorded and never asked about.
site_subject() {
  local base out
  base=$(printf '%s' "$1" | awk -F/ '{print $NF}' | sed -e 's/\.[A-Za-z0-9]*$//')
  # CamelCase before folding, or clinicOverview.ts becomes the one word
  # "clinicoverview" - which is not a phrase anybody would say.
  out=$(printf '%s' "$base" | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g' \
    | tr '_-' '  ' | _terms_fold | awk '{
    o = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^(app|src|lib|models?|concerns?|serializers?|views?|controllers?|helpers?|jobs?|services?|queries|query|base|index|show|new|edit|application|record)$/) continue
      o = (o == "" ? $i : o " " $i)
    }
    print o
  }')
  [ -n "$out" ] || return 0
  printf '%s' "$out" | grep -qiE "$ORC_JARGON_WORD" && return 0
  printf '%s' "$out"
}

# The candidate members a ticket names that a set does not have.
#
# One pass over the folded ticket, looking at every occurrence of the set's head
# noun. An occurrence whose preceding words spell one of the set's own members is
# that member being talked about, and contributes nothing - which is also what
# stops the "visit" in "first-visit cases" being read as a member the code lacks.
# Anything else in front of the head is a candidate: one or two words, no
# function word at either end, nothing shorter than three characters.
#
# Said twice, or not at all. A phrase a ticket is introducing is a phrase it
# repeats; "a closed case" said once in passing is not a new kind of case, and
# without this floor it would be one. That is the single filter that decides
# whether this finding is worth a reporter's round trip.
_integration_candidates() {
  awk -v head="$2" -v vals="$3" '
    BEGIN {
      nv = split(vals, V, ";")
      split("the a an this that these those each every any all one two both new existing per of and or for in on at to is are be being was were with from by no not its their his her our your as if then than but so when while where which who whose what how why into onto out up down over under again also just still even only", S, " ")
      for (i in S) stop[S[i]] = 1
    }
    { for (i = 1; i <= NF; i++) w[++m] = $i }
    END {
      for (i = 1; i <= m; i++) {
        if (w[i] != head && w[i] != head "s" && w[i] != head "es") continue
        peer = 0
        for (len = 3; len >= 1; len--) {
          if (i - len < 1) continue
          p = ""
          for (j = i - len; j <= i - 1; j++) p = (p == "" ? w[j] : p " " w[j])
          for (v = 1; v <= nv; v++) if (V[v] == p) peer = 1
        }
        if (peer) continue
        for (len = 1; len <= 2; len++) {
          if (i - len < 1) continue
          q = ""; bad = 0
          for (j = i - len; j <= i - 1; j++) {
            if (length(w[j]) < 3) bad = 1
            q = (q == "" ? w[j] : q " " w[j])
          }
          if (bad) continue
          if (stop[w[i - len]] || stop[w[i - 1]]) continue
          if (q == head) continue
          skip = 0
          for (v = 1; v <= nv; v++) if (V[v] == q || V[v] == q " " head) skip = 1
          if (skip) continue
          seen[q]++
        }
      }
      for (q in seen) if (seen[q] >= 2) print seen[q] "\t" q
    }' <<< "$1" | sort -rn | cut -f2-
}

# The ticket's own spelling of a folded phrase, so a question quotes the reporter
# back rather than quoting the fold. "follow up case" folded came from
# "follow-up case", and the hyphen is theirs.
_original_spelling() {
  local re
  re=$(printf '%s' "$2" | sed 's/ /[^A-Za-z0-9]+/g')
  printf '%s' "$1" | grep -oiE "$re" | head -1
}

# integration_gaps <ticket text> <searchable name<TAB>path, one per line>
#
# One record per finding, most-enumerated set first:
#
#   set words \002 key \002 member \002 peers \002 site subject|repo|relpath;...
#
# \002 rather than a tab, because two of those five fields are legitimately
# empty on a recorded-but-unaskable finding and `IFS=$'\t' read` collapses a run
# of tabs, which here would put a repo name in the member field.
ORC_INTEGRATION_FS=$'\002'
ORC_INTEGRATION_SITE_CAP=3
ORC_INTEGRATION_FINDING_CAP=4
integration_gaps() {
  local text="$1" repos="$2" folded name path key values decl head words
  local peers member sites nsites v vf cand rec rel sub _n _p folded_values out=""
  folded=$(printf '%s' "$text" | _terms_fold)
  [ -n "$folded" ] || return 0
  while IFS=$'\t' read -r name path; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    while IFS=$'\t' read -r key values decl; do
      [ -n "$key" ] && [ -n "$values" ] || continue
      head=$(_set_head_noun "$key") || continue
      [ -n "$head" ] || continue
      words=$(_set_words "$key")

      # The set has to be the one the ticket is talking about, and a member it
      # already has is the only mechanical evidence of that. Without it, a
      # sentence sharing one noun with an unrelated enum would be a finding.
      peers=""
      while IFS= read -r v; do
        [ -n "$v" ] || continue
        vf=$(printf '%s' "$v" | _terms_fold)
        orc_folded_says "$folded" "$vf" && peers="$peers${peers:+,}$v"
      done <<< "$(printf '%s' "$values" | tr ',' '\n')"
      [ -n "$peers" ] || continue

      # Folded one at a time. _terms_fold turns a newline into a space like any
      # other separator, so folding the list in one pass produced a single value
      # nothing could ever match - and with no value matching, a member the set
      # already had read as one it lacked.
      folded_values=""
      while IFS= read -r v; do
        [ -n "$v" ] || continue
        folded_values="$folded_values$(printf '%s' "$v" | _terms_fold);"
      done <<< "$(printf '%s' "$values" | tr ',' '\n')"
      cand=$(_integration_candidates "$folded" "$head" "$folded_values")
      [ -n "$cand" ] || continue
      member=$(printf '%s' "$cand" | head -1)
      member=$(_original_spelling "$text" "$member $head")
      [ -n "$member" ] || continue

      # The places, across every repository this run was given, not only the one
      # the set is declared in: a dashboard that lists the same members is as
      # much affected work as the report that groups them.
      sites=""; nsites=0
      while IFS=$'\t' read -r _n _p; do
        [ -n "$_p" ] && [ -d "$_p" ] || continue
        while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          sub=$(site_subject "$rel") || continue
          [ -n "$sub" ] || continue
          # Test four of the question bar, done mechanically: a place the ticket
          # already names is not a place it forgot. This is the property the
          # real miss had - the word for the report was nowhere in five thousand
          # characters of description.
          orc_folded_says "$folded" "$sub" && continue
          case ";$sites" in *";$sub|"*) continue ;; esac
          nsites=$((nsites + 1))
          [ "$nsites" -le "$ORC_INTEGRATION_SITE_CAP" ] || continue
          sites="$sites${sites:+;}$sub|$_n|$rel"
        done <<< "$(enumeration_sites "$_p" "$key" "$values" \
                     "$(if [ "$_p" = "$path" ]; then printf '%s' "$decl"; fi)")"
      done <<< "$repos"
      [ -n "$sites" ] || continue

      rec="$words$ORC_INTEGRATION_FS$key$ORC_INTEGRATION_FS$member$ORC_INTEGRATION_FS$peers$ORC_INTEGRATION_FS$sites"
      out="$out$nsites	$rec
"
    done <<< "$(enum_sets_of "$path")"
  done <<< "$repos"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | grep -v '^$' | sort -rn | cut -f2- | head -"$ORC_INTEGRATION_FINDING_CAP"
}

# The places one finding names, as a reader would say them.
_site_list() {
  local out="" n=0 total sub
  total=$(printf '%s' "$1" | tr ';' '\n' | grep -c . | tr -d ' ')
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    sub=${s%%|*}
    n=$((n + 1))
    if [ "$n" = 1 ]; then out="the $sub"
    elif [ "$n" = "$total" ]; then out="$out and the $sub"
    else out="$out, the $sub"
    fi
  done <<< "$(printf '%s' "$1" | tr ';' '\n')"
  printf '%s' "$out"
}

# integration_question <one finding record>
#
# One sentence, the product's own words, answerable in a line, and the answer is
# a whole piece of work rather than a detail - which is tests one to three of the
# question bar. Test four is the site filter above.
#
# It asks whether the new member belongs where the existing ones already are. It
# does not assert that it does: that is a product decision, and the places are
# named so the person answering knows what they are deciding about.
integration_question() {
  local words member sites
  IFS="$ORC_INTEGRATION_FS" read -r words _key member _peers sites <<< "$1"
  printf 'This ticket adds "%s" as a new %s, and every %s is already listed in %s - should this one be listed there too?' \
    "$member" "$words" "$words" "$(_site_list "$sites")"
}

# The words that say a question is about where a set's members are gathered
# together.
#
# A closed list, and a deliberately short one, because the two ways of being
# wrong here do not cost the same. A wrong yes drops a real question, which is
# the exact failure this whole finding exists to fix; a wrong no puts a second
# similar question on one comment, which a reader notices and forgives. So the
# list holds only words about gathering members up - counting, grouping,
# reporting, exporting - and none of the generic ones it started with: "listed",
# "shown" and "appear" all fire on "should it be listed on the case list", which
# is a question about one screen and not about the set at all.
ORC_ENUMERATION_ASK_WORDS='counted|count|counts|grouped|group|groups|statistics|figures|totals|total|breakdown|export|exports|exported|reported|report|reports|aggregated|tallied|summary'

# integration_to_ask <findings> <questions already asked, one per line>
#
# The one finding that becomes a question, or nothing.
#
# One, because two of these are two questions and the sites are the payload of
# each: a single sentence naming two different sets is not answerable in a line.
# The rest stay in the record, which is where a report reads them.
#
# A finding the refiner already asked about is dropped. The prompt asks it to go
# looking for this itself, and its question is the better one when it fires - it
# can say what the new member is for, where this one can only say where the
# existing ones already are - so asking again underneath would be the same
# question twice on one comment.
#
# Already asked means the refiner's own questions name the member and say what is
# done with the set: not the site subject by name, because the refiner will name
# the place in the product's words rather than in the filename's - "the clinic's
# monthly figures" is the case statistics, and a comparison on the subject would
# have missed it and asked again underneath.
integration_to_ask() {
  local asked rec member
  asked=" $(printf '%s' "$2" | _terms_fold) "
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    member=$(printf '%s' "$rec" | cut -d"$ORC_INTEGRATION_FS" -f3)
    if orc_folded_says "$asked" "$(printf '%s' "$member" | _terms_fold)" \
       && printf '%s' "$asked" | grep -qE "(^| )($ORC_ENUMERATION_ASK_WORDS)( |$)"; then
      continue
    fi
    printf '%s\n' "$rec"
    return 0
  done <<< "$1"
}

# integration_site_lines <findings>
#
# One line per place, for the fold on a ready comment. It names the repository
# and the path, because the audience there is an implementing agent and a path is
# what it came for, and it says which set the place enumerates and which member
# is the new one - so the line can be checked rather than believed.
integration_site_lines() {
  local rec words member sites s
  printf '%s\n' "$1" | grep -v '^$' | while IFS= read -r rec; do
    IFS="$ORC_INTEGRATION_FS" read -r words _key member _peers sites <<< "$rec"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      printf '%s %s - enumerates every %s, and "%s" would be a new one\n' \
        "$(printf '%s' "$s" | cut -d'|' -f2)" \
        "$(printf '%s' "$s" | cut -d'|' -f3)" \
        "$words" "$member"
    done <<< "$(printf '%s' "$sites" | tr ';' '\n')"
  done
}

# integration_gaps_json <findings>
#
# The findings as the verdict record carries them. Recorded on every verdict,
# whether or not one of them was asked about, for the same reason the off-ticket
# discount is: what a later report wants to know is whether this was found at
# all, and a finding that was found and not asked is a different fact from one
# that was never found.
integration_gaps_json() {
  local rec words key member peers sites
  printf '%s\n' "$1" | grep -v '^$' | while IFS= read -r rec; do
    IFS="$ORC_INTEGRATION_FS" read -r words key member peers sites <<< "$rec"
    jq -nc --arg s "$words" --arg k "$key" --arg m "$member" \
      --arg p "$peers" --arg si "$sites" '{
        set: $s, key: $k, member: $m,
        peers: ($p | split(",") | map(select(length > 0))),
        sites: ($si | split(";") | map(select(length > 0)) | map(split("|"))
                | map({subject: .[0], project: .[1], path: .[2]}))
      }'
  done | jq -sc .
}

# --- the gap record ---------------------------------------------------------
#
# `terms_unresolved` is written to state/ and to nowhere else, and state/ is a
# cache. Every other thing in there is rebuilt by bin/orc-reconcile.sh out of the
# comments on the tickets; this one cannot be, because a refinement comment
# deliberately carries no term list - a reporter asked to read a list of words an
# agent could not look up stops reading these comments.
#
# So the gap is re-derivable only by refining the ticket again, which costs an
# agent call and answers under whatever prompt is current rather than the one
# that produced the observation. That is not history, and a loop that ranks a
# gap across months of runs needs history.
#
# Hence a ledger, and hence a ledger that is not in state/: one append-only line
# per (ticket, prompt version), written by bin/orc-gap-loop.sh and by nothing
# else, outside the two directories a reset clears. It is the only copy of what
# it holds, which is why it is not left in a gitignored directory.
#
# Both halves of the answer are true and both matter: the ledger is what makes
# *earlier* runs survive a reset, and it can only hold what somebody ran the loop
# to capture - so the loop still has to run before the cache is cleared. That is
# why bin/orc-reset.sh counts what state/ holds that the ledger does not, and
# says so before it removes anything.
#
# Environment only, like ORC_STATE_DIR: a test run must be able to point at its
# own ledger without config/.env having a say.
GAP_LEDGER="${ORC_GAP_LEDGER:-$ORC_ROOT/data/gaps.jsonl}"

# key<TAB>prompt version, one line per observation the ledger already holds.
#
# Read line by line with fromjson? rather than as a stream, so one truncated line
# - a run killed mid-append - costs that line and not the whole ledger.
gap_ledger_pairs() {
  [ -f "$GAP_LEDGER" ] || return 0
  jq -rR 'fromjson? | select(type == "object") | select((.key // "") != "")
          | "\(.key)\t\(if (.prompt_version // "") == "" then "-" else .prompt_version end)"' \
     "$GAP_LEDGER" 2>/dev/null
}

# key<TAB>prompt version<TAB>file, one line per verdict record state/ holds.
gap_state_verdicts() {
  local f key pv
  for f in "$STATE_DIR"/*.verdict.json; do
    [ -e "$f" ] || continue
    key=$(jq -r '.key // ""' "$f" 2>/dev/null)
    [ -n "$key" ] || continue
    # Never empty. A tab-separated record whose middle field can be empty is
    # read by `IFS=$'\t' read` with every later field shifted one to the left,
    # because a run of tabs is collapsed, which here would put a file path in
    # the prompt-version column.
    pv=$(jq -r 'if (.prompt_version // "") == "" then "-" else .prompt_version end' "$f" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$key" "$pv" "$f"
  done
}

# The verdict records in state/ the ledger has never seen: exactly what clearing
# the cache would take with it, and the reason bin/orc-reset.sh says so out loud.
gap_unrecorded() {
  local pairs key pv f
  pairs=$(gap_ledger_pairs)
  while IFS=$'\t' read -r key pv f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$pairs" | grep -qxF "$(printf '%s\t%s' "$key" "$pv")" && continue
    printf '%s\t%s\t%s\n' "$key" "$pv" "$f"
  done <<< "$(gap_state_verdicts)"
}

# One verdict record, as the one line the ledger keeps of it. Deliberately not
# the whole verdict: what a gap loop ranks is the unresolved half, the run it
# came from and how that run localised, and a ledger that copied the file would
# be a second cache rather than a record.
gap_observation() {
  jq -c --arg at "$(orc_now)" '{
    key: (.key // ""),
    prompt_version: (.prompt_version // ""),
    verdict: (.verdict // ""),
    locality_basis: (.locality_basis // "none"),
    recorded_at: $at,
    terms_unresolved: [ (.terms_unresolved // [])[] | tostring ]
  }' "$1"
}

# --- what a person signed ---------------------------------------------------
#
# The bundle's whole knowledge model rests on one act: somebody reads a fact and
# says it is true. Until this existed that act meant opening a markdown file,
# understanding OKF frontmatter and hand-editing a block, which made the one
# step every other step depends on the hardest one in the system.
#
# Two granularities, because there are two kinds of file and one rule does not
# fit both.
#
#   A concept file is verified whole, exactly as it always was: a `verified:`
#   block in its frontmatter, and bin/orc-okf-draft.sh then refuses to re-draft
#   it. That works because the file is re-rendered from the repositories, so
#   freezing it is the intended meaning of signing it.
#
#   An accumulating file cannot be signed whole. domain/open-vocabulary.md and
#   domain/reporter-answers.md grow a row every time a ticket is refined or a
#   reporter answers, so a `verified:` date on either would freeze the one file
#   in the bundle whose whole purpose is to keep growing - and the drafter would
#   report it SKIPPED forever while real answers piled up outside it.
#
# So a fact inside an accumulating file is verified by *promotion*: agreeing
# moves it into a file the drafter never writes at all. That is what keeps the
# drafter's no-overwrite guarantee a simple whole-file rule instead of teaching
# it to merge a human's rows into a machine's table - which is the one shape
# that would put a machine and a person editing the same file.
ORC_ACCUMULATING_VOCAB="domain/open-vocabulary.md"
ORC_ACCUMULATING_ANSWERS="domain/reporter-answers.md"
# shellcheck disable=SC2034  # read by bin/orc-verify.sh, which sources this
ORC_ACCUMULATING_CONCEPTS="$ORC_ACCUMULATING_VOCAB $ORC_ACCUMULATING_ANSWERS"

# The two files promotion writes into. Human-owned in the sense that matters:
# bin/orc-okf-draft.sh never names them, so its refusal to overwrite a verified
# concept is not what protects them - nothing writes them but the promotion.
# shellcheck disable=SC2034  # read by bin/orc-verify.sh, which sources this
ORC_VERIFIED_ANSWERS="domain/verified-answers.md"
# shellcheck disable=SC2034  # read by bin/orc-verify.sh, which sources this
ORC_VERIFIED_VOCABULARY="domain/verified-vocabulary.md"

# One append-only line per decision a person made, outside the caches for the
# same reason data/gaps.jsonl is: a human's judgement is the one thing in this
# system that nothing can re-derive. Refining again re-reads the tickets and
# drafting again re-reads the repositories; nothing re-reads somebody's opinion.
#
# It holds refusals as well as agreements, and the refusals are the half that
# has no other home: an agreement leaves a promoted row behind, while a refusal
# leaves nothing at all, and without a record of it the harvest would propose
# the identical answer on every run forever.
#
# The newest line for a subject wins. That is what makes a decision reversible
# without the file ever being rewritten: deciding again appends, and the reader
# takes the last one.
#
# Environment only, like ORC_STATE_DIR and ORC_GAP_LEDGER: a test run must be
# able to point at its own ledger without config/.env having a say.
VERIFY_LEDGER="${ORC_VERIFY_LEDGER:-$ORC_ROOT/data/verifications.jsonl}"

# The identity of one reviewable thing, stable across runs.
#
# Three parts, because two of them are not always both meaningful. The kind and
# the subject say what is being decided; the proposal fold says *which* proposal
# about that subject, and it is deliberately empty for a word - refusing a word
# is a judgement about the word rather than about the sentence the evidence
# currently produces for it, so a re-drafted sentence must not bring it back.
# For an answer it carries, because a different answer to the same question is a
# new proposal and has to be offered again.
decision_id() {
  content_hash "$1|$2|$3" | cut -c1-8
}

# The subject of an answer decision: the ticket it was asked on, and the
# question folded so that a re-asked question spelled with different
# punctuation is still the same question.
answer_subject_key() {
  printf '%s %s' "$1" "$(printf '%s' "$2" | _terms_fold)"
}

# decision_for <kind> <subject key> <proposal fold>
#
# `agree`, `reject`, or nothing. The last matching line wins, so deciding again
# overrules an earlier decision and nothing has to be rewritten.
#
# A recorded decision with an empty proposal fold matches any proposal about
# that subject: that is the word case above, spelled once here rather than as a
# branch in each of the three callers.
#
# Read line by line with fromjson? rather than as a stream, so one truncated
# line - a run killed mid-append - costs that line and not the whole ledger.
decision_for() {
  [ -f "$VERIFY_LEDGER" ] || return 0
  jq -rR --arg k "$1" --arg s "$2" --arg p "$3" '
    fromjson? | select(type == "object")
    | select((.kind // "") == $k and (.subject_key // "") == $s)
    | select((.proposal_fold // "") == "" or (.proposal_fold // "") == $p)
    | (.decision // "") | select(length > 0)' "$VERIFY_LEDGER" 2>/dev/null | tail -1
}

# The concepts a human has signed, as concept<TAB>folded text.
#
# Shared, because two passes ask the same question of the same files for
# opposite reasons: the harvest asks whether a signed concept already says a
# word refinement had to ask a person about, and the review asks what the
# bundle already claims about the fact somebody is being asked to sign. Two
# implementations would eventually disagree about one concept, and then one of
# those two answers would be silently wrong.
bundle_verified_folded() {
  local dir="$1" f rel
  [ -d "$dir" ] || return 0
  find "$dir" -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel=${f#"$dir"/}
    case "$rel" in index.md|*/index.md) continue ;; esac
    concept_is_verified "$f" || continue
    printf '%s\t%s\n' "$rel" "$(_terms_fold < "$f")"
  done
}

# --- a new answer checked against what is already settled on the same card ---
#
# Nothing checked a fresh answer against the ticket's own description or
# against an answer already signed on the same ticket. A contradiction is worse
# than a gap: an open question announces itself, and a contradiction hides
# inside something that now looks resolved - the whole chain shipped this week
# (split gating, the terminal signal, the rewritten description, the
# adversarial re-read) treats a signed answer as settled, and none of it has
# ever checked that "signed" and "true" are the same thing.
#
# "Does this new fact conflict with that other text" is an open question in
# general - a categorical disagreement, a negation, a mutually exclusive
# choice, an incompatible date - and reading that mechanically is not what a
# derived check of this project's own kind can do; the derived checks this
# project has proven (verdict_split_ready, integration_gaps, terms_off_to_ask)
# all read a closed-form fact off structured data, not free prose. So this is
# scoped to the one shape of disagreement that is both mechanical and the
# paradigm case the task itself names: two different numbers about what reads
# as the same subject. "19 euros" against "25 euros" for the rush fee is
# exactly that; "cash only" against "cards too" is not, and this does not catch
# it. That is a real and named gap rather than a claim of full contradiction
# detection, and it is the same trade the deferral check above makes: caught
# mechanically where the evidence is literal, surfaced to a human rather than
# silently trusted everywhere else.

# The first number in a folded string, or nothing. Folding strips the decimal
# point along with every other non-alphanumeric character, so "19.5" already
# reads as two tokens and only the first is read - a known and stated gap
# rather than an attempt at parsing a real number.
_leading_number() {
  printf '%s' "$1" | _terms_fold | grep -oE '[0-9]+' | head -1
}

# answer_contradicts_text <question> <new answer> <comparison text>
#
# The sentence inside <comparison text> that states a different number from
# <new answer> for what looks like the same subject as <question> - sharing at
# least two content words with it, the same bar bin/orc-harvest.sh's own
# read_for_meaning uses to attribute a reply to a question in the first place.
# Prints that sentence and returns 0 when found; nothing and 1 otherwise.
#
# Gated on the new answer naming a number at all: an answer with nothing
# numeric in it is not compared, because there is nothing here to disagree
# about mechanically.
answer_contradicts_text() {
  local question="$1" answer="$2" text="$3" qfold anum
  qfold=$(printf '%s' "$question" | _terms_fold)
  anum=$(_leading_number "$answer")
  [ -n "$qfold" ] && [ -n "$anum" ] || return 1
  printf '%s' "$text" | awk -v q="$qfold" -v anum="$anum" '
    function fold(s,    t) {
      t = tolower(s)
      gsub(/[^a-z0-9]/, " ", t)
      gsub(/  +/, " ", t)
      sub(/^ /, "", t); sub(/ $/, "", t)
      return t
    }
    { body = body $0 " " }
    END {
      nq = split(q, qw, " ")
      n = split(body, sentences, /[.!?]+ */)
      for (i = 1; i <= n; i++) {
        s = sentences[i]
        gsub(/^ +| +$/, "", s)
        if (s == "") continue
        sf = fold(s)
        if (match(sf, /[0-9]+/) == 0) continue
        snum = substr(sf, RSTART, RLENGTH)
        if (snum == anum) continue
        nsf = split(sf, sw, " ")
        c = 0
        for (a = 1; a <= nq; a++) {
          if (length(qw[a]) <= 2) continue
          for (b = 1; b <= nsf; b++) { if (qw[a] == sw[b]) { c++; break } }
        }
        if (c >= 2) { print s; exit }
      }
    }'
}

# The text of every answer somebody has already signed for one ticket, the
# newest decision per subject winning the same way bin/orc-verify.sh's own
# render does - so a decision since taken back is not still read as settled
# here. Ticket-scoped rather than project-wide: two different cards can
# legitimately give two different answers to what reads as the same question,
# and that is not a contradiction.
verified_answer_texts_for_ticket() {
  local key="$1"
  [ -f "$VERIFY_LEDGER" ] || return 0
  jq -rsR --arg k "$key" '
    [ splits("\n") | select(length > 0) | fromjson? | select(type == "object") ]
    | map(select((.kind // "") == "answer" and (.ticket // "") == $k))
    | group_by((.subject_key // "") + "|" + (.proposal_fold // ""))
    | map(last)
    | map(select((.decision // "") == "agree"))
    | .[] | (.text // .proposal // "")' "$VERIFY_LEDGER" 2>/dev/null
}

# answer_contradiction <ticket key> <question> <new answer>
#
# A noun phrase naming what the new answer disagrees with - the ticket's own
# description first, then every answer already signed on this ticket - or
# nothing. A phrase rather than a sentence, so every caller can compose it into
# its own sentence ("this conflicts with ...", "disagrees with ...") without the
# result reading as two sentences stitched together.
#
# $DESCRIPTION_TEXT is read from the caller's environment rather than passed as
# a fourth positional argument, because every caller in bin/orc-harvest.sh
# already holds the ticket's description once per ticket and passing it through
# every call site that leads here would be plumbing for its own sake.
answer_contradiction() {
  local key="$1" q="$2" answer="$3" found prior
  found=$(answer_contradicts_text "$q" "$answer" "${DESCRIPTION_TEXT:-}")
  if [ -n "$found" ]; then
    printf 'the ticket'"'"'s own description, which says: "%s"' "$found"
    return 0
  fi
  while IFS= read -r prior; do
    [ -n "$prior" ] || continue
    found=$(answer_contradicts_text "$q" "$answer" "$prior")
    if [ -n "$found" ]; then
      printf 'an answer already signed on this ticket, which says: "%s"' "$found"
      return 0
    fi
  done <<< "$(verified_answer_texts_for_ticket "$key")"
  return 1
}

# --- a ticket that contradicts what the code already does -------------------
#
# Every question source in this system so far filters what the refiner already
# thought of; none of it ever added a question from what it read in the
# repositories. The question bar's central rule is "anything answerable by
# reading the code, you answer yourself, and you never ask" - which is right
# for a gap, but a ticket can also describe behaviour the code already
# contradicts, and reading around that silently is not the same as answering
# it. Refining a ticket by hand starts with reading the logic; this is that
# step, mechanised the same way integration_gaps is - a real, evidence-based
# finding, not a prompt asked to "notice this and ask about it" on its own. The
# prompt-only version of that instruction has shipped twice without proving
# itself, while every derived check beside it worked.
#
# The mechanical evidence is a database check constraint: `db/schema.rb`
# already states a small number of its lines as rules rather than layout
# (bin/orc-okf-draft.sh's own SCHEMA_RULES_AWK reads the same fact for a
# different purpose), and a numeric one - `"count <= 3"` - is a rule with a
# number in it that a ticket can straightforwardly disagree with. That is
# exactly the shape answer_contradicts_text was built for: two different
# numbers about what reads as the same subject. So it is reused rather than
# reimplemented, with the constraint's own column and table standing in for
# the "new answer" side and the ticket's prose standing in for the comparison
# text - two spellings of "do these numbers disagree" would eventually
# disagree about what counts, the same reason the deferral and description
# checks above reuse rather than duplicate.
#
# Scoped to a single binary comparison against a literal integer, the same way
# _integration_candidates and _leading_number are scoped rather than general:
# a `BETWEEN`, an `AND`-joined constraint or a non-numeric check is not
# parsed, and that is a real and named gap rather than an attempt at reading
# arbitrary SQL.

# schema_numeric_rules <repository path>
#
# table<TAB>column<TAB>op<TAB>number, one line per check constraint in
# db/schema.rb that is a simple `<column> <op> <integer>` comparison. The
# reversed spelling (`3 >= count`) is not matched: Rails migrations write the
# column first, and a rule nobody writes is not worth the second branch.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_SCHEMA_NUMERIC_RULE_AWK='
/^  create_table "/ { t = $0; sub(/^  create_table "/, "", t); sub(/".*$/, "", t); next }
/^    t\.check_constraint / {
  c = $0
  sub(/^[[:space:]]*t\.check_constraint "/, "", c)
  sub(/", name:.*$/, "", c)
  sub(/"$/, "", c)
  gsub(/[\\"]/, "", c)
  gsub(/^\(+|\)+$/, "", c)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
  if (match(c, /^[a-z_][a-z0-9_]*[[:space:]]*(<=|>=|<|>|=)[[:space:]]*[0-9]+$/)) {
    rest = c
    if (match(rest, /(<=|>=|<|>|=)/)) {
      op = substr(rest, RSTART, RLENGTH)
      col = substr(rest, 1, RSTART - 1); gsub(/[[:space:]]+$/, "", col)
      num = substr(rest, RSTART + RLENGTH); gsub(/[[:space:]]+/, "", num)
      print t "\t" col "\t" op "\t" num
    }
  }
  next
}'
schema_numeric_rules() {
  local p="$1"
  [ -f "$p/db/schema.rb" ] || return 0
  awk "$ORC_SCHEMA_NUMERIC_RULE_AWK" "$p/db/schema.rb"
}

# The product phrase for a table-and-column pair: the table's own head noun,
# singular, followed by the column's words. "clinics" and
# "monthly_second_opinion_count" become "clinic monthly second opinion count" -
# a thing a depot manager can be asked about, and neither identifier is.
_contradiction_subject() {
  local words last rest singular
  words=$(printf '%s' "$1" | tr '_' ' ' | _terms_fold)
  last=$(_singular "${words##* }")
  rest=${words% *}
  [ "$rest" = "$words" ] && rest=""
  singular="${rest:+$rest }$last"
  printf '%s %s' "$singular" "$(printf '%s' "$2" | tr '_' ' ' | _terms_fold)"
}

# The comparison a check constraint's operator reads as in a sentence.
_contradiction_opword() {
  case "$1" in
    '<=') printf 'at most' ;;
    '>=') printf 'at least' ;;
    '<')  printf 'under' ;;
    '>')  printf 'over' ;;
    *)    printf 'exactly' ;;
  esac
}

# code_contradictions <ticket text> <searchable name<TAB>path, one per line>
#
# One record per finding, project<TAB>table<TAB>column<TAB>op<TAB>code's
# number<TAB>the ticket's own sentence stating a different one - as many as
# ORC_CONTRADICTION_CAP, most-specific evidence first is not meaningful here
# the way it is for an enum, so the order is simply the order the repositories
# and their schemas were given in.
ORC_CONTRADICTION_FS=$'\002'
ORC_CONTRADICTION_CAP=3
code_contradictions() {
  local text="$1" repos="$2" name path table col op num subject found out=""
  while IFS=$'\t' read -r name path; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    while IFS=$'\t' read -r table col op num; do
      [ -n "$table" ] && [ -n "$col" ] && [ -n "$num" ] || continue
      subject=$(_contradiction_subject "$table" "$col")
      found=$(answer_contradicts_text "$subject" "$num" "$text")
      [ -n "$found" ] || continue
      out="$out$name$ORC_CONTRADICTION_FS$table$ORC_CONTRADICTION_FS$col$ORC_CONTRADICTION_FS$op$ORC_CONTRADICTION_FS$num$ORC_CONTRADICTION_FS$found
"
    done <<< "$(schema_numeric_rules "$path")"
  done <<< "$repos"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | grep -v '^$' | head -"$ORC_CONTRADICTION_CAP"
}

# True when the folded text $3 names the number $2 and shares at least two
# content words (longer than two characters) with the subject phrase $1 - the
# same overlap bar answer_contradicts_text and bin/orc-harvest.sh's own
# read_for_meaning both use to decide two things are about the same subject.
# Not a whole-phrase match the way integration_to_ask's "member" check is,
# because a subject built by concatenating a table and a column - "clinic
# monthly second opinion count" - is not a phrase a refiner asking about the
# same rule would ever spell verbatim; the overlap bar is what the rest of
# this codebase reaches for when the phrasing is expected to differ.
_contradiction_already_asked() {
  local subject="$1" num="$2" asked="$3"
  case " $asked " in *" $num "*) : ;; *) return 1 ;; esac
  awk -v s="$subject" -v t="$asked" 'BEGIN {
    ns = split(s, sw, " "); nt = split(t, tw, " "); c = 0
    for (a = 1; a <= ns; a++) {
      if (length(sw[a]) <= 2) continue
      for (b = 1; b <= nt; b++) { if (sw[a] == tw[b]) { c++; break } }
    }
    exit !(c >= 2)
  }'
}

# code_contradiction_to_ask <findings> <questions already asked, one per line>
#
# The one finding that becomes a question, or nothing - the same one-per-round
# rule integration_to_ask follows, and for the same reason: the two numbers are
# the payload, and a sentence naming two different rules is not answerable in a
# line.
#
# A finding already named by the refiner's own questions is dropped: see
# _contradiction_already_asked above for what "named" means here.
code_contradiction_to_ask() {
  local asked rec table col num subject
  asked=$(printf '%s' "$2" | _terms_fold)
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS="$ORC_CONTRADICTION_FS" read -r _n table col _op num _f <<< "$rec"
    subject=$(_contradiction_subject "$table" "$col")
    _contradiction_already_asked "$subject" "$num" "$asked" && continue
    printf '%s\n' "$rec"
    return 0
  done <<< "$1"
}

# code_contradiction_question <one finding record>
#
# One sentence, in the product's own words: what the code already enforces,
# against the number the ticket names for what reads as the same subject. It
# does not accuse the ticket of being wrong - the ticket may be the one asking
# for the limit to change - so it asks rather than states.
code_contradiction_question() {
  local table col op num found subject opword ticket_num
  IFS="$ORC_CONTRADICTION_FS" read -r _n table col op num found <<< "$1"
  subject=$(_contradiction_subject "$table" "$col")
  opword=$(_contradiction_opword "$op")
  ticket_num=$(_leading_number "$found")
  printf 'The ticket describes %s as %s %s, but the existing logic already enforces %s %s - did you mean to change that, or should the ticket describe what happens today?' \
    "$subject" "$opword" "${ticket_num:-a different number}" "$opword" "$num"
}

# code_contradictions_json <findings>
#
# Recorded on every verdict, whether or not one of them was asked about, for
# the same reason integration_gaps_json is: a finding that was found and not
# asked is a different fact from one that was never found.
code_contradictions_json() {
  local rec name table col op num found
  printf '%s\n' "$1" | grep -v '^$' | while IFS= read -r rec; do
    IFS="$ORC_CONTRADICTION_FS" read -r name table col op num found <<< "$rec"
    jq -nc --arg r "$name" --arg t "$table" --arg c "$col" --arg o "$op" \
      --arg n "$num" --arg f "$found" \
      '{project: $r, table: $t, column: $c, op: $o, code_value: $n, ticket_text: $f}'
  done | jq -sc .
}

# --- the ticket's own copy, and whether the rewrite kept it ------------------
#
# `rewritten_description` paraphrases a specification, which is the point of
# it, and it will paraphrase the ticket's user-facing copy as well. On a card
# whose description states a dozen exact strings - button labels, push titles, a
# warning, two status wordings - almost none of them survive, and the ones that
# do survive because a reporter had answered with them. A rewrite offered "to
# copy across" that reads beautifully and has turned the banner
# "Heads up: this booking is a follow-on!" into "a warning before the return is
# started" has destroyed the one part of the ticket an implementer has to
# reproduce character for character.
#
# The prompt carries half of the fix and this carries the other, which is this
# project's repeated measured finding about which of the two is the strong
# lever: a prompt-side "notice this" instruction has shipped twice saying
# plainly that its own fixture never reproduced the miss, while every derived
# check beside it worked and was proved end to end. So the strings are
# extracted from the ticket mechanically and their absence from the rewrite is
# reported, in the same style as terms_off_ticket, integration_gaps and
# code_contradictions - derived rather than asked of the refiner as a field,
# because this run holds the ticket's own text and a self-declared "I kept the
# copy" can disagree with it while a derived one structurally cannot.
#
# Two sources, and both are narrow on purpose.
#
# A quoted span is the reliable one: a reporter putting quotation marks round
# something is the plainest mechanical signal there is that the characters
# rather than the meaning are what matters.
#
# A run of text in a language the ticket is not written in is the second, and
# it is gated rather than trusted, because a description written in that
# language would otherwise nominate its own prose. Copy in a *minority*
# language is copy; a language most of the description's sentences are in is
# the ticket's own, and its sentences are prose. That gate is what keeps this
# safe on a card written in the language of its own copy: its foreign runs are
# its prose and only its quoted spans are read - and it is also the named
# bound: an unquoted UI string in the ticket's own language
# is invisible here, the same shape of gap schema_numeric_rules has for a
# BETWEEN.
#
# It reports and never repairs. The refiner's own text reaches the record and
# the comment exactly as it wrote it; what travels beside it is which strings
# went missing. Whether that withholds the rewrite is bin/orc-refine.sh's
# decision and is argued there.

# One spelling of a quotation mark before the spans between them are read.
# Substituted one at a time rather than through a bracket expression, because a
# multibyte character inside `[...]` is a locale question and this is not one.
_verbatim_normalise_quotes() {
  sed -e 's/“/"/g' -e 's/”/"/g' -e 's/„/"/g' -e 's/‟/"/g' \
      -e 's/«/"/g' -e 's/»/"/g' -e 's/❝/"/g' -e 's/❞/"/g'
}

# The text between one pair of quotation marks, one span per line. Part i sits
# between quote i-1 and quote i, so a span is closed only while i is under the
# field count - which is how an apostrophe or a single stray quote contributes
# nothing rather than swallowing the rest of the line.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_VERBATIM_QUOTED_AWK='
{
  n = split($0, p, "\"")
  for (i = 2; i <= n - 1; i += 2) if (p[i] != "") print p[i]
}'

# The description as sentence-sized fragments, one per line, which is the unit
# the foreign-language gate below counts and the unit it emits.
#
# bin/orc-harvest.sh's own reading pass splits a reply on `[.!?]+`, and this
# splits on a colon and a semicolon as well - because a description writes its
# copy as "Push title: Your follow-on booking has been refunded", and a
# candidate carrying the label in front of the string would then be reported as
# dropped by a rewrite that quoted the string perfectly and introduced it
# differently. A quoted span is unaffected: it is read out before this runs, so
# "Heads up: this booking is a follow-on!" keeps its own colon.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_VERBATIM_FRAGMENT_AWK='
{
  s = $0
  gsub(/[.!?;:]+/, "\n", s)
  print s
}'

# The fragments holding a letter that is not an ASCII one, one per line - which
# is what "a run of text in another language" has to mean.
#
# Spelled as a byte question and not as a locale one, for the reason every other
# grep in this function pins LC_ALL=C: whichever locale the daemon was started
# from must not decide what the ticket says. In UTF-8 the lead byte of a
# multibyte sequence names the block it comes from, so the ranges are the whole
# rule. C3-DF is every two-byte letter - the Latin-1 letters, Latin Extended,
# Greek, Cyrillic, Hebrew, Arabic - and C2 below it is the two-byte symbols and
# punctuation, so it is out. E0-EF is the three-byte planes, which are letters
# except for E2: U+2000-U+2FFF is General Punctuation, currency, arrows and
# maths, and that one block is where every character that misled this lived.
#
# It cost the check its own evidence. `- new advantages (only 2 and new wording
# + pricing) → new packages` was nominated as a string a rewrite had to carry
# through character for character, on a real terminal round, because the arrow
# in it is a byte outside ASCII and the old test asked only that. So was any
# plain English sentence holding an em dash, a euro sign, a bullet or an
# ellipsis. A symbol says nothing about which language a sentence is in, and
# reading one as a language signal turned a specification bullet into copy - and
# then withheld the whole rewritten description over it.
#
# The named cost of the ranges is small and is the right way round: the few
# letter-shaped characters inside E2 - the ohm sign, the angstrom sign - are
# read as symbols, so a sentence whose only non-ASCII character is one of those
# is not nominated. That is the safe direction, because a string nominated
# wrongly withholds something and a string never nominated is only unchecked.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_VERBATIM_FOREIGN_AWK='
{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (c >= "\303" && c <= "\337") { print; next }
    if (c >= "\340" && c <= "\357" && c != "\342") { print; next }
  }
}'

# A candidate is at most this many words and at least this many characters, and
# a description contributes at most this many of them.
#
# Fifteen words, because copy is a label or a sentence and never a paragraph:
# past that the span is prose somebody quoted, and requiring a paragraph
# verbatim would withhold every rewrite of the ticket that held it. Four
# characters, the same floor bin/orc-gap-loop.sh's bar already uses. Twenty
# candidates, comfortably above what a copy-heavy card holds: the cap bounds the
# work rather than the finding, and it errs towards reading fewer strings,
# because a string this never looked at is the bug carrying on while a string
# wrongly required is a rewrite withheld that was fine.
ORC_VERBATIM_MAX_WORDS=15
ORC_VERBATIM_MIN_CHARS=4
ORC_VERBATIM_CAP=20

# A candidate opening with one of these is the description's own structure
# rather than a string, and one holding one of these is notation rather than a
# string. Both refuse a specification bullet without touching a quoted span,
# because a quotation mark opens inside the bullet that lists it: what reaches
# here from the quoted branch is the span between the marks, which carries
# neither the bullet in front of it nor the mapping arrow beside it.
# Spelled as an alternation rather than as a bracket expression, because a
# multibyte character inside `[...]` is a locale question and this is not one -
# the same reason _verbatim_normalise_quotes substitutes one mark at a time.
ORC_VERBATIM_LIST_MARKER='^(-|\*|\+|•|‣|▪|·|[0-9]{1,2}[.)])[[:space:]]'
ORC_VERBATIM_NOTATION='->|=>|→|⇒|⟶|⟹'

# The bars a candidate has to clear, printing the normalised span when it does.
#
# Code-shaped is refused, and that is what keeps this rule and the reporter bar
# from pulling against each other: a quoted `app/models/case.rb` or
# `monthly_second_opinion_count` is an identifier rather than copy, the
# rewritten description may not name one at all, and a check demanding it be
# carried through would be demanding the field fail its own scan. Same regex
# terms_off_ticket discounts a term by, for the same reason.
#
# A leading list marker and an arrow are refused for the same shape of reason
# one step out. Nothing a person has to reproduce character for character
# begins with the bullet that lists it, and nothing does its work through
# `->`: an arrow in a description means "becomes" or "leads to", which is a
# specification writing down a mapping. The line this whole task was found on
# is both at once, and a card writing its specification as bullets in more than
# one language would have kept producing the same false positive under the
# language rule alone - a bullet reading `- Status changes on return → follow-on`
# holds a letter outside ASCII as soon as one word in it is accented, and is no
# more copy than a plain ASCII one was.
#
# The cost is named rather than hidden, and it is the safe direction: an
# unquoted label written as a bare bullet in a language the ticket is not
# written in is no longer nominated. Quoting it puts it back, and a string that
# goes unchecked is the bug carrying on while a string wrongly required
# annotates a rewrite that was fine.
_verbatim_keep() {
  local s words
  s=$(printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ *//;s/ *$//')
  [ "${#s}" -ge "$ORC_VERBATIM_MIN_CHARS" ] || return 1
  printf '%s' "$s" | LC_ALL=C grep -q '[A-Za-z]' || return 1
  words=$(printf '%s' "$s" | wc -w | tr -d ' ')
  [ "$words" -le "$ORC_VERBATIM_MAX_WORDS" ] || return 1
  printf '%s' "$s" | grep -qE "$ORC_CODE_SHAPED_TERM" && return 1
  printf '%s' "$s" | grep -qE "$ORC_VERBATIM_LIST_MARKER" && return 1
  printf '%s' "$s" | grep -qE -e "$ORC_VERBATIM_NOTATION" && return 1
  printf '%s\n' "$s"
}

# ticket_verbatim_copy <description text>
#
# The strings a rewrite has to carry through unchanged, one per line, in the
# ticket's own spelling. The description alone rather than the summary beside
# it: what is being checked is the rewritten *description*, and a phrase quoted
# in a title is not something that field promised to hold.
#
# LC_ALL=C on both awks and both greps that ask about a byte, so "is there a
# character outside ASCII here" is a question about bytes rather than about
# whichever locale the daemon was started from - the same pin
# bin/orc-okf-draft.sh takes at the top of itself, for the same reason.
ticket_verbatim_copy() {
  local text quoted fragments foreign total n_foreign candidates line
  text=$(printf '%s' "$1" | _verbatim_normalise_quotes)
  quoted=$(printf '%s\n' "$text" | LC_ALL=C awk "$ORC_VERBATIM_QUOTED_AWK")
  fragments=$(printf '%s\n' "$text" | LC_ALL=C awk "$ORC_VERBATIM_FRAGMENT_AWK" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^[[:space:]]*$')
  total=$(printf '%s\n' "$fragments" | grep -c . || true)
  foreign=$(printf '%s\n' "$fragments" | LC_ALL=C awk "$ORC_VERBATIM_FOREIGN_AWK" || true)
  n_foreign=$(printf '%s\n' "$foreign" | grep -c . || true)
  candidates="$quoted"
  # No more than half. Over that, the language is the ticket's own and its
  # sentences are prose, not copy.
  if [ "$total" -gt 0 ] && [ "$(( n_foreign * 2 ))" -le "$total" ]; then
    candidates="$candidates
$foreign"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _verbatim_keep "$line" || true
  done <<< "$candidates" | awk '!seen[$0]++' | head -"$ORC_VERBATIM_CAP"
}

# rewrite_dropped <candidates, one per line> <rewritten description>
#
# The candidates the rewrite does not hold, one per line, in the ticket's own
# spelling - which is what a reader has to be shown, because the finding is
# that exactly those characters went missing.
#
# Compared folded, so a change of case or of surrounding punctuation is not a
# dropped string: the two sides go through _terms_fold and orc_folded_says like
# every other text comparison in this file, rather than through a second
# spelling of the same rule. A letter outside ASCII folds to a space on both
# sides, so an umlaut costs the comparison nothing while a translation - which
# changes the words - is exactly what it catches.
rewrite_dropped() {
  local folded cand cfold
  [ -n "$1" ] || return 0
  folded=$(printf '%s' "${2:-}" | _terms_fold)
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    cfold=$(printf '%s' "$cand" | _terms_fold)
    [ -n "$cfold" ] || continue
    orc_folded_says "$folded" "$cfold" && continue
    printf '%s\n' "$cand"
  done <<< "$1"
}

# --- the rewrite as a superset of the ticket, not a summary of it -------------
#
# The check above is about characters: a label, a warning, a status wording, the
# strings somebody has to reproduce exactly. This one is the layer over it, and
# it is about content. A rewrite also loses requirements that are plain unquoted
# English - a whole bullet asking for a second tab, a whole sentence saying what
# carries over from the previous rental - and nothing sees them go, because they
# are not quoted, not in another language, and so never nominated as copy. The field is meant to be the ticket's whole content with the answers
# folded in; what it produced was a good short summary of it, and a summary
# pasted over a description is a deletion of whatever it left out.
#
# So the description is segmented into statements and each one is asked whether
# the rewrite still says it. Derived here rather than asked of the refiner as a
# field, for the reason verdict_split_ready, terms_off_ticket, integration_gaps
# and rewrite_dropped are: this run holds the ticket's own text, so a
# self-declared "I kept everything" can disagree with it and a derived one
# structurally cannot.
#
# The unit is ORC_VERBATIM_FRAGMENT_AWK's own fragment rather than a `- ` bullet.
# A Jira description may be bullets, may be prose, or may mix the two, so a
# bullet is not a unit at all; splitting on `[.!?;:]` per line segments all three
# the same way. It is the splitter the copy check already uses, and two spellings
# of "what is a statement in this description" would eventually disagree about
# one - at which point one check would report a statement the other had never
# heard of.

# The words shared by every sentence in every language this reads. Folded out of
# both sides of any content comparison, because "the" and "was" would otherwise
# swamp a signal that is supposed to come from the words that are about
# something. One list, in one place: bin/orc-harvest.sh's reading pass scores a
# reply against a question by exactly this measure, and a second copy of the list
# would make two comparisons of the same kind disagree about what a content word
# is.
ORC_CONTENT_STOPWORDS="a an and are as at be been being but by can could did do does for from had has have how if in into is it its may might must no nor not of on or our out over own shall should so than that the their then there these they this those to too was we were what when where which who why will with would you your yours i me my us them he she his her him just only also still yet both either neither since once again"

# A statement is judged only when it has at least this many content words left
# after the stopwords and the description's own ubiquitous ones are taken out,
# and it counts as carried through when the rewrite holds at least this
# percentage of them.
#
# Two, because a fragment with one content word in it is a heading (`## App`) or
# a scrap, and "the rewrite does not say `app`" is not a finding. Fifty, because
# the two ways of being wrong here do not cost the same: a reworded survivor
# reported as lost is the failure that gets a check switched off within a week,
# and a rewrite legitimately merges two overlapping sentences and legitimately
# drops an ambiguity somebody has since resolved. So the bar leans towards
# missing a loss rather than towards inventing one, and half the words of a
# statement surviving somewhere in the rewrite is read as the statement
# surviving.
ORC_COVERAGE_MIN_WORDS=2
ORC_COVERAGE_SHARE=50

# The stem is the first this many characters, compared as a prefix in either
# direction, so an inflection is not a lost statement: "change" and "changed"
# and "changes" all stem to `change`, and "case" is a prefix of "cases". That is
# the same asymmetry orc_folded_says takes - a word boundary at the start and
# not at the end - widened to both sides, because here either side may be the
# inflected one.
ORC_COVERAGE_STEM=6

# shellcheck disable=SC2016  # an awk program, not a shell expansion
ORC_COVERAGE_AWK='
function keys(s,   t, n, i, arr, out) {
  t = tolower(s)
  gsub(/[^a-z0-9]/, " ", t)
  n = split(t, arr, " ")
  out = ""
  for (i = 1; i <= n; i++)
    if (length(arr[i]) >= 3 && !(arr[i] in sw)) out = out " " substr(arr[i], 1, stemlen)
  return out
}
function held(s,   h) {
  if (s in have) return 1
  for (h in have) {
    if (length(h) >= 4 && index(s, h) == 1) return 1
    if (length(s) >= 4 && index(h, s) == 1) return 1
  }
  return 0
}
BEGIN {
  n_sw = split(stop, swlist, " ")
  for (i = 1; i <= n_sw; i++) sw[swlist[i]] = 1
  while ((getline line < rwfile) > 0) {
    n = split(keys(line), arr, " ")
    for (i = 1; i <= n; i++) have[arr[i]] = 1
  }
  close(rwfile)
}
{
  frag[++nf] = $0
  fk[nf] = keys($0)
  n = split(fk[nf], arr, " ")
  for (i = 1; i <= n; i++) {
    if ((nf SUBSEP arr[i]) in once) continue
    once[nf SUBSEP arr[i]] = 1
    df[arr[i]]++
  }
}
END {
  # A word the description says in more than half its statements is what the
  # ticket is about, so finding it in the rewrite says nothing about any one
  # statement. On a card about follow-up cases every sentence holds "case" and
  # "follow", and counting those would report a wholly deleted requirement as
  # covered by the words its subject shares with the rest of the ticket.
  #
  # Below three statements there is no "the rest of the ticket" to read a
  # subject out of: at one, every word it says is in more than half of them and
  # the whole card would go unjudged.
  if (nf >= 3) for (s in df) if (df[s] * 2 > nf) ubiq[s] = 1
  for (j = 1; j <= nf; j++) {
    n = split(fk[j], arr, " ")
    tot = 0; hit = 0
    for (i = 1; i <= n; i++) {
      s = arr[i]
      if (s in ubiq) continue
      if ((j SUBSEP s) in counted) continue
      counted[j SUBSEP s] = 1
      tot++
      if (held(s)) hit++
    }
    if (tot < minwords) continue
    if (hit * 100 < share * tot) print frag[j]
  }
}'

# rewrite_uncovered <description text> <rewritten description>
#
# The ticket's own statements the rewrite no longer says, one per line, in the
# ticket's own words - which is what a reader has to be shown, because the
# finding is that this sentence is not in there any more.
#
# Three fragments are dropped before any of this, and two of the three are the
# same idea: a name for what comes after it is not a statement of its own.
#
# A fragment that ended at a colon. "The following is missing today:" and
# "Push title:" are both introducers, and a rewrite that says everything the
# list under them said has not lost anything by introducing it differently. The
# splitter is still the copy check's own - it is marked before it runs rather
# than re-implemented, since the marker survives into the end of the fragment
# the colon closed.
#
# A markdown heading, for the same reason and one more: the rewrite is required
# to keep a sectioned ticket's own sections, so a section whose content really
# did go missing is reported by its statements rather than by its title, and
# holding the title against the rewrite as well would report one loss twice.
#
# And one holding an identifier, because the rewritten description may not name
# a path, a class or a column at all, so a check that demanded one be carried
# through would be demanding the field fail the scan it is held to. Same regex
# terms_off_ticket discounts a term by, and the same reason _verbatim_keep
# refuses a quoted one.
rewrite_uncovered() {
  local rwfile out
  [ -n "${1:-}" ] || return 0
  [ -n "${2:-}" ] || return 0
  rwfile=$(mktemp)
  printf '%s\n' "$2" > "$rwfile"
  out=$(printf '%s\n' "$1" \
    | LC_ALL=C awk '{ gsub(/:/, " \001:"); print }' \
    | LC_ALL=C awk "$ORC_VERBATIM_FRAGMENT_AWK" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | LC_ALL=C grep -v "$(printf '\001')$" \
    | grep -v '^#' \
    | LC_ALL=C grep -Ev "$ORC_CODE_SHAPED_TERM" \
    | LC_ALL=C awk -v rwfile="$rwfile" -v stop="$ORC_CONTENT_STOPWORDS" \
        -v stemlen="$ORC_COVERAGE_STEM" -v minwords="$ORC_COVERAGE_MIN_WORDS" \
        -v share="$ORC_COVERAGE_SHARE" "$ORC_COVERAGE_AWK" || true)
  rm -f "$rwfile"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

# --- memory of what a prior round already asked and the reporter already
# answered --------------------------------------------------------------------
#
# Every promoted question above checks itself against what THIS round already
# asked - the refiner's own questions, the second read's own findings - and
# none of it ever checked a PRIOR round. Run to completion with real
# orc-refine.sh and orc-harvest.sh calls and a reporter answering every round,
# that gap alone is enough to keep a card looping until its round cap without
# ever reaching a terminal verdict. One round both resolves a term via
# domain/reporter-answers.md and promotes the same term as a question in the
# same breath, because terms_off_to_ask never looked at that round's own
# terms_resolved; other terms are promoted, answered, and re-promoted verbatim
# rounds later; and one misreading is re-raised round after round despite an
# identical answer each time. The refiner's
# own first-pass questions never show this failure, because the refiner reads
# domain/reporter-answers.md itself, every round - the bug is that nothing
# else does.
#
# So both broken mechanisms get the same grounding, and it is read the same
# mechanical way the rest of this file already prefers over a self-report:
# bin/orc-harvest.sh already matches a reporter's reply to the question it
# addressed - by address, then by position, then by reading - and it already
# excludes a deferral from that match (answer_is_deferring above). Nothing
# here repeats that matching; this reads its result, in
# $STATE_DIR/<key>.answers.json, which is exactly the derived-not-asked
# pattern verdict_split_ready, integration_gaps and terms_off_to_ask itself
# already follow.
ORC_ANSWERED_FS=$'\002'

# answered_qa_for <ticket key>
#
# question<FS>answer, one per line, for every question this ticket has
# already had a genuine answer to. Never a deferral: answer_is_deferring
# already decided such a reply settled nothing, and bin/orc-harvest.sh leaves
# it out of this file rather than recording it as though it had.
answered_qa_for() {
  local key="$1"
  local file="$STATE_DIR/$key.answers.json"
  [ -f "$file" ] || return 0
  jq -r --arg fs "$ORC_ANSWERED_FS" '
    .answers // [] | .[]?
    | select((.question // "") != "" and (.answer // "") != "")
    | (.question + $fs + .answer)' "$file" 2>/dev/null
}

# answered_questions_for <ticket key>
#
# Just the question half of answered_qa_for, one per line - what the
# already-asked lists elsewhere in this file are folded and matched against.
answered_questions_for() {
  local q a
  while IFS="$ORC_ANSWERED_FS" read -r q a; do
    [ -n "$q" ] && printf '%s\n' "$q"
  done <<< "$(answered_qa_for "$1")"
}

# The register the refiner's own questions are written in, folded out of both
# sides of the comparison below on top of ORC_CONTENT_STOPWORDS. Every question
# this system asks is an interrogative held to one bar - one sentence, one
# thing, a product decision named two ways - so they all say "should", "does",
# "or", "only", "instead", "rather", "every", "any", "whether". Those are the
# words two questions are most likely to share and the last words that say
# anything about whether they are the same question, so counting them inflates
# the overlap on exactly the comparisons that ought to fail.
#
# Read off the questions in prompts/refine.md's calibration examples,
# prompts/misread.md's worked example and golden/expected/, rather than guessed
# at. Two things that corpus said and this list therefore does not carry: the
# ticket's own nouns - case, clinic, rental, deposit - which are shared subject
# vocabulary rather than register and are what the per-question comparison
# below exists to discount; and the small number words, because "one per
# rental" and "three qualifying groups" are quantities a question turns on
# rather than function words. First and second stay out for both reasons at
# once - a first visit and a second opinion are products.
#
# Kept beside ORC_CONTENT_STOPWORDS rather than folded into it, because that
# list is also how bin/orc-harvest.sh scores a reporter's reply against a
# question, and a reply's "instead" or "rather" is often where the decision
# actually is. Widening what that comparison ignores is a change to attribution
# and would have to be measured as one.
ORC_QUESTION_STOPWORDS="able about above across after against all almost along already although always among another any anybody anyone anything anywhere around because before behind below beneath beside besides between beyond cannot during each else elsewhere enough even ever every everyone everything few here however instead less like many more most much never next none nobody nothing now often onto other others otherwise per perhaps rather same several some somebody someone something somewhere such through throughout thus together toward towards unable under underneath unless until up upon very well whatever whenever wherever whether whichever while whom whose within without"
ORC_MISREAD_STOPWORDS="$ORC_CONTENT_STOPWORDS $ORC_QUESTION_STOPWORDS"

# Half of the candidate's own content words, and never fewer than two of them.
#
# Half, because a re-derived disagreement is rephrased far more freely than a
# repeated term ever is and a bar much above half would only catch the repeats
# that were already near-verbatim. Two, because half of a two-word question is
# one word, and one word in common is a coincidence rather than a match - the
# same floor _contradiction_already_asked puts under its own overlap test.
ORC_MISREAD_ASKED_SHARE=50
ORC_MISREAD_ASKED_MIN=2

# misread_already_asked <folded question> <one folded question already answered>
#
# True when the two are the same disagreement in different words: at least half
# of the candidate's own content words, and at least two of them, are said by
# that one prior question as well. Content word here means longer than two
# characters and not in ORC_MISREAD_STOPWORDS, and a repeated word counts once.
#
# The overlap bar is loose rather than a whole-phrase match on purpose, and the
# reason is a real ticket whose second read re-raised one disagreement on five
# separate rounds and was not always word for word, so a match that needed the
# phrasing to repeat would have caught almost none of them.
#
# What it is compared against is the load-bearing half. This used to be handed
# the concatenation of every prior answered question at once, and asked whether
# half the candidate's words appeared anywhere in that bag. By round five or six
# of a real ticket the bag holds several hundred words, so a brand-new question
# about a brand-new subject clears the bar by coincidence - half of its words
# have been used somewhere, in some earlier question, about something else. The
# false-suppression rate grew with the round count, which put it at its worst on
# the late rounds that decide whether a card is finished; on the last one it
# discarded three real findings from the round that called the card done. So the
# unit is one prior question, and the caller asks this of each of them in turn:
# a candidate is the same disagreement as some *one* question that was answered,
# or it is not the same disagreement as any of them.
#
# Both sides drop the stopwords, so a question made almost entirely of function
# words does not clear the bar by having them matched; and a question with no
# content words left after that suppresses nothing, because there is no evidence
# either way in a sentence that says nothing.
misread_already_asked() {
  local qfold="$1" priorfold="$2"
  [ -n "$qfold" ] && [ -n "$priorfold" ] || return 1
  awk -v q="$qfold" -v t="$priorfold" -v stop="$ORC_MISREAD_STOPWORDS" \
      -v share="$ORC_MISREAD_ASKED_SHARE" -v minshared="$ORC_MISREAD_ASKED_MIN" 'BEGIN {
    n = split(stop, sl, " ")
    for (i = 1; i <= n; i++) sw[sl[i]] = 1
    n = split(t, tw, " ")
    for (i = 1; i <= n; i++) if (length(tw[i]) > 2 && !(tw[i] in sw)) have[tw[i]] = 1
    n = split(q, qw, " ")
    tot = 0; hit = 0
    for (i = 1; i <= n; i++) {
      w = qw[i]
      if (length(w) <= 2 || (w in sw) || (w in seen)) continue
      seen[w] = 1
      tot++
      if (w in have) hit++
    }
    exit !(tot > 0 && hit >= minshared && hit * 100 >= share * tot)
  }'
}

# misread_to_ask <misread-json> <questions already asked-and-answered, one per line>
#
# The second read's own findings, minus any whose question is the same
# disagreement as one already asked and answered on a prior round. Same shape
# as the object misread_questions already reads - {"misreadings": [...]} - so
# a caller filters with this and renders with that, unchanged. Everything
# unfiltered is still recorded on the verdict: a finding found and not asked
# is a different fact from one never found, the same reason
# integration_gaps_json and code_contradictions_json both report everything
# rather than only what was promoted.
#
# Each prior question is folded and compared on its own, never as one bag of
# every word anybody has ever been asked on this ticket - see
# misread_already_asked above for what that bag cost.
misread_to_ask() {
  local m q qfold prior priorfold settled
  printf '%s' "$1" | jq -c '.misreadings // [] | .[]?' | while IFS= read -r m; do
    q=$(printf '%s' "$m" | jq -r '.question // ""')
    if [ -n "$q" ]; then
      qfold=$(printf '%s' "$q" | _terms_fold)
      settled=no
      while IFS= read -r prior; do
        [ -n "$prior" ] || continue
        priorfold=$(printf '%s' "$prior" | _terms_fold)
        if misread_already_asked "$qfold" "$priorfold"; then settled=yes; break; fi
      done <<< "$2"
      [ "$settled" = yes ] && continue
    fi
    printf '%s\n' "$m"
  done | jq -sc '{misreadings: .}'
}

# Where a question was asked and answered, as something a reader can open. A
# ticket browse URL when the site is configured, and the bare key when it is
# not - a fixture run has no base URL, and half a URL is worse than a key.
# A key and a URL both have no space in them, which is what the check that
# forbids a sentence in a source resource tests for.
ticket_resource() {
  if [ -n "$JIRA_BASE_URL" ]; then
    printf '%s/browse/%s' "${JIRA_BASE_URL%/}" "$1"
  else
    printf 'jira:%s' "$1"
  fi
}

# --- the answer key in the team's git history --------------------------------
#
# A closed ticket has already been answered: the files its fix touched are in the
# repository, and nobody is reading them. These two functions are how refinement
# gets scored against real work without labelling anything by hand.
#
# Reachable from the clone's HEAD only. A commit on an unmerged branch is
# somebody's work in progress rather than an answer, and scoring against one
# would credit refinement for guessing what a branch was about to do.

# Every commit on this clone's current branch whose subject names the ticket.
# Squash merges spell it `[RW-118]`, some spell it `[#RW-140]`, and a
# rebase-merged branch contributes several commits rather than one, so the
# question asked is "does the subject name this ticket" rather than "is this the
# pull request".
ticket_merged_commits() {
  local repo="$1" key="$2"
  git_read "$repo" log --format='%H %s' HEAD 2>/dev/null \
    | grep -E "(^|[^0-9A-Za-z])#?$key([^0-9]|\$)" \
    | awk '{print $1}'
}

# The paths those commits touched, sorted and deduplicated. Repository-relative,
# which is the same shape a verdict names files in.
ticket_merged_paths() {
  local repo="$1" key="$2" sha
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git_read "$repo" show --pretty=format: --name-only "$sha" 2>/dev/null
  done <<< "$(ticket_merged_commits "$repo" "$key")" \
    | grep -v '^$' | sort -u
}
