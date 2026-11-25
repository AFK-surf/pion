"""P124 case generator.

usage: python3 -E gen.py OUT_DIR

Writes OUT_DIR/<case>.pion for every case and OUT_DIR/cases.txt with one line
per case:

    NAME EXIT IMM MIN MAX ALL DYN

EXIT is the expected exit status; OUT_DIR/<case>.stdout and <case>.stderr hold
the exact expected streams. The expectations come from the plain array
semantics below (Python lists, index checks against the real length), not from
the compiler. IMM MIN MAX ALL describe `$pion_fn_probe` in the emitted QBE text:
between MIN and MAX (-1: unbounded) unsigned bounds checks compare against the
immediate IMM, ALL=1 also requires every bounds check of the function to
use that immediate (no header length is loaded for a bounds check), and at
least DYN checks compare against a loaded length (an SSA temporary).
"""
import os
import sys

FILL = '''  let a : Array[Int] = []
  let mut i = 0
  while i < {n} {{ a.push(7); i = i + 1 }}
'''

MAIN = '''pub fn main(w : World) -> Int {{
  io_println(w, probe({args}).to_string())
  0
}}
'''


class Trap(Exception):
    def __init__(self, idx, length):
        self.idx = idx
        self.length = length


def get(xs, k):
    if k < 0 or k >= len(xs):
        raise Trap(k, len(xs))
    return xs[k]


def put(xs, k, v):
    if k < 0 or k >= len(xs):
        raise Trap(k, len(xs))
    xs[k] = v


def ref_single(k, j):
    a = [7] * 37
    put(a, k, get(a, j) + 5)
    put(a, k, get(a, k))
    s = 0
    for t in range(37):
        put(a, t, get(a, t) + t)
        s += get(a, t)
    return s * 100 + get(a, k)


def ref_multi(k):
    a = [3] * 37
    b = [5] * 37
    put(b, k, get(a, k) * 2 + get(b, 36 - k))
    put(a, 36 - k, get(b, k) + 1)
    return get(a, k) * 10000 + get(b, k) * 100 + get(a, 36 - k)


def grown(k):
    a = [7] * 37
    a.append(19)
    return get(a, k)


def ref_shrink(k):
    a = [7] * 37
    a.pop()
    return get(a, k)


def ref_callarg(k):
    a = [7] * 37
    return get(a, k) + len(a)


def ref_shadow_short(k):
    a = [7] * 37
    s = get(a, k - 2)
    inner = [10, 20]
    return s + get(inner, k)


def ref_shadow_long(k):
    a = [7] * 37
    s = get(a, k - 2)
    inner = list(range(40))
    return s + get(inner, k)


def ref_loop_shadow_len(k):
    a = [7] * 3
    s = 0
    for j in range(k):
        s += get(a, k)
        inner = [10, 20]
        s += len(inner)
    return s


def ref_loop_shadow_idx(k, off):
    a = [7] * 3
    s = 0
    for j in range(k):
        s += get(a, k)
        inner = [10, 20]
        s += get(inner, j + off) * 100
    return s


def ref_read(n, k):
    a = [7] * n
    return get(a, k)


def ref_write(k):
    a = [7] * 37
    put(a, k, 1)
    return get(a, 0)


LONG = ', '.join(str(x) for x in range(40))

LOOP_FILL = '''  let a : Array[Int] = []
  let mut i = 0
  while i < 3 { a.push(7); i = i + 1 }
  let mut s = 0
  let mut j = 0
'''

