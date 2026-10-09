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
