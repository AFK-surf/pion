"""Self-test of check_dump.py: tampered `-d SR` dumps must be rejected.

usage: python3 -E mutate_dump.py DUMP EXPECT CHECK_DUMP OUT_DIR

In the register allocation dump of `sink7`, the first table target that
starts with a moved store is tampered with in five ways, each of which
check_dump.py must reject (non-zero exit, a `FAIL:` line):

  dup    the prepended store is duplicated;
  reg    it stores from another register;
  move   it moves to a table target that cannot read the home;
  extra  a copy of it is added to such a target (the original stays);
  late   a copy of it is added after the first instruction of that target.
"""
import re
import subprocess
import sys
from pathlib import Path

DUMP, EXPECT, CHECK, OUT = sys.argv[1:5]
text = open(DUMP).read()
start = text.index('**** Function sink7 ****')
rega = text.index('> After register allocation:', start)
end = text.find('**** Function ', rega)
end = len(text) if end < 0 else end
head, body, tail = text[:rega], text[rega:end], text[end:]
lines = body.split('\n')
jt = [ln for ln in lines if ln.startswith('\tjtbl ')]
if len(jt) != 1:
    raise SystemExit('FAIL: p114 mutate: sink7 has no single jtbl')
targets = list(dict.fromkeys(re.findall(r'@(\w+)', jt[0])))
label = {ln[1:]: k for k, ln in enumerate(lines) if ln.startswith('@')}
store = re.compile(r'^\tstore[wl] (R\d+), (S\d+)$')
victim = None
for t in targets:
    m = store.match(lines[label[t] + 1])
    if m:
        victim = (t, label[t] + 1, m)
        break
if victim is None:
    raise SystemExit('FAIL: p114 mutate: no table target of sink7 starts with a store')
t, k, m = victim
slot = m.group(2)
other = [u for u in targets if u != t and not any(
    (store.match(ln) or [None, None, None])[2] == slot
    for ln in lines[label[u] + 1:label[u] + 8])]
if not other:
    raise SystemExit('FAIL: p114 mutate: no target without the store')
# Prefer the arm @a0 (or its edge-copy block), which never reads the homes.
other.sort(key=lambda u: not (u == 'a0' or u.endswith('_a0')))
regs = sorted({int(r) for r in re.findall(r'\bR(\d+)\b', body)})
wrong = next(f'R{r}' for r in regs if f'R{r}' != m.group(1))


def variant(kind):
    ls = list(lines)
    if kind == 'dup':
        ls.insert(k, ls[k])
    elif kind == 'reg':
        ls[k] = ls[k].replace(m.group(1) + ',', wrong + ',', 1)
    elif kind == 'move':
        moved = ls.pop(k)
        ls.insert(ls.index('@' + other[0]) + 1, moved)
    elif kind == 'extra':
        ls.insert(ls.index('@' + other[0]) + 1, ls[k])
    else:
        at = ls.index('@' + other[0]) + 1
        if ls[at].startswith('@') or ls[at].startswith('\tj') or ls[at].startswith('\tret'):
            raise SystemExit(f'FAIL: p114 mutate: {other[0]} has no first instruction')
        ls.insert(at + 1, ls[k])
    return head + '\n'.join(ls) + tail


for kind in ('dup', 'reg', 'move', 'extra', 'late'):
    path = Path(OUT) / f'mutant_{kind}.txt'
    path.write_text(variant(kind))
    r = subprocess.run([sys.executable, '-E', CHECK, str(path), EXPECT, f'mutant-{kind}'],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    msg = (r.stderr.strip().split('\n') or [''])[-1]
    if r.returncode == 0 or not msg.startswith('FAIL: p114 mutant-'):
        raise SystemExit(f'FAIL: p114 check_dump accepted the {kind} mutant of {t} {m.group(0).strip()}')
    if kind in ('extra', 'late') and 'not a target that can read it' not in msg:
        raise SystemExit(f'FAIL: p114 the extra store at {other[0]} was not reported: {msg}')
    print(f'p114 check_dump rejects {kind} ({t}: {m.group(0).strip()}): {msg}')
