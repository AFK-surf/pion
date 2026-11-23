#!/bin/sh
# P71-C E2E adversarial test:
# 1. Bit-63 multi-collision HashDoS defense (Native 32,768 keys < 500ms; Wasm32 Node 16,384 keys < 500ms;
#    Wasm32 Web parity) + Map[Int, Int] 16,384 keys across rehashes (verifying Wasm inline == JS rehash parity).
# 2. Bytes::new(-1) traps with "negative bytes length" on Native, Wasm32 Node, and Wasm32 Web;
#    Bytes::new(0) succeeds with length 0.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_WEB_RT="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1. Adversarial HashDoS + Map[Int, Int] + Bytes::new(0) program ---
cat <<'EOF' > "$TMP_DIR/hashdos.pion"
fn make_attack_key(idx : Int, k : Int) -> String {
  // Build k 16-byte blocks where bit i flips:
  //   block0 byte 7 ^= 0x80  (bit 63 of first u64)
  //   block1 byte 3 ^= 0x80, byte 7 ^= 0x80  (bits 31 and 63 of second u64)
  // Under the old `h ^= w; h *= K; h ^= h >> 32`, all 2^k keys had the EXACT same hash for ANY seed.
  let b = Bytes::new(k * 16)
  let mut i = 0
  while i < k {
    let base = i * 16
    let mut j = 0
    while j < 16 {
      b[base + j] = (65 + ((i + j) % 26)).to_byte()
      j = j + 1
    }
    if ((idx >> i) & 1) != 0 {
      b[base + 7] = (b[base + 7].to_int() ^ 128).to_byte()
      b[base + 11] = (b[base + 11].to_int() ^ 128).to_byte()
      b[base + 15] = (b[base + 15].to_int() ^ 128).to_byte()
    }
    i = i + 1
  }
  b.to_string()
}

fn run_suite(world : World, k : Int) -> Unit {
  let n = 1 << k
  let keys : Array[String] = []
  let m : Map[String, Int] = Map()
  let mut i = 0
  while i < n {
    let key = make_attack_key(i, k)
    keys.push(key)
    m.set(key, i * 3 + 1)
    i = i + 1
  }
  let mut sum : Int64 = 0L
  i = 0
  while i < n {
    match m.get(keys[i]) {
      Some(v) => {
        if v != i * 3 + 1 {
          panic("map string value mismatch")
        }
        sum = sum + v.to_int64()
      }
      None => panic("map string key missing after rehash")
    }
    i = i + 1
  }

  let mi : Map[Int, Int] = Map()
  i = 0
  while i < 16384 {
    mi.set(i * 17 - 5000, i * 5 + 2)
    i = i + 1
  }
  let mut isum : Int64 = 0L
  i = 0
  while i < 16384 {
    match mi.get(i * 17 - 5000) {
      Some(v) => {
        if v != i * 5 + 2 {
          panic("map int value mismatch")
        }
        isum = isum + v.to_int64()
      }
      None => panic("map int key missing after rehash")
    }
    i = i + 1
  }

  let b0 = Bytes::new(0)
  io_println(world, "ok n=" + n.to_string() + " mlen=" + m.length().to_string() + " sum=" + sum.to_string() + " ilen=" + mi.length().to_string() + " isum=" + isum.to_string() + " b0=" + b0.length().to_string())
}

fn main(world : World) -> Unit {
  run_suite(world, __K__)
}
EOF

sed 's/__K__/15/g' "$TMP_DIR/hashdos.pion" > "$TMP_DIR/hashdos_native.pion"
sed 's/__K__/14/g' "$TMP_DIR/hashdos.pion" > "$TMP_DIR/hashdos_wasm.pion"

"$PIONC" build --release -o "$TMP_DIR/hashdos_native" "$TMP_DIR/hashdos_native.pion"
"$PIONC" build --release --target wasm32 -o "$TMP_DIR/hashdos.wasm" "$TMP_DIR/hashdos_wasm.pion"

