#!/bin/sh
# P117: QBE counted-loop expansion (vendor/qbe/main.c `trips` / `expandloops`,
# run after GCM; Lean: tests/lean/proofs/QbeCountedLoopUnroll.lean).
# A single-block loop whose only phi is an integer induction with a constant
# start, a constant add/sub stride and an exit test against a constant
# (optionally through extsw/extuw) is evaluated at compile time; 1..8 trips of
# a body of loads, stores, extensions, comparisons, copies, add/sub/shl/mul
# (at most 96 expanded instructions per loop, 192 per function) become
# straight-line copies. `-d G` reports `Expanded counted loop @blk: N trips`.
# Verifies:
#   1. loops.ssa: the exact expansions (block, trips) of every function on
#      amd64_sysv, amd64_apple, arm64, arm64_apple and rv64: positive /
#      negative stride, true / false back edge, 32-bit wrap, signed bound
#      crossing, unsigned bound, extsw / extuw tests, 1 and 8 trips, a 64-bit
#      induction, aliasing loads and stores, three loops in one function (two
#      expanded, the 9-trip one kept), a nested loop expanded in the second
#      round, five 8-trip loops in one function of which only four fit the
#      192-instruction budget shared by both rounds; none for 9 trips, a
#      call, a division, a variable start or a second phi.
#   2. Host differential: `qbe` + `cc -c` (no assembler warning) and, on
#      x86-64 ELF / AArch64 Mach-O, `qbe --obj`, linked with driver.c and the
#      independent C oracle.c: 20 functions x 40 memory layouts (separate,
#      identical, shifted dst/src) compare the return value and the whole
#      buffer, `total 800 bad 0`, identical on both routes.
#   3. Linux x86-64: the executable sections of `--obj` equal those of the
#      assembled text byte for byte (relocated fields compared as relocations),
#      or as canonical instruction streams where the pre-existing --obj-only
#      differences apply (loop-header NOP padding spelling, elf.c's flags-dead
#      mov+add -> lea rewrite, fused only where a later instruction rewrites
#      all flags first, with self-checked negative cases); the 13 fully
#      expanded functions have no backward branch, the others exactly one.
#   4. benchmarks/pion/fannkuchredux.pion dev and --release print the C
#      result (`73196 38` for n = 10) and the release SSA expands loops.
#   5. An ASan + UBSan QBE (when the compiler can build one) replays loops.ssa
#      and the fannkuchredux SSA on four targets (text and, where supported,
#      --obj) with halt_on_error, with the same expansions and the same host
#      output as the regular QBE.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p117_qbe_counted_loop_unroll"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

# expansions DUMP TARGET: the `-d G` expansions of loops.ssa against the table.
expansions() {
  python3 -E - "$1" "$2" <<'PYEOF'
import re, sys
WANT = {
    'up4': [('body', 4)], 'down4': [('body', 4)], 'falseback5': [('body', 5)],
    'wrap3': [('body', 3)], 'signcross2': [('body', 2)], 'udown4': [('body', 4)],
    'extsw5': [('body', 5)], 'extuw3': [('body', 3)], 'once1': [('body', 1)],
    'eight8': [('body', 8)], 'nine9': [], 'long7': [('body', 7)],
    'alias6': [('body', 6)], 'multi': [('l1', 4), ('l2', 5)],
    'nested': [('inner', 3), ('outer', 2)],
    'callbody': [], 'divbody': [], 'varstart': [], 'twophi': [],
    'overbudget': [('b0', 8), ('b1', 8), ('b2', 8), ('b3', 8)],
}
text = open(sys.argv[1]).read()
parts = re.split(r'\*\*\*\* Function (\S+) \*\*\*\*', text)
got = {}
for name, body in zip(parts[1::2], parts[2::2]):
    if name in got:
        raise SystemExit(f"FAIL: p117 {sys.argv[2]}: {name} dumped twice")
    got[name] = [(b, int(n)) for b, n in re.findall(r'> Expanded counted loop @(\S+): (\d+) trips, \d+ ins', body)]
if got != WANT:
    raise SystemExit(f"FAIL: p117 {sys.argv[2]} expansions\n got  {got}\n want {WANT}")
n = sum(1 for v in WANT.values() if v)
print(f"p117 {sys.argv[2]}: {n} functions expanded ({sum(len(v) for v in WANT.values())} loops), "
      f"{len(WANT) - n} kept, as expected")
PYEOF
}

