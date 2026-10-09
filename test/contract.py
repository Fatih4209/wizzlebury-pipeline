"""Every RPC the Make scenarios call, with the exact parameter names in their request bodies (from the scenario builds on 8-9 Oct)."""
from lib import *
CALLS = [
 ('M417-S1', 'start_production_job', ['p_idempotency_key', 'p_series_code', 'p_request'], ['job_id']),
 ('M417-S1', 'evaluate_budget_gate', ['p_job_id', 'p_gate_no'], []),
 ('S2/S3/S6/S7', 'job_next_step', ['p_job_id'], ['step_no', 'state']),
 ('S2/S3/S6/S7', 'get_job_context', ['p_job_id'], ['series_bible_text', 'request_text', 'trend_report_text', 'topic_selection_text', 'script_text', 'shot_package_text', 'preqc_report_text', 'music_library_text', 'final_qc_report_text', 'policy_checks_text', 'metadata_candidates_text']),
 ('S2/S3/S7', 'save_artifact', ['p_job_id', 'p_artifact_type', 'p_producer', 'p_content'], []),
 ('S2/S6', 'record_policy_check', ['p_job_id', 'p_gate_no', 'p_checker', 'p_result'], []),
 ('M417-S2', 'get_series_bible', ['p_job_id'], []),
 ('M417-S2', 'route_revision', ['p_job_id'], []),
 ('M417-S2', 'record_final_director_decision', ['p_job_id', 'p_actor', 'p_result'], []),
 ('M417-S2', 'commit_production_package', ['p_job_id'], []),
 ('M417-S3', 'list_voice_work', ['p_job_id'], ['items']),
 ('M417-S3', 'register_voice_take', ['p_line_id', 'p_action', 'p_storage_path', 'p_mp3_bitrate_kbps'], ['take_id']),
 ('M417-S3', 'apply_voice_qc', ['p_take_id', 'p_verdict', 'p_score'], []),
 ('M417-S3', 'check_music_licenses', ['p_job_id'], []),
 ('M417-S4 Sürücü', 'video_work_pending', [], ['pending']),
 ('M417-S4', 'next_video_actions', [], ['items']),
 ('M417-S4', 'prepare_shot_attempt', ['p_shot_id'], []),
 ('M417-S4', 'claim_attempt_submission', ['p_attempt_id', 'p_claimed_by'], ['decision']),
 ('M417-S4', 'record_attempt_submission', ['p_attempt_id', 'p_provider_response'], []),
 ('M417-S4', 'reset_attempt_submission_claim', ['p_attempt_id', 'p_actor', 'p_reason'], []),
 ('M417-S4', 'record_provider_poll', ['p_attempt_id', 'p_provider_response'], []),
 ('M417-S4', 'register_generation_output', ['p_attempt_id', 'p_storage_path'], ['output_id', 'technical_qc']),
 ('M417-S4', 'apply_visual_qc', ['p_output_id', 'p_result'], []),
 ('M417-S4', 'ack_video_advance', ['p_job_id'], []),
 ('M417-S4', 'request_human_approval', ['p_scope_type', 'p_scope_id', 'p_requested_by', 'p_summary'], ['request_id', 'token', 'expires_at']),
 ('M417-S6', 'select_final_audio_track', ['p_job_id'], []),
 ('M417-S6', 'begin_assembly', ['p_job_id'], ['phase', 'render_id', 'sign_request_text', 'shotstack_render_id']),
 ('M417-S6', 'create_render', ['p_job_id', 'p_signed_urls'], ['render_id', 'shotstack_request_text']),
 ('M417-S6', 'mark_render_submitted', ['p_render_id', 'p_shotstack_render_id'], []),
 ('M417-S6', 'record_render_poll', ['p_render_id', 'p_status', 'p_output_url'], ['status', 'storage_path']),
 ('M417-S6', 'complete_render', ['p_render_id', 'p_storage_path'], []),
 ('M417-S6', 'apply_final_qc', ['p_render_id', 'p_result'], []),
 ('M417-S6', 'approve_release', ['p_job_id', 'p_actor', 'p_result'], []),
 ('M417-S7', 'resolve_thumbnail', ['p_job_id'], []),
 ('M417-S7', 'save_publication_package', ['p_job_id', 'p_selected_by', 'p_result'], []),
 ('M417-S7', 'request_publish_approval', ['p_job_id'], ['token', 'title', 'description', 'storage_path', 'storage_base_url', 'notify_chat_id', 'expires_at']),
 ('M417-Onay', 'handle_approval_link', ['p_token', 'p_decision', 'p_decided_by', 'p_channel'], ['scope_type', 'outcome', 'job_id', 'message']),
 ('M417-S8', 'claim_publication', ['p_job_id'], ['decision', 'publication_id', 'storage_path', 'title', 'description', 'tags_csv', 'privacy_status', 'made_for_kids', 'notify_chat_id']),
 ('M417-S8', 'record_publication', ['p_publication_id', 'p_video_id', 'p_url', 'p_status'], []),
 ('M417-S9', 'list_publications_for_analytics', [], ['items']),
 ('M417-S9', 'record_analytics_snapshot', ['p_publication_id', 'p_snapshot_date', 'p_metrics'], []),
 ('M417-S9', 'weekly_learning_input', [], ['week_start', 'input_text']),
 ('M417-S9', 'save_learning_report', ['p_week_start', 'p_report', 'p_model'], ['summary_text', 'notify_chat_id']),
 ('M417-Bakım', 'daily_maintenance', [], ['has_issues', 'message_text', 'notify_chat_id']),
]
if __name__ == '__main__':
    for scen, fn, params, _ in CALLS:
        row = one(f"""select count(*) || '|' || coalesce(max(array_to_string(p.proargnames[1:p.pronargs], ',')), '') || '|' || coalesce(max(p.pronargs - p.pronargdefaults), 0)
                      || '|' || bool_or(has_function_privilege('service_role', p.oid, 'execute'))
                      from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = '{fn}'""")
        cnt, names, required, can = row.split('|')
        names = [x for x in names.split(',') if x]
        check(f'{fn}: exists exactly once (no overloads)', cnt == '1', row)
        check(f'{fn}: Make sends only known parameters', set(params) <= set(names), f'make={params} db={names}')
        check(f'{fn}: Make sends every required parameter', set(names[:int(required)]) <= set(params), f'make={params} required={names[:int(required)]}')
        check(f'{fn}: callable by service_role', can == 't' or can == 'true', row)
    summary()
