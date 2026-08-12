#!/usr/bin/env bash
# Поднимает временную БД, применяет миграции + seed, прогоняет смоук-тесты.
# Требует локальный Postgres 14+ и права на createdb.
#
#   ./supabase/tests/run.sh
#
# Переменные окружения: PGHOST, PGPORT, PGUSER (как обычно для psql).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${TEST_DB:-ukrainians_usa_test}"
PSQL="psql -v ON_ERROR_STOP=1 -q"

cleanup() { psql -q -d postgres -c "drop database if exists $DB;" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql -q -d postgres -c "drop database if exists $DB;"
psql -q -d postgres -c "create database $DB;"

# Заглушки Supabase: локально нет schema auth и auth.uid().
$PSQL -d "$DB" <<'SQL'
create schema auth;
create table auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
SQL

for f in "$DIR"/migrations/*.sql; do
  echo "  → $(basename "$f")"
  $PSQL -d "$DB" -f "$f"
done

echo "  → seed.sql"
$PSQL -d "$DB" -f "$DIR/seed.sql"

psql -v ON_ERROR_STOP=1 -d "$DB" -f "$DIR/tests/smoke.sql"