# 1. Expansions on every target.
for T in amd64_sysv amd64_apple arm64 arm64_apple rv64; do
  "$QBE" -t "$T" -d G -o /dev/null "$DIR/loops.ssa" 2> "$TMP_DIR/g_$T.txt"
  expansions "$TMP_DIR/g_$T.txt" "$T"
done

# 2. Host differential through text assembly and --obj.
"$CC_BIN" -O0 -c "$DIR/oracle.c" -o "$TMP_DIR/oracle.o"
"$CC_BIN" -O1 -c "$DIR/driver.c" -o "$TMP_DIR/driver.o"
run_driver() { # $1 label, $2 object
  "$CC_BIN" "$TMP_DIR/driver.o" "$TMP_DIR/oracle.o" "$2" -o "$TMP_DIR/run_$1"
  # A failing run is reported by the exact-output check below (which prints
  # the MISMATCH lines), never by a silent `set -e` exit.
  "$TMP_DIR/run_$1" > "$TMP_DIR/$1.out" || echo "exit status $?" >> "$TMP_DIR/$1.out"
  python3 -E - "$TMP_DIR/$1.out" "$1" <<'PYEOF'
import sys
NAMES = ['up4', 'down4', 'falseback5', 'wrap3', 'signcross2', 'udown4', 'extsw5',
         'extuw3', 'once1', 'eight8', 'nine9', 'alias6', 'multi', 'nested',
         'callbody', 'divbody', 'varstart', 'twophi', 'overbudget', 'long7']
want = ''.join(f'{n} 40\n' for n in NAMES) + f'total {40 * len(NAMES)} bad 0\n'
got = open(sys.argv[1]).read()
if got != want or len(NAMES) != 20:
    raise SystemExit(f"FAIL: p117 {sys.argv[2]} driver output\n{got}")
print(f"p117 {sys.argv[2]}: 20 functions x 40 layouts = 800 calls equal the C oracle")
PYEOF
}
asm() { # $1 qbe, $2 input, $3 output object (fails on any assembler message)
  "$1" -o "$3.s" "$2"
  if ! "$CC_BIN" -c "$3.s" -o "$3" 2> "$3.log" || [ -s "$3.log" ]; then
    cat "$3.log" >&2
    echo "FAIL: p117 assembler diagnostics for $2" >&2
    exit 1
  fi
}
asm "$QBE" "$DIR/loops.ssa" "$TMP_DIR/text.o"
run_driver text "$TMP_DIR/text.o"
HOST="$(uname -s)/$(uname -m)"
OBJ=0
case "$HOST" in
  Linux/x86_64|Linux/amd64|Darwin/arm64|Darwin/aarch64) OBJ=1 ;;
esac
if [ "$OBJ" = 1 ]; then
  "$QBE" --obj -o "$TMP_DIR/direct.o" "$DIR/loops.ssa"
  run_driver obj "$TMP_DIR/direct.o"
  cmp "$TMP_DIR/text.out" "$TMP_DIR/obj.out"
else
  echo "NOTE: no direct object route on $HOST; text assembly only"
fi

# 3. Linux x86-64: --obj == as (byte for byte, or canonically), and no back edge left.
case "$HOST" in
  Linux/x86_64|Linux/amd64)
  objdump -d --no-show-raw-insn "$TMP_DIR/direct.o" > "$TMP_DIR/direct.dis"
  objdump -d --no-show-raw-insn "$TMP_DIR/text.o" > "$TMP_DIR/text.dis"
  python3 -E - "$TMP_DIR/direct.o" "$TMP_DIR/text.o" "$TMP_DIR/direct.dis" "$TMP_DIR/text.dis" <<'PYEOF'
