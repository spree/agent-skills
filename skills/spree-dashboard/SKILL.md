---
name: spree-dashboard
description: Use when the user wants to extend the Spree React admin dashboard (`@spree/dashboard`) — add a new admin page, customize an existing one via slots, add a column to an admin table, register a new sidebar nav entry, or build a dashboard plugin. Specifically the React SPA shipping alongside the legacy Rails admin. Common phrasings include "extend the React dashboard", "defineDashboardPlugin", "customize the Spree admin SPA", "add slot to product edit", "@spree/dashboard plugin", "React admin". For customizing the legacy Rails admin (`spree_admin` gem), use the spree-admin skill instead. Provides the extension points the dashboard exposes and the `defineDashboardPlugin` API.
---

# Spree React Dashboard

`@spree/dashboard` is the React single-page application that ships as Spree's modern admin. It's a Vite-built SPA using TanStack Router (file-based, type-safe), TanStack Query, React Hook Form + Zod, shadcn/ui + Base UI, Tailwind, and Biome. All data goes through `@spree/admin-sdk` against the Admin API.

The dashboard is an alternative to the legacy Rails admin (`spree_admin` gem). Projects can run either; this skill is specifically about extending `@spree/dashboard`.

## The three-package split

The dashboard is intentionally split into three packages so plugin authors can extend it without forking:

| Package | What it owns |
|---|---|
| `@spree/dashboard-ui` | Headless primitives + design system. Components accept data via props, never import providers or hooks. Customize visuals here. |
| `@spree/dashboard-core` | The extension framework — registries, providers, admin SDK client, `defineDashboardPlugin`. Plugin authors import from here. |
| `@spree/dashboard` | The deployable app shell — routes, resource hooks, Zod schemas, locales. Customize behavior here. |

If you're extending the dashboard for a single project, write your code against `@spree/dashboard-core/plugin`. The same API works whether you're customizing for one app or publishing a reusable plugin.

## The extension API

Plugins register additions to the dashboard via a single call:

```tsx
import { defineDashboardPlugin } from '@spree/dashboard-core/plugin'
import { Card } from '@spree/dashboard-ui'

function WishlistCount({ product }: { product: { wishlist_count: number } }) {
  return <Card>Wishlists: {product.wishlist_count}</Card>
}

defineDashboardPlugin({
  nav: [
    { key: 'wishlists', label: 'Wishlists', path: '/wishlists', position: 50 },
  ],
  slots: {
    'product.form_sidebar': [
      { id: 'wishlist-count', component: WishlistCount, position: 50 },
    ],
  },
  tables: {
    products: {
      add: [{ key: 'wishlist_count', label: 'Wishlists', sortable: true }],
    },
  },
  settingsNav: [
    { key: 'wishlist-settings', label: 'Wishlists', path: '/wishlists', group: 'integrations' },
  ],
})
```

Each registry uses `useSyncExternalStore` so late registration (after the app has mounted) still re-renders consumers. Plugins can be lazy-loaded.

## What you can extend (the four registries)

### 1. Sidebar navigation (`nav`)

Add a top-level sidebar entry that opens a route in your plugin.

```tsx
defineDashboardPlugin({
  nav: [
    { key: 'reviews', label: 'Reviews', path: '/reviews', icon: ReviewIcon, position: 60 },
  ],
})
```

`position` controls ordering (lower = earlier). Built-in entries occupy positions 10–90; plugins typically land at 50+. `key` must be unique across all registered nav entries.

### 2. Slots (`slots`)

Slots are named injection points inside dashboard pages where plugins can inject components. The Product edit page exposes a `product.form_sidebar` slot, for example. Add a card to it:

```tsx
defineDashboardPlugin({
  slots: {
    'product.form_sidebar': [
      { id: 'wishlist-count', component: WishlistCount, position: 50 },
    ],
  },
})
```

The slot component receives the page's subject as a prop (e.g. `{ product }` for product slots, `{ order }` for order slots). Each slot entry needs a unique `id`. The dashboard's source is the truth for what slots exist — search for `<Slot name="..."` in the dashboard source to enumerate them.

### 3. Table columns (`tables`)

Augment built-in tables (Products, Orders, Customers, etc.) with extra columns:

```tsx
defineDashboardPlugin({
  tables: {
    products: {
      add: [{ key: 'wishlist_count', label: 'Wishlists', sortable: true }],
      remove: ['legacy_status'],
      update: { name: { label: 'Product Name' } },
    },
  },
})
```

