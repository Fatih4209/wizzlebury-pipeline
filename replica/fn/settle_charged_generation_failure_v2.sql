CREATE OR REPLACE FUNCTION public.settle_charged_generation_failure_v2(p_attempt_id uuid, p_actual_cost numeric, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, estimated_cost numeric, actual_cost numeric, released_amount numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_episode_id uuid;

    v_estimated_cost numeric;
    v_status text;

    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;

    v_release numeric;
    v_overrun numeric;

    v_generation_disabled boolean := false;
BEGIN

    IF p_attempt_id IS NULL THEN
        RAISE EXCEPTION 'ATTEMPT_ID_REQUIRED';
    END IF;

    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION 'INVALID_ACTUAL_COST';
    END IF;

    SELECT
        a.shot_id,
        a.estimated_cost,
        a.status,
        a.monthly_budget_id,
        a.episode_budget_id,
        a.shot_budget_id
    INTO
        v_shot_id,
        v_estimated_cost,
        v_status,
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    FROM public.attempts a
    WHERE a.id = p_attempt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTEMPT_NOT_FOUND';
    END IF;

    IF v_status NOT IN (
        'BUDGET_RESERVED',
        'SUBMITTED',
        'GENERATING'
    ) THEN
        RAISE EXCEPTION
            'ATTEMPT_NOT_CHARGED_FAILURE_SETTLEABLE: %',
            v_status;
    END IF;

    IF v_monthly_budget_id IS NULL
       OR v_episode_budget_id IS NULL
       OR v_shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION 'ATTEMPT_BUDGET_BINDINGS_MISSING';
    END IF;

    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = v_shot_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;

    PERFORM 1
    FROM public.budgets b
    WHERE b.id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    ORDER BY b.id
    FOR UPDATE;

    IF (
        SELECT COUNT(*)
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
    ) <> 3 THEN
        RAISE EXCEPTION 'BOUND_BUDGET_NOT_FOUND';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
        AND b.reserved_amount < v_estimated_cost
    ) THEN
        RAISE EXCEPTION 'BOUND_RESERVED_BALANCE_INVALID';
    END IF;

    v_release :=
        GREATEST(v_estimated_cost - p_actual_cost, 0);

    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);

    UPDATE public.budgets
    SET
        reserved_amount =
            reserved_amount - v_estimated_cost,

        settled_amount =
            settled_amount + p_actual_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );

    UPDATE public.attempts
    SET
        actual_cost = p_actual_cost,
        status = 'FAILED',
        error_code = p_error_code,
        error_detail = p_error_detail,
        finished_at = now()
    WHERE id = p_attempt_id;

    -- SETTLE is the SINGLE accounting record of actual provider charge.
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
        p_attempt_id,
        v_episode_id,
        v_shot_id,
        'SETTLE',
        p_actual_cost,
        'USD',
        CASE
            WHEN v_overrun > 0
            THEN 'Charged generation failure settled; provider overrun detected'
            ELSE 'Charged generation failure settled'
        END
    );

    IF v_release > 0 THEN

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
            p_attempt_id,
            v_episode_id,
            v_shot_id,
            'RELEASE',
            v_release,
            'USD',
            'Unused reservation released after charged failure'
        );

    END IF;

    -- Overrun already exists inside SETTLE actual_cost.
    -- No duplicate ADJUSTMENT row.
    IF v_overrun > 0 THEN

        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';

        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;

        v_generation_disabled := true;

    END IF;

    RETURN QUERY
    SELECT
        p_attempt_id,
        v_estimated_cost,
        p_actual_cost,
        v_release,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN v_overrun > 0
            THEN 'CHARGED_FAILURE_OVERRUN_GENERATION_DISABLED'
            ELSE 'CHARGED_FAILURE_SETTLED'
        END::text;

END;
$function$
