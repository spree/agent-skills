---
name: spree-extensions
description: Use when the user wants to install a specific third-party Spree gem (Stripe, Adyen, PayPal, i18n, search, social login, etc.), build their own Spree extension to share across apps, or swap a core Spree service via `Spree.dependencies`. Common phrasings include "add Stripe", "install spree_X", "what payment gateways", "create a Spree extension", "build a gem for Spree", "spree_dev_tools", "Spree.dependencies", "service swap". For deciding which customization pattern to use, see the `spree-customization` skill first — extensions are the last two rows of its decision tree and most single-app work doesn't need one.
---

# Spree Extensions

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

This skill covers two distinct things: **installing a third-party Spree gem** (`spree_stripe`, `spree_i18n`, etc.) and **building your own extension** to share across multiple Spree apps. For single-app customization (the 99% case), use the `spree-customization` skill to find the right pattern — usually it's a subscriber, dependency injection, or a decorator, not a gem.

Spree extensions are Rails engines packaged as gems. They mount into the host Rails app the same way Spree itself does. Adding one is a Gemfile entry + a generator run + a migrate.

## Installing an extension

Three steps. Same pattern for every Spree extension. Requires the ejected dev stack: fresh `create-spree-app` projects run a prebuilt image where `backend/` is not mounted into the container — run `spree eject` once first to switch to the bind-mounted dev compose.

```bash
# 1. Add to Gemfile
echo "gem 'spree_reviews'" >> backend/Gemfile

# 2. Install the gem
spree bundle install

# 3. Run the extension's install generator
spree rails g spree_reviews:install
```

The install generator is a **convention** — every Spree extension provides one at `<gem_name>:install`. It typically:
- Copies migrations into your app (`db/migrate/<ts>_<name>.<gem_name>.rb`)
- Adds an initializer (`config/initializers/<gem_name>.rb`)
- Registers itself with `Spree.dependencies` or `Spree.subscribers` if needed
- Sometimes copies admin views or installs admin slot extensions

After the install generator runs, apply migrations and restart:

```bash
spree migrate
spree dev                 # Ctrl+C the running one first; `spree restart` does not reload Gemfile changes
```

## Extension gems bundled with `create-spree-app`

When you scaffold via `npx create-spree-app`, the resulting Gemfile already includes three payment providers plus i18n:

| Gem | What it provides |
|---|---|
| `spree_stripe` | Stripe checkout — payment methods, sessions, webhooks |
| `spree_adyen` | Adyen — drop-in component, methods, webhooks |
| `spree_paypal_checkout` | PayPal Smart Buttons checkout |
| `spree_i18n` | Translations for the admin UI across many locales |

These are commercially-significant integrations. If you remove one from your Gemfile, also strip its admin Settings → Payment methods entry. If you add one to an existing project that wasn't created with `create-spree-app`, follow the standard three-step install above.

## Integrations and community extensions

The maintained integrations list is at `https://spreecommerce.org/docs/integrations` (source: `docs/integrations/integrations.mdx`) — it currently covers Stripe, Adyen, PayPal, RazorPay, Avalara (`spree_avatax`), Meilisearch, Google Analytics / Tag Manager, and Klaviyo.

