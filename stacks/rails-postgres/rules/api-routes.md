---
paths:
  - "app/controllers/**"
  - "config/routes.rb"
  - "app/views/**/*.jbuilder"
  - "app/serializers/**"
---

<!-- SETUP (rails-postgres profile): adapt the helper names
(`authenticate!`, `authorize!`, `render_error`) to your project. Replaces
the core `api-boundary.md` when installed; delete one or the other so the
two never disagree. -->

# Controllers and routes

Controllers orchestrate; services own the logic. 150 LOC per controller.

## Required pattern for every action that takes input

```ruby
class Api::V1::InvoicesController < Api::BaseController
  # Api::BaseController: `before_action :authenticate!` resolves the session
  # cookie OR the `Authorization: Bearer` API key through ONE resolver and
  # sets Current.user / Current.account. Nothing runs before it.
  rate_limit to: 60, within: 1.minute, by: -> { Current.user.id }, only: :create

  def create
    authorize! :invoice, :create            # permission, not membership
    result = Invoices::Create.call(account: Current.account, actor: Current.user,
                                   attrs: invoice_params)
    return render_error(result.error, status: :unprocessable_entity) if result.failure?

    render :show, status: :created, locals: { invoice: result.invoice }
  end

  private

  def invoice_params
    params.expect(invoice: [:customer_id, :due_on, line_items: [[:description, :amount_cents]]])
    # Rails 7.2: params.require(:invoice).permit(...)
  end
end
```

## Conventions

- Auth FIRST. `authenticate!` is declared once in the base controller.
  `skip_before_action :authenticate!` requires a comment naming the
  replacement gate: a timing-safe signature check
  (`ActiveSupport::SecurityUtils.secure_compare`) for webhooks, a
  hashed-token lookup for public links, a shared secret plus a
  platform header for cron endpoints.
- Tenant comes from `Current.account`, resolved from the user's
  membership row. Never from `params[:account_id]`, a query string, a
  header, or a subdomain the resolver did not verify.
- Every lookup goes through the tenant association
  (`Current.account.invoices.find(params[:id])`, a foreign id is a 404),
  never `Invoice.find(params[:id])`.
- Strong params at the boundary, then trust within. No `params.to_unsafe_h`
  outside a comment explaining why.
- `GET` never writes. `resources :things, only: %i[index show]` unless
  the action exists. A "confirm" link that mutates is `button_to`, not
  `link_to`.
- N+1: `includes` / `preload` on every collection that renders an
  association. `config.active_record.strict_loading_by_default = true`
  in development and Bullet in test make the miss loud.
- JSON through `*.json.jbuilder` templates or a serializer class. Never
  `render json: record`: it dumps every column, encrypted-at-rest ones
  included.
- One `render_error` helper; `rescue_from` for `RecordNotFound` (404),
  `ParameterMissing` (400), and your not-authorized error (403) live in
  the base controller. Never render `e.message` from a database error.
- API controllers inherit `ActionController::API` or skip
  `protect_from_forgery` explicitly; browser controllers keep CSRF on.

## What NOT to do

- Do not accept the tenant ID from the request. Access-control bypass.
- Do not bypass `authenticate!` for "internal" endpoints. Use an admin
  scope on an API key instead.
- Do not write to financial tables (payments, payouts, ledgers) from a
  controller. Go through the dedicated money services.
- Do not add a public route to `config/routes.rb` without also adding
  it to the auth allowlist test and the docs. Every allowlist, or none.

## Money paths require extra care

- A `regression=pass` line in the Senior-Checklist trailer.
- A request spec that exercises both the happy and failure paths.
- Error-reporter capture (`Rails.error.report`) of any silent rollback.
