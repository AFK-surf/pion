#!/bin/sh
# Wave K1-A: Windows COFF per-symbol section GC, same-section jump tables,
# Mach-O text `.subsections_via_symbols`, c_sources section flags, and
# multi-package local-symbol isolation E2E test.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
. "$ROOT_DIR/scripts/bg-lib.sh"
TMP="$(mktemp -d)"
BIGOBJ_PID=""
CBIG_PID=""
cleanup() {
  bg_kill "$BIGOBJ_PID" "$CBIG_PID"
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export PION_CACHE_DIR="$TMP/cas"

WS="$TMP/ws"
mkdir -p "$WS/pkg_a/src" "$WS/pkg_a/csrc" "$WS/pkg_b/src" "$WS/app/src"

cat > "$WS/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"

[link]
c_sources = ["csrc/stub.c"]
EOF

cat > "$WS/pkg_a/csrc/stub.c" <<'EOF'
#include <stdint.h>

int64_t k1a_live_c_fn(int64_t x) {
    return x * 3 + 7;
}

static const unsigned char k1a_dead_c_blob[65536] = { 1, 2, 3, 4 };

int64_t k1a_dead_c_bloat_fn(int64_t x) {
    int64_t acc = x;
    for (int i = 0; i < 65536; i++) {
        acc += k1a_dead_c_blob[i];
    }
    return acc;
}
EOF

cat > "$WS/pkg_a/src/lib.pion" <<'EOF'
extern "C" fn k1a_live_c_fn(x : Int) -> Int
extern "C" fn k1a_dead_c_bloat_fn(x : Int) -> Int

pub trait Scorer {
  score(self : Self) -> Int
}

pub struct LiveScorer {
  base : Int
}

impl Scorer for LiveScorer {
  fn score(self : LiveScorer) -> Int {
    self.base + 10
  }
}

fn init_magic() -> Int {
  40 + 2
}

pub let MAGIC : Int = init_magic()

fn priv_tag() -> String {
  "priv_a"
}

fn dead_priv_local_fn(x : Int) -> Int {
  let mut acc = x
  let mut i = 0
  while i < 16 {
    acc = acc * 5 + i
    i = i + 1
  }
  acc
}

pub fn live_msg() -> String {
  "alpha_from_a:" + priv_tag()
}

pub fn live_match_jtbl(k : Int) -> Int {
  match k {
    0 => 100
    1 => 101
    2 => 102
    3 => 103
    4 => 104
    5 => 105
    6 => 106
    7 => 107
    8 => 108
    9 => 109
    _ => 999
  }
}

pub fn live_vtable_and_closure(b : Int) -> Int {
  let s : dyn Scorer = LiveScorer::{ base: b }
  let f = fn(x : Int) -> Int { x + MAGIC }
  f(s.score()) + k1a_live_c_fn(5)
}

pub fn dead_match_jtbl_fn(k : Int) -> Int {
  match k {
    0 => k1a_dead_c_bloat_fn(0)
    1 => k1a_dead_c_bloat_fn(1)
    2 => k1a_dead_c_bloat_fn(2)
    3 => k1a_dead_c_bloat_fn(3)
    4 => k1a_dead_c_bloat_fn(4)
    5 => k1a_dead_c_bloat_fn(5)
    6 => k1a_dead_c_bloat_fn(6)
    7 => k1a_dead_c_bloat_fn(7)
    8 => k1a_dead_c_bloat_fn(8)
    9 => k1a_dead_c_bloat_fn(9)
    _ => k1a_dead_c_bloat_fn(99)
  }
}
EOF

# Append 80 dead bloat functions in pkg_a so Pion dead-code GC alone saves >32KB.
python3 - "$WS/pkg_a/src/lib.pion" <<'PYEOF'
import sys
with open(sys.argv[1], "a") as f:
    for i in range(80):
        f.write(f"\npub fn dead_bloat_fn_{i}(x : Int) -> Int {{\n")
        f.write("  let mut acc = x\n")
        for j in range(24):
            f.write(f"  acc = acc * 3 + {i * 13 + j}\n")
        f.write("  acc\n}\n")
PYEOF

cat > "$WS/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"
EOF

cat > "$WS/pkg_b/src/lib.pion" <<'EOF'
fn priv_tag() -> String {
  "priv_b"
}

pub fn live_msg() -> String {
  "beta_from_b:" + priv_tag()
}

pub fn dead_pkg_b_fn(x : Int) -> Int {
  x * 17 + 31
}
EOF

cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }
EOF

cat > "$WS/app/src/main.pion" <<'EOF'
import "pkg_a"
import "pkg_b"

pub fn main(world : World) -> Int {
  let a = pkg_a::live_msg()
  let b = pkg_b::live_msg()
  let m3 = pkg_a::live_match_jtbl(3)
  let md = pkg_a::live_match_jtbl(42)
  let vc = pkg_a::live_vtable_and_closure(5)
  io_println(world, a + "|" + b + "|" + m3.to_string() + "|" + md.to_string() + "|" + vc.to_string())
  0
}
EOF

# 1. Verify QBE text assembly invariants across targets.
WIN_ASM="$TMP/pkg_a_win.s"
"$PIONC" build --target amd64_win --emit-asm "$WIN_ASM" "$WS/pkg_a/src/lib.pion"
grep -q '\.section \.text\$' "$WIN_ASM" || { echo "FAIL: amd64_win asm missing .section .text\$" >&2; exit 1; }
grep -q '^\.linkonce one_only$' "$WIN_ASM" || { echo "FAIL: amd64_win asm missing .linkonce one_only" >&2; exit 1; }
if grep -q '\.section \.rdata' "$WIN_ASM"; then
  echo "FAIL: amd64_win jump table must stay in function section, not .rdata" >&2
  exit 1
fi
if grep -q '^\.previous$' "$WIN_ASM"; then
  echo "FAIL: amd64_win asm must not emit .previous" >&2
  exit 1
fi
# Every COFF per-symbol section (both exported `.globl` and non-exported local)
# MUST be followed by `.linkonce one_only` so MSVC `/OPT:REF` and MinGW
# `--gc-sections` can GC both dead exports and dead locals.
python3 - "$WIN_ASM" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
found_local = False
found_export = False
found_jtbl = False
for idx, line in enumerate(lines):
    if line.startswith('.section .text$') or line.startswith('.section .data$') or line.startswith('.section .bss$'):
        nxt = lines[idx + 1] if idx + 1 < len(lines) else ""
        window = lines[idx + 1 : min(idx + 5, len(lines))]
        is_globl = any(w.startswith(".globl ") for w in window)
        if nxt != ".linkonce one_only":
            sys.exit(f"FAIL: COFF section {line} missing .linkonce one_only (got {nxt!r})")
        if is_globl:
            found_export = True
        else:
            found_local = True
    if line.startswith('Ljt') or line.startswith('.Ljt'):
        found_jtbl = True
        for j in range(idx + 1, min(idx + 30, len(lines))):
            if lines[j] == ".text":
                sys.exit("FAIL: amd64_win jump table switched back to .text")
            if lines[j].startswith("Lbb") or lines[j].startswith(".Lbb"):
                break
