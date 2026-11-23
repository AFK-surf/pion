#!/bin/sh
# P74-C E2E soundness regression (Native --release + Native ASan/LSan + Wasm32 Node):
# 1. Exact whiteboard repro: `Buf { arr: Array[Double], mut n: Int }`, `let d = dst.arr`,
#    loop calling `grow_slot(dst)` growing 0 -> 12,000+ (multiple reallocs) & writing `d[w]`.
# 2. Aliased direct `push` growth: `let b = a; while k < 2000 { b.push(k); a[k] = k * 2; k += 1 }`.
# 3. Aliased `clear`/`pop` shrink: `if d.length() >= 10 { clear_buf(dst); ... }` must re-read
#    `d.length() == 0` and trap OOB on `d[5]` (no stale `known_min_len_arrs` BCE).
# 4. Borrowed element across aliased overwrite/growth UAF prevention:
#    `let s = d[0]; mutate_or_grow(dst); check(s)` under ASan/LSan & Wasm32.
# 5. P72-A M5 lattice zero-alloc non-regression (`insert_top8` and `run_lattice` stay 0 heap allocs).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
CC_BIN="${CC:-cc}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Cases 1, 2, 3a, 4: Main soundness program (Native + ASan/LSan + Wasm32) ---
cat <<'EOF' > "$TMP_DIR/p74c_main.pion"
struct Buf {
  arr : Array[Double]
  mut n : Int
}

fn grow_slot(b : Buf) -> Int {
  let pos = b.n * 60
  while b.arr.length() < pos + 60 {
    b.arr.push(0.0)
  }
  pos
}

fn copy_into(dst : Buf, count : Int) -> Unit {
  let d = dst.arr
  let mut k = 0
  while k < count {
    let w = grow_slot(dst)
    d[w] = (k + 1).to_double()
    d[w + 30] = (k * 2 + 5).to_double()
    d[w + 59] = (k * 3 + 7).to_double()
    dst.n = dst.n + 1
    k = k + 1
  }
}

enum Helper {
  Tag
}

fn Helper::grow(b : Buf) -> Int {
  let pos = b.n * 60
  while b.arr.length() < pos + 60 {
    b.arr.push(0.0)
  }
  pos
}

fn copy_into_via_enum_method(dst : Buf, count : Int) -> Unit {
  let d = dst.arr
  let mut k = 0
  while k < count {
    let w = Helper::grow(dst)
    d[w] = (k + 2).to_double()
    d[w + 59] = (k * 3 + 9).to_double()
    dst.n = dst.n + 1
    k = k + 1
  }
}

struct StrBuf {
  arr : Array[String]
}

fn clear_str_buf(b : StrBuf) -> Unit {
  b.arr.clear()
}

fn mutate_and_grow_str_buf(b : StrBuf) -> Unit {
  b.arr[0] = "overwritten_0_" + (10 + 1).to_string()
  let mut i = 0
  while i < 128 {
    b.arr.push("grow_" + i.to_string())
    i = i + 1
  }
}

