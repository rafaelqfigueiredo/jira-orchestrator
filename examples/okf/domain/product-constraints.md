---
type: Domain
title: Constraints the product works under
description: What the product may not do, and what needs sign-off before it ships, where that rule lives in no repository.
tags: [example, unfilled, refinement]
status: draft
---

# This is an example, and it is not filled in

Nothing below is a fact about your product.
Copy this file to `.okf/domain/product-constraints.md`, rewrite it, and delete
this section.
It carries no `verified:` date and no `generated:` block, which is what keeps it
out of the drafter's way and keeps refinement from quoting it.

# What belongs in this file

The rules a change has to obey that are written down nowhere a repository can be
read for.

Refinement returns `ready` only when an implementation agent could start now and
finish **without asking anybody anything**. A ticket asking for something the
product is not allowed to do fails that bar however well it is specified, and
without this file refinement has no way to notice: the request is clear, the
surface is decided, the acceptance criteria are stated, and it is still not
finishable.

Three kinds of thing, and the third is the one people forget:

- **Hard prohibitions.** Things the product may not do at all. Usually law,
  contract, or a decision taken after something went wrong.
- **Sign-off gates.** Things it may do, once a named function has agreed. These
  do not make a ticket unready on their own; they make it unready when nobody
  has been asked yet and the ticket does not say who will.
- **Rules that read like ordinary product decisions and are not.** A retention
  period, a wording requirement, a thing that must be shown before a button is
  pressed. These are the expensive ones, because a ticket asking to remove one
  looks like a reasonable simplification.

In a regulated setting - medical, financial, anything with an auditor - the
regulatory constraints go here too, and they are usually the majority of the
file. In an unregulated one this file is mostly contract terms and consumer
protection, and it is short. Short is fine. Empty is a claim, so if it is
genuinely empty, say that in the last section rather than leaving the file out.

# One worked example

The product below is **Rentworks**, a tool and equipment rental company that does
not exist. It is here to show the shape and the level of detail. Replace all of
it.

> **Hard prohibitions.**
>
> - A deposit may not be retained without an itemised statement of what it was
>   retained for. A ticket asking for a one-click deduction is not implementable
>   as written, whatever the screen it names.
> - One customer's contact details are never shown to another, on any surface,
>   including in a shared rental.
> - A safety-certified item may not be marked available by any automatic process.
>   A person signs it off, and the person is recorded.
>
> **Sign-off gates.**
>
> | Change | Who signs it off |
> |---|---|
> | Anything altering what a deposit deduction may be | finance |
> | New wording on the rental agreement, in any language | legal |
> | Anything that changes what is retained after a rental closes | legal, and it is not negotiable on a deadline |
>
> **Rules that look like product decisions.**
>
> - The agreement is shown in full before collection, not summarised and not
>   behind a link. A ticket asking to shorten that screen is asking for
>   something that needs legal, and it never says so.
> - A closed rental keeps its photographs for two years. A ticket about the
>   storage bill that proposes deleting them earlier is a legal question wearing
>   an infrastructure hat.

# What to leave out

- **Anything checkable in code.** A validation, a state machine, a constraint the
  schema states. Those are drafted into `domain/domain-rules.md` from the
  evidence itself, they cannot go stale without the code changing, and a second
  copy here can and will disagree with the first.
- **Security practice and internal policy.** Password rules, review requirements,
  who may deploy. All real, none of it changes whether a ticket can be finished.
- **The reasoning.** Say the rule, name who owns it, stop. A paragraph of why
  reads as a case that can be argued with, and a refiner will treat it as one.
- **A citation of a statute you have not read.** If you know the constraint but
  not its source, write the constraint and say the source is unconfirmed. A wrong
  citation is worse than none: it gets quoted.

# What this file could not determine

Delete this heading when you fill the file in, or better, keep it and say what
you left open.
If this product genuinely works under no constraint that a repository does not
already state, write that sentence here and leave the rest of the file empty.
That is a useful thing for the next reader to know, and it is different from
nobody having got around to it.
