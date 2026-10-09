-- ---------------------------------------------------------------------
-- 4. Existing rules, adjusted
--
-- Production is authorised by the Head Director decision (step 14), not
-- by a human approval. Storyboards are required only while the
-- storyboard_required flag is true. Everything else in these functions
-- is unchanged from 001.
-- ---------------------------------------------------------------------

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

      AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)

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
$function$;

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
       AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)
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

$function$;

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

      AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)

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
$function$;

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

    -- Storyboards are a switchable requirement. A missing flag
    -- means the requirement is on.
    IF COALESCE(
        (
            SELECT sf.value
            FROM public.system_flags sf
            WHERE sf.key = 'storyboard_required'
        ),
        true
    ) IS NOT TRUE
    THEN
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
$function$;

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


    -- ----------------------------------------------------
    -- director_approval_id may only point at an APPROVE
    -- decision made for this episode and production version.
    -- ----------------------------------------------------
    if new.director_approval_id is distinct from old.director_approval_id then
        if new.director_approval_id is null
           or not exists (
               select 1
               from public.director_decisions dd
               where dd.id = new.director_approval_id
                 and dd.episode_id = new.id
                 and dd.production_version = new.production_version
                 and dd.stage = 'PRODUCTION'
                 and dd.decision = 'APPROVE'
           )
        then
            raise exception 'EPISODE_DIRECTOR_APPROVAL_INVALID';
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
       and new.director_approval_id is null
    then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_REQUIRED';
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
$function$;

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

    -- Production is authorised by the Head Director decision.
    if p_scope_type = 'EPISODE_PRODUCTION' then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_RETIRED';
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
$function$;

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

        -- A paid, human-approved benchmark comes first. Without one,
        -- an owner pilot approval stands in for it: the first shot of
        -- the first episode is then the model's trial (pilot gate, QC
        -- and the two-attempt limit still apply).
        SELECT ev.*

        FROM (

            SELECT
                b1.id,
                b1.benchmark_status,
                b1.approved_at,
                b1.continuity_score,
                b1.motion_score,
                b1.face_score,
                b1.anatomy_score,
                b1.prompt_adherence_score,
                b1.camera_score,
                b1.expression_score,
                b1.lip_sync_score,
                b1.pass_rate,
                b1.average_generation_seconds,
                0 AS evidence_rank,
                b1.benchmark_version AS evidence_version

            FROM public.generation_model_benchmarks b1

            WHERE b1.model_id = gpm.model_id
              AND b1.benchmark_status = 'HUMAN_APPROVED'
              AND b1.approved_at IS NOT NULL

            UNION ALL

            SELECT
                pa.id,
                'HUMAN_APPROVED'::text,
                pa.approved_at,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_pass_rate,
                pa.assumed_generation_seconds,
                1 AS evidence_rank,
                0 AS evidence_version

            FROM public.generation_model_pilot_approvals pa

            WHERE pa.model_id = gpm.model_id
              AND pa.revoked_at IS NULL

        ) ev

        ORDER BY
            ev.evidence_rank,
            ev.evidence_version DESC

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
$function$;
