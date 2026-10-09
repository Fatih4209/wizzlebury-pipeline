CREATE OR REPLACE FUNCTION public.find_stuck_attempts(p_stale_minutes integer DEFAULT 30)
 RETURNS TABLE(attempt_id uuid, shot_id uuid, provider text, provider_job_id text, status text, last_activity timestamp with time zone, submission_claimed_at timestamp with time zone, recommended_action text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

    select
        x.id,
        x.shot_id,
        x.provider,
        x.provider_job_id,
        x.status,
        x.last_activity,
        x.submission_claimed_at,
        case
            when x.status = 'BUDGET_RESERVED'
             and x.submission_claimed_at is null
                then 'RESUME_SUBMISSION'
            when x.status = 'BUDGET_RESERVED'
                then 'RECONCILE_SUBMISSION'
            else 'POLL_PROVIDER'
        end

    from (

        select
            a.id,
            a.shot_id,
            a.provider,
            a.provider_job_id,
            a.status,
            a.submission_claimed_at,
            greatest(
                coalesce(a.heartbeat_at, '-infinity'::timestamptz),
                coalesce(a.last_provider_check_at, '-infinity'::timestamptz),
                coalesce(a.started_at, '-infinity'::timestamptz),
                coalesce(a.submission_claimed_at, '-infinity'::timestamptz),
                a.created_at
            ) as last_activity

        from public.attempts a

        where a.status in (
            'BUDGET_RESERVED',
            'SUBMITTED',
            'GENERATING'
        )

    ) x

    where x.last_activity
          < now() - make_interval(mins => p_stale_minutes)

    order by x.last_activity;

$function$
