---
name: spree-cli
description: Use when calling the Spree 6 Admin API from the command line or driving it programmatically as an agent — exploring endpoints, reading or mutating store data, and especially DEBUGGING (inspecting an order/product/customer, checking why a request failed, reproducing a 403/422). The `spree api` command group in `@spree/cli` is a `gh api`-style generic HTTP client: `spree api get|post|patch|delete <path>` plus offline discovery (`spree api endpoints`, `spree api schema`). Common phrasings include "spree api", "spree CLI", "call the admin API from the terminal", "spree api get", "inspect this order", "why is this Spree request failing", "list admin endpoints", "spree auth". Also covers the project-side dev commands agents reach for while debugging (`spree shell`, `spree rspec`, `spree console`, `spree add`, `spree plugin new`). For SDK/TypeScript integration use spree-typescript-sdk; for raw API protocol details use spree-api-v3.
---

# Spree CLI — Admin API from the terminal

`@spree/cli` ships a `spree api` command group: a generic Admin API v3 client modeled on `gh api`. It is the fastest way to inspect and manipulate store data from a terminal, and the most reliable way for an **agent to debug** — no SDK boilerplate, structured JSON in/out, and offline endpoint discovery.

`spree api` talks to the **Admin API only** (`/api/v3/admin`, secret key auth). It can't call the Store or Seller APIs; use `curl` or the SDKs for those. It works against any Spree 6 instance (and 5.5+). Inside a local project it provisions a read-only key for itself; for any other server you supply a key.

## When to reach for the CLI

- **Debugging** — "what status is order `or_x` in?", "why did this 403?", "does this product have the variant I expect?". One command, JSON back, pipe to `jq`.
- **Exploring the API** — list endpoints and their required scopes, dump an operation's schema, all offline.
- **Scripting / agents** — deterministic, pipeable, exit-coded. No client to instantiate.

For building an app, prefer `@spree/admin-sdk` (see `spree-typescript-sdk`). The CLI is for interactive work, scripts, and agents.

## Setup

The CLI is `@spree/cli` (binary: `spree`). Verify it's available:

```bash
spree --version          # or: pnpm exec spree --version
```

If not installed: `npm i -g @spree/cli` (or run via `pnpm exec spree` / `npx @spree/cli` inside a project).

### Credentials — pick the layer that fits

Credentials resolve in this order (first match wins); host and key always resolve **together** per source:

1. **Explicit flags** — `--api-key sk_xxx`, or `--profile prod` to select a saved profile. Outrank everything below.
2. **Env** — set `SPREE_API_KEY`; the host defaults to `http://localhost:3000`, so local dev needs only the key. Set `SPREE_BASE_URL` for a remote store. Note an exported `SPREE_API_KEY` **outranks a local project's saved key**:
   ```bash
   SPREE_API_KEY=sk_xxx spree api get /products            # → localhost:3000
   SPREE_BASE_URL=https://store.example.com SPREE_API_KEY=sk_xxx spree api get /orders
   ```
3. **Inside a local Spree project** (a dir with `docker-compose.yml`, Rails app in `server/`, or legacy `backend/`, and the dev stack running): zero config. The first `spree api` call mints a **read-only** key via the dev stack and saves it to `.spree/credentials.json` (gitignored). Just run commands.
4. **Default profile** (the first profile you `spree auth login` becomes the default; key read from a prompt, never a flag):
   ```bash
   spree auth login --profile prod --base-url https://store.example.com
   spree api get /orders --profile prod    # or omit --profile once it's the default
   ```

Confirm what's resolved and that the server is reachable:

```bash
spree api status
```

### Minting a key with the scopes you need

Auto-minted project keys are `read_all` only. For writes, create a scoped secret key (in a project):

```bash
spree api-key create --type secret --scopes read_orders,write_products
```

Scopes follow `read_<resource>` / `write_<resource>` (`write_*` implies `read_*`); `read_all` / `write_all` are the catch-alls. `spree api endpoints` shows the scope each endpoint needs.

## Core usage

```bash
# Read — Ransack filters as repeatable -q, plus sort/page/limit/expand/fields
spree api get /products -q status_eq=active -q name_cont=shirt --sort -created_at --limit 10
spree api get /orders/or_x8k2J9aQ --expand items,payments,fulfillments
spree api get /products --fields name,slug,status     # id is always returned

# Write — JSON body inline, from @file, or '-' for stdin
spree api post /products -d '{"name":"Classic Tee","prices":[{"currency":"USD","amount":"29.99"}]}'
spree api patch /orders/or_x8k2J9aQ/cancel
spree api post /orders/or_x8k2J9aQ/refunds -d @refund.json
cat prices.json | spree api post /prices/bulk_upsert -d -
spree api delete /products/prod_86Rf07xd
```

