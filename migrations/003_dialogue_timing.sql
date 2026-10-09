-- =====================================================================
-- M417 / WIZZLEBURY  -  003 dialogue timing
--
-- Run after 002. Safe to run more than once; one transaction.
--
-- 1. A dialogue line is measured against its scene and its shot when the
--    script and the shot package are saved, before any voice is paid for.
-- 2. The writers are told the speech-time rule in the series bible.
-- 3. A voice take that ran too long is retaken at a faster speed; when
--    no allowed speed can make it fit, no further take is paid for.
-- =====================================================================
begin;

do $$
begin
    if to_regclass('public.production_jobs') is null
       or to_regprocedure('public.list_voice_work(uuid)') is null
       or to_regprocedure('m417_internal.clean(text)') is null
    then
        raise exception 'M417_002_NOT_FOUND: apply 002_pipeline_layers.sql first';
    end if;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('speech_chars_per_second', 13, 'Speaking rate used to check, before any voice is paid for, that a dialogue line fits its shot.'),
    ('speech_padding_seconds', 0.3, 'Silence a voice file carries around the spoken words.'),
    ('max_voice_speed', 1.3, 'Fastest speaking speed a retake may use to make a line fit its shot.')
on conflict (key) do nothing;

create or replace function m417_internal.speech_seconds(p_text text)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select case when m417_internal.clean(p_text) = '' then 0
           else round(char_length(m417_internal.clean(p_text))
                      / greatest(m417_internal.num('speech_chars_per_second', 13), 1)
                      + m417_internal.num('speech_padding_seconds', 0.3), 2) end;
$function$;

create or replace function m417_internal.speech_max_chars(p_seconds numeric)
 returns integer language sql stable security definer set search_path to ''
as $function$
    select greatest(0, floor((coalesce(p_seconds, 0) - m417_internal.num('speech_padding_seconds', 0.3))
                             * greatest(m417_internal.num('speech_chars_per_second', 13), 1)))::integer;
$function$;

