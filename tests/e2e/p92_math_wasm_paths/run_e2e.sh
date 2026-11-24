#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc2}"
CC="${CC:-cc}"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== [P92] Wave I3: Math Primitives + Exact Double::to_string + Path Sanitization + Web Wasm Bridge ==="

# ---------------------------------------------------------------------------
# 1. Zero-runtime-byte math primitives: Native vs Wasm32 (Node + Web) + arity
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/math_test.pion" <<'EOF'
fn show_f64(w : World, tag : String, v : Double) -> Unit {
  io_println(w, tag + "=" + v.to_bits().to_string())
}

fn show_f32(w : World, tag : String, v : Float) -> Unit {
  io_println(w, tag + "=" + v.to_bits().to_string())
}

pub fn main(w : World) -> Int {
  let zero : Double = 0.0
  let neg_zero : Double = -0.0
  let inf : Double = 1.0 / zero
  let neg_inf : Double = -1.0 / zero
  let nan : Double = zero / zero

  let fzero : Float = 0.0f
  let fneg_zero : Float = -0.0f
  let finf : Float = 1.0f / fzero
  let fneg_inf : Float = -1.0f / fzero
  let fnan : Float = fzero / fzero

  // Exact sqrt & Float::sqrt & C99 round boundary
  show_f64(w, "d_sqrt_9", 9.0.sqrt())
  show_f64(w, "d_sqrt_2", 2.0.sqrt())
  show_f64(w, "d_sqrt_0", zero.sqrt())
  show_f64(w, "d_sqrt_n0", neg_zero.sqrt())
  show_f64(w, "d_sqrt_inf", inf.sqrt())
  show_f64(w, "d_sqrt_neg", (-1.0).sqrt())
  show_f64(w, "d_round_subhalf", 0.49999999999999994.round())
  show_f64(w, "d_round_nsubhalf", (-0.49999999999999994).round())
  show_f64(w, "d_round_half", 0.5.round())
  show_f64(w, "d_round_nhalf", (-0.5).round())

  show_f32(w, "f_sqrt_9", 9.0f.sqrt())
  show_f32(w, "f_sqrt_2", 2.0f.sqrt())
  show_f32(w, "f_sqrt_0", fzero.sqrt())
  show_f32(w, "f_sqrt_n0", fneg_zero.sqrt())
  show_f32(w, "f_sqrt_inf", finf.sqrt())
  show_f32(w, "f_sqrt_neg", (-1.0f).sqrt())
  show_f32(w, "f_round_subhalf", 0.49999997f.round())
  show_f32(w, "f_round_nsubhalf", (-0.49999997f).round())

  // Double math methods + math_cbrt
  show_f64(w, "m_cbrt_27", math_cbrt(27.0))
  show_f64(w, "d_cbrt_n8", (-8.0).cbrt())
  show_f64(w, "d_cbrt_2", 2.0.cbrt())
  show_f64(w, "d_pow_2_10", 2.0.pow(10.0))
  show_f64(w, "d_pow_3_05", 3.0.pow(0.5))
  show_f64(w, "d_exp_1", 1.0.exp())
  show_f64(w, "d_exp_n2", (-2.5).exp())
  show_f64(w, "d_ln_e", 2.718281828459045.ln())
  show_f64(w, "d_ln_10", 10.0.ln())
  show_f64(w, "d_sin_05", 0.5.sin())
  show_f64(w, "d_cos_05", 0.5.cos())
  show_f64(w, "d_tan_05", 0.5.tan())
  show_f64(w, "d_asin_05", 0.5.asin())
  show_f64(w, "d_acos_05", 0.5.acos())
  show_f64(w, "d_atan_1", 1.0.atan())
  show_f64(w, "d_atan2_pp", 1.0.atan2(2.0))
  show_f64(w, "d_atan2_pn", 1.0.atan2(-2.0))
  show_f64(w, "d_atan2_np", (-1.0).atan2(2.0))
  show_f64(w, "d_atan2_nn", (-1.0).atan2(-2.0))
  show_f64(w, "d_atan2_z_nz", zero.atan2(neg_zero))
  show_f64(w, "d_atan2_nz_nz", neg_zero.atan2(neg_zero))

  // C99 Annex F pow edge cases (Double)
  show_f64(w, "d_pow_1_nan", 1.0.pow(nan))
  show_f64(w, "d_pow_n1_inf", (-1.0).pow(inf))
  show_f64(w, "d_pow_n1_ninf", (-1.0).pow(neg_inf))
  show_f64(w, "d_pow_nan_0", nan.pow(zero))
  show_f64(w, "d_pow_nan_n0", nan.pow(neg_zero))
  show_f64(w, "d_pow_inf_0", inf.pow(zero))
  show_f64(w, "d_ln_0", zero.ln())
  show_f64(w, "d_ln_neg", (-1.0).ln())
  show_f64(w, "d_asin_oob", 2.0.asin())
  show_f64(w, "d_acos_oob", (-2.0).acos())

  // Float math methods (f32 ABI & rounding)
  show_f32(w, "f_cbrt_27", 27.0f.cbrt())
  show_f32(w, "f_cbrt_n8", (-8.0f).cbrt())
  show_f32(w, "f_cbrt_2", 2.0f.cbrt())
  show_f32(w, "f_pow_2_10", 2.0f.pow(10.0))
  show_f32(w, "f_pow_3_05", 3.0f.pow(0.5))
  show_f32(w, "f_exp_1", 1.0f.exp())
  show_f32(w, "f_exp_n2", (-2.5f).exp())
  show_f32(w, "f_ln_10", 10.0f.ln())
  show_f32(w, "f_sin_05", 0.5f.sin())
  show_f32(w, "f_cos_05", 0.5f.cos())
  show_f32(w, "f_tan_05", 0.5f.tan())
  show_f32(w, "f_asin_05", 0.5f.asin())
  show_f32(w, "f_acos_05", 0.5f.acos())
  show_f32(w, "f_atan_1", 1.0f.atan())
  show_f32(w, "f_atan2_pp", 1.0f.atan2(2.0))
  show_f32(w, "f_atan2_nn", (-1.0f).atan2(-2.0))

  // C99 Annex F powf edge cases (Float)
  show_f32(w, "f_pow_1_nan", 1.0f.pow(fnan))
  show_f32(w, "f_pow_n1_inf", (-1.0f).pow(finf))
  show_f32(w, "f_pow_n1_ninf", (-1.0f).pow(fneg_inf))
  show_f32(w, "f_pow_nan_0", fnan.pow(fzero))
  show_f32(w, "f_pow_nan_n0", fnan.pow(fneg_zero))
  show_f32(w, "f_ln_neg", (-1.0f).ln())
  0
}
EOF

"$PIONC" build --emit-ssa "$TMP_DIR/math_test.ssa" -o "$TMP_DIR/math_test_native" "$TMP_DIR/math_test.pion"
grep -q '=s sqrt ' "$TMP_DIR/math_test.ssa" || { echo "FAIL: Float::sqrt did not emit '=s sqrt'" >&2; exit 1; }
if grep -q '\$sqrtf' "$TMP_DIR/math_test.ssa"; then
  echo "FAIL: Float::sqrt unexpectedly emitted \$sqrtf" >&2
  exit 1
fi
"$PIONC" build --target wasm32 -o "$TMP_DIR/math_test.wasm" "$TMP_DIR/math_test.pion"

"$TMP_DIR/math_test_native" > "$TMP_DIR/math_native.out"
node "$WASM_RT" "$TMP_DIR/math_test.wasm" > "$TMP_DIR/math_wasm_node.out"
node --input-type=module -e '
  import fs from "node:fs";
  import { pathToFileURL } from "node:url";
  const bytes = fs.readFileSync(process.argv[1]);
  const { runWasmBytes } = await import(pathToFileURL(process.argv[2]).href);
  const { exitCode, runtime } = await runWasmBytes(bytes);
  if (exitCode !== 0) process.exit(exitCode);
  process.stdout.write(runtime.getStdout());
' "$TMP_DIR/math_test.wasm" "$WASM_RT_WEB" > "$TMP_DIR/math_wasm_web.out"

python3 - "$TMP_DIR/math_native.out" "$TMP_DIR/math_wasm_node.out" "$TMP_DIR/math_wasm_web.out" <<'PYEOF'
import math, struct, sys

def f64_to_bits(v):
    return struct.unpack("<q", struct.pack("<d", v))[0]

def f32_to_bits(v):
    return struct.unpack("<i", struct.pack("<f", v))[0]

def bits_to_f64(b):
    return struct.unpack("<d", struct.pack("<q", b))[0]

def bits_to_f32(b):
    return struct.unpack("<f", struct.pack("<i", b))[0]

def f64_ordered(b):
    u = b & ((1 << 64) - 1)
    if (u >> 63) != 0:
        return ((~u) & ((1 << 64) - 1)) + 1
    return u | (1 << 63)

def f32_ordered(b):
    u = b & 0xFFFFFFFF
    if (u >> 31) != 0:
        return ((~u) & 0xFFFFFFFF) + 1
    return u | 0x80000000

