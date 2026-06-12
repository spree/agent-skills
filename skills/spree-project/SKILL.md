---
name: spree-project
description: Use when the user is working on a Spree Commerce project — anything involving Spree models, controllers, customization patterns (decorators, subscribers, services), Spree conventions like prefixed IDs / Spree::Model namespacing / Spree.user_class / Spree::Current, or asking how Spree works. Activates broadly for any task in a Spree backend.
---

# Spree Commerce Project

A Rails application powered by [Spree Commerce](https://spreecommerce.org).

## Project flavors — detect FIRST, it changes every command

Not every Spree app is a `create-spree-app` project. Check these signals in order before running anything:

| Signal | Flavor | How commands run |
|---|---|---|
| `backend/Gemfile` mentions spree + `docker-compose.yml` at root | **create-spree-app project** (5.4+) | `spree <cmd>` — the `@spree/cli` routes into the Docker `web` container |
| Rails app at root (`config/application.rb`, Gemfile with spree) + `docker-compose.yml` with a Spree image/build | **spree-starter-style Docker app** | `spree <cmd>` if the CLI resolves (`npx spree --version`); else `docker compose exec web <cmd>` |
| Rails app at root with spree gems, no Docker wiring | **classic Rails app** (typical pre-5.4) | Native, from the app root: `bin/rails …`, `bundle exec rake …` |

Command mapping — Spree CLI form → classic-app native form:

| Task | Spree CLI (Docker) | Classic Rails app |
|---|---|---|
| Boot for development | `spree dev` | `bin/dev` (or `bin/rails server`) |
| Rails console | `spree console` | `bin/rails console` |
| Install + run migrations | `spree migrate` | `bin/rake spree:install:migrations && bin/rails db:migrate` |
| Version upgrade | `spree upgrade` | `bundle update <spree gems>`, migrations, then `bin/rake spree:upgrade` |
| Run a generator | `spree generate api_resource …` | `bin/rails g spree:api_resource …` (spell the `spree:` prefix yourself — auto-prefixing is a CLI feature) |
| Any rake task | `spree rake <task>` | `bundle exec rake <task>` |
| Seeds / sample data | `spree seed` / `spree sample-data` | `bin/rails db:seed` / `bin/rails spree:load_sample_data` |
| Arbitrary command | `spree exec <cmd>` | just run `<cmd>` |

Other flavor differences:
- **Rails root**: `backend/` in create-spree-app projects, `.` in classic apps. Paths written as `backend/app/…` in these skills mean `app/…` on a classic app.
- **Local docs** (`node_modules/@spree/docs/dist/`) exist only when the project installs `@spree/docs`. On classic apps, use https://spreecommerce.org/docs/llms.txt instead.
- The rake tasks themselves (`spree:install:migrations`, `spree:upgrade`, the `spree:model`/`spree:api_resource` generators) ship inside the spree gems and work identically in both flavors — only the invocation wrapper differs. Note `spree:upgrade` and the generators ship in spree_core **5.5+**: a pre-5.5 app gains them after the `bundle update` step of the upgrade, so on old apps run the gem bump first.

## create-spree-app project layout

| Directory | Description |
|---|---|
| `backend/` | The Rails app — Spree mounted as an engine |
| `apps/storefront/` | Optional Next.js storefront |
| `node_modules/@spree/docs/dist/` | Local copy of Spree developer docs |

All Spree-specific code (models, decorators, subscribers) lives under `backend/app/`.

## Where to find Spree documentation

When you need Spree-specific guidance — how a model works, what events are available, how the cart pipeline runs — read the local docs first:

```
node_modules/@spree/docs/dist/
├── developer/
│   ├── core-concepts/       Products, orders, payments, inventory
│   ├── customization/       Decorators, extensions, dependencies, events
│   ├── admin/               Admin panel customization
│   ├── storefront/          Storefront building guides
│   ├── sdk/                 TypeScript SDK documentation
│   └── tutorial/            Step-by-step guides
├── api-reference/
│   ├── store-api/           Store API v3 guides
│   └── store.yaml           OpenAPI spec — every Store API endpoint
└── integrations/            Stripe, Meilisearch, etc.
```

Reach for these before guessing from training data. The local docs are the authoritative source for the installed Spree version.

## Customization patterns

90% of work on a Spree project is customization: wiring in external services, adding custom models, tweaking behavior. Spree exposes a layered set of extension points for this — settings, configuration, events, dependency injection, admin extension APIs, the resource generator, decorators, gems. Picking the right one matters because each layer has different upgrade-safety characteristics.

**For routing a specific customization to the right pattern, use the `spree-customization` skill.** It has the full decision table (subscribers vs decorators vs `Spree.dependencies` vs admin APIs vs `Spree.ransack`) with worked examples. Reach for it whenever the right approach isn't obvious.

Quick summary of the priority order:

1. **Settings / `Spree::Config`** — for runtime behavior toggles.
2. **Events + subscribers** — for side effects ("sync to ERP when order completes").
3. **Dependency injection** (`Spree.dependencies`) — for swapping how a core service computes. See `spree-dependencies` skill.
4. **Admin extension APIs** (`Spree.admin.navigation`, `Spree.admin.partials`, `Spree.admin.tables`, `Spree.ransack`) — for admin UI and search.
5. **Generators** (`spree:api_resource`, `spree:model`) — for brand-new models / resources.
6. **Decorators** (`spree:model_decorator`, `spree:controller_decorator`) — for structural changes to existing Spree classes.
7. **Extensions** (gems) — only when sharing customization across multiple apps.

## Conventions you should always follow

- **Namespace under `Spree::`** — all Spree-related Ruby classes live in `app/models/spree/`, `app/controllers/spree/`, etc.
- **`Spree.user_class` / `Spree.admin_user_class`** — never reference `Spree::User` directly. The user class is configurable.
- **`Spree::Current.store` / `.currency` / `.locale`** — per-request context, available in models, controllers, services.
- **Prefixed IDs in the API** — every v3 API response returns Stripe-style prefixed IDs (`prod_86Rf07xd4z`, `or_m3Rp9wXz`). Never expose raw integer IDs. Same on writes — the API accepts prefixed IDs.
- **`Spree.base_class`** — inherit from this, not `ActiveRecord::Base`. It applies Spree's base configuration.

## Common commands

`@spree/cli` (installed by `create-spree-app`) wraps the Docker-based dev workflow:

```bash
spree dev                          # run the stack in the foreground (streams logs; Ctrl+C stops web + worker, DBs stay up)
spree stop                         # tear down
spree console                      # Rails console
spree logs                         # follow web container logs
spree restart                      # restart the Rails process

spree migrate                      # install engine migrations from gems + db:migrate
spree generate <name> [args]       # any Spree generator
spree bundle add <gem>             # add a gem (persists in bundle_cache volume)
spree rake <task>                  # any rake task
spree exec <cmd>                   # universal escape hatch
spree rails <cmd>                  # any bin/rails command
spree routes                       # show Rails routes
spree seed                         # seed the database
spree sample-data                  # load sample products/categories/images
spree user create                  # create an admin user
spree api-key create               # create an API key (also: list, revoke)
spree db:reset                     # drop + recreate + migrate + seed (destructive)

spree upgrade                      # version upgrade
```

If you don't have `spree` on your PATH, prefix with the package runner: `npx spree …`, `pnpm exec spree …`, or `bunx spree …`.

## When in doubt

- Not sure which customization pattern fits? See the `spree-customization` skill — it routes the decision.
- Need to add a new model + API endpoint? See the `spree-resource` skill.
- Need to extend an existing Spree model/controller? See the `spree-decorators` skill.
- Need to upgrade Spree? See the `spree-upgrade` skill.
- Need details on a specific Spree concept? Read `node_modules/@spree/docs/dist/developer/` first.
