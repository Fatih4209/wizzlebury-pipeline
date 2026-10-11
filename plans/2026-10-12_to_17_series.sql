-- 10 October, late evening. The owner: "apply these now": a dance song
-- every day, the magic bottle as a series, a funny moment in the dances.
--   15:00 every day (12-15 Oct): a dance short with its own song.
--   20:00 on 13 and 15 Oct: the magic bottle lands on the moon / in the snow.
--   The shorts that had those slots move to 16-17 Oct (codes unchanged).
-- One statement, only rows that are still PLANNED.
--
-- Songs (auto/songs/, sung twice, 30 s). Measured line starts in seconds:
--   DINO_STOMP_V1        0.2  3.9  7.6  11.3  (verse ends 14.5)
--   WIGGLE_JELLY_V1      0.1  3.9  7.7  11.4  (14.6)
--   SILLY_MONKEY_V1      0.2  3.9  7.6  11.3  (14.4)
--   HANDS_UP_HOORAY_V1   0.2  3.8  7.5  11.2  (14.4)
-- With trim 0 and four shots of 4 s (0-4, 3.5-7.5, 7-11, 10.5-14.5 after
-- the 0.5 s fades) every line has its own shot; the film is 14.5 s.
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. More funny cartoon shorts every week!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,videos for kids,animation for kids,' as tags
), old as materialized (
    select code, title, description, tags_csv, spec, produce_at, publish_at from public.auto_shorts where state = 'PLANNED'
), fresh(code, title, l1, l2, hashtags, extra_tags, produce_at, publish_at, spec) as (values

('AS-1012-1500-SONG', 'Dinosaur Stomp! 🦖 Kids Dance Song',
 'Stomp like a dinosaur, hop like a kangaroo and flap like a little bird with Ömer, Tombik and Bruce! A happy dance song for kids.',
 'Stomp, stomp, like a dinosaur! Hop, hop, like a kangaroo! Flap, flap, like a little bird! Roar out loud! Can you do all the moves? Dance along!',
 '#kidssongs #dancesong #dinosaur', 'kids dance song,dance song for kids,kids songs,action song,dinosaur song,animal dance,omer,tombik,bruce',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 12:00+00'::timestamptz, $j${
  "kind": "dance",
  "wardrobe": "school",
  "place": "A bright school gym with a shiny light wooden floor, colourful soft mats stacked against the wall and tall windows, warm daylight from the left.",
  "cast": ["OMER", "TOMBIK", "BRUCE"],
  "song": {"file": "auto/songs/DINO_STOMP_V1.mp3", "trim": 0, "volume": 0.9},
  "moves": [
    {"seconds": 4, "move": "All three stomp heavily on the spot like dinosaurs, lifting their knees high, with their arms bent in front of them like little dinosaur arms."},
    {"seconds": 4, "move": "All three hop up and down like kangaroos, with their hands held in front of their chests like paws."},
    {"seconds": 4, "move": "All three flap their arms up and down like little birds, bouncing on their tiptoes."},
    {"seconds": 4, "move": "All three pretend to roar like playful little dinosaurs with wide open mouths and scrunched noses, then burst out laughing together."}
  ]
 }$j$::jsonb),

('AS-1013-1500-SONG', 'Wiggle Like a Jelly! 🍮 Kids Dance Song',
 'Wiggle, wobble and spin with Fatih, Tombik and Bruce until everybody falls down! A funny dance song for kids.',
 'Wiggle, wiggle, like a jelly! Wobble, wobble, shake your belly! Round and round and round we go, fall down, boom! Dance along and laugh out loud!',
 '#kidssongs #dancesong #wiggle', 'kids dance song,dance song for kids,kids songs,action song,wiggle song,funny dance,fatih,tombik,bruce',
 '2026-10-13 07:00+00'::timestamptz, '2026-10-13 12:00+00'::timestamptz, $j${
  "kind": "dance",
  "wardrobe": "park",
  "place": "A sunny garden with soft green grass, a wooden fence and a flower bed softly blurred in the background, blue sky and warm golden light from the left.",
  "cast": ["FATIH", "TOMBIK", "BRUCE"],
  "song": {"file": "auto/songs/WIGGLE_JELLY_V1.mp3", "trim": 0, "volume": 0.9},
  "moves": [
    {"seconds": 4, "move": "All three wiggle their whole bodies like wobbly jelly, with loose, shaking arms."},
    {"seconds": 4, "move": "All three wobble from side to side and shake their bellies, patting them with both hands."},
    {"seconds": 4, "move": "All three spin round and round on the spot with their arms stretched out, get dizzy, wobble and plop down softly onto the grass on their bottoms."},
    {"seconds": 4, "move": "All three sway a little with dizzy, silly smiles, then burst out laughing together and look at each other."}
  ]
 }$j$::jsonb),

