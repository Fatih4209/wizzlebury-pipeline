CREATE OR REPLACE FUNCTION public.reserve_benchmark_job_budget()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_case_run_id uuid;

    v_pricing_model_id uuid;
    v_pricing_verified boolean;
    v_verified_at timestamptz;
    v_effective_from timestamptz;
    v_effective_to timestamptz;

    v_run_status text;
    v_human_approved boolean;

    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;

    v_max_count integer;
    v_generation_count integer;

    v_should_reserve boolean := false;

BEGIN

    IF TG_OP = 'INSERT' THEN

        v_should_reserve :=
            NEW.status = 'BUDGET_RESERVED';

    ELSIF TG_OP = 'UPDATE' THEN

        v_should_reserve :=
            OLD.status <> 'BUDGET_RESERVED'
            AND NEW.status = 'BUDGET_RESERVED';

    END IF;


    IF v_should_reserve IS NOT TRUE THEN
        RETURN NEW;
    END IF;


    SELECT gbc.benchmark_run_id
    INTO v_case_run_id

    FROM public.generation_benchmark_cases gbc

    WHERE gbc.id = NEW.benchmark_case_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_NOT_FOUND';
    END IF;


    IF v_case_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_RUN_MISMATCH';
    END IF;


    SELECT
        gmp.model_id,
        gmp.is_verified,
        gmp.verified_at,
        gmp.effective_from,
        gmp.effective_to

    INTO
        v_pricing_model_id,
        v_pricing_verified,
        v_verified_at,
        v_effective_from,
        v_effective_to

    FROM public.generation_model_pricing gmp

    WHERE gmp.id = NEW.pricing_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_FOUND';
    END IF;


    IF v_pricing_model_id <> NEW.model_id THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_MODEL_MISMATCH';
    END IF;


    IF COALESCE(v_pricing_verified, false) IS NOT TRUE
       OR v_verified_at IS NULL
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_VERIFIED';
    END IF;


    IF v_effective_from > now()
       OR (
            v_effective_to IS NOT NULL
            AND v_effective_to <= now()
       )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_EFFECTIVE';
    END IF;


    SELECT
        gbr.status,
        gbr.human_approved,
        gbr.hard_budget_usd,
        gbr.reserved_usd,
        gbr.settled_usd,
        gbr.max_generation_count,
        gbr.generation_count

    INTO
        v_run_status,
        v_human_approved,
        v_hard_budget,
        v_reserved,
        v_settled,
        v_max_count,
        v_generation_count

    FROM public.generation_benchmark_runs gbr

    WHERE gbr.id = NEW.benchmark_run_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_FOUND';
    END IF;


    IF v_run_status <> 'RUNNING'
       OR v_human_approved IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_AUTHORIZED';
    END IF;


    IF v_generation_count + 1 > v_max_count THEN
        RAISE EXCEPTION
            'BENCHMARK_GENERATION_LIMIT_EXCEEDED';
    END IF;


    IF (
        v_reserved
        + v_settled
        + NEW.estimated_cost
    ) > v_hard_budget
    THEN
        RAISE EXCEPTION
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    END IF;


    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );


    UPDATE public.generation_benchmark_runs

    SET
        reserved_usd =
            reserved_usd
            + NEW.estimated_cost,

        generation_count =
            generation_count + 1,

        updated_at = now()

    WHERE id = NEW.benchmark_run_id;


    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );


    RETURN NEW;

END;

$function$
