import csv, sys, json, os
csv.field_size_limit(10**9)
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for r in csv.DictReader(open(src, newline='')):
    name = r['bolum']; raw = r['veri']
    try:
        data = json.loads(raw) if raw not in ('', None) else None
    except Exception as e:
        data = {'_parse_error': str(e), 'raw': raw[:500]}
    json.dump(data, open(os.path.join(out, name + '.json'), 'w'), indent=1, ensure_ascii=False)
    n = len(data) if isinstance(data, (list, dict)) else 1
    print(f"{len(raw):8d} bytes  {n:5d} items  {name}")
