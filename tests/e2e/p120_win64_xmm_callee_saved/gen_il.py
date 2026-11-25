"""Generate the p120 QBE fixture for the Win64 nonvolatile xmm6..xmm15 test.

usage: python3 -E gen_il.py OUT_DIR
writes OUT_DIR/fixture.ssa (Win64 functions, compiled with `qbe -t amd64_win`),
OUT_DIR/cases.h (one `{ "name", fn, nstack, {args}, {stack}, kind, bits }`
row per call the C driver makes, expected results from the Python reference
below, bit for bit) and OUT_DIR/expect.txt (`name need...` per function, for
check_frames.py: `save6-14` = must save all of xmm6..xmm14, `save15` = must
save xmm15, `nosave` = no xmm6..xmm15 save at all, `div15` / `copy15` /
`swap15` = the xmm15 scratch pattern the emitter must produce there, `rsp` /
`rbp` = frame base, `chkstk` = probed frame).

Every function is straight-line IEEE double arithmetic (add, sub, mul, div,
no FMA, no reassociation in QBE), so Python floats are an exact oracle.
"""
import struct
import sys
from pathlib import Path


def dbits(x):
    return struct.unpack('<Q', struct.pack('<d', x))[0]


def coef(i):
    # exact binary fractions in [1, 1.375]
    return 1.0 + (i % 7) / 16.0


class Pressure:
    """N doubles, all live at once: v_i = v_{i-1} * c_i + in[i % k], then
    s = v_{N-1}; s = s * 0.5 + v_i for i = N-2 .. 0."""

    def __init__(self, p, ins, n):
        self.p, self.ins, self.n = p, ins, n

    def il(self):
        p, ins, n = self.p, self.ins, self.n
        out = [f'\t%{p}m0 =d mul {ins[0]}, d_{coef(0)}',
               f'\t%{p}v0 =d add %{p}m0, {ins[1 % len(ins)]}']
        for i in range(1, n):
            out.append(f'\t%{p}m{i} =d mul %{p}v{i-1}, d_{coef(i)}')
            out.append(f'\t%{p}v{i} =d add %{p}m{i}, {ins[i % len(ins)]}')
        out.append(f'\t%{p}s{n-1} =d copy %{p}v{n-1}')
        for i in range(n - 2, -1, -1):
            out.append(f'\t%{p}h{i} =d mul %{p}s{i+1}, d_0.5')
            out.append(f'\t%{p}s{i} =d add %{p}h{i}, %{p}v{i}')
        return out, f'%{p}s0'

    def ref(self, vals):
        n = self.n
        v = [vals[0] * coef(0) + vals[1 % len(vals)]]
        for i in range(1, n):
            v.append(v[i - 1] * coef(i) + vals[i % len(vals)])
        s = v[n - 1]
        for i in range(n - 2, -1, -1):
            s = s * 0.5 + v[i]
        return s


FUNCS = []   # IL text
EXPECT = []  # check_frames.py lines
CASES = []   # driver rows


def fn(text, expect):
    FUNCS.append(text)
    EXPECT.append(expect)


def case(name, args, stack, kind, val):
    """args: up to 4 register arguments, stack: arguments 5.. (all 64-bit
    patterns; the harness loads each register argument into both the GPR
    and the XMM of its position, as Win64 varargs do)."""
    bits = dbits(val) if kind == 'd' else val & 0xffffffffffffffff
    CASES.append((name, args, stack, kind, bits))


def d(x):
    return dbits(x)


# 1. leaf, > 18 live doubles, two stack arguments (s < 0), alloc16 slot
LP = Pressure('a', ['%a0', '%a1', '%a2', '%a3', '%s4', '%s5', '%m'], 22)
body, res = LP.il()
fn('\n'.join([
    'export function d $p120_leaf(d %a0, d %a1, d %a2, d %a3, d %s4, d %s5) {',
    '@start',
    '\t%p =l alloc16 16',
    '\t%q =d mul %a0, d_3',
    '\tstored %q, %p',
    '\t%m =d loadd %p',
] + body + [f'\tret {res}', '}']), 'p120_leaf save6-14 rsp')


def ref_leaf(a0, a1, a2, a3, s4, s5):
    return LP.ref([a0, a1, a2, a3, s4, s5, a0 * 3.0])


for k, xs in enumerate([(1.5, -2.25, 3.125, 0.75, 1.0625, -0.5),
                        (0.1, 0.2, 0.3, 0.4, 0.5, 0.6),
                        (-7.0, 1e-3, 12.5, -0.125, 2.0, 3.0)]):
    case('p120_leaf', [d(x) for x in xs[:4]], [d(x) for x in xs[4:]], 'd',
         ref_leaf(*xs))