assert found_local, "FAIL: no local COFF section found in amd64_win asm"
assert found_export, "FAIL: no exported COFF section found in amd64_win asm"
assert found_jtbl, "FAIL: no jump table found in amd64_win asm"
PYEOF

MAC_ARM_ASM="$TMP/pkg_a_arm64_apple.s"
MAC_X64_ASM="$TMP/pkg_a_amd64_apple.s"
"$PIONC" build --target arm64_apple --emit-asm "$MAC_ARM_ASM" "$WS/pkg_a/src/lib.pion"
"$PIONC" build --target amd64_apple --emit-asm "$MAC_X64_ASM" "$WS/pkg_a/src/lib.pion"
grep -q '^\.subsections_via_symbols$' "$MAC_ARM_ASM" || { echo "FAIL: arm64_apple asm missing .subsections_via_symbols" >&2; exit 1; }
grep -q '^\.subsections_via_symbols$' "$MAC_X64_ASM" || { echo "FAIL: amd64_apple asm missing .subsections_via_symbols" >&2; exit 1; }
echo "[PASS] p98: QBE amd64_win COFF sections/jump-tables + Apple .subsections_via_symbols"

# 2. Native host build & run + GC effectiveness check.
HOST_BIN="$TMP/app_gc"
"$PIONC" build --release -o "$HOST_BIN" "$WS/app"
HOST_OUT="$("$HOST_BIN" | tr -d '\r')"
WANT_OUT="alpha_from_a:priv_a|beta_from_b:priv_b|103|999|79"
if [ "$HOST_OUT" != "$WANT_OUT" ]; then
  echo "FAIL: p98 host output mismatch: got='$HOST_OUT' want='$WANT_OUT'" >&2
  exit 1
fi

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
if command -v nm >/dev/null 2>&1; then
  case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*)
      if [ "${PION_WIN_ABI:-}" = "msvc" ]; then
        DEAD_RE='dead_bloat_fn_0\|dead_match_jtbl_fn\|dead_priv_local_fn\|k1a_dead_c_bloat_fn'
      else
        # MinGW GCC's default PE linker script KEEP()s `.pdata*` for C sources.
        DEAD_RE='dead_bloat_fn_0\|dead_match_jtbl_fn\|dead_priv_local_fn'
      fi
      ;;
    *)
      DEAD_RE='dead_bloat_fn_0\|dead_match_jtbl_fn\|dead_priv_local_fn\|k1a_dead_c_bloat_fn'
      ;;
  esac
  if nm "$HOST_BIN" 2>/dev/null | grep -v '^[[:space:]]*U ' | grep -q "$DEAD_RE"; then
    echo "FAIL: dead symbols survived in GC'd native binary" >&2
    exit 1
  fi
fi

# On ELF/Linux or Windows, compare against no-GC link flag.
case "$UNAME_S" in
  Linux*|MINGW*|MSYS*|CYGWIN*)
    NOGC_FLAG="-Wl,--no-gc-sections"
    case "${CC:-}" in
      *clang-cl*|*clang-cl.exe|*clang-cl.EXE) NOGC_FLAG="-Wl,/OPT:NOREF" ;;
    esac
    if [ "${PION_WIN_ABI:-}" = "msvc" ]; then
      NOGC_FLAG="-Wl,/OPT:NOREF"
    fi
    cat > "$WS/app_nogc.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }

[link]
flags = ["$NOGC_FLAG"]
EOF
    cp "$WS/app/pion.toml" "$WS/app/pion.toml.bak"
    cp "$WS/app_nogc.toml" "$WS/app/pion.toml"
    HOST_NOGC="$TMP/app_nogc"
    "$PIONC" build --release -o "$HOST_NOGC" "$WS/app"
    mv "$WS/app/pion.toml.bak" "$WS/app/pion.toml"
    SZ_GC="$(wc -c < "$HOST_BIN" | tr -d ' ')"
    SZ_NOGC="$(wc -c < "$HOST_NOGC" | tr -d ' ')"
    DIFF_SZ=$((SZ_NOGC - SZ_GC))
    echo "[PASS] p98: native GC size=${SZ_GC}B vs no-GC(${NOGC_FLAG})=${SZ_NOGC}B (saved ${DIFF_SZ}B)"
    if [ "$DIFF_SZ" -lt 32768 ]; then
      echo "FAIL: expected >=32KB savings from section GC (saved ${DIFF_SZ}B)" >&2
      exit 1
    fi
    ;;
  *)
    echo "[PASS] p98: native macOS dead_strip verified (out=$HOST_OUT)"
    ;;
esac

# 2b. Shared CAS A -> B -> B verification on a minimal pure-Pion package
# (zero c_sources, zero extra link flags) using a native compiled C wrapper
# (works on Linux, macOS, and Windows CreateProcessA) that counts LINK calls only.
PURE_AB="$TMP/pure_ab"
mkdir -p "$PURE_AB/src"
cat > "$PURE_AB/pion.toml" <<'EOF'
[package]
name = "pure_ab"
version = "0.1.0"
EOF
cat > "$PURE_AB/src/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "pure_ab_ok")
  0
}
EOF
ORIG_CC="${CC:-cc}"
cat > "$TMP/cc_wrap_b.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

int main(int argc, char **argv) {
    const char *real_cc = getenv("P98_REAL_CC");
    const char *log_path = getenv("P98_WRAP_LOG");
    if (!real_cc || !*real_cc) real_cc = "cc";
    int has_out = 0, is_nonlink = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 || strncmp(argv[i], "/Fe", 3) == 0) has_out = 1;
        if (strcmp(argv[i], "-c") == 0 || strcmp(argv[i], "-S") == 0 ||
            strcmp(argv[i], "-E") == 0 || strcmp(argv[i], "-dumpmachine") == 0)
            is_nonlink = 1;
    }
    if (has_out && !is_nonlink && log_path && *log_path) {
        FILE *f = fopen(log_path, "a");
        if (f) { fputs("LINK\n", f); fclose(f); }
    }
    char **nargv = (char **)malloc((size_t)(argc + 1) * sizeof(char *));
    if (!nargv) return 127;
    nargv[0] = (char *)real_cc;
    for (int i = 1; i < argc; i++) nargv[i] = argv[i];
    nargv[argc] = NULL;
#ifdef _WIN32
    int rc = (int)_spawnvp(_P_WAIT, real_cc, (const char *const *)nargv);
    free(nargv);
    return rc < 0 ? 127 : rc;
#else
    execvp(real_cc, nargv);
    perror("execvp");
    return 127;
#endif
}
EOF
CC_WRAP="$TMP/cc_wrap_b"
case "$UNAME_S" in
  MINGW*|MSYS*|CYGWIN*) CC_WRAP="$TMP/cc_wrap_b.exe" ;;
