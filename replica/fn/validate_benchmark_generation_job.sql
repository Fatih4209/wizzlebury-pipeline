CREATE OR REPLACE FUNCTION public.validate_benchmark_generation_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_case_run_id uuid;

    v_pricing_model_id uuid;
    v_pricing_verified boolean;
    v_pricing_verified_at timestamptz;
    v_effective_from timestamptz;
    v_effective_to timestamptz;

    v_run_status text;
    v_human_approved boolean;

    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;

    v_max_count integer;
    v_generation_count integer;

BEGIN

    -- Only reservation opens a paid benchmark job.

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- CASE -> RUN
    -- -----------------------------------------------------

    SELECT benchmark_run_id
    INTO v_case_run_id

    FROM public.generation_benchmark_cases

    WHERE id = NEW.benchmark_case_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_NOT_FOUND';
    END IF;


    IF v_case_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_RUN_MISMATCH';
    END IF;


    -- -----------------------------------------------------
    -- PRICING -> MODEL
    -- -----------------------------------------------------

    SELECT
        model_id,
        is_verified,
        verified_at,
        effective_from,
        effective_to

    INTO
        v_pricing_model_id,
        v_pricing_verified,
        v_pricing_verified_at,
        v_effective_from,
        v_effective_to

    FROM public.generation_model_pricing

    WHERE id = NEW.pricing_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_FOUND';
    END IF;


    IF v_pricing_model_id <> NEW.model_id THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_MODEL_MISMATCH';
    END IF;


    IF COALESCE(
        v_pricing_verified,
        false
    ) IS NOT TRUE
       OR v_pricing_verified_at IS NULL
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


    -- -----------------------------------------------------
    -- LOCK RUN
    -- -----------------------------------------------------

    SELECT
        status,
        human_approved,
        hard_budget_usd,
        reserved_usd,
        settled_usd,
        max_generation_count,
        generation_count

    INTO
        v_run_status,
        v_human_approved,
        v_hard_budget,
        v_reserved,
        v_settled,
        v_max_count,
        v_generation_count

    FROM public.generation_benchmark_runs

    WHERE id = NEW.benchmark_run_id

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


    -- -----------------------------------------------------
    -- GENERATION COUNT LIMIT
    -- -----------------------------------------------------

    IF v_generation_count + 1 >
        v_max_count
    THEN
        RAISE EXCEPTION
            'BENCHMARK_GENERATION_LIMIT_EXCEEDED';
    END IF;


    -- -----------------------------------------------------
    -- HARD BUDGET
    -- -----------------------------------------------------

    IF (
        v_reserved
        + v_settled
        + NEW.estimated_cost
    ) > v_hard_budget
    THEN
        RAISE EXCEPTION
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    END IF;


    -- -----------------------------------------------------
    -- RESERVE
    -- -----------------------------------------------------

    UPDATE public.generation_benchmark_runs

    SET
        reserved_usd =
            reserved_usd
            + NEW.estimated_cost,

        generation_count =
            generation_count + 1,

        updated_at = now()

    WHERE id = NEW.benchmark_run_id;


    RETURN NEW;

END;

$function$
