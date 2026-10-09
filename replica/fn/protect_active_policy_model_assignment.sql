CREATE OR REPLACE FUNCTION public.protect_active_policy_model_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_policy_id uuid;
    v_policy_status text;

BEGIN

    IF TG_OP = 'DELETE' THEN
        v_policy_id := OLD.policy_id;
    ELSE
        v_policy_id := NEW.policy_id;
    END IF;


    SELECT grp.status
    INTO v_policy_status

    FROM public.generation_routing_policies grp

    WHERE grp.id = v_policy_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_FOUND';
    END IF;


    IF v_policy_status = 'ACTIVE' THEN

        RAISE EXCEPTION
            'ACTIVE_ROUTING_POLICY_MODEL_ASSIGNMENTS_IMMUTABLE';

    END IF;


    -- Prevent moving an existing assignment away from
    -- an ACTIVE old policy.

    IF TG_OP = 'UPDATE'
       AND NEW.policy_id IS DISTINCT FROM OLD.policy_id
    THEN

        SELECT grp.status
        INTO v_policy_status

        FROM public.generation_routing_policies grp

        WHERE grp.id = OLD.policy_id;


        IF v_policy_status = 'ACTIVE' THEN

            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_MODEL_ASSIGNMENTS_IMMUTABLE';

        END IF;

    END IF;


    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;


    RETURN NEW;

END;

$function$
