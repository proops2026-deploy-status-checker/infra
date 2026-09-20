#!/usr/bin/env bash
set -euo pipefail

export PGPASSWORD="${POSTGRES_PASSWORD:-}"

psql \
  -v ON_ERROR_STOP=1 \
  --username "${POSTGRES_USER:-postgres}" \
  --set=deploy_db_password="$DEPLOY_DB_PASSWORD" \
  --set=log_db_password="$LOG_DB_PASSWORD" <<'EOSQL'
  -- CREATE DATABASE cannot run inside a transaction, so guard it with
  -- \gexec instead of DO $$ ... $$ (Postgres has no CREATE DATABASE IF NOT EXISTS).
  -- deploy_db in particular is often pre-created by the image via POSTGRES_DB.
  SELECT 'CREATE DATABASE deploy_db'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'deploy_db')\gexec

  SELECT 'CREATE DATABASE log_db'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'log_db')\gexec

  -- psql does NOT substitute :'vars' inside DO $$ ... $$ blocks (dollar-quoting
  -- is treated as raw text), so build the CREATE USER statement via \gexec too.
  SELECT format('CREATE USER deploy_user WITH PASSWORD %L', :'deploy_db_password')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deploy_user')\gexec

  SELECT format('CREATE USER log_user WITH PASSWORD %L', :'log_db_password')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'log_user')\gexec

  REVOKE ALL ON DATABASE deploy_db FROM PUBLIC;
  REVOKE ALL ON DATABASE log_db FROM PUBLIC;

  GRANT CONNECT ON DATABASE deploy_db TO deploy_user;
  GRANT CONNECT ON DATABASE log_db TO log_user;
  REVOKE CONNECT ON DATABASE log_db FROM deploy_user;
  REVOKE CONNECT ON DATABASE deploy_db FROM log_user;

  \c deploy_db
  REVOKE ALL ON SCHEMA public FROM PUBLIC;
  GRANT USAGE, CREATE ON SCHEMA public TO deploy_user;

  \c log_db
  REVOKE ALL ON SCHEMA public FROM PUBLIC;
  GRANT USAGE, CREATE ON SCHEMA public TO log_user;

  -- CREATE privilege on a SCHEMA lets a role create objects (tables) inside
  -- an existing schema. It does NOT cover DDL that creates a schema itself —
  -- Prisma's auto-generated migrations always start with
  -- `CREATE SCHEMA IF NOT EXISTS "public"`, and Postgres checks database-level
  -- CREATE privilege for that statement even when the schema already exists.
  -- Without this grant: `migrate deploy` fails with
  -- "P3018 ... permission denied for database <db>".
  GRANT CREATE ON DATABASE deploy_db TO deploy_user;
  GRANT CREATE ON DATABASE log_db TO log_user;
EOSQL
