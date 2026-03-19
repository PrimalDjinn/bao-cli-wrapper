#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "postgres" <<-EOSQL

-- Create database if it doesn't exist
SELECT 'CREATE DATABASE ' || quote_ident('$POSTGRES_DB')
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '$POSTGRES_DB'
)\gexec

-- Ensure correct ownership
ALTER DATABASE "$POSTGRES_DB" OWNER TO "$POSTGRES_USER";

EOSQL