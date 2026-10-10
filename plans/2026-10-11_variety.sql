-- 10 October, 20:48: the owner wants Bruce and Ömer in the videos, other
-- places (dance class, park, school) and no more "something comes out of
-- a container" after the box and the egg. The magic hat and the dinner
-- dome are dropped; three new shorts open the calendar and the others
-- move back. Only PLANNED rows are touched; reads see the old calendar.
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. More funny cartoon shorts every week!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,' as tags
), old as materialized (
    select code, title, description, tags_csv, spec from public.auto_shorts where state = 'PLANNED'
), fresh(code, title, l1, l2, hashtag, extra_tags, produce_at, publish_at, spec) as (values

('AS-1011-1500', 'Freeze Dance! Who Moves First? 🕺',
 'Freeze dance! Can Bruce, Ömer and Tombik stay still in this funny kids cartoon?',
 'The friends dance in the studio until Ömer shouts freeze. Everybody turns into a statue, but one of them has very wiggly legs. Watch to the end to see who moves first!',
 'freezedance', 'freeze dance,dance for kids,kids dance,dance game,funny dance,bruce,omer,tombik',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 12:00+00'::timestamptz, $j${
  "wardrobe": "dance",
  "place": "A bright dance studio with a light wooden floor, a wooden ballet barre on a pastel yellow wall and big windows, warm golden afternoon light from the left.",
  "setup": "There is nothing else in the room: no mirror, no posters, no writing.",
  "cast": ["BRUCE", "TOMBIK", "OMER"],
  "wide_pose": "stand in a row in the middle of the floor in happy dance poses, arms up, one foot lifted, with big smiles",
  "s1": {"seconds": 4, "action": "A bright dance studio: three children dance side by side with big, funny moves, arms waving, hips wiggling, sneakers squeaking on the floor.", "speaker": "OMER", "gesture": "throws both arms up", "verb": "shouts", "voice": "a loud, playful", "line": "Freeze!", "sounds": "the squeak of sneakers on the floor", "rule": "At the word all three freeze in silly poses and stay perfectly still until the end."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "frozen in a funny pose with one arm up, cheeks puffed, lips pressed together, eyes wide", "action": "He stands frozen in a silly pose with one arm up and his cheeks puffed, wobbles a little, his eyes dart left and right, his lips tremble", "verb": "squeaks", "voice": "a tiny, strained", "line": "Must... not... move!", "after": "keeps wobbling"},
  "s3": {"seconds": 3, "char": "TOMBIK", "frame": "Medium shot at eye level on {CHAR}, standing in the same dance studio, his whole upper body visible, frozen in a funny pose with one arm up and his cheeks puffed, mouth closed. The studio is softly blurred behind him. Only this one boy, nobody else, no animals.", "action": "Medium shot on {CHAR}, in a bright dance studio, frozen in a funny pose. He wobbles more and more, then cannot hold it any longer: he bursts out giggling and breaks into a wild, happy wiggle dance, arms waving, and shouts in a laughing cartoon boy voice: \"I can't stop dancing!\" His mouth forms every word clearly, exactly in sync with his voice. He says only these four words, once, in English, and keeps dancing until the end.", "sounds": "his giggle, his voice, the squeak of his sneakers", "guard": "Only Tombik is in the frame, nobody else appears,", "expect": "Tombik cannot stay frozen, starts a wild wiggle dance and shouts: \"I can't stop dancing!\""},
  "s4": {"seconds": 3, "pose": "stand close together with big smiles, arms around each other's shoulders, looking at the camera", "action": "All three laugh out loud together, then bounce and dance on the spot with their arms in the air, happy and silly."}
 }$j$::jsonb),

('AS-1011-2000', 'Super Kick Gone Wrong! ⚽',
 'Watch the super kick! Ömer, Bruce and Fatih play football in this funny kids cartoon!',
 'Ömer wants to show his best kick ever and Bruce is ready in goal. But something flies much higher than the ball. Watch to the end for the funny surprise!',
 'football', 'football for kids,soccer cartoon,super kick,funny football,park fun,bruce,omer,fatih',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 17:00+00'::timestamptz, $j${
  "wardrobe": "park",
  "place": "A green park with a wide lawn, a few trees and a wooden bench far in the background, blue sky, warm golden afternoon light from the left.",
  "setup": "On the grass in front of the boy in the middle lies exactly one black-and-white football.",
  "cast": ["BRUCE", "OMER", "FATIH"],
  "wide_pose": "stand on the grass, the boy in the middle with one foot next to the ball and his hands on his hips, the other two watching him",
  "guard": "exactly one football",
  "s1": {"seconds": 4, "action": "A sunny park: three children stand on the grass. The boy in the middle stands proudly next to a football and stretches one leg; the other two watch him with curious faces.", "speaker": "OMER", "gesture": "points at the ball", "verb": "shouts", "voice": "a proud, confident", "line": "Watch my super kick!", "rule": "Nobody kicks the ball yet; it stays on the grass."},
  "s2": {"seconds": 3, "char": "BRUCE", "pose": "a calm little smile, both hands raised in front of him like a goalkeeper", "action": "He bends his knees a little, raises both hands like a goalkeeper, nods with a calm little smile", "verb": "says", "voice": "a calm, cool", "line": "I am ready!", "after": "keeps his hands up"},
  "s3": {"seconds": 3, "frame": "Close-up at grass height on the same black-and-white football lying still on the grass of the same park, filling the lower middle of the frame. The lawn and the trees are softly blurred behind it. Exactly one football. No people, no feet, no animals.", "action": "Close-up on one football lying still on the grass in a sunny park. A child's leg in black shorts and a white sneaker swings in from the right with a big whoosh and misses the ball completely; the white sneaker flies off the foot and sails up out of the frame, and a moment later it drops back down from above and lands softly right on top of the ball. The ball has not moved at all. A boy's voice from off-screen says, embarrassed: \"Oops!\"", "sounds": "the whoosh of the kick, the soft thud of the sneaker, the boy's \"Oops!\"", "guard": "Exactly one football and one sneaker. No faces in the frame,", "expect": "A kick misses the ball, a white sneaker flies off, comes back down and lands on the ball; a boy's voice says \"Oops!\""}
 }$j$::jsonb),

