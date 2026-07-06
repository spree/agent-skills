---
name: spree-shipping-fulfillment
description: Use when the user is working with Spree's shipping system — shipments, shipping methods, shipping rates, stock locations, the shipment state machine, splitter logic, returns. Common phrasings include "shipping method", "calculate shipping rate", "stock location", "shipment stuck in pending", "order fulfillment", "ship from", "shipping zone", "shipping category", "returns", "reimbursement". Provides the shipping graph, the state machine, and customization hooks.
---

# Spree Shipping

The shipping system answers two questions: *where is this order going* (the shipping method) and *where is it shipping from* (the stock location). Together they produce one or more Shipments — each Shipment represents a package leaving a specific StockLocation via a specific ShippingMethod.

## The shipping graph

```
Order
  └── Shipment (one per fulfillment package — may be many per order)
        ├── StockLocation        — where it ships from
        ├── ShippingRate × n     — offered rates from configured methods
        │    └── ShippingMethod  — UPS Ground, USPS Priority, etc.
        └── InventoryUnit × n    — per LineItem, each carrying a quantity (may split, e.g. partial backorder)

ShippingMethod
  ├── ShippingCategory × n       — which categories of items this method handles
  ├── Calculator                 — how much (per-order, per-item, weight-based)
  └── Zone × n                   — where this method applies

Variant
  └── ShippingCategory           — heavy items, fragile items, digital, etc.
```

Each line item's variant has a ShippingCategory. A ShippingMethod's eligibility for a shipment depends on whether the variant's category is in the method's allowed categories AND the destination is in the method's Zone.

## Shipment state machine

```
pending ──ready──→ ready ──ship──→ shipped
   │    ←─pend──     │                ↑
   │                 │                │
   └────cancel───→ canceled ──ship────┘
                      │
                      └──resume──→ ready (or pending if not yet ready)
```

(`cancel` is allowed from both `pending` and `ready`; `resume` returns a canceled shipment to `ready` — or `pending` when the order isn't ready — and a canceled shipment can be shipped directly via `ship`.)

| State | What it means |
|---|---|
| `pending` | Created but not yet ready to ship (waiting on payment, allocation, etc.) |
| `ready` | Inventory allocated, ready for the warehouse to pick |
| `shipped` | Picked up by carrier; tracking number set |
| `canceled` | Order was canceled; the shipment doesn't go out |

Transitions: `ready`, `pend` (back to pending), `ship`, `cancel`, `resume`. The `ship` transition fires the `shipment.shipped` event (subscribers see it) and updates `order.shipment_state` to `shipped` or `partial` based on the order's other shipments. The `cancel` and `resume` transitions fire `shipment.canceled` and `shipment.resumed` respectively.

## How shipping rates get calculated

When an order enters the `delivery` checkout state (after address):

```
For each Shipment in order:
  package = shipment.to_package
  Spree::Stock::Estimator.new(order).shipping_rates(package)
    ↓
    For each ShippingMethod where:
      - method.shipping_categories.include?(variant.shipping_category)
      - method.zones.include?(zone_for(order.ship_address))
    ↓
    Run method.calculator.compute(package)
    ↓
    ShippingRate(shipping_method: method, cost: amount, selected: best)
```

The cheapest rate per Shipment is `selected: true` by default. The customer can pick a different one in the checkout UI.

## Built-in calculators

| Calculator | Computes |
|---|---|
| `Spree::Calculator::Shipping::FlatRate` | Same flat rate; optional min/max weight and item-total bounds (returns nil → method unavailable outside them) |
| `Spree::Calculator::Shipping::FlatPercentItemTotal` | % of order item total |
| `Spree::Calculator::Shipping::PerItem` | Rate × number of items |
| `Spree::Calculator::Shipping::FlexiRate` | Tiered by item count |
| `Spree::Calculator::Shipping::PriceSack` | Tiered by order total (e.g. under $50 = $10, over $50 = free) |
| `Spree::Calculator::Shipping::DigitalDelivery` | Configurable amount (default 0); only available when every item in the package is digital |

Custom shipping calculators subclass `Spree::ShippingCalculator` and implement `compute_package(package)` (optionally `available?(package)`). The package is a `Spree::Stock::Package` with contents, total weight, and item total.

## StockLocation

Stock is tracked per-Variant per-StockLocation via `Spree::StockItem`. A store has at least one StockLocation; multi-warehouse stores have many.

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
  default: false                 # only one StockLocation can be the default
)

