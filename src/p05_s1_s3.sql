
-- =====================================================================
-- 6. RPC: S1 start, common, S2 creative planning
-- =====================================================================

-- ----- steps 1-4 ----------------------------------------------------
create or replace function public.start_production_job(
    p_idempotency_key text, p_series_code text, p_request jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_series public.series;
    v_profile public.production_creative_profiles;
    v_episode_budget numeric;
    v_shot_budget numeric;
    v_episode_id uuid;
    v_content_id text;
    v_job_id uuid;
    v_active integer;
begin
    if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
        raise exception 'IDEMPOTENCY_KEY_REQUIRED';
    end if;

    -- The same key always returns the same job.
    select j.* into v_job
    from public.production_jobs j
    where j.idempotency_key = btrim(p_idempotency_key);
    if found then
        return m417_internal.job_status(v_job.id)
            || jsonb_build_object('decision', 'EXISTING');
    end if;

    if m417_internal.flag('pipeline_enabled', false) is not true then
        raise exception 'PIPELINE_DISABLED';
    end if;

    select s.* into v_series
    from public.series s
    where upper(s.series_code) = upper(btrim(coalesce(p_series_code, '')))
      and s.status <> 'ARCHIVED'
    order by s.version desc
    limit 1;
    if not found then
        raise exception 'SERIES_NOT_FOUND: %', coalesce(p_series_code, '(empty)');
    end if;

    select p.* into v_profile
    from public.production_creative_profiles p
    where upper(p.profile_code) = upper(btrim(coalesce(p_request ->> 'creative_profile_code', '')))
      and p.status = 'LOCKED';
    if not found then
        raise exception 'LOCKED_CREATIVE_PROFILE_NOT_FOUND: %',
            coalesce(p_request ->> 'creative_profile_code', '(empty)');
    end if;

    v_episode_budget := m417_internal.safe_numeric(p_request ->> 'episode_budget_usd');
    v_shot_budget := m417_internal.safe_numeric(p_request ->> 'shot_budget_usd');
    if v_episode_budget is null or v_episode_budget <= 0 then
        raise exception 'EPISODE_BUDGET_REQUIRED';
    end if;
    if v_shot_budget is null or v_shot_budget <= 0 then
        raise exception 'SHOT_BUDGET_REQUIRED';
    end if;
    if v_shot_budget > v_episode_budget then
        raise exception 'SHOT_BUDGET_EXCEEDS_EPISODE_BUDGET';
    end if;

    -- Serialise job creation so the active-job limit holds.
    perform 1 from public.system_flags sf where sf.key = 'pipeline_enabled' for update;
    select count(*) into v_active
    from public.production_jobs j
    where j.state not in ('DONE', 'CANCELLED');
    if v_active >= m417_internal.num('max_active_jobs', 1) then
        raise exception 'ACTIVE_JOB_LIMIT_REACHED: % job(s) in progress', v_active;
    end if;

    v_job_id := gen_random_uuid();
    v_content_id := v_series.series_code || '-' || to_char(now() at time zone 'UTC', 'YYYYMMDD')
                    || '-' || upper(substr(replace(v_job_id::text, '-', ''), 1, 6));

    insert into public.episodes (
        content_id, series_id, state, maximum_budget, production_mode, creative_profile_id)
    values (
        v_content_id, v_series.id, 'PLANNED', v_episode_budget,
        v_profile.production_mode, v_profile.id)
    returning id into v_episode_id;

    update public.episodes set state = 'PREPRODUCTION' where id = v_episode_id;

    insert into public.budgets (budget_type, reference_id, currency, hard_limit, is_active)
    values ('EPISODE', v_episode_id, 'USD', v_episode_budget, true);

    insert into public.production_jobs (
        id, idempotency_key, series_id, episode_id, creative_profile_id, request, current_step, state)
    values (
        v_job_id, btrim(p_idempotency_key), v_series.id, v_episode_id, v_profile.id,
        coalesce(p_request, '{}'::jsonb), 5, 'READY');

    insert into public.job_step_log (job_id, step_no, event, detail)
    values (v_job_id, 5, 'JOB_STARTED',
            jsonb_build_object('content_id', v_content_id, 'series_code', v_series.series_code,
                               'creative_profile_code', v_profile.profile_code));
    perform m417_internal.event(
        'JOB_STARTED', 'INFO', 'Production job started for ' || v_content_id,
        jsonb_build_object('job_id', v_job_id, 'episode_budget_usd', v_episode_budget, 'shot_budget_usd', v_shot_budget),
        v_episode_id);

    return m417_internal.job_status(v_job_id)
        || jsonb_build_object('decision', 'CREATED', 'content_id', v_content_id);
end;
$function$;

-- ----- every scenario starts here -----------------------------------
create or replace function public.job_next_step(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_status jsonb;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id for update;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    v_status := m417_internal.job_status(p_job_id);
    if v_job.state <> 'READY' then
        return v_status;
    end if;
    -- With the pipeline switched off no scenario may act on a job.
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return v_status || jsonb_build_object(
            'state', 'BLOCKED', 'blocked_reason', 'PIPELINE_DISABLED');
    end if;

    -- One run per step: a second run that asks while the first is still
    -- working is told IN_PROGRESS and does nothing.
    if m417_internal.step_has_lease(v_job.current_step) then
        if v_job.step_claimed_step is not distinct from v_job.current_step
           and v_job.step_claimed_at > now() - make_interval(secs => m417_internal.num('step_lease_seconds', 180))
        then
            return v_status || jsonb_build_object('state', 'IN_PROGRESS', 'busy', 'STEP_ALREADY_RUNNING');
        end if;
        update public.production_jobs
        set step_claimed_at = now(), step_claimed_step = current_step
        where id = p_job_id;
    elsif v_job.current_step between 16 and 18 and m417_internal.voice_batch_open(p_job_id) then
        return v_status || jsonb_build_object('state', 'IN_PROGRESS', 'busy', 'VOICE_BATCH_RUNNING');
    end if;
    return v_status;
end;
$function$;

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
        'assistant_review_text', '',
        'music_library_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'track_code', mt.track_code, 'title', mt.title, 'role', mt.role,
                       'mood', mt.mood, 'duration_seconds', mt.duration_seconds)
                       order by mt.track_code), '[]'::jsonb)::text
            from public.music_tracks mt
            where mt.is_active = true and mt.license_status = 'VERIFIED'),
        'final_qc_report_text', coalesce((
            select r.qc_result::text
            from public.renders r
            where r.job_id = p_job_id and r.qc_result is not null
            order by r.render_no desc
            limit 1), ''),
        'policy_checks_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'gate_no', pc.gate_no, 'verdict', pc.verdict, 'checker', pc.checker,
                       'findings', pc.result -> 'findings', 'notes', pc.result -> 'notes')
                       order by pc.created_at), '[]'::jsonb)::text
            from public.policy_checks pc
            where pc.job_id = p_job_id),
        'metadata_candidates_text', m417_internal.artifact_text(p_job_id, 'METADATA_CANDIDATES'));
