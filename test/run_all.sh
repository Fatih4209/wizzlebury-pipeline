#!/bin/bash
# Full test run: every suite on a fresh replica, then the re-apply check.
S=/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad
cd $S/test; rc=0
for t in test_s1_s3 test_e2e test_paths test_rules; do
  ./reset.sh || exit 1
  printf '%-14s ' $t; python3 $t.py | tail -n 3 | tr '\n' ' '; [ ${PIPESTATUS[0]} -eq 0 ] || rc=1; echo
done
./reset.sh; printf '%-14s ' contract; python3 contract.py | tail -1 || rc=1
# re-apply on a database that already has a finished job
./reset.sh; python3 test_e2e.py >/dev/null
before=$(psql -X -At -d m417 -c "select (select count(*) from public.production_jobs)||'/'||(select count(*) from public.job_artifacts)||'/'||(select count(*) from public.system_text_settings)||'/'||(select value from public.system_text_settings where key='notify_chat_id')||'/'||(select value from public.system_flags where key='pipeline_enabled')")
out=$(psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/mig/002_pipeline_layers.sql 2>&1 | grep -v -e NOTICE -e '^$'); ec=$?
after=$(psql -X -At -d m417 -c "select (select count(*) from public.production_jobs)||'/'||(select count(*) from public.job_artifacts)||'/'||(select count(*) from public.system_text_settings)||'/'||(select value from public.system_text_settings where key='notify_chat_id')||'/'||(select value from public.system_flags where key='pipeline_enabled')")
if [ "$before" == "$after" ] && [ -z "$out" ]; then echo "re-apply       ok: data and settings unchanged ($after)"; else echo "re-apply       FAIL: $before -> $after $out"; rc=1; fi
printf '%-14s ' 'after re-apply'; python3 contract.py | tail -1
exit $rc
