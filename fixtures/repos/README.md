# The fixture repositories

Two small repositories in the same invented clinical product the golden tickets
describe: an API and a dashboard.
They exist so that a golden run measures a refiner that has code to read.

Until they did, `golden/run.sh` ran against `config/projects.yml`, which ships
with no product repository at all - so every golden ticket was judged with the
context "No repository is available to search".
That is not the daemon's situation, and it makes one whole class of finding
unmeasurable: an integration gap is found by reading the code for the places
that assume a set is complete, and a refiner with no code reads none of them.

They are committed as plain files, with no `.git` of their own.
A git repository nested inside this one is not just untidy: it makes `git add`
on its parent fail outright with "does not have a commit checked out".
So `fixtures/repos.sh` copies the tree into `state/golden-repos/` and runs `git
init` there, which is the only git command it runs - refinement will only search
a path git reports as a repository root, and that is the cheapest way to make
one without anything in this repository being able to move or discard work.

There is no commit, deliberately, and it has a visible cost: a verdict reasoned
against this fleet names no commit either, so provenance reads `-@main`.
The fixture code's real provenance is this repository's own commit, which is
where it is versioned.

Both `golden/run.sh` and `bin/orc-check.sh` go through that one script, so the
fixture fleet has one spelling.
Neither repository declares a `remote`, so the orchestrator does not manage the
clones and nothing here ever fetches: a metrics run stays offline.

## What they are for

`app/models/medical_case.rb` declares `case_type`, and two other files enumerate
it: a report that groups cases by type and an export that lists them.
The dashboard's clinic overview names the same members again, and its case
header names one - which is a branch rather than a listing, and is there so the
detection has something it must not report.
That is the shape `integration_gaps` in `bin/orc-lib.sh` looks for, and
`fixtures/src/ORC-107.md` is the ticket that extends it.

Keep them small. They are read by an agent under a wall-clock limit, and a
fixture fleet big enough to be interesting is a fixture fleet nobody can reason
about when a measurement moves.
