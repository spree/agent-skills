---
name: spree-pricing
description: Use when the user is working with Spree pricing — variant prices, currency-specific pricing, sale/compare-at prices, price lists (5.3), price rules, EU Omnibus compliance (PriceHistory + prior_price), tax-inclusive pricing. Common phrasings include "set price", "compare at price", "sale price", "price list", "multi-currency pricing", "prior price", "Omnibus", "EU pricing law", "lowest price in 30 days", "tax inclusive", "VAT". Provides the price graph and the regulatory bits.
---

# Spree Pricing

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

Pricing in Spree is per-variant, per-currency. Optional layers add price lists (per-customer or per-market), historical tracking (for EU Omnibus compliance), and rule-based variations.

## The price graph

```
Variant
  ├── Price (one per currency)
  │     ├── amount             — what the customer pays (gross or net depending on tax config)
  │     ├── compare_at_amount  — was-price / strikethrough price (sale messaging)
  │     ├── currency
  │     └── price_list (5.3)   — nil for the default storefront price
  ├── PriceHistory × n         — historical amount changes (EU Omnibus)
  └── PriceRule × n            — conditional price overrides (5.3)
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

The canonical, idempotent setter is `variant.set_price('USD', 39.99, 49.99)` — it find-or-initializes the base Price for the currency (unlike `prices.create!`, which raises if a USD base price already exists, due to a unique DB index on variant + currency). Note the third argument is `compare_at_amount` and is assigned unconditionally — calling `set_price('USD', 39.99)` clears any existing compare-at price. Read it back with `variant.price_in('USD')`, which returns the base `Spree::Price` for that currency.

For most stores, prices are created via the admin UI (Products → variant edit) or bulk-imported via CSV. `Spree::Variant#price` is deprecated (removed in 6.0) — it returns the base-price amount in the default store's default currency, not a `Spree::Price` in the current currency. Use `variant.price_in('EUR')` (returns the base `Spree::Price` for a currency), `variant.amount_in('EUR')` (BigDecimal amount), or `variant.price_for(currency: 'EUR', user: user)` to get the price resolved through price lists (`Spree::Pricing::Resolver`).

```ruby
variant.price_in(Spree::Current.currency)   # => Spree::Price
variant.cost_price                          # => internal cost (not customer-facing)
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

Note `update_all` bypasses callbacks, so PriceHistory is NOT recorded (and the seed task won't backfill changes — it skips prices that already have history). If you have PriceHistory enabled, use the batched `update!` pattern shown under "Bulk price update" instead, which fires the history callback per record.

## PriceList (5.3)

A PriceList is a named pricing context — "Wholesale", "VIP", "B2B Tier 1". Each PriceList has its own Prices, separate from the default storefront prices.

```ruby
wholesale = Spree::PriceList.create!(
  store: current_store,
  name: 'Wholesale',
  match_policy: 'all',     # 'all' (all rules must match) or 'any'
  starts_at: nil,          # optional time window
  ends_at: nil
)
wholesale.activate          # status is a state machine (draft → active); activate/deactivate/schedule

variant.prices.create!(
  price_list: wholesale,
  currency: 'USD',
  amount: 25.00
)
```

A PriceList is gated by **PriceRule** records attached to it. A customer "qualifies" for a PriceList only when its rules match the pricing context — zone, market, customer group, user, or volume. The cart pipeline picks the highest-priority matching PriceList's price; falls back to the default (`price_list: nil`) otherwise.

This is the foundation for B2B pricing tiers, member discounts, and per-market pricing. Pre-5.3 stores used promotions for this — PriceList is cleaner because the price *is* the displayed price (no "20% off at checkout" surprise).

## PriceRule (5.3)

A PriceRule is a condition gating a PriceList. PriceRule is STI; subclasses live in `Spree::PriceRules::*`:

| Subclass | Matches when… |
|---|---|
| `Spree::PriceRules::ChannelRule` | The order's channel is in a specified set of channels |
| `Spree::PriceRules::CustomerGroupRule` | The customer is in a specified CustomerGroup |
| `Spree::PriceRules::MarketRule` | The order's market is in a specified set of markets (5.4) |
| `Spree::PriceRules::UserRule` | A specific User is logged in |
| `Spree::PriceRules::VolumeRule` | The line item quantity hits a threshold |

(`Spree::PriceRules::ZoneRule` still exists so legacy rows load, but it's deliberately excluded from the admin "Add rule" picker — zones are slated for removal in 6.0. Don't use it in new code.)

Each subclass implements `applicable?(context)` where `context` is a `Spree::Pricing::Context` (store, currency, zone, market, user, quantity, date, etc.).

```ruby
wholesale = Spree::PriceList.find_by(name: 'Wholesale')

