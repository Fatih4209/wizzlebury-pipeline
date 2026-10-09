
-- ----- the prompt of a film shot -------------------------------------
-- What the video model reads for a planned shot: framing, the action
-- with its timing, who talks, then the wardrobe, props and look fixed by
-- the script - worded the same way in every shot of the episode - and
-- last the series style. When the text has to be cut, the end goes.
create or replace function m417_internal.compose_shot_prompt(
    p_series_id uuid, p_script jsonb, p_shot jsonb, p_character_ids uuid[],
    p_location_id uuid, p_speaker_id uuid, p_cut numeric)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_parts text[] := array[]::text[];
    v_text text;
    v_n integer := coalesce(cardinality(p_character_ids), 0);
    v_size text := m417_internal.film_size(p_shot ->> 'shot_size');
    v_stage text := m417_internal.voice_stage(p_shot ->> 'voice_staging');
    v_speaker text;
    v_window numeric;
begin
    v_parts := v_parts || m417_internal.film_size_sentence(v_size);
    v_parts := v_parts || left(btrim(coalesce(p_shot ->> 'video_prompt', '')), 800);

    select string_agg(
               'at ' || to_char(coalesce(m417_internal.safe_numeric(b.value ->> 'at'), 0), 'FM990.0') || ' s '
               || rtrim(left(btrim(coalesce(b.value ->> 'what', '')), 160), '. '),
               '; ' order by b.ord)
    into v_text
    from jsonb_array_elements(
        case when jsonb_typeof(p_shot -> 'beats') = 'array' then p_shot -> 'beats' else '[]'::jsonb end
    ) with ordinality as b(value, ord);
    v_window := ceil((coalesce(p_cut, 0) + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2;
    if v_text is not null then
        v_parts := v_parts || format(
            'Timing: %s. The action starts immediately and all of it happens within the first %s seconds; after that everyone holds the final pose.',
            v_text, to_char(v_window, 'FM990.0'));
    end if;

    select c.name into v_speaker from public.characters c where c.id = p_speaker_id;
    v_parts := v_parts || case
        when v_speaker is null then
            'Nobody speaks in this shot: no talking mouth movements. Feelings show in the eyes, eyebrows and body, in a smile, a gasp or a laugh.'
        when v_stage = 'ON_CAMERA' then
            v_speaker || ' is talking from the first moment of the shot, mouth moving naturally, with matching gestures. Nobody else talks: their mouths stay closed while they listen.'
        when v_stage = 'BACK_TO_CAMERA' then
            v_speaker || ' is talking but is seen only from behind, the back of the head and the shoulders; the face of ' || v_speaker || ' is never visible. Nobody else talks: their mouths stay closed while they listen.'
        else
            'A voice is heard from off-screen. Nobody visible talks: their mouths stay closed while they listen and react.'
        end;

    if coalesce(btrim(p_shot ->> 'acting'), '') <> '' then
        v_parts := v_parts || ('Acting: ' || left(btrim(p_shot ->> 'acting'), 180));
    end if;
    if coalesce(btrim(p_shot ->> 'camera'), '') <> '' then
        v_parts := v_parts || ('Camera: ' || left(btrim(p_shot ->> 'camera'), 150));
    end if;

    select string_agg(c.name || ' wears ' || rtrim(left(btrim(w.value ->> 'outfit'), 170), '. '),
                      '. ' order by c.character_code)
    into v_text
    from jsonb_array_elements(
        case when jsonb_typeof(p_script -> 'wardrobe') = 'array' then p_script -> 'wardrobe' else '[]'::jsonb end) w(value)
    join public.characters c
      on c.id = m417_internal.resolve_character(p_series_id, w.value ->> 'character')
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Wardrobe in this episode, the same in every shot: ' || v_text || '.');
    end if;

    select string_agg(rtrim(left(btrim(m417_internal.script_prop(p_script, n.value) ->> 'description'), 150), '. '),
                      '; ' order by n.ord)
    into v_text
    from jsonb_array_elements_text(
        case when jsonb_typeof(p_shot -> 'props') = 'array' then p_shot -> 'props' else '[]'::jsonb end
    ) with ordinality as n(value, ord)
    where m417_internal.script_prop(p_script, n.value) is not null;
    if v_text is not null then
        v_parts := v_parts || ('Props, exactly as described and no extra copies: ' || v_text || '.');
    end if;

    if coalesce(btrim(p_script ->> 'look'), '') <> '' then
        v_parts := v_parts || ('Look: ' || rtrim(left(btrim(p_script ->> 'look'), 160), '. ') || '.');
    end if;
    if v_n >= 2 and m417_internal.txt('cast_rule_text', '') <> '' then
        v_parts := v_parts || m417_internal.txt('cast_rule_text', '');
    end if;
    v_parts := v_parts || 'Vertical 9:16 framing. No on-screen text, subtitles, logos or watermarks.'::text;

    select left(coalesce(sb.visual_style, ''), 220) into v_text
    from public.style_bibles sb
    where sb.series_id = p_series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 180) into v_text
    from public.locations l where l.id = p_location_id;
    if v_text is not null then
        v_parts := v_parts || ('Location. ' || v_text);
    end if;
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''), 120),
                      ' ' order by c.character_code)
    into v_text
    from public.characters c
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Characters. ' || v_text);
    end if;
    return left(regexp_replace(array_to_string(v_parts, ' '), '[[:space:]]+', ' ', 'g'), 2400);