def ulp_f64(a, b):
    va, vb = bits_to_f64(a), bits_to_f64(b)
    if math.isnan(va) or math.isnan(vb):
        raise ValueError("NaN in ulp_f64")
    return abs(f64_ordered(a) - f64_ordered(b))

def ulp_f32(a, b):
    va, vb = bits_to_f32(a), bits_to_f32(b)
    if math.isnan(va) or math.isnan(vb):
        raise ValueError("NaN in ulp_f32")
    return abs(f32_ordered(a) - f32_ordered(b))

# Self-test monotonic ULP comparator (f64 & f32)
assert ulp_f64(f64_to_bits(2.0), f64_to_bits(-2.0)) > 1_000_000
assert ulp_f64(f64_to_bits(1.0), f64_to_bits(math.nextafter(1.0, 2.0))) == 1
assert ulp_f64(f64_to_bits(0.0), f64_to_bits(-0.0)) == 0
assert ulp_f32(f32_to_bits(2.0), f32_to_bits(-2.0)) > 1_000_000
assert ulp_f32(f32_to_bits(1.0), f32_to_bits(1.0) + 1) == 1
assert ulp_f32(f32_to_bits(0.0), f32_to_bits(-0.0)) == 0
for fn, nan_b, z_b in [(ulp_f64, f64_to_bits(float("nan")), 0), (ulp_f32, f32_to_bits(float("nan")), 0)]:
    try:
        fn(nan_b, z_b)
        raise AssertionError("expected ValueError for single-sided NaN")
    except ValueError:
        pass

def load(path):
    d = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            k, v = line.split("=", 1)
            d[k] = int(v)
    return d

nat = load(sys.argv[1])
wn = load(sys.argv[2])
ww = load(sys.argv[3])
assert set(nat.keys()) == set(wn.keys()) == set(ww.keys()), "key mismatch"

exact_keys = {
    "d_sqrt_9", "d_sqrt_2", "d_sqrt_0", "d_sqrt_n0", "d_sqrt_inf",
    "d_round_subhalf", "d_round_nsubhalf", "d_round_half", "d_round_nhalf",
    "f_sqrt_9", "f_sqrt_2", "f_sqrt_0", "f_sqrt_n0", "f_sqrt_inf",
    "f_round_subhalf", "f_round_nsubhalf",
    "d_pow_1_nan", "d_pow_n1_inf", "d_pow_n1_ninf", "d_pow_nan_0", "d_pow_nan_n0", "d_pow_inf_0",
    "f_pow_1_nan", "f_pow_n1_inf", "f_pow_n1_ninf", "f_pow_nan_0", "f_pow_nan_n0",
}

for k in sorted(nat.keys()):
    is_f32 = k.startswith("f_")
    for label, other in [("wasm-node", wn), ("wasm-web", ww)]:
        b1, b2 = nat[k], other[k]
        v1 = bits_to_f32(b1) if is_f32 else bits_to_f64(b1)
        v2 = bits_to_f32(b2) if is_f32 else bits_to_f64(b2)
        if math.isnan(v1) != math.isnan(v2):
            raise AssertionError(f"{k} ({label}): single-sided NaN mismatch ({v1} vs {v2})")
        if math.isnan(v1) and math.isnan(v2):
            continue
        if math.isinf(v1) or math.isinf(v2):
            assert v1 == v2, f"{k} ({label}): inf mismatch {v1} vs {v2}"
            continue
        if k in exact_keys:
            assert b1 == b2, f"{k} ({label}): exact bit mismatch {b1} ({v1}) vs {b2} ({v2})"
        else:
            d = ulp_f32(b1, b2) if is_f32 else ulp_f64(b1, b2)
            assert d <= 2, f"{k} ({label}): ULP={d} > 2 ({v1} vs {v2})"

one64 = f64_to_bits(1.0)
one32 = f32_to_bits(1.0)
for k in ["d_pow_1_nan", "d_pow_n1_inf", "d_pow_n1_ninf", "d_pow_nan_0", "d_pow_nan_n0", "d_pow_inf_0"]:
    assert nat[k] == wn[k] == ww[k] == one64, f"{k} expected 1.0"
for k in ["f_pow_1_nan", "f_pow_n1_inf", "f_pow_n1_ninf", "f_pow_nan_0", "f_pow_nan_n0"]:
    assert nat[k] == wn[k] == ww[k] == one32, f"{k} expected 1.0f"

print(f"[PASS] Math primitives Native vs Wasm32 (Node + Web): {len(nat)} vectors (monotonic ULP self-tested, sqrt/round exact, transcendentals <= 2 ULP, C99 pow aligned)")
PYEOF

# Arity checks on math_cbrt & unary Double/Float math methods
cat > "$TMP_DIR/math_arity_err.pion" <<'EOF'
pub fn bad() -> Double {
  let a = math_cbrt()
  let b = math_cbrt(1.0, 2.0)
  let c = 1.0.sin(2.0)
  let d = 1.0f.cbrt(2.0f)
  a + b + c + d.to_double()
}
EOF
set +e
ARITY_JSON="$("$PIONC" check --json "$TMP_DIR/math_arity_err.pion")"
ARITY_RC=$?
"$PIONC" build -o "$TMP_DIR/math_arity_bin" "$TMP_DIR/math_arity_err.pion" >/dev/null 2>&1
ARITY_BUILD_RC=$?
set -e
if [ "$ARITY_RC" -eq 0 ] || [ "$ARITY_BUILD_RC" -eq 0 ]; then
  echo "FAIL: expected E_ARITY_MISMATCH failure on bad math arity" >&2
  exit 1
fi
python3 - "$ARITY_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
codes = [x["code"] for x in d["diagnostics"]]
assert d["ok"] is False and codes.count("E_ARITY_MISMATCH") == 4, f"expected 4 E_ARITY_MISMATCH, got {codes}"
print("[PASS] Math arity checks: math_cbrt(), math_cbrt(1,2), 1.0.sin(2.0), 1.0f.cbrt(2.0f) all report E_ARITY_MISMATCH")
PYEOF

# ---------------------------------------------------------------------------
# 2. Double::to_string() & fmtG exact round-half-to-even parity (C vs Node vs Web)
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/dbl_c_ref.c" <<'EOF'
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double from_bits(uint64_t u) {
    double d;
    memcpy(&d, &u, sizeof(d));
    return d;
}

static uint64_t to_bits(double d) {
    uint64_t u;
    memcpy(&u, &d, sizeof(u));
    return u;
}

int main(void) {
    double base[] = {
        9290347888448.125,
        9290347888448.375,
        9290347888448.8125,
        -9290347888448.125,
        -9290347888448.375,
        -9290347888448.8125,
        0.0,
        -0.0,
        INFINITY,
        -INFINITY,
        0.00009999999999999999,
        0.0000999999999999999,
        -0.00009999999999999999,
        0.0001,
        0.00009999999999999995,
        9.999999999999999e14,
        9.99999999999999e14,
        -9.999999999999999e14,
        1e14,
        1e15,
        1e-4,
        1e-5,
        1.7976931348623157e308,
        -1.7976931348623157e308,
        from_bits(1ULL),
        from_bits((1ULL << 63) | 1ULL),
        from_bits(2ULL),
        from_bits(0x000fffffffffffffULL),
        from_bits(0x0010000000000000ULL),
        from_bits(to_bits(9290347888448.125) - 1ULL),
        from_bits(to_bits(9290347888448.125) + 1ULL),
        from_bits(to_bits(9290347888448.375) - 1ULL),
        from_bits(to_bits(9290347888448.375) + 1ULL),
        from_bits(to_bits(1.0) + 1ULL),
        from_bits(to_bits(1.0) - 1ULL),
    };
    size_t n = sizeof(base) / sizeof(base[0]);
    for (size_t i = 0; i < n; i++) {
        double v = base[i];
        uint64_t u = to_bits(v);
        char g15[64];
        snprintf(g15, sizeof(g15), "%.15g", v);
        printf("%016llx\t%s\n", (unsigned long long)u, g15);
    }
    return 0;
}
EOF
"$CC" -std=c11 -O2 "$TMP_DIR/dbl_c_ref.c" -lm -o "$TMP_DIR/dbl_c_ref"
"$TMP_DIR/dbl_c_ref" > "$TMP_DIR/dbl_c_g15.tsv"

