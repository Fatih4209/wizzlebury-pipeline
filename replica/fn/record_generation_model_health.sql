CREATE OR REPLACE FUNCTION public.record_generation_model_health(p_model_id uuid, p_new_status text, p_check_source text, p_reason text, p_success_rate numeric DEFAULT NULL::numeric, p_average_latency_seconds numeric DEFAULT NULL::numeric, p_provider_http_status integer DEFAULT NULL::integer, p_provider_request_id text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

DECLARE

    v_previous_status text;
    v_exists boolean;

BEGIN

    -- MODEL EXISTS

    IF NOT EXISTS (
        SELECT 1
        FROM public.generation_models gm
        WHERE gm.id = p_model_id
    )
    THEN
        RAISE EXCEPTION
            'GENERATION_MODEL_NOT_FOUND';
    END IF;


    -- STATUS

    IF p_new_status NOT IN (
        'UNKNOWN',
        'AVAILABLE',
        'DEGRADED',
        'UNAVAILABLE'
    )
    THEN
        RAISE EXCEPTION
            'INVALID_MODEL_HEALTH_STATUS';
    END IF;


    -- SOURCE

    IF p_check_source NOT IN (
        'API_HEALTH_CHECK',
        'BENCHMARK',
        'PROVIDER_RESPONSE',
        'MANUAL_INCIDENT',
        'SYSTEM_RECOVERY'
    )
    THEN
        RAISE EXCEPTION
            'INVALID_MODEL_HEALTH_SOURCE';
    END IF;


    IF p_reason IS NULL
       OR btrim(p_reason) = ''
    THEN
        RAISE EXCEPTION
            'MODEL_HEALTH_REASON_REQUIRED';
    END IF;


    IF p_success_rate IS NOT NULL
       AND (
            p_success_rate < 0
            OR p_success_rate > 1
       )
    THEN
        RAISE EXCEPTION
            'INVALID_MODEL_HEALTH_SUCCESS_RATE';
    END IF;


    IF p_average_latency_seconds IS NOT NULL
       AND p_average_latency_seconds < 0
    THEN
        RAISE EXCEPTION
            'INVALID_MODEL_HEALTH_LATENCY';
    END IF;


    -- LOCK EXISTING ROW

    SELECT
        gmh.availability_status
    INTO
        v_previous_status
    FROM public.generation_model_health gmh
    WHERE gmh.model_id = p_model_id
    FOR UPDATE;

    v_exists := FOUND;


    -- CONTROLLED MUTATION

    PERFORM set_config(
        'm417.model_health_update',
        'on',
        true
    );


    IF v_exists THEN

        UPDATE public.generation_model_health
        SET
            availability_status = p_new_status,
            success_rate = p_success_rate,
            average_latency_seconds =
                p_average_latency_seconds,
            last_checked_at = now(),
            failure_reason =
                CASE
                    WHEN p_new_status IN (
                        'DEGRADED',
                        'UNAVAILABLE'
                    )
                    THEN p_reason
                    ELSE NULL
                END,
            metadata =
                COALESCE(
                    p_metadata,
                    '{}'::jsonb
                ),
            updated_at = now()
        WHERE model_id = p_model_id;

    ELSE

        INSERT INTO public.generation_model_health (
            model_id,
            availability_status,
            success_rate,
            average_latency_seconds,
            last_checked_at,
            failure_reason,
            metadata,
            updated_at
        )
        VALUES (
            p_model_id,
            p_new_status,
            p_success_rate,
            p_average_latency_seconds,
            now(),
            CASE
                WHEN p_new_status IN (
                    'DEGRADED',
                    'UNAVAILABLE'
                )
                THEN p_reason
                ELSE NULL
            END,
            COALESCE(
                p_metadata,
                '{}'::jsonb
            ),
            now()
        );

    END IF;


    PERFORM set_config(
        'm417.model_health_update',
        'off',
        true
    );


    -- AUDIT HISTORY

    INSERT INTO public.generation_model_health_history (
        model_id,
        previous_status,
        new_status,
        check_source,
        reason,
        success_rate,
        average_latency_seconds,
        provider_http_status,
        provider_request_id,
        metadata,
        checked_at
    )
    VALUES (
        p_model_id,
        v_previous_status,
        p_new_status,
        p_check_source,
        p_reason,
        p_success_rate,
        p_average_latency_seconds,
        p_provider_http_status,
        p_provider_request_id,
        COALESCE(
            p_metadata,
            '{}'::jsonb
        ),
        now()
    );


    RETURN p_model_id;

END;

$function$
