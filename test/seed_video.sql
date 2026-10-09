-- TEST ONLY: a qualified video catalog (Kling primary via PiAPI, Veo fallback).
-- Benchmarks are inserted with triggers off because real ones need paid evidence.
insert into public.generation_providers (provider_code, display_name, provider_type, status, metadata)
values ('PIAPI_KLING', 'PiAPI Kling', 'VIDEO', 'ACTIVE', '{"make_route": "KLING"}');
insert into public.generation_models (provider_id, model_code, display_name, model_version, media_type, status,
    supports_text_to_video, supports_image_to_video, supports_reference_images, min_duration_seconds, max_duration_seconds,
    supported_aspect_ratios, supported_resolutions, capability_metadata)
select id, 'kling-std', 'Kling std', '2.6', 'VIDEO', 'ACTIVE', true, true, true, 5, 10,
       '["9:16","16:9"]', '["720p"]', '{"allowed_durations": [5, 10]}'
from public.generation_providers where provider_code = 'PIAPI_KLING';
insert into public.generation_model_pricing (model_id, pricing_version, billing_unit, unit_price, effective_from, is_verified, verified_at, source_reference)
select id, 1, 'PER_SECOND', 0.05, now() - interval '1 day', true, now(), 'TEST' from public.generation_models where model_code = 'kling-std';
set session_replication_role = replica;
update public.generation_models set min_duration_seconds = 5, max_duration_seconds = 8 where model_code = 'veo-3.1-fast-generate-preview';
insert into public.generation_model_benchmarks (model_id, benchmark_version, benchmark_name, benchmark_status,
    continuity_score, motion_score, face_score, anatomy_score, prompt_adherence_score, camera_score, expression_score, lip_sync_score,
    pass_rate, average_generation_seconds, sample_size, tested_at, approved_at)
select id, 1, 'test', 'HUMAN_APPROVED', 85, 85, 85, 85, 85, 85, 85, 85, 90, 120, 3, now(), now()
from public.generation_models where model_code in ('kling-std', 'veo-3.1-fast-generate-preview');
set session_replication_role = origin;
insert into public.generation_routing_policies (policy_code, version, display_name, status, minimum_quality_score, minimum_pass_rate)
values ('M417_DEFAULT', 1, 'Default', 'DRAFT', 70, 60);
insert into public.generation_policy_models (policy_id, model_id, route_role, route_priority)
select p.id, m.id, case m.model_code when 'kling-std' then 'PRIMARY' else 'FALLBACK' end, 1
from public.generation_routing_policies p, public.generation_models m
where p.policy_code = 'M417_DEFAULT' and m.model_code in ('kling-std', 'veo-3.1-fast-generate-preview');
update public.generation_routing_policies set status = 'ACTIVE', approved_at = now() where policy_code = 'M417_DEFAULT';
update public.system_settings set value_numeric = 0 where key in ('video_driver_min_interval_seconds', 'video_poll_min_interval_seconds');