import re, struct, sys
# Every function must be identical byte for byte, or differ only by the two
# known, pre-existing differences of the direct object route: the padding in
# front of an aligned loop header (one 10-byte `cs nopw` from as, `nopw` +
# `nop` from --obj) and amd64/elf.c's flags-dead `mov a, d; add v, d` ->
# `lea v(a), d` rewrite. Those functions are compared as canonical
# instruction streams (NOPs dropped, the as pair fused into the lea, branch
# targets as instruction indices).
R64 = {}
for n in 'ax bx cx dx si di bp sp'.split():
    R64['e' + n] = R64['r' + n] = 'r' + n
for k in range(8, 16):
    for suf in ('', 'd'):
        R64[f'r{k}{suf}'] = f'r{k}'
def width(r):
    # 64 or 32 for a general register name (with or without %), else None.
    r = r.lstrip('%')
    if r not in R64:
        return None
    return 64 if R64[r] == r else 32
# The lea fusion is only sound where the add's flags are dead: some later
# instruction must overwrite all arithmetic flags before anything that reads
# them, branches, calls or returns. Unknown instructions stop the scan.
FLAGS_WRITE = re.compile(r'^(cmp|test|add|sub|xor|and|or)[bwlq]? ')
FLAGS_NEUTRAL = re.compile(r'^(mov[a-z]*|lea[lq]?|push[q]?|pop[q]?|endbr64|cltq|cqto|cltd)( |$)')
def flags_dead(ins, j):
    for _, t in ins[j:]:
        if FLAGS_WRITE.match(t):
            return True
        if not FLAGS_NEUTRAL.match(t):
            return False
    return False
TARGET = re.compile(r'\b([0-9a-f]+) <\w+(?:\+0x[0-9a-f]+)?>')
NOP = re.compile(r'^((cs |ds |data16 )*nop[wl]?\b|xchg %ax,%ax$)')
def canon(path):
    return canon_text(open(path).read())
def canon_text(text):
    out, cur = {}, None
    for ln in text.split('\n'):
        m = re.match(r'^[0-9a-f]+ <(\w+)>:', ln)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        m = re.match(r'^\s*([0-9a-f]+):\s+(.*?)\s*$', ln)
        if m and cur:
            out[cur].append((int(m.group(1), 16), re.sub(r'\s+', ' ', m.group(2))))
    res = {}
    for fn, raw in out.items():
        # A branch to padding lands on the first instruction after it; any
        # other target must be an instruction entry exactly.
        land, pending = {}, []
        for a, t in raw:
            if NOP.match(t):
                pending.append(a)
                continue
            for p in pending:
                land[p] = a
            pending = []
            land[a] = a
        ins = [(a, t) for a, t in raw if not NOP.match(t)]
        targets = {land.get(int(m.group(1), 16), -1) for _, t in ins for m in TARGET.finditer(t)}
        seq, k = [], 0
        while k < len(ins):
            a, t = ins[k]
            m1 = re.match(r'^mov (%\w+),(%\w+)$', t)
            m2 = k + 1 < len(ins) and re.match(r'^add (\$0x[0-9a-f]+|%\w+),(%\w+)$', ins[k + 1][1])
            if (m1 and m2 and m1.group(2) == m2.group(2)
                    # `mov s, d; add v, d` == `lea v(s), d` only with s, d (and
                    # a register v) of one width, v != d (`add d, d` doubles s),
                    # nothing branching to the add, and its flags dead.
                    and width(m1.group(1)) is not None and width(m1.group(1)) == width(m1.group(2))
                    and (m2.group(1).startswith('$') or (width(m2.group(1)) == width(m1.group(2))
                                                         and m2.group(1) != m1.group(2)))
                    and ins[k + 1][0] not in targets
                    and flags_dead(ins, k + 2)):
                d, v = m1.group(2).lstrip('%'), m2.group(1)
                w = width(d)
                if v.startswith('$'):
                    seq.append((a, f'lea {int(v[1:], 16) % (1 << w)} {R64[m1.group(1).lstrip("%")]} {d}'))
                else:
                    regs = sorted([R64[m1.group(1).lstrip('%')], R64[v.lstrip('%')]])
                    seq.append((a, f'lea 0 {"+".join(regs)} {d}'))
                k += 2
                continue
            # Only 64-bit address registers are canonicalized: a 32-bit
            # address (`lea 1(%edi), %rdx`) truncates the sum and stays as is.
            m = re.match(r'^lea[lq]? (-?0x[0-9a-f]+)?\((%\w+)(?:,(%\w+),1)?\),(%\w+)$', t)
            if m and width(m.group(2)) == 64 and (m.group(3) is None or width(m.group(3)) == 64) \
                    and width(m.group(4)) is not None:
                d = m.group(4).lstrip('%')
                disp = int(m.group(1), 16) % (1 << width(d)) if m.group(1) else 0
                regs = [m.group(2).lstrip('%')] + ([m.group(3).lstrip('%')] if m.group(3) else [])
                seq.append((a, f'lea {disp} {"+".join(sorted(regs))} {d}'))
            else:
                seq.append((a, t))
            k += 1
        index = {a: n for n, (a, _) in enumerate(seq)}
        def target(m):
            addr = land.get(int(m.group(1), 16))
            return f'@{index[addr]}' if addr in index else f'@?{m.group(1)}'
        res[fn] = [TARGET.sub(target, t) for _, t in seq]
    return res
