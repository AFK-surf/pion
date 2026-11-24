#!/usr/bin/env sh
# P75-A E2E: Signed Int8 + compact 1B Array[Int8]/FixedArray[Int8]
#            + compact 4B Array[Float]/FixedArray[Float] + Float32 alias
#            + Bytes::read_i8 / Bytes::read_f32_le (Native release/dev + ASan/LSan + Wasm32 Node & Web + SSA + RSS).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== P75-A E2E: Int8 + Compact 1B/4B Arrays + Float32 Alias + Bytes::read_i8/read_f32_le ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
struct I8Pair {
  a : Int8
  b : Int8
}

fn generic_sum_i8[T](xs : Array[T], to_i : (T) -> Int) -> Int {
  let mut s = 0
  let mut i = 0
  while i < xs.length() {
    s += to_i(xs[i])
    i += 1
  }
  s
}

fn generic_first_last[T](xs : Array[T]) -> (T, T) {
  (xs[0], xs[xs.length() - 1])
}

fn dot_i8(a : Array[Int8], b : Array[Int8]) -> Int {
  let mut acc = 0
  let mut i = 0
  let n = a.length()
  while i < n {
    acc += a[i].to_int() * b[i].to_int()
    i += 1
  }
  acc
}

fn saxpy_f32(a : Array[Float32], b : FixedArray[Float], alpha : Float32) -> Float32 {
  let mut i = 0
  let n = a.length()
  while i < n {
    b[i] = b[i] + alpha * a[i]
    i += 1
  }
  b[0] + b[n - 1]
}

fn test_int8_arith() -> String {
  let max8 : Int8 = 127
  let min8 : Int8 = -128
  let m1 : Int8 = -1
  let z0 : Int8 = 0
  let m5 : Int8 = -5
  let m7 : Int8 = -7
  let p3 : Int8 = 3
  let p42 : Int8 = 42
  let m42 : Int8 = -42
  let m8 : Int8 = -8
  let p1 : Int8 = 1
  let x55 : Int8 = 0x55
  let x0f : Int8 = 0x0f
  let x20 : Int8 = 0x20
  let x05 : Int8 = 0x05
  let m100 : Int8 = -100
  let p100 : Int8 = 100
  let w1 : Int8 = max8 + 1
  let w2 : Int8 = min8 - 1
  let d1 : Int8 = min8 / 2
  let r1 : Int8 = m7 % p3
  let neg1 : Int8 = -min8
  let neg2 : Int8 = -p42
  let sh1 : Int8 = m8 >> 1
  let sh2 : Int8 = p1 << 7
  let bw : Int8 = (x55 & x0f) | x20
  let bx : Int8 = bw ^ x05
  let mut ca : Int8 = 120
  ca += 20
  let cmp_ok = (min8 < m1) && (m1 < z0) && (z0 < max8) && (max8 >= max8)
  let a1 = m42.abs()
  let a2 = min8.abs()
  let mn = m5.min(3)
  let mx = m5.max(3)
  let cl1 = m100.clamp(-10, 10)
  let cl2 = p100.clamp(-10, 10)
  let cl3 = p3.clamp(-10, 10)
  let c_i : Int = m5.to_int()
  let c_i64 : Int64 = m5.to_int64()
  let c_u : UInt = m1.to_uint()
  let c_b : Byte = m1.to_byte()
  let c_f : Float = m5.to_float()
  let c_d : Double = m5.to_double()
  let r_i : Int8 = (255).to_int8()
  let r_i64 : Int8 = (-129L).to_int8()
  let r_u : Int8 = (128U).to_int8()
  let r_u64 : Int8 = (250UL).to_int8()
  let r_b : Int8 = b'\xfe'.to_int8()
  let r_f : Int8 = (-12.9f).to_int8()
  let r_d : Int8 = (13.7).to_int8()
  let opt : Option[Int8] = Some(-77)
  let opt_v = opt.unwrap_or(0)
  let res : Result[Int8, String] = Ok(-33)
  let res_v = res.unwrap_or(0)
  let pair = I8Pair::{ a: -12, b: 34 }
  "i8:\{w1},\{w2},\{d1},\{r1},\{neg1},\{neg2},\{sh1},\{sh2},\{bx},\{ca},\{cmp_ok},\{a1},\{a2},\{mn},\{mx},\{cl1},\{cl2},\{cl3},\{c_i},\{c_i64},\{c_u},\{c_b.to_int()},\{c_f.to_int()},\{c_d.to_int()},\{r_i},\{r_i64},\{r_u},\{r_u64},\{r_b},\{r_f},\{r_d},\{opt_v},\{res_v},\{pair.a},\{pair.b}"
}

