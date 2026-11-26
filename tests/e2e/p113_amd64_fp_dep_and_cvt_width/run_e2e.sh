#!/bin/sh
# P113: AMD64 scalar floating-point dependency breaking + text conversion
# width fix (vendor/qbe/amd64/{all.h,elf.c,emit.c};
# Lean: tests/lean/proofs/QbeAmd64FpOpts.lean).
#   copy      XMM -> XMM `Ocopy` (also from `Oneg` / `Odiv` via emitcopy) is
#             `movaps` in the amd64_sysv text and ELF emitters; memory moves
#             stay movss / movsd; amd64_win is unchanged.
#   grouped   `amd64_grouped_cvt`: a block with >= 2 `swtof` / `sltof`
#             zeroes each destination with `xorps` first (amd64_sysv text
#             and ELF); isolated conversions are unchanged.
#   width     text templates `cvtsi2%kl` / `cvtsi2%kq`: GNU `as` used to
#             encode `cvtsi2sd off(%rsp), %xmm0` from an i64 slot as a dword
#             load (2^32 + 1 -> 1.0).
# Verifies:
#   1. p113.pion (grouped / isolated i32 / i64 -> f32 / f64 conversions at
#      INT32 / INT64 extremes, +-(2^32 + 1), 2^53 + 1, register pressure;
#      copies, neg, a / b, b / a, x / x and scalar iterations over +-0,
#      subnormals, Inf and NaN) prints the exact IEEE-754 bits of
#      expected.txt on Native dev & --release, Wasm32 dev & --release and
#      ASan/LSan dev & --release; reference.py recomputes expected.txt.
#   2. fixture.ssa through `qbe -t amd64_sysv` text: movaps for every XMM
#      register copy, no register-register movss / movsd, explicit
#      cvtsi2{ss,sd}{l,q}, one xorps before each conversion of the grouped
#      blocks (register pressure included) and none in the isolated ones;
#      `qbe -t amd64_win` text keeps movss / movsd and adds no xorps
#      (xmm6..xmm15 are callee-saved on Windows and not saved by QBE) but
#      has the same explicit conversion widths. QBE always reloads a spilled
#      conversion source into a register, so slots.ssa reaches the
#      memory-operand forms through a test-only QBE (qbe_*_hook.c, built
#      with ASan + UBSan when available) that rewrites the slot_* bodies
#      after register allocation; that QBE must emit exactly what out/qbe
#      emits for fixture.ssa and the nbody / spectralnorm / mandelbrot_mt
#      SSA, with no sanitizer report.
#   3. On a Linux x86-64 host with `as` / `objdump`: every executable
#      section of `qbe --obj` equals the one of `qbe` + `as` byte for byte
#      (fixture.ssa and slots.ssa), objdump decodes the slot conversions
#      with their operand width (qword for i64), and driver.c linked with
#      each pair of objects checks every function bit for bit (4294967297,
#      -4294967297, INT64_MIN, INT64_MAX included).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p113_amd64_fp_dep_and_cvt_width"
SRC="$DIR/p113.pion"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! cmp -s "$DIR/expected.txt" "$2"; then
    diff -u "$DIR/expected.txt" "$2" || true
    echo "FAIL: p113 $1" >&2
    exit 1
  fi
  echo "p113 $1 ok"
}

# 0. The checked-in expectation is the exact IEEE-754 reference.
python3 -E "$DIR/reference.py" > "$TMP_DIR/reference.txt"
check "reference.py == expected.txt" "$TMP_DIR/reference.txt"

# 1. Native dev / --release
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG -o "$TMP_DIR/p113_$MODE" "$SRC"
  "$TMP_DIR/p113_$MODE" > "$TMP_DIR/$MODE.out"
  check "native $MODE" "$TMP_DIR/$MODE.out"
done

# 2. Wasm32 dev / --release
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/$MODE.wasm" "$SRC"
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/$MODE.wasm" > "$TMP_DIR/w$MODE.out"
    check "wasm32 $MODE" "$TMP_DIR/w$MODE.out"
  done
else
  echo "NOTE: node unavailable; skipping p113 Wasm32 checks"
