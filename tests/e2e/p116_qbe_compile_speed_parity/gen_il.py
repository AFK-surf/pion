"""Generate the p116 QBE fixtures and their C driver.

usage: python3 -E gen_il.py OUT_DIR
writes into OUT_DIR:
  lex.ssa     lexer boundaries (one byte of lookahead in vendor/qbe/parse.c):
              bare `s` / `d` words (classes, `sb` / `sh` parameters, keywords
              starting with s / d), `s_` / `d_` floats (decimal, exponent,
              hex, signed zero, extremes), temporaries / labels / globals
              named s, d, s_, d_x, names longer than 127 bytes, negative and
              extreme integers, data definitions;
  lexa.ssa, lexb.ssa
              two inputs for one multi-file run; lexa.ssa ends with `}` and
              no newline so the next file starts right after an end of stream;
  flow.ssa    phi placement and liveness (vendor/qbe/ssa.c philive,
              vendor/qbe/live.c filllive, vendor/qbe/rega.c snapshot):
              temporaries redefined on several paths (non-SSA input), a loop
              `jtbl` with a duplicate entry, dead redefinitions, an input that
              already has phis, 20 loop-carried 64-bit values across a call on
              one table arm (spills, multi-predecessor joins), argument-free
              calls whose results are read right after them, and float /
              double values redefined in a loop;
  check.c     C references of every function; main() runs each one over its
              input grid and prints `name N` then `total N bad B`;
  err_*.ssa   inputs the lexer must reject, with err_expect.txt
              (`file<TAB>exact stderr line`).
"""
import struct
import sys
from pathlib import Path

LONG_FN = 'lx_' + 'q' * 197            # 200-byte global name
LONG_TMP = 't' * 300                    # 300-byte temporary
LONG_LBL = 'b' * 150                    # 150-byte label
LONG_DATA = 'dz' + 'x' * 140            # 142-byte data symbol, starts with d

S_LITS = ['1.5', '-0.25', '0.1', '1e-3', '3.4028234e38', '-0', '1.17549435e-38',
          '16777217', '0x1.8p1', '7']
D_LITS = ['0.1', '-2.5e-300', '1e308', '4.9e-324', '-0', '123456789.125',
          '0x1.8p1', '-1e-5', '2']


def fval(lit):
    return float.fromhex(lit) if 'x' in lit else float(lit)


def sbits(lit):
    return struct.unpack('<I', struct.pack('<f', fval(lit)))[0]


def dbits(lit):
    return struct.unpack('<Q', struct.pack('<d', fval(lit)))[0]


