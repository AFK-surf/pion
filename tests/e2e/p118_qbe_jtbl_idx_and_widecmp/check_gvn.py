"""usage: python3 -E check_gvn.py bounds_expect.txt DUMP (qbe -d G)

Every function: `0` / `1` -> no comparison left and that constant returned;
`keep` -> the 64-bit signed comparison (or its branch) is still there.
"""
import re
import sys

expect = [ln.split() for ln in open(sys.argv[1]).read().split('\n') if ln.strip()]
parts = re.split(r'\*\*\*\* Function (\S+) \*\*\*\*', open(sys.argv[2]).read())
body = dict(zip(parts[1::2], parts[2::2]))
if [e[0] for e in expect] != parts[1::2] or not expect:
    raise SystemExit('FAIL: p118 gvn: dump does not list the expected functions')
tally = {'0': 0, '1': 0, 'keep': 0}
for name, want in expect:
    text = body[name].split('> After GVN:', 1)
    if len(text) != 2:
        raise SystemExit(f'FAIL: p118 gvn: no GVN dump of {name}')
    dump = text[1].split('\n> ', 1)[0]
    cmps = re.findall(r'\b(cs(?:ge|gt|le|lt)l)\b', dump)
    rets = re.findall(r'^\s*ret\w* (\S+)$', dump, re.M)
    branch = re.search(r'\bjnz\b', dump) is not None
    if want == 'keep':
        ok = len(cmps) == 1
    else:
        ok = not cmps and not branch and rets == [want]
    if not ok:
        raise SystemExit(f'FAIL: p118 gvn: {name}: want {want}, compares {cmps}, returns {rets}:\n{dump}')
    tally[want] += 1
if min(tally.values()) == 0:
    raise SystemExit(f'FAIL: p118 gvn: {tally}')
print(f'p118 gvn: {len(expect)} comparisons: {tally["1"]} folded to 1, {tally["0"]} folded to 0, {tally["keep"]} kept')
