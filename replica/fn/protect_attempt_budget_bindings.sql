CREATE OR REPLACE FUNCTION public.protect_attempt_budget_bindings()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF NEW.monthly_budget_id
       IS DISTINCT FROM OLD.monthly_budget_id
       OR NEW.episode_budget_id
       IS DISTINCT FROM OLD.episode_budget_id
       OR NEW.shot_budget_id
       IS DISTINCT FROM OLD.shot_budget_id
    THEN
        RAISE EXCEPTION
            'ATTEMPT_BUDGET_BINDINGS_IMMUTABLE';
    END IF;

    RETURN NEW;

END;
$function$