create or replace function m417_internal.series_bible(p_job_id uuid)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_series public.series;
    v_profile public.production_creative_profiles;
    v_style jsonb;
    v_characters jsonb;
    v_locations jsonb;
    v_durations integer[];
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    select s.* into v_series from public.series s where s.id = v_job.series_id;
    select p.* into v_profile from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select to_jsonb(x) into v_style
    from (
        select sb.visual_style, sb.color_language, sb.lighting_language, sb.camera_language,
               sb.texture_language, sb.animation_language, sb.negative_rules
        from public.style_bibles sb
        where sb.series_id = v_series.id and sb.status <> 'ARCHIVED'
        order by sb.version desc
        limit 1
    ) x;

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.character_code,
               'name', c.name,
               'age', c.age,
               'role', c.role_type,
               'description', c.canonical_description,
               'core_traits', c.personality -> 'core_traits',
               'weaknesses', c.personality -> 'weaknesses',
               'behavior_rules', c.behavior_rules,
               'relationships', c.relationship_rules,
               'has_voice', m417_internal.character_voice(c.id) is not null,
               'reference_asset', (
                   select ar.asset_code
                   from public.asset_registry ar
                   where ar.character_id = c.id
                     and ar.asset_type = 'CHARACTER_REFERENCE'
                     and ar.status = 'LOCKED'
                   order by ar.version desc
                   limit 1)
           ) order by c.character_code), '[]'::jsonb)
    into v_characters
    from public.characters c
    where c.series_id = v_series.id
      and c.status = 'LOCKED';

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', l.location_code,
               'name', l.name,
               'type', l.location_type,
               'description', left(l.canonical_description, 220),
               'reference_assets', (
                   select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
                   from public.asset_registry ar
                   where ar.location_id = l.id
                     and ar.asset_type = 'LOCATION_REFERENCE'
                     and ar.status = 'LOCKED')
           ) order by l.location_code), '[]'::jsonb)
    into v_locations
    from public.locations l
    where l.series_id = v_series.id
      and l.status <> 'ARCHIVED';

    v_durations := m417_internal.allowed_shot_durations();

    return jsonb_build_object(
        'series', jsonb_build_object(
            'code', v_series.series_code,
            'name', v_series.name,
            'language', v_series.primary_language,
            'target_audience', v_series.target_audience,
            'target_age_min', v_series.target_age_min,
            'target_age_max', v_series.target_age_max,
            'premise', v_series.premise,
            'world_rules', v_series.world_rules,
            'creative_rules', v_series.creative_rules,
            'forbidden_rules', v_series.forbidden_rules),
        'format', jsonb_build_object(
            'production_mode', v_profile.production_mode,
            'aspect_ratio', v_profile.aspect_ratio,
            'total_duration_seconds_min', greatest(v_profile.target_duration_min_seconds, 6),
            'total_duration_seconds_target_max', v_profile.target_duration_max_seconds,
            'total_duration_seconds_hard_max', least(v_profile.hard_duration_max_seconds, 15),
            'hook_deadline_seconds', v_profile.hook_deadline_seconds,
            'allowed_shot_durations_seconds', coalesce(to_jsonb(v_durations), '"any whole number from 1 to 15"'::jsonb),
            'shot_duration_rule', 'Every shot duration must be one of allowed_shot_durations_seconds. The sum of all shot durations must lie inside the total duration limits.',
            'code_rule', 'Use the exact character and location codes listed here. Do not invent characters, locations or assets.',
            'dialogue_rule', 'Only characters with has_voice = true may speak.',
            'dialogue_timing_rule', format(
                'Spoken lines are checked against real speech time: about 1 second per %s characters (spaces and punctuation included) plus %s s per line. All lines spoken in a shot must fit inside that shot, and all lines of a scene inside that scene. Dialogue that fits: 2 s holds %s characters, 3 s holds %s, 4 s holds %s, 5 s holds %s. Write short lines; when in doubt, cut words.',
                m417_internal.num('speech_chars_per_second', 13)::text,
                m417_internal.num('speech_padding_seconds', 0.3)::text,
                m417_internal.speech_max_chars(2), m417_internal.speech_max_chars(3),
                m417_internal.speech_max_chars(4), m417_internal.speech_max_chars(5)),
            'creative_rules', v_profile.creative_rules,
            'quality_rules', v_profile.quality_rules),
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

create or replace function m417_internal.validate_script(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_issues jsonb := '[]'::jsonb;
    v_scene jsonb;
    v_line jsonb;
    v_scene_no text;
    v_total numeric := 0;
    v_dur numeric;
    v_char uuid;
    v_scene_idx integer := 0;
    v_speech numeric;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if jsonb_typeof(p_content -> 'scenes') is distinct from 'array'
       or jsonb_array_length(p_content -> 'scenes') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SCRIPT', 'scenes', 'The script has no scenes array.',
            'Return the script in the required JSON shape with at least one scene.'));
    end if;
    for v_scene in select * from jsonb_array_elements(p_content -> 'scenes')
    loop
        v_scene_idx := v_scene_idx + 1;
        v_scene_no := coalesce(v_scene ->> 'scene_no', v_scene_idx::text);
        v_dur := m417_internal.safe_numeric(v_scene ->> 'duration_seconds');
        if v_dur is null or v_dur <= 0 then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no, 'duration_seconds is missing or not positive.',
                'Give every scene a positive duration in seconds.');
        else
            v_total := v_total + v_dur;
        end if;
        if coalesce(btrim(v_scene ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_scene ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                'Unknown location: ' || (v_scene ->> 'location'),
                'Use one of the location codes from the series bible.');
        end if;
        v_speech := 0;
        if jsonb_typeof(v_scene -> 'dialogue') = 'array' then
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if coalesce(btrim(v_line ->> 'text'), '') = '' then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Dialogue line has no text.', 'Remove the line or give it text.');
                end if;
                v_char := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                if v_char is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Unknown speaking character: ' || coalesce(v_line ->> 'character', '(empty)'),
                        'Use a character code from the series bible.');
                elsif m417_internal.character_voice(v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Character has no locked voice: ' || (v_line ->> 'character'),
                        'Give the line to a character with has_voice = true.');
                end if;
            end loop;
        end if;
        -- Checked here, before any voice is paid for.
        if v_dur is not null and v_dur > 0 and v_speech > v_dur + v_tol then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                format('The dialogue of this scene takes about %s s to say, but the scene lasts %s s.', v_speech, v_dur),
                format('Shorten the lines of this scene to at most %s characters in total (spaces included), or make the scene longer. See dialogue_timing_rule.',
                       m417_internal.speech_max_chars(v_dur)));
        end if;
    end loop;
    if v_total < 6 or v_total > 15 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'total duration',
            'Scene durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.',
            'Adjust scene durations so the total is between 6 and 15 seconds.');
    end if;
    return v_issues;
