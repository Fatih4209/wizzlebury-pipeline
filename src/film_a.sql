
-- =====================================================================
-- 10b. Film grammar and the two-yes rule (010)
-- =====================================================================

-- ----- small helpers -------------------------------------------------
create or replace function m417_internal.film_on()
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select m417_internal.flag('film_grammar_enforced', false) is true;
$function$;

-- The eight shot sizes, whatever way the writer spelled them.
create or replace function m417_internal.film_size(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z]+', '_', 'g'), '_')
        when 'EXTREME_WIDE' then 'EXTREME_WIDE'
        when 'EWS' then 'EXTREME_WIDE'
        when 'ESTABLISHING' then 'EXTREME_WIDE'
        when 'WIDE' then 'WIDE'
        when 'WS' then 'WIDE'
        when 'FULL' then 'WIDE'
        when 'MEDIUM' then 'MEDIUM'
        when 'MS' then 'MEDIUM'
        when 'MEDIUM_CLOSE' then 'MEDIUM_CLOSE'
        when 'MEDIUM_CLOSE_UP' then 'MEDIUM_CLOSE'
        when 'MCU' then 'MEDIUM_CLOSE'
        when 'CLOSE_UP' then 'CLOSE_UP'
        when 'CLOSEUP' then 'CLOSE_UP'
        when 'CU' then 'CLOSE_UP'
        when 'EXTREME_CLOSE_UP' then 'EXTREME_CLOSE_UP'
        when 'ECU' then 'EXTREME_CLOSE_UP'
        when 'INSERT' then 'INSERT'
        when 'DETAIL' then 'INSERT'
        when 'OVER_SHOULDER' then 'OVER_SHOULDER'
        when 'OVER_THE_SHOULDER' then 'OVER_SHOULDER'
        when 'OTS' then 'OVER_SHOULDER'
        else null end;
$function$;