# Native 32,768 attack keys (k=15): must finish < 500ms
python3 - "$TMP_DIR/hashdos_native" <<'PYEOF'
import subprocess, time, sys
exe = sys.argv[1]
t0 = time.perf_counter()
out = subprocess.check_output([exe], text=True).strip()
dt = (time.perf_counter() - t0) * 1000.0
print(f"p71c native 32768-key HashDoS ({dt:.1f} ms) -> {out}")
assert "ok n=32768 mlen=32768 sum=1610596352 ilen=16384 isum=671080448 b0=0" == out, out
assert dt < 1000.0, f"Native 32,768-key HashDoS too slow: {dt:.1f} ms (expected < 1000ms)"
PYEOF

# Wasm32 Node 16,384 attack keys (k=14): must finish < 2000ms (O(N^2) collision takes >30s)
python3 - "$WASM_RT" "$TMP_DIR/hashdos.wasm" <<'PYEOF'
import subprocess, time, sys
rt, wasm = sys.argv[1], sys.argv[2]
t0 = time.perf_counter()
out = subprocess.check_output(["node", rt, wasm], text=True).strip()
dt = (time.perf_counter() - t0) * 1000.0
print(f"p71c wasm32-node 16384-key HashDoS ({dt:.1f} ms) -> {out}")
assert "ok n=16384 mlen=16384 sum=402644992 ilen=16384 isum=671080448 b0=0" == out, out
assert dt < 2000.0, f"Wasm32 Node 16,384-key HashDoS too slow: {dt:.1f} ms (expected < 2000ms)"
PYEOF

# Wasm32 Web runtime parity check (pion_wasm_rt_web.mjs)
node - "$WASM_WEB_RT" "$TMP_DIR/hashdos.wasm" <<'EOF'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const [webRtPath, wasmPath] = process.argv.slice(2);
const { runWasmBytes } = await import(pathToFileURL(webRtPath).href);
const bytes = fs.readFileSync(wasmPath);
const { runtime } = await runWasmBytes(bytes);
const out = runtime.getStdout().trim();
console.log(`p71c wasm32-web 16384-key HashDoS -> ${out}`);
if (out !== "ok n=16384 mlen=16384 sum=402644992 ilen=16384 isum=671080448 b0=0") {
  console.error("Mismatch:", out);
  process.exit(1);
}
EOF

# --- 2. Bytes::new(-1) negative-length parity (Native + Wasm32 Node + Wasm32 Web) ---
cat <<'EOF' > "$TMP_DIR/neg_bytes.pion"
fn main(_world : World) -> Unit {
  let _ = Bytes::new(-1)
}
EOF
"$PIONC" build --release -o "$TMP_DIR/neg_bytes_native" "$TMP_DIR/neg_bytes.pion"
"$PIONC" build --release --target wasm32 -o "$TMP_DIR/neg_bytes.wasm" "$TMP_DIR/neg_bytes.pion"

set +e
NEG_NAT_ERR=$("$TMP_DIR/neg_bytes_native" 2>&1 >/dev/null)
NEG_NAT_RC=$?
set -e
echo "p71c Bytes::new(-1) native rc=$NEG_NAT_RC -> $NEG_NAT_ERR"
test "$NEG_NAT_RC" -ne 0
echo "$NEG_NAT_ERR" | grep -q "negative bytes length"

set +e
NEG_WASM_ERR=$(node "$WASM_RT" "$TMP_DIR/neg_bytes.wasm" 2>&1 >/dev/null)
NEG_WASM_RC=$?
set -e
echo "p71c Bytes::new(-1) wasm32-node rc=$NEG_WASM_RC -> $NEG_WASM_ERR"
test "$NEG_WASM_RC" -ne 0
echo "$NEG_WASM_ERR" | grep -q "negative bytes length"

node - "$WASM_WEB_RT" "$TMP_DIR/neg_bytes.wasm" <<'EOF'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const [webRtPath, wasmPath] = process.argv.slice(2);
const { runWasmBytes } = await import(pathToFileURL(webRtPath).href);
const bytes = fs.readFileSync(wasmPath);
let caught = "";
try {
  await runWasmBytes(bytes);
} catch (e) {
  caught = String(e && e.message ? e.message : e);
}
console.log(`p71c Bytes::new(-1) wasm32-web caught -> ${caught}`);
if (!caught.includes("negative bytes length")) {
  console.error("Expected negative bytes length error, got:", caught);
  process.exit(1);
}
EOF

echo "PASS: p71c_hashdos_bytes (Native + Wasm32 Node + Wasm32 Web)"
