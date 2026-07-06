---
name: spree-dependencies
description: Use when the user wants to swap how a core Spree service computes — cart add, cart recalculate, checkout flow, ability checks, payment processing, search, serializers in the API. Common phrasings include "Spree.dependencies", "Spree::Dependencies", "replace Spree::Cart::AddItem", "swap the cart recalculate service", "custom ability", "override an API serializer", "swap a service", "dependency injection in Spree", "spree:dependencies:list", "spree:dependencies:overrides", "spree:dependencies:validate", "what services can I swap". Covers global vs API-level overrides, the introspection rake tasks, and the full catalog of swappable services. For deciding *whether* to swap a service vs use a decorator or subscriber, see the `spree-customization` skill first.
---

# Spree Dependencies (Dependency Injection)

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

`Spree.dependencies` is the canonical way to replace a core Spree service with your own implementation — no fork, no monkey-patch, no decorator. You inherit from the Spree default, override the methods you need, and register your class as the dependency. Spree's own code calls your service everywhere it used to call the default.

The core has **70+ injection points** (71 in 5.5); the API has **300+ more** (303 in 5.5) for serializers, finders, and per-endpoint services. The full set is documented at `node_modules/@spree/docs/dist/developer/customization/dependencies.md`.

## When to reach for this vs other patterns

| Want to... | Use |
|---|---|
| Replace how a core service computes (cart add, cart recalculate, checkout step, ability checks, search, finder) | **Dependency injection** (this skill) |
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
  def call(order:, variant:, quantity: nil, metadata: {}, public_metadata: {}, private_metadata: {}, options: {})
    ApplicationRecord.transaction do
      run :add_to_line_item
      run :handle_stock_reservations            # keep the parent's steps you need
      run :update_in_external_system            # your custom step
      run Spree.cart_recalculate_service        # call other dependencies dynamically
    end
  end

  private

  def update_in_external_system(order:, line_item:, **rest)
    # Your custom logic
    success(order: order, line_item: line_item, **rest)
  end
end
```

Inherit from the Spree default. Override `call` if you need to change the step chain; override individual private steps (`add_to_line_item`, `handle_stock_reservations`) if you only need to tweak one piece of behavior.

Every `run` step must return `success(...)` or `failure(...)` — otherwise `Spree::ServiceModule::WrongDataPassed` is raised after the chain. The value you pass to `success` is double-splatted (`**`) into the next step, so it must be a hash whenever another step follows. That's also why the custom step goes *before* `run Spree.cart_recalculate_service` here: `Spree::Cart::Recalculate` ends with `success(line_item)` (a bare LineItem, not a hash), so no `run` step can come after it.

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

Spree.api.cart_serializer.new(order).serializable_hash

# ❌ Bypasses any override another extension or app initializer set
Spree::Cart::AddItem.call(order: order, variant: variant, quantity: 1)
```

This matters for extensions and shared code — using the accessor means your code composes cleanly with whatever overrides the host app has registered.

## Global vs API-level overrides

The two API surfaces are **Store API v3** and **Admin API v3**. They share core services but have separate serializer injection points, so you can customize one surface without touching the other:

- **Serializers** are per-surface: `Spree.api.<resource>_serializer` for the Store API (e.g. `Spree.api.product_serializer`, `Spree.api.cart_serializer`) and `Spree.api.admin_<resource>_serializer` for the Admin API (e.g. `Spree.api.admin_product_serializer`). Admin serializers extend their Store counterparts, so public-field changes propagate automatically.
- **Services** have a single core-level injection point — `Spree.<name>` (e.g. `Spree.cart_add_item_service`). All v3 endpoints, Store and Admin alike, call the core dependency directly; there is no per-surface service layer.

