---
name: spree-typescript-sdk
description: Use when the user is building a TypeScript or JavaScript client against Spree 6 — a Next.js storefront, a mobile/web app, an integration or back-office tool, a webhook receiver — or shipping a typed client for an extension's endpoints. Covers @spree/sdk (Store API), @spree/admin-sdk (Admin API) and points to @spree/seller-sdk (marketplace); custom endpoints via `client.request`, SDK extensions (`define{Store,Admin,Seller}Extension` + `client.extend()`), and `spree sdk generate`. Common phrasings include "Spree SDK", "createClient", "createAdminClient", "cart token / spreeToken", "carts.complete", "orders.get after checkout", "TypeScript types from Spree", "Zod schemas", "verifyWebhookSignature", "retry config", "client.request custom endpoint", "client.extend", "typed client for my extension", "spree sdk generate", "MSW Spree". For curl/raw HTTP and protocol details, see spree-api-v3.
---

# Spree TypeScript SDKs

| Package | Surface | Auth |
|---|---|---|
| `@spree/sdk` | Store API (`/api/v3/store`) | Publishable key + optional customer JWT / guest token |
| `@spree/admin-sdk` | Admin API (`/api/v3/admin`) | Secret key **or** staff JWT |
| `@spree/seller-sdk` | Seller API (`/api/v3/seller`) | Seller JWT + seller ID (`createSellerClient`, `setSeller`). Singletons use `get`/`update` like the admin SDK (`seller.me.get()`, `seller.me.update({ selected_locale })`, `seller.profile.update(…)`). See `spree-marketplace` |
| `@spree/sdk-core` | Shared HTTP, retry, errors, extensions | Internal, never published. Don't import it |

The three SDKs version in lockstep with the Spree gems (6.0.3 alongside gems 6.0.3), so pin the SDK to your server's minor. `@spree/cli` versions on its own track (3.6.x for 6.0.3). All three expose the same shape and share `SpreeError`, retry, idempotency, a `request` escape hatch and `extend()`.

`@spree/sdk` also ships three subpaths: `@spree/sdk/types` (generated types), `@spree/sdk/zod` (Zod schemas) and `@spree/sdk/webhooks` (signature verification, Node only). The Admin and Seller SDKs have matching `/types` and `/zod` subpaths. Schemas are named `<Type>Schema` and generated from the API serializers. `zod` (>= 3) is an optional peer dependency, so install it yourself to validate responses at runtime:

```typescript
import { OrderSchema } from '@spree/admin-sdk/zod'

const order = OrderSchema.parse(await adminClient.orders.get('or_xxx'))  // throws on a shape mismatch
```

## @spree/sdk — Store API

```ts
import { createClient } from '@spree/sdk'

const client = createClient({
  baseUrl: 'https://shop.example.com',
  publishableKey: 'pk_xxx',
  // optional defaults, sent as X-Spree-* headers
  country: 'DE', locale: 'de', currency: 'EUR', channel: 'online',
})

const { data: products, meta } = await client.products.list({ name_cont: 'shirt', limit: 24, expand: ['default_variant'] })
const product = await client.products.get('classic-tee')         // id or slug
```

Setters change the defaults for later requests: `client.setLocale('fr')`, `setCurrency`, `setCountry`, `setChannel`. Each client instance keeps its own defaults, so a server-rendered client and a browser client have to be set separately.

### Method vocabulary

`list(params?, options?)`, `get(idOrSlug, params?, options?)`, `create(body, options?)`, `update(id, body, options?)`, `delete(id, options?)`. The method is always `get` (never `show`) and `delete` (never `destroy`). Nested resources take the parent ID first: `client.carts.items.create(cartId, body, options)`.

The Store SDK only exposes what the Store API allows. If a method doesn't typecheck, it doesn't exist on that surface.

| Resource | What you get |
|---|---|
| `products`, `categories`, `collections` (+ `collections.products.list`), `sellers` | Catalog reads (`products.filters` for facets) |
| `markets`, `countries`, `currencies`, `locales`, `channel`, `policies`, `deliveryMethods` | Context and reference data |
| `carts` (+ `items`, `discountCodes`, `giftCards`, `fulfillments`, `payments`, `paymentSessions`, `storeCredits`), `carts.associate`, `carts.complete` | Cart and checkout |
| `orders.get` (+ `returns`, `claims`) | Completed orders |
| `auth`, `customers.create`, `passwordResets`, `customer.*` (profile, addresses, creditCards, giftCards, storeCredits, digitalLinks, orders, paymentSetupSessions) | Accounts |
| `wishlists` (+ `items`) | Wishlists |
| `newsletterSubscribers` (`create`, `verify`, `requestUnsubscribe`, `delete`) | Double opt-in newsletter |
| `account.companies`, `companies` (+ `addresses`, `members`, `invitations`, `orders`), `companyInvitations` (`lookup`, `accept`) | B2B self-service (see `spree-b2b`). `companies.members.create(id, { customer_email })` always returns a `CompanyInvitation` |

