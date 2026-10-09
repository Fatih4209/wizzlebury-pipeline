"""Tiny test driver: every rpc() is one transaction as service_role, like a Make module calling PostgREST."""
import json, subprocess, sys
DB = 'm417'
class RpcError(Exception): pass
passed = failed = 0
SEEN = {}
def _psql(sql, role=None):
    pre = f"set role {role};" if role else ""
    r = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', pre + sql],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RpcError(r.stderr.strip().split('\n')[0].replace('ERROR:  ', ''))
    return r.stdout.strip()
def sql(q): return _psql(q)
def one(q): return _psql(q)
def rpc(fn, args=None, obj=False):
    lit = json.dumps(args or {}, ensure_ascii=False)
    assert '$a$' not in lit
    out = _psql(f"select t.rpc('{fn}', $a${lit}$a$::jsonb, {'true' if obj else 'false'})", role='service_role')
    res = json.loads(out) if out else None
    if isinstance(res, dict):
        SEEN.setdefault(fn, set()).update(res.keys())
    return res
def check(name, cond, detail=''):
    global passed, failed
    if cond: passed += 1
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")
def expect_error(name, fn, args, needle):
    try:
        r = rpc(fn, args); check(name, False, f"no error; got {str(r)[:160]}")
    except RpcError as e:
        check(name, needle in str(e), f"got: {e}")
def put(path, size, mime='audio/mpeg'):
    sql(f"select t.put($p${path}$p$, {size}, '{mime}')")
def summary():
    print(f"\n{passed} passed, {failed} failed"); sys.exit(1 if failed else 0)
