---
paths:
  - "**/components/**"
  - "**/app/**/*.tsx"
---

<!-- SETUP (reference stack: React + Tailwind 4 + shadcn/ui): adapt or
delete to match your UI layer. Replaces the core `ui.md` when installed;
keep one. The copy-style items are a preference. -->

# Components

UI layer. shadcn/ui + Tailwind + React.

## Conventions

- Use shadcn primitives from `components/ui/`. Don't reimplement.
- New shadcn components install via `pnpm dlx shadcn@latest add <name>`.
- Tailwind design tokens live in your global stylesheet under `@theme`.
  Use tokens before adding raw hex.
- Brand color: `<--color-primary, your hex>`.
- Use `next/image` for image assets. Don't reach for raw `<img>`.
- Memoize only when the profiler shows a problem. Premature memoization
  costs more than it saves.
- For lists over 100 rows, virtualize or paginate on the server.

## Loading is a state, not an absence

Gate on an explicit load signal, never on emptiness. If a component
branches on `!value` / `length === 0` / `?? null` while its fetch is
still in flight, it treats "not loaded" as "empty": saves silently
no-op, controls lock during background refreshes, dialogs flash open
and shut. Track which record the loaded state belongs to (a ref, not an
object in a deps array), and lock only the fields that failed to load.

## Mobile is part of the change

Check every change at phone width and say what it does there. A bare
`grid` sizes its implicit column to max-content and pushes children out
of the viewport; use `grid-cols-*` plus `min-w-0` on items. An ancestor
`overflow-hidden` hides an overflow from every viewport-width assertion
while silently amputating content; walk inside it. Horizontal page
scroll is always a bug.

## User-facing copy rules

These apply to every user-visible string: buttons, headings, body copy,
toasts, error messages, empty states, email subjects.

- Brand name spelled exactly right every time. <State the exact casing.>
- Copy describing which cases a number includes states the RULE, never
  a sample; the noun matches the filter.
- Avoid em dashes, en dashes, and hyphens-as-punctuation. Reword with
  periods, commas, parentheses, or colons. <Delete if you do not care.>
- No emojis in email subjects (encoding corruption). Body emojis are
  case-by-case, default off.
- No corporate filler. Say what you need to say.

## Dates

All date display goes through helpers in `@/lib/date`. Never call
`new Date(str).toLocaleDateString()` or
`new Date().toISOString().slice(0, 10)` inline. See the Dates section in
`CLAUDE.md` for why and which helper to use.

## Accessibility

- Every interactive element has `aria-label` or visible text.
- Color contrast: 4.5:1 minimum for text.
- Focus rings are mandatory. Don't disable `:focus-visible`.
- Keyboard navigation works for every interactive flow. Test with
  Tab / Shift+Tab / Enter / Escape.

## Forms

- Use `react-hook-form` + `zod`. Schemas live near the form.
- Submit handlers POST to your API routes via `fetch`.
- Show validation errors inline at the field, not as a toast.
- Disable the submit button while in-flight to prevent double-submits.
