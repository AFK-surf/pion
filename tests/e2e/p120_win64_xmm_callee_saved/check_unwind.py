"""Check COFF object and linked PE32+ unwind tables (.pdata / .xdata) against
the prologues emitted by `qbe --seh -t amd64_win`.

Modes:
  1. COFF object check:
       python3 -E check_unwind.py --coff WIN.s OBJ.obj
     Parses the COFF object directly (no objdump dependency):
       - Every framed function (`.seh_proc`) must have a `.text$<fn>` COMDAT
         leader (`IMAGE_COMDAT_SELECT_NODUPLICATES`) with COMDAT symbol `<fn>`,
         plus associative `.pdata` and `.xdata` sections
         (`IMAGE_COMDAT_SELECT_ASSOCIATIVE` linked to `.text$<fn>`).
       - `.pdata`'s three `IMAGE_REL_AMD64_ADDR32NB` relocations must reference
         `.text$<fn>` (or `<fn>`) at offset 0 (begin=0), offset 4 (end>0), and
         the matching `.xdata` section at offset 8.
       - The decoded `UNWIND_INFO` must match the prologue instructions of
         `WIN.s` in reverse order, with strictly decreasing code offsets inside
         `PrologSize`, `FrameOffset == 0`, and `FrameRegister == rbp` iff the
         prologue has `movq %rsp, %rbp`.
       - Unframed functions must have no `.pdata` / `.xdata`.

  2. Zero-unwind check (for default non-`--seh` objects):
       python3 -E check_unwind.py --no-unwind OBJ.obj
     Fails if the COFF object contains any `.pdata*` or `.xdata*` section.

  3. Final linked PE32+ `/OPT:REF` check:
       python3 -E check_unwind.py --pe-link PE.exe MAP.txt WIN.s \
           --live entry[,fn2,...] --dead unused[,fn3,...] [--expect-entries N]
     Verifies on the linked PE32+ image and LLD `/map:` output:
       - Every `--dead` symbol is absent from `MAP.txt`.
       - Every `--live` symbol (supports `name:count` for distinct statics) is
         present in `MAP.txt` with the exact multiplicity.
       - PE32+ `DataDirectory[3]` (Exception Directory) size is `12 * N`.
       - Each `RUNTIME_FUNCTION` entry maps to a live symbol's RVA with
         `EndAddress > BeginAddress`, and its `UNWIND_INFO` decodes to the
         exact prologue of that function in `WIN.s`.
"""
import re
import struct
import sys

GPRS = [
    'rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
    'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15',
]

IMAGE_REL_AMD64_ADDR32NB = 3
IMAGE_COMDAT_SELECT_NODUPLICATES = 1
IMAGE_COMDAT_SELECT_ASSOCIATIVE = 5
IMAGE_SCN_LNK_COMDAT = 0x00001000
IMAGE_SCN_LNK_NRELOC_OVFL = 0x01000000


def fail(msg):
    print(f'FAIL: check_unwind {msg}')
    sys.exit(1)


def expected_prologues(paths):
    """Derive expected unwind codes from the actual prologue instructions in
    WIN.s (not from `.seh_*` directives, so a lying directive is caught)."""
    exp = {}
    for path in paths:
        cur = None
        for raw in open(path):
            line = raw.strip()
            m = re.match(r'^([A-Za-z_][\w.]*):$', line)
            if m and not line.startswith('L') and cur is None:
                cur, codes, inpro, framed = m.group(1), [], True, False
                continue
            if cur is None:
                continue
            if line.startswith('/* end'):
                if framed:
                    exp.setdefault(cur, []).append(codes)
                cur = None
                continue
            if not inpro:
                continue
            if line == f'.seh_proc {cur}':
                framed = True
            elif line == '.seh_endprologue':
                inpro = False
            elif (m := re.match(r'^pushq %(\w+)$', line)):
                codes.append(f'push {m.group(1)}')
            elif (m := re.match(r'^subq \$(\d+), %rsp$', line)):
                n = int(m.group(1))
                kind = 'small' if n <= 128 else 'large'
                codes.append(f'alloc {kind} area: rsp = rsp - 0x{n:x}')
            elif line == 'movq %rsp, %rbp':
                codes.append('FPReg: rbp = rsp + 0x0')
            elif (m := re.match(r'^movups %xmm(\d+), (\d+)\(%rsp\)$', line)):
                codes.append(f'save xmm{m.group(1)} at rsp + 0x{int(m.group(2)):x}')
    return exp


