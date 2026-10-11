-- 11 October, evening. The first episodes of the everyday-life series for the
-- writers' room (migration 017). One place, one small problem with something
-- real at stake, twelve one-take scenes. The owner named the places:
-- classroom, canteen, school bus, sports lesson, park, dance course, coming
-- home to mum and dad. The ideas are ours; he does not want to supply them.
--
-- EP01 was pushed through the room by hand this evening (runs 1, 6, 7, 9, 10
-- of public.writer_runs); it is adopted here in state FINAL so that the tick
-- only has to make the specs. Safe to run more than once.
insert into public.writer_episodes (code, no, title, place, wardrobe, premise) values
('EP01', 1, 'The Missing Homework',
 'Miss Lily''s classroom on a sunny morning.', 'school',
 'Fatih has left his homework at home. Mia notices before the teacher does. Tombik tries to distract Miss Lily and makes it bigger. Ömer tries to help too quickly. Bruce''s paper plane goes wrong. Fatih takes a breath and tells the truth. Miss Lily is kind. His dad arrives at the door with the homework, just in time - a little too late to save him, exactly in time to see him be brave.'),
('EP02', 2, 'The Last Pudding',
 'The school canteen at lunch time: long tables, trays, the serving counter with the Cook behind it.', 'school',
 'There is exactly one chocolate pudding left on the counter, and Tombik has been dreaming of it all morning. Tidy Mia, of all people, has brought the wrong lunch box: it is empty, and she is too proud to say so. Fatih sees it with one look. Ömer offers to race for the pudding; Bruce offers to cut it into five with a spoon and a plan. Tombik gets the pudding - and then sees Mia''s empty box. The hardest decision of his life is played on his face. He slides the pudding over. The Cook, who has watched everything and always gives a little extra, has the last word.'),
('EP03', 3, 'The Song Nobody Sings',
 'Inside the yellow school bus on the way to school in the morning; the Driver at the wheel in front.', 'school',
 'The Driver hums a little children''s song. Ömer declares that it is a song for babies and that nobody here is going to sing it. One after the other they catch themselves: Tombik''s foot taps, Bruce drums on his knees, Mia hums behind her hand and is caught by Fatih, who is caught nodding himself. Only Ömer holds out, arms crossed, lips pressed - until the bus stops at school and the song stops with it, and it is Ömer who sings the last line out loud, alone, in the silence. The Driver winks in the mirror.'),
('EP04', 4, 'The Duck Whistle',
 'The schoolyard during the sports lesson on a bright day: a running track painted on the ground, small cones, the Coach in his tracksuit.', 'school',
 'The Coach wants to start the big relay, lifts his whistle - and it quacks like a duck. Bruce has "improved" it in the break and does not dare to say so. Every time the Coach tries again it quacks, and it gets harder for the children not to laugh: Tombik has to hide behind Ömer, Mia bites her sleeve, Fatih sees Bruce''s ears turn red. Fatih gives Bruce the look that says "tell him", Bruce steps forward and admits it. The Coach is silent for one long second - and then quacks the start of the relay himself, with enormous enthusiasm, for the rest of the lesson.'),
('EP05', 5, 'Clean Floor',
 'The hallway and kitchen of Fatih''s home in the afternoon after school; outside it has rained.', 'home',
 'Fatih and Mia come home from school with mud up to their knees, and Mom has just finished mopping: the floor shines. They try to cross it without leaving a trace - on tiptoe, on the school bags, on two kitchen towels like skates - and every idea makes it a little worse. Mom has her back to them at the counter, and the two can hardly breathe for holding in the giggles. They decide to tell her, take a breath, "Mom...?" - and in that moment Dad comes in through the door, muddier than both of them together, walks straight across the floor and asks what is for dinner. Mom looks at three guilty faces and hands out three mops.'),
('EP06', 6, 'One Swing',
 'The park in the late afternoon: a playground with one swing, a bench, trees, golden light.', 'park',
 'There is one swing and three friends. Ömer is always first. They agree on ten swings each and count out loud - but Ömer counts very slowly, Tombik''s ice cream melts in his hand while he waits, and Mia keeps the peace with her eyebrows. When it is finally Fatih''s turn he sees that Mia has let everybody go before her without a word. He gets off after one swing and holds the swing still for her. Then Ömer and Tombik push her, far too eagerly, and the queue that everybody fought about is forgotten.'),
('EP07', 7, 'Left Foot, Right Foot',
 'The school hall in the afternoon, used for the dance club: wooden floor, a big mirror wall, Miss Lily leading the club.', 'dance',
 'The dance club practises for the school show, and Fatih cannot get one step right: left, right, clap - he always goes right, left and claps too late. In the mirror he sees everybody else do it. Mia, next to him, notices that he has stopped smiling. Tombik tries to help by doing the step very big and very wrong; Ömer does it at double speed. Fatih wants to sit out. Mia does not explain anything: she taps her own left knee, he taps his, and they do the step together, slowly, only the two of them, until his face opens up. At the end the whole row does it - and it is Miss Lily who goes the wrong way.'),
('EP08', 8, 'Show and Tell',
 'Miss Lily''s classroom on a sunny morning; one child at a time stands at the front beside the teacher''s desk.', 'school',
 'It is show-and-tell day. Bruce has built a machine that is supposed to hand over a pencil all by itself, and he is far too proud of it. Tombik has brought his lunch and presents it with great seriousness. When it is Bruce''s turn the machine does nothing. Nothing at all. The longest silence of his life. Fatih and Mia look at each other; Mia starts to clap slowly for the idea, Fatih joins, and Miss Lily asks him how it was meant to work. While Bruce explains with shining eyes, the machine, behind his back, quietly hands the pencil to Tombik.')
on conflict (code) do nothing;

-- EP01: adopt the hand-run of this evening
update public.writer_runs set part = 'A' where id = 9 and episode = 'EP01' and step = 'FINAL';
update public.writer_runs set part = 'B' where id = 10 and episode = 'EP01' and step = 'FINAL';
update public.writer_episodes e
set state = 'FINAL',
    step_at = (select created_at from public.writer_runs where id = 9),
    research = (select output from public.writer_runs where id = 1),
    draft = (select output from public.writer_runs where id = 6),
    edit = (select output from public.writer_runs where id = 7)
where e.code = 'EP01' and e.state = 'IDEA'
  and exists (select 1 from public.writer_runs where id = 10 and episode = 'EP01' and step = 'FINAL' and output is not null);

select code, no, title, state from public.writer_episodes order by no;
