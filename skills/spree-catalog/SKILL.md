---
name: spree-catalog
description: Use when the user is working with Spree's product catalog — Products, Variants, Options, Categories, search, images, product publication on channels. Common phrasings include "add a product type", "variants vs options", "product taxonomy", "categorize products", "product images", "Meilisearch reindex", "search broken", "product not showing in store", "publish product on channel", "master variant", "default variant", "SKU". Provides the catalog graph and the operations on it; defers to local @spree/docs for field-level detail.
---

# Spree Catalog

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

The catalog is everything that's for sale: Products, the Variants underneath them, the Options that distinguish those Variants, the Categories that group them, and the search index that makes them findable.

## The catalog graph

```
Product
  ├── Variant (one master + zero or more "real" variants; master flagged via `is_master`)
  │     ├── Price (per currency)
  │     ├── StockItem (per stock location)
  │     ├── VariantMedia (images, videos, focal point — 5.5)
  │     └── OptionValue × OptionValueVariant
  ├── Category × Classification (the join)
  ├── ProductPublication × Channel (5.5 — which channels surface this product)
  ├── ProductPromotionRule (which promos this product qualifies for)
  └── Metafield (custom fields — 5.4+)
```

## Product vs Variant

The **Product** is the storefront concept — name, slug, description, category. It rarely changes once published.

The **Variant** is the SKU — what gets added to a cart, what has a price, what has inventory. A Product has at least one Variant.

### Master variant and default variant

Every Product has a "master" Variant — `Product.master` — which historically holds default attributes (price, weight, SKU) when the Product has no real variants. Real variants override.

```ruby
product = Spree::Product.find_by(slug: 'cool-shirt')
product.master            # => the master variant (default attributes)
product.variants          # => non-master "real" variants (color/size combos)
product.variants_including_master   # => everything
```

If a Product has variants (color × size), the master is mostly a placeholder; default pricing/SKU still lives there as a fallback.

`Product#default_variant` is a computed helper, not a stored column. With `Spree::Config[:track_inventory_levels]` enabled it returns the first purchasable (in-stock or backorderable) variant; if none qualifies — or inventory tracking is off — it returns the first variant by position. A product with no real variants falls back to the master:

```ruby
product.default_variant   # => first purchasable (or first-by-position) variant; master if the product has no variants
```

A real `default_variant_id` FK on Product is planned for 6.0 (`6.0-remove-master-variant.md`, implementation not started). Today `Product#default_variant_id` is just a memoized method returning `default_variant.id`, and `master` is still the live mechanism — not a backwards-compatibility accessor.

## Options + OptionTypes + OptionValues

This is how Variants distinguish themselves.

```
OptionType  "Size"          ─┐
OptionType  "Color"         ─┤
                             │
ProductOptionType  Product ──┘  (which OptionTypes apply to which Product)

OptionValue  Size: "S"      ─┐
OptionValue  Size: "M"      ─┤
OptionValue  Color: "Red"   ─┤
OptionValue  Color: "Blue"  ─┘

OptionValueVariant  Variant ──┘  (which Values apply to which Variant)
```

A Product declares which OptionTypes apply via `product_option_types`. Each Variant of that Product picks one OptionValue per OptionType. So a "T-Shirt" Product with `[Size, Color]` OptionTypes has Variants like `[Size=M, Color=Red]`, `[Size=L, Color=Blue]`, etc.

```ruby
product.option_types       # => [Size, Color]
variant.option_values      # => [Size=M, Color=Red]
variant.options_text       # => "Size: M, Color: Red"
```

### OptionType `kind` (5.4)

OptionType has a `kind` field controlling how it renders in the admin: `dropdown`, `color_swatch`, `buttons`. OptionValue's `color_code` field stores the hex for `color_swatch` rendering.

```ruby
size = Spree::OptionType.create!(name: 'size', presentation: 'Size', kind: 'buttons')
color = Spree::OptionType.create!(name: 'color', presentation: 'Color', kind: 'color_swatch')

red = color.option_values.create!(name: 'red', presentation: 'Red', color_code: '#ff0000')
```

## Categories (formerly Taxons)

Spree 5.5 added `Spree::Category`, a subclass of `Spree::Taxon` — the merchant-facing concept for the hierarchical product grouping.

```
Category (hierarchical — left/right via awesome_nested_set)
  ├── Classification (the join — multiple Products per Category, multiple Categories per Product)
  ├── permalink         (URL slug, hierarchical: "men/shirts/casual")
  └── i18n on name + description
```

`Spree::Category < Spree::Taxon`, sharing the `spree_taxons` table — but they are not interchangeable: a Category is owned directly via `store_id` and needs no `Taxonomy` (it default-scopes to manually-curated taxons), while a plain `Taxon` requires a parent `Taxonomy`. Use `Spree::Category` in new code; `Spree::Taxon` remains for backwards compatibility.

```ruby
shirts = Spree::Category.find_by(permalink: 'men/shirts')
shirts.products                          # => Products directly in this Category
shirts.descendants                       # => sub-categories
shirts.active_products_with_descendants  # => active Products in this Category or any descendant
```

## ProductPublication (5.5 — channel-scoped visibility)

In 5.5, products belong to a Store via `store_id` (single owner). Visibility per Channel is managed via `ProductPublication`:

```ruby
product.product_publications                                           # ProductPublication × Channel
product.product_publications.where(channel: store.default_channel)     # publication for the default channel
```

A ProductPublication has `published_at` and `unpublished_at` windows. The `Product.for_store(store)` scope returns products owned by a store (`store_id`); per-channel visibility is checked via `Product.for_channel(channel)` / ProductPublications; `Product.active(currency)` filters to products that are live with prices in the requested currency.

