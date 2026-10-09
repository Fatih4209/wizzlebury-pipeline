CREATE OR REPLACE FUNCTION public.episode_production_status(p_episode_id uuid)
 RETURNS TABLE(episode_state text, production_version integer, total_shots integer, locked_shots integer, cancelled_shots integer, escalated_shots integer, retry_required_shots integer, in_progress_shots integer, not_started_shots integer, pilot_locked boolean, ready_for_assembly boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

    select
        e.state,
        e.production_version,
        count(s.id)::integer,
        count(*) filter (where s.state = 'LOCKED')::integer,
        count(*) filter (where s.state = 'CANCELLED')::integer,
        count(*) filter (where s.state = 'ESCALATED')::integer,
        count(*) filter (where s.state = 'RETRY_REQUIRED')::integer,
        count(*) filter (
            where s.state in (
                'QUEUED',
                'GENERATING',
                'GENERATED',
                'QC_PENDING',
                'FAILED_TECHNICAL'
            )
        )::integer,
        count(*) filter (
            where s.state in (
                'PLANNED',
                'STORYBOARD_PENDING',
                'STORYBOARD_APPROVED',
                'AUDIO_READY'
            )
        )::integer,
        coalesce(
            bool_or(s.id = pm.pilot_shot_id and s.state = 'LOCKED'),
            false
        ),
        (
            count(s.id) > 0
            and count(*) filter (where s.state = 'LOCKED') > 0
            and count(*) filter (
                    where s.state not in ('LOCKED', 'CANCELLED')
                ) = 0
        )

    from public.episodes e

    left join public.production_manifests pm
      on pm.episode_id = e.id
     and pm.production_version = e.production_version
     and pm.status = 'LOCKED'

    left join public.production_manifest_shots pms
      on pms.manifest_id = pm.id

    left join public.shots s
      on s.id = pms.shot_id

    where e.id = p_episode_id

    group by e.state, e.production_version;

$function$
