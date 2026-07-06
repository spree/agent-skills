---
name: spree-events-webhooks
description: Use when the user wants Spree to react to something that happened — sync orders to an ERP, send notifications, fire webhooks, integrate with external services, configure webhook endpoints, verify webhook signatures. Common phrasings include "react to X", "when X happens", "send notification when", "sync to external service", "Spree events", "subscribers", "publish_event", "webhook endpoint", "webhook signature", "X-Spree-Webhook-Signature", "HMAC", "webhook retry", "webhook failed", "webhook.test". Covers in-process subscribers (Ruby side effects) AND outbound webhooks (HTTPS POSTs to external URLs).
---

# Spree Events + Webhooks

Spree has **two layered systems** for reacting to lifecycle events. Both subscribe to the same events; what differs is the delivery target.

| System | Lives | Use for |
|---|---|---|
| **Subscribers** | Ruby code in your Rails app | Sync to your own ERP, send transactional email, update analytics, invalidate caches |
| **Webhooks** | HTTPS POSTs to external URLs | Third-party integrations, partner systems, customer-built apps |

You pick a subscriber when **you** are the consumer. You pick a webhook when **another system** is the consumer.

## Part 1: Subscribers (in-process)

```
Spree::Order.complete!
  ↓
order.publish_event('order.completed', payload)
  ↓
Spree::Subscribers each receive the event
  ↓
Your subscriber: sync to ERP, send email, etc.
```

Automatic lifecycle events (`*.created`, `*.updated`, `*.deleted`) fire after the transaction commits — if the write fails, those subscribers never run. Custom events published via `publish_event(...)` (including `order.completed`) are dispatched at the call site, which may be inside an open transaction: sync subscribers run inline, and async subscriber jobs are enqueued immediately — possibly before the commit. Don't assume the surrounding write has committed.

### Writing a subscriber

Use the generator (Spree 5.5+) — it creates the class, a spec stub, and handles registration:

```bash
spree generate subscriber OrderComplete order.completed   # native: bin/rails g spree:subscriber …
# flags: --sync (async: false), --skip-spec
```

Or by hand: put the class anywhere autoloadable (e.g. `app/subscribers/`), then register it in an initializer — subscribers are NOT auto-discovered, and an unregistered subscriber is a silent no-op:

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.subscribers << OrderCompleteSubscriber
end
```

```ruby
# app/subscribers/order_complete_subscriber.rb
class OrderCompleteSubscriber < Spree::Subscriber
  subscribes_to 'order.completed'

  def handle(event)
    order_id = event.payload['id']
    ExternalErp.sync_order(order_id)
  end
end
```

The handler method is `handle(event)` (or route with the `on` DSL below). Don't override `call` — the base `call` is the dispatch entry that routes `on`-declared handlers and falls back to `handle`, so overriding it silently disables `on` routing. Subscribers run **asynchronously** via `Spree::Events::SubscriberJob` by default; opt into synchronous execution only when the side effect must complete before the publisher's transaction returns:

```ruby
class CriticalOrderHandler < Spree::Subscriber
  subscribes_to 'order.completed', async: false

  def handle(event)
    # Runs inline, blocks the publisher
  end
end
```

### Multiple events from one subscriber

Single handler, dispatch on `event.name`:

```ruby
class OrderActivitySubscriber < Spree::Subscriber
  subscribes_to 'order.completed', 'order.paid', 'order.shipped'

  def handle(event)
    case event.name
    when 'order.completed' then track_completion(event)
    when 'order.paid'      then track_payment(event)
    when 'order.shipped'   then track_shipment(event)
    end
  end
end
```

Or use the `on` DSL to route specific events to specific methods:

```ruby
class PaymentSubscriber < Spree::Subscriber
  subscribes_to 'payment.completed', 'payment.voided'

  on 'payment.completed', :handle_complete
  on 'payment.voided', :handle_void

  private

  def handle_complete(event)
    # ...
  end

  def handle_void(event)
    # ...
  end
end
```

### Pattern matching

Wildcards subscribe to a family of events:

```ruby
class OrderEventLogger < Spree::Subscriber
  subscribes_to 'order.*'

  def handle(event)
    Rails.logger.info("Order event: #{event.name}")
  end
end
```

## Part 2: Webhooks (outbound HTTPS)

```
Spree::Order.complete!
  ↓
order.publish_event('order.completed', payload)
  ↓
Spree::WebhookEventSubscriber receives it (shipped with spree_api)
  ↓
For each Spree::WebhookEndpoint subscribed_to?('order.completed'):
  ↓
Create Spree::WebhookDelivery (queued)
  ↓
Spree::WebhookDeliveryJob (ActiveJob, on Spree.queues.webhooks) → POST to endpoint URL
  ↓
