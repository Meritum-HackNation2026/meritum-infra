#!/usr/bin/env bash
# Database layout of the Meritum platform. Source it after lib.sh, don't run it.
#
#   database meritum          corpus (shared, infra#4), app_dev, app_prd, mocks_prd
#   database meritum_dbos_dev DBOS system tables of dev (schema dbos)
#   database meritum_dbos_prd DBOS system tables of prd
#
# Per env: meritum_worker_<env> owns app_<env> and meritum_dbos_<env> (it runs the
# migrations); meritum_api_<env> reads and writes app_<env> without DDL and gets
# the DBOS tables from `dbos migrate -r` in the worker deploy. Roles of one env
# have no access to the schema or the DBOS database of the other env.
# Mocks (prd only) keep their own schema mocks_prd.

pw_var() { printf '%s_PASSWORD' "$(printf '%s_%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')"; }
m_app_schema() { printf 'app_%s' "$1"; }
m_dbos_db() { printf 'meritum_dbos_%s' "$1"; }

# postgresql:// URL of role $1 with password $2 to database $3; with $4 the
# search_path is "$4, public" (libpq `options`, read by psycopg and DBOS).
m_db_url() {
  printf 'postgresql://%s:%s@%s:5432/%s' "$1" "$2" "${M_DB_HOST:-$M_POSTGRES}" "$3"
  if [ -n "${4:-}" ]; then printf '?options=-csearch_path%%3D%s,public' "$4"; fi
}

# SQL for psql (run as the superuser in database meritum, ON_ERROR_STOP=1).
# Idempotent: creates what is missing, never drops. Passwords come from the
# variables named by pw_var (setup.sh: ~/meritum/db.env).
#   $1 ENVS (space separated)   $2 mocks envs (space separated)
m_db_sql() {
  local env role schema api worker db
  echo "REVOKE ALL ON DATABASE meritum FROM PUBLIC;"
  echo "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
  for env in $1; do
    for role in api worker; do
      _m_db_role "$(m_role "$role" "$env")" "$(pw_var "$role" "$env")"
    done
  done
  for env in $2; do
    role=$(m_role mocks "$env"); schema=$(m_schema mocks "$env")
    _m_db_role "$role" "$(pw_var mocks "$env")"
    echo "CREATE SCHEMA IF NOT EXISTS $schema AUTHORIZATION $role;"
    echo "ALTER ROLE $role SET search_path = $schema, public;"
  done
  for env in $1; do
    api=$(m_role api "$env"); worker=$(m_role worker "$env"); schema=$(m_app_schema "$env")
    cat <<SQL
CREATE SCHEMA IF NOT EXISTS $schema AUTHORIZATION $worker;
ALTER SCHEMA $schema OWNER TO $worker;
GRANT USAGE ON SCHEMA $schema TO $api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $schema TO $api;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA $schema TO $api;
ALTER DEFAULT PRIVILEGES FOR ROLE $worker IN SCHEMA $schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $api;
ALTER DEFAULT PRIVILEGES FOR ROLE $worker IN SCHEMA $schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO $api;
ALTER ROLE $api SET search_path = $schema, public;
ALTER ROLE $worker SET search_path = $schema, public;
SQL
  done
  # CREATE DATABASE cannot run in a DO block; \gexec runs it only when missing.
  for env in $1; do
    db=$(m_dbos_db "$env"); api=$(m_role api "$env"); worker=$(m_role worker "$env")
    cat <<SQL
SELECT 'CREATE DATABASE $db OWNER $worker' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')
\\gexec
ALTER DATABASE $db OWNER TO $worker;
REVOKE ALL ON DATABASE $db FROM PUBLIC;
GRANT CONNECT ON DATABASE $db TO $api;
SQL
  done
}

# One login role with CONNECT on meritum; $2 names the variable with its password.
_m_db_role() {
  echo "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$1') THEN CREATE ROLE $1; END IF; END \$\$;"
  echo "ALTER ROLE $1 WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${!2}';"
  echo "GRANT CONNECT ON DATABASE meritum TO $1;"
}
