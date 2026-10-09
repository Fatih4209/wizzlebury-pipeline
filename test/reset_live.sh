#!/bin/bash
# The database as it is live: 002 as delivered on 9 Oct, then the patches, each applied twice.
set -e
S=/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad
bash $S/work/load_base.sh $S/work m417 >/dev/null 2>&1
psql -X -q -v ON_ERROR_STOP=1 -d m417 -f /mnt/user-data/outputs/002_pipeline_layers.sql 2>&1 | grep -v -e NOTICE -e '^$' || true
for i in 1 2; do for f in /mnt/user-data/outputs/003_dialogue_timing.sql /mnt/user-data/outputs/004_speech_pauses.sql /mnt/user-data/outputs/005_resilience.sql $S/mig/006_video_pilot.sql; do
  psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $f 2>&1 | grep -v -e NOTICE -e '^$' || true; done; done
psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/test/harness.sql
