# spree/agent-skills

Agent skills for [Spree Commerce](https://spreecommerce.org) — works with Claude Code, Codex, Cursor, Copilot, Cline, Aider, Zed, Windsurf, OpenCode, and 60+ other agentic CLIs.

## Install

```bash
npx skills add spree/agent-skills
```

That's it. The [`skills`](https://github.com/vercel-labs/skills) CLI auto-detects which agent(s) you have installed and copies the skill files into each agent's native location. Works in any project — new or existing.

Want to see what's available without installing?

```bash
npx skills add spree/agent-skills --list
```

Want a specific subset?

```bash
npx skills add spree/agent-skills --skill spree-api-v3 --skill spree-checkout
```

Update later:

```bash
npx skills update
```

## What ships

### 38 skills

Targets **Spree 6.x** (Rails 8.1). Working on Spree 5.x? Install the [`v0.3.0`](https://github.com/spree/agent-skills/tree/v0.3.0) release instead.

| Skill | When it activates |
|---|---|
| `spree-project` | General Spree project context — layout (`server/`, `apps/dashboard`), conventions, CLI vs classic Rails flavor. |
| `spree-customization` | Decision tree for "where does my customization belong" — hook vs subscriber vs provider vs decorator. Use FIRST when the pattern isn't obvious. |
| `spree-workflows` | `Spree::Workflow` and `Spree.hooks` — validate, lifecycle and context hooks; `has_status`. |
| `spree-resource` | Adding a new model + API endpoint via the `spree:api_resource` generator, or a model-only resource via `spree:model`. |
| `spree-decorators` | Extending existing Spree classes via decorators (`Module#prepend`) — the last resort. |
| `spree-dependencies` | Swapping core workflows, services and serializers via `Spree.dependencies`. |
| `spree-extensions` | Installing official gems or building your own extension (engine + dashboard plugin). |
| `spree-providers` | Plugging in tax, delivery rate, fulfillment, payment, search, payout, digital asset and auth providers. |
| `spree-api-v3` | REST API v3 — Store, Admin and Seller surfaces, auth, scopes, prefixed IDs, envelopes, errors. |
| `spree-typescript-sdk` | `@spree/sdk`, `@spree/admin-sdk`, `@spree/seller-sdk` — auth, types, webhooks, extension patterns. |
| `spree-cli` | `spree api` — call/inspect the Admin API from the terminal. Especially for debugging. |
| `spree-auth-permissions` | Staff roles as data, permission keys, API key scopes, SSO and custom authentication. |
| `spree-data-model` | Domain model — stores, channels, markets, carts vs orders, customers, companies, prefixed IDs. |
| `spree-catalog` | Products, variants, options, product types, categories, collections, media, custom fields, search. |
| `spree-pricing` | Prices per currency, price lists, catalogs, volume pricing, EU Omnibus price history. |
| `spree-inventory` | Stock levels, reservations, backorders, purchase orders, suppliers, transfers. |
| `spree-checkout` | Cart → order completion, the requirements feed, `Spree::Checkout::Registry`, checkout hooks. |
| `spree-order-totals` | Tax lines, discounts and fees; totals recalculation; money freeze after placement. |
| `spree-taxes` | Tax categories and rates, per-market tax providers, exemptions. |
| `spree-payments` | Payment methods, sessions, capture, refunds, gift cards, store credits. |
| `spree-promotions` | Promotion rules, actions, calculators, coupon codes. |
| `spree-fulfillment` | Fulfillments, delivery methods, zones and profiles, rates, order routing, stock splitters. |
| `spree-returns` | Returns, exchanges and claims — workflows, eligibility policy, refunds. |
| `spree-marketplace` | Multi-vendor marketplaces — sellers, onboarding, commissions, payouts, Seller API. |
| `spree-b2b` | B2B / wholesale — companies, catalogs, customer groups, gated channels, PO numbers, freight. |
| `spree-multi-tenant` | Multi-tenant SaaS platform on Spree Enterprise. |
| `spree-reporting` | Reporting metrics and dimensions, saved reports, imports and exports. |
| `spree-dashboard` | Customizing the React admin dashboard — navigation, routes, slots, tables, forms, theming. |
| `spree-dashboard-plugins` | Scaffolding, packaging and publishing dashboard plugins. |
| `spree-storefront` | The Next.js storefront and `@spree/sdk`. |
| `spree-events-webhooks` | Events, subscribers and outbound webhooks (HMAC signing, retries with backoff, auto-disable, delivery-log redaction). |
| `spree-i18n` | UI translations (`Spree.t` + YAML) and data translations (Mobility). |
| `spree-testing` | RSpec + Factory Bot, `spree_dev_tools`, the API v3 shared contexts, dashboard tests. |
| `spree-security` | Rails security + Spree-specific (secrets, encryption, webhook HMAC, data privacy, PCI). |
| `spree-performance` | Recalculation, catalog N+1s, search latency, job queues, observability. |
| `spree-deployment` | Deploying to Docker, Render, AWS — env vars, Solid Queue, dashboard build, S3/CDN. |
| `spree-upgrade` | Upgrading Spree — `spree upgrade`, manifests, data steps, production release. |
| `spree-upgrade-5-to-6` | The Spree 5.6 → 6.0 upgrade — preconditions, backfills, grep recipes for breaking changes. |

### `spree-expert` subagent

Invoked by Claude (not the user) for multi-step Spree work that benefits from a fresh context — audits, multi-resource API planning, checkout flow investigations.

### Two slash commands (Claude Code plugin only)

| Command | What it does |
|---|---|
| `/spree:doctor` | Diagnose the local dev stack — Docker, containers, env, web, migrations, job queues — and prescribe the exact fix. |
| `/spree:audit-upgrade [version]` | Read-only upgrade-readiness audit: checks the target version's breaking changes against your code (via the `spree-expert` subagent), shows the manifest plan, and produces a remediation checklist. |

### Two safety hooks (Claude Code only)

| Hook | What it does |
|---|---|
| `PreToolUse` on `Bash` | Blocks destructive database commands (`rake db:drop`, `Spree::Model.delete_all`, raw `DROP TABLE spree_*`, force-push to main/master). |
| `PostToolUse` on `Edit`/`Write`/`MultiEdit` | Warns when an edit adds a hardcoded secret (Stripe live keys, AWS access keys, GitHub PATs, OpenAI/Anthropic keys). |

Hooks honor `SPREE_HOOKS_DISABLE=1` as an escape hatch. Like the slash commands, they require the Claude Code plugin install path below — `npx skills add` installs skills, but not subagent, commands or hooks (the `${CLAUDE_PLUGIN_ROOT}` path resolution that hooks need only works under the plugin install).

## Claude Code: also get the safety hooks

If you're on Claude Code and want the safety hooks too, install as a plugin **from inside a Claude Code session**:

```text
/plugin marketplace add spree/agent-skills
/plugin install spree@spree
```

Plugin install gives you everything `npx skills add` does **plus** subagent and the two slash commands and the two safety hooks. Use one path or the other — don't double-install (skills will collide).

## Cross-tool compatibility

`npx skills add` handles the per-tool delivery. Under the hood it places skill files where each tool expects:

| Tool | Where files land |
|---|---|
| Claude Code | `.claude/skills/`, `.claude/agents/` |
| Codex CLI | `AGENTS.md` walked from cwd to git root + per-skill files |
| Cursor | `.cursor/rules/*.mdc` |
| Copilot | `AGENTS.md` |
| Cline | `.clinerules/` |
| Aider, Zed, Windsurf, Amp | `AGENTS.md` |
| OpenCode | Native skill format |
| 60+ others | Each tool's native convention |

See [`vercel-labs/skills`](https://github.com/vercel-labs/skills) for the full agent matrix.

## Manual install (offline / air-gapped)

If you can't use `npx skills`:

```bash
git clone https://github.com/spree/agent-skills.git
mkdir -p .claude/skills .claude/agents
cp -R agent-skills/skills/* .claude/skills/
cp -R agent-skills/agents/* .claude/agents/
```

Or copy the [`AGENTS.md`](./AGENTS.md) to your project root for any AGENTS.md-aware agent.

## Contributing

PRs welcome. Adding a new skill: `mkdir skills/<name>` then create `skills/<name>/SKILL.md` with this frontmatter:

```markdown
---
name: <name>
description: One sentence on when this skill should activate. Include common trigger phrasings the agent will see in user queries.
---

# Skill title

Markdown body...
```

Refer to existing skills for tone, depth, and structure — they're written for users extending Spree, not core contributors.

## License

[MIT](./LICENSE)
