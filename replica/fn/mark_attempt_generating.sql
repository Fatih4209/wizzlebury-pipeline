CREATE OR REPLACE FUNCTION public.mark_attempt_generating(p_attempt_id uuid)
 RETURNS TABLE(attempt_id uuid, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_current_status text;
begin

    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;


    select a.status
    into v_current_status
    from public.attempts a
    where a.id = p_attempt_id
    for update;

    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;


    if v_current_status <> 'SUBMITTED' then
        raise exception
            'ATTEMPT_NOT_READY_FOR_GENERATION: %',
            v_current_status;
    end if;


    update public.attempts
    set status = 'GENERATING'
    where id = p_attempt_id;


    return query
    select
        p_attempt_id,
        'GENERATING'::text;

end;
$function$
