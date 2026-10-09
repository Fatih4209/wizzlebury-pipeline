CREATE OR REPLACE FUNCTION public.require_router_authorized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_decision_status text;
    v_decision_shot_id uuid;
    v_decision_spec_id uuid;
    v_decision_attempt_no integer;
    v_selected_model_id uuid;
    v_selected_pricing_id uuid;
    v_decision_estimated_cost numeric;

    v_spec_shot_id uuid;
    v_spec_version integer;
    v_spec_status text;
    v_spec_active boolean;
    v_spec_locked_at timestamptz;

    v_model_provider_id uuid;
    v_model_code text;
    v_model_status text;

    v_provider_code text;
    v_provider_status text;

    v_pricing_model_id uuid;
    v_pricing_currency text;
    v_pricing_verified boolean;
    v_pricing_verified_at timestamptz;
    v_pricing_effective_from timestamptz;
    v_pricing_effective_to timestamptz;

BEGIN

    -- -----------------------------------------------------
    -- Only paid/reserved attempts require router gate.
    -- -----------------------------------------------------

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Routing decision is mandatory.
    -- -----------------------------------------------------

    IF NEW.routing_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Lock routing decision during attempt creation.
    -- -----------------------------------------------------

    SELECT
        grd.decision_status,
        grd.shot_id,
        grd.shot_specification_id,
        grd.attempt_no,
        grd.selected_model_id,
        grd.selected_pricing_id,
        grd.estimated_cost

    INTO
        v_decision_status,
        v_decision_shot_id,
        v_decision_spec_id,
        v_decision_attempt_no,
        v_selected_model_id,
        v_selected_pricing_id,
        v_decision_estimated_cost

    FROM public.generation_routing_decisions grd

    WHERE grd.id = NEW.routing_decision_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_FOUND';
    END IF;


    IF v_decision_status <> 'SELECTED' THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_decision_status;
    END IF;


    -- -----------------------------------------------------
    -- Exact shot + attempt number.
    -- -----------------------------------------------------

    IF v_decision_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_SHOT_MISMATCH';
    END IF;


    IF v_decision_attempt_no <> NEW.attempt_no THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ATTEMPT_MISMATCH';
    END IF;


    IF v_selected_model_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_SELECTED_MODEL_REQUIRED';
    END IF;


    IF v_selected_pricing_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_SELECTED_PRICING_REQUIRED';
    END IF;


    IF v_decision_estimated_cost IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_ESTIMATED_COST_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Exact specification must still be canonical.
    -- -----------------------------------------------------

    SELECT
        ss.shot_id,
        ss.version,
        ss.status,
        ss.is_active,
        ss.locked_at

    INTO
        v_spec_shot_id,
        v_spec_version,
        v_spec_status,
        v_spec_active,
        v_spec_locked_at

    FROM public.shot_specifications ss

    WHERE ss.id = v_decision_spec_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_FOUND';
    END IF;


    IF v_spec_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_SHOT_MISMATCH';
    END IF;


    IF v_spec_status <> 'LOCKED'
       OR v_spec_locked_at IS NULL
       OR COALESCE(v_spec_active, false) IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_CANONICAL';
    END IF;


    IF v_spec_version <> NEW.prompt_version THEN
        RAISE EXCEPTION
            'ROUTING_PROMPT_VERSION_MISMATCH';
    END IF;


    -- -----------------------------------------------------
    -- Selected model.
    -- -----------------------------------------------------

    SELECT
        gm.provider_id,
        gm.model_code,
        gm.status

    INTO
        v_model_provider_id,
        v_model_code,
        v_model_status

    FROM public.generation_models gm

    WHERE gm.id = v_selected_model_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_MODEL_NOT_FOUND';
    END IF;


    IF v_model_status NOT IN (
        'ACTIVE',
        'TESTING'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_MODEL_NOT_ENABLED: %',
            v_model_status;
    END IF;


    -- -----------------------------------------------------
    -- Provider.
    -- -----------------------------------------------------

    SELECT
        gp.provider_code,
        gp.status

    INTO
        v_provider_code,
        v_provider_status

    FROM public.generation_providers gp

    WHERE gp.id = v_model_provider_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_PROVIDER_NOT_FOUND';
    END IF;


    IF v_provider_status NOT IN (
        'ACTIVE',
        'TESTING'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_PROVIDER_NOT_ENABLED: %',
            v_provider_status;
    END IF;


    -- -----------------------------------------------------
    -- Exact provider/model match.
    -- -----------------------------------------------------

    IF NEW.provider <> v_provider_code THEN
        RAISE EXCEPTION
            'ATTEMPT_PROVIDER_DOES_NOT_MATCH_ROUTER';
    END IF;


    IF NEW.model <> v_model_code THEN
        RAISE EXCEPTION
            'ATTEMPT_MODEL_DOES_NOT_MATCH_ROUTER';
    END IF;


    -- -----------------------------------------------------
    -- Pricing validation.
    --
    -- Must:
    -- belong to selected model
    -- be USD
    -- be verified
    -- be currently effective
    -- -----------------------------------------------------

    SELECT
        gmp.model_id,
        gmp.currency,
        gmp.is_verified,
        gmp.verified_at,
        gmp.effective_from,
        gmp.effective_to

    INTO
        v_pricing_model_id,
        v_pricing_currency,
        v_pricing_verified,
        v_pricing_verified_at,
        v_pricing_effective_from,
        v_pricing_effective_to

    FROM public.generation_model_pricing gmp

    WHERE gmp.id = v_selected_pricing_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_FOUND';
    END IF;


    IF v_pricing_model_id <> v_selected_model_id THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_MODEL_MISMATCH';
    END IF;


    IF v_pricing_currency <> 'USD' THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_CURRENCY_INVALID';
    END IF;


    IF COALESCE(v_pricing_verified, false) IS NOT TRUE
       OR v_pricing_verified_at IS NULL
    THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_VERIFIED';
    END IF;


    IF v_pricing_effective_from > now()
       OR (
            v_pricing_effective_to IS NOT NULL
            AND v_pricing_effective_to <= now()
       )
    THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_EFFECTIVE';
    END IF;


    -- -----------------------------------------------------
    -- Estimated cost must be EXACTLY router-approved.
    --
    -- numeric = deterministic comparison.
    -- -----------------------------------------------------

    IF NEW.estimated_cost
       IS DISTINCT FROM
       v_decision_estimated_cost
    THEN
        RAISE EXCEPTION
            'ATTEMPT_COST_DOES_NOT_MATCH_ROUTER';
    END IF;


    RETURN NEW;

END;

$function$
