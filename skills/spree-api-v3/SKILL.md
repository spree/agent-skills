---
name: spree-api-v3
description: Use when the user is integrating with Spree's v3 REST API — making requests as a customer, building an admin app, writing webhook consumers, debugging auth errors, parsing API responses. Distinguishes the Store API (customer-facing) from the Admin API (back-office). Common phrasings include "Spree API", "Store API", "Admin API", "publishable key", "secret key", "X-Spree-API-Key", "API scopes", "prefixed IDs in API", "expand", "API pagination", "Spree 401", "Spree 403", "{data, meta} envelope", "v3 endpoint". For ADDING a new resource to the API, use the spree-resource skill instead.
---

# Spree API v3

Spree exposes two distinct API surfaces under `/api/v3/`:

| Surface | Path | Audience | Auth |
|---|---|---|---|
| **Store API** | `/api/v3/store/*` | Storefronts, mobile apps, customers | Publishable key + optional JWT customer |
| **Admin API** | `/api/v3/admin/*` | Back-office apps, integrations, admin SPAs | Secret key + scopes OR JWT admin + CanCanCan |

They share conventions (envelope shape, prefixed IDs, pagination) but have **different auth, different default actions, and different exposed fields**. This is the most-confused-about distinction in the API; cover it carefully.

## Store API vs Admin API — the contract differences

### Store API

**Who calls it:** customer browsers and apps. Public, untrusted clients.

**Auth:** Always include `X-Spree-API-Key: pk_<token>` (a publishable key). Additional layers:
- **Anonymous browse:** publishable key alone is enough for reading products, categories.
- **Guest cart:** publishable key + `X-Spree-Token: <cart_token>` for operations on a specific guest cart.
- **Logged-in customer:** publishable key + `Authorization: Bearer <jwt>` for account data, order history.

**What's exposed:** customer-visible fields only. No timestamps (`created_at`/`updated_at` are NOT in Store responses). No cost prices, no admin internal notes, no private metadata.

**What actions are enabled:** read-only by default. `index` and `show` for catalog endpoints. Cart/customer/address endpoints opt into `create`/`update`/`destroy`.

**Channel scope:** Store responses are scoped by `X-Spree-Channel: <code>` (e.g. `online`, `pos`). When omitted, the store's default channel is used. Products not published on the requested channel don't appear.

```bash
curl -H "X-Spree-API-Key: pk_CzEKBTWFiuNLgz4wciLsS59n" \
     -H "X-Spree-Channel: online" \
     -H "Accept-Language: en-US" \
     https://my-spree.example.com/api/v3/store/products
```

### Admin API

**Who calls it:** trusted backend apps (your ERP integration, marketplace fulfillment service) or trusted humans (admin SPA users). Never the browser of an anonymous visitor.

**Auth:** Two distinct paths, each with its own authorization model.

**Path 1: Secret key with scopes** — for server-to-server apps and integrations.

```bash
curl -H "X-Spree-API-Key: sk_…" \
     https://my-spree.example.com/api/v3/admin/orders
```

Secret keys (`sk_*` prefix) carry **Shopify-style scopes** that gate which endpoints they can hit. Scopes are granted at key creation. Each request's scope is enforced by `ScopedAuthorization`; missing scope = 403.

The scope list (5.5):
```
read_orders               write_orders
read_products             write_products
read_customers            write_customers
read_payments             write_payments
read_fulfillments         write_fulfillments
read_refunds              write_refunds
read_gift_cards           write_gift_cards
read_store_credits        write_store_credits
read_stock                write_stock
read_categories           write_categories
read_custom_field_definitions  write_custom_field_definitions
read_exports              write_exports
read_settings             write_settings
read_webhooks             write_webhooks
read_dashboard
read_all                  write_all     # superset (full admin)
```

This is the right path for **building an app or integration**. The app gets a minimum-privilege secret key from the merchant; no human user is involved. Audit-friendly (you know exactly which app made each request).

**Path 2: JWT with CanCanCan abilities** — for human admin users.

```bash
# Login first
curl -X POST https://my-spree.example.com/api/v3/admin/auth/login \
     -H "Content-Type: application/json" \
     -d '{"email":"admin@example.com","password":"…"}'
# Returns: { access_token, refresh_token, token_type: "Bearer" }

# Then use the JWT
curl -H "X-Spree-API-Key: pk_<publishable>" \
     -H "Authorization: Bearer <jwt>" \
     https://my-spree.example.com/api/v3/admin/orders
```