def lex_ssa():
    s = ['# p116 lexer boundaries',
         f'export data ${LONG_DATA} = {{ w -3, l -9223372036854775808, b -1, h -2, s s_1.5, d d_-0.125 }}',
         'export data $s = { w 11, w -12 }',
         'export data $d_x = { l 18446744073709551615, s s_-0, d d_0x1p-3 }',
         '']
    for k, lit in enumerate(S_LITS):
        s += [f'export function w $lx_s{k}() {{', '@start', f'\t%s =s copy s_{lit}',
              '\t%b =w cast %s', '\tret %b', '}', '']
    for k, lit in enumerate(D_LITS):
        s += [f'export function l $lx_d{k}() {{', '@start', f'\t%d =d copy d_{lit}',
              '\t%b =l cast %d', '\tret %b', '}', '']
    # s / d / s_ / d_x as temporary, label and global names; keywords starting with s / d.
    s += ['export function w $lx_names(w %s, w %d) {',
          '@s',
          '\t%s_ =w add %s, %d',
          '\t%d_x =w sub %s_, 1',
          '\t%sx =w shl %d_x, 1',
          '\t%dv =w div %sx, 2',
          '\t%sa =w sar %dv, 0',
          '\tjnz %sa, @d_, @d',
          '@d_',
          '\t%r =w mul %sa, 3',
          '\tret %r',
          '@d',
          '\tret 77',
          '}',
          '',
          # sb / sh / ub parameters, swtof / sltof / dtosi / stosi / exts / truncd / extsw
          'export function l $lx_conv(sb %a, sh %b, ub %c, w %w) {',
          '@start',
          '\t%x =w add %a, %b',
          '\t%y =w add %x, %c',
          '\t%f =s swtof %y',
          '\t%g =d exts %f',
          '\t%z =l extsw %w',
          '\t%h =d sltof %z',
          '\t%i =d add %g, %h',
          '\t%j =s truncd %i',
          '\t%k =w stosi %j',
          '\t%m =l dtosi %i',
          '\t%n =l extsw %k',
          '\t%o =l add %m, %n',
          '\tret %o',
          '}',
          '',
          # integers: negative, extreme, `- 0` forms, a store / load through memory
          'export function l $lx_ints(l %p) {',
          '@start',
          '\t%a =l copy -9223372036854775808',
          '\t%b =l add %a, -1',
          '\t%c =l add %b, 18446744073709551615',
          '\t%d =l sub %c, -0',
          '\tstorel %d, %p',
          '\t%e =l loadl %p',
          '\t%f =w sub 0, -5',
          '\t%g =l extsw %f',
          '\t%h =l add %e, %g',
          '\tret %h',
          '}',
          '',
          # names longer than the 128-byte token buffer
          f'export function w ${LONG_FN}(w %{LONG_TMP}) {{',
          f'@{LONG_LBL}',
          f'\t%{LONG_TMP}x =w add %{LONG_TMP}, 41',
          f'\tjnz %{LONG_TMP}x, @{LONG_LBL}y, @{LONG_LBL}z',
          f'@{LONG_LBL}y',
          f'\tret %{LONG_TMP}x',
          f'@{LONG_LBL}z',
          '\tret -1',
          '}',
          '',
          f'export function l $lx_data() {{',
          '@start',
          f'\t%a =w loadsw ${LONG_DATA}',
          f'\t%p =l add ${LONG_DATA}, 4',
          '\t%b =l loadl %p',
          '\t%q =l add $s, 4',
          '\t%c =w loadsw %q',
          '\t%e =l loadl $d_x',
          '\t%x =l extsw %a',
          '\t%y =l extsw %c',
          '\t%r =l add %x, %b',
          '\t%r2 =l add %r, %y',
          '\t%r3 =l add %r2, %e',
          '\tret %r3',
          '}',
          '']
    return '\n'.join(s) + '\n'


def lex_expect():
    """C statements checking every lex.ssa function (expected values computed here)."""
    m64 = (1 << 64) - 1
    c = []
    for k, lit in enumerate(S_LITS):
        c.append(f'CHK("lx_s{k}", (uint64_t)(uint32_t)lx_s{k}(), 0x{sbits(lit):08x}ull);')
    for k, lit in enumerate(D_LITS):
        c.append(f'CHK("lx_d{k}", (uint64_t)lx_d{k}(), 0x{dbits(lit):016x}ull);')

    def names(s, d):
        s_ = (s + d) & 0xffffffff
        dx = (s_ - 1) & 0xffffffff
        sx = (dx << 1) & 0xffffffff
        sxi = sx - (1 << 32) if sx >> 31 else sx
        dv = int(sxi / 2)                     # C division truncates
        if dv == 0:
            return 77
        return (dv * 3) & 0xffffffff
    for s, d in [(0, 0), (1, 0), (0, 1), (5, 7), (-3, 2), (0x7fffffff, 1), (-1, -1), (100, -50)]:
        c.append(f'CHK("lx_names", (uint64_t)(uint32_t)lx_names({s}, {d}), 0x{names(s & 0xffffffff, d & 0xffffffff):x}ull);')

    def conv(a, b, cc, w):
        y = a + b + cc
        f = struct.unpack('<f', struct.pack('<f', float(y)))[0]
        i = f + float(w)
        j = struct.unpack('<f', struct.pack('<f', i))[0]
        return (int(i) + int(j)) & m64
    for a, b, cc, w in [(0, 0, 0, 0), (-128, -32768, 255, 7), (127, 32767, 0, -9), (-1, 2, 3, 1000000)]:
        c.append(f'CHK("lx_conv", (uint64_t)lx_conv({a}, {b}, {cc}, {w}), 0x{conv(a, b, cc, w):x}ull);')
    ints = ((((-(1 << 63)) - 1) + m64) & m64) + 5
    c.append(f'{{ int64_t cell = 0; CHK("lx_ints", (uint64_t)lx_ints(&cell), 0x{ints & m64:x}ull); }}')
    for v in [0, 1, -41, -42, 1000]:
        r = (v + 41) & 0xffffffff
        want = r if r else 0xffffffff
        c.append(f'CHK("lx_long", (uint64_t)(uint32_t){LONG_FN}({v}), 0x{want:x}ull);')
    data = (-3 + (-(1 << 63)) + (-12) + m64) & m64
    c.append(f'CHK("lx_data", (uint64_t)lx_data(), 0x{data:x}ull);')
    c.append(f'CHK("lx_data_s", (uint64_t)*(uint32_t *)((char *){LONG_DATA} + 15), 0x{sbits("1.5"):08x}ull);')
    c.append(f'CHK("d_x_s", (uint64_t)*(uint32_t *)((char *)d_x + 8), 0x{sbits("-0"):08x}ull);')
    return c


