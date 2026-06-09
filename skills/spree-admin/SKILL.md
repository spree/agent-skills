---
name: spree-admin
description: Use when the user is customizing the legacy Rails admin (the `spree_admin` gem) — adding a new resource page, registering a sidebar item, customizing a column in an admin table, overriding a view, scaffolding a new admin section. The legacy admin is the Rails/Turbo admin; the React `@spree/dashboard` is the alternative covered by the spree-dashboard skill. Common phrasings include "add admin page", "Rails admin", "spree_admin", "scaffold admin resource", "admin sidebar", "override admin view", "Hotwire admin", "Turbo admin". If the project uses the React dashboard, use the spree-dashboard skill instead.
---

# Spree Legacy Rails Admin (`spree_admin`)

The legacy admin is a Rails engine — server-rendered ERB views, Stimulus + Turbo for interactivity, Tailwind for styling. It's the long-standing admin and remains a fully-supported option alongside the React `@spree/dashboard`.

If you're working on the React dashboard instead, see the **spree-dashboard** skill. This skill is specifically the `spree_admin` gem's Rails admin.

## Project layout

The legacy admin lives in the `spree_admin` gem, mounted at `/admin`. View it as a normal Rails app:

```
spree_admin gem
├── app/
│   ├── controllers/spree/admin/         # admin controllers
│   ├── views/spree/admin/<resource>/    # ERB views per resource
│   ├── helpers/spree/admin/             # view helpers
│   ├── presenters/spree/admin/          # presenter pattern for complex views
│   ├── javascript/spree/admin/          # Stimulus controllers, importmap-managed
│   └── models/spree/admin/navigation*   # nav + nav builder
└── lib/generators/spree/admin/
    ├── install/                         # bin/rails g spree_admin:install
    └── scaffold/                        # bin/rails g spree_admin:scaffold
```

In a host app (`backend/`), you customize by overriding files at the same paths under `backend/app/`. Rails view path resolution prefers the host app's files over the gem's.

## Adding a new admin resource (the one-command path)

Spree ships an admin scaffold generator that produces the full CRUD admin for any model. After the model + migration exist (use `spree:api_resource` or `spree:model`):

```bash
spree rails g spree_admin:scaffold Spree::Brand
```

This emits:

| File | Purpose |
|---|---|
| `backend/app/controllers/spree/admin/brands_controller.rb` | Controller inheriting `Spree::Admin::ResourceController` |
| `backend/app/views/spree/admin/brands/index.html.erb` | Listing page (uses `Spree.admin.tables.brands` for columns) |
| `backend/app/views/spree/admin/brands/new.html.erb` | Create form page |
| `backend/app/views/spree/admin/brands/edit.html.erb` | Edit form page |
| `backend/app/views/spree/admin/brands/_form.html.erb` | Shared form partial |
| `backend/config/initializers/spree_admin_brands_table.rb` | Table column registration |
| `backend/config/initializers/spree_admin_brands_navigation.rb` | Sidebar nav registration |

You'll also need to add routes — the generator currently doesn't inject them:

```ruby
# backend/config/routes.rb
Rails.application.routes.draw do
  mount Spree::Core::Engine => '/'

  Spree::Core::Engine.routes.append do
    namespace :admin do
      resources :brands
    end
  end
end
```

