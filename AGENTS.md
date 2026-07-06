# Spree Commerce — Agent Guidance

This file follows the [agents.md](https://agents.md) cross-tool standard. It's a portable summary of how to be effective on a Spree Commerce codebase, written for any agentic CLI (Codex, Cursor, Copilot, Aider, Windsurf, Zed, Amp, etc.) that reads `AGENTS.md`.

If you're running in **Claude Code**, install this package as a plugin and you'll get the 26 SKILL.md files under `skills/` as on-demand context, the `spree-expert` subagent, and two safety hooks. See [README.md](./README.md) for install instructions.

If you're running in **any other tool**: read this file, then dive into the relevant `skills/<name>/SKILL.md` when the task matches its domain.

---

## What Spree is

Spree Commerce is an open-source, self-hosted commerce platform built on Ruby on Rails. The thing people choose it for is the ability to customize and extend it without forking. Architecture in three layers:

1. **Backend (Ruby gems)** — `spree_core` (models, services, business logic), `spree_api` (Store + Admin REST APIs under `/api/v3/`), `spree_admin` (Rails admin UI), optional payment/integration gems (`spree_stripe`, `spree_adyen`, `spree_paypal_checkout`, `spree_i18n`).
2. **Frontend SDKs (TypeScript)** — `@spree/sdk` (Store API client), `@spree/admin-sdk` (Admin API client).
3. **Admin UI** — `spree_admin` (the Rails/Turbo admin).

Users run Spree in their own infrastructure — there's no Spree cloud. Everything is opt-in customization.

## Core conventions (don't violate these without a reason)

### Ruby / Rails

- All Spree code is namespaced under `Spree::`.
- All models inherit from `Spree.base_class` — not `ApplicationRecord` directly.
- Use `Spree.user_class` and `Spree.admin_user_class` instead of `Spree::User` so apps can swap the user model.
- Always scope queries through `current_store` (e.g. `current_store.orders`, not `Spree::Order.all`). Multi-store apps share a database; un-scoped queries leak data across stores.
- State/status fields on state-machine models (Order, Payment, Shipment) are string columns — don't convert them to Rails enums. (Core does use integer enums for a few non-workflow fields like `Promotion#kind`; string + state machine is still the default for anything with transitions.)
- IDs are treated as strings (Stripe-style prefixed IDs at the API surface; integer PKs internally — never `.to_i` an ID).
- State machines use the `state_machines-activerecord` gem.
- Uniqueness validations use `scope: spree_base_uniqueness_scope` plus a DB index.
- Always pass `class_name` and `dependent` on associations.
- Use the events system (`publish_event` + subscribers) for side effects — not `after_*` callbacks.

### API v3 (REST)

Two surfaces under `/api/v3/`:

- **Store API** (`/api/v3/store/*`) — customer-facing. Auth: publishable key (`pk_*`) + optional JWT customer. Read-only by default.
- **Admin API** (`/api/v3/admin/*`) — back-office. Auth: secret key (`sk_*` with scoped permissions) OR JWT admin (with CanCanCan abilities). Full CRUD by default.

Both share: prefixed IDs (`prod_…`, `or_…`, `variant_…`), `{ data, meta }` envelope on lists, Ransack filters (`q[name_cont]=...`), `expand=...` for sideloading (and `fields=...` for sparse responses). See `skills/spree-api-v3/SKILL.md`.

### TypeScript

- The `@spree/sdk` (Store) and `@spree/admin-sdk` (Admin) packages are the canonical way to call the API from TypeScript.
- For custom endpoints, use the SDK's `client.request<T>(method, path, options)` escape hatch or extend the client with a wrapped resource class — don't fork the SDK and don't bypass with raw `fetch`.

## Development commands

Projects scaffolded with `create-spree-app` use the `@spree/cli` to drive the Docker-based dev environment. **Flavor check first:** classic Rails apps with Spree gems (no Docker/CLI — typical pre-5.4, Rails app at the repo root) take the native equivalents instead — `bin/rails console`, `bin/rake spree:install:migrations && bin/rails db:migrate`, `bin/rake spree:upgrade`, `bin/rails g spree:api_resource …` — and paths lose the `backend/` prefix. The rake tasks and generators ship in the gems (spree_core 5.5+ for `spree:upgrade` and the generators — older apps gain them after the gem bump) and work identically in both flavors; only the wrapper differs.

```bash
spree init                  # one-time setup: starts services, seeds DB, generates API key
spree dev                   # run the stack in the foreground (Ctrl+C stops web + worker; DBs stay up)
spree stop
spree restart               # in-place restart for initializer changes
spree logs                  # web (default) or `spree logs worker`
spree console               # Rails console
spree migrate               # install + run pending migrations
spree db:reset               # drop, recreate, seed
spree routes                # bin/rails routes passthrough
spree generate <args>       # run a generator — bare names auto-prefix to `spree:` (`model` → `spree:model`, `api_resource` → `spree:api_resource`); Rails built-ins (`migration`, `scaffold`, `job`, …) forwarded as-is
spree exec <command>        # arbitrary command inside the web container
spree rails <args>          # bin/rails passthrough
spree bundle <args>         # bundle passthrough (lands in bundle_cache volume)
spree rake <task>
spree upgrade               # walk version upgrade (bundle + migrate + spree:upgrade)
spree eject                 # switch from prebuilt image to building from ./backend/
spree build                 # rebuild dev image (after eject + Dockerfile/.ruby-version changes)
spree update                # pull latest image + recreate containers
spree migrate:status        # show migration status
spree migrate:rollback      # roll back last migration (STEP=n for more)
spree db:console            # psql session against the dev database
spree task <name>           # rake task with auto `spree:` prefix (e.g. spree task search:reindex)
spree seed                  # seed the database
spree sample-data           # load sample data (products, categories, images)
spree user create           # create an admin user (interactive, or --email/--password)
spree api-key create|list|revoke   # manage publishable/secret API keys (--type publishable|secret)
spree open                  # open the admin dashboard in the browser
spree api <verb> <path>     # generic Admin API client (see skills/spree-cli/SKILL.md)
spree auth login            # save a credentials profile for a remote store
spree completion <shell>    # bash/zsh/fish shell completions
```

For the full command reference see `dist/developer/cli/quickstart.md` in the installed `@spree/docs` package (source: `docs/developer/cli/quickstart.mdx` in the spree monorepo).

### Testing

```bash
# Inside the project's backend directory or via `spree exec`:
bundle exec rspec                       # full suite
bundle exec rspec spec/models/...       # one file
bundle exec rspec spec/models/...:42    # one test (by line number)

# Only when developing a Spree engine or extension (these tasks don't exist in a scaffolded app backend):
bundle exec rake test_app               # regenerate the dummy test app (after schema changes)
bundle exec rake parallel_setup         # create per-worker test DBs
bundle exec parallel_rspec spec         # parallel run
```

## Testing conventions

- RSpec + Factory Bot + Capybara — **not** Minitest, **not** fixtures.
- Install `spree_dev_tools` for Spree-specific helpers (`stub_authorization!`, `'API v3 Store'` shared context, Spree factories).
- Always use factories (`create(:order_with_line_items)`), never `Model.create` directly.
- Prefer `build` over `create` when persistence isn't needed.
- Don't test Rails framework guarantees (strong params, presence validations). Test your custom logic.

## Security non-negotiables

- Secrets live in Rails encrypted credentials or env vars — never in the repo.
- Configure Rails Active Record encryption keys in production (`active_record.encryption.primary_key`, `deterministic_key`, `key_derivation_salt` — generate with `bin/rails db:encryption:init`, store in encrypted credentials). Spree uses `encrypts` for secrets like webhook signing keys and gateway customer profile IDs; these columns only encrypt at rest when AR encryption is configured. Keep `secret_key_base` stable within each environment.
- Webhook receivers MUST verify HMAC-SHA256 signatures + timing-safe compare + replay window (default 5 min).
- Publishable keys (`pk_*`) are safe in client code. Secret keys (`sk_*`) are server-to-server only — never ship in mobile apps or browser JS.
- Grant secret keys minimum scopes (`read_orders`, `write_products`, etc.) — not `write_all`.
- All queries scoped through `current_store` to prevent cross-store data leaks.
- See `skills/spree-security/SKILL.md` for the full list.

## The skills index — where to look

When the task domain matches one of these, read the corresponding `skills/<name>/SKILL.md`:

| Domain | Skill |
|---|---|
| General project conventions, customization patterns | `spree-project` |
| Routing question: "where does my customization belong" / "decorator vs subscriber vs ..." | `spree-customization` |
| Adding a new model + API endpoint (uses the `spree:api_resource` generator) | `spree-resource` |
| Extending an existing Spree model/controller via decorators (`prepend`) | `spree-decorators` |
| Swapping a core Spree service via `Spree.dependencies` (cart, checkout, serializers, ability) | `spree-dependencies` |
| REST API v3 protocol — auth, envelopes, prefixed IDs, scopes | `spree-api-v3` |
| Maintaining or migrating legacy v2 (JSON:API) integrations | `spree-legacy-api-v2` |
| `@spree/sdk` + `@spree/admin-sdk` usage, extension patterns | `spree-typescript-sdk` |
| Calling/inspecting the Admin API from the terminal, debugging requests (`spree api`) | `spree-cli` |
| Upgrading Spree across minor/major versions | `spree-upgrade` |
| Domain model — Orders, LineItems, Variants, Stores, Channels, Markets | `spree-data-model` |
| Events + subscribers (in-process) + outbound webhooks (HMAC, retry) | `spree-events-webhooks` |
| Installing third-party gems or writing your own extension | `spree-extensions` |
| Products, Variants, Options, Categories, search, images | `spree-catalog` |
| Cart pipeline, order state machine, payment sessions, checkout customization | `spree-checkout` |
| Payment methods, gateways, refunds, gift cards, store credits | `spree-payments` |
| Promotion rules, actions, calculators, coupon codes | `spree-promotions` |
| Variant prices, multi-currency, price lists, EU Omnibus | `spree-pricing` |
| Shipments, shipping methods, rates, stock locations, returns | `spree-shipping-fulfillment` |
| Legacy Rails/Turbo admin customization (`spree_admin` gem) | `spree-admin` |
| Next.js storefront + `@spree/sdk` integration | `spree-storefront` |
| UI translations (`Spree.t`) + data translations (Mobility) | `spree-i18n` |
| RSpec / Factory Bot / `spree_dev_tools` testing patterns | `spree-testing` |
| Rails security + Spree-specific (scopes, encrypted prefs, webhook HMAC, PCI) | `spree-security` |
| Perf hotspots — cart pipeline, catalog N+1s, search, image processing, Sidekiq | `spree-performance` |
| Deploying to Heroku/Render/K8s/Docker — env vars, release commands, S3, Sidekiq | `spree-deployment` |

## What NOT to do

- Don't write `Spree::User.find(...)` — use `Spree.user_class.find(...)`.
- Don't add foreign key constraints in migrations on business tables — Spree's generators emit `foreign_key: false` (the only FKs in the schema come from ActiveStorage and the Mobility translation tables).
- Don't model state/status fields as Rails enums — use string columns (+ a state machine where transitions matter).
- Don't drop or truncate `spree_*` tables in development without backup. The `spree/agent-skills` plugin's safety hook blocks the most dangerous of these automatically when installed via `/plugin install spree@spree` in Claude Code (DROP TABLE on any `spree_*` table, `db:drop`/`db:reset`, and TRUNCATE or mass-deletes of orders, payments, users); other tables and other tools aren't covered.
- Don't bypass `current_store` scoping in custom controllers.
- Don't expose raw integer IDs in API responses — always prefixed IDs (`prod_…`, `or_…`).
- Don't fork `@spree/sdk` to add custom endpoints — extend it via `client.request` or a wrapped resource class.

## Where to read further

- **Spree developer docs:** https://spreecommerce.org/docs/developer
- **Installed locally:** `node_modules/@spree/docs/dist/developer/` after scaffolding with `create-spree-app`
- **Source code:** https://github.com/spree/spree
- **Each `skills/<name>/SKILL.md` is self-contained** — read it when its domain is in scope.