def decode_unwind_info(buf, off, fn):
    if off + 4 > len(buf):
        fail(f'{fn}: truncated UNWIND_INFO at 0x{off:x}')
    ver_flg, prolog, ncodes, frame = struct.unpack_from('<BBBB', buf, off)
    ver = ver_flg & 0x7
    if ver not in (1, 2):
        fail(f'{fn}: unexpected UNWIND_INFO version {ver}')
    freg_id = frame & 0xf
    foff = (frame >> 4) * 16
    freg = 'none' if freg_id == 0 else GPRS[freg_id]
    if off + 4 + ncodes * 2 > len(buf):
        fail(f'{fn}: truncated UNWIND_CODE array')
    codes, pcs = [], []
    j = 0
    while j < ncodes:
        co, info = struct.unpack_from('<BB', buf, off + 4 + j * 2)
        op, opinfo = info & 0xf, info >> 4
        pcs.append(co)
        if op == 0:  # UWOP_PUSH_NONVOL
            codes.append(f'push {GPRS[opinfo]}')
            j += 1
        elif op == 1:  # UWOP_ALLOC_LARGE
            if opinfo == 0:
                if j + 1 >= ncodes:
                    fail(f'{fn}: truncated UWOP_ALLOC_LARGE(0)')
                n = struct.unpack_from('<H', buf, off + 4 + (j + 1) * 2)[0] * 8
                j += 2
            elif opinfo == 1:
                if j + 2 >= ncodes:
                    fail(f'{fn}: truncated UWOP_ALLOC_LARGE(1)')
                n = struct.unpack_from('<I', buf, off + 4 + (j + 1) * 2)[0]
                j += 3
            else:
                fail(f'{fn}: bad UWOP_ALLOC_LARGE opinfo {opinfo}')
            codes.append(f'alloc large area: rsp = rsp - 0x{n:x}')
        elif op == 2:  # UWOP_ALLOC_SMALL
            n = (opinfo + 1) * 8
            codes.append(f'alloc small area: rsp = rsp - 0x{n:x}')
            j += 1
        elif op == 3:  # UWOP_SET_FPREG
            codes.append(f'FPReg: {freg} = rsp + 0x{foff:x}')
            j += 1
        elif op == 8:  # UWOP_SAVE_XMM128
            if j + 1 >= ncodes:
                fail(f'{fn}: truncated UWOP_SAVE_XMM128')
            so = struct.unpack_from('<H', buf, off + 4 + (j + 1) * 2)[0] * 16
            codes.append(f'save xmm{opinfo} at rsp + 0x{so:x}')
            j += 2
        elif op == 9:  # UWOP_SAVE_XMM128_FAR
            if j + 2 >= ncodes:
                fail(f'{fn}: truncated UWOP_SAVE_XMM128_FAR')
            so = struct.unpack_from('<I', buf, off + 4 + (j + 1) * 2)[0]
            codes.append(f'save xmm{opinfo} at rsp + 0x{so:x}')
            j += 3
        else:
            fail(f'{fn}: unsupported unwind op {op} (info={opinfo})')
    return {'size': prolog, 'foff': foff, 'freg': freg, 'codes': codes, 'pc': pcs}


def verify_unwind_matches(fn, decoded, exp_codes):
    want = list(reversed(exp_codes))
    if decoded['codes'] != want:
        fail(f'{fn}: unwind codes {decoded["codes"]} != {want}')
    rbp = any(c.startswith('FPReg') for c in exp_codes)
    if decoded['freg'] != ('rbp' if rbp else 'none') or decoded['foff'] != 0:
        fail(f'{fn}: frame reg {decoded["freg"]} offset {decoded["foff"]}')
    pcs = decoded['pc']
    if any(a <= b for a, b in zip(pcs, pcs[1:])) or (pcs and pcs[0] > decoded['size']):
        fail(f'{fn}: code offsets {pcs} not strictly decreasing within prologue {decoded["size"]}')


