---
paths:
  - "app/services/**"
  - "app/jobs/**"
---

<!-- SETUP (rails-postgres profile): the business-logic layer as plain
Ruby objects under `app/services/`. Adapt the result type and the
access-control module name. Replaces the core `services.md`; keep one. -->

# Services

Plain Ruby objects, one public entry point, no model callbacks doing
business logic. Controllers, jobs, and rake tasks call services; services
own the invariants.

## Shape

```ruby
module Invoices
  class Create
    Result = Data.define(:invoice, :error) do
      def failure? = !error.nil?
    end

    def self.call(**) = new(**).call

    def initialize(account:, actor:, attrs:)
      @account, @actor, @attrs = account, actor, attrs
    end

    def call
      Access.require!(@actor, @account, :invoice_create)   # permission, not membership
      invoice = ApplicationRecord.transaction do
        inv = @account.invoices.create!(@attrs.except(:line_items))
        inv.line_items.insert_all!(line_item_rows(inv))
        AuditLog.record!(@account, @actor, :invoice_created, inv)
        inv
      end
      InvoiceCreatedJob.perform_later(invoice.id)   # after the block returns = after commit
      Result.new(invoice:, error: nil)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(invoice: nil, error: e.record.errors.full_messages)
    end
  end
end
```

## Conventions

- Every service takes `account:` (the tenant) and `actor:` keywords.
  Never query without the tenant; never derive it from a record the
  caller handed you without checking `record.account_id`.
- Access-control lives in ONE module (`app/policies/` or `lib/access.rb`):
  per-record `can_access_x?` plus scope variants for list filtering.
  Tenant scoping alone is not per-record visibility.
- The transaction boundary is explicit and inside the service. A caller
  composing several services wraps them in its own `transaction`; the
  inner ones join it. Expected failures return a `Result`; unexpected
  ones raise and roll back.
- Enqueue jobs and send mail AFTER the transaction returns, or from
  `after_commit`; do not rely on the queue adapter to defer.
- Jobs receive ids, never records or PII (arguments sit as plaintext in
  the queue table), and every job is idempotent because the queue retries.
- Sensitive attributes (SSN, bank details, anything regulated) are
  `encrypts`-ed on the model, listed in `config.filter_parameters` (which
  also filters `#inspect` and logs), and filtered through the ONE
  canonical list (`SensitiveAttributes.filter(hash)`) before an LLM
  prompt, a log line, `Rails.error.report` context, an export, or a third
  party. A new sensitive column updates all three in the same commit.
- Tool handlers a model can call receive the full `actor:` and `account:`
  context, not bare ids, so per-record access checks apply inside the tool.
- A guard on one write path is not immutability. Before claiming a column
  "never changes", grep every writer: callbacks, `update_all` in rake
  tasks, admin controllers, cascades.

## Adding an LLM-powered service

Read `PROMPTING.md` first, then copy your most thorough existing call
site. Prompt constants, builders, and the post-parse validator live in
a PURE module under `app/prompts/` (no ActiveRecord) so the eval
harness can require it without booting the app. The shell does the
spend budget assertion, the call, retries on 408 / 429 / 5xx / 529, the
spend record, and persistence. Model ID comes from the one config module.

## Size

400 LOC per new file (ENGINEERING-PRINCIPLES section 12a); orchestration
services may declare an 800 LOC tolerance. More than 50 new lines in an
over-budget file triggers a split-first commit.
