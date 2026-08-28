# jira-orchestrator

A Jira ticket refiner.
It reads a ticket, decides whether the ticket says enough for someone to implement it without guessing, and writes back one comment and one label.

That is the whole of it.
It never writes code, it never changes your repositories, and it never edits a ticket's description.

Three verdicts:

| Verdict | Label it adds | What the comment carries |
|---|---|---|
| `ready` | `agent-ready` | the acceptance criteria, the ticket's description rewritten with every settled answer folded in, and - behind a collapsible section - the probable files, the subsystems and the commit each was found at |
| `needs_input` | `needs-refinement` | every question that blocks the ticket, assigned back to whoever filed it |
| `duplicate` | `possible-duplicate` | the ticket it duplicates, plus a Jira duplicate link |

The useful artefact is better tickets.
A clearer ticket helps the person who picks it up as much as it helps any tool, so this is worth running even if you never automate anything downstream.

## Try it now

No account, no credentials, no network.
This is the default mode, not a test harness.

```sh
git clone <this repo> && cd jira-orchestrator
bin/orc-daemon.sh
```

It judges nine example tickets in about a second and prints, for each one, the comment it would have posted - first rendered the way a person would read it on the card, then the exact JSON body.
Nothing is sent anywhere.
The whole transcript is also written to `state/.would-write.log`.

The run ends with a tally:

```
2026-08-27T19:24:23Z pass complete: ready=1 needs_input=7 duplicate=1 untouched=0 failed=0
```

Run it again and it judges nothing, because none of the tickets has changed since it last saw them.
`rm -rf state/` starts over.

## What lands on the ticket

This is the product, so here is real output from the run above, pasted verbatim.

A vague ticket - one line, no reproduction, and it names a screen that exists twice:

```
  +----------------------------------------------------------------+
  | WOULD POST   /issue/ORC-102/comment
  +----------------------------------------------------------------+
  | ## Refinement: this needs a little more before an agent can pick it up
  | Something about a case list regressed recently, but the ticket does not say which case list, for whom, or what it does wrong.
  | Answering these in the description is enough to unblock it:
  |   * Which case list is this: the doctor queue on the dashboard home screen, or the patient app grouped list? They share a name but they are two different screens.
  |   * What does a doctor see instead of what they expect - an empty list, the wrong cases, an error, or the wrong order?
  |   * Which role and clinic was the person using when they saw it, and roughly when did it start?
  | Not reproducible as written, and "case list" names two unrelated screens - the doctor queue and the patient app list - so the first question decides everything else.
  | Not verified: I could not read any of the product's code in this run, so the doctor-facing candidates come from what we have written down rather than from the code itself. If this turns out to be the patient app, none of them apply: nothing we have written down describes that screen at all.
  | ---
  | orchestrator/refinement prompt=refine-5f4ebda7 ticket-rev=96ca1ba080c0
  +-- raw ---------------------------------------------------------+
  | ... the exact JSON body follows here, elided
  +----------------------------------------------------------------+
```

Then the label, and the ticket handed back to the reporter:

```
  +----------------------------------------------------------------+
  | WOULD PUT    /issue/ORC-102
  +----------------------------------------------------------------+
  | {
  |   "update": {
  |     "labels": [
  |       {
  |         "add": "needs-refinement"
  |       }
  |     ]
  |   }
  | }
  +----------------------------------------------------------------+
```

And a ticket that is clear enough to build.
`[+]` marks a collapsible section; on the card those are folded shut until somebody opens them.

