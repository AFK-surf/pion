#!/bin/sh
# P103: Wave L0 — Nested tuple patterns, Array::is_empty/truncate,
# Double::is_nan/compare/reinterpret_as_int64 + Double/Float Hash -0.0 normalization,
# Int/Int64/UInt/UInt64::lnot (Native dev + --release + ASan/LSan + Wasm32 Node + Web parity).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
CC_BIN="${CC:-cc}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"

echo "=== P103 E2E: Wave L0 (Nested Tuple Patterns + Stdlib + Double Hash -0.0 + lnot) ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
struct RcRec {
  tag : Int
  label : String
}

struct DblKey {
  x : Double
  id : Int
}

fn mk_str(prefix : String, n : Int) -> String {
  prefix + "_" + n.to_string()
}

fn pipe_wrap(n : Int) -> Option[Int] {
  if n > 0 { Some(n * 2) } else { None }
}

fn pipe_step(n : Int) -> Option[Int] {
  if n > 0 { Some(n - 1) } else { None }
}

fn test_nested_tuple_patterns() -> String {
  let sb = StringBuilder()

  // 1. Some((String, Array[String])) with RC payloads
  let mut rc_sum = 0
  let mut iter = 0
  while iter < 120 {
    let arr : Array[String] = [mk_str("a", iter), mk_str("b", iter)]
    let opt : Option[(String, Array[String])] = if iter % 3 == 0 {
      None
    } else {
      Some((mk_str("k", iter), arr))
    }
    let v = match opt {
      Some((s, xs)) => s.length() + xs.length() + xs[0].length()
      None => 1
    }
    rc_sum = rc_sum + v
    iter = iter + 1
  }
  sb.write_string("rc=" + rc_sum.to_string())

  // 2. Multi-level nesting: Ok((a, (b, c))), (Some((a, b)), None), Ok((x, Some((y, z))))
  let r1 : Result[(Int, (String, Int)), String] = Ok((10, (mk_str("mid", 7), 20)))
  let v1 = match r1 {
    Ok((a, (b, c))) => a + b.length() + c
    Err(e) => -e.length()
  }
  let p1 : (Option[(Int, String)], Option[Int]) = (Some((3, mk_str("hi", 1))), None)
  let v2 = match p1 {
    (Some((a, b)), None) => a + b.length()
    _ => -1
  }
  let r2 : Result[(Int, Option[(String, Int)]), String] = Ok((5, Some((mk_str("deep", 9), 11))))
  let v3 = match r2 {
    Ok((x, Some((y, z)))) => x + y.length() + z
    _ => -1
  }
  let r3 : Result[(Int, Option[(String, Int)]), String] = Ok((5, None))
  let v4 = match r3 {
    Ok((x, Some((y, z)))) => x + y.length() + z
    Ok((x, None)) => x * 10
    Err(_) => -1
  }
  sb.write_string(" nest=" + v1.to_string() + "," + v2.to_string() + "," + v3.to_string() + "," + v4.to_string())

  // 3. Literal + wildcard + guard combinations (including guard failure releasing RC bindings)
  let mut lit_acc : Int64 = 0L
  let cases : Array[Option[(Int, String)]] = [
    Some((1, mk_str("one", 1))),
    Some((5, mk_str("pos", 2))),
    Some((-3, mk_str("neg", 3))),
    None,
  ]
  let mut ci = 0
  while ci < cases.length() {
    let cur = cases[ci]
    let x = match cur {
      Some((1, b)) => 100 + b.length()
      Some((a, s)) if a > 0 && s.length() > 100 => 999
      Some((a, _)) if a > 0 => 200 + a
      Some((_, b)) => 300 + b.length()
      None => 400
    }
    lit_acc = lit_acc * 1000L + x.to_int64()
    ci = ci + 1
  }
  sb.write_string(" lit=" + lit_acc.to_string())

  // 4. if let Some((a, b)) = expr && cond { ... } else if let ... && ... { ... } else { ... }
  let o_if : Option[(String, Int)] = Some((mk_str("iflet", 4), 42))
  let if1 = if let Some((s, n)) = o_if && n > 10 { s.length() + n } else { -1 }
  let o_if2 : Option[(String, Int)] = Some((mk_str("neg", 2), -5))
  let if2 = if let Some((s, n)) = o_if2 && n > 0 {
    s.length() + n
  } else if let Some((s, n)) = o_if2 && n < 0 {
    s.length() - n
  } else {
    -1
  }
  let o_if_none : Option[(String, Int)] = None
  let if3 = if let Some((s, n)) = o_if_none && n > 0 { s.length() + n } else { 77 }

  // 5. while let Some((a, b)) = ... && cond
  let queue : Array[(Int, String)] = [
    (-1, mk_str("stop", 0)),
    (1, mk_str("q", 1)),
    (2, mk_str("q", 2)),
    (3, mk_str("q", 3)),
  ]
  let mut wl_sum = 0
  while let Some((n, s)) = queue.pop() && n > 0 {
    wl_sum = wl_sum + n * 10 + s.length()
  }

  // 6. if let / while let with unparenthesized & parenthesized `|>` pipe
  let p_a = if let Some(x) = 5 |> pipe_wrap { x } else { -1 }
  let p_b = if let Some(x) = 5 |> pipe_wrap && x > 5 { x } else { -1 }
  let p_c = if let Some(x) = (5 |> pipe_wrap) && x > 100 { x } else { 3 }
  let mut p_cur = 4
  let mut p_acc = 0
  while let Some(x) = p_cur |> pipe_step && x > 0 {
    p_acc = p_acc + x
    p_cur = x
  }
  sb.write_string(" ifwl=" + if1.to_string() + "," + if2.to_string() + "," + if3.to_string() + "," + wl_sum.to_string() + " pipe=" + p_a.to_string() + "," + p_b.to_string() + "," + p_c.to_string() + "," + p_acc.to_string())
  sb.to_string()
}