esac
"$ORIG_CC" -O1 "$TMP/cc_wrap_b.c" -o "$CC_WRAP"
CAS_AB="$TMP/cas_ab"
mkdir -p "$CAS_AB"
CC_WRAP_LOG="$TMP/cc_wrap_b.log"
if [ "$UNAME_S" = "Darwin" ]; then
  OUT_A="$(PION_CACHE_DIR="$CAS_AB" env -u CC "$PIONC" run --release "$PURE_AB" | tr -d '\r')"
else
  OUT_A="$(PION_CACHE_DIR="$CAS_AB" "$PIONC" run --release "$PURE_AB" | tr -d '\r')"
fi
if [ "$OUT_A" != "pure_ab_ok" ]; then
  echo "FAIL: CAS A run output mismatch: '$OUT_A'" >&2
  exit 1
fi
N_BIN_A="$(ls -1 "$CAS_AB/bin" | wc -l | tr -d ' ')"
OUT_B1="$(PION_CACHE_DIR="$CAS_AB" P98_REAL_CC="$ORIG_CC" P98_WRAP_LOG="$CC_WRAP_LOG" CC="$CC_WRAP" "$PIONC" run --release "$PURE_AB" | tr -d '\r')"
if [ "$OUT_B1" != "pure_ab_ok" ]; then
  echo "FAIL: CAS B1 run output mismatch: '$OUT_B1'" >&2
  exit 1
fi
N_BIN_B1="$(ls -1 "$CAS_AB/bin" | wc -l | tr -d ' ')"
WLOG_B1="$(wc -l < "$CC_WRAP_LOG" 2>/dev/null | tr -d ' ' || echo 0)"
OUT_B2="$(PION_CACHE_DIR="$CAS_AB" P98_REAL_CC="$ORIG_CC" P98_WRAP_LOG="$CC_WRAP_LOG" CC="$CC_WRAP" "$PIONC" run --release "$PURE_AB" | tr -d '\r')"
if [ "$OUT_B2" != "pure_ab_ok" ]; then
  echo "FAIL: CAS B2 run output mismatch: '$OUT_B2'" >&2
  exit 1
fi
N_BIN_B2="$(ls -1 "$CAS_AB/bin" | wc -l | tr -d ' ')"
WLOG_B2="$(wc -l < "$CC_WRAP_LOG" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "$N_BIN_A" -ne 1 ] || [ "$N_BIN_B1" -ne 2 ] || [ "$N_BIN_B2" -ne 2 ]; then
  echo "FAIL: shared CAS A->B->B bin counts expected 1->2->2, got ${N_BIN_A}->${N_BIN_B1}->${N_BIN_B2}" >&2
  exit 1
fi
if [ "$WLOG_B1" -ne 1 ] || [ "$WLOG_B2" -ne 1 ]; then
  echo "FAIL: shared CAS A->B->B LINK count expected 1->1, got ${WLOG_B1}->${WLOG_B2}" >&2
  exit 1
fi
if [ "$UNAME_S" = "Darwin" ]; then
  OUT_C="$(PION_CACHE_DIR="$CAS_AB" CC=cc "$PIONC" run --release "$PURE_AB" | tr -d '\r')"
  N_BIN_C="$(ls -1 "$CAS_AB/bin" | wc -l | tr -d ' ')"
  if [ "$OUT_C" != "pure_ab_ok" ] || [ "$N_BIN_C" -ne 3 ]; then
    echo "FAIL: macOS unset CC (apple_ld) vs CC=cc expected 3rd bin key, got ${N_BIN_C}" >&2
    exit 1
  fi
fi
echo "[PASS] p98: shared CAS A->B->B pure-pkg driver-key isolation & hot hit (bins=${N_BIN_A}->${N_BIN_B1}->${N_BIN_B2}, LINK=${WLOG_B1}->${WLOG_B2})"

# 3. Cross-target Windows COFF verification (MinGW + Clang MSVC assembler/lld-link).
CLANG_BIN="$(command -v clang 2>/dev/null || true)"
if [ -z "$CLANG_BIN" ] && [ -x "/c/Program Files/LLVM/bin/clang.exe" ]; then
  CLANG_BIN="/c/Program Files/LLVM/bin/clang.exe"
fi
if [ -n "$CLANG_BIN" ]; then
  "$CLANG_BIN" --target=x86_64-pc-windows-msvc -Wa,-mbig-obj -c "$WIN_ASM" -o "$TMP/pkg_a_msvc.o"
  echo "[PASS] p98: clang --target=x86_64-pc-windows-msvc -Wa,-mbig-obj assembled amd64_win .s"
fi

QBE_BIN="${PION_QBE:-$ROOT_DIR/out/qbe}"
if [ -x "$QBE_BIN" ]; then
  cat > "$TMP/dup1.ssa" <<'EOF'
export function w $dup_strong() {
@s
  ret 1
}
export function w $main() {
@s
  %r =w call $dup_strong()
  ret %r
}
EOF
  cat > "$TMP/dup2.ssa" <<'EOF'
export function w $dup_strong() {
@s
  ret 2
}
EOF
  "$QBE_BIN" -t amd64_win -o "$TMP/dup1.s" "$TMP/dup1.ssa"
  "$QBE_BIN" -t amd64_win -o "$TMP/dup2.s" "$TMP/dup2.ssa"

  # Same-named non-exported local `.data$pion_str_0_hdr` with `.linkonce one_only`
  # across two COFF objects must stay isolated (distinguishable first bytes
  # 'A' vs 'B') while an unreferenced 64 KB local dead data section is GC'd.
  cat > "$TMP/loc1.ssa" <<'EOF'
data $pion_str_0_hdr = { b "AAA_LOCAL_1111", b 0 }
data $dead_local_blob = { b "DEAD_LOCAL_BLOB_SENTINEL", z 65536 }
export function l $get_a() {
@s
  ret $pion_str_0_hdr
}
export function w $main() {
@s
  %a =l call $get_a()
  %b =l call $get_b()
  %x =l loadub %a
  %y =l loadub %b
  %x1000 =l mul %x, 1000
  %z =l add %x1000, %y
  %r =w copy %z
  ret %r
}
EOF
  cat > "$TMP/loc2.ssa" <<'EOF'
data $pion_str_0_hdr = { b "BBB_LOCAL_2222", b 0 }
export function l $get_b() {
@s
  ret $pion_str_0_hdr
}
EOF
  "$QBE_BIN" -t amd64_win -o "$TMP/loc1.s" "$TMP/loc1.ssa"
  "$QBE_BIN" -t amd64_win -o "$TMP/loc2.s" "$TMP/loc2.ssa"
