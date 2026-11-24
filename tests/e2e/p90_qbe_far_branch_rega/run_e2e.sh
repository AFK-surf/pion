#!/usr/bin/env sh
# P90 E2E (Wave H-2 Track H5):
# A1: ARM64 > +-1MB far conditional branches (Mach-O direct .o + ELF text .s)
#     - forward/backward > 1MB branches, jtbl out-of-range b.hs, fused flag_ins,
#       cbz/cbnz, non-fused b.cc, external call relocs intact after far retry.
#     - small function emits short 19-bit branches (zero far thunks).
# A2: QBE rega.c cold-call successor seeding + final cold-block sinking layout
#     - high-live-var ST RC loop, MT RC loop, Option null-niche loop
#     - dev/release/ASan exact checksum agreement + amd64_sysv & arm64_apple
#       hot-path layout audit.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC="${CC:-cc}"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== P90 E2E: A1 ARM64 Far Conditional Branches (> +-1MB) ==="

python3 - "$TMP_DIR" <<'PYEOF'
import os, sys

out_dir = sys.argv[1]

# 1. Construct a > 1.12 MB function with:
#    - forward cbz/cbnz (> +1MB)
#    - forward fused flag_ins + b.cc (> +1MB)
#    - forward jtbl out-of-range b.hs (> +1MB)
#    - backward conditional branch (< -1MB)
#    - external call relocations (ext_helper)
# Keep max SSA def-use chain depth shallow (< 2000) so QBE GCM never overflows
# the C stack: 1450 blocks x 200 ops, split across 16 independent lanes (91
# blocks/lane) with 10 parallel 20-op subchains per block.
N_BLKS = 1600
N_LANES = 16
SUBCHAINS = 10
SUB_LEN = 20

lines = [
    "export function l $far_branch_test(w %mode, l %x, l %y, w %iters, l %state) {",
    "@entry",
    "    %a0 =l call $ext_helper(l %x)",
    "    %c_cbz =w ceqw %mode, 0",
    "    jnz %c_cbz, @far_cbz_dst, @check_flag",
    "@check_flag",
    "    %c_lt =w csltl %x, %y",
    "    jnz %c_lt, @far_flag_dst, @check_jtbl",
    "@check_jtbl",
    "    %jidx =w sub %mode, 1",
    "    jtbl %jidx, @far_jtbl_def, @jt_case0, @jt_case1, @jt_case2",
    "@jt_case0",
    "    %r_j0 =l add %a0, 100",
    "    jmp @loop_init",
    "@jt_case1",
    "    %r_j1 =l add %a0, 200",
    "    jmp @loop_init",
    "@jt_case2",
    "    %r_j2 =l add %a0, 300",
    "    jmp @loop_init",
    "@loop_init",
    "    %acc0 =l phi @jt_case0 %r_j0, @jt_case1 %r_j1, @jt_case2 %r_j2",
    "    storel %acc0, %state",
    "    %st_rem0 =l add %state, 8",
    "    storew %iters, %st_rem0",
    "@loop_head",
    "    %acc =l loadl %state",
]

lanes = []
for li in range(N_LANES):
    v = f"%lane_init_{li}"
    lines.append(f"    {v} =l add %acc, {li + 1}")
    lanes.append(v)

for bi in range(N_BLKS):
    lines.append(f"@pad_{bi}")
    li = bi % N_LANES
    base = lanes[li]
    ends = []
    for sc in range(SUBCHAINS):
        cur = f"%p_{bi}_{sc}_0"
        lines.append(f"    {cur} =l xor {base}, {sc + 1}")
        for ki in range(1, SUB_LEN):
            nxt = f"%p_{bi}_{sc}_{ki}"
            if (ki & 1) == 0:
                lines.append(f"    {nxt} =l add {cur}, {(sc + 1)}")
            else:
                lines.append(f"    {nxt} =l xor {cur}, {(sc + 3)}")
            cur = nxt
        ends.append(cur)
    red = ends[0]
    for sc in range(1, SUBCHAINS):
        nxt = f"%r_{bi}_{sc}"
        lines.append(f"    {nxt} =l xor {red}, {ends[sc]}")
        red = nxt
    lanes[li] = red

lines.append("@loop_back")
final_v = lanes[0]
for li in range(1, N_LANES):
    nxt = f"%fin_{li}"
    lines.append(f"    {nxt} =l add {final_v}, {lanes[li]}")
    final_v = nxt

