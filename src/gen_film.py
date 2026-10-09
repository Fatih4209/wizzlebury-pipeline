#!/usr/bin/env python3
"""Builds film_d.sql: functions of the 009 state with the 010 changes patched in.
Every patch must match exactly once, so a drifted source stops the build."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'mig_before_010')

def fn(file, name):
    t = open(os.path.join(SRC, file)).read()
    i = t.find('create or replace function ' + name + '(')
    assert i >= 0, name
    j = t.find('$function$;', i)
    assert j >= 0, name
    return t[i:j + len('$function$;')] + '\n'

def patch(text, old, new, count=1):
    assert text.count(old) == count, (old[:70], text.count(old))
    return text.replace(old, new)

out = ['\n-- ----- functions changed for the film rules and the two-yes rule -----\n']

# ---- get_job_context -------------------------------------------------
t = fn('p05_s1_s3.sql', 'public.get_job_context')
t = patch(t, "        'assistant_review_text', '',\n",
          "        'assistant_review_text', m417_internal.artifact_text(p_job_id, 'SCRIPT_REVIEW'),\n"
          "        'two_yes_text', m417_internal.two_yes(p_job_id)::text,\n"
          "        'prompt_text', m417_internal.step_prompt(p_job_id, v_job.current_step, v_request::text, v_preqc),\n")
t = patch(t, """        'final_qc_report_text', coalesce((
            select r.qc_result::text
""", """        -- The accepted verdict only: the reviewer's raw verdict and the
        -- system note read as a contradiction to the policy gate.
        'final_qc_report_text', coalesce((
            select ((r.qc_result - 'reviewer_verdict' - 'system_note' - 'overruled')
                    || case when r.qc_result ? 'system_note'
                            then jsonb_build_object('lip_sync_policy',
                                 'Lip-sync is not produced in this version by owner decision; lip-sync findings are informational and do not affect the verdict.')
                            else '{}'::jsonb end)::text
""")
t = patch(t, """            from public.policy_checks pc
            where pc.job_id = p_job_id),
""", """            -- The check in force per gate: a repeated gate replaces its
            -- earlier result instead of contradicting it.
            from (
                select distinct on (x.gate_no) x.*
                from public.policy_checks x
                where x.job_id = p_job_id
                order by x.gate_no, x.created_at desc
            ) pc),
""")
out.append(t)

# ---- save_artifact ---------------------------------------------------
t = fn('p05_s1_s3.sql', 'public.save_artifact')
t = patch(t, "    v_continue boolean;\nbegin\n", """    v_continue boolean;
    v_vote jsonb;
    v_stated text;
    v_decision text;
    v_low numeric;
    v_scored integer;
    v_vote_issue jsonb;
    v_script_id uuid;
    v_review_version integer;
begin
""")
t = patch(t, "    -- Problems the writer can fix go back to the writer.\n", """    -- Two-yes rule, first vote: the Assistant Director votes on the
    -- script in the same answer that carries the shots.
    if v_type = 'SHOT_PACKAGE' and m417_internal.flag('assistant_vote_required', false) then
        v_vote := p_content -> 'script_vote';
        v_stated := upper(btrim(coalesce(v_vote ->> 'decision', '')));
        v_script_id := m417_internal.current_script_id(p_job_id);
        if v_script_id is null then
            raise exception 'SCRIPT_MISSING';
        end if;
        select min(m417_internal.safe_numeric(s.value)),
               count(*) filter (where m417_internal.safe_numeric(s.value) is not null)
        into v_low, v_scored
        from jsonb_each_text(case when jsonb_typeof(v_vote -> 'scores') = 'object'
                                  then v_vote -> 'scores' else '{}'::jsonb end) s(key, value);
        if jsonb_typeof(v_vote) is distinct from 'object' or v_stated not in ('YES', 'NO') then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'script_vote is missing, or its decision is not YES or NO.',
                'Return script_vote {decision, scores, strengths, problems, required_changes} together with the shots.');
        elsif v_stated = 'YES' and v_scored < 5 then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'A YES needs the five scores: hook, story, humor, dialogue, filmability (1 to 10).',
                'Return all five scores in script_vote.scores.');
        else
            v_decision := case when v_stated = 'YES'
                                    and v_low >= m417_internal.num('script_vote_min_score', 7)
                               then 'YES' else 'NO' end;
            insert into public.script_votes (
                job_id, script_artifact_id, voter, voter_role, decision, stated_decision, scores, result)
            values (
                p_job_id, v_script_id, 'OPENAI', 'ASSISTANT_DIRECTOR', v_decision, v_stated,
                case when jsonb_typeof(v_vote -> 'scores') = 'object' then v_vote -> 'scores' else '{}'::jsonb end,
                v_vote);
            perform m417_internal.retire_artifacts(p_job_id, array['SCRIPT_REVIEW']);
            select coalesce(max(a.version), 0) + 1 into v_review_version
            from public.job_artifacts a
            where a.job_id = p_job_id and a.artifact_type = 'SCRIPT_REVIEW';
            insert into public.job_artifacts (job_id, artifact_type, producer, version, content)
            values (p_job_id, 'SCRIPT_REVIEW', 'OPENAI', v_review_version,
                    v_vote || jsonb_build_object('decision', v_decision, 'stated_decision', v_stated));
            if v_decision = 'NO' then
                perform m417_internal.usage(p_job_id, 'OPENAI', 'SCRIPT_REVIEW');
                return m417_internal.script_rejected(p_job_id, v_vote, v_stated)
                    || jsonb_build_object('version', v_review_version);
            end if;
        end if;
    end if;

    -- Problems the writer can fix go back to the writer.
