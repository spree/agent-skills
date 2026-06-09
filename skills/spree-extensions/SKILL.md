---
name: spree-extensions
description: Use when the user wants to add Spree functionality via a third-party gem (Stripe, Adyen, PayPal, i18n, etc.), build their own Spree extension, or decide between extension vs subscriber vs decorator for a customization. Common phrasings include "add Stripe", "install spree_X", "what payment gateways", "create a Spree extension", "build a gem for Spree", "decorator vs extension". Provides the install convention, the customization decision tree, and known official extensions.
---

# Spree Extensions

Spree extensions are Rails engines packaged as gems. They mount into the host Rails app the same way Spree itself does. The Spree ecosystem has official extensions (payments, i18n, dev tools) and a long tail of community ones.

## The customization decision tree (where extensions fit)

Always prefer the least-invasive option that solves the problem:

1. **Configuration / preferences** — Many things are just config. Check `Spree::Config[:my_key]` and the admin Settings UI first.
2. **Events + subscribers** — Side effects that react to lifecycle events. See the `spree-events-webhooks` skill.
3. **Service swap (dependencies)** — Replace a specific behavior (cart add, tax calculation) by subclassing the service and registering it. See the `spree-project` skill.
4. **Install an extension (gem)** — Pull in pre-built functionality (payment gateways, search providers, integrations).
5. **Build your own extension (gem)** — Functionality you want to reuse across multiple Spree apps you maintain.
6. **Decorator** — Last resort. Tightly couples your code to Spree internals; makes upgrades harder.

Extensions are option 4 — **pulling in someone else's gem**. Building your own (option 5) makes sense when you have multiple Spree projects sharing customization. For a single project, prefer subscribers + service swaps.

## Installing an extension

Three steps. Same pattern for every official Spree extension.

```bash
# 1. Add to Gemfile
echo "gem 'spree_stripe'" >> backend/Gemfile

# 2. Install the gem
spree bundle install

# 3. Run the extension's install generator
spree rails g spree_stripe:install
```

The install generator is a **convention** — every Spree extension provides one at `<gem_name>:install`. It typically:
- Copies migrations into your app (`db/migrate/<ts>_<name>.spree.rb`)
- Adds an initializer (`config/initializers/<gem_name>.rb`)
- Registers itself with `Spree.dependencies` or `Spree.subscribers`
- Sometimes copies admin views or registers admin slot extensions

After the install generator runs, run migrations:

```bash
spree migrate
```

Restart Rails so the new code loads:

```bash
spree restart
```

## Official extensions

These are maintained by the Spree core team.

| Gem | Purpose |
|---|---|
| `spree_stripe` | Stripe payments — checkout sessions, hosted forms, webhooks |
| `spree_adyen` | Adyen payments — drop-in, webhooks, multi-method |
| `spree_paypal_checkout` | PayPal Smart Buttons checkout |
| `spree_i18n` | Translations for the admin UI (40+ locales) |
| `spree_dev_tools` | Dev-only — better factories, model graph visualization, console helpers. Add to `:development, :test` groups. |
| `spree_multi_store` | Multi-store catalog management (lets one product belong to multiple stores in 6.0). Without this, 6.0 enforces single-store ownership. |

Some extensions have CHANGELOG entries that document breaking changes per version. Check the extension's GitHub repo when you upgrade Spree — extension compatibility is per-version.

## Adding `spree_dev_tools` for development

This is the most common "first extension" — speeds up your development inner loop significantly:

```ruby
# backend/Gemfile
group :development, :test do
  gem 'spree_dev_tools'
end
```

```bash
spree bundle install
spree restart
```

No install generator needed — it auto-wires its dev helpers. Provides:
- `Spree::TestingSupport::Factories.find` — load factories from anywhere
- Console aliases and helpers
- Better error messages on missing fixtures

## Configuring an extension

Most extensions add an initializer to `backend/config/initializers/<gem_name>.rb` during install. Examples:

```ruby
# backend/config/initializers/spree_stripe.rb (after spree_stripe:install)
SpreeStripe.configure do |config|
  config.publishable_key = ENV['STRIPE_PUBLISHABLE_KEY']
  config.secret_key      = ENV['STRIPE_SECRET_KEY']
  config.webhook_secret  = ENV['STRIPE_WEBHOOK_SECRET']
end
```

API keys belong in `backend/.env` (gitignored), not in the initializer file directly. The initializer reads them from ENV.

## Building your own extension

Skip this section unless you maintain multiple Spree projects that share customization. For a single app, put your code directly in `backend/app/` and use subscribers/service swaps.

If you do need to build one:

```bash
gem install spree_cmd       # the Spree extension generator (separate from spree:install)
spree extension my_thing    # scaffolds the gem structure
```

The scaffold gives you:
- `lib/spree_my_thing/engine.rb` — the Rails engine declaration
- `lib/generators/spree_my_thing/install/install_generator.rb` — the convention `<name>:install` generator
- `app/` — where your models, controllers, services live (same Spree:: namespacing rules)
- `db/migrate/` — migrations copied into the host app via `spree:install:migrations`

The engine declaration is where you register dependencies and subscribers:

```ruby
# lib/spree_my_thing/engine.rb
module SpreeMyThing
  class Engine < ::Rails::Engine
    engine_name 'spree_my_thing'

    initializer 'spree.my_thing.subscribers' do
      Spree.subscribers << SpreeMyThing::OrderSubscriber
    end

    initializer 'spree.my_thing.dependencies' do
      Spree.dependencies do |deps|
        deps.cart_add_item_service = 'SpreeMyThing::Cart::AddItem'
      end
    end
  end
end
```

## Decision: extension vs subscriber vs decorator

The most common confusion is between "should I write a subscriber, or build an extension?" Honest distinction:

| Want to... | Use |
|---|---|
| Sync orders to one external service | Subscriber in `backend/app/subscribers/` |
| Add a payment gateway | Extension (existing or new — most major gateways have official ones) |
| Customize how a cart calculates | Service swap via `Spree.dependencies` |
| Add a custom field to Products | `Spree::Metafields` (configuration, not extension) |
| Add a new admin page | Either `defineDashboardPlugin` in your own code (see `spree-dashboard` skill) or an extension if you maintain it across multiple apps |
| Replace search backend | Extension already exists for Meilisearch; for others, write a SearchProvider service |

If the customization is **specific to one app's business**, don't build an extension — it's overhead. If it's **reusable across multiple apps** OR **a feature the wider Spree community would benefit from**, then yes, an extension is the right shape.

## Common gotchas with extensions

- **Migrations don't auto-apply.** Each install generator copies migrations into `backend/db/migrate/`; you must run `spree migrate` after. The `spree upgrade` command handles this for Spree itself but not for extensions — each extension's upgrade is manual.
- **Initializers can drift across upgrades.** When you bump an extension version, the initializer it generated may need new config keys. Check the extension's CHANGELOG.
- **Extensions ship migrations with `.spree.rb` extension** in the host app (e.g. `db/migrate/20260101000000_create_spree_stripe_charges.spree.rb`). The `.spree` infix marks them as "copied from a gem" so they survive `db:schema:dump` correctly. Don't rename them.
- **Decorators in extensions** can collide with decorators in your app. If both reopen `Spree::Order` and define a method with the same name, last-loaded wins (load order is alphabetical by gem). Avoid decorating the same model in two places.

## Where to read further

- **Extension list:** `https://spreecommerce.org/docs/developer/extensions` for the official catalog.
- **Building extensions:** `backend/node_modules/@spree/docs/dist/developer/customization/extensions.mdx`
- **Customization patterns reference:** the `spree-project` skill has the full decision tree.
