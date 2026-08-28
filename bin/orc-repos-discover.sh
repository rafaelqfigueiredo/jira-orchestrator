#!/usr/bin/env bash
# Proposes a config/projects.yml block from a GitHub organisation, so nobody has
# to type remotes and branch names by hand and get one of them subtly wrong.
#
# It proposes. It does not write.
#
# Nothing in this script opens config/projects.yml for writing, and
# bin/orc-check.sh proves it by running discovery with a config present and
# comparing that file's hash afterwards. The reason is the same reason a Jira
# write needs two switches: the orchestrator detects, and a human consents. A
# tool that edits the reviewed half of the split is a tool that quietly makes
# the review meaningless.
#
#   orc-repos-discover.sh --org acme
#   orc-repos-discover.sh --org acme --limit 10
#   orc-repos-discover.sh --org example --offline      the fixture listing
#   orc-repos-discover.sh --org acme --protocol ssh    override the detection
#   orc-repos-discover.sh --check-access               can this machine read GitHub?
#
# --check-access is here rather than in bin/orc-onboard.sh for the same reason
# the listing is: gh lives in this script and nowhere else, and an access check is
# a gh question. It reads, prints one line about what it found, and exits 0 when a
# listing would work. It never tries to log in - gh auth login is interactive and
# does not want to be wrapped - so when there is no credential it prints the exact
# command for a human to run and stops. Same rule as a Jira write: detect, then
# let a human consent.
#
# Remotes are proposed in the protocol this machine can actually use, and the
# proposal says which it chose and why rather than leaving it to be discovered
# ten failed clones later. Detected, in this order:
#
#   1. the git protocol gh reports, which is the one gh configured
#   2. git ls-remote against one real candidate, ssh first
#   3. https, as the guess, because it works wherever a token does and needs no
#      key on disk
#
# ssh remotes on a machine whose GitHub credentials are https fail for one
# reason and report it once per repository, and the proposal is the place that
# gets decided.
#
# Repositories are ranked by when they were last pushed to, because on any org
# of real size the ones worth wiring up first are the ones people are working in.
#
# With gh on PATH it reads the organisation. Without it, or with --offline, it
# reads fixtures/org/<org>.json, which is what keeps the acceptance suite
# runnable with no network and no credentials. gh is used here and nowhere else,
# and never for Jira: every Jira request goes through orc-lib.sh.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

org=""
limit=20
offline=0
protocol=""
check_access=0

while [ $# -gt 0 ]; do
  case "$1" in
    --org)     org="$2"; shift ;;
    --limit)   limit="$2"; shift ;;
    --offline) offline=1 ;;
    --check-access) check_access=1 ;;
    --protocol)
      protocol="$2"; shift
      case "$protocol" in
        ssh|https) : ;;
        *) orc_die "--protocol must be ssh or https (got '$protocol')" ;;
      esac
      ;;
    -h|--help) orc_usage "$0"; exit 0 ;;
    -*)        orc_die "unknown option: $1" ;;
    *)         org="$1" ;;
  esac
  shift
done

# --- can this machine read GitHub at all? -----------------------------------
#
# Reported before a listing is attempted, because "gh could not list the acme
# organisation" is the same message for a missing gh, an expired token and an
# organisation that does not exist, and those have three different fixes.

report_access() {
  if [ "$offline" = "1" ]; then
    printf 'offline: nothing was asked of GitHub. The listing comes from %s.\n' \
      "fixtures/org/${org:-<org>}.json"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'gh is not on PATH, so no organisation can be listed.\n'
    printf '\n  install it:  brew install gh\n'
    printf '  then:        gh auth login\n'
    printf '\nOr stay offline: --offline reads fixtures/org/<org>.json, which needs\n'
    printf 'neither gh nor a network and is how this is demonstrated.\n'
    return 1
  fi
  local who
  if gh auth status >/dev/null 2>&1; then
    who=$(gh auth status 2>&1 \
      | sed -n 's/.*[Ll]ogged in to \([^ ]*\) account \([^ ]*\).*/\1 as \2/p' | head -1)
    printf 'GitHub access is configured%s.\n' "${who:+: gh is logged in to $who}"
    return 0
  fi
  printf 'gh is installed but not authenticated, so no organisation can be listed.\n'
  printf '\n  run this yourself:  gh auth login\n'
  printf '\nIt is interactive - it asks which host, which protocol and opens a browser -\n'
  printf 'so nothing here tries to drive it. Run it, then run this again.\n'
  printf '\nOr stay offline: --offline reads fixtures/org/<org>.json, which needs neither\n'
  printf 'gh nor a network.\n'
  return 1
}

if [ "$check_access" = "1" ]; then
  report_access
  exit $?
fi

[ -n "$org" ] || orc_die "usage: orc-repos-discover.sh --org ORG [--limit N] [--offline]"
case "$limit" in ''|*[!0-9]*) orc_die "--limit must be a number (got '$limit')" ;; esac

# A paragraph as '# ' comment lines. The reason a protocol was chosen is a
# sentence, and a sentence on one 300-column line is not a thing anyone reads.
comment_wrap() {
  printf '%s' "$1" | awk -v w=74 '
    {
      m = split($0, word, " ")
      out = "#"
      for (i = 1; i <= m; i++) {
        if (length(out) + 1 + length(word[i]) <= w) { out = out " " word[i]; continue }
        print out
        out = "# " word[i]
      }
      print out
    }'
}

fixture_listing() {
  local f
  for f in "$FIXTURE_DIR/org/$org.json" "$ORC_ROOT/fixtures/org/$org.json"; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  orc_die "no gh on PATH and no fixture listing for '$org' (looked in $ORC_ROOT/fixtures/org/)"
}

