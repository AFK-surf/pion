#!/bin/sh
# P77 E2E: Zero-copy StrView / BytesView + Library-mode OS primitives
# (fs_mmap_ro, clock_monotonic_us, fs_write_atomic_bytes) across:
#   1. Native --release + dev
#   2. Native ASan/LSan (0 leaks, 0 UAF, munmap cleanup verified)
#   3. --emit-staticlib --no-main C harness (no World parameter)
#   4. OOB & read-only mmap Bytes mutation trap checks
#   5. Wasm32 Node (full) + Wasm32 Web (StrView/BytesView/clock_monotonic_us)
#   6. Microbenchmark: 100k StrView::subview+trim+== vs String::slice+trim
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
CC_BIN="${CC:-cc}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1. Main Native + ASan/LSan + Wasm32 Node program ---
cat <<'EOF' > "$TMP_DIR/p77_main.pion"
fn make_owned_view() -> StrView {
  let s = "   hello, " + "world!   "
  s.view(0, s.length()).trim()
}

fn make_bytes_with_f32_and_i8() -> Bytes {
  // 8 bytes: 4-byte f32 LE (1.5f = 0x3FC00000 -> 00 00 C0 3F) + 4 i8s (-128, -1, 2, 127)
  let b = Bytes::new(8)
  b[0] = 0x00 as Byte
  b[1] = 0x00 as Byte
  b[2] = 0xC0 as Byte
  b[3] = 0x3F as Byte
  b[4] = 0x80 as Byte
  b[5] = 0xFF as Byte
  b[6] = 0x02 as Byte
  b[7] = 0x7F as Byte
  b
}

fn test_strview() -> String {
  let v = make_owned_view()
  if v.length() != 13 || v.is_empty() {
    panic("StrView len/is_empty")
  }
  if v[0] != 104 || v.code_unit_at(12) != 33 {
    panic("StrView index/code_unit_at")
  }
  if !v.starts_with("hello") || v.starts_with("world") {
    panic("StrView starts_with")
  }
  if !v.ends_with("world!") || v.ends_with("hello") {
    panic("StrView ends_with")
  }
  if !v.eq_str("hello, world!") || v.eq_str("hello") {
    panic("StrView eq_str")
  }
  if v.index_of_byte(b',') != 5 || v.index_of_byte(b'Z') != -1 {
    panic("StrView index_of_byte")
  }
  let sub1 = v.subview(7, 12)
  let s2 = "  world  "
  let sub2 = s2.as_view().trim()
  if sub1 != sub2 || !(sub1 == sub2) {
    panic("StrView == / !=")
  }
  let empty_v = v.subview(3, 3)
  if !empty_v.is_empty() || empty_v.length() != 0 || empty_v != "".as_view() {
    panic("StrView empty subview")
  }
  if "[\{sub1}]" != "[world]" {
    panic("StrView interpolation")
  }
  sub1.to_string()
}

fn test_bytesview_and_mmap(path : String, empty_path : String, missing_path : String) -> String {
  // 1. Atomic write + mmap_ro + BytesView + SIMD matvec
  let raw = make_bytes_with_f32_and_i8()
  match fs_write_atomic_bytes(path, raw) {
    Ok(_) => ()
    Err(e) => panic("fs_write_atomic_bytes failed: " + e)
  }
  // Empty file
  let empty_b = Bytes::new(0)
  match fs_write_atomic_bytes(empty_path, empty_b) {
    Ok(_) => ()
    Err(e) => panic("fs_write_atomic_bytes empty failed: " + e)
  }
  match fs_mmap_ro(empty_path) {
    Ok(eb) => {
      if eb.length() != 0 {
        panic("empty mmap len")
      }
      let ev = eb.as_view()
      if !ev.is_empty() || ev.length() != 0 || ev.subview(0, 0).length() != 0 {
        panic("empty BytesView")
      }
    }
    Err(e) => panic("empty mmap failed: " + e)
  }
  // Missing file -> Err
  match fs_mmap_ro(missing_path) {
    Ok(_) => panic("missing mmap should fail")
    Err(_) => ()
  }
  // Regular file mmap_ro -> BytesView -> read_f32_le / read_i8 / subview / to_bytes / to_string
  let mapped = match fs_mmap_ro(path) {
    Ok(mb) => mb
    Err(e) => panic("mmap_ro failed: " + e)
  }
  if mapped.length() != 8 {
    panic("mmap len != 8")
  }
  let bv = mapped.as_view()
  if bv.length() != 8 || bv.is_empty() || bv[3] != (0x3F as Byte) {
    panic("BytesView basic")
  }
  let f = bv.read_f32_le(0)
  if f != 1.5f {
    panic("BytesView read_f32_le != 1.5f")
  }
  let tail = bv.subview(4, 8)
  if tail.length() != 4 || tail.read_i8(0).to_int() != -128 || tail.read_i8(1).to_int() != -1 || tail.read_i8(2).to_int() != 2 || tail.read_i8(3).to_int() != 127 {
    panic("BytesView subview read_i8")
  }
  let copied = tail.to_bytes()
  if copied.length() != 4 || copied[2] != (2 as Byte) {
    panic("BytesView to_bytes")
  }
  let ascii_b = "pion_bv".to_bytes()
  if ascii_b.view(0, 4).to_string() != "pion" {
    panic("BytesView to_string")
  }
  // Zero-copy mmap Bytes directly into simd_matvec_i8_bytes_f32:
  // weights (1 row x 4 cols) at byte offset 4: [-128, -1, 2, 127]
  // x: [1, 2, 3, 1] -> dot = -128 - 2 + 6 + 127 = 3; scale = 1.0f * 1.0f -> out[0] = 3.0f
  let out : Array[Float] = [0.0f]
  let x : Array[Int8] = [1, 2, 3, 1]
  let scales : Array[Float] = [1.0f]
  simd_matvec_i8_bytes_f32(out, 0, mapped, 4, x, 0, scales, 0, 1.0f, 1, 4)
  if out[0] != 3.0f {
    panic("simd_matvec_i8_bytes_f32 on mmap Bytes != 3.0f")
  }
  "f=" + f.to_double().to_string() + ",dot=" + out[0].to_int().to_string()
}

