"""Check the `qbe -d SR` dump of the p114 fixture (gen_cfg.py).

usage: python3 -E check_dump.py DUMP EXPECT LABEL

For every function, the table block T (the block ending in `jtbl`) and its
source blocks (T, and the unique non-table predecessor of T) are taken from
the spill dump ("After spilling"); their shadow stores `store %tmp, S<n>` are
the candidates. In the register allocation dump:

  * a candidate whose store left its source block is moved; their number
    equals both the `nop`s added to the source blocks and the `sunk homes`
    statistic;
  * a moved home's store leads between 1 and half of the table entries
    (duplicates counted per entry) and each of these targets has T as its
    only predecessor, so at least half of the entries (hot arms) run without
    it.

Every candidate that one of these unsafe situations reaches must be kept,
and every target must witness each situation at least once:

  majority  the home is read along the arms of more than half the entries;
  late      the home is read in its source block after its shadow store, in
            T after a predecessor's store, or is the table selector;
  multi     the home is read by a target that has another predecessor.

Function kinds (EXPECT, `name kind` lines): sink / pred (homes moved from T /
from its predecessor), major / head / multi (built for the three unsafe
situations; head must move nothing) and flat (no loop: nothing moved).
"""
import re
import sys


def need(ok, msg):
    if not ok:
        raise SystemExit(f'FAIL: p114 {LABEL} ' + msg)


def parse_fn(text):
    """-> blocks[name] = (body, successors, terminator line)."""
    order, raw, cur = [], {}, None
    for ln in text.split('\n'):
        if ln.startswith('@'):
            cur = ln[1:].strip()
            order.append(cur)
            raw[cur] = []
        elif ln.startswith('\t') and cur is not None:
            raw[cur].append(ln.strip())
    out = {}
    for k, name in enumerate(order):
        ins = raw[name]
        last = ins[-1] if ins else ''
        word = last.split(' ')[0]
        if word.startswith('j'):
            out[name] = (ins[:-1], re.findall(r'@(\w+)', last), last)
        elif word.startswith('ret') or word == 'hlt':
            out[name] = (ins[:-1], [], last)
        else:
            out[name] = (ins, [order[k + 1]] if k + 1 < len(order) else [], '')
    return out


def preds_of(blocks):
    pr = {b: set() for b in blocks}
    for b, (_, succ, _) in blocks.items():
        for s in succ:
            pr[s].add(b)
    return pr


def table_of(blocks):
    tabs = [b for b, (_, _, last) in blocks.items() if last.startswith('jtbl ')]
    need(len(tabs) == 1, f'want one jtbl block, got {tabs}')
    return tabs[0], re.findall(r'@(\w+)', blocks[tabs[0]][2])


STORE = re.compile(r'^store[wl] (\S+), (S\d+)$')


def store_slot(ins):
    mm = STORE.match(ins)
    return mm.group(2) if mm else None


def slots_in(text):
    return set(re.findall(r'\bS\d+\b', text))


def reads_of(ins):
    """Homes an instruction reads (a store's or copy's destination is not)."""
    mm = STORE.match(ins)
    if mm:
        return slots_in(mm.group(1))
    return slots_in(ins.split('=', 1)[1] if '=' in ins else ins)