def need(ok, msg):
    if not ok:
        raise SystemExit("FAIL: p117 ELF " + msg)
# Self-check of the canonicalization: `mov; add` == `lea` only when the flags
# are dead (input 0: `setne` after the add returns 1, after the lea 0).
def probe(middle, tail):
    rows = ['xor %eax,%eax'] + middle + tail
    return canon_text('0000000000000000 <probe>:\n'
                      + ''.join(f'  {4 * n:x}:\t{r}\n' for n, r in enumerate(rows)))['probe']
ADD, LEA = ['mov %edi,%edx', 'add $0x1,%edx'], ['lea 0x1(%rdi),%edx']
need(probe(ADD, ['setne %al', 'ret']) != probe(LEA, ['setne %al', 'ret']),
     "canon self-check: a flags-live mov+add matched a lea")
need(probe(ADD, ['ret']) != probe(LEA, ['ret']), "canon self-check: mov+add before ret matched a lea")
need(probe(ADD, ['mov %edx,(%rsi)', 'call 0 <probe>', 'cmp $0x9,%edx']) != probe(LEA, ['mov %edx,(%rsi)', 'call 0 <probe>', 'cmp $0x9,%edx']),
     "canon self-check: mov+add before a call matched a lea")
need(probe(ADD, ['mov %edx,(%rsi)', 'cmp $0x9,%edx', 'setne %al']) == probe(LEA, ['mov %edx,(%rsi)', 'cmp $0x9,%edx', 'setne %al']),
     "canon self-check: a flags-dead mov+add did not match its lea")
# Flags dead, but not the same computation or not the same control flow.
need(probe(['mov $0xa,%edx', 'mov %edi,%edx', 'add %edx,%edx'], ['cmp $0x0,%edx', 'ret'])
     != probe(['mov $0xa,%edx', 'lea (%rdi,%rdx,1),%edx'], ['cmp $0x0,%edx', 'ret']),
     "canon self-check: `mov s, d; add d, d` matched `lea (s, d), d`")
def jprobe(rows):
    return canon_text('0000000000000000 <probe>:\n' + ''.join(f'  {a:x}:\t{r}\n' for a, r in rows))['probe']
need(jprobe([(0, 'mov $0xa,%edx'), (5, 'test %esi,%esi'), (7, 'je b <probe+0xb>'), (9, 'mov %edi,%edx'),
             (0xb, 'add $0x1,%edx'), (0xe, 'cmp $0x0,%edx'), (0x11, 'ret')])
     != jprobe([(0, 'mov $0xa,%edx'), (5, 'test %esi,%esi'), (7, 'je c <probe+0xc>'), (9, 'lea 0x1(%rdi),%edx'),
                (0xc, 'cmp $0x0,%edx'), (0xf, 'ret')]),
     "canon self-check: a branch into the add matched a branch past the lea")
need(probe(['lea 0x1(%edi),%rdx'], ['mov %rdx,%rax', 'ret']) != probe(['lea 0x1(%rdi),%rdx'], ['mov %rdx,%rax', 'ret']),
     "canon self-check: a 32-bit address lea matched a 64-bit one")
