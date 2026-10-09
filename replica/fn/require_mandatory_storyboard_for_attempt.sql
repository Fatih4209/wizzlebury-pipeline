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
