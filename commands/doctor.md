---
description: Diagnose the local Spree dev stack — Docker, containers, env, web, migrations, jobs — and prescribe the exact fix
allowed-tools: Bash, Read, Grep, Glob
---

# Spree stack diagnosis

Run every check below in order against this project. Do not stop at the first failure — run all of them, then report. Judge each against its healthy state.

Pre-flight — detect the project flavor:
- `docker-compose.yml` at the root (create-spree-app / spree-starter): run the Docker checks below as written.
- No Docker wiring but a Rails app with spree gems at the root (classic pre-5.4 app): skip checks 1–2, run everything else **natively** — replace `spree exec <cmd>` with plain `<cmd>` from the app root, check the web on the port `bin/dev`/`bin/rails s` uses (default 3000), and read `backend/Gemfile.lock` as `Gemfile.lock`.
- Neither: not a Spree project — say so and stop.

Command routing (Docker flavors): prefer `spree exec <cmd>`; if the `spree` CLI isn't available, fall back to `docker compose exec -T web <cmd>`. If `.env` contains `SPREE_PATH`, this is a monorepo edge project — `spree dev`/`spree build` refuse there by design; remedies should say `pnpm server:dev` / `pnpm server:build` (run from the monorepo root) instead. On classic apps, remedies use native forms (`bin/dev`, `bin/rails db:migrate`, `bundle exec rake`).

## Checks

1. **Docker daemon** — `docker info --format '{{.ServerVersion}}'`
   Healthy: prints a version. Remedy: start Docker Desktop / OrbStack.

2. **Containers** — `docker compose ps -a --format '{{.Service}}: {{.State}} ({{.Status}})'`
   Healthy: `postgres`, `redis`, `web` running (plus `worker` and `meilisearch` when defined in the compose file). Exited app containers are normal if the user just hasn't booted; the remedy is `spree dev` (foreground, Ctrl+C stops) — or `pnpm server:dev` in monorepo mode.

3. **Env file** — read `.env`: `SECRET_KEY_BASE` present and non-empty, `SPREE_PORT` (default 3000 when absent). Note `SPREE_VERSION_TAG` if pinned. Flag a missing `.env` as the likely root cause for boot loops.

4. **Web responding** — `curl -fsS -o /dev/null -w '%{http_code}' http://localhost:<SPREE_PORT>/` (substitute the detected port)
   Healthy: 2xx/3xx. `000` = nothing listening (stack down or still booting — check `spree logs`); `5xx` = Rails boot/runtime error (read `spree logs` and include the first error line in the report).

5. **Database connectivity** — `spree exec bin/rails runner 'puts ActiveRecord::Base.connection.active?'`
   Healthy: `true`. Skip (and say so) if the web container isn't running.

6. **Pending migrations** — `spree exec bin/rails db:migrate:status | grep -c '^\s*down'`
   Healthy: `0`. Remedy: `spree migrate` (installs engine migrations from gems, then `db:migrate`).

7. **Background jobs** — `spree exec bin/rails runner 'require "sidekiq/api"; puts({ queues: Sidekiq::Queue.all.map { |q| [q.name, q.size] }.to_h, retries: Sidekiq::RetrySet.new.size, dead: Sidekiq::DeadSet.new.size }.inspect)'`
   Healthy: no runaway queue (thousands) and a small dead set. Remedy for backlogs: confirm the `worker` container is running and check `spree logs worker`.

8. **Installed Spree version** — `grep -E '^    spree(_core)? \(' backend/Gemfile.lock | head -3` (monorepo projects: gems resolve via path, note that instead). Report the version; if `@spree/sdk` is declared in `apps/storefront/package.json`, report it next to the backend version so drift is visible.

## Report format

Produce a table — Check | Status (pass / warn / fail) | Detail | Remedy — followed by a short diagnosis paragraph: name the single most likely root cause if anything failed and give the exact first command to run. If everything passes, say the stack is healthy and print the URLs (`http://localhost:<port>`, `/admin`) and the installed versions. Do not fix anything yourself — this command diagnoses; the user decides.
