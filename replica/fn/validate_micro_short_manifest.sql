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