fn test_array_is_empty_truncate() -> String {
  let sb = StringBuilder()

  // Array[Int] (4B compact)
  let ai : Array[Int] = []
  let e0 = ai.is_empty()
  ai.push(10); ai.push(20); ai.push(30); ai.push(40)
  let e1 = ai.is_empty()
  ai.truncate(10) // no-op
  let l1 = ai.length()
  ai.truncate(2)
  let l2 = ai.length()
  let s2 = ai[0] + ai[1]
  ai.truncate(-5) // clamp to 0
  let e2 = ai.is_empty()
  ai.push(99)
  let s3 = ai[0]
  sb.write_string("i=" + e0.to_string() + "," + e1.to_string() + "," + l1.to_string() + "," + l2.to_string() + "," + s2.to_string() + "," + e2.to_string() + "," + s3.to_string())

  // Array[Byte], Array[Int8], Array[Float], Array[Bool]
  let ab : Array[Byte] = [(1).to_byte(), (2).to_byte(), (3).to_byte()]
  ab.truncate(1)
  let ai8 : Array[Int8] = [(-5).to_int8(), (7).to_int8(), (9).to_int8()]
  ai8.truncate(2)
  let af : Array[Float] = [Float::from_int(1), Float::from_int(2), Float::from_int(3)]
  af.truncate(2)
  let abool : Array[Bool] = [true, false, true, false]
  abool.truncate(1)
  sb.write_string(" c=" + ab.length().to_string() + "," + ab[0].to_int().to_string() + "," + ai8.length().to_string() + "," + ai8[1].to_int().to_string() + "," + af.length().to_string() + "," + af[1].to_int().to_string() + "," + abool.length().to_string() + "," + abool[0].to_string())

  // Array[String], Array[Array[Int]], Array[RcRec] (flat RC struct) — RC leak stress
  let mut k = 0
  let mut rc_check = 0
  while k < 60 {
    let astr : Array[String] = [mk_str("s0", k), mk_str("s1", k), mk_str("s2", k), mk_str("s3", k)]
    astr.truncate(2)
    rc_check = rc_check + astr.length() + astr[1].length()
    astr.truncate(0)

    let aarr : Array[Array[Int]] = [[1, 2], [3, 4, 5], [6]]
    aarr.truncate(1)
    rc_check = rc_check + aarr[0].length()

    let arec : Array[RcRec] = [
      RcRec::{ tag: 1, label: mk_str("r0", k) },
      RcRec::{ tag: 2, label: mk_str("r1", k) },
      RcRec::{ tag: 3, label: mk_str("r2", k) },
    ]
    arec.truncate(1)
    rc_check = rc_check + arec[0].tag + arec[0].label.length()
    arec.truncate(-1)
    k = k + 1
  }
  sb.write_string(" rc=" + rc_check.to_string())
  sb.to_string()
}

