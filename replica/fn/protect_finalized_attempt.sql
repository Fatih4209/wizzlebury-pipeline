CREATE OR REPLACE FUNCTION public.protect_finalized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if old.status in (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED',
        'ESCALATED'
    ) then

        if
            new.shot_id is distinct from old.shot_id
            or new.attempt_no is distinct from old.attempt_no
            or new.idempotency_key is distinct from old.idempotency_key
            or new.provider is distinct from old.provider
            or new.model is distinct from old.model
            or new.prompt_version is distinct from old.prompt_version
            or new.model_version is distinct from old.model_version
            or new.estimated_cost is distinct from old.estimated_cost
            or new.actual_cost is distinct from old.actual_cost
        then
            raise exception 'FINALIZED_ATTEMPT_IMMUTABLE';
        end if;

    end if;

    return new;

end;
$function$