lines.extend([
    f"    %acc_next =l call $ext_helper(l {final_v})",
    "    storel %acc_next, %state",
    "    %st_rem1 =l add %state, 8",
    "    %rem_cur =w loadw %st_rem1",
    "    %rem_next =w sub %rem_cur, 1",
    "    storew %rem_next, %st_rem1",
    "    %c_back =w cslew %rem_next, 0",
    "    jnz %c_back, @done_normal, @loop_head",
    "@done_normal",
    "    %ret_v =l loadl %state",
    "    ret %ret_v",
    "@far_cbz_dst",
    "    %rc0 =l add %a0, 777",
    "    ret %rc0",
    "@far_flag_dst",
    "    %rf0 =l add %a0, 888",
    "    ret %rf0",
    "@far_jtbl_def",
    "    %rj0 =l add %a0, 999",
    "    ret %rj0",
    "}",
    "",
    "# Symbol-collision test: a legitimate function named .Lfar0 must not collide with far-branch labels",
    "export function w $\".Lfar0\"() {",
    "@s",
    "    ret 42",
    "}",
])

with open(os.path.join(out_dir, "far_branch.ssa"), "w") as f:
    f.write("\n".join(lines) + "\n")

# 2. Small function to confirm zero far thunks when within +-1MB
small_ssa = """export function l $small_branch_test(w %mode, l %x, l %y) {
@entry
    %c0 =w ceqw %mode, 0
    jnz %c0, @z, @nz
@nz
    %c1 =w csltl %x, %y
    jnz %c1, @lt, @ge
@z
    ret 10
@lt
    ret 20
@ge
    ret 30
}
"""
with open(os.path.join(out_dir, "small_branch.ssa"), "w") as f:
    f.write(small_ssa)

# 3. C driver for host execution
driver_c = """#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int64_t ext_helper(int64_t v) { return v + 5; }
extern int64_t far_branch_test(int32_t mode, int64_t x, int64_t y, int32_t iters, int64_t *state);

static int64_t expected_pad(int64_t acc) {
    int64_t lanes[16];
    for (int li = 0; li < 16; li++)
        lanes[li] = acc + (li + 1);
    for (int bi = 0; bi < 1600; bi++) {
        int li = bi % 16;
        int64_t base = lanes[li];
        int64_t red = 0;
        for (int sc = 0; sc < 10; sc++) {
            int64_t cur = base ^ (sc + 1);
            for (int ki = 1; ki < 20; ki++) {
                if ((ki & 1) == 0) cur = cur + (sc + 1);
                else cur = cur ^ (sc + 3);
            }
            red = (sc == 0) ? cur : (red ^ cur);
        }
        lanes[li] = red;
    }
    int64_t fin = lanes[0];
    for (int li = 1; li < 16; li++)
        fin += lanes[li];
    return fin;
}

int main(void) {
    int64_t st[2] = {0, 0};
    int64_t r_cbz = far_branch_test(0, 10, 5, 1, st);
    int64_t r_flag = far_branch_test(1, 2, 9, 1, st);
    int64_t r_jdef = far_branch_test(99, 10, 5, 1, st);
    int64_t r_loop = far_branch_test(2, 10, 5, 2, st);

    int64_t w_cbz = (10 + 5) + 777;
    int64_t w_flag = (2 + 5) + 888;
    int64_t w_jdef = (10 + 5) + 999;
    int64_t v = (10 + 5) + 200;
    v = expected_pad(v) + 5;
    v = expected_pad(v) + 5;
    int64_t w_loop = v;

    if (r_cbz != w_cbz || r_flag != w_flag || r_jdef != w_jdef || r_loop != w_loop) {
        fprintf(stderr, "FAIL: cbz=%lld/%lld flag=%lld/%lld jdef=%lld/%lld loop=%lld/%lld\\n",
            (long long)r_cbz, (long long)w_cbz,
            (long long)r_flag, (long long)w_flag,
            (long long)r_jdef, (long long)w_jdef,
            (long long)r_loop, (long long)w_loop);
        return 1;
    }
    printf("far_branch_exec ok: cbz=%lld flag=%lld jdef=%lld loop=%lld\\n",
        (long long)r_cbz, (long long)r_flag, (long long)r_jdef, (long long)r_loop);
    return 0;
}
"""
with open(os.path.join(out_dir, "far_driver.c"), "w") as f:
    f.write(driver_c)
PYEOF

# A1.1: arm64_apple direct Mach-O .o verification (works on both Linux and macOS!)
"$QBE" -t arm64_apple --obj -o "$TMP_DIR/far_branch_arm64.o" "$TMP_DIR/far_branch.ssa"
"$QBE" -t arm64_apple --obj -o "$TMP_DIR/small_branch_arm64.o" "$TMP_DIR/small_branch.ssa"

python3 - "$TMP_DIR/far_branch_arm64.o" "$TMP_DIR/small_branch_arm64.o" "$QBE" "$TMP_DIR" <<'PYEOF'
import os, struct, subprocess, sys

