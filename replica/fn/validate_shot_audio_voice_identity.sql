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
