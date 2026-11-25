"""Generate the p118 QBE fixtures.

usage: python3 -E gen_il.py OUT_DIR
writes OUT_DIR/jtbl.ssa, OUT_DIR/jtbl_expect.txt (`name form entries` per function,
checked by check_dispatch.py), OUT_DIR/bounds.ssa, OUT_DIR/bounds_expect.txt
(`name 0|1` or `name keep op arg limit` per function, checked by check_gvn.py) and OUT_DIR/check.c
(independent C oracles for both files).

jtbl.ssa: every `d_KIND_LIVE(l %w, l %p, w %arg)` selects with

  jtbl %i, @d, @a, @a, @c, @b, @c, @b, @b, @a

(eight entries, duplicates, default @d). %w is the low 32-bit input with
dirty high bits, %p points at { x, y }. With LIVE = 1 every successor adds
the selector to its result. amd64 forms:

  direct   dead selector in %r10, no `movl` before the table load: the block
           defines it with a 32-bit write from the amd64_table_word list;
  norm     dead selector in %r10, but nothing proves its high half is zero,
           so `movl %r10d, %r10d` must stay;
  live     selector read on the successors: kept out of %r10 / %r11, no
           normalization because the block proves the high half;
  livenorm as live, with `movl %REG, %r10d`;
  slot     live selector spilled: `movl HOME, %r10d` is the normalization.
"""
import sys
from pathlib import Path

MASK32 = 0xffffffff
TABLE = '@d, @a, @a, @c, @b, @c, @b, @b, @a'
NTBL = 8  # entries of TABLE without the default
ARMS = (('d', 41), ('a', 3), ('b', 9), ('c', 27))

# (kind, setup, C expression of the selector's low word, proven, selector class)
KINDS = [
    ('loaduw', ['%i =w loaduw %p'], 'x', 1, 'w'),
    ('loadw', ['%i =w loadw %p'], 'x', 1, 'w'),
    ('loaduwl', ['%i =l loaduw %p'], 'x', 1, 'l'),
    ('loadub', ['%i =w loadub %p'], '(uint8_t)x', 1, 'w'),
    ('loaduh', ['%i =w loaduh %p'], '(uint16_t)x', 1, 'w'),
    ('add', ['%x =w copy %w', '%i =w add %x, %arg'], 'x + y', 1, 'w'),
    ('sub', ['%x =w copy %w', '%i =w sub %x, %arg'], 'x - y', 1, 'w'),
    ('subrev', ['%x =w copy %w', '%i =w sub %arg, %x'], 'y - x', 1, 'w'),
    ('and', ['%x =w copy %w', '%i =w and %x, %arg'], 'x & y', 1, 'w'),
    ('or', ['%x =w copy %w', '%i =w or %x, %arg'], 'x | y', 1, 'w'),
    ('xor', ['%x =w copy %w', '%i =w xor %x, %arg'], 'x ^ y', 1, 'w'),
    ('addimm', ['%x =w copy %w', '%i =w add %x, 4294967293'], 'x - 3u', 1, 'w'),
    # The immediate's bytes (00 45 89 d2) end like `movl %r10d, %r10d`.
    ('addmagic', ['%x =w copy %w', '%i =w add %x, 3532211456'], 'x + 3532211456u', 1, 'w'),
    ('subimm', ['%x =w copy %w', '%i =w sub %x, 2'], 'x - 2u', 1, 'w'),
    ('addmem', ['%m =w loadw %p', '%i =w add %m, %arg'], 'x + y', 1, 'w'),
    # No proof of a clear high half: parameters, calls, unlisted or 64-bit ops.
    ('arg', ['%i =w copy %w'], 'x', 0, 'w'),
    ('opaque', ['%v =l call $p118_wide(l %w)', '%i =w copy %v'], 'x', 0, 'w'),
    ('call', ['%i =w loadw %p', 'call $p118_touch(l %w)'], 'x', 0, 'w'),
    ('store', ['%i =w loadw %p', 'storew %arg, $p118_cell'], 'x', 0, 'w'),
    ('mul', ['%x =w copy %w', '%i =w mul %x, %arg'], 'x * y', 0, 'w'),
    ('shl', ['%x =w copy %w', '%i =w shl %x, 1'], 'x << 1', 0, 'w'),
    ('urem', ['%x =w copy %w', '%d1 =w or %arg, 1', '%i =w urem %x, %d1'], 'x % (y | 1u)', 0, 'w'),
    ('loadsb', ['%i =w loadsb %p'], '(uint32_t)(int32_t)(int8_t)(uint8_t)x', 0, 'w'),
    ('loadsh', ['%i =w loadsh %p'], '(uint32_t)(int32_t)(int16_t)(uint16_t)x', 0, 'w'),
    ('loadl', ['%i =l loadl %p'], 'x', 0, 'l'),
    ('loadswl', ['%i =l loadsw %p'], 'x', 0, 'l'),
    ('addl', ['%z =l extuw %arg', '%i =l add %w, %z'], 'x + y', 0, 'l'),
    ('andl', ['%i =l and %w, 18446744069414584335'], 'x & 15u', 0, 'l'),
    ('cross', ['%i =w loaduw %p', '%c =w ceqw %arg, 0', 'jnz %c, @m1, @m2', '@m1',
               'call $p118_touch(l %w)', 'jmp @disp', '@m2', 'storew %arg, $p118_cell', 'jmp @disp', '@disp'],
     'x', 0, 'w'),
    ('phi', ['%x =w copy %w', '%c =w ceqw %arg, 0', 'jnz %c, @m1, @m2', '@m1',
             '%i1 =w loaduw %p', 'call $p118_touch(l %w)', 'jmp @disp', '@m2', '%i2 =w add %x, %arg',
             'storew %arg, $p118_cell', 'jmp @disp', '@disp', '%i =w phi @m1 %i1, @m2 %i2'],
     'y ? x + y : x', 0, 'w'),
]


