---
name: spree-project
description: Use for any work in a Spree Commerce 6 project — orienting in the repo (server/, apps/dashboard, apps/storefront), detecting the project flavor (create-spree-app + `spree` CLI vs a classic Rails app), running commands, following Spree conventions (Spree:: namespace, Spree.base_class, Spree.customer_class, current_store scoping, has_status, prefixed IDs, custom fields vs metadata), and finding the right docs. Activates broadly — "how does Spree work", "where do I put this", "how do I run X in my Spree app", "what are the Spree conventions", "set up a Spree project". Routes to spree-customization when the question is which extension pattern to use.
---

# Spree Commerce Project (Spree 6)

Spree is a headless commerce engine: a Rails app (the `spree` gems) that serves the Store, Admin and Seller REST APIs, plus TypeScript apps you own (a React admin dashboard and a Next.js storefront). Customization happens *around* the engine — configuration, hooks, events, providers — not by forking it.

> Coming from Spree 5.x? Read the `spree-upgrade-5-to-6` skill first — cart/order split, no state machines, React dashboard, API v2 and `spree_admin` removed.

## Detect the project flavor FIRST — it changes every command

| Signal | Flavor | How commands run |
|---|---|---|
| `server/Gemfile` (or legacy `backend/Gemfile`) + `docker-compose.yml` + `package.json` with `@spree/cli` | **create-spree-app project** | `spree <cmd>` — the CLI routes into the Docker `web` container |
| Rails app at the repo root (`config/application.rb`, `Gemfile` with `spree` gems), no `server/` | **classic Rails app** | Native from the app root: `bin/rails …`, `bundle exec rake …` |

If `spree` isn't on PATH, use `npx spree …` / `pnpm exec spree …`. The CLI accepts both `server/` and the older `backend/` directory name.

