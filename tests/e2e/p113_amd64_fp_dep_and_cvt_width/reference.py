"""Exact IEEE-754 reference for p113.pion (writes expected.txt to stdout).

Doubles are Python floats (binary64, round to nearest even). Float values
are kept as binary32 bit patterns; each binary32 operation is evaluated in
binary64 and rounded once to binary32 (exact for + - * / of binary32
operands, since 53 >= 2 * 24 + 2). Integer -> float conversions are rounded
exactly from the integer. A NaN produced by an operation prints as `nan`.
"""
import ctypes
import math
import struct


def i64(x):
    x &= (1 << 64) - 1
    return x - (1 << 64) if x >> 63 else x


def i32(x):
    x &= (1 << 32) - 1
    return x - (1 << 32) if x >> 31 else x


def dbits(x):
    return str(i64(struct.unpack('<Q', struct.pack('<d', x))[0]))


def dfrom(bits):
    return struct.unpack('<d', struct.pack('<Q', bits & ((1 << 64) - 1)))[0]


def dres(x):
    return 'nan' if math.isnan(x) else dbits(x)


def dneg(x):
    return dfrom(int(dbits(x)) ^ (1 << 63))


def ddiv(a, b):
    if math.isnan(a) or math.isnan(b):
        return math.nan
    if b == 0.0:
        if a == 0.0:
            return math.nan
        neg = (math.copysign(1.0, a) < 0) != (math.copysign(1.0, b) < 0)
        return -math.inf if neg else math.inf
    if math.isinf(a) and math.isinf(b):
        return math.nan
    return a / b


# ---- binary32 as bit patterns -------------------------------------------

def f_round(x):
    """binary64 -> binary32 bits, round to nearest even, overflow -> inf."""
    if math.isnan(x):
        return 0x7FC00000
    return struct.unpack('<I', struct.pack('<f', ctypes.c_float(x).value))[0]


def f_val(bits):
    return struct.unpack('<f', struct.pack('<I', bits & 0xFFFFFFFF))[0]


def f_isnan(bits):
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x7FFFFF) != 0


def fbits(bits):
    return str(i32(bits))


def fres(bits):
    return 'nan' if f_isnan(bits) else fbits(bits)


def fneg(bits):
    return (bits ^ 0x80000000) & 0xFFFFFFFF


def fop(op, a, b):
    if f_isnan(a) or f_isnan(b):
        return 0x7FC00000
    x, y = f_val(a), f_val(b)
    if op == '+':
        if math.isinf(x) and math.isinf(y) and x != y:
            return 0x7FC00000
        r = x + y
    elif op == '-':
        if math.isinf(x) and math.isinf(y) and x == y:
            return 0x7FC00000
        r = x - y
    elif op == '*':
        if (math.isinf(x) and y == 0.0) or (math.isinf(y) and x == 0.0):
            return 0x7FC00000
        r = x * y
    else:
        r = ddiv(x, y)
    return f_round(r)


def fconst(x):
    return f_round(x)


def int_to_f32(v):
    if v == 0:
        return 0
    m = abs(v)
    n = m.bit_length()
    if n > 24:
        shift = n - 24
        q, r = m >> shift, m & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        if r > half or (r == half and q & 1):
            q += 1
        m = q << shift
    return f_round(float(m) if v > 0 else -float(m))


def int_to_f64(v):
    return float(v)  # correctly rounded


# ---- p113.pion ----------------------------------------------------------

INT_MIN32 = -2147483648
INT_MIN64 = -9223372036854775808


def grouped(a, b, c, d):
    xs = [int_to_f64(a), int_to_f64(b), int_to_f64(c), int_to_f64(d)]
    ys = [int_to_f32(a), int_to_f32(b), int_to_f32(c), int_to_f32(d)]
    return ' '.join([dbits(x) for x in xs] + [fbits(y) for y in ys])


def loop_sum(xs, ys):
    acc = 0.0
    for j in range(len(xs)):
        acc = acc + int_to_f64(xs[j]) / (int_to_f64(ys[j]) + 0.5)
    return acc


def loop_sum_f(xs, ys):
    acc = 0
    for j in range(len(xs)):
        p, q = int_to_f32(xs[j]), int_to_f32(ys[j])
        acc = fop('-', fop('+', acc, fop('*', p, fconst(0.25))), fop('*', q, fconst(0.125)))
    return acc


