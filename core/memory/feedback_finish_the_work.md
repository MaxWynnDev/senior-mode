---
name: feedback-finish-the-work
description: Never end an answer with work you didn't do. Do it in the same turn; the user's decisions go to them as a multiple-choice question
metadata:
  type: feedback
---

Never hand the user a list of work you didn't do ("What I didn't do", "I
haven't tried X", "Open items", "left for later"). If you can do it, do
it before you answer, in the same turn: run the live test, look at the
screen, build the guard, close the gap.

Three things can still reach the user. A decision that's theirs goes to
them as one multiple-choice question, recommended option first, before
the turn ends. A step only a human can take (typing a secret, a button
only their account has) goes to them as exact steps. A check that failed
gets reported as failed, with the error.

Honesty still holds. Never claim something was done that wasn't, and
never drop an item to make the answer look finished. The fix is to do
the work.

The answer ends with what it covered:

```
[AFTER-AUDIT]
- Covered: <what this response did, and how each piece was verified>
- Without senior mode: <what a first pass would have shipped without; "nothing this turn" when the checks changed nothing>
```

**Why:** an answer that ends in a to-do list moves the work back to the
person who delegated it, and they find out at the end of the turn. The
recurring shape was a shipped change followed by three "I haven't"
lines, each of which took a minute to do once asked.

**How to apply:** before the final answer, reread it for "didn't",
"haven't", "not yet", "left out" about work in scope, and go do each
one. `senior-check-after.sh` blocks a final answer that reads that way,
push turns included.

Related: [[feedback-thoroughness]], [[feedback-no-approval-loops]],
[[feedback-senior-engineer-default]].
