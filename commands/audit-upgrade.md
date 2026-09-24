---
description: Audit this Spree app for upgrade readiness — breaking changes vs your code, manifest plan, SDK drift — without changing anything
argument-hint: [target-version]
allowed-tools: Task, Bash, Read, Grep, Glob, WebFetch
---

# Spree upgrade-readiness audit

Target version: `$ARGUMENTS` — if blank, detect the installed version (step 1) and target the next release (5.6 → 6.0; otherwise the next minor).

This command is **read-only/advisory**: never run `spree upgrade`, `bundle update`, migrations or rake tasks that write data from here. The output is a readiness report; the user runs the upgrade.

**Layout detection:** create-spree-app projects keep the Rails app in `server/` (older projects: `backend/` — use whichever exists; call it `<app>` below), with `apps/storefront/` and `apps/dashboard/` beside it. Classic Rails apps have the Rails app at the repo root: read `Gemfile.lock` there, get the plan with `DRY_RUN=1 bundle exec rake spree:upgrade`, and the closing recommendation becomes the native sequence: `bundle update <spree gems>`, `bin/rails spree:install:migrations db:migrate`, `bundle exec rake spree:upgrade`.

## Steps

1. **Determine the version hop.** Installed: the `spree_core` entry in `<app>/Gemfile.lock` (monorepo edge projects resolve gems via path — read the version from the monorepo's `spree/core/lib/spree/core/version.rb` instead). Also record `rails` from the lockfile and the Ruby version. Target: `$ARGUMENTS` or the next release.

2. **Gate major hops.** If the target is **6.x** and the installed version is 5.x:
   - Installed must be **5.6.x**. Anything older → verdict **BLOCKED**: "upgrade to 5.6 first (`spree upgrade --to 5.6`, then run the 5.6 backfills)". Still run the audit so the user sees the work ahead, but say it clearly at the top.
   - Rails 8.1 must be feasible: flag every gem in the lockfile pinned below Rails 8.1 compatibility and any `gem 'rails'` constraint `< 8.1`. Unresolvable pins → **BLOCKED**.
   - Every `spree_*` extension in the Gemfile needs a 6.0-compatible release; `spree_admin` and `spree_storefront` must be removed; `spree_dashboard` added (unless API-only); `spree_meilisearch` added if `Spree.search_provider` names Meilisearch. List each as a finding.

3. **Read the official upgrade doc for that hop.** Local first: `node_modules/@spree/docs/dist/developer/upgrades/<from>-to-<to>.md` (5.6 → 6.0: `5.6-to-6.0.md`); fall back to `https://spreecommerce.org/docs/developer/upgrades/<from>-to-<to>`. Extract: (a) data-backfill steps the manifest automates, (b) required manual configuration (recurring jobs, env, settings moved to the store, roles), (c) breaking changes needing code edits. For 5.6 → 6.0 the `spree-upgrade-5-to-6` skill already has these organized — use its preconditions list, its behavioral checklist, and its `references/grep-recipes.md` table.

4. **Spawn the `spree-expert` agent** (Task tool, `subagent_type: spree-expert`) with a charter built from the breaking changes, for example:

   > Audit this codebase for the Spree <from> → <to> upgrade. For each pattern in skills/spree-upgrade-5-to-6/references/grep-recipes.md (for 6.0) or each breaking change listed below (other hops), find concrete usages with file:line evidence — or state it's not used. Search `<app>/app`, `<app>/config`, `<app>/lib`, `<app>/spec`, `<app>/db/seeds.rb`, plus `apps/storefront/` and `apps/dashboard/` (wire-format rows: requirement codes, `*_html` fields, webhook event names, removed endpoints). Specifically check: decorators referencing removed classes/methods; initializers writing `*_service =` DI keys, PermissionSets or `PermittedAttributes`; custom checkout steps/state-machine callbacks; subscribers/webhooks on `order.completed`; your own `Spree::Base` models with `belongs_to` lacking `optional:`; tests asserting "can't be blank" or using `OrderWalkthrough`; Devise configuration (`Devise.pepper`) for the customer migration; whether `config/application.rb` copies `ACTIVE_RECORD_ENCRYPTION_*` env vars / `active_record_encryption` credentials into `config.active_record.encryption` (report presence only, never values); `Spree::RichTextSanitizer` needs (tables/divs/inline styles in product/category descriptions). Report `@spree/sdk` in `apps/storefront/package.json` and `@spree/admin-sdk` anywhere, against the target (6.0: `@spree/sdk` 2.x, `@spree/admin-sdk` 1.x). Return findings only — no fixes.

5. **Get the manifest plan.** If the stack is running and the gems are already on the target, run `spree upgrade --plan` (it lists exactly the steps a real run executes for the installed version) and capture the step list. Before the gem bump the installed gem doesn't ship the target's manifest, so reconstruct the plan from the upgrade doc or the `spree-upgrade-5-to-6` step table instead, and say so.
   For 5.6 → 6.0, also note the post-run check: completed orders flagged `metadata['typed_adjustments_frozen']` by `migrate_adjustments_to_typed_rows` need manual review.

6. **Synthesize the readiness report:**
   - **Verdict:** READY / READY WITH CHANGES / BLOCKED (with the blocking reason first)
   - **Findings table:** severity | file:line | what breaks | the fix
   - **Preconditions:** (6.0) 5.6 landed, Rails 8.1, Gemfile swaps, roles recreated as data, PermissionSets initializers removed, rich-text allowlist decision, Action Text/Cable requires, Devise pepper answer (`CONFIRM_NO_PEPPER=true`), Active Record encryption keys configured and read into `config.active_record.encryption` (plus the one-time encrypt-existing-rows pass), DB backup
   - **Automated steps:** the manifest plan from step 5 (these run via `spree upgrade` / `rake spree:upgrade`)
   - **Manual checklist:** everything the manifest won't do — frozen-order review, recurring jobs, SDK bumps (exact `npm install @spree/sdk@^2` / `@spree/admin-sdk@^1` commands and where), behavior changes to review, extension upgrades
   - **Remediation order:** what to fix before upgrading, then the closing line: run `spree upgrade` (after `spree eject` if the project still runs the prebuilt image) when the list is clear.
