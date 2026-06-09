---
name: spree-dependencies
description: Use when the user wants to swap how a core Spree service computes — cart add, cart recalculate, checkout flow, ability checks, payment processing, search, tax, serializers in the API. Common phrasings include "Spree.dependencies", "Spree::Dependencies", "replace Spree::Cart::AddItem", "swap the cart recalculate service", "custom ability", "override an API serializer", "swap a service", "dependency injection in Spree", "spree:dependencies:list", "spree:dependencies:overrides", "spree:dependencies:validate", "what services can I swap". Covers global vs API-level overrides, the introspection rake tasks, and the full catalog of swappable services. For deciding *whether* to swap a service vs use a decorator or subscriber, see the `spree-customization` skill first.
---

# Spree Dependencies (Dependency Injection)

`Spree.dependencies` is the canonical way to replace a core Spree service with your own implementation — no fork, no monkey-patch, no decorator. You inherit from the Spree default, override the methods you need, and register your class as the dependency. Spree's own code calls your service everywhere it used to call the default.

The core has **64 injection points**; the API has **233 more** for serializers, finders, and per-endpoint services. The full set is documented at `node_modules/@spree/docs/dist/developer/customization/dependencies.mdx`.

## When to reach for this vs other patterns

| Want to... | Use |
|---|---|
| Replace how a core service computes (cart add, cart recalculate, checkout step, ability checks, search, tax, finder) | **Dependency injection** (this skill) |
| Replace an API serializer everywhere | **Dependency injection** — `Spree.api.<serializer> = MyApp::Foo` |
| React to something happening after a service runs (sync to ERP, notify) | **Events subscriber** — see `spree-events-webhooks` |
| Add an association / validation / scope / method to a model | **Decorator** — see `spree-decorators` |
| Add a brand-new model + API endpoint | **`spree:api_resource`** — see `spree-resource` |
| Tweak runtime config / preferences | **`Spree::Config[:key]`** |

If Spree gives you a swappable service, **use it**. Decorating `Spree::Cart::AddItem` would couple you to the parent's step names and break on minor upgrades; subclassing + injection is the supported extension point.

## The basic pattern

### Step 1: subclass the Spree default

```ruby
# app/services/my_app/cart/add_item.rb
class MyApp::Cart::AddItem < Spree::Cart::AddItem
  def call(order:, variant:, quantity: nil, metadata: {}, options: {})
    ApplicationRecord.transaction do
      run :add_to_line_item
      run :handle_stock_reservations            # keep the parent's steps you need
      run Spree.cart_recalculate_service        # call other dependencies dynamically
      run :update_in_external_system            # your custom step
    end
  end

  private

  def update_in_external_system(*)
    # Your custom logic
  end
end
```

Inherit from the Spree default. Override `call` if you need to change the step chain; override individual private steps (`add_to_line_item`, `handle_stock_reservations`) if you only need to tweak one piece of behavior.

### Step 2: register the override

In `config/initializers/spree.rb`. Two syntaxes — both work, the direct form is concise:

```ruby
# Direct (recommended)
Spree.cart_add_item_service = MyApp::Cart::AddItem

# Block (when you're setting several at once)
Spree.dependencies do |deps|
  deps.cart_add_item_service       = MyApp::Cart::AddItem
  deps.cart_recalculate_service    = MyApp::Cart::Recalculate
  deps.checkout_advance_service    = MyApp::Checkout::Advance
end
```

### Step 3: Spree picks up your service everywhere

You don't have to find and patch callers. Spree's own code calls `Spree.cart_add_item_service.call(...)` rather than `Spree::Cart::AddItem.call(...)` — your replacement runs in admin requests, API requests, the dashboard, the storefront, background jobs, everything.

## Using dependencies from your own code

When your code needs to call a Spree service that might be overridden by someone else's customization, go through the dependency accessor — never hardcode the default class:

```ruby
# ✅ Resolves to the current dependency (default OR override)
Spree.cart_add_item_service.call(order: order, variant: variant, quantity: 1)

Spree.api.storefront_cart_serializer.new(order).serializable_hash

# ❌ Bypasses any override another extension or app initializer set
Spree::Cart::AddItem.call(order: order, variant: variant, quantity: 1)
```

This matters for extensions and shared code — using the accessor means your code composes cleanly with whatever overrides the host app has registered.

## Global vs API-level overrides

The Store API and Platform API each have their own set of injection points so you can customize one without touching the other. The precedence order:

1. **API-specific** (`Spree.api.<storefront|platform>_<name>`)
2. **Global** (`Spree.<name>`)
3. **Default** (Spree's bundled class)

You can mix and match:

```ruby
# Global swap — affects admin, jobs, custom controllers, anywhere
Spree.cart_add_item_service = MyApp::CartAddItem

# Storefront API only — takes precedence over the global for that surface
Spree.api.storefront_cart_add_item_service = MyApp::StorefrontCartAddItem
```

Storefront API requests use `MyApp::StorefrontCartAddItem`; everything else uses `MyApp::CartAddItem`. The Spree backend ignores the Storefront override outside that surface.

## Per-controller overrides

If you only want to swap a service for one specific API action (rather than globally or per-surface), use a controller decorator:

```ruby
# app/controllers/spree/cart_controller_decorator.rb
module Spree
  module CartControllerDecorator
    def resource_serializer
      MyApp::PremiumCartSerializer
    end

    def add_item_service
      MyApp::PremiumCart::AddItem
    end
  end

  CartController.prepend(CartControllerDecorator)
end
```

The controller's `resource_serializer` and `<name>_service` methods are themselves overridable hooks — see the controller source for the full list of overridable methods per endpoint.

For the decorator syntax + generator, see the `spree-decorators` skill.

## Inspecting + debugging dependencies

Spree ships three rake tasks for working with the dependency graph.

### List everything

```bash
spree rake spree:dependencies:list
```

Output looks like:

```
[CORE]
ability_class                    Spree::Ability
cart_add_item_service            Spree::Cart::AddItem
cart_create_service              Spree::Cart::Create
cart_recalculate_service         Spree::Cart::Recalculate [OVERRIDDEN]
...

[API]
storefront_cart_serializer       Spree::Api::V2::Storefront::CartSerializer
storefront_cart_add_item_service MyApp::CartAddItem [OVERRIDDEN]
...
```

`[OVERRIDDEN]` flags every dependency that's been swapped from the default — invaluable for figuring out what an extension changed.

Filter to find a specific service:

```bash
spree rake spree:dependencies:list | grep cart
spree rake spree:dependencies:list | grep -i serializer
```

### Show only overrides

```bash
spree rake spree:dependencies:overrides
```

Lists *only* the dependencies that differ from the default, with the source location (file + line) of the override:

```
[Core OVERRIDES]
cart_recalculate_service         Spree::Cart::Recalculate -> MyApp::Cart::Recalculate (config/initializers/spree.rb:15)

[API OVERRIDES]
storefront_cart_add_item_service Spree::Cart::AddItem     -> MyApp::CartAddItem        (config/initializers/spree.rb:20)
```

Use this when you walk into an inherited project — it answers "what has this app customized?" in one command.

### Validate that all dependencies resolve

```bash
spree rake spree:dependencies:validate
```

Loads every registered dependency and confirms it points to a real class. Catches typos and missing constants before runtime:

```
....F...............
1 invalid dependencies:
  [Core] cart_add_item_service: uninitialized constant MyApp::Cart::AddIem
```

Wire this into CI on any project that overrides dependencies. Typos here are silent at boot and only surface when the affected code path runs in production.

## Programmatic introspection

The rake tasks are thin wrappers around a public Ruby API. Use it in console sessions, custom rake tasks, or extension health checks:

```ruby
# All dependencies with their current + default values
Spree::Dependencies.current_values
# => [{name: :cart_add_item_service, current: MyApp::CartAddItem, default: 'Spree::Cart::AddItem', overridden: true}, ...]

# Is a specific dependency overridden?
Spree::Dependencies.overridden?(:cart_add_item_service)
# => true

# Where was the override set?
Spree::Dependencies.override_info(:cart_add_item_service)
# => {value: MyApp::CartAddItem, source: "config/initializers/spree.rb:15", set_at: 2024-01-15 10:30:00}

# Validate — raises Spree::DependencyError on the first bad reference
Spree::Dependencies.validate!
```

`Spree::Api::Dependencies` exposes the same surface for the API-level injection points.

## The catalog — what's actually swappable

The injection points are grouped by domain. The list is too long to enumerate in full; this is the categorical map. Run `spree rake spree:dependencies:list` to see the full set for the installed version.

### Core (64 injection points)

| Category | Examples |
|---|---|
| Cart | `cart_add_item_service`, `cart_remove_item_service`, `cart_recalculate_service`, `cart_create_service`, `cart_update_service`, `cart_set_item_quantity_service`, `cart_compare_line_items_service`, `cart_change_currency_service`, `cart_empty_service`, `cart_destroy_service`, `cart_associate_service`, `cart_estimate_shipping_rates_service`, `cart_remove_out_of_stock_items_service` |
| Carts (plural) | `carts_complete_service` |
| Checkout | `checkout_next_service`, `checkout_advance_service`, `checkout_update_service`, `checkout_complete_service`, `checkout_add_store_credit_service`, `checkout_remove_store_credit_service`, `checkout_get_shipping_rates_service`, `checkout_select_shipping_method_service` |
| Order | (order finalization, recalculation, cancellation services) |
| Shipment | (shipment update, ready, ship, cancel services) |
| Gift cards | `gift_card_apply_service` |
| Coupons | (coupon apply, remove services) |
| Tracking numbers | (tracking number generators) |
| Account | (account create/update services) |
| Addresses | (address create/update services) |
| Credit cards | (credit card management) |
| Classifications | (product-taxon association services) |
| Line items | (line item create/update/destroy services) |
| Finders | (record lookup classes — `line_item_by_variant_finder`, etc.) |
| Search | (search provider — also see `spree-catalog` skill) |
| Sorters / Paginators | (per-resource sort + pagination) |
| Ability | `ability_class` — the CanCanCan ability class |

### API (233 injection points)

| Category | Examples |
|---|---|
| v3 Store serializers | `storefront_cart_serializer`, `storefront_product_serializer`, `storefront_order_serializer`, etc. (one per resource) |
| v3 Admin serializers | `admin_product_serializer`, `admin_order_serializer`, etc. |
| v3 event serializers | Serializers for models that don't yet have Store API endpoints |
| Platform (v2 legacy) serializers | The full v2 JSON:API serializer set |
| Per-endpoint services | Per-endpoint overridable services (cart add, checkout advance, etc. — duplicates of the core list, scoped to a single API surface) |
| Sorters / Paginators / Finders | API-specific sort, pagination, and lookup classes |
| Coupon code handler | Per-API-surface coupon handler |

The `Spree.api.<name>` accessor reaches into API-level dependencies; the bare `Spree.<name>` accessor reaches into core dependencies.

## Backwards compatibility — old syntax

Older Spree projects used a string-based syntax that's still supported:

```ruby
# Legacy (still works)
Spree::Dependencies.cart_add_item_service = 'MyApp::Cart::AddItem'
result = Spree::Dependencies.cart_add_item_service.constantize

# New (recommended — concise, fails at assignment if the class doesn't exist)
Spree.cart_add_item_service = MyApp::Cart::AddItem
result = Spree.cart_add_item_service
```

Both can coexist in one initializer. New code should use the direct syntax — it catches misspelled class names immediately rather than at first invocation.

## Common pitfalls

### Calling the wrong accessor in your own code

`Spree.cart_add_item_service` resolves to whatever the current dependency is (default OR an override). `Spree::Cart::AddItem` is always the literal default class. **Always use the accessor in code that might run alongside an override** — extensions, shared services, decorators. Hardcoding the default class breaks composition.

### Forgetting to inherit from the default

A common mistake on first try:

```ruby
# ❌ Doesn't inherit — your class is missing Spree's service module wiring
class MyApp::Cart::AddItem
  def call(order:, variant:, **)
    # ...
  end
end

# ✅ Inherits Spree::ServiceModule::Base via the parent
class MyApp::Cart::AddItem < Spree::Cart::AddItem
  def call(order:, variant:, **)
    super  # or compose your own steps
  end
end
```

Spree services include `Spree::ServiceModule::Base` for the `run` step orchestration. Your replacement must inherit (or include that module manually) for the same step-chain behavior to work.

### Dropping steps from `call`

When you override `call`, every `run` step in the parent that you don't repeat is dropped:

```ruby
# Parent:
def call(order:, variant:, **)
  ApplicationRecord.transaction do
    run :add_to_line_item
    run :handle_stock_reservations       # ← parent has this step
    run Spree.cart_recalculate_service
  end
end

# Bad override — drops handle_stock_reservations silently:
def call(order:, variant:, **)
  ApplicationRecord.transaction do
    run :add_to_line_item
    run Spree.cart_recalculate_service
    run :my_custom_step
  end
end
```

Stock reservations stop working. Read the parent's `call` and preserve every step you don't have a reason to drop.

### Forgetting to set the dependency in an API context

`Spree.cart_add_item_service = X` overrides core. The Store API will still use its own `storefront_cart_add_item_service` (which itself defaults to the core one). If you want your override to apply to the Storefront API too, set both:

```ruby
Spree.cart_add_item_service                = MyApp::Cart::AddItem
Spree.api.storefront_cart_add_item_service = MyApp::Cart::AddItem
```

Or rely on the cascade (API falls through to core for any value it hasn't set itself) — but the `spree:dependencies:list` output will *not* show the storefront override in that case, which can mislead a future developer reading the catalog.

### Initializer load order

Dependency overrides go in `config/initializers/spree.rb`. Multiple extensions setting the same dependency follow alphabetical gem load order — the **last** assignment wins. If two gems both try to override `cart_add_item_service`, only the alphabetically-later one's override survives. Use `spree:dependencies:overrides` to confirm what actually ended up registered.

## Where to read further

- **Canonical docs:** `node_modules/@spree/docs/dist/developer/customization/dependencies.mdx`
- **Core injection point list:** `Spree::Core::Dependencies::INJECTION_POINTS_WITH_DEFAULTS` in `spree_core/lib/spree/core/dependencies.rb`
- **API injection point list:** `Spree::Api::Dependencies::INJECTION_POINTS_WITH_DEFAULTS` in `spree_api/lib/spree/api/dependencies.rb`
- **`Spree::ServiceModule::Base`** — the base class behind the `run :step_name` orchestration
- **For deciding whether to swap a service vs use events vs decorate:** the `spree-customization` skill
- **For installing third-party Spree gems that ship dependency overrides:** the `spree-extensions` skill