node --input-type=module -e '
  import fs from "node:fs";
  import { pathToFileURL } from "node:url";
  const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
  const nodeRt = await import(pathToFileURL(process.argv[2]).href);
  const webRt = await import(pathToFileURL(process.argv[3]).href);
  const buf = new ArrayBuffer(8);
  const u64 = new BigUint64Array(buf);
  const f64 = new Float64Array(buf);
  for (const line of lines) {
    const [hex, want] = line.split("\t");
    u64[0] = BigInt("0x" + hex);
    const v = f64[0];
    const gNode = nodeRt.formatG(v, 15);
    const gWeb = webRt.fmtG(v, 15);
    if (gNode !== want || gWeb !== want) {
      throw new Error(`fmtG(0x${hex}, 15) mismatch: want=${want} node=${gNode} web=${gWeb}`);
    }
  }
  if (nodeRt.formatG(9290347888448.125, 15) !== "9290347888448.12") throw new Error("125 tie failed");
  if (nodeRt.formatG(9290347888448.375, 15) !== "9290347888448.38") throw new Error("375 tie failed");
  if (webRt.fmtG(9290347888448.125, 15) !== "9290347888448.12") throw new Error("web 125 tie failed");
  if (webRt.fmtG(9290347888448.375, 15) !== "9290347888448.38") throw new Error("web 375 tie failed");
  if (webRt.fmtG(0.00009999999999999999, 15) !== "0.0001") throw new Error("carry %g boundary failed");
  console.log(`[PASS] formatG/fmtG(15) exact round-half-to-even matches C %.15g on all ${lines.length} vectors (Node + Web)`);
' "$TMP_DIR/dbl_c_g15.tsv" "$WASM_RT" "$WASM_RT_WEB"

# Verify Pion Double::to_string() Native vs Wasm32 (Node + Web) including negative quiet NaN (0xfff8000000000000) -> "nan"
cat > "$TMP_DIR/dbl_str.pion" <<'EOF'
pub fn main(w : World) -> Int {
  let zero : Double = 0.0
  let xs : Array[Double] = [
    9290347888448.125,
    9290347888448.375,
    9290347888448.8125,
    -9290347888448.125,
    -9290347888448.375,
    -9290347888448.8125,
    0.0,
    -0.0,
    1.0 / zero,
    -1.0 / zero,
    zero / zero,
    Double::from_bits(-2251799813685248L),
    Double::from_bits(9221120237041090560L),
    0.00009999999999999999,
    0.0000999999999999999,
    -0.00009999999999999999,
    9.999999999999999e14,
    9.99999999999999e14,
    1.7976931348623157e308,
    Double::from_bits(1L),
    Double::from_bits(-9223372036854775807L),
    Double::from_bits(4503599627370495L),
    Double::from_bits(4503599627370496L),
    Double::from_bits(9290347888448.125.to_bits() - 1L),
    Double::from_bits(9290347888448.125.to_bits() + 1L),
  ]
  for x in xs {
    io_println(w, x.to_string())
  }
  0
}
EOF
"$PIONC" build -o "$TMP_DIR/dbl_str_native" "$TMP_DIR/dbl_str.pion"
"$PIONC" build --target wasm32 -o "$TMP_DIR/dbl_str.wasm" "$TMP_DIR/dbl_str.pion"
"$TMP_DIR/dbl_str_native" > "$TMP_DIR/dbl_str_native.out"
node "$WASM_RT" "$TMP_DIR/dbl_str.wasm" > "$TMP_DIR/dbl_str_node.out"
node --input-type=module -e '
  import fs from "node:fs";
  import { pathToFileURL } from "node:url";
  const bytes = fs.readFileSync(process.argv[1]);
  const { runWasmBytes } = await import(pathToFileURL(process.argv[2]).href);
  const { exitCode, runtime } = await runWasmBytes(bytes);
  if (exitCode !== 0) process.exit(exitCode);
  process.stdout.write(runtime.getStdout());
' "$TMP_DIR/dbl_str.wasm" "$WASM_RT_WEB" > "$TMP_DIR/dbl_str_web.out"

cmp "$TMP_DIR/dbl_str_native.out" "$TMP_DIR/dbl_str_node.out" || { echo "FAIL: Double::to_string Native != Wasm Node" >&2; diff -u "$TMP_DIR/dbl_str_native.out" "$TMP_DIR/dbl_str_node.out"; exit 1; }
cmp "$TMP_DIR/dbl_str_native.out" "$TMP_DIR/dbl_str_web.out" || { echo "FAIL: Double::to_string Native != Wasm Web" >&2; diff -u "$TMP_DIR/dbl_str_native.out" "$TMP_DIR/dbl_str_web.out"; exit 1; }
if grep -q -- '-nan' "$TMP_DIR/dbl_str_native.out"; then
  echo "FAIL: Native Double::to_string emitted -nan instead of canonical nan" >&2
  exit 1
fi
echo "[PASS] Double::to_string() Native == Wasm32 (Node) == Wasm32 (Web) byte-for-byte (incl. canonical nan for negative qNaN)"

# ---------------------------------------------------------------------------
# 3. Artifact panic/assert source path sanitization + diagnostics preservation
# ---------------------------------------------------------------------------
make_dual_ws() {
  root="$1"
  mkdir -p "$root/pkg_a/src" "$root/pkg_b/src" "$root/app/src"
  cat > "$root/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF
  cat > "$root/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"
EOF
  cat > "$root/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }
EOF
  cat > "$root/pkg_a/src/lib.pion" <<'EOF'
pub fn boom_a(flag : Bool) -> Int {
  if flag {
    panic("from_a")
  }
  1
}

pub fn gen_boom_a[T](x : T, flag : Bool) -> T {
  if flag {
    panic("gen_from_a")
  }
  x
}
EOF
  cat > "$root/pkg_b/src/lib.pion" <<'EOF'
pub fn boom_b(flag : Bool) -> Int {
  if flag {
    panic("from_b")
  }
  2
}

test "pkg_b ok" {
  debug_assert(boom_b(false) == 2, "ok")
}
EOF
  cat > "$root/app/src/main.pion" <<'EOF'
import "pkg_a"
import "pkg_b"

pub fn main(w : World) -> Int {
  let args = args_get(w)
  if args.length() > 1 && args[1] == "a" {
    return pkg_a::boom_a(true)
  }
  if args.length() > 1 && args[1] == "b" {
    return pkg_b::boom_b(true)
  }
  if args.length() > 1 && args[1] == "ga" {
    return pkg_a::gen_boom_a(7, true)
  }
  io_println(w, "ok")
  0
}
EOF
}

DIR_ALPHA="$TMP_DIR/secret_alpha_host_dir"
DIR_BETA="$TMP_DIR/secret_beta_host_dir"
make_dual_ws "$DIR_ALPHA"
make_dual_ws "$DIR_BETA"

# Cold + hot CAS builds (ensure cross-pkg generic mono also stays sanitized on hot CAS)
"$PIONC" build -o "$TMP_DIR/ws_alpha_nat" "$DIR_ALPHA/app"
"$PIONC" build -o "$TMP_DIR/ws_alpha_hot_nat" "$DIR_ALPHA/app"
"$PIONC" build -o "$TMP_DIR/ws_beta_nat" "$DIR_BETA/app"
"$PIONC" build --target wasm32 -o "$TMP_DIR/ws_alpha.wasm" "$DIR_ALPHA/app"
"$PIONC" build --target wasm32 -o "$TMP_DIR/ws_beta.wasm" "$DIR_BETA/app"

python3 - "$TMP_DIR/ws_alpha_nat" "$TMP_DIR/ws_alpha_hot_nat" "$TMP_DIR/ws_beta_nat" "$TMP_DIR/ws_alpha.wasm" "$TMP_DIR/ws_beta.wasm" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    data = open(p, "rb").read()
    for forbidden in [b"secret_alpha_host_dir", b"secret_beta_host_dir"]:
        if forbidden in data:
            raise SystemExit(f"FAIL: forbidden host path {forbidden!r} found in artifact {p}")
print("[PASS] Zero host absolute paths embedded in Native (cold+hot CAS) and Wasm32 artifacts")
PYEOF

set +e
PANIC_A_ALPHA="$("$TMP_DIR/ws_alpha_nat" a 2>&1)"
PANIC_A_BETA="$("$TMP_DIR/ws_beta_nat" a 2>&1)"
PANIC_B_ALPHA="$("$TMP_DIR/ws_alpha_nat" b 2>&1)"
PANIC_GA_HOT="$("$TMP_DIR/ws_alpha_hot_nat" ga 2>&1)"
PANIC_A_WASM="$(node "$WASM_RT" "$TMP_DIR/ws_alpha.wasm" a 2>&1)"
PANIC_B_WASM="$(node "$WASM_RT" "$TMP_DIR/ws_alpha.wasm" b 2>&1)"
PANIC_GA_WASM="$(node "$WASM_RT" "$TMP_DIR/ws_alpha.wasm" ga 2>&1)"
set -e

if [ "$PANIC_A_ALPHA" != "$PANIC_A_BETA" ]; then
  echo "FAIL: panic output differed between alpha and beta dirs: '$PANIC_A_ALPHA' vs '$PANIC_A_BETA'" >&2
  exit 1