fi

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  MINGW_NM="x86_64-w64-mingw32-nm"
  command -v "$MINGW_NM" >/dev/null 2>&1 || MINGW_NM="nm"
  MINGW_AR="x86_64-w64-mingw32-ar"
  command -v "$MINGW_AR" >/dev/null 2>&1 || MINGW_AR="ar"
  WIN_EXE="$TMP/app_win_gc.exe"
  env -u PION_RT_LIB CC=x86_64-w64-mingw32-gcc "$PIONC" build --release --target amd64_win -o "$WIN_EXE" "$WS/app"
  # MinGW GCC's default PE linker script KEEP()s `.pdata*` for C sources unless
  # compiled with `-fno-asynchronous-unwind-tables`, so check Pion QBE symbols here.
  "$MINGW_NM" --defined-only "$WIN_EXE" > "$TMP/win_nm.txt"
  if grep -q 'dead_bloat_fn_0\|dead_match_jtbl_fn\|dead_priv_local_fn' "$TMP/win_nm.txt"; then
    echo "FAIL: dead Pion symbols survived in MinGW amd64_win .exe" >&2
    exit 1
  fi
  cp "$WS/app/pion.toml" "$WS/app/pion.toml.bak"
  cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }

[link.windows]
flags = ["-Wl,--no-gc-sections"]
EOF
  WIN_NOGC="$TMP/app_win_nogc.exe"
  env -u PION_RT_LIB CC=x86_64-w64-mingw32-gcc "$PIONC" build --release --target amd64_win -o "$WIN_NOGC" "$WS/app"
  mv "$WS/app/pion.toml.bak" "$WS/app/pion.toml"
  WSZ_GC="$(wc -c < "$WIN_EXE" | tr -d ' ')"
  WSZ_NOGC="$(wc -c < "$WIN_NOGC" | tr -d ' ')"
  WDIFF=$((WSZ_NOGC - WSZ_GC))
  echo "[PASS] p98: MinGW cross amd64_win GC=${WSZ_GC}B vs no-GC=${WSZ_NOGC}B (saved ${WDIFF}B)"
  if [ "$WDIFF" -lt 32768 ]; then
    echo "FAIL: expected >=32KB savings on MinGW amd64_win (saved ${WDIFF}B)" >&2
    exit 1
  fi

  if [ -x "$QBE_BIN" ]; then
    x86_64-w64-mingw32-gcc -Wa,-mbig-obj -c "$TMP/dup1.s" -o "$TMP/dup1.o"
    x86_64-w64-mingw32-gcc -Wa,-mbig-obj -c "$TMP/dup2.s" -o "$TMP/dup2.o"
    # Positive control: dup1.o alone MUST link cleanly, and -Xlinker --stack -Xlinker 33554432,65536 sets PE32+ header.
    x86_64-w64-mingw32-gcc -Wl,--gc-sections -Xlinker --stack -Xlinker 33554432,65536 "$TMP/dup1.o" -o "$TMP/dup_ok.exe"
    python3 - "$TMP/dup_ok.exe" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
assert data[:2] == b"MZ"
pe_off = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe_off:pe_off + 4] == b"PE\0\0"
opt_off = pe_off + 24
assert struct.unpack_from("<H", data, opt_off)[0] == 0x20B
reserve, commit = struct.unpack_from("<QQ", data, opt_off + 72)
assert reserve == 33554432 and commit == 65536, f"FAIL(mingw): reserve={reserve} commit={commit}"
PYEOF
    # Negative check: dup1.o + dup2.o MUST fail and explicitly name dup_strong.
    if x86_64-w64-mingw32-gcc -Wl,--gc-sections "$TMP/dup1.o" "$TMP/dup2.o" -o "$TMP/dup.exe" 2>"$TMP/dup_err.txt"; then
      echo "FAIL: duplicate strong symbol unexpectedly linked cleanly on MinGW" >&2
      exit 1
    fi
    if ! grep -q 'dup_strong' "$TMP/dup_err.txt"; then
      echo "FAIL: MinGW duplicate strong symbol error did not name dup_strong: $(cat "$TMP/dup_err.txt")" >&2
      exit 1
    fi
    echo "[PASS] p98: duplicate strong symbol rejected on MinGW COFF (single-obj OK, dup named dup_strong)"

    x86_64-w64-mingw32-gcc -Wa,-mbig-obj -c "$TMP/loc1.s" -o "$TMP/loc1.o"
    x86_64-w64-mingw32-gcc -Wa,-mbig-obj -c "$TMP/loc2.s" -o "$TMP/loc2.o"
    x86_64-w64-mingw32-gcc -Wl,--gc-sections "$TMP/loc1.o" "$TMP/loc2.o" -o "$TMP/loc_gc.exe"
    x86_64-w64-mingw32-gcc -Wl,--no-gc-sections "$TMP/loc1.o" "$TMP/loc2.o" -o "$TMP/loc_nogc.exe"
    python3 - "$TMP/loc_gc.exe" "$TMP/loc_nogc.exe" "$UNAME_S" <<'PYEOF'
import os, re, subprocess, sys
gc_exe, nogc_exe, uname_s = sys.argv[1], sys.argv[2], sys.argv[3]
gc_bytes = open(gc_exe, "rb").read()
nogc_sz = os.path.getsize(nogc_exe)
pos_a = gc_bytes.find(b"AAA_LOCAL_1111")
pos_b = gc_bytes.find(b"BBB_LOCAL_2222")
assert pos_a >= 0, "FAIL: loc1 local string missing"
assert pos_b >= 0, "FAIL: loc2 local string missing (merged across .o!)"
assert pos_a != pos_b, "FAIL: local strings aliased to same offset"
assert b"DEAD_LOCAL_BLOB_SENTINEL" not in gc_bytes, "FAIL: dead local 64KB data survived GC"
assert nogc_sz - len(gc_bytes) >= 65536, f"FAIL: expected >=64KB savings from local dead data GC (saved {nogc_sz - len(gc_bytes)}B)"

if uname_s.startswith(("MINGW", "MSYS", "CYGWIN")):
    rc = subprocess.run([gc_exe]).returncode
    assert rc == 65066, f"FAIL: expected exit code 65066 (ord('A')*1000+ord('B')), got {rc}"