def parse_macho_text(path):
    data = open(path, "rb").read()
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IIIIIIII", data, 0)
    assert magic == 0xfeedfacf, f"bad Mach-O magic {hex(magic)}"
    assert cputype == 0x0100000c, f"bad cputype {hex(cputype)}"
    off = 32
    text_bytes = None
    raw_relocs = []
    syms = []
    symtab_info = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19: # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            soff = off + 72
            for _ in range(nsects):
                sectname = data[soff:soff+16].rstrip(b"\x00").decode()
                segname = data[soff+16:soff+32].rstrip(b"\x00").decode()
                addr, size, foff, align, reloff, nreloc = struct.unpack_from("<QQIIII", data, soff + 32)
                if segname == "__TEXT" and sectname == "__text":
                    text_bytes = data[foff:foff+size]
                    for ri in range(nreloc):
                        r_addr, r_info = struct.unpack_from("<iI", data, reloff + ri * 8)
                        r_sym = r_info & 0x00ffffff
                        r_extern = (r_info >> 27) & 1
                        r_type = (r_info >> 28) & 0xf
                        raw_relocs.append((r_addr, r_type, r_extern, r_sym))
                soff += 80
        elif cmd == 0x02: # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            symtab_info = (symoff, nsyms, stroff, strsize)
        off += cmdsize
    assert text_bytes is not None, "missing __TEXT,__text"
    if symtab_info is not None:
        symoff, nsyms, stroff, strsize = symtab_info
        strtab = data[stroff:stroff+strsize]
        for si in range(nsyms):
            n_strx = struct.unpack_from("<I", data, symoff + si * 16)[0]
            end = strtab.find(b"\x00", n_strx)
            syms.append(strtab[n_strx:end].decode() if end != -1 else "")
    relocs = [
        (r_addr, r_type, r_extern, syms[r_sym] if (r_extern == 1 and r_sym < len(syms)) else "")
        for r_addr, r_type, r_extern, r_sym in raw_relocs
    ]
    insns = struct.unpack(f"<{len(text_bytes)//4}I", text_bytes)
    return len(text_bytes), insns, relocs

def is_cond_skip8(insn):
    # b.cc +8: 0x54000000 | (2 << 5) | cond
    if (insn & 0xff000010) == 0x54000000 and ((insn >> 5) & 0x7ffff) == 2:
        return True
    # cbz/cbnz +8: 0x34000000 (32/64) | (2 << 5) | rt
    if (insn & 0x7e000000) == 0x34000000 and ((insn >> 5) & 0x7ffff) == 2:
        return True
    return False

far_sz, far_insns, far_relocs = parse_macho_text(sys.argv[1])
assert far_sz > 1048576, f"expected > 1MB __text, got {far_sz}"

far_thunks = 0
fwd_far = 0
bwd_far = 0
thunk_info = []
for idx in range(len(far_insns) - 1):
    if is_cond_skip8(far_insns[idx]) and (far_insns[idx + 1] & 0xfc000000) == 0x14000000:
        far_thunks += 1
        imm26 = far_insns[idx + 1] & 0x03ffffff
        if imm26 & 0x02000000:
            imm26 -= 0x04000000
        thunk_info.append((idx, hex(far_insns[idx]), imm26))
        if imm26 > 262143:
            fwd_far += 1
        elif imm26 < -262144:
            bwd_far += 1

# Must have far thunks covering both forward (> +1MB) and backward (< -1MB)
assert far_thunks >= 4, f"expected >= 4 far conditional thunks, got {far_thunks} ({thunk_info})"
assert fwd_far >= 3, f"expected >= 3 forward > +1MB thunks (cbz, flag, jtbl), got {fwd_far} ({thunk_info})"
assert bwd_far >= 1, f"expected >= 1 backward < -1MB thunk (loop), got {bwd_far} (sz={far_sz}, thunks={thunk_info})"

