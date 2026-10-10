"""013 on a database that looks like live: full schema, 012 as it was released (git 330fc16), then 013."""
from lib import *
import subprocess
S = '/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
REPO = '/home/claude/wizzlebury-pipeline'
def apply_file(path):
    r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', path], capture_output=True, text=True)
    return r.returncode, r.stderr
def md5s():
    return one("select string_agg(p.proname || ':' || md5(replace(pg_get_functiondef(p.oid), chr(13), '')), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'm417_internal' and p.proname in ('validate_one_event', 'validate_shot_package', 'step_prompt')")
want = md5s()
want_prompt = one("select md5(replace(body, chr(13), '')) from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3")
old012 = S + '/old_012.sql'
open(old012, 'w').write(subprocess.run(['git', '-C', REPO, 'show', '330fc16:migrations/012_short_format.sql'], capture_output=True, text=True, check=True).stdout)
rc, err = apply_file(old012); check('released 012 applies', rc == 0, err[:300])
subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c',
    "drop function m417_internal.validate_one_event(uuid, jsonb); delete from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3; "
    "update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 2; delete from public.system_settings where key = 'max_beats_per_shot'"], check=True)
check('looks like live: v2 active, no one-event rule', one("select string_agg(version::text, ',') from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and is_active") == '2'
      and one("select to_regprocedure('m417_internal.validate_one_event(uuid, jsonb)') is null") == 't' and md5s() != want)
rc, err = apply_file(S + '/mig/013_one_event.sql'); check('013 applies', rc == 0, err[:300])
rc, err = apply_file(S + '/mig/013_one_event.sql'); check('013 applies twice', rc == 0, err[:300])
check('the three functions equal the full schema', md5s() == want, md5s() + ' / ' + want)
check('the instruction equals the full schema', one("select md5(replace(body, chr(13), '')) from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3") == want_prompt)
check('version 3 is the active one', one("select string_agg(version::text, ',') from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and is_active") == '3')
check('other instructions untouched', one("select string_agg(prompt_code || version, ',' order by prompt_code) from public.step_prompts where is_active") == 'DIRECTOR3,FINAL_QC1,PREQC1,SCRIPT2,SHOT_PACKAGE3,TOPIC2')
check('setting present', one("select value_numeric::int from public.system_settings where key = 'max_beats_per_shot'") == '3')
check('nobody but the owner may call the validator', one("select count(*) from pg_proc p where p.oid = 'm417_internal.validate_one_event(uuid, jsonb)'::regprocedure and (has_function_privilege('service_role', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))") == '0')
print(md5s()); print('prompt', want_prompt)
summary()
