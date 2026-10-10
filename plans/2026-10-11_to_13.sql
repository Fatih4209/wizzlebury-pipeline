-- Calendar 11-13 October 2026: three shorts a day, produced at 10:00 and
-- published at 15:00, 20:00 and 02:00 (Europe/Istanbul). Safe to run
-- again while a short is still PLANNED.
with fixed as (
    select E'WIZZLEBURY: short, funny cartoons for kids with Fatih, Mia, Ömer, Tombik and Bruce. More funny cartoon shorts every week!' as brand,
           'kids cartoons,cartoons for kids,kids videos,funny cartoon,kids animation,cartoon shorts,wizzlebury,' as tags
), p(code, title, l1, l2, hashtag, extra_tags, produce_at, publish_at, spec) as (values

('AS-1011-1500', 'Shh! Don''t Wake the Puppy! 🐶',
 'Shh! Can Fatih, Mia and Tombik stay quiet in this funny kids cartoon?',
 'A tiny puppy is fast asleep in its basket and the three friends tiptoe around it. Then a very loud sound comes from a very hungry tummy. Watch to the end to see what the puppy does!',
 'puppy', 'puppy cartoon,cute puppy,sleeping puppy,dont wake the puppy,funny kids shorts,fatih,mia,tombik',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 12:00+00'::timestamptz, $j${
  "place": "A cozy living room with a soft beige sofa and a round rug on a wooden floor, warm golden afternoon light from a window on the left.",
  "setup": "In the middle of the rug stands exactly one round wicker basket with a blue blanket, and in it sleeps exactly one tiny fluffy golden puppy with floppy ears, curled up with its eyes closed.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand in a row behind the basket on tiptoe, bending forward and looking down at the puppy with soft smiles",
  "guard": "exactly one sleeping puppy",
  "wide_animals": true,
  "s1": {"seconds": 4, "action": "A cozy living room: three children stand on tiptoe behind a wicker basket in which one tiny golden puppy sleeps. The puppy breathes slowly and one ear twitches. The children hold still and watch it.", "speaker": "FATIH", "gesture": "puts one finger to his lips", "verb": "whispers loudly", "voice": "a careful, hushed", "line": "Shh! Don't wake the puppy!", "sounds": "the soft breathing of the puppy", "rule": "The puppy stays asleep with its eyes closed the whole time."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "lips pressed together, eyes wide and worried, both hands on his round belly", "action": "His round belly rumbles loudly, he looks down at it in shock, then looks up with a guilty little smile", "verb": "whispers", "voice": "a guilty, hushed", "line": "Oops! My tummy!", "after": "holds his belly", "sounds": "one loud funny tummy rumble"},
  "s3": {"seconds": 3, "frame": "Close-up at floor height on the same round wicker basket with the blue blanket on the rug, and in it the same tiny fluffy golden puppy with floppy ears, lying curled up with its eyes closed, filling the middle of the frame. The living room is softly blurred behind it. Exactly one puppy. No people, no hands.", "action": "Close-up on one tiny fluffy golden puppy sleeping in a wicker basket in a cozy living room. A loud funny tummy rumble is heard from off-screen. The puppy's eyes pop open, its head shoots up, its ears flap, it looks into the camera, wags its tail fast and gives one tiny happy bark: \"Woof!\" Right after that, three children's voices from off-screen laugh together. The puppy keeps wagging its tail and looking into the camera until the end.", "sounds": "the tummy rumble, the tiny bark, the children's laughter", "guard": "Exactly one puppy. No people in the frame, no hands,", "expect": "A sleeping puppy wakes up, wags its tail and barks \"Woof!\"; children laugh off-screen."}
 }$j$::jsonb),

