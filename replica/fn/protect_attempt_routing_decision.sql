CREATE OR REPLACE FUNCTION public.protect_attempt_routing_decision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF OLD.routing_decision_id IS NOT NULL
       AND NEW.routing_decision_id
            IS DISTINCT FROM OLD.routing_decision_id
    THEN

        RAISE EXCEPTION
            'ATTEMPT_ROUTING_DECISION_IMMUTABLE';

    END IF;


    RETURN NEW;

END;

$function$
