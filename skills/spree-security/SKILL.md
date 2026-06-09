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
def self.whitelisted_ransackable_attributes
  %w[name slug created_at price]
end

def self.whitelisted_ransackable_associations
  %w[variants categories]
end

def self.whitelisted_ransackable_scopes
  %w[available in_stock]
end
```

Filtering on an un-allowlisted attribute returns 422 — the user can't exfiltrate `password_digest` via `q[password_digest_eq]=...`.

### Mass assignment

Same answer as Strong Parameters above. Plus:

```ruby
# Forbid setting protected attributes via mass assignment
class Spree::User
  attr_readonly :id, :encrypted_password
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
  policy.style_src   :self, :unsafe_inline   # admin needs this for Bootstrap; relax over time
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

Admin users authenticate via JWT and authorize via `Spree::Ability`. Customize:

```ruby
# backend/app/models/spree/ability_decorator.rb
module Spree::AbilityDecorator
  def initialize(user)
    super
    # Wholesale managers can read+update orders but never destroy
    if user.has_spree_role?('wholesale_manager')
      cannot :destroy, Spree::Order
      can [:read, :update], Spree::Order, channel: 'wholesale'
    end
  end
  Spree::Ability.prepend self
end
```

Defaults are restrictive — start from "can :read, :all" only if you're sure. Better: build up explicit grants per role.

### Payment method preferences

Payment methods (Stripe, Adyen, PayPal, etc.) store their gateway credentials as Spree preferences on the `Spree::PaymentMethod` record. These end up in `spree_payment_methods.preferences` as a serialized column.

Two precautions:

- **Set `Rails.application.credentials.secret_key_base`** consistently across all environments. Without it, the preference serializer's encryption is weakened or unstable.
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
@orders = current_store.orders.where(user: current_customer)

# ❌ — leaks orders from other stores
@orders = Spree::Order.where(user: current_customer)
```

The Store API does this automatically via the `Spree::Api::V3::Store::ResourceController` base class. Custom controllers must replicate the pattern.

### IDOR (Insecure Direct Object Reference)

Customer A trying to load `/api/v3/store/orders/or_<customerB_order>`. The base `ResourceController#scope` already restricts to `current_user`'s orders, so the lookup returns 404 — but if you override `find_resource` or write a custom controller, you must replicate the scoping.

Prefixed IDs don't help here — they're discoverable (sequential PKs under the hood). **Always authorize, never rely on ID opacity.**

### Rate limiting

Spree itself doesn't ship application-level rate limiting — that's the deployer's responsibility. Layer it at two places:

- **Rack::Attack** in the Rails app (per-IP, per-API-key, sliding windows). Throttle login and checkout endpoints aggressively.
- **CDN / load balancer** (Cloudflare, Fastly, AWS WAF) for the global ceiling.

```ruby
# config/initializers/rack_attack.rb
class Rack::Attack
  throttle('login attempts', limit: 5, period: 60) do |req|
    req.ip if req.path == '/api/v3/store/auth/login' && req.post?
  end

  throttle('api by key', limit: 600, period: 60) do |req|
    req.env['HTTP_X_SPREE_API_KEY']
  end
end
```

Tune the numbers to your traffic shape. Without rate limiting, a leaked publishable key can be used to scrape your full catalog at carrier speed.

### Dependency hygiene

```bash
bundle audit                # CVEs in Ruby gems
npm audit / pnpm audit      # CVEs in JS deps
brakeman                    # Rails static analysis
```

Run these in CI. The `spree/agent-skills` plugin doesn't ship a CI workflow — you wire these into your own.

### Admin upload safety

Admins can upload images, CSVs (imports), and theme assets. Risks:
- **Polyglot files** (image+JS) — sanitize uploads, set `Content-Type` strictly, serve from a different origin than the app domain (S3 + CloudFront, not `app.example.com/uploads/…`).
- **CSV formula injection** — sanitize fields starting with `=`, `+`, `-`, `@` before writing back to user-downloaded CSV exports.
- **ZIP slip in theme uploads** — Spree extracts theme ZIPs; old versions had path traversal bugs (`../../../../config/credentials.yml.enc`). Stay current; the extraction code is hardened in 5.5+.

### Sensitive logs

Filter sensitive params at the Rails level:

```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += %i[
  password password_confirmation
  api_key secret_key publishable_key
  card_number cvv cvc
  authentication_token reset_password_token
  stripe_token adyen_token
]
```

Without this, a `POST /admin/payments` with form data will write the secret_key to production.log. Real incident.

## A short checklist for a new Spree deployment

- [ ] Production credentials in encrypted credentials or environment, **not** in repo.
- [ ] `secret_key_base` set via `Rails.application.credentials` so payment method preferences serialize consistently.
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
- **Spree credentials docs:** Spree developer docs → "Authentication", "Authorization".
- **Webhook HMAC:** `spree-events-webhooks` skill.
- **API scopes:** `spree-api-v3` skill.
- **Payment data flow:** `spree-payments` skill.