def pressure(v):
    a = v[:10]
    d = [int_to_f64(x) for x in a]
    f = [int_to_f32(x) for x in a]
    s = d[0] * 0.5 + d[1] * 0.25 + d[2] * 0.125
    for k in range(3, 10):
        s = s + d[k]
    t = fop('+', fop('+', fop('*', f[0], fconst(0.5)), fop('*', f[1], fconst(0.25))), fop('*', f[2], fconst(0.125)))
    for k in range(3, 10):
        t = fop('+', t, f[k])
    out = dbits(s) + ' ' + fbits(t)
    out += ' | ' + ' '.join(dbits(x) for x in d)
    out += ' | ' + ' '.join(fbits(x) for x in f)
    return out + ' | ' + str(i64(sum(a)))


def copy_d(a, b):
    x, y = b, a
    return ' '.join([dbits(x), dbits(y), dbits(dneg(x)), dbits(dneg(y))])


def div_d(a, b):
    return ' '.join([dres(ddiv(a, b)), dres(ddiv(b, a)), dres(ddiv(a, a))])


def neg_div_d(a, b):
    n = dneg(a)
    q = ddiv(b, n)
    return ' '.join([dres(n), dres(q), dres(ddiv(n, q))])


def copy_f(a, b):
    x, y = b, a
    return ' '.join([fbits(x), fbits(y), fbits(fneg(x)), fbits(fneg(y))])


def div_f(a, b):
    return ' '.join([fres(fop('/', a, b)), fres(fop('/', b, a)), fres(fop('/', a, a))])


def iterate_d(cr, ci):
    zr = zi = 0.0
    k = 0
    while k < 40:
        tr = zr * zr - zi * zi + cr
        ti = (zr + zr) * zi + ci
        zr, zi = tr, ti
        if zr * zr + zi * zi > 4.0:
            break
        k += 1
    return f'{k} {dres(zr)} {dres(zi)}'


def iterate_f(cr, ci):
    cr, ci = fconst(cr), fconst(ci)
    zr = zi = 0
    k = 0
    while k < 40:
        tr = fop('+', fop('-', fop('*', zr, zr), fop('*', zi, zi)), cr)
        ti = fop('+', fop('*', fop('+', zr, zr), zi), ci)
        zr, zi = tr, ti
        m = fop('+', fop('*', zr, zr), fop('*', zi, zi))
        if not f_isnan(m) and f_val(m) > 4.0:
            break
        k += 1
    return f'{k} {fres(zr)} {fres(zi)}'


def main():
    out = []
    ws = [INT_MIN32, 2147483647, -1, 0, 1, 16777217, -16777217, 123456789]
    ls = [INT_MIN64, 9223372036854775807, -1, 0, 1, 4294967297, -4294967297,
          9007199254740993, -9007199254740993, 2147483648, -2147483649, 16777217]
    for a in ws:
        out.append(f'iso_w {a} {dbits(int_to_f64(a))} {fbits(int_to_f32(a))}')
    for a in ls:
        out.append(f'iso_l {a} {dbits(int_to_f64(a))} {fbits(int_to_f32(a))}')
    for j in range(len(ls)):
        a, b = ws[j % len(ws)], ws[(j + 3) % len(ws)]
        c, d = ls[j], ls[(j + 5) % len(ls)]
        out.append(f'grouped {j} ' + grouped(a, b, c, d))
    ys = [1, -3, 4294967297, -4294967297, 7, 2, -9, 100]
    out.append('loop_sum ' + dbits(loop_sum(ws, ys)) + ' ' + fbits(loop_sum_f(ws, ys)))
    out.append('pressure0 ' + pressure(ls))
    rot = [ls[(r + 4) % len(ls)] for r in range(len(ls))]
    out.append('pressure1 ' + pressure(rot))
    ds = [0.0, dfrom(1 << 63), dfrom(1), dfrom(4503599627370495), 1.0, -2.5, 3.0, 1.0e308,
          dfrom(0x7FF0000000000000), dfrom(0xFFF0000000000000), dfrom(0x7FF8000000000123)]
    for i in range(len(ds)):
        a, b = ds[i], ds[(i + 1) % len(ds)]
        out.append(f'd {i} copy {copy_d(a, b)} div {div_d(a, b)} negdiv {neg_div_d(a, b)}')
    fs = [0, 0x80000000, 1, 8388607, fconst(1.0), fconst(-2.5), fconst(3.0), fconst(3.0e38),
          0x7F800000, 0xFF800000, 0x7FC00123]
    for i in range(len(fs)):
        a, b = fs[i], fs[(i + 1) % len(fs)]
        out.append(f'f {i} copy {copy_f(a, b)} div {div_f(a, b)}')
    out.append('iter_d ' + ' '.join([iterate_d(-0.75, 0.1), iterate_d(0.25, 0.5), iterate_d(-2.0, 0.0)]))
    out.append('iter_f ' + ' '.join([iterate_f(-0.75, 0.1), iterate_f(0.25, 0.5), iterate_f(-2.0, 0.0)]))
    print('\n'.join(out))


main()
