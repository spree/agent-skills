---
name: spree-api-v3
description: Use when the user is integrating with Spree's v3 REST API — making requests as a customer, building an admin app, writing webhook consumers, debugging auth errors, parsing API responses. Distinguishes the Store API (customer-facing) from the Admin API (back-office). Common phrasings include "Spree API", "Store API", "Admin API", "publishable key", "secret key", "X-Spree-Api-Key", "API scopes", "prefixed IDs in API", "expand", "API pagination", "Spree 401", "Spree 403", "{data, meta} envelope", "v3 endpoint". For ADDING a new resource to the API, use the spree-resource skill instead.
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

**Auth:** Always include `X-Spree-Api-Key: pk_<token>` (a publishable key). Additional layers:
- **Anonymous browse:** publishable key alone is enough for reading products, categories.
- **Guest cart:** publishable key + `X-Spree-Token: <cart_token>` for operations on a specific guest cart.
- **Logged-in customer:** publishable key + `Authorization: Bearer <jwt>` for account data, order history.

**What's exposed:** customer-visible fields only. Catalog and order Store serializers omit `created_at`/`updated_at`, exposing business dates instead (`available_on`, `completed_at`); a few resources (digitals, newsletter subscriptions) do include timestamps. No cost prices, no admin internal notes, no private metadata.

**What actions are enabled:** read-only by default. `index` and `show` for catalog endpoints. Cart/customer/address endpoints opt into `create`/`update`/`destroy`.

**Channel scope:** Store responses are scoped by `X-Spree-Channel: <code>` (e.g. `online`, `pos`). When omitted, the store's default channel is used. Products not published on the requested channel don't appear.

```bash
curl -H "X-Spree-Api-Key: pk_CzEKBTWFiuNLgz4wciLsS59n" \
     -H "X-Spree-Channel: online" \
     -H "Accept-Language: en-US" \
     https://my-spree.example.com/api/v3/store/products
```

### Admin API

**Who calls it:** trusted backend apps (your ERP integration, marketplace fulfillment service) or trusted humans (admin SPA users). Never the browser of an anonymous visitor.

**Auth:** Two distinct paths, each with its own authorization model.

**Path 1: Secret key with scopes** — for server-to-server apps and integrations.

```bash
curl -H "X-Spree-Api-Key: sk_…" \
     https://my-spree.example.com/api/v3/admin/orders
```

Secret keys (`sk_*` prefix) carry **scopes** that gate which endpoints they can hit. Scopes are granted at key creation. Each request's scope is enforced by `ScopedAuthorization`; missing scope = 403.

The scope list (5.5, from `Spree::ApiKey::SCOPES`):
```
read_orders               write_orders
read_products             write_products
read_promotions           write_promotions
read_customers            write_customers
read_payments             write_payments
read_fulfillments         write_fulfillments
read_refunds              write_refunds
read_gift_cards           write_gift_cards
read_store_credits        write_store_credits
read_stock                write_stock
read_categories           write_categories
read_settings             write_settings
read_webhooks             write_webhooks
read_api_keys             write_api_keys
read_dashboard
read_all                  write_all     # superset (full admin)
```

Some endpoints map onto these rather than having their own pair: custom-field-definition endpoints require `read_settings`/`write_settings`, and export endpoints resolve their required scope per request (there is no `read_exports`/`write_exports` scope).

This is the right path for **building an app or integration**. The app gets a minimum-privilege secret key from the merchant; no human user is involved. Audit-friendly (you know exactly which app made each request).

**Path 2: JWT with CanCanCan abilities** — for human admin users.

```bash
# Login first
curl -X POST https://my-spree.example.com/api/v3/admin/auth/login \
     -H "Content-Type: application/json" \
     -d '{"email":"admin@example.com","password":"…"}'
# Returns: { token, user } — the JWT is in `token`; the refresh token is set as an
# httpOnly cookie (used by POST /api/v3/admin/auth/refresh), not returned in the body.

# Then use the JWT
curl -H "Authorization: Bearer <jwt>" \
     https://my-spree.example.com/api/v3/admin/orders
```

JWT admin auth uses **`Spree::Ability` (CanCanCan)** to determine what the human user can do. Roles + permission sets configure who can manage what.

(The store is resolved from the request host, not from an API key.)

**What's exposed:** everything visible to the Store API plus timestamps (`created_at`, `updated_at`, `deleted_at` if paranoid), cost prices, private metadata, internal notes, audit fields (`approved_by_id`, `cancelled_by_id`), back-office relations.

**What actions are enabled:** full CRUD by default. `index`, `show`, `create`, `update`, `destroy` for every resource unless explicitly restricted.

### Quick reference