else:
    dis = subprocess.check_output(["x86_64-w64-mingw32-objdump", "-d", gc_exe], text=True)
    dat = subprocess.check_output(["x86_64-w64-mingw32-objdump", "-s", "-j", ".data", gc_exe], text=True)
    mem = {}
    for line in dat.splitlines():
        m = re.match(r"^\s*([0-9a-fA-F]+)\s+((?:[0-9a-fA-F]{8}\s+){1,4})", line)
        if not m:
            continue
        va = int(m.group(1), 16)
        hex_str = "".join(m.group(2).split())
        raw = bytes.fromhex(hex_str)
        for off, b in enumerate(raw):
            mem[va + off] = b
    def read_cstr(va):
        out = bytearray()
        while va in mem and mem[va] != 0 and len(out) < 64:
            out.append(mem[va])
            va += 1
        return bytes(out)
    cur_fn = None
    fn_va = {}
    for line in dis.splitlines():
        mf = re.match(r"^[0-9a-fA-F]+\s+<([^>]+)>:", line)
        if mf:
            cur_fn = mf.group(1)
            continue
        if cur_fn in ("get_a", "get_b") and "lea" in line and "%rip" in line and "#" in line:
            mt = re.search(r"#\s*([0-9a-fA-F]+)", line)
            if mt and cur_fn not in fn_va:
                fn_va[cur_fn] = int(mt.group(1), 16)
    assert "get_a" in fn_va and "get_b" in fn_va, f"FAIL: could not resolve RIP targets for get_a/get_b: {fn_va}"
    sa = read_cstr(fn_va["get_a"])
    sb = read_cstr(fn_va["get_b"])
    assert sa == b"AAA_LOCAL_1111", f"FAIL: get_a resolved to {sa!r}, expected b'AAA_LOCAL_1111'"
    assert sb == b"BBB_LOCAL_2222", f"FAIL: get_b resolved to {sb!r}, expected b'BBB_LOCAL_2222'"
PYEOF
    echo "[PASS] p98: same-name local .linkonce one_only binding verified (get_a->AAA, get_b->BBB) & 64KB dead local data GC'd"
  fi

  # >65,279 COFF sections big-obj assemble + archive + link test (asm).
  python3 - "$TMP/bigobj.s" <<'PYEOF'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(66000):
        f.write(f'.section .text$f_{i},"xr"\n.linkonce one_only\n.globl f_{i}\nf_{i}:\n\tret\n')
    f.write('.section .text$main,"xr"\n.linkonce one_only\n.globl main\nmain:\n\tcall f_0\n\txorl %eax,%eax\n\tret\n')
PYEOF
  # GNU as takes ~20-35 s on each >65,279-section object: this one and the
  # c_sources one below are built in their own process groups and joined at the end.
  bg_start "$TMP/bigobj.log" sh -euc '
    x86_64-w64-mingw32-gcc -Wa,-mbig-obj -c "$1/bigobj.s" -o "$1/bigobj.o"
    "$2" rcs "$1/libbigobj.a" "$1/bigobj.o"
    x86_64-w64-mingw32-gcc -Wl,--gc-sections "$1/bigobj.o" -o "$1/bigobj.exe"
  ' bigobj "$TMP" "$MINGW_AR"
  BIGOBJ_PID="$BG_PID"

  # Real manifest `c_sources` >65,600-section COFF big-obj via `pionc build --target amd64_win`.
  CBIG="$TMP/c_bigobj_pkg"
  mkdir -p "$CBIG/src" "$CBIG/csrc"
  cat > "$CBIG/pion.toml" <<'EOF'
[package]
name = "c_bigobj_pkg"
version = "0.1.0"

[link]
c_sources = ["csrc/big.c"]
EOF
  cat > "$CBIG/src/main.pion" <<'EOF'
extern "C" fn cbig_live() -> Int

pub fn main(world : World) -> Int {
  io_println(world, cbig_live().to_string())
  0
}
EOF
  python3 - "$CBIG/csrc/big.c" <<'PYEOF'
import sys
with open(sys.argv[1], "w") as f:
    f.write("#include <stdint.h>\nint64_t cbig_live(void) { return 42; }\n")
    for i in range(65600):
        f.write(f"int cbig_d_{i} = {i + 1};\n")
    for i in range(16):
        f.write(f"int cbig_f_{i}(void) {{ return cbig_d_{i}; }}\n")
PYEOF
  bg_start "$TMP/cbig.log" sh -euc '
    env -u PION_RT_LIB CC=x86_64-w64-mingw32-gcc PION_CACHE_DIR="$1/cas_cbig" \
      "$2" build --release --target amd64_win -o "$1/c_bigobj.exe" "$3"
    # Confirm big.c genuinely exceeds the 65,279-section standard COFF limit (COFF BigObj).
    python3 - "$1/cas_cbig" <<'\''PYEOF'\''
import glob, os, struct, sys
max_sec = 0
for p in glob.glob(os.path.join(sys.argv[1], "**", "*.o"), recursive=True):
    with open(p, "rb") as f:
        hdr = f.read(56)
    if len(hdr) >= 56:
        sig1, sig2, ver = struct.unpack_from("<HHH", hdr, 0)
        if sig1 == 0 and sig2 == 0xFFFF and ver >= 2:
            nsec = struct.unpack_from("<I", hdr, 44)[0]
            if nsec > max_sec:
                max_sec = nsec
assert max_sec > 65279, f"FAIL: expected COFF BigObj (>65279 sections) in {sys.argv[1]}, max={max_sec}"
print(f"p98 c_bigobj COFF BigObj verified: {max_sec} sections (>65279)")
PYEOF
  ' cbig "$TMP" "$PIONC" "$CBIG"
  CBIG_PID="$BG_PID"
fi

# 4. MSVC lld-link & link.exe verification (runs whenever clang + lld-link / link.exe are available).
LLD_LINK="$(command -v lld-link 2>/dev/null || command -v lld-link-19 2>/dev/null || true)"
if [ -z "$LLD_LINK" ] && [ -x "/c/Program Files/LLVM/bin/lld-link.exe" ]; then
  LLD_LINK="/c/Program Files/LLVM/bin/lld-link.exe"
fi
MSVC_LINK=""
case "$UNAME_S" in
  MINGW*|MSYS*|CYGWIN*)
    VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if [ -x "$VSWHERE" ]; then
      VS_PATH="$("$VSWHERE" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null | tr -d '\r' || true)"
      if [ -n "$VS_PATH" ]; then
        if command -v cygpath >/dev/null 2>&1; then
          VS_PATH_U="$(cygpath -u "$VS_PATH")"
        else
          VS_PATH_U="$VS_PATH"
        fi
        MSVC_LINK="$(find "$VS_PATH_U/VC/Tools/MSVC" -path '*/bin/Hostx64/x64/link.exe' 2>/dev/null | sort | tail -n 1 || true)"
      fi
    fi
    ;;
esac

if command -v cygpath >/dev/null 2>&1; then
  TMP_NAT="$(cygpath -w "$TMP")"
  NAT_SEP='\'
else
  TMP_NAT="$TMP"
  NAT_SEP='/'
fi

