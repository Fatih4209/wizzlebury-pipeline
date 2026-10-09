CREATE OR REPLACE FUNCTION public.reset_attempt_submission_claim(p_attempt_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(attempt_id uuid, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_shot_id uuid;
    v_claimed_at timestamptz;
begin

    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;

    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;


    select a.status, a.shot_id, a.submission_claimed_at
    into v_status, v_shot_id, v_claimed_at
    from public.attempts a
    where a.id = p_attempt_id
    for update;

    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;

    if v_status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_CLAIM_NOT_RESETTABLE: %',
            v_status;
    end if;

    if v_claimed_at is null then

        return query
        select p_attempt_id, 'NOT_CLAIMED'::text;
        return;

    end if;


    update public.attempts
    set
        submission_claimed_at = null,
        submission_claimed_by = null
    where id = p_attempt_id;


    insert into public.events (
        event_type,
        shot_id,
        attempt_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'ATTEMPT_SUBMISSION_CLAIM_RESET',
        v_shot_id,
        p_attempt_id,
        'WARNING',
        'RECOVERY',
        'Submission claim reset after reconciliation.',
        jsonb_build_object(
            'actor', p_actor,
            'reason', p_reason,
            'previous_claimed_at', v_claimed_at
        )
    );


    return query
    select p_attempt_id, 'CLAIM_RESET'::text;

end;
$function$