fn test_int8_arrays() -> String {
  let a : Array[Int8] = Array::make(4, -5)
  a.push(-128)
  a.push(127)
  a[1] = 10
  a[2] += -3
  let popped = a.pop().unwrap_or(0)
  let cp = a.copy()
  cp.reverse()
  cp.swap(0, 1)
  let has_m128 = cp.contains(-128)
  let has_99 = cp.contains(99)
  let mut for_sum = 0
  for x in a {
    for_sum += x.to_int()
  }
  let gsum = generic_sum_i8(a, fn(x : Int8) -> Int { x.to_int() })
  let fa : FixedArray[Int8] = FixedArray::makei(6, fn(i : Int) -> Int8 { (i - 3).to_int8() })
  let fb = fa.copy()
  fb.blit_to(fb, 3, 2, 0)
  let fc = fa.copy()
  fc.blit_to(fc, 3, 0, 2)
  let fd : FixedArray[Int8] = FixedArray::make(4, 0)
  fd.fill(-9)
  let lit : Array[Int8] = [-2, 3, -4, 5]
  let dot = dot_i8(lit, [-10, -20, 30, -40])
  "ai8:\{popped},\{cp[0]},\{cp[1]},\{has_m128},\{has_99},\{for_sum},\{gsum},\{fb[0]},\{fb[2]},\{fc[2]},\{fc[4]},\{fd[3]},\{dot}"
}

fn test_f32_arrays() -> String {
  let z : Array[Float32] = Array::make(8, 0.0f)
  let mut zsum = 0.0f
  for v in z {
    zsum += v
  }
  let a : Array[Float32] = Array::make(4, -1.5f)
  let mut k = 0
  while k < 12 {
    a.push(Float32::from_int(k) * 0.5f)
    k += 1
  }
  a[0] = 2.5f
  a[1] += 0.25f
  let p = a.pop().unwrap_or(0.0f)
  let cp = a.copy()
  cp.reverse()
  cp.swap(0, 1)
  let has_25 = cp.contains(2.5f)
  let has_99 = cp.contains(99.0f)
  let fl = generic_first_last(a)
  let fa : FixedArray[Float] = FixedArray::makei(6, fn(i : Int) -> Float { Float::from_int(i) + 0.5f })
  let fb = fa.copy()
  fb.blit_to(fb, 3, 2, 0)
  let fc = fa.copy()
  fc.blit_to(fc, 3, 0, 2)
  let fd : FixedArray[Float32] = FixedArray::make(4, 1.0f)
  fd.fill(0.0f)
  let f0 = fd[3]
  fd.fill(-2.25f)
  let f1 = fd[2]
  let lit : Array[Float32] = [1.0f, 2.0f, 3.0f, 4.0f]
  let out : FixedArray[Float] = FixedArray::make(4, 0.5f)
  let sx = saxpy_f32(lit, out, 2.0f)
  "af32:\{zsum.to_int()},\{a.length()},\{p.to_bits()},\{cp[0].to_bits()},\{cp[1].to_bits()},\{has_25},\{has_99},\{fl.0.to_bits()},\{fl.1.to_bits()},\{fb[0].to_bits()},\{fc[2].to_bits()},\{f0.to_bits()},\{f1.to_bits()},\{sx.to_bits()}"
}

