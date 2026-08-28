---
type: Domain
title: Product overview
description: What the product is, who uses it, and what people call each surface when they are not being precise.
tags: [example, unfilled, refinement]
status: draft
---

# This is an example, and it is not filled in

Nothing below is a fact about your product.
Copy this file to `.okf/domain/product-overview.md`, rewrite it, and delete this
section.
It carries no `verified:` date and no `generated:` block, which is what keeps it
out of the drafter's way and keeps refinement from quoting it.

# What belongs in this file

The join between the words a ticket is written in and the repositories that
exist.

A ticket says "the app is showing the wrong price".
`config/projects.yml` knows there is a repository called `mobile` on branch
`main`.
Nothing anywhere connects those two sentences, and no artefact in any repository
can: the string catalogues hold the product's phrases, the schema holds its
rules, and neither of them records that the people filing tickets say "the app"
and mean one specific surface out of three.

So this file needs, and needs little else:

- One paragraph on what the product does and who pays for it.
- Every surface a ticket could be about, with **the names people actually use**
  beside the name you would put in a slide. Include the wrong ones and the
  informal ones. Those are the ones that arrive in tickets.
- For each surface, who uses it. Not permissions - see
  `domain/roles-and-decisions.md` for those - just which kind of person opens it.
- The phrases that fit more than one surface, said plainly. This is the most
  valuable part of the file, because it is what turns a confident wrong answer
  into a question.

# One worked example

The product below is **Rentworks**, a tool and equipment rental company that does
not exist. It is here to show the shape and the level of detail. Replace all of
it.

> Rentworks rents tools and site equipment to trade businesses and to the public,
> out of staffed depots. A customer reserves an item, collects it, returns it,
> and pays a deposit that is released on return.
>
> **Three surfaces.**
>
> - **The customer app.** Reserving, collecting, returning, paying. Reporters
>   call it "the app", "the customer app" and occasionally "the booking app".
>   Used by the renting customer and by nobody else.
> - **The depot dashboard.** Counter work: handing an item over, taking it back,
>   deciding a deposit. Called "the dashboard", "the depot dashboard" and, by
>   support, "the backend", which it is not. Used by depot clerks and depot
>   managers.
> - **The API.** No human opens it. It carries the rules both of the above obey,
>   and it is what the CRM talks to.
>
> **Phrases that fit more than one surface.** A ticket using one of these has
> not yet said which surface it is about, and asking is the right move:
>
> - "the booking list" exists on both the app and the dashboard, and they show
>   different things.
> - "the return screen" exists on both.
> - "the notification" could be the push the app receives or the counter alert
>   the dashboard shows.
> - "the price" is calculated in the API and displayed by both, so "the price is
>   wrong" is a defect on one of three surfaces.

# What to leave out

- **Paths, class names, tables, endpoints.** Every one of them is drafted
  already, by `bin/orc-okf-draft.sh`, from evidence that cannot go stale without
  the code changing. A path written here goes stale silently and is then quoted
  in a verdict.
- **Which repository a surface is.** That is the `subsystem:` join in
  `config/projects.yml` and the drafted `subsystems/` concepts. This file names
  surfaces in product words; the mapping to code is mechanics.
- **Anything you are unsure of.** A surface you left out is a question
  refinement asks a reporter, which is a good outcome. A surface described wrongly
  is a confident wrong file list, which is the expensive one.
- **A count, a figure or a percentage** unless somebody is going to verify this
  file and keep it verified. Prose about how the product works ages slowly.
  Numbers age immediately.

# What this file could not determine

Delete this heading when you fill the file in, or better, keep it and say what
you left open.
Every drafted concept in the bundle carries one, because a concept that names
its hole gives the next reader a question to answer, and one that fills the space
reads as complete and gives them nothing.
