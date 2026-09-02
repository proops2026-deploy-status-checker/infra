#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE DATABASE deploy_db;
  CREATE DATABASE log_db;

  CREATE USER deploy_user WITH PASSWORD '${DEPLOY_DB_PASSWORD}';
  CREATE USER log_user WITH PASSWORD '${LOG_DB_PASSWORD}';

  REVOKE CONNECT ON DATABASE deploy_db FROM PUBLIC;
  REVOKE CONNECT ON DATABASE log_db FROM PUBLIC;

  GRANT ALL PRIVILEGES ON DATABASE deploy_db TO deploy_user;
  GRANT ALL PRIVILEGES ON DATABASE log_db TO log_user;

  \c deploy_db
  GRANT ALL ON SCHEMA public TO deploy_user;

  \c log_db
  GRANT ALL ON SCHEMA public TO log_user;
EOSQL
