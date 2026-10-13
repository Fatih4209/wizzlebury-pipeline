-- =====================================================================
-- M417 / WIZZLEBURY  -  018 the owner's locked places
--
-- 13 October: the first one-take picture was drawn in an invented
-- classroom (desks for three). The owner: "the class is wrong, the desks
-- are for two, use the classroom I uploaded". On 4 October a library of
-- locked location pictures was made (canonical-assets, private bucket):
-- classroom master / reverse / side, canteen, school bus, yard, corridor,
-- dance studio, homes, park ... They are copied to public-refs/auto/places/
-- (Make scenario "M417-Dosya Kopyala", webhook in setting webhook_copy) and
-- listed in public.auto_places. A one-take spec names one with
-- "place_ref": the picture is sent as an extra reference image and the
-- frame prompt says the room must be exactly that room. The locked rooms
-- have writing on boards and posters; with a place_ref the prompts no
-- longer forbid that writing, only new writing.
-- Safe to run more than once.
-- =====================================================================
begin;

create table if not exists public.auto_places (
    code text primary key check (code ~ '^[A-Z_]{3,30}$'),
    ref_file text not null,
    source_file text not null,
    look text not null
);
alter table public.auto_places enable row level security;

-- A note on the set of an episode (seating, which place picture), given to
-- the SPEC step through {EP_SET} (writer_fill below, writer_p_spec gets the
-- placeholder right after {EP_ERROR}). Applied live 13 October.
-- Lesson: the Supabase MCP tool cancels a query whose quoted text contains a
-- semicolon (it seems to split statements on it); write such texts without ';'.
alter table public.writer_episodes add column if not exists set_note text;

update public.auto_shorts_settings set value = replace(value, E'{EP_ERROR}\nEvery object', E'{EP_ERROR}{EP_SET}\nEvery object')
where key = 'writer_p_spec' and position('{EP_SET}' in value) = 0;

