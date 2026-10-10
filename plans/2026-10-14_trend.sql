-- 10 October, 21:00: the owner asked for topics chosen from what is being
-- watched. Source: vidIQ outliers and trending for kids' cartoon shorts
-- (last 1-3 months). What small channels break out with: a prank that
-- backfires ("instant karma"), friends or siblings fighting over one
-- thing, a fail, a funny dance, a cute animal, a good habit. Titles are
-- short and carry the hook word (prank, fail, karma) and one 😂.
-- Two more search phrases that are growing join the fixed tags.
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. More funny cartoon shorts every week!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,videos for kids,animation for kids,' as tags
), old as materialized (
    select code, title, description, tags_csv, spec, produce_at, publish_at from public.auto_shorts where state = 'PLANNED'
), fresh(code, title, l1, l2, hashtag, extra_tags, produce_at, publish_at, spec) as (values

('AS-1014-2000', 'Prank Gone Wrong! Instant Karma 😂',
 'Prank gone wrong! Fatih, Bruce and Tombik try a funny prank in this kids cartoon!',
 'Fatih hides a whoopee cushion on the big blue chair and cannot stop laughing. But who will sit on it? Watch to the end for the instant karma!',
 'prank', 'funny prank,prank gone wrong,instant karma,whoopee cushion,prank for kids,fatih,bruce,tombik',
 '2026-10-14 07:00+00'::timestamptz, '2026-10-14 17:00+00'::timestamptz, $j${
  "wardrobe": "home",
  "place": "A cozy living room with a soft beige sofa in the background, a round rug on a wooden floor and warm golden afternoon light from a window on the left.",
  "setup": "In the middle of the rug stands exactly one big blue armchair, and the boy on the right holds exactly one round pink whoopee cushion in both hands.",
  "cast": ["BRUCE", "TOMBIK", "FATIH"],
  "wide_pose": "stand next to the armchair, the boy on the right holding the pink cushion, the other two watching him with cheeky grins",
  "guard": "exactly one armchair and one pink whoopee cushion",
  "s1": {"seconds": 4, "action": "A cozy living room: three children stand next to a big blue armchair. The boy on the right holds a round pink whoopee cushion and sneakily lays it flat on the seat of the armchair; the other two giggle silently behind their hands.", "speaker": "FATIH", "gesture": "puts one finger to his lips", "verb": "whispers loudly", "voice": "a sneaky, excited", "line": "Shh! Prank time!", "sounds": "soft giggles", "rule": "Nobody sits down yet; the pink cushion stays on the seat."},
  "s2": {"seconds": 3, "char": "FATIH", "pose": "a huge mischievous grin, both hands rubbing together", "action": "He rubs his hands together with a huge mischievous grin, his shoulders shake with silent laughter", "verb": "says", "voice": "a giggling, proud", "line": "This is so funny!", "after": "keeps grinning"},
  "s3": {"seconds": 4, "char": "FATIH", "frame": "Medium shot at eye level on {CHAR}, standing right in front of the same big blue armchair in the same living room, his back to the armchair, laughing with his eyes closed, mouth closed. Exactly one round pink whoopee cushion lies on the seat of the armchair behind him. Only this one boy, nobody else, no animals.", "action": "Medium shot on {CHAR}, in a cozy living room, standing right in front of a big blue armchair with a pink whoopee cushion on its seat. He laughs so hard with his eyes closed that he forgets everything, steps back and plops down onto the armchair. A very loud, long, funny whoopee cushion sound rings out. His eyes pop wide open, he freezes with red cheeks and says in a tiny, embarrassed cartoon boy voice: \"Oops!\" His mouth forms the word clearly, exactly in sync with his voice. He says only this one word, once, in English, and stays frozen until the end.", "sounds": "his laughing, the loud funny whoopee cushion sound, his voice", "guard": "Only Fatih is in the frame, nobody else appears,", "expect": "Fatih laughs, sits down on his own whoopee cushion, a loud funny sound rings out and he says: \"Oops!\""},
  "s4": {"seconds": 3, "pose": "stand close together, the boy on the right with red cheeks and an embarrassed smile, the other two with wide surprised eyes, all looking at the camera", "action": "The two boys on the left burst out laughing and point at the boy on the right; he blushes, then starts laughing at himself too, and all three laugh together."}
 }$j$::jsonb),

('AS-1015-0200', 'Musical Chairs! Who Wins?! 😂',
 'Musical chairs! Who gets the last chair? Ömer, Bruce and Mia play in this funny kids cartoon!',
 'There is only one chair left and Ömer is sure it is his. But somebody small and very fast has another plan. Watch to the end to see who wins!',
 'musicalchairs', 'musical chairs,party games,last chair,kitten cartoon,cute kitten,omer,bruce,mia',
 '2026-10-14 07:00+00'::timestamptz, '2026-10-14 23:00+00'::timestamptz, $j${
  "wardrobe": "party",
  "place": "A living room decorated for a birthday party with colorful balloons and plain paper garlands without letters on the wall, a light wooden floor and warm golden afternoon light from a window on the left.",
  "setup": "In the middle of the room stands exactly one small red wooden chair.",
  "cast": ["OMER", "MIA", "BRUCE"],
  "wide_pose": "stand in a half circle behind the red chair, knees bent, ready to run, eyes on the chair",
  "guard": "exactly one red chair",
  "s1": {"seconds": 4, "action": "A birthday party in a living room: three children tiptoe in a circle around one small red chair, eyes fixed on it, ready to jump.", "speaker": "MIA", "gesture": "claps her hands once", "verb": "calls out", "voice": "a cheerful, excited", "line": "Sit down... NOW!", "sounds": "one clap", "rule": "Nobody sits on the chair yet."},
  "s2": {"seconds": 3, "char": "OMER", "pose": "a confident grin, leaning forward like a runner, one hand pointing down", "foreground": "The red backrest of the small chair is", "fg_clip": "with the red backrest of a small chair in the foreground", "action": "He leans forward like a runner at the start, grins confidently, points down at the chair", "verb": "shouts", "voice": "a confident, playful", "line": "This chair is mine!", "after": "keeps grinning", "rule": "He does not sit down yet."},
  "s3": {"seconds": 3, "frame": "Close-up at seat height on the same small red wooden chair standing empty in the middle of the same party room, filling the middle of the frame. The balloons are softly blurred behind it. Exactly one chair. No people, no hands, no animals.", "action": "Close-up on one small red wooden chair standing empty in a party room. With a quick little hop, one tiny fluffy orange tabby kitten with white paws and big green eyes jumps up onto the seat, sits down proudly in the middle of it, looks into the camera and says a tiny, high, cute \"Meow!\" Right after that, three children's voices from off-screen shout together, surprised: \"Whaaat?!\" The kitten stays sitting on the chair until the end.", "sounds": "the soft hop of the kitten, the tiny meow, the children's \"Whaaat?!\"", "guard": "Exactly one kitten and one chair. No people in the frame, no hands,", "expect": "A kitten jumps onto the empty red chair, sits down and says \"Meow!\"; children's voices shout \"Whaaat?!\""}
 }$j$::jsonb)
), todo as (
    select f.code, f.title,
           f.l1 || E'\n' || f.l2 || E'\n' || x.brand || E'\n#shorts #cartoon #kidscartoon #funnycartoon #' || f.hashtag as description,
           x.tags || f.extra_tags as tags_csv, f.spec, f.produce_at, f.publish_at
    from fresh f cross join fixed x
    union all
    -- the shorts already planned: hook word in the title, two more tags
    select o.code,
           case o.code when 'AS-1011-1500' then 'Funny Freeze Dance Fail! 😂'
                       when 'AS-1011-2000' then 'Super Kick Fail! 😂'
                       else o.title end,
           o.description,
           case when o.tags_csv like '%videos for kids%' then o.tags_csv
                else replace(o.tags_csv, 'wizzlebury,', 'wizzlebury,videos for kids,animation for kids,') end,
           o.spec, o.produce_at, o.publish_at
    from old o
)
select t.code, t.title, public.auto_short_plan(t.code, t.title, t.description, t.tags_csv, t.spec, t.produce_at, t.publish_at) ->> 'seconds' as seconds
from todo t order by t.publish_at;
