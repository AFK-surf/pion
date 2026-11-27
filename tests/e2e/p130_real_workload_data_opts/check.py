"""P130 structure checks.

usage: python3 -E check.py ssa PROGRAM SSA GEN_DIR
       python3 -E check.py wasm PROGRAM WASM GEN_DIR

ssa: checks the QBE text SSA that `pionc build --emit-ssa` wrote for PROGRAM
  (strings, ints, records or sparse; GEN_DIR holds gen.py's output).
  strings: the whole Base64 literal is one quoted item `b "..."`; quote,
    backslash, `$` and multibyte UTF-8 bytes stay numeric (`b 34`, `b 92`,
    `b 36`, `b 240`); no quoted item contains a byte outside the plain
    alphabet.
  ints / sparse / sparsecap / collide / edges: make_array, make_fixed,
    make_imm, table, table_a, table_b and edge_big each copy a
    private word table (`call $pion_arr_copy`) and store no element; the
    tables hold -2147483648 and 2147483647 as `w` words with an
    `l N, l N, w 0, w 4` descriptor; dyn_array keeps its 1,100 element
    stores and copies no table (the in-order tick log is checked at run
    time). edges: edge_small (1,023 elements) keeps its stores. collide:
    the `extern "C"` exports `pion_i32_literal_0` / `pion_i32_literal_1_words`
    exist and no word table or descriptor uses either name (or its pair).
  records: entities and triples allocate their array (`$pion_arr_new`) and
    no row box (`$pion_alloc_uninit`); dyn_rows, reordered_rows and
    single_row keep row boxes.
wasm: parses the module strictly (header, section sizes, every data
  segment). Section 11 must hold several active memory-0 segments in
  ascending, non-overlapping order whose bytes neither start nor end with
  zero and contain no zero run of 16+ bytes (except the dense tail when the
  4,096 segment cap is reached; sparsecap must reach it), and the memory
  image they build must contain PROGRAM.table (the word table, zeros
  included) and the program's marker string.
Every check needs content: an empty or truncated file fails.
"""
import os
import re
import sys

PLAIN = set(b' +-./0123456789=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz')


def fail(msg):
    print('FAIL: p130 ' + msg, file=sys.stderr)
    sys.exit(1)


def functions(ssa):
    fns = {}
    for m in re.finditer(r'^(?:export )?function (?:\S+ )?\$(\S+?)\((.*?)^\}', ssa, re.M | re.S):
        fns[m.group(1)] = m.group(0)
    return fns


def fn_body(fns, name):
    keys = [k for k in fns if k == 'pion_fn_' + name or k.endswith('_fn_' + name)]
    if len(keys) != 1:
        fail('expected one function %s, found %r' % (name, keys))
    return fns[keys[0]]


def check_ssa(prog, path, gen):
    with open(path, encoding='utf-8') as f:
        ssa = f.read()
    if 'function' not in ssa:
        fail('%s: empty SSA' % path)
    fns = functions(ssa)
    for q in re.findall(r'b "([^"]*)"', ssa):
        bad = [c for c in q.encode() if c not in PLAIN]
        if bad or len(q) < 2:
            fail('quoted data item %r is not a plain run of 2+ bytes' % q[:40])
    if prog == 'strings':
        b64 = open(os.path.join(gen, 'strings.base64')).read()
        if len(b64) < 4000 or ('b "' + b64 + '"') not in ssa:
            fail('strings: the Base64 literal is not one quoted run')
        for n in (34, 92, 36, 240, 228):
            if ('b %d,' % n) not in ssa:
                fail('strings: byte %d is not kept numeric' % n)
        if 'b "row 0", b 58, b 32, b 34, b "quoted", b 34' not in ssa:
            fail('strings: mixed row is not split at its quotes')
        return
    tables = {'ints': ['make_array', 'make_fixed', 'make_imm'], 'sparse': ['table'],
              'sparsecap': ['table'], 'collide': ['table_a', 'table_b'], 'edges': ['edge_big']}
    if prog in tables:
        names = tables[prog]
        for name in names:
            body = fn_body(fns, name)
            if body.count('call $pion_arr_copy(') != 1 or 'i32_literal_' not in body:
                fail('%s: %s does not copy a word table' % (prog, name))
            if 'storew' in body:
                fail('%s: %s still stores elements' % (prog, name))
        words = re.findall(r'^(?:section "\.rodata" )?data \$(\S*i32_literal_\d+)_words = align 4 \{ (.*) \}$', ssa, re.M)
        descs = re.findall(r'^data \$(\S*i32_literal_\d+) = align 8 \{ l (\d+), l (\d+), w 0, w 4, l \$(\S+) \}$', ssa, re.M)
        if len(words) != len(names) or len(descs) != len(names):
            fail('%s: %d word tables / %d descriptors, want %d' % (prog, len(words), len(descs), len(names)))
        sizes = {}
        for sym, body in words:
            sizes[sym] = len(body.split(', '))
        for sym, n, cap, wsym in descs:
            if n != cap or wsym != sym + '_words' or sizes.get(sym) != int(n) or int(n) < 1024:
                fail('%s: descriptor %s does not match its table' % (prog, sym))
        if prog == 'ints':
            if not any('w -2147483648' in b and 'w 2147483647' in b for _, b in words):
                fail('ints: INT32_MIN / INT32_MAX words missing')
            dyn = fn_body(fns, 'dyn_array')
            if 'arr_copy' in dyn or 'i32_literal_' in dyn or dyn.count('storew ') < 1100:
                fail('ints: dyn_array does not keep element evaluation')
        if prog == 'edges':
            small = fn_body(fns, 'edge_small')
            if 'arr_copy' in small or 'i32_literal_' in small or small.count('storew ') < 1023:
                fail('edges: edge_small does not keep element stores')
        if prog == 'collide':
            for sym in ('pion_i32_literal_0', 'pion_i32_literal_1_words'):
                if not re.search(r'^export function w \$%s\(' % sym, ssa, re.M):
                    fail('collide: export %s missing' % sym)
            used = set(d[0] for d in descs) | set(w[0] + '_words' for w in words)
            if used & {'pion_i32_literal_0', 'pion_i32_literal_0_words',
                       'pion_i32_literal_1', 'pion_i32_literal_1_words'}:
                fail('collide: a word table took an exported C symbol: %r' % sorted(used))
        return
    if prog == 'records':
        for name in ('entities', 'triples'):
            body = fn_body(fns, name)
            if 'call $pion_arr_new(' not in body or 'pion_alloc_uninit' in body:
                fail('records: %s allocates row boxes' % name)
        for name in ('dyn_rows', 'reordered_rows', 'single_row'):
            if 'call $pion_alloc_uninit(' not in fn_body(fns, name):
                fail('records: %s lost its row boxes' % name)
        return
    fail('unknown program ' + prog)


