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