Endpoints without a wrapper yet (e.g. `/customers/me/data_requests`, cart `tax_identifier`, `po_document`) are reachable through `client.request` (below).

### Auth, guest tokens, per-request options

```ts
// Customer login: tokens aren't stored on the client; pass them per request
const { token, refresh_token, user } = await client.auth.login({ email, password })
const { data: orders } = await client.customer.orders.list({}, { token })
const fresh = await client.auth.refresh({ refresh_token })        // rotates both tokens
await client.auth.logout({ refresh_token })

// Third-party IdP (strategy registered on the server)
await client.auth.login({ provider: 'external_idp', token: idpJwt })
```

`RequestOptions`: `token` (Bearer JWT), `spreeToken` (guest cart/order token, sent as `X-Spree-Token`), `idempotencyKey`, `headers`.

### Cart → order

```ts
let cart = await client.carts.create()
const opts = { spreeToken: cart.token }            // or { token } for a signed-in customer

cart = await client.carts.items.create(cart.id, { variant_id: 'variant_xxx', quantity: 1 }, opts)
cart = await client.carts.update(cart.id, { email, shipping_address, use_shipping: true }, opts)
// cart.requirements → [{ step, field, code, message }] (what still blocks completion)

const result = await client.carts.complete(cart.id, opts)  // Order (or_…, order.cart_id === cart.id) | OrderGroup (ogrp_…)
```

- **After completion, the cart is gone from cart endpoints.** `client.carts.get(cartId)` throws a 404 `SpreeError` (`cart_not_found`). On the confirmation page, or after a redirect-based payment, read `client.orders.get(cartId, {}, opts)`. The orders endpoint accepts the cart ID and resolves it to its order, with the same guest token.
- Drive the checkout UI from `cart.requirements`, not from a state machine (see `spree-checkout`).
- `Order` exposes `number`, `cart_id`, `coupon_code`, `payment_status`, `fulfillment_status`, totals and `display_*`. The Store serializer has no `state` and no `status`.
- `carts.complete` is typed `Promise<Order | OrderGroup>`: a multi-seller marketplace cart completes into an order group (`ogrp_…`, with `orders[]`). Narrow with the `isOrderGroup` guard exported from `@spree/sdk` — `const orders = isOrderGroup(result) ? result.orders : [result]`. Non-marketplace stores always get an `Order`, but TypeScript still makes you narrow. (`@spree/admin-sdk` has its own `isOrderGroup` for admin completion.)

### Money is `string | null`

Amounts are decimal strings (`"29.99"`) with `display_*` companions. On channels that hide prices from guests they're **`null`**, and the generated types say `string | null`. Handle null, and don't `parseFloat` blindly.

### List params (Ransack)

```ts
await client.products.list({ page: 2, limit: 50, name_cont: 'shirt', sort: '-created_at', expand: ['media'], fields: ['name', 'slug'] })
```

Keys other than `page`, `limit`, `sort`, `expand` and `fields` become `q[...]` predicates (`name_cont` → `q[name_cont]`; arrays get `[]`, nested objects use brackets).

- A filter that isn't in the typed params, or one named like a passthrough key, goes under `q: { … }`. Entries in `q` are always sent as filters, and a top-level key overrides the same key in `q`.
- Don't nest predicates under a `filter` key. It's sent as `q[filter][…]` and Ransack ignores it.
- `spree filters types` generates typings for the filters your app adds (see `spree-cli`).

### Errors

```ts
import { SpreeError } from '@spree/sdk'

try { await client.carts.items.create(cartId, { variant_id, quantity: 1 }, opts) }
catch (err) {
  if (err instanceof SpreeError) {
    err.status   // 422
    err.code     // 'insufficient_stock' | 'validation_error' | ...
    err.details  // { quantity: ['...'] } (attribute keys; 'base' = form-level)
  }
  throw err
}
```

### Retry and idempotency

