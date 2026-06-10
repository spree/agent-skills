---
name: spree-data-model
description: Use when the user is asking how Spree's domain models relate — Orders, LineItems, Variants, Products, Stores, Channels, Markets, Payments, Shipments, Customers, Adjustments. Architecture and relationships only. Common phrasings include "how does X connect to Y", "what's the relationship between", "where does Spree store X", "how do I query orders across stores", "how do channels work", "what's the difference between Cart and Order", "Store vs Channel vs Market". For adding new models / new API resources, use the `spree-resource` skill. For field-level detail, see `docs/developer/core-concepts/` in the installed `@spree/docs` package.
---

# Spree Data Model

A relationship map for the most-asked-about Spree models. Field-level documentation lives in the installed `@spree/docs` package at `node_modules/@spree/docs/dist/developer/core-concepts/`.

## The catalog → cart pipeline

```
Product → Variant → LineItem → Order
```

- **Product** is the brand-level entity (name, slug, description, category).
- **Variant** is the sellable SKU. Every Product has at least one Variant. Variants carry SKU, prices, dimensions, and link to inventory.
- **LineItem** links a Variant to an Order with `quantity` and price frozen at add-time.
- **Order** is the customer's transaction — the cart-in-progress and, after checkout, the completed transaction (same record, different `state`).

Variants relate to stock via `StockItem` (one per Variant per StockLocation) and the `StockMovement` history.

### Master vs default variant

A Product has a `master` variant (legacy concept, `is_master: true`) and a computed `default_variant` method: when `Spree::Config[:track_inventory_levels]` is on, the first purchasable variant; otherwise the first non-master variant by `position`; master is only the fallback when the product has no other variants. `product.default_variant_id` just returns that computed variant's id. Neither is a database column in 5.5 — don't query or migrate against `default_variant_id` (a `default_variant_id` FK on `spree_products` is planned for 6.0, implementation not started; see `docs/plans/6.0-remove-master-variant.md`). Use `product.variants` for the non-master sellable variants and `product.variants_including_master` only when you genuinely need the master row included.

## The multi-channel / multi-store axis

```
Store → Channel → ProductPublication → Product
```

Available since Spree 5.5.

- **Store** is the top-level brand (one organization = one Store, typically).
- **Channel** is a selling surface within a Store: the online storefront, in-person POS, marketplace integrations (Amazon, eBay), B2B wholesale, mobile apps. Every Store has at least a default Channel named "Online Store".
- **ProductPublication** is the join: which Products are visible on which Channel, with optional `published_at` / `unpublished_at` windows for scheduling.
- **Order** has `channel_id` so revenue can be attributed per channel.

The Store API resolves a channel per request from the `X-Spree-Channel` header (matched against `channels.code` or a `ch_…` prefixed ID); without it the store's default channel is used. The Admin API does not consume `X-Spree-Channel` — admin queries return data across all channels for the current store.

## Markets (regional config)

```
Market has_many :countries
Market  columns:  currency (string), default_locale (string)
Order belongs_to :market
```

A Market is a regional configuration: its set of countries, currency, and default locale. Stores typically get a default Market created automatically (when a default country is known at creation), but markets are optional — check `store.has_markets?`; currency and locale fall back to store-level defaults when no market exists. Orders are placed in a Market — that's what controls the currency the customer sees and what tax rules apply.

For full Market documentation see `node_modules/@spree/docs/dist/developer/core-concepts/markets.md`.

## Cart vs Order

In Spree, `Spree::Order` is both the in-progress cart and the completed transaction. The `state` column tracks which phase: `cart`, `address`, `delivery`, `payment`, `confirm`, `complete`. Filter on state to distinguish:

```ruby
Spree::Order.where(state: 'cart')      # in-progress carts
Spree::Order.where(state: 'complete')  # finalized orders
Spree::Order.complete                  # named scope — NOT equivalent: defined as where.not(completed_at: nil), so it matches any order that ever completed checkout, including ones later canceled or returned
```

