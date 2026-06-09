---
name: spree-resource
description: Use when the user wants to add a new model, database table, or REST API endpoint to their Spree project. Covers both `spree:api_resource` (full surface — model + API controllers + serializers + factory + specs + routes) and `spree:model` (model + migration only, no API). Common phrasings include "add a Brand model", "create a new resource", "expose X as an API endpoint", "add an admin API for Y", "scaffold a Spree resource", "create a Spree model without an API", "internal model".
---

# Adding a Spree Resource

To add a new model that's exposed via the Spree v3 API, use the `spree:api_resource` generator. One command produces:

- The model (in `backend/app/models/spree/<name>.rb`)
- The migration
- Store + Admin API controllers
- Store + Admin serializers (with TypeScript types auto-generated from the serializers)
- FactoryBot factory
- Controller specs covering full CRUD
- Routes (injected into `spree/api/config/routes.rb`)

## The one-command path

```bash
spree generate api_resource Brand name:string:uniq active:boolean --writable
```

Field syntax follows Rails' attribute parser, with Spree extensions:

| Modifier | Effect |
|---|---|
| `:string`, `:integer`, `:boolean`, `:decimal`, `:date`, `:datetime`, `:text` | Column type |
| `:uniq` | Unique index on the column + uniqueness validation scoped to `spree_base_uniqueness_scope` |
| `:index` | Non-unique index |
| `belongs_to:<Model>` | `belongs_to :<model>` association with index, no FK constraint |

Example field specs:

```
name:string:uniq               # unique non-null string with index + validator
description:text               # non-null text column
active:boolean                 # non-null boolean
price:decimal                  # non-null decimal
brand:belongs_to:Brand         # association to Spree::Brand
```

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--writable` | off | Store API gets full CRUD. Default Store API is read-only (index + show) — customer-facing endpoints rarely accept writes. |
| `--no-store` | (off) | Skip generating the Store API surface. Resource only exists under Admin. |
| `--no-admin` | (off) | Skip generating the Admin API surface. Rare; usually you want admin CRUD. |
| `--store-name=Discount` | (off) | Expose the Store API under a different external name. The model + table + Admin stay as `Brand`; only the Store API path becomes `/api/v3/store/discounts`. Used for cases like the Promotions/Discounts split. |
| `--paranoid` | off | Adds `acts_as_paranoid` to the model + `deleted_at` column + index. Soft-delete instead of hard-delete. |
| `--metafields` | off | Includes `Spree::Metafields` and `Spree::Metadata` concerns. Use when the resource should support user-defined custom fields. |
| `--id-prefix=brand` | snake-cased class name | The Stripe-style prefix on the resource's IDs. `Brand` defaults to `brand_<id>`. Override for shorter forms (e.g. `--id-prefix=br` for `br_<id>`). Conventions in core: long forms (`brand_`, `variant_`) for most, two-letter for high-traffic (`or_`, `py_`). |
| `--skip-routes` | off | Don't inject routes into `routes.rb`. You're on your own to wire them up. |
| `--skip-specs` | off | Don't generate controller specs. |

## What gets created

For `spree generate api_resource Brand name:string:uniq active:boolean --writable`:

```
backend/app/models/spree/brand.rb                                 (owned-once)
backend/db/migrate/<ts>_create_spree_brands.rb                    (append-only)
backend/app/controllers/spree/api/v3/store/brands_controller.rb   (managed)
backend/app/controllers/spree/api/v3/admin/brands_controller.rb   (managed)
backend/app/serializers/spree/api/v3/brand_serializer.rb          (managed)
backend/app/serializers/spree/api/v3/admin/brand_serializer.rb    (managed)
backend/lib/spree/testing_support/factories/brand_factory.rb      (managed)
backend/spec/controllers/spree/api/v3/store/brands_controller_spec.rb (managed)
backend/spec/controllers/spree/api/v3/admin/brands_controller_spec.rb (managed)
backend/spree/api/config/routes.rb                                (idempotent inject)
```

## The "owned-once / managed-forever / append-only" contract

- **Model file (owned-once)** — the generator writes it once. Once it exists, the generator never touches it again. Your domain logic (validations, scopes, callbacks, custom methods) lives here and stays yours.
- **Migration (append-only)** — generated once at resource creation. To change the schema later, add a separate migration: `spree rails g migration AddFooToBar foo:string`.
- **Controllers, serializers, specs, factory (managed)** — the generator overwrites these on re-run. If you customize them by hand, your changes get wiped next time you regenerate. Re-runs are idempotent — Thor's `identical` check leaves bytes-equal files alone.
- **Routes (idempotent inject)** — added between `# BEGIN spree:api_resource managed routes` and `# END` sentinel markers. Re-runs don't duplicate.