```
  +----------------------------------------------------------------+
  | WOULD POST   /issue/ORC-101/comment
  +----------------------------------------------------------------+
  | ## Refinement: ready
  | The dashboard's follow-up decision panel keeps the unlock control disabled even though the API already reports the authorisation as claimed.
  | ## Acceptance criteria, as the ticket states them
  |   - A doctor on a case whose follow-up authorisation is claimed can open the follow-up from the examination tab.
  |   - A doctor on a case whose authorisation is not claimed still sees the control disabled with the existing tooltip.
  |   - The regression is covered by a test at the level where the bug lives.
  | One outcome, a reproduction that names the surface, the role and the starting state, and criteria that can be checked afterwards. The bundle agrees with the ticket that the decision is the API's and the dashboard only renders it, so the fix belongs in the decision panel.
  | [+] The ticket, rewritten with every answer folded in - to copy across
  | The ticket has not been changed. This is how its description reads with every answer folded in; copy it across when you are happy with it.
  | A doctor cannot open a follow-up whose authorisation has already been claimed. On the examination tab of a closed case, the "Open follow-up" control in the follow-up decision panel stays disabled and its tooltip still reads "waiting for authorisation", so the case cannot be worked on at all.
  | To see it, open a closed case that has a claimed follow-up authorisation as a doctor who belongs to that case's clinic, go to the examination tab, and look at the "Open follow-up" control.
  | The control should be enabled, and activating it should open the follow-up for examination.
  | This happens on the dashboard only. The authorisation is already recorded as claimed; it is the dashboard that shows it wrongly.
  | Done when:
  |   - A doctor on a case whose follow-up authorisation is claimed can open the follow-up from the examination tab.
  |   - A doctor on a case whose authorisation is not claimed still sees the control disabled with the existing tooltip.
  |   - The change is covered by a test at the level where the fault lies.
  | Follow-up pricing and the mobile app's own follow-up wizard are out of scope.
  | [+] For the implementing agent: files, subsystems, commits
  | ## Probable files
  |   - src/features/case/FollowUpDecision.vue
  |   - src/features/case/ExaminationTab.vue
  | ## Subsystems
  |   - subsystems/dashboard
  | ## Reasoned against
  |   - ORC nothing configured to search
  | Not verified: No repository was available to search in this run, so the file names come from the knowledge bundle rather than from reading the component. Which field the panel reads instead of authorisation_claimed_at is unconfirmed.
  | ---
  | orchestrator/refinement prompt=refine-5f4ebda7 ticket-rev=28b4757a955e
  +-- raw ---------------------------------------------------------+
  | ... the exact JSON body follows here, elided
  +----------------------------------------------------------------+
```

Two things in there are worth pointing out, because they are the design rather than an accident.

**The questions are product questions.**
Nothing on a `needs_input` comment names a file, a class, a column or a branch, and nothing names this tool's own vocabulary either.
The reader is whoever filed the ticket - a reporter, a support agent, someone in the business - and the only questions worth asking them are the ones they can actually answer.
Anything answerable by reading the code gets answered rather than asked.

**A `ready` comment has two audiences, so it is split.**
The summary, the criteria and the caveats are visible.
The file paths and commits sit behind a fold, because printed flat they pushed the summary off the top of the card and the person who opened the ticket read three headings of paths before the sentence saying what it was about.

The last line of every comment is a marker.
It is how the tool recognises its own comments later, and it records which prompt version judged the ticket and which revision of the ticket it judged.

## How it decides

The judgement is made by a language model.
`prompts/refine.md` is what it is asked - the readiness bar, the four tests a question has to pass to be worth asking, and the exact JSON shape the answer has to come back in.
The model is handed the ticket's text, a list of the other open tickets so it can spot a duplicate, the paths of your repositories so it can search them itself, and the knowledge bundle described below.
Everything after that is ordinary shell: the answer is validated, the comment is built node by node, and the label is applied.

So the prompt is the product.
A change to it is a change to what the tool decides, which is why `golden/diff.sh` exists: it runs two versions of the prompt over the same set of tickets, each with a verdict a human already reached, and reports what moved.

Two other things happen around that call, and both are there because one read of a ticket is not reliable enough.
A ticket about to be declared ready is read a second time under a different question - what in this text admits two readings that would produce different software - and if the two reads disagree, the union of their questions is asked and the ticket goes back to its reporter.
And a handful of checks are computed in shell rather than asked of the model at all, because a model asked "did you check for this?" can answer yes when it did not, and a check that reads the code itself cannot.

In the default fixture mode no model is called.
The verdicts are canned, which is what makes the demo above run offline in a second.
That also means it tells you the machinery works and nothing at all about the prompt - `golden/run.sh --refiner claude` is what measures a prompt.

## Commands worth knowing

