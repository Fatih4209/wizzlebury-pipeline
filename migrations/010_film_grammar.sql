-- =====================================================================
-- M417 / WIZZLEBURY  -  010 film grammar and the two-yes rule
--
-- Run after 009. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. Two-yes rule. The Assistant Director (OpenAI) scores the script and
--    votes YES or NO in the answer that carries the shots; a NO sends
--    the script back to the Head Director (Claude) with the reasons, and
--    after repeated NOs the topic is dropped. The Head Director's final
--    approval is the second YES. Without both, nothing is committed, so
--    no voice and no video is paid for.
-- 2. Film rules. A script fixes hook, payoff, look, one outfit per
--    character and every prop. A shot package is a planned edit: shot
--    sizes, cut lengths to a tenth of a second, timed beats, one spoken
--    line per shot and how its speaker is staged.
-- 3. The edit uses a cut out of every generated clip, long enough for
--    the voice spoken in it; voices can no longer overlap.
-- 4. Every shot prompt carries wardrobe, props and look in identical
--    words; a rejected take tells the next one what to avoid.
-- 5. The instructions for topic, script, shots, pre-QC and final
--    decision live in the database (step_prompts) and are handed to
--    Make as prompt_text.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.validate_shot_package(uuid,jsonb)') is null
       or not exists (select 1 from public.system_settings where key = 'video_prompt_min_chars')
    then
        raise exception 'M417_009_NOT_FOUND: apply 009_shot_package_rules.sql first';
    end if;
end $$;

-- =====================================================================
-- 1b. Film grammar, two-yes rule, prompts kept in the database (010)
-- =====================================================================

-- What the edit uses of a generated clip, and how the shot is staged.
alter table public.shot_specifications
    add column if not exists beats jsonb not null default '[]'::jsonb,
    add column if not exists props jsonb not null default '[]'::jsonb,
    add column if not exists edit_seconds numeric,
    add column if not exists film_size text,
    add column if not exists shot_purpose text,
    add column if not exists voice_staging text,
    add column if not exists qc_brief jsonb;

alter table public.video_reference_images
    add column if not exists wardrobe_note text;

alter table public.production_jobs
    add column if not exists script_no_count integer not null default 0;

alter table public.job_artifacts drop constraint if exists job_artifacts_type_check;
alter table public.job_artifacts add constraint job_artifacts_type_check check (artifact_type in (
    'TREND_REPORT', 'TOPIC_SELECTION', 'SCRIPT', 'SCRIPT_REVIEW', 'SHOT_PACKAGE', 'PREQC_REPORT',
    'MUSIC_SFX_PLAN', 'FINAL_QC_REPORT', 'METADATA_CANDIDATES', 'THUMBNAIL'));

-- One row per vote on a script: the Assistant Director (OpenAI) votes on
-- the Head Director's script, the Head Director (Claude) on the finished
-- package. Nothing is produced without a YES from both.
create table if not exists public.script_votes (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    script_artifact_id uuid not null references public.job_artifacts(id) on delete restrict,
    voter text not null,
    voter_role text not null,
    decision text not null,
    stated_decision text,
    scores jsonb not null default '{}'::jsonb,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint script_votes_voter_check check (voter in ('CLAUDE', 'OPENAI')),
    constraint script_votes_role_check check (voter_role in ('HEAD_DIRECTOR', 'ASSISTANT_DIRECTOR')),
    constraint script_votes_decision_check check (decision in ('YES', 'NO'))
);
create index if not exists idx_script_votes_job on public.script_votes (job_id, created_at);
create index if not exists idx_script_votes_artifact on public.script_votes (script_artifact_id);
alter table public.script_votes enable row level security;

-- The instructions the writers and reviewers receive. Make sends the
-- text the database hands out, so a change of wording is a change here.
-- Placeholders: [[BIBLE]] [[REQUEST]] [[TOPIC]] [[SCRIPT]] [[SHOT_PACKAGE]]
-- [[FEEDBACK]] [[ASSISTANT_REVIEW]] [[PREQC_REPORT]] [[LIMITS]].
create table if not exists public.step_prompts (
    prompt_code text not null,
    version integer not null,
    is_active boolean not null default true,
    body text not null,
    note text,
    created_at timestamptz not null default now(),
    constraint step_prompts_pkey primary key (prompt_code, version),
    constraint step_prompts_version_check check (version > 0)
);
create unique index if not exists uq_step_prompts_active
    on public.step_prompts (prompt_code) where (is_active = true);
alter table public.step_prompts enable row level security;

do $$
declare
    v_role text;
begin
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.script_votes from %I', v_role);
            execute format('revoke all on public.step_prompts from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.system_flags (key, value, description) values
    ('film_grammar_enforced', true, 'Scripts and shot packages must follow the film rules: hook, wardrobe, props, planned shot sizes, cut lengths, one speaker per shot.'),
    ('speaker_closeup_allowed', false, 'May a character speak in a close-up? Off until exact lip-sync is produced.'),
    ('assistant_vote_required', true, 'Two-yes rule: the Assistant Director (OpenAI) must vote YES on the script and the Head Director (Claude) YES on the package before anything is produced.')
on conflict (key) do nothing;

insert into public.system_settings (key, value_numeric, description) values
    ('episode_min_seconds', 10, 'Shortest finished episode (sum of the cut lengths).'),
    ('episode_max_seconds', 18, 'Longest finished episode (sum of the cut lengths).'),
    ('min_shots', 5, 'Fewest shots in an episode.'),
    ('max_shots', 7, 'Most shots in an episode; every shot is one paid generation.'),
    ('min_shot_edit_seconds', 0.8, 'Shortest cut.'),
    ('max_shot_edit_seconds', 4.5, 'Longest cut.'),
    ('hook_max_seconds', 2.5, 'The first cut may not be longer than this.'),
    ('max_dialogue_lines', 6, 'Most spoken lines in an episode.'),
    ('edit_voice_lead_seconds', 0.15, 'A voice starts this long after its cut begins.'),
    ('edit_voice_tail_seconds', 0.35, 'A cut lasts at least this long after its voice ends.'),
    ('edit_trim_lead_seconds', 0.2, 'The edit skips this much at the start of every generated clip.'),
    ('script_vote_min_score', 7, 'A YES from the Assistant Director counts only when every score is at least this (1-10).'),
    ('max_script_rejections', 2, 'Times the Assistant Director may send a script back before the topic is dropped.'),
    ('film_video_prompt_min_chars', 200, 'Shortest shot description under the film rules.'),
    ('min_beat_chars', 15, 'Shortest description of one timed beat inside a shot.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('cast_rule_text', 'All the children are the same age and the same height, with the same child body proportions; nobody is taller or looks older than the others.', 'Sentence added to every shot with characters.')
on conflict (key) do nothing;

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

-- ----- two-yes rule --------------------------------------------------
-- The Assistant Director said NO to the script. The script goes back to
-- the Head Director with the reasons; after too many rounds the topic
-- itself is dropped and a new one is chosen.
create or replace function m417_internal.script_rejected(p_job_id uuid, p_vote jsonb, p_stated text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_round integer;
    v_retries integer;
    v_feedback jsonb;
    v_episode uuid;
begin
    update public.production_jobs
    set script_no_count = script_no_count + 1
    where id = p_job_id
    returning script_no_count, episode_id into v_round, v_episode;

    v_feedback := jsonb_build_object(
        'verdict', 'REVISE_SCRIPT',
        'source', 'ASSISTANT_DIRECTOR',
        'vote', 'NO',
        'stated_vote', p_stated,
        'minimum_score', m417_internal.num('script_vote_min_score', 7),
        'scores', coalesce(p_vote -> 'scores', '{}'::jsonb),
        'strengths', coalesce(p_vote -> 'strengths', '[]'::jsonb),
        'problems', coalesce(p_vote -> 'problems', '[]'::jsonb),
        'required_changes', coalesce(p_vote -> 'required_changes', '[]'::jsonb),
        'note', case when p_stated = 'YES'
                     then 'The Assistant Director said YES, but a score is below the minimum, so the vote counts as NO. Raise the weak scores.'
                     else 'The Assistant Director voted NO. Rewrite the script so that every required change is met.' end);

    if v_round > m417_internal.num('max_script_rejections', 2) then
        update public.production_jobs
        set topic_retry_count = topic_retry_count + 1,
            topic_feedback = coalesce(topic_feedback, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'topic', m417_internal.artifact(p_job_id, 'TOPIC_SELECTION') -> 'title',
                'findings', coalesce(p_vote -> 'problems', '[]'::jsonb),
                'required_changes', jsonb_build_array(
                    'The Head Director and the Assistant Director could not agree on a script for this topic. Choose a different idea that is easier to tell in pictures.'))),
            revision_feedback = null,
            revision_count = 0,
            validation_retry_count = 0,
            script_no_count = 0
        where id = p_job_id
        returning topic_retry_count into v_retries;
        perform m417_internal.retire_artifacts(
            p_job_id, array['SCRIPT', 'SHOT_PACKAGE', 'PREQC_REPORT', 'SCRIPT_REVIEW']);
        perform m417_internal.event(
            'TOPIC_DROPPED_NO_AGREEMENT', 'WARNING',
            'The Assistant Director rejected the script too often; the topic is dropped.',
            jsonb_build_object('job_id', p_job_id, 'rounds', v_round, 'topic_retry', v_retries), v_episode);
        if v_retries > m417_internal.num('max_topic_retries', 2) then
            update public.production_jobs set current_step = 7 where id = p_job_id;
            perform m417_internal.block_job(p_job_id, 'SCRIPT_NOT_AGREED', v_feedback::text);
        else
            perform m417_internal.set_step(
                p_job_id, 7, 'TOPIC_DROPPED_NO_AGREEMENT', jsonb_build_object('retry_no', v_retries));
        end if;
    else
        update public.production_jobs
        set revision_feedback = v_feedback,
            validation_retry_count = 0
        where id = p_job_id;
        perform m417_internal.set_step(
            p_job_id, 10, 'REVISION_OPENED',
            jsonb_build_object('source', 'ASSISTANT_DIRECTOR', 'round', v_round));
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('accepted', false, 'script_vote', 'NO', 'issues', '[]'::jsonb);
end;
$function$;

-- Both votes of the current script, for the owner's overview.
create or replace function m417_internal.two_yes(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'assistant_director', m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR'),
        'head_director', m417_internal.has_yes(p_job_id, 'HEAD_DIRECTOR'));
$function$;

-- ----- instructions kept in the database -----------------------------
-- The instruction for the model that works on this step, with the
-- material of the job filled in. Empty when the step has none here.
create or replace function m417_internal.step_prompt(
    p_job_id uuid, p_step integer, p_request text, p_feedback text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_code text := case p_step
        when 7 then 'TOPIC' when 10 then 'SCRIPT' when 11 then 'SHOT_PACKAGE'
        when 12 then 'PREQC' when 14 then 'DIRECTOR'
        when 31 then 'FINAL_QC' when 32 then 'FINAL_QC' end;
    v_body text;
    v_plan text := '[]';
    v_total text := '0';
    v_durations integer[] := m417_internal.allowed_shot_durations();
    v_last_no text;
    v_pair record;
begin
    if v_code is null then
        return '';
    end if;
    select sp.body into v_body
    from public.step_prompts sp
    where sp.prompt_code = v_code and sp.is_active = true;
    if v_body is null then
        return '';
    end if;

    select v.result::text into v_last_no
    from public.script_votes v
    where v.job_id = p_job_id and v.voter_role = 'ASSISTANT_DIRECTOR' and v.decision = 'NO'
      and exists (select 1 from public.job_artifacts a
                  where a.id = v.script_artifact_id
                    and a.created_at >= coalesce((
                        select max(t.created_at) from public.job_artifacts t
                        where t.job_id = p_job_id and t.artifact_type = 'TOPIC_SELECTION' and t.is_current), '-infinity'))
    order by v.created_at desc
    limit 1;

    -- The finished edit, cut by cut, for the reviewer of the final video.
    if v_code = 'FINAL_QC' then
        select coalesce(jsonb_agg(jsonb_build_object(
                   'cut', e.value ->> 'shot_code',
                   'starts_at', e.value -> 'start',
                   'seconds', e.value -> 'length',
                   'shot_size', ss.film_size,
                   'spoken_line', ss.dialogue,
                   'speaker_staging', ss.voice_staging,
                   'action', left(ss.narrative_action, 160))
                   order by (e.value ->> 'start')::numeric), '[]'::jsonb)::text,
               coalesce(sum((e.value ->> 'length')::numeric), 0)::text
        into v_plan, v_total
        from jsonb_array_elements(m417_internal.edit_list(p_job_id) -> 'shots') e(value)
        join public.production_jobs j on j.id = p_job_id
        join public.shots s on s.episode_id = j.episode_id and s.shot_code = e.value ->> 'shot_code'
        join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true;
    end if;

    for v_pair in
        select * from (values
            ('[[EDIT_PLAN]]', coalesce(v_plan, '[]')),
            ('[[TOTAL_SECONDS]]', coalesce(v_total, '0')),
            ('[[EP_MIN]]', m417_internal.num('episode_min_seconds', 10)::text),
            ('[[EP_MAX]]', m417_internal.num('episode_max_seconds', 18)::text),
            ('[[SHOTS_MIN]]', m417_internal.num('min_shots', 5)::integer::text),
            ('[[SHOTS_MAX]]', m417_internal.num('max_shots', 7)::integer::text),
            ('[[CUT_MIN]]', m417_internal.num('min_shot_edit_seconds', 0.8)::text),
            ('[[CUT_MAX]]', m417_internal.num('max_shot_edit_seconds', 4.5)::text),
            ('[[HOOK_MAX]]', m417_internal.num('hook_max_seconds', 2.5)::text),
            ('[[LINES_MAX]]', m417_internal.num('max_dialogue_lines', 4)::integer::text),
            ('[[LINE_CHARS]]', m417_internal.speech_max_chars(m417_internal.max_line_seconds())::text),
            ('[[GEN_SECONDS]]', coalesce(v_durations[1], 5)::text),
            ('[[MIN_SCORE]]', m417_internal.num('script_vote_min_score', 7)::integer::text),
            ('[[PROMPT_MIN]]', m417_internal.num('film_video_prompt_min_chars', 200)::integer::text),
            ('[[MAX_CAST]]', m417_internal.num('max_characters_per_shot', 3)::integer::text),
            ('[[BIBLE]]', m417_internal.series_bible(p_job_id)::text),
            ('[[REQUEST]]', coalesce(nullif(p_request, ''), '{}')),
            ('[[TRENDS]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'TREND_REPORT'), ''), 'none')),
            ('[[TOPIC]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'TOPIC_SELECTION'), ''), 'none')),
            ('[[SCRIPT]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SCRIPT'), ''), 'none')),
            ('[[SHOT_PACKAGE]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SHOT_PACKAGE'), ''), 'none')),
            ('[[ASSISTANT_REVIEW]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SCRIPT_REVIEW'), ''), 'none')),
            ('[[PREQC_REPORT]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'PREQC_REPORT'), ''), 'none')),
            ('[[LAST_REJECTION]]', coalesce(v_last_no, 'none')),
            ('[[FEEDBACK]]', coalesce(nullif(p_feedback, ''), 'none'))
        ) as x(token, val)
    loop
        v_body := replace(v_body, v_pair.token, v_pair.val);
    end loop;
    return v_body;