end;
$function$;

-- ----- step 5 and step 21 -------------------------------------------
create or replace function public.evaluate_budget_gate(p_job_id uuid, p_gate_no integer)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_step integer;
    v_monthly_available numeric;
    v_episode_limit numeric;
    v_episode_available numeric;
    v_policy_id uuid;
    v_shot record;
    v_cost numeric;
    v_total numeric := 0;
    v_problems text[] := array[]::text[];
    v_reason text;
begin
    if p_gate_no not in (1, 2) then
        raise exception 'INVALID_BUDGET_GATE';
    end if;
    v_step := case p_gate_no when 1 then 5 else 21 end;
    v_job := m417_internal.lock_job(p_job_id);
    -- Repeating a gate that already passed changes nothing.
    if v_job.current_step > v_step then
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('gate_no', p_gate_no, 'passed', true, 'decision', 'ALREADY_PASSED');
    end if;
    perform m417_internal.require_step(v_job, v_step);

    select (b.hard_limit - b.reserved_amount - b.settled_amount)
    into v_monthly_available
    from public.budgets b
    where b.budget_type = 'MONTHLY'
      and b.reference_id is null
      and b.currency = 'USD'
      and b.is_active = true
      and (b.period_start is null or b.period_start <= now())
      and (b.period_end is null or b.period_end > now())
    order by b.created_at desc
    limit 1;

    select b.hard_limit, (b.hard_limit - b.reserved_amount - b.settled_amount)
    into v_episode_limit, v_episode_available
    from public.budgets b
    where b.budget_type = 'EPISODE'
      and b.reference_id = v_job.episode_id
      and b.is_active = true
    order by b.created_at desc
    limit 1;

    if v_monthly_available is null then
        v_problems := v_problems || 'ACTIVE_MONTHLY_BUDGET_MISSING'::text;
    elsif p_gate_no = 1 and v_monthly_available < v_episode_limit then
        v_problems := v_problems || format(
            'MONTHLY_BUDGET_TOO_LOW: %s available, episode budget %s', v_monthly_available, v_episode_limit);
    end if;
    if v_episode_limit is null then
        v_problems := v_problems || 'ACTIVE_EPISODE_BUDGET_MISSING'::text;
    end if;

    if p_gate_no = 2 and cardinality(v_problems) = 0 then
        select grp.id into v_policy_id
        from public.generation_routing_policies grp
        where grp.status = 'ACTIVE' and grp.approved_at is not null
        order by grp.approved_at desc
        limit 1;
        if v_policy_id is null then
            v_problems := v_problems || 'NO_ACTIVE_ROUTING_POLICY'::text;
        else
            for v_shot in
                select s.shot_code, s.maximum_budget, ss.id as spec_id
                from public.shots s
                join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                where s.episode_id = v_job.episode_id
                order by s.shot_order
            loop
                -- Cheapest PRIMARY model that fits the shot and has an
                -- approved benchmark or an owner pilot approval. Live
                -- health is checked at acquisition.
                select min(ec.estimated_cost) into v_cost
                from public.generation_policy_models gpm
                join public.evaluate_generation_candidates(v_shot.spec_id) ec
                  on ec.model_id = gpm.model_id
                where gpm.policy_id = v_policy_id
                  and gpm.enabled = true
                  and gpm.route_role = 'PRIMARY'
                  and ec.duration_compatible and ec.aspect_ratio_compatible
                  and ec.resolution_compatible and ec.reference_compatible
                  and ec.pricing_compatible
                  and (exists (
                          select 1 from public.generation_model_benchmarks b
                          where b.model_id = gpm.model_id
                            and b.benchmark_status = 'HUMAN_APPROVED'
                            and b.approved_at is not null)
                       or exists (
                          select 1 from public.generation_model_pilot_approvals pa
                          where pa.model_id = gpm.model_id
                            and pa.revoked_at is null));
                if v_cost is null then
                    v_problems := v_problems || ('NO_ELIGIBLE_PRIMARY_MODEL: ' || v_shot.shot_code);
                else
                    v_total := v_total + v_cost;
                    if v_cost > v_shot.maximum_budget then
                        v_problems := v_problems || format(
                            'SHOT_BUDGET_TOO_LOW: %s needs %s, budget %s',
                            v_shot.shot_code, v_cost, v_shot.maximum_budget);
                    end if;
                end if;
            end loop;
            if v_total > v_episode_available then
                v_problems := v_problems || format(
                    'EPISODE_BUDGET_TOO_LOW: video needs %s, %s available', v_total, v_episode_available);
            end if;
            if v_total > v_monthly_available then
                v_problems := v_problems || format(
                    'MONTHLY_BUDGET_TOO_LOW: video needs %s, %s available', v_total, v_monthly_available);
            end if;
        end if;
    end if;

    if cardinality(v_problems) > 0 then
        v_reason := case
            when p_gate_no = 1 then 'BUDGET_GATE_1_FAILED'
            when exists (
                select 1 from unnest(v_problems) x
                where x like 'NO_ACTIVE_ROUTING_POLICY%' or x like 'NO_ELIGIBLE_PRIMARY_MODEL%')
            then 'VIDEO_PREREQUISITES_MISSING'
            else 'BUDGET_GATE_2_FAILED' end;
        perform m417_internal.block_job(p_job_id, v_reason, array_to_string(v_problems, '; '));
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('gate_no', p_gate_no, 'passed', false, 'problems', to_jsonb(v_problems));
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'BUDGET_GATE_PASSED',
        jsonb_build_object('gate_no', p_gate_no, 'monthly_available', v_monthly_available,
                           'episode_limit', v_episode_limit, 'estimated_video_cost', v_total));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object(
            'gate_no', p_gate_no, 'passed', true,
            'monthly_available', v_monthly_available,
            'episode_limit', v_episode_limit,
            'estimated_video_cost', v_total,
            'generation_enabled', m417_internal.flag('generation_enabled', false));
