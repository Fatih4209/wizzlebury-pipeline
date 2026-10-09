-- ===== acquire_generation_attempt_v2 =====
CREATE OR REPLACE FUNCTION public.acquire_generation_attempt_v2(p_routing_decision_id uuid, p_idempotency_key text)
 RETURNS TABLE(attempt_id uuid, attempt_no integer, decision text, reserved_cost numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_generation_enabled boolean;
    v_shot_id uuid;
    v_spec_id uuid;
    v_episode_id uuid;
    v_attempt_no integer;
    v_prompt_version integer;
    v_provider text;
    v_model text;
    v_model_version text;
    v_estimated_cost numeric;
    v_routing_status text;
    v_selected_model_id uuid;
    v_selected_pricing_id uuid;
    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;
    v_monthly_available numeric;
    v_episode_available numeric;
    v_shot_available numeric;
    v_attempt_id uuid;
    v_existing_attempt_id uuid;
    v_existing_attempt_no integer;
    v_existing_cost numeric;
    v_shot_state text;
BEGIN
    -- =====================================================
    -- 1. INPUT
    -- =====================================================
    IF p_routing_decision_id IS NULL THEN
        RAISE EXCEPTION 'ROUTING_DECISION_REQUIRED';
    END IF;
    IF p_idempotency_key IS NULL
       OR btrim(p_idempotency_key) = ''
    THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    -- =====================================================
    -- 2. TRUE IDEMPOTENCY
    -- Same request returns the existing attempt.
    -- =====================================================
    SELECT
        a.id,
        a.attempt_no,
        a.estimated_cost
    INTO
        v_existing_attempt_id,
        v_existing_attempt_no,
        v_existing_cost
    FROM public.attempts a
    WHERE a.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN QUERY
        SELECT
            v_existing_attempt_id,
            v_existing_attempt_no,
            'ALREADY_ACQUIRED'::text,
            v_existing_cost;
        RETURN;
    END IF;
    -- =====================================================
    -- 3. MASTER KILL SWITCH
    -- =====================================================
    SELECT sf.value
    INTO v_generation_enabled
    FROM public.system_flags sf
    WHERE sf.key = 'generation_enabled'
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
    END IF;
    IF v_generation_enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'GENERATION_DISABLED';
    END IF;
    -- =====================================================
    -- 4. LOCK ROUTING DECISION
    -- =====================================================
    SELECT
        grd.shot_id,
        grd.shot_specification_id,
        grd.attempt_no,
        grd.decision_status,
        grd.selected_model_id,
        grd.selected_pricing_id,
        grd.estimated_cost
    INTO
        v_shot_id,
        v_spec_id,
        v_attempt_no,
        v_routing_status,
        v_selected_model_id,
        v_selected_pricing_id,
        v_estimated_cost
    FROM public.generation_routing_decisions grd
    WHERE grd.id = p_routing_decision_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROUTING_DECISION_NOT_FOUND';
    END IF;
    IF v_routing_status <> 'SELECTED' THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_routing_status;
    END IF;
    IF v_attempt_no NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION
            'INVALID_ROUTING_ATTEMPT_NO: %',
            v_attempt_no;
    END IF;
    IF v_selected_model_id IS NULL
       OR v_selected_pricing_id IS NULL
       OR v_estimated_cost IS NULL
       OR v_estimated_cost <= 0
    THEN
        RAISE EXCEPTION 'ROUTING_DECISION_INCOMPLETE';
    END IF;
    -- =====================================================
    -- 5. LOCK SHOT
    -- Prevent concurrent paid acquisition for same shot.
    -- =====================================================
    SELECT
        s.episode_id,
        s.state
    INTO
        v_episode_id,
        v_shot_state
    FROM public.shots s
    WHERE s.id = v_shot_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;
    -- Exact shot/attempt must still be unused.
    IF EXISTS (
        SELECT 1
        FROM public.attempts a
        WHERE a.shot_id = v_shot_id
          AND a.attempt_no = v_attempt_no
    ) THEN
        RAISE EXCEPTION
            'SHOT_ATTEMPT_ALREADY_EXISTS';
    END IF;
    -- A shot that already has a canonical output is finished.
    IF EXISTS (
        SELECT 1
        FROM public.generation_outputs go
        WHERE go.shot_id = v_shot_id
          AND go.is_canonical = true
    ) THEN
        RAISE EXCEPTION
            'SHOT_ALREADY_HAS_CANONICAL_OUTPUT';
    END IF;
    -- Attempt 2 requires attempt 1 to be finished without a usable
    -- result:
    --
    --   a) technical failure: attempt 1 FAILED / CANCELLED
    --   b) QC failure: attempt 1 SUCCEEDED, every output it produced
    --      was rejected by QC, and the shot is RETRY_REQUIRED
    IF v_attempt_no = 2 THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.attempts a
            WHERE a.shot_id = v_shot_id
              AND a.attempt_no = 1
              AND (
                    a.status IN (
                        'FAILED',
                        'CANCELLED'
                    )
                    OR
                    (
                        a.status = 'SUCCEEDED'
                        AND v_shot_state = 'RETRY_REQUIRED'
                        AND EXISTS (
                            SELECT 1
                            FROM public.generation_outputs go
                            WHERE go.attempt_id = a.id
                              AND go.qc_status = 'FAIL'
                        )
                        AND NOT EXISTS (
                            SELECT 1
                            FROM public.generation_outputs go
                            WHERE go.attempt_id = a.id
                              AND go.qc_status <> 'FAIL'
                        )
                    )
              )
        ) THEN
            RAISE EXCEPTION
                'ATTEMPT_2_REQUIRES_FINALIZED_ATTEMPT_1';
        END IF;
    END IF;
    -- =====================================================
    -- 6. CANONICAL SPECIFICATION
    -- =====================================================
    SELECT ss.version
    INTO v_prompt_version
    FROM public.shot_specifications ss
    WHERE ss.id = v_spec_id
      AND ss.shot_id = v_shot_id
      AND ss.status = 'LOCKED'
      AND ss.locked_at IS NOT NULL
      AND ss.is_active = true;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_CANONICAL';
    END IF;
    -- =====================================================
    -- 7. RESOLVE EXACT ROUTER MODEL + PROVIDER
    -- =====================================================
    SELECT
        gp.provider_code,
        gm.model_code
    INTO
        v_provider,
        v_model
    FROM public.generation_models gm
    JOIN public.generation_providers gp
        ON gp.id = gm.provider_id
    WHERE gm.id = v_selected_model_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROUTING_MODEL_PROVIDER_NOT_FOUND';
    END IF;
    -- Keep model_version aligned with the immutable
    -- model code currently selected by router.
    v_model_version := v_model;
    -- =====================================================
    -- 8. LOCK EXACT ACTIVE MONTHLY BUDGET
    -- =====================================================
    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_monthly_budget_id,
        v_monthly_available
    FROM public.budgets b
    WHERE b.budget_type = 'MONTHLY'
      AND b.reference_id IS NULL
      AND b.currency = 'USD'
      AND b.is_active = true
      AND (
          b.period_start IS NULL
          OR b.period_start <= now()
      )
      AND (
          b.period_end IS NULL
          OR b.period_end > now()
      )
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_MONTHLY_BUDGET_MISSING';
    END IF;
    -- =====================================================
    -- 9. LOCK EXACT EPISODE BUDGET
    -- =====================================================
    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_episode_budget_id,
        v_episode_available
    FROM public.budgets b
    WHERE b.budget_type = 'EPISODE'
      AND b.reference_id = v_episode_id
      AND b.currency = 'USD'
      AND b.is_active = true
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_EPISODE_BUDGET_MISSING';
    END IF;
    -- =====================================================
    -- 10. LOCK EXACT SHOT BUDGET
    -- =====================================================
    SELECT
        b.id,
        (
            b.hard_limit
            - b.reserved_amount
            - b.settled_amount
        )
    INTO
        v_shot_budget_id,
        v_shot_available
    FROM public.budgets b
    WHERE b.budget_type = 'SHOT'
      AND b.reference_id = v_shot_id
      AND b.currency = 'USD'
      AND b.is_active = true
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ACTIVE_SHOT_BUDGET_MISSING';
    END IF;
    -- =====================================================
    -- 11. HARD BUDGET GATES
    -- =====================================================
    IF v_monthly_available < v_estimated_cost THEN
        RAISE EXCEPTION 'MONTHLY_BUDGET_EXCEEDED';
    END IF;
    IF v_episode_available < v_estimated_cost THEN
        RAISE EXCEPTION 'EPISODE_BUDGET_EXCEEDED';
    END IF;
    IF v_shot_available < v_estimated_cost THEN
        RAISE EXCEPTION 'SHOT_BUDGET_EXCEEDED';
    END IF;
    -- =====================================================
    -- 12. CREATE ROUTER + BUDGET BOUND ATTEMPT
    --
    -- Existing DATA-81/84/93/97 triggers still perform
    -- production, manifest, readiness and router validation.
    -- =====================================================
    -- Marker checked by require_attempt_acquisition_path:
    -- attempts can only be created here.
    PERFORM set_config(
        'm417.attempt_acquisition',
        'on',
        true
    );
    INSERT INTO public.attempts (
        shot_id,
        attempt_no,
        idempotency_key,
        provider,
        model,
        prompt_version,
        model_version,
        status,
        estimated_cost,
        routing_decision_id,
        monthly_budget_id,
        episode_budget_id,
        shot_budget_id
    )
    VALUES (
        v_shot_id,
        v_attempt_no,
        p_idempotency_key,
        v_provider,
        v_model,
        v_prompt_version,
        v_model_version,
        'BUDGET_RESERVED',
        v_estimated_cost,
        p_routing_decision_id,
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    RETURNING id
    INTO v_attempt_id;
    PERFORM set_config(
        'm417.attempt_acquisition',
        'off',
        true
    );
    -- =====================================================
    -- 13. RESERVE ALL ACCOUNTING SCOPES
    -- =====================================================
    UPDATE public.budgets
    SET reserved_amount =
        reserved_amount + v_estimated_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );
    -- =====================================================
    -- 14. APPEND LEDGER
    -- =====================================================
    INSERT INTO public.cost_ledger (
        attempt_id,
        episode_id,
        shot_id,
        entry_type,
        amount,
        currency,
        description
    )
    VALUES (
        v_attempt_id,
        v_episode_id,
        v_shot_id,
        'RESERVE',
        v_estimated_cost,
        'USD',
        'Router-authorized generation reservation'
    );
    -- =====================================================
    -- 15. SHOT -> QUEUED
    -- =====================================================
    UPDATE public.shots
    SET state = 'QUEUED'
    WHERE id = v_shot_id;
    RETURN QUERY
    SELECT
        v_attempt_id,
        v_attempt_no,
        'AUTHORIZED'::text,
        v_estimated_cost;
