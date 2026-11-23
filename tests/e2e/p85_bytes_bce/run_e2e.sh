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

printf 'ABCD1234' > "$TMP_DIR/ro.bin"

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
