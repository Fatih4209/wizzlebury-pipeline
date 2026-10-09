CREATE OR REPLACE FUNCTION public.protect_benchmark_provider_job_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF OLD.provider_job_id IS NOT NULL
       AND NEW.provider_job_id
            IS DISTINCT FROM OLD.provider_job_id
    THEN

        RAISE EXCEPTION
            'BENCHMARK_PROVIDER_JOB_ID_IMMUTABLE';

    END IF;


    IF OLD.provider_job_id IS NULL
       AND NEW.provider_job_id IS NOT NULL
       AND OLD.status NOT IN (
            'BUDGET_RESERVED',
            'SUBMITTED'
       )
    THEN

        RAISE EXCEPTION
            'BENCHMARK_PROVIDER_JOB_ID_INVALID_STATE: %',
            OLD.status;

    END IF;


    RETURN NEW;

END;

$function$