('AS-1012-0200', 'My Robot Can Dance?! 🤖',
 'Can a cardboard robot dance? Bruce, Ömer and Mia find out in this funny kids cartoon!',
 'Bruce brings his homemade robot to school and Ömer does not believe it can do anything. Then the little robot wakes up. Watch to the end for its funny dance!',
 'robot', 'robot cartoon,robot for kids,dancing robot,school cartoon,show and tell,bruce,omer,mia',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 23:00+00'::timestamptz, $j${
  "wardrobe": "school",
  "place": "A bright classroom with small light wooden desks, colorful chairs, shelves with books and big windows, warm golden daylight from the left. The walls are plain, with no board, no posters and no writing.",
  "setup": "On the desk in front stands exactly one small homemade robot made of grey cardboard boxes, about as tall as a shoebox, with a square head, two bottle-cap eyes and two short cardboard arms, standing still.",
  "cast": ["BRUCE", "OMER", "MIA"],
  "wide_pose": "stand behind the desk, the boy on the left with one open hand next to the robot, proudly presenting it, the other two leaning in with curious eyes",
  "guard": "exactly one cardboard robot",
  "s1": {"seconds": 4, "action": "A bright classroom: three children stand behind a desk with one small cardboard robot on it. The boy on the left proudly presents the robot with one open hand; the other two lean in and look at it with curious eyes.", "speaker": "BRUCE", "gesture": "taps the robot gently on its head", "verb": "says", "voice": "a proud, calm", "line": "Meet my robot!", "rule": "The robot does not move yet."},
  "s2": {"seconds": 3, "char": "OMER", "pose": "one eyebrow raised, a cheeky grin, looking down at the robot", "foreground": "The square cardboard head of the little robot is", "fg_clip": "with the square cardboard head of a little robot in the foreground", "action": "He raises one eyebrow, grins cheekily, points down at the robot", "verb": "asks", "voice": "a cheeky, doubtful", "line": "Can it dance?", "after": "keeps grinning", "rule": "The robot does not move."},
  "s3": {"seconds": 3, "frame": "Close-up at desk height on the same small homemade cardboard robot with the square head, two bottle-cap eyes and two short cardboard arms, standing still in the middle of the desk and filling the middle of the frame. The classroom is softly blurred behind it. Exactly one robot. No people, no hands, no animals.", "action": "Close-up on one small cardboard robot standing on a school desk. Its bottle-cap eyes light up yellow with a soft beep, its square head spins once all the way around, and then the little robot does a funny wiggle dance: it rocks from side to side, swings its short cardboard arms up and down and makes happy beep-boop sounds in rhythm. Right after it starts, three children's voices from off-screen gasp: \"Whoa!\" The robot keeps dancing until the end.", "sounds": "the beeps and beep-boop sounds of the robot, the children's \"Whoa!\"", "guard": "Exactly one robot. No people in the frame, no hands,", "expect": "The cardboard robot's eyes light up, its head spins and it does a wiggle dance with beep-boop sounds; children's voices say \"Whoa!\""}
 }$j$::jsonb)
), moved(code, from_code, produce_at, publish_at) as (values
    ('AS-1012-1500', 'AS-1011-1500', '2026-10-12 07:00+00'::timestamptz, '2026-10-12 12:00+00'::timestamptz),  -- puppy
    ('AS-1012-2000', 'AS-1012-0200', '2026-10-12 07:00+00', '2026-10-12 17:00+00'),                          -- balloon
    ('AS-1013-0200', 'AS-1012-2000', '2026-10-12 07:00+00', '2026-10-12 23:00+00'),                          -- sock
    ('AS-1013-1500', 'AS-1013-1500', '2026-10-13 07:00+00', '2026-10-13 12:00+00'),                          -- cookie
    ('AS-1013-2000', 'AS-1013-2000', '2026-10-13 07:00+00', '2026-10-13 17:00+00'),                          -- band
    ('AS-1014-0200', 'AS-1013-0200', '2026-10-13 07:00+00', '2026-10-13 23:00+00'),                          -- bubble
    ('AS-1014-1500', 'AS-1014-0200', '2026-10-14 07:00+00', '2026-10-14 12:00+00')                           -- jelly
), todo as (
    select f.code, f.title,
           f.l1 || E'\n' || f.l2 || E'\n' || x.brand || E'\n#shorts #cartoon #kidscartoon #funnycartoon #' || f.hashtag as description,
           x.tags || f.extra_tags as tags_csv, f.spec, f.produce_at, f.publish_at
    from fresh f cross join fixed x
    union all
    select m.code, o.title, o.description, o.tags_csv, o.spec, m.produce_at, m.publish_at
    from moved m join old o on o.code = m.from_code
)
select t.code, t.title, public.auto_short_plan(t.code, t.title, t.description, t.tags_csv, t.spec, t.produce_at, t.publish_at) ->> 'seconds' as seconds
from todo t order by t.publish_at;
