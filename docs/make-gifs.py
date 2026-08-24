"""Render the senior-mode README GIFs: scripted terminal sessions that show
one mechanism each. Frames are drawn with Pillow; every hook banner is the
verbatim deny/nudge text from the hook scripts, and the Claude turns are
what the doctrine asks for.

Usage:  python docs/make-gifs.py docs [keyframe_dir] [name ...]
        (writes docs/launch.gif, docs/pipe.gif, docs/push-gate.gif,
         docs/parallel.gif, docs/prompting.gif, docs/starter.gif;
         pass names to re-render a subset, e.g. `docs "" starter`)

Requires Pillow. Font paths below are Windows (Cascadia Mono + Segoe UI
Symbol); swap for any monospace + symbol font elsewhere. Set REPO_URL to
your repo before regenerating starter.gif.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

REPO_URL = "https://github.com/maxwynndev/senior-mode"

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "docs"
KEY_DIR = sys.argv[2] if len(sys.argv) > 2 else None
os.makedirs(OUT_DIR, exist_ok=True)
if KEY_DIR:
    os.makedirs(KEY_DIR, exist_ok=True)

FONT_PX, LINE_H = 16, 24
FONT = ImageFont.truetype("C:/Windows/Fonts/CascadiaMono.ttf", FONT_PX)
SYM = ImageFont.truetype("C:/Windows/Fonts/seguisym.ttf", FONT_PX)
SYM_CHARS = set("✔✎●→✘")

BG, CHROME, PANE_BAR = (13, 17, 23), (22, 27, 34), (18, 23, 30)
FG, DIM, WHITE = (201, 209, 217), (110, 118, 129), (240, 246, 252)
GREEN, AMBER, ORANGE = (63, 185, 80), (227, 179, 65), (240, 136, 62)
RED, BLUE = (248, 81, 73), (88, 166, 255)


def seg(text, color=FG):
    return (text, color)


# ------------------------------------------------------------ script DSL
class Script:
    """Collects events. Pane 0 is the only pane unless split=True."""

    def __init__(self, name, title, width=960, height=520, split=None):
        self.name, self.title, self.W, self.H = name, title, width, height
        self.split = split  # None or (left_title, right_title)
        self.events = []

    def line(self, segs, hold=140, pane=0):
        self.events.append(("line", pane, segs, hold))

    def typed(self, prefix, text, color=WHITE, ms=38, pane=0):
        self.events.append(("type", pane, prefix + [seg(text, color)], ms))

    def hold(self, ms):
        self.events.append(("hold", 0, None, ms))

    def blank(self, hold=80, pane=0):
        self.line([seg("")], hold, pane)

    def key(self, name):
        self.events.append(("key", 0, name, 0))

    # convenience: a shell line run by Claude, and a user prompt
    def sh(self, cmd, hold=600, pane=0):
        self.line([seg("  $ ", GREEN), seg(cmd, FG)], hold, pane)

    def prompt(self, text, ms=38, pane=0):
        self.typed([seg("> ", BLUE)], text, ms=ms, pane=pane)
        self.hold(450)

    def claude(self, first, rest=(), hold=240, pane=0):
        self.line([seg("● ", ORANGE), seg(first, FG)], hold, pane)
        for r in rest:
            self.line([seg("  " + r, FG)], hold, pane)

    def hook(self, event, script, decision, lines, hold=1400, pane=0):
        tag = "deny" if decision == "deny" else decision
        col = RED if decision == "deny" else AMBER
        self.line([seg(f"[{event}] ", AMBER), seg(script, DIM), seg("  →  ", DIM), seg(tag, col)], 260, pane)
        for i, l in enumerate(lines):
            self.line([seg("  " + l, FG)], hold if i == len(lines) - 1 else 170, pane)


# --------------------------------------------------------------- renderer
def glyph_font(c):
    return SYM if c in SYM_CHARS else FONT


def draw_text(d, x, y, s, color):
    for c in s:
        f = glyph_font(c)
        d.text((x, y), c, font=f, fill=color)
        x += FONT.getlength("M") if f is SYM else f.getlength(c)
    return x


def text_width(segs):
    return sum(FONT.getlength("M") if c in SYM_CHARS else FONT.getlength(c) for t, _ in segs for c in t)


def render(sc, bufs, cursor_pane=None):
    im = Image.new("RGB", (sc.W, sc.H), BG)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, sc.W, 40], fill=CHROME)
    for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([16 + i * 22, 14, 28 + i * 22, 26], fill=col)
    d.text(((sc.W - FONT.getlength(sc.title)) / 2, 11), sc.title, font=FONT, fill=DIM)

    panes = 2 if sc.split else 1
    pane_w = sc.W // panes
    top = 52
    if sc.split:
        d.rectangle([0, 40, sc.W, 68], fill=PANE_BAR)
        for i, t in enumerate(sc.split):
            d.text((i * pane_w + 20, 46), t, font=FONT, fill=DIM)
        d.line([pane_w, 40, pane_w, sc.H], fill=CHROME, width=2)
        top = 80
    visible_n = (sc.H - top - 14) // LINE_H

    for p in range(panes):
        x0 = p * pane_w + 20
        visible = bufs[p][-visible_n:]
        y = top
        for segs in visible:
            x = x0
            for text, color in segs:
                x = draw_text(d, x, y, text, color)
            y += LINE_H
        if cursor_pane == p and visible:
            x = x0 + text_width(visible[-1])
            d.rectangle([x + 2, y - LINE_H + 3, x + 10, y - 4], fill=FG)
    return im


def build(sc):
    panes = 2 if sc.split else 1
    bufs = [[] for _ in range(panes)]
    frames, durs = [], []

    def emit(im, ms):
        frames.append(im)
        durs.append(ms)

    for kind, pane, payload, ms in sc.events:
        if kind == "line":
            bufs[pane].append(payload)
            emit(render(sc, bufs), ms)
        elif kind == "type":
            prefix, (text, color) = payload[:-1], payload[-1]
            bufs[pane].append(prefix + [seg("", color)])
            emit(render(sc, bufs, cursor_pane=pane), 260)
            step = 2
            for i in range(step, len(text) + step, step):
                bufs[pane][-1] = prefix + [seg(text[:i], color)]
                emit(render(sc, bufs, cursor_pane=pane), ms * step)
        elif kind == "hold":
            emit(render(sc, bufs), ms)
        elif kind == "key" and KEY_DIR:
            render(sc, bufs).save(os.path.join(KEY_DIR, f"{sc.name}-{payload}.png"))

    pal = frames[0].convert("P", palette=Image.ADAPTIVE, colors=64)
    q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    out = os.path.join(OUT_DIR, f"{sc.name}.gif")
    q[0].save(out, save_all=True, append_images=q[1:], duration=durs, loop=0, optimize=True, disposal=1)
    print(f"{sc.name}.gif  frames={len(frames)}  {sum(durs)/1000:.1f}s  {os.path.getsize(out)/1024:.0f}KB")


# ================================================================ scripts
CHECKLIST = "Senior-Checklist: ambiguity=pass summary=pass concurrency=n/a regression=pass blast=green"


def launch():
    s = Script("launch", "senior-mode  ·  the senior checks fire at the decision moment, not in the system prompt", 960, 600)
    s.line([seg("$ ", GREEN), seg("claude", WHITE)], 500)
    s.blank(300)
    s.prompt("fix the invoice total showing $0 after save", ms=42)
    s.blank(60)
    s.line([seg("[SENIOR CHECK | BEFORE]", AMBER), seg("  hook: senior-check-before.sh", DIM)], 200)
    s.line([seg("  (1) ambiguous in a way that changes production behavior? ASK before coding")], 160)
    s.line([seg("  (2) name the 100% version so the 80% gap is visible to the user")], 160)
    s.line([seg("  (3) evidence before code; never cite a source you have not opened")], 900)
    s.key("before")
    s.blank(60)
    s.claude('"After save" has two readings that need different fixes:', [
        "  a) the server recomputes the total on save and returns 0 (money-path bug)",
        "  b) the server is right; the UI shows $0 while it refetches (loading-state bug)",
    ], hold=230)
    s.line([seg("  Which one? The response body of POST /api/invoices/42 would settle it.")], 1900)
    s.key("question")
    s.blank(120)
    s.prompt("b. API returns 1250, the page shows $0 for a second then flips", ms=34)
    s.blank(60)
    s.line([seg("● ", ORANGE), seg("[BEFORE-AUDIT]", WHITE)], 240)
    s.line([seg("  Diagnosis: InvoiceSummary treats total===undefined as 0 during refetch")], 200)
    s.line([seg("             src/components/InvoiceSummary.tsx:41  `total ?? 0`", DIM)], 200)
    s.line([seg("  Missing evidence: none load-bearing; reproduced with a 500ms network throttle")], 200)
    s.line([seg("  100% version: gate on isLoading, fix formatMoney(undefined), regression test")], 200)
    s.line([seg("  Senior would reject if: the fix hides the loading state instead of showing it")], 200)
    s.line([seg("  Action: "), seg("ship", GREEN)], 700)
    s.blank(60)
    s.line([seg("  ✎ ", BLUE), seg("src/components/InvoiceSummary.tsx"), seg("   +6 -1", DIM)], 320)
    s.line([seg("  ✎ ", BLUE), seg("src/lib/money.ts"), seg("   +3 -0", DIM)], 320)
    s.line([seg("  ✎ ", BLUE), seg("src/components/__tests__/InvoiceSummary.test.tsx"), seg("   new", DIM)], 320)
    s.sh("pnpm test", 700)
    s.line([seg("    ✔ 12 passed", GREEN), seg("   (1.9s)", DIM)], 900)
    s.blank(60)
    s.line([seg("[SENIOR CHECK | AFTER]", AMBER), seg("  hook: senior-check-after.sh  →  decision: block", DIM)], 220)
    s.line([seg("  (3) for every green you are about to report: what would RED have looked like,")], 180)
    s.line([seg("      and could this run have produced it? a detector that cannot fail proves nothing")], 1400)
    s.key("after")
    s.blank(60)
    s.line([seg("● ", ORANGE), seg("Caught one. ", WHITE), seg("12 passed before my change and 12 passed after: the new test")], 320)
    s.line([seg("  never ran. vitest.config includes tests/**, not src/**/__tests__. It read as")], 240)
    s.line([seg("  coverage and was not.")], 700)
    s.line([seg("  ✎ ", BLUE), seg("tests/components/InvoiceSummary.test.tsx"), seg("   moved", DIM)], 320)
    s.sh("pnpm test", 700)
    s.line([seg("    ✔ 13 passed", GREEN), seg("   (2.0s)   was 12: the new test is reachable now", DIM)], 1200)
    s.blank(60)
    s.claude("Done. Loading state gated on isLoading; formatMoney handles undefined;", [
        "regression test runs. Not done: the server-side total (reading a) was not",
        "touched, since the API was shown to be correct.",
    ])
    s.hold(3000)
    s.key("final")
    return s


def pipe():
    s = Script("pipe", "exit-code-mask-guard.sh  ·  a pipe hides an exit code", 960, 470)
    s.prompt("watch the CI run for that push and tell me if it's green", ms=34)
    s.sh("gh run watch 17234 --exit-status | tail -5", 500)
    s.hook("PreToolUse", "exit-code-mask-guard.sh", "deny", [
        "BLOCKED: piping a CI watcher masks the run's exit code with the pipe's last",
        "command (a red run reads as exit 0). Use the redirect recipe instead:",
        '  gh run watch <id> --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"',
        "  gh run view <id> --json status,conclusion",
        "The conclusion field is the fact: success is green; cancelled, skipped, and null are NOT.",
    ], hold=1800)
    s.key("deny")
    s.sh('gh run watch 17234 --exit-status > watch.log 2>&1; echo "WATCH_EXIT=$?"', 900)
    s.line([seg("    WATCH_EXIT=1", RED)], 700)
    s.sh("gh run view 17234 --json status,conclusion", 700)
    s.line([seg('    {"status":"completed","conclusion":"failure"}', FG)], 900)
    s.blank(60)
    s.line([seg("● ", ORANGE), seg("RED. ", RED), seg("typecheck failed in apps/web (watch.log:212). Through the pipe this run")], 260)
    s.line([seg("  would have reported exit 0 and I would have told you it was green. Not pushing;")], 260)
    s.line([seg("  fixing forward.")], 2800)
    s.key("final")
    return s


def push_gate():
    s = Script("push-gate", "pre-push-checklist.sh  ·  the one irreversible action gets a deliberate check", 960, 560)
    s.prompt("push it", ms=50)
    s.sh("git push origin main", 500)
    s.hook("PreToolUse", "pre-push-checklist.sh", "deny", [
        "Push blocked: HEAD commit missing Senior-Checklist trailer.",
        "Amend the commit to add a trailer line at the bottom:",
        "  " + CHECKLIST,
        "Grades per key: pass | miss | n/a (blast also accepts green | red).",
    ], hold=1500)
    s.key("deny")
    s.blank(60)
    s.claude("Running the checklist before I amend, not after:", hold=300)
    rows = [
        ("ambiguity  ", "pass ", "one reading; confirmed against the API response in turn 2"),
        ("summary    ", "pass ", "user-facing summary drafted; it names what was NOT touched"),
        ("concurrency", "n/a  ", "pure UI + formatter; no shared writers"),
        ("regression ", "pass ", "tests/components/InvoiceSummary.test.tsx, runner-reachable"),
        ("blast      ", "green", "UI only; rollback is the previous deploy, one click"),
    ]
    for k, g, why in rows:
        s.line([seg("    " + k + "  "), seg(g, GREEN if g.strip() != "n/a" else DIM), seg("  " + why, DIM)], 330)
    s.hold(500)
    s.sh('git commit --amend -q -m "fix: invoice total loading state" \\', 300)
    s.line([seg('        -m "' + CHECKLIST + '"', FG)], 900)
    s.sh("git push origin main", 700)
    s.line([seg("    a3f9c21..7be04d0  main -> main", GREEN)], 800)
    s.blank(60)
    s.claude("Pushed. Ten seconds of friction on the one action that cannot be undone.")
    s.hold(2600)
    s.key("final")
    return s


def parallel():
    s = Script("parallel", "session-registry.sh + session-tree-guard.sh  ·  two sessions, one checkout, no tangle",
               1200, 600, split=("session 1  ·  ~/work/app  (incumbent)", "session 2  ·  ~/work/app  (opened 4 min later)"))
    L, R = 0, 1
    s.line([seg("$ ", GREEN), seg("claude", WHITE)], 300, L)
    s.line([seg("[PARALLEL SESSIONS] ", AMBER), seg("You are the only session in", FG)], 150, L)
    s.line([seg("this checkout (branch main). No tangle risk.", FG)], 600, L)
    s.prompt("add CSV export to the invoices page", ms=30, pane=L)
    s.line([seg("● ", ORANGE), seg("[BEFORE-AUDIT] ", WHITE), seg("… Action: ", FG), seg("ship", GREEN)], 400, L)
    s.line([seg("  ✎ ", BLUE), seg("src/app/invoices/export.ts"), seg("   new", DIM)], 300, L)
    # session 2 arrives
    s.line([seg("$ ", GREEN), seg("claude", WHITE)], 300, R)
    s.line([seg("[PARALLEL SESSIONS] ", AMBER), seg("CONCURRENT SESSION IN THIS", FG)], 150, R)
    s.line([seg("CHECKOUT. You are 1 of 2 live sessions in ~/work/app", FG)], 150, R)
    s.line([seg("and you are NOT the incumbent. Two sessions committing", FG)], 150, R)
    s.line([seg("in one checkout is exactly what tangles the working", FG)], 150, R)
    s.line([seg("tree. Before any commit, run /worktree to isolate.", FG)], 900, R)
    s.key("nudge")
    s.prompt("fix the date rollover on the dashboard", ms=30, pane=R)
    s.line([seg("  ✎ ", BLUE), seg("src/app/invoices/page.tsx"), seg("   +14 -2", DIM)], 300, L)
    s.line([seg("  ✎ ", BLUE), seg("src/lib/date.ts"), seg("   +4 -1", DIM)], 300, R)
    s.sh("pnpm test", 500, L)
    s.line([seg("    ✔ 41 passed", GREEN)], 400, L)
    s.sh('git commit -m "fix: dashboard date rollover"', 500, R)
    s.hook("PreToolUse", "session-tree-guard.sh", "deny", [
        "Tangle guard: BLOCKED. 1 other live Claude session",
        "shares this checkout (~/work/app) and you are NOT",
        "the incumbent. Run /worktree to isolate first.",
    ], hold=1400, pane=R)
    s.key("blocked")
    s.sh('git commit -m "feat: invoice CSV export"', 500, L)
    s.line([seg("    [main 9c1e2af] feat: invoice CSV export", GREEN)], 600, L)
    s.claude("Isolating first.", hold=300, pane=R)
    s.sh("/worktree dashboard-date", 700, R)
    s.line([seg("    ✔ ", GREEN), seg("../app-dashboard-date  branch dashboard-date", FG)], 200, R)
    s.line([seg("      off origin/main; this session now lives there", DIM)], 800, R)
    s.sh('git commit -m "fix: dashboard date rollover"', 500, R)
    s.line([seg("    [dashboard-date 4d7a0b3] fix: dashboard date rollover", GREEN)], 800, R)
    s.claude("Committed on my own tree. To ship: rebase onto", ["origin/main and push HEAD. Session 1 was never", "touched."], hold=260, pane=R)
    s.hold(3000)
    s.key("final")
    return s


def prompting():
    s = Script("prompting", "PROMPT-STANDARD  ·  calibration, not nagging", 960, 560)
    s.prompt("where is the KPI row on the dashboard defined?", ms=30)
    s.claude("src/app/dashboard/page.tsx:88, the KpiRow component (src/components/KpiRow.tsx).", hold=1200)
    s.blank(60)
    s.prompt("make the dashboard better", ms=55)
    s.claude("Below standard for a build prompt: 3 of 5 elements missing, so I'm stopping", [
        "before I touch anything.",
    ], hold=300)
    s.line([seg("    GOAL      ", AMBER), seg("what is wrong with it? slow, wrong numbers, layout, all three?")], 300)
    s.line([seg("    EVIDENCE  ", AMBER), seg("which page, which component, a screenshot or a symptom")], 300)
    s.line([seg("    OUTPUT    ", AMBER), seg("plan first, or go fix it?")], 300)
    s.line([seg("    STOP      ", AMBER), seg("what does done look like?")], 500)
    s.line([seg("  Best guess: the KPI row clipping at phone width (KpiRow.tsx:31, fixed min-width).")], 260)
    s.line([seg("  Confirm or revise; I'll wait.")], 2000)
    s.key("stop")
    s.blank(60)
    s.prompt("yes, the KPI row clips at phone width. fix it, no new files, done when it", ms=26)
    s.line([seg("  matches figma-kpi-mobile.png at 390px", WHITE)], 500)
    s.claude("5 of 5. Going.", hold=500)
    s.line([seg("  ✎ ", BLUE), seg("src/components/KpiRow.tsx"), seg("   +9 -3", DIM)], 400)
    s.sh("pnpm exec playwright test kpi --project=mobile", 800)
    s.line([seg("    ✔ 3 passed", GREEN), seg("   screenshot matches figma-kpi-mobile.png at 390px", DIM)], 800)
    s.blank(60)
    s.claude("Q&A passes through. A vague build prompt stops once, with a best guess. A", [
        "complete brief runs to the stop condition without check-ins.",
    ])
    s.hold(3000)
    s.key("final")
    return s


def starter():
    s = Script("starter", "starter/  ·  five minutes to a coding agent that checks its own work", 960, 560)
    s.line([seg("$ ", GREEN), seg(f"git clone {REPO_URL}", WHITE)], 700)
    s.line([seg("$ ", GREEN), seg("bash senior-mode/starter/install.sh", WHITE)], 600)
    s.line([seg("senior-mode starter -> /home/you/.claude", FG)], 200)
    for f in ["CLAUDE.md", "PROMPTING-CLAUDE-CODE.md", "ENGINEERING-PRINCIPLES.md", "settings.json",
              "hooks/senior-check-before.sh", "hooks/senior-check-after.sh", "commands/review.md"]:
        s.line([seg("  write  ", DIM), seg("~/.claude/" + f, FG)], 130)
    s.line([seg("Done. Open any repo in Claude Code; the first prompt should show", FG)], 150)
    s.line([seg("[SENIOR CHECK | BEFORE] in context.", FG)], 1200)
    s.key("installed")
    s.blank(60)
    s.line([seg("$ ", GREEN), seg("cd ~/work/app && claude", WHITE)], 700)
    s.prompt("fix the login redirect loop", ms=40)
    s.line([seg("[SENIOR CHECK | BEFORE]", AMBER), seg("  hook: senior-check-before.sh", DIM)], 200)
    s.line([seg("  (1) ambiguous in a way that changes production behavior? ASK before coding")], 900)
    s.claude("Before I touch it: does the loop happen on every login, or only after a", [
        "session expires? The first points at the callback URL (auth/callback.ts:18);",
        "the second at the refresh path (middleware.ts:44). Different fixes.",
    ], hold=260)
    s.hold(3200)
    s.key("final")
    return s


if __name__ == "__main__":
    only = set(sys.argv[3:])  # optional: names of the GIFs to (re)render
    for make in (launch, pipe, push_gate, parallel, prompting, starter):
        sc = make()
        if not only or sc.name in only:
            build(sc)