fi
printf '%s' "$PANIC_A_ALPHA" | grep -q 'pkg_a/src/lib.pion:3' || { echo "FAIL: expected pkg_a/src/lib.pion:3 in '$PANIC_A_ALPHA'" >&2; exit 1; }
printf '%s' "$PANIC_B_ALPHA" | grep -q 'pkg_b/src/lib.pion:3' || { echo "FAIL: expected pkg_b/src/lib.pion:3 in '$PANIC_B_ALPHA'" >&2; exit 1; }
printf '%s' "$PANIC_GA_HOT" | grep -q 'pkg_a/src/lib.pion:10' || { echo "FAIL: expected pkg_a/src/lib.pion:10 in '$PANIC_GA_HOT'" >&2; exit 1; }
printf '%s' "$PANIC_A_WASM" | grep -q 'pkg_a/src/lib.pion:3' || { echo "FAIL: expected pkg_a/src/lib.pion:3 in wasm '$PANIC_A_WASM'" >&2; exit 1; }
printf '%s' "$PANIC_B_WASM" | grep -q 'pkg_b/src/lib.pion:3' || { echo "FAIL: expected pkg_b/src/lib.pion:3 in wasm '$PANIC_B_WASM'" >&2; exit 1; }
printf '%s' "$PANIC_GA_WASM" | grep -q 'pkg_a/src/lib.pion:10' || { echo "FAIL: expected pkg_a/src/lib.pion:10 in wasm '$PANIC_GA_WASM'" >&2; exit 1; }
echo "[PASS] Dual-package + cross-pkg generic panic paths distinguish pkg_a/src/lib.pion vs pkg_b/src/lib.pion on Native (cold+hot CAS) + Wasm32"

# Bare file inside a directory containing `/src/`: MUST produce strict basename `main.pion` for BOTH abs & rel inputs
BARE_DIR="$TMP_DIR/src/private-build"
mkdir -p "$BARE_DIR"
cat > "$BARE_DIR/main.pion" <<'EOF'
pub fn main() -> Int {
  panic("bare_boom")
}
EOF
"$PIONC" build -o "$TMP_DIR/bare_nat" "$BARE_DIR/main.pion"
(cd "$TMP_DIR" && "$PIONC" build -o "$TMP_DIR/bare_rel_nat" ./src/private-build/main.pion)
"$PIONC" build --target wasm32 -o "$TMP_DIR/bare.wasm" "$BARE_DIR/main.pion"
(cd "$TMP_DIR" && "$PIONC" build --target wasm32 -o "$TMP_DIR/bare_rel.wasm" ./src/private-build/main.pion)
set +e
BARE_OUT="$("$TMP_DIR/bare_nat" 2>&1)"
BARE_REL_OUT="$("$TMP_DIR/bare_rel_nat" 2>&1)"
BARE_WASM_OUT="$(node "$WASM_RT" "$TMP_DIR/bare.wasm" 2>&1)"
BARE_REL_WASM_OUT="$(node "$WASM_RT" "$TMP_DIR/bare_rel.wasm" 2>&1)"
set -e
if [ "$BARE_OUT" != "$BARE_REL_OUT" ]; then
  echo "FAIL: bare abs vs rel native panic mismatch: '$BARE_OUT' vs '$BARE_REL_OUT'" >&2
  exit 1
fi
printf '%s' "$BARE_OUT" | grep -q 'at main.pion:2:' || { echo "FAIL: bare file panic expected 'at main.pion:2:', got '$BARE_OUT'" >&2; exit 1; }
printf '%s' "$BARE_WASM_OUT" | grep -q 'at main.pion:2:' || { echo "FAIL: bare wasm panic expected 'at main.pion:2:', got '$BARE_WASM_OUT'" >&2; exit 1; }
printf '%s' "$BARE_REL_WASM_OUT" | grep -q 'at main.pion:2:' || { echo "FAIL: bare rel wasm panic expected 'at main.pion:2:', got '$BARE_REL_WASM_OUT'" >&2; exit 1; }
python3 - "$TMP_DIR/bare_nat" "$TMP_DIR/bare_rel_nat" "$TMP_DIR/bare.wasm" "$TMP_DIR/bare_rel.wasm" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    data = open(p, "rb").read()
    if b"private-build" in data:
        raise SystemExit(f"FAIL: bare artifact leaked 'private-build' in {p}")
print("[PASS] Bare file under /src/private-build/main.pion emits strict basename main.pion identically for abs & rel paths")
PYEOF

# Standalone package: relative `.` / `pkg_rel` vs absolute path produce identical panic location
REL_PKG_PARENT="$TMP_DIR/rel_pkg_parent"
REL_PKG_DIR="$REL_PKG_PARENT/pkg_rel"
mkdir -p "$REL_PKG_DIR/src"
cat > "$REL_PKG_DIR/pion.toml" <<'EOF'
[package]
name = "pkg_rel"
version = "0.1.0"
EOF
cat > "$REL_PKG_DIR/src/main.pion" <<'EOF'
pub fn main() -> Int {
  panic("rel_pkg_boom")
}
EOF
"$PIONC" build -o "$TMP_DIR/relpkg_abs_nat" "$REL_PKG_DIR"
(cd "$REL_PKG_DIR" && "$PIONC" build -o "$TMP_DIR/relpkg_dot_nat" .)
(cd "$REL_PKG_PARENT" && "$PIONC" build -o "$TMP_DIR/relpkg_sub_nat" pkg_rel)
"$PIONC" build --target wasm32 -o "$TMP_DIR/relpkg_abs.wasm" "$REL_PKG_DIR"
(cd "$REL_PKG_DIR" && "$PIONC" build --target wasm32 -o "$TMP_DIR/relpkg_dot.wasm" .)
(cd "$REL_PKG_PARENT" && "$PIONC" build --target wasm32 -o "$TMP_DIR/relpkg_sub.wasm" pkg_rel)
set +e
RP_ABS="$("$TMP_DIR/relpkg_abs_nat" 2>&1)"
RP_DOT="$("$TMP_DIR/relpkg_dot_nat" 2>&1)"
RP_SUB="$("$TMP_DIR/relpkg_sub_nat" 2>&1)"
RP_W_ABS="$(node "$WASM_RT" "$TMP_DIR/relpkg_abs.wasm" 2>&1)"
RP_W_DOT="$(node "$WASM_RT" "$TMP_DIR/relpkg_dot.wasm" 2>&1)"
RP_W_SUB="$(node "$WASM_RT" "$TMP_DIR/relpkg_sub.wasm" 2>&1)"
set -e
if [ "$RP_ABS" != "$RP_DOT" ] || [ "$RP_ABS" != "$RP_SUB" ]; then
  echo "FAIL: pkg abs/dot/sub native panic mismatch: '$RP_ABS' | '$RP_DOT' | '$RP_SUB'" >&2
  exit 1
fi
printf '%s' "$RP_ABS" | grep -q 'at pkg_rel/src/main.pion:2:' || { echo "FAIL: expected pkg_rel/src/main.pion:2 in '$RP_ABS'" >&2; exit 1; }
printf '%s' "$RP_W_ABS" | grep -q 'at pkg_rel/src/main.pion:2:' || { echo "FAIL: expected pkg_rel/src/main.pion:2 in wasm abs" >&2; exit 1; }
printf '%s' "$RP_W_DOT" | grep -q 'at pkg_rel/src/main.pion:2:' || { echo "FAIL: expected pkg_rel/src/main.pion:2 in wasm dot" >&2; exit 1; }
printf '%s' "$RP_W_SUB" | grep -q 'at pkg_rel/src/main.pion:2:' || { echo "FAIL: expected pkg_rel/src/main.pion:2 in wasm sub" >&2; exit 1; }
echo "[PASS] Package abs / '.' / relative dir builds produce identical pkg_rel/src/main.pion:2 on Native + Wasm32"

# pionc test path sanitization (must exit non-zero, zero host path, and contain tp/src/lib.pion:3)
TEST_PANIC_PKG="$TMP_DIR/secret_test_host/tp"
mkdir -p "$TEST_PANIC_PKG/src"
cat > "$TEST_PANIC_PKG/pion.toml" <<'EOF'
[package]
name = "tp"
version = "0.1.0"
EOF
cat > "$TEST_PANIC_PKG/src/lib.pion" <<'EOF'
pub fn helper() -> Int { 1 }
test "sanitized panic" {
  panic("tp_boom")
}
EOF
set +e
TP_OUT="$("$PIONC" test "$TEST_PANIC_PKG" 2>&1)"
TP_RC=$?
set -e
if [ "$TP_RC" -eq 0 ]; then
  echo "FAIL: pionc test unexpectedly exited 0 on panicking test" >&2
  exit 1
fi
if printf '%s' "$TP_OUT" | grep -q 'secret_test_host'; then
  echo "FAIL: pionc test leaked host path: $TP_OUT" >&2
  exit 1
fi
printf '%s' "$TP_OUT" | grep -q 'tp/src/lib.pion:3' || { echo "FAIL: pionc test panic missing tp/src/lib.pion:3: $TP_OUT" >&2; exit 1; }
echo "[PASS] pionc test panic path sanitization verified (rc=$TP_RC, contains tp/src/lib.pion:3, zero host path leak)"

