
-- =====================================================================
-- 10. RPC: S9 learning, maintenance, administration
-- =====================================================================

-- ----- step 41 ------------------------------------------------------
create or replace function public.list_publications_for_analytics()
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object(
               'publication_id', p.id,
               'video_id', p.video_id,
               'snapshot_date', to_char((now() at time zone 'UTC')::date, 'YYYY-MM-DD'))
               order by p.published_at), '[]'::jsonb))
    from public.publications p
    where p.status = 'PUBLISHED'
      and p.video_id is not null
      and p.published_at > now() - make_interval(days => m417_internal.num('analytics_window_days', 90)::integer);
$function$;

-- Called up to twice a day per video: basic counts, then watch-time
-- figures. Values arrive as text; a missing value keeps what is stored.
create or replace function public.record_analytics_snapshot(
    p_publication_id uuid, p_snapshot_date date, p_metrics jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_m jsonb := coalesce(p_metrics, '{}'::jsonb);
begin
    if p_snapshot_date is null then
        raise exception 'SNAPSHOT_DATE_REQUIRED';
    end if;
    if jsonb_typeof(v_m) <> 'object' then
        raise exception 'METRICS_MUST_BE_JSON_OBJECT';
    end if;
    if not exists (select 1 from public.publications p where p.id = p_publication_id and p.status = 'PUBLISHED') then
        raise exception 'PUBLICATION_NOT_FOUND';
    end if;
    insert into public.analytics_snapshots as s (
        publication_id, snapshot_date, views, likes, comments, minutes_watched,
        average_view_duration_seconds, subscribers_gained, metrics)
    values (
        p_publication_id, p_snapshot_date,
        m417_internal.safe_numeric(v_m ->> 'views')::bigint,
        m417_internal.safe_numeric(v_m ->> 'likes')::bigint,
        m417_internal.safe_numeric(v_m ->> 'comments')::bigint,
        m417_internal.safe_numeric(v_m ->> 'minutes_watched'),
        m417_internal.safe_numeric(v_m ->> 'average_view_duration_seconds'),
        m417_internal.safe_numeric(v_m ->> 'subscribers_gained')::bigint,
        v_m)
    on conflict (publication_id, snapshot_date) do update
        set views = coalesce(excluded.views, s.views),
            likes = coalesce(excluded.likes, s.likes),
            comments = coalesce(excluded.comments, s.comments),
            minutes_watched = coalesce(excluded.minutes_watched, s.minutes_watched),
            average_view_duration_seconds = coalesce(excluded.average_view_duration_seconds, s.average_view_duration_seconds),
            subscribers_gained = coalesce(excluded.subscribers_gained, s.subscribers_gained),
            metrics = s.metrics || excluded.metrics,
            updated_at = now();
    return (
        select jsonb_build_object(
            'publication_id', s.publication_id, 'snapshot_date', s.snapshot_date,
            'views', s.views, 'likes', s.likes, 'comments', s.comments,
            'minutes_watched', s.minutes_watched,
            'average_view_duration_seconds', s.average_view_duration_seconds,
            'subscribers_gained', s.subscribers_gained)
        from public.analytics_snapshots s
        where s.publication_id = p_publication_id and s.snapshot_date = p_snapshot_date);
end;
$function$;

create or replace function public.episode_cost_summary(p_episode_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'episode_id', e.id,
        'content_id', e.content_id,
        'video_charged_usd', coalesce((
            select sum(cl.amount) from public.cost_ledger cl
            where cl.episode_id = e.id and cl.entry_type = 'SETTLE'), 0),
        'video_reserved_now_usd', coalesce((
            select b.reserved_amount from public.budgets b
            where b.budget_type = 'EPISODE' and b.reference_id = e.id
            order by b.created_at desc limit 1), 0),
        'episode_budget_usd', (
            select b.hard_limit from public.budgets b
            where b.budget_type = 'EPISODE' and b.reference_id = e.id
            order by b.created_at desc limit 1),
        'video_attempts', (
            select count(*) from public.attempts a
            join public.shots s on s.id = a.shot_id where s.episode_id = e.id),
        'service_usage', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'service', u.service, 'unit', u.unit, 'units', u.units, 'calls', u.calls,
                       'estimated_usd', u.estimated_usd) order by u.service)
            from (
                select su.service, su.unit, sum(su.units) as units, count(*) as calls,
                       round(sum(su.units) * max(sr.usd_per_unit), 4) as estimated_usd
                from public.service_usage su
                join public.production_jobs j on j.id = su.job_id
                left join public.service_rates sr on sr.service = su.service and sr.unit = su.unit
                where j.episode_id = e.id
                group by su.service, su.unit
            ) u), '[]'::jsonb),
        'note', 'video_charged_usd is recorded provider spend. estimated_usd is filled only for services with a row in service_rates.')
    from public.episodes e
    where e.id = p_episode_id;
