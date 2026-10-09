CREATE OR REPLACE FUNCTION public.require_attempt_acquisition_path()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if coalesce(
           current_setting('m417.attempt_acquisition', true),
           'off'
       ) <> 'on'
    then
        raise exception 'ATTEMPT_INSERT_REQUIRES_ACQUIRE_FUNCTION';
    end if;

    if new.status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_INSERT_REQUIRES_BUDGET_RESERVED: %',
            new.status;
    end if;

    if new.submission_claimed_at is not null
       or new.provider_job_id is not null
       or new.actual_cost is not null
    then
        raise exception 'ATTEMPT_INSERT_MUST_BE_UNSUBMITTED';
    end if;

    return new;

end;
$function$
