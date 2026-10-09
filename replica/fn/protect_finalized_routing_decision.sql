CREATE OR REPLACE FUNCTION public.protect_finalized_routing_decision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_supersession boolean;
BEGIN

    v_supersession :=
        COALESCE(
            current_setting(
                'm417.routing_supersession',
                true
            ),
            'off'
        ) = 'on';


    -- -----------------------------------------------------
    -- DELETE
    -- -----------------------------------------------------

    IF TG_OP = 'DELETE' THEN

        IF OLD.decision_status <> 'PENDING' THEN
            RAISE EXCEPTION
                'FINALIZED_ROUTING_DECISION_CANNOT_BE_DELETED';
        END IF;

        RETURN OLD;

    END IF;


    -- -----------------------------------------------------
    -- FINALIZED DECISION
    --
    -- Normally completely immutable.
    --
    -- Controlled exception:
    -- CURRENT -> HISTORICAL only.
    -- No other field may change.
    -- -----------------------------------------------------

    IF OLD.decision_status <> 'PENDING' THEN

        IF v_supersession IS TRUE
           AND OLD.is_current IS TRUE
           AND NEW.is_current IS FALSE

           AND NEW.id
                IS NOT DISTINCT FROM OLD.id

           AND NEW.shot_id
                IS NOT DISTINCT FROM OLD.shot_id

           AND NEW.shot_specification_id
                IS NOT DISTINCT FROM OLD.shot_specification_id

           AND NEW.policy_id
                IS NOT DISTINCT FROM OLD.policy_id

           AND NEW.attempt_no
                IS NOT DISTINCT FROM OLD.attempt_no

           AND NEW.decision_revision
                IS NOT DISTINCT FROM OLD.decision_revision

           AND NEW.decision_status
                IS NOT DISTINCT FROM OLD.decision_status

           AND NEW.decision_reason
                IS NOT DISTINCT FROM OLD.decision_reason

           AND NEW.selected_model_id
                IS NOT DISTINCT FROM OLD.selected_model_id

           AND NEW.selected_pricing_id
                IS NOT DISTINCT FROM OLD.selected_pricing_id

           AND NEW.route_role
                IS NOT DISTINCT FROM OLD.route_role

           AND NEW.estimated_cost
                IS NOT DISTINCT FROM OLD.estimated_cost

           AND NEW.candidate_scores
                IS NOT DISTINCT FROM OLD.candidate_scores

           AND NEW.created_at
                IS NOT DISTINCT FROM OLD.created_at
        THEN

            RETURN NEW;

        END IF;


        RAISE EXCEPTION
            'FINALIZED_ROUTING_DECISION_IMMUTABLE';

    END IF;


    -- -----------------------------------------------------
    -- PENDING IDENTITY IMMUTABLE
    -- -----------------------------------------------------

    IF NEW.shot_id
            IS DISTINCT FROM OLD.shot_id

       OR NEW.shot_specification_id
            IS DISTINCT FROM OLD.shot_specification_id

       OR NEW.policy_id
            IS DISTINCT FROM OLD.policy_id

       OR NEW.attempt_no
            IS DISTINCT FROM OLD.attempt_no

       OR NEW.decision_revision
            IS DISTINCT FROM OLD.decision_revision

       OR NEW.is_current
            IS DISTINCT FROM OLD.is_current
    THEN

        RAISE EXCEPTION
            'ROUTING_DECISION_IDENTITY_IMMUTABLE';

    END IF;


    -- -----------------------------------------------------
    -- VALID STATES
    -- -----------------------------------------------------

    IF NEW.decision_status NOT IN (
        'PENDING',
        'SELECTED',
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN

        RAISE EXCEPTION
            'INVALID_ROUTING_DECISION_STATUS: %',
            NEW.decision_status;

    END IF;


    -- -----------------------------------------------------
    -- SELECTED COMPLETENESS
    -- -----------------------------------------------------

    IF NEW.decision_status = 'SELECTED' THEN

        IF NEW.selected_model_id IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_MODEL';
        END IF;

        IF NEW.selected_pricing_id IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_PRICING';
        END IF;

        IF NEW.route_role IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_ROUTE_ROLE';
        END IF;

        IF NEW.estimated_cost IS NULL
           OR NEW.estimated_cost < 0
        THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_INVALID_COST';
        END IF;

    END IF;


    -- -----------------------------------------------------
    -- BLOCKED DECISION CANNOT CONTAIN SELECTED ROUTE
    -- -----------------------------------------------------

    IF NEW.decision_status IN (
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN

        IF NEW.selected_model_id IS NOT NULL
           OR NEW.selected_pricing_id IS NOT NULL
           OR NEW.route_role IS NOT NULL
        THEN

            RAISE EXCEPTION
                'BLOCKED_ROUTING_DECISION_CANNOT_SELECT_ROUTE';

        END IF;

    END IF;


    RETURN NEW;

END;
$function$
