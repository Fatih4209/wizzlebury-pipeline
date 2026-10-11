-- 11 October, evening. The owner: the cut-up gag shorts feel cold and wrong.
-- He wants everyday life (classroom, way to school, canteen, sports lesson)
-- filmed like a real video: ONE camera, ONE take, the camera turning from
-- the one who speaks to the next. The whole old calendar was parked (times
-- moved by 30 days, spec.parked says so); these three are the first tests.
--
-- NOT APPLIED YET: on 11 October at about 11:10 Google answered
--   [402] Your prepayment credits are depleted
-- (the failed robot clip, the failed look request and both tries to draw the
-- teacher were this, not the daily clip limit). Run this after the owner has
-- topped up the credit AND auto/refs/TEACHER_REF_V1.jpg has been drawn and
-- looked at; set the times then.
--
-- Rules of a one-take spec: everybody who appears is in the first picture;
-- two or three short lines; nothing written anywhere; about 10 seconds (the
-- longest length the video model is known to give; 15 is still to be tried).
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. New videos every day!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,videos for kids,animation for kids,school cartoon,' as tags
), fresh(code, title, l1, l2, hashtags, extra_tags, produce_at, publish_at, spec) as (values

('OT-1012-1500', 'Funny Answer in Class! 🍎😂',
 'The teacher asks a question in class and Tombik has a very funny answer in this kids cartoon!',
 'What is this? An apple... or Tombik''s lunch? A warm, funny school moment with Mia, Tombik and Ömer. Watch to the end!',
 '#school #classroom #funnykids', 'classroom,funny answer,teacher and students,school for kids,funny kids,mia,tombik,omer',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 12:00+00'::timestamptz, $j${
  "kind": "onetake", "wardrobe": "school", "adult": "TEACHER", "seconds": 10,
  "place": "A bright, cozy classroom with light wooden desks, a plain green board without any writing and big windows, warm morning light from the left.",
  "scene": "The teacher stands on the right side at the front, holding one red apple in her hand. Three children sit side by side at their desks on the left and in the middle, turned toward her.",
  "cast": ["MIA", "TOMBIK", "OMER"],
  "action": "The teacher holds up the red apple, smiles and asks in a warm, friendly woman's voice: \"Who knows what this is?\" The camera turns to the children. {2} shoots his hand up, bouncing on his chair, and shouts in a happy, cheeky cartoon boy voice: \"My lunch!\" {1} and {3} burst out laughing. The camera turns back to the teacher, who laughs warmly too and shakes her head with a smile.",
  "sounds": "the voices, the children's laughter, the teacher's soft laugh",
  "expect": ["The teacher holds up an apple and asks: \"Who knows what this is?\"", "Tombik raises his hand and shouts: \"My lunch!\"", "The other children and the teacher laugh."]
 }$j$::jsonb),

('OT-1012-2000', 'School Bus Sing-Along! 🚌🎵',
 'Bruce, Mia and Fatih sing and clap on the school bus in this happy kids cartoon!',
 'Clap, clap, clap your hands! Jump, jump, jump around! The way to school is more fun with a song. Sing along!',
 '#schoolbus #kidssongs #singalong', 'school bus,sing along,kids songs,clap your hands,way to school,bruce,mia,fatih',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 17:00+00'::timestamptz, $j${
  "kind": "onetake", "wardrobe": "school", "seconds": 10, "music": false,
  "place": "Inside a yellow school bus in the morning: rows of green seats, big windows with trees and houses passing by outside, warm sunlight falling in.",
  "scene": "Three children sit side by side on the wide back seat, facing the camera, with their backpacks beside them and their hands on their knees.",
  "cast": ["BRUCE", "MIA", "FATIH"],
  "action": "The bus hums along and a cheerful children's song starts to play on the bus radio. {2} starts to clap to the beat and sings in a bright, happy voice: \"Clap, clap, clap your hands!\" The camera moves over to {1} and {3}, who grin and join in, and then all three clap and sing together: \"Jump, jump, jump around!\" They sway from side to side on the seat and laugh.",
  "sounds": "a cheerful children's song with ukulele and hand claps from the bus radio, the children's singing and laughing, the soft hum of the bus",
  "expect": ["Three children sit on the back seat of a school bus; music plays.", "Mia claps and sings: \"Clap, clap, clap your hands!\"", "All three clap and sing together: \"Jump, jump, jump around!\" and laugh."]
 }$j$::jsonb),

('OT-1013-0200', 'Where Is Your Lunch?! 😂',
 'Lunch time at school! Tombik''s tray is already empty in this funny, warm kids cartoon.',
 'Ömer cannot believe it, and Mia has a kind idea. A little story about sharing with Ömer, Tombik and Mia. Watch to the end!',
 '#school #lunchtime #sharing', 'school lunch,canteen,sharing is caring,funny kids,kind kids,omer,tombik,mia',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 23:00+00'::timestamptz, $j${
  "kind": "onetake", "wardrobe": "school", "seconds": 10,
  "place": "A bright school canteen with long light wooden tables, colourful chairs and big windows, warm midday light from the left.",
  "scene": "Three children sit side by side behind a table, each with a lunch tray in front of them. On the trays of the child on the left and the child on the right lie one sandwich and one red apple each; the tray of the boy in the middle is already empty, with only a few crumbs on it.",
  "cast": ["OMER", "TOMBIK", "MIA"],
  "action": "{1} looks at the empty tray in the middle with big eyes and asks in a surprised cartoon boy voice: \"Where is your lunch?\" The camera turns to {2}, who pats his round belly with both hands, grins and says in a happy, cheeky cartoon boy voice: \"Already gone!\" The camera turns to {3}, who giggles, picks up her red apple, holds it out to him and says in a kind, cheerful cartoon child voice: \"Here, take mine!\" All three laugh.",
  "sounds": "the voices, the children's laughter, soft canteen sounds in the background",
  "expect": ["Ömer looks at Tombik's empty tray and asks: \"Where is your lunch?\"", "Tombik pats his belly and says: \"Already gone!\"", "Mia holds out her apple and says: \"Here, take mine!\"; they laugh."]
 }$j$::jsonb)
)
select f.code, f.title,
       public.auto_short_plan(f.code, f.title,
           f.l1 || E'\n' || f.l2 || E'\n' || x.brand || E'\n#shorts #cartoon #kidscartoon ' || f.hashtags,
           x.tags || f.extra_tags, f.spec, f.produce_at, f.publish_at) ->> 'seconds' as seconds
from fresh f cross join fixed x order by f.publish_at;
