CREATE OR REPLACE FUNCTION public.supersede_routing_decision(p_decision_id uuid)
 RETURNS TABLE(superseded_decision_id uuid, shot_id uuid, attempt_no integer, next_revision integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_attempt_no integer;
    v_revision integer;
    v_status text;
    v_is_current boolean;
BEGIN

    IF p_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ID_REQUIRED';
    END IF;


    SELECT
        grd.shot_id,
        grd.attempt_no,
        grd.decision_revision,
        grd.decision_status,
        grd.is_current

    INTO
        v_shot_id,
        v_attempt_no,
        v_revision,
        v_status,
        v_is_current

    FROM public.generation_routing_decisions grd

    WHERE grd.id = p_decision_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_FOUND';
    END IF;


    -- -----------------------------------------------------
    -- SELECTED decisions cannot be superseded here.
    --
    -- Their runtime safety is handled by acquisition
    -- fresh-health / pricing / provider gates.
    -- -----------------------------------------------------

    IF v_status = 'SELECTED' THEN
        RAISE EXCEPTION
            'SELECTED_ROUTING_DECISION_CANNOT_BE_SUPERSEDED';
    END IF;


    IF v_status NOT IN (
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_REEVALUATABLE: %',
            v_status;
    END IF;


    IF v_is_current IS NOT TRUE THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ALREADY_SUPERSEDED';
    END IF;


    -- -----------------------------------------------------
    -- Ensure no paid attempt already references this
    -- routing decision.
    -- -----------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.attempts a
        WHERE a.routing_decision_id = p_decision_id
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ALREADY_USED_BY_ATTEMPT';
    END IF;


    -- -----------------------------------------------------
    -- Controlled CURRENT -> HISTORICAL transition
    -- -----------------------------------------------------

    PERFORM set_config(
        'm417.routing_supersession',
        'on',
        true
    );


    UPDATE public.generation_routing_decisions
    SET is_current = false
    WHERE id = p_decision_id
      AND is_current = true;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_SUPERSESSION_FAILED';
    END IF;


    PERFORM set_config(
        'm417.routing_supersession',
        'off',
        true
    );


    RETURN QUERY
    SELECT
        p_decision_id,
        v_shot_id,
        v_attempt_no,
        v_revision + 1;

END;
$function$
