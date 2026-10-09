"""Emit SQL that adds data, indexes, triggers, RLS and grants from the 4th export to the local replica."""
import json, csv, sys, os
x4, cons_csv, out_data, out_struct = sys.argv[1:5]
def J(n): return json.load(open(os.path.join(x4, n + '.json')))
def lit(obj): 
    s = json.dumps(obj, ensure_ascii=False)
    assert '$j$' not in s
    return '$j$' + s + '$j$'
d = []
full = [('system_flags','system_flags'),('system_settings','system_settings'),('series','series'),('style_bibles','style_bibles'),
        ('creative_profiles','production_creative_profiles'),('characters','characters'),('voice_identities','voice_identities'),
        ('gen_providers','generation_providers'),('gen_models','generation_models'),('gen_pricing','generation_model_pricing'),
        ('gen_health','generation_model_health'),('benchmark_runs','generation_benchmark_runs')]
for sec, tbl in full:
    rows = J(sec)
    if rows:
        d.append(f"insert into public.{tbl} select * from jsonb_populate_recordset(null::public.{tbl}, {lit(rows)}::jsonb);")
# locations: partial rows
locs = J('locations')
d.append("insert into public.locations (series_id, location_code, name, location_type, canonical_description, status, version) "
         "select (select id from public.series limit 1), x.kod, x.ad, x.tur, x.aciklama, x.durum, x.surum "
         f"from jsonb_to_recordset({lit(locs)}::jsonb) as x(kod text, ad text, tur text, aciklama text, durum text, surum int);")
assets = J('assets')
d.append("insert into public.asset_registry (series_id, asset_code, asset_type, character_id, location_id, voice_identity_id, storage_provider, storage_path, mime_type, metadata, status, version, locked_at) "
         "select (select id from public.series limit 1), x.kod, x.tur, "
         "(select c.id from public.characters c where c.character_code = x.karakter), "
         "(select l.id from public.locations l where l.location_code = x.mekan), "
         "(select v.id from public.voice_identities v where v.voice_code = x.ses), "
         "x.depo, x.yol, x.mime, x.meta, x.durum, x.surum, now() "
         f"from jsonb_to_recordset({lit(assets)}::jsonb) as x(kod text, tur text, karakter text, mekan text, ses text, depo text, yol text, mime text, meta jsonb, durum text, surum int);")
# storage mock
d.append("create schema if not exists storage; "
         "create table if not exists storage.buckets(id text primary key, name text, public boolean default false); "
         "create table if not exists storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, metadata jsonb, created_at timestamptz default now(), unique(bucket_id, name));")
for b in J('depolama_kovalari'):
    d.append(f"insert into storage.buckets(id, name, public) values ('{b['ad']}', '{b['ad']}', {str(b['public']).lower()});")
    for p in (b['ornek_yollar'] or []):
        d.append(f"insert into storage.objects(bucket_id, name, metadata) values ('{b['ad']}', '{p}', '{{\"size\": 1000000, \"mimetype\": \"image/png\"}}');")
open(out_data, 'w').write('\n'.join(d) + '\n')
s = []
cons = set(r['conname'] for r in csv.DictReader(open(cons_csv, newline='')))
for i in J('indeksler'):
    if i['ad'] not in cons: s.append(i['tanim'] + ';')
for t in J('tetikleyiciler'): s.append(t['tanim'] + ';')
for r in J('rls'):
    if r['rls']: s.append(f'alter table public."{r["tablo"]}" enable row level security;')
s.append("revoke all on all tables in schema public from public, anon, authenticated, service_role;")
for g in J('tablo_yetkileri'):
    s.append(f'grant {g["yetkiler"]} on public."{g["table_name"]}" to {g["grantee"]};')
s.append("revoke all on all functions in schema public from public, anon, authenticated, service_role;")
for f in J('fonksiyon_yetkileri'):
    for role in ('anon', 'authenticated', 'service_role'):
        if f[role]:
            s.append(f"do $$ declare r record; begin for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='{f['fonksiyon']}' loop execute format('grant execute on function %s to {role}', r.sig); end loop; end $$;")
s.append("grant usage on schema public to anon, authenticated, service_role;")
open(out_struct, 'w').write('\n'.join(s) + '\n')
print(len(d), 'data statements;', len(s), 'structure statements')
