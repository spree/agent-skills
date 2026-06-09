---
name: spree-project
description: Use when the user is working on a Spree Commerce project — anything involving Spree models, controllers, customization patterns (decorators, subscribers, services), Spree conventions like prefixed IDs / Spree:: namespacing / Spree.user_class / Spree::Current, or asking how Spree works. Activates broadly for any task in a Spree backend.
---

# Spree Commerce Project

A Rails application powered by [Spree Commerce](https://spreecommerce.org). Project layout (scaffolded by `create-spree-app`):

| Directory | Description |
|---|---|
| `backend/` | The Rails app — Spree mounted as an engine |
| `apps/storefront/` | Optional Next.js storefront |
| `node_modules/@spree/docs/dist/` | Local copy of Spree developer docs |

All Spree-specific code (models, decorators, subscribers) lives under `backend/app/`.

## Where to find Spree documentation

When you need Spree-specific guidance — how a model works, what events are available, how the cart pipeline runs — read the local docs first:

```
node_modules/@spree/docs/dist/
├── developer/
│   ├── core-concepts/       Products, orders, payments, inventory
│   ├── customization/       Decorators, extensions, dependencies, events
│   ├── admin/               Admin panel customization
│   └── tutorial/            Step-by-step guides
└── api-reference/
    └── store.yaml           OpenAPI spec — every Store API endpoint
```

Reach for these before guessing from training data. The local docs are the authoritative source for the installed Spree version.

## Customization patterns (in priority order)

When extending Spree, follow this decision tree. Each layer is more invasive than the last — prefer the earliest option that solves the problem.

### 1. Events + subscribers (preferred for side effects)

React to model lifecycle events without touching Spree source. Use for: external service syncs, notifications, cache invalidation, custom analytics.

```ruby
# backend/app/subscribers/spree/my_order_subscriber.rb
module MyApp
  class OrderSubscriber < Spree::Subscriber
    subscribes_to 'order.complete'

    def handle(event)
      order = Spree::Order.find_by_prefix_id(event.payload['id'])
      ExternalService.notify(order)
    end
  end
end
```

Register in `backend/config/initializers/spree.rb`:

```ruby
Rails.application.config.after_initialize do
  Spree.subscribers << MyApp::OrderSubscriber
end
```

### 2. Swap a service (dependencies)

When you need to change *behavior* of a specific operation (e.g. how items are added to the cart), subclass the Spree service and register it.

```ruby
# backend/app/services/my_app/cart/add_item.rb
module MyApp
  module Cart
    class AddItem < Spree::Cart::AddItem
      def call(order:, variant:, quantity: nil, **opts)
        ApplicationRecord.transaction do
          run :add_to_line_item
          run :my_custom_step
          run Spree.cart_recalculate_service
        end
      end

      def my_custom_step
        # ...
      end
    end
  end
end
```

```ruby
# backend/config/initializers/spree.rb
Spree.dependencies do |deps|
  deps.cart_add_item_service = 'MyApp::Cart::AddItem'
end
```

### 3. Install a Spree extension (gem)

For larger feature additions (payment gateways, search providers, integrations):

```ruby
# backend/Gemfile
gem 'spree_stripe'
```

```bash
spree bundle install
spree rails g spree_stripe:install   # convention: <gem>:install
```

### 4. Decorator (last resort)

Only use for structural model changes (associations, validations, scopes). **Avoid for callbacks and side effects** — those belong in subscribers.

```ruby
# backend/app/models/spree/product_decorator.rb
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.has_many :reviews, class_name: 'MyApp::Review', dependent: :destroy
      base.validates :custom_field, presence: true
    end
  end

  Product.prepend ProductDecorator
end
```

Decorators couple your code to Spree internals and make upgrades harder. Prefer subscribers or service swaps when possible.

## Conventions you should always follow

- **Namespace under `Spree::`** — all Spree-related Ruby classes live in `app/models/spree/`, `app/controllers/spree/`, etc.
- **`Spree.user_class` / `Spree.admin_user_class`** — never reference `Spree::User` directly. The user class is configurable.
- **`Spree::Current.store` / `.currency` / `.locale`** — per-request context, available in models, controllers, services.
- **Prefixed IDs in the API** — every v3 API response returns Stripe-style prefixed IDs (`prod_86Rf07xd4z`, `or_m3Rp9wXz`). Never expose raw integer IDs. Same on writes — the API accepts prefixed IDs.
- **`Spree.base_class`** — inherit from this, not `ActiveRecord::Base`. It applies Spree's base configuration.

## Common commands

`@spree/cli` (installed by `create-spree-app`) wraps the Docker-based dev workflow:

```bash
spree dev                          # boot the backend stack
spree stop                         # tear down
spree console                      # Rails console
spree logs                         # follow web container logs
spree restart                      # restart the Rails process

spree migrate                      # run pending migrations
spree generate <name> [args]       # any Spree generator
spree bundle add <gem>             # add a gem (persists in bundle_cache volume)
spree rake <task>                  # any rake task
spree exec <cmd>                   # universal escape hatch

spree upgrade                      # version upgrade
```

If you don't have `spree` on your PATH, prefix with the package runner: `npx spree …`, `pnpm exec spree …`, or `bunx spree …`.

## When in doubt

- Need to add a new model + API endpoint? See the `spree-resource` skill.
- Need to upgrade Spree? See the `spree-upgrade` skill.
- Need details on a specific Spree concept? Read `node_modules/@spree/docs/dist/developer/` first.
