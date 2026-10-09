with q(bolum, veri) as (
  select 'surum', to_jsonb(version())
  union all
  select 'uzantilar', (select jsonb_agg(extname order by extname) from pg_extension)
  union all
  select 'tetikleyiciler', (
    select jsonb_agg(jsonb_build_object('tablo', c.relname, 'ad', t.tgname, 'acik', t.tgenabled, 'tanim', pg_get_triggerdef(t.oid)) order by c.relname, t.tgname)
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not t.tgisinternal)
  union all
  select 'olay_tetikleyicileri', (
    select coalesce(jsonb_agg(jsonb_build_object('ad', evtname, 'olay', evtevent, 'fonksiyon', evtfoid::regproc::text, 'acik', evtenabled)), '[]'::jsonb)
    from pg_event_trigger)
  union all
  select 'indeksler', (
    select jsonb_agg(jsonb_build_object('tablo', tablename, 'ad', indexname, 'tanim', indexdef) order by tablename, indexname)
    from pg_indexes where schemaname = 'public')
  union all
  select 'gorunumler', (
    select coalesce(jsonb_agg(jsonb_build_object('ad', viewname, 'tanim', definition)), '[]'::jsonb)
    from pg_views where schemaname = 'public')
  union all
  select 'rls', (
    select jsonb_agg(jsonb_build_object('tablo', c.relname, 'rls', c.relrowsecurity, 'zorunlu', c.relforcerowsecurity) order by c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r')
  union all
  select 'politikalar', (
    select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from pg_policies p where schemaname = 'public')
  union all
  select 'tablo_yetkileri', (
    select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb)
    from (
      select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) as yetkiler
      from information_schema.role_table_grants
      where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')
      group by grantee, table_name) g)
  union all
  select 'fonksiyon_yetkileri', (
    select jsonb_agg(jsonb_build_object(
             'fonksiyon', p.proname,
             'definer', p.prosecdef,
             'anon', has_function_privilege('anon', p.oid, 'execute'),
             'authenticated', has_function_privilege('authenticated', p.oid, 'execute'),
             'service_role', has_function_privilege('service_role', p.oid, 'execute')) order by p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and pg_get_function_result(p.oid) not in ('trigger', 'event_trigger'))
  union all
  select 'satir_sayilari', (
    select jsonb_object_agg(c.relname,
             (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r')
  union all select 'system_flags', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.system_flags x)
  union all select 'system_settings', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.system_settings x)
  union all select 'budgets', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.budgets x)
  union all select 'series', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.series x)
  union all select 'style_bibles', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.style_bibles x)
  union all select 'creative_profiles', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.production_creative_profiles x)
  union all select 'characters', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.characters x)
  union all select 'character_outfits', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.character_outfits x)
  union all select 'voice_identities', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.voice_identities x)
  union all
  select 'locations', (
    select coalesce(jsonb_agg(jsonb_build_object('kod', location_code, 'ad', name, 'tur', location_type, 'durum', status, 'surum', version, 'aciklama', left(canonical_description, 200)) order by location_code), '[]'::jsonb)
    from public.locations)
  union all
  select 'props', (
    select coalesce(jsonb_agg(jsonb_build_object('kod', prop_code, 'ad', name, 'durum', status, 'surum', version) order by prop_code), '[]'::jsonb)
    from public.props)
  union all
  select 'assets', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'kod', a.asset_code, 'tur', a.asset_type, 'durum', a.status, 'surum', a.version,
             'karakter', (select c.character_code from public.characters c where c.id = a.character_id),
             'mekan', (select l.location_code from public.locations l where l.id = a.location_id),
             'ses', (select v.voice_code from public.voice_identities v where v.id = a.voice_identity_id),
             'depo', a.storage_provider, 'yol', a.storage_path, 'mime', a.mime_type, 'meta', a.metadata) order by a.asset_code), '[]'::jsonb)
    from public.asset_registry a)
  union all select 'gen_providers', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_providers x)
  union all select 'gen_models', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_models x)
  union all select 'gen_pricing', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_model_pricing x)
  union all select 'gen_health', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_model_health x)
  union all select 'gen_benchmarks', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_model_benchmarks x)
  union all select 'gen_policies', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_routing_policies x)
  union all select 'gen_policy_models', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_policy_models x)
  union all select 'benchmark_runs', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.generation_benchmark_runs x)
  union all
  select 'benchmark_jobs', (
    select coalesce(jsonb_agg(jsonb_build_object('model_id', model_id, 'durum', status, 'deneme', attempt_no, 'tahmini', estimated_cost, 'gercek', actual_cost, 'hata', error_code, 'cikti_var', (output_url is not null or storage_path is not null))), '[]'::jsonb)
    from public.generation_benchmark_jobs)
  union all select 'episodes', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.episodes x)
  union all
  select 'shots', (
    select coalesce(jsonb_agg(jsonb_build_object('bolum', episode_id, 'kod', shot_code, 'sira', shot_order, 'durum', state, 'butce', maximum_budget) order by episode_id, shot_order), '[]'::jsonb)
    from public.shots)
  union all
  select 'shot_specs', (
    select coalesce(jsonb_agg(jsonb_build_object('shot', shot_id, 'surum', version, 'aktif', is_active, 'durum', status, 'sure', duration_seconds, 'oran', aspect_ratio, 'cozunurluk', resolution, 'fps', fps, 'ses_gerekli', audio_required, 'konusma_gerekli', voice_required, 'karakterler', character_codes, 'varliklar', required_asset_codes)), '[]'::jsonb)
    from public.shot_specifications)
  union all select 'manifests', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.production_manifests x)
  union all
  select 'attempts', (
    select coalesce(jsonb_agg(jsonb_build_object('shot', shot_id, 'no', attempt_no, 'saglayici', provider, 'model', model, 'durum', status, 'tahmini', estimated_cost, 'gercek', actual_cost, 'hata', error_code, 'tarih', created_at) order by created_at), '[]'::jsonb)
    from public.attempts)
  union all
  select 'approval_requests', (
    select coalesce(jsonb_agg(jsonb_build_object('kapsam', scope_type, 'surum', scope_version, 'durum', status, 'isteyen', requested_by, 'karar_veren', decided_by, 'kanal', decision_channel, 'tarih', created_at) order by created_at), '[]'::jsonb)
    from public.approval_requests)
  union all
  select 'son_olaylar', (
    select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
    from (select event_type, severity, source, message, created_at from public.events order by created_at desc limit 40) e)
  union all
  select 'depolama_kovalari', (
    select coalesce(jsonb_agg(jsonb_build_object('ad', b.name, 'public', b.public,
             'dosya_sayisi', (select count(*) from storage.objects o where o.bucket_id = b.id),
             'ornek_yollar', (select jsonb_agg(s.name) from (select o.name from storage.objects o where o.bucket_id = b.id order by o.name limit 60) s))), '[]'::jsonb)
    from storage.buckets b)
)
select bolum, veri from q;