end;
$function$;

-- ----- functions changed for the film rules and the two-yes rule -----

create or replace function public.get_job_context(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_request jsonb;
    v_preqc text;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;

    v_request := v_job.request;
    if v_job.topic_feedback is not null then
        v_request := v_request || jsonb_build_object('rejected_topics', v_job.topic_feedback);
    end if;

    -- While a revision is open the writer sees the feedback that opened
    -- it; afterwards the reviewers see the real pre-QC report.
    if v_job.current_step in (10, 11) and v_job.revision_feedback is not null then
        v_preqc := v_job.revision_feedback::text;
    else
        v_preqc := m417_internal.artifact_text(p_job_id, 'PREQC_REPORT');
    end if;

    return jsonb_build_object(
        'job_id', v_job.id,
        'step_no', v_job.current_step,
        'series_bible_text', m417_internal.series_bible(p_job_id)::text,
        'request_text', v_request::text,
        'trend_report_text', m417_internal.artifact_text(p_job_id, 'TREND_REPORT'),
        'topic_selection_text', m417_internal.artifact_text(p_job_id, 'TOPIC_SELECTION'),
        'script_text', m417_internal.artifact_text(p_job_id, 'SCRIPT'),
        'shot_package_text', m417_internal.artifact_text(p_job_id, 'SHOT_PACKAGE'),
        'preqc_report_text', v_preqc,
        'assistant_review_text', m417_internal.artifact_text(p_job_id, 'SCRIPT_REVIEW'),
        'two_yes_text', m417_internal.two_yes(p_job_id)::text,
        'prompt_text', m417_internal.step_prompt(p_job_id, v_job.current_step, v_request::text, v_preqc),
        'music_library_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'track_code', mt.track_code, 'title', mt.title, 'role', mt.role,
                       'mood', mt.mood, 'duration_seconds', mt.duration_seconds)
                       order by mt.track_code), '[]'::jsonb)::text
            from public.music_tracks mt
            where mt.is_active = true and mt.license_status = 'VERIFIED'),
        -- The accepted verdict only: the reviewer's raw verdict and the
        -- system note read as a contradiction to the policy gate.
        'final_qc_report_text', coalesce((
            select ((r.qc_result - 'reviewer_verdict' - 'system_note' - 'overruled')
                    || case when r.qc_result ? 'system_note'
                            then jsonb_build_object('lip_sync_policy',
                                 'Lip-sync is not produced in this version by owner decision; lip-sync findings are informational and do not affect the verdict.')
                            else '{}'::jsonb end)::text
            from public.renders r
            where r.job_id = p_job_id and r.qc_result is not null
            order by r.render_no desc
            limit 1), ''),
        'policy_checks_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'gate_no', pc.gate_no, 'verdict', pc.verdict, 'checker', pc.checker,
                       'findings', pc.result -> 'findings', 'notes', pc.result -> 'notes')
                       order by pc.created_at), '[]'::jsonb)::text
            -- The check in force per gate: a repeated gate replaces its
            -- earlier result instead of contradicting it.
            from (
                select distinct on (x.gate_no) x.*
                from public.policy_checks x
                where x.job_id = p_job_id
                order by x.gate_no, x.created_at desc
            ) pc),
        'metadata_candidates_text', m417_internal.artifact_text(p_job_id, 'METADATA_CANDIDATES'));
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
    v_vote jsonb;
    v_stated text;
    v_decision text;
    v_low numeric;
    v_scored integer;
    v_vote_issue jsonb;
    v_script_id uuid;
    v_review_version integer;
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

    -- Two-yes rule, first vote: the Assistant Director votes on the
    -- script in the same answer that carries the shots.
    if v_type = 'SHOT_PACKAGE' and m417_internal.flag('assistant_vote_required', false) then
        v_vote := p_content -> 'script_vote';
        v_stated := upper(btrim(coalesce(v_vote ->> 'decision', '')));
        v_script_id := m417_internal.current_script_id(p_job_id);
        if v_script_id is null then
            raise exception 'SCRIPT_MISSING';
        end if;
        select min(m417_internal.safe_numeric(s.value)),
               count(*) filter (where m417_internal.safe_numeric(s.value) is not null)
        into v_low, v_scored
        from jsonb_each_text(case when jsonb_typeof(v_vote -> 'scores') = 'object'
                                  then v_vote -> 'scores' else '{}'::jsonb end) s(key, value);
        if jsonb_typeof(v_vote) is distinct from 'object' or v_stated not in ('YES', 'NO') then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'script_vote is missing, or its decision is not YES or NO.',
                'Return script_vote {decision, scores, strengths, problems, required_changes} together with the shots.');
        elsif v_stated = 'YES' and v_scored < 5 then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'A YES needs the five scores: hook, story, humor, dialogue, filmability (1 to 10).',
                'Return all five scores in script_vote.scores.');
        else
            v_decision := case when v_stated = 'YES'
                                    and v_low >= m417_internal.num('script_vote_min_score', 7)
                               then 'YES' else 'NO' end;
            insert into public.script_votes (
                job_id, script_artifact_id, voter, voter_role, decision, stated_decision, scores, result)
            values (
                p_job_id, v_script_id, 'OPENAI', 'ASSISTANT_DIRECTOR', v_decision, v_stated,
                case when jsonb_typeof(v_vote -> 'scores') = 'object' then v_vote -> 'scores' else '{}'::jsonb end,
                v_vote);
            perform m417_internal.retire_artifacts(p_job_id, array['SCRIPT_REVIEW']);
            select coalesce(max(a.version), 0) + 1 into v_review_version
            from public.job_artifacts a
            where a.job_id = p_job_id and a.artifact_type = 'SCRIPT_REVIEW';
            insert into public.job_artifacts (job_id, artifact_type, producer, version, content)
            values (p_job_id, 'SCRIPT_REVIEW', 'OPENAI', v_review_version,
                    v_vote || jsonb_build_object('decision', v_decision, 'stated_decision', v_stated));
            if v_decision = 'NO' then
                perform m417_internal.usage(p_job_id, 'OPENAI', 'SCRIPT_REVIEW');
                return m417_internal.script_rejected(p_job_id, v_vote, v_stated)
                    || jsonb_build_object('version', v_review_version);
            end if;
        end if;
    end if;

    -- Problems the writer can fix go back to the writer.
    if v_type = 'SCRIPT' then
        v_issues := m417_internal.validate_script(p_job_id, p_content);
    elsif v_type = 'SHOT_PACKAGE' then
        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
        if v_vote_issue is not null then
            v_issues := jsonb_build_array(v_vote_issue) || v_issues;
        end if;
    end if;

    -- A new script makes the old shots and review stale; new shots make
    -- the old review stale.
    if v_type = 'SCRIPT' then
        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT', 'SCRIPT_REVIEW']);
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
        -- A new topic starts with a clean count of script rejections.
        update public.production_jobs set script_no_count = 0 where id = p_job_id;
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'ARTIFACT_SAVED',
        jsonb_build_object('artifact_type', v_type, 'version', v_version, 'artifact_id', v_artifact_id));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                              'accepted', true, 'issues', '[]'::jsonb);