# Diagnostics & fix-it edits preserve real file paths for pkg_a, pkg_b, and bare file
DIAG_WS="$TMP_DIR/diag_ws"
mkdir -p "$DIAG_WS/pkg_a/src" "$DIAG_WS/pkg_b/src"
cat > "$DIAG_WS/pion.toml" <<'EOF'
[workspace]
members = ["pkg_a", "pkg_b"]
EOF
cat > "$DIAG_WS/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF
cat > "$DIAG_WS/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"
EOF
cat > "$DIAG_WS/pkg_a/src/lib.pion" <<'EOF'
pub fn bad() -> Int {
  let x = 1
  x = 2
  x
}
EOF
cat > "$DIAG_WS/pkg_b/src/lib.pion" <<'EOF'
pub fn bad() -> Int {
  let x = 1
  x = 2
  x
}
EOF
cat > "$BARE_DIR/diag_bare.pion" <<'EOF'
pub fn bad() -> Int {
  let x = 1
  x = 2
  x
}
EOF
set +e
DIAG_JSON="$("$PIONC" check --json "$DIAG_WS")"
BARE_DIAG_JSON="$("$PIONC" check --json "$BARE_DIR/diag_bare.pion")"
set -e
python3 - "$DIAG_JSON" "$DIAG_WS/pkg_a/src/lib.pion" "$DIAG_WS/pkg_b/src/lib.pion" "$BARE_DIAG_JSON" "$BARE_DIR/diag_bare.pion" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
want_a, want_b = sys.argv[2], sys.argv[3]
assert d["ok"] is False, "expected check failure"
diag_files = {x["file"] for x in d["diagnostics"]}
edit_files = {e["file"] for x in d["diagnostics"] for e in x.get("edits", [])}
assert want_a in diag_files and want_b in diag_files, f"diagnostics lost real paths: {diag_files}"
assert want_a in edit_files and want_b in edit_files, f"fix-it edits lost real paths: {edit_files}"

bd = json.loads(sys.argv[4])
want_bare = sys.argv[5]
b_files = {x["file"] for x in bd["diagnostics"]}
b_edits = {e["file"] for x in bd["diagnostics"] for e in x.get("edits", [])}
assert want_bare in b_files and want_bare in b_edits, f"bare diag/edit lost real path: {b_files} {b_edits}"
print("[PASS] check --json diagnostics and fix-it edits preserve real absolute paths for pkg_a, pkg_b & bare file")
PYEOF

# ---------------------------------------------------------------------------
# 4. Official Web Wasm Host Bridge + --emit-web-rt (incl. collision & ABI=20)
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/web_bridge.pion" <<'EOF'
extern "C" fn host_scale(x : Int) -> Int = "host_scale"

pub extern "C" fn echo_str(s : String) -> String = "echo_str" {
  "echo:" + s
}

pub extern "C" fn echo_cstr(p : Ptr) -> String = "echo_cstr" {
  "c:" + cstr_to_str(p)
}

pub extern "C" fn invert_bytes(b : Bytes) -> Bytes = "invert_bytes" {
  let n = b.length()
  let out = Bytes::new(n)
  let mut i = 0
  while i < n {
    out[i] = (255 - b[i].to_int()).to_byte()
    i = i + 1
  }
  out
}

pub extern "C" fn grow_heap(n : Int) -> Int = "grow_heap" {
  let big = Bytes::new(n)
  big[0] = b'A'
  big[n - 1] = b'Z'
  big.length()
}

pub extern "C" fn call_host(x : Int) -> Int = "call_host" {
  host_scale(x)
}

pub fn main() -> Int {
  0
}
EOF

# (a) --emit-web-rt must fail on non-wasm32 target
if "$PIONC" build --emit-web-rt -o "$TMP_DIR/should_fail" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: --emit-web-rt should fail on non-wasm32 target" >&2
  exit 1
fi

# (b) --emit-web-rt pion.toml must NOT consume/overwrite pion.toml, and must emit default pion_wasm_rt_web.mjs
TOML_PKG="$TMP_DIR/emit_toml_pkg"
mkdir -p "$TOML_PKG/src"
cat > "$TOML_PKG/pion.toml" <<'EOF'
[package]
name = "emit_toml_pkg"
version = "0.1.0"
EOF
cat > "$TOML_PKG/src/main.pion" <<'EOF'
pub fn main() -> Int { 0 }
EOF
cp "$TOML_PKG/pion.toml" "$TMP_DIR/pion.toml.orig"
(cd "$TOML_PKG" && "$PIONC" build --target wasm32 --emit-web-rt pion.toml)
cmp "$TOML_PKG/pion.toml" "$TMP_DIR/pion.toml.orig" || { echo "FAIL: --emit-web-rt pion.toml overwrote pion.toml!" >&2; exit 1; }
test -s "$TOML_PKG/pion_wasm_rt_web.mjs" || { echo "FAIL: --emit-web-rt pion.toml did not emit default pion_wasm_rt_web.mjs" >&2; exit 1; }

# (c) Extension, symlink-loop, out-of-tree source, lockfile, parent-symlink & case-alias collision guards
# Symlink loop inside package must NOT hang --emit-web-rt
ln -s .. "$TOML_PKG/loop"
(cd "$TOML_PKG" && "$PIONC" build --target wasm32 --emit-web-rt=out/rt.mjs .)
test -s "$TOML_PKG/out/rt.mjs" || { echo "FAIL: --emit-web-rt=out/rt.mjs failed with symlink loop in package" >&2; exit 1; }
rm -f "$TOML_PKG/loop"

cp "$TOML_PKG/src/main.pion" "$TMP_DIR/src_main.pion.orig"
printf 'version = 1\n' > "$TOML_PKG/pion.lock"
cp "$TOML_PKG/pion.lock" "$TMP_DIR/pion.lock.orig"
mkdir -p "$TMP_DIR/ext_lib/src"
printf 'pub fn ext() -> Int { 1 }\n' > "$TMP_DIR/ext_lib/src/lib.pion"
cp "$TMP_DIR/ext_lib/src/lib.pion" "$TMP_DIR/ext_lib.pion.orig"

# Non-.mjs/.js extensions and source/manifest/lock paths must all fail without modifying files
for BAD_DST in "foo.txt" "pion.toml" "pion.lock" "src/main.pion" "../ext_lib/src/lib.pion"; do
  if (cd "$TOML_PKG" && "$PIONC" build --target wasm32 --emit-web-rt="$BAD_DST" . 2>/dev/null); then
    echo "FAIL: --emit-web-rt=$BAD_DST should have been rejected" >&2
    exit 1
  fi
done
cmp "$TOML_PKG/pion.toml" "$TMP_DIR/pion.toml.orig" || { echo "FAIL: pion.toml modified!" >&2; exit 1; }
cmp "$TOML_PKG/pion.lock" "$TMP_DIR/pion.lock.orig" || { echo "FAIL: pion.lock modified!" >&2; exit 1; }
cmp "$TOML_PKG/src/main.pion" "$TMP_DIR/src_main.pion.orig" || { echo "FAIL: src/main.pion modified!" >&2; exit 1; }
cmp "$TMP_DIR/ext_lib/src/lib.pion" "$TMP_DIR/ext_lib.pion.orig" || { echo "FAIL: out-of-tree lib.pion modified!" >&2; exit 1; }

if "$PIONC" build --target wasm32 -o "$TMP_DIR/collide.wasm" --emit-web-rt="$TMP_DIR/collide.wasm" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: --emit-web-rt colliding with -o wasm should fail" >&2
  exit 1
fi

# Workspace root pion.toml collision when using -p <pkg>
WS_COL="$TMP_DIR/ws_collide"
mkdir -p "$WS_COL/subpkg/src"
cat > "$WS_COL/pion.toml" <<'EOF'
[workspace]
members = ["subpkg"]
EOF
cat > "$WS_COL/subpkg/pion.toml" <<'EOF'
[package]
name = "subpkg"
version = "0.1.0"
EOF
cat > "$WS_COL/subpkg/src/main.pion" <<'EOF'
pub fn main() -> Int { 0 }
EOF
cp "$WS_COL/pion.toml" "$TMP_DIR/ws_pion.toml.orig"
if "$PIONC" build --target wasm32 --emit-web-rt="$WS_COL/pion.toml" -p subpkg "$WS_COL" 2>/dev/null; then
  echo "FAIL: --emit-web-rt colliding with workspace pion.toml under -p should fail" >&2
  exit 1
fi
cmp "$WS_COL/pion.toml" "$TMP_DIR/ws_pion.toml.orig" || { echo "FAIL: workspace pion.toml was modified!" >&2; exit 1; }

# --emit-ssa collision with pre-existing file
printf 'SENTINEL_SSA_CONTENT\n' > "$TMP_DIR/pre_ssa.ssa"
if "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/pre_ssa.ssa" --emit-web-rt="$TMP_DIR/pre_ssa.ssa" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: --emit-web-rt colliding with --emit-ssa should fail" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/pre_ssa.ssa")" != "SENTINEL_SSA_CONTENT" ]; then
  echo "FAIL: pre-existing --emit-ssa file was modified!" >&2
  exit 1
fi