# Relocations must be intact: exact count = 2, distinct offsets, r_extern=1, both targeting _ext_helper
br26 = [r for r in far_relocs if r[1] == 2] # ARM64_RELOC_BRANCH26
assert len(br26) == 2, f"expected exactly 2 BRANCH26 relocs, got {len(br26)} (all={far_relocs})"
assert br26[0][0] != br26[1][0], f"duplicate BRANCH26 reloc offset: {br26}"
for r_addr, _, r_extern, r_sym in br26:
    assert r_extern == 1, f"expected BRANCH26 r_extern=1, got {r_extern}"
    assert r_sym == "_ext_helper", f"expected BRANCH26 reloc sym '_ext_helper', got '{r_sym}'"
    assert r_addr % 4 == 0 and 0 <= r_addr < far_sz
    w = far_insns[r_addr // 4]
    assert (w & 0xfc000000) == 0x94000000, f"reloc at {r_addr} does not point to bl: {hex(w)}"

# Small function must NOT emit any far thunks
sm_sz, sm_insns, _ = parse_macho_text(sys.argv[2])
sm_thunks = sum(
    1 for idx in range(len(sm_insns) - 1)
    if is_cond_skip8(sm_insns[idx]) and (sm_insns[idx + 1] & 0xfc000000) == 0x14000000
)
assert sm_thunks == 0, f"small function unexpectedly emitted {sm_thunks} far thunks"
print(f"[PASS] Mach-O far_branch: size={far_sz}B thunks={far_thunks} (fwd={fwd_far}, bwd={bwd_far}) relocs=2 (_ext_helper @ {[r[0] for r in br26]}); small={sm_sz}B thunks=0")

# Exact imm19 boundary endpoint tests: +262143 / +262144 and -262144 / -262145
qbe_bin, tmp_dir = sys.argv[3], sys.argv[4]

def emit_pad_chunks(lines, total_ops, prefix, val_ref, ptr_ref):
    # Each chunk of up to 100 ops has shallow SSA depth (<= 100), starts with a
    # unique imm12 (cid + 1 <= 4095, single ARM64 ADD imm instruction) so GVN
    # cannot deduplicate chunks, and ends with storel to ptr_ref so nothing is DCE'd.
    done = 0
    cid = 0
    while done < total_ops:
        rem = total_ops - done
        if rem == 1:
            lines.append(f"    storel {val_ref}, {ptr_ref}")
            done += 1
            break
        n_add = min(99, rem - 1)
        cur = val_ref
        for k in range(n_add):
            nxt = f"%{prefix}_{cid}_{k}"
            if k == 0:
                lines.append(f"    {nxt} =l add {cur}, {cid + 1}")
            elif (k & 1) == 1:
                lines.append(f"    {nxt} =l xor {cur}, 3")
            else:
                lines.append(f"    {nxt} =l add {cur}, 1")
            cur = nxt
        lines.append(f"    storel {cur}, {ptr_ref}")
        done += n_add + 1
        cid += 1

def build_and_inspect_edge(tag, ssa_text):
    ssa_p = os.path.join(tmp_dir, f"edge_{tag}.ssa")
    obj_p = os.path.join(tmp_dir, f"edge_{tag}.o")
    open(ssa_p, "w").write(ssa_text)
    subprocess.check_call([qbe_bin, "-t", "arm64_apple", "--obj", "-o", obj_p, ssa_p])
    _, insns, _ = parse_macho_text(obj_p)
    thunks = []
    short_imm19s = []
    for idx, w in enumerate(insns):
        if idx + 1 < len(insns) and is_cond_skip8(w) and (insns[idx + 1] & 0xfc000000) == 0x14000000:
            imm26 = insns[idx + 1] & 0x03ffffff
            if imm26 & 0x02000000: imm26 -= 0x04000000
            thunks.append(imm26)
        elif (w & 0xff000010) == 0x54000000 or (w & 0x7e000000) == 0x34000000:
            imm19 = (w >> 5) & 0x7ffff
            if imm19 & 0x40000: imm19 -= 0x80000
            short_imm19s.append(imm19)
    return thunks, short_imm19s

def make_fwd_ssa(n_ops):
    lines = [
        "export function l $edge_fwd(w %c, l %x, l %p) {",
        "@entry",
        "    %z =w ceqw %c, 0",
        "    jnz %z, @dst, @pad",
        "@pad",
    ]
    emit_pad_chunks(lines, n_ops, "f", "%x", "%p")
    lines.extend(["@dst", "    ret %x", "}"])
    return "\n".join(lines) + "\n"

def make_bwd_ssa(n_ops):
    lines = [
        "export function l $edge_bwd(l %x, l %p) {",
        "@entry",
        "    jmp @head",
        "@head",
        "    %v =l loadl %p",
    ]
    emit_pad_chunks(lines, n_ops, "b", "%v", "%p")
    lines.extend([
        "    %c =w loadw %p",
        "    %z =w ceqw %c, 0",
        "    jnz %z, @done, @head",
        "@done",
        "    ret %x",
        "}",
    ])
    return "\n".join(lines) + "\n"

# Self-calibrate exact instruction overhead using a small probe (n_ops = 500)
_, probe_fwd = build_and_inspect_edge("probe_fwd", make_fwd_ssa(500))
assert len(probe_fwd) == 1 and probe_fwd[0] >= 500, f"bad fwd probe: {probe_fwd}"
fwd_overhead = probe_fwd[0] - 500
n_fwd_max = 262143 - fwd_overhead

th_fmax, sh_fmax = build_and_inspect_edge("fwd_262143", make_fwd_ssa(n_fwd_max))
assert len(th_fmax) == 0 and 262143 in sh_fmax, f"fwd +262143 failed: thunks={th_fmax} short={sh_fmax}"
th_fover, _ = build_and_inspect_edge("fwd_262144", make_fwd_ssa(n_fwd_max + 1))
assert th_fover == [262144], f"fwd +262144 failed: thunks={th_fover}"

_, probe_bwd = build_and_inspect_edge("probe_bwd", make_bwd_ssa(500))
assert len(probe_bwd) == 1 and (-probe_bwd[0]) >= 500, f"bad bwd probe: {probe_bwd}"
bwd_overhead = (-probe_bwd[0]) - 500
n_bwd_min = 262144 - bwd_overhead

th_bmin, sh_bmin = build_and_inspect_edge("bwd_262144", make_bwd_ssa(n_bwd_min))
assert len(th_bmin) == 0 and -262144 in sh_bmin, f"bwd -262144 failed: thunks={th_bmin} short={sh_bmin}"
th_bover, _ = build_and_inspect_edge("bwd_262145", make_bwd_ssa(n_bwd_min + 1))
assert th_bover == [-262146], f"bwd -262145 failed: thunks={th_bover}"

print(f"[PASS] Mach-O exact imm19 boundaries: +262143(short) / +262144(far={th_fover[0]}), -262144(short) / -262145(far={th_bover[0]})")
PYEOF

# A1.2: arm64 ELF text assembly verification
"$QBE" -t arm64 -o "$TMP_DIR/far_branch_arm64.s" "$TMP_DIR/far_branch.ssa"
"$QBE" -t arm64 -o "$TMP_DIR/small_branch_arm64.s" "$TMP_DIR/small_branch.ssa"

python3 - "$TMP_DIR/far_branch_arm64.s" "$TMP_DIR/small_branch_arm64.s" <<'PYEOF'
import re, sys

far_s = open(sys.argv[1]).read()
small_s = open(sys.argv[2]).read()

# Every conditional branch in far_branch_arm64.s must target numeric local label 1f,
# with matching 1: definitions, and zero collision with user symbol ".Lfar0".
far_labels = re.findall(r'^1:$', far_s, re.M)
assert len(far_labels) >= 4, f"expected >= 4 numeric '1:' labels in arm64 .s, got {len(far_labels)}"

direct_cond = re.findall(r'^\t(?:b(?:eq|ne|ge|gt|le|lt|cs|cc|hs|lo|hi|ls|mi|pl|vc|vs)|cbz|cbnz)\t.*,\s*\.L\d+|^\tb(?:eq|ne|ge|gt|le|lt|cs|cc|hs|lo|hi|ls|mi|pl|vc|vs)\t\.L\d+', far_s, re.M)
assert not direct_cond, f"found unexpanded short conditional branches in >1MB arm64 .s: {direct_cond[:5]}"

lfar0_defs = re.findall(r'^"?\.Lfar0"?:$', far_s, re.M)
assert len(lfar0_defs) == 1, f"expected exactly 1 definition of user function .Lfar0, got {len(lfar0_defs)}"

assert "\n1:\n" not in small_s, "small function unexpectedly emitted numeric 1: far labels"
print(f"[PASS] ELF arm64 .s far_branch: 1: labels={len(far_labels)}, direct_short_cond=0, .Lfar0 defs=1; small=0")
PYEOF

# Assemble far_branch_arm64.s when an ARM64 assembler is available on host
if command -v aarch64-linux-gnu-as >/dev/null 2>&1; then
  aarch64-linux-gnu-as -o "$TMP_DIR/far_branch_arm64_as.o" "$TMP_DIR/far_branch_arm64.s"
  echo "[PASS] aarch64-linux-gnu-as assembled far_branch_arm64.s cleanly"
elif [ "$(uname -s)" = "Darwin" ] && command -v clang >/dev/null 2>&1; then
  "$QBE" -t arm64_apple -o "$TMP_DIR/far_branch_apple.s" "$TMP_DIR/far_branch.ssa"
  clang -arch arm64 -c "$TMP_DIR/far_branch_apple.s" -o "$TMP_DIR/far_branch_apple_as.o"
  echo "[PASS] clang -arch arm64 assembled far_branch_apple.s cleanly"
fi

# A1.3: Host native execution of far_branch_test
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
if [ "$UNAME_S" = "Darwin" ] && [ "$UNAME_M" = "arm64" ]; then
  "$CC" "$TMP_DIR/far_branch_arm64.o" "$TMP_DIR/far_driver.c" -o "$TMP_DIR/far_driver"
elif [ "$UNAME_S" = "Linux" ] && [ "$UNAME_M" = "x86_64" ]; then
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/far_branch_host.o" "$TMP_DIR/far_branch.ssa"
  "$CC" "$TMP_DIR/far_branch_host.o" "$TMP_DIR/far_driver.c" -o "$TMP_DIR/far_driver"
elif [ "$UNAME_S" = "Linux" ] && { [ "$UNAME_M" = "aarch64" ] || [ "$UNAME_M" = "arm64" ]; }; then
  "$CC" "$TMP_DIR/far_branch_arm64.s" "$TMP_DIR/far_driver.c" -o "$TMP_DIR/far_driver"
else
  "$QBE" -o "$TMP_DIR/far_branch_host.s" "$TMP_DIR/far_branch.ssa"
  "$CC" "$TMP_DIR/far_branch_host.s" "$TMP_DIR/far_driver.c" -o "$TMP_DIR/far_driver"
fi
"$TMP_DIR/far_driver"

echo "=== P90 E2E: A2 QBE rega.c Cold-Call Seeding + Cold-Block Layout ==="

cat > "$TMP_DIR/a2_rc_layout.pion" <<'PIONEOF'
struct Box {
  tag : Int
  label : String
  extra : Int
}

// High-live-var ST RC loop (simulating Lay::flow_block: 16+ live locals + object RC)
fn st_rc_high_live(items : Array[Box], n : Int) -> Int {
  let mut a0 = 1
  let mut a1 = 2
  let mut a2 = 3
  let mut a3 = 4
  let mut a4 = 5
  let mut a5 = 6
  let mut a6 = 7
  let mut a7 = 8
  let mut a8 = 9
  let mut a9 = 10
  let mut a10 = 11
  let mut a11 = 12
  let mut a12 = 13
  let mut a13 = 14
  let mut a14 = 15
  let mut a15 = 16
  let mut keep = Box::{ tag: 0, label: "init", extra: 0 }
  let len = items.length()
  let mut i = 0
  while i < n {
    let cur = items[i & 15]
    keep = cur
    let t = cur.tag + cur.extra
    a0 = a0 + t
    a1 = a1 ^ (a0 + 1)
    a2 = a2 + (a1 & 15)
    a3 = a3 + (a2 & 31)
    a4 = a4 ^ (a3 + cur.tag)
    a5 = a5 + (a4 & 63)
    a6 = a6 + (a5 & 15)
    a7 = a7 ^ (a6 + cur.extra)
    a8 = a8 + (a7 & 7)
    a9 = a9 + (a8 & 15)
    a10 = a10 ^ (a9 + 3)
    a11 = a11 + (a10 & 31)
    a12 = a12 + (a11 & 7)
    a13 = a13 ^ (a12 + 5)
    a14 = a14 + (a13 & 15)
    a15 = a15 + (a14 & 31)
    i = i + 1
  }
  a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + keep.tag + len
}

// Option null-niche loop with high live state
fn option_niche_loop(items : Array[Option[Box]], n : Int) -> Int {
  let mut s0 = 1
  let mut s1 = 2
  let mut s2 = 3
  let mut s3 = 4
  let mut s4 = 5
  let mut s5 = 6
  let mut s6 = 7
  let mut s7 = 8
  let len = items.length()
  let mut i = 0
  while i < n {
    let cur = items[i % len]
    let v = match cur {
      Some(b) => b.tag + b.extra,
      None => 1
    }
    s0 = s0 + v
    s1 = s1 ^ (s0 + 1)
    s2 = s2 + (s1 & 15)
    s3 = s3 + (s2 & 31)
    s4 = s4 ^ (s3 + v)
    s5 = s5 + (s4 & 63)
    s6 = s6 + (s5 & 15)
    s7 = s7 ^ (s6 + 7)
    i = i + 1
  }
  s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7
}

pub fn main(w : World) -> Unit {
  let items : Array[Box] = []
  let opts : Array[Option[Box]] = []
  let mut i = 0
  while i < 16 {
    let b = Box::{ tag: i * 3 + 1, label: "box_" + i.to_string(), extra: i * 5 + 2 }
    items.push(b)
    if (i & 3) == 0 {
      opts.push(None)
    } else {
      opts.push(Some(b))
    }
    i = i + 1
  }
  let r_st = st_rc_high_live(items, 4000)
  let r_opt = option_niche_loop(opts, 4000)

  // Enter MT mode via scope/spawn, then run the same high-live RC loop in MT mode
  let mt_out = AtomicInt::new(0)
  scope(w, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let local_items : Array[Box] = []
      let mut j = 0
      while j < 16 {
        local_items.push(Box::{ tag: j * 3 + 1, label: "mt_" + j.to_string(), extra: j * 5 + 2 })
        j = j + 1
      }
      let r_mt = st_rc_high_live(local_items, 4000)
      mt_out.store(r_mt)
    })
  })
  let r_mt = mt_out.load()
  io_println(w, "a2 ok st=" + r_st.to_string() + " mt=" + r_mt.to_string() + " opt=" + r_opt.to_string())
}
PIONEOF

