"""Rebuild table DDL from the information_schema.columns export and the pg_constraint export."""
import csv, sys, collections
cols_path, cons_path, out_path = sys.argv[1:4]
tables = collections.OrderedDict()
for r in csv.DictReader(open(cols_path, newline='')):
    tables.setdefault(r['table_name'], []).append(r)
def coltype(r):
    return {'timestamp with time zone': 'timestamptz'}.get(r['data_type'], r['data_type'])
out = []
for t, cols in tables.items():
    lines = []
    for c in cols:
        l = f'    "{c["column_name"]}" {coltype(c)}'
        if c['column_default'] not in ('null', '', None):
            l += f' default {c["column_default"]}'
        if c['is_nullable'] == 'NO':
            l += ' not null'
        lines.append(l)
    out.append(f'create table public."{t}" (\n' + ',\n'.join(lines) + '\n);')
cons = list(csv.DictReader(open(cons_path, newline='')))
order = {'p': 0, 'u': 1, 'c': 2, 'f': 3}
for r in sorted(cons, key=lambda r: order[r['contype']]):
    out.append(f'alter table public."{r["tablo"]}" add constraint "{r["conname"]}" {r["tanim"]};')
open(out_path, 'w').write('\n'.join(out) + '\n')
print(len(tables), 'tables,', len(cons), 'constraints')
