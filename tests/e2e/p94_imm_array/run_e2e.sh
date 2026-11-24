#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# =====================================================================
# Part 1: Core ImmArray semantics (Native + Wasm32 parity)
# =====================================================================
cat > "$TMP_DIR/j3_core.pion" <<'EOF'
#derive(Eq)
val struct FlatPod {
  x : Int
  y : Int
}

#derive(Eq)
val struct MixedRc {
  label : String
  n : Int
}

#derive(Eq)
struct Box[T] {
  a : T
}

#derive(Eq)
struct Box_i {
  a : Int
  b : Int
}

struct Boxed[T] {
  items : ImmArray[T]
}

fn id_imm[T](xs : ImmArray[T]) -> ImmArray[T] {
  xs
}

fn same_imm[T](a : ImmArray[T], b : ImmArray[T]) -> Bool {
  a == b
}

fn take_imm(xs : ImmArray[Int]) -> Int {
  let mut s = 0
  for i, v in xs {
    s = s + (i + 1) * v
  }
  s
}

fn ret_imm_lit() -> ImmArray[String] {
  ["alpha", "beta", "gamma"]
}

pub fn main(w : World) -> Int {
  // 1. Empty ImmArray
  let e1 : ImmArray[Int] = ImmArray::new()
  let e2 : ImmArray[Int] = []
  debug_assert(e1.is_empty(), "e1 empty")
  debug_assert(e1.length() == 0, "e1 len")
  debug_assert(e1 == e2, "empty eq")

  // 2. Literal expected-type inference (let, param, struct field, return)
  let xs : ImmArray[Int] = [10, 20, 30]
  debug_assert(!xs.is_empty(), "xs non-empty")
  debug_assert(xs.length() == 3, "xs len")
  debug_assert(xs[0] == 10 && xs[1] == 20 && xs[2] == 30, "xs idx")
  debug_assert(take_imm([2, 3, 4]) == 2 + 6 + 12, "param lit")
  let bx = Boxed::{ items: [7, 8] }
  debug_assert(bx.items.length() == 2 && bx.items[1] == 8, "field lit")
  let rs = ret_imm_lit()
  debug_assert(rs.length() == 3 && rs[2] == "gamma", "ret lit")

  // 3. Zero mutable aliasing: Array -> ImmArray -> Array
  let mut src : Array[Int] = [1, 2, 3]
  let ia1 = ImmArray::from_array(src)
  let ia2 = src.to_imm()
  src[0] = 999
  src.push(4)
  debug_assert(ia1.length() == 3 && ia1[0] == 1 && ia1[2] == 3, "from_array isolated")
  debug_assert(ia2.length() == 3 && ia2[0] == 1 && ia2[2] == 3, "to_imm isolated")
  debug_assert(ia1 == ia2, "ia1 == ia2")

  let mut mut_copy = ia1.to_array()
  mut_copy[1] = 888
  mut_copy.push(555)
  debug_assert(ia1.length() == 3 && ia1[1] == 2, "to_array isolated")

  let cp = ia1.copy()
  debug_assert(cp == ia1 && !(cp != ia1), "copy eq")

  // 4. ImmArray::make (scalars, strings, flat POD, mixed RC)
  let mk_i = ImmArray::make(4, 42)
  debug_assert(mk_i.length() == 4 && mk_i[0] == 42 && mk_i[3] == 42, "make int")
  let mk_s = ImmArray::make(3, "ok")
  debug_assert(mk_s == ["ok", "ok", "ok"], "make str eq")
  debug_assert(mk_s != ["ok", "no", "ok"], "make str ne")

  // 5. Compact 1-byte & 4-byte & 8-byte & Float/Double NaN equality
  let bs : ImmArray[Byte] = [b'a', b'b', b'c']
  let bs2 : ImmArray[Byte] = [b'a', b'b', b'c']
  let bs3 : ImmArray[Byte] = [b'a', b'b', b'd']
  debug_assert(bs == bs2 && bs != bs3, "byte eq")

  let fls : ImmArray[Double] = [1.5, 2.5]
  let fls2 : ImmArray[Double] = [1.5, 2.5]
  debug_assert(fls == fls2, "double eq")
  let pz : ImmArray[Double] = [0.0]
  let nz : ImmArray[Double] = [-0.0]
  debug_assert(pz == nz && !(pz != nz), "double +0.0 == -0.0")
  let nan = 0.0 / 0.0
  let nans : ImmArray[Double] = [nan]
  debug_assert(!(nans == nans) && nans != nans, "double NaN ne")

  // 5b. No symbol collision between ImmArray[Box[Int]] and ImmArray[Box_i]
  let bx1 : ImmArray[Box[Int]] = [Box::{ a: 1 }]
  let bx2 : ImmArray[Box[Int]] = [Box::{ a: 1 }]
  let bi1 : ImmArray[Box_i] = [Box_i::{ a: 1, b: 10 }]
  let bi2 : ImmArray[Box_i] = [Box_i::{ a: 1, b: 20 }]
  debug_assert(bx1 == bx2, "Box[Int] eq")
  debug_assert(bi1 != bi2 && !(bi1 == bi2), "Box_i ne on field b")

  // 6. Flat POD struct & Mixed RC struct ImmArray
  let mut pods_src : Array[FlatPod] = [FlatPod::{ x: 1, y: 2 }, FlatPod::{ x: 3, y: 4 }]
  let pods = pods_src.to_imm()
  pods_src[0] = FlatPod::{ x: 9, y: 9 }
  debug_assert(pods[0].x == 1 && pods[1].y == 4, "flat pod isolated")
  let pods2 : ImmArray[FlatPod] = [FlatPod::{ x: 1, y: 2 }, FlatPod::{ x: 3, y: 4 }]
  debug_assert(pods == pods2, "flat pod eq")

  let s_a = "hel" + "lo"
  let s_b = "wor" + "ld"
  let mut rcs_src : Array[MixedRc] = [
    MixedRc::{ label: s_a, n: 10 },
    MixedRc::{ label: s_b, n: 20 },
  ]
  let rcs = ImmArray::from_array(rcs_src)
  rcs_src[0] = MixedRc::{ label: "mutated", n: 99 }
  debug_assert(rcs[0].label == "hello" && rcs[0].n == 10, "mixed rc isolated")
  debug_assert(rcs[1].label == "world" && rcs[1].n == 20, "mixed rc elem1")
  let rcs2 : ImmArray[MixedRc] = [
    MixedRc::{ label: "hello", n: 10 },
    MixedRc::{ label: "world", n: 20 },
  ]
  debug_assert(rcs == rcs2, "mixed rc eq")
  let rcs_back = rcs.to_array()
  rcs_back[1] = MixedRc::{ label: "changed", n: 0 }
  debug_assert(rcs[1].label == "world", "mixed rc to_array isolated")

  // 7. Nested ImmArray & generic equality
  let mat1 : ImmArray[ImmArray[String]] = [["a", "b"], ["c"]]
  let mat2 : ImmArray[ImmArray[String]] = [["a", "b"], ["c"]]
  let mat3 : ImmArray[ImmArray[String]] = [["a", "b"], ["d"]]
  debug_assert(mat1 == mat2 && mat1 != mat3, "nested imm eq")
  debug_assert(same_imm(id_imm(xs), [10, 20, 30]), "generic imm eq")
  debug_assert(same_imm(rs, ["alpha", "beta", "gamma"]), "generic str imm eq")

  io_println(w, "J3_CORE_OK")
  0
}
EOF

CORE_NAT="$("$PIONC" run "$TMP_DIR/j3_core.pion")"
[ "$CORE_NAT" = "J3_CORE_OK" ] || { echo "FAIL: native core: $CORE_NAT" >&2; exit 1; }
echo "PASS: J3 core (Native)"

if command -v node >/dev/null 2>&1; then
  CORE_WASM="$("$PIONC" run --target wasm32 "$TMP_DIR/j3_core.pion")"
  [ "$CORE_WASM" = "J3_CORE_OK" ] || { echo "FAIL: wasm32 core: $CORE_WASM" >&2; exit 1; }
  echo "PASS: J3 core (Wasm32)"
fi

# =====================================================================
# Part 2: Out-of-bounds panic checks (build exit 0 + exact bounds msg)
# =====================================================================
cat > "$TMP_DIR/j3_oob_pos.pion" <<'EOF'
pub fn main() -> Int {
  let xs : ImmArray[Int] = [1, 2, 3]
  xs[5]
}
EOF
cat > "$TMP_DIR/j3_oob_neg.pion" <<'EOF'
pub fn main() -> Int {
  let xs : ImmArray[Int] = [1, 2, 3]
  xs[-1]
}
EOF
cat > "$TMP_DIR/j3_oob_empty.pion" <<'EOF'
pub fn main() -> Int {
  let xs : ImmArray[Int] = ImmArray::new()
  xs[0]
}
EOF
check_oob_case() {
  OOB_NAME="$1"
  EXP_NAT="$2"
  EXP_WASM="$3"
  "$PIONC" build -o "$TMP_DIR/${OOB_NAME}_bin" "$TMP_DIR/${OOB_NAME}.pion"
  set +e
  OOB_ERR="$("$TMP_DIR/${OOB_NAME}_bin" 2>&1)"
  OOB_RC=$?
  set -e
  [ "$OOB_RC" -ne 0 ] || { echo "FAIL: Native ${OOB_NAME} did not panic" >&2; exit 1; }
  echo "$OOB_ERR" | grep -Fq "$EXP_NAT" || { echo "FAIL: Native ${OOB_NAME} missing '$EXP_NAT', got: $OOB_ERR" >&2; exit 1; }
  echo "PASS: J3 Native ${OOB_NAME} panic (rc=$OOB_RC, $EXP_NAT)"
  if command -v node >/dev/null 2>&1; then
    "$PIONC" build --target wasm32 -o "$TMP_DIR/${OOB_NAME}.wasm" "$TMP_DIR/${OOB_NAME}.pion"
    set +e
    W_ERR="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/${OOB_NAME}.wasm" 2>&1)"
    W_RC=$?
    set -e
    [ "$W_RC" -ne 0 ] || { echo "FAIL: Wasm32 ${OOB_NAME} did not panic" >&2; exit 1; }
    echo "$W_ERR" | grep -Fq "$EXP_WASM" || { echo "FAIL: Wasm32 ${OOB_NAME} missing '$EXP_WASM', got: $W_ERR" >&2; exit 1; }
    echo "PASS: J3 Wasm32 ${OOB_NAME} panic (rc=$W_RC, $EXP_WASM)"
  fi
}
check_oob_case j3_oob_pos "pion panic: index 5 out of bounds (len 3)" "pion panic: index out of bounds: idx=5, len=3"
check_oob_case j3_oob_neg "pion panic: index -1 out of bounds (len 3)" "pion panic: index out of bounds: idx=-1, len=3"
check_oob_case j3_oob_empty "pion panic: index 0 out of bounds (len 0)" "pion panic: index out of bounds: idx=0, len=0"

