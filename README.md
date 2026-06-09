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

### 25 skills

| Skill | When it activates |
|---|---|
| `spree-project` | General Spree project context — conventions, customization patterns, common commands. |
| `spree-customization` | Decision tree for "where does my customization belong" — routes to the right specific skill. Use FIRST when the pattern isn't obvious. |
| `spree-resource` | Adding a new model + API endpoint via the `spree:api_resource` generator. |
| `spree-decorators` | Extending existing Spree models/controllers via decorators (`Module#prepend`). |
| `spree-api-v3` | Spree REST API v3 conventions — Store vs Admin surfaces, auth (pk_/sk_/JWT), scopes, prefixed IDs, envelope, Ransack filters. |
| `spree-legacy-api-v2` | Maintaining or migrating away from the legacy API v2 (JSON:API style). |
| `spree-typescript-sdk` | `@spree/sdk` + `@spree/admin-sdk` — auth modes, types, Zod, webhooks, retry config, MSW, extension patterns. |
| `spree-upgrade` | Upgrading Spree to a new version. |
| `spree-data-model` | Domain model questions — Orders, LineItems, Variants, Stores, Channels, Markets. |
| `spree-events-webhooks` | Subscribers + outbound webhooks (HMAC, retry, auto-disable). |
| `spree-extensions` | Installing third-party gems (Stripe, Adyen, etc.) or building your own. |
| `spree-catalog` | Products, Variants, Options, Categories, search, images. |
| `spree-checkout` | Cart pipeline, order state machine, payment sessions, custom checkout flow. |
| `spree-payments` | Payment methods, gateways, refunds, gift cards, store credits. |
| `spree-promotions` | Promotion rules, actions, calculators, coupon codes. |
| `spree-pricing` | Variant prices, multi-currency, price lists, EU Omnibus / PriceHistory. |
| `spree-shipping-fulfillment` | Shipments, methods, rates, stock locations, returns. |
| `spree-admin` | Customizing the legacy Rails admin (`spree_admin` gem). |
| `spree-dashboard` | Extending the React admin SPA (`@spree/dashboard`) via `defineDashboardPlugin`. |
| `spree-storefront` | The Next.js storefront and `@spree/sdk`. |
| `spree-i18n` | UI translations (`Spree.t` + YAML) and data translations (Mobility). |
| `spree-testing` | RSpec + Factory Bot + Capybara, `spree_dev_tools`, the `API v3 Store` shared context. |
| `spree-security` | Rails security + Spree-specific (CanCanCan scopes, encrypted preferences, webhook HMAC, PCI scope reduction). |
| `spree-performance` | Cart pipeline, catalog N+1s, search latency, image processing, Sidekiq queue tuning. |
| `spree-deployment` | Deploying to Heroku, Render, K8s, Docker — env vars, release commands, S3, Sidekiq. |

### `spree-expert` subagent

Invoked by Claude (not the user) for multi-step Spree work that benefits from a fresh context — audits, multi-resource API planning, checkout flow investigations.

### Two safety hooks (Claude Code only)

| Hook | What it does |
|---|---|
| `PreToolUse` on `Bash` | Blocks destructive database commands (`rake db:drop`, `Spree::Model.delete_all`, raw `DROP TABLE spree_*`, force-push to main/master). |
| `PostToolUse` on `Edit`/`Write`/`MultiEdit` | Warns when an edit adds a hardcoded secret (Stripe live keys, AWS access keys, GitHub PATs, OpenAI/Anthropic keys). |

Hooks honor `SPREE_HOOKS_DISABLE=1` as an escape hatch. They require the Claude Code plugin install path below — `npx skills add` installs skills + subagent, but not hooks (the `${CLAUDE_PLUGIN_ROOT}` path resolution that hooks need only works under the plugin install).

## Claude Code: also get the safety hooks

If you're on Claude Code and want the safety hooks too, install as a plugin **from inside a Claude Code session**:

```text
/plugin marketplace add spree/agent-skills
/plugin install spree@spree
```

Plugin install gives you everything `npx skills add` does **plus** the two safety hooks. Use one path or the other — don't double-install (skills will collide).

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
