
-- =====================================================================
-- 1b. Film grammar, two-yes rule, prompts kept in the database (010)
-- =====================================================================

-- What the edit uses of a generated clip, and how the shot is staged.
alter table public.shot_specifications
    add column if not exists beats jsonb not null default '[]'::jsonb,
    add column if not exists props jsonb not null default '[]'::jsonb,
    add column if not exists edit_seconds numeric,
    add column if not exists film_size text,
    add column if not exists shot_purpose text,
    add column if not exists voice_staging text,
    add column if not exists qc_brief jsonb;

alter table public.video_reference_images
    add column if not exists wardrobe_note text;

alter table public.production_jobs
    add column if not exists script_no_count integer not null default 0;

alter table public.job_artifacts drop constraint if exists job_artifacts_type_check;
alter table public.job_artifacts add constraint job_artifacts_type_check check (artifact_type in (
    'TREND_REPORT', 'TOPIC_SELECTION', 'SCRIPT', 'SCRIPT_REVIEW', 'SHOT_PACKAGE', 'PREQC_REPORT',
    'MUSIC_SFX_PLAN', 'FINAL_QC_REPORT', 'METADATA_CANDIDATES', 'THUMBNAIL'));

-- One row per vote on a script: the Assistant Director (OpenAI) votes on
-- the Head Director's script, the Head Director (Claude) on the finished
-- package. Nothing is produced without a YES from both.
create table if not exists public.script_votes (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    script_artifact_id uuid not null references public.job_artifacts(id) on delete restrict,
    voter text not null,
    voter_role text not null,
    decision text not null,
    stated_decision text,
    scores jsonb not null default '{}'::jsonb,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint script_votes_voter_check check (voter in ('CLAUDE', 'OPENAI')),
    constraint script_votes_role_check check (voter_role in ('HEAD_DIRECTOR', 'ASSISTANT_DIRECTOR')),
    constraint script_votes_decision_check check (decision in ('YES', 'NO'))
);
create index if not exists idx_script_votes_job on public.script_votes (job_id, created_at);
create index if not exists idx_script_votes_artifact on public.script_votes (script_artifact_id);
alter table public.script_votes enable row level security;

-- The instructions the writers and reviewers receive. Make sends the
-- text the database hands out, so a change of wording is a change here.
-- Placeholders: [[BIBLE]] [[REQUEST]] [[TOPIC]] [[SCRIPT]] [[SHOT_PACKAGE]]
-- [[FEEDBACK]] [[ASSISTANT_REVIEW]] [[PREQC_REPORT]] [[LIMITS]].
create table if not exists public.step_prompts (
    prompt_code text not null,
    version integer not null,
    is_active boolean not null default true,
    body text not null,
    note text,
    created_at timestamptz not null default now(),
    constraint step_prompts_pkey primary key (prompt_code, version),
    constraint step_prompts_version_check check (version > 0)
);
create unique index if not exists uq_step_prompts_active
    on public.step_prompts (prompt_code) where (is_active = true);
alter table public.step_prompts enable row level security;

do $$
declare
    v_role text;
begin
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.script_votes from %I', v_role);
            execute format('revoke all on public.step_prompts from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.system_flags (key, value, description) values
    ('film_grammar_enforced', true, 'Scripts and shot packages must follow the film rules: hook, wardrobe, props, planned shot sizes, cut lengths, one speaker per shot.'),
    ('speaker_closeup_allowed', false, 'May a character speak in a close-up? Off until exact lip-sync is produced.'),
    ('assistant_vote_required', true, 'Two-yes rule: the Assistant Director (OpenAI) must vote YES on the script and the Head Director (Claude) YES on the package before anything is produced.')
on conflict (key) do nothing;

insert into public.system_settings (key, value_numeric, description) values
    ('episode_min_seconds', 10, 'Shortest finished episode (sum of the cut lengths).'),
    ('episode_max_seconds', 18, 'Longest finished episode (sum of the cut lengths).'),
    ('min_shots', 5, 'Fewest shots in an episode.'),
    ('max_shots', 7, 'Most shots in an episode; every shot is one paid generation.'),
    ('min_shot_edit_seconds', 0.8, 'Shortest cut.'),
    ('max_shot_edit_seconds', 4.5, 'Longest cut.'),
    ('hook_max_seconds', 2.5, 'The first cut may not be longer than this.'),
    ('max_dialogue_lines', 6, 'Most spoken lines in an episode.'),
    ('edit_voice_lead_seconds', 0.15, 'A voice starts this long after its cut begins.'),
    ('edit_voice_tail_seconds', 0.35, 'A cut lasts at least this long after its voice ends.'),
    ('edit_trim_lead_seconds', 0.2, 'The edit skips this much at the start of every generated clip.'),
    ('script_vote_min_score', 7, 'A YES from the Assistant Director counts only when every score is at least this (1-10).'),
    ('max_script_rejections', 2, 'Times the Assistant Director may send a script back before the topic is dropped.'),
    ('film_video_prompt_min_chars', 200, 'Shortest shot description under the film rules.'),
    ('min_beat_chars', 15, 'Shortest description of one timed beat inside a shot.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('cast_rule_text', 'All the children are the same age and the same height, with the same child body proportions; nobody is taller or looks older than the others.', 'Sentence added to every shot with characters.')
on conflict (key) do nothing;
