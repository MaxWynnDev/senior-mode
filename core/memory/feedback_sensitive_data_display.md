---
name: feedback-sensitive-data-display
description: Authorized in-app display of sensitive data can be intentional; protect against exfiltration, not display (domain-dependent)
metadata:
  type: feedback
---

When a product genuinely requires authorized users to see sensitive
fields (e.g. a compliance analyst seeing a full tax ID or bank account) to do their
job, that in-app display is INTENTIONAL and is not the threat to defend
against. Do not add UI masking that breaks the workflow, and do not flag
the absence of masking as a bug.

Protect against EXFILTRATION instead: plaintext at rest, leakage to
logs/error-reporter/the LLM, cross-tenant exposure, unauthorized export.
See ENGINEERING-PRINCIPLES.md section 7.

**DOMAIN-DEPENDENT.** This is true for the user's regulated-data products
where authorized display is a requirement. On a project where masking IS
the right control, this memory does not apply. Decide consciously per
field and write the decision down.
