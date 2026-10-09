CREATE OR REPLACE FUNCTION public.release_generation_attempt_v2(p_attempt_id uuid, p_failure_status text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, released_amount numeric, decision text)
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

BEGIN

    IF p_attempt_id IS NULL THEN
        RAISE EXCEPTION 'ATTEMPT_ID_REQUIRED';
    END IF;

    IF p_failure_status NOT IN ('FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION 'INVALID_FAILURE_STATUS';
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
            'ATTEMPT_NOT_RELEASABLE: %',
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


    UPDATE public.budgets
    SET reserved_amount =
        reserved_amount - v_estimated_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );


    UPDATE public.attempts
    SET
        actual_cost = 0,
        status = p_failure_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        finished_at = now()
    WHERE id = p_attempt_id;


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
        v_estimated_cost,
        'USD',
        'Bound generation reservation released without provider charge'
    );


    RETURN QUERY
    SELECT
        p_attempt_id,
        v_estimated_cost,
        'RELEASED'::text;

END;
$function$
