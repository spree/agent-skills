---
name: spree-pricing
description: Use when the user is working with Spree pricing — variant prices, currency-specific pricing, sale/compare-at prices, price lists (5.5), price rules, EU Omnibus compliance (PriceHistory + prior_price), tax-inclusive pricing. Common phrasings include "set price", "compare at price", "sale price", "price list", "multi-currency pricing", "prior price", "Omnibus", "EU pricing law", "lowest price in 30 days", "tax inclusive", "VAT". Provides the price graph and the regulatory bits.
---

# Spree Pricing

Pricing in Spree is per-variant, per-currency. Optional layers add price lists (per-customer or per-market), historical tracking (for EU Omnibus compliance), and rule-based variations.

## The price graph

```
Variant
  ├── Price (one per currency)
  │     ├── amount             — what the customer pays (gross or net depending on tax config)
  │     ├── compare_at_amount  — was-price / strikethrough price (sale messaging)
  │     ├── currency
  │     └── price_list (5.5)   — nil for the default storefront price
  ├── PriceHistory × n         — historical amount changes (EU Omnibus)
  └── PriceRule × n            — conditional price overrides (5.5)
```

Each Variant has at least one Price per currency the store sells in. The cart pipeline picks the right Price based on `Spree::Current.currency` and the customer's `PriceList` (if any).

## Setting a price

```ruby
variant.prices.create!(
  currency: 'USD',
  amount: 39.99,
  compare_at_amount: 49.99   # strikethrough — shows as "was $49.99 now $39.99"
)
```

For most stores, prices are created via the admin UI (Products → variant edit) or bulk-imported via CSV. The `Spree::Variant#price` accessor returns the Price in the current currency.

```ruby
Spree::Current.currency       # => 'EUR'
variant.price                 # => Price with currency: 'EUR'
variant.display_price         # => "€39.99" (Money formatting)
variant.cost_price            # => internal cost (not customer-facing)
```

## Multi-currency pricing

Each Variant needs a Price per currency the store sells in. There's no automatic conversion — you set EUR, GBP, USD explicitly. (The store's `default_currency` determines what the admin defaults to.)

```ruby
variant.prices.create!(currency: 'USD', amount: 39.99)
variant.prices.create!(currency: 'EUR', amount: 35.00)
variant.prices.create!(currency: 'GBP', amount: 31.00)
```

For bulk currency updates (e.g. "raise all USD prices 10%"):

```ruby
Spree::Price.where(currency: 'USD', price_list_id: nil).update_all('amount = amount * 1.1')
```

If you have PriceHistory enabled, run `spree rake spree:price_history:seed` afterwards so the change is recorded for Omnibus compliance.

## PriceList (5.5)

A PriceList is a named pricing context — "Wholesale", "VIP", "B2B Tier 1". Each PriceList has its own Prices, separate from the default storefront prices.

```ruby
wholesale = Spree::PriceList.create!(name: 'Wholesale', code: 'wholesale')

variant.prices.create!(
  price_list: wholesale,
  currency: 'USD',
  amount: 25.00   # lower than the default storefront price
)
```

Customers are assigned to a PriceList via their CustomerGroup or directly. The cart pipeline picks the assigned PriceList's price if one exists, falling back to the default (`price_list: nil`) otherwise.

This is the foundation for B2B pricing tiers, member discounts, and per-market pricing. Pre-5.5 stores used promotions for this — PriceList is cleaner because the price *is* the displayed price (no "20% off at checkout" surprise).

## PriceRule (5.5)

A PriceRule is a conditional override — "20% off all Variants in this Category for customers in the EU".

```ruby
rule = Spree::PriceRule.create!(
  name: 'EU Summer Sale',
  conditions: { country_in: ['DE', 'FR', 'IT'], category_in: ['t-shirts'] },
  adjustment_type: 'percent',
  adjustment_value: -20,
  starts_at: 2.weeks.from_now,
  expires_at: 6.weeks.from_now
)
```

PriceRules apply during the price-lookup phase of the cart pipeline. They differ from Promotions in that they modify the *displayed price* (the customer sees the discounted price on the PDP), whereas Promotions apply at checkout (the customer sees "discount $X" at the cart total).

Use PriceRule for market-segment pricing; use Promotion for time-limited campaigns and coupon codes. See the `spree-promotions` skill.

## EU Omnibus compliance (PriceHistory + prior_price)

The EU Omnibus Directive (in force since 2022) requires retailers to display the **lowest price in the last 30 days** alongside any "was-price" / sale messaging. Spree 5.4 added `PriceHistory` and the `prior_price` serializer field to support this.

### How it works