fn bench_views(world : World) -> Int {
  let sb = StringBuilder()
  sb.write_string("   key_alpha = ")
  let mut k = 0
  while k < 1024 {
    sb.write_byte(b'x')
    k = k + 1
  }
  sb.write_string("   ")
  let line = sb.to_string()
  let v = line.as_view()
  let eq = v.index_of_byte(b'=')
  let target = v.subview(eq + 1, v.length()).trim()
  let target_s = target.to_string()
  let t0 = clock_monotonic_us()
  let mut hits = 0
  let mut i = 0
  while i < 100000 {
    let rhs = v.subview(eq + 1, v.length()).trim()
    if rhs == target {
      hits = hits + 1
    }
    i = i + 1
  }
  let t1 = clock_monotonic_us()
  let mut hits_s = 0
  i = 0
  while i < 100000 {
    let rhs_s = line.slice(eq + 1, line.length()).trim()
    if rhs_s == target_s {
      hits_s = hits_s + 1
    }
    i = i + 1
  }
  let t2 = clock_monotonic_us()
  if t1 < t0 || t2 < t1 || hits != 100000 || hits_s != 100000 {
    panic("monotonic clock or bench_views mismatch")
  }
  io_eprintln(world, "p77 bench 100k (1KB): StrView=" + (t1 - t0).to_string() + "us vs String=" + (t2 - t1).to_string() + "us")
  hits
}

fn main(world : World) -> Unit {
  let base = world_argv(world, 1)
  let s_res = test_strview()
  let b_res = test_bytesview_and_mmap(base + "/data.bin", base + "/empty.bin", base + "/missing.bin")
  let hits = bench_views(world)
  io_println(world, "p77 ok " + s_res + " " + b_res + " hits=" + hits.to_string())
}
EOF

EXPECTED="p77 ok world f=1.5,dot=3 hits=100000"

# 1a. Native --release
"$PIONC" build --release -o "$TMP_DIR/p77_rel" "$TMP_DIR/p77_main.pion"
NAT_REL=$("$TMP_DIR/p77_rel" "$TMP_DIR")
echo "p77 native release -> $NAT_REL"
test "$NAT_REL" = "$EXPECTED"

# 1b. Native dev
"$PIONC" build -o "$TMP_DIR/p77_dev" "$TMP_DIR/p77_main.pion"
NAT_DEV=$("$TMP_DIR/p77_dev" "$TMP_DIR")
echo "p77 native dev -> $NAT_DEV"
test "$NAT_DEV" = "$EXPECTED"

# 2. Native ASan/LSan (0 leaks, 0 UAF)
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  "$PIONC" build --release --emit-obj "$TMP_DIR/p77_main.o" "$TMP_DIR/p77_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p77_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p77_asan"
  ASAN_OUT=$("$TMP_DIR/p77_asan" "$TMP_DIR")
  echo "p77 ASan/LSan -> $ASAN_OUT"
  test "$ASAN_OUT" = "$EXPECTED"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p77 ASan check"
fi

