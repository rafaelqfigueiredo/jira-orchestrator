# The example solved set

Four invented tickets for **Rentworks**, a tool and equipment rental company that
does not exist, saved so `bin/orc-locality-score.sh` runs offline with no
network, no credentials and no repositories configured.

This directory is an **example, not a measurement**.
It exists so the harness can be demonstrated and so the shape of a scored set is
documented by something you can read.
The numbers a run prints against it say nothing about the prompt.

## Point it at your own set instead

The set is a directory, and `ORC_SOLVED_DIR` chooses which one:

```sh
ORC_SOLVED_DIR=~/work/orc-solved bin/orc-locality-score.sh
bin/orc-locality-score.sh --fixtures ~/work/orc-solved   # same thing, per run
```

A real set is your own organisation's tickets, and it belongs **outside this
repository**.
Two reasons, and the second is the one that bites:

- Ticket text carries reporter names, account ids and whatever the reporter
  happened to paste in. Fixtures are committed, so anything in here is readable
  by everyone with the repo.
- A set that ships with a shared template is one organisation's tickets being
  read by every other installation, which is worth nothing to any of them.

The layout your directory needs is the layout here: `issues/<KEY>.json` read the
way fixture mode reads any ticket, `search/open-issues.json` so a duplicate can
be named rather than merely suspected, and optionally `verdicts/<KEY>.json`.

## Why the tickets are invented and the answer key is empty

An answer key is the merged diff: for a ticket whose work has landed, the files
the fix touched are the diff of the commits naming it, reachable from the branch
the config names.

These four name no repository this template configures, so every row reports **no
answer key** and both figures come out empty.
That is the harness working: no merged work and a wrong verdict are different
findings, and `bin/orc-locality-score.sh` reports the first rather than averaging
it in at zero.
Scoring needs your repositories in `config/projects.yml` and your tickets in
`ORC_SOLVED_DIR`.

| Key | Summary |
|---|---|
| RW-118 | Reactivation - introduce follow-on bookings |
| RW-140 | Prefill the booking form from the last completed rental |
| RW-152 | Notification app update |
| RW-163 | Improve the push integration, sync push reachability to the CRM |

The text is deliberately uneven - one ticket is four deliverables wearing one
summary, one says a part already landed without saying where, one is a wall of
version numbers - because a set of uniformly well-written tickets exercises no
judgment.

## `verdicts/`

Hand-authored, and they carry **no `prompt_version`**.

That absence is the honest part and it is deliberate: no prompt produced these,
so none is named, and `bin/orc-locality-score.sh` prints no staleness warning
because there is no recording being read under the wrong prompt.

Contrast the two directories that already exist, because this one is a third
thing:

- `fixtures/verdicts/` - hand-authored **expectations**, what a prompt *should*
  produce, replayed by `--refiner replay`.
- a real `ORC_SOLVED_DIR`'s `verdicts/` - **recordings**, what the agent actually
  said, kept by `--save` and stamped with the `prompt_version` they were produced
  under. A recording made under one prompt says nothing about another, so a
  prompt change means re-recording.
- this directory - authored **examples**, so the table can be produced with no
  agent calls at all.

```sh
bin/orc-locality-score.sh --verdicts fixtures/solved/verdicts
```

What they are authored to demonstrate, because two checks in `bin/orc-check.sh`
read them:

- Every one localises through `both`, which is why the gap loop's default basis
  of `search,none` matches none of them. That is the data rather than a bug, and
  the loop says so.
- Their `terms_unresolved` lists hold 23 words between them, all 23 distinct. No
  word is said by two tickets, so nothing clears the recurrence bar of two - a
  vocabulary gap is wide rather than deep, and four tickets is far too few for a
  frequency signal either way.

They also carry the reporter's bar: every one is `needs_input`, and
`bin/orc-check.sh` replays each through the real comment builder and scans what a
reporter would see for a path, a code identifier and the orchestrator's own
nouns. A guarantee proved only against text written to pass it is not yet a
guarantee, so this is where that scan meets prose it did not author.

## Two rules about content

The same two that govern every fixture here.

**No personal data, ever, at any phase, for any reason.**
Nothing here names a real person: the reporters are invented and so are their
account ids.

**No credentials.**
Fixtures are committed, so anything in them is public to everyone with the repo.
