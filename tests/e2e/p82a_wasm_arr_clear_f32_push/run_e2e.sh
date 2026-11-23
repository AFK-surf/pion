#!/bin/sh
# P82-A E2E: Wasm32 pion_arr_clear flat inline RC struct arrays (stride > 8, bitmask)
# + hot-loop Array[Float32].push (stride == 4) guard across Native rel/dev, ASan/LSan,
# and Wasm32 Node + Web (release + dev).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
CC_BIN="${CC:-cc}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<'EOF' > "$TMP_DIR/p82a_main.pion"
struct UndoEntry {
  pos : Int,
  text : String,
  end_pos : Int,
}

struct FlatClear6 {
  a : Int,
  b : String,
  c : Int,
  d : String,
  e : Double,
  f : Array[Int],
}

fn test_undo_clear() -> Int {
  let stack : Array[UndoEntry] = []
  let mut i = 0
  while i < 20 {
    let s = "hex_" + i.to_string() + "_fff"
    stack.push(UndoEntry::{ pos: i + 3, text: s, end_pos: i + 6 })
    i += 1
  }
  if stack.length() != 20 || stack[0].pos != 3 || stack[0].text != "hex_0_fff" || stack[19].end_pos != 25 {
    panic("undo push mismatch")
  }
  // Clear non-empty flat RC struct array (slot 0 = non-zero scalar 3, slot 1 = heap String, slot 2 = scalar 6)
  stack.clear()
  if stack.length() != 0 {
    panic("undo clear len != 0")
  }
  // Idempotent clear on empty array
  stack.clear()
  if stack.length() != 0 {
    panic("undo clear empty len != 0")
  }
  // Re-push, copy, reverse, pop, clear
  i = 0
  while i < 8 {
    stack.push(UndoEntry::{ pos: 100 + i, text: "redo_" + i.to_string(), end_pos: 200 + i })
    i += 1
  }
  let cp = stack.copy()
  cp.reverse()
  let popped = match cp.pop() {
    Some(e) => e
    None => panic("undo pop None")
  }
  if popped.pos != 100 || popped.text != "redo_0" || popped.end_pos != 200 {
    panic("undo copy/reverse/pop mismatch")
  }
  let mut acc = 0
  i = 0
  while i < cp.length() {
    acc += cp[i].pos + cp[i].text.length() + cp[i].end_pos
    i += 1
  }
  cp.clear()
  stack.clear()
  acc
}

fn test_flat6_clear() -> Int {
  let arr : Array[FlatClear6] = []
  let mut i = 0
  while i < 16 {
    arr.push(FlatClear6::{
      a: i + 11,
      b: "b_" + i.to_string(),
      c: i * 3 + 7,
      d: "d_" + (i * 2).to_string(),
      e: i.to_double() + 0.5,
      f: [i, i + 1, i + 2],
    })
    i += 1
  }
  if arr.length() != 16 || arr[15].b != "b_15" || arr[15].d != "d_30" || arr[15].f[2] != 17 {
    panic("flat6 push mismatch")
  }
  arr.clear()
  if arr.length() != 0 {
    panic("flat6 clear len != 0")
  }
  arr.clear()
  i = 0
  while i < 6 {
    arr.push(FlatClear6::{
      a: i + 1,
      b: "nb_" + i.to_string(),
      c: i + 2,
      d: "nd_" + i.to_string(),
      e: 1.25,
      f: [i * 10, i * 10 + 1],
    })
    i += 1
  }
  let cp = arr.copy()
  cp.reverse()
  let last = match cp.pop() {
    Some(x) => x
    None => panic("flat6 pop None")
  }
  if last.a != 1 || last.b != "nb_0" || last.d != "nd_0" || last.f[1] != 1 {
    panic("flat6 pop mismatch")
  }
  let mut acc = 0
  i = 0
  while i < cp.length() {
    acc += cp[i].a + cp[i].c + cp[i].b.length() + cp[i].d.length() + cp[i].f[0] + cp[i].f[1]
    i += 1
  }
  cp.clear()
  arr.clear()
  acc
}

fn test_hot_f32_push() -> Int {
  // Pre-allocated capacity triggers `len < cap` hot-path inline push guard in Wasm32
  let xs : Array[Float32] = Array::with_capacity(64)
  let mut i = 0
  while i < 64 {
    xs.push(Float32::from_int(i) * 0.25f - 4.0f)
    i += 1
  }
  // Push more to also exercise growth + post-growth hot-path pushes
  while i < 192 {
    xs.push(Float32::from_int(i) * 0.25f - 4.0f)
    i += 1
  }
  if xs.length() != 192 {
    panic("f32 len != 192")
  }
  let mut sum_bits = 0
  i = 0
  while i < 192 {
    let want = Float32::from_int(i) * 0.25f - 4.0f
    if xs[i].to_bits() != want.to_bits() {
      panic("f32 mismatch at " + i.to_string())
    }
    sum_bits = sum_bits ^ xs[i].to_bits()
    i += 1
  }
  xs.clear()
  if xs.length() != 0 {
    panic("f32 clear len != 0")
  }
  sum_bits
}

pub fn main(world : World) -> Int {
  let u = test_undo_clear()
  let f6 = test_flat6_clear()
  let fb = test_hot_f32_push()
  io_println(world, "p82a ok u=" + u.to_string() + " f6=" + f6.to_string() + " fb=" + fb.to_string())
  0
}
EOF

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p82a_rel" "$TMP_DIR/p82a_main.pion"
OUT_REL=$("$TMP_DIR/p82a_rel")
echo "p82a native release -> $OUT_REL"
echo "$OUT_REL" | grep -q "^p82a ok "

"$PIONC" build -o "$TMP_DIR/p82a_dev" "$TMP_DIR/p82a_main.pion"
OUT_DEV=$("$TMP_DIR/p82a_dev")
echo "p82a native dev -> $OUT_DEV"
test "$OUT_DEV" = "$OUT_REL"

# 2. Native ASan/LSan (0 leaks, 0 UAF)
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  "$PIONC" build --release --emit-obj "$TMP_DIR/p82a_main.o" "$TMP_DIR/p82a_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p82a_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p82a_asan"
  OUT_ASAN=$("$TMP_DIR/p82a_asan")
  echo "p82a ASan/LSan -> $OUT_ASAN"
  test "$OUT_ASAN" = "$OUT_REL"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p82a ASan check"
fi

# 3. Wasm32 Node + Web (release + dev)
if command -v node >/dev/null 2>&1; then
  for mode in release dev; do
    if [ "$mode" = "release" ]; then
      "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p82a_${mode}.wasm" "$TMP_DIR/p82a_main.pion"
    else
      "$PIONC" build --target wasm32 -o "$TMP_DIR/p82a_${mode}.wasm" "$TMP_DIR/p82a_main.pion"
    fi
    OUT_NODE=$(node "$WASM_RT" "$TMP_DIR/p82a_${mode}.wasm")
    echo "p82a wasm32 node ($mode) -> $OUT_NODE"
    test "$OUT_NODE" = "$OUT_REL"

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
    ' "$TMP_DIR/p82a_${mode}.wasm" "$WASM_RT_WEB")"
    echo "p82a wasm32 web ($mode) -> $OUT_WEB"
    test "$OUT_WEB" = "$OUT_REL"
  done
fi

echo "PASS: p82a_wasm_arr_clear_f32_push (Native rel+dev + ASan/LSan + Wasm32 Node+Web rel+dev)"