$function$;

-- ----- step 42 ------------------------------------------------------
create or replace function public.weekly_learning_input()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    -- The report covers the seven days up to today, whenever it runs.
    v_week_end date := (now() at time zone 'UTC')::date;
    v_week_start date := v_week_end - 7;
    v_episodes jsonb;
    v_previous jsonb;
begin
    select coalesce(jsonb_agg(x.row order by x.published_at), '[]'::jsonb) into v_episodes
    from (
        select p.published_at,
               jsonb_build_object(
                   'title', pk.title,
                   'video_id', p.video_id,
                   'published_at', to_char(p.published_at at time zone 'UTC', 'YYYY-MM-DD'),
                   'topic', m417_internal.artifact(p.job_id, 'TOPIC_SELECTION') -> 'premise',
                   'hook', m417_internal.artifact(p.job_id, 'TOPIC_SELECTION') -> 'hook',
                   'characters', (
                       select coalesce(jsonb_agg(distinct c.value), '[]'::jsonb)
                       from public.shots s
                       join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                       cross join lateral jsonb_array_elements_text(ss.character_codes) c(value)
                       where s.episode_id = p.episode_id),
                   'shots', (select count(*) from public.shots s where s.episode_id = p.episode_id and s.state = 'LOCKED'),
                   'duration_seconds', (
                       select sum(ss.duration_seconds)
                       from public.shots s
                       join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                       where s.episode_id = p.episode_id and s.state = 'LOCKED'),
                   'latest', (
                       select jsonb_build_object(
                                  'as_of', s.snapshot_date, 'views', s.views, 'likes', s.likes, 'comments', s.comments,
                                  'minutes_watched', s.minutes_watched,
                                  'average_view_duration_seconds', s.average_view_duration_seconds,
                                  'subscribers_gained', s.subscribers_gained)
                       from public.analytics_snapshots s
                       where s.publication_id = p.id and s.snapshot_date <= v_week_end
                       order by s.snapshot_date desc limit 1),
                   'before_this_week', (
                       select jsonb_build_object('as_of', s.snapshot_date, 'views', s.views, 'likes', s.likes, 'comments', s.comments)
                       from public.analytics_snapshots s
                       where s.publication_id = p.id and s.snapshot_date < v_week_start
                       order by s.snapshot_date desc limit 1),
                   'production', public.episode_cost_summary(p.episode_id)
                                 - 'episode_id' - 'content_id' - 'note'
               ) as row
        from public.publications p
        join public.publication_packages pk on pk.id = p.package_id
        where p.status = 'PUBLISHED'
          and p.published_at > now() - interval '56 days'
    ) x;

    select jsonb_build_object('week_start', lr.week_start, 'headline', lr.report -> 'headline',
                              'recommendations', lr.report -> 'recommendations_for_next_topics')
    into v_previous
    from public.learning_reports lr
    where lr.week_start < v_week_start
    order by lr.week_start desc limit 1;

    return jsonb_build_object(
        'week_start', to_char(v_week_start, 'YYYY-MM-DD'),
        'input_text', jsonb_build_object(
            'week_start', v_week_start,
            'week_end', v_week_end,
            'episodes_published_last_8_weeks', v_episodes,
            'episode_count', jsonb_array_length(v_episodes),
            'previous_report', v_previous,
            'data_note', 'Numbers come from daily YouTube snapshots. A null means the value was not collected. before_this_week is the last snapshot taken before week_start; latest minus before_this_week is the change over the seven days. A missing before_this_week means the video is newer than the window.'
        )::text);
