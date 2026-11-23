#!/bin/sh
# P74-D E2E cross-platform IEEE-754 saturating float-to-int conversion test:
# Verifies Native (--release + dev) and Wasm32 (Node + Web runtimes) produce
# bit-for-bit identical saturating outputs across NaN, +/-Inf, +/-1e25, +/-2^31,
# 2^31-1, 2^32, +/-2^63, 2^64, -0.0, -1.9, 42.9 for both Double and Float
# via to_int, to_int64, to_int8, as Int, as Int64, as UInt, as UInt64, as Byte, as Int8,
# with ZERO Wasm32 RuntimeError traps.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<'EOF' > "$TMP_DIR/p74d_sat.pion"
fn check_double(
  tag : String,
  x : Double,
  exp_i32 : Int,
  exp_i64 : Int64,
  exp_u32 : UInt,
  exp_u64 : UInt64,
  exp_i8 : Int8,
  exp_b : Byte,
) -> String {
  let m_i32 = x.to_int()
  let m_i64 = x.to_int64()
  let m_i8 = x.to_int8()
  let a_i32 = x as Int
  let a_i64 = x as Int64
  let a_u32 = x as UInt
  let a_u64 = x as UInt64
  let a_i8 = x as Int8
  let a_b = x as Byte
  if m_i32 != exp_i32 || a_i32 != exp_i32 {
    panic("D " + tag + " i32 got=" + m_i32.to_string() + "/" + a_i32.to_string() + " exp=" + exp_i32.to_string())
  }
  if m_i64 != exp_i64 || a_i64 != exp_i64 {
    panic("D " + tag + " i64 got=" + m_i64.to_string() + "/" + a_i64.to_string() + " exp=" + exp_i64.to_string())
  }
  if a_u32 != exp_u32 {
    panic("D " + tag + " u32 got=" + a_u32.to_string() + " exp=" + exp_u32.to_string())
  }
  if a_u64 != exp_u64 {
    panic("D " + tag + " u64 got=" + a_u64.to_string() + " exp=" + exp_u64.to_string())
  }
  if m_i8 != exp_i8 || a_i8 != exp_i8 {
    panic("D " + tag + " i8 got=" + m_i8.to_int().to_string() + "/" + a_i8.to_int().to_string() + " exp=" + exp_i8.to_int().to_string())
  }
  if a_b != exp_b {
    panic("D " + tag + " byte got=" + a_b.to_int().to_string() + " exp=" + exp_b.to_int().to_string())
  }
  tag + ":" + a_i32.to_string() + "," + a_i64.to_string() + "," + a_u32.to_string() + "," + a_u64.to_string() + "," + a_i8.to_int().to_string() + "," + a_b.to_int().to_string()
}

fn check_float(
  tag : String,
  x : Float,
  exp_i32 : Int,
  exp_i64 : Int64,
  exp_u32 : UInt,
  exp_u64 : UInt64,
  exp_i8 : Int8,
  exp_b : Byte,
) -> String {
  let m_i32 = x.to_int()
  let m_i64 = x.to_int64()
  let m_i8 = x.to_int8()
  let a_i32 = x as Int
  let a_i64 = x as Int64
  let a_u32 = x as UInt
  let a_u64 = x as UInt64
  let a_i8 = x as Int8
  let a_b = x as Byte
  if m_i32 != exp_i32 || a_i32 != exp_i32 {
    panic("F " + tag + " i32 got=" + m_i32.to_string() + "/" + a_i32.to_string() + " exp=" + exp_i32.to_string())
  }
  if m_i64 != exp_i64 || a_i64 != exp_i64 {
    panic("F " + tag + " i64 got=" + m_i64.to_string() + "/" + a_i64.to_string() + " exp=" + exp_i64.to_string())
  }
  if a_u32 != exp_u32 {
    panic("F " + tag + " u32 got=" + a_u32.to_string() + " exp=" + exp_u32.to_string())
  }
  if a_u64 != exp_u64 {
    panic("F " + tag + " u64 got=" + a_u64.to_string() + " exp=" + exp_u64.to_string())
  }
  if m_i8 != exp_i8 || a_i8 != exp_i8 {
    panic("F " + tag + " i8 got=" + m_i8.to_int().to_string() + "/" + a_i8.to_int().to_string() + " exp=" + exp_i8.to_int().to_string())
  }
  if a_b != exp_b {
    panic("F " + tag + " byte got=" + a_b.to_int().to_string() + " exp=" + exp_b.to_int().to_string())
  }
  tag + ":" + a_i32.to_string() + "," + a_i64.to_string() + "," + a_u32.to_string() + "," + a_u64.to_string() + "," + a_i8.to_int().to_string() + "," + a_b.to_int().to_string()
}

