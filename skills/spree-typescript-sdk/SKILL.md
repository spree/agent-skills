---
name: spree-typescript-sdk
description: Use when the user is building a TypeScript or JavaScript client against Spree — a Next.js storefront, a custom admin tool, a webhook receiver, a backend service that talks to the Spree API. Covers @spree/sdk (Store API) and @spree/admin-sdk (Admin API). Common phrasings include "Spree SDK", "createClient", "publishable key", "store client", "admin client", "TypeScript types from Spree", "Zod schemas", "verifyWebhookSignature", "retry config", "MSW Spree", "@spree/sdk", "@spree/admin-sdk". For curl/raw HTTP usage and protocol details, see spree-api-v3.
---

# Spree TypeScript SDKs

Two npm packages, one shared HTTP core:

| Package | Surface | Auth | Status |
|---|---|---|---|
| `@spree/sdk` | Store API (`/api/v3/store/*`) | Publishable key + optional JWT customer | Stable (1.x) |
| `@spree/admin-sdk` | Admin API (`/api/v3/admin/*`) | Secret key OR JWT admin | Developer Preview (`next` dist-tag) |
| `@spree/sdk-core` | Shared HTTP, retry, error layer | n/a | Internal (not for direct use) |

Both packages publish:
- `dist/index.js` — flat client (`createClient` / `createAdminClient`)
- `dist/types/` — generated TypeScript types from Alba serializers
- `@spree/sdk` also publishes `dist/zod/` — runtime validation schemas + `dist/webhooks.js` — signature verifier

## @spree/sdk — Store API client

### Install

```bash
npm install @spree/sdk
```

### Quickstart

```ts
import { createClient } from '@spree/sdk'

const client = createClient({
  baseUrl: 'https://my-spree.example.com',
  publishableKey: 'pk_CzEKBTWFiuNLgz4wciLsS59n',
  // optional defaults
  locale: 'en-US',
  currency: 'USD',
  country: 'US',
  channel: 'online',
})

// All resources hang flat off the client
const { data: products, meta } = await client.products.list({ limit: 20 })
const product = await client.products.get('prod_86Rf07xd4z')
const cart = await client.carts.create()
await client.carts.items.create(cart.id, { variant_id: 'variant_…', quantity: 1 }, {
  spreeToken: cart.token,
})
```

### Resource shape

Resources follow one method vocabulary:

```ts
client.<resource>.list(params?, options?)              // GET   index
client.<resource>.get(idOrSlug, params?, options?)     // GET   show
client.<resource>.create(body, options?)               // POST  create
client.<resource>.update(id, body, options?)           // PATCH update
client.<resource>.delete(id, options?)                 // DELETE
```

Full five-method CRUD is an **Admin SDK** property. On the **Store SDK** most resources are read-only or partial — `products` exposes only `list`/`get`/`filters`; `categories`, `countries`, `orders`, `policies`, `markets`, `currencies`, `locales` are read-only; `customers` exposes only `create`. Store writes are limited to carts, wishlists, and the customer's own account/addresses; catalog writes require the Admin SDK. If a method doesn't typecheck, it doesn't exist on that surface — don't force it.

Method name is always `get`, never `show`. The delete method is `delete`, not `destroy`. Nested resources (e.g. `client.carts.items.create(cartId, params, options)`) take the parent prefixed ID as the first positional argument.

### Customer auth (JWT)

After login, attach the JWT per request via `options.token`. There is no `setAccessToken` — the SDK doesn't hold customer tokens in client state.

```ts
const { token, refresh_token, user } = await client.auth.login({ email, password })

// Subsequent calls pass the token via options
const orders = await client.customer.orders.list({}, { token })
```

The login response's `token` field is the customer JWT. Store and pass per-request — server-rendered apps can stash it in a session cookie; client-side apps store it in memory and refresh via `client.auth.refresh({ refresh_token })`.

### Setting defaults dynamically

