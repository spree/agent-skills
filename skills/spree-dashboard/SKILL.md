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

function WishlistCount({ resource }: { resource: { wishlist_count: number } }) {
  return <Card>Wishlists: {resource.wishlist_count}</Card>
}

defineDashboardPlugin({
  nav: [
    { key: 'wishlists', label: 'Wishlists', path: '/wishlists', position: 150 },
  ],
  slots: {
    'page.actions': [
      { id: 'wishlist-count', component: WishlistCount, position: 50 },
    ],
  },
  tables: {
    products: {
      add: [{ key: 'wishlist_count', label: 'Wishlists', sortable: true }],
    },
  },
  settingsNav: [
    { key: 'wishlist-settings', label: 'Wishlists', path: '/wishlists', group: 'store' },
  ],
})
```

The nav, settings-nav, and slot registries use `useSyncExternalStore`, so late registration (after the app has mounted) still re-renders consumers. Table mutations registered before the table's `defineTable` runs are queued and applied when it does — register table columns at bootstrap, before the table page renders. Plugins can be lazy-loaded.

## What you can extend (the four registries)

### 1. Sidebar navigation (`nav`)

Add a top-level sidebar entry that opens a route in your plugin.

```tsx
defineDashboardPlugin({
  nav: [
    { key: 'reviews', label: 'Reviews', path: '/reviews', icon: ReviewIcon, position: 150 },
  ],
})
```

`position` controls ordering (lower = earlier). Built-in entries use 100/200/300… spacing so plugins can slot in between (e.g. 150 lands between the first and second built-in entries; entries without a `position` default to 100). `key` must be unique across all registered nav entries — duplicate keys throw. For relative placement without hardcoding numbers, use `nav.insertBefore(targetKey, entry)` / `nav.insertAfter(targetKey, entry)`.

### 2. Slots (`slots`)

Slots are named injection points inside dashboard pages where plugins can inject components. The page header on every resource page exposes `page.actions` and `page.actions_dropdown` slots, and `<PageTabs>` exposes a `page.tabs` slot, for example. Dynamic editor slots also exist: `payment_method.{guide,form,actions}.<provider_type>`, `promotion.{rule_form,action_form,rule_summary,action_summary}.<type>`, and `price_list.rule_form.<type>`. Add a card to `page.actions`:

```tsx
defineDashboardPlugin({
  slots: {
    'page.actions': [
      { id: 'wishlist-count', component: WishlistCount, position: 50 },
    ],
  },
})
```

The slot component receives the context the render site passes — for `page.actions` that is `{ resource }` (the page's resource, e.g. the product on the product edit page) — plus optional ambient `permissions`, `store`, and `user` fields declared on the slot context type (not populated yet — they arrive with the SlotProvider, so don't depend on them today). Each slot entry needs a unique `id`. The dashboard's source is the truth for what slots exist — search for `<Slot name="..."` in the dashboard source to enumerate them.

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

Columns can be added (`add`), removed (`remove`), or patched (`update`). For `add` to surface real data, the column key must match a field the resource serializer returns. To extend a built-in resource's Admin serializer with a new field, see "Adding a column to a table that maps to a field you added" below.

### 4. Settings sub-nav (`settingsNav`)

Adds entries under Settings → (group). Groups (`store`, `payments`, `fulfillment`, `team`) are registered by the dashboard app; declare a new group via `settingsNavGroups` if needed — an entry whose `group` key is not registered is silently dropped from the sidebar:

```tsx
defineDashboardPlugin({
  settingsNavGroups: [
    { key: 'wishlist', label: 'Wishlists', position: 80 },
  ],
  settingsNav: [
    { key: 'wishlist-settings', label: 'Wishlists', path: '/wishlists', group: 'wishlist' },
  ],
})
```

Settings-nav paths are auto-prefixed with `/$storeId/settings` at render time.

## Adding a brand-new admin page

The lightest version: register a nav entry via `defineDashboardPlugin`, then add a file-based route in the host app under `src/routes/_authenticated/$storeId/<path>.tsx` that renders your component (nav paths are auto-prefixed with `/$storeId`). Plugins cannot register routes themselves — routing is file-based TanStack Router owned by the host app; the plugin registries cover nav, settings nav, slots, and table columns only. For more complex pages (resource list + edit), reuse the dashboard's existing patterns:

- **Table page:** Use `<ResourceTable>` from `@spree/dashboard-core` — pass a `queryFn` that calls the Admin SDK; it handles sort/filter/pagination.
- **Form page:** React Hook Form + `<Field>` / `<Input>` / `<FieldError>` primitives. Zod schema for validation.
- **Data fetching:** TanStack Query. For plugin pages, write a small hook that wraps the admin SDK client in `useQuery` (`import { adminClient } from '@spree/dashboard-core'`); for writes, use `useResourceMutation` from `@spree/dashboard-core` — it bundles query invalidation and success/error toasts. The per-resource data hooks (`useProducts`, `useOrder`, …) live in the `@spree/dashboard` app under `src/hooks/`; reuse them when you're customizing the app shell itself (they aren't importable from the published package).

Don't hand-write fetch calls — go through the admin SDK client (or the resource hooks when working in the app shell). It handles JWT auth, refresh, and error mapping consistently with the rest of the dashboard.

## Adding a column to a table that maps to a field you added

The flow when you add `wishlist_count` to `Spree::Product`:

1. Add the attribute to your model (decorator) + migration.
2. Update the Admin serializer so the field appears in API responses:

```ruby
# backend/app/serializers/my_app/admin_product_serializer.rb
module MyApp
  class AdminProductSerializer < Spree::Api::V3::Admin::ProductSerializer
    typelize wishlist_count: :number
    attributes :wishlist_count
  end
end

# backend/config/initializers/spree.rb
Spree.api.admin_product_serializer = 'MyApp::AdminProductSerializer'
```

3. Type the new field in your frontend code via TypeScript declaration merging — the generated SDK types are interfaces precisely so this works:

```ts
// types/spree.d.ts
declare module '@spree/admin-sdk' {
  interface Product {
    wishlist_count: number
  }
}
```

(`rake typelizer:generate` and the Lefthook hook are Spree-monorepo tooling for regenerating the published SDK types. In your app the task technically exists — the typelizer gem ships it — but it writes into the installed gem's directory tree, never into the `@spree/admin-sdk` package your dashboard consumes, so don't use it. Declaration merging is the supported path.)

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
- **Reusable customization across multiple apps** — package it as an npm package whose entry module calls `defineDashboardPlugin` at import time. Host apps register it with a side-effect import (`import '@my-co/wishlists-plugin'`) in their entry file before the router mounts, and list it in `spreeDashboardPlugin({ plugins: [...] })` in vite.config.ts so Tailwind scans its classes. Keep `@spree/dashboard-core`, `@spree/dashboard-ui`, `react`, `react-dom` as peer dependencies so the registries stay singletons.
- **Core dashboard behavior change** — that's not extension territory; consider whether the dashboard core needs to expose a new slot or registry. PR upstream.

## Where to read further

- **The dashboard package itself:** the `@spree/dashboard` source is the authoritative reference — file-based routes under `src/routes/_authenticated/$storeId/` are real implementations you can study.
- **Component primitives:** `@spree/dashboard-ui` source for headless components.
- **Plugin API source:** `@spree/dashboard-core` — `defineDashboardPlugin` type signature is authoritative.
- **Admin SDK usage:** the `spree-typescript-sdk` skill.
- **Legacy Rails admin** (the alternative): the `spree-admin` skill.
