-- 10 October, evening: the owner asked for two new kinds of shorts.
--   1. Dance shorts: the children dance to a song of our own (written by us,
--      sung by the music model, stored under auto/songs/). Nobody speaks.
--   2. The magic bottle: they pull the cork and land in another world.
-- Both go out on 11 October; Freeze Dance and Super Kick keep their codes
-- and move to 15 October. One statement, only rows that are still PLANNED.
--
-- Song auto/songs/CLAP_JUMP_V1.mp3 (30 s, the verse twice). Sung words as
-- measured: "Clap, clap, clap your hands" 1.1-3.5 s, "Jump, jump, jump
-- around" 3.9-7.2, "Spin, spin, wiggle, wiggle" 7.6-10.9, "Laugh out loud,
-- ha ha ha" 11.4-14.7. With trim 1.0 and shots of 3+4+4+4 s (joined with
-- 0.5 s fades: 0-3, 2.5-6.5, 6-10, 9.5-13.5) every line has its own shot.
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. More funny cartoon shorts every week!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,videos for kids,animation for kids,' as tags
), old as materialized (
    select code, title, description, tags_csv, spec from public.auto_shorts
    where state = 'PLANNED' and code in ('AS-1011-1500', 'AS-1011-2000')
), fresh(code, title, l1, l2, hashtags, extra_tags, produce_at, publish_at, spec) as (values

('AS-1011-1500-SONG', 'Clap Clap Jump! 🎵 Kids Dance Song',
 'Clap, jump, spin and wiggle with Bruce, Fatih and Ömer! A happy dance song for kids.',
 'Can you do all the moves? Clap your hands, jump around, spin, wiggle and laugh out loud! Dance along and watch it again!',
 '#kidssongs #dancesong #kidsdance', 'kids dance song,dance song for kids,kids songs,action song,clap your hands,bruce,fatih,omer',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 12:00+00'::timestamptz, $j${
  "kind": "dance",
  "wardrobe": "park",
  "place": "A sunny park: soft green grass in front, a colourful playground with a slide and swings softly blurred in the background, blue sky and warm golden light from the left.",
  "cast": ["BRUCE", "FATIH", "OMER"],
  "song": {"file": "auto/songs/CLAP_JUMP_V1.mp3", "trim": 1.0, "volume": 0.9},
  "moves": [
    {"seconds": 3, "move": "All three clap their hands above their heads three times and bounce on their knees with every clap."},
    {"seconds": 4, "move": "All three jump up and down together three times with both arms in the air, landing softly each time."},
    {"seconds": 4, "move": "All three spin around once on the spot with their arms stretched out, then put their hands on their hips and wiggle their hips from side to side."},
    {"seconds": 4, "move": "All three bob their heads from side to side, then burst out laughing together and look at each other."}
  ]
 }$j$::jsonb),

('AS-1011-2000-BOTTLE', 'Magic Bottle! Where Are We?! 🍭✨',
 'A magic bottle! Fatih, Ömer and Tombik pull the cork in this funny kids cartoon. Where will it take them?',
 'The bottle glows, Fatih counts to three and... POP! Watch to the end to see the magic world they land in!',
 '#magic #surprise', 'magic bottle,magic cartoon,candy world,magic for kids,surprise,fatih,omer,tombik',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 17:00+00'::timestamptz, $j${
  "wardrobe": "home",
  "place": "A cozy living room with a soft beige sofa in the background, a round rug on a wooden floor and warm golden afternoon light from a window on the left.",
  "setup": "In the middle of the rug stands exactly one small round glass bottle with a cork, filled with softly glowing, swirling rainbow light.",
  "cast": ["OMER", "TOMBIK", "FATIH"],
  "wide_pose": "kneel on the rug in a half circle behind the glowing bottle and stare at it with big amazed eyes, the rainbow light shining on their faces",
  "guard": "exactly one glass bottle",
  "s1": {"seconds": 4, "action": "A cozy living room: three children kneel on a round rug behind one small glass bottle that glows with swirling rainbow light. The light flickers on their amazed faces.", "speaker": "OMER", "gesture": "points at the bottle with both hands", "verb": "shouts", "voice": "an excited", "line": "Open it! Open it!", "sounds": "a soft magical hum", "rule": "Nobody touches the bottle yet; the cork stays in."},
  "s2": {"seconds": 3, "char": "FATIH", "pose": "eyes wide with excitement, a nervous little smile", "foreground": "The round top of the glowing glass bottle with its cork is", "fg_clip": "with the top of a glowing glass bottle in the foreground", "action": "He takes a deep breath, his eyes wide with excitement,", "verb": "counts", "voice": "an excited, trembling", "line": "One... two... THREE!", "after": "squeezes his eyes shut", "sounds": "a soft magical hum"},
  "s3": {"seconds": 4, "char": "FATIH", "frame": "Medium shot at eye level on {CHAR}, kneeling on the same round rug in the same living room, holding the same small round glass bottle in one hand and gripping its cork with the other hand, eyes squeezed shut, mouth closed. The bottle glows with swirling rainbow light. Only this one boy, nobody else, no animals.", "action": "Medium shot on {CHAR}, kneeling on a rug in a cozy living room, holding a small round glass bottle that glows with swirling rainbow light. He pulls the cork out with a loud pop. A swirl of sparkling rainbow light shoots out of the bottle, spins around him faster and faster and fills the whole picture with bright golden-white light, until only the bright light can be seen.", "sounds": "the loud pop of the cork, a rising magical whoosh, sparkling chimes", "guard": "Only Fatih is in the frame, nobody else appears,", "expect": "Fatih pulls the cork out of the glowing bottle with a pop; sparkling rainbow light swirls out and fills the picture with bright light, so that he disappears in the light (this is wanted)."},
  "s4": {"seconds": 4, "place": "A bright candy world under a pastel blue sky: rolling hills of pink and mint-green ice cream, giant swirly lollipops as tall as trees, a shiny chocolate river and fluffy cotton-candy clouds, soft warm sunlight.", "pose": "look up and around with wide, amazed eyes", "sounds": "soft sparkling chimes", "expect": "The same three children now stand in a candy world with giant lollipops (this change of place is wanted), look around amazed and then laugh together; nobody speaks."}
 }$j$::jsonb)
), todo as (
    select f.code, f.title,
           f.l1 || E'\n' || f.l2 || E'\n' || x.brand || E'\n#shorts #cartoon #kidscartoon ' || f.hashtags as description,
           x.tags || f.extra_tags as tags_csv, f.spec, f.produce_at, f.publish_at
    from fresh f cross join fixed x
    union all
    select o.code, o.title, o.description, o.tags_csv, o.spec, '2026-10-15 07:00+00'::timestamptz,
           case o.code when 'AS-1011-1500' then '2026-10-15 12:00+00'::timestamptz else '2026-10-15 17:00+00'::timestamptz end
    from old o
)
select t.code, t.title, public.auto_short_plan(t.code, t.title, t.description, t.tags_csv, t.spec, t.produce_at, t.publish_at) ->> 'seconds' as seconds
from todo t order by t.publish_at;
