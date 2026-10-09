CREATE OR REPLACE FUNCTION public.touch_attempt_heartbeat(p_attempt_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin

    update public.attempts
    set heartbeat_at = now()
    where id = p_attempt_id
      and status in ('SUBMITTED','GENERATING');

    if not found then
        raise exception 'ACTIVE_ATTEMPT_NOT_FOUND';
    end if;

end;
$function$