def jtbl_fun(kind, setup, live, cls):
    s = [f'export function l $d_{kind}_{live}(l %w, l %p, w %arg) {{', '@entry']
    s += setup + [f'jtbl %i, {TABLE}']
    for label, val in ARMS:
        s.append('@' + label)
        if live:
            s.append(f'%z{label} =l extuw %i')
            s += [f'%s{label} =l add %z{label}, {val}', f'ret %s{label}']
        else:
            s.append(f'ret {val}')
    return s + ['}']


NPRESS = 16


def press_fun(live):
    """NPRESS loaded values live into every arm next to the selector, which
    only arm @b reads: the cheapest live-out, so it is spilled (RSlot)."""
    s = [f'export function l $press_{live}(l %w, l %p, w %arg) {{', '@entry']
    for n in range(NPRESS):
        s += [f'%q{n} =l add %p, {8 * n + 8}', f'%v{n} =l loadl %q{n}']
    s += ['%x =w copy %w', '%i =w add %x, %arg', f'jtbl %i, {TABLE}']
    for label, val in ARMS:
        last = str(val)
        s.append('@' + label)
        for n in range(NPRESS):
            s += [f'%m{label}{n} =l mul {last}, 33', f'%k{label}{n} =l xor %m{label}{n}, %v{n}']
            last = f'%k{label}{n}'
        if live and label == 'b':
            s += [f'%z{label} =l extuw %i', f'%s{label} =l add {last}, %z{label}']
            last = f'%s{label}'
        s.append('ret ' + last)
    return s + ['}']


# ---- widecmp ----

I64MIN, I64MAX = -2**63, 2**63 - 1
EXTS = (('extsw', -2**31, 2**31 - 1), ('extuw', 0, 2**32 - 1))
RELS = (('csgel', '>='), ('csgtl', '>'), ('cslel', '<='), ('csltl', '<'))
OFFS = (0, -2**31, 2**31 - 1, 1, -1)
PY = {'>=': lambda a, b: a >= b, '>': lambda a, b: a > b, '<=': lambda a, b: a <= b, '<': lambda a, b: a < b}


