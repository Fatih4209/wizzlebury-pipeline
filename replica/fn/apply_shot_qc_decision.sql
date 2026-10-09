CREATE OR REPLACE FUNCTION public.apply_shot_qc_decision(p_output_id uuid, p_decision text, p_qc_score numeric DEFAULT NULL::numeric, p_qc_notes text DEFAULT NULL::text, p_qc_details jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(output_id uuid, shot_id uuid, attempt_id uuid, attempt_no integer, qc_status text, shot_state text, is_canonical boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

DECLARE
    v_attempt_id uuid;
    v_shot_id uuid;

    v_attempt_no integer;
    v_attempt_status text;

    v_output_qc_status text;
    v_output_is_canonical boolean;

    v_shot_state text;

    v_storage_path text;
    v_source_url text;

    v_final_shot_state text;
    v_final_qc_status text;
    v_final_is_canonical boolean;

BEGIN

    -- =====================================================
    -- 1. INPUT VALIDATION
    -- =====================================================

    IF p_output_id IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_ID_REQUIRED';
    END IF;


    IF p_decision IS NULL
       OR p_decision NOT IN ('PASS', 'FAIL')
    THEN
        RAISE EXCEPTION 'INVALID_QC_DECISION';
    END IF;


    IF p_qc_score IS NOT NULL
       AND (
            p_qc_score < 0
            OR p_qc_score > 100
       )
    THEN
        RAISE EXCEPTION 'INVALID_QC_SCORE';
    END IF;


    -- =====================================================
    -- 2. LOCK OUTPUT
    -- =====================================================

    SELECT
        go.attempt_id,
        go.shot_id,
        go.qc_status,
        go.is_canonical,
        go.storage_path,
        go.source_url

    INTO
        v_attempt_id,
        v_shot_id,
        v_output_qc_status,
        v_output_is_canonical,
        v_storage_path,
        v_source_url

    FROM public.generation_outputs go

    WHERE go.id = p_output_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'GENERATION_OUTPUT_NOT_FOUND';
    END IF;


    -- Prevent accidental second QC decision.
    IF v_output_qc_status IN ('PASS', 'FAIL') THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_ALREADY_REVIEWED: %',
            v_output_qc_status;
    END IF;


    IF v_output_is_canonical IS TRUE THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_ALREADY_CANONICAL';
    END IF;


    -- =====================================================
    -- 3. LOCK ATTEMPT
    -- =====================================================

    SELECT
        a.attempt_no,
        a.status

    INTO
        v_attempt_no,
        v_attempt_status

    FROM public.attempts a

    WHERE a.id = v_attempt_id
      AND a.shot_id = v_shot_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'OUTPUT_ATTEMPT_RELATION_INVALID';
    END IF;


    IF v_attempt_status <> 'SUCCEEDED' THEN
        RAISE EXCEPTION
            'QC_REQUIRES_SUCCEEDED_ATTEMPT: %',
            v_attempt_status;
    END IF;


    IF v_attempt_no NOT IN (1, 2) THEN
        RAISE EXCEPTION
            'INVALID_ATTEMPT_NUMBER: %',
            v_attempt_no;
    END IF;


    -- =====================================================
    -- 4. LOCK SHOT
    -- =====================================================

    SELECT s.state
    INTO v_shot_state

    FROM public.shots s

    WHERE s.id = v_shot_id

    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;


    IF v_shot_state <> 'QC_PENDING' THEN
        RAISE EXCEPTION
            'SHOT_NOT_READY_FOR_QC: %',
            v_shot_state;
    END IF;


    -- =====================================================
    -- 5. PASS
    -- =====================================================

    IF p_decision = 'PASS' THEN

        -- A canonical output must have a durable copy.
        -- Provider URLs (source_url) expire.
        IF v_storage_path IS NULL
           OR btrim(v_storage_path) = ''
        THEN
            RAISE EXCEPTION
                'QC_PASS_REQUIRES_DURABLE_STORAGE';
        END IF;


        UPDATE public.generation_outputs
        SET
            qc_status = 'PASS',
            qc_score = p_qc_score,
            qc_notes = p_qc_notes,
            qc_details = COALESCE(
                p_qc_details,
                '{}'::jsonb
            ),
            reviewed_at = now(),
            status = 'AVAILABLE',
            is_canonical = true

        WHERE id = p_output_id;


        -- Existing canonical-output trigger converts
        -- AVAILABLE + canonical into CANONICAL.
        UPDATE public.shots
        SET state = 'LOCKED'
        WHERE id = v_shot_id;


        v_final_shot_state := 'LOCKED';
        v_final_qc_status := 'PASS';
        v_final_is_canonical := true;


        INSERT INTO public.events (
            event_type,
            shot_id,
            attempt_id,
            severity,
            source,
            message,
            metadata
        )
        VALUES (
            'SHOT_QC_PASS',
            v_shot_id,
            v_attempt_id,
            'INFO',
            'QC_ENGINE',
            'Shot passed QC and canonical output was selected.',
            jsonb_build_object(
                'output_id', p_output_id,
                'attempt_no', v_attempt_no,
                'qc_score', p_qc_score
            )
        );


    -- =====================================================
    -- 6. FAIL
    -- =====================================================

    ELSE

        UPDATE public.generation_outputs
        SET
            qc_status = 'FAIL',
            qc_score = p_qc_score,
            qc_notes = p_qc_notes,
            qc_details = COALESCE(
                p_qc_details,
                '{}'::jsonb
            ),
            reviewed_at = now(),
            status = 'REJECTED',
            is_canonical = false

        WHERE id = p_output_id;


        -- ---------------------------------------------
        -- Attempt 1 failure:
        -- only this shot becomes retryable.
        -- ---------------------------------------------

        IF v_attempt_no = 1 THEN

            UPDATE public.shots
            SET state = 'RETRY_REQUIRED'
            WHERE id = v_shot_id;


            v_final_shot_state := 'RETRY_REQUIRED';


            INSERT INTO public.events (
                event_type,
                shot_id,
                attempt_id,
                severity,
                source,
                message,
                metadata
            )
            VALUES (
                'SHOT_QC_RETRY_REQUIRED',
                v_shot_id,
                v_attempt_id,
                'WARNING',
                'QC_ENGINE',
                'Shot failed QC on attempt 1. One retry is allowed.',
                jsonb_build_object(
                    'output_id', p_output_id,
                    'attempt_no', v_attempt_no,
                    'qc_score', p_qc_score
                )
            );


        -- ---------------------------------------------
        -- Attempt 2 failure:
        --
        -- Existing shot state machine requires:
        -- QC_PENDING -> RETRY_REQUIRED -> ESCALATED
        --
        -- Both happen in this transaction.
        -- No third paid attempt is possible.
        -- ---------------------------------------------

        ELSE

            UPDATE public.shots
            SET state = 'RETRY_REQUIRED'
            WHERE id = v_shot_id;


            UPDATE public.shots
            SET state = 'ESCALATED'
            WHERE id = v_shot_id;


            v_final_shot_state := 'ESCALATED';


            INSERT INTO public.events (
                event_type,
                shot_id,
                attempt_id,
                severity,
                source,
                message,
                metadata
            )
            VALUES (
                'SHOT_QC_ESCALATED',
                v_shot_id,
                v_attempt_id,
                'ERROR',
                'QC_ENGINE',
                'Shot failed QC on attempt 2 and requires human intervention.',
                jsonb_build_object(
                    'output_id', p_output_id,
                    'attempt_no', v_attempt_no,
                    'qc_score', p_qc_score,
                    'automatic_retry_allowed', false
                )
            );

        END IF;


        v_final_qc_status := 'FAIL';
        v_final_is_canonical := false;

    END IF;


    -- =====================================================
    -- 7. RETURN FINAL DECISION
    -- =====================================================

    RETURN QUERY

    SELECT
        p_output_id,
        v_shot_id,
        v_attempt_id,
        v_attempt_no,
        v_final_qc_status,
        v_final_shot_state,
        v_final_is_canonical,

        CASE

            WHEN p_decision = 'PASS'
                THEN 'CANONICAL_LOCKED'

            WHEN v_attempt_no = 1
                THEN 'RETRY_REQUIRED'

            ELSE 'ESCALATED'

        END::text;

END;

$function$