def parse_coff(path):
    b = open(path, 'rb').read()
    mach, nsecs, _, symoff, nsyms, optsz, _ = struct.unpack_from('<HHIIIHH', b, 0)
    if mach != 0x8664:
        fail(f'{path}: COFF machine 0x{mach:x}, want 0x8664')
    strtab_off = symoff + 18 * nsyms

    def read_str(offset):
        end = b.index(b'\0', strtab_off + offset)
        return b[strtab_off + offset:end].decode('utf-8', errors='replace')

    def sec_name(raw8):
        if raw8.startswith(b'/'):
            return read_str(int(raw8[1:].rstrip(b'\0')))
        return raw8.rstrip(b'\0').decode('utf-8', errors='replace')

    secs = []
    sec_base = 20 + optsz
    for idx in range(nsecs):
        o = sec_base + idx * 40
        nm = sec_name(b[o:o + 8])
        vsz, vrva, rsz, rptr, relptr, _, nrel, _, chars = struct.unpack_from('<IIIIIIHHI', b, o + 8)
        rels = []
        if relptr:
            cnt = nrel
            r_start = relptr
            if (chars & IMAGE_SCN_LNK_NRELOC_OVFL) and nrel == 0xffff:
                cnt = struct.unpack_from('<I', b, relptr)[0] - 1
                r_start = relptr + 10
            for k in range(cnt):
                rva, symidx, rtype = struct.unpack_from('<IIH', b, r_start + k * 10)
                rels.append((rva, symidx, rtype))
        secs.append({
            'num': idx + 1, 'name': nm, 'rsz': rsz, 'rptr': rptr,
            'chars': chars, 'rels': rels, 'selection': None, 'assoc': None,
            'comdat_sym': None,
        })

    syms = {}
    i = 0
    while i < nsyms:
        o = symoff + i * 18
        raw8 = b[o:o + 8]
        z, soff = struct.unpack_from('<II', raw8, 0)
        nm = read_str(soff) if z == 0 else raw8.rstrip(b'\0').decode('utf-8', errors='replace')
        val, secnum, typ, sclass, naux = struct.unpack_from('<IhHBB', b, o + 8)
        syms[i] = {'name': nm, 'val': val, 'sec': secnum, 'sclass': sclass, 'naux': naux}
        if sclass == 3 and val == 0 and naux >= 1 and 1 <= secnum <= nsecs:
            sec = secs[secnum - 1]
            if nm == sec['name'] and sec['selection'] is None:
                _, _, _, _, num_lo, sel, _, num_hi = struct.unpack_from('<IHHIHBBH', b, o + 18)
                sec['selection'] = sel
                sec['assoc'] = num_lo | (num_hi << 16)
        elif 1 <= secnum <= nsecs and val == 0:
            sec = secs[secnum - 1]
            if sec['selection'] == IMAGE_COMDAT_SELECT_NODUPLICATES and sec['comdat_sym'] is None:
                sec['comdat_sym'] = nm
        i += 1 + naux
    return b, secs, syms


def check_no_unwind(obj_path):
    _, secs, _ = parse_coff(obj_path)
    bad = [s['name'] for s in secs if s['name'].startswith(('.pdata', '.xdata'))]
    if bad:
        fail(f'{obj_path}: unexpected unwind sections {bad}')


