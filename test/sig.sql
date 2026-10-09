select 'fn|'||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||md5(pg_get_functiondef(p.oid))||'|'||coalesce((select string_agg(a::text, ',' order by a::text) from unnest(p.proacl) a where a::text !~ '^(postgres|root|pgsim|supabase_admin)='),'')
from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','m417_internal') and p.prokind='f'
union all
select 'col|'||table_name||'.'||column_name||'|'||data_type||'|'||is_nullable||'|'||coalesce(column_default,'') from information_schema.columns where table_schema='public'
union all
select 'con|'||conrelid::regclass||'|'||conname||'|'||pg_get_constraintdef(oid) from pg_constraint where connamespace='public'::regnamespace
union all
select 'rls|'||relname||'|'||relrowsecurity||'|'||coalesce((select string_agg(a::text, ',' order by a::text) from unnest(relacl) a where a::text !~ '^(postgres|root|pgsim|supabase_admin)='),'') from pg_class where relnamespace='public'::regnamespace and relkind='r'
union all
select 'set|'||key||'|'||coalesce(value_numeric::text,'') from public.system_settings
union all
select 'txt|'||key from public.system_text_settings
union all
select 'flag|'||key from public.system_flags
order by 1;