end;
$function$;

create or replace function public.record_final_director_decision(
    p_job_id uuid, p_actor text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_decision text;
    v_version integer;
    v_decision_id uuid;
    v_feedback jsonb;
    v_ok boolean;
begin
    if upper(btrim(coalesce(p_actor, ''))) <> 'CLAUDE' then
        raise exception 'DIRECTOR_NOT_AUTHORIZED: %', coalesce(p_actor, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'DIRECTOR_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_decision := upper(btrim(coalesce(p_result ->> 'decision', '')));
    if v_decision not in ('APPROVE', 'REVISE_SCRIPT', 'REVISE_SHOTS', 'REJECT') then
        raise exception 'DIRECTOR_DECISION_INVALID: %', coalesce(p_result ->> 'decision', '(empty)');
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 14);

    -- An approval that contradicts the reviews is not accepted as one.
    if v_decision = 'APPROVE' then
        if upper(coalesce(m417_internal.artifact(p_job_id, 'PREQC_REPORT') ->> 'verdict', '')) <> 'PASS' then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_PREQC_PASS';
        end if;
        if not exists (
            select 1 from public.policy_checks pc
            where pc.job_id = p_job_id and pc.gate_no = 1 and pc.verdict = 'PASS')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_POLICY_GATE_1';
        end if;
        if upper(coalesce(p_result ->> 'child_safety_status', 'PASS')) = 'FAIL'
           or coalesce(p_result ->> 'production_ready', 'true') = 'false'
        then
            raise exception 'DIRECTOR_APPROVAL_CONTRADICTS_ITS_OWN_FINDINGS';
        end if;
        -- Two-yes rule: the Assistant Director's YES comes first.
        if m417_internal.flag('assistant_vote_required', false)
           and not m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_ASSISTANT_YES';
        end if;
    end if;

    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;

    insert into public.director_decisions (
        job_id, episode_id, production_version, stage, decision, actor, notes, result)
    values (
        p_job_id, v_job.episode_id, v_version, 'PRODUCTION', v_decision, 'CLAUDE',
        p_result ->> 'director_notes', p_result)
    returning id into v_decision_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');
    -- Two-yes rule, second vote.
    if m417_internal.current_script_id(p_job_id) is not null then
        insert into public.script_votes (
            job_id, script_artifact_id, voter, voter_role, decision, stated_decision, result)
        values (
            p_job_id, m417_internal.current_script_id(p_job_id), 'CLAUDE', 'HEAD_DIRECTOR',
            case when v_decision = 'APPROVE' then 'YES' else 'NO' end, v_decision, p_result);
    end if;

    if v_decision = 'APPROVE' then
        update public.production_jobs
        set director_decision_id = v_decision_id, revision_feedback = null
        where id = p_job_id;
        perform m417_internal.set_step(
            p_job_id, 15, 'DIRECTOR_APPROVED', jsonb_build_object('decision_id', v_decision_id));
    elsif v_decision = 'REJECT' then
        update public.episodes set state = 'CANCELLED' where id = v_job.episode_id;
        update public.budgets set is_active = false
        where budget_type = 'EPISODE' and reference_id = v_job.episode_id;
        perform m417_internal.set_step(
            p_job_id, 14, 'DIRECTOR_REJECTED',
            jsonb_build_object('decision_id', v_decision_id, 'notes', p_result ->> 'director_notes'),
            'CANCELLED');
        perform m417_internal.event(
            'JOB_REJECTED_BY_DIRECTOR', 'WARNING', 'Head Director rejected the production package.',
            jsonb_build_object('job_id', p_job_id, 'decision_id', v_decision_id), v_job.episode_id);
    else
        v_feedback := jsonb_build_object(
            'verdict', v_decision,
            'source', 'HEAD_DIRECTOR',
            'director_notes', p_result -> 'director_notes',
            'issues', coalesce((
                select jsonb_agg(m417_internal.issue(
                    case v_decision when 'REVISE_SCRIPT' then 'SCRIPT' else 'SHOTS' end,
                    'director', c.value, c.value))
                from jsonb_array_elements_text(
                    case when jsonb_typeof(p_result -> 'required_changes') = 'array'
                         then p_result -> 'required_changes' else '[]'::jsonb end) c(value)), '[]'::jsonb));
        v_ok := m417_internal.open_revision(
            p_job_id, case v_decision when 'REVISE_SCRIPT' then 10 else 11 end,
            v_feedback, 'HEAD_DIRECTOR');
    end if;

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', v_decision, 'decision_id', v_decision_id);
end;
$function$;

create or replace function public.commit_production_package(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_episode public.episodes;
    v_decision public.director_decisions;
    v_script jsonb;
    v_pkg jsonb;
    v_shot_budget numeric;
    v_resolution text := m417_internal.txt('default_shot_resolution', '720p');
    v_voice_provider text := m417_internal.txt('voice_provider', 'fish_audio');
    v_profile public.production_creative_profiles;
    v_scene record;
    v_scene_ids jsonb := '{}'::jsonb;
    v_scene_locations jsonb := '{}'::jsonb;
    v_scene_id uuid;
    v_loc_id uuid;
    v_rec record;
    v_shot jsonb;
    v_idx integer := 0;
    v_shot_id uuid;
    v_spec_id uuid;
    v_first_shot_id uuid;
    v_char_ids uuid[];
    v_char_codes jsonb;
    v_asset_ids uuid[];
    v_asset_roles text[];
    v_asset_codes jsonb;
    v_asset record;
    v_lines jsonb;
    v_line record;
    v_char_id uuid;
    v_voice_id uuid;
    v_voice_language text;
    v_camera text;
    v_negative text;
    v_style_negative text;
    v_duration numeric;
    v_line_total integer := 0;
    v_manifest_id uuid;
    v_i integer;
    v_edit numeric;
    v_cut numeric;
    v_speaker_id uuid;
    v_stage text;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 15);

    if m417_internal.flag('storyboard_required', true) then
        perform m417_internal.block_job(
            p_job_id, 'STORYBOARD_REQUIRED',
            'storyboard_required is on, but this pipeline has no storyboard step.');
        return m417_internal.job_status(p_job_id);
    end if;

    select d.* into v_decision
    from public.director_decisions d
    where d.id = v_job.director_decision_id
      and d.job_id = p_job_id
      and d.stage = 'PRODUCTION'
      and d.decision = 'APPROVE';
    if not found then
        raise exception 'DIRECTOR_APPROVAL_MISSING';
    end if;
    -- Two-yes rule: nothing is produced without a YES from both.
    if m417_internal.flag('assistant_vote_required', false)
       and not (m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
                and m417_internal.has_yes(p_job_id, 'HEAD_DIRECTOR'))
    then
        raise exception 'TWO_YES_REQUIRED: %', m417_internal.two_yes(p_job_id)::text;
    end if;

    select e.* into v_episode from public.episodes e where e.id = v_job.episode_id for update;
    if v_episode.state <> 'PREPRODUCTION' then
        raise exception 'EPISODE_NOT_IN_PREPRODUCTION: %', v_episode.state;
    end if;
    if v_decision.production_version <> v_episode.production_version then
        raise exception 'DIRECTOR_APPROVAL_VERSION_STALE';
    end if;
    select p.* into v_profile
    from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select a.content into v_script
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SCRIPT' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    select a.content into v_pkg
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SHOT_PACKAGE' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    if v_script is null or v_pkg is null then
        raise exception 'VALID_SCRIPT_AND_SHOT_PACKAGE_REQUIRED';
    end if;

    v_shot_budget := m417_internal.safe_numeric(v_job.request ->> 'shot_budget_usd');

    select array_to_string(array(
               select jsonb_array_elements_text(sb.negative_rules)), ', ')
    into v_style_negative
    from public.style_bibles sb
    where sb.series_id = v_job.series_id and sb.status <> 'ARCHIVED'
      and jsonb_typeof(sb.negative_rules) = 'array'
    order by sb.version desc
    limit 1;

    update public.episodes
    set title = left(coalesce(nullif(btrim(v_script ->> 'title'), ''), title), 200),
        concept = coalesce(nullif(btrim(v_script ->> 'logline'), ''), concept),
        director_approval_id = v_decision.id
    where id = v_episode.id;

    -- Scenes ---------------------------------------------------------
    for v_scene in
        select s.scene, s.idx
        from jsonb_array_elements(v_script -> 'scenes') with ordinality as s(scene, idx)
    loop
        v_loc_id := m417_internal.resolve_location(v_job.series_id, v_scene.scene ->> 'location');
        insert into public.scenes (
            episode_id, scene_code, scene_order, title, description, location_id,
            estimated_duration_seconds, state)
        values (
            v_episode.id, 'SC' || lpad(v_scene.idx::text, 2, '0'), v_scene.idx,
            left(v_scene.scene ->> 'action', 120), v_scene.scene ->> 'action', v_loc_id,
            m417_internal.safe_numeric(v_scene.scene ->> 'duration_seconds'), 'SCRIPTED')
        returning id into v_scene_id;
        v_scene_ids := v_scene_ids
            || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_scene_id);
        if v_loc_id is not null then
            v_scene_locations := v_scene_locations
                || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_loc_id);
        end if;
    end loop;

    -- Shots ----------------------------------------------------------
    for v_rec in
        select t.elem
        from jsonb_array_elements(v_pkg -> 'shots') with ordinality as t(elem, ord)
        order by coalesce(m417_internal.safe_numeric(t.elem ->> 'shot_no'), t.ord), t.ord
    loop
        v_shot := v_rec.elem;
        v_idx := v_idx + 1;
        v_scene_id := (v_scene_ids ->> coalesce(v_shot ->> 'scene_no', ''))::uuid;
        v_duration := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');

        -- A film shot carries its cut length and the staging of its line.
        v_edit := case when m417_internal.film_on()
                       then m417_internal.safe_numeric(v_shot ->> 'edit_seconds') end;
        v_stage := case when v_edit is not null then m417_internal.voice_stage(v_shot ->> 'voice_staging') end;

        -- Who is in the shot: listed characters plus everyone who speaks
        -- (a speaker staged off-screen is heard, not seen).
        v_lines := coalesce((
            select jsonb_agg(m417_internal.script_line(v_script, v_shot ->> 'scene_no', n.line_no) order by n.ord)
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array'
                     then v_shot -> 'dialogue_line_nos' else '[]'::jsonb end
            ) with ordinality as n(line_no, ord)), '[]'::jsonb);

        select coalesce(array_agg(distinct x.id), array[]::uuid[]) into v_char_ids
        from (
            select m417_internal.resolve_character(v_job.series_id, c.value) as id
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'characters') = 'array'
                     then v_shot -> 'characters' else '[]'::jsonb end) c(value)
            union
            select m417_internal.resolve_character(v_job.series_id, l.value ->> 'character')
            from jsonb_array_elements(v_lines) l(value)
            where v_stage is distinct from 'OFF_SCREEN'
        ) x
        where x.id is not null;

        v_speaker_id := m417_internal.resolve_character(v_job.series_id, v_lines -> 0 ->> 'character');
        v_cut := case when v_edit is not null then m417_internal.planned_cut(v_edit, (
                     select coalesce(sum(m417_internal.speech_seconds(l.value ->> 'text')), 0)
                     from jsonb_array_elements(v_lines) l(value))) end;

        select coalesce(jsonb_agg(c.character_code order by c.character_code), '[]'::jsonb)
        into v_char_codes
        from public.characters c where c.id = any (v_char_ids);

        v_loc_id := coalesce(
            m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location'),
            (v_scene_locations ->> coalesce(v_shot ->> 'scene_no', ''))::uuid);

        -- Canonical references: one per character, then the location
        -- master, at most three in total.
        v_asset_ids := array[]::uuid[];
        v_asset_roles := array[]::text[];
        for v_asset in
            select x.asset_id, x.role
            from (
                select (
                           select ar.id from public.asset_registry ar
                           where ar.character_id = c.id
                             and ar.asset_type = 'CHARACTER_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by ar.version desc, ar.asset_code
                           limit 1) as asset_id,
                       'CHARACTER'::text as role, 1 as grp, c.character_code as ord
                from public.characters c
                where c.id = any (v_char_ids)
                union all
                select (
                           select ar.id from public.asset_registry ar
                           where ar.location_id = v_loc_id
                             and ar.asset_type = 'LOCATION_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by (ar.metadata ->> 'asset_role' = 'MASTER') desc nulls last,
                                    ar.version desc, ar.asset_code
                           limit 1),
                       'LOCATION', 2, ''
            ) x
            where x.asset_id is not null
            order by x.grp, x.ord
            limit 3
        loop
            v_asset_ids := v_asset_ids || v_asset.asset_id;
            v_asset_roles := v_asset_roles || v_asset.role;
        end loop;
        select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
        into v_asset_codes
        from public.asset_registry ar where ar.id = any (v_asset_ids);

        insert into public.shots (episode_id, shot_code, shot_order, state, maximum_budget, scene_id)
        values (v_episode.id, 'SH' || lpad(v_idx::text, 2, '0'), v_idx, 'PLANNED', v_shot_budget, v_scene_id)
        returning id into v_shot_id;
        if v_first_shot_id is null then
            v_first_shot_id := v_shot_id;
        end if;

        insert into public.budgets (budget_type, reference_id, currency, hard_limit, is_active)
        values ('SHOT', v_shot_id, 'USD', v_shot_budget, true);

        v_camera := lower(coalesce(v_shot ->> 'camera', ''));
        v_negative := left(btrim(concat_ws(', ',
            nullif(btrim(v_shot ->> 'negative_prompt'), ''),
            nullif(v_style_negative, ''),
            'text, subtitles, watermark, logo')), 900);

        insert into public.shot_specifications (
            shot_id, version, is_active, narrative_action, dialogue, emotion, shot_size,
            camera_movement, duration_seconds, generation_prompt, negative_prompt,
            aspect_ratio, fps, resolution, character_codes, required_asset_codes,
            continuity_notes, audio_required, voice_required, status,
            edit_seconds, film_size, shot_purpose, voice_staging, beats, props, qc_brief)
        values (
            v_shot_id, 1, true,
            coalesce(nullif(btrim(v_shot ->> 'action'), ''), left(v_shot ->> 'video_prompt', 500)),
            nullif((select string_agg((l.value ->> 'character') || ': ' || (l.value ->> 'text'), ' / ')
                    from jsonb_array_elements(v_lines) l(value)), ''),
            nullif(btrim(v_shot ->> 'acting'), ''),
            case
                when v_edit is not null and m417_internal.film_size(v_shot ->> 'shot_size') is not null
                    then m417_internal.film_size(v_shot ->> 'shot_size')
                when v_camera ~ '(extreme close|close[- ]?up|closeup)' then 'CLOSE_UP'
                when v_camera ~ '(wide|establishing|long shot|full shot)' then 'WIDE'
                else 'MEDIUM'
            end,
            nullif(btrim(v_shot ->> 'camera'), ''),
            v_duration,
            case when v_edit is not null
                 then m417_internal.compose_shot_prompt(
                          v_job.series_id, v_script, v_shot, v_char_ids, v_loc_id, v_speaker_id, v_cut)
                 else m417_internal.compose_prompt(v_job.series_id, v_shot, v_char_ids, v_loc_id) end,
            v_negative,
            v_profile.aspect_ratio, 24, v_resolution, v_char_codes, v_asset_codes,
            nullif(btrim(v_shot ->> 'continuity_notes'), ''),
            false, jsonb_array_length(v_lines) > 0, 'DRAFT',
            v_edit,
            case when v_edit is not null then m417_internal.film_size(v_shot ->> 'shot_size') end,
            case when v_edit is not null then nullif(upper(btrim(v_shot ->> 'purpose')), '') end,
            case when jsonb_array_length(v_lines) > 0 then v_stage end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'beats') = 'array'
                 then v_shot -> 'beats' else '[]'::jsonb end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'props') = 'array'
                 then v_shot -> 'props' else '[]'::jsonb end,
            case when v_edit is not null
                 then m417_internal.shot_qc_brief(v_job.series_id, v_script, v_shot, v_char_ids, v_speaker_id, v_cut) end)
        returning id into v_spec_id;

        for v_i in 1 .. coalesce(array_length(v_asset_ids, 1), 0)
        loop
            insert into public.shot_reference_assets (
                shot_specification_id, asset_id, reference_role, reference_order, is_required)
            values (v_spec_id, v_asset_ids[v_i], v_asset_roles[v_i], v_i, true);
        end loop;

        -- Locked on the strength of the director decision.
        perform set_config('m417.director_lock', 'on', true);
        update public.shot_specifications set status = 'LOCKED' where id = v_spec_id;
        perform set_config('m417.director_lock', 'off', true);

        -- One planned voice take per dialogue line.
        for v_line in
            select l.value, l.ord
            from jsonb_array_elements(v_lines) with ordinality as l(value, ord)
        loop
            v_char_id := m417_internal.resolve_character(v_job.series_id, v_line.value ->> 'character');
            v_voice_id := m417_internal.character_voice(v_char_id);
            if v_char_id is null or v_voice_id is null then
                raise exception 'DIALOGUE_CHARACTER_HAS_NO_LOCKED_VOICE: %',
                    coalesce(v_line.value ->> 'character', '(empty)');
            end if;
            select vi.language into v_voice_language
            from public.voice_identities vi where vi.id = v_voice_id;
            insert into public.shot_audio_productions (
                shot_specification_id, character_id, voice_identity_id, audio_order,
                dialogue_text, language, provider, lip_sync_required, lip_sync_status,
                timing_metadata, status, take_no)
            values (
                v_spec_id, v_char_id, v_voice_id, v_line.ord,
                m417_internal.clean(v_line.value ->> 'text'), v_voice_language, v_voice_provider,
                false, 'NOT_REQUIRED',
                jsonb_build_object(
                    'scene_no', v_line.value ->> 'scene_no',
                    'line_no', v_line.value ->> 'line_no',
                    'emotion', v_line.value ->> 'emotion',
                    'estimated_seconds', v_line.value ->> 'estimated_seconds'),
                'PLANNED', 1);
            v_line_total := v_line_total + 1;
        end loop;

        -- No storyboard step: the storyboard stage is passed, not skipped
        -- silently, so the state machine and the event log both show it.
        update public.shots set state = 'STORYBOARD_PENDING' where id = v_shot_id;
        update public.shots set state = 'STORYBOARD_APPROVED' where id = v_shot_id;
    end loop;

    -- Manifest -------------------------------------------------------
    insert into public.production_manifests (
        episode_id, production_version, manifest_code, status, pilot_shot_id, director_approval_id)
    values (
        v_episode.id, v_episode.production_version,
        v_episode.content_id || '-M' || v_episode.production_version,
        'DRAFT', v_first_shot_id, v_decision.id)
    returning id into v_manifest_id;

    insert into public.production_manifest_shots (manifest_id, shot_id, shot_specification_id, manifest_order)
    select v_manifest_id, s.id, ss.id, s.shot_order
    from public.shots s
    join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
    where s.episode_id = v_episode.id
    order by s.shot_order;

    perform set_config('m417.director_lock', 'on', true);
    update public.production_manifests set status = 'LOCKED' where id = v_manifest_id;
    perform set_config('m417.director_lock', 'off', true);

    -- Episode: approved by the director decision, then authorised.
    update public.episodes set state = 'APPROVED' where id = v_episode.id;
    perform public.authorize_episode_production(v_episode.id);

    perform m417_internal.event(
        'PRODUCTION_PACKAGE_COMMITTED', 'INFO',
        'Production package committed on Head Director decision; storyboard stage waived.',
        jsonb_build_object('job_id', p_job_id, 'director_decision_id', v_decision.id,
                           'manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total,
                           'storyboard_required', false),
        v_episode.id);

    perform m417_internal.set_step(
        p_job_id, case when v_line_total > 0 then 16 else 19 end, 'PRODUCTION_PACKAGE_COMMITTED',
        jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total));

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total);
end;
$function$;

