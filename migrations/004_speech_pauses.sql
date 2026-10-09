-- =====================================================================
-- M417 / WIZZLEBURY  -  004 speech pauses
--
-- Run after 003. Safe to run more than once; one transaction.
-- The speech-time estimate now follows the first real voice takes:
-- a pause is counted for every sentence break inside a line.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.speech_max_chars(numeric)') is null then
        raise exception 'M417_003_NOT_FOUND: apply 003_dialogue_timing.sql first';
    end if;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('speech_pause_seconds', 0.5, 'Pause the voice makes at a sentence break inside a line (. ! ? ...).')
on conflict (key) do nothing;

-- Measured on the first takes; only changed while still at the first default.
update public.system_settings
set value_numeric = 0.4, updated_at = now()
where key = 'speech_padding_seconds' and value_numeric = 0.3;

create or replace function m417_internal.speech_seconds(p_text text)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select case when m417_internal.clean(p_text) = '' then 0
           else round(char_length(m417_internal.clean(p_text))
                      / greatest(m417_internal.num('speech_chars_per_second', 13), 1)
                      + m417_internal.num('speech_padding_seconds', 0.4)
                      + m417_internal.num('speech_pause_seconds', 0.5)
                        * (select count(*) from regexp_matches(m417_internal.clean(p_text), '[.!?…]+\s+\S', 'g')),
                      2) end;
$function$;

create or replace function m417_internal.speech_max_chars(p_seconds numeric)
 returns integer language sql stable security definer set search_path to ''
as $function$
    select greatest(0, floor((coalesce(p_seconds, 0) - m417_internal.num('speech_padding_seconds', 0.4))
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
                'Spoken lines are checked against real speech time: about 1 second per %s characters (spaces and punctuation included) plus %s s per line, plus %s s for every sentence break inside a line (. ! ? or ... followed by more words). All lines spoken in a shot must fit inside that shot, and all lines of a scene inside that scene. A single-sentence line that fits: 2 s holds %s characters, 3 s holds %s, 4 s holds %s, 5 s holds %s. Prefer one short sentence per line; when in doubt, cut words or give the shot one more second.',
                m417_internal.num('speech_chars_per_second', 13)::text,
                m417_internal.num('speech_padding_seconds', 0.4)::text,
                m417_internal.num('speech_pause_seconds', 0.5)::text,
                m417_internal.speech_max_chars(2), m417_internal.speech_max_chars(3),
                m417_internal.speech_max_chars(4), m417_internal.speech_max_chars(5)),
            'creative_rules', v_profile.creative_rules,
            'quality_rules', v_profile.quality_rules),
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_004_APPLIED', 'INFO', 'CONTROL_PLANE', 'Speech pauses (004) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