**Pre-5.5 (4.x, early 5.x):** Products were on Stores directly via `spree_products_stores`. The 5.4→5.5 upgrade migrates this. See the `spree-upgrade` skill.

## Search

Spree ships a pluggable search provider system in 5.4+:

| Provider | Class | Use when |
|---|---|---|
| Database (default) | `Spree::SearchProvider::Database` | Small catalogs (<10K products); case-insensitive substring (LIKE) matching — no typo tolerance |
| Meilisearch | `Spree::SearchProvider::Meilisearch` | Real-time facets, typo tolerance, large catalogs |

Configured via `Spree.search_provider = 'Spree::SearchProvider::Meilisearch'` in `backend/config/initializers/spree.rb`.

### Reindexing

```bash
spree rake spree:search:reindex
```

The task is a no-op on the Database provider (no index to maintain) and a full catalog push on Meilisearch. Required after:
- Bulk product imports
- Schema changes (new searchable attribute)
- Switching providers
- The 5.4→5.5 channels upgrade (products gain `store_id` and become visible to `for_store`)

### Custom searchable attributes

Spree's search-indexed fields come from `Spree::Product#search_presentation`, which returns the array of document hashes (one per market × locale combination) that gets pushed to the index. Override via a decorator or — preferred — swap the presenter via `Spree::Dependencies.search_product_presenter_class`. After changes, reindex.

## Images + Media

5.5 added product-level media. Media records (`Spree::Asset` subclasses) have a `media_type` from `Spree::Asset::MEDIA_TYPES = %w[image video external_video]`. Images use ActiveStorage attachments; both video media types (`video`, `external_video`) require a URL in `external_video_url` — hosted video-file uploads are not supported. `focal_point` enables crop-aware thumbnails on images.

```ruby
product.media                                       # all media for the product
product.media.where(media_type: 'image').first      # first image
```

The legacy variant-level `Spree::Image` (via `Spree::Asset`) still exists for variants. Variants also expose `variant_media`, `associated_media`, and `gallery_media` for finer-grained queries.

Images use ActiveStorage. Resized derivatives (mini/small/medium/large/xlarge/og_image — see `Spree::Config.product_image_variant_sizes`) are declared with `preprocessed: true`, so ActiveStorage generates WebP variants in background jobs right after upload.

## Brand (custom — your Product's brand)

Spree doesn't ship a Brand model out of the box (different merchants want different brand models — sometimes a Category, sometimes a separate concept with logo/banner/SEO). The `spree:api_resource Brand` generator scaffolds one. See the `spree-resource` skill.

If you scaffold a Brand model, link it from Product via a decorator:

```ruby
module Spree::ProductDecorator
  def self.prepended(base)
    base.belongs_to :brand, class_name: 'Spree::Brand', optional: true
    base.delegate :name, to: :brand, prefix: true, allow_nil: true
  end

  Spree::Product.prepend self
end
```

## Common catalog operations

### "My product isn't showing in the store"

Walk this list:

1. **Is it on the store?** `Spree::Product.for_store(store).where(id: id).exists?` — if false, the Product's `store_id` doesn't point at this store. (Publication checks come next.)
2. **Is it published on the current channel?** `product.product_publications.where(channel: Spree::Current.channel).any?` — if false, no ProductPublication for the channel in scope. (equivalently: `Spree::Product.for_channel(Spree::Current.channel).exists?(id: product.id)`)
3. **Is the publication window active?** (`published_at` is nil OR `published_at <= Time.current`) AND (`unpublished_at` is nil OR `unpublished_at > Time.current`).
4. **Does it have a price in the current currency?** `product.master.prices.where(currency: Spree::Current.currency).any?`
5. **Is it in stock?** `product.in_stock?` — false if no `track_inventory` variant has positive stock.
6. **Is the search index stale?** If using Meilisearch, run `spree rake spree:search:reindex`.

### "Bulk-update prices"

For currency-wide price changes, batch via `Spree::Price.where(currency: 'USD').update_all('amount = amount * 1.1')`. After: the product is fine, but if you have PriceHistory enabled (EU Omnibus), note that `update_all` bypasses the `after_save` callback that records history — iterate and save instead (`Spree::Price.where(currency: 'USD').where.not(amount: nil).find_each { |p| p.update!(amount: p.amount * 1.1) }`) or create `Spree::PriceHistory` rows explicitly. (`spree rake spree:price_history:seed` is only a one-time post-migration backfill that skips any price that already has history rows.) See the `spree-pricing` skill.

### "Add a custom field to Products"

Use Metafields (5.4) — no decorator, no schema change. First create a `MetafieldDefinition` (in the admin or via seed/migration) with a namespace + key + type + `display_on` (`back_end` or `both` — the admin UI doesn't offer a `front_end`-only option for metafields). Then set values per record:

```ruby
product.set_metafield('catalog.season', 'fall-2026')
product.get_metafield('catalog.season')&.value   # => "fall-2026" (get_metafield returns the Spree::Metafield record, or nil)
```

`display_on: front_end` (or `both`) surfaces the metafield on the Store API; `back_end` is admin-only. See `Spree::Metafields` concern and the `spree-resource` skill (`--metafields` flag) for built-in support.

## Where to read further

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/products.md`
- **Media:** `node_modules/@spree/docs/dist/developer/core-concepts/media.md`
- **Search + filtering:** `node_modules/@spree/docs/dist/developer/core-concepts/search-filtering.md`
- **Custom search provider:** `node_modules/@spree/docs/dist/developer/how-to/custom-search-provider.md`