create or replace function m417_internal.judge_voice_take(p_take_id uuid, p_score numeric, p_forced_fail text)
 returns text language plpgsql security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_reason text := p_forced_fail;
    v_size bigint;
begin
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id for update;
    if not found then
        raise exception 'VOICE_TAKE_NOT_FOUND';
    end if;
    if v_take.status = 'APPROVED' then
        return 'PASS';
    elsif v_take.status = 'REJECTED' then
        return 'FAIL';
    elsif v_take.status not in ('GENERATED', 'QC_PENDING') then
        raise exception 'VOICE_TAKE_NOT_READY_FOR_QC: %', v_take.status;
    end if;

    -- Room for voice in the cut of this shot (the whole shot for shots
    -- planned before the film rules).
    v_spec_duration := m417_internal.voice_room(v_take.shot_specification_id);
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_size := coalesce((v_take.timing_metadata ->> 'file_size_bytes')::bigint, 0);

    if v_reason is null and v_size < m417_internal.num('min_audio_bytes', 2000) then
        v_reason := 'AUDIO_FILE_TOO_SMALL';
    end if;
    if v_reason is null
       and v_other + v_take.duration_seconds
           > v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5)
    then
        v_reason := format('DIALOGUE_LONGER_THAN_SHOT: %s s of dialogue in a %s s shot',
                           round(v_other + v_take.duration_seconds, 2), v_spec_duration);
    end if;

    if v_reason is null then
        update public.shot_audio_productions
        set status = 'APPROVED', qc_status = 'PASS',
            qc_score = m417_internal.score100(p_score),
            reviewed_at = now(), is_canonical = true
        where id = p_take_id;
        return 'PASS';
    end if;
    update public.shot_audio_productions
    set status = 'REJECTED', qc_status = 'FAIL',
        qc_score = m417_internal.score100(p_score),
        qc_notes = v_reason, reviewed_at = now()
    where id = p_take_id;
    return 'FAIL';
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
    -- Room for voice in the cut of this shot (the whole shot for shots
    -- planned before the film rules).
    v_spec_duration := m417_internal.voice_room(v_take.shot_specification_id);
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

