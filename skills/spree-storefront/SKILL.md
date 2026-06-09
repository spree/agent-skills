---
name: spree-storefront
description: Use when the user is working on the optional Next.js storefront (the customer-facing online store) — adding a page, customizing checkout, fetching products, integrating with Spree's Store API. Common phrasings include "customize storefront", "Next.js storefront", "frontend changes", "PDP", "product page", "cart", "checkout flow", "@spree/sdk", "publishable key". Provides the storefront architecture, the @spree/sdk integration model, and the storefront-vs-backend decision tree.
---

# Spree Storefront (Next.js)

The Spree storefront is a separate Next.js 16 application that talks to the Spree backend over the v3 Store API. It lives at `apps/storefront/` in projects scaffolded by `create-spree-app --storefront`, and the repo is `github.com/spree/storefront`.

The storefront is **optional**. Headless deployments may use a custom frontend instead — React Native, Astro, Remix, or hand-rolled. Spree's job is to expose a clean API; what consumes it is your choice. This skill assumes the official Next.js storefront, but the API contract is identical for any frontend.

## How it connects to Spree

```
Browser ──HTTPS──> Next.js storefront ──API──> Spree backend (Rails)
                          │
                          └── @spree/sdk for typed API calls
```

The storefront authenticates against the Spree backend via a **publishable API key** (`pk_…` prefix). Customer-bound operations (their cart, their account) use additional auth — JWT for logged-in customers, cart tokens for guest carts.

```bash
# apps/storefront/.env.local
NEXT_PUBLIC_SPREE_API_URL=http://localhost:3000
NEXT_PUBLIC_SPREE_API_KEY=pk_…
```

## @spree/sdk — the canonical client

Don't hand-write fetch calls. Use `@spree/sdk` for typed access to the Store API:

```ts
import { createClient } from '@spree/sdk'

const spree = createClient({
  host: process.env.NEXT_PUBLIC_SPREE_API_URL,
  bearerToken: process.env.NEXT_PUBLIC_SPREE_API_KEY,
})

// List products
const { data, meta } = await spree.products.list({
  include: 'images,default_variant',
  filter: { available: true },
})

// Get a single product by slug or prefixed ID
const product = await spree.products.get('cool-shirt')

// Create a cart
const cart = await spree.carts.create()

// Add item to cart
await spree.carts.items.create(cart.token, {
  variant_id: 'variant_k5nR8xLq',
  quantity: 1,
})
```

The SDK includes:
- Full TypeScript types generated from the Spree serializers (`StoreProduct`, `StoreOrder`, etc.)
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
const { access_token, refresh_token } = await spree.auth.login({
  email: 'jane@example.com',
  password: 'secret',
})

// Subsequent calls
const customerSpree = createClient({
  host: process.env.NEXT_PUBLIC_SPREE_API_URL,
  bearerToken: process.env.NEXT_PUBLIC_SPREE_API_KEY,
  customerToken: access_token,
})

const orders = await customerSpree.account.orders.list()
```

## Channels — which sales surface

If the merchant has multiple channels (website, mobile app, in-store POS), the storefront should identify which one it represents. Set the channel header via the SDK:

```ts
const spree = createClient({
  host: '…',
  bearerToken: pk,
  channel: 'online',         // channel code; or prefixed ID like 'ch_…'
})
```

The Spree backend uses `Spree::Current.channel` to scope queries — only products published on that channel surface in API responses. If `channel` is omitted, the store's default channel is used.

## Common storefront patterns

### Server-rendered PDP

```tsx
// apps/storefront/app/products/[slug]/page.tsx
import { spree } from '@/lib/spree'

export default async function ProductPage({ params }: { params: { slug: string } }) {
  const product = await spree.products.get(params.slug, {
    include: 'default_variant,variants,images,categories',
  })

  return (
    <main>
      <h1>{product.data.name}</h1>
      <img src={product.data.relationships.images.data[0]?.src} alt="" />
      <AddToCartButton variantId={product.data.relationships.default_variant.data.id} />
    </main>
  )
}
```

### Client-side cart

Carts are server-state, so use SWR or React Query. The cart token persists in a cookie or localStorage:

```tsx
'use client'
import useSWR from 'swr'

export function MiniCart({ token }: { token: string }) {
  const { data: cart } = useSWR(['cart', token], () => spree.carts.get(token))
  if (!cart) return null
  return <span>{cart.data.relationships.line_items.data.length} items</span>
}
```

### Checkout

The Store API exposes payment sessions for the checkout flow. Each payment provider has its own session creation endpoint (Stripe, Adyen, PayPal). The pattern:

1. Customer hits checkout — `POST /api/v3/store/carts/:token/payment_sessions` with a payment method choice.
2. Backend returns a session with provider-specific data (Stripe Checkout URL, Adyen drop-in token, etc.).
3. Storefront redirects to the provider OR renders the provider's embedded form.
4. Customer completes — provider posts back to the Spree backend, which fires `payment_session.completed` events.
5. Storefront polls or webhook-listens for completion, then transitions cart → order.

The official `spree_stripe` / `spree_adyen` extensions ship reference checkout flows. Don't roll your own unless you're integrating a new provider.

### Webhook handling

For Next.js storefronts, `@spree/sdk/webhooks` provides typed webhook event handlers with signature verification:

```ts
// apps/storefront/app/api/webhooks/spree/route.ts
import { verifyWebhook } from '@spree/sdk/webhooks'

export async function POST(req: Request) {
  const event = await verifyWebhook(req, {
    secret: process.env.SPREE_WEBHOOK_SECRET!,
  })

  switch (event.type) {
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

The Spree backend ships outbound webhooks in `Spree::WebhookSubscription`. Configure URL + events under Settings → Webhooks in the admin.

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

- **Don't ship secret keys to the browser.** Only publishable keys (`pk_…`) belong in `NEXT_PUBLIC_*` env vars. Secret API keys (`sk_…`) are server-side only.
- **Cart tokens are not credentials** — they identify a cart, not a user. But they grant cart access, so treat them like a session token: HTTPS only, set as an httpOnly cookie when possible.
- **Cache aggressively but invalidate on cart/auth changes.** Product catalog can sit in CDN; cart calls must always hit fresh.
- **Pricing displayed must match what the API will charge.** Don't compute totals client-side. Always pull the cart's `total` from the API after add/remove operations — the backend applies promotions, taxes, shipping rules.
- **i18n is the storefront's job.** The Store API returns translated strings via the `Accept-Language` header. Pass it on every request: `headers: { 'Accept-Language': locale }`.

## Where to read further

- **SDK docs:** `packages/sdk/README.md` in the Spree monorepo or `node_modules/@spree/sdk/README.md` in your storefront project.
- **Store API reference:** `node_modules/@spree/docs/dist/api-reference/store.yaml` — every endpoint, parameter, response schema.
- **Tutorial:** `node_modules/@spree/docs/dist/developer/tutorial/store-api.mdx` and `sdk.mdx` walk through common storefront integrations.
- **Storefront source:** `github.com/spree/storefront` is open source — reference implementations for product listing, cart, checkout, account pages.
