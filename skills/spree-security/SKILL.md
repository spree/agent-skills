---
name: spree-security
description: Use when the user is hardening a Spree app, responding to a security finding, reviewing a PR for security issues, setting up secrets management, configuring CSP/CORS, or asking about Spree-specific security (CanCanCan scopes, encrypted preferences, webhook HMAC, PCI scope). Covers both standard Rails security practices (CSRF, mass assignment, SQL injection, secrets in repo) AND the Spree-specific pieces (publishable vs secret keys, scope enforcement, SSRF on webhooks, CanCanCan abilities). Common phrasings include "Spree security", "CSP", "CORS", "secret key", "leaked key", "SQL injection", "Strong Params", "CanCanCan", "PCI", "webhook signature", "SSRF".
---

# Spree Security

Spree inherits Rails' security model and adds an e-commerce attack surface (payment data, customer PII, admin credentials, webhook endpoints). This skill covers both.

## The threat model in three sentences

1. The **storefront** is internet-facing — every visitor can hit it. Threats: XSS via product content, IDOR on orders, abuse of cart endpoints.
2. The **admin** is staff-only but credentials get phished — assume someone is going to log in as a regular admin sometimes. Threats: privilege escalation, broad data exfiltration, malicious extension upload.
3. The **payments path** touches money and PCI. Threats: card data leaking into logs/DB, gateway response tampering, refund abuse.

Everything below maps to one of these.

## Standard Rails security (don't skip these)

### Secrets — not in the repo

Production credentials live in `config/credentials.yml.enc` (Rails encrypted credentials) or environment variables. **Never** check raw secrets into git.

```bash
# Read credentials
EDITOR="code --wait" bin/rails credentials:edit --environment production

# Look up
Rails.application.credentials.stripe[:secret_key]
```

If a secret leaks into a commit (even on a private repo): **rotate immediately**, then rewrite history (`git filter-repo`, `bfg`). Rotation order:
1. Rotate the key in the provider (Stripe, AWS, etc.).
2. Update credentials/env.
3. Deploy.
4. Then clean history. The order matters — clean history first and the leaked key keeps working until rotation.

Spree's `spree/agent-skills` plugin (installed via `/plugin install spree@spree` in Claude Code) ships a PostToolUse hook that warns when Claude appears to be writing a known-shape secret (Stripe live keys, AWS keys, GitHub PATs, OpenAI/Anthropic keys, plaintext sensitive env names). It's a tripwire, not a substitute for review.

### Strong Parameters

Always whitelist params in controllers; never `params.permit!` or splat user input into mass-assignment:

```ruby
# ✅
def permitted_params
  params.permit(:name, :description, :slug, metadata: {})
end

# ❌ — accepts anything, including admin_id / is_admin / etc.
Spree::Product.create!(params[:product])
```

Spree v3 controllers use flat `params.permit(...)` — no nested wrapping. See `spree-api-v3` and `spree-resource` for the convention.

### SQL injection

Use parameterized queries:

```ruby
# ✅
Spree::Product.where('price > ?', user_value)
Spree::Product.where(price: user_value)

# ❌ — string interpolation
Spree::Product.where("price > #{user_value}")
```

Ransack is safe by default — but only filters on **allowlisted** attributes. Declare per model:

```ruby
self.whitelisted_ransackable_attributes = %w[name slug created_at price]
self.whitelisted_ransackable_associations = %w[variants categories]
self.whitelisted_ransackable_scopes = %w[available in_stock]
```

Filtering on an un-allowlisted attribute is silently ignored — Ransack's default `ignore_unknown_conditions: true` drops the unknown condition (Spree's v3 controllers call `ransack`, not `ransack!`), so the user can't exfiltrate `password_digest` via `q[password_digest_eq]=...`. But there's no error signal either: the response is 200 and that filter simply doesn't apply, while any valid conditions in the same query still do.

### Mass assignment

Same answer as Strong Parameters above — `params.permit` is the mass-assignment defense; nothing extra is needed on the model.

Do **not** reach for `attr_readonly` here: it blocks *all* writes after creation, not just mass assignment. With Rails 7.1+ defaults, assigning a readonly attribute on a persisted record raises `ActiveRecord::ReadonlyAttributeError` (on older defaults the write is silently dropped). Putting it on `encrypted_password` breaks Devise password changes and password resets for every existing user. Reserve `attr_readonly` for genuinely immutable columns:

