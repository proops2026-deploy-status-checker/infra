#!/usr/bin/env bash
set -euo pipefail

psql \
  -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --set=deploy_db_password="$DEPLOY_DB_PASSWORD" \
  --set=log_db_password="$LOG_DB_PASSWORD" <<'EOSQL'
  CREATE DATABASE deploy_db;
  CREATE DATABASE log_db;

  CREATE USER deploy_user WITH PASSWORD :'deploy_db_password';
  CREATE USER log_user WITH PASSWORD :'log_db_password';

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
EOSQL
