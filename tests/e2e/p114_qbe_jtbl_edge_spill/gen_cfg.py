"""Generate the p114 QBE fixture: loop-carried values under register pressure
dispatched through `jtbl` with duplicate entries, a default arm, negative and
out-of-range selectors, an early exit and 0..19 rounds.

usage: python3 -E gen_cfg.py OUT_DIR
writes OUT_DIR/cfg.ssa (QBE IL), OUT_DIR/check.c (C reference + driver) and
OUT_DIR/expect.txt (`name kind` per function, checked by check_dump.py).

Every function `f(seed, rounds)` keeps n values v[i] (v[i] = seed + 17 i) in
a loop. Round j selects idx = ((seed + j) & 15) - 2 (unsigned, so -2 / -1 and
9..13 take the default arm @a7) through

  jtbl %idx, @a7, @a0, @a1, @a2, @a3, @a3, @a4, @a5, @a5, @a6

(entries 3/4 and 6/7 are duplicates). Arm k rewrites v[i] when touched(k, i):
v[i] = opaque(v[i], v[i+1]) when calls(k, i), else v[i] + v[i+1]. The loop
leaves early when (v[0] & 31) == 0 after a round. The result folds every
value into one hash (or returns seed when rounds == 0).

sink   only the default arm calls, so only a minority of the table entries
       can read a private spill home: the shadow stores of the loop-carried
       values move onto those entries.
pred   as sink, but the table sits in its own block whose only predecessor
       (the loop header, with a never-taken bail-out) holds the stores.
major  calls in 7 of 10 entries: homes read by more than half the entries
       must stay (a home read only by the default arm may still move).
head   a call in the table block after the shadow stores: the homes are read
       after the original write in the same block, nothing may move.
multi  arm @a0 continues into the default arm @a7: a target that reads a home
       and has a second predecessor keeps it (when register allocation puts
       an edge-copy block on table -> @a7, that block is the sole-predecessor
       target instead).
flat   one dispatch without a loop: nothing may move.
dup    the duplicated arm @a3 (entries 3 and 4) calls as well as the default
       arm: 3 of 10 entries need the homes, and the shared @a3 target gets
       the store exactly once.
"""
import sys
from pathlib import Path

ARM = [0, 1, 2, 3, 3, 4, 5, 5, 6]  # table entry -> arm, default arm 7


def spec(kind, n):
    if kind == 'major':
        touched = lambda k, i: k == 7 or i % 7 == k or (k != 6 and i % 3 == 0)
        calls = lambda k, i: k != 6 and i % 3 == 0
    elif kind == 'dup':
        touched = lambda k, i: k in (3, 7) or i % 7 == k
        calls = lambda k, i: k in (3, 7) and i % 3 == 0
    else:
        touched = lambda k, i: k == 7 or i % 7 == k
        calls = lambda k, i: k == 7 and i % 3 == 0
    return touched, calls


def ssa_loop(name, kind, n):
    touched, calls = spec(kind, n)
    s = [f'export function w ${name}(w %seed, w %rounds) {{', '@start']
    for i in range(n):
        s.append(f'%i{i} =w add %seed, {i * 17}')
    s += ['%zero =w ceqw %rounds, 0', 'jnz %zero, @empty, @head', '@empty', 'ret %seed', '@head',
          '%j =w phi @start 0, @cont %next']
    for i in range(n):
        s.append(f'%v{i} =w phi @start %i{i}, @cont %p{i}')
    if kind == 'head':
        s.append('%op0 =w call $opaque(w %seed, w %j)')
        s.append('%op =w sub %op0, 193')
        s.append('%opx =w add %op, %j')
    else:
        s.append('%opx =w add %seed, %j')
    s.append('%mask =w and %opx, 15')
    if kind == 'pred':
        # A never-taken bail-out keeps @tbl a separate block whose only
        # predecessor @head holds the shadow stores.
        s += ['%bail =w cugtw %j, 1000000', 'jnz %bail, @out, @tbl', '@out', 'ret 7', '@tbl']
    s += ['%idx =w sub %mask, 2',
          'jtbl %idx, @a7, @a0, @a1, @a2, @a3, @a3, @a4, @a5, @a5, @a6']
    changed = {}
    for k in range(8):
        s.append(f'@a{k}')
        if kind == 'multi' and k == 0:
            s.append('jmp @a7')
            continue
        for i in range(n):
            if touched(k, i):
                if calls(k, i):
                    ins = f'call $opaque(w %v{i}, w %v{(i + 1) % n})'
                else:
                    ins = f'add %v{i}, %v{(i + 1) % n}'
                v = f'%t{k}_{i}'
                s.append(f'{v} =w {ins}')
                changed[k, i] = v
        s.append('jmp @latch')
    s.append('@latch')
    arms = [k for k in range(8) if not (kind == 'multi' and k == 0)]
    for i in range(n):
        s.append(f'%p{i} =w phi ' + ', '.join(f'@a{k} ' + changed.get((k, i), f'%v{i}') for k in arms))
    s += ['%low =w and %p0, 31', '%stop =w ceqw %low, 0', 'jnz %stop, @done, @cont',
          '@cont', '%next =w add %j, 1', '%again =w cultw %next, %rounds', 'jnz %again, @head, @done',
          '@done']
    last = '%seed'
    for i in range(n):
        s += [f'%h{i} =w mul {last}, 33', f'%acc{i} =w xor %h{i}, %p{i}']
        last = f'%acc{i}'
    s += ['ret ' + last, '}']
    return s