('AS-1011-2000', 'Abracadabra! What''s in the Hat? 🎩',
 'Abracadabra! Fatih, Mia and Tombik try a magic trick in this funny kids cartoon!',
 'Fatih taps a big purple magic hat with his wand and Tombik hopes for something yummy. What will pop out of the hat? Watch to the end for the cute surprise.',
 'magictrick', 'magic hat,magic trick for kids,abracadabra,bunny cartoon,cute bunny,fatih,mia,tombik',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 17:00+00'::timestamptz, $j${
  "place": "A bright playroom with colorful shelves of toys and a small wooden table, warm golden afternoon light from a window on the left.",
  "setup": "In the middle of the small wooden table stands exactly one big shiny purple top hat with a yellow band, upside down with its opening facing up.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand behind the table and look at the hat with excited eyes, the boy on the right holding one short wooden magic wand with a white tip above the hat",
  "guard": "exactly one hat and one wand",
  "s1": {"seconds": 4, "action": "A bright playroom: three children stand behind a small table with one big purple top hat, opening up. The boy on the right holds a small magic wand above the hat. The other two watch the hat closely.", "speaker": "FATIH", "gesture": "taps the brim of the hat twice with the wand", "verb": "calls out", "voice": "a proud, showman", "line": "Abracadabra!", "sounds": "the two taps on the hat", "rule": "Nothing comes out of the hat yet."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "eyes huge and hopeful, leaning toward the hat", "foreground": "The purple brim of the top hat is", "fg_clip": "with the purple brim of a top hat in the foreground", "action": "He leans closer, peeks toward the hat with huge hopeful eyes, licks his lips", "verb": "asks", "voice": "a hopeful, hungry", "line": "Is it a cupcake?", "after": "keeps staring at the hat", "rule": "Nothing comes out of the hat."},
  "s3": {"seconds": 3, "frame": "Close-up at table height on the same big shiny purple top hat with the yellow band, standing upside down in the middle of the table with its opening facing up, filling the middle of the frame, with free space above it. The playroom is softly blurred behind it. Exactly one hat. No people, no hands, no animals.", "action": "Close-up on one big purple top hat standing opening-up on a table in a bright playroom. The hat shakes once, then with a soft pop one small fluffy white bunny with long ears and a pink nose pops its head and front paws out of the hat. The bunny looks into the camera, wiggles its nose and twitches one ear. Right after that, three children's voices from off-screen say together, amazed: \"Wooow!\" The bunny keeps looking into the camera and wiggling its nose until the end.", "sounds": "the soft pop, the children's \"Wooow!\"", "guard": "Exactly one bunny and one hat. No people in the frame, no hands,", "expect": "A white bunny pops out of the purple hat and wiggles its nose; children's voices say \"Wooow!\""}
 }$j$::jsonb),

('AS-1012-0200', 'Biggest Balloon Ever! Uh-Oh! 🎈',
 'The biggest balloon ever! Fatih, Mia and Tombik have a silly balloon moment in this funny kids cartoon!',
 'Fatih holds a huge red balloon and Tombik feels a big sneeze coming. What happens to the balloon? Watch to the end for the funniest sound.',
 'balloon', 'balloon cartoon,big balloon,funny balloon,achoo,sneeze cartoon,fatih,mia,tombik',
 '2026-10-11 07:00+00'::timestamptz, '2026-10-11 23:00+00'::timestamptz, $j${
  "place": "A sunny family kitchen with light wooden cabinets and a light wooden table, warm golden morning light from a window on the left.",
  "setup": "The boy on the right holds exactly one huge round red balloon, almost as big as he is, by its untied neck with both hands in front of his chest.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand side by side in the middle of the kitchen, the other two looking at the balloon with big eyes",
  "guard": "exactly one red balloon",
  "s1": {"seconds": 4, "action": "A sunny kitchen: three children stand side by side. The boy on the right holds one huge red balloon by its untied neck with both hands; the balloon wobbles and squeaks a little. The other two stare at it.", "speaker": "FATIH", "gesture": "lifts the balloon up proudly", "verb": "shouts", "voice": "a proud", "line": "Biggest balloon ever!", "sounds": "the squeak of the balloon", "rule": "He never lets go of the balloon and it does not pop."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "nose wrinkled, eyes half closed, as if about to sneeze", "action": "His nose twitches, his eyes squeeze shut, he takes two short breaths", "verb": "bursts out", "voice": "a loud, funny", "line": "Ah... ah... ACHOO!", "after": "blinks in surprise"},
  "s3": {"seconds": 3, "frame": "Medium-wide view of the same sunny kitchen with nobody in it: the light wooden table, the cabinets and the window. Exactly one huge round red balloon with an untied neck floats in the air in the middle of the kitchen. No people, no hands, no animals.", "action": "A sunny kitchen with nobody in it and one huge red balloon with an untied neck in the air. The balloon suddenly shoots off and zooms around the kitchen in fast loops, shrinking as the air rushes out with a long, silly, sputtering sound, and finally lands, tiny and wrinkled, flat on the wooden table. Right after that, three children's voices from off-screen burst out laughing.", "sounds": "the long silly sputtering of the balloon, the children's laughter", "guard": "Exactly one balloon. No people in the frame, no hands,", "expect": "A red balloon zooms around the kitchen with a silly sputtering sound and lands on the table; children laugh off-screen."}
 }$j$::jsonb),