```ts
client.setLocale('fr')
client.setCurrency('EUR')
client.setCountry('FR')
client.setChannel('wholesale')
```

Each setter mutates the in-memory defaults. The next request uses the new values; concurrent in-flight requests use whatever was set when their headers were built.

### List params (Ransack)

```ts
await client.products.list({
  page: 2,
  limit: 50,
  name_cont: 'shirt',
  price_gte: 20,
  price_lte: 100,
  sort: '-created_at',
  expand: ['images', 'default_variant'],
})
```

List params are flat. Internally any key that is not `page`/`limit`/`expand`/`sort`/`fields` becomes a Ransack predicate via `transformListParams` in `@spree/sdk-core`: `name_cont: 'shirt'` → `q[name_cont]=shirt` (array values get a `[]` suffix: `q[with_option_value_ids][]`). The `expand` array becomes `?expand=images,default_variant`. Do not nest predicates under a `filter` key — there is no such param; a nested object would serialize as `q[filter]=[object Object]`.

### Error handling

```ts
import { SpreeError } from '@spree/sdk'

try {
  await client.carts.items.create(cartId, { variant_id, quantity: 1 }, { spreeToken })
} catch (err) {
  if (err instanceof SpreeError) {
    err.status       // 422
    err.code         // 'validation_error'
    err.message      // human message
    err.details      // { variant_id: ["is out of stock"], ... }
  }
  throw err
}
```

