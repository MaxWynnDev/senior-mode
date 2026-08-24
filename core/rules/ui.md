<!-- SETUP: stack-neutral UI rule. Scope it with `paths:` frontmatter (e.g.
"src/components/**", "src/app/**/*.tsx", "app/views/**") so it loads only
when UI files are touched. The copy-style items are a preference; delete
what your project does not adopt. The reference stack profile ships a
concrete React + Tailwind version. -->

# UI layer

## Loading is a state, not an absence

Gate on an explicit load signal, never on emptiness. Before branching
on `!value`, `value === ""`, `length === 0`, or `?? null`, ask what the
expression says while the fetch is still in flight. If the answer is
"the same thing it says when the value is genuinely absent", it is the
recurring bug class: a save that silently no-ops, a control that locks
during a background refresh, a dialog that flashes open and shut on
every visit. Track which record the loaded state belongs to; fix the
field that failed to load, not the whole surface.

## Mobile is part of the change

Every UI change is designed and checked at phone width as well as
desktop, and the description of the change says what happens at phone
width. Layouts that stretch or distribute (`h-full`, `flex-1`,
`justify-between`) behave differently when a multi-column grid
collapses to one column; gate them to the breakpoint that wants them.
Fixed widths, `nowrap`, and long unbroken strings (money, emails, URLs)
are the usual overflow sources, and one overflowing element makes the
whole page look zoomed out. Horizontal page scroll is always a bug.

## User-facing copy

- Brand name spelled exactly right every time (CLAUDE.md "Brand").
- Copy that says which cases a number includes states the RULE, never
  a sample: "every order regardless of status, cancelled ones included"
  rather than "pending and paid". A 3-of-4 list reads as exhaustive.
  The noun matches the filter: "earned" means the query filtered for
  earned.
- No corporate filler. No emojis in email subjects (encoding
  corruption).
- Avoid em dashes, en dashes, and hyphens-as-punctuation; reword with
  periods, commas, parentheses, or colons. (Preference; delete if not
  adopted.)

## Dates

Never build a `Date` from a stored bare `YYYY-MM-DD` and format it
(renders yesterday west of UTC), and never derive "today" from
`toISOString().slice(0, 10)` (rolls over early east of UTC). All date
display goes through the project's date helpers (CLAUDE.md "Dates").

## Accessibility and forms

- Every interactive element has `aria-label` or visible text; focus
  rings stay on; keyboard navigation works for every flow (Tab,
  Shift+Tab, Enter, Escape); text contrast 4.5:1 minimum.
- Forms validate with a schema, show field errors inline (not as a
  toast), and disable submit while in flight to prevent double-submits.
- Lists over 100 rows paginate on the server or virtualize.