On failure: delivery recorded as failed (manual redeliver available)
On 15 consecutive failures: auto-disable endpoint
```

### Configuring an endpoint

Admin UI: **Settings → Webhooks → Add endpoint**.

Via API:

```bash
curl -X POST https://my-spree.example.com/api/v3/admin/webhook_endpoints \
  -H "X-Spree-Api-Key: sk_…" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Order sync to ERP",
    "url": "https://my-erp.example.com/spree-webhooks",
    "subscriptions": ["order.completed", "order.paid", "order.shipped"],
    "active": true
  }'
```

The response includes a plaintext `secret_key` **only on create** (Stripe-style — you'll never see it again, store it). Use it to verify signatures on the receiving end.

`subscriptions` is an array of event names. Supports:
- Exact match: `"order.completed"`
- Wildcard: `"order.*"` matches `order.completed`, `order.paid`, etc.
- Catch-all: `"*"` or empty array — receive everything

### Webhook payload format

```json
POST /your-webhook-url HTTP/1.1
Content-Type: application/json
User-Agent: Spree-Webhooks/1.0
X-Spree-Webhook-Signature: <hex hmac>
X-Spree-Webhook-Timestamp: 1728432000
X-Spree-Webhook-Event: order.completed

{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "order.completed",
  "created_at": "2026-06-08T12:00:00Z",
  "data": {
    "id": "or_m3Rp9wXz",
    "number": "R123456789",
    "total": "129.99",
    "...": "..."
  },
  "metadata": {
    "spree_version": "5.5.0"
  }
}
```

### Verifying the signature

The signature is HMAC-SHA256 over `"{timestamp}.{payload_json}"` using the endpoint's `secret_key`. **Always verify** — without it any actor can forge POSTs to your URL.

```ruby
# Ruby receiver
def verify_webhook(request)
  timestamp = request.headers['X-Spree-Webhook-Timestamp']
  signature = request.headers['X-Spree-Webhook-Signature']
  body = request.body.read

  # Reject replays older than 5 minutes
  return false if (Time.current.to_i - timestamp.to_i).abs > 300

  expected = OpenSSL::HMAC.hexdigest('SHA256', ENV['SPREE_WEBHOOK_SECRET'], "#{timestamp}.#{body}")
  ActiveSupport::SecurityUtils.secure_compare(expected, signature)
end
```

```ts
// Node receiver
import crypto from 'crypto'

