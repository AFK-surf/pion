#!/usr/bin/env python3
"""P122 QBE inputs for main.c replicatedispatch (arm64_apple only).

Writes into argv[1]:
  dispatch.ssa   positive cases: an interpreter-shaped loop whose four arms
                 (default, duplicate entries) jump back to the bounds guard
                 of a private jump table, with the table on the true side
                 (`guarded`) and on the false side (`guarded_rev`) of the
                 guard; every iteration stores to a trace slot.
                 `dual_bigfirst` / `dual_bigsecond`: both guard sides are
                 tables, the 33-entry one first or second; `cap31`: 31 arms
                 reach the guard (the 24-copy limit); `reshare`: a rewritten
                 predecessor shares the uncopied side, which later edges into
                 it must not copy. Then the
                 negative controls `c_*`: the same shape with exactly one
                 condition of replicatedispatch broken per function.
  expect.txt     `<function> <jump tables> <indirect branches on arm64_apple>`
                 per function (every other target keeps one branch per table).
  expect_<m>.txt the same for the QBE mutant <m> of mk_mutants.py.
The C driver (check.c) runs every function against a C reference.
"""
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

ARMS = '''@a
 %acc =w add %acc, %op
 storew %acc, %output
 jmp @check
@b
 %acc =w mul %acc, 17
 storew %acc, %output
 jmp @check
@c
 %acc =w xor %acc, 123
 storew %acc, %output
 jmp @check
@fallback
 %acc =w sub %acc, %op
 storew %acc, %output
 jmp @check
'''


def loop(name, guard='', table='', tbl='@a, @b, @a, @c', arms=ARMS, rev=False):
    """One guarded dispatch loop; `guard` / `table` are extra instructions
    placed in the guard and table blocks (they never change the result)."""
    if rev:
        test = ' %stop =w csgew %i, %n\n jnz %stop, @exit, @dispatch\n'
    else:
        test = ' %test =w csltw %i, %n\n jnz %test, @dispatch, @exit\n'
    return f'''export function w ${name}(l %src, l %trace, w %n, w %acc) {{
@start
 %i =w copy 0
 jmp @check
@check
{guard}{test}@dispatch
 %ix =l extsw %i
 %off =l mul %ix, 4
 %address =l add %src, %off
 %output =l add %trace, %off
 %op =w loadw %address
{table} %i =w add %i, 1
 jtbl %op, @fallback, {tbl}
{arms}@exit
 ret %acc
}}
'''


expect = []
pos = []
for name, rev in (('guarded', False), ('guarded_rev', True)):
    pos.append(loop(name, rev=rev))
    # The entry edge keeps the original guard and table; each of the four
    # arms gets its own copy.
    expect.append(f'{name} 1 5')


# Both guard sides are jump tables; only the 5-entry one qualifies (the other
# has 33 entries). The guard picks a table by the parity of i; both tables map
# selectors alike: in range, op 0..3 to @a @b @a @c and 4 to @exit; out of
# range (i >= n) the selector is 4. Every other value goes to @fallback.
# `dual_bigfirst` has the 33-entry table on the true side, `dual_bigsecond`
# on the false side: both must copy the 5-entry table onto the 4 arms.
def dual(name, big_first):
    def table(lbl, n_entries):
        ents = ['@a', '@b', '@a', '@c', '@exit'] + ['@fallback'] * (n_entries - 5)
        return f"""@{lbl}
 %k =w csltw %i, %n
 %j =w and %i, 31
 %ix =l extuw %j
 %off =l mul %ix, 4
 %address =l add %src, %off
 %output =l add %trace, %off
 %op =w loadw %address
 %km =w sub 1, %k
 %f =w mul %km, 4
 %g =w mul %op, %k
 %sel =w add %g, %f
 %i =w add %i, 1
 jtbl %sel, @fallback, {', '.join(ents)}
"""
    sides = '@big, @small' if big_first else '@small, @big'
    return f"""export function w ${name}(l %src, l %trace, w %n, w %acc) {{
@start
 %i =w copy 0
 jmp @check
@check
 %odd =w and %i, 1
 jnz %odd, {sides}
{table('big', 33)}{table('small', 5)}{ARMS.replace('%op', '%sel')}@exit
 ret %acc
}}
"""


