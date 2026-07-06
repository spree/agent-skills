---
name: spree-storefront
description: Use when the user is working on the optional Next.js storefront (the customer-facing online store) — adding a page, customizing checkout, fetching products, integrating with Spree's Store API. Common phrasings include "customize storefront", "Next.js storefront", "frontend changes", "PDP", "product page", "cart", "checkout flow", "@spree/sdk", "publishable key". Provides the storefront architecture, the @spree/sdk integration model, and the storefront-vs-backend decision tree.
---

# Spree Storefront (Next.js)

The Spree Next.js storefront is a separate application that talks to the Spree backend over the v3 Store API. It lives at `github.com/spree/storefront`; `create-spree-app` clones it into `apps/storefront/` for you, or fork it directly for deeper customization.

The storefront is **optional**. Headless deployments may use a custom frontend — React Native, Astro, Remix, or hand-rolled. Spree's job is to expose a clean API; what consumes it is your choice. This skill assumes the official Next.js storefront, but the API contract is identical for any frontend.

## How it connects to Spree

```
Browser ──HTTPS──> Next.js storefront ──API──> Spree backend (Rails)
                          │
                          └── @spree/sdk for typed API calls
```

The storefront authenticates against the Spree backend via a **publishable API key** (`pk_…` prefix). Customer-bound operations (their cart, their account) use additional auth — JWT for logged-in customers, cart tokens for guest carts.

```bash
# .env.local — server-side only (the storefront makes all API calls via Server Actions)
SPREE_API_URL=http://localhost:3000
SPREE_PUBLISHABLE_KEY=pk_…
```

## @spree/sdk — the canonical client

Don't hand-write fetch calls. Use `@spree/sdk` for typed access to the Store API:

```ts
import { createClient } from '@spree/sdk'

const spree = createClient({
  baseUrl: process.env.SPREE_API_URL!,
  publishableKey: process.env.SPREE_PUBLISHABLE_KEY!,
})

// List products
const { data, meta } = await spree.products.list({
  expand: ['media', 'default_variant'],
})

// Get a single product by slug or prefixed ID
const product = await spree.products.get('cool-shirt')

// Create a cart
const cart = await spree.carts.create()

// Add item to cart — cart ID positional, token via options.spreeToken
await spree.carts.items.create(cart.id, {
  variant_id: 'variant_k5nR8xLq',
  quantity: 1,
}, { spreeToken: cart.token })
```

The SDK includes:
- Full TypeScript types generated from the Spree serializers (`Product`, `Order`, `Cart`, etc.)
- Runtime Zod schemas in `@spree/sdk/zod` if you want validation
- Automatic retry with exponential backoff
- Ransack query param transformation
- Webhook signature verification in `@spree/sdk/webhooks`

## Authentication modes

| Who | How | Use for |
|---|---|---|
| Anonymous browser | Publishable key | Browsing products, viewing categories |
| Guest cart | Publishable key + cart token | Cart operations for not-yet-signed-up customers |
| Logged-in customer | Publishable key + JWT (customer login) | Order history, saved addresses, account pages |

The customer login flow:

```ts
const { token, refresh_token, user } = await spree.auth.login({
  email: 'jane@example.com',
  password: 'secret',
})

// Pass the JWT per request via options.token
const orders = await spree.customer.orders.list({}, { token })
const me = await spree.customer.get({ token })

// Refresh later
const { token: newToken } = await spree.auth.refresh({ refresh_token })
```

## Channels — which sales surface

If the merchant has multiple channels (website, mobile app, in-store POS), the storefront should identify which one it represents. Set the channel via the SDK config:

```ts
const spree = createClient({
  baseUrl: process.env.SPREE_API_URL!,
  publishableKey: process.env.SPREE_PUBLISHABLE_KEY!,
  channel: 'online',         // channel code; or prefixed ID like 'ch_…'
})
```

The Spree backend uses `Spree::Current.channel` to scope queries — only products published on that channel surface in API responses. If `channel` is omitted, the store's default channel is used.

## Common storefront patterns

### Server-rendered PDP

```tsx
// app/products/[slug]/page.tsx
import { spree } from '@/lib/spree'

export default async function ProductPage({ params }: { params: { slug: string } }) {
  const product = await spree.products.get(params.slug, {
    expand: ['default_variant', 'variants', 'media', 'categories'],
  })

  return (
    <main>
      <h1>{product.name}</h1>
      <img src={product.media?.[0]?.large_url ?? undefined} alt={product.media?.[0]?.alt ?? ''} />
      <AddToCartButton variantId={product.default_variant_id} />
    </main>
  )
}
```

The v3 Store API uses **flat responses** — `product.name`, not `product.data.attributes.name`. Related records appear as either ID fields (e.g. `default_variant_id`) or, when expanded, as nested objects (e.g. `product.default_variant`, `product.media[]`).

### Client-side cart

Carts are server-state, so use SWR or React Query. The cart ID + token persist in a cookie:

```tsx
'use client'
import useSWR from 'swr'

export function MiniCart({ cartId, token }: { cartId: string; token: string }) {
  const { data: cart } = useSWR(
    ['cart', cartId],
    () => spree.carts.get(cartId, { spreeToken: token })
  )
  if (!cart) return null
  return <span>{cart.items.length} items</span>
}
```

