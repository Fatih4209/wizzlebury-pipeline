"""Generate CREATE OR REPLACE statements for existing trigger functions, changing only the approval / storyboard conditions."""
import sys, os, re
fn_dir, out = sys.argv[1], sys.argv[2]
def src(n): return open(os.path.join(fn_dir, n + '.sql')).read().rstrip()
def sub(text, old, new, count=1):
    assert text.count(old) == count, (old[:60], text.count(old))
    return text.replace(old, new)
parts = ["""-- ---------------------------------------------------------------------
-- 4. Existing rules, adjusted
--
-- Production is authorised by the Head Director decision (step 14), not
-- by a human approval. Storyboards are required only while the
-- storyboard_required flag is true. Everything else in these functions
-- is unchanged from 001.
-- ---------------------------------------------------------------------"""]
DIRECTOR_OK = "(pm.human_approved = true OR pm.director_approval_id IS NOT NULL)"

# --- attempt gates: accept a director-approved manifest
for n in ['require_manifest_authorized_attempt', 'require_paid_generation_readiness', 'require_production_pilot_gate']:
    t = src(n)
    t = sub(t, "AND pm.human_approved = true", "AND " + DIRECTOR_OK)
    parts.append(t + ';')

# --- storyboard gate: honour the flag
t = src('require_mandatory_storyboard_for_attempt')
t = sub(t, """    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;
""", """    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;

    -- Storyboards are a switchable requirement. A missing flag
    -- means the requirement is on.
    IF COALESCE(
        (
            SELECT sf.value
            FROM public.system_flags sf
            WHERE sf.key = 'storyboard_required'
        ),
        true
    ) IS NOT TRUE
    THEN
        RETURN NEW;
    END IF;
""")
parts.append(t + ';')

# --- episode state machine: APPROVED by human approval OR director decision
t = src('validate_episode_state_transition')
t = sub(t, """    if new.state = old.state then
        return new;
    end if;
""", """    -- ----------------------------------------------------
    -- director_approval_id may only point at an APPROVE
    -- decision made for this episode and production version.
    -- ----------------------------------------------------
    if new.director_approval_id is distinct from old.director_approval_id then
        if new.director_approval_id is null
           or not exists (
               select 1
               from public.director_decisions dd
               where dd.id = new.director_approval_id
                 and dd.episode_id = new.id
                 and dd.production_version = new.production_version
                 and dd.stage = 'PRODUCTION'
                 and dd.decision = 'APPROVE'
           )
        then
            raise exception 'EPISODE_DIRECTOR_APPROVAL_INVALID';
        end if;
    end if;

    if new.state = old.state then
        return new;
    end if;
""")
t = sub(t, """    if new.state = 'APPROVED'
       and new.human_approved is not true
    then
        raise exception 'EPISODE_HUMAN_APPROVAL_REQUIRED';
    end if;
""", """    if new.state = 'APPROVED'
       and new.human_approved is not true
       and new.director_approval_id is null
    then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_REQUIRED';
    end if;
""")
parts.append(t + ';')

# --- request_human_approval: production approvals are retired
t = src('request_human_approval')
t = sub(t, """    if p_scope_id is null then
        raise exception 'APPROVAL_SCOPE_ID_REQUIRED';
    end if;
""", """    -- Production is authorised by the Head Director decision.
    if p_scope_type = 'EPISODE_PRODUCTION' then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_RETIRED';
    end if;
    if p_scope_id is null then
        raise exception 'APPROVAL_SCOPE_ID_REQUIRED';
    end if;
""")
parts.append(t + ';')
# --- routing: a model the owner approved for a pilot counts as benchmarked
t = src('create_generation_routing_decision')
t = sub(t, """        SELECT b1.*

        FROM public.generation_model_benchmarks b1

        WHERE b1.model_id = gpm.model_id

          AND b1.benchmark_status =
                'HUMAN_APPROVED'

          AND b1.approved_at IS NOT NULL

        ORDER BY
            b1.benchmark_version DESC

        LIMIT 1
""", """        -- A paid, human-approved benchmark comes first. Without one,
        -- an owner pilot approval stands in for it: the first shot of
        -- the first episode is then the model's trial (pilot gate, QC
        -- and the two-attempt limit still apply).
        SELECT ev.*

        FROM (

            SELECT
                b1.id,
                b1.benchmark_status,
                b1.approved_at,
                b1.continuity_score,
                b1.motion_score,
                b1.face_score,
                b1.anatomy_score,
                b1.prompt_adherence_score,
                b1.camera_score,
                b1.expression_score,
                b1.lip_sync_score,
                b1.pass_rate,
                b1.average_generation_seconds,
                0 AS evidence_rank,
                b1.benchmark_version AS evidence_version

            FROM public.generation_model_benchmarks b1

            WHERE b1.model_id = gpm.model_id
              AND b1.benchmark_status = 'HUMAN_APPROVED'
              AND b1.approved_at IS NOT NULL

            UNION ALL

            SELECT
                pa.id,
                'HUMAN_APPROVED'::text,
                pa.approved_at,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_pass_rate,
                pa.assumed_generation_seconds,
                1 AS evidence_rank,
                0 AS evidence_version

            FROM public.generation_model_pilot_approvals pa

            WHERE pa.model_id = gpm.model_id
              AND pa.revoked_at IS NULL

        ) ev

        ORDER BY
            ev.evidence_rank,
            ev.evidence_version DESC

        LIMIT 1
""")
parts.append(t + ';')

open(out, 'w').write('\n\n'.join(parts) + '\n')
print('patched functions written:', len(parts) - 1)