```ruby
# Service swap — affects every caller: Store API, Admin API, jobs, custom code
Spree.cart_add_item_service = MyApp::CartAddItem

# Store API serializer only — Admin API keeps its own
Spree.api.product_serializer = 'MyApp::ProductSerializer'

# Admin API serializer only
Spree.api.admin_product_serializer = 'MyApp::Admin::ProductSerializer'
```

> **Warning:** `Spree.api` still defines legacy `storefront_*` and `platform_*` injection points (e.g. `Spree.api.storefront_cart_add_item_service`), and they still appear in `spree rake spree:dependencies:list` output under `[API]`. These belonged to the removed API v2 controllers and have no consumers — setting them is a silent no-op and they will be removed in Spree 6. Always use the global `Spree.<name>` service accessors instead.

## Per-controller overrides

If you only want to swap a serializer for one specific controller (rather than globally or per-surface), use a controller decorator overriding `serializer_class`:

```ruby
# app/controllers/spree/api/v3/store/carts_controller_decorator.rb
module Spree::Api::V3::Store
  module CartsControllerDecorator
    def serializer_class
      MyApp::PremiumCartSerializer
    end
  end
end

Spree::Api::V3::Store::CartsController.prepend Spree::Api::V3::Store::CartsControllerDecorator
```

Generate the file with `bin/rails g spree:controller_decorator Spree::Api::V3::Store::CartsController`.

The v3 `ResourceController` hooks you can override this way are `model_class`, `serializer_class`, `scope`, `find_resource`, `permitted_params`, and `collection_includes`. There are no per-controller `<name>_service` hooks in API v3 — controllers call the registered dependencies directly, so to swap a service use the global (`Spree.<name>`) injection points described above. (Per-surface `Spree.api.*` points exist only for serializers.)

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
cart_serializer                  Spree::Api::V3::CartSerializer
admin_product_serializer         Spree::Api::V3::Admin::ProductSerializer
product_serializer               MyApp::ProductSerializer [OVERRIDDEN]
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

**Caveat (5.5):** the task walks *every* injection point, including the legacy v2 slots (`storefront_*`, `platform_*`) whose defaults still name deleted `Spree::V2::Storefront::*` / `Spree::Api::V2::Platform::*` classes — so a clean install already reports dozens of pre-existing `[API]` failures. Grep the output for your own class names (or scope your check to Core) rather than expecting a green run.

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

