CREATE OR REPLACE FUNCTION public.acquire_generation_attempt_v2(p_routing_decision_id uuid, p_idempotency_key text)
 RETURNS TABLE(attempt_id uuid, attempt_no integer, decision text, reserved_cost numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_generation_enabled boolean;

    v_shot_id uuid;
    v_spec_id uuid;
    v_episode_id uuid;

    v_attempt_no integer;
    v_prompt_version integer;

    v_provider text;
    v_model text;
    v_model_version text;

    v_estimated_cost numeric;

    v_routing_status text;
    v_selected_model_id uuid;
    v_selected_pricing_id uuid;

    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;

    v_monthly_available numeric;
    v_episode_available numeric;
    v_shot_available numeric;

    v_attempt_id uuid;

    v_existing_attempt_id uuid;
    v_existing_attempt_no integer;
    v_existing_cost numeric;

    v_shot_state text;


BEGIN

    -- =====================================================
    -- 1. INPUT
    -- =====================================================

    IF p_routing_decision_id IS NULL THEN
        RAISE EXCEPTION 'ROUTING_DECISION_REQUIRED';
    END IF;

    IF p_idempotency_key IS NULL
       OR btrim(p_idempotency_key) = ''
    THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;


    -- =====================================================
    -- 2. TRUE IDEMPOTENCY
    -- Same request returns the existing attempt.
    -- =====================================================

    SELECT
        a.id,
        a.attempt_no,
        a.estimated_cost
    INTO
        v_existing_attempt_id,
        v_existing_attempt_no,
        v_existing_cost
    FROM public.attempts a
    WHERE a.idempotency_key = p_idempotency_key;

    IF FOUND THEN

        RETURN QUERY
        SELECT
            v_existing_attempt_id,
            v_existing_attempt_no,
            'ALREADY_ACQUIRED'::text,
            v_existing_cost;

        RETURN;

    END IF;


    -- =====================================================
    -- 3. MASTER KILL SWITCH
    -- =====================================================

    SELECT sf.value
    INTO v_generation_enabled
    FROM public.system_flags sf
    WHERE sf.key = 'generation_enabled'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
    END IF;

    IF v_generation_enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'GENERATION_DISABLED';
    END IF;


    -- =====================================================
    -- 4. LOCK ROUTING DECISION
    -- =====================================================

    SELECT
        grd.shot_id,
        grd.shot_specification_id,
        grd.attempt_no,
        grd.decision_status,
        grd.selected_model_id,
        grd.selected_pricing_id,
        grd.estimated_cost
    INTO
        v_shot_id,
        v_spec_id,
        v_attempt_no,
        v_routing_status,
        v_selected_model_id,
        v_selected_pricing_id,
        v_estimated_cost
    FROM public.generation_routing_decisions grd
    WHERE grd.id = p_routing_decision_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROUTING_DECISION_NOT_FOUND';
    END IF;

    IF v_routing_status <> 'SELECTED' THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_routing_status;
    END IF;

    IF v_attempt_no NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION
            'INVALID_ROUTING_ATTEMPT_NO: %',
            v_attempt_no;
    END IF;

    IF v_selected_model_id IS NULL
       OR v_selected_pricing_id IS NULL
       OR v_estimated_cost IS NULL
       OR v_estimated_cost <= 0
    THEN
        RAISE EXCEPTION 'ROUTING_DECISION_INCOMPLETE';
    END IF;


    -- =====================================================
    -- 5. LOCK SHOT
    -- Prevent concurrent paid acquisition for same shot.
    -- =====================================================

    SELECT
        s.episode_id,
        s.state
    INTO
        v_episode_id,
        v_shot_state
    FROM public.shots s
    WHERE s.id = v_shot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;


    -- Exact shot/attempt must still be unused.
    IF EXISTS (
        SELECT 1
        FROM public.attempts a
        WHERE a.shot_id = v_shot_id
          AND a.attempt_no = v_attempt_no
    ) THEN
        RAISE EXCEPTION
            'SHOT_ATTEMPT_ALREADY_EXISTS';
    END IF;


    -- A shot that already has a canonical output is finished.
    IF EXISTS (
        SELECT 1
        FROM public.generation_outputs go
        WHERE go.shot_id = v_shot_id
          AND go.is_canonical = true
    ) THEN
        RAISE EXCEPTION
            'SHOT_ALREADY_HAS_CANONICAL_OUTPUT';
    END IF;


    -- Attempt 2 requires attempt 1 to be finished without a usable
    -- result:
    --
    --   a) technical failure: attempt 1 FAILED / CANCELLED
    --   b) QC failure: attempt 1 SUCCEEDED, every output it produced
    --      was rejected by QC, and the shot is RETRY_REQUIRED
    IF v_attempt_no = 2 THEN

        IF NOT EXISTS (
            SELECT 1
            FROM public.attempts a
            WHERE a.shot_id = v_shot_id
              AND a.attempt_no = 1
              AND (
                    a.status IN (
                        'FAILED',
                        'CANCELLED'
                    )
                    OR
                    (
                        a.status = 'SUCCEEDED'
                        AND v_shot_state = 'RETRY_REQUIRED'
                        AND EXISTS (
                            SELECT 1
                            FROM public.generation_outputs go
                            WHERE go.attempt_id = a.id
                              AND go.qc_status = 'FAIL'
                        )
                        AND NOT EXISTS (
                            SELECT 1
                            FROM public.generation_outputs go
                            WHERE go.attempt_id = a.id
                              AND go.qc_status <> 'FAIL'
                        )
                    )
              )
        ) THEN
            RAISE EXCEPTION
                'ATTEMPT_2_REQUIRES_FINALIZED_ATTEMPT_1';
        END IF;

    END IF;


    -- =====================================================
    -- 6. CANONICAL SPECIFICATION
    -- =====================================================

    SELECT ss.version
    INTO v_prompt_version
    FROM public.shot_specifications ss
    WHERE ss.id = v_spec_id
      AND ss.shot_id = v_shot_id
      AND ss.status = 'LOCKED'
      AND ss.locked_at IS NOT NULL
      AND ss.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_CANONICAL';
    END IF;


    -- =====================================================
    -- 7. RESOLVE EXACT ROUTER MODEL + PROVIDER
    -- =====================================================

    SELECT
        gp.provider_code,
        gm.model_code
    INTO
        v_provider,
        v_model
    FROM public.generation_models gm
    JOIN public.generation_providers gp
        ON gp.id = gm.provider_id
    WHERE gm.id = v_selected_model_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROUTING_MODEL_PROVIDER_NOT_FOUND';
    END IF;


    -- Keep model_version aligned with the immutable
    -- model code currently selected by router.
    v_model_version := v_model;


    -- =====================================================
    -- 8. LOCK EXACT ACTIVE MONTHLY BUDGET
    -- =====================================================

    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_monthly_budget_id,
        v_monthly_available
    FROM public.budgets b
    WHERE b.budget_type = 'MONTHLY'
      AND b.reference_id IS NULL
      AND b.currency = 'USD'
      AND b.is_active = true
      AND (
          b.period_start IS NULL
          OR b.period_start <= now()
      )
      AND (
          b.period_end IS NULL
          OR b.period_end > now()
      )
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_MONTHLY_BUDGET_MISSING';
    END IF;


    -- =====================================================
    -- 9. LOCK EXACT EPISODE BUDGET
    -- =====================================================

    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_episode_budget_id,
        v_episode_available
    FROM public.budgets b
    WHERE b.budget_type = 'EPISODE'
      AND b.reference_id = v_episode_id
      AND b.currency = 'USD'
      AND b.is_active = true
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_EPISODE_BUDGET_MISSING';
    END IF;


    -- =====================================================
    -- 10. LOCK EXACT SHOT BUDGET
    -- =====================================================

    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_shot_budget_id,
        v_shot_available
    FROM public.budgets b
    WHERE b.budget_type = 'SHOT'
      AND b.reference_id = v_shot_id
      AND b.currency = 'USD'
      AND b.is_active = true
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_SHOT_BUDGET_MISSING';
    END IF;


    -- =====================================================
    -- 11. HARD BUDGET GATES
    -- =====================================================

    IF v_monthly_available < v_estimated_cost THEN
        RAISE EXCEPTION 'MONTHLY_BUDGET_EXCEEDED';
    END IF;

    IF v_episode_available < v_estimated_cost THEN
        RAISE EXCEPTION 'EPISODE_BUDGET_EXCEEDED';
    END IF;

    IF v_shot_available < v_estimated_cost THEN
        RAISE EXCEPTION 'SHOT_BUDGET_EXCEEDED';
    END IF;


    -- =====================================================
    -- 12. CREATE ROUTER + BUDGET BOUND ATTEMPT
    --
    -- Existing DATA-81/84/93/97 triggers still perform
    -- production, manifest, readiness and router validation.
    -- =====================================================

    -- Marker checked by require_attempt_acquisition_path:
    -- attempts can only be created here.
    PERFORM set_config(
        'm417.attempt_acquisition',
        'on',
        true
    );

    INSERT INTO public.attempts (
        shot_id,
        attempt_no,
        idempotency_key,

        provider,
        model,
        prompt_version,
        model_version,

        status,
        estimated_cost,

        routing_decision_id,

        monthly_budget_id,
        episode_budget_id,
        shot_budget_id
    )
    VALUES (
        v_shot_id,
        v_attempt_no,
        p_idempotency_key,

        v_provider,
        v_model,
        v_prompt_version,
        v_model_version,

        'BUDGET_RESERVED',
        v_estimated_cost,

        p_routing_decision_id,

        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    RETURNING id
    INTO v_attempt_id;

    PERFORM set_config(
        'm417.attempt_acquisition',
        'off',
        true
    );


    -- =====================================================
    -- 13. RESERVE ALL ACCOUNTING SCOPES
    -- =====================================================

    UPDATE public.budgets
    SET reserved_amount =
        reserved_amount + v_estimated_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );


    -- =====================================================
    -- 14. APPEND LEDGER
    -- =====================================================

    INSERT INTO public.cost_ledger (
        attempt_id,
        episode_id,
        shot_id,
        entry_type,
        amount,
        currency,
        description
    )
    VALUES (
        v_attempt_id,
        v_episode_id,
        v_shot_id,
        'RESERVE',
        v_estimated_cost,
        'USD',
        'Router-authorized generation reservation'
    );


    -- =====================================================
    -- 15. SHOT -> QUEUED
    -- =====================================================

    UPDATE public.shots
    SET state = 'QUEUED'
    WHERE id = v_shot_id;


    RETURN QUERY
    SELECT
        v_attempt_id,
        v_attempt_no,
        'AUTHORIZED'::text,
        v_estimated_cost;

END;
$function$