# 2. writes only volatile xmm0..xmm5 (and is called by the others)
fn('\n'.join([
    'export function d $p120_vol(d %x) {',
    '@start',
    '\t%v1 =d mul %x, d_1.5',
    '\t%v2 =d add %v1, %x',
    '\t%v3 =d mul %v2, %v1',
    '\t%v4 =d sub %v3, %x',
    '\t%v5 =d mul %v4, %v2',
    '\t%r =d add %v5, %v3',
    '\tret %r',
    '}']), 'p120_vol nosave rsp')


def ref_vol(x):
    v1 = x * 1.5
    v2 = v1 + x
    v3 = v2 * v1
    v4 = v3 - x
    v5 = v4 * v2
    return v5 + v3


for x in (1.25, -3.0, 0.001):
    case('p120_vol', [d(x)], [], 'd', ref_vol(x))

# 3. non-leaf: 10 doubles live across calls to p120_vol (clobbers volatile
# xmm) and p120_leaf (6 arguments, 2 on the stack)
NL = 10
lines = ['export function d $p120_nonleaf(d %a, d %b, d %c, d %e) {', '@start']
srcs = ['%b', '%c', '%e']
for i in range(NL):
    lines.append(f'\t%u{i} =d mul %a, d_{coef(i) + i}')
    lines.append(f'\t%u{i} =d add %u{i}, {srcs[i % 3]}')
lines += ['\t%r1 =d call $p120_vol(d %u0)',
          '\t%r2 =d call $p120_leaf(d %u1, d %u2, d %u3, d %u4, d %u5, d %u6)',
          '\t%t =d add %r1, %r2']
for i in range(NL):
    lines.append(f'\t%t =d mul %t, d_0.5')
    lines.append(f'\t%t =d add %t, %u{i}')
lines += ['\tret %t', '}']
fn('\n'.join(lines), 'p120_nonleaf save6-14 rbp')


def ref_nonleaf(a, b, c, e):
    s = [b, c, e]
    u = [a * (coef(i) + i) + s[i % 3] for i in range(NL)]
    t = ref_vol(u[0]) + ref_leaf(*u[1:7])
    for i in range(NL):
        t = t * 0.5 + u[i]
    return t


for xs in ((1.0, 2.0, 3.0, 4.0), (-0.5, 0.25, 8.0, -1.0)):
    case('p120_nonleaf', [d(x) for x in xs], [], 'd', ref_nonleaf(*xs))

# 4. varargs: n named, 5 doubles read with vaarg, then pressure
VP = Pressure('b', ['%x0', '%x1', '%x2', '%x3', '%x4', '%fn'], 20)
body, res = VP.il()
fn('\n'.join([
    'export function d $p120_va(w %n, ...) {',
    '@start',
    '\t%ap =l alloc8 32',
    '\tvastart %ap',
    '\t%x0 =d vaarg %ap',
    '\t%x1 =d vaarg %ap',
    '\t%x2 =d vaarg %ap',
    '\t%x3 =d vaarg %ap',
    '\t%x4 =d vaarg %ap',
    '\t%fn =d swtof %n',
] + body + [f'\tret {res}', '}']), 'p120_va save6-14 rbp')
for n, xs in ((5, (1.5, 2.5, -3.5, 4.5, 0.125)), (-9, (0.3, 0.7, 1.1, -2.2, 9.0))):
    case('p120_va', [n & 0xffffffff] + [d(x) for x in xs[:3]],
         [d(x) for x in xs[3:]], 'd', VP.ref(list(xs) + [float(n)]))

# 5. dynamic stack allocation (fn->dynalloc), pressure across it
DP = Pressure('c', ['%a', '%b', '%l0', '%l1'], 20)
body, res = DP.il()
fn('\n'.join([
    'export function d $p120_dyn(w %n, d %a, d %b) {',
    '@start',
    '\t%n8 =l extsw %n',
    '\t%sz =l mul %n8, 8',
    '\t%p =l alloc16 %sz',
    '\tstored %a, %p',
    '\t%o =l sub %sz, 8',
    '\t%pe =l add %p, %o',
    '\tstored %b, %pe',
    '\t%l0 =d loadd %p',
    '\t%l1 =d loadd %pe',
] + body + [f'\tret {res}', '}']), 'p120_dyn save6-14 rbp')
for n, a, b in ((3, 1.5, 2.5), (700, -0.75, 6.0)):
    case('p120_dyn', [n, d(a), d(b)], [], 'd', DP.ref([a, b, a, b]))