fn main(world : World) -> Unit {
  let i32_max : Int = 2147483647
  let i32_min : Int = -2147483647 - 1
  let i64_max : Int64 = 9223372036854775807L
  let i64_min : Int64 = -9223372036854775807L - 1L
  let u32_max : UInt = 4294967295U
  let u64_max : UInt64 = 18446744073709551615UL

  let dz = 0.0
  let d1 = 1.0
  let d_nan = dz / dz
  let d_pinf = d1 / dz
  let d_ninf = (0.0 - d1) / dz
  let d_2p31 = 2147483648.0
  let d_n2p31 = -2147483648.0
  let d_2p31m1 = 2147483647.0
  let d_2p32 = 4294967296.0
  let d_2p63 = 9223372036854775808.0
  let d_n2p63 = -9223372036854775808.0
  let d_2p64 = 18446744073709551616.0

  let sb = StringBuilder()
  sb.write_string(check_double("d_nan", d_nan, 0, 0L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_pinf", d_pinf, i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_ninf", d_ninf, i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_1e25", 1.0e25, i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_n1e25", -1.0e25, i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_2p31", d_2p31, i32_max, 2147483648L, 2147483648U, 2147483648UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_n2p31", d_n2p31, i32_min, -2147483648L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_2p31m1", d_2p31m1, i32_max, 2147483647L, 2147483647U, 2147483647UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_2p32", d_2p32, i32_max, 4294967296L, u32_max, 4294967296UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_2p63", d_2p63, i32_max, i64_max, u32_max, 9223372036854775808UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_n2p63", d_n2p63, i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_2p64", d_2p64, i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_n0", -0.0, 0, 0L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_n1p9", -1.9, -1, -1L, 0U, 0UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_double("d_42p9", 42.9, 42, 42L, 42U, 42UL, 42, 42 as Byte))

  let fz : Float = 0.0f
  let f1 : Float = 1.0f
  let f_nan : Float = fz / fz
  let f_pinf : Float = f1 / fz
  let f_ninf : Float = (0.0f - f1) / fz
  let f_2p31 : Float = d_2p31.to_float()
  let f_n2p31 : Float = d_n2p31.to_float()
  let f_2p32 : Float = d_2p32.to_float()
  let f_2p63 : Float = d_2p63.to_float()
  let f_n2p63 : Float = d_n2p63.to_float()
  let f_2p64 : Float = d_2p64.to_float()

  sb.write_string("|")
  sb.write_string(check_float("f_nan", f_nan, 0, 0L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_pinf", f_pinf, i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_ninf", f_ninf, i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_1e25", 1.0e25.to_float(), i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_n1e25", (-1.0e25).to_float(), i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_2p31", f_2p31, i32_max, 2147483648L, 2147483648U, 2147483648UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_n2p31", f_n2p31, i32_min, -2147483648L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_2p32", f_2p32, i32_max, 4294967296L, u32_max, 4294967296UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_2p63", f_2p63, i32_max, i64_max, u32_max, 9223372036854775808UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_n2p63", f_n2p63, i32_min, i64_min, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_2p64", f_2p64, i32_max, i64_max, u32_max, u64_max, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_n0", -0.0f, 0, 0L, 0U, 0UL, 0, 0 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_n1p9", -1.9f, -1, -1L, 0U, 0UL, -1, 255 as Byte))
  sb.write_string("|")
  sb.write_string(check_float("f_42p9", 42.9f, 42, 42L, 42U, 42UL, 42, 42 as Byte))

  io_println(world, sb.to_string())
}
EOF

# 1. Native --release
"$PIONC" build --release -o "$TMP_DIR/p74d_rel" "$TMP_DIR/p74d_sat.pion"
OUT_REL=$("$TMP_DIR/p74d_rel")

# 2. Native dev
"$PIONC" build -o "$TMP_DIR/p74d_dev" "$TMP_DIR/p74d_sat.pion"
OUT_DEV=$("$TMP_DIR/p74d_dev")
test "$OUT_REL" = "$OUT_DEV"

# 3. Wasm32 (Node + Web runtimes, both --release and dev)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p74d_rel.wasm" "$TMP_DIR/p74d_sat.pion"
  OUT_WASM_NODE=$(node "$WASM_RT" "$TMP_DIR/p74d_rel.wasm")
  test "$OUT_REL" = "$OUT_WASM_NODE"
  OUT_WASM_WEB="$(node --input-type=module -e '
    import fs from "node:fs";
    import { pathToFileURL } from "node:url";
    const { createPionRuntime } = await import(pathToFileURL(process.argv[2]).href);
    const out = [];
    const rt = createPionRuntime({ print: (s) => out.push(s), println: (s) => out.push(s + "\n") });
    const bytes = fs.readFileSync(process.argv[1]);
    const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
    rt.bindExports(instance.exports);
    const rc = instance.exports.main(0, 0n);
    if ((rc | 0) !== 0) process.exit(1);
    process.stdout.write(out.join("").replace(/\n$/, ""));
  ' "$TMP_DIR/p74d_rel.wasm" "$WASM_RT_WEB")"
  test "$OUT_REL" = "$OUT_WASM_WEB"

  "$PIONC" build --target wasm32 -o "$TMP_DIR/p74d_dev.wasm" "$TMP_DIR/p74d_sat.pion"
  OUT_WASM_DEV=$(node "$WASM_RT" "$TMP_DIR/p74d_dev.wasm")
  test "$OUT_REL" = "$OUT_WASM_DEV"
  echo "PASS: p74d_float_to_int_sat (Native release+dev == Wasm32 Node+Web, bit-for-bit identical, 0 traps)"
else
  echo "PASS: p74d_float_to_int_sat (Native release+dev; node unavailable)"
fi