end;
$function$;

-- ----- steps 6, 7, 10, 11, 12, 19, 36 -------------------------------
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

-- ----- step 8 and step 33 -------------------------------------------
create or replace function public.record_policy_check(
    p_job_id uuid, p_gate_no integer, p_checker text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_step integer;
    v_verdict text;
    v_retries integer;
begin
    if p_gate_no not in (1, 2) then
        raise exception 'INVALID_POLICY_GATE';
    end if;
    if upper(btrim(coalesce(p_checker, ''))) <> 'CLAUDE' then
        raise exception 'POLICY_CHECKER_NOT_AUTHORIZED: %', coalesce(p_checker, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'POLICY_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_verdict := upper(btrim(coalesce(p_result ->> 'verdict', '')));
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'POLICY_VERDICT_INVALID: %', coalesce(p_result ->> 'verdict', '(empty)');
    end if;
    -- A finding of MEDIUM or HIGH severity fails the gate whatever the
    -- stated verdict.
    if jsonb_typeof(p_result -> 'findings') = 'array' and exists (
        select 1 from jsonb_array_elements(p_result -> 'findings') f
        where upper(coalesce(f ->> 'severity', '')) in ('MEDIUM', 'HIGH'))
    then
        v_verdict := 'FAIL';
    end if;

    v_step := case p_gate_no when 1 then 8 else 33 end;
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, v_step);

    insert into public.policy_checks (job_id, gate_no, checker, verdict, categories, result)
    values (p_job_id, p_gate_no, 'CLAUDE', v_verdict,
            case when jsonb_typeof(p_result -> 'categories') = 'array'
                 then p_result -> 'categories' else '[]'::jsonb end,
            p_result);
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'POLICY_GATE_' || p_gate_no);

    if v_verdict = 'PASS' then
        perform m417_internal.set_step(
            p_job_id, v_step + 1, 'POLICY_GATE_PASSED', jsonb_build_object('gate_no', p_gate_no));
    elsif p_gate_no = 1 then
        update public.production_jobs
        set topic_retry_count = topic_retry_count + 1,
            topic_feedback = coalesce(topic_feedback, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'topic', m417_internal.artifact(p_job_id, 'TOPIC_SELECTION') -> 'title',
                'findings', p_result -> 'findings',
                'required_changes', p_result -> 'required_changes'))
        where id = p_job_id
        returning topic_retry_count into v_retries;
        if v_retries > m417_internal.num('max_topic_retries', 2) then
            -- Stopped at topic selection, so a resumed job picks a new topic
            -- instead of re-checking the rejected one.
            update public.production_jobs set current_step = 7 where id = p_job_id;
            perform m417_internal.block_job(p_job_id, 'POLICY_GATE_1_FAILED', p_result::text);
        else
            perform m417_internal.set_step(
                p_job_id, 7, 'TOPIC_REJECTED_BY_POLICY', jsonb_build_object('retry_no', v_retries));
        end if;
    else
        perform m417_internal.block_job(p_job_id, 'POLICY_GATE_2_FAILED', p_result::text);
    end if;

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('gate_no', p_gate_no, 'verdict', v_verdict);
end;
$function$;