-- The framing sentence the video model reads for a shot size.
create or replace function m417_internal.film_size_sentence(p_size text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_size
        when 'EXTREME_WIDE' then 'Extreme wide establishing shot: the whole place is visible and the characters are small in the frame.'
        when 'WIDE' then 'Wide shot: full bodies from head to feet, with the surroundings clearly visible.'
        when 'MEDIUM' then 'Medium shot: framed from the waist up.'
        when 'MEDIUM_CLOSE' then 'Medium close-up: framed from the chest up.'
        when 'CLOSE_UP' then 'Close-up: one face fills the frame.'
        when 'EXTREME_CLOSE_UP' then 'Extreme close-up on a single detail such as the eyes or the hands.'
        when 'INSERT' then 'Insert detail shot: the object fills the frame; no faces.'
        when 'OVER_SHOULDER' then 'Over-the-shoulder shot: the camera looks past the back of one character''s head and shoulder at what is in front of them.'
        else '' end;
$function$;

-- How the speaker of a shot is staged: seen talking, heard from
-- off-screen, or seen from behind.
create or replace function m417_internal.voice_stage(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z]+', '_', 'g'), '_')
        when 'ON_CAMERA' then 'ON_CAMERA'
        when 'ON_SCREEN' then 'ON_CAMERA'
        when 'ONSCREEN' then 'ON_CAMERA'
        when 'VISIBLE' then 'ON_CAMERA'
        when 'WIDE' then 'ON_CAMERA'
        when 'OFF_SCREEN' then 'OFF_SCREEN'
        when 'OFFSCREEN' then 'OFF_SCREEN'
        when 'VOICE_OVER' then 'OFF_SCREEN'
        when 'BACK_TO_CAMERA' then 'BACK_TO_CAMERA'
        when 'BACK' then 'BACK_TO_CAMERA'
        when 'FROM_BEHIND' then 'BACK_TO_CAMERA'
        else null end;
$function$;

-- Longest spoken line (seconds of voice) a single cut can carry.
create or replace function m417_internal.max_line_seconds()
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select m417_internal.num('max_shot_edit_seconds', 4.5)
         - m417_internal.num('edit_voice_lead_seconds', 0.15)
         - m417_internal.num('edit_voice_tail_seconds', 0.35);
$function$;

-- The cut a shot gets: its planned length, made long enough for the
-- voice spoken in it.
create or replace function m417_internal.planned_cut(p_edit numeric, p_voice numeric)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select round(greatest(
        coalesce(p_edit, 0),
        case when coalesce(p_voice, 0) > 0
             then p_voice + m417_internal.num('edit_voice_lead_seconds', 0.15)
                          + m417_internal.num('edit_voice_tail_seconds', 0.35)
             else 0 end), 2);
$function$;

-- Seconds of voice a locked shot can carry in the edit. Shots planned
-- before the film rules keep the old measure: their whole duration.
create or replace function m417_internal.voice_room(p_spec_id uuid)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select case when ss.edit_seconds is null then ss.duration_seconds
           else ss.duration_seconds
                - m417_internal.num('edit_trim_lead_seconds', 0.2)
                - m417_internal.num('edit_voice_lead_seconds', 0.15)
                - m417_internal.num('edit_voice_tail_seconds', 0.35)
                - m417_internal.num('voice_duration_tolerance_seconds', 0.5) end
    from public.shot_specifications ss
    where ss.id = p_spec_id;
$function$;

-- The current script artifact of a job.
create or replace function m417_internal.current_script_id(p_job_id uuid)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select a.id from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SCRIPT' and a.is_current = true;
$function$;

-- Has this voter said YES to the current script, and not NO since?
create or replace function m417_internal.has_yes(p_job_id uuid, p_role text)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select coalesce((
        select v.decision = 'YES'
        from public.script_votes v
        where v.job_id = p_job_id
          and v.voter_role = p_role
          and v.script_artifact_id = m417_internal.current_script_id(p_job_id)
        order by v.created_at desc, v.id desc
        limit 1), false);
$function$;

-- A prop of the script by its name.
create or replace function m417_internal.script_prop(p_script jsonb, p_name text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    select p.value
    from jsonb_array_elements(
        case when jsonb_typeof(p_script -> 'props') = 'array' then p_script -> 'props' else '[]'::jsonb end) p(value)
    where lower(btrim(p.value ->> 'name')) = lower(btrim(coalesce(p_name, '')))
    limit 1;
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
    v_format jsonb;
    v_film boolean := m417_internal.film_on();
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
               'look_notes', (
                   select v.wardrobe_note
                   from public.asset_registry ar
                   join public.video_reference_images v on v.asset_id = ar.id and v.is_active = true
                   where ar.character_id = c.id and coalesce(btrim(v.wardrobe_note), '') <> ''
                   order by ar.version desc
                   limit 1),
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

    v_format := jsonb_build_object(
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
        'quality_rules', v_profile.quality_rules);

    -- Under the film rules an episode is a planned edit: every shot is
    -- generated at a fixed length and the edit uses a cut out of it.
    if v_film then
        v_format := (v_format - 'total_duration_seconds_min' - 'total_duration_seconds_target_max'
                              - 'total_duration_seconds_hard_max' - 'shot_duration_rule' - 'shot_cast_rule')
            || jsonb_build_object(
                'episode_seconds_min', m417_internal.num('episode_min_seconds', 10),
                'episode_seconds_max', m417_internal.num('episode_max_seconds', 18),
                'shots_min', m417_internal.num('min_shots', 5)::integer,
                'shots_max', m417_internal.num('max_shots', 7)::integer,
                'cut_seconds_min', m417_internal.num('min_shot_edit_seconds', 0.8),
                'cut_seconds_max', m417_internal.num('max_shot_edit_seconds', 4.5),
                'hook_cut_seconds_max', m417_internal.num('hook_max_seconds', 2.5),
                'dialogue_lines_max', m417_internal.num('max_dialogue_lines', 4)::integer,
                'dialogue_line_chars_max', m417_internal.speech_max_chars(m417_internal.max_line_seconds()),
                'shot_sizes', jsonb_build_array('EXTREME_WIDE', 'WIDE', 'MEDIUM', 'MEDIUM_CLOSE', 'CLOSE_UP',
                                                'EXTREME_CLOSE_UP', 'INSERT', 'OVER_SHOULDER'),
                'voice_stagings', jsonb_build_array('ON_CAMERA', 'OFF_SCREEN', 'BACK_TO_CAMERA'),
                'shot_duration_rule', 'duration_seconds is the length the video model generates and must be one of allowed_shot_durations_seconds (use the shortest). edit_seconds is the cut the edit uses from the start of that clip, to one decimal place. The episode length is the sum of the cuts.',
                'edit_rule', 'An episode is a sequence of cuts. No two neighbouring shots have the same shot_size. At least three different sizes are used. One of the first three shots is WIDE or EXTREME_WIDE so the viewer knows where we are. At least one shot is a CLOSE_UP, EXTREME_CLOSE_UP or INSERT. The first cut is the hook.',
                'voice_rule', case when m417_internal.flag('speaker_closeup_allowed', false)
                    then 'Dialogue is cut shot by shot: at most one line is spoken in a shot, and a conversation is a chain of shots, each on the speaker or on the listener. voice_staging says how the speaker is staged: ON_CAMERA (seen talking), OFF_SCREEN (not in the shot; we watch the listener or an object) or BACK_TO_CAMERA (seen from behind).'
                    else 'Dialogue is cut shot by shot: at most one line is spoken in a shot, and a conversation is a chain of shots, each on the speaker or on the listener. voice_staging says how the speaker is staged: ON_CAMERA (seen talking, in a MEDIUM_CLOSE, MEDIUM, WIDE or EXTREME_WIDE shot), OFF_SCREEN (not in the shot; we watch the listener or an object) or BACK_TO_CAMERA (seen from behind, typically OVER_SHOULDER). Exact lip-sync is not produced yet, so nobody speaks in a CLOSE_UP or EXTREME_CLOSE_UP: those are silent looks, reactions and laughs.' end,
                'shot_cast_rule', format(
                    'A shot shows at most %s characters; one or two is better. Every shot carries one clear action.',
                    m417_internal.num('max_characters_per_shot', 3)::integer),
                'wardrobe_rule', 'The script fixes one outfit per character for the whole episode, chosen for the place and the activity, modest and suitable for a child, with no logos, brands or text. Each character has a distinct look and colour. look_notes of a character always hold.',
                'prop_rule', 'Every object that matters is a prop of the script with an exact description: colour, size, material, count. It looks the same in every shot.',
                -- Written for one-event micro shorts; a planned edit tells a small story.
                'creative_rules', v_profile.creative_rules - 'single_primary_event' - 'unnecessary_scene_changes_forbidden');
    end if;

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
        'format', v_format,
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

-- ----- script validation --------------------------------------------
create or replace function m417_internal.validate_script(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_issues jsonb := '[]'::jsonb;
    v_scene jsonb;
    v_line jsonb;
    v_item jsonb;
    v_scene_no text;
    v_total numeric := 0;
    v_dur numeric;
    v_char uuid;
    v_scene_idx integer := 0;
    v_speech numeric;
    v_one numeric;
    v_lines integer := 0;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
    v_film boolean := m417_internal.film_on();
    v_min numeric := 6;
    v_max numeric := 15;
    v_cast uuid[] := array[]::uuid[];
    v_dressed uuid[] := array[]::uuid[];
    v_name text;
    v_names text[] := array[]::text[];
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if v_film then
        v_min := m417_internal.num('episode_min_seconds', 10);
        v_max := m417_internal.num('episode_max_seconds', 18);
    end if;
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
        if v_film then
            if coalesce(btrim(v_scene ->> 'location'), '') = '' then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no, 'The scene has no location.',
                    'Give every scene a location code from the series bible.');
            end if;
            if char_length(btrim(coalesce(v_scene ->> 'action', ''))) < 60 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no,
                    'action is missing or too thin to film.',
                    'Describe in at least 60 characters who is where, what exactly happens in order, and what causes what.');
            end if;
            if jsonb_typeof(v_scene -> 'characters') is distinct from 'array' then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no, 'The scene has no characters array.',
                    'List the codes of every character seen or heard in the scene in characters.');
            else
                for v_name in select * from jsonb_array_elements_text(v_scene -> 'characters')
                loop
                    v_char := m417_internal.resolve_character(v_job.series_id, v_name);
                    if v_char is null then
                        v_issues := v_issues || m417_internal.issue(
                            'SCRIPT', 'scene ' || v_scene_no, 'Unknown character: ' || v_name,
                            'Use character codes from the series bible.');
                    elsif not (v_char = any (v_cast)) then
                        v_cast := v_cast || v_char;
                    end if;
                end loop;
            end if;
        end if;
        v_speech := 0;
        if jsonb_typeof(v_scene -> 'dialogue') = 'array' then
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
                v_lines := v_lines + 1;
                v_one := m417_internal.speech_seconds(v_line ->> 'text');
                v_speech := v_speech + v_one;
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
                if v_film then
                    if v_char is not null and not (v_char = any (v_cast)) then
                        v_cast := v_cast || v_char;
                    end if;
                    -- One line is spoken inside one cut.
                    if v_one > m417_internal.max_line_seconds() then
                        v_issues := v_issues || m417_internal.issue(
                            'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                            format('This line takes about %s s to say; a line is spoken inside one cut and may take at most %s s.',
                                   v_one, m417_internal.max_line_seconds()),
                            format('Shorten the line to one short sentence of at most %s characters (spaces included).',
                                   m417_internal.speech_max_chars(m417_internal.max_line_seconds())));
                    end if;
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
    if v_total < v_min or v_total > v_max then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'total duration',
            format('Scene durations add up to %s seconds; the episode must be %s to %s seconds.', v_total, v_min, v_max),
            format('Adjust scene durations so the total is between %s and %s seconds.', v_min, v_max));
    end if;
    if not v_film then
        return v_issues;
    end if;

    -- Film rules: the script fixes everything the shots depend on.
    if char_length(btrim(coalesce(p_content ->> 'hook', ''))) < 40 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'hook', 'hook is missing or too short.',
            'In hook, describe in at least 40 characters exactly what the viewer sees and hears in the first two seconds and why they keep watching.');
    end if;
    if char_length(btrim(coalesce(p_content ->> 'payoff', ''))) < 30 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'payoff', 'payoff is missing or too short.',
            'In payoff, describe in at least 30 characters the final image or gag the episode ends on.');
    end if;
    if char_length(btrim(coalesce(p_content ->> 'look', ''))) < 20 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'look', 'look is missing or too short.',
            'In look, state the time of day, the weather and the light; it is the same in every shot.');
    end if;
    if v_lines > m417_internal.num('max_dialogue_lines', 4) then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'dialogue',
            format('The script has %s spoken lines; at most %s are allowed.', v_lines, m417_internal.num('max_dialogue_lines', 4)::integer),
            'Tell the story with pictures; keep only the lines that carry the joke.');
    end if;
    if jsonb_typeof(p_content -> 'wardrobe') is distinct from 'array' then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'wardrobe', 'The script has no wardrobe array.',
            'Add wardrobe: one entry {character, outfit} for every character of the episode.');
    else
        for v_item in select * from jsonb_array_elements(p_content -> 'wardrobe')
        loop
            v_char := m417_internal.resolve_character(v_job.series_id, v_item ->> 'character');
            if v_char is null then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'wardrobe', 'Unknown character in wardrobe: ' || coalesce(v_item ->> 'character', '(empty)'),
                    'Use character codes from the series bible.');
            elsif char_length(btrim(coalesce(v_item ->> 'outfit', ''))) < 25 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'wardrobe', 'The outfit of ' || (v_item ->> 'character') || ' is missing or too vague.',
                    'Describe the outfit in at least 25 characters: garments, colours, shoes, anything worn or carried.');
            else
                v_dressed := v_dressed || v_char;
            end if;
        end loop;
    end if;
    for v_name in
        select c.character_code from public.characters c
        where c.id = any (v_cast) and not (c.id = any (v_dressed))
        order by c.character_code
    loop
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'wardrobe', v_name || ' appears in the episode but has no outfit in wardrobe.',
            'Add a wardrobe entry for ' || v_name || '.');
    end loop;
    if jsonb_typeof(p_content -> 'props') is distinct from 'array' then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'props', 'The script has no props array.',
            'Add props: one entry {name, description} for every object that matters (an empty array when there is none).');
    else
        for v_item in select * from jsonb_array_elements(p_content -> 'props')
        loop
            v_name := lower(btrim(coalesce(v_item ->> 'name', '')));
            if v_name = '' or char_length(btrim(coalesce(v_item ->> 'description', ''))) < 20 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'props', 'A prop has no name or its description is too vague: ' || coalesce(nullif(v_name, ''), '(no name)'),
                    'Give every prop a short name and a description of at least 20 characters with colour, size and exact count.');
            elsif v_name = any (v_names) then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'props', 'Two props share the name ' || v_name || '.',
                    'Give every prop its own name.');
            else
                v_names := v_names || v_name;
            end if;
        end loop;
    end if;
    return v_issues;