function verifyWebhook(req: Request): boolean {
  const timestamp = req.headers['x-spree-webhook-timestamp']
  const signature = req.headers['x-spree-webhook-signature']
  const body = req.rawBody  // raw bytes, NOT the parsed JSON

  // Reject replays older than 5 minutes
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false

  const expected = crypto
    .createHmac('sha256', process.env.SPREE_WEBHOOK_SECRET!)
    .update(`${timestamp}.${body}`)
    .digest('hex')

  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signature as string))
}
```

**Gotchas:**
1. **Verify on the raw body, not the parsed JSON.** Re-serializing JSON changes whitespace and key order — the signature won't match.
2. **Always use timing-safe compare** (`secure_compare`, `timingSafeEqual`). String `==` leaks the secret via timing side-channel.
3. **Check the timestamp** to reject replay attacks. 5 minutes is the conventional window.

### Retry + auto-disable

Failed deliveries (timeout, 5xx, connection error) are recorded on the delivery record — Spree does **not** automatically retry a failed delivery. (Don't be misled by the `retry_on StandardError, attempts: 5` on `WebhookDeliveryJob`: `DeliverWebhook` rescues HTTP/timeout errors and records them as failed without re-raising, so that ActiveJob retry path never fires for ordinary delivery failures.) Retry manually with `delivery.redeliver!` (creates a fresh delivery and queues it), the admin UI's redeliver button on the delivery page, or `POST /api/v3/admin/webhook_endpoints/:webhook_endpoint_id/deliveries/:id/redeliver`. After **15 consecutive failures**, the endpoint auto-disables and an email goes to store staff (`Spree::WebhookMailer.endpoint_disabled`).

Re-enable via `endpoint.enable!` or by toggling `active: true` in the admin UI. A more recent successful delivery breaks the consecutive-failure streak (the check queries recent deliveries — there's no stored counter).

Inspect failures:

```ruby
endpoint = Spree::WebhookEndpoint.find_by_prefix_id('whe_…')
endpoint.webhook_deliveries.where(success: false).order(delivered_at: :desc).first(20)
# Each has: response_code, response_body, error_type, request_errors, execution_time
```

### Testing an endpoint

The admin UI has a "Send test" button — fires a synthetic `webhook.test` event so you can verify connectivity without waiting for a real order to complete.

```ruby
endpoint.send_test!   # creates and queues a Spree::WebhookDelivery
```

### SSRF protection

In production, endpoint URLs are validated against private IP ranges (RFC 1918, link-local, loopback) via `ssrf_filter`. In development, this is disabled so you can webhook to `localhost` / `host.docker.internal`.

## Events Spree publishes

### Order lifecycle

| Event | When |
|---|---|
| `order.completed` | Customer finalizes the order (post-payment) |
| `order.paid` | All payments processed successfully |
| `order.shipped` | All of the order's shipments are marked shipped (`order.fully_shipped?`) — a partial shipment doesn't fire it |
| `order.approved` | An admin approves a pending order |
| `order.canceled` | Order is canceled |
| `order.resumed` | A canceled order is reactivated |
| `order.updated` | General-purpose order change event |

### Payment lifecycle

| Event | When |
|---|---|
| `payment.completed` | Payment captured |
| `payment.paid` | Payment moves to paid state |
| `payment.voided` | Payment voided before capture |

### Payment session lifecycle

| Event | When |
|---|---|
| `payment_session.processing` | Session is being processed by the provider |
| `payment_session.completed` | Session completes (returns to your app from payment provider) |
| `payment_session.failed` | Provider returned failure |
| `payment_session.canceled` | Customer canceled |
| `payment_session.expired` | Session timed out |

Payment **setup** sessions (saving a payment method without charging) fire the same set: `payment_setup_session.processing`, `.completed`, `.failed`, `.canceled`, `.expired`.

### Shipment lifecycle

| Event | When |
|---|---|
| `shipment.shipped` | Shipment marked shipped (tracking set) |
| `shipment.canceled` | Shipment canceled |
| `shipment.resumed` | A previously-canceled shipment is resumed |

### Product lifecycle

| Event | When |
|---|---|
| `product.activated` | Product becomes available for sale |
| `product.archived` | Product is archived |
| `product.back_in_stock` | A product moves from out-of-stock to in-stock |
| `product.out_of_stock` | A product becomes out of stock |

### Gift cards

| Event | When |
|---|---|
| `gift_card.redeemed` | Card fully redeemed |
| `gift_card.partially_redeemed` | Card partially redeemed |

### Returns + reimbursements

| Event | When |
|---|---|
| `return_authorization.canceled` | Return authorization canceled |
| `return_item.given` | A return item is given to the customer (exchange) |
| `return_item.received` | A return item is received back from the customer |
| `return_item.canceled` | A return item line is canceled |
| `reimbursement.reimbursed` | Reimbursement processed (refund or store credit issued) |

### Imports

| Event | When |
|---|---|
| `import.completed` | Import job finished |
| `import.progress` | Progress checkpoint during large imports (emitted every 10th completed row group) |
| `import_row.completed` | Single row imported successfully |
| `import_row.failed` | Single row failed |

### Invitations

| Event | When |
|---|---|
| `invitation.created` | Staff/customer invitation sent |
| `invitation.accepted` | Invitee created their account |
| `invitation.resent` | Invitation re-sent |

### Newsletter

| Event | When |
|---|---|
| `newsletter_subscriber.subscription_requested` | Customer requested a subscription (pending double opt-in) |
| `newsletter_subscriber.verified` | Customer confirmed the subscription |

### Customer

| Event | When |
|---|---|
| `customer.password_reset_requested` | Customer requested a password reset email |
| `customer.password_reset` | Customer successfully reset their password |

### Automatic lifecycle events

Models that include `publishes_lifecycle_events` emit `<model_singular>.created`, `<model_singular>.updated`, `<model_singular>.deleted` automatically after the create, update, and destroy transactions commit (the `.deleted` payload is captured before destroy). Examples (5.5):

- `payment.created`, `payment.updated`, `payment.deleted`
- `shipment.created`, `shipment.updated`, `shipment.deleted`
- `variant.created`, `variant.updated`, `variant.deleted`
- `price.created`, `price.updated`, `price.deleted`
- `stock_movement.created`, `stock_movement.updated`, `stock_movement.deleted`
- `report.created`, `gift_card.created`, `refund.created`, `return_authorization.created`, `digital.created`

To make your own model emit lifecycle events:

```ruby
module Spree
  class Brand < Spree.base_class
    publishes_lifecycle_events           # all three
    # or: publishes_lifecycle_events only: [:create, :delete]
  end