def cint(v):
    return '(-INT64_C(9223372036854775807) - 1)' if v == I64MIN else f'INT64_C({v})'


def bounds():
    """rows: (name, il lines, C oracle expression, expectation)"""
    rows = []

    def fun(name, body, ret='%t'):
        return [f'export function w ${name}(w %x) {{', '@entry'] + body + [f'ret {ret}', '}']

    def oracle(ext, off, op, lim):
        wide = '(int64_t)(int32_t)x' if ext == 'extsw' else '(int64_t)x'
        return f'(int64_t)((uint64_t)({wide}) + (uint64_t){cint(off)}) {op} {cint(lim)}'

    for ext, lo0, hi0 in EXTS:
        for off in OFFS:
            lo, hi = lo0 + off, hi0 + off
            for rel, op in RELS:
                for k, lim in enumerate((lo - 1, lo, lo + 1, hi - 1, hi, hi + 1, I64MIN, I64MAX)):
                    name = f'r{len(rows)}_{ext}_{rel}_{k}'
                    body = [f'%w =l {ext} %x']
                    if off:
                        body.append(f'%a =l add %w, {off}')
                    body.append(f'%t =w {rel} {"%a" if off else "%w"}, {lim}')
                    # Independent of the C code: the relation is monotone, so it is
                    # constant over the word range iff both attained ends agree.
                    f, g = PY[op](lo, lim), PY[op](hi, lim)
                    rows.append((name, fun(name, body), oracle(ext, off, op, lim), str(int(f)) if f == g else 'keep'))
        # Near misses of the pattern that must not fold.
        for rel, op in RELS:
            for off in (2**31, -2**31 - 1):
                lo, hi = lo0 + off, hi0 + off
                for lim in (lo, hi):
                    f, g = PY[op](lo, lim), PY[op](hi, lim)
                    name = f'r{len(rows)}_{ext}_{rel}_bigoff'
                    body = [f'%w =l {ext} %x', f'%a =l add %w, {off}', f'%t =w {rel} %a, {lim}']
                    rows.append((name, fun(name, body), oracle(ext, off, op, lim), 'keep'))
            # An offset that wraps at 64 bits: 2**63 - 1 + x.
            name = f'r{len(rows)}_{ext}_{rel}_wrap'
            body = [f'%w =l {ext} %x', f'%a =l add %w, {I64MAX}', f'%t =w {rel} %a, 0']
            rows.append((name, fun(name, body), oracle(ext, I64MAX, op, 0), 'keep'))
            # Offset added to the word before the extension (wraps at 32 bits).
            for lim in (lo0, hi0):
                f, g = PY[op](lo0, lim), PY[op](hi0, lim)
                name = f'r{len(rows)}_{ext}_{rel}_preadd'
                body = ['%y =w add %x, 1', f'%w =l {ext} %y', f'%t =w {rel} %w, {lim}']
                wide = '(int64_t)(int32_t)(x + 1u)' if ext == 'extsw' else '(int64_t)(uint32_t)(x + 1u)'
                rows.append((name, fun(name, body), f'{wide} {op} {cint(lim)}', str(int(f)) if f == g else 'keep'))
            # Commuted addition.
            for lim in (lo0 + 5, lo0 + 4):
                f, g = PY[op](lo0 + 5, lim), PY[op](hi0 + 5, lim)
                name = f'r{len(rows)}_{ext}_{rel}_comm'
                body = [f'%w =l {ext} %x', '%a =l add 5, %w', f'%t =w {rel} %a, {lim}']
                rows.append((name, fun(name, body), oracle(ext, 5, op, lim), str(int(f)) if f == g else 'keep'))
            # The folded comparison decides a branch.
            for lim in (lo0 - 1, lo0, hi0, hi0 + 1):
                f, g = PY[op](lo0, lim), PY[op](hi0, lim)
                name = f'r{len(rows)}_{ext}_{rel}_jnz'
                body = [f'%w =l {ext} %x', f'%t =w {rel} %w, {lim}', 'jnz %t, @yes, @no', '@yes', 'ret 1', '@no']
                rows.append((name, fun(name, body, '0'), oracle(ext, 0, op, lim), str(int(f)) if f == g else 'keep'))
    # Unrelated widenings and an l parameter: untouched.
    for rel, op in RELS:
        name = f'r{len(rows)}_par_{rel}'
        il = [f'export function w ${name}(l %x) {{', '@entry', f'%t =w {rel} %x, {-2**31}', 'ret %t', '}']
        rows.append((name, il, f'(int64_t)w {op} {cint(-2**31)}', 'keep'))
        name = f'r{len(rows)}_paradd_{rel}'
        il = [f'export function w ${name}(l %x) {{', '@entry', '%a =l add %x, 1', f'%t =w {rel} %a, 0', 'ret %t', '}']
        rows.append((name, il, f'(int64_t)(w + 1u) {op} 0', 'keep'))
    return rows