fn main(world : World) -> Unit {
  // Case 1: Whiteboard Buf/grow_slot 0 -> 12,000+ (200 slots * 60 doubles)
  let dst = Buf::{ arr: [], n: 0 }
  copy_into(dst, 200)
  if dst.n != 200 || dst.arr.length() != 12000 {
    panic("Case 1: wrong length after grow_slot")
  }
  let mut k = 0
  let mut sum1 : Int64 = 0L
  while k < 200 {
    let w = k * 60
    if dst.arr[w] != (k + 1).to_double() ||
      dst.arr[w + 30] != (k * 2 + 5).to_double() ||
      dst.arr[w + 59] != (k * 3 + 7).to_double() {
      panic("Case 1: slot value mismatch")
    }
    sum1 = sum1 + dst.arr[w].to_int().to_int64() + dst.arr[w + 59].to_int().to_int64()
    k = k + 1
  }

  // Case 2: Aliased direct `push` growth (`let b = a; while k < 2000 { b.push(k); a[k] = k * 2 }`)
  let a : Array[Int] = []
  let b = a
  let mut i = 0
  while i < 2000 {
    b.push(i)
    a[i] = i * 2
    i = i + 1
  }
  if a.length() != 2000 || b.length() != 2000 {
    panic("Case 2: wrong aliased push length")
  }
  let mut sum2 : Int64 = 0L
  i = 0
  while i < 2000 {
    if a[i] != i * 2 || b[i] != i * 2 {
      panic("Case 2: aliased push value mismatch")
    }
    sum2 = sum2 + a[i].to_int64()
    i = i + 1
  }

  // Case 3a: Aliased clear_buf resets length accurately
  let sb = StrBuf::{ arr: [] }
  let d = sb.arr
  i = 0
  while i < 16 {
    d.push("elem_" + i.to_string())
    i = i + 1
  }
  let mut cleared_len = -1
  if d.length() >= 10 {
    clear_str_buf(sb)
    cleared_len = d.length()
  }
  if cleared_len != 0 {
    panic("Case 3a: stale length after clear_str_buf")
  }

  // Case 4: Borrowed element across aliased overwrite + realloc must NOT UAF
  let sb2 = StrBuf::{ arr: [] }
  let d2 = sb2.arr
  d2.push("orig_" + (40 + 2).to_string())
  d2.push("second_" + (10 + 2).to_string())
  let s = d2[0]
  mutate_and_grow_str_buf(sb2)
  if s != "orig_42" || d2[0] != "overwritten_0_11" || d2.length() != 130 {
    panic("Case 4: borrowed elem corrupted or UAF across aliased overwrite/grow")
  }

  // Case 4b: Aliased direct element overwrite without call (`b2[0] = ...` while `s2 = a2[0]` live)
  let a2 : Array[String] = ["live_" + (70 + 7).to_string(), "other"]
  let b2 = a2
  let s2 = a2[0]
  b2[0] = "clobbered_" + (80 + 8).to_string()
  if s2 != "live_77" || a2[0] != "clobbered_88" {
    panic("Case 4b: borrowed elem corrupted across aliased element assign")
  }

  // Case 1b: Enum static method `Helper::grow(dst)` inside loop must NOT be treated as pure variant ctor
  let dst1b = Buf::{ arr: [], n: 0 }
  copy_into_via_enum_method(dst1b, 200)
  if dst1b.n != 200 || dst1b.arr.length() != 12000 {
    panic("Case 1b: wrong length after Helper::grow")
  }
  let mut sum1b : Int64 = 0L
  k = 0
  while k < 200 {
    let w = k * 60
    if dst1b.arr[w] != (k + 2).to_double() || dst1b.arr[w + 59] != (k * 3 + 9).to_double() {
      panic("Case 1b: slot value mismatch after Helper::grow")
    }
    sum1b = sum1b + dst1b.arr[w].to_int().to_int64() + dst1b.arr[w + 59].to_int().to_int64()
    k = k + 1
  }

  // Case 4c: Aliased element overwrite inside compound `if` / `while` last_use must NOT UAF
  let a3 : Array[String] = ["orig_if_" + (90 + 9).to_string(), "other"]
  let b3 = a3
  let s3 = a3[0]
  let mut ok_if = false
  if b3.length() > 0 {
    b3[0] = "clobber_if_" + (10 + 1).to_string()
    if s3 == "orig_if_99" {
      ok_if = true
    }
  }
  if !ok_if || a3[0] != "clobber_if_11" {
    panic("Case 4c-if: borrowed elem UAF in compound if last_use")
  }

  let a4 : Array[String] = ["orig_wh_" + (50 + 5).to_string(), "other"]
  let b4 = a4
  let s4 = a4[0]
  let mut wi = 0
  let mut wh_hits = 0
  while wi < 2 {
    if s4 == "orig_wh_55" {
      wh_hits = wh_hits + 1
    }
    b4[0] = "clobber_wh_" + wi.to_string()
    wi = wi + 1
  }
  if wh_hits != 2 || a4[0] != "clobber_wh_1" {
    panic("Case 4c-while: borrowed elem UAF in while last_use")
  }

  io_println(world, "p74c ok sum1=" + sum1.to_string() + " sum1b=" + sum1b.to_string() + " sum2=" + sum2.to_string() + " clen=" + cleared_len.to_string() + " s=" + s + " s2=" + s2 + " wh=" + wh_hits.to_string())
}
EOF

