#!/bin/sh
# Regression E2E for QBE .rodata / .bss data section governance:
#   1. Read-only literals (strings, immortal enums, Option::None, i32 literal words)
#      land in per-symbol GC-able .rodata (ELF), __TEXT,__const (Mach-O), or .rdata (COFF).
#   2. Zero-initialized mutable globals (init guards, const slots) land in .bss.
#   3. Unused string literals are eliminated by --gc-sections / -dead_strip.
#   4. Relocated tables (dyn Trait vtables, i32_literal_tables descriptors) stay in
#      writable .data and link & execute cleanly under PIE / read-only .rodata.
#   5. Multi-target QBE asm & direct ELF64 .o section/flag checks.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

SRC="$TMP_DIR/rodata_bss.pion"
python3 - "$SRC" << 'PY'
import sys
nums = ", ".join(str(i) for i in range(1, 1025))
code = f"""pub enum Mode {{
  Idle
  Active(Bool)
  Code(Int)
}}

pub trait Label {{
  fn label(self : Self) -> String
}}

pub struct Item {{
  n : Int
}}

impl Label for Item {{
  fn label(self : Item) -> String {{
    "LIVE_VTABLE_SENTINEL_" + self.n.to_string()
  }}
}}

pub let GLOBAL_BANNER : String = "LIVE_RODATA_SENTINEL"

fn dead_helper() -> String {{
  "DEAD_RODATA_SENTINEL_MUST_BE_GCED"
}}

fn make_i32_table() -> Array[Int] {{
  [{nums}]
}}

fn main(w : World) -> Int {{
  let none_v : Option[Int] = None
  let m1 = Idle
  let m2 = Active(true)
  let it : dyn Label = Item::{{ n: 42 }}
  let tbl = make_i32_table()
  let mut sum = 0
  let mut i = 0
  while i < tbl.length() {{
    sum = sum + tbl[i]
    i = i + 1
  }}
  let a = match none_v {{
    None => 1
    Some(v) => v
  }}
  let b = match m1 {{
    Idle => 2
    Active(f) => if f {{ 3 }} else {{ 4 }}
    Code(k) => k
  }}
  let c = match m2 {{
    Idle => 0
    Active(f) => if f {{ 5 }} else {{ 6 }}
    Code(k) => k
  }}
  io_println(w, GLOBAL_BANNER + "|" + it.label() + "|sum=" + sum.to_string() + "|abc=" + (a + b + c).to_string())
  0
}}
"""
open(sys.argv[1], "w").write(code)
PY

BIN="$TMP_DIR/rodata_bss_bin"
SSA="$TMP_DIR/rodata_bss.ssa"
"$PIONC" build --release --emit-ssa "$SSA" -o "$BIN" "$SRC"
OUT="$("$BIN")"
EXPECTED="LIVE_RODATA_SENTINEL|LIVE_VTABLE_SENTINEL_42|sum=524800|abc=8"
if [ "$OUT" != "$EXPECTED" ]; then
  echo "FAIL: native output mismatch: got '$OUT', expected '$EXPECTED'" >&2
  exit 1
fi

# Verify --gc-sections / -dead_strip eliminated DEAD_RODATA_SENTINEL and kept LIVE_RODATA_SENTINEL.
python3 - "$BIN" << 'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert b"LIVE_RODATA_SENTINEL" in data, "missing LIVE_RODATA_SENTINEL in binary"
assert b"LIVE_VTABLE_SENTINEL_" in data, "missing LIVE_VTABLE_SENTINEL_ in binary"
assert b"DEAD_RODATA_SENTINEL_MUST_BE_GCED" not in data, "DEAD_RODATA_SENTINEL was not GC'd!"
PY

# On Linux ELF, verify LIVE_RODATA_SENTINEL resides in .rodata (not .data).
if [ "$(uname -s)" = "Linux" ] && command -v readelf >/dev/null 2>&1; then
  RO_DUMP="$(readelf -p .rodata "$BIN" 2>/dev/null || true)"
  DATA_DUMP="$(readelf -p .data "$BIN" 2>/dev/null || true)"
  printf '%s' "$RO_DUMP" | grep -q 'LIVE_RODATA_SENTINEL' || {
    echo "FAIL: LIVE_RODATA_SENTINEL not found in ELF .rodata" >&2
    exit 1
  }
  if printf '%s' "$DATA_DUMP" | grep -q 'LIVE_RODATA_SENTINEL'; then
    echo "FAIL: LIVE_RODATA_SENTINEL leaked into writable ELF .data" >&2
    exit 1
  fi
