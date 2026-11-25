"""P123 generator: Pion sources and reference outputs for the guarded exchange.

usage: python3 -E gen.py OUT_DIR

Writes into OUT_DIR:
  edges.pion / edges.expected  every valid (start, bound, axis) over a 5-element
                               Array[Int], through `exchange` (the recognised
                               loop) and `constrained` (the same loop with an
                               extra `&& i < 2` condition, which stays indexed);
                               each line is the exit induction value followed by
                               the five final elements, from an independent
                               Python reference
  trap_<name>.pion             one out-of-range exchange each, run in its own
  traps.txt                    process: `<name> <expected index>` per line
"""
import os
import sys

LEN = 5
WORD_MAX = 2147483647

# Every (start, bound, axis) with start, bound in 0..5 and axis in -1..10 whose
# accesses all stay in range: empty ranges (bound <= start, any axis), single
# elements, self exchanges (axis = 2 * i), coinciding / crossing pointers and
# right-side axes at both ends.
SPECS = [(s, b, k) for s in range(6) for b in range(6) for k in range(-1, 11)
         if b <= s or (0 <= k - b + 1 and k - s < LEN)]
assert len(SPECS) == 307, len(SPECS)

# Out-of-range starts: (start, bound, axis, first failing index). The fast path
# is not entered, the checked loop runs the earlier in-range exchanges and the
# first out-of-range access panics with that index.
TRAPS = {
    'left_negative': (-1, 2, 3, -1),   # a[-1] on the first read
    'left_past_end': (3, 7, 6, 5),     # a[3]<->a[3], a[4]<->a[2], then a[5]
    'right_past_end': (0, 1, 8, 8),    # a[0] is read, then a[8 - 0]
    'right_negative': (0, 4, 1, -1),   # two exchanges, then a[1 - 2]
}


def loop(name, conditional):
    extra = ' && i < 2' if conditional else ''
    return f"""fn {name}(world : World, start : Int, bound : Int, k : Int) -> Unit {{
  let a : Array[Int] = []
  let mut n = 0
  while n < {LEN} {{
    a.push(10 + n)
    n = n + 1
  }}
  let mut i = start
  while i < bound{extra} {{
    let t = a[i]
    a[i] = a[k - i]
    a[k - i] = t
    i = i + 1
  }}
  let mut line = i.to_string()
  let mut q = 0
  while q < {LEN} {{
    line = line + " " + a[q].to_string()
    q = q + 1
  }}
  io_println(world, line)
}}

"""


def reference(start, bound, axis, limit):
    a = [10 + n for n in range(LEN)]
    i = start
    while i < bound and i < limit:
        assert 0 <= i < LEN and 0 <= axis - i < LEN
        assert -WORD_MAX - 1 <= axis - i <= WORD_MAX
        a[i], a[axis - i] = a[axis - i], a[i]
        i += 1
    return ' '.join(str(x) for x in [i] + a)


def main():
    out = sys.argv[1]
    body = []
    expected = []
    for s, b, k in SPECS:
        for name, limit in (('exchange', WORD_MAX), ('constrained', 2)):
            body.append(f'  {name}(world, {s}, {b}, {k})\n')
            expected.append(reference(s, b, k, limit))
    head = loop('exchange', False) + loop('constrained', True)
    with open(os.path.join(out, 'edges.pion'), 'w') as f:
        f.write(head + 'pub fn main(world : World) -> Int {\n' + ''.join(body) + '  0\n}\n')
    with open(os.path.join(out, 'edges.expected'), 'w') as f:
        f.write('\n'.join(expected) + '\n')
    with open(os.path.join(out, 'traps.txt'), 'w') as f:
        for name, (s, b, k, idx) in TRAPS.items():
            with open(os.path.join(out, f'trap_{name}.pion'), 'w') as g:
                g.write(loop('exchange', False) +
                        'pub fn main(world : World) -> Int {\n'
                        f'  exchange(world, {s}, {b}, {k})\n  0\n}}\n')
            f.write(f'{name} {idx}\n')
    print(f'p123 gen: {len(SPECS)} valid (start, bound, axis) specs, '
          f'{len(expected)} cases, {len(TRAPS)} trap programs')


main()