run_msvc_linker_checks() {
  LNAME="$1"
  LBIN="$2"
  "$CLANG_BIN" --target=x86_64-pc-windows-msvc -Wa,-mbig-obj -c "$TMP/dup1.s" -o "$TMP/dup1_${LNAME}.o"
  "$CLANG_BIN" --target=x86_64-pc-windows-msvc -Wa,-mbig-obj -c "$TMP/dup2.s" -o "$TMP/dup2_${LNAME}.o"
  MSYS2_ARG_CONV_EXCL="*" "$LBIN" /NOLOGO "/OUT:${TMP_NAT}${NAT_SEP}dup_${LNAME}_ok.exe" /ENTRY:main /SUBSYSTEM:CONSOLE /OPT:REF /OPT:NOICF /INCREMENTAL:NO "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o"
  if MSYS2_ARG_CONV_EXCL="*" "$LBIN" /NOLOGO "/OUT:${TMP_NAT}${NAT_SEP}dup_${LNAME}_fail.exe" /ENTRY:main /SUBSYSTEM:CONSOLE /OPT:REF /OPT:NOICF /INCREMENTAL:NO "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o" "${TMP_NAT}${NAT_SEP}dup2_${LNAME}.o" >"$TMP/dup_${LNAME}_err.txt" 2>&1; then
    echo "FAIL: duplicate strong symbol unexpectedly linked cleanly on ${LNAME}" >&2
    exit 1
  fi
  if ! grep -q 'dup_strong' "$TMP/dup_${LNAME}_err.txt"; then
    echo "FAIL: ${LNAME} duplicate strong symbol error did not name dup_strong: $(cat "$TMP/dup_${LNAME}_err.txt")" >&2
    exit 1
  fi
  "$CLANG_BIN" --target=x86_64-pc-windows-msvc -Wa,-mbig-obj -c "$TMP/loc1.s" -o "$TMP/loc1_${LNAME}.o"
  "$CLANG_BIN" --target=x86_64-pc-windows-msvc -Wa,-mbig-obj -c "$TMP/loc2.s" -o "$TMP/loc2_${LNAME}.o"
  MSYS2_ARG_CONV_EXCL="*" "$LBIN" /NOLOGO "/OUT:${TMP_NAT}${NAT_SEP}loc_${LNAME}_gc.exe" /ENTRY:main /SUBSYSTEM:CONSOLE /OPT:REF /OPT:NOICF /INCREMENTAL:NO "${TMP_NAT}${NAT_SEP}loc1_${LNAME}.o" "${TMP_NAT}${NAT_SEP}loc2_${LNAME}.o"
  MSYS2_ARG_CONV_EXCL="*" "$LBIN" /NOLOGO "/OUT:${TMP_NAT}${NAT_SEP}loc_${LNAME}_nogc.exe" /ENTRY:main /SUBSYSTEM:CONSOLE /OPT:NOREF /OPT:NOICF /INCREMENTAL:NO "${TMP_NAT}${NAT_SEP}loc1_${LNAME}.o" "${TMP_NAT}${NAT_SEP}loc2_${LNAME}.o"
  python3 - "$TMP/loc_${LNAME}_gc.exe" "$TMP/loc_${LNAME}_nogc.exe" "$UNAME_S" "$LNAME" <<'PYEOF'
import os, subprocess, sys
gc_exe, nogc_exe, uname_s, lname = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
gc_bytes = open(gc_exe, "rb").read()
nogc_sz = os.path.getsize(nogc_exe)
assert b"AAA_LOCAL_1111" in gc_bytes, f"FAIL: {lname} loc1 local string missing"
assert b"BBB_LOCAL_2222" in gc_bytes, f"FAIL: {lname} loc2 local string missing"
assert b"DEAD_LOCAL_BLOB_SENTINEL" not in gc_bytes, f"FAIL: {lname} dead local 64KB data survived /OPT:REF"
assert nogc_sz - len(gc_bytes) >= 65536, f"FAIL: {lname} expected >=64KB savings (saved {nogc_sz - len(gc_bytes)}B)"
if uname_s.startswith(("MINGW", "MSYS", "CYGWIN")):
    rc = subprocess.run([gc_exe]).returncode
    assert rc == 65066, f"FAIL: {lname} expected exit code 65066, got {rc}"
PYEOF
  # Real link with unpacked `-Wl,/OPT:REF -Wl,/OPT:ICF`, `-Wl,/OPT:NOREF -Wl,/INCREMENTAL:NO`,
  # and `/STACK:33554432,65536` (verified against PE32+ Optional Header).
  MSYS2_ARG_CONV_EXCL="*" "$LBIN" /NOLOGO "/OUT:${TMP_NAT}${NAT_SEP}stack_rc_${LNAME}.exe" /ENTRY:main /SUBSYSTEM:CONSOLE /STACK:33554432,65536 /OPT:REF /OPT:NOICF /INCREMENTAL:NO "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o"
  check_pe_stack_hdr() {
    python3 - "$1" "$2" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
label = sys.argv[2]
assert data[:2] == b"MZ", f"FAIL({label}): not MZ PE"
pe_off = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe_off:pe_off + 4] == b"PE\0\0", f"FAIL({label}): missing PE signature"
opt_off = pe_off + 24
magic = struct.unpack_from("<H", data, opt_off)[0]
assert magic == 0x20B, f"FAIL({label}): expected PE32+ magic 0x20B, got {hex(magic)}"
reserve, commit = struct.unpack_from("<QQ", data, opt_off + 72)
assert reserve == 33554432 and commit == 65536, \
    f"FAIL({label}): expected stack reserve=33554432 commit=65536, got reserve={reserve} commit={commit}"
PYEOF
  }
  check_pe_stack_hdr "$TMP/stack_rc_${LNAME}.exe" "${LNAME}_direct"
  if [ "$LNAME" = "lld" ]; then
    MSYS2_ARG_CONV_EXCL="*" "$CLANG_BIN" --target=x86_64-pc-windows-msvc -fuse-ld=lld -nostdlib \
      -Wl,/ENTRY:main -Wl,/SUBSYSTEM:CONSOLE -Wl,/OPT:REF -Wl,/OPT:ICF -Wl,/INCREMENTAL:NO \
      "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o" -o "${TMP_NAT}${NAT_SEP}opt_combo_${LNAME}.exe"
    MSYS2_ARG_CONV_EXCL="*" "$CLANG_BIN" --target=x86_64-pc-windows-msvc -fuse-ld=lld -nostdlib \
      -Wl,/ENTRY:main -Wl,/SUBSYSTEM:CONSOLE -Wl,/OPT:NOREF -Wl,/INCREMENTAL:NO \
      "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o" -o "${TMP_NAT}${NAT_SEP}opt_noref_${LNAME}.exe"
    MSYS2_ARG_CONV_EXCL="*" "$CLANG_BIN" --target=x86_64-pc-windows-msvc -fuse-ld=lld -nostdlib \
      -Wl,/ENTRY:main -Wl,/SUBSYSTEM:CONSOLE -Xlinker /STACK:33554432,65536 -Wl,/OPT:REF -Wl,/OPT:NOICF -Wl,/INCREMENTAL:NO \
      "${TMP_NAT}${NAT_SEP}dup1_${LNAME}.o" -o "${TMP_NAT}${NAT_SEP}stack_rc_clang_${LNAME}.exe"
    check_pe_stack_hdr "$TMP/stack_rc_clang_${LNAME}.exe" "${LNAME}_clang_xlinker"
  fi
  echo "[PASS] p98: ${LNAME} MSVC COFF dup_strong rejection + local isolation + /OPT:REF 64KB dead data GC + /STACK:33554432,65536 PE32+ header"
}