end;
$function$;

-- What the visual reviewer is told about a film shot.
create or replace function m417_internal.shot_qc_brief(
    p_series_id uuid, p_script jsonb, p_shot jsonb, p_character_ids uuid[], p_speaker_id uuid, p_cut numeric)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'shot_size', m417_internal.film_size(p_shot ->> 'shot_size'),
        'purpose', p_shot ->> 'purpose',
        'used_seconds', format(
            'The edit uses only about the first %s seconds of this clip. Judge those; what happens later does not matter.',
            to_char(ceil((coalesce(p_cut, 0) + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2, 'FM990.0')),
        'beats', case when jsonb_typeof(p_shot -> 'beats') = 'array' then p_shot -> 'beats' else '[]'::jsonb end,
        'speaker', (select c.name from public.characters c where c.id = p_speaker_id),
        'voice_staging', case when p_speaker_id is null then null
                              else m417_internal.voice_stage(p_shot ->> 'voice_staging') end,
        'mouth_rule', case when p_speaker_id is null
            then 'Nobody speaks in this shot. A character clearly talking is a defect; a gasp, a smile or a laugh is not.'
            else 'Only the speaker may be talking. The voice is added in the edit; exact lip-sync is not expected and is not a defect.' end,
        'wardrobe', coalesce((
            select jsonb_agg(jsonb_build_object('name', c.name, 'outfit', w.value ->> 'outfit') order by c.character_code)
            from jsonb_array_elements(
                case when jsonb_typeof(p_script -> 'wardrobe') = 'array' then p_script -> 'wardrobe' else '[]'::jsonb end) w(value)
            join public.characters c
              on c.id = m417_internal.resolve_character(p_series_id, w.value ->> 'character')
            where c.id = any (coalesce(p_character_ids, array[]::uuid[]))), '[]'::jsonb),
        'props', coalesce((
            select jsonb_agg(m417_internal.script_prop(p_script, n.value))
            from jsonb_array_elements_text(
                case when jsonb_typeof(p_shot -> 'props') = 'array' then p_shot -> 'props' else '[]'::jsonb end) n(value)
            where m417_internal.script_prop(p_script, n.value) is not null), '[]'::jsonb),
        'look', p_script ->> 'look',
        'cast_rule', m417_internal.txt('cast_rule_text', ''),
        'also_report', 'Add to details the field action_start_seconds: the second (a number) at which the described action visibly starts in this clip.');
$function$;

-- ----- reference images ----------------------------------------------
-- Reference images of a shot that a provider can fetch: the shot's
-- canonical references that have a public copy, in reference order.
-- Each element: {"n": 1, "role": "CHARACTER", "name": "Mia", "url": "https://...", "note": null}.
create or replace function m417_internal.shot_reference_images(p_spec_id uuid, p_limit integer)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.n, 'role', x.reference_role, 'name', x.name, 'url', x.url,
               'note', x.note) order by x.n), '[]'::jsonb)
    from (
        select row_number() over (order by sra.reference_order, ar.asset_code) as n,
               sra.reference_role,
               coalesce(c.name, l.name, ar.asset_code) as name,
               nullif(btrim(coalesce(v.wardrobe_note, '')), '') as note,
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
    v_names text;
    v_notes text;
    v_lead text;
    v_fix text;
    v_tail text;
    v_input jsonb;
    v_max integer;
begin
    select a.provider, a.model, a.shot_id, gm.model_version, gm.capability_metadata,
           ss.id as spec_id, ss.generation_prompt, ss.negative_prompt, ss.aspect_ratio,
           ss.duration_seconds, ss.resolution, ss.edit_seconds
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
            select string_agg(
                       '@image_' || (r.value ->> 'n') || ' is '
                       || case when r.value ->> 'role' = 'LOCATION'
                               then 'the location ' || (r.value ->> 'name')
                               else r.value ->> 'name' end,
                       ', ' order by (r.value ->> 'n')::integer),
                   string_agg(r.value ->> 'note', ' ' order by (r.value ->> 'n')::integer)
                       filter (where r.value ->> 'note' is not null)
            into v_names, v_notes
            from jsonb_array_elements(v_refs) r(value);
            v_lead := 'Reference images: ' || v_names
                   || '. A character reference image shows one single character, sometimes in more than one view.'
                   || ' Keep every character''s face, hair, skin tone, age and body proportions exactly as in their reference image;'
                   || ' the outfit follows the wardrobe given below, or the reference image when none is given.'
                   || case when v_notes is null then '' else ' ' || v_notes end
                   || ' Exactly one of each named character. One continuous shot, never a collage or a split screen. ';
        end if;
        -- A take that was rejected tells the next one what to avoid.
        if v_row.edit_seconds is not null then
            select ' Correction: an earlier take of this shot was rejected because: '
                   || rtrim(left(regexp_replace(btrim(go.qc_notes), '[[:space:]]+', ' ', 'g'), 260), '. ')
                   || '. Do not repeat this. '
            into v_fix
            from public.generation_outputs go
            where go.shot_id = v_row.shot_id
              and go.qc_status = 'FAIL'
              and coalesce(btrim(go.qc_notes), '') <> ''
            order by go.created_at desc
            limit 1;
        end if;
        v_lead := v_lead || coalesce(v_fix, '');
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

-- ----- the edit ------------------------------------------------------
-- Everything the edit is made of, in order, with its storage path.
-- A film shot contributes a cut out of its clip: the planned length,
-- made long enough for the voice spoken in it, starting where the
-- reviewer saw the action begin. Older shots are used whole.
create or replace function m417_internal.edit_list(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    with job as (
        select j.episode_id from public.production_jobs j where j.id = p_job_id
    ),
    cfg as (
        select m417_internal.num('edit_voice_lead_seconds', 0.15) as lead,
               m417_internal.num('edit_voice_tail_seconds', 0.35) as tail,
               m417_internal.num('edit_trim_lead_seconds', 0.2) as trim_lead
    ),
    base as (
        select s.id, s.shot_order, s.shot_code, ss.id as spec_id, ss.duration_seconds, ss.edit_seconds,
               go.storage_path,
               coalesce(m417_internal.safe_numeric(go.qc_details ->> 'action_start_seconds'),
                        m417_internal.safe_numeric(go.qc_details -> 'details' ->> 'action_start_seconds')) as action_at,
               (select coalesce(sum(sap.duration_seconds), 0) + 0.1 * greatest(count(*) - 1, 0)
                from public.shot_audio_productions sap
                where sap.shot_specification_id = ss.id and sap.is_canonical = true) as voice_seconds
        from job
        join public.shots s on s.episode_id = job.episode_id and s.state = 'LOCKED'
        join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
        join public.generation_outputs go on go.shot_id = s.id and go.is_canonical = true
    ),
    cut as (
        select b.*,
               case when b.edit_seconds is null then b.duration_seconds
                    else round(least(
                        greatest(b.edit_seconds,
                                 case when b.voice_seconds > 0 then b.voice_seconds + cfg.lead + cfg.tail else 0 end),
                        b.duration_seconds - cfg.trim_lead), 2) end as length
        from base b cross join cfg
    ),
    shots as (
        select c.*,
               case when c.edit_seconds is null then 0
                    else round(greatest(least(coalesce(c.action_at - 0.1, cfg.trim_lead),
                                              c.duration_seconds - c.length), 0), 2) end as trim,
               coalesce(sum(c.length) over (order by c.shot_order
                   rows between unbounded preceding and 1 preceding), 0) as start_at
        from cut c cross join cfg
    ),
    voices as (
        select sh.shot_order, sap.audio_order, sap.storage_path, sap.duration_seconds,
               sh.start_at + cfg.lead
                 + coalesce(sum(sap.duration_seconds + 0.1) over (
                       partition by sh.id order by sap.audio_order
                       rows between unbounded preceding and 1 preceding), 0) as start_at
        from shots sh
        cross join cfg
        join public.shot_audio_productions sap
          on sap.shot_specification_id = sh.spec_id and sap.is_canonical = true
    ),
    music as (
        select mt.track_code, jmt.role, mt.storage_path, jmt.start_seconds, jmt.end_seconds, jmt.volume
        from public.job_music_tracks jmt
        join public.music_tracks mt on mt.id = jmt.track_id
        where jmt.job_id = p_job_id
    )
    select jsonb_build_object(
        'shots', coalesce((select jsonb_agg(jsonb_build_object(
                     'shot_code', shot_code, 'path', storage_path, 'start', start_at,
                     'length', length, 'trim', trim) order by shot_order) from shots), '[]'::jsonb),
        'voices', coalesce((select jsonb_agg(jsonb_build_object(
                     'path', storage_path, 'start', round(start_at, 3), 'length', duration_seconds)
                     order by shot_order, audio_order) from voices), '[]'::jsonb),
        'music', coalesce((select jsonb_agg(jsonb_build_object(
                     'track_code', track_code, 'role', role, 'path', storage_path,
                     'start', start_seconds, 'end', end_seconds, 'volume', volume)
                     order by start_seconds) from music), '[]'::jsonb),
        'total_seconds', coalesce((select sum(length) from shots), 0));
$function$;

-- ----- owner tools ---------------------------------------------------
-- The owner states what always holds for a character in generated video
-- (eye colour, height, a default outfit). An empty note removes it.
create or replace function public.set_video_wardrobe(p_asset_code text, p_note text, p_actor text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_note text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '[[:space:]]+', ' ', 'g')), '');
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if char_length(coalesce(v_note, '')) > 300 then
        raise exception 'WARDROBE_NOTE_TOO_LONG: at most 300 characters';
    end if;
    select v.asset_id into v_asset_id
    from public.video_reference_images v
    join public.asset_registry ar on ar.id = v.asset_id
    where ar.asset_code = p_asset_code;
    if not found then
        raise exception 'VIDEO_REFERENCE_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    update public.video_reference_images
    set wardrobe_note = v_note, updated_at = now()
    where asset_id = v_asset_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_WARDROBE_SET', 'INFO', 'CONTROL_PLANE',
            'Video character note set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'wardrobe_note', v_note));
    return jsonb_build_object('asset_code', p_asset_code, 'decision', 'SET', 'wardrobe_note', v_note);