EXPECTED="p74c ok sum1=81200 sum1b=81800 sum2=3998000 clen=0 s=orig_42 s2=live_77 wh=2"

# 1. Native --release
"$PIONC" build --release -o "$TMP_DIR/p74c_native" "$TMP_DIR/p74c_main.pion"
NAT_OUT=$("$TMP_DIR/p74c_native")
echo "p74c native -> $NAT_OUT"
test "$NAT_OUT" = "$EXPECTED"

# 2. Native ASan/LSan
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  "$PIONC" build --release --emit-obj "$TMP_DIR/p74c_main.o" "$TMP_DIR/p74c_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p74c_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p74c_asan"
  ASAN_OUT=$("$TMP_DIR/p74c_asan")
  echo "p74c ASan/LSan -> $ASAN_OUT"
  test "$ASAN_OUT" = "$EXPECTED"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p74c ASan check"
fi

# 3. Wasm32 (Node)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p74c_main.wasm" "$TMP_DIR/p74c_main.pion"
  WASM_OUT=$(node "$WASM_RT" "$TMP_DIR/p74c_main.wasm")
  echo "p74c wasm32 -> $WASM_OUT"
  test "$WASM_OUT" = "$EXPECTED"
fi

# --- Case 3b: Straight-line aliased clear MUST trap OOB (no stale known_min_len_arrs BCE) ---
cat <<'EOF' > "$TMP_DIR/p74c_oob.pion"
struct Box {
  arr : Array[Int]
}

fn clear_box(b : Box) -> Unit {
  b.arr.clear()
}

fn main(world : World) -> Unit {
  let bx = Box::{ arr: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11] }
  let d = bx.arr
  if d.length() >= 10 {
    clear_box(bx)
    let x = d[5]
    io_println(world, "BUG=" + x.to_string())
  }
}
EOF

"$PIONC" build --release -o "$TMP_DIR/p74c_oob_native" "$TMP_DIR/p74c_oob.pion"
set +e
OOB_NAT_ERR=$("$TMP_DIR/p74c_oob_native" 2>&1)
OOB_NAT_RC=$?
set -e
echo "p74c Case 3b OOB native rc=$OOB_NAT_RC -> $OOB_NAT_ERR"
test "$OOB_NAT_RC" -ne 0
echo "$OOB_NAT_ERR" | grep -q "out of bounds"

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p74c_oob.wasm" "$TMP_DIR/p74c_oob.pion"
  set +e
  OOB_WASM_ERR=$(node "$WASM_RT" "$TMP_DIR/p74c_oob.wasm" 2>&1)
  OOB_WASM_RC=$?
  set -e
  echo "p74c Case 3b OOB wasm32 rc=$OOB_WASM_RC"
  test "$OOB_WASM_RC" -ne 0
  echo "$OOB_WASM_ERR" | grep -q "out of bounds"
fi

# --- Case 5: P72-A M5 lattice zero-alloc non-regression ---
sh "$ROOT_DIR/tests/e2e/p72a_flat_pod_opt/run_e2e.sh" "$PIONC"

echo "PASS: p74c_licm_alias_soundness (Native + ASan/LSan + Wasm32 + OOB + P72-A non-regression)"