```
Spree::Price.update(amount: 30.00)
  ↓ (model callback)
Spree::PriceHistory.create(
  price: self_price,
  amount: 30.00,
  recorded_at: Time.current
)
```

Every Price change creates a PriceHistory entry. The `Spree::Price#prior_price(window:)` method returns the **lowest amount in the configured window** (default: 30 days):

```ruby
price.amount             # => 25.00 (current sale price)
price.prior_price        # => 30.00 (lowest in last 30 days — used as the strikethrough)
```

The Store API exposes `prior_price` on the Price serializer. EU storefronts display it as the "regular price" alongside the current sale price.

### Configuration

```ruby
# backend/config/initializers/spree.rb
Spree::Config[:price_history_retention_days] = 60   # default 30
Spree::Config[:price_history_enabled] = true        # required for compliance
```

### Seeding history for existing stores

If you turned on PriceHistory on an existing store, run the seed task to backfill an initial PriceHistory entry per Price:

```bash
spree rake spree:price_history:seed
```

The task is idempotent — it skips Prices that already have a PriceHistory entry.

### Pruning old entries

PriceHistory grows unboundedly. The prune task drops entries older than the configured retention:

```bash
spree rake spree:price_history:prune
```

Schedule this in your background job runner (Sidekiq cron, Heroku scheduler, etc.) to run nightly.

## Tax-inclusive vs tax-exclusive pricing

Spree supports both modes per Zone / Country:

| Mode | What's stored in Price.amount | Customer sees |
|---|---|---|
| Tax-exclusive (US default) | Net (pre-tax) | Net + "Tax at checkout" |
| Tax-inclusive (EU default) | Gross (post-tax) | Gross with "incl. VAT" |

Configured via `Spree::TaxRate.included_in_price` per rate. The Markets system (5.4+) sets a default per market.

The cart pipeline displays prices according to `Spree::Current.market`'s setting. Editing prices in the admin asks the merchant whether the entered number is gross or net.

**EU stores: always gross-stored.** This is what Omnibus requires for transparency. **US stores: always net-stored.** Sales tax is added at the cart level.

Mixing the two (US store selling to EU customers) requires careful Market configuration. The 6.0 TaxProvider plan reworks this — see `docs/plans/6.0-tax-provider.md` if you're on the monorepo.

## Common pricing problems

### "Customer sees the wrong price"

Walk this list:

1. **Currency mismatch?** `Spree::Current.currency` should be the customer's. Check the Channel / Market config.
2. **PriceList?** If the customer is on a PriceList (CustomerGroup-driven or direct), the assigned PriceList's price wins. `customer.assigned_price_list` should reflect this.
3. **PriceRule applied?** PriceRules show in the customer's price; check `Spree::PriceRule.applicable(variant, customer).any?`.
4. **Tax mode?** The amount stored is gross or net depending on the Market — make sure the display logic matches the store setting.
5. **Cache stale?** Catalog endpoints heavily cache. After price changes, invalidate the cache (Spree.cache_key_with_version on Product/Variant handles this for most cases).

### "PriceHistory not populating"

Confirm `Spree::Config[:price_history_enabled]` is `true`. Confirm the model callback is registered — it ships in the gem so this should always be true on 5.4+ unless explicitly disabled. Verify with `Spree::Price.first.histories.count`.

### "Bulk price update — what's the right pattern?"

For broad updates:
```ruby
Spree::Price.where(currency: 'USD', price_list_id: nil).find_in_batches(batch_size: 500) do |batch|
  Spree::Price.transaction do
    batch.each { |p| p.update!(amount: p.amount * 1.1) }
  end
end
```

`find_in_batches` keeps memory bounded; the transaction ensures atomicity per batch. After: run `spree:price_history:seed` if you have PriceHistory enabled, and reindex search if prices affect ranking.

### "Display price doesn't match cart total"

The display price uses the variant's Price for `Spree::Current.currency`. The cart total includes adjustments (promotions, taxes, shipping). They should agree on item subtotal unless a Promotion or PriceRule is changing the line-item amount.

`order.line_items.first.price` is the *frozen* price at the time the item was added. If the storefront PDP shows a different (newer) price, it's because the Variant's Price changed after the customer added to cart. This is intentional — cart contents don't auto-update.

## Where to read further

- **Source:** `bundle show spree_core`/app/models/spree/price.rb and price_history.rb.
- **PriceList + PriceRule (5.5):** `Spree::PriceList`, `Spree::PriceRule` source.
- **Omnibus implementation plan:** `docs/plans/5.4-6.0-eu-legal-compliance.md` if you have the monorepo.
- **Docs:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/pricing.mdx`.
