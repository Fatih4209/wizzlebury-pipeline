CREATE OR REPLACE FUNCTION public.settle_charged_benchmark_failure_v2(p_job_id uuid, p_actual_cost numeric, p_final_status text DEFAULT 'FAILED'::text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(job_id uuid, estimated_cost numeric, actual_cost numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_run_id uuid;
    v_status text;
    v_estimated_cost numeric;

    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;

    v_overrun numeric;
    v_generation_disabled boolean := false;

BEGIN

    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'BENCHMARK_JOB_ID_REQUIRED';
    END IF;


    IF p_final_status NOT IN ('FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION
            'INVALID_CHARGED_FAILURE_STATUS';
    END IF;


    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_ACTUAL_COST';
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
        RAISE EXCEPTION 'BENCHMARK_JOB_NOT_FOUND';
    END IF;


    IF v_status NOT IN ('SUBMITTED', 'GENERATING') THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_CHARGED_FAILURE_SETTLEABLE: %',
            v_status;
    END IF;


    SELECT
        r.hard_budget_usd,
        r.reserved_usd,
        r.settled_usd
    INTO
        v_hard_budget,
        v_reserved,
        v_settled
    FROM public.generation_benchmark_runs r
    WHERE r.id = v_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'BENCHMARK_RUN_NOT_FOUND';
    END IF;


    IF v_reserved < v_estimated_cost THEN
        RAISE EXCEPTION
            'BENCHMARK_RESERVATION_ACCOUNTING_ERROR';
    END IF;


    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);


    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );


    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd - v_estimated_cost,

        settled_usd =
            settled_usd + p_actual_cost,

        updated_at = now()
    WHERE id = v_run_id;


    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );


    -- Only this function may record a charge above the
    -- reservation (see protect_benchmark_job_accounting_fields).
    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'on',
        true
    );

    UPDATE public.generation_benchmark_jobs
    SET
        actual_cost = p_actual_cost,
        status = p_final_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = now()
    WHERE id = p_job_id;

    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'off',
        true
    );


    IF v_overrun > 0
       OR (v_settled + p_actual_cost) > v_hard_budget
    THEN

        INSERT INTO public.events (
            event_type,
            severity,
            source,
            message,
            metadata
        )
        VALUES (
            'BENCHMARK_COST_OVERRUN',
            'CRITICAL',
            'BENCHMARK_ACCOUNTING',
            'Benchmark provider charge exceeded its reservation or the run budget. Generation disabled.',
            jsonb_build_object(
                'benchmark_job_id', p_job_id,
                'benchmark_run_id', v_run_id,
                'estimated_cost', v_estimated_cost,
                'actual_cost', p_actual_cost,
                'overrun', v_overrun,
                'run_hard_budget', v_hard_budget,
                'run_settled_after', v_settled + p_actual_cost
            )
        );

    END IF;



    IF v_overrun > 0
       OR (v_settled + p_actual_cost) > v_hard_budget
    THEN

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
        p_job_id,
        v_estimated_cost,
        p_actual_cost,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN (v_settled + p_actual_cost) > v_hard_budget
            THEN 'CHARGED_FAILURE_BUDGET_BREACH_GENERATION_DISABLED'

            WHEN v_overrun > 0
            THEN 'CHARGED_FAILURE_OVERRUN_GENERATION_DISABLED'

            ELSE 'CHARGED_FAILURE_SETTLED'
        END::text;

END;
$function$
