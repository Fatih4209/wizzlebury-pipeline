CREATE OR REPLACE FUNCTION public.release_benchmark_job(p_job_id uuid, p_final_status text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

DECLARE

    v_run_id uuid;
    v_status text;
    v_estimated_cost numeric;

BEGIN

    IF p_final_status NOT IN (
        'FAILED',
        'CANCELLED'
    )
    THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_RELEASE_STATUS';
    END IF;


    SELECT
        gbj.benchmark_run_id,
        gbj.status,
        gbj.estimated_cost

    INTO
        v_run_id,
        v_status,
        v_estimated_cost

    FROM public.generation_benchmark_jobs gbj

    WHERE gbj.id = p_job_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_FOUND';
    END IF;


    IF v_status NOT IN (
        'BUDGET_RESERVED',
        'SUBMITTED',
        'GENERATING'
    )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_RELEASABLE: %',
            v_status;
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
            - v_estimated_cost,

        updated_at = now()

    WHERE id = v_run_id

      AND reserved_usd >=
            v_estimated_cost;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_RESERVATION_ACCOUNTING_ERROR';
    END IF;


    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );


    UPDATE public.generation_benchmark_jobs

    SET
        actual_cost = 0,
        status = p_final_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = now()

    WHERE id = p_job_id;

END;

$function$
