---
name: spree-decorators
description: Use when the user wants to extend a Spree model, controller, helper, or service class without forking — add an association to Spree::Product, add a method to Spree::Order, override a validation, add a scope, prepend a before_action, hook into create. Common phrasings include "add brand to product", "decorate Spree::X", "ProductDecorator", "OrderDecorator", "Module#prepend", "spree:model_decorator", "extend an existing Spree model", "add a method to Spree::Order", "override Spree behavior", "monkey patch Spree". Provides the decorator pattern, the generator, the prepended(base) idiom, and the gotchas. Mentions when NOT to decorate — events for after-save side effects, dependencies for service swaps, the resource generator for whole new models.
---

# Spree Decorators

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

Decorators let you change existing Spree classes (models, controllers, helpers, services) from your own app without modifying gem source. They're the standard Ruby `Module#prepend` pattern with a Spree filename convention and a generator.

## Read the warning first

Decorators tightly couple your code to Spree internals. They will *probably* survive a minor upgrade and *might* survive a major one. The Spree docs are explicit: **decorators are for structural changes** (add an association, validation, scope, new method). For behavioral changes (callbacks, side effects, post-save sync), use a modern alternative instead.

### Pick the right tool

| Use case | Use this instead of a decorator |
|---|---|
| React to a save / create / update / delete | [Events subscriber](https://spreecommerce.org/docs/developer/core-concepts/events) — see the `spree-events-webhooks` skill |
| Notify an external service when something changes | Webhook or events subscriber |
| Swap how a service computes (cart add, tax, search, checkout) | `Spree.dependencies` — see the `spree-dependencies` skill |
| Replace a serializer or ability | `Spree.dependencies` |
| Add an admin menu item | Admin navigation API — see the `spree-admin` skill |
| Add a section to an admin form | Admin partial injection / slot — see the `spree-admin` skill |
| Add a searchable/filterable field | `Spree.ransack.add_attribute(Spree::Product, :brand_id)` in an initializer (also `add_association` / `add_scope`) — no decorator needed |
| Add an association, validation, scope, or new method | **Decorator** (this skill) |

If your job is "react to product update by syncing to an ERP," write a subscriber on `product.updated`, not a `after_save` callback in a decorator. The decorator path will break the next time Spree changes how Product saves.

## The pattern in three lines

A decorator is just a Ruby module prepended to an existing Spree class. The file lives in your app at the same path Spree uses, with `_decorator` appended.

```ruby
# app/models/spree/product_decorator.rb
module Spree
  module ProductDecorator
    # methods, prepended hook, etc.
  end

  Product.prepend(ProductDecorator)
end
```

Host-app decorators are loaded by an explicit glob, not by plain autoloading: spree-starter (and the `spree:install` generator) put a `config.to_prepare` block in `config/application.rb` that loads every `app/**/*_decorator*.rb` file, so the `prepend` line runs at boot and again after every code reload in development. If your app has neither (check `config/application.rb` for the block), add it — Zeitwerk alone will never load an unreferenced decorator module in development, and your decorators will silently not apply. Once loaded, your module enters the method-lookup chain ahead of `Spree::Product`'s own definitions: your methods are found first and can `super` to call the original.

## Generate the file

Spree ships two generators — one for models, one for controllers. **Use them** — they produce the exact filenames, modules, and `prepend` lines the autoloader expects.

### Models

```bash
spree generate model_decorator Spree::Product
# or, without the @spree/cli wrapper:
bin/rails g spree:model_decorator Spree::Product
```

The CLI auto-prefixes `spree:` for Spree generators (`spree g model_decorator ...` also works as a shorthand).

Output at `app/models/spree/product_decorator.rb`:

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      # base.belongs_to :brand
    end

    # add custom methods here
  end
end

Spree::Product.prepend Spree::ProductDecorator
```

The argument accepts either `Spree::Product` or `Product` — the generator strips the prefix. Works for singular model names under `Spree::` (the vast majority), including nested ones. But the generator runs the name through `classify`, which singularizes the last segment — for plural-named classes (e.g. `Spree::Exports::Products`, `Spree::Promotion::Actions::CreateItemAdjustments`) it emits a `prepend` against a non-existent singular constant and the file raises `NameError` on load. Write those decorators by hand instead.

### Controllers

```bash
spree generate controller_decorator Spree::Admin::ProductsController
# or, without the @spree/cli wrapper:
bin/rails g spree:controller_decorator Spree::Admin::ProductsController
```

Output at `app/controllers/spree/admin/products_controller_decorator.rb`:

```ruby
module Spree::Admin
  module ProductsControllerDecorator
    def self.prepended(base)
      # base.before_action :my_filter
    end

    # add custom methods here
  end
end

Spree::Admin::ProductsController.prepend Spree::Admin::ProductsControllerDecorator
```

The generator handles arbitrary namespace depth:

- `Spree::ProductsController` → `app/controllers/spree/products_controller_decorator.rb`
- `Spree::Admin::ProductsController` → `app/controllers/spree/admin/products_controller_decorator.rb`
- `Spree::Api::V3::Store::ProductsController` → `app/controllers/spree/api/v3/store/products_controller_decorator.rb`

The final `.prepend` line is always fully qualified — no surprises about which constant is being decorated.

## Model decorator patterns

### Add an association

Run the migration first (no foreign key constraint — keep it Spree-style):

```bash
bin/rails g migration AddBrandIdToSpreeProducts brand_id:bigint:index
```

```ruby
class AddBrandIdToSpreeProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_products, :brand_id, :bigint
    add_index :spree_products, :brand_id
  end
end
```

Then the decorator:

```ruby
# app/models/spree/product_decorator.rb
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.belongs_to :brand, class_name: 'Spree::Brand', optional: true
      base.has_many :videos, class_name: 'Spree::Video', dependent: :destroy
    end
  end

  Product.prepend(ProductDecorator)
end
```

Class-level additions (associations, validations, scopes, callbacks, `extend`s) **always go inside `self.prepended(base)`** and are called on `base`. Instance methods go at module level.

### Add a validation

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.validates :external_id, presence: true, uniqueness: true
      base.validates :weight, numericality: { greater_than: 0 }, allow_nil: true
    end
  end

  Product.prepend(ProductDecorator)
end
```

### Add a scope

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.scope :featured, -> { where("public_metadata->>'featured' = ?", 'true') }
      base.scope :recently_added, -> { where('created_at > ?', 30.days.ago) }
    end
  end

  Product.prepend(ProductDecorator)
end
```

If you want this scope queryable from the API, also allowlist it via Ransack — see the Ransack note at the bottom.

Note the SQL string names the real jsonb column: `public_metadata` or `private_metadata`. In Ruby, `metadata` is an alias method for `private_metadata` — but there is no `metadata` **column**, so `where("metadata->>…")` raises `PG::UndefinedColumn`. (For anything the storefront filters on, a real boolean column beats metadata anyway.)

### Add a new instance method

```ruby
module Spree
  module ProductDecorator
    def featured?
      metadata[:featured] == true
    end

    def days_until_available
      return 0 if available_on.nil? || available_on <= Time.current
      (available_on.to_date - Date.current).to_i
    end
  end

  Product.prepend(ProductDecorator)
end
```

### Override an existing method (call `super`)

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

**Always consider whether you need `super`.** Omitting it replaces the original method entirely — which can silently break behavior the rest of Spree assumes is there.

### Add class methods

Use `extend` from inside `prepended`:

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def search_by_name(query)
        where('LOWER(name) LIKE ?', "%#{query.downcase}%")
      end
    end
  end

  Product.prepend(ProductDecorator)
end
```

Usage: `Spree::Product.search_by_name('shirt')`.

### Make a new attribute available via Ransack

If you added an association or column and want it queryable from the API (`?q[brand_id_eq]=...`), allowlist it. The preferred, no-decorator way is `Spree.ransack` from an initializer:

```ruby
# config/initializers/spree.rb
Spree.ransack.add_attribute(Spree::Product, :brand_id)
Spree.ransack.add_attribute(Spree::Product, :external_id)
Spree.ransack.add_association(Spree::Product, :brand)
Spree.ransack.add_scope(Spree::Product, :featured)
```

If you're already inside a decorator (e.g. you just added the association there), appending to the model allowlists works too:

```ruby
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.whitelisted_ransackable_attributes += %w[brand_id external_id]
      base.whitelisted_ransackable_associations += %w[brand videos]
    end
  end

  Product.prepend(ProductDecorator)
end
```

Without this, filter params on the attribute are silently dropped — the API returns 200 as if that filter were never sent, not an error. See the `spree-api-v3` skill for the full Ransack story.

### Permit a new attribute on writes

If the new attribute should be settable via the admin or the API, register it in the permitted-attributes list:

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree::PermittedAttributes.product_attributes << :brand_id
end
```

This makes the attribute writable in the Rails admin, which builds its strong params from this list. It does not automatically reach every API v3 endpoint: the v3 base `ResourceController` defaults `permitted_params` to the matching `Spree::PermittedAttributes` list, but controllers that enumerate their own `params.permit(...)` — including `Spree::Api::V3::Admin::ProductsController` — ignore the global list. To accept the attribute on those endpoints, decorate the controller's `permitted_params` (or contribute the attribute upstream).

## Controller decorator patterns

> **First check whether you can avoid this.** A new controller that inherits from a Spree base class is more upgrade-safe than a decorator on an existing controller. Controller decorators that override existing actions are the most fragile decorator type — they couple to instance variables and method signatures that can change between Spree minor releases.

### Add a before_action

Note: Spree no longer ships a Rails storefront — `Spree::CheckoutController` / `Spree::ProductsController` only exist in legacy apps using the separate storefront gem. Modern storefronts are headless via the Store API, so the controllers you'll decorate are the admin and API ones:

```ruby
# app/controllers/spree/admin/products_controller_decorator.rb
module Spree::Admin
  module ProductsControllerDecorator
    def self.prepended(base)
      base.before_action :check_editable, only: [:update]
    end

    private

    def check_editable
      if params[:id].blank?
        flash[:error] = Spree.t(:not_found)
        redirect_to spree.admin_products_path
      end
    end
  end

  ProductsController.prepend(ProductsControllerDecorator)
end
```

Use `bin/rails g spree:controller_decorator Spree::Admin::ProductsController` (or `Spree::Api::V3::Store::CartsController` for API controllers) to scaffold the correct file path and prepend line — the generator handles arbitrary namespace depth. Note: API controller decorators must render JSON errors (e.g. `render json: { error: ... }, status: :unprocessable_entity`), not flash/redirect.

### Add a new action

```ruby
# app/controllers/spree/admin/products_controller_decorator.rb
module Spree::Admin
  module ProductsControllerDecorator
    def self.prepended(base)
      base.before_action :load_product, only: [:quick_view]
    end

    def quick_view
      respond_to do |format|
        format.html { render partial: 'quick_view', locals: { product: @product } }
        format.json { render json: @product }
      end
    end

    private

    def load_product
      @product = current_store.products.friendly.find(params[:id])
    end
  end

  ProductsController.prepend(ProductsControllerDecorator)
end
```

And the route — Spree controllers live in the engine, so the route must be added to the engine, not your app. Admin routes are drawn through the core engine inside the admin namespace:

```ruby
# config/routes.rb
Spree::Core::Engine.add_routes do
  namespace :admin, path: Spree.admin_path do
    get 'products/:id/quick_view', to: 'products#quick_view', as: :product_quick_view
  end
end
```

### Modifying an existing action

The most fragile decorator pattern. If you must:

```ruby
module Spree
  module Admin
    module ProductsControllerDecorator
      def create
        log_product_creation_attempt
        super
        notify_team_of_new_product if @product.persisted?
      end

      private

      def log_product_creation_attempt
        Rails.logger.info "Product creation attempted by #{try_spree_current_user&.email}"
      end

      def notify_team_of_new_product
        ProductNotificationJob.perform_later(@product)
      end
    end

    ProductsController.prepend(ProductsControllerDecorator)
  end
end
```

The example above is also a case where **the better answer is a subscriber on `product.created`** — same outcome, no coupling to controller internals.

## Common pitfalls

### Forgot to call `super`

```ruby
# ❌ Replaces all of Spree's availability logic — easy to silently break
def available?
  in_stock? && active?
end

# ✅ Extends, doesn't replace
def available?
  super && custom_availability_check
end
```

### Instance variables in `prepended`

```ruby
# ❌ Doesn't do what it looks like — @custom_setting lives on the decorator module, not on instances
def self.prepended(base)
  @custom_setting = true
end

# ✅ Use class_attribute when you want a setting on instances
def self.prepended(base)
  base.class_attribute :custom_setting, default: true
end
```

### Circular dependencies via constant references

When decorators reference each other (or other Spree models that haven't been loaded yet), constant lookups can fail at boot. Use **string class names** for association `class_name:` arguments:

```ruby
# ❌ Variant might not be loaded yet at decorator boot
base.has_many :variants

# ✅ String form — resolved lazily
base.has_many :variants, class_name: 'Spree::Variant'
```

### File path / module name mismatch

The autoloader is strict about names. `Spree::ProductDecorator` MUST live at `app/models/spree/product_decorator.rb`. The generator gets this right; if you hand-write the file, match it exactly.

## Organizing multiple decorators

If you have many customizations on `Spree::Product`, splitting into focused modules is fine — group by concern:

```
app/models/spree/
├── product_decorator.rb           # Main file, prepends the others
├── product/
│   ├── brand_decorator.rb         # Brand association
│   ├── inventory_decorator.rb     # Inventory customizations
│   └── seo_decorator.rb           # SEO methods
```

```ruby
# app/models/spree/product_decorator.rb
require_dependency 'spree/product/brand_decorator'
require_dependency 'spree/product/inventory_decorator'
require_dependency 'spree/product/seo_decorator'
```

This is purely organizational — each child file uses the same `prepend` pattern, just on smaller modules.

## Migrating from decorators to modern patterns

If you inherited a decorator that uses `after_save` for side effects, migrate it to an Events subscriber. Same outcome, no coupling to model internals, won't break when Spree changes how `Spree::Product` saves.

**Before:**

```ruby
# app/models/spree/product_decorator.rb
module Spree
  module ProductDecorator
    def self.prepended(base)
      base.after_save :sync_to_external_service
    end

    private

    def sync_to_external_service
      ExternalSyncJob.perform_later(self) if saved_change_to_name?
    end
  end

  Product.prepend(ProductDecorator)
end
```

**After:**

```ruby
# app/subscribers/product_sync_subscriber.rb
class ProductSyncSubscriber < Spree::Subscriber
  subscribes_to 'product.updated'

  def handle(event)
    product = Spree::Product.find_by_prefix_id(event.payload['id'])
    return unless product

    ExternalSyncJob.perform_later(product)
  end
end
```

Subscribers are **not** auto-discovered from `app/subscribers/` — only classes in the `Spree.subscribers` array get wired to the event registry (Spree's engines add their built-in subscribers there; your app must add its own). Register yours in an initializer:

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.subscribers << ProductSyncSubscriber
end
```

Async by default. Testable in isolation. See the `spree-events-webhooks` skill for the full event catalog and the subscriber API.

## When NOT to use a decorator

- **You want a whole new model + API endpoint** → use the `spree:api_resource` generator. See the `spree-resource` skill.
- **You want to swap how a service computes** → use `Spree.dependencies`. See the `spree-dependencies` skill.
- **You want to react to a Spree event** → write a subscriber. See the `spree-events-webhooks` skill.
- **You want to customize the admin UI** → use the admin partial / slot system. See the `spree-admin` skill.
- **You want a custom payment gateway** → subclass `Spree::PaymentMethod` and register it with `Spree.payment_methods << MyGateway`. See the `spree-payments` skill.
- **You want to override admin tables or navigation** → use the admin extension APIs (`Spree.admin.tables`, the navigation registry). See the `spree-admin` skill.

The decorator is the **last resort** for structural changes the modern APIs don't cover. When in doubt, check the table at the top of this skill — there's a high chance the modern alternative exists.

## Where to read further

- **Decorator docs:** `node_modules/@spree/docs/dist/developer/customization/decorators.md` (also at https://spreecommerce.org/docs/developer/customization/decorators)
- **Extending models tutorial:** `node_modules/@spree/docs/dist/developer/tutorial/extending-models.md` — the canonical brand-on-product walkthrough
- **Events** (for behavioral customizations): the `spree-events-webhooks` skill
- **Dependencies** (for swappable services): the `spree-dependencies` skill
- **API resource generator** (for whole new models): the `spree-resource` skill
