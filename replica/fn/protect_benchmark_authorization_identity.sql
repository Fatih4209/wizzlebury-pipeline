CREATE OR REPLACE FUNCTION public.protect_benchmark_authorization_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF NEW.benchmark_run_id
            IS DISTINCT FROM OLD.benchmark_run_id

       OR NEW.benchmark_job_id
            IS DISTINCT FROM OLD.benchmark_job_id

       OR NEW.authorization_stage
            IS DISTINCT FROM OLD.authorization_stage

       OR NEW.authorized_estimated_cost
            IS DISTINCT FROM OLD.authorized_estimated_cost

    THEN

        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_IDENTITY_IMMUTABLE';

    END IF;


    RETURN NEW;

END;

$function$