`Order#token` (`has_secure_token :token, length: 35`) identifies an anonymous cart across requests. Logged-in carts are owned via the `user_id` FK.

## Checkout-side models

```
Order → Payment → PaymentMethod
Order → Shipment → ShippingRate → ShippingMethod
Order → Address (bill_address, ship_address)
```

- **Payment** has its own state machine (`checkout → processing → pending → completed`, plus `failed`, `void`, and `invalid`). Column is `state`.
- **Shipment** has its own state machine (`pending → ready → shipped` with `canceled`). Column is `state`.
- **ShippingRate** is a per-Shipment offer (e.g. UPS Ground $5.99, USPS Priority $8.99). The customer picks one.

## Customer / User

```
Spree.user_class (typically Spree::User)
  ↓
Address (many, via spree_addresses)
CreditCard (many)
GiftCard (many)
StoreCredit (many)
```

Use `Spree.user_class` and `Spree.admin_user_class` to reference user models — never `Spree::User` directly. Apps can swap in their own user model via configuration.

## Adjustments (polymorphic)

```
Adjustable (Order, LineItem, Shipment) ← Adjustment
```

`Adjustment` is polymorphic — it attaches to any Order, LineItem, or Shipment via `adjustable_type` + `adjustable_id`. Each Adjustment has a `source` (the thing that created it: a TaxRate, PromotionAction, ReturnAuthorization, etc.) and built-in scopes to filter by source type:

```ruby
order.adjustments.tax                     # source_type: 'Spree::TaxRate'
order.adjustments.promotion               # source_type: 'Spree::PromotionAction'
order.adjustments.return_authorization
order.all_adjustments                     # adjustments on order + its line_items + shipments
```

## Prefixed IDs

Every Spree model exposed via the v3 API has a Stripe-style prefixed ID:

```ruby
product.prefixed_id  # => "prod_86Rf07xd4z"
order.prefixed_id    # => "or_m3Rp9wXz"
variant.prefixed_id  # => "variant_k5nR8xLq"
```

IDs are computed from the integer PK via Sqids — no database column. The prefix is declared per-class via `has_prefix_id :<prefix>` on the model. The v3 API accepts and emits prefixed IDs everywhere; `find_by_prefix_id!` resolves them back to integer PKs.

Conventions for the prefix:

- Long form for some resources: `prod` (Product), `variant` (Variant)
- Short codes for most others: `or` (Order), `py` (Payment, Stripe parity), `adj` (Adjustment), `li` (LineItem), `ctg` (Category/Taxon), `cus` (customer, Stripe parity), `ch` (Channel), `mkt` (Market)

Never expose raw integer PKs in API responses.

## `state` vs `status` (mixed on 5.5)

Different models use different column names depending on when they were introduced:

- `Order.state`, `Payment.state`, `Shipment.state` — older state machines
- `OrderApproval.status` — newer status column
- `Channel` doesn't use a state machine — it has an `active` boolean instead

When writing model code, follow the convention of the column the model actually has. When querying, check the model's source if you're not sure.

## `Spree::Current` (per-request context)

Avoid passing store / currency / locale around as arguments. Use the ambient context:

```ruby
Spree::Current.store      # The store handling this request
Spree::Current.currency   # The currency to display prices in
Spree::Current.locale     # The locale for translations
Spree::Current.channel    # The resolved sales channel (falls back to the store's default channel)
Spree::Current.market     # The resolved market (falls back to the store's default market)
```

Available in models, controllers, jobs, and services. Set automatically by controller before_actions on the API (with built-in fallbacks to store defaults inside `Spree::Current`); you set it manually in jobs and rake tasks that need to address a specific store.

## When to read further

- **Field-level docs:** `node_modules/@spree/docs/dist/developer/core-concepts/<topic>.md` for each model.
- **OpenAPI spec:** `node_modules/@spree/docs/dist/api-reference/store.yaml` lists every API field and its type — better than guessing from the model source.
- **Adding new models / API resources:** use the `spree-resource` skill.
- **Extending existing Spree models** (add an association, validation, scope, method via decorator): use the `spree-decorators` skill.