end;
$function$;

-- ----- the duration envelope of an episode ---------------------------
-- These two guards date from before the film rules and measured an
-- episode by the summed length of its generated clips (6 to 15 s). A
-- film shot contributes its cut, and the envelope of a planned edit is
-- the one set for episodes. Everything else in them is unchanged.
create or replace function m417_internal.episode_envelope(p_episode_id uuid,
    out total numeric, out low numeric, out high numeric)
 language sql stable security definer set search_path to ''
as $function$
    select coalesce(sum(coalesce(ss.edit_seconds, ss.duration_seconds)), 0),
           case when bool_or(ss.edit_seconds is not null)
                then m417_internal.num('episode_min_seconds', 10) else 6 end,
           -- A voice may lengthen a cut, so the ceiling leaves room for that.
           case when bool_or(ss.edit_seconds is not null)
                then m417_internal.num('episode_max_seconds', 18) * 1.25 else 15 end
    from public.shots s
    join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
    where s.episode_id = p_episode_id;
$function$;

create or replace function public.validate_micro_short_manifest()
 returns trigger language plpgsql set search_path to ''
as $function$
declare
    v_production_mode text;
    v_manifest_shot_count integer;
    v_invalid_episode_count integer;
    v_invalid_binding_count integer;
    v_invalid_spec_count integer;
    v_pilot_binding_count integer;
    v_total_duration numeric;
    v_film boolean;
    v_low numeric := 6;
    v_high numeric := 15;