| Command | What it is for |
|---|---|
| `bin/orc-daemon.sh` | one pass over everything that changed; drop `--once` to leave it running as a loop |
| `bin/orc-cycle.sh` | the full four-step pass: refine, read the answers people gave, rank what could not be resolved, redraft the knowledge bundle |
| `bin/orc-check.sh` | runs the project's own guarantees as assertions, plus shellcheck; run it after any change under `bin/` |
| `bin/orc-verify.sh` | the review queue - what is waiting for a human to sign off, and how to sign it |
| `bin/orc-onboard.sh` | point it at a real GitHub organisation: propose repositories, write the config you select, draft a first bundle |

There are ten more scripts, each doing one thing.
`bin/orc-refine.sh ORC-101` judges a single ticket, `bin/orc-repos-sync.sh` keeps the clones current, `bin/orc-reconcile.sh` rebuilds local state from Jira, `bin/orc-reset.sh` clears the caches, `bin/orc-jira-poll.sh` lists what changed, `bin/orc-repos-discover.sh` proposes a config, `bin/orc-okf-draft.sh` drafts the bundle, `bin/orc-harvest.sh` reads replies to the questions, `bin/orc-gap-loop.sh` ranks the words nothing could explain, and `bin/orc-locality-score.sh` scores how well it guesses files.
Most of them print their own `--help`.

## Going from fixtures to real Jira

There are three modes, and writing needs two switches rather than one.

| `ORC_JIRA_MODE` | Reads | Writes | Needs |
|---|---|---|---|
| `fixture` (default) | canned tickets in `fixtures/` | printed, never sent | nothing |
| `dry-run` | your real Jira | printed, never sent | credentials |
| `live` | your real Jira | sent, **and only if `DRY_RUN=0` as well** | credentials |

**A write happens only when `ORC_JIRA_MODE=live` and `DRY_RUN=0`.**
Being in live mode is not enough, and setting `DRY_RUN=0` is not enough.
Both default to safe, and `bin/orc-check.sh` verifies all four combinations on every run.

Dry-run against your real instance is the step to take before live, and it is not a formality:

```sh
cp config/.env.example config/.env
$EDITOR config/.env          # base url, email, API token, project key
ORC_JIRA_MODE=dry-run bin/orc-daemon.sh --once
```

Real tickets are read, real verdicts are reached, nothing is written.
Create five tickets of deliberately varying quality first and read what it would have posted.
If its verdicts do not match your own judgement, nothing you build on top of it is worth building yet, and you will have found that out for the price of five tickets.

Then, once the dry run reads well:

```sh
ORC_JIRA_MODE=live DRY_RUN=0 bin/orc-daemon.sh --once
```

Authenticate as a service account rather than as yourself.
Otherwise every automated comment appears to have been written by whoever's credentials it borrowed.

`config/.env.example` lists the settings and what each one does.
Anything already in your environment wins over anything in that file, so the command lines above mean what they say whatever the file holds.

Two settings are worth knowing before you start:

- `LABEL_OPT_IN` - empty by default, which means every ticket in the project is in scope. Set it to a label and only cards carrying that label are polled. Nothing here ever adds or removes it, so which cards are in scope stays a person's decision.
- `JIRA_PROJECT` - which project to poll.

## Where the answers come from

Refinement answers as much as it can itself, and only asks about what nothing can tell it.
It has two places to look.

**Your code.** `config/projects.yml` names your repositories, their default branch and their remote, and `bin/orc-repos-sync.sh` keeps a read-only clone of each under `clones/`.
`bin/orc-onboard.sh` writes that config for you from a GitHub organisation.

**A knowledge bundle**, in `.okf/` - a small set of markdown files holding the product knowledge that is written down nowhere in the code: what people call each screen, who is allowed to decide what, which repository owns which decision.
The code cannot answer "the case list is broken", because nothing in it records that the people filing tickets say "the case list" and mean one specific screen out of three.

No bundle ships with this repository, because a bundle is knowledge about one organisation's product.
`bin/orc-onboard.sh` drafts a first one by reading your repositories; `bin/orc-okf-draft.sh` redrafts it when the code moves.
A bundle file looks like this - the format is [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog), which is plain markdown with a frontmatter header:

```markdown
---
type: Subsystem
title: dashboard
description: Vue single-page app - renders the case a doctor is working on.
resource: https://github.com/example/dashboard
tags: [drafted, subsystem, vue]
status: draft
generated:
  by: bin/orc-okf-draft.sh
  at: 2026-08-14T09:12:00Z
sources:
  - id: dashboard-tree
    title: dashboard, on the branch it releases from
    resource: https://github.com/example/dashboard/tree/main
---

# Overview

**Drafted, not verified.** Everything below was read out of the repository by
`bin/orc-okf-draft.sh`; nobody has checked it. Treat a claim here as a lead, not
as a fact, until this concept carries a `verified:` date.

# What it does not own

| Not here | Where it is instead |
|---|---|
| Eligibility rules | api |
| Push notifications | api, mobile |

# What this draft could not determine

Whether the follow-up wizard in the mobile app shares this component.
```

The negative half is the half that earns its place.
"The dashboard does not decide eligibility, the API does" is what stops a wrong file list, and a concept that names what it could not work out gives a person a question to answer instead of reading as complete.

The important line is `generated:`.
**A fact starts as a draft, and it only counts as knowledge once a person has signed it.**
A drafted fact carries `generated:` and no `verified:`, and refinement is told to treat it as a lead to confirm rather than as something to quote.
`bin/orc-verify.sh queue` lists what is waiting to be signed and `bin/orc-verify.sh verify <id> --agree` signs it, after printing the whole thing first.
Nothing is ever signed that was not displayed, and no flag removes the display: a queue you could sign by number alone is one stale index away from putting somebody's name on a fact they never read.
A signed concept is never overwritten by a redraft, and there is no flag that changes that: replacing a fact a person checked with one nobody has is a downgrade wearing the costume of an update.

There are three worked examples of bundle files, unfilled, in `examples/okf/`.

## Requirements

- bash 3.2 or later - what macOS ships, so no coreutils are assumed
- `git`, `curl` and [`jq`](https://jqlang.github.io/jq/)
- for live and dry-run mode: a Jira Cloud account and an Atlassian API token
- for judging with a real model rather than canned verdicts: the [Claude Code](https://claude.com/claude-code) CLI on `PATH`
- optional: [`gh`](https://cli.github.com/) for `bin/orc-onboard.sh`, the `okf` gem for bundle linting and the knowledge graph, `shellcheck` for `bin/orc-check.sh`

Fixture mode needs none of the optional ones and no network.

## Limits, and what it deliberately does not do

- **It never writes code**, and it never runs anything from your repositories.
- **The only write it makes to a clone is a fast-forward.** Never a force, a reset, a stash or a checkout. A clone that is dirty, detached or diverged is reported and left exactly as it was found. It reports repositories; it does not repair them.
- **It never writes a ticket's description.** The rewritten description is offered on the comment for a person to copy across, and the four things a refinement may touch are the comment, the label, the assignee and the duplicate link.
- **No dispatch, no sandboxes, no implementation agents.** Judging a ticket is the whole scope.
- **No webhooks.** It polls.
- **No personal data in the fixtures.** Every person, clinic and case in them is invented.

State is disposable for the phase and the verdict name.
It is not disposable for the reasoning behind either: `bin/orc-reconcile.sh` rebuilds `state/` from the comments and labels in Jira, but only the phase and verdict name come back, and locality, files, subsystems and `terms_resolved` are exactly as unrebuildable as anything else a `needs_input` comment deliberately does not carry.
Re-deriving those means judging the ticket again, under whatever prompt is current.
Two things therefore live outside the caches and are not gitignored, because they are the only copy of what they hold: `data/gaps.jsonl`, the words refinement could not resolve, and `data/verifications.jsonl`, one line per decision a person made.

Honest about what is unproven: several of the things the refinement prompt is asked to notice have never been shown to work against a real ticket whose gaps nobody planted.
The shipped example scored set holds 23 distinct unresolved terms and clears no bar at all, which is the measurement working rather than the loop failing.
Treat a claim about what the prompt notices as unproven until it has been run against tickets whose gaps nobody planted.

## Digging deeper

- `golden/README.md` - the golden set: tickets with a human's verdict, run on every prompt change like a test suite.
- `fixtures/README.md` - the example tickets, and how to edit them.
- `prompts/refine.md` - the prompt itself. It is the product: a change to it is a change to what the tool decides, so `golden/diff.sh` measures one version against another before it is kept.
