CREATE OR REPLACE FUNCTION public.sync_shot_state_from_output()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_attempt_status text;
begin

    select s.state
    into v_state
    from public.shots s
    where s.id = new.shot_id
    for update;

    select a.status
    into v_attempt_status
    from public.attempts a
    where a.id = new.attempt_id;


    if v_state = 'GENERATED'
       and v_attempt_status = 'SUCCEEDED'
       and new.qc_status in ('PENDING', 'IN_REVIEW')
    then
        update public.shots
        set state = 'QC_PENDING'
        where id = new.shot_id;
    end if;

    return new;

end;
$function$