fi

# Multi-target QBE section directives & direct ELF64 .o checks.
MINI_SSA="$TMP_DIR/mini.ssa"
cat > "$MINI_SSA" << 'EOF'
section ".rodata" data $pion_str_0_hdr = align 8 { w 0, w 0, w 1, h 1, h 3, l 0, l 2, b "hi", b 0 }
section ".rodata" data $pion_cstr_0 = { b "ok", b 0 }
section ".rodata" data $pion_none_hdr = align 8 { w 0, w 0, w 1, h 5, h 3, l 0, l 0 }
data $pion_consts_inited = align 4 { z 4 }
export data $pion_const_G = align 8 { z 8 }
export function l $use_str() {
@start
    ret $pion_str_0_hdr
}
EOF

ASM_SYSV="$("$QBE" -t amd64_sysv "$MINI_SSA")"
printf '%s\n' "$ASM_SYSV" | grep -qF '.section .rodata.pion_str_0_hdr,"a",%progbits'
printf '%s\n' "$ASM_SYSV" | grep -qF '.section .bss.pion_consts_inited,"aw",%nobits'
printf '%s\n' "$ASM_SYSV" | grep -qF '.section .bss.pion_const_G,"aw",%nobits'

ASM_ARM64="$("$QBE" -t arm64 "$MINI_SSA")"
printf '%s\n' "$ASM_ARM64" | grep -qF '.section .rodata.pion_str_0_hdr,"a",%progbits'
printf '%s\n' "$ASM_ARM64" | grep -qF '.section .bss.pion_consts_inited,"aw",%nobits'

ASM_APPLE="$("$QBE" -t arm64_apple "$MINI_SSA")"
printf '%s\n' "$ASM_APPLE" | grep -qF '.section __TEXT,__const'

ASM_MINGW="$("$QBE" -t amd64_win "$MINI_SSA")"
printf '%s\n' "$ASM_MINGW" | grep -qF '.section .rdata$pion_str_0_hdr,"dr"'
printf '%s\n' "$ASM_MINGW" | grep -qF '.linkonce one_only'

ASM_SEH="$("$QBE" -t amd64_win --seh "$MINI_SSA")"
printf '%s\n' "$ASM_SEH" | grep -qF '.section .rdata$pion_str_0_hdr,"dr",one_only,pion_str_0_hdr'

if command -v readelf >/dev/null 2>&1; then
  OBJ="$TMP_DIR/mini.o"
  "$QBE" -t amd64_sysv --obj -o "$OBJ" "$MINI_SSA"
  SEC_HDRS="$(readelf -SW "$OBJ")"
  printf '%s\n' "$SEC_HDRS" | grep -E '\.rodata\.pion_str_0_hdr\s+PROGBITS.*A\s' >/dev/null
  printf '%s\n' "$SEC_HDRS" | grep -E '\.bss\.pion_consts_inited\s+NOBITS.*WA\s' >/dev/null
  # private_literal: pion_str_0_hdr must be emitted as STT_SECTION (not named STT_OBJECT)
  if ! readelf -sW "$OBJ" | grep -qE 'SECTION[[:space:]]+LOCAL.*\.rodata\.pion_str_0_hdr'; then
    echo "FAIL: private_literal STT_SECTION missing for .rodata.pion_str_0_hdr" >&2
    exit 1
  fi
  if readelf -sW "$OBJ" | grep -qE 'OBJECT[[:space:]]+LOCAL.*pion_str_0_hdr'; then
    echo "FAIL: private_literal emitted named STT_OBJECT for pion_str_0_hdr" >&2
    exit 1
  fi
fi

# Wasm32 parity check if node is available.
if command -v node >/dev/null 2>&1; then
  WASM_BIN="$TMP_DIR/rodata_bss.wasm"
  "$PIONC" build --release --target wasm32 -o "$WASM_BIN" "$SRC"
  WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$WASM_BIN")"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: wasm32 output mismatch: got '$WASM_OUT', expected '$EXPECTED'" >&2
    exit 1
  fi
fi

echo "[SUMMARY] qbe_rodata_bss: OK"