# =====================================================================
# Part 2b: CLI check/build arity rejection (never crash backend)
# =====================================================================
for AR_CASE in \
  'pub fn main() -> Int { let _ = ImmArray::make(1); 0 }' \
  'pub fn main() -> Int { let _ = ImmArray::from_array(); 0 }' \
  'pub fn main() -> Int { let a : Array[Int] = [1]; let _ = a.to_imm(1); 0 }' \
  'pub fn main() -> Int { let xs : ImmArray[Int] = [1]; xs.length(1) }' \
  'pub fn main(xs : ImmArray[Int, Bool]) -> Int { 0 }'
do
  printf '%s\n' "$AR_CASE" > "$TMP_DIR/j3_arity.pion"
  set +e
  CHK_OUT="$("$PIONC" check --json "$TMP_DIR/j3_arity.pion" 2>&1)"
  CHK_RC=$?
  BLD_OUT="$("$PIONC" build -o "$TMP_DIR/j3_arity_bin" "$TMP_DIR/j3_arity.pion" 2>&1)"
  BLD_RC=$?
  set -e
  [ "$CHK_RC" -ne 0 ] || { echo "FAIL: check accepted bad arity: $AR_CASE" >&2; exit 1; }
  echo "$CHK_OUT" | grep -q '"code":"E_ARITY_MISMATCH"' || { echo "FAIL: missing E_ARITY_MISMATCH: $CHK_OUT" >&2; exit 1; }
  [ "$BLD_RC" -ne 0 ] || { echo "FAIL: build accepted bad arity: $AR_CASE" >&2; exit 1; }
  [ "$BLD_RC" -lt 128 ] || { echo "FAIL: build crashed (rc=$BLD_RC): $BLD_OUT" >&2; exit 1; }
done
echo "PASS: J3 CLI arity guards (check --json + build, no crash)"

# =====================================================================
# Part 3: Multithreaded Send + Deep-Freeze + Repeated/Aliased Leaf RC
# =====================================================================
cat > "$TMP_DIR/j3_mt.pion" <<'EOF'
val struct MixedLeaf {
  tag : String
  val_n : Int
}

val struct Packet {
  id : Int
  words : ImmArray[String]
  leaves : ImmArray[MixedLeaf]
}

pub fn main(w : World) -> Int {
  // Dynamic heap strings with external aliases AND repeated occurrences inside ImmArray
  let shared_a = "leaf_" + "alpha"
  let shared_b = "leaf_" + "beta"
  let mut tmp_words : Array[String] = []
  let mut i = 0
  while i < 16 {
    tmp_words.push(if i % 2 == 0 { shared_a } else { shared_b })
    i = i + 1
  }
  let words = tmp_words.to_imm()
  // Mutate original array after freezing snapshot
  tmp_words[0] = "corrupted"
  tmp_words.push("extra")

  let leaves : ImmArray[MixedLeaf] = [
    MixedLeaf::{ tag: shared_a, val_n: 10 },
    MixedLeaf::{ tag: shared_b, val_n: 20 },
    MixedLeaf::{ tag: shared_a, val_n: 30 },
  ]
  let pkt = Packet::{ id: 7, words: words, leaves: leaves }
  let ch : Channel[Packet] = Channel::new(8)
  let m : Mutex[ImmArray[String]] = Mutex::new(words)
  let acc = AtomicInt::new(0)

  scope(w, fn(s : Scope) -> Unit {
    let mut t = 0
    while t < 4 {
      let tid = t
      spawn(s, fn() -> Unit {
        let mut local_sum = 0
        let mut round = 0
        while round < 50 {
          let mut j = 0
          while j < pkt.words.length() {
            local_sum = local_sum + pkt.words[j].length()
            j = j + 1
          }
          let mut k = 0
          while k < pkt.leaves.length() {
            local_sum = local_sum + pkt.leaves[k].val_n + pkt.leaves[k].tag.length()
            k = k + 1
          }
          let mlen = m.with_lock(fn(xs : ImmArray[String]) -> Int { xs.length() })
          local_sum = local_sum + mlen
          round = round + 1
        }
        let _ = acc.fetch_add(local_sum)
        if tid == 0 {
          ch.send(pkt)
        }
      })
      t = t + 1
    }
  })

  let got = match ch.recv() {
    Some(p) => p
    None => Packet::{ id: 0, words: [], leaves: [] }
  }
  debug_assert(got.id == 7, "pkt id")
  debug_assert(got.words.length() == 16 && got.words[0] == "leaf_alpha", "pkt words intact")
  debug_assert(got.leaves.length() == 3 && got.leaves[1].tag == "leaf_beta", "pkt leaves intact")
  // External aliases still valid after workers released their copies
  debug_assert(shared_a == "leaf_alpha" && shared_b == "leaf_beta", "external aliases intact")
  // Expected per round: words (8*10 + 8*9 = 152) + leaves (10+10 + 20+9 + 30+10 = 89) + mlen (16) = 257
  // 4 threads * 50 rounds * 257 = 51400
  let total = acc.load()
  debug_assert(total == 51400, "mt total mismatch")
  io_println(w, "J3_MT_OK:" + total.to_string())
  0
}
EOF

MT_OUT="$("$PIONC" run "$TMP_DIR/j3_mt.pion")"
[ "$MT_OUT" = "J3_MT_OK:51400" ] || { echo "FAIL: mt test: $MT_OUT" >&2; exit 1; }
echo "PASS: J3 multithreaded deep-freeze & RC ($MT_OUT)"

# Optional ASan/LSan verification of j3_core and j3_mt when compiler supports it
ASAN_CC="${CC:-cc}"
printf 'int main(void){return 0;}\n' > "$TMP_DIR/asan_probe.c"
if "$ASAN_CC" -fsanitize=address "$TMP_DIR/asan_probe.c" -o "$TMP_DIR/asan_probe" >/dev/null 2>&1 && "$TMP_DIR/asan_probe" >/dev/null 2>&1; then
  CC="$ASAN_CC" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  "$PIONC" build --emit-obj "$TMP_DIR/j3_core.o" "$TMP_DIR/j3_core.pion"
  "$ASAN_CC" -fsanitize=address "$TMP_DIR/j3_core.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/j3_core_asan"
  ASAN_CORE="$("$TMP_DIR/j3_core_asan")"
  [ "$ASAN_CORE" = "J3_CORE_OK" ] || { echo "FAIL: ASan core: $ASAN_CORE" >&2; exit 1; }
  "$PIONC" build --emit-obj "$TMP_DIR/j3_mt.o" "$TMP_DIR/j3_mt.pion"
  "$ASAN_CC" -fsanitize=address "$TMP_DIR/j3_mt.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/j3_mt_asan"
  ASAN_MT="$("$TMP_DIR/j3_mt_asan")"
  [ "$ASAN_MT" = "J3_MT_OK:51400" ] || { echo "FAIL: ASan mt: $ASAN_MT" >&2; exit 1; }
  echo "PASS: J3 ASan/LSan (core + multithreaded 0 leaks)"
fi

# =====================================================================
# Part 4: Cross-package .pionsig / .pionstub round-trip (Native + Wasm32)
# =====================================================================
mkdir -p "$TMP_DIR/ws/lib/src" "$TMP_DIR/ws/app/src"
cat > "$TMP_DIR/ws/lib/pion.toml" <<'EOF'
[package]
name = "lib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws/lib/src/lib.pion" <<'EOF'
#derive(Eq)
pub val struct Config {
  tags : ImmArray[String]
}

pub fn make_config(a : Array[String]) -> Config {
  Config::{ tags: a.to_imm() }
}

pub fn wrap_one[T](x : T) -> ImmArray[T] {
  ImmArray::make(2, x)
}
EOF
cat > "$TMP_DIR/ws/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
lib = { path = "../lib" }
EOF
cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "lib"

pub fn main(w : World) -> Int {
  let mut raw : Array[String] = ["x", "y"]
  let cfg = lib::make_config(raw)
  raw.push("z")
  let wrapped = lib::wrap_one(42)
  let ok = cfg.tags == ["x", "y"] && wrapped == [42, 42]
  debug_assert(ok, "xpkg imm check")
  io_println(w, "J3_XPKG_OK")
  0
}
EOF

XPKG_NAT="$("$PIONC" run "$TMP_DIR/ws/app")"
[ "$XPKG_NAT" = "J3_XPKG_OK" ] || { echo "FAIL: xpkg native: $XPKG_NAT" >&2; exit 1; }
echo "PASS: J3 cross-package .pionstub (Native)"

if command -v node >/dev/null 2>&1; then
  XPKG_WASM="$("$PIONC" run --target wasm32 "$TMP_DIR/ws/app")"
  [ "$XPKG_WASM" = "J3_XPKG_OK" ] || { echo "FAIL: xpkg wasm32: $XPKG_WASM" >&2; exit 1; }
  echo "PASS: J3 cross-package .pionstub (Wasm32)"
fi

