CREATE OR REPLACE FUNCTION public.protect_active_generation_routing_policy()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    -- -----------------------------------------------------
    -- DELETE ACTIVE POLICY
    -- -----------------------------------------------------

    IF TG_OP = 'DELETE' THEN

        IF OLD.status = 'ACTIVE' THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_CANNOT_BE_DELETED';
        END IF;

        RETURN OLD;

    END IF;


    -- -----------------------------------------------------
    -- ACTIVE POLICY IS IMMUTABLE
    -- -----------------------------------------------------

    IF OLD.status = 'ACTIVE' THEN
        RAISE EXCEPTION
            'ACTIVE_ROUTING_POLICY_IMMUTABLE';
    END IF;


    -- -----------------------------------------------------
    -- ACTIVATION REQUIREMENTS
    -- -----------------------------------------------------

    IF NEW.status = 'ACTIVE' THEN

        IF NEW.approved_at IS NULL THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_REQUIRES_APPROVED_AT';
        END IF;


        IF abs(
            (
                NEW.quality_weight
                + NEW.cost_weight
                + NEW.reliability_weight
                + NEW.latency_weight
            ) - 1.0
        ) > 0.000001
        THEN
            RAISE EXCEPTION
                'ROUTING_POLICY_WEIGHTS_MUST_SUM_TO_ONE';
        END IF;


        IF NEW.max_attempts NOT BETWEEN 1 AND 2 THEN
            RAISE EXCEPTION
                'ROUTING_POLICY_MAX_ATTEMPTS_INVALID';
        END IF;


        -- Must have at least one enabled PRIMARY model.

        IF NOT EXISTS (

            SELECT 1

            FROM public.generation_policy_models gpm

            WHERE gpm.policy_id = NEW.id
              AND gpm.enabled = true
              AND gpm.route_role = 'PRIMARY'

        )
        THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_REQUIRES_PRIMARY_MODEL';
        END IF;

    END IF;


    RETURN NEW;

END;

$function$