variant.stock_items.where(stock_location: warehouse).first.count_on_hand
variant.total_on_hand   # summed across all locations
```

### StockMovement

Stock changes are recorded as `Spree::StockMovement` entries — an audit log:

```ruby
stock_item = warehouse.stock_item_or_create(variant)
stock_item.stock_movements.create!(
  quantity: 10,                  # positive = received, negative = sold/lost
  originator: purchase_order     # polymorphic — what caused the movement
)
# or the higher-level helpers (these wrap the same StockMovement creation):
warehouse.restock(variant, 10, purchase_order)
warehouse.unstock(variant, 2, shipment)
```

Don't update `count_on_hand` directly; create a StockMovement and let the model recompute the count.

## How Shipments split across StockLocations

When an order is split into shipments, Spree groups InventoryUnits by where they can ship from:

```
Order has 3 items: [A from East, B from East, C from West]
  ↓
Order Routing (`order.order_routing_strategy.for_allocation`, default `Spree::OrderRouting::Strategy::Rules`) ranks eligible StockLocations via the channel's routing rules, packs each location (`Spree::Stock::Packer` + the `Spree.stock_splitters` chain), and `Spree::Stock::Prioritizer` assigns each inventory unit to the first ranked package with on-hand stock
  ↓
Creates 2 Shipments:
  - Shipment 1: items A + B from East Warehouse
  - Shipment 2: item C from West Warehouse
```

Since Spree 5.5, *which* stock locations fulfill an order is decided by **Order Routing**, not the splitters. Each Channel has an ordered list of `Spree::OrderRoutingRule` rows (STI subclasses: `Spree::OrderRouting::Rules::PreferredLocation`, `MinimizeSplits`, `DefaultLocation` — seeded in that priority order) that rank the candidate stock locations. The routing strategy is configurable via `store.preferred_order_routing_strategy` (default `Spree::OrderRouting::Strategy::Rules`), overridable per channel; `Spree::OrderRouting::Strategy::Legacy` restores the pre-5.5 `Spree::Stock::Coordinator` behavior and is dropped in 6.0. Splitters then break each chosen location's allocation into packages *within* that location.

Each Shipment gets its own ShippingRate calculation (different origin = different rates). The customer pays each shipment's selected rate.

For location-preference logic — distance-based, prefer-closest-warehouse, minimize splits — write a custom order routing rule or strategy, see `node_modules/@spree/docs/dist/developer/how-to/custom-order-routing.md`. For breaking one location's allocation into more packages (refrigerated, hazmat, gift wrap), write a custom splitter — see `node_modules/@spree/docs/dist/developer/how-to/custom-stock-splitter.md`.

### Manual fulfillments (3PL / external fulfillment)

To mirror an externally-managed fulfillment back into Spree — a 3PL or courier API shipped part of a completed order — use `Spree::Fulfillments::Create` (5.5+) instead of hand-building shipments. It bypasses order routing, moves the requested not-yet-shipped units out of their current shipments into a new one, and handles the stock bookkeeping (restock at source / unstock at target when locations differ):

```ruby
result = Spree.fulfillment_create_service.call(
  order: order,                       # must be completed, not canceled
  stock_location: three_pl_location,
  items: [{ line_item: li, quantity: 1 }],   # nil = everything not yet shipped
  tracking: '1Z…',
  delivery_method: shipping_method,   # defaults to the drained source shipment's
  cost: '12.50',                      # explicit 3PL price; defaults to carrying over the source cost
  status: 'shipped'                   # register as already shipped ('shipped' is the only accepted value; omit for pending)
)

result.valid? # true if the fulfillment was created successfully
```

Note an explicit `cost` sticks only with `status: 'shipped'` — pending fulfillments get re-priced by the rate engine on the next recalculation.

## Returns + Reverse Logistics

A customer wants to return an item:

```
ReturnAuthorization (admin-created, lists which InventoryUnits)
  ↓
Customer ships item back
  ↓
CustomerReturn (admin-received, links InventoryUnits to receipt)
  ↓
