---
name: spree-resource
description: Use when the user wants to add a new model, database table, or REST API endpoint to a Spree 6 project, or document custom endpoints in OpenAPI. Covers `spree:api_resource` (model + migration + Store/Admin controllers + serializers + factory + specs + rswag integration spec + routes + permission scope), `spree:model` (model + migration only), and generating `openapi/admin.yaml` / `store.yaml` with rswag (`admin_operation`, `request_body_for`, `filter_parameters_for`, `spree_dev_tools:openapi`, `spree task openapi:generate`) — the document behind MCP agent tools and `spree sdk generate`. Common phrasings include "add a Brand model", "create a new resource", "expose X as an API endpoint", "add an Admin API for Y", "scaffold a Spree resource", "model without an API", "make my model store-scoped", "OpenAPI for my endpoint", "swagger docs for custom API", "rswag", "openapi:generate".
---

# Adding a Spree Resource

> Commands use the Spree CLI (`spree …`, Docker, Rails app in `server/`). On a classic Rails app without the CLI, run `bin/rails g spree:api_resource …` from the app root and drop the `server/` prefix from paths (see `spree-project`).

To add a model exposed through the v3 API, use the `spree:api_resource` generator. One command produces:

- The model (`server/app/models/spree/<name>.rb`) and its migration
- Store + Admin API controllers and serializers
- A FactoryBot factory and controller specs for both APIs
- An rswag integration spec documenting the Admin endpoints (`spec/integration/admin/<plural>_spec.rb`), which generates `openapi/admin.yaml` (see [Documenting endpoints](#documenting-endpoints-openapi))
- Route lines inside the `Spree::Core::Engine.add_routes` block of your app's `config/routes.rb`
- The `read_<plural>` / `write_<plural>` permission scope (`Spree.permissions.register_scope` appended to `config/initializers/spree.rb`) and its role-editor label (`config/locales/spree_<plural>.en.yml`) — Admin surface only

Prerequisite: run `spree eject` first. Generators execute inside the web container, and only the ejected dev compose bind-mounts `./server`, so generated files appear (and persist) on your host.

## The one-command path

```bash
spree generate api_resource Brand name:string:index slug:string:uniq active:boolean
spree migrate
```

Output summary:

```text
✓ Generated Spree::Brand API resource
  Prefixed ID:  brand_xxxxxxxxxx
  Store API:    /api/v3/store/brands  (read-only)
  Admin API:    /api/v3/admin/brands  (full CRUD)
```

Field syntax follows Rails' attribute parser, with Spree conventions applied:

| You write | You get |
|---|---|
| `name:string` / `:text` / `:integer` / `:decimal` / `:boolean` / `:date` / `:datetime` | `null: false` column; presence validation for non-boolean fields |
| `name:string:index` | Non-unique index |
| `slug:string:uniq` | Unique index + uniqueness validation — scoped to `store_id` when the model is store-scoped (the default), plus `spree_base_uniqueness_scope` |
| `brand:belongs_to` (or `:references`) | `belongs_to` with `class_name`, index, **no FK constraint**, `null: false` |
| `category:belongs_to{TaxCategory}` | Explicit class hint (unqualified names only) → `class_name: 'TaxCategory'`, resolved inside the `Spree` namespace |
| `description:rich_text` | `has_spree_rich_text` + `Spree::SanitizableRichText` |
| `logo:attachment` / `photos:attachments` | `has_one_attached` / `has_many_attached` |

`belongs_to` class resolution: `user` → `Spree.customer_class`; `admin_user`, `created_by`, `approver`, `canceler` → `Spree.admin_user_class`; anything else → `Spree::<Camelized>`.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--writable` | off | Store API gets create/update/destroy. Default Store API is read-only (index + show). |
| `--no-store` | — | Skip the Store API controller + serializer + route. Admin-only resource. |
| `--no-admin` | — | Skip the Admin API surface. Rare. |
| `--store-name=Discount` | — | Expose the Store API under a different name (`/api/v3/store/discounts`); model, table and Admin API keep the canonical name. |
| `--no-store-scoped` | scoped | By default the model includes `Spree::SingleStoreResource` (`store_id` column, `belongs_to :store`, auto-assigned from `Spree::Current.store`, `for_store` scope, store can't be changed later). Opt out only for global reference data. |
| `--no-lifecycle-events` | on | By default the model calls `publishes_lifecycle_events` (`brand.created/updated/deleted` events for subscribers and webhooks). |
| `--custom-fields` | off | Includes `Spree::HasCustomFields` + `Spree::Metadata` (merchant-defined custom fields + `metadata` JSON). |
| `--paranoid` | off | `acts_as_paranoid` + `deleted_at` column/index; Admin serializer exposes `deleted_at`. |
| `--id-prefix=br` | snake-cased class name | Prefixed-ID prefix (`brand_…` by default). Core uses short prefixes: `prod_`, `variant_`, `cart_`, `or_`, `py_`, `ful_`, `cust_`, `sl_`. |
| `--parent=Spree::Foo` | `Spree.base_class` | Parent class expression. |
| `--permission-group=settings` | `catalog` | Where the `read_`/`write_` keys appear in the role editor and API-key scope picker (`orders`, `catalog`, `customers`, `settings`, … or your own lowercase identifier). |
| `--skip-routes` | off | Don't touch routes. |
| `--skip-specs` | off | Don't generate controller specs. |

## What gets created

```
server/app/models/spree/brand.rb                                    (owned-once)
server/db/migrate/<ts>_create_spree_brands.rb                       (append-only)
server/app/controllers/spree/api/v3/store/brands_controller.rb      (managed)
server/app/controllers/spree/api/v3/admin/brands_controller.rb      (managed)
server/app/serializers/spree/api/v3/brand_serializer.rb             (managed)
server/app/serializers/spree/api/v3/admin/brand_serializer.rb       (managed)
server/spec/factories/spree/brand_factory.rb                        (managed)
server/spec/controllers/spree/api/v3/{store,admin}/brands_controller_spec.rb (managed)
server/spec/integration/admin/brands_spec.rb                        (managed — rswag, documents the Admin API)
server/config/routes.rb                                             (idempotent inject)
server/config/initializers/spree.rb                                 (idempotent append — register_scope)
server/config/locales/spree_brands.en.yml                           (owned-once — permission label)
```

Generated model (store-scoped default):

```ruby
module Spree
  class Brand < Spree.base_class
    include Spree::SingleStoreResource

    has_prefix_id :brand
    publishes_lifecycle_events

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: { scope: [:store_id, *spree_base_uniqueness_scope] }
    self.whitelisted_ransackable_attributes = %w[name slug active]
    self.whitelisted_ransackable_associations = %w[]
    self.whitelisted_ransackable_scopes = %w[]
  end
end
```

**Routes.** The generator inserts `resources :brands, only: [:index, :show]` (store) and `resources :brands` (admin) into the `namespace :store` / `namespace :admin` blocks inside `Spree::Core::Engine.add_routes` in `config/routes.rb` (create-spree-app / spree-starter ship this block empty). If the block or namespace is missing, it skips with a warning — add it by hand:

```ruby
Rails.application.routes.draw do
  Spree::Core::Engine.add_routes do
    namespace :api, defaults: { format: 'json' } do
      namespace :v3 do
        namespace :store do
          resources :brands, only: [:index, :show]
        end
        namespace :admin do
          resources :brands
        end
      end
    end
  end
  mount Spree::Core::Engine, at: '/'
end
```

## The "owned-once / managed / append-only" contract

- **Model (owned-once)** — written once; re-runs never touch it. Your validations, scopes, associations live here.
- **Migration (append-only)** — generated once. Change schema with a new migration: `spree generate migration AddLogoToSpreeBrands logo_url:string`.
- **Controllers, serializers, factory, specs (managed)** — overwritten on re-run. If you hand-edit them, don't re-run the generator for that resource (or re-apply your edits).
- **Routes and permission scope (idempotent)** — a route line or `register_scope(:brands, …)` already present isn't duplicated. The permission locale file is owned-once, so an edited label survives re-runs.

## After running the generator

1. **Review the model** — add validations, associations, scopes. Generated `belongs_to` is required (Spree models require `belongs_to` by default; failure message is "must exist"). Add `optional: true` and relax the migration's `null: false` for optional references.
2. **Migrate** — `spree migrate`.
3. **Grant the permission** — the Admin controller declares `scoped_resource :brands`, and the generator registered the matching scope in `config/initializers/spree.rb`:

   ```ruby
   # Permissions for the Brand API — grants read_brands / write_brands
   # to staff roles and secret API keys. Labels: config/locales/spree_brands.en.yml
   Spree.permissions.register_scope(:brands, group: :catalog, resources: -> { [Spree::Brand] })
   ```

   Until you grant `read_brands` / `write_brands` to a staff role (dashboard **Settings → Roles**, the Admin API, or seeds) or mint them on a secret key, only full-access principals get in (the `admin` role, `read_all`/`write_all` keys). The label lives under `spree.permissions_catalog.resources.brands` (`label`, optional `description`). With `--no-admin` nothing is registered. See `spree-auth-permissions`.
4. **Store-scoping on reads** — the base controller scopes collections with `Model.for_store(current_store)`. `SingleStoreResource` provides that scope; for `--no-store-scoped` models `for_store` falls back to `current_store.<plural>` if the association exists, else the whole table. Add `has_many :brands, class_name: 'Spree::Brand', dependent: :destroy` to `Spree::Store` via a decorator if you want `current_store.brands`. A permission decides *whether* someone may read brands, not *which* ones — keep lookups store-scoped.
5. **Permitted attributes** — the generated controllers declare the writable columns in `resource_permitted_attributes` (not a `permitted_params` override), so extension-declared attributes (`Spree::Brand.additional_permitted_attributes += [...]`) and param normalization still apply:

   ```ruby
   def resource_permitted_attributes
     [:name, :slug, :active]
   end
   ```

   Edit the list to drop columns clients shouldn't write — but the controllers are managed, so a re-run restores the template.
6. **Run the specs** — `spree test spec/controllers/spree/api/v3/`. The specs use the `'API v3 Store guest'` / `'API v3 Admin authenticated'` shared contexts from `spree_api`'s testing support (see `spree-testing`).
7. **Document it** — fill in the integration spec's descriptions, add specs for any custom member actions, then `spree task openapi:generate` and commit `openapi/admin.yaml` (next section).

## Adding a status

Spree has no state machines. For a record with a lifecycle, add a string `status` column and use `Spree::HasStatus`; transitions belong in workflows (see `spree-workflows`):

```ruby
include Spree::HasStatus
has_status :draft, :active, :archived, default: :draft   # predicates (active?), scopes (.active), inclusion validation, .with_status(...)
```

Extensions append statuses with `Spree::Brand.add_status('paused', after: 'active')`. Don't use Rails enums for status.

## Documenting endpoints (OpenAPI)

Since 6.0.3 a custom endpoint is documented the way core documents its own: rswag integration specs, generated into an OpenAPI file you commit. That one file drives three things:

- **Agent tools.** Spree merges every engine's and the app's `openapi/admin.yaml` into core's document at runtime. Each documented admin action other than CRUD becomes an Admin MCP / dashboard-assistant tool, with nothing to register (see `spree-mcp`).
- **Typed SDK clients.** `spree sdk generate` builds an SDK extension package from the document (see `spree-typescript-sdk`).
- **API reference.** Spree's own docs and SDKs use core's document only. Build yours from your own file.

### Setup

- **Projects from `create-spree-app`** already ship `server/spec/swagger_helper.rb` and `server/spec/agent_tools_spec.rb`.
- **Older projects or extensions** need `spree_dev_tools` 1.0.1 or later (Spree 6.0.3+):

  ```bash
  spree generate spree_dev_tools:openapi          # app (classic: bin/rails g spree_dev_tools:openapi)
  bundle exec rails g spree_dev_tools:openapi     # extension, from its own directory
  ```

The generator writes three things:

- `spec/swagger_helper.rb`, which requires `spree_dev_tools/rspec/openapi`.
- The agent-tools contract spec.
- A **skipped skeleton spec** for every admin action your controllers serve that isn't documented yet.

Fill in each skeleton's description and response records, then remove the skip. Re-run the generator after adding endpoints; it only writes what's missing.

### Writing a spec

```ruby
# spec/integration/admin/supplier_syncs_spec.rb
require 'swagger_helper'

RSpec.describe 'Supplier syncs', type: :request, swagger_doc: 'openapi/admin.yaml' do
  let(:supplier) { create(:supplier) }

  path '/api/v3/admin/suppliers/{id}/sync' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Supplier ID'
    let(:id) { supplier.prefixed_id }

    post 'Sync a supplier' do
      tags 'Suppliers'
      admin_operation :write, :purchasing, description: <<~DESC
        Pulls the supplier's current catalogue and stock. Use it before raising a
        purchase order, so the order uses today's prices.
      DESC
      request_body_for

      response '200', 'synced' do
        let(:body) { { full: true } }
        run_test!
      end
    end
  end
end
```

| Helper | What it does |
|---|---|
| `admin_operation :read\|:write, :<scoped_resource>, description:` | Adds the content types, both auth schemes (`X-Spree-Api-Key` / Bearer) and the scope note to the description. Signs in as an admin and a secret key; a response block can override either with its own `let`. |
| `request_body_for(action = nil, controller: nil, required: true)` | Documents the body from the controller's `request_params` declaration. That one declaration also permits the request, and it produces the tool arguments and the SDK `params/` types. |
| `filter_parameters_for(controller = nil, search: '…', scopes: {})` | Documents `q[...]` list filters from the model's ransack allowlists. It adds the filter table and the `x-spree-filters` data used to generate SDK `filters.ts`. Pass `search:` when the model's search isn't declared with `search_by`. |
| `query_parameters_for(shape)` | Documents a named query-param shape for a read endpoint. |
| `admin_scope_note 'text'` | A free-form scope note, for endpoints whose scope is resolved at request time. |
| `agent_tool false, reason: '…'` / `agent_tool true` | Opts a write out of agent tools (a reason is required) or opts a read in. See `spree-mcp`. |
| `operationId 'quotes_resend'` | Overrides the derived tool and SDK method name. Use it when two operations would collide. |

**Writing good summaries and descriptions.** The summary is the first line; the description is the paragraph that follows. Agents choose tools by this text, and the SDK puts it in JSDoc. Describe what the operation does and when to use it, not how it's implemented.

### Generating and committing

```bash
spree task openapi:generate          # app → server/openapi/admin.yaml  (classic: bin/rails spree:openapi:generate)
bundle exec rake spree:openapi:generate   # extension → openapi/admin.yaml (+ openapi/store.yaml)
```

- The task runs `spec/integration/**/*_spec.rb` through rswag's formatter with `OPENAPI=true`, so the output is deterministic. A diff in the file means the API changed. Override the pattern with `PATTERN=…`.
- Commit the YAML, and regenerate it whenever an endpoint, its `request_params` or its filters change.
- In an extension the task comes from `spree/testing_support/extension_rake`, which its Rakefile already requires. In an app it's built into `spree_api`.
- Specs that fail produce no operations. Run the integration specs green first.

**Store API endpoints (extensions).** Pass `store_title:` to `Spree::Api::TestingSupport::Openapi.configure(config, engine:, title:, store_title:)` in `spec/swagger_helper.rb`. Then name the document in each Store spec and authenticate as a customer:

```ruby
get 'List quotes', openapi_spec: 'openapi/store.yaml' do
  include_context 'API v3 Store authenticated'
```

**Shipping it in a gem.** A gemspec built from `git ls-files` already includes the YAML. A hand-listed one needs `'openapi/*.yaml'` added to `s.files`.

**Keeping it honest.** `spec/agent_tools_spec.rb` fails when:

- an admin action has no documented operation,
- an opt-out has no reason,
- two actions derive one tool name,
- the document conflicts with core's.

Keep it in CI, and add a check that catches an uncommitted document: `spree task openapi:generate && git diff --exit-code server/openapi/` in an app, or `bundle exec rake spree:openapi:generate && git diff --exit-code openapi/` in an extension.

## TypeScript types

Serializers you generate are app-local. They aren't in the published `@spree/sdk` / `@spree/admin-sdk` types. Choose the client by who uses it:

- **One app calling its own endpoints.** Use `client.request<T>(...)` with types written by hand from the serializer. The generated serializer's `typelize` line documents the JSON types; decimals serialize as strings.
- **An extension shipping a client.** Document the endpoints (above), then run `spree sdk generate` in an npm package. It writes typed `define*Extension` namespaces, request/filter/response types, and an `extend…Client` helper. See `spree-typescript-sdk`.

## Common patterns

```bash
# Read-only catalog resource (Store GET, Admin CRUD)
spree generate api_resource Brand name:string:uniq active:boolean

# Writable customer-facing resource
spree generate api_resource SavedList label:string user:belongs_to --writable

# Admin-only back-office data
spree generate api_resource SupplierNote body:text --no-store

# Soft-delete + custom fields
spree generate api_resource Vendor name:string:uniq slug:string:uniq --paranoid --custom-fields

# Global reference data (no store_id)
spree generate api_resource Certification code:string:uniq --no-store-scoped
```

For a writable customer resource, remember the Store API authorizes by ownership: override `scope` in the Store controller to read through the customer (e.g. `current_user.saved_lists`), otherwise any shopper can see every record in the store.

## Model only — no API surface

`spree:model` produces the model + migration with the same conventions (prefixed ID, `Spree.base_class`, store scoping, lifecycle events, `null: false`, no FKs, ransack allowlists) and accepts the same model flags (`--paranoid`, `--custom-fields`, `--id-prefix`, `--parent`, `--no-store-scoped`, `--no-lifecycle-events`). Unlike `api_resource`, it keeps Rails' test-framework hooks, so with rspec/factory_bot configured you also get a stub model spec and factory.

```bash
spree generate model BrandImage position:integer brand:belongs_to
```

Use it when the record is internal (log, join table), only reachable through a parent's API, or you'll hand-write controllers. To add an API later, run `spree generate api_resource Brand …` — it detects the existing model and skips the model + migration (owned-once), generating only the API surface.

## Gotchas

- **Don't add FK constraints** or Rails enums; keep `foreign_key: false` and string statuses.
- **Extending core models** (e.g. `brand_id` on products) is a decorator + `Spree::Product.additional_permitted_attributes += [:brand_id]` (never `<<` — the array is frozen). See `spree-decorators`.
- **Jobs, rake tasks, console:** store-scoped records need a store. Set `Spree::Current.store = store` (don't rely on `Spree::Store.default`, which can be nil).
- **Custom read-only member actions** — add them to `read_actions` in the controller so they map to `read_*` instead of `write_*`.

## Where to read further

- `node_modules/@spree/docs/dist/developer/tutorial/model-and-api.md` — end-to-end Brand walkthrough
- `node_modules/@spree/docs/dist/developer/customization/permissions.md` — `register_scope`
- `node_modules/@spree/docs/dist/developer/customization/api.md` — extending the API, and "From an endpoint to agent tools and an SDK client"
- `https://spreecommerce.org/docs/developer/mcp/custom-tools` — documenting endpoints for agents
- rswag helpers: `spree/api/lib/spree/api/testing_support/{openapi,filter_parameters,agent_tools}.rb`
- Generator source: `spree/core/lib/generators/spree/{api_resource,model}/`
