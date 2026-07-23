#!/usr/bin/env bash
set -euo pipefail

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=n8n_password="$N8N_DB_PASSWORD" \
  --set=twenty_password="$TWENTY_DB_PASSWORD" <<'SQL'
CREATE USER n8n PASSWORD :'n8n_password';
CREATE DATABASE n8n OWNER n8n;
CREATE USER twenty PASSWORD :'twenty_password';
CREATE DATABASE twenty OWNER twenty;
SQL