(If you're using `spree:api_resource` for the API, the routes for the API are separate from the admin routes — they live in different namespaces.)

Restart Rails to pick up the new initializers and routes:

```bash
spree restart
```

## Customizing the sidebar

Sidebar entries are registered in initializers. Pattern:

```ruby
# backend/config/initializers/spree_admin_brands_navigation.rb
Rails.application.config.after_initialize do
  Spree.admin.navigation.sidebar.add :brands,
    label: :brands,                                       # i18n key or string
    url: :admin_brands_path,                              # symbol → route helper, or string
    icon: 'list',                                         # lucide-react icon name
    position: 55,                                         # lower = earlier in sidebar
    active: -> { controller_name == 'brands' },           # when to highlight
    if: -> { can?(:manage, Spree::Brand) }                # CanCanCan visibility check
end
```

Common nav patterns:

```ruby
# Top-level item that opens a sub-menu
Spree.admin.navigation.sidebar.add :marketing, label: :marketing, position: 30 do |nav|
  nav.add :promotions, label: :promotions, url: :admin_promotions_path, position: 10
  nav.add :coupon_codes, label: :coupon_codes, url: :admin_coupon_codes_path, position: 20
end

# Remove an existing entry
Spree.admin.navigation.sidebar.remove :reports

# Reorder an existing entry
Spree.admin.navigation.sidebar.update :products, position: 5
```

The full nav API is in `spree/admin/app/models/spree/admin/navigation.rb` if you need to read the source.

## Customizing admin tables

Every admin listing page (Products, Orders, Customers, etc.) uses a registered table definition. Add, remove, or reorder columns from an initializer:

```ruby
# backend/config/initializers/spree_admin_products_table_customization.rb
Rails.application.config.after_initialize do
  # Add a column to the existing Products table
  Spree.admin.tables.products.add :brand_name,
    label: :brand,                                        # i18n key
    type: :text,                                          # :text | :link | :datetime | :badge | :image | :money | :boolean
    sortable: true,
    filterable: true,
    default: true,                                        # visible by default (vs opt-in via column toggle)
    position: 25

  # Remove a column
  Spree.admin.tables.products.remove :sku

  # Update an existing column
  Spree.admin.tables.products.update :name, label: :product_name
end
```

For tables you generate yourself (via `spree_admin:scaffold`), the initializer is emitted with sensible defaults — `name`, `created_at`, `updated_at`. Add your domain-specific columns there.

Custom column rendering: when a column's value isn't a direct attribute, define a method on the model or a presenter/decorator. The column's `name` references that method. For example, if you add a `brand_name` column to the Products table, define `brand_name` on the Product model or a presenter:

```ruby
# In your model or decorator
def brand_name
  brand&.name
end
```

## Overriding views

Drop the same-pathed file in the host app and Rails uses it. The gem ships `spree/admin/app/views/spree/admin/products/index.html.erb`; you override it at `backend/app/views/spree/admin/products/index.html.erb`.

Two real gotchas:

1. **Copy the full file first**, then edit. Partial overrides don't work — Rails picks the host app's file entirely. Use `bundle show spree_admin` to find the gem's view source.

2. **View files have a `data-controller` Stimulus binding** for interactive behavior. If you delete a `data-controller="…"` attribute, the related JS stops working. Keep the bindings unless you're explicitly replacing them.

For lighter overrides, prefer extending via partials Spree exposes — many views `<%= render 'spree/admin/shared/extra_actions' %>` at known points. Override just the partial:

```erb
<!-- backend/app/views/spree/admin/shared/_extra_actions.html.erb -->
<%= link_to 'My custom action', some_path, class: 'btn btn-primary' %>
```

## Decorating admin controllers

The Spree admin controllers are normal Rails controllers — you can decorate them like any other:

```ruby
# backend/app/controllers/spree/admin/products_controller_decorator.rb
module Spree::Admin::ProductsControllerDecorator
  def self.prepended(base)
    base.before_action :my_custom_check, only: [:create, :update]
  end

  private

  def my_custom_check
    # ...
  end

  Spree::Admin::ProductsController.prepend self
end
```

This is more invasive than nav/table customization — only reach for it when the action's behavior needs to change. Check whether a subscriber (for side effects) or a service swap (for business logic) would work first. See the `spree-project` skill for the full customization decision tree.

## Stimulus controllers — admin interactivity

The legacy admin uses Stimulus + Turbo for client-side interactivity. Existing controllers live at `spree_admin/app/javascript/spree/admin/controllers/`:

| Controller | What it does |
|---|---|
| `sidebar_controller.js` | Sidebar toggle + persistence |
| `variants_form_controller.js` | Variant management on product edit |
| `page_builder_controller.js` | Drag-and-drop CMS page builder |
| `bulk_editor_controller.js` | Multi-row table editing |
| `dropdown_controller.js` | Dropdown menus |

To add your own Stimulus controller, drop it at `backend/app/javascript/controllers/` and register it via the importmap (`backend/config/importmap.rb`). Reference it from a view with `data-controller="my-controller"`.

For Turbo Streams (server-pushed UI updates), the same patterns apply as any Rails 7+ Hotwire app — render `turbo_stream.*` from the controller, target frames by ID.

## Decision tree: what kind of admin change is this?

| Want to... | Use |
|---|---|
| Add a sidebar item linking to your own page | `Spree.admin.navigation.sidebar.add` in an initializer |
| Add a column to an admin table | `Spree.admin.tables.<name>.add` in an initializer |
| Add a new resource CRUD section | `bin/rails g spree_admin:scaffold Spree::YourModel` |
| Change how an existing page looks | Override the view in `backend/app/views/spree/admin/...` |
| Add a new action to a controller | Decorator (last resort — see `spree-project` skill first) |
| Make a form field interactive | Stimulus controller + `data-controller="..."` in the view |
| Push real-time updates to the UI | Turbo Stream broadcasts from a subscriber or service |
| Change admin styling globally | Custom Tailwind classes; the admin uses Tailwind via `spree_admin/app/assets/stylesheets/spree/admin/application.css` |

## What the legacy admin doesn't ship that the React dashboard does

If you're choosing between the legacy admin and the React dashboard, here's what each does well:

| Feature | Legacy admin | React dashboard |
|---|---|---|
| Customization via plugins | Via Rails initializers (nav, tables) and view overrides | Via `defineDashboardPlugin` (slots, nav, tables, settings) |
| Real-time UI updates | Turbo Streams (server pushes) | TanStack Query (client polls/refetches) |
| Multi-store support | Yes | Yes (built-in, store switcher in nav) |
| Mobile-friendly | Limited | Yes (responsive layout) |
| Slot-based UI extensions | No (view-override only) | Yes (named injection points) |
| Type safety on extensions | No | Yes (TypeScript + Zod schemas) |
| Translation infrastructure | Rails i18n (server-side) | i18next (client-side, with same key conventions) |

If you don't need slots / TypeScript types / mobile, the legacy admin is more than enough and easier to customize via Rails idioms. If you're building deeply custom workflows or shipping a SaaS where admin UX matters, the dashboard is worth the move.

## Where to read further

- **Admin source:** `bundle show spree_admin` to find the installed gem path. The README at the root of the gem covers the philosophy.
- **Customization docs:** `node_modules/@spree/docs/dist/developer/admin/` covers patterns.
- **Navigation API:** `Spree::Admin::Navigation` source — the full method surface for nav customization.
- **Table API:** `Spree::Admin::Tables` source — column types, options, sorting/filtering details.
- **Scaffold generator:** `bundle show spree_admin`/lib/generators/spree/admin/scaffold/ has the template files you can copy for advanced customization.