begin
    -- Only enforce the final production envelope when the manifest
    -- enters HUMAN_APPROVED or LOCKED.
    if new.status not in ('HUMAN_APPROVED', 'LOCKED') then
        return new;
    end if;

    select e.production_mode into v_production_mode
    from public.episodes e where e.id = new.episode_id;
    if not found then
        raise exception 'MICRO_SHORT_MANIFEST_EPISODE_NOT_FOUND';
    end if;
    -- SERIES_EPISODE is not governed by Micro Short policy.
    if v_production_mode <> 'MICRO_SHORT' then
        return new;
    end if;

    select count(*),
           count(*) filter (where s.episode_id is distinct from new.episode_id),
           count(*) filter (where ss.shot_id is distinct from pms.shot_id),
           count(*) filter (
               where ss.id is null
                  or ss.is_active is not true
                  or ss.status <> 'LOCKED'
                  or ss.locked_at is null
                  or ss.aspect_ratio <> '9:16'
                  or ss.duration_seconds < 1
                  or ss.duration_seconds > 15),
           coalesce(sum(coalesce(ss.edit_seconds, ss.duration_seconds)), 0),
           count(*) filter (where pms.shot_id = new.pilot_shot_id),
           coalesce(bool_or(ss.edit_seconds is not null), false)
    into v_manifest_shot_count, v_invalid_episode_count, v_invalid_binding_count,
         v_invalid_spec_count, v_total_duration, v_pilot_binding_count, v_film
    from public.production_manifest_shots pms
    left join public.shots s on s.id = pms.shot_id
    left join public.shot_specifications ss on ss.id = pms.shot_specification_id
    where pms.manifest_id = new.id;

    if v_manifest_shot_count < 1 then
        raise exception 'MICRO_SHORT_MANIFEST_EMPTY';
    end if;
    if v_invalid_episode_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_EPISODE_MISMATCH';
    end if;
    if v_invalid_binding_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_SPEC_BINDING_INVALID';
    end if;
    if v_invalid_spec_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_SPEC_INVALID';
    end if;

    -- Duration envelope: 6-15 s of clips, or the planned edit's limits.
    if v_film then
        select e.low, e.high into v_low, v_high
        from m417_internal.episode_envelope(new.episode_id) e;
    end if;
    if v_total_duration < v_low or v_total_duration > v_high then
        raise exception 'MICRO_SHORT_MANIFEST_DURATION_INVALID: %', v_total_duration;
    end if;

    -- The pilot must be part of the exact manifest.
    if v_pilot_binding_count <> 1 then
        raise exception 'MICRO_SHORT_MANIFEST_PILOT_BINDING_REQUIRED';
    end if;
    return new;
