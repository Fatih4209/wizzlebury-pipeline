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
