CREATE OR REPLACE FUNCTION public.validate_generation_benchmark_evidence()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_job_model_id uuid;
    v_job_status text;

    v_actual_cost numeric;

    v_output_url text;
    v_storage_path text;

    v_completed_at timestamptz;

BEGIN

    -- -----------------------------------------------------
    -- HUMAN_APPROVED benchmark MUST have evidence.
    -- -----------------------------------------------------

    IF NEW.benchmark_status = 'HUMAN_APPROVED'
       AND NEW.source_benchmark_job_id IS NULL
    THEN

        RAISE EXCEPTION
            'HUMAN_APPROVED_BENCHMARK_REQUIRES_SOURCE_JOB';

    END IF;


    -- Draft/non-approved benchmark may exist before
    -- evidence assignment.

    IF NEW.source_benchmark_job_id IS NULL THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- LOAD SOURCE JOB
    -- -----------------------------------------------------

    SELECT
        gbj.model_id,
        gbj.status,
        gbj.actual_cost,
        gbj.output_url,
        gbj.storage_path,
        gbj.completed_at

    INTO
        v_job_model_id,
        v_job_status,
        v_actual_cost,
        v_output_url,
        v_storage_path,
        v_completed_at

    FROM public.generation_benchmark_jobs gbj

    WHERE gbj.id =
        NEW.source_benchmark_job_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'BENCHMARK_SOURCE_JOB_NOT_FOUND';

    END IF;


    -- -----------------------------------------------------
    -- MODEL MUST MATCH
    -- -----------------------------------------------------

    IF v_job_model_id <> NEW.model_id THEN

        RAISE EXCEPTION
            'BENCHMARK_SOURCE_JOB_MODEL_MISMATCH';

    END IF;


    -- -----------------------------------------------------
    -- HUMAN APPROVAL REQUIRES SUCCESSFUL REAL OUTPUT
    -- -----------------------------------------------------

    IF NEW.benchmark_status = 'HUMAN_APPROVED' THEN

        IF v_job_status <> 'SUCCEEDED' THEN

            RAISE EXCEPTION
                'BENCHMARK_SOURCE_JOB_NOT_SUCCEEDED';

        END IF;


        IF v_actual_cost IS NULL THEN

            RAISE EXCEPTION
                'BENCHMARK_SOURCE_JOB_MISSING_ACTUAL_COST';

        END IF;


        IF v_completed_at IS NULL THEN

            RAISE EXCEPTION
                'BENCHMARK_SOURCE_JOB_MISSING_COMPLETION';

        END IF;


        IF v_output_url IS NULL
           AND v_storage_path IS NULL
        THEN

            RAISE EXCEPTION
                'BENCHMARK_SOURCE_JOB_MISSING_OUTPUT';

        END IF;

    END IF;


    RETURN NEW;

END;

$function$