('AS-1012-1500', 'What''s for Dinner?! Surprise! 🥦',
 'What is for dinner? Fatih, Mia and Tombik get a funny surprise in this kids cartoon!',
 'Dinner is hiding under a shiny silver dome and Tombik is dreaming of ice cream. Can you guess what is on the plate? Watch to the end to hear who loves it.',
 'dinnertime', 'dinner surprise,broccoli,healthy food for kids,veggies for kids,yummy,fatih,mia,tombik',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 12:00+00'::timestamptz, $j${
  "place": "A sunny family kitchen with light wooden cabinets, warm golden morning light from a window on the left.",
  "setup": "In the middle of a light wooden table stands exactly one big shiny silver serving dome with a round knob on top, covering a plate.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "sit behind the table and stare at the silver dome with hungry, curious eyes",
  "guard": "exactly one silver dome",
  "s1": {"seconds": 4, "action": "A sunny kitchen: three children sit behind a table with one big shiny silver serving dome on it. A little steam rises around the edge of the dome. All three stare at it and sniff the air.", "speaker": "MIA", "gesture": "claps her hands once", "verb": "calls out", "voice": "a cheerful", "line": "Dinner is ready!", "sounds": "one clap", "rule": "The dome stays closed."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "eyes sparkling, licking his lips, looking down at the dome", "foreground": "The round top of the silver dome with its knob is", "fg_clip": "with the top of a shiny silver serving dome in the foreground", "action": "He rubs his hands together, his eyes sparkle", "verb": "asks", "voice": "a dreamy, hungry", "line": "Is it ice cream?", "after": "keeps smiling at the dome", "rule": "The dome stays closed."},
  "s3": {"seconds": 4, "frame": "Close-up at table height on the same big shiny silver serving dome with the round knob, standing on a white plate in the middle of the table, filling the middle of the frame, with free space above it. The kitchen is softly blurred behind it. Exactly one dome. No people, no hands, no animals.", "action": "Close-up on one shiny silver serving dome on a wooden kitchen table. The dome lifts straight up by itself with a magical sparkle and floats up out of the frame, revealing one single, big, bright green broccoli standing upright on the white plate like a little tree, with a small puff of steam. Right after that, two children's voices from off-screen say together, disappointed: \"Ewww!\" and then one happy boy's voice from off-screen shouts: \"Yummy! Broccoli!\" The broccoli stays on the plate until the end.", "sounds": "a soft magical chime, the children's \"Ewww!\", the boy's \"Yummy! Broccoli!\"", "guard": "Exactly one broccoli on one plate. No people in the frame, no hands,", "expect": "The silver dome lifts and shows one big broccoli; children's voices say \"Ewww!\", then a boy's voice says \"Yummy! Broccoli!\""}
 }$j$::jsonb),

