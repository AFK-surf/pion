#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== P85 E2E: Hardware ROR + Bitops (rotate/clz/ctz/popcnt) + Method Arity Check ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
fn check_u32(x : UInt, n : Int) -> String {
  let rl = x.rotate_left(n)
  let rr = x.rotate_right(n)
  let lz = x.leading_zeros()
  let tz = x.trailing_zeros()
  let co = x.count_ones()
  let i_or = (x << 7) | (x >> 25)
  let i_xor = (x >> 13) ^ (x << 19)
  let i_add = (x << 5) + (x >> 27)
  let i_var_r = (x >> n) | (x << (32 - n))
  let i_var_l = (x << n) | (x >> (32 - n))
  if i_or != x.rotate_left(7) || i_xor != x.rotate_right(13) || i_add != x.rotate_left(5) {
    return "BAD_IDIOM_CONST"
  }
  if i_var_r != rr || i_var_l != rl {
    return "BAD_IDIOM_VAR"
  }
  "\{rl}:\{rr}:\{lz}:\{tz}:\{co}"
}

fn check_i32(x : Int, n : Int) -> String {
  let rl = x.rotate_left(n)
  let rr = x.rotate_right(n)
  let lz = x.leading_zeros()
  let tz = x.trailing_zeros()
  let co = x.count_ones()
  "\{rl}:\{rr}:\{lz}:\{tz}:\{co}"
}

fn check_u64(x : UInt64, n : Int) -> String {
  let rl = x.rotate_left(n)
  let rr = x.rotate_right(n)
  let lz = x.leading_zeros()
  let tz = x.trailing_zeros()
  let co = x.count_ones()
  let i_or = (x << 11) | (x >> 53)
  let i_xor = (x >> 17) ^ (x << 47)
  let i_add = (x << 29) + (x >> 35)
  let i_var_r = (x >> n) | (x << (64 - n))
  let i_var_l = (x << n) | (x >> (64 - n))
  if i_or != x.rotate_left(11) || i_xor != x.rotate_right(17) || i_add != x.rotate_left(29) {
    return "BAD_IDIOM64_CONST"
  }
  if i_var_r != rr || i_var_l != rl {
    return "BAD_IDIOM64_VAR"
  }
  "\{rl}:\{rr}:\{lz}:\{tz}:\{co}"
}

fn check_i64(x : Int64, n : Int) -> String {
  let rl = x.rotate_left(n)
  let rr = x.rotate_right(n)
  let lz = x.leading_zeros()
  let tz = x.trailing_zeros()
  let co = x.count_ones()
  "\{rl}:\{rr}:\{lz}:\{tz}:\{co}"
}

pub fn main(w : World) -> Int {
  let shifts : Array[Int] = [0, 1, 7, 31, 32, 33, 63, 64, -1]
  let u32s : Array[UInt] = [0U, 1U, 2147483648U, 4294967295U, 305419896U]
  let i32s : Array[Int] = [0, 1, -1, -2147483648, 305419896]
  let u64s : Array[UInt64] = [0UL, 1UL, 9223372036854775808UL, 18446744073709551615UL, 81985529216486895UL]
  let i64s : Array[Int64] = [0L, 1L, -1L, -9223372036854775808L, 81985529216486895L]

  // Exact spot checks for boundary invariants
  if (0U).leading_zeros() != 32 || (0U).trailing_zeros() != 32 || (0U).count_ones() != 0 {
    io_println(w, "FAIL: u32 zero")
    return 1
  }
  if (0UL).leading_zeros() != 64 || (0UL).trailing_zeros() != 64 || (0UL).count_ones() != 0 {
    io_println(w, "FAIL: u64 zero")
    return 1
  }
  if (-1).leading_zeros() != 0 || (-1).trailing_zeros() != 0 || (-1).count_ones() != 32 {
    io_println(w, "FAIL: i32 -1")
    return 1
  }
  if (-1L).leading_zeros() != 0 || (-1L).trailing_zeros() != 0 || (-1L).count_ones() != 64 {
    io_println(w, "FAIL: i64 -1")
    return 1
  }
  if (1U).rotate_right(1) != 2147483648U || (2147483648U).rotate_left(1) != 1U {
    io_println(w, "FAIL: u32 wrap")
    return 1
  }
  if (1UL).rotate_right(1) != 9223372036854775808UL || (9223372036854775808UL).rotate_left(1) != 1UL {
    io_println(w, "FAIL: u64 wrap")
    return 1
  }

  let mut si = 0
  while si < shifts.length() {
    let n = shifts[si]
    let mut i = 0
    while i < u32s.length() {
      io_println(w, "u32[\{i},\{n}]=" + check_u32(u32s[i], n))
      io_println(w, "i32[\{i},\{n}]=" + check_i32(i32s[i], n))
      io_println(w, "u64[\{i},\{n}]=" + check_u64(u64s[i], n))
      io_println(w, "i64[\{i},\{n}]=" + check_i64(i64s[i], n))
      i = i + 1
    }
    si = si + 1
  }
  io_println(w, "P85_OK")
  0
}
EOF

# 1. Native dev run
"$PIONC" build -o "$TMP_DIR/p85_dev" "$TMP_DIR/main.pion"
"$TMP_DIR/p85_dev" > "$TMP_DIR/out_dev.txt"
grep -q '^P85_OK$' "$TMP_DIR/out_dev.txt" || { echo "FAIL: native dev did not print P85_OK" >&2; exit 1; }
echo "  1. Native dev: OK"

# 2. Native --release run (direct ELF64 / Mach-O object emission)
"$PIONC" build --release -o "$TMP_DIR/p85_rel" "$TMP_DIR/main.pion"
"$TMP_DIR/p85_rel" > "$TMP_DIR/out_rel.txt"
diff -u "$TMP_DIR/out_dev.txt" "$TMP_DIR/out_rel.txt"
echo "  2. Native --release matches dev byte-for-byte: OK"

# 3. Verify hardware `ror` instruction appears in emitted assembly
"$PIONC" build --release --emit-asm "$TMP_DIR/p85_rel.s" -o "$TMP_DIR/p85_rel_asm" "$TMP_DIR/main.pion"
grep -Eq '\bror[lq]?\b' "$TMP_DIR/p85_rel.s" || { echo "FAIL: no ror instruction in emitted asm" >&2; exit 1; }
echo "  3. Emitted assembly contains hardware ror: OK"

# 4. Wasm32 parity (if node is available)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p85.wasm" "$TMP_DIR/main.pion"
  node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85.wasm" > "$TMP_DIR/out_wasm.txt"
  diff -u "$TMP_DIR/out_dev.txt" "$TMP_DIR/out_wasm.txt"
  echo "  4. Wasm32 matches Native byte-for-byte: OK"
else
  echo "  4. Wasm32 skipped (node not installed)"
fi

# 5. Method call arity check negative E2E
cat > "$TMP_DIR/bad_arity.pion" <<'EOF'
struct Pair { a : Int }
fn Pair::sum(self : Pair, x : Int, y : Int) -> Int { self.a + x + y }
pub fn main() -> Int {
  let p = Pair { a: 1 }
  p.sum(2)
}
EOF
BAD_JSON="$("$PIONC" check --json "$TMP_DIR/bad_arity.pion" || true)"
printf '%s' "$BAD_JSON" | grep -q 'E_TYPE_MISMATCH' || {
  echo "FAIL: expected E_TYPE_MISMATCH for missing method arg, got: $BAD_JSON" >&2
  exit 1
}
echo "  5. Method call arity check (E_TYPE_MISMATCH): OK"

echo "PASS: p85_ror_bitops"
