---
name: spree-customization
description: Use FIRST when the user is about to customize Spree and the right approach isn't obvious — "how do I customize X", "what's the best way to add Y", "how do I extend Spree", "should I use a decorator or a subscriber", "where should I put this logic", "how do I add custom behavior", "where does business logic go". Maps a customization need to the right specific skill (decorators, events, dependencies, admin extensions, Ransack, configuration, the resource generator, etc.). Routes to specific skills rather than going deep itself. The skill to reach for whenever the user's question is broad or they haven't picked a pattern yet.
---

# Spree Customization — Where Does My Code Belong?

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

Spree is heavily customizable. The work of any Spree project is mostly customization — wiring in external services, adding custom models, tweaking behavior, extending the admin. The thing that's hard isn't *how* to customize; it's *which pattern* fits a given problem.

This skill is a decision tree. It maps a customization need to the right specific skill — read those for the deep dive. Walk the table top to bottom; the higher options are simpler and survive upgrades better than the lower ones.

## The decision tree

| What you're trying to do | Reach for | Deep-dive skill |
|---|---|---|
| Change merchant-facing settings (currencies, languages, tax zones, shipping methods, payment methods) | Admin Settings UI | — |
| Tweak Spree's runtime behavior globally | `Spree.config` block (`config.<setting> = …`) in `config/initializers/spree.rb`; read anywhere via `Spree::Config[:key]` | (configuration is straightforward — see docs link below) |
| React to something happening in Spree (order completed, product updated, customer registered, stock changed) | Events subscriber | **`spree-events-webhooks`** |
| Notify an external service (ERP, CRM, fulfillment, analytics, Slack) when something happens | Events subscriber OR outbound webhook | **`spree-events-webhooks`** |
| Replace how a core service computes (cart add, tax calculation, search, checkout flow, ability checks) | Dependency injection via `Spree.dependencies` | **`spree-dependencies`** |
| Add a menu item / nav entry to the admin | `Spree.admin.navigation.sidebar.add` | **`spree-admin`** |
| Add a section / form field to an existing admin page | `Spree.admin.partials.<page> << '...'` | **`spree-admin`** |
| Customize an admin table (columns, sort) | `Spree.admin.tables.<key>.add ...` | **`spree-admin`** |
| Make a new attribute searchable / filterable in the API or admin | `Spree.ransack.add_attribute(Class, :attr)` | **`spree-api-v3`** |
| Customize the checkout flow (skip a step, add a step, change validation) | `checkout_flow` block on a `Spree::Order` decorator | **`spree-checkout`** |
| Add a brand-new model + API endpoint (Brand, Vendor, etc.) | `spree:api_resource` generator | **`spree-resource`** |
| Add a Spree model with no API surface (internal record, lookup table, supporting model) | `spree:model` generator | **`spree-resource`** |
| Add an association / validation / scope / method to an existing Spree model | Decorator via `spree:model_decorator` | **`spree-decorators`** |
| Add a before_action / new action / override existing action on an existing controller | Decorator via `spree:controller_decorator` | **`spree-decorators`** |
| Pull in a third-party gem (Stripe, Adyen, search, i18n, social login) | `gem 'spree_x'` + install generator | **`spree-extensions`** |
| Package customization to share across multiple Spree apps | Build an extension (Rails engine as a gem) | **`spree-extensions`** |

## The priority order, in one sentence

**Settings → Configuration → Events → Dependencies → Admin / Ransack APIs → Generators (resource or model) → Decorators → Extensions.**

Lower-numbered options are easier to write, easier to test, and survive Spree upgrades cleanly. Decorators are reserved for *structural* changes to existing Spree classes (associations, validations, scopes, methods) — for behavioral changes (callbacks, side effects, sync), use Events instead.

## Worked examples

### "I need to sync orders to my ERP when they complete"

That's a side effect that fires when an order finishes. Don't decorate `Spree::Order` to add `after_save` — write a subscriber:

```ruby
# app/subscribers/erp_order_sync_subscriber.rb
class ErpOrderSyncSubscriber < Spree::Subscriber
  subscribes_to 'order.completed'

  def handle(event)
    ErpClient.sync_order(event.payload['id'])
  end
end
```