JWT admin auth uses **`Spree::Ability` (CanCanCan)** to determine what the human user can do. Roles + permission sets configure who can manage what. This is what the admin SPA (`@spree/dashboard`) uses.

(The publishable key is required alongside the JWT to identify the store the user is logged into.)

**What's exposed:** everything visible to the Store API plus timestamps (`created_at`, `updated_at`, `deleted_at` if paranoid), cost prices, private metadata, internal notes, audit fields (`approved_by_id`, `cancelled_by_id`), back-office relations.

**What actions are enabled:** full CRUD by default. `index`, `show`, `create`, `update`, `destroy` for every resource unless explicitly restricted.

### Quick reference

| Question | Store API | Admin API |
|---|---|---|
| Default actions | index, show | full CRUD |
| API key prefix | `pk_*` | `sk_*` (or use JWT instead) |
| Timestamps in responses | No | Yes |
| Cost prices exposed | No | Yes |
| Channel scoping | Required | Optional |
| Default for new endpoints | Read-only | Full CRUD |
| Authorization | Per-endpoint defaults | Scopes (sk_*) OR CanCanCan abilities (JWT) |

## The {data, meta} envelope

Every list endpoint returns:

```json
{
  "data": [
    { "id": "prod_86Rf07xd4z", "type": "product", "name": "...", ... },
    { "id": "prod_kvJ0pQrTb9", "type": "product", "name": "...", ... }
  ],
  "meta": {
    "page": 1,
    "limit": 25,
    "count": 152,
    "pages": 7,
    "from": 1,
    "to": 25,
    "previous": null,
    "next": 2,
    "current_cursor": "...",
    "next_cursor": "..."
  }
}
```

Single-record endpoints return the record's attributes directly (no wrapping):

```json
{ "id": "prod_86Rf07xd4z", "type": "product", "name": "...", ... }
```

Conventions:
- **`type`** is the resource type identifier (`"product"`, `"order"`, `"cart"`). Used by clients to dispatch.
- **`meta` is on lists only.** Single-record responses don't have it.
- **`next` / `previous`** are page numbers (or `null` at the ends). Use these for offset pagination.
- **`current_cursor` / `next_cursor`** are for keyset pagination — use these on large collections (orders, customers) to avoid OFFSET performance.

## Prefixed IDs

Every v3 API uses Stripe-style prefixed IDs:

```
prod_86Rf07xd4z       Product
variant_k5nR8xLq      Variant
or_m3Rp9wXz           Order
py_…                  Payment       (Stripe parity)
ful_…                 Shipment      (becomes Fulfillment in 6.0)
brand_…               Brand
ad_…                  Adjustment
li_…                  LineItem
ctg_…                 Category      (renamed from Taxon)
ch_…                  Channel
pk_…                  ApiKey (publishable)
sk_…                  ApiKey (secret)
cf_…                  CustomField   (renamed from Metafield)
```

The integer PK is **never** in API responses — only the prefixed form. Same on writes: send `"variant_id": "variant_k5nR8xLq"`, not `"variant_id": 42`. The server resolves prefixed IDs to integer PKs internally.

Computation: `Sqids.encode([integer_pk])` with `min_length: 10`. Deterministic — the same PK always gets the same prefixed ID. There's no database column for it; it's computed on read.

## Expand

Most resources support an `include` query param (Spree uses `include`, not `expand`) for sideloading related data:

```bash
curl '/api/v3/store/products/cool-shirt?include=images,default_variant,categories'
```

Returns the product with `images`, `default_variant`, and `categories` data inlined as full objects rather than just IDs. Without `include`, related objects appear as ID references in `relationships`.

Allowed includes are per-resource and listed in the OpenAPI spec.

## Pagination

```bash
# Offset (small/medium collections)
GET /api/v3/admin/orders?page=2&limit=50

# Keyset / cursor (large collections — orders, customers, line_items)
GET /api/v3/admin/orders?cursor=eyJpZCI6Im9yX...
```

`limit` defaults vary by endpoint (usually 25). Maximum is generally 100. Use the `meta.next_cursor` from the previous response for the next page on keyset paginated endpoints.

## Filtering with Ransack

List endpoints accept Ransack predicates as `q[<attribute>_<predicate>]`:

```bash
# Products with name containing "shirt"
GET /api/v3/store/products?q[name_cont]=shirt

# Orders completed in the last 30 days
GET /api/v3/admin/orders?q[completed_at_gteq]=2026-05-01

# Multiple filters
GET /api/v3/admin/orders?q[state_eq]=complete&q[total_gt]=100

# Sort by completed_at descending
GET /api/v3/admin/orders?q[s]=completed_at+desc
```

