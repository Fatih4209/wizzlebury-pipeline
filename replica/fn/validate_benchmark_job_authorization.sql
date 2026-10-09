CREATE OR REPLACE FUNCTION public.validate_benchmark_job_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_job_run_id uuid;
    v_job_estimated_cost numeric;
    v_job_status text;
    v_attempt_no integer;

BEGIN

    SELECT
        benchmark_run_id,
        estimated_cost,
        status,
        attempt_no

    INTO
        v_job_run_id,
        v_job_estimated_cost,
        v_job_status,
        v_attempt_no

    FROM public.generation_benchmark_jobs

    WHERE id = NEW.benchmark_job_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_JOB_NOT_FOUND';
    END IF;


    IF v_job_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_RUN_MISMATCH';
    END IF;


    IF NEW.authorized_estimated_cost
       <> v_job_estimated_cost
    THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_COST_MISMATCH';
    END IF;


    IF NEW.authorization_stage = 'PILOT'
       AND v_attempt_no <> 1
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PILOT_REQUIRES_ATTEMPT_1';
    END IF;


    IF NEW.authorization_status IN (
        'PLANNED',
        'AUTHORIZED'
    )
    AND v_job_status <> 'CREATED'
    THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_REQUIRES_CREATED_JOB';
    END IF;


    RETURN NEW;

END;

$function$
