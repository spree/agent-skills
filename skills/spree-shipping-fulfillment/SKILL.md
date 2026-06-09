---
name: spree-shipping-fulfillment
description: Use when the user is working with Spree's shipping and fulfillment system — shipments, shipping methods, shipping rates, stock locations, the shipment state machine, pickup vs ship, the 6.0 Shipment→Fulfillment rename. Common phrasings include "shipping method", "calculate shipping rate", "stock location", "shipment stuck in pending", "order fulfillment", "pickup in store", "ship from", "shipping zone", "Fulfillment", "DeliveryMethod", "ShippingCategory". Provides the shipping graph, the state machine, and the customization hooks.
---

# Spree Shipping + Fulfillment

The shipping system answers two questions: *where is this order going* (the delivery method) and *where is it shipping from* (the stock location). Together they produce one or more Shipments — each Shipment represents a package leaving a specific StockLocation via a specific ShippingMethod.

## The shipping graph

```
Order
  └── Shipment (one per fulfillment package — may be many per order)
        ├── StockLocation        — where it ships from
        ├── ShippingRate × n     — offered rates from configured methods
        │    └── ShippingMethod  — UPS Ground, USPS Priority, etc.
        └── InventoryUnit × n    — one per LineItem unit in the shipment

ShippingMethod
  ├── ShippingCategory × n       — which categories of items this method handles
  ├── Calculator                 — how much (per-order, per-item, weight-based)
  └── Zone × n                   — where this method applies (will be Markets in 6.0)

Variant
  └── ShippingCategory           — heavy items, fragile items, digital, etc.
```

Each line item's variant has a ShippingCategory. A ShippingMethod's eligibility depends on whether the variant's category is in the method's allowed categories AND the destination is in the method's Zone.

## Shipment state machine

```
pending → ready → shipped
   ↓                ↑
canceled ←──────────┘ (via :resume)
```

| State | What it means |
|---|---|
| `pending` | Created but not yet ready to ship (waiting on payment, allocation, etc.) |
| `ready` | Inventory allocated, ready for the warehouse to pick |
| `shipped` | Picked up by carrier; tracking number set |
| `canceled` | Order was canceled; the shipment doesn't go out |

Transitions are events: `ready`, `pend` (back to pending), `ship`, `cancel`, `resume`. The `ship` event fires `shipment.shipped` (subscribers) and updates `order.shipment_state` to `shipped`/`partial` based on the order's other shipments.

### `state` → `status` rename (6.0)

In 6.0, Shipment.state becomes Shipment.status (along with Payment, InventoryUnit, ReturnAuthorization, GiftCard). On 5.x, use `shipment.state`. On 6.0, use `shipment.status`. Same values, different column name.

## How shipping rates get calculated

When an order enters the `delivery` checkout state (after address):

```
Spree::Stock::Estimator.new(order).shipping_rates
  ↓
For each Shipment in order:
  ↓
For each ShippingMethod where:
  - method.shipping_categories.include?(variant.shipping_category)
  - method.zones.include?(zone_for(order.ship_address))
  ↓
Run method.calculator.compute(package)
  ↓
ShippingRate(shipping_method: method, cost: amount, selected: best)
```

The cheapest rate per Shipment is `selected: true` by default. Customer can pick a different one in the checkout UI.

## Built-in calculators

| Calculator | Computes |
|---|---|
| `Spree::Calculator::Shipping::FlatRate` | Same rate regardless of weight/items |
| `Spree::Calculator::Shipping::FlatPercentItemTotal` | % of order item total |
| `Spree::Calculator::Shipping::PerItem` | Rate × number of items |
| `Spree::Calculator::Shipping::FlexiRate` | Tiered by item count (1 item = $5, 2-5 = $10, 6+ = $15) |
| `Spree::Calculator::Shipping::PriceSack` | Tiered by order total (under $50 = $10 shipping, over $50 = free) |
| `Spree::Calculator::Shipping::DigitalDelivery` | Zero — for digital products |

Custom calculators subclass `Spree::Calculator` and implement `compute(package)`. The package is a `Spree::Stock::Package` with line items, total weight, total cost. See `spree-promotions` skill for the calculator pattern in detail.

## StockLocation

Stock is tracked per-Variant per-StockLocation via StockItem. A store has at least one StockLocation; multi-warehouse stores have many.

```ruby
warehouse = Spree::StockLocation.create!(
  name: 'East Coast Warehouse',
  address1: '...',
  city: '...',
  state_id: Spree::State.find_by(name: 'New York').id,
  country_id: Spree::Country.find_by(iso: 'US').id,
  propagate_all_variants: true,  # auto-create StockItem for every Variant
  active: true,
  backorderable_default: false,
  default: false                  # only one StockLocation can be the default
)

variant.stock_items.where(stock_location: warehouse).first.count_on_hand   # current stock at this location
variant.total_on_hand                                                       # summed across all locations
```

### StockMovement

Stock changes are recorded as `Spree::StockMovement` entries — an audit log:

```ruby
warehouse.stock_movements.create!(
  stock_item: stock_item,
  quantity: 10,                           # positive = received, negative = sold/lost
  originator: purchase_order              # polymorphic — what caused the movement
)
```

Don't update `count_on_hand` directly; create a StockMovement and let the model recompute. The 6.0 plan introduces typed StockMovement subclasses (Received, Sold, Adjusted, Lost) — see `docs/plans/6.0-typed-stock-movements.md`.

## How Shipments split across StockLocations

When an order is split into shipments, Spree groups InventoryUnits by where they can ship from:

```
Order has 3 items: [A from East, B from East, C from West]
  ↓
Stock::Splitter inspects available stock per item per location
  ↓
Creates 2 Shipments:
  - Shipment 1: items A + B from East Warehouse
  - Shipment 2: item C from West Warehouse
```