fi

# 3. ASan/LSan dev / --release. Only a compiler that cannot link a minimal
# ASan program skips this step (an error with PION_REQUIRE_SANITIZERS=1); once
# the probe passes, every compile and run below must succeed.
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$TMP_DIR/asan_probe"; then
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  # LeakSanitizer is not available everywhere (e.g. Apple Clang on macOS ARM64).
  ASAN_RUN_OPTS=""
  if ASAN_OPTIONS=detect_leaks=1 "$TMP_DIR/asan_probe" >/dev/null 2>&1; then
    ASAN_RUN_OPTS="detect_leaks=1"
  fi
  echo "p113 ASan options: ${ASAN_RUN_OPTS:-<none, no LeakSanitizer>}"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p113.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p113.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p113_asan"
    ASAN_OPTIONS="$ASAN_RUN_OPTS" "$TMP_DIR/p113_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p113 needs ASan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one" >&2
  exit 1
else
  echo "NOTE: $CC_BIN -fsanitize=address unavailable; skipping p113 ASan check"
fi

# 4. QBE text assembly (cross-target: runs on every host).
if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi
"$QBE" -t amd64_sysv -o "$TMP_DIR/sysv.s" "$DIR/fixture.ssa"
"$QBE" -t amd64_win -o "$TMP_DIR/win.s" "$DIR/fixture.ssa"

# Test-only QBE with the slot hook (qbe_slot_hook.c), built from the same
# vendor/qbe sources; reuses prebuilt $PION_QBE_SAN_DIR/obj/*.o when available.
QBE_DIR="$ROOT_DIR/vendor/qbe"
HOOK_DIR="$TMP_DIR/qbe-hook"
mkdir -p "$HOOK_DIR"
SAN_FLAGS=""
HOOK_OBJS=""
HOOK_CC="$CC_BIN"
if [ -n "${PION_QBE_SAN_DIR:-}" ] && [ -d "$PION_QBE_SAN_DIR/obj" ]; then
  SAN_FLAGS="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
  HOOK_INC="$PION_QBE_SAN_DIR"
  [ -f "$PION_QBE_SAN_DIR/qbe.cc" ] && HOOK_CC="$(cat "$PION_QBE_SAN_DIR/qbe.cc")"
  for O in "$PION_QBE_SAN_DIR"/obj/*.o; do
    case "$O" in
      */main.c.o) continue ;;
    esac
    HOOK_OBJS="$HOOK_OBJS $O"
  done
