---
name: feedback-public-writing-voice
description: Anything public (README, SECURITY.md, commits, PRs, issues, docs, comments) must read as the owner wrote it, not as AI output
metadata:
  type: feedback
---

Anything a stranger reads with the owner's name on it has to sound like the
owner typed it. README, SECURITY.md, commit messages, PR bodies, issues,
release notes, docs, code comments. The recurring complaint is that it reads as
AI-written.

The tells, in the order they show up most:

- **The antithesis flip.** "It is not an assertion, it is the guard." "Not
  prompts, infrastructure." Pick one side and say it straight.
- **"Load-bearing", "the whole point", "by construction", "deliberately", "on
  purpose".** Once per document is fine. Every paragraph is a tell.
- **Aphorisms and maxims.** "A gate nobody has watched fail is not a gate."
  Say what the code does instead.
- **Rule of three for rhythm.** Three clauses, three examples, three short
  sentences in a row.
- **Explaining why something is clever** rather than what it does.
- **Portentous one-line paragraphs** and fragments used for emphasis.
- **"Worth stating plainly", "worth knowing", "the honest version".**

What to do instead: first person on your own projects, contractions, short
declarative sentences, concrete nouns (name the file, the number, the command),
plain verbs. Sounding like an engineer typing quickly is right. Sounding like
an essay is wrong.

**Why:** the owner was handed a README paragraph reading "The load-bearing code
in that suite is not an assertion, it is the guard that runs before them" and
said to stop writing like that, permanently, everywhere public.

**How to apply:** before committing anything public, reread it and cut the
constructions above. Applies on top of [[feedback-copy-style]], which still
bans em dashes, en dashes and hyphens-as-punctuation.