For 422 in form contexts, `err.details` keys are attribute names, so they map directly onto form-library error setters (e.g. React Hook Form's `setError`); `base` errors are non-field-specific — render them as a form-level banner.

### Retry config

```ts
const client = createClient({
  baseUrl, publishableKey,
  retry: { maxRetries: 3, baseDelay: 200, retryOnStatus: [429, 502, 503, 504] },
})

// Or disable entirely
const client = createClient({ baseUrl, publishableKey, retry: false })
```

Defaults: 2 retries, exponential backoff with jitter (300ms base, capped at 10s), retries on 429/500/502/503/504 + network errors. Honors `Retry-After` headers. The 5xx statuses only retry for idempotent requests — GET/HEAD, or any request carrying an `Idempotency-Key`; since mutating requests get an auto-generated `Idempotency-Key` when retries are on, they're covered too. Non-keyed mutations retry on 429 only.

### Custom fetch (testing, server-only, etc.)

```ts
const client = createClient({
  baseUrl, publishableKey,
  fetch: customFetch,   // any fetch-compatible function
})
```

Use this for:
- Server-only fetch (Next.js server components: `fetch` from `next/cache`)
- Mocking in tests (pass MSW's `fetch` or a stub)
- Adding tracing headers (wrap `fetch` with an OpenTelemetry instrument)

### Generated types

```ts
import type { Product, Order, Cart } from '@spree/sdk/types'

function renderProduct(product: Product) { ... }
```

Types are generated from Alba serializers via `bundle exec rake typelizer:generate` and published with each release. They always match the API exactly (no drift).

### Zod schemas (runtime validation)

```ts
import { ProductSchema } from '@spree/sdk/zod'

const product = ProductSchema.parse(unsafeData)   // throws if shape doesn't match
const parsed = ProductSchema.safeParse(unsafeData)
if (parsed.success) { ... }
```

Use when consuming API responses you don't fully trust (cached payloads, webhook bodies, third-party proxies). Generated from the TypeScript types via `pnpm generate:zod`.

### Webhook signature verification

```ts
import { verifyWebhookSignature } from '@spree/sdk/webhooks'

// In your webhook receiver (Next.js API route, Express handler, etc.)
const rawBody = await request.text()          // MUST be the raw bytes, not parsed JSON
const signature = request.headers.get('x-spree-webhook-signature')!
const timestamp = request.headers.get('x-spree-webhook-timestamp')!

const isValid = verifyWebhookSignature(
  rawBody,
  signature,
  timestamp,
  process.env.SPREE_WEBHOOK_SECRET!,
  300,   // tolerance in seconds (default 300 = 5 min)
)

if (!isValid) return new Response('Unauthorized', { status: 401 })

const event = JSON.parse(rawBody)   // safe to parse now
```

This is a Node-only export (uses `node:crypto`). For Edge runtimes, use Web Crypto manually — see `spree-events-webhooks` skill.

### Typed webhook event payloads

```ts
import type { WebhookEvent } from '@spree/sdk/webhooks'
import type { Order } from '@spree/sdk'

const event = JSON.parse(rawBody) as WebhookEvent<Order>

if (event.name === 'order.completed') {
  event.data.id      // 'or_…'
  event.data.total   // typed against Order
}
```

## @spree/admin-sdk — Admin API client

### Install

```bash
npm install @spree/admin-sdk@next
```

The Admin SDK is in Developer Preview and published under the `next` dist-tag — a plain `npm install @spree/admin-sdk` resolves `latest` and will not get the preview release.

### Two auth modes

**Mode 1: secret key (server-to-server apps)**

```ts
import { createAdminClient } from '@spree/admin-sdk'

const admin = createAdminClient({
  baseUrl: 'https://my-spree.example.com',
  secretKey: process.env.SPREE_ADMIN_SECRET_KEY!,   // sk_…
  storeId: 'store_k5nR8xLq',                         // optional multi-store routing
})

const { data: orders } = await admin.orders.list({ status_eq: 'placed' })   // status (5.5) not state — state is removed in Spree 6
```

The secret key carries scopes (`read_orders`, `write_products`, etc.) — see `spree-api-v3` for the scope list. Requests for endpoints outside the key's scopes get 403.

**Mode 2: JWT (human admin users)**

```ts
const admin = createAdminClient({
  baseUrl,
  jwtToken: jwtFromLogin,    // identifies the admin user; mutually exclusive with secretKey
  storeId: currentStoreId,
})
```

JWT mode uses CanCanCan abilities on the backend. What the user can do depends on their role. The Admin SDK defaults to `credentials: 'include'` so the admin refresh-token cookie is sent on `/api/v3/admin/auth/*` endpoints.

Unlike the Store SDK, the admin client holds its JWT in client state: call `admin.setToken(newJwt)` after a refresh, `admin.setStore(storeId)` to switch stores (sets the `X-Spree-Store-Id` header), and `admin.onUnauthorized(async () => { /* refresh token, call admin.setToken(...) */ return true })` to transparently retry a 401'd request once with the new token (paths under `/auth/` are excluded from retry; return `false` to let the 401 propagate).

### Resource shape

Same five-method shape as the Store SDK, full CRUD enabled by default for every resource:

```ts
admin.products.list()
admin.products.get('prod_…')
admin.products.create({ name, description, ... })
admin.products.update('prod_…', { name: 'Renamed' })
admin.products.delete('prod_…')
```

### Singletons use `get`, not `show`

```ts
admin.me.get()           // current authenticated admin
admin.store.get()        // current store config
```

(Never `show` — the convention is uniform.)

### Exports endpoint

For example, a CSV export flow:

```ts
const exportRecord = await admin.exports.create({
  type: 'Spree::Exports::Orders',
  search_params: { status_eq: 'placed' },
})
// poll admin.exports.get(exportRecord.id) until done === true, then fetch
// download_url with Authorization: Bearer <jwt> and create a Blob —
// there is no .download() method
```

Always stream bytes (`send_data` backend / `Blob` frontend); never `redirect_to attachment.url` + `window.location.href`. JWT downloads must use fetch + Blob so the Authorization header is sent.

## @spree/sdk-core — shared layer (internal)

Private package providing:
- `createRequestFn(config, basePath, auth, defaults)` — the HTTP function used by both clients
- `SpreeError` class
- `resolveRetryConfig` + exponential backoff
- `transformListParams` (Ransack predicate transform)

Don't import directly. The public `@spree/sdk` and `@spree/admin-sdk` re-export everything you need.

## Extending the SDK — custom endpoints, custom resources

Spree is a self-hosted open-source platform. Most real projects add custom API endpoints (vendor models, B2B quote flows, loyalty programs, integrations specific to the merchant's business). The SDK is built to wrap these the same way it wraps the built-in resources — you're not stuck with what ships in the box.

There are three escape hatches, in order of increasing investment:

### 1. One-off custom calls — `client.request`

Both `Client` and `AdminClient` expose a low-level `request<T>(method, path, options?)` that uses the same auth, retry, and base URL as the built-in resources. Paths are **relative** to `/api/v3/store` (Store SDK) or `/api/v3/admin` (Admin SDK).

```ts
// Store SDK — calling a custom endpoint you added to your Spree backend
type Brand = { id: string; name: string; slug: string }
type ListResponse<T> = { data: T[]; meta: { page: number; pages: number; count: number } }

const { data: brands } = await client.request<ListResponse<Brand>>('GET', '/brands', {
  params: { 'q[name_cont]': 'acme', page: 1, limit: 25 },
})

const brand = await client.request<Brand>('GET', `/brands/${id}`)
const created = await client.request<Brand>('POST', '/brands', { body: { name: 'New brand' } })
```

```ts
// Admin SDK
const vendor = await admin.request<Vendor>('POST', '/vendors', {
  body: { name, contact_email, commission_rate: 0.15 },
})
```

`request` is what every built-in resource is built on top of — there's no "private" version. Reach for it whenever:
- You shipped a custom endpoint via the `spree:api_resource` generator (see `spree-resource` skill) and want to call it from TypeScript without writing a wrapper class.
- You need to call an endpoint added by a third-party Spree extension.
- You're prototyping and the wrapper isn't worth it yet.

### 2. Wrapped custom resource — for code you reuse

Once you're calling a custom endpoint from more than one place, wrap it. The convention matches what ships in the SDK: a class that takes the `request` function in its constructor and exposes the five-method shape.

```ts
// src/spree-extensions/brands-client.ts
import type { RequestFn, ListResponse } from '@spree/sdk'

export interface Brand {
  id: string
  name: string
  slug: string
  description: string | null
}

export interface BrandListParams {
  page?: number
  limit?: number
  name_cont?: string
  slug_eq?: string
}

export class BrandsClient {
  constructor(private readonly request: RequestFn) {}

  list(params: BrandListParams = {}) {
    // request() is raw — it does not apply transformListParams, so wrap
    // Ransack predicates in q[...] yourself
    const { page, limit, ...predicates } = params
    const q = Object.fromEntries(Object.entries(predicates).map(([k, v]) => [`q[${k}]`, v]))
    return this.request<ListResponse<Brand>>('GET', '/brands', {
      params: { page, limit, ...q },
    })
  }
  get(id: string) {
    return this.request<Brand>('GET', `/brands/${id}`)
  }
  create(body: Partial<Brand>) {
    return this.request<Brand>('POST', '/brands', { body })
  }
  update(id: string, body: Partial<Brand>) {
    return this.request<Brand>('PATCH', `/brands/${id}`, { body })
  }
  delete(id: string) {
    return this.request<void>('DELETE', `/brands/${id}`)
  }
}
```

### 3. Extending the client itself

Attach the wrapper to the client so consumer code reads the same as built-in resources (`spree.brands.list()` not `new BrandsClient(spree.request).list()`):

```ts
// src/spree-extensions/index.ts
import { createClient, type Client, type ClientConfig } from '@spree/sdk'
import { BrandsClient } from './brands-client'
import { VendorsClient } from './vendors-client'

export interface ExtendedClient extends Client {
  brands: BrandsClient
  vendors: VendorsClient
}

export function createExtendedClient(config: ClientConfig): ExtendedClient {
  const client = createClient(config) as ExtendedClient
  client.brands = new BrandsClient(client.request)
  client.vendors = new VendorsClient(client.request)
  return client
}
```

```ts
// Application code
import { createExtendedClient } from '@/spree-extensions'

const spree = createExtendedClient({ baseUrl, publishableKey })
const { data: brands } = await spree.brands.list({ name_cont: 'acme' })
```

Same trick for `@spree/admin-sdk`: import `createAdminClient` + `AdminClient`, extend the interface, attach wrappers in your factory.

### Decorating a built-in resource

If a third-party extension adds endpoints under an existing resource (e.g. `/products/:id/republish` for a syndication extension), decorate the existing resource instead of replacing it. **Don't spread the client itself** — `createClient` returns an object whose resources live on its prototype, so `{ ...base }` would copy only the locale/currency setters and drop `carts`, `request`, and every other resource. Attach the decorated resource onto the client instead:

```ts
import { createClient } from '@spree/sdk'

const base = createClient({ baseUrl, publishableKey })

export const spree = Object.assign(base, {
  products: {
    ...base.products,
    republish(id: string) {
      return base.request<void>('POST', `/products/${id}/republish`)
    },
  },
})
```

Capturing `Object.assign`'s return value gives `spree` the intersection type, so `spree.products.republish(...)` typechecks alongside the built-in `spree.products.list()`. Spreading `base.products` is safe — resource methods are own properties with lexically bound `this`, so they keep working after the copy.

### Type generation for custom resources

If your custom endpoint uses Alba serializers (which it does if you generated it with `spree:api_resource`), you can plug into the same Typelizer pipeline that produces the official SDK types:

```bash
cd spree/api && bundle exec rake typelizer:generate
```

The output goes to `packages/sdk/src/types/generated/` if you're in the monorepo, but in a standalone consumer project you'd configure Typelizer's output path to your project's `types/spree-extensions/` directory. Re-run after serializer changes; check the generated `.d.ts` into version control.

For Zod schemas to match, copy the same `pnpm generate:zod` pattern — it's a small custom script (`packages/sdk/scripts/generate-zod.ts`) that converts the generated TS interfaces to Zod schemas; point its input/output dirs at your generated types directory.

If you're not running the monorepo, just hand-write the TypeScript interfaces. The serializer is the source of truth either way — match attribute names + types and you're done.

### What you should NOT do

- **Don't fork `@spree/sdk`.** When the package updates, you're stuck merging. Extend, don't fork.
- **Don't depend on `@spree/sdk-core`** — it's a private workspace package, never published to npm. Everything you need is re-exported from the public packages: `@spree/sdk` exports `RequestFn`, `ListResponse`, `RequestOptions`, and `SpreeError`; `@spree/admin-sdk` exports `ListResponse`, `RequestOptions`, and `SpreeError` (no `RequestFn` — type admin wrapper constructors with `AdminClient['request']`). The HTTP and retry internals can change between minor releases.
- **Don't bypass the SDK by calling `fetch` directly** in app code. You lose retry, error normalization, default headers (locale/currency/channel), and auth. If the SDK doesn't cover what you need, use `client.request` — it's the same fetch with all the goodies still applied.

## Testing with MSW

Both SDKs work great with [Mock Service Worker](https://mswjs.io). The SDK doesn't intercept fetch — it just calls fetch — so MSW handlers see the requests and respond with whatever you want.

```ts
// tests/setup.ts
import { setupServer } from 'msw/node'
import { http, HttpResponse } from 'msw'

export const server = setupServer(
  http.get('https://test.spree.local/api/v3/store/products', () => {
    return HttpResponse.json({
      data: [{ id: 'prod_test1', name: 'Test product' }],
      meta: { page: 1, count: 1, pages: 1, limit: 25 },
    })
  }),
)

beforeAll(() => server.listen())
afterEach(() => server.resetHandlers())
afterAll(() => server.close())

// tests/products.test.ts
import { createClient } from '@spree/sdk'

test('lists products', async () => {
  const client = createClient({
    baseUrl: 'https://test.spree.local',
    publishableKey: 'pk_test',
  })
  const { data } = await client.products.list()
  expect(data).toHaveLength(1)
})
```

## Type regeneration pipeline

After backend serializer changes, the types and Zod schemas need to be regenerated:

```bash
# 1. TS types from Alba serializers
cd spree/api && bundle exec rake typelizer:generate

# 2. Zod schemas from TS types
cd packages/sdk && pnpm generate:zod

# 3. (Optional) Re-run SDK tests
cd packages/sdk && pnpm test
```

In the monorepo, a Lefthook pre-commit hook runs steps 1–2 automatically whenever `spree/api/app/serializers/**/*.rb` files are committed.

If you're a SDK consumer (not the maintainer), you don't run this — just `npm update @spree/sdk` to get the latest types.

## Common patterns

### Next.js App Router server component

```ts
// app/products/page.tsx
import { createClient } from '@spree/sdk'

const spree = createClient({
  baseUrl: process.env.SPREE_API_URL!,
  publishableKey: process.env.SPREE_PUBLISHABLE_KEY!,
  fetch,   // Next's fetch — gets caching/revalidation for free
})

export default async function ProductsPage() {
  const { data: products } = await spree.products.list({ limit: 24 })
  return <ProductGrid products={products} />
}
```

### Webhook receiver (Next.js API route)

```ts
// app/api/webhooks/spree/route.ts
import { verifyWebhookSignature, type WebhookEvent } from '@spree/sdk/webhooks'
import type { Order } from '@spree/sdk/types'

export async function POST(request: Request) {
  const rawBody = await request.text()
  const signature = request.headers.get('x-spree-webhook-signature') ?? ''
  const timestamp = request.headers.get('x-spree-webhook-timestamp') ?? ''

  if (!verifyWebhookSignature(rawBody, signature, timestamp, process.env.SPREE_WEBHOOK_SECRET!)) {
    return new Response('Unauthorized', { status: 401 })
  }

  const event = JSON.parse(rawBody) as WebhookEvent<Order>
  switch (event.name) {
    case 'order.completed':
      await syncToERP(event.data)
      break
  }
  return Response.json({ ok: true })
}
```

### React Query integration

```ts
import { useQuery, useMutation } from '@tanstack/react-query'
import { spree } from '@/lib/spree-client'

function useProducts(filters: ProductFilters) {
  return useQuery({
    queryKey: ['products', filters],
    queryFn: () => spree.products.list(filters),
  })
}

function useCreateCart() {
  return useMutation({
    mutationFn: () => spree.carts.create(),
  })
}
```


## Common pitfalls

### "Why is `currency` not sticking?"

`setCurrency` mutates an in-memory default. If you have multiple clients (server-rendered + client-side rehydrated), each has its own defaults. Either set on both or pass per-request via `client.products.list({ currency: 'EUR' })`.

### "Signature verification fails on Next.js Edge"

`@spree/sdk/webhooks` uses `node:crypto` (Node only). For Edge runtimes, write the HMAC verify by hand against Web Crypto's `subtle.importKey` + `subtle.sign`. See `spree-events-webhooks` for the algorithm.

### "Types changed, my code broke"

`@spree/sdk` follows semver. **Minor versions** can add fields (your code keeps working). **Major versions** can break (read the changelog before bumping). Pin to a specific minor if you want zero surprise.

### "Where's the OpenAPI?"

`node_modules/@spree/docs/dist/api-reference/store.yaml` (Store) — generated from the Rails integration specs via Rswag. Authoritative reference for everything the SDK exposes.

## Where to read further

- **Store SDK source:** `packages/sdk/src/store-client.ts` — every resource and its methods.
- **Admin SDK source:** `packages/admin-sdk/src/admin-client.ts`.
- **API protocol details:** see the `spree-api-v3` skill — auth, prefixed IDs, pagination, envelope.
- **Webhooks delivery side:** see the `spree-events-webhooks` skill — endpoint config, retry logic, payload shape.
