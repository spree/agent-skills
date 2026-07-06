---
name: spree-promotions
description: Use when the user is working with Spree promotions, discounts, or coupon codes — configuring a promo, writing a custom promotion rule, building a custom action, applying a discount programmatically. Common phrasings include "create promotion", "coupon code", "discount", "BOGO", "free shipping promotion", "promotion not applying", "custom promotion rule", "stack promotions". Provides the Promotion / PromotionRule / PromotionAction / Calculator graph and the customization points documented at `docs/developer/how-to/custom-promotion.mdx`.
---

# Spree Promotions

A promotion is "if X is true about the cart, do Y." Spree breaks that into:

```
Promotion           — the campaign (name, dates, code, usage limits)
  ├── PromotionRule × n        — eligibility checks: "if X is true"
  ├── PromotionAction × n      — what to do: "create a discount", "free shipping"
  │     └── Calculator         — how much (flat $, %, per-item, etc.)
  └── PromotionCategory        — admin grouping
```

A promo can have multiple rules (ANDed or ORed via `match_policy`) and multiple actions (all fire when eligible).

## Promotion attributes

```ruby
Spree::Promotion.create!(
  name: 'Summer Sale 2026',
  code: 'SUMMER20',                 # required for the default kind: :coupon_code; pass kind: :automatic for no-code promos
  starts_at: Date.new(2026, 6, 1),
  expires_at: Date.new(2026, 9, 1),
  usage_limit: 1000,                # max total redemptions; nil = unlimited
  match_policy: 'all',              # 'all' (AND) or 'any' (OR) for rule matching
  advertise: true                   # show in store header / banners
)
```

- **Coupon codes vs automatic:** promotions have a `kind` enum — `coupon_code` (default) or `automatic`. Coupon-code promos require `code` (normalized to lowercase; matched case-insensitively). For promos that apply automatically when rules match, pass `kind: :automatic` — leaving `code` nil without it fails validation, since `kind` defaults to `coupon_code`.
- **Bulk codes:** for many unique single-use codes (one per email blast, influencer, etc.), set `multi_codes: true` + `number_of_codes:` (optionally `code_prefix:`) — Spree generates `Spree::CouponCode` records (`promotion.coupon_codes`) instead of using the single `code` column, and `usage_limit` doesn't apply.
- **Console caveat:** `store` is validated as present and auto-filled from `Spree::Current.store` — in a bare console/rake context set it explicitly (`store: Spree::Store.default`) or the `create!` above raises.
- **Per-customer limits:** add a `Spree::Promotion::Rules::OneUsePerUser` rule. The customer must be logged in (anonymous orders can't enforce per-customer limits — no identity).

## Built-in PromotionRule subclasses

Each rule subclasses `Spree::PromotionRule` and implements `eligible?(promotable, options = {})`.

| Rule | Eligibility |
|---|---|
| `Channel` | The order's channel is in a configured set of channels |
| `Country` | The order's shipping country is in the configured ISO code list (defaults to the store's default country) |
| `Currency` | The cart's currency matches |
| `CustomerGroup` | The customer is in a specific group |
| `FirstOrder` | The customer hasn't completed an order before |
| `ItemTotal` | Order subtotal meets a threshold (configurable operator) |
| `Market` | The order's market matches |
| `OneUsePerUser` | The customer hasn't used this promo before |
| `OptionValue` | At least one variant in the cart has a matching option value |
| `Product` | At least one matching product is in the cart |
| `Taxon` | At least one matching category is in the cart |
| `User` | The specific customer is on the order |
| `UserLoggedIn` | The customer is authenticated |

Rules combine via the promo's `match_policy`:
- `all` — every rule must be eligible (default)
- `any` — at least one rule must be eligible

## Built-in PromotionAction subclasses

Each action subclasses `Spree::PromotionAction` and implements `perform(options = {})`.

| Action | Effect |
|---|---|
| `CreateAdjustment` | One adjustment on the whole order (e.g. $10 off the total) |
| `CreateItemAdjustments` | One adjustment per eligible line item (e.g. 20% off matching products) |
| `CreateLineItems` | Auto-add configured variants to the cart when eligible (added at normal price — pair with a discount action to make them free / BOGO) |
| `FreeShipping` | Zero out shipping cost |