END;
$function$
;
-- ===== add_m417_location_asset_plan =====
CREATE OR REPLACE FUNCTION public.add_m417_location_asset_plan(p_location_code text, p_asset_code text, p_asset_role text, p_view_type text, p_priority text, p_rules jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
    v_series_id uuid;
    v_location_id uuid;
begin
    select id
    into v_series_id
    from public.series
    where series_code = 'M417'
    limit 1;
    if v_series_id is null then
        raise exception 'M417 series not found';
    end if;
    select id
    into v_location_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_location_code
    limit 1;
    if v_location_id is null then
        raise exception
        'Location not found: %',
        p_location_code;
    end if;
    insert into public.location_asset_plan (
        series_id,
        location_id,
        asset_code,
        asset_role,
        view_type,
        priority,
        production_rules,
        status
    )
    values (
        v_series_id,
        v_location_id,
        p_asset_code,
        p_asset_role,
        p_view_type,
        p_priority,
        p_rules,
        'PLANNED'
    )
    on conflict (
        series_id,
        location_id,
        asset_code
    )
    do update set
        asset_role = excluded.asset_role,
        view_type = excluded.view_type,
        priority = excluded.priority,
        production_rules = excluded.production_rules;
end;
$function$
;
-- ===== add_m417_location_relationship =====
CREATE OR REPLACE FUNCTION public.add_m417_location_relationship(p_from_code text, p_to_code text, p_relationship_type text, p_minutes integer, p_travel_mode text, p_rules jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
    v_series_id uuid;
    v_from_id uuid;
    v_to_id uuid;
begin
    select id
    into v_series_id
    from public.series
    where series_code = 'M417'
    limit 1;
    if v_series_id is null then
        raise exception 'M417 series not found';
    end if;
    select id
    into v_from_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_from_code
    limit 1;
    select id
    into v_to_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_to_code
    limit 1;
    if v_from_id is null then
        raise exception
        'FROM location not found: %',
        p_from_code;
    end if;
    if v_to_id is null then
        raise exception
        'TO location not found: %',
        p_to_code;
    end if;
    insert into public.location_relationships (
        series_id,
        from_location_id,
        to_location_id,
        relationship_type,
        approximate_travel_minutes,
        travel_mode,
        geography_rules
    )
    values (
        v_series_id,
        v_from_id,
        v_to_id,
        p_relationship_type,
        p_minutes,
        p_travel_mode,
        p_rules
    )
    on conflict (
        series_id,
        from_location_id,
        to_location_id,
        relationship_type
    )
    do update set
        approximate_travel_minutes =
            excluded.approximate_travel_minutes,
        travel_mode =
            excluded.travel_mode,
        geography_rules =
            excluded.geography_rules;
end;
$function$
;
-- ===== apply_shot_qc_decision =====
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
;
-- ===== authorize_episode_production =====
CREATE OR REPLACE FUNCTION public.authorize_episode_production(p_episode_id uuid)
 RETURNS TABLE(episode_id uuid, production_authorized boolean, authorized_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_human_approved boolean;
    v_authorized_at timestamptz;
begin
    select
        e.state,
        e.human_approved
    into
        v_state,
        v_human_approved
    from public.episodes e
    where e.id = p_episode_id
    for update;
    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;
    if v_human_approved is not true then
        raise exception 'HUMAN_APPROVAL_REQUIRED';
    end if;
    if v_state <> 'APPROVED' then
        raise exception 'EPISODE_NOT_APPROVED';
    end if;
    v_authorized_at := now();
    update public.episodes
    set
        production_authorized = true,
        authorized_at = v_authorized_at,
        state = 'PRODUCTION'
    where id = p_episode_id;
    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message
    )
    values (
        'PRODUCTION_AUTHORIZED',
        p_episode_id,
        'INFO',
        'CONTROL_PLANE',
        'Episode production authorized'
    );
    return query
    select
        p_episode_id,
        true,
        v_authorized_at;
end;
$function$
;
-- ===== calculate_benchmark_quality_score =====
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
;
-- ===== calculate_generation_routing_score =====
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
;
-- ===== claim_attempt_submission =====
CREATE OR REPLACE FUNCTION public.claim_attempt_submission(p_attempt_id uuid, p_claimed_by text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, decision text, claimed_at timestamp with time zone, provider text, model text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_claimed_at timestamptz;
    v_provider text;
    v_model text;
    v_generation_enabled boolean;
begin
    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;
    select
        a.status,
        a.submission_claimed_at,
        a.provider,
        a.model
    into
        v_status,
        v_claimed_at,
        v_provider,
        v_model
    from public.attempts a
    where a.id = p_attempt_id
    for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_status in ('SUBMITTED', 'GENERATING') then
        return query
        select p_attempt_id, 'ALREADY_SUBMITTED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;
    end if;
    if v_status <> 'BUDGET_RESERVED' then
        return query
        select p_attempt_id, 'ALREADY_FINALIZED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;
    end if;
    if v_claimed_at is not null then
        return query
        select p_attempt_id, 'ALREADY_CLAIMED'::text,
               v_claimed_at, v_provider, v_model, v_status;
        return;
    end if;
    -- The kill switch may have been closed after the reservation.
    select sf.value
    into v_generation_enabled
    from public.system_flags sf
    where sf.key = 'generation_enabled';
    if not found then
        raise exception 'GENERATION_FLAG_MISSING';
    end if;
    if v_generation_enabled is not true then
        raise exception 'GENERATION_DISABLED';
    end if;
    v_claimed_at := now();
    update public.attempts
    set
        submission_claimed_at = v_claimed_at,
        submission_claimed_by = p_claimed_by
    where id = p_attempt_id;
    return query
    select p_attempt_id, 'CLAIMED'::text,
           v_claimed_at, v_provider, v_model, v_status;
end;
$function$
;
-- ===== consume_approval_token =====
CREATE OR REPLACE FUNCTION public.consume_approval_token(p_token text, p_expected_scope_type text, p_decision text, p_decided_by text, p_channel text, p_note text)
 RETURNS approval_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
begin
    if p_token is null or btrim(p_token) = '' then
        raise exception 'APPROVAL_TOKEN_REQUIRED';
    end if;
    if p_decision not in ('APPROVED', 'REJECTED') then
        raise exception 'INVALID_APPROVAL_DECISION';
    end if;
    if p_decided_by is null or btrim(p_decided_by) = '' then
        raise exception 'APPROVAL_DECIDER_REQUIRED';
    end if;
    select ar.*
    into v_row
    from public.approval_requests ar
    where ar.token_hash =
          encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
    for update;
    if not found then
        raise exception 'APPROVAL_TOKEN_INVALID';
    end if;
    if p_expected_scope_type is not null
       and v_row.scope_type <> p_expected_scope_type
    then
        raise exception
            'APPROVAL_TOKEN_SCOPE_MISMATCH: %',
            v_row.scope_type;
    end if;
    if v_row.status <> 'PENDING' then
        raise exception
            'APPROVAL_TOKEN_ALREADY_USED: %',
            v_row.status;
    end if;
    if v_row.expires_at <= now() then
        raise exception 'APPROVAL_TOKEN_EXPIRED';
    end if;
    update public.approval_requests ar
    set
        status = p_decision,
        decided_at = now(),
        decided_by = p_decided_by,
        decision_channel = p_channel,
        decision_note = p_note
    where ar.id = v_row.id
    returning ar.*
    into v_row;
    return v_row;
end;
$function$
;
-- ===== create_generation_routing_decision =====
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
;
-- ===== decide_human_approval =====
CREATE OR REPLACE FUNCTION public.decide_human_approval(p_token text, p_decision text, p_decided_by text, p_channel text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS TABLE(request_id uuid, scope_type text, scope_id uuid, status text, effect text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
    v_effect text := 'RECORDED';
    v_version integer;
    v_state text;
begin
    v_row := public.consume_approval_token(
        p_token,
        null,
        p_decision,
        p_decided_by,
        p_channel,
        p_note
    );
    if v_row.scope_type = 'SHOT_ESCALATION' then
        -- Escalations carry a choice, so they are decided through
        -- resolve_escalated_shot.
        raise exception 'USE_RESOLVE_ESCALATED_SHOT';
    end if;
    select e.production_version, e.state
    into v_version, v_state
    from public.episodes e
    where e.id = v_row.scope_id
    for update;
    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;
    if v_version is distinct from v_row.scope_version then
        raise exception
            'APPROVAL_VERSION_STALE: requested for v%, episode is v%',
            v_row.scope_version,
            v_version;
    end if;
    if v_row.scope_type = 'EPISODE_PRODUCTION' then
        if v_state <> 'PREPRODUCTION' then
            raise exception
                'EPISODE_NOT_AWAITING_PRODUCTION_APPROVAL: %',
                v_state;
        end if;
        if p_decision = 'APPROVED' then
            update public.episodes
            set
                human_approved = true,
                state = 'APPROVED'
            where id = v_row.scope_id;
            v_effect := 'EPISODE_APPROVED_FOR_PRODUCTION';
        end if;
    elsif v_row.scope_type = 'EPISODE_PUBLISH' then
        if v_state <> 'READY_TO_PUBLISH' then
            raise exception
                'EPISODE_NOT_AWAITING_PUBLISH_APPROVAL: %',
                v_state;
        end if;
        if p_decision = 'APPROVED' then
            v_effect := 'EPISODE_CLEARED_TO_PUBLISH';
        end if;
    end if;
    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'HUMAN_APPROVAL_' || p_decision,
        v_row.scope_id,
        case when p_decision = 'APPROVED' then 'INFO' else 'WARNING' end,
        'HUMAN_APPROVAL',
        v_row.scope_type || ' ' || lower(p_decision) || ' by ' || p_decided_by,
        jsonb_build_object(
            'request_id', v_row.id,
            'scope_type', v_row.scope_type,
            'scope_version', v_row.scope_version,
            'decided_by', p_decided_by,
            'channel', p_channel,
            'note', p_note
        )
    );
    return query
    select
        v_row.id,
        v_row.scope_type,
        v_row.scope_id,
        v_row.status,
        v_effect;
end;
$function$
;
-- ===== enforce_settlement_source_state =====
CREATE OR REPLACE FUNCTION public.enforce_settlement_source_state()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.status = 'SUCCEEDED'
       and old.status not in (
           'SUBMITTED',
           'GENERATING'
       )
    then
        raise exception
            'SUCCESS_REQUIRES_SUBMITTED_OR_GENERATING: %',
            old.status;
    end if;
    return new;
end;
$function$
;
-- ===== enforce_storyboard_review_integrity =====
CREATE OR REPLACE FUNCTION public.enforce_storyboard_review_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_asset_status text;
BEGIN
    -- -----------------------------------------------------
    -- APPROVED storyboard must be complete.
    -- -----------------------------------------------------
    IF NEW.status = 'APPROVED' THEN
        IF NEW.storyboard_asset_id IS NULL THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_ASSET';
        END IF;
        IF NEW.reviewed_at IS NULL THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_REVIEW_TIMESTAMP';
        END IF;
        IF NEW.reviewer_type IS NULL
           OR btrim(NEW.reviewer_type) = ''
        THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_REVIEWER';
        END IF;
        SELECT ar.status
        INTO v_asset_status
        FROM public.asset_registry ar
        WHERE ar.id = NEW.storyboard_asset_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'STORYBOARD_ASSET_NOT_FOUND';
        END IF;
        IF v_asset_status <> 'LOCKED' THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_ASSET_MUST_BE_LOCKED';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== episode_production_status =====
CREATE OR REPLACE FUNCTION public.episode_production_status(p_episode_id uuid)
 RETURNS TABLE(episode_state text, production_version integer, total_shots integer, locked_shots integer, cancelled_shots integer, escalated_shots integer, retry_required_shots integer, in_progress_shots integer, not_started_shots integer, pilot_locked boolean, ready_for_assembly boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    select
        e.state,
        e.production_version,
        count(s.id)::integer,
        count(*) filter (where s.state = 'LOCKED')::integer,
        count(*) filter (where s.state = 'CANCELLED')::integer,
        count(*) filter (where s.state = 'ESCALATED')::integer,
        count(*) filter (where s.state = 'RETRY_REQUIRED')::integer,
        count(*) filter (
            where s.state in (
                'QUEUED',
                'GENERATING',
                'GENERATED',
                'QC_PENDING',
                'FAILED_TECHNICAL'
            )
        )::integer,
        count(*) filter (
            where s.state in (
                'PLANNED',
                'STORYBOARD_PENDING',
                'STORYBOARD_APPROVED',
                'AUDIO_READY'
            )
        )::integer,
        coalesce(
            bool_or(s.id = pm.pilot_shot_id and s.state = 'LOCKED'),
            false
        ),
        (
            count(s.id) > 0
            and count(*) filter (where s.state = 'LOCKED') > 0
            and count(*) filter (
                    where s.state not in ('LOCKED', 'CANCELLED')
                ) = 0
        )
    from public.episodes e
    left join public.production_manifests pm
      on pm.episode_id = e.id
     and pm.production_version = e.production_version
     and pm.status = 'LOCKED'
    left join public.production_manifest_shots pms
      on pms.manifest_id = pm.id
    left join public.shots s
      on s.id = pms.shot_id
    where e.id = p_episode_id
    group by e.state, e.production_version;
$function$
;
-- ===== evaluate_generation_candidates =====
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
;
-- ===== find_stuck_attempts =====
CREATE OR REPLACE FUNCTION public.find_stuck_attempts(p_stale_minutes integer DEFAULT 30)
 RETURNS TABLE(attempt_id uuid, shot_id uuid, provider text, provider_job_id text, status text, last_activity timestamp with time zone, submission_claimed_at timestamp with time zone, recommended_action text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
    select
        x.id,
        x.shot_id,
        x.provider,
        x.provider_job_id,
        x.status,
        x.last_activity,
        x.submission_claimed_at,
        case
            when x.status = 'BUDGET_RESERVED'
             and x.submission_claimed_at is null
                then 'RESUME_SUBMISSION'
            when x.status = 'BUDGET_RESERVED'
                then 'RECONCILE_SUBMISSION'
            else 'POLL_PROVIDER'
        end
    from (
        select
            a.id,
            a.shot_id,
            a.provider,
            a.provider_job_id,
            a.status,
            a.submission_claimed_at,
            greatest(
                coalesce(a.heartbeat_at, '-infinity'::timestamptz),
                coalesce(a.last_provider_check_at, '-infinity'::timestamptz),
                coalesce(a.started_at, '-infinity'::timestamptz),
                coalesce(a.submission_claimed_at, '-infinity'::timestamptz),
                a.created_at
            ) as last_activity
        from public.attempts a
        where a.status in (
            'BUDGET_RESERVED',
            'SUBMITTED',
            'GENERATING'
        )
    ) x
    where x.last_activity
          < now() - make_interval(mins => p_stale_minutes)
    order by x.last_activity;
$function$
;
-- ===== mark_attempt_generating =====
CREATE OR REPLACE FUNCTION public.mark_attempt_generating(p_attempt_id uuid)
 RETURNS TABLE(attempt_id uuid, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_current_status text;
begin
    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;
    select a.status
    into v_current_status
    from public.attempts a
    where a.id = p_attempt_id
    for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_current_status <> 'SUBMITTED' then
        raise exception
            'ATTEMPT_NOT_READY_FOR_GENERATION: %',
            v_current_status;
    end if;
    update public.attempts
    set status = 'GENERATING'
    where id = p_attempt_id;
    return query
    select
        p_attempt_id,
        'GENERATING'::text;
end;
$function$
;
-- ===== mark_attempt_submitted =====
CREATE OR REPLACE FUNCTION public.mark_attempt_submitted(p_attempt_id uuid, p_provider_job_id text)
 RETURNS TABLE(attempt_id uuid, status text, provider_job_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_current_status text;
    v_current_job_id text;
    v_claimed_at timestamptz;
begin
    if p_attempt_id is null then
        raise exception 'ATTEMPT_ID_REQUIRED';
    end if;
    if p_provider_job_id is null
       or btrim(p_provider_job_id) = '' then
        raise exception 'PROVIDER_JOB_ID_REQUIRED';
    end if;
    select
        a.status,
        a.provider_job_id,
        a.submission_claimed_at
    into
        v_current_status,
        v_current_job_id,
        v_claimed_at
    from public.attempts a
    where a.id = p_attempt_id
    for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    -- Repeating the same call is harmless.
    if v_current_status in ('SUBMITTED', 'GENERATING')
       and v_current_job_id = p_provider_job_id
    then
        return query
        select p_attempt_id, v_current_status, v_current_job_id;
        return;
    end if;
    if v_current_status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_NOT_READY_FOR_SUBMISSION: %',
            v_current_status;
    end if;
    if v_claimed_at is null then
        raise exception 'ATTEMPT_SUBMISSION_NOT_CLAIMED';
    end if;
    update public.attempts
    set
        status = 'SUBMITTED',
        provider_job_id = p_provider_job_id,
        started_at = coalesce(started_at, now())
    where id = p_attempt_id;
    return query
    select
        p_attempt_id,
        'SUBMITTED'::text,
        p_provider_job_id;
end;
$function$
;
-- ===== prevent_approved_storyboard_review_delete =====
CREATE OR REPLACE FUNCTION public.prevent_approved_storyboard_review_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.status = 'APPROVED' THEN
        RAISE EXCEPTION
            'APPROVED_STORYBOARD_REVIEW_CANNOT_BE_DELETED';
    END IF;
    RETURN OLD;
END;
$function$
;
-- ===== prevent_canonical_generation_output_delete =====
CREATE OR REPLACE FUNCTION public.prevent_canonical_generation_output_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.is_canonical = true
       OR OLD.status = 'CANONICAL'
    THEN
        RAISE EXCEPTION
            'CANONICAL_GENERATION_OUTPUT_CANNOT_BE_DELETED';
    END IF;
    RETURN OLD;
END;
$function$
;
-- ===== prevent_cost_ledger_mutation =====
CREATE OR REPLACE FUNCTION public.prevent_cost_ledger_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    raise exception 'COST_LEDGER_IS_APPEND_ONLY';
end;
$function$
;
-- ===== prevent_event_mutation =====
CREATE OR REPLACE FUNCTION public.prevent_event_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    raise exception 'EVENT_LOG_IS_APPEND_ONLY';
end;
$function$
;
-- ===== prevent_locked_asset_mutation =====
CREATE OR REPLACE FUNCTION public.prevent_locked_asset_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if old.status = 'LOCKED' then
        -- Controlled retirement: only asset_registry, only
        -- LOCKED -> ARCHIVED, nothing else may change.
        if tg_table_name = 'asset_registry'
           and coalesce(
                   current_setting('m417.asset_retirement', true),
                   'off'
               ) = 'on'
           and new.status = 'ARCHIVED'
           and (to_jsonb(new) - 'status')
               = (to_jsonb(old) - 'status')
        then
            return new;
        end if;
        raise exception 'LOCKED_ASSET_IS_IMMUTABLE';
    end if;
    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
    then
        raise exception
            'ASSET_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;
    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;
    return new;
end;
$function$
;
-- ===== prevent_overlapping_verified_model_pricing =====
CREATE OR REPLACE FUNCTION public.prevent_overlapping_verified_model_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.is_verified IS NOT TRUE THEN
        RETURN NEW;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.generation_model_pricing gmp
        WHERE gmp.model_id = NEW.model_id
          AND gmp.id <> NEW.id
          AND gmp.is_verified IS TRUE
          AND NEW.effective_from
                < COALESCE(
                    gmp.effective_to,
                    'infinity'::timestamptz
                )
          AND gmp.effective_from
                < COALESCE(
                    NEW.effective_to,
                    'infinity'::timestamptz
                )
    )
    THEN
        RAISE EXCEPTION
            'OVERLAPPING_VERIFIED_MODEL_PRICING';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_active_generation_routing_policy =====
CREATE OR REPLACE FUNCTION public.protect_active_generation_routing_policy()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    -- -----------------------------------------------------
    -- DELETE ACTIVE POLICY
    -- -----------------------------------------------------
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'ACTIVE' THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    -- -----------------------------------------------------
    -- ACTIVE POLICY IS IMMUTABLE
    -- -----------------------------------------------------
    IF OLD.status = 'ACTIVE' THEN
        RAISE EXCEPTION
            'ACTIVE_ROUTING_POLICY_IMMUTABLE';
    END IF;
    -- -----------------------------------------------------
    -- ACTIVATION REQUIREMENTS
    -- -----------------------------------------------------
    IF NEW.status = 'ACTIVE' THEN
        IF NEW.approved_at IS NULL THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_REQUIRES_APPROVED_AT';
        END IF;
        IF abs(
            (
                NEW.quality_weight
                + NEW.cost_weight
                + NEW.reliability_weight
                + NEW.latency_weight
            ) - 1.0
        ) > 0.000001
        THEN
            RAISE EXCEPTION
                'ROUTING_POLICY_WEIGHTS_MUST_SUM_TO_ONE';
        END IF;
        IF NEW.max_attempts NOT BETWEEN 1 AND 2 THEN
            RAISE EXCEPTION
                'ROUTING_POLICY_MAX_ATTEMPTS_INVALID';
        END IF;
        -- Must have at least one enabled PRIMARY model.
        IF NOT EXISTS (
            SELECT 1
            FROM public.generation_policy_models gpm
            WHERE gpm.policy_id = NEW.id
              AND gpm.enabled = true
              AND gpm.route_role = 'PRIMARY'
        )
        THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_REQUIRES_PRIMARY_MODEL';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_active_policy_model_assignment =====
CREATE OR REPLACE FUNCTION public.protect_active_policy_model_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_policy_id uuid;
    v_policy_status text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_policy_id := OLD.policy_id;
    ELSE
        v_policy_id := NEW.policy_id;
    END IF;
    SELECT grp.status
    INTO v_policy_status
    FROM public.generation_routing_policies grp
    WHERE grp.id = v_policy_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_FOUND';
    END IF;
    IF v_policy_status = 'ACTIVE' THEN
        RAISE EXCEPTION
            'ACTIVE_ROUTING_POLICY_MODEL_ASSIGNMENTS_IMMUTABLE';
    END IF;
    -- Prevent moving an existing assignment away from
    -- an ACTIVE old policy.
    IF TG_OP = 'UPDATE'
       AND NEW.policy_id IS DISTINCT FROM OLD.policy_id
    THEN
        SELECT grp.status
        INTO v_policy_status
        FROM public.generation_routing_policies grp
        WHERE grp.id = OLD.policy_id;
        IF v_policy_status = 'ACTIVE' THEN
            RAISE EXCEPTION
                'ACTIVE_ROUTING_POLICY_MODEL_ASSIGNMENTS_IMMUTABLE';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_approval_request =====
CREATE OR REPLACE FUNCTION public.protect_approval_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if tg_op = 'DELETE' then
        raise exception 'APPROVAL_REQUESTS_CANNOT_BE_DELETED';
    end if;
    if old.status <> 'PENDING' then
        raise exception
            'APPROVAL_REQUEST_ALREADY_DECIDED: %',
            old.status;
    end if;
    if new.scope_type is distinct from old.scope_type
       or new.scope_id is distinct from old.scope_id
       or new.scope_version is distinct from old.scope_version
       or new.token_hash is distinct from old.token_hash
       or new.requested_by is distinct from old.requested_by
       or new.summary is distinct from old.summary
       or new.expires_at is distinct from old.expires_at
       or new.created_at is distinct from old.created_at
    then
        raise exception 'APPROVAL_REQUEST_IDENTITY_IMMUTABLE';
    end if;
    return new;
end;
$function$
;
-- ===== protect_approved_generation_benchmark =====
CREATE OR REPLACE FUNCTION public.protect_approved_generation_benchmark()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.benchmark_status = 'HUMAN_APPROVED' THEN
            RAISE EXCEPTION
                'APPROVED_BENCHMARK_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.benchmark_status = 'HUMAN_APPROVED' THEN
        RAISE EXCEPTION
            'APPROVED_BENCHMARK_IMMUTABLE';
    END IF;
    -- HUMAN_APPROVED must carry approval timestamp.
    IF NEW.benchmark_status = 'HUMAN_APPROVED'
       AND NEW.approved_at IS NULL
    THEN
        RAISE EXCEPTION
            'APPROVED_BENCHMARK_REQUIRES_APPROVED_AT';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_approved_storyboard_review =====
CREATE OR REPLACE FUNCTION public.protect_approved_storyboard_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.status = 'APPROVED' THEN
        IF
            NEW.shot_specification_id
                IS DISTINCT FROM OLD.shot_specification_id
         OR NEW.storyboard_asset_id
                IS DISTINCT FROM OLD.storyboard_asset_id
         OR NEW.status
                IS DISTINCT FROM OLD.status
         OR NEW.reviewer_type
                IS DISTINCT FROM OLD.reviewer_type
         OR NEW.score
                IS DISTINCT FROM OLD.score
         OR NEW.notes
                IS DISTINCT FROM OLD.notes
         OR NEW.reviewed_at
                IS DISTINCT FROM OLD.reviewed_at
        THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REVIEW_IS_IMMUTABLE';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_attempt_budget_bindings =====
CREATE OR REPLACE FUNCTION public.protect_attempt_budget_bindings()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.monthly_budget_id
       IS DISTINCT FROM OLD.monthly_budget_id
       OR NEW.episode_budget_id
       IS DISTINCT FROM OLD.episode_budget_id
       OR NEW.shot_budget_id
       IS DISTINCT FROM OLD.shot_budget_id
    THEN
        RAISE EXCEPTION
            'ATTEMPT_BUDGET_BINDINGS_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_attempt_routing_decision =====
CREATE OR REPLACE FUNCTION public.protect_attempt_routing_decision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.routing_decision_id IS NOT NULL
       AND NEW.routing_decision_id
            IS DISTINCT FROM OLD.routing_decision_id
    THEN
        RAISE EXCEPTION
            'ATTEMPT_ROUTING_DECISION_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_attempt_routing_identity =====
CREATE OR REPLACE FUNCTION public.protect_attempt_routing_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.shot_id
           IS DISTINCT FROM OLD.shot_id
       OR NEW.attempt_no
           IS DISTINCT FROM OLD.attempt_no
       OR NEW.idempotency_key
           IS DISTINCT FROM OLD.idempotency_key
       OR NEW.provider
           IS DISTINCT FROM OLD.provider
       OR NEW.model
           IS DISTINCT FROM OLD.model
       OR NEW.prompt_version
           IS DISTINCT FROM OLD.prompt_version
       OR NEW.model_version
           IS DISTINCT FROM OLD.model_version
       OR NEW.estimated_cost
           IS DISTINCT FROM OLD.estimated_cost
       OR NEW.routing_decision_id
           IS DISTINCT FROM OLD.routing_decision_id
       OR NEW.monthly_budget_id
           IS DISTINCT FROM OLD.monthly_budget_id
       OR NEW.episode_budget_id
           IS DISTINCT FROM OLD.episode_budget_id
       OR NEW.shot_budget_id
           IS DISTINCT FROM OLD.shot_budget_id
    THEN
        RAISE EXCEPTION
            'ATTEMPT_ROUTING_IDENTITY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_benchmark_authorization_identity =====
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
;
-- ===== protect_benchmark_evidence_job_delete =====
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
;
-- ===== protect_benchmark_job_accounting_fields =====
CREATE OR REPLACE FUNCTION public.protect_benchmark_job_accounting_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.benchmark_run_id
            is distinct from old.benchmark_run_id
       or new.benchmark_case_id
            is distinct from old.benchmark_case_id
       or new.model_id
            is distinct from old.model_id
       or new.pricing_id
            is distinct from old.pricing_id
       or new.attempt_no
            is distinct from old.attempt_no
       or new.estimated_cost
            is distinct from old.estimated_cost
    then
        raise exception
            'BENCHMARK_JOB_AUTHORIZATION_FIELDS_IMMUTABLE';
    end if;
    -- An overrun is a fact reported by the provider. It may only be
    -- written by the settlement functions, which also stop generation.
    if new.actual_cost is not null
       and new.actual_cost > old.estimated_cost
       and coalesce(
               current_setting('m417.benchmark_overrun_settlement', true),
               'off'
           ) <> 'on'
    then
        raise exception
            'BENCHMARK_ACTUAL_COST_EXCEEDS_RESERVATION';
    end if;
    return new;
end;
$function$
;
-- ===== protect_benchmark_provider_job_id =====
CREATE OR REPLACE FUNCTION public.protect_benchmark_provider_job_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.provider_job_id IS NOT NULL
       AND NEW.provider_job_id
            IS DISTINCT FROM OLD.provider_job_id
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PROVIDER_JOB_ID_IMMUTABLE';
    END IF;
    IF OLD.provider_job_id IS NULL
       AND NEW.provider_job_id IS NOT NULL
       AND OLD.status NOT IN (
            'BUDGET_RESERVED',
            'SUBMITTED'
       )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PROVIDER_JOB_ID_INVALID_STATE: %',
            OLD.status;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_benchmark_run_fields =====
CREATE OR REPLACE FUNCTION public.protect_benchmark_run_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_internal_accounting boolean;
begin
    v_internal_accounting :=
        coalesce(
            current_setting(
                'm417.benchmark_accounting',
                true
            ),
            'off'
        ) = 'on';
    -- APPROVED/RUNNING CONFIGURATION IS IMMUTABLE
    if old.status in (
        'HUMAN_APPROVED',
        'RUNNING',
        'BLOCKED',
        'COMPLETED'
    )
    then
        if new.run_code
                is distinct from old.run_code
           or new.benchmark_name
                is distinct from old.benchmark_name
           or new.hard_budget_usd
                is distinct from old.hard_budget_usd
           or new.max_generation_count
                is distinct from old.max_generation_count
           or new.human_approved
                is distinct from old.human_approved
           or new.approved_at
                is distinct from old.approved_at
        then
            raise exception
                'APPROVED_BENCHMARK_RUN_CONFIGURATION_IMMUTABLE';
        end if;
    end if;
    -- ACCOUNTING COUNTERS
    if (
        new.reserved_usd
            is distinct from old.reserved_usd
        or new.settled_usd
            is distinct from old.settled_usd
        or new.generation_count
            is distinct from old.generation_count
    )
    and v_internal_accounting is not true
    then
        raise exception
            'BENCHMARK_RUN_ACCOUNTING_FIELDS_PROTECTED';
    end if;
    -- HARD BUDGET (replaces generation_benchmark_runs_spend_check):
    -- no new money may be reserved past the cap. Settling an overrun
    -- is allowed to exceed it, because the money is already spent.
    if new.reserved_usd > old.reserved_usd
       and (new.reserved_usd + new.settled_usd) > new.hard_budget_usd
    then
        raise exception
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    end if;
    return new;
end;
$function$
;
-- ===== protect_canonical_generation_output =====
CREATE OR REPLACE FUNCTION public.protect_canonical_generation_output()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    -- Once canonical, production evidence is immutable.
    IF OLD.is_canonical = true
       OR OLD.status = 'CANONICAL'
    THEN
        IF
            NEW.attempt_id IS DISTINCT FROM OLD.attempt_id
         OR NEW.shot_id IS DISTINCT FROM OLD.shot_id
         OR NEW.storage_path IS DISTINCT FROM OLD.storage_path
         OR NEW.source_url IS DISTINCT FROM OLD.source_url
         OR NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds
         OR NEW.width IS DISTINCT FROM OLD.width
         OR NEW.height IS DISTINCT FROM OLD.height
         OR NEW.fps IS DISTINCT FROM OLD.fps
         OR NEW.file_size_bytes IS DISTINCT FROM OLD.file_size_bytes
         OR NEW.qc_status IS DISTINCT FROM OLD.qc_status
         OR NEW.qc_score IS DISTINCT FROM OLD.qc_score
         OR NEW.qc_notes IS DISTINCT FROM OLD.qc_notes
         OR NEW.qc_details IS DISTINCT FROM OLD.qc_details
         OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
         OR NEW.is_canonical IS DISTINCT FROM OLD.is_canonical
         OR NEW.canonical_at IS DISTINCT FROM OLD.canonical_at
         OR NEW.status IS DISTINCT FROM OLD.status
        THEN
            RAISE EXCEPTION
                'CANONICAL_GENERATION_OUTPUT_IS_IMMUTABLE';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_episode_creative_profile_binding =====
CREATE OR REPLACE FUNCTION public.protect_episode_creative_profile_binding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.state IN (
        'APPROVED',
        'PRODUCTION',
        'ASSEMBLY',
        'FINAL_QC',
        'READY_TO_PUBLISH',
        'PUBLISHED'
    )
    AND (
        NEW.creative_profile_id IS DISTINCT FROM
            OLD.creative_profile_id
        OR
        NEW.production_mode IS DISTINCT FROM
            OLD.production_mode
    )
    THEN
        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_BINDING_IS_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_finalized_attempt =====
CREATE OR REPLACE FUNCTION public.protect_finalized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if old.status in (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED',
        'ESCALATED'
    ) then
        if
            new.shot_id is distinct from old.shot_id
            or new.attempt_no is distinct from old.attempt_no
            or new.idempotency_key is distinct from old.idempotency_key
            or new.provider is distinct from old.provider
            or new.model is distinct from old.model
            or new.prompt_version is distinct from old.prompt_version
            or new.model_version is distinct from old.model_version
            or new.estimated_cost is distinct from old.estimated_cost
            or new.actual_cost is distinct from old.actual_cost
        then
            raise exception 'FINALIZED_ATTEMPT_IMMUTABLE';
        end if;
    end if;
    return new;
end;
$function$
;
-- ===== protect_finalized_benchmark_job =====
CREATE OR REPLACE FUNCTION public.protect_finalized_benchmark_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status IN (
            'SUCCEEDED',
            'FAILED',
            'CANCELLED'
        )
        THEN
            RAISE EXCEPTION
                'FINALIZED_BENCHMARK_JOB_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status IN (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED'
    )
    THEN
        RAISE EXCEPTION
            'FINALIZED_BENCHMARK_JOB_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_finalized_routing_decision =====
CREATE OR REPLACE FUNCTION public.protect_finalized_routing_decision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_supersession boolean;
BEGIN
    v_supersession :=
        COALESCE(
            current_setting(
                'm417.routing_supersession',
                true
            ),
            'off'
        ) = 'on';
    -- -----------------------------------------------------
    -- DELETE
    -- -----------------------------------------------------
    IF TG_OP = 'DELETE' THEN
        IF OLD.decision_status <> 'PENDING' THEN
            RAISE EXCEPTION
                'FINALIZED_ROUTING_DECISION_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    -- -----------------------------------------------------
    -- FINALIZED DECISION
    --
    -- Normally completely immutable.
    --
    -- Controlled exception:
    -- CURRENT -> HISTORICAL only.
    -- No other field may change.
    -- -----------------------------------------------------
    IF OLD.decision_status <> 'PENDING' THEN
        IF v_supersession IS TRUE
           AND OLD.is_current IS TRUE
           AND NEW.is_current IS FALSE
           AND NEW.id
                IS NOT DISTINCT FROM OLD.id
           AND NEW.shot_id
                IS NOT DISTINCT FROM OLD.shot_id
           AND NEW.shot_specification_id
                IS NOT DISTINCT FROM OLD.shot_specification_id
           AND NEW.policy_id
                IS NOT DISTINCT FROM OLD.policy_id
           AND NEW.attempt_no
                IS NOT DISTINCT FROM OLD.attempt_no
           AND NEW.decision_revision
                IS NOT DISTINCT FROM OLD.decision_revision
           AND NEW.decision_status
                IS NOT DISTINCT FROM OLD.decision_status
           AND NEW.decision_reason
                IS NOT DISTINCT FROM OLD.decision_reason
           AND NEW.selected_model_id
                IS NOT DISTINCT FROM OLD.selected_model_id
           AND NEW.selected_pricing_id
                IS NOT DISTINCT FROM OLD.selected_pricing_id
           AND NEW.route_role
                IS NOT DISTINCT FROM OLD.route_role
           AND NEW.estimated_cost
                IS NOT DISTINCT FROM OLD.estimated_cost
           AND NEW.candidate_scores
                IS NOT DISTINCT FROM OLD.candidate_scores
           AND NEW.created_at
                IS NOT DISTINCT FROM OLD.created_at
        THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION
            'FINALIZED_ROUTING_DECISION_IMMUTABLE';
    END IF;
    -- -----------------------------------------------------
    -- PENDING IDENTITY IMMUTABLE
    -- -----------------------------------------------------
    IF NEW.shot_id
            IS DISTINCT FROM OLD.shot_id
       OR NEW.shot_specification_id
            IS DISTINCT FROM OLD.shot_specification_id
       OR NEW.policy_id
            IS DISTINCT FROM OLD.policy_id
       OR NEW.attempt_no
            IS DISTINCT FROM OLD.attempt_no
       OR NEW.decision_revision
            IS DISTINCT FROM OLD.decision_revision
       OR NEW.is_current
            IS DISTINCT FROM OLD.is_current
    THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_IDENTITY_IMMUTABLE';
    END IF;
    -- -----------------------------------------------------
    -- VALID STATES
    -- -----------------------------------------------------
    IF NEW.decision_status NOT IN (
        'PENDING',
        'SELECTED',
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN
        RAISE EXCEPTION
            'INVALID_ROUTING_DECISION_STATUS: %',
            NEW.decision_status;
    END IF;
    -- -----------------------------------------------------
    -- SELECTED COMPLETENESS
    -- -----------------------------------------------------
    IF NEW.decision_status = 'SELECTED' THEN
        IF NEW.selected_model_id IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_MODEL';
        END IF;
        IF NEW.selected_pricing_id IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_PRICING';
        END IF;
        IF NEW.route_role IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_REQUIRES_ROUTE_ROLE';
        END IF;
        IF NEW.estimated_cost IS NULL
           OR NEW.estimated_cost < 0
        THEN
            RAISE EXCEPTION
                'SELECTED_ROUTING_DECISION_INVALID_COST';
        END IF;
    END IF;
    -- -----------------------------------------------------
    -- BLOCKED DECISION CANNOT CONTAIN SELECTED ROUTE
    -- -----------------------------------------------------
    IF NEW.decision_status IN (
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN
        IF NEW.selected_model_id IS NOT NULL
           OR NEW.selected_pricing_id IS NOT NULL
           OR NEW.route_role IS NOT NULL
        THEN
            RAISE EXCEPTION
                'BLOCKED_ROUTING_DECISION_CANNOT_SELECT_ROUTE';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_generation_benchmark_source_job =====
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
;
-- ===== protect_generation_model_health_history =====
CREATE OR REPLACE FUNCTION public.protect_generation_model_health_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION
            'GENERATION_MODEL_HEALTH_HISTORY_IMMUTABLE';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'GENERATION_MODEL_HEALTH_HISTORY_CANNOT_BE_DELETED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_generation_model_health_mutation =====
CREATE OR REPLACE FUNCTION public.protect_generation_model_health_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_internal boolean;
BEGIN
    v_internal :=
        COALESCE(
            current_setting(
                'm417.model_health_update',
                true
            ),
            'off'
        ) = 'on';
    IF v_internal IS NOT TRUE THEN
        RAISE EXCEPTION
            'DIRECT_MODEL_HEALTH_MUTATION_FORBIDDEN';
    END IF;
    RETURN CASE
        WHEN TG_OP = 'DELETE' THEN OLD
        ELSE NEW
    END;
END;
$function$
;
-- ===== protect_locked_creative_profile =====
CREATE OR REPLACE FUNCTION public.protect_locked_creative_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'LOCKED' THEN
            RAISE EXCEPTION
                'LOCKED_CREATIVE_PROFILE_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_CREATIVE_PROFILE_IS_IMMUTABLE';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN
        NEW.locked_at := now();
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_locked_manifest_content =====
CREATE OR REPLACE FUNCTION public.protect_locked_manifest_content()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_manifest_id uuid;
    v_status text;
BEGIN
    v_manifest_id :=
        CASE
            WHEN TG_OP = 'DELETE'
                THEN OLD.manifest_id
            ELSE NEW.manifest_id
        END;
    SELECT pm.status
    INTO v_status
    FROM public.production_manifests pm
    WHERE pm.id = v_manifest_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCTION_MANIFEST_NOT_FOUND';
    END IF;
    IF v_status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_CONTENT_IS_IMMUTABLE';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_locked_shot =====
CREATE OR REPLACE FUNCTION public.protect_locked_shot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if old.state = 'LOCKED' then
        if
            new.episode_id is distinct from old.episode_id
            or new.shot_code is distinct from old.shot_code
            or new.shot_order is distinct from old.shot_order
            or new.prompt_version is distinct from old.prompt_version
            or new.asset_version is distinct from old.asset_version
            or new.model_version is distinct from old.model_version
            or new.maximum_budget is distinct from old.maximum_budget
            or new.currency is distinct from old.currency
            or new.locked_at is distinct from old.locked_at
        then
            raise exception 'LOCKED_SHOT_PRODUCTION_FIELDS_IMMUTABLE';
        end if;
    end if;
    return new;
end;
$function$
;
-- ===== protect_production_manifest =====
CREATE OR REPLACE FUNCTION public.protect_production_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF OLD.status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_IS_IMMUTABLE';
    END IF;
    IF NEW.status = 'LOCKED'
       AND OLD.status <> 'HUMAN_APPROVED'
    THEN
        RAISE EXCEPTION
            'MANIFEST_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.human_approved IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_HUMAN_APPROVAL_REQUIRED';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN
        NEW.locked_at := now();
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== protect_referenced_generation_pricing =====
CREATE OR REPLACE FUNCTION public.protect_referenced_generation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_pricing_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_pricing_id := OLD.id;
    ELSE
        v_pricing_id := OLD.id;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.generation_routing_decisions grd
        WHERE grd.selected_pricing_id = v_pricing_id
          AND grd.decision_status <> 'PENDING'
    )
    THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION
                'ROUTING_REFERENCED_PRICING_CANNOT_BE_DELETED';
        ELSE
            -- effective_to may still close the historical
            -- window, but all other fields must stay fixed.
            IF (
                to_jsonb(NEW)
                - 'effective_to'
                - 'updated_at'
            )
            IS DISTINCT FROM
            (
                to_jsonb(OLD)
                - 'effective_to'
                - 'updated_at'
            )
            THEN
                RAISE EXCEPTION
                    'ROUTING_REFERENCED_PRICING_IMMUTABLE';
            END IF;
        END IF;
    END IF;
    RETURN CASE
        WHEN TG_OP = 'DELETE'
            THEN OLD
        ELSE NEW
    END;
END;
$function$
;
-- ===== protect_shot_specification =====
CREATE OR REPLACE FUNCTION public.protect_shot_specification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_supersession boolean;
begin
    v_supersession :=
        coalesce(
            current_setting('m417.spec_supersession', true),
            'off'
        ) = 'on';
    if old.status = 'LOCKED' then
        if v_supersession then
            -- Retire the old active specification.
            if new.status = 'SUPERSEDED'
               and old.is_active = true
               and new.is_active = false
               and (to_jsonb(new) - 'status' - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'status' - 'is_active' - 'updated_at')
            then
                return new;
            end if;
            -- Activate the new locked specification.
            if new.status = 'LOCKED'
               and old.is_active = false
               and new.is_active = true
               and (to_jsonb(new) - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'is_active' - 'updated_at')
            then
                return new;
            end if;
        end if;
        raise exception
            'LOCKED_SHOT_SPECIFICATION_IS_IMMUTABLE';
    end if;
    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
    then
        raise exception
            'SHOT_SPEC_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;
    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;
    return new;
end;
$function$
;
-- ===== protect_verified_generation_model_pricing =====
CREATE OR REPLACE FUNCTION public.protect_verified_generation_model_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_old_business_state jsonb;
    v_new_business_state jsonb;
BEGIN
    -- -----------------------------------------------------
    -- DELETE
    -- -----------------------------------------------------
    IF TG_OP = 'DELETE' THEN
        IF OLD.is_verified IS TRUE THEN
            RAISE EXCEPTION
                'VERIFIED_GENERATION_PRICING_CANNOT_BE_DELETED';
        END IF;
        RETURN OLD;
    END IF;
    -- -----------------------------------------------------
    -- A VERIFIED ROW MAY NEVER BECOME UNVERIFIED
    -- -----------------------------------------------------
    IF OLD.is_verified IS TRUE
       AND NEW.is_verified IS DISTINCT FROM TRUE
    THEN
        RAISE EXCEPTION
            'VERIFIED_GENERATION_PRICING_CANNOT_BE_UNVERIFIED';
    END IF;
    -- -----------------------------------------------------
    -- PROTECT VERIFIED BUSINESS STATE
    --
    -- Only effective_to + updated_at may differ.
    -- -----------------------------------------------------
    IF OLD.is_verified IS TRUE THEN
        v_old_business_state :=
            to_jsonb(OLD)
            - 'effective_to'
            - 'updated_at';
        v_new_business_state :=
            to_jsonb(NEW)
            - 'effective_to'
            - 'updated_at';
        IF v_new_business_state
            IS DISTINCT FROM
            v_old_business_state
        THEN
            RAISE EXCEPTION
                'VERIFIED_GENERATION_PRICING_IMMUTABLE_CREATE_NEW_VERSION';
        END IF;
        -- -------------------------------------------------
        -- effective_to can only be assigned once.
        -- -------------------------------------------------
        IF OLD.effective_to IS NOT NULL
           AND NEW.effective_to
                IS DISTINCT FROM OLD.effective_to
        THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_EFFECTIVE_TO_IMMUTABLE';
        END IF;
        -- -------------------------------------------------
        -- Cannot reopen an expired/closed price.
        -- -------------------------------------------------
        IF OLD.effective_to IS NOT NULL
           AND NEW.effective_to IS NULL
        THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_CANNOT_BE_REOPENED';
        END IF;
        -- -------------------------------------------------
        -- Closing timestamp must be after effective_from.
        -- -------------------------------------------------
        IF NEW.effective_to IS NOT NULL
           AND NEW.effective_to <= OLD.effective_from
        THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_INVALID_EFFECTIVE_TO';
        END IF;
    END IF;
    -- -----------------------------------------------------
    -- NEWLY VERIFIED ROW REQUIREMENTS
    -- -----------------------------------------------------
    IF OLD.is_verified IS DISTINCT FROM TRUE
       AND NEW.is_verified IS TRUE
    THEN
        IF NEW.verified_at IS NULL THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_REQUIRES_VERIFIED_AT';
        END IF;
        IF NEW.effective_from IS NULL THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_REQUIRES_EFFECTIVE_FROM';
        END IF;
        IF NEW.effective_to IS NOT NULL
           AND NEW.effective_to <= NEW.effective_from
        THEN
            RAISE EXCEPTION
                'VERIFIED_PRICING_INVALID_EFFECTIVE_WINDOW';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== record_generation_model_health =====
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
;
-- ===== release_benchmark_job =====
CREATE OR REPLACE FUNCTION public.release_benchmark_job(p_job_id uuid, p_final_status text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_run_id uuid;
    v_status text;
    v_estimated_cost numeric;
BEGIN
    IF p_final_status NOT IN (
        'FAILED',
        'CANCELLED'
    )
    THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_RELEASE_STATUS';
    END IF;
    SELECT
        gbj.benchmark_run_id,
        gbj.status,
        gbj.estimated_cost
    INTO
        v_run_id,
        v_status,
        v_estimated_cost
    FROM public.generation_benchmark_jobs gbj
    WHERE gbj.id = p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_FOUND';
    END IF;
    IF v_status NOT IN (
        'BUDGET_RESERVED',
        'SUBMITTED',
        'GENERATING'
    )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_RELEASABLE: %',
            v_status;
    END IF;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );
    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd
            - v_estimated_cost,
        updated_at = now()
    WHERE id = v_run_id
      AND reserved_usd >=
            v_estimated_cost;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_RESERVATION_ACCOUNTING_ERROR';
    END IF;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );
    UPDATE public.generation_benchmark_jobs
    SET
        actual_cost = 0,
        status = p_final_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = now()
    WHERE id = p_job_id;
END;
$function$
;
-- ===== release_generation_attempt_v2 =====
CREATE OR REPLACE FUNCTION public.release_generation_attempt_v2(p_attempt_id uuid, p_failure_status text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, released_amount numeric, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_episode_id uuid;
    v_estimated_cost numeric;
    v_status text;
    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;
BEGIN
    IF p_attempt_id IS NULL THEN
        RAISE EXCEPTION 'ATTEMPT_ID_REQUIRED';
    END IF;
    IF p_failure_status NOT IN ('FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION 'INVALID_FAILURE_STATUS';
    END IF;
    SELECT
        a.shot_id,
        a.estimated_cost,
        a.status,
        a.monthly_budget_id,
        a.episode_budget_id,
        a.shot_budget_id
    INTO
        v_shot_id,
        v_estimated_cost,
        v_status,
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    FROM public.attempts a
    WHERE a.id = p_attempt_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTEMPT_NOT_FOUND';
    END IF;
    IF v_status NOT IN (
        'BUDGET_RESERVED',
        'SUBMITTED',
        'GENERATING'
    ) THEN
        RAISE EXCEPTION
            'ATTEMPT_NOT_RELEASABLE: %',
            v_status;
    END IF;
    IF v_monthly_budget_id IS NULL
       OR v_episode_budget_id IS NULL
       OR v_shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION 'ATTEMPT_BUDGET_BINDINGS_MISSING';
    END IF;
    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = v_shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;
    PERFORM 1
    FROM public.budgets b
    WHERE b.id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    ORDER BY b.id
    FOR UPDATE;
    IF (
        SELECT COUNT(*)
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
    ) <> 3 THEN
        RAISE EXCEPTION 'BOUND_BUDGET_NOT_FOUND';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
          AND b.reserved_amount < v_estimated_cost
    ) THEN
        RAISE EXCEPTION 'BOUND_RESERVED_BALANCE_INVALID';
    END IF;
    UPDATE public.budgets
    SET reserved_amount =
        reserved_amount - v_estimated_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );
    UPDATE public.attempts
    SET
        actual_cost = 0,
        status = p_failure_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        finished_at = now()
    WHERE id = p_attempt_id;
    INSERT INTO public.cost_ledger (
        attempt_id,
        episode_id,
        shot_id,
        entry_type,
        amount,
        currency,
        description
    )
    VALUES (
        p_attempt_id,
        v_episode_id,
        v_shot_id,
        'RELEASE',
        v_estimated_cost,
        'USD',
        'Bound generation reservation released without provider charge'
    );
    RETURN QUERY
    SELECT
        p_attempt_id,
        v_estimated_cost,
        'RELEASED'::text;
END;
$function$
;
-- ===== request_human_approval =====
CREATE OR REPLACE FUNCTION public.request_human_approval(p_scope_type text, p_scope_id uuid, p_requested_by text, p_summary jsonb DEFAULT '{}'::jsonb, p_ttl_hours integer DEFAULT 72)
 RETURNS TABLE(request_id uuid, token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_token text;
    v_request_id uuid;
    v_expires_at timestamptz;
    v_scope_version integer;
    v_state text;
begin
    if p_scope_type not in (
        'EPISODE_PRODUCTION',
        'EPISODE_PUBLISH',
        'SHOT_ESCALATION'
    ) then
        raise exception 'INVALID_APPROVAL_SCOPE';
    end if;
    if p_scope_id is null then
        raise exception 'APPROVAL_SCOPE_ID_REQUIRED';
    end if;
    if p_requested_by is null or btrim(p_requested_by) = '' then
        raise exception 'APPROVAL_REQUESTER_REQUIRED';
    end if;
    if p_ttl_hours is null
       or p_ttl_hours < 1
       or p_ttl_hours > 720
    then
        raise exception 'INVALID_APPROVAL_TTL';
    end if;
    if p_scope_type in ('EPISODE_PRODUCTION', 'EPISODE_PUBLISH') then
        select e.production_version, e.state
        into v_scope_version, v_state
        from public.episodes e
        where e.id = p_scope_id;
        if not found then
            raise exception 'EPISODE_NOT_FOUND';
        end if;
        if p_scope_type = 'EPISODE_PRODUCTION'
           and v_state <> 'PREPRODUCTION'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PRODUCTION_APPROVAL: %',
                v_state;
        end if;
        if p_scope_type = 'EPISODE_PUBLISH'
           and v_state <> 'READY_TO_PUBLISH'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PUBLISH_APPROVAL: %',
                v_state;
        end if;
    else
        select s.state
        into v_state
        from public.shots s
        where s.id = p_scope_id;
        if not found then
            raise exception 'SHOT_NOT_FOUND';
        end if;
        if v_state <> 'ESCALATED' then
            raise exception
                'SHOT_NOT_ESCALATED: %',
                v_state;
        end if;
    end if;
    -- A new request replaces a pending one for the same subject.
    update public.approval_requests ar
    set status = 'SUPERSEDED'
    where ar.scope_type = p_scope_type
      and ar.scope_id = p_scope_id
      and ar.status = 'PENDING';
    v_token :=
        replace(gen_random_uuid()::text, '-', '')
        || replace(gen_random_uuid()::text, '-', '');
    v_expires_at :=
        now() + make_interval(hours => p_ttl_hours);
    insert into public.approval_requests (
        scope_type,
        scope_id,
        scope_version,
        token_hash,
        requested_by,
        summary,
        expires_at
    )
    values (
        p_scope_type,
        p_scope_id,
        v_scope_version,
        encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
        p_requested_by,
        coalesce(p_summary, '{}'::jsonb),
        v_expires_at
    )
    returning id
    into v_request_id;
    return query
    select v_request_id, v_token, v_expires_at;
end;
$function$
;
-- ===== require_attempt_acquisition_path =====
CREATE OR REPLACE FUNCTION public.require_attempt_acquisition_path()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if coalesce(
           current_setting('m417.attempt_acquisition', true),
           'off'
       ) <> 'on'
    then
        raise exception 'ATTEMPT_INSERT_REQUIRES_ACQUIRE_FUNCTION';
    end if;
    if new.status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_INSERT_REQUIRES_BUDGET_RESERVED: %',
            new.status;
    end if;
    if new.submission_claimed_at is not null
       or new.provider_job_id is not null
       or new.actual_cost is not null
    then
        raise exception 'ATTEMPT_INSERT_MUST_BE_UNSUBMITTED';
    end if;
    return new;
end;
$function$
;
-- ===== require_attempt_budget_bindings =====
CREATE OR REPLACE FUNCTION public.require_attempt_budget_bindings()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;
    v_monthly_type text;
    v_monthly_reference uuid;
    v_monthly_currency text;
    v_episode_type text;
    v_episode_reference uuid;
    v_episode_currency text;
    v_shot_type text;
    v_shot_reference uuid;
    v_shot_currency text;
BEGIN
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    IF NEW.monthly_budget_id IS NULL
       OR NEW.episode_budget_id IS NULL
       OR NEW.shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION
            'ATTEMPT_BUDGET_BINDINGS_REQUIRED';
    END IF;
    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = NEW.shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;
    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_monthly_type,
        v_monthly_reference,
        v_monthly_currency
    FROM public.budgets b
    WHERE b.id = NEW.monthly_budget_id
      AND b.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_MONTHLY_BUDGET_NOT_ACTIVE';
    END IF;
    IF v_monthly_type <> 'MONTHLY'
       OR v_monthly_reference IS NOT NULL
       OR v_monthly_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_MONTHLY_BUDGET';
    END IF;
    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_episode_type,
        v_episode_reference,
        v_episode_currency
    FROM public.budgets b
    WHERE b.id = NEW.episode_budget_id
      AND b.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_EPISODE_BUDGET_NOT_ACTIVE';
    END IF;
    IF v_episode_type <> 'EPISODE'
       OR v_episode_reference <> v_episode_id
       OR v_episode_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_EPISODE_BUDGET';
    END IF;
    SELECT
        b.budget_type,
        b.reference_id,
        b.currency
    INTO
        v_shot_type,
        v_shot_reference,
        v_shot_currency
    FROM public.budgets b
    WHERE b.id = NEW.shot_budget_id
      AND b.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BOUND_SHOT_BUDGET_NOT_ACTIVE';
    END IF;
    IF v_shot_type <> 'SHOT'
       OR v_shot_reference <> NEW.shot_id
       OR v_shot_currency <> 'USD'
    THEN
        RAISE EXCEPTION
            'INVALID_BOUND_SHOT_BUDGET';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_attempt_insert_authorization =====
CREATE OR REPLACE FUNCTION public.require_attempt_insert_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_authorized boolean;
    v_episode_state text;
BEGIN
    -- Only paid/reserved production attempts require this gate.
    IF NEW.status = 'BUDGET_RESERVED' THEN
        SELECT
            e.production_authorized,
            e.state
        INTO
            v_authorized,
            v_episode_state
        FROM public.shots s
        JOIN public.episodes e
            ON e.id = s.episode_id
        WHERE s.id = NEW.shot_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SHOT_OR_EPISODE_NOT_FOUND';
        END IF;
        IF COALESCE(v_authorized, false) IS NOT TRUE THEN
            RAISE EXCEPTION 'PRODUCTION_NOT_AUTHORIZED';
        END IF;
        IF v_episode_state <> 'PRODUCTION' THEN
            RAISE EXCEPTION
                'EPISODE_NOT_IN_PRODUCTION: %',
                v_episode_state;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_benchmark_generation_enabled =====
CREATE OR REPLACE FUNCTION public.require_benchmark_generation_enabled()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_generation_enabled boolean;
    v_enters_paid_path boolean := false;
BEGIN
    -- -----------------------------------------------------
    -- Only guard entry into BUDGET_RESERVED.
    -- -----------------------------------------------------
    IF TG_OP = 'INSERT' THEN
        v_enters_paid_path :=
            NEW.status = 'BUDGET_RESERVED';
    ELSIF TG_OP = 'UPDATE' THEN
        v_enters_paid_path :=
            OLD.status IS DISTINCT FROM 'BUDGET_RESERVED'
            AND NEW.status = 'BUDGET_RESERVED';
    END IF;
    IF v_enters_paid_path IS NOT TRUE THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- GLOBAL M417 KILL SWITCH
    -- -----------------------------------------------------
    SELECT sf.value
    INTO v_generation_enabled
    FROM public.system_flags sf
    WHERE sf.key = 'generation_enabled'
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
    END IF;
    IF v_generation_enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'GENERATION_DISABLED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_benchmark_job_authorization =====
CREATE OR REPLACE FUNCTION public.require_benchmark_job_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_authorization_status text;
BEGIN
    IF TG_OP <> 'UPDATE' THEN
        RETURN NEW;
    END IF;
    IF OLD.status = 'CREATED'
       AND NEW.status = 'BUDGET_RESERVED'
    THEN
        SELECT authorization_status
        INTO v_authorization_status
        FROM public.generation_benchmark_job_authorizations
        WHERE benchmark_job_id = NEW.id;
        IF NOT FOUND
           OR v_authorization_status <> 'AUTHORIZED'
        THEN
            RAISE EXCEPTION
                'BENCHMARK_JOB_NOT_AUTHORIZED_FOR_PAID_EXECUTION';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_complete_approved_benchmark =====
CREATE OR REPLACE FUNCTION public.require_complete_approved_benchmark()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.benchmark_status = 'HUMAN_APPROVED'
       and (
            tg_op = 'INSERT'
            or old.benchmark_status is distinct from 'HUMAN_APPROVED'
       )
       and (
            new.continuity_score is null
            or new.motion_score is null
            or new.face_score is null
            or new.anatomy_score is null
            or new.prompt_adherence_score is null
            or new.camera_score is null
            or new.expression_score is null
            or new.lip_sync_score is null
            or new.pass_rate is null
            or new.average_generation_seconds is null
       )
    then
        raise exception
            'HUMAN_APPROVED_BENCHMARK_REQUIRES_COMPLETE_SCORES';
    end if;
    return new;
end;
$function$
;
-- ===== require_fresh_model_health_for_attempt =====
CREATE OR REPLACE FUNCTION public.require_fresh_model_health_for_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_selected_model_id uuid;
    v_decision_status text;
    v_health_status text;
    v_last_checked_at timestamptz;
    v_max_age_minutes numeric;
begin
    -- Only paid/reserved attempts require fresh health.
    if new.status <> 'BUDGET_RESERVED' then
        return new;
    end if;
    if new.routing_decision_id is null then
        raise exception 'ROUTING_DECISION_REQUIRED';
    end if;
    select
        grd.decision_status,
        grd.selected_model_id
    into
        v_decision_status,
        v_selected_model_id
    from public.generation_routing_decisions grd
    where grd.id = new.routing_decision_id
    for share;
    if not found then
        raise exception 'ROUTING_DECISION_NOT_FOUND';
    end if;
    if v_decision_status <> 'SELECTED' then
        raise exception
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_decision_status;
    end if;
    if v_selected_model_id is null then
        raise exception 'ROUTING_SELECTED_MODEL_REQUIRED';
    end if;
    -- Fail closed:
    --   AVAILABLE + recent -> allowed
    --   anything else      -> blocked
    select
        gmh.availability_status,
        gmh.last_checked_at
    into
        v_health_status,
        v_last_checked_at
    from public.generation_model_health gmh
    where gmh.model_id = v_selected_model_id
    for share;
    if not found then
        raise exception
            'ROUTING_MODEL_HEALTH_MISSING';
    end if;
    if v_health_status is distinct from 'AVAILABLE' then
        raise exception
            'ROUTING_MODEL_NOT_CURRENTLY_AVAILABLE: %',
            coalesce(v_health_status, 'NULL');
    end if;
    if v_last_checked_at is null then
        raise exception
            'ROUTING_MODEL_HEALTH_NOT_VERIFIED';
    end if;
    select st.value_numeric
    into v_max_age_minutes
    from public.system_settings st
    where st.key = 'model_health_max_age_minutes';
    if not found
       or v_max_age_minutes is null
       or v_max_age_minutes <= 0
    then
        raise exception 'MODEL_HEALTH_MAX_AGE_SETTING_MISSING';
    end if;
    if v_last_checked_at
       < now() - (v_max_age_minutes * interval '1 minute')
    then
        raise exception
            'ROUTING_MODEL_HEALTH_STALE: last checked % minutes ago, limit %',
            floor(extract(epoch from (now() - v_last_checked_at)) / 60),
            v_max_age_minutes;
    end if;
    return new;
end;
$function$
;
-- ===== require_mandatory_storyboard_for_attempt =====
CREATE OR REPLACE FUNCTION public.require_mandatory_storyboard_for_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_spec_id uuid;
    v_review_count integer;
    v_approved_count integer;
BEGIN
    -- -----------------------------------------------------
    -- Only paid/reserved generation.
    -- -----------------------------------------------------
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Resolve exact canonical spec through routing decision.
    -- -----------------------------------------------------
    IF NEW.routing_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_REQUIRED';
    END IF;
    SELECT grd.shot_specification_id
    INTO v_spec_id
    FROM public.generation_routing_decisions grd
    WHERE grd.id = NEW.routing_decision_id
      AND grd.shot_id = NEW.shot_id
      AND grd.attempt_no = NEW.attempt_no
      AND grd.decision_status = 'SELECTED'
      AND grd.is_current = true
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'CURRENT_SELECTED_ROUTING_DECISION_REQUIRED';
    END IF;
    -- -----------------------------------------------------
    -- Exact storyboard review.
    --
    -- UNIQUE(spec) already exists, but explicit counts make
    -- the execution gate fail closed.
    -- -----------------------------------------------------
    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE sr.status = 'APPROVED'
              AND sr.storyboard_asset_id IS NOT NULL
              AND sr.reviewed_at IS NOT NULL
              AND sr.reviewer_type IS NOT NULL
              AND btrim(sr.reviewer_type) <> ''
        )
    INTO
        v_review_count,
        v_approved_count
    FROM public.storyboard_reviews sr
    WHERE sr.shot_specification_id = v_spec_id;
    IF v_review_count <> 1 THEN
        RAISE EXCEPTION
            'EXACTLY_ONE_STORYBOARD_REVIEW_REQUIRED';
    END IF;
    IF v_approved_count <> 1 THEN
        RAISE EXCEPTION
            'STORYBOARD_APPROVAL_REQUIRED';
    END IF;
    -- -----------------------------------------------------
    -- Storyboard asset must STILL be LOCKED at acquisition.
    -- -----------------------------------------------------
    IF NOT EXISTS (
        SELECT 1
        FROM public.storyboard_reviews sr
        JOIN public.asset_registry ar
          ON ar.id = sr.storyboard_asset_id
         AND ar.status = 'LOCKED'
         AND ar.locked_at IS NOT NULL
        WHERE sr.shot_specification_id = v_spec_id
          AND sr.status = 'APPROVED'
          AND sr.reviewed_at IS NOT NULL
          AND sr.reviewer_type IS NOT NULL
          AND btrim(sr.reviewer_type) <> ''
    )
    THEN
        RAISE EXCEPTION
            'CANONICAL_STORYBOARD_ASSET_NOT_LOCKED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_manifest_authorized_attempt =====
CREATE OR REPLACE FUNCTION public.require_manifest_authorized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;
    v_episode_authorized boolean;
    v_episode_state text;
    v_episode_production_version integer;
    v_manifest_count integer;
BEGIN
    -- -----------------------------------------------------
    -- Only paid/reserved attempts require production gate.
    -- -----------------------------------------------------
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Load canonical shot -> episode state.
    -- -----------------------------------------------------
    SELECT
        s.episode_id,
        e.production_authorized,
        e.state,
        e.production_version
    INTO
        v_episode_id,
        v_episode_authorized,
        v_episode_state,
        v_episode_production_version
    FROM public.shots s
    JOIN public.episodes e
        ON e.id = s.episode_id
    WHERE s.id = NEW.shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_SHOT_OR_EPISODE_NOT_FOUND';
    END IF;
    -- -----------------------------------------------------
    -- Episode production authorization.
    -- Defense in depth with DATA-81.
    -- -----------------------------------------------------
    IF COALESCE(v_episode_authorized, false) IS NOT TRUE THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_PRODUCTION_NOT_AUTHORIZED';
    END IF;
    IF v_episode_state <> 'PRODUCTION' THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_EPISODE_NOT_IN_PRODUCTION: %',
            v_episode_state;
    END IF;
    -- -----------------------------------------------------
    -- Find EXACTLY ONE canonical production path:
    --
    -- Episode
    --   -> LOCKED Manifest
    --      -> Manifest Shot
    --         -> LOCKED ACTIVE Specification
    --
    -- Specification version must equal prompt_version
    -- being used by this attempt.
    -- -----------------------------------------------------
    SELECT COUNT(*)
    INTO v_manifest_count
    FROM public.production_manifests pm
    JOIN public.production_manifest_shots pms
        ON pms.manifest_id = pm.id
    JOIN public.shot_specifications ss
        ON ss.id = pms.shot_specification_id
    WHERE pm.episode_id = v_episode_id
      AND pm.production_version =
          v_episode_production_version
      AND pm.status = 'LOCKED'
      AND pm.human_approved = true
      AND pm.locked_at IS NOT NULL
      AND pms.shot_id = NEW.shot_id
      AND ss.shot_id = NEW.shot_id
      AND ss.status = 'LOCKED'
      AND ss.locked_at IS NOT NULL
      AND ss.is_active = true
      AND ss.version = NEW.prompt_version;
    IF v_manifest_count = 0 THEN
        RAISE EXCEPTION
            'SHOT_NOT_AUTHORIZED_BY_LOCKED_MANIFEST';
    END IF;
    IF v_manifest_count > 1 THEN
        RAISE EXCEPTION
            'AMBIGUOUS_LOCKED_MANIFEST_FOR_SHOT';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_paid_generation_readiness =====
CREATE OR REPLACE FUNCTION public.require_paid_generation_readiness()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_spec_id uuid;
    v_series_id uuid;
    v_shot_state text;
    v_audio_required boolean;
    v_voice_required boolean;
    v_required_asset_codes jsonb;
    v_storyboard_count integer;
    v_storyboard_approved_count integer;
    v_required_asset_count integer;
    v_resolved_required_asset_count integer;
    v_bound_required_asset_count integer;
    v_canonical_audio_count integer;
    v_unbound_asset_code text;
    v_multi_bound_asset_code text;
    v_uncovered_audio_order integer;
BEGIN
    -- -----------------------------------------------------
    -- Only paid/reserved attempts require readiness gate.
    -- -----------------------------------------------------
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Resolve the EXACT locked production specification
    -- already authorized by manifest architecture.
    -- -----------------------------------------------------
    SELECT
        ss.id,
        e.series_id,
        s.state,
        ss.audio_required,
        ss.voice_required,
        ss.required_asset_codes
    INTO
        v_spec_id,
        v_series_id,
        v_shot_state,
        v_audio_required,
        v_voice_required,
        v_required_asset_codes
    FROM public.shots s
    JOIN public.episodes e
        ON e.id = s.episode_id
    JOIN public.production_manifests pm
        ON pm.episode_id = e.id
       AND pm.production_version = e.production_version
       AND pm.status = 'LOCKED'
       AND pm.human_approved = true
       AND pm.locked_at IS NOT NULL
    JOIN public.production_manifest_shots pms
        ON pms.manifest_id = pm.id
       AND pms.shot_id = s.id
    JOIN public.shot_specifications ss
        ON ss.id = pms.shot_specification_id
       AND ss.shot_id = s.id
       AND ss.status = 'LOCKED'
       AND ss.locked_at IS NOT NULL
       AND ss.is_active = true
       AND ss.version = NEW.prompt_version
    WHERE s.id = NEW.shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'READINESS_LOCKED_PRODUCTION_SPEC_NOT_FOUND';
    END IF;
    -- -----------------------------------------------------
    -- Shot lifecycle readiness.
    --
    -- Initial generation:
    -- STORYBOARD_APPROVED / AUDIO_READY
    --
    -- Retry:
    -- RETRY_REQUIRED is converted to QUEUED by the
    -- acquisition workflow after authorization.
    --
    -- QUEUED is also accepted because acquire_generation_attempt
    -- may be operating inside the same orchestration path.
    -- -----------------------------------------------------
    IF v_shot_state NOT IN (
        'STORYBOARD_APPROVED',
        'AUDIO_READY',
        'RETRY_REQUIRED',
        'QUEUED'
    )
    THEN
        RAISE EXCEPTION
            'SHOT_NOT_GENERATION_READY: %',
            v_shot_state;
    END IF;
    -- -----------------------------------------------------
    -- STORYBOARD
    --
    -- Storyboard review is optional at schema level.
    -- But if a review record exists, it cannot be pending
    -- or rejected when paid generation begins.
    -- -----------------------------------------------------
    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE sr.status = 'APPROVED'
              AND sr.reviewed_at IS NOT NULL
        )
    INTO
        v_storyboard_count,
        v_storyboard_approved_count
    FROM public.storyboard_reviews sr
    WHERE sr.shot_specification_id = v_spec_id;
    IF v_storyboard_count > 0
       AND v_storyboard_approved_count <> v_storyboard_count
    THEN
        RAISE EXCEPTION
            'STORYBOARD_REVIEW_NOT_APPROVED';
    END IF;
    -- -----------------------------------------------------
    -- REQUIRED ASSET CODES
    --
    -- required_asset_codes must:
    --
    -- 1. contain strings only
    -- 2. contain no blank codes
    -- 3. resolve to LOCKED asset_registry rows
    -- 4. belong to the episode series
    -- 5. be explicitly bound to this shot specification
    --
    -- DISTINCT prevents duplicate JSON codes from creating
    -- false counts.
    -- -----------------------------------------------------
    IF jsonb_typeof(
        COALESCE(v_required_asset_codes, '[]'::jsonb)
    ) <> 'array'
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODES_MUST_BE_ARRAY';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_required_asset_codes, '[]'::jsonb)
        ) AS elem(value)
        WHERE jsonb_typeof(elem.value) <> 'string'
    )
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODES_MUST_CONTAIN_STRINGS_ONLY';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(
            COALESCE(v_required_asset_codes, '[]'::jsonb)
        ) AS req(asset_code)
        WHERE btrim(req.asset_code) = ''
    )
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODE_CANNOT_BE_BLANK';
    END IF;
    SELECT COUNT(DISTINCT req.asset_code)
    INTO v_required_asset_count
    FROM jsonb_array_elements_text(
        COALESCE(v_required_asset_codes, '[]'::jsonb)
    ) AS req(asset_code);
    IF v_required_asset_count > 0 THEN
        -- ---------------------------------------------
        -- Each required code must resolve to EXACTLY ONE
        -- LOCKED asset of this series THROUGH THIS
        -- SPECIFICATION'S OWN BINDINGS.
        --
        -- Several versions of a code may be LOCKED at the
        -- same time; each specification stays pinned to
        -- the version it was approved with.
        -- ---------------------------------------------
        SELECT
            min(x.asset_code) FILTER (WHERE x.bound_count = 0),
            min(x.asset_code) FILTER (WHERE x.bound_count > 1)
        INTO
            v_unbound_asset_code,
            v_multi_bound_asset_code
        FROM (
            SELECT
                required.asset_code,
                COUNT(DISTINCT bound.asset_id) AS bound_count
            FROM (
                SELECT DISTINCT req.asset_code
                FROM jsonb_array_elements_text(
                    COALESCE(
                        v_required_asset_codes,
                        '[]'::jsonb
                    )
                ) AS req(asset_code)
            ) required
            LEFT JOIN (
                SELECT
                    ar.id AS asset_id,
                    ar.asset_code
                FROM public.shot_reference_assets sra
                JOIN public.asset_registry ar
                    ON ar.id = sra.asset_id
                WHERE sra.shot_specification_id = v_spec_id
                  AND sra.is_required = true
                  AND ar.series_id = v_series_id
                  AND ar.status = 'LOCKED'
                  AND ar.locked_at IS NOT NULL
            ) bound
                ON bound.asset_code = required.asset_code
            GROUP BY required.asset_code
        ) x;
        IF v_unbound_asset_code IS NOT NULL THEN
            RAISE EXCEPTION
                'REQUIRED_ASSET_NOT_BOUND_TO_SHOT: %',
                v_unbound_asset_code;
        END IF;
        IF v_multi_bound_asset_code IS NOT NULL THEN
            RAISE EXCEPTION
                'REQUIRED_ASSET_BOUND_TO_MULTIPLE_VERSIONS: %',
                v_multi_bound_asset_code;
        END IF;
    END IF;
    -- -----------------------------------------------------
    -- AUDIO / VOICE READINESS
    -- -----------------------------------------------------
    IF COALESCE(v_audio_required, false) = true
       OR COALESCE(v_voice_required, false) = true
    THEN
        SELECT COUNT(*)
        INTO v_canonical_audio_count
        FROM public.shot_audio_productions sap
        JOIN public.voice_identities vi
            ON vi.id = sap.voice_identity_id
           AND vi.character_id = sap.character_id
           AND vi.status = 'LOCKED'
           AND vi.locked_at IS NOT NULL
        WHERE sap.shot_specification_id = v_spec_id
          AND sap.is_canonical = true
          AND sap.status = 'APPROVED'
          AND sap.qc_status = 'PASS'
          AND sap.reviewed_at IS NOT NULL
          AND sap.duration_seconds IS NOT NULL
          AND sap.duration_seconds > 0
          AND sap.storage_path IS NOT NULL
          AND btrim(sap.storage_path) <> ''
          AND (
                COALESCE(v_voice_required, false) = false
                OR
                (
                    -- READY = timing prepared before the video
                    -- exists. PASS = verified against a video.
                    sap.lip_sync_required = true
                    AND sap.lip_sync_status IN (
                        'READY',
                        'PASS'
                    )
                )
                OR
                (
                    sap.lip_sync_required = false
                    AND sap.lip_sync_status IN (
                        'NOT_REQUIRED',
                        'PASS'
                    )
                )
          );
        IF v_canonical_audio_count = 0 THEN
            IF COALESCE(v_voice_required, false) = true THEN
                RAISE EXCEPTION
                    'VOICE_REQUIRED_BUT_CANONICAL_AUDIO_NOT_READY';
            ELSE
                RAISE EXCEPTION
                    'AUDIO_REQUIRED_BUT_CANONICAL_AUDIO_NOT_READY';
            END IF;
        END IF;
        -- Every dialogue line that still has a live take must have
        -- a canonical take. Archive the takes of a dropped line.
        SELECT min(l.audio_order)
        INTO v_uncovered_audio_order
        FROM (
            SELECT sap.audio_order
            FROM public.shot_audio_productions sap
            WHERE sap.shot_specification_id = v_spec_id
              AND sap.status <> 'ARCHIVED'
            GROUP BY sap.audio_order
            HAVING COUNT(*) FILTER (
                WHERE sap.is_canonical = true
            ) = 0
        ) l;
        IF v_uncovered_audio_order IS NOT NULL THEN
            RAISE EXCEPTION
                'AUDIO_LINE_WITHOUT_CANONICAL_TAKE: %',
                v_uncovered_audio_order;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_production_authorization =====
CREATE OR REPLACE FUNCTION public.require_production_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_authorized boolean;
begin
    if new.status = 'BUDGET_RESERVED'
       and old.status = 'CREATED'
    then
        select e.production_authorized
        into v_authorized
        from public.shots s
        join public.episodes e
            on e.id = s.episode_id
        where s.id = new.shot_id;
        if coalesce(v_authorized, false) is not true then
            raise exception 'PRODUCTION_NOT_AUTHORIZED';
        end if;
    end if;
    return new;
end;
$function$
;
-- ===== require_production_pilot_gate =====
CREATE OR REPLACE FUNCTION public.require_production_pilot_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;
    v_production_version integer;
    v_manifest_id uuid;
    v_pilot_shot_id uuid;
    v_pilot_state text;
    v_pilot_locked_at timestamptz;
    v_pilot_pass_count integer;
BEGIN
    -- -----------------------------------------------------
    -- Only paid generation acquisition.
    -- -----------------------------------------------------
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Resolve episode.
    -- -----------------------------------------------------
    SELECT
        s.episode_id,
        e.production_version
    INTO
        v_episode_id,
        v_production_version
    FROM public.shots s
    JOIN public.episodes e
      ON e.id = s.episode_id
    WHERE s.id = NEW.shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_SHOT_OR_EPISODE_NOT_FOUND';
    END IF;
    -- -----------------------------------------------------
    -- Resolve EXACT canonical locked manifest.
    -- -----------------------------------------------------
    SELECT
        pm.id,
        pm.pilot_shot_id
    INTO
        v_manifest_id,
        v_pilot_shot_id
    FROM public.production_manifests pm
    WHERE pm.episode_id = v_episode_id
      AND pm.production_version =
          v_production_version
      AND pm.status = 'LOCKED'
      AND pm.human_approved = true
      AND pm.locked_at IS NOT NULL
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_LOCKED_MANIFEST_NOT_FOUND';
    END IF;
    IF v_pilot_shot_id IS NULL THEN
        RAISE EXCEPTION
            'PILOT_GATE_PILOT_SHOT_NOT_CONFIGURED';
    END IF;
    -- -----------------------------------------------------
    -- Defense in depth:
    -- requested shot must itself belong to this manifest.
    -- -----------------------------------------------------
    IF NOT EXISTS (
        SELECT 1
        FROM public.production_manifest_shots pms
        WHERE pms.manifest_id = v_manifest_id
          AND pms.shot_id = NEW.shot_id
    )
    THEN
        RAISE EXCEPTION
            'PILOT_GATE_SHOT_NOT_IN_MANIFEST';
    END IF;
    -- -----------------------------------------------------
    -- Pilot itself may generate/retry before it passes.
    -- Existing max-2-attempt rules remain authoritative.
    -- -----------------------------------------------------
    IF NEW.shot_id = v_pilot_shot_id THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Non-pilot shots are blocked until pilot is LOCKED.
    -- -----------------------------------------------------
    SELECT
        s.state,
        s.locked_at
    INTO
        v_pilot_state,
        v_pilot_locked_at
    FROM public.shots s
    WHERE s.id = v_pilot_shot_id
      AND s.episode_id = v_episode_id
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_PILOT_SHOT_NOT_FOUND';
    END IF;
    IF v_pilot_state <> 'LOCKED'
       OR v_pilot_locked_at IS NULL
    THEN
        RAISE EXCEPTION
            'PILOT_SHOT_NOT_YET_LOCKED';
    END IF;
    -- -----------------------------------------------------
    -- Real QC evidence required.
    --
    -- generation_outputs is the canonical QC source:
    -- PASS + canonical + reviewed output.
    -- -----------------------------------------------------
    SELECT COUNT(*)
    INTO v_pilot_pass_count
    FROM public.generation_outputs go
    JOIN public.attempts a
      ON a.id = go.attempt_id
     AND a.shot_id = v_pilot_shot_id
     AND a.status = 'SUCCEEDED'
    WHERE go.shot_id = v_pilot_shot_id
      AND go.qc_status = 'PASS'
      AND go.is_canonical = true
      AND go.reviewed_at IS NOT NULL
      AND (
            (
                go.storage_path IS NOT NULL
                AND btrim(go.storage_path) <> ''
            )
            OR
            (
                go.source_url IS NOT NULL
                AND btrim(go.source_url) <> ''
            )
      );
    IF v_pilot_pass_count <> 1 THEN
        RAISE EXCEPTION
            'PILOT_SHOT_QC_PASS_REQUIRED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== require_router_authorized_attempt =====
CREATE OR REPLACE FUNCTION public.require_router_authorized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_decision_status text;
    v_decision_shot_id uuid;
    v_decision_spec_id uuid;
    v_decision_attempt_no integer;
    v_selected_model_id uuid;
    v_selected_pricing_id uuid;
    v_decision_estimated_cost numeric;
    v_spec_shot_id uuid;
    v_spec_version integer;
    v_spec_status text;
    v_spec_active boolean;
    v_spec_locked_at timestamptz;
    v_model_provider_id uuid;
    v_model_code text;
    v_model_status text;
    v_provider_code text;
    v_provider_status text;
    v_pricing_model_id uuid;
    v_pricing_currency text;
    v_pricing_verified boolean;
    v_pricing_verified_at timestamptz;
    v_pricing_effective_from timestamptz;
    v_pricing_effective_to timestamptz;
BEGIN
    -- -----------------------------------------------------
    -- Only paid/reserved attempts require router gate.
    -- -----------------------------------------------------
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Routing decision is mandatory.
    -- -----------------------------------------------------
    IF NEW.routing_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_REQUIRED';
    END IF;
    -- -----------------------------------------------------
    -- Lock routing decision during attempt creation.
    -- -----------------------------------------------------
    SELECT
        grd.decision_status,
        grd.shot_id,
        grd.shot_specification_id,
        grd.attempt_no,
        grd.selected_model_id,
        grd.selected_pricing_id,
        grd.estimated_cost
    INTO
        v_decision_status,
        v_decision_shot_id,
        v_decision_spec_id,
        v_decision_attempt_no,
        v_selected_model_id,
        v_selected_pricing_id,
        v_decision_estimated_cost
    FROM public.generation_routing_decisions grd
    WHERE grd.id = NEW.routing_decision_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_FOUND';
    END IF;
    IF v_decision_status <> 'SELECTED' THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_decision_status;
    END IF;
    -- -----------------------------------------------------
    -- Exact shot + attempt number.
    -- -----------------------------------------------------
    IF v_decision_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_SHOT_MISMATCH';
    END IF;
    IF v_decision_attempt_no <> NEW.attempt_no THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ATTEMPT_MISMATCH';
    END IF;
    IF v_selected_model_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_SELECTED_MODEL_REQUIRED';
    END IF;
    IF v_selected_pricing_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_SELECTED_PRICING_REQUIRED';
    END IF;
    IF v_decision_estimated_cost IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_ESTIMATED_COST_REQUIRED';
    END IF;
    -- -----------------------------------------------------
    -- Exact specification must still be canonical.
    -- -----------------------------------------------------
    SELECT
        ss.shot_id,
        ss.version,
        ss.status,
        ss.is_active,
        ss.locked_at
    INTO
        v_spec_shot_id,
        v_spec_version,
        v_spec_status,
        v_spec_active,
        v_spec_locked_at
    FROM public.shot_specifications ss
    WHERE ss.id = v_decision_spec_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_FOUND';
    END IF;
    IF v_spec_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_SHOT_MISMATCH';
    END IF;
    IF v_spec_status <> 'LOCKED'
       OR v_spec_locked_at IS NULL
       OR COALESCE(v_spec_active, false) IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'ROUTING_SPECIFICATION_NOT_CANONICAL';
    END IF;
    IF v_spec_version <> NEW.prompt_version THEN
        RAISE EXCEPTION
            'ROUTING_PROMPT_VERSION_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- Selected model.
    -- -----------------------------------------------------
    SELECT
        gm.provider_id,
        gm.model_code,
        gm.status
    INTO
        v_model_provider_id,
        v_model_code,
        v_model_status
    FROM public.generation_models gm
    WHERE gm.id = v_selected_model_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_MODEL_NOT_FOUND';
    END IF;
    IF v_model_status NOT IN (
        'ACTIVE',
        'TESTING'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_MODEL_NOT_ENABLED: %',
            v_model_status;
    END IF;
    -- -----------------------------------------------------
    -- Provider.
    -- -----------------------------------------------------
    SELECT
        gp.provider_code,
        gp.status
    INTO
        v_provider_code,
        v_provider_status
    FROM public.generation_providers gp
    WHERE gp.id = v_model_provider_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_PROVIDER_NOT_FOUND';
    END IF;
    IF v_provider_status NOT IN (
        'ACTIVE',
        'TESTING'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_PROVIDER_NOT_ENABLED: %',
            v_provider_status;
    END IF;
    -- -----------------------------------------------------
    -- Exact provider/model match.
    -- -----------------------------------------------------
    IF NEW.provider <> v_provider_code THEN
        RAISE EXCEPTION
            'ATTEMPT_PROVIDER_DOES_NOT_MATCH_ROUTER';
    END IF;
    IF NEW.model <> v_model_code THEN
        RAISE EXCEPTION
            'ATTEMPT_MODEL_DOES_NOT_MATCH_ROUTER';
    END IF;
    -- -----------------------------------------------------
    -- Pricing validation.
    --
    -- Must:
    -- belong to selected model
    -- be USD
    -- be verified
    -- be currently effective
    -- -----------------------------------------------------
    SELECT
        gmp.model_id,
        gmp.currency,
        gmp.is_verified,
        gmp.verified_at,
        gmp.effective_from,
        gmp.effective_to
    INTO
        v_pricing_model_id,
        v_pricing_currency,
        v_pricing_verified,
        v_pricing_verified_at,
        v_pricing_effective_from,
        v_pricing_effective_to
    FROM public.generation_model_pricing gmp
    WHERE gmp.id = v_selected_pricing_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_FOUND';
    END IF;
    IF v_pricing_model_id <> v_selected_model_id THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_MODEL_MISMATCH';
    END IF;
    IF v_pricing_currency <> 'USD' THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_CURRENCY_INVALID';
    END IF;
    IF COALESCE(v_pricing_verified, false) IS NOT TRUE
       OR v_pricing_verified_at IS NULL
    THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_VERIFIED';
    END IF;
    IF v_pricing_effective_from > now()
       OR (
            v_pricing_effective_to IS NOT NULL
            AND v_pricing_effective_to <= now()
       )
    THEN
        RAISE EXCEPTION
            'ROUTING_PRICING_NOT_EFFECTIVE';
    END IF;
    -- -----------------------------------------------------
    -- Estimated cost must be EXACTLY router-approved.
    --
    -- numeric = deterministic comparison.
    -- -----------------------------------------------------
    IF NEW.estimated_cost
       IS DISTINCT FROM
       v_decision_estimated_cost
    THEN
        RAISE EXCEPTION
            'ATTEMPT_COST_DOES_NOT_MATCH_ROUTER';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== reserve_benchmark_job_budget =====
CREATE OR REPLACE FUNCTION public.reserve_benchmark_job_budget()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_case_run_id uuid;
    v_pricing_model_id uuid;
    v_pricing_verified boolean;
    v_verified_at timestamptz;
    v_effective_from timestamptz;
    v_effective_to timestamptz;
    v_run_status text;
    v_human_approved boolean;
    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;
    v_max_count integer;
    v_generation_count integer;
    v_should_reserve boolean := false;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_should_reserve :=
            NEW.status = 'BUDGET_RESERVED';
    ELSIF TG_OP = 'UPDATE' THEN
        v_should_reserve :=
            OLD.status <> 'BUDGET_RESERVED'
            AND NEW.status = 'BUDGET_RESERVED';
    END IF;
    IF v_should_reserve IS NOT TRUE THEN
        RETURN NEW;
    END IF;
    SELECT gbc.benchmark_run_id
    INTO v_case_run_id
    FROM public.generation_benchmark_cases gbc
    WHERE gbc.id = NEW.benchmark_case_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_NOT_FOUND';
    END IF;
    IF v_case_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_RUN_MISMATCH';
    END IF;
    SELECT
        gmp.model_id,
        gmp.is_verified,
        gmp.verified_at,
        gmp.effective_from,
        gmp.effective_to
    INTO
        v_pricing_model_id,
        v_pricing_verified,
        v_verified_at,
        v_effective_from,
        v_effective_to
    FROM public.generation_model_pricing gmp
    WHERE gmp.id = NEW.pricing_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_FOUND';
    END IF;
    IF v_pricing_model_id <> NEW.model_id THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_MODEL_MISMATCH';
    END IF;
    IF COALESCE(v_pricing_verified, false) IS NOT TRUE
       OR v_verified_at IS NULL
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_VERIFIED';
    END IF;
    IF v_effective_from > now()
       OR (
            v_effective_to IS NOT NULL
            AND v_effective_to <= now()
       )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_EFFECTIVE';
    END IF;
    SELECT
        gbr.status,
        gbr.human_approved,
        gbr.hard_budget_usd,
        gbr.reserved_usd,
        gbr.settled_usd,
        gbr.max_generation_count,
        gbr.generation_count
    INTO
        v_run_status,
        v_human_approved,
        v_hard_budget,
        v_reserved,
        v_settled,
        v_max_count,
        v_generation_count
    FROM public.generation_benchmark_runs gbr
    WHERE gbr.id = NEW.benchmark_run_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_FOUND';
    END IF;
    IF v_run_status <> 'RUNNING'
       OR v_human_approved IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_AUTHORIZED';
    END IF;
    IF v_generation_count + 1 > v_max_count THEN
        RAISE EXCEPTION
            'BENCHMARK_GENERATION_LIMIT_EXCEEDED';
    END IF;
    IF (
        v_reserved
        + v_settled
        + NEW.estimated_cost
    ) > v_hard_budget
    THEN
        RAISE EXCEPTION
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    END IF;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );
    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd
            + NEW.estimated_cost,
        generation_count =
            generation_count + 1,
        updated_at = now()
    WHERE id = NEW.benchmark_run_id;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );
    RETURN NEW;
END;
$function$
;
-- ===== reset_attempt_submission_claim =====
CREATE OR REPLACE FUNCTION public.reset_attempt_submission_claim(p_attempt_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(attempt_id uuid, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_shot_id uuid;
    v_claimed_at timestamptz;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    select a.status, a.shot_id, a.submission_claimed_at
    into v_status, v_shot_id, v_claimed_at
    from public.attempts a
    where a.id = p_attempt_id
    for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_status <> 'BUDGET_RESERVED' then
        raise exception
            'ATTEMPT_CLAIM_NOT_RESETTABLE: %',
            v_status;
    end if;
    if v_claimed_at is null then
        return query
        select p_attempt_id, 'NOT_CLAIMED'::text;
        return;
    end if;
    update public.attempts
    set
        submission_claimed_at = null,
        submission_claimed_by = null
    where id = p_attempt_id;
    insert into public.events (
        event_type,
        shot_id,
        attempt_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'ATTEMPT_SUBMISSION_CLAIM_RESET',
        v_shot_id,
        p_attempt_id,
        'WARNING',
        'RECOVERY',
        'Submission claim reset after reconciliation.',
        jsonb_build_object(
            'actor', p_actor,
            'reason', p_reason,
            'previous_claimed_at', v_claimed_at
        )
    );
    return query
    select p_attempt_id, 'CLAIM_RESET'::text;
end;
$function$
;
-- ===== resolve_escalated_shot =====
CREATE OR REPLACE FUNCTION public.resolve_escalated_shot(p_token text, p_resolution text, p_decided_by text, p_note text DEFAULT NULL::text, p_output_id uuid DEFAULT NULL::uuid, p_channel text DEFAULT NULL::text)
 RETURNS TABLE(shot_id uuid, resolution text, shot_state text, canonical_output_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
    v_shot_id uuid;
    v_state text;
    v_out_shot_id uuid;
    v_out_attempt_id uuid;
    v_out_storage_path text;
    v_out_qc_status text;
    v_out_qc_score numeric;
    v_attempt_status text;
begin
    if p_resolution not in ('ACCEPT_OUTPUT', 'CANCEL_SHOT') then
        raise exception 'INVALID_ESCALATION_RESOLUTION';
    end if;
    if p_resolution = 'ACCEPT_OUTPUT'
       and p_output_id is null
    then
        raise exception 'OUTPUT_ID_REQUIRED';
    end if;
    v_row := public.consume_approval_token(
        p_token,
        'SHOT_ESCALATION',
        'APPROVED',
        p_decided_by,
        p_channel,
        coalesce(p_note, '') || ' [' || p_resolution || ']'
    );
    v_shot_id := v_row.scope_id;
    select s.state
    into v_state
    from public.shots s
    where s.id = v_shot_id
    for update;
    if not found then
        raise exception 'SHOT_NOT_FOUND';
    end if;
    if v_state <> 'ESCALATED' then
        raise exception
            'SHOT_NOT_ESCALATED: %',
            v_state;
    end if;
    if p_resolution = 'CANCEL_SHOT' then
        update public.shots
        set state = 'CANCELLED'
        where id = v_shot_id;
        insert into public.events (
            event_type, shot_id, severity, source, message, metadata
        )
        values (
            'ESCALATED_SHOT_CANCELLED',
            v_shot_id,
            'WARNING',
            'HUMAN_APPROVAL',
            'Escalated shot cancelled by ' || p_decided_by,
            jsonb_build_object(
                'request_id', v_row.id,
                'decided_by', p_decided_by,
                'note', p_note
            )
        );
        return query
        select v_shot_id, p_resolution, 'CANCELLED'::text, null::uuid;
        return;
    end if;
    -- ACCEPT_OUTPUT
    select
        go.shot_id,
        go.attempt_id,
        go.storage_path,
        go.qc_status,
        go.qc_score
    into
        v_out_shot_id,
        v_out_attempt_id,
        v_out_storage_path,
        v_out_qc_status,
        v_out_qc_score
    from public.generation_outputs go
    where go.id = p_output_id
    for update;
    if not found then
        raise exception 'GENERATION_OUTPUT_NOT_FOUND';
    end if;
    if v_out_shot_id <> v_shot_id then
        raise exception 'GENERATION_OUTPUT_SHOT_MISMATCH';
    end if;
    if v_out_storage_path is null
       or btrim(v_out_storage_path) = ''
    then
        raise exception 'ACCEPTED_OUTPUT_REQUIRES_DURABLE_STORAGE';
    end if;
    select a.status
    into v_attempt_status
    from public.attempts a
    where a.id = v_out_attempt_id;
    if v_attempt_status is distinct from 'SUCCEEDED' then
        raise exception
            'ACCEPTED_OUTPUT_REQUIRES_SUCCEEDED_ATTEMPT: %',
            coalesce(v_attempt_status, 'NULL');
    end if;
    update public.generation_outputs go
    set
        qc_status = 'PASS',
        status = 'AVAILABLE',
        is_canonical = true,
        reviewed_at = now(),
        qc_details =
            coalesce(go.qc_details, '{}'::jsonb)
            || jsonb_build_object(
                'human_override',
                jsonb_build_object(
                    'request_id', v_row.id,
                    'decided_by', p_decided_by,
                    'note', p_note,
                    'previous_qc_status', v_out_qc_status,
                    'previous_qc_score', v_out_qc_score,
                    'decided_at', now()
                )
            )
    where go.id = p_output_id;
    perform set_config('m417.human_resolution', 'on', true);
    update public.shots
    set state = 'LOCKED'
    where id = v_shot_id;
    perform set_config('m417.human_resolution', 'off', true);
    insert into public.events (
        event_type, shot_id, attempt_id, severity, source, message, metadata
    )
    values (
        'ESCALATED_SHOT_OUTPUT_ACCEPTED',
        v_shot_id,
        v_out_attempt_id,
        'WARNING',
        'HUMAN_APPROVAL',
        'Rejected output accepted by ' || p_decided_by,
        jsonb_build_object(
            'request_id', v_row.id,
            'output_id', p_output_id,
            'decided_by', p_decided_by,
            'note', p_note,
            'previous_qc_status', v_out_qc_status,
            'previous_qc_score', v_out_qc_score
        )
    );
    return query
    select v_shot_id, p_resolution, 'LOCKED'::text, p_output_id;
end;
$function$
;
-- ===== retire_locked_asset =====
CREATE OR REPLACE FUNCTION public.retire_locked_asset(p_asset_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(asset_id uuid, asset_code text, version integer, affected_open_shots integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_code text;
    v_version integer;
    v_affected integer;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    select ar.status, ar.asset_code, ar.version
    into v_status, v_code, v_version
    from public.asset_registry ar
    where ar.id = p_asset_id
    for update;
    if not found then
        raise exception 'ASSET_NOT_FOUND';
    end if;
    if v_status <> 'LOCKED' then
        raise exception
            'ASSET_NOT_LOCKED: %',
            v_status;
    end if;
    -- Never pull a reference out from under a paid generation.
    if exists (
        select 1
        from public.attempts a
        join public.shot_specifications ss
          on ss.shot_id = a.shot_id
         and ss.is_active = true
        where a.status in (
                  'BUDGET_RESERVED',
                  'SUBMITTED',
                  'GENERATING'
              )
          and (
                exists (
                    select 1
                    from public.shot_reference_assets sra
                    where sra.shot_specification_id = ss.id
                      and sra.asset_id = p_asset_id
                )
                or exists (
                    select 1
                    from public.storyboard_reviews sr
                    where sr.shot_specification_id = ss.id
                      and sr.storyboard_asset_id = p_asset_id
                )
          )
    )
    then
        raise exception 'ASSET_IN_USE_BY_ACTIVE_ATTEMPT';
    end if;
    -- Shots that are not finished yet and still point at this asset.
    -- They will be blocked until they get a new specification.
    select count(distinct s.id)
    into v_affected
    from public.shots s
    join public.shot_specifications ss
      on ss.shot_id = s.id
     and ss.is_active = true
    where s.state not in ('LOCKED', 'CANCELLED')
      and (
            exists (
                select 1
                from public.shot_reference_assets sra
                where sra.shot_specification_id = ss.id
                  and sra.asset_id = p_asset_id
            )
            or exists (
                select 1
                from public.storyboard_reviews sr
                where sr.shot_specification_id = ss.id
                  and sr.storyboard_asset_id = p_asset_id
            )
      );
    perform set_config('m417.asset_retirement', 'on', true);
    update public.asset_registry
    set status = 'ARCHIVED'
    where id = p_asset_id;
    perform set_config('m417.asset_retirement', 'off', true);
    insert into public.events (
        event_type,
        severity,
        source,
        message,
        metadata
    )
    values (
        'LOCKED_ASSET_RETIRED',
        'WARNING',
        'CONTROL_PLANE',
        'Locked asset retired.',
        jsonb_build_object(
            'asset_id', p_asset_id,
            'asset_code', v_code,
            'version', v_version,
            'actor', p_actor,
            'reason', p_reason,
            'affected_open_shots', v_affected
        )
    );
    return query
    select p_asset_id, v_code, v_version, v_affected;
end;
$function$
;
-- ===== rls_auto_enable =====
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;
-- ===== set_generation_enabled =====
CREATE OR REPLACE FUNCTION public.set_generation_enabled(p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
    update public.system_flags
    set value = p_enabled
    where key = 'generation_enabled';
    if not found then
        raise exception 'GENERATION_FLAG_MISSING';
    end if;
    insert into public.events (
        event_type,
        severity,
        source,
        message,
        metadata
    )
    values (
        case
            when p_enabled
            then 'GENERATION_ENABLED'
            else 'GENERATION_DISABLED'
        end,
        case
            when p_enabled
            then 'INFO'
            else 'WARNING'
        end,
        'CONTROL_PLANE',
        case
            when p_enabled
            then 'Paid generation enabled'
            else 'Paid generation disabled'
        end,
        jsonb_build_object(
            'enabled',
            p_enabled
        )
    );
    return p_enabled;
end;
$function$
;
-- ===== set_updated_at =====
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    new.updated_at = now();
    return new;
end;
$function$
;
-- ===== settle_benchmark_job_v2 =====
CREATE OR REPLACE FUNCTION public.settle_benchmark_job_v2(p_job_id uuid, p_actual_cost numeric, p_output_url text DEFAULT NULL::text, p_storage_path text DEFAULT NULL::text)
 RETURNS TABLE(job_id uuid, estimated_cost numeric, actual_cost numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_run_id uuid;
    v_status text;
    v_estimated_cost numeric;
    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;
    v_overrun numeric;
    v_generation_disabled boolean := false;
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'BENCHMARK_JOB_ID_REQUIRED';
    END IF;
    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION 'INVALID_BENCHMARK_ACTUAL_COST';
    END IF;
    SELECT
        gbj.benchmark_run_id,
        gbj.status,
        gbj.estimated_cost
    INTO
        v_run_id,
        v_status,
        v_estimated_cost
    FROM public.generation_benchmark_jobs gbj
    WHERE gbj.id = p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BENCHMARK_JOB_NOT_FOUND';
    END IF;
    IF v_status NOT IN ('SUBMITTED', 'GENERATING') THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_SETTLEABLE: %',
            v_status;
    END IF;
    SELECT
        r.hard_budget_usd,
        r.reserved_usd,
        r.settled_usd
    INTO
        v_hard_budget,
        v_reserved,
        v_settled
    FROM public.generation_benchmark_runs r
    WHERE r.id = v_run_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BENCHMARK_RUN_NOT_FOUND';
    END IF;
    IF v_reserved < v_estimated_cost THEN
        RAISE EXCEPTION
            'BENCHMARK_RESERVATION_ACCOUNTING_ERROR';
    END IF;
    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);
    -- =====================================================
    -- ACCOUNTING TRUTH:
    -- reservation removed, actual provider charge recorded.
    -- =====================================================
    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );
    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd - v_estimated_cost,
        settled_usd =
            settled_usd + p_actual_cost,
        updated_at = now()
    WHERE id = v_run_id;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );
    -- Only this function may record a charge above the
    -- reservation (see protect_benchmark_job_accounting_fields).
    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'on',
        true
    );
    UPDATE public.generation_benchmark_jobs
    SET
        actual_cost = p_actual_cost,
        output_url = p_output_url,
        storage_path = p_storage_path,
        status = 'SUCCEEDED',
        completed_at = now()
    WHERE id = p_job_id;
    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'off',
        true
    );
    IF v_overrun > 0
       OR (v_settled + p_actual_cost) > v_hard_budget
    THEN
        INSERT INTO public.events (
            event_type,
            severity,
            source,
            message,
            metadata
        )
        VALUES (
            'BENCHMARK_COST_OVERRUN',
            'CRITICAL',
            'BENCHMARK_ACCOUNTING',
            'Benchmark provider charge exceeded its reservation or the run budget. Generation disabled.',
            jsonb_build_object(
                'benchmark_job_id', p_job_id,
                'benchmark_run_id', v_run_id,
                'estimated_cost', v_estimated_cost,
                'actual_cost', p_actual_cost,
                'overrun', v_overrun,
                'run_hard_budget', v_hard_budget,
                'run_settled_after', v_settled + p_actual_cost
            )
        );
    END IF;
    -- =====================================================
    -- PROVIDER OVERRUN:
    -- Record actual cost, then fail closed.
    -- =====================================================
    IF v_overrun > 0 THEN
        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;
        v_generation_disabled := true;
    END IF;
    -- Even if provider overrun pushes the run beyond the
    -- hard benchmark budget, accounting truth is preserved.
    -- Further generation is stopped instead of hiding cost.
    IF (v_settled + p_actual_cost) > v_hard_budget THEN
        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;
        v_generation_disabled := true;
    END IF;
    RETURN QUERY
    SELECT
        p_job_id,
        v_estimated_cost,
        p_actual_cost,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN (v_settled + p_actual_cost) > v_hard_budget
            THEN 'SETTLED_BUDGET_BREACH_GENERATION_DISABLED'
            WHEN v_overrun > 0
            THEN 'SETTLED_OVERRUN_GENERATION_DISABLED'
            ELSE 'SETTLED'
        END::text;
END;
$function$
;
-- ===== settle_charged_benchmark_failure_v2 =====
CREATE OR REPLACE FUNCTION public.settle_charged_benchmark_failure_v2(p_job_id uuid, p_actual_cost numeric, p_final_status text DEFAULT 'FAILED'::text, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(job_id uuid, estimated_cost numeric, actual_cost numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_run_id uuid;
    v_status text;
    v_estimated_cost numeric;
    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;
    v_overrun numeric;
    v_generation_disabled boolean := false;
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'BENCHMARK_JOB_ID_REQUIRED';
    END IF;
    IF p_final_status NOT IN ('FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION
            'INVALID_CHARGED_FAILURE_STATUS';
    END IF;
    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_ACTUAL_COST';
    END IF;
    SELECT
        gbj.benchmark_run_id,
        gbj.status,
        gbj.estimated_cost
    INTO
        v_run_id,
        v_status,
        v_estimated_cost
    FROM public.generation_benchmark_jobs gbj
    WHERE gbj.id = p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BENCHMARK_JOB_NOT_FOUND';
    END IF;
    IF v_status NOT IN ('SUBMITTED', 'GENERATING') THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_NOT_CHARGED_FAILURE_SETTLEABLE: %',
            v_status;
    END IF;
    SELECT
        r.hard_budget_usd,
        r.reserved_usd,
        r.settled_usd
    INTO
        v_hard_budget,
        v_reserved,
        v_settled
    FROM public.generation_benchmark_runs r
    WHERE r.id = v_run_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BENCHMARK_RUN_NOT_FOUND';
    END IF;
    IF v_reserved < v_estimated_cost THEN
        RAISE EXCEPTION
            'BENCHMARK_RESERVATION_ACCOUNTING_ERROR';
    END IF;
    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);
    PERFORM set_config(
        'm417.benchmark_accounting',
        'on',
        true
    );
    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd - v_estimated_cost,
        settled_usd =
            settled_usd + p_actual_cost,
        updated_at = now()
    WHERE id = v_run_id;
    PERFORM set_config(
        'm417.benchmark_accounting',
        'off',
        true
    );
    -- Only this function may record a charge above the
    -- reservation (see protect_benchmark_job_accounting_fields).
    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'on',
        true
    );
    UPDATE public.generation_benchmark_jobs
    SET
        actual_cost = p_actual_cost,
        status = p_final_status,
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = now()
    WHERE id = p_job_id;
    PERFORM set_config(
        'm417.benchmark_overrun_settlement',
        'off',
        true
    );
    IF v_overrun > 0
       OR (v_settled + p_actual_cost) > v_hard_budget
    THEN
        INSERT INTO public.events (
            event_type,
            severity,
            source,
            message,
            metadata
        )
        VALUES (
            'BENCHMARK_COST_OVERRUN',
            'CRITICAL',
            'BENCHMARK_ACCOUNTING',
            'Benchmark provider charge exceeded its reservation or the run budget. Generation disabled.',
            jsonb_build_object(
                'benchmark_job_id', p_job_id,
                'benchmark_run_id', v_run_id,
                'estimated_cost', v_estimated_cost,
                'actual_cost', p_actual_cost,
                'overrun', v_overrun,
                'run_hard_budget', v_hard_budget,
                'run_settled_after', v_settled + p_actual_cost
            )
        );
    END IF;
    IF v_overrun > 0
       OR (v_settled + p_actual_cost) > v_hard_budget
    THEN
        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;
        v_generation_disabled := true;
    END IF;
    RETURN QUERY
    SELECT
        p_job_id,
        v_estimated_cost,
        p_actual_cost,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN (v_settled + p_actual_cost) > v_hard_budget
            THEN 'CHARGED_FAILURE_BUDGET_BREACH_GENERATION_DISABLED'
            WHEN v_overrun > 0
            THEN 'CHARGED_FAILURE_OVERRUN_GENERATION_DISABLED'
            ELSE 'CHARGED_FAILURE_SETTLED'
        END::text;
END;
$function$
;
-- ===== settle_charged_generation_failure_v2 =====
CREATE OR REPLACE FUNCTION public.settle_charged_generation_failure_v2(p_attempt_id uuid, p_actual_cost numeric, p_error_code text DEFAULT NULL::text, p_error_detail text DEFAULT NULL::text)
 RETURNS TABLE(attempt_id uuid, estimated_cost numeric, actual_cost numeric, released_amount numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_episode_id uuid;
    v_estimated_cost numeric;
    v_status text;
    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;
    v_release numeric;
    v_overrun numeric;
    v_generation_disabled boolean := false;
BEGIN
    IF p_attempt_id IS NULL THEN
        RAISE EXCEPTION 'ATTEMPT_ID_REQUIRED';
    END IF;
    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION 'INVALID_ACTUAL_COST';
    END IF;
    SELECT
        a.shot_id,
        a.estimated_cost,
        a.status,
        a.monthly_budget_id,
        a.episode_budget_id,
        a.shot_budget_id
    INTO
        v_shot_id,
        v_estimated_cost,
        v_status,
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    FROM public.attempts a
    WHERE a.id = p_attempt_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTEMPT_NOT_FOUND';
    END IF;
    IF v_status NOT IN (
        'BUDGET_RESERVED',
        'SUBMITTED',
        'GENERATING'
    ) THEN
        RAISE EXCEPTION
            'ATTEMPT_NOT_CHARGED_FAILURE_SETTLEABLE: %',
            v_status;
    END IF;
    IF v_monthly_budget_id IS NULL
       OR v_episode_budget_id IS NULL
       OR v_shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION 'ATTEMPT_BUDGET_BINDINGS_MISSING';
    END IF;
    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = v_shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;
    PERFORM 1
    FROM public.budgets b
    WHERE b.id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    ORDER BY b.id
    FOR UPDATE;
    IF (
        SELECT COUNT(*)
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
    ) <> 3 THEN
        RAISE EXCEPTION 'BOUND_BUDGET_NOT_FOUND';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
        AND b.reserved_amount < v_estimated_cost
    ) THEN
        RAISE EXCEPTION 'BOUND_RESERVED_BALANCE_INVALID';
    END IF;
    v_release :=
        GREATEST(v_estimated_cost - p_actual_cost, 0);
    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);
    UPDATE public.budgets
    SET
        reserved_amount =
            reserved_amount - v_estimated_cost,
        settled_amount =
            settled_amount + p_actual_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );
    UPDATE public.attempts
    SET
        actual_cost = p_actual_cost,
        status = 'FAILED',
        error_code = p_error_code,
        error_detail = p_error_detail,
        finished_at = now()
    WHERE id = p_attempt_id;
    -- SETTLE is the SINGLE accounting record of actual provider charge.
    INSERT INTO public.cost_ledger (
        attempt_id,
        episode_id,
        shot_id,
        entry_type,
        amount,
        currency,
        description
    )
    VALUES (
        p_attempt_id,
        v_episode_id,
        v_shot_id,
        'SETTLE',
        p_actual_cost,
        'USD',
        CASE
            WHEN v_overrun > 0
            THEN 'Charged generation failure settled; provider overrun detected'
            ELSE 'Charged generation failure settled'
        END
    );
    IF v_release > 0 THEN
        INSERT INTO public.cost_ledger (
            attempt_id,
            episode_id,
            shot_id,
            entry_type,
            amount,
            currency,
            description
        )
        VALUES (
            p_attempt_id,
            v_episode_id,
            v_shot_id,
            'RELEASE',
            v_release,
            'USD',
            'Unused reservation released after charged failure'
        );
    END IF;
    -- Overrun already exists inside SETTLE actual_cost.
    -- No duplicate ADJUSTMENT row.
    IF v_overrun > 0 THEN
        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;
        v_generation_disabled := true;
    END IF;
    RETURN QUERY
    SELECT
        p_attempt_id,
        v_estimated_cost,
        p_actual_cost,
        v_release,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN v_overrun > 0
            THEN 'CHARGED_FAILURE_OVERRUN_GENERATION_DISABLED'
            ELSE 'CHARGED_FAILURE_SETTLED'
        END::text;
END;
$function$
;
-- ===== settle_generation_attempt_v2 =====
CREATE OR REPLACE FUNCTION public.settle_generation_attempt_v2(p_attempt_id uuid, p_actual_cost numeric)
 RETURNS TABLE(attempt_id uuid, estimated_cost numeric, actual_cost numeric, released_amount numeric, overrun_amount numeric, generation_disabled boolean, decision text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_episode_id uuid;
    v_estimated_cost numeric;
    v_status text;
    v_monthly_budget_id uuid;
    v_episode_budget_id uuid;
    v_shot_budget_id uuid;
    v_release numeric;
    v_overrun numeric;
    v_generation_disabled boolean := false;
BEGIN
    IF p_attempt_id IS NULL THEN
        RAISE EXCEPTION 'ATTEMPT_ID_REQUIRED';
    END IF;
    IF p_actual_cost IS NULL OR p_actual_cost < 0 THEN
        RAISE EXCEPTION 'INVALID_ACTUAL_COST';
    END IF;
    SELECT
        a.shot_id,
        a.estimated_cost,
        a.status,
        a.monthly_budget_id,
        a.episode_budget_id,
        a.shot_budget_id
    INTO
        v_shot_id,
        v_estimated_cost,
        v_status,
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    FROM public.attempts a
    WHERE a.id = p_attempt_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTEMPT_NOT_FOUND';
    END IF;
    IF v_status NOT IN ('SUBMITTED', 'GENERATING') THEN
        RAISE EXCEPTION
            'ATTEMPT_NOT_SETTLEABLE: %',
            v_status;
    END IF;
    IF v_monthly_budget_id IS NULL
       OR v_episode_budget_id IS NULL
       OR v_shot_budget_id IS NULL
    THEN
        RAISE EXCEPTION 'ATTEMPT_BUDGET_BINDINGS_MISSING';
    END IF;
    SELECT s.episode_id
    INTO v_episode_id
    FROM public.shots s
    WHERE s.id = v_shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHOT_NOT_FOUND';
    END IF;
    PERFORM 1
    FROM public.budgets b
    WHERE b.id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    )
    ORDER BY b.id
    FOR UPDATE;
    IF (
        SELECT COUNT(*)
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
    ) <> 3 THEN
        RAISE EXCEPTION 'BOUND_BUDGET_NOT_FOUND';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.budgets b
        WHERE b.id IN (
            v_monthly_budget_id,
            v_episode_budget_id,
            v_shot_budget_id
        )
        AND b.reserved_amount < v_estimated_cost
    ) THEN
        RAISE EXCEPTION 'BOUND_RESERVED_BALANCE_INVALID';
    END IF;
    v_release :=
        GREATEST(v_estimated_cost - p_actual_cost, 0);
    v_overrun :=
        GREATEST(p_actual_cost - v_estimated_cost, 0);
    -- Remove original reservation and settle actual provider cost.
    UPDATE public.budgets
    SET
        reserved_amount =
            reserved_amount - v_estimated_cost,
        settled_amount =
            settled_amount + p_actual_cost
    WHERE id IN (
        v_monthly_budget_id,
        v_episode_budget_id,
        v_shot_budget_id
    );
    UPDATE public.attempts
    SET
        actual_cost = p_actual_cost,
        status = 'SUCCEEDED',
        finished_at = now()
    WHERE id = p_attempt_id;
    -- SETTLE is the SINGLE accounting record of actual spend.
    INSERT INTO public.cost_ledger (
        attempt_id,
        episode_id,
        shot_id,
        entry_type,
        amount,
        currency,
        description
    )
    VALUES (
        p_attempt_id,
        v_episode_id,
        v_shot_id,
        'SETTLE',
        p_actual_cost,
        'USD',
        CASE
            WHEN v_overrun > 0
            THEN 'Actual generation cost settled; provider overrun detected'
            ELSE 'Actual generation cost settled'
        END
    );
    -- Release unused reservation only when actual < estimate.
    IF v_release > 0 THEN
        INSERT INTO public.cost_ledger (
            attempt_id,
            episode_id,
            shot_id,
            entry_type,
            amount,
            currency,
            description
        )
        VALUES (
            p_attempt_id,
            v_episode_id,
            v_shot_id,
            'RELEASE',
            v_release,
            'USD',
            'Unused generation reservation released'
        );
    END IF;
    -- Overrun is already included in SETTLE actual_cost.
    -- DO NOT create an additional ADJUSTMENT cost row.
    IF v_overrun > 0 THEN
        UPDATE public.system_flags
        SET value = false
        WHERE key = 'generation_enabled';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
        END IF;
        v_generation_disabled := true;
    END IF;
    RETURN QUERY
    SELECT
        p_attempt_id,
        v_estimated_cost,
        p_actual_cost,
        v_release,
        v_overrun,
        v_generation_disabled,
        CASE
            WHEN v_overrun > 0
            THEN 'SETTLED_OVERRUN_GENERATION_DISABLED'
            ELSE 'SETTLED'
        END::text;
END;
$function$
;
-- ===== supersede_routing_decision =====
CREATE OR REPLACE FUNCTION public.supersede_routing_decision(p_decision_id uuid)
 RETURNS TABLE(superseded_decision_id uuid, shot_id uuid, attempt_no integer, next_revision integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_shot_id uuid;
    v_attempt_no integer;
    v_revision integer;
    v_status text;
    v_is_current boolean;
BEGIN
    IF p_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ID_REQUIRED';
    END IF;
    SELECT
        grd.shot_id,
        grd.attempt_no,
        grd.decision_revision,
        grd.decision_status,
        grd.is_current
    INTO
        v_shot_id,
        v_attempt_no,
        v_revision,
        v_status,
        v_is_current
    FROM public.generation_routing_decisions grd
    WHERE grd.id = p_decision_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_FOUND';
    END IF;
    -- -----------------------------------------------------
    -- SELECTED decisions cannot be superseded here.
    --
    -- Their runtime safety is handled by acquisition
    -- fresh-health / pricing / provider gates.
    -- -----------------------------------------------------
    IF v_status = 'SELECTED' THEN
        RAISE EXCEPTION
            'SELECTED_ROUTING_DECISION_CANNOT_BE_SUPERSEDED';
    END IF;
    IF v_status NOT IN (
        'NO_ELIGIBLE_MODEL',
        'BUDGET_BLOCKED',
        'HEALTH_BLOCKED',
        'PRICING_BLOCKED'
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_NOT_REEVALUATABLE: %',
            v_status;
    END IF;
    IF v_is_current IS NOT TRUE THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ALREADY_SUPERSEDED';
    END IF;
    -- -----------------------------------------------------
    -- Ensure no paid attempt already references this
    -- routing decision.
    -- -----------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM public.attempts a
        WHERE a.routing_decision_id = p_decision_id
    )
    THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_ALREADY_USED_BY_ATTEMPT';
    END IF;
    -- -----------------------------------------------------
    -- Controlled CURRENT -> HISTORICAL transition
    -- -----------------------------------------------------
    PERFORM set_config(
        'm417.routing_supersession',
        'on',
        true
    );
    UPDATE public.generation_routing_decisions
    SET is_current = false
    WHERE id = p_decision_id
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
    RETURN QUERY
    SELECT
        p_decision_id,
        v_shot_id,
        v_attempt_no,
        v_revision + 1;
END;
$function$
;
-- ===== supersede_shot_specification =====
CREATE OR REPLACE FUNCTION public.supersede_shot_specification(p_new_specification_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(shot_id uuid, old_specification_id uuid, new_specification_id uuid, new_version integer, retired_routing_decisions integer, next_step text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_shot_id uuid;
    v_new_status text;
    v_new_active boolean;
    v_new_version integer;
    v_new_locked_at timestamptz;
    v_old_id uuid;
    v_old_status text;
    v_old_version integer;
    v_shot_state text;
    v_retired integer := 0;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    select
        ss.shot_id,
        ss.status,
        ss.is_active,
        ss.version,
        ss.locked_at
    into
        v_shot_id,
        v_new_status,
        v_new_active,
        v_new_version,
        v_new_locked_at
    from public.shot_specifications ss
    where ss.id = p_new_specification_id;
    if not found then
        raise exception 'NEW_SPECIFICATION_NOT_FOUND';
    end if;
    select s.state
    into v_shot_state
    from public.shots s
    where s.id = v_shot_id
    for update;
    if v_shot_state in (
        'LOCKED',
        'CANCELLED',
        'QUEUED',
        'GENERATING',
        'GENERATED',
        'QC_PENDING'
    ) then
        raise exception
            'SHOT_STATE_DOES_NOT_ALLOW_NEW_SPECIFICATION: %',
            v_shot_state;
    end if;
    if exists (
        select 1
        from public.attempts a
        where a.shot_id = v_shot_id
          and a.status in (
              'CREATED',
              'BUDGET_RESERVED',
              'SUBMITTED',
              'GENERATING'
          )
    ) then
        raise exception 'SHOT_HAS_ACTIVE_ATTEMPT';
    end if;
    if v_new_status <> 'LOCKED'
       or v_new_locked_at is null
    then
        raise exception
            'NEW_SPECIFICATION_MUST_BE_LOCKED: %',
            v_new_status;
    end if;
    if v_new_active is true then
        raise exception 'NEW_SPECIFICATION_ALREADY_ACTIVE';
    end if;
    select ss.id, ss.status, ss.version
    into v_old_id, v_old_status, v_old_version
    from public.shot_specifications ss
    where ss.shot_id = v_shot_id
      and ss.is_active = true
    for update;
    if not found then
        raise exception 'ACTIVE_SPECIFICATION_NOT_FOUND';
    end if;
    if v_old_status <> 'LOCKED' then
        raise exception
            'ACTIVE_SPECIFICATION_NOT_LOCKED: %',
            v_old_status;
    end if;
    if v_new_version <= v_old_version then
        raise exception
            'NEW_SPECIFICATION_VERSION_MUST_INCREASE: % <= %',
            v_new_version,
            v_old_version;
    end if;
    perform set_config('m417.spec_supersession', 'on', true);
    update public.shot_specifications
    set
        status = 'SUPERSEDED',
        is_active = false
    where id = v_old_id;
    update public.shot_specifications
    set is_active = true
    where id = p_new_specification_id;
    perform set_config('m417.spec_supersession', 'off', true);
    -- Unused routing decisions made for the old specification must
    -- not be handed out again.
    perform set_config('m417.routing_supersession', 'on', true);
    update public.generation_routing_decisions grd
    set is_current = false
    where grd.shot_id = v_shot_id
      and grd.is_current = true
      and grd.shot_specification_id <> p_new_specification_id
      and grd.decision_status <> 'PENDING'
      and not exists (
          select 1
          from public.attempts a
          where a.routing_decision_id = grd.id
      );
    get diagnostics v_retired = row_count;
    perform set_config('m417.routing_supersession', 'off', true);
    insert into public.events (
        event_type,
        shot_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'SHOT_SPECIFICATION_SUPERSEDED',
        v_shot_id,
        'WARNING',
        'CONTROL_PLANE',
        'Active shot specification replaced.',
        jsonb_build_object(
            'old_specification_id', v_old_id,
            'old_version', v_old_version,
            'new_specification_id', p_new_specification_id,
            'new_version', v_new_version,
            'actor', p_actor,
            'reason', p_reason,
            'retired_routing_decisions', v_retired
        )
    );
    return query
    select
        v_shot_id,
        v_old_id,
        p_new_specification_id,
        v_new_version,
        v_retired,
        'NEW_MANIFEST_VERSION_REQUIRED'::text;
end;
$function$
;
-- ===== sync_shot_state_from_attempt =====
CREATE OR REPLACE FUNCTION public.sync_shot_state_from_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_state text;
begin
    if new.status = old.status then
        return new;
    end if;
    select s.state
    into v_state
    from public.shots s
    where s.id = new.shot_id
    for update;
    if not found then
        return new;
    end if;
    -- -------------------------------------------------
    -- Provider accepted / is working.
    -- -------------------------------------------------
    if new.status in ('SUBMITTED', 'GENERATING') then
        if v_state = 'QUEUED' then
            update public.shots
            set state = 'GENERATING'
            where id = new.shot_id;
        end if;
        return new;
    end if;
    -- -------------------------------------------------
    -- Provider produced a result.
    -- -------------------------------------------------
    if new.status = 'SUCCEEDED' then
        if v_state = 'QUEUED' then
            update public.shots
            set state = 'GENERATING'
            where id = new.shot_id;
            v_state := 'GENERATING';
        end if;
        if v_state = 'GENERATING' then
            update public.shots
            set state = 'GENERATED'
            where id = new.shot_id;
            v_state := 'GENERATED';
        end if;
        -- Output may have been registered before settlement.
        if v_state = 'GENERATED'
           and exists (
               select 1
               from public.generation_outputs go
               where go.attempt_id = new.id
                 and go.qc_status in ('PENDING', 'IN_REVIEW')
           )
        then
            update public.shots
            set state = 'QC_PENDING'
            where id = new.shot_id;
        end if;
        return new;
    end if;
    -- -------------------------------------------------
    -- Technical failure / cancellation.
    -- Attempt 1 -> one retry. Attempt 2 -> human.
    -- -------------------------------------------------
    if new.status in ('FAILED', 'CANCELLED') then
        if v_state in ('QUEUED', 'GENERATING') then
            update public.shots
            set state = 'FAILED_TECHNICAL'
            where id = new.shot_id;
            update public.shots
            set state =
                case
                    when new.attempt_no = 1
                    then 'RETRY_REQUIRED'
                    else 'ESCALATED'
                end
            where id = new.shot_id;
        end if;
        return new;
    end if;
    return new;
end;
$function$
;
-- ===== sync_shot_state_from_output =====
CREATE OR REPLACE FUNCTION public.sync_shot_state_from_output()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_attempt_status text;
begin
    select s.state
    into v_state
    from public.shots s
    where s.id = new.shot_id
    for update;
    select a.status
    into v_attempt_status
    from public.attempts a
    where a.id = new.attempt_id;
    if v_state = 'GENERATED'
       and v_attempt_status = 'SUCCEEDED'
       and new.qc_status in ('PENDING', 'IN_REVIEW')
    then
        update public.shots
        set state = 'QC_PENDING'
        where id = new.shot_id;
    end if;
    return new;
end;
$function$
;
-- ===== touch_attempt_heartbeat =====
CREATE OR REPLACE FUNCTION public.touch_attempt_heartbeat(p_attempt_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
    update public.attempts
    set heartbeat_at = now()
    where id = p_attempt_id
      and status in ('SUBMITTED','GENERATING');
    if not found then
        raise exception 'ACTIVE_ATTEMPT_NOT_FOUND';
    end if;
end;
$function$
;
-- ===== validate_attempt_status_transition =====
CREATE OR REPLACE FUNCTION public.validate_attempt_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.status = old.status then
        return new;
    end if;
    -- Final states are terminal.
    if old.status in (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED',
        'ESCALATED'
    ) then
        raise exception
            'FINAL_ATTEMPT_STATUS_IS_IMMUTABLE: %',
            old.status;
    end if;
    -- A paid reservation can only be created by
    -- acquire_generation_attempt_v2 (INSERT as BUDGET_RESERVED).
    if old.status = 'CREATED'
       and new.status = 'BUDGET_RESERVED'
    then
        raise exception 'ATTEMPT_MUST_BE_ACQUIRED_VIA_ROUTER';
    end if;
    if not (
        (old.status = 'CREATED'
            and new.status = 'CANCELLED')
        or
        (old.status = 'BUDGET_RESERVED'
            and new.status in (
                'SUBMITTED',
                'FAILED',
                'CANCELLED'
            ))
        or
        (old.status = 'SUBMITTED'
            and new.status in (
                'GENERATING',
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))
        or
        (old.status = 'GENERATING'
            and new.status in (
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))
    ) then
        raise exception
            'INVALID_ATTEMPT_STATUS_TRANSITION: % -> %',
            old.status,
            new.status;
    end if;
    return new;
end;
$function$
;
-- ===== validate_benchmark_authorization_transition =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_authorization_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP <> 'UPDATE'
       OR NEW.authorization_status =
          OLD.authorization_status
    THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (
            OLD.authorization_status = 'PLANNED'
            AND NEW.authorization_status IN (
                'AUTHORIZED',
                'REVOKED'
            )
        )
        OR
        (
            OLD.authorization_status = 'AUTHORIZED'
            AND NEW.authorization_status IN (
                'CONSUMED',
                'REVOKED'
            )
        )
    )
    THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_AUTHORIZATION_TRANSITION: % -> %',
            OLD.authorization_status,
            NEW.authorization_status;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_generation_job =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_generation_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_case_run_id uuid;
    v_pricing_model_id uuid;
    v_pricing_verified boolean;
    v_pricing_verified_at timestamptz;
    v_effective_from timestamptz;
    v_effective_to timestamptz;
    v_run_status text;
    v_human_approved boolean;
    v_hard_budget numeric;
    v_reserved numeric;
    v_settled numeric;
    v_max_count integer;
    v_generation_count integer;
BEGIN
    -- Only reservation opens a paid benchmark job.
    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- CASE -> RUN
    -- -----------------------------------------------------
    SELECT benchmark_run_id
    INTO v_case_run_id
    FROM public.generation_benchmark_cases
    WHERE id = NEW.benchmark_case_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_NOT_FOUND';
    END IF;
    IF v_case_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_RUN_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- PRICING -> MODEL
    -- -----------------------------------------------------
    SELECT
        model_id,
        is_verified,
        verified_at,
        effective_from,
        effective_to
    INTO
        v_pricing_model_id,
        v_pricing_verified,
        v_pricing_verified_at,
        v_effective_from,
        v_effective_to
    FROM public.generation_model_pricing
    WHERE id = NEW.pricing_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_FOUND';
    END IF;
    IF v_pricing_model_id <> NEW.model_id THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_MODEL_MISMATCH';
    END IF;
    IF COALESCE(
        v_pricing_verified,
        false
    ) IS NOT TRUE
       OR v_pricing_verified_at IS NULL
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_VERIFIED';
    END IF;
    IF v_effective_from > now()
       OR (
            v_effective_to IS NOT NULL
            AND v_effective_to <= now()
       )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_EFFECTIVE';
    END IF;
    -- -----------------------------------------------------
    -- LOCK RUN
    -- -----------------------------------------------------
    SELECT
        status,
        human_approved,
        hard_budget_usd,
        reserved_usd,
        settled_usd,
        max_generation_count,
        generation_count
    INTO
        v_run_status,
        v_human_approved,
        v_hard_budget,
        v_reserved,
        v_settled,
        v_max_count,
        v_generation_count
    FROM public.generation_benchmark_runs
    WHERE id = NEW.benchmark_run_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_FOUND';
    END IF;
    IF v_run_status <> 'RUNNING'
       OR v_human_approved IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'BENCHMARK_RUN_NOT_AUTHORIZED';
    END IF;
    -- -----------------------------------------------------
    -- GENERATION COUNT LIMIT
    -- -----------------------------------------------------
    IF v_generation_count + 1 >
        v_max_count
    THEN
        RAISE EXCEPTION
            'BENCHMARK_GENERATION_LIMIT_EXCEEDED';
    END IF;
    -- -----------------------------------------------------
    -- HARD BUDGET
    -- -----------------------------------------------------
    IF (
        v_reserved
        + v_settled
        + NEW.estimated_cost
    ) > v_hard_budget
    THEN
        RAISE EXCEPTION
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    END IF;
    -- -----------------------------------------------------
    -- RESERVE
    -- -----------------------------------------------------
    UPDATE public.generation_benchmark_runs
    SET
        reserved_usd =
            reserved_usd
            + NEW.estimated_cost,
        generation_count =
            generation_count + 1,
        updated_at = now()
    WHERE id = NEW.benchmark_run_id;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_job_authorization =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_job_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_job_run_id uuid;
    v_job_estimated_cost numeric;
    v_job_status text;
    v_attempt_no integer;
BEGIN
    SELECT
        benchmark_run_id,
        estimated_cost,
        status,
        attempt_no
    INTO
        v_job_run_id,
        v_job_estimated_cost,
        v_job_status,
        v_attempt_no
    FROM public.generation_benchmark_jobs
    WHERE id = NEW.benchmark_job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_JOB_NOT_FOUND';
    END IF;
    IF v_job_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_RUN_MISMATCH';
    END IF;
    IF NEW.authorized_estimated_cost
       <> v_job_estimated_cost
    THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_COST_MISMATCH';
    END IF;
    IF NEW.authorization_stage = 'PILOT'
       AND v_attempt_no <> 1
    THEN
        RAISE EXCEPTION
            'BENCHMARK_PILOT_REQUIRES_ATTEMPT_1';
    END IF;
    IF NEW.authorization_status IN (
        'PLANNED',
        'AUTHORIZED'
    )
    AND v_job_status <> 'CREATED'
    THEN
        RAISE EXCEPTION
            'BENCHMARK_AUTHORIZATION_REQUIRES_CREATED_JOB';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_job_identity =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_job_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_case_run_id uuid;
    v_pricing_model_id uuid;
    v_attempt1_status text;
BEGIN
    -- -----------------------------------------------------
    -- INSERT must begin before provider execution.
    -- Direct creation as SUBMITTED / GENERATING / terminal
    -- is forbidden.
    -- -----------------------------------------------------
    IF NEW.status NOT IN (
        'CREATED',
        'BUDGET_RESERVED'
    )
    THEN
        RAISE EXCEPTION
            'BENCHMARK_JOB_INVALID_INITIAL_STATUS: %',
            NEW.status;
    END IF;
    -- -----------------------------------------------------
    -- CASE MUST BELONG TO RUN
    -- -----------------------------------------------------
    SELECT gbc.benchmark_run_id
    INTO v_case_run_id
    FROM public.generation_benchmark_cases gbc
    WHERE gbc.id = NEW.benchmark_case_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_NOT_FOUND';
    END IF;
    IF v_case_run_id <> NEW.benchmark_run_id THEN
        RAISE EXCEPTION
            'BENCHMARK_CASE_RUN_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- PRICING MUST BELONG TO MODEL
    -- -----------------------------------------------------
    SELECT gmp.model_id
    INTO v_pricing_model_id
    FROM public.generation_model_pricing gmp
    WHERE gmp.id = NEW.pricing_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_NOT_FOUND';
    END IF;
    IF v_pricing_model_id <> NEW.model_id THEN
        RAISE EXCEPTION
            'BENCHMARK_PRICING_MODEL_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- ATTEMPT 1
    -- -----------------------------------------------------
    IF NEW.attempt_no = 1 THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- ATTEMPT 2
    --
    -- Must have attempt 1 for exact same:
    -- case + model
    --
    -- Attempt 1 must be FAILED.
    --
    -- CANCELLED does not authorize another paid generation.
    -- SUCCEEDED obviously does not authorize retry.
    -- -----------------------------------------------------
    SELECT gbj.status
    INTO v_attempt1_status
    FROM public.generation_benchmark_jobs gbj
    WHERE gbj.benchmark_case_id =
            NEW.benchmark_case_id
      AND gbj.model_id =
            NEW.model_id
      AND gbj.attempt_no = 1
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'BENCHMARK_ATTEMPT_2_REQUIRES_ATTEMPT_1';
    END IF;
    IF v_attempt1_status <> 'FAILED' THEN
        RAISE EXCEPTION
            'BENCHMARK_ATTEMPT_2_REQUIRES_FAILED_ATTEMPT_1: current=%',
            v_attempt1_status;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_job_state_fields =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_job_state_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF NEW.status IN (
        'SUBMITTED',
        'GENERATING'
    )
    THEN
        IF NEW.provider_job_id IS NULL
           OR NEW.submitted_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_SUBMITTED_JOB_REQUIRES_PROVIDER_ID_AND_TIMESTAMP';
        END IF;
    END IF;
    IF NEW.status IN (
        'SUCCEEDED',
        'FAILED',
        'CANCELLED'
    )
    THEN
        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'FINALIZED_BENCHMARK_JOB_REQUIRES_COMPLETED_AT';
        END IF;
    END IF;
    IF NEW.status = 'SUCCEEDED' THEN
        IF NEW.actual_cost IS NULL THEN
            RAISE EXCEPTION
                'SUCCEEDED_BENCHMARK_JOB_REQUIRES_ACTUAL_COST';
        END IF;
        IF NEW.output_url IS NULL
           AND NEW.storage_path IS NULL
        THEN
            RAISE EXCEPTION
                'SUCCEEDED_BENCHMARK_JOB_REQUIRES_OUTPUT';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_job_transition =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_job_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP <> 'UPDATE' THEN
        RETURN NEW;
    END IF;
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (OLD.status = 'CREATED'
            AND NEW.status IN (
                'BUDGET_RESERVED',
                'CANCELLED'
            ))
        OR
        (OLD.status = 'BUDGET_RESERVED'
            AND NEW.status IN (
                'SUBMITTED',
                'FAILED',
                'CANCELLED'
            ))
        OR
        (OLD.status = 'SUBMITTED'
            AND NEW.status IN (
                'GENERATING',
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))
        OR
        (OLD.status = 'GENERATING'
            AND NEW.status IN (
                'SUCCEEDED',
                'FAILED',
                'CANCELLED'
            ))
    )
    THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_JOB_TRANSITION: % -> %',
            OLD.status,
            NEW.status;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_benchmark_run_transition =====
CREATE OR REPLACE FUNCTION public.validate_benchmark_run_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP <> 'UPDATE'
       OR NEW.status = OLD.status
    THEN
        RETURN NEW;
    END IF;
    IF NOT (
        (
            OLD.status = 'DRAFT'
            AND NEW.status IN (
                'HUMAN_APPROVED',
                'CANCELLED'
            )
        )
        OR
        (
            OLD.status = 'HUMAN_APPROVED'
            AND NEW.status IN (
                'RUNNING',
                'CANCELLED'
            )
        )
        OR
        (
            OLD.status = 'RUNNING'
            AND NEW.status IN (
                'COMPLETED',
                'CANCELLED',
                'BLOCKED'
            )
        )
        OR
        (
            OLD.status = 'BLOCKED'
            AND NEW.status IN (
                'RUNNING',
                'CANCELLED'
            )
        )
    )
    THEN
        RAISE EXCEPTION
            'INVALID_BENCHMARK_RUN_TRANSITION: % -> %',
            OLD.status,
            NEW.status;
    END IF;
    -- HUMAN APPROVAL
    IF NEW.status = 'HUMAN_APPROVED' THEN
        IF NEW.human_approved IS NOT TRUE
           OR NEW.approved_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_APPROVAL_REQUIRED';
        END IF;
    END IF;
    -- RUNNING
    IF NEW.status = 'RUNNING' THEN
        IF NEW.human_approved IS NOT TRUE
           OR NEW.approved_at IS NULL
           OR NEW.started_at IS NULL
        THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_START_REQUIREMENTS_NOT_MET';
        END IF;
    END IF;
    -- COMPLETED
    IF NEW.status = 'COMPLETED' THEN
        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_COMPLETION_TIMESTAMP_REQUIRED';
        END IF;
        IF OLD.reserved_usd <> 0 THEN
            RAISE EXCEPTION
                'BENCHMARK_RUN_HAS_OPEN_RESERVATIONS';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_canonical_generation_output =====
CREATE OR REPLACE FUNCTION public.validate_canonical_generation_output()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.is_canonical = true then
        if new.qc_status <> 'PASS' then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_QC_PASS';
        end if;
        if new.status not in (
            'AVAILABLE',
            'CANONICAL'
        ) then
            raise exception
                'CANONICAL_OUTPUT_NOT_AVAILABLE';
        end if;
        if new.reviewed_at is null then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_REVIEW';
        end if;
        -- Enforced when an output becomes canonical. Outputs made
        -- canonical before this rule keep working (their evidence
        -- fields are immutable, so they could not be repaired).
        if (
               tg_op = 'INSERT'
               or old.is_canonical is not true
           )
           and (
               new.storage_path is null
               or btrim(new.storage_path) = ''
           )
        then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_DURABLE_STORAGE';
        end if;
        if new.canonical_at is null then
            new.canonical_at := now();
        end if;
        new.status := 'CANONICAL';
    else
        -- Prevent stale canonical timestamp.
        new.canonical_at := null;
        -- If canonical flag is removed before final lock phase,
        -- return CANONICAL status to AVAILABLE.
        if new.status = 'CANONICAL' then
            new.status := 'AVAILABLE';
        end if;
    end if;
    return new;
end;
$function$
;
-- ===== validate_canonical_shot_audio =====
CREATE OR REPLACE FUNCTION public.validate_canonical_shot_audio()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if new.is_canonical = true then
        if new.qc_status <> 'PASS' then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_QC_PASS';
        end if;
        if new.status <> 'APPROVED' then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_APPROVED_STATUS';
        end if;
        if new.duration_seconds is null then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_DURATION';
        end if;
        if new.reviewed_at is null then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_REVIEW';
        end if;
        if new.storage_path is null
           or btrim(new.storage_path) = ''
        then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_DURABLE_STORAGE';
        end if;
        if new.lip_sync_required = true
           and new.lip_sync_status not in (
               'READY',
               'PASS'
           )
        then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_LIP_SYNC_READY_OR_PASS';
        end if;
        if new.lip_sync_required = false
           and new.lip_sync_status not in (
               'NOT_REQUIRED',
               'PASS'
           )
        then
            raise exception
                'INVALID_NON_LIPSYNC_AUDIO_STATUS';
        end if;
        if new.canonical_at is null then
            new.canonical_at := now();
        end if;
    else
        new.canonical_at := null;
    end if;
    return new;
end;
$function$
;
-- ===== validate_episode_creative_profile =====
CREATE OR REPLACE FUNCTION public.validate_episode_creative_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_profile_mode text;
    v_profile_status text;
    v_locked_at timestamptz;
BEGIN
    -- -----------------------------------------------------
    -- Planning may begin before a profile is selected.
    -- Production lifecycle may not.
    -- -----------------------------------------------------
    IF NEW.creative_profile_id IS NULL THEN
        IF NEW.state NOT IN (
            'PLANNED',
            'BLOCKED',
            'CANCELLED'
        ) THEN
            RAISE EXCEPTION
                'EPISODE_CREATIVE_PROFILE_REQUIRED';
        END IF;
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Resolve canonical profile.
    -- -----------------------------------------------------
    SELECT
        p.production_mode,
        p.status,
        p.locked_at
    INTO
        v_profile_mode,
        v_profile_status,
        v_locked_at
    FROM public.production_creative_profiles p
    WHERE p.id = NEW.creative_profile_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_NOT_FOUND';
    END IF;
    -- -----------------------------------------------------
    -- Profile must match episode production mode.
    -- -----------------------------------------------------
    IF v_profile_mode IS DISTINCT FROM
       NEW.production_mode
    THEN
        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_MODE_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- Only canonical LOCKED profiles may be bound.
    -- -----------------------------------------------------
    IF v_profile_status <> 'LOCKED'
       OR v_locked_at IS NULL
    THEN
        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_NOT_LOCKED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_episode_state_transition =====
CREATE OR REPLACE FUNCTION public.validate_episode_state_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_open_shots integer;
    v_locked_shots integer;
begin
    -- ----------------------------------------------------
    -- human_approved may only become true through a
    -- recorded approval for this production version.
    -- ----------------------------------------------------
    if new.human_approved is true
       and old.human_approved is not true
    then
        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PRODUCTION'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception
                'EPISODE_HUMAN_APPROVAL_RECORD_REQUIRED';
        end if;
    end if;
    if new.state = old.state then
        return new;
    end if;
    if old.state in ('PUBLISHED', 'CANCELLED') then
        raise exception
            'EPISODE_STATE_IS_TERMINAL: %',
            old.state;
    end if;
    -- ----------------------------------------------------
    -- BLOCKED remembers where it came from and can only
    -- return there (or be cancelled).
    -- ----------------------------------------------------
    if new.state = 'BLOCKED' then
        new.blocked_from_state := old.state;
        return new;
    end if;
    if old.state = 'BLOCKED' then
        if new.state = 'CANCELLED' then
            new.blocked_from_state := null;
            return new;
        end if;
        -- Blocked before this migration: the origin is unknown, so
        -- the only way forward is back through approval.
        if old.blocked_from_state is null then
            if new.state <> 'PREPRODUCTION' then
                raise exception
                    'BLOCKED_EPISODE_MUST_RETURN_TO: PREPRODUCTION';
            end if;
            return new;
        end if;
        if new.state <> old.blocked_from_state then
            raise exception
                'BLOCKED_EPISODE_MUST_RETURN_TO: %',
                old.blocked_from_state;
        end if;
        new.blocked_from_state := null;
        return new;
    end if;
    if new.state = 'CANCELLED' then
        return new;
    end if;
    if not (
        (old.state = 'PLANNED'
            and new.state = 'PREPRODUCTION')
        or
        (old.state = 'PREPRODUCTION'
            and new.state in ('APPROVED', 'PLANNED'))
        or
        (old.state = 'APPROVED'
            and new.state in ('PRODUCTION', 'PREPRODUCTION'))
        or
        (old.state = 'PRODUCTION'
            and new.state = 'ASSEMBLY')
        or
        (old.state = 'ASSEMBLY'
            and new.state in ('FINAL_QC', 'PRODUCTION'))
        or
        (old.state = 'FINAL_QC'
            and new.state in ('READY_TO_PUBLISH', 'ASSEMBLY'))
        or
        (old.state = 'READY_TO_PUBLISH'
            and new.state in ('PUBLISHED', 'FINAL_QC'))
    ) then
        raise exception
            'INVALID_EPISODE_STATE_TRANSITION: % -> %',
            old.state,
            new.state;
    end if;
    if new.state = 'APPROVED'
       and new.human_approved is not true
    then
        raise exception 'EPISODE_HUMAN_APPROVAL_REQUIRED';
    end if;
    if new.state = 'PRODUCTION'
       and old.state = 'APPROVED'
       and new.production_authorized is not true
    then
        raise exception 'EPISODE_PRODUCTION_AUTHORIZATION_REQUIRED';
    end if;
    -- ----------------------------------------------------
    -- Assembly needs every shot of the current locked
    -- manifest to be finished: LOCKED or CANCELLED.
    -- ----------------------------------------------------
    if new.state = 'ASSEMBLY'
       and old.state = 'PRODUCTION'
    then
        select
            count(*) filter (
                where s.state not in ('LOCKED', 'CANCELLED')
            ),
            count(*) filter (
                where s.state = 'LOCKED'
            )
        into
            v_open_shots,
            v_locked_shots
        from public.production_manifests pm
        join public.production_manifest_shots pms
          on pms.manifest_id = pm.id
        join public.shots s
          on s.id = pms.shot_id
        where pm.episode_id = new.id
          and pm.production_version = new.production_version
          and pm.status = 'LOCKED';
        if coalesce(v_locked_shots, 0) = 0 then
            raise exception 'ASSEMBLY_REQUIRES_LOCKED_SHOTS';
        end if;
        if v_open_shots > 0 then
            raise exception
                'ASSEMBLY_BLOCKED_BY_OPEN_SHOTS: %',
                v_open_shots;
        end if;
    end if;
    -- ----------------------------------------------------
    -- Publishing needs a recorded human approval for this
    -- production version.
    -- ----------------------------------------------------
    if new.state = 'PUBLISHED' then
        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PUBLISH'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception 'PUBLISH_HUMAN_APPROVAL_REQUIRED';
        end if;
    end if;
    return new;
end;
$function$
;
-- ===== validate_generation_benchmark_evidence =====
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
;
-- ===== validate_generation_output_attempt =====
CREATE OR REPLACE FUNCTION public.validate_generation_output_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_attempt_shot_id uuid;
BEGIN
    SELECT a.shot_id
    INTO v_attempt_shot_id
    FROM public.attempts a
    WHERE a.id = NEW.attempt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_ATTEMPT_NOT_FOUND';
    END IF;
    IF v_attempt_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_SHOT_MISMATCH';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_manifest_pilot_shot =====
CREATE OR REPLACE FUNCTION public.validate_manifest_pilot_shot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_pilot_episode_id uuid;
    v_manifest_binding_count integer;
BEGIN
    IF NEW.pilot_shot_id IS NULL THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_REQUIRED';
    END IF;
    -- -----------------------------------------------------
    -- Pilot shot must belong to manifest episode.
    -- -----------------------------------------------------
    SELECT s.episode_id
    INTO v_pilot_episode_id
    FROM public.shots s
    WHERE s.id = NEW.pilot_shot_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_NOT_FOUND';
    END IF;
    IF v_pilot_episode_id IS DISTINCT FROM NEW.episode_id THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_EPISODE_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- Before HUMAN_APPROVED / LOCKED, pilot must already
    -- exist inside the manifest.
    -- -----------------------------------------------------
    IF NEW.status IN (
        'HUMAN_APPROVED',
        'LOCKED'
    )
    THEN
        SELECT COUNT(*)
        INTO v_manifest_binding_count
        FROM public.production_manifest_shots pms
        JOIN public.shot_specifications ss
          ON ss.id = pms.shot_specification_id
         AND ss.shot_id = pms.shot_id
        WHERE pms.manifest_id = NEW.id
          AND pms.shot_id = NEW.pilot_shot_id;
        IF v_manifest_binding_count <> 1 THEN
            RAISE EXCEPTION
                'MANIFEST_PILOT_SHOT_BINDING_REQUIRED';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_micro_short_manifest =====
CREATE OR REPLACE FUNCTION public.validate_micro_short_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_production_mode text;
    v_manifest_shot_count integer;
    v_invalid_episode_count integer;
    v_invalid_binding_count integer;
    v_invalid_spec_count integer;
    v_pilot_binding_count integer;
    v_total_duration numeric;
BEGIN
    -- Only enforce the final production envelope when
    -- manifest enters HUMAN_APPROVED or LOCKED.
    IF NEW.status NOT IN (
        'HUMAN_APPROVED',
        'LOCKED'
    ) THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Resolve production mode.
    -- -----------------------------------------------------
    SELECT e.production_mode
    INTO v_production_mode
    FROM public.episodes e
    WHERE e.id = NEW.episode_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_EPISODE_NOT_FOUND';
    END IF;
    -- SERIES_EPISODE is not governed by Micro Short policy.
    IF v_production_mode <> 'MICRO_SHORT' THEN
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- Inspect exact manifest contents.
    -- -----------------------------------------------------
    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE s.episode_id IS DISTINCT FROM NEW.episode_id
        ),
        COUNT(*) FILTER (
            WHERE ss.shot_id IS DISTINCT FROM pms.shot_id
        ),
        COUNT(*) FILTER (
            WHERE ss.id IS NULL
               OR ss.is_active IS NOT TRUE
               OR ss.status <> 'LOCKED'
               OR ss.locked_at IS NULL
               OR ss.aspect_ratio <> '9:16'
               OR ss.duration_seconds < 1
               OR ss.duration_seconds > 15
        ),
        COALESCE(
            SUM(ss.duration_seconds),
            0
        ),
        COUNT(*) FILTER (
            WHERE pms.shot_id = NEW.pilot_shot_id
        )
    INTO
        v_manifest_shot_count,
        v_invalid_episode_count,
        v_invalid_binding_count,
        v_invalid_spec_count,
        v_total_duration,
        v_pilot_binding_count
    FROM public.production_manifest_shots pms
    LEFT JOIN public.shots s
      ON s.id = pms.shot_id
    LEFT JOIN public.shot_specifications ss
      ON ss.id = pms.shot_specification_id
    WHERE pms.manifest_id = NEW.id;
    -- -----------------------------------------------------
    -- Manifest cannot be empty.
    -- -----------------------------------------------------
    IF v_manifest_shot_count < 1 THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_EMPTY';
    END IF;
    -- -----------------------------------------------------
    -- Every shot must belong to manifest episode.
    -- -----------------------------------------------------
    IF v_invalid_episode_count > 0 THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_EPISODE_MISMATCH';
    END IF;
    -- -----------------------------------------------------
    -- Exact shot/spec binding required.
    -- -----------------------------------------------------
    IF v_invalid_binding_count > 0 THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_SPEC_BINDING_INVALID';
    END IF;
    -- -----------------------------------------------------
    -- Production specs must be canonical locked vertical
    -- specifications.
    -- -----------------------------------------------------
    IF v_invalid_spec_count > 0 THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_SPEC_INVALID';
    END IF;
    -- -----------------------------------------------------
    -- Hard Micro Short duration envelope.
    -- Creative target remains 6–10 seconds.
    -- -----------------------------------------------------
    IF v_total_duration < 6
       OR v_total_duration > 15
    THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_DURATION_INVALID: %',
            v_total_duration;
    END IF;
    -- -----------------------------------------------------
    -- Pilot must be part of exact manifest.
    -- Existing pilot gate remains authoritative for QC.
    -- -----------------------------------------------------
    IF v_pilot_binding_count <> 1 THEN
        RAISE EXCEPTION
            'MICRO_SHORT_MANIFEST_PILOT_BINDING_REQUIRED';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_micro_short_production_mode =====
CREATE OR REPLACE FUNCTION public.validate_micro_short_production_mode()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_mode text;
    v_episode_id uuid;
    v_total_duration numeric;
    v_invalid_specs integer;
BEGIN
    -- -----------------------------------------------------
    -- EPISODE DIRECT VALIDATION
    -- -----------------------------------------------------
    IF TG_TABLE_NAME = 'episodes' THEN
        IF NEW.production_mode = 'MICRO_SHORT'
           AND NEW.state NOT IN (
               'PLANNED',
               'PREPRODUCTION',
               'BLOCKED',
               'CANCELLED'
           )
        THEN
            SELECT
                COALESCE(SUM(ss.duration_seconds), 0),
                COUNT(*) FILTER (
                    WHERE ss.aspect_ratio <> '9:16'
                       OR ss.duration_seconds < 1
                       OR ss.duration_seconds > 15
                )
            INTO
                v_total_duration,
                v_invalid_specs
            FROM public.shots s
            JOIN public.shot_specifications ss
              ON ss.shot_id = s.id
             AND ss.is_active = true
            WHERE s.episode_id = NEW.id;
            IF v_invalid_specs > 0 THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_FORMAT_INVALID';
            END IF;
            IF v_total_duration < 6
               OR v_total_duration > 15
            THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_TOTAL_DURATION_INVALID: %',
                    v_total_duration;
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    -- -----------------------------------------------------
    -- SHOT SPECIFICATION VALIDATION
    -- -----------------------------------------------------
    IF TG_TABLE_NAME = 'shot_specifications' THEN
        SELECT
            s.episode_id,
            e.production_mode
        INTO
            v_episode_id,
            v_mode
        FROM public.shots s
        JOIN public.episodes e
          ON e.id = s.episode_id
        WHERE s.id = NEW.shot_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SHOT_EPISODE_NOT_FOUND';
        END IF;
        IF v_mode = 'MICRO_SHORT'
           AND NEW.is_active = true
        THEN
            IF NEW.aspect_ratio <> '9:16' THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_REQUIRES_9_16';
            END IF;
            IF NEW.duration_seconds < 1
               OR NEW.duration_seconds > 15
            THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_SHOT_DURATION_INVALID';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_shot_audio_voice_identity =====
CREATE OR REPLACE FUNCTION public.validate_shot_audio_voice_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_voice_character_id uuid;
    v_voice_status text;
BEGIN
    SELECT
        vi.character_id,
        vi.status
    INTO
        v_voice_character_id,
        v_voice_status
    FROM public.voice_identities vi
    WHERE vi.id = NEW.voice_identity_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'AUDIO_VOICE_IDENTITY_NOT_FOUND';
    END IF;
    IF v_voice_status <> 'LOCKED' THEN
        RAISE EXCEPTION
            'AUDIO_VOICE_IDENTITY_MUST_BE_LOCKED: %',
            v_voice_status;
    END IF;
    IF v_voice_character_id <> NEW.character_id THEN
        RAISE EXCEPTION
            'AUDIO_VOICE_CHARACTER_MISMATCH';
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_shot_reference_asset =====
CREATE OR REPLACE FUNCTION public.validate_shot_reference_asset()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_asset_status text;
BEGIN
    SELECT ar.status
    INTO v_asset_status
    FROM public.asset_registry ar
    WHERE ar.id = NEW.asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'REFERENCE_ASSET_NOT_FOUND';
    END IF;
    IF v_asset_status <> 'LOCKED' THEN
        RAISE EXCEPTION
            'REFERENCE_ASSET_MUST_BE_LOCKED: %',
            v_asset_status;
    END IF;
    RETURN NEW;
END;
$function$
;
-- ===== validate_shot_state_transition =====
CREATE OR REPLACE FUNCTION public.validate_shot_state_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_human_resolution boolean;
begin
    -- No state change = allowed.
    if new.state = old.state then
        return new;
    end if;
    v_human_resolution :=
        coalesce(
            current_setting('m417.human_resolution', true),
            'off'
        ) = 'on';
    -- --------------------------------------------------------
    -- LOCKED IS TERMINAL
    -- --------------------------------------------------------
    if old.state = 'LOCKED' then
        raise exception 'LOCKED_SHOT_IS_IMMUTABLE';
    end if;
    -- --------------------------------------------------------
    -- CANCELLED IS TERMINAL
    -- --------------------------------------------------------
    if old.state = 'CANCELLED' then
        raise exception 'CANCELLED_SHOT_IS_TERMINAL';
    end if;
    -- --------------------------------------------------------
    -- ESCALATED CANNOT RETURN TO AUTOMATIC GENERATION
    -- --------------------------------------------------------
    if old.state = 'ESCALATED'
       and new.state in (
           'QUEUED',
           'GENERATING',
           'GENERATED',
           'QC_PENDING',
           'RETRY_REQUIRED'
       )
    then
        raise exception 'ESCALATED_SHOT_REQUIRES_HUMAN_INTERVENTION';
    end if;
    -- --------------------------------------------------------
    -- ALLOWED TRANSITIONS
    -- --------------------------------------------------------
    if not (
        -- Planning / storyboard
        (old.state = 'PLANNED'
            and new.state in (
                'STORYBOARD_PENDING',
                'CANCELLED'
            ))
        or
        (old.state = 'STORYBOARD_PENDING'
            and new.state in (
                'STORYBOARD_APPROVED',
                'CANCELLED'
            ))
        or
        (old.state = 'STORYBOARD_APPROVED'
            and new.state in (
                'AUDIO_READY',
                'QUEUED',
                'CANCELLED'
            ))
        or
        -- Audio can be skipped for non-dialogue shots.
        (old.state = 'AUDIO_READY'
            and new.state in (
                'QUEUED',
                'CANCELLED'
            ))
        or
        -- Generation
        (old.state = 'QUEUED'
            and new.state in (
                'GENERATING',
                'FAILED_TECHNICAL',
                'CANCELLED'
            ))
        or
        (old.state = 'GENERATING'
            and new.state in (
                'GENERATED',
                'FAILED_TECHNICAL',
                'RETRY_REQUIRED',
                'CANCELLED'
            ))
        or
        -- QC
        (old.state = 'GENERATED'
            and new.state in (
                'QC_PENDING',
                'FAILED_TECHNICAL'
            ))
        or
        (old.state = 'QC_PENDING'
            and new.state in (
                'LOCKED',
                'RETRY_REQUIRED',
                'FAILED_TECHNICAL'
            ))
        or
        -- Retry
        (old.state = 'RETRY_REQUIRED'
            and new.state in (
                'QUEUED',
                'ESCALATED',
                'CANCELLED'
            ))
        or
        -- Technical recovery
        (old.state = 'FAILED_TECHNICAL'
            and new.state in (
                'RETRY_REQUIRED',
                'ESCALATED',
                'CANCELLED'
            ))
        or
        -- Human resolution of an escalated shot.
        (old.state = 'ESCALATED'
            and new.state = 'CANCELLED')
        or
        (old.state = 'ESCALATED'
            and new.state = 'LOCKED'
            and v_human_resolution)
    ) then
        raise exception
            'INVALID_SHOT_STATE_TRANSITION: % -> %',
            old.state,
            new.state;
    end if;
    -- --------------------------------------------------------
    -- AUTOMATIC LOCK TIMESTAMP
    -- --------------------------------------------------------
    if new.state = 'LOCKED' then
        if new.locked_at is null then
            new.locked_at := now();
        end if;
    else
        -- A non-LOCKED shot must not carry a lock timestamp.
        new.locked_at := null;
    end if;
    return new;
end;
$function$
;
-- ===== validate_storyboard_asset =====
CREATE OR REPLACE FUNCTION public.validate_storyboard_asset()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_asset_status text;
BEGIN
    IF NEW.storyboard_asset_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT ar.status
    INTO v_asset_status
    FROM public.asset_registry ar
    WHERE ar.id = NEW.storyboard_asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'STORYBOARD_ASSET_NOT_FOUND';
    END IF;
    IF v_asset_status <> 'LOCKED' THEN
        RAISE EXCEPTION
            'STORYBOARD_ASSET_MUST_BE_LOCKED: %',
            v_asset_status;
    END IF;
    RETURN NEW;
END;
$function$
;