```ruby
class Spree::Order < Spree.base_class
  attr_readonly :number  # generated once, never changes
end
```

### CSRF

Rails handles CSRF for browser sessions automatically (`protect_from_forgery with: :exception`). API controllers skip CSRF (token auth replaces it). **Don't disable CSRF on form-rendering controllers** — that's how XSS becomes RCE-via-admin.

### CSP (Content Security Policy)

Lock down what scripts/styles/images can load:

```ruby
# config/initializers/content_security_policy.rb
Rails.application.config.content_security_policy do |policy|
  policy.default_src :self
  policy.font_src    :self, :https, :data
  policy.img_src     :self, :https, :data
  policy.script_src  :self, 'https://js.stripe.com'
  policy.style_src   :self, :unsafe_inline   # the Rails admin's inline styles need this; relax over time
  policy.connect_src :self, 'https://api.stripe.com'
end
```

The storefront should have a stricter policy than the admin. If your storefront uses a separate domain (Next.js consuming the Store API), set CSP on that app, not on the Rails app.

### XSS

Rails auto-escapes ERB output. Where you raw-render user content (rich text descriptions, product copy from CSV import), sanitize:

```ruby
ActionController::Base.helpers.sanitize(product.description, tags: %w[p br strong em a ul li], attributes: %w[href])
```

Sanitize before storing OR before rendering, but pick one and be consistent.

### CORS

Spree also ships an admin-manageable CORS allowlist for the Admin API — per-store `Spree::AllowedOrigin` records (validated to be origin-only http(s) URLs), managed in the dashboard under Settings → Allowed origins or via the Admin API (`/api/v3/admin/allowed_origins`). The spree-starter app's `config/initializers/cors.rb` consults it dynamically (cached, exact-match in production) for `/api/v3/admin/*` with `credentials: true` — so admin/dashboard origins belong in that allowlist, not in hand-written `allow` blocks. For your storefront origin on `/api/v3/store/*`, add a static `allow` block as shown below.

If your storefront is a separate origin (typical for Next.js):

```ruby
# config/initializers/cors.rb
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins 'https://my-storefront.com', /https:\/\/.*\.my-storefront\.com/
    resource '/api/v3/store/*',
             headers: :any,
             methods: %i[get post put patch delete options],
             expose: %w[x-spree-api-version]
  end
end
```

**Never `origins '*'` in production** for paths that accept credentials. Allowlist explicit storefront origins.

## Spree-specific security

### Publishable key vs secret key

```
pk_*  — Publishable key.  Safe to ship in client-side code.  Identifies store, permits public Store API endpoints only.
sk_*  — Secret key.       Server-to-server only. Never bundle into mobile apps or browser JS.
```

A leaked `pk_` is annoying but not catastrophic (rate limit, rotate). A leaked `sk_` is a breach — rotate immediately and audit `Spree::WebhookDelivery`/admin audit logs for unauthorized activity.

### Scopes on secret keys

When creating a secret key for an integration (Settings → API keys → Create secret key), grant **only the scopes the integration needs**. Don't hand out `write_all` to every app.

```
Need to sync orders out? → read_orders
Need to update inventory? → write_stock
Need to create refunds? → write_refunds
```

If the integration is later compromised, the blast radius is limited to what its scopes permit. The full scope list is in the `spree-api-v3` skill.

### CanCanCan abilities (admin JWT auth)

Admin users authenticate via JWT and authorize via `Spree::Ability`, which builds permissions from Permission Sets assigned to the user's roles. Customize by defining a permission set and assigning it to a role:

```ruby
# app/models/my_app/permission_sets/wholesale_orders.rb
module MyApp
  module PermissionSets
    class WholesaleOrders < Spree::PermissionSets::Base
      def activate!
        # Wholesale managers can read+update wholesale orders but never destroy
        can [:read, :update], Spree::Order, channel: { code: 'wholesale' }
        cannot :destroy, Spree::Order
      end
    end
  end
end
```

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.permissions.assign(:wholesale_manager, [
    Spree::PermissionSets::DashboardDisplay,
    MyApp::PermissionSets::WholesaleOrders
  ])