Columns can be added (`add`), removed (`remove`), or patched (`update`). For `add` to surface real data, the column key must match a field the resource serializer returns. If you added the field via `spree:api_resource` and a custom serializer attribute, the column will get the data automatically.

### 4. Settings sub-nav (`settingsNav`)

Adds entries under Settings → (group). Groups (`general`, `taxes`, `integrations`, etc.) come from the dashboard core; declare a new group via `settingsNavGroups` if needed:

```tsx
defineDashboardPlugin({
  settingsNavGroups: [
    { key: 'wishlist', label: 'Wishlists', position: 80 },
  ],
  settingsNav: [
    { key: 'wishlist-settings', label: 'Wishlists', path: '/settings/wishlists', group: 'wishlist' },
  ],
})
```

## Adding a brand-new admin page

The lightest version: register a nav entry, register a route in your plugin's bootstrap, and the dashboard renders your component when the user clicks. For more complex pages (resource list + edit), reuse the dashboard's existing patterns:

- **Table page:** Use `<ResourceTable>` from `@spree/dashboard-ui` — handles sort/filter/pagination via the Admin SDK.
- **Form page:** React Hook Form + `<Field>` / `<Input>` / `<FieldError>` primitives. Zod schema for validation.
- **Data fetching:** TanStack Query via the resource hooks (`useResource(...)` exposed by `@spree/dashboard-core`).

Don't hand-write fetch calls — use the resource hooks. They handle JWT auth, refresh, and error mapping consistently with the rest of the dashboard.

## Adding a column to a table that maps to a field you added

The flow when you add `wishlist_count` to `Spree::Product`:

1. Add the attribute to your model (decorator) + migration.
2. Update the Admin serializer so the field appears in API responses:

```ruby
# backend/app/serializers/spree/api/v3/admin/product_serializer_decorator.rb
module Spree::Api::V3::Admin::ProductSerializerDecorator
  def self.prepended(base)
    base.attributes :wishlist_count
  end
  Spree::Api::V3::Admin::ProductSerializer.prepend self
end
```

3. Regenerate the TypeScript type for the new field. If a Lefthook hook is set up it runs automatically on commit; otherwise:

```bash
spree rake typelizer:generate
```

Then rebuild the admin SDK so the dashboard sees the new type.

4. Now the dashboard plugin can register the column:

```tsx
defineDashboardPlugin({
  tables: {
    products: { add: [{ key: 'wishlist_count', label: 'Wishlists', sortable: true }] },
  },
})
```

The `key` must match the serializer attribute exactly. Sort and filter work if the underlying column is in the model's `whitelisted_ransackable_attributes`.

## Conventions to follow

- **Wrap text in i18n.** Every user-visible string goes through i18next. `useTranslation().t('admin.wishlists.heading')` in components; `i18n.t(...)` at module load (table definitions). Keys live in your plugin's locale file.
- **Use the design system tokens.** `bg-primary`, `text-muted-foreground` — never raw color values. shadcn/ui + Base UI ship the tokens.
- **Forms = React Hook Form + Zod.** Map 422 API errors with `mapSpreeErrorsToForm(...)` so attribute errors land on fields and `:base` errors land in a top banner.
- **Drag-and-drop reorder where `acts_as_list` applies.** Don't render a position input — use `<ResourceTable reorder={{...}}>` for top-level tables, `dnd-kit` inside `<Sheet>` editors for nested.
- **Base UI `<Select>` doesn't auto-render labels.** Pass an `items` array, OR use the children render-prop with `<SelectValue>{(v) => labelFor(v)}</SelectValue>`. Common gotcha.

## What lives where

- **Page-level customization for one app** — write a plugin in your project; the dashboard imports it at bootstrap.
- **Reusable customization across multiple apps** — package it as an npm package + ship as a Spree extension that auto-registers in development. Same `defineDashboardPlugin` API.
- **Core dashboard behavior change** — that's not extension territory; consider whether the dashboard core needs to expose a new slot or registry. PR upstream.

## Where to read further

- **The dashboard package itself:** the `@spree/dashboard` source is the authoritative reference — file-based routes under `src/routes/_authenticated/$storeId/` are real implementations you can study.
- **Component primitives:** `@spree/dashboard-ui` source for headless components.
- **Plugin API source:** `@spree/dashboard-core` — `defineDashboardPlugin` type signature is authoritative.
- **Admin SDK usage:** the `spree-typescript-sdk` skill.
- **Legacy Rails admin** (the alternative): the `spree-admin` skill.
