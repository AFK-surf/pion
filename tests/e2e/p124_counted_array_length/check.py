"""P124 structure check.

usage: python3 -E check.py LABEL SSA IMM MIN MAX ALL DYN

In `$pion_fn_probe` of the QBE text SSA, classify the unsigned bounds checks
(`=w cugel IDX, LEN`) by their length operand:
  - the immediate IMM: require MIN <= count <= MAX (MAX -1: unbounded);
  - an SSA temporary (`%...`, a length loaded from an array header): require
    at least DYN of them, and none at all when ALL=1;
  - any other constant: never allowed.
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
    label, path, imm, lo, hi, every, dyn_min = sys.argv[1:8]
    lo, hi, every, dyn_min = int(lo), int(hi), every == '1', int(dyn_min)
    fn = ssa_function(open(path).read(), 'pion_fn_probe')
    checks = re.findall(r'=w cugel (\S+), (\S+)$', fn, re.M)
    hits = [c for c in checks if c[1] == imm]
    dyn = [c for c in checks if c[1].startswith('%')]
    stray = [c for c in checks if c[1] != imm and not c[1].startswith('%')]
    if len(hits) < lo or (hi >= 0 and len(hits) > hi):
        want = f'{lo}..{hi}' if hi >= 0 else f'>= {lo}'
        fail(f'{label}: {len(hits)} bounds checks against {imm}, want {want}\n{fn}')
    if stray:
        fail(f'{label}: bounds checks against unexpected constants: {stray}\n{fn}')
    if every and dyn:
        fail(f'{label}: bounds checks against a loaded length: {dyn}\n{fn}')
    if len(dyn) < dyn_min:
        fail(f'{label}: {len(dyn)} bounds checks against a loaded length, want >= {dyn_min}\n{fn}')
    print(f'p124 {label}: {len(hits)} of {len(checks)} bounds checks against {imm}, {len(dyn)} against a loaded length')


main()
