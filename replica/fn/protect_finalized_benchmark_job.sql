CREATE OR REPLACE FUNCTION public.protect_finalized_benchmark_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP = 'DELETE' THEN

        IF OLD.status IN (
            'SUCCEEDED',
            'FAILED',
            'CANCELLED'
        )
        THEN
            RAISE EXCEPTION
                'FINALIZED_BENCHMARK_JOB_CANNOT_BE_DELETED';
        END IF;

        RETURN OLD;

    END IF;


    IF OLD.status IN (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED'
    )
    THEN
        RAISE EXCEPTION
            'FINALIZED_BENCHMARK_JOB_IMMUTABLE';
    END IF;


    RETURN NEW;

END;

$function$