end;
$function$;

create or replace function public.save_learning_report(p_week_start date, p_report jsonb, p_model text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_summary text;
begin
    if p_week_start is null then
        raise exception 'WEEK_START_REQUIRED';
    end if;
    if p_report is null or jsonb_typeof(p_report) <> 'object' then
        raise exception 'REPORT_MUST_BE_JSON_OBJECT';
    end if;
    v_summary := coalesce(
        nullif(btrim(p_report ->> 'summary_for_owner_tr'), ''),
        nullif(btrim(p_report ->> 'headline'), ''),
        'Haftalık rapor kaydedildi.');
    v_summary := 'M417 / WIZZLEBURY haftalık rapor (' || to_char(p_week_start, 'DD.MM.YYYY') || E')\n\n' || v_summary;
    insert into public.learning_reports (week_start, report, model, summary)
    values (p_week_start, p_report, p_model, v_summary)
    on conflict (week_start) do update
        set report = excluded.report, model = excluded.model, summary = excluded.summary, updated_at = now();
    perform m417_internal.usage(null, 'CLAUDE', 'WEEKLY_REPORT');
    return jsonb_build_object(
        'week_start', p_week_start,
        'summary_text', left(v_summary, 3900),
        'notify_chat_id', m417_internal.txt('notify_chat_id', ''));
end;
$function$;

-- ----- maintenance --------------------------------------------------
-- The link that re-runs the scenario owning a job's current step.
create or replace function m417_internal.resume_url(p_job_id uuid, p_step integer)
 returns text language sql stable security definer set search_path to ''
as $function$
    select case
        when p_step between 6 and 15 then nullif(m417_internal.txt('webhook_s2', ''), '') || '?job_id=' || p_job_id
        when p_step between 16 and 21 then nullif(m417_internal.txt('webhook_s3', ''), '') || '?job_id=' || p_job_id
        when p_step between 22 and 29 then nullif(m417_internal.txt('webhook_s4_driver', ''), '') || '?source=manual'
        when p_step between 30 and 34 then nullif(m417_internal.txt('webhook_s6', ''), '') || '?job_id=' || p_job_id
        when p_step between 35 and 38 then nullif(m417_internal.txt('webhook_s7', ''), '') || '?job_id=' || p_job_id
        when p_step = 39 then nullif(m417_internal.txt('webhook_s8', ''), '') || '?job_id=' || p_job_id
    end;
$function$;

create or replace function public.pipeline_overview()
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'pipeline_enabled', m417_internal.flag('pipeline_enabled', false),
        'generation_enabled', m417_internal.flag('generation_enabled', false),
        'monthly_budget', (
            select jsonb_build_object('hard_limit', b.hard_limit, 'reserved', b.reserved_amount, 'settled', b.settled_amount,
                                      'available', b.hard_limit - b.reserved_amount - b.settled_amount)
            from public.budgets b
            where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
              and (b.period_start is null or b.period_start <= now())
              and (b.period_end is null or b.period_end > now())
            order by b.created_at desc limit 1),
        'jobs', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'job_id', j.id,
                       'content_id', e.content_id,
                       'title', e.title,
                       'episode_state', e.state,
                       'step_no', j.current_step,
                       'state', j.state,
                       'blocked_reason', j.blocked_reason,
                       'blocked_detail', j.blocked_detail,
                       'idle_minutes', floor(extract(epoch from (now() - j.last_activity_at)) / 60),
                       'resume_url', m417_internal.resume_url(j.id, j.current_step))
                   order by j.created_at desc)
            from (select * from public.production_jobs order by created_at desc limit 20) j
            join public.episodes e on e.id = j.episode_id), '[]'::jsonb));
