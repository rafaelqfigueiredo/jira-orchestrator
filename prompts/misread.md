# Second pass: the adversarial re-read

Everything above this line described a job you have already done, once. Its
output contract does not apply to this pass, and you are not being asked to
judge the ticket again. Do not return a verdict, a file list, a term record, a
split or a rewritten description. The contract for this pass is at the bottom of
this section and it is the only one you answer.

What you are being asked now is a different question, and it is deliberately not
the one the pass above asks.

That pass asks **what do I still want to know**. This one asks **what in this
text admits two readings that would produce different software**. Those are
different acts. The first one enumerates gaps, and a sentence with no gap in it -
every word defined, every criterion stated, nothing missing - passes it cleanly
while still parsing two ways. The second one goes looking for exactly that
sentence, and it is the only pass that will find it, because there is nothing
absent for the first one to notice.

## What you are given, and why it is the reading you are attacking

Below is the first read's own conclusion: what it decided the ticket asks for,
the criteria it took from it, and whatever split it proposed. That is one
competent implementer's reading of this card, written out.

It is what you are trying to find an alternative to. You are not sampling the
ticket again from nothing - a second guess is worth very little, and this is not
one. You are asking, of a reading that already exists: could somebody just as
careful, with the same ticket and no way to ask anybody, have read it
differently and built something else - and been just as sure they were right?

## The method

Read the ticket as the person who has to build it, on a Monday, with no access
to the reporter and no intention of asking. At every sentence that decides
behaviour, ask whether it decides it.

The shapes that admit two readings, in roughly the order they are missed:

- **Grouping.** A condition listing several things joined by commas and an "or"
  or an "and", where more than one grouping fits the words. Which things
  qualify, and which conditions attach to which of them.
- **Scope of a qualifier.** A phrase - "only", "also", "for the first time",
  "after it is confirmed" - that could attach to the clause beside it or to the
  whole sentence.
- **What a pronoun or a bare noun points at**, when two things in the paragraph
  could be it. "It should then be hidden" - the control, or the whole section.
- **Whether something is a rule or an example.** A list that could be the
  complete set of cases or an illustration of a broader one.
- **Whether a stated behaviour replaces the current one or joins it.** "Show the
  weekend rate" - instead of the day rate, or beside it.
- **Whether a limit is a limit on the thing or on the person.** "Only one per
  rental" - one per rental, or one per customer per rental.
- **What happens in the state the ticket did not picture**, when the ticket's own
  words decide it one way and its evident intent decides it the other.

## The bar has not moved

Every rule of the question bar above applies to anything you produce here, word
for word. The four tests, the product's own words, no path and no field name and
no code of any kind, one sentence asking one thing, answerable by a depot
manager in a line. A question that fails the bar is not asked here either, and
this pass is not a way round it.

One test is added, and it is the one that does the work:

**The two readings must produce different software.** Not a different emphasis,
not a different wording of the same behaviour - a different thing built, that a
reviewer would see. If both readings lead to the same change, the sentence is
not ambiguous in any way that costs anything, and it is not a finding. This is
test three of the bar, sharpened: there, one answer must change what an
implementer does; here, both readings must already describe different work.

And one thing you must not do: do not re-ask what has been settled. The ticket's
own words, the answers people have already given that are written down, and
anything the first read above resolved are all settled. A question this card has
already answered is the fourth test, and it fails here for the same reason it
fails there.

## The expected answer is an empty list

Say so plainly when it is. Most cards that reach this pass are exactly what the
first read said they were: settled, and readable one way only. A pass that finds
something every time is a pass whose findings mean nothing, and the next person
to read one will discount it - which costs the one real finding it was built for.

Do not reach. Do not offer a reading nobody would take in order to have
something to say. If the sentence only parses two ways when it is read
uncharitably, it parses one way.

Equally: if you have found one, do not hold it back because the card looks
finished. The card looking finished is the whole reason this pass exists. A
ticket that reaches here is about to be handed to somebody to build, or carved
into slices drawn around this reading, and that is the most expensive moment in
the loop to be wrong.

## The contract

Reply with exactly one JSON object and nothing else. No prose before or after,
no code fence, no explanation.

```
{
  "misreadings": [
    {
      "quote":       "the ticket's own words that admit both readings, verbatim",
      "reading_taken":  "what the first read built on, in one clause",
      "reading_missed": "what somebody just as careful could equally have built",
      "different_software": "what would actually differ between the two, in one sentence",
      "question":    "one sentence, in the product's own words, naming both readings"
    }
  ]
}
```

`{"misreadings": []}` is the normal answer and is a complete one.

## Written, in practice

A ticket says: "Show the express return only for deposit-free rentals, extended
manually, or weekend rentals with an on-site check = van, trailer, lift or
generator." Everything else about the card is decided - the surface, the role,
four criteria, an out-of-scope list - and the first read returned it ready,
summarising it as "offer the express return to deposit-free rentals that were
extended by hand, and to weekend rentals with one of four checks."

That is one reading. The other is three separate qualifying sets: every
deposit-free rental, any rental extended by hand, and weekend rentals with one
of those checks. The two offer the feature to different customers, and the
second one reaches rentals the first never shows it to. Reading the code settles
nothing, because the express return does not exist yet.

```
{"misreadings": [{
  "quote": "only for deposit-free rentals, extended manually, or weekend rentals with an on-site check = van, trailer, lift or generator",
  "reading_taken": "one qualifying group - deposit-free rentals that were also extended by hand - plus weekend rentals with one of the four checks",
  "reading_missed": "three qualifying groups - every deposit-free rental, any rental extended by hand, and weekend rentals with one of the four checks",
  "different_software": "under the second reading the express return appears on every deposit-free rental, including the ones nobody extended, which the first reading never shows it on",
  "question": "Should the express return show for every deposit-free rental, for any rental extended by hand, and for weekend rentals with one of those four checks - or only for deposit-free rentals that were also extended by hand?"
}]}
```

And a card where the answer is the empty list. A ticket asks for the deposit
figure on the depot dashboard to show the released amount as well as the held
one, states which screen, which role, three criteria and what stays as it is.
There is nothing in it that two people would build differently: one number
becomes two, in a named place, for a named role.

```
{"misreadings": []}
```
