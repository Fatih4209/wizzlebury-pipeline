CREATE OR REPLACE FUNCTION public.sync_shot_state_from_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_state text;
begin

    if new.status = old.status then
        return new;
    end if;


    select s.state
    into v_state
    from public.shots s
    where s.id = new.shot_id
    for update;

    if not found then
        return new;
    end if;


    -- -------------------------------------------------
    -- Provider accepted / is working.
    -- -------------------------------------------------
    if new.status in ('SUBMITTED', 'GENERATING') then

        if v_state = 'QUEUED' then
            update public.shots
            set state = 'GENERATING'
            where id = new.shot_id;
        end if;

        return new;

    end if;


    -- -------------------------------------------------
    -- Provider produced a result.
    -- -------------------------------------------------
    if new.status = 'SUCCEEDED' then

        if v_state = 'QUEUED' then
            update public.shots
            set state = 'GENERATING'
            where id = new.shot_id;
            v_state := 'GENERATING';
        end if;

        if v_state = 'GENERATING' then
            update public.shots
            set state = 'GENERATED'
            where id = new.shot_id;
            v_state := 'GENERATED';
        end if;

        -- Output may have been registered before settlement.
        if v_state = 'GENERATED'
           and exists (
               select 1
               from public.generation_outputs go
               where go.attempt_id = new.id
                 and go.qc_status in ('PENDING', 'IN_REVIEW')
           )
        then
            update public.shots
            set state = 'QC_PENDING'
            where id = new.shot_id;
        end if;

        return new;

    end if;


    -- -------------------------------------------------
    -- Technical failure / cancellation.
    -- Attempt 1 -> one retry. Attempt 2 -> human.
    -- -------------------------------------------------
    if new.status in ('FAILED', 'CANCELLED') then

        if v_state in ('QUEUED', 'GENERATING') then

            update public.shots
            set state = 'FAILED_TECHNICAL'
            where id = new.shot_id;

            update public.shots
            set state =
                case
                    when new.attempt_no = 1
                    then 'RETRY_REQUIRED'
                    else 'ESCALATED'
                end
            where id = new.shot_id;

        end if;

        return new;

    end if;


    return new;

end;
$function$
