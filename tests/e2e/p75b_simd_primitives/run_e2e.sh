#!/usr/bin/env sh
# P75-B E2E: Portable SIMD Vector Primitives + 4-Row Tiled INT8 Matvec
#            (Native release/dev + ASan/LSan + Wasm32 Node & Web + OOB + 256x256 speedup).
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

echo "=== P75-B E2E: Portable SIMD Vector Primitives + 4-Row Tiled INT8 Matvec ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
fn abs_f(x : Float) -> Float {
  if x < 0.0f { -x } else { x }
}

fn assert_near(got : Float, want : Float, tol : Float, msg : String) -> Unit {
  if abs_f(got - want) > tol {
    panic(msg + ": got=" + got.to_string() + " want=" + want.to_string())
  }
}

fn scalar_dot_i8(a : Array[Int8], a_off : Int, b : Array[Int8], b_off : Int, len : Int) -> Int {
  let mut s = 0
  let mut i = 0
  while i < len {
    s += a[a_off + i].to_int() * b[b_off + i].to_int()
    i += 1
  }
  s
}

fn test_dot_i8() -> Unit {
  let n = 272
  let a : Array[Int8] = Array::make(n, 0)
  let b : Array[Int8] = Array::make(n, 0)
  let ab = Bytes::new(n)
  let mut i = 0
  while i < n {
    let va : Int8 = (((i * 37 + 13) % 256) - 128).to_int8()
    let vb : Int8 = (((i * 53 + 7) % 256) - 128).to_int8()
    a[i] = va
    b[i] = vb
    ab[i] = va.to_byte()
    i += 1
  }
  let lens : Array[Int] = [0, 1, 3, 4, 7, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 129, 256]
  let offs : Array[Int] = [0, 1, 3, 5, 7]
  let mut li = 0
  while li < lens.length() {
    let len = lens[li]
    let mut oi = 0
    while oi < offs.length() {
      let ao = offs[oi]
      let bo = offs[(oi + 2) % offs.length()]
      let want = scalar_dot_i8(a, ao, b, bo, len)
      let g1 = simd_dot_i8(a, ao, b, bo, len)
      let g2 = simd_dot_i8_bytes(ab, ao, b, bo, len)
      if g1 != want {
        panic("simd_dot_i8 mismatch")
      }
      if g2 != want {
        panic("simd_dot_i8_bytes mismatch")
      }
      oi += 1
    }
    li += 1
  }
  // Extreme -128 * -128 accumulation (catches broken AVX2 maddubs sign tricks!)
  let e1 : Array[Int8] = Array::make(65, -128)
  let e2 : Array[Int8] = Array::make(65, -128)
  let eb = Bytes::new(65)
  i = 0
  while i < 65 {
    eb[i] = b'\x80'
    i += 1
  }
  let want_ext = 65 * 16384
  if simd_dot_i8(e1, 0, e2, 0, 65) != want_ext {
    panic("simd_dot_i8 -128*-128 overflow!")
  }
  if simd_dot_i8_bytes(eb, 0, e2, 0, 65) != want_ext {
    panic("simd_dot_i8_bytes -128*-128 overflow!")
  }
}