('AS-1012-2000', 'Who Took My Sock?! 🧦',
 'Who took the sock? Fatih, Mia and Tombik solve a funny mystery in this kids cartoon!',
 'Fatih has only one sock and cannot find the other one anywhere. Mia spots the sneaky sock thief first. Watch to the end to see who it is!',
 'kitten', 'missing sock,sock thief,kitten cartoon,cute kitten,funny mystery for kids,fatih,mia,tombik',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 17:00+00'::timestamptz, $j${
  "place": "A tidy children's bedroom with a blue bed, a wooden wardrobe and a round rug, warm golden morning light from a window on the left.",
  "setup": "The boy on the right holds up exactly one bright yellow sock with red stripes in one hand.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand side by side on the rug, the other two looking at the sock with puzzled faces",
  "guard": "exactly one sock",
  "s1": {"seconds": 4, "action": "A children's bedroom: three children stand on a round rug. The boy on the right holds up one yellow striped sock and looks around the room, puzzled. The other two shrug.", "speaker": "FATIH", "gesture": "shakes the sock in the air", "verb": "shouts", "voice": "a puzzled", "line": "Where is my other sock?!"},
  "s2": {"seconds": 3, "char": "MIA", "pose": "one eyebrow raised, a playful knowing smile, looking toward the left", "action": "She smiles playfully, raises one eyebrow, points with one finger toward the left edge of the frame without covering her face", "verb": "says", "voice": "a cheerful, teasing", "line": "Look! Over there!", "after": "keeps smiling"},
  "s3": {"seconds": 3, "frame": "Close-up at floor height on the round rug of the same bedroom: exactly one tiny fluffy orange tabby kitten with white paws and big green eyes sits on the rug and holds exactly one bright yellow sock with red stripes in its mouth. The bedroom is softly blurred behind it. No people, no hands.", "action": "Close-up on one tiny orange tabby kitten sitting on a rug in a bedroom with one yellow striped sock in its mouth. The kitten shakes the sock playfully left and right, drops it in front of its paws, looks into the camera and says a tiny, high, cute \"Meow!\" Right after that, three children's voices from off-screen burst out laughing. The kitten keeps looking into the camera until the end.", "sounds": "the tiny meow, the children's laughter", "guard": "Exactly one kitten and one sock. No people in the frame, no hands,", "expect": "A kitten with a yellow striped sock in its mouth shakes it, drops it and says \"Meow!\"; children laugh off-screen."}
 }$j$::jsonb),

('AS-1013-0200', 'The Biggest Bubble Ever! 🫧',
 'The biggest bubble ever! Fatih, Mia and Tombik play with bubbles in this funny kids cartoon!',
 'A giant soap bubble floats over the garden and nobody wants it to pop. Where will it land? Watch to the end for the pop!',
 'bubbles', 'bubbles for kids,giant bubble,soap bubbles,bubble pop,garden fun,fatih,mia,tombik',
 '2026-10-12 07:00+00'::timestamptz, '2026-10-12 23:00+00'::timestamptz, $j${
  "place": "A green garden with a wooden fence, a flower bed and blue sky, warm golden afternoon light from the left.",
  "setup": "The girl on the left holds exactly one big pink bubble wand, and exactly one giant shiny soap bubble as big as a beach ball floats in the air above the three of them.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand on the grass and look up at the giant bubble with amazed faces",
  "guard": "exactly one giant bubble",
  "s1": {"seconds": 4, "action": "A sunny garden: three children stand on the grass and look up at one giant shiny soap bubble floating above them. The bubble wobbles and drifts slowly down toward them. The girl on the left holds a pink bubble wand.", "speaker": "MIA", "gesture": "points up at the bubble", "verb": "shouts", "voice": "an excited", "line": "The biggest bubble ever!", "rule": "The bubble does not pop."},
  "s2": {"seconds": 3, "char": "FATIH", "pose": "eyes wide, both hands raised with open palms next to his face, looking up", "action": "He raises both open hands next to his face, eyes wide", "verb": "shouts", "voice": "a worried", "line": "Don't pop it!", "after": "holds still"},
  "s3": {"seconds": 3, "char": "TOMBIK", "frame": "Close-up at eye level on {CHAR}, standing in the same garden. Head and shoulders, face toward the camera, mouth closed, eyes crossed, looking at exactly one giant shiny soap bubble that hovers right in front of his nose. The garden is softly blurred behind him. Only this one boy and one bubble, nobody else, no animals.", "action": "Close-up on {CHAR}, in a sunny garden, with one giant shiny soap bubble hovering right in front of his nose. The bubble sinks slowly, touches the tip of his nose and bursts with a soft pop into a sparkle of tiny droplets. He blinks, surprised, then breaks into a big grin and shouts in a happy cartoon boy voice: \"Again!\" His mouth forms the word clearly, exactly in sync with his voice. He says only this one word, once, in English, and keeps grinning until the end.", "sounds": "the soft pop of the bubble, his voice", "guard": "Only Tombik is in the frame, nobody else appears,", "expect": "A giant bubble pops on Tombik's nose and Tombik shouts: \"Again!\""}
 }$j$::jsonb),