# 6. frames >= 4096 B (__chkstk probe): leaf (rsp) and non-leaf (rbp)
BP = Pressure('e', ['%a', '%b', '%l0', '%l1'], 20)
body, res = BP.il()
for nm, call, base in (('p120_bigleaf', [], 'rsp'),
                       ('p120_bigcall', ['\t%b2 =d call $p120_vol(d %b)'], 'rbp')):
    bsrc = '%b2' if call else '%b'
    fn('\n'.join([
        f'export function d ${nm}(d %a, d %b) {{',
        '@start',
        '\t%p =l alloc16 8192',
        '\tstored %a, %p',
        '\t%pe =l add %p, 8184',
    ] + call + [
        f'\tstored {bsrc}, %pe',
        '\t%l0 =d loadd %p',
        '\t%l1 =d loadd %pe',
    ] + body + [f'\tret {res}', '}']), f'{nm} save6-14 {base} chkstk')
    for a, b in ((2.0, 3.0), (-1.25, 0.0625)):
        bb = ref_vol(b) if call else b
        case(nm, [d(a), d(b)], [], 'd', BP.ref([a, b, a, bb]))

# 7. the three xmm15 scratch paths of amd64/emit.c
#   div: Odiv with to == arg[1]
fn('\n'.join([
    'export function d $p120_div15(d %a, d %b) {',
    '@start',
    '\t%r =d div %b, %a',
    '\tret %r',
    '}']), 'p120_div15 save15 div15 rsp')
for a, b in ((4.0, 1.0), (3.0, -10.0)):
    case('p120_div15', [d(a), d(b)], [], 'd', b / a)

#   swap: floating-point phi swap in a loop
fn('\n'.join([
    'export function d $p120_swap15(d %a, d %b, w %n) {',
    '@start',
    '\tjmp @loop',
    '@loop',
    '\t%x =d phi @start %a, @loop %y',
    '\t%y =d phi @start %b, @loop %x',
    '\t%i =w phi @start %n, @loop %i1',
    '\t%i1 =w sub %i, 1',
    '\tjnz %i1, @loop, @done',
    '@done',
    '\t%x2 =d mul %x, d_2',
    '\t%r =d add %x2, %y',
    '\tret %r',
    '}']), 'p120_swap15 save15 swap15 rsp')


def ref_swap(a, b, n):
    x, y = a, b
    i = n
    while True:
        i1 = (i - 1) & 0xffffffff
        if i1 == 0:
            break
        x, y = y, x
        i = i1
    return x * 2.0 + y


for a, b, n in ((1.0, 10.0, 1), (1.0, 10.0, 2), (-3.5, 0.25, 7)):
    case('p120_swap15', [d(a), d(b), n], [], 'd', ref_swap(a, b, n))

#   copy: slot-to-slot moves of spilled loop-carried doubles (a chain, no
#   cycle, so no swap)
NC = 22
lines = ['export function d $p120_copy15(d %a, w %n) {', '@start']
for i in range(NC):
    lines.append(f'\t%s{i} =d mul %a, d_{1 + i / 8}')
lines += ['\tjmp @loop', '@loop']
for i in range(NC):
    nxt = f'%v{i+1}' if i + 1 < NC else '%w'
    lines.append(f'\t%v{i} =d phi @start %s{i}, @loop {nxt}')
lines += ['\t%i =w phi @start %n, @loop %i1',
          f'\t%w =d mul %v{NC-1}, d_0.75',
          '\t%i1 =w sub %i, 1',
          '\tjnz %i1, @loop, @done',
          '@done',
          '\t%t0 =d copy %v0']
for i in range(1, NC):
    lines.append(f'\t%m{i} =d mul %t{i-1}, d_1.0625')
    lines.append(f'\t%t{i} =d add %m{i}, %v{i}')
lines += [f'\tret %t{NC-1}', '}']
fn('\n'.join(lines), 'p120_copy15 save15 copy15')


def ref_copy(a, n):
    v = [a * (1 + i / 8) for i in range(NC)]
    i = n
    while True:
        w = v[NC - 1] * 0.75
        i1 = (i - 1) & 0xffffffff
        if i1 == 0:
            break
        v = v[1:] + [w]
        i = i1
    t = v[0]
    for k in range(1, NC):
        t = t * 1.0625 + v[k]
    return t


for a, n in ((1.0, 1), (0.5, 5), (-2.0, 40)):
    case('p120_copy15', [d(a), n], [], 'd', ref_copy(a, n))


