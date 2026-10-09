CREATE OR REPLACE FUNCTION public.protect_approved_generation_benchmark()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP = 'DELETE' THEN

        IF OLD.benchmark_status = 'HUMAN_APPROVED' THEN
            RAISE EXCEPTION
                'APPROVED_BENCHMARK_CANNOT_BE_DELETED';
        END IF;

        RETURN OLD;

    END IF;


    IF OLD.benchmark_status = 'HUMAN_APPROVED' THEN

        RAISE EXCEPTION
            'APPROVED_BENCHMARK_IMMUTABLE';

    END IF;


    -- HUMAN_APPROVED must carry approval timestamp.

    IF NEW.benchmark_status = 'HUMAN_APPROVED'
       AND NEW.approved_at IS NULL
    THEN

        RAISE EXCEPTION
            'APPROVED_BENCHMARK_REQUIRES_APPROVED_AT';

    END IF;


    RETURN NEW;

END;

$function$