""")
t = patch(t, """        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
    end if;
""", """        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
        if v_vote_issue is not null then
            v_issues := jsonb_build_array(v_vote_issue) || v_issues;
        end if;
    end if;
""")
t = patch(t, "        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT']);\n",
          "        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT', 'SCRIPT_REVIEW']);\n")
t = patch(t, """        where id = v_job.episode_id;
    end if;
""", """        where id = v_job.episode_id;
        -- A new topic starts with a clean count of script rejections.
        update public.production_jobs set script_no_count = 0 where id = p_job_id;
    end if;
""")
out.append(t)

# ---- record_final_director_decision ----------------------------------
t = fn('p05_s1_s3.sql', 'public.record_final_director_decision')
t = patch(t, """            raise exception 'DIRECTOR_APPROVAL_CONTRADICTS_ITS_OWN_FINDINGS';
        end if;
""", """            raise exception 'DIRECTOR_APPROVAL_CONTRADICTS_ITS_OWN_FINDINGS';
        end if;
        -- Two-yes rule: the Assistant Director's YES comes first.
        if m417_internal.flag('assistant_vote_required', false)
           and not m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_ASSISTANT_YES';
        end if;
""")
t = patch(t, "    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');\n", """    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');
    -- Two-yes rule, second vote.
    if m417_internal.current_script_id(p_job_id) is not null then
        insert into public.script_votes (
            job_id, script_artifact_id, voter, voter_role, decision, stated_decision, result)
        values (
            p_job_id, m417_internal.current_script_id(p_job_id), 'CLAUDE', 'HEAD_DIRECTOR',
            case when v_decision = 'APPROVE' then 'YES' else 'NO' end, v_decision, p_result);
    end if;
""")
out.append(t)

# ---- commit_production_package ---------------------------------------
t = fn('p06_commit_voice.sql', 'public.commit_production_package')
t = patch(t, "    v_i integer;\nbegin\n", """    v_i integer;
    v_edit numeric;
    v_cut numeric;
    v_speaker_id uuid;
    v_stage text;
begin
""")
t = patch(t, """        raise exception 'DIRECTOR_APPROVAL_MISSING';
    end if;
""", """        raise exception 'DIRECTOR_APPROVAL_MISSING';
    end if;
    -- Two-yes rule: nothing is produced without a YES from both.
    if m417_internal.flag('assistant_vote_required', false)
       and not (m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
                and m417_internal.has_yes(p_job_id, 'HEAD_DIRECTOR'))
    then
        raise exception 'TWO_YES_REQUIRED: %', m417_internal.two_yes(p_job_id)::text;
    end if;
