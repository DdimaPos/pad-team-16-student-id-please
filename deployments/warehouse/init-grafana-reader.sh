#!/bin/sh
# warehouse-postgres init step (Lab 5, #165): creates grafana_reader, the read-only role of Grafana's "Warehouse"
# datasource, with the password WAREHOUSE_GRAFANA_PASSWORD. The official postgres image runs it once, as POSTGRES_USER
# (`warehouse`), on an empty data directory only; on an existing volume run the same SQL by hand.
#
# The tables do not exist yet: the ETL Service creates them later with its migrations, as `warehouse`. So the role
# gets SELECT on the tables there are now and, through the default privileges of `warehouse`, on every table it creates
# later. Every session of the role is read-only as well, so a dashboard query can never write.
set -eu

if [ -z "${WAREHOUSE_GRAFANA_PASSWORD:-}" ]; then
  echo "WAREHOUSE_GRAFANA_PASSWORD is empty: grafana_reader not created" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v grafana_password="$WAREHOUSE_GRAFANA_PASSWORD" <<'SQL'
CREATE ROLE grafana_reader LOGIN PASSWORD :'grafana_password';
ALTER ROLE grafana_reader SET default_transaction_read_only = on;
ALTER ROLE grafana_reader SET statement_timeout = '30s';
GRANT CONNECT ON DATABASE warehouse_db TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE warehouse IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
SQL