# =====================================================================
# Part 4b: Cross-package symbol disambiguation (a::B__C vs a__B::C)
# =====================================================================
mkdir -p "$TMP_DIR/xcol/a/src" "$TMP_DIR/xcol/a__B/src" "$TMP_DIR/xcol/app1/src" "$TMP_DIR/xcol/app2/src"
cat > "$TMP_DIR/xcol/a/pion.toml" <<'EOF'
[package]
name = "a"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xcol/a/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct B__C {
  x : Int
}
EOF
cat > "$TMP_DIR/xcol/a__B/pion.toml" <<'EOF'
[package]
name = "a__B"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xcol/a__B/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct C {
  x : Int
  y : Int
}
EOF
for ORD in 1 2; do
  cat > "$TMP_DIR/xcol/app${ORD}/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
a = { path = "../a" }
a__B = { path = "../a__B" }
EOF
done
cat > "$TMP_DIR/xcol/app1/src/main.pion" <<'EOF'
import "a"
import "a__B"

pub fn main(w : World) -> Int {
  let u1 : ImmArray[a::B__C] = [a::B__C::{ x: 1 }]
  let u2 : ImmArray[a::B__C] = [a::B__C::{ x: 1 }]
  let v1 : ImmArray[a__B::C] = [a__B::C::{ x: 1, y: 10 }]
  let v2 : ImmArray[a__B::C] = [a__B::C::{ x: 1, y: 20 }]
  debug_assert(u1 == u2, "a::B__C eq")
  debug_assert(v1 != v2 && !(v1 == v2), "a__B::C ne on y")
  io_println(w, "J3_XCOL1_OK")
  0
}
EOF
cat > "$TMP_DIR/xcol/app2/src/main.pion" <<'EOF'
import "a__B"
import "a"

