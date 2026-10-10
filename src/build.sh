#!/bin/bash
# Concatenate the migration parts into one file.
set -e
cd "$(dirname "$0")"
OUT=002_pipeline_layers.sql
: > $OUT
python3 gen_film.py >/dev/null
for f in p01_schema.sql p01b_film_schema.sql p02_patched_generated.sql p03_patched_manual.sql p04_helpers.sql p05_s1_s3.sql p06_commit_voice.sql p07_video.sql p08_assembly_publish.sql p09_learning_admin.sql p09z_resilience.sql film_a.sql film_b.sql film_c.sql film_d.sql film_prompts.sql short_a.sql short_prompts.sql short_prompts_b.sql p10_grants.sql; do
  [ -f "$f" ] && cat "$f" >> $OUT
done
printf '\ncommit;\n' >> $OUT
wc -l $OUT
