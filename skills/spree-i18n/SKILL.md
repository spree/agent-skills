---
name: spree-i18n
description: Use when the user is translating Spree — adding a new locale, translating product names/descriptions, fixing missing translations, configuring RTL languages, building a multilingual storefront, working with Mobility, or wrangling Spree.t / I18n.t key lookups. Common phrasings include "add Spanish to Spree", "translate products", "Mobility", "translation tables", "RTL", "missing translation", "Spree.t", "fallback locale", "translated columns", "translation admin". Covers both UI strings (config/locales/*.yml) and data translations (Mobility on Product, Taxon, etc.).
---

# Spree I18n + Translations

Two distinct translation surfaces, each with its own mechanism:

| What | Mechanism | Where it lives |
|---|---|---|
| **UI strings** (labels, buttons, errors, emails) | Standard Rails I18n + `Spree.t` | `config/locales/<locale>.yml` |
| **Data** (product names, category names, descriptions) | [Mobility gem](https://github.com/shioyama/mobility) translation tables | `spree_<model>_translations` tables |

You need both for a multilingual store. UI strings are about how the app speaks; data translations are about what merchant content the customer sees.

## UI strings — `Spree.t` and the YAML files

Every Spree gem ships its own English locale file. `spree.t` (or `Spree.t`) looks up a key scoped under `spree.*` in the active locale:

```ruby
Spree.t(:add_to_cart)                      # => "Add to cart"
Spree.t('orders.checkout_complete')        # => "Order complete!"
Spree.t(:total, scope: 'order')            # => "Total"
Spree.t(:missing_key, default: 'Fallback') # => "Fallback"
```

In views / helpers, the shorthand is just `Spree.t(...)`. In ERB templates, you can also use `<%= t('.relative_key') %>` for lazy lookup based on the controller + action name (standard Rails).

### Adding a new UI language

1. **Install the translations gem** (community-maintained):

   ```ruby
   # Gemfile
   gem 'spree_i18n'   # ships translations for ~50 locales
   ```

   This adds `config/locales/<locale>.yml` files for every Spree gem in the bundle.

2. **Add the locale to your store's supported list:**

   ```ruby
   # backend/config/initializers/spree.rb
   I18n.available_locales = %i[en es fr de it ja]
   I18n.default_locale = :en
   ```

3. **(Optional) Add the locale to the store's supported_locales** so the storefront language switcher offers it:

   ```ruby
   store = Spree::Store.default
   store.update!(supported_locales: 'en,es,fr', default_locale: 'en')
   ```

4. **Customize keys** by overriding in your app's `config/locales/<locale>.yml` — Rails merges later-loaded locale files over earlier ones, and your app's `config/locales/` is loaded last by default.

### Adding a new key

If a string isn't in any locale yet:

```yaml
# config/locales/en.yml in your app
en:
  spree:
    custom_feature:
      title: "Loyalty rewards"
      cta: "Join now"
```

```ruby
Spree.t('custom_feature.title')   # => "Loyalty rewards"
```

Then add the same key under `es`, `fr`, etc. in matching files.

### Normalizing translation keys

Spree uses [`i18n-tasks`](https://github.com/glebm/i18n-tasks) to keep locale files clean. After adding keys:

```bash
bundle exec i18n-tasks normalize          # sort + dedupe
bundle exec i18n-tasks missing            # list missing keys
bundle exec i18n-tasks unused             # list unused keys
bundle exec i18n-tasks health             # all of the above
```

The Spree monorepo runs `normalize` on its YAML files; if you're modifying `spree/admin/config/locales/en.yml` (legacy admin), always normalize after.

### Default + fallback

```ruby
# config/initializers/spree.rb
I18n.default_locale = :en
I18n.fallbacks = [:en]   # missing :es key falls back to :en
```

`Spree::Current.locale` is the per-request locale. The cart pipeline + Store API set this from the `Accept-Language` header by default; storefront can override via URL prefix (`/es/products/...`), session, or domain.

## Data translations — Mobility

Spree uses [Mobility](https://github.com/shioyama/mobility) for translatable model attributes. Each model declares which fields translate:

```ruby
# spree/core/app/models/spree/product.rb (paraphrased)
class Spree::Product < Spree.base_class
  TRANSLATABLE_FIELDS = %i[name description slug meta_description meta_title].freeze
  translates(*TRANSLATABLE_FIELDS, column_fallback: !Spree.always_use_translations?)
end
```

Translations are stored in **a separate per-model table** (e.g. `spree_product_translations`) keyed by `(product_id, locale)`:

```
spree_product_translations
  ├── id
  ├── product_id
  ├── locale       ('en', 'es', 'fr', ...)
  ├── name
  ├── description
  ├── slug
  ├── meta_description
  └── meta_title
```

### Reading translations

Mobility transparently returns the translated value for `I18n.locale`:

```ruby
I18n.with_locale(:es) do
  product.name   # => "Camiseta"
end

I18n.with_locale(:en) do
  product.name   # => "T-shirt"
end
```

If the translation for the current locale is missing, behavior depends on `column_fallback`:
- **`column_fallback: true` (default unless `Spree.always_use_translations?`)** — falls back to the model's own column (which holds the default-locale value).
- **`column_fallback: false`** — returns `nil`. Use this in storefront contexts where missing translations should be hidden, not silently English.

### Writing translations

Two patterns:

```ruby
# Via locale block
I18n.with_locale(:es) do
  product.update(name: 'Camiseta', description: 'Una camiseta cómoda')
end

# Via the translation association directly
product.translations.find_or_initialize_by(locale: 'es').update!(
  name: 'Camiseta',
  description: 'Una camiseta cómoda',
)
```

### Which models translate

Out of the box (5.x+):
- `Spree::Product` — name, description, slug, meta_description, meta_title
- `Spree::Taxon` (Category) — name, description, permalink, meta_*
- `Spree::Taxonomy` — name
- `Spree::OptionType` — name, presentation
- `Spree::OptionValue` — name, presentation
- `Spree::Store` — store-level customer-facing strings

The 5.4 plan covers translating MetafieldDefinition names + Metafield text values — see `docs/plans/5.4-metafield-translations.md` if you have the monorepo.

### Locale availability

`Spree.always_use_translations?` is set per app:

```ruby
# config/initializers/spree.rb
Spree::Config[:always_use_translations] = false   # default — fallback to column for missing locale
Spree::Config[:always_use_translations] = true    # never fallback — only use translation tables
```

`true` is the right choice for stores where the column value is meaningless (e.g. it's the merchant's internal admin-only string) and only translations are customer-facing. `false` is right for single-locale stores starting out.

## RTL languages (Arabic, Hebrew, Persian)

For RTL support:

1. **Locale config:**
   ```ruby
   I18n.available_locales = %i[en ar he]
   ```
2. **Storefront direction:** the storefront detects locale direction via `I18n.t('i18n.dir', default: 'ltr')`. Spree's locale files set this; if you customize, make sure your `ar.yml` sets `i18n.dir: rtl`.
3. **Admin UI direction:** the legacy Rails admin honors RTL via Bootstrap RTL classes. The React dashboard sets `dir="rtl"` on the document root when an RTL locale is active.
4. **Mobility data** works the same — you store Arabic strings in `spree_product_translations` with `locale: 'ar'`.

## Storefront integration

The Store API responds in the locale specified by `Accept-Language` (or per-request `?locale=es`). Translated fields are returned in that locale; if the locale isn't available, fallback applies.

```bash
curl -H "X-Spree-API-Key: pk_…" \
     -H "Accept-Language: es-ES" \
     https://my-spree.example.com/api/v3/store/products/cool-shirt
# => { "name": "Camiseta", ... }
```

The `@spree/sdk` exposes `setLocale`:

```ts
const client = createClient({ baseUrl, publishableKey, locale: 'es' })
// or
client.setLocale('es')
```

See the `spree-typescript-sdk` and `spree-api-v3` skills for more.

## Common problems

### "I see `translation missing: es.spree.…`"

The key doesn't exist in the active locale. Either:
- Add the key to `config/locales/es.yml` in your app.
- Install `spree_i18n` gem if the missing key is a Spree-core string.
- Add a fallback: `I18n.fallbacks = [:en]`.

### "Product name shows English even after I set Spanish"

Walk this list:
1. `I18n.locale` is actually `:es`? Add a `puts I18n.locale` in the controller to confirm.
2. `product.translations.find_by(locale: 'es')` exists and has `name` set?
3. `column_fallback: true` would return the English column value. Check the `translates` declaration on the model; if you want strict translations, override with `column_fallback: false` in a decorator.
4. Mobility caching — calls in the same request memoize. Reload the product (`product.reload`) after writing translations in the same process.

### "Adding a new translated field"

Two steps:

1. **Generate the migration** to add columns to the per-model translation table:
   ```ruby
   class AddCustomFieldToSpreeProductTranslations < ActiveRecord::Migration[7.2]
     def change
       add_column :spree_product_translations, :custom_field, :text
     end
   end
   ```

2. **Declare it on the model** (via decorator):
   ```ruby
   module Spree::ProductDecorator
     def self.prepended(base)
       base::TRANSLATABLE_FIELDS << :custom_field
       base.translates :custom_field, column_fallback: !Spree.always_use_translations?
     end
     Spree::Product.prepend self
   end
   ```

   If the model also stores the field on the base table (for fallback), add a column there too.

### "Storefront language switcher doesn't show my new locale"

```ruby
store.update!(supported_locales: 'en,es,fr,de')
```

The storefront reads `Spree::Current.store.supported_locales` to render the switcher. If your locale isn't in that list, it's hidden even when present in `I18n.available_locales`.

### "Translations admin is missing for new content"

The 5.4 plan adds a centralized Translations admin (overview grid + bulk CSV import/export) — see `docs/plans/5.4-centralized-translations-admin.md`. Until shipped, translate via the model's own admin page (each translatable model gets a "Translations" tab).

## Where to read further

- **Mobility gem docs:** https://github.com/shioyama/mobility — backends, fallbacks, dirty tracking.
- **Spree docs:** `node_modules/@spree/docs/dist/developer/internationalization/`.
- **`spree_i18n` gem:** https://github.com/spree-contrib/spree_i18n — community translations.
- **Plan files (monorepo):** `docs/plans/5.4-centralized-translations-admin.md`, `docs/plans/5.4-metafield-translations.md`.
- **Admin SPA i18n:** see `spree-dashboard` skill — `packages/dashboard/src/locales/` + i18next setup.
