-- Calendar 11-13 October: clothes follow the place. Run after
-- 2026-10-11_to_13.sql; only touches shorts that are still PLANNED.
update public.auto_shorts set spec = spec || '{"wardrobe": "home"}'::jsonb, updated_at = now()
where code in ('AS-1011-1500', 'AS-1012-1500', 'AS-1013-2000') and state = 'PLANNED';

-- the magic show is a dressed-up occasion
update public.auto_shorts set spec = spec || '{"wardrobe": "party"}'::jsonb, updated_at = now()
where code = 'AS-1011-2000' and state = 'PLANNED';

-- the missing sock is a morning in pajamas
update public.auto_shorts set spec = spec || '{"wardrobe": "pajamas"}'::jsonb, updated_at = now()
where code = 'AS-1012-2000' and state = 'PLANNED';

update public.auto_shorts set spec = spec || '{"wardrobe": "park"}'::jsonb, updated_at = now()
where code = 'AS-1013-0200' and state = 'PLANNED';

-- the balloon moves out into the garden
update public.auto_shorts set updated_at = now(), spec = jsonb_set(jsonb_set(
    spec || $j${
      "wardrobe": "park",
      "place": "A green garden with a wooden fence, a flower bed, a wooden picnic table and blue sky, warm golden afternoon light from the left.",
      "wide_pose": "stand side by side on the grass, the other two looking at the balloon with big eyes"
    }$j$::jsonb,
    '{s1,action}', to_jsonb('A sunny garden: three children stand side by side on the grass. The boy on the right holds one huge red balloon by its untied neck with both hands; the balloon wobbles and squeaks a little. The other two stare at it.'::text)),
    '{s3}', (spec -> 's3') || $j${
      "frame": "Medium-wide view of the same sunny garden with nobody in it: the grass, the wooden fence and the wooden picnic table. Exactly one huge round red balloon with an untied neck floats in the air in the middle of the garden. No people, no hands, no animals.",
      "action": "A sunny garden with nobody in it and one huge red balloon with an untied neck in the air. The balloon suddenly shoots off and zooms around the garden in fast loops, shrinking as the air rushes out with a long, silly, sputtering sound, and finally lands, tiny and wrinkled, flat on the wooden picnic table. Right after that, three children's voices from off-screen burst out laughing.",
      "expect": "A red balloon zooms around the garden with a silly sputtering sound and lands on the picnic table; children laugh off-screen."
    }$j$::jsonb)
where code = 'AS-1012-0200' and state = 'PLANNED';

-- the cookie is shared at school
update public.auto_shorts set updated_at = now(), spec = jsonb_set(jsonb_set(
    spec || $j${
      "wardrobe": "school",
      "place": "A bright school cafeteria with long light wooden tables, colorful chairs and big windows, warm golden daylight from the left.",
      "setup": "In the middle of the light wooden table in front stands exactly one blue plate with exactly one big round chocolate chip cookie on it."
    }$j$::jsonb,
    '{s1,action}', to_jsonb('A bright school cafeteria: three children sit behind a table and stare at one big chocolate chip cookie on a blue plate. All three lick their lips and lean a little closer.'::text)),
    '{s3}', (spec -> 's3') || jsonb_build_object(
      'frame', replace(spec -> 's3' ->> 'frame', 'The kitchen is softly blurred behind him.', 'The cafeteria is softly blurred behind him.'),
      'action', replace(spec -> 's3' ->> 'action', 'at a kitchen table', 'at a school cafeteria table')))
where code = 'AS-1013-1500' and state = 'PLANNED';

-- the jelly stands on a birthday table
update public.auto_shorts set updated_at = now(), spec = jsonb_set(jsonb_set(
    spec || $j${
      "wardrobe": "party",
      "place": "A living room decorated for a birthday party with colorful balloons and plain paper garlands without letters on the wall, warm golden afternoon light from a window on the left.",
      "setup": "In the middle of a table with a white tablecloth stands exactly one white plate with exactly one giant shiny red jelly dome, as big as a football, perfectly still."
    }$j$::jsonb,
    '{s1,action}', to_jsonb('A birthday party in a living room: three children sit behind a table and stare at one giant shiny red jelly on a plate. The jelly glistens and stands perfectly still. The chubby boy in the middle slowly lifts one finger toward it.'::text)),
    '{s3}', (spec -> 's3') || jsonb_build_object(
      'frame', replace(spec -> 's3' ->> 'frame', 'The kitchen is softly blurred behind it.', 'The party room is softly blurred behind it.'),
      'action', replace(spec -> 's3' ->> 'action', 'on a plate on a kitchen table', 'on a plate on a party table')))
where code = 'AS-1014-0200' and state = 'PLANNED';

select a.code, a.spec ->> 'wardrobe' as wardrobe, left(a.spec ->> 'place', 40) as place,
       (m417_internal.as_prompts(a.code, a.spec) ->> 'seconds') as seconds
from public.auto_shorts a order by a.publish_at;

-- 10 October: the first automatic run (AS-1011-0200, the giant egg) stopped
-- because Google refused the close-up clip of Mia twice. It was planned
-- again as AS-1011-0200B with Tombik in that scene and the home wardrobe.
-- Rule since then: Mia is in group shots, not alone in a close-up clip.
