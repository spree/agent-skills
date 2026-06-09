---
name: spree-extensions
description: Use when the user wants to add Spree functionality via a third-party gem (Stripe, Adyen, PayPal, i18n, search, social login, etc.), build their own Spree extension, or decide between extension vs subscriber vs decorator vs dependency injection for a customization. Common phrasings include "add Stripe", "install spree_X", "what payment gateways", "create a Spree extension", "build a gem for Spree", "decorator vs extension". Provides the install convention, the customization decision tree, and the catalog of community extensions documented at `docs/developer/customization/extensions.mdx`.
---

# Spree Extensions

Spree extensions are Rails engines packaged as gems. They mount into the host Rails app the same way Spree itself does. Adding one is a Gemfile entry + a generator run + a migrate.

## The customization decision tree

Always prefer the least-invasive option that solves the problem:

1. **Configuration / preferences** — A lot of behavior is just config. Check `Spree::Config[:my_key]` and the admin Settings UI first. See `docs/developer/customization/configuration.mdx`.
2. **Events + subscribers** — Side effects that react to lifecycle events. See the `spree-events-webhooks` skill.
3. **Dependency injection (service swap)** — Replace specific behavior (cart add, tax calculation, checkout flow) by subclassing the service and registering it via `Spree.dependencies`. See the `spree-project` skill and `docs/developer/customization/dependencies.mdx`.
4. **Install an extension (gem)** — Pull in pre-built functionality.
5. **Build your own extension (gem)** — Functionality you want to reuse across multiple Spree apps you maintain.
6. **Decorators** — Structural changes (add an association, validation, scope, new method) to an existing Spree model or controller via `Module#prepend`. Tightly couples to Spree internals. See the `spree-decorators` skill.

Extensions are option 4 — pulling in someone else's gem. Building your own (option 5) makes sense when you have multiple Spree projects sharing customization, or when you intend to share with the community. For a single app's customization, prefer subscribers and dependency injection.

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

## Decision: extension vs subscriber vs decorator vs dependency injection

The most common confusion is "which customization pattern do I use." The honest distinction:

| Want to... | Use |
|---|---|
| React to a lifecycle event (sync, notify, log) | Subscriber in `backend/app/subscribers/` |
| Replace how a cart calculates / how checkout transitions / how stock allocates | Dependency injection via `Spree.dependencies` |
| Add a custom field to an existing model | `Spree::Metafields` (configuration, not extension) — see `docs/developer/core-concepts/metafields.mdx` |
| Add a new admin page | Slot system + custom controller in `backend/`; extension if reusable across apps |
| Add a payment gateway | Use an existing extension (Stripe/Adyen/PayPal) or write a new `Spree::PaymentMethod` subclass |
| Replace search backend | Implement a SearchProvider (see `docs/developer/how-to/custom-search-provider.mdx`) |
| Add an association, validation, scope, or method to an existing Spree model | Decorator (see `spree-decorators` skill) |

If the customization is **specific to one app's business**, don't build an extension — it's overhead. If it's **reusable across multiple apps** or **a feature the wider Spree community would benefit from**, an extension is the right shape.

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