('AS-1014-1500-SONG', 'Silly Monkey Dance! 🐵 Kids Dance Song',
 'Swing your arms and scratch like a monkey with Mia, Fatih and Ömer! A silly dance song for kids.',
 'Swing, swing, swing your arms! Scratch, scratch, like a monkey! Stomp your feet and turn around, silly faces! Can you make the silliest face? Dance along!',
 '#kidssongs #dancesong #monkey', 'kids dance song,dance song for kids,kids songs,action song,monkey dance,silly faces,mia,fatih,omer',
 '2026-10-14 07:00+00'::timestamptz, '2026-10-14 12:00+00'::timestamptz, $j${
  "kind": "dance",
  "wardrobe": "dance",
  "place": "A bright dance studio with a light wooden floor, a plain pastel yellow wall with a wooden ballet barre and tall windows with white curtains, warm daylight from the left.",
  "cast": ["MIA", "FATIH", "OMER"],
  "song": {"file": "auto/songs/SILLY_MONKEY_V1.mp3", "trim": 0, "volume": 0.9},
  "moves": [
    {"seconds": 4, "move": "All three swing both arms from side to side like monkeys, bouncing on bent knees."},
    {"seconds": 4, "move": "All three scratch the tops of their heads with one hand and their sides with the other like cheeky monkeys, bouncing up and down."},
    {"seconds": 4, "move": "All three stomp their feet four times, then turn around once on the spot."},
    {"seconds": 4, "move": "All three pull silly faces, puffing their cheeks and wiggling their eyebrows, then burst out laughing together."}
  ]
 }$j$::jsonb),

('AS-1015-1500-SONG', 'Hands Up Hooray! 🙌 Kids Dance Song',
 'Hands up to the sky, touch your toes and shake your body with Bruce, Mia and Tombik! A happy dance song for kids.',
 'Hands up, up, up to the sky! Hands down, down, touch your toes! Shake, shake, shake your body, shout hooray! Dance along and watch it again!',
 '#kidssongs #dancesong #handsup', 'kids dance song,dance song for kids,kids songs,action song,hands up song,exercise for kids,bruce,mia,tombik',
 '2026-10-15 07:00+00'::timestamptz, '2026-10-15 12:00+00'::timestamptz, $j${
  "kind": "dance",
  "wardrobe": "home",
  "place": "A cozy living room with a soft beige sofa in the background, a round rug on a wooden floor and warm golden afternoon light from a window on the left.",
  "cast": ["BRUCE", "MIA", "TOMBIK"],
  "song": {"file": "auto/songs/HANDS_UP_HOORAY_V1.mp3", "trim": 0, "volume": 0.9},
  "moves": [
    {"seconds": 4, "move": "All three stretch both hands up high and wave them, rising onto their tiptoes."},
    {"seconds": 4, "move": "All three bend down to touch their toes, dipping out of the picture, and pop back up with big smiles."},
    {"seconds": 4, "move": "All three shake their whole bodies from head to toe with loose arms, bouncing on the spot."},
    {"seconds": 4, "move": "All three throw their heads back and cheer with wide open mouths, then burst out laughing together."}
  ]
 }$j$::jsonb),

