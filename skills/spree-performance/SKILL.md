---
name: spree-performance
description: Use when the user is investigating or improving Spree performance — slow product listings, slow cart updates, search latency, image processing bottlenecks, Sidekiq queue tuning, N+1 in admin pages, cache invalidation strategies. Common phrasings include "slow PDP", "slow cart", "N+1 queries in Spree", "Sidekiq queue backlog", "search slow", "Meilisearch tuning", "image processing slow", "Spree cache". Provides the Spree-specific performance hotspots and the tools to address them.
---

# Spree Performance

Most Spree performance work has more leverage than generic Rails tuning because the bottleneck is usually in one of a few known hotspots. This skill covers those.

## The biggest leverage areas

In rough order of impact for typical Spree stores:

1. **Cart pipeline cost on every cart change.** `Spree::Cart::Recalculate` is the most-run service in the app — every line-item add, remove, and quantity change fires it. A slow recalculate makes the storefront feel sluggish.
2. **Catalog rendering N+1s.** Product listing pages load Products, then prices, then images, then variants, then categories — easy to hit dozens of queries per product.
3. **Search provider latency.** Database search degrades past ~10K products. Meilisearch's network round-trip + result deserialization adds up if not bounded.
4. **Image processing.** Generating image variants is slow and CPU-bound — variants are pre-generated in background transform jobs at upload time, and bulk uploads can flood the queue.
5. **Sidekiq queue backlog.** Per-queue weights matter — image processing flooding the `default` queue blocks event subscribers from firing in time.
6. **Admin product table.** The N+1 problem with 100+ products and all-columns-visible is real.

## The cart pipeline

Every cart change runs `Spree.cart_recalculate_service` (default: `Spree::Cart::Recalculate`). The chain reads line items, prices, adjustments, shipments, promotions, computes totals, and writes the order back.

### Common cart-pipeline N+1s

Each line item lazily loads its variant, then the variant's price, then the variant's images for the cart UI. Eager-load before iterating:

```ruby
order.line_items.includes(variant: [:prices, :images, product: :categories]).each do |li|
  # ...
end
```

In a custom recalculate step, prefer batch operations over per-item loops. If you must loop, eager-load the associations the loop touches.

### Sidekiq for slow recalculate work

If you have a recalculate step that's slow (external service call, complex computation), make it async via Sidekiq instead of inline. The customer doesn't need to wait for an analytics push; fire-and-forget via a subscriber on `order.updated` (see the `spree-events-webhooks` skill).

### Profiling the recalculate

Sample any cart in the Rails console:

```ruby
order = Spree::Order.find(123)
ActiveRecord::Base.logger.level = Logger::DEBUG
Spree::Cart::Recalculate.call(order: order, line_item: order.line_items.first)
```

Read the query log. Anything above ~50 queries for a 5-item cart is high. Anything that issues per-line-item queries is fixable with eager loading.

## Catalog rendering

The classic Spree catalog page (PLP) hits N+1s by default. Spree includes `ar_lazy_preload` to mitigate, but only for paths that use it.

### preload_associations_lazily

`preload_associations_lazily` (from the ar_lazy_preload gem) is available on any relation — it auto-preloads whichever associations the iteration touches, with no per-model list. Spree's own controllers chain it on collections (see `Spree::Api::V3::ResourceController#collection`). Use it on custom catalog queries:

```ruby
@products = Spree::Product.for_store(current_store)
                          .active(Spree::Current.currency)
                          .includes(
                            primary_media: [attachment_attachment: :blob],
                            master: [:prices, stock_items: [:stock_location, :active_stock_reservations]],
                            variants: [:prices, stock_items: [:stock_location, :active_stock_reservations]]
                          )
                          .preload_associations_lazily
@pagy, @products = pagy(@products, page: params[:page], limit: params[:per_page])
```