- **Paths** take the Admin API path; the `/api/v3/admin` prefix is optional (paste a full path and it still works).
- **Output** is JSON: indented + colored in a terminal, compact + uncolored when piped (clean for `jq`). `--format table` renders collections for humans.
- Mutations carry an automatic `Idempotency-Key`, so retries are safe.

## Discovery (offline — no server needed)

The CLI bundles a snapshot of the Admin API OpenAPI spec:

```bash
spree api endpoints --resource orders        # every orders endpoint + required scope
spree api endpoints --search "gift card"     # fuzzy search across method/path/summary
spree api schema "POST /orders"              # full request/response schema for one op
```

Use `endpoints`/`schema` to find the right path and body shape **before** calling — this is how an agent should orient instead of guessing.

### Shell completion

```bash
eval "$(spree completion zsh)"     # bash and fish also supported
```

Completes resource paths, Ransack predicate stems (`status_eq=`, `name_cont=`…), and scope names.

## Debugging workflow (the high-value path for agents)

When a request or app behavior is wrong, the CLI is the fastest probe. A typical loop:

```bash
# 1. Reproduce the read and see the actual state
spree api get /orders/or_x8k2J9aQ --expand payments,fulfillments | jq '.status, .payment_status, .fulfillment_status'

# 2. If a write failed, find the endpoint's contract
spree api schema "PATCH /orders/{id}/cancel"

# 3. Re-run the write and read the error envelope verbatim
spree api patch /orders/or_x8k2J9aQ/cancel
```

### Reading errors

Errors print the Stripe-style envelope to **stderr** and set the exit code:

- **`0`** success · **`1`** API error (4xx/5xx — the `{error: {code, message, details}}` envelope) · **`2`** usage/config error (bad flag, no credentials, unreachable host).

A **scope denial** (`403`, `code: access_denied`) prints `details.required_scope` and the exact remediation — mint a key with that scope and pass it via `--api-key` or `SPREE_API_KEY`:

```text
access_denied: API key lacks scope: write_products
{ "details": { "required_scope": "write_products" } }
Hint: this key lacks `write_products`. Create one that has it and use it:
  spree api-key create --type secret --scopes write_products
  then pass it via --api-key <sk_...> or export SPREE_API_KEY=<sk_...>
```

A **validation error** (`422`, `code: validation_error`) puts per-attribute messages in `details` — read them to see which fields the body got wrong, then check `spree api schema` for the correct shape.

`spree api status` diagnoses the credential/reachability layer when calls fail before reaching the API at all (wrong host, expired/typo'd key).

## Beyond `spree api`: project commands for debugging

In a scaffolded project (Docker dev stack), these commands run inside the web container. In a classic Rails app without Docker, use the native equivalents (`bin/rails console`, `bundle exec rspec`, …).

```bash
spree console                           # Rails console: Spree::Cart.find_by_prefix_id!('cart_…')
spree shell                             # interactive bash in the web container (alias: spree bash)
spree rspec spec/models/spree/brand_spec.rb:15   # RSpec with RAILS_ENV=test; args pass straight through
spree logs                              # web logs (spree logs worker for jobs)
spree db:console                        # psql against the dev database
spree add dashboard                     # scaffold apps/dashboard (or: spree add seller-dashboard)
spree plugin new brands                 # scaffold a dashboard plugin repo (the Rails engine half is a separate spree_extension gem)
spree encryption init [--print]         # add Active Record encryption keys to .env (never overwrites; --print only prints a set)
```

`spree shell` and `spree rspec` still work when the web container is crash-looping: they fall back to a one-off `compose run`.

### What `spree api` can't see

- **Shopper carts.** The Admin API exposes orders (`/orders`, `/order_groups`) but not in-progress carts. Inspect those in `spree console` or through the Store API with the cart token.
- **Store/Seller API responses.** Use `curl` with a `pk_` key (Store) or the seller SDK.

## Gotchas

- The bundled spec for `endpoints`/`schema` reflects the **CLI's** Spree version, not necessarily the live server's — `spree api status` shows the bundled version. If an endpoint is missing from `endpoints` but exists on the server, the CLI may be older.
- `--api-key` on the command line leaks into shell history — prefer `SPREE_API_KEY` or a profile.
- Auto-minted project keys are read-only by design; a write returning 403 in a fresh project means you need an explicit scoped key, not a bug.
- Secret-key scopes can't be edited after creation. For different access, mint a new key and revoke the old one (`spree api-key revoke <id>`).
- Multi-store host? Pass `--store-id <store_…>` (sent as `X-Spree-Store-Id`).
- The CLI talks to a **running** server; it can't bootstrap one. Inside a project, ensure the dev stack is up (`spree dev`).