from_fixture=0
if [ "$offline" = "1" ] || ! command -v gh >/dev/null 2>&1; then
  from_fixture=1
  source_desc="fixtures/org/$org.json"
  listing=$(fixture_listing)
else
  source_desc="the $org organisation, read with gh"
  listing=$(gh repo list "$org" --limit "$limit" --no-archived \
      --json name,description,url,sshUrl,defaultBranchRef,primaryLanguage,pushedAt,isArchived) \
    || orc_die "gh could not list the $org organisation (gh auth status?)"
fi

printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || orc_die "the listing for '$org' is not a JSON array of repositories"

# The protocol every proposed remote is spelled in, and why.
#
# Both halves matter. A detected protocol nobody can see is magic, and magic in
# the reviewed half of the split is the thing this script exists not to do.
protocol_reason=""

# One real remote to probe, if we have one. Fixture listings name example.com,
# so probing those would be network traffic that proves nothing.
candidate=$(printf '%s' "$listing" | jq -r 'first(.[] | select(.isArchived != true) | .sshUrl // .url // empty) // empty')

gh_reported_protocol() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status 2>&1 \
    | sed -n 's/.*[Gg]it operations protocol:[[:space:]]*\([a-z]*\).*/\1/p' \
    | head -1 \
    | grep -E '^(https|ssh)$'
}

detect_protocol() {
  local reported probe

  if [ -n "$protocol" ]; then
    protocol_reason="you asked for it with --protocol"
    return 0
  fi

  if [ "$from_fixture" = "1" ]; then
    # The offline path must stay offline: it is how this is demonstrated with no
    # network and no credentials, so nothing here may reach for either.
    protocol=https
    protocol_reason="the listing is a fixture, so nothing was probed; https is the default because it works wherever a token does and needs no key on disk"
    return 0
  fi

  reported=$(gh_reported_protocol)
  if [ -n "$reported" ]; then
    protocol="$reported"
    protocol_reason="gh reports its git operations protocol as $reported, and gh is what configured your credentials"
    return 0
  fi

  if [ -n "$candidate" ]; then
    probe=$(remote_in_protocol ssh "$candidate")
    if remote_is_readable "$probe"; then
      protocol=ssh
      protocol_reason="gh would not say, so git ls-remote was tried: it read $probe"
      return 0
    fi
    probe=$(remote_in_protocol https "$candidate")
    if remote_is_readable "$probe"; then
      protocol=https
      protocol_reason="gh would not say and ssh could not read $(remote_in_protocol ssh "$candidate"), but git ls-remote read $probe"
      return 0
    fi
  fi

  protocol=https
  protocol_reason="neither gh nor git ls-remote could tell, so this is a guess: https works wherever a token does and needs no key on disk"
}

detect_protocol

# Already-configured projects are shown commented out. Pasting a duplicate
# top-level key into the config would silently shadow the reviewed entry.
known=$(project_names | tr '\n' ' ')

printf '# Proposed by bin/orc-repos-discover.sh from %s.\n' "$source_desc"
printf '# Nothing has been written. Read every line, then paste what you want into\n'
printf '# %s and commit it as the reviewed change it is.\n' "${PROJECTS_FILE#"$ORC_ROOT"/}"
printf '#\n'
printf '# default_branch below is what the remote actually says, not an assumption.\n'
printf '# The clone lands in %s/<project> unless the entry names a repo path.\n' "${CLONE_DIR#"$ORC_ROOT"/}"
printf '# verify is the one field discovery cannot know: unit-only is the safe\n'
printf '# starting point, and local is worth it only where the suite is slow enough\n'
printf '# that an agent should iterate before pushing.\n'
printf '#\n'
comment_wrap "Remotes are proposed over $protocol, because $protocol_reason. A remote spelled in a protocol these credentials cannot use fails on every repository for the same reason, so the protocol is chosen here, in the open, rather than found out ten failed clones later. Override it with --protocol ssh or --protocol https."
printf '\n'

printf '%s' "$listing" \
  | jq -r --argjson limit "$limit" '
      [ .[] | select(.isArchived != true) ]
      | sort_by(.pushedAt) | reverse | .[0:$limit]
      | .[]
      | [ .name,
          (.sshUrl // .url // "-"),
          (.defaultBranchRef.name // "-"),
          ((.pushedAt // "-") | split("T")[0]),
          (.primaryLanguage.name // "unknown"),
          (((.description // "") | gsub("[\r\n\t]"; " ") | if . == "" then "no description" else . end))
        ] | @tsv' \
  | while IFS=$'\t' read -r name remote branch pushed lang desc; do
      [ -n "$name" ] || continue
      if [ "$branch" = "-" ]; then
        printf '# %s: skipped. The remote reports no default branch, so there is\n' "$name"
        printf '#   nothing to check out and nothing to fetch. Probably an empty repository.\n\n'
        continue
      fi
      prefix=""
      case " $known " in
        *" $name "*)
          printf '# %s is already in %s. Shown for comparison only.\n' \
            "$name" "${PROJECTS_FILE#"$ORC_ROOT"/}"
          prefix="# "
          ;;
      esac
      printf '%s%s:\n' "$prefix" "$name"
      printf '%s  remote: %s\n' "$prefix" "$(remote_in_protocol "$protocol" "$remote")"
      printf '%s  default_branch: %s\n' "$prefix" "$branch"
      printf '%s  verify: unit-only\n' "$prefix"
      printf '%s  # %s, last pushed %s\n' "$prefix" "$desc" "$pushed"
      printf '%s  # %s\n' "$prefix" "$lang"
      printf '\n'
    done

printf '# Proposal only. %s was not read for anything but existing project names,\n' \
  "${PROJECTS_FILE#"$ORC_ROOT"/}"
printf '# and it was not written to.\n'
