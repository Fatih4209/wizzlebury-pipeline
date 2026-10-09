
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

create or replace function public.complete_render(p_render_id uuid, p_storage_path text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
    v_job public.production_jobs;
    v_size bigint;
begin
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    if v_render.status not in ('DONE', 'STORED') then
        raise exception 'RENDER_NOT_DONE: %', v_render.status;
    end if;
    v_size := m417_internal.object_size(p_storage_path);
    if v_size is null then
        raise exception 'RENDER_FILE_NOT_FOUND_IN_STORAGE: %', coalesce(p_storage_path, '(empty)');
    end if;
    if v_size < m417_internal.num('min_video_bytes', 20000) then
        raise exception 'RENDER_FILE_TOO_SMALL: % bytes', v_size;
    end if;
    v_job := m417_internal.lock_job(v_render.job_id);

    update public.renders
    set status = 'STORED', storage_path = p_storage_path, updated_at = now()
    where id = p_render_id;

    -- An edit rendered again after the owner resumed a job stopped at
    -- final QC arrives here with the job already at step 32; the episode
    -- has to reach FINAL_QC on that path as well.
    if v_job.state = 'READY' and v_job.current_step in (31, 32) then
        update public.episodes set state = 'FINAL_QC'
        where id = v_job.episode_id and state = 'ASSEMBLY';
    end if;
    if v_job.current_step = 31 and v_job.state = 'READY' then
        perform m417_internal.set_step(
            v_job.id, 32, 'RENDER_STORED', jsonb_build_object('render_id', p_render_id, 'storage_path', p_storage_path));
    end if;
    return m417_internal.job_status(v_job.id)
        || jsonb_build_object('render_id', p_render_id, 'status', 'STORED');
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
