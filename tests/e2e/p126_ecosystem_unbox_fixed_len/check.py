"""P126 structure check.

usage: python3 -E check.py PROGRAM MODE SSA

PROGRAM is variant, tuple or fixed; MODE is dev or release. Checks the QBE
text SSA that `pionc build --emit-ssa` wrote for the p126 program.

variant (release): the cross-file `Result` / `Option` callees are inlined into
  their immediate consumers through tag / payload slots. `sum_bytes`,
  `through` and `arg_early` call neither `ByteReader::read_byte` nor
  `get_value` and allocate only their own returned `Result` (one box per
  `ret`); `opt_match` calls nothing at all; `through` loads the callee's
  top-level `bias` (7), not the caller's parameter of the same name.
tuple (release): `project`, `second_only`, `loop_mix`, `use_wide` and
  `use_pair` keep the destructured tuple in a private `alloc8` stack buffer and
  call nothing (no `pion_alloc*`, no `mix` / `wide` / `pair_scale`); `escape`
  and `use_named` still allocate a heap box.
tuple (dev and release): `scaled` / `use_pair` inline their callee with the
  callee's top-level `scale` (3): `mul ..., 3` and no call of `add_scale` /
  `pair_scale`.
fixed (dev and release): every unsigned bounds check (`=w cugel IDX, LEN`) of
  `probe_fixed_*` compares against 4 and of `probe_imm_*` against 6; every
  `probe_dyn_*` check compares against a loaded length, and at least one such
  check exists in each `probe_dyn_*` function.
"""
import re
import sys


def fail(msg):
    print(f'FAIL: p126 {msg}', file=sys.stderr)
    sys.exit(1)


def functions(text):
    out = {}
    for m in re.finditer(r'^(?:export )?function [^\n]*\$pion_fn_(\w+)\(', text, re.M):
        end = text.index('\n}\n', m.start())
        out[m.group(1)] = text[m.start():end]
    return out


def calls(fn):
    return re.findall(r'call (\$[\w.]+)\(', fn)


def need(fns, label, name):
    if name not in fns:
        fail(f'{label}: no function $pion_fn_{name} in the QBE text')
    return fns[name]


def check_variant(fns, label, release):
    if not release:
        return
    for name in ['sum_bytes', 'through', 'arg_early']:
        fn = need(fns, label, name)
        cs = calls(fn)
        bad = [c for c in cs if c in ('$pion_m_ByteReader__read_byte', '$pion_fn_get_value')]
        if bad:
            fail(f'{label}: {name} still calls {bad}\n{fn}')
        allocs = sum(1 for c in cs if c.startswith('$pion_alloc'))
        rets = len(re.findall(r'^\s*ret ', fn, re.M))
        if allocs > rets:
            fail(f'{label}: {name} allocates {allocs} times for {rets} returns\n{fn}')
    fn = need(fns, label, 'opt_match')
    if calls(fn):
        fail(f'{label}: opt_match calls {calls(fn)}\n{fn}')
    fn = need(fns, label, 'through')
    if 'storel 7, ' not in fn:
        fail(f'{label}: through does not use the callee top-level bias 7\n{fn}')


def check_tuple(fns, label, release):
    for name, callee in [('scaled', 'add_scale'), ('use_pair', 'pair_scale')]:
        fn = need(fns, label, name)
        if f'$pion_fn_{callee}' in calls(fn):
            fail(f'{label}: {name} calls {callee}\n{fn}')
        if not re.search(r'=w mul %\w+, 3$', fn, re.M):
            fail(f'{label}: {name} does not multiply by the callee top-level scale 3\n{fn}')
    if not release:
        return
    for name in ['project', 'second_only', 'loop_mix', 'use_wide', 'use_pair']:
        fn = need(fns, label, name)
        if calls(fn):
            fail(f'{label}: {name} calls {sorted(set(calls(fn)))}\n{fn}')
        if not re.search(r'=l alloc8 \d+$', fn, re.M):
            fail(f'{label}: {name} has no private tuple buffer\n{fn}')
    for name in ['escape', 'use_named']:
        fn = need(fns, label, name)
        if not any(c.startswith('$pion_alloc') for c in calls(fn)):
            fail(f'{label}: {name} lost its heap tuple box\n{fn}')


def check_fixed(fns, label):
    for name, fn in sorted(fns.items()):
        if not name.startswith('probe_'):
            continue
        lens = [c[1] for c in re.findall(r'=w cugel (\S+), (\S+)$', fn, re.M)]
        if name.startswith('probe_dyn_'):
            if not lens or any(not x.startswith('%') for x in lens):
                fail(f'{label}: {name} bounds checks {lens}, want only loaded lengths\n{fn}')
        else:
            want = '4' if name.startswith('probe_fixed_') else '6'
            if not lens or any(x != want for x in lens):
                fail(f'{label}: {name} bounds checks {lens}, want only {want}\n{fn}')
        print(f'p126 {label}: {name} bounds checks against {lens}')


def main():
    program, mode, path = sys.argv[1:4]
    label = f'{program} {mode}'
    fns = functions(open(path).read())
    release = mode == 'release'
    if program == 'variant':
        check_variant(fns, label, release)
    elif program == 'tuple':
        check_tuple(fns, label, release)
    elif program == 'fixed':
        check_fixed(fns, label)
    else:
        fail(f'unknown program {program}')
    print(f'p126 {label}: SSA structure ok')


main()
