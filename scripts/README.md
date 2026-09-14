# Secret management scripts

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
