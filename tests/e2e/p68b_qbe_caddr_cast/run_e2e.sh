#!/bin/sh
# P68-B regression: QBE load.c + fold.c must not crash with
# "invalid address operand for 'cast'" when a CAddr (symbol address) is
# stored to an enum payload slot and a dead match branch loads it as Double,
# or when Ocast/O*tof receives a symbol address after copy/GVN propagation.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Pion Farview-exact enum payload (String CAddr vs Double) + inlined match
cat <<'EOF' > "$TMP_DIR/repro.pion"
enum InlineKind {
  TextRun(String)
  Replaced(Double, Double)
}

fn measure_kind(k : InlineKind) -> Double {
  match k {
    InlineKind::TextRun(s) => s.length().to_double()
    InlineKind::Replaced(w, h) => w * h
  }
}

fn check_text() -> Double {
  let k = InlineKind::TextRun("hello")
  measure_kind(k)
}

fn check_replaced(w : Double, h : Double) -> Double {
  let k = InlineKind::Replaced(w, h)
  measure_kind(k)
}

fn main(world : World) -> Unit {
  let a = check_text()
  let b = check_replaced(3.5, 4.0)
  io_println(world, "p68b ok a=" + a.to_int().to_string() + " b=" + b.to_int().to_string())
}
EOF

"$PIONC" build --release -o "$TMP_DIR/repro_bin" "$TMP_DIR/repro.pion"
OUT=$("$TMP_DIR/repro_bin")
echo "p68b native -> $OUT"
if [ "$OUT" != "p68b ok a=5 b=14" ]; then
  echo "FAIL: p68b native output mismatch: $OUT" >&2
  exit 1
fi

"$PIONC" build --release --target arm64_apple --emit-obj "$TMP_DIR/repro_arm64.o" "$TMP_DIR/repro.pion"
"$PIONC" build --release --target amd64_sysv --emit-obj "$TMP_DIR/repro_amd64.o" "$TMP_DIR/repro.pion"
test -s "$TMP_DIR/repro_arm64.o"
test -s "$TMP_DIR/repro_amd64.o"

# 2. Direct QBE SSA regression:
#    - direct storel $sym + dead loadd
#    - copy $sym -> storel + dead loadd
#    - copy $sym -> direct =d cast
cat <<'EOF' > "$TMP_DIR/qbe_caddr_cast.ssa"
data $sym = { b "hello\0" }

export function d $f_store_con_loadd(w %cond) {
@start
  %p =l alloc8 16
  storew 0, %p
  %p8 =l add %p, 8
  storel $sym, %p8
  jnz %cond, @dead_double, @live
@dead_double
  %d =d loadd %p8
  ret %d
@live
  ret d_42.5
}

export function d $f_store_copy_loadd(w %cond) {
@start
  %p =l alloc8 16
  storew 0, %p
  %p8 =l add %p, 8
  %t =l copy $sym
  storel %t, %p8
  jnz %cond, @dead_double, @live
@dead_double
  %d =d loadd %p8
  ret %d
@live
  ret d_19.25
}

export function d $f_direct_cast() {
@start
  %t =l copy $sym
  %d =d cast %t
  ret %d
}
EOF

"$QBE" -t arm64_apple "$TMP_DIR/qbe_caddr_cast.ssa" -o "$TMP_DIR/qbe_arm64.s"
"$QBE" -t amd64_sysv  "$TMP_DIR/qbe_caddr_cast.ssa" -o "$TMP_DIR/qbe_amd64.s"
"$QBE" -t arm64_apple --obj "$TMP_DIR/qbe_caddr_cast.ssa" -o "$TMP_DIR/qbe_arm64.o"
"$QBE" -t amd64_sysv  --obj "$TMP_DIR/qbe_caddr_cast.ssa" -o "$TMP_DIR/qbe_amd64.o"
test -s "$TMP_DIR/qbe_arm64.s"
test -s "$TMP_DIR/qbe_amd64.s"
test -s "$TMP_DIR/qbe_arm64.o"
test -s "$TMP_DIR/qbe_amd64.o"

echo "PASS: p68b_qbe_caddr_cast (native + arm64_apple/amd64_sysv asm & --obj)"
