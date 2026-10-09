CREATE OR REPLACE FUNCTION public.require_complete_approved_benchmark()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if new.benchmark_status = 'HUMAN_APPROVED'
       and (
            tg_op = 'INSERT'
            or old.benchmark_status is distinct from 'HUMAN_APPROVED'
       )
       and (
            new.continuity_score is null
            or new.motion_score is null
            or new.face_score is null
            or new.anatomy_score is null
            or new.prompt_adherence_score is null
            or new.camera_score is null
            or new.expression_score is null
            or new.lip_sync_score is null
            or new.pass_rate is null
            or new.average_generation_seconds is null
       )
    then
        raise exception
            'HUMAN_APPROVED_BENCHMARK_REQUIRES_COMPLETE_SCORES';
    end if;

    return new;

end;
$function$