$function$;

create or replace function public.daily_maintenance()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_lines text[] := array[]::text[];
    v_row record;
    v_idle integer := m417_internal.num('job_idle_alert_minutes', 30)::integer;
    v_n integer;
begin
    -- Approval links past their time are closed.
    update public.approval_requests
    set status = 'EXPIRED'
    where status = 'PENDING' and expires_at <= now();
    get diagnostics v_n = row_count;
    if v_n > 0 then
        v_lines := v_lines || format('%s onay bağlantısının süresi doldu.', v_n);
    end if;

    for v_row in
        select j.id, j.current_step, j.state, j.blocked_reason, j.blocked_detail, e.content_id,
               floor(extract(epoch from (now() - j.last_activity_at)) / 60)::integer as idle_minutes
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        where j.state in ('READY', 'BLOCKED', 'WAITING_HUMAN')
        order by j.created_at
    loop
        if v_row.state = 'BLOCKED' then
            v_lines := v_lines || format(
                E'%s durdu (adım %s): %s\n%s',
                v_row.content_id, v_row.current_step, v_row.blocked_reason,
                left(coalesce(v_row.blocked_detail, ''), 300));
        elsif v_row.state = 'WAITING_HUMAN' then
            if not exists (
                select 1 from public.approval_requests ar
                join public.production_jobs j on j.episode_id = ar.scope_id
                where j.id = v_row.id and ar.scope_type = 'EPISODE_PUBLISH' and ar.status = 'PENDING')
            then
                v_lines := v_lines || format(
                    '%s yayın onayı bekliyordu ama geçerli bir onay bağlantısı kalmadı. Yeni bağlantı için işi sürdür.',
                    v_row.content_id);
            elsif v_row.idle_minutes > 24 * 60 then
                v_lines := v_lines || format('%s yayın onayını bekliyor (%s saattir).', v_row.content_id, v_row.idle_minutes / 60);
            end if;
        elsif v_row.current_step between 22 and 29 then
            if m417_internal.flag('generation_enabled', false) is not true then
                v_lines := v_lines || format('%s video adımında bekliyor: ücretli üretim kapalı.', v_row.content_id);
            elsif v_row.idle_minutes > greatest(v_idle, 60)
              and not exists (
                  select 1 from public.approval_requests ar
                  join public.shots s on s.id = ar.scope_id
                  join public.production_jobs j on j.episode_id = s.episode_id
                  where j.id = v_row.id and ar.scope_type = 'SHOT_ESCALATION' and ar.status = 'PENDING')
            then
                v_lines := v_lines || format(
                    E'%s video adımında %s dakikadır ilerlemiyor. Sürdür: %s',
                    v_row.content_id, v_row.idle_minutes, coalesce(m417_internal.resume_url(v_row.id, v_row.current_step), '-'));
            end if;
        elsif v_row.idle_minutes > v_idle then
            v_lines := v_lines || format(
                E'%s adım %s''te %s dakikadır bekliyor. Sürdür: %s',
                v_row.content_id, v_row.current_step, v_row.idle_minutes,
                coalesce(m417_internal.resume_url(v_row.id, v_row.current_step), '-'));
        end if;
    end loop;

    if m417_internal.flag('pipeline_enabled', false) and not exists (
        select 1 from public.budgets b
        where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
          and (b.period_start is null or b.period_start <= now())
          and (b.period_end is null or b.period_end > now()))
    then
        v_lines := v_lines || 'Bu dönem için aktif aylık bütçe yok; yeni bölüm başlatılamaz.'::text;
    end if;

    for v_row in select * from public.find_stuck_attempts(90)
    loop
        v_lines := v_lines || format(
            'Takılan video denemesi: %s, durum %s, önerilen işlem %s.',
            v_row.provider, v_row.status, v_row.recommended_action);
    end loop;

    select count(*) into v_n
    from public.approval_requests ar
    where ar.scope_type = 'SHOT_ESCALATION' and ar.status = 'PENDING' and ar.created_at < now() - interval '6 hours';
    if v_n > 0 then
        v_lines := v_lines || format('%s shot kararını bekliyor (Telegram''daki onay mesajı).', v_n);
    end if;

    return jsonb_build_object(
        'has_issues', cardinality(v_lines) > 0,
        'message_text', case when cardinality(v_lines) = 0 then ''
            else left(E'M417 / WIZZLEBURY bakım raporu\n\n' || array_to_string(v_lines, E'\n\n'), 3900) end,
        'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
        'issue_count', cardinality(v_lines));
