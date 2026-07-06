---
name: spree-cli
description: Use when calling the Spree Admin API from the command line or driving it programmatically as an agent — exploring endpoints, reading or mutating store data, and especially DEBUGGING (inspecting an order/product/customer, checking why a request failed, reproducing a 403/422). The `spree api` command group in `@spree/cli` is a `gh api`-style generic HTTP client: `spree api get|post|patch|delete <path>` plus offline discovery (`spree api endpoints`, `spree api schema`). Common phrasings include "spree api", "spree CLI", "call the admin API from the terminal", "spree api get", "inspect this order", "why is this Spree request failing", "list admin endpoints", "spree auth". For SDK/TypeScript integration use spree-typescript-sdk; for raw API protocol details use spree-api-v3.
---

# Spree CLI — Admin API from the terminal

`@spree/cli` ships a `spree api` command group: a generic Admin API v3 client modeled on `gh api`. It is the fastest way to inspect and manipulate store data from a terminal, and the most reliable way for an **agent to debug** — no SDK boilerplate, structured JSON in/out, and offline endpoint discovery.

It works against **any Spree 5.5+ instance**. Inside a local project it self-provisions a read-only key; for any other server you supply a key.

## When to reach for the CLI

- **Debugging** — "what state is order `ord_x` in?", "why did this 403?", "does this product have the variant I expect?". One command, JSON back, pipe to `jq`.
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
3. **Inside a local Spree project** (a dir with `docker-compose.yml`, dev stack running): zero config. The first `spree api` call mints a **read-only** key via the dev stack and saves it to `.spree/credentials.json` (gitignored). Just run commands.
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
spree api get /orders/ord_x8k2J9aQ --expand items,payments,fulfillments
spree api get /products --fields name,price          # id is always returned

# Write — JSON body inline, from @file, or '-' for stdin
spree api post /products -d '{"name":"Classic Tee","price":29.99}'
spree api patch /orders/ord_x8k2J9aQ/cancel
spree api post /orders/ord_x8k2J9aQ/refunds -d @refund.json
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
spree api get /orders/ord_x8k2J9aQ --expand payments,fulfillments | jq '.state, .payment_state'

# 2. If a write failed, find the endpoint's contract
spree api schema "PATCH /orders/{id}/cancel"

# 3. Re-run the write and read the error envelope verbatim
spree api patch /orders/ord_x8k2J9aQ/cancel
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

## Gotchas

- The bundled spec for `endpoints`/`schema` reflects the **CLI's** Spree version, not necessarily the live server's — `spree api status` shows the bundled version. If an endpoint is missing from `endpoints` but exists on the server, the CLI may be older.
- `--api-key` on the command line leaks into shell history — prefer `SPREE_API_KEY` or a profile.
- Auto-minted project keys are read-only by design; a write returning 403 in a fresh project means you need an explicit scoped key, not a bug.
- The CLI talks to a **running** server; it can't bootstrap one. Inside a project, ensure the dev stack is up (`spree dev`).