end;
$function$;

-- ----- shot package validation ---------------------------------------
create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_script jsonb;
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_beat jsonb;
    v_idx integer := 0;
    v_ref text;
    v_dur numeric;
    v_edit numeric;
    v_cut numeric;
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
    v_film boolean := m417_internal.film_on();
    v_min numeric := 6;
    v_max numeric := 15;
    v_max_shots integer := 6;
    v_size text;
    v_prev_size text;
    v_sizes text[] := array[]::text[];
    v_stage text;
    v_line_count integer;
    v_at numeric;
    v_prev_at numeric;
    v_beats integer;
    v_prop text;
    v_trim numeric := m417_internal.num('edit_trim_lead_seconds', 0.2);
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    v_script := m417_internal.artifact(p_job_id, 'SCRIPT');
    if v_film then
        v_min := m417_internal.num('episode_min_seconds', 10);
        v_max := m417_internal.num('episode_max_seconds', 18);
        v_max_shots := m417_internal.num('max_shots', 7)::integer;
        v_min_prompt := m417_internal.num('film_video_prompt_min_chars', 200)::integer;
    end if;
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array'
       or jsonb_array_length(p_content -> 'shots') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SHOTS', 'shots', 'The shot package has no shots array.',
            'Return the shot package in the required JSON shape with at least one shot.'));
    end if;
    if jsonb_array_length(p_content -> 'shots') > v_max_shots then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots', format('More than %s shots.', v_max_shots), format('Use at most %s shots.', v_max_shots));
    end if;
    if v_film and jsonb_array_length(p_content -> 'shots') < m417_internal.num('min_shots', 5) then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots',
            format('Only %s shots; an episode is cut from at least %s.', jsonb_array_length(p_content -> 'shots'), m417_internal.num('min_shots', 5)::integer),
            'Break the action into more shots: establish the place, show the action, cut to reactions and details.');
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
            if not v_film then
                v_total := v_total + v_dur;
            end if;
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

        v_size := m417_internal.film_size(v_shot ->> 'shot_size');
        v_stage := m417_internal.voice_stage(v_shot ->> 'voice_staging');
        v_speech := 0;
        v_line_count := 0;
        if jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array' then
            for v_line_no in select * from jsonb_array_elements_text(v_shot -> 'dialogue_line_nos')
            loop
                v_line_count := v_line_count + 1;
                v_line := m417_internal.script_line(v_script, v_shot ->> 'scene_no', v_line_no);
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if v_line is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref,
                        'dialogue_line_nos refers to line ' || v_line_no || ', which is not in scene ' || coalesce(v_shot ->> 'scene_no', '?') || ' of the script.',
                        'Reference only line numbers that exist in the script scene of this shot.');
                else
                    v_assigned := v_assigned || ((v_line ->> 'scene_no') || ':' || (v_line ->> 'line_no'));
                    v_speaker := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                    if not v_film then
                        -- Whoever speaks in a shot is seen in it.
                        if v_speaker is not null and not (v_speaker = any (v_cast)) then
                            v_cast := v_cast || v_speaker;
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'Line ' || v_line_no || ' is spoken by ' || (v_line ->> 'character') || ', who is not listed in characters of this shot.',
                                'Add the speaker to characters of this shot, or move the line to a shot of the same scene in which the speaker is visible.');
                        end if;
                    elsif v_speaker is not null then
                        -- The speaker's mouth is never seen.
                        if v_stage is null then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'A line is spoken in this shot but voice_staging is missing or unknown.',
                                'Set voice_staging to ON_CAMERA, OFF_SCREEN or BACK_TO_CAMERA. See voice_rule.');
                        elsif v_stage = 'OFF_SCREEN' and v_speaker = any (v_cast) then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging is OFF_SCREEN but the speaker ' || (v_line ->> 'character') || ' is listed in characters.',
                                'Take the speaker out of characters and show the listener or an object, or use ON_CAMERA or BACK_TO_CAMERA.');
                        elsif v_stage in ('BACK_TO_CAMERA', 'ON_CAMERA') and not (v_speaker = any (v_cast)) then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging is ' || v_stage || ' but the speaker ' || (v_line ->> 'character') || ' is not listed in characters.',
                                'Add the speaker to characters, or use OFF_SCREEN.');
                        elsif v_stage = 'ON_CAMERA' and v_size in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT')
                              and m417_internal.flag('speaker_closeup_allowed', false) is not true then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'A line is spoken ON_CAMERA in a ' || v_size || ' shot; exact lip-sync is not produced yet, so nobody speaks in a close shot.',
                                'Frame the speaker MEDIUM_CLOSE or wider, or keep the close shot on the listener and stage the line OFF_SCREEN.');
                        elsif v_stage = 'BACK_TO_CAMERA' and v_size in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT') then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging BACK_TO_CAMERA does not work in a ' || v_size || ' shot.',
                                'Use OVER_SHOULDER, MEDIUM or WIDE for a speaker seen from behind, or stage the line OFF_SCREEN.');
                        end if;
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

        if not v_film then
            if v_dur is not null and v_dur >= 1 and v_speech > v_dur + v_tol then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The lines spoken in this shot take about %s s to say, but the shot lasts %s s.', v_speech, v_dur),
                    format('Give this shot at least %s s (an allowed duration), or move one of its lines to a neighbouring shot of the same scene. Do not change the script text.',
                           ceil(v_speech - v_tol)));
            end if;
            continue;
        end if;

        -- Film rules for one shot ------------------------------------
        if v_size is null then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'shot_size is missing or unknown: ' || coalesce(v_shot ->> 'shot_size', '(empty)'),
                'Set shot_size to one of shot_sizes in the series bible.');
        else
            if v_prev_size is not null and v_prev_size = v_size then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'This shot has the same shot_size (' || v_size || ') as the shot before it.',
                    'Change the size of one of the two: a cut needs a clear change of framing.');
            end if;
            v_sizes := v_sizes || v_size;
        end if;
        v_prev_size := v_size;
        if v_line_count > 1 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, format('%s lines are spoken in this shot; at most one is allowed.', v_line_count),
                'Give every spoken line its own shot.');
        end if;
        v_edit := m417_internal.safe_numeric(v_shot ->> 'edit_seconds');
        if v_edit is null
           or v_edit < m417_internal.num('min_shot_edit_seconds', 0.8)
           or v_edit > m417_internal.num('max_shot_edit_seconds', 4.5)
        then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                'edit_seconds is missing or outside the allowed cut length: ' || coalesce(v_shot ->> 'edit_seconds', '(empty)'),
                format('Give the shot an edit_seconds between %s and %s.',
                       m417_internal.num('min_shot_edit_seconds', 0.8), m417_internal.num('max_shot_edit_seconds', 4.5)));
        else
            v_cut := m417_internal.planned_cut(v_edit, v_speech);
            if v_dur is not null and v_cut > v_dur - v_trim then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The cut needs %s s but the generated clip gives only %s s.', v_cut, v_dur - v_trim),
                    'Shorten edit_seconds, or move the spoken line to another shot.');
            end if;
            if v_idx = 1 and v_cut > m417_internal.num('hook_max_seconds', 2.5) then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The first cut lasts %s s; the hook must be over in %s s.', v_cut, m417_internal.num('hook_max_seconds', 2.5)),
                    'Open on the most striking image of the episode in a short cut; a line spoken in it must be a word or two.');
            end if;
            v_total := v_total + v_cut;
            -- Timed beats: what happens when inside the cut.
            v_beats := 0;
            v_prev_at := null;
            if jsonb_typeof(v_shot -> 'beats') = 'array' then
                for v_beat in select * from jsonb_array_elements(v_shot -> 'beats')
                loop
                    v_beats := v_beats + 1;
                    v_at := m417_internal.safe_numeric(v_beat ->> 'at');
                    if v_at is null or v_at < 0 or v_at >= v_cut
                       or (v_prev_at is not null and v_at <= v_prev_at)
                       or (v_beats = 1 and v_at <> 0)
                    then
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref, format('Beat %s has a wrong time: %s.', v_beats, coalesce(v_beat ->> 'at', '(empty)')),
                            'Beat times are seconds from the start of the cut: the first is 0, each later one is larger, all are inside the cut.');
                    end if;
                    v_prev_at := coalesce(v_at, v_prev_at);
                    if char_length(btrim(coalesce(v_beat ->> 'what', ''))) < m417_internal.num('min_beat_chars', 15) then
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref, format('Beat %s does not say what happens.', v_beats),
                            'In what, say exactly who does what at that moment.');
                    end if;
                end loop;
            end if;
            if v_beats = 0 then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'The shot has no beats.',
                    'Add beats: [{at, what}] - at least one, the first at 0 - timing the action inside the cut to a tenth of a second.');
            end if;
        end if;
        if jsonb_typeof(v_shot -> 'props') = 'array' then
            for v_prop in select * from jsonb_array_elements_text(v_shot -> 'props')
            loop
                if m417_internal.script_prop(v_script, v_prop) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown prop: ' || v_prop,
                        'List in props only names from props of the script.');
                end if;
            end loop;
        end if;
    end loop;

    if v_film then
        if (select count(distinct s) from unnest(v_sizes) s) < 3 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'Fewer than three different shot sizes are used.',
                'Vary the framing: wide to show the place, medium for action, close for reactions and details.');
        end if;
        if not exists (select 1 from unnest(v_sizes[1:3]) s where s in ('WIDE', 'EXTREME_WIDE')) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'None of the first three shots is WIDE or EXTREME_WIDE.',
                'Show where we are early: make one of the first three shots a wide view of the place.');
        end if;
        if not exists (select 1 from unnest(v_sizes) s where s in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT')) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'No close shot is used.',
                'Add at least one CLOSE_UP, EXTREME_CLOSE_UP or INSERT: a face reacting or the detail that matters.');
        end if;
    end if;
    if v_total < v_min or v_total > v_max then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'total duration',
            case when v_film
                 then format('The cuts add up to %s seconds; the episode must be %s to %s seconds.', v_total, v_min, v_max)
                 else 'Shot durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.' end,
            case when v_film
                 then format('Change the number of shots or their edit_seconds so the total is between %s and %s seconds. A shot with a spoken line lasts at least as long as the line plus half a second.', v_min, v_max)
                 else 'Change the number of shots or their durations so the total is between 6 and 15 seconds.' end);
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