Pagination is Pagy (Spree's only pagination dependency) — the `pagy(...)` call mirrors `Spree::Api::V3::ResourceController#collection`. There is no Kaminari-style `.page` scope on Spree models.

For the most common path (default-variant-only listing), the API's `ProductsController#scope` already does the right thing. If you're building a custom catalog endpoint, copy that pattern.

### `cache_key_with_version`

Every Spree model that's `Spree.base_class`-derived has a `cache_key_with_version` instance method (from ActiveRecord) — it folds in the model's `updated_at`. Use it for HTTP caching and fragment caching:

```ruby
def show
  product = scope.find_by_prefix_id!(params[:id])
  fresh_when(etag: product.cache_key_with_version, last_modified: product.updated_at)
  # render serializer
end
```

```erb
<% cache [product.cache_key_with_version, 'pdp'] do %>
  <%= render 'pdp', product: product %>
<% end %>
```

`product.touch` (or touching any has_many child that the model `belongs_to :product, touch: true` on) bumps the version and invalidates the cache.

## Search provider performance

### Database provider (default)

Fine for catalogs < 10K products. Past that, text search slows down: the Database provider runs `Spree::Variant.product_name_or_sku_cont`, whose predicate is `LOWER(spree_products.name) ILIKE '%q%' OR LOWER(spree_variants.sku) ILIKE '%q%'` through a variants→products join (when translations are enabled, the product translations table replaces `spree_products.name`).

If you must stay on Database:
- `pg_trgm` is already enabled by a core migration on PostgreSQL (when the extension is available on the server)
- Index the expressions actually queried — note the `lower(...)` wrapper; a trigram index on the bare column won't be used:
  ```sql
  CREATE INDEX idx_spree_products_lower_name_trgm ON spree_products USING gin (lower(name) gin_trgm_ops);
  CREATE INDEX idx_spree_variants_lower_sku_trgm ON spree_variants USING gin (lower(sku) gin_trgm_ops);
  ```
- Because the OR spans two joined tables, the planner may still fall back to scans on large catalogs — that's the signal to switch to Meilisearch
- Pass a lower `limit` query param on API requests (default 25); for the legacy storefront, lower `Spree::Config[:products_per_page]` (default 12)

### Meilisearch provider

The right choice for medium-to-large catalogs.

**Common Meilisearch performance issues:**

- **Indexing flood.** Every product update enqueues a `Spree::SearchProvider::IndexJob` (it runs on `Spree.queues.search`). On a bulk import this swamps Sidekiq — pause the queue, do the import, then trigger a single `bin/rake spree:search:reindex` afterwards.
- **Synonyms / typo tolerance config drift.** Meilisearch's tolerance settings live on the index — if you change configuration code without re-running setup, results won't match expectations. The Meilisearch provider's `reindex` re-applies index settings.
- **Result set too large.** Bound result sizes via `limit` query param; default page sizes in the API are usually right.

## Image processing

Spree uses ActiveStorage and pre-generates product image variants at upload time. `Spree::Asset` declares a named ActiveStorage variant per entry in `Spree::Config.product_image_variant_sizes` (defaults: mini 128, small 256, medium 400, large 720, xlarge 2000, og_image 1200×630) as webp `resize_to_fill` with `preprocessed: true`, so ActiveStorage enqueues transform jobs in the background when the image is attached — no first-request processing on the web tier. The Store API's media serializer serves exactly these named variants (`mini_url`, `small_url`, …).

### Performance levers

- Customize `Spree::Config.product_image_variant_sizes` in an initializer — fewer/smaller sizes means less transform work per upload (it must be set in an initializer, since the variant definitions are read when the model loads).
- Route ActiveStorage transform jobs to a dedicated low-concurrency queue so bulk image imports don't starve customer-facing work: `config.active_storage.queues.transform = :images`, then run that queue on a separate Sidekiq worker process.

Don't bother pre-warming variants from a subscriber — it duplicates the built-in behavior, and ad-hoc `resize_to_limit` variants have a different variation digest than the named webp variants, so the storefront never serves them. A pre-warming job only makes sense for custom, non-default variant transformations your own code requests.

### Use a CDN

ActiveStorage serves images via Rails by default. For production, route via CloudFront / Cloudflare with a long cache TTL. The Spree image URL helpers are CDN-friendly.

## Sidekiq queue configuration

Spree organizes background work into named queues exposed via `Spree.queues`. By default every queue is mapped to `:default`, but the names are distinct so you can route them to dedicated queues in production:

```ruby
# backend/config/initializers/spree.rb
Spree.queues.payment_webhooks = :payment_webhooks
Spree.queues.events           = :events
Spree.queues.webhooks         = :webhooks
Spree.queues.images           = :images
Spree.queues.search           = :search
Spree.queues.products         = :catalog
Spree.queues.variants         = :catalog
Spree.queues.exports          = :reports
Spree.queues.imports          = :imports
```

Then run Sidekiq with explicit queue weights:

```bash
bundle exec sidekiq -q payment_webhooks,5 -q events,4 -q default,3 -q search,2 -q catalog,2 -q images,1
```

Why weights matter: payment webhooks must process fast (customer is waiting); image processing can lag. Without weights, image jobs flood and delay payment events.

The full queue list lives in `Spree.queues` in `spree_core/lib/spree/core.rb` of the installed gem. Available: `default`, `events`, `exports`, `images`, `imports`, `products`, `reports`, `variants`, `taxons`, `stock_location_stock_items`, `coupon_codes`, `themes`, `addresses`, `gift_cards`, `webhooks`, `payment_webhooks`, `api_keys`, `search`, `stock_reservations`.

## Admin product table N+1

The Rails admin preloads associations in the controller, not the table registry. The base `Spree::Admin::ResourceController` chains `.includes(collection_includes)` onto the scope and applies `preload_associations_lazily` (the ar_lazy_preload gem) to the collection; `Spree::Admin::ProductsController#collection_includes` supplies the products-table preloads (media attachments, stock items, master/variant prices) that ar_lazy_preload can't pick up automatically. If a custom column triggers per-row queries, override `collection_includes` in a controller decorator to add the association. `Spree.admin.tables.products.add` only defines the column (label, type, sortable, filterable, etc.) — it accepts no `preload:` option, and passing one raises `ActiveModel::UnknownAttributeError`.

## Caching patterns

### Russian-doll fragment caching

For the storefront, cache fragments keyed by the model's `cache_key_with_version`:

```erb
<% cache [product.cache_key_with_version, 'pdp', 'v1'] do %>
  <%= render 'pdp', product: product %>
<% end %>
```

Updates to the product (or any `touch:`-linked association) automatically bust the cache.

### Rails.cache for expensive computations

For per-store computed values (active promo banner, configured currencies, available payment methods):

```ruby
Rails.cache.fetch(['store', current_store.cache_key_with_version, 'banner'], expires_in: 5.minutes) do
  ActiveBannerService.call(current_store)
end
```

Don't cache anything tied to the customer (cart, account) — it varies per session and pollutes the cache.

### HTTP caching on the Store API

Only the Store API catalog controllers (products, categories, countries, currencies, markets, locales, policies) opt into `Spree::Api::V3::HttpCaching` — the base v3 `ResourceController` ships no-op caching hooks. For guest (unauthenticated) requests it sets a public Cache-Control (5-minute TTL by default): show actions use Rails `stale?` on the record (ETag from `cache_key_with_version`, Last-Modified from `updated_at`), while index actions get a digest ETag built from the collection's latest `updated_at`, count, and query params. Authenticated requests are sent `Cache-Control: private, no-store`, so CDNs (Cloudflare, Fastly, CloudFront) can only cache guest `/api/v3/store/products`-style traffic with conditional revalidation; guest responses `Vary` on `Accept`, `x-spree-currency`, and `x-spree-locale`.

## Profiling tools

- **rack-mini-profiler** — add it to the Gemfile first (it is not in spree-starter by default). Look for the badge on every page; click for the query waterfall.
- **bullet** — detects N+1s in development. Add to the Gemfile and configure to notify on N+1.
- **Skylight / Scout / New Relic** — production APM. All work fine with Spree out of the box.
- **ActiveSupport::Notifications** instrumentation — Spree (via Rails) fires `sql.active_record`, `process_action.action_controller`, `cache.read`, `cache.write`. Hook into them for custom dashboards: `ActiveSupport::Notifications.subscribe('sql.active_record') { |...| ... }`.

## Where to read further

- **Cart pipeline:** `Spree::Cart::Recalculate` and its dependencies in `spree_core/app/services/spree/cart/`.
- **Search provider:** `Spree::SearchProvider::Base` and `Spree::SearchProvider::Meilisearch` in the installed `spree_core` gem.
- **Deployment caching:** `node_modules/@spree/docs/dist/developer/deployment/caching.md`.
- **Search + filtering:** `node_modules/@spree/docs/dist/developer/core-concepts/search-filtering.md`.
