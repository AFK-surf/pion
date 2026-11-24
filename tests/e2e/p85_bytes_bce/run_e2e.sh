#!/bin/sh
set -eu

# Wave G Track G3-A + G4 E2E regression:
#   1. Fresh writable Bytes (Bytes::new / slice / concat / to_bytes) + compound writes.
#   2. Read-only fs_mmap_ro Bytes MUST trap on BOTH direct write `mb[0] = ...` and compound write `mb[0] += ...`.
#   3. Slice of read-only fs_mmap_ro Bytes (`let s = mb.slice(0, 4)`) IS fresh writable and mutates cleanly.
#   4. Sound unsigned/bitmask BCE positive cases + aliased dynamic Array shrink OOB trap.
#   5. Wasm32 Node + Web parity.

PIONC="${1:-}"
if [ -z "$PIONC" ] || [ ! -x "$PIONC" ]; then
  echo "usage: $0 <path-to-pionc>" >&2
  exit 1
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf 'ABCD1234EFGH5678' > "$TMP_DIR/ro.bin"

cat <<EOF > "$TMP_DIR/p85_ok.pion"
fn ro_path() -> String {
  "$TMP_DIR/ro.bin"
}
EOF
cat <<'EOF' >> "$TMP_DIR/p85_ok.pion"
fn bump_byte(mut x : Byte) -> Unit {
  x = (x.to_int() + 1).to_byte()
}

pub fn main(world : World) -> Int {
  // 1. Fresh writable Bytes: Bytes::new(const), to_bytes, slice, concat + mut writeback
  let out = Bytes::new(2)
  out[0] = (1).to_byte()
  out[1] = (41).to_byte()
  let mut out_m = out
  bump_byte(mut out_m[1])
  debug_assert(out[0].to_int() == 1 && out[1].to_int() == 42, "fresh Bytes::new")

  let tb = "ab".to_bytes()
  tb[0] = b'Z'
  debug_assert(tb.to_string() == "Zb", "to_bytes writable")

  let cc = tb.concat(out)
  cc[2] = b'!'
  debug_assert(cc[2] == b'!' && cc[3].to_int() == 42, "concat writable")

  // 2. mmap_ro slice is fresh writable (native + Node; Err on Web)
  let mut mmap_slice_ok = 0
  match fs_mmap_ro(ro_path()) {
    Ok(mb) => {
      let sl = mb.slice(0, 4)
      sl[0] = b'X'
      let mut sl_m = sl
      bump_byte(mut sl_m[1])
      debug_assert(sl.to_string() == "XCCD", "mmap slice writable")
      mmap_slice_ok = 1
    }
    Err(_) => ()
  }

  // 3. Sound unsigned & bitmask BCE positive cases
  let lut : FixedArray[Int] = FixedArray::make(256, 0)
  let mut i = 0
  while i < 256 {
    lut[i] = i * 3 + 1
    i = i + 1
  }
  let x = -1234567
  let u : UInt = 0xDEADBEEFU
  let k = x & 15
  let sum = lut[x & 63] + lut[(u >> 24U).to_int()] + lut[(u % 16U).to_int()] + lut[k]
  // x & 63 = (-1234567) & 63 = 57 -> 172
  // u >> 24 = 0xDE = 222 -> 667
  // u % 16 = 0xF = 15 -> 46
  // k = (-1234567) & 15 = 9 -> 28
  // sum = 172 + 667 + 46 + 28 = 913
  debug_assert(sum == 913, "bce sum mismatch: " + sum.to_string())

  // 3b. R3-A TByte 8-bit unsigned wrapping (+, -, +=, -=) + safe Bytes::new(256) indexing
  let bp = (255).to_byte()
  let bq = (1).to_byte()
  let b_wrap_add = bp + bq
  let b_wrap_sub = (0).to_byte() - (1).to_byte()
  debug_assert(b_wrap_add.to_int() == 0, "byte add wrap: " + b_wrap_add.to_int().to_string())
  debug_assert(b_wrap_sub.to_int() == 255, "byte sub wrap: " + b_wrap_sub.to_int().to_string())
  let mut bc = (255).to_byte()
  bc += (1).to_byte()
  debug_assert(bc.to_int() == 0, "byte += wrap: " + bc.to_int().to_string())
  bc -= (1).to_byte()
  debug_assert(bc.to_int() == 255, "byte -= wrap: " + bc.to_int().to_string())
  let btab = Bytes::new(256)
  btab[b_wrap_add.to_int()] = (11).to_byte()
  btab[b_wrap_sub.to_int()] = (22).to_byte()
  btab[bc.to_int()] = (33).to_byte()
  debug_assert(btab[0].to_int() == 11 && btab[255].to_int() == 33, "byte wrap index")

  io_println(world, "p85 ok sum=" + sum.to_string() + " mmap_slice=" + mmap_slice_ok.to_string())
  0
}
EOF