Discount actions consult a **Calculator** for the amount. `Spree::Calculator::FlatRate` gives a flat amount off; `Spree::Calculator::PercentOnLineItem` gives a percentage off matching items; `Spree::Calculator::FlatPercentItemTotal` gives a percentage off the cart total. The full calculator catalog lives at `Spree::Calculator` subclasses in `spree_core/app/models/spree/calculator/`.

## Custom PromotionRule

Subclass `Spree::PromotionRule`, implement `applicable?` + `eligible?`, register in an initializer, add an admin partial:

```ruby
# app/models/spree/promotion/rules/minimum_quantity.rb
module Spree
  class Promotion
    module Rules
      class MinimumQuantity < Spree::PromotionRule
        preference :quantity, :integer, default: 5

        def applicable?(promotable)
          promotable.is_a?(Spree::Order)
        end

        def eligible?(order, options = {})
          total_quantity = order.line_items.sum(&:quantity)
          return true if total_quantity >= preferred_quantity

          eligibility_errors.add(:base, "Order must contain at least #{preferred_quantity} items")
          false
        end
      end
    end
  end
end
```

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.promotions.rules << Spree::Promotion::Rules::MinimumQuantity
end
```

```erb
# app/views/spree/admin/promotion_rules/forms/_minimum_quantity.html.erb
# The partial name must match the rule's `key` (`api_type` — demodulized, underscored class name by default).
# Action partials go in app/views/spree/admin/promotion_actions/forms/.
<div class="row mb-3">
  <%= f.spree_number_field :preferred_quantity, label: Spree.t(:minimum_quantity) %>
</div>
```

Add locale entries under `spree.minimum_quantity` and `spree.promotion_rule_types.minimum_quantity.{name,description}`. The admin selector reads from those keys.

### Key methods on a rule

| Method | Required | Description |
|---|---|---|
| `applicable?(promotable)` | Yes | Whether this rule can evaluate the promotable (usually `promotable.is_a?(Spree::Order)`) |
| `eligible?(promotable, options = {})` | Yes | Whether the promotable meets the rule. Add messages to `eligibility_errors` to explain `false` |
| `actionable?(line_item)` | No | Whether a specific line item should receive the action's adjustment. Default `true`. Override for rules that target specific items (product, category) |

`eligible?` is called per-order during the cart pipeline. Keep it cheap — N+1 queries here are a common cart-pipeline performance issue.

## Custom PromotionAction

Subclass `Spree::PromotionAction` and implement `perform`. Discount actions also include `Spree::CalculatedAdjustments` + `Spree::AdjustmentSource`:

```ruby
# app/models/spree/promotion/actions/tiered_discount.rb
module Spree
  class Promotion
    module Actions
      class TieredDiscount < Spree::PromotionAction
        include Spree::CalculatedAdjustments
        include Spree::AdjustmentSource

        before_validation -> { self.calculator ||= Calculator::FlatRate.new }

        def perform(options = {})
          order = options[:order]
          return false unless order.present?

          create_unique_adjustment(order, order)
        end

        def compute_amount(order)
          discount = case order.item_total
                     when 100..Float::INFINITY then 25
                     when 50..99.99 then 10
                     else 0
                     end

          # Discounts are negative; cap to prevent negative orders
          [discount, order.item_total].min * -1
        end
      end
    end
  end
end
```

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.promotions.actions << Spree::Promotion::Actions::TieredDiscount
end
```

Non-discount actions (award points, send notifications) don't need the calculator includes — just implement `perform`.

### Key methods on an action

| Method | Required | Description |
|---|---|---|
| `perform(options = {})` | Yes | Called when the promotion activates. `options` includes `:order` and `:promotion`. Return `true` if the action was applied |
| `compute_amount(adjustable)` | For discount actions | Return the adjustment amount (negative for discounts). Cap at the adjustable's total |
| `revert(options = {})` | No | Called when the promotion deactivates. Use to undo side effects (e.g., remove added line items) |