# Parent-directory symlink, symlink + `..`, symlink loop (>32 hops), symlinked .js source & case-alias collision guards
mkdir -p "$TMP_DIR/real_dir/sub"
ln -s "$TMP_DIR/real_dir" "$TMP_DIR/link_dir"
ln -s "$TMP_DIR/real_dir/sub" "$TMP_DIR/link_sub"
printf 'SENTINEL_MJS\n' > "$TMP_DIR/real_dir/out.mjs"
if "$PIONC" build --target wasm32 -o "$TMP_DIR/link_dir/out.mjs" --emit-web-rt="$TMP_DIR/real_dir/out.mjs" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: parent-dir symlink collision should fail" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/real_dir/out.mjs")" != "SENTINEL_MJS" ]; then
  echo "FAIL: parent-dir symlink collision overwrote out.mjs!" >&2
  exit 1
fi
if "$PIONC" build --target wasm32 -o "$TMP_DIR/real_dir/out.mjs" --emit-web-rt="$TMP_DIR/real_dir/OUT.mjs" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: case-alias collision should fail" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/real_dir/out.mjs")" != "SENTINEL_MJS" ]; then
  echo "FAIL: case-alias collision overwrote out.mjs!" >&2
  exit 1
fi

# Symlink + `..` collision: link_sub -> real_dir/sub, so link_sub/../out.mjs == real_dir/out.mjs
if "$PIONC" build --target wasm32 -o "$TMP_DIR/real_dir/out.mjs" --emit-web-rt="$TMP_DIR/link_sub/../out.mjs" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: symlink+dotdot existing collision should fail" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/real_dir/out.mjs")" != "SENTINEL_MJS" ]; then
  echo "FAIL: symlink+dotdot collision overwrote real_dir/out.mjs!" >&2
  exit 1
fi
if "$PIONC" build --target wasm32 -o "$TMP_DIR/real_dir/new.mjs" --emit-web-rt="$TMP_DIR/link_sub/../new.mjs" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: symlink+dotdot non-existent collision should fail" >&2
  exit 1
fi
if [ -e "$TMP_DIR/real_dir/new.mjs" ]; then
  echo "FAIL: symlink+dotdot collision created real_dir/new.mjs!" >&2
  exit 1
fi

# Symlink loop > 32 hops in --emit-web-rt destination must fail cleanly
ln -s "$TMP_DIR/loop_b" "$TMP_DIR/loop_a"
ln -s "$TMP_DIR/loop_a" "$TMP_DIR/loop_b"
if "$PIONC" build --target wasm32 --emit-web-rt="$TMP_DIR/loop_a/out.mjs" -o "$TMP_DIR/loop_test.wasm" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: symlink loop >32 hops should fail" >&2
  exit 1
fi

# Symlinked .js source protection: src/main.pion -> ../../shared_js/source.js
mkdir -p "$TMP_DIR/shared_js" "$TMP_DIR/sym_src_pkg/src"
printf 'pub fn main() -> Int { 0 }\n' > "$TMP_DIR/shared_js/source.js"
cp "$TMP_DIR/shared_js/source.js" "$TMP_DIR/shared_source.js.orig"
cat > "$TMP_DIR/sym_src_pkg/pion.toml" <<'EOF'
[package]
name = "sym_src_pkg"
version = "0.1.0"
EOF
ln -s "$TMP_DIR/shared_js/source.js" "$TMP_DIR/sym_src_pkg/src/main.pion"
if (cd "$TMP_DIR/sym_src_pkg" && "$PIONC" build --target wasm32 --emit-web-rt=../shared_js/source.js . 2>/dev/null); then
  echo "FAIL: --emit-web-rt colliding with symlinked .js source should fail" >&2
  exit 1
fi
cmp "$TMP_DIR/shared_js/source.js" "$TMP_DIR/shared_source.js.orig" || { echo "FAIL: symlinked .js source was modified!" >&2; exit 1; }

# POSIX backslash in symlink component name: build\alias -> real_dir
ln -s "$TMP_DIR/real_dir" "$TMP_DIR/build\\alias"
if "$PIONC" build --target wasm32 -o "$TMP_DIR/real_dir/out.mjs" --emit-web-rt="$TMP_DIR/build\\alias/out.mjs" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
  echo "FAIL: POSIX backslash symlink component collision should fail" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/real_dir/out.mjs")" != "SENTINEL_MJS" ]; then
  echo "FAIL: POSIX backslash symlink collision overwrote real_dir/out.mjs!" >&2
  exit 1
fi

# Symlinked manifest (pion.toml -> ../shared_js/manifest.js) and lockfile (pion.lock -> ../shared_js/lock.js)
mkdir -p "$TMP_DIR/sym_mf_pkg/src"
cat > "$TMP_DIR/shared_js/manifest.js" <<'EOF'
[package]
name = "sym_mf_pkg"
version = "0.1.0"
EOF
printf '# pion.lock: generated by pionc; do not edit by hand.\nversion = 1\n' > "$TMP_DIR/shared_js/lock.js"
cp "$TMP_DIR/shared_js/manifest.js" "$TMP_DIR/shared_manifest.js.orig"
cp "$TMP_DIR/shared_js/lock.js" "$TMP_DIR/shared_lock.js.orig"
ln -s "$TMP_DIR/shared_js/manifest.js" "$TMP_DIR/sym_mf_pkg/pion.toml"
ln -s "$TMP_DIR/shared_js/lock.js" "$TMP_DIR/sym_mf_pkg/pion.lock"
printf 'pub fn main() -> Int { 0 }\n' > "$TMP_DIR/sym_mf_pkg/src/main.pion"
if (cd "$TMP_DIR/sym_mf_pkg" && "$PIONC" build --target wasm32 --emit-web-rt=../shared_js/manifest.js . 2>/dev/null); then
  echo "FAIL: --emit-web-rt colliding with symlinked manifest.js should fail" >&2
  exit 1
fi
if (cd "$TMP_DIR/sym_mf_pkg" && "$PIONC" build --target wasm32 --emit-web-rt=../shared_js/lock.js . 2>/dev/null); then
  echo "FAIL: --emit-web-rt colliding with symlinked lock.js should fail" >&2
  exit 1
fi
cmp "$TMP_DIR/shared_js/manifest.js" "$TMP_DIR/shared_manifest.js.orig" || { echo "FAIL: symlinked manifest.js was modified!" >&2; exit 1; }
cmp "$TMP_DIR/shared_js/lock.js" "$TMP_DIR/shared_lock.js.orig" || { echo "FAIL: symlinked lock.js was modified!" >&2; exit 1; }

# Workspace -p with root pion.toml symlinked to ../shared_js/ws_manifest.js
# AND unselected sibling member b/pion.toml symlinked to ../shared_js/b_manifest.js
mkdir -p "$TMP_DIR/sym_ws/subpkg/src" "$TMP_DIR/sym_ws/sibling_b/src"
cat > "$TMP_DIR/shared_js/ws_manifest.js" <<'EOF'
[workspace]
members = ["subpkg", "sibling_b"]
EOF
cat > "$TMP_DIR/shared_js/b_manifest.js" <<'EOF'
[package]
name = "sibling_b"
version = "0.1.0"
EOF
cp "$TMP_DIR/shared_js/ws_manifest.js" "$TMP_DIR/shared_ws_manifest.js.orig"
cp "$TMP_DIR/shared_js/b_manifest.js" "$TMP_DIR/shared_b_manifest.js.orig"
ln -s "$TMP_DIR/shared_js/ws_manifest.js" "$TMP_DIR/sym_ws/pion.toml"
ln -s "$TMP_DIR/shared_js/b_manifest.js" "$TMP_DIR/sym_ws/sibling_b/pion.toml"
cat > "$TMP_DIR/sym_ws/subpkg/pion.toml" <<'EOF'
[package]
name = "sym_subpkg"
version = "0.1.0"
EOF
printf 'pub fn main() -> Int { 0 }\n' > "$TMP_DIR/sym_ws/subpkg/src/main.pion"
printf 'pub fn b() -> Int { 1 }\n' > "$TMP_DIR/sym_ws/sibling_b/src/lib.pion"
if "$PIONC" build --target wasm32 --emit-web-rt="$TMP_DIR/shared_js/ws_manifest.js" -p sym_subpkg "$TMP_DIR/sym_ws" 2>/dev/null; then
  echo "FAIL: --emit-web-rt colliding with symlinked workspace root pion.toml under -p should fail" >&2
  exit 1
fi
cmp "$TMP_DIR/shared_js/ws_manifest.js" "$TMP_DIR/shared_ws_manifest.js.orig" || { echo "FAIL: symlinked workspace root ws_manifest.js was modified!" >&2; exit 1; }
if "$PIONC" build --target wasm32 --emit-web-rt="$TMP_DIR/shared_js/b_manifest.js" -p sym_subpkg "$TMP_DIR/sym_ws" 2>/dev/null; then
  echo "FAIL: --emit-web-rt colliding with unselected workspace member b/pion.toml under -p should fail" >&2
  exit 1
fi
cmp "$TMP_DIR/shared_js/b_manifest.js" "$TMP_DIR/shared_b_manifest.js.orig" || { echo "FAIL: unselected member b_manifest.js was modified!" >&2; exit 1; }