def ssa_flat(name, n):
    touched, calls = spec('flat', n)
    s = [f'export function w ${name}(w %seed, w %rounds) {{', '@start']
    for i in range(n):
        s.append(f'%v{i} =w add %seed, {i * 17}')
    s += ['%opx =w add %seed, %rounds', '%mask =w and %opx, 15', '%idx =w sub %mask, 2',
          'jtbl %idx, @a7, @a0, @a1, @a2, @a3, @a3, @a4, @a5, @a5, @a6']
    changed = {}
    for k in range(8):
        s.append(f'@a{k}')
        for i in range(n):
            if touched(k, i):
                ins = (f'call $opaque(w %v{i}, w %v{(i + 1) % n})' if calls(k, i)
                       else f'add %v{i}, %v{(i + 1) % n}')
                s.append(f'%t{k}_{i} =w {ins}')
                changed[k, i] = f'%t{k}_{i}'
        s.append('jmp @join')
    s.append('@join')
    for i in range(n):
        s.append(f'%p{i} =w phi ' + ', '.join(f'@a{k} ' + changed.get((k, i), f'%v{i}') for k in range(8)))
    last = '%seed'
    for i in range(n):
        s += [f'%h{i} =w mul {last}, 33', f'%acc{i} =w xor %h{i}, %p{i}']
        last = f'%acc{i}'
    s += ['ret ' + last, '}']
    return s


def c_ref(name, kind, n):
    touched, calls = spec(kind, n)
    tc = ' || '.join(f'(k=={k} && i=={i})' for k in range(8) for i in range(n) if touched(k, i)) or '0'
    cc = ' || '.join(f'(k=={k} && i=={i})' for k in range(8) for i in range(n) if calls(k, i)) or '0'
    body = f'''static int touched_{name}(unsigned k, unsigned i) {{ return {tc}; }}
static int calls_{name}(unsigned k, unsigned i) {{ return {cc}; }}
static void round_{name}(U *x, unsigned k) {{
  U y[{n}];
  for (unsigned i = 0; i < {n}; i++) {{
    U a = x[i], b = x[(i + 1) % {n}];
    y[i] = a;
    if (touched_{name}(k, i)) y[i] = calls_{name}(k, i) ? opaque(a, b) : a + b;
  }}
  for (unsigned i = 0; i < {n}; i++) x[i] = y[i];
}}
'''
    if kind == 'flat':
        body += f'''static U ref_{name}(U seed, U rounds) {{
  U x[{n}], h = seed;
  for (unsigned i = 0; i < {n}; i++) x[i] = seed + 17u * i;
  U idx = ((seed + rounds) & 15u) - 2u;
  round_{name}(x, idx < 9u ? arm[idx] : 7u);
  for (unsigned i = 0; i < {n}; i++) h = (33u * h) ^ x[i];
  return h;
}}
'''
        return body
    sel = '(opaque(seed, j) - 193u) + j' if kind == 'head' else 'seed + j'
    body += f'''static U ref_{name}(U seed, U rounds) {{
  U x[{n}], h = seed;
  if (!rounds) return seed;
  for (unsigned i = 0; i < {n}; i++) x[i] = seed + 17u * i;
  for (U j = 0; j < rounds; j++) {{
    U idx = (({sel}) & 15u) - 2u;
    unsigned k = idx < 9u ? arm[idx] : 7u;
    if ({1 if kind == 'multi' else 0} && k == 0) k = 7;
    round_{name}(x, k);
    if ((x[0] & 31u) == 0) break;
  }}
  for (unsigned i = 0; i < {n}; i++) h = (33u * h) ^ x[i];
  return h;
}}
'''
    return body


def main():
    out = Path(sys.argv[1])
    funcs = [(f'sink{n}', 'sink', n) for n in (7, 11, 14, 18, 23)]
    funcs += [('pred14', 'pred', 14), ('dup14', 'dup', 14), ('dup23', 'dup', 23)]
    funcs += [('major23', 'major', 23), ('head23', 'head', 23), ('multi14', 'multi', 14), ('multi23', 'multi', 23),
              ('flat14', 'flat', 14)]
    ssa = []
    c = ['#include <stdint.h>', '#include <stdio.h>', 'typedef uint32_t U;',
         'static const unsigned arm[9] = {' + ', '.join(map(str, ARM)) + '};',
         'U opaque(U a, U b) { return (a ^ (b * 2654435761u)) + 193u; }']
    for name, kind, n in funcs:
        ssa += ssa_flat(name, n) if kind == 'flat' else ssa_loop(name, kind, n)
        c.append(f'extern U {name}(U, U);')
        c.append(c_ref(name, kind, n))
    c.append('int main(void) {')
    c.append('  unsigned total = 0, bad = 0;')
    for name, kind, n in funcs:
        c.append(f'''  {{
    unsigned count = 0; U hash = 0;
    for (U i = 0; i < 512; i++)
      for (U j = 0; j < 20; j++) {{
        U x = i * 2654435761u, v = {name}(x, j);
        if (v != ref_{name}(x, j)) {{ bad++; printf("MISMATCH {name} %u %u\\n", x, j); }}
        hash = 33u * hash + v; count++;
      }}
    for (U j = 0; j < 4; j++) {{
      U x = 0xffffffffu - j, v = {name}(x, 19);
      if (v != ref_{name}(x, 19)) {{ bad++; printf("MISMATCH {name} %u 19\\n", x); }}
      hash = 33u * hash + v; count++;
    }}
    printf("{name} %u %08x\\n", count, hash);
    total += count;
  }}''')
    c += ['  printf("total %u bad %u\\n", total, bad);', '  return bad != 0 || total == 0;', '}']
    (out / 'cfg.ssa').write_text('\n'.join(ssa) + '\n')
    (out / 'check.c').write_text('\n'.join(c) + '\n')
    (out / 'expect.txt').write_text(''.join(f'{name} {kind}\n'
                                            for name, kind, n in funcs))


main()