pub fn main(w : World) -> Int {
  let v1 : ImmArray[a__B::C] = [a__B::C::{ x: 1, y: 10 }]
  let v2 : ImmArray[a__B::C] = [a__B::C::{ x: 1, y: 20 }]
  let u1 : ImmArray[a::B__C] = [a::B__C::{ x: 1 }]
  let u2 : ImmArray[a::B__C] = [a::B__C::{ x: 1 }]
  debug_assert(v1 != v2 && !(v1 == v2), "a__B::C ne on y")
  debug_assert(u1 == u2, "a::B__C eq")
  io_println(w, "J3_XCOL2_OK")
  0
}
EOF
for ORD in 1 2; do
  "$PIONC" build -o "$TMP_DIR/xcol_app${ORD}_bin" "$TMP_DIR/xcol/app${ORD}"
  XCOL_NAT="$("$TMP_DIR/xcol_app${ORD}_bin")"
  [ "$XCOL_NAT" = "J3_XCOL${ORD}_OK" ] || { echo "FAIL: xcol${ORD} native: $XCOL_NAT" >&2; exit 1; }
  "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xcol_app${ORD}.ssa" -o "$TMP_DIR/xcol_app${ORD}.wasm" "$TMP_DIR/xcol/app${ORD}"
  grep -Eq 'pion_eq_iarr_st_0P(1_a|13_a_u_u[0-9a-f]{8})_N6_B_u_uC_A0\(' "$TMP_DIR/xcol_app${ORD}.ssa" || { echo "FAIL: missing a::B__C eq helper in app${ORD}" >&2; grep 'pion_eq_' "$TMP_DIR/xcol_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'pion_eq_iarr_st_0P(6_a_u_uB|18_a_u_uB_u_u[0-9a-f]{8})_N1_C_A0\(' "$TMP_DIR/xcol_app${ORD}.ssa" || { echo "FAIL: missing a__B::C eq helper in app${ORD}" >&2; grep 'pion_eq_' "$TMP_DIR/xcol_app${ORD}.ssa" >&2 || true; exit 1; }
  if command -v node >/dev/null 2>&1; then
    XCOL_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xcol_app${ORD}.wasm")"
    [ "$XCOL_WASM" = "J3_XCOL${ORD}_OK" ] || { echo "FAIL: xcol${ORD} wasm32: $XCOL_WASM" >&2; exit 1; }
  fi
done
echo "PASS: J3 cross-package a::B__C vs a__B::C disambiguation (both orders, Native + Wasm32 + SSA)"

# =====================================================================
# Part 4c: Cross-package reversible encoding (a-b::Item vs a_b::Item)
# =====================================================================
mkdir -p "$TMP_DIR/xhyp/a-b/src" "$TMP_DIR/xhyp/a_b/src" "$TMP_DIR/xhyp/app1/src" "$TMP_DIR/xhyp/app2/src"
cat > "$TMP_DIR/xhyp/a-b/pion.toml" <<'EOF'
[package]
name = "a-b"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xhyp/a-b/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct Item {
  x : Int
}

pub fn tag() -> Int { 11 }

#derive(Eq)
pub enum Kind {
  A
  B
}
EOF
cat > "$TMP_DIR/xhyp/a_b/pion.toml" <<'EOF'
[package]
name = "a_b"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xhyp/a_b/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct Item {
  x : Int
  y : Int
}

pub fn tag() -> Int { 22 }

#derive(Eq)
pub enum Kind {
  B
  A
}
EOF
for ORD in 1 2; do
  cat > "$TMP_DIR/xhyp/app${ORD}/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
a-b = { path = "../a-b" }
a_b = { path = "../a_b" }
EOF
done
cat > "$TMP_DIR/xhyp/app1/src/main.pion" <<'EOF'
import "a-b" as left
import "a_b"

fn same[T](x : T, y : T) -> Bool { x == y }
fn apply(f : () -> Int) -> Int { f() }

pub fn main(w : World) -> Int {
  let u1 : ImmArray[left::Item] = [left::Item::{ x: 1 }]
  let u2 : ImmArray[left::Item] = [left::Item::{ x: 1 }]
  let v1 : ImmArray[a_b::Item] = [a_b::Item::{ x: 1, y: 10 }]
  let v2 : ImmArray[a_b::Item] = [a_b::Item::{ x: 1, y: 20 }]
  debug_assert(same(u1, u2), "a-b::Item eq via generic same")
  debug_assert(!same(v1, v2), "a_b::Item ne on y via generic same")
  debug_assert(apply(left::tag) == 11, "a-b::tag wrapper")
  debug_assert(apply(a_b::tag) == 22, "a_b::tag wrapper")
  let lk_a = left::Kind::A
  let lk_b = left::Kind::B
  let rk_a = a_b::Kind::A
  let rk_b = a_b::Kind::B
  let l_code = match lk_a { left::Kind::A => 101; left::Kind::B => 102 }
  let r_code = match rk_a { a_b::Kind::B => 201; a_b::Kind::A => 202 }
  debug_assert(l_code == 101 && r_code == 202, "enum const hdr tags distinct")
  debug_assert(lk_a != lk_b && rk_a != rk_b, "enum variants distinct")
  io_println(w, "J3_XHYP1_OK")
  0
}
EOF
cat > "$TMP_DIR/xhyp/app2/src/main.pion" <<'EOF'
import "a_b"
import "a-b" as left

fn same[T](x : T, y : T) -> Bool { x == y }
fn apply(f : () -> Int) -> Int { f() }

pub fn main(w : World) -> Int {
  let v1 : ImmArray[a_b::Item] = [a_b::Item::{ x: 1, y: 10 }]
  let v2 : ImmArray[a_b::Item] = [a_b::Item::{ x: 1, y: 20 }]
  let u1 : ImmArray[left::Item] = [left::Item::{ x: 1 }]
  let u2 : ImmArray[left::Item] = [left::Item::{ x: 1 }]
  debug_assert(!same(v1, v2), "a_b::Item ne on y via generic same")
  debug_assert(same(u1, u2), "a-b::Item eq via generic same")
  debug_assert(apply(a_b::tag) == 22, "a_b::tag wrapper")
  debug_assert(apply(left::tag) == 11, "a-b::tag wrapper")
  let rk_a = a_b::Kind::A
  let rk_b = a_b::Kind::B
  let lk_a = left::Kind::A
  let lk_b = left::Kind::B
  let r_code = match rk_a { a_b::Kind::B => 201; a_b::Kind::A => 202 }
  let l_code = match lk_a { left::Kind::A => 101; left::Kind::B => 102 }
  debug_assert(r_code == 202 && l_code == 101, "enum const hdr tags distinct")
  debug_assert(rk_a != rk_b && lk_a != lk_b, "enum variants distinct")
  io_println(w, "J3_XHYP2_OK")
  0
}
EOF
for ORD in 1 2; do
  "$PIONC" build -o "$TMP_DIR/xhyp_app${ORD}_bin" "$TMP_DIR/xhyp/app${ORD}"
  XHYP_NAT="$("$TMP_DIR/xhyp_app${ORD}_bin")"
  [ "$XHYP_NAT" = "J3_XHYP${ORD}_OK" ] || { echo "FAIL: xhyp${ORD} native: $XHYP_NAT" >&2; exit 1; }
  "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xhyp_app${ORD}.ssa" -o "$TMP_DIR/xhyp_app${ORD}.wasm" "$TMP_DIR/xhyp/app${ORD}"
  grep -Eq 'pion_eq_iarr_st_0P(4_a_db|16_a_db_u_u[0-9a-f]{8})_N4_Item_A0\(' "$TMP_DIR/xhyp_app${ORD}.ssa" || { echo "FAIL: missing a-b::Item eq helper in app${ORD}" >&2; grep 'pion_eq_' "$TMP_DIR/xhyp_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'pion_eq_iarr_st_0P(4_a_ub|16_a_ub_u_u[0-9a-f]{8})_N4_Item_A0\(' "$TMP_DIR/xhyp_app${ORD}.ssa" || { echo "FAIL: missing a_b::Item eq helper in app${ORD}" >&2; grep 'pion_eq_' "$TMP_DIR/xhyp_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'same__mono_ImmArray_0L[0-9]+_0P(4_a_db|16_a_db_u_u[0-9a-f]{8})_N4_Item\(' "$TMP_DIR/xhyp_app${ORD}.ssa" || { echo "FAIL: missing a-b::Item mono same in app${ORD}" >&2; grep 'same__mono_' "$TMP_DIR/xhyp_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'same__mono_ImmArray_0L[0-9]+_(a_b__Item|0P16_a_ub_u_u[0-9a-f]{8}_N4_Item)\(' "$TMP_DIR/xhyp_app${ORD}.ssa" || { echo "FAIL: missing a_b::Item mono same in app${ORD}" >&2; grep 'same__mono_' "$TMP_DIR/xhyp_app${ORD}.ssa" >&2 || true; exit 1; }
  if command -v node >/dev/null 2>&1; then
    XHYP_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xhyp_app${ORD}.wasm")"
    [ "$XHYP_WASM" = "J3_XHYP${ORD}_OK" ] || { echo "FAIL: xhyp${ORD} wasm32: $XHYP_WASM" >&2; exit 1; }
  fi
done
echo "PASS: J3 cross-package a-b::Item vs a_b::Item reversible encoding (mono + wrap + enum hdr, both orders, Native + Wasm32 + SSA)"

# =====================================================================
# Part 4d: R6 prefix-free encoding (a_::tag vs a::_tag, 2-arg mono split, mixed enum _u_/_b_ hdr)
# =====================================================================
mkdir -p "$TMP_DIR/xr6/a_/src" "$TMP_DIR/xr6/a/src" "$TMP_DIR/xr6/p/src" "$TMP_DIR/xr6/app1/src" "$TMP_DIR/xr6/app2/src"
cat > "$TMP_DIR/xr6/a_/pion.toml" <<'EOF'
[package]
name = "a_"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr6/a_/src/lib.pion" <<'EOF'
pub fn tag() -> Int { 11 }
EOF
cat > "$TMP_DIR/xr6/a/pion.toml" <<'EOF'
[package]
name = "a"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr6/a/src/lib.pion" <<'EOF'
pub fn _tag() -> Int { 22 }
EOF
cat > "$TMP_DIR/xr6/p/pion.toml" <<'EOF'
[package]
name = "p"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr6/p/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct A { pub x : Int }
#derive(Eq)
pub struct B_p__C { pub x : Int, pub y : Int }
#derive(Eq)
pub struct A_p__B { pub x : Int, pub y : Int, pub z : Int }
#derive(Eq)
pub struct C { pub x : Int }
EOF
for ORD in 1 2; do
  cat > "$TMP_DIR/xr6/app${ORD}/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
a_ = { path = "../a_" }
a = { path = "../a" }
p = { path = "../p" }
EOF
done
cat > "$TMP_DIR/xr6/app1/src/main.pion" <<'EOF'
import "a_"
import "a"
import "p"

enum E {
  Flag(Bool)
  Flag_1
  Other(Int)
}

fn apply(f : () -> Int) -> Int { f() }

fn pair_layout[X, Y](x1 : X, x2 : X, y1 : Y, y2 : Y) -> Int {
  let a = if x1 == x2 { 1 } else { 0 }
  let b = if y1 == y2 { 10 } else { 0 }
  a + b
}

fn eval_e(e : E) -> Int {
  match e {
    E::Flag(b) => if b { 101 } else { 100 }
    E::Flag_1 => 200
    E::Other(n) => 300 + n
  }
}

pub fn main(w : World) -> Int {
  debug_assert(apply(a_::tag) == 11, "a_::tag")
  debug_assert(apply(a::_tag) == 22, "a::_tag")
  let r1 = pair_layout(p::A::{ x: 1 }, p::A::{ x: 1 }, p::B_p__C::{ x: 1, y: 2 }, p::B_p__C::{ x: 1, y: 3 })
  let r2 = pair_layout(p::A_p__B::{ x: 1, y: 2, z: 3 }, p::A_p__B::{ x: 1, y: 2, z: 4 }, p::C::{ x: 5 }, p::C::{ x: 5 })
  debug_assert(r1 == 1 && r2 == 10, "pair_layout distinct mono")
  let e_t = E::Flag(true)
  let e_f = E::Flag(false)
  let e_1 = E::Flag_1
  let e_o = E::Other(7)
  debug_assert(eval_e(e_t) == 101 && eval_e(e_f) == 100 && eval_e(e_1) == 200 && eval_e(e_o) == 307, "enum u/b hdr order 1")
  io_println(w, "J3_XR6_1_OK")
  0
}
EOF
cat > "$TMP_DIR/xr6/app2/src/main.pion" <<'EOF'
import "a"
import "a_"
import "p"

enum E {
  Flag(Bool)
  Flag_1
  Other(Int)
}

fn apply(f : () -> Int) -> Int { f() }

fn pair_layout[X, Y](x1 : X, x2 : X, y1 : Y, y2 : Y) -> Int {
  let a = if x1 == x2 { 1 } else { 0 }
  let b = if y1 == y2 { 10 } else { 0 }
  a + b
}

fn eval_e(e : E) -> Int {
  match e {
    E::Flag(b) => if b { 101 } else { 100 }
    E::Flag_1 => 200
    E::Other(n) => 300 + n
  }
}

pub fn main(w : World) -> Int {
  debug_assert(apply(a::_tag) == 22, "a::_tag")
  debug_assert(apply(a_::tag) == 11, "a_::tag")
  let r2 = pair_layout(p::A_p__B::{ x: 1, y: 2, z: 3 }, p::A_p__B::{ x: 1, y: 2, z: 4 }, p::C::{ x: 5 }, p::C::{ x: 5 })
  let r1 = pair_layout(p::A::{ x: 1 }, p::A::{ x: 1 }, p::B_p__C::{ x: 1, y: 2 }, p::B_p__C::{ x: 1, y: 3 })
  debug_assert(r1 == 1 && r2 == 10, "pair_layout distinct mono")
  let e_1 = E::Flag_1
  let e_f = E::Flag(false)
  let e_t = E::Flag(true)
  let e_o = E::Other(7)
  debug_assert(eval_e(e_1) == 200 && eval_e(e_f) == 100 && eval_e(e_t) == 101 && eval_e(e_o) == 307, "enum u/b hdr order 2")
  io_println(w, "J3_XR6_2_OK")
  0
}
EOF
for ORD in 1 2; do
  "$PIONC" build -o "$TMP_DIR/xr6_app${ORD}_bin" "$TMP_DIR/xr6/app${ORD}"
  XR6_NAT="$("$TMP_DIR/xr6_app${ORD}_bin")"
  [ "$XR6_NAT" = "J3_XR6_${ORD}_OK" ] || { echo "FAIL: xr6_${ORD} native: $XR6_NAT" >&2; exit 1; }
  "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xr6_app${ORD}.ssa" -o "$TMP_DIR/xr6_app${ORD}.wasm" "$TMP_DIR/xr6/app${ORD}"
  grep -Eq 'wrap_ef_0P(3_a_u|15_a_u_u_u[0-9a-f]{8})_N3_tag\(' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing a_::tag wrapper in xr6 app${ORD}" >&2; grep 'wrap_ef_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'wrap_ef_0P(1_a|13_a_u_u[0-9a-f]{8})_N5__utag\(' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing a::_tag wrapper in xr6 app${ORD}" >&2; grep 'wrap_ef_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'pair_layout__mono_0L[0-9]+_(p__A|0P13_p_u_u[0-9a-f]{8}_N1_A)_0L[0-9]+_(p__B_p__C|0P13_p_u_u[0-9a-f]{8}_N[0-9]+_B_up_u_uC)\(' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing (A, B_p__C) mono in xr6 app${ORD}" >&2; grep 'pair_layout__mono_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'pair_layout__mono_0L[0-9]+_(p__A_p__B|0P13_p_u_u[0-9a-f]{8}_N[0-9]+_A_up_u_uB)_0L[0-9]+_(p__C|0P13_p_u_u[0-9a-f]{8}_N1_C)\(' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing (A_p__B, C) mono in xr6 app${ORD}" >&2; grep 'pair_layout__mono_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'pion_enum_u_E_M7_Flag_u1_hdr' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing _u_ enum hdr in xr6 app${ORD}" >&2; grep 'pion_enum_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'pion_enum_b_E_M4_Flag_1_hdr' "$TMP_DIR/xr6_app${ORD}.ssa" || { echo "FAIL: missing _b_ enum hdr in xr6 app${ORD}" >&2; grep 'pion_enum_' "$TMP_DIR/xr6_app${ORD}.ssa" >&2 || true; exit 1; }
  if command -v node >/dev/null 2>&1; then
    XR6_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr6_app${ORD}.wasm")"
    [ "$XR6_WASM" = "J3_XR6_${ORD}_OK" ] || { echo "FAIL: xr6_${ORD} wasm32: $XR6_WASM" >&2; exit 1; }
  fi
done
echo "PASS: J3 R6 prefix-free encoding (a_::tag vs a::_tag, 2-arg mono split, mixed enum _u_/_b_ hdr, both orders, Native + Wasm32 + SSA)"

# =====================================================================
# Part 4e: R7 namespace disjointness (wrap_ef vs wrap_em, T_::tag vs T::_tag, trait A_/B vs A/_B)
# =====================================================================
mkdir -p "$TMP_DIR/xr7/p/src" "$TMP_DIR/xr7/m_p/src" "$TMP_DIR/xr7/app1/src" "$TMP_DIR/xr7/app2/src"
cat > "$TMP_DIR/xr7/p/pion.toml" <<'EOF'
[package]
name = "p"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr7/p/src/lib.pion" <<'EOF'
pub struct T { pub x : Int }
pub fn T::tag() -> Int { 11 }
EOF
cat > "$TMP_DIR/xr7/m_p/pion.toml" <<'EOF'
[package]
name = "m_p"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr7/m_p/src/lib.pion" <<'EOF'
pub fn T_M3_tag() -> Int { 22 }
EOF
for ORD in 1 2; do
  cat > "$TMP_DIR/xr7/app${ORD}/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
p = { path = "../p" }
m_p = { path = "../m_p" }
EOF
done
cat > "$TMP_DIR/xr7/app1/src/main.pion" <<'EOF'
import "p"
import "m_p"

struct T_ { x : Int }
fn T_::tag() -> Int { 31 }
struct T { x : Int }
fn T::_tag() -> Int { 32 }

trait A_ { fn score(self : Self) -> Int }
trait A { fn score(self : Self) -> Int }
struct B { x : Int }
struct _B { x : Int }
impl A_ for B { fn score(self : B) -> Int { 41 + self.x } }
impl A for _B { fn score(self : _B) -> Int { 42 + self.x } }

fn apply(f : () -> Int) -> Int { f() }
fn call_a_(d : dyn A_) -> Int { d.score() }
fn call_a(d : dyn A) -> Int { d.score() }

pub fn main(w : World) -> Int {
  debug_assert(apply(p::T::tag) == 11, "wrap_em p::T::tag")
  debug_assert(apply(m_p::T_M3_tag) == 22, "wrap_ef m_p::T_M3_tag")
  debug_assert(T_::tag() == 31 && T::_tag() == 32, "direct T_::tag vs T::_tag")
  debug_assert(apply(T_::tag) == 31 && apply(T::_tag) == 32, "wrap_lm T_::tag vs T::_tag")
  let d1 : dyn A_ = B::{ x: 0 }
  let d2 : dyn A = _B::{ x: 0 }
  debug_assert(call_a_(d1) == 41 && call_a(d2) == 42, "vtable A_/B vs A/_B")
  io_println(w, "J3_XR7_1_OK")
  0
}
EOF
cat > "$TMP_DIR/xr7/app2/src/main.pion" <<'EOF'
import "m_p"
import "p"

struct T { x : Int }
fn T::_tag() -> Int { 32 }
struct T_ { x : Int }
fn T_::tag() -> Int { 31 }

trait A { fn score(self : Self) -> Int }
trait A_ { fn score(self : Self) -> Int }
struct _B { x : Int }
struct B { x : Int }
impl A for _B { fn score(self : _B) -> Int { 42 + self.x } }
impl A_ for B { fn score(self : B) -> Int { 41 + self.x } }

fn apply(f : () -> Int) -> Int { f() }
fn call_a(d : dyn A) -> Int { d.score() }
fn call_a_(d : dyn A_) -> Int { d.score() }

pub fn main(w : World) -> Int {
  debug_assert(apply(m_p::T_M3_tag) == 22, "wrap_ef m_p::T_M3_tag")
  debug_assert(apply(p::T::tag) == 11, "wrap_em p::T::tag")
  debug_assert(T::_tag() == 32 && T_::tag() == 31, "direct T::_tag vs T_::tag")
  debug_assert(apply(T::_tag) == 32 && apply(T_::tag) == 31, "wrap_lm T::_tag vs T_::tag")
  let d2 : dyn A = _B::{ x: 0 }
  let d1 : dyn A_ = B::{ x: 0 }
  debug_assert(call_a(d2) == 42 && call_a_(d1) == 41, "vtable A/_B vs A_/B")
  io_println(w, "J3_XR7_2_OK")
  0
}
EOF
for ORD in 1 2; do
  "$PIONC" build -o "$TMP_DIR/xr7_app${ORD}_bin" "$TMP_DIR/xr7/app${ORD}"
  XR7_NAT="$("$TMP_DIR/xr7_app${ORD}_bin")"
  [ "$XR7_NAT" = "J3_XR7_${ORD}_OK" ] || { echo "FAIL: xr7_${ORD} native: $XR7_NAT" >&2; exit 1; }
  "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xr7_app${ORD}.ssa" -o "$TMP_DIR/xr7_app${ORD}.wasm" "$TMP_DIR/xr7/app${ORD}"
  grep -Eq 'wrap_(lm|em)_(p__T|0P13_p_u_u[0-9a-f]{8}_N1_T)_M3_tag\(' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing method wrapper for p::T::tag in xr7 app${ORD}" >&2; grep 'wrap_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'wrap_ef_(m_p__T_M3_tag|0P16_m_up_u_u[0-9a-f]{8}_N[0-9]+_T_uM3_utag)\(' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing wrap_ef in xr7 app${ORD}" >&2; grep 'wrap_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'm_0P3_T_u_N3_tag(' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing T_::tag method def in xr7 app${ORD}" >&2; grep '_m_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'm_0P1_T_N5__utag(' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing T::_tag method def in xr7 app${ORD}" >&2; grep '_m_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'pion_vtable_0P3_A_u_N1_B' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing vtable A_/B in xr7 app${ORD}" >&2; grep 'pion_vtable_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Fq 'pion_vtable_0P1_A_N3__uB' "$TMP_DIR/xr7_app${ORD}.ssa" || { echo "FAIL: missing vtable A/_B in xr7 app${ORD}" >&2; grep 'pion_vtable_' "$TMP_DIR/xr7_app${ORD}.ssa" >&2 || true; exit 1; }
  if command -v node >/dev/null 2>&1; then
    XR7_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr7_app${ORD}.wasm")"
    [ "$XR7_WASM" = "J3_XR7_${ORD}_OK" ] || { echo "FAIL: xr7_${ORD} wasm32: $XR7_WASM" >&2; exit 1; }
  fi
done
echo "PASS: J3 R7 namespace disjointness (wrap_ef vs wrap_em, T_::tag vs T::_tag, vtable A_/B vs A/_B, both orders, Native + Wasm32 + SSA)"

# =====================================================================
# Part 4f: R8/R9 cross-package impl_method_sym, generic trait-bound dispatch & pkg_prefix boundary
# =====================================================================
mkdir -p "$TMP_DIR/xr8/left/src" "$TMP_DIR/xr8/right/src" "$TMP_DIR/xr8/p/src" "$TMP_DIR/xr8/p_m_A/src" "$TMP_DIR/xr8/app1/src" "$TMP_DIR/xr8/app2/src"
cat > "$TMP_DIR/xr8/left/pion.toml" <<'EOF'
[package]
name = "left"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr8/left/src/lib.pion" <<'EOF'
pub trait A {
  fn score(self : Self) -> Int
}
EOF
cat > "$TMP_DIR/xr8/right/pion.toml" <<'EOF'
[package]
name = "right"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr8/right/src/lib.pion" <<'EOF'
pub trait A {
  fn score(self : Self) -> Int
}
EOF
cat > "$TMP_DIR/xr8/p/pion.toml" <<'EOF'
[package]
name = "p"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr8/p/src/lib.pion" <<'EOF'
pub struct A_m_B { pub x : Int }
pub fn A_m_B::tag() -> Int { 11 }
struct MakeB { x : Int }
fn MakeB::length(self : MakeB) -> Int { -3 }
fn make() -> MakeB { MakeB::{ x: 0 } }
pub fn via_make_div[T](_ : T) -> Int {
  make().length() / 2
}
EOF
cat > "$TMP_DIR/xr8/p_m_A/pion.toml" <<'EOF'
[package]
name = "p_m_A"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr8/p_m_A/src/lib.pion" <<'EOF'
pub struct B { pub x : Int }
pub fn B::tag() -> Int { 22 }
EOF
for ORD in 1 2; do
  cat > "$TMP_DIR/xr8/app${ORD}/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
left = { path = "../left" }
right = { path = "../right" }
p = { path = "../p" }
p_m_A = { path = "../p_m_A" }
EOF
done
cat > "$TMP_DIR/xr8/app1/src/main.pion" <<'EOF'
import "left"
import "right"
import "p"
import "p_m_A"

struct B { x : Int }
fn B::score(self : B) -> Int { 33 + self.x }
fn B::pick(self : B) -> Option[Int] { Some(33 + self.x) }
fn B::trim(self : B) -> Int { 7 + self.x }
impl left::A for B {
  fn score(self : B) -> Int { 11 + self.x }
}
impl right::A for B {
  fn score(self : B) -> Int { 22 + self.x }
}

trait CustomLen {
  fn length(self : Self) -> Int
}
impl CustomLen for String {
  fn length(self : String) -> Int { 77 }
}

trait CustomSlice {
  fn slice(self : Self, a : Int, b : Int) -> Bytes
}
impl CustomSlice for Bytes {
  fn slice(self : Bytes, _a : Int, _b : Int) -> Bytes { "Z".to_bytes() }
}

trait CustomShow {
  fn to_string(self : Self) -> String
}
impl CustomShow for Int {
  fn to_string(self : Int) -> String { "CUSTOM_INT" }
}

trait Pick {
  fn pick(self : Self) -> Option[Int]
}
impl Pick for B {
  fn pick(self : B) -> Option[Int] { Some(11 + self.x) }
}

trait BigLen {
  fn length(self : Self) -> Int64
}
impl BigLen for String {
  fn length(self : String) -> Int64 { 4294967296L }
}

trait IntTrim {
  fn trim(self : Self) -> Int
}
impl IntTrim for String {
  fn trim(self : String) -> Int { 7 }
}

trait PassthruSlice {
  fn slice(self : Self, a : Int, b : Int) -> Bytes
}
impl PassthruSlice for Bytes {
  fn slice(self : Bytes, _a : Int, _b : Int) -> Bytes { self }
}

trait NegLen {
  fn length(self : Self) -> Int
}
impl NegLen for String {
  fn length(self : String) -> Int { -3 }
}

struct Holder { mut n : Int }
trait BumpMin {
  fn min(self : Self, h : Holder) -> Int
}
impl BumpMin for Int {
  fn min(self : Int, h : Holder) -> Int {
    h.n = h.n + 1
    self
  }
}

fn make() -> String { "hi" }

fn call_left(d : dyn left::A) -> Int { d.score() }
fn call_right(d : dyn right::A) -> Int { d.score() }
fn via_left[T : left::A](x : T) -> Int { x.score() }
fn via_right[T : right::A](x : T) -> Int { x.score() }
fn via_len[T : CustomLen](s : T) -> Int { s.length() }
fn via_slice_str[T : CustomSlice](x : T) -> String { x.slice(0, 1).to_string() }
fn via_sb_show[T : CustomShow](x : T) -> String {
  let sb = StringBuilder()
  sb.write_string(x.to_string())
  sb.to_string()
}
fn via_pick[T : Pick](x : T) -> Int {
  match x.pick() {
    Some(v) => v
    None => -1
  }
}
fn via_sb_biglen[T : BigLen](x : T) -> String {
  let sb = StringBuilder()
  sb.write_string(x.length().to_string())
  sb.to_string()
}
fn via_trim_add[T : IntTrim](x : T) -> Int {
  x.trim() + 1 + 2
}
fn via_ro_slice[T : PassthruSlice](x : T) -> Bytes {
  let b = x.slice(0, 1)
  b[0] = 65 as Byte
  b
}
fn via_neg_len_div[T : NegLen](x : T) -> Int {
  let a = x.length() / 2
  let n = x.length()
  let b = n / 2
  a * 10 + b
}
fn via_trait_min[T : BumpMin](x : T, h : Holder) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < 2 {
    let _ = x.min(h)
    acc = acc + h.n
    i = i + 1
  }
  acc
}

pub fn main(w : World) -> Int {
  let d1 : dyn left::A = B::{ x: 0 }
  let d2 : dyn right::A = B::{ x: 0 }
  let inh_pick = match (B::{ x: 0 }).pick() {
    Some(v) => v
    None => -1
  }
  let mb = via_ro_slice("xy".to_bytes())
  let inh_trim = B::{ x: 0 }.trim() + 1 + 2
  let res = "J3_XR8_1:" +
    B::{ x: 0 }.score().to_string() + "," +
    call_left(d1).to_string() + "," +
    call_right(d2).to_string() + "," +
    via_left(B::{ x: 0 }).to_string() + "," +
    via_right(B::{ x: 0 }).to_string() + "," +
    "abc".length().to_string() + "," +
    via_len("abc").to_string() + "," +
    "ab".to_bytes().slice(0, 1).to_string() + "," +
    via_slice_str("ab".to_bytes()) + "," +
    (42).to_string() + "," +
    via_sb_show(42) + "," +
    inh_pick.to_string() + "," +
    via_pick(B::{ x: 0 }).to_string() + "," +
    via_sb_biglen("hi") + "," +
    via_trim_add("hi").to_string() + "," +
    inh_trim.to_string() + "," +
    mb.to_string() + "," +
    via_neg_len_div("hi").to_string() + "," +
    p::via_make_div(0).to_string() + "," +
    via_trait_min(7, Holder::{ n: 0 }).to_string() + "," +
    make().length().to_string() + "," +
    p::A_m_B::tag().to_string() + "," +
    p_m_A::B::tag().to_string()
  io_println(w, res)
  0
}
EOF
cat > "$TMP_DIR/xr8/app2/src/main.pion" <<'EOF'
import "right"
import "left"
import "p_m_A"
import "p"

struct B { x : Int }
fn B::score(self : B) -> Int { 33 + self.x }
fn B::pick(self : B) -> Option[Int] { Some(33 + self.x) }
fn B::trim(self : B) -> Int { 7 + self.x }
impl right::A for B {
  fn score(self : B) -> Int { 22 + self.x }
}
impl left::A for B {
  fn score(self : B) -> Int { 11 + self.x }
}

trait CustomLen {
  fn length(self : Self) -> Int
}
impl CustomLen for String {
  fn length(self : String) -> Int { 77 }
}

trait CustomSlice {
  fn slice(self : Self, a : Int, b : Int) -> Bytes
}
impl CustomSlice for Bytes {
  fn slice(self : Bytes, _a : Int, _b : Int) -> Bytes { "Z".to_bytes() }
}

trait CustomShow {
  fn to_string(self : Self) -> String
}
impl CustomShow for Int {
  fn to_string(self : Int) -> String { "CUSTOM_INT" }
}

trait Pick {
  fn pick(self : Self) -> Option[Int]
}
impl Pick for B {
  fn pick(self : B) -> Option[Int] { Some(11 + self.x) }
}

trait BigLen {
  fn length(self : Self) -> Int64
}
impl BigLen for String {
  fn length(self : String) -> Int64 { 4294967296L }
}

trait IntTrim {
  fn trim(self : Self) -> Int
}
impl IntTrim for String {
  fn trim(self : String) -> Int { 7 }
}

trait PassthruSlice {
  fn slice(self : Self, a : Int, b : Int) -> Bytes
}
impl PassthruSlice for Bytes {
  fn slice(self : Bytes, _a : Int, _b : Int) -> Bytes { self }
}

trait NegLen {
  fn length(self : Self) -> Int
}
impl NegLen for String {
  fn length(self : String) -> Int { -3 }
}

struct Holder { mut n : Int }
trait BumpMin {
  fn min(self : Self, h : Holder) -> Int
}
impl BumpMin for Int {
  fn min(self : Int, h : Holder) -> Int {
    h.n = h.n + 1
    self
  }
}

fn make() -> String { "hi" }

fn call_left(d : dyn left::A) -> Int { d.score() }
fn call_right(d : dyn right::A) -> Int { d.score() }
fn via_left[T : left::A](x : T) -> Int { x.score() }
fn via_right[T : right::A](x : T) -> Int { x.score() }
fn via_len[T : CustomLen](s : T) -> Int { s.length() }
fn via_slice_str[T : CustomSlice](x : T) -> String { x.slice(0, 1).to_string() }
fn via_sb_show[T : CustomShow](x : T) -> String {
  let sb = StringBuilder()
  sb.write_string(x.to_string())
  sb.to_string()
}
fn via_pick[T : Pick](x : T) -> Int {
  match x.pick() {
    Some(v) => v
    None => -1
  }
}
fn via_sb_biglen[T : BigLen](x : T) -> String {
  let sb = StringBuilder()
  sb.write_string(x.length().to_string())
  sb.to_string()
}
fn via_trim_add[T : IntTrim](x : T) -> Int {
  x.trim() + 1 + 2
}
fn via_ro_slice[T : PassthruSlice](x : T) -> Bytes {
  let b = x.slice(0, 1)
  b[0] = 65 as Byte
  b
}
fn via_neg_len_div[T : NegLen](x : T) -> Int {
  let a = x.length() / 2
  let n = x.length()
  let b = n / 2
  a * 10 + b
}
fn via_trait_min[T : BumpMin](x : T, h : Holder) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < 2 {
    let _ = x.min(h)
    acc = acc + h.n
    i = i + 1
  }
  acc
}

pub fn main(w : World) -> Int {
  let d1 : dyn left::A = B::{ x: 0 }
  let d2 : dyn right::A = B::{ x: 0 }
  let inh_pick = match (B::{ x: 0 }).pick() {
    Some(v) => v
    None => -1
  }
  let mb = via_ro_slice("xy".to_bytes())
  let inh_trim = B::{ x: 0 }.trim() + 1 + 2
  let res = "J3_XR8_2:" +
    B::{ x: 0 }.score().to_string() + "," +
    call_left(d1).to_string() + "," +
    call_right(d2).to_string() + "," +
    via_left(B::{ x: 0 }).to_string() + "," +
    via_right(B::{ x: 0 }).to_string() + "," +
    "abc".length().to_string() + "," +
    via_len("abc").to_string() + "," +
    "ab".to_bytes().slice(0, 1).to_string() + "," +
    via_slice_str("ab".to_bytes()) + "," +
    (42).to_string() + "," +
    via_sb_show(42) + "," +
    inh_pick.to_string() + "," +
    via_pick(B::{ x: 0 }).to_string() + "," +
    via_sb_biglen("hi") + "," +
    via_trim_add("hi").to_string() + "," +
    inh_trim.to_string() + "," +
    mb.to_string() + "," +
    via_neg_len_div("hi").to_string() + "," +
    p::via_make_div(0).to_string() + "," +
    via_trait_min(7, Holder::{ n: 0 }).to_string() + "," +
    make().length().to_string() + "," +
    p::A_m_B::tag().to_string() + "," +
    p_m_A::B::tag().to_string()
  io_println(w, res)
  0
}
EOF
for ORD in 1 2; do
  EXP_XR8="J3_XR8_${ORD}:33,11,22,11,22,3,77,a,Z,42,CUSTOM_INT,33,11,4294967296,10,10,Ay,-11,-1,3,2,11,22"
  "$PIONC" build -o "$TMP_DIR/xr8_app${ORD}_bin" "$TMP_DIR/xr8/app${ORD}"
  XR8_NAT="$("$TMP_DIR/xr8_app${ORD}_bin")"
  [ "$XR8_NAT" = "$EXP_XR8" ] || { echo "FAIL: xr8_${ORD} native dev: $XR8_NAT (want $EXP_XR8)" >&2; exit 1; }
  "$PIONC" build --release -o "$TMP_DIR/xr8_app${ORD}_rel_bin" "$TMP_DIR/xr8/app${ORD}"
  XR8_NAT_REL="$("$TMP_DIR/xr8_app${ORD}_rel_bin")"
  [ "$XR8_NAT_REL" = "$EXP_XR8" ] || { echo "FAIL: xr8_${ORD} native release: $XR8_NAT_REL (want $EXP_XR8)" >&2; exit 1; }
  "$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xr8_app${ORD}.ssa" -o "$TMP_DIR/xr8_app${ORD}.wasm" "$TMP_DIR/xr8/app${ORD}"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/xr8_app${ORD}_rel.wasm" "$TMP_DIR/xr8/app${ORD}"
  grep -Eq 'function w \$[^ ]*pion_pkg_app_impl_0_0P(13_left|25_left_u_u[0-9a-f]{8})_x3a_x3aA_N1_B_M5_score\(' "$TMP_DIR/xr8_app${ORD}.ssa" || { echo "FAIL: missing left::A impl def in xr8_${ORD}" >&2; grep 'impl_0_' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'function w \$[^ ]*pion_pkg_app_impl_0_0P(14_right|26_right_u_u[0-9a-f]{8})_x3a_x3aA_N1_B_M5_score\(' "$TMP_DIR/xr8_app${ORD}.ssa" || { echo "FAIL: missing right::A impl def in xr8_${ORD}" >&2; grep 'impl_0_' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  awk '/via_left__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -Eq 'pion_pkg_app_impl_0_0P(13_left|25_left_u_u[0-9a-f]{8})_x3a_x3aA_N1_B_M5_score\(' || { echo "FAIL: via_left mono did not call left::A impl in xr8_${ORD}" >&2; awk '/via_left__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  awk '/via_right__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -Eq 'pion_pkg_app_impl_0_0P(14_right|26_right_u_u[0-9a-f]{8})_x3a_x3aA_N1_B_M5_score\(' || { echo "FAIL: via_right mono did not call right::A impl in xr8_${ORD}" >&2; awk '/via_right__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  if awk '/^(export )?function .*via_trim_add__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -q 'pion_str_concat'; then
    echo "FAIL: via_trim_add mono miscompiled as string concat in xr8_${ORD}" >&2
    awk '/^(export )?function .*via_trim_add__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true
    exit 1
  fi
  awk '/^(export )?function .*via_ro_slice__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | awk '/^@bytes_ro/{f=1; next} /^@|^}/{f=0} f' | grep -q 'call \$pion_panic(' || { echo "FAIL: via_ro_slice mono missing @bytes_ro -> call \$pion_panic( in xr8_${ORD}" >&2; awk '/^(export )?function .*via_ro_slice__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  [ "$(awk '/^(export )?function .*via_neg_len_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -c '=w shr .*, 31$')" -ge 2 ] || { echo "FAIL: via_neg_len_div mono missing signed shr 31 bias in xr8_${ORD}" >&2; awk '/^(export )?function .*via_neg_len_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  if awk '/^(export )?function .*via_neg_len_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -q '=w shr .*, 1$'; then
    echo "FAIL: via_neg_len_div mono unexpectedly used unsigned shr 1 in xr8_${ORD}" >&2
    awk '/^(export )?function .*via_neg_len_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true
    exit 1
  fi
  awk '/^(export )?function .*via_make_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | grep -q '=w shr .*, 31$' || { echo "FAIL: via_make_div mono missing signed shr 31 bias in xr8_${ORD}" >&2; awk '/^(export )?function .*via_make_div__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  awk '/^(export )?function .*via_trait_min__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | awk '/^@wh_b_/{f=1; next} /^@|^}/{f=0} f' | grep -q 'call \$[^ ]*BumpMin.*min(' || { echo "FAIL: via_trait_min mono loop body missing BumpMin::min call in xr8_${ORD}" >&2; awk '/^(export )?function .*via_trait_min__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  awk '/^(export )?function .*via_trait_min__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" | awk '/^@wh_b_/{f=1; next} /^@|^}/{f=0} f' | awk '/call \$[^ ]*BumpMin.*min\(/{seen=1; next} seen && /loadsw/{ok=1} END{exit(ok?0:1)}' || { echo "FAIL: via_trait_min mono hoisted h.n load out of loop in xr8_${ORD}" >&2; awk '/^(export )?function .*via_trait_min__mono_/,/^}/' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'function w \$[^ ]*pion_pkg_(p|0L13_p_u_u[0-9a-f]{8})_m_A_m_B__tag\(' "$TMP_DIR/xr8_app${ORD}.ssa" || { echo "FAIL: missing p::A_m_B::tag def in xr8_${ORD}" >&2; grep '_tag(' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  grep -Eq 'function w \$[^ ]*pion_pkg_0L(7_p_um_uA|19_p_um_uA_u_u[0-9a-f]{8})_m_B__tag\(' "$TMP_DIR/xr8_app${ORD}.ssa" || { echo "FAIL: missing p_m_A::B::tag def in xr8_${ORD}" >&2; grep '_tag(' "$TMP_DIR/xr8_app${ORD}.ssa" >&2 || true; exit 1; }
  if command -v node >/dev/null 2>&1; then
    XR8_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr8_app${ORD}.wasm")"
    [ "$XR8_WASM" = "$EXP_XR8" ] || { echo "FAIL: xr8_${ORD} wasm32 dev: $XR8_WASM (want $EXP_XR8)" >&2; exit 1; }
    XR8_WASM_REL="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr8_app${ORD}_rel.wasm")"
    [ "$XR8_WASM_REL" = "$EXP_XR8" ] || { echo "FAIL: xr8_${ORD} wasm32 release: $XR8_WASM_REL (want $EXP_XR8)" >&2; exit 1; }
  fi
done
echo "PASS: J3 R8-R14 cross-pkg impl_method_sym, trait-bound dispatch priority, fusion/scalarization & probe/readonly guards (dev+release, both orders, Native + Wasm32 + SSA)"

# =====================================================================
# Part 4g: R15 cross-pkg mono alias-conflict & unqualified-call isolation
# =====================================================================
mkdir -p "$TMP_DIR/xr9/left/src" "$TMP_DIR/xr9/right/src" "$TMP_DIR/xr9/decoy/src" "$TMP_DIR/xr9/decoy2/src" "$TMP_DIR/xr9/modx/src" "$TMP_DIR/xr9/Tag/src" "$TMP_DIR/xr9/q/src" "$TMP_DIR/xr9/p/src" "$TMP_DIR/xr9/app/src"
cat > "$TMP_DIR/xr9/left/pion.toml" <<'EOF'
[package]
name = "left"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/left/src/lib.pion" <<'EOF'
pub fn make() -> String {
  let mut s = ""
  let mut i = 0
  while i < 6 {
    s = s + "a"
    i = i + 1
  }
  s
}
pub fn pick() -> Option[Int] { Some(6) }
EOF
cat > "$TMP_DIR/xr9/right/pion.toml" <<'EOF'
[package]
name = "right"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/right/src/lib.pion" <<'EOF'
pub fn make() -> String {
  let mut s = ""
  let mut i = 0
  while i < 2 {
    s = s + "x"
    i = i + 1
  }
  s
}
pub fn pick() -> Option[Int] { Some(2) }
EOF
cat > "$TMP_DIR/xr9/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/decoy/src/lib.pion" <<'EOF'
pub fn make() -> String {
  let mut s = ""
  let mut i = 0
  while i < 2 {
    s = s + "y"
    i = i + 1
  }
  s
}
pub fn seed() -> Int { 99 }
pub fn Some(_n : Int) -> Option[Int] { Option::Some(99) }
pub let None : Option[Int] = Option::Some(88)
EOF
cat > "$TMP_DIR/xr9/decoy2/pion.toml" <<'EOF'
[package]
name = "decoy2"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/decoy2/src/lib.pion" <<'EOF'
pub fn One(_n : Int) -> Int { 99 }
pub let Zero : Int = 88
pub fn shared() -> Int { 29 }
EOF
cat > "$TMP_DIR/xr9/modx/pion.toml" <<'EOF'
[package]
name = "modx"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/modx/src/lib.pion" <<'EOF'
pub fn Make(v : Int) -> Int {
  let mut acc = 3
  let mut i = 0
  while i < 10 {
    acc = acc + v
    i = i + 1
  }
  acc
}
EOF
cat > "$TMP_DIR/xr9/p/pion.toml" <<'EOF'
[package]
name = "p"
version = "0.1.0"

[dependencies]
left = { path = "../left" }
modx = { path = "../modx" }
decoy = { path = "../decoy" }
decoy2 = { path = "../decoy2" }
EOF
cat > "$TMP_DIR/xr9/p/src/lib.pion" <<'EOF'
import "left" as x
import "modx" as X
import "decoy" as Option
import "decoy2" as Tag

pub enum Tag {
  One(Int)
  Zero
}

pub fn take_opt(v~ : Option[Int] = Option::Some(7)) -> Int {
  match v {
    Some(n) => n
    None => 0
  }
}

pub fn take_none(v~ : Option[Int] = Option::None) -> Int {
  match v {
    Some(n) => n
    None => 0
  }
}

pub fn take_tag(t~ : Tag = Tag::One(5)) -> Int {
  match t {
    Tag::One(n) => n
    Tag::Zero => 11
  }
}

pub fn take_tag_zero(t~ : Tag = Tag::Zero) -> Int {
  match t {
    Tag::One(n) => n
    Tag::Zero => 11
  }
}

pub fn Tag::seed() -> Int { 17 }
pub fn Tag::shared() -> Int { 31 }
pub fn local_seed() -> Int { Tag::seed() }
pub fn take_seed(n~ : Int = Tag::seed()) -> Int { n }
pub fn local_shared() -> Int { Tag::shared() }
pub fn take_shared(n~ : Int = Tag::shared()) -> Int { n }
pub fn take_seed_fn(f~ : () -> Int = Tag::seed) -> Int { f() }
pub fn local_shared_fn() -> Int {
  let f : () -> Int = Tag::shared
  f()
}
pub fn take_shared_fn(f~ : () -> Int = Tag::shared) -> Int { f() }
pub fn local_shared_fn_mono[T : ForceMono](t : T) -> Int {
  let f : () -> Int = Tag::shared
  f() + t.tag()
}
pub fn local_seed_fn_mono[T : ForceMono](t : T) -> Int {
  let f : () -> Int = Tag::seed
  f() + t.tag()
}

fn make() -> String {
  let mut s = ""
  let mut i = 0
  while i < 6 {
    s = s + "p"
    i = i + 1
  }
  s
}

fn seed() -> Int { 7 }
fn take(n~ : Int = seed()) -> Int { n }

pub trait ForceMono {
  fn tag(self : Self) -> Int
}
impl ForceMono for Int {
  fn tag(self : Int) -> Int { 0 }
}

pub fn via_alias_div[T : ForceMono](t : T) -> Int {
  x::make().length() / 2 + t.tag()
}

pub fn via_self_div[T : ForceMono](t : T) -> Int {
  make().length() / 2 + t.tag()
}

pub fn via_def[T : ForceMono](t : T) -> Int {
  take() + t.tag()
}

pub fn via_pick_opt[T : ForceMono](t : T) -> Int {
  let base = match x::pick() {
    Some(v) => v
    None => -1
  }
  base + t.tag()
}

pub fn via_enum_clash[T : ForceMono](t : T) -> Int {
  X::Make(7) + t.tag()
}
EOF
cat > "$TMP_DIR/xr9/Tag/pion.toml" <<'EOF'
[package]
name = "Tag"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xr9/Tag/src/lib.pion" <<'EOF'
pub fn shared() -> Int { 29 }
EOF
cat > "$TMP_DIR/xr9/q/pion.toml" <<'EOF'
[package]
name = "q"
version = "0.1.0"

[dependencies]
Tag = { path = "../Tag" }
EOF
cat > "$TMP_DIR/xr9/q/src/lib.pion" <<'EOF'
import "Tag" as other

pub enum Tag {
  Zero
}

pub fn Tag::shared() -> Int { 31 }

pub trait QMono {
  fn tag(self : Self) -> Int
}
impl QMono for Int {
  fn tag(self : Int) -> Int { 0 }
}

pub fn local_tag_fn() -> Int {
  let f : () -> Int = Tag::shared
  f()
}
pub fn local_other_fn() -> Int {
  let g : () -> Int = other::shared
  g()
}
pub fn mono_tag_fn[T : QMono](t : T) -> Int {
  let f : () -> Int = Tag::shared
  f() + t.tag()
}
pub fn mono_other_fn[T : QMono](t : T) -> Int {
  let g : () -> Int = other::shared
  g() + t.tag()
}
pub fn take_tag_fn(f~ : () -> Int = Tag::shared) -> Int { f() }
pub fn take_other_fn(g~ : () -> Int = other::shared) -> Int { g() }
EOF
cat > "$TMP_DIR/xr9/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
p = { path = "../p" }
q = { path = "../q" }
right = { path = "../right" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/xr9/app/src/main.pion" <<'EOF'
import "p" as lib
import "q"
import "right" as x
import "decoy" as p

enum X {
  Make(Int)
}

pub fn main(w : World) -> Int {
  let r1 = lib::via_alias_div(0)
  let r2 = lib::via_self_div(0)
  let r3 = x::make().length() / 2
  let r4 = p::make().length() / 2
  let r5 = lib::via_def(0)
  let r6 = lib::via_pick_opt(0)
  let r7 = lib::via_enum_clash(0)
  let e = X::Make(5)
  let r8 = match e {
    X::Make(v) => v
  }
  let r9 = lib::take_opt()
  let r10 = lib::take_opt(v=Option::Some(7))
  let r11 = lib::take_none()
  let r12 = lib::take_none(v=Option::None)
  let r13 = lib::take_tag()
  let r14 = lib::take_tag_zero()
  let r15 = lib::local_seed()
  let r16 = lib::take_seed()
  let r17 = lib::local_shared()
  let r18 = lib::take_shared()
  let r19 = lib::take_seed_fn()
  let r20 = lib::local_shared_fn()
  let r21 = lib::take_shared_fn()
  let r22 = lib::local_shared_fn_mono(0)
  let r23 = lib::local_seed_fn_mono(0)
  let r24 = q::local_tag_fn()
  let r25 = q::local_other_fn()
  let r26 = q::mono_tag_fn(0)
  let r27 = q::mono_other_fn(0)
  let r28 = q::take_tag_fn()
  let r29 = q::take_other_fn()
  io_println(
    w,
    "J3_XR9:" +
    r1.to_string() + "," +
    r2.to_string() + "," +
    r3.to_string() + "," +
    r4.to_string() + "," +
    r5.to_string() + "," +
    r6.to_string() + "," +
    r7.to_string() + "," +
    r8.to_string() + "," +
    r9.to_string() + "," +
    r10.to_string() + "," +
    r11.to_string() + "," +
    r12.to_string() + "," +
    r13.to_string() + "," +
    r14.to_string() + "," +
    r15.to_string() + "," +
    r16.to_string() + "," +
    r17.to_string() + "," +
    r18.to_string() + "," +
    r19.to_string() + "," +
    r20.to_string() + "," +
    r21.to_string() + "," +
    r22.to_string() + "," +
    r23.to_string() + "," +
    r24.to_string() + "," +
    r25.to_string() + "," +
    r26.to_string() + "," +
    r27.to_string() + "," +
    r28.to_string() + "," +
    r29.to_string(),
  )
  0
}
EOF
EXP_XR9="J3_XR9:3,3,1,1,7,6,73,5,7,7,0,0,5,11,17,17,29,29,17,29,29,29,17,31,29,31,29,31,29"
"$PIONC" build -o "$TMP_DIR/xr9_app_bin" "$TMP_DIR/xr9/app"
XR9_NAT="$("$TMP_DIR/xr9_app_bin")"
[ "$XR9_NAT" = "$EXP_XR9" ] || { echo "FAIL: xr9 native dev: $XR9_NAT (want $EXP_XR9)" >&2; exit 1; }
"$PIONC" build --release -o "$TMP_DIR/xr9_app_rel_bin" "$TMP_DIR/xr9/app"
XR9_NAT_REL="$("$TMP_DIR/xr9_app_rel_bin")"
[ "$XR9_NAT_REL" = "$EXP_XR9" ] || { echo "FAIL: xr9 native release: $XR9_NAT_REL (want $EXP_XR9)" >&2; exit 1; }
"$PIONC" build --target wasm32 --emit-ssa "$TMP_DIR/xr9_app.ssa" -o "$TMP_DIR/xr9_app.wasm" "$TMP_DIR/xr9/app"
"$PIONC" build --release --target wasm32 --emit-ssa "$TMP_DIR/xr9_app_rel.ssa" -o "$TMP_DIR/xr9_app_rel.wasm" "$TMP_DIR/xr9/app"
awk '/^(export )?function .*via_alias_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" | grep -Eq 'call \$[^ ]*pion_pkg_(left|0L16_left_u_u[0-9a-f]{8})_fn_make\(' || { echo "FAIL: via_alias_div mono did not call left::make" >&2; awk '/^(export )?function .*via_alias_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" >&2 || true; exit 1; }
if awk '/^(export )?function .*via_alias_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" | grep -Eq 'call \$[^ ]*right.*make\('; then
  echo "FAIL: via_alias_div mono hijacked by caller alias right::make" >&2
  awk '/^(export )?function .*via_alias_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" >&2 || true
  exit 1
fi
awk '/^(export )?function .*via_self_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" | grep -Eq 'call \$[^ ]*pion_pkg_(p|0L13_p_u_u[0-9a-f]{8})_fn_make' || { echo "FAIL: via_self_div mono did not call p::make" >&2; awk '/^(export )?function .*via_self_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" >&2 || true; exit 1; }
if awk '/^(export )?function .*via_self_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" | grep -Eq 'call \$[^ ]*decoy.*make'; then
  echo "FAIL: via_self_div mono hijacked by caller alias p->decoy::make" >&2
  awk '/^(export )?function .*via_self_div__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" >&2 || true
  exit 1
fi
awk '/^(export )?function .*via_enum_clash__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" | grep -Eq 'call \$[^ ]*pion_pkg_(modx|0L16_modx_u_u[0-9a-f]{8})_fn_Make\(' || { echo "FAIL: via_enum_clash mono did not call modx::Make" >&2; awk '/^(export )?function .*via_enum_clash__mono_/,/^}/' "$TMP_DIR/xr9_app.ssa" >&2 || true; exit 1; }
VIA_PICK_BODY="$(awk '/^(export )?function .*via_pick_opt__mono_/,/^}/' "$TMP_DIR/xr9_app_rel.ssa")"
[ -n "$VIA_PICK_BODY" ] || { echo "FAIL: via_pick_opt mono missing from xr9_app_rel.ssa" >&2; exit 1; }
if printf '%s\n' "$VIA_PICK_BODY" | grep -Eq 'call \$[^ ]*pick\(|pion_alloc'; then
  echo "FAIL: via_pick_opt mono in release mode missed scalarization" >&2
  printf '%s\n' "$VIA_PICK_BODY" >&2
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  XR9_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr9_app.wasm")"
  [ "$XR9_WASM" = "$EXP_XR9" ] || { echo "FAIL: xr9 wasm32 dev: $XR9_WASM (want $EXP_XR9)" >&2; exit 1; }
  XR9_WASM_REL="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xr9_app_rel.wasm")"
  [ "$XR9_WASM_REL" = "$EXP_XR9" ] || { echo "FAIL: xr9 wasm32 release: $XR9_WASM_REL (want $EXP_XR9)" >&2; exit 1; }
fi
echo "PASS: J3 R15-R20 cross-pkg mono alias-conflict, strict lexical alias lookup, canonical default-arg priority, value-pos EPath order, scalarization & enum-clash isolation (dev+release, Native + Wasm32 + SSA)"

# =====================================================================
# Part 5: extract-lean CLI smoke test
# =====================================================================
mkdir -p "$TMP_DIR/lean_pkg/src" "$TMP_DIR/lean_out"
cat > "$TMP_DIR/lean_pkg/pion.toml" <<'EOF'
[package]
name = "imm_lean"
version = "0.1.0"
EOF
cat > "$TMP_DIR/lean_pkg/src/lib.pion" <<'EOF'
#verify
pub fn sum_imm(xs : ImmArray[Int]) -> Int {
  let mut s = 0
  for v in xs {
    s = s + v
  }
  s
}
EOF
LEAN_JSON="$("$PIONC" extract-lean --json --out "$TMP_DIR/lean_out" "$TMP_DIR/lean_pkg")"
echo "$LEAN_JSON" | grep -q '"ok":true' || { echo "FAIL: extract-lean: $LEAN_JSON" >&2; exit 1; }
grep -q "Pion.ImmArray" "$TMP_DIR/lean_out/ImmLean/Funs.lean" || { echo "FAIL: missing Pion.ImmArray in Funs.lean" >&2; exit 1; }
echo "PASS: J3 extract-lean CLI"

echo "=== ALL J3 ImmArray E2E CHECKS PASSED ==="
