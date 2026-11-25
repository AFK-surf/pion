"""P124 structure check.

usage: python3 -E check.py LABEL SSA IMM MIN MAX ALL

In `$pion_fn_probe` of the QBE text SSA, count the unsigned bounds checks
(`=w cugel IDX, LEN`) whose length operand is the immediate IMM; require
MIN <= count <= MAX (MAX -1: unbounded). With ALL=1, every bounds check of the
function must use the immediate, i.e. no array header length feeds a check.
"""
import re
import sys


def fail(msg):
    print(f'FAIL: p124 {msg}', file=sys.stderr)
    sys.exit(1)


def ssa_function(text, func):
    m = re.search(r'^(?:export )?function [^\n]*\$' + re.escape(func) + r'\(', text, re.M)
    if not m:
        fail(f'no function ${func} in the QBE text')
    end = text.index('\n}\n', m.start())
    return text[m.start():end]


def main():
    label, path, imm, lo, hi, every = sys.argv[1:7]
    lo, hi, every = int(lo), int(hi), every == '1'
    fn = ssa_function(open(path).read(), 'pion_fn_probe')
    checks = re.findall(r'=w cugel (\S+), (\S+)$', fn, re.M)
    hits = [c for c in checks if c[1] == imm]
    if len(hits) < lo or (hi >= 0 and len(hits) > hi):
        want = f'{lo}..{hi}' if hi >= 0 else f'>= {lo}'
        fail(f'{label}: {len(hits)} bounds checks against {imm}, want {want}\n{fn}')
    if every:
        other = [c for c in checks if c[1] != imm]
        if other:
            fail(f'{label}: bounds checks not against {imm}: {other}\n{fn}')
    print(f'p124 {label}: {len(hits)} of {len(checks)} bounds checks against {imm}')


main()