Beyond that there is a long tail of **legacy community extensions** from the Spree 4.x era — `spree_print_invoice`, `spree_volume_pricing`, `spree_products_qa`, `spree_searchkick`, `spree_easypost`, `spree_shipstation`, `spree_social`, `spree_reviews`, `spree_taxjar`, `spree-product-assembly`, `spree_related_products`, and others. These are not in the current docs and many are unmaintained — before adding one, verify against its GitHub repo that it supports your Spree 5.x version (check the gemspec's `spree_core` constraint and the CHANGELOG), and expect to fork/patch.

Compatibility is per-extension-version — when you upgrade Spree, check each extension's CHANGELOG before bumping.

## `spree_dev_tools` — first install on any project

`spree_dev_tools` packages Spree's test stack for host apps (RSpec, Factory Bot, Capybara, DatabaseCleaner) and loads the factories and helpers that ship inside `spree_core` — Spree's own gems wire those dependencies directly and don't use this gem. Projects scaffolded with `create-spree-app` already include it in the `:development, :test` group; add it yourself only on apps that weren't:

```ruby
# backend/Gemfile
group :development, :test do
  gem 'spree_dev_tools'
end
```

```bash
spree bundle install
spree rails g spree_dev_tools:install   # copies helpers into spec/support/ and enables loading them from rails_helper.rb
```

What it adds:
- Factory Bot factories for every Spree model (loaded via `require 'spree/testing_support/factories'`)
- The `'API v3 Store'` shared context used by API specs (additionally requires `require 'spree/api/testing_support/v3/base'` in the spec file — the install generator does not wire it)
- `stub_authorization!` for admin controller specs

See the `spree-testing` skill for usage patterns.

## Building your own extension

Skip this section unless you're confident your customization belongs as a reusable gem. For one-app changes, put your code directly in `backend/app/` and use subscribers + dependency injection.

If you do need to build an extension:

```bash
gem install spree_extension       # the Spree extension scaffolder
spree-extension simple_sales      # generates ./spree_simple_sales/
cd spree_simple_sales
```

The scaffold produces:

- `lib/spree_simple_sales/engine.rb` — the Rails engine declaration
- `lib/generators/spree_simple_sales/install/install_generator.rb` — the convention `<name>:install` generator
- `app/` — where your models, controllers, services live (same `Spree::` namespacing rules)
- `db/migrate/` — your migrations (copied into the host app by the install generator)

The engine declaration registers dependencies, subscribers, and admin UI extensions:

```ruby
# lib/spree_simple_sales/engine.rb
module SpreeSimpleSales
  class Engine < ::Rails::Engine
    engine_name 'spree_simple_sales'

    initializer 'spree.simple_sales.subscribers' do
      Spree.subscribers << SpreeSimpleSales::OrderSubscriber
    end

    initializer 'spree.simple_sales.dependencies' do
      Spree.dependencies do |deps|
        deps.cart_add_item_service = 'SpreeSimpleSales::Cart::AddItem'
      end
    end
  end
end
```

For the full tutorial — decorators, controller extensions, model decorators, route additions, testing — see `docs/developer/contributing/creating-an-extension.mdx`.

## Swapping a core service is NOT an extension

A common confusion: "I want my own version of an existing Spree service — should I build an extension?" Almost always no. Spree exposes 70+ swappable core injection points via `Spree.dependencies` (or `Spree.<name> = ...` directly) plus 300+ API injection points (serializers, finders, per-endpoint services) via `Spree.api`. You subclass the default, register the override in `config/initializers/spree.rb`, and Spree calls your service everywhere. No gem packaging required.

```ruby
# config/initializers/spree.rb
Spree.cart_add_item_service = MyApp::Cart::AddItem
```

See the **`spree-dependencies`** skill for the full pattern, the catalog of injection points, and the introspection rake tasks (`spree:dependencies:list`, `spree:dependencies:overrides`, `spree:dependencies:validate`).

Extensions become the right shape when you want to **share** customization (including dependency overrides) across multiple Spree apps — the extension's engine declaration registers the overrides at boot, so any host app that bundles the gem gets the swap automatically.

## When an extension is and isn't the right shape

Extensions are the wrong tool for most single-app customization. They make sense when:

- You maintain **multiple Spree apps** and want to share customization between them.
- You're building **something the Spree community would benefit from** (an open-source gem).

For one app: put the code directly in `app/` (subscribers, decorators, services, controllers). No extension overhead. See the `spree-customization` skill for the full routing table; this skill picks up at "yes, I really want a gem."

## Common gotchas with extensions

- **Migrations don't auto-apply.** Each install generator copies migrations into `backend/db/migrate/`; you must run `spree migrate` after. `spree upgrade` bundle-updates every spree-prefixed gem (extensions included), but its migration-install step (`spree:install:migrations`) only covers Spree core — and `spree migrate` has the same limitation. After an extension version bump, re-run the extension's install generator (or `spree rails railties:install:migrations`) to copy any new extension migrations, then `spree migrate` to apply them.
- **Initializers can drift across upgrades.** When you bump an extension version, the initializer it generated may need new config keys. Check the extension's CHANGELOG before upgrading.
- **Extensions ship migrations with the engine name as a suffix** in the host app (e.g. `db/migrate/20260427130753_create_spree_paypal_checkout_orders.spree_paypal_checkout.rb`; Spree core's own migrations use `.spree.rb`). The suffix records which engine a migration was copied from: the install tasks use it to skip already-copied migrations, and Spree's boot-time check uses it to warn when an engine's migrations are missing. Don't rename them.
- **Decorators in extensions** can collide with decorators in your app. If two reopen `Spree::Order` and define a method with the same name, last-loaded wins (load order is alphabetical by gem name). Avoid decorating the same model in two places.
- **Engine-level subscribers** registered in an `initializer 'spree.<name>.subscribers'` block are appended once at boot. Subscriber code hot-reloads — Spree resets and re-registers all subscribers on each code reload. Only changes to the registration itself (the engine initializer) need a server restart.

## Where to read further

- **Integrations catalog:** https://spreecommerce.org/docs/integrations (source: `docs/integrations/integrations.mdx`)
- **Building extensions tutorial:** `docs/developer/contributing/creating-an-extension.mdx` (full walkthrough — generates a sale-price extension)
- **Customization patterns:** `docs/developer/customization/quickstart.mdx`, `docs/developer/customization/decorators.mdx`, `docs/developer/customization/dependencies.mdx`
- **Events for sync/notify scenarios:** the `spree-events-webhooks` skill
