#!/usr/bin/env bash
# Materialises the fixture repositories into a directory and writes the
# projects.yml that names them. Prints that file's path on stdout and nothing
# else, so a caller can export ORC_PROJECTS_FILE from it directly.
#
#   fixtures/repos.sh DIR
#
# Why this exists: the harness used to run against config/projects.yml, which
# ships with no product repository at all, so every golden ticket was judged
# under "No repository is available to search". That is not the daemon's
# situation, and it makes a whole class of finding unmeasurable - an integration
# gap is read out of the code, in the places that assume a set is complete, and a
# refiner with no code reads none of them.
#
# Why a script rather than committed clones: refinement only searches a path git
# reports as a repository root, and a git repository nested inside this one
# breaks `git add` on its parent - "does not have a commit checked out" - so
# fixtures/repos/ is a plain tree and the repository is made here.
#
# Why one script rather than a copy in each caller: golden/run.sh and
# bin/orc-check.sh need the same fleet, and two spellings of a fixture fleet is
# two fleets that drift.
#
# What it deliberately does not do, and this is the interesting part:
#
#   It never removes anything. The destination is a directory in state/, which
#   is already a cache, so a stale file left behind by a deleted fixture is a
#   cache being stale rather than something to `rm -rf`. bin/orc-reset.sh is what
#   clears it, and the rule that a recursive remove lives in exactly one place in
#   this repository is worth more than a tidy scratch directory.
#
#   It never commits. `git init` is the only git command here, so nothing in this
#   script can move or discard work in any repository - which is the promise the
#   fast-forward region in bin/orc-repos-sync.sh makes, kept here by having
#   nothing to fence in the first place. The cost is real and named: with no
#   commit, a verdict reasoned against this fleet names no commit either, and
#   provenance reads `-@main`. The fixture code's actual provenance is this
#   repository's own commit, which is where it is versioned.
#
# No repository declares a remote, so the orchestrator does not manage these
# clones and nothing ever fetches: a metrics run stays offline, which is the same
# reason golden/run.sh pins ORC_REPO_SYNC=off.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")/../bin" && pwd)/orc-lib.sh"

SRC="$ORC_ROOT/fixtures/repos"
dest="${1:-}"
[ -n "$dest" ] || orc_die "usage: fixtures/repos.sh DIR"
[ -d "$SRC" ] || orc_die "no fixture repositories at $SRC"

mkdir -p "$dest" || orc_die "cannot create $dest"
projects="$dest/projects.yml"
: > "$projects"

for src in "$SRC"/*; do
  [ -d "$src" ] || continue
  name=$(basename "$src")
  target="$dest/$name"
  mkdir -p "$target" || orc_die "cannot create $target"
  # Copied over the top rather than replaced, for the reason in the header: this
  # is a cache, and nothing here removes.
  (cd "$src" && tar cf - .) | (cd "$target" && tar xf -) \
    || orc_die "could not copy $name into $target"
  if ! is_git_repo "$target"; then
    git -C "$target" init --quiet --initial-branch=main >/dev/null 2>&1 \
      || orc_die "could not make $target a repository"
  fi
  cat >> "$projects" <<YML
$name:
  repo: $target
  verify: unit-only

YML
done

[ -s "$projects" ] || orc_die "no fixture repository was materialised from $SRC"
printf '%s\n' "$projects"