end
```

(The role itself must exist: `Spree::Role.find_or_create_by(name: 'wholesale_manager')`.)

Defaults are restrictive — users with no roles get only `Spree::PermissionSets::DefaultCustomer`. Build up explicit grants per role by composing built-in sets (`OrderManagement`, `ProductDisplay`, `StockManagement`, …) with custom ones; don't hand every role `SuperUser`.

### Payment method preferences

Payment methods (Stripe, Adyen, PayPal, etc.) store their gateway credentials as Spree preferences on the `Spree::PaymentMethod` record. These end up in `spree_payment_methods.preferences` as a serialized column.

Two precautions:

- **Gateway preferences are stored UNENCRYPTED** as serialized YAML in `spree_payment_methods.preferences` — treat the database and its backups as containing live secrets. Two pieces of key material do matter elsewhere: keep `secret_key_base` stable, because secret API key authentication HMAC-SHA256s tokens with it (rotating it invalidates every `sk_` key; publishable `pk_` keys are unaffected), and configure `active_record_encryption` credentials consistently, because webhook endpoint secrets are encrypted with ActiveRecord::Encryption when those keys are present.
- **Use the admin UI to enter live keys** (Settings → Payments → edit method), not seed scripts or direct DB writes. Treat preference rows as containing live secrets; back up encrypted.

If a gateway secret leaks (committed to git, exposed in a log, copied to a chat), rotate at the provider first (Stripe dashboard, Adyen back office), then update the admin preference, then audit recent transactions.

### Webhook signature verification (HMAC)

Outbound webhooks are signed with HMAC-SHA256. **Receivers MUST verify** — see the `spree-events-webhooks` skill for the exact algorithm + timing-safe comparison + replay rejection. Spree won't tell you if your receiver is unverified; that's the receiver's responsibility.

### Webhook SSRF protection

Inbound URL validation: in production, webhook endpoint URLs are checked against private IP ranges (RFC 1918, loopback, link-local) via `ssrf_filter`. Admin can't (easily) make Spree POST to `http://internal-erp.localhost:8080` from outside the trusted network.

In development this is disabled so localhost webhooks work. **Never run development settings in production**; this gap is a real SSRF in deployed apps if you copy `Rails.env.development?` checks blindly.

### PCI DSS scope

Spree never stores raw PANs. Payment data flows through tokenization at the gateway:
- **Stripe** (via `spree_stripe`) — card data goes browser→Stripe directly via Stripe Elements / Checkout. Spree only sees a payment-method token.
- **Adyen** (via `spree_adyen`) — same pattern; the drop-in component returns a tokenized reference.
- **`Spree::CreditCard`** stores last4, brand, exp month/year — never the full PAN, never the CVC.

PCI scope reduction relies on this. **Don't add fields to `spree_credit_cards` that hold raw card data.** If you find yourself wanting to, it's a sign you're building the wrong integration pattern — gateway tokenization is the right answer.

If a regulator asks for your PCI SAQ:
- Using only tokenizing gateways with hosted fields: SAQ A-EP or SAQ A.
- Self-collecting card data anywhere: SAQ D (full audit). Don't go here.

### Customer-data isolation

Multi-store stores share a database. **Always scope queries through `current_store`**:

```ruby
# ✅
@orders = current_store.orders.where(user: current_user)

# ❌ — leaks orders from other stores
@orders = Spree::Order.where(user: current_user)
```

The Store API does this automatically via the `Spree::Api::V3::Store::ResourceController` base class. Custom controllers must replicate the pattern.

### IDOR (Insecure Direct Object Reference)

Customer A trying to load `/api/v3/store/orders/or_<customerB_order>`. The Store API's `OrdersController#scope` restricts to the current user's orders (or the guest order token), so the lookup returns 404 — but if you override `scope`/`find_resource` or write a custom controller, you must replicate that scoping.

Prefixed IDs don't help here — they're discoverable (sequential PKs under the hood). **Always authorize, never rely on ID opacity.**

### Rate limiting

Spree's v3 API ships application-level rate limiting out of the box, built on Rails' `rate_limit` and backed by `Rails.cache`:

- **All v3 endpoints**: 300 requests / 60s, keyed by the `X-Spree-Api-Key` header (falling back to client IP when no key is sent).
- **Auth endpoints** (per IP, to stop brute force): login 5/60s, registration 3/60s, token refresh and logout 10/60s, password reset 3/60s. Admin login/refresh and invitation acceptance get the same treatment.