end;
$function$;

-- ----- administration ----------------------------------------------
create or replace function public.set_pipeline_enabled(p_enabled boolean)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
begin
    if p_enabled is null then
        raise exception 'ENABLED_REQUIRED';
    end if;
    update public.system_flags set value = p_enabled where key = 'pipeline_enabled';
    if not found then
        raise exception 'PIPELINE_FLAG_MISSING';
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values (
        case when p_enabled then 'PIPELINE_ENABLED' else 'PIPELINE_DISABLED' end,
        case when p_enabled then 'INFO' else 'WARNING' end,
        'CONTROL_PLANE',
        case when p_enabled then 'Job pipeline enabled' else 'Job pipeline disabled' end,
        jsonb_build_object('enabled', p_enabled));
    return p_enabled;
end;
$function$;

-- Opens the budget for the current calendar month (UTC). Earlier
-- monthly budgets without open reservations are closed.
create or replace function public.open_monthly_budget(p_hard_limit_usd numeric, p_actor text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_start timestamptz := date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
    v_end timestamptz := (date_trunc('month', now() at time zone 'UTC') + interval '1 month') at time zone 'UTC';
    v_id uuid;
    v_spent numeric := 0;
begin
    if p_hard_limit_usd is null or p_hard_limit_usd <= 0 then
        raise exception 'HARD_LIMIT_REQUIRED';
    end if;
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if exists (
        select 1 from public.budgets b
        where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
          and b.reserved_amount > 0)
    then
        raise exception 'MONTHLY_BUDGET_HAS_OPEN_RESERVATIONS';
    end if;
    -- Money already charged this month counts against the new limit.
    select coalesce(sum(cl.amount), 0) into v_spent
    from public.cost_ledger cl
    where cl.entry_type = 'SETTLE' and cl.created_at >= v_start and cl.created_at < v_end;
    if v_spent > p_hard_limit_usd then
        raise exception 'LIMIT_BELOW_SPEND_THIS_MONTH: % already charged', v_spent;
    end if;
    update public.budgets
    set is_active = false
    where budget_type = 'MONTHLY' and reference_id is null and is_active = true;
    insert into public.budgets (budget_type, reference_id, currency, hard_limit, settled_amount, period_start, period_end, is_active)
    values ('MONTHLY', null, 'USD', p_hard_limit_usd, v_spent, v_start, v_end, true)
    returning id into v_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MONTHLY_BUDGET_OPENED', 'INFO', 'CONTROL_PLANE',
            'Monthly budget opened by ' || p_actor,
            jsonb_build_object('budget_id', v_id, 'hard_limit', p_hard_limit_usd, 'already_charged', v_spent,
                               'period_start', v_start, 'period_end', v_end));
    return jsonb_build_object('budget_id', v_id, 'hard_limit_usd', p_hard_limit_usd,
                              'already_charged_usd', v_spent,
                              'period_start', v_start, 'period_end', v_end);
end;
$function$;