| Task | Spree CLI | Classic Rails app |
|---|---|---|
| Run the stack | `spree dev` | `bin/dev` or `bin/rails server` |
| Rails console | `spree console` | `bin/rails console` |
| Shell in the container | `spree shell` | (you're already in one) |
| Install + run migrations | `spree migrate` | `bin/rails spree:install:migrations && bin/rails db:migrate` |
| Generator | `spree generate api_resource Brand …` (bare names auto-prefix `spree:`) | `bin/rails g spree:api_resource Brand …` |
| Run specs | `spree rspec spec/models/…` (RAILS_ENV=test) | `bundle exec rspec spec/models/…` |
| Rake task | `spree rake <task>` / `spree task <name>` (auto `spree:` prefix) | `bundle exec rake <task>` |
| Sample data | `spree sample-data` (default store; another store: `spree rake spree:load_sample_data STORE_CODE=eu`) | `bin/rails spree:load_sample_data` (`STORE_ID=store_…` or `STORE_CODE=…` to target a non-default store) |
| Version upgrade | `spree upgrade` | `bundle update spree…`, migrate, `bin/rails spree:upgrade` |
| Anything else | `spree exec <cmd>` | `<cmd>` |

Paths written `server/app/...` in these skills mean `app/...` in a classic app.

## Project layout (create-spree-app)

```text
my-store/
├── server/                 # The Spree API — a full Rails 8.1 app (spree-starter). Your Ruby code lives here.
│   ├── app/{models,services,workflows,subscribers,controllers,serializers}/
│   ├── config/initializers/spree.rb   # hooks, registries, dependencies, subscribers
│   ├── Dockerfile          # builds the production image (API + dashboard)
│   └── Gemfile
├── apps/
│   ├── dashboard/          # React admin (@spree/dashboard) — plugins in src/plugins.ts
│   ├── seller-dashboard/   # Marketplace seller panel (optional)
│   └── storefront/         # Next.js storefront on @spree/sdk (optional)
├── docker-compose.yml      # prebuilt ghcr.io/spree/spree image + Postgres (Meilisearch optional, commented out)
├── .env                    # SECRET_KEY_BASE, ACTIVE_RECORD_ENCRYPTION_* keys, SPREE_PORT, SPREE_VERSION_TAG… (mode 0600)
├── AGENTS.md / CLAUDE.md   # generated agent instructions
└── package.json            # pins @spree/cli
```

- **`server/` is the only part that is Spree's.** The apps are ordinary Vite/Next.js projects you own.
- By default the stack runs the **prebuilt image**. To change Ruby code, run `spree eject` once — compose then builds from `server/`.
- Stack: Rails 8.1, Ruby ≥ 3.2; PostgreSQL, MySQL or SQLite. Background jobs run in-process via **Solid Queue** (Mission Control at `/jobs`), Solid Cache; Sidekiq/Redis is optional. The dashboard is served at `/dashboard` by the `spree_dashboard` gem in production (one image, same origin).
- APIs: Store `/api/v3/store` (publishable key `pk_…`), Admin `/api/v3/admin` (secret key `sk_…` or staff JWT), Seller `/api/v3/seller` (seller JWT + `X-Spree-Seller-Id`). See `spree-api-v3`.

## Conventions you should always follow

- **Namespace under `Spree::`**, files under `server/app/models/spree/…` etc. Your own non-Spree classes can use your app namespace (`MyApp::…`).
- **Inherit from `Spree.base_class`** (defaults to `Spree::Base`), not `ApplicationRecord`. It brings preferences, prefixed IDs, ransack allowlists, document numbers, `additional_permitted_attributes`.
- **Users are two classes:** `Spree.customer_class` (default `Spree::Customer`, table `spree_customers`, `cust_…`) and `Spree.admin_user_class` (`Spree::AdminUser`, `adm_…`). Never hardcode either. `Spree.user_class` is a deprecated alias.
- **Scope every query through the store**: `current_store.products`, `store.orders` — never `Spree::Order.all` in request code. In dev/test `SPREE_STORE_SCOPE_GUARD=log|raise|off` flags unscoped queries.
- **`Spree::Current`** carries per-request `store`, `channel`, `market`, `currency`, `locale`. `Spree::Current.store` falls back to `Spree::Store.default`, which **can be nil** (no store flagged default) — set `Spree::Current.store = store` explicitly in jobs, rake tasks and specs. Assigning it also arms the dev/test `StoreScopeGuard` for the rest of that job/script, so unscoped queries there get flagged too (wrap deliberately global lookups in `Spree::StoreScopeGuard.skip { … }`).
- **No state machines, no enums for lifecycles.** Statuses are string `status` columns declared with `has_status` (`Spree::HasStatus`); transitions are **workflows** (`app/workflows`). Extend with `Model.add_status('on_hold', after: 'approved')` — plus your own workflow to move records into it. See `spree-workflows`.
- **`belongs_to` is required by default** — pass `optional: true` when the FK may be nil, or saves fail with "… must exist". Always pass `class_name:` and an explicit `dependent:` on `has_many`.
- **No DB foreign keys on business tables**; add an index instead. Uniqueness validations are store-scoped in core.
- **IDs are strings at the API surface** — Stripe-style prefixed IDs (`prod_…`, `cart_…`, `or_…`, `py_…`). Look up with `Model.find_by_prefix_id!(id)`; never `.to_i` an ID and never expose integer IDs. Full table: `spree-data-model`.
- **Cart ≠ Order.** `Spree::Cart` is mutable checkout state; completing it creates an immutable `Spree::Order` (`status` draft/placed/canceled). Code that runs on both reads `line_item.owner`, not `.order`.
- **Custom data:** merchant-facing, typed, filterable → **custom fields** (`product.set_custom_field('custom.material', 'Cotton')`, `get_custom_field`). Machine/integration data → **`metadata`** (schemaless JSON, write-only in Store API). A new *column* only when your own code queries it heavily.
- **Side effects go in events / hooks, not callbacks.** React after the fact with a `Spree::Subscriber` (`order.placed`, …); run inside a flow with `Spree.hooks.register('carts.complete.validate', …)`. Don't add `after_save` to Spree models.
- **Writable API attributes:** `Spree::Product.additional_permitted_attributes += [:brand_id]` — `+=`, never `<<` (the default is frozen).
- **Services return results, not exceptions:** `result = Spree.cart_add_item_workflow.call(...)`; check `result.success?`.
- **Money in the API is a string** (`"135.60"`) with a `display_…` twin — render the display one.
- **Secrets** go in Rails credentials or env vars; Spree's installation settings are all `SPREE_*` env vars (see `spree-customization`). Active Record encryption keys (`ACTIVE_RECORD_ENCRYPTION_*`) must be set in every environment — `create-spree-app` generates a dev set; `spree encryption init` adds one to older projects (see `spree-security`).

## Where customization goes (short version)

Walk this list top-down — higher options are cheaper and survive upgrades better. The `spree-customization` skill has the full decision table.

1. **Store settings** (dashboard → Settings; Admin API) — markets, currencies, delivery, taxes, order numbering. Data, not code.
2. **Configuration** — `SPREE_*` env vars / `Spree.config`; per-record `preference`s.
3. **Workflow hooks** — `Spree.hooks.register('<flow>.<hook>', 'MyApp::Handler')` to veto or extend a core flow (`spree-workflows`).
4. **Events & subscribers** — react after something happened (`spree-events-webhooks`).
5. **Checkout registry** — `Spree::Checkout::Registry.add_requirement` / `register_step` (`spree-checkout`).
6. **Providers** — tax, delivery rates, fulfillment, search, pricing, inventory, payouts, digital assets, auth (`spree-providers`).
7. **Ransack allowlists** — `Spree.ransack.add_attribute(Spree::Product, :erp_id)`.
8. **Webhooks** — notify external systems without Ruby.
9. **Dependencies** — replace a whole workflow/service: `Spree::Dependencies.cart_add_item_workflow = 'MyApp::Carts::AddItem'` (`spree-dependencies`).
10. **Decorators** — last resort, for structural additions (associations, scopes) (`spree-decorators`).

Admin UI changes happen in the React dashboard via plugins (`spree-dashboard`, `spree-dashboard-plugins`), not in Rails views.

## Common CLI commands

```bash
spree dev                      # run API (+ dashboard dev server if apps/dashboard exists); first run completes setup
spree stop | restart | logs [worker]
spree console | shell | db:console
spree migrate | migrate:status | migrate:rollback
spree generate api_resource Brand name:string   # → spree:api_resource
spree generate subscriber ErpSync order.placed   # class + registration in initializers/spree.rb
spree rspec [path[:line]]      # tests in RAILS_ENV=test (first: spree rails db:test:prepare)
spree bundle add <gem>         # gem lands in the bundle_cache volume, no rebuild
spree eject                    # build from server/ instead of the prebuilt image
spree build [--production]     # rebuild dev image / build the production image (API + dashboard)
spree add dashboard            # add apps/dashboard (also: spree add seller-dashboard)
spree plugin new <name>        # scaffold a dashboard plugin monorepo
spree update                   # pull latest image, recreate containers (migrations run on boot)
spree upgrade [--plan]         # bundle update + migrate + spree:upgrade data steps
spree seed | sample-data | user create | api-key create|list|revoke
spree encryption init [--print]  # add ACTIVE_RECORD_ENCRYPTION_* keys to .env (never overwrites); --print for production
spree rails spree:setup:token  # reprint the first-run admin setup link
spree api <verb> <path>        # call the Admin API from the terminal (see spree-cli)
```

`spree db:reset` is destructive — confirm with the user before running it.

## Where to find Spree documentation

Read the installed docs before guessing from training data — they match the installed version:

```text
node_modules/@spree/docs/dist/
├── developer/
│   ├── getting-started/  create-spree-app/  cli/
│   ├── core-concepts/    # products, carts, orders, payments, fulfillments, markets, …
│   ├── customization/    # quickstart, configuration, workflows, dependencies, decorators, permissions, validations
│   ├── providers/        # ERP, PIM, DAM, fulfillment, payouts, SSO, observability
│   ├── how-to/           # custom payment method, delivery rate provider, search provider, B2B, marketplace…
│   ├── dashboard/        # React admin: customization, plugins, recipes
│   ├── sdk/  storefront/  multi-tenant/  security/  deployment/  upgrades/  tutorial/
└── api-reference/        # Store/Admin API guides + OpenAPI specs
```

- No local package (classic app)? Use https://spreecommerce.org/docs/llms.txt (index) or append `.md` to any docs URL.
- The **Spree docs MCP server** (`https://spreecommerce.org/docs/mcp`) searches the latest published docs: `claude mcp add --transport http spree-docs https://spreecommerce.org/docs/mcp`.
- Never use `docs/v5/` pages for a Spree 6 project.

## When in doubt

- Which extension pattern? → `spree-customization`
- How models relate, which ID prefix, which status values? → `spree-data-model`
- New model + API endpoint? → `spree-resource`
- Hooks / writing a workflow? → `spree-workflows`
- Tests? → `spree-testing`. Upgrading? → `spree-upgrade` / `spree-upgrade-5-to-6`.