fn test_matvec_i8() -> Unit {
  let row_cases : Array[Int] = [0, 1, 2, 3, 4, 5, 7, 8, 13]
  let col_cases : Array[Int] = [0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 131, 256]
  let max_r = 16
  let max_c = 264
  let w_arr : Array[Int8] = Array::make(max_r * max_c + 16, 0)
  let w_bs = Bytes::new(max_r * max_c + 16)
  let x_arr : Array[Int8] = Array::make(max_c + 16, 0)
  let sc : Array[Float] = Array::make(max_r + 16, 0.0f)
  let mut i = 0
  while i < w_arr.length() {
    let v : Int8 = (((i * 29 + 11) % 256) - 128).to_int8()
    w_arr[i] = v
    w_bs[i] = v.to_byte()
    i += 1
  }
  i = 0
  while i < x_arr.length() {
    x_arr[i] = (((i * 41 + 3) % 256) - 128).to_int8()
    i += 1
  }
  i = 0
  while i < sc.length() {
    sc[i] = (Float::from_int(i + 1) * 0.015625f)
    i += 1
  }
  let x_scale = 0.03125f
  let mut ri = 0
  while ri < row_cases.length() {
    let rows = row_cases[ri]
    let mut ci = 0
    while ci < col_cases.length() {
      let cols = col_cases[ci]
      let out1 : Array[Float] = Array::make(max_r + 16, -999.0f)
      let out2 : Array[Float] = Array::make(max_r + 16, -999.0f)
      let oo = 3
      let wo = 5
      let xo = 2
      let so = 1
      simd_matvec_i8_f32(out1, oo, w_arr, wo, x_arr, xo, sc, so, x_scale, rows, cols)
      simd_matvec_i8_bytes_f32(out2, oo, w_bs, wo, x_arr, xo, sc, so, x_scale, rows, cols)
      // Sentinel untouched
      assert_near(out1[oo - 1], -999.0f, 0.0f, "sentinel pre")
      assert_near(out1[oo + rows], -999.0f, 0.0f, "sentinel post")
      let mut r = 0
      while r < rows {
        let dot = scalar_dot_i8(w_arr, wo + r * cols, x_arr, xo, cols)
        let want = Float::from_int(dot) * (sc[so + r] * x_scale)
        assert_near(out1[oo + r], want, 1e-4f, "matvec_arr")
        assert_near(out2[oo + r], want, 1e-4f, "matvec_bytes")
        r += 1
      }
      ci += 1
    }
    ri += 1
  }
}

fn test_f32_ops() -> Unit {
  let lens : Array[Int] = [0, 1, 3, 4, 7, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64, 65, 256]
  let mut li = 0
  while li < lens.length() {
    let len = lens[li]
    let n = len + 12
    let a : Array[Float] = Array::make(n, 0.0f)
    let b : Array[Float] = Array::make(n, 0.0f)
    let d1 : Array[Float] = Array::make(n, 0.0f)
    let d2 : Array[Float] = Array::make(n, 0.0f)
    let mut i = 0
    while i < n {
      a[i] = Float::from_int((i % 13) - 6) * 0.25f
      b[i] = Float::from_int((i % 11) - 5) * 0.5f
      d1[i] = Float::from_int((i % 7) - 3) * 0.125f
      d2[i] = d1[i]
      i += 1
    }
    let ao = 2
    let bo = 3
    let doff = 1
    // 1. simd_dot_f32
    let mut want_dot = 0.0f
    i = 0
    while i < len {
      want_dot += a[ao + i] * b[bo + i]
      i += 1
    }
    assert_near(simd_dot_f32(a, ao, b, bo, len), want_dot, 1e-3f, "dot_f32")

    // 2. simd_axpy_f32
    let alpha = -1.5f
    simd_axpy_f32(d1, doff, a, ao, alpha, len)
    i = 0
    while i < len {
      d2[doff + i] = d2[doff + i] + alpha * a[ao + i]
      assert_near(d1[doff + i], d2[doff + i], 1e-5f, "axpy_f32")
      i += 1
    }

    // 3. simd_mul_f32 (separate & in-place dst == a)
    let m1 : Array[Float] = Array::make(n, 0.0f)
    simd_mul_f32(m1, doff, a, ao, b, bo, len)
    let ip = a.copy()
    simd_mul_f32(ip, ao, ip, ao, b, bo, len)
    i = 0
    while i < len {
      let w = a[ao + i] * b[bo + i]
      assert_near(m1[doff + i], w, 1e-5f, "mul_f32")
      assert_near(ip[ao + i], w, 1e-5f, "mul_f32_inplace")
      i += 1
    }

    // 4. simd_add_f32 (in-place dst == b)
    let ip_add = b.copy()
    simd_add_f32(ip_add, bo, a, ao, ip_add, bo, len)
    i = 0
    while i < len {
      assert_near(ip_add[bo + i], a[ao + i] + b[bo + i], 1e-5f, "add_f32_inplace")
      i += 1
    }

    // 5. simd_scale_f32 (in-place)
    let ip_sc = a.copy()
    simd_scale_f32(ip_sc, ao, ip_sc, ao, 2.5f, len)
    i = 0
    while i < len {
      assert_near(ip_sc[ao + i], a[ao + i] * 2.5f, 1e-5f, "scale_f32")
      i += 1
    }

    // 6. simd_mul_dot_f32
    let md1 = d1.copy()
    let md2 = d1.copy()
    let got_md = simd_mul_dot_f32(md1, doff, a, ao, b, bo, len)
    let mut want_md = 0.0f
    i = 0
    while i < len {
      let v = md2[doff + i] * a[ao + i]
      md2[doff + i] = v
      want_md += v * b[bo + i]
      assert_near(md1[doff + i], md2[doff + i], 1e-5f, "mul_dot_f32_dst")
      i += 1
    }
    assert_near(got_md, want_md, 1e-3f, "mul_dot_f32_sum")

    // 7. simd_axpy_dot_f32
    let ad1 = d1.copy()
    let ad2 = d1.copy()
    let got_ad = simd_axpy_dot_f32(ad1, doff, a, ao, 0.75f, b, bo, len)
    let mut want_ad = 0.0f
    i = 0
    while i < len {
      let v = ad2[doff + i] + 0.75f * a[ao + i]
      ad2[doff + i] = v
      want_ad += v * b[bo + i]
      assert_near(ad1[doff + i], ad2[doff + i], 1e-5f, "axpy_dot_f32_dst")
      i += 1
    }
    assert_near(got_ad, want_ad, 1e-3f, "axpy_dot_f32_sum")

    li += 1
  }
}

