CREATE OR REPLACE FUNCTION public.validate_attempt_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if new.status = old.status then
        return new;
    end if;


    -- Final states are terminal.
    if old.status in (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED',
        'ESCALATED'
    ) then
        raise exception
            'FINAL_ATTEMPT_STATUS_IS_IMMUTABLE: %',
            old.status;
    end if;


    -- A paid reservation can only be created by
    -- acquire_generation_attempt_v2 (INSERT as BUDGET_RESERVED).
    if old.status = 'CREATED'
       and new.status = 'BUDGET_RESERVED'
    then
        raise exception 'ATTEMPT_MUST_BE_ACQUIRED_VIA_ROUTER';
    end if;


    if not (

        (old.status = 'CREATED'
            and new.status = 'CANCELLED')

        or

        (old.status = 'BUDGET_RESERVED'
            and new.status in (
                'SUBMITTED',
                'FAILED',
                'CANCELLED'
            ))

        or

        (old.status = 'SUBMITTED'
            and new.status in (
                'GENERATING',
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))

        or

        (old.status = 'GENERATING'
            and new.status in (
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))

    ) then

        raise exception
            'INVALID_ATTEMPT_STATUS_TRANSITION: % -> %',
            old.status,
            new.status;

    end if;


    return new;

end;
$function$