wholesale.price_rules << Spree::PriceRules::CustomerGroupRule.new(
  preferred_customer_group_ids: [b2b_group.id]
)
```

Rules combine via the parent PriceList's `match_policy` (`all` = AND, `any` = OR).

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

Every base-price amount change creates a PriceHistory entry (price-list prices and compare_at-only changes are not tracked; recording requires `Spree::Config[:track_price_history]`). The `Spree::Price#prior_price` method returns the `Spree::PriceHistory` record with the **lowest amount recorded in the last 30 days** (or `nil` if there's no history in that window):

```ruby
price.amount                # => 25.00 (current sale price)
price.prior_price           # => #<Spree::PriceHistory amount: 25.00, ...> or nil
price.prior_price&.amount   # => lowest amount recorded in the window
```

Note: the price-change callback records the new amount itself, so the just-set sale price is included in the 30-day window and can be the "lowest" returned.

The Store API exposes `prior_price` as an expandable field on product and variant endpoints (`?expand=prior_price`), serialized as a PriceHistory object (`amount`, `amount_in_cents`, `currency`, `display_amount`, `recorded_at`). EU storefronts display it alongside the current sale price.

### Configuration

```ruby
# config/initializers/spree.rb
Spree::Config[:track_price_history] = true        # default true; disable for non-EU stores
Spree::Config[:price_history_retention_days] = 60 # default 30; controls the prune task
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

The cart pipeline displays prices according to `Spree::Current.market`'s setting. Prices are entered as-is in the admin — no price form asks gross vs net. The interpretation comes from the tax configuration: `TaxRate.included_in_price` drives the tax math, and the per-market `tax_inclusive` flag (Settings → Markets) records the market-level default.

**EU stores: always gross-stored.** This is what Omnibus requires for transparency. **US stores: always net-stored.** Sales tax is added at the cart level.

Mixing the two (US store selling to EU customers) requires careful Market configuration.

## Common pricing problems

### "Customer sees the wrong price"

Walk this list:

1. **Currency mismatch?** `Spree::Current.currency` should be the customer's. Check the Channel / Market config.
2. **PriceList?** If a PriceList's rules match the pricing context, that PriceList's price wins. Walk the candidate lists for the request context: `Spree::Current.price_lists` returns the memoized `Spree::PriceList.for_context(Spree::Current.global_pricing_context)` (status active/scheduled, within date range, by position). To check rule matching for a specific customer, build a context and test each list: `ctx = Spree::Pricing::Context.new(currency: 'USD', store: current_store, user: user); Spree::PriceList.for_context(ctx).select { |pl| pl.applicable?(ctx) }`. Or just inspect the resolved price directly: `variant.price_for(currency: 'USD', user: user)`.
3. **Tax mode?** The amount stored is gross or net depending on the Market — make sure the display logic matches the store setting.
4. **Cache stale?** Catalog endpoints heavily cache. After price changes, touch the product (`product.touch`) to invalidate.

### "PriceHistory not populating"

Confirm `Spree::Config[:track_price_history]` is `true` (default). Verify entries via `Spree::Price.first.price_histories.count`.

### "Bulk price update — what's the right pattern?"

For broad updates:
```ruby
Spree::Price.where(currency: 'USD', price_list_id: nil).find_in_batches(batch_size: 500) do |batch|
  Spree::Price.transaction do
    batch.each { |p| p.update!(amount: p.amount * 1.1) }
  end
end
```

`find_in_batches` keeps memory bounded; the transaction ensures atomicity per batch. After: no PriceHistory action needed — each `update!` fires the price-history callback automatically (when `Spree::Config[:track_price_history]` is enabled, the default). Reindex search if prices affect ranking.

### "Display price doesn't match cart total"

The display price uses the variant's Price for `Spree::Current.currency`. The cart total includes adjustments (promotions, taxes, shipping). They should agree on item subtotal unless a Promotion or PriceRule is changing the line-item amount.

`order.line_items.first.price` is the *frozen* price at the time the item was added. If the storefront PDP shows a different (newer) price, it's because the Variant's Price changed after the customer added to cart. This is intentional — cart contents don't auto-update.

## Where to read further

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/pricing.md`
- **Taxes:** `node_modules/@spree/docs/dist/developer/core-concepts/taxes.md`
- **Source:** `Spree::Price`, `Spree::PriceHistory`, `Spree::PriceList`, `Spree::PriceRule` in the installed `spree_core` gem.