('AS-1013-2000-BOTTLE', 'Magic Bottle! We''re on the MOON?! 🌙✨',
 'A magic bottle in the park! Bruce, Ömer and Fatih pull the cork in this funny kids cartoon. Where will it take them?',
 'The bottle glows like starlight, Ömer is brave enough to open it and... POP! Watch to the end to see where they land!',
 '#magic #moon #surprise', 'magic bottle,magic cartoon,moon cartoon,space for kids,magic for kids,surprise,bruce,omer,fatih',
 '2026-10-13 07:00+00'::timestamptz, '2026-10-13 17:00+00'::timestamptz, $j${
  "wardrobe": "park",
  "place": "A sunny park with soft green grass, a big tree and a wooden bench softly blurred in the background, blue sky and warm golden light from the left.",
  "setup": "In the grass in front of them stands exactly one small round glass bottle with a cork, filled with softly glowing, swirling silver-blue starlight.",
  "cast": ["BRUCE", "OMER", "FATIH"],
  "wide_pose": "crouch in the grass in a half circle behind the glowing bottle and stare at it with big amazed eyes, the silver-blue light shining on their faces",
  "guard": "exactly one glass bottle",
  "s1": {"seconds": 4, "action": "A sunny park: three children crouch in the grass behind one small glass bottle that glows with swirling silver-blue starlight. The light flickers on their amazed faces.", "speaker": "BRUCE", "gesture": "points at the bottle with one hand", "verb": "shouts", "voice": "an amazed", "line": "Whoa! A magic bottle!", "sounds": "a soft magical hum", "rule": "Nobody touches the bottle yet; the cork stays in."},
  "s2": {"seconds": 3, "char": "OMER", "pose": "a brave, excited grin, one fist raised", "foreground": "The round top of the glowing glass bottle with its cork is", "fg_clip": "with the top of a glowing glass bottle in the foreground", "action": "He raises one fist with a brave, excited grin", "verb": "shouts", "voice": "a brave, excited", "line": "I will open it!", "after": "keeps grinning", "sounds": "a soft magical hum"},
  "s3": {"seconds": 4, "char": "OMER", "frame": "Medium shot at eye level on {CHAR}, crouching in the same grass in the same park, holding the same small round glass bottle in one hand and gripping its cork with the other hand, eyes squeezed shut, mouth closed. The bottle glows with swirling silver-blue starlight. Only this one boy, nobody else, no animals.", "action": "Medium shot on {CHAR}, crouching in the grass in a sunny park, holding a small round glass bottle that glows with swirling silver-blue starlight. He pulls the cork out with a loud pop. A swirl of sparkling silver stars shoots out of the bottle, spins around him faster and faster and fills the whole picture with bright silver-white light, until only the bright light can be seen.", "sounds": "the loud pop of the cork, a rising magical whoosh, sparkling chimes", "guard": "Only Ömer is in the frame, nobody else appears,", "expect": "Ömer pulls the cork out of the glowing bottle with a pop; sparkling stars swirl out and fill the picture with bright light, so that he disappears in the light (this is wanted)."},
  "s4": {"seconds": 4, "place": "The surface of the moon: soft grey ground with round craters, a black sky full of twinkling stars and the big blue Earth shining above the horizon, bright clear light.", "pose": "look up at the big blue Earth with wide, amazed eyes", "sounds": "soft sparkling chimes", "expect": "The same three children now stand on the moon with the blue Earth in the sky (this change of place is wanted), look around amazed and then laugh together; nobody speaks."}
 }$j$::jsonb),

