---
name: spree-extensions
description: Use when the user wants to install a specific third-party Spree gem (Stripe, Adyen, PayPal, i18n, search, social login, etc.), build their own Spree extension to share across apps, or swap a core Spree service via `Spree.dependencies`. Common phrasings include "add Stripe", "install spree_X", "what payment gateways", "create a Spree extension", "build a gem for Spree", "spree_dev_tools", "Spree.dependencies", "service swap". For deciding which customization pattern to use, see the `spree-customization` skill first — extensions are option 4 on a 6-option decision tree and most single-app work doesn't need one.
---

# Spree Extensions

This skill covers two distinct things: **installing a third-party Spree gem** (`spree_stripe`, `spree_i18n`, etc.) and **building your own extension** to share across multiple Spree apps. For single-app customization (the 99% case), use the `spree-customization` skill to find the right pattern — usually it's a subscriber, dependency injection, or a decorator, not a gem.

Spree extensions are Rails engines packaged as gems. They mount into the host Rails app the same way Spree itself does. Adding one is a Gemfile entry + a generator run + a migrate.

## Installing an extension

Three steps. Same pattern for every Spree extension.

```bash
# 1. Add to Gemfile
echo "gem 'spree_i18n'" >> backend/Gemfile

# 2. Install the gem
spree bundle install

# 3. Run the extension's install generator
spree rails g spree_i18n:install
```

The install generator is a **convention** — every Spree extension provides one at `<gem_name>:install`. It typically:
- Copies migrations into your app (`db/migrate/<ts>_<name>.spree.rb`)
- Adds an initializer (`config/initializers/<gem_name>.rb`)
- Registers itself with `Spree.dependencies` or `Spree.subscribers` if needed
- Sometimes copies admin views or installs admin slot extensions

After the install generator runs, apply migrations and restart:

```bash
spree migrate
spree restart
```

## Payment-provider gems bundled with `create-spree-app`

When you scaffold via `npx create-spree-app`, the resulting Gemfile already includes:

| Gem | What it provides |
|---|---|
| `spree_stripe` | Stripe checkout — payment methods, sessions, webhooks |
| `spree_adyen` | Adyen — drop-in component, methods, webhooks |
| `spree_paypal_checkout` | PayPal Smart Buttons checkout |
| `spree_i18n` | Translations for the admin UI across many locales |

These are commercially-significant integrations. If you remove one from your Gemfile, also strip its admin Settings → Payment methods entry. If you add one to an existing project that wasn't created with `create-spree-app`, follow the standard three-step install above.

## Community extensions catalog

The authoritative list of community extensions is at `docs/developer/customization/extensions.mdx` (also at https://spreecommerce.org/docs/developer/customization/extensions). Categories covered:

- **Internationalization** — `spree_i18n` (multi-language admin), `flowcommerce_spree` (cross-border)
- **Order management** — `spree_print_invoice`
- **Marketing** — `spree_mailchimp_ecommerce`
- **Product features** — `spree_volume_pricing`, `spree_products_qa`
- **Search** — `spree_searchkick` (Elasticsearch via Searchkick)
- **Shipping** — `spree_easypost`, `spree_shipstation`
- **Social** — `spree_social` (Facebook/Twitter/etc login), `spree_reviews`
- **Tax** — `spree_avatax_official`, `spree_taxjar`
- **Upselling** — `spree-product-assembly` (bundles), `spree_related_products`
- **Customer service** — `spree_gladly`

Each extension links to its GitHub repo. Compatibility is per-extension-version — when you upgrade Spree, check each extension's CHANGELOG before bumping.

## `spree_dev_tools` — first install on any project

`spree_dev_tools` provides factories and helpers used by every Spree gem's own test suite. Add it to the development and test groups:

```ruby
# backend/Gemfile
group :development, :test do
  gem 'spree_dev_tools'
end
```

```bash
spree bundle install
```

What it adds:
- Factory Bot factories for every Spree model (`Spree::TestingSupport::Factories`)
- The `'API v3 Store'` shared context used by API specs
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

A common confusion: "I want my own version of an existing Spree service — should I build an extension?" Almost always no. Spree exposes 64 swappable core services + 233 API injection points via `Spree.dependencies`. You subclass the default, register the override in `config/initializers/spree.rb`, and Spree calls your service everywhere. No gem packaging required.

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

- **Migrations don't auto-apply.** Each install generator copies migrations into `backend/db/migrate/`; you must run `spree migrate` after. The `spree upgrade` command handles this for Spree itself but not for extensions — each extension's upgrade is manual.
- **Initializers can drift across upgrades.** When you bump an extension version, the initializer it generated may need new config keys. Check the extension's CHANGELOG before upgrading.
- **Extensions ship migrations with a `.spree.rb` suffix** in the host app (e.g. `db/migrate/<ts>_create_spree_stripe_charges.spree.rb`). The `.spree` infix marks them as "copied from a gem" so they survive `db:schema:dump` correctly. Don't rename them.
- **Decorators in extensions** can collide with decorators in your app. If two reopen `Spree::Order` and define a method with the same name, last-loaded wins (load order is alphabetical by gem name). Avoid decorating the same model in two places.
- **Engine-level subscribers** registered in an `initializer 'spree.<name>.subscribers'` block are appended once at boot. Reloading the development server is required when you change subscriber code.

## Where to read further

- **Extension catalog:** https://spreecommerce.org/docs/developer/customization/extensions and `docs/developer/customization/extensions.mdx`
- **Building extensions tutorial:** `docs/developer/contributing/creating-an-extension.mdx` (full walkthrough — generates a sale-price extension)
- **Customization patterns:** `docs/developer/customization/quickstart.mdx`, `docs/developer/customization/decorators.mdx`, `docs/developer/customization/dependencies.mdx`
- **Events for sync/notify scenarios:** the `spree-events-webhooks` skill
