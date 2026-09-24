---
name: spree-reporting
description: Use when adding or changing analytics, reports, dashboard numbers, or CSV imports/exports in a Spree 6 project. Covers the `Spree.reporting` semantic layer (metrics, dimensions, counters, bases, `replace: true` overrides), `Spree::Reporting::Query`, authorization via `subject` + `key_scope`, saved reports (`Spree::SavedReport`), and the async CSV pipeline (`Spree::Export` / `Spree::Import` subclasses, import statuses, retrying failed rows, resumable processing). Common phrasings include "add a custom metric", "report sales by brand/seller/warehouse", "add a dashboard counter", "why don't the report rows add up to the total", "export orders to CSV", "add a custom export/import type", "import products from a spreadsheet", "retry failed import rows".
---

# Reporting, Imports & Exports

Spree 6 does analytics through a **semantic layer**: a registry of *metrics* (numbers), *dimensions* (ways to group and filter) and *counters* (point-in-time "needs attention" numbers). One query contract compiles any valid combination into SQL. You extend the vocabulary; you don't write report classes. The dashboard home, the Reports builder, saved reports and CSV report export all read the same registry.

CSV data moves through a separate, older pipeline: `Spree::Export` / `Spree::Import` STI subclasses running as background jobs.

## Decision guide

| You want… | Do this |
|---|---|
| A new number merchants can chart/rank | `Spree.reporting.metric` |
| A new way to slice existing numbers ("by seller", "by locale") | `Spree.reporting.dimension` |
| A "N things need attention" card / sidebar badge | `Spree.reporting.counter` |
| Change what a built-in number means | `metric :name, replace: true, ...` (affects every saved report — prefer a new name) |
| Query a table core reporting doesn't know | `Spree.reporting.base` **plus** an adapter table-map entry (see Limits) |
| A row-level CSV dump of a model | `Spree::Export` subclass registered in `Spree.export_types` |
| Bulk create/update records from CSV | `Spree::Import` subclass + import schema + row processor, in `Spree.import_types` |

## Registering vocabulary

Core seeds its vocabulary in an engine initializer that runs **before** `load_config_initializers`, so a plain initializer can append to it (wrapping in `Rails.application.config.after_initialize` also works):

```ruby
# server/config/initializers/spree.rb
Spree.reporting.metric :items_sold,
  sql: 'SUM(%{line_items}.quantity)', base: :line_items, format: :integer

Spree.reporting.metric :avg_items_per_order,
  ratio: %i[items_sold orders], format: :decimal   # derived — computed after aggregation, never AVG()

Spree.reporting.dimension :order_locale, base: :orders, column: :locale
```

### Metrics

- `base:` — one of the registered bases. Core: `:orders`, `:line_items` (family `sales`), `:payments` (`payments`), `:stock_movements` (`inventory`), `:carts` (`carts`). **A query may use only one family**; mixing is refused.
- `sql:` — portable aggregate fragment. Placeholders like `%{orders}`, `%{line_items}`, `%{variants}`, `%{products}`, `%{addresses}`, `%{refunds}`, `%{fees}` interpolate to real table names. No DB-specific functions.
- `format:` — `:money`, `:integer` (default), `:decimal`, `:percent` (returned as `42.5`, not `0.425`).
- `ratio: [:numerator, :denominator]` — derived metric, correct for both rows and totals.
- Optional: `subject:` + `key_scope:` (for money outside the order, e.g. commission), `requires_grouping:` (per-group-only figures like lifetime value), `grouped_sql:`, `suggests:`.

Money is **never converted**. A query containing a `:money` metric is scoped to one currency (the one it names, else the store default). A query with no money in it is not currency-scoped at all — `orders` alone counts every order.

### Dimensions

Simple column: `dimension :order_locale, base: :orders, column: :locale`.

A dimension whose keys are records declares resolution, display and authorization together:

```ruby
Spree.reporting.dimension :seller, base: :line_items,
  column: '%{variants}.seller_id',
  joins: [:variant],                 # applied to the grouped query only
  lookup: :seller,
  subject: -> { Spree::Seller },     # staff need :read on this
  key_scope: 'read_sellers',         # API keys need this scope
  resolve: ->(store, value) { store.sellers.find_by_prefix_id!(value).id },
  hydrate: lambda { |store, ids, _params|
    store.sellers.where(id: ids).to_h { |s| [s.id, { id: s.prefixed_id, label: s.name, meta: {} }] }
  }
```

Other options: `type: :time` + `grains:` (time buckets, zero-filled, store timezone), `expression:` (SQL key when no column can answer — same trust as metric SQL), `values:` (array or lambda of enumerated raw values → checkbox filters; label them under `spree.reporting.values.<dimension>.<value>`), `population:` (lambda `(store) -> relation`, required for `include_empty`).

Labels for metrics/dimensions go in the server locale: `spree.reporting.metrics.<name>.label` / `.description`.

### Counters

Point-in-time, no time range, no currency, no base:

```ruby
Spree.reporting.counter :orders_on_hold,
  subject: -> { Spree::Order }, key_scope: 'read_orders',
  count: ->(store, channel:) { store.orders.placed_orders.for_channel(channel).where(on_hold: true).count },
  link: { resource: 'orders', filters: [{ field: 'on_hold', operator: 'eq', value: 'true' }] },
  nav: 'orders'   # optional: badge this sidebar entry
```

The endpoint returns keys and numbers only — the dashboard owns the text (`admin.pages.home.operations.counters.<key>.label` in dashboard locales; falls back to the humanized key). Only declare `link` when that list filter shows exactly the rows counted. (Adapt the `count` lambda to your real columns — `on_hold` above is illustrative.)

### Duplicates and overrides

Registering an existing name raises `ArgumentError ... (pass replace: true to override)`. Declaring `subject` without `key_scope` raises at registration, as does a dimension with neither `column` nor `expression`.

## Querying

Contract (same for Ruby, `POST /api/v3/admin/reporting/query`, and `adminClient.reporting.query`):

```json
{
  "metrics": ["total_sales", "orders"],
  "dimensions": [{ "name": "completed_at", "grain": "week" }],
  "filters": [{ "dimension": "channel", "op": "eq", "value": "ch_86Rf07xd4z" }],
  "time_range": { "preset": "last_4_weeks" },
  "compare": "previous_period",
  "currency": "EUR",
  "sort": "-total_sales",
  "limit": 50
}
```

- At most two dimensions. Filters: `eq` / `in`, values are prefixed IDs for record dimensions.
- `time_range`: presets (`today`, `yesterday`, `week_to_date`, `month_to_date`, `quarter_to_date`, `year_to_date`, `last_week`, `last_month`, `last_quarter`, any `last_<n>_<days|weeks|months>`) or `since`/`until` ISO 8601.
- Unknown members raise `Spree::Reporting::UnknownMember`; malformed queries `Spree::Reporting::InvalidQuery` → 422. Nothing is silently dropped.

```ruby
Spree::Reporting::Query.new(
  store: store,
  params: { metrics: %w[items_sold], dimensions: %w[order_locale], time_range: { preset: 'last_30_days' } }
).execute   # => Spree::Reporting::Result (rows + totals)
```

Build UI pickers from `GET /api/v3/admin/reporting/schema` (`adminClient.reporting.schema()`), which returns only what the **calling credential** may use. Counters: `GET /api/v3/admin/dashboard/counters?channel_id=…` (`adminClient.dashboard.counters()`).

### Authorization

- Staff JWT: `read_reports` + `:read` on each member's `subject`.
- API key: `read_reports` + each member's `key_scope`.
- `query.required_subjects` / `query.required_key_scopes` expose what a query needs — worth asserting in a spec for your extension's members.

### What the numbers mean

- Canceled orders are excluded from sales bases.
- Sales chain: `gross_sales − discounts − returns = net_sales`; `net_sales + shipping + duties + fees + taxes = total_sales`. `returns` lands in the period the refund was issued.
- The Total row is computed without grouping joins, so **rows of a fan-out breakdown (e.g. by category) need not sum to the total** — that's correct, not a bug.
- `cost_of_goods` / margins read nullable `cost_price`; uncosted variants make margin look high.

## Saved reports

`Spree::SavedReport` (prefix `sq_`, store-scoped, `publishes_lifecycle_events` → `saved_report.created/updated/deleted`) stores a name + query JSON. It validates that the query compiles against the current registry, so removing a metric an existing report uses will make that report invalid. Seeded reports (`seeded: true`) are read-only — copy to change. Visualization is inferred from shape (time dimension → chart, other dimension → ranking, none → totals). API: `/api/v3/admin/reporting/saved_reports` (`adminClient.reporting.savedReports.*`). CSV export of a report is `Spree::Exports::Report`; it re-authorizes against a user, so API keys can't queue one.

## Exports

Built-in types (`Spree.export_types`): Products, ProductTranslations, Orders, Customers, GiftCards, NewsletterSubscribers, CouponCodes, PriceListPrices, PurchaseOrders, Report. Prefix `exp_`.

Flow: create → `export.created` event → `Spree::ExportSubscriber` enqueues `Spree::Exports::GenerateJob` → CSV attached to private storage → email to the requesting admin user (none for API-key-created exports).

```ts
const exp = await adminClient.exports.create({
  type: 'orders',                                   // api_type of the class
  search_params: { completed_at_gteq: '2026-01-01' }, // Ransack hash; or record_selection: 'all'
})
const polled = await adminClient.exports.get(exp.id)
polled.done          // boolean — exports have no status column
polled.download_url  // set once done; streams via /api/v3/admin/exports/:id/download
```

Custom export type:

```ruby
# app/models/spree/exports/brands.rb
module Spree
  module Exports
    class Brands < Spree::Export
      def scope_includes = [:products]
      def csv_headers = Spree::CSV::BrandPresenter::HEADERS + custom_fields_headers
    end
  end
end
# Model class is inferred (Brands → Spree::Brand; override self.model_class otherwise).
# Each record must respond to #to_csv(store) returning one row (or override multi_line_csv?).

# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.export_types << Spree::Exports::Brands
end
```