fn test_bytes_readers() -> String {
  let bs = Bytes::new(20)
  bs[0] = b'\x00'
  bs[1] = b'\x7f'
  bs[2] = b'\x80'
  bs[3] = b'\xff'
  bs[8] = b'\x00'
  bs[9] = b'\x00'
  bs[10] = b'\xc0'
  bs[11] = b'\xbf'
  bs[13] = b'\xdb'
  bs[14] = b'\x0f'
  bs[15] = b'\x49'
  bs[16] = b'\x40'
  let i0 = bs.read_i8(0)
  let i1 = bs.read_i8(1)
  let i2 = bs.read_i8(2)
  let i3 = bs.read_i8(3)
  let f0 = bs.read_f32_le(4)
  let f1 = bs.read_f32_le(8)
  let f2 = bs.read_f32_le(13)
  let u2 = Bytes::new(8)
  u2[2] = b'\x00'
  u2[3] = b'\x00'
  u2[4] = b'\x80'
  u2[5] = b'\x3f'
  let fu2 = u2.read_f32_le(2)
  let u3 = Bytes::new(8)
  u3[3] = b'\x00'
  u3[4] = b'\x00'
  u3[5] = b'\x80'
  u3[6] = b'\x3f'
  let fu3 = u3.read_f32_le(3)
  "br:\{i0},\{i1},\{i2},\{i3},\{f0.to_bits()},\{f1.to_bits()},\{f2.to_bits()},\{fu2.to_bits()},\{fu3.to_bits()}"
}

pub fn main(world : World) -> Int {
  io_println(world, test_int8_arith())
  io_println(world, test_int8_arrays())
  io_println(world, test_f32_arrays())
  io_println(world, test_bytes_readers())
  0
}
EOF

EXPECTED="$(cat <<'EOF'
i8:-128,127,-64,-1,-128,-42,-4,-128,32,-116,true,42,-128,-5,3,-10,10,3,-5,-5,4294967295,255,-5,-5,-1,127,-128,-6,-2,-12,13,-77,-33,-12,34
ai8:127,-5,-128,true,false,-136,-136,-1,1,-3,-1,-9,-360
af32:0,15,1085276160,1083179008,1084227584,true,false,1075838976,1084227584,1075838976,1056964608,0,-1072693248,1093664768
br:0,127,-128,-1,0,-1077936128,1078530011,1065353216,1065353216
EOF
)"

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p75a_rel" "$TMP_DIR/main.pion"
OUT_REL="$("$TMP_DIR/p75a_rel")"
if [ "$OUT_REL" != "$EXPECTED" ]; then
  echo "FAIL: native release mismatch" >&2
  echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
  echo "--- got ---" >&2; printf '%s\n' "$OUT_REL" >&2
  exit 1
fi
echo "1a. Native release -> OK"

"$PIONC" build -o "$TMP_DIR/p75a_dev" "$TMP_DIR/main.pion"
OUT_DEV="$("$TMP_DIR/p75a_dev")"
if [ "$OUT_DEV" != "$EXPECTED" ]; then
  echo "FAIL: native dev mismatch" >&2
  exit 1
fi
echo "1b. Native dev -> OK"

# 2. SSA audit: Array[Int8] loadsb, Array[Float] elem_flags=4 + shl 2 + loads/stores
"$PIONC" build --release --emit-ssa "$TMP_DIR/p75a.ssa" "$TMP_DIR/main.pion"
python3 - "$TMP_DIR/p75a.ssa" <<'SSA_AUDIT'
import sys, re
ssa = open(sys.argv[1]).read()
def fn_body(name):
    m = re.search(rf'function [^\n]*\${name}\([^)]*\) \{{(.*?)\n\}}', ssa, re.S)
    assert m, f"missing function {name}"
    return m.group(1)

dot = fn_body("pion_fn_dot_i8")
assert "loadsb " in dot, "dot_i8 missing loadsb"
assert "loadub " not in dot, "dot_i8 unexpectedly uses loadub"

saxpy = fn_body("pion_fn_saxpy_f32")
assert ", 2\n" in saxpy and "shl " in saxpy, "saxpy_f32 missing shl ..., 2"
assert not re.search(r"=l shl [^\n]+, 3\b", saxpy), "saxpy_f32 unexpectedly uses shl ..., 3"
assert "=s loads " in saxpy, "saxpy_f32 missing =s loads"
assert "stores " in saxpy, "saxpy_f32 missing stores"

tf32 = fn_body("pion_fn_test_f32_arrays")
assert ", w 4)" in tf32, "test_f32_arrays missing pion_arr_new(..., w 4)"
print("2. SSA audit (dot_i8=loadsb, saxpy_f32=shl2+loads+stores, arr_new=w 4) -> OK")
SSA_AUDIT