# Validate — checks every injection point and raises Spree::DependencyError listing all bad references
Spree::Dependencies.validate!
```

`Spree::Api::Dependencies` exposes the same surface for the API-level injection points.

## The catalog — what's actually swappable

The injection points are grouped by domain. The list is too long to enumerate in full; this is the categorical map. Run `spree rake spree:dependencies:list` to see the full set for the installed version.

### Core (71 injection points in 5.5)

| Category | Examples |
|---|---|
| Cart | `cart_add_item_service`, `cart_remove_item_service`, `cart_recalculate_service`, `cart_create_service`, `cart_update_service`, `cart_set_item_quantity_service`, `cart_compare_line_items_service`, `cart_change_currency_service`, `cart_empty_service`, `cart_destroy_service`, `cart_associate_service`, `cart_estimate_shipping_rates_service`, `cart_remove_out_of_stock_items_service` |
| Carts (plural) | `carts_complete_service` |
| Checkout | `checkout_next_service`, `checkout_advance_service`, `checkout_update_service`, `checkout_complete_service`, `checkout_add_store_credit_service`, `checkout_remove_store_credit_service`, `checkout_get_shipping_rates_service`, `checkout_select_shipping_method_service` |
| Order | (order finalization, recalculation, cancellation services) |
| Shipment | (shipment update, ready, ship, cancel services) |
| Gift cards | `gift_card_apply_service` |
| Coupons | `coupon_handler` — single handler for apply + remove (`Spree::PromotionHandler::Coupon`) |
| Tracking numbers | (tracking number generators) |
| Account | (account create/update services) |
| Addresses | (address create/update services) |
| Credit cards | (credit card management) |
| Classifications | (product-taxon association services) |
| Line items | (line item create/update/destroy services) |
| Payments | `payment_create_service`, `payments_handle_webhook_service` |
| Finders | (record lookup classes — `line_item_by_variant_finder`, etc.) |
| Search | `search_product_presenter` (the provider itself is set via `Spree.search_provider=`, not dependencies — see `spree-catalog`) |
| Sorters / Paginators | (per-resource sort + pagination) |
| Ability | `ability_class` — the CanCanCan ability class |

### API (303 injection points in 5.5)

| Category | Examples |
|---|---|
| v3 Store serializers | `cart_serializer`, `product_serializer`, `order_serializer`, etc. (unprefixed, one per resource) |
| v3 Admin serializers | `admin_product_serializer`, `admin_order_serializer`, etc. |
| v3 event serializers | Serializers for models that don't yet have Store API endpoints |
| Legacy v2 slots (`storefront_*`, `platform_*`) | v2 Storefront/Platform serializer and service keys kept for back-compat, slated for removal in Spree 6 — v3 endpoints never read them (v3 controllers call the core service dependencies like `Spree.cart_add_item_service` directly), and the default `Spree::V2::Storefront::*` serializer classes no longer exist in the tree |
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

Spree services `prepend Spree::ServiceModule::Base` for the `run` step orchestration. Your replacement must inherit from the Spree default (or `prepend` that module itself — `include` will not wire the class-level `.call`) for the same step-chain behavior to work.

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

### Assuming you need a second, API-level assignment

You don't. A global override applies everywhere, including the v3 Store and Admin APIs:

```ruby
Spree.cart_add_item_service = MyApp::Cart::AddItem  # ← this is all you need
```

The v3 controllers call `Spree.cart_add_item_service` (the core injection point) directly and resolve it lazily at request time, so an override in `config/initializers/spree.rb` takes effect for API requests too.

The `Spree.api.storefront_*` service points are leftovers from the removed API v2 (marked "Legacy API v2 dependencies — will be removed in Spree 6" in the `spree_api` gem's `lib/spree/api/dependencies.rb`). Nothing consumes them anymore — assigning `Spree.api.storefront_cart_add_item_service` is a no-op. Don't rely on their "cascade" either: their proc defaults are snapshotted once, when `Spree::Api::Dependencies` is instantiated in an engine initializer that runs *before* your app's initializers — so core overrides set in `config/initializers/spree.rb` never propagate into them. They'll still appear in `spree:dependencies:list` output showing the stale boot-time value; ignore them.

### Initializer load order

Dependency overrides go in `config/initializers/spree.rb`. Multiple extensions setting the same dependency follow alphabetical gem load order — the **last** assignment wins. If two gems both try to override `cart_add_item_service`, only the alphabetically-later one's override survives. Use `spree:dependencies:overrides` to confirm what actually ended up registered.

## Where to read further

- **Docs:** `node_modules/@spree/docs/dist/developer/customization/dependencies.md` — note this published page still describes the **legacy v2** injection points (`storefront_*`, `Spree::V2::Storefront::*` defaults); treat the source constants below as authoritative for 5.5.
- **Core injection point list:** `Spree::Core::Dependencies::INJECTION_POINTS_WITH_DEFAULTS` in the installed `spree_core` gem, `lib/spree/core/dependencies.rb`
- **API injection point list:** `Spree::Api::ApiDependencies::INJECTION_POINTS_WITH_DEFAULTS` in the installed `spree_api` gem, `lib/spree/api/dependencies.rb` (`Spree::Api::Dependencies` is an instance of this class)
- **`Spree::ServiceModule::Base`** — the base class behind the `run :step_name` orchestration
- **For deciding whether to swap a service vs use events vs decorate:** the `spree-customization` skill
- **For installing third-party Spree gems that ship dependency overrides:** the `spree-extensions` skill
