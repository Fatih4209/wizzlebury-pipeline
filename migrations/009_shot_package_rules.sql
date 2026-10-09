-- =====================================================================
-- M417 / WIZZLEBURY  -  009 shot package rules
--
-- Run after 008. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- Why: on 9 Oct 2026 the shot writer handed in one shot for a two-scene
-- script three times, with a template left in the video prompt.
--
-- 1. A shot package is refused, with a clear instruction to the writer,
--    when a scene has no shot, when a video prompt contains brackets,
--    codes or asset names or is too short, when more than 3 characters
--    are in a shot, or when a speaker is not in the shot.
-- 2. The series bible tells both writers these rules.
-- 3. A clean script or shot package resets the count of failed format
--    checks, so a later review round starts with a fresh allowance.
-- 4. The stored generation prompt is ordered scene, action, acting,
--    camera, framing, style, location, characters: when it has to be
--    cut, the written character descriptions (already covered by the
--    reference images) go first.
-- =====================================================================
begin;

do $$
begin
    if to_regclass('public.video_reference_images') is null then
        raise exception 'M417_008_NOT_FOUND: apply 008_kling_omni_refs.sql first';
    end if;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('max_characters_per_shot', 3, 'Characters that may be shown in one shot; each needs a reference image.'),
    ('video_prompt_min_chars', 120, 'Shortest video prompt the shot writer may hand in.')
on conflict (key) do nothing;

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

create or replace function m417_internal.compose_prompt(
    p_series_id uuid, p_shot jsonb, p_character_ids uuid[], p_location_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_parts text[] := array[]::text[];
    v_text text;
    v_n integer := coalesce(cardinality(p_character_ids), 0);
begin
    -- What happens comes first, the look of the series next, and the
    -- written character descriptions last: when the text has to be cut
    -- for a model that also receives reference images, those go first.
    v_parts := v_parts || left(btrim(coalesce(p_shot ->> 'video_prompt', '')), 900);
    if coalesce(btrim(p_shot ->> 'action'), '') <> '' then
        v_parts := v_parts || ('Action: ' || left(btrim(p_shot ->> 'action'), 250));
    end if;
    if coalesce(btrim(p_shot ->> 'acting'), '') <> '' then
        v_parts := v_parts || ('Acting: ' || left(btrim(p_shot ->> 'acting'), 200));
    end if;
    if coalesce(btrim(p_shot ->> 'camera'), '') <> '' then
        v_parts := v_parts || ('Camera: ' || left(btrim(p_shot ->> 'camera'), 150));
    end if;
    v_parts := v_parts || 'Vertical 9:16 framing. No on-screen text, subtitles, logos or watermarks.'::text;
    select left(coalesce(sb.visual_style, ''), 260) into v_text
    from public.style_bibles sb
    where sb.series_id = p_series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 200) into v_text
    from public.locations l where l.id = p_location_id;
    if v_text is not null then
        v_parts := v_parts || ('Location. ' || v_text);
    end if;
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''),
                                             case when v_n > 2 then 150 else 230 end),
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