def lex_ab():
    a = ('# p116 multi-file input A (no trailing newline)\n'
         'export function w $mf_a(w %s) {\n@start\n\t%d =w add %s, -7\n\tret %d\n}')
    b = ('export function d $mf_b(d %x) {\n@start\n\t%y =d mul %x, d_-0.5\n\tret %y\n}\n'
         'export data $mf_tab = { w -1, s s_2.5 }\n')
    return a, b


def pressure(n=20):
    """20 loop-carried 64-bit values, a jtbl in the loop, a call on one arm."""
    s = ['export function l $pressure(l %seed, w %rounds) {', '@start']
    for i in range(n):
        s.append(f'\t%v{i} =l add %seed, {i * 977 + 13}')
    s += ['\t%j =w copy 0', '@loop', '\t%go =w csltw %j, %rounds', '\tjnz %go, @head, @out',
          '@head', '\t%jl =l extsw %j', '\t%k =l add %v0, %jl', '\t%sel =l and %k, 3', '\t%idx =w copy %sel',
          '\tjtbl %idx, @dflt, @a0, @a1, @a2, @a1']
    ref = []
    for arm in range(3):
        s.append(f'@a{arm}')
        body = []
        for i in range(n):
            if i % 3 == arm:
                s.append(f'\t%m{i} =l mul %v{(i + 1) % n}, {arm + 2}')
                s.append(f'\t%v{i} =l add %v{i}, %m{i}')
                body.append(f'v[{i}] += v[{(i + 1) % n}] * {arm + 2};')
            if arm == 2 and i % 5 == 0:
                s.append(f'\t%v{i} =l call $p116_opaque(l %v{i}, l %jl)')
                body.append(f'v[{i}] = p116_opaque(v[{i}], (int64_t)j);')
        s.append('\tjmp @join')
        ref.append(body)
    s.append('@dflt')
    dflt = []
    for i in range(0, n, 2):
        s.append(f'\t%v{i} =l xor %v{i}, %jl')
        dflt.append(f'v[{i}] ^= (int64_t)j;')
    s += ['@join', '\t%v0 =l add %v0, 1', '\t%j =w add %j, 1', '\t%low =l and %v1, 63',
          '\t%early =w ceql %low, 0', '\tjnz %early, @out, @loop', '@out', '\t%h =l copy 0']
    for i in range(n):
        s += [f'\t%h =l mul %h, 31', f'\t%h =l add %h, %v{i}']
    s += ['\tret %h', '}', '']
    c = ['static int64_t pressure_ref(int64_t seed, int32_t rounds) {',
         f'\tint64_t v[{n}];',
         f'\tfor (int i = 0; i < {n}; i++) v[i] = (int64_t)((uint64_t)seed + (uint64_t)(i * 977 + 13));',
         '\tfor (int32_t j = 0; j < rounds;) {',
         '\t\tuint64_t sel = ((uint64_t)v[0] + (uint64_t)(int64_t)j) & 3;',
         '\t\tswitch (sel) {']
    for arm, body in enumerate(ref):
        labels = {0: 'case 0:', 1: 'case 1: case 3:', 2: 'case 2:'}[arm]
        c.append(f'\t\t{labels}')
        for b in body:
            lhs, rhs = b.split(' += ') if ' += ' in b else (None, None)
            if lhs:
                c.append(f'\t\t\t{lhs} = (int64_t)((uint64_t){lhs} + (uint64_t){rhs.rstrip(";").replace("v[", "(uint64_t)v[")});')
            else:
                c.append(f'\t\t\t{b}')
        c.append('\t\t\tbreak;')
    c.append('\t\tdefault:')
    c += [f'\t\t\t{b}' for b in dflt]
    c += ['\t\t}', '\t\tv[0] = (int64_t)((uint64_t)v[0] + 1);', '\t\tj++;',
          '\t\tif ((v[1] & 63) == 0) break;', '\t}', '\tuint64_t h = 0;',
          f'\tfor (int i = 0; i < {n}; i++) h = h * 31 + (uint64_t)v[i];', '\treturn (int64_t)h;', '}']
    return '\n'.join(s) + '\n', '\n'.join(c) + '\n'