('AS-1013-1500', 'One Cookie, Three Friends! 🍪',
 'Only one cookie for three friends! What will Fatih, Mia and Tombik do in this kids cartoon?',
 'There is one big cookie on the plate and everybody is hungry. Mia has a bright idea. Watch to the end to see how friends share!',
 'sharing', 'sharing for kids,sharing is caring,cookie cartoon,one cookie,kindness for kids,fatih,mia,tombik',
 '2026-10-13 07:00+00'::timestamptz, '2026-10-13 12:00+00'::timestamptz, $j${
  "place": "A sunny family kitchen with light wooden cabinets, warm golden morning light from a window on the left.",
  "setup": "In the middle of a light wooden table stands exactly one blue plate with exactly one big round chocolate chip cookie on it.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "sit behind the table and stare at the cookie with hungry eyes",
  "guard": "exactly one cookie on one plate",
  "s1": {"seconds": 4, "action": "A sunny kitchen: three children sit behind a table and stare at one big chocolate chip cookie on a blue plate. All three lick their lips and lean a little closer.", "speaker": "FATIH", "gesture": "points at the plate", "verb": "says", "voice": "a worried", "line": "Uh-oh! Only one cookie!", "rule": "Nobody touches the cookie."},
  "s2": {"seconds": 3, "char": "MIA", "pose": "a bright idea on her face, one finger raised next to her cheek", "foreground": "The edge of the blue plate with the cookie is", "fg_clip": "with the edge of a blue plate and a cookie in the foreground", "action": "Her eyes light up, she raises one finger next to her cheek with a bright smile", "verb": "says", "voice": "a cheerful", "line": "I know! Let's share!", "after": "keeps smiling", "rule": "Nobody touches the cookie."},
  "s3": {"seconds": 4, "char": "TOMBIK", "frame": "Medium close-up at eye level on {CHAR}, sitting at the same table. He holds exactly one big round chocolate chip cookie in front of his chest with both hands and looks at it with a warm smile, mouth closed. The empty blue plate stands on the table in front of him. The kitchen is softly blurred behind him. Only this one boy and one cookie, nobody else, no animals.", "action": "Medium close-up on {CHAR}, at a kitchen table, holding one big chocolate chip cookie with both hands. He breaks the cookie into three pieces with a soft snap, holds the pieces out toward the camera on his open palms with a big proud smile and says in a warm, happy cartoon boy voice: \"Sharing is yummy!\" His mouth forms every word clearly, exactly in sync with his voice. He says only these three words, once, in English, and keeps smiling until the end. He has exactly two hands with five fingers each.", "sounds": "the snap of the cookie, his voice", "guard": "Only Tombik is in the frame, nobody else appears,", "expect": "Tombik breaks the cookie into pieces, holds them out and says: \"Sharing is yummy!\""}
 }$j$::jsonb),

('AS-1013-2000', 'The Loudest Kitchen Band! 🥁',
 'The loudest kitchen band! Fatih, Mia and Tombik make music with pots in this funny kids cartoon!',
 'Tombik drums on the pots and it gets very, very loud. But who is the best drummer in the kitchen? Watch to the end for the tiny surprise.',
 'kidsmusic', 'kitchen band,pots and pans,drumming for kids,kitten drums,music for kids,fatih,mia,tombik',
 '2026-10-13 07:00+00'::timestamptz, '2026-10-13 17:00+00'::timestamptz, $j${
  "place": "A sunny family kitchen with light wooden cabinets, warm golden morning light from a window on the left.",
  "setup": "On a light wooden table stand exactly three shiny upside-down cooking pots in a row, and the chubby boy in the middle holds one wooden spoon in each hand above them.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "stand behind the table, the other two watching the pots with big smiles",
  "guard": "exactly three pots and two wooden spoons",
  "s1": {"seconds": 4, "action": "A sunny kitchen: three children stand behind a table with three upside-down cooking pots. The chubby boy in the middle drums on the pots with two wooden spoons in a happy rhythm. The other two bounce to the beat.", "speaker": "TOMBIK", "gesture": "lifts both spoons high", "verb": "shouts", "voice": "a wild, happy", "line": "We are a band!", "sounds": "the drumming on the pots"},
  "s2": {"seconds": 3, "char": "MIA", "pose": "both hands over her ears, eyes squeezed, a laughing smile", "action": "She presses both hands over her ears, laughs", "verb": "shouts", "voice": "a laughing", "line": "Too loud! Too loud!", "after": "keeps her hands over her ears", "sounds": "drumming on pots from off-screen"},
  "s3": {"seconds": 3, "frame": "Close-up at table height on the same light wooden table: exactly one small shiny upside-down cooking pot, and behind it sits exactly one tiny fluffy orange tabby kitten with white paws and big green eyes, both front paws resting on the pot. The kitchen is softly blurred behind it. No people, no hands.", "action": "Close-up on one tiny orange tabby kitten sitting behind a small upside-down cooking pot on a kitchen table, front paws on the pot. The kitten drums on the pot with both paws in a quick little rhythm, then stops, looks into the camera and says a tiny, high, cute \"Meow!\" Right after that, three children's voices from off-screen cheer together: \"Yaaay!\"", "sounds": "the tapping on the pot, the tiny meow, the children's cheer", "guard": "Exactly one kitten and one pot. No people in the frame, no hands,", "expect": "A kitten drums on a pot with its paws and says \"Meow!\"; children cheer \"Yaaay!\" off-screen."}
 }$j$::jsonb),

