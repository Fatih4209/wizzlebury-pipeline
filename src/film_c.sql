
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
