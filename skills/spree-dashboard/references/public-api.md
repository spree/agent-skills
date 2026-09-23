# Dashboard public import surface

Host apps import **everything** from `@spree/dashboard` (it re-exports `@spree/dashboard-core` and `@spree/dashboard-ui`). Distributed plugins import from `@spree/dashboard-core` + `@spree/dashboard-ui` directly and never from `@spree/dashboard`. Treat anything not listed here as internal, and never deep-import `…/src/…` paths. Canonical lists: `packages/dashboard-core/src/index.ts`, `packages/dashboard-ui/src/index.ts`.

Packages are `1.0.0-beta.x` (Developer Preview) — names can still move between releases; check the installed version's barrel when something doesn't resolve.

## `@spree/dashboard-core` — framework

| Kind | Exports |
|---|---|
| Plugin facade | `defineDashboardPlugin` (also at `@spree/dashboard-core/plugin`) |
| Registries | `nav`, `settingsNav`, `pluginRoutes`, `matchPluginRoute`, `usePluginRoutes`, `registerSlot`, `removeSlot`, `updateSlot`, `useSlotEntries`, `tables`, `defineTable`, `formFields`, `customFieldComponents` |
| Page chrome | `PageHeader`, `PageTabs`, `Slot`, `AppSidebar`, `SettingsSidebar`, `MobileTopBar`, `StoreSwitcher` |
| Tables | `ResourceTable`, `resourceSearchSchema`, `type ResourceSearch`, `TableToolbar`, `BulkActionBar`, `filtersToRansack` |
| Form widgets | `StoreDatePicker`, `CountryCombobox`, `CountryStateFields`, `CurrencySelect`, `LocaleSelect`, `MarketCombobox`, `ResourceCombobox`, `ResourceMultiAutocomplete`, `TagCombobox`, `PreferencesForm`, `AddressFormDialog` |
| Permission | `Can`, `usePermissions`, `Subject`, `Action`, `type SubjectName`, `type ActionName` |
| Hooks | `useAuth`, `useStore`, `useCommandPalette`, `useGlobalSearch`, `useCountries`, `useCustomFields`, `useDirectUpload`, `useExport`, `useResourceKey`, `useResourceKeyBuilder`, `useResourceMutation`, `useHostForm`, `useOptionalHostForm` |
| Helpers | `mapSpreeErrorsToForm`, `formatPrice`, `formatStoreDateTime`, `getInitials`, `blankToNull`, `blankToUndefined`, `withStoreScope`, `resourceKey`, `i18n` |
| SDK client | `adminClient` (the configured `@spree/admin-sdk` singleton) |
| Providers | `AuthProvider`, `PermissionProvider`, `StoreProvider` (the shell mounts these; only needed for a custom shell) |
| Export | `ExportButton` |
| Vite | `spreeDashboardPlugin` from `@spree/dashboard-core/vite` (core-only hosts; full-shell hosts use `@spree/dashboard/vite`) |

## `@spree/dashboard-ui` — design system (props in, no providers/hooks)

- shadcn-style primitives: `Button`, `Card*`, `Dialog*`, `Sheet*`, `DropdownMenu*`, `Input`, `Textarea`, `Checkbox`, `RadioGroup`, `Switch`, `Select*`, `Combobox`, `Field`, `FieldLabel`, `FieldError`, `FieldDescription`, `Table*`, `Badge`, `Avatar`, `Skeleton`, `Tooltip*`, `Toaster`
- Composed: `ResourceLayout` (header / main / sidebar grid), `Empty`, `EmptyHeader`, `EmptyMedia`, `EmptyTitle`, `EmptyDescription`, `EmptyContent`, `ColorPicker`, `RelativeTime`, `useConfirm`
- Utility: `cn` (clsx + tailwind-merge)
- Toasts: `import { toast } from 'sonner'` directly; `<Toaster>` is already mounted by the shell.

A few names exist in both packages (`ResourceCombobox`, `ResourceMultiAutocomplete`, `Slot`, `StatusCard`, `DateRange`): `@spree/dashboard` gives you the framework (data-fetching) version; import from `@spree/dashboard-ui` for the presentational one that takes options as props.

## `@spree/dashboard` — app shell

- Everything above, re-exported.
- `Dashboard` (provider stack + router; `<Dashboard router={router} />`) and `createDashboardRouter(routeTree, { basepath })` — wired in the starter's `main.tsx`.
- `@spree/dashboard/vite` → `spreeDashboardPlugin()` (Tailwind, plugin discovery, `virtual:spree-dashboard-plugins`, route-tree composition).
- `@spree/dashboard/styles.css` — CSS entry, imported first in `src/styles.css`.
- `@spree/dashboard/components/spree/payment-method-editors/types` — `paymentMethodGuideSlot` / `paymentMethodFormSlot` / `paymentMethodActionsSlot`.

## `@spree/admin-sdk`

Import types and `SpreeError` directly (`import { type Product, type PaginatedResponse, SpreeError } from '@spree/admin-sdk'`). Never construct a second client — use `adminClient`.