end
```

## Event payloads

Every payload includes the **prefixed ID** (`'id' => 'or_…'` for orders, `'py_…'` for payments). Many include additional context:

```ruby
# order.completed payload
{
  'id' => 'or_m3Rp9wXz',
  'notify_customer' => true,   # whether to send the confirmation email
  # ...
}
```

Check the `publish_event(...)` call site in the model emitting the event to see the exact payload. Don't assume.

For **webhook** payloads, the same data is wrapped in the envelope shown above (`{id, name, created_at, data, metadata}`).

## When to use which

| Need | Use |
|---|---|
| Send custom transactional email | Subscriber |
| Sync to your own ERP/warehouse | Subscriber |
| Update internal analytics service | Subscriber |
| Invalidate Rails cache | Subscriber (inline, not async) |
| Notify customer's Zapier workflow | Webhook |
| Trigger n8n / Zapier / Make.com workflows | Webhook |
| Update partner system across the internet | Webhook |
| Notify your own non-Rails service | Webhook (or message bus if scaled) |

## When NOT to use either

- **Business logic that's part of order completion itself** — that goes in services (the cart pipeline, checkout state machine). Events fire after-the-fact.
- **Data validation** — belongs on the model.
- **Things that need to run inside the order's transaction** — events fire post-commit. If it really must be transactional (rare), use a callback.

## Common recipes

### Send custom email on order complete (subscriber)

```ruby
class OrderConfirmationSubscriber < Spree::Subscriber
  subscribes_to 'order.completed'

  def handle(event)
    order = Spree::Order.find_by_prefix_id(event.payload['id'])
    MyOrderMailer.confirmation(order).deliver_later
  end
end
```

### Forward all order events to a partner (webhook)

```bash
curl -X POST https://my-spree.example.com/api/v3/admin/webhook_endpoints \
  -H "X-Spree-Api-Key: sk_…" \
  -d '{"url":"https://partner.example.com/spree","subscriptions":["order.*"]}'
```

### React to payment failure (subscriber)

```ruby
class PaymentFailureSubscriber < Spree::Subscriber
  subscribes_to 'payment_session.failed'

  def handle(event)
    order = Spree::Order.find_by_prefix_id(event.payload['order_id'])
    Slack.notify("Payment failed for #{order.number} (session #{event.payload['id']})")
  end
end
```

### Sync inventory after stock movement (subscriber, async)

```ruby
class InventorySyncSubscriber < Spree::Subscriber
  subscribes_to 'stock_movement.created', async: true

  def handle(event)
    movement = Spree::StockMovement.find_by_prefix_id(event.payload['id'])
    WarehouseApi.update_stock(movement.stock_item.variant)
  end
end
```

## Debugging

### "My subscriber doesn't fire"

1. Registered? `Spree.subscribers.include?(MySubscriber)` should be true.
2. Event name matches? `subscribes_to 'order.completed'` — exact string match.
3. Transaction committed? Subscribers run after commit; if the save raises, they don't fire.
4. Async-only failure? Check `Spree::Events::SubscriberJob` failures in your job backend (queued on `Spree.queues.events`, `:default` by default).

### "My webhook endpoint isn't receiving anything"

1. **Active?** `endpoint.active?` and not `auto_disabled?`.
2. **Subscribed?** `endpoint.subscribed_to?('order.completed')` should be true.
3. **URL reachable?** `endpoint.send_test!` then check `endpoint.webhook_deliveries.last`.
4. **SSRF blocking?** In production, private IPs are rejected. Check `endpoint.errors` if you can't save.
5. **Job backend running?** `WebhookDeliveryJob` is async (ActiveJob). If your worker (e.g. Sidekiq) is down, deliveries pile up in the queue.

### "Signatures don't verify"

Almost always one of:
1. **Verifying against parsed JSON** instead of the raw request body. Re-serialization changes the bytes.
2. **Wrong secret.** Each endpoint has its own; check you're using the right one for the endpoint in question.
3. **Timestamp window too narrow.** Some clocks drift; 5 minutes is reasonable.
4. **String `==` instead of timing-safe compare** — usually still produces the right boolean, but if you're seeing intermittent fails check this.

## Where to read further

- **Subscriber base class:** `Spree::Subscriber` source.
- **Events docs:** `node_modules/@spree/docs/dist/developer/core-concepts/events.md`; **Webhooks docs:** `node_modules/@spree/docs/dist/developer/core-concepts/webhooks.md`; **Per-event payload schemas:** `node_modules/@spree/docs/dist/api-reference/webhooks-events.md`.
- **Webhook source:** `Spree::WebhookEndpoint`, `Spree::WebhookDelivery`, `Spree::Webhooks::DeliverWebhook`, `Spree::WebhookEventSubscriber`.
- **Admin UI:** Settings → Webhooks (manages endpoints, view delivery history with response codes/bodies, replay failed deliveries).
- **For the API surface:** see the `spree-api-v3` skill — webhook endpoints have full CRUD via `/api/v3/admin/webhook_endpoints`.
