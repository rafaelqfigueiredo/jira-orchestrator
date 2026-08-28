# Canned verdicts, for offline replay

`--refiner replay` reads a verdict from here instead of calling an agent, which
is what lets the whole loop run with no network and no credentials.

**These files are hand-authored, not recorded model output.** They are what each
prompt version is expected to produce, written by a human, and they exist so the
plumbing and the harness can be demonstrated and tested on their own. Do not
read a replay run as evidence about the prompt: for that, run the golden harness
with `--refiner claude`, which calls the real agent against the same tickets.

| Set | Stands for |
|---|---|
| `baseline/` | `prompts/refine.md`, the shipped prompt |

The mapping from prompt file to set is `golden/replay-map.tsv`, and a prompt not
listed there cannot be replayed. That is deliberate: falling back to another
version's verdicts would make a diff a lie.

One set ships, because no earlier prompt version is kept on disk - git holds
those. So `golden/diff.sh --refiner replay` has nothing to compare, and measuring
a prompt change is `--refiner claude` against a previous version taken out of
git. `golden/diff.sh --help` gives the two commands.

If you add a set, add its row to `golden/replay-map.tsv` and give it a canned
verdict for every ticket in `fixtures/`; `bin/orc-check.sh` fails on a set that
covers only some of them, and on a row naming a prompt file that is not there.