# 3. Compact 4B stride / RSS proof: Array::make(4_000_000, 0.0f) = 16 MB data (< 28 MB RSS)
cat > "$TMP_DIR/rss.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let a : Array[Float32] = Array::make(4_000_000, 0.0f)
  a[0] = 1.5f
  a[3_999_999] = 2.5f
  let sum = a[0] + a[3_999_999]
  io_println(world, sum.to_int().to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p75a_rss" "$TMP_DIR/rss.pion"
python3 - "$TMP_DIR/p75a_rss" <<'RSS_CHK'
import os, resource, subprocess, sys
out = subprocess.check_output([sys.argv[1]], text=True).strip()
assert out == "4", f"expected 4, got {out!r}"
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
rss_kb = ru.ru_maxrss // 1024 if sys.platform == "darwin" else ru.ru_maxrss
assert rss_kb <= 28672, f"Array[Float](4M) RSS {rss_kb} KB > 28672 KB (expected compact 4B = ~16MB)"
print(f"3. Compact 4B Array::make(4M, 0.0f) RSS={rss_kb} KB (<= 28672 KB) -> OK")
RSS_CHK

# 4. OOB panic checks for Bytes::read_i8 and Bytes::read_f32_le
check_oob() {
  label="$1"
  code="$2"
  cat > "$TMP_DIR/oob_${label}.pion" <<EOF
pub fn main() -> Int {
  $code
  0
}
EOF
  "$PIONC" build --release -o "$TMP_DIR/oob_${label}" "$TMP_DIR/oob_${label}.pion"
  if "$TMP_DIR/oob_${label}" >/dev/null 2>&1; then
    echo "FAIL: OOB case $label did not panic" >&2
    exit 1
  fi
}
check_oob "i8_neg" 'let b = Bytes::new(4); let _ = b.read_i8(-1)'
check_oob "i8_end" 'let b = Bytes::new(4); let _ = b.read_i8(4)'
check_oob "f32_neg" 'let b = Bytes::new(8); let _ = b.read_f32_le(-1)'
check_oob "f32_tail" 'let b = Bytes::new(8); let _ = b.read_f32_le(5)'
check_oob "f32_short" 'let b = Bytes::new(3); let _ = b.read_f32_le(0)'
echo "4. Bytes::read_i8 & read_f32_le 5 OOB panic cases -> OK"

# 5. Native ASan/LSan (0 leaks, 0 memory errors)
CC_BIN="${CC:-cc}"
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'EOF' >/dev/null 2>&1
int main(void) { return 0; }
EOF
then
  "$PIONC" build --release --emit-asm "$TMP_DIR/p75a.s" "$TMP_DIR/main.pion"
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  "$CC_BIN" -fsanitize=address -g -O1 "$TMP_DIR/p75a.s" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p75a_asan"
  OUT_ASAN="$("$TMP_DIR/p75a_asan")"
  if [ "$OUT_ASAN" != "$EXPECTED" ]; then
    echo "FAIL: ASan output mismatch" >&2
    exit 1
  fi
  echo "5. Native ASan/LSan (0 leaks) -> OK"
else
  echo "5. Native ASan/LSan -> SKIP (cc lacks -fsanitize=address)"
fi

# 6. Wasm32 (Node runtime + Web runtime)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p75a.wasm" "$TMP_DIR/main.pion"
  OUT_WASM_NODE="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p75a.wasm")"
  if [ "$OUT_WASM_NODE" != "$EXPECTED" ]; then
    echo "FAIL: Wasm32 Node output mismatch" >&2
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
    echo "--- got ---" >&2; printf '%s\n' "$OUT_WASM_NODE" >&2
    exit 1
  fi
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
  ' "$TMP_DIR/p75a.wasm" "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs")"
  if [ "$OUT_WASM_WEB" != "$EXPECTED" ]; then
    echo "FAIL: Wasm32 Web output mismatch" >&2
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
    echo "--- got ---" >&2; printf '%s\n' "$OUT_WASM_WEB" >&2
    exit 1
  fi
  echo "6. Wasm32 (Node + Web runtimes) -> OK"
else
  echo "6. Wasm32 -> SKIP (no node)"
fi

echo "PASS: p75a_compact_i8_f32"