end;
$function$;

create or replace function public.validate_micro_short_production_mode()
 returns trigger language plpgsql set search_path to ''
as $function$
declare
    v_mode text;
    v_episode_id uuid;
    v_invalid_specs integer;
    v_env record;
begin
    if tg_table_name = 'episodes' then
        if new.production_mode = 'MICRO_SHORT'
           and new.state not in ('PLANNED', 'PREPRODUCTION', 'BLOCKED', 'CANCELLED')
        then
            select count(*) filter (
                       where ss.aspect_ratio <> '9:16'
                          or ss.duration_seconds < 1
                          or ss.duration_seconds > 15)
            into v_invalid_specs
            from public.shots s
            join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
            where s.episode_id = new.id;
            if v_invalid_specs > 0 then
                raise exception 'MICRO_SHORT_FORMAT_INVALID';
            end if;
            select * into v_env from m417_internal.episode_envelope(new.id);
            if v_env.total < coalesce(v_env.low, 6) or v_env.total > coalesce(v_env.high, 15) then
                raise exception 'MICRO_SHORT_TOTAL_DURATION_INVALID: %', v_env.total;
            end if;
        end if;
        return new;
    end if;

    if tg_table_name = 'shot_specifications' then
        select s.episode_id, e.production_mode into v_episode_id, v_mode
        from public.shots s
        join public.episodes e on e.id = s.episode_id
        where s.id = new.shot_id;
        if not found then
            raise exception 'SHOT_EPISODE_NOT_FOUND';
        end if;
        if v_mode = 'MICRO_SHORT' and new.is_active = true then
            if new.aspect_ratio <> '9:16' then
                raise exception 'MICRO_SHORT_REQUIRES_9_16';
            end if;
            if new.duration_seconds < 1 or new.duration_seconds > 15 then
                raise exception 'MICRO_SHORT_SHOT_DURATION_INVALID';
            end if;
        end if;
        return new;
    end if;
    return new;
end;
$function$;
