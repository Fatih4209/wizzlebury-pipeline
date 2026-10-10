-- =====================================================================
-- M417 / WIZZLEBURY  -  015 automatic shorts (Google clips, fixed slots)
--
-- Safe to run more than once; one transaction. Running this file
-- generates nothing and spends nothing: the timer only acts on rows of
-- public.auto_shorts whose produce_at has come.
--
-- A short is a row: three scenes written in advance (spec), a time to
-- produce it and a time to publish it. Every minute auto_shorts_tick()
-- moves at most one short through production:
--   PLANNED -> FRAME_WIDE -> FRAMES -> CLIPS -> RENDERING -> QC -> READY
-- and publishes READY shorts whose publish_at has come:
--   READY -> PUBLISHING -> PUBLISHED
-- A step that fails or a check that says FAIL ends in FAILED: nothing is
-- published and the owner is told. The owner can cancel a short before
-- its slot with the link in the "ready" message.
-- =====================================================================
begin;

create table if not exists public.auto_shorts_settings (
    key text primary key,
    value text not null,
    description text
);
insert into public.auto_shorts_settings (key, value, description) values
    ('enabled', 'true', 'Master switch of the automatic shorts timer.'),
    ('daily_limit', '3', 'Most shorts whose production may start on one day (Europe/Istanbul).'),
    ('step_timeout_minutes', '5', 'A file that has not arrived after this long is asked for once more, then the short fails.'),
    ('late_publish_minutes', '120', 'A ready short is still published this long after its slot; later it is marked MISSED.'),
    ('qc_min_score', '70', 'Lowest score of the automatic check that may be published.'),
    ('storage_base', 'https://fhkqegbdzsrfgzhikyra.supabase.co/storage/v1/object/public/public-refs/', 'Public address of the bucket the files are written to.'),
    ('music_url', 'https://fhkqegbdzsrfgzhikyra.supabase.co/storage/v1/object/public/public-refs/samples/cake/MUSIC_PLAYFUL.mp3', 'Music under every short.'),
    ('music_volume', '0.12', 'Volume of the music.'),
    ('webhook_frame', 'https://hook.eu1.make.com/8m45knf2emmyxmd811ed634k5bj0d0n7', 'Make: draw a still picture.'),
    ('webhook_clip', 'https://hook.eu1.make.com/546t53e7oil73jpwydqn28o3wluqtabf', 'Make: Google clip from a picture, 1080p.'),
    ('webhook_render', 'https://hook.eu1.make.com/hgak8rm3fphyxhm1ga5ybb6rk85fjrmp', 'Make: Shotstack render and status.'),
    ('webhook_qc', 'https://hook.eu1.make.com/9vl7tukmwyk47bn5z3it4ytk24mue34x', 'Make: store the film and let Gemini watch it.'),
    ('webhook_publish', 'https://hook.eu1.make.com/o2f4cerblk4yy9pqf9ppjwou9xjff5p6', 'Make: upload to YouTube.'),
    ('webhook_cancel', 'https://hook.eu1.make.com/443iogyik0ug55b8va5mqycouv8fm8o3', 'Make: the owner''s cancel link.')
on conflict (key) do nothing;

create table if not exists public.auto_shorts (
    id uuid primary key default gen_random_uuid(),
    code text not null unique check (code ~ '^[A-Z0-9-]{3,40}$'),
    title text not null check (char_length(title) between 3 and 100),
    description text not null check (char_length(description) between 50 and 5000),
    tags_csv text not null,
    spec jsonb not null,
    produce_at timestamptz not null,
    publish_at timestamptz not null,
    state text not null default 'PLANNED' check (state in (
        'PLANNED', 'FRAME_WIDE', 'FRAMES', 'CLIPS', 'RENDERING', 'QC', 'READY',
        'PUBLISHING', 'PUBLISHED', 'FAILED', 'CANCELLED', 'MISSED')),
    state_since timestamptz not null default now(),
    data jsonb not null default '{}'::jsonb,
    cancel_token text not null default replace(gen_random_uuid()::text, '-', ''),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (publish_at > produce_at)
);
create index if not exists idx_auto_shorts_state on public.auto_shorts (state, produce_at);
alter table public.auto_shorts enable row level security;
alter table public.auto_shorts_settings enable row level security;

