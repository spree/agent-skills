---
name: spree-promotions
description: Use when the user is working with Spree promotions, discounts, or coupon codes — configuring a promo, writing a custom promotion rule, building a custom action, applying a discount programmatically, the Promotion→Discount rename in 6.0. Common phrasings include "create promotion", "coupon code", "discount", "BOGO", "free shipping promotion", "promotion not applying", "custom promotion rule", "stack promotions". Provides the Promotion / PromotionRule / PromotionAction / Calculator graph and customization points.
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

A promo can have multiple rules (ANDed together) and multiple actions (all fire when eligible).

## Promotion attributes

```ruby
Spree::Promotion.create!(
  name: 'Summer Sale 2026',
  code: 'SUMMER20',                 # nil for automatic (no code needed)
  starts_at: Date.new(2026, 6, 1),
  expires_at: Date.new(2026, 9, 1),
  usage_limit: 1000,                # max total redemptions; nil = unlimited
  match_policy: 'all',              # 'all' (AND) or 'any' (OR) for rule matching
  advertise: true                   # show in store header / banners
)
```

**Coupon codes:** When `code` is present, the customer must enter it. When nil, the promo applies automatically if rules match.

**Per-customer limits:** Add a `Spree::Promotion::Rules::OneUsePerUser` rule. The customer must be logged in (anonymous orders can't enforce per-customer limits — no identity).

## Built-in PromotionRule subclasses

Each rule subclasses `Spree::PromotionRule` and implements `eligible?(order, options = {})`.

| Rule | Eligibility |
|---|---|
| `ItemTotal` | Order subtotal ≥ X (or ≤ X — configurable operator) |
| `Product` | At least one matching product is in the cart |
| `Taxon` | At least one matching category is in the cart |
| `User` | The specific customer is on the order |
| `CustomerGroup` | The customer is in a specific group |
| `FirstOrder` | The customer hasn't completed an order before |
| `OneUsePerUser` | The customer hasn't used this promo before |
| `Country` | The order's billing/shipping country matches |
| `Currency` | The cart's currency matches |
| `OptionValue` | At least one variant in the cart has a matching option value |

Rules combine via the promo's `match_policy`:
- `all` — every rule must be eligible (default)
- `any` — at least one rule must be eligible

## Built-in PromotionAction subclasses

Each action subclasses `Spree::PromotionAction` and implements `perform(payload)`.

| Action | Effect |
|---|---|
| `CreateAdjustment` | One adjustment on the whole order (e.g. $10 off the total) |
| `CreateItemAdjustments` | One adjustment per eligible line item (e.g. 20% off matching products) |
| `CreateLineItems` | Add a free product to the cart (BOGO) |
| `FreeShipping` | Zero out shipping cost |

Actions consult a **Calculator** for the amount. `Spree::Calculator::FlatRate` gives $10 off; `Spree::Calculator::PercentOnLineItem` gives 20% off matching items; `Spree::Calculator::FlatPercentItemTotal` gives 10% off the cart total.

## Anatomy of a real promotion

"20% off T-shirts, max $50 discount, requires code SUMMER20, first 1000 customers":

```ruby
promo = Spree::Promotion.create!(
  name: 'T-shirt 20% off (Summer)',
  code: 'SUMMER20',
  usage_limit: 1000,
  match_policy: 'all',
  starts_at: 2.weeks.from_now,
  expires_at: 6.weeks.from_now
)

# Rule: must contain a T-shirt
tshirts = Spree::Category.find_by(name: 'T-Shirts')
promo.rules << Spree::Promotion::Rules::Taxon.new(taxon_ids: [tshirts.id])

# Action: 20% off matching items, capped at $50
calculator = Spree::Calculator::PercentOnLineItem.new(preferred_percent: 20)
action = Spree::Promotion::Actions::CreateItemAdjustments.new(calculator: calculator)
# Cap separately if needed via a custom calculator subclass
promo.actions << action
```

In production, most promos are configured via the admin UI — these models exist so the code path is consistent whether the source is admin clicks or programmatic.

## Custom PromotionRule

Subclass and implement `eligible?`. Register in `Spree.promotions.rules.register(...)`:

```ruby
# backend/app/models/spree/promotion/rules/has_metafield.rb
module Spree::Promotion::Rules
  class HasMetafield < Spree::PromotionRule
    preference :key, :string
    preference :value, :string

    def eligible?(order, options = {})
      return false unless order.user
      order.user.metafield(preferred_key) == preferred_value
    end

    def applicable?(promotable)
      promotable.is_a?(Spree::Order)
    end
  end
end

# backend/config/initializers/spree.rb
Rails.application.config.after_initialize do
  Spree.promotions.rules.register(Spree::Promotion::Rules::HasMetafield)
end
```

After registration, the admin UI shows the new rule type in the rule selector.

`eligible?` is called per-order during the cart pipeline. Keep it cheap — N+1 queries here are the #1 cart-pipeline performance issue.

## Custom PromotionAction

Subclass `Spree::PromotionAction` and implement `perform`:

```ruby
# backend/app/models/spree/promotion/actions/award_loyalty_points.rb
module Spree::Promotion::Actions
  class AwardLoyaltyPoints < Spree::PromotionAction
    preference :points, :integer, default: 100

    def perform(payload)
      order = payload[:order]
      return unless order.user
      order.user.loyalty_points_account.add(preferred_points, source: promotion)
    end
  end
end

# Register in initializer:
Spree.promotions.actions.register(Spree::Promotion::Actions::AwardLoyaltyPoints)
```

`perform` runs during cart recalculate. Like rules, keep it cheap and idempotent — recalculate can fire many times per cart change.

## Custom Calculator

Calculators answer "given X, how much discount?" The same Calculator subclass can be used by multiple action types.

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

# Available to all action types:
Spree::Calculator::PercentWithCap.new(preferred_percent: 20, preferred_cap_amount: 50)
```

## Promotion stacking

Multiple promotions can apply to one order. The cart pipeline runs each eligible action, creating an adjustment per action. Default behavior: **all eligible promotions stack**.

If you want exclusive promos (only the best discount applies), implement that in a decorator on `Spree::Promotion`:

```ruby
module Spree::PromotionDecorator
  def self.prepended(base)
    base.scope :exclusive, -> { where(advertise: true) }   # convention
  end
  Spree::Promotion.prepend self
end

# Then in your custom recalculate service, before applying actions, filter to keep only
# the highest-discount exclusive promo.
```

Most stores don't customize this — stacking by default is what merchants expect.

## Promotion → Discount rename (6.0)

In 6.0, the Promotion concept is being renamed to Discount in the public-facing Store API while staying as `Spree::Promotion` internally (model + table stay the same). Reasons:

1. "Promotion" suggests advertising; "Discount" is what customers see at checkout.
2. The internal Promotion model has historical baggage that's being cleaned up alongside.

For now: write code against `Spree::Promotion`. The Store API may surface it as "Discount" in 6.0 — admins still see "Promotions" in the back office.

## Common promotion problems

### "Promotion isn't applying"

Walk this list:

1. **Is the code right?** Coupon codes are case-insensitive but must match exactly otherwise.
2. **Within the window?** `promotion.starts_at < Time.current && (promotion.expires_at.nil? || promotion.expires_at > Time.current)`.
3. **Usage limit not exceeded?** `promotion.usage_count < promotion.usage_limit` (nil limit = unlimited).
4. **Every rule eligible?** With `match_policy: 'all'`, every rule must return true. Walk `promotion.rules.map { |r| [r.class.name, r.eligible?(order)] }` to see which fails.
5. **Action ran during recalculate?** Check `order.adjustments.where(source_type: 'Spree::PromotionAction')`. If empty, the action never fired — usually a stale recalculate; run `Spree::Cart::Recalculate.call(order: order)` and re-check.

### "Promotion stacks when it shouldn't"

Default is to stack. Implement an exclusive-discount policy in your custom recalculate service (see above).

### "Custom rule isn't showing in admin UI"

Confirm registration: `Spree.promotions.rules.partial_for(MyRule.new)` should return a partial path. If it crashes, your rule didn't get registered — check the initializer fires after Rails boot.

## Where to read further

- **Source:** `bundle show spree_core`/app/models/spree/promotion/ — the full hierarchy of rules and actions.
- **Calculators:** `Spree::Calculator` subclasses live in `spree_core/app/models/spree/calculator/`.
- **Adjustments:** see the `spree-data-model` skill — promotions create Adjustments tied to Orders/LineItems/Shipments.
- **Docs:** `backend/node_modules/@spree/docs/dist/developer/core-concepts/promotions.mdx`.
