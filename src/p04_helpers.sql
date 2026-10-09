
-- ---------------------------------------------------------------------
-- 5. Internal helpers (schema m417_internal is not exposed by the API)
-- ---------------------------------------------------------------------
create or replace function m417_internal.flag(p_key text, p_default boolean)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select sf.value from public.system_flags sf where sf.key = p_key),
        p_default);
$function$;

create or replace function m417_internal.num(p_key text, p_default numeric)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select st.value_numeric from public.system_settings st where st.key = p_key),
        p_default);
$function$;

create or replace function m417_internal.txt(p_key text, p_default text default '')
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        nullif(btrim((select ts.value from public.system_text_settings ts where ts.key = p_key)), ''),
        p_default);
$function$;

-- Text that Make places between double quotes inside a JSON body.
create or replace function m417_internal.clean(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select btrim(regexp_replace(
        replace(replace(coalesce(p_text, ''), '"', ''''), chr(92), ''),
        '[[:space:]]+', ' ', 'g'));
$function$;

create or replace function m417_internal.rand_suffix()
 returns text language sql volatile set search_path to ''
as $function$
    select substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
$function$;

-- 0-1 scores from the models become 0-100; values already above 1 are kept.
create or replace function m417_internal.score100(p_score numeric)
 returns numeric language sql immutable set search_path to ''
as $function$
    select case
        when p_score is null then null
        when p_score < 0 then 0
        when p_score <= 1 then round(p_score * 100, 2)
        when p_score > 100 then 100
        else round(p_score, 2)
    end;
$function$;

-- True when a QC "details" object fails on lip_sync and on nothing else.
create or replace function m417_internal.only_lip_sync_failed(p_details jsonb)
 returns boolean language sql immutable set search_path to ''
as $function$
    select jsonb_typeof(p_details) = 'object'
       and upper(coalesce(p_details ->> 'lip_sync', '')) = 'FAIL'
       and not exists (
           select 1 from jsonb_each_text(p_details) d
           where d.key <> 'lip_sync' and upper(coalesce(d.value, '')) = 'FAIL');
$function$;

create or replace function m417_internal.safe_numeric(p_text text)
 returns numeric language plpgsql immutable set search_path to ''
as $function$
begin
    if p_text is null or btrim(p_text) = '' then
        return null;
    end if;
    return btrim(p_text)::numeric;
exception when others then
    return null;
end;
$function$;

create or replace function m417_internal.object_size(p_path text)
 returns bigint language sql stable security definer set search_path to ''
as $function$
    select (o.metadata ->> 'size')::bigint
    from storage.objects o
    where o.bucket_id = m417_internal.txt('storage_bucket', 'production-assets')
      and o.name = p_path
    limit 1;
$function$;

create or replace function m417_internal.event(
    p_type text, p_severity text, p_message text,
    p_meta jsonb default '{}'::jsonb,
    p_episode_id uuid default null, p_shot_id uuid default null, p_attempt_id uuid default null)
 returns void language sql security definer set search_path to ''
as $function$
    insert into public.events (event_type, episode_id, shot_id, attempt_id, severity, source, message, metadata)
    values (p_type, p_episode_id, p_shot_id, p_attempt_id, p_severity, 'PIPELINE', p_message, coalesce(p_meta, '{}'::jsonb));
$function$;

create or replace function m417_internal.usage(
    p_job_id uuid, p_service text, p_purpose text,
    p_units numeric default 1, p_unit text default 'call')
 returns void language sql security definer set search_path to ''
as $function$
    insert into public.service_usage (job_id, service, purpose, units, unit)
    values (p_job_id, p_service, p_purpose, coalesce(p_units, 1), p_unit);
$function$;

-- ----- job row -------------------------------------------------------
create or replace function m417_internal.lock_job(p_job_id uuid)
 returns public.production_jobs language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    if p_job_id is null then
        raise exception 'JOB_ID_REQUIRED';
    end if;
    select j.* into v_job
    from public.production_jobs j
    where j.id = p_job_id
    for update;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    return v_job;
end;
$function$;

create or replace function m417_internal.require_step(p_job public.production_jobs, p_step integer)
 returns void language plpgsql stable security definer set search_path to ''
as $function$
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        raise exception 'PIPELINE_DISABLED';
    end if;
    if p_job.state <> 'READY' then
        raise exception 'JOB_NOT_READY: % (%)', p_job.state, coalesce(p_job.blocked_reason, '-');
    end if;
    if p_job.current_step <> p_step then
        raise exception 'STEP_MISMATCH: job is at step %, this call belongs to step %', p_job.current_step, p_step;
    end if;
end;
$function$;

create or replace function m417_internal.set_step(
    p_job_id uuid, p_step integer, p_event text,
    p_detail jsonb default '{}'::jsonb, p_state text default 'READY')
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
    update public.production_jobs
    set current_step = p_step,
        state = p_state,
        blocked_reason = null,
        blocked_detail = null,
        step_claimed_at = null,
        last_activity_at = now(),
        updated_at = now(),
        finished_at = case when p_state in ('DONE', 'CANCELLED') then now() else finished_at end
    where id = p_job_id;
    insert into public.job_step_log (job_id, step_no, event, detail)
    values (p_job_id, p_step, p_event, coalesce(p_detail, '{}'::jsonb));
end;
$function$;

create or replace function m417_internal.block_job(p_job_id uuid, p_reason text, p_detail text default null)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id for update;
    update public.production_jobs
    set state = 'BLOCKED',
        blocked_reason = p_reason,
        blocked_detail = left(p_detail, 2000),
        step_claimed_at = null,
        last_activity_at = now(),
        updated_at = now()
    where id = p_job_id;
    insert into public.job_step_log (job_id, step_no, event, detail)
    values (p_job_id, v_job.current_step, 'BLOCKED',
            jsonb_build_object('reason', p_reason, 'detail', left(p_detail, 2000)));
    perform m417_internal.event(
        'JOB_BLOCKED', 'WARNING',
        'Job blocked at step ' || v_job.current_step || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step, 'reason', p_reason, 'detail', left(p_detail, 2000)),
        v_job.episode_id);
end;
$function$;

create or replace function m417_internal.job_status(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'job_id', j.id,
        'episode_id', j.episode_id,
        'step_no', j.current_step,
        'state', j.state,
        'blocked_reason', coalesce(j.blocked_reason, ''),
        'blocked_detail', coalesce(j.blocked_detail, ''))
    from public.production_jobs j
    where j.id = p_job_id;
$function$;

-- One more revision round, or block when the limit is used up.
-- Creative revisions (Gemini pre-QC, Head Director) and automatic
-- format checks are counted separately.
-- Returns true when the job may continue at p_step.
create or replace function m417_internal.open_revision(
    p_job_id uuid, p_step integer, p_feedback jsonb, p_source text)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
declare
    v_count integer;
    v_max integer;
begin
    if p_source = 'SYSTEM_VALIDATION' then
        v_max := m417_internal.num('max_validation_retries', 2)::integer;
        update public.production_jobs
        set validation_retry_count = validation_retry_count + 1,
            revision_feedback = p_feedback
        where id = p_job_id
        returning validation_retry_count into v_count;
    else
        v_max := m417_internal.num('max_revisions', 2)::integer;
        update public.production_jobs
        set revision_count = revision_count + 1,
            revision_feedback = p_feedback
        where id = p_job_id
        returning revision_count into v_count;
    end if;
    if v_count > v_max then
        perform m417_internal.block_job(
            p_job_id,
            case when p_source = 'SYSTEM_VALIDATION' then 'VALIDATION_RETRY_LIMIT_REACHED'
                 else 'REVISION_LIMIT_REACHED' end,
            'Source: ' || p_source || '. Feedback: ' || coalesce(p_feedback::text, ''));
        return false;
    end if;
    perform m417_internal.set_step(
        p_job_id, p_step, 'REVISION_OPENED',
        jsonb_build_object('source', p_source, 'round', v_count));
    return true;
end;
$function$;

-- ----- artifacts -----------------------------------------------------
create or replace function m417_internal.artifact(p_job_id uuid, p_type text)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select a.content
    from public.job_artifacts a
    where a.job_id = p_job_id
      and a.artifact_type = p_type
      and a.is_current = true;
$function$;

create or replace function m417_internal.artifact_text(p_job_id uuid, p_type text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(m417_internal.artifact(p_job_id, p_type)::text, '');
$function$;

create or replace function m417_internal.retire_artifacts(p_job_id uuid, p_types text[])
 returns void language sql security definer set search_path to ''
as $function$
    update public.job_artifacts
    set is_current = false
    where job_id = p_job_id
      and artifact_type = any (p_types)
      and is_current = true;
$function$;

-- ----- canon lookups -------------------------------------------------
-- Accepts a code (CHR_FATIH), a bare code (FATIH) or a name (Fatih).
create or replace function m417_internal.resolve_character(p_series_id uuid, p_ref text)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select c.id
    from public.characters c
    where c.series_id = p_series_id
      and c.status = 'LOCKED'
      and (
            upper(c.character_code) = upper(btrim(p_ref))
         or upper(c.character_code) = 'CHR_' || upper(btrim(p_ref))
         or lower(c.name) = lower(btrim(p_ref))
         or lower(translate(c.name, 'ÖöÜüİıŞşÇçĞğ', 'OoUuIiSsCcGg'))
            = lower(translate(btrim(p_ref), 'ÖöÜüİıŞşÇçĞğ', 'OoUuIiSsCcGg'))
      )
    order by c.version desc
    limit 1;
$function$;

create or replace function m417_internal.resolve_location(p_series_id uuid, p_ref text)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select l.id
    from public.locations l
    where l.series_id = p_series_id
      and l.status <> 'ARCHIVED'
      and (
            upper(l.location_code) = upper(btrim(p_ref))
         or upper(l.location_code) = 'LOC_' || upper(btrim(p_ref))
         or lower(l.name) = lower(btrim(p_ref))
      )
    order by l.version desc
    limit 1;
$function$;

create or replace function m417_internal.character_voice(p_character_id uuid)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select v.id
    from public.voice_identities v
    where v.character_id = p_character_id
      and v.status = 'LOCKED'
      and v.provider_voice_id is not null
      and btrim(v.provider_voice_id) <> ''
    order by v.version desc
    limit 1;
$function$;

-- Durations the PRIMARY video models of the active routing policy accept.
-- NULL means "no restriction known".
create or replace function m417_internal.allowed_shot_durations()
 returns integer[] language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_result integer[];
    v_model record;
    v_this integer[];
    v_have boolean := false;
begin
    for v_model in
        select gm.min_duration_seconds, gm.max_duration_seconds, gm.capability_metadata
        from public.generation_routing_policies grp
        join public.generation_policy_models gpm
          on gpm.policy_id = grp.id and gpm.enabled = true and gpm.route_role = 'PRIMARY'
        join public.generation_models gm on gm.id = gpm.model_id
        where grp.status = 'ACTIVE'
          and grp.id = (
              select p2.id from public.generation_routing_policies p2
              where p2.status = 'ACTIVE'
              order by p2.approved_at desc nulls last, p2.created_at desc
              limit 1)
    loop
        if jsonb_typeof(v_model.capability_metadata -> 'allowed_durations') = 'array' then
            select array_agg(x::integer order by x::integer) into v_this
            from jsonb_array_elements_text(v_model.capability_metadata -> 'allowed_durations') x;
        elsif v_model.min_duration_seconds is not null
          and v_model.max_duration_seconds is not null then
            select array_agg(g) into v_this
            from generate_series(ceil(v_model.min_duration_seconds)::integer,
                                 floor(v_model.max_duration_seconds)::integer) g;
        else
            continue;
        end if;
        if not v_have then
            v_result := v_this;
            v_have := true;
        else
            select array_agg(distinct u order by u) into v_result
            from unnest(v_result || v_this) u;
        end if;
    end loop;
    return v_result;
end;
$function$;

-- ----- series bible --------------------------------------------------
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
            'max_characters_per_shot', m417_internal.num('max_characters_per_shot', 3)::integer,
            'shot_cast_rule', format(
                'A shot shows at most %s characters; one or two is better. Whoever speaks in a shot is visible in it. Write scenes so that every shot works with that few characters on screen and carries one clear action; the others can be off-screen.',
                m417_internal.num('max_characters_per_shot', 3)::integer),
            'shot_package_rule', 'A shot package always contains every shot of the episode, also when it is a revision; every scene has at least one shot.',
            'video_prompt_rule', 'video_prompt is plain descriptive English for the video model: characters by their plain names, no codes, no asset names, no brackets, no spoken words.',
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

-- ----- script / shot package validation ------------------------------
-- Seconds a voice needs to say a text: characters at the configured
-- speaking rate, the silence around the words, and a pause for every
-- sentence break inside the line. Calibrated on the first real takes
-- (9 Oct 2026): 'Reflexes! Still got it.' ran 2.8-3.8 s.
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

-- Characters of dialogue that fit comfortably into p_seconds.
create or replace function m417_internal.speech_max_chars(p_seconds numeric)
 returns integer language sql stable security definer set search_path to ''
as $function$
    select greatest(0, floor((coalesce(p_seconds, 0) - m417_internal.num('speech_padding_seconds', 0.4))
                             * greatest(m417_internal.num('speech_chars_per_second', 13), 1)))::integer;
$function$;

create or replace function m417_internal.issue(p_target text, p_ref text, p_detail text, p_fix text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    select jsonb_build_object(
        'target', p_target, 'ref', p_ref, 'severity', 'HIGH',
        'detail', p_detail, 'fix', p_fix);
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

-- Finds one dialogue line of the script: first inside the given scene,
-- then anywhere if the line number is unique.
create or replace function m417_internal.script_line(p_script jsonb, p_scene_no text, p_line_no text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    with lines as (
        select coalesce(s.scene ->> 'scene_no', s.idx::text) as scene_no,
               coalesce(l.line ->> 'line_no', l.idx::text) as line_no,
               l.line
        from jsonb_array_elements(p_script -> 'scenes') with ordinality as s(scene, idx)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(s.scene -> 'dialogue') = 'array'
                 then s.scene -> 'dialogue' else '[]'::jsonb end
        ) with ordinality as l(line, idx)
    )
    select coalesce(
        (select x.line || jsonb_build_object('scene_no', x.scene_no, 'line_no', x.line_no)
         from lines x
         where x.scene_no = p_scene_no and x.line_no = p_line_no
         limit 1),
        (select x.line || jsonb_build_object('scene_no', x.scene_no, 'line_no', x.line_no)
         from lines x
         where x.line_no = p_line_no
           and (select count(*) from lines y where y.line_no = p_line_no) = 1
         limit 1));
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
    v_max_cast integer := m417_internal.num('max_characters_per_shot', 3)::integer;
    v_min_prompt integer := m417_internal.num('video_prompt_min_chars', 120)::integer;
    v_prompt text;
    v_cast uuid[];
    v_speaker uuid;
    v_scene record;
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
        -- The video prompt is what the video model reads: it has to be
        -- real description, not a template or a list of codes.
        v_prompt := btrim(coalesce(v_shot ->> 'video_prompt', ''));
        if v_prompt = '' then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'video_prompt is empty.', 'Write the video prompt for this shot.');
        else
            if v_prompt ~ '[<>]' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains angle brackets or a placeholder such as <PROMPT: ...>.',
                    'Write video_prompt as plain descriptive English without brackets or placeholders.');
            end if;
            if v_prompt ~ '\m(CHR|LOC)_[A-Z0-9_]+' or v_prompt ~ '\m[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_V[0-9]+\M' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains codes or asset names; the video model does not understand them.',
                    'Call characters by their plain names (for example Mia) and describe the place in words. Codes belong only in characters, location and reference_assets.');
            end if;
            if char_length(v_prompt) < v_min_prompt then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('video_prompt is only %s characters long; at least %s are needed.', char_length(v_prompt), v_min_prompt),
                    'Describe framing and camera, where each character is, what they do beat by beat, their expressions and body language, the place and the light.');
            end if;
        end if;
        v_cast := array[]::uuid[];
        if jsonb_typeof(v_shot -> 'characters') = 'array' then
            for v_char in select * from jsonb_array_elements_text(v_shot -> 'characters')
            loop
                if m417_internal.resolve_character(v_job.series_id, v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown character: ' || v_char,
                        'Use character codes from the series bible.');
                elsif not (m417_internal.resolve_character(v_job.series_id, v_char) = any (v_cast)) then
                    v_cast := v_cast || m417_internal.resolve_character(v_job.series_id, v_char);
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
                    -- Whoever speaks in a shot is seen in it.
                    v_speaker := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                    if v_speaker is not null and not (v_speaker = any (v_cast)) then
                        v_cast := v_cast || v_speaker;
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref,
                            'Line ' || v_line_no || ' is spoken by ' || (v_line ->> 'character') || ', who is not listed in characters of this shot.',
                            'Add the speaker to characters of this shot, or move the line to a shot of the same scene in which the speaker is visible.');
                    end if;
                end if;
            end loop;
        end if;
        if cardinality(v_cast) > v_max_cast then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                format('%s characters are in this shot; at most %s can be shown.', cardinality(v_cast), v_max_cast),
                format('Show at most %s characters in a shot: frame the ones that matter for this beat and keep the others off-screen, or split the scene into more shots.', v_max_cast));
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
    -- Every scene of the script needs at least one shot: a package is
    -- always the whole episode, also when it is a revision.
    for v_scene in
        select coalesce(sc.scene ->> 'scene_no', sc.idx::text) as scene_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as sc(scene, idx)
        where not exists (
            select 1 from jsonb_array_elements(p_content -> 'shots') sh(value)
            where sh.value ->> 'scene_no' = coalesce(sc.scene ->> 'scene_no', sc.idx::text))
    loop
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'scene ' || v_scene.scene_no,
            'Scene ' || v_scene.scene_no || ' of the script has no shot.',
            'Return the complete shot package: every scene needs at least one shot, and shots that did not change must be included again.');
    end loop;
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
