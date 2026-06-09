# Spree Commerce — Agent Guidance

This file follows the [agents.md](https://agents.md) cross-tool standard. It's a portable summary of how to be effective on a Spree Commerce codebase, written for any agentic CLI (Codex, Cursor, Copilot, Aider, Windsurf, Zed, Amp, etc.) that reads `AGENTS.md`.

If you're running in **Claude Code**, you're better off installing this package as a plugin — Claude Code auto-loads the 23 SKILL.md files under `skills/` as on-demand context (progressive disclosure), the `spree-expert` subagent for multi-step work, and two safety hooks. See [README.md](./README.md) for install instructions.

If you're running in **any other tool**: read this file, then dive into the relevant `skills/<name>/SKILL.md` when the task matches its domain.

---

## What Spree is

Spree Commerce is an open-source, self-hosted commerce platform built on Ruby on Rails. The thing people choose it for is the ability to customize and extend it without forking. Architecture in three layers:

1. **Backend (Ruby gems)** — `spree_core` (models, services, business logic), `spree_api` (Store + Admin REST APIs under `/api/v3/`), `spree_admin` (legacy Rails admin UI), `spree_emails` (transactional emails).
2. **Frontend SDKs (TypeScript)** — `@spree/sdk` (Store API client), `@spree/admin-sdk` (Admin API client, Developer Preview).
3. **Admin UIs** — `spree_admin` (legacy Rails/Turbo, default on 5.x) **OR** `@spree/dashboard` (React SPA, default on 6.0+).

Users run Spree in their own infrastructure — there's no Spree cloud. Everything is opt-in customization.

## Core conventions (don't violate these without a reason)

### Ruby / Rails

- All Spree code is namespaced under `Spree::`.
- All models inherit from `Spree.base_class` — not `ApplicationRecord` directly.
- Use `Spree.user_class` and `Spree.admin_user_class` instead of `Spree::User` so apps can swap the user model.
- Always scope queries through `current_store` (e.g. `current_store.orders`, not `Spree::Order.all`). Multi-store apps share a database; un-scoped queries leak data across stores.
- Use string columns instead of Rails enums.
- IDs are treated as strings (Stripe-style prefixed IDs at the API surface; integer PKs internally — never `.to_i` an ID).
- State machines use the `state_machines-activerecord` gem; column is `status` on new models, `state` on legacy models (see `6.0-normalize-state-to-status.md`).
- Uniqueness validations use `scope: spree_base_uniqueness_scope` plus a DB index.
- Always pass `class_name` and `dependent` on associations.
- Use the events system (`publish_event` + subscribers) for side effects — not `after_*` callbacks.

### API v3 (REST)

Two surfaces under `/api/v3/`:

- **Store API** (`/api/v3/store/*`) — customer-facing. Auth: publishable key (`pk_*`) + optional JWT customer. Read-only by default.
- **Admin API** (`/api/v3/admin/*`) — back-office. Auth: secret key (`sk_*` with Shopify-style scopes) OR JWT admin (with CanCanCan abilities). Full CRUD by default.

Both share: prefixed IDs (`prod_…`, `or_…`, `variant_…`), `{ data, meta }` envelope on lists, Ransack filters (`q[name_cont]=...`), `include=...` for sideloading. See `skills/spree-api-v3/SKILL.md`.

### TypeScript

- Workspace: pnpm + Turbo + Tsup + Vitest.
- Lint: Biome (replaces ESLint + Prettier).
- Two SDKs: `@spree/sdk` (Store) and `@spree/admin-sdk` (Admin).
- For custom endpoints, use the SDK's `client.request<T>(method, path, options)` escape hatch or extend the client with a wrapped resource class — don't fork the SDK and don't bypass with raw `fetch`.

## Development commands

### Backend (Ruby/Rails)

```bash
# Boot a Spree backend for development
pnpm server:setup        # one-time: clones spree-starter into ./server
pnpm server:dev          # Rails on http://localhost:3000

# Tests (per gem, e.g. core)
cd spree/core
bundle exec rake test_app          # generate dummy app once
bundle exec rspec                  # run suite
bundle exec rspec spec/models/spree/order_spec.rb:42   # single test
bundle exec parallel_rspec spec    # parallel
```

Seed admin user: `spree@example.com` / `spree123`.

### Frontend (TypeScript)

```bash
pnpm install
pnpm build                 # all packages (Turbo-cached)
pnpm test
pnpm typecheck
pnpm lint                  # Biome
pnpm lint:fix
```

### Admin dashboard (React SPA, 6.0+)

```bash
cd packages/dashboard
pnpm dev                   # http://localhost:5173 (proxies /api/* to :3000)
pnpm test:e2e              # Playwright
```

### API type regeneration (after serializer changes)

```bash
cd spree/api && bundle exec rake typelizer:generate    # TS types
cd packages/sdk && pnpm generate:zod                    # Zod schemas
bundle exec rake rswag:specs:swaggerize                # OpenAPI
```

Lefthook runs steps 1–2 automatically pre-commit when serializers change.

## Testing conventions

- RSpec + Factory Bot + Capybara — **not** Minitest, **not** fixtures.
- Install `spree_dev_tools` gem for Spree-specific helpers (`stub_authorization!`, `'API v3 Store'` shared context, Spree factories).
- Always use factories (`create(:order, :with_line_items)`), never `Model.create` directly.
- Prefer `build` over `create` when persistence isn't needed.
- Admin SPA uses Playwright (not Capybara) with UI-only assertions — see `skills/spree-testing/SKILL.md`.
- Don't test Rails framework guarantees (strong params, presence validations). Test your custom logic.

## Security non-negotiables

- Secrets live in Rails encrypted credentials or env vars — never in the repo.
- Set `Spree::Config[:preference_encryptor_key]` in production so gateway secrets encrypt at rest.
- Webhook receivers MUST verify HMAC-SHA256 signatures + timing-safe compare + replay window (default 5 min).
- Publishable keys (`pk_*`) are safe in client code. Secret keys (`sk_*`) are server-to-server only — never ship in mobile apps or browser JS.
- Grant secret keys minimum scopes (Shopify-style: `read_orders`, `write_products`, etc.) — not `write_all`.
- All queries scoped through `current_store` to prevent cross-store data leaks.
- See `skills/spree-security/SKILL.md` for the full list.

## The skills index — where to look

When the task domain matches one of these, read the corresponding `skills/<name>/SKILL.md`:

| Domain | Skill |
|---|---|
| General project conventions, customization patterns | `spree-project` |
| Adding a new model + API endpoint (uses the `spree:api_resource` generator) | `spree-resource` |
| REST API v3 protocol — auth, envelopes, prefixed IDs, scopes | `spree-api-v3` |
| Maintaining or migrating legacy v2 (JSON:API) integrations | `spree-legacy-api-v2` |
| `@spree/sdk` + `@spree/admin-sdk` usage, extension patterns | `spree-typescript-sdk` |
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
| Legacy Rails/Turbo admin customization (5.x default) | `spree-admin` |
| 6.0 React admin SPA extension via `defineDashboardPlugin` | `spree-dashboard` |
| Next.js storefront + `@spree/sdk` integration | `spree-storefront` |
| UI translations (`Spree.t`) + data translations (Mobility) | `spree-i18n` |
| RSpec / Factory Bot / `spree_dev_tools` testing patterns | `spree-testing` |
| Rails security + Spree-specific (scopes, encrypted prefs, webhook HMAC, PCI) | `spree-security` |
| Perf hotspots — cart pipeline, catalog N+1s, search, image processing, Sidekiq | `spree-performance` |
| Deploying to Heroku/Render/K8s/Docker — env vars, release commands, S3, Sidekiq | `spree-deployment` |

## What NOT to do

- Don't write `Spree::User.find(...)` — use `Spree.user_class.find(...)`.
- Don't add foreign key constraints in migrations (Spree convention).
- Don't add Rails enum columns — use strings.
- Don't drop or truncate `spree_*` tables in development without backup; the `spree/agent-skills` plugin's safety hook blocks this automatically when installed via `/plugin install spree@spree` in Claude Code, but other tools won't.
- Don't bypass `current_store` scoping in custom controllers.
- Don't expose raw integer IDs in API responses — always prefixed IDs (`prod_…`, `or_…`).
- Don't pre-write 6.0 changes on a 5.x codebase (Cart/Order split, state→status rename, Adjustment split, etc.) — see `docs/plans/` for what's in flight.
- Don't fork `@spree/sdk` to add custom endpoints — extend it via `client.request` or a wrapped resource class.

## Where to read further

- **Spree developer docs:** https://spreecommerce.org/docs/developer
- **API reference (OpenAPI):** [docs/api-reference/store.yaml](https://github.com/spree/spree/blob/main/docs/api-reference/store.yaml)
- **Plans for upcoming versions:** `docs/plans/` in the [spree/spree](https://github.com/spree/spree) monorepo
- **Source code:** https://github.com/spree/spree
- **Each `skills/<name>/SKILL.md` is self-contained** — read it when its domain is in scope.