`perform` runs during cart recalculate. Keep it cheap and idempotent — recalculate fires on many cart changes.

### Helper methods from the includes

```ruby
# Spree::AdjustmentSource:
create_unique_adjustment(order, adjustable)
create_unique_adjustments(order, order.line_items)
create_unique_adjustments(order, order.line_items) do |line_item|
  promotion.line_item_actionable?(order, line_item)
end

# Spree::CalculatedAdjustments:
compute(adjustable)                                # calls calculator.compute(adjustable)
self.calculator_type = 'Spree::Calculator::FlatRate'
self.class.calculators                              # available calculators
```

## Custom Calculator

Calculators answer "given X, how much?" — the same calculator subclass can be used by multiple action types.

```ruby
module Spree
  class Calculator::PercentWithCap < Spree::Calculator
    preference :percent, :decimal, default: 10
    preference :cap_amount, :decimal, default: 50

    def compute(object)
      base = object.amount.to_d
      raw = base * (preferred_percent / 100.0)
      [raw, preferred_cap_amount].min
    end
  end
end
```

Register so the action's "available calculators" picker shows it:

```ruby
Rails.application.config.after_initialize do
  Spree.calculators.promotion_actions_create_item_adjustments << Spree::Calculator::PercentWithCap
  # order-level actions read from Spree.calculators.promotion_actions_create_adjustments
end
```

## Promotion stacking

Multiple promotions can each create adjustments, but Spree does not stack them on the same target. During recalculation `Spree::Adjustable::Adjuster::Promotion` (registered by default in `Rails.application.config.spree.adjusters`) keeps only the single best (largest-discount) eligible promo adjustment per adjustable — order, line item, or shipment — and marks competing promo adjustments `eligible: false`; on a tie the most recently created wins. Promotions targeting *different* adjustables can still combine (e.g. an order-level discount plus a line-item discount on the same order).

To change this behavior (e.g. allow stacking on one adjustable), swap in a custom adjuster via `Rails.application.config.spree.adjusters`.

## Common promotion problems

### "Promotion isn't applying"

Walk this list:

1. **Is the code right?** Coupon codes are matched case-insensitively but must otherwise match exactly. On `multi_codes` promos, check the `Spree::CouponCode` records (`promotion.coupon_codes`) — each is single-use (`state: 'used'` once redeemed).
2. **Within the window?** `promotion.starts_at < Time.current && (promotion.expires_at.nil? || promotion.expires_at > Time.current)`.
3. **Usage limit not exceeded?** `promotion.usage_limit_exceeded?(order)` should be false (nil limit = unlimited). To inspect manually, `promotion.credits_count` is the number of distinct orders that have used the promo — compare it against `promotion.usage_limit` when a limit is set.
4. **Every rule eligible?** With `match_policy: 'all'`, every rule must return true. Walk `promotion.rules.map { |r| [r.class.name, r.eligible?(order)] }` to see which fails. Check `r.eligibility_errors.full_messages` for the reason.
5. **Action ran during recalculate?** Check `order.all_adjustments.promotion` — `order.adjustments` only holds order-level adjustments; `CreateItemAdjustments` writes to line items and `FreeShipping` to shipments. If empty, the action never fired — recalculate to retry.

### "Custom rule isn't showing in admin UI"

Confirm registration ran: `Spree.promotions.rules.include?(Spree::Promotion::Rules::MyRule)` should be true after Rails boot. Confirm the admin partial exists at `app/views/spree/admin/promotion_rules/forms/_<key>.html.erb` (the rule's `key` / `api_type`). Confirm locale keys under `spree.promotion_rule_types.<underscored_class>.{name,description}` are present.

## Where to read further

- **Core concepts:** `node_modules/@spree/docs/dist/developer/core-concepts/promotions.md`
- **Custom rules + actions tutorial:** `node_modules/@spree/docs/dist/developer/how-to/custom-promotion.md`
- **Source:** `Spree::Promotion`, `Spree::PromotionRule`, `Spree::PromotionAction`, `Spree::Calculator` in the installed `spree_core` gem
- **Adjustments:** see the `spree-data-model` skill — promotions create Adjustments tied to Orders, LineItems, or Shipments
