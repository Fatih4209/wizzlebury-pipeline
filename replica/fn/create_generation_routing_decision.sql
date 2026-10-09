CREATE OR REPLACE FUNCTION public.create_generation_routing_decision(p_shot_specification_id uuid, p_policy_id uuid, p_attempt_no integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE

    v_shot_id uuid;

    v_policy_status text;
    v_policy_approved_at timestamptz;

    v_min_quality numeric;
    v_min_pass_rate numeric;

    v_quality_weight numeric;
    v_cost_weight numeric;
    v_reliability_weight numeric;
    v_latency_weight numeric;

    v_max_attempts integer;
    v_fallback_second boolean;

    v_require_verified_pricing boolean;
    v_require_available_health boolean;

    v_existing_decision_id uuid;
    v_existing_status text;
    v_existing_revision integer;

    v_next_revision integer := 1;

    v_candidate_count integer := 0;
    v_technical_candidate_count integer := 0;
    v_benchmark_candidate_count integer := 0;

    v_selected_model_id uuid;
    v_selected_pricing_id uuid;
    v_selected_role text;
    v_selected_cost numeric;

    v_lowest_cost numeric;
    v_fastest_latency numeric;

    v_decision_id uuid;

    v_failure_status text;
    v_failure_reason text;

    v_candidate_scores jsonb := '[]'::jsonb;

BEGIN


    -- =====================================================
    -- 1. INPUT
    -- =====================================================

    IF p_attempt_no NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION
            'INVALID_ROUTING_ATTEMPT_NO';
    END IF;


    -- =====================================================
    -- 2. SPECIFICATION
    -- =====================================================

    SELECT ss.shot_id
    INTO v_shot_id

    FROM public.shot_specifications ss

    WHERE ss.id = p_shot_specification_id
      AND ss.status = 'LOCKED'
      AND ss.locked_at IS NOT NULL
      AND ss.is_active = true

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_REQUIRES_LOCKED_ACTIVE_SPECIFICATION';
    END IF;


    -- =====================================================
    -- 3. CURRENT DECISION
    --
    -- Lock the current routing record so concurrent router
    -- calls cannot both supersede it.
    -- =====================================================

    SELECT
        grd.id,
        grd.decision_status,
        grd.decision_revision

    INTO
        v_existing_decision_id,
        v_existing_status,
        v_existing_revision

    FROM public.generation_routing_decisions grd

    WHERE grd.shot_id = v_shot_id
      AND grd.attempt_no = p_attempt_no
      AND grd.is_current = true

    FOR UPDATE;


    IF FOUND THEN

        -- -------------------------------------------------
        -- SELECTED decisions remain deterministic.
        -- Runtime health/pricing/provider checks are handled
        -- again by acquisition gates.
        -- -------------------------------------------------

        IF v_existing_status = 'SELECTED' THEN
            RETURN v_existing_decision_id;
        END IF;


        -- -------------------------------------------------
        -- Only transient blocked outcomes may be re-evaluated.
        -- -------------------------------------------------

        IF v_existing_status NOT IN (
            'NO_ELIGIBLE_MODEL',
            'BUDGET_BLOCKED',
            'HEALTH_BLOCKED',
            'PRICING_BLOCKED'
        )
        THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_NOT_REEVALUATABLE: %',
                v_existing_status;
        END IF;


        -- No attempt may already consume the blocked decision.

        IF EXISTS (
            SELECT 1
            FROM public.attempts a
            WHERE a.routing_decision_id =
                  v_existing_decision_id
        )
        THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_ALREADY_USED_BY_ATTEMPT';
        END IF;


        v_next_revision :=
            v_existing_revision + 1;


        -- Controlled CURRENT -> HISTORICAL transition.

        PERFORM set_config(
            'm417.routing_supersession',
            'on',
            true
        );


        UPDATE public.generation_routing_decisions
        SET is_current = false
        WHERE id = v_existing_decision_id
          AND is_current = true;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_SUPERSESSION_FAILED';
        END IF;


        PERFORM set_config(
            'm417.routing_supersession',
            'off',
            true
        );

    END IF;


    -- A decision retired outside this function (specification
    -- supersession) leaves no current row. Continue its numbering
    -- instead of colliding with revision 1.
    IF v_existing_decision_id IS NULL THEN

        SELECT COALESCE(MAX(grd.decision_revision), 0) + 1
        INTO v_next_revision
        FROM public.generation_routing_decisions grd
        WHERE grd.shot_id = v_shot_id
          AND grd.attempt_no = p_attempt_no;

    END IF;


    -- =====================================================
    -- 4. POLICY
    -- =====================================================

    SELECT
        grp.status,
        grp.approved_at,

        grp.minimum_quality_score,
        grp.minimum_pass_rate,

        grp.quality_weight,
        grp.cost_weight,
        grp.reliability_weight,
        grp.latency_weight,

        grp.max_attempts,
        grp.fallback_on_second_attempt,

        grp.require_verified_pricing,
        grp.require_available_health

    INTO
        v_policy_status,
        v_policy_approved_at,

        v_min_quality,
        v_min_pass_rate,

        v_quality_weight,
        v_cost_weight,
        v_reliability_weight,
        v_latency_weight,

        v_max_attempts,
        v_fallback_second,

        v_require_verified_pricing,
        v_require_available_health

    FROM public.generation_routing_policies grp

    WHERE grp.id = p_policy_id

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_FOUND';
    END IF;


    IF v_policy_status <> 'ACTIVE'
       OR v_policy_approved_at IS NULL
    THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_ACTIVE';
    END IF;


    IF p_attempt_no > v_max_attempts THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_ATTEMPT_LIMIT_EXCEEDED';
    END IF;


    -- =====================================================
    -- 5. TEMP CANDIDATES
    -- =====================================================

    CREATE TEMP TABLE IF NOT EXISTS
    pg_temp.m417_routing_candidates
    (
        model_id uuid,
        pricing_id uuid,

        route_role text,
        route_priority integer,

        estimated_cost numeric,

        quality_score numeric,
        pass_rate numeric,
        latency_seconds numeric,

        routing_score numeric,

        technically_eligible boolean,
        pricing_compatible boolean,
        health_compatible boolean,
        benchmark_eligible boolean,
        policy_eligible boolean,

        rejection_reasons jsonb
    )
    ON COMMIT DROP;


    TRUNCATE TABLE
        pg_temp.m417_routing_candidates;


    -- =====================================================
    -- 6. LOAD CANDIDATES
    -- =====================================================

    INSERT INTO pg_temp.m417_routing_candidates (

        model_id,
        pricing_id,

        route_role,
        route_priority,

        estimated_cost,

        quality_score,
        pass_rate,
        latency_seconds,

        technically_eligible,
        pricing_compatible,
        health_compatible,
        benchmark_eligible,
        policy_eligible,

        rejection_reasons
    )

    SELECT

        gpm.model_id,
        ec.pricing_id,

        gpm.route_role,
        gpm.route_priority,

        ec.estimated_cost,

        public.calculate_benchmark_quality_score(
            b.continuity_score,
            b.motion_score,
            b.face_score,
            b.anatomy_score,
            b.prompt_adherence_score,
            b.camera_score,
            b.expression_score,
            b.lip_sync_score
        ),

        b.pass_rate,
        b.average_generation_seconds,

        ec.technically_eligible,
        ec.pricing_compatible,
        ec.health_compatible,

        (
            b.id IS NOT NULL
            AND b.benchmark_status = 'HUMAN_APPROVED'
            AND b.approved_at IS NOT NULL
        ),

        (
            ec.technically_eligible = true

            AND b.id IS NOT NULL

            AND b.benchmark_status =
                'HUMAN_APPROVED'

            AND b.approved_at IS NOT NULL

            AND public.calculate_benchmark_quality_score(
                b.continuity_score,
                b.motion_score,
                b.face_score,
                b.anatomy_score,
                b.prompt_adherence_score,
                b.camera_score,
                b.expression_score,
                b.lip_sync_score
            ) >= v_min_quality

            AND b.pass_rate >=
                v_min_pass_rate

            AND (
                gpm.minimum_quality_override IS NULL

                OR

                public.calculate_benchmark_quality_score(
                    b.continuity_score,
                    b.motion_score,
                    b.face_score,
                    b.anatomy_score,
                    b.prompt_adherence_score,
                    b.camera_score,
                    b.expression_score,
                    b.lip_sync_score
                ) >=
                    gpm.minimum_quality_override
            )

            AND (
                gpm.maximum_estimated_cost IS NULL
                OR ec.estimated_cost <=
                    gpm.maximum_estimated_cost
            )

            AND (
                v_require_verified_pricing = false
                OR ec.pricing_compatible = true
            )

            AND (
                v_require_available_health = false
                OR ec.health_compatible = true
            )
        ),

        (
            ec.rejection_reasons

            ||

            CASE
                WHEN b.id IS NULL
                THEN
                    '["APPROVED_BENCHMARK_MISSING"]'::jsonb
                ELSE
                    '[]'::jsonb
            END

            ||

            CASE
                WHEN b.id IS NOT NULL
                 AND b.pass_rate < v_min_pass_rate
                THEN
                    '["PASS_RATE_BELOW_POLICY_MINIMUM"]'::jsonb
                ELSE
                    '[]'::jsonb
            END

            ||

            CASE
                WHEN b.id IS NOT NULL
                 AND (
                        b.continuity_score IS NULL
                     OR b.motion_score IS NULL
                     OR b.face_score IS NULL
                     OR b.anatomy_score IS NULL
                     OR b.prompt_adherence_score IS NULL
                     OR b.camera_score IS NULL
                     OR b.expression_score IS NULL
                     OR b.lip_sync_score IS NULL
                     OR b.pass_rate IS NULL
                     OR b.average_generation_seconds IS NULL
                 )
                THEN
                    '["APPROVED_BENCHMARK_INCOMPLETE"]'::jsonb
                ELSE
                    '[]'::jsonb
            END
        )

    FROM public.generation_policy_models gpm


    JOIN LATERAL (

        SELECT *

        FROM public.evaluate_generation_candidates(
            p_shot_specification_id
        ) ecx

        WHERE ecx.model_id = gpm.model_id

        LIMIT 1

    ) ec ON true


    LEFT JOIN LATERAL (

        SELECT b1.*

        FROM public.generation_model_benchmarks b1

        WHERE b1.model_id = gpm.model_id

          AND b1.benchmark_status =
                'HUMAN_APPROVED'

          AND b1.approved_at IS NOT NULL

        ORDER BY
            b1.benchmark_version DESC

        LIMIT 1

    ) b ON true


    WHERE gpm.policy_id = p_policy_id
      AND gpm.enabled = true;


    -- =====================================================
    -- 7. ATTEMPT ROUTE
    -- =====================================================

    IF p_attempt_no = 1 THEN

        DELETE FROM pg_temp.m417_routing_candidates
        WHERE route_role <> 'PRIMARY';


    ELSIF p_attempt_no = 2
       AND v_fallback_second = true
    THEN

        DELETE FROM pg_temp.m417_routing_candidates
        WHERE route_role NOT IN (
            'FALLBACK',
            'EMERGENCY'
        );

    END IF;


    SELECT COUNT(*)
    INTO v_candidate_count

    FROM pg_temp.m417_routing_candidates;


    -- =====================================================
    -- 8. NO ROUTE
    -- =====================================================

    IF v_candidate_count = 0 THEN

        INSERT INTO public.generation_routing_decisions (

            shot_id,
            shot_specification_id,
            policy_id,
            attempt_no,

            decision_revision,
            is_current,

            decision_status,
            decision_reason,
            candidate_scores
        )

        VALUES (

            v_shot_id,
            p_shot_specification_id,
            p_policy_id,
            p_attempt_no,

            v_next_revision,
            true,

            'NO_ELIGIBLE_MODEL',

            CASE
                WHEN p_attempt_no = 2
                 AND v_fallback_second = true
                THEN
                    'NO_ENABLED_FALLBACK_OR_EMERGENCY_MODEL'
                ELSE
                    'NO_ENABLED_POLICY_MODEL'
            END,

            '[]'::jsonb
        )

        RETURNING id
        INTO v_decision_id;


        RETURN v_decision_id;

    END IF;


    -- =====================================================
    -- 9. COUNTS
    -- =====================================================

    SELECT COUNT(*)
    INTO v_technical_candidate_count

    FROM pg_temp.m417_routing_candidates

    WHERE technically_eligible = true;


    SELECT COUNT(*)
    INTO v_benchmark_candidate_count

    FROM pg_temp.m417_routing_candidates

    WHERE benchmark_eligible = true;


    -- =====================================================
    -- 10. NORMALIZATION BASELINES
    -- =====================================================

    SELECT
        MIN(estimated_cost),
        MIN(latency_seconds)

    INTO
        v_lowest_cost,
        v_fastest_latency

    FROM pg_temp.m417_routing_candidates

    WHERE policy_eligible = true;


    -- =====================================================
    -- 11. SCORE
    -- =====================================================

    UPDATE pg_temp.m417_routing_candidates c

    SET routing_score =

        public.calculate_generation_routing_score(

            c.quality_score,
            c.estimated_cost,
            v_lowest_cost,
            c.pass_rate,
            c.latency_seconds,
            v_fastest_latency,

            v_quality_weight,
            v_cost_weight,
            v_reliability_weight,
            v_latency_weight
        )

    WHERE c.policy_eligible = true;


    -- =====================================================
    -- 12. AUDIT SNAPSHOT
    -- =====================================================

    SELECT COALESCE(

        jsonb_agg(

            jsonb_build_object(

                'model_id', c.model_id,
                'pricing_id', c.pricing_id,
                'route_role', c.route_role,
                'route_priority', c.route_priority,
                'estimated_cost', c.estimated_cost,
                'quality_score', c.quality_score,
                'pass_rate', c.pass_rate,
                'latency_seconds', c.latency_seconds,
                'routing_score', c.routing_score,
                'technically_eligible',
                    c.technically_eligible,
                'pricing_compatible',
                    c.pricing_compatible,
                'health_compatible',
                    c.health_compatible,
                'benchmark_eligible',
                    c.benchmark_eligible,
                'policy_eligible',
                    c.policy_eligible,
                'rejection_reasons',
                    c.rejection_reasons
            )

            ORDER BY
                c.routing_score DESC NULLS LAST,
                c.route_priority ASC,
                c.estimated_cost ASC NULLS LAST,
                c.model_id
        ),

        '[]'::jsonb
    )

    INTO v_candidate_scores

    FROM pg_temp.m417_routing_candidates c;


    -- =====================================================
    -- 13. WINNER
    -- =====================================================

    SELECT
        c.model_id,
        c.pricing_id,
        c.route_role,
        c.estimated_cost

    INTO
        v_selected_model_id,
        v_selected_pricing_id,
        v_selected_role,
        v_selected_cost

    FROM pg_temp.m417_routing_candidates c

    WHERE c.policy_eligible = true
      AND c.routing_score IS NOT NULL

    ORDER BY
        c.routing_score DESC,
        c.route_priority ASC,
        c.estimated_cost ASC,
        c.model_id

    LIMIT 1;


    -- =====================================================
    -- 14. SELECTED
    -- =====================================================

    IF v_selected_model_id IS NOT NULL THEN

        INSERT INTO public.generation_routing_decisions (

            shot_id,
            shot_specification_id,
            policy_id,
            attempt_no,

            decision_revision,
            is_current,

            selected_model_id,
            selected_pricing_id,
            route_role,
            estimated_cost,

            decision_status,
            decision_reason,
            candidate_scores
        )

        VALUES (

            v_shot_id,
            p_shot_specification_id,
            p_policy_id,
            p_attempt_no,

            v_next_revision,
            true,

            v_selected_model_id,
            v_selected_pricing_id,
            v_selected_role,
            v_selected_cost,

            'SELECTED',
            'DETERMINISTIC_ROUTER_SELECTION',
            v_candidate_scores
        )

        RETURNING id
        INTO v_decision_id;


        RETURN v_decision_id;

    END IF;


    -- =====================================================
    -- 15. FAILURE CLASSIFICATION
    -- =====================================================

    IF v_technical_candidate_count = 0 THEN

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'NO_TECHNICALLY_ELIGIBLE_MODEL';


    ELSIF v_benchmark_candidate_count = 0 THEN

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'NO_HUMAN_APPROVED_BENCHMARK';


    ELSIF v_require_available_health = true
       AND NOT EXISTS (

            SELECT 1

            FROM pg_temp.m417_routing_candidates c

            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.health_compatible = true
       )
    THEN

        v_failure_status :=
            'HEALTH_BLOCKED';

        v_failure_reason :=
            'NO_AVAILABLE_HEALTHY_MODEL';


    ELSIF v_require_verified_pricing = true
       AND NOT EXISTS (

            SELECT 1

            FROM pg_temp.m417_routing_candidates c

            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.pricing_compatible = true
       )
    THEN

        v_failure_status :=
            'PRICING_BLOCKED';

        v_failure_reason :=
            'VERIFIED_PRICING_REQUIRED';


    ELSIF NOT EXISTS (
            SELECT 1
            FROM pg_temp.m417_routing_candidates c
            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.quality_score IS NOT NULL
              AND c.pass_rate IS NOT NULL
              AND c.latency_seconds IS NOT NULL
       )
    THEN

        -- Every approved benchmark is missing a score, a pass
        -- rate or a generation time. That is a data gap, not a
        -- quality verdict.
        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'APPROVED_BENCHMARK_INCOMPLETE';

    ELSE

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'POLICY_THRESHOLDS_NOT_MET';

    END IF;


    -- =====================================================
    -- 16. BLOCKED DECISION
    -- =====================================================

    INSERT INTO public.generation_routing_decisions (

        shot_id,
        shot_specification_id,
        policy_id,
        attempt_no,

        decision_revision,
        is_current,

        decision_status,
        decision_reason,
        candidate_scores
    )

    VALUES (

        v_shot_id,
        p_shot_specification_id,
        p_policy_id,
        p_attempt_no,

        v_next_revision,
        true,

        v_failure_status,
        v_failure_reason,
        v_candidate_scores
    )

    RETURNING id
    INTO v_decision_id;


    RETURN v_decision_id;

END;
$function$
