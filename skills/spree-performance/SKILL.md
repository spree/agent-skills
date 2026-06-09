---
name: spree-performance
description: Use when the user is investigating or improving Spree performance — slow product listings, slow cart updates, search latency, image processing bottlenecks, Sidekiq queue tuning, N+1 in admin pages, cache invalidation strategies. Common phrasings include "slow PDP", "slow cart", "N+1 queries in Spree", "Sidekiq queue backlog", "search slow", "Meilisearch tuning", "image processing slow", "Spree cache". Provides the Spree-specific performance hotspots and the tools to address them.
---

# Spree Performance

Most Spree performance work has more leverage than generic Rails tuning because the bottleneck is usually in one of a few known hotspots. This skill covers those.

## The biggest leverage areas

In rough order of impact for typical Spree stores:

1. **Cart pipeline cost on every cart change.** `Spree::Cart::Recalculate` is the most-run service in the app — every add, remove, address change fires it. A slow recalculate makes the storefront feel sluggish.
2. **Catalog rendering N+1s.** Product listing pages load Products, then prices, then images, then variants, then categories — easy to hit dozens of queries per product.
3. **Search provider latency.** Database search degrades past ~10K products. Meilisearch's network round-trip + result deserialization adds up if not bounded.
4. **Image processing.** Generating thumbnails for the storefront on first request is slow and CPU-bound — and falls on the web process by default.
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

If you have a recalculate step that's slow (external service call, complex computation), make it async via Sidekiq instead of inline. The customer doesn't need to wait for an analytics push; fire-and-forget via a subscriber on `cart.update` (see the `spree-events-webhooks` skill).

### Profiling the recalculate

Sample any cart in the Rails console:

```ruby
order = Spree::Order.find(123)
require 'rack-mini-profiler'
ActiveRecord::Base.logger.level = Logger::DEBUG
Spree::Cart::Recalculate.call(order: order)
```

Read the query log. Anything above ~50 queries for a 5-item cart is high. Anything that issues per-line-item queries is fixable with eager loading.

## Catalog rendering

The classic Spree catalog page (PLP) hits N+1s by default. Spree includes `ar_lazy_preload` to mitigate, but only for paths that use it.

### Variant.preload_associations_lazily

`Spree::Variant.preload_associations_lazily` is a scope that adds the common associations (`prices`, `images`, `option_values`, `stock_items`) as lazy preloads. Use it in any catalog query:

```ruby
@products = Spree::Product.for_store(current_store)
                          .available(Spree::Current.currency)
                          .includes(default_variant: [], variants: :prices)
                          .preload(master: :images)
                          .page(params[:page])
```

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

Fine for catalogs < 10K products. Past that, the `ILIKE` queries on Product.name slow down.

If you must stay on Database:
- Ensure `pg_trgm` extension is enabled for fuzzy matching
- Index trigrams on `spree_products(name)`:
  ```sql
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  CREATE INDEX idx_spree_products_name_trgm ON spree_products USING gin (name gin_trgm_ops);
  ```
- Tune `default_per_page` lower to limit result set size

### Meilisearch provider

The right choice for medium-to-large catalogs.

**Common Meilisearch performance issues:**

- **Indexing flood.** Every product update enqueues a `Spree::SearchProvider::IndexJob` (it runs on `Spree.queues.search`). On a bulk import this swamps Sidekiq — pause the queue, do the import, then trigger a single `bin/rake spree:search:reindex` afterwards.
- **Synonyms / typo tolerance config drift.** Meilisearch's tolerance settings live on the index — if you change configuration code without re-running setup, results won't match expectations. The Meilisearch provider's `reindex` re-applies index settings.
- **Result set too large.** Bound result sizes via `limit` query param; default page sizes in the API are usually right.

## Image processing

Spree uses ActiveStorage. Image variants (thumbs, smalls, larges) are generated on first request — by default, on the web process.

### Move processing off the web tier

Pre-generate variants in a background job instead of letting the first storefront request do the work. A subscriber on `variant.updated` (lifecycle event) does the trick:

```ruby
# backend/app/subscribers/image_variant_pregeneration_subscriber.rb
class ImageVariantPregenerationSubscriber < Spree::Subscriber
  subscribes_to 'variant.updated', async: true

  def handle(event)
    variant = Spree::Variant.find_by(id: event.payload['id'])
    return unless variant

    variant.images.each do |image|
      image.variant(resize_to_limit: [300, 300]).processed
      image.variant(resize_to_limit: [600, 600]).processed
    end
  end
end

# backend/config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.subscribers << ImageVariantPregenerationSubscriber
end
```

Run image-heavy Sidekiq queues on a separate worker process with lower concurrency so they don't starve customer-facing queues.

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

The legacy Rails admin product listing pre-loads associations via `Spree.admin.tables.products` registration. If you customize columns, ensure your new column has a preload hint:

```ruby
Spree.admin.tables.products.add :brand_name,
  preload: { brand: [] },        # eager-load to avoid per-row query
  ...
```

For the React dashboard, columns are populated via the Admin API which uses serializer-level includes — `?include=brand,categories,images` on the request. The dashboard's resource hooks set these correctly by default; custom additions need to update the `include` param.

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

Spree's v3 controllers set ETag and Last-Modified headers based on the model's `cache_key_with_version` and `updated_at`. CDNs (Cloudflare, Fastly, CloudFront) respect these — configure them to cache `/api/v3/store/products`-style endpoints with conditional revalidation.

## Profiling tools

- **rack-mini-profiler** — usually in the `:development` group. Look for the badge on every page; click for the query waterfall.
- **bullet** — detects N+1s in development. Add to the Gemfile and configure to notify on N+1.
- **Skylight / Scout / New Relic** — production APM. All work fine with Spree out of the box.
- **ActiveSupport::Notifications** instrumentation — Spree (via Rails) fires `sql.active_record`, `process_action.action_controller`, `cache.read`, `cache.write`. Hook into them for custom dashboards: `ActiveSupport::Notifications.subscribe('sql.active_record') { |...| ... }`.

## Where to read further

- **Cart pipeline:** `Spree::Cart::Recalculate` and its dependencies in `spree_core/app/services/spree/cart/`.
- **Search provider:** `Spree::SearchProvider::Base` and `Spree::SearchProvider::Meilisearch` in the installed `spree_core` gem.
- **Deployment caching:** `node_modules/@spree/docs/dist/developer/deployment/caching.mdx`.
- **Search + filtering:** `node_modules/@spree/docs/dist/developer/core-concepts/search-filtering.mdx`.
