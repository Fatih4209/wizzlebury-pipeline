CREATE OR REPLACE FUNCTION public.evaluate_generation_candidates(p_shot_specification_id uuid)
 RETURNS TABLE(model_id uuid, provider_code text, model_code text, model_display_name text, provider_status text, model_status text, health_status text, pricing_id uuid, billing_unit text, unit_price numeric, duration_seconds numeric, estimated_cost numeric, duration_compatible boolean, aspect_ratio_compatible boolean, resolution_compatible boolean, reference_compatible boolean, audio_compatible boolean, pricing_compatible boolean, health_compatible boolean, technically_eligible boolean, rejection_reasons jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$

DECLARE

    v_duration numeric;
    v_aspect_ratio text;
    v_resolution text;

    v_audio_required boolean;

    v_reference_required boolean;

BEGIN


    -- =====================================================
    -- LOAD SPECIFICATION
    -- =====================================================

    SELECT

        ss.duration_seconds,
        ss.aspect_ratio,
        ss.resolution,
        ss.audio_required,

        EXISTS (

            SELECT 1

            FROM public.shot_reference_assets sra

            WHERE
                sra.shot_specification_id =
                    ss.id

                AND sra.is_required = true

        )

    INTO

        v_duration,
        v_aspect_ratio,
        v_resolution,
        v_audio_required,
        v_reference_required

    FROM public.shot_specifications ss

    WHERE ss.id = p_shot_specification_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'SHOT_SPECIFICATION_NOT_FOUND';

    END IF;


    -- =====================================================
    -- RETURN MODEL CANDIDATES
    -- =====================================================

    RETURN QUERY

    WITH active_pricing AS (

        SELECT DISTINCT ON (gmp.model_id)

            gmp.id,
            gmp.model_id,
            gmp.billing_unit,
            gmp.unit_price,
            gmp.minimum_charge

        FROM public.generation_model_pricing gmp

        WHERE
            gmp.currency = 'USD'

            AND gmp.is_verified = true

            AND gmp.verified_at IS NOT NULL

            AND gmp.effective_from <= now()

            AND (
                gmp.effective_to IS NULL
                OR gmp.effective_to > now()
            )

        ORDER BY
            gmp.model_id,
            gmp.effective_from DESC,
            gmp.pricing_version DESC
    ),


    candidate_base AS (

        SELECT

            gm.id AS model_id,

            gp.provider_code,
            gm.model_code,
            gm.display_name,

            gp.status AS provider_status,
            gm.status AS model_status,

            COALESCE(
                gmh.availability_status,
                'UNKNOWN'
            ) AS health_status,

            ap.id AS pricing_id,
            ap.billing_unit,
            ap.unit_price,
            ap.minimum_charge,


            -- ---------------------------------------------
            -- DURATION
            -- ---------------------------------------------

            (
                (
                    gm.min_duration_seconds IS NULL
                    OR
                    v_duration >=
                        gm.min_duration_seconds
                )

                AND

                (
                    gm.max_duration_seconds IS NULL
                    OR
                    v_duration <=
                        gm.max_duration_seconds
                )
            ) AS duration_ok,


            -- ---------------------------------------------
            -- ASPECT RATIO
            -- ---------------------------------------------

            (
                jsonb_array_length(
                    gm.supported_aspect_ratios
                ) = 0

                OR

                gm.supported_aspect_ratios
                    ? v_aspect_ratio
            ) AS aspect_ok,


            -- ---------------------------------------------
            -- RESOLUTION
            --
            -- Empty capability list = unspecified.
            -- Non-empty = requested resolution must match.
            -- ---------------------------------------------

            (
                jsonb_array_length(
                    gm.supported_resolutions
                ) = 0

                OR

                gm.supported_resolutions
                    ? v_resolution

                OR

                gm.supported_resolutions
                    ? lower(v_resolution)

            ) AS resolution_ok,


            -- ---------------------------------------------
            -- REFERENCES
            -- ---------------------------------------------

            (
                v_reference_required = false

                OR

                gm.supports_reference_images = true
            ) AS reference_ok,


            -- ---------------------------------------------
            -- AUDIO
            --
            -- Current video router interpretation:
            --
            -- If audio is already produced externally,
            -- native video-model audio is NOT mandatory.
            --
            -- Therefore external canonical shot audio
            -- satisfies audio readiness.
            --
            -- Native audio becomes a capability advantage,
            -- not a hard requirement.
            -- ---------------------------------------------

            true AS audio_ok,


            -- ---------------------------------------------
            -- PRICING
            -- ---------------------------------------------

            (
                ap.id IS NOT NULL
                AND ap.billing_unit IN (
                    'PER_SECOND',
                    'PER_GENERATION'
                )
            ) AS pricing_ok,


            -- ---------------------------------------------
            -- HEALTH
            --
            -- UNKNOWN is NOT production eligible.
            --
            -- TESTING catalog entries may still be
            -- evaluated, but live routing will later
            -- require AVAILABLE health.
            -- ---------------------------------------------

            (
                COALESCE(
                    gmh.availability_status,
                    'UNKNOWN'
                ) = 'AVAILABLE'
            ) AS health_ok,


            -- ---------------------------------------------
            -- COST
            -- ---------------------------------------------

            CASE

                WHEN ap.id IS NULL
                    THEN NULL


                WHEN ap.billing_unit =
                    'PER_SECOND'
                THEN

                    GREATEST(
                        v_duration
                            * ap.unit_price,
                        ap.minimum_charge
                    )


                WHEN ap.billing_unit =
                    'PER_GENERATION'
                THEN

                    GREATEST(
                        ap.unit_price,
                        ap.minimum_charge
                    )


                ELSE NULL

            END AS calculated_cost

        FROM public.generation_models gm

        JOIN public.generation_providers gp
            ON gp.id = gm.provider_id

        LEFT JOIN public.generation_model_health gmh
            ON gmh.model_id = gm.id

        LEFT JOIN active_pricing ap
            ON ap.model_id = gm.id

        WHERE

            gm.media_type = 'VIDEO'

            AND gp.provider_type IN (
                'VIDEO',
                'MULTIMODAL'
            )

            AND gp.status IN (
                'TESTING',
                'ACTIVE'
            )

            AND gm.status IN (
                'TESTING',
                'ACTIVE'
            )
    )


    SELECT

        cb.model_id,
        cb.provider_code,
        cb.model_code,
        cb.display_name,

        cb.provider_status,
        cb.model_status,
        cb.health_status,

        cb.pricing_id,
        cb.billing_unit,
        cb.unit_price,

        v_duration,

        cb.calculated_cost,

        cb.duration_ok,
        cb.aspect_ok,
        cb.resolution_ok,
        cb.reference_ok,
        cb.audio_ok,

        cb.pricing_ok,
        cb.health_ok,


        (
            cb.duration_ok
            AND cb.aspect_ok
            AND cb.resolution_ok
            AND cb.reference_ok
            AND cb.audio_ok
            AND cb.pricing_ok
            AND cb.health_ok
        ) AS technically_eligible,


        (
            SELECT
                COALESCE(
                    jsonb_agg(reason),
                    '[]'::jsonb
                )

            FROM (

                SELECT
                    'DURATION_UNSUPPORTED'::text
                        AS reason
                WHERE NOT cb.duration_ok


                UNION ALL


                SELECT
                    'ASPECT_RATIO_UNSUPPORTED'
                WHERE NOT cb.aspect_ok


                UNION ALL


                SELECT
                    'RESOLUTION_UNSUPPORTED'
                WHERE NOT cb.resolution_ok


                UNION ALL


                SELECT
                    'REFERENCE_IMAGES_UNSUPPORTED'
                WHERE NOT cb.reference_ok


                UNION ALL


                SELECT
                    'AUDIO_UNSUPPORTED'
                WHERE NOT cb.audio_ok


                UNION ALL


                SELECT
                    'VERIFIED_PRICING_UNAVAILABLE'
                WHERE NOT cb.pricing_ok


                UNION ALL


                SELECT
                    CASE
                        WHEN cb.health_status = 'UNKNOWN'
                            THEN 'HEALTH_UNKNOWN'

                        WHEN cb.health_status = 'DEGRADED'
                            THEN 'HEALTH_DEGRADED'

                        WHEN cb.health_status = 'UNAVAILABLE'
                            THEN 'HEALTH_UNAVAILABLE'

                        ELSE 'HEALTH_NOT_AVAILABLE'
                    END
                WHERE NOT cb.health_ok

            ) rejection_list

        ) AS rejection_reasons


    FROM candidate_base cb

    ORDER BY

        (
            cb.duration_ok
            AND cb.aspect_ok
            AND cb.resolution_ok
            AND cb.reference_ok
            AND cb.audio_ok
            AND cb.pricing_ok
            AND cb.health_ok
        ) DESC,

        cb.calculated_cost ASC NULLS LAST,

        cb.provider_code,
        cb.model_code;


END;

$function$