"$PIONC" build -o "$TMP_DIR/a2_dev" "$TMP_DIR/a2_rc_layout.pion"
"$PIONC" build --release --emit-ssa "$TMP_DIR/a2.ssa" -o "$TMP_DIR/a2_rel" "$TMP_DIR/a2_rc_layout.pion"
OUT_DEV="$("$TMP_DIR/a2_dev")"
OUT_REL="$("$TMP_DIR/a2_rel")"
echo "a2 dev: $OUT_DEV"
echo "a2 rel: $OUT_REL"
if [ "$OUT_DEV" != "$OUT_REL" ]; then
  echo "FAIL: dev vs release output mismatch: dev='$OUT_DEV' rel='$OUT_REL'" >&2
  exit 1
fi

# ASan/LSan check (0 UAF / 0 leaks)
if printf 'int main(void){return 0;}\n' | "$CC" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  "$PIONC" build --release --emit-obj "$TMP_DIR/a2_asan.o" "$TMP_DIR/a2_rc_layout.pion"
  "$CC" -fsanitize=address "$TMP_DIR/a2_asan.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/a2_asan"
  OUT_ASAN="$("$TMP_DIR/a2_asan")"
  echo "a2 asan: $OUT_ASAN"
  if [ "$OUT_ASAN" != "$OUT_REL" ]; then
    echo "FAIL: asan vs release output mismatch: asan='$OUT_ASAN' rel='$OUT_REL'" >&2
    exit 1
  fi