pos.append(dual('dual_bigfirst', True))
pos.append(dual('dual_bigsecond', False))
# 33-entry table: 1 branch; 5-entry table: 1 + one copy per arm.
expect.append('dual_bigfirst 2 6')
expect.append('dual_bigsecond 2 6')

# Stale predecessor counts. @b -> @h -> @t1 / @t2 -> @a / @bb -> @b is a
# loop inside the @o loop; @y and @w enter it at @h from outside (so only @b
# qualifies for @h's tables), and @c / @fallback go back to @o, whose `route`
# table they copy. @b is rewritten first: it branches to a copy of @t1 and to
# @t2, which it now shares with @h. The arms @a / @bb then reach @b as a
# guard whose one side is @t2, still counted with one predecessor until
# fillcfg: they must not copy it.
def table(lbl, shift):
    return f"""@{lbl}
 %k =w csltw %i, %n
 %j =w and %i, 31
 %ix =l extuw %j
 %off =l mul %ix, 4
 %address =l add %src, %off
 %output =l add %trace, %off
 %op =w loadw %address
 %x =w shr %op, {shift}
 %x =w and %x, 3
 %km =w sub 1, %k
 %f =w mul %km, 3
 %g =w mul %x, %k
 %sel =w add %g, %f
 %i =w add %i, 1
 jtbl %sel, @fallback, @a, @bb, @c
"""


pos.append(f"""export function w $reshare(l %src, l %trace, w %n, w %acc) {{
@start
 %i =w copy 0
 jmp @o
@o
 %go =w csltw %i, %n
 jnz %go, @route, @exit
@route
 %r =w urem %i, 3
 jtbl %r, @exit, @b, @y, @w
@b
 %acc =w xor %acc, 1
 jmp @h
@y
 %acc =w add %acc, 7
 jmp @h
@w
 %acc =w mul %acc, 5
 jmp @h
@h
 %odd =w and %i, 1
 jnz %odd, @t1, @t2
{table('t1', 0)}{table('t2', 1)}@a
 %acc =w add %acc, %sel
 storew %acc, %output
 jmp @b
@bb
 %acc =w mul %acc, 17
 storew %acc, %output
 jmp @b
@c
 %acc =w xor %acc, 123
 storew %acc, %output
 jmp @o
@fallback
 %acc =w sub %acc, %op
 storew %acc, %output
 jmp @o
@exit
 ret %acc
}}
""")
# route + its copies on @c / @fallback; @t1, @t2 + the copy on @b.
expect.append('reshare 3 6')

# 31 arms jump back to the guard: the 24-copy limit (MaxSites) leaves
# 1 + 24 sites.
arms = ''.join(f"""@a{j}
 %acc =w mul %acc, {2 * j + 3}
 %acc =w add %acc, {j}
 storew %acc, %output
 jmp @check
""" for j in range(31))
pos.append(f"""export function w $cap31(l %src, l %trace, w %n, w %acc) {{
@start
 %i =w copy 0
 jmp @check
@check
 %test =w csltw %i, %n
 jnz %test, @dispatch, @exit
@dispatch
 %ix =l extsw %i
 %off =l mul %ix, 4
 %address =l add %src, %off
 %output =l add %trace, %off
 %op =w loadw %address
 %sel =w and %op, 31
 %i =w add %i, 1
 jtbl %sel, @fallback, {', '.join(f'@a{j}' for j in range(31))}
{arms}@fallback
 %acc =w sub %acc, %op
 storew %acc, %output
 jmp @check
@exit
 ret %acc
}}
""")
expect.append('cap31 1 25')

ctl = []
# 1. A call in the guard (shortdispatchblock(head)): p122_opaque returns 0.
ctl.append(loop('c_guardcall', guard=' %z =w call $p122_opaque(w %i)\n %acc =w add %acc, %z\n'))
# 2. A call in the table block (shortdispatchblock(table)).
ctl.append(loop('c_tablecall', table=' %z =w call $p122_opaque(w %op)\n %acc =w add %acc, %z\n'))
# 3. More than 16 instructions in the guard (b->nins > 16): 18 trace-slot
#    loads summed into a value that is subtracted again before the test.
g = ' %gp =l add %trace, 124\n %g0 =w loadw %gp\n'
for k in range(1, 18):
    g += f' %g{k} =w add %g{k - 1}, %g{k - 1}\n'