CHECK_HEAD = r'''#include <stdint.h>
#include <stdio.h>
#include <string.h>
static volatile uint64_t sink;
uint32_t p118_cell;
uint64_t p118_wide(uint64_t w) { sink = w; return w; }
void p118_touch(uint64_t w) { sink = w; }
static const uint32_t target[8] = {3, 3, 27, 9, 27, 9, 9, 3};
static unsigned long count, bad;
static void fail(const char *n, uint64_t w, uint32_t y, uint64_t got, uint64_t want) {
  if (bad++ < 20)
    printf("MISMATCH %s w=%llx y=%x got=%llx want=%llx\n", n, (unsigned long long)w, (unsigned)y,
           (unsigned long long)got, (unsigned long long)want);
}
static const uint32_t high[] = {0xdeadbeefu, 0u, 0xffffffffu, 0x80000000u, 1u};
#define NHIGH (sizeof high / sizeof *high)
'''


def check_c(rows):
    c = [CHECK_HEAD]
    for kind, _, _, _, _ in KINDS:
        for live in (0, 1):
            c.append(f'extern uint64_t d_{kind}_{live}(uint64_t, void *, uint32_t);')
    for live in (0, 1):
        c.append(f'extern uint64_t press_{live}(uint64_t, void *, uint32_t);')
    for name, il, _, _ in rows:
        c.append(f'extern uint32_t {name}(uint64_t);')
    c.append('static void jtbl_one(uint64_t w, uint32_t y) {')
    c.append('  uint32_t x = (uint32_t)w;')
    # { x, dirty } then the values of press_*: loadl of the pair has dirty high bits.
    c.append(f'  uint64_t mem[{NPRESS} + 1]; uint32_t pair[2] = {{ x, (uint32_t)(w >> 32) }};')
    c.append('  memcpy(mem, pair, sizeof pair);')
    c.append(f'  for (unsigned n = 0; n < {NPRESS}; n++) mem[n + 1] = (w + n) * UINT64_C(0x9e3779b97f4a7c15);')
    for kind, _, expr, _, _ in KINDS:
        for live in (0, 1):
            name = f'd_{kind}_{live}'
            c.append(f'  {{ uint32_t k = {expr}; uint64_t e = k < 8 ? target[k] : 41, g = {name}(w, mem, y);'
                     + (' e += k;' if live else '')
                     + f' count++; if (g != e) fail("{name}", w, y, g, e); }}')
    for live in (0, 1):
        name = f'press_{live}'
        c.append(f'  {{ uint32_t k = x + y; uint64_t e = k < 8 ? target[k] : 41, g = {name}(w, mem, y);'
                 f' for (unsigned n = 0; n < {NPRESS}; n++) e = (e * 33) ^ mem[n + 1];'
                 + (' if (k < 8 && target[k] == 9) e += k;' if live else '') + f' count++; if (g != e) fail("{name}", w, y, g, e); }}')
    c.append('}')
    chunks = [rows[n:n + 64] for n in range(0, len(rows), 64)]
    for n, chunk in enumerate(chunks):
        c.append(f'static void bounds_{n}(uint64_t w) {{')
        c.append('  uint32_t x = (uint32_t)w; (void)x;')
        for name, il, expr, _ in chunk:
            c.append(f'  {{ uint32_t e = {expr}, g = {name}(w); count++; if (g != e) fail("{name}", w, 0, g, e); }}')
        c.append('}')
    c.append(r'''int main(void) {
  unsigned long total = 0;
  for (uint32_t j = 0; j < 2048; j++) {
    uint32_t x = j % 4 == 0 ? j % 9 : j % 4 == 1 ? 0xffffffffu - j % 12 : j % 4 == 2 ? (j % 16) | (j << 8) : j * 2654435761u;
    jtbl_one(((uint64_t)(high[j % NHIGH] ^ (j >> 5)) << 32) | x, j % 8);
  }
  /* Every small selector and the neighbours of the table end, every dirty high half. */
  for (uint32_t h = 0; h < NHIGH; h++)
    for (uint32_t x = 0; x < 12; x++)
      for (uint32_t y = 0; y < 4; y++) {
        jtbl_one(((uint64_t)high[h] << 32) | x, y);
        jtbl_one(((uint64_t)high[h] << 32) | (0u - x), y);
      }
  printf("jtbl %lu\n", count);
  total += count; count = 0;
  static const uint32_t in[] = {0u, 1u, 2u, 3u, 4u, 5u, UINT32_MAX, UINT32_MAX - 1, UINT32_MAX - 4, UINT32_MAX - 5, UINT32_MAX - 6,
    0x80000000u, 0x80000001u, 0x80000002u, 0x7fffffffu, 0x7ffffffeu, 0x7ffffffdu, 0xdeadbeefu};
  for (unsigned n = 0; n < sizeof in / sizeof *in; n++)
    for (unsigned h = 0; h < NHIGH; h++) {
      uint64_t w = ((uint64_t)high[h] << 32) | in[n];''')
    for n in range(len(chunks)):
        c.append(f'      bounds_{n}(w);')
    c.append(r'''    }
  printf("bounds %lu\n", count);
  total += count;
  printf("total %lu bad %lu\n", total, bad);
  return bad != 0 || total == 0;
}''')
    return c


