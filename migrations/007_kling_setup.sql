-- =====================================================================
-- M417 / WIZZLEBURY  -  007 Kling (PiAPI) as the video model
--
-- Run after 006. Safe to run more than once; one transaction.
-- OWNER DECISIONS recorded by running this file:
--   * Video is generated with Kling 2.6, standard mode, through PiAPI.
--   * Price taken from PiAPI's price list on 9 Oct 2026:
--     0.20 USD per 5 s clip, 0.40 USD per 10 s clip (= 0.04 USD / second).
--   * The model is used without a separate paid benchmark: the first
--     shot of the first episode is its trial (pilot approval).
-- Nothing is generated and nothing is spent by running this file;
-- paid generation stays off until set_generation_enabled(true).
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('public.approve_model_pilot(text,text,text)') is null then
        raise exception 'M417_006_NOT_FOUND: apply 006_video_pilot.sql first';
    end if;
end $$;

insert into public.generation_providers (provider_code, display_name, provider_type, status, api_base_url, metadata)
select 'PIAPI_KLING', 'Kling (PiAPI)', 'VIDEO', 'ACTIVE', 'https://api.piapi.ai',
       '{"make_route": "KLING"}'::jsonb
where not exists (select 1 from public.generation_providers where provider_code = 'PIAPI_KLING');

insert into public.generation_models (
    provider_id, model_code, display_name, model_version, media_type, status,
    supports_text_to_video, supports_image_to_video, supports_reference_images,
    min_duration_seconds, max_duration_seconds,
    supported_aspect_ratios, supported_resolutions, capability_metadata)
select gp.id, 'kling-2.6-std', 'Kling 2.6 standard (PiAPI)', '2.6', 'VIDEO', 'ACTIVE',
       true, true, true, 5, 10,
       '["9:16", "16:9", "1:1"]'::jsonb, '["720p"]'::jsonb,
       '{"allowed_durations": [5, 10], "api_model": "kling", "task_type": "video_generation", "mode": "std"}'::jsonb
from public.generation_providers gp
where gp.provider_code = 'PIAPI_KLING'
  and not exists (select 1 from public.generation_models where model_code = 'kling-2.6-std');

insert into public.generation_model_pricing (
    model_id, pricing_version, billing_unit, unit_price, effective_from,
    is_verified, verified_at, source_reference)
select gm.id, 1, 'PER_SECOND', 0.04, now(), true, now(),
       'https://piapi.ai/docs/kling-api/create-task - Kling 2.5/2.6 std: 0.20 USD per 5 s, 10 s costs twice; read 2026-10-09'
from public.generation_models gm
where gm.model_code = 'kling-2.6-std'
  and not exists (select 1 from public.generation_model_pricing p where p.model_id = gm.id);

insert into public.generation_routing_policies (
    policy_code, version, display_name, status,
    minimum_quality_score, minimum_pass_rate, fallback_on_second_attempt)
select 'M417_KLING_PILOT', 1, 'Kling only (pilot)', 'DRAFT', 70, 60, false
where not exists (select 1 from public.generation_routing_policies where policy_code = 'M417_KLING_PILOT');

insert into public.generation_policy_models (policy_id, model_id, route_role, route_priority)
select grp.id, gm.id, 'PRIMARY', 1
from public.generation_routing_policies grp, public.generation_models gm
where grp.policy_code = 'M417_KLING_PILOT' and grp.status = 'DRAFT'
  and gm.model_code = 'kling-2.6-std'
  and not exists (
      select 1 from public.generation_policy_models x
      where x.policy_id = grp.id and x.model_id = gm.id);

update public.generation_routing_policies
set status = 'ACTIVE', approved_at = now()
where policy_code = 'M417_KLING_PILOT' and status = 'DRAFT';

select public.approve_model_pilot(
    'kling-2.6-std', 'FATIH',
    'No separate paid benchmark: the first shot of the first episode is the trial.');

insert into public.events (event_type, severity, source, message, metadata)
values ('VIDEO_MODEL_CONFIGURED', 'INFO', 'CONTROL_PLANE', 'Kling 2.6 std (PiAPI) set as the video model (007).',
        jsonb_build_object('model_code', 'kling-2.6-std', 'usd_per_second', 0.04, 'applied_at', now()));

commit;
