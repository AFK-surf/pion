"""Write a broken copy of `qbe -t amd64_win` text for the checker self-tests.

usage: python3 -E mutate.py KIND IN.s OUT.s
Each kind breaks one Win64 frame rule in one function; the output differs
from the input (exit 1 when the kind finds nothing to break).
"""
import re
import sys

kind, src, dst = sys.argv[1:4]
lines = open(src).read().split('\n')


def func(name):
    a = lines.index(f'{name}:')
    b = next(i for i in range(a, len(lines)) if lines[i].startswith('/* end function'))
    return a, b


def first(pat, lo=0, hi=None):
    hi = len(lines) if hi is None else hi
    for i in range(lo, hi):
        if re.match(pat, lines[i]):
            return i
    sys.exit(f'mutate {kind}: no {pat!r}')


if kind == 'norestore':      # one xmm9 restore dropped
    del lines[first(r'^\tmovups -?\d+\(%r[sb]p\), %xmm9$')]
elif kind == 'nosave15':     # xmm15 used but neither saved nor described
    i = first(r'^\tmovups %xmm15, \d+\(%rsp\)$')
    del lines[i:i + (2 if lines[i + 1].startswith('\t.seh_savexmm') else 1)]
elif kind == 'moved':        # one restore from the wrong cell
    i = first(r'^\tmovups \d+\(%r[sb]p\), %xmm7$')
    m = re.match(r'^\tmovups (\d+)\((%r[sb]p)\), %xmm7$', lines[i])
    lines[i] = f'\tmovups {int(m.group(1)) + 16}({m.group(2)}), %xmm7'
elif kind == 'overlap':      # 0, 16, 0: xmm8 saved over xmm6's cell
    a, b = func('p120_leaf')
    off6 = re.match(r'^\tmovups %xmm6, (\d+)', lines[first(r'^\tmovups %xmm6, ', a, b)]).group(1)
    for i in range(a, b):
        lines[i] = re.sub(r'^(\tmovups %xmm8, )\d+(\(%rsp\))$', rf'\g<1>{off6}\2', lines[i])
        lines[i] = re.sub(r'^(\t\.seh_savexmm %xmm8, )\d+$', rf'\g<1>{off6}', lines[i])
        lines[i] = re.sub(r'^(\tmovups )\d+(\(%rsp\), %xmm8)$', rf'\g<1>{off6}\2', lines[i])
elif kind == 'badadd':       # epilogue frees 16 bytes too many
    a, b = func('p120_leaf')
    i = first(r'^\taddq \$\d+, %rsp$', a, b)
    n = int(re.search(r'\d+', lines[i]).group(0))
    lines[i] = f'\taddq ${n + 16}, %rsp'
elif kind == 'nodynreset':   # dynalloc function returns without resetting %rsp
    a, b = func('p120_dyn')
    i = first(r'^\tleaq \d+\(%rbp\), %rsp$', a, b)
    n = int(re.search(r'\d+', lines[i]).group(0))
    lines[i] = f'\taddq ${n}, %rsp'
elif kind == 'nosehpush':    # a push the unwinder does not know about
    a, b = func('p120_dynpush9')
    i = first(r'^\t\.seh_pushreg %(rsi|rdi|rbx|r1[2-5])$', a, b)
    del lines[i]
elif kind == 'misalign':     # 8 more bytes of frame: %rsp 8 mod 16
    a, b = func('p120_align')
    n = int(re.search(r'\d+', lines[first(r'^\tsubq \$\d+, %rsp$', a, b)]).group(0))
    for i in range(a, b):
        lines[i] = lines[i].replace(f'subq ${n}, %rsp', f'subq ${n + 8}, %rsp')
        lines[i] = lines[i].replace(f'.seh_stackalloc {n}', f'.seh_stackalloc {n + 8}')
        lines[i] = lines[i].replace(f'addq ${n}, %rsp', f'addq ${n + 8}, %rsp')
elif kind == 'sehlie':       # .seh_savexmm offset differs from the store
    i = first(r'^\t\.seh_savexmm %xmm7, \d+$')
    n = int(lines[i].split(', ')[1])
    lines[i] = f'\t.seh_savexmm %xmm7, {n + 16}'
elif kind == 'nosave':       # the pre-fix emitter: no xmm save at all
    lines = [l for l in lines if not l.startswith('\tmovups ')
             and not l.startswith('\t.seh_savexmm')]
else:
    sys.exit(f'unknown mutation {kind}')
out = '\n'.join(lines)
if out == open(src).read():
    sys.exit(f'mutate {kind}: no change')
open(dst, 'w').write(out)
