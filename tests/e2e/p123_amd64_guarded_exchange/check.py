"""P123 structure checks.

usage:
  python3 -E check.py ssa  LABEL SSA FUNC hit|miss
      FUNC's QBE text has (hit) or lacks (miss) the guarded exchange. A hit
      also needs: a phi-carried left / right pointer pair stepping by +4 / -4,
      no `extsw` and no `pion_panic_oob` between `@exchange_` and
      `@exchange_done_`, the bound stored back in `@exchange_done_`, and a
      checked slow loop that still calls `pion_panic_oob`.
  python3 -E check.py asm  LABEL ASM FUNC N
      FUNC's amd64_sysv assembly has exactly N self-looping blocks of the
      exchange form: 8 instructions, two 32-bit loads, two 32-bit stores,
      +4 / -4 pointer updates, a 64-bit compare and the back branch.
"""
import re
import sys


def fail(msg):
    print(f'FAIL: p123 {msg}', file=sys.stderr)
    sys.exit(1)


def ssa_function(text, func):
    m = re.search(r'^(?:export )?function [^\n]*\$' + re.escape(func) + r'\(', text, re.M)
    if not m:
        fail(f'no function ${func} in the QBE text')
    end = text.index('\n}\n', m.start())
    return text[m.start():end]


def blocks(fn):
    """label -> list of instruction lines (QBE text)."""
    out = {}
    cur = None
    for line in fn.split('\n'):
        s = line.strip()
        if s.startswith('@'):
            cur = s
            out[cur] = []
        elif cur is not None and s:
            out[cur].append(s)
    return out


def check_ssa(label, path, func, want):
    fn = ssa_function(open(path).read(), func)
    bl = blocks(fn)
    loops = [b for b in bl if re.fullmatch(r'@exchange_\d+', b)]
    dones = [b for b in bl if re.fullmatch(r'@exchange_done_\d+', b)]
    if want == 'miss':
        if loops or dones:
            fail(f'{label}: ${func} has a guarded exchange ({loops + dones})')
        print(f'p123 {label}: ${func} keeps the indexed loop')
        return
    if len(loops) != 1 or len(dones) != 1:
        fail(f'{label}: ${func} has {len(loops)} exchange / {len(dones)} done blocks, want 1 / 1')
    hot = bl[loops[0]]
    done = bl[dones[0]]
    phis = [l for l in hot if ' =l phi ' in l]
    if len(phis) != 2:
        fail(f'{label}: exchange block has {len(phis)} pointer phis: {hot}')
    left, right = (p.split(' =l phi ')[0] for p in phis)
    if not any(re.fullmatch(r'%\S+ =l add ' + re.escape(left) + r', 4', l) for l in hot):
        fail(f'{label}: left pointer {left} does not advance by 4')
    if not any(re.fullmatch(r'%\S+ =l sub ' + re.escape(right) + r', 4', l) for l in hot):
        fail(f'{label}: right pointer {right} does not retreat by 4')
    bad = [l for l in hot if 'extsw' in l or 'pion_panic_oob' in l or l.startswith('call ')]
    if bad:
        fail(f'{label}: exchange block keeps {bad}')
    loads = [l for l in hot if re.search(r'=w load(sw|uw|w) ', l)]
    stores = [l for l in hot if l.startswith('storew ')]
    if len(loads) != 2 or len(stores) != 2:
        fail(f'{label}: exchange block has {len(loads)} loads / {len(stores)} stores: {hot}')
    if not hot[-1].startswith('jnz ') or loops[0] + ',' not in hot[-1]:
        fail(f'{label}: exchange block does not branch back to itself: {hot[-1]}')
    if not any(l.startswith('storew ') for l in done) or not done[-1].startswith('jmp @wh_e_'):
        fail(f'{label}: done block does not store the bound and leave the loop: {done}')
    slow = [b for b in bl if b.startswith('@wh_slow_') or b.startswith('@wh_sc_')]
    if not slow or 'pion_panic_oob' not in fn:
        fail(f'{label}: ${func} lost its checked slow loop')
    print(f'p123 {label}: ${func} exchange {loops[0]} '
          f'({len(hot)} QBE instructions, no extsw / OOB call, slow loop checked)')


# 32-bit general registers: %eax..%edi, %esi, %edi, %r8d..%r15d.
REG32 = r'%(?:e\w\w|r\d+d)'
LOAD = re.compile(r'movl -?\d*\(%r\w+\), ' + REG32)
STORE = re.compile(r'movl ' + REG32 + r', -?\d*\(%r\w+\)')


def check_asm(label, path, func, want):
    text = open(path).read()
    m = re.search(r'^' + re.escape(func) + r':\n', text, re.M)
    if not m:
        fail(f'{label}: no {func} in the assembly')
    end = text.find('/* end function', m.end())
    lines = text[m.end():end if end >= 0 else len(text)].split('\n')
    bl = {}
    order = []
    cur = None
    for raw in lines:
        s = raw.strip()
        if not s or s.startswith('.') and not s.endswith(':'):
            continue
        if s.endswith(':'):
            cur = s[:-1]
            bl[cur] = []
            order.append(cur)
        elif cur is not None:
            bl[cur].append(s)
    found = []
    for name in order:
        ins = bl[name]
        if not ins or not re.fullmatch(r'j\w+ ' + re.escape(name), ins[-1]):
            continue
        if len(ins) != 8:
            continue
        loads = sum(1 for i in ins if LOAD.fullmatch(i))
        stores = sum(1 for i in ins if STORE.fullmatch(i))
        adds = sum(1 for i in ins if re.fullmatch(r'addq \$4, %r\w+', i))
        subs = sum(1 for i in ins if re.fullmatch(r'subq \$4, %r\w+', i))
        cmps = sum(1 for i in ins if re.fullmatch(r'cmpq %r\w+, %r\w+', i))
        if (loads, stores, adds, subs, cmps) == (2, 2, 1, 1, 1):
            found.append((name, ins))
    if len(found) != want:
        dump = '\n'.join(f'{n}: {bl[n]}' for n in order)
        fail(f'{label}: {func} has {len(found)} 8-instruction exchange loops, want {want}\n{dump}')
    for name, ins in found:
        print(f'p123 {label}: {func} {name}: ' + ' ; '.join(ins))
    if want == 0:
        print(f'p123 {label}: {func} has no 8-instruction exchange loop')


def main():
    mode = sys.argv[1]
    if mode == 'ssa':
        check_ssa(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif mode == 'asm':
        check_asm(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        fail(f'unknown mode {mode}')


main()