Reimbursement (calculates the refund amount from the return items' amounts — admins can adjust per-item amounts before reimbursing)
  ↓
Refund (to original payment) OR StoreCredit
```

Admin creates a `ReturnAuthorization` listing the InventoryUnits the customer is returning. When the items come back, an admin records a `CustomerReturn` to mark the units received. The `Reimbursement` calculates the refund amount from the return items' amounts, and produces either a `Refund` (back to the original payment method) or a `StoreCredit`.

## Customizing shipping

### Custom calculator

```ruby
# app/models/spree/calculator/shipping/weight_based.rb
module Spree
  class Calculator::Shipping::WeightBased < Spree::ShippingCalculator
    preference :rate_per_kg, :decimal, default: 5.00

    def compute_package(package)
      package.weight * preferred_rate_per_kg
    end
  end
end

# Register so it shows in the admin shipping method UI (config/initializers/spree.rb)
Rails.application.config.after_initialize do
  Spree.calculators.shipping_methods << Spree::Calculator::Shipping::WeightBased
end
```

### Hooking into shipment events

For external warehouse integration, subscribe to `shipment.shipped`:

```ruby
class ShipmentShippedSubscriber < Spree::Subscriber
  subscribes_to 'shipment.shipped'

  def call(event)
    shipment = Spree::Shipment.find_by_prefix_id(event.payload['id'])
    return unless shipment

    ExternalWarehouseAPI.notify_dispatched(
      tracking: shipment.tracking,
      shipping_method: shipment.shipping_method.name,
      order_number: shipment.order.number
    )
  end
end
```

See the `spree-events-webhooks` skill for the events system.

### Custom shipping rate ranking

By default, the cheapest rate is selected. To prefer carrier reliability, decorate `Spree::Stock::Estimator`:

```ruby
module Spree::Stock::EstimatorDecorator
  # which rate is pre-selected
  def choose_default_shipping_rate(rates)
    preferred = rates.find { |r| r.shipping_method.name == 'UPS Ground' }
    (preferred || rates.min_by(&:cost))&.selected = true
  end

  # display order
  def sort_shipping_rates(rates)
    rates.sort_by { |r| [r.shipping_method.name == 'UPS Ground' ? 0 : 1, r.cost] }
  end

  Spree::Stock::Estimator.prepend self
end
```

Note: `sort_shipping_rates` only affects display order; `choose_default_shipping_rate` (which runs first, picking the cheapest by default) decides which rate gets `selected: true`.

## Common shipping problems

### "Shipment stuck in `pending`"

Walk this list:

1. **Payment not complete?** Shipment doesn't move to `ready` until the order is paid. `order.payment_state == 'paid'`.
2. **Inventory not allocated?** `shipment.inventory_units.all? { |iu| iu.on_hand? }` — if any are `backordered`, it's waiting on stock.
3. **`determine_state` returning `pending`?** That's the explicit blocker; check what state the Shipment thinks the order is in via `shipment.determine_state(shipment.order)`.

### "No shipping rates appear at checkout"

- **No ShippingMethod covers the address's Zone.** Add a method for the country, OR add the country to an existing method's Zone.
- **No ShippingMethod covers the variant's ShippingCategory.** Make sure each variant has a category and each method allows that category.
- **All methods' calculators return nil/zero erroneously.** Inspect rates by calling `Spree::Stock::Estimator.new(order).shipping_rates(package)` for each `package` in `order.shipments.map(&:to_package)` in the console.

### "Order ships from the wrong warehouse"

Order Routing decides the location: the default `Spree::OrderRouting::Strategy::Rules` walks the channel's routing rules (preferred_location → minimize_splits → default_location baseline). Adjust the channel's `Spree::OrderRoutingRule` rows, or for closest-warehouse-wins write a custom routing rule (implementing `#rank(order, locations)`) or strategy — see `node_modules/@spree/docs/dist/developer/how-to/custom-order-routing.md`.

### "Shipping rate doesn't update when cart changes"

The rates are cached per Shipment after first calculation. When the cart changes (line item added/removed), the Shipment is destroyed and recreated, so rates do recompute at the next call to `Spree::Stock::Estimator`. If you're displaying rates in a Turbo Frame, make sure to re-render on cart updates.

## Where to read further

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/shipments.md`, `inventory.md`
- **Custom stock splitter:** `node_modules/@spree/docs/dist/developer/how-to/custom-stock-splitter.md`
- **Custom order routing:** `node_modules/@spree/docs/dist/developer/how-to/custom-order-routing.md`
- **Stock services:** `Spree::Stock::Estimator`, `Spree::Stock::Packer`, `Spree::Stock::Prioritizer`, `Spree::Stock::Splitter::Base` (+ `ShippingCategory`/`Backordered`/`Digital`/`Weight` subclasses). Allocation goes through `Spree::OrderRouting::Strategy::Rules` by default; `Spree::Stock::Coordinator` is deprecated (slated for removal in 6.0) and survives only in the opt-in Legacy routing strategy, `Spree::Exchange`, and `Spree::Cart::EstimateShippingRates`.