else
  SAN_RC=0
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/build-qbe-san.sh" "$HOOK_DIR" || SAN_RC=$?
  if [ "$SAN_RC" -eq 0 ]; then
    SAN_FLAGS="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
    HOOK_INC="$HOOK_DIR"
    [ -f "$HOOK_DIR/qbe.cc" ] && HOOK_CC="$(cat "$HOOK_DIR/qbe.cc")"
    for O in "$HOOK_DIR"/obj/*.o; do
      case "$O" in
        */main.c.o) continue ;;
      esac
      HOOK_OBJS="$HOOK_OBJS $O"
    done
  elif [ "$SAN_RC" -eq 77 ]; then
    if [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
      echo "FAIL: p113 needs ASan/UBSan for QBE (PION_REQUIRE_SANITIZERS=1)" >&2
      exit 1
    fi
    HOOK_INC="$HOOK_DIR"
    printf '#define Deftgt T_amd64_sysv\n' > "$HOOK_DIR/config.h"
    for S in util parse abi cfg mem ssa alias load copy fold gvn gcm simpl ifopt live spill rega emit \
      amd64/targ amd64/sysv amd64/isel amd64/emit amd64/winabi amd64/elf \
      arm64/targ arm64/abi arm64/isel arm64/emit arm64/macho \
      rv64/targ rv64/abi rv64/isel rv64/emit; do
      O="$HOOK_DIR/$(printf '%s' "$S" | tr / _).o"
      "$CC_BIN" -std=c99 -O1 -I"$HOOK_INC" -I"$QBE_DIR" -c "$QBE_DIR/$S.c" -o "$O"
      HOOK_OBJS="$HOOK_OBJS $O"
    done
  else
    echo "FAIL: p113 ASan+UBSan QBE build failed (exit $SAN_RC)" >&2
    exit 1
  fi
fi
echo "p113 hook QBE sanitizers: ${SAN_FLAGS:-<none>} (cc=$HOOK_CC)"
"$HOOK_CC" -std=c99 -O1 $SAN_FLAGS -I"$HOOK_INC" -I"$QBE_DIR" -c "$DIR/qbe_main_hook.c" -o "$HOOK_DIR/main_hook.o"
"$HOOK_CC" -std=c99 -O1 $SAN_FLAGS -I"$HOOK_INC" -I"$QBE_DIR" -c "$DIR/qbe_slot_hook.c" -o "$HOOK_DIR/slot_hook.o"
"$HOOK_CC" $SAN_FLAGS $HOOK_OBJS "$HOOK_DIR/main_hook.o" "$HOOK_DIR/slot_hook.o" -o "$HOOK_DIR/qbe"
HQBE="$HOOK_DIR/qbe"
export ASAN_OPTIONS="${ASAN_OPTIONS:-}${ASAN_OPTIONS:+:}detect_leaks=0:abort_on_error=0:detect_stack_use_after_return=0:fast_unwind_on_malloc=0:quarantine_size_mb=16"
"$HQBE" -t amd64_sysv -o "$TMP_DIR/slots.s" "$DIR/slots.ssa"
"$HQBE" -t amd64_win -o "$TMP_DIR/slots_win.s" "$DIR/slots.ssa"
# Without slot_* functions the hook QBE is the real one: same output, and no
# sanitizer report on the fixture or on real benchmark SSA.
"$HQBE" -t amd64_sysv -o "$TMP_DIR/hsysv.s" "$DIR/fixture.ssa"
"$HQBE" -t amd64_win -o "$TMP_DIR/hwin.s" "$DIR/fixture.ssa"
cmp "$TMP_DIR/sysv.s" "$TMP_DIR/hsysv.s"
cmp "$TMP_DIR/win.s" "$TMP_DIR/hwin.s"
"$QBE" -t amd64_sysv --obj -o "$TMP_DIR/direct.o" "$DIR/fixture.ssa"
"$HQBE" -t amd64_sysv --obj -o "$TMP_DIR/hdirect.o" "$DIR/fixture.ssa"
cmp "$TMP_DIR/direct.o" "$TMP_DIR/hdirect.o"
for B in nbody spectralnorm mandelbrot_mt; do
  "$PIONC" build --release --emit-ssa "$TMP_DIR/$B.ssa" -o "$TMP_DIR/$B.bin" "$ROOT_DIR/benchmarks/pion/$B.pion"
  "$QBE" -t amd64_sysv -o "$TMP_DIR/$B.s" "$TMP_DIR/$B.ssa"
  "$HQBE" -t amd64_sysv -o "$TMP_DIR/$B.h.s" "$TMP_DIR/$B.ssa"
  cmp "$TMP_DIR/$B.s" "$TMP_DIR/$B.h.s"
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/$B.o" "$TMP_DIR/$B.ssa"
  "$HQBE" -t amd64_sysv --obj -o "$TMP_DIR/$B.h.o" "$TMP_DIR/$B.ssa"
  cmp "$TMP_DIR/$B.o" "$TMP_DIR/$B.h.o"
done
python3 -E - "$TMP_DIR/nbody.s" "$TMP_DIR/spectralnorm.s" "$TMP_DIR/mandelbrot_mt.s" <<'PYEOF'
import re, sys
def need(ok, msg):
    if not ok:
        raise SystemExit("FAIL: p113 benchmark asm " + msg)
for path in sys.argv[1:]:
    t = open(path).read()
    need(not re.search(r'\tmovs[sd] %xmm\d+, %xmm\d+\n', t), f"{path}: register-register movss/movsd left")
    need(not re.search(r'\tcvtsi2s[sd] ', t), f"{path}: conversion without width suffix")
    nmov = len(re.findall(r'\tmovaps %xmm', t))
    nxor = len(re.findall(r'\txorps (%xmm\d+), \1\n\tcvtsi2', t))
    print("p113 %s: %d movaps, %d xorps-cvt pairs" % (path.rsplit('/', 1)[-1], nmov, nxor))
sn = open(sys.argv[2]).read()
need(re.search(r'\txorps (%xmm\d+), \1\n\tcvtsi2sdl ', sn), "spectralnorm: no grouped conversion")
PYEOF
echo "p113 hook QBE: fixture and nbody / spectralnorm / mandelbrot_mt emission identical to $QBE, no sanitizer report"
python3 -E - "$TMP_DIR/sysv.s" "$TMP_DIR/win.s" "$TMP_DIR/slots.s" "$TMP_DIR/slots_win.s" <<'PYEOF'
import re, sys
def need(ok, msg):
    if not ok:
        raise SystemExit("FAIL: p113 asm " + msg)
def functions(path):
    funcs, cur = {}, None
    lines = open(path).read().split('\n')
    # Function labels are the exported symbols; block labels are skipped.
    names = {m.group(1) for ln in lines for m in [re.match(r'^\.globl\s+(\w+)$', ln)] if m}
    for ln in lines:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):$', ln)
        if m and m.group(1) in names:
            cur = m.group(1)
            funcs[cur] = []
        elif cur is not None and ln.startswith('\t') and not ln.startswith('\t.'):
            funcs[cur].append(ln.strip())
    return funcs
