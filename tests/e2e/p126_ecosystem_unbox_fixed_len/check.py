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
  `use_pair` keep the destructured tuple in private stack slots (`alloc4`/`alloc8`)
  and call nothing (no `pion_alloc*`, no `mix` / `wide` / `pair_scale`); `escape`
  still allocates a heap box; `use_named` inlines `named` with no heap tuple box
  while preserving `String` / `Array` allocation and `pion_rc_dec` cleanup;
  `use_drop_pair` inlines `drop_pair` without a box and releases its first string
  (`pion_rc_dec`) between the two `pion_int_to_str` calls (last-use early drop).
tuple (dev and release): `scaled` / `use_pair` inline their callee with the
  callee's top-level `scale` (3): `mul ..., 3` and no call of `add_scale` /
  `pair_scale`.
fixed (dev and release): every unsigned bounds check (`=w cugel IDX, LEN`) of
  `probe_fixed_*` compares against 4 and of `probe_imm_*` against 6; every
  `probe_dyn_*` check compares against a loaded length, and at least one such
  check exists in each `probe_dyn_*` function.
Every function named in REQUIRED must exist in every mode, so an empty or
truncated SSA file fails.
"""
import re
import sys


def fail(msg):
    print(f'FAIL: p126 {msg}', file=sys.stderr)
    sys.exit(1)


REQUIRED = {
    'variant': ['sum_bytes', 'through', 'opt_match', 'arg_early', 'show'],
    'tuple': ['project', 'second_only', 'loop_mix', 'use_wide', 'escape',
              'use_named', 'use_drop_pair', 'scaled', 'use_pair'],
    'fixed': ['probe_fixed_sum', 'probe_imm_sum', 'probe_fixed_alias_write',
              'probe_dyn_param', 'probe_dyn_local', 'probe_dyn_mut',
              'probe_dyn_array'],
}


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
        if not re.search(r'=l alloc(?:4|8) \d+$', fn, re.M):
            fail(f'{label}: {name} has no private stack tuple slot/buffer\n{fn}')
    fn_esc = need(fns, label, 'escape')
    if not any(c.startswith('$pion_alloc') for c in calls(fn_esc)):
        fail(f'{label}: escape lost its heap tuple box\n{fn_esc}')
    fn_named = need(fns, label, 'use_named')
    cs_named = calls(fn_named)
    if any(c.startswith('$pion_alloc') or c == '$pion_fn_named' for c in cs_named):
        fail(f'{label}: use_named should unbox the destructured tuple without calling named/pion_alloc: {sorted(set(cs_named))}\n{fn_named}')
    if cs_named.count('$pion_rc_dec') < 2:
        fail(f'{label}: use_named lost RC release for String/Array elements: {cs_named}\n{fn_named}')
    fn = need(fns, label, 'use_drop_pair')
    cs = calls(fn)
    if any(c.startswith('$pion_alloc') or c == '$pion_fn_drop_pair' for c in cs):
        fail(f'{label}: use_drop_pair calls {sorted(set(cs))}\n{fn}')
    seq = [c for c in cs if c in ('$pion_int_to_str', '$pion_rc_dec')]
    if seq[:3] != ['$pion_int_to_str', '$pion_rc_dec', '$pion_int_to_str']:
        fail(f'{label}: use_drop_pair does not release the first string before building the second: {seq}\n{fn}')


def check_fixed(fns, label):
    for name in REQUIRED['fixed']:
        fn = need(fns, label, name)
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
    if program not in REQUIRED or mode not in ('dev', 'release'):
        fail(f'unknown program / mode {program} {mode}')
    fns = functions(open(path).read())
    for name in REQUIRED[program]:
        need(fns, label, name)
    release = mode == 'release'
    if program == 'variant':
        check_variant(fns, label, release)
    elif program == 'tuple':
        check_tuple(fns, label, release)
    else:
        check_fixed(fns, label)
    print(f'p126 {label}: SSA structure ok')


main()
