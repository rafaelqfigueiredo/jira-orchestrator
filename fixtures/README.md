# Example tickets

Nine tickets of deliberately varying quality, which are both the offline demo
and the seed of the golden set.

| Key | Shape | Why it is here |
|---|---|---|
| ORC-101 | Excellent | Reproducible, one outcome, surface decided. The bar for `ready`. |
| ORC-102 | Vague, by omission | One line, no reproduction, and it names a screen that exists twice. |
| ORC-103 | Vague, by indecision | Plenty of context, no decidable outcome. It offers three alternatives and picks none. |
| ORC-104 | Duplicate | The same defect as ORC-101 in a reporter's words rather than a developer's. |
| ORC-105 | Really three tickets | Four clear deliverables across two subsystems in one ticket. |
| ORC-106 | Ambiguous grammar | Complete in every other respect, and one sentence of qualifying conditions parses two ways. |
| ORC-107 | Extends a closed set | Adds one more of something the code enumerates elsewhere, and never mentions the places that count them. |
| ORC-108 | Dense | Eight sections, settled everywhere but one, so the unsettled sentence competes with a screenful of prose the way it does on a real card. |
| ORC-109 | Dense, and thorough | Five of the six standing gap classes are closed in the ticket's own words and the sixth is left open on purpose. |

The last four are deliberately harder than the first five.
A ticket written clean enough that the finding is the only thing in it is a far
easier target than a real card, so a fixture that is dense is the only kind that
says anything about a prompt.
`golden/expected/` carries a `why` for each one, and several of them say plainly
that the fixture did not reproduce the miss it was written for.

ORC-102 and ORC-103 are both vague and they fail in opposite directions.
One has too few words, the other has plenty and still cannot be acted on.
A refiner that reads volume of prose as readiness passes the first and fails the
second, which is exactly what the design's own first-draft prompt does.

## Editing them

Tickets are authored as markdown in `src/`, with a small frontmatter block.
`build.sh` turns each one into a Jira-shaped issue whose description is real
Atlassian Document Format, because that is what the v3 API returns and the
pipeline has to handle the real shape.

```sh
fixtures/build.sh
```

Never edit `issues/*.json` or `search/*.json` by hand; they are generated.

## The mid-flight scenario

`scenarios/mid-flight/` is the same tickets as they would look after the
orchestrator had already run: labels applied, and a refinement comment carrying
the prompt version and the ticket revision it judged.

It exists so that `bin/orc-reconcile.sh` can be tested against a world that has
history, which is the only way that test means anything.
It is generated from the same sources plus `src/overlays/mid-flight.tsv`.

## Tickets that have already been solved

`solved/` is the set `bin/orc-locality-score.sh` scores: the files a verdict names
against the diff the work actually landed.

What ships is an **invented example** - four Rentworks tickets that run offline and
score nothing, because none of them names a repository this template configures.
A real set is your own organisation's already-solved tickets, and it belongs
outside this repository, chosen with `ORC_SOLVED_DIR`. Its own README says why,
and says what a scored set has to contain.

Real text matters there for a reason worth keeping in view: a ticket written to
be scored against carries the answer, and a score against it means nothing. That
is exactly why the shipped example is documented as a demonstration rather than a
measurement.

## The organisation listing

`org/example.json` is a canned `gh repo list` response, which is what lets
`bin/orc-repos-discover.sh` be tested with no network and no GitHub credentials.

It is shaped to exercise the decisions discovery has to make: four active
repositories across three different default branches (`staging`, `main` and
`trunk`, so a run that assumed any one of them would be visibly wrong), one
archived repository that must not be proposed, and one empty repository with no
default branch at all, which must be skipped rather than guessed at.

## Two rules about content

**No patient data, ever, at any phase, for any reason.**
Every name, clinic and case here is invented.
This is not a trial constraint that gets relaxed later.

**No credentials.**
Fixtures are committed, so anything in them is public to everyone with the repo.
