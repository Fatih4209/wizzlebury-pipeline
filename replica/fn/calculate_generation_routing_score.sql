CREATE OR REPLACE FUNCTION public.calculate_generation_routing_score(p_quality_score numeric, p_estimated_cost numeric, p_lowest_candidate_cost numeric, p_pass_rate numeric, p_latency_seconds numeric, p_fastest_candidate_latency numeric, p_quality_weight numeric, p_cost_weight numeric, p_reliability_weight numeric, p_latency_weight numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$

DECLARE

    v_quality_component numeric;
    v_cost_component numeric;
    v_reliability_component numeric;
    v_latency_component numeric;

    v_final_score numeric;

BEGIN

    -- -----------------------------------------------------
    -- REQUIRED VALUES
    -- -----------------------------------------------------

    IF p_quality_score IS NULL
       OR p_estimated_cost IS NULL
       OR p_lowest_candidate_cost IS NULL
       OR p_pass_rate IS NULL
       OR p_latency_seconds IS NULL
       OR p_fastest_candidate_latency IS NULL
    THEN
        RETURN NULL;
    END IF;


    -- -----------------------------------------------------
    -- RANGE VALIDATION
    -- -----------------------------------------------------

    IF p_quality_score < 0
       OR p_quality_score > 100
    THEN
        RAISE EXCEPTION
            'QUALITY_SCORE_OUT_OF_RANGE';
    END IF;


    IF p_pass_rate < 0
       OR p_pass_rate > 100
    THEN
        RAISE EXCEPTION
            'PASS_RATE_OUT_OF_RANGE';
    END IF;


    IF p_estimated_cost < 0
       OR p_lowest_candidate_cost < 0
    THEN
        RAISE EXCEPTION
            'COST_OUT_OF_RANGE';
    END IF;


    IF p_latency_seconds < 0
       OR p_fastest_candidate_latency < 0
    THEN
        RAISE EXCEPTION
            'LATENCY_OUT_OF_RANGE';
    END IF;


    -- -----------------------------------------------------
    -- WEIGHT VALIDATION
    -- -----------------------------------------------------

    IF p_quality_weight < 0
       OR p_cost_weight < 0
       OR p_reliability_weight < 0
       OR p_latency_weight < 0
    THEN
        RAISE EXCEPTION
            'ROUTING_WEIGHT_NEGATIVE';
    END IF;


    IF abs(
        (
            p_quality_weight
            + p_cost_weight
            + p_reliability_weight
            + p_latency_weight
        ) - 1.0
    ) > 0.000001
    THEN
        RAISE EXCEPTION
            'ROUTING_WEIGHTS_MUST_SUM_TO_ONE';
    END IF;


    -- =====================================================
    -- QUALITY
    --
    -- Benchmark quality already normalized 0..100.
    -- =====================================================

    v_quality_component :=
        p_quality_score;


    -- =====================================================
    -- COST SCORE
    --
    -- Cheapest candidate = 100.
    --
    -- Example:
    -- cheapest = $0.60
    -- candidate = $1.20
    -- score = 50
    --
    -- If all costs are zero:
    -- score = 100.
    -- =====================================================

    IF p_estimated_cost = 0
       AND p_lowest_candidate_cost = 0
    THEN

        v_cost_component := 100;

    ELSIF p_estimated_cost = 0 THEN

        v_cost_component := 100;

    ELSE

        v_cost_component :=
            LEAST(
                100,
                GREATEST(
                    0,
                    (
                        p_lowest_candidate_cost
                        / p_estimated_cost
                    ) * 100
                )
            );

    END IF;


    -- =====================================================
    -- RELIABILITY
    --
    -- Benchmark PASS rate.
    -- =====================================================

    v_reliability_component :=
        p_pass_rate;


    -- =====================================================
    -- LATENCY SCORE
    --
    -- Fastest candidate = 100.
    -- =====================================================

    IF p_latency_seconds = 0
       AND p_fastest_candidate_latency = 0
    THEN

        v_latency_component := 100;

    ELSIF p_latency_seconds = 0 THEN

        v_latency_component := 100;

    ELSE

        v_latency_component :=
            LEAST(
                100,
                GREATEST(
                    0,
                    (
                        p_fastest_candidate_latency
                        / p_latency_seconds
                    ) * 100
                )
            );

    END IF;


    -- =====================================================
    -- FINAL WEIGHTED SCORE
    -- =====================================================

    v_final_score :=

          (v_quality_component
                * p_quality_weight)

        + (v_cost_component
                * p_cost_weight)

        + (v_reliability_component
                * p_reliability_weight)

        + (v_latency_component
                * p_latency_weight);


    RETURN round(v_final_score, 4);

END;

$function$
