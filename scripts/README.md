# infra/scripts

## `deploy.sh`

One-command release with an automatic health gate and rollback, per
DOP-001 §7/§11 AC-01/AC-03.

```
./deploy.sh <api-gateway|deploy-service|log-service> <tag>
```

Rewrites that service's `image:` tag in `docker-compose.prod.yml`, pulls
and restarts it (`--no-deps`, scoped to just that service), then polls its
Docker health status (the real `/health` HEALTHCHECK) for up to 60s. For
`api-gateway` — the only host/load-balancer-reachable service — it also
does an external `curl` smoke test.

- **On success:** commits the new tag to `docker-compose.prod.yml` (a
  versioned record of what's currently deployed) and exits 0.
- **On failure:** automatically reverts to the previously-deployed tag
  (read from `docker-compose.prod.yml` before the change), restarts, and
  re-verifies health — then exits non-zero either way, so a rolled-back
  deploy is never silently reported as green.

Requires `docker-compose.prod.yml`'s current tag to reflect what's
actually running — don't hand-edit that file's tags outside this script
without also restarting the service, or the "previous tag" it captures
will be wrong.

## `backup-db.sh` / `restore-db.sh`

Per DOP-001 §10 ("regular backups, restore testing... required") and §14
(restore time target). No IRD currently specifies backup mechanics — see
TIE-29/TIE-35 for the standing gap.

```
./backup-db.sh [--dir /backups] [--container <name>] [--compose-dir <path>]
```

`pg_dump -Fc` (custom format) for `deploy_db` and `log_db`, written to a
timestamped directory under `/backups` inside the postgres container —
bind-mounted to `infra/backups/` on the host (gitignored; these are runtime
artifacts, not source). Prunes backup directories older than 7 days.

**Schedule this daily on the actual deployment host** (not on a dev
machine) via cron, e.g.:

```
0 3 * * * cd /path/to/infra && ./scripts/backup-db.sh >> /var/log/db-backup.log 2>&1
```

```
./restore-db.sh <backup-timestamp> [--compose-dir <path>] [--name <container>]
```

Rehearsal/verification tool: spins up a **fresh, separate, throwaway**
Postgres container (never the live one) using the same `init/01-databases.sh`
so roles/grants match, then `pg_restore`s both dumps into it and prints row
counts. Leaves the container running so you can point a real service at it
(`DATABASE_URL` override) to confirm it starts cleanly — remove it yourself
when done (`docker rm -f <container>`). For an actual disaster-recovery
restore into a real replacement primary, an operator runs the same
`pg_restore` commands by hand against that instance instead.

Verified 2026-09-17: seeded 3 deploy records + 4 log entries via the real
API, backed up, restored into a throwaway instance — row counts and content
matched exactly, and a real `deploy-service` container started cleanly and
reported healthy against the restored database.

## Secret management scripts

Per DOP-001 §8 and IRD-003 §6: secrets are loaded from `.env`, never
hardcoded, and never committed (`.env` / `.env.*` are gitignored — only
`.env.*.example` templates are tracked).

## `generate-secrets.sh`

Generates fresh, host-local secrets for one environment's `.env.postgres`,
`.env.deploy`, `.env.gateway`, and `.env.log`. Run it independently on each
host (local dev machine, staging VM, production host) — every invocation
uses `openssl rand -hex` and produces its own random values, so no
credential is ever shared between environments.

```
./generate-secrets.sh [--dir <path>] [--force]
```

Refuses to overwrite existing `.env.*` files unless `--force` is passed, and
never prints secret values to stdout/logs.

## `rotate-db-roles.sh`

If Postgres was already initialized (i.e. `deploy_user`/`log_user` already
exist with old passwords) before you ran `generate-secrets.sh --force`, the
new `DATABASE_URL`s in `.env.deploy`/`.env.log` won't match the live
Postgres roles. This script reads the current `.env.postgres` and applies
those passwords to the running Postgres container via `ALTER USER`.

```
./rotate-db-roles.sh [--dir <path>] [--container <name>]
```

After rotating the DB roles, recreate the app containers so they pick up
the new `.env` files:

```
docker compose up -d --force-recreate api-gateway deploy-service log-service
```

## First-time setup (no existing Postgres data)

If you're bootstrapping a brand-new environment (fresh volume, nothing
initialized yet), just run `generate-secrets.sh` before the first
`docker compose up` — `infra/init/01-databases.sh` will create the DB roles
with the generated passwords directly, so `rotate-db-roles.sh` isn't needed.

**`01-databases.sh` only creates the databases and roles — it does not
create any tables.** On a brand-new volume, run the migration step below
once before starting `deploy-service`/`log-service`, or every request
fails with `PrismaClientKnownRequestError: table does not exist`.

## Database schema migrations (Prisma)

Neither `deploy-service` nor `log-service` had a committed migration
history before 2026-09-18 — schema only ever reached Postgres via manual
`prisma db push`, which is why this broke identically on the Day 12 EC2
deploy and again on the Day 15 Kubernetes deploy (fresh volume each time,
same missing step). Fixed by:

1. Committed `prisma/migrations/` in both service repos (real, versioned
   migration SQL — not `db push` anymore).
2. Both Dockerfiles gained a `migrator` build target (`FROM builder AS
   migrator`, `CMD npx prisma migrate deploy`) — reuses the existing
   `builder` stage, which already has the Prisma CLI the runtime image
   deliberately omits. Never run migrations inside the runtime container.
3. On Kubernetes: `k8s/migrate-job.yaml` in each service repo — a `Job`,
   applied once before rolling that service's `Deployment`. On Compose/EC2:
   build the `migrator` target and run it once the same way the Day 12
   one-off "migrator image" did.

**Still a gap — no IRD decision or ticket for this yet.** DOP-001 §10
already requires "forward-only migrations", but no IRD says how they run,
and there's no ticket tracking it the way `TIE-29`/`TIE-35` track the
backup gap above. Whoever picks this up next should: (a) file a ticket,
(b) add a short numbered Decision to IRD-001 §1 and IRD-002 §1 describing
this migrator-stage + Job pattern, referencing that ticket — same as every
other `(added per TIE-xx)` line in those files.