| Question | Store API | Admin API |
|---|---|---|
| Default actions | index, show | full CRUD |
| API key prefix | `pk_*` | `sk_*` (or use JWT instead) |
| Timestamps in responses | No | Yes |
| Cost prices exposed | No | Yes |
| Channel scoping | Optional header (default channel when omitted) | N/A (header ignored; filter via Ransack) |
| Default for new endpoints | Read-only | Full CRUD |
| Authorization | Per-endpoint defaults | Scopes (sk_*) OR CanCanCan abilities (JWT) |

## The {data, meta} envelope

Every list endpoint returns:

```json
{
  "data": [
    { "id": "prod_86Rf07xd4z", "name": "...", ... },
    { "id": "prod_kvJ0pQrTb9", "name": "...", ... }
  ],
  "meta": {
    "page": 1,
    "limit": 25,
    "count": 152,
    "pages": 7,
    "from": 1,
    "to": 25,
    "in": 25,
    "previous": null,
    "next": 2
  }
}
```

Single-record endpoints return the record's attributes directly (no wrapping):

```json
{ "id": "prod_86Rf07xd4z", "name": "...", ... }
```

Conventions:
- **There is no `type` field.** The resource kind is implied by the prefixed-ID prefix (`prod_`, `or_`, `variant_`, …). A few resources do expose a `type` attribute (payment methods, promotion rules/actions, price rules), but it is an STI class discriminator specific to that resource, not an envelope convention.
- **`meta` is on lists only.** Single-record responses don't have it.
- **`next` / `previous`** are page numbers (or `null` at the ends). Pagination is offset-based via Pagy — pass `?page=N&limit=N` to navigate.

## Prefixed IDs

Every v3 API uses Stripe-style prefixed IDs:

```
prod_86Rf07xd4z       Product
variant_k5nR8xLq      Variant
or_m3Rp9wXz           Order
py_…                  Payment       (Stripe parity)
ful_…                 Shipment
adj_…                 Adjustment
li_…                  LineItem
ch_…                  Channel
key_…                 ApiKey        (record ID; the credential token values are prefixed pk_/sk_ — those are secrets, not IDs)
cf_…                  CustomField   (alias of Metafield)
```

The integer PK is **never** in API responses — only the prefixed form. Same on writes: send `"variant_id": "variant_k5nR8xLq"`, not `"variant_id": 42`. The server resolves prefixed IDs to integer PKs internally.

Computation: `Sqids.encode([integer_pk])` with `min_length: 10`. Deterministic — the same PK always gets the same prefixed ID. There's no database column for it; it's computed on read.

## Expand

Resources support an `expand` query param for sideloading related data:

```bash
curl '/api/v3/store/products/cool-shirt?expand=media,default_variant,categories'
```

Returns the product with `media`, `default_variant`, and `categories` inlined as full objects. Without `expand`, related objects appear as ID references on the parent. Dot notation lets you expand nested associations:

```bash
curl '/api/v3/store/products/cool-shirt?expand=variants.media'
```

Allowed expand keys are per-resource and listed in the OpenAPI spec.

### Sparse fieldsets

The inverse of `expand`: pass `fields=name,slug` to trim the response to just those attributes (`id` and any expanded associations are always retained):

```bash
curl '/api/v3/store/products?fields=name,slug'
```

## Pagination

```bash
GET /api/v3/admin/orders?page=2&limit=50
```

Offset-based via Pagy. `limit` defaults to 25; max is generally 100. Use `meta.next` / `meta.previous` to navigate.

## Filtering with Ransack

List endpoints accept Ransack predicates as `q[<attribute>_<predicate>]`:

```bash
# Products with name containing "shirt"
GET /api/v3/store/products?q[name_cont]=shirt

# Orders completed in the last 30 days
GET /api/v3/admin/orders?q[completed_at_gteq]=2026-05-01

# Multiple filters — use `status` (draft/placed/canceled, new in 5.5), not the legacy `state` (removed in Spree 6)
GET /api/v3/admin/orders?q[status_eq]=placed&q[total_gt]=100

# Sort by completed_at descending
GET /api/v3/admin/orders?q[s]=completed_at+desc
```

Common predicates: `_eq`, `_not_eq`, `_in`, `_not_in`, `_cont` (LIKE %x%), `_start` (LIKE x%), `_gteq`, `_lteq`, `_gt`, `_lt`, `_present`, `_blank`.

Only attributes in the model's `whitelisted_ransackable_attributes` and `whitelisted_ransackable_associations` are queryable. Predicates on attributes outside the whitelist are silently ignored — the request returns 200 with that condition dropped (any remaining whitelisted predicates still apply), not a 422.

## Error responses

All errors use a consistent envelope:

```json
// 401 Unauthorized
{ "error": { "code": "invalid_token", "message": "Valid API key required" } }

// 403 Forbidden (scope missing)
{ "error": { "code": "access_denied", "message": "API key lacks scope: write_orders", "details": { "required_scope": "write_orders" } } }

// 404 Not Found
{ "error": { "code": "record_not_found", "message": "Product not found" } }

// 422 Unprocessable Entity (validation)
{
  "error": {
    "code": "validation_error",
    "message": "Email can't be blank and Customer is required for checkout",
    "details": {
      "email": ["can't be blank"],
      "base": ["Customer is required for checkout"]
    }
  }
}

// 429 Too Many Requests (rate limited)
{ "error": { "code": "rate_limit_exceeded", "message": "..." } }
```

Note: some resources return a specific code instead of `record_not_found`: `order_not_found` (orders), `cart_not_found` (carts — order lookups on /carts paths), `line_item_not_found`, `variant_not_found`. The message is always "<Model> not found".

The `details` map on 422s uses **attribute names** as keys. Map field-level errors to inputs; `base` errors are non-field-specific (display as a form-level banner). The `@spree/sdk` includes a `SpreeError` class that parses these automatically.

## Rate limiting

The API has per-key and per-endpoint rate limits configured via `Spree::Api::Config`:

| Setting | Default | Scope |
|---|---|---|
| `rate_limit_per_key` | 300 / 60s | General requests, per API key |
| `rate_limit_window` | 60s | Window for the per-key counter |
| `rate_limit_login` | 5 / 60s | `POST /api/v3/{store,admin}/auth/login` + admin invitation acceptance, per IP |
| `rate_limit_register` | 3 / 60s | Customer register + newsletter subscribe endpoints, per IP |
| `rate_limit_refresh` | 10 / 60s | Token refresh (store + admin) and store logout, per IP |
| `rate_limit_password_reset` | 3 / 60s | Password reset, per IP |

Hit limits → `429 Too Many Requests` with `Retry-After` header. The `@spree/sdk` retries with exponential backoff automatically.

Tune via `Spree::Api::Config[:rate_limit_per_key]` etc. in `config/initializers/spree.rb`. For tougher global throttling (per-IP at the proxy edge), layer Rack::Attack or your CDN's WAF on top.

## Read/write attribute symmetry (a v3 invariant)

For any resource: **whatever a serializer returns, the controller's `permitted_params` accepts on write under the same name.** No `label` exposed but `presentation` accepted. No `customer_note` exposed but `special_instructions` accepted. The client never has to translate.

When the underlying column has a legacy name, the model has an alias method (e.g. `Spree::OptionType` exposes `label`/`label=` aliasing the underlying `presentation` column). The model owns the bridge.

## Common debugging recipes

### "I'm getting 401 on every call"

- Check `X-Spree-Api-Key` header is set.
- Verify the key is valid: `GET /api/v3/admin/me` returns 200 if your JWT is valid; otherwise 401.
- Publishable key for Store API; secret OR JWT for Admin API. Mixing them = 401.

### "I'm getting 403 on Admin API"

- For secret keys: the key doesn't have the required scope. Check the key's scopes; either grant the scope or use a JWT admin user.
- For JWT admins: the user doesn't have the required ability. Check `Spree::Ability` rules for the user's role.

### "My q[...] filter is silently ignored"

The attribute isn't in the model's Ransack allowlist. The API uses lenient `.ransack`, so conditions on non-whitelisted attributes are silently dropped — the list comes back unfiltered (200, no error). Add the attribute via `Spree.ransack.add_attribute(Spree::Product, :attr)` in an initializer, or append it to `whitelisted_ransackable_attributes` in a model decorator.

### "Empty data array but I know records exist"

- Wrong channel? Store API queries are channel-scoped. Try `X-Spree-Channel: <code>` matching where the record was created.
- Wrong currency? Some resources (products) are filtered by `available(currency)` — record exists but doesn't have a price in the requested currency.
- Authorization scope? For Admin: maybe your role can see the index but the scope of accessible records is restricted.

### "Webhook payload uses raw IDs?"

It doesn't — Webhooks 2.0 uses the same prefixed IDs as the API. If you're seeing integer IDs, you're either on the legacy webhooks system OR the consumer is parsing wrong.

## Where to read further

- **OpenAPI specs:** `node_modules/@spree/docs/dist/api-reference/store.yaml` (Store API) and `admin.yaml` (Admin API) — every endpoint, parameter, response schema. Authoritative.
- **Adding a new endpoint:** see the `spree-resource` skill — `spree:api_resource` generator produces v3-conformant controllers + serializers automatically.
- **SDK:** `@spree/sdk` (Store) and `@spree/admin-sdk` (Admin) — typed clients. See the `spree-typescript-sdk` skill.
- **Customization:** `node_modules/@spree/docs/dist/developer/customization/api.md` and `authentication.md`
- **Webhooks vs subscribers:** see the `spree-events-webhooks` skill.