""")
t = patch(t, """        -- Who is in the shot: listed characters plus everyone who speaks.
""", """        -- A film shot carries its cut length and the staging of its line.
        v_edit := case when m417_internal.film_on()
                       then m417_internal.safe_numeric(v_shot ->> 'edit_seconds') end;
        v_stage := case when v_edit is not null then m417_internal.voice_stage(v_shot ->> 'voice_staging') end;

        -- Who is in the shot: listed characters plus everyone who speaks
        -- (a speaker staged off-screen is heard, not seen).
""")
t = patch(t, """            select m417_internal.resolve_character(v_job.series_id, l.value ->> 'character')
            from jsonb_array_elements(v_lines) l(value)
        ) x
""", """            select m417_internal.resolve_character(v_job.series_id, l.value ->> 'character')
            from jsonb_array_elements(v_lines) l(value)
            where v_stage is distinct from 'OFF_SCREEN'
        ) x
""")
t = patch(t, """        select coalesce(jsonb_agg(c.character_code order by c.character_code), '[]'::jsonb)
        into v_char_codes
""", """        v_speaker_id := m417_internal.resolve_character(v_job.series_id, v_lines -> 0 ->> 'character');
        v_cut := case when v_edit is not null then m417_internal.planned_cut(v_edit, (
                     select coalesce(sum(m417_internal.speech_seconds(l.value ->> 'text')), 0)
                     from jsonb_array_elements(v_lines) l(value))) end;

        select coalesce(jsonb_agg(c.character_code order by c.character_code), '[]'::jsonb)
        into v_char_codes
""")
t = patch(t, """            continuity_notes, audio_required, voice_required, status)
        values (
""", """            continuity_notes, audio_required, voice_required, status,
            edit_seconds, film_size, shot_purpose, voice_staging, beats, props, qc_brief)
        values (
""")
t = patch(t, """            case
                when v_camera ~ '(extreme close|close[- ]?up|closeup)' then 'CLOSE_UP'
                when v_camera ~ '(wide|establishing|long shot|full shot)' then 'WIDE'
                else 'MEDIUM'
            end,
""", """            case
                when v_edit is not null and m417_internal.film_size(v_shot ->> 'shot_size') is not null
                    then m417_internal.film_size(v_shot ->> 'shot_size')
                when v_camera ~ '(extreme close|close[- ]?up|closeup)' then 'CLOSE_UP'
                when v_camera ~ '(wide|establishing|long shot|full shot)' then 'WIDE'
                else 'MEDIUM'
            end,
""")
t = patch(t, """            m417_internal.compose_prompt(v_job.series_id, v_shot, v_char_ids, v_loc_id),
""", """            case when v_edit is not null
                 then m417_internal.compose_shot_prompt(
                          v_job.series_id, v_script, v_shot, v_char_ids, v_loc_id, v_speaker_id, v_cut)
                 else m417_internal.compose_prompt(v_job.series_id, v_shot, v_char_ids, v_loc_id) end,
""")
t = patch(t, """            false, jsonb_array_length(v_lines) > 0, 'DRAFT')
        returning id into v_spec_id;
""", """            false, jsonb_array_length(v_lines) > 0, 'DRAFT',
            v_edit,
            case when v_edit is not null then m417_internal.film_size(v_shot ->> 'shot_size') end,
            case when v_edit is not null then nullif(upper(btrim(v_shot ->> 'purpose')), '') end,
            case when jsonb_array_length(v_lines) > 0 then v_stage end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'beats') = 'array'
                 then v_shot -> 'beats' else '[]'::jsonb end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'props') = 'array'
                 then v_shot -> 'props' else '[]'::jsonb end,
            case when v_edit is not null
                 then m417_internal.shot_qc_brief(v_job.series_id, v_script, v_shot, v_char_ids, v_speaker_id, v_cut) end)
        returning id into v_spec_id;
""")
out.append(t)

# ---- voice takes measured against the cut -----------------------------
for name in ('m417_internal.judge_voice_take', 'm417_internal.voice_retake_plan'):
    t = fn('p06_commit_voice.sql', name)
    t = patch(t, """    select ss.duration_seconds into v_spec_duration
    from public.shot_specifications ss where ss.id = v_take.shot_specification_id;
