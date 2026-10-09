CREATE OR REPLACE FUNCTION public.calculate_benchmark_quality_score(p_continuity numeric, p_motion numeric, p_face numeric, p_anatomy numeric, p_prompt_adherence numeric, p_camera numeric, p_expression numeric, p_lip_sync numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$

DECLARE

    v_result numeric;

BEGIN

    IF p_continuity IS NULL
       OR p_motion IS NULL
       OR p_face IS NULL
       OR p_anatomy IS NULL
       OR p_prompt_adherence IS NULL
       OR p_camera IS NULL
       OR p_expression IS NULL
       OR p_lip_sync IS NULL
    THEN
        RETURN NULL;
    END IF;


    IF p_continuity NOT BETWEEN 0 AND 100
       OR p_motion NOT BETWEEN 0 AND 100
       OR p_face NOT BETWEEN 0 AND 100
       OR p_anatomy NOT BETWEEN 0 AND 100
       OR p_prompt_adherence NOT BETWEEN 0 AND 100
       OR p_camera NOT BETWEEN 0 AND 100
       OR p_expression NOT BETWEEN 0 AND 100
       OR p_lip_sync NOT BETWEEN 0 AND 100
    THEN
        RAISE EXCEPTION
            'BENCHMARK_SCORE_OUT_OF_RANGE';
    END IF;


    -- -----------------------------------------------------
    -- M417 QUALITY WEIGHTS
    --
    -- Character/world continuity: 25%
    -- Motion:                    15%
    -- Face:                      15%
    -- Anatomy:                   10%
    -- Prompt adherence:          15%
    -- Camera:                     8%
    -- Expression:                 7%
    -- Lip sync:                   5%
    --
    -- TOTAL = 100%
    -- -----------------------------------------------------

    v_result :=

          (p_continuity       * 0.25)
        + (p_motion           * 0.15)
        + (p_face             * 0.15)
        + (p_anatomy          * 0.10)
        + (p_prompt_adherence * 0.15)
        + (p_camera           * 0.08)
        + (p_expression       * 0.07)
        + (p_lip_sync         * 0.05);


    RETURN round(v_result, 4);

END;

$function$
