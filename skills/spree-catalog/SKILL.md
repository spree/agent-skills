---
name: spree-catalog
description: Use when the user is working with Spree's product catalog — Products, Variants, Options, Categories, search, images, product publication on channels. Common phrasings include "add a product type", "variants vs options", "product taxonomy", "categorize products", "product images", "Meilisearch reindex", "search broken", "product not showing in store", "publish product on channel", "master variant", "default variant", "SKU". Provides the catalog graph and the operations on it; defers to local @spree/docs for field-level detail.
---

# Spree Catalog

The catalog is everything that's for sale: Products, the Variants underneath them, the Options that distinguish those Variants, the Categories that group them, and the search index that makes them findable.

## The catalog graph

```
Product
  ├── Variant (one master + zero or more "real" variants; default_variant_id in 6.0)
  │     ├── Price (per currency)
  │     ├── StockItem (per stock location)
  │     ├── VariantMedia (images, videos, focal point — 5.5)
  │     └── OptionValue × ProductOptionType
  ├── Category × CategoryProduct (the join)
  ├── ProductPublication × Channel (5.5 — which channels surface this product)
  ├── ProductPromotionRule (which promos this product qualifies for)
  └── Metafield (custom fields — 5.4+, renaming to CustomField in 6.0)
```

## Product vs Variant

The **Product** is the storefront concept — name, slug, description, category. It rarely changes once published.

The **Variant** is the SKU — what gets added to a cart, what has a price, what has inventory. A Product has at least one Variant.

### Master variant (5.x convention)

Every Product has a "master" Variant — `Product.master` — which holds default attributes (price, weight, SKU) when the Product has no real variants. Real variants override.

```ruby
product = Spree::Product.find_by(slug: 'cool-shirt')
product.master            # => the master variant (default attributes)
product.variants          # => non-master "real" variants (color/size combos)
product.variants_including_master   # => everything
```

If a Product has variants (color × size), the master is mostly a placeholder. Default pricing/SKU still lives there as a fallback.

### Coming in 6.0: `is_master` drops, `default_variant_id` arrives

The 6.0 plan drops the `is_master` boolean and the implicit master concept. Each Product gets a `default_variant_id` FK pointing at one of its variants. Cleaner semantics — no special master/non-master distinction.

**5.x code: keep using `product.master` and `product.variants`.** 6.0 will introduce `product.default_variant` and `product.variants` (no special master anymore). Don't pre-write 6.0 code on 5.x.

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

Spree 5.5 renamed the Taxon model to **Category** for the merchant-facing concept (the 6.0 plan finishes the table rename, but the class alias `Spree::Category < Spree::Taxon` is already in 5.5).

```
Category (hierarchical — left/right via awesome_nested_set)
  ├── CategoryProduct (the join — multiple Products per Category, multiple Categories per Product)
  ├── permalink         (URL slug, hierarchical: "men/shirts/casual")
  └── i18n on name + description
```

Spree 5.5 also introduces **Collection** — a flat or rule-based grouping (e.g. "Summer Sale", "New Arrivals") that's separate from the hierarchical Category tree. The model rename to drop "Taxon" entirely is pending 6.0.

```ruby
shirts = Spree::Category.find_by(permalink: 'men/shirts')
shirts.products              # => all Products in this Category
shirts.descendants           # => sub-categories
shirts.products_in_subtree   # => Products in this Category or any descendant
```

## ProductPublication (5.5 — channel-scoped visibility)

In 5.5, products belong to a Store via `store_id` (single owner). Visibility per Channel is managed via `ProductPublication`:

```ruby
product.publications        # ProductPublication × Channel
product.publications.where(channel: store.default_channel).first.published?   # is it live on the default channel
```

A ProductPublication has `published_at` and `unpublished_at` windows. The `Product.for_store(store)` scope returns products visible on a store; `Product.available(currency)` adds availability + pricing filters.

**Pre-5.5 (4.x, early 5.x):** Products were on Stores directly via `spree_products_stores`. The 5.4→5.5 upgrade migrates this. See the `spree-upgrade` skill.

## Search

Spree ships a pluggable search provider system in 5.4+:

| Provider | Class | Use when |
|---|---|---|
| Database (default) | `Spree::SearchProvider::Database` | Small catalogs (<10K products), PG with `pg_trgm` extension for fuzzy match |
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

Override `searchable_data` on `Spree::Product` (decorator):

```ruby
module Spree::ProductDecorator
  def searchable_data
    super.merge(
      brand_name: brand&.name,
      season: metafields_for('catalog').find { |m| m.key == 'season' }&.value
    )
  end

  Spree::Product.prepend self
end
```

After deploying, reindex.

## Images + Media

5.5 introduced product-level media (`Spree::VariantMedia` — name is misleading; it's product-level, owned via the master variant). Media types: `image`, `external_video_url`. Includes `focal_point` for crop-aware thumbnails.

```ruby
product.master.media     # all media for the product
product.master.media.where(media_type: 'image').first
```

The legacy variant-level `Spree::Image` (via `Spree::Asset`) still exists pre-5.5. The 5.4→5.5 upgrade has an opt-in rake task `spree:media:migrate_master_images_to_product_media` to move them.

Images use ActiveStorage. Variants (resized derivatives like thumb/small/large) are generated lazily on first request via the `image_processing` gem. Pre-generating is possible via a background job.

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

1. **Is it on the store?** `Spree::Product.for_store(store).where(id: id).exists?` — if false, the Product has no `store_id` or no ProductPublication on any of the store's channels.
2. **Is it published on the current channel?** `product.publications.where(channel: Spree::Current.channel).any?` — if false, no ProductPublication for the channel in scope.
3. **Is the publication window active?** `published_at < Time.current` AND (`unpublished_at` is nil OR `unpublished_at > Time.current`).
4. **Does it have a price in the current currency?** `product.master.prices.where(currency: Spree::Current.currency).any?`
5. **Is it in stock?** `product.in_stock?` — false if no `track_inventory` variant has positive stock.
6. **Is the search index stale?** If using Meilisearch, run `spree rake spree:search:reindex`.

### "Bulk-update prices"

For currency-wide price changes, batch via `Spree::Price.where(currency: 'USD').update_all('amount = amount * 1.1')`. After: the product is fine, but if you have PriceHistory enabled (EU Omnibus), generate history entries with `spree rake spree:price_history:seed`. See the `spree-pricing` skill.

### "Add a custom field to Products"

Use Metafields (5.4) — no decorator, no schema change:

```ruby
product.metafields.create!(key: 'season', value: 'fall-2026', kind: 'short_text', visibility: 'public')
product.metafield('season')   # => "fall-2026"
```

Public metafields surface on the Store API; private ones are admin-only. See `Spree::Metafields` concern and the `spree-resource` skill (`--metafields` flag) for built-in support.

## Where to read further

- **Core concepts:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/products.mdx` and `variants.mdx`.
- **Search providers:** the `Spree::SearchProvider::Base` source documents the interface. Custom providers subclass and override `reindex` and `search`.
- **Image processing:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/media.mdx`.
- **6.0 plans (if monorepo present):** `docs/plans/6.0-remove-master-variant.md`, `docs/plans/6.0-product-types.md`, `docs/plans/6.0-replace-taxons-with-categories.md`.
