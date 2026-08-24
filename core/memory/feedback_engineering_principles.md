---
name: feedback-engineering-principles
description: The operating doctrine lives in ENGINEERING-PRINCIPLES.md at repo root; the never/always lists are non-negotiable
metadata:
  type: feedback
---

The full engineering doctrine lives in `ENGINEERING-PRINCIPLES.md` at the
repo root. Read it at session start before non-trivial changes. The
never/always lists (sections 3 and 4) are non-negotiable. Section 15 is
the canonical tool catalog (check it before writing your own utility).
Section 12a sets the 400-LOC budget per new file.

**Why:** the user wants me to operate as a senior principal engineer at
top-tier standards. The doctrine lives in-repo so any future session
loads it via CLAUDE.md; this memory pointer ensures continuity even when
CLAUDE.md context is trimmed.

**How to apply:**
- When in conflict with my own habits, the principles doc wins.
- When the doc itself needs to change, write an ADR referencing it.
- Don't restate the principles in chat; refer the user to the file
  (`ENGINEERING-PRINCIPLES.md` section N) when the question is doctrine.
- The 400 LOC rule applies to NEW files; existing god-files are tracked
  and split in their own commits.
- The four-tier refactor risk model (section 13) governs how aggressive
  a single change can be.

Related: [[feedback-senior-engineer-default]].