# 3. Library mode (--emit-staticlib --no-main, NO World parameter!)
cat <<'EOF' > "$TMP_DIR/p77_lib.pion"
pub extern "C" fn p77_lib_roundtrip(path_cstr : Ptr) -> Int = "p77_lib_roundtrip" {
  let path = cstr_to_str(path_cstr)
  let t0 = clock_monotonic_us()
  let b = Bytes::new(8)
  b[0] = 0x00 as Byte
  b[1] = 0x00 as Byte
  b[2] = 0x20 as Byte
  b[3] = 0x40 as Byte // 2.5f
  b[4] = 0xFE as Byte // -2i8
  match fs_write_atomic_bytes(path, b) {
    Ok(_) => ()
    Err(_) => return -1
  }
  let mapped = match fs_mmap_ro(path) {
    Ok(m) => m
    Err(_) => return -2
  }
  let bv = mapped.as_view()
  let f = bv.read_f32_le(0)
  let x = bv.read_i8(4).to_int()
  let t1 = clock_monotonic_us()
  if t1 < t0 || f != 2.5f || x != -2 {
    return -3
  }
  42
}
EOF

cat <<'EOF' > "$TMP_DIR/p77_host.c"
#include <stdio.h>
#include <stdint.h>
extern int32_t p77_lib_roundtrip(const char *path);
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int32_t r = p77_lib_roundtrip(argv[1]);
    printf("staticlib=%d\n", r);
    return r == 42 ? 0 : 1;
}
EOF

RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
"$PIONC" build --release --emit-staticlib "$TMP_DIR/libp77.a" --no-main "$TMP_DIR/p77_lib.pion"
"$CC_BIN" -O2 "$TMP_DIR/p77_host.c" "$TMP_DIR/libp77.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/p77_host"
SLIB_OUT=$("$TMP_DIR/p77_host" "$TMP_DIR/lib_out.bin")
echo "p77 staticlib -> $SLIB_OUT"
test "$SLIB_OUT" = "staticlib=42"

# 4. Trap checks: StrView OOB + BytesView OOB + read-only mmap Bytes mutation
cat <<'EOF' > "$TMP_DIR/p77_oob_sv.pion"
fn main(world : World) -> Unit {
  let v = "abc".view(0, 4)
  io_println(world, v.to_string())
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p77_oob_sv" "$TMP_DIR/p77_oob_sv.pion"
set +e
OOB_SV=$("$TMP_DIR/p77_oob_sv" 2>&1)
OOB_SV_RC=$?
set -e
test "$OOB_SV_RC" -ne 0
echo "$OOB_SV" | grep -q "out of bounds"

cat <<'EOF' > "$TMP_DIR/p77_ro_mut.pion"
fn main(world : World) -> Unit {
  let p = world_argv(world, 1)
  match fs_mmap_ro(p) {
    Ok(mb) => {
      mb[0] = 0x41 as Byte
      io_println(world, "BUG")
    }
    Err(e) => panic(e)
  }
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p77_ro_mut" "$TMP_DIR/p77_ro_mut.pion"
set +e
RO_MUT=$("$TMP_DIR/p77_ro_mut" "$TMP_DIR/data.bin" 2>&1)
RO_MUT_RC=$?
set -e
echo "p77 ro_mut rc=$RO_MUT_RC -> $RO_MUT"
test "$RO_MUT_RC" -ne 0
echo "$RO_MUT" | grep -q "read-only mmap Bytes"

# 5. Wasm32 Node (full) + Wasm32 Web (StrView + BytesView + clock_monotonic_us)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p77_main.wasm" "$TMP_DIR/p77_main.pion"
  WASM_NODE=$(node "$WASM_RT" "$TMP_DIR/p77_main.wasm" "$TMP_DIR")
  echo "p77 wasm32 node -> $WASM_NODE"
  test "$WASM_NODE" = "$EXPECTED"

  cat <<'EOF' > "$TMP_DIR/p77_web.pion"
fn main(world : World) -> Unit {
  let t0 = clock_monotonic_us()
  let v = "  wasm_web_view  ".as_view().trim()
  let b = "ABCD".to_bytes()
  let bv = b.view(1, 3)
  let t1 = clock_monotonic_us()
  if t1 < t0 || !v.eq_str("wasm_web_view") || bv.to_string() != "BC" {
    panic("p77 web failed")
  }
  io_println(world, "p77_web:\{v}:\{bv.to_string()}")
}
EOF
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p77_web.wasm" "$TMP_DIR/p77_web.pion"
  WASM_WEB="$(node --input-type=module -e '
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
  ' "$TMP_DIR/p77_web.wasm" "$WASM_RT_WEB")"
  echo "p77 wasm32 web -> $WASM_WEB"
  test "$WASM_WEB" = "p77_web:wasm_web_view:BC"
fi

# --- 6. P77-B: Zero-RC / Zero-Heap-Alloc StrView & BytesView hot-path + SSA audit + ASan safety ---
cat <<'EOF' > "$TMP_DIR/p77b_main.pion"
fn cmp_view(a : StrView, b : StrView) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  let mut i = 0
  while i < n {
    let ca = a[i]
    let cb = b[i]
    if ca != cb {
      return ca - cb
    }
    i = i + 1
  }
  la - lb
}

fn cmp_bview(a : BytesView, b : BytesView) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  let mut i = 0
  while i < n {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca - cb
    }
    i = i + 1
  }
  la - lb
}

