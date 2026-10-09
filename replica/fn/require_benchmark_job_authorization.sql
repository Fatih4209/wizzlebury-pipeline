CREATE OR REPLACE FUNCTION public.require_benchmark_job_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_authorization_status text;

BEGIN

    IF TG_OP <> 'UPDATE' THEN
        RETURN NEW;
    END IF;


    IF OLD.status = 'CREATED'
       AND NEW.status = 'BUDGET_RESERVED'
    THEN

        SELECT authorization_status
        INTO v_authorization_status

        FROM public.generation_benchmark_job_authorizations

        WHERE benchmark_job_id = NEW.id;


        IF NOT FOUND
           OR v_authorization_status <> 'AUTHORIZED'
        THEN

            RAISE EXCEPTION
                'BENCHMARK_JOB_NOT_AUTHORIZED_FOR_PAID_EXECUTION';

        END IF;

    END IF;


    RETURN NEW;

END;

$function$