RAN_LLD_LINK=0
RAN_MSVC_LINK=0
if [ -n "$CLANG_BIN" ] && [ -x "$QBE_BIN" ]; then
  if [ -n "$LLD_LINK" ]; then
    run_msvc_linker_checks lld "$LLD_LINK"
    RAN_LLD_LINK=1
  fi
  if [ -n "$MSVC_LINK" ] && [ -x "$MSVC_LINK" ]; then
    run_msvc_linker_checks msvc "$MSVC_LINK"
    RAN_MSVC_LINK=1
  fi
fi
if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*)
      if [ "$RAN_LLD_LINK" -ne 1 ] || [ "$RAN_MSVC_LINK" -ne 1 ]; then
        echo "FAIL: Windows CI requires BOTH lld-link (ran=${RAN_LLD_LINK}) and Microsoft link.exe (ran=${RAN_MSVC_LINK}) to pass (clang=${CLANG_BIN:-none} lld-link=${LLD_LINK:-none} link.exe=${MSVC_LINK:-none})" >&2
        exit 1
      fi
      ;;
  esac
fi

# 5. End-to-end pion.toml -> pionc build --target amd64_win -> clang-cl /link forwarding
# verified via native C `clang-cl` shim invoking `clang --driver-mode=cl -###`.
if [ -n "$CLANG_BIN" ]; then
  CL_DIR="$TMP/cl_shim_bin"
  mkdir -p "$CL_DIR"
  cat > "$TMP/clang_cl_shim.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <process.h>
/* Quote a single argv element using Microsoft CRT CommandLineToArgvW rules so
 * _spawnvp preserves spaces/quotes (e.g. C:\Program Files\LLVM\bin\clang.exe). */
static char *quote_win_arg(const char *arg) {
    int need_quote = (*arg == '\0');
    for (const char *p = arg; *p; p++) {
        if (*p == ' ' || *p == '\t' || *p == '"') {
            need_quote = 1;
            break;
        }
    }
    if (!need_quote) {
        size_t len = strlen(arg);
        char *out = (char *)malloc(len + 1);
        if (!out) return NULL;
        memcpy(out, arg, len + 1);
        return out;
    }
    size_t cap = strlen(arg) * 2 + 3;
    char *out = (char *)malloc(cap);
    if (!out) return NULL;
    char *w = out;
    *w++ = '"';
    for (const char *p = arg; *p; ) {
        size_t bs = 0;
        while (*p == '\\') { bs++; p++; }
        if (*p == '\0') {
            for (size_t i = 0; i < bs * 2; i++) *w++ = '\\';
            break;
        } else if (*p == '"') {
            for (size_t i = 0; i < bs * 2 + 1; i++) *w++ = '\\';
            *w++ = '"';
            p++;
        } else {
            for (size_t i = 0; i < bs; i++) *w++ = '\\';
            *w++ = *p++;
        }
    }
    *w++ = '"';
    *w = '\0';
    return out;
}
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

int main(int argc, char **argv) {
    int is_compile = 0;
    const char *out_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) is_compile = 1;
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out_path = argv[i + 1];
    }
    if (is_compile) {
        if (out_path) {
            FILE *f = fopen(out_path, "wb");
            if (f) { fputs("OBJ", f); fclose(f); }
        }
        return 0;
    }
    const char *argv_log = getenv("P98_CL_ARGV_LOG");
    if (argv_log && *argv_log) {
        FILE *f = fopen(argv_log, "w");
        if (f) {
            for (int i = 1; i < argc; i++) {
                fputs(argv[i], f);
                fputc('\n', f);
            }
            fclose(f);
        }
    }
    const char *dry_log = getenv("P98_CL_DRY_LOG");
    const char *real_clang = getenv("P98_REAL_CLANG");
    if (!real_clang || !*real_clang) real_clang = "clang";
    char **nargv = (char **)malloc((size_t)(argc + 5) * sizeof(char *));
    if (!nargv) return 127;
    int k = 0;
    nargv[k++] = (char *)real_clang;
    nargv[k++] = "--driver-mode=cl";
    nargv[k++] = "--target=x86_64-pc-windows-msvc";
    nargv[k++] = "-###";
    for (int i = 1; i < argc; i++) nargv[k++] = argv[i];
    nargv[k] = NULL;
    int rc = 0;
#ifdef _WIN32
    if (dry_log && *dry_log) freopen(dry_log, "w", stderr);
    char **qargv = (char **)malloc((size_t)(k + 1) * sizeof(char *));
    if (!qargv) { free(nargv); return 127; }
    for (int i = 0; i < k; i++) {
        qargv[i] = quote_win_arg(nargv[i]);
        if (!qargv[i]) {
            for (int j = 0; j < i; j++) free(qargv[j]);
            free(qargv);
            free(nargv);
            return 127;
        }
    }
    qargv[k] = NULL;
    rc = (int)_spawnvp(_P_WAIT, real_clang, (const char *const *)qargv);
    for (int i = 0; i < k; i++) free(qargv[i]);
    free(qargv);
#else
    pid_t pid = fork();
    if (pid == 0) {
        if (dry_log && *dry_log) {
            if (!freopen(dry_log, "w", stderr)) _exit(126);
        }
        execvp(real_clang, nargv);
        _exit(127);
    }
    int st = 0;
    if (pid > 0 && waitpid(pid, &st, 0) > 0 && WIFEXITED(st)) {
        rc = WEXITSTATUS(st);
    } else {
        rc = 127;
    }
#endif
    free(nargv);
    if (rc == 0 && out_path) {
        FILE *f = fopen(out_path, "wb");
        if (f) { fputs("EXE", f); fclose(f); }
    }
    return rc;
}
EOF
  CL_SHIM="$CL_DIR/clang-cl"
  case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) CL_SHIM="$CL_DIR/clang-cl.exe" ;;
  esac
  "$ORIG_CC" -O1 "$TMP/clang_cl_shim.c" -o "$CL_SHIM"
  DUMMY_RT="$TMP/dummy_win_rt.a"
  printf '!<arch>\n' > "$DUMMY_RT"
  CL_PKG="$TMP/cl_pkg"
  mkdir -p "$CL_PKG/src"
  cat > "$CL_PKG/src/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "cl_ok")
  0
}
EOF
  for CASE in bare_noref multi_wl stack_rc wl_stack_map wl_stack_rc_map; do
    if [ "$CASE" = "bare_noref" ]; then
      FLAGS_LINE='flags = ["/OPT:NOREF"]'
    elif [ "$CASE" = "multi_wl" ]; then
      FLAGS_LINE='flags = ["-Wl,/OPT:NOREF,/INCREMENTAL:NO"]'
    elif [ "$CASE" = "stack_rc" ]; then
      FLAGS_LINE='flags = ["/STACK:33554432,65536"]'
    elif [ "$CASE" = "wl_stack_map" ]; then
      FLAGS_LINE='flags = ["-Wl,--stack,33554432,/MAP"]'
    else
      FLAGS_LINE='flags = ["-Wl,--stack,33554432,65536,/MAP"]'
    fi
    cat > "$CL_PKG/pion.toml" <<EOF