create or replace function m417_internal.video_scan(p_mutate boolean)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_items jsonb := '[]'::jsonb;
    v_waiting integer := 0;
    v_gen boolean := m417_internal.flag('generation_enabled', false);
    v_stale interval := make_interval(mins => m417_internal.num('video_claim_stale_minutes', 5)::integer);
    v_poll_gap interval := make_interval(secs => m417_internal.num('video_poll_min_interval_seconds', 45));
    v_timeout interval := make_interval(mins => m417_internal.num('video_poll_timeout_minutes', 45)::integer);
    v_blank jsonb := jsonb_build_object(
        'action', '', 'job_id', '', 'shot_id', '', 'attempt_id', '', 'provider', '',
        'submit_url', '', 'provider_request_text', '', 'poll_url', '', 'download_url', '',
        'storage_path', '', 'qc_context_text', '', 'notify_chat_id', '', 'review_text', '',
        'storage_base_url', '');
    v_job record;
    v_shot record;
    v_att public.attempts;
    v_has_att boolean;
    v_out record;
    v_manifest_id uuid;
    v_pilot_id uuid;
    v_pilot_state text;
    v_blocked boolean;
    v_resets integer;
    v_open integer;
    v_locked integer;
    v_emits integer;
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return jsonb_build_object('items', v_items, 'waiting', 0);
    end if;

    -- An advance to assembly that Make has not confirmed is handed out again.
    for v_job in
        select j.id
        from public.production_jobs j
        where j.current_step = 30 and j.state = 'READY'
          and j.video_advanced_at is not null
          and j.video_advance_acked_at is null
    loop
        v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
    end loop;

    for v_job in
        select j.id, j.episode_id, e.content_id, e.production_version, s.series_code
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.series s on s.id = j.series_id
        where j.current_step = 22 and j.state = 'READY'
        order by j.created_at
    loop
        select pm.id, pm.pilot_shot_id into v_manifest_id, v_pilot_id
        from public.production_manifests pm
        where pm.episode_id = v_job.episode_id
          and pm.production_version = v_job.production_version
          and pm.status = 'LOCKED';
        if not found then
            if p_mutate then
                perform m417_internal.block_job(v_job.id, 'LOCKED_MANIFEST_MISSING', null);
            end if;
            continue;
        end if;
        select s.state into v_pilot_state from public.shots s where s.id = v_pilot_id;
        v_blocked := false;

        for v_shot in
            select s.id, s.shot_code, s.state, ss.id as spec_id, ss.duration_seconds,
                   ss.narrative_action, ss.camera_movement, ss.dialogue, ss.continuity_notes,
                   ss.character_codes, ss.qc_brief
            from public.production_manifest_shots pms
            join public.shots s on s.id = pms.shot_id
            join public.shot_specifications ss on ss.id = pms.shot_specification_id
            where pms.manifest_id = v_manifest_id
            order by pms.manifest_order
        loop
            exit when v_blocked;
            continue when v_shot.state in ('LOCKED', 'CANCELLED');

            select a.* into v_att
            from public.attempts a
            where a.shot_id = v_shot.id
            order by a.attempt_no desc
            limit 1;
            v_has_att := found;

            if v_shot.state = 'ESCALATED' then
                select go.id, go.storage_path, go.qc_notes, go.qc_score into v_out
                from public.generation_outputs go
                where go.shot_id = v_shot.id
                  and go.storage_path is not null and btrim(go.storage_path) <> ''
                order by go.created_at desc
                limit 1;
                if not found then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'SHOT_FAILED_WITHOUT_OUTPUT',
                            v_shot.shot_code || ': both attempts failed and there is no clip to review.');
                    end if;
                    v_blocked := true;
                elsif exists (
                    select 1 from public.approval_requests ar
                    where ar.scope_type = 'SHOT_ESCALATION'
                      and ar.scope_id = v_shot.id
                      and ar.status = 'PENDING'
                      and ar.expires_at > now())
                then
                    null;  -- waiting for the owner
                else
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'HUMAN_REVIEW',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'storage_path', v_out.storage_path,
                        'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
                        'storage_base_url', m417_internal.txt('storage_base_url', ''),
                        'review_text', format('%s / %s. QC: %s (score %s)',
                            v_job.content_id, v_shot.shot_code,
                            coalesce(nullif(v_out.qc_notes, ''), '-'),
                            coalesce(v_out.qc_score::text, '-'))));
                end if;

            elsif v_has_att and v_att.status = 'BUDGET_RESERVED' then
                if v_att.submission_claimed_at is null then
                    if v_gen then
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'SUBMIT',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider),
                            'submit_url', m417_internal.submit_url(v_att.provider, v_att.model),
                            'provider_request_text', m417_internal.build_provider_request(v_att.id)));
                    end if;
                elsif v_att.submission_claimed_at < now() - v_stale then
                    select count(*) into v_resets
                    from public.events ev
                    where ev.attempt_id = v_att.id
                      and ev.event_type = 'ATTEMPT_SUBMISSION_CLAIM_RESET';
                    if v_resets >= 2 then
                        -- Three submissions that never produced a job id:
                        -- stop paying attention to this attempt.
                        if p_mutate then
                            perform public.release_generation_attempt_v2(
                                v_att.id, 'FAILED', 'SUBMISSION_FAILED_REPEATEDLY',
                                'The provider never returned a job id after 3 submissions.');
                            perform m417_internal.note_model_health(
                                v_att.id, 'DEGRADED', 'Submission failed repeatedly without a job id.');
                        end if;
                        v_waiting := v_waiting + 1;
                    else
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'RECONCILE',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider)));
                    end if;
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status in ('SUBMITTED', 'GENERATING') then
                if coalesce(v_att.started_at, v_att.created_at) < now() - v_timeout then
                    if p_mutate then
                        perform public.release_generation_attempt_v2(
                            v_att.id, 'FAILED', 'PROVIDER_TIMEOUT',
                            'No result from the provider within the time limit. Reservation released; check the provider bill for this job id.');
                        perform m417_internal.event(
                            'VIDEO_PROVIDER_TIMEOUT', 'CRITICAL',
                            'A submitted video attempt timed out. The provider may still have charged for it.',
                            jsonb_build_object('provider', v_att.provider, 'provider_job_id', v_att.provider_job_id,
                                               'estimated_cost', v_att.estimated_cost),
                            v_job.episode_id, v_shot.id, v_att.id);
                        perform m417_internal.note_model_health(v_att.id, 'DEGRADED', 'Generation timed out.');
                    end if;
                    v_waiting := v_waiting + 1;
                elsif v_att.last_provider_check_at is null
                   or v_att.last_provider_check_at < now() - v_poll_gap then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'POLL',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'attempt_id', v_att.id,
                        'provider', m417_internal.provider_route(v_att.provider),
                        'poll_url', m417_internal.poll_url(v_att.provider, v_att.provider_job_id)));
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status = 'SUCCEEDED'
              and v_shot.state in ('GENERATED', 'QC_PENDING') then
                v_emits := 1;
                if p_mutate then
                    insert into public.video_action_state (attempt_id, output_emits)
                    values (v_att.id, 1)
                    on conflict (attempt_id) do update
                        set output_emits = public.video_action_state.output_emits + 1, updated_at = now()
                    returning output_emits into v_emits;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object(
                    'action', 'PROCESS_OUTPUT',
                    'job_id', v_job.id,
                    'shot_id', v_shot.id,
                    'attempt_id', v_att.id,
                    'provider', m417_internal.provider_route(v_att.provider),
                    'download_url', coalesce(v_att.provider_result_url, ''),
                    'storage_path', format('%s/%s/video/%s_A%s_%s.mp4',
                        v_job.series_code, v_job.content_id, v_shot.shot_code, v_att.attempt_no,
                        m417_internal.rand_suffix()),
                    'qc_context_text', jsonb_build_object(
                        'shot', v_shot.shot_code,
                        'duration_seconds', v_shot.duration_seconds,
                        'action', v_shot.narrative_action,
                        'camera', v_shot.camera_movement,
                        'dialogue', case when m417_internal.flag('lip_sync_enforced', false)
                                         then v_shot.dialogue else null end,
                        'continuity_notes', v_shot.continuity_notes,
                        'film', v_shot.qc_brief,
                        'characters', (
                            select coalesce(jsonb_agg(jsonb_build_object(
                                       'name', c.name, 'description', c.canonical_description,
                                       'look_notes', (
                                           select v.wardrobe_note
                                           from public.asset_registry ar
                                           join public.video_reference_images v
                                             on v.asset_id = ar.id and v.is_active = true
                                           where ar.character_id = c.id
                                             and coalesce(btrim(v.wardrobe_note), '') <> ''
                                           limit 1))), '[]'::jsonb)
                            from public.characters c
                            where c.status = 'LOCKED'
                              and v_shot.character_codes ? c.character_code))::text));

            elsif v_shot.state in ('STORYBOARD_APPROVED', 'AUDIO_READY', 'RETRY_REQUIRED') then
                if not v_gen then
                    null;  -- paid generation is switched off
                elsif v_shot.id = v_pilot_id or v_pilot_state = 'LOCKED' then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'ACQUIRE', 'job_id', v_job.id, 'shot_id', v_shot.id));
                elsif v_pilot_state = 'CANCELLED' then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'PILOT_SHOT_CANCELLED',
                            'The pilot shot was cancelled; the remaining shots cannot pass the pilot gate.');
                    end if;
                    v_blocked := true;
                elsif v_pilot_state <> 'ESCALATED' then
                    v_waiting := v_waiting + 1;  -- pilot still in progress
                end if;
            end if;
        end loop;

        continue when v_blocked;

        select count(*) filter (where s.state not in ('LOCKED', 'CANCELLED')),
               count(*) filter (where s.state = 'LOCKED')
        into v_open, v_locked
        from public.production_manifest_shots pms
        join public.shots s on s.id = pms.shot_id
        where pms.manifest_id = v_manifest_id;

        if v_open = 0 then
            if v_locked = 0 then
                if p_mutate then
                    perform m417_internal.block_job(v_job.id, 'ALL_SHOTS_CANCELLED', null);
                end if;
            else
                -- The step moves before Make is told, so the assembly
                -- scenario finds the job at step 30 when it is called.
                if p_mutate then
                    update public.episodes set state = 'ASSEMBLY' where id = v_job.episode_id;
                    perform m417_internal.set_step(
                        v_job.id, 30, 'VIDEO_COMPLETE', jsonb_build_object('locked_shots', v_locked));
                    update public.production_jobs set video_advanced_at = now() where id = v_job.id;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
            end if;
        end if;
    end loop;

    return jsonb_build_object('items', v_items, 'waiting', v_waiting);