## After running the generator

The summary panel at the end of generator output lists the next steps:

1. **Review the generated model** — add validations, scopes, callbacks, custom methods that are specific to your resource.
2. **Apply the migration** — `spree migrate`.
3. **Set up authorization** — the generator can't infer who's allowed to access the resource under what conditions. Add CanCanCan rules in `backend/app/models/spree/permission_sets/` or `backend/config/initializers/spree.rb` so the resource's API surface actually returns data.
4. **Decide store-scoping** — if the resource should be scoped to a Store (most catalog data is), add `has_many :brands` on `Spree::Store` and override the controller's `scope` method.
5. **Run the specs** — `spree exec bundle exec rspec spec/controllers/spree/api/v3/`. The generated specs cover happy paths; add edge cases as you go.

## TypeScript types

After committing the new serializer, a Lefthook pre-commit hook auto-regenerates TypeScript types in `packages/sdk/src/types/generated/` (Store API) and `packages/admin-sdk/src/types/generated/` (Admin API), plus Zod schemas. You don't need to invoke `typelizer` manually — committing the serializer triggers everything.

## Common patterns

**Read-only catalog resource** (the default):

```bash
spree generate api_resource Brand name:string:uniq active:boolean
```

Customers can GET via Store API; admins have full CRUD via Admin API.

**Writable customer-facing resource** (rare, but real — e.g. saved addresses):

```bash
spree generate api_resource SavedAddress label:string belongs_to:User --writable
```

**Admin-only resource** (back-office data):

```bash
spree generate api_resource AuditLog action:string details:text --no-store
```

**Soft-delete with custom fields** (e.g. a Vendor with metadata):

```bash
spree generate api_resource Vendor name:string:uniq slug:string:uniq --paranoid --metafields
```

## Model only — no API surface

If you want a Spree model but no Store/Admin API (internal-only record, supporting model, lookup table), use the **`spree:model` generator** directly. It produces just the model file + migration with all the Spree conventions baked in — no controllers, serializers, factory, specs, or routes.

```bash
spree generate spree:model Brand name:string:uniq active:boolean
```

The `spree:model` generator is what `spree:api_resource` inherits from; running it standalone is the right choice when:

- The record is internal-only (event log, audit trail, internal join table)
- The record is exposed only through a parent's API (e.g. `BrandImage` accessed via `brand.images`, not directly)
- You want to write controllers and serializers by hand (custom auth, non-RESTful shape)
- You're scaffolding a model that will be associated with an existing Spree class via decorator (see the `spree-decorators` skill)

### What it produces

For `spree generate spree:model Brand name:string:uniq active:boolean`:

```
backend/app/models/spree/brand.rb                   (owned-once)
backend/db/migrate/<ts>_create_spree_brands.rb      (append-only)
```

The model has:
- `class Brand < Spree.base_class` (the swappable base lookup, not hardcoded)
- `has_prefix_id :brand` (auto-derived from class name, override with `--id-prefix`)
- `null: false` on every column in the migration
- No foreign key constraints (Spree convention)
- Uniqueness validation scoped to `spree_base_uniqueness_scope` for any `:uniq` field
- Ransack allowlist set to the generated attributes (empty `_associations` and `_scopes` arrays for you to fill in)

### Flags

The `spree:model` generator accepts the same Spree-specific flags as `api_resource`:

| Flag | Effect |
|---|---|
| `--paranoid` | Add `acts_as_paranoid` + `deleted_at` column + index |
| `--metafields` | Include `Spree::Metafields` + `Spree::Metadata` concerns |
| `--id-prefix=br` | Override the prefixed-ID prefix |
| `--parent=Spree::SomeBase` | Override the parent class (default is `Spree.base_class`) |

Plus everything Rails' built-in model generator accepts (column types, indexes, references, etc.).

### When to upgrade to `spree:api_resource`

If you later decide the model needs API access, run `spree generate api_resource Brand …` — the generator detects the existing model file and won't overwrite it. It'll generate the controllers, serializers, factory, specs, and routes around your hand-managed model.