### Checkout

The Store API exposes payment sessions for the checkout flow — a single, provider-agnostic endpoint that works with any session-based gateway (Stripe, Adyen, PayPal); the provider is selected via `payment_method_id`. The pattern:

1. Customer hits checkout — `POST /api/v3/store/carts/:cart_id/payment_sessions` with a payment method choice (cart token in `X-Spree-Token` header).
2. Backend returns a session with provider-specific data (Stripe Checkout URL, Adyen drop-in token, etc.).
3. Storefront redirects to the provider OR renders the provider's embedded form.
4. Customer completes — provider posts back to the Spree backend, which fires `payment_session.completed` events.
5. Storefront calls `spree.carts.paymentSessions.complete(cartId, sessionId, { session_result: 'success' }, options)` once the customer confirms, then `spree.carts.complete(cartId, options)` to get the Order — or relies on the provider webhook, in which case the backend completes the cart → order transition automatically.

The `spree_stripe` / `spree_adyen` / `spree_paypal_checkout` gems ship reference checkout flows. Don't roll your own unless you're integrating a new provider.

### Webhook handling

For Next.js storefronts, `@spree/sdk/webhooks` provides HMAC signature verification with typed event payloads:

```ts
// app/api/webhooks/spree/route.ts
import { verifyWebhookSignature, type WebhookEvent } from '@spree/sdk/webhooks'

export async function POST(req: Request) {
  const body = await req.text()
  const signature = req.headers.get('x-spree-webhook-signature') ?? ''
  const timestamp = req.headers.get('x-spree-webhook-timestamp') ?? ''

  if (!verifyWebhookSignature(body, signature, timestamp, process.env.SPREE_WEBHOOK_SECRET!)) {
    return new Response('Invalid signature', { status: 401 })
  }

  const event: WebhookEvent = JSON.parse(body)
  switch (event.name) {
    case 'order.completed':
      await sendCustomThankYouEmail(event.data)
      break
    case 'order.shipped':
      await pushShippingNotification(event.data)
      break
  }

  return Response.json({ received: true })
}
```

The Spree backend ships outbound webhooks as `Spree::WebhookEndpoint` records. Configure URL + events under Settings → Webhooks in the admin.

## Storefront vs backend — where does the change belong

| Want to... | Belongs in |
|---|---|
| Change how a product is displayed (layout, colors, copy) | Storefront |
| Add a new field to product responses | Backend (model + serializer) |
| Add a custom page like /about, /shipping | Storefront |
| Change pricing logic | Backend (service swap or extension) |
| Add a country to checkout | Backend (Markets / Country config) |
| Customize the checkout UI flow | Storefront |
| Add an A/B test to the PDP | Storefront |
| Sync orders to a CRM | Backend (subscriber) |
| Custom analytics events | Storefront (client-side tracking) OR backend (subscriber) — depends on what triggers them |
| Customize the cart total calculation | Backend (service swap on `Spree.cart_recalculate_service`) |
| Send a custom transactional email | Backend (subscriber + ActionMailer) |

The rule: **anything customer-visible is the storefront. Anything that touches data, money, or business logic is the backend.** When in doubt, backend — keeping logic centralized makes it consistent across all frontends if you ever ship a second one.

## Common gotchas

- **Don't ship secret keys to the browser.** Secret API keys (`sk_…`) never belong in `NEXT_PUBLIC_*` env vars. In the official storefront even the Spree publishable key stays server-side (`SPREE_PUBLISHABLE_KEY`, no `NEXT_PUBLIC_` prefix) since all API calls run in Server Actions — `NEXT_PUBLIC_*` is only for third-party client SDK keys (Stripe/PayPal publishable keys).
- **Cart tokens are not credentials** — they identify a cart, not a user. But they grant cart access, so treat them like a session token: HTTPS only, set as an httpOnly cookie when possible.
- **Cache aggressively but invalidate on cart/auth changes.** Product catalog can sit in CDN; cart calls must always hit fresh.
- **Pricing displayed must match what the API will charge.** Don't compute totals client-side. Always pull the cart's `total` from the API after add/remove operations — the backend applies promotions, taxes, shipping rules.
- **i18n is the storefront's job.** The Store API returns translated strings based on the `x-spree-locale` header (or a `locale` query param) — not `Accept-Language`. Set it via the SDK: `createClient({ ..., locale })` for a default, or pass `{ locale }` in per-request options; the SDK sends it as `x-spree-locale`.

## Where to read further

- **SDK docs:** `node_modules/@spree/docs/dist/developer/sdk/quickstart.md` (also at https://spreecommerce.org/docs/developer/sdk/quickstart)
- **Storefront docs:** `node_modules/@spree/docs/dist/developer/storefront/nextjs/architecture.md`, `customization.md`, `deployment.md`
- **Storefront tutorial:** `node_modules/@spree/docs/dist/developer/tutorial/api.md`, `sdk.md`
- **Storefront source:** https://github.com/spree/storefront — reference implementations for product listing, cart, checkout, account pages
