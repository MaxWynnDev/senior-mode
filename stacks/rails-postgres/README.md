# Stack profile: rails-postgres

A Ruby on Rails profile for an existing or new Rails app on Postgres,
packaged as an overlay. Install with `bash install.sh --profile
rails-postgres <repo>`, or copy the pieces by hand. Nothing here is
required by the core kit; a project on another stack skips this folder
entirely (see `../../STACK.md`).

## What it assumes

- Ruby 3.3+, Rails 7.2 or 8, bundler. Conventional layout
  (`app/controllers`, `app/models`, `app/services`, `lib/tasks`).
- Postgres via the `pg` gem. ActiveRecord migrations under
  `db/migrate/`, `db/schema.rb` (or `db/structure.sql` when you rely on
  PG extensions, triggers, or functions).
- The `strong_migrations` gem guarding DDL.
- RSpec (`rspec-rails`) with system specs through Capybara, or minitest
  with `bin/rails test` and `test:system`. Either works; the profile's
  commands name RSpec first.
- RuboCop for lint AND format (`rubocop-rails-omakase` or your own
  config), Brakeman for static security scanning, both wired in CI.
- Hotwire (Turbo + Stimulus) for UI; server-rendered ERB, no separate
  frontend build unless you added one.
- Auth through the Rails 8 authentication generator, Devise, or an
  equivalent vetted library, exposed to controllers through ONE
  `authenticate!` before_action that sets `Current.user` and
  `Current.account`.
- Deploy as a Docker image: Kamal 2 to your own hosts (the Rails 8
  default), or Fly.io / Render. GitHub Actions for CI, a CI-gated
  production deploy.

## What's in the overlay

| Path | Installs as | Purpose |
|---|---|---|
| `rules/api-routes.md` | path-scoped rule (location depends on the agent adapter) | controller contract: one auth resolver, strong params, tenant from `Current.account`, no writes in GET, N+1, serializers; scoped to `app/controllers/**` |
| `rules/database.md` | path-scoped rule (location depends on the agent adapter) | migrations, `strong_migrations`, concurrent indexes, raw SQL casts, integer money, transactions and locks; scoped to `db/**` and `app/models/**` |
| `rules/services.md` | path-scoped rule (location depends on the agent adapter) | service objects, transaction boundaries, sensitive attributes; scoped to `app/services/**` |
| `rules/scripts.md` | path-scoped rule (location depends on the agent adapter) | rake tasks vs `bin/` vs `rails runner`, naming, dry-run, prod refusal; scoped to `lib/tasks/**`, `bin/**`, `scripts/**` |
| `WORKFLOW.md` | repo root | the concrete pipeline (replaces the core template) |

The profile's rules REPLACE the core's `api-boundary.md`,
`data-layer.md`, `services.md`, and `scripts.md`. The kickoff asks you
to keep one of each pair so they never disagree. The core `ui.md` stays;
adapt its component language to ERB partials, Turbo Frames, and
Stimulus controllers.

## Platform notes worth knowing (as of mid-2026)

- **Kamal 2** is what `rails new` generates for deploys: `config/deploy.yml`
  names the servers, the registry, env vars, and a `proxy:` block;
  `.kamal/secrets` supplies `KAMAL_REGISTRY_PASSWORD` and
  `RAILS_MASTER_KEY` from your env or a password manager. `kamal setup`
  bootstraps a host once, `kamal deploy` builds the image tagged with
  the git SHA, pushes it, boots the new container, waits for the `/up`
  health check through kamal-proxy, then switches traffic (zero
  downtime). `kamal rollback <sha>` swaps back to an image already on
  the host. Hooks live in `.kamal/hooks/` (`pre-deploy` is where a
  CI-green check belongs). Thruster sits in front of Puma inside the
  container for asset caching, compression, and HTTP/2.
- **Rails 8 Solid Queue, Solid Cache, Solid Cable** are the default
  job, cache, and Action Cable backends, all on the database. The
  generated `config/database.yml` gives production separate `queue`,
  `cache`, and `cable` databases with their own schema files
  (`db/queue_schema.rb` and friends) loaded by `db:prepare`, not by
  `db:migrate`. Solid Queue runs inside Puma when
  `SOLID_QUEUE_IN_PUMA=true`, or as its own `bin/jobs` container. Job
  arguments are serialized into the queue table in plaintext: pass ids,
  not records or PII.
- **`strong_migrations`** raises at migration time on unsafe DDL
  (`add_index` without `algorithm: :concurrently`, `remove_column`
  before `ignored_columns`, type changes, unvalidated foreign keys,
  volatile defaults) and prints the safe recipe. `safety_assured { }`
  is the explicit escape hatch; `StrongMigrations.start_after` skips
  migrations that predate adoption; it can also set `lock_timeout` and
  `statement_timeout` per migration.
- **The generated `bin/docker-entrypoint` runs `db:prepare` when the
  container command is the Rails server.** That is auto-migration on
  deploy. The kit's doctrine is that migrations never run automatically;
  delete that line (see `WORKFLOW.md`).
- Rails 7.1+ serves `/up` (`Rails::HealthController`); Kamal, Fly, and
  Render health checks all point at it. Rails 7.2+ has controller-level
  `rate_limit` backed by `Rails.cache`, which is only shared across
  processes when the cache store is Solid Cache or Redis.
- Rails 8 `params.expect` replaces `params.require(...).permit(...)`
  and returns 400 instead of 500 on a malformed shape.

## Install by hand

1. Rules: copy `rules/*.md` into `.senior-mode/rules/` (the agent
   adapter wires them to its native rules location), keeping the
   `paths:` frontmatter each file shows at the top. Delete the core
   `api-boundary.md`, `data-layer.md`, `services.md`, `scripts.md`.
2. Docs: `WORKFLOW.md` to the repo root; fill in the deploy target and
   name the profile in `AGENTS.md`'s Stack section.
3. Set `SENIOR_MODE_FORMAT_CMD="bundle exec rubocop -a"` for the
   post-edit format hook if it does not detect RuboCop on its own.
4. Add `strong_migrations` to the Gemfile, run
   `bin/rails generate strong_migrations`, set `start_after`.
5. Write `scripts/migrate-prod.sh` per `WORKFLOW.md` and remove
   `db:prepare` from `bin/docker-entrypoint`.

## What to adapt if you use Sinatra / Hanami

- **Sinatra**: there is no `bin/rails`, so the detector will not fire;
  install by hand. `api-routes.md` maps onto a `before` filter for auth
  and a hand-written params validator; `database.md` maps onto Sequel
  migrations (`sequel -m db/migrate`) or `standalone_migrations`.
- **Hanami 2.2+**: actions live in `app/actions/**` with built-in typed
  `params` blocks (keep the rule, change the paths); persistence is ROM
  with `hanami db migrate` over Sequel migrations in `config/db/migrate/`,
  so swap `strong_migrations` advice for hand-checked concurrent DDL.