DUMP, EXPECT, LABEL = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(DUMP).read()
expect = dict(ln.split() for ln in open(EXPECT).read().split('\n') if ln.strip())
sections = re.split(r'\*\*\*\* Function (\w+) \*\*\*\*', text)
fns = dict(zip(sections[1::2], sections[2::2]))
need(sorted(fns) == sorted(expect), f'functions {sorted(fns)} != {sorted(expect)}')
witness = {'majority': 0, 'late': 0, 'multi': 0}
total_moved = wide = 0
for name, kind in expect.items():
    sec = fns[name]
    need('> After spilling:' in sec and '> After register allocation:' in sec, f'{name}: missing dumps')
    spill = sec.split('> After spilling:')[1].split('> Register allocation statistics:')[0]
    rega = sec.split('> After register allocation:')[1]
    m = re.search(r'sunk homes: (\d+)', sec)
    need(m is not None, f'{name}: no `sunk homes` statistic')
    sunk = int(m.group(1))
    sb, rb = parse_fn(spill), parse_fn(rega)
    st, _ = table_of(sb)
    spred = preds_of(sb)
    srcs = [st]
    if len(spred[st]) == 1:
        (p,) = spred[st]
        if p != st and not sb[p][2].startswith('jtbl '):
            srcs.append(p)
    cand = {}
    for src in srcs:
        for ins in sb[src][0]:
            mm = STORE.match(ins)
            if mm and mm.group(1).startswith('%'):
                cand[mm.group(2)] = src
    rt, entries = table_of(rb)
    need(rt == st, f'{name}: table block {rt} != {st}')
    rpred = preds_of(rb)
    edges = len(entries)
    moved = {s: src for s, src in cand.items() if not any(store_slot(i) == s for i in rb[src][0])}
    nops = sum(sum(1 for i in rb[src][0] if i == 'nop') - sum(1 for i in sb[src][0] if i == 'nop')
               for src in srcs)
    need(len(moved) == sunk == nops,
         f'{name}: moved {sorted(moved)}, `sunk homes: {sunk}`, {nops} new nops in {srcs}')

    def lead(b):
        out = set()
        for i in rb[b][0]:
            s = store_slot(i)
            if s is None:
                break
            out.add(s)
        return out

    for slot in moved:
        hits = [e for e in entries if slot in lead(e)]
        need(1 <= len(hits) <= edges // 2, f'{name}: {slot} stored on {len(hits)} of {edges} entries')
        for e in set(hits):
            need(rpred[e] == {rt}, f'{name}: {slot} prepended to {e} with predecessors {sorted(rpred[e])}')

    def arm_reads(e):
        """Homes read along one entry: follow single successors that have no
        other predecessor (edge copy block, then the arm)."""
        seen, b, out = set(), e, set()
        while b not in seen:
            seen.add(b)
            body, succ, last = rb[b]
            for i in body:
                out |= reads_of(i)
            out |= slots_in(last)
            if len(succ) != 1 or rpred[succ[0]] != {b}:
                break
            b = succ[0]
        return out

    reads = [arm_reads(e) for e in entries]
    for slot, src in cand.items():
        why = []
        if sum(1 for r in reads if slot in r) > edges // 2:
            why.append('majority')
        body = rb[src][0]
        pos = [k for k, i in enumerate(body) if store_slot(i) == slot]
        if (pos and any(slot in reads_of(i) for i in body[pos[0] + 1:])) or slot in slots_in(rb[src][2]) \
                or (src != rt and any(slot in reads_of(i) for i in rb[rt][0])) or slot in slots_in(rb[rt][2]):
            why.append('late')
        if any(len(rpred[e]) > 1 and any(slot in reads_of(i) for i in rb[e][0]) for e in set(entries)):
            why.append('multi')
        for w in why:
            need(slot not in moved, f'{name}: {slot} moved although {w}')
            witness[w] += 1
    if kind in ('sink', 'pred'):
        # A wide target (AArch64) keeps the narrowest fixture in registers.
        need(len(moved) >= min(3, len(cand)), f'{name}: only {len(moved)} of {len(cand)} homes moved')
        if kind == 'pred':
            need(len(srcs) == 2 and all(src == srcs[1] for src in moved.values()),
                 f'{name}: homes not moved from the predecessor block: {moved} {srcs}')
        if len(moved) >= 3:
            wide += 1
    elif kind in ('head', 'flat'):
        need(sunk == 0, f'{name}: {sunk} homes moved')
    else:
        need(kind in ('major', 'multi'), f'{name}: unknown kind {kind}')
    total_moved += len(moved)
    print(f'p114 {LABEL} {name} ({kind}): {len(cand)} candidates, {len(moved)} moved, {edges} entries')
need(wide >= 4, f'only {wide} sink functions moved at least 3 homes')
need(all(witness.values()), f'unsafe situations not all exercised: {witness}')
print(f'p114 {LABEL} dump ok: {len(expect)} functions, {total_moved} homes moved, '
      f'kept: {witness["majority"]} majority / {witness["late"]} late / {witness["multi"]} multi-predecessor')
