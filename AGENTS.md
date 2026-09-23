# Spree Commerce — Agent Guidance

This file follows the [agents.md](https://agents.md) cross-tool standard. It's a portable summary of how to be effective on a Spree Commerce codebase, written for any agentic CLI (Codex, Cursor, Copilot, Aider, Windsurf, Zed, Amp, etc.) that reads `AGENTS.md`.

**Targets Spree 6.x (Rails 8.1).** For Spree 5.x projects, use the `v0.3.0` tag of this repository.

If you're running in **Claude Code**, install this package as a plugin and you'll get the 38 SKILL.md files under `skills/` as on-demand context, the `spree-expert` subagent, two slash commands, and two safety hooks. See [README.md](./README.md) for install instructions.

If you're running in **any other tool**: read this file, then dive into the relevant `skills/<name>/SKILL.md` when the task matches its domain.

---

## What Spree is

Spree Commerce is an open-source, self-hosted, API-first commerce platform built on Ruby on Rails. The thing people choose it for is the ability to customize and extend it without forking. Architecture:

1. **Backend (Ruby gems)** — `spree_core` (models, services, workflows), `spree_api` (Store, Admin and Seller REST APIs under `/api/v3/`), `spree_dashboard` (serves the admin dashboard at `/dashboard`), `spree_emails` (transactional email), plus provider gems (`spree_stripe`, `spree_meilisearch`, `spree_easypost`, …).
2. **TypeScript SDKs** — `@spree/sdk` (Store API), `@spree/admin-sdk` (Admin API), `@spree/seller-sdk` (Seller API).
3. **Admin UI** — `@spree/dashboard`, a React app you own and extend with plugins (`apps/dashboard/`). An optional seller dashboard exists for marketplaces.
4. **Storefront** — the reference Next.js storefront (`apps/storefront/`), or anything you build on the Store API.

Users run Spree in their own infrastructure. Everything is opt-in customization.

## Core conventions (don't violate these without a reason)

### Ruby / Rails

- All Spree code is namespaced under `Spree::`; models inherit from `Spree.base_class`, not `ApplicationRecord` directly.
- Use `Spree.customer_class` (default `Spree::Customer`) and `Spree.admin_user_class` (default `Spree::AdminUser`) — never hardcode the class. `Spree.user_class` is deprecated.
- Always scope queries through the current store (`current_store.products`, not `Spree::Product.all`). Multi-store apps share a database; un-scoped queries leak data across stores. `Spree::Store.default` can return `nil` — set `Spree::Current.store` in jobs, rake tasks and tests.
- **Cart and Order are separate models.** `Spree::Cart` (`cart_…`) is the shopping/checkout phase; completing it creates an immutable `Spree::Order` (`or_…`). Records owned by either side (line items, payments, fulfillments, tax lines, discounts, fees) use `#owner`.
- **No state machines.** Status fields are plain string `status` columns declared with `has_status`; transitions happen in `Spree::Workflow` classes. Don't add state machines and don't convert statuses to Rails enums.
- **Side effects go in workflow hooks or event subscribers**, not `after_*` callbacks or decorators on business methods. `Spree.hooks.register('carts.complete.before_finalize', …)` for in-flow logic; `publish_event` + subscribers for reactions.
- Money adjustments are typed rows: `Spree::TaxLine`, `Spree::Discount`, `Spree::Fee`. Prices are per currency: `variant.price_in(currency)` / `variant.set_price(currency, amount)`.
- IDs are strings at the API surface (Stripe-style prefixed IDs); never `.to_i` an ID.
- `belongs_to` is required by default — declare `optional: true` where blank is legitimate.
- Uniqueness validations use `scope: spree_base_uniqueness_scope` plus a DB index. Always pass `class_name` and `dependent` on associations.
- Permit extra attributes on the model: `Spree::Product.additional_permitted_attributes += [:brand_id]` (never `<<`).
- Merchant-managed data belongs in **custom fields**; schemaless private data in `metadata`.

### API v3 (REST)

Three surfaces under `/api/v3/`:

- **Store API** (`/api/v3/store/*`) — customer-facing. Auth: publishable key (`pk_*`) + optional customer JWT. Customer access is ownership-scoped.
- **Admin API** (`/api/v3/admin/*`) — back-office. Auth: secret key (`sk_*`, scoped `read_*`/`write_*`) or staff JWT. Both pass the same per-endpoint permission check; staff permissions come from roles stored as data.
- **Seller API** (`/api/v3/seller/*`) — marketplace sellers. Seller JWT + `X-Spree-Seller-Id`.

All share prefixed IDs (`prod_…`, `cart_…`, `or_…`, `variant_…`), `{ data, meta }` list envelopes, Ransack filters (`q[name_cont]=...`), `expand=...` and `fields=...`, and money as strings. See `skills/spree-api-v3/SKILL.md`.

### TypeScript

- Use `@spree/sdk` / `@spree/admin-sdk` / `@spree/seller-sdk` to call the API from TypeScript.
- For custom endpoints, use the SDK's `client.request<T>(method, path, options)` escape hatch or extend the client with a wrapped resource class — don't fork the SDK and don't bypass it with raw `fetch`.

## Project layout and commands

Projects scaffolded with `create-spree-app` put the Rails app in `server/` (older projects: `backend/`, still accepted), the dashboard in `apps/dashboard/`, and use `@spree/cli` to drive the Docker-based dev environment.

**Flavor check first:** classic Rails apps with Spree gems at the repo root (no Docker/CLI) take the native equivalents instead — `bin/rails console`, `bin/rails spree:install:migrations && bin/rails db:migrate`, `bin/rails spree:upgrade`, `bin/rails g spree:api_resource …`. The rake tasks and generators ship in the gems and behave identically; only the wrapper differs. See `skills/spree-project/SKILL.md`.

```bash
spree dev                   # run the stack (+ dashboard dev server if apps/dashboard exists)
spree stop | restart | logs
spree console | shell | db:console
spree migrate | migrate:status | migrate:rollback
spree generate <args>       # bare names auto-prefix to `spree:` (`api_resource` → `spree:api_resource`)
spree rspec [path[:line]]   # run specs in RAILS_ENV=test
spree rake <task> | task <name>   # `task` auto-prefixes `spree:`
spree rails <args> | bundle <args> | exec <command>
spree seed | sample-data | user create | api-key create|list|revoke
spree encryption init [--print]   # add ACTIVE_RECORD_ENCRYPTION_* keys to .env (never overwrites)
spree add dashboard         # add apps/dashboard (also: spree add seller-dashboard)
spree plugin new <name>     # scaffold a dashboard plugin (the gem half is a spree_extension >= 2.0 gem)
spree eject | build [--production] | update
spree upgrade [--plan]      # bundle update + migrate + spree:upgrade data steps
spree db:reset              # destructive — confirm with the user first
spree open                  # open the dashboard in the browser
spree api <verb> <path>     # call the Admin API from the terminal (see skills/spree-cli)
spree auth login            # save a credentials profile for a remote store
```

For the full command reference see `dist/developer/cli/quickstart.md` in the installed `@spree/docs` package.

### Testing

```bash
spree rspec                             # or, natively: bundle exec rspec
spree rspec spec/models/...:42          # one example

# Only when developing a Spree engine or extension:
bundle exec rake test_app               # regenerate the dummy app (after schema changes)
```

- RSpec + Factory Bot — **not** Minitest, **not** fixtures. Install `spree_dev_tools` for Spree factories and the `'API v3 Store'` / `'API v3 Admin'` shared contexts.
- Always use factories (`create(:cart_ready_to_complete)`, `create(:completed_order_with_totals)`), never `Model.create` directly. Prefer `build` when persistence isn't needed.
- Don't test Rails framework guarantees. Test your custom logic.

## Security non-negotiables

- Secrets live in Rails encrypted credentials or env vars — never in the repo, and never in `VITE_*` dashboard variables.
- Set the three Active Record encryption keys (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT`) in every environment. Spree encrypts webhook signing secrets, gateway customer IDs and OAuth identity tokens only when they're configured — otherwise plaintext. New projects get a dev set in `.env`; `spree encryption init` adds one to older projects, `spree encryption init --print` (or `bin/rails db:encryption:init`) prints a production set. Never change them once data is encrypted.
- Webhook receivers MUST verify the HMAC-SHA256 signature with a timing-safe compare and a replay window.
- Publishable keys (`pk_*`) are safe in client code. Secret keys (`sk_*`) are server-to-server only — never in mobile apps or browser JS. Grant them minimum scopes.
- Hiding UI in the dashboard is not authorization; the API enforces permissions.
- See `skills/spree-security/SKILL.md` and `skills/spree-auth-permissions/SKILL.md`.

## The skills index — where to look

When the task domain matches one of these, read the corresponding `skills/<name>/SKILL.md`:

| Domain | Skill |
|---|---|
| Project layout, conventions, CLI vs classic flavor | `spree-project` |
| "Where does my customization belong?" — hook vs subscriber vs provider vs decorator | `spree-customization` |
| Workflows and `Spree.hooks` — validate/lifecycle/context hooks, `has_status` | `spree-workflows` |
| New model + API endpoint (`spree:api_resource` generator) | `spree-resource` |
| Extending existing classes via decorators (`prepend`) — last resort | `spree-decorators` |
| Swapping core workflows/services/serializers via `Spree.dependencies` | `spree-dependencies` |
| Installing extensions or writing your own gem | `spree-extensions` |
| Plugging in tax, delivery rate, payment, search, payout, auth providers | `spree-providers` |
| REST API v3 — surfaces, auth, envelopes, prefixed IDs, scopes | `spree-api-v3` |
| `@spree/sdk`, `@spree/admin-sdk`, `@spree/seller-sdk` | `spree-typescript-sdk` |
| Calling/debugging the Admin API from the terminal (`spree api`) | `spree-cli` |
| Staff roles, permission keys, API scopes, SSO/custom authentication | `spree-auth-permissions` |
| Domain model — stores, markets, carts, orders, customers, prefixed IDs | `spree-data-model` |
| Products, variants, options, categories, collections, media, search | `spree-catalog` |
| Prices, multi-currency, price lists, volume pricing, EU Omnibus | `spree-pricing` |
| Stock levels, reservations, purchase orders, suppliers, transfers | `spree-inventory` |
| Cart → order completion, checkout requirements, `Checkout::Registry` | `spree-checkout` |
| Tax lines, discounts, fees, totals recalculation | `spree-order-totals` |
| Tax categories/rates, tax providers, exemptions | `spree-taxes` |
| Payment methods, sessions, capture, refunds, gift cards, store credits | `spree-payments` |
| Promotion rules, actions, calculators, coupon codes | `spree-promotions` |
| Fulfillments, delivery methods/zones/profiles, rates, order routing | `spree-fulfillment` |
| Returns, exchanges, claims | `spree-returns` |
| Multi-vendor marketplace — sellers, commissions, payouts, Seller API | `spree-marketplace` |
| B2B — companies, catalogs, customer groups, wholesale channels | `spree-b2b` |
| Multi-tenant SaaS platform (Enterprise) | `spree-multi-tenant` |
| Reporting metrics/dimensions, imports and exports | `spree-reporting` |
| Customizing the React admin dashboard | `spree-dashboard` |
| Packaging and publishing dashboard plugins | `spree-dashboard-plugins` |
| Next.js storefront + `@spree/sdk` | `spree-storefront` |
| Events, subscribers and outbound webhooks | `spree-events-webhooks` |
| UI translations (`Spree.t`) + data translations (Mobility) | `spree-i18n` |
| RSpec / Factory Bot / `spree_dev_tools` | `spree-testing` |
| Security — secrets, encryption, webhook HMAC, data privacy, PCI | `spree-security` |
| Performance — recalculation, N+1s, search, jobs, observability | `spree-performance` |
| Deploying — Docker, Render, AWS, env vars, Solid Queue, dashboard build | `spree-deployment` |
| Upgrading Spree (general flow, manifests, `spree upgrade`) | `spree-upgrade` |
| Upgrading from Spree 5.6 to 6.0 | `spree-upgrade-5-to-6` |

## What NOT to do

- Don't write `Spree::User` / `Spree::Customer.find(...)` in app code — use `Spree.customer_class.find(...)`.
- Don't add foreign key constraints in migrations on business tables — Spree's generators emit `foreign_key: false`.
- Don't add state machines or Rails enums for statuses — use `has_status` and workflows.
- Don't patch `Order#finalize!` or other model internals — use workflow hooks or event subscribers.
- Don't register into Spree registries (payment methods, promotion actions, stock splitters, calculators, …) from `to_prepare` or bare initializer code; core resets several of them in its own `after_initialize`. Register inside `Rails.application.config.after_initialize`.
- Don't drop or truncate `spree_*` tables without a backup. The plugin's safety hook blocks the most dangerous cases (DROP TABLE on any `spree_*` table, `db:drop`/`db:reset`, TRUNCATE or mass deletes of orders, carts, payments, refunds, fulfillments, customers, staff, gift cards, store credits and API keys) when installed via `/plugin install spree@spree` in Claude Code; other tools aren't covered.
- Don't bypass store scoping in custom controllers.
- Don't expose raw integer IDs in API responses — always prefixed IDs.
- Don't fork `@spree/sdk` to add custom endpoints — extend it via `client.request` or a wrapped resource class.

## Where to read further

- **Spree developer docs:** https://spreecommerce.org/docs/developer
- **Installed locally:** `node_modules/@spree/docs/dist/developer/` after scaffolding with `create-spree-app`
- **Source code:** https://github.com/spree/spree
- **Each `skills/<name>/SKILL.md` is self-contained** — read it when its domain is in scope.