need(jprobe([(0, 'jmp 5 <probe+0x5>'), (2, 'nopw 0x0(%rax,%rax,1)'), (5, 'ret')])
     == jprobe([(0, 'jmp 2 <probe+0x2>'), (2, 'cs nopw 0x0(%rax,%rax,1)'), (5, 'ret')]),
     "canon self-check: a branch to padding did not land on the next instruction")
def exec_sections(path):
    # Executable sections with the 4-byte fields their RELA relocations patch
    # zeroed (the linker ignores them; as and --obj may leave different
    # placeholders), plus those relocations as (offset, type, symbol, addend).
    data = open(path, 'rb').read()
    need(data[:4] == b'\x7fELF' and data[4] == 2 and data[5] == 1, f"{path}: not ELF64 LE")
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + k * shentsize) for k in range(shnum)]
    def cstr(tab, off):
        s = data[secs[tab][4] + off:]
        return s[:s.index(b'\0')].decode()
    out, idx = {}, {}
    for k, sh in enumerate(secs):
        sh_name, sh_type, flags, _, off, size = sh[:6]
        if flags & 4 and size:  # SHF_EXECINSTR
            n = cstr(shstrndx, sh_name)
            need(n not in out, f"{path}: duplicate section {n}")
            out[n] = [bytearray(data[off:off + size] if sh_type != 8 else b'\0' * size), []]
            idx[k] = n
    for sh in secs:
        if sh[1] != 4 or sh[7] not in idx:  # SHT_RELA on an executable section
            continue
        symtab = secs[sh[6]]
        ent = out[idx[sh[7]]]
        for r in range(sh[5] // 24):
            r_off, info, addend = struct.unpack_from('<QQq', data, sh[4] + r * 24)
            st_name, = struct.unpack_from('<I', data, symtab[4] + (info >> 32) * 24)
            shndx, = struct.unpack_from('<H', data, symtab[4] + (info >> 32) * 24 + 6)
            # Unnamed (section) symbols are compared by the section they name.
            sym = cstr(symtab[6], st_name) if st_name else "section " + cstr(shstrndx, secs[shndx][0])
            need(r_off + 4 <= len(ent[0]), f"{path}: relocation past {idx[sh[7]]}")
            ent[0][r_off:r_off + 4] = b'\0\0\0\0'
            ent[1].append((r_off, info & 0xffffffff, sym, addend))
    return {n: (bytes(b), sorted(r)) for n, (b, r) in out.items()}
a, b = exec_sections(sys.argv[1]), exec_sections(sys.argv[2])
CAN_A, CAN_B = canon(sys.argv[3]), canon(sys.argv[4])
exact, rewritten = 0, []
need(len(a) == 20, f"want 20 function sections, got {sorted(a)}")
need(sorted(a) == sorted(b), f"section sets differ: {sorted(a)} vs {sorted(b)}")
total = nrel = 0
for n in sorted(a):
    (ab, ar), (bb, br) = a[n], b[n]
    fn = n[len('.text.'):]
    if ab != bb:
        k = next((i for i in range(min(len(ab), len(bb))) if ab[i] != bb[i]), min(len(ab), len(bb)))
        ca, cb = CAN_A.get(fn), CAN_B.get(fn)
        need(ca is not None and ca == cb,
             f"{n}: --obj and as differ at byte {k} ({len(ab)} vs {len(bb)} bytes) beyond NOP padding and the lea rewrite:\n"
             + "\n".join(f"  {x!r:40} {y!r}" for x, y in zip(ca or [], cb or []) if x != y))
        rewritten.append(fn)
    else:
        exact += 1
    need(ar == br, f"{n}: relocations differ: {ar} vs {br}")
    total += len(ab)
    nrel += len(ar)
# The 13 functions left without a loop must match byte for byte.
LOOPFREE = ['up4', 'down4', 'falseback5', 'wrap3', 'signcross2', 'udown4', 'extsw5', 'extuw3',
            'once1', 'eight8', 'long7', 'alias6', 'nested']
need(not set(LOOPFREE) & set(rewritten), f"expanded functions differ: {sorted(set(LOOPFREE) & set(rewritten))}")
need(sorted(rewritten) == ['callbody', 'multi', 'nine9', 'overbudget', 'twophi', 'varstart'], f"unexpected canonical-only set {rewritten}")
print(f"p117 --obj == as: {len(a)} function sections ({total} bytes, {nrel} relocations): {exact} byte-identical, "
      f"{len(rewritten)} equal up to NOP padding / the --obj lea rewrite ({', '.join(rewritten) or '-'})")
PYEOF
  python3 -E - "$TMP_DIR/direct.dis" <<'PYEOF'
import re, sys
BACK = {'nine9': 1, 'multi': 1, 'callbody': 1, 'divbody': 1, 'varstart': 1, 'twophi': 1, 'overbudget': 1}
FUNCS = ['up4', 'down4', 'falseback5', 'wrap3', 'signcross2', 'udown4', 'extsw5', 'extuw3',
         'once1', 'eight8', 'nine9', 'long7', 'alias6', 'multi', 'nested',
         'callbody', 'divbody', 'varstart', 'twophi', 'overbudget']
cur, back = None, {}
for ln in open(sys.argv[1]):
    m = re.match(r'^[0-9a-f]+ <(\w+)>:', ln)
    if m:
        cur = m.group(1)
        back[cur] = 0
        continue
    m = re.match(r'^\s*([0-9a-f]+):\s+(j\w+)\s+([0-9a-f]+) <', ln)
    if m and cur and int(m.group(3), 16) <= int(m.group(1), 16):
        back[cur] += 1
if sorted(back) != sorted(FUNCS):
    raise SystemExit(f"FAIL: p117 disassembly functions {sorted(back)}")
bad = {f: back[f] for f in FUNCS if back[f] != BACK.get(f, 0)}
if bad:
    raise SystemExit(f"FAIL: p117 backward branches {bad}, want {BACK} (0 elsewhere)")
print(f"p117 --obj: {len(FUNCS) - len(BACK)} expanded functions without a back edge, "
      f"{len(BACK)} with exactly one")
PYEOF
  ;;
  *) echo "NOTE: p117 byte and back-edge checks need Linux x86-64 (host $HOST)" ;;