end;
$function$;

create or replace function public.create_render(p_job_id uuid, p_signed_urls jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_render public.renders;
    v_base text := rtrim(m417_internal.txt('storage_base_url', ''), '/');
    v_urls jsonb := '{}'::jsonb;
    v_item jsonb;
    v_edit jsonb;
    v_clip jsonb;
    v_video jsonb := '[]'::jsonb;
    v_voice jsonb := '[]'::jsonb;
    v_sfx jsonb := '[]'::jsonb;
    v_soundtrack jsonb;
    v_tracks jsonb := '[]'::jsonb;
    v_timeline jsonb;
    v_request jsonb;
    v_url text;
    v_total numeric;
begin
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state <> 'READY' or v_job.current_step not between 31 and 32 then
        raise exception 'STEP_MISMATCH: job is at step % (%)', v_job.current_step, v_job.state;
    end if;
    if v_base = '' then
        raise exception 'STORAGE_BASE_URL_NOT_SET: set system_text_settings.storage_base_url';
    end if;
    select r.* into v_render
    from public.renders r where r.job_id = p_job_id and r.status = 'CREATED'
    order by r.render_no desc limit 1
    for update;
    if not found then
        raise exception 'NO_RENDER_WAITING_FOR_A_TIMELINE';
    end if;
    if p_signed_urls is null or jsonb_typeof(p_signed_urls) <> 'array' then
        raise exception 'SIGNED_URLS_MUST_BE_ARRAY';
    end if;

    for v_item in select * from jsonb_array_elements(p_signed_urls)
    loop
        v_url := coalesce(v_item ->> 'signedURL', v_item ->> 'signedUrl');
        if v_url is not null and coalesce(v_item ->> 'error', '') = '' then
            v_urls := v_urls || jsonb_build_object(
                v_item ->> 'path',
                case when v_url like 'http%' then v_url
                     else v_base || case when v_url like '/%' then v_url else '/' || v_url end end);
        end if;
    end loop;

    v_edit := m417_internal.edit_list(p_job_id);
    v_total := (v_edit ->> 'total_seconds')::numeric;

    for v_clip in select * from jsonb_array_elements(v_edit -> 'shots')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_video := v_video || jsonb_build_object(
            'asset', jsonb_build_object('type', 'video', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 0)
                     || case when coalesce((v_clip ->> 'trim')::numeric, 0) > 0
                             then jsonb_build_object('trim', (v_clip ->> 'trim')::numeric) else '{}'::jsonb end,
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric,
            'fit', 'cover');
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'voices')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_voice := v_voice || jsonb_build_object(
            'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 1),
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric);
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'music')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        if v_clip ->> 'role' = 'MUSIC' and v_soundtrack is null then
            v_soundtrack := jsonb_build_object(
                'src', v_urls ->> (v_clip ->> 'path'),
                'effect', 'fadeOut',
                'volume', (v_clip ->> 'volume')::numeric);
        else
            v_sfx := v_sfx || jsonb_build_object(
                'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'),
                                            'volume', (v_clip ->> 'volume')::numeric),
                'start', least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)),
                'length', greatest(least(coalesce((v_clip ->> 'end')::numeric, v_total), v_total)
                                   - least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)), 0.5));
        end if;
    end loop;

    -- Shotstack draws the first track on top; audio order does not matter.
    if jsonb_array_length(v_voice) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_voice);
    end if;
    if jsonb_array_length(v_sfx) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_sfx);
    end if;
    v_tracks := v_tracks || jsonb_build_object('clips', v_video);

    v_timeline := jsonb_build_object('background', '#000000', 'tracks', v_tracks);
    if v_soundtrack is not null then
        v_timeline := v_timeline || jsonb_build_object('soundtrack', v_soundtrack);
    end if;
    v_request := jsonb_build_object(
        'timeline', v_timeline,
        'output', jsonb_build_object(
            'format', 'mp4',
            'aspectRatio', '9:16',
            'resolution', m417_internal.txt('render_resolution', 'hd')));

    update public.renders
    set request = v_request, updated_at = now()
    where id = v_render.id;
    update public.production_jobs set last_activity_at = now() where id = p_job_id;

    return jsonb_build_object(
        'render_id', v_render.id,
        'shotstack_request_text', v_request::text,
        'total_seconds', v_total);
end;
$function$;