"$PIONC" build --release -o "$TMP_DIR/p85_ok_rel" "$TMP_DIR/p85_ok.pion"
REL_OUT=$("$TMP_DIR/p85_ok_rel")
echo "p85 native release -> $REL_OUT"
test "$REL_OUT" = "p85 ok sum=913 mmap_slice=1"

"$PIONC" build -o "$TMP_DIR/p85_ok_dev" "$TMP_DIR/p85_ok.pion"
DEV_OUT=$("$TMP_DIR/p85_ok_dev")
echo "p85 native dev -> $DEV_OUT"
test "$DEV_OUT" = "$REL_OUT"

# Negative trap 1: direct write on fs_mmap_ro Bytes must trap
cat <<EOF > "$TMP_DIR/p85_ro_direct.pion"
pub fn main(world : World) -> Int {
  let _ = world
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(mb) => { mb[0] = b'X' }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_ro_direct" "$TMP_DIR/p85_ro_direct.pion"
set +e
RO1_ERR=$("$TMP_DIR/p85_ro_direct" 2>&1)
RO1_RC=$?
set -e
echo "p85 ro_direct rc=$RO1_RC -> $RO1_ERR"
test "$RO1_RC" -ne 0
printf '%s' "$RO1_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 2: mut-arg writeback `bump_byte(mut mb[0])` on fs_mmap_ro Bytes must trap
cat <<EOF > "$TMP_DIR/p85_ro_mutwb.pion"
fn bump_byte(mut x : Byte) -> Unit {
  x = (x.to_int() + 1).to_byte()
}
pub fn main(world : World) -> Int {
  let _ = world
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(mb) => {
      let mut mb_m = mb
      bump_byte(mut mb_m[0])
    }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_ro_mutwb" "$TMP_DIR/p85_ro_mutwb.pion"
set +e
RO2_ERR=$("$TMP_DIR/p85_ro_mutwb" 2>&1)
RO2_RC=$?
set -e
echo "p85 ro_mutwb rc=$RO2_RC -> $RO2_ERR"
test "$RO2_RC" -ne 0
printf '%s' "$RO2_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 3: aliased dynamic Array popped inside index expression must trap OOB
cat <<'EOF' > "$TMP_DIR/p85_alias_oob.pion"
fn pop_all(a : Array[Int]) -> Int {
  while a.length() > 0 {
    let _ = a.pop()
  }
  63
}
pub fn main(world : World) -> Int {
  let arr : Array[Int] = Array::make(64, 1)
  let v = arr[pop_all(arr) & 63]
  io_println(world, v.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_alias_oob" "$TMP_DIR/p85_alias_oob.pion"
set +e
OOB_ERR=$("$TMP_DIR/p85_alias_oob" 2>&1)
OOB_RC=$?
set -e
echo "p85 alias_oob rc=$OOB_RC -> $OOB_ERR"
test "$OOB_RC" -ne 0
printf '%s' "$OOB_ERR" | grep -q "out of bounds"

# Negative trap 4 (R2 P1-1): for-range shadows outer u8_range_vars `i` -> must trap OOB
cat <<'EOF' > "$TMP_DIR/p85_shadow_for_oob.pion"
pub fn main(world : World) -> Int {
  let _ = world
  let x = 3
  let t : FixedArray[Int] = FixedArray::make(8, 0)
  let i = x & 7
  let _ = i
  for i in 0..100 {
    t[i] = 1
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_shadow_for_oob" "$TMP_DIR/p85_shadow_for_oob.pion"
set +e
SF_ERR=$("$TMP_DIR/p85_shadow_for_oob" 2>&1)
SF_RC=$?
set -e
echo "p85 shadow_for_oob rc=$SF_RC -> $SF_ERR"
test "$SF_RC" -ne 0
printf '%s' "$SF_ERR" | grep -q "out of bounds"

# Negative trap 5 (R2 P1-1): match arm shadows outer known_writable_bytes `b` -> must trap RO
cat <<EOF > "$TMP_DIR/p85_shadow_match_ro.pion"
pub fn main(world : World) -> Int {
  let _ = world
  let b = Bytes::new(64)
  let _ = b
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(b) => { b[10] = (7).to_byte() }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_shadow_match_ro" "$TMP_DIR/p85_shadow_match_ro.pion"
set +e
SM_ERR=$("$TMP_DIR/p85_shadow_match_ro" 2>&1)
SM_RC=$?
set -e
echo "p85 shadow_match_ro rc=$SM_RC -> $SM_ERR"
test "$SM_RC" -ne 0
printf '%s' "$SM_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 6 (R2 P1-2): local `let M = 15` shadows top-level `let M : Int = 7` -> must trap OOB
cat <<'EOF' > "$TMP_DIR/p85_shadow_const_oob.pion"
let M : Int = 7
pub fn main(world : World) -> Int {
  let t : FixedArray[Int] = FixedArray::make(8, 0)
  let M = 15
  let x = 15
  let v = t[x & M]
  io_println(world, v.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_shadow_const_oob" "$TMP_DIR/p85_shadow_const_oob.pion"
set +e
SC_ERR=$("$TMP_DIR/p85_shadow_const_oob" 2>&1)
SC_RC=$?
set -e
echo "p85 shadow_const_oob rc=$SC_RC -> $SC_ERR"
test "$SC_RC" -ne 0
printf '%s' "$SC_ERR" | grep -q "out of bounds"

# Negative trap 7 (R2 P1-3): user-defined `bytes_from_ptr` wrapping mmap_ro -> must trap RO
cat <<EOF > "$TMP_DIR/p85_shadow_bfp_ro.pion"
fn bytes_from_ptr(b : Bytes, n : Int) -> Bytes {
  let _ = n
  b
}
pub fn main(world : World) -> Int {
  let _ = world
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(mb) => {
      let w = bytes_from_ptr(mb, 8)
      w[0] = b'Z'
    }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_shadow_bfp_ro" "$TMP_DIR/p85_shadow_bfp_ro.pion"
set +e
SB_ERR=$("$TMP_DIR/p85_shadow_bfp_ro" 2>&1)
SB_RC=$?
set -e
echo "p85 shadow_bfp_ro rc=$SB_RC -> $SB_ERR"
test "$SB_RC" -ne 0
printf '%s' "$SB_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 8 (R3-A P1-2a): extern "C" fn bytes_from_ptr wrapping mmap_ro -> must trap RO
cat <<EOF > "$TMP_DIR/p85_extern_bfp_ro.pion"
extern "C" fn bytes_from_ptr(b : Bytes, n : Int) -> Bytes {
  let _ = n
  b
}
pub fn main(world : World) -> Int {
  let _ = world
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(mb) => {
      let out = bytes_from_ptr(mb, 8)
      out[0] = b'Z'
    }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_extern_bfp_ro" "$TMP_DIR/p85_extern_bfp_ro.pion"
set +e
EB_ERR=$("$TMP_DIR/p85_extern_bfp_ro" 2>&1)
EB_RC=$?
set -e
echo "p85 extern_bfp_ro rc=$EB_RC -> $EB_ERR"
test "$EB_RC" -ne 0
printf '%s' "$EB_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 9 (R3-A P1-2b): `let src = src.slice(0, 1)` where outer `src : Wrapper` returns mmap_ro -> must trap RO
cat <<EOF > "$TMP_DIR/p85_shadow_slice_ro.pion"
struct Wrapper {
  b : Bytes
}
fn Wrapper::slice(self : Wrapper, i : Int, j : Int) -> Bytes {
  let _ = i
  let _ = j
  self.b
}
pub fn main(world : World) -> Int {
  let _ = world
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(mb) => {
      let src = Wrapper::{ b: mb }
      let src = src.slice(0, 1)
      src[0] = (1).to_byte()
    }
    Err(e) => panic("unexpected mmap err: " + e)
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_shadow_slice_ro" "$TMP_DIR/p85_shadow_slice_ro.pion"
set +e
SS_ERR=$("$TMP_DIR/p85_shadow_slice_ro" 2>&1)
SS_RC=$?
set -e
echo "p85 shadow_slice_ro rc=$SS_RC -> $SS_ERR"
test "$SS_RC" -ne 0
printf '%s' "$SS_ERR" | grep -q "cannot mutate read-only mmap Bytes"

# Negative trap 10 (R3-A P1-3): `if a.length() >= 8 && opt is Some(a)` shadows outer `a` -> must trap OOB
cat <<'EOF' > "$TMP_DIR/p85_is_shadow_oob.pion"
pub fn main(world : World) -> Int {
  let a : FixedArray[Int] = FixedArray::make(8, 1)
  let small : FixedArray[Int] = FixedArray::make(1, 2)
  let opt : Option[FixedArray[Int]] = Some(small)
  let x = 7
  if a.length() >= 8 && opt is Some(a) {
    let v = a[x & 7]
    io_println(world, v.to_string())
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_is_shadow_oob" "$TMP_DIR/p85_is_shadow_oob.pion"
set +e
IS_ERR=$("$TMP_DIR/p85_is_shadow_oob" 2>&1)
IS_RC=$?
set -e
echo "p85 is_shadow_oob rc=$IS_RC -> $IS_ERR"
test "$IS_RC" -ne 0
printf '%s' "$IS_ERR" | grep -q "out of bounds"

# R4 P1-1a + R5 P1-1/P1-2: `a[0] += grow(a)`, `ab2[0] += g.to_byte()` (user Grower::to_byte), & `Array[String]` slot replacement -> exact value + ASan/LSan 0 UAF/leak
cat <<'EOF' > "$TMP_DIR/p85_compound_grow.pion"
fn grow_b(a : Array[Byte]) -> Byte {
  let mut k = 0
  while k < 128 {
    a.push((k & 255).to_byte())
    k = k + 1
  }
  (5).to_byte()
}
fn grow_i(a : Array[Int]) -> Int {
  let mut k = 0
  while k < 128 {
    a.push(k)
    k = k + 1
  }
  7
}
struct Grower {
  arr : Array[Byte]
}
fn Grower::to_byte(self : Grower) -> Byte {
  let mut k = 0
  while k < 128 {
    self.arr.push((k & 255).to_byte())
    k = k + 1
  }
  (5).to_byte()
}
fn replace_slot(a : Array[String]) -> String {
  a[0] = "replaced_longer_string_payload"
  " world"
}
fn append_opt(a : Array[String], suffix : Option[String]) -> Option[Int] {
  a[0] += suffix?
  Some(a[0].length())
}
fn replace_map_slot(m : Map[String, String]) -> String {
  m["k"] = "other" + "_heap"
  "_suffix"
}
fn replace_vmap_slot(vm : Map[Int, String]) -> String {
  vm[1] = "other" + "_vheap"
  "_vsuf"
}
fn append_map_opt(m : Map[String, String], suffix : Option[String]) -> Option[Int] {
  m["k"] += suffix?
  Some(m["k"].length())
}
fn append_vmap_opt(vm : Map[Int, String], suffix : Option[String]) -> Option[Int] {
  vm[1] += suffix?
  Some(vm[1].length())
}
pub fn main(world : World) -> Int {
  let ab : Array[Byte] = [(10).to_byte()]
  ab[0] += grow_b(ab)
  let ai : Array[Int] = [100]
  ai[0] += grow_i(ai)
  let ab2 : Array[Byte] = [(20).to_byte()]
  let g = Grower::{ arr: ab2 }
  ab2[0] += g.to_byte()
  let as_arr : Array[String] = ["hello" + "_heap"]
  as_arr[0] += replace_slot(as_arr)
  let a_opt : Array[String] = ["base" + "_heap"]
  let mut r = 0
  while r < 8 {
    let none_res = append_opt(a_opt, None)
    debug_assert(none_res is None && a_opt[0] == "base_heap", "append_opt None")
    r = r + 1
  }
  let some_res = append_opt(a_opt, Some("_ok" + "_tail"))
  let some_len = match some_res {
    Some(n) => n
    None => -1
  }
  debug_assert(some_len == 17 && a_opt[0] == "base_heap_ok_tail", "append_opt Some")
  // R7 P1: Map[String, String] & vmap Map[Int, String] compound assign with RHS slot overwrite + `?` early return
  let sm : Map[String, String] = Map([])
  sm.set("k", "orig" + "_s")
  sm["k"] += replace_map_slot(sm)
  debug_assert(sm["k"] == "orig_s_suffix", "map replace_slot: " + sm["k"])
  let vm : Map[Int, String] = Map([])
  vm.set(1, "orig" + "_v")
  vm[1] += replace_vmap_slot(vm)
  debug_assert(vm[1] == "orig_v_vsuf", "vmap replace_slot: " + vm[1])
  let mut mr = 0
  while mr < 8 {
    let mn = append_map_opt(sm, None)
    let vn = append_vmap_opt(vm, None)
    debug_assert(mn is None && sm["k"] == "orig_s_suffix", "map opt None")
    debug_assert(vn is None && vm[1] == "orig_v_vsuf", "vmap opt None")
    mr = mr + 1
  }
  debug_assert(ab[0].to_int() == 15 && ab.length() == 129, "grow_b")
  debug_assert(ai[0] == 107 && ai.length() == 129, "grow_i")
  debug_assert(ab2[0].to_int() == 25 && ab2.length() == 129, "grower_to_byte")
  debug_assert(as_arr[0] == "hello_heap world" && as_arr.length() == 1, "replace_slot")
  io_println(world, "grow_ok=" + ab[0].to_int().to_string() + ":" + ai[0].to_string() + ":" + ab2[0].to_int().to_string() + ":" + as_arr[0] + ":" + a_opt[0] + ":" + sm["k"] + ":" + vm[1])
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_compound_grow" "$TMP_DIR/p85_compound_grow.pion"
GROW_OUT=$("$TMP_DIR/p85_compound_grow")
echo "p85 compound_grow -> $GROW_OUT"
test "$GROW_OUT" = "grow_ok=15:107:25:hello_heap world:base_heap_ok_tail:orig_s_suffix:orig_v_vsuf"
CC_BIN="${CC:-cc}"
ASAN_RT="$TMP_DIR/libpionrt_asan.a"
CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$ASAN_RT"
printf '#!/bin/sh\nexec %s -fsanitize=address -fno-omit-frame-pointer "$@"\n' "$CC_BIN" > "$TMP_DIR/cc-asan"
chmod +x "$TMP_DIR/cc-asan"
CC="$TMP_DIR/cc-asan" PION_RT_LIB="$ASAN_RT" PION_CACHE_DIR="$TMP_DIR/cas_asan" \
  "$PIONC" build --release -o "$TMP_DIR/p85_compound_grow_asan" "$TMP_DIR/p85_compound_grow.pion"
if [ "$(uname -s)" = "Linux" ]; then
  GROW_ASAN=$(ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$TMP_DIR/p85_compound_grow_asan")
else
  GROW_ASAN=$(ASAN_OPTIONS=halt_on_error=1 "$TMP_DIR/p85_compound_grow_asan")
fi
echo "p85 compound_grow ASan/LSan -> $GROW_ASAN"
test "$GROW_ASAN" = "grow_ok=15:107:25:hello_heap world:base_heap_ok_tail:orig_s_suffix:orig_v_vsuf"

# R4 P1-1b: `a[0] += shrink(a)` clears Array[Byte] inside RHS -> must trap OOB on writeback
cat <<'EOF' > "$TMP_DIR/p85_compound_shrink_oob.pion"
fn shrink_b(a : Array[Byte]) -> Byte {
  a.clear()
  (1).to_byte()
}
pub fn main(world : World) -> Int {
  let _ = world
  let ab : Array[Byte] = [(10).to_byte()]
  ab[0] += shrink_b(ab)
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_compound_shrink_oob" "$TMP_DIR/p85_compound_shrink_oob.pion"
set +e
SH_ERR=$("$TMP_DIR/p85_compound_shrink_oob" 2>&1)
SH_RC=$?
set -e
echo "p85 compound_shrink_oob rc=$SH_RC -> $SH_ERR"
test "$SH_RC" -ne 0
printf '%s' "$SH_ERR" | grep -q "out of bounds"

# R4 P1-2: outer `let n = a.length()`, inner `let a = short`, then `if n >= 8 { a[x & 7] }` -> must trap OOB
cat <<'EOF' > "$TMP_DIR/p85_len_alias_shadow_oob.pion"
pub fn main(world : World) -> Int {
  let a : FixedArray[Int] = FixedArray::make(8, 1)
  let short : FixedArray[Int] = FixedArray::make(1, 2)
  let n = a.length()
  let x = 7
  {
    let a = short
    if n >= 8 {
      let v = a[x & 7]
      io_println(world, v.to_string())
    }
  }
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_len_alias_shadow_oob" "$TMP_DIR/p85_len_alias_shadow_oob.pion"
set +e
LA_ERR=$("$TMP_DIR/p85_len_alias_shadow_oob" 2>&1)
LA_RC=$?
set -e
echo "p85 len_alias_shadow_oob rc=$LA_RC -> $LA_ERR"
test "$LA_RC" -ne 0
printf '%s' "$LA_ERR" | grep -q "out of bounds"

# R4 P1-4 runtime: cross-pkg K=1 (lib) vs K=8 (app) switch & loop versioning must use lib's K=1
mkdir -p "$TMP_DIR/r4xpkg/r4lib/src" "$TMP_DIR/r4xpkg/r4app/src"
cat <<'EOF' > "$TMP_DIR/r4xpkg/r4lib/pion.toml"
[package]
name = "r4lib"
version = "0.1.0"
EOF
cat <<'EOF' > "$TMP_DIR/r4xpkg/r4lib/src/lib.pion"
let K : Int = 1
pub fn sw6[T](a : FixedArray[T], idx : Int) -> Int {
  let _ = a[0]
  if idx == K { 101 }
  else if idx == 2 { 102 }
  else if idx == 3 { 103 }
  else if idx == 4 { 104 }
  else if idx == 5 { 105 }
  else if idx == 6 { 106 }
  else { 0 }
}
pub fn loop_k[T](a : FixedArray[T]) -> Int {
  let mut s = 0
  let mut j = 0
  while j < K {
    let _ = a[j]
    s = s + 1
    j = j + 1
  }
  s
}
EOF
cat <<'EOF' > "$TMP_DIR/r4xpkg/r4app/pion.toml"
[package]
name = "r4app"
version = "0.1.0"

[dependencies]
r4lib = { path = "../r4lib" }
EOF
cat <<'EOF' > "$TMP_DIR/r4xpkg/r4app/src/main.pion"
import "r4lib"
let K : Int = 8
pub fn main(world : World) -> Int {
  let a : FixedArray[Int] = FixedArray::make(1, 9)
  let r_sw = r4lib::sw6(a, 1)
  let r_lp = r4lib::loop_k(a)
  let _ = K
  io_println(world, "xpkg=" + r_sw.to_string() + ":" + r_lp.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_r4xpkg" "$TMP_DIR/r4xpkg/r4app"
XPKG_OUT=$("$TMP_DIR/p85_r4xpkg")
echo "p85 r4xpkg -> $XPKG_OUT"
test "$XPKG_OUT" = "xpkg=101:1"

# R4 P1-5: #verify TByte `/=` and `%=` dynamic division by zero must panic on BOTH Native and Wasm32
cat <<'EOF' > "$TMP_DIR/p85_verify_byte_div0.pion"
#verify
fn div_byte(mut buf : Array[Byte], d : Byte) -> Unit {
  buf[0] /= d
}
#verify
fn rem_byte(mut buf : Array[Byte], d : Byte) -> Unit {
  buf[0] %= d
}
pub fn main(world : World) -> Int {
  let d = if world_args(world).length() >= 0 { (0).to_byte() } else { (1).to_byte() }
  let mut buf : Array[Byte] = [(10).to_byte()]
  div_byte(mut buf, d)
  rem_byte(mut buf, d)
  0
}
EOF
cat <<'EOF' > "$TMP_DIR/p85_verify_byte_rem0.pion"
#verify
fn rem_byte(mut buf : Array[Byte], d : Byte) -> Unit {
  buf[0] %= d
}
pub fn main(world : World) -> Int {
  let d = if world_args(world).length() >= 0 { (0).to_byte() } else { (1).to_byte() }
  let mut buf : Array[Byte] = [(10).to_byte()]
  rem_byte(mut buf, d)
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_verify_byte_div0" "$TMP_DIR/p85_verify_byte_div0.pion"
set +e
VD_ERR=$("$TMP_DIR/p85_verify_byte_div0" 2>&1)
VD_RC=$?
set -e
echo "p85 verify_byte_div0 native rc=$VD_RC -> $VD_ERR"
test "$VD_RC" -ne 0
printf '%s' "$VD_ERR" | grep -q "division by zero"
"$PIONC" build --release -o "$TMP_DIR/p85_verify_byte_rem0" "$TMP_DIR/p85_verify_byte_rem0.pion"
set +e
VR_ERR=$("$TMP_DIR/p85_verify_byte_rem0" 2>&1)
VR_RC=$?
set -e
echo "p85 verify_byte_rem0 native rc=$VR_RC -> $VR_ERR"
test "$VR_RC" -ne 0
printf '%s' "$VR_ERR" | grep -q "division by zero"
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p85_verify_byte_div0.wasm" "$TMP_DIR/p85_verify_byte_div0.pion"
  set +e
  VDW_ERR=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85_verify_byte_div0.wasm" 2>&1)
  VDW_RC=$?
  set -e
  echo "p85 verify_byte_div0 wasm32 rc=$VDW_RC -> $VDW_ERR"
  test "$VDW_RC" -ne 0
  printf '%s' "$VDW_ERR" | grep -q "division by zero"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p85_verify_byte_rem0.wasm" "$TMP_DIR/p85_verify_byte_rem0.pion"
  set +e
  VRW_ERR=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85_verify_byte_rem0.wasm" 2>&1)
  VRW_RC=$?
  set -e
  echo "p85 verify_byte_rem0 wasm32 rc=$VRW_RC -> $VRW_ERR"
  test "$VRW_RC" -ne 0
  printf '%s' "$VRW_ERR" | grep -q "division by zero"
fi

# Wasm32 Node + Web parity
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p85_ok.wasm" "$TMP_DIR/p85_ok.pion"
  WASM_NODE=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85_ok.wasm")
  echo "p85 wasm32 node -> $WASM_NODE"
  test "$WASM_NODE" = "p85 ok sum=913 mmap_slice=1"
  WASM_WEB=$(node --input-type=module -e '
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const { runWasmBytes } = await import(pathToFileURL(process.argv[1]).href);
const out = [];
await runWasmBytes(fs.readFileSync(process.argv[2]), {
  print: (s) => out.push(s),
  println: (s) => out.push(s + "\n"),
});
process.stdout.write(out.join("").trim());
' "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs" "$TMP_DIR/p85_ok.wasm")
  echo "p85 wasm32 web -> $WASM_WEB"
  test "$WASM_WEB" = "p85 ok sum=913 mmap_slice=0"
fi

echo "PASS: p85_bytes_bce (G3-A writable Bytes + RO direct/compound trap + G4 unsigned/bitmask BCE + alias OOB trap + Wasm32)"