esac

# 4. fannkuchredux: dev and --release equal C, and its loops expand.
FK="$ROOT_DIR/benchmarks/pion/fannkuchredux.pion"
"$CC_BIN" -O2 -o "$TMP_DIR/fk_c" "$ROOT_DIR/benchmarks/c/fannkuchredux.c"
"$TMP_DIR/fk_c" > "$TMP_DIR/fk_c.out"
if [ "$(cat "$TMP_DIR/fk_c.out")" != "73196 38" ]; then
  echo "FAIL: p117 C fannkuchredux printed '$(cat "$TMP_DIR/fk_c.out")'" >&2
  exit 1
fi
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/fk_$MODE.ssa" -o "$TMP_DIR/fk_$MODE" "$FK"
  "$TMP_DIR/fk_$MODE" > "$TMP_DIR/fk_$MODE.out"
  if ! diff -u "$TMP_DIR/fk_c.out" "$TMP_DIR/fk_$MODE.out" >&2; then
    echo "FAIL: p117 fannkuchredux $MODE differs from C" >&2
    exit 1
  fi
  "$QBE" -d G -o /dev/null "$TMP_DIR/fk_$MODE.ssa" 2> "$TMP_DIR/fk_$MODE.g"
  N=$(grep -c '^> Expanded counted loop ' "$TMP_DIR/fk_$MODE.g" || true)
  echo "p117 fannkuchredux $MODE: $(cat "$TMP_DIR/fk_$MODE.out") (= C), $N loops expanded"
done
if [ "$N" -lt 1 ]; then
  echo "FAIL: p117 fannkuchredux --release expands no loop" >&2
  exit 1
fi