Exceeding a limit returns `429` with error code `rate_limit_exceeded` and `Retry-After` / `X-RateLimit-*` headers. All limits are tunable via `Spree::Api::Config` preferences: `rate_limit_per_key`, `rate_limit_window`, `rate_limit_login`, `rate_limit_register`, `rate_limit_refresh`, `rate_limit_password_reset`. One operational caveat: counters live in `Rails.cache`, so multi-process deployments need a shared cache store (Redis/Memcached) — with an in-process store each worker counts independently.

Still layer defense in depth on top:

- **Rack::Attack** for endpoints the built-in limits don't cover (Rails admin, storefront) and any custom throttling rules — don't duplicate the v3 auth throttles, they're already enforced.
- **CDN / load balancer** (Cloudflare, Fastly, AWS WAF) for the global ceiling and volumetric attacks.

Tune the numbers to your traffic shape — the defaults cap a leaked publishable key at 300 req/min, but a scraper rotating IPs without a key still warrants the CDN layer.

### Dependency hygiene

```bash
bundle audit                # CVEs in Ruby gems
npm audit / pnpm audit      # CVEs in JS deps
brakeman                    # Rails static analysis
```

Run these in CI. The `spree/agent-skills` plugin doesn't ship a CI workflow — you wire these into your own.

### Admin upload safety

Admins can upload images and CSVs (imports). Risks:
- **Polyglot files** (image+JS) — sanitize uploads, set `Content-Type` strictly, serve from a different origin than the app domain (S3 + CloudFront, not `app.example.com/uploads/…`).
- **CSV formula injection** — sanitize fields starting with `=`, `+`, `-`, `@` before writing back to user-downloaded CSV exports.

### Sensitive logs

Rails param filtering is already largely in place: Spree core registers `filter_parameters` for `:password`, `:number`, `:verification_value`, `:client_secret`, `:refresh_token` etc., and the spree-starter app ships partial-match filters (`:passw, :email, :secret, :token, :_key, :crypt, :salt, :cvv, :cvc, …`) — partial matching means `:secret` already catches `secret_key`/`stripe_secret_key` and `:_key` catches `api_key`/`publishable_key`.

Treat this as defense-in-depth, not a solved problem: extend the list for any custom param name your app introduces that the partial matches don't cover, and verify what's actually filtered:

```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += %i[card_number my_custom_credential]

# Verify in console:
Rails.application.config.filter_parameters
```

A param name that slips through the filters gets written verbatim to production.log by any form POST that carries it.

## A short checklist for a new Spree deployment

- [ ] Production credentials in encrypted credentials or environment, **not** in repo.
- [ ] `secret_key_base` stable and managed via credentials — secret API keys are HMAC-digested with it (rotating it invalidates every `sk_` key) and it is the fallback JWT signing secret. Webhook endpoint secrets use ActiveRecord::Encryption, whose keys (`active_record_encryption.*`) must also live in credentials.
- [ ] CORS allowlist matches your storefront origin(s) only.
- [ ] CSP defined and not `default_src 'unsafe-inline'` everywhere.
- [ ] Brakeman + bundle audit + pnpm audit in CI.
- [ ] Rack::Attack rules for login + checkout endpoints.
- [ ] Webhook receiver verifies HMAC + checks replay timestamp.
- [ ] All staff admin users on real-name accounts with role-appropriate abilities (no shared "admin@" accounts).
- [ ] Secret keys for integrations granted minimum scopes.
- [ ] Filtered parameters configured for logs.
- [ ] Database backups are encrypted, restorable, and not stored next to the database.
- [ ] HTTPS-only (`config.force_ssl = true`).
- [ ] `Secure` + `HttpOnly` + `SameSite=Lax` on auth cookies.

## Where to read further

- **Rails Security Guide:** https://guides.rubyonrails.org/security.html — read it cover to cover at least once.
- **OWASP Top 10:** https://owasp.org/www-project-top-ten/ — annual update; the categories don't change much but the examples do.
- **Spree credentials docs:** Spree developer docs → "Authentication", "Permissions".
- **Webhook HMAC:** `spree-events-webhooks` skill.
- **API scopes:** `spree-api-v3` skill.
- **Payment data flow:** `spree-payments` skill.
