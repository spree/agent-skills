---
name: spree-checkout
description: Use when the user is working on Spree's checkout flow — cart pipeline, order state machine, address handling, the transition from cart to completed order, customizing checkout steps, payment sessions, guest checkout. Common phrasings include "checkout broken", "order stuck in X state", "skip address step", "guest checkout", "cart not advancing", "payment session", "customize checkout flow", "add a checkout step". Provides the order state machine, the cart pipeline, and the customization hooks.
---

# Spree Checkout

Checkout is how a cart becomes a completed order. In Spree, an Order is the cart (while in cart state) AND the completed transaction (post-complete); the `state` column tracks which phase you're in.

## The order state machine

Default checkout flow on an Order:

```
cart  →  address  →  delivery  →  payment  →  confirm  →  complete
```

Each step is conditional. Looking at `Spree::Order.checkout_flow`:

```ruby
checkout_flow do
  go_to_state :address
  go_to_state :delivery, if: ->(order) { order.delivery_required? }
  go_to_state :payment,  if: ->(order) { order.payment? || order.payment_required? }
  go_to_state :confirm,  if: ->(order) { order.confirmation_required? }
  go_to_state :complete
end
```

So:
- **All-digital orders** are not skipped via `delivery_required?` — in core that method unconditionally returns `true` (decorate it to change). Instead, digital-only orders (`requires_ship_address?` is `!digital?`) still transition *into* `delivery`, then an `after_transition to: :delivery` hook (`move_to_next_step_if_address_not_required`) immediately calls `next!` to auto-advance past it.
- **Zero-total orders** (free orders) skip `payment` — `payment_required?` is simply `total.to_f > 0.0`. Note gift cards do NOT zero the total: applying one creates a store-credit payment for the covered amount, so a gift-card-covered order still has `total > 0` and still goes through the `payment` step, where that payment satisfies it.
- **`confirm`** is opt-in — disabled by default; some payment integrations enable it.

The transition driver is `state_machines-activerecord`. Advance with `order.next!` (raises on failure) or `order.next` (returns false on failure).

```ruby
cart.state                # => "cart"
cart.next!                # => transitions to "address" (if validation passes)
cart.state                # => "address"
```

### `state` vs `status` columns

Order has BOTH `state` (the checkout state machine — values from the flow above) and `status` (the high-level lifecycle: `Spree::Order::STATUSES = %w[draft placed canceled]`). `payment_state` and `shipment_state` are separate denormalized columns reflecting the rollup of child Payment and Shipment states.

## The cart pipeline (recalculate chain)

Whenever a cart changes (item added, removed, address updated, promo applied), Spree runs a **recalculate chain** to keep derived state correct. The chain is `Spree.cart_recalculate_service` (default: `Spree::Cart::Recalculate`):

```
Spree::Cart::Recalculate
  ├── Update item totals
  ├── Recalculate adjustments (taxes, discounts, fees)
  ├── Apply promotion actions
  ├── Update shipment costs
  ├── Recompute order totals
  └── Persist
```

The chain is composed of services swappable via `Spree.dependencies`:

```ruby
# config/initializers/spree.rb
Spree.cart_add_item_service       = MyApp::Cart::AddItem
Spree.cart_recalculate_service    = MyApp::Cart::Recalculate
Spree.cart_remove_item_service    = MyApp::Cart::RemoveItem
Spree.cart_update_service         = MyApp::Cart::Update
```

To inject behavior into the cart pipeline, **subclass the service**, override `call`, and register. Don't decorate `Spree::Order` to add a callback — that fires on every save and confuses the state machine.

For the full `Spree.dependencies` system (catalog of swappable services, introspection rake tasks, per-API-surface overrides), see the `spree-dependencies` skill.

```ruby
module MyApp
  module Cart
    class AddItem < Spree::Cart::AddItem
      def call(order:, variant:, quantity: nil, metadata: {}, public_metadata: {}, private_metadata: {}, options: {})
        ApplicationRecord.transaction do
          run :add_to_line_item
          run :handle_stock_reservations     # keep the parent's stock reservation step
          run :my_custom_step                # your custom logic
          run Spree.cart_recalculate_service
        end
      end

      def my_custom_step(order:, line_item:, line_item_created:, options:)
        # ... your custom logic ...
        success(order: order, line_item: line_item, line_item_created: line_item_created, options: options)
      end
    end
  end
end
```

When you subclass `Spree::Cart::AddItem`, keep all the parent's `run` steps and slot yours in — don't drop `:handle_stock_reservations` or you'll silently break stock reservations for orders in checkout. Every `run` step receives the previous step's `success(...)` hash as keywords and must itself end with `success(...)`/`failure(...)` — that's why `my_custom_step` above takes the keys `handle_stock_reservations` returns and passes them along.

## Customizing the checkout flow

Add, remove, or reorder steps via `Spree::Order#checkout_flow` (decorator). The state machine is rebuilt when the flow is re-declared.

```ruby
# backend/app/models/spree/order_decorator.rb — REMOVE the address step (e.g. digital-only store)
module Spree::OrderDecorator
  def self.prepended(base)
    base.checkout_flow do
      go_to_state :delivery, if: ->(order) { order.delivery_required? }
      go_to_state :payment,  if: ->(order) { order.payment? || order.payment_required? }
      go_to_state :complete
    end
  end

  Spree::Order.prepend self
end
```

To **insert** a new step (e.g. a "review" step between `payment` and `confirm`):

```ruby
base.insert_checkout_step :review, after: :payment
```

To **remove** a single step there's also `base.remove_checkout_step :address` (one step per call) — no need to re-declare the whole flow unless you're redefining it entirely.

Common gotchas:

- **Existing in-progress orders have a `state` that may not exist in your new flow.** Add a backfill rake task that resets them to `cart` or migrates to the new state.
- **State machine guards run on every transition** — `delivery_required?`, `payment_required?`, etc. Decorating these to lie about the cart's state breaks the flow.

## Address handling

`Spree::Address` is used for both billing and shipping. Order has `bill_address_id` and `ship_address_id`. Both can point at the same address (one-form checkout); the validator allows nil for both during the `cart` state.

Country/State are normalized to `Spree::Country` and `Spree::State` records (not free text). Form input from the storefront is validated against the country's `Spree::State` set. State validation is gated by `Spree::Config[:address_requires_state]` (marked deprecated in 5.5, but still honored) and the country's `states_required` flag — countries with `states_required: false` skip it entirely. A country with `states_required: true` but no seeded `Spree::State` records still requires a free-text `state_name`.

### Guest checkout vs logged-in

`Order.user_id` is nullable. Guest orders have `email` set instead. After completion, the guest's order token remains the credential for viewing the order — `GET /api/v3/store/orders/:id` with the `X-Spree-Token` header. If the guest opts into account creation at checkout, `Spree::Orders::CreateUserAccount` links the order to a new user (or an existing user with the same email) at completion. There is no number+email claim flow, and registering later does not auto-link past guest orders.

For the storefront, the guest cart is tracked via a **cart token** (`Order.token` — a random per-cart string). The token is in a cookie or returned to the API client. JWT auth replaces token auth once the customer logs in.

## Payment sessions (5.4+)

The classic Spree payment flow created a Payment record + processed it inline. The 5.4+ refactor introduced **PaymentSession** — an intermediate object that handles redirect-based provider flows (Stripe Checkout, Adyen drop-in, PayPal Smart Buttons).

```
Order (cart)
  ↓
PaymentSession  ← provider-specific session data
  ↓             (created by spree_stripe / spree_adyen / spree_paypal_checkout)
Customer redirects to provider
  ↓
Customer returns OR provider webhook fires
  ↓
PaymentSession.complete!
  ↓
Payment record created
  ↓
Order transitions to `confirm` or `complete`
```

Events: `payment_session.processing`, `payment_session.completed`, `payment_session.failed`, `payment_session.canceled`, `payment_session.expired`. See the `spree-events-webhooks` skill.

In your subscriber, the `payment_session.completed` event payload includes the `order_id` — you can hook in custom logic after the customer returns from the provider but before the order finalizes.

## The complete transition

When the order transitions to `complete`:

1. Inventory is allocated via shipment finalization (`shipment.finalize!`); stock reservations from checkout are released (deleted) by `Spree::StockReservations::Release` once the order completes.
2. `Spree::OrderUpdater` finalizes totals.
3. `order.completed_at` is set.
4. `order.publish_event('order.completed', payload)` fires — subscribers run, webhooks deliver.
5. For guests, the order token remains the credential for viewing the completed order — the Store API scopes guest order lookup by `token` (`X-Spree-Token` header). The order's human-facing `number` (e.g. `R123456789`, assigned at creation) is for display and support, not API lookup.

After complete, the order should be immutable from the customer's side. Admins can still adjust (refunds, return authorizations, edits) but those go through dedicated controllers, not the cart pipeline.

## Common checkout problems

### "Order stuck in checkout"

- Missing line items: `order.line_items.count == 0`. `ensure_line_items_present` runs on every transition out of `cart` — this is the only thing that blocks leaving `cart` itself.
- Missing address: `order.bill_address` or `order.ship_address` is nil. This doesn't block leaving `cart` — it surfaces at `address → delivery` (no ship address means no proposed shipments, so `ensure_available_shipping_rates` fails). Run `order.next!` and check the validation errors.
- A variant became discontinued or out of stock: blocks the transition to `complete` (and `resumed`), and the order gets bounced back to the start of checkout via `restart_checkout_flow`. Check `order.line_items.map(&:variant).map(&:purchasable?)`.

### "Customer redirected to Stripe but never returned"

- PaymentSession is still in `processing` state. Either Stripe's webhook never fired (check `spree_stripe`'s endpoint config) or the customer abandoned. The session has a TTL (`expires_at`) — core filters timed-out sessions via the `not_expired`/`active` scopes, but the `payment_session.expired` event only fires when something explicitly triggers the `expire` transition (typically the gateway extension reacting to a provider webhook).
- The redirect-back URL is wrong. Check `spree_stripe`'s configured `return_url`.

### "Cart total doesn't match what's displayed"

- The cart pipeline didn't run after the last change. Trigger `Spree::Cart::Recalculate.call(order: order, line_item: order.line_items.last)` manually and inspect.
- A custom adjustment isn't being applied. Check `order.adjustments.eligible.sum(:amount)`.
- Promotions are eligible but not applied. See the `spree-promotions` skill — common cause is promotion `usage_limit` exhausted.

### "Skip the payment step for a free order"

`order.payment_required?` returns false when the order total is zero (`total.to_f > 0.0` is the implementation). If your custom flow needs to skip even more aggressively, override `payment_required?`:

```ruby
module Spree::OrderDecorator
  def payment_required?
    return false if my_special_condition?
    super
  end

  Spree::Order.prepend self
end
```

## Where to read further

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/orders.md`, `payments.md`
- **Checkout customization:** `node_modules/@spree/docs/dist/developer/customization/checkout.md`
- **Order source:** `Spree::Order` and `Spree::Order::Checkout` in the installed `spree_core` gem — the state machine wiring.
- **Cart services:** `Spree::Cart::AddItem`, `Spree::Cart::Recalculate`, etc. in `spree_core/app/services/spree/cart/`.