fi

# Audit amd64_sysv and arm64_apple assembly & rega stats for st_rc_high_live
"$QBE" -t amd64_sysv -o "$TMP_DIR/a2_amd64.s" "$TMP_DIR/a2.ssa"
"$QBE" -t arm64_apple -o "$TMP_DIR/a2_arm64.s" "$TMP_DIR/a2.ssa"
"$QBE" -t amd64_sysv -d R "$TMP_DIR/a2.ssa" > /dev/null 2> "$TMP_DIR/a2_amd64.rega"
"$QBE" -t arm64_apple -d R "$TMP_DIR/a2.ssa" > /dev/null 2> "$TMP_DIR/a2_arm64.rega"

python3 - "$TMP_DIR/a2_amd64.s" "$TMP_DIR/a2_arm64.s" "$TMP_DIR/a2_amd64.rega" "$TMP_DIR/a2_arm64.rega" <<'PYEOF'
import re, sys

def audit_asm_text(body, label, is_arm64):
    # Check that cold callq/bl pion_rc_inc_slow / pion_rc_dec_slow / pion_rc_drop are sunk
    # past the main loop backward branch (no cold RC calls inside the hot loop body).
    # With loop-guided selective inline_rc, the post-loop epilogue may retain a compact
    # `call pion_rc_dec` right before `ret`, which runs once after loop exit.
    lines = body.splitlines()
    ret_idx = next((i for i, l in enumerate(lines) if re.match(r'^\tret\b', l)), -1)
    assert ret_idx > 0, f"no ret found in {label}"
    # Locate the loop's backward branch using real arch branch instructions only
    # (never matching address-taking instructions like `leaq .Lold(%rip), %rax`).
    br_re = (
        r'^\t(?:b(?:\.\w+)?|cbn?z|tbn?z)\b.*?(?<!\w)(\.?L\w+)\b'
        if is_arm64
        else r'^\t(?:jmp|j[a-z]{1,3})\b.*?(?<!\w)(\.?L\w+)\b'
    )
    lbl_pos = {}
    last_back_br = -1
    for i, l in enumerate(lines[:ret_idx]):
        lm = re.match(r'^(\.?L\w+):', l)
        if lm:
            lbl_pos[lm.group(1)] = i
        else:
            bm = re.match(br_re, l)
            if bm and bm.group(1) in lbl_pos and lbl_pos[bm.group(1)] < i:
                last_back_br = i
    assert last_back_br > 0, f"no loop backward branch found before ret in {label}"
    call_re = r'^\t(?:bl|callq?)\b.*\b(?:_?pion_rc_(?:inc|dec)|_?pion_destroy_obj)\b'
    slow_idxs = [i for i, l in enumerate(lines) if re.match(call_re, l)]
    in_loop_calls = [i for i in slow_idxs if i < last_back_br]
    after_ret = sum(1 for i in slow_idxs if i > ret_idx)
    mov_re = r'^\tmov\b' if is_arm64 else r'^\tmov[qwl]?\b'
    hot_movs = sum(1 for l in lines[:ret_idx] if re.match(mov_re, l))
    uncond_re = r'^\tb\t' if is_arm64 else r'^\tjmp\t'
    hot_jmps = sum(1 for l in lines[:ret_idx] if re.match(uncond_re, l))
    assert len(in_loop_calls) == 0, f"found {len(in_loop_calls)} cold RC calls inside hot loop (before L{last_back_br}): {in_loop_calls} in {label}"
    assert after_ret >= 6, f"expected >= 6 sunk loop RC slow/drop calls after ret ({ret_idx}), got {after_ret} in {label}"
    return after_ret, hot_movs, hot_jmps