end;
$function$;

create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_script jsonb;
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_idx integer := 0;
    v_ref text;
    v_dur numeric;
    v_total numeric := 0;
    v_allowed integer[] := m417_internal.allowed_shot_durations();
    v_char text;
    v_line_no text;
    v_line jsonb;
    v_assigned text[] := array[]::text[];
    v_missing record;
    v_speech numeric;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    v_script := m417_internal.artifact(p_job_id, 'SCRIPT');
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array'
       or jsonb_array_length(p_content -> 'shots') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SHOTS', 'shots', 'The shot package has no shots array.',
            'Return the shot package in the required JSON shape with at least one shot.'));
    end if;
    if jsonb_array_length(p_content -> 'shots') > 6 then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots', 'More than 6 shots.', 'Use at most 6 shots.');
    end if;
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        v_ref := 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text);
        v_dur := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');
        if v_dur is null or v_dur < 1 or v_dur > 15 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'duration_seconds is missing or outside 1 to 15.',
                'Give the shot a duration from allowed_shot_durations_seconds.');
        else
            v_total := v_total + v_dur;
            if v_allowed is not null
               and (v_dur <> trunc(v_dur) or not (v_dur::integer = any (v_allowed)))
            then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    'Duration ' || v_dur || ' is not supported by the video model. Allowed: ' || array_to_string(v_allowed, ', '),
                    'Use one of the allowed shot durations.');
            end if;
        end if;
        if coalesce(btrim(v_shot ->> 'video_prompt'), '') = '' then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'video_prompt is empty.', 'Write the video prompt for this shot.');
        end if;
        if jsonb_typeof(v_shot -> 'characters') = 'array' then
            for v_char in select * from jsonb_array_elements_text(v_shot -> 'characters')
            loop
                if m417_internal.resolve_character(v_job.series_id, v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown character: ' || v_char,
                        'Use character codes from the series bible.');
                end if;
            end loop;
        end if;
        if coalesce(btrim(v_shot ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'Unknown location: ' || (v_shot ->> 'location'),
                'Use a location code from the series bible.');
        end if;
        v_speech := 0;
        if jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array' then
            for v_line_no in select * from jsonb_array_elements_text(v_shot -> 'dialogue_line_nos')
            loop
                v_line := m417_internal.script_line(v_script, v_shot ->> 'scene_no', v_line_no);
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if v_line is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref,
                        'dialogue_line_nos refers to line ' || v_line_no || ', which is not in scene ' || coalesce(v_shot ->> 'scene_no', '?') || ' of the script.',
                        'Reference only line numbers that exist in the script scene of this shot.');
                else
                    v_assigned := v_assigned || ((v_line ->> 'scene_no') || ':' || (v_line ->> 'line_no'));
                end if;
            end loop;
        end if;
        if v_dur is not null and v_dur >= 1 and v_speech > v_dur + v_tol then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                format('The lines spoken in this shot take about %s s to say, but the shot lasts %s s.', v_speech, v_dur),
                format('Give this shot at least %s s (an allowed duration), or move one of its lines to a neighbouring shot of the same scene. Do not change the script text.',
                       ceil(v_speech - v_tol)));
        end if;
    end loop;
    if v_total < 6 or v_total > 15 then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'total duration',
            'Shot durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.',
            'Change the number of shots or their durations so the total is between 6 and 15 seconds.');
    end if;
    -- Every scripted line must be spoken in exactly one shot.
    for v_missing in
        select coalesce(s.scene ->> 'scene_no', s.idx::text) as scene_no,
               coalesce(l.line ->> 'line_no', l.idx::text) as line_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as s(scene, idx)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(s.scene -> 'dialogue') = 'array'
                 then s.scene -> 'dialogue' else '[]'::jsonb end
        ) with ordinality as l(line, idx)
    loop
        if not ((v_missing.scene_no || ':' || v_missing.line_no) = any (v_assigned)) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'scene ' || v_missing.scene_no || ' line ' || v_missing.line_no,
                'This script line is not assigned to any shot.',
                'Add the line number to dialogue_line_nos of the shot in which it is spoken.');
        end if;
    end loop;
    if (select count(*) from unnest(v_assigned) a) <> (select count(distinct a) from unnest(v_assigned) a) then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'dialogue_line_nos', 'A script line is assigned to more than one shot.',
            'Assign every script line to exactly one shot.');
    end if;
    return v_issues;
