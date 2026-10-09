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
