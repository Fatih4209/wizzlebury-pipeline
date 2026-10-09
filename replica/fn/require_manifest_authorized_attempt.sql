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
