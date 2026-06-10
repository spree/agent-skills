---
description: Audit this Spree app for upgrade readiness — breaking changes vs your code, manifest plan, SDK drift — without changing anything
argument-hint: [target-version]
allowed-tools: Task, Bash, Read, Grep, Glob, WebFetch
---

# Spree upgrade-readiness audit

Target version: `$ARGUMENTS` — if blank, detect the installed version (step 1) and target the next minor.

This command is **read-only/advisory**: never run `spree upgrade`, `bundle update`, or migrations from here. The output is a readiness report; the user runs the upgrade.

Flavor note: on a classic Rails app (Spree gems at the repo root, no Docker/CLI), read `Gemfile.lock` instead of `backend/Gemfile.lock`, get the plan with `DRY_RUN=1 bundle exec rake spree:upgrade` instead of `spree upgrade --plan`, and the closing recommendation becomes the native sequence: `bundle update <spree gems>`, `bin/rake spree:install:migrations && bin/rails db:migrate`, `bin/rake spree:upgrade`.

## Steps

1. **Determine the version hop.** Installed: the `spree_core` entry in `backend/Gemfile.lock` (monorepo edge projects resolve gems via path — read the version from the monorepo's gemspec instead). Target: `$ARGUMENTS` or the next minor.

2. **Read the official upgrade doc for that hop.** Local first: `node_modules/@spree/docs/dist/developer/upgrades/<from>-to-<to>.md`; fall back to `https://spreecommerce.org/docs/developer/upgrades/<from>-to-<to>`. Extract three lists: (a) the data-backfill steps the rake manifest automates, (b) required post-upgrade configuration the manifest does NOT cover (cron jobs, env), (c) breaking changes that may require code edits.

3. **Spawn the `spree-expert` agent** (Task tool, `subagent_type: spree-expert`) with a charter built from the breaking-changes list, for example:

   > Audit this codebase for the Spree <from> → <to> upgrade. For each breaking change below, find concrete usages with file:line evidence — or state it's not used: <enumerate the breaking changes>. Check specifically: decorators in `backend/app/` referencing renamed or removed Spree classes/methods; storefront code (`apps/storefront/`) string-matching wire formats that changed; custom subscribers/services touching changed models. Also report the `@spree/sdk` version declared in `apps/storefront/package.json` and whether it matches the target Spree version's compatibility row. Return findings only — no fixes.

4. **Get the manifest plan.** If the stack is running, run `spree upgrade --plan` and capture the step list. If the stack is down, note that and reconstruct the steps from the upgrade doc instead.

5. **Synthesize the readiness report:**
   - **Verdict:** READY / READY WITH CHANGES / BLOCKED
   - **Findings table:** severity | file:line | what breaks | the fix
   - **Automated steps:** the manifest plan from step 4 (these run via `spree upgrade`)
   - **Manual checklist:** everything from step 2(b) and 2(c) the manifest won't do — cron scheduling, SDK bump (with the exact `npm install @spree/sdk@^X` command and where), behavior changes to review
   - **Remediation order:** what to fix before upgrading, then the closing line: run `spree upgrade` when the list is clear.
