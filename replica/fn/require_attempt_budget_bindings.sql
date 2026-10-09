CREATE OR REPLACE FUNCTION public.require_attempt_budget_bindings()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;

    v_monthly_type text;
    v_monthly_reference uuid;
    v_monthly_currency text;

    v_episode_type text;
    v_episode_reference uuid;
    v_episode_currency text;

    v_shot_type text;
    v_shot_reference uuid;
    v_shot_currency text;

BEGIN

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    IF NEW.monthly_budget_id IS NULL
       OR NEW.episode_budget_id IS NULL
       OR NEW.shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION
            'ATTEMPT_BUDGET_BINDINGS_REQUIRED';
    END IF;


    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = NEW.shot_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;


    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_monthly_type,
        v_monthly_reference,
        v_monthly_currency
    FROM public.budgets b
    WHERE b.id = NEW.monthly_budget_id
      AND b.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_MONTHLY_BUDGET_NOT_ACTIVE';
    END IF;


    IF v_monthly_type <> 'MONTHLY'
       OR v_monthly_reference IS NOT NULL
       OR v_monthly_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_MONTHLY_BUDGET';
    END IF;


    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_episode_type,
        v_episode_reference,
        v_episode_currency
    FROM public.budgets b
    WHERE b.id = NEW.episode_budget_id
      AND b.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_EPISODE_BUDGET_NOT_ACTIVE';
    END IF;


    IF v_episode_type <> 'EPISODE'
       OR v_episode_reference <> v_episode_id
       OR v_episode_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_EPISODE_BUDGET';
    END IF;


    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_shot_type,
        v_shot_reference,
        v_shot_currency
    FROM public.budgets b
    WHERE b.id = NEW.shot_budget_id
      AND b.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_SHOT_BUDGET_NOT_ACTIVE';
    END IF;


    IF v_shot_type <> 'SHOT'
       OR v_shot_reference <> NEW.shot_id
       OR v_shot_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_SHOT_BUDGET';
    END IF;


    RETURN NEW;

END;
$function$
