-- =====================================================================
-- M417 / WIZZLEBURY  -  013 one event per shot
--
-- Run after 012. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. A shot of a short carries one event and the reaction to it: at most
--    max_beats_per_shot timed beats (3). More is refused with the reason.
--    The shot instructions say so (SHOT_PACKAGE version 3).
-- 2. The list of recent shorts given to the topic writer no longer
--    contains cancelled jobs.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.validate_camera_plan(uuid, jsonb)') is null
       or not exists (select 1 from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 2)
    then
        raise exception 'M417_012_NOT_FOUND: apply 012_short_format.sql first';
    end if;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('max_beats_per_shot', 3, 'Most timed beats in one shot of a short: one event and the reaction to it.')
on conflict (key) do nothing;

create or replace function m417_internal.validate_one_event(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_idx integer := 0;
    v_n integer;
    v_max integer := m417_internal.num('max_beats_per_shot', 3)::integer;
begin
    if not (m417_internal.film_on() and m417_internal.flag('short_format_enforced', false)) or v_max <= 0 then
        return v_issues;
    end if;
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array' then
        return v_issues;
    end if;
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        continue when jsonb_typeof(v_shot -> 'beats') is distinct from 'array';
        v_n := jsonb_array_length(v_shot -> 'beats');
        if v_n > v_max then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text),
                format('The shot has %s beats; a shot of a short has at most %s.', v_n, v_max),
                format('Keep one event and the reaction to it, in at most %s beats, and rewrite action and video_prompt to match. The video model performs one event per shot and drops a second one: what does not fit is left out, not squeezed in.', v_max));
        end if;
    end loop;
    return v_issues;
end;
$function$;
create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    -- M417-LAYER-012
    select m417_internal.validate_shot_package_film(p_job_id, p_content)
        || m417_internal.validate_camera_plan(p_job_id, p_content)
        || m417_internal.validate_one_event(p_job_id, p_content);
$function$;
create or replace function m417_internal.step_prompt(
    p_job_id uuid, p_step integer, p_request text, p_feedback text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_body text := m417_internal.step_prompt_base(p_job_id, p_step, p_request, p_feedback);
    v_recent text;
    v_moods text;
begin
    -- M417-LAYER-012
    if v_body is null or position('[[' in v_body) = 0 then
        return v_body;
    end if;
    select coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb)::text into v_recent
    from (
        select jsonb_build_object(
                   'title', a.content ->> 'title',
                   'pattern', a.content ->> 'pattern',
                   'characters', a.content -> 'characters',
                   'location', a.content ->> 'location') as item,
               j.created_at
        from public.production_jobs j
        join public.job_artifacts a
          on a.job_id = j.id and a.artifact_type = 'TOPIC_SELECTION' and a.is_current
        where j.id <> p_job_id and j.current_step >= 16 and j.state <> 'CANCELLED'
        order by j.created_at desc
        limit 8
    ) x;
    select string_agg(distinct lower(btrim(mt.mood)), ', ') into v_moods
    from public.music_tracks mt
    where mt.is_active = true and mt.license_status = 'VERIFIED' and mt.role = 'MUSIC'
      and coalesce(btrim(mt.mood), '') <> '';
    v_body := replace(v_body, '[[RECENT]]', coalesce(v_recent, '[]'));
    v_body := replace(v_body, '[[MUSIC_MOODS]]',
                      coalesce(v_moods, 'playful, sneaky, chase, triumphant, warm, mystery, dance'));
    v_body := replace(v_body, '[[LINE_WORDS]]', m417_internal.num('max_line_words', 6)::integer::text);
    v_body := replace(v_body, '[[BEATS_MAX]]', m417_internal.num('max_beats_per_shot', 3)::integer::text);
    return v_body;
end;
$function$;

-- ----- SHOT_PACKAGE 3: one event per shot ---------------------------------
-- Version 2 with one rule added. Built from version 2 as it stands in
-- the table, so the two cannot drift apart unnoticed.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 2;
    if v is null then
        raise exception 'M417_013_PROMPT_V2_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short.$a$,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short. At most [[BEATS_MAX]] beats: one event and the reaction to it. The video model performs one event per shot and drops a second one, so what does not fit is left out, never squeezed in.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has beats starting at 0;$a$,
        $a$every shot has at most [[BEATS_MAX]] beats, the first at 0;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 3, false, 'Step 11: as version 2, plus one event per shot (at most max_beats_per_shot beats).', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = (version = 3) where prompt_code = 'SHOT_PACKAGE';
end $$;

do $$
declare
    v_role text;
begin
    execute 'revoke all on function m417_internal.validate_one_event(uuid, jsonb) from public';
    foreach v_role in array array['anon', 'authenticated', 'service_role']
    loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on function m417_internal.validate_one_event(uuid, jsonb) from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_013_APPLIED', 'INFO', 'CONTROL_PLANE', 'One event per shot (013) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
