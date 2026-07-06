---
name: spree-testing
description: Use when the user is writing or running automated tests for a Spree app — model specs, controller specs, API integration tests, admin feature specs, factories, fixtures. Covers RSpec + Factory Bot + Capybara (Spree's stack — NOT Minitest + fixtures), the spree_dev_tools gem, pulling in Spree's own factories, the shared `API v3 Store` context, stub_authorization!, wait_for_turbo, and common Spree testing gotchas. Common phrasings include "test my Spree model", "Spree spec", "Factory Bot factories from Spree", "spree_dev_tools", "include_context API v3 Store", "stub_authorization", "wait_for_turbo", "Spree test setup".
---

# Spree Testing

> Commands below use the Spree CLI form (`spree …`, Docker). On a classic Rails app without the CLI (typical pre-5.4), use the native mapping in the `spree-project` skill — `bin/rails` / `bundle exec rake` from the app root, paths without the `backend/` prefix.

Spree's testing stack:

| Tool | Role |
|---|---|
| [RSpec](https://rspec.info) | Test framework (not Minitest) |
| [Factory Bot](https://github.com/thoughtbot/factory_bot_rails) | Test data (not fixtures) |
| [Capybara](https://github.com/teamcapybara/capybara) | Browser-driving feature tests |
| `spree_dev_tools` | Spree-specific helpers (authorization stub, shared contexts, factory access) |

If you've worked with vanilla Rails: drop `test/`, drop `fixtures/`, write under `spec/` with RSpec instead. Spree gems use this stack consistently — your app should too.

## Setup (one-time)

```bash
bin/rails g rspec:install            # creates spec/spec_helper.rb, spec/rails_helper.rb
bin/rails g spree_dev_tools:install  # adds Spree-specific helpers + shared contexts
```

`spree_dev_tools` is the key piece. It wires up:
- `stub_authorization!` for admin controller/feature specs
- Spree's core test helpers (factories, preferences, Capybara config)
- Factory Bot configuration that auto-loads Spree's factories
- Capybara driver setup for feature tests

For tests involving images/uploads, create a fixtures directory:

```bash
mkdir -p spec/fixtures/files
# add real file bytes — a 1x1 PNG is enough for most cases
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR...' > spec/fixtures/files/logo.png
```

## Pulling in Spree's factories

`spree_dev_tools` requires `spree/testing_support/factories` — the same factories Spree itself uses in its own specs (`spree/core/lib/spree/testing_support/factories/`). You get factories for every Spree model:

```ruby
create(:store)           # Spree::Store
create(:product)         # Spree::Product (with default_variant, prices)
create(:variant)         # Spree::Variant
create(:order)           # Spree::Order
create(:order_with_line_items)
create(:completed_order_with_totals)
create(:user)            # Spree::User
create(:admin_user)
create(:shipping_method)
create(:tax_rate)
create(:promotion)
create(:payment_method)
```

Spree mostly ships preset variations as nested child factories rather than traits — check `bundle show spree_core`/lib/spree/testing_support/factories/ for each factory's list:

```ruby
create(:product_in_stock)                            # product with stock on hand
create(:product_with_option_types)                   # product with an option type + values
create(:variant, product: product)                   # add a variant to an existing product
create(:order_with_line_items, line_items_count: 3)
create(:order_ready_to_ship)                         # complete order, payment_state 'paid', shipments ready
create(:shipped_order)
create(:shipment, state: 'ready')                    # shipment factory has no traits — override state
create(:payment, state: 'completed')                 # payment factory has no traits — override state
```

**Always use factories — never call `Model.create` directly in tests.** Factories handle dependencies (stores, currencies, shipping categories) you don't want to think about per-test.

## Writing model specs

```ruby
# spec/models/spree/brand_spec.rb
require 'rails_helper'

RSpec.describe Spree::Brand, type: :model do
  describe 'associations' do
    it 'has many products' do
      association = described_class.reflect_on_association(:products)
      expect(association.macro).to eq(:has_many)
      expect(association.class_name).to eq('Spree::Product')
    end
  end

  describe 'validations' do
    it 'validates presence of name' do
      brand = build(:brand, name: nil)
      expect(brand).not_to be_valid
      expect(brand.errors[:name]).to include("can't be blank")
    end

    describe 'slug uniqueness' do
      let!(:existing_brand) { create(:brand, slug: 'nike') }

      it 'is enforced' do
        brand = build(:brand, slug: 'nike')
        expect(brand).not_to be_valid
        expect(brand.errors[:slug]).to include('has already been taken')
      end
    end
  end
end
```

**Prefer `build` over `create`** when persistence isn't needed — it skips the database round-trip and runs ~10x faster.

### Testing decorators

When you decorate a Spree model (e.g. add `brand` to Product), write a separate spec file:

```ruby
# spec/models/spree/product_decorator_spec.rb
require 'rails_helper'

RSpec.describe 'Spree::Product brand association' do
  let(:brand) { create(:brand) }
  let(:product) { create(:product) }

  it 'can be assigned a brand' do
    product.update!(brand: brand)
    expect(product.reload.brand).to eq(brand)
  end
end
```

## Writing controller specs

Always include `render_views` so view rendering bugs surface in tests too.

### Admin controller spec

```ruby
# spec/controllers/spree/admin/brands_controller_spec.rb
require 'rails_helper'

RSpec.describe Spree::Admin::BrandsController, type: :controller do
  stub_authorization!   # grants full admin access for tests
  render_views

  describe 'GET #index' do
    let!(:brand) { create(:brand, name: 'Nike') }

    it 'returns a successful response' do
      get :index
      expect(response).to be_successful
      expect(response.body).to include('Nike')
    end
  end

  describe 'POST #create' do
    it 'creates a brand' do
      expect {
        post :create, params: { brand: { name: 'Adidas', slug: 'adidas' } }
      }.to change(Spree::Brand, :count).by(1)
    end
  end
end
```

`stub_authorization!` is the single most important admin-test helper. Without it, every test would have to log in as an admin user (slow + brittle).

### API v3 Store controller spec

Scaffolding a new API resource? `bin/rails g spree:api_resource Name attr:type` (or `spree generate api_resource ...` via the Spree CLI) scaffolds these files for you: v3 Store + Admin controller specs under `spec/controllers/spree/api/v3/{store,admin}/` and a Factory Bot factory at `spec/factories/spree/<name>_factory.rb` (FactoryBot's default scan path). Pass `--skip-specs` to skip the controller specs (the factory is always generated).

Use the shared context — it provisions a default store + a publishable API key. The `'API v3 Store'` / `'API v3 Admin'` shared contexts live in the `spree_api` gem — add `require 'spree/api/testing_support/v3/base'` at the top of the spec (after `require 'rails_helper'`) before `include_context 'API v3 Store'`.

```ruby
# spec/controllers/spree/api/v3/store/brands_controller_spec.rb
require 'rails_helper'
require 'spree/api/testing_support/v3/base'

RSpec.describe Spree::Api::V3::Store::BrandsController, type: :controller do
  render_views
  include_context 'API v3 Store'

  let!(:brand) { create(:brand, name: 'Nike') }

  before do
    request.headers['X-Spree-Api-Key'] = api_key.token
  end

  describe 'GET #index' do
    it 'returns a list of brands' do
      get :index
      expect(response).to have_http_status(:ok)
      expect(json_response['data'].size).to eq(1)
    end

    it 'returns prefixed IDs' do
      get :index
      expect(json_response['data'].first['id']).to start_with('brand_')
    end

    it 'filters by name' do
      create(:brand, name: 'Adidas')
      get :index, params: { q: { name_cont: 'nik' } }
      expect(json_response['data'].size).to eq(1)
    end
  end

  describe 'GET #show' do
    it 'returns the brand by prefixed ID' do
      get :show, params: { id: brand.prefixed_id }
      expect(json_response['name']).to eq('Nike')
    end
  end
end
```

`json_response` comes from `Spree::TestingSupport::ApiHelpers` (defined in spree_dev_tools' generated `spec/support/spree.rb`), which is only included for `type: :request` specs by default. For API controller specs, extend the include in `spec/support/spree.rb`: `config.include Spree::TestingSupport::ApiHelpers, type: :controller`.

Equivalent shared context for admin: `include_context 'API v3 Admin'` (provisions admin JWT + a secret key). Use it for Admin API controller specs.

### When to write controller specs vs API integration specs

**Default to controller specs.** Use them for:
- Edge cases (filter combinations, missing params, authorization edges)
- Happy path + the 422s you care about
- All controllers you wrote

**Use API integration specs (`spec/integration/`) sparingly.** They drive request → middleware → controller → response end-to-end, and they generate OpenAPI examples via Rswag. Reserve them for:
- One happy-path test per public endpoint (powers OpenAPI examples)
- One representative 422 test per endpoint

Integration specs are slow and brittle to maintain. Don't try to cover every combination there — controller specs do that better.

## Writing feature specs (Capybara)

Feature specs use rack_test by default (no browser, no JavaScript); tag examples with `js: true` to drive a real headless Chrome browser through the Rails admin (or storefront). Turbo-driven admin pages need `js: true` — without it, `wait_for_turbo` and any Turbo Stream/Frame behavior is a no-op.

```ruby
# spec/features/spree/admin/brands_spec.rb
require 'rails_helper'

RSpec.feature 'Admin Brands', type: :feature do
  stub_authorization!

  describe 'creating a brand' do
    it 'creates successfully' do
      visit spree.admin_brands_path
      click_on 'New Brand'
      fill_in 'Name', with: 'Puma'
      fill_in 'Slug', with: 'puma'
      click_on 'Create'
      wait_for_turbo

      expect(page).to have_content('Brand "Puma" has been successfully created!')
      expect(Spree::Brand.find_by(name: 'Puma')).to be_present
    end
  end
end
```

### `wait_for_turbo`

The Rails admin uses Turbo (Hotwire). After clicking a button that triggers a Turbo Stream / Frame update, the response is async — Capybara needs to wait for the DOM update. `wait_for_turbo` waits for Turbo's in-flight requests to settle.

`wait_for_turbo` comes from `Spree::Admin::TestingSupport::CapybaraUtils` in the `spree_admin` gem. On a standard `spree_dev_tools` setup it's already available — `rails_helper` requires `spree_dev_tools/rspec/spec_helper`, whose own support glob loads the gem's `spree_admin.rb`, which includes the module. If your setup only globs your app's `spec/support/` and you hit `NoMethodError: undefined method 'wait_for_turbo'`, add a `spec/support/spree_admin.rb`:

```ruby
require 'spree/admin/testing_support/capybara_utils'

RSpec.configure do |config|
  config.include Spree::Admin::TestingSupport::CapybaraUtils, type: :feature
end
```

```ruby
click_on 'Create'
wait_for_turbo            # <- without this, the next expect runs before the update
expect(page).to have_content('Success!')
```

Many Capybara matchers (`have_content`, `have_css`) auto-poll, so they often work without `wait_for_turbo`. Use it explicitly when:
- You're asserting on something OUTSIDE the page DOM (record count in DB).
- You're chaining a second action after the first (`click_on 'Edit'` immediately after the previous form submit).

## Running tests

```bash
bundle exec rspec                            # all
spree exec bundle exec rspec                 # Spree CLI (Docker) projects: runs inside the web container (invoke as `npx spree` / `pnpm exec spree` if not on PATH)
bundle exec rspec spec/models/spree/brand_spec.rb    # one file
bundle exec rspec spec/models/spree/brand_spec.rb:15 # one test (line number)
bundle exec rspec spec/features/             # one directory
bundle exec rspec --format documentation     # readable output
bundle exec rspec --tag focus                # filter by tag

# Parallel (after `bundle exec rake parallel_setup`)
bundle exec parallel_rspec spec
bundle exec parallel_rspec -n 4 spec         # 4 workers
```

When developing the Spree gems themselves or a Spree extension — not a Spree app — specs run against a generated dummy app; after schema changes regenerate it:

```bash
bundle exec rake test_app                    # default SQLite
DB=postgres DB_USERNAME=postgres DB_PASSWORD=password DB_HOST=localhost bundle exec rake test_app
```

(Spree's engine Rakefiles define `test_app` via `spree/testing_support/common_rake`; extension Rakefiles delegate to `extension:test_app` from `spree/testing_support/extension_rake`. `bundle exec rake parallel_setup` is likewise engine/extension-only.) Then re-run `parallel_setup` for parallel workers.

In a Spree *app* there is no dummy app to regenerate — after running migrations, just run `bin/rails db:test:prepare`.

## Common Spree testing gotchas

### "spree_dummy_models table missing"

(Spree gem development only — this hits Spree's own core/admin test suites, not apps or extensions; apps don't even have a `test_app` task.) The gem's dummy app is stale. Regenerate from the gem directory: `bundle exec rake test_app`.

### "ActiveRecord::ConnectionPool…" in parallel

You skipped `parallel_setup`. Each worker needs its own DB:

```bash
bundle exec rake parallel_setup
```

### "Wrong currency in test"

The order factory hardcodes `currency { 'USD' }`, so orders are USD no matter what the store's `default_currency` is. To test another currency, be explicit:

```ruby
create(:order, currency: 'EUR')
```

### "Variant has no price"

`create(:variant)` doesn't always create a Price in your test currency. Force it:

```ruby
variant = create(:variant)
variant.prices.create!(currency: 'EUR', amount: 10.00)
```

Or use the factory's transients: `create(:variant, price: 10.0, currency: 'EUR')` — the factory's `after(:create)` hook calls `set_price` with these, creating the Price in that currency.

### "Image attachments fail"

You used `build(:image)` instead of `create(:image)`. Image fixtures need ActiveStorage to actually attach the file — that happens in the `before(:create)` hook. Always `create`.

### "Time-dependent test flakes around midnight"

Use Timecop:

```ruby
Timecop.freeze(Time.zone.local(2025, 1, 1, 12, 0)) do
  # the entire block thinks it's noon on 2025-01-01
end
```

Don't write `Time.now` and hope.

### "Stock-related test fails when other tests interfered"

Tests should clean up between runs (DatabaseCleaner). If you're seeing stock_items from other tests, check `spec/support/database_cleaner.rb` (loaded via the support-file glob in `rails_helper.rb`) — `rails g spree_dev_tools:install` generates it, but custom config can break it.

### "TestApp regeneration is slow"

The Spree test app boots the full stack. Once generated, don't regenerate unless schema changed. Use `RAILS_ENV=test bin/rails db:rollback` for migration tweaks.

## What NOT to test

Don't test framework guarantees. (Spree's own `CLAUDE.md` states the validations rule — "no tests for standard Rails validations, only custom ones"; the rest below is this skill's guidance in the same spirit.)

- ❌ Strong params filtering (it's Rails — proven, exhaustively tested upstream)
- ❌ Presence validations on standard attributes (write tests for validations YOU customized)
- ❌ Standard Rails associations (write tests when your decorator adds behavior)
- ❌ Tests asserting on private methods or instance variables

DO test:
- ✅ Custom business logic (services, custom calculator math, scope chaining)
- ✅ Custom validations (uniqueness scope, conditional presence)
- ✅ Decorator behavior — the new code you wrote, not the unchanged inherited code
- ✅ Regression cases — anything a bug report led to

## Best practices

- **`build` over `create`** for unit tests; `create` only when persistence matters.
- **`let` over instance variables** — lazy, scoped per example.
- **One behavior per `it`**, with `aggregate_failures` when you need multiple assertions on the same setup.
- **Test behavior, not implementation** — `expect(brand.products).to include(product)` over `expect(brand.products).to be_a(ActiveRecord::Relation)`.
- **Real factories, not stubs**, unless the stubbed thing is external (HTTP, Stripe API).
- **Don't reset instance variables** to paper over broken test infrastructure — fix the shared setup.

## Where to read further

- **Spree's own factories:** `bundle show spree_core`/lib/spree/testing_support/factories/ — read these to discover available traits.
- **`spree_dev_tools` source:** look at `lib/spree_dev_tools/generators/install/` and `lib/spree_dev_tools/rspec/support/` to see exactly what it adds.
- **Full tutorial:** `docs/developer/tutorial/testing.mdx` in the Spree docs — covers the Brand example end-to-end.
- **RSpec docs:** https://rspec.info/documentation/
- **Factory Bot guide:** https://github.com/thoughtbot/factory_bot/blob/main/GETTING_STARTED.md
