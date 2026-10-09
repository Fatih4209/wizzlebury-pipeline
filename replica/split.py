import csv, sys, os
csv.field_size_limit(10**9)
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
rows = list(csv.DictReader(open(src, newline='')))
print(len(rows), 'functions')
seen = {}
for r in rows:
    n = r['proname']; seen[n] = seen.get(n, 0) + 1
    fn = n if seen[n] == 1 else f"{n}__{seen[n]}"
    open(os.path.join(out, fn + '.sql'), 'w').write(r['kaynak'])
    print(f"{len(r['kaynak']):7d}  {n}")