The default is 2 retries with exponential backoff and jitter, retrying on 429/500/502/503/504 and network errors, and honoring `Retry-After`. Mutating requests get an automatic `Idempotency-Key` while retries are on, so a retried POST can't double-apply. Configure with `retry: { maxRetries, baseDelay, maxDelay, retryOnStatus, retryOnNetworkError }` or turn it off with `retry: false`. Pass `fetch` for Next.js caching, tracing or tests.

## @spree/admin-sdk — Admin API

```ts
import { createAdminClient } from '@spree/admin-sdk'

// Integration (server only)
const admin = createAdminClient({ baseUrl, secretKey: process.env.SPREE_SECRET_KEY! })

const { data: orders } = await admin.orders.list({ status_eq: 'placed', sort: '-completed_at' })
const order = await admin.orders.get('or_xxx', { expand: ['items', 'payments', 'fulfillments'] })
await admin.orders.cancel('or_xxx', { cancel_reason_id: 'ocr_xxx', cancel_note: 'Customer request' })
await admin.orders.refunds.create('or_xxx', { payment_id: 'py_xxx', amount: '25.00', refund_reason_id: 'rr_xxx' })  // refund_reason_id, not reason_id
```

- **Secret key**: scope-limited. A missing scope throws 403 with `details.required_scope`. Mint the narrowest key you can (see `spree-api-v3/references/scopes.md`).
- **Staff JWT** (custom back-office UIs): `admin.auth.login({ email, password })` (or `{ provider, ... }`) returns `{ token, user }`, and the refresh token is set as an HttpOnly cookie. Then call `admin.setToken(token)`. `admin.auth.refresh()` takes **no token argument** (the cookie drives it). Admin JWTs expire after 5 minutes, so wire up `admin.onUnauthorized(async () => { const { token } = await admin.auth.refresh(); admin.setToken(token); return true })`. The client defaults to `credentials: 'include'`. Staff are gated by their **roles' permission keys** (403 `details.required_permission`); see `spree-auth-permissions`.
- `admin.setStore(storeId)` sends `X-Spree-Store-Id` on multi-store hosts.
- Full CRUD plus domain actions: `orders.complete/cancel/approve`, `products.activate/archive/draft` (one product, emits the product event), `products.clone/bulkStatusUpdate/bulkAddToCategories/...`, `prices.bulkUpsert`, `stockLevels.bulkUpsert`, `roles`, `permissions.list()`, `exports`, `imports`, `webhookEndpoints`, `apiKeys`, and more (see `packages/admin-sdk/src/admin-client.ts`).
- Invitation listings carry no `acceptance_url`; fetch the link on demand with `admin.invitations.acceptanceLink(id)` (or `admin.sellers.invitations.acceptanceLink(sellerId, id)`) — write-gated. `admin.invitations.create` requires `role_id`.
- `?expand=` of orders/payments/customers/gift cards/store credits is silently dropped when the key/staff member lacks that read permission — check scopes before assuming the API omitted data.
- Stock is `admin.stockLevels` (`sl_…`), not `stockItems`. Addresses use `country_code` / `state_code`, not `country_iso`.
- Products take prices as `prices: [{ currency: 'USD', amount: '29.99' }]` for simple products, or per variant.
- Singletons use `get`: `admin.me.get()` (includes `permission_keys`), `admin.store.get()`.
- Exports: `admin.exports.create({ type, search_params })`, poll `exports.get(id)` until it's done, then download with fetch plus an `Authorization` header into a Blob. There's no `.download()` helper.

## Webhook receivers

```ts
// app/api/webhooks/spree/route.ts (Node runtime)
import { verifyWebhookSignature, type WebhookEvent } from '@spree/sdk/webhooks'
import type { Order } from '@spree/sdk'

export async function POST(request: Request) {
  const rawBody = await request.text()                       // raw bytes, before JSON.parse
  const ok = verifyWebhookSignature(
    rawBody,
    request.headers.get('x-spree-webhook-signature') ?? '',
    request.headers.get('x-spree-webhook-timestamp') ?? '',
    process.env.SPREE_WEBHOOK_SECRET!,
    300,                                                      // replay tolerance (seconds)
  )
  if (!ok) return new Response('Unauthorized', { status: 401 })

  const event = JSON.parse(rawBody) as WebhookEvent<Order>
  if (event.name === 'order.placed') await syncToERP(event.data)
  return Response.json({ ok: true })
}
```

