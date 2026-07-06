---
name: spree-upgrade
description: Use when the user wants to upgrade Spree to a new version. Common phrasings include "upgrade Spree", "update to 5.5", "how do I upgrade", "what's the upgrade process", "we need to bump Spree", "run the Spree upgrade". Provides the spree upgrade command and the upgrade flow.
---

# Upgrading Spree

Spree ships an upgrade flow that bundles three steps into one command:

1. `bundle update` — bump the Spree gems in your Gemfile.lock
2. `db:migrate` — apply migrations from the new gem version (after copying them in via `spree:install:migrations`)
3. `bin/rake spree:upgrade` — run version-specific data backfills shipped in each release

Use `spree upgrade` in development and `bundle exec rake spree:upgrade` in your deploy pipeline (production runs only the third step; bundle install + db:migrate are part of your platform's deploy flow).

**Classic Rails apps** (Spree gems in a plain Rails app, no Docker/CLI — typical pre-5.4) run the same three steps natively from the app root; the CLI flags map to env vars on the rake task (`--plan` → `DRY_RUN=1`, `--step` → `STEP=<id>`, `--to` → `TO=<version>`):

```bash
bundle update spree spree_core spree_api spree_admin spree_emails   # plus any spree_* extensions
bin/rake spree:install:migrations && bin/rails db:migrate
DRY_RUN=1 bin/rake spree:upgrade   # plan first
bin/rake spree:upgrade             # then run the data backfills
```

`spree upgrade` requires the ejected dev stack — fresh create-spree-app projects run the prebuilt Docker image (frozen bundle, no source bind mount), so run `spree eject` first; otherwise `bundle update` fails and the copied migrations never land in `backend/db/migrate/` on your host.

## See what would run (always do this first)

```bash
spree upgrade --plan
```

`--plan` walks the eligible upgrade manifests for the installed Spree version and prints every data-backfill step in order. It skips the bundle update and migration pre-steps entirely (those aren't part of the manifest). No changes happen. Read the output before running for real.

If you're caught between versions or want to test against a specific target:

```bash
spree upgrade --plan --to 5.5
```

## Run the upgrade

```bash
spree upgrade
```

You'll be prompted before each interactive step (bundle update, migrations). Answer No to skip an individual step; answer Yes to run it. The data backfills (`spree:upgrade`) always run — they're the version-specific part.

For CI or non-interactive use, skip the prompts:

```bash
spree upgrade --yes
```

## Run a single step

After a partial failure, retry one step without re-running bundle/migrate:

```bash
spree upgrade --step channels
```

Step ids come from the manifest (printed by `--plan`).

## Cap the version

If you want to upgrade to an intermediate version (e.g. you're on 5.3 and want to land on 5.4 before going to 5.5):

```bash
spree upgrade --to 5.4
```

## Flag reference

| Flag | Effect |
|---|---|
| `--plan` | Print what would run; execute nothing. Always run first. |
| `--step <id>` | Run a single step by id from the manifest (e.g. `channels`, `media`). Useful for retrying after a partial failure. |
| `--to <version>` | Cap the upgrade at this minor version. Eligible manifests = those whose `to:` is ≤ this. |
| `--yes` | Skip the interactive prompts. Required for CI / non-interactive runs. |

## What it does (and doesn't)

### Does

- Bumps every `spree*` gem in your bundle — `spree`, `spree_admin`, `spree_core`, `spree_api`, plus `spree_emails` and any installed `spree_*` extensions (`spree_stripe`, `spree_adyen`, …) — detected via `bundle list --name-only | grep '^spree'` inside the container. Extension gems get their versions bumped here, but their own upgrade steps remain manual (see "Doesn't" below).
- Copies new migrations from the gems into `backend/db/migrate/` via `spree:install:migrations`.
- Runs `db:migrate`.
- Runs every eligible upgrade manifest's rake tasks, in version order. Manifests are shipped inside `spree_core` (look in `spree_core/lib/spree/upgrades/<from>_to_<to>/manifest.yml` — version dots become underscores in the directory name, e.g. `5_4_to_5_5/manifest.yml`). Each task is idempotent — re-running the full upgrade is safe.

### Doesn't

- **Schedule cron jobs.** Some Spree releases add jobs that need scheduling (e.g. 5.5's `Spree::StockReservations::ExpireJob`). The "Next steps" panel at the end of the upgrade reminds you; check the upgrade doc for your target version (`https://spreecommerce.org/docs/developer/upgrades/<X.Y>-to-<A.B>`).
- **Audit your custom decorators.** When Spree moves an API surface (e.g. 5.5 moved the product↔store association off the `spree_products_stores` join table onto `Spree::Product#store_id` plus per-channel `Spree::ProductPublication` records), the upgrade can't migrate decorators that referenced the old surface. You need to read the breaking-changes section of the upgrade doc and update by hand.
- **Run extension upgrade steps.** The bundle update bumps `spree_*` extension gems (`spree_stripe`, `spree_adyen`, etc.) along with core — but their migrations, install generators, and breaking changes are not handled. After running `spree upgrade`, check each extension's CHANGELOG and run its upgrade steps by hand.

## After the upgrade

The "Next steps" panel printed at the end of `spree upgrade` lists what's still manual. Don't dismiss it — the rake-runnable parts only cover ~80% of a Spree upgrade. The remaining 20% (cron jobs, decorator audits, behavior changes) is documented in the per-version upgrade guides.

Read the upgrade doc for your target version:

```
https://spreecommerce.org/docs/developer/upgrades/<from>-to-<to>
```

For the manifest details, check `backend/Gemfile.lock` to see your installed version, then:

```bash
spree exec sh -c 'ls "$(bundle info spree_core --path)/lib/spree/upgrades/"'
```

## In production

Don't run `spree upgrade` against production directly — it's a dev CLI. On production, your deploy pipeline already handles `bundle install` + `db:migrate`. The remaining piece (data backfills) is one rake invocation:

```bash
bundle exec rake spree:upgrade
```

Add that as a release-phase command (Heroku), init container (K8s), auto-migrate hook (Render), or post-deploy task. The rake task is idempotent — running it on every deploy is safe.
