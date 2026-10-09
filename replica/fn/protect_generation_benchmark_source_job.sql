CREATE OR REPLACE FUNCTION public.protect_generation_benchmark_source_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF OLD.source_benchmark_job_id IS NOT NULL
       AND NEW.source_benchmark_job_id
            IS DISTINCT FROM OLD.source_benchmark_job_id
    THEN

        RAISE EXCEPTION
            'BENCHMARK_SOURCE_JOB_IMMUTABLE';

    END IF;


    RETURN NEW;

END;

$function$
