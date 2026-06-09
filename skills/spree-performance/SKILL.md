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

### Spree.cache_key_with_version on Product

Spree generates cache keys that incorporate the updated_at of Product + its variants + its categories. Use it for HTTP caching and fragment caching:

```ruby
def show
  product = scope.find_by_prefix_id!(params[:id])
  cache_key = Spree.cache_key_with_version(product, ['v3', 'show'])
  fresh_when(etag: cache_key, last_modified: product.updated_at)
  # render serializer
end
```

Touching the product (via `product.touch`) or any of its variants invalidates the cache automatically. Most Spree updates already touch the right records; custom code may need explicit touches.

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

- **Indexing flood.** Every product update fires a `Spree::SearchProvider::IndexJob`. On a bulk import, this swamps Sidekiq. Batch via `Spree::Search.reindex_in_batches(scope)`.
- **Synonyms / typo tolerance config drift.** Meilisearch's tolerance settings live in the index — if you change them in code without reapplying, results don't match expectations. Reapply via `Spree::SearchProvider::Meilisearch::Setup.call`.
- **Result set too large.** Meilisearch returns the full result set by default; bound it via the `limit` query param.

## Image processing

Spree uses ActiveStorage. Image variants (thumbs, smalls, larges) are generated on first request — by default, on the web process.

### Move processing off the web tier

Add `image_processing` jobs to a dedicated queue and process out-of-band:

```ruby
# backend/config/initializers/spree.rb
Spree.queues.images = :images

# Pre-generate variants when a product is created/updated:
Rails.application.config.after_initialize do
  Spree.subscribers << ImageVariantPregenerationSubscriber
end

class ImageVariantPregenerationSubscriber < Spree::Subscriber
  subscribes_to 'variant.updated', async: true

  def handle(event)
    variant = Spree::Variant.find_by_prefix_id(event.payload['id'])
    variant.images.each do |image|
      image.variant(resize_to_limit: [300, 300]).processed
      image.variant(resize_to_limit: [600, 600]).processed
    end
  end
end
```

Configure Sidekiq to run `images` queue on a separate worker process (or with lower concurrency) so it doesn't starve other queues.

### Use a CDN

ActiveStorage serves images via Rails by default. For production, route via CloudFront / Cloudflare with a long cache TTL. The Spree image URL helpers are CDN-friendly.

## Sidekiq queue configuration

Spree organizes background work into named queues. Default configuration routes everything to `default`, but you can split for production:

```ruby
# backend/config/initializers/spree.rb
Spree.queues.images = :images
Spree.queues.search = :search
Spree.queues.events = :events
Spree.queues.webhooks = :webhooks
Spree.queues.payment_webhooks = :payment_webhooks
Spree.queues.products = :catalog
Spree.queues.variants = :catalog
Spree.queues.exports = :reports
Spree.queues.imports = :imports
```

Then run Sidekiq with explicit queue weights:

```bash
bundle exec sidekiq -q payment_webhooks,5 -q events,4 -q default,3 -q search,2 -q catalog,2 -q images,1
```

Why weights matter: payment webhooks must process fast (customer is waiting); image processing can lag. Without weights, image jobs flood and delay payment events.

The full queue list lives in `Spree.queues` (see `bundle show spree_core`/lib/spree/core.rb).

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

For the storefront, cache fragments keyed by `Spree.cache_key_with_version`:

```erb
<% cache Spree.cache_key_with_version(product, ['pdp', 'v1']) do %>
  <%= render 'pdp', product: product %>
<% end %>
```

Updates to the product (or any touched association) automatically bust the cache.

### Rails.cache for expensive computations

For per-store computed values (active promo banner, configured currencies, available payment methods):

```ruby
Rails.cache.fetch(['store', current_store.cache_key_with_version, 'banner'], expires_in: 5.minutes) do
  ActiveBannerService.call(current_store)
end
```

Don't cache anything tied to the customer (cart, account) — it varies per session and pollutes the cache.

### HTTP caching on the Store API

`Spree::Api::V3::HttpCaching` concern (mixed into select controllers) sets ETag + Last-Modified based on the model. CDN respects these. For most read endpoints, including this concern is enough.

## Profiling tools

- **rack-mini-profiler** — already in `:development` group. Look for the badge on every page; click for the query waterfall.
- **bullet** — detects N+1s in development. Add to the Gemfile, configure to notify on N+1.
- **Skylight / Scout / NewRelic** — production APM. All work fine with Spree out of the box.
- **`Spree::Subscribers::ActiveSupport::Notifications`** — Spree fires `sql.active_record`, `cache.read`, `cache.write` notifications. Hook into them for custom dashboards.

## Where to read further

- **Queue config:** `bundle show spree_core`/lib/spree/core.rb (`Spree.queues`).
- **Cart pipeline:** `Spree::Cart::Recalculate` and its dependencies in `spree_core/app/services/spree/cart/`.
- **Search provider:** `Spree::SearchProvider::Base` and the Meilisearch subclass.
- **Docs:** `backend/node_modules/@spree/docs/dist/developer/deployment/performance.mdx` (if shipped) or the deployment section generally.
- **CLAUDE.md performance guidance** in your project root may have project-specific notes.
