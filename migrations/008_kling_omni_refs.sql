-- =====================================================================
-- M417 / WIZZLEBURY  -  008 character reference images (Kling 3.0 Omni)
--
-- Run after 007. Safe to run more than once; one transaction.
-- OWNER DECISIONS recorded by running this file:
--   * Video is generated with Kling 3.0 Omni, 720p, through PiAPI,
--     because it accepts reference images of the characters.
--   * Price taken from PiAPI's price list on 9 Oct 2026:
--     0.10 USD per second at 720p without audio (0.50 USD per 5 s clip).
--   * The model is used on a pilot approval, like Kling 2.6 before it.
--   * The public copies of the five character references are the files
--     in the public bucket "public-refs".
-- From the moment this file has run, NEW video attempts use the new
-- model. Nothing is generated and nothing is spent by running it.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('public.approve_model_pilot(text,text,text)') is null then
        raise exception 'M417_006_NOT_FOUND: apply 006_video_pilot.sql first';
    end if;
    if not exists (select 1 from public.generation_providers where provider_code = 'PIAPI_KLING') then
        raise exception 'M417_007_NOT_FOUND: apply 007_kling_setup.sql first';
    end if;
end $$;

-- Publicly readable copies of canonical reference images, one per
-- canonical asset. A video provider fetches them by URL; the canonical
-- originals stay in the private bucket.
create table if not exists public.video_reference_images (
    asset_id uuid primary key references public.asset_registry(id) on delete restrict,
    bucket text not null default 'public-refs',
    object_path text not null,
    is_active boolean not null default true,
    set_by text not null,
    note text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint video_reference_images_path_check check (
        btrim(object_path) <> '' and object_path !~ '^/' and object_path !~ '[[:space:]?#]'
        and btrim(bucket) <> '' and bucket !~ '[/[:space:]?#]')
);
alter table public.video_reference_images enable row level security;
do $$
declare
    v_role text;
begin
    execute 'revoke all on public.video_reference_images from public';
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.video_reference_images from %I', v_role);
        end if;
    end loop;
end $$;

-- Reference images of a shot that a provider can fetch: the shot's
-- canonical references that have a public copy, in reference order.
-- Each element: {"n": 1, "role": "CHARACTER", "name": "Mia", "url": "https://..."}.
create or replace function m417_internal.shot_reference_images(p_spec_id uuid, p_limit integer)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.n, 'role', x.reference_role, 'name', x.name, 'url', x.url) order by x.n), '[]'::jsonb)
    from (
        select row_number() over (order by sra.reference_order, ar.asset_code) as n,
               sra.reference_role,
               coalesce(c.name, l.name, ar.asset_code) as name,
               rtrim(m417_internal.txt('storage_base_url', ''), '/')
                   || '/object/public/' || v.bucket || '/' || v.object_path as url
        from public.shot_reference_assets sra
        join public.asset_registry ar on ar.id = sra.asset_id
        join public.video_reference_images v on v.asset_id = ar.id and v.is_active = true
        left join public.characters c on c.id = ar.character_id
        left join public.locations l on l.id = ar.location_id
        where sra.shot_specification_id = p_spec_id
          and sra.reference_role in ('CHARACTER', 'LOCATION')
          and m417_internal.txt('storage_base_url', '') <> ''
        order by sra.reference_order, ar.asset_code
        limit greatest(coalesce(p_limit, 4), 0)
    ) x;
$function$;

-- The complete request body for the provider. Make forwards it as is.
create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_row record;
    v_route text;
    v_defaults jsonb;
    v_params jsonb;
    v_task text;
    v_refs jsonb;
    v_lead text;
    v_tail text;
    v_input jsonb;
    v_max integer;
