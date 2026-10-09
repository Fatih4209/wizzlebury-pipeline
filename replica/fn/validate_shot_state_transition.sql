CREATE OR REPLACE FUNCTION public.validate_shot_state_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_human_resolution boolean;
begin

    -- No state change = allowed.
    if new.state = old.state then
        return new;
    end if;


    v_human_resolution :=
        coalesce(
            current_setting('m417.human_resolution', true),
            'off'
        ) = 'on';


    -- --------------------------------------------------------
    -- LOCKED IS TERMINAL
    -- --------------------------------------------------------

    if old.state = 'LOCKED' then
        raise exception 'LOCKED_SHOT_IS_IMMUTABLE';
    end if;


    -- --------------------------------------------------------
    -- CANCELLED IS TERMINAL
    -- --------------------------------------------------------

    if old.state = 'CANCELLED' then
        raise exception 'CANCELLED_SHOT_IS_TERMINAL';
    end if;


    -- --------------------------------------------------------
    -- ESCALATED CANNOT RETURN TO AUTOMATIC GENERATION
    -- --------------------------------------------------------

    if old.state = 'ESCALATED'
       and new.state in (
           'QUEUED',
           'GENERATING',
           'GENERATED',
           'QC_PENDING',
           'RETRY_REQUIRED'
       )
    then
        raise exception 'ESCALATED_SHOT_REQUIRES_HUMAN_INTERVENTION';
    end if;


    -- --------------------------------------------------------
    -- ALLOWED TRANSITIONS
    -- --------------------------------------------------------

    if not (

        -- Planning / storyboard
        (old.state = 'PLANNED'
            and new.state in (
                'STORYBOARD_PENDING',
                'CANCELLED'
            ))

        or

        (old.state = 'STORYBOARD_PENDING'
            and new.state in (
                'STORYBOARD_APPROVED',
                'CANCELLED'
            ))

        or

        (old.state = 'STORYBOARD_APPROVED'
            and new.state in (
                'AUDIO_READY',
                'QUEUED',
                'CANCELLED'
            ))

        or

        -- Audio can be skipped for non-dialogue shots.
        (old.state = 'AUDIO_READY'
            and new.state in (
                'QUEUED',
                'CANCELLED'
            ))

        or

        -- Generation
        (old.state = 'QUEUED'
            and new.state in (
                'GENERATING',
                'FAILED_TECHNICAL',
                'CANCELLED'
            ))

        or

        (old.state = 'GENERATING'
            and new.state in (
                'GENERATED',
                'FAILED_TECHNICAL',
                'RETRY_REQUIRED',
                'CANCELLED'
            ))

        or

        -- QC
        (old.state = 'GENERATED'
            and new.state in (
                'QC_PENDING',
                'FAILED_TECHNICAL'
            ))

        or

        (old.state = 'QC_PENDING'
            and new.state in (
                'LOCKED',
                'RETRY_REQUIRED',
                'FAILED_TECHNICAL'
            ))

        or

        -- Retry
        (old.state = 'RETRY_REQUIRED'
            and new.state in (
                'QUEUED',
                'ESCALATED',
                'CANCELLED'
            ))

        or

        -- Technical recovery
        (old.state = 'FAILED_TECHNICAL'
            and new.state in (
                'RETRY_REQUIRED',
                'ESCALATED',
                'CANCELLED'
            ))

        or

        -- Human resolution of an escalated shot.
        (old.state = 'ESCALATED'
            and new.state = 'CANCELLED')

        or

        (old.state = 'ESCALATED'
            and new.state = 'LOCKED'
            and v_human_resolution)

    ) then

        raise exception
            'INVALID_SHOT_STATE_TRANSITION: % -> %',
            old.state,
            new.state;

    end if;


    -- --------------------------------------------------------
    -- AUTOMATIC LOCK TIMESTAMP
    -- --------------------------------------------------------

    if new.state = 'LOCKED' then

        if new.locked_at is null then
            new.locked_at := now();
        end if;

    else

        -- A non-LOCKED shot must not carry a lock timestamp.
        new.locked_at := null;

    end if;


    return new;

end;
$function$
