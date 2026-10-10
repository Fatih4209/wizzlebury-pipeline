-- =====================================================================
-- M417 / WIZZLEBURY  -  014 storyboard rules
--
-- Run after 013. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. A clip that starts from an approved frame may be sent to the video
--    model with that frame alone (start_frame_reference_images = 0). The
--    character reference images next to the frame made the model put a
--    second copy of the character into the scene.
-- 2. SHOT_PACKAGE version 4: everybody in the scene is in shot 1, and
--    every first frame continues from the end of the shot before.
-- =====================================================================
begin;

insert into public.system_settings (key, value_numeric, description) values
    ('start_frame_reference_images', 3, 'Character reference images sent to the video model besides an approved start frame. 0 sends the start frame alone.')
on conflict (key) do nothing;

create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_base jsonb := m417_internal.build_provider_request_base(p_attempt_id)::jsonb;
    v_shot_id uuid;
    v_spec public.shot_specifications;
    v_key public.shot_keyframes;
    v_plan jsonb;
    v_meta jsonb;
    v_max integer;
    v_refs jsonb;
    v_names text;
    v_notes text;
    v_beats text;
    v_speaker text;
    v_fix text;
    v_window numeric;
    v_prompt text;
    v_tail text;
    v_images jsonb;
begin
    -- M417-LAYER-012
    if v_base ->> 'task_type' is distinct from 'omni_video_generation' then
        return v_base::text;
    end if;
    select a.shot_id, gm.capability_metadata into v_shot_id, v_meta
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.generation_models gm on gm.id = grd.selected_model_id
    where a.id = p_attempt_id;
    select k.* into v_key
    from public.shot_keyframes k
    where k.shot_id = v_shot_id and k.status = 'APPROVED';
    if not found then
        return v_base::text;
    end if;
    select ss.* into v_spec
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where a.id = p_attempt_id;
    v_plan := coalesce(m417_internal.shot_plan(v_shot_id), '{}'::jsonb);

    -- The start frame is image 1; the characters follow.
    v_max := least(greatest(coalesce(nullif(v_meta ->> 'max_reference_images', '')::integer, 4) - 1, 0),
                   greatest(m417_internal.num('start_frame_reference_images', 3)::integer, 0));
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.ord + 1, 'name', x.value ->> 'name', 'url', x.value ->> 'url', 'note', x.value ->> 'note')
               order by x.ord), '[]'::jsonb)
    into v_refs
    from (
        select r.value, row_number() over (order by (r.value ->> 'n')::integer) as ord
        from jsonb_array_elements(m417_internal.shot_reference_images(v_spec.id, 8)) r(value)
        where r.value ->> 'role' = 'CHARACTER'
    ) x
    where x.ord <= v_max;
    select string_agg('@image_' || (r.value ->> 'n') || ' is ' || (r.value ->> 'name'), ', '
                      order by (r.value ->> 'n')::integer),
           string_agg(r.value ->> 'note', ' ' order by (r.value ->> 'n')::integer)
               filter (where r.value ->> 'note' is not null)
    into v_names, v_notes
    from jsonb_array_elements(v_refs) r(value);

    select string_agg(
               'at ' || to_char(coalesce(m417_internal.safe_numeric(b.value ->> 'at'), 0), 'FM990.0') || ' s '
               || rtrim(left(btrim(coalesce(b.value ->> 'what', '')), 160), '. '),
               '; ' order by b.ord)
    into v_beats
    from jsonb_array_elements(
        case when jsonb_typeof(v_spec.beats) = 'array' then v_spec.beats else '[]'::jsonb end
    ) with ordinality as b(value, ord);
    v_window := ceil((coalesce(v_spec.edit_seconds, v_spec.duration_seconds)
                      + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2;

    select c.name into v_speaker
    from public.shot_audio_productions sap
    join public.characters c on c.id = sap.character_id
    where sap.shot_specification_id = v_spec.id
    order by sap.audio_order
    limit 1;

    select ' Correction: an earlier take of this shot was rejected because: '
           || rtrim(left(regexp_replace(btrim(go.qc_notes), '[[:space:]]+', ' ', 'g'), 260), '. ')
           || '. Do not repeat this.'
    into v_fix
    from public.generation_outputs go
    where go.shot_id = v_shot_id
      and go.qc_status = 'FAIL'
      and coalesce(btrim(go.qc_notes), '') <> ''
    order by go.created_at desc
    limit 1;

    v_tail := case when coalesce(btrim(v_spec.negative_prompt), '') <> ''
                   then ' Avoid: ' || left(btrim(v_spec.negative_prompt), 300) else '' end;
    v_prompt :=
        'Use @image_1 as the start frame: the video begins exactly with this picture. '
        || 'Keep its framing, where everyone stands, the outfits, the props, the place and the light; no new person and no new object appears. There is exactly one of each character: never a second copy of anybody, not in the background either.'
        || case when v_names is null then '' else
               ' ' || v_names || ': their faces, hair and body proportions stay exactly as in these reference images.'
               || case when v_notes is null then '' else ' ' || v_notes end end
        || ' ' || coalesce(nullif(m417_internal.camera_move_sentence(m417_internal.camera_move(v_plan ->> 'camera_move')), ''),
                           'Static camera, no camera movement.')
        || ' What happens: ' || rtrim(left(btrim(coalesce(v_spec.narrative_action, '')), 400), '. ') || '.'
        || case when v_beats is null then '' else
               format(' Timing: %s. The action starts immediately and all of it happens within the first %s seconds; after that everyone holds the final pose.',
                      v_beats, to_char(v_window, 'FM990.0')) end
        || ' ' || case
               when v_speaker is null then
                   'Nobody speaks in this shot: no talking mouth movements. Feelings show in the eyes, eyebrows and body, in a smile, a gasp or a laugh.'
               when v_spec.voice_staging = 'ON_CAMERA' then
                   v_speaker || ' is talking from the first moment of the shot, mouth moving naturally, with matching gestures. Nobody else talks.'
               when v_spec.voice_staging = 'BACK_TO_CAMERA' then
                   v_speaker || ' is talking but is seen only from behind. Nobody else talks.'
               else
                   'A voice is heard from off-screen. Nobody visible talks: their mouths stay closed while they listen and react.'
               end
        || case when coalesce(btrim(v_spec.emotion), '') = '' then '' else ' Acting: ' || left(btrim(v_spec.emotion), 180) || '.' end
        || ' One continuous shot, never a cut, a collage or a split screen. No on-screen text.'
        || coalesce(v_fix, '');
    v_prompt := left(regexp_replace(v_prompt, '[[:space:]]+', ' ', 'g'), 2500 - length(v_tail)) || v_tail;

    v_images := jsonb_build_array(m417_internal.keyframe_url(v_key.storage_path))
        || coalesce((select jsonb_agg(r.value ->> 'url' order by (r.value ->> 'n')::integer)
                     from jsonb_array_elements(v_refs) r(value)), '[]'::jsonb);
    return jsonb_set(
        v_base, '{input}',
        (v_base -> 'input') || jsonb_build_object('prompt', v_prompt, 'images', v_images))::text;
end;
$function$;

-- ----- SHOT_PACKAGE 4: everybody is there from the first shot --------------
-- Version 3 with two rules added: nobody pops into a scene, and a first
-- frame shows props in the state the shot before left them.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3;
    if v is null then
        raise exception 'M417_014_PROMPT_V3_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.$a$,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.
- Nobody pops into the scene. Shot 1 shows every character who takes part in the scene, all in one picture, so the viewer knows who is there before anything happens; a line in shot 1 is spoken by a character who is seen in it, never from off-screen. Only a character whose arrival is the surprise of the payoff may be missing from shot 1.
- The story runs on from picture to picture. The first_frame of a shot shows the place, the characters, their positions and every prop exactly in the state in which the shot before ended: what is closed stays closed until a shot shows it being opened, and what is inside something is not visible before it comes out.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture;$a$,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture; shot 1 shows everyone in the scene; every first_frame continues from the end of the shot before it;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 4, false, 'Step 11: as version 3, plus: everybody is in shot 1, and first frames continue from the shot before.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = false where prompt_code = 'SHOT_PACKAGE' and version <> 4 and is_active;
    update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 4 and not is_active;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_014_APPLIED', 'INFO', 'CONTROL_PLANE', 'Storyboard rules (014) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