end;
$function$;

create or replace function m417_internal.voice_retake_plan(
    p_take_id uuid, out speed numeric, out fits boolean, out detail text)
 language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_available numeric;
    v_natural numeric;
    v_prev_speed numeric;
    v_max numeric := m417_internal.num('max_voice_speed', 1.3);
begin
    speed := 1; fits := true; detail := null;
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id;
    if not found or coalesce(v_take.qc_notes, '') not like 'DIALOGUE_LONGER_THAN_SHOT%' then
        return;
    end if;
    select ss.duration_seconds into v_spec_duration
    from public.shot_specifications ss where ss.id = v_take.shot_specification_id;
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_available := v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5) - v_other;
    v_prev_speed := round(greatest(coalesce(m417_internal.safe_numeric(v_take.timing_metadata ->> 'requested_speed'), 1), 1), 2);
    -- Length at normal speed: the newest take of this line recorded at speed 1.
    select o.duration_seconds into v_natural
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order = v_take.audio_order
      and o.duration_seconds is not null
      and coalesce(m417_internal.safe_numeric(o.timing_metadata ->> 'requested_speed'), 1) <= 1.001
    order by o.take_no desc
    limit 1;
    v_natural := round(coalesce(v_natural, v_take.duration_seconds * v_prev_speed), 2);
    v_available := round(v_available, 2);
    if v_available <= 0 then
        fits := false;
        detail := format('needs %s s at normal speed; the other lines already fill the %s s shot', v_natural, v_spec_duration);
        return;
    end if;
    speed := ceil(v_natural / v_available * 1.04 * 100) / 100;
    if speed > v_max then
        fits := false;
        detail := format('needs %s s at normal speed, %s s are available in the %s s shot; faster than %sx is not allowed',
                         v_natural, v_available, v_spec_duration, v_max);
    elsif v_prev_speed >= speed - 0.005 then
        -- Already asked for this speed and it still did not fit.
        fits := false;
        detail := format('still %s s after a retake at %sx; %s s are available in the %s s shot',
                         round(v_take.duration_seconds, 2), v_prev_speed, v_available, v_spec_duration);
    end if;
end;
$function$;