Subscribe to `order.placed`. `order.completed` is still sent through 6.0 as a deprecated alias (its metadata carries `deprecated_alias_of`) and is removed in 6.1. The verifier uses `node:crypto`; on Edge runtimes, implement HMAC-SHA256 over `` `${timestamp}.${rawBody}` `` with Web Crypto (see `spree-events-webhooks`). Failed deliveries are retried with backoff (up to 5 attempts, same `event.id`), so make handlers idempotent on `event.id`.

## Extending the SDK for custom endpoints

Don't fork the SDK, and don't bypass it with raw `fetch`. You'd lose the auth headers, locale/currency/channel defaults, retry, idempotency and error normalization.

| Situation | Use |
|---|---|
| An app calling one or two of its own endpoints | `client.request` |
| A reusable typed namespace on the client (`client.brands.list()`) | `define…Extension` + `client.extend()` |
| An extension (gem) shipping an npm client for its endpoints | `spree sdk generate` writes the extensions from the extension's OpenAPI |

### 1. One-off calls: `client.request`

Paths are relative to the surface root (`/api/v3/store`, `/api/v3/admin` or `/api/v3/seller`). `request` does **not** transform list params, so wrap Ransack predicates yourself:

```ts
import type { PaginatedResponse } from '@spree/sdk'

type Brand = { id: string; name: string; slug: string }

const { data } = await client.request<PaginatedResponse<Brand>>('GET', '/brands', {
  params: { 'q[name_cont]': 'acme', page: 1, limit: 25 },
})
const created = await admin.request<Brand>('POST', '/brands', { body: { name: 'Acme' } })
```

### 2. SDK extensions: `define…Extension` + `client.extend()` (6.0.3+)

An extension adds one typed namespace to a client. It uses the client's own request function, so auth, store/seller headers, locale defaults and retries all apply.

```ts
import { createClient, defineStoreExtension, type PaginatedResponse } from '@spree/sdk'

export const brands = defineStoreExtension('brands', ({ request, listParams, readParams }) => ({
  list: (params: { page?: number; limit?: number; name_cont?: string } = {}) =>
    request<PaginatedResponse<Brand>>('GET', '/brands', { params: listParams(params) }),
  get: (id: string, params: { expand?: string[] } = {}) =>
    request<Brand>('GET', `/brands/${id}`, { params: readParams(params) }),
}))

const client = createClient({ baseUrl, publishableKey }).extend(brands)
await client.brands.list({ name_cont: 'acme' })   // typed; built-ins unchanged
```

- `defineAdminExtension` comes from `@spree/admin-sdk` and `defineSellerExtension` from `@spree/seller-sdk`. Each export also has its `ExtensionContext` type.
- `build` receives three things:
  - `request` — the client's request function.
  - `listParams` — the same transform the built-in `list` methods use: filters to `q[…]`, plus `sort`, `page` and `expand`.
  - `readParams` — builds `{ expand, fields }`.
- `extend` returns a **new** client and leaves the original untouched. The two share settings, so a token or locale set on either applies to both. Chain `.extend(a).extend(b)` for more namespaces.
- `extend` throws a `TypeError` when:
  - the name already exists on the client (`products`, or the same extension added twice),
  - the extension was defined for another API (a store extension on an admin client),
  - the name is `then`.

  Extensions only add namespaces. To change a built-in method, wrap it in your own namespace.
- A package that ships an extension lists the SDK as a **peer dependency**, so the app's own client instance is the one extended.

This replaces the old patterns of `new BrandsClient(client.request)` assigned onto the client, and `Object.assign` over a resource. Those still run, but `extend` is typed and doesn't drop the prototype-held resources.

### 3. Generating an extension's client: `spree sdk generate`

For a Spree extension (gem) with its own Store/Admin/Seller endpoints, ship an npm package whose client is generated from the gem.

1. Document the gem's endpoints with rswag so it produces `openapi/admin.yaml` / `openapi/store.yaml` (see `spree-resource` § Documenting endpoints). Its serializers describe the responses.
2. In the package's `package.json`, point at the gem:

   ```json
   {
     "name": "my-quotes-extension",
     "peerDependencies": { "@spree/admin-sdk": "^6.0.3" },
     "spree": { "extension": "../my_extension" }
   }
   ```

3. Generate from the package directory. Build the gem's dummy app once first (`bundle exec rake test_app`).

   ```bash
   spree sdk generate               # runs the gem's rake spree:openapi:generate + spree:sdk:serializer_types, then writes
   spree sdk generate --no-backend  # from the committed openapi/*.yaml and types only
   spree sdk generate --check       # CI: fail if generated files are stale
   ```