# 8. 16-byte alignment: mixed fixed allocs, dynamic allocs with 0..7 pushed
# GPRs, and %rsp at the entry of a callee (p120_rsp in harness.S returns
# its entry %rsp mod 16, 8 on a correct call). Results are 0 / 8 plus a
# checksum, so a misaligned address shows up as a wrong result.
M64 = (1 << 64) - 1
fn('\n'.join([
    'export function l $p120_align(l %x) {',
    '@start',
    '\t%a4 =l alloc4 4',
    '\t%b8 =l alloc8 8',
    '\t%c16 =l alloc16 16',
    '\t%d4 =l alloc4 4',
    '\t%e16 =l alloc16 32',
    '\tstorew 1, %a4',
    '\tstorel %x, %b8',
    '\tstorel %x, %c16',
    '\tstorew 2, %d4',
    '\tstorel %x, %e16',
    '\t%m1 =l and %c16, 15',
    '\t%m2 =l and %e16, 15',
    '\t%m3 =l and %b8, 7',
    '\t%m =l or %m1, %m2',
    '\t%m =l or %m, %m3',
    '\t%v =l loadl %c16',
    '\t%w =l loadw %a4',
    '\t%u =l loadw %d4',
    '\t%t =l add %v, %w',
    '\t%t =l add %t, %u',
    '\t%t =l mul %t, 16',
    '\t%r =l or %t, %m',
    '\tret %r',
    '}']), 'p120_align')
for x in (5, 1 << 40):
    case('p120_align', [x], [], 'l', ((x + 3) * 16) & M64)

DYNK = list(range(3, 15))
for k in DYNK:
    lines = [f'export function l $p120_dynpush{k}(l %x, l %n) {{', '@start',
             '\t%p =l alloc16 %n']
    for i in range(k):
        lines.append(f'\t%v{i} =l mul %x, {2 * i + 3}')
        lines.append(f'\t%v{i} =l add %v{i}, {i}')
    lines.append('\t%s =l copy 0')
    for i in range(k):
        lines.append(f'\t%s =l xor %s, %v{i}')
        lines.append(f'\t%s =l mul %s, 3')
    lines += ['\tstorel %s, %p', '\t%q =l loadl %p', '\t%m =l and %p, 15',
              '\t%q =l mul %q, 16', '\t%r =l or %q, %m', '\tret %r', '}']
    fn('\n'.join(lines), f'p120_dynpush{k} rbp')

    def ref_dyn(x, kk=k):
        s = 0
        for i in range(kk):
            s ^= (x * (2 * i + 3) + i) & M64
            s = (s * 3) & M64
        return (s * 16) & M64
    for x, n in ((7, 32), (-3 & M64, 24), (1 << 33, 8)):
        case(f'p120_dynpush{k}', [x, n], [], 'l', ref_dyn(x))

for nm, dyn in (('p120_rspdyn', True), ('p120_rspcall', False)):
    lines = [f'export function l ${nm}(l %x, l %n) {{', '@start']
    if dyn:
        lines += ['\t%p =l alloc16 %n', '\tstorel %x, %p']
    for i in range(9):
        lines.append(f'\t%g{i} =l add %x, {i * 7 + 1}')
    lines.append('\t%c =l call $p120_rsp()')
    lines.append('\t%s =l copy %c')
    for i in range(9):
        lines.append(f'\t%s =l add %s, %g{i}')
    lines += ['\tret %s', '}']
    fn('\n'.join(lines), f'{nm} rbp')
    for x, n in ((100, 24), (5, 40)):
        case(nm, [x, n], [], 'l', (8 + sum(x + i * 7 + 1 for i in range(9))) & M64)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / 'fixture.ssa').write_text('\n\n'.join(FUNCS) + '\n')
    (out / 'expect.txt').write_text('\n'.join(EXPECT) + '\n')
    names = sorted({c[0] for c in CASES})
    h = ['/* generated by gen_il.py */']
    for nm in names:
        h.append(f'extern char {nm}[];')
    h.append(f'#define P120_NCALLS {3 * len(CASES)}')
    h.append('static const struct p120_case P120_CASES[] = {')
    for nm, args, stack, kind, bits in CASES:
        a = ', '.join(f'0x{x:016x}ull' for x in args) or '0'
        s = ', '.join(f'0x{x:016x}ull' for x in stack) or '0'
        h.append(f'\t{{"{nm}", {nm}, {len(stack)}, {{{a}}}, {{{s}}}, '
                 f"'{kind}', 0x{bits:016x}ull}},")
    h.append('};')
    (out / 'cases.h').write_text('\n'.join(h) + '\n')


main()