def audit_asm(path, fn_sub, is_arm64):
    txt = open(path).read()
    m = re.search(rf'({fn_sub}:.*?/\* end function)', txt, re.S)
    assert m, f"{fn_sub} not found in {path}"
    return audit_asm_text(m.group(1), path, is_arm64)

# Self-test negative cases for audit_asm_text:
# (a) `leaq .Lold(%rip), %rax` backward label reference without a real backward branch must be rejected.
neg_lea_only = "\n".join([
    "fake_fn:",
    ".Lold:",
    "\tleaq .Lold(%rip), %rax",
    "\tret",
    "\tcallq pion_rc_inc", "\tcallq pion_rc_inc", "\tcallq pion_rc_dec",
    "\tcallq pion_rc_dec", "\tcallq pion_destroy_obj", "\tcallq pion_destroy_obj",
])
try:
    audit_asm_text(neg_lea_only, "neg_lea_only", False)
    raise RuntimeError("neg_lea_only should have failed audit_asm_text")
except AssertionError as e:
    assert "no loop backward branch" in str(e), str(e)

# (b) Real cold RC call before backward branch must be rejected on both amd64 and arm64.
for _label, _is_arm64, _snippet in [
    ("neg_amd64_in_loop", False, "\n".join([
        "fake_amd64:",
        ".Lloop:",
        "\tcallq pion_rc_dec",
        "\tjl .Lloop",
        "\tret",
        "\tcallq pion_rc_inc", "\tcallq pion_rc_inc", "\tcallq pion_rc_dec",
        "\tcallq pion_rc_dec", "\tcallq pion_destroy_obj", "\tcallq pion_destroy_obj",
    ])),
    ("neg_arm64_in_loop", True, "\n".join([
        "fake_arm64:",
        "Lloop:",
        "\tbl _pion_rc_dec",
        "\tb.lt Lloop",
        "\tret",
        "\tbl _pion_rc_inc", "\tbl _pion_rc_inc", "\tbl _pion_rc_dec",
        "\tbl _pion_rc_dec", "\tbl _pion_destroy_obj", "\tbl _pion_destroy_obj",
    ])),
]:
    try:
        audit_asm_text(_snippet, _label, _is_arm64)
        raise RuntimeError(f"{_label} should have failed audit_asm_text")
    except AssertionError as e:
        assert "inside hot loop" in str(e), str(e)