# name: (source of probe, extra top-level items, main args, reference, imm, min, max, all, dyn)
CASES = [
    ('single', '''fn probe(k : Int, j : Int) -> Int {
''' + FILL.format(n=37) + '''  a[k] = a[j] + 5
  a[k] = a[k]
  let mut s = 0
  let mut t = 0
  while t < 37 {
    a[t] = a[t] + t
    s = s + a[t]
    t = t + 1
  }
  s * 100 + a[k]
}
''', '', '3, 36', lambda: ref_single(3, 36), 37, 3, -1, 1, 0),
    ('multi', '''fn probe(k : Int) -> Int {
  let a : Array[Int] = []
  let b : Array[Int] = []
  let mut i = 0
  while i < 37 { a.push(3); b.push(5); i = i + 1 }
  b[k] = a[k] * 2 + b[36 - k]
  a[36 - k] = b[k] + 1
  a[k] * 10000 + b[k] * 100 + a[36 - k]
}
''', '', '4', lambda: ref_multi(4), 37, 4, -1, 1, 0),
    ('alias', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let b = a
  b.push(19)
  a[k]
}
''', '', '37', lambda: grown(37), 37, 0, 0, 0, 1),
    ('grow', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  a.push(19)
  a[k]
}
''', '', '37', lambda: grown(37), 37, 0, 0, 0, 1),
    ('shrink', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let _ = a.pop()
  a[k]
}
''', '', '36', lambda: ref_shrink(36), 37, 0, 0, 0, 1),
    ('capture', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let f = fn() -> Unit { a.push(19) }
  f()
  a[k]
}
''', '', '37', lambda: grown(37), 37, 0, 0, 0, 1),
    ('mutarg', '''fn probe(k : Int) -> Int {
''' + FILL.replace('let a', 'let mut a').format(n=37) + '''  grow(mut a)
  a[k]
}
''', 'fn grow(mut xs : Array[Int]) -> Unit { xs.push(19) }\n', '37', lambda: grown(37), 37, 0, 0, 0, 1),
    ('callarg', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let n = size(a)
  a[k] + n
}
''', 'fn size(xs : Array[Int]) -> Int { xs.length() }\n', '36', lambda: ref_callarg(36), 37, 0, 0, 0, 1),
    ('shadow_short', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let s = a[k - 2]
  let t = {
    let a = [10, 20]
    a[k]
  }
  s + t
}
''', '', '2', lambda: ref_shadow_short(2), 37, 1, 1, 0, 1),
    ('shadow_long', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  let s = a[k - 2]
  let t = {
    let a = [''' + LONG + ''']
    a[k]
  }
  s + t
}
''', '', '38', lambda: ref_shadow_long(38), 37, 1, 1, 0, 1),
    ('loop_shadow_len', '''fn probe(k : Int) -> Int {
''' + LOOP_FILL + '''  while j < k {
    s = s + a[k]
    let a = [10, 20]
    s = s + a.length()
    j = j + 1
  }
  s
}
''', '', '1', lambda: ref_loop_shadow_len(1), 3, 1, 1, 0, 0),
    ('loop_shadow_idx', '''fn probe(k : Int) -> Int {
''' + LOOP_FILL + '''  while j < k {
    s = s + a[k]
    let a = [10, 20]
    s = s + a[j] * 100
    j = j + 1
  }
  s
}
''', '', '2', lambda: ref_loop_shadow_idx(2, 0), 3, 1, 1, 0, 1),
    ('loop_shadow_trap', '''fn probe(k : Int) -> Int {
''' + LOOP_FILL + '''  while j < k {
    s = s + a[k]
    let a = [10, 20]
    s = s + a[j + 1] * 100
    j = j + 1
  }
  s
}
''', '', '2', lambda: ref_loop_shadow_idx(2, 1), 3, 1, 1, 0, 1),
    ('trap_negative', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  a[k]
}
''', '', '-1', lambda: ref_read(37, -1), 37, 1, -1, 1, 0),
    ('trap_length', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  a[k]
}
''', '', '37', lambda: ref_read(37, 37), 37, 1, -1, 1, 0),
    ('trap_large', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  a[k]
}
''', '', '100', lambda: ref_read(37, 100), 37, 1, -1, 1, 0),
    ('trap_write', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=37) + '''  a[k] = 1
  a[0]
}
''', '', '37', lambda: ref_write(37), 37, 1, -1, 1, 0),
    ('trap_empty', '''fn probe(k : Int) -> Int {
''' + FILL.format(n=0) + '''  a[k]
}
''', '', '0', lambda: ref_read(0, 0), 0, 1, -1, 1, 0),
]


def main():
    out = sys.argv[1]
    lines = []
    for name, probe, extra, args, ref, imm, lo, hi, every, dyn in CASES:
        with open(os.path.join(out, name + '.pion'), 'w') as f:
            f.write(extra + probe + MAIN.format(args=args))
        try:
            stdout = f'{ref()}\n'
            stderr = ''
            code = 0
        except Trap as t:
            stdout = ''
            stderr = f'pion panic: index {t.idx} out of bounds (len {t.length})\n'
            code = 134
        with open(os.path.join(out, name + '.stdout'), 'w') as f:
            f.write(stdout)
        with open(os.path.join(out, name + '.stderr'), 'w') as f:
            f.write(stderr)
        lines.append(f'{name} {code} {imm} {lo} {hi} {every} {dyn}\n')
    with open(os.path.join(out, 'cases.txt'), 'w') as f:
        f.writelines(lines)


main()