create or replace function public.list_voice_work(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_items jsonb := '[]'::jsonb;
    v_line record;
    v_max integer := m417_internal.num('max_voice_takes', 3)::integer;
    v_series_code text;
    v_content_id text;
    v_verdict text;
    v_plan record;
    v_speed numeric;
begin
    v_job := m417_internal.lock_job(p_job_id);
    if m417_internal.flag('pipeline_enabled', false) is not true
       or v_job.state <> 'READY'
       or v_job.current_step not between 16 and 18
    then
        return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
    end if;
    select s.series_code into v_series_code from public.series s where s.id = v_job.series_id;
    select e.content_id into v_content_id from public.episodes e where e.id = v_job.episode_id;

    for v_line in
        select distinct on (sap.shot_specification_id, sap.audio_order)
               sap.id, sap.status, sap.take_no, sap.dialogue_text, sap.audio_order,
               s.shot_code, vi.provider_voice_id
        from public.shot_audio_productions sap
        join public.shot_specifications ss on ss.id = sap.shot_specification_id and ss.is_active = true
        join public.shots s on s.id = ss.shot_id
        join public.voice_identities vi on vi.id = sap.voice_identity_id
        where s.episode_id = v_job.episode_id
          and sap.status <> 'ARCHIVED'
        order by sap.shot_specification_id, sap.audio_order, sap.take_no desc
    loop
        -- A registered take whose QC never arrived is judged now.
        if v_line.status in ('GENERATED', 'QC_PENDING') then
            v_verdict := m417_internal.judge_voice_take(v_line.id, null, null);
            v_line.status := case v_verdict when 'PASS' then 'APPROVED' else 'REJECTED' end;
        end if;
        if v_line.status = 'PLANNED' or (v_line.status = 'REJECTED' and v_line.take_no < v_max) then
            v_speed := 1;
            if v_line.status = 'REJECTED' then
                select * into v_plan from m417_internal.voice_retake_plan(v_line.id);
                if v_plan.fits is not true then
                    perform m417_internal.block_job(
                        p_job_id, 'DIALOGUE_DOES_NOT_FIT_SHOT',
                        format('%s line %s: %s', v_line.shot_code, v_line.audio_order, v_plan.detail));
                    return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
                end if;
                v_speed := v_plan.speed;
            end if;
            v_items := v_items || jsonb_build_object(
                'line_id', v_line.id,
                'action', case v_line.status when 'PLANNED' then 'GENERATE' else 'RETAKE' end,
                'text', m417_internal.clean(v_line.dialogue_text),
                'voice_reference_id', v_line.provider_voice_id,
                'speed', v_speed,
                'storage_path', format('%s/%s/audio/%s_L%s_T%s_S%s_%s.mp3',
                    v_series_code, v_content_id, v_line.shot_code, v_line.audio_order,
                    case v_line.status when 'PLANNED' then v_line.take_no else v_line.take_no + 1 end,
                    round(v_speed * 100)::integer,
                    m417_internal.rand_suffix()));
        elsif v_line.status = 'REJECTED' then
            perform m417_internal.block_job(
                p_job_id, 'VOICE_TAKE_LIMIT_REACHED',
                format('%s line %s failed %s takes.', v_line.shot_code, v_line.audio_order, v_line.take_no));
            return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
        end if;
    end loop;

    if jsonb_array_length(v_items) = 0 then
        perform m417_internal.finish_voice_if_done(p_job_id);
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('items', v_items, 'count', jsonb_array_length(v_items));
end;
$function$;

create or replace function public.register_voice_take(
    p_line_id uuid, p_action text, p_storage_path text, p_mp3_bitrate_kbps integer default 128)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_line public.shot_audio_productions;
    v_action text := upper(btrim(coalesce(p_action, '')));
    v_job_id uuid;
    v_take_id uuid;
    v_take_no integer;
    v_size bigint;
    v_duration numeric;
    v_kbps integer := coalesce(nullif(p_mp3_bitrate_kbps, 0), 128);
    -- The speed the take was asked for travels in the file name (_S125_ = 1.25x).
    v_speed numeric := round(coalesce(
        m417_internal.safe_numeric(substring(p_storage_path from '_S([0-9]{2,3})_')) / 100, 1), 2);
begin
    if v_action not in ('GENERATE', 'RETAKE') then
        raise exception 'INVALID_VOICE_ACTION: %', coalesce(p_action, '(empty)');
    end if;
    if p_storage_path is null or btrim(p_storage_path) = '' then
        raise exception 'STORAGE_PATH_REQUIRED';
    end if;
    select t.* into v_line from public.shot_audio_productions t where t.id = p_line_id for update;
    if not found then
        raise exception 'VOICE_LINE_NOT_FOUND';
    end if;

    select j.id into v_job_id
    from public.shot_specifications ss
    join public.shots s on s.id = ss.shot_id
    join public.production_jobs j on j.episode_id = s.episode_id
    where ss.id = v_line.shot_specification_id;
    if v_job_id is null then
        raise exception 'VOICE_LINE_HAS_NO_JOB';
    end if;

    v_size := m417_internal.object_size(p_storage_path);
    if v_size is null or v_size <= 0 then
        raise exception 'VOICE_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;
    v_duration := round((v_size * 8)::numeric / (v_kbps * 1000), 3);

    if v_action = 'GENERATE' then
        if v_line.status <> 'PLANNED' then
            -- The same registration repeated.
            if v_line.storage_path = p_storage_path then
                return jsonb_build_object('take_id', v_line.id, 'take_no', v_line.take_no,
                                          'duration_seconds', v_line.duration_seconds, 'decision', 'ALREADY_REGISTERED');
            end if;
            raise exception 'VOICE_LINE_NOT_PLANNED: %', v_line.status;
        end if;
        v_take_id := v_line.id;
        v_take_no := v_line.take_no;
        update public.shot_audio_productions
        set storage_provider = 'SUPABASE_STORAGE',
            storage_path = p_storage_path,
            mime_type = 'audio/mpeg',
            duration_seconds = v_duration,
            status = 'QC_PENDING',
            timing_metadata = timing_metadata
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps, 'requested_speed', v_speed)
        where id = v_take_id;
    else
        if v_line.status <> 'REJECTED' then
            raise exception 'RETAKE_REQUIRES_REJECTED_TAKE: %', v_line.status;
        end if;
        select max(t.take_no) + 1 into v_take_no
        from public.shot_audio_productions t
        where t.shot_specification_id = v_line.shot_specification_id
          and t.audio_order = v_line.audio_order;
        if v_take_no > m417_internal.num('max_voice_takes', 3) then
            raise exception 'VOICE_TAKE_LIMIT_REACHED';
        end if;
        insert into public.shot_audio_productions (
            shot_specification_id, character_id, voice_identity_id, audio_order, dialogue_text,
            language, provider, storage_provider, storage_path, mime_type, duration_seconds,
            lip_sync_required, lip_sync_status, timing_metadata, status, take_no)
        values (
            v_line.shot_specification_id, v_line.character_id, v_line.voice_identity_id,
            v_line.audio_order, v_line.dialogue_text, v_line.language, v_line.provider,
            'SUPABASE_STORAGE', p_storage_path, 'audio/mpeg', v_duration,
            v_line.lip_sync_required, v_line.lip_sync_status,
            (v_line.timing_metadata - 'file_size_bytes' - 'bitrate_kbps' - 'requested_speed')
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps, 'requested_speed', v_speed),
            'QC_PENDING', v_take_no)
        returning id into v_take_id;
    end if;

    perform m417_internal.usage(v_job_id, 'FISH_AUDIO', 'VOICE_TAKE',
                                char_length(v_line.dialogue_text), 'character');
    update public.production_jobs set last_activity_at = now() where id = v_job_id;

    return jsonb_build_object('take_id', v_take_id, 'take_no', v_take_no,
                              'duration_seconds', v_duration, 'decision', 'REGISTERED');