FLOW = r'''
# Temporaries redefined on several paths: phi placement must find them.
export function w $multidef(w %n, w %s) {
@start
	%x =w copy %s
	%y =w copy 0
	%i =w copy 0
@loop
	%c =w csltw %i, %n
	jnz %c, @body, @end
@body
	%t =w and %i, 3
	jnz %t, @odd, @even
@odd
	%x =w add %x, %i
	%y =w xor %y, %x
	jmp @next
@even
	%x =w mul %x, 3
@next
	%i =w add %i, 1
	jmp @loop
@end
	%r =w add %x, %y
	ret %r
}

# A loop jtbl with a duplicate entry; %only is defined once per arm and read
# in @join, %scratch is redefined but dead, %solo has one definition outside
# @start and a use in another block.
export function w $jt(w %seed, w %rounds) {
@start
	%a =w copy %seed
	%b =w add %seed, 7
	%c =w copy 0
	%j =w copy 0
@loop
	%go =w csltw %j, %rounds
	jnz %go, @head, @out
@head
	%k =w add %a, %j
	%idx =w and %k, 7
	%solo =w mul %k, 13
	jtbl %idx, @dflt, @e0, @e1, @e2, @e1
@e0
	%a =w add %a, %b
	%only =w xor %a, 5
	jmp @join
@e1
	%b =w mul %b, 3
	%only =w copy %b
	jmp @join
@e2
	%c =w add %c, %a
	%scratch =w copy %c
	%scratch =w add %scratch, 1
	%only =w copy 9
	jmp @join
@dflt
	%c =w sub %c, 1
	%only =w add %c, %solo
	jmp @join
@join
	%c =w add %c, %only
	%j =w add %j, 1
	jmp @loop
@out
	%r =w xor %a, %b
	%r =w add %r, %c
	ret %r
}

# Input that already has phis, next to a temporary redefined in the loop.
export function w $prephi(w %n, w %s) {
@start
	%acc0 =w copy %s
	jmp @loop
@loop
	%i =w phi @start 0, @merge %i1
	%acc =w phi @start %acc0, @merge %acc2
	%m =w copy %acc
	%c =w csltw %i, %n
	jnz %c, @body, @end
@body
	%t =w and %i, 1
	jnz %t, @odd, @even
@odd
	%m =w add %m, %i
	jmp @merge
@even
	%m =w mul %m, 5
@merge
	%acc2 =w xor %m, %i
	%i1 =w add %i, 1
	jmp @loop
@end
	%r =w add %acc, %m
	ret %r
}

# Argument-free calls whose results are read right after them: the
# return registers are dead before the call (Mach-O register liveness).
export function l $zcall(w %n) {
@start
	%acc =l copy 0
	%f =d copy d_0
	%i =w copy 0
@loop
	%c =w csltw %i, %n
	jnz %c, @body, @end
@body
	%r =l call $p116_tick()
	%acc =l add %acc, %r
	%g =d call $p116_half()
	%f =d add %f, %g
	%i =w add %i, 1
	jmp @loop
@end
	%fi =l dtosi %f
	%out =l add %acc, %fi
	ret %out
}

# Float and double values redefined in a loop (both register classes).
export function l $fl(w %n, d %x) {
@start
	%a =d copy %x
	%b =s copy s_0.5
	%i =w copy 0
@loop
	%c =w csltw %i, %n
	jnz %c, @body, @end
@body
	%t =w and %i, 1
	jnz %t, @p, @q
@p
	%a =d mul %a, d_1.0625
	%b =s add %b, s_0.25
	jmp @nx
@q
	%a =d sub %a, d_0.5
@nx
	%i =w add %i, 1
	jmp @loop
@end
	%bd =d exts %b
	%r =d add %a, %bd
	%bits =l cast %r
	ret %bits
}
'''