def expect_row(r):
    name, il, _, want = r
    if want != 'keep':
        return f'{name} {want}\n'
    # `%t =w OP ARG, LIMIT`: the one comparison of the function.
    (cmp,) = [ln for ln in il if ln.startswith('%t =w cs')]
    _, _, op, arg, lim = cmp.split()
    return f'{name} keep {op} {arg.rstrip(",")} {lim}\n'


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    ssa, expect = [], []
    for kind, setup, _, proven, cls in KINDS:
        for live in (0, 1):
            ssa += jtbl_fun(kind, setup, live, cls)
            expect.append(f'd_{kind}_{live} ' + (('live' if proven else 'livenorm') if live else ('direct' if proven else 'norm')) + f' {NTBL}')
    ssa += press_fun(0) + press_fun(1)
    expect += [f'press_0 direct {NTBL}', f'press_1 slot {NTBL}']
    rows = bounds()
    (out / 'jtbl.ssa').write_text('\n'.join(ssa) + '\n')
    (out / 'jtbl_expect.txt').write_text('\n'.join(expect) + '\n')
    (out / 'bounds.ssa').write_text('\n'.join(ln for r in rows for ln in r[1]) + '\n')
    (out / 'bounds_expect.txt').write_text(''.join(expect_row(r) for r in rows))
    (out / 'check.c').write_text('\n'.join(check_c(rows)) + '\n')


main()