# 5. ASan + UBSan QBE over every QBE input above.
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address,undefined -o "$TMP_DIR/san_probe" 2>/dev/null \
  && "$TMP_DIR/san_probe"; then
  mkdir -p "$TMP_DIR/sanq"
  # The host's default target, as scripts/build-qbe.sh picks it (the replays
  # below pass -t; the default matters for the host differential run).
  case "$HOST" in
    Darwin/arm64|Darwin/aarch64) DEFTGT=T_arm64_apple ;;
    Darwin/*) DEFTGT=T_amd64_apple ;;
    */aarch64|*/arm64) DEFTGT=T_arm64 ;;
    */riscv64) DEFTGT=T_rv64 ;;
    *) DEFTGT=T_amd64_sysv ;;
  esac
  printf '#define Deftgt %s\n' "$DEFTGT" > "$TMP_DIR/sanq/config.h"
  (
    cd "$ROOT_DIR/vendor/qbe"
    for f in *.c amd64/*.c arm64/*.c rv64/*.c; do
      o="$TMP_DIR/sanq/$(printf '%s' "$f" | tr / _).o"
      "$CC_BIN" -std=c99 -O1 -g -w -fsanitize=address,undefined -fno-sanitize-recover=undefined \
        -fno-omit-frame-pointer -I "$TMP_DIR/sanq" -I . -c "$f" -o "$o"
    done
  )
  "$CC_BIN" -fsanitize=address,undefined "$TMP_DIR"/sanq/*.o -o "$TMP_DIR/sanq/qbe"
  SAN_ENV="ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"
  # san ARGS: run the sanitized QBE; any exit status or diagnostic fails.
  san() {
    if ! env $SAN_ENV "$TMP_DIR/sanq/qbe" "$@" 2> "$TMP_DIR/sanq/err" || [ -s "$TMP_DIR/sanq/err" ]; then
      cat "$TMP_DIR/sanq/err" >&2
      echo "FAIL: p117 sanitized QBE $*" >&2
      exit 1
    fi
  }
  # san_dump ARGS: same with a -d dump on stderr (printed to stdout); a
  # sanitizer report ends the process with a non-zero status.
  san_dump() {
    if ! env $SAN_ENV "$TMP_DIR/sanq/qbe" "$@" 2> "$TMP_DIR/sanq/err"; then
      tail -40 "$TMP_DIR/sanq/err" >&2
      echo "FAIL: p117 sanitized QBE $*" >&2
      exit 1
    fi
    if grep -q 'Sanitizer\|runtime error' "$TMP_DIR/sanq/err"; then
      grep -A20 'Sanitizer\|runtime error' "$TMP_DIR/sanq/err" >&2
      echo "FAIL: p117 sanitized QBE $*" >&2
      exit 1
    fi
    cat "$TMP_DIR/sanq/err"
  }
  RUNS=0
  for IN in "$DIR/loops.ssa" "$TMP_DIR/fk_dev.ssa" "$TMP_DIR/fk_release.ssa"; do
    for T in amd64_sysv amd64_apple arm64 arm64_apple; do
      san -t "$T" -o "$TMP_DIR/sanq/out.s" "$IN"
      san_dump -t "$T" -d G -o /dev/null "$IN" > "$TMP_DIR/sanq/g_$T.txt"
      RUNS=$((RUNS + 2))
      case "$T" in
        amd64_sysv|arm64_apple)
          san -t "$T" --obj -o "$TMP_DIR/sanq/out.o" "$IN"
          RUNS=$((RUNS + 1))
          ;;
      esac
      "$QBE" -t "$T" -o "$TMP_DIR/sanq/plain.s" "$IN"
      cmp "$TMP_DIR/sanq/out.s" "$TMP_DIR/sanq/plain.s"
      "$QBE" -t "$T" -d G -o /dev/null "$IN" 2> "$TMP_DIR/sanq/plain_g.txt"
      cmp "$TMP_DIR/sanq/g_$T.txt" "$TMP_DIR/sanq/plain_g.txt"
      if [ "$IN" = "$DIR/loops.ssa" ]; then
        expansions "$TMP_DIR/sanq/g_$T.txt" "ASan+UBSan $T" > /dev/null
      fi
    done
  done
  asm "$TMP_DIR/sanq/qbe" "$DIR/loops.ssa" "$TMP_DIR/san_text.o"
  run_driver "asan-ubsan-text" "$TMP_DIR/san_text.o"
  echo "p117 ASan+UBSan QBE: 3 inputs x 4 targets, $RUNS runs clean (same expansions and assembly as the plain QBE)"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p117 needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one" >&2
  exit 1
else
  echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; skipping the sanitized QBE replay"
fi

echo "PASS: p117_qbe_counted_loop_unroll"