def check_coff(win_s, obj_path):
    exp_map = expected_prologues([win_s])
    exp = {k: v[0] for k, v in exp_map.items()}
    if not exp:
        fail('no .seh_proc function in the text')
    b, secs, syms = parse_coff(obj_path)
    sec_by_num = {s['num']: s for s in secs}

    text_by_fn = {}
    pdata_by_text = {}
    xdata_by_text = {}
    for s in secs:
        nm = s['name']
        if nm.startswith('.text$'):
            fn = nm[len('.text$'):]
            text_by_fn[fn] = s
        elif nm == '.pdata' or nm.startswith('.pdata$'):
            if not (s['chars'] & IMAGE_SCN_LNK_COMDAT) or s['selection'] != IMAGE_COMDAT_SELECT_ASSOCIATIVE:
                fail(f'{obj_path}: {nm} (sec {s["num"]}) is not IMAGE_COMDAT_SELECT_ASSOCIATIVE (sel={s["selection"]})')
            leader = sec_by_num.get(s['assoc'])
            if leader is None or not leader['name'].startswith('.text$'):
                fail(f'{obj_path}: {nm} (sec {s["num"]}) associates with non-text sec {s["assoc"]}')
            if leader['num'] in pdata_by_text:
                fail(f'{obj_path}: duplicate .pdata for {leader["name"]}')
            pdata_by_text[leader['num']] = s
        elif nm == '.xdata' or nm.startswith('.xdata$'):
            if not (s['chars'] & IMAGE_SCN_LNK_COMDAT) or s['selection'] != IMAGE_COMDAT_SELECT_ASSOCIATIVE:
                fail(f'{obj_path}: {nm} (sec {s["num"]}) is not IMAGE_COMDAT_SELECT_ASSOCIATIVE (sel={s["selection"]})')
            leader = sec_by_num.get(s['assoc'])
            if leader is None or not leader['name'].startswith('.text$'):
                fail(f'{obj_path}: {nm} (sec {s["num"]}) associates with non-text sec {s["assoc"]}')
            if leader['num'] in xdata_by_text:
                fail(f'{obj_path}: duplicate .xdata for {leader["name"]}')
            xdata_by_text[leader['num']] = s

    seen_text = set()
    for fn, codes in exp.items():
        ts = text_by_fn.get(fn)
        if ts is None:
            fail(f'{fn}: missing .text${fn} section in {obj_path}')
        if not (ts['chars'] & IMAGE_SCN_LNK_COMDAT) or ts['selection'] != IMAGE_COMDAT_SELECT_NODUPLICATES:
            fail(f'{fn}: .text${fn} is not COMDAT one_only (sel={ts["selection"]})')
        if ts['comdat_sym'] != fn:
            fail(f'{fn}: .text${fn} COMDAT key symbol is {ts["comdat_sym"]!r}, want {fn!r}')
        ps = pdata_by_text.get(ts['num'])
        xs = xdata_by_text.get(ts['num'])
        if ps is None or xs is None:
            fail(f'{fn}: missing associative .pdata/.xdata for .text${fn}')
        if ps['rsz'] != 12:
            fail(f'{fn}: .pdata size {ps["rsz"]}, want 12')
        beg, end, uadd = struct.unpack_from('<III', b, ps['rptr'])
        if beg != 0 or end == 0 or end > ts['rsz']:
            fail(f'{fn}: bad .pdata addends begin={beg} end={end} text_sz={ts["rsz"]}')
        rels_by_off = {rva: (symidx, rtype) for rva, symidx, rtype in ps['rels']}
        if set(rels_by_off) != {0, 4, 8}:
            fail(f'{fn}: .pdata relocs at {sorted(rels_by_off)}, want [0, 4, 8]')
        for off in (0, 4, 8):
            sidx, rtype = rels_by_off[off]
            if rtype != IMAGE_REL_AMD64_ADDR32NB:
                fail(f'{fn}: .pdata reloc@{off} type {rtype}, want ADDR32NB (3)')
            sym = syms.get(sidx)
            if sym is None:
                fail(f'{fn}: .pdata reloc@{off} unknown symbol {sidx}')
            want_sec = ts['num'] if off in (0, 4) else xs['num']
            if sym['sec'] != want_sec:
                fail(f'{fn}: .pdata reloc@{off} points to sec {sym["sec"]}, want {want_sec}')
        dec = decode_unwind_info(b, xs['rptr'] + uadd, fn)
        verify_unwind_matches(fn, dec, codes)
        seen_text.add(ts['num'])

    extra_p = [sec_by_num[n]['name'] for n in pdata_by_text if n not in seen_text]
    extra_x = [sec_by_num[n]['name'] for n in xdata_by_text if n not in seen_text]
    if extra_p or extra_x:
        fail(f'unwind data for unframed functions: pdata={extra_p} xdata={extra_x}')
    print(f'check_unwind: {len(exp)} functions, associative COMDAT .pdata/.xdata match prologues')


