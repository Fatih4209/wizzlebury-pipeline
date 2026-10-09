CREATE OR REPLACE FUNCTION public.enforce_settlement_source_state()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if new.status = 'SUCCEEDED'
       and old.status not in (
           'SUBMITTED',
           'GENERATING'
       )
    then
        raise exception
            'SUCCESS_REQUIRES_SUBMITTED_OR_GENERATING: %',
            old.status;
    end if;

    return new;

end;
$function$