begin
    select a.provider, a.model, gm.model_version, gm.capability_metadata,
           ss.id as spec_id, ss.generation_prompt, ss.negative_prompt, ss.aspect_ratio,
           ss.duration_seconds, ss.resolution
    into v_row
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.generation_models gm on gm.id = grd.selected_model_id
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where a.id = p_attempt_id;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    v_route := m417_internal.provider_route(v_row.provider);
    v_defaults := case when jsonb_typeof(v_row.capability_metadata -> 'request_defaults') = 'object'
                       then v_row.capability_metadata -> 'request_defaults' else '{}'::jsonb end;
    v_task := coalesce(v_row.capability_metadata ->> 'task_type', 'video_generation');

    if v_route = 'KLING' and v_task = 'omni_video_generation' then
        -- Kling Omni: reference images go in input.images and are named
        -- in the prompt as @image_1, @image_2 ... in list order. It has
        -- no negative_prompt field, so the short "Avoid" list is part of
        -- the prompt. The whole prompt stays inside 2500 characters.
        v_max := coalesce(nullif(v_row.capability_metadata ->> 'max_reference_images', '')::integer, 4);
        v_refs := m417_internal.shot_reference_images(v_row.spec_id, v_max);
        v_lead := '';
        if jsonb_array_length(v_refs) > 0 then
            select 'Reference images: '
                   || string_agg(
                          '@image_' || (r.value ->> 'n') || ' is '
                          || case when r.value ->> 'role' = 'LOCATION'
                                  then 'the location ' || (r.value ->> 'name')
                                  else r.value ->> 'name' end,
                          ', ' order by (r.value ->> 'n')::integer)
                   || '. A character reference image shows one single character, sometimes in more than one view.'
                   || ' Keep every character''s face, hair, skin tone, age and body proportions exactly as in their reference image,'
                   || ' and their outfit as in the reference unless the scene says otherwise.'
                   || ' Exactly one of each named character. One continuous shot, never a collage or a split screen. '
            into v_lead
            from jsonb_array_elements(v_refs) r(value);
        end if;
        v_tail := case when coalesce(btrim(v_row.negative_prompt), '') <> ''
                       then ' Avoid: ' || left(btrim(v_row.negative_prompt), 300) else '' end;
        v_input := jsonb_build_object(
            'prompt', v_lead
                      || left(v_row.generation_prompt, greatest(2500 - length(v_lead) - length(v_tail), 200))
                      || v_tail,
            'version', coalesce(v_row.model_version, '3.0'),
            'resolution', coalesce(v_row.capability_metadata ->> 'resolution', '720p'),
            'duration', v_row.duration_seconds::integer,
            'aspect_ratio', v_row.aspect_ratio,
            'enable_audio', false);
        if jsonb_array_length(v_refs) > 0 then
            v_input := v_input || jsonb_build_object(
                'images', (select jsonb_agg(r.value ->> 'url' order by (r.value ->> 'n')::integer)
                           from jsonb_array_elements(v_refs) r(value)));
        end if;
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', v_input || v_defaults)::text;
    elsif v_route = 'KLING' then
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', jsonb_build_object(
                'prompt', v_row.generation_prompt,
                'negative_prompt', coalesce(v_row.negative_prompt, ''),
                'aspect_ratio', v_row.aspect_ratio,
                'duration', v_row.duration_seconds::integer,
                'version', coalesce(v_row.model_version, '2.6'),
                'mode', coalesce(v_row.capability_metadata ->> 'mode', 'std'),
                'enable_audio', false) || v_defaults)::text;
    elsif v_route = 'VEO' then
        v_params := jsonb_build_object(
            'aspectRatio', v_row.aspect_ratio,
            'durationSeconds', v_row.duration_seconds::integer);
        if coalesce(btrim(v_row.negative_prompt), '') <> '' then
            v_params := v_params || jsonb_build_object('negativePrompt', v_row.negative_prompt);
        end if;
        if v_row.resolution in ('720p', '1080p') then
            v_params := v_params || jsonb_build_object('resolution', v_row.resolution);
        end if;
        return jsonb_build_object(
            'instances', jsonb_build_array(jsonb_build_object('prompt', v_row.generation_prompt)),
            'parameters', v_params || v_defaults)::text;
    end if;
    raise exception 'PROVIDER_ROUTE_NOT_SUPPORTED: % (%)', v_row.provider, v_route;
end;
$function$;

