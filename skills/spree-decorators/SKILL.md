---
name: spree-decorators
description: Use when the user wants to extend a Spree model, controller, helper, or service class without forking — add an association to Spree::Product, add a method to Spree::Order, override a validation, add a scope, prepend a before_action, hook into create. Common phrasings include "add brand to product", "decorate Spree::X", "ProductDecorator", "OrderDecorator", "Module#prepend", "spree:model_decorator", "extend an existing Spree model", "add a method to Spree::Order", "override Spree behavior", "monkey patch Spree". Provides the decorator pattern, the generator, the prepended(base) idiom, and the gotchas. Mentions when NOT to decorate — events for after-save side effects, dependencies for service swaps, the resource generator for whole new models.
---

# Spree Decorators

Decorators let you change existing Spree classes (models, controllers, helpers, services) from your own app without modifying gem source. They're the standard Ruby `Module#prepend` pattern with a Spree filename convention and a generator.

## Read the warning first

Decorators tightly couple your code to Spree internals. They will *probably* survive a minor upgrade and *might* survive a major one. The Spree docs are explicit: **decorators are for structural changes** (add an association, validation, scope, new method). For behavioral changes (callbacks, side effects, post-save sync), use a modern alternative instead.

### Pick the right tool

| Use case | Use this instead of a decorator |
|---|---|
| React to a save / create / update / delete | [Events subscriber](https://spreecommerce.org/docs/developer/core-concepts/events) — see the `spree-events-webhooks` skill |
| Notify an external service when something changes | Webhook or events subscriber |
| Swap how a service computes (cart add, tax, search, checkout) | `Spree.dependencies` — see the `spree-extensions` skill |
| Replace a serializer or ability | `Spree.dependencies` |
| Add an admin menu item | Admin navigation API — see the `spree-admin` skill |
| Add a section to an admin form | Admin partial injection / slot — see the `spree-admin` skill |
| Add a searchable/filterable field | `whitelisted_ransackable_attributes` on the model (still a decorator, but the lightest possible) |
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

Rails autoloads the file at boot; the `prepend` line runs once and your module enters the method-lookup chain ahead of `Spree::Product`'s own definitions. Your methods are found first and can `super` to call the original.

## Generate the file

Spree ships two generators — one for models, one for controllers. **Use them** — they produce the exact filenames, modules, and `prepend` lines the autoloader expects.

### Models

```bash
spree generate spree:model_decorator Spree::Product
# or, without the @spree/cli wrapper:
bin/rails g spree:model_decorator Spree::Product
```

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

The argument accepts either `Spree::Product` or `Product` — the generator strips the prefix. Works for any model in the `Spree::*` namespace.

### Controllers

```bash
spree generate spree:controller_decorator Spree::Admin::ProductsController
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
bin/rails g migration AddBrandIdToSpreeProducts brand_id:integer:index
```

```ruby
class AddBrandIdToSpreeProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_products, :brand_id, :integer
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
      base.scope :featured, -> { where("metadata->>'featured' = ?", 'true') }
      base.scope :recently_added, -> { where('created_at > ?', 30.days.ago) }
    end
  end

  Product.prepend(ProductDecorator)
end
```

If you want this scope queryable from the API, also allowlist it via Ransack — see the Ransack note at the bottom.

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

If you added an association or column and want it queryable from the API (`?q[brand_id_eq]=...`), allowlist it on the model:

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

Without this, the API returns 422 on filter attempts. See the `spree-api-v3` skill for the full Ransack story.

### Permit a new attribute on writes

If the new attribute should be settable via the admin or the API, register it in the permitted-attributes list:

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree::PermittedAttributes.product_attributes += [:brand_id]
end
```

## Controller decorator patterns

> **First check whether you can avoid this.** A new controller that inherits from a Spree base class is more upgrade-safe than a decorator on an existing controller. Controller decorators that override existing actions are the most fragile decorator type — they couple to instance variables and method signatures that can change between Spree minor releases.

### Add a before_action

```ruby
# app/controllers/spree/checkout_controller_decorator.rb
module Spree
  module CheckoutControllerDecorator
    def self.prepended(base)
      base.before_action :check_minimum_order, only: [:update]
    end

    private

    def check_minimum_order
      if @order.total < 25.0 && params[:state] == 'payment'
        flash[:error] = 'Minimum order amount is $25'
        redirect_to checkout_state_path(@order.state)
      end
    end
  end

  CheckoutController.prepend(CheckoutControllerDecorator)
end
```

### Add a new action

```ruby
# app/controllers/spree/products_controller_decorator.rb
module Spree
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

And the route — Spree controllers live in the engine, so the route must be added to the engine, not your app:

```ruby
# config/routes.rb
Spree::Core::Engine.add_routes do
  get 'products/:id/quick_view', to: 'products#quick_view', as: :product_quick_view
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
        Rails.logger.info "Product creation attempted by #{current_spree_user.email}"
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

  def call(event)
    product = Spree::Product.find_by(id: event.payload['id'])
    return unless product

    ExternalSyncJob.perform_later(product)
  end
end
```

Subscribers in `app/subscribers/` are auto-registered. Async by default. Testable in isolation. See the `spree-events-webhooks` skill for the full event catalog and the subscriber API.

## When NOT to use a decorator

- **You want a whole new model + API endpoint** → use the `spree:api_resource` generator. See the `spree-resource` skill.
- **You want to swap how a service computes** → use `Spree.dependencies`. See the `spree-extensions` skill.
- **You want to react to a Spree event** → write a subscriber. See the `spree-events-webhooks` skill.
- **You want to customize the admin UI** → use the admin partial / slot system. See the `spree-admin` skill (legacy Rails admin) or `spree-dashboard` (React).
- **You want a custom payment gateway** → subclass `Spree::PaymentMethod` and register the calculator. See the `spree-payments` skill.
- **You want to override admin tables or navigation** → use the admin extension APIs (`Spree.admin.tables`, the navigation registry). See the `spree-admin` skill.

The decorator is the **last resort** for structural changes the modern APIs don't cover. When in doubt, check the table at the top of this skill — there's a high chance the modern alternative exists.

## Where to read further

- **Decorator docs:** `node_modules/@spree/docs/dist/developer/customization/decorators.mdx` (also at https://spreecommerce.org/docs/developer/customization/decorators)
- **Extending models tutorial:** `node_modules/@spree/docs/dist/developer/tutorial/extending-models.mdx` — the canonical brand-on-product walkthrough
- **Events** (for behavioral customizations): the `spree-events-webhooks` skill
- **Dependencies** (for swappable services): the `spree-extensions` skill
- **API resource generator** (for whole new models): the `spree-resource` skill