fn test_double_methods_and_hash() -> String {
  let sb = StringBuilder()
  let zero = 0.0
  let neg_zero = -0.0
  let pos_inf = 1.0 / zero
  let neg_inf = -1.0 / zero
  let nan = zero / zero

  // is_nan
  sb.write_string("nan=" + nan.is_nan().to_string() + "," + zero.is_nan().to_string() + "," + neg_zero.is_nan().to_string() + "," + pos_inf.is_nan().to_string() + "," + neg_inf.is_nan().to_string() + "," + (1.5).is_nan().to_string())

  // reinterpret_as_int64 vs to_bits
  let b_nz = neg_zero.reinterpret_as_int64()
  let b_z = zero.reinterpret_as_int64()
  let b_one = (1.0).reinterpret_as_int64()
  let b_eq = b_nz == neg_zero.to_bits() && b_one == (1.0).to_bits()
  sb.write_string(" bits=" + b_nz.to_string() + "," + b_z.to_string() + "," + b_one.to_string() + "," + b_eq.to_string())

  // compare: all 7x7 = 49 combinations
  let vals : Array[Double] = [neg_inf, -1.0, neg_zero, zero, 1.0, pos_inf, nan]
  sb.write_string(" cmp=")
  let mut i = 0
  while i < vals.length() {
    let mut j = 0
    while j < vals.length() {
      let c = vals[i].compare(vals[j])
      if c < 0 {
        sb.write_string("-")
      } else if c > 0 {
        sb.write_string("+")
      } else {
        sb.write_string("0")
      }
      j = j + 1
    }
    i = i + 1
  }

  // Double Hash -0.0 normalization: Map[Double, Int]
  let dm : Map[Double, Int] = Map([])
  dm.set(neg_zero, 11)
  let h1 = dm.get(zero).unwrap_or(-1)
  dm.set(zero, 22)
  let h2 = dm.get(neg_zero).unwrap_or(-1)
  let dlen1 = dm.length()
  dm.set(1.5, 33)
  dm.remove(neg_zero)
  let h3 = dm.contains(zero)

  // Reverse direction: insert +0.0, lookup -0.0
  let dm2 : Map[Double, Int] = Map([])
  dm2.set(zero, 44)
  let h4 = dm2.get(neg_zero).unwrap_or(-1)

  // Float Hash -0.0f normalization: Map[Float, Int]
  let fz = Float::from_double(0.0)
  let fnz = Float::from_double(-0.0)
  let fm : Map[Float, Int] = Map([])
  fm.set(fnz, 55)
  let fh1 = fm.get(fz).unwrap_or(-1)
  fm.set(fz, 66)
  let fh2 = fm.get(fnz).unwrap_or(-1)
  let flen = fm.length()

  // Composite struct and tuple keys containing Double
  let sm : Map[DblKey, Int] = Map([])
  sm.set(DblKey::{ x: neg_zero, id: 7 }, 77)
  let sh1 = sm.get(DblKey::{ x: zero, id: 7 }).unwrap_or(-1)
  sm.set(DblKey::{ x: zero, id: 7 }, 88)
  let slen = sm.length()

  let tm : Map[(Double, Int), Int] = Map([])
  tm.set((neg_zero, 9), 99)
  let th1 = tm.get((zero, 9)).unwrap_or(-1)
  let tlen = tm.length()

  sb.write_string(" map=" + h1.to_string() + "," + h2.to_string() + "," + dlen1.to_string() + "," + h3.to_string() + "," + h4.to_string() + "," + fh1.to_string() + "," + fh2.to_string() + "," + flen.to_string() + "," + sh1.to_string() + "," + slen.to_string() + "," + th1.to_string() + "," + tlen.to_string())
  sb.to_string()
}

