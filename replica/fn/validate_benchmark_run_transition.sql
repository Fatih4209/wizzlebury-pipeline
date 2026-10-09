CREATE OR REPLACE FUNCTION public.validate_benchmark_run_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP <> 'UPDATE'
       OR NEW.status = OLD.status
    THEN
        RETURN NEW;
    END IF;


    IF NOT (

        (
            OLD.status = 'DRAFT'
            AND NEW.status IN (
                'HUMAN_APPROVED',
                'CANCELLED'
            )
        )

        OR

        (
            OLD.status = 'HUMAN_APPROVED'
            AND NEW.status IN (
                'RUNNING',
                'CANCELLED'
            )
        )

        OR

        (
            OLD.status = 'RUNNING'
            AND NEW.status IN (
                'COMPLETED',
                'CANCELLED',
                'BLOCKED'
            )
        )

        OR

        (
            OLD.status = 'BLOCKED'
            AND NEW.status IN (
                'RUNNING',
                'CANCELLED'
            )
        )

    )
    THEN

        RAISE EXCEPTION
            'INVALID_BENCHMARK_RUN_TRANSITION: % -> %',
            OLD.status,
            NEW.status;

    END IF;


    -- HUMAN APPROVAL

    IF NEW.status = 'HUMAN_APPROVED' THEN

        IF NEW.human_approved IS NOT TRUE
           OR NEW.approved_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_APPROVAL_REQUIRED';
        END IF;

    END IF;


    -- RUNNING

    IF NEW.status = 'RUNNING' THEN

        IF NEW.human_approved IS NOT TRUE
           OR NEW.approved_at IS NULL
           OR NEW.started_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_START_REQUIREMENTS_NOT_MET';
        END IF;

    END IF;


    -- COMPLETED

    IF NEW.status = 'COMPLETED' THEN

        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_COMPLETION_TIMESTAMP_REQUIRED';
        END IF;

        IF OLD.reserved_usd <> 0 THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_HAS_OPEN_RESERVATIONS';
        END IF;

    END IF;


    RETURN NEW;

END;

$function$