FLOW_REF = r'''
static uint32_t multidef_ref(int32_t n, uint32_t s) {
	uint32_t x = s, y = 0;
	for (int32_t i = 0; i < n; i++) {
		if (i & 3) { x += (uint32_t)i; y ^= x; } else x *= 3;
	}
	return x + y;
}

static uint32_t jt_ref(uint32_t seed, int32_t rounds) {
	uint32_t a = seed, b = seed + 7, c = 0, only;
	for (int32_t j = 0; j < rounds; j++) {
		uint32_t k = a + (uint32_t)j, solo = k * 13;
		switch (k & 7) {
		case 0: a += b; only = a ^ 5; break;
		case 1: case 3: b *= 3; only = b; break;
		case 2: c += a; only = 9; break;
		default: c -= 1; only = c + solo; break;
		}
		c += only;
	}
	return (a ^ b) + c;
}

static uint32_t prephi_ref(int32_t n, uint32_t s) {
	uint32_t acc = s, m;
	int32_t i = 0;
	for (;;) {
		m = acc;
		if (!(i < n)) break;
		if (i & 1) m += (uint32_t)i; else m *= 5;
		acc = m ^ (uint32_t)i;
		i++;
	}
	return acc + m;
}

static int64_t zcall_ref(int32_t n) {
	int64_t acc = 0;
	double f = 0;
	for (int32_t i = 0; i < n; i++) { acc += 3; f += 0.5; }
	return acc + (int64_t)f;
}

static uint64_t fl_ref(int32_t n, double x) {
	double a = x;
	float b = 0.5f;
	for (int32_t i = 0; i < n; i++) {
		if (i & 1) { a = a * 1.0625; b = b + 0.25f; } else a = a - 0.5;
	}
	double r = a + (double)b;
	uint64_t u;
	memcpy(&u, &r, sizeof u);
	return u;
}
'''


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / 'lex.ssa').write_text(lex_ssa())
    a, b = lex_ab()
    (out / 'lexa.ssa').write_text(a)
    (out / 'lexb.ssa').write_text(b)
    p_ssa, p_ref = pressure()
    (out / 'flow.ssa').write_text(FLOW.lstrip('\n') + '\n' + p_ssa)
    decls = [f'int32_t lx_s{k}(void);' for k in range(len(S_LITS))]
    decls += [f'int64_t lx_d{k}(void);' for k in range(len(D_LITS))]
    decls += ['int32_t lx_names(int32_t, int32_t);',
              'int64_t lx_conv(signed char, short, unsigned char, int32_t);',
              'int64_t lx_ints(int64_t *);', f'int32_t {LONG_FN}(int32_t);', 'int64_t lx_data(void);',
              f'extern char {LONG_DATA}[];', 'extern char d_x[];',
              'int32_t mf_a(int32_t);', 'double mf_b(double);', 'extern char mf_tab[];',
              'uint32_t multidef(int32_t, uint32_t);', 'uint32_t jt(uint32_t, int32_t);',
              'uint32_t prephi(int32_t, uint32_t);', 'uint64_t fl(int32_t, double);', 'int64_t zcall(int32_t);',
              'int64_t pressure(int64_t, int32_t);']
    c = ['/* p116 driver: generated by gen_il.py */',
         '#include <stdint.h>', '#include <stdio.h>', '#include <string.h>', '',
         *decls, '',
         '__attribute__((noinline)) int64_t p116_tick(void) { return 3; }',
         '__attribute__((noinline)) double p116_half(void) { return 0.5; }',
         '__attribute__((noinline)) int64_t p116_opaque(int64_t a, int64_t b) {',
         '\treturn (int64_t)(((uint64_t)a ^ ((uint64_t)b << 1)) + 0x9e37u);', '}',
         FLOW_REF, p_ref,
         'static long total, bad;',
         'static void CHK(const char *name, uint64_t got, uint64_t want) {',
         '\ttotal++;',
         '\tif (got != want) { bad++; printf("BAD %s got %llx want %llx\\n", name, (unsigned long long)got, (unsigned long long)want); }',
         '}', '',
         'int main(void) {', '\tlong n0;']
    c += ['\t' + x for x in lex_expect()]
    c += ['\tprintf("lex %ld\\n", total);',
          '\tn0 = total;',
          '\tfor (int32_t s = -20; s <= 20; s++) CHK("mf_a", (uint64_t)(uint32_t)mf_a(s), (uint64_t)(uint32_t)(s - 7));',
          '\tfor (int k = -8; k <= 8; k++) { double x = k * 0.75, r = mf_b(x), w = x * -0.5; uint64_t a, b; memcpy(&a, &r, 8); memcpy(&b, &w, 8); CHK("mf_b", a, b); }',
          '\tCHK("mf_tab", (uint64_t)*(uint32_t *)mf_tab, 0xffffffffull);',
          '\tprintf("multifile %ld\\n", total - n0);',
          '\tn0 = total;',
          '\tfor (int32_t n = -2; n <= 70; n++) for (uint32_t s = 0; s < 40; s++) {',
          '\t\tuint32_t sv = s * 2654435761u;',
          '\t\tCHK("multidef", multidef(n, sv), multidef_ref(n, sv));',
          '\t\tCHK("jt", jt(sv, n), jt_ref(sv, n));',
          '\t\tCHK("prephi", prephi(n, sv), prephi_ref(n, sv));',
          '\t\tCHK("fl", fl(n, (double)s * 1.25 - 3.0), fl_ref(n, (double)s * 1.25 - 3.0));',
          '\t\tCHK("pressure", (uint64_t)pressure((int64_t)sv * 7919, n), (uint64_t)pressure_ref((int64_t)sv * 7919, n));',
          '\t}',
          '\tfor (int32_t n = -2; n <= 70; n++) CHK("zcall", (uint64_t)zcall(n), (uint64_t)zcall_ref(n));',
          '\tprintf("flow %ld\\n", total - n0);',
          '\tprintf("total %ld bad %ld\\n", total, bad);',
          '\treturn bad != 0;', '}']
    (out / 'check.c').write_text('\n'.join(c) + '\n')
    errs = {
        'err_sfoo.ssa': ('export function s $f() {\n@start\n\t%x =s add s_foo, s_1\n\tret %x\n}\n',
                         'qbe:err_sfoo.ssa:3: unknown keyword sfoo'),
        'err_sx.ssa': ('export function w $f() {\n@start\n\t%x =sx add 1, 2\n\tret %x\n}\n',
                       'qbe:err_sx.ssa:3: unknown keyword sx'),
        'err_long.ssa': ('export function w $f() {\n@start\n\n\t%x =w ' + 's' + 'z' * 200 + ' 1, 2\n\tret %x\n}\n',
                         'qbe:err_long.ssa:4: unknown keyword s' + 'z' * 200),
        'err_dlong.ssa': ('data $t = { w 1 }\n' + 'd' * 160 + '\n',
                          'qbe:err_dlong.ssa:2: unknown keyword ' + 'd' * 160),
    }
    exp = []
    for name, (text, msg) in errs.items():
        (out / name).write_text(text)
        exp.append(f'{name}\t{msg}')
    (out / 'err_expect.txt').write_text('\n'.join(exp) + '\n')


if __name__ == '__main__':
    main()
