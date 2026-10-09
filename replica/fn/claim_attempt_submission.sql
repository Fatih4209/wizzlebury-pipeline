CREATE OR REPLACE FUNCTION public.claim_attempt_submission(p_attempt_id uuid, p_claimed_by text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, decision text, claimed_at timestamp with time zone, provider text, model text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_claimed_at timestamptz;
    v_provider text;
    v_model text;
    v_generation_enabled boolean;
begin

    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;


    select
        a.status,
        a.submission_claimed_at,
        a.provider,
        a.model
    into
        v_status,
        v_claimed_at,
        v_provider,
        v_model
    from public.attempts a
    where a.id = p_attempt_id
    for update;

    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;


    if v_status in ('SUBMITTED', 'GENERATING') then

        return query
        select p_attempt_id, 'ALREADY_SUBMITTED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;

    end if;


    if v_status <> 'BUDGET_RESERVED' then

        return query
        select p_attempt_id, 'ALREADY_FINALIZED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;

    end if;


    if v_claimed_at is not null then

        return query
        select p_attempt_id, 'ALREADY_CLAIMED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;

    end if;


    -- The kill switch may have been closed after the reservation.
    select sf.value
    into v_generation_enabled
    from public.system_flags sf
    where sf.key = 'generation_enabled';

    if not found then
        raise exception 'GENERATION_FLAG_MISSING';
    end if;

    if v_generation_enabled is not true then
        raise exception 'GENERATION_DISABLED';
    end if;


    v_claimed_at := now();

    update public.attempts
    set
        submission_claimed_at = v_claimed_at,
        submission_claimed_by = p_claimed_by
    where id = p_attempt_id;


    return query
    select p_attempt_id, 'CLAIMED'::text,
           v_claimed_at, v_provider, v_model, v_status;

end;
$function$