fn test_lnot() -> String {
  let i0 = (0).lnot()
  let im1 = (-1).lnot()
  let ix = (0x12345678).lnot()
  let l0 = (0L).lnot()
  let lm1 = (-1L).lnot()
  let lx = (0x0123456789abcdefL).lnot()
  let u0 = (0U).lnot()
  let um = (4294967295U).lnot()
  let ux = (0x12345678U).lnot()
  let ul0 = (0UL).lnot()
  let ulm = (18446744073709551615UL).lnot()
  "lnot=" + i0.to_string() + "," + im1.to_string() + "," + ix.to_string() +
    "," + l0.to_string() + "," + lm1.to_string() + "," + lx.to_string() +
    "," + u0.to_string() + "," + um.to_string() + "," + ux.to_string() +
    "," + ul0.to_string() + "," + ulm.to_string()
}

pub fn main(world : World) -> Int {
  io_println(world, test_nested_tuple_patterns())
  io_println(world, test_array_is_empty_truncate())
  io_println(world, test_double_methods_and_hash())
  io_println(world, test_lnot())
  0
}
EOF

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p103_rel" "$TMP_DIR/main.pion"
OUT_REL=$("$TMP_DIR/p103_rel")
echo "p103 native release:"
printf '%s\n' "$OUT_REL"

# Exact independent expected-value assertions (49-char Double::compare matrix + all lines)
WANT_CMP="0------+0-----++00---++00---++++0--+++++0-++++++0"
printf '%s\n' "$OUT_REL" | grep -q "^rc=856 nest=35,7,22,50 lit=105205305400 ifwl=49,10,77,69 pipe=10,10,3,6$"
printf '%s\n' "$OUT_REL" | grep -q "^i=true,false,4,2,30,true,99 c=1,1,2,7,2,2,1,true rc=880$"
printf '%s\n' "$OUT_REL" | grep -q "^nan=true,false,false,false,false,false bits=-9223372036854775808,0,4607182418800017408,true cmp=${WANT_CMP} map=11,22,1,false,44,55,66,1,77,1,99,1$"
printf '%s\n' "$OUT_REL" | grep -q "^lnot=-1,0,-305419897,-1,0,-81985529216486896,4294967295,0,3989547399,18446744073709551615,0$"

"$PIONC" build -o "$TMP_DIR/p103_dev" "$TMP_DIR/main.pion"
OUT_DEV=$("$TMP_DIR/p103_dev")
test "$OUT_DEV" = "$OUT_REL"
echo "p103 native dev == release -> OK"

# 2. Native ASan/LSan (0 leaks, 0 UAF)
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/p103_main.o" "$TMP_DIR/main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p103_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p103_asan"
  OUT_ASAN=$("$TMP_DIR/p103_asan")
  test "$OUT_ASAN" = "$OUT_REL"
  echo "p103 ASan/LSan (0 leaks, 0 UAF) == release -> OK"
