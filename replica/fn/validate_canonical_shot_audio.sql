CREATE OR REPLACE FUNCTION public.validate_canonical_shot_audio()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

begin

    if new.is_canonical = true then

        if new.qc_status <> 'PASS' then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_QC_PASS';
        end if;


        if new.status <> 'APPROVED' then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_APPROVED_STATUS';
        end if;


        if new.duration_seconds is null then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_DURATION';
        end if;


        if new.reviewed_at is null then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_REVIEW';
        end if;


        if new.storage_path is null
           or btrim(new.storage_path) = ''
        then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_DURABLE_STORAGE';
        end if;


        if new.lip_sync_required = true
           and new.lip_sync_status not in (
               'READY',
               'PASS'
           )
        then
            raise exception
                'CANONICAL_AUDIO_REQUIRES_LIP_SYNC_READY_OR_PASS';
        end if;


        if new.lip_sync_required = false
           and new.lip_sync_status not in (
               'NOT_REQUIRED',
               'PASS'
           )
        then
            raise exception
                'INVALID_NON_LIPSYNC_AUDIO_STATUS';
        end if;


        if new.canonical_at is null then
            new.canonical_at := now();
        end if;


    else

        new.canonical_at := null;

    end if;


    return new;

end;
$function$