def rega_stats(path, fn_sub):
    txt = open(path).read()
    m = re.search(rf'\*\*\*\* Function [^\n]*{fn_sub}[^\n]*\*\*\*\*(.*?)(?=\*\*\*\* Function |\Z)', txt, re.S)
    assert m, f"rega stats for {fn_sub} not found in {path}"
    sec = m.group(1)
    nm = int(re.search(r'new moves:\s*(\d+)', sec).group(1))
    nb = int(re.search(r'new blocks:\s*(\d+)', sec).group(1))
    return nb, nm

s64, m64, j64 = audit_asm(sys.argv[1], "st_rc_high_live", False)
sarm, marm, jarm = audit_asm(sys.argv[2], "st_rc_high_live", True)
tb64, tm64 = rega_stats(sys.argv[3], "st_rc_high_live")
tbarm, tmarm = rega_stats(sys.argv[4], "st_rc_high_live")
# Hard regression gates on arm64_apple: fails if either rega seeding or cold-block sinking regresses
assert marm <= 90, f"A2 regression: arm64_hot_mov={marm} > 90"
assert jarm <= 12, f"A2 regression: arm64_hot_jmp={jarm} > 12"
assert tmarm <= 115, f"A2 regression: arm64_rega_mov={tmarm} > 115"
print(f"[PASS] A2 layout & rega audit (st_rc_high_live):")
print(f"  amd64_sysv : cold_sunk={s64}/{s64} hot_movs={m64} hot_jmps={j64} rega_tramps={tb64} rega_moves={tm64}")
print(f"  arm64_apple: cold_sunk={sarm}/{sarm} hot_movs={marm} hot_jmps={jarm} rega_tramps={tbarm} rega_moves={tmarm}")
PYEOF

echo "[PASS] P90 E2E: A1 ARM64 far branches + A2 rega cold-call seeding & cold-block layout"