Each Shipment gets its own ShippingRate calculation (different origin = different rates). The customer pays each shipment's selected rate.

### Pickup (6.0)

The 6.0 plan introduces first-class pickup as a delivery option: a StockLocation can be marked `pickup_enabled`, exposing it as an in-store pickup option at checkout. Customer reserves stock at that location; shipment never ships.

There's also `pickup_point` — third-party pickup networks (parcel lockers, post offices) via a PickupPointProvider strategy. See `docs/plans/6.0-fulfillment-and-delivery.md`.

## The 6.0 rename: Shipment → Fulfillment, ShippingMethod → DeliveryMethod

The 6.0 model rename is largely cosmetic but reflects how the modern concept differs from "shipping":

- **Shipment → Fulfillment** — a fulfillment can be a physical shipment, a pickup, a digital delivery, an in-store dispatch. "Shipping" is one mode.
- **ShippingMethod → DeliveryMethod** — same shift.
- **ShippingCategory drops entirely** — replaced by per-variant fulfillment configuration.
- **FulfillmentProvider strategy** — pluggable: ShipStation, EasyPost, custom warehouse integrations all implement the same interface.

On 5.x: use Shipment, ShippingMethod, ShippingCategory. **Don't pre-write 6.0 code.** See the upgrade docs when the migration arrives.

## Returns + Reverse Logistics

Customer wants to return an item: an Order has `ReturnAuthorization` → `CustomerReturn` → `Reimbursement` → `Refund` or `StoreCredit`.

```
ReturnAuthorization (admin-created, lists which InventoryUnits)
  ↓
Customer ships item back
  ↓
CustomerReturn (admin-received, links InventoryUnits to receipt)
  ↓
Reimbursement (calculates refund amount minus restocking fees)
  ↓
Refund (to original payment) OR StoreCredit
```

This chain is awkward and changing in 6.0 — see `docs/plans/6.0-returns-exchanges-claims.md` for the planned first-class Return/Exchange/Claim models.

## Customizing shipping

### Custom calculator

```ruby
# backend/app/models/spree/calculator/shipping/weight_based.rb
module Spree
  class Calculator::Shipping::WeightBased < Spree::Calculator
    preference :rate_per_kg, :decimal, default: 5.00

    def compute(package)
      total_weight = package.contents.sum { |c| c.variant.weight * c.quantity }
      total_weight * preferred_rate_per_kg
    end
  end
end

# Register so it shows in admin shipping method UI
Rails.application.config.after_initialize do
  Spree::ShippingMethod.calculators << Spree::Calculator::Shipping::WeightBased
end
```

### Hooking into shipment events

For external warehouse integration, subscribe to `shipment.shipped`:

```ruby
class ShipmentShippedSubscriber < Spree::Subscriber
  subscribes_to 'shipment.shipped', async: true

  def handle(event)
    shipment = Spree::Shipment.find_by_prefix_id(event.payload['id'])
    ExternalWarehouseAPI.notify_dispatched(
      tracking: shipment.tracking,
      carrier: shipment.shipping_method.carrier,
      order_number: shipment.order.number
    )
  end
end
```

See the `spree-events-webhooks` skill for the events system.

### Custom shipping rate ranking

By default, the cheapest rate is selected. To prefer carrier reliability, override `Spree::Stock::Estimator#sort_shipping_rates`:

```ruby
module Spree::Stock::EstimatorDecorator
  def sort_shipping_rates(rates)
    # Prefer specific carriers, then cheapest
    rates.sort_by { |r| [r.shipping_method.name == 'UPS Ground' ? 0 : 1, r.cost] }
  end
  Spree::Stock::Estimator.prepend self
end
```

## Common shipping problems

### "Shipment stuck in `pending`"

Walk this list:

1. **Payment not complete?** Shipment doesn't move to `ready` until the order is paid. `order.payment_state == 'paid'`.
2. **Inventory not allocated?** `shipment.inventory_units.all? { |iu| iu.on_hand? }` — if any are `backordered`, it's waiting on stock.
3. **`determine_state` returning `pending`?** That's the explicit blocker; check what state the Shipment thinks the order is in: `shipment.determine_state(shipment.order)`.

### "No shipping rates appear at checkout"

- **No ShippingMethod covers the address's Zone.** Add a method for the country, OR add the country to an existing method's Zone.
- **No ShippingMethod covers the variant's ShippingCategory.** Make sure each variant has a category, and each method allows that category.
- **All methods' calculators return nil/zero erroneously.** Check by calling `Spree::Stock::Estimator.new(order).shipping_rates` in the console.

### "Order ships from the wrong warehouse"

`Spree::Stock::Splitter` picks based on first-available stock. To override, decorate or use a `Spree::Stock::CustomSplitter`. The default behavior favors the default StockLocation; if you want closest-warehouse-wins, write a custom splitter that consults distance.

### "Shipping rate doesn't update when cart changes"

The rates are cached per Shipment after first calculation. When the cart changes (line item added/removed), the Shipment is destroyed and recreated, so rates do recompute — but only at the next call to `Spree::Stock::Estimator`. If you're displaying rates in a Turbo Frame, make sure to re-render on cart updates.

## Where to read further

- **Source:** `bundle show spree_core`/app/models/spree/shipment.rb (state machine), shipping_method.rb, stock_location.rb.
- **Stock services:** `Spree::Stock::Estimator`, `Spree::Stock::Splitter`, `Spree::Stock::Coordinator`.
- **6.0 plans:** `docs/plans/6.0-fulfillment-and-delivery.md`, `docs/plans/6.0-typed-stock-movements.md`, `docs/plans/6.0-returns-exchanges-claims.md`.
- **Docs:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/shipments.mdx`.
