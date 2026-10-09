CREATE OR REPLACE FUNCTION public.protect_attempt_routing_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF NEW.shot_id
           IS DISTINCT FROM OLD.shot_id

       OR NEW.attempt_no
           IS DISTINCT FROM OLD.attempt_no

       OR NEW.idempotency_key
           IS DISTINCT FROM OLD.idempotency_key

       OR NEW.provider
           IS DISTINCT FROM OLD.provider

       OR NEW.model
           IS DISTINCT FROM OLD.model

       OR NEW.prompt_version
           IS DISTINCT FROM OLD.prompt_version

       OR NEW.model_version
           IS DISTINCT FROM OLD.model_version

       OR NEW.estimated_cost
           IS DISTINCT FROM OLD.estimated_cost

       OR NEW.routing_decision_id
           IS DISTINCT FROM OLD.routing_decision_id

       OR NEW.monthly_budget_id
           IS DISTINCT FROM OLD.monthly_budget_id

       OR NEW.episode_budget_id
           IS DISTINCT FROM OLD.episode_budget_id

       OR NEW.shot_budget_id
           IS DISTINCT FROM OLD.shot_budget_id

    THEN

        RAISE EXCEPTION
            'ATTEMPT_ROUTING_IDENTITY_IMMUTABLE';

    END IF;


    RETURN NEW;

END;
$function$
