# The golden set

Twenty to thirty real tickets with verdicts you have judged yourself, run on
every prompt change, like a test suite.

This is the cheapest component in the design and the one that makes everything
else trustworthy.
Without it you improve one class of ticket while silently regressing another,
and you do not find out for weeks.

Nine tickets ship here.
That is a seed, not a golden set.
The README explains how to grow it.

## What is in an expectation

One file per ticket in `expected/`.

```json
{
  "key": "ORC-103",
  "verdict": "needs_input",
  "max_questions": 3,
  "expect_files": [],
  "duplicate_of": null,
  "expect_split": false,
  "why": "..."
}
```

`why` is the field that matters.
A verdict without its reasoning is unmaintainable: in six months nobody
remembers whether a ticket was marked `needs_input` for a good reason or because
of a mood, and the set stops being an authority the moment that happens.

A ticket passes only if all of these hold:

- the verdict matches,
- it asked no more than `max_questions` questions,
- when a duplicate was expected, it named the right ticket,
- when a split was expected, it proposed at least three tickets.

`expect_files` is scored as recall and reported, but does not fail a ticket on
its own.
Locality accuracy is worth measuring and too noisy to gate on.

## Running it

```sh
golden/run.sh                                    # the shipped prompt
golden/run.sh --refiner claude                   # call the real agent
golden/run.sh --json                             # machine-readable
golden/diff.sh OLD.md NEW.md --refiner claude    # two prompts, same set
```

Both sides of a diff are named explicitly, because no earlier prompt version is
kept on disk - git holds those:

```sh
git show HEAD:prompts/refine.md > /tmp/prev-refine.md
golden/diff.sh /tmp/prev-refine.md prompts/refine.md --refiner claude
```

`run.sh` exits non-zero when any ticket fails, so it works as a gate.
`diff.sh` exits non-zero only when a ticket that passed under the old prompt
fails under the new one, which is the thing that should block a merge.

Neither writes to Jira or to `state/`.
They call `bin/orc-refine.sh --judge-only`, which is the same code path the
daemon uses to reach a verdict and none of the code path that acts on one.

## What it is judged against

The tickets come from `fixtures/`, and so do the repositories: `golden/run.sh`
materialises `fixtures/repos/` through `fixtures/repos.sh` and points refinement
at it.

Before that it ran against `config/projects.yml`, which ships with no product
repository at all, so every ticket was judged under "No repository is available
to search".
That is not the daemon's situation, and it makes a whole class of finding
unmeasurable: an integration gap - a ticket adding one more of something the
product enumerates elsewhere - is read out of the code, and a refiner with no
code reads none of it.

`ORC_PROJECTS_FILE` overrides it, which is how the same prompt is run with and
without the fleet.
That override is a measurement rather than an escape hatch: a change to what the
refiner can read is a change to the instrument, and the two numbers are only
comparable if you know which one you took.

## replay and claude

`--refiner replay` reads canned verdicts from `fixtures/verdicts/`.
Those are hand-authored, so a replay run tells you the harness works and tells
you nothing about the prompt.
It is what lets the whole thing be demonstrated with no network.

`--refiner claude` calls the agent for real.
That is the mode that measures a prompt.
It needs network, but still no Jira account, because the tickets come from
fixtures either way.

`replay-map.tsv` maps a prompt file to its canned set.
A prompt not listed there cannot be replayed, which is deliberate: silently
falling back to another version's verdicts would make the diff a lie.
Only the shipped prompt is listed, so a replay diff has nothing to compare and
`--refiner claude` is the only mode that measures a prompt change.

## What to measure once it runs on real tickets

The workflow produces its own ground truth, so no labelling effort is needed.

| Signal | Computed from | Tells you |
|---|---|---|
| Verdict agreement | this harness | whether it judges like you |
| Locality precision and recall | files named, versus files the merged PR touched | whether it can find things |
| Verdict reversal rate | tickets marked ready that an implementer then found underspecified | whether ready means ready |
| Question yield | whether the description changed after the questions were posted | whether the questions were worth asking |
| Human override rate | the label removed with nothing answered | whether people trust it |

The second row is built. `bin/orc-locality-score.sh` scores the files a verdict
named against the diff of the commits that merged for the ticket, over the real
tickets in `fixtures/solved/`.
It is a separate harness rather than a column here because the two want different
sets: this one wants tickets a human has judged, and that one wants tickets the
team has already finished.

The last two predict adoption.
A refiner asking eight questions per ticket gets switched off within a week
regardless of how correct it is, which is why the question budget is a pass
condition here and not a footnote.