def parse_lld_map(map_path):
    base = None
    syms = {}  # name -> list of rvas
    for raw in open(map_path):
        line = raw.strip()
        m = re.match(r'^Preferred load address is ([0-9a-fA-F]+)$', line)
        if m:
            base = int(m.group(1), 16)
            continue
        m = re.match(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s+\S+', line)
        if m and base is not None:
            nm, va = m.group(1), int(m.group(2), 16)
            syms.setdefault(nm, []).append(va - base)
    if base is None:
        fail(f'{map_path}: missing Preferred load address')
    return syms


def check_pe_link(pe_path, map_path, win_s_paths, live_specs, dead_names, expect_entries):
    exp_map = expected_prologues(win_s_paths)
    map_syms = parse_lld_map(map_path)

    for d in dead_names:
        if d in map_syms:
            fail(f'dead symbol {d!r} survived /OPT:REF in {map_path}: {map_syms[d]}')

    live_rvas = {}  # rva -> fn name
    for spec in live_specs:
        if ':' in spec:
            nm, cnt_s = spec.split(':', 1)
            cnt = int(cnt_s)
        else:
            nm, cnt = spec, 1
        rvas = map_syms.get(nm, [])
        if len(rvas) != cnt:
            fail(f'live symbol {nm!r}: got {len(rvas)} entries in {map_path}, want {cnt}')
        for r in rvas:
            live_rvas[r] = nm

    b = open(pe_path, 'rb').read()
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    if b[pe:pe + 4] != b'PE\0\0':
        fail(f'{pe_path}: bad PE signature')
    nsecs = struct.unpack_from('<H', b, pe + 6)[0]
    optsz = struct.unpack_from('<H', b, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', b, opt)[0]
    if magic != 0x20b:
        fail(f'{pe_path}: not PE32+ (magic=0x{magic:x})')
    exc_rva, exc_sz = struct.unpack_from('<II', b, opt + 112 + 3 * 8)
    want_sz = 12 * expect_entries
    if exc_sz != want_sz:
        fail(f'{pe_path}: PE Exception Directory size = 0x{exc_sz:x} ({exc_sz} B), want 0x{want_sz:x} ({want_sz} B)')
    if expect_entries == 0:
        print(f'check_unwind PE: {pe_path} 0 unwind entries, {len(dead_names)} dead symbols GCd')
        return

    secs = []
    for i in range(nsecs):
        o = opt + optsz + i * 40
        nm = b[o:o + 8].rstrip(b'\0').decode('utf-8', errors='replace')
        vsz, vrva, rsz, rptr = struct.unpack_from('<IIII', b, o + 8)
        secs.append((nm, vrva, vsz, rptr, rsz))

    def rva2off(rva):
        for _, vrva, vsz, rptr, rsz in secs:
            if vrva <= rva < vrva + max(vsz, rsz):
                return rptr + (rva - vrva)
        fail(f'{pe_path}: RVA 0x{rva:x} outside all sections')

    poff = rva2off(exc_rva)
    matched_rvas = set()
    for i in range(expect_entries):
        beg, end, unw = struct.unpack_from('<III', b, poff + i * 12)
        if end <= beg:
            fail(f'{pe_path}: RUNTIME_FUNCTION[{i}] bad range [0x{beg:x}, 0x{end:x})')
        fn = live_rvas.get(beg)
        if fn is None:
            fail(f'{pe_path}: RUNTIME_FUNCTION[{i}] begin=0x{beg:x} matches no live symbol ({live_rvas})')
        if beg in matched_rvas:
            fail(f'{pe_path}: duplicate RUNTIME_FUNCTION for {fn}@0x{beg:x}')
        matched_rvas.add(beg)
        candidates = exp_map.get(fn)
        if not candidates:
            fail(f'{pe_path}: no expected prologue for {fn}')
        dec = decode_unwind_info(b, rva2off(unw), f'{fn}@0x{beg:x}')
        ok = False
        last_err = None
        for cand in candidates:
            want = list(reversed(cand))
            rbp = any(c.startswith('FPReg') for c in cand)
            pcs = dec['pc']
            if (dec['codes'] == want
                    and dec['freg'] == ('rbp' if rbp else 'none')
                    and dec['foff'] == 0
                    and not any(a <= b_ for a, b_ in zip(pcs, pcs[1:]))
                    and not (pcs and pcs[0] > dec['size'])):
                ok = True
                break
            last_err = f'{dec} vs {want}'
        if not ok:
            fail(f'{pe_path}: {fn}@0x{beg:x} unwind mismatch ({last_err})')
    print(f'check_unwind PE: {pe_path} exc_dir=0x{exc_sz:x} ({expect_entries} entries), {len(dead_names)} dead symbols GCd, all unwind records match')


def main():
    args = sys.argv[1:]
    if not args:
        fail('missing mode (--coff | --no-unwind | --pe-link)')
    mode = args[0]
    if mode == '--coff':
        if len(args) != 3:
            fail('usage: check_unwind.py --coff WIN.s OBJ.obj')
        check_coff(args[1], args[2])
    elif mode == '--no-unwind':
        if len(args) != 2:
            fail('usage: check_unwind.py --no-unwind OBJ.obj')
        check_no_unwind(args[1])
    elif mode == '--pe-link':
        if len(args) < 4:
            fail('usage: check_unwind.py --pe-link PE.exe MAP.txt [--asm WIN.s ...] --live ... --dead ... --expect-entries N')
        pe_path, map_path = args[1], args[2]
        win_s_paths, live, dead, expect_n = [], [], [], None
        i = 3
        if i < len(args) and not args[i].startswith('--'):
            win_s_paths.append(args[i])
            i += 1
        while i < len(args):
            if args[i] == '--asm':
                win_s_paths.append(args[i + 1])
                i += 2
            elif args[i] == '--live':
                live = [x for x in args[i + 1].split(',') if x]
                i += 2
            elif args[i] == '--dead':
                dead = [x for x in args[i + 1].split(',') if x]
                i += 2
            elif args[i] == '--expect-entries':
                expect_n = int(args[i + 1])
                i += 2
            else:
                fail(f'unknown arg {args[i]}')
        if expect_n is None:
            expect_n = sum(int(s.split(':', 1)[1]) if ':' in s else 1 for s in live)
        check_pe_link(pe_path, map_path, win_s_paths, live, dead, expect_n)
    else:
        fail(f'unknown mode {mode!r}')


main()