create or replace function public.save_artifact(
    p_job_id uuid, p_artifact_type text, p_producer text, p_content jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_type text := upper(btrim(coalesce(p_artifact_type, '')));
    v_producer text := upper(btrim(coalesce(p_producer, '')));
    v_step integer;
    v_owner text;
    v_issues jsonb := '[]'::jsonb;
    v_version integer;
    v_artifact_id uuid;
    v_verdict text;
    v_continue boolean;
begin
    select x.step, x.owner into v_step, v_owner
    from (values
        ('TREND_REPORT', 6, 'GROK'),
        ('TOPIC_SELECTION', 7, 'CLAUDE'),
        ('SCRIPT', 10, 'CLAUDE'),
        ('SHOT_PACKAGE', 11, 'OPENAI'),
        ('PREQC_REPORT', 12, 'GEMINI'),
        ('MUSIC_SFX_PLAN', 19, 'CLAUDE'),
        ('METADATA_CANDIDATES', 36, 'GROK')
    ) as x(atype, step, owner)
    where x.atype = v_type;
    if not found then
        raise exception 'ARTIFACT_TYPE_NOT_ACCEPTED: %', v_type;
    end if;
    if v_producer <> v_owner then
        raise exception 'PRODUCER_NOT_AUTHORIZED: % may not write %', v_producer, v_type;
    end if;
    if p_content is null or jsonb_typeof(p_content) <> 'object' then
        raise exception 'ARTIFACT_CONTENT_MUST_BE_JSON_OBJECT';
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, v_step);

    -- Shape checks that cannot be repaired by another round stop here.
    if v_type = 'TOPIC_SELECTION'
       and (coalesce(btrim(p_content ->> 'title'), '') = '' or coalesce(btrim(p_content ->> 'premise'), '') = '')
    then
        raise exception 'TOPIC_SELECTION_INCOMPLETE: title and premise are required';
    end if;
    if v_type = 'PREQC_REPORT' then
        v_verdict := upper(btrim(coalesce(p_content ->> 'verdict', '')));
        if v_verdict not in ('PASS', 'REVISE_SCRIPT', 'REVISE_SHOTS') then
            raise exception 'PREQC_VERDICT_INVALID: %', coalesce(p_content ->> 'verdict', '(empty)');
        end if;
    end if;
    if v_type = 'MUSIC_SFX_PLAN' and jsonb_typeof(p_content -> 'tracks') is distinct from 'array' then
        raise exception 'MUSIC_PLAN_TRACKS_MUST_BE_ARRAY';
    end if;
    if v_type = 'METADATA_CANDIDATES'
       and (jsonb_typeof(p_content -> 'candidates') is distinct from 'array'
            or jsonb_array_length(p_content -> 'candidates') = 0)
    then
        raise exception 'METADATA_CANDIDATES_REQUIRED';
    end if;

    -- Problems the writer can fix go back to the writer.
    if v_type = 'SCRIPT' then
        v_issues := m417_internal.validate_script(p_job_id, p_content);
    elsif v_type = 'SHOT_PACKAGE' then
        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
    end if;

    -- A new script makes the old shots and review stale; new shots make
    -- the old review stale.
    if v_type = 'SCRIPT' then
        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT']);
    elsif v_type = 'SHOT_PACKAGE' then
        perform m417_internal.retire_artifacts(p_job_id, array['PREQC_REPORT']);
    end if;
    perform m417_internal.retire_artifacts(p_job_id, array[v_type]);

    select coalesce(max(a.version), 0) + 1 into v_version
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = v_type;

    insert into public.job_artifacts (job_id, artifact_type, producer, version, content, validation_issues)
    values (p_job_id, v_type, v_producer, v_version, p_content, v_issues)
    returning id into v_artifact_id;

    perform m417_internal.usage(p_job_id, v_producer, v_type);

    if jsonb_array_length(v_issues) > 0 then
        v_continue := m417_internal.open_revision(
            p_job_id, v_step,
            jsonb_build_object(
                'verdict', case v_type when 'SCRIPT' then 'REVISE_SCRIPT' else 'REVISE_SHOTS' end,
                'source', 'SYSTEM_VALIDATION',
                'issues', v_issues),
            'SYSTEM_VALIDATION');
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                                  'accepted', false, 'issues', v_issues);
    end if;

    -- A clean script or shot package closes the feedback that asked for
    -- it, and the count of failed format checks starts again.
    if v_type in ('SCRIPT', 'SHOT_PACKAGE') then
        update public.production_jobs
        set revision_feedback = null,
            validation_retry_count = 0
        where id = p_job_id;
    end if;
    if v_type = 'TOPIC_SELECTION' then
        update public.episodes
        set title = left(p_content ->> 'title', 200),
            concept = p_content ->> 'premise'
        where id = v_job.episode_id;
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'ARTIFACT_SAVED',
        jsonb_build_object('artifact_type', v_type, 'version', v_version, 'artifact_id', v_artifact_id));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                              'accepted', true, 'issues', '[]'::jsonb);
end;
$function$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_009_APPLIED', 'INFO', 'CONTROL_PLANE', 'Shot package rules (009) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
