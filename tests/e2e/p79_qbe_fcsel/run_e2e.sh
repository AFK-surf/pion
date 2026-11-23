#!/bin/sh
# P79: QBE ARM64 fcsel / cross-class csel branchless if-conversion + ops.h xsel*
# class widening regression test (strict IEEE-754 bit-exact, zero implicit FMA).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<'EOF' > "$TMP_DIR/p79_fcsel.pion"
// 1. Float & Double min / max / abs / clamp (branchless fcsel on ARM64).
pub fn min_d(a : Double, b : Double) -> Double {
  if a < b { a } else { b }
}

pub fn max_d(a : Double, b : Double) -> Double {
  if a > b { a } else { b }
}

pub fn abs_d(x : Double) -> Double {
  if x < 0.0 { 0.0 - x } else { x }
}

pub fn clamp_d(x : Double, lo : Double, hi : Double) -> Double {
  let y = if x < lo { lo } else { x }
  if y > hi { hi } else { y }
}

pub fn min_f(a : Float, b : Float) -> Float {
  if a < b { a } else { b }
}

pub fn max_f(a : Float, b : Float) -> Float {
  if a > b { a } else { b }
}

pub fn abs_f(x : Float) -> Float {
  let z : Float = 0.0
  if x < z { z - x } else { x }
}

pub fn clamp_f(x : Float, lo : Float, hi : Float) -> Float {
  let y = if x < lo { lo } else { x }
  if y > hi { hi } else { y }
}

// 2. Viterbi-isomorphic inner loops: float compare selecting (Double, Int64) and (Float, Int).
pub fn viterbi_d_i64(scores : Array[Double], trans : Array[Double], n : Int) -> (Double, Int64) {
  let mut best_score = -1.0e30
  let mut best_prev : Int64 = -1L
  let mut p = 0
  while p < n {
    let cand = scores[p] + trans[p]
    if cand > best_score {
      best_score = cand
      best_prev = p as Int64
    }
    p = p + 1
  }
  (best_score, best_prev)
}

pub fn viterbi_f_i32(scores : Array[Float], trans : Array[Float], n : Int) -> (Float, Int) {
  let mut best_score : Float = -1.0e30
  let mut best_prev : Int = -1
  let mut p = 0
  while p < n {
    let cand = scores[p] + trans[p]
    if cand > best_score {
      best_score = cand
      best_prev = p
    }
    p = p + 1
  }
  (best_score, best_prev)
}

// 3. Branchless select vs side-effecting (non-if-converted) reference for NaN & all 6 comparisons.
fn side_effect(sink : Array[Int], v : Int) -> Unit {
  sink[0] = sink[0] + v
}

fn sel_d_lt(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a < b { t } else { f }
}
fn sel_d_le(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a <= b { t } else { f }
}
fn sel_d_gt(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a > b { t } else { f }
}
fn sel_d_ge(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a >= b { t } else { f }
}
fn sel_d_eq(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a == b { t } else { f }
}
fn sel_d_ne(a : Double, b : Double, t : Double, f : Double) -> Double {
  if a != b { t } else { f }
}

fn sel_i_lt(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a < b { t } else { f }
}
fn sel_i_le(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a <= b { t } else { f }
}
fn sel_i_gt(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a > b { t } else { f }
}
fn sel_i_ge(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a >= b { t } else { f }
}
fn sel_i_eq(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a == b { t } else { f }
}
fn sel_i_ne(a : Double, b : Double, t : Int, f : Int) -> Int {
  if a != b { t } else { f }
}

fn sel_f_lt(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a < b { t } else { f }
}
fn sel_f_le(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a <= b { t } else { f }
}
fn sel_f_gt(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a > b { t } else { f }
}
fn sel_f_ge(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a >= b { t } else { f }
}
fn sel_f_eq(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a == b { t } else { f }
}
fn sel_f_ne(a : Float, b : Float, t : Float, f : Float) -> Float {
  if a != b { t } else { f }
}