# Symlinked pion.lock with custom comment must be rejected BEFORE lockfile rewrite (symlink stays intact!)
mkdir -p "$TMP_DIR/sym_lock_comment_pkg/src"
cat > "$TMP_DIR/sym_lock_comment_pkg/pion.toml" <<'EOF'
[package]
name = "sym_lock_comment_pkg"
version = "0.1.0"
EOF
printf 'pub fn main() -> Int { 0 }\n' > "$TMP_DIR/sym_lock_comment_pkg/src/main.pion"
printf '# extra custom comment\nversion = 1\n' > "$TMP_DIR/shared_js/lock_comment.js"
cp "$TMP_DIR/shared_js/lock_comment.js" "$TMP_DIR/shared_lock_comment.js.orig"
ln -s "$TMP_DIR/shared_js/lock_comment.js" "$TMP_DIR/sym_lock_comment_pkg/pion.lock"
if (cd "$TMP_DIR/sym_lock_comment_pkg" && "$PIONC" build --target wasm32 --emit-web-rt=../shared_js/lock_comment.js . 2>/dev/null); then
  echo "FAIL: --emit-web-rt colliding with non-canonical symlinked pion.lock should fail" >&2
  exit 1
fi
test -L "$TMP_DIR/sym_lock_comment_pkg/pion.lock" || { echo "FAIL: symlinked pion.lock was replaced by regular file before collision check!" >&2; exit 1; }
cmp "$TMP_DIR/shared_js/lock_comment.js" "$TMP_DIR/shared_lock_comment.js.orig" || { echo "FAIL: lock_comment.js was modified!" >&2; exit 1; }

# Astra dangling output symlink regression: alias.wasm -> new.mjs (non-existent), exit code == 1, symlink preserved, new.mjs not created
mkdir -p "$TMP_DIR/dangle_dir"
ln -s new.mjs "$TMP_DIR/dangle_dir/alias.wasm"
set +e
(cd "$TMP_DIR/dangle_dir" && "$PIONC" build --target wasm32 -o alias.wasm --emit-web-rt=new.mjs "$TMP_DIR/web_bridge.pion" 2>/dev/null)
DANGLE_RC=$?
set -e
if [ "$DANGLE_RC" -ne 1 ]; then
  echo "FAIL: dangling output symlink collision expected exit 1, got $DANGLE_RC" >&2
  exit 1
fi
test -L "$TMP_DIR/dangle_dir/alias.wasm" || { echo "FAIL: dangling output symlink alias.wasm was clobbered!" >&2; exit 1; }
test ! -e "$TMP_DIR/dangle_dir/new.mjs" || { echo "FAIL: dangling output symlink collision created new.mjs!" >&2; exit 1; }
# Positive control in the same directory: ordinary new files still build cleanly
(cd "$TMP_DIR/dangle_dir" && "$PIONC" build --target wasm32 -o fresh.wasm --emit-web-rt=fresh.mjs "$TMP_DIR/web_bridge.pion")
test -s "$TMP_DIR/dangle_dir/fresh.wasm" && test -s "$TMP_DIR/dangle_dir/fresh.mjs" || { echo "FAIL: fresh.wasm / fresh.mjs positive control failed" >&2; exit 1; }

# Opus non-existent dir + `..` bypassing symlink: dir/link.mjs -> ../shared_js/a.js (dir/nope does not exist)
mkdir -p "$TMP_DIR/bypass_pkg/src" "$TMP_DIR/bypass_pkg/dir"
cat > "$TMP_DIR/bypass_pkg/pion.toml" <<'EOF'
[package]
name = "bypass_pkg"
version = "0.1.0"
EOF
printf 'pub fn main() -> Int { 0 }\n' > "$TMP_DIR/shared_js/a.js"
cp "$TMP_DIR/shared_js/a.js" "$TMP_DIR/shared_a.js.orig"
ln -s "$TMP_DIR/shared_js/a.js" "$TMP_DIR/bypass_pkg/src/main.pion"
ln -s "$TMP_DIR/shared_js/a.js" "$TMP_DIR/bypass_pkg/dir/link.mjs"
BYPASS_ERR="$TMP_DIR/bypass_err.txt"
if (cd "$TMP_DIR/bypass_pkg" && "$PIONC" build --target wasm32 --emit-web-rt=dir/nope/../link.mjs . 2>"$BYPASS_ERR"); then
  echo "FAIL: non-existent dir + '..' bypassing symlink should fail" >&2
  exit 1
fi
grep -qi 'collides' "$BYPASS_ERR" || { echo "FAIL: bypass error missing 'collides': $(cat "$BYPASS_ERR")" >&2; exit 1; }
cmp "$TMP_DIR/shared_js/a.js" "$TMP_DIR/shared_a.js.orig" || { echo "FAIL: shared_js/a.js was modified!" >&2; exit 1; }

# Astra missing-dir + '..' followed by directory symlink + '..': dir/nope/../hop/../out.mjs -> real/out.mjs
mkdir -p "$TMP_DIR/hop_case/dir" "$TMP_DIR/hop_case/real/sub"
ln -s "$TMP_DIR/hop_case/real/sub" "$TMP_DIR/hop_case/dir/hop"
printf 'SENTINEL_HOP_OUT_MJS\n' > "$TMP_DIR/hop_case/real/out.mjs"
cp "$TMP_DIR/hop_case/real/out.mjs" "$TMP_DIR/hop_case/out.mjs.orig"
HOP_ERR="$TMP_DIR/hop_err.txt"
set +e
(cd "$TMP_DIR/hop_case" && "$PIONC" build --target wasm32 -o real/out.mjs --emit-web-rt=dir/nope/../hop/../out.mjs "$TMP_DIR/web_bridge.pion" 2>"$HOP_ERR")
HOP_RC=$?
set -e
if [ "$HOP_RC" -ne 1 ]; then
  echo "FAIL: dir/nope/../hop/../out.mjs collision expected exit 1, got $HOP_RC" >&2
  exit 1
fi
grep -qi 'collides' "$HOP_ERR" || { echo "FAIL: hop collision error missing 'collides': $(cat "$HOP_ERR")" >&2; exit 1; }
cmp "$TMP_DIR/hop_case/real/out.mjs" "$TMP_DIR/hop_case/out.mjs.orig" || { echo "FAIL: real/out.mjs sentinel was modified!" >&2; exit 1; }

# (d) Top-statement ABI checks: = 20, = 2e1, // comment + 99, block comment only, block comment + 99, and continuation expressions must ALL be rejected
sed 's/PION_WASM_RT_ABI = 2;/PION_WASM_RT_ABI = 20;/' "$WASM_RT_WEB" > "$TMP_DIR/bad_abi20_rt.mjs"
sed 's/PION_WASM_RT_ABI = 2;/PION_WASM_RT_ABI = 2e1;/' "$WASM_RT_WEB" > "$TMP_DIR/bad_abi2e1_rt.mjs"
sed 's/export const PION_WASM_RT_ABI = 2;/\/\/ export const PION_WASM_RT_ABI = 2;\nexport const PION_WASM_RT_ABI = 99;/' "$WASM_RT_WEB" > "$TMP_DIR/bad_abi_comment_rt.mjs"
printf '/*\nexport const PION_WASM_RT_ABI = 2;\n*/\n' > "$TMP_DIR/bad_abi_blk_only.mjs"
printf '/*\nexport const PION_WASM_RT_ABI = 2;\n*/\nexport const PION_WASM_RT_ABI = 99;\n' > "$TMP_DIR/bad_abi_blk_99.mjs"
printf 'export const PION_WASM_RT_ABI = 2 /* offset */ + 1;\n' > "$TMP_DIR/bad_abi_cont_blk.mjs"
printf 'export const PION_WASM_RT_ABI = 2\n+ 1;\n' > "$TMP_DIR/bad_abi_cont_nl.mjs"
for BAD_RT in "$TMP_DIR/bad_abi20_rt.mjs" "$TMP_DIR/bad_abi2e1_rt.mjs" "$TMP_DIR/bad_abi_comment_rt.mjs" "$TMP_DIR/bad_abi_blk_only.mjs" "$TMP_DIR/bad_abi_blk_99.mjs" "$TMP_DIR/bad_abi_cont_blk.mjs" "$TMP_DIR/bad_abi_cont_nl.mjs"; do
  rm -f "$TMP_DIR/should_not_exist.mjs"
  if PION_WASM_WEB_RT="$BAD_RT" "$PIONC" build --target wasm32 --emit-web-rt "$TMP_DIR/should_not_exist.mjs" -o "$TMP_DIR/bad_abi.wasm" "$TMP_DIR/web_bridge.pion" 2>/dev/null; then
    echo "FAIL: --emit-web-rt accepted invalid ABI file $BAD_RT" >&2
    exit 1
  fi
  if [ -e "$TMP_DIR/should_not_exist.mjs" ]; then
    echo "FAIL: --emit-web-rt wrote file despite invalid ABI in $BAD_RT" >&2
    exit 1
  fi
done
echo "[PASS] --emit-web-rt .mjs/.js guard, POSIX realpath (symlink+.., >32-hop loop, symlinked .js src), case-alias & semicolon-strict ABI checks verified"

