CREATE OR REPLACE FUNCTION public.mark_attempt_submitted(p_attempt_id uuid, p_provider_job_id text)
 RETURNS TABLE(attempt_id uuid, status text, provider_job_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_current_status text;
    v_current_job_id text;
    v_claimed_at timestamptz;
begin

    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;

    if p_provider_job_id is null
       or btrim(p_provider_job_id) = '' then
        raise exception 'PROVIDER_JOB_ID_REQUIRED';
    end if;


    select
        a.status,
        a.provider_job_id,
        a.submission_claimed_at
    into
        v_current_status,
        v_current_job_id,
        v_claimed_at
    from public.attempts a
    where a.id = p_attempt_id
    for update;

    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;


    -- Repeating the same call is harmless.
    if v_current_status in ('SUBMITTED', 'GENERATING')
       and v_current_job_id = p_provider_job_id
    then

        return query
        select p_attempt_id, v_current_status, v_current_job_id;
        return;

    end if;


    if v_current_status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_NOT_READY_FOR_SUBMISSION: %',
            v_current_status;
    end if;


    if v_claimed_at is null then
        raise exception 'ATTEMPT_SUBMISSION_NOT_CLAIMED';
    end if;


    update public.attempts
    set
        status = 'SUBMITTED',
        provider_job_id = p_provider_job_id,
        started_at = coalesce(started_at, now())
    where id = p_attempt_id;


    return query
    select
        p_attempt_id,
        'SUBMITTED'::text,
        p_provider_job_id;

end;
$function$
