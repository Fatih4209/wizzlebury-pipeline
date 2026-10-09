CREATE OR REPLACE FUNCTION public.validate_benchmark_job_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP <> 'UPDATE' THEN
        RETURN NEW;
    END IF;


    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;


    IF NOT (

        (OLD.status = 'CREATED'
            AND NEW.status IN (
                'BUDGET_RESERVED',
                'CANCELLED'
            ))

        OR

        (OLD.status = 'BUDGET_RESERVED'
            AND NEW.status IN (
                'SUBMITTED',
                'FAILED',
                'CANCELLED'
            ))

        OR

        (OLD.status = 'SUBMITTED'
            AND NEW.status IN (
                'GENERATING',
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))

        OR

        (OLD.status = 'GENERATING'
            AND NEW.status IN (
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))

    )
    THEN

        RAISE EXCEPTION
            'INVALID_BENCHMARK_JOB_TRANSITION: % -> %',
            OLD.status,
            NEW.status;

    END IF;


    RETURN NEW;

END;

$function$
