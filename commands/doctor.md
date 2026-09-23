---
description: Diagnose the local Spree dev stack — Docker, containers, env, web, migrations, jobs — and prescribe the exact fix
allowed-tools: Bash, Read, Grep, Glob
---

# Spree stack diagnosis

Run every check below in order against this project. Do not stop at the first failure — run all of them, then report. Judge each against its healthy state.

Pre-flight — detect the project flavor:
- `docker-compose.yml` at the root (create-spree-app): run the Docker checks as written. The Rails app lives in `server/` (older projects: `backend/` — use whichever exists; call it `<app>` below). `apps/dashboard/` and `apps/storefront/` are optional.
- No Docker wiring but a Rails app with spree gems at the root (classic app): skip checks 1–2, run everything else **natively** — replace `spree exec <cmd>` with plain `<cmd>` from the app root, check the web on the port `bin/dev`/`bin/rails s` uses (default 3000), and read `Gemfile.lock` at the root.
- Neither: not a Spree project — say so and stop.

Command routing (Docker flavor): prefer `spree exec <cmd>`; if the `spree` CLI isn't available, fall back to `docker compose exec -T web <cmd>`. If `.env` contains `SPREE_PATH`, this is a monorepo edge project — `spree dev`/`spree build`/`spree upgrade` refuse there by design; remedies should say `pnpm server:dev` / `pnpm server:build` (run from the monorepo root) instead. On classic apps, remedies use native forms (`bin/dev`, `bin/rails db:migrate`, `bundle exec rake`).

Stack shape (create-spree-app): services `web` (Puma **and** the Solid Queue job supervisor in-process — there is no separate worker by default), `postgres`, `mailpit`. Optional: `meilisearch` (commented out in the template until enabled), a `bin/jobs` worker service if the user split jobs out (`SOLID_QUEUE_IN_PUMA=false`), and `redis`/`sidekiq` only if they swapped the job backend. Read `docker-compose.yml` and `<app>/Gemfile.lock` first and only run the optional checks for what's actually there.

## Checks

1. **Docker daemon** — `docker info --format '{{.ServerVersion}}'`
   Healthy: prints a version. Remedy: start Docker Desktop / OrbStack.

2. **Containers** — `docker compose ps -a --format '{{.Service}}: {{.State}} ({{.Status}})'`
   Healthy: `web` and `postgres` running (web `healthy` once booted), `mailpit` running. Plus any optional services defined in the compose file (`meilisearch`, a jobs worker, `redis`). Exited containers are normal if the user just hasn't booted; the remedy is `spree dev` (foreground, Ctrl+C stops) — or `pnpm server:dev` in monorepo mode. Note whether the compose file has a `build:` section (ejected, builds from `<app>/`) or uses the prebuilt `ghcr.io/spree/spree` image — code changes in `<app>/` only take effect on an ejected stack.

3. **Env file** — read `.env` at the project root: `SECRET_KEY_BASE` present and non-empty, `SPREE_PORT` (default 3000 when absent). Note `SPREE_VERSION_TAG` if pinned. Flag a missing `.env` as the likely root cause for boot loops. If `apps/storefront/.env*` exists, check `SPREE_PUBLISHABLE_KEY` isn't still `pk_REPLACE_ME…` (remedy: `spree api-key create --type publishable`).

4. **Web responding** — `curl -fsS -o /dev/null -w '%{http_code}' http://localhost:<SPREE_PORT>/up` (substitute the detected port)
   Healthy: `200`. `000` = nothing listening (stack down or still booting — check `spree logs`); `5xx` = Rails boot/runtime error (read `spree logs` and include the first error line in the report).

5. **Dashboard** — if `spree_dashboard` is in `<app>/Gemfile.lock`: `curl -fsS -o /dev/null -w '%{http_code}' http://localhost:<SPREE_PORT>/dashboard` → healthy `200`. If `apps/dashboard/` exists, also check the Vite dev server `curl -fsS -o /dev/null -w '%{http_code}' http://localhost:5173/` → `200` while `spree dev` runs (it may pick the next free port if 5173 was taken — check `spree dev` output). Skip either if not applicable and say so.

6. **Database connectivity** — `spree exec bin/rails runner 'puts ActiveRecord::Base.connection.active?'`
   Healthy: `true`. Skip (and say so) if the web container isn't running.

7. **Pending migrations** — `spree exec bin/rails db:migrate:status | grep -c '^\s*down'`
   Healthy: `0`. Remedy: `spree migrate` (installs engine migrations from gems, then `db:migrate`).

8. **Background jobs** — pick by what's in `<app>/Gemfile.lock` / `config.active_job.queue_adapter`:
   - **Solid Queue** (default):
     `spree exec bin/rails runner 'puts({ ready: SolidQueue::ReadyExecution.count, scheduled: SolidQueue::ScheduledExecution.count, failed: SolidQueue::FailedExecution.count, live_processes: SolidQueue::Process.where("last_heartbeat_at > ?", 5.minutes.ago).pluck(:kind) }.inspect)'`
     Healthy: at least one live `Supervisor`/`Worker` process, `ready` not growing into the thousands, `failed` small. No live processes → the supervisor isn't running: check `SOLID_QUEUE_IN_PUMA` isn't `false` on `web` (or that the `bin/jobs` service is up if they split it out), then `spree logs`. Failed jobs: inspect/retry in Mission Control at `http://localhost:<SPREE_PORT>/jobs` (dev credentials default to `spree` / `spree123` unless `MISSION_CONTROL_USER`/`MISSION_CONTROL_PASSWORD` are set).
   - **Sidekiq** (only if the `sidekiq` gem is present):
     `spree exec bin/rails runner 'require "sidekiq/api"; puts({ queues: Sidekiq::Queue.all.map { |q| [q.name, q.size] }.to_h, retries: Sidekiq::RetrySet.new.size, dead: Sidekiq::DeadSet.new.size, processes: Sidekiq::ProcessSet.new.size }.inspect)'`
     Healthy: ≥1 process, no runaway queues, small dead set. Remedy: confirm the Sidekiq and Redis containers are running; `spree logs <service>`.

9. **Search provider** (only if a `meilisearch` service is defined or `MEILISEARCH_URL` is set): `curl -fsS http://localhost:${SPREE_MEILISEARCH_PORT:-7700}/health` → `{"status":"available"}`. If available but products are missing from search, the remedy is `spree task search:reindex`. With the default database provider there's nothing to check — say so.

10. **Installed versions** — `grep -E '^    (spree|spree_core|rails) \(' <app>/Gemfile.lock` (monorepo edge projects resolve gems via path — note that instead). Report Spree and Rails. If `@spree/sdk` is declared in `apps/storefront/package.json`, or `@spree/dashboard` / `@spree/admin-sdk` in `apps/dashboard/package.json`, report them next to the backend version so drift is visible (Spree 6 pairs with `@spree/sdk` 2.x and `@spree/admin-sdk` 1.x).

## Report format

Produce a table — Check | Status (pass / warn / fail / skipped) | Detail | Remedy — followed by a short diagnosis paragraph: name the single most likely root cause if anything failed and give the exact first command to run. If everything passes, say the stack is healthy and print the URLs (`http://localhost:<port>` — API under `/api/v3/store` and `/api/v3/admin` — `/dashboard`, `/jobs`, the Vite dashboard on `:5173` when `apps/dashboard` exists, Mailpit at `http://localhost:<MAILPIT_UI_PORT or 8025>`) and the installed versions. Do not fix anything yourself — this command diagnoses; the user decides.