fn test_med_cache_f32_copy() -> Unit {
  // P80-B: 128 KB (32768 * 4B) and 256 KB (65536 * 4B) Array[Float] copy() x 200
  let a128 : Array[Float] = Array::make(32768, 0.0f)
  let a256 : Array[Float] = Array::make(65536, 0.0f)
  a128[0] = 1.25f
  a128[32767] = -3.5f
  a256[0] = 2.5f
  a256[65535] = 7.75f
  let mut iter = 0
  while iter < 200 {
    let c128 = a128.copy()
    let c256 = a256.copy()
    assert_near(c128[0] + c128[32767], -2.25f, 1e-5f, "copy_128k")
    assert_near(c256[0] + c256[65535], 10.25f, 1e-5f, "copy_256k")
    iter += 1
  }
}

pub fn main(world : World) -> Int {
  test_dot_i8()
  test_matvec_i8()
  test_f32_ops()
  test_med_cache_f32_copy()
  io_println(world, "p75b_simd ok")
  0
}
EOF

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p75b_rel" "$TMP_DIR/main.pion"
[ "$("$TMP_DIR/p75b_rel")" = "p75b_simd ok" ]
echo "1a. Native release -> p75b_simd ok"

"$PIONC" build -o "$TMP_DIR/p75b_dev" "$TMP_DIR/main.pion"
[ "$("$TMP_DIR/p75b_dev")" = "p75b_simd ok" ]
echo "1b. Native dev -> p75b_simd ok"

# 2. OOB negative checks (Native + Wasm32)
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
    echo "FAIL: native OOB case $label did not panic" >&2
    exit 1
  fi
  if command -v node >/dev/null 2>&1; then
    "$PIONC" build --release --target wasm32 -o "$TMP_DIR/oob_${label}.wasm" "$TMP_DIR/oob_${label}.pion"
    if node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/oob_${label}.wasm" >/dev/null 2>&1; then
      echo "FAIL: wasm32 OOB case $label did not panic" >&2
      exit 1
    fi
  fi
}
check_oob "neg_off" 'let a : Array[Int8] = Array::make(8, 1); let _ = simd_dot_i8(a, -1, a, 0, 4)'
check_oob "len_over" 'let a : Array[Int8] = Array::make(8, 1); let _ = simd_dot_i8(a, 5, a, 0, 4)'
check_oob "matvec_w_over" 'let o : Array[Float] = Array::make(4, 0.0f); let w : Array[Int8] = Array::make(15, 1); let x : Array[Int8] = Array::make(4, 1); let s : Array[Float] = Array::make(4, 1.0f); simd_matvec_i8_f32(o, 0, w, 0, x, 0, s, 0, 1.0f, 4, 4)'
check_oob "empty_nonzero" 'let a : Array[Float] = []; let _ = simd_dot_f32(a, 0, a, 0, 1)'
echo "2. OOB negative checks (4 cases, Native + Wasm32) -> OK"

