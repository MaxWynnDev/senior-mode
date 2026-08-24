# Memory Index

This index is loaded into context each session (first 200 lines / 25KB).
One line per memory; the detail lives in the file. HOOKS, not content:
open the file before working in its domain. Recognising a hook is not
reading the memory.

The `feedback_*` files are working-style preferences that travel with
you across projects. `user_role.md` and any `project_*` / `reference_*`
files are specific to you and this project: fill them in as you go.

- [user_role.md](user_role.md) — who the user is (FILL IN per project)
- [feedback_senior_engineer_default.md](feedback_senior_engineer_default.md) — operate at senior level; self-check before AND after every non-trivial decision; ambiguity trigger
- [feedback_evidence_before_code.md](feedback_evidence_before_code.md) — visible BEFORE-AUDIT block before the first edit; verify the writer before building the reader
- [feedback_never_cite_an_unread_source.md](feedback_never_cite_an_unread_source.md) — never name a source you did not open this session; "found nothing" is complete
- [feedback_thoroughness.md](feedback_thoroughness.md) — prefers comprehensive all-at-once execution, not incremental
- [feedback_no_approval_loops.md](feedback_no_approval_loops.md) — skip design-approval loops on bounded directives; execute fully in one pass
- [feedback_prompt_standard.md](feedback_prompt_standard.md) — enforce the 5-element prompt standard (PROMPT-STANDARD.md) on non-trivial prompts
- [feedback_prompt_engineering_rubric.md](feedback_prompt_engineering_rubric.md) — apply the PROMPTING.md rubric on every Claude API change
- [feedback_engineering_principles.md](feedback_engineering_principles.md) — ENGINEERING-PRINCIPLES.md doctrine; never/always lists non-negotiable
- [feedback_cli_authority.md](feedback_cli_authority.md) — authorized to run CLIs (migrations, env, deploy) directly without asking (CONFIRM per project)
- [feedback_copy_style.md](feedback_copy_style.md) — no em/en dashes or hyphens-as-punctuation in user-facing copy (preference)
- [feedback_sensitive_data_display.md](feedback_sensitive_data_display.md) — authorized display of sensitive data can be intentional; protect exfiltration, not display (domain-dependent)
- [feedback_deploy_preference.md](feedback_deploy_preference.md) — deploy/branching preference (CONFIRM per project)