Then register it — subscribers are not auto-discovered (or skip both steps with `spree generate subscriber ErpOrderSync order.completed`, which creates the class and the registration in one go):

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.subscribers << ErpOrderSyncSubscriber
end
```

→ See the **`spree-events-webhooks`** skill for the full event catalog and async/sync behavior.

### "I need to add a Brand model that products belong to"

Brand is a brand-new resource with its own API surface. Use the generator:

```bash
spree generate api_resource Brand name:string:uniq active:boolean
```

Add the `brand_id` column to products:

```bash
spree generate migration AddBrandIdToSpreeProducts brand_id:bigint:index
spree migrate
```

Then add the `belongs_to :brand` to `Spree::Product` via a decorator:

```bash
spree generate model_decorator Spree::Product   # bare generator names auto-prefix to spree:
```

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.belongs_to :brand, class_name: 'Spree::Brand', optional: true
    end
  end

  Product.prepend(ProductDecorator)
end
```

→ See the **`spree-resource`** skill for the generator details and the **`spree-decorators`** skill for the decorator pattern.

### "I need to make `external_id` searchable in the admin orders table"

That's a Ransack allowlist concern — not a decorator job. Use the Ransack configuration API:

```ruby
# config/initializers/spree.rb
Spree.ransack.add_attribute(Spree::Order, :external_id)
```

→ See the **`spree-api-v3`** skill for Ransack details.

### "I need to change how the cart calculates totals"

That's a service swap. Subclass `Spree::Cart::Recalculate` and register your replacement:

```ruby
# config/initializers/spree.rb
Spree.cart_recalculate_service = MyApp::Cart::Recalculate
```

→ See the **`spree-dependencies`** skill for the full dependency injection pattern, the catalog of 70+ core and 300+ API injection points, and the `spree:dependencies:list / :overrides / :validate` rake tasks.

### "I need to add a 'Loyalty Points' page to the admin sidebar"

Use the admin navigation API — no decorator on the admin controller required:

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.admin.navigation.sidebar.add :loyalty_points,
    label: :loyalty_points,
    url: :admin_loyalty_points_path,
    icon: 'award',
    position: 80
end
```

→ See the **`spree-admin`** skill for the full extension API.

### "I need to add a 'preferred carrier' column to the products admin form"

Use the admin partials API to inject a section — no view override required:

```ruby
# config/initializers/spree.rb
Spree.admin.partials.product_form << 'spree/admin/products/preferred_carrier'
```

Then drop the partial at `app/views/spree/admin/products/_preferred_carrier.html.erb`. Permit the new attribute via:

```ruby
Rails.application.config.after_initialize do
  Spree::PermittedAttributes.product_attributes << :preferred_carrier
end
```

→ See the **`spree-admin`** skill.

### "I need to override how `Spree::Product#available?` decides availability"

That's a structural change — a behavioral override on an existing model method. Decorate:

```ruby
module Spree
  module ProductDecorator
    def available?
      return false if discontinued?
      super
    end
  end

  Product.prepend(ProductDecorator)
end
```

Call `super` so you extend Spree's logic instead of replacing it.

→ See the **`spree-decorators`** skill.

## Anti-patterns

These are tempting but wrong — the table above gives you a better answer for each.

- **`after_save` callbacks in a decorator** → use an Events subscriber instead. Decorator callbacks couple to model save mechanics and can break on minor upgrades.
- **Reaching into a Spree controller to add a sidebar item** → use `Spree.admin.navigation.sidebar.add`. No controller decorator needed.
- **Overriding a Spree serializer to add a field** → register the field via dependency injection or use `Spree.api.<resource>_serializer = 'MyApp::FooSerializer'`.
- **Decorating a model to add `ransackable_attributes`** → use `Spree.ransack.add_attribute` instead. Same outcome, no coupling to model internals.
- **Building a private extension gem for one-app customization** → put the code directly in `app/` (subscribers, decorators, services). Extensions are for sharing across apps.
- **Forking Spree** → almost never necessary. If you find yourself wanting to, work through this table from the top first — the right pattern almost certainly exists.

## Where to read further

- **Spree's customization docs (the canonical decision tree):** `node_modules/@spree/docs/dist/developer/customization/quickstart.md`
- **Each specific pattern's deep dive:** the linked `spree-X` skill in the table above
- **Configuration reference:** `node_modules/@spree/docs/dist/developer/customization/configuration.md`
