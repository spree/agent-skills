---
name: spree-data-model
description: Use when the user is working with Spree's domain models — Orders, LineItems, Variants, Products, Stores, Channels, Markets, Payments, Shipments, Customers — or asking how these relate. Common phrasings include "how does X connect to Y", "what's the relationship between", "where does Spree store X", "how do I query orders across stores", "how do channels work", "what's the difference between Cart and Order". Provides the relationship map and key conventions; defers to local @spree/docs for field-level detail.
---

# Spree Data Model

A reference map for the most-asked-about relationships. For field-level detail, read `backend/node_modules/@spree/docs/dist/developer/core-concepts/`.

## The catalog → cart pipeline

```
Product → Variant → LineItem → Order
```

- **Product** owns brand-level info (name, slug, description, category).
- **Variant** is the SKU — every Product has at least one Variant (the "master" variant; being eliminated in 6.0, see "Coming in 6.0" below). Variants carry SKU, price, dimensions, inventory.
- **LineItem** links a Variant to an Order with quantity + frozen-at-add-time pricing.
- **Order** is the customer's transaction (cart-in-progress OR completed purchase — see "Cart vs Order" below).

Variants relate to inventory via `StockItem` (per Variant + per StockLocation) and `StockMovement` for the movement history.

## The multi-channel / multi-store axis (5.5+)

```
Store → Channel → ProductPublication → Product
```

This is new in 5.5. Before 5.5, products belonged directly to stores via `spree_products_stores`. Now:

- **Store** is a top-level brand entity (one organization = one Store, usually).
- **Channel** is a sales surface within a Store (website, POS, marketplace, B2B). Every Store has at least a default Channel.
- **ProductPublication** is the join: which Products are visible on which Channel, with `published_at` / `unpublished_at` windows.
- **Order** has `channel_id` (which channel it came from) so you can attribute revenue per channel.

If the user is on Spree < 5.5, the model is flatter: `Product` has `has_many :stores`. The 5.5 upgrade (`spree:channels:upgrade` rake task) migrates the data.

## Markets (regional config)

```
Market → Country (many), Market has currency + default_locale
Order → Market
```

A Market is a regional configuration — its set of countries, currency, default locale. Each Store has a default Market. Orders are placed in a Market (controls the currency the customer sees).

Markets replaced the older `Zone` model in 5.4. Zones may still appear in older codebases (`migrate_checkout_zones` rake task migrates them).

## Cart vs Order

**Currently (5.x):** Same model. `Spree::Order` is the cart while `state == 'cart'`, becomes a completed Order after `state == 'complete'`. Filter on state to distinguish.

**Coming in 6.0:** Cart and Order will be separate models. `Spree::Cart` owns the in-progress shopping experience; `Spree::Order` is the finalized transaction. `LineItem` becomes polymorphic so it can belong to either. See `docs/plans/6.0-cart-order-split.md` in the Spree monorepo for the plan if you have the docs installed locally.

Don't write code that assumes the split has happened — query both via `state` for now.

## Checkout-side models

```
Order → Payment → PaymentMethod
Order → Shipment → ShippingRate → ShippingMethod
Order → Address (billing + shipping)
```

- **Payment** has its own state machine (`checkout → processing → completed / failed / void`). The state is currently `state` column, becoming `status` in 6.0 (see "Coming in 6.0" below).
- **Shipment** likewise has its own state machine. Being renamed to `Fulfillment` in 6.0.
- **ShippingRate** is a per-Shipment offer (e.g. UPS Ground $5.99, USPS Priority $8.99). Customer picks one.

## Customer / User

```
Customer (or User, depending on Spree version)
  ↓
Address (many, via spree_addresses)
CreditCard (many)
GiftCard (many)
StoreCredit (many)
```

- `Spree.user_class` — never reference `Spree::User` directly. Configurable per app.
- In 6.0, `User` becomes `Customer` (with `Staff` for admin). 5.x apps still use `User` for both.

## Adjustments (the polymorphic problem)

```
Adjustable (Order, LineItem, Shipment) ← Adjustment
```

Currently, `Adjustment` is polymorphic — it sticks to any Order, LineItem, or Shipment with `adjustable_type` + `adjustable_id` + a `source` (the thing that created it: a TaxRate, Promotion, etc.).

This works but makes adjustment queries painful and obscures tax vs discount vs fee. **In 6.0, this splits into `TaxLine`, `Discount`, `Fee`** — concrete models with concrete FKs. If you're writing query code against Adjustment today, expect it to need rework at 6.0.

## Prefixed IDs

Every Spree model that's exposed via the v3 API has a Stripe-style prefixed ID:

```ruby
product.prefixed_id  # => "prod_86Rf07xd4z"
order.prefixed_id    # => "or_m3Rp9wXz"
variant.prefixed_id  # => "variant_k5nR8xLq"
```

IDs are computed on-the-fly via Sqids from the integer PK — no database column. The prefix is declared per-class via `has_prefix_id :<prefix>` (auto-applied by the v3 `Spree::PrefixedId` concern). Conventions:

- Long form for most: `prod`, `variant`, `brand`, `category`, `customer`
- Short form when the model is high-traffic: `or` (Order), `py` (Payment, Stripe parity), `ad` (Adjustment), `li` (LineItem)
- Domain-specific abbreviations: `cf` (CustomField, renamed from Metafield)

The v3 API accepts and emits prefixed IDs everywhere. Never expose raw integer PKs in API responses. `find_by_prefix_id!` resolves them on the inbound side.

## `state` vs `status` (the rename in progress)

Some models use `state` (legacy), some use `status` (the 6.0 convention). 5.x has both depending on when the model was introduced:

- `Order.state` (renaming to `status` in 6.0)
- `Payment.state` (renaming to `status` in 6.0)
- `Channel.status` (always status — new)
- `OrderApproval.state` (legacy)

If you're building new state machines on Spree models, use `status` not `state`. If you're querying existing 5.x state, check the model's column.

## `Spree::Current` (per-request context)

Don't pass store / currency / locale around as arguments. Use the ambient context:

```ruby
Spree::Current.store      # The store handling this request
Spree::Current.currency   # The currency to display prices in
Spree::Current.locale     # The locale for translations
```

Available in models, controllers, jobs, services. Set automatically by request middleware on the API; you set it manually in jobs / rake tasks.

## Coming in 6.0 (key shifts to be aware of)

- **Cart / Order split** — separate models, polymorphic LineItem.
- **Shipment → Fulfillment, ShippingMethod → DeliveryMethod** — terminology and model rename. ShippingCategory drops.
- **Adjustment split** — TaxLine, Discount, Fee replace polymorphic Adjustment.
- **User → Customer + Staff** — own auth stack, Devise drops.
- **Returns/Exchanges/Claims** — first-class models replacing ReturnAuthorization + Reimbursement chain.
- **state → status** — the rename completes on Payment, Shipment, InventoryUnit, ReturnAuthorization, GiftCard.
- **`is_master` drops** — Product gets `default_variant_id` FK.
- **TaxProvider per Market** — replaces TaxRate.adjust + Calculator.

Don't write code that assumes any of these have shipped if you're on 5.x. When a question mentions a 6.0 plan, point at `docs/plans/<version>-<topic>.md` if the user has the monorepo, otherwise the upgrade docs.

## When to read further

- **Field-level docs:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/<model>.mdx`
- **OpenAPI spec:** `backend/node_modules/@spree/docs/dist/api-reference/store.yaml` lists every API field and its type — better than guessing from the model class.
- **Active plans (if monorepo present):** `docs/plans/6.0-*.md` covers each architectural shift in detail.