else
  if [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
    echo "FAIL: PION_REQUIRE_SANITIZERS=1 but ASan runtime unavailable" >&2
    exit 1
  fi
  echo "NOTE: cc -fsanitize=address unavailable; skipping p103 ASan check"
fi

# 3. Wasm32 Node + Web (release + dev)
if command -v node >/dev/null 2>&1; then
  for mode in release dev; do
    if [ "$mode" = "release" ]; then
      "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p103_${mode}.wasm" "$TMP_DIR/main.pion"
    else
      "$PIONC" build --target wasm32 -o "$TMP_DIR/p103_${mode}.wasm" "$TMP_DIR/main.pion"
    fi
    OUT_NODE=$(node "$WASM_RT" "$TMP_DIR/p103_${mode}.wasm")
    test "$OUT_NODE" = "$OUT_REL"
    echo "p103 wasm32 node ($mode) == native -> OK"

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
    ' "$TMP_DIR/p103_${mode}.wasm" "$WASM_RT_WEB")"
    test "$OUT_WEB" = "$OUT_REL"
    echo "p103 wasm32 web ($mode) == native -> OK"
  done
fi

# 4. Astra #3 regression: user trait method `Int.compare(b)` mutating aliased array via `truncate(0)`
#    must NOT be misclassified as a pure builtin (must panic OOB instead of reusing stale length).
cat > "$TMP_DIR/bad_cmp.pion" <<'EOF'
trait BadCmp {
  fn compare(self : Self, b : Array[Int]) -> Int
}
impl BadCmp for Int {
  fn compare(self : Int, b : Array[Int]) -> Int {
    b.truncate(0)
    self
  }
}
fn run_aliased(a : Array[Int], b : Array[Int]) -> Int {
  let mut i = 0
  let mut s = 0
  while i < a.length() {
    let _ = i.compare(b)
    s = s + a[i]
    i = i + 1
  }
  s
}
pub fn main(world : World) -> Int {
  let a : Array[Int] = [10, 20, 30]
  let r = run_aliased(a, a)
  io_println(world, r.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/bad_cmp_rel" "$TMP_DIR/bad_cmp.pion"
set +e
BAD_OUT=$("$TMP_DIR/bad_cmp_rel" 2>&1)
BAD_RC=$?
set -e
if [ "$BAD_RC" -eq 0 ] || ! printf '%s' "$BAD_OUT" | grep -Fq "pion panic: index 0 out of bounds (len 0)"; then
  echo "FAIL: p103 Astra #3 Int.compare(b) OOB regression did not trap with exact OOB diag (rc=$BAD_RC out='$BAD_OUT')" >&2
  exit 1
fi
echo "p103 Astra #3 Int.compare(b) aliased truncate OOB trap (native rc=$BAD_RC) -> OK"
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/bad_cmp.wasm" "$TMP_DIR/bad_cmp.pion"
  set +e
  BAD_WOUT=$(node "$WASM_RT" "$TMP_DIR/bad_cmp.wasm" 2>&1)
  BAD_WRC=$?
  set -e
  if [ "$BAD_WRC" -eq 0 ] || ! printf '%s' "$BAD_WOUT" | grep -Fq "pion panic: index out of bounds: idx=0, len=0"; then
    echo "FAIL: p103 Astra #3 wasm32 OOB regression did not trap with exact OOB diag (rc=$BAD_WRC out='$BAD_WOUT')" >&2
    exit 1
  fi
  echo "p103 Astra #3 Int.compare(b) aliased truncate OOB trap (wasm32 rc=$BAD_WRC) -> OK"
fi

# 5. Astra #1 R3 regression: user trait method `Byte.to_uint()` mutating package-level array via `truncate(0)`
#    must NOT be misclassified as a pure builtin (TByte only has built-in `to_int` and `to_int8`).
cat > "$TMP_DIR/bad_byte.pion" <<'EOF'
let G_ARR : Array[Int] = [10, 20, 30]
trait MyByteTrait {
  fn to_uint(self : Self) -> UInt
}
impl MyByteTrait for Byte {
  fn to_uint(self : Byte) -> UInt {
    G_ARR.truncate(0)
    self.to_int().to_uint()
  }
}
fn run_byte_loop(a : Array[Int], b : Byte) -> Int {
  let mut i = 0
  let mut s = 0
  while i < a.length() {
    let _ = b.to_uint()
    s = s + a[i]
    i = i + 1
  }
  s
}
pub fn main(world : World) -> Int {
  let r = run_byte_loop(G_ARR, (1).to_byte())
  io_println(world, r.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/bad_byte_rel" "$TMP_DIR/bad_byte.pion"
set +e
BB_OUT=$("$TMP_DIR/bad_byte_rel" 2>&1)
BB_RC=$?
set -e
if [ "$BB_RC" -eq 0 ] || ! printf '%s' "$BB_OUT" | grep -Fq "pion panic: index 0 out of bounds (len 0)"; then
  echo "FAIL: p103 Astra #1 Byte.to_uint() OOB regression did not trap with exact OOB diag (rc=$BB_RC out='$BB_OUT')" >&2
  exit 1
fi
echo "p103 Astra #1 Byte.to_uint() truncate OOB trap (native rc=$BB_RC) -> OK"
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/bad_byte.wasm" "$TMP_DIR/bad_byte.pion"
  set +e
  BB_WOUT=$(node "$WASM_RT" "$TMP_DIR/bad_byte.wasm" 2>&1)
  BB_WRC=$?
  set -e
  if [ "$BB_WRC" -eq 0 ] || ! printf '%s' "$BB_WOUT" | grep -Fq "pion panic: index out of bounds: idx=0, len=0"; then
    echo "FAIL: p103 Astra #1 Byte.to_uint() wasm32 OOB regression did not trap with exact OOB diag (rc=$BB_WRC out='$BB_WOUT')" >&2
    exit 1
  fi
  echo "p103 Astra #1 Byte.to_uint() truncate OOB trap (wasm32 rc=$BB_WRC) -> OK"
fi

# 6. Astra #1 R4 regression: generic trait dispatch `x.to_int()` in `match xs[0]` guard
#    instantiated with `Byte` whose impl truncates `G_XS` must NOT borrow `xs[0]` (0 UAF under ASan/Native/Wasm32).
cat > "$TMP_DIR/bad_guard.pion" <<'EOF'
let G_XS : Array[String] = []
trait BadToInt {
  fn to_int(self : Self) -> Int
}
impl BadToInt for Byte {
  fn to_int(self : Byte) -> Int {
    G_XS.truncate(0)
    self.to_int()
  }
}
fn match_guard_gen[T : BadToInt](x : T, xs : Array[String]) -> Int {
  match xs[0] {
    s if x.to_int() >= 0 => s.length()
    _ => -1
  }
}
pub fn main(world : World) -> Int {
  let sb = StringBuilder()
  sb.write_string("heap_string_for_uaf_check_")
  sb.write_string("0123456789")
  G_XS.push(sb.to_string())
  let n = match_guard_gen((1).to_byte(), G_XS)
  io_println(world, "guard_len=" + n.to_string() + ",after=" + G_XS.length().to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/bad_guard_rel" "$TMP_DIR/bad_guard.pion"
BG_OUT=$("$TMP_DIR/bad_guard_rel")
if [ "$BG_OUT" != "guard_len=36,after=0" ]; then
  echo "FAIL: p103 Astra #1 R4 generic trait guard native output mismatch: '$BG_OUT'" >&2
  exit 1
fi
echo "p103 Astra #1 R4 generic trait guard (native rel) -> $BG_OUT"
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/bad_guard.wasm" "$TMP_DIR/bad_guard.pion"
  BG_WOUT=$(node "$WASM_RT" "$TMP_DIR/bad_guard.wasm")
  if [ "$BG_WOUT" != "guard_len=36,after=0" ]; then
    echo "FAIL: p103 Astra #1 R4 generic trait guard wasm32 output mismatch: '$BG_WOUT'" >&2
    exit 1
  fi
  echo "p103 Astra #1 R4 generic trait guard (wasm32) -> $BG_WOUT"
fi

echo "PASS: p103_wave_l0_stdlib_tuple (Native dev+rel + ASan/LSan + Wasm32 Node+Web + Astra #1/#3 OOB + R4 Guard)"
