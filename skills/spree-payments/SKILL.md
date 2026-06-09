---
name: spree-payments
description: Use when the user is working with Spree's payment system — payment methods, gateways (Stripe, Adyen, PayPal), payment sessions, the payment state machine, refunds, store credits, gift cards. Common phrasings include "add payment gateway", "Stripe integration", "payment failed", "refund order", "store credit", "gift card", "payment state stuck", "configure PaymentMethod", "process payment manually". Provides the payment graph, the state machine, and the integration points.
---

# Spree Payments

Payments in Spree are layered:

```
PaymentMethod   — the configured way to pay (Stripe, Adyen, PayPal, store credit, …)
  ↓
Payment         — the actual charge against an Order via a PaymentMethod
  ↓
PaymentSource   — the customer's instrument (CreditCard, PaymentSession, etc.)
```

A single Order can have multiple Payments (split payments, multiple cards), each with its own state.

## Payment state machine

```
checkout  →  processing  →  pending  →  completed
                       ↘            ↘
                        failed       void
                       ↘
                        invalid
```

| State | What it means |
|---|---|
| `checkout` | Payment created during cart phase; no money moved yet |
| `processing` | Gateway call in flight |
| `pending` | Authorized but not captured (auth/capture flow, e.g. credit card pre-auth) |
| `completed` | Captured — money has actually moved |
| `failed` | Gateway returned an error during processing |
| `void` | Cancelled before capture |
| `invalid` | Card brand or instrument unsupported |

Transitions are events: `started_processing`, `pend`, `complete`, `failure`, `void`, `invalidate`. After-callbacks fire `payment.completed` / `payment.voided` events. See the `spree-events-webhooks` skill.

### `state` → `status` rename (6.0)

In 6.0, Payment.state becomes Payment.status (along with Shipment, InventoryUnit, ReturnAuthorization, GiftCard). On 5.x, use `payment.state`. On 6.0, use `payment.status`. Same values, different column name.

## Payment methods

A PaymentMethod is configured in the admin (Settings → Payments). The model carries:

- `type` — the Ruby class implementing it (`Spree::PaymentMethod::Stripe`, `Spree::PaymentMethod::StoreCredit`, etc.)
- `name` — what the customer sees ("Credit Card", "PayPal", etc.)
- `display_on` — where it's shown (`back_end`, `front_end`, `both`)
- `active` — whether it's currently accepting payments
- `auto_capture` — whether to capture immediately or hold as `pending`
- `preferences` — gateway credentials (encrypted preference store; never plain text on disk)

```ruby
stripe = Spree::PaymentMethod.create!(
  name: 'Credit Card',
  type: 'Spree::PaymentMethod::Stripe',
  display_on: 'front_end',
  active: true,
  preferences: { publishable_key: ENV['STRIPE_PUBLISHABLE_KEY'], secret_key: ENV['STRIPE_SECRET_KEY'] }
)
```

Most production stores don't create PaymentMethods in code — they're created via the admin UI after installing the gem (e.g. `spree_stripe`).

## Built-in payment method types

| Class | Source |
|---|---|
| `Spree::PaymentMethod::StoreCredit` | spree_core — pays from `Spree::StoreCredit` balance |
| `Spree::PaymentMethod::Check` | spree_core — back-office "manual" payment |
| `Spree::PaymentMethod::Stripe` | spree_stripe gem |
| `Spree::PaymentMethod::Adyen` | spree_adyen gem |
| `Spree::PaymentMethod::PaypalCheckout` | spree_paypal_checkout gem |

Custom payment methods subclass `Spree::PaymentMethod` and implement the gateway interface (`purchase`, `authorize`, `capture`, `void`, `credit`). Most stores use an existing extension instead of writing custom.

## Payment sessions (5.4+) — the modern flow

Classic Spree payments expected the storefront to collect card data and POST it. That doesn't work for hosted forms (Stripe Checkout) or drop-in widgets (Adyen). The 5.4+ `Spree::PaymentSession` model wraps the customer redirect / return flow.

```
Customer hits checkout
  ↓
Storefront creates a PaymentSession via the Store API
  ↓
API returns provider-specific session data (Stripe Checkout URL, Adyen drop-in payload, etc.)
  ↓
Customer interacts with provider UI
  ↓
Provider redirects back to storefront OR fires a webhook to backend
  ↓
PaymentSession.complete! → Payment created → Order transitions to confirm/complete
```