-- The owner allows a video model to be used without a paid benchmark.
create or replace function public.approve_model_pilot(p_model_code text, p_actor text, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_model public.generation_models;
    v_id uuid;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select gm.* into v_model from public.generation_models gm where gm.model_code = p_model_code;
    if not found then
        raise exception 'MODEL_NOT_FOUND: %', coalesce(p_model_code, '(empty)');
    end if;
    select pa.id into v_id
    from public.generation_model_pilot_approvals pa
    where pa.model_id = v_model.id and pa.revoked_at is null;
    if found then
        return jsonb_build_object('approval_id', v_id, 'model_code', v_model.model_code, 'decision', 'ALREADY_APPROVED');
    end if;
    insert into public.generation_model_pilot_approvals (model_id, approved_by, note)
    values (v_model.id, p_actor, p_note)
    returning id into v_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MODEL_PILOT_APPROVED', 'WARNING', 'CONTROL_PLANE',
            'Video model approved for a pilot without a paid benchmark by ' || p_actor,
            jsonb_build_object('approval_id', v_id, 'model_id', v_model.id, 'model_code', v_model.model_code, 'note', p_note));
    return jsonb_build_object('approval_id', v_id, 'model_code', v_model.model_code, 'decision', 'APPROVED');
end;
$function$;

create or replace function public.revoke_model_pilot(p_model_code text, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_id uuid;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    update public.generation_model_pilot_approvals pa
    set revoked_at = now(), revoked_by = p_actor, revoke_reason = p_reason
    from public.generation_models gm
    where gm.id = pa.model_id and gm.model_code = p_model_code and pa.revoked_at is null
    returning pa.id into v_id;
    if v_id is null then
        return jsonb_build_object('model_code', p_model_code, 'decision', 'NO_ACTIVE_APPROVAL');
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MODEL_PILOT_REVOKED', 'WARNING', 'CONTROL_PLANE',
            'Pilot approval of a video model revoked by ' || p_actor,
            jsonb_build_object('approval_id', v_id, 'model_code', p_model_code, 'reason', p_reason));
    return jsonb_build_object('approval_id', v_id, 'model_code', p_model_code, 'decision', 'REVOKED');
end;
$function$;