end;
$function$;

create or replace function public.apply_voice_qc(
    p_take_id uuid, p_verdict text, p_score numeric default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job_id uuid;
    v_verdict text := upper(btrim(coalesce(p_verdict, '')));
    v_final text;
    v_take public.shot_audio_productions;
    v_shot_code text;
    v_plan record;
begin
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'INVALID_VOICE_QC_VERDICT: %', coalesce(p_verdict, '(empty)');
    end if;
    select j.id, s.shot_code into v_job_id, v_shot_code
    from public.shot_audio_productions t
    join public.shot_specifications ss on ss.id = t.shot_specification_id
    join public.shots s on s.id = ss.shot_id
    join public.production_jobs j on j.episode_id = s.episode_id
    where t.id = p_take_id;
    if v_job_id is null then
        raise exception 'VOICE_TAKE_NOT_FOUND';
    end if;
    perform m417_internal.lock_job(v_job_id);

    v_final := m417_internal.judge_voice_take(
        p_take_id, p_score,
        case when v_verdict = 'FAIL' then 'REJECTED_BY_REVIEWER' else null end);
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id;

    if v_final = 'PASS' then
        perform m417_internal.finish_voice_if_done(v_job_id);
    elsif v_take.take_no >= m417_internal.num('max_voice_takes', 3) then
        perform m417_internal.block_job(
            v_job_id, 'VOICE_TAKE_LIMIT_REACHED',
            format('%s line %s: %s', v_shot_code, v_take.audio_order, coalesce(v_take.qc_notes, '')));
    else
        select * into v_plan from m417_internal.voice_retake_plan(p_take_id);
        if v_plan.fits is not true then
            perform m417_internal.block_job(
                v_job_id, 'DIALOGUE_DOES_NOT_FIT_SHOT',
                format('%s line %s: %s', v_shot_code, v_take.audio_order, v_plan.detail));
        end if;
    end if;

    return m417_internal.job_status(v_job_id)
        || jsonb_build_object('take_id', p_take_id, 'verdict', v_final,
                              'reason', coalesce(v_take.qc_notes, ''),
                              'duration_seconds', v_take.duration_seconds);
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
        where n.nspname = 'm417_internal'
          and p.proname in ('speech_seconds', 'speech_max_chars', 'voice_retake_plan')
    loop
        execute format('revoke all on function %s from public', r.sig);
        foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
            if exists (select 1 from pg_roles where rolname = v_role) then
                execute format('revoke all on function %s from %I', r.sig, v_role);
            end if;
        end loop;
    end loop;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_003_APPLIED', 'INFO', 'CONTROL_PLANE', 'Dialogue timing (003) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