-- The owner names the public copy of a canonical reference image.
-- p_object_path is the file's path inside the public bucket.
create or replace function public.set_video_reference(
    p_asset_code text, p_object_path text, p_actor text, p_bucket text default 'public-refs')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_path text := btrim(coalesce(p_object_path, ''));
    v_bucket text := btrim(coalesce(p_bucket, ''));
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select ar.id into v_asset_id
    from public.asset_registry ar
    where ar.asset_code = p_asset_code and ar.status = 'LOCKED'
    order by ar.version desc
    limit 1;
    if not found then
        raise exception 'LOCKED_ASSET_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    if v_path = '' or v_path ~ '^/' or v_path ~ '[[:space:]?#]' or v_bucket = '' or v_bucket ~ '[/[:space:]?#]' then
        raise exception 'REFERENCE_PATH_INVALID: %/%', v_bucket, v_path;
    end if;
    insert into public.video_reference_images (asset_id, bucket, object_path, is_active, set_by)
    values (v_asset_id, v_bucket, v_path, true, p_actor)
    on conflict (asset_id) do update
        set bucket = excluded.bucket, object_path = excluded.object_path, is_active = true,
            set_by = excluded.set_by, updated_at = now();
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_REFERENCE_SET', 'INFO', 'CONTROL_PLANE',
            'Public reference image set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'bucket', v_bucket, 'object_path', v_path));
    return jsonb_build_object(
        'asset_code', p_asset_code, 'decision', 'SET',
        'url', rtrim(m417_internal.txt('storage_base_url', ''), '/') || '/object/public/' || v_bucket || '/' || v_path);
end;
$function$;

do $$
declare
    r record;
    v_role text;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where (n.nspname = 'public' and p.proname = 'set_video_reference')
           or (n.nspname = 'm417_internal' and p.proname in ('shot_reference_images', 'build_provider_request'))
    loop
        execute format('revoke all on function %s from public', r.sig);
        foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
            if exists (select 1 from pg_roles where rolname = v_role) then
                execute format('revoke all on function %s from %I', r.sig, v_role);
            end if;
        end loop;
    end loop;
end $$;

-- ----- the model ------------------------------------------------------
insert into public.generation_models (
    provider_id, model_code, display_name, model_version, media_type, status,
    supports_text_to_video, supports_image_to_video, supports_reference_images,
    supports_character_consistency,
    min_duration_seconds, max_duration_seconds,
    supported_aspect_ratios, supported_resolutions, capability_metadata)
select gp.id, 'kling-3.0-omni-720p', 'Kling 3.0 Omni 720p (PiAPI)', '3.0', 'VIDEO', 'ACTIVE',
       true, true, true, true, 5, 10,
       '["9:16", "16:9", "1:1"]'::jsonb, '["720p"]'::jsonb,
       '{"allowed_durations": [5, 10], "api_model": "kling", "task_type": "omni_video_generation", "resolution": "720p", "max_reference_images": 4}'::jsonb
from public.generation_providers gp
where gp.provider_code = 'PIAPI_KLING'
  and not exists (select 1 from public.generation_models where model_code = 'kling-3.0-omni-720p');

insert into public.generation_model_pricing (
    model_id, pricing_version, billing_unit, unit_price, effective_from,
    is_verified, verified_at, source_reference)
select gm.id, 1, 'PER_SECOND', 0.10, now(), true, now(),
       'https://piapi.ai/docs/kling-api/kling-3-omni-api - Kling 3.0 Omni 720p without audio: 0.10 USD per second; read 2026-10-09'
from public.generation_models gm
where gm.model_code = 'kling-3.0-omni-720p'
  and not exists (select 1 from public.generation_model_pricing p where p.model_id = gm.id);

-- An active policy cannot be changed; the most recently approved
-- active policy is the one in force.
insert into public.generation_routing_policies (
    policy_code, version, display_name, status,
    minimum_quality_score, minimum_pass_rate, fallback_on_second_attempt)
select 'M417_KLING_OMNI', 1, 'Kling 3.0 Omni with character references (pilot)', 'DRAFT', 70, 60, false
where not exists (select 1 from public.generation_routing_policies where policy_code = 'M417_KLING_OMNI');

insert into public.generation_policy_models (policy_id, model_id, route_role, route_priority)
select grp.id, gm.id, 'PRIMARY', 1
from public.generation_routing_policies grp, public.generation_models gm
where grp.policy_code = 'M417_KLING_OMNI' and grp.status = 'DRAFT'
  and gm.model_code = 'kling-3.0-omni-720p'
  and not exists (
      select 1 from public.generation_policy_models x
      where x.policy_id = grp.id and x.model_id = gm.id);

update public.generation_routing_policies
set status = 'ACTIVE', approved_at = now()
where policy_code = 'M417_KLING_OMNI' and status = 'DRAFT';

select public.approve_model_pilot(
    'kling-3.0-omni-720p', 'FATIH',
    'No separate paid benchmark: the first shot made with it is the trial.');

-- ----- the public copies of the character references -------------------
-- Only where the owner has not already chosen a file.
select public.set_video_reference(x.asset_code, x.object_path, 'FATIH')
from (values
    ('MIA_CANONICAL_V1',    'MIA_REF_V1.png'),
    ('FATIH_CANONICAL_V1',  'FATIH_REF_V1.png'),
    ('BRUCE_CANONICAL_V1',  'BRUCE_REF_V1.png'),
    ('TOMBIK_CANONICAL_V1', 'TOMBIK_REF_V1.png'),
    ('OMER_CANONICAL_V1',   'OMER_REF_V1.png')
) as x(asset_code, object_path)
join public.asset_registry ar on ar.asset_code = x.asset_code and ar.status = 'LOCKED'
where not exists (select 1 from public.video_reference_images v where v.asset_id = ar.id);

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_008_APPLIED', 'INFO', 'CONTROL_PLANE',
        'Character reference images and Kling 3.0 Omni (008) applied.',
        jsonb_build_object('model_code', 'kling-3.0-omni-720p', 'usd_per_second', 0.10, 'applied_at', now()));

notify pgrst, 'reload schema';

commit;