CVT = re.compile(r'^cvtsi2(ss|sd)([lq]) (\S+), %(xmm\d+)$')
for path, target in ((sys.argv[1], 'amd64_sysv'), (sys.argv[2], 'amd64_win')):
    fs = functions(path)
    win = target == 'amd64_win'
    # amd64_win keeps scalar register moves and adds no xorps: xmm6..xmm15
    # are callee-saved (all 128 bits) there and QBE does not save them.
    REGMOVE = r'^movs[sd] %xmm\d+, %xmm\d+$' if win else r'^movaps %xmm\d+, %xmm\d+$'
    ZERO = re.compile(r'^xorps (%xmm\d+), \1$')
    def body(name):
        need(name in fs, f"{target}: no function {name} (got {sorted(fs)})")
        return fs[name]
    for name, ins in fs.items():
        for ln in ins:
            if win:
                need(not ln.startswith('movaps') and not ZERO.match(ln), f"{target} {name}: `{ln}` on Windows")
            else:
                need(not re.match(r'^movs[sd] %xmm\d+, %xmm\d+$', ln),
                     f"{target} {name}: register-register scalar move `{ln}`")
            need(not re.match(r'^cvtsi2s[sd] ', ln), f"{target} {name}: conversion without width suffix `{ln}`")
    for name, want in (('second_d', 1), ('second_s', 1), ('neg_d', 1), ('neg_s', 1),
                       ('div_ba', 2), ('div_ba_s', 2), ('div_xx', 1), ('div_xx_s', 1)):
        got = sum(1 for ln in body(name) if re.match(REGMOVE, ln))
        need(got == want, f"{target} {name}: {got} register copies, want {want}: {body(name)}")
    need(any(re.match(REGMOVE, ln) for ln in body('swap_sel')), f"{target} swap_sel: no register copy")
    for name in ('div_ab', 'div_ab_s'):
        need(not any(re.match(REGMOVE, ln) for ln in body(name)), f"{target} {name}: needs no copy: {body(name)}")
    mc = body('mem_copy')
    need(sum(1 for ln in mc if re.match(r'^movs[sd] ', ln) and '(' in ln) == 4 and
         not any('movaps' in ln for ln in mc), f"{target} mem_copy: memory moves must stay scalar: {mc}")
    def convs(name):
        ins = body(name)
        out = []
        for k, ln in enumerate(ins):
            m = CVT.match(ln)
            if m:
                out.append((k, m.group(1), m.group(2), m.group(3), m.group(4), ins))
        return out
    for name, prec, width in (('iso_wd', 'sd', 'l'), ('iso_ld', 'sd', 'q'),
                              ('iso_ws', 'ss', 'l'), ('iso_ls', 'ss', 'q')):
        cs = convs(name)
        need(len(cs) == 1 and cs[0][1:3] == (prec, width), f"{target} {name}: want one cvtsi2{prec}{width}: {body(name)}")
    for name in ('iso_wd', 'iso_ld', 'iso_ws', 'iso_ls', 'pressure_iso', 'pressure_iso_s'):
        need(not any(ZERO.match(ln) for ln in body(name)), f"{target} {name}: isolated conversion got xorps")
    def grouped(name, want):
        cs = convs(name)
        got = sorted(c[1] + c[2] for c in cs)
        need(got == sorted(want), f"{target} {name}: conversions {got}, want {sorted(want)}")
        n = sum(1 for ln in body(name) if ZERO.match(ln))
        if win:
            need(n == 0, f"{target} {name}: {n} xorps on Windows")
            return cs
        for k, _, _, _, dst, ins in cs:
            need(k > 0 and ins[k - 1] == f'xorps %{dst}, %{dst}', f"{target} {name}: `{ins[k]}` not preceded by xorps %{dst}")
        need(n == len(cs), f"{target} {name}: {n} xorps for {len(cs)} conversions")
        return cs
    grouped('grouped', ['sdl', 'sdl', 'sdq', 'sdq', 'ssl', 'ssl', 'ssq', 'ssq'])
    grouped('pressure_grouped', ['sdq', 'ssq'])
    for name, want in (('pressure_iso', 'sdq'), ('pressure_iso_s', 'ssq')):
        cs = convs(name)
        need(len(cs) == 1 and cs[0][1] + cs[0][2] == want, f"{target} {name}: want one cvtsi2{want}: {body(name)}")
    # slots.ssa: the conversions read the integer from the stack slot.
    sfs = functions(sys.argv[3] if target == 'amd64_sysv' else sys.argv[4])
    fs.update(sfs)
    for g in 'gi':
        for w in 'lw':
            for c in 'ds':
                name = f'slot_{g}{w}{c}'
                want = ['s' + c + {'l': 'q', 'w': 'l'}[w]] * (2 if g == 'g' else 1)
                cs = grouped(name, want) if g == 'g' else convs(name)
                need(len(cs) == len(want) and all(c_[1] + c_[2] == want[0] for c_ in cs) and
                     all(re.match(r'^-?\d*\(%r[sb]p\)$', c_[3]) for c_ in cs),
                     f"{target} {name}: want memory-operand cvtsi2{want[0]} from the slot: {body(name)}")
                if g == 'i':
                    need(not any(ZERO.match(ln) for ln in body(name)), f"{target} {name}: isolated conversion got xorps")
    print(f"p113 {target} text asm ok ({len(fs)} functions)")