g += ' %gz =w sub %g17, %g17\n %acc =w add %acc, %gz\n'
ctl.append(loop('c_longguard', guard=g))
# 4. More than 16 instructions in the table block.
t = ''
for k in range(18):
    t += f' %t{k} =w {"xor" if k % 2 else "add"} %op, {k + 1}\n'
t += ' %tz =w sub %t17, %t17\n'
for k in range(17):
    t += f' %tz =w and %tz, %t{k}\n'
t += ' %acc =w add %acc, %tz\n'
ctl.append(loop('c_longtable', table=t))
# 5. A table of 33 entries (njtbl > 32): entries 4..32 all go to @fallback.
ctl.append(loop('c_bigtable', tbl='@a, @b, @a, @c' + ', @fallback' * 29))
# 6. The table block has a second predecessor (table->npred > 1): arm @b
#    skips the guard when i < n is already known (i is even and i < n).
arms6 = ARMS.replace(''' %acc =w mul %acc, 17
 storew %acc, %output
 jmp @check''', ''' %acc =w mul %acc, 17
 storew %acc, %output
 %more =w csltw %i, %n
 jnz %more, @dispatch, @exit''')
ctl.append(loop('c_sharedtable', arms=arms6))
# 7. Only two predecessors of the guard (head->npred < 3): arms @b, @c and
#    @fallback leave the loop.
arms7 = ARMS.replace(''' storew %acc, %output
 jmp @check
@c''', ''' storew %acc, %output
 ret %acc
@c''').replace(''' %acc =w xor %acc, 123
 storew %acc, %output
 jmp @check''', ''' %acc =w xor %acc, 123
 storew %acc, %output
 ret %acc''').replace(''' %acc =w sub %acc, %op
 storew %acc, %output
 jmp @check''', ''' %acc =w sub %acc, %op
 storew %acc, %output
 ret %acc''')
ctl.append(loop('c_twopreds', arms=arms7))
# 8. No loop (head->loop <= 1): three blocks join at a guarded table.
ctl.append('''export function w $c_noloop(l %src, l %trace, w %n, w %acc) {
@start
 %s =w loadw %src
 %sel =w and %s, 3
 jtbl %sel, @p0, @p1, @p2
@p0
 %acc =w add %acc, 1
 jmp @check
@p1
 %acc =w mul %acc, 3
 jmp @check
@p2
 %acc =w xor %acc, 5
 jmp @check
@check
 %test =w csltw 0, %n
 jnz %test, @dispatch, @exit
@dispatch
 %op =w loadw %src
 storew %acc, %trace
 jtbl %op, @fallback, @a, @b, @a, @c
@a
 %acc =w add %acc, %op
 ret %acc
@b
 %acc =w mul %acc, 17
 ret %acc
@c
 %acc =w xor %acc, 123
 ret %acc
@fallback
 %acc =w sub %acc, %op
 ret %acc
@exit
 ret %acc
}
''')
for c in ctl:
    name = c.split('$', 1)[1].split('(', 1)[0]
    # c_noloop has a second table (the entry selector), which is no guard.
    expect.append(f'{name} 2 2' if name == 'c_noloop' else f'{name} 1 1')

# Each control is a near miss: with its condition removed from main.c
# (mk_mutants.py), exactly the listed functions get dispatch copies and every
# other function keeps its count.
MUTANTS = {
    'len': {'c_longguard': 5, 'c_longtable': 5},
    'call': {'c_guardcall': 5, 'c_tablecall': 5},
    'big': {'c_bigtable': 5},
    'shared': {'c_sharedtable': 4},
    'npred': {'c_twopreds': 2},
    'loop': {'c_noloop': 4},
    'sites23': {'cap31': 24},
    'sites25': {'cap31': 26},
}
for mut, sites in MUTANTS.items():
    with open(os.path.join(out, f'expect_{mut}.txt'), 'w') as f:
        for e in expect:
            name, tables, n = e.split()
            f.write(f'{name} {tables} {sites.get(name, n)}\n')

with open(os.path.join(out, 'dispatch.ssa'), 'w') as f:
    f.write('\n'.join(pos + ctl))
with open(os.path.join(out, 'expect.txt'), 'w') as f:
    f.write('\n'.join(expect) + '\n')
