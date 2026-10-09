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