PYEOF

# 5. Linux x86-64: direct ELF == GNU as, objdump widths, execution.
HOST_ARCH=$(uname -m)
if [ "$(uname -s)" = Linux ] && [ "$HOST_ARCH" = x86_64 ] && command -v as >/dev/null 2>&1 \
  && command -v objdump >/dev/null 2>&1; then
  as --64 -o "$TMP_DIR/gas.o" "$TMP_DIR/sysv.s"
  "$HQBE" -t amd64_sysv --obj -o "$TMP_DIR/slots_direct.o" "$DIR/slots.ssa"
  as --64 -o "$TMP_DIR/slots_gas.o" "$TMP_DIR/slots.s"
  for PAIR in direct:gas slots_direct:slots_gas; do
  python3 -E - "$TMP_DIR/${PAIR%%:*}.o" "$TMP_DIR/${PAIR#*:}.o" <<'PYEOF'
import struct, sys
def need(ok, msg):
    if not ok:
        raise SystemExit("FAIL: p113 ELF " + msg)
def exec_sections(path):
    data = open(path, 'rb').read()
    need(data[:4] == b'\x7fELF' and data[4] == 2 and data[5] == 1, f"{path}: not ELF64 LE")
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + k * shentsize) for k in range(shnum)]
    strtab = secs[shstrndx]
    def name(off):
        s = data[strtab[4] + off:]
        return s[:s.index(b'\0')].decode()
    out = {}
    for sh in secs:
        sh_name, sh_type, flags, _, off, size = sh[:6]
        if flags & 4 and size:  # SHF_EXECINSTR
            n = name(sh_name)
            need(n not in out, f"{path}: duplicate section {n}")
            out[n] = data[off:off + size] if sh_type != 8 else b'\0' * size
    return out