The session has events: `payment_session.completed`, `payment_session.failed`, `payment_session.canceled`, `payment_session.expired`. Sessions expire after a configurable TTL (default 15 minutes) — abandoned sessions don't leave dangling payments.

For most stores, you don't interact with PaymentSession directly — the gateway extension (spree_stripe, spree_adyen) handles creation and completion. You just subscribe to the events if you need to react.

## Adding a payment gateway

For Stripe, Adyen, PayPal: install the official extension. See the `spree-extensions` skill.

```bash
echo "gem 'spree_stripe'" >> backend/Gemfile
spree bundle install
spree rails g spree_stripe:install
spree migrate
spree restart
```

Then configure credentials via the admin Payment Methods UI (or via ENV-fed initializer for repeatability).

## Refunds + reimbursements

```
Payment (completed)
  ↓
Refund — partial or full credit back to the original payment source
```

Refunds carry a `Spree::RefundReason` (admin-managed: "duplicate charge", "customer return", etc.) and an amount. The Refund's `transaction_id` links to the gateway's refund record.

```ruby
payment = order.payments.completed.first
refund = payment.refunds.create!(
  amount: 25.00,
  reason: Spree::RefundReason.find_by(name: 'Goodwill'),
  refunder: current_user
)
# Then process via the gateway:
refund.process!
```

For partial refunds with return authorizations, the chain is:
```
Customer requests return → ReturnAuthorization → CustomerReturn → Reimbursement → Refund / StoreCredit
```

This is being significantly restructured in 6.0 — see the `Returns/Exchanges/Claims` plan in `docs/plans/6.0-returns-exchanges-claims.md`. On 5.x, the chain works but is awkward.

## Store credits

`Spree::StoreCredit` is built-in. Tracks balance per user per store per currency. Pays via `Spree::PaymentMethod::StoreCredit`.

```ruby
user.store_credits.create!(
  store: current_store,
  currency: 'USD',
  amount: 50.00,
  category: Spree::StoreCreditCategory.find_by(name: 'Goodwill'),
  created_by: current_admin_user,
  type_name: 'Goodwill credit'
)
```

Categories are admin-managed (Settings → Store Credit Categories). Non-expiring categories (configured via `Spree::Config[:non_expiring_credit_types]`) don't have a TTL.

## Gift cards

`Spree::GiftCard` is built-in (5.x). Each gift card has a redemption code and a remaining balance. Customers can apply at checkout; partial redemption is supported.

Events fired: `gift_card.redeemed`, `gift_card.partially_redeemed`. See the `spree-events-webhooks` skill.

```ruby
gc = Spree::GiftCard.create!(
  amount: 100.00,
  currency: 'USD',
  recipient_email: 'jane@example.com',
  code: SecureRandom.alphanumeric(16).upcase  # or let Spree generate
)
```

## Common payment problems

### "Payment stuck in `processing`"

The gateway call started but never finished. Either the gateway timed out (network), or the result-handling code crashed before transitioning. Check `payment.log_entries` (each Payment has a paper trail of gateway responses). Manually transition with `payment.failure!` after investigating.

### "Payment completed but order didn't transition"

The Payment is in `completed` but Order is still in `payment` or `confirm`. The order-state-machine should advance automatically; if it doesn't, check `order.payment_state` and run `Spree::OrderUpdater.new(order).update`.

### "Wrong amount captured"

By default, Spree captures the **outstanding balance** at checkout. If you ran an authorize earlier with a different amount (e.g. customer used a gift card after authorization), you need to void + re-authorize OR partial-capture (gateway-dependent).

### "Webhook from Stripe but no PaymentSession found"

The webhook arrived before the storefront's redirect-back, OR the PaymentSession TTL expired. Stripe's webhook is the source of truth — always trust it over the redirect-back. The `spree_stripe` gem handles this; if you're writing custom, idempotency keys are essential.

## Where to read further

- **Payment source:** `bundle show spree_core`/app/models/spree/payment.rb — the state machine and processing methods.
- **Payment processing:** `Spree::Payment::Processing` concern — `purchase`, `authorize`, `capture`, `void`, `credit` methods.
- **PaymentSession:** `Spree::PaymentSession` — the 5.4+ redirect-flow wrapper.
- **Docs:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/payments.mdx`.
- **Stripe gem:** `github.com/spree/spree_stripe` — best reference for a real-world payment integration.
