---
type: Domain
title: Roles, and who owns which decision
description: The kinds of person who use the product, and who decides the kinds of question refinement has to hand back.
tags: [example, unfilled, refinement]
status: draft
---

# This is an example, and it is not filled in

Nothing below is a fact about your product.
Copy this file to `.okf/domain/roles-and-decisions.md`, rewrite it, and delete
this section.
It carries no `verified:` date and no `generated:` block, which is what keeps it
out of the drafter's way and keeps refinement from quoting it.

# What belongs in this file

Two lists that look unrelated and are not.

**The roles.** Refinement will not call a bug ready without a reproduction that
names the surface, the role and the starting state, so it has to know what the
roles are called before it can notice one is missing. A ticket saying "the user
cannot return the item" has named no role in a product with four of them.

**Who owns which kind of product decision.** Refinement returns `needs_input`
when a question needs product judgment rather than research, and the comment it
writes is read by a person. "Somebody needs to decide whether the deposit is
refunded" is a comment that sits for a week. "This is a decision for the depot
operations lead" is one somebody forwards in a minute.

Note what this file is not: it is not a permissions matrix. Who *may* do what is
in the code, it is drafted from the schema and the enums already, and it goes
stale the moment somebody ships a change. Who *decides* what is in nobody's
repository and changes about once a year.

# One worked example

The product below is **Rentworks**, a tool and equipment rental company that does
not exist. It is here to show the shape and the level of detail. Replace all of
it.

> **Roles, as tickets name them.**
>
> - **The customer.** Rents the item. Called "the customer", "the renter", and in
>   older tickets "the user", which is ambiguous and worth asking about.
> - **The depot clerk.** Hands items over and takes them back at the counter.
>   Called "the clerk" or just "the depot".
> - **The depot manager.** A clerk who can also override a deposit decision and
>   close a rental early.
> - **The support agent.** Sees everything, changes nothing, files most of the
>   tickets. A ticket from support is usually reported second-hand, which is why
>   "in what starting state" so often goes unanswered.
>
> **Who decides.**
>
> | The kind of question | Who answers it |
> |---|---|
> | What the customer app should do, and what it should say | product |
> | What happens at the counter, and what a clerk may override | depot operations |
> | Whether money moves, and what a deposit deduction may be | finance, and it is never product's call |
> | Whether a defect is worth fixing now | the reporter's own team lead |
> | What a term means when the code holds two meanings | product, and this one comes up more than anybody expects |
>
> **Two roles that are one word apart and are not the same.** A clerk and a
> manager see the same screen, and about a fifth of dashboard tickets are only
> reproducible as one of the two. Asking which is almost always worth one of the
> three questions.

# What to leave out

- **Permissions, scopes, roles as the code spells them.** `admin`, `staff`,
  `role_id`. Those are drafted from the enums and the schema, they are checkable
  against the code, and this file cannot be. If you find yourself writing a code
  identifier here, the thing you want is already in `domain/domain-rules.md`.
- **Names of individuals.** "The depot operations lead" survives somebody
  leaving; a name does not, and a bundle is read by a machine that cannot tell a
  stale name from a current one. Name the function.
- **Escalation procedure, on-call, who to page.** True, useful, and not read by
  anything here. Refinement asks a question on a ticket; it does not route an
  incident.
- **Anything you would have to check with somebody before writing.** Ask them
  first, then write it. This file is the one place in the bundle where a guess
  looks exactly like a fact.

# What this file could not determine

Delete this heading when you fill the file in, or better, keep it and say what
you left open.
The most common honest hole here is a kind of decision two teams both believe
they own. Say so. A refiner that knows a question is contested asks it better
than one that picks a side.