# (e) Build with default --emit-web-rt (sibling of -o) AND explicit --emit-web-rt <path.mjs>
mkdir -p "$TMP_DIR/web_dist"
"$PIONC" build --target wasm32 --emit-web-rt -o "$TMP_DIR/web_dist/bridge.wasm" "$TMP_DIR/web_bridge.pion"
test -s "$TMP_DIR/web_dist/pion_wasm_rt_web.mjs" || { echo "FAIL: default --emit-web-rt did not create sibling pion_wasm_rt_web.mjs" >&2; exit 1; }

"$PIONC" build --target wasm32 --emit-web-rt "$TMP_DIR/custom_web_rt.mjs" -o "$TMP_DIR/web_dist/bridge2.wasm" "$TMP_DIR/web_bridge.pion"
test -s "$TMP_DIR/custom_web_rt.mjs" || { echo "FAIL: explicit --emit-web-rt <path.mjs> did not create file" >&2; exit 1; }

node --input-type=module -e '
  import fs from "node:fs";
  import { pathToFileURL } from "node:url";

  const wasmBytes = fs.readFileSync(process.argv[1]);
  const mod = await import(pathToFileURL(process.argv[2]).href);
  const { createPionRuntime, PION_WASM_RT_ABI } = mod;
  if (PION_WASM_RT_ABI !== 2) throw new Error(`unexpected ABI ${PION_WASM_RT_ABI}`);

  // (a) extraImports overriding pion_rt must throw
  let threwPionRt = false;
  try {
    createPionRuntime({ extraImports: { pion_rt: { __pion_rt_abi_v2: () => {} } } });
  } catch (e) {
    threwPionRt = true;
  }
  if (!threwPionRt) throw new Error("extraImports overriding pion_rt did not throw");

  // (b) hostFns overriding built-in pion_rt symbol must throw
  let threwHostBuiltin = false;
  try {
    createPionRuntime({ hostFns: { pion_alloc: () => 0n } });
  } catch (e) {
    threwHostBuiltin = true;
  }
  if (!threwHostBuiltin) throw new Error("hostFns overriding built-in pion_alloc did not throw");

  // (c) Two independent instances with separate extraImports AND official opts.hostFns
  const rt1 = createPionRuntime({
    extraImports: { invar_host: { ping: () => 111 } },
    hostFns: { host_scale: (x) => (x * 3) | 0 },
  });
  const rt2 = createPionRuntime({
    extraImports: { invar_host: { ping: () => 222 } },
    hostFns: { host_scale: (x) => (x * 7) | 0 },
  });
  if (rt1.imports.invar_host.ping() !== 111 || rt2.imports.invar_host.ping() !== 222) {
    throw new Error("extraImports namespace isolation failed");
  }

  const inst1 = (await WebAssembly.instantiate(wasmBytes, rt1.imports)).instance;
  const inst2 = (await WebAssembly.instantiate(wasmBytes, rt2.imports)).instance;
  rt1.bindExports(inst1.exports);
  rt2.bindExports(inst2.exports);

  if (inst1.exports.call_host(5) !== 15) throw new Error("rt1 hostFns call_host mismatch");
  if (inst2.exports.call_host(5) !== 35) throw new Error("rt2 hostFns call_host mismatch");

  // String & CStr helpers on both instances independently
  const s1 = rt1.mkStr("hello-one");
  const s2 = rt2.mkStr("hello-two");
  const r1 = inst1.exports.echo_str(s1);
  const r2 = inst2.exports.echo_str(s2);
  if (rt1.readStr(r1) !== "echo:hello-one" || rt1.readUtf8(r1) !== "echo:hello-one") throw new Error("rt1 readStr/readUtf8 failed");
  if (rt2.readStr(r2) !== "echo:hello-two" || rt2.readUtf8(r2) !== "echo:hello-two") throw new Error("rt2 readStr/readUtf8 failed");
  rt1.rcInc(r1);
  rt1.rcDec(r1);
  rt1.rcDec(r1);
  rt1.rcDec(s1);
  rt2.rcDec(r2);
  rt2.rcDec(s2);

  const cs1 = rt1.mkCStr("raw-cstr");
  const cr1 = inst1.exports.echo_cstr(cs1);
  if (rt1.readStr(cr1) !== "c:raw-cstr") throw new Error("mkCStr failed");
  rt1.freePtr(cs1);
  rt1.rcDec(cr1);

  // Bytes round-trip + memory.grow safety of readBytes copy
  const orig = new Uint8Array([1, 2, 3, 250, 254, 255]);
  const b1 = rt1.mkBytes(orig);
  const inv1 = inst1.exports.invert_bytes(b1);
  const copyBeforeGrow = rt1.readBytes(inv1);
  const wantInv = [254, 253, 252, 5, 1, 0];
  if (Array.from(copyBeforeGrow).join(",") !== wantInv.join(",")) {
    throw new Error("readBytes before grow mismatch");
  }

  // mkBytes with BOTH Uint8Array AND Node Buffer views aliasing Wasm linear memory under memory.grow!
  for (const useNodeBuf of [false, true]) {
    const memBeforeAlias = inst1.exports.memory.buffer.byteLength;
    const aliasLen = memBeforeAlias + 128 * 1024;
    const seedPtr = rt1.imports.pion_rt.pion_ptr_alloc(BigInt(aliasLen));
    const seedOff = Number(seedPtr);
    const memAfterSeed = inst1.exports.memory.buffer.byteLength;
    const aliasView = useNodeBuf
      ? Buffer.from(inst1.exports.memory.buffer, seedOff, aliasLen)
      : new Uint8Array(inst1.exports.memory.buffer, seedOff, aliasLen);
    for (let i = 0; i < aliasLen; i++) {
      aliasView[i] = ((i * 31 + (useNodeBuf ? 23 : 17)) & 0xff) || 1;
    }
    const bAlias = rt1.mkBytes(aliasView);
    const memAfterAlias = inst1.exports.memory.buffer.byteLength;
    if (memAfterAlias <= memAfterSeed) throw new Error(`mkBytes alias (${useNodeBuf ? "Buffer" : "Uint8Array"}) did not trigger memory.grow`);
    const gotAlias = rt1.readBytes(bAlias);
    if (gotAlias.length !== aliasLen) throw new Error(`mkBytes alias length mismatch: ${gotAlias.length}`);
    for (let i = 0; i < aliasLen; i++) {
      const want = ((i * 31 + (useNodeBuf ? 23 : 17)) & 0xff) || 1;
      if (gotAlias[i] !== want) {
        throw new Error(`mkBytes alias (${useNodeBuf ? "Buffer" : "Uint8Array"}) byte ${i} corrupted after memory.grow: got=${gotAlias[i]} want=${want}`);
      }
    }
    rt1.rcDec(bAlias);
    rt1.freePtr(seedPtr);
  }

  // Trigger another external memory.grow + syncMemory
  const pagesBefore = inst1.exports.memory.buffer.byteLength;
  const grownLen = inst1.exports.grow_heap(512 * 1024);
  if (grownLen !== 512 * 1024) throw new Error("grow_heap failed");
  inst1.exports.memory.grow(4);
  rt1.syncMemory();
  const pagesAfter = inst1.exports.memory.buffer.byteLength;
  if (pagesAfter <= pagesBefore) throw new Error("memory did not grow");

  if (Array.from(copyBeforeGrow).join(",") !== wantInv.join(",")) {
    throw new Error("readBytes copy corrupted after memory.grow");
  }
  const sAfter = rt1.mkStr("after-grow");
  const rAfter = inst1.exports.echo_str(sAfter);
  if (rt1.readStr(rAfter) !== "echo:after-grow") throw new Error("readStr after memory.grow failed");
  const bAfter = rt1.readBytes(inv1);
  if (Array.from(bAfter).join(",") !== wantInv.join(",")) throw new Error("readBytes after memory.grow failed");
  rt1.rcDec(sAfter);
  rt1.rcDec(rAfter);
  rt1.rcDec(b1);
  rt1.rcDec(inv1);

  // (d) ABI mismatch module must throw on bindExports
  const rtBad = createPionRuntime();
  let threwAbi = false;
  try {
    rtBad.bindExports({
      memory: new WebAssembly.Memory({ initial: 1 }),
      __pion_wasm_rt_abi: new WebAssembly.Global({ value: "i32", mutable: false }, 1),
    });
  } catch (e) {
    if (String(e.message).includes("ABI mismatch")) threwAbi = true;
  }
  if (!threwAbi) throw new Error("ABI mismatch module did not throw on bindExports");

  console.log("[PASS] Web Wasm host bridge: 2 isolated instances, opts.hostFns + builtin guard, extraImports guard, mkBytes linear-memory alias under memory.grow, readBytes copy safety & ABI mismatch check");
' "$TMP_DIR/web_dist/bridge.wasm" "$TMP_DIR/web_dist/pion_wasm_rt_web.mjs"

echo "=== [P92] ALL WAVE I3 GATES PASSED ==="