a, b = exec_sections(sys.argv[1]), exec_sections(sys.argv[2])
need(len(a) > 0, "no executable sections")
need(sorted(a) == sorted(b), f"section sets differ: {sorted(a)} vs {sorted(b)}")
total = 0
for n in sorted(a):
    if a[n] != b[n]:
        k = next((i for i in range(min(len(a[n]), len(b[n]))) if a[n][i] != b[n][i]), min(len(a[n]), len(b[n])))
        need(False, f"{n}: --obj and as differ at byte {k} ({len(a[n])} vs {len(b[n])} bytes)")
    total += len(a[n])
print(f"p113 {sys.argv[1].rsplit('/', 1)[-1]} (--obj) == {sys.argv[2].rsplit('/', 1)[-1]} (as): "
      f"{len(a)} executable sections, {total} bytes identical")
PYEOF
  done
  objdump -d --no-show-raw-insn "$TMP_DIR/slots_direct.o" > "$TMP_DIR/direct.dis"
  python3 -E - "$TMP_DIR/direct.dis" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
funcs = dict(re.findall(r'<(\w+)>:\n(.*?)(?=\n\n|\Z)', text, re.S))
n = 0
for g, want in (('g', 2), ('i', 1)):
    for w, sfx in (('l', 'q'), ('w', 'l')):
        for c in 'ds':
            name = f'slot_{g}{w}{c}'
            body = funcs.get(name, '')
            got = len(re.findall(r'cvtsi2s%s%s\s+(?:0x[0-9a-f]+)?\(%%r[sb]p\)' % (c, sfx), body))
            if got != want:
                raise SystemExit(f"FAIL: p113 objdump {name}: {got} cvtsi2s{c}{sfx} slot loads, want {want}:\n{body}")
            n += got
print(f"p113 objdump --obj: {n} slot conversions decode with the operand width of their type (q for l, l for w)")
PYEOF
  for OBJ in direct gas; do
    "$CC_BIN" -std=c11 -O2 -ffp-contract=off "$DIR/driver.c" "$TMP_DIR/$OBJ.o" "$TMP_DIR/slots_$OBJ.o" -lm -o "$TMP_DIR/driver_$OBJ"
    "$TMP_DIR/driver_$OBJ" > "$TMP_DIR/driver_$OBJ.out" || {
      cat "$TMP_DIR/driver_$OBJ.out"
      echo "FAIL: p113 driver ($OBJ object) disagrees with C" >&2
      exit 1
    }
    sed "s/^/p113 driver $OBJ: /" "$TMP_DIR/driver_$OBJ.out"
  done
  cmp "$TMP_DIR/driver_direct.out" "$TMP_DIR/driver_gas.out"
  # Exact group names and check counts: a group that silently lost its
  # cases (0/0) fails here.
  printf '%s\n' 'double_copy_neg_div 876/876' 'float_copy_neg_div 588/588' 'mem_copy 24/24' \
    'isolated_cvt 53/53' 'grouped_cvt 128/128' 'pressure_cvt 128/128' 'slot_cvt 104/104' > "$TMP_DIR/driver.want"
  if ! cmp -s "$TMP_DIR/driver.want" "$TMP_DIR/driver_direct.out"; then
    diff -u "$TMP_DIR/driver.want" "$TMP_DIR/driver_direct.out" || true
    echo "FAIL: p113 driver groups or check counts differ" >&2
    exit 1
  fi
else
  echo "NOTE: not a Linux x86-64 host with as/objdump ($HOST_ARCH); skipping p113 ELF parity and execution"
fi

echo "PASS: p113_amd64_fp_dep_and_cvt_width"
