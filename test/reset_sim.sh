#!/bin/bash
# Like reset.sh, but everything is owned by a non-superuser role and the
# migration is applied as that role - the way the Supabase SQL Editor does it.
set -e
S=/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad
(cd $S/mig && ./build.sh >/dev/null)
bash $S/work/load_base.sh $S/work m417 >/dev/null 2>&1
psql -X -q -v ON_ERROR_STOP=1 -d m417 <<SQL
do \$\$ begin if not exists (select 1 from pg_roles where rolname='pgsim') then create role pgsim nosuperuser bypassrls createrole login; end if; end \$\$;
grant all on database m417 to pgsim;
do \$\$ declare r record; begin
  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','v','S') loop
    execute format('alter table %I.%I owner to pgsim', r.nspname, r.relname); end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e') loop
    execute format('alter function %s owner to pgsim', r.sig); end loop;
end \$\$;
alter schema public owner to pgsim;
grant usage on schema storage to pgsim;
grant select on storage.objects, storage.buckets to pgsim;
SQL
PGOPTIONS='-c role=pgsim' psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/mig/002_pipeline_layers.sql 2>&1 | grep -v -e NOTICE -e '^$' || true
psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/test/harness.sql
