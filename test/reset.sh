#!/bin/bash
# Fresh replica + migration + test helpers.
set -e
S=/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad
(cd $S/mig && ./build.sh >/dev/null)
bash $S/work/load_base.sh $S/work m417 >/dev/null 2>&1
psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/mig/002_pipeline_layers.sql 2>&1 | grep -v -e NOTICE -e '^$' || true
psql -X -q -v ON_ERROR_STOP=1 -d m417 -f $S/test/harness.sql