def u32(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return r, i
        if s > 35:
            fail('bad LEB128')


def s32(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            if c & 0x40:
                r -= 1 << s
            return r, i
        if s > 35:
            fail('bad LEB128')


def check_wasm(prog, path, gen):
    b = open(path, 'rb').read()
    if b[:8] != b'\0asm\x01\0\0\0':
        fail('%s: not a Wasm module' % path)
    i = 8
    data = None
    while i < len(b):
        sid = b[i]
        n, i = u32(b, i + 1)
        if i + n > len(b):
            fail('section %d overruns the module' % sid)
        if sid == 11:
            if data is not None:
                fail('two data sections')
            data = b[i:i + n]
        i += n
    if data is None:
        fail('no data section')
    count, j = u32(data, 0)
    segs = []
    for _ in range(count):
        if data[j] != 0 or data[j + 1] != 0x41:
            fail('segment is not active in memory 0 with i32.const')
        off, j = s32(data, j + 2)
        if data[j] != 0x0B:
            fail('segment offset is not a constant expression')
        size, j = u32(data, j + 1)
        segs.append((off, data[j:j + size]))
        j += size
    if j != len(data):
        fail('data section has %d trailing bytes' % (len(data) - j))
    if prog == 'sparsecap' and len(segs) != 4096:
        fail('sparsecap: %d data segments, want the 4,096 segment cap' % len(segs))
    if len(segs) < 3 or len(segs) > 4096:
        fail('%d data segments, want a sparse split' % len(segs))
    end = 0
    for k, (off, seg) in enumerate(segs):
        # The last of 4,096 segments is the dense tail: it may hold zero runs.
        tail = len(segs) == 4096 and k == 4095
        if off < end or not seg:
            fail('segment %d overlaps or is empty' % k)
        if seg[0] == 0 or (seg[-1] == 0 and not tail):
            fail('segment %d keeps an edge zero' % k)
        if b'\0' * 16 in seg and not tail:
            fail('segment %d keeps a 16+ byte zero run' % k)
        if k > 0 and off - end < 16:
            fail('segment %d follows a gap of only %d bytes' % (k, off - end))
        end = off + len(seg)
    base = segs[0][0]
    image = bytearray(end - base)
    for off, seg in segs:
        image[off - base:off - base + len(seg)] = seg
    table = open(os.path.join(gen, prog + '.table'), 'rb').read()
    if len(table) < 8192 or bytes(image).find(table) < 0:
        fail('the memory image does not hold the %s word table' % prog)
    if bytes(image).find(prog.encode() + b'-marker ') < 0:
        fail('the memory image does not hold the marker string')
    print('p130 wasm ' + prog + ': %d active segments, %d of %d image bytes stored'
          % (len(segs), sum(len(s) for _, s in segs), len(image)))


if len(sys.argv) == 5 and sys.argv[1] == 'ssa':
    check_ssa(sys.argv[2], sys.argv[3], sys.argv[4])
elif len(sys.argv) == 5 and sys.argv[1] == 'wasm':
    check_wasm(sys.argv[2], sys.argv[3], sys.argv[4])
else:
    fail('usage: check.py ssa PROGRAM SSA GEN_DIR | wasm PROGRAM WASM GEN_DIR')