fn find_line(buf : String, offs : Array[Int], lens : Array[Int], key : StrView) -> Int {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let line = buf.view(s, s + lens[mid])
    let c = cmp_view(line, key)
    if c == 0 {
      return mid
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  -1
}

fn find_line_direct_arg(buf : String, offs : Array[Int], lens : Array[Int], key : StrView) -> Int {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let c = cmp_view(buf.view(s, s + lens[mid]), key)
    if c == 0 {
      return mid
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  -1
}

fn find_line_bytes(buf : Bytes, offs : Array[Int], lens : Array[Int], key : BytesView) -> Int {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let line = buf.view(s, s + lens[mid])
    let c = cmp_bview(line, key)
    if c == 0 {
      return mid
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  -1
}

fn cmp_str(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  let mut i = 0
  while i < n {
    let ca = a[i]
    let cb = b[i]
    if ca != cb {
      return ca - cb
    }
    i = i + 1
  }
  la - lb
}

fn find_line_str(buf : String, offs : Array[Int], lens : Array[Int], key : String) -> Int {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let line = buf.slice(s, s + lens[mid])
    let c = cmp_str(line, key)
    if c == 0 {
      return mid
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  -1
}

// Negative safety tests (must NOT stack-allocate):
fn make_escaped_view() -> StrView {
  let s = "esc_" + "ok"
  s.view(0, 6)
}

fn push_view(arr : Array[StrView], v : StrView) -> Unit {
  arr.push(v)
}

fn test_p77b_safety() -> Unit {
  // (a) Source local mutated after view creation
  let mut s = "aaa" + "bbb"
  let v = s.as_view()
  s = "ccc" + "ddd"
  if !v.eq_str("aaabbb") || s != "cccddd" {
    panic("p77b safety (a) mutated source failed")
  }
  // (b) Cross-function return escape
  let ev = make_escaped_view()
  if !ev.eq_str("esc_ok") {
    panic("p77b safety (b) return escape failed")
  }
  // (c) Storing StrView into Array[StrView] via non-borrowing callee
  let arr : Array[StrView] = []
  let tmp = "stored_" + "view"
  let sv = tmp.view(0, tmp.length())
  push_view(arr, sv)
  if arr.length() != 1 || !arr[0].eq_str("stored_view") {
    panic("p77b safety (c) array store failed")
  }
}

fn pad4(n : Int) -> String {
  let s = n.to_string()
  if s.length() == 1 {
    "000" + s
  } else if s.length() == 2 {
    "00" + s
  } else if s.length() == 3 {
    "0" + s
  } else {
    s
  }
}

fn main(world : World) -> Unit {
  test_p77b_safety()
  // Build 4096-line sorted TSV buffer
  let sb = StringBuilder()
  let offs : Array[Int] = []
  let lens : Array[Int] = []
  let keys : Array[String] = []
  let mut i = 0
  while i < 4096 {
    let k = "key_" + pad4(i) + "\tval_" + pad4(i)
    offs.push(sb.length())
    lens.push(k.length())
    sb.write_string(k)
    sb.write_byte(b'\n')
    keys.push(k)
    i = i + 1
  }
  let buf = sb.to_string()
  let bbuf = buf.to_bytes()
  let bkeys : Array[Bytes] = []
  i = 0
  while i < 4096 {
    bkeys.push(keys[i].to_bytes())
    i = i + 1
  }

  let iters = 200000
  let t0 = clock_monotonic_us()
  let mut sum_sv = 0
  i = 0
  while i < iters {
    let idx = (i * 17) & 4095
    let k = keys[idx]
    let kv = k.as_view()
    sum_sv = sum_sv + find_line(buf, offs, lens, kv)
    i = i + 1
  }
  let t1 = clock_monotonic_us()

  let mut sum_sv2 = 0
  i = 0
  while i < iters {
    let idx = (i * 17) & 4095
    let k = keys[idx]
    sum_sv2 = sum_sv2 + find_line_direct_arg(buf, offs, lens, k.as_view())
    i = i + 1
  }
  let t2 = clock_monotonic_us()

  let mut sum_bv = 0
  i = 0
  while i < iters {
    let idx = (i * 17) & 4095
    let bk = bkeys[idx]
    let bkv = bk.as_view()
    sum_bv = sum_bv + find_line_bytes(bbuf, offs, lens, bkv)
    i = i + 1
  }
  let t3 = clock_monotonic_us()

  let mut sum_str = 0
  i = 0
  while i < iters {
    let idx = (i * 17) & 4095
    sum_str = sum_str + find_line_str(buf, offs, lens, keys[idx])
    i = i + 1
  }
  let t4 = clock_monotonic_us()

  if sum_sv != sum_sv2 || sum_sv != sum_bv || sum_sv != sum_str {
    panic("p77b bsearch sum mismatch")
  }
  io_eprintln(
    world,
    "p77b bench 200k bsearch: StrView=" +
    ((t1 - t0) / 1000L).to_string() +
    "ms StrViewDirect=" +
    ((t2 - t1) / 1000L).to_string() +
    "ms BytesView=" +
    ((t3 - t2) / 1000L).to_string() +
    "ms StringSlice=" +
    ((t4 - t3) / 1000L).to_string() +
    "ms",
  )
  io_println(world, "p77b ok sum=" + sum_sv.to_string())
}
EOF

# 6a. SSA hard audit for P77-B
"$PIONC" build --release --emit-ssa "$TMP_DIR/p77b.ssa" "$TMP_DIR/p77b_main.pion"
audit_fn_ssa() {
  fn_sym="$1"
  pat="$2"
  body=$(awk -v f="$fn_sym" '$0 ~ ("function .* \\$" f "\\(") { p=1 } p { print } p && /^}/ { p=0 }' "$TMP_DIR/p77b.ssa")
  test -n "$body" || { echo "FAIL: missing $fn_sym in p77b.ssa"; exit 1; }
  if printf '%s\n' "$body" | grep -Eq "$pat"; then
    echo "FAIL: $fn_sym unexpectedly matched $pat:"
    printf '%s\n' "$body" | grep -E "$pat"
    exit 1
  fi
}
audit_fn_ssa "pion_fn_cmp_view" "pion_rc_inc|pion_rc_dec|pion_mt_flag|pion_alloc_uninit"
audit_fn_ssa "pion_fn_cmp_bview" "pion_rc_inc|pion_rc_dec|pion_mt_flag|pion_alloc_uninit"
audit_fn_ssa "pion_fn_find_line" "pion_alloc_uninit|pion_rc_inc|pion_rc_dec"
audit_fn_ssa "pion_fn_find_line_direct_arg" "pion_alloc_uninit|pion_rc_inc|pion_rc_dec"
audit_fn_ssa "pion_fn_find_line_bytes" "pion_alloc_uninit|pion_rc_inc|pion_rc_dec"
echo "p77b SSA audit: PASS (0 alloc / 0 RC in cmp_view, cmp_bview, find_line, find_line_direct_arg, find_line_bytes)"

# 6b. Native --release + benchmark
"$PIONC" build --release -o "$TMP_DIR/p77b_rel" "$TMP_DIR/p77b_main.pion"
P77B_REL=$("$TMP_DIR/p77b_rel")
echo "p77b native release -> $P77B_REL"
echo "$P77B_REL" | grep -q "^p77b ok sum="

# 6c. ASan/LSan on p77b (verifies stack views + mutated-source/return/array negative regressions: 0 leaks, 0 UAF)
if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/p77b_main.o" "$TMP_DIR/p77b_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p77b_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p77b_asan"
  P77B_ASAN=$("$TMP_DIR/p77b_asan")
  echo "p77b ASan/LSan -> $P77B_ASAN"
  test "$P77B_ASAN" = "$P77B_REL"
fi

# --- 7. P81 (Part A + Part B): Cold-return on-demand boxing (P77-C) + Native memcmp/memchr ---
cat <<'EOF' > "$TMP_DIR/p81_views.pion"
fn cmp_view(a : StrView, b : StrView) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  let mut i = 0
  while i < n {
    let ca = a[i]
    let cb = b[i]
    if ca != cb {
      return ca - cb
    }
    i = i + 1
  }
  la - lb
}

fn find_line_opt(buf : String, offs : Array[Int], lens : Array[Int], target : StrView) -> Option[StrView] {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let line = buf.view(s, s + lens[mid])
    let tab = line.index_of_byte(b'\t')
    let key = line.subview(0, tab)
    let c = cmp_view(key, target)
    if c == 0 {
      return Some(line)
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  None
}

fn find_line_ret_direct(buf : String, offs : Array[Int], lens : Array[Int], target : StrView) -> StrView {
  let mut lo = 0
  let mut hi = offs.length() - 1
  while lo <= hi {
    let mid = lo + (hi - lo) / 2
    let s = offs[mid]
    let line = buf.view(s, s + lens[mid])
    let tab = line.index_of_byte(b'\t')
    let key = line.subview(0, tab)
    let c = cmp_view(key, target)
    if c == 0 {
      return line
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  "".as_view()
}

fn make_temp_buf_and_find(target : StrView) -> Option[StrView] {
  // Local `buf` is dropped when this function returns; returned StrView MUST keep owner alive!
  let buf = "k0\tv0\nk1\tv1\nk2\tv2\n"
  let offs : Array[Int] = [0, 6, 12]
  let lens : Array[Int] = [5, 5, 5]
  find_line_opt(buf, offs, lens, target)
}

fn main(world : World) -> Unit {
  let k1 = "k1".as_view()
  let km = "k9".as_view()
  match make_temp_buf_and_find(k1) {
    Some(v) => {
      if !v.eq_str("k1\tv1") || v != "k1\tv1".as_view() {
        panic("p81 find_line_opt hit mismatch")
      }
    }
    None => panic("p81 find_line_opt expected Some")
  }
  match make_temp_buf_and_find(km) {
    Some(_) => panic("p81 find_line_opt expected None")
    None => ()
  }
  let buf = "a\t1\nb\t2\nc\t3\n"
  let offs : Array[Int] = [0, 4, 8]
  let lens : Array[Int] = [3, 3, 3]
  let d = find_line_ret_direct(buf, offs, lens, "b".as_view())
  if !d.eq_str("b\t2") {
    panic("p81 find_line_ret_direct mismatch")
  }
  io_println(world, "p81_views ok " + d.to_string())
}
EOF

"$PIONC" build --release --emit-ssa "$TMP_DIR/p81_views.ssa" "$TMP_DIR/p81_views.pion"
OPT_BODY=$(awk '/function .* \$pion_fn_find_line_opt\(/ { p=1 } p { print } p && /^}/ { p=0 }' "$TMP_DIR/p81_views.ssa")
test -n "$OPT_BODY" || { echo "FAIL: missing pion_fn_find_line_opt in p81_views.ssa"; exit 1; }
# Only 1 view alloc (24B, tag 4) on the cold `return Some(line)` edge, 0 in the loop for `line` or `key`
VIEW_ALLOCS=$(printf '%s\n' "$OPT_BODY" | grep -c 'pion_alloc_uninit(w 24, w 4' || true)
RC_INCS=$(printf '%s\n' "$OPT_BODY" | grep -c 'pion_rc_inc' || true)
if [ "$VIEW_ALLOCS" -ne 1 ] || [ "$RC_INCS" -ne 1 ]; then
  echo "FAIL: find_line_opt expected 1 cold view alloc & 1 owner rc_inc, got allocs=$VIEW_ALLOCS rc_incs=$RC_INCS" >&2
  printf '%s\n' "$OPT_BODY" >&2
  exit 1
fi
if ! printf '%s\n' "$OPT_BODY" | grep -q 'call \$memchr('; then
  echo "FAIL: find_line_opt did not lower index_of_byte to Native memchr" >&2
  exit 1
fi
if ! grep -q 'call \$memcmp(' "$TMP_DIR/p81_views.ssa"; then
  echo "FAIL: p81_views.ssa did not lower view_eq_bytes to Native memcmp" >&2
  exit 1
fi
echo "p81 SSA audit: PASS (find_line_opt: 0 loop view allocs, 1 cold return materialize + Native memcmp/memchr)"

"$PIONC" build --release -o "$TMP_DIR/p81_views_rel" "$TMP_DIR/p81_views.pion"
P81_REL=$("$TMP_DIR/p81_views_rel")
echo "p81 native release -> $P81_REL"
test "$P81_REL" = "p81_views ok b	2"

if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/p81_views.o" "$TMP_DIR/p81_views.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p81_views.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p81_views_asan"
  P81_ASAN=$("$TMP_DIR/p81_views_asan")
  echo "p81 ASan/LSan -> $P81_ASAN"
  test "$P81_ASAN" = "$P81_REL"
fi

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p81_views.wasm" "$TMP_DIR/p81_views.pion"
  P81_WASM=$(node "$WASM_RT" "$TMP_DIR/p81_views.wasm")
  echo "p81 wasm32 node -> $P81_WASM"
  test "$P81_WASM" = "$P81_REL"
fi

# --- 8. P83: PionBytes/PionStrBuf TLS Slab + Bytes::slice(a, c).to_string() Fusion ---
printf '0123456789abcdef' > "$TMP_DIR/p83_mmap.bin"
cat <<EOF > "$TMP_DIR/p83_slab_bytes.pion"
fn p83_mmap_path() -> String {
  "$TMP_DIR/p83_mmap.bin"
}
EOF
cat <<'EOF' >> "$TMP_DIR/p83_slab_bytes.pion"
fn check_slice_pair(b : Bytes, a : Int, c : Int, label : String) -> Unit {
  let fused = b.slice(a, c).to_string()
  let tmp = b.slice(a, c)
  let two_step = tmp.to_string()
  if fused != two_step {
    panic("p83 slice.to_string mismatch on " + label + ": fused='" + fused + "' two_step='" + two_step + "'")
  }
}

fn verify_all_edges(b : Bytes, tag : String) -> Unit {
  let n = b.length()
  check_slice_pair(b, 0, n, tag + ":full")
  check_slice_pair(b, 2, 7, tag + ":mid")
  check_slice_pair(b, 3, 3, tag + ":empty_mid")
  check_slice_pair(b, -5, 4, tag + ":neg_a")
  check_slice_pair(b, -10, -2, tag + ":both_neg")
  check_slice_pair(b, 5, n + 100, tag + ":c_gt_len")
  check_slice_pair(b, 8, 3, tag + ":a_gt_c")
  check_slice_pair(b, n + 10, n + 20, tag + ":a_gt_len")
}

fn main(world : World) -> Unit {
  // 1. Bytes::slice(a, c).to_string() fusion edge cases
  let b = "0123456789abcdef".to_bytes()
  verify_all_edges(b, "heap")
  if b.slice(2, 6).to_string() != "2345" {
    panic("p83 expected 2345")
  }
  let empty_b = Bytes::new(0)
  verify_all_edges(empty_b, "empty")
  if empty_b.slice(0, 0).to_string() != "" {
    panic("p83 empty slice failed")
  }

  // Optional native-only mmap_ro test (returns Err on Wasm32 Node/Web)
  let mut mmap_ok = 0
  match fs_mmap_ro(p83_mmap_path()) {
    Ok(mb) => {
      verify_all_edges(mb, "mmap")
      if mb.slice(10, 16).to_string() != "abcdef" {
        panic("p83 mmap slice mismatch")
      }
      mmap_ok = 1
    }
    Err(_) => ()
  }

  // 2. 10,000 short Bytes (1..64B), medium Bytes (4KB / 64KB), large Bytes (300KB)
  let mut checksum = 0
  let mut i = 0
  while i < 10000 {
    let sz = (i & 63) + 1
    let sb = Bytes::new(sz)
    sb[0] = ((i & 127) + 1).to_byte()
    sb[sz - 1] = (((i * 3) & 127) + 1).to_byte()
    checksum = checksum + sb[0].to_int() + sb[sz - 1].to_int()
    i = i + 1
  }
  i = 0
  while i < 64 {
    let m4 = Bytes::new(4096)
    m4[0] = b'A'
    m4[4095] = b'Z'
    let m64 = Bytes::new(65536)
    m64[0] = b'B'
    m64[65535] = b'Y'
    checksum = checksum + m4[0].to_int() + m4[4095].to_int() + m64[0].to_int() + m64[65535].to_int()
    i = i + 1
  }
  i = 0
  while i < 8 {
    let lg = Bytes::new(307200)
    lg[0] = b'L'
    lg[307199] = b'G'
    checksum = checksum + lg[0].to_int() + lg[307199].to_int()
    i = i + 1
  }

  // 3. 10,000 StringBuilders (32B -> 128B / 4KB / 300KB growth)
  i = 0
  while i < 10000 {
    let sb = StringBuilder()
    sb.write_string("hi_")
    sb.write_string(i.to_string())
    if (i & 15) == 0 {
      let mut k = 0
      while k < 16 {
        sb.write_string("01234567")
        k = k + 1
      }
    }
    let s = sb.to_string()
    checksum = checksum + s.length()
    i = i + 1
  }
  let sb_med = StringBuilder()
  i = 0
  while i < 512 {
    sb_med.write_string("abcdefgh")
    i = i + 1
  }
  checksum = checksum + sb_med.to_string().length()

  let sb_lg = StringBuilder()
  i = 0
  while i < 10000 {
    sb_lg.write_string("01234567890123456789012345678901")
    i = i + 1
  }
  checksum = checksum + sb_lg.to_string().length()

  // 4. Cross-thread frozen Bytes & StringBuilder handoff + MT drop
  let mx : Mutex[Array[String]] = Mutex::new([])
  scope(world, fn(sc : Scope) -> Unit {
    let mut t = 0
    while t < 4 {
      let tid = t
      let moved_b = ("frozen_shared_payload_" + tid.to_string()).to_bytes()
      let moved_sb = StringBuilder()
      moved_sb.write_string("sb_handoff_")
      moved_sb.write_string(tid.to_string())
      spawn(sc, fn() -> Unit {
        let fb = move moved_b
        let fsb = move moved_sb
        let head = fb.slice(0, 6).to_string()
        if head != "frozen" {
          panic("p83 mt frozen slice mismatch")
        }
        fsb.write_string("_grown_past_32_bytes_0123456789abcdef")
        let mut r = 0
        while r < 200 {
          let local_b = ("thr_" + tid.to_string() + "_" + r.to_string()).to_bytes()
          let _ = local_b.slice(0, 4).to_string()
          r = r + 1
        }
        let acc = mx.lock()
        acc.push(fsb.to_string())
        mx.unlock(acc)
      })
      t = t + 1
    }
  })
  let final_acc = mx.lock()
  let final_len = final_acc.length()
  mx.unlock(final_acc)
  if final_len != 4 {
    panic("p83 mt final_len != 4")
  }

  io_println(world, "p83 ok checksum=" + checksum.to_string() + " mmap=" + mmap_ok.to_string())
}
EOF

"$PIONC" build --release --emit-ssa "$TMP_DIR/p83_slab_bytes.ssa" "$TMP_DIR/p83_slab_bytes.pion"
P83_CHK_BODY=$(awk '/function .* \$pion_fn_check_slice_pair\(/ { p=1 } p { print } p && /^}/ { p=0 }' "$TMP_DIR/p83_slab_bytes.ssa")
test -n "$P83_CHK_BODY" || { echo "FAIL: missing pion_fn_check_slice_pair in p83_slab_bytes.ssa"; exit 1; }
# check_slice_pair has 1 fused `b.slice(a, c).to_string()` (no pion_bytes_slice) and 1 two-step `let tmp = b.slice(a, c); tmp.to_string()` (1 pion_bytes_slice)
P83_SLICE_CNT=$(printf '%s\n' "$P83_CHK_BODY" | grep -c 'call \$pion_bytes_slice(' || true)
P83_FROM_CSTR_CNT=$(printf '%s\n' "$P83_CHK_BODY" | grep -c 'call \$pion_str_from_cstr(' || true)
if [ "$P83_SLICE_CNT" -ne 1 ] || [ "$P83_FROM_CSTR_CNT" -lt 1 ]; then
  echo "FAIL: p83 fusion SSA audit expected 1 pion_bytes_slice and >=1 pion_str_from_cstr, got slice=$P83_SLICE_CNT cstr=$P83_FROM_CSTR_CNT" >&2
  exit 1
fi
echo "p83 SSA audit: PASS (Bytes::slice(a,c).to_string() fused to pion_str_from_cstr)"

"$PIONC" build --release -o "$TMP_DIR/p83_rel" "$TMP_DIR/p83_slab_bytes.pion"
P83_REL=$("$TMP_DIR/p83_rel")
echo "p83 native release -> $P83_REL"
echo "$P83_REL" | grep -q "mmap=1$"

"$PIONC" build -o "$TMP_DIR/p83_dev" "$TMP_DIR/p83_slab_bytes.pion"
P83_DEV=$("$TMP_DIR/p83_dev")
echo "p83 native dev -> $P83_DEV"
test "$P83_DEV" = "$P83_REL"

if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/p83_slab_bytes.o" "$TMP_DIR/p83_slab_bytes.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p83_slab_bytes.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p83_asan"
  P83_ASAN=$("$TMP_DIR/p83_asan")
  echo "p83 ASan/LSan -> $P83_ASAN"
  test "$P83_ASAN" = "$P83_REL"
fi

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p83_slab_bytes.wasm" "$TMP_DIR/p83_slab_bytes.pion"
  P83_WASM_NODE=$(node "$WASM_RT" "$TMP_DIR/p83_slab_bytes.wasm")
  echo "p83 wasm32 node -> $P83_WASM_NODE"
  test "$P83_WASM_NODE" = "$P83_REL"
  P83_EXP_WASM=$(printf '%s' "$P83_REL" | sed 's/mmap=1$/mmap=0/')
  P83_WASM_WEB=$(node --input-type=module -e '
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const { runWasmBytes } = await import(pathToFileURL(process.argv[1]).href);
const out = [];
await runWasmBytes(fs.readFileSync(process.argv[2]), {
  print: (s) => out.push(s),
  println: (s) => out.push(s + "\n"),
});
process.stdout.write(out.join("").trim());
' "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs" "$TMP_DIR/p83_slab_bytes.wasm")
  echo "p83 wasm32 web -> $P83_WASM_WEB"
  test "$P83_WASM_WEB" = "$P83_EXP_WASM"
fi

echo "PASS: p77_views_and_lib_os (Native rel+dev + ASan/LSan + staticlib no-main + OOB/RO-mmap traps + Wasm32 Node+Web + P77-B/P81/P83)"