""", """    -- Room for voice in the cut of this shot (the whole shot for shots
    -- planned before the film rules).
    v_spec_duration := m417_internal.voice_room(v_take.shot_specification_id);
""")
    out.append(t)

# ---- video_scan: the reviewer's brief ----------------------------------
t = fn('p07_video.sql', 'm417_internal.video_scan')
t = patch(t, """                   ss.character_codes
            from public.production_manifest_shots pms
""", """                   ss.character_codes, ss.qc_brief
            from public.production_manifest_shots pms
""")
t = patch(t, """                        'continuity_notes', v_shot.continuity_notes,
                        'characters', (
                            select coalesce(jsonb_agg(jsonb_build_object(
                                       'name', c.name, 'description', c.canonical_description)), '[]'::jsonb)
""", """                        'continuity_notes', v_shot.continuity_notes,
                        'film', v_shot.qc_brief,
                        'characters', (
                            select coalesce(jsonb_agg(jsonb_build_object(
                                       'name', c.name, 'description', c.canonical_description,
                                       'look_notes', (
                                           select v.wardrobe_note
                                           from public.asset_registry ar
                                           join public.video_reference_images v
                                             on v.asset_id = ar.id and v.is_active = true
                                           where ar.character_id = c.id
                                             and coalesce(btrim(v.wardrobe_note), '') <> ''
                                           limit 1))), '[]'::jsonb)
""")
out.append(t)

# ---- create_render: cuts ----------------------------------------------
t = fn('p08_assembly_publish.sql', 'public.create_render')
t = patch(t, """            'asset', jsonb_build_object('type', 'video', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 0),
""", """            'asset', jsonb_build_object('type', 'video', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 0)
                     || case when coalesce((v_clip ->> 'trim')::numeric, 0) > 0
                             then jsonb_build_object('trim', (v_clip ->> 'trim')::numeric) else '{}'::jsonb end,
""")
out.append(t)

# ---- complete_render: an edit rendered again after a resume --------------
t = fn('p08_assembly_publish.sql', 'public.complete_render')
t = patch(t, """    if v_job.current_step = 31 and v_job.state = 'READY' then
        update public.episodes set state = 'FINAL_QC'
        where id = v_job.episode_id and state = 'ASSEMBLY';
""", """    -- An edit rendered again after the owner resumed a job stopped at
    -- final QC arrives here with the job already at step 32; the episode
    -- has to reach FINAL_QC on that path as well.
    if v_job.state = 'READY' and v_job.current_step in (31, 32) then
        update public.episodes set state = 'FINAL_QC'
        where id = v_job.episode_id and state = 'ASSEMBLY';
    end if;
    if v_job.current_step = 31 and v_job.state = 'READY' then
""")
RENDER_FIX = t
out.append(t)

# ---- block reasons ------------------------------------------------------
t = fn('p09z_resilience.sql', 'm417_internal.block_reason_tr')
t = patch(t, "        when 'STALLED' then", "        when 'SCRIPT_NOT_AGREED' then 'Yönetmen ile yardımcı yönetmen senaryoda anlaşamadı; iki evet çıkmadı.'\n        when 'STALLED' then")
out.append(t)

open(os.path.join(HERE, 'film_d.sql'), 'w').write('\n'.join(out))
open(os.path.join(HERE, '011_render_after_resume.sql'), 'w').write('''-- =====================================================================
-- M417 / WIZZLEBURY  -  011 final QC after a resumed render
--
-- Run after 010. Safe to run more than once. Nothing is spent.
-- A job stopped at final QC and resumed by the owner renders again with
-- the job at step 32; the episode stayed in ASSEMBLY and the release
-- approval was then refused (INVALID_EPISODE_STATE_TRANSITION).
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.step_prompt(uuid,integer,text,text)') is null then
        raise exception 'M417_010_NOT_FOUND: apply 010_film_grammar.sql first';
    end if;
end $$;

''' + RENDER_FIX + '''
notify pgrst, 'reload schema';

commit;
''')
print('film_d.sql', sum(len(x) for x in out), 'chars')