-- The owner names the public copy of a canonical reference image.
-- p_object_path is the file's path inside the public bucket.
create or replace function public.set_video_reference(
    p_asset_code text, p_object_path text, p_actor text, p_bucket text default 'public-refs')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_path text := btrim(coalesce(p_object_path, ''));
    v_bucket text := btrim(coalesce(p_bucket, ''));
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select ar.id into v_asset_id
    from public.asset_registry ar
    where ar.asset_code = p_asset_code and ar.status = 'LOCKED'
    order by ar.version desc
    limit 1;
    if not found then
        raise exception 'LOCKED_ASSET_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    if v_path = '' or v_path ~ '^/' or v_path ~ '[[:space:]?#]' or v_bucket = '' or v_bucket ~ '[/[:space:]?#]' then
        raise exception 'REFERENCE_PATH_INVALID: %/%', v_bucket, v_path;
    end if;
    insert into public.video_reference_images (asset_id, bucket, object_path, is_active, set_by)
    values (v_asset_id, v_bucket, v_path, true, p_actor)
    on conflict (asset_id) do update
        set bucket = excluded.bucket, object_path = excluded.object_path, is_active = true,
            set_by = excluded.set_by, updated_at = now();
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_REFERENCE_SET', 'INFO', 'CONTROL_PLANE',
            'Public reference image set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'bucket', v_bucket, 'object_path', v_path));
    return jsonb_build_object(
        'asset_code', p_asset_code, 'decision', 'SET',
        'url', rtrim(m417_internal.txt('storage_base_url', ''), '/') || '/object/public/' || v_bucket || '/' || v_path);
end;
$function$;

create or replace function public.set_text_setting(p_key text, p_value text)
 returns text language plpgsql security definer set search_path to ''
as $function$
begin
    update public.system_text_settings
    set value = btrim(coalesce(p_value, '')), updated_at = now()
    where key = p_key;
    if not found then
        raise exception 'UNKNOWN_TEXT_SETTING: %', p_key;
    end if;
    if p_key = 'privacy_status' and lower(btrim(p_value)) not in ('private', 'unlisted', 'public') then
        raise exception 'PRIVACY_STATUS_INVALID: %', p_value;
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('SETTING_CHANGED', 'INFO', 'CONTROL_PLANE', 'Text setting changed: ' || p_key,
            jsonb_build_object('key', p_key));
    return btrim(coalesce(p_value, ''));
end;
$function$;

create or replace function public.set_numeric_setting(p_key text, p_value numeric)
 returns numeric language plpgsql security definer set search_path to ''
as $function$
begin
    if p_value is null then
        raise exception 'VALUE_REQUIRED';
    end if;
    update public.system_settings
    set value_numeric = p_value, updated_at = now()
    where key = p_key;
    if not found then
        raise exception 'UNKNOWN_NUMERIC_SETTING: %', p_key;
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('SETTING_CHANGED', 'INFO', 'CONTROL_PLANE', 'Numeric setting changed: ' || p_key,
            jsonb_build_object('key', p_key, 'value', p_value));
    return p_value;
end;
$function$;

create or replace function public.resume_production_job(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state not in ('BLOCKED', 'WAITING_HUMAN') then
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('decision', 'NOT_STOPPED',
                                  'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
    end if;
    -- A job stopped by a counter gets a fresh count; the cause is in the log.
    update public.production_jobs
    set revision_count = case when v_job.blocked_reason = 'REVISION_LIMIT_REACHED' then 0 else revision_count end,
        validation_retry_count = case when v_job.blocked_reason = 'VALIDATION_RETRY_LIMIT_REACHED' then 0 else validation_retry_count end,
        topic_retry_count = case when v_job.blocked_reason = 'POLICY_GATE_1_FAILED' then 0 else topic_retry_count end,
        -- The watchdog starts the job on its next round; no link to click.
        kick_requested = true,
        watchdog_resumes = 0
    where id = p_job_id;
    perform m417_internal.set_step(
        p_job_id, v_job.current_step, 'RESUMED',
        jsonb_build_object('actor', p_actor, 'reason', p_reason,
                           'previous_state', v_job.state, 'previous_block', v_job.blocked_reason));
    perform m417_internal.event(
        'JOB_RESUMED', 'WARNING', 'Job resumed by ' || p_actor || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step, 'previous_block', v_job.blocked_reason),
        v_job.episode_id);
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', 'RESUMED',
                              'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
end;
$function$;

create or replace function public.cancel_production_job(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_state text;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state in ('DONE', 'CANCELLED') then
        return m417_internal.job_status(p_job_id) || jsonb_build_object('decision', 'ALREADY_FINISHED');
    end if;
    -- Money that is reserved or with a provider must be settled first.
    if exists (
        select 1 from public.attempts a
        join public.shots s on s.id = a.shot_id
        where s.episode_id = v_job.episode_id
          and a.status in ('BUDGET_RESERVED', 'SUBMITTED', 'GENERATING'))
    then
        raise exception 'JOB_HAS_ACTIVE_VIDEO_ATTEMPTS';
    end if;
    if exists (select 1 from public.publications p where p.job_id = p_job_id) then
        raise exception 'JOB_HAS_A_PUBLICATION_CLAIM';
    end if;
    select e.state into v_state from public.episodes e where e.id = v_job.episode_id;
    if v_state not in ('PUBLISHED', 'CANCELLED') then
        update public.episodes set state = 'CANCELLED' where id = v_job.episode_id;
    end if;
    update public.budgets set is_active = false
    where reserved_amount = 0
      and ((budget_type = 'EPISODE' and reference_id = v_job.episode_id)
        or (budget_type = 'SHOT' and reference_id in (
               select s.id from public.shots s where s.episode_id = v_job.episode_id)));
    perform m417_internal.set_step(
        p_job_id, v_job.current_step, 'CANCELLED',
        jsonb_build_object('actor', p_actor, 'reason', p_reason), 'CANCELLED');
    perform m417_internal.event(
        'JOB_CANCELLED', 'WARNING', 'Job cancelled by ' || p_actor || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step), v_job.episode_id);
    return m417_internal.job_status(p_job_id) || jsonb_build_object('decision', 'CANCELLED');
end;
$function$;

-- A review link that never reached the owner is replaced by a new one
-- on the next video tick.
create or replace function public.reissue_shot_review(p_shot_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_n integer;
begin
    update public.approval_requests
    set status = 'SUPERSEDED'
    where scope_type = 'SHOT_ESCALATION' and scope_id = p_shot_id and status = 'PENDING';
    get diagnostics v_n = row_count;
    return jsonb_build_object('superseded', v_n);
end;
$function$;

-- After a failed YouTube upload: frees the claim so step 39 can run again.
create or replace function public.reset_publication_claim(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_pub public.publications;
begin
    if p_actor is null or btrim(p_actor) = '' or p_reason is null or btrim(p_reason) = '' then
        raise exception 'ACTOR_AND_REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    select p.* into v_pub from public.publications p where p.job_id = p_job_id for update;
    if not found then
        return jsonb_build_object('decision', 'NO_CLAIM');
    end if;
    if v_pub.status = 'PUBLISHED' then
        raise exception 'PUBLICATION_ALREADY_PUBLISHED';
    end if;
    delete from public.publications where id = v_pub.id;
    perform m417_internal.event(
        'PUBLICATION_CLAIM_RESET', 'WARNING',
        'Publication claim reset by ' || p_actor || ': ' || p_reason || '. Check the channel for a duplicate upload first.',
        jsonb_build_object('job_id', p_job_id), v_job.episode_id);
    return jsonb_build_object('decision', 'CLAIM_RESET',
                              'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
end;
$function$;

-- Adds a track to the licensed library. Registering a track is the
-- owner's statement that the licence covers this use.
create or replace function public.register_music_track(
    p_track_code text, p_title text, p_role text, p_storage_path text,
    p_license_type text, p_verified_by text,
    p_license_url text default null, p_duration_seconds numeric default null, p_mood text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_id uuid;
begin
    if coalesce(btrim(p_track_code), '') = '' or coalesce(btrim(p_title), '') = ''
       or coalesce(btrim(p_storage_path), '') = '' or coalesce(btrim(p_license_type), '') = ''
       or coalesce(btrim(p_verified_by), '') = ''
    then
        raise exception 'TRACK_CODE_TITLE_PATH_LICENSE_AND_VERIFIER_REQUIRED';
    end if;
    if upper(btrim(p_role)) not in ('MUSIC', 'SFX') then
        raise exception 'TRACK_ROLE_INVALID: %', p_role;
    end if;
    if m417_internal.object_size(btrim(p_storage_path)) is null then
        raise exception 'TRACK_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;
    insert into public.music_tracks (
        track_code, title, role, mood, storage_path, duration_seconds, license_type, license_url,
        license_status, license_checked_by, license_checked_at)
    values (
        upper(btrim(p_track_code)), btrim(p_title), upper(btrim(p_role)), p_mood, btrim(p_storage_path),
        p_duration_seconds, btrim(p_license_type), p_license_url, 'VERIFIED', btrim(p_verified_by), now())
    on conflict (track_code) do update
        set title = excluded.title, role = excluded.role, mood = excluded.mood,
            storage_path = excluded.storage_path, duration_seconds = excluded.duration_seconds,
            license_type = excluded.license_type, license_url = excluded.license_url,
            license_status = 'VERIFIED', license_checked_by = excluded.license_checked_by,
            license_checked_at = now(), is_active = true
    returning id into v_id;
    return jsonb_build_object('track_id', v_id, 'track_code', upper(btrim(p_track_code)), 'license_status', 'VERIFIED');
end;
$function$;