The export scope is `for_store(store)` when the model supports it — keep your model store-scoped. Draft orders are left out of every orders export (any model responding to `not_drafts` gets that scope), matching the Orders list. A seller-scoped export ransacks `search_params` with the `:seller` audience, so conditions on data the seller can't read (the buyer's `email`) are ignored (see `spree-api-v3`). Keep `scope_includes` to real associations — a bad preload makes every generate job fail, and with no `export.failed` event the export just never becomes `done`. API keys need `read_<required_scope>` (derived from the class name, e.g. `read_brands`; override `self.required_scope`).

## Imports

Built-in types (`Spree.import_types`): Products, ProductTranslations, Customers, PriceListPrices, PurchaseOrders. Prefix `imp_`. Orders are export-only on purpose.

Statuses (`has_status`): `pending → mapping → completed_mapping → processing → completed`, or `failed`. Rows (`Spree::ImportRow`) have `pending/processing/completed/failed`. Transitions run as workflows (`Spree.import_start_mapping_workflow`, `import_complete_mapping_workflow`, `import_start_processing_workflow`, `import_complete_workflow`, `import_retry_failed_rows_workflow`); the old bang methods (`complete_mapping!`, `retry_failed_rows`, …) are deprecated.

```ts
const imp = await adminClient.imports.create({ type: 'products', file: signedBlobId })
await adminClient.imports.completeMapping(imp.id, {
  mappings: [{ schema_field: 'sku', file_column: 'Item Code' }],
})
const { data: failed } = await adminClient.imports.rows.list(imp.id, { status_eq: 'failed' })
await adminClient.imports.retryFailedRows(imp.id)   // re-runs only failed rows
```

- A failed row never stops the import; it records `validation_errors`.
- Processing uses resumable jobs (cursor = row number): a deploy mid-import resumes, it doesn't restart.
- Non-numeric values are rejected, never guessed (`"12,50"` fails).
- Preferences: `preferred_inline` (run in-process — rake/seeds/console only, never from a request), `preferred_skip_events` (suppress per-row `product.created`, `import_row.*`), `preferred_delimiter`.
- Templates/examples: `GET /api/v3/admin/imports/template?type=…` and `/imports/example`.

Custom import type = three pieces:

```ruby
module Spree
  module ImportSchemas
    class Brands < Spree::ImportSchema
      FIELDS = [{ name: 'name', label: 'Name', required: true }, { name: 'slug', label: 'Slug' }].freeze
    end
  end
  module Imports
    module RowProcessors
      class Brand < Base
        def process!
          brand = import.store.brands.find_or_initialize_by(name: attributes['name'])
          brand.slug = attributes['slug'] if attributes['slug'].present?
          brand.save!
          brand
        end
      end
    end
    class Brands < Spree::Import
      def row_processor_class = Spree::Imports::RowProcessors::Brand
    end
  end
end

Rails.application.config.after_initialize { Spree.import_types << Spree::Imports::Brands }
```

The schema is looked up as `Spree::ImportSchemas::<TypeName>` and the model as `Spree::<TypeName.singularize>` — keep the names aligned or override `import_schema` / `model_class`. Custom field columns are added automatically when the model supports custom fields. API keys need `write_<required_scope>`.

### Events

`import.created/updated/deleted`, `import.progress`, `import.completed`, `import_row.completed/failed`; `export.created/updated/deleted`. There is no `export.completed` or `import.failed` event — for exports, poll `done`; for import failure, watch `import.updated` with `status == 'failed'`.

## Limits (design around these)

- The `%{table}` interpolation map in the Live adapter is fixed; a `base` over your own table needs an adapter entry (`Spree::Dependencies.reporting_adapter` lets you swap the adapter class).
- Dimension `column` must resolve to a plain `table.column`; computed groupings need `expression:` or a real column/DB view.
- The dashboard maps known `lookup` values to pickers; a custom lookup gets a plain ID input.

## Common mistakes

- Using `AVG()` in metric SQL — use `ratio:` so totals are correct.
- Joining refunds/commissions directly in a metric — fans out order rows; use a correlated subquery.
- A base relation lambda `(store, range, currency)` that does `where(currency: currency)` unconditionally — `currency` is `nil` for no-money queries; guard it.
- `subject` without `key_scope` (raises) or `resolve` that isn't store-scoped (cross-store ID leak).
- Expecting breakdown rows to sum to the Total row.
- Putting labels in the dashboard for metrics/dimensions — those are server-side (`spree.reporting.*`); only counter labels live in dashboard locales.
- Registering export/import types in a plain initializer without `after_initialize` — core assigns the default lists in its own `after_initialize`.

## Where to read further

- `node_modules/@spree/docs/dist/developer/core-concepts/reporting.md`
- `node_modules/@spree/docs/dist/developer/how-to/extend-reporting.md`
- `node_modules/@spree/docs/dist/developer/core-concepts/imports-exports.md`
- Source: `spree/core/lib/spree/reporting/` (registry, query, default_vocabulary), `spree/core/app/models/spree/{export,import}.rb`
- Related skills: `spree-auth-permissions` (scopes), `spree-events-webhooks`, `spree-dashboard-plugins`, `spree-marketplace` (seller dimension, commission metrics)