create or replace function m417_internal.block_reason_tr(p_reason text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_reason
        when 'VIDEO_PREREQUISITES_MISSING' then 'Video üretimi için gereken model kaydı ya da bütçe eksik.'
        when 'NO_ACTIVE_ROUTING_POLICY' then 'Video modeli seçme kuralı tanımlı değil.'
        when 'NO_ELIGIBLE_VIDEO_MODEL' then 'Bu sahneyi üretebilecek uygun bir video modeli yok.'
        when 'VIDEO_ATTEMPT_REFUSED' then 'Video denemesi başlatılamadı (bütçe ya da hazırlık kontrolü).'
        when 'VOICE_TAKE_LIMIT_REACHED' then 'Bir replik için izin verilen ses denemeleri bitti.'
        when 'DIALOGUE_DOES_NOT_FIT_SHOT' then 'Bir replik, sahnesine sığmıyor.'
        when 'POLICY_GATE_1_FAILED' then 'Konu, çocuk güvenliği kontrolünden geçemedi.'
        when 'POLICY_GATE_2_FAILED' then 'Bitmiş video, güvenlik kontrolünden geçemedi.'
        when 'REVISION_LIMIT_REACHED' then 'Senaryo, izin verilen düzeltme sayısında onaylanamadı.'
        when 'VALIDATION_RETRY_LIMIT_REACHED' then 'Senaryo ya da sahne paketi kurallara uydurulamadı.'
        when 'FINAL_QC_FAILED' then 'Bitmiş video kalite kontrolünden geçemedi.'
        when 'RENDER_LIMIT_REACHED' then 'İzin verilen montaj denemeleri bitti.'
        when 'RELEASE_REJECTED' then 'Baş Yönetmen bitmiş videoyu onaylamadı.'
        when 'PUBLISH_REJECTED_BY_OWNER' then 'Yayın onayını sen reddettin.'
        when 'ALL_SHOTS_CANCELLED' then 'Bütün sahneler iptal edildi.'
        when 'PILOT_SHOT_CANCELLED' then 'İlk (pilot) sahne iptal edildi.'
        when 'SHOT_FAILED_WITHOUT_OUTPUT' then 'Bir sahne iki denemede de üretilemedi.'
        when 'BUDGET_GATE_1_FAILED' then 'Bütçe yetersiz ya da bu ay için bütçe açılmamış.'
        when 'BUDGET_GATE_2_FAILED' then 'Video için kalan bütçe yetersiz.'
        when 'SCRIPT_NOT_AGREED' then 'Yönetmen ile yardımcı yönetmen senaryoda anlaşamadı; iki evet çıkmadı.'
        when 'STALLED' then 'İş ilerlemiyor; otomatik yeniden başlatmalar sonuç vermedi.'
        else 'Sistem bir kontrol noktasında durdu.'
    end;
$function$;

-- ----- the instructions, version 1 -----------------------------------
update public.step_prompts set is_active = false
where prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE', 'PREQC', 'DIRECTOR', 'FINAL_QC') and version <> 1 and is_active;

insert into public.step_prompts (prompt_code, version, is_active, note, body) values
('TOPIC', 1, true, 'Step 7, Head Director: choose the story idea.', $p$Choose the single best story idea for the next WIZZLEBURY episode: a vertical animated short of [[EP_MIN]] to [[EP_MAX]] seconds for children and families.

A good idea is a tiny complete story, not a situation:
- One character wants something concrete; something gets in the way; it escalates in two or three steps; it ends on a surprise that is funny or warm.
- It can be told almost entirely in pictures. A viewer with the sound off still understands it.
- The very first image makes a stranger stop scrolling: something is already happening and raises a question.
- The comedy comes from who the characters are (their traits in the series bible), not from random events.
- It is easy to film with an AI video model in short separate shots: at most [[MAX_CAST]] characters in a picture, simple big physical actions, clear props. Avoid readable text, screens, crowds, sports with fast balls, water and liquids, mirrors, tiny hand work.
- Canon and child safety outweigh trend appeal. Nothing dangerous that a child could copy.

If the production request contains a brief, follow it. Never repeat a topic listed under rejected_topics in the request; read why it was rejected.

Trend report: [[TRENDS]]
Series bible: [[BIBLE]]
Production request: [[REQUEST]]

Return exactly this JSON shape:
{"title": "", "premise": "", "source_trend": "", "characters": [""], "location": "", "emotional_beat": "", "hook": "", "target_duration_seconds": 0, "rationale": "", "rejected_alternatives": [{"topic": "", "reason": ""}]}

premise tells the whole story in three to five sentences: the want, the obstacle, each escalation, the payoff. hook is the first image. characters and location are codes from the series bible.$p$),

('SCRIPT', 1, true, 'Step 10, Head Director: write the script.', $p$Write the script of this WIZZLEBURY episode. You are the Head Director and the writer. The Assistant Director will read your script, score it and vote YES or NO; nothing is filmed without that YES and your own final YES. Write the script you would be proud to sign.

LENGTH AND SHAPE
- The finished episode lasts [[EP_MIN]] to [[EP_MAX]] seconds and will be cut into [[SHOTS_MIN]] to [[SHOTS_MAX]] short shots. Scene durations add up to a total inside that range.
- At most [[LINES_MAX]] spoken lines. Every line is one short sentence of at most [[LINE_CHARS]] characters, spaces included. Lines are checked automatically against real speaking time.

STORY
- hook: the first two seconds. Start in the middle of something already happening; put a question in the viewer's head. No greeting, no setup, no title.
- Then a clear want, an obstacle, two or three escalations each bigger than the last, a turn nobody expected, and a payoff that answers the hook. End on a short button: one last look, line or gag.
- Tell it in pictures. Dialogue is real conversation between the characters: short, quick, back and forth, each line answering the one before; one character never explains the plot. Give the funniest words to the character whose nature they fit.
- Every character acts from the traits, weaknesses and relationships in the series bible. The lead character drives the story.
- Warm, funny, lively. Never scary, never mean, nothing a child could copy and get hurt.

WRITE IT SO IT CANNOT BE FILMED WRONG
Each shot is later generated separately by an AI video model that sees only one description at a time and remembers nothing. Whatever you leave open, it will invent differently in every shot.
- action of every scene: who is where (left, right, foreground, background), what exactly happens in order, what causes what, and how each character reacts. State exact counts and what must not happen ("one ball, never two", "the tree does not fall").
- wardrobe: one outfit per character for the whole episode, chosen for the place and the activity (school, park, sport, rain, a party ...). Garments, colours, shoes, anything worn or carried. Modest and suitable for a child; no logos, brands or writing. Every character has a clearly different look and main colour; the lead is the most eye-catching. Anything in look_notes of a character in the series bible always holds.
- props: every object that matters, with colour, size, material and exact count. One entry per object. Describe it once here and use the same name everywhere.
- look: time of day, weather, light and colour mood, the same in every shot.
- Only characters and locations from the series bible, by their codes. Only characters with has_voice = true speak.
- Keep it filmable: at most [[MAX_CAST]] characters seen at once, simple big physical actions, clear props. Avoid readable text and signs, screens, crowds, fast ball games, water and liquids, mirrors, tiny hand work such as tying knots.

INPUTS
Selected topic: [[TOPIC]]
Series bible: [[BIBLE]]
Previous script (if any): [[SCRIPT]]
Feedback on the previous script (if any): [[FEEDBACK]]

If there is feedback, this is a rewrite. Meet every required change and fix every problem, keep what was praised, and say in revision_notes what you changed. If the feedback gives scores, raise the weak ones: a better hook, a sharper turn, funnier lines.

Return exactly this JSON shape:
{"title": "", "logline": "", "hook": "", "payoff": "", "look": "", "wardrobe": [{"character": "", "outfit": ""}], "props": [{"name": "", "description": ""}], "scenes": [{"scene_no": 1, "location": "", "characters": [""], "duration_seconds": 0, "action": "", "dialogue": [{"line_no": 1, "character": "", "text": "", "emotion": ""}], "sound_notes": ""}], "total_duration_seconds": 0, "revision_notes": ""}

line_no restarts at 1 in every scene. A scene without speech has an empty dialogue array. Before answering, check: the total is inside the range; no line is longer than [[LINE_CHARS]] characters; every character has an outfit; every object that matters is a prop; a stranger could draw each scene from its action alone.$p$),

('SHOT_PACKAGE', 1, true, 'Step 11, Assistant Director: vote on the script, then plan the shots.', $p$You are the Assistant Director of WIZZLEBURY, a premium stylized 3D animated series of vertical shorts for children and families. Claude, the Head Director, wrote the script below. You do two things in one answer: you vote on the script, and if your vote is YES you plan every shot.

PART 1 - YOUR VOTE (two-yes rule)
Nothing is filmed unless you and the Head Director both say YES. Read the script as the viewer who decides in two seconds whether to keep watching, and as the person who has to film it.
Score each from 1 to 10:
- hook: do the first two seconds stop a stranger from scrolling?
- story: want, obstacle, escalation, a real turn, a payoff that lands?
- humor: is it actually funny or charming, from character and not from accident?
- dialogue: short, natural, back and forth, each line worth its seconds?
- filmability: can an AI video model shoot it in short separate shots without ambiguity? Are wardrobe, props and look exact?
Vote YES only if you would film exactly this script and every score is at least [[MIN_SCORE]]. Otherwise vote NO. A NO costs nothing; a weak episode costs the channel. Do not vote NO for things you can solve yourself in the staging.
When you vote NO: problems says precisely what is weak and where; required_changes gives concrete rewrites - a better hook image, a sharper line, a stronger payoff - that would earn your YES. Return "shots": [].
Your last rejection of this topic (if any): [[LAST_REJECTION]]
If there is one, check that each required change was met before you vote.

PART 2 - THE SHOT PACKAGE (only when you vote YES)
Turn the script into the complete edit of the episode: every cut, planned to a tenth of a second. Do not change the story, the dialogue text or who speaks.

How the film is made: every shot is generated separately by an AI video model as a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.

THE EDIT
- [[SHOTS_MIN]] to [[SHOTS_MAX]] shots. Each cut lasts [[CUT_MIN]] to [[CUT_MAX]] seconds (edit_seconds, one decimal). The cuts add up to [[EP_MIN]] to [[EP_MAX]] seconds.
- Shot 1 is the hook: the most striking image of the story, at most [[HOOK_MAX]] seconds.
- shot_size is one of EXTREME_WIDE, WIDE, MEDIUM, MEDIUM_CLOSE, CLOSE_UP, EXTREME_CLOSE_UP, INSERT, OVER_SHOULDER. Two neighbouring shots never have the same size. Use at least three sizes. One of the first three shots is WIDE or EXTREME_WIDE so the viewer knows where we are. Use close shots for reactions and INSERT shots for the object that matters.
- Cut like a film: establish, act, react. Show the cause, then the face that sees it. Vary the rhythm: quick cuts of about one second for reactions and surprises, longer ones for action and for lines. End on the payoff and a short button.
- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.

DIALOGUE
- At most one spoken line per shot. A conversation is a chain of shots: the speaker, then the answer, then a reaction. Every script line goes into dialogue_line_nos of exactly one shot of its own scene (line numbers restart in every scene).
- A shot with a line lasts at least the speaking time of the line plus half a second (see dialogue_timing_rule in the series bible).
- voice_staging says how the speaker is staged: ON_CAMERA (seen talking; shot size MEDIUM_CLOSE or wider), OFF_SCREEN (not in the shot: we watch the listener react, or an object) or BACK_TO_CAMERA (seen from behind, typically OVER_SHOULDER on the listener). Exact lip-sync is not produced yet, so nobody speaks in a CLOSE_UP or EXTREME_CLOSE_UP: those are silent looks, reactions and laughs.
- characters lists exactly the characters visible in the shot, at most [[MAX_CAST]]; one or two is better. An OFF_SCREEN speaker is not listed.

EVERY SHOT
- beats: what happens when inside the cut, in seconds from its start: [{"at": 0.0, "what": "..."}, {"at": 0.6, "what": "..."}]. The first beat is at 0. Each beat is one visible action or change of expression. The action must start at once: the cut is short.
- video_prompt: what the video model reads. Plain English, present tense, [[PROMPT_MIN]] to 800 characters, one continuous shot without cuts. In this order: who is where in the frame, what each one does and how, expressions and body language, the place around them. Characters by their plain names exactly as in the series bible. No codes, no file names, no brackets, no spoken words. Self-contained: never "as before" or "the same".
- Do not describe faces, hair, outfits, props or the light in video_prompt: the system adds the wardrobe, the listed props and the look from the script to every shot in identical words. Name the props the shot shows in props, using the prop names of the script.
- Acting is specific and visible: eyebrows, eyes, hands, posture ("her eyes go wide, then a slow grin spreads"). One clear action per shot, simple and physically plausible.
- camera: angle and movement (static, slow push-in, pan, low angle ...). action: one sentence. acting: the emotional beat. purpose: HOOK, SETUP, ACTION, REACTION, DIALOGUE, PAYOFF or BUTTON. negative_prompt: a short comma-separated list of what to avoid. continuity_notes: what must match the neighbouring shots.
- duration_seconds is always [[GEN_SECONDS]]. aspect_ratio is always "9:16". shot_no counts 1, 2, 3 ... through the episode. location is a location code.

INPUTS
Script: [[SCRIPT]]
Series bible: [[BIBLE]]
Previous shot package (if any): [[SHOT_PACKAGE]]
Feedback on the previous shot package (if any): [[FEEDBACK]]
If there is feedback on the shots, this is a revision: fix every listed issue and return the complete package again, including the shots that did not change. If the script did not change, repeat your vote.

Return one raw JSON object only, no markdown, no code fences, in exactly this shape:
{"script_vote": {"decision": "YES or NO", "scores": {"hook": 0, "story": 0, "humor": 0, "dialogue": 0, "filmability": 0}, "strengths": [""], "problems": [""], "required_changes": [""]}, "shots": [{"shot_no": 1, "scene_no": 1, "purpose": "", "shot_size": "", "camera": "", "duration_seconds": [[GEN_SECONDS]], "edit_seconds": 0.0, "aspect_ratio": "9:16", "characters": [""], "location": "", "props": [""], "beats": [{"at": 0.0, "what": ""}], "dialogue_line_nos": [], "voice_staging": "", "action": "", "acting": "", "video_prompt": "", "negative_prompt": "", "continuity_notes": ""}], "total_edit_seconds": 0.0, "continuity_risks": [""]}

Before answering, check your own work: the number of shots and the sum of the cuts are inside the limits; shot 1 is at most [[HOOK_MAX]] seconds; no two neighbours share a size; a wide shot is among the first three; every script line is in exactly one shot and that shot is long enough; nobody speaks in a close-up; every shot has beats starting at 0; every video_prompt is self-contained and free of codes.$p$),

('PREQC', 1, true, 'Step 12, QC Inspector: check the package before production.', $p$You are the Pre-Production QC Inspector of WIZZLEBURY. This is a planning gate only. Review the script and the shot package against the series bible before any money is spent.

How the film is made: every shot is generated separately by an AI video model that sees only the video_prompt of that shot (the system adds the wardrobe, the props and the look of the script to each one), and the edit uses the first edit_seconds of each clip. Voices are recorded separately and laid over the cuts; exact lip-sync is not produced and is not an issue to report.

Check:
- Canon: characters behave and speak as the series bible says; only known characters and locations.
- Story on screen: do the shots, in order, tell the script so that a viewer with the sound off understands it? Does shot 1 hook? Does the last shot pay off?
- Continuity between shots: where each character stands, which props are present, what happened before. A video_prompt that depends on another shot ("as before") is an issue.
- Ambiguity: anything the video model could show wrongly - unclear counts, unclear cause and effect, two actions in one shot, an action that cannot be shown in the length of the cut.
- Dialogue: every line is in the right shot, the speaker is staged as voice_staging says, nobody else is described as talking.
- Wardrobe and props: suitable for children, without logos, brands or writing; exact enough to look the same in every shot.
- Child safety: nothing frightening, nothing dangerous to copy.
Lengths, shot counts, shot sizes and line timing were already checked by the system; do not report them.

Script: [[SCRIPT]]
Shot package: [[SHOT_PACKAGE]]
Series bible: [[BIBLE]]

OUTPUT FORMAT (mandatory). Respond with exactly one raw JSON object. No markdown, no code fences, no commentary, no extra keys:
{"verdict": "PASS or REVISE_SCRIPT or REVISE_SHOTS", "issues": [{"target": "SCRIPT or SHOTS", "ref": "scene / line / shot reference", "severity": "LOW or MEDIUM or HIGH", "detail": "what is wrong", "fix": "what to change"}], "continuity_status": "PASS or FAIL", "character_identity_status": "PASS or FAIL", "lip_sync_status": "READY", "notes": "short summary"}

Rules:
- The key is "verdict". "issues" is an empty array when nothing needs fixing.
- If any issue has severity MEDIUM or HIGH, the verdict is REVISE_SCRIPT (the problem is in the script) or REVISE_SHOTS (the problem is in the shot package). Use MEDIUM or HIGH only for something that would visibly damage the episode or break a rule; say exactly what to change.
- LOW issues alone do not block: the verdict is PASS.$p$),

('DIRECTOR', 1, true, 'Step 14, Head Director: the final YES or NO.', $p$Make the final Head Director decision on this production package. This is the second YES of the two-yes rule: the Assistant Director has voted YES on your script and planned the shots. Your APPROVE authorizes paid production, so approve only a package you would stake the episode budget on.

Read the shot package as the finished film, cut by cut:
- Does shot 1 stop a stranger from scrolling?
- Does every cut show exactly one clear thing, and does the order tell the story without sound?
- Do the cuts breathe - wide to place us, close for faces, inserts for the object that matters - and does the rhythm build to the payoff?
- Is every video_prompt complete on its own and impossible to misread?
- Is the dialogue staged as a real exchange?

APPROVE requires a pre-QC verdict of PASS and no child-safety concern. Use REVISE_SHOTS when the shots do not do the script justice, and REVISE_SCRIPT when the script itself must change (the Assistant Director will vote again); give precise required_changes. Use REJECT only when the topic itself cannot work.

Script: [[SCRIPT]]
Assistant Director's vote and review: [[ASSISTANT_REVIEW]]
Shot package: [[SHOT_PACKAGE]]
Pre-QC report: [[PREQC_REPORT]]
Series bible: [[BIBLE]]

Return exactly this JSON shape:
{"decision": "APPROVE, REVISE_SCRIPT, REVISE_SHOTS or REJECT", "director_notes": "", "required_changes": [""], "child_safety_status": "PASS or FAIL", "production_ready": true}$p$),

('FINAL_QC', 1, true, 'Steps 31-32, QC Inspector: judge the finished edit.', $p$You are the Final QC Inspector of WIZZLEBURY. Watch the attached finished edit of a family-friendly vertical animated short, with sound, and judge it against the script and the planned edit below.

How it was made: every cut is a separately generated clip; the voices were recorded separately and laid over the cuts. Exact lip-sync is not produced in this version: do not fail the edit for lip-sync, and report lip_sync as FAIL only when a character who is not the speaker is clearly the one talking during a line.

Check:
- dialogue_match: every scripted line is audible, in order, and its words match the script.
- audio_mix: voices are clear, do not overlap each other and are not masked by music.
- edit_order: the cuts follow the planned edit and tell the story of the script.
- character_consistency: each character looks like the same child in every cut (face, hair, outfit as in wardrobe of the script).
- visual_artifacts: glitches, black frames, broken anatomy, duplicated characters or objects, unwanted text. A prop or background that looks slightly different between two cuts is reported in notes but does not fail the edit by itself. A small "shotstack" watermark, if present, comes from the editor's trial mode: ignore it.
- duration_and_format: vertical 9:16, about [[TOTAL_SECONDS]] seconds long (within two seconds).
- child_safety: nothing frightening, nothing dangerous to copy.
Be strict about real defects a viewer would notice; do not fail for matters of taste.

Script: [[SCRIPT]]
Planned edit: [[EDIT_PLAN]]

Return one raw JSON object only, no markdown, no code fences. score is between 0 and 1.
{"verdict": "PASS or FAIL", "score": 0.0, "notes": "", "details": {"dialogue_match": "PASS or FAIL", "lip_sync": "PASS or FAIL", "audio_mix": "PASS or FAIL", "edit_order": "PASS or FAIL", "character_consistency": "PASS or FAIL", "visual_artifacts": "PASS or FAIL", "duration_and_format": "PASS or FAIL", "child_safety": "PASS or FAIL"}}$p$)
on conflict (prompt_code, version) do update
    set body = excluded.body, note = excluded.note, is_active = true;

-- ----- permissions ---------------------------------------------------
do $$
declare
    r record;
    v_role text;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'm417_internal'
           or (n.nspname = 'public' and p.proname = 'set_video_wardrobe')
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
values ('SCHEMA_010_APPLIED', 'INFO', 'CONTROL_PLANE', 'Film grammar and two-yes rule (010) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