Common predicates: `_eq`, `_not_eq`, `_in`, `_not_in`, `_cont` (LIKE %x%), `_start` (LIKE x%), `_gteq`, `_lteq`, `_gt`, `_lt`, `_present`, `_blank`.

Only attributes in the model's `whitelisted_ransackable_attributes` and `whitelisted_ransackable_associations` are queryable. Trying to filter on an unallowed attribute returns 422.

## Error responses

All errors use a consistent envelope:

```json
// 401 Unauthorized
{ "error": { "code": "invalid_token", "message": "Valid API key required" } }

// 403 Forbidden (scope missing)
{ "error": { "code": "insufficient_scope", "message": "Required scope: write_orders" } }

// 404 Not Found
{ "error": { "code": "not_found", "message": "Order not found" } }

// 422 Unprocessable Entity (validation)
{
  "error": {
    "code": "validation_failed",
    "message": "Validation failed",
    "details": {
      "email": ["can't be blank"],
      "base": ["Customer is required for checkout"]
    }
  }
}

// 429 Too Many Requests (rate limited)
{ "error": { "code": "rate_limited", "message": "..." } }
```

The `details` map on 422s uses **attribute names** as keys. Map field-level errors to inputs; `base` errors are non-field-specific (display as a form-level banner). The `@spree/sdk` includes a `SpreeError` class that parses these automatically.

## Rate limiting

Default limits are conservative:

- **Anonymous (publishable key only):** 300 req/min per IP
- **Authenticated customer (JWT):** 600 req/min per user
- **Secret key (admin app):** 1000 req/min per key
- **JWT admin:** 1000 req/min per user

Hit limits → `429 Too Many Requests` with `Retry-After` header. The `@spree/sdk` retries with exponential backoff automatically.

To raise limits in production, configure `Spree::Config[:api_rate_limit]` or use Rack::Attack at the infra layer.

## Read/write attribute symmetry (a v3 invariant)

For any resource: **whatever a serializer returns, the controller's `permitted_params` accepts on write under the same name.** No `label` exposed but `presentation` accepted. No `customer_note` exposed but `special_instructions` accepted. The client never has to translate.

When the underlying column has a legacy name, the model has an alias method (e.g. `Spree::OptionType` exposes `label`/`label=` aliasing the underlying `presentation` column). The model owns the bridge.

## Common debugging recipes

### "I'm getting 401 on every call"

- Check `X-Spree-API-Key` header is set.
- Verify the key is valid: `GET /api/v3/admin/auth/me` returns 200 if your JWT is valid; otherwise 401.
- Publishable key for Store API; secret OR JWT for Admin API. Mixing them = 401.

### "I'm getting 403 on Admin API"

- For secret keys: the key doesn't have the required scope. Check the key's scopes; either grant the scope or use a JWT admin user.
- For JWT admins: the user doesn't have the required ability. Check `Spree::Ability` rules for the user's role.

### "Filter returns 422 'attribute not allowed'"

The attribute isn't in `whitelisted_ransackable_attributes`. Either add it (model decorator) or filter on a different attribute.

### "Empty data array but I know records exist"

- Wrong channel? Store API queries are channel-scoped. Try `X-Spree-Channel: <code>` matching where the record was created.
- Wrong currency? Some resources (products) are filtered by `available(currency)` — record exists but doesn't have a price in the requested currency.
- Authorization scope? For Admin: maybe your role can see the index but the scope of accessible records is restricted.

### "Webhook payload uses raw IDs?"

It doesn't — Webhooks 2.0 uses the same prefixed IDs as the API. If you're seeing integer IDs, you're either on the legacy webhooks system OR the consumer is parsing wrong.

## Where to read further

- **OpenAPI spec:** `backend/node_modules/@spree/docs/dist/api-reference/store.yaml` — every endpoint, parameter, response schema. Authoritative.
- **Adding a new endpoint:** see the `spree-resource` skill — `spree:api_resource` generator produces v3-conformant controllers + serializers automatically.
- **SDK:** `@spree/sdk` (Store) and `@spree/admin-sdk` (Admin) — typed clients. See the `spree-typescript-sdk` skill.
- **Auth deep dive:** `docs/plans/6.0-platform-auth.md` and `docs/plans/5.5-admin-api-key-scopes.md` if the monorepo is present.
- **Webhooks vs subscribers:** see the `spree-events-webhooks` skill.