fn ref_i_cmp(op : Int, a : Double, b : Double, t : Int, f : Int, sink : Array[Int]) -> Int {
  if op == 0 {
    if a < b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 1 {
    if a <= b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 2 {
    if a > b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 3 {
    if a >= b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 4 {
    if a == b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else {
    if a != b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  }
}

fn ref_d_cmp(op : Int, a : Double, b : Double, t : Double, f : Double, sink : Array[Int]) -> Double {
  if op == 0 {
    if a < b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 1 {
    if a <= b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 2 {
    if a > b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 3 {
    if a >= b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else if op == 4 {
    if a == b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  } else {
    if a != b { side_effect(sink, 1); t } else { side_effect(sink, 2); f }
  }
}

fn check_pair(a : Double, b : Double, sink : Array[Int]) -> Unit {
  let td = 11.5
  let fd = -22.25
  let ti = 101
  let fi = 202

  if sel_d_lt(a, b, td, fd) != ref_d_cmp(0, a, b, td, fd, sink) { panic("d_lt mismatch") }
  if sel_d_le(a, b, td, fd) != ref_d_cmp(1, a, b, td, fd, sink) { panic("d_le mismatch") }
  if sel_d_gt(a, b, td, fd) != ref_d_cmp(2, a, b, td, fd, sink) { panic("d_gt mismatch") }
  if sel_d_ge(a, b, td, fd) != ref_d_cmp(3, a, b, td, fd, sink) { panic("d_ge mismatch") }
  if sel_d_eq(a, b, td, fd) != ref_d_cmp(4, a, b, td, fd, sink) { panic("d_eq mismatch") }
  if sel_d_ne(a, b, td, fd) != ref_d_cmp(5, a, b, td, fd, sink) { panic("d_ne mismatch") }

  if sel_i_lt(a, b, ti, fi) != ref_i_cmp(0, a, b, ti, fi, sink) { panic("i_lt mismatch") }
  if sel_i_le(a, b, ti, fi) != ref_i_cmp(1, a, b, ti, fi, sink) { panic("i_le mismatch") }
  if sel_i_gt(a, b, ti, fi) != ref_i_cmp(2, a, b, ti, fi, sink) { panic("i_gt mismatch") }
  if sel_i_ge(a, b, ti, fi) != ref_i_cmp(3, a, b, ti, fi, sink) { panic("i_ge mismatch") }
  if sel_i_eq(a, b, ti, fi) != ref_i_cmp(4, a, b, ti, fi, sink) { panic("i_eq mismatch") }
  if sel_i_ne(a, b, ti, fi) != ref_i_cmp(5, a, b, ti, fi, sink) { panic("i_ne mismatch") }

  let af = a as Float
  let bf = b as Float
  let tf : Float = 11.5
  let ff : Float = -22.25
  if (sel_f_lt(af, bf, tf, ff) as Double) != ref_d_cmp(0, a, b, td, fd, sink) { panic("f_lt mismatch") }
  if (sel_f_le(af, bf, tf, ff) as Double) != ref_d_cmp(1, a, b, td, fd, sink) { panic("f_le mismatch") }
  if (sel_f_gt(af, bf, tf, ff) as Double) != ref_d_cmp(2, a, b, td, fd, sink) { panic("f_gt mismatch") }
  if (sel_f_ge(af, bf, tf, ff) as Double) != ref_d_cmp(3, a, b, td, fd, sink) { panic("f_ge mismatch") }
  if (sel_f_eq(af, bf, tf, ff) as Double) != ref_d_cmp(4, a, b, td, fd, sink) { panic("f_eq mismatch") }
  if (sel_f_ne(af, bf, tf, ff) as Double) != ref_d_cmp(5, a, b, td, fd, sink) { panic("f_ne mismatch") }
}

fn main(world : World) -> Unit {
  // min / max / abs / clamp
  if min_d(3.5, -2.0) != -2.0 { panic("min_d") }
  if max_d(3.5, -2.0) != 3.5 { panic("max_d") }
  if abs_d(-7.25) != 7.25 || abs_d(4.5) != 4.5 { panic("abs_d") }
  if clamp_d(-5.0, 0.0, 10.0) != 0.0 || clamp_d(15.0, 0.0, 10.0) != 10.0 || clamp_d(4.5, 0.0, 10.0) != 4.5 {
    panic("clamp_d")
  }
  if (min_f(3.5 as Float, -2.0 as Float) as Double) != -2.0 { panic("min_f") }
  if (max_f(3.5 as Float, -2.0 as Float) as Double) != 3.5 { panic("max_f") }
  if (abs_f(-7.25 as Float) as Double) != 7.25 || (abs_f(4.5 as Float) as Double) != 4.5 { panic("abs_f") }
  if (clamp_f(-5.0 as Float, 0.0 as Float, 10.0 as Float) as Double) != 0.0
    || (clamp_f(15.0 as Float, 0.0 as Float, 10.0 as Float) as Double) != 10.0
    || (clamp_f(4.5 as Float, 0.0 as Float, 10.0 as Float) as Double) != 4.5 {
    panic("clamp_f")
  }

  // Viterbi inner loops (with NaN entry that must not overwrite best_score)
  let dz = 0.0
  let nan = dz / dz
  let sc_d = [-5.0, 2.5, nan, 7.25, 3.0]
  let tr_d = [1.0, 0.5, 0.0, 0.75, 10.0]
  let (vd, pd) = viterbi_d_i64(sc_d, tr_d, 5)
  if vd != 13.0 || pd != 4L { panic("viterbi_d_i64") }

  let sc_f : Array[Float] = [-5.0 as Float, 2.5 as Float, nan as Float, 7.25 as Float, 3.0 as Float]
  let tr_f : Array[Float] = [1.0 as Float, 0.5 as Float, 0.0 as Float, 0.75 as Float, 10.0 as Float]
  let (vf, pf) = viterbi_f_i32(sc_f, tr_f, 5)
  if (vf as Double) != 13.0 || pf != 4 { panic("viterbi_f_i32") }

  // Full NaN & finite boundary comparison matrix
  let sink = [0]
  let vals = [-2.5, 0.0, 2.5, nan]
  let mut i = 0
  while i < 4 {
    let mut j = 0
    while j < 4 {
      check_pair(vals[i], vals[j], sink)
      j = j + 1
    }
    i = i + 1
  }

  io_println(world, "p79_qbe_fcsel ok")
}
EOF

BIN="$TMP_DIR/p79_bin"
"$PIONC" build --release -o "$BIN" "$TMP_DIR/p79_fcsel.pion"
OUT="$("$BIN")"
if [ "$OUT" != "p79_qbe_fcsel ok" ]; then
  echo "FAIL: p79 runtime output mismatch: '$OUT'" >&2
  exit 1
fi

if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
  ASM="$TMP_DIR/p79.s"
  "$PIONC" build --release --emit-asm "$ASM" -o "$TMP_DIR/p79_bin_asm" "$TMP_DIR/p79_fcsel.pion"
  OUT_ASM="$("$TMP_DIR/p79_bin_asm")"
  if [ "$OUT_ASM" != "p79_qbe_fcsel ok" ]; then
    echo "FAIL: p79 --emit-asm binary output mismatch: '$OUT_ASM'" >&2
    exit 1
  fi

  OBJ="$TMP_DIR/p79.o"
  "$PIONC" build --release --emit-obj "$OBJ" "$TMP_DIR/p79_fcsel.pion"
  DIS="$TMP_DIR/p79.dis"
  otool -tV "$OBJ" > "$DIS"
  DIS_BIN="$TMP_DIR/p79_bin.dis"
  otool -tV "$BIN" > "$DIS_BIN"
  for INSN in fcsel csel; do
    if ! grep -Eq "[[:space:]]${INSN}[[:space:]]" "$DIS_BIN"; then
      echo "FAIL: p79 macOS ARM64 macho binary missing '${INSN}' in otool -tV" >&2
      exit 1
    fi
    if ! grep -Eq "[[:space:]]${INSN}[[:space:]]" "$DIS"; then
      echo "FAIL: p79 macOS ARM64 macho .o missing '${INSN}' in otool -tV" >&2
      exit 1
    fi
    if ! grep -Eq "[[:space:]]${INSN}[[:space:]]" "$ASM"; then
      echo "FAIL: p79 macOS ARM64 asm missing '${INSN}'" >&2
      exit 1
    fi
  done

  # Verify Viterbi inner loops and min/max/abs/clamp use branchless fcsel (+ csel for Viterbi).
  python3 - "$DIS" <<'PYEOF'
import re, sys

funcs = {}
cur = None
for ln in open(sys.argv[1]):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_.$]*):\s*$", ln)
    if m:
        cur = m.group(1)
        funcs[cur] = []
    elif cur is not None:
        funcs[cur].append(ln.rstrip("\n"))

def find_fn(suffix):
    for name, lines in funcs.items():
        if name.endswith(suffix):
            return name, lines
    sys.exit(f"FAIL: symbol ending with {suffix} not found in otool -tV (.o)")

for fn in ("viterbi_d_i64", "viterbi_f_i32"):
    name, lines = find_fn(fn)
    body = "\n".join(lines)
    if "fcsel" not in body or "csel" not in body:
        sys.exit(f"FAIL: {name} missing fcsel/csel:\n{body}")
    for idx, ln in enumerate(lines):
        if "\tfcmpe\t" in ln:
            nxt = lines[idx + 1] if idx + 1 < len(lines) else ""
            if re.search(r"\tb\.[a-z]+\b", nxt):
                sys.exit(f"FAIL: {name} branches right after fcmpe:\n{ln}\n{nxt}")

for fn in ("min_d", "max_d", "abs_d", "clamp_d", "min_f", "max_f", "abs_f", "clamp_f"):
    name, lines = find_fn(fn)
    body = "\n".join(lines)
    if "fcsel" not in body:
        sys.exit(f"FAIL: {name} missing fcsel:\n{body}")
    bad = [ln for ln in lines if re.search(r"\tb\.[a-z]+\b", ln)]
    if bad:
        sys.exit(f"FAIL: {name} still has conditional branch:\n" + "\n".join(bad))
PYEOF
  echo "PASS: p79_qbe_fcsel (macOS ARM64: fcsel/csel verified in Mach-O & asm, branchless Viterbi & min/max/abs/clamp, NaN matrix)"
else
  if [ "$(uname -m)" = x86_64 ]; then
    ASM="$TMP_DIR/p79_x64.s"
    "$PIONC" build --release --emit-asm "$ASM" -o "$TMP_DIR/p79_bin_asm" "$TMP_DIR/p79_fcsel.pion"
    OUT_ASM="$("$TMP_DIR/p79_bin_asm")"
    if [ "$OUT_ASM" != "p79_qbe_fcsel ok" ]; then
      echo "FAIL: p79 x86_64 --emit-asm binary output mismatch: '$OUT_ASM'" >&2
      exit 1
    fi
    if ! grep -Eq "[[:space:]]cmov" "$ASM"; then
      echo "FAIL: p79 x86_64 asm missing cmov for float-cmp int-select" >&2
      exit 1
    fi
  fi
  echo "PASS: p79_qbe_fcsel ($(uname -m): Viterbi/min/max/abs/clamp/float-cmp-int-select cmov & NaN matrix)"
fi