create or replace function m417_internal.as_set(p_key text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select s.value from public.auto_shorts_settings s where s.key = p_key;
$function$;

-- ----- the cast and its wardrobe ----------------------------------------
-- Who somebody is (face, hair) is fixed here and comes from the reference
-- image. What they wear depends on where the short plays: a row of
-- auto_wardrobe per character and wardrobe. Every character keeps one
-- colour of their own, the clothes change with the place.
create table if not exists public.auto_wardrobe (
    character_code text not null,
    wardrobe text not null,
    outfit_frame text not null,
    outfit_clip text not null,
    primary key (character_code, wardrobe)
);
alter table public.auto_wardrobe enable row level security;
insert into public.auto_wardrobe (character_code, wardrobe, outfit_frame, outfit_clip) values
    ('FATIH', 'classic', 'the same red jacket over a white shirt as', 'the red jacket'),
    ('FATIH', 'home', 'a soft red hoodie and grey sweatpants', 'the red hoodie'),
    ('FATIH', 'pajamas', 'red-and-white striped pajamas with long sleeves', 'the red-and-white striped pajamas'),
    ('FATIH', 'park', 'a white T-shirt with red sleeves, blue denim shorts and a red cap worn backwards', 'the white T-shirt with red sleeves and the red cap'),
    ('FATIH', 'school', 'a red polo shirt with a white collar, navy trousers and a navy backpack', 'the red polo shirt'),
    ('FATIH', 'dance', 'a red tracksuit jacket with white stripes on the sleeves and black track pants', 'the red tracksuit jacket'),
    ('FATIH', 'party', 'a red checked shirt with rolled sleeves, a small blue bow tie and dark jeans', 'the red checked shirt and the blue bow tie'),
    ('MIA', 'classic', 'a lilac top with short sleeves', 'the lilac top'),
    ('MIA', 'home', 'a lilac long-sleeved top under light blue denim dungarees', 'the lilac top and the denim dungarees'),
    ('MIA', 'pajamas', 'lilac pajamas with small white stars, long sleeves and long trousers', 'the lilac pajamas'),
    ('MIA', 'park', 'a lilac summer dress with short sleeves that reaches her knees, white sneakers and a purple hair band', 'the lilac summer dress and the purple hair band'),
    ('MIA', 'school', 'a lilac cardigan over a white collared blouse, a grey pleated skirt that reaches her knees with white tights, and a purple backpack', 'the lilac cardigan'),
    ('MIA', 'dance', 'a lilac dance T-shirt and a pink tutu skirt over purple leggings', 'the lilac dance T-shirt and the pink tutu'),
    ('MIA', 'party', 'a lilac party dress with short puffy sleeves that reaches her knees', 'the lilac party dress'),
    ('TOMBIK', 'classic', 'the same green-and-white varsity jacket over a yellow hoodie as', 'the green-and-white varsity jacket'),
    ('TOMBIK', 'home', 'a green-and-white striped long-sleeved shirt and blue jeans', 'the green-and-white striped shirt'),
    ('TOMBIK', 'pajamas', 'green pajamas with small yellow dots and long sleeves', 'the green pajamas'),
    ('TOMBIK', 'park', 'a yellow T-shirt under green dungaree shorts', 'the yellow T-shirt and the green dungarees'),
    ('TOMBIK', 'school', 'a green knitted vest over a white collared shirt, grey trousers and a yellow backpack', 'the green knitted vest'),
    ('TOMBIK', 'dance', 'a green tracksuit jacket with yellow stripes, zipped up, and a yellow sweatband on his forehead', 'the green tracksuit jacket and the yellow sweatband'),
    ('TOMBIK', 'party', 'a yellow shirt with a green bow tie and green suspenders', 'the yellow shirt and the green suspenders'),
    ('OMER', 'classic', 'the same blue jacket over a white hoodie as', 'the blue jacket'),
    ('OMER', 'home', 'an orange T-shirt with white sleeves and dark grey jogger pants', 'the orange T-shirt with white sleeves'),
    ('OMER', 'pajamas', 'orange pajamas with a white collar and long sleeves', 'the orange pajamas'),
    ('OMER', 'park', 'an orange football jersey with white stripes, black shorts and white sneakers', 'the orange football jersey'),
    ('OMER', 'school', 'an orange polo shirt with a white collar, navy trousers and a blue backpack', 'the orange polo shirt'),
    ('OMER', 'dance', 'an orange sleeveless hoodie over a white T-shirt and black track pants', 'the orange sleeveless hoodie'),
    ('OMER', 'party', 'an orange shirt with a white bow tie under a dark grey waistcoat', 'the orange shirt and the grey waistcoat'),
    ('BRUCE', 'classic', 'the same blue jacket over a white hoodie as', 'the blue jacket'),
    ('BRUCE', 'home', 'a teal sweatshirt, light grey cargo pants and small white headphones around his neck', 'the teal sweatshirt and the white headphones around his neck'),
    ('BRUCE', 'pajamas', 'teal pajamas with thin white stripes and long sleeves', 'the teal striped pajamas'),
    ('BRUCE', 'park', 'a teal windbreaker jacket over a white T-shirt and grey shorts', 'the teal windbreaker'),
    ('BRUCE', 'school', 'a teal zip cardigan over a white collared shirt, dark trousers and a black backpack', 'the teal zip cardigan'),
    ('BRUCE', 'dance', 'a loose teal T-shirt over a long-sleeved white shirt, black track pants and small white headphones around his neck', 'the loose teal T-shirt'),
    ('BRUCE', 'party', 'a teal shirt with a short black tie and a black waistcoat', 'the teal shirt and the black tie')
on conflict (character_code, wardrobe) do nothing;

drop function if exists m417_internal.as_char(text);
create or replace function m417_internal.as_char(p_code text, p_wardrobe text)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    with who as (
        select case upper(btrim(p_code))
            when 'FATIH' then jsonb_build_object('name', 'Fatih', 'ref', 'FATIH_REF_V8.png',
                'face', 'the boy from the %s reference image, same face, same messy brown hair, same green eyes',
                'base', 'Fatih, the boy with messy brown hair',
                'he', 'he', 'his', 'his', 'voice', 'cartoon boy voice')
            when 'MIA' then jsonb_build_object('name', 'Mia', 'ref', 'MIA_REF_V2.png',
                'face', 'the cartoon girl from the %s reference image, same face and same long wavy blonde hair',
                'base', 'Mia, the cartoon character with long wavy blonde hair',
                'he', 'she', 'his', 'her', 'voice', 'cartoon child voice')
            when 'TOMBIK' then jsonb_build_object('name', 'Tombik', 'ref', 'TOMBIK_REF_V1.png',
                'face', 'the chubby boy from the %s reference image, same face, same curly ginger hair, same round body',
                'base', 'Tombik, the chubby boy with curly ginger hair',
                'he', 'he', 'his', 'his', 'voice', 'cartoon boy voice')
            when 'OMER' then jsonb_build_object('name', 'Ömer', 'ref', 'OMER_REF_V1.png',
                'face', 'the boy from the %s reference image, same face, same deep brown skin, same short curly dark hair with tapered sides',
                'base', 'Ömer, the boy with deep brown skin and short curly dark hair',
                'he', 'he', 'his', 'his', 'voice', 'cartoon boy voice')
            when 'BRUCE' then jsonb_build_object('name', 'Bruce', 'ref', 'BRUCE_REF_V1.png',
                'face', 'the boy from the %s reference image, same face, same tousled layered black hair',
                'base', 'Bruce, the boy with tousled black hair',
                'he', 'he', 'his', 'his', 'voice', 'cartoon boy voice')
        end as c
    )
    select who.c || jsonb_build_object(
        'frame', (who.c ->> 'face') || ', wearing ' || w.outfit_frame
                 || case when w.wardrobe = 'classic' and w.outfit_frame like '% as' then ' in that reference image'
                         when w.wardrobe = 'classic' then ''
                         else ' instead of the clothes in that reference image' end,
        'clip', (who.c ->> 'base') || ' in ' || w.outfit_clip)
    from who
    join public.auto_wardrobe w
      on w.character_code = upper(btrim(p_code))
     and w.wardrobe = coalesce(nullif(lower(btrim(p_wardrobe)), ''), 'classic')
    where who.c is not null;
$function$;

create or replace function m417_internal.as_words(p_line text)
 returns text language sql immutable set search_path to ''
as $function$
    select case n
        when 1 then 'this one word' when 2 then 'these two words' when 3 then 'these three words'
        when 4 then 'these four words' when 5 then 'these five words' when 6 then 'these six words'
        when 7 then 'these seven words' when 8 then 'these eight words' else 'these words' end
    from (select coalesce(array_length(regexp_split_to_array(btrim(regexp_replace(p_line, '[^[:alnum:]'' -]+', ' ', 'g')), '\s+'), 1), 0) as n) x;
$function$;

-- ----- from a spec to the texts sent to the models -------------------------
-- Returns {"frames":[{key,refs,prompt}], "clips":[{key,frame,seconds,prompt}],
--          "expected":[...], "seconds": n}. Raises when the spec is incomplete.
create or replace function m417_internal.as_prompts(p_code text, p_spec jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_base text := m417_internal.as_set('storage_base');
    v_dir text := v_base || 'auto/' || p_code || '/';
    v_cast text[];
    v_n integer;
    v_num text[] := array['one', 'two', 'three'];
    v_ord text[] := array['first', 'second', 'third'];
    v_pos text[];
    v_c jsonb;
    v_s1 jsonb := p_spec -> 's1';
    v_s2 jsonb := p_spec -> 's2';
    v_s3 jsonb := p_spec -> 's3';
    v_s4 jsonb := case when jsonb_typeof(p_spec -> 's4') = 'object' then p_spec -> 's4' else '{}'::jsonb end;
    v_names text := '';
    v_expected jsonb;
    v_total integer;
    v_sp jsonb;
    v_c2 jsonb;
    v_c3 jsonb;
    v_positions text := '';
    v_refs jsonb := '[]'::jsonb;
    v_frames jsonb := '[]'::jsonb;
    v_clips jsonb := '[]'::jsonb;
    v_text text;
    v_style constant text := 'Draw one still picture, vertical 9:16, 3D animated kids cartoon, soft rounded Pixar-like style';
    v_open constant text := 'The video starts exactly from this picture and stays one continuous shot, about %s seconds long. 3D animated family cartoon for kids. ';
    v_key text;
    i integer;
begin
    select array_agg(upper(x)) into v_cast from jsonb_array_elements_text(p_spec -> 'cast') x;
    v_n := coalesce(array_length(v_cast, 1), 0);
    if v_n not between 2 and 3 then
        raise exception 'AUTO_SPEC: cast needs two or three characters';
    end if;
    foreach v_key in array array['place', 'setup', 'wide_pose'] loop
        if coalesce(btrim(p_spec ->> v_key), '') = '' then
            raise exception 'AUTO_SPEC: % is missing', v_key;
        end if;
    end loop;
    foreach v_key in array array['action', 'speaker', 'gesture', 'voice', 'line'] loop
        if coalesce(btrim(v_s1 ->> v_key), '') = '' then
            raise exception 'AUTO_SPEC: s1.% is missing', v_key;
        end if;
    end loop;
    foreach v_key in array array['char', 'pose', 'action', 'voice', 'line', 'after'] loop
        if coalesce(btrim(v_s2 ->> v_key), '') = '' then
            raise exception 'AUTO_SPEC: s2.% is missing', v_key;
        end if;
    end loop;
    foreach v_key in array array['frame', 'action', 'sounds', 'guard', 'expect'] loop
        if coalesce(btrim(v_s3 ->> v_key), '') = '' then
            raise exception 'AUTO_SPEC: s3.% is missing', v_key;
        end if;
    end loop;
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
    end loop;
    v_sp := m417_internal.as_char(v_s1 ->> 'speaker', p_spec ->> 'wardrobe');
    v_c2 := m417_internal.as_char(v_s2 ->> 'char', p_spec ->> 'wardrobe');
    v_c3 := m417_internal.as_char(v_s3 ->> 'char', p_spec ->> 'wardrobe');
    if v_sp is null or not (upper(v_s1 ->> 'speaker') = any (v_cast)) then
        raise exception 'AUTO_SPEC: s1.speaker must be one of the cast';
    end if;
    if v_c2 is null then
        raise exception 'AUTO_SPEC: s2.char is unknown';
    end if;

    -- wide picture: everybody and the thing the short is about
    v_text := v_style || '. ' || btrim(p_spec ->> 'place') || ' ' || btrim(p_spec ->> 'setup') || ' '
        || initcap(v_num[v_n]) || ' children ' || btrim(p_spec ->> 'wide_pose') || ', mouths closed, all '
        || v_num[v_n] || ' fully visible, medium-wide shot at eye level. ' || v_positions
        || 'Exactly ' || v_num[v_n] || ' children' || coalesce(' and ' || nullif(btrim(p_spec ->> 'guard'), ''), '')
        || '. Only the clothes may differ from the reference images: every face, hairstyle, hair colour, skin tone, eye colour, age and body shape stays exactly as in its reference image. Nobody else, ' || case when coalesce((p_spec ->> 'wide_animals')::boolean, false) then '' else 'no animals, ' end
        || 'no text, no letters.';
    v_frames := v_frames || jsonb_build_object('key', 'W', 'refs', v_refs, 'prompt', v_text);

    -- close picture of the one who answers
    v_text := v_style || ', shallow depth of field. It is a close-up taken inside the scene of the second reference image: the same place, the same light and the same things. Close-up at eye level on '
        || format(v_c2 ->> 'frame', 'first') || ', exactly as ' || (v_c2 ->> 'he') || ' looks in the second image. Head and shoulders, face in three-quarter view toward the camera, mouth closed and fully visible, '
        || btrim(v_s2 ->> 'pose') || '. '
        || coalesce(nullif(btrim(v_s2 ->> 'foreground'), '') || ' in the foreground at the bottom edge of the frame, slightly blurred. ', '')
        || 'The background is softly blurred. Only this one child, nobody else, no animals, no text, no letters.';
    v_frames := v_frames || jsonb_build_object('key', 'F2', 'prompt', v_text, 'refs', jsonb_build_array(
        jsonb_build_object('upload_format', 'url', 'uri', v_base || (v_c2 ->> 'ref'), 'mimeType', 'image/png'),
        jsonb_build_object('upload_format', 'url', 'uri', v_dir || 'W.jpg', 'mimeType', 'image/jpeg')));

    -- picture of the payoff
    v_text := v_style || ', shallow depth of field. It is taken inside the scene of the '
        || case when v_c3 is null then '' else 'second ' end || 'reference image: the same place and the same light. '
        || replace(btrim(v_s3 ->> 'frame'), '{CHAR}',
               case when v_c3 is null then '' else format(v_c3 ->> 'frame', 'first') || ', exactly as ' || (v_c3 ->> 'he') || ' looks in the second image' end)
        || ' No text, no letters.';
    v_frames := v_frames || jsonb_build_object('key', 'F3', 'prompt', v_text, 'refs',
        case when v_c3 is null then '[]'::jsonb
             else jsonb_build_array(jsonb_build_object('upload_format', 'url', 'uri', v_base || (v_c3 ->> 'ref'), 'mimeType', 'image/png')) end
        || jsonb_build_object('upload_format', 'url', 'uri', v_dir || 'W.jpg', 'mimeType', 'image/jpeg'));

    -- clip 1: the question
    v_text := format(v_open, coalesce((v_s1 ->> 'seconds')::integer, 4)) || btrim(v_s1 ->> 'action') || ' Then ' || (v_sp ->> 'clip') || ', '
        || btrim(v_s1 ->> 'gesture') || ' and ' || coalesce(nullif(btrim(v_s1 ->> 'verb'), ''), 'says') || ' in ' || btrim(v_s1 ->> 'voice') || ' ' || (v_sp ->> 'voice')
        || ': "' || btrim(v_s1 ->> 'line') || '" ' || initcap(v_sp ->> 'his') || ' mouth forms every word clearly, exactly in sync with ' || (v_sp ->> 'his') || ' voice. '
        || initcap(v_sp ->> 'he') || ' says only ' || m417_internal.as_words(v_s1 ->> 'line') || ', once, in English. The other children keep their mouths closed. '
        || coalesce(nullif(btrim(v_s1 ->> 'rule'), '') || ' ', '') || 'The camera does not move. Sound: '
        || coalesce(nullif(btrim(v_s1 ->> 'sounds'), '') || ', ', '') || (v_sp ->> 'his') || ' voice and a quiet room tone. No music, no other voices, no narrator. Exactly '
        || v_num[v_n] || ' children, nobody else appears, no text, no subtitles.';
    v_clips := v_clips || jsonb_build_object('key', 'C1', 'frame', 'W', 'seconds', coalesce((v_s1 ->> 'seconds')::integer, 4), 'prompt', v_text);

    -- clip 2: the answer, one face
    v_text := format(v_open, coalesce((v_s2 ->> 'seconds')::integer, 3)) || 'Close-up on ' || (v_c2 ->> 'clip')
        || coalesce(', ' || nullif(btrim(v_s2 ->> 'fg_clip'), ''), '') || '. ' || btrim(v_s2 ->> 'action') || ' and '
        || coalesce(nullif(btrim(v_s2 ->> 'verb'), ''), 'says') || ' at once, in ' || btrim(v_s2 ->> 'voice') || ' ' || (v_c2 ->> 'voice')
        || ': "' || btrim(v_s2 ->> 'line') || '" ' || initcap(v_c2 ->> 'his') || ' mouth forms every word clearly, exactly in sync with ' || (v_c2 ->> 'his') || ' voice. '
        || initcap(v_c2 ->> 'he') || ' says only ' || m417_internal.as_words(v_s2 ->> 'line') || ', once, in English, then ' || btrim(v_s2 ->> 'after')
        || ' with ' || (v_c2 ->> 'his') || ' mouth closed. ' || coalesce(nullif(btrim(v_s2 ->> 'rule'), '') || ' ', '')
        || 'The camera does not move. Sound: ' || coalesce(nullif(btrim(v_s2 ->> 'sounds'), '') || ', ', 'only ') || (v_c2 ->> 'his') || ' voice and a quiet room tone. No music, no other voices, no narrator. Only '
        || (v_c2 ->> 'name') || ' is in the frame, nobody else appears, no text, no subtitles.';
    v_clips := v_clips || jsonb_build_object('key', 'C2', 'frame', 'F2', 'seconds', coalesce((v_s2 ->> 'seconds')::integer, 3), 'prompt', v_text);

    -- clip 3: the payoff
    v_text := format(v_open, coalesce((v_s3 ->> 'seconds')::integer, 3))
        || replace(btrim(v_s3 ->> 'action'), '{CHAR}', coalesce(v_c3 ->> 'clip', ''))
        || ' The camera does not move. Sound: ' || btrim(v_s3 ->> 'sounds') || ' and a quiet room tone. No music, no narrator. '
        || btrim(v_s3 ->> 'guard') || ' no text, no subtitles.';
    v_clips := v_clips || jsonb_build_object('key', 'C3', 'frame', 'F3', 'seconds', coalesce((v_s3 ->> 'seconds')::integer, 3), 'prompt', v_text);

    v_expected := jsonb_build_array(
        (v_sp ->> 'name') || ' says: "' || btrim(v_s1 ->> 'line') || '"',
        (v_c2 ->> 'name') || ' says: "' || btrim(v_s2 ->> 'line') || '"',
        btrim(v_s3 ->> 'expect'));
    v_total := coalesce((v_s1 ->> 'seconds')::integer, 4) + coalesce((v_s2 ->> 'seconds')::integer, 3) + coalesce((v_s3 ->> 'seconds')::integer, 3);

    -- scene 4: everybody reacts. Written by default; "s4": false leaves it out.
    if coalesce(p_spec ->> 's4', '') <> 'false' then
        v_text := v_style || ', shallow depth of field. It is taken inside the scene of the last reference image: the same place, the same light and the same clothes. Close shot at eye level on the same '
            || v_num[v_n] || ' children, heads close together so that their faces fill the frame, shoulder to shoulder in the same order from left to right, exactly as they look in the last reference image. ' || v_positions
            || 'All ' || v_num[v_n] || ' ' || coalesce(nullif(btrim(v_s4 ->> 'pose'), ''), 'look down at something just below the frame with wide, amazed eyes') || ', mouths closed. The background is softly blurred. Only the clothes may differ from the reference images: every face, hairstyle, hair colour, skin tone, eye colour, age and body shape stays exactly as in its reference image. Exactly '
            || v_num[v_n] || ' children, nobody else, no animals, no text, no letters.';
        v_frames := v_frames || jsonb_build_object('key', 'F4', 'prompt', v_text,
            'refs', v_refs || jsonb_build_object('upload_format', 'url', 'uri', v_dir || 'W.jpg', 'mimeType', 'image/jpeg'));
        v_text := format(v_open, coalesce((v_s4 ->> 'seconds')::integer, 3)) || 'Close shot on the faces of ' || v_num[v_n] || ' children standing close together: ' || v_names
            || '. ' || coalesce(nullif(btrim(v_s4 ->> 'action'), ''),
                   'All ' || v_num[v_n] || ' stare down at something just below the frame with wide, amazed eyes and open mouths for a moment, then burst out laughing together and look at each other.')
            || ' Their faces are very expressive: big open-mouthed laughs, eyes squeezed with joy, cheeks lifted, heads tipping back a little, shoulders shaking.'
            || ' Nobody says a word; there is only happy children''s laughter. The camera does not move. Sound: the children''s gasp and laughter and a quiet room tone. No music, no words, no narrator. Exactly '
            || v_num[v_n] || ' children, nobody else appears, no text, no subtitles.';
        v_clips := v_clips || jsonb_build_object('key', 'C4', 'frame', 'F4', 'seconds', coalesce((v_s4 ->> 'seconds')::integer, 3), 'prompt', v_text);
        v_expected := v_expected || to_jsonb('All the children look amazed and then laugh together; nobody speaks.'::text);
        v_total := v_total + coalesce((v_s4 ->> 'seconds')::integer, 3);
    end if;

    return jsonb_build_object('frames', v_frames, 'clips', v_clips, 'expected', v_expected, 'seconds', v_total);
end;
$function$;

-- ----- the edit: three clips, soft fades, the channel's music ---------------
create or replace function m417_internal.as_render_request(p_code text, p_prompts jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_dir text := m417_internal.as_set('storage_base') || 'auto/' || p_code || '/';
    v_tracks jsonb := '[]'::jsonb;
    v_clip jsonb;
    v_at numeric := 0;
    v_no integer := 0;
begin
    for v_clip in select * from jsonb_array_elements(p_prompts -> 'clips')
    loop
        -- later clips lie on top and fade in over the end of the one before
        v_tracks := jsonb_build_array(jsonb_build_object('clips', jsonb_build_array(
            jsonb_build_object(
                'asset', jsonb_build_object('type', 'video', 'src', v_dir || (v_clip ->> 'key') || '.mp4', 'volume', 1),
                'start', greatest(v_at - 0.5 * v_no, 0),
                'length', (v_clip ->> 'seconds')::numeric,
                'fit', 'cover')
            || case when v_no > 0 then jsonb_build_object('transition', jsonb_build_object('in', 'fadeFast')) else '{}'::jsonb end)))
            || v_tracks;
        v_at := v_at + (v_clip ->> 'seconds')::numeric;
        v_no := v_no + 1;
    end loop;
    return jsonb_build_object(
        'timeline', jsonb_build_object(
            'background', '#000000',
            'soundtrack', jsonb_build_object('src', m417_internal.as_set('music_url'), 'effect', 'fadeOut',
                                             'volume', m417_internal.as_set('music_volume')::numeric),
            'tracks', v_tracks),
        'output', jsonb_build_object('format', 'mp4', 'aspectRatio', '9:16', 'resolution', '1080', 'fps', 24));
end;
$function$;

create or replace function m417_internal.as_qc_prompt(p_prompts jsonb)
 returns text language sql stable set search_path to ''
as $function$
    select 'You are the quality inspector of a cartoon channel for small children. Watch this short vertical video with its sound and judge it strictly. It was made from several generated clips joined with soft fades; a fade between two clips is not a defect, and quiet background music is wanted.'
        || E'\nExpected, in this order:'
        || (select string_agg(E'\n' || e.ord || ') ' || e.value, '' order by e.ord)
            from jsonb_array_elements_text(p_prompts -> 'expected') with ordinality e(value, ord))
        || E'\nAnswer FAIL if any of these is true: a spoken line is missing, cut off, in another language or has clearly different words; a voice speaks while nobody''s mouth moves, or the wrong character speaks; any text, letters, subtitles, logo or watermark is visible; a face, a hand or a body is deformed, has too many or too few parts, or changes into another one; a character looks like a different child from one scene to the next (other face, hair or skin); a character or an object is duplicated, appears from nowhere or vanishes; a part of the video is frozen or black; anything is scary, unsafe or unsuitable for small children. Otherwise answer PASS.'
        || E'\nReturn exactly this JSON and nothing else: {"verdict": "PASS or FAIL", "score": 0, "heard": [""], "problems": [""]}. score is 0 to 100; heard lists the words you actually hear, in order.';
$function$;

-- ----- small helpers of the timer -----------------------------------------
create or replace function m417_internal.as_post(p_url text, p_body jsonb, p_timeout_ms integer default 300000)
 returns bigint language sql security definer set search_path to ''
as $function$
    select net.http_post(url := p_url, body := p_body, timeout_milliseconds := p_timeout_ms);
$function$;

create or replace function m417_internal.as_exists(p_code text, p_file text)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select exists (select 1 from storage.objects o
                   where o.bucket_id = 'public-refs' and o.name = 'auto/' || p_code || '/' || p_file);
$function$;

create or replace function m417_internal.as_notify(p_text text)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    v_url text := (select s.value from public.system_text_settings s where s.key = 'webhook_notify');
    v_chat text := (select s.value from public.system_text_settings s where s.key = 'notify_chat_id');
begin
    if coalesce(v_url, '') <> '' and coalesce(v_chat, '') <> '' then
        perform net.http_post(url := v_url, body := jsonb_build_object('chat_id', v_chat, 'text', p_text));
    end if;
end;
$function$;

create or replace function m417_internal.as_move(p_id uuid, p_state text, p_patch jsonb default '{}'::jsonb)
 returns void language sql security definer set search_path to ''
as $function$
    update public.auto_shorts
    set state = p_state,
        state_since = case when state = p_state then state_since else now() end,
        data = data || coalesce(p_patch, '{}'::jsonb),
        updated_at = now()
    where id = p_id;
$function$;

create or replace function m417_internal.as_fail(p_id uuid, p_reason text, p_detail text default null)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    r public.auto_shorts;
begin
    select a.* into r from public.auto_shorts a where a.id = p_id;
    perform m417_internal.as_move(p_id, 'FAILED', jsonb_build_object(
        'failed_at', now(), 'failed_in', r.state, 'reason', p_reason, 'detail', left(coalesce(p_detail, ''), 600)));
    perform m417_internal.as_notify(format(
        E'⛔ Otomatik video durdu: %s (%s)\nAşama: %s\nSebep: %s\n%s\nBu video yayınlanmayacak.',
        r.title, r.code, r.state, p_reason, left(coalesce(p_detail, ''), 400)));
end;
$function$;

-- Asks for the files of a stage that are not there yet. Returns the
-- missing file names. A file is asked for when p_first is true, or once
-- more when the stage has waited longer than the timeout.
create or replace function m417_internal.as_request(p_id uuid, p_kind text, p_keys text[], p_first boolean)
 returns text[] language plpgsql security definer set search_path to ''
as $function$
declare
    r public.auto_shorts;
    v_p jsonb;
    v_item jsonb;
    v_missing text[] := array[]::text[];
    v_file text;
    v_dir text;
    v_timeout interval := make_interval(mins => coalesce(m417_internal.as_set('step_timeout_minutes')::integer, 5));
    v_retry boolean;
begin
    select a.* into r from public.auto_shorts a where a.id = p_id;
    v_p := m417_internal.as_prompts(r.code, r.spec);
    v_dir := m417_internal.as_set('storage_base') || 'auto/' || r.code || '/';
    v_retry := not p_first and r.state_since < now() - v_timeout
               and coalesce((r.data -> 'retried' ->> r.state)::boolean, false) is not true;
    for v_item in select * from jsonb_array_elements(v_p -> p_kind)
    loop
        -- '*' means every file of the kind, '!W' every one but the wide picture
        continue when p_keys[1] = '!W' and (v_item ->> 'key') = 'W';
        continue when p_keys[1] not in ('*', '!W') and not ((v_item ->> 'key') = any (p_keys));
        v_file := (v_item ->> 'key') || case when p_kind = 'frames' then '.jpg' else '.mp4' end;
        continue when m417_internal.as_exists(r.code, v_file);
        v_missing := v_missing || v_file;
        if p_first or v_retry then
            if p_kind = 'frames' then
                perform m417_internal.as_post(m417_internal.as_set('webhook_frame'), jsonb_build_object(
                    'path', 'auto/' || r.code || '/' || v_file, 'prompt', v_item ->> 'prompt', 'images', v_item -> 'refs'));
            else
                perform m417_internal.as_post(m417_internal.as_set('webhook_clip'), jsonb_build_object(
                    'path', 'auto/' || r.code || '/' || v_file, 'prompt', v_item ->> 'prompt',
                    'image_url', v_dir || (v_item ->> 'frame') || '.jpg'));
            end if;
        end if;
    end loop;
    if v_retry and array_length(v_missing, 1) > 0 then
        update public.auto_shorts
        set data = jsonb_set(data, array['retried'], coalesce(data -> 'retried', '{}'::jsonb) || jsonb_build_object(r.state, true)),
            state_since = now(), updated_at = now()
        where id = p_id;
    end if;
    return v_missing;
end;
$function$;

-- ----- the timer -----------------------------------------------------
create or replace function public.auto_shorts_tick()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    r public.auto_shorts;
    v_timeout interval := make_interval(mins => coalesce(m417_internal.as_set('step_timeout_minutes')::integer, 5));
    v_late interval := make_interval(mins => coalesce(m417_internal.as_set('late_publish_minutes')::integer, 120));
    v_limit integer := coalesce(m417_internal.as_set('daily_limit')::integer, 3);
    v_base text := m417_internal.as_set('storage_base');
    v_day timestamptz := date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul';
    v_missing text[];
    v_p jsonb;
    v_body jsonb;
    v_status integer;
    v_content text;
    v_found boolean;
    v_started integer;
    v_score numeric;
    v_done jsonb := '[]'::jsonb;
begin
    if coalesce(m417_internal.as_set('enabled'), 'false') <> 'true' then
        return jsonb_build_object('note', 'DISABLED');
    end if;
    if not pg_try_advisory_xact_lock(417015) then
        return jsonb_build_object('note', 'BUSY');
    end if;

    -- ===== production: one short at a time =====
    select a.* into r from public.auto_shorts a
    where a.state in ('FRAME_WIDE', 'FRAMES', 'CLIPS', 'RENDERING', 'QC')
    order by a.state_since limit 1 for update;

    if not found then
        select count(*) into v_started from public.auto_shorts a
        where (a.data ->> 'started_at')::timestamptz >= v_day;
        select a.* into r from public.auto_shorts a
        where a.state = 'PLANNED' and a.produce_at <= now()
        order by a.publish_at limit 1 for update;
        if found then
            if r.publish_at < now() - v_late then
                perform m417_internal.as_move(r.id, 'MISSED', jsonb_build_object('reason', 'SLOT_PASSED_BEFORE_PRODUCTION'));
                v_done := v_done || jsonb_build_object('code', r.code, 'to', 'MISSED');
            elsif v_started < v_limit then
                perform m417_internal.as_move(r.id, 'FRAME_WIDE', jsonb_build_object('started_at', now()));
                perform m417_internal.as_request(r.id, 'frames', array['W'], true);
                v_done := v_done || jsonb_build_object('code', r.code, 'to', 'FRAME_WIDE');
            end if;
        end if;

    elsif r.state = 'FRAME_WIDE' then
        v_missing := m417_internal.as_request(r.id, 'frames', array['W'], false);
        if coalesce(array_length(v_missing, 1), 0) = 0 then
            perform m417_internal.as_move(r.id, 'FRAMES');
            perform m417_internal.as_request(r.id, 'frames', array['!W'], true);
            v_done := v_done || jsonb_build_object('code', r.code, 'to', 'FRAMES');
        elsif r.state_since < now() - v_timeout and coalesce((r.data -> 'retried' ->> 'FRAME_WIDE')::boolean, false) then
            perform m417_internal.as_fail(r.id, 'FRAME_NOT_DRAWN', array_to_string(v_missing, ', '));
        end if;

    elsif r.state = 'FRAMES' then
        v_missing := m417_internal.as_request(r.id, 'frames', array['!W'], false);
        if coalesce(array_length(v_missing, 1), 0) = 0 then
            perform m417_internal.as_move(r.id, 'CLIPS');
            perform m417_internal.as_request(r.id, 'clips', array['*'], true);
            v_done := v_done || jsonb_build_object('code', r.code, 'to', 'CLIPS');
        elsif r.state_since < now() - v_timeout and coalesce((r.data -> 'retried' ->> 'FRAMES')::boolean, false) then
            perform m417_internal.as_fail(r.id, 'FRAME_NOT_DRAWN', array_to_string(v_missing, ', '));
        end if;

    elsif r.state = 'CLIPS' then
        v_missing := m417_internal.as_request(r.id, 'clips', array['*'], false);
        if coalesce(array_length(v_missing, 1), 0) = 0 then
            v_p := m417_internal.as_prompts(r.code, r.spec);
            -- a short that is rendered again starts with a clean slate
            perform m417_internal.as_move(r.id, 'RENDERING', jsonb_build_object(
                'render_id', null, 'poll_req', null, 'poll_at', null, 'qc_req', null,
                'render_req', m417_internal.as_post(m417_internal.as_set('webhook_render'),
                    jsonb_build_object('request_text', m417_internal.as_render_request(r.code, v_p)::text), 120000)));
            v_done := v_done || jsonb_build_object('code', r.code, 'to', 'RENDERING');
        elsif r.state_since < now() - v_timeout and coalesce((r.data -> 'retried' ->> 'CLIPS')::boolean, false) then
            perform m417_internal.as_fail(r.id, 'CLIP_NOT_GENERATED', array_to_string(v_missing, ', '));
        end if;

    elsif r.state = 'RENDERING' then
        if r.data ->> 'render_id' is null then
            select true, h.status_code, h.content into v_found, v_status, v_content
            from net._http_response h where h.id = (r.data ->> 'render_req')::bigint;
            if coalesce(v_found, false) then
                begin
                    v_body := v_content::jsonb;
                exception when others then
                    v_body := null;
                end;
                if v_status = 200 and coalesce(v_body ->> 'render_id', '') <> '' then
                    perform m417_internal.as_move(r.id, 'RENDERING', jsonb_build_object('render_id', v_body ->> 'render_id'));
                else
                    perform m417_internal.as_fail(r.id, 'RENDER_NOT_ACCEPTED', coalesce(v_status::text, '') || ' ' || left(coalesce(v_content, ''), 300));
                end if;
            elsif r.state_since < now() - v_timeout then
                perform m417_internal.as_fail(r.id, 'RENDER_NOT_ACCEPTED', 'no answer');
            end if;
        else
            v_found := false;
            if r.data ->> 'poll_req' is not null then
                select true, h.status_code, h.content into v_found, v_status, v_content
                from net._http_response h where h.id = (r.data ->> 'poll_req')::bigint;
            end if;
            if coalesce(v_found, false) then
                begin
                    v_body := v_content::jsonb;
                exception when others then
                    v_body := '{}'::jsonb;
                end;
                if lower(coalesce(v_body ->> 'status', '')) = 'done' and coalesce(v_body ->> 'url', '') like 'http%' then
                    v_p := m417_internal.as_prompts(r.code, r.spec);
                    perform m417_internal.as_move(r.id, 'QC', jsonb_build_object(
                        'render_url', v_body ->> 'url',
                        'qc_req', m417_internal.as_post(m417_internal.as_set('webhook_qc'), jsonb_build_object(
                            'video_url', v_body ->> 'url',
                            'path', 'auto/' || r.code || '/final_' || left(r.data ->> 'render_id', 8) || '.mp4',
                            'prompt', m417_internal.as_qc_prompt(v_p)), 170000)));
                    v_done := v_done || jsonb_build_object('code', r.code, 'to', 'QC');
                elsif lower(coalesce(v_body ->> 'status', '')) = 'failed' then
                    perform m417_internal.as_fail(r.id, 'RENDER_FAILED', left(coalesce(v_content, ''), 300));
                else
                    perform m417_internal.as_move(r.id, 'RENDERING', jsonb_build_object('poll_req', null));
                end if;
            elsif r.state_since < now() - 2 * v_timeout then
                perform m417_internal.as_fail(r.id, 'RENDER_TIMEOUT', r.data ->> 'render_id');
            elsif r.data ->> 'poll_req' is null
                  or coalesce((r.data ->> 'poll_at')::timestamptz, '-infinity') < now() - interval '2 minutes' then
                perform m417_internal.as_move(r.id, 'RENDERING', jsonb_build_object(
                    'poll_at', now(),
                    'poll_req', m417_internal.as_post(m417_internal.as_set('webhook_render'),
                        jsonb_build_object('render_id', r.data ->> 'render_id'), 60000)));
            end if;
        end if;

    elsif r.state = 'QC' then
        select true, h.status_code, h.content into v_found, v_status, v_content
        from net._http_response h where h.id = (r.data ->> 'qc_req')::bigint;
        if coalesce(v_found, false) then
            begin
                v_body := v_content::jsonb;
            exception when others then
                v_body := null;
            end;
            v_score := case when (v_body ->> 'score') ~ '^[0-9]+(\.[0-9]+)?$' then (v_body ->> 'score')::numeric end;
            if v_status = 200 and upper(coalesce(v_body ->> 'verdict', '')) = 'PASS'
               and coalesce(v_score, 0) >= coalesce(m417_internal.as_set('qc_min_score')::numeric, 70)
               and m417_internal.as_exists(r.code, 'final_' || left(r.data ->> 'render_id', 8) || '.mp4')
            then
                perform m417_internal.as_move(r.id, 'READY', jsonb_build_object(
                    'qc', v_body, 'video_url', v_base || 'auto/' || r.code || '/final_' || left(r.data ->> 'render_id', 8) || '.mp4', 'ready_at', now()));
                perform m417_internal.as_notify(format(
                    E'🎬 Hazır: %s\nİzle: %s\nYayın saati: %s\nOtomatik kontrol puanı: %s\n\nYayınlanmasın istersen: %s?code=%s&t=%s',
                    r.title, v_base || 'auto/' || r.code || '/final_' || left(r.data ->> 'render_id', 8) || '.mp4',
                    to_char(r.publish_at at time zone 'Europe/Istanbul', 'DD.MM HH24:MI'),
                    v_score, m417_internal.as_set('webhook_cancel'), r.code, r.cancel_token));
                v_done := v_done || jsonb_build_object('code', r.code, 'to', 'READY');
            else
                update public.auto_shorts set data = data || jsonb_build_object('qc', coalesce(v_body, to_jsonb(left(coalesce(v_content, ''), 300))))
                where id = r.id;
                perform m417_internal.as_fail(r.id, 'CHECK_FAILED',
                    coalesce(v_body ->> 'problems', coalesce(v_status::text, '') || ' ' || left(coalesce(v_content, ''), 300)));
            end if;
        elsif r.state_since < now() - v_timeout then
            perform m417_internal.as_fail(r.id, 'CHECK_NO_ANSWER', null);
        end if;
    end if;

    -- ===== publishing =====
    for r in
        select a.* from public.auto_shorts a
        where a.state = 'READY' and a.publish_at <= now()
        order by a.publish_at for update
    loop
        if r.publish_at < now() - v_late then
            perform m417_internal.as_move(r.id, 'MISSED', jsonb_build_object('reason', 'SLOT_PASSED'));
            perform m417_internal.as_notify(format(E'⏰ Yayın saati kaçtı, yayınlanmadı: %s (%s)', r.title, r.code));
        else
            perform m417_internal.as_move(r.id, 'PUBLISHING', jsonb_build_object(
                'publish_req', m417_internal.as_post(m417_internal.as_set('webhook_publish'), jsonb_build_object(
                    'video_url', r.data ->> 'video_url', 'title', r.title,
                    'description', r.description, 'tags_csv', r.tags_csv), 170000)));
            v_done := v_done || jsonb_build_object('code', r.code, 'to', 'PUBLISHING');
        end if;
    end loop;

    for r in
        select a.* from public.auto_shorts a where a.state = 'PUBLISHING' order by a.state_since for update
    loop
        v_found := false;
        select true, h.status_code, h.content into v_found, v_status, v_content
        from net._http_response h where h.id = (r.data ->> 'publish_req')::bigint;
        if coalesce(v_found, false) then
            begin
                v_body := v_content::jsonb;
            exception when others then
                v_body := null;
            end;
            if v_status = 200 and coalesce(v_body ->> 'video_id', '') <> '' then
                perform m417_internal.as_move(r.id, 'PUBLISHED', jsonb_build_object(
                    'video_id', v_body ->> 'video_id', 'published_at', now(),
                    'url', 'https://www.youtube.com/watch?v=' || (v_body ->> 'video_id')));
                perform m417_internal.as_notify(format(E'✅ Yayınlandı: %s\nhttps://www.youtube.com/watch?v=%s', r.title, v_body ->> 'video_id'));
                v_done := v_done || jsonb_build_object('code', r.code, 'to', 'PUBLISHED');
            else
                -- never upload twice by itself: a person looks first
                perform m417_internal.as_fail(r.id, 'UPLOAD_NOT_CONFIRMED', coalesce(v_status::text, '') || ' ' || left(coalesce(v_content, ''), 300));
            end if;
        elsif r.state_since < now() - v_timeout then
            perform m417_internal.as_fail(r.id, 'UPLOAD_NOT_CONFIRMED', 'no answer; check the channel before trying again');
        end if;
    end loop;

    return jsonb_build_object('moved', v_done);
end;
$function$;

-- ----- owner tools ---------------------------------------------------
create or replace function public.auto_short_plan(
    p_code text, p_title text, p_description text, p_tags_csv text, p_spec jsonb,
    p_produce_at timestamptz, p_publish_at timestamptz)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_p jsonb := m417_internal.as_prompts(p_code, p_spec);
    v_state text;
begin
    select a.state into v_state from public.auto_shorts a where a.code = p_code;
    if v_state is not null and v_state <> 'PLANNED' then
        raise exception 'AUTO_SHORT_ALREADY_STARTED: % is %', p_code, v_state;
    end if;
    insert into public.auto_shorts (code, title, description, tags_csv, spec, produce_at, publish_at)
    values (p_code, p_title, p_description, p_tags_csv, p_spec, p_produce_at, p_publish_at)
    on conflict (code) do update
    set title = excluded.title, description = excluded.description, tags_csv = excluded.tags_csv,
        spec = excluded.spec, produce_at = excluded.produce_at, publish_at = excluded.publish_at, updated_at = now();
    return jsonb_build_object('code', p_code, 'seconds', v_p -> 'seconds', 'expected', v_p -> 'expected');
end;
$function$;

create or replace function public.auto_short_cancel(p_code text, p_token text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    r public.auto_shorts;
begin
    select a.* into r from public.auto_shorts a where a.code = p_code for update;
    if not found or r.cancel_token is distinct from p_token then
        return jsonb_build_object('ok', false, 'message', 'Bağlantı geçersiz.');
    end if;
    if r.state in ('PUBLISHED', 'PUBLISHING') then
        return jsonb_build_object('ok', false, 'message', 'Bu video zaten yayınlandı: ' || r.title);
    end if;
    if r.state = 'CANCELLED' then
        return jsonb_build_object('ok', true, 'message', 'Zaten iptal edilmişti: ' || r.title);
    end if;
    perform m417_internal.as_move(r.id, 'CANCELLED', jsonb_build_object('cancelled_at', now(), 'cancelled_in', r.state));
    return jsonb_build_object('ok', true, 'message', 'İptal edildi, yayınlanmayacak: ' || r.title);
end;
$function$;

create or replace view public.auto_shorts_calendar
with (security_invoker = true) as
    select a.code, a.title, a.state,
           to_char(a.produce_at at time zone 'Europe/Istanbul', 'DD.MM HH24:MI') as produce_tr,
           to_char(a.publish_at at time zone 'Europe/Istanbul', 'DD.MM HH24:MI') as publish_tr,
           a.data ->> 'url' as youtube_url, a.data ->> 'reason' as reason
    from public.auto_shorts a
    order by a.publish_at;

do $$
declare
    v_role text;
    v_fn text;
begin
    foreach v_fn in array array[
        'public.auto_shorts_tick()',
        'public.auto_short_plan(text, text, text, text, jsonb, timestamptz, timestamptz)',
        'public.auto_short_cancel(text, text)']
    loop
        execute format('revoke all on function %s from public', v_fn);
        foreach v_role in array array['anon', 'authenticated'] loop
            if exists (select 1 from pg_roles where rolname = v_role) then
                execute format('revoke all on function %s from %I', v_fn, v_role);
            end if;
        end loop;
        if exists (select 1 from pg_roles where rolname = 'service_role') then
            execute format('grant execute on function %s to service_role', v_fn);
        end if;
    end loop;
    foreach v_role in array array['anon', 'authenticated'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.auto_shorts, public.auto_shorts_settings, public.auto_shorts_calendar, public.auto_wardrobe from %I', v_role);
        end if;
    end loop;
end $$;

notify pgrst, 'reload schema';

commit;