('AS-1014-0200', 'Don''t Touch the Jelly! 🍮',
 'Don''t touch the jelly! Can Fatih, Mia and Tombik resist in this funny kids cartoon?',
 'A giant red jelly stands on the table and Tombik wants just one tiny poke. What happens when he does it? Watch to the end for the wobble!',
 'jelly', 'jelly wobble,giant jelly,wobbly jelly,funny food,satisfying for kids,fatih,mia,tombik',
 '2026-10-13 07:00+00'::timestamptz, '2026-10-13 23:00+00'::timestamptz, $j${
  "place": "A sunny family kitchen with light wooden cabinets, warm golden morning light from a window on the left.",
  "setup": "In the middle of a light wooden table stands exactly one white plate with exactly one giant shiny red jelly dome, as big as a football, perfectly still.",
  "cast": ["MIA", "TOMBIK", "FATIH"],
  "wide_pose": "sit behind the table and stare at the jelly with big eyes",
  "guard": "exactly one jelly",
  "s1": {"seconds": 4, "action": "A sunny kitchen: three children sit behind a table and stare at one giant shiny red jelly on a plate. The jelly glistens and stands perfectly still. The chubby boy in the middle slowly lifts one finger toward it.", "speaker": "MIA", "gesture": "holds one open hand up", "verb": "calls out", "voice": "a warning, giggly", "line": "Don't touch the jelly!", "rule": "Nobody touches the jelly yet."},
  "s2": {"seconds": 3, "char": "TOMBIK", "pose": "a cheeky grin, one pointing finger raised next to his face", "foreground": "The shiny red top of the giant jelly is", "fg_clip": "with the shiny red top of a giant jelly in the foreground", "action": "He grins cheekily, holds one pointing finger up next to his face, wiggles it", "verb": "says", "voice": "a cheeky, pleading", "line": "Just one tiny poke!", "after": "keeps grinning", "rule": "He does not touch the jelly yet."},
  "s3": {"seconds": 3, "frame": "Close-up at table height on the same giant shiny red jelly dome on its white plate in the middle of the table, filling the middle of the frame, perfectly still. One small pointing finger of a child's hand comes into the frame from the right edge and almost touches the jelly. The kitchen is softly blurred behind it. Exactly one jelly and one hand. No faces, no animals.", "action": "Close-up on one giant shiny red jelly on a plate on a kitchen table, with one child's pointing finger at the right edge of the frame. The finger gives the jelly one gentle poke and pulls back out of the frame. The jelly wobbles wildly left and right and up and down with a funny boing-boing sound for a long moment and slowly settles. Right after the poke, three children's voices from off-screen burst out laughing.", "sounds": "the funny boing-boing wobble of the jelly, the children's laughter", "guard": "Exactly one jelly. No faces in the frame,", "expect": "A finger pokes the giant red jelly, the jelly wobbles wildly with a boing sound; children laugh off-screen."}
 }$j$::jsonb)
)
select public.auto_short_plan(
    p.code, p.title,
    p.l1 || E'\n' || p.l2 || E'\n' || f.brand || E'\n#shorts #cartoon #kidscartoon #funnycartoon #' || p.hashtag,
    f.tags || p.extra_tags, p.spec, p.produce_at, p.publish_at) ->> 'seconds' as seconds,
    p.code, p.title, char_length(p.title) as title_len
from p cross join fixed f
order by p.publish_at;
