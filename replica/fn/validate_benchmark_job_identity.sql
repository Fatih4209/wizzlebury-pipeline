CREATE OR REPLACE FUNCTION public.validate_benchmark_job_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_case_run_id uuid;

    v_pricing_model_id uuid;

    v_attempt1_status text;

BEGIN

    -- -----------------------------------------------------
    -- INSERT must begin before provider execution.
    -- Direct creation as SUBMITTED / GENERATING / terminal
    -- is forbidden.
    -- -----------------------------------------------------

    IF NEW.status NOT IN (
        'CREATED',
        'BUDGET_RESERVED'
    )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_INVALID_INITIAL_STATUS: %',
            NEW.status;
    END IF;


    -- -----------------------------------------------------
    -- CASE MUST BELONG TO RUN
    -- -----------------------------------------------------

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


    -- -----------------------------------------------------
    -- PRICING MUST BELONG TO MODEL
    -- -----------------------------------------------------

    SELECT gmp.model_id
    INTO v_pricing_model_id

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


    -- -----------------------------------------------------
    -- ATTEMPT 1
    -- -----------------------------------------------------

    IF NEW.attempt_no = 1 THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- ATTEMPT 2
    --
    -- Must have attempt 1 for exact same:
    -- case + model
    --
    -- Attempt 1 must be FAILED.
    --
    -- CANCELLED does not authorize another paid generation.
    -- SUCCEEDED obviously does not authorize retry.
    -- -----------------------------------------------------

    SELECT gbj.status
    INTO v_attempt1_status

    FROM public.generation_benchmark_jobs gbj

    WHERE gbj.benchmark_case_id =
            NEW.benchmark_case_id

      AND gbj.model_id =
            NEW.model_id

      AND gbj.attempt_no = 1

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_ATTEMPT_2_REQUIRES_ATTEMPT_1';
    END IF;


    IF v_attempt1_status <> 'FAILED' THEN

        RAISE EXCEPTION
            'BENCHMARK_ATTEMPT_2_REQUIRES_FAILED_ATTEMPT_1: current=%',
            v_attempt1_status;

    END IF;


    RETURN NEW;

END;

$function$