-- ----- step 9 -------------------------------------------------------
create or replace function public.get_series_bible(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_bible jsonb;
begin
    v_job := m417_internal.lock_job(p_job_id);
    v_bible := m417_internal.series_bible(p_job_id);
    if jsonb_array_length(v_bible -> 'characters') = 0 then
        raise exception 'SERIES_HAS_NO_LOCKED_CHARACTERS';
    end if;
    if v_job.current_step = 9 then
        perform m417_internal.require_step(v_job, 9);
        perform m417_internal.set_step(p_job_id, 10, 'SERIES_BIBLE_LOADED');
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('series_bible_text', v_bible::text);
end;
$function$;

-- ----- step 13 ------------------------------------------------------
create or replace function public.route_revision(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_report jsonb;
    v_verdict text;
    v_ok boolean;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 13);
    v_report := m417_internal.artifact(p_job_id, 'PREQC_REPORT');
    if v_report is null then
        raise exception 'PREQC_REPORT_MISSING';
    end if;
    v_verdict := upper(btrim(v_report ->> 'verdict'));
    -- A PASS that still lists a MEDIUM or HIGH issue is not a pass.
    if v_verdict = 'PASS'
       and jsonb_typeof(v_report -> 'issues') = 'array'
       and exists (
           select 1 from jsonb_array_elements(v_report -> 'issues') i
           where upper(coalesce(i ->> 'severity', '')) in ('MEDIUM', 'HIGH'))
    then
        v_verdict := case when exists (
                select 1 from jsonb_array_elements(v_report -> 'issues') i
                where upper(coalesce(i ->> 'severity', '')) in ('MEDIUM', 'HIGH')
                  and upper(coalesce(i ->> 'target', '')) = 'SCRIPT')
            then 'REVISE_SCRIPT' else 'REVISE_SHOTS' end;
    end if;

    if v_verdict = 'PASS' then
        update public.production_jobs set revision_feedback = null where id = p_job_id;
        perform m417_internal.set_step(p_job_id, 14, 'PREQC_PASSED');
    elsif v_verdict = 'REVISE_SCRIPT' then
        v_ok := m417_internal.open_revision(p_job_id, 10, v_report, 'GEMINI_PREQC');
    else
        v_ok := m417_internal.open_revision(p_job_id, 11, v_report, 'GEMINI_PREQC');
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('verdict', v_verdict,
                              'next_step', (m417_internal.job_status(p_job_id) ->> 'step_no')::integer);
end;
$function$;

-- ----- step 14 ------------------------------------------------------
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
    end if;

    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;

    insert into public.director_decisions (
        job_id, episode_id, production_version, stage, decision, actor, notes, result)
    values (
        p_job_id, v_job.episode_id, v_version, 'PRODUCTION', v_decision, 'CLAUDE',
        p_result ->> 'director_notes', p_result)
    returning id into v_decision_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');

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