It writes the following under `src/generated/<api>/`:

| File | Contents |
|---|---|
| `client.ts` | One extension per resource: `list`, `get`, `create`, `update`, `delete` and each action, camel-cased (`PATCH /quotes/{id}/send` → `quotes.send()`). Each method carries the operation's summary as JSDoc. Also exports `extendAdminClient` / `extendStoreClient`, which add every namespace. |
| `params/` | Request bodies (from `request_body_for`) |
| `filters.ts` | List filters (from `filter_parameters_for`) |
| `types/`, `spree.ts` | Response types from the serializers. `spree.ts` re-exports the SDK's types, so a `Quote` that nests an order uses the SDK's `Order`. |

Re-export the generated files from the package entry point, wrapping or renaming methods there if you want:

```ts
// src/index.ts
export * from './generated/admin/client'
export type * from './generated/admin/spree'
```

The consuming app:

```ts
import { createAdminClient } from '@spree/admin-sdk'
import { extendAdminClient } from 'my-quotes-extension'

const admin = extendAdminClient(createAdminClient({ baseUrl, secretKey }))
await admin.quotes.send('quote_1', { valid_until: '2026-12-01' })   // typed as Quote
```

Generation refuses some inputs:

- **Serializer names that clash with SDK types.** A serializer called `OrderSerializer` would collide with the SDK's `Order`, and two serializers in one API ending in the same name are refused. Rename the serializer.
- **Two operations that map to one method.** Give one an `operationId`.
- **Responses with no schema.** These aren't refused: they're typed by the resource name (`quotes` → `Quote`).

### Types for custom resources

- **Ad-hoc types.** Serializers are the source of truth. For `client.request`, hand-write the interface to match the serializer's `typelize` declarations (money is `string`).
- **Generated types.** `spree sdk generate` uses `rake spree:sdk:serializer_types`.
- **Typelizer 0.14.** `spree_api` 6.0.3 requires Typelizer `~> 0.14.0`. Update it together with Spree (`bundle update spree typelizer`). The old `DISABLE_TYPELIZER` / `ENABLE_TYPELIZER` env vars no longer do anything; Spree sets the new `TYPELIZER` switch itself, so delete them from `.env` files and CI.

## Testing with MSW

The SDK just calls `fetch`, so MSW handlers see every request:

```ts
server.use(
  http.get('https://test.spree.local/api/v3/store/products', () =>
    HttpResponse.json({ data: [{ id: 'prod_test1', name: 'Test' }], meta: { page: 1, limit: 25, count: 1, pages: 1 } })),
)
const client = createClient({ baseUrl: 'https://test.spree.local', publishableKey: 'pk_test' })
```

## Common pitfalls

- **404 on `carts.get` after checkout.** Expected. Use `orders.get(cartId)`.
- **Totals render as "NaN".** The channel hides prices and the fields are `null`.
- **Admin requests 401 every 5 minutes.** You haven't registered `onUnauthorized`, or the refresh cookie is blocked. Cross-origin setups need HTTPS and the origin in Settings → Allowed Origins.
- **403 with a secret key.** Read `err.details.required_scope` and mint a key that has it. Scopes can't be edited on an existing key.
- **Secret key in a browser bundle.** Never do this. `@spree/admin-sdk` with `secretKey` belongs on the server only, and the dashboard uses the JWT flow.
- **Listening for `order.completed`.** Switch to `order.placed`.

## Where to read further

- Store SDK source: `packages/sdk/src/store-client.ts`. Admin SDK: `packages/admin-sdk/src/admin-client.ts`. Seller SDK: `packages/seller-sdk/src/seller-client.ts`
- Docs: `node_modules/@spree/docs/dist/developer/sdk/` (Store quickstart, `extending.md`, `admin/quickstart.md`, `admin/authentication.md`, `admin/extending.md`)
- Extension source: `packages/sdk-core/src/extensions.ts`; generator: `packages/cli/src/commands/sdk.ts` + `packages/sdk-core/src/extension-source.ts`
- OpenAPI: `node_modules/@spree/docs/dist/api-reference/store.yaml`. Admin and Seller specs are at `/openapi/api-reference/{admin,seller}.yaml` on the `spree-docs` MCP server, or `docs/api-reference/` in the spree/spree repo.
- Related skills: `spree-api-v3`, `spree-resource` (OpenAPI for custom endpoints), `spree-mcp`, `spree-storefront`, `spree-checkout`, `spree-events-webhooks`, `spree-auth-permissions`, `spree-marketplace`.
