CREATE OR REPLACE FUNCTION public.protect_benchmark_evidence_job_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF EXISTS (

        SELECT 1

        FROM public.generation_model_benchmarks gmb

        WHERE gmb.source_benchmark_job_id = OLD.id

          AND gmb.benchmark_status =
                'HUMAN_APPROVED'

    )
    THEN

        RAISE EXCEPTION
            'APPROVED_BENCHMARK_EVIDENCE_JOB_CANNOT_BE_DELETED';

    END IF;


    RETURN OLD;

END;

$function$
