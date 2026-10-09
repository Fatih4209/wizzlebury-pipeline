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
