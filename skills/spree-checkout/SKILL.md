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
- **All-digital orders** skip `delivery` (`delivery_required?` returns false when no shippable line items).
- **Zero-total orders** (gift cards covering the total, free orders) skip `payment`.
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

      def my_custom_step(order:, variant:, **)
        # ...
      end
    end
  end
end
```

When you subclass `Spree::Cart::AddItem`, keep all the parent's `run` steps and slot yours in — don't drop `:handle_stock_reservations` or you'll silently break stock reservations for orders in checkout.

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

Common gotchas:

- **Existing in-progress orders have a `state` that may not exist in your new flow.** Add a backfill rake task that resets them to `cart` or migrates to the new state.
- **State machine guards run on every transition** — `delivery_required?`, `payment_required?`, etc. Decorating these to lie about the cart's state breaks the flow.

## Address handling

`Spree::Address` is used for both billing and shipping. Order has `bill_address_id` and `ship_address_id`. Both can point at the same address (one-form checkout); the validator allows nil for both during the `cart` state.

Country/State are normalized to `Spree::Country` and `Spree::State` records (not free text). Form input from the storefront is validated against the country's `Spree::State` set. Countries without states (Andorra, etc.) skip state validation.

### Guest checkout vs logged-in

`Order.user_id` is nullable. Guest orders have `email` set instead. After completion, guests can claim their order via the order number + email, OR sign up using the email (Spree links the order on registration if email matches).

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

Events: `payment_session.completed`, `payment_session.failed`, `payment_session.canceled`, `payment_session.expired`. See the `spree-events-webhooks` skill.

In your subscriber, the `payment_session.completed` event payload includes the `order_id` — you can hook in custom logic after the customer returns from the provider but before the order finalizes.

## The complete transition

When the order transitions to `complete`:

1. Inventory is allocated (stock reservations become committed, see 5.4's stock reservations system).
2. `Spree::OrderUpdater` finalizes totals.
3. `order.completed_at` is set.
4. `order.publish_event('order.completed', payload)` fires — subscribers run, webhooks deliver.
5. The cart token becomes irrelevant; the order is now identified by its `number` (e.g. `R123456789`).

After complete, the order should be immutable from the customer's side. Admins can still adjust (refunds, return authorizations, edits) but those go through dedicated controllers, not the cart pipeline.

## Common checkout problems

### "Order stuck in `cart`"

- Missing address: `order.bill_address` or `order.ship_address` is nil. Run `order.next!` and check the validation errors.
- Missing line items: `order.line_items.count == 0`. The state machine won't advance past `cart` without items.
- Validation error on a line item: a variant became unavailable; check `order.line_items.map(&:variant).map(&:purchasable?)`.

### "Customer redirected to Stripe but never returned"

- PaymentSession is still in `processing` state. Either Stripe's webhook never fired (check `spree_stripe`'s endpoint config) or the customer abandoned. The session has a TTL — `payment_session.expired` fires when it times out.
- The redirect-back URL is wrong. Check `spree_stripe`'s configured `return_url`.

### "Cart total doesn't match what's displayed"

- The cart pipeline didn't run after the last change. Trigger `Spree::Cart::Recalculate.call(order: order, line_item: order.line_items.last)` manually and inspect.
- A custom adjustment isn't being applied. Check `order.adjustments.eligible.sum(:amount)`.
- Promotions are eligible but not applied. See the `spree-promotions` skill — common cause is promotion `usage_limit` exhausted.

### "Skip the payment step for a free order"

`order.payment_required?` returns false when `outstanding_balance.zero?`. If your custom flow needs to skip even more aggressively, override `payment_required?`:

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

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/orders.mdx`, `payments.mdx`
- **Checkout customization:** `node_modules/@spree/docs/dist/developer/customization/checkout.mdx`
- **Order source:** `Spree::Order` and `Spree::Order::Checkout` in the installed `spree_core` gem — the state machine wiring.
- **Cart services:** `Spree::Cart::AddItem`, `Spree::Cart::Recalculate`, etc. in `spree_core/app/services/spree/cart/`.
