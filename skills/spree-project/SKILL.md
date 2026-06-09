---
name: spree-project
description: Use when the user is working on a Spree Commerce project — anything involving Spree models, controllers, customization patterns (decorators, subscribers, services), Spree conventions like prefixed IDs / Spree:: namespacing / Spree.user_class / Spree::Current, or asking how Spree works. Activates broadly for any task in a Spree backend.
---

# Spree Commerce Project

A Rails application powered by [Spree Commerce](https://spreecommerce.org). Project layout (scaffolded by `create-spree-app`):

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
│   └── tutorial/            Step-by-step guides
└── api-reference/
    └── store.yaml           OpenAPI spec — every Store API endpoint
```

Reach for these before guessing from training data. The local docs are the authoritative source for the installed Spree version.

## Customization patterns

90% of work on a Spree project is customization: wiring in external services, adding custom models, tweaking behavior. Spree exposes a layered set of extension points for this — settings, configuration, events, dependency injection, admin extension APIs, the resource generator, decorators, gems. Picking the right one matters because each layer has different upgrade-safety characteristics.

**For routing a specific customization to the right pattern, use the `spree-customization` skill.** It has the full decision table (subscribers vs decorators vs `Spree.dependencies` vs admin APIs vs `Spree.ransack`) with worked examples. Reach for it whenever the right approach isn't obvious.

Quick summary of the priority order:

1. **Settings / `Spree::Config`** — for runtime behavior toggles.
2. **Events + subscribers** — for side effects ("sync to ERP when order completes").
3. **Dependency injection** (`Spree.dependencies`) — for swapping how a core service computes.
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
spree dev                          # boot the backend stack
spree stop                         # tear down
spree console                      # Rails console
spree logs                         # follow web container logs
spree restart                      # restart the Rails process

spree migrate                      # run pending migrations
spree generate <name> [args]       # any Spree generator
spree bundle add <gem>             # add a gem (persists in bundle_cache volume)
spree rake <task>                  # any rake task
spree exec <cmd>                   # universal escape hatch

spree upgrade                      # version upgrade
```

If you don't have `spree` on your PATH, prefix with the package runner: `npx spree …`, `pnpm exec spree …`, or `bunx spree …`.

## When in doubt

- Not sure which customization pattern fits? See the `spree-customization` skill — it routes the decision.
- Need to add a new model + API endpoint? See the `spree-resource` skill.
- Need to extend an existing Spree model/controller? See the `spree-decorators` skill.
- Need to upgrade Spree? See the `spree-upgrade` skill.
- Need details on a specific Spree concept? Read `node_modules/@spree/docs/dist/developer/` first.