create or replace function m417_internal.writer_fill(p_tpl text, p_code text, p_part text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    ep public.writer_episodes;
    v text := p_tpl;
begin
    select * into ep from public.writer_episodes e where e.code = p_code;
    v := replace(v, '{PART}', coalesce(p_part, ''));
    v := replace(v, '{EP_NO}', ep.no::text);
    v := replace(v, '{EP_TITLE}', ep.title);
    v := replace(v, '{EP_PLACE}', ep.place);
    v := replace(v, '{EP_WARDROBE}', ep.wardrobe);
    v := replace(v, '{EP_PREMISE}', ep.premise);
    v := replace(v, '{EP_ERROR}', case when coalesce(ep.error, '') = '' then ''
        else E'\nNOTE: your previous answer was rejected by the checker with this message: ' || ep.error || E'\nFix exactly that.\n' end);
    v := replace(v, '{EP_SET}', coalesce(E'\n' || nullif(ep.set_note, '') || E'\n', ''));
    v := replace(v, '{EP_RESEARCH}', coalesce(ep.research, ''));
    v := replace(v, '{EP_EDIT}', coalesce(ep.edit, ''));
    v := replace(v, '{EP_DRAFT}', coalesce(ep.draft, ''));
    v := replace(v, '{EP_FINAL}', coalesce(ep.final_text, ''));
    return v;
end;
$function$;

insert into public.auto_shorts_settings (key, value, description) values
    ('webhook_copy', 'https://hook.eu1.make.com/h7jlnk98riauh6qrgugb37g2apjkl3lo', 'Make: copy a file from a private bucket to public-refs ({from_bucket, from, to}).')
on conflict (key) do nothing;

insert into public.auto_places (code, ref_file, source_file, look) values
    ('CLASSROOM', 'auto/places/CLASSROOM_MASTER_V1.png', 'M417/locations/core-classroom/v1/M417_CLASSROOM_MASTER_V1.png',
     'the children''s classroom seen from the back towards the front: the green chalkboard, the whiteboard, the teacher''s desk, the door on the right wall, tall windows on the left, rows of light wooden desks for two children each with blue chairs'),
    ('CLASSROOM_REVERSE', 'auto/places/CLASSROOM_REVERSE_V1.png', 'M417/locations/core-classroom/v1/M417_CLASSROOM_REVERSE_V1.png',
     'the same classroom seen from the front towards the back: the back wall with the world map, coat hooks with backpacks and shelves, the door on the left, tall windows on the right, rows of light wooden desks for two children each with blue chairs'),
    ('CLASSROOM_SIDE', 'auto/places/CLASSROOM_SIDE_V1.png', 'M417/locations/core-classroom/v1/M417_CLASSROOM_SIDE_V1.png',
     'the same classroom seen from the side, along the rows of light wooden desks for two children each with blue chairs'),
    ('CANTEEN', 'auto/places/CANTEEN_MASTER_V1.png', 'M417/locations/school-canteen/v1/M417_SCHOOL_CANTEEN_MASTER_V1.png',
     'the school canteen with its serving counter, tables and chairs'),
    ('CANTEEN_REVERSE', 'auto/places/CANTEEN_REVERSE_V1.png', 'M417/locations/school-canteen/v1/M417_SCHOOL_CANTEEN_REVERSE_V1.png',
     'the same school canteen seen from the other side')
on conflict (code) do update set ref_file = excluded.ref_file, source_file = excluded.source_file, look = excluded.look;

create or replace function m417_internal.as_prompts_onetake(p_code text, p_spec jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_base text := m417_internal.as_set('storage_base');
    v_cast text[];
    v_n integer;
    v_num text[] := array['one', 'two', 'three'];
    v_ord text[] := array['first', 'second', 'third', 'fourth', 'fifth', 'sixth'];
    v_pl public.auto_places;
    v_place_frame text := '';
    v_pos text[];
    v_c jsonb;
    v_names text := '';
    v_positions text := '';
    v_refs jsonb := '[]'::jsonb;
    v_action text := btrim(coalesce(p_spec ->> 'action', ''));
    v_adults text[];
    v_x public.auto_extras;
    v_adult_frame text := '';
    v_adult_clip text := '';
    v_refno integer;
    v_sec integer := coalesce((p_spec ->> 'seconds')::integer, 10);
    v_key text;
    v_frame text;
    v_clip text;
    v_style constant text := 'Draw one still picture, vertical 9:16, 3D animated kids cartoon, soft rounded Pixar-like style';
    i integer;
begin
    select array_agg(upper(x)) into v_cast from jsonb_array_elements_text(p_spec -> 'cast') x;
    v_n := coalesce(array_length(v_cast, 1), 0);
    if v_n not between 2 and 3 then
        raise exception 'AUTO_SPEC: cast needs two or three characters';
    end if;
    foreach v_key in array array['place', 'scene', 'action', 'sounds'] loop
        if coalesce(btrim(p_spec ->> v_key), '') = '' then
            raise exception 'AUTO_SPEC: % is missing', v_key;
        end if;
    end loop;
    if jsonb_typeof(p_spec -> 'expect') <> 'array' or jsonb_array_length(p_spec -> 'expect') = 0 then
        raise exception 'AUTO_SPEC: expect needs at least one line';
    end if;
    if v_sec not between 5 and 15 then
        raise exception 'AUTO_SPEC: seconds must be 5 to 15';
    end if;
    v_pos := case when v_n = 3 then array['On the left', 'In the middle', 'On the right']
                  else array['On the left', 'On the right'] end;
    for i in 1 .. v_n loop
        v_c := m417_internal.as_char(v_cast[i], p_spec ->> 'wardrobe');
        if v_c is null then
            raise exception 'AUTO_SPEC: unknown character or wardrobe: % / %', v_cast[i], coalesce(p_spec ->> 'wardrobe', 'classic');
        end if;
        v_positions := v_positions || v_pos[i] || ': ' || format(v_c ->> 'frame', v_ord[i]) || '. ';
        v_names := v_names || case when i > 1 then '; ' else '' end || lower(v_pos[i]) || ' ' || (v_c ->> 'clip');
        v_refs := v_refs || jsonb_build_object('upload_format', 'url', 'uri', v_base || (v_c ->> 'ref'), 'mimeType', 'image/png');
        v_action := replace(v_action, '{' || i || '}', v_c ->> 'name');
    end loop;
    -- the grown-ups: "adults": [...] or the older "adult": "TEACHER"
    select array_agg(upper(x)) into v_adults
    from jsonb_array_elements_text(case when jsonb_typeof(p_spec -> 'adults') = 'array' then p_spec -> 'adults'
                                        when coalesce(p_spec ->> 'adult', '') <> '' then jsonb_build_array(p_spec ->> 'adult')
                                        else '[]'::jsonb end) x;
    if coalesce(array_length(v_adults, 1), 0) > 2 then
        raise exception 'AUTO_SPEC: at most two grown-ups in one short';
    end if;
    v_refno := v_n;
    for i in 1 .. coalesce(array_length(v_adults, 1), 0) loop
        select e.* into v_x from public.auto_extras e where e.code = v_adults[i];
        if not found then
            raise exception 'AUTO_SPEC: unknown grown-up: %', v_adults[i];
        end if;
        v_refno := v_refno + 1;
        v_refs := v_refs || jsonb_build_object('upload_format', 'url', 'uri', v_base || v_x.ref_file, 'mimeType', 'image/jpeg');
        v_adult_frame := v_adult_frame || initcap(left(v_x.short_name, 1)) || substr(v_x.short_name, 2) || ' is the person from the ' || v_ord[v_refno]
            || ' reference image, exactly as in that image: ' || v_x.look || '. ';
        v_adult_clip := v_adult_clip || '; and ' || v_x.clip_text;
        v_action := replace(v_action, '{' || v_x.code || '}', v_x.short_name);
    end loop;
    -- the place: one of the owner's locked location pictures (public.auto_places)
    if coalesce(p_spec ->> 'place_ref', '') <> '' then
        select p.* into v_pl from public.auto_places p where p.code = upper(p_spec ->> 'place_ref');
        if not found then
            raise exception 'AUTO_SPEC: unknown place_ref: %', p_spec ->> 'place_ref';
        end if;
        v_refno := v_refno + 1;
        v_refs := v_refs || jsonb_build_object('upload_format', 'url', 'uri', v_base || v_pl.ref_file, 'mimeType', 'image/png');
        v_place_frame := 'The place is exactly the room in the ' || v_ord[v_refno] || ' reference image (' || v_pl.look
            || '): the same walls, windows, door, boards, posters, shelves, furniture and desks, the same colours and the same light. The camera stands inside that room; only the framing is closer. ';
    end if;
    v_action := replace(v_action, '{T}', 'the teacher');
    if position('{' in v_action) > 0 then
        raise exception 'AUTO_SPEC: action has an unknown placeholder';
    end if;

    v_frame := v_style || ', like a frame of a real video filmed by one camera at the eye level of a child. '
        || v_place_frame || btrim(p_spec ->> 'place') || ' ' || btrim(p_spec ->> 'scene') || ' The children, from left to right: ' || v_positions
        || v_adult_frame
        || 'Everybody is fully inside the picture with the face clearly visible, mouths closed. Exactly ' || v_num[v_n] || ' children'
        || case coalesce(array_length(v_adults, 1), 0) when 1 then ' and one grown-up' when 2 then ' and two grown-ups' else '' end
        || coalesce(' ' || nullif(btrim(p_spec ->> 'crowd'), ''), '')
        || '. Only the clothes of the children may differ from their reference images: every face, hairstyle, hair colour, skin tone, eye colour, age and body shape stays exactly as in its reference image. '
        || case when coalesce(btrim(p_spec ->> 'crowd'), '') = '' then 'Nobody else, no' else 'No' end
        || case when v_place_frame <> '' then ' animals, no numbers or logos on the clothes; boards, posters and signs only as they are in the room reference image, nothing new written anywhere.'
                else ' animals, no text, no letters, no numbers or logos on the clothes, nothing written on walls, boards, books or signs.' end;

    v_clip := 'The video starts exactly from this picture and is one single continuous shot without any cut, about ' || v_sec
        || ' seconds long, filmed like a real video by one hand-held camera that turns smoothly toward whoever speaks. 3D animated family cartoon for kids, warm and natural like everyday life. The movement begins in the very first moment, with no still pause. '
        || 'The people in the picture: ' || v_names || v_adult_clip || '. '
        || v_action
        || ' Whenever somebody speaks or sings, the camera is on that person and the mouth forms every word clearly, exactly in sync with the voice. Every line is said or sung once, in English, only by those named for it. '
        || 'The camera never cuts and nobody new appears who is not in the first picture; every face and all clothes stay exactly as they are in the first picture. Sound: '
        || btrim(p_spec ->> 'sounds') || ' and a quiet room tone. No narrator, no subtitles, no new text or writing appears anywhere.'
        || case when coalesce((p_spec ->> 'music')::boolean, true) then ' No music.' else '' end;

    return jsonb_build_object(
        'frames', jsonb_build_array(jsonb_build_object('key', 'W', 'refs', v_refs, 'prompt', v_frame)),
        'clips', jsonb_build_array(jsonb_build_object('key', 'C1', 'frame', 'W', 'seconds', v_sec, 'prompt', v_clip)),
        'expected', p_spec -> 'expect',
        'seconds', v_sec,
        'one_take', true)
        || case when coalesce((p_spec ->> 'music')::boolean, true) then '{}'::jsonb else '{"no_music": true}'::jsonb end;
end;
$function$;

commit;
