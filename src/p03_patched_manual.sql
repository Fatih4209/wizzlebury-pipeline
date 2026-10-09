
CREATE OR REPLACE FUNCTION public.authorize_episode_production(p_episode_id uuid)
 RETURNS TABLE(episode_id uuid, production_authorized boolean, authorized_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_human_approved boolean;
    v_director_approval_id uuid;
    v_authorized_at timestamptz;
begin
    select
        e.state,
        e.human_approved,
        e.director_approval_id
    into
        v_state,
        v_human_approved,
        v_director_approval_id
    from public.episodes e
    where e.id = p_episode_id
    for update;
    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;
    if v_human_approved is not true
       and v_director_approval_id is null
    then
        raise exception 'PRODUCTION_APPROVAL_REQUIRED';
    end if;
    if v_state <> 'APPROVED' then
        raise exception 'EPISODE_NOT_APPROVED';
    end if;
    v_authorized_at := now();
    update public.episodes
    set
        production_authorized = true,
        authorized_at = v_authorized_at,
        state = 'PRODUCTION'
    where id = p_episode_id;
    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message
    )
    values (
        'PRODUCTION_AUTHORIZED',
        p_episode_id,
        'INFO',
        'CONTROL_PLANE',
        'Episode production authorized'
    );
    return query
    select
        p_episode_id,
        true,
        v_authorized_at;
end;
$function$;

-- A specification may be locked from HUMAN_APPROVED (as before) or,
-- inside commit_production_package, straight from DRAFT on the
-- strength of the director decision (m417.director_lock marker).
CREATE OR REPLACE FUNCTION public.protect_shot_specification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_supersession boolean;
    v_director_lock boolean;
begin
    v_supersession :=
        coalesce(
            current_setting('m417.spec_supersession', true),
            'off'
        ) = 'on';
    v_director_lock :=
        coalesce(
            current_setting('m417.director_lock', true),
            'off'
        ) = 'on';
    if old.status = 'LOCKED' then
        if v_supersession then
            -- Retire the old active specification.
            if new.status = 'SUPERSEDED'
               and old.is_active = true
               and new.is_active = false
               and (to_jsonb(new) - 'status' - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'status' - 'is_active' - 'updated_at')
            then
                return new;
            end if;
            -- Activate the new locked specification.
            if new.status = 'LOCKED'
               and old.is_active = false
               and new.is_active = true
               and (to_jsonb(new) - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'is_active' - 'updated_at')
            then
                return new;
            end if;
        end if;
        raise exception
            'LOCKED_SHOT_SPECIFICATION_IS_IMMUTABLE';
    end if;
    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
       and not (v_director_lock and old.status = 'DRAFT')
    then
        raise exception
            'SHOT_SPEC_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;
    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;
    return new;
end;
$function$;

-- A manifest may be locked by human approval (as before) or by the
-- director decision it is bound to.
CREATE OR REPLACE FUNCTION public.protect_production_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_director_lock boolean;
BEGIN
    IF OLD.status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_IS_IMMUTABLE';
    END IF;
    v_director_lock :=
        COALESCE(
            current_setting('m417.director_lock', true),
            'off'
        ) = 'on'
        AND OLD.status = 'DRAFT'
        AND NEW.director_approval_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM public.director_decisions dd
            WHERE dd.id = NEW.director_approval_id
              AND dd.episode_id = NEW.episode_id
              AND dd.production_version = NEW.production_version
              AND dd.stage = 'PRODUCTION'
              AND dd.decision = 'APPROVE'
        );
    IF NEW.director_approval_id IS DISTINCT FROM OLD.director_approval_id
       AND v_director_lock IS NOT TRUE
       AND NEW.status <> 'DRAFT'
    THEN
        RAISE EXCEPTION
            'MANIFEST_DIRECTOR_APPROVAL_INVALID';
    END IF;
    IF NEW.status = 'LOCKED'
       AND OLD.status <> 'HUMAN_APPROVED'
       AND v_director_lock IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.human_approved IS NOT TRUE
       AND v_director_lock IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_HUMAN_APPROVAL_REQUIRED';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN
        NEW.locked_at := now();
    END IF;
    RETURN NEW;
END;
$function$;

-- Decisions are a record: never edited, never deleted.
create or replace function m417_internal.append_only()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
begin
    raise exception '%_IS_APPEND_ONLY', upper(tg_table_name);
end;
$function$;

drop trigger if exists trg_director_decisions_append_only on public.director_decisions;
create trigger trg_director_decisions_append_only
    before update or delete on public.director_decisions
    for each row execute function m417_internal.append_only();

drop trigger if exists trg_policy_checks_append_only on public.policy_checks;
create trigger trg_policy_checks_append_only
    before update or delete on public.policy_checks
    for each row execute function m417_internal.append_only();

drop trigger if exists trg_job_step_log_append_only on public.job_step_log;
create trigger trg_job_step_log_append_only
    before update or delete on public.job_step_log
    for each row execute function m417_internal.append_only();