# 3. Native ASan/LSan
CC_BIN="${CC:-cc}"
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'EOF' >/dev/null 2>&1
int main(void) { return 0; }
EOF
then
  "$PIONC" build --release --emit-asm "$TMP_DIR/p75b.s" "$TMP_DIR/main.pion"
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  "$CC_BIN" -fsanitize=address -g -O1 "$TMP_DIR/p75b.s" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p75b_asan"
  [ "$("$TMP_DIR/p75b_asan")" = "p75b_simd ok" ]
  echo "3. Native ASan/LSan (0 leaks) -> OK"
else
  echo "3. Native ASan/LSan -> SKIP (cc lacks -fsanitize=address)"
fi

# 4. Wasm32 (Node + Web runtimes)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p75b.wasm" "$TMP_DIR/main.pion"
  OUT_NODE="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p75b.wasm")"
  [ "$OUT_NODE" = "p75b_simd ok" ]
  OUT_WEB="$(node --input-type=module -e '
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
  ' "$TMP_DIR/p75b.wasm" "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs")"
  [ "$OUT_WEB" = "p75b_simd ok" ]
  echo "4. Wasm32 (Node + Web runtimes) -> OK"
else
  echo "4. Wasm32 -> SKIP (no node)"
fi

# 5. Microbenchmark: 256x256 INT8 matvec x 200 iters (Scalar Pion vs simd_matvec_i8_f32, bit-exact checksum)
cat > "$TMP_DIR/bench.pion" <<'EOF'
fn scalar_matvec(out : Array[Float], w : Array[Int8], x : Array[Int8], sc : Array[Float], x_scale : Float, rows : Int, cols : Int) -> Unit {
  let mut r = 0
  while r < rows {
    let base = r * cols
    let mut acc = 0
    let mut k = 0
    while k < cols {
      acc += w[base + k].to_int() * x[k].to_int()
      k += 1
    }
    out[r] = Float::from_int(acc) * (sc[r] * x_scale)
    r += 1
  }
}

pub fn main(world : World) -> Int {
  let rows = 256
  let cols = 256
  let iters = 200
  let w : Array[Int8] = Array::make(rows * cols, 0)
  let x : Array[Int8] = Array::make(cols, 0)
  let sc : Array[Float] = Array::make(rows, 0.0f)
  let o_sc : Array[Float] = Array::make(rows, 0.0f)
  let o_sm : Array[Float] = Array::make(rows, 0.0f)
  let mut i = 0
  while i < rows * cols {
    w[i] = (((i * 31 + 7) % 256) - 128).to_int8()
    i += 1
  }
  i = 0
  while i < cols {
    x[i] = (((i * 17 + 3) % 256) - 128).to_int8()
    i += 1
  }
  i = 0
  while i < rows {
    sc[i] = Float::from_int((i % 16) + 1) * 0.0078125f
    i += 1
  }
  let x_scale = 0.015625f
  let t0 = clock_now_ms(world)
  let mut it = 0
  while it < iters {
    scalar_matvec(o_sc, w, x, sc, x_scale, rows, cols)
    it += 1
  }
  let t1 = clock_now_ms(world)
  it = 0
  while it < iters {
    simd_matvec_i8_f32(o_sm, 0, w, 0, x, 0, sc, 0, x_scale, rows, cols)
    it += 1
  }
  let t2 = clock_now_ms(world)
  let mut c_sc = 0
  let mut c_sm = 0
  i = 0
  while i < rows {
    if o_sc[i].to_bits() != o_sm[i].to_bits() {
      panic("matvec bit mismatch at row " + i.to_string())
    }
    c_sc = c_sc ^ o_sc[i].to_bits()
    c_sm = c_sm ^ o_sm[i].to_bits()
    i += 1
  }
  let sc_ms = t1 - t0
  let sm_ms = t2 - t1
  io_println(world, "matvec 256x256x200: scalar=" + sc_ms.to_string() + "ms simd=" + sm_ms.to_string() + "ms checksum=" + c_sm.to_string() + " exact=true")
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p75b_bench" "$TMP_DIR/bench.pion"
BENCH_OUT="$("$TMP_DIR/p75b_bench")"
echo "5. $BENCH_OUT"

echo "PASS: p75b_simd_primitives"
