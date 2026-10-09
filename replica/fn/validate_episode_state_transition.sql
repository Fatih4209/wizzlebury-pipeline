CREATE OR REPLACE FUNCTION public.validate_episode_state_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_open_shots integer;
    v_locked_shots integer;
begin

    -- ----------------------------------------------------
    -- human_approved may only become true through a
    -- recorded approval for this production version.
    -- ----------------------------------------------------
    if new.human_approved is true
       and old.human_approved is not true
    then

        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PRODUCTION'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception
                'EPISODE_HUMAN_APPROVAL_RECORD_REQUIRED';
        end if;

    end if;


    if new.state = old.state then
        return new;
    end if;


    if old.state in ('PUBLISHED', 'CANCELLED') then
        raise exception
            'EPISODE_STATE_IS_TERMINAL: %',
            old.state;
    end if;


    -- ----------------------------------------------------
    -- BLOCKED remembers where it came from and can only
    -- return there (or be cancelled).
    -- ----------------------------------------------------
    if new.state = 'BLOCKED' then
        new.blocked_from_state := old.state;
        return new;
    end if;

    if old.state = 'BLOCKED' then

        if new.state = 'CANCELLED' then
            new.blocked_from_state := null;
            return new;
        end if;

        -- Blocked before this migration: the origin is unknown, so
        -- the only way forward is back through approval.
        if old.blocked_from_state is null then

            if new.state <> 'PREPRODUCTION' then
                raise exception
                    'BLOCKED_EPISODE_MUST_RETURN_TO: PREPRODUCTION';
            end if;

            return new;

        end if;

        if new.state <> old.blocked_from_state then
            raise exception
                'BLOCKED_EPISODE_MUST_RETURN_TO: %',
                old.blocked_from_state;
        end if;

        new.blocked_from_state := null;
        return new;

    end if;


    if new.state = 'CANCELLED' then
        return new;
    end if;


    if not (

        (old.state = 'PLANNED'
            and new.state = 'PREPRODUCTION')

        or

        (old.state = 'PREPRODUCTION'
            and new.state in ('APPROVED', 'PLANNED'))

        or

        (old.state = 'APPROVED'
            and new.state in ('PRODUCTION', 'PREPRODUCTION'))

        or

        (old.state = 'PRODUCTION'
            and new.state = 'ASSEMBLY')

        or

        (old.state = 'ASSEMBLY'
            and new.state in ('FINAL_QC', 'PRODUCTION'))

        or

        (old.state = 'FINAL_QC'
            and new.state in ('READY_TO_PUBLISH', 'ASSEMBLY'))

        or

        (old.state = 'READY_TO_PUBLISH'
            and new.state in ('PUBLISHED', 'FINAL_QC'))

    ) then

        raise exception
            'INVALID_EPISODE_STATE_TRANSITION: % -> %',
            old.state,
            new.state;

    end if;


    if new.state = 'APPROVED'
       and new.human_approved is not true
    then
        raise exception 'EPISODE_HUMAN_APPROVAL_REQUIRED';
    end if;


    if new.state = 'PRODUCTION'
       and old.state = 'APPROVED'
       and new.production_authorized is not true
    then
        raise exception 'EPISODE_PRODUCTION_AUTHORIZATION_REQUIRED';
    end if;


    -- ----------------------------------------------------
    -- Assembly needs every shot of the current locked
    -- manifest to be finished: LOCKED or CANCELLED.
    -- ----------------------------------------------------
    if new.state = 'ASSEMBLY'
       and old.state = 'PRODUCTION'
    then

        select
            count(*) filter (
                where s.state not in ('LOCKED', 'CANCELLED')
            ),
            count(*) filter (
                where s.state = 'LOCKED'
            )
        into
            v_open_shots,
            v_locked_shots
        from public.production_manifests pm
        join public.production_manifest_shots pms
          on pms.manifest_id = pm.id
        join public.shots s
          on s.id = pms.shot_id
        where pm.episode_id = new.id
          and pm.production_version = new.production_version
          and pm.status = 'LOCKED';

        if coalesce(v_locked_shots, 0) = 0 then
            raise exception 'ASSEMBLY_REQUIRES_LOCKED_SHOTS';
        end if;

        if v_open_shots > 0 then
            raise exception
                'ASSEMBLY_BLOCKED_BY_OPEN_SHOTS: %',
                v_open_shots;
        end if;

    end if;


    -- ----------------------------------------------------
    -- Publishing needs a recorded human approval for this
    -- production version.
    -- ----------------------------------------------------
    if new.state = 'PUBLISHED' then

        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PUBLISH'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception 'PUBLISH_HUMAN_APPROVAL_REQUIRED';
        end if;

    end if;


    return new;

end;
$function$
