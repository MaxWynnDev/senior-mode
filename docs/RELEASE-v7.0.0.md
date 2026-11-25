v7: the hooks read the code

Through v6 senior-mode watched how the agent behaved: a test that
never ran, a pipe that hid an exit code, an answer that handed work
back. It never opened the file the agent had just written. v7 does.

After every edit a hook reads the file and blocks on an import that
names nothing, a named import the module doesn't export, a call to
one of your own functions with the wrong number of arguments, and an
index that's always one past the end. JS and TS run on node with a
tokenizer that ships in the kit, so a worktree with no node_modules
gets the same checks. Python runs on the project's own interpreter
and ast. Then your repo's own type checker runs on that one file
inside a 20 second budget.

The commit gate denies a new @ts-ignore, a cast to any, a bare
type: ignore or an eslint-disable with no reason, and a strict flag
turned off. `|| true` after a checker is denied, and so is
`tsc file.ts` beside a tsconfig.

`check.sh` runs the full typecheck and writes a receipt the stop
hook asks for. `boundary-probe.sh` flips each comparison your diff
added and runs the tests, because an off by one has no syntax.
`package-install-guard.sh` looks a new package name up before it
gets installed.

Nothing to install. 287 harness cases on Linux, 278 on macOS, 279
on Windows.

Upgrade: `bash senior-mode/install.sh --upgrade /path/to/your-repo`.
The check arrives through `post-edit-format.sh`, which your install
already wires. The install guard is a new hook entry, so merge the
`.senior-mode` sibling of your settings file.

What I haven't confirmed: what Codex, Copilot, Factory and Devin do
with a post-edit block. On Cursor, Gemini CLI and OpenCode the same
checks run at commit. The full list is in CHANGELOG.md.
