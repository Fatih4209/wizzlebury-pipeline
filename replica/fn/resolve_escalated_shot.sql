CREATE OR REPLACE FUNCTION public.resolve_escalated_shot(p_token text, p_resolution text, p_decided_by text, p_note text DEFAULT NULL::text, p_output_id uuid DEFAULT NULL::uuid, p_channel text DEFAULT NULL::text)
 RETURNS TABLE(shot_id uuid, resolution text, shot_state text, canonical_output_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
    v_shot_id uuid;
    v_state text;

    v_out_shot_id uuid;
    v_out_attempt_id uuid;
    v_out_storage_path text;
    v_out_qc_status text;
    v_out_qc_score numeric;
    v_attempt_status text;
begin

    if p_resolution not in ('ACCEPT_OUTPUT', 'CANCEL_SHOT') then
        raise exception 'INVALID_ESCALATION_RESOLUTION';
    end if;

    if p_resolution = 'ACCEPT_OUTPUT'
       and p_output_id is null
    then
        raise exception 'OUTPUT_ID_REQUIRED';
    end if;


    v_row := public.consume_approval_token(
        p_token,
        'SHOT_ESCALATION',
        'APPROVED',
        p_decided_by,
        p_channel,
        coalesce(p_note, '') || ' [' || p_resolution || ']'
    );

    v_shot_id := v_row.scope_id;


    select s.state
    into v_state
    from public.shots s
    where s.id = v_shot_id
    for update;

    if not found then
        raise exception 'SHOT_NOT_FOUND';
    end if;

    if v_state <> 'ESCALATED' then
        raise exception
            'SHOT_NOT_ESCALATED: %',
            v_state;
    end if;


    if p_resolution = 'CANCEL_SHOT' then

        update public.shots
        set state = 'CANCELLED'
        where id = v_shot_id;

        insert into public.events (
            event_type, shot_id, severity, source, message, metadata
        )
        values (
            'ESCALATED_SHOT_CANCELLED',
            v_shot_id,
            'WARNING',
            'HUMAN_APPROVAL',
            'Escalated shot cancelled by ' || p_decided_by,
            jsonb_build_object(
                'request_id', v_row.id,
                'decided_by', p_decided_by,
                'note', p_note
            )
        );

        return query
        select v_shot_id, p_resolution, 'CANCELLED'::text, null::uuid;
        return;

    end if;


    -- ACCEPT_OUTPUT
    select
        go.shot_id,
        go.attempt_id,
        go.storage_path,
        go.qc_status,
        go.qc_score
    into
        v_out_shot_id,
        v_out_attempt_id,
        v_out_storage_path,
        v_out_qc_status,
        v_out_qc_score
    from public.generation_outputs go
    where go.id = p_output_id
    for update;

    if not found then
        raise exception 'GENERATION_OUTPUT_NOT_FOUND';
    end if;

    if v_out_shot_id <> v_shot_id then
        raise exception 'GENERATION_OUTPUT_SHOT_MISMATCH';
    end if;

    if v_out_storage_path is null
       or btrim(v_out_storage_path) = ''
    then
        raise exception 'ACCEPTED_OUTPUT_REQUIRES_DURABLE_STORAGE';
    end if;

    select a.status
    into v_attempt_status
    from public.attempts a
    where a.id = v_out_attempt_id;

    if v_attempt_status is distinct from 'SUCCEEDED' then
        raise exception
            'ACCEPTED_OUTPUT_REQUIRES_SUCCEEDED_ATTEMPT: %',
            coalesce(v_attempt_status, 'NULL');
    end if;


    update public.generation_outputs go
    set
        qc_status = 'PASS',
        status = 'AVAILABLE',
        is_canonical = true,
        reviewed_at = now(),
        qc_details =
            coalesce(go.qc_details, '{}'::jsonb)
            || jsonb_build_object(
                'human_override',
                jsonb_build_object(
                    'request_id', v_row.id,
                    'decided_by', p_decided_by,
                    'note', p_note,
                    'previous_qc_status', v_out_qc_status,
                    'previous_qc_score', v_out_qc_score,
                    'decided_at', now()
                )
            )
    where go.id = p_output_id;


    perform set_config('m417.human_resolution', 'on', true);

    update public.shots
    set state = 'LOCKED'
    where id = v_shot_id;

    perform set_config('m417.human_resolution', 'off', true);


    insert into public.events (
        event_type, shot_id, attempt_id, severity, source, message, metadata
    )
    values (
        'ESCALATED_SHOT_OUTPUT_ACCEPTED',
        v_shot_id,
        v_out_attempt_id,
        'WARNING',
        'HUMAN_APPROVAL',
        'Rejected output accepted by ' || p_decided_by,
        jsonb_build_object(
            'request_id', v_row.id,
            'output_id', p_output_id,
            'decided_by', p_decided_by,
            'note', p_note,
            'previous_qc_status', v_out_qc_status,
            'previous_qc_score', v_out_qc_score
        )
    );


    return query
    select v_shot_id, p_resolution, 'LOCKED'::text, p_output_id;

end;
$function$