[package]
name = "cl_pkg"
version = "0.1.0"

[link.windows]
$FLAGS_LINE
EOF
    CL_ARGV_LOG="$TMP/cl_argv_${CASE}.log"
    CL_DRY_LOG="$TMP/cl_dry_${CASE}.log"
    CL_ARGV_LOG_NAT="${TMP_NAT}${NAT_SEP}cl_argv_${CASE}.log"
    CL_DRY_LOG_NAT="${TMP_NAT}${NAT_SEP}cl_dry_${CASE}.log"
    CLANG_BIN_NAT="$CLANG_BIN"
    if command -v cygpath >/dev/null 2>&1; then
      CLANG_BIN_NAT="$(cygpath -w "$CLANG_BIN")"
    fi
    rm -f "$CL_ARGV_LOG" "$CL_DRY_LOG" "$TMP/cl_out_${CASE}.exe"
    PION_CACHE_DIR="$TMP/cas_cl_${CASE}" \
      PION_RT_LIB="$DUMMY_RT" \
      P98_REAL_CLANG="$CLANG_BIN_NAT" \
      P98_CL_ARGV_LOG="$CL_ARGV_LOG_NAT" \
      P98_CL_DRY_LOG="$CL_DRY_LOG_NAT" \
      CC="$CL_SHIM" \
      "$PIONC" build --release --target amd64_win -o "$TMP/cl_out_${CASE}.exe" "$CL_PKG"
    python3 - "$CL_ARGV_LOG" "$CL_DRY_LOG" "$CASE" <<'PYEOF'
import sys
argv_lines = [l.strip() for l in open(sys.argv[1]).read().splitlines() if l.strip()]
dry_txt = open(sys.argv[2]).read()
case = sys.argv[3]
assert "/link" in argv_lines, f"FAIL({case}): /link missing from clang-cl argv: {argv_lines}"
link_idx = argv_lines.index("/link")
before = [a.upper() for a in argv_lines[:link_idx]]
after = [a.upper() for a in argv_lines[link_idx + 1:]]
for a in before:
    assert not a.startswith("/OPT:") and not a.startswith("-OPT:") and not a.startswith("/INCREMENTAL") and not a.startswith("-INCREMENTAL") and not a.startswith("/STACK:") and not a.startswith("-STACK:"), \
        f"FAIL({case}): linker opt leaked before /link: {argv_lines}"
assert "argument unused during compilation" not in dry_txt, \
    f"FAIL({case}): clang --driver-mode=cl reported unused argument:\n{dry_txt}"
dry_up = dry_txt.upper()
if case == "stack_rc":
    assert "/STACK:33554432,65536" in after, f"FAIL({case}): intact /STACK:33554432,65536 missing after /link: {after}"
    assert "65536" not in before and "65536" not in after, f"FAIL({case}): comma-split 65536 leaked into argv: {argv_lines}"
    assert "/STACK:16777216" not in after, f"FAIL({case}): conflicting default /STACK:16777216 after /link: {after}"
    assert "/STACK:33554432,65536" in dry_up, f"FAIL({case}): clang -### linker line missing /STACK:33554432,65536:\n{dry_txt}"
elif case == "wl_stack_map":
    assert "/STACK:33554432" in after, f"FAIL({case}): /STACK:33554432 missing after /link: {after}"
    assert "/MAP" in after, f"FAIL({case}): standalone /MAP missing after /link: {after}"
    assert "/STACK:16777216" not in after, f"FAIL({case}): conflicting default /STACK:16777216 after /link: {after}"
    assert '"/MAP"' in dry_up or " /MAP" in dry_up, f"FAIL({case}): clang -### linker line missing /MAP:\n{dry_txt}"
    assert "/STACK:33554432" in dry_up, f"FAIL({case}): clang -### linker line missing /STACK:33554432:\n{dry_txt}"
elif case == "wl_stack_rc_map":
    assert "/STACK:33554432,65536" in after, f"FAIL({case}): intact /STACK:33554432,65536 missing after /link: {after}"
    assert "/MAP" in after, f"FAIL({case}): standalone /MAP missing after /link: {after}"
    assert "65536" not in before and "65536" not in after, f"FAIL({case}): comma-split 65536 leaked into argv: {argv_lines}"
    assert "/STACK:16777216" not in after, f"FAIL({case}): conflicting default /STACK:16777216 after /link: {after}"
    assert '"/MAP"' in dry_up or " /MAP" in dry_up, f"FAIL({case}): clang -### linker line missing /MAP:\n{dry_txt}"
    assert "/STACK:33554432,65536" in dry_up, f"FAIL({case}): clang -### linker line missing /STACK:33554432,65536:\n{dry_txt}"
else:
    assert "/OPT:NOREF" in after, f"FAIL({case}): /OPT:NOREF missing after /link: {after}"
    assert "/OPT:REF" not in after, f"FAIL({case}): conflicting /OPT:REF after /link: {after}"
    assert "/INCREMENTAL:NO" in after, f"FAIL({case}): /INCREMENTAL:NO missing after /link: {after}"
    assert "/OPT:NOREF" in dry_up, f"FAIL({case}): clang -### linker line missing /OPT:NOREF:\n{dry_txt}"
    assert '"/OPT:REF"' not in dry_up and " /OPT:REF" not in dry_up, \
        f"FAIL({case}): clang -### linker line unexpectedly has /OPT:REF:\n{dry_txt}"
PYEOF
  done
  echo "[PASS] p98: pion.toml -> pionc -> clang-cl /link forwarding verified via clang --driver-mode=cl -### (5 cases incl. /STACK:reserve,commit & trailing /MAP)"
fi

# Join the two big-obj builds of section 3.
if [ -n "$CBIG_PID" ]; then
  if ! bg_join "$CBIG_PID" "$TMP/cbig.log"; then
    CBIG_PID=""
    echo "FAIL: p98: c_sources >65,600-section COFF big-obj build failed" >&2
    exit 1
  fi
  CBIG_PID=""
  echo "[PASS] p98: real manifest c_sources >65,600-section COFF big-obj compiled & linked via pionc"
fi
if [ -n "$BIGOBJ_PID" ]; then
  if ! bg_join "$BIGOBJ_PID" "$TMP/bigobj.log"; then
    BIGOBJ_PID=""
    echo "FAIL: p98: 66,000-section COFF big-obj assemble/archive/GC-link failed" >&2
    exit 1
  fi
  BIGOBJ_PID=""
  echo "[PASS] p98: 66,000-section COFF big-obj assembled, archived, and GC-linked"
fi

echo "ALL p98_section_gc CHECKS PASSED!"
