#!/bin/bash
# Recreate the local replica database from the exported schema + data + triggers.
set -e
W="$1"; DB="${2:-m417}"
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>&1 | grep -v NOTICE || true
psql -q -d postgres -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end \$\$;"
psql -q -v ON_ERROR_STOP=1 -d $DB -c "create extension if not exists pgcrypto" -f "$W/base_tables.sql"
psql -q -v ON_ERROR_STOP=1 -d $DB -c "set check_function_bodies = off" -f "$W/all_fn.sql" 2>&1 | grep -v -e 'rls_auto_enable' -e '^$' || true
psql -q -v ON_ERROR_STOP=1 -d $DB -f "$W/base_data.sql"
psql -q -v ON_ERROR_STOP=1 -d $DB -f "$W/base_struct.sql"