('AS-1015-2000-BOTTLE', 'Don''t Open the Magic Bottle! ❄️😂',
 'Don''t open the magic bottle! Mia warns Tombik, but it is too late in this funny kids cartoon.',
 'It is bedtime, the bottle glows icy blue and Tombik cannot wait. POP! Watch to the end to see where they land in their pajamas!',
 '#magic #snow #surprise', 'magic bottle,magic cartoon,snow cartoon,snowman,magic for kids,surprise,tombik,mia,bruce',
 '2026-10-15 07:00+00'::timestamptz, '2026-10-15 17:00+00'::timestamptz, $j${
  "wardrobe": "pajamas",
  "place": "A cozy children's bedroom in the evening with a bed with a plain blue blanket in the background, a soft round rug on a wooden floor and warm light from a bedside lamp on the left.",
  "setup": "In the middle of the rug stands exactly one small round glass bottle with a cork, filled with softly glowing, swirling icy-blue light.",
  "cast": ["TOMBIK", "MIA", "BRUCE"],
  "wide_pose": "sit on the rug in a half circle behind the glowing bottle; the chubby boy on the left stretches one hand toward it with a cheeky grin, the other two look at him with worried eyes",
  "guard": "exactly one glass bottle",
  "s1": {"seconds": 4, "action": "A cozy bedroom in the evening: three children in pajamas sit on a rug behind one small glass bottle that glows with swirling icy-blue light. The chubby boy on the left slowly stretches one hand toward the cork.", "speaker": "MIA", "gesture": "holds up both hands", "verb": "shouts", "voice": "a worried", "line": "Don't open it!", "sounds": "a soft magical hum", "rule": "Nobody touches the bottle yet; the cork stays in."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "a cheeky grin, eyebrows raised", "foreground": "The round top of the glowing glass bottle with its cork is", "fg_clip": "with the top of a glowing glass bottle in the foreground", "action": "He grins cheekily and wiggles his eyebrows", "verb": "says", "voice": "a cheeky, giggling", "line": "Too late! Hee hee!", "after": "keeps grinning", "sounds": "a soft magical hum"},
  "s3": {"seconds": 4, "char": "TOMBIK", "frame": "Medium shot at eye level on {CHAR}, sitting on the same round rug in the same bedroom, holding the same small round glass bottle in one hand and gripping its cork with the other hand, a cheeky grin, mouth closed. The bottle glows with swirling icy-blue light. Only this one boy, nobody else, no animals.", "action": "Medium shot on {CHAR}, sitting on a rug in a cozy bedroom, holding a small round glass bottle that glows with swirling icy-blue light. He pulls the cork out with a loud pop. A swirl of sparkling snowflakes shoots out of the bottle, spins around him faster and faster and fills the whole picture with bright white light, until only the bright light can be seen.", "sounds": "the loud pop of the cork, a rising magical whoosh, sparkling chimes", "guard": "Only Tombik is in the frame, nobody else appears,", "expect": "Tombik pulls the cork out of the glowing bottle with a pop; sparkling snowflakes swirl out and fill the picture with bright light, so that he disappears in the light (this is wanted)."},
  "s4": {"seconds": 4, "place": "A sparkling snow world: soft white snow hills, snow-covered pine trees, a friendly snowman with a carrot nose and a red scarf in the background, big soft snowflakes falling from a pale blue sky.", "pose": "hug themselves and look around with wide, surprised eyes", "action": "All three shiver and look around with wide, surprised eyes and open mouths for a moment, then look at each other and burst out laughing with joy.", "sounds": "soft wind and sparkling chimes", "expect": "The same three children in pajamas now stand in a snow world with a snowman (this change of place is wanted), shiver, look around amazed and then laugh together; nobody speaks."}
 }$j$::jsonb)
), moved(code, produce_at, publish_at) as (values
    ('AS-1012-1500', '2026-10-15 07:00+00'::timestamptz, '2026-10-15 23:00+00'::timestamptz),  -- Puppy        16.10 02:00
    ('AS-1013-1500', '2026-10-16 07:00+00'::timestamptz, '2026-10-16 12:00+00'::timestamptz),  -- Cookie       16.10 15:00
    ('AS-1013-2000', '2026-10-16 07:00+00'::timestamptz, '2026-10-16 17:00+00'::timestamptz),  -- Kitchen Band 16.10 20:00
    ('AS-1014-1500', '2026-10-16 07:00+00'::timestamptz, '2026-10-16 23:00+00'::timestamptz),  -- Jelly        17.10 02:00
    ('AS-1011-1500', '2026-10-17 07:00+00'::timestamptz, '2026-10-17 12:00+00'::timestamptz),  -- Freeze Dance 17.10 15:00
    ('AS-1011-2000', '2026-10-17 07:00+00'::timestamptz, '2026-10-17 17:00+00'::timestamptz)   -- Super Kick   17.10 20:00
), todo as (
    select f.code, f.title,
           f.l1 || E'\n' || f.l2 || E'\n' || x.brand || E'\n#shorts #cartoon #kidscartoon ' || f.hashtags as description,
           x.tags || f.extra_tags as tags_csv, f.spec, f.produce_at, f.publish_at
    from fresh f cross join fixed x
    union all
    select o.code, o.title, o.description, o.tags_csv, o.spec, m.produce_at, m.publish_at
    from old o join moved m on m.code = o.code
    union all
    -- tomorrow's first dance gets its funny moment: dizzy after the spin
    select o.code, o.title, o.description, o.tags_csv,
           jsonb_set(o.spec, '{moves,2,move}', to_jsonb('All three spin around once on the spot with their arms stretched out, then wobble dizzily from side to side with silly smiles, wiggling their hips.'::text)),
           o.produce_at, o.publish_at
    from old o where o.code = 'AS-1011-1500-SONG'
)
select t.code, t.title, public.auto_short_plan(t.code, t.title, t.description, t.tags_csv, t.spec, t.produce_at, t.publish_at) ->> 'seconds' as seconds
from todo t order by t.publish_at;

-- ---------------------------------------------------------------------
-- 11 October, after the first morning (see the notes in
-- plans/2026-10-11_morning_repairs.sql): applied live with
-- m417_internal.as_respec(code, spec):
--   AS-1012-1500-SONG  move 2: small, quick kangaroo hops, feet leave the
--                      ground only a little (big jumps came out floating).
--   AS-1013-2000-BOTTLE and AS-1015-2000-BOTTLE  s3: the cork is pulled in
--                      a shot of all three children (a shot of one child
--                      alone on the rug read as "the others vanished").
-- ---------------------------------------------------------------------
