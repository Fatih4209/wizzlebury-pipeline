CREATE OR REPLACE FUNCTION public.validate_benchmark_job_state_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF NEW.status IN (
        'SUBMITTED',
        'GENERATING'
    )
    THEN

        IF NEW.provider_job_id IS NULL
           OR NEW.submitted_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_SUBMITTED_JOB_REQUIRES_PROVIDER_ID_AND_TIMESTAMP';
        END IF;

    END IF;


    IF NEW.status IN (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED'
    )
    THEN

        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'FINALIZED_BENCHMARK_JOB_REQUIRES_COMPLETED_AT';
        END IF;

    END IF;


    IF NEW.status = 'SUCCEEDED' THEN

        IF NEW.actual_cost IS NULL THEN
            RAISE EXCEPTION
                'SUCCEEDED_BENCHMARK_JOB_REQUIRES_ACTUAL_COST';
        END IF;


        IF NEW.output_url IS NULL
           AND NEW.storage_path IS NULL
        THEN
            RAISE EXCEPTION
                'SUCCEEDED_BENCHMARK_JOB_REQUIRES_OUTPUT';
        END IF;

    END IF;


    RETURN NEW;

END;

$function$
