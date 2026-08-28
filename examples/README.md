# examples/

Sample content for somebody setting this repository up.
Nothing in here is read by anything.

That is the whole point of the directory.
`.okf/` is the knowledge bundle: refinement reads it, `bin/orc-okf-draft.sh`
manages it, `okf lint` counts it.
A sample concept sitting in there is structurally part of the bundle, so telling
it apart from knowledge your own team wrote means opening it and reading its
frontmatter.
That is the same confusion the drafted-versus-verified distinction exists to
prevent, arriving through a different door.
Here, the separation is the path: `examples/okf/` is not `.okf/`, no default
resolves to it, and `ORC_BUNDLE_DIR` would have to be pointed at it on purpose.

Copying out of here is therefore a deliberate act by a human, which is the same
shape every other consent step in this repository has: `bin/orc-repos-discover.sh`
proposes and never writes `config/projects.yml`, a Jira write needs two switches,
and the drafter reports a verified concept it would have rewritten rather than
rewriting it.

## What is in here

```
examples/projects.yml               a sample fleet for config/projects.yml
examples/okf/domain/                the three concepts no bootstrap can draft
```

### The sample fleet

`config/projects.yml` used to carry this block commented out at the bottom of
itself.
It has moved here for the reason above, plus one specific to that file: it is
tracked source that every installation edits, so example lines in it are lines
each installation has to delete and lines that conflict on a pull.
The field reference stayed behind, because that documents the live file rather
than being a sample of it.

You will usually not need the sample at all.
`bin/orc-repos-discover.sh --org your-org` prints a block with your own remotes
and each repository's real default branch in it, and `bin/orc-onboard.sh` writes
the lines you select.
The sample is for reading, when you want to see the shape before running
anything.

### The three concepts

`bin/orc-okf-draft.sh` drafts what it can read out of code: one concept per
subsystem, the vocabulary the string catalogues hold, the rules the enums and
schema constraints write down, the localisation surfaces.
What it cannot draft is everything a person decided and no repository records.
The bundle's own worked example of that is a term retired as a company decision:
that fact is in no file in any repository, so no amount of reading finds it.

These three cover exactly that half, and each one is here because a specific
line of the readiness bar in `prompts/refine.md` needs knowledge no repository
holds:

| Concept | The line it serves |
|---|---|
| `domain/product-overview.md` | "The affected surface is decided", and the instruction to phrase every question in the product's own words. No string catalogue teaches a refiner that people say "the customer app". |
| `domain/roles-and-decisions.md` | "For a bug: a reproduction that names the surface, the **role**, and the starting state", and "whether a design decision is needed before anybody builds" - which is a better question when it can name who decides. |
| `domain/product-constraints.md` | "Return `ready` only when an implementation agent could start now and finish without asking anybody anything." A ticket asking for something the product may not do cannot be finished, whatever else its prose says. |

Three, not the five this was scoped with, and the two that were dropped were
dropped for reasons rather than for length:

- **A glossary.** Every cross-reference the drafter writes points at
  `domain/product-vocabulary.md`, which is the drafted dictionary, and a second
  hand-curated glossary beside it would be a competing answer to the same
  question. The bundle contradicting itself is worse than the bundle being
  sparse, because you cannot tell which answer you got. A human-curated
  distinction belongs in whichever of these three concepts it bites in, or in a
  `verified:` rewrite of the vocabulary itself.
- **Delivery practices.** Its two concrete facts are already mechanics and
  already configured: the branch a ticket is about is `default_branch` in
  `config/projects.yml`, and how a change gets verified is `verify:` in the same
  entry. What is left - review expectations, where coverage is expected - appears
  nowhere in `prompts/refine.md` and changes no verdict, so an example concept
  for it would teach a shape nothing reads. Knowledge does not go in the config
  and mechanics do not go in the bundle, and that rule cuts both ways.

None of the three collides with a path the drafter owns, which matters: a
hand-written concept beside a generated one of the same name is the
duplicate-concept problem `bin/orc-check.sh` already fails on.

## Using them

```sh
mkdir -p .okf/domain
cp examples/okf/domain/product-overview.md .okf/domain/
$EDITOR .okf/domain/product-overview.md
```

Read the file before you copy it.
Each one says plainly what belongs in it, carries one short worked example that
is clearly marked as one, and names what to leave out.
They are written for somebody who has never seen OKF.

A copy you have not filled in yet is safe to leave in the bundle, and that is by
construction rather than by luck:

- It carries no `verified:` date, so `prompts/refine.md` already treats it as a
  lead to confirm rather than as knowledge to quote.
- It carries no `generated:` block either, so `bin/orc-okf-draft.sh` will not
  mistake it for a stale draft of its own, and `--check` and `--drifted` say
  nothing about it. It is not on a path the drafter writes.
- Its worked example is about **Rentworks**, a tool and equipment rental company
  that does not exist, and says so on the line above itself. The same invented
  company the example solved set under `fixtures/solved/` and the worked examples
  in `prompts/refine.md` use, so the three corroborate each other rather than
  being three domains to keep consistent. A refiner reading an unfilled copy
  finds no claim about *your* product to quote.

That last point is why `prompts/refine.md` needed no new rule telling a refiner
to skip these, and no frontmatter marker had to be invented for the drafter to
ignore them.
The separation comes from the location, and the marked-fiction worked example
covers the one case the location does not: a copy somebody made and has not
finished.

## Filling one in

Replace the fiction with your own, and when a person has read the result and
agrees with it, add the frontmatter that says so:

```yaml
verified:
  - by: your.name@example.com
    at: 2026-08-22
```

That is what makes it knowledge rather than a lead, and it is also what stops
`bin/orc-okf-draft.sh` from ever touching the file.
Do not add it on the way past.
A fact with a verification date nobody actually did is worse than a fact with
none, because the refiner is told to quote the first and only to follow up the
second.
