#!/usr/bin/env sh
# Wave J1 Soundness & Robustness E2E Gate:
#   1. 2,500-term `&&` with `is`-bindings + observable RHS side-effect short-circuit (Native + Wasm32)
#   2. Dual-file cold/hot CAS top-level const init:
#      - default-arg expression (`let A = get()`, `fn get(x = B)`)
#      - named top-level closure body (`let A = F()`, `let F = fn() { B }`)
#      - `#fcallp`: `ignore_cb(read_A)` (no false cycle) & `apply(fn() { B })` (B before A)
#      - builtin `.length()` vs unrelated `X::length` (no false cycle)
#      - `x is Some(v) && v > 0` (no false cycle) vs reading top-level `v` (`E_CONST_CYCLE`)
#   3. Cross-package monomorphized generic calling library top-level closure const (Native + Wasm32)
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
PIONC="${1:-$ROOT_DIR/out/pionc2}"
case "$PIONC" in
  /*) ;;
  *) PIONC="$PWD/$PIONC" ;;
esac
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion_wave_j1_e2e.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
export PION_RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"

run_wasm() {
  wasm_path="$1"
  expected_rc="$2"
  node -e '
import(process.argv[1]).then(async ({ runWasmBytes }) => {
  const fs = await import("fs");
  const bytes = fs.readFileSync(process.argv[2]);
  const { exitCode } = await runWasmBytes(bytes);
  if (exitCode !== Number(process.argv[3])) {
    console.error("wasm exitCode mismatch: got " + exitCode + ", expected " + process.argv[3]);
    process.exit(1);
  }
});
' "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs" "$wasm_path" "$expected_rc"
}

echo "=== Wave J1 E2E [1/3]: 2,500-term && with is-bindings + short-circuit (Native + Wasm32) ==="
mkdir -p "$TMP_DIR/and_sc" "$TMP_DIR/cas_and"
python3 - "$TMP_DIR/and_sc/main.pion" <<'PY'
import sys
lines = [
    "fn bump(cnt : Array[Int], res : Bool) -> Bool {",
    "  cnt[0] = cnt[0] + 1",
    "  res",
    "}",
    "pub fn run_case(x : Option[Int], mid_stop : Bool) -> Int {",
    "  let cnt : Array[Int] = [0]",
    "  if x is Some(v0)"
    + "".join(" && (v0 >= 0)" for _ in range(1250))
    + " && !mid_stop"
    + "".join(" && (v0 >= 0)" for _ in range(1250))
    + " && bump(cnt, true) {",
    "    v0 + cnt[0] * 10",
    "  } else {",
    "    cnt[0]",
    "  }",
    "}",
    "pub fn main() -> Int {",
    "  let r1 = run_case(Some(5), true)",   # mid-chain fail -> bump skipped -> 0
    "  let r2 = run_case(None, false)",     # initial is fail -> bump skipped -> 0
    "  let r3 = run_case(Some(5), false)",  # all true -> bump runs once -> 15
    "  r1 * 100 + r2 * 10 + r3",
    "}",
]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
PION_CACHE_DIR="$TMP_DIR/cas_and" "$PIONC" build -o "$TMP_DIR/and_nat" "$TMP_DIR/and_sc/main.pion"
set +e; "$TMP_DIR/and_nat"; rc_nat=$?; set -e
test "$rc_nat" -eq 15
echo "  native 2500-term &&+is short-circuit: exit=$rc_nat (OK)"
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$TMP_DIR/cas_and" "$PIONC" build --target wasm32 -o "$TMP_DIR/and_sc.wasm" "$TMP_DIR/and_sc/main.pion"
  run_wasm "$TMP_DIR/and_sc.wasm" 15
  echo "  wasm32 2500-term &&+is short-circuit: exit=15 (OK)"
fi

echo "=== Wave J1 E2E [2/3]: Dual-file cold/hot CAS top-level const init ==="
# (2a) Default-arg cold + hot CAS rebuild
mkdir -p "$TMP_DIR/def" "$TMP_DIR/cas_def"
cat > "$TMP_DIR/def/a.pion" <<'EOF'
let A : Int = get()
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/def/b.pion" <<'EOF'
fn get(x : Int = B) -> Int { x }
let B : Int = 41
EOF
PION_CACHE_DIR="$TMP_DIR/cas_def" "$PIONC" build -o "$TMP_DIR/def_cold" "$TMP_DIR/def/a.pion" "$TMP_DIR/def/b.pion"
set +e; "$TMP_DIR/def_cold"; rc=$?; set -e
test "$rc" -eq 41
cat > "$TMP_DIR/def/b.pion" <<'EOF'
fn get(x : Int = B) -> Int { x }
let B : Int = 42
EOF
PION_CACHE_DIR="$TMP_DIR/cas_def" "$PIONC" build -o "$TMP_DIR/def_hot" "$TMP_DIR/def/a.pion" "$TMP_DIR/def/b.pion"
set +e; "$TMP_DIR/def_hot"; rc=$?; set -e
test "$rc" -eq 42
echo "  default-arg cold/hot CAS: 41 -> 42 (OK)"

# (2b) Named top-level closure body reading B
mkdir -p "$TMP_DIR/clo" "$TMP_DIR/cas_clo"
cat > "$TMP_DIR/clo/a.pion" <<'EOF'
let A : String = F()
pub fn main(world : World) -> Int {
  io_println(world, A)
  0
}
EOF
cat > "$TMP_DIR/clo/b.pion" <<'EOF'
let F : () -> String = fn() -> String { B }
let B : String = "ok"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_clo" "$PIONC" build -o "$TMP_DIR/clo_bin" "$TMP_DIR/clo/a.pion" "$TMP_DIR/clo/b.pion"
out_clo=$("$TMP_DIR/clo_bin")
test "$out_clo" = "ok"
echo "  named top-level closure body: out=$out_clo (OK)"

# (2c) #fcallp: ignore_cb(read_A) (no false cycle) & apply(fn() -> Int { B }) (B before A, cold + hot)
mkdir -p "$TMP_DIR/cb" "$TMP_DIR/cas_cb"
cat > "$TMP_DIR/cb/a.pion" <<'EOF'
fn read_a() -> Int { A }
let A : Int = ignore_cb(read_a) + apply(fn() -> Int { B })
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/cb/b.pion" <<'EOF'
fn ignore_cb(_f : () -> Int) -> Int { 10 }
fn apply(f : () -> Int) -> Int { f() }
let B : Int = 23
EOF
PION_CACHE_DIR="$TMP_DIR/cas_cb" "$PIONC" build -o "$TMP_DIR/cb_cold" "$TMP_DIR/cb/a.pion" "$TMP_DIR/cb/b.pion"
set +e; "$TMP_DIR/cb_cold"; rc=$?; set -e
test "$rc" -eq 33
cat > "$TMP_DIR/cb/b.pion" <<'EOF'
fn ignore_cb(_f : () -> Int) -> Int { 10 }
fn apply(f : () -> Int) -> Int { f() }
let B : Int = 25
EOF
PION_CACHE_DIR="$TMP_DIR/cas_cb" "$PIONC" build -o "$TMP_DIR/cb_hot" "$TMP_DIR/cb/a.pion" "$TMP_DIR/cb/b.pion"
set +e; "$TMP_DIR/cb_hot"; rc=$?; set -e
test "$rc" -eq 35
echo "  #fcallp ignore_cb + apply(fn(){B}) cold/hot CAS: 33 -> 35 (OK)"

# (2d) Builtin .length() vs unrelated X::length + `x is Some(v) && v > 0` (no false cycle)
mkdir -p "$TMP_DIR/bi" "$TMP_DIR/cas_bi"
cat > "$TMP_DIR/bi/a.pion" <<'EOF'
struct X { n : Int }
let A : Int = [1, 2, 3].length()
let v : Int = check_opt(Some(9))
pub fn main() -> Int { A + v }
EOF
cat > "$TMP_DIR/bi/b.pion" <<'EOF'
fn X::length(self : X) -> Int { A + self.n }
fn check_opt(x : Option[Int]) -> Int {
  if x is Some(v) && v > 0 { v } else { 0 }
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_bi" "$PIONC" build -o "$TMP_DIR/bi_bin" "$TMP_DIR/bi/a.pion" "$TMP_DIR/bi/b.pion"
set +e; "$TMP_DIR/bi_bin"; rc=$?; set -e
test "$rc" -eq 12
echo "  builtin .length() + is-bound && v > 0: exit=$rc (OK)"

# (2e) `#fcallp` param escape (keep/wrap/apply_alias), top-level closure const `apply_clo`,
#      lexical bound shadowing in callback closure, and non-fn `mk()()` check --json
mkdir -p "$TMP_DIR/fcallp_esc" "$TMP_DIR/cas_esc" "$TMP_DIR/fcallp_shad" "$TMP_DIR/cas_shad" "$TMP_DIR/nonfn_call"
cat > "$TMP_DIR/fcallp_esc/a.pion" <<'EOF'
let A : String = keep(read_b)() + wrap(read_b)() + apply_alias(fn() -> String { B }) + apply_clo(fn() -> String { B })
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/fcallp_esc/b.pion" <<'EOF'
fn keep(f : () -> String) -> () -> String { f }
fn wrap(f : () -> String) -> () -> String { fn() -> String { f() } }
fn apply_alias(f : () -> String) -> String { let g = f; g() }
let apply_clo : (() -> String) -> String = fn(f : () -> String) -> String { f() }
fn read_b() -> String { B }
let B : String = "ok"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_esc" "$PIONC" build -o "$TMP_DIR/esc_cold" "$TMP_DIR/fcallp_esc/a.pion" "$TMP_DIR/fcallp_esc/b.pion"
out_esc1=$("$TMP_DIR/esc_cold")
test "$out_esc1" = "okokokok"
cat > "$TMP_DIR/fcallp_esc/b.pion" <<'EOF'
fn keep(f : () -> String) -> () -> String { f }
fn wrap(f : () -> String) -> () -> String { fn() -> String { f() } }
fn apply_alias(f : () -> String) -> String { let g = f; g() }
let apply_clo : (() -> String) -> String = fn(f : () -> String) -> String { f() }
fn read_b() -> String { B }
let B : String = "hi"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_esc" "$PIONC" build -o "$TMP_DIR/esc_hot" "$TMP_DIR/fcallp_esc/a.pion" "$TMP_DIR/fcallp_esc/b.pion"
out_esc2=$("$TMP_DIR/esc_hot")
test "$out_esc2" = "hihihihi"
echo "  #fcallp escape (keep/wrap/alias/apply_clo) cold/hot CAS: $out_esc1 -> $out_esc2 (OK)"

cat > "$TMP_DIR/fcallp_shad/a.pion" <<'EOF'
let A : Int = helper()
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/fcallp_shad/b.pion" <<'EOF'
fn apply(f : () -> Int) -> Int { f() }
fn helper() -> Int { let A = 7; apply(fn() -> Int { A }) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_shad" "$PIONC" build -o "$TMP_DIR/shad_bin" "$TMP_DIR/fcallp_shad/a.pion" "$TMP_DIR/fcallp_shad/b.pion"
set +e; "$TMP_DIR/shad_bin"; rc=$?; set -e
test "$rc" -eq 7
echo "  #fcallp lexical bound shadowing in callback closure: exit=$rc (OK)"

cat > "$TMP_DIR/nonfn_call/main.pion" <<'EOF'
fn mk() -> Int { 1 }
pub fn f() -> Int { mk()() }
EOF
set +e
nonfn_out=$("$PIONC" check --json "$TMP_DIR/nonfn_call/main.pion" 2>&1)
nonfn_rc=$?
set -e
test "$nonfn_rc" -ne 0
printf '%s' "$nonfn_out" | grep -q "E_TYPE_MISMATCH"
echo "  non-function mk()() check --json: rc=$nonfn_rc E_TYPE_MISMATCH (OK)"

echo "=== Wave J1 E2E [3/3]: Cross-package monomorphized generic calling library closure const (Native + Wasm32) ==="
mkdir -p "$TMP_DIR/xpkg/lib/src" "$TMP_DIR/xpkg/app/src" "$TMP_DIR/cas_xpkg"
cat > "$TMP_DIR/xpkg/lib/pion.toml" <<'EOF'
[package]
name = "mlib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xpkg/lib/src/lib.pion" <<'EOF'
pub trait Tag {
  tag(self : Self) -> Int
}
let helper : (Int) -> Int = fn(n : Int) -> Int { n + 20 }
pub fn run_gen[T : Tag](x : T) -> Int {
  helper(x.tag())
}
EOF
cat > "$TMP_DIR/xpkg/app/pion.toml" <<'EOF'
[package]
name = "mapp"
version = "0.1.0"

[dependencies]
mlib = { path = "../lib" }
EOF
cat > "$TMP_DIR/xpkg/app/src/main.pion" <<'EOF'
import "mlib"
struct Item { v : Int }
impl mlib::Tag for Item {
  fn tag(self : Item) -> Int { self.v }
}
fn helper(n : Int) -> Int { n + 100 }
pub fn main() -> Int {
  let _ = helper(0)
  mlib::run_gen(Item::{ v: 5 })
}
EOF
(cd "$TMP_DIR/xpkg/app" && PION_CACHE_DIR="$TMP_DIR/cas_xpkg" "$PIONC" build -o "$TMP_DIR/xpkg_nat")
set +e; "$TMP_DIR/xpkg_nat"; rc=$?; set -e
test "$rc" -eq 25
echo "  xpkg mono library closure const native: exit=$rc (OK)"
if command -v node >/dev/null 2>&1; then
  (cd "$TMP_DIR/xpkg/app" && PION_CACHE_DIR="$TMP_DIR/cas_xpkg" "$PIONC" build --target wasm32 -o "$TMP_DIR/xpkg.wasm")
  run_wasm "$TMP_DIR/xpkg.wasm" 25
  echo "  xpkg mono library closure const wasm32: exit=25 (OK)"
fi

echo "=== Wave J1 E2E [4/4]: Bool scalar casts (Native+Wasm32) & cross-pkg/indirect/alias #fcallp ==="
# 4a. Bool scalar casts: true/false as Double, Float, Int64 (Native + Wasm32)
mkdir -p "$TMP_DIR/bcast" "$TMP_DIR/cas_bcast"
cat > "$TMP_DIR/bcast/main.pion" <<'EOF'
pub fn main() -> Int {
  let d1 : Double = true as Double
  let d0 : Double = false as Double
  let f1 : Float = true as Float
  let f0 : Float = false as Float
  let i1 : Int64 = true as Int64
  let i0 : Int64 = false as Int64
  if d1 == 1.0 && d0 == 0.0 && f1.to_double() == 1.0 && f0.to_double() == 0.0 && i1 == 1L && i0 == 0L {
    42
  } else {
    1
  }
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_bcast" "$PIONC" build -o "$TMP_DIR/bcast_nat" "$TMP_DIR/bcast/main.pion"
set +e; "$TMP_DIR/bcast_nat"; rc=$?; set -e
test "$rc" -eq 42
echo "  Bool scalar casts native: exit=$rc (OK)"
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$TMP_DIR/cas_bcast" "$PIONC" build --target wasm32 -o "$TMP_DIR/bcast.wasm" "$TMP_DIR/bcast/main.pion"
  run_wasm "$TMP_DIR/bcast.wasm" 42
  echo "  Bool scalar casts wasm32: exit=42 (OK)"
fi

# 4b. Cross-pkg `util::call0(read_b)`, indirect `twice(fn(g) { g() })`, and `let alias = apply` (cold + hot CAS)
mkdir -p "$TMP_DIR/cb_xpkg/util/src" "$TMP_DIR/cb_xpkg/app/src" "$TMP_DIR/cas_cbx"
cat > "$TMP_DIR/cb_xpkg/util/pion.toml" <<'EOF'
[package]
name = "util"
version = "0.1.0"
EOF
cat > "$TMP_DIR/cb_xpkg/util/src/lib.pion" <<'EOF'
pub fn call0(f : () -> String) -> String { f() }
EOF
cat > "$TMP_DIR/cb_xpkg/app/pion.toml" <<'EOF'
[package]
name = "cbapp"
version = "0.1.0"

[dependencies]
util = { path = "../util" }
EOF
cat > "$TMP_DIR/cb_xpkg/app/src/a.pion" <<'EOF'
import "util"
let A : String = util::call0(read_b) + twice(fn(g : () -> String) -> String { g() }) + alias_apply(fn() -> String { B })
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/cb_xpkg/app/src/b.pion" <<'EOF'
fn apply(f : () -> String) -> String { f() }
let alias_apply : (() -> String) -> String = apply
fn twice(f : (() -> String) -> String) -> String { f(read_b) }
fn read_b() -> String { B }
let B : String = "ok"
EOF
(cd "$TMP_DIR/cb_xpkg/app" && PION_CACHE_DIR="$TMP_DIR/cas_cbx" "$PIONC" build -o "$TMP_DIR/cbx_cold")
out_cbx1=$("$TMP_DIR/cbx_cold")
test "$out_cbx1" = "okokok"
cat > "$TMP_DIR/cb_xpkg/app/src/b.pion" <<'EOF'
fn apply(f : () -> String) -> String { f() }
let alias_apply : (() -> String) -> String = apply
fn twice(f : (() -> String) -> String) -> String { f(read_b) }
fn read_b() -> String { B }
let B : String = "yo"
EOF
(cd "$TMP_DIR/cb_xpkg/app" && PION_CACHE_DIR="$TMP_DIR/cas_cbx" "$PIONC" build -o "$TMP_DIR/cbx_hot")
out_cbx2=$("$TMP_DIR/cbx_hot")
test "$out_cbx2" = "yoyoyo"
echo "  xpkg util::call0 + twice + alias_apply cold/hot CAS: $out_cbx1 -> $out_cbx2 (OK)"

echo "=== Wave J1 E2E [5/5]: Local callable closures, branch callbacks & as Char scalar validation ==="
# 5a. Local zero-arg closure call (cold + hot CAS), self-cycle E_CONST_CYCLE, and ignore_cb(f)
mkdir -p "$TMP_DIR/lc_ok" "$TMP_DIR/cas_lc" "$TMP_DIR/lc_cyc"
cat > "$TMP_DIR/lc_ok/a.pion" <<'EOF'
let A : Int = run() + run_ign()
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/lc_ok/b.pion" <<'EOF'
fn make_b() -> Int { 40 }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn run() -> Int {
  let f = fn() -> Int { B }
  let g = fn() -> Int { f() }
  g()
}
fn run_ign() -> Int {
  let f = fn() -> Int { A }
  ignore_cb(f)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_lc" "$PIONC" build -o "$TMP_DIR/lc_cold" "$TMP_DIR/lc_ok/a.pion" "$TMP_DIR/lc_ok/b.pion"
set +e; "$TMP_DIR/lc_cold"; rc1=$?; set -e
test "$rc1" -eq 41
cat > "$TMP_DIR/lc_ok/b.pion" <<'EOF'
fn make_b() -> Int { 44 }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn run() -> Int {
  let f = fn() -> Int { B }
  let g = fn() -> Int { f() }
  g()
}
fn run_ign() -> Int {
  let f = fn() -> Int { A }
  ignore_cb(f)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_lc" "$PIONC" build -o "$TMP_DIR/lc_hot" "$TMP_DIR/lc_ok/a.pion" "$TMP_DIR/lc_ok/b.pion"
set +e; "$TMP_DIR/lc_hot"; rc2=$?; set -e
test "$rc2" -eq 45
cat > "$TMP_DIR/lc_cyc/main.pion" <<'EOF'
fn run() -> Int { let f = fn() -> Int { A }; f() }
let A : Int = run()
pub fn main() -> Int { A }
EOF
set +e
lc_cyc_out=$("$PIONC" check --json "$TMP_DIR/lc_cyc/main.pion" 2>&1)
lc_cyc_rc=$?
set -e
test "$lc_cyc_rc" -ne 0
printf '%s' "$lc_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  local closure cold/hot CAS ($rc1 -> $rc2), ignore_cb(f), and self-cycle E_CONST_CYCLE (OK)"

# 5b. Branch-selected callback `apply(if flag { read_b } else { read_c })` (both branches, cold + hot CAS)
#     plus `ignore_cb(if flag { read_a } else { read_c })` (zero false cycle)
mkdir -p "$TMP_DIR/br_cb" "$TMP_DIR/cas_br"
cat > "$TMP_DIR/br_cb/a.pion" <<'EOF'
let A : String = pick(true) + pick(false) + ign(true)
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/br_cb/b.pion" <<'EOF'
fn apply(f : () -> String) -> String { f() }
fn ignore_cb(_f : () -> String) -> String { "!" }
fn read_a() -> String { A }
fn read_b() -> String { B }
fn read_c() -> String { C }
fn pick(flag : Bool) -> String { apply(if flag { read_b } else { read_c }) }
fn ign(flag : Bool) -> String { ignore_cb(if flag { read_a } else { read_c }) }
let B : String = "hi"
let C : String = "ok"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_br" "$PIONC" build -o "$TMP_DIR/br_cold" "$TMP_DIR/br_cb/a.pion" "$TMP_DIR/br_cb/b.pion"
out_br1=$("$TMP_DIR/br_cold")
test "$out_br1" = "hiok!"
cat > "$TMP_DIR/br_cb/b.pion" <<'EOF'
fn apply(f : () -> String) -> String { f() }
fn ignore_cb(_f : () -> String) -> String { "!" }
fn read_a() -> String { A }
fn read_b() -> String { B }
fn read_c() -> String { C }
fn pick(flag : Bool) -> String { apply(if flag { read_b } else { read_c }) }
fn ign(flag : Bool) -> String { ignore_cb(if flag { read_a } else { read_c }) }
let B : String = "ab"
let C : String = "cd"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_br" "$PIONC" build -o "$TMP_DIR/br_hot" "$TMP_DIR/br_cb/a.pion" "$TMP_DIR/br_cb/b.pion"
out_br2=$("$TMP_DIR/br_hot")
test "$out_br2" = "abcd!"
echo "  branch-selected callback cold/hot CAS: $out_br1 -> $out_br2 (OK)"

# 5c. `as Char` Unicode scalar validation (Native + Wasm32)
mkdir -p "$TMP_DIR/char_cast" "$TMP_DIR/cas_char"
cat > "$TMP_DIR/char_cast/main.pion" <<'EOF'
pub fn main() -> Int {
  let ok0 = (0 as Char) as Int == 0
  let ok1 = (55295 as Char) as Int == 55295
  let ok2 = (57344 as Char) as Int == 57344
  let ok3 = (1114111 as Char) as Int == 1114111
  let ok4 = (1114111.0 as Char) as Int == 1114111
  let s1 = (55296 as Char) as Int == 65533
  let s2 = (57343 as Char) as Int == 65533
  let s3 = (55296.0 as Char) as Int == 65533
  let hi1 = (1114112 as Char) as Int == 65533
  let c_big : Char = 4294967296L as Char
  let arr : Array[Char] = [c_big]
  let hi2 = (c_big as Int == 65533) && (arr[0] as Int == 65533)
  let neg1 = ((-1) as Char) as Int == 65533
  let neg2 = ((-1L) as Char) as Int == 65533
  let neg3 = ((-1 as Int8) as Char) as Int == 65533
  let neg4 = ((-1.0) as Char) as Int == 65533
  let z = 0.0
  let nan_c = ((z / z) as Char) as Int == 65533
  if ok0 && ok1 && ok2 && ok3 && ok4 && s1 && s2 && s3 && hi1 && hi2 && neg1 && neg2 && neg3 && neg4 && nan_c {
    77
  } else {
    1
  }
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_char" "$PIONC" build -o "$TMP_DIR/char_nat" "$TMP_DIR/char_cast/main.pion"
set +e; "$TMP_DIR/char_nat"; rc=$?; set -e
test "$rc" -eq 77
echo "  as Char Unicode scalar validation native: exit=$rc (OK)"
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$TMP_DIR/cas_char" "$PIONC" build --target wasm32 -o "$TMP_DIR/char.wasm" "$TMP_DIR/char_cast/main.pion"
  run_wasm "$TMP_DIR/char.wasm" 77
  echo "  as Char Unicode scalar validation wasm32: exit=77 (OK)"
fi

echo "=== Wave J1 E2E [6/6]: Local higher-order #fcallp, shared mut slots & exact/non-exact callees ==="
# 6a. Local higher-order closure `#fcallp` (cold + hot CAS, self-cycle, ignore)
mkdir -p "$TMP_DIR/r8_ho" "$TMP_DIR/cas_r8_ho" "$TMP_DIR/r8_ho_cyc"
cat > "$TMP_DIR/r8_ho/a.pion" <<'EOF'
let A : Int = run_apply() + run_ign()
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/r8_ho/b.pion" <<'EOF'
fn make_b() -> Int { 30 }
fn run_apply() -> Int {
  let apply = fn(f : () -> Int) -> Int { f() }
  apply(fn() -> Int { B })
}
fn run_ign() -> Int {
  let ign = fn(_f : () -> Int) -> Int { 2 }
  ign(fn() -> Int { A })
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_ho" "$PIONC" build -o "$TMP_DIR/r8_ho_cold" "$TMP_DIR/r8_ho/a.pion" "$TMP_DIR/r8_ho/b.pion"
set +e; "$TMP_DIR/r8_ho_cold"; rc1=$?; set -e
test "$rc1" -eq 32
cat > "$TMP_DIR/r8_ho/b.pion" <<'EOF'
fn make_b() -> Int { 35 }
fn run_apply() -> Int {
  let apply = fn(f : () -> Int) -> Int { f() }
  apply(fn() -> Int { B })
}
fn run_ign() -> Int {
  let ign = fn(_f : () -> Int) -> Int { 2 }
  ign(fn() -> Int { A })
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_ho" "$PIONC" build -o "$TMP_DIR/r8_ho_hot" "$TMP_DIR/r8_ho/a.pion" "$TMP_DIR/r8_ho/b.pion"
set +e; "$TMP_DIR/r8_ho_hot"; rc2=$?; set -e
test "$rc2" -eq 37
cat > "$TMP_DIR/r8_ho_cyc/main.pion" <<'EOF'
fn run() -> Int {
  let apply = fn(f : () -> Int) -> Int { f() }
  apply(fn() -> Int { A })
}
let A : Int = run()
pub fn main() -> Int { A }
EOF
set +e
r8_cyc_out=$("$PIONC" check --json "$TMP_DIR/r8_ho_cyc/main.pion" 2>&1)
r8_cyc_rc=$?
set -e
test "$r8_cyc_rc" -ne 0
printf '%s' "$r8_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  local higher-order #fcallp cold/hot CAS ($rc1 -> $rc2), ignore, and self-cycle (OK)"

# 6b. Captured `let mut` closure reassigned after capture & inside closure (cold + hot CAS)
mkdir -p "$TMP_DIR/r8_mut" "$TMP_DIR/cas_r8_mut"
cat > "$TMP_DIR/r8_mut/a.pion" <<'EOF'
let A : String = run_cap().to_string() + ":" + run_set()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r8_mut/b.pion" <<'EOF'
fn make_n() -> Int { 7 }
fn noop(_g : () -> String) -> String { "x" }
fn run_cb(g : () -> String) -> String { g() }
fn read_s() -> String { S }
fn run_cap() -> Int {
  let mut f = fn() -> Int { 0 }
  let g = fn() -> Int { f() }
  f = fn() -> Int { N }
  g()
}
fn run_set() -> String {
  let mut f = noop
  let set = fn() -> Unit { f = run_cb }
  set()
  f(read_s)
}
let N : Int = make_n()
let S : String = "b"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_mut" "$PIONC" build -o "$TMP_DIR/r8_mut_cold" "$TMP_DIR/r8_mut/a.pion" "$TMP_DIR/r8_mut/b.pion"
out_m1=$("$TMP_DIR/r8_mut_cold")
test "$out_m1" = "7:b"
cat > "$TMP_DIR/r8_mut/b.pion" <<'EOF'
fn make_n() -> Int { 9 }
fn noop(_g : () -> String) -> String { "x" }
fn run_cb(g : () -> String) -> String { g() }
fn read_s() -> String { S }
fn run_cap() -> Int {
  let mut f = fn() -> Int { 0 }
  let g = fn() -> Int { f() }
  f = fn() -> Int { N }
  g()
}
fn run_set() -> String {
  let mut f = noop
  let set = fn() -> Unit { f = run_cb }
  set()
  f(read_s)
}
let N : Int = make_n()
let S : String = "z"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_mut" "$PIONC" build -o "$TMP_DIR/r8_mut_hot" "$TMP_DIR/r8_mut/a.pion" "$TMP_DIR/r8_mut/b.pion"
out_m2=$("$TMP_DIR/r8_mut_hot")
test "$out_m2" = "9:z"
echo "  captured let mut slot cold/hot CAS: $out_m1 -> $out_m2 (OK)"

# 6c. Incomplete local targets (Opus) + exhaustive branch callee (Astra #3) (cold + hot CAS)
mkdir -p "$TMP_DIR/r8_ex" "$TMP_DIR/cas_r8_ex"
cat > "$TMP_DIR/r8_ex/a.pion" <<'EOF'
let A : String = go_arr() + go_br(false) + (if true { ignore1 } else { ignore2 })(read_a) + (if false { ignore1 } else { apply })(read_b)
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r8_ex/b.pion" <<'EOF'
fn noop(_g : () -> String) -> String { "x" }
fn ignore1(_g : () -> String) -> String { "!" }
fn ignore2(_g : () -> String) -> String { "?" }
fn apply(g : () -> String) -> String { g() }
fn read_a() -> String { A }
fn read_b() -> String { B }
fn go_arr() -> String {
  let mut f = noop
  f = [apply][0]
  f(read_b)
}
fn go_br(flag : Bool) -> String {
  let fs : Array[(() -> String) -> String] = [apply]
  let f = if flag { noop } else { fs[0] }
  f(read_b)
}
let B : String = "b"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_ex" "$PIONC" build -o "$TMP_DIR/r8_ex_cold" "$TMP_DIR/r8_ex/a.pion" "$TMP_DIR/r8_ex/b.pion"
out_e1=$("$TMP_DIR/r8_ex_cold")
test "$out_e1" = "bb!b"
cat > "$TMP_DIR/r8_ex/b.pion" <<'EOF'
fn noop(_g : () -> String) -> String { "x" }
fn ignore1(_g : () -> String) -> String { "!" }
fn ignore2(_g : () -> String) -> String { "?" }
fn apply(g : () -> String) -> String { g() }
fn read_a() -> String { A }
fn read_b() -> String { B }
fn go_arr() -> String {
  let mut f = noop
  f = [apply][0]
  f(read_b)
}
fn go_br(flag : Bool) -> String {
  let fs : Array[(() -> String) -> String] = [apply]
  let f = if flag { noop } else { fs[0] }
  f(read_b)
}
let B : String = "q"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r8_ex" "$PIONC" build -o "$TMP_DIR/r8_ex_hot" "$TMP_DIR/r8_ex/a.pion" "$TMP_DIR/r8_ex/b.pion"
out_e2=$("$TMP_DIR/r8_ex_hot")
test "$out_e2" = "qq!q"
echo "  incomplete local targets + exhaustive branch callee cold/hot CAS: $out_e1 -> $out_e2 (OK)"

echo "=== Wave J1 E2E [7/7]: Shadowed closure param depth, [read_b][0](), exact #fslot & __slot_ignore ==="
mkdir -p "$TMP_DIR/r9_ok" "$TMP_DIR/cas_r9" "$TMP_DIR/r9_cyc"
cat > "$TMP_DIR/r9_ok/a.pion" <<'EOF'
let A : Int = run_shad() + run_idx() + run_slot_ign() + run_slot_app() + __slot_ignore(fn() -> Int { A })
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/r9_ok/b.pion" <<'EOF'
fn make_b() -> Int { 10 }
fn read_a() -> Int { A }
fn read_b() -> Int { B }
fn ignore1(_g : () -> Int) -> Int { 1 }
fn ignore2(_g : () -> Int) -> Int { 2 }
fn apply(g : () -> Int) -> Int { g() }
fn __slot_ignore(_g : () -> Int) -> Int { 3 }
fn run_shad() -> Int {
  let f = 0
  let _ = f
  let ap = fn(f : () -> Int) -> Int { f() }
  ap(fn() -> Int { B })
}
fn run_idx() -> Int {
  let f = [read_b][0]
  f()
}
fn run_slot_ign() -> Int {
  let mut f = ignore1
  f = ignore2
  f(read_a)
}
fn run_slot_app() -> Int {
  let mut f = ignore1
  f = apply
  f(read_b)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r9" "$PIONC" build -o "$TMP_DIR/r9_cold" "$TMP_DIR/r9_ok/a.pion" "$TMP_DIR/r9_ok/b.pion"
set +e; "$TMP_DIR/r9_cold"; rc1=$?; set -e
test "$rc1" -eq 35
cat > "$TMP_DIR/r9_ok/b.pion" <<'EOF'
fn make_b() -> Int { 12 }
fn read_a() -> Int { A }
fn read_b() -> Int { B }
fn ignore1(_g : () -> Int) -> Int { 1 }
fn ignore2(_g : () -> Int) -> Int { 2 }
fn apply(g : () -> Int) -> Int { g() }
fn __slot_ignore(_g : () -> Int) -> Int { 3 }
fn run_shad() -> Int {
  let f = 0
  let _ = f
  let ap = fn(f : () -> Int) -> Int { f() }
  ap(fn() -> Int { B })
}
fn run_idx() -> Int {
  let f = [read_b][0]
  f()
}
fn run_slot_ign() -> Int {
  let mut f = ignore1
  f = ignore2
  f(read_a)
}
fn run_slot_app() -> Int {
  let mut f = ignore1
  f = apply
  f(read_b)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r9" "$PIONC" build -o "$TMP_DIR/r9_hot" "$TMP_DIR/r9_ok/a.pion" "$TMP_DIR/r9_ok/b.pion"
set +e; "$TMP_DIR/r9_hot"; rc2=$?; set -e
test "$rc2" -eq 41
cat > "$TMP_DIR/r9_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn run() -> Int { let f = [read_a][0]; f() }
let A : Int = run()
pub fn main() -> Int { A }
EOF
set +e
r9_cyc_out=$("$PIONC" check --json "$TMP_DIR/r9_cyc/main.pion" 2>&1)
r9_cyc_rc=$?
set -e
test "$r9_cyc_rc" -ne 0
printf '%s' "$r9_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R9 shadowed param depth + [read_b][0]() + exact #fslot + __slot_ignore cold/hot CAS ($rc1 -> $rc2) & self-cycle (OK)"

echo "=== Wave J1 E2E [8/8]: EMutArg slot invalidation, container projection/writes, decl-kind prefix & #fslot alias ==="
mkdir -p "$TMP_DIR/r10_ok" "$TMP_DIR/cas_r10"
cat > "$TMP_DIR/r10_ok/a.pion" <<'EOF'
let A : String = go_mut() + ":" + go_arr_w().to_string() + ":" + go_arr_p().to_string() + ":" + go_fld().to_string() + ":" + helper_body().to_string() + ":" + go_alias_ign().to_string() + ":" + go_alias_app().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r10_ok/b.pion" <<'EOF'
struct Holder { ok : () -> Int; bad : () -> Int }
fn noop(_g : () -> String) -> String { "x" }
fn run_s(g : () -> String) -> String { g() }
fn reassign(mut f : (() -> String) -> String) -> Unit { f = run_s }
fn read_s() -> String { S }
fn go_mut() -> String {
  let mut f = noop
  reassign(mut f)
  f(read_s)
}
fn zero() -> Int { 0 }
fn seven() -> Int { 7 }
fn make_n() -> Int { 17 }
fn read_a_len() -> Int { A.length() }
fn go_arr_w() -> Int {
  let fs = [zero]
  fs[0] = fn() -> Int { N }
  let f = fs[0]
  f()
}
fn go_arr_p() -> Int {
  let fs = [seven, read_a_len]
  let f = fs[0]
  f()
}
fn go_fld() -> Int {
  let h = Holder::{ ok: seven, bad: read_a_len }
  let f = h.ok
  f()
}
fn helper_body() -> Int { 7 }
let helper : () -> Int = fn() -> Int { let inner = fn() -> Int { A.length() }; inner() }
fn ignore1(_g : () -> Int) -> Int { 1 }
fn ignore2(_g : () -> Int) -> Int { 2 }
fn apply_i(g : () -> Int) -> Int { g() }
fn read_n() -> Int { N }
fn go_alias_ign() -> Int {
  let mut f1 = ignore1
  f1 = ignore2
  let mut f2 = f1
  let g = f2
  g(read_a_len)
}
fn go_alias_app() -> Int {
  let mut f = ignore1
  f = apply_i
  let g = f
  g(read_n)
}
let S : String = "b"
let N : Int = make_n()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r10" "$PIONC" build -o "$TMP_DIR/r10_cold" "$TMP_DIR/r10_ok/a.pion" "$TMP_DIR/r10_ok/b.pion"
out_r10_1=$("$TMP_DIR/r10_cold")
test "$out_r10_1" = "b:17:7:7:7:2:17"
cat > "$TMP_DIR/r10_ok/b.pion" <<'EOF'
struct Holder { ok : () -> Int; bad : () -> Int }
fn noop(_g : () -> String) -> String { "x" }
fn run_s(g : () -> String) -> String { g() }
fn reassign(mut f : (() -> String) -> String) -> Unit { f = run_s }
fn read_s() -> String { S }
fn go_mut() -> String {
  let mut f = noop
  reassign(mut f)
  f(read_s)
}
fn zero() -> Int { 0 }
fn seven() -> Int { 7 }
fn make_n() -> Int { 23 }
fn read_a_len() -> Int { A.length() }
fn go_arr_w() -> Int {
  let fs = [zero]
  fs[0] = fn() -> Int { N }
  let f = fs[0]
  f()
}
fn go_arr_p() -> Int {
  let fs = [seven, read_a_len]
  let f = fs[0]
  f()
}
fn go_fld() -> Int {
  let h = Holder::{ ok: seven, bad: read_a_len }
  let f = h.ok
  f()
}
fn helper_body() -> Int { 7 }
let helper : () -> Int = fn() -> Int { let inner = fn() -> Int { A.length() }; inner() }
fn ignore1(_g : () -> Int) -> Int { 1 }
fn ignore2(_g : () -> Int) -> Int { 2 }
fn apply_i(g : () -> Int) -> Int { g() }
fn read_n() -> Int { N }
fn go_alias_ign() -> Int {
  let mut f1 = ignore1
  f1 = ignore2
  let mut f2 = f1
  let g = f2
  g(read_a_len)
}
fn go_alias_app() -> Int {
  let mut f = ignore1
  f = apply_i
  let g = f
  g(read_n)
}
let S : String = "ok"
let N : Int = make_n()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r10" "$PIONC" build -o "$TMP_DIR/r10_hot" "$TMP_DIR/r10_ok/a.pion" "$TMP_DIR/r10_ok/b.pion"
out_r10_2=$("$TMP_DIR/r10_hot")
test "$out_r10_2" = "ok:23:7:7:7:2:23"
echo "  R10 EMutArg + container projection/writes + decl-kind prefix + #fslot alias cold/hot CAS: $out_r10_1 -> $out_r10_2 (OK)"

echo "=== Wave J1 E2E [9/9]: Shared container slots (\$cslot_), reverse, mut-param #fmutw/#fmutlink & let mut fs ==="
mkdir -p "$TMP_DIR/r11_ok" "$TMP_DIR/cas_r11" "$TMP_DIR/r11_cyc"
cat > "$TMP_DIR/r11_ok/a.pion" <<'EOF'
let A : String = go_alias().to_string() + ":" + go_cap().to_string() + ":" + go_rev().to_string() + ":" + go_mutw().to_string() + ":" + go_mutfs().to_string() + ":" + go_refarr().to_string() + ":" + go_selfm().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r11_ok/b.pion" <<'EOF'
struct Holder { mut f : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn install(mut f : () -> Int) -> Unit { f = read_b }
fn install_arr(fs : Array[() -> Int]) -> Unit { fs[0] = read_b }
fn Holder::install(self : Holder) -> Unit { self.f = read_b }
fn go_alias() -> Int {
  let fs = [zero]
  let alias = fs
  alias[0] = read_b
  let f = fs[0]
  f()
}
fn go_cap() -> Int {
  let fs = [zero]
  let g = fn() -> Int { let f = fs[0]; f() }
  fs[0] = read_b
  g()
}
fn go_rev() -> Int {
  let fs = [zero, read_b]
  fs.reverse()
  let f = fs[0]
  f()
}
fn go_mutw() -> Int {
  let mut f = zero
  install(mut f)
  f()
}
fn go_mutfs() -> Int {
  let mut fs = [zero]
  let set = fn() -> Unit { fs[0] = read_b }
  set()
  let f = fs[0]
  f()
}
fn go_refarr() -> Int {
  let fs = [zero]
  install_arr(fs)
  let f = fs[0]
  f()
}
fn go_selfm() -> Int {
  let h = Holder::{ f: zero }
  h.install()
  let g = h.f
  g()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r11" "$PIONC" build -o "$TMP_DIR/r11_cold" "$TMP_DIR/r11_ok/a.pion" "$TMP_DIR/r11_ok/b.pion"
out_r11_1=$("$TMP_DIR/r11_cold")
test "$out_r11_1" = "17:17:17:17:17:17:17"
cat > "$TMP_DIR/r11_ok/b.pion" <<'EOF'
struct Holder { mut f : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn install(mut f : () -> Int) -> Unit { f = read_b }
fn install_arr(fs : Array[() -> Int]) -> Unit { fs[0] = read_b }
fn Holder::install(self : Holder) -> Unit { self.f = read_b }
fn go_alias() -> Int {
  let fs = [zero]
  let alias = fs
  alias[0] = read_b
  let f = fs[0]
  f()
}
fn go_cap() -> Int {
  let fs = [zero]
  let g = fn() -> Int { let f = fs[0]; f() }
  fs[0] = read_b
  g()
}
fn go_rev() -> Int {
  let fs = [zero, read_b]
  fs.reverse()
  let f = fs[0]
  f()
}
fn go_mutw() -> Int {
  let mut f = zero
  install(mut f)
  f()
}
fn go_mutfs() -> Int {
  let mut fs = [zero]
  let set = fn() -> Unit { fs[0] = read_b }
  set()
  let f = fs[0]
  f()
}
fn go_refarr() -> Int {
  let fs = [zero]
  install_arr(fs)
  let f = fs[0]
  f()
}
fn go_selfm() -> Int {
  let h = Holder::{ f: zero }
  h.install()
  let g = h.f
  g()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r11" "$PIONC" build -o "$TMP_DIR/r11_hot" "$TMP_DIR/r11_ok/a.pion" "$TMP_DIR/r11_ok/b.pion"
out_r11_2=$("$TMP_DIR/r11_hot")
test "$out_r11_2" = "29:29:29:29:29:29:29"
cat > "$TMP_DIR/r11_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(mut f : () -> Int) -> Unit { f = read_a }
fn go() -> Int { let mut f = zero; install(mut f); f() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r11_cyc_out=$("$PIONC" check --json "$TMP_DIR/r11_cyc/main.pion" 2>&1)
r11_cyc_rc=$?
set -e
test "$r11_cyc_rc" -ne 0
printf '%s' "$r11_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R11 shared \$cslot_ + reverse + #fmutw/#fmutlink + let mut fs cold/hot CAS ($out_r11_1 -> $out_r11_2) & self-cycle (OK)"

echo "=== Wave J1 E2E [10/10]: R12 independent cold/hot CAS for mut container rebind, param alias, user get & assign-LHS precision ==="
# 10a: Reassigned mutable container (`let mut fs = [zero]; fs = [read_b]; let f = fs[0]; f()`)
mkdir -p "$TMP_DIR/r12_1" "$TMP_DIR/cas_r12_1"
cat > "$TMP_DIR/r12_1/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r12_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn go() -> Int { let mut fs = [zero]; fs = [read_b]; let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_1" "$PIONC" build -o "$TMP_DIR/r12_1_cold" "$TMP_DIR/r12_1/a.pion" "$TMP_DIR/r12_1/b.pion"
out_r12_1a=$("$TMP_DIR/r12_1_cold")
test "$out_r12_1a" = "17"
cat > "$TMP_DIR/r12_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go() -> Int { let mut fs = [zero]; fs = [read_b]; let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_1" "$PIONC" build -o "$TMP_DIR/r12_1_hot" "$TMP_DIR/r12_1/a.pion" "$TMP_DIR/r12_1/b.pion"
out_r12_1b=$("$TMP_DIR/r12_1_hot")
echo "  10a rebind: $out_r12_1a -> $out_r12_1b"
test "$out_r12_1b" = "23"

# 10b: Parameter local alias (`fn install(fs : Array[() -> Int]) { let a = fs; a[0] = read_b }`)
mkdir -p "$TMP_DIR/r12_2" "$TMP_DIR/cas_r12_2"
cat > "$TMP_DIR/r12_2/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r12_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn install(fs : Array[() -> Int]) -> Unit { let a = fs; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_2" "$PIONC" build -o "$TMP_DIR/r12_2_cold" "$TMP_DIR/r12_2/a.pion" "$TMP_DIR/r12_2/b.pion"
out_r12_2a=$("$TMP_DIR/r12_2_cold")
test "$out_r12_2a" = "31"
cat > "$TMP_DIR/r12_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn install(fs : Array[() -> Int]) -> Unit { let a = fs; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_2" "$PIONC" build -o "$TMP_DIR/r12_2_hot" "$TMP_DIR/r12_2/a.pion" "$TMP_DIR/r12_2/b.pion"
out_r12_2b=$("$TMP_DIR/r12_2_hot")
echo "  10b palias: $out_r12_2a -> $out_r12_2b"
test "$out_r12_2b" = "37"

# 10c: User method named `get` mutating `self.f`
mkdir -p "$TMP_DIR/r12_3" "$TMP_DIR/cas_r12_3"
cat > "$TMP_DIR/r12_3/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r12_3/b.pion" <<'EOF'
struct Holder { mut f : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn Holder::get(self : Holder) -> Unit { self.f = read_b }
fn go() -> Int { let h = Holder::{ f: zero }; h.get(); let g = h.f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_3" "$PIONC" build -o "$TMP_DIR/r12_3_cold" "$TMP_DIR/r12_3/a.pion" "$TMP_DIR/r12_3/b.pion"
out_r12_3a=$("$TMP_DIR/r12_3_cold")
test "$out_r12_3a" = "41"
cat > "$TMP_DIR/r12_3/b.pion" <<'EOF'
struct Holder { mut f : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn Holder::get(self : Holder) -> Unit { self.f = read_b }
fn go() -> Int { let h = Holder::{ f: zero }; h.get(); let g = h.f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_3" "$PIONC" build -o "$TMP_DIR/r12_3_hot" "$TMP_DIR/r12_3/a.pion" "$TMP_DIR/r12_3/b.pion"
out_r12_3b=$("$TMP_DIR/r12_3_hot")
echo "  10c userget: $out_r12_3a -> $out_r12_3b"
test "$out_r12_3b" = "43"

# 10d: `SAssign` LHS container write without call (no false cycle) vs with call (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r12_4" "$TMP_DIR/cas_r12_4" "$TMP_DIR/r12_4_cyc"
cat > "$TMP_DIR/r12_4/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r12_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(fs : Array[() -> Int]) -> Unit { fs[0] = read_a }
fn go() -> Int { let fs = [zero]; install(fs); 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_4" "$PIONC" build -o "$TMP_DIR/r12_4_cold" "$TMP_DIR/r12_4/a.pion" "$TMP_DIR/r12_4/b.pion"
out_r12_4a=$("$TMP_DIR/r12_4_cold")
test "$out_r12_4a" = "1"
cat > "$TMP_DIR/r12_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(fs : Array[() -> Int]) -> Unit { fs[0] = read_a }
fn go() -> Int { let fs = [zero]; install(fs); 2 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r12_4" "$PIONC" build -o "$TMP_DIR/r12_4_hot" "$TMP_DIR/r12_4/a.pion" "$TMP_DIR/r12_4/b.pion"
out_r12_4b=$("$TMP_DIR/r12_4_hot")
test "$out_r12_4b" = "2"

cat > "$TMP_DIR/r12_4_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(fs : Array[() -> Int]) -> Unit { fs[0] = read_a }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r12_cyc_out=$("$PIONC" check --json "$TMP_DIR/r12_4_cyc/main.pion" 2>&1)
r12_cyc_rc=$?
set -e
test "$r12_cyc_rc" -ne 0
printf '%s' "$r12_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R12 independent cold/hot CAS (rebind $out_r12_1a->$out_r12_1b, palias $out_r12_2a->$out_r12_2b, userget $out_r12_3a->$out_r12_3b, nocall $out_r12_4a->$out_r12_4b) & call-cycle (OK)"

echo "=== Wave J1 E2E [11/11]: R13 independent cold/hot CAS for old/new alias, assign param alias, conditional #fcbw & alias direct_callp ==="
# 11a: Rebind preserves old_a (0) while new_a sees rebound container (19 -> 29)
mkdir -p "$TMP_DIR/r13_1old" "$TMP_DIR/r13_1new" "$TMP_DIR/cas_r13_1new"
cat > "$TMP_DIR/r13_1old/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_1old/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int { let mut fs = [zero]; let old_a = fs; fs = [read_a]; let _ = fs; let f = old_a[0]; f() }
EOF
"$PIONC" build -o "$TMP_DIR/r13_1old_bin" "$TMP_DIR/r13_1old/a.pion" "$TMP_DIR/r13_1old/b.pion"
out_r13_1old=$("$TMP_DIR/r13_1old_bin")
test "$out_r13_1old" = "0"

cat > "$TMP_DIR/r13_1new/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_1new/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 19 }
fn go() -> Int { let mut fs = [zero]; let _old_a = fs; fs = [read_b]; let new_a = fs; let f = new_a[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_1new" "$PIONC" build -o "$TMP_DIR/r13_1new_cold" "$TMP_DIR/r13_1new/a.pion" "$TMP_DIR/r13_1new/b.pion"
out_r13_1a=$("$TMP_DIR/r13_1new_cold")
test "$out_r13_1a" = "19"
cat > "$TMP_DIR/r13_1new/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn go() -> Int { let mut fs = [zero]; let _old_a = fs; fs = [read_b]; let new_a = fs; let f = new_a[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_1new" "$PIONC" build -o "$TMP_DIR/r13_1new_hot" "$TMP_DIR/r13_1new/a.pion" "$TMP_DIR/r13_1new/b.pion"
out_r13_1b=$("$TMP_DIR/r13_1new_hot")
test "$out_r13_1b" = "29"

# 11b: Param alias via assignment (`let mut a = [zero]; a = fs; a[0] = read_b`)
mkdir -p "$TMP_DIR/r13_2" "$TMP_DIR/cas_r13_2"
cat > "$TMP_DIR/r13_2/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = fs; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_2" "$PIONC" build -o "$TMP_DIR/r13_2_cold" "$TMP_DIR/r13_2/a.pion" "$TMP_DIR/r13_2/b.pion"
out_r13_2a=$("$TMP_DIR/r13_2_cold")
test "$out_r13_2a" = "31"
cat > "$TMP_DIR/r13_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 47 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = fs; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_2" "$PIONC" build -o "$TMP_DIR/r13_2_hot" "$TMP_DIR/r13_2/a.pion" "$TMP_DIR/r13_2/b.pion"
out_r13_2b=$("$TMP_DIR/r13_2_hot")
test "$out_r13_2b" = "47"

# 11c: Closure capturing outer param alias: called (53 -> 59) vs uncalled (0, no false cycle)
mkdir -p "$TMP_DIR/r13_3" "$TMP_DIR/cas_r13_3" "$TMP_DIR/r13_3un"
cat > "$TMP_DIR/r13_3/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 53 }
fn install(fs : Array[() -> Int]) -> Unit { let a = fs; let set = fn() -> Unit { a[0] = read_b }; set() }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_3" "$PIONC" build -o "$TMP_DIR/r13_3_cold" "$TMP_DIR/r13_3/a.pion" "$TMP_DIR/r13_3/b.pion"
out_r13_3a=$("$TMP_DIR/r13_3_cold")
test "$out_r13_3a" = "53"
cat > "$TMP_DIR/r13_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 59 }
fn install(fs : Array[() -> Int]) -> Unit { let a = fs; let set = fn() -> Unit { a[0] = read_b }; set() }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_3" "$PIONC" build -o "$TMP_DIR/r13_3_hot" "$TMP_DIR/r13_3/a.pion" "$TMP_DIR/r13_3/b.pion"
out_r13_3b=$("$TMP_DIR/r13_3_hot")
test "$out_r13_3b" = "59"

cat > "$TMP_DIR/r13_3un/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_3un/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(fs : Array[() -> Int]) -> Unit { let a = fs; let _set = fn() -> Unit { a[0] = read_a }; () }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
EOF
"$PIONC" build -o "$TMP_DIR/r13_3un_bin" "$TMP_DIR/r13_3un/a.pion" "$TMP_DIR/r13_3un/b.pion"
out_r13_3un=$("$TMP_DIR/r13_3un_bin")
test "$out_r13_3un" = "0"

# 11d: Param alias without call (`clear_first`) returns 1 (no false cycle) vs calling `a[0]()` (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r13_4" "$TMP_DIR/cas_r13_4" "$TMP_DIR/r13_4_cyc"
cat > "$TMP_DIR/r13_4/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r13_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn clear_first(fs : Array[() -> Int]) -> Unit { let a = fs; a[0] = zero }
fn go() -> Int { let fs = [read_a]; clear_first(fs); 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_4" "$PIONC" build -o "$TMP_DIR/r13_4_cold" "$TMP_DIR/r13_4/a.pion" "$TMP_DIR/r13_4/b.pion"
out_r13_4a=$("$TMP_DIR/r13_4_cold")
test "$out_r13_4a" = "1"
cat > "$TMP_DIR/r13_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn clear_first(fs : Array[() -> Int]) -> Unit { let a = fs; a[0] = zero }
fn go() -> Int { let fs = [read_a]; clear_first(fs); 2 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r13_4" "$PIONC" build -o "$TMP_DIR/r13_4_hot" "$TMP_DIR/r13_4/a.pion" "$TMP_DIR/r13_4/b.pion"
out_r13_4b=$("$TMP_DIR/r13_4_hot")
test "$out_r13_4b" = "2"

cat > "$TMP_DIR/r13_4_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn clear_first(fs : Array[() -> Int]) -> Int { let a = fs; let f = a[0]; a[0] = zero; f() }
fn go() -> Int { let fs = [read_a]; clear_first(fs) }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r13_cyc_out=$("$PIONC" check --json "$TMP_DIR/r13_4_cyc/main.pion" 2>&1)
r13_cyc_rc=$?
set -e
test "$r13_cyc_rc" -ne 0
printf '%s' "$r13_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R13 independent cold/hot CAS (old=$out_r13_1old, new $out_r13_1a->$out_r13_1b, assign $out_r13_2a->$out_r13_2b, cb $out_r13_3a->$out_r13_3b/un=$out_r13_3un, clear $out_r13_4a->$out_r13_4b) & call-cycle (OK)"

echo "=== Wave J1 E2E [12/12]: R14 independent cold/hot CAS for rebound shared cslot, #fcbcall, block env & alias forwarding ==="
# 12a: Rebound mut container shares new $cslot with new_a while old_a keeps 0
mkdir -p "$TMP_DIR/r14_1" "$TMP_DIR/cas_r14_1"
cat > "$TMP_DIR/r14_1/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r14_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn go() -> Int {
  let mut fs = [zero]
  let old_a = fs
  fs = [zero]
  let new_a = fs
  new_a[0] = read_b
  let f0 = old_a[0]
  let f1 = fs[0]
  f0() + f1()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_1" "$PIONC" build -o "$TMP_DIR/r14_1_cold" "$TMP_DIR/r14_1/a.pion" "$TMP_DIR/r14_1/b.pion"
out_r14_1a=$("$TMP_DIR/r14_1_cold")
test "$out_r14_1a" = "17"
cat > "$TMP_DIR/r14_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go() -> Int {
  let mut fs = [zero]
  let old_a = fs
  fs = [zero]
  let new_a = fs
  new_a[0] = read_b
  let f0 = old_a[0]
  let f1 = fs[0]
  f0() + f1()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_1" "$PIONC" build -o "$TMP_DIR/r14_1_hot" "$TMP_DIR/r14_1/a.pion" "$TMP_DIR/r14_1/b.pion"
out_r14_1b=$("$TMP_DIR/r14_1_hot")
test "$out_r14_1b" = "23"

# 12b: Closure calling captured outer param alias (`#fcbcall`) cold/hot CAS (29 -> 37) + uncalled (1)
mkdir -p "$TMP_DIR/r14_2" "$TMP_DIR/cas_r14_2" "$TMP_DIR/r14_2un"
cat > "$TMP_DIR/r14_2/a.pion" <<'EOF'
let A : Int = relay(read_b)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r14_2/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn relay(f : () -> Int) -> Int { let g = f; let h = fn() -> Int { g() }; h() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_2" "$PIONC" build -o "$TMP_DIR/r14_2_cold" "$TMP_DIR/r14_2/a.pion" "$TMP_DIR/r14_2/b.pion"
out_r14_2a=$("$TMP_DIR/r14_2_cold")
test "$out_r14_2a" = "29"
cat > "$TMP_DIR/r14_2/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn relay(f : () -> Int) -> Int { let g = f; let h = fn() -> Int { g() }; h() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_2" "$PIONC" build -o "$TMP_DIR/r14_2_hot" "$TMP_DIR/r14_2/a.pion" "$TMP_DIR/r14_2/b.pion"
out_r14_2b=$("$TMP_DIR/r14_2_hot")
test "$out_r14_2b" = "37"

cat > "$TMP_DIR/r14_2un/a.pion" <<'EOF'
let A : Int = relay(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r14_2un/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn relay(f : () -> Int) -> Int { let g = f; let _h = fn() -> Int { g() }; 1 }
EOF
"$PIONC" build -o "$TMP_DIR/r14_2un_bin" "$TMP_DIR/r14_2un/a.pion" "$TMP_DIR/r14_2un/b.pion"
out_r14_2un=$("$TMP_DIR/r14_2un_bin")
test "$out_r14_2un" = "1"

# 12c: Block-local param alias `a = { let t = fs; t }; a[0] = read_b` cold/hot CAS (41 -> 43)
mkdir -p "$TMP_DIR/r14_3" "$TMP_DIR/cas_r14_3"
cat > "$TMP_DIR/r14_3/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r14_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = { let t = fs; t }; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_3" "$PIONC" build -o "$TMP_DIR/r14_3_cold" "$TMP_DIR/r14_3/a.pion" "$TMP_DIR/r14_3/b.pion"
out_r14_3a=$("$TMP_DIR/r14_3_cold")
test "$out_r14_3a" = "41"
cat > "$TMP_DIR/r14_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = { let t = fs; t }; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_3" "$PIONC" build -o "$TMP_DIR/r14_3_hot" "$TMP_DIR/r14_3/a.pion" "$TMP_DIR/r14_3/b.pion"
out_r14_3b=$("$TMP_DIR/r14_3_hot")
test "$out_r14_3b" = "43"

# 12d: Param alias forwarded to `ignore_cb(g)` (1 -> 2, 0 diagnostics) vs `apply(g)` (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r14_4" "$TMP_DIR/cas_r14_4" "$TMP_DIR/r14_4_cyc"
cat > "$TMP_DIR/r14_4/a.pion" <<'EOF'
let A : Int = relay(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r14_4/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn relay(f : () -> Int) -> Int { let g = f; ignore_cb(g) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_4" "$PIONC" build -o "$TMP_DIR/r14_4_cold" "$TMP_DIR/r14_4/a.pion" "$TMP_DIR/r14_4/b.pion"
out_r14_4a=$("$TMP_DIR/r14_4_cold")
test "$out_r14_4a" = "1"
cat > "$TMP_DIR/r14_4/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 2 }
fn relay(f : () -> Int) -> Int { let g = f; ignore_cb(g) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r14_4" "$PIONC" build -o "$TMP_DIR/r14_4_hot" "$TMP_DIR/r14_4/a.pion" "$TMP_DIR/r14_4/b.pion"
out_r14_4b=$("$TMP_DIR/r14_4_hot")
test "$out_r14_4b" = "2"

cat > "$TMP_DIR/r14_4_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn apply(f : () -> Int) -> Int { f() }
fn relay(f : () -> Int) -> Int { let g = f; apply(g) }
let A : Int = relay(read_a)
pub fn main() -> Int { A }
EOF
set +e
r14_cyc_out=$("$PIONC" check --json "$TMP_DIR/r14_4_cyc/main.pion" 2>&1)
r14_cyc_rc=$?
set -e
test "$r14_cyc_rc" -ne 0
printf '%s' "$r14_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R14 independent cold/hot CAS (share $out_r14_1a->$out_r14_1b, cbcall $out_r14_2a->$out_r14_2b/un=$out_r14_2un, blk $out_r14_3a->$out_r14_3b, fwd $out_r14_4a->$out_r14_4b) & apply-cycle (OK)"

echo "=== Wave J1 E2E [13/13]: R15 independent cold/hot CAS for escaping anon closure alias, conditional cslots, SLetTuple & #fcbcallfwd ==="
# 13a: Escaping anonymous closures capturing param alias (tail + return + struct field)
mkdir -p "$TMP_DIR/r15_1" "$TMP_DIR/cas_r15_1"
cat > "$TMP_DIR/r15_1/a.pion" <<'EOF'
let A : String = mk_tail(read_b)() + ":" + mk_ret(read_b)() + ":" + { let h = mk_fld(read_b); (h.cb)() }
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r15_1/b.pion" <<'EOF'
struct Holder { cb : () -> String }
fn read_b() -> String { B }
fn mk_tail(f : () -> String) -> () -> String { let a = f; fn() -> String { a() } }
fn mk_ret(f : () -> String) -> () -> String { let a = f; return fn() -> String { a() } }
fn mk_fld(f : () -> String) -> Holder { let a = f; Holder::{ cb: fn() -> String { a() } } }
let B : String = "b"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_1" "$PIONC" build -o "$TMP_DIR/r15_1_cold" "$TMP_DIR/r15_1/a.pion" "$TMP_DIR/r15_1/b.pion"
out_r15_1a=$("$TMP_DIR/r15_1_cold")
test "$out_r15_1a" = "b:b:b"
cat > "$TMP_DIR/r15_1/b.pion" <<'EOF'
struct Holder { cb : () -> String }
fn read_b() -> String { B }
fn mk_tail(f : () -> String) -> () -> String { let a = f; fn() -> String { a() } }
fn mk_ret(f : () -> String) -> () -> String { let a = f; return fn() -> String { a() } }
fn mk_fld(f : () -> String) -> Holder { let a = f; Holder::{ cb: fn() -> String { a() } } }
let B : String = "ok"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_1" "$PIONC" build -o "$TMP_DIR/r15_1_hot" "$TMP_DIR/r15_1/a.pion" "$TMP_DIR/r15_1/b.pion"
out_r15_1b=$("$TMP_DIR/r15_1_hot")
test "$out_r15_1b" = "ok:ok:ok"

# 13b: Conditional container rebind (`if flag { fs = right }`) preserves left cslot
mkdir -p "$TMP_DIR/r15_2" "$TMP_DIR/cas_r15_2"
cat > "$TMP_DIR/r15_2/a.pion" <<'EOF'
let A : Int = go(false)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r15_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 19 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  if flag { fs = right }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_2" "$PIONC" build -o "$TMP_DIR/r15_2_cold" "$TMP_DIR/r15_2/a.pion" "$TMP_DIR/r15_2/b.pion"
out_r15_2a=$("$TMP_DIR/r15_2_cold")
test "$out_r15_2a" = "19"
cat > "$TMP_DIR/r15_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  if flag { fs = right }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_2" "$PIONC" build -o "$TMP_DIR/r15_2_hot" "$TMP_DIR/r15_2/a.pion" "$TMP_DIR/r15_2/b.pion"
out_r15_2b=$("$TMP_DIR/r15_2_hot")
test "$out_r15_2b" = "29"

# 13c: `SLetTuple` positional param_srcs (block & top-level) cold/hot CAS (41 -> 43) + cycle
mkdir -p "$TMP_DIR/r15_3" "$TMP_DIR/cas_r15_3" "$TMP_DIR/r15_3_top" "$TMP_DIR/cas_r15_3_top" "$TMP_DIR/r15_3_cyc"
cat > "$TMP_DIR/r15_3/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r15_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = { let (t, _n) = (fs, 0); t }; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_3" "$PIONC" build -o "$TMP_DIR/r15_3_cold" "$TMP_DIR/r15_3/a.pion" "$TMP_DIR/r15_3/b.pion"
out_r15_3a=$("$TMP_DIR/r15_3_cold")
test "$out_r15_3a" = "41"
cat > "$TMP_DIR/r15_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = { let (t, _n) = (fs, 0); t }; a[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_3" "$PIONC" build -o "$TMP_DIR/r15_3_hot" "$TMP_DIR/r15_3/a.pion" "$TMP_DIR/r15_3/b.pion"
out_r15_3b=$("$TMP_DIR/r15_3_hot")
test "$out_r15_3b" = "43"

cat > "$TMP_DIR/r15_3_top/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r15_3_top/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn install(fs : Array[() -> Int]) -> Unit { let (t, _n) = (fs, 0); t[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_3_top" "$PIONC" build -o "$TMP_DIR/r15_3_top_cold" "$TMP_DIR/r15_3_top/a.pion" "$TMP_DIR/r15_3_top/b.pion"
out_r15_3ta=$("$TMP_DIR/r15_3_top_cold")
test "$out_r15_3ta" = "41"
cat > "$TMP_DIR/r15_3_top/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn install(fs : Array[() -> Int]) -> Unit { let (t, _n) = (fs, 0); t[0] = read_b }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_3_top" "$PIONC" build -o "$TMP_DIR/r15_3_top_hot" "$TMP_DIR/r15_3_top/a.pion" "$TMP_DIR/r15_3_top/b.pion"
out_r15_3tb=$("$TMP_DIR/r15_3_top_hot")
test "$out_r15_3tb" = "43"

cat > "$TMP_DIR/r15_3_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(fs : Array[() -> Int]) -> Unit { let mut a = [zero]; a = { let (t, _n) = (fs, 0); t }; a[0] = read_a }
fn go() -> Int { let fs = [zero]; install(fs); let f = fs[0]; f() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r15_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r15_3_cyc/main.pion" 2>&1)
r15_3_cyc_rc=$?
set -e
test "$r15_3_cyc_rc" -ne 0
printf '%s' "$r15_3_cyc_out" | grep -q "E_CONST_CYCLE"

# 13d: `#fcbcallfwd` inside executed closure: `ignore_cb(g)` (1 -> 2, 0 diagnostics) vs `mid(g)->apply(g)` (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r15_4" "$TMP_DIR/cas_r15_4" "$TMP_DIR/r15_4_cyc"
cat > "$TMP_DIR/r15_4/a.pion" <<'EOF'
let A : Int = relay(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r15_4/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn relay(f : () -> Int) -> Int { let g = f; let h = fn() -> Int { ignore_cb(g) }; h() }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_4" "$PIONC" build -o "$TMP_DIR/r15_4_cold" "$TMP_DIR/r15_4/a.pion" "$TMP_DIR/r15_4/b.pion"
out_r15_4a=$("$TMP_DIR/r15_4_cold")
test "$out_r15_4a" = "1"
cat > "$TMP_DIR/r15_4/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 2 }
fn relay(f : () -> Int) -> Int { let g = f; let h = fn() -> Int { ignore_cb(g) }; h() }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r15_4" "$PIONC" build -o "$TMP_DIR/r15_4_hot" "$TMP_DIR/r15_4/a.pion" "$TMP_DIR/r15_4/b.pion"
out_r15_4b=$("$TMP_DIR/r15_4_hot")
test "$out_r15_4b" = "2"

cat > "$TMP_DIR/r15_4_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn apply(f : () -> Int) -> Int { f() }
fn mid(f : () -> Int) -> Int { apply(f) }
fn relay(f : () -> Int) -> Int { let g = f; let h = fn() -> Int { mid(g) }; h() }
let A : Int = relay(read_a)
pub fn main() -> Int { A }
EOF
set +e
r15_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r15_4_cyc/main.pion" 2>&1)
r15_4_cyc_rc=$?
set -e
test "$r15_4_cyc_rc" -ne 0
printf '%s' "$r15_4_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R15 independent cold/hot CAS (esc $out_r15_1a->$out_r15_1b, cond $out_r15_2a->$out_r15_2b, tuple $out_r15_3a->$out_r15_3b/top $out_r15_3ta->$out_r15_3tb, cbfwd $out_r15_4a->$out_r15_4b) & cycles (OK)"

echo "=== Wave J1 E2E [14/14]: R16 independent cold/hot CAS for escaping named closure & while-loop cond_depth ==="
# 14a: Escaping named closure local (tail + return + struct field)
mkdir -p "$TMP_DIR/r16_1" "$TMP_DIR/cas_r16_1"
cat > "$TMP_DIR/r16_1/a.pion" <<'EOF'
let A : String = mk_tail(read_b)() + ":" + mk_ret(read_b)() + ":" + { let x = mk_fld(read_b); (x.cb)() }
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r16_1/b.pion" <<'EOF'
struct Holder { cb : () -> String }
fn read_b() -> String { B }
fn mk_tail(f : () -> String) -> () -> String { let a = f; let h = fn() -> String { a() }; h }
fn mk_ret(f : () -> String) -> () -> String { let h = fn() -> String { f() }; return h }
fn mk_fld(f : () -> String) -> Holder { let a = f; let h = fn() -> String { a() }; Holder::{ cb: h } }
let B : String = "b"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_1" "$PIONC" build -o "$TMP_DIR/r16_1_cold" "$TMP_DIR/r16_1/a.pion" "$TMP_DIR/r16_1/b.pion"
out_r16_1a=$("$TMP_DIR/r16_1_cold")
test "$out_r16_1a" = "b:b:b"
cat > "$TMP_DIR/r16_1/b.pion" <<'EOF'
struct Holder { cb : () -> String }
fn read_b() -> String { B }
fn mk_tail(f : () -> String) -> () -> String { let a = f; let h = fn() -> String { a() }; h }
fn mk_ret(f : () -> String) -> () -> String { let h = fn() -> String { f() }; return h }
fn mk_fld(f : () -> String) -> Holder { let a = f; let h = fn() -> String { a() }; Holder::{ cb: h } }
let B : String = "ok"
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_1" "$PIONC" build -o "$TMP_DIR/r16_1_hot" "$TMP_DIR/r16_1/a.pion" "$TMP_DIR/r16_1/b.pion"
out_r16_1b=$("$TMP_DIR/r16_1_hot")
test "$out_r16_1b" = "ok:ok:ok"

# 14b: Named closure forwarded to `ignore_cb(h)` (1 -> 2, 0 diagnostics) vs `apply(h)` (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r16_2" "$TMP_DIR/cas_r16_2" "$TMP_DIR/r16_2_cyc"
cat > "$TMP_DIR/r16_2/a.pion" <<'EOF'
let A : Int = relay(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r16_2/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn relay(f : () -> Int) -> Int { let a = f; let h = fn() -> Int { a() }; ignore_cb(h) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_2" "$PIONC" build -o "$TMP_DIR/r16_2_cold" "$TMP_DIR/r16_2/a.pion" "$TMP_DIR/r16_2/b.pion"
out_r16_2a=$("$TMP_DIR/r16_2_cold")
test "$out_r16_2a" = "1"
cat > "$TMP_DIR/r16_2/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 2 }
fn relay(f : () -> Int) -> Int { let a = f; let h = fn() -> Int { a() }; ignore_cb(h) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_2" "$PIONC" build -o "$TMP_DIR/r16_2_hot" "$TMP_DIR/r16_2/a.pion" "$TMP_DIR/r16_2/b.pion"
out_r16_2b=$("$TMP_DIR/r16_2_hot")
test "$out_r16_2b" = "2"

cat > "$TMP_DIR/r16_2_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn apply(f : () -> Int) -> Int { f() }
fn relay(f : () -> Int) -> Int { let a = f; let h = fn() -> Int { a() }; apply(h) }
let A : Int = relay(read_a)
pub fn main() -> Int { A }
EOF
set +e
r16_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r16_2_cyc/main.pion" 2>&1)
r16_2_cyc_rc=$?
set -e
test "$r16_2_cyc_rc" -ne 0
printf '%s' "$r16_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 14c: While-loop `while flag { fs = right }` with `flag = false` preserves `left` cslot (23 -> 31)
mkdir -p "$TMP_DIR/r16_3" "$TMP_DIR/cas_r16_3"
cat > "$TMP_DIR/r16_3/a.pion" <<'EOF'
let A : Int = go(false)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r16_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  while flag { fs = right }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_3" "$PIONC" build -o "$TMP_DIR/r16_3_cold" "$TMP_DIR/r16_3/a.pion" "$TMP_DIR/r16_3/b.pion"
out_r16_3a=$("$TMP_DIR/r16_3_cold")
test "$out_r16_3a" = "23"
cat > "$TMP_DIR/r16_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  while flag { fs = right }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r16_3" "$PIONC" build -o "$TMP_DIR/r16_3_hot" "$TMP_DIR/r16_3/a.pion" "$TMP_DIR/r16_3/b.pion"
out_r16_3b=$("$TMP_DIR/r16_3_hot")
test "$out_r16_3b" = "31"
echo "  R16 independent cold/hot CAS (named $out_r16_1a->$out_r16_1b, ign $out_r16_2a->$out_r16_2b, while $out_r16_3a->$out_r16_3b) & apply-cycle (OK)"

echo "=== Wave J1 E2E [15/15]: R17 independent cold/hot CAS for loop back-edge, &&/|| cond_depth, SLetTuple swap & escaping cb->named cb ==="
# 15a: Loop back-edge `while i < 2 { fs[0] = read_b; fs = right; i = i + 1 }` (17 -> 23)
mkdir -p "$TMP_DIR/r17_1" "$TMP_DIR/cas_r17_1"
cat > "$TMP_DIR/r17_1/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r17_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while i < 2 { fs[0] = read_b; fs = right; i = i + 1 }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_1" "$PIONC" build -o "$TMP_DIR/r17_1_cold" "$TMP_DIR/r17_1/a.pion" "$TMP_DIR/r17_1/b.pion"
out_r17_1a=$("$TMP_DIR/r17_1_cold")
test "$out_r17_1a" = "17"
cat > "$TMP_DIR/r17_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while i < 2 { fs[0] = read_b; fs = right; i = i + 1 }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_1" "$PIONC" build -o "$TMP_DIR/r17_1_hot" "$TMP_DIR/r17_1/a.pion" "$TMP_DIR/r17_1/b.pion"
out_r17_1b=$("$TMP_DIR/r17_1_hot")
test "$out_r17_1b" = "23"

# 15b: Short-circuit `&&` (flag=false) and `||` (flag=true) preserve `left` cslot (29:29 -> 31:31)
mkdir -p "$TMP_DIR/r17_2" "$TMP_DIR/cas_r17_2"
cat > "$TMP_DIR/r17_2/a.pion" <<'EOF'
let A : String = go_and(false).to_string() + ":" + go_or(true).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r17_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn go_and(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = flag && { fs = right; true }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
fn go_or(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = flag || { fs = right; false }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_2" "$PIONC" build -o "$TMP_DIR/r17_2_cold" "$TMP_DIR/r17_2/a.pion" "$TMP_DIR/r17_2/b.pion"
out_r17_2a=$("$TMP_DIR/r17_2_cold")
test "$out_r17_2a" = "29:29"
cat > "$TMP_DIR/r17_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn go_and(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = flag && { fs = right; true }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
fn go_or(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = flag || { fs = right; false }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_2" "$PIONC" build -o "$TMP_DIR/r17_2_hot" "$TMP_DIR/r17_2/a.pion" "$TMP_DIR/r17_2/b.pion"
out_r17_2b=$("$TMP_DIR/r17_2_hot")
test "$out_r17_2b" = "31:31"

# 15c: `SLetTuple` simultaneous RHS eval (`let f = read_b; let (f, g) = (zero, f); g()`) (37 -> 41)
mkdir -p "$TMP_DIR/r17_3" "$TMP_DIR/cas_r17_3"
cat > "$TMP_DIR/r17_3/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r17_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn go() -> Int { let f = read_b; let (f, g) = (zero, f); let _ = f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_3" "$PIONC" build -o "$TMP_DIR/r17_3_cold" "$TMP_DIR/r17_3/a.pion" "$TMP_DIR/r17_3/b.pion"
out_r17_3a=$("$TMP_DIR/r17_3_cold")
test "$out_r17_3a" = "37"
cat > "$TMP_DIR/r17_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn go() -> Int { let f = read_b; let (f, g) = (zero, f); let _ = f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_3" "$PIONC" build -o "$TMP_DIR/r17_3_hot" "$TMP_DIR/r17_3/a.pion" "$TMP_DIR/r17_3/b.pion"
out_r17_3b=$("$TMP_DIR/r17_3_hot")
test "$out_r17_3b" = "41"

# 15d: Escaping anon closure calling named closure `h()` (43 -> 47), `ignore_cb(fn(){h()})` (1 -> 2), `apply(fn(){h()})` (E_CONST_CYCLE)
mkdir -p "$TMP_DIR/r17_4" "$TMP_DIR/cas_r17_4" "$TMP_DIR/r17_4ign" "$TMP_DIR/cas_r17_4ign" "$TMP_DIR/r17_4cyc"
cat > "$TMP_DIR/r17_4/a.pion" <<'EOF'
let A : Int = mk(read_b)()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r17_4/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn mk(f : () -> Int) -> () -> Int { let h = fn() -> Int { f() }; fn() -> Int { h() } }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_4" "$PIONC" build -o "$TMP_DIR/r17_4_cold" "$TMP_DIR/r17_4/a.pion" "$TMP_DIR/r17_4/b.pion"
out_r17_4a=$("$TMP_DIR/r17_4_cold")
test "$out_r17_4a" = "43"
cat > "$TMP_DIR/r17_4/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 47 }
fn mk(f : () -> Int) -> () -> Int { let h = fn() -> Int { f() }; fn() -> Int { h() } }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_4" "$PIONC" build -o "$TMP_DIR/r17_4_hot" "$TMP_DIR/r17_4/a.pion" "$TMP_DIR/r17_4/b.pion"
out_r17_4b=$("$TMP_DIR/r17_4_hot")
test "$out_r17_4b" = "47"

cat > "$TMP_DIR/r17_4ign/a.pion" <<'EOF'
let A : Int = relay(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r17_4ign/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 1 }
fn relay(f : () -> Int) -> Int { let h = fn() -> Int { f() }; ignore_cb(fn() -> Int { h() }) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_4ign" "$PIONC" build -o "$TMP_DIR/r17_4ign_cold" "$TMP_DIR/r17_4ign/a.pion" "$TMP_DIR/r17_4ign/b.pion"
out_r17_4ia=$("$TMP_DIR/r17_4ign_cold")
test "$out_r17_4ia" = "1"
cat > "$TMP_DIR/r17_4ign/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn ignore_cb(_f : () -> Int) -> Int { 2 }
fn relay(f : () -> Int) -> Int { let h = fn() -> Int { f() }; ignore_cb(fn() -> Int { h() }) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r17_4ign" "$PIONC" build -o "$TMP_DIR/r17_4ign_hot" "$TMP_DIR/r17_4ign/a.pion" "$TMP_DIR/r17_4ign/b.pion"
out_r17_4ib=$("$TMP_DIR/r17_4ign_hot")
test "$out_r17_4ib" = "2"

cat > "$TMP_DIR/r17_4cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn apply(f : () -> Int) -> Int { f() }
fn relay(f : () -> Int) -> Int { let h = fn() -> Int { f() }; apply(fn() -> Int { h() }) }
let A : Int = relay(read_a)
pub fn main() -> Int { A }
EOF
set +e
r17_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r17_4cyc/main.pion" 2>&1)
r17_4_cyc_rc=$?
set -e
test "$r17_4_cyc_rc" -ne 0
printf '%s' "$r17_4_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R17 independent cold/hot CAS (loop $out_r17_1a->$out_r17_1b, sc $out_r17_2a->$out_r17_2b, swap $out_r17_3a->$out_r17_3b, esc $out_r17_4a->$out_r17_4b/ign $out_r17_4ia->$out_r17_4ib) & apply-cycle (OK)"

echo "=== Wave J1 E2E [16/16]: R18 independent cold/hot CAS for 9-step shift loop, while-cond/SFor, match guard & SLetTuple block/if ==="
# 16a: 9-step shift chain (`f0..f8 -> right`) cold/hot CAS (17 -> 23)
mkdir -p "$TMP_DIR/r18_1" "$TMP_DIR/cas_r18_1"
cat > "$TMP_DIR/r18_1/a.pion" <<'EOF'
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r18_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn go() -> Int {
  let mut f0 = [zero]; let mut f1 = [zero]; let mut f2 = [zero]
  let mut f3 = [zero]; let mut f4 = [zero]; let mut f5 = [zero]
  let mut f6 = [zero]; let mut f7 = [zero]; let mut f8 = [zero]
  let right = [zero]
  let mut i = 0
  while i < 10 {
    f0[0] = read_b
    f0 = f1; f1 = f2; f2 = f3; f3 = f4; f4 = f5; f5 = f6; f6 = f7; f7 = f8; f8 = right
    i = i + 1
  }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_1" "$PIONC" build -o "$TMP_DIR/r18_1_cold" "$TMP_DIR/r18_1/a.pion" "$TMP_DIR/r18_1/b.pion"
out_r18_1a=$("$TMP_DIR/r18_1_cold")
test "$out_r18_1a" = "17"
cat > "$TMP_DIR/r18_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go() -> Int {
  let mut f0 = [zero]; let mut f1 = [zero]; let mut f2 = [zero]
  let mut f3 = [zero]; let mut f4 = [zero]; let mut f5 = [zero]
  let mut f6 = [zero]; let mut f7 = [zero]; let mut f8 = [zero]
  let right = [zero]
  let mut i = 0
  while i < 10 {
    f0[0] = read_b
    f0 = f1; f1 = f2; f2 = f3; f3 = f4; f4 = f5; f5 = f6; f6 = f7; f7 = f8; f8 = right
    i = i + 1
  }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_1" "$PIONC" build -o "$TMP_DIR/r18_1_hot" "$TMP_DIR/r18_1/a.pion" "$TMP_DIR/r18_1/b.pion"
out_r18_1b=$("$TMP_DIR/r18_1_hot")
test "$out_r18_1b" = "23"

# 16b: `while ({ fs[0] = read_b; i < 1 })` + C-style `for let mut fs = left; i < 2; i = i + 1` (19:19 -> 29:29)
mkdir -p "$TMP_DIR/r18_2" "$TMP_DIR/cas_r18_2"
cat > "$TMP_DIR/r18_2/a.pion" <<'EOF'
let A : String = go_wc().to_string() + ":" + go_for().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r18_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 19 }
fn go_wc() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while ({ fs[0] = read_b; i < 1 }) { fs = right; i = i + 1 }
  let f = right[0]
  f()
}
fn go_for() -> Int {
  let left = [zero]
  let right = [zero]
  let mut i = 0
  for let mut fs = left; i < 2; i = i + 1 { fs[0] = read_b; fs = right }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_2" "$PIONC" build -o "$TMP_DIR/r18_2_cold" "$TMP_DIR/r18_2/a.pion" "$TMP_DIR/r18_2/b.pion"
out_r18_2a=$("$TMP_DIR/r18_2_cold")
test "$out_r18_2a" = "19:19"
cat > "$TMP_DIR/r18_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn go_wc() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while ({ fs[0] = read_b; i < 1 }) { fs = right; i = i + 1 }
  let f = right[0]
  f()
}
fn go_for() -> Int {
  let left = [zero]
  let right = [zero]
  let mut i = 0
  for let mut fs = left; i < 2; i = i + 1 { fs[0] = read_b; fs = right }
  let f = right[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_2" "$PIONC" build -o "$TMP_DIR/r18_2_hot" "$TMP_DIR/r18_2/a.pion" "$TMP_DIR/r18_2/b.pion"
out_r18_2b=$("$TMP_DIR/r18_2_hot")
test "$out_r18_2b" = "29:29"

# 16c: `EMatch` guard under `cond_depth` (`flag = false`) cold/hot CAS (31 -> 37)
mkdir -p "$TMP_DIR/r18_3" "$TMP_DIR/cas_r18_3"
cat > "$TMP_DIR/r18_3/a.pion" <<'EOF'
let A : Int = go(false)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r18_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = match flag { true if { fs = right; true } => 1; _ => 0 }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_3" "$PIONC" build -o "$TMP_DIR/r18_3_cold" "$TMP_DIR/r18_3/a.pion" "$TMP_DIR/r18_3/b.pion"
out_r18_3a=$("$TMP_DIR/r18_3_cold")
test "$out_r18_3a" = "31"
cat > "$TMP_DIR/r18_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let _ = match flag { true if { fs = right; true } => 1; _ => 0 }
  let a = fs
  left[0] = read_b
  let f = a[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_3" "$PIONC" build -o "$TMP_DIR/r18_3_hot" "$TMP_DIR/r18_3/a.pion" "$TMP_DIR/r18_3/b.pion"
out_r18_3b=$("$TMP_DIR/r18_3_hot")
test "$out_r18_3b" = "37"

# 16d: `SLetTuple` block & `if` RHS cold/hot CAS (41:41 -> 43:43) + cycle
mkdir -p "$TMP_DIR/r18_4" "$TMP_DIR/cas_r18_4" "$TMP_DIR/r18_4_cyc"
cat > "$TMP_DIR/r18_4/a.pion" <<'EOF'
let A : String = go_blk().to_string() + ":" + go_if(false).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r18_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn go_blk() -> Int { let f = read_b; let (f, g) = { let t = f; (zero, t) }; let _ = f; g() }
fn go_if(flag : Bool) -> Int { let f = read_b; let (f, g) = if flag { (zero, zero) } else { (zero, f) }; let _ = f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_4" "$PIONC" build -o "$TMP_DIR/r18_4_cold" "$TMP_DIR/r18_4/a.pion" "$TMP_DIR/r18_4/b.pion"
out_r18_4a=$("$TMP_DIR/r18_4_cold")
test "$out_r18_4a" = "41:41"
cat > "$TMP_DIR/r18_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn go_blk() -> Int { let f = read_b; let (f, g) = { let t = f; (zero, t) }; let _ = f; g() }
fn go_if(flag : Bool) -> Int { let f = read_b; let (f, g) = if flag { (zero, zero) } else { (zero, f) }; let _ = f; g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_4" "$PIONC" build -o "$TMP_DIR/r18_4_hot" "$TMP_DIR/r18_4/a.pion" "$TMP_DIR/r18_4/b.pion"
out_r18_4b=$("$TMP_DIR/r18_4_hot")
test "$out_r18_4b" = "43:43"

cat > "$TMP_DIR/r18_4_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int { let f = read_a; let (f, g) = { (zero, f) }; let _ = f; g() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r18_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r18_4_cyc/main.pion" 2>&1)
r18_4_cyc_rc=$?
set -e
test "$r18_4_cyc_rc" -ne 0
printf '%s' "$r18_4_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R18 independent cold/hot CAS (shift9 $out_r18_1a->$out_r18_1b, wc/for $out_r18_2a->$out_r18_2b, guard $out_r18_3a->$out_r18_3b, tup $out_r18_4a->$out_r18_4b) & cycle (OK)"

# 16e: R18b pure fn-var shift loop (`f0 = f1; f1 = read_b`) + `SLetTuple` `if`-branch `cond_depth` (47:47 -> 53:53)
mkdir -p "$TMP_DIR/r18_5" "$TMP_DIR/cas_r18_5"
cat > "$TMP_DIR/r18_5/a.pion" <<'EOF'
let A : String = go_fnshift().to_string() + ":" + go_tup_if(false).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r18_5/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 47 }
fn go_fnshift() -> Int {
  let mut f0 = zero
  let mut f1 = zero
  let mut i = 0
  while i < 2 { f0 = f1; f1 = read_b; i = i + 1 }
  f0()
}
fn go_tup_if(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let (_a, _b) = if flag { fs = right; (zero, zero) } else { (zero, zero) }
  let alias = fs
  left[0] = read_b
  let f = alias[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_5" "$PIONC" build -o "$TMP_DIR/r18_5_cold" "$TMP_DIR/r18_5/a.pion" "$TMP_DIR/r18_5/b.pion"
out_r18_5a=$("$TMP_DIR/r18_5_cold")
test "$out_r18_5a" = "47:47"
cat > "$TMP_DIR/r18_5/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 53 }
fn go_fnshift() -> Int {
  let mut f0 = zero
  let mut f1 = zero
  let mut i = 0
  while i < 2 { f0 = f1; f1 = read_b; i = i + 1 }
  f0()
}
fn go_tup_if(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let (_a, _b) = if flag { fs = right; (zero, zero) } else { (zero, zero) }
  let alias = fs
  left[0] = read_b
  let f = alias[0]
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r18_5" "$PIONC" build -o "$TMP_DIR/r18_5_hot" "$TMP_DIR/r18_5/a.pion" "$TMP_DIR/r18_5/b.pion"
out_r18_5b=$("$TMP_DIR/r18_5_hot")
test "$out_r18_5b" = "53:53"
echo "  R18b pure fn-var shift loop + SLetTuple if-branch cond_depth cold/hot CAS ($out_r18_5a -> $out_r18_5b) (OK)"

echo "=== Wave J1 E2E [17/17]: R19 independent cold/hot CAS & cycles for 65-step fallback, loop closure rescan, single-pass SLetTuple & match payload binding ==="
# 17a: 65-step shift chain (f0..f64 -> right, 66-round loop > 64-round cap) independent cold/hot CAS (61 -> 63) + cycle
mkdir -p "$TMP_DIR/r19_1" "$TMP_DIR/cas_r19_1" "$TMP_DIR/r19_1_cyc"
cat > "$TMP_DIR/r19_1/a.pion" <<'EOF'
let A : Int = go()
pub fn main() -> Int { A }
EOF
{
  echo "fn zero() -> Int { 0 }"
  echo "fn read_b() -> Int { B }"
  echo "fn make_b() -> Int { 61 }"
  echo "fn go() -> Int {"
  i=0
  while [ "$i" -lt 65 ]; do
    echo "  let mut f$i = [zero]"
    i=$((i + 1))
  done
  echo "  let right = [zero]"
  echo "  let mut i = 0"
  echo "  while i < 66 {"
  echo "    f0[0] = read_b"
  i=0
  while [ "$i" -lt 64 ]; do
    echo "    f$i = f$((i + 1))"
    i=$((i + 1))
  done
  echo "    f64 = right"
  echo "    i = i + 1"
  echo "  }"
  echo "  right[0]()"
  echo "}"
  echo "let B : Int = make_b()"
} > "$TMP_DIR/r19_1/b.pion"
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$TMP_DIR/cas_r19_1" "$PIONC" build --target wasm32 -o "$TMP_DIR/r19_1_cold.wasm" "$TMP_DIR/r19_1/a.pion" "$TMP_DIR/r19_1/b.pion"
  run_wasm "$TMP_DIR/r19_1_cold.wasm" 61
  sed 's/fn make_b() -> Int { 61 }/fn make_b() -> Int { 63 }/' "$TMP_DIR/r19_1/b.pion" > "$TMP_DIR/r19_1/b2.pion"
  mv "$TMP_DIR/r19_1/b2.pion" "$TMP_DIR/r19_1/b.pion"
  PION_CACHE_DIR="$TMP_DIR/cas_r19_1" "$PIONC" build --target wasm32 -o "$TMP_DIR/r19_1_hot.wasm" "$TMP_DIR/r19_1/a.pion" "$TMP_DIR/r19_1/b.pion"
  run_wasm "$TMP_DIR/r19_1_hot.wasm" 63
  r19_shift65_status="shift65 wasm32 61->63"
else
  "$PIONC" check --json "$TMP_DIR/r19_1/a.pion" "$TMP_DIR/r19_1/b.pion" >/dev/null
  r19_shift65_status="shift65 check OK (wasm32 skipped: no node)"
fi

{
  echo "fn zero() -> Int { 0 }"
  echo "fn read_a() -> Int { A }"
  echo "fn go() -> Int {"
  i=0
  while [ "$i" -lt 65 ]; do
    echo "  let mut f$i = [zero]"
    i=$((i + 1))
  done
  echo "  let right = [zero]"
  echo "  let mut i = 0"
  echo "  while i < 66 {"
  echo "    f0[0] = read_a"
  i=0
  while [ "$i" -lt 64 ]; do
    echo "    f$i = f$((i + 1))"
    i=$((i + 1))
  done
  echo "    f64 = right"
  echo "    i = i + 1"
  echo "  }"
  echo "  right[0]()"
  echo "}"
  echo "let A : Int = go()"
  echo "pub fn main() -> Int { A }"
} > "$TMP_DIR/r19_1_cyc/main.pion"
set +e
r19_1_cyc_out=$("$PIONC" check --json "$TMP_DIR/r19_1_cyc/main.pion" 2>&1)
r19_1_cyc_rc=$?
set -e
test "$r19_1_cyc_rc" -ne 0
printf '%s' "$r19_1_cyc_out" | grep -q "E_CONST_CYCLE"

# 17b: closure inside loop capturing loop-varying `a = fs` independent cold/hot CAS (67 -> 71) + cycle
mkdir -p "$TMP_DIR/r19_2" "$TMP_DIR/cas_r19_2" "$TMP_DIR/r19_2_cyc"
cat > "$TMP_DIR/r19_2/a.pion" <<'EOF'
let A : String = go_cb().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r19_2/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 67 }
fn go_cb() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while i < 2 {
    let a = fs
    let install = fn() -> Unit { a[0] = read_b }
    install()
    fs = right
    i = i + 1
  }
  right[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r19_2" "$PIONC" build -o "$TMP_DIR/r19_2_cold" "$TMP_DIR/r19_2/a.pion" "$TMP_DIR/r19_2/b.pion"
out_r19_2a=$("$TMP_DIR/r19_2_cold")
test "$out_r19_2a" = "67"
sed 's/fn make_b() -> Int { 67 }/fn make_b() -> Int { 71 }/' "$TMP_DIR/r19_2/b.pion" > "$TMP_DIR/r19_2/b2.pion"
mv "$TMP_DIR/r19_2/b2.pion" "$TMP_DIR/r19_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r19_2" "$PIONC" build -o "$TMP_DIR/r19_2_hot" "$TMP_DIR/r19_2/a.pion" "$TMP_DIR/r19_2/b.pion"
out_r19_2b=$("$TMP_DIR/r19_2_hot")
test "$out_r19_2b" = "71"

cat > "$TMP_DIR/r19_2_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let mut i = 0
  while i < 2 {
    let a = fs
    let install = fn() -> Unit { a[0] = read_a }
    install()
    fs = right
    i = i + 1
  }
  right[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r19_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r19_2_cyc/main.pion" 2>&1)
r19_2_cyc_rc=$?
set -e
test "$r19_2_cyc_rc" -ne 0
printf '%s' "$r19_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 17c: single-pass `SLetTuple` `{ let old = fs; fs = right; (old, 0) }` independent cold/hot CAS (73 -> 79) + cycle
mkdir -p "$TMP_DIR/r19_3" "$TMP_DIR/cas_r19_3" "$TMP_DIR/r19_3_cyc"
cat > "$TMP_DIR/r19_3/a.pion" <<'EOF'
let A : String = go_tup().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r19_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 73 }
fn go_tup() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let (saved, _n) = { let old = fs; fs = right; (old, 0) }
  let _ = fs
  left[0] = read_b
  saved[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r19_3" "$PIONC" build -o "$TMP_DIR/r19_3_cold" "$TMP_DIR/r19_3/a.pion" "$TMP_DIR/r19_3/b.pion"
out_r19_3a=$("$TMP_DIR/r19_3_cold")
test "$out_r19_3a" = "73"
sed 's/fn make_b() -> Int { 73 }/fn make_b() -> Int { 79 }/' "$TMP_DIR/r19_3/b.pion" > "$TMP_DIR/r19_3/b2.pion"
mv "$TMP_DIR/r19_3/b2.pion" "$TMP_DIR/r19_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r19_3" "$PIONC" build -o "$TMP_DIR/r19_3_hot" "$TMP_DIR/r19_3/a.pion" "$TMP_DIR/r19_3/b.pion"
out_r19_3b=$("$TMP_DIR/r19_3_hot")
test "$out_r19_3b" = "79"

cat > "$TMP_DIR/r19_3_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let mut fs = left
  let (saved, _n) = { let old = fs; fs = right; (old, 0) }
  let _ = fs
  left[0] = read_a
  saved[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r19_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r19_3_cyc/main.pion" 2>&1)
r19_3_cyc_rc=$?
set -e
test "$r19_3_cyc_rc" -ne 0
printf '%s' "$r19_3_cyc_out" | grep -q "E_CONST_CYCLE"

# 17d: direct `match Some(left)` with write-through `dst[0] = read_b; left[0]()` independent cold/hot CAS (83 -> 89) + cycle
mkdir -p "$TMP_DIR/r19_4a" "$TMP_DIR/cas_r19_4a" "$TMP_DIR/r19_4a_cyc"
cat > "$TMP_DIR/r19_4a/a.pion" <<'EOF'
let A : String = go_md().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r19_4a/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 83 }
fn go_md() -> Int {
  let left = [zero]
  let right = [zero]
  let (dst, _n) = match Some(left) { Some(t) => (t, 0), None => (right, 0) }
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r19_4a" "$PIONC" build -o "$TMP_DIR/r19_4a_cold" "$TMP_DIR/r19_4a/a.pion" "$TMP_DIR/r19_4a/b.pion"
out_r19_4aa=$("$TMP_DIR/r19_4a_cold")
test "$out_r19_4aa" = "83"
sed 's/fn make_b() -> Int { 83 }/fn make_b() -> Int { 89 }/' "$TMP_DIR/r19_4a/b.pion" > "$TMP_DIR/r19_4a/b2.pion"
mv "$TMP_DIR/r19_4a/b2.pion" "$TMP_DIR/r19_4a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r19_4a" "$PIONC" build -o "$TMP_DIR/r19_4a_hot" "$TMP_DIR/r19_4a/a.pion" "$TMP_DIR/r19_4a/b.pion"
out_r19_4ab=$("$TMP_DIR/r19_4a_hot")
test "$out_r19_4ab" = "89"

cat > "$TMP_DIR/r19_4a_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let (dst, _n) = match Some(left) { Some(t) => (t, 0), None => (right, 0) }
  dst[0] = read_a
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r19_4a_cyc_out=$("$PIONC" check --json "$TMP_DIR/r19_4a_cyc/main.pion" 2>&1)
r19_4a_cyc_rc=$?
set -e
test "$r19_4a_cyc_rc" -ne 0
printf '%s' "$r19_4a_cyc_out" | grep -q "E_CONST_CYCLE"

# 17e: indirect `let opt = Some(left); match opt { Some(t) => t[0](), None => 0 }` independent cold/hot CAS (91 -> 97) + cycle
mkdir -p "$TMP_DIR/r19_4b" "$TMP_DIR/cas_r19_4b" "$TMP_DIR/r19_4b_cyc"
cat > "$TMP_DIR/r19_4b/a.pion" <<'EOF'
let A : String = go_mi().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r19_4b/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 91 }
fn go_mi() -> Int {
  let left = [zero]
  let opt = Some(left)
  left[0] = read_b
  match opt { Some(t) => t[0](), None => 0 }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r19_4b" "$PIONC" build -o "$TMP_DIR/r19_4b_cold" "$TMP_DIR/r19_4b/a.pion" "$TMP_DIR/r19_4b/b.pion"
out_r19_4ba=$("$TMP_DIR/r19_4b_cold")
test "$out_r19_4ba" = "91"
sed 's/fn make_b() -> Int { 91 }/fn make_b() -> Int { 97 }/' "$TMP_DIR/r19_4b/b.pion" > "$TMP_DIR/r19_4b/b2.pion"
mv "$TMP_DIR/r19_4b/b2.pion" "$TMP_DIR/r19_4b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r19_4b" "$PIONC" build -o "$TMP_DIR/r19_4b_hot" "$TMP_DIR/r19_4b/a.pion" "$TMP_DIR/r19_4b/b.pion"
out_r19_4bb=$("$TMP_DIR/r19_4b_hot")
test "$out_r19_4bb" = "97"

cat > "$TMP_DIR/r19_4b_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let opt = Some(left)
  left[0] = read_a
  match opt { Some(t) => t[0](), None => 0 }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r19_4b_cyc_out=$("$PIONC" check --json "$TMP_DIR/r19_4b_cyc/main.pion" 2>&1)
r19_4b_cyc_rc=$?
set -e
test "$r19_4b_cyc_rc" -ne 0
printf '%s' "$r19_4b_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R19 independent cold/hot CAS ($r19_shift65_status, cb $out_r19_2a->$out_r19_2b, tup $out_r19_3a->$out_r19_3b, match-direct $out_r19_4aa->$out_r19_4ab, match-indirect $out_r19_4ba->$out_r19_4bb) & 5x cycles (OK)"

echo "=== Wave J1 E2E [18/18]: R20 two-phase pat bind, positional payload_evals & if/guard is cond pat bind ==="
# 18a: multi-field shadowing pattern `match (left, right) { (right, dst) => { dst[0] = read_b } }; right[0]()` (71 -> 73) + cycle
mkdir -p "$TMP_DIR/r20_1" "$TMP_DIR/cas_r20_1" "$TMP_DIR/r20_1_cyc"
cat > "$TMP_DIR/r20_1/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 71 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  match (left, right) {
    (right, dst) => {
      let _ = right
      dst[0] = read_b
    }
    _ => ()
  }
  right[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_1" "$PIONC" build -o "$TMP_DIR/r20_1_cold" "$TMP_DIR/r20_1/a.pion" "$TMP_DIR/r20_1/b.pion"
out_r20_1a=$("$TMP_DIR/r20_1_cold")
test "$out_r20_1a" = "71"
sed 's/fn make_b() -> Int { 71 }/fn make_b() -> Int { 73 }/' "$TMP_DIR/r20_1/b.pion" > "$TMP_DIR/r20_1/b2.pion"
mv "$TMP_DIR/r20_1/b2.pion" "$TMP_DIR/r20_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_1" "$PIONC" build -o "$TMP_DIR/r20_1_hot" "$TMP_DIR/r20_1/a.pion" "$TMP_DIR/r20_1/b.pion"
out_r20_1b=$("$TMP_DIR/r20_1_hot")
test "$out_r20_1b" = "73"

cat > "$TMP_DIR/r20_1_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  match (left, right) {
    (right, dst) => {
      let _ = right
      dst[0] = read_a
    }
    _ => ()
  }
  right[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20_1_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_1_cyc/main.pion" 2>&1)
r20_1_cyc_rc=$?
set -e
test "$r20_1_cyc_rc" -ne 0
printf '%s' "$r20_1_cyc_out" | grep -q "E_CONST_CYCLE"

# 18b: positional payload_evals — valid `Pair::Both(left, right)` writing `a[0] = read_a` & calling `b[0]()` returns 0, while `a[0]()` reports E_CONST_CYCLE
mkdir -p "$TMP_DIR/r20_2" "$TMP_DIR/cas_r20_2" "$TMP_DIR/r20_2_cyc"
cat > "$TMP_DIR/r20_2/main.pion" <<'EOF'
enum Pair {
  Both(Array[() -> Int], Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let pair = Pair::Both(left, right)
  match pair {
    Pair::Both(a, b) => {
      a[0] = read_a
      b[0]()
    }
  }
}
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_2" "$PIONC" build -o "$TMP_DIR/r20_2_bin" "$TMP_DIR/r20_2/main.pion"
out_r20_2=$("$TMP_DIR/r20_2_bin")
test "$out_r20_2" = "0"

cat > "$TMP_DIR/r20_2_cyc/main.pion" <<'EOF'
enum Pair {
  Both(Array[() -> Int], Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let pair = Pair::Both(left, right)
  match pair {
    Pair::Both(a, b) => {
      let _ = b
      a[0] = read_a
      a[0]()
    }
  }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_2_cyc/main.pion" 2>&1)
r20_2_cyc_rc=$?
set -e
test "$r20_2_cyc_rc" -ne 0
printf '%s' "$r20_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 18c: `if opt is Some(t)` inside `SLetTuple` independent cold/hot CAS (79 -> 83) + cycle
mkdir -p "$TMP_DIR/r20_3a" "$TMP_DIR/cas_r20_3a" "$TMP_DIR/r20_3a_cyc"
cat > "$TMP_DIR/r20_3a/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_3a/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 79 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let opt = Some(left)
  let (dst, _n) = if opt is Some(t) { (t, 0) } else { (right, 0) }
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_3a" "$PIONC" build -o "$TMP_DIR/r20_3a_cold" "$TMP_DIR/r20_3a/a.pion" "$TMP_DIR/r20_3a/b.pion"
out_r20_3aa=$("$TMP_DIR/r20_3a_cold")
test "$out_r20_3aa" = "79"
sed 's/fn make_b() -> Int { 79 }/fn make_b() -> Int { 83 }/' "$TMP_DIR/r20_3a/b.pion" > "$TMP_DIR/r20_3a/b2.pion"
mv "$TMP_DIR/r20_3a/b2.pion" "$TMP_DIR/r20_3a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_3a" "$PIONC" build -o "$TMP_DIR/r20_3a_hot" "$TMP_DIR/r20_3a/a.pion" "$TMP_DIR/r20_3a/b.pion"
out_r20_3ab=$("$TMP_DIR/r20_3a_hot")
test "$out_r20_3ab" = "83"

cat > "$TMP_DIR/r20_3a_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let opt = Some(left)
  let (dst, _n) = if opt is Some(t) { (t, 0) } else { (right, 0) }
  dst[0] = read_a
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20_3a_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_3a_cyc/main.pion" 2>&1)
r20_3a_cyc_rc=$?
set -e
test "$r20_3a_cyc_rc" -ne 0
printf '%s' "$r20_3a_cyc_out" | grep -q "E_CONST_CYCLE"

# 18d: `guard opt is Some(t)` independent cold/hot CAS (89 -> 97) + cycle
mkdir -p "$TMP_DIR/r20_3b" "$TMP_DIR/cas_r20_3b" "$TMP_DIR/r20_3b_cyc"
cat > "$TMP_DIR/r20_3b/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_3b/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 89 }
fn go() -> Int {
  let left = [zero]
  let opt = Some(left)
  guard opt is Some(t) else { return 0 }
  t[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_3b" "$PIONC" build -o "$TMP_DIR/r20_3b_cold" "$TMP_DIR/r20_3b/a.pion" "$TMP_DIR/r20_3b/b.pion"
out_r20_3ba=$("$TMP_DIR/r20_3b_cold")
test "$out_r20_3ba" = "89"
sed 's/fn make_b() -> Int { 89 }/fn make_b() -> Int { 97 }/' "$TMP_DIR/r20_3b/b.pion" > "$TMP_DIR/r20_3b/b2.pion"
mv "$TMP_DIR/r20_3b/b2.pion" "$TMP_DIR/r20_3b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_3b" "$PIONC" build -o "$TMP_DIR/r20_3b_hot" "$TMP_DIR/r20_3b/a.pion" "$TMP_DIR/r20_3b/b.pion"
out_r20_3bb=$("$TMP_DIR/r20_3b_hot")
test "$out_r20_3bb" = "97"

cat > "$TMP_DIR/r20_3b_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let opt = Some(left)
  guard opt is Some(t) else { return 0 }
  t[0] = read_a
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20_3b_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_3b_cyc/main.pion" 2>&1)
r20_3b_cyc_rc=$?
set -e
test "$r20_3b_cyc_rc" -ne 0
printf '%s' "$r20_3b_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R20 independent cold/hot CAS (shadow-pat $out_r20_1a->$out_r20_1b, pos-payload ok=$out_r20_2, if-is $out_r20_3aa->$out_r20_3ab, guard-is $out_r20_3ba->$out_r20_3bb) & 4x cycles (OK)"

# 18e: Opus (a) indirect tuple match `let p = (left, right); match p { (_a, b) => b[0]() }` (91 -> 97)
mkdir -p "$TMP_DIR/r20_5" "$TMP_DIR/cas_r20_5"
cat > "$TMP_DIR/r20_5/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_5/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 91 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let p = (left, right)
  right[0] = read_b
  match p { (_a, b) => b[0](), _ => 0 }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_5" "$PIONC" build -o "$TMP_DIR/r20_5_cold" "$TMP_DIR/r20_5/a.pion" "$TMP_DIR/r20_5/b.pion"
out_r20_5a=$("$TMP_DIR/r20_5_cold")
test "$out_r20_5a" = "91"
sed 's/fn make_b() -> Int { 91 }/fn make_b() -> Int { 97 }/' "$TMP_DIR/r20_5/b.pion" > "$TMP_DIR/r20_5/b2.pion"
mv "$TMP_DIR/r20_5/b2.pion" "$TMP_DIR/r20_5/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_5" "$PIONC" build -o "$TMP_DIR/r20_5_hot" "$TMP_DIR/r20_5/a.pion" "$TMP_DIR/r20_5/b.pion"
out_r20_5b=$("$TMP_DIR/r20_5_hot")
test "$out_r20_5b" = "97"

# 18f: Opus (b) `if opt is Some(t) && t[0]() == ...` cold/hot CAS (1 -> 2) + cycle
mkdir -p "$TMP_DIR/r20_6" "$TMP_DIR/cas_r20_6" "$TMP_DIR/r20_6_cyc"
cat > "$TMP_DIR/r20_6/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_6/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 1 }
fn go() -> Int {
  let left = [zero]
  let opt = Some(left)
  left[0] = read_b
  if opt is Some(t) && t[0]() == 1 { 1 } else { 2 }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_6" "$PIONC" build -o "$TMP_DIR/r20_6_cold" "$TMP_DIR/r20_6/a.pion" "$TMP_DIR/r20_6/b.pion"
out_r20_6a=$("$TMP_DIR/r20_6_cold")
test "$out_r20_6a" = "1"
sed 's/fn make_b() -> Int { 1 }/fn make_b() -> Int { 2 }/' "$TMP_DIR/r20_6/b.pion" > "$TMP_DIR/r20_6/b2.pion"
mv "$TMP_DIR/r20_6/b2.pion" "$TMP_DIR/r20_6/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_6" "$PIONC" build -o "$TMP_DIR/r20_6_hot" "$TMP_DIR/r20_6/a.pion" "$TMP_DIR/r20_6/b.pion"
out_r20_6b=$("$TMP_DIR/r20_6_hot")
test "$out_r20_6b" = "2"

cat > "$TMP_DIR/r20_6_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let opt = Some(left)
  left[0] = read_a
  if opt is Some(t) && t[0]() == 0 { 1 } else { 0 }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20_6_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_6_cyc/main.pion" 2>&1)
r20_6_cyc_rc=$?
set -e
test "$r20_6_cyc_rc" -ne 0
printf '%s' "$r20_6_cyc_out" | grep -q "E_CONST_CYCLE"

# 18g: Opus (c) `let opt = if flag { Some(left) } else { None }; match opt { Some(t) => t[0](), None => 0 }` cold/hot CAS (101 -> 103) + cycle
mkdir -p "$TMP_DIR/r20_7" "$TMP_DIR/cas_r20_7" "$TMP_DIR/r20_7_cyc"
cat > "$TMP_DIR/r20_7/a.pion" <<'EOF'
let A : String = go(true).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20_7/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 101 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let opt = if flag { Some(left) } else { None }
  left[0] = read_b
  match opt { Some(t) => t[0](), None => 0 }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20_7" "$PIONC" build -o "$TMP_DIR/r20_7_cold" "$TMP_DIR/r20_7/a.pion" "$TMP_DIR/r20_7/b.pion"
out_r20_7a=$("$TMP_DIR/r20_7_cold")
test "$out_r20_7a" = "101"
sed 's/fn make_b() -> Int { 101 }/fn make_b() -> Int { 103 }/' "$TMP_DIR/r20_7/b.pion" > "$TMP_DIR/r20_7/b2.pion"
mv "$TMP_DIR/r20_7/b2.pion" "$TMP_DIR/r20_7/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20_7" "$PIONC" build -o "$TMP_DIR/r20_7_hot" "$TMP_DIR/r20_7/a.pion" "$TMP_DIR/r20_7/b.pion"
out_r20_7b=$("$TMP_DIR/r20_7_hot")
test "$out_r20_7b" = "103"

cat > "$TMP_DIR/r20_7_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let opt = if flag { Some(left) } else { None }
  left[0] = read_a
  match opt { Some(t) => t[0](), None => 0 }
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r20_7_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20_7_cyc/main.pion" 2>&1)
r20_7_cyc_rc=$?
set -e
test "$r20_7_cyc_rc" -ne 0
printf '%s' "$r20_7_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R20 Opus additions cold/hot CAS (tup-match $out_r20_5a->$out_r20_5b, and-is $out_r20_6a->$out_r20_6b, if-ctor $out_r20_7a->$out_r20_7b) & 2x cycles (OK)"

echo "=== Wave J1 E2E [19/19]: R20b ground-truth ctor_call & cslot_unknown write/method propagation ==="
# 19a: PascalCase fn / closure const / static method calls must report E_CONST_CYCLE
mkdir -p "$TMP_DIR/r20b_1a" "$TMP_DIR/r20b_1b" "$TMP_DIR/r20b_1c"
cat > "$TMP_DIR/r20b_1a/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn Mutate(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go() -> Int {
  let left = [zero]
  Mutate(left)
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20b_1a_out=$("$PIONC" check --json "$TMP_DIR/r20b_1a/main.pion" 2>&1)
r20b_1a_rc=$?
set -e
test "$r20b_1a_rc" -ne 0
printf '%s' "$r20b_1a_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r20b_1b/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let Wrap : (Array[() -> Int]) -> Unit = fn(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go() -> Int {
  let left = [zero]
  Wrap(left)
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20b_1b_out=$("$PIONC" check --json "$TMP_DIR/r20b_1b/main.pion" 2>&1)
r20b_1b_rc=$?
set -e
test "$r20b_1b_rc" -ne 0
printf '%s' "$r20b_1b_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r20b_1c/main.pion" <<'EOF'
struct S { x : Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn S::Mutate(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go() -> Int {
  let left = [zero]
  S::Mutate(left)
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20b_1c_out=$("$PIONC" check --json "$TMP_DIR/r20b_1c/main.pion" 2>&1)
r20b_1c_rc=$?
set -e
test "$r20b_1c_rc" -ne 0
printf '%s' "$r20b_1c_out" | grep -q "E_CONST_CYCLE"

# 19b: Single-letter variant `enum E { V(...) }` positional ok=0 + cycle
mkdir -p "$TMP_DIR/r20b_2" "$TMP_DIR/cas_r20b_2" "$TMP_DIR/r20b_2_cyc"
cat > "$TMP_DIR/r20b_2/main.pion" <<'EOF'
enum E {
  V(Array[() -> Int], Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let e = V(left, right)
  match e {
    V(a, b) => {
      a[0] = read_a
      b[0]()
    }
  }
}
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20b_2" "$PIONC" build -o "$TMP_DIR/r20b_2_bin" "$TMP_DIR/r20b_2/main.pion"
out_r20b_2=$("$TMP_DIR/r20b_2_bin")
test "$out_r20b_2" = "0"

cat > "$TMP_DIR/r20b_2_cyc/main.pion" <<'EOF'
enum E {
  V(Array[() -> Int], Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let e = V(left, right)
  match e {
    V(a, b) => {
      let _ = b
      a[0] = read_a
      a[0]()
    }
  }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r20b_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20b_2_cyc/main.pion" 2>&1)
r20b_2_cyc_rc=$?
set -e
test "$r20b_2_cyc_rc" -ne 0
printf '%s' "$r20b_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 19c: `cslot_unknown` index write & `.push(...)` through `if flag { Some(left) } else { None }` + `let dst = if flag { left } else { right }` cold/hot CAS (107 -> 109) + cycles
mkdir -p "$TMP_DIR/r20b_3" "$TMP_DIR/r20b_4" "$TMP_DIR/r20b_5" "$TMP_DIR/cas_r20b_5" "$TMP_DIR/r20b_5_cyc"
cat > "$TMP_DIR/r20b_3/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let opt = if flag { Some(left) } else { None }
  match opt {
    Some(dst) => { dst[0] = read_a }
    None => ()
  }
  left[0]()
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r20b_3_out=$("$PIONC" check --json "$TMP_DIR/r20b_3/main.pion" 2>&1)
r20b_3_rc=$?
set -e
test "$r20b_3_rc" -ne 0
printf '%s' "$r20b_3_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r20b_4/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let opt = if flag { Some(left) } else { None }
  match opt {
    Some(dst) => { dst.push(read_a) }
    None => ()
  }
  left[1]()
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r20b_4_out=$("$PIONC" check --json "$TMP_DIR/r20b_4/main.pion" 2>&1)
r20b_4_rc=$?
set -e
test "$r20b_4_rc" -ne 0
printf '%s' "$r20b_4_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r20b_5/a.pion" <<'EOF'
let A : String = go(true).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r20b_5/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 107 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let dst = if flag { left } else { right }
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r20b_5" "$PIONC" build -o "$TMP_DIR/r20b_5_cold" "$TMP_DIR/r20b_5/a.pion" "$TMP_DIR/r20b_5/b.pion"
out_r20b_5a=$("$TMP_DIR/r20b_5_cold")
test "$out_r20b_5a" = "107"
sed 's/fn make_b() -> Int { 107 }/fn make_b() -> Int { 109 }/' "$TMP_DIR/r20b_5/b.pion" > "$TMP_DIR/r20b_5/b2.pion"
mv "$TMP_DIR/r20b_5/b2.pion" "$TMP_DIR/r20b_5/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r20b_5" "$PIONC" build -o "$TMP_DIR/r20b_5_hot" "$TMP_DIR/r20b_5/a.pion" "$TMP_DIR/r20b_5/b.pion"
out_r20b_5b=$("$TMP_DIR/r20b_5_hot")
test "$out_r20b_5b" = "109"

cat > "$TMP_DIR/r20b_5_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let dst = if flag { left } else { right }
  dst[0] = read_a
  left[0]()
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r20b_5_cyc_out=$("$PIONC" check --json "$TMP_DIR/r20b_5_cyc/main.pion" 2>&1)
r20b_5_cyc_rc=$?
set -e
test "$r20b_5_cyc_rc" -ne 0
printf '%s' "$r20b_5_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R20b ground-truth ctor_call & cslot_unknown (1char-var ok=$out_r20b_2, if-dst $out_r20b_5a->$out_r20b_5b) & 7x cycles (OK)"

echo "=== Wave J1 E2E [20/20]: R21 hot/cold custom ctor consistency, Factory::V, SLetTuple ident, extract_callable if/match & precise branch cslots ==="
# 20a: Opus hot/cold dual-file custom enum ctor consistency: Wrap(arr), Pair::Both(left, right), Wrap(read_b)
mkdir -p "$TMP_DIR/r21_1a" "$TMP_DIR/cas_r21_1a" "$TMP_DIR/r21_1a_cyc"
cat > "$TMP_DIR/r21_1a/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_1a/b.pion" <<'EOF'
enum W {
  Wrap(Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn go() -> Int {
  let arr = [zero]
  let w = Wrap(arr)
  arr[0] = read_b
  match w { Wrap(t) => t[0]() }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_1a" "$PIONC" build -o "$TMP_DIR/r21_1a_cold" "$TMP_DIR/r21_1a/a.pion" "$TMP_DIR/r21_1a/b.pion"
out_r21_1aa=$("$TMP_DIR/r21_1a_cold")
test "$out_r21_1aa" = "7"
printf '\n// comment touch for hot incremental rebuild\n' >> "$TMP_DIR/r21_1a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_1a" "$PIONC" build -o "$TMP_DIR/r21_1a_hot" "$TMP_DIR/r21_1a/a.pion" "$TMP_DIR/r21_1a/b.pion"
out_r21_1ab=$("$TMP_DIR/r21_1a_hot")
test "$out_r21_1ab" = "7"

cat > "$TMP_DIR/r21_1a_cyc/main.pion" <<'EOF'
enum W {
  Wrap(Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let arr = [zero]
  let w = Wrap(arr)
  arr[0] = read_a
  match w { Wrap(t) => t[0]() }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r21_1a_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_1a_cyc/main.pion" 2>&1)
r21_1a_cyc_rc=$?
set -e
test "$r21_1a_cyc_rc" -ne 0
printf '%s' "$r21_1a_cyc_out" | grep -q "E_CONST_CYCLE"

mkdir -p "$TMP_DIR/r21_1b" "$TMP_DIR/cas_r21_1b"
cat > "$TMP_DIR/r21_1b/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_1b/b.pion" <<'EOF'
enum Pair {
  Both(Array[() -> Int], Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A.length() }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let pair = Pair::Both(left, right)
  match pair {
    Pair::Both(a, b) => {
      a[0] = read_a
      b[0]()
    }
  }
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_1b" "$PIONC" build -o "$TMP_DIR/r21_1b_cold" "$TMP_DIR/r21_1b/a.pion" "$TMP_DIR/r21_1b/b.pion"
out_r21_1ba=$("$TMP_DIR/r21_1b_cold")
test "$out_r21_1ba" = "0"
printf '\n// comment touch for hot incremental rebuild\n' >> "$TMP_DIR/r21_1b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_1b" "$PIONC" build -o "$TMP_DIR/r21_1b_hot" "$TMP_DIR/r21_1b/a.pion" "$TMP_DIR/r21_1b/b.pion"
out_r21_1bb=$("$TMP_DIR/r21_1b_hot")
test "$out_r21_1bb" = "0"

mkdir -p "$TMP_DIR/r21_1c" "$TMP_DIR/cas_r21_1c"
cat > "$TMP_DIR/r21_1c/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_1c/b.pion" <<'EOF'
enum FWrap {
  Wrap(() -> Int)
}
fn read_b() -> Int { B }
fn make_b() -> Int { 13 }
fn go() -> Int {
  let w = Wrap(read_b)
  match w { Wrap(f) => f() }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_1c" "$PIONC" build -o "$TMP_DIR/r21_1c_cold" "$TMP_DIR/r21_1c/a.pion" "$TMP_DIR/r21_1c/b.pion"
out_r21_1ca=$("$TMP_DIR/r21_1c_cold")
test "$out_r21_1ca" = "13"
sed 's/fn make_b() -> Int { 13 }/fn make_b() -> Int { 17 }/' "$TMP_DIR/r21_1c/b.pion" > "$TMP_DIR/r21_1c/b2.pion"
mv "$TMP_DIR/r21_1c/b2.pion" "$TMP_DIR/r21_1c/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_1c" "$PIONC" build -o "$TMP_DIR/r21_1c_hot" "$TMP_DIR/r21_1c/a.pion" "$TMP_DIR/r21_1c/b.pion"
out_r21_1cb=$("$TMP_DIR/r21_1c_hot")
test "$out_r21_1cb" = "17"

# 20b: Astra #1 `Factory::V(left, right)` returning `E::V(right)` cold/hot CAS (19 -> 21) + cycle
mkdir -p "$TMP_DIR/r21_2" "$TMP_DIR/cas_r21_2" "$TMP_DIR/r21_2_cyc"
cat > "$TMP_DIR/r21_2/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_2/b.pion" <<'EOF'
enum E {
  V(Array[() -> Int])
}
struct Factory { x : Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 19 }
fn Factory::V(_l : Array[() -> Int], r : Array[() -> Int]) -> E { E::V(r) }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  match Factory::V(left, right) {
    V(dst) => { dst[0] = read_b }
  }
  right[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_2" "$PIONC" build -o "$TMP_DIR/r21_2_cold" "$TMP_DIR/r21_2/a.pion" "$TMP_DIR/r21_2/b.pion"
out_r21_2a=$("$TMP_DIR/r21_2_cold")
test "$out_r21_2a" = "19"
sed 's/fn make_b() -> Int { 19 }/fn make_b() -> Int { 21 }/' "$TMP_DIR/r21_2/b.pion" > "$TMP_DIR/r21_2/b2.pion"
mv "$TMP_DIR/r21_2/b2.pion" "$TMP_DIR/r21_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_2" "$PIONC" build -o "$TMP_DIR/r21_2_hot" "$TMP_DIR/r21_2/a.pion" "$TMP_DIR/r21_2/b.pion"
out_r21_2b=$("$TMP_DIR/r21_2_hot")
test "$out_r21_2b" = "21"

cat > "$TMP_DIR/r21_2_cyc/main.pion" <<'EOF'
enum E {
  V(Array[() -> Int])
}
struct Factory { x : Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn Factory::V(_l : Array[() -> Int], r : Array[() -> Int]) -> E { E::V(r) }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  match Factory::V(left, right) {
    V(dst) => { dst[0] = read_a }
  }
  right[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r21_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_2_cyc/main.pion" 2>&1)
r21_2_cyc_rc=$?
set -e
test "$r21_2_cyc_rc" -ne 0
printf '%s' "$r21_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 20c: Astra #2 `let p = (left, right); let (dst, _u) = p; dst[0] = read_b; left[0]()` cold/hot CAS (23 -> 25) + cycle
mkdir -p "$TMP_DIR/r21_3" "$TMP_DIR/cas_r21_3" "$TMP_DIR/r21_3_cyc"
cat > "$TMP_DIR/r21_3/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let p = (left, right)
  let (dst, _u) = p
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_3" "$PIONC" build -o "$TMP_DIR/r21_3_cold" "$TMP_DIR/r21_3/a.pion" "$TMP_DIR/r21_3/b.pion"
out_r21_3a=$("$TMP_DIR/r21_3_cold")
test "$out_r21_3a" = "23"
sed 's/fn make_b() -> Int { 23 }/fn make_b() -> Int { 25 }/' "$TMP_DIR/r21_3/b.pion" > "$TMP_DIR/r21_3/b2.pion"
mv "$TMP_DIR/r21_3/b2.pion" "$TMP_DIR/r21_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_3" "$PIONC" build -o "$TMP_DIR/r21_3_hot" "$TMP_DIR/r21_3/a.pion" "$TMP_DIR/r21_3/b.pion"
out_r21_3b=$("$TMP_DIR/r21_3_hot")
test "$out_r21_3b" = "25"

cat > "$TMP_DIR/r21_3_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let right = [zero]
  let p = (left, right)
  let (dst, _u) = p
  dst[0] = read_a
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r21_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_3_cyc/main.pion" 2>&1)
r21_3_cyc_rc=$?
set -e
test "$r21_3_cyc_rc" -ne 0
printf '%s' "$r21_3_cyc_out" | grep -q "E_CONST_CYCLE"

# 20d: Astra #3 `let f = match opt { Some(t) => t, None => zero }; f()` & `if opt is Some(t) { t } else { zero }; f()` cold/hot CAS (29 -> 31, 37 -> 41) + nocall + cycles
mkdir -p "$TMP_DIR/r21_4m" "$TMP_DIR/cas_r21_4m" "$TMP_DIR/r21_4i" "$TMP_DIR/cas_r21_4i" "$TMP_DIR/r21_4_cyc"
cat > "$TMP_DIR/r21_4m/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_4m/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 29 }
fn go() -> Int {
  let opt = Some(read_b)
  let f = match opt { Some(t) => t, None => zero }
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_4m" "$PIONC" build -o "$TMP_DIR/r21_4m_cold" "$TMP_DIR/r21_4m/a.pion" "$TMP_DIR/r21_4m/b.pion"
out_r21_4ma=$("$TMP_DIR/r21_4m_cold")
test "$out_r21_4ma" = "29"
sed 's/fn make_b() -> Int { 29 }/fn make_b() -> Int { 31 }/' "$TMP_DIR/r21_4m/b.pion" > "$TMP_DIR/r21_4m/b2.pion"
mv "$TMP_DIR/r21_4m/b2.pion" "$TMP_DIR/r21_4m/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_4m" "$PIONC" build -o "$TMP_DIR/r21_4m_hot" "$TMP_DIR/r21_4m/a.pion" "$TMP_DIR/r21_4m/b.pion"
out_r21_4mb=$("$TMP_DIR/r21_4m_hot")
test "$out_r21_4mb" = "31"

cat > "$TMP_DIR/r21_4i/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_4i/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn go() -> Int {
  let opt = Some(read_b)
  let f = if opt is Some(t) { t } else { zero }
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_4i" "$PIONC" build -o "$TMP_DIR/r21_4i_cold" "$TMP_DIR/r21_4i/a.pion" "$TMP_DIR/r21_4i/b.pion"
out_r21_4ia=$("$TMP_DIR/r21_4i_cold")
test "$out_r21_4ia" = "37"
sed 's/fn make_b() -> Int { 37 }/fn make_b() -> Int { 41 }/' "$TMP_DIR/r21_4i/b.pion" > "$TMP_DIR/r21_4i/b2.pion"
mv "$TMP_DIR/r21_4i/b2.pion" "$TMP_DIR/r21_4i/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_4i" "$PIONC" build -o "$TMP_DIR/r21_4i_hot" "$TMP_DIR/r21_4i/a.pion" "$TMP_DIR/r21_4i/b.pion"
out_r21_4ib=$("$TMP_DIR/r21_4i_hot")
test "$out_r21_4ib" = "41"

cat > "$TMP_DIR/r21_4_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let opt = Some(read_a)
  let f = if opt is Some(t) { t } else { zero }
  f()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r21_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_4_cyc/main.pion" 2>&1)
r21_4_cyc_rc=$?
set -e
test "$r21_4_cyc_rc" -ne 0
printf '%s' "$r21_4_cyc_out" | grep -q "E_CONST_CYCLE"

# 20e: Astra #4 precise branch cslots (`third[0]()` ok=0, `install(dst)` cold/hot 43->47 + cycle, opaque `pick(left)` cycle)
mkdir -p "$TMP_DIR/r21_5a" "$TMP_DIR/cas_r21_5a" "$TMP_DIR/r21_5b" "$TMP_DIR/cas_r21_5b" "$TMP_DIR/r21_5b_cyc" "$TMP_DIR/r21_5c_cyc"
cat > "$TMP_DIR/r21_5a/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let third = [zero]
  let dst = if flag { left } else { right }
  dst[0] = read_a
  third[0]()
}
let A : Int = go(true)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_5a" "$PIONC" build -o "$TMP_DIR/r21_5a_bin" "$TMP_DIR/r21_5a/main.pion"
out_r21_5a=$("$TMP_DIR/r21_5a_bin")
test "$out_r21_5a" = "0"

cat > "$TMP_DIR/r21_5b/a.pion" <<'EOF'
let A : String = go(true).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r21_5b/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 43 }
fn install(a : Array[() -> Int]) -> Unit { a[0] = read_b }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let dst = if flag { left } else { right }
  install(dst)
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r21_5b" "$PIONC" build -o "$TMP_DIR/r21_5b_cold" "$TMP_DIR/r21_5b/a.pion" "$TMP_DIR/r21_5b/b.pion"
out_r21_5ba=$("$TMP_DIR/r21_5b_cold")
test "$out_r21_5ba" = "43"
sed 's/fn make_b() -> Int { 43 }/fn make_b() -> Int { 47 }/' "$TMP_DIR/r21_5b/b.pion" > "$TMP_DIR/r21_5b/b2.pion"
mv "$TMP_DIR/r21_5b/b2.pion" "$TMP_DIR/r21_5b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r21_5b" "$PIONC" build -o "$TMP_DIR/r21_5b_hot" "$TMP_DIR/r21_5b/a.pion" "$TMP_DIR/r21_5b/b.pion"
out_r21_5bb=$("$TMP_DIR/r21_5b_hot")
test "$out_r21_5bb" = "47"

cat > "$TMP_DIR/r21_5b_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let dst = if flag { left } else { right }
  install(dst)
  left[0]()
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r21_5b_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_5b_cyc/main.pion" 2>&1)
r21_5b_cyc_rc=$?
set -e
test "$r21_5b_cyc_rc" -ne 0
printf '%s' "$r21_5b_cyc_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r21_5c_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn pick(x : Array[() -> Int]) -> Array[() -> Int] { x }
fn go() -> Int {
  let left = [zero]
  let t = pick(left)
  t[0] = read_a
  left[0]()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r21_5c_cyc_out=$("$PIONC" check --json "$TMP_DIR/r21_5c_cyc/main.pion" 2>&1)
r21_5c_cyc_rc=$?
set -e
test "$r21_5c_cyc_rc" -ne 0
printf '%s' "$r21_5c_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R21 cold/hot CAS (wrap $out_r21_1aa->$out_r21_1ab, pair $out_r21_1ba->$out_r21_1bb, fwrap $out_r21_1ca->$out_r21_1cb, factory $out_r21_2a->$out_r21_2b, tup-id $out_r21_3a->$out_r21_3b, match-f $out_r21_4ma->$out_r21_4mb, if-f $out_r21_4ia->$out_r21_4ib, third=$out_r21_5a, install $out_r21_5ba->$out_r21_5bb) & 6x cycles (OK)"

echo "=== Wave J1 E2E [21/21]: R22 lowercase enum ctor?: fallback, Array::new cslot, branch call-arg, extract_callable cond_depth & block SLetTuple/SGuard ==="
# 21a: Lowercase enum variants `wrap(arr)`, `Box::wrap(arr)`, `FWrap::wrap(read_b)` cold/hot CAS + cycles
mkdir -p "$TMP_DIR/r22_1a" "$TMP_DIR/cas_r22_1a" "$TMP_DIR/r22_1b" "$TMP_DIR/cas_r22_1b" "$TMP_DIR/r22_1_cyc"
cat > "$TMP_DIR/r22_1a/a.pion" <<'EOF'
let A : String = go1().to_string() + ":" + go2().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_1a/b.pion" <<'EOF'
enum Box {
  wrap(Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 11 }
fn go1() -> Int {
  let arr = [zero]
  let w = wrap(arr)
  arr[0] = read_b
  match w { wrap(t) => t[0]() }
}
fn go2() -> Int {
  let arr = [zero]
  let w = Box::wrap(arr)
  arr[0] = read_b
  match w { Box::wrap(t) => t[0]() }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_1a" "$PIONC" build -o "$TMP_DIR/r22_1a_cold" "$TMP_DIR/r22_1a/a.pion" "$TMP_DIR/r22_1a/b.pion"
out_r22_1aa=$("$TMP_DIR/r22_1a_cold")
test "$out_r22_1aa" = "11:11"
sed 's/fn make_b() -> Int { 11 }/fn make_b() -> Int { 13 }/' "$TMP_DIR/r22_1a/b.pion" > "$TMP_DIR/r22_1a/b2.pion"
mv "$TMP_DIR/r22_1a/b2.pion" "$TMP_DIR/r22_1a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_1a" "$PIONC" build -o "$TMP_DIR/r22_1a_hot" "$TMP_DIR/r22_1a/a.pion" "$TMP_DIR/r22_1a/b.pion"
out_r22_1ab=$("$TMP_DIR/r22_1a_hot")
test "$out_r22_1ab" = "13:13"

cat > "$TMP_DIR/r22_1b/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_1b/b.pion" <<'EOF'
enum FWrap {
  wrap(() -> Int)
}
fn read_b() -> Int { B }
fn make_b() -> Int { 17 }
fn go() -> Int {
  let w = FWrap::wrap(read_b)
  match w { FWrap::wrap(f) => f() }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_1b" "$PIONC" build -o "$TMP_DIR/r22_1b_cold" "$TMP_DIR/r22_1b/a.pion" "$TMP_DIR/r22_1b/b.pion"
out_r22_1ba=$("$TMP_DIR/r22_1b_cold")
test "$out_r22_1ba" = "17"
sed 's/fn make_b() -> Int { 17 }/fn make_b() -> Int { 19 }/' "$TMP_DIR/r22_1b/b.pion" > "$TMP_DIR/r22_1b/b2.pion"
mv "$TMP_DIR/r22_1b/b2.pion" "$TMP_DIR/r22_1b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_1b" "$PIONC" build -o "$TMP_DIR/r22_1b_hot" "$TMP_DIR/r22_1b/a.pion" "$TMP_DIR/r22_1b/b.pion"
out_r22_1bb=$("$TMP_DIR/r22_1b_hot")
test "$out_r22_1bb" = "19"

cat > "$TMP_DIR/r22_1_cyc/main.pion" <<'EOF'
enum Box {
  wrap(Array[() -> Int])
}
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let arr = [zero]
  let w = Box::wrap(arr)
  arr[0] = read_a
  match w { Box::wrap(t) => t[0]() }
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r22_1_cyc_out=$("$PIONC" check --json "$TMP_DIR/r22_1_cyc/main.pion" 2>&1)
r22_1_cyc_rc=$?
set -e
test "$r22_1_cyc_rc" -ne 0
printf '%s' "$r22_1_cyc_out" | grep -q "E_CONST_CYCLE"

# 21b: Fresh `Array::new()` no false cycle on unrelated `left`
mkdir -p "$TMP_DIR/r22_2" "$TMP_DIR/cas_r22_2"
cat > "$TMP_DIR/r22_2/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let left = [zero]
  let out : Array[() -> Int] = Array::new()
  out.push(read_a)
  left[0]()
}
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_2" "$PIONC" build -o "$TMP_DIR/r22_2_bin" "$TMP_DIR/r22_2/main.pion"
out_r22_2=$("$TMP_DIR/r22_2_bin")
test "$out_r22_2" = "0"

# 21c: Direct branch call-arg `install(if flag { left } else { right })` cold/hot (31 -> 33), `third[0]()` ok=0, + cycle
mkdir -p "$TMP_DIR/r22_3" "$TMP_DIR/cas_r22_3" "$TMP_DIR/r22_3t" "$TMP_DIR/cas_r22_3t" "$TMP_DIR/r22_3_cyc"
cat > "$TMP_DIR/r22_3/a.pion" <<'EOF'
let A : String = go(true).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_3/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 31 }
fn install(a : Array[() -> Int]) -> Unit { a[0] = read_b }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  install(if flag { left } else { right })
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_3" "$PIONC" build -o "$TMP_DIR/r22_3_cold" "$TMP_DIR/r22_3/a.pion" "$TMP_DIR/r22_3/b.pion"
out_r22_3a=$("$TMP_DIR/r22_3_cold")
test "$out_r22_3a" = "31"
sed 's/fn make_b() -> Int { 31 }/fn make_b() -> Int { 33 }/' "$TMP_DIR/r22_3/b.pion" > "$TMP_DIR/r22_3/b2.pion"
mv "$TMP_DIR/r22_3/b2.pion" "$TMP_DIR/r22_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_3" "$PIONC" build -o "$TMP_DIR/r22_3_hot" "$TMP_DIR/r22_3/a.pion" "$TMP_DIR/r22_3/b.pion"
out_r22_3b=$("$TMP_DIR/r22_3_hot")
test "$out_r22_3b" = "33"

cat > "$TMP_DIR/r22_3t/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let third = [zero]
  install(if flag { left } else { right })
  third[0]()
}
let A : Int = go(true)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_3t" "$PIONC" build -o "$TMP_DIR/r22_3t_bin" "$TMP_DIR/r22_3t/main.pion"
out_r22_3t=$("$TMP_DIR/r22_3t_bin")
test "$out_r22_3t" = "0"

cat > "$TMP_DIR/r22_3_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn install(a : Array[() -> Int]) -> Unit { a[0] = read_a }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  install(if flag { left } else { right })
  left[0]()
}
let A : Int = go(true)
pub fn main() -> Int { A }
EOF
set +e
r22_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r22_3_cyc/main.pion" 2>&1)
r22_3_cyc_rc=$?
set -e
test "$r22_3_cyc_rc" -ne 0
printf '%s' "$r22_3_cyc_out" | grep -q "E_CONST_CYCLE"

# 21d: Multi-stmt branch `let _n = if flag { dst = right; 1 } else { 0 }` cold/hot (37 -> 39) + cycle
mkdir -p "$TMP_DIR/r22_4" "$TMP_DIR/cas_r22_4" "$TMP_DIR/r22_4_cyc"
cat > "$TMP_DIR/r22_4/a.pion" <<'EOF'
let A : String = go(false).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_4/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 37 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut dst = left
  let _n = if flag { dst = right; 1 } else { 0 }
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_4" "$PIONC" build -o "$TMP_DIR/r22_4_cold" "$TMP_DIR/r22_4/a.pion" "$TMP_DIR/r22_4/b.pion"
out_r22_4a=$("$TMP_DIR/r22_4_cold")
test "$out_r22_4a" = "37"
sed 's/fn make_b() -> Int { 37 }/fn make_b() -> Int { 39 }/' "$TMP_DIR/r22_4/b.pion" > "$TMP_DIR/r22_4/b2.pion"
mv "$TMP_DIR/r22_4/b2.pion" "$TMP_DIR/r22_4/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_4" "$PIONC" build -o "$TMP_DIR/r22_4_hot" "$TMP_DIR/r22_4/a.pion" "$TMP_DIR/r22_4/b.pion"
out_r22_4b=$("$TMP_DIR/r22_4_hot")
test "$out_r22_4b" = "39"

cat > "$TMP_DIR/r22_4_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut dst = left
  let _n = if flag { dst = right; 1 } else { 0 }
  dst[0] = read_a
  left[0]()
}
let A : Int = go(false)
pub fn main() -> Int { A }
EOF
set +e
r22_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r22_4_cyc/main.pion" 2>&1)
r22_4_cyc_rc=$?
set -e
test "$r22_4_cyc_rc" -ne 0
printf '%s' "$r22_4_cyc_out" | grep -q "E_CONST_CYCLE"

# 21e: Block `SLetTuple` & `SGuard is` returning callback cold/hot (41 -> 43, 47 -> 53) + cycles
mkdir -p "$TMP_DIR/r22_5t" "$TMP_DIR/cas_r22_5t" "$TMP_DIR/r22_5g" "$TMP_DIR/cas_r22_5g" "$TMP_DIR/r22_5_cyc"
cat > "$TMP_DIR/r22_5t/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_5t/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn go() -> Int {
  let p = (read_b, zero)
  let f = { let (g, _u) = p; g }
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_5t" "$PIONC" build -o "$TMP_DIR/r22_5t_cold" "$TMP_DIR/r22_5t/a.pion" "$TMP_DIR/r22_5t/b.pion"
out_r22_5ta=$("$TMP_DIR/r22_5t_cold")
test "$out_r22_5ta" = "41"
sed 's/fn make_b() -> Int { 41 }/fn make_b() -> Int { 43 }/' "$TMP_DIR/r22_5t/b.pion" > "$TMP_DIR/r22_5t/b2.pion"
mv "$TMP_DIR/r22_5t/b2.pion" "$TMP_DIR/r22_5t/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_5t" "$PIONC" build -o "$TMP_DIR/r22_5t_hot" "$TMP_DIR/r22_5t/a.pion" "$TMP_DIR/r22_5t/b.pion"
out_r22_5tb=$("$TMP_DIR/r22_5t_hot")
test "$out_r22_5tb" = "43"

cat > "$TMP_DIR/r22_5g/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r22_5g/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 47 }
fn go() -> Int {
  let opt = Some(read_b)
  let f = { guard opt is Some(g) else { return 0 }; g }
  f()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r22_5g" "$PIONC" build -o "$TMP_DIR/r22_5g_cold" "$TMP_DIR/r22_5g/a.pion" "$TMP_DIR/r22_5g/b.pion"
out_r22_5ga=$("$TMP_DIR/r22_5g_cold")
test "$out_r22_5ga" = "47"
sed 's/fn make_b() -> Int { 47 }/fn make_b() -> Int { 53 }/' "$TMP_DIR/r22_5g/b.pion" > "$TMP_DIR/r22_5g/b2.pion"
mv "$TMP_DIR/r22_5g/b2.pion" "$TMP_DIR/r22_5g/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r22_5g" "$PIONC" build -o "$TMP_DIR/r22_5g_hot" "$TMP_DIR/r22_5g/a.pion" "$TMP_DIR/r22_5g/b.pion"
out_r22_5gb=$("$TMP_DIR/r22_5g_hot")
test "$out_r22_5gb" = "53"

cat > "$TMP_DIR/r22_5_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn go() -> Int {
  let opt = Some(read_a)
  let f = { guard opt is Some(g) else { return 0 }; g }
  f()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r22_5_cyc_out=$("$PIONC" check --json "$TMP_DIR/r22_5_cyc/main.pion" 2>&1)
r22_5_cyc_rc=$?
set -e
test "$r22_5_cyc_rc" -ne 0
printf '%s' "$r22_5_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R22 cold/hot CAS (lwrap $out_r22_1aa->$out_r22_1ab, lfwrap $out_r22_1ba->$out_r22_1bb, arr-new=$out_r22_2, br-arg $out_r22_3a->$out_r22_3b/third=$out_r22_3t, cd $out_r22_4a->$out_r22_4b, blk-tup $out_r22_5ta->$out_r22_5tb, blk-guard $out_r22_5ga->$out_r22_5gb) & 4x cycles (OK)"

echo "=== Wave J1 E2E [22/22]: R23 match eval_let cond_depth, Option/Result qualified ctors & Array/FixedArray::make ==="
# 22a: `match flag { true => { dst = right; 1 }, false => 0 }; dst[0] = read_b; left[0]()` cold/hot CAS (23 -> 29) + cycle
mkdir -p "$TMP_DIR/r23_1" "$TMP_DIR/cas_r23_1" "$TMP_DIR/r23_1_cyc"
cat > "$TMP_DIR/r23_1/a.pion" <<'EOF'
let A : String = go(false).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r23_1/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 23 }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut dst = left
  let _n = match flag {
    true => { dst = right; 1 }
    false => 0
  }
  dst[0] = read_b
  left[0]()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r23_1" "$PIONC" build -o "$TMP_DIR/r23_1_cold" "$TMP_DIR/r23_1/a.pion" "$TMP_DIR/r23_1/b.pion"
out_r23_1a=$("$TMP_DIR/r23_1_cold")
test "$out_r23_1a" = "23"
sed 's/fn make_b() -> Int { 23 }/fn make_b() -> Int { 29 }/' "$TMP_DIR/r23_1/b.pion" > "$TMP_DIR/r23_1/b2.pion"
mv "$TMP_DIR/r23_1/b2.pion" "$TMP_DIR/r23_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r23_1" "$PIONC" build -o "$TMP_DIR/r23_1_hot" "$TMP_DIR/r23_1/a.pion" "$TMP_DIR/r23_1/b.pion"
out_r23_1b=$("$TMP_DIR/r23_1_hot")
test "$out_r23_1b" = "29"

cat > "$TMP_DIR/r23_1_cyc/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go(flag : Bool) -> Int {
  let left = [zero]
  let right = [zero]
  let mut dst = left
  let _n = match flag {
    true => { dst = right; 1 }
    false => 0
  }
  dst[0] = read_a
  left[0]()
}
let A : Int = go(false)
pub fn main() -> Int { A }
EOF
set +e
r23_1_cyc_out=$("$PIONC" check --json "$TMP_DIR/r23_1_cyc/main.pion" 2>&1)
r23_1_cyc_rc=$?
set -e
test "$r23_1_cyc_rc" -ne 0
printf '%s' "$r23_1_cyc_out" | grep -q "E_CONST_CYCLE"

# 22b: `Array::make` & `FixedArray::make` — save-only returns 0, `xs[0]()` cold/hot CAS (41:41 -> 43:43) + cycles
mkdir -p "$TMP_DIR/r23_2s" "$TMP_DIR/cas_r23_2s" "$TMP_DIR/r23_2" "$TMP_DIR/cas_r23_2" "$TMP_DIR/r23_2_cyc"
cat > "$TMP_DIR/r23_2s/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn go() -> Int {
  let _xs = Array::make(1, read_a)
  let _ys = FixedArray::make(1, read_a)
  0
}
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r23_2s" "$PIONC" build -o "$TMP_DIR/r23_2s_bin" "$TMP_DIR/r23_2s/main.pion"
out_r23_2s=$("$TMP_DIR/r23_2s_bin")
test "$out_r23_2s" = "0"

cat > "$TMP_DIR/r23_2/a.pion" <<'EOF'
let A : String = go1().to_string() + ":" + go2().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r23_2/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 41 }
fn go1() -> Int { let xs = Array::make(1, read_b); xs[0]() }
fn go2() -> Int { let xs = FixedArray::make(1, read_b); xs[0]() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r23_2" "$PIONC" build -o "$TMP_DIR/r23_2_cold" "$TMP_DIR/r23_2/a.pion" "$TMP_DIR/r23_2/b.pion"
out_r23_2a=$("$TMP_DIR/r23_2_cold")
test "$out_r23_2a" = "41:41"
sed 's/fn make_b() -> Int { 41 }/fn make_b() -> Int { 43 }/' "$TMP_DIR/r23_2/b.pion" > "$TMP_DIR/r23_2/b2.pion"
mv "$TMP_DIR/r23_2/b2.pion" "$TMP_DIR/r23_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r23_2" "$PIONC" build -o "$TMP_DIR/r23_2_hot" "$TMP_DIR/r23_2/a.pion" "$TMP_DIR/r23_2/b.pion"
out_r23_2b=$("$TMP_DIR/r23_2_hot")
test "$out_r23_2b" = "43:43"

cat > "$TMP_DIR/r23_2_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn go() -> Int { let xs = FixedArray::make(1, read_a); xs[0]() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r23_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r23_2_cyc/main.pion" 2>&1)
r23_2_cyc_rc=$?
set -e
test "$r23_2_cyc_rc" -ne 0
printf '%s' "$r23_2_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R23 cold/hot CAS (match-cd $out_r23_1a->$out_r23_1b, make-save=$out_r23_2s, make-call $out_r23_2a->$out_r23_2b) & 2x cycles (OK)"

echo "=== Wave J1 E2E [23/23]: R24 struct fn field push, direct make[0]() & param fill Array/FixedArray::make ==="
# 23a: struct fn field `holder.push(read_b)` cold/hot CAS (53 -> 59) + `holder.push(read_a)` cycle
mkdir -p "$TMP_DIR/r24_1" "$TMP_DIR/cas_r24_1" "$TMP_DIR/r24_1_cyc"
cat > "$TMP_DIR/r24_1/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r24_1/b.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_b() -> Int { B }
fn make_b() -> Int { 53 }
fn go() -> Int {
  let holder = Holder::{ push: invoke }
  holder.push(read_b)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24_1" "$PIONC" build -o "$TMP_DIR/r24_1_cold" "$TMP_DIR/r24_1/a.pion" "$TMP_DIR/r24_1/b.pion"
out_r24_1a=$("$TMP_DIR/r24_1_cold")
test "$out_r24_1a" = "53"
sed 's/fn make_b() -> Int { 53 }/fn make_b() -> Int { 59 }/' "$TMP_DIR/r24_1/b.pion" > "$TMP_DIR/r24_1/b2.pion"
mv "$TMP_DIR/r24_1/b2.pion" "$TMP_DIR/r24_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r24_1" "$PIONC" build -o "$TMP_DIR/r24_1_hot" "$TMP_DIR/r24_1/a.pion" "$TMP_DIR/r24_1/b.pion"
out_r24_1b=$("$TMP_DIR/r24_1_hot")
test "$out_r24_1b" = "59"

cat > "$TMP_DIR/r24_1_cyc/main.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ push: invoke }
  holder.push(read_a)
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r24_1_cyc_out=$("$PIONC" check --json "$TMP_DIR/r24_1_cyc/main.pion" 2>&1)
r24_1_cyc_rc=$?
set -e
test "$r24_1_cyc_rc" -ne 0
printf '%s' "$r24_1_cyc_out" | grep -q "E_CONST_CYCLE"

# 23b: direct `Array::make(1, read_b)[0]()` + `FixedArray::make(1, read_b)[0]()` cold/hot CAS (61:61 -> 67:67) + cycle
mkdir -p "$TMP_DIR/r24_2" "$TMP_DIR/cas_r24_2" "$TMP_DIR/r24_2_cyc"
cat > "$TMP_DIR/r24_2/a.pion" <<'EOF'
let A : String = go1().to_string() + ":" + go2().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r24_2/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 61 }
fn go1() -> Int { Array::make(1, read_b)[0]() }
fn go2() -> Int { FixedArray::make(1, read_b)[0]() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24_2" "$PIONC" build -o "$TMP_DIR/r24_2_cold" "$TMP_DIR/r24_2/a.pion" "$TMP_DIR/r24_2/b.pion"
out_r24_2a=$("$TMP_DIR/r24_2_cold")
test "$out_r24_2a" = "61:61"
sed 's/fn make_b() -> Int { 61 }/fn make_b() -> Int { 67 }/' "$TMP_DIR/r24_2/b.pion" > "$TMP_DIR/r24_2/b2.pion"
mv "$TMP_DIR/r24_2/b2.pion" "$TMP_DIR/r24_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r24_2" "$PIONC" build -o "$TMP_DIR/r24_2_hot" "$TMP_DIR/r24_2/a.pion" "$TMP_DIR/r24_2/b.pion"
out_r24_2b=$("$TMP_DIR/r24_2_hot")
test "$out_r24_2b" = "67:67"

cat > "$TMP_DIR/r24_2_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn go() -> Int { Array::make(1, read_a)[0]() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r24_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r24_2_cyc/main.pion" 2>&1)
r24_2_cyc_rc=$?
set -e
test "$r24_2_cyc_rc" -ne 0
printf '%s' "$r24_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 23c: function param fill `let xs = Array::make(1, f); xs[0]()` — save-only ok (0), call cold/hot CAS (71:71 -> 73:73) + cycle
mkdir -p "$TMP_DIR/r24_3s" "$TMP_DIR/cas_r24_3s" "$TMP_DIR/r24_3" "$TMP_DIR/cas_r24_3" "$TMP_DIR/r24_3_cyc"
cat > "$TMP_DIR/r24_3s/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn stash(f : () -> Int) -> Int {
  let _xs = Array::make(1, f)
  let _ys = FixedArray::make(1, f)
  0
}
let A : Int = stash(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24_3s" "$PIONC" build -o "$TMP_DIR/r24_3s_bin" "$TMP_DIR/r24_3s/main.pion"
out_r24_3s=$("$TMP_DIR/r24_3s_bin")
test "$out_r24_3s" = "0"

cat > "$TMP_DIR/r24_3/a.pion" <<'EOF'
let A : String = invoke1(read_b).to_string() + ":" + invoke2(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r24_3/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 71 }
fn invoke1(f : () -> Int) -> Int { let xs = Array::make(1, f); xs[0]() }
fn invoke2(f : () -> Int) -> Int { let xs = FixedArray::make(1, f); xs[0]() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24_3" "$PIONC" build -o "$TMP_DIR/r24_3_cold" "$TMP_DIR/r24_3/a.pion" "$TMP_DIR/r24_3/b.pion"
out_r24_3a=$("$TMP_DIR/r24_3_cold")
test "$out_r24_3a" = "71:71"
sed 's/fn make_b() -> Int { 71 }/fn make_b() -> Int { 73 }/' "$TMP_DIR/r24_3/b.pion" > "$TMP_DIR/r24_3/b2.pion"
mv "$TMP_DIR/r24_3/b2.pion" "$TMP_DIR/r24_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r24_3" "$PIONC" build -o "$TMP_DIR/r24_3_hot" "$TMP_DIR/r24_3/a.pion" "$TMP_DIR/r24_3/b.pion"
out_r24_3b=$("$TMP_DIR/r24_3_hot")
test "$out_r24_3b" = "73:73"

cat > "$TMP_DIR/r24_3_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn invoke(f : () -> Int) -> Int { let xs = Array::make(1, f); xs[0]() }
let A : Int = invoke(read_a)
pub fn main() -> Int { A }
EOF
set +e
r24_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r24_3_cyc/main.pion" 2>&1)
r24_3_cyc_rc=$?
set -e
test "$r24_3_cyc_rc" -ne 0
printf '%s' "$r24_3_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R24 cold/hot CAS (holder-push $out_r24_1a->$out_r24_1b, make-idx $out_r24_2a->$out_r24_2b, param-save=$out_r24_3s, param-call $out_r24_3a->$out_r24_3b) & 3x cycles (OK)"

echo "=== Wave J1 E2E [24/24]: R24b struct fn field shadowing unrelated method & 0-arg holder.run() / fire(holder) ==="
# 24a: `Other::push` + `Other::run` + `Holder` fn fields cold/hot CAS (79:83 -> 83:89) + 2x cycles
mkdir -p "$TMP_DIR/r24b_1" "$TMP_DIR/cas_r24b_1" "$TMP_DIR/r24b_1_cyc1" "$TMP_DIR/r24b_1_cyc2"
cat > "$TMP_DIR/r24b_1/a.pion" <<'EOF'
let A : String = go_push().to_string() + ":" + go_run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r24b_1/b.pion" <<'EOF'
struct Other { x : Int }
fn Other::push(self : Other, v : Int) -> Int { v }
fn Other::run(self : Other, v : Int) -> Int { v }
struct HolderPush { push : (() -> Int) -> Int }
struct HolderRun { run : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_b() -> Int { B }
fn make_b() -> Int { 79 }
fn go_push() -> Int {
  let holder = HolderPush::{ push: invoke }
  holder.push(read_b)
}
fn go_run() -> Int {
  let holder = HolderRun::{ run: invoke }
  holder.run(read_b)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24b_1" "$PIONC" build -o "$TMP_DIR/r24b_1_cold" "$TMP_DIR/r24b_1/a.pion" "$TMP_DIR/r24b_1/b.pion"
out_r24b_1a=$("$TMP_DIR/r24b_1_cold")
test "$out_r24b_1a" = "79:79"
sed 's/fn make_b() -> Int { 79 }/fn make_b() -> Int { 83 }/' "$TMP_DIR/r24b_1/b.pion" > "$TMP_DIR/r24b_1/b2.pion"
mv "$TMP_DIR/r24b_1/b2.pion" "$TMP_DIR/r24b_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r24b_1" "$PIONC" build -o "$TMP_DIR/r24b_1_hot" "$TMP_DIR/r24b_1/a.pion" "$TMP_DIR/r24b_1/b.pion"
out_r24b_1b=$("$TMP_DIR/r24b_1_hot")
test "$out_r24b_1b" = "83:83"

cat > "$TMP_DIR/r24b_1_cyc1/main.pion" <<'EOF'
struct Other { x : Int }
fn Other::push(self : Other, v : Int) -> Int { v }
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ push: invoke }
  holder.push(read_a)
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r24b_1_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r24b_1_cyc1/main.pion" 2>&1)
r24b_1_cyc1_rc=$?
set -e
test "$r24b_1_cyc1_rc" -ne 0
printf '%s' "$r24b_1_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r24b_1_cyc2/main.pion" <<'EOF'
struct Other { x : Int }
fn Other::run(self : Other, v : Int) -> Int { v }
struct Holder { run : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ run: invoke }
  holder.run(read_a)
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r24b_1_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r24b_1_cyc2/main.pion" 2>&1)
r24b_1_cyc2_rc=$?
set -e
test "$r24b_1_cyc2_rc" -ne 0
printf '%s' "$r24b_1_cyc2_out" | grep -q "E_CONST_CYCLE"

# 24b: 0-arg `holder.run()` & `fire(Holder::{ run: read_b })` cold/hot CAS (89:89 -> 97:97) + 2x cycles
mkdir -p "$TMP_DIR/r24b_2" "$TMP_DIR/cas_r24b_2" "$TMP_DIR/r24b_2_cyc1" "$TMP_DIR/r24b_2_cyc2"
cat > "$TMP_DIR/r24b_2/a.pion" <<'EOF'
let A : String = go().to_string() + ":" + fire(Holder::{ run: read_b }).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r24b_2/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 89 }
fn go() -> Int {
  let holder = Holder::{ run: read_b }
  holder.run()
}
fn fire(h : Holder) -> Int { h.run() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r24b_2" "$PIONC" build -o "$TMP_DIR/r24b_2_cold" "$TMP_DIR/r24b_2/a.pion" "$TMP_DIR/r24b_2/b.pion"
out_r24b_2a=$("$TMP_DIR/r24b_2_cold")
test "$out_r24b_2a" = "89:89"
sed 's/fn make_b() -> Int { 89 }/fn make_b() -> Int { 97 }/' "$TMP_DIR/r24b_2/b.pion" > "$TMP_DIR/r24b_2/b2.pion"
mv "$TMP_DIR/r24b_2/b2.pion" "$TMP_DIR/r24b_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r24b_2" "$PIONC" build -o "$TMP_DIR/r24b_2_hot" "$TMP_DIR/r24b_2/a.pion" "$TMP_DIR/r24b_2/b.pion"
out_r24b_2b=$("$TMP_DIR/r24b_2_hot")
test "$out_r24b_2b" = "97:97"

cat > "$TMP_DIR/r24b_2_cyc1/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ run: read_a }
  holder.run()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r24b_2_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r24b_2_cyc1/main.pion" 2>&1)
r24b_2_cyc1_rc=$?
set -e
test "$r24b_2_cyc1_rc" -ne 0
printf '%s' "$r24b_2_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r24b_2_cyc2/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn fire(h : Holder) -> Int { h.run() }
let A : Int = fire(Holder::{ run: read_a })
pub fn main() -> Int { A }
EOF
set +e
r24b_2_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r24b_2_cyc2/main.pion" 2>&1)
r24b_2_cyc2_rc=$?
set -e
test "$r24b_2_cyc2_rc" -ne 0
printf '%s' "$r24b_2_cyc2_out" | grep -q "E_CONST_CYCLE"
echo "  R24b cold/hot CAS (shadow $out_r24b_1a->$out_r24b_1b, zero-arg/fire $out_r24b_2a->$out_r24b_2b) & 4x cycles (OK)"

echo "=== Wave J1 E2E [25/25]: R25 dyn/generic trait dispatch, exact struct fn field, generic Holder[T].get & top-level const struct ==="
# 25a: `dyn Read` & `via[T : Read]` cold/hot CAS (101:101 -> 103:103) + 2x cycles
mkdir -p "$TMP_DIR/r25_1" "$TMP_DIR/cas_r25_1" "$TMP_DIR/r25_1_cyc1" "$TMP_DIR/r25_1_cyc2"
cat > "$TMP_DIR/r25_1/a.pion" <<'EOF'
let A : String = via_dyn(R::{ x: 0 } as dyn Read).to_string() + ":" + via_gen(R::{ x: 0 }).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r25_1/b.pion" <<'EOF'
trait Read { fn read(self : Self) -> Int }
struct R { x : Int }
impl Read for R { fn read(self : R) -> Int { B } }
fn via_dyn(x : dyn Read) -> Int { x.read() }
fn via_gen[T : Read](x : T) -> Int { x.read() }
fn make_b() -> Int { 101 }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25_1" "$PIONC" build -o "$TMP_DIR/r25_1_cold" "$TMP_DIR/r25_1/a.pion" "$TMP_DIR/r25_1/b.pion"
out_r25_1a=$("$TMP_DIR/r25_1_cold")
test "$out_r25_1a" = "101:101"
sed 's/fn make_b() -> Int { 101 }/fn make_b() -> Int { 103 }/' "$TMP_DIR/r25_1/b.pion" > "$TMP_DIR/r25_1/b2.pion"
mv "$TMP_DIR/r25_1/b2.pion" "$TMP_DIR/r25_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r25_1" "$PIONC" build -o "$TMP_DIR/r25_1_hot" "$TMP_DIR/r25_1/a.pion" "$TMP_DIR/r25_1/b.pion"
out_r25_1b=$("$TMP_DIR/r25_1_hot")
test "$out_r25_1b" = "103:103"

cat > "$TMP_DIR/r25_1_cyc1/main.pion" <<'EOF'
trait Read { fn read(self : Self) -> Int }
struct R { x : Int }
impl Read for R { fn read(self : R) -> Int { A } }
fn via(x : dyn Read) -> Int { x.read() }
let A : Int = via(R::{ x: 0 } as dyn Read)
pub fn main() -> Int { A }
EOF
set +e
r25_1_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r25_1_cyc1/main.pion" 2>&1)
r25_1_cyc1_rc=$?
set -e
test "$r25_1_cyc1_rc" -ne 0
printf '%s' "$r25_1_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r25_1_cyc2/main.pion" <<'EOF'
trait Read { fn read(self : Self) -> Int }
struct R { x : Int }
impl Read for R { fn read(self : R) -> Int { A } }
fn via[T : Read](x : T) -> Int { x.read() }
let A : Int = via(R::{ x: 0 })
pub fn main() -> Int { A }
EOF
set +e
r25_1_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r25_1_cyc2/main.pion" 2>&1)
r25_1_cyc2_rc=$?
set -e
test "$r25_1_cyc2_rc" -ne 0
printf '%s' "$r25_1_cyc2_out" | grep -q "E_CONST_CYCLE"

# 25b: exact struct fn field projection: `Holder::{ run: zero, spare: read_a }; holder.run()` -> 0, swapped -> cycle
mkdir -p "$TMP_DIR/r25_2" "$TMP_DIR/cas_r25_2" "$TMP_DIR/r25_2_cyc"
cat > "$TMP_DIR/r25_2/main.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ run: zero, spare: read_a }
  holder.run()
}
let A : Int = go()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25_2" "$PIONC" build -o "$TMP_DIR/r25_2_bin" "$TMP_DIR/r25_2/main.pion"
out_r25_2=$("$TMP_DIR/r25_2_bin")
test "$out_r25_2" = "0"

cat > "$TMP_DIR/r25_2_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn go() -> Int {
  let holder = Holder::{ run: read_a, spare: zero }
  holder.run()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r25_2_cyc_out=$("$PIONC" check --json "$TMP_DIR/r25_2_cyc/main.pion" 2>&1)
r25_2_cyc_rc=$?
set -e
test "$r25_2_cyc_rc" -ne 0
printf '%s' "$r25_2_cyc_out" | grep -q "E_CONST_CYCLE"

# 25c: 2-file `struct Holder[T] { get : T }` cold/hot CAS (107 -> 109) + cycle
mkdir -p "$TMP_DIR/r25_3" "$TMP_DIR/cas_r25_3" "$TMP_DIR/r25_3_cyc"
cat > "$TMP_DIR/r25_3/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r25_3/b.pion" <<'EOF'
struct Holder[T] { get : T }
fn read_b() -> Int { B }
fn make_b() -> Int { 107 }
fn go() -> Int {
  let h : Holder[() -> Int] = Holder::{ get: read_b }
  h.get()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25_3" "$PIONC" build -o "$TMP_DIR/r25_3_cold" "$TMP_DIR/r25_3/a.pion" "$TMP_DIR/r25_3/b.pion"
out_r25_3a=$("$TMP_DIR/r25_3_cold")
test "$out_r25_3a" = "107"
sed 's/fn make_b() -> Int { 107 }/fn make_b() -> Int { 109 }/' "$TMP_DIR/r25_3/b.pion" > "$TMP_DIR/r25_3/b2.pion"
mv "$TMP_DIR/r25_3/b2.pion" "$TMP_DIR/r25_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r25_3" "$PIONC" build -o "$TMP_DIR/r25_3_hot" "$TMP_DIR/r25_3/a.pion" "$TMP_DIR/r25_3/b.pion"
out_r25_3b=$("$TMP_DIR/r25_3_hot")
test "$out_r25_3b" = "109"

cat > "$TMP_DIR/r25_3_cyc/main.pion" <<'EOF'
struct Holder[T] { get : T }
fn read_a() -> Int { A }
fn go() -> Int {
  let h : Holder[() -> Int] = Holder::{ get: read_a }
  h.get()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r25_3_cyc_out=$("$PIONC" check --json "$TMP_DIR/r25_3_cyc/main.pion" 2>&1)
r25_3_cyc_rc=$?
set -e
test "$r25_3_cyc_rc" -ne 0
printf '%s' "$r25_3_cyc_out" | grep -q "E_CONST_CYCLE"

# 25d: top-level `let H : Holder = Holder::{ run: zero, spare: read_a }` (H.run()=0, H.spare() cycle, H.run() cold/hot CAS 113->127)
mkdir -p "$TMP_DIR/r25_4s" "$TMP_DIR/cas_r25_4s" "$TMP_DIR/r25_4" "$TMP_DIR/cas_r25_4" "$TMP_DIR/r25_4_cyc"
cat > "$TMP_DIR/r25_4s/main.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Holder = Holder::{ run: zero, spare: read_a }
let A : Int = H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25_4s" "$PIONC" build -o "$TMP_DIR/r25_4s_bin" "$TMP_DIR/r25_4s/main.pion"
out_r25_4s=$("$TMP_DIR/r25_4s_bin")
test "$out_r25_4s" = "0"

cat > "$TMP_DIR/r25_4/a.pion" <<'EOF'
let A : String = H.run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r25_4/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 113 }
let H : Holder = Holder::{ run: read_b }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25_4" "$PIONC" build -o "$TMP_DIR/r25_4_cold" "$TMP_DIR/r25_4/a.pion" "$TMP_DIR/r25_4/b.pion"
out_r25_4a=$("$TMP_DIR/r25_4_cold")
test "$out_r25_4a" = "113"
sed 's/fn make_b() -> Int { 113 }/fn make_b() -> Int { 127 }/' "$TMP_DIR/r25_4/b.pion" > "$TMP_DIR/r25_4/b2.pion"
mv "$TMP_DIR/r25_4/b2.pion" "$TMP_DIR/r25_4/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r25_4" "$PIONC" build -o "$TMP_DIR/r25_4_hot" "$TMP_DIR/r25_4/a.pion" "$TMP_DIR/r25_4/b.pion"
out_r25_4b=$("$TMP_DIR/r25_4_hot")
test "$out_r25_4b" = "127"

cat > "$TMP_DIR/r25_4_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Holder = Holder::{ run: zero, spare: read_a }
let A : Int = H.spare()
pub fn main() -> Int { A }
EOF
set +e
r25_4_cyc_out=$("$PIONC" check --json "$TMP_DIR/r25_4_cyc/main.pion" 2>&1)
r25_4_cyc_rc=$?
set -e
test "$r25_4_cyc_rc" -ne 0
printf '%s' "$r25_4_cyc_out" | grep -q "E_CONST_CYCLE"
echo "  R25 cold/hot CAS (trait $out_r25_1a->$out_r25_1b, field-ok=$out_r25_2, gen-get $out_r25_3a->$out_r25_3b, top-H-ok=$out_r25_4s/ord $out_r25_4a->$out_r25_4b) & 5x cycles (OK)"

echo "=== Wave J1 E2E [26/26]: R25b non-exact struct fn field init & top-level #cfdef callback param propagation ==="
mkdir -p "$TMP_DIR/r25b_1" "$TMP_DIR/cas_r25b_1" "$TMP_DIR/r25b_1_cyc1" "$TMP_DIR/r25b_1_cyc2" "$TMP_DIR/r25b_2" "$TMP_DIR/cas_r25b_2" "$TMP_DIR/r25b_2_cyc1" "$TMP_DIR/r25b_2_cyc2"
cat > "$TMP_DIR/r25b_1/a.pion" <<'EOF'
let A : String = go1().to_string() + ":" + go2().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r25b_1/b.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn get_invoker() -> ((() -> Int) -> Int) { invoke }
fn read_b() -> Int { B }
fn make_b() -> Int { 131 }
fn go1() -> Int { let h = Holder::{ push: get_invoker() }; h.push(read_b) }
fn go2() -> Int { Holder::{ push: get_invoker() }.push(read_b) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25b_1" "$PIONC" build -o "$TMP_DIR/r25b_1_cold" "$TMP_DIR/r25b_1/a.pion" "$TMP_DIR/r25b_1/b.pion"
out_r25b_1a=$("$TMP_DIR/r25b_1_cold")
test "$out_r25b_1a" = "131:131"
sed 's/fn make_b() -> Int { 131 }/fn make_b() -> Int { 137 }/' "$TMP_DIR/r25b_1/b.pion" > "$TMP_DIR/r25b_1/b2.pion"
mv "$TMP_DIR/r25b_1/b2.pion" "$TMP_DIR/r25b_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r25b_1" "$PIONC" build -o "$TMP_DIR/r25b_1_hot" "$TMP_DIR/r25b_1/a.pion" "$TMP_DIR/r25b_1/b.pion"
out_r25b_1b=$("$TMP_DIR/r25b_1_hot")
test "$out_r25b_1b" = "137:137"

cat > "$TMP_DIR/r25b_1_cyc1/main.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn get_invoker() -> ((() -> Int) -> Int) { invoke }
fn read_a() -> Int { A }
fn go() -> Int { let h = Holder::{ push: get_invoker() }; h.push(read_a) }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r25b_1_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r25b_1_cyc1/main.pion" 2>&1)
r25b_1_cyc1_rc=$?
set -e
test "$r25b_1_cyc1_rc" -ne 0
printf '%s' "$r25b_1_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r25b_1_cyc2/main.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn get_invoker() -> ((() -> Int) -> Int) { invoke }
fn read_a() -> Int { A }
fn go() -> Int { Holder::{ push: get_invoker() }.push(read_a) }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r25b_1_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r25b_1_cyc2/main.pion" 2>&1)
r25b_1_cyc2_rc=$?
set -e
test "$r25b_1_cyc2_rc" -ne 0
printf '%s' "$r25b_1_cyc2_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r25b_2/a.pion" <<'EOF'
let A : String = H1.push(read_b).to_string() + ":" + H2.push(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r25b_2/b.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn get_invoker() -> ((() -> Int) -> Int) { invoke }
fn read_b() -> Int { B }
fn make_b() -> Int { 139 }
let H1 : Holder = Holder::{ push: invoke }
let H2 : Holder = Holder::{ push: get_invoker() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r25b_2" "$PIONC" build -o "$TMP_DIR/r25b_2_cold" "$TMP_DIR/r25b_2/a.pion" "$TMP_DIR/r25b_2/b.pion"
out_r25b_2a=$("$TMP_DIR/r25b_2_cold")
test "$out_r25b_2a" = "139:139"
sed 's/fn make_b() -> Int { 139 }/fn make_b() -> Int { 149 }/' "$TMP_DIR/r25b_2/b.pion" > "$TMP_DIR/r25b_2/b2.pion"
mv "$TMP_DIR/r25b_2/b2.pion" "$TMP_DIR/r25b_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r25b_2" "$PIONC" build -o "$TMP_DIR/r25b_2_hot" "$TMP_DIR/r25b_2/a.pion" "$TMP_DIR/r25b_2/b.pion"
out_r25b_2b=$("$TMP_DIR/r25b_2_hot")
test "$out_r25b_2b" = "149:149"

cat > "$TMP_DIR/r25b_2_cyc1/main.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn read_a() -> Int { A }
let H : Holder = Holder::{ push: invoke }
let A : Int = H.push(read_a)
pub fn main() -> Int { A }
EOF
set +e
r25b_2_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r25b_2_cyc1/main.pion" 2>&1)
r25b_2_cyc1_rc=$?
set -e
test "$r25b_2_cyc1_rc" -ne 0
printf '%s' "$r25b_2_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r25b_2_cyc2/main.pion" <<'EOF'
struct Holder { push : (() -> Int) -> Int }
fn invoke(f : () -> Int) -> Int { f() }
fn get_invoker() -> ((() -> Int) -> Int) { invoke }
fn read_a() -> Int { A }
let H : Holder = Holder::{ push: get_invoker() }
let A : Int = H.push(read_a)
pub fn main() -> Int { A }
EOF
set +e
r25b_2_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r25b_2_cyc2/main.pion" 2>&1)
r25b_2_cyc2_rc=$?
set -e
test "$r25b_2_cyc2_rc" -ne 0
printf '%s' "$r25b_2_cyc2_out" | grep -q "E_CONST_CYCLE"
echo "  R25b cold/hot CAS (nonexact $out_r25b_1a->$out_r25b_1b, top-H-cb $out_r25b_2a->$out_r25b_2b) & 4x cycles (OK)"

echo "=== Wave J1 E2E [27/27]: R26 unified @field::, #fret, #fieldw/#fieldp & #cfspread (all 16 Opus probes + 5 Astra blockers) ==="
# Run all 16 Opus probes (cycle + 2-file cold 7 -> hot 9)
python3 - "$TMP_DIR/r26_opus" <<'PYEOF'
import os, sys
out = sys.argv[1]
HOLDER = "struct Holder { mut run : () -> Int }\nfn zero() -> Int { 0 }\n"
P = {
  "call_recv": (HOLDER + "fn mk() -> Holder { Holder::{ run: READ } }\nfn go() -> Int { mk().run() }\n", "go()"),
  "nested_field": (HOLDER + "struct Outer { h : Holder }\nfn go() -> Int {\n  let o = Outer::{ h: Holder::{ run: READ } }\n  o.h.run()\n}\n", "go()"),
  "array_elem": (HOLDER + "fn go() -> Int {\n  let hs = [Holder::{ run: READ }]\n  hs[0].run()\n}\n", "go()"),
  "const_call": (HOLDER + "fn mk() -> Holder { Holder::{ run: READ } }\nlet H : Holder = mk()\nfn go() -> Int { H.run() }\n", "go()"),
  "const_alias": (HOLDER + "let H1 : Holder = Holder::{ run: READ }\nlet H2 : Holder = H1\nfn go() -> Int { H2.run() }\n", "go()"),
  "const_spread": ("struct Holder { run : () -> Int; spare : () -> Int }\nfn zero() -> Int { 0 }\nlet H0 : Holder = Holder::{ run: READ, spare: zero }\nlet H : Holder = Holder::{ ..H0, spare: zero }\nfn go() -> Int { H.run() }\n", "go()"),
  "reassign": (HOLDER + "fn go() -> Int {\n  let mut h = Holder::{ run: zero }\n  h = Holder::{ run: READ }\n  h.run()\n}\n", "go()"),
  "field_write": (HOLDER + "fn go() -> Int {\n  let h = Holder::{ run: zero }\n  h.run = READ\n  h.run()\n}\n", "go()"),
  "alias_write": (HOLDER + "fn go() -> Int {\n  let h = Holder::{ run: zero }\n  let g = h\n  g.run = READ\n  h.run()\n}\n", "go()"),
  "method_write": (HOLDER + "fn Holder::install(self : Holder) -> Unit { self.run = READ }\nfn go() -> Int {\n  let h = Holder::{ run: zero }\n  h.install()\n  h.run()\n}\n", "go()"),
  "fn_write": (HOLDER + "fn poke(h : Holder) -> Unit { h.run = READ }\nfn go() -> Int {\n  let h = Holder::{ run: zero }\n  poke(h)\n  h.run()\n}\n", "go()"),
  "closure_write": (HOLDER + "fn go() -> Int {\n  let h = Holder::{ run: zero }\n  let set = fn() -> Unit { h.run = READ }\n  set()\n  h.run()\n}\n", "go()"),
  "loop_reassign": (HOLDER + "fn go() -> Int {\n  let mut h = Holder::{ run: zero }\n  let mut r = 0\n  let mut i = 0\n  while i < 2 {\n    r = r + h.run()\n    h = Holder::{ run: READ }\n    i = i + 1\n  }\n  r\n}\n", "go()"),
  "arr_alias_write": (HOLDER + "fn go() -> Int {\n  let h = Holder::{ run: zero }\n  let hs = [h]\n  hs[0].run = READ\n  h.run()\n}\n", "go()"),
  "outer_alias_write": (HOLDER + "struct Outer { h : Holder }\nfn go() -> Int {\n  let h = Holder::{ run: zero }\n  let o = Outer::{ h: h }\n  o.h.run = READ\n  h.run()\n}\n", "go()"),
  "const_mut_write": (HOLDER + "let H : Holder = Holder::{ run: zero }\nfn go() -> Int {\n  H.run = READ\n  H.run()\n}\n", "go()"),
}
for name, (body, expr) in P.items():
  d = os.path.join(out, "cyc", name)
  os.makedirs(d, exist_ok=True)
  with open(os.path.join(d, "main.pion"), "w") as f:
    f.write("fn read_a() -> Int { A }\n" + body.replace("READ", "read_a") + "let A : Int = " + expr + "\npub fn main() -> Int { A }\n")
  d = os.path.join(out, "run", name)
  os.makedirs(d, exist_ok=True)
  with open(os.path.join(d, "a.pion"), "w") as f:
    f.write("let A : Int = " + expr + "\npub fn main(world : World) -> Unit { io_println(world, A.to_string()) }\n")
  with open(os.path.join(d, "b.pion"), "w") as f:
    f.write("fn read_b() -> Int { B }\nfn make_b() -> Int { 7 }\n" + body.replace("READ", "read_b") + "let B : Int = make_b()\n")
PYEOF
r26_opus_ok=0
for pname in call_recv nested_field array_elem const_call const_alias const_spread reassign field_write alias_write method_write fn_write closure_write loop_reassign arr_alias_write outer_alias_write const_mut_write; do
  set +e
  p_cyc_out=$("$PIONC" check --json "$TMP_DIR/r26_opus/cyc/$pname/main.pion" 2>&1)
  p_cyc_rc=$?
  set -e
  test "$p_cyc_rc" -ne 0
  printf '%s' "$p_cyc_out" | grep -q "E_CONST_CYCLE"
  mkdir -p "$TMP_DIR/r26_opus/cas_$pname"
  PION_CACHE_DIR="$TMP_DIR/r26_opus/cas_$pname" "$PIONC" build -o "$TMP_DIR/r26_opus/bin_${pname}_c" "$TMP_DIR/r26_opus/run/$pname/a.pion" "$TMP_DIR/r26_opus/run/$pname/b.pion"
  p_cold=$("$TMP_DIR/r26_opus/bin_${pname}_c")
  test "$p_cold" = "7"
  sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r26_opus/run/$pname/b.pion" > "$TMP_DIR/r26_opus/run/$pname/b2.pion"
  mv "$TMP_DIR/r26_opus/run/$pname/b2.pion" "$TMP_DIR/r26_opus/run/$pname/b.pion"
  PION_CACHE_DIR="$TMP_DIR/r26_opus/cas_$pname" "$PIONC" build -o "$TMP_DIR/r26_opus/bin_${pname}_h" "$TMP_DIR/r26_opus/run/$pname/a.pion" "$TMP_DIR/r26_opus/run/$pname/b.pion"
  p_hot=$("$TMP_DIR/r26_opus/bin_${pname}_h")
  test "$p_hot" = "9"
  r26_opus_ok=$((r26_opus_ok + 1))
done
test "$r26_opus_ok" = "16"

# Astra #2-#5 E2E (top-level closure field, spread override ok, maker() #fret, struct __field__)
mkdir -p "$TMP_DIR/r26_astra" "$TMP_DIR/cas_r26_a" "$TMP_DIR/r26_a_cyc1" "$TMP_DIR/r26_a_cyc2" "$TMP_DIR/r26_a_cyc3"
cat > "$TMP_DIR/r26_astra/a.pion" <<'EOF'
let A : String = H_cb.run().to_string() + ":" + H_ov.run().to_string() + ":" + H_mk.run().to_string() + ":" + __field__::{ n: 0 }.run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r26_astra/b.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 151 }
fn maker() -> () -> Int { read_b }
let H_cb : Holder = Holder::{ run: fn() -> Int { B }, spare: zero }
let H0 : Holder = Holder::{ run: read_b, spare: zero }
let H_ov : Holder = Holder::{ ..H0, run: zero }
let H_mk : Holder = Holder::{ run: maker(), spare: zero }
struct __field__ { n : Int }
fn __field__::run(self : __field__) -> Int { B }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r26_a" "$PIONC" build -o "$TMP_DIR/r26_a_cold" "$TMP_DIR/r26_astra/a.pion" "$TMP_DIR/r26_astra/b.pion"
out_r26_aa=$("$TMP_DIR/r26_a_cold")
test "$out_r26_aa" = "151:0:151:151"
sed 's/fn make_b() -> Int { 151 }/fn make_b() -> Int { 163 }/' "$TMP_DIR/r26_astra/b.pion" > "$TMP_DIR/r26_astra/b2.pion"
mv "$TMP_DIR/r26_astra/b2.pion" "$TMP_DIR/r26_astra/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r26_a" "$PIONC" build -o "$TMP_DIR/r26_a_hot" "$TMP_DIR/r26_astra/a.pion" "$TMP_DIR/r26_astra/b.pion"
out_r26_ab=$("$TMP_DIR/r26_a_hot")
test "$out_r26_ab" = "163:0:163:163"

cat > "$TMP_DIR/r26_a_cyc1/main.pion" <<'EOF'
struct Holder { run : () -> Int }
let H : Holder = Holder::{ run: fn() -> Int { A } }
let A : Int = H.run()
pub fn main() -> Int { A }
EOF
set +e
r26_a_c1=$("$PIONC" check --json "$TMP_DIR/r26_a_cyc1/main.pion" 2>&1)
r26_a_rc1=$?
set -e
test "$r26_a_rc1" -ne 0
printf '%s' "$r26_a_c1" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r26_a_cyc2/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn maker() -> () -> Int { read_a }
let H : Holder = Holder::{ run: maker() }
let A : Int = H.run()
pub fn main() -> Int { A }
EOF
set +e
r26_a_c2=$("$PIONC" check --json "$TMP_DIR/r26_a_cyc2/main.pion" 2>&1)
r26_a_rc2=$?
set -e
test "$r26_a_rc2" -ne 0
printf '%s' "$r26_a_c2" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r26_a_cyc3/main.pion" <<'EOF'
struct __field__ { n : Int }
fn __field__::run(self : __field__) -> Int { A }
let A : Int = __field__::{ n: 0 }.run()
pub fn main() -> Int { A }
EOF
set +e
r26_a_c3=$("$PIONC" check --json "$TMP_DIR/r26_a_cyc3/main.pion" 2>&1)
r26_a_rc3=$?
set -e
test "$r26_a_rc3" -ne 0
printf '%s' "$r26_a_c3" | grep -q "E_CONST_CYCLE"
echo "  R26 unified: 16/16 Opus probes (cyc + cold 7->hot 9) & Astra #2-#5 ($out_r26_aa->$out_r26_ab + 3x cycles) (OK)"

echo "=== Wave J1 E2E [28/28]: R27 alias factory \$ret:, shadowed local ret & type-qualified reachability-gated #fieldw/#fieldp ==="
mkdir -p "$TMP_DIR/r27_1" "$TMP_DIR/cas_r27_1" "$TMP_DIR/r27_1_cyc" "$TMP_DIR/r27_2" "$TMP_DIR/cas_r27_2" "$TMP_DIR/r27_3" "$TMP_DIR/cas_r27_3"
cat > "$TMP_DIR/r27_1/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r27_1/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn maker() -> () -> Int { read_b }
fn go() -> Int {
  let mk = maker
  let h = Holder::{ run: mk() }
  h.run()
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r27_1" "$PIONC" build -o "$TMP_DIR/r27_1_cold" "$TMP_DIR/r27_1/a.pion" "$TMP_DIR/r27_1/b.pion"
out_r27_1a=$("$TMP_DIR/r27_1_cold")
test "$out_r27_1a" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r27_1/b.pion" > "$TMP_DIR/r27_1/b2.pion"
mv "$TMP_DIR/r27_1/b2.pion" "$TMP_DIR/r27_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r27_1" "$PIONC" build -o "$TMP_DIR/r27_1_hot" "$TMP_DIR/r27_1/a.pion" "$TMP_DIR/r27_1/b.pion"
out_r27_1b=$("$TMP_DIR/r27_1_hot")
test "$out_r27_1b" = "9"

cat > "$TMP_DIR/r27_1_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn maker() -> () -> Int { read_a }
fn go() -> Int {
  let mk = maker
  let h = Holder::{ run: mk() }
  h.run()
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e
r27_1_c=$("$PIONC" check --json "$TMP_DIR/r27_1_cyc/main.pion" 2>&1)
r27_1_rc=$?
set -e
test "$r27_1_rc" -ne 0
printf '%s' "$r27_1_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r27_2/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn danger() -> Int { A }
fn zero() -> Int { 0 }
fn maker() -> () -> Int { let danger = zero; danger }
fn maker_if(flag : Bool) -> () -> Int {
  if flag { let danger = zero; danger } else { zero }
}
let H1 : Holder = Holder::{ run: maker() }
let H2 : Holder = Holder::{ run: maker_if(true) }
let A : Int = H1.run() + H2.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r27_2" "$PIONC" build -o "$TMP_DIR/r27_2_cold" "$TMP_DIR/r27_2/main.pion"
out_r27_2a=$("$TMP_DIR/r27_2_cold")
test "$out_r27_2a" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r27_2" "$PIONC" build -o "$TMP_DIR/r27_2_hot" "$TMP_DIR/r27_2/main.pion"
out_r27_2b=$("$TMP_DIR/r27_2_hot")
test "$out_r27_2b" = "0"

cat > "$TMP_DIR/r27_3/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
struct Other { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn unused_other(x : Other) -> Unit { x.run = read_a }
fn unused_live(x : Live) -> Unit { x.run = read_a }
fn touch_other() -> Int { let o = Other::{ run: zero }; o.run = read_a; 0 }
let H : Live = Live::{ run: zero }
let A : Int = touch_other() + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r27_3" "$PIONC" build -o "$TMP_DIR/r27_3_cold" "$TMP_DIR/r27_3/main.pion"
out_r27_3a=$("$TMP_DIR/r27_3_cold")
test "$out_r27_3a" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r27_3" "$PIONC" build -o "$TMP_DIR/r27_3_hot" "$TMP_DIR/r27_3/main.pion"
out_r27_3b=$("$TMP_DIR/r27_3_hot")
test "$out_r27_3b" = "0"
echo "  R27 cold/hot CAS (alias-factory $out_r27_1a->$out_r27_1b + cyc, shadow-ret $out_r27_2a->$out_r27_2b, other+dead-write $out_r27_3a->$out_r27_3b) (OK)"

echo "=== Wave J1 E2E [29/29]: R28 param factory \$retp:, multi-level outer()(), @ci:, gated fdef, isolated locals & Opus indirect/dyn/spread ==="
mkdir -p "$TMP_DIR/r28_1a" "$TMP_DIR/cas_r28_1a" "$TMP_DIR/r28_1a_cyc" \
         "$TMP_DIR/r28_1b" "$TMP_DIR/cas_r28_1b" "$TMP_DIR/r28_1b_cyc" \
         "$TMP_DIR/r28_2" "$TMP_DIR/cas_r28_2" \
         "$TMP_DIR/r28_3" "$TMP_DIR/cas_r28_3" "$TMP_DIR/r28_3_cyc" \
         "$TMP_DIR/r28_4" "$TMP_DIR/cas_r28_4" "$TMP_DIR/r28_4_cyc" \
         "$TMP_DIR/r28_op1" "$TMP_DIR/cas_r28_op1" "$TMP_DIR/r28_op1_cyc" \
         "$TMP_DIR/r28_op2" "$TMP_DIR/cas_r28_op2" "$TMP_DIR/r28_op2_cyc" \
         "$TMP_DIR/r28_op3" "$TMP_DIR/cas_r28_op3" "$TMP_DIR/r28_op3_cyc"

# 29a: param factory `go(maker)` cold 7 -> hot 9 + cycle
cat > "$TMP_DIR/r28_1a/a.pion" <<'EOF'
let A : String = go(maker).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r28_1a/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn maker() -> () -> Int { read_b }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_1a" "$PIONC" build -o "$TMP_DIR/r28_1a_c" "$TMP_DIR/r28_1a/a.pion" "$TMP_DIR/r28_1a/b.pion"
out_r28_1ac=$("$TMP_DIR/r28_1a_c"); test "$out_r28_1ac" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r28_1a/b.pion" > "$TMP_DIR/r28_1a/b2.pion" && mv "$TMP_DIR/r28_1a/b2.pion" "$TMP_DIR/r28_1a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r28_1a" "$PIONC" build -o "$TMP_DIR/r28_1a_h" "$TMP_DIR/r28_1a/a.pion" "$TMP_DIR/r28_1a/b.pion"
out_r28_1ah=$("$TMP_DIR/r28_1a_h"); test "$out_r28_1ah" = "9"
cat > "$TMP_DIR/r28_1a_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let A : Int = go(maker)
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_1a_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

# 29b: multi-level `outer()()` cold 7 -> hot 9 + cycle
cat > "$TMP_DIR/r28_1b/a.pion" <<'EOF'
let A : String = H.run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r28_1b/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn maker() -> () -> Int { read_b }
fn outer() -> () -> (() -> Int) { maker }
let H : Holder = Holder::{ run: outer()() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_1b" "$PIONC" build -o "$TMP_DIR/r28_1b_c" "$TMP_DIR/r28_1b/a.pion" "$TMP_DIR/r28_1b/b.pion"
out_r28_1bc=$("$TMP_DIR/r28_1b_c"); test "$out_r28_1bc" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r28_1b/b.pion" > "$TMP_DIR/r28_1b/b2.pion" && mv "$TMP_DIR/r28_1b/b2.pion" "$TMP_DIR/r28_1b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r28_1b" "$PIONC" build -o "$TMP_DIR/r28_1b_h" "$TMP_DIR/r28_1b/a.pion" "$TMP_DIR/r28_1b/b.pion"
out_r28_1bh=$("$TMP_DIR/r28_1b_h"); test "$out_r28_1bh" = "9"
cat > "$TMP_DIR/r28_1b_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn maker() -> () -> Int { read_a }
fn outer() -> () -> (() -> Int) { maker }
let H : Holder = Holder::{ run: outer()() }
let A : Int = H.run()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_1b_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

# 29c: `@ci:` domain isolation (`fn ci_unused_live`) cold 0 -> hot 0
cat > "$TMP_DIR/r28_2/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn ci_unused_live(x : Live) -> Unit { x.run = read_a }
let H : Live = Live::{ run: zero }
let A : Int = H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_2" "$PIONC" build -o "$TMP_DIR/r28_2_c" "$TMP_DIR/r28_2/main.pion"
test "$("$TMP_DIR/r28_2_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r28_2" "$PIONC" build -o "$TMP_DIR/r28_2_h" "$TMP_DIR/r28_2/main.pion"
test "$("$TMP_DIR/r28_2_h")" = "0"

# 29d: gated `fdef_calls` (`choose(0)` cold 0 -> hot 0; `choose()` cycle)
cat > "$TMP_DIR/r28_3/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn choose(x : Int = install()) -> Int { x }
let A : Int = choose(0) + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_3" "$PIONC" build -o "$TMP_DIR/r28_3_c" "$TMP_DIR/r28_3/main.pion"
test "$("$TMP_DIR/r28_3_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r28_3" "$PIONC" build -o "$TMP_DIR/r28_3_h" "$TMP_DIR/r28_3/main.pion"
test "$("$TMP_DIR/r28_3_h")" = "0"
cat > "$TMP_DIR/r28_3_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn choose(x : Int = install()) -> Int { x }
let A : Int = choose() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_3_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

# 29e: isolated local struct write (`o = Live::{...}` cold 0 -> hot 0; `o = H` cycle)
cat > "$TMP_DIR/r28_4/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn touch_live() -> Int { let o = Live::{ run: zero }; o.run = read_a; 0 }
let A : Int = touch_live() + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_4" "$PIONC" build -o "$TMP_DIR/r28_4_c" "$TMP_DIR/r28_4/main.pion"
test "$("$TMP_DIR/r28_4_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r28_4" "$PIONC" build -o "$TMP_DIR/r28_4_h" "$TMP_DIR/r28_4/main.pion"
test "$("$TMP_DIR/r28_4_h")" = "0"
cat > "$TMP_DIR/r28_4_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn touch_live() -> Int { let o = H; o.run = read_a; 0 }
let A : Int = touch_live() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_4_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

# 29f: Opus `indirect_writer`, `dyn_writer`, `spread_override_hole` (each cold 7 -> hot 9 + cycle)
cat > "$TMP_DIR/r28_op1/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r28_op1/b.pion" <<'EOF'
struct Holder { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn do_write(h : Holder) -> Unit { h.run = read_b }
fn apply_w(w : (Holder) -> Unit, h : Holder) -> Unit { w(h) }
fn go() -> Int { let h = Holder::{ run: zero }; apply_w(do_write, h); h.run() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_op1" "$PIONC" build -o "$TMP_DIR/r28_op1_c" "$TMP_DIR/r28_op1/a.pion" "$TMP_DIR/r28_op1/b.pion"
test "$("$TMP_DIR/r28_op1_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r28_op1/b.pion" > "$TMP_DIR/r28_op1/b2.pion" && mv "$TMP_DIR/r28_op1/b2.pion" "$TMP_DIR/r28_op1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r28_op1" "$PIONC" build -o "$TMP_DIR/r28_op1_h" "$TMP_DIR/r28_op1/a.pion" "$TMP_DIR/r28_op1/b.pion"
test "$("$TMP_DIR/r28_op1_h")" = "9"
cat > "$TMP_DIR/r28_op1_cyc/main.pion" <<'EOF'
struct Holder { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn do_write(h : Holder) -> Unit { h.run = read_a }
fn apply_w(w : (Holder) -> Unit, h : Holder) -> Unit { w(h) }
fn go() -> Int { let h = Holder::{ run: zero }; apply_w(do_write, h); h.run() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_op1_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r28_op2/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r28_op2/b.pion" <<'EOF'
struct Holder { mut run : () -> Int }
trait Writer { fn write(self : Self, h : Holder) -> Unit }
struct W { tag : Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
impl Writer for W { fn write(self : W, h : Holder) -> Unit { h.run = read_b } }
fn run_w(w : dyn Writer, h : Holder) -> Unit { w.write(h) }
fn go() -> Int { let h = Holder::{ run: zero }; run_w(W::{ tag: 0 } as dyn Writer, h); h.run() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_op2" "$PIONC" build -o "$TMP_DIR/r28_op2_c" "$TMP_DIR/r28_op2/a.pion" "$TMP_DIR/r28_op2/b.pion"
test "$("$TMP_DIR/r28_op2_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r28_op2/b.pion" > "$TMP_DIR/r28_op2/b2.pion" && mv "$TMP_DIR/r28_op2/b2.pion" "$TMP_DIR/r28_op2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r28_op2" "$PIONC" build -o "$TMP_DIR/r28_op2_h" "$TMP_DIR/r28_op2/a.pion" "$TMP_DIR/r28_op2/b.pion"
test "$("$TMP_DIR/r28_op2_h")" = "9"
cat > "$TMP_DIR/r28_op2_cyc/main.pion" <<'EOF'
struct Holder { mut run : () -> Int }
trait Writer { fn write(self : Self, h : Holder) -> Unit }
struct W { tag : Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
impl Writer for W { fn write(self : W, h : Holder) -> Unit { h.run = read_a } }
fn run_w(w : dyn Writer, h : Holder) -> Unit { w.write(h) }
fn go() -> Int { let h = Holder::{ run: zero }; run_w(W::{ tag: 0 } as dyn Writer, h); h.run() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_op2_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r28_op3/a.pion" <<'EOF'
let A : String = H.run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r28_op3/b.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn mk() -> Holder { Holder::{ run: read_b, spare: zero } }
let H : Holder = Holder::{ ..mk(), spare: zero }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r28_op3" "$PIONC" build -o "$TMP_DIR/r28_op3_c" "$TMP_DIR/r28_op3/a.pion" "$TMP_DIR/r28_op3/b.pion"
test "$("$TMP_DIR/r28_op3_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r28_op3/b.pion" > "$TMP_DIR/r28_op3/b2.pion" && mv "$TMP_DIR/r28_op3/b2.pion" "$TMP_DIR/r28_op3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r28_op3" "$PIONC" build -o "$TMP_DIR/r28_op3_h" "$TMP_DIR/r28_op3/a.pion" "$TMP_DIR/r28_op3/b.pion"
test "$("$TMP_DIR/r28_op3_h")" = "9"
cat > "$TMP_DIR/r28_op3_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int; spare : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn mk() -> Holder { Holder::{ run: read_a, spare: zero } }
let H : Holder = Holder::{ ..mk(), spare: zero }
let A : Int = H.run()
pub fn main() -> Int { A }
EOF
set +e; r28_c=$("$PIONC" check --json "$TMP_DIR/r28_op3_cyc/main.pion" 2>&1); r28_rc=$?; set -e
test "$r28_rc" -ne 0; printf '%s' "$r28_c" | grep -q "E_CONST_CYCLE"
echo "  R28 cold/hot CAS (param-factory $out_r28_1ac->$out_r28_1ah, outer()() $out_r28_1bc->$out_r28_1bh, @ci:/fdef/isolated 0->0, Opus indirect/dyn/spread 7->9) & 7x cycles (OK)"

echo "=== Wave J1 E2E [30/30]: R29 EIs isolated shadow, @fdef: def_ctx, #fdefcb & context-sensitive \$retp: ==="
mkdir -p "$TMP_DIR/r29_1" "$TMP_DIR/cas_r29_1" "$TMP_DIR/r29_1_cyc" \
         "$TMP_DIR/r29_2" "$TMP_DIR/cas_r29_2" "$TMP_DIR/r29_2_cyc" \
         "$TMP_DIR/r29_3" "$TMP_DIR/cas_r29_3" "$TMP_DIR/r29_3_cyc" \
         "$TMP_DIR/r29_4" "$TMP_DIR/cas_r29_4" "$TMP_DIR/r29_4_cyc"

# 30a: `EIs` pattern shadow of isolated local `o` (cold 7 -> hot 9 + cycle)
cat > "$TMP_DIR/r29_1/a.pion" <<'EOF'
let A : String = (touch() + H.run()).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r29_1/b.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
let H : Live = Live::{ run: zero }
fn touch() -> Int {
  let o = Live::{ run: zero }
  if Some(H) is Some(o) { o.run = read_b }
  0
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r29_1" "$PIONC" build -o "$TMP_DIR/r29_1_c" "$TMP_DIR/r29_1/a.pion" "$TMP_DIR/r29_1/b.pion"
out_r29_1c=$("$TMP_DIR/r29_1_c"); test "$out_r29_1c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r29_1/b.pion" > "$TMP_DIR/r29_1/b2.pion" && mv "$TMP_DIR/r29_1/b2.pion" "$TMP_DIR/r29_1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r29_1" "$PIONC" build -o "$TMP_DIR/r29_1_h" "$TMP_DIR/r29_1/a.pion" "$TMP_DIR/r29_1/b.pion"
out_r29_1h=$("$TMP_DIR/r29_1_h"); test "$out_r29_1h" = "9"
cat > "$TMP_DIR/r29_1_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn touch() -> Int {
  let o = Live::{ run: zero }
  if Some(H) is Some(o) { o.run = read_a }
  0
}
let A : Int = touch() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r29_c=$("$PIONC" check --json "$TMP_DIR/r29_1_cyc/main.pion" 2>&1); r29_rc=$?; set -e
test "$r29_rc" -ne 0; printf '%s' "$r29_c" | grep -q "E_CONST_CYCLE"

# 30b: inline default arg `{ H.run = read_a; 0 }` (`choose(0)` cold 0 -> hot 0; `choose()` cycle)
cat > "$TMP_DIR/r29_2/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn choose(x : Int = { H.run = read_a; 0 }) -> Int { x }
let A : Int = choose(0) + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r29_2" "$PIONC" build -o "$TMP_DIR/r29_2_c" "$TMP_DIR/r29_2/main.pion"
test "$("$TMP_DIR/r29_2_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r29_2" "$PIONC" build -o "$TMP_DIR/r29_2_h" "$TMP_DIR/r29_2/main.pion"
test "$("$TMP_DIR/r29_2_h")" = "0"
cat > "$TMP_DIR/r29_2_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn choose(x : Int = { H.run = read_a; 0 }) -> Int { x }
let A : Int = choose() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r29_c=$("$PIONC" check --json "$TMP_DIR/r29_2_cyc/main.pion" 2>&1); r29_rc=$?; set -e
test "$r29_rc" -ne 0; printf '%s' "$r29_c" | grep -q "E_CONST_CYCLE"

# 30c: `#fdefcb` default callback `fn go(mk = maker)` (cold 7 -> hot 9 + cycle)
cat > "$TMP_DIR/r29_3/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r29_3/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn maker() -> () -> Int { read_b }
fn go(mk : () -> (() -> Int) = maker) -> Int { let h = Holder::{ run: mk() }; h.run() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r29_3" "$PIONC" build -o "$TMP_DIR/r29_3_c" "$TMP_DIR/r29_3/a.pion" "$TMP_DIR/r29_3/b.pion"
out_r29_3c=$("$TMP_DIR/r29_3_c"); test "$out_r29_3c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r29_3/b.pion" > "$TMP_DIR/r29_3/b2.pion" && mv "$TMP_DIR/r29_3/b2.pion" "$TMP_DIR/r29_3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r29_3" "$PIONC" build -o "$TMP_DIR/r29_3_h" "$TMP_DIR/r29_3/a.pion" "$TMP_DIR/r29_3/b.pion"
out_r29_3h=$("$TMP_DIR/r29_3_h"); test "$out_r29_3h" = "9"
cat > "$TMP_DIR/r29_3_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int) = maker) -> Int { let h = Holder::{ run: mk() }; h.run() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r29_c=$("$PIONC" check --json "$TMP_DIR/r29_3_cyc/main.pion" 2>&1); r29_rc=$?; set -e
test "$r29_rc" -ne 0; printf '%s' "$r29_c" | grep -q "E_CONST_CYCLE"

# 30d: context-sensitive `$retp:` (`B = go(reader_maker)`, `A = go(safe_maker)` -> cold 5 -> hot 8; `A = go(reader_maker)` cycle)
cat > "$TMP_DIR/r29_4/a.pion" <<'EOF'
let B : String = go(reader_maker).to_string()
pub fn main(world : World) -> Unit { io_println(world, B) }
EOF
cat > "$TMP_DIR/r29_4/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn base_val() -> Int { 2 }
fn read_a() -> Int { A + 3 }
fn safe_maker() -> () -> Int { base_val }
fn reader_maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let A : Int = go(safe_maker)
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r29_4" "$PIONC" build -o "$TMP_DIR/r29_4_c" "$TMP_DIR/r29_4/a.pion" "$TMP_DIR/r29_4/b.pion"
out_r29_4c=$("$TMP_DIR/r29_4_c"); test "$out_r29_4c" = "5"
sed 's/fn base_val() -> Int { 2 }/fn base_val() -> Int { 5 }/' "$TMP_DIR/r29_4/b.pion" > "$TMP_DIR/r29_4/b2.pion" && mv "$TMP_DIR/r29_4/b2.pion" "$TMP_DIR/r29_4/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r29_4" "$PIONC" build -o "$TMP_DIR/r29_4_h" "$TMP_DIR/r29_4/a.pion" "$TMP_DIR/r29_4/b.pion"
out_r29_4h=$("$TMP_DIR/r29_4_h"); test "$out_r29_4h" = "8"
cat > "$TMP_DIR/r29_4_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn reader_maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let A : Int = go(reader_maker)
pub fn main() -> Int { A }
EOF
set +e; r29_c=$("$PIONC" check --json "$TMP_DIR/r29_4_cyc/main.pion" 2>&1); r29_rc=$?; set -e
test "$r29_rc" -ne 0; printf '%s' "$r29_c" | grep -q "E_CONST_CYCLE"
echo "  R29 cold/hot CAS (eis-shadow $out_r29_1c->$out_r29_1h, inline-fdef 0->0, fdefcb $out_r29_3c->$out_r29_3h, ctx-retp $out_r29_4c->$out_r29_4h) & 4x cycles (OK)"

echo "=== Wave J1 E2E [31/31]: R30 default param refs, nested fdef cb, 8/9-level \$retp:, alias \$retp: & Opus 4+1 default cb ==="
mkdir -p \
  "$TMP_DIR/r30_1a" "$TMP_DIR/cas_r30_1a" "$TMP_DIR/r30_1a_ok" "$TMP_DIR/cas_r30_1a_ok" "$TMP_DIR/r30_1a_cyc" \
  "$TMP_DIR/r30_1b" "$TMP_DIR/cas_r30_1b" "$TMP_DIR/r30_1b_ok" "$TMP_DIR/cas_r30_1b_ok" "$TMP_DIR/r30_1b_cyc" \
  "$TMP_DIR/r30_2" "$TMP_DIR/cas_r30_2" "$TMP_DIR/r30_2_ok" "$TMP_DIR/cas_r30_2_ok" "$TMP_DIR/r30_2_cyc" \
  "$TMP_DIR/r30_3a" "$TMP_DIR/cas_r30_3a" "$TMP_DIR/r30_3a_cyc" \
  "$TMP_DIR/r30_3b" "$TMP_DIR/cas_r30_3b" "$TMP_DIR/r30_3b_cyc" \
  "$TMP_DIR/r30_4" "$TMP_DIR/cas_r30_4" "$TMP_DIR/r30_4_ok" "$TMP_DIR/cas_r30_4_ok" "$TMP_DIR/r30_4_cyc" \
  "$TMP_DIR/r30_o1" "$TMP_DIR/cas_r30_o1" "$TMP_DIR/r30_o1_cyc" \
  "$TMP_DIR/r30_o2" "$TMP_DIR/cas_r30_o2" "$TMP_DIR/r30_o2_cyc" \
  "$TMP_DIR/r30_o3" "$TMP_DIR/cas_r30_o3" "$TMP_DIR/r30_o3_cyc" \
  "$TMP_DIR/r30_o4" "$TMP_DIR/cas_r30_o4" "$TMP_DIR/r30_o4_cyc" \
  "$TMP_DIR/r30_o5" "$TMP_DIR/cas_r30_o5"

# 31a: Default param prior-param scope (#19) & unshadowed top-level fn default
cat > "$TMP_DIR/r30_1a/a.pion" <<'EOF'
let A : String = use_cb(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_1a/b.pion" <<'EOF'
fn f() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn use_cb(f : () -> Int, g : () -> Int = f) -> Int { g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_1a" "$PIONC" build -o "$TMP_DIR/r30_1a_c" "$TMP_DIR/r30_1a/a.pion" "$TMP_DIR/r30_1a/b.pion"
out_r30_1ac=$("$TMP_DIR/r30_1a_c"); test "$out_r30_1ac" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_1a/b.pion" > "$TMP_DIR/r30_1a/b2.pion" && mv "$TMP_DIR/r30_1a/b2.pion" "$TMP_DIR/r30_1a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_1a" "$PIONC" build -o "$TMP_DIR/r30_1a_h" "$TMP_DIR/r30_1a/a.pion" "$TMP_DIR/r30_1a/b.pion"
out_r30_1ah=$("$TMP_DIR/r30_1a_h"); test "$out_r30_1ah" = "9"

cat > "$TMP_DIR/r30_1a_ok/main.pion" <<'EOF'
fn f() -> Int { A }
fn zero() -> Int { 0 }
fn use_cb(f : () -> Int, g : () -> Int = f) -> Int { g() }
let A : Int = use_cb(zero)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_1a_ok" "$PIONC" build -o "$TMP_DIR/r30_1a_ok_b" "$TMP_DIR/r30_1a_ok/main.pion"
test "$("$TMP_DIR/r30_1a_ok_b")" = "0"

cat > "$TMP_DIR/r30_1a_cyc/main.pion" <<'EOF'
fn f() -> Int { 0 }
fn read_a() -> Int { A }
fn use_cb(f : () -> Int, g : () -> Int = f) -> Int { g() }
let A : Int = use_cb(read_a)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_1a_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r30_1b/a.pion" <<'EOF'
let A : String = use_cb_call(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_1b/b.pion" <<'EOF'
fn f() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn use_cb_call(f : () -> Int, x : Int = f()) -> Int { x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_1b" "$PIONC" build -o "$TMP_DIR/r30_1b_c" "$TMP_DIR/r30_1b/a.pion" "$TMP_DIR/r30_1b/b.pion"
out_r30_1bc=$("$TMP_DIR/r30_1b_c"); test "$out_r30_1bc" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_1b/b.pion" > "$TMP_DIR/r30_1b/b2.pion" && mv "$TMP_DIR/r30_1b/b2.pion" "$TMP_DIR/r30_1b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_1b" "$PIONC" build -o "$TMP_DIR/r30_1b_h" "$TMP_DIR/r30_1b/a.pion" "$TMP_DIR/r30_1b/b.pion"
out_r30_1bh=$("$TMP_DIR/r30_1b_h"); test "$out_r30_1bh" = "9"

cat > "$TMP_DIR/r30_1b_ok/main.pion" <<'EOF'
fn f() -> Int { A }
fn zero() -> Int { 0 }
fn use_cb_call(f : () -> Int, x : Int = f()) -> Int { x }
let A : Int = use_cb_call(zero)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_1b_ok" "$PIONC" build -o "$TMP_DIR/r30_1b_ok_b" "$TMP_DIR/r30_1b_ok/main.pion"
test "$("$TMP_DIR/r30_1b_ok_b")" = "0"

cat > "$TMP_DIR/r30_1b_cyc/main.pion" <<'EOF'
fn f() -> Int { 0 }
fn read_a() -> Int { A }
fn use_cb_call(f : () -> Int, x : Int = f()) -> Int { x }
let A : Int = use_cb_call(read_a)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_1b_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# Unshadowed top-level fn default still tracks B (cold/hot 7->9) and E_CONST_CYCLE
mkdir -p "$TMP_DIR/r30_1c" "$TMP_DIR/cas_r30_1c" "$TMP_DIR/r30_1c_cyc"
cat > "$TMP_DIR/r30_1c/a.pion" <<'EOF'
let A : String = use_top(0).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_1c/b.pion" <<'EOF'
fn top_f() -> Int { B }
fn make_b() -> Int { 7 }
fn use_top(x : Int, g : () -> Int = top_f) -> Int { x + g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_1c" "$PIONC" build -o "$TMP_DIR/r30_1c_c" "$TMP_DIR/r30_1c/a.pion" "$TMP_DIR/r30_1c/b.pion"
out_r30_1cc=$("$TMP_DIR/r30_1c_c"); test "$out_r30_1cc" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_1c/b.pion" > "$TMP_DIR/r30_1c/b2.pion" && mv "$TMP_DIR/r30_1c/b2.pion" "$TMP_DIR/r30_1c/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_1c" "$PIONC" build -o "$TMP_DIR/r30_1c_h" "$TMP_DIR/r30_1c/a.pion" "$TMP_DIR/r30_1c/b.pion"
out_r30_1ch=$("$TMP_DIR/r30_1c_h"); test "$out_r30_1ch" = "9"

cat > "$TMP_DIR/r30_1c_cyc/main.pion" <<'EOF'
fn top_f() -> Int { A }
fn use_top(x : Int, g : () -> Int = top_f) -> Int { x + g() }
let A : Int = use_top(0)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_1c_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# 31b: Astra #2 nested default arg sub-call default callback (`run(cb = install)`, `outer(x = run())`)
cat > "$TMP_DIR/r30_2/a.pion" <<'EOF'
let A : String = (outer() + H.run()).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_2/b.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_b; 0 }
fn run(cb : () -> Int = install) -> Int { cb() }
fn outer(x : Int = run()) -> Int { x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_2" "$PIONC" build -o "$TMP_DIR/r30_2_c" "$TMP_DIR/r30_2/a.pion" "$TMP_DIR/r30_2/b.pion"
out_r30_2c=$("$TMP_DIR/r30_2_c"); test "$out_r30_2c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_2/b.pion" > "$TMP_DIR/r30_2/b2.pion" && mv "$TMP_DIR/r30_2/b2.pion" "$TMP_DIR/r30_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_2" "$PIONC" build -o "$TMP_DIR/r30_2_h" "$TMP_DIR/r30_2/a.pion" "$TMP_DIR/r30_2/b.pion"
out_r30_2h=$("$TMP_DIR/r30_2_h"); test "$out_r30_2h" = "9"

cat > "$TMP_DIR/r30_2_ok/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn run(cb : () -> Int = install) -> Int { cb() }
fn outer(x : Int = run()) -> Int { x }
let A : Int = outer(0) + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_2_ok" "$PIONC" build -o "$TMP_DIR/r30_2_ok_c" "$TMP_DIR/r30_2_ok/main.pion"
test "$("$TMP_DIR/r30_2_ok_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r30_2_ok" "$PIONC" build -o "$TMP_DIR/r30_2_ok_h" "$TMP_DIR/r30_2_ok/main.pion"
test "$("$TMP_DIR/r30_2_ok_h")" = "0"

cat > "$TMP_DIR/r30_2_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn run(cb : () -> Int = install) -> Int { cb() }
fn outer(x : Int = run()) -> Int { x }
let A : Int = outer() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_2_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# 31c: Astra #3 8-level and 9-level zero-arg factory chains `go(mk)`
cat > "$TMP_DIR/r30_3a/a.pion" <<'EOF'
let A : String = go(f7).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_3a/b.pion" <<'EOF'
fn make_b() -> Int { 7 }
fn f0() -> Int { B }
fn f1() -> () -> Int { f0 }
fn f2() -> () -> (() -> Int) { f1 }
fn f3() -> () -> (() -> (() -> Int)) { f2 }
fn f4() -> () -> (() -> (() -> (() -> Int))) { f3 }
fn f5() -> () -> (() -> (() -> (() -> (() -> Int)))) { f4 }
fn f6() -> () -> (() -> (() -> (() -> (() -> (() -> Int))))) { f5 }
fn f7() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))) { f6 }
fn go(mk : () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))))) -> Int { mk()()()()()()()() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_3a" "$PIONC" build -o "$TMP_DIR/r30_3a_c" "$TMP_DIR/r30_3a/a.pion" "$TMP_DIR/r30_3a/b.pion"
out_r30_3ac=$("$TMP_DIR/r30_3a_c"); test "$out_r30_3ac" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_3a/b.pion" > "$TMP_DIR/r30_3a/b2.pion" && mv "$TMP_DIR/r30_3a/b2.pion" "$TMP_DIR/r30_3a/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_3a" "$PIONC" build -o "$TMP_DIR/r30_3a_h" "$TMP_DIR/r30_3a/a.pion" "$TMP_DIR/r30_3a/b.pion"
out_r30_3ah=$("$TMP_DIR/r30_3a_h"); test "$out_r30_3ah" = "9"

cat > "$TMP_DIR/r30_3a_cyc/main.pion" <<'EOF'
fn f0() -> Int { A }
fn f1() -> () -> Int { f0 }
fn f2() -> () -> (() -> Int) { f1 }
fn f3() -> () -> (() -> (() -> Int)) { f2 }
fn f4() -> () -> (() -> (() -> (() -> Int))) { f3 }
fn f5() -> () -> (() -> (() -> (() -> (() -> Int)))) { f4 }
fn f6() -> () -> (() -> (() -> (() -> (() -> (() -> Int))))) { f5 }
fn f7() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))) { f6 }
fn go(mk : () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))))) -> Int { mk()()()()()()()() }
let A : Int = go(f7)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_3a_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r30_3b/a.pion" <<'EOF'
let A : String = go(f8).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_3b/b.pion" <<'EOF'
fn make_b() -> Int { 7 }
fn f0() -> Int { B }
fn f1() -> () -> Int { f0 }
fn f2() -> () -> (() -> Int) { f1 }
fn f3() -> () -> (() -> (() -> Int)) { f2 }
fn f4() -> () -> (() -> (() -> (() -> Int))) { f3 }
fn f5() -> () -> (() -> (() -> (() -> (() -> Int)))) { f4 }
fn f6() -> () -> (() -> (() -> (() -> (() -> (() -> Int))))) { f5 }
fn f7() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))) { f6 }
fn f8() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int))))))) { f7 }
fn go(mk : () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int))))))))) -> Int { mk()()()()()()()()() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_3b" "$PIONC" build -o "$TMP_DIR/r30_3b_c" "$TMP_DIR/r30_3b/a.pion" "$TMP_DIR/r30_3b/b.pion"
out_r30_3bc=$("$TMP_DIR/r30_3b_c"); test "$out_r30_3bc" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_3b/b.pion" > "$TMP_DIR/r30_3b/b2.pion" && mv "$TMP_DIR/r30_3b/b2.pion" "$TMP_DIR/r30_3b/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_3b" "$PIONC" build -o "$TMP_DIR/r30_3b_h" "$TMP_DIR/r30_3b/a.pion" "$TMP_DIR/r30_3b/b.pion"
out_r30_3bh=$("$TMP_DIR/r30_3b_h"); test "$out_r30_3bh" = "9"

cat > "$TMP_DIR/r30_3b_cyc/main.pion" <<'EOF'
fn f0() -> Int { A }
fn f1() -> () -> Int { f0 }
fn f2() -> () -> (() -> Int) { f1 }
fn f3() -> () -> (() -> (() -> Int)) { f2 }
fn f4() -> () -> (() -> (() -> (() -> Int))) { f3 }
fn f5() -> () -> (() -> (() -> (() -> (() -> Int)))) { f4 }
fn f6() -> () -> (() -> (() -> (() -> (() -> (() -> Int))))) { f5 }
fn f7() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> Int)))))) { f6 }
fn f8() -> () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int))))))) { f7 }
fn go(mk : () -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> (() -> Int))))))))) -> Int { mk()()()()()()()()() }
let A : Int = go(f8)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_3b_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# 31d: Astra #4 top-level alias propagates `fn_called_ret_depths`
cat > "$TMP_DIR/r30_4/a.pion" <<'EOF'
let A : String = alias(reader_maker).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_4/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn reader_maker() -> () -> Int { read_b }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let alias : (() -> (() -> Int)) -> Int = go
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_4" "$PIONC" build -o "$TMP_DIR/r30_4_c" "$TMP_DIR/r30_4/a.pion" "$TMP_DIR/r30_4/b.pion"
out_r30_4c=$("$TMP_DIR/r30_4_c"); test "$out_r30_4c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_4/b.pion" > "$TMP_DIR/r30_4/b2.pion" && mv "$TMP_DIR/r30_4/b2.pion" "$TMP_DIR/r30_4/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_4" "$PIONC" build -o "$TMP_DIR/r30_4_h" "$TMP_DIR/r30_4/a.pion" "$TMP_DIR/r30_4/b.pion"
out_r30_4h=$("$TMP_DIR/r30_4_h"); test "$out_r30_4h" = "9"

cat > "$TMP_DIR/r30_4_ok/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn zero() -> Int { 0 }
fn safe_maker() -> () -> Int { zero }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let alias : (() -> (() -> Int)) -> Int = go
let A : Int = alias(safe_maker)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_4_ok" "$PIONC" build -o "$TMP_DIR/r30_4_ok_c" "$TMP_DIR/r30_4_ok/main.pion"
test "$("$TMP_DIR/r30_4_ok_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r30_4_ok" "$PIONC" build -o "$TMP_DIR/r30_4_ok_h" "$TMP_DIR/r30_4_ok/main.pion"
test "$("$TMP_DIR/r30_4_ok_h")" = "0"

cat > "$TMP_DIR/r30_4_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn reader_maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int)) -> Int { let h = Holder::{ run: mk() }; h.run() }
let alias : (() -> (() -> Int)) -> Int = go
let A : Int = alias(reader_maker)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_4_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# 31e: Opus 4+1 default callback cases
# O1: `fn g(f : () -> Int = read_x) -> Int { f() }; g()`
cat > "$TMP_DIR/r30_o1/a.pion" <<'EOF'
let A : String = g().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_o1/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn g(f : () -> Int = read_b) -> Int { f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_o1" "$PIONC" build -o "$TMP_DIR/r30_o1_c" "$TMP_DIR/r30_o1/a.pion" "$TMP_DIR/r30_o1/b.pion"
test "$("$TMP_DIR/r30_o1_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_o1/b.pion" > "$TMP_DIR/r30_o1/b2.pion" && mv "$TMP_DIR/r30_o1/b2.pion" "$TMP_DIR/r30_o1/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_o1" "$PIONC" build -o "$TMP_DIR/r30_o1_h" "$TMP_DIR/r30_o1/a.pion" "$TMP_DIR/r30_o1/b.pion"
test "$("$TMP_DIR/r30_o1_h")" = "9"
cat > "$TMP_DIR/r30_o1_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn g(f : () -> Int = read_a) -> Int { f() }
let A : Int = g()
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_o1_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# O2: `fn g(f : () -> Int = fn() -> Int { read_x() }) -> Int { f() }; g()`
cat > "$TMP_DIR/r30_o2/a.pion" <<'EOF'
let A : String = g().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_o2/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn g(f : () -> Int = fn() -> Int { read_b() }) -> Int { f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_o2" "$PIONC" build -o "$TMP_DIR/r30_o2_c" "$TMP_DIR/r30_o2/a.pion" "$TMP_DIR/r30_o2/b.pion"
test "$("$TMP_DIR/r30_o2_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_o2/b.pion" > "$TMP_DIR/r30_o2/b2.pion" && mv "$TMP_DIR/r30_o2/b2.pion" "$TMP_DIR/r30_o2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_o2" "$PIONC" build -o "$TMP_DIR/r30_o2_h" "$TMP_DIR/r30_o2/a.pion" "$TMP_DIR/r30_o2/b.pion"
test "$("$TMP_DIR/r30_o2_h")" = "9"
cat > "$TMP_DIR/r30_o2_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn g(f : () -> Int = fn() -> Int { read_a() }) -> Int { f() }
let A : Int = g()
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_o2_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# O3: `fn g(a : Int, f~ : () -> Int = read_x) -> Int { a + f() }; g(0)`
cat > "$TMP_DIR/r30_o3/a.pion" <<'EOF'
let A : String = g(0).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_o3/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn g(a : Int, f~ : () -> Int = read_b) -> Int { a + f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_o3" "$PIONC" build -o "$TMP_DIR/r30_o3_c" "$TMP_DIR/r30_o3/a.pion" "$TMP_DIR/r30_o3/b.pion"
test "$("$TMP_DIR/r30_o3_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_o3/b.pion" > "$TMP_DIR/r30_o3/b2.pion" && mv "$TMP_DIR/r30_o3/b2.pion" "$TMP_DIR/r30_o3/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_o3" "$PIONC" build -o "$TMP_DIR/r30_o3_h" "$TMP_DIR/r30_o3/a.pion" "$TMP_DIR/r30_o3/b.pion"
test "$("$TMP_DIR/r30_o3_h")" = "9"
cat > "$TMP_DIR/r30_o3_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn g(a : Int, f~ : () -> Int = read_a) -> Int { a + f() }
let A : Int = g(0)
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_o3_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# O4: `fn g(f : () -> Int = read_x) -> Holder { Holder::{ run: f } }; g().run()`
cat > "$TMP_DIR/r30_o4/a.pion" <<'EOF'
let A : String = g().run().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r30_o4/b.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn g(f : () -> Int = read_b) -> Holder { Holder::{ run: f } }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_o4" "$PIONC" build -o "$TMP_DIR/r30_o4_c" "$TMP_DIR/r30_o4/a.pion" "$TMP_DIR/r30_o4/b.pion"
test "$("$TMP_DIR/r30_o4_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r30_o4/b.pion" > "$TMP_DIR/r30_o4/b2.pion" && mv "$TMP_DIR/r30_o4/b2.pion" "$TMP_DIR/r30_o4/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r30_o4" "$PIONC" build -o "$TMP_DIR/r30_o4_h" "$TMP_DIR/r30_o4/a.pion" "$TMP_DIR/r30_o4/b.pion"
test "$("$TMP_DIR/r30_o4_h")" = "9"
cat > "$TMP_DIR/r30_o4_cyc/main.pion" <<'EOF'
struct Holder { run : () -> Int }
fn read_a() -> Int { A }
fn g(f : () -> Int = read_a) -> Holder { Holder::{ run: f } }
let A : Int = g().run()
pub fn main() -> Int { A }
EOF
set +e; r30_c=$("$PIONC" check --json "$TMP_DIR/r30_o4_cyc/main.pion" 2>&1); r30_rc=$?; set -e
test "$r30_rc" -ne 0; printf '%s' "$r30_c" | grep -q "E_CONST_CYCLE"

# O5: precision `fn g(f : () -> Int = read_a) -> Int { 0 }; g()` -> 0 -> 0, no cycle
cat > "$TMP_DIR/r30_o5/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn g(f : () -> Int = read_a) -> Int { 0 }
let A : Int = g()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r30_o5" "$PIONC" build -o "$TMP_DIR/r30_o5_c" "$TMP_DIR/r30_o5/main.pion"
test "$("$TMP_DIR/r30_o5_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r30_o5" "$PIONC" build -o "$TMP_DIR/r30_o5_h" "$TMP_DIR/r30_o5/main.pion"
test "$("$TMP_DIR/r30_o5_h")" = "0"

echo "  R30 cold/hot CAS (fdef-val $out_r30_1ac->$out_r30_1ah, fdef-call $out_r30_1bc->$out_r30_1bh, nested-fdef $out_r30_2c->$out_r30_2h, depth8/9 $out_r30_3ac->$out_r30_3ah/$out_r30_3bc->$out_r30_3bh, alias-retp $out_r30_4c->$out_r30_4h, Opus 4+1 7->9/0->0) & 10x cycles (OK)"

echo "=== Wave J1 E2E [32/32]: R31 default arg lexical hygiene (no SIGSEGV), active_fdef rescan & 65/66-level transitive ret ==="
mkdir -p \
  "$TMP_DIR/r31_1_d1" "$TMP_DIR/cas_r31_1_d1" \
  "$TMP_DIR/r31_1_d2" "$TMP_DIR/cas_r31_1_d2" "$TMP_DIR/r31_1_d2_cyc" \
  "$TMP_DIR/r31_1_d3_cyc" \
  "$TMP_DIR/r31_1_op1" "$TMP_DIR/cas_r31_1_op1" \
  "$TMP_DIR/r31_1_op2" "$TMP_DIR/cas_r31_1_op2" \
  "$TMP_DIR/r31_2" "$TMP_DIR/cas_r31_2" "$TMP_DIR/r31_2_ok" "$TMP_DIR/cas_r31_2_ok" "$TMP_DIR/r31_2_cyc" \
  "$TMP_DIR/r31_3_65" "$TMP_DIR/cas_r31_3_65" "$TMP_DIR/r31_3_65_cyc" \
  "$TMP_DIR/r31_3_66" "$TMP_DIR/cas_r31_3_66" "$TMP_DIR/r31_3_66_cyc"

# 32a: Astra #1 lexical hygiene (Dir 1: 0->0; Dir 2: cyc + 7->9; Dir 3: explicit local cyc)
cat > "$TMP_DIR/r31_1_d1/main.pion" <<'EOF'
fn f() -> Int { 0 }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn use_cb(f : () -> Int, g : () -> Int = f) -> Int { g() }
let A : Int = { let f = read_a; use_cb(zero) }
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_d1" "$PIONC" build -o "$TMP_DIR/r31_1_d1_c" "$TMP_DIR/r31_1_d1/main.pion"
test "$("$TMP_DIR/r31_1_d1_c")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_d1" "$PIONC" build -o "$TMP_DIR/r31_1_d1_h" "$TMP_DIR/r31_1_d1/main.pion"
test "$("$TMP_DIR/r31_1_d1_h")" = "0"

cat > "$TMP_DIR/r31_1_d2/a.pion" <<'EOF'
let A : String = { let f = zero; use_cb(0) }.to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r31_1_d2/b.pion" <<'EOF'
fn f() -> Int { B }
fn zero() -> Int { 0 }
fn make_b() -> Int { 7 }
fn use_cb(x : Int, g : () -> Int = f) -> Int { x + g() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_d2" "$PIONC" build -o "$TMP_DIR/r31_1_d2_c" "$TMP_DIR/r31_1_d2/a.pion" "$TMP_DIR/r31_1_d2/b.pion"
out_r31_d2c=$("$TMP_DIR/r31_1_d2_c"); test "$out_r31_d2c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r31_1_d2/b.pion" > "$TMP_DIR/r31_1_d2/b2.pion" && mv "$TMP_DIR/r31_1_d2/b2.pion" "$TMP_DIR/r31_1_d2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_d2" "$PIONC" build -o "$TMP_DIR/r31_1_d2_h" "$TMP_DIR/r31_1_d2/a.pion" "$TMP_DIR/r31_1_d2/b.pion"
out_r31_d2h=$("$TMP_DIR/r31_1_d2_h"); test "$out_r31_d2h" = "9"

cat > "$TMP_DIR/r31_1_d2_cyc/main.pion" <<'EOF'
fn f() -> Int { A }
fn zero() -> Int { 0 }
fn use_cb(x : Int, g : () -> Int = f) -> Int { x + g() }
let A : Int = { let f = zero; use_cb(0) }
pub fn main() -> Int { A }
EOF
set +e; r31_c=$("$PIONC" check --json "$TMP_DIR/r31_1_d2_cyc/main.pion" 2>&1); r31_rc=$?; set -e
test "$r31_rc" -ne 0; printf '%s' "$r31_c" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r31_1_d3_cyc/main.pion" <<'EOF'
fn f() -> Int { 0 }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn use_cb(f : () -> Int, g : () -> Int = f) -> Int { g() }
let A : Int = { let f = read_a; use_cb(zero, f) }
pub fn main() -> Int { A }
EOF
set +e; r31_c=$("$PIONC" check --json "$TMP_DIR/r31_1_d3_cyc/main.pion" 2>&1); r31_rc=$?; set -e
test "$r31_rc" -ne 0; printf '%s' "$r31_c" | grep -q "E_CONST_CYCLE"

# 32b: Opus #1 runtime no-const SIGSEGV repros (must output 0, never rc=139)
cat > "$TMP_DIR/r31_1_op1/main.pion" <<'EOF'
fn pick() -> Int { 0 }
fn one() -> Int { 1 }
fn g(x : Int = pick()) -> Int { x }
pub fn main(world : World) -> Unit {
  let pick = one
  io_println(world, g().to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_op1" "$PIONC" build -o "$TMP_DIR/r31_1_op1_b" "$TMP_DIR/r31_1_op1/main.pion"
test "$("$TMP_DIR/r31_1_op1_b")" = "0"

cat > "$TMP_DIR/r31_1_op2/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn one() -> Int { 1 }
fn g(f : () -> Int = zero) -> Int { f() }
pub fn main(world : World) -> Unit {
  let zero = one
  io_println(world, g().to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_1_op2" "$PIONC" build -o "$TMP_DIR/r31_1_op2_b" "$TMP_DIR/r31_1_op2/main.pion"
test "$("$TMP_DIR/r31_1_op2_b")" = "0"

# 32c: Astra #2 active_fdef_idxs fixed-point rescan (`let g = cb; let h = fn() { g() }; h()`)
cat > "$TMP_DIR/r31_2/a.pion" <<'EOF'
let A : String = (outer() + H.run()).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r31_2/b.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_b; 0 }
fn run(cb : () -> Int = install) -> Int { let g = cb; let h = fn() -> Int { g() }; h() }
fn outer(x : Int = run()) -> Int { x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_2" "$PIONC" build -o "$TMP_DIR/r31_2_c" "$TMP_DIR/r31_2/a.pion" "$TMP_DIR/r31_2/b.pion"
out_r31_2c=$("$TMP_DIR/r31_2_c"); test "$out_r31_2c" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r31_2/b.pion" > "$TMP_DIR/r31_2/b2.pion" && mv "$TMP_DIR/r31_2/b2.pion" "$TMP_DIR/r31_2/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r31_2" "$PIONC" build -o "$TMP_DIR/r31_2_h" "$TMP_DIR/r31_2/a.pion" "$TMP_DIR/r31_2/b.pion"
out_r31_2h=$("$TMP_DIR/r31_2_h"); test "$out_r31_2h" = "9"

cat > "$TMP_DIR/r31_2_ok/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn run(cb : () -> Int = install) -> Int { let g = cb; let h = fn() -> Int { g() }; h() }
fn outer(x : Int = run()) -> Int { x }
let A : Int = outer(0) + H.run()
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r31_2_ok" "$PIONC" build -o "$TMP_DIR/r31_2_ok_b" "$TMP_DIR/r31_2_ok/main.pion"
test "$("$TMP_DIR/r31_2_ok_b")" = "0"

cat > "$TMP_DIR/r31_2_cyc/main.pion" <<'EOF'
struct Live { mut run : () -> Int }
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
let H : Live = Live::{ run: zero }
fn install() -> Int { H.run = read_a; 0 }
fn run(cb : () -> Int = install) -> Int { let g = cb; let h = fn() -> Int { g() }; h() }
fn outer(x : Int = run()) -> Int { x }
let A : Int = outer() + H.run()
pub fn main() -> Int { A }
EOF
set +e; r31_c=$("$PIONC" check --json "$TMP_DIR/r31_2_cyc/main.pion" 2>&1); r31_rc=$?; set -e
test "$r31_rc" -ne 0; printf '%s' "$r31_c" | grep -q "E_CONST_CYCLE"

# 32d: Astra #3 + Opus #2: 65-level and 66-level factory chains (cyc + 2-file cold 7 -> hot 9)
for dp in 65 66; do
  dir="$TMP_DIR/r31_3_${dp}"
  cdir="$TMP_DIR/r31_3_${dp}_cyc"
  cas="$TMP_DIR/cas_r31_3_${dp}"
  last=$((dp - 1))
  printf 'let A : String = go(f%d).to_string()\npub fn main(world : World) -> Unit { io_println(world, A) }\n' "$last" > "$dir/a.pion"
  {
    echo 'fn make_b() -> Int { 7 }'
    echo 'fn f0() -> Int { B }'
    ty='() -> Int'
    i=1
    while [ "$i" -lt "$dp" ]; do
      prev=$((i - 1))
      printf 'fn f%d() -> %s { f%d }\n' "$i" "$ty" "$prev"
      ty="() -> ($ty)"
      i=$((i + 1))
    done
    calls=""
    i=0
    while [ "$i" -lt "$dp" ]; do
      calls="${calls}()"
      i=$((i + 1))
    done
    printf 'fn go(mk : %s) -> Int { mk%s }\n' "$ty" "$calls"
    echo 'let B : Int = make_b()'
  } > "$dir/b.pion"
  PION_CACHE_DIR="$cas" "$PIONC" build -o "$TMP_DIR/r31_3_${dp}_c" "$dir/a.pion" "$dir/b.pion"
  out_c=$("$TMP_DIR/r31_3_${dp}_c"); test "$out_c" = "7"
  sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$dir/b.pion" > "$dir/b2.pion" && mv "$dir/b2.pion" "$dir/b.pion"
  PION_CACHE_DIR="$cas" "$PIONC" build -o "$TMP_DIR/r31_3_${dp}_h" "$dir/a.pion" "$dir/b.pion"
  out_h=$("$TMP_DIR/r31_3_${dp}_h"); test "$out_h" = "9"
  {
    echo 'fn f0() -> Int { A }'
    ty='() -> Int'
    i=1
    while [ "$i" -lt "$dp" ]; do
      prev=$((i - 1))
      printf 'fn f%d() -> %s { f%d }\n' "$i" "$ty" "$prev"
      ty="() -> ($ty)"
      i=$((i + 1))
    done
    calls=""
    i=0
    while [ "$i" -lt "$dp" ]; do
      calls="${calls}()"
      i=$((i + 1))
    done
    printf 'fn go(mk : %s) -> Int { mk%s }\n' "$ty" "$calls"
    printf 'let A : Int = go(f%d)\npub fn main() -> Int { A }\n' "$last"
  } > "$cdir/main.pion"
  set +e; r31_c=$("$PIONC" check --json "$cdir/main.pion" 2>&1); r31_rc=$?; set -e
  test "$r31_rc" -ne 0; printf '%s' "$r31_c" | grep -q "E_CONST_CYCLE"
done

echo "  R31 cold/hot CAS (hygiene 0->0/$out_r31_d2c->$out_r31_d2h + Opus no-SIGSEGV 0/0, fdef-rescan $out_r31_2c->$out_r31_2h/0, depth65/66 7->9/7->9) & 5x cycles (OK)"

echo "=== Wave J1 E2E [33/33]: R32 default arg llbc K-hygiene, closure return=42 & generic T default_expr ==="
mkdir -p \
  "$TMP_DIR/r32_k" "$TMP_DIR/cas_r32_k" \
  "$TMP_DIR/r32_ret" "$TMP_DIR/cas_r32_ret" \
  "$TMP_DIR/r32_gen" "$TMP_DIR/cas_r32_gen"

cat > "$TMP_DIR/r32_k/main.pion" <<'EOF'
let K : Int = 7
fn g(x : Int = K) -> Int { x }
fn outer(K : Int) -> Int { g() }
pub fn main(world : World) -> Unit { io_println(world, outer(9).to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r32_k" "$PIONC" build -o "$TMP_DIR/r32_k_b" "$TMP_DIR/r32_k/main.pion"
test "$("$TMP_DIR/r32_k_b")" = "7"

cat > "$TMP_DIR/r32_ret/main.pion" <<'EOF'
fn g(f : () -> Int = fn() -> Int { return 42 }) -> Int { f() }
pub fn main(world : World) -> Unit { io_println(world, g().to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r32_ret" "$PIONC" build -o "$TMP_DIR/r32_ret_b" "$TMP_DIR/r32_ret/main.pion"
test "$("$TMP_DIR/r32_ret_b")" = "42"

cat > "$TMP_DIR/r32_gen/main.pion" <<'EOF'
fn g[T](x : T, n : Int = { let xs : Array[T] = []; xs.length() }) -> Int { let _ = x; n }
fn caller[T](y : T) -> Int { let _ = y; g(7) }
pub fn main(world : World) -> Unit { io_println(world, (g(7) + caller("hi")).to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r32_gen" "$PIONC" build -o "$TMP_DIR/r32_gen_b" "$TMP_DIR/r32_gen/main.pion"
test "$("$TMP_DIR/r32_gen_b")" = "0"

echo "  R32 runtime (outer(9)==7, default-closure return==42, generic g(7)+caller(\"hi\")==0) (OK)"

echo "=== Wave J1 E2E [34/34]: R33 cross-pkg default K/Item/generic T, DImpl decl check & forbid ? in default_expr ==="
mkdir -p \
  "$TMP_DIR/r33_xpkg/dep/src" "$TMP_DIR/r33_xpkg/app/src" "$TMP_DIR/cas_r33_xpkg" \
  "$TMP_DIR/r33_try_bad" "$TMP_DIR/r33_try_ok" "$TMP_DIR/cas_r33_try_ok"

# 34a: Cross-pkg `dep` (K=7 + Item + id_len[T]) imported by `app` (conflicting K=9 & incompatible Item)
cat > "$TMP_DIR/r33_xpkg/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r33_xpkg/dep/src/lib.pion" <<'EOF'
let K : Int = 7
pub struct Item { v : Int }
pub fn g_k(x : Int = K) -> Int { x }
pub fn g_item(n : Int = { let xs : Array[Item] = []; xs.length() }) -> Int { n }
pub fn id_len[T](x : T, n : Int = { let xs : Array[T] = []; xs.length() }) -> Int { let _ = x; n }
EOF
cat > "$TMP_DIR/r33_xpkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r33_xpkg/app/src/main.pion" <<'EOF'
import "dep"
let K : Int = 9
struct Item { s : String }
pub fn main(world : World) -> Unit {
  let _ = Item::{ s: "x" }
  let res = dep::g_k() + dep::g_item() + dep::id_len(7) + dep::id_len("hi")
  io_println(world, res.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r33_xpkg" "$PIONC" build -o "$TMP_DIR/r33_xpkg_b" "$TMP_DIR/r33_xpkg/app"
test "$("$TMP_DIR/r33_xpkg_b")" = "7"

# 34b: Opus h5 — `?` directly in default_expr rejected; `?` inside closure in default_expr runs cleanly -> 42
cat > "$TMP_DIR/r33_try_bad/main.pion" <<'EOF'
fn parse(flag : Bool) -> Result[Int, String] { if flag { Ok(1) } else { Err("bad") } }
fn g(x : Int = parse(false)?) -> Result[Int, String] { Ok(x) }
fn caller() -> Result[Int, String] { g() }
pub fn main() -> Int { let _ = caller(); 0 }
EOF
set +e; r33_c=$("$PIONC" check --json "$TMP_DIR/r33_try_bad/main.pion" 2>&1); r33_rc=$?; set -e
test "$r33_rc" -ne 0; printf '%s' "$r33_c" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r33_try_ok/main.pion" <<'EOF'
fn parse(flag : Bool) -> Result[Int, String] { if flag { Ok(42) } else { Err("bad") } }
fn g(f : () -> Result[Int, String] = fn() -> Result[Int, String] { let n = parse(true)?; Ok(n) }) -> Int {
  match f() { Ok(v) => v, Err(_) => -1 }
}
pub fn main(world : World) -> Unit { io_println(world, g().to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r33_try_ok" "$PIONC" build -o "$TMP_DIR/r33_try_ok_b" "$TMP_DIR/r33_try_ok/main.pion"
test "$("$TMP_DIR/r33_try_ok_b")" = "42"

echo "  R33 runtime (xpkg K/Item/id_len==7, forbid ? E_TYPE_MISMATCH, default-closure ?==42) (OK)"

echo "=== Wave J1 E2E [35/35]: R34 default arg break/continue, xpkg is-binding & private Item lazy import ==="
mkdir -p \
  "$TMP_DIR/r34_brk_bad" "$TMP_DIR/r34_loop_ok" "$TMP_DIR/cas_r34_loop_ok" \
  "$TMP_DIR/r34_xpkg/dep/src" "$TMP_DIR/r34_xpkg/app/src" "$TMP_DIR/cas_r34_xpkg" \
  "$TMP_DIR/r34_priv_bad/src"

# 35a: bare `break` in default_expr rejected; default_expr's own while loop with continue/break runs -> 4 (1+3)
cat > "$TMP_DIR/r34_brk_bad/main.pion" <<'EOF'
fn f(x : Int = { break; 7 }) -> Int { x }
pub fn main() -> Int { let mut i = 0; while i < 1 { i = i + 1; let _ = f() }; i }
EOF
set +e; r34_c=$("$PIONC" check --json "$TMP_DIR/r34_brk_bad/main.pion" 2>&1); r34_rc=$?; set -e
test "$r34_rc" -ne 0; printf '%s' "$r34_c" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r34_loop_ok/main.pion" <<'EOF'
fn f(x : Int = {
  let mut s = 0
  let mut i = 0
  while i < 5 {
    i = i + 1
    if i == 2 { continue }
    if i == 4 { break }
    s = s + i
  }
  s
}) -> Int { x }
pub fn main(world : World) -> Unit { io_println(world, f().to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r34_loop_ok" "$PIONC" build -o "$TMP_DIR/r34_loop_ok_b" "$TMP_DIR/r34_loop_ok/main.pion"
test "$("$TMP_DIR/r34_loop_ok_b")" = "4"

# 35b: cross-pkg `is` condition bindings (7 + 99 + 7 = 113) + private `struct Item` in default_expr (0)
cat > "$TMP_DIR/r34_xpkg/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r34_xpkg/dep/src/lib.pion" <<'EOF'
let k : Int = 99
struct Item { v : Int }
pub fn pick_if(x : Int = if Some(7) is Some(k) && k > 0 { k } else { k }) -> Int { x }
pub fn pick_else(x : Int = { let o : Option[Int] = None; if o is Some(k) { k } else { k } }) -> Int { x }
pub fn pick_guard(x : Int = { guard Some(7) is Some(k) else { panic("no") }; k }) -> Int { x }
pub fn priv_item(n : Int = { let xs : Array[Item] = []; xs.length() }) -> Int { n }
EOF
cat > "$TMP_DIR/r34_xpkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r34_xpkg/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  let res = dep::pick_if() + dep::pick_else() + dep::pick_guard() + dep::priv_item()
  io_println(world, res.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r34_xpkg" "$PIONC" build -o "$TMP_DIR/r34_xpkg_b" "$TMP_DIR/r34_xpkg/app"
test "$("$TMP_DIR/r34_xpkg_b")" = "113"

# 35c: direct reference to `dep::Item` in consumer AFTER `dep::priv_item()` still fails E_PRIVATE_SYMBOL
cat > "$TMP_DIR/r34_priv_bad/pion.toml" <<'EOF'
[package]
name = "app_bad"
version = "0.1.0"

[dependencies]
dep = { path = "../r34_xpkg/dep" }
EOF
cat > "$TMP_DIR/r34_priv_bad/src/main.pion" <<'EOF'
import "dep"
pub fn main() -> Int {
  let _ = dep::priv_item()
  let xs : Array[dep::Item] = []
  xs.length()
}
EOF
set +e; r34_p=$("$PIONC" check --json "$TMP_DIR/r34_priv_bad" 2>&1); r34_prc=$?; set -e
test "$r34_prc" -ne 0; printf '%s' "$r34_p" | grep -q "E_PRIVATE_SYMBOL"

echo "  R34 runtime (own-loop==4, xpkg is+priv-Item==113, bare break E_TYPE_MISMATCH, direct priv Item E_PRIVATE_SYMBOL) (OK)"

echo "=== Wave J1 E2E [36/36]: R35 private enum ctors, 3-pkg dep->bridge->app isolation, alias hijack & value && is-scoping ==="
mkdir -p \
  "$TMP_DIR/r35/dep/src" "$TMP_DIR/r35/bridge/src" "$TMP_DIR/r35/decoy/src" \
  "$TMP_DIR/r35/app_enum_val/src" "$TMP_DIR/r35/app_enum_call/src" \
  "$TMP_DIR/r35/app_3pkg_item/src" "$TMP_DIR/r35/app_3pkg_sec/src" \
  "$TMP_DIR/r35/app_alias_ok/src" "$TMP_DIR/cas_r35_alias" \
  "$TMP_DIR/r35/app_val_and/src" "$TMP_DIR/cas_r35_val_and"

cat > "$TMP_DIR/r35/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r35/dep/src/lib.pion" <<'EOF'
struct Item { v : Int }
enum Secret { Empty; Wrap(Int) }
let K : Int = 7
let k : Bool = true
pub fn priv_item(n : Int = { let xs : Array[Item] = []; xs.length() }) -> Int { n }
pub fn use_secret(n : Int = { let xs : Array[Secret] = []; xs.length() }) -> Int { n }
pub fn g_k(x : Int = K) -> Int { x }
pub fn opt_k(x : Int = K) -> Option[Int] { Some(x) }
pub fn val_and(b : Bool = (Some(false) is Some(k)) && k) -> Bool { b }
EOF

cat > "$TMP_DIR/r35/bridge/pion.toml" <<'EOF'
[package]
name = "bridge"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/bridge/src/lib.pion" <<'EOF'
import "dep"
pub fn run_bridge() -> Int { dep::priv_item() + dep::use_secret() }
EOF

cat > "$TMP_DIR/r35/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r35/decoy/src/lib.pion" <<'EOF'
pub struct Item { s : String }
pub let K : Int = 999
EOF

# 36a: private enum value & call ctors rejected after default-arg call
cat > "$TMP_DIR/r35/app_enum_val/pion.toml" <<'EOF'
[package]
name = "app_enum_val"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/app_enum_val/src/main.pion" <<'EOF'
import "dep"
pub fn main() -> Int { let _ = dep::use_secret(); let _ = dep::Secret::Empty; 0 }
EOF
set +e; r35_ev=$("$PIONC" check --json "$TMP_DIR/r35/app_enum_val" 2>&1); r35_evrc=$?; set -e
test "$r35_evrc" -ne 0; printf '%s' "$r35_ev" | grep -q "E_PRIVATE_SYMBOL"

cat > "$TMP_DIR/r35/app_enum_call/pion.toml" <<'EOF'
[package]
name = "app_enum_call"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/app_enum_call/src/main.pion" <<'EOF'
import "dep"
pub fn main() -> Int { let _ = dep::use_secret(); let _ = dep::Secret::Wrap(1); 0 }
EOF
set +e; r35_ec=$("$PIONC" check --json "$TMP_DIR/r35/app_enum_call" 2>&1); r35_ecrc=$?; set -e
test "$r35_ecrc" -ne 0; printf '%s' "$r35_ec" | grep -q "E_PRIVATE_SYMBOL"

# 36b: 3-pkg dep -> bridge -> app does NOT leak dep::Item / dep::Secret
cat > "$TMP_DIR/r35/app_3pkg_item/pion.toml" <<'EOF'
[package]
name = "app_3pkg_item"
version = "0.1.0"
[dependencies]
bridge = { path = "../bridge" }
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/app_3pkg_item/src/main.pion" <<'EOF'
import "bridge"
import "dep"
pub fn main() -> Int { let _ = bridge::run_bridge(); let xs : Array[dep::Item] = []; xs.length() }
EOF
set +e; r35_3i=$("$PIONC" check --json "$TMP_DIR/r35/app_3pkg_item" 2>&1); r35_3irc=$?; set -e
test "$r35_3irc" -ne 0; printf '%s' "$r35_3i" | grep -q "E_PRIVATE_SYMBOL"

cat > "$TMP_DIR/r35/app_3pkg_sec/pion.toml" <<'EOF'
[package]
name = "app_3pkg_sec"
version = "0.1.0"
[dependencies]
bridge = { path = "../bridge" }
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/app_3pkg_sec/src/main.pion" <<'EOF'
import "bridge"
import "dep"
pub fn main() -> Int { let _ = bridge::run_bridge(); let _ = dep::Secret::Empty; 0 }
EOF
set +e; r35_3s=$("$PIONC" check --json "$TMP_DIR/r35/app_3pkg_sec" 2>&1); r35_3src=$?; set -e
test "$r35_3src" -ne 0; printf '%s' "$r35_3s" | grep -q "E_PRIVATE_SYMBOL"

# 36c: alias hijack `import "dep" as lib; import "decoy" as dep` Native E2E (debug + --release scalar inline) -> lib::priv_item()=0, lib::g_k()=7, lib::opt_k()=Some(7), dep::Item=decoy(len 2) => 16
cat > "$TMP_DIR/r35/app_alias_ok/pion.toml" <<'EOF'
[package]
name = "app_alias_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r35/app_alias_ok/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let a = lib::priv_item()
  let b = lib::g_k()
  let c = match lib::opt_k() { Some(v) => v, None => -1 }
  let d = dep::Item::{ s: "ok" }
  io_println(world, (a + b + c + d.s.length()).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r35_alias" "$PIONC" build -o "$TMP_DIR/r35_alias_b" "$TMP_DIR/r35/app_alias_ok"
test "$("$TMP_DIR/r35_alias_b")" = "16"
PION_CACHE_DIR="$TMP_DIR/cas_r35_alias_rel" "$PIONC" build --release -o "$TMP_DIR/r35_alias_rel_b" "$TMP_DIR/r35/app_alias_ok"
test "$("$TMP_DIR/r35_alias_rel_b")" = "16"

# 36d: Wave L1-A A2 unified `&&` is-scoping: `(Some(false) is Some(k)) && k` binds `k = false` in RHS (0),
# never leaking `dep::k` (true) or `app::k`.
cat > "$TMP_DIR/r35/app_val_and/pion.toml" <<'EOF'
[package]
name = "app_val_and"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r35/app_val_and/src/main.pion" <<'EOF'
import "dep"
let k : Bool = true
pub fn main(world : World) -> Unit {
  let _ = k
  let r = if dep::val_and() { 1 } else { 0 }
  io_println(world, r.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r35_val_and" "$PIONC" build -o "$TMP_DIR/r35_val_and_b" "$TMP_DIR/r35/app_val_and"
test "$("$TMP_DIR/r35_val_and_b")" = "0"

echo "  R35 runtime (priv-enum val/call E_PRIVATE_SYMBOL, 3-pkg isolation E_PRIVATE_SYMBOL, alias-hijack==16 debug+--release, val-and==0) (OK)"

echo "=== Wave J1 E2E [37/37]: R36 canonical Ty lookup vs alias, missing struct in aliased pkg, PVariant resolved visibility & FnInfo.is_imported ==="
mkdir -p \
  "$TMP_DIR/r36/dep/src" "$TMP_DIR/r36/decoy/src" \
  "$TMP_DIR/r36/app_fields/src" "$TMP_DIR/cas_r36_fields" "$TMP_DIR/cas_r36_fields_rel" \
  "$TMP_DIR/r36/dep2/src" "$TMP_DIR/r36/decoy2/src" \
  "$TMP_DIR/r36/app_missing_bad/src" "$TMP_DIR/r36/app_missing_ok/src" "$TMP_DIR/cas_r36_missing_ok" \
  "$TMP_DIR/r36/dep3/src" "$TMP_DIR/r36/decoy3/src" \
  "$TMP_DIR/r36/app_pvar_ok/src" "$TMP_DIR/cas_r36_pvar_ok" "$TMP_DIR/r36/app_pvar_bad/src" \
  "$TMP_DIR/r36/Lib/src" "$TMP_DIR/r36/decoy4/src" \
  "$TMP_DIR/r36/app_lib_struct/src" "$TMP_DIR/cas_r36_lib_struct" "$TMP_DIR/cas_r36_lib_struct_rel"

# 37a: canonical TStruct field offsets must NOT be redirected to decoy's reversed fields (debug + --release)
cat > "$TMP_DIR/r36/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/dep/src/lib.pion" <<'EOF'
pub struct Item { first : Int; second : Int }
pub fn make() -> Item {
  let mut a = 0
  let mut i = 0
  while i < 1 { a = a + 11; i = i + 1 }
  Item::{ first: a, second: 22 }
}
EOF
cat > "$TMP_DIR/r36/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/decoy/src/lib.pion" <<'EOF'
pub struct Item { second : Int; first : Int }
EOF
cat > "$TMP_DIR/r36/app_fields/pion.toml" <<'EOF'
[package]
name = "app_fields"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r36/app_fields/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let it = lib::make()
  io_println(world, it.first.to_string() + ":" + it.second.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r36_fields" "$PIONC" build -o "$TMP_DIR/r36_fields_b" "$TMP_DIR/r36/app_fields"
test "$("$TMP_DIR/r36_fields_b")" = "11:22"
PION_CACHE_DIR="$TMP_DIR/cas_r36_fields_rel" "$PIONC" build --release -o "$TMP_DIR/r36_fields_rel_b" "$TMP_DIR/r36/app_fields"
test "$("$TMP_DIR/r36_fields_rel_b")" = "11:22"

# 37b: missing struct in aliased decoy must fail (NOT fall back to dep::Item), while lib::Item works -> 7
cat > "$TMP_DIR/r36/dep2/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/dep2/src/lib.pion" <<'EOF'
pub struct Item { v : Int }
EOF
cat > "$TMP_DIR/r36/decoy2/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/decoy2/src/lib.pion" <<'EOF'
pub fn noop() -> Int { 0 }
EOF
cat > "$TMP_DIR/r36/app_missing_bad/pion.toml" <<'EOF'
[package]
name = "app_missing_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep2" }
decoy = { path = "../decoy2" }
EOF
cat > "$TMP_DIR/r36/app_missing_bad/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main() -> Int { let _ = lib::Item::{ v: 1 }; let x = dep::Item::{ v: 7 }; x.v }
EOF
set +e; r36_mb=$("$PIONC" check --json "$TMP_DIR/r36/app_missing_bad" 2>&1); r36_mbrc=$?; set -e
test "$r36_mbrc" -ne 0; printf '%s' "$r36_mb" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r36/app_missing_ok/pion.toml" <<'EOF'
[package]
name = "app_missing_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep2" }
decoy = { path = "../decoy2" }
EOF
cat > "$TMP_DIR/r36/app_missing_ok/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let _ = dep::noop()
  let x = lib::Item::{ v: 7 }
  io_println(world, x.v.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r36_missing_ok" "$PIONC" build -o "$TMP_DIR/r36_missing_ok_b" "$TMP_DIR/r36/app_missing_ok"
test "$("$TMP_DIR/r36_missing_ok_b")" = "7"

# 37c: PVariant resolved visibility (decoy pub Secret matches before & after lib::use_secret() -> 3; lib::Secret::Empty -> E_PRIVATE_SYMBOL)
cat > "$TMP_DIR/r36/dep3/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/dep3/src/lib.pion" <<'EOF'
enum Secret { Empty }
pub fn use_secret(n : Int = { let xs : Array[Secret] = []; xs.length() }) -> Int { n }
EOF
cat > "$TMP_DIR/r36/decoy3/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/decoy3/src/lib.pion" <<'EOF'
pub enum Secret { Empty }
pub fn make() -> Secret { Secret::Empty }
EOF
cat > "$TMP_DIR/r36/app_pvar_ok/pion.toml" <<'EOF'
[package]
name = "app_pvar_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep3" }
decoy = { path = "../decoy3" }
EOF
cat > "$TMP_DIR/r36/app_pvar_ok/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let a = match dep::make() { dep::Secret::Empty => 1 }
  let _ = lib::use_secret()
  let b = match dep::make() { dep::Secret::Empty => 2 }
  io_println(world, (a + b).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r36_pvar_ok" "$PIONC" build -o "$TMP_DIR/r36_pvar_ok_b" "$TMP_DIR/r36/app_pvar_ok"
test "$("$TMP_DIR/r36_pvar_ok_b")" = "3"

cat > "$TMP_DIR/r36/app_pvar_bad/pion.toml" <<'EOF'
[package]
name = "app_pvar_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep3" }
decoy = { path = "../decoy3" }
EOF
cat > "$TMP_DIR/r36/app_pvar_bad/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main() -> Int { let _ = lib::use_secret(); let _ = lib::Secret::Empty; 0 }
EOF
set +e; r36_pb=$("$PIONC" check --json "$TMP_DIR/r36/app_pvar_bad" 2>&1); r36_pbrc=$?; set -e
test "$r36_pbrc" -ne 0; printf '%s' "$r36_pb" | grep -q "E_PRIVATE_SYMBOL"

# 37d: FnInfo.is_imported with local `struct Lib` colliding with imported pkg `"Lib"` -> actual::g() returns 7 (debug + --release)
cat > "$TMP_DIR/r36/Lib/pion.toml" <<'EOF'
[package]
name = "Lib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/Lib/src/lib.pion" <<'EOF'
let K : Int = 7
pub fn g(x : Int = K) -> Int { x }
EOF
cat > "$TMP_DIR/r36/decoy4/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r36/decoy4/src/lib.pion" <<'EOF'
pub let K : String = "bad"
EOF
cat > "$TMP_DIR/r36/app_lib_struct/pion.toml" <<'EOF'
[package]
name = "app_lib_struct"
version = "0.1.0"
[dependencies]
Lib = { path = "../Lib" }
decoy = { path = "../decoy4" }
EOF
cat > "$TMP_DIR/r36/app_lib_struct/src/main.pion" <<'EOF'
import "Lib" as actual
import "decoy" as Lib
struct Lib { x : Int }
pub fn main(world : World) -> Unit {
  let l = Lib::{ x: actual::g() }
  let _ = Lib::K
  io_println(world, l.x.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r36_lib_struct" "$PIONC" build -o "$TMP_DIR/r36_lib_struct_b" "$TMP_DIR/r36/app_lib_struct"
test "$("$TMP_DIR/r36_lib_struct_b")" = "7"
PION_CACHE_DIR="$TMP_DIR/cas_r36_lib_struct_rel" "$PIONC" build --release -o "$TMP_DIR/r36_lib_struct_rel_b" "$TMP_DIR/r36/app_lib_struct"
test "$("$TMP_DIR/r36_lib_struct_rel_b")" = "7"

echo "  R36 runtime (canon-Ty 11:22 debug+--release, missing-struct E_TYPE_MISMATCH/lib==7, PVariant==3/priv E_PRIVATE_SYMBOL, struct-Lib-collision==7 debug+--release) (OK)"

echo "=== Wave J1 E2E [38/38]: R37 probe EStructLit no double-redirect, omitted struct lit, static method fn-value & PVariant enum identity ==="
mkdir -p \
  "$TMP_DIR/r37/dep/src" "$TMP_DIR/r37/decoy/src" \
  "$TMP_DIR/r37/app_pick_tag/src" "$TMP_DIR/cas_r37_pt" "$TMP_DIR/cas_r37_pt_rel" \
  "$TMP_DIR/r37/dep_om/src" "$TMP_DIR/r37/decoy_om/src" \
  "$TMP_DIR/r37/app_om/src" "$TMP_DIR/cas_r37_om" "$TMP_DIR/cas_r37_om_rel" \
  "$TMP_DIR/r37/app_pvar_bad/src" "$TMP_DIR/r37/app_pvar_ok/src" "$TMP_DIR/cas_r37_pv"

# 38a + 38c: probe EStructLit (`lib::Item::{ v: 0 }.pick()` == 11) + static method fn-value (`dep::Item::tag` == 22, `lib::Item::tag` == 11) in debug + --release
cat > "$TMP_DIR/r37/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/dep/src/lib.pion" <<'EOF'
pub struct Item { v : Int }
pub fn Item::pick(self : Item) -> Option[Int] { Some(11 + self.v) }
pub fn Item::tag() -> Int { 11 }
pub enum Secret { Empty }
EOF
cat > "$TMP_DIR/r37/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/decoy/src/lib.pion" <<'EOF'
pub struct Item { v : Int }
pub fn Item::pick(self : Item) -> Option[Int] { Some(22 + self.v) }
pub fn Item::tag() -> Int { 22 }
pub enum Secret { Empty }
EOF
cat > "$TMP_DIR/r37/app_pick_tag/pion.toml" <<'EOF'
[package]
name = "app_pick_tag"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r37/app_pick_tag/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let p = match lib::Item::{ v: 0 }.pick() { Some(n) => n, None => -1 }
  let d1 = dep::Item::tag()
  let fd = dep::Item::tag
  let d2 = fd()
  let l1 = lib::Item::tag()
  let fl = lib::Item::tag
  let l2 = fl()
  io_println(world, p.to_string() + ":" + d1.to_string() + ":" + d2.to_string() + ":" + l1.to_string() + ":" + l2.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r37_pt" "$PIONC" build -o "$TMP_DIR/r37_pt_b" "$TMP_DIR/r37/app_pick_tag"
test "$("$TMP_DIR/r37_pt_b")" = "11:22:22:11:11"
PION_CACHE_DIR="$TMP_DIR/cas_r37_pt_rel" "$PIONC" build --release -o "$TMP_DIR/r37_pt_rel_b" "$TMP_DIR/r37/app_pick_tag"
test "$("$TMP_DIR/r37_pt_rel_b")" = "11:22:22:11:11"

# 38b: omitted struct lit `{ v: 7 }` and `{ ..x, v: 8 }` (debug + --release)
cat > "$TMP_DIR/r37/dep_om/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/dep_om/src/lib.pion" <<'EOF'
pub struct Item { v : Int }
EOF
cat > "$TMP_DIR/r37/decoy_om/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/decoy_om/src/lib.pion" <<'EOF'
pub fn noop() -> Int { 0 }
EOF
cat > "$TMP_DIR/r37/app_om/pion.toml" <<'EOF'
[package]
name = "app_om"
version = "0.1.0"
[dependencies]
dep = { path = "../dep_om" }
decoy = { path = "../decoy_om" }
EOF
cat > "$TMP_DIR/r37/app_om/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let _ = dep::noop()
  let x : lib::Item = { v: 7 }
  let y = { ..x, v: 8 }
  io_println(world, x.v.to_string() + ":" + y.v.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r37_om" "$PIONC" build -o "$TMP_DIR/r37_om_b" "$TMP_DIR/r37/app_om"
test "$("$TMP_DIR/r37_om_b")" = "7:8"
PION_CACHE_DIR="$TMP_DIR/cas_r37_om_rel" "$PIONC" build --release -o "$TMP_DIR/r37_om_rel_b" "$TMP_DIR/r37/app_om"
test "$("$TMP_DIR/r37_om_rel_b")" = "7:8"

# 38d: PVariant enum identity mismatch rejected (`E_TYPE_MISMATCH`), matching arms run -> 3
cat > "$TMP_DIR/r37/app_pvar_bad/pion.toml" <<'EOF'
[package]
name = "app_pvar_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r37/app_pvar_bad/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main() -> Int { match lib::Secret::Empty { dep::Secret::Empty => 1; _ => 0 } }
EOF
set +e; r37_pb=$("$PIONC" check --json "$TMP_DIR/r37/app_pvar_bad" 2>&1); r37_pbrc=$?; set -e
test "$r37_pbrc" -ne 0; printf '%s' "$r37_pb" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r37/app_pvar_ok/pion.toml" <<'EOF'
[package]
name = "app_pvar_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r37/app_pvar_ok/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let a = match lib::Secret::Empty { lib::Secret::Empty => 1 }
  let b = match dep::Secret::Empty { dep::Secret::Empty => 2 }
  io_println(world, (a + b).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r37_pv" "$PIONC" build -o "$TMP_DIR/r37_pv_b" "$TMP_DIR/r37/app_pvar_ok"
test "$("$TMP_DIR/r37_pv_b")" = "3"

# 38e: Opus a1-a5 reversed-field Item with lib::show(it) (debug + --release)
mkdir -p "$TMP_DIR/r37/dep_rev/src" "$TMP_DIR/r37/decoy_rev/src" "$TMP_DIR/r37/app_rev/src" "$TMP_DIR/cas_r37_rev" "$TMP_DIR/cas_r37_rev_rel"
cat > "$TMP_DIR/r37/dep_rev/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/dep_rev/src/lib.pion" <<'EOF'
pub struct Item { first : Int; second : Int }
pub fn make() -> Item {
  let mut a = 0
  let mut i = 0
  while i < 1 { a = a + 11; i = i + 1 }
  Item::{ first: a, second: 22 }
}
pub fn show(it : Item) -> String { it.first.to_string() + ":" + it.second.to_string() }
EOF
cat > "$TMP_DIR/r37/decoy_rev/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r37/decoy_rev/src/lib.pion" <<'EOF'
pub struct Item { second : Int; first : Int }
EOF
cat > "$TMP_DIR/r37/app_rev/pion.toml" <<'EOF'
[package]
name = "app_rev"
version = "0.1.0"
[dependencies]
dep = { path = "../dep_rev" }
decoy = { path = "../decoy_rev" }
EOF
cat > "$TMP_DIR/r37/app_rev/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let a1 = lib::Item::{ first: 1, second: 2 }
  let s1a = a1.first.to_string() + ":" + a1.second.to_string()
  let s1b = lib::show(a1)
  let a2 : lib::Item = { first: 1, second: 2 }
  let s2 = lib::show(a2)
  let b = lib::make()
  let a3 = { ..b, first: 5 }
  let s3 = lib::show(a3)
  let s4 = lib::show({ first: 1, second: 2 })
  let a5 = lib::Item::{ ..b, first: 5 }
  let s5 = lib::show(a5)
  io_println(world, s1a + "|" + s1b + "|" + s2 + "|" + s3 + "|" + s4 + "|" + s5)
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r37_rev" "$PIONC" build -o "$TMP_DIR/r37_rev_b" "$TMP_DIR/r37/app_rev"
test "$("$TMP_DIR/r37_rev_b")" = "1:2|1:2|1:2|5:22|1:2|5:22"
PION_CACHE_DIR="$TMP_DIR/cas_r37_rev_rel" "$PIONC" build --release -o "$TMP_DIR/r37_rev_rel_b" "$TMP_DIR/r37/app_rev"
test "$("$TMP_DIR/r37_rev_rel_b")" = "1:2|1:2|1:2|5:22|1:2|5:22"

echo "  R37 runtime (pick/tag 11:22:22:11:11, omitted-lit 7:8, PVariant mismatch/ok==3, Opus a1-a5 reversed-field debug+--release) (OK)"

echo "=== Wave J1 E2E [39/39]: R38 mono_pkg generic struct layout, trait alias vs dyn lookup & unqualified .Variant default_expr ==="
mkdir -p \
  "$TMP_DIR/r38/dep/src" "$TMP_DIR/r38/decoy/src" \
  "$TMP_DIR/r38/app_mono_trait/src" "$TMP_DIR/cas_r38_mt" "$TMP_DIR/cas_r38_mt_rel" \
  "$TMP_DIR/r38/other/src" "$TMP_DIR/r38/bridge/src" \
  "$TMP_DIR/r38/app_dotvar/src" "$TMP_DIR/cas_r38_dv" "$TMP_DIR/cas_r38_dv_rel"

# 39a + 39b: mono_pkg generic make_gen[T] reversed-field Item (11:22) + trait alias impl/dyn Tag (22:11) in debug + --release
cat > "$TMP_DIR/r38/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r38/dep/src/lib.pion" <<'EOF'
pub struct Item { first : Int; second : Int }
pub fn make_gen[T](x : T) -> Item { let _ = x; Item::{ first: 11, second: 22 } }
pub fn show(it : Item) -> String { it.first.to_string() + ":" + it.second.to_string() }
pub trait Tag { fn first(self : Self) -> Int }
EOF
cat > "$TMP_DIR/r38/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r38/decoy/src/lib.pion" <<'EOF'
pub struct Item { second : Int; first : Int }
pub trait Tag { fn second(self : Self) -> Int }
EOF
cat > "$TMP_DIR/r38/app_mono_trait/pion.toml" <<'EOF'
[package]
name = "app_mono_trait"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r38/app_mono_trait/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
struct X { v : Int }
struct Y { v : Int }
impl dep::Tag for X { fn second(self : X) -> Int { self.v + 20 } }
impl lib::Tag for Y { fn first(self : Y) -> Int { self.v + 10 } }
fn call_decoy(t : dyn dep::Tag) -> Int { t.second() }
fn call_dep(t : dyn lib::Tag) -> Int { t.first() }
pub fn main(world : World) -> Unit {
  let gs = lib::show(lib::make_gen(0))
  let t1 = call_decoy(X::{ v: 2 })
  let t2 = call_dep(Y::{ v: 1 })
  io_println(world, gs + "|" + t1.to_string() + ":" + t2.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r38_mt" "$PIONC" build -o "$TMP_DIR/r38_mt_b" "$TMP_DIR/r38/app_mono_trait"
test "$("$TMP_DIR/r38_mt_b")" = "11:22|22:11"
PION_CACHE_DIR="$TMP_DIR/cas_r38_mt_rel" "$PIONC" build --release -o "$TMP_DIR/r38_mt_rel_b" "$TMP_DIR/r38/app_mono_trait"
test "$("$TMP_DIR/r38_mt_rel_b")" = "11:22|22:11"

# 39c: unqualified `.Hit` in cross-pkg default_expr with colliding `bridge::Local::Hit` -> 14 (debug + --release)
cat > "$TMP_DIR/r38/other/pion.toml" <<'EOF'
[package]
name = "other"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r38/other/src/lib.pion" <<'EOF'
pub enum E { Hit }
pub fn make() -> E { E::Hit }
EOF
cat > "$TMP_DIR/r38/bridge/pion.toml" <<'EOF'
[package]
name = "bridge"
version = "0.1.0"
[dependencies]
other = { path = "../other" }
EOF
cat > "$TMP_DIR/r38/bridge/src/lib.pion" <<'EOF'
import "other"
enum Local { Hit }
pub fn g(x : Int = match other::make() { .Hit => 7 }) -> Int { x }
pub fn self_call() -> Int { let _ = Local::Hit; g() }
EOF
cat > "$TMP_DIR/r38/app_dotvar/pion.toml" <<'EOF'
[package]
name = "app_dotvar"
version = "0.1.0"
[dependencies]
bridge = { path = "../bridge" }
EOF
cat > "$TMP_DIR/r38/app_dotvar/src/main.pion" <<'EOF'
import "bridge"
pub fn main(world : World) -> Unit {
  io_println(world, (bridge::g() + bridge::self_call()).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r38_dv" "$PIONC" build -o "$TMP_DIR/r38_dv_b" "$TMP_DIR/r38/app_dotvar"
test "$("$TMP_DIR/r38_dv_b")" = "14"
PION_CACHE_DIR="$TMP_DIR/cas_r38_dv_rel" "$PIONC" build --release -o "$TMP_DIR/r38_dv_rel_b" "$TMP_DIR/r38/app_dotvar"
test "$("$TMP_DIR/r38_dv_rel_b")" = "14"

echo "  R38 runtime (mono_pkg make_gen 11:22 + dyn trait 22:11 debug+--release, unqualified .Hit xpkg default==14 debug+--release) (OK)"

echo "=== Wave J1 E2E [40/40]: R39 source trait visibility/aliasing (private impl, aliased bound & xpkg private dyn default) ==="
mkdir -p \
  "$TMP_DIR/r39/dep/src" "$TMP_DIR/r39/decoy/src" \
  "$TMP_DIR/r39/app_impl_priv/src" "$TMP_DIR/r39/app_bound_bad/src" \
  "$TMP_DIR/r39/app_dyn_ok/src" "$TMP_DIR/cas_r39_dyn" "$TMP_DIR/cas_r39_dyn_rel" \
  "$TMP_DIR/r39/app_dyn_bad/src"

cat > "$TMP_DIR/r39/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r39/dep/src/lib.pion" <<'EOF'
trait Hidden { fn tag(self : Self) -> Int }
pub trait Tag { fn first(self : Self) -> Int }
pub fn use_dyn(n : Int = { let xs : Array[dyn Hidden] = []; xs.length() }) -> Int { n }
EOF
cat > "$TMP_DIR/r39/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r39/decoy/src/lib.pion" <<'EOF'
pub fn noop() -> Int { 0 }
EOF

# 40a: private trait impl rejected with E_PRIVATE_SYMBOL
cat > "$TMP_DIR/r39/app_impl_priv/pion.toml" <<'EOF'
[package]
name = "app_impl_priv"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r39/app_impl_priv/src/main.pion" <<'EOF'
import "dep"
struct X { v : Int }
impl dep::Hidden for X { fn tag(self : X) -> Int { self.v } }
pub fn main() -> Int { 0 }
EOF
set +e; r39_ip=$("$PIONC" check --json "$TMP_DIR/r39/app_impl_priv" 2>&1); r39_iprc=$?; set -e
test "$r39_iprc" -ne 0; printf '%s' "$r39_ip" | grep -q "E_PRIVATE_SYMBOL"

# 40b: uncalled generic bound `fn f[T : dep::Tag]` under `import "dep" as lib; import "decoy" as dep` -> E_UNKNOWN_TRAIT
cat > "$TMP_DIR/r39/app_bound_bad/pion.toml" <<'EOF'
[package]
name = "app_bound_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r39/app_bound_bad/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
fn f[T : dep::Tag](x : T) -> Int { let _ = x; 0 }
pub fn main() -> Int { let _ = dep::noop(); 0 }
EOF
set +e; r39_bb=$("$PIONC" check --json "$TMP_DIR/r39/app_bound_bad" 2>&1); r39_bbrc=$?; set -e
test "$r39_bbrc" -ne 0; printf '%s' "$r39_bb" | grep -q "E_UNKNOWN_TRAIT"

# 40c: cross-pkg private `dyn Hidden` in default_expr runs -> 0 (debug + --release), while direct `dyn dep::Hidden` in app -> E_PRIVATE_SYMBOL
cat > "$TMP_DIR/r39/app_dyn_ok/pion.toml" <<'EOF'
[package]
name = "app_dyn_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r39/app_dyn_ok/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit { io_println(world, dep::use_dyn().to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r39_dyn" "$PIONC" build -o "$TMP_DIR/r39_dyn_b" "$TMP_DIR/r39/app_dyn_ok"
test "$("$TMP_DIR/r39_dyn_b")" = "0"
PION_CACHE_DIR="$TMP_DIR/cas_r39_dyn_rel" "$PIONC" build --release -o "$TMP_DIR/r39_dyn_rel_b" "$TMP_DIR/r39/app_dyn_ok"
test "$("$TMP_DIR/r39_dyn_rel_b")" = "0"

cat > "$TMP_DIR/r39/app_dyn_bad/pion.toml" <<'EOF'
[package]
name = "app_dyn_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r39/app_dyn_bad/src/main.pion" <<'EOF'
import "dep"
pub fn main() -> Int { let _ = dep::use_dyn(); let xs : Array[dyn dep::Hidden] = []; xs.length() }
EOF
set +e; r39_db=$("$PIONC" check --json "$TMP_DIR/r39/app_dyn_bad" 2>&1); r39_dbrc=$?; set -e
test "$r39_dbrc" -ne 0; printf '%s' "$r39_db" | grep -q "E_PRIVATE_SYMBOL"

echo "  R39 runtime (priv impl E_PRIVATE_SYMBOL, aliased bound E_UNKNOWN_TRAIT, xpkg priv dyn default==0 debug+--release / direct E_PRIVATE_SYMBOL) (OK)"

echo "=== Wave J1 E2E [41/41]: R40 cross-pkg default_expr calling private dyn Trait methods with qualified Item param/ret ==="
mkdir -p \
  "$TMP_DIR/r40/dep/src" "$TMP_DIR/r40/app_ok/src" "$TMP_DIR/cas_r40_ok" "$TMP_DIR/cas_r40_ok_rel" \
  "$TMP_DIR/r40/app_bad/src"

cat > "$TMP_DIR/r40/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r40/dep/src/lib.pion" <<'EOF'
pub struct Item { v : Int }
trait Hidden {
  fn tag(self : Self) -> Int
  fn score(self : Self, p : Item) -> Int
  fn get(self : Self) -> Item
}
struct X { v : Int }
impl Hidden for X {
  fn tag(self : X) -> Int { self.v }
  fn score(self : X, p : Item) -> Int { self.v + p.v }
  fn get(self : X) -> Item { Item::{ v: self.v + 1 } }
}
pub fn run_dyn(n : Int = {
  let h : dyn Hidden = X::{ v: 7 }
  h.tag() * 100 + h.score(Item::{ v: 3 }) * 10 + h.get().v
}) -> Int { n }
EOF

cat > "$TMP_DIR/r40/app_ok/pion.toml" <<'EOF'
[package]
name = "app_ok"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r40/app_ok/src/main.pion" <<'EOF'
import "dep"
struct Item { pad : String; v : Int }
pub fn main(world : World) -> Unit {
  let _ = Item::{ pad: "different_layout", v: 999 }
  io_println(world, dep::run_dyn().to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r40_ok" "$PIONC" build -o "$TMP_DIR/r40_ok_b" "$TMP_DIR/r40/app_ok"
test "$("$TMP_DIR/r40_ok_b")" = "808"
PION_CACHE_DIR="$TMP_DIR/cas_r40_ok_rel" "$PIONC" build --release -o "$TMP_DIR/r40_ok_rel_b" "$TMP_DIR/r40/app_ok"
test "$("$TMP_DIR/r40_ok_rel_b")" = "808"

cat > "$TMP_DIR/r40/app_bad/pion.toml" <<'EOF'
[package]
name = "app_bad"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r40/app_bad/src/main.pion" <<'EOF'
import "dep"
pub fn main() -> Int { let _ = dep::run_dyn(); let xs : Array[dyn dep::Hidden] = []; xs.length() }
EOF
set +e; r40_b=$("$PIONC" check --json "$TMP_DIR/r40/app_bad" 2>&1); r40_brc=$?; set -e
test "$r40_brc" -ne 0; printf '%s' "$r40_b" | grep -q "E_PRIVATE_SYMBOL"

echo "  R40 runtime (xpkg priv dyn Trait methods==808 debug+--release with colliding local Item, direct dyn dep::Hidden E_PRIVATE_SYMBOL) (OK)"

echo "=== Wave J1 E2E [42/42]: R41 Opus run6.sh mono_pkg nominal Ty, method lookup & unqualified helper call under alias hijack ==="
mkdir -p \
  "$TMP_DIR/r41/dep/src" "$TMP_DIR/r41/decoy/src" \
  "$TMP_DIR/r41/app/src" "$TMP_DIR/cas_r41" "$TMP_DIR/cas_r41_rel"

cat > "$TMP_DIR/r41/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r41/dep/src/lib.pion" <<'EOF'
pub struct S { v : Int }
pub trait Tag {
  fn first(self : Self) -> String
  fn second(self : Self) -> String
}
trait Hidden {
  fn secret(self : Self) -> Int
}
impl Tag for S {
  fn first(self : S) -> String { self.v.to_string() }
  fn second(self : S) -> String { (self.v * 2).to_string() }
}
impl Hidden for S {
  fn secret(self : S) -> Int { self.v }
}
fn bonus() -> Int { 100 }
pub fn mk_s() -> S { S::{ v: 5 } }
pub fn use_t[T : Tag](x : T) -> String { x.first() + ":" + x.second() }
pub fn use_h[T : Hidden](x : T) -> Int { x.secret() + bonus() }
EOF

cat > "$TMP_DIR/r41/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r41/decoy/src/lib.pion" <<'EOF'
pub trait Tag {
  fn second(self : Self) -> String
  fn first(self : Self) -> String
}
pub fn bonus() -> Int { 999 }
EOF

cat > "$TMP_DIR/r41/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r41/app/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as dep
struct X { a : String; b : String }
impl lib::Tag for X {
  fn first(self : X) -> String { self.a }
  fn second(self : X) -> String { self.b }
}
fn call_dyn(t : dyn lib::Tag) -> String { t.first() + "/" + t.second() }
pub fn main(world : World) -> Unit {
  let _ = dep::bonus()
  let r1 = lib::use_t(lib::mk_s())
  let r2 = lib::use_t(X::{ a: "hi", b: "lo" })
  let r3 = lib::use_h(lib::mk_s())
  let r4 = call_dyn(lib::mk_s())
  let r5 = call_dyn(X::{ a: "A", b: "B" })
  io_println(world, r1 + "|" + r2 + "|" + r3.to_string() + "|" + r4 + "|" + r5)
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r41" "$PIONC" build -o "$TMP_DIR/r41_b" "$TMP_DIR/r41/app"
test "$("$TMP_DIR/r41_b")" = "5:10|hi:lo|105|5/10|A/B"
PION_CACHE_DIR="$TMP_DIR/cas_r41_rel" "$PIONC" build --release -o "$TMP_DIR/r41_rel_b" "$TMP_DIR/r41/app"
test "$("$TMP_DIR/r41_rel_b")" = "5:10|hi:lo|105|5/10|A/B"

echo "  R41 runtime (Opus run6.sh use_t/use_h/bonus/dyn-Tag 5:10|hi:lo|105|5/10|A/B debug+--release) (OK)"

echo "=== Wave J1 E2E [43/43]: R42 no __mono_pkg__ sentinel collision & mono_pkg ECall(EPath) defining-pkg alias resolution ==="
mkdir -p \
  "$TMP_DIR/r42/real/src" "$TMP_DIR/r42/decoy/src" \
  "$TMP_DIR/r42/dep/src" "$TMP_DIR/r42/app/src" \
  "$TMP_DIR/cas_r42" "$TMP_DIR/cas_r42_rel"

cat > "$TMP_DIR/r42/real/pion.toml" <<'EOF'
[package]
name = "real"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r42/real/src/lib.pion" <<'EOF'
pub fn bonus() -> Int { 100 }
EOF

cat > "$TMP_DIR/r42/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r42/decoy/src/lib.pion" <<'EOF'
pub fn bonus() -> Int { 999 }
EOF

cat > "$TMP_DIR/r42/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
[dependencies]
real = { path = "../real" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r42/dep/src/lib.pion" <<'EOF'
import "decoy" as __mono_pkg__
import "real" as tools
pub struct S { v : Int }
trait Hidden { fn secret(self : Self) -> Int }
impl Hidden for S { fn secret(self : S) -> Int { self.v } }
fn bonus() -> Int { 100 }
pub fn with_def(n : Int = bonus()) -> Int { n }
pub fn mk_s() -> S { S::{ v: 5 } }
pub fn use_h[T : Hidden](x : T) -> Int { x.secret() + __mono_pkg__::bonus() }
pub fn use_local[T : Hidden](x : T) -> Int { x.secret() + bonus() }
pub fn use_def[T : Hidden](x : T) -> Int { x.secret() + with_def() }
pub fn use_tools[T : Hidden](x : T) -> String {
  let _ = x.secret()
  let a = tools::bonus()
  let f = tools::bonus
  let b = f()
  a.to_string() + ":" + b.to_string()
}
EOF

cat > "$TMP_DIR/r42/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r42/app/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as tools
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let _ = tools::bonus() + dep::bonus()
  let r1 = lib::use_h(lib::mk_s())
  let r2 = lib::use_local(lib::mk_s())
  let r3 = lib::use_def(lib::mk_s())
  let r4 = lib::use_tools(lib::mk_s())
  io_println(world, r1.to_string() + "|" + r2.to_string() + "|" + r3.to_string() + "|" + r4)
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r42" "$PIONC" build -o "$TMP_DIR/r42_b" "$TMP_DIR/r42/app"
test "$("$TMP_DIR/r42_b")" = "1004|105|105|100:100"
PION_CACHE_DIR="$TMP_DIR/cas_r42_rel" "$PIONC" build --release -o "$TMP_DIR/r42_rel_b" "$TMP_DIR/r42/app"
test "$("$TMP_DIR/r42_rel_b")" = "1004|105|105|100:100"

echo "  R42 runtime (no __mono_pkg__ collision 1004|105, mono_pkg default_arg==105, mono_pkg tools::bonus 100:100 debug+--release) (OK)"

echo "=== Wave J1 E2E [44/44]: R43 unified qbe_resolve_path_pkg (scalar opt/POD inline, static method fn-val & default-arg cb) ==="
mkdir -p \
  "$TMP_DIR/r43/real/src" "$TMP_DIR/r43/decoy/src" \
  "$TMP_DIR/r43/dep/src" "$TMP_DIR/r43/app/src" \
  "$TMP_DIR/cas_r43" "$TMP_DIR/cas_r43_rel"

cat > "$TMP_DIR/r43/real/pion.toml" <<'EOF'
[package]
name = "real"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r43/real/src/lib.pion" <<'EOF'
pub struct Pod { a : Int; b : Int }
pub struct Item { v : Int }
pub fn Item::tag() -> Int { 100 }
pub fn bonus() -> Int { 100 }
pub fn pick() -> Option[Int] { Some(100) }
pub fn mk_pod() -> Pod { Pod::{ a: 100, b: 1 } }
EOF

cat > "$TMP_DIR/r43/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r43/decoy/src/lib.pion" <<'EOF'
pub struct Pod { a : Int; b : Int }
pub struct Item { v : Int }
pub fn Item::tag() -> Int { 999 }
pub fn bonus() -> Int { 999 }
pub fn pick() -> Option[Int] { Some(999) }
pub fn mk_pod() -> Pod { Pod::{ a: 999, b: 2 } }
EOF

cat > "$TMP_DIR/r43/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
[dependencies]
real = { path = "../real" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r43/dep/src/lib.pion" <<'EOF'
import "real" as tools
import "decoy" as real
pub struct S { v : Int }
trait Hidden { fn secret(self : Self) -> Int }
impl Hidden for S { fn secret(self : S) -> Int { self.v } }
pub fn mk_s() -> S { S::{ v: 5 } }
pub fn with_cb(cb : () -> Int = tools::bonus) -> Int { cb() }
pub fn use_all[T : Hidden](x : T) -> String {
  let _ = x.secret() + real::bonus()
  let p1 = match tools::pick() { Some(v) => v; None => 0 }
  let pod = tools::mk_pod()
  let t1 = tools::Item::tag()
  let ft = tools::Item::tag
  let t2 = ft()
  let c1 = with_cb()
  p1.to_string() + ":" + pod.a.to_string() + "|" + t1.to_string() + ":" + t2.to_string() + "|" + c1.to_string()
}
EOF

cat > "$TMP_DIR/r43/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r43/app/src/main.pion" <<'EOF'
import "dep" as lib
import "decoy" as tools
import "decoy" as dep
pub fn main(world : World) -> Unit {
  let _ = tools::bonus() + dep::bonus()
  io_println(world, lib::use_all(lib::mk_s()))
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r43" "$PIONC" build -o "$TMP_DIR/r43_b" "$TMP_DIR/r43/app"
test "$("$TMP_DIR/r43_b")" = "100:100|100:100|100"
PION_CACHE_DIR="$TMP_DIR/cas_r43_rel" "$PIONC" build --release -o "$TMP_DIR/r43_rel_b" "$TMP_DIR/r43/app"
test "$("$TMP_DIR/r43_rel_b")" = "100:100|100:100|100"

echo "  R43 runtime (unified qbe_resolve_path_pkg: pick/pod 100:100, static Item::tag 100:100, default-cb 100 debug+--release) (OK)"

echo "=== Wave J1 E2E [45/45]: R44 enum static-method fn-value & mono_pkg qualified enum ctor alias isolation ==="
mkdir -p \
  "$TMP_DIR/r44/real/src" "$TMP_DIR/r44/decoy/src" \
  "$TMP_DIR/r44/dep/src" "$TMP_DIR/r44/app/src" \
  "$TMP_DIR/cas_r44" "$TMP_DIR/cas_r44_rel"

cat > "$TMP_DIR/r44/real/pion.toml" <<'EOF'
[package]
name = "real"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r44/real/src/lib.pion" <<'EOF'
pub enum E { Miss(Int); Hit(Int) }
EOF

cat > "$TMP_DIR/r44/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r44/decoy/src/lib.pion" <<'EOF'
pub enum E { Hit(Int); Miss(Int) }
pub fn read(e : E) -> Int { match e { .Hit(_) => 1; .Miss(_) => 2 } }
EOF

cat > "$TMP_DIR/r44/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
[dependencies]
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r44/dep/src/lib.pion" <<'EOF'
import "decoy" as real
pub enum Mode { Idle }
pub fn Mode::tag() -> Int { 100 }
pub struct S { v : Int }
trait Hidden { fn secret(self : Self) -> Int }
impl Hidden for S { fn secret(self : S) -> Int { self.v } }
pub fn mk_s() -> S { S::{ v: 5 } }
pub fn use_all[T : Hidden](x : T) -> String {
  let _ = x.secret()
  let a = Mode::tag()
  let f : () -> Int = Mode::tag
  let b = f()
  let v = real::E::Hit(7)
  let c = real::read(v)
  a.to_string() + ":" + b.to_string() + "|" + c.to_string()
}
EOF

cat > "$TMP_DIR/r44/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
real = { path = "../real" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r44/app/src/main.pion" <<'EOF'
import "dep" as lib
import "real" as original
import "decoy"
pub fn main(world : World) -> Unit {
  let _ = original::E::Miss(0)
  let _ = decoy::read(decoy::E::Hit(1))
  io_println(world, lib::use_all(lib::mk_s()))
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r44" "$PIONC" build -o "$TMP_DIR/r44_b" "$TMP_DIR/r44/app"
test "$("$TMP_DIR/r44_b")" = "100:100|1"
PION_CACHE_DIR="$TMP_DIR/cas_r44_rel" "$PIONC" build --release -o "$TMP_DIR/r44_rel_b" "$TMP_DIR/r44/app"
test "$("$TMP_DIR/r44_rel_b")" = "100:100|1"

echo "  R44 runtime (enum static Mode::tag 100:100 + mono_pkg real::E::Hit(7)==1 debug+--release) (OK)"

echo "=== Wave J1 E2E [46/46]: R45 --release xpkg inline boxing of private dyn Trait vtable method slots ==="
mkdir -p \
  "$TMP_DIR/r45/dep/src" "$TMP_DIR/r45/app/src" \
  "$TMP_DIR/cas_r45" "$TMP_DIR/cas_r45_rel"

cat > "$TMP_DIR/r45/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r45/dep/src/lib.pion" <<'EOF'
trait Hidden { fn tag(self : Self) -> Int }
pub struct X { v : Int }
impl Hidden for X { fn tag(self : X) -> Int { self.v } }
pub fn boxed(x : X) -> dyn Hidden { x }
pub fn run(n : Int = boxed(X::{ v: 7 }).tag()) -> Int { n }
EOF

cat > "$TMP_DIR/r45/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r45/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  io_println(world, dep::run().to_string())
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r45" "$PIONC" build -o "$TMP_DIR/r45_b" "$TMP_DIR/r45/app"
test "$("$TMP_DIR/r45_b")" = "7"
PION_CACHE_DIR="$TMP_DIR/cas_r45_rel" "$PIONC" build --release -o "$TMP_DIR/r45_rel_b" "$TMP_DIR/r45/app"
test "$("$TMP_DIR/r45_rel_b")" = "7"
grep -E 'data \$pion_vtable_.*dep.*Hidden.*\$pion_dyn_wrap_.*(_M3_tag|__tag)' "$TMP_DIR/cas_r45_rel"/ssa/*.ssa > /dev/null
if grep -E 'data \$pion_vtable_.*dep.*Hidden' "$TMP_DIR/cas_r45_rel"/ssa/*.ssa | grep -qvE '\$pion_dyn_wrap_.*(_M3_tag|__tag)'; then
  echo "FAIL: found dep__Hidden vtable missing __tag wrap slot in --release SSA" >&2
  exit 1
fi

echo "  R45 runtime+SSA (private dyn Hidden vtable wrap slot & dep::run()==7 debug+--release) (OK)"

echo "=== Wave J1 E2E [47/47]: R46/R47 self-pkg qualified canonical dyn Trait (app::Local) dispatch, boxing & import-as-app alias isolation ==="
mkdir -p \
  "$TMP_DIR/r46/decoy/src" "$TMP_DIR/r46/app/src" \
  "$TMP_DIR/cas_r46" "$TMP_DIR/cas_r46_rel"

cat > "$TMP_DIR/r46/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r46/decoy/src/lib.pion" <<'EOF'
pub fn noop() -> Int { 0 }
EOF

cat > "$TMP_DIR/r46/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r46/app/src/main.pion" <<'EOF'
import "decoy" as app
trait Local { fn tag(self : Self) -> Int }
struct X { v : Int }
impl Local for X { fn tag(self : X) -> Int { self.v } }
fn pass[A : Local, B](a : A, b : B) -> B {
  let _ = a.tag()
  b
}
fn box_it[A : Local](a : A) -> dyn Local {
  let h : dyn Local = X::{ v: a.tag() }
  h
}
fn read_local(h : dyn Local) -> Int { h.tag() }
pub fn main(world : World) -> Unit {
  let _ = app::noop()
  let h : dyn Local = X::{ v: 7 }
  let out = h.tag().to_string() + ":" +
    pass(X::{ v: 7 }, h).tag().to_string() + ":" +
    box_it(X::{ v: 7 }).tag().to_string() + ":" +
    read_local(X::{ v: 7 }).to_string() + ":" +
    pass(X::{ v: 7 }, read_local)(X::{ v: 7 }).to_string()
  io_println(world, out)
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas_r46" "$PIONC" build -o "$TMP_DIR/r46_b" "$TMP_DIR/r46/app"
test "$("$TMP_DIR/r46_b")" = "7:7:7:7:7"
PION_CACHE_DIR="$TMP_DIR/cas_r46_rel" "$PIONC" build --release -o "$TMP_DIR/r46_rel_b" "$TMP_DIR/r46/app"
test "$("$TMP_DIR/r46_rel_b")" = "7:7:7:7:7"

echo "  R46/R47 runtime (self-pkg canonical dyn app::Local + import decoy as app==7:7:7:7:7 debug+--release) (OK)"

echo "=== Wave J1 E2E [48/48]: R49 PR #34 Opus+Astra blockers (default return, non-fn shadow, chained fwd, #fdeffwd, unit EPath & hot-loop 2500+) ==="
mkdir -p \
  "$TMP_DIR/r49_ret_r1" "$TMP_DIR/r49_ret_r2" "$TMP_DIR/r49_ret_r7" "$TMP_DIR/r49_ret_r3" "$TMP_DIR/cas_r49_r3" \
  "$TMP_DIR/r49_sh" "$TMP_DIR/cas_r49_sh" "$TMP_DIR/r49_sh_cyc" \
  "$TMP_DIR/r49_cf" "$TMP_DIR/cas_r49_cf" "$TMP_DIR/r49_cf_cyc" "$TMP_DIR/r49_cf_ok" "$TMP_DIR/cas_r49_cf_ok" \
  "$TMP_DIR/r49_df" "$TMP_DIR/cas_r49_df" "$TMP_DIR/r49_df_cyc" "$TMP_DIR/r49_df_ok" "$TMP_DIR/cas_r49_df_ok" \
  "$TMP_DIR/r49_ep/real/src" "$TMP_DIR/r49_ep/decoy/src" "$TMP_DIR/r49_ep/dep/src" "$TMP_DIR/r49_ep/app/src" "$TMP_DIR/cas_r49_ep" "$TMP_DIR/cas_r49_ep_rel" \
  "$TMP_DIR/r49_sum" "$TMP_DIR/cas_r49_sum"

# 48a: Opus B1 — forbid top-level `return` in default_expr (r1 free fn, r2 mismatched caller, r7 method); allow closure return (r3 == 6)
cat > "$TMP_DIR/r49_ret_r1/main.pion" <<'EOF'
fn g(x : Int = { if true { return 1 }; 0 }) -> Int { x }
pub fn main() -> Int { g() }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_ret_r1/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r49_ret_r2/main.pion" <<'EOF'
fn g(x : Int = { if true { return 1 }; 0 }) -> Int { x }
fn caller() -> String { let _ = g(); "ok" }
pub fn main() -> Int { caller().length() }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_ret_r2/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r49_ret_r7/main.pion" <<'EOF'
struct S { v : Int }
fn S::m(self : S, x : Int = { if true { return 1 }; 0 }) -> Int { self.v + x }
pub fn main() -> Int { S::{ v: 1 }.m() }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_ret_r7/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_TYPE_MISMATCH"

cat > "$TMP_DIR/r49_ret_r3/main.pion" <<'EOF'
fn g(x : Int, f : () -> Int = fn() -> Int { if x > 0 { return x + 1 }; 0 }) -> Int { f() }
pub fn main(world : World) -> Unit { io_println(world, g(5).to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_r3" "$PIONC" build -o "$TMP_DIR/r49_r3_b" "$TMP_DIR/r49_ret_r3/main.pion"
test "$("$TMP_DIR/r49_r3_b")" = "6"

# 48b: Opus B2 — non-fn prior param `READ : Int` must not shadow top-level `fn READ()` in default_expr
cat > "$TMP_DIR/r49_sh/a.pion" <<'EOF'
let A : String = g(1).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r49_sh/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn g(READ : Int, x : Int = READ()) -> Int { READ * 0 + x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_sh" "$PIONC" build -o "$TMP_DIR/r49_sh_c" "$TMP_DIR/r49_sh/a.pion" "$TMP_DIR/r49_sh/b.pion"
test "$("$TMP_DIR/r49_sh_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r49_sh/b.pion" > "$TMP_DIR/r49_sh/b2.pion" && mv "$TMP_DIR/r49_sh/b2.pion" "$TMP_DIR/r49_sh/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r49_sh" "$PIONC" build -o "$TMP_DIR/r49_sh_h" "$TMP_DIR/r49_sh/a.pion" "$TMP_DIR/r49_sh/b.pion"
test "$("$TMP_DIR/r49_sh_h")" = "9"

cat > "$TMP_DIR/r49_sh_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn g(READ : Int, x : Int = READ()) -> Int { READ * 0 + x }
let A : Int = g(1)
pub fn main() -> Int { A }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_sh_cyc/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_CONST_CYCLE"

# 48c: Astra B1 — param forwarded into chained default (`wrap(f) { use(f) }` + `use(a, b=a, c=b) { c() }`)
cat > "$TMP_DIR/r49_cf/a.pion" <<'EOF'
let A : String = wrap(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r49_cf/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn use_chain(a : () -> Int, b : () -> Int = a, c : () -> Int = b) -> Int { c() }
fn wrap(f : () -> Int) -> Int { use_chain(f) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_cf" "$PIONC" build -o "$TMP_DIR/r49_cf_c" "$TMP_DIR/r49_cf/a.pion" "$TMP_DIR/r49_cf/b.pion"
test "$("$TMP_DIR/r49_cf_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r49_cf/b.pion" > "$TMP_DIR/r49_cf/b2.pion" && mv "$TMP_DIR/r49_cf/b2.pion" "$TMP_DIR/r49_cf/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r49_cf" "$PIONC" build -o "$TMP_DIR/r49_cf_h" "$TMP_DIR/r49_cf/a.pion" "$TMP_DIR/r49_cf/b.pion"
test "$("$TMP_DIR/r49_cf_h")" = "9"

cat > "$TMP_DIR/r49_cf_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn use_chain(a : () -> Int, b : () -> Int = a, c : () -> Int = b) -> Int { c() }
fn wrap(f : () -> Int) -> Int { use_chain(f) }
let A : Int = wrap(read_a)
pub fn main() -> Int { A }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_cf_cyc/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r49_cf_ok/main.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_a() -> Int { A }
fn use_chain(a : () -> Int, b : () -> Int = a, c : () -> Int = b) -> Int { c() }
fn wrap2(f : () -> Int) -> Int { use_chain(f, f, zero) }
let A : Int = wrap2(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_cf_ok" "$PIONC" build -o "$TMP_DIR/r49_cf_ok_b" "$TMP_DIR/r49_cf_ok/main.pion"
test "$("$TMP_DIR/r49_cf_ok_b")" = "0"

# 48d: Astra B2 — default_expr forwards prior callback to another fn (`use(f, x = invoke(f))`)
cat > "$TMP_DIR/r49_df/a.pion" <<'EOF'
let A : String = use_inv(read_b).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r49_df/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn invoke(cb : () -> Int) -> Int { cb() }
fn use_inv(f : () -> Int, x : Int = invoke(f)) -> Int { x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_df" "$PIONC" build -o "$TMP_DIR/r49_df_c" "$TMP_DIR/r49_df/a.pion" "$TMP_DIR/r49_df/b.pion"
test "$("$TMP_DIR/r49_df_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r49_df/b.pion" > "$TMP_DIR/r49_df/b2.pion" && mv "$TMP_DIR/r49_df/b2.pion" "$TMP_DIR/r49_df/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r49_df" "$PIONC" build -o "$TMP_DIR/r49_df_h" "$TMP_DIR/r49_df/a.pion" "$TMP_DIR/r49_df/b.pion"
test "$("$TMP_DIR/r49_df_h")" = "9"

cat > "$TMP_DIR/r49_df_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn invoke(cb : () -> Int) -> Int { cb() }
fn use_inv(f : () -> Int, x : Int = invoke(f)) -> Int { x }
let A : Int = use_inv(read_a)
pub fn main() -> Int { A }
EOF
set +e; r49_o=$("$PIONC" check --json "$TMP_DIR/r49_df_cyc/main.pion" 2>&1); r49_rc=$?; set -e
test "$r49_rc" -ne 0; printf '%s' "$r49_o" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r49_df_ok/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn invoke(cb : () -> Int) -> Int { cb() }
fn use_inv(f : () -> Int, x : Int = invoke(f)) -> Int { x }
let A : Int = use_inv(read_a, 0)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_df_ok" "$PIONC" build -o "$TMP_DIR/r49_df_ok_b" "$TMP_DIR/r49_df_ok/main.pion"
test "$("$TMP_DIR/r49_df_ok_b")" = "0"

# 48e: Astra B3 — cross-pkg mono_pkg unit-variant EPath `real::E::Hit` under `import "decoy" as real`
cat > "$TMP_DIR/r49_ep/real/pion.toml" <<'EOF'
[package]
name = "real"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r49_ep/real/src/lib.pion" <<'EOF'
pub enum E { Hit, Miss }
pub fn id_e(e : E) -> Int { match e { Hit => 10, Miss => 20 } }
EOF
cat > "$TMP_DIR/r49_ep/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r49_ep/decoy/src/lib.pion" <<'EOF'
pub enum E { Miss, Hit }
pub fn id_e(e : E) -> Int { match e { Miss => 1, Hit => 2 } }
EOF
cat > "$TMP_DIR/r49_ep/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
[dependencies]
real = { path = "../real" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/r49_ep/dep/src/lib.pion" <<'EOF'
import "real" as r_orig
import "decoy" as real
pub trait ForceMono { fn fm(self) -> Int }
impl ForceMono for Int { fn fm(self) -> Int { self } }
pub fn keep_orig() -> Int { r_orig::id_e(r_orig::E::Hit) }
pub fn make_unit[T : ForceMono](x : T) -> Int {
  let _ = x.fm()
  real::id_e(real::E::Hit)
}
EOF
cat > "$TMP_DIR/r49_ep/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r49_ep/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  io_println(world, dep::keep_orig().to_string() + ":" + dep::make_unit(1).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_ep" "$PIONC" build -o "$TMP_DIR/r49_ep_b" "$TMP_DIR/r49_ep/app"
test "$("$TMP_DIR/r49_ep_b")" = "10:2"
PION_CACHE_DIR="$TMP_DIR/cas_r49_ep_rel" "$PIONC" build --release -o "$TMP_DIR/r49_ep_rel_b" "$TMP_DIR/r49_ep/app"
test "$("$TMP_DIR/r49_ep_rel_b")" = "10:2"

# 48f: Astra B4 — hot-loop 2,500-term left-associative integer `+` chain (iterative qbe_bounded_format_parts)
python3 - <<PYEOF > "$TMP_DIR/r49_sum/main.pion"
terms = " + ".join(["1"] * 2500)
print("pub fn main(world : World) -> Unit {")
print("  let mut acc = 0")
print("  let mut i = 0")
print("  while i < 2 {")
print("    acc = acc + (" + terms + ")")
print("    i = i + 1")
print("  }")
print("  io_println(world, acc.to_string())")
print("}")
PYEOF
PION_CACHE_DIR="$TMP_DIR/cas_r49_sum" "$PIONC" build -o "$TMP_DIR/r49_sum_b" "$TMP_DIR/r49_sum/main.pion"
test "$("$TMP_DIR/r49_sum_b")" = "5000"

echo "  R49 PR #34 Opus+Astra blockers (default-ret, non-fn shadow 7->9, chained-fwd 7->9/0, #fdeffwd 7->9/0, unit EPath 10:2, hot-loop 2500+==5000) (OK)"

echo "=== Wave J1 E2E [49/49]: R50 PR #34 final Opus+Astra edge cases (fwd-edge 3 consumers, __probe__ user fn, generic TParam non-callable in body & default_expr, xpkg non-fn param shadow in default_expr) ==="
mkdir -p "$TMP_DIR/r50_fwd" "$TMP_DIR/r50_fwd_cyc" "$TMP_DIR/r50_probe" \
  "$TMP_DIR/r50_tp_run" "$TMP_DIR/r50_tp_cyc1" "$TMP_DIR/r50_tp_cyc2" "$TMP_DIR/r50_tp_cas" \
  "$TMP_DIR/r50_xdef/dep/src" "$TMP_DIR/r50_xdef/app/src"

# 49a: Astra #1 — factory return-depth forwarding across `0>go>0@1` edge format (cycle + cold/hot CAS 7->9)
cat > "$TMP_DIR/r50_fwd_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn reader_maker() -> () -> Int { read_a }
fn go(mk : () -> (() -> Int)) -> Int { let f = mk(); f() }
fn outer(mk : () -> (() -> Int)) -> Int { go(mk) }
let A : Int = outer(reader_maker)
pub fn main() -> Int { A }
EOF
set +e; r50_o=$("$PIONC" check --json "$TMP_DIR/r50_fwd_cyc/main.pion" 2>&1); r50_rc=$?; set -e
test "$r50_rc" -ne 0; printf '%s' "$r50_o" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r50_fwd/a.pion" <<'EOF'
let A : String = outer(reader_maker).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r50_fwd/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn reader_maker() -> () -> Int { read_b }
fn go(mk : () -> (() -> Int)) -> Int { let f = mk(); f() }
fn outer(mk : () -> (() -> Int)) -> Int { go(mk) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r50_fwd" "$PIONC" build -o "$TMP_DIR/r50_fwd_c" "$TMP_DIR/r50_fwd/a.pion" "$TMP_DIR/r50_fwd/b.pion"
test "$("$TMP_DIR/r50_fwd_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r50_fwd/b.pion" > "$TMP_DIR/r50_fwd/b2.pion" && mv "$TMP_DIR/r50_fwd/b2.pion" "$TMP_DIR/r50_fwd/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r50_fwd" "$PIONC" build -o "$TMP_DIR/r50_fwd_h" "$TMP_DIR/r50_fwd/a.pion" "$TMP_DIR/r50_fwd/b.pion"
test "$("$TMP_DIR/r50_fwd_h")" = "9"

# 49b: Astra #2 — user fn named `__probe__` must not collide with internal sentinel
cat > "$TMP_DIR/r50_probe/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn __probe__() -> Int { 0 }
fn use_p(f : () -> Int, g : () -> Int = __probe__) -> Int { let _ = f; g() }
fn wrap_p(f : () -> Int) -> Int { use_p(f) }
let A : Int = wrap_p(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r50_probe" "$PIONC" build -o "$TMP_DIR/r50_probe_b" "$TMP_DIR/r50_probe/main.pion"
test "$("$TMP_DIR/r50_probe_b")" = "0"

# 49c: Astra #3 + Opus blocker — generic TParam param is non-callable in bare `READ()` (body + mono + default_expr)
cat > "$TMP_DIR/r50_tp_run/main.pion" <<'EOF'
fn READ() -> Int { 42 }
fn bad() -> Int { 99 }
trait Tag { fn tag(self) -> Int }
impl Tag for Int { fn tag(self) -> Int { self } }
fn r13[T](READ : T) -> Int { let _ = READ; READ() }
fn r14[U : Tag, T](u : U, READ : T) -> Int { let _ = u.tag(); let _ = READ; READ() }
fn r15[T](READ : T, x : Int = READ()) -> Int { let _ = READ; x }
pub fn main(world : World) -> Unit {
  io_println(world, r13(bad).to_string() + ":" + r14(1, bad).to_string() + ":" + r15(bad).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r50_tp" "$PIONC" build -o "$TMP_DIR/r50_tp_b" "$TMP_DIR/r50_tp_run/main.pion"
test "$("$TMP_DIR/r50_tp_b")" = "42:42:42"
PION_CACHE_DIR="$TMP_DIR/cas_r50_tp_rel" "$PIONC" build --release -o "$TMP_DIR/r50_tp_rel_b" "$TMP_DIR/r50_tp_run/main.pion"
test "$("$TMP_DIR/r50_tp_rel_b")" = "42:42:42"

cat > "$TMP_DIR/r50_tp_cyc1/main.pion" <<'EOF'
fn READ() -> Int { A }
fn zero() -> Int { 0 }
fn g[T](READ : T, x : Int = READ()) -> Int { let _ = READ; x }
let A : Int = g(zero)
pub fn main() -> Int { A }
EOF
set +e; r50_o=$("$PIONC" check --json "$TMP_DIR/r50_tp_cyc1/main.pion" 2>&1); r50_rc=$?; set -e
test "$r50_rc" -ne 0; printf '%s' "$r50_o" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r50_tp_cyc2/main.pion" <<'EOF'
fn READ() -> Int { A }
fn zero() -> Int { 0 }
fn g[T](READ : T) -> Int { let _ = READ; READ() }
let A : Int = g(zero)
pub fn main() -> Int { A }
EOF
set +e; r50_o=$("$PIONC" check --json "$TMP_DIR/r50_tp_cyc2/main.pion" 2>&1); r50_rc=$?; set -e
test "$r50_rc" -ne 0; printf '%s' "$r50_o" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r50_tp_cas/a.pion" <<'EOF'
let A : String = g1(zero).to_string() + ":" + g2(zero).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r50_tp_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn zero() -> Int { 0 }
fn g1[T](READ : T) -> Int { let _ = READ; READ() }
fn g2[T](READ : T, x : Int = READ()) -> Int { let _ = READ; x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r50_tp_cas" "$PIONC" build -o "$TMP_DIR/r50_tp_cas_c" "$TMP_DIR/r50_tp_cas/a.pion" "$TMP_DIR/r50_tp_cas/b.pion"
test "$("$TMP_DIR/r50_tp_cas_c")" = "7:7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r50_tp_cas/b.pion" > "$TMP_DIR/r50_tp_cas/b2.pion" && mv "$TMP_DIR/r50_tp_cas/b2.pion" "$TMP_DIR/r50_tp_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r50_tp_cas" "$PIONC" build -o "$TMP_DIR/r50_tp_cas_h" "$TMP_DIR/r50_tp_cas/a.pion" "$TMP_DIR/r50_tp_cas/b.pion"
test "$("$TMP_DIR/r50_tp_cas_h")" = "9:9"

# 49d: Astra #4 — cross-pkg default_expr with non-fn prior param sharing name with defining-pkg fn
cat > "$TMP_DIR/r50_xdef/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r50_xdef/dep/src/lib.pion" <<'EOF'
fn READ() -> Int { 7 }
pub fn g(READ : Int, x : Int = READ() + READ) -> Int { x }
EOF
cat > "$TMP_DIR/r50_xdef/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r50_xdef/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  io_println(world, dep::g(1).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r50_xdef" "$PIONC" build -o "$TMP_DIR/r50_xdef_b" "$TMP_DIR/r50_xdef/app"
test "$("$TMP_DIR/r50_xdef_b")" = "8"
PION_CACHE_DIR="$TMP_DIR/cas_r50_xdef_rel" "$PIONC" build --release -o "$TMP_DIR/r50_xdef_rel_b" "$TMP_DIR/r50_xdef/app"
test "$("$TMP_DIR/r50_xdef_rel_b")" = "8"

echo "  R50 PR #34 final Opus+Astra fixes (fwd-edge 7->9, __probe__==0, TParam 42:42:42 & 7:7->9:9, xpkg default_expr==8) (OK)"

echo "=== Wave J1 E2E [50/50]: R51 ground-truth call_pkg unification (mono TParam/let/closure, xpkg default_expr 10-case matrix & private TFn const, 6x cycle + cold/hot CAS 7->9) ==="
mkdir -p "$TMP_DIR/r51_local" \
  "$TMP_DIR/r51_xpkg/dep/src" "$TMP_DIR/r51_xpkg/app/src" \
  "$TMP_DIR/r51_opt_cyc" "$TMP_DIR/r51_opt_cas" \
  "$TMP_DIR/r51_mk_cyc" "$TMP_DIR/r51_mk_cas" \
  "$TMP_DIR/r51_let_cyc" "$TMP_DIR/r51_let_cas" \
  "$TMP_DIR/r51_clo_cyc" "$TMP_DIR/r51_clo_cas" \
  "$TMP_DIR/r51_def_cyc" "$TMP_DIR/r51_def_cas" \
  "$TMP_DIR/r51_tp_cyc" "$TMP_DIR/r51_tp_cas"

# 50a: Mono `let READ : T = x; READ()` + r16/r17/r18/r19 (dev + --release)
cat > "$TMP_DIR/r51_local/main.pion" <<'EOF'
fn READ() -> Int { 42 }
fn bad() -> Int { 99 }
trait Tag { fn tag(self) -> Int }
impl Tag for Int { fn tag(self) -> Int { self } }
fn r14_let[U : Tag, T](u : U, x : T) -> Int {
  let _ = u.tag()
  let READ : T = x
  let _ = READ
  READ()
}
fn r16[F](x : F) -> Int {
  let READ = x
  let _ = READ
  READ()
}
fn r17[F](x : F, y : Int = { let READ = x; let _ = READ; READ() }) -> Int {
  let _ = x
  y
}
fn r18() -> Int {
  let READ = 0
  let _ = READ
  READ()
}
fn r19() -> Int {
  let c = fn(READ : Int) -> Int { let _ = READ; READ() }
  c(0)
}
pub fn main(world : World) -> Unit {
  io_println(
    world,
    r14_let(1, bad).to_string() + ":" +
    r16(bad).to_string() + ":" +
    r17(bad).to_string() + ":" +
    r18().to_string() + ":" +
    r19().to_string(),
  )
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_loc" "$PIONC" build -o "$TMP_DIR/r51_loc_b" "$TMP_DIR/r51_local/main.pion"
test "$("$TMP_DIR/r51_loc_b")" = "42:42:42:42:42"
PION_CACHE_DIR="$TMP_DIR/cas_r51_loc_rel" "$PIONC" build --release -o "$TMP_DIR/r51_loc_rel_b" "$TMP_DIR/r51_local/main.pion"
test "$("$TMP_DIR/r51_loc_rel_b")" = "42:42:42:42:42"

# 50b: Cross-pkg default_expr full matrix (with decoy `app::READ() -> 999`) + private TFn const + optional callback param
cat > "$TMP_DIR/r51_xpkg/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r51_xpkg/dep/src/lib.pion" <<'EOF'
fn READ() -> Int { 42 }
fn seven() -> Int { 7 }
let READC : () -> Int = seven

pub fn a(x : Int = { let READ = 0; let _ = READ; READ() }) -> Int { x }
pub fn b(x : Int = { let READ = fn() -> Int { 1 }; READ() }) -> Int { x }
pub fn c[F](f : F, x : Int = { let READ = f; let _ = READ; READ() }) -> Int { let _ = f; x }
pub fn e(READ : Int, x : Int = READ()) -> Int { let _ = READ; x }
pub fn f2(READ : () -> Int, x : Int = READ()) -> Int { let _ = READ; x }
pub fn g(x : Int = { let mut s = 0; for READ in [3] { let _ = READ; s = s + READ() }; s }) -> Int { x }
pub fn h(x : Int = { let READ : Int = 0; let _ = READ; READ() }) -> Int { x }
pub fn g1(x : Int = { let READ = 1; READ() + READ }) -> Int { x }
pub fn g2(READC : Int, x : Int = READC() + READC) -> Int { x }
pub fn g3(READ? : () -> Int, x : Int = READ()) -> Int { let _ = READ; x }
EOF
cat > "$TMP_DIR/r51_xpkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r51_xpkg/app/src/main.pion" <<'EOF'
import "dep"
fn READ() -> Int { 999 }
fn READC() -> Int { 999 }
fn one() -> Int { 1 }
pub fn main(world : World) -> Unit {
  let _ = READ() + READC()
  let out = dep::a().to_string() + ":" +
    dep::b().to_string() + ":" +
    dep::c(one).to_string() + ":" +
    dep::e(0).to_string() + ":" +
    dep::f2(one).to_string() + ":" +
    dep::g().to_string() + ":" +
    dep::h().to_string() + ":" +
    dep::g1().to_string() + ":" +
    dep::g2(1).to_string() + ":" +
    dep::g3().to_string()
  io_println(world, out)
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_xpkg" "$PIONC" build -o "$TMP_DIR/r51_xpkg_b" "$TMP_DIR/r51_xpkg/app"
test "$("$TMP_DIR/r51_xpkg_b")" = "42:1:42:42:1:42:42:43:8:42"
PION_CACHE_DIR="$TMP_DIR/cas_r51_xpkg_rel" "$PIONC" build --release -o "$TMP_DIR/r51_xpkg_rel_b" "$TMP_DIR/r51_xpkg/app"
test "$("$TMP_DIR/r51_xpkg_rel_b")" = "42:1:42:42:1:42:42:43:8:42"

# 50c: 6x two-file const cycles + cold/hot CAS (7 -> 9)
# (1) optional_param_shadow
cat > "$TMP_DIR/r51_opt_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn g(READ? : () -> Int, x : Int = READ()) -> Int { let _ = READ; x }
let A : Int = g()
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_opt_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_opt_cas/a.pion" <<'EOF'
let A : String = g().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_opt_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn g(READ? : () -> Int, x : Int = READ()) -> Int { let _ = READ; x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_opt" "$PIONC" build -o "$TMP_DIR/r51_opt_c" "$TMP_DIR/r51_opt_cas/a.pion" "$TMP_DIR/r51_opt_cas/b.pion"
test "$("$TMP_DIR/r51_opt_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_opt_cas/b.pion" > "$TMP_DIR/r51_opt_cas/b2.pion" && mv "$TMP_DIR/r51_opt_cas/b2.pion" "$TMP_DIR/r51_opt_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_opt" "$PIONC" build -o "$TMP_DIR/r51_opt_h" "$TMP_DIR/r51_opt_cas/a.pion" "$TMP_DIR/r51_opt_cas/b.pion"
test "$("$TMP_DIR/r51_opt_h")" = "9"

# (2) mk_int_ret_shadow
cat > "$TMP_DIR/r51_mk_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn mk() -> () -> Int { read_a }
fn g(mk : Int) -> Int { let _ = mk; let f = mk(); f() }
let A : Int = g(0)
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_mk_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_mk_cas/a.pion" <<'EOF'
let A : String = g(0).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_mk_cas/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn mk() -> () -> Int { read_b }
fn g(mk : Int) -> Int { let _ = mk; let f = mk(); f() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_mk" "$PIONC" build -o "$TMP_DIR/r51_mk_c" "$TMP_DIR/r51_mk_cas/a.pion" "$TMP_DIR/r51_mk_cas/b.pion"
test "$("$TMP_DIR/r51_mk_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_mk_cas/b.pion" > "$TMP_DIR/r51_mk_cas/b2.pion" && mv "$TMP_DIR/r51_mk_cas/b2.pion" "$TMP_DIR/r51_mk_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_mk" "$PIONC" build -o "$TMP_DIR/r51_mk_h" "$TMP_DIR/r51_mk_cas/a.pion" "$TMP_DIR/r51_mk_cas/b.pion"
test "$("$TMP_DIR/r51_mk_h")" = "9"

# (3) body_let_int_shadow
cat > "$TMP_DIR/r51_let_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn go() -> Int { let READ = 0; let _ = READ; READ() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_let_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_let_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_let_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn go() -> Int { let READ = 0; let _ = READ; READ() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_let" "$PIONC" build -o "$TMP_DIR/r51_let_c" "$TMP_DIR/r51_let_cas/a.pion" "$TMP_DIR/r51_let_cas/b.pion"
test "$("$TMP_DIR/r51_let_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_let_cas/b.pion" > "$TMP_DIR/r51_let_cas/b2.pion" && mv "$TMP_DIR/r51_let_cas/b2.pion" "$TMP_DIR/r51_let_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_let" "$PIONC" build -o "$TMP_DIR/r51_let_h" "$TMP_DIR/r51_let_cas/a.pion" "$TMP_DIR/r51_let_cas/b.pion"
test "$("$TMP_DIR/r51_let_h")" = "9"

# (4) closure_param_int_shadow
cat > "$TMP_DIR/r51_clo_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn go() -> Int { let c = fn(READ : Int) -> Int { let _ = READ; READ() }; c(0) }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_clo_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_clo_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_clo_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn go() -> Int { let c = fn(READ : Int) -> Int { let _ = READ; READ() }; c(0) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_clo" "$PIONC" build -o "$TMP_DIR/r51_clo_c" "$TMP_DIR/r51_clo_cas/a.pion" "$TMP_DIR/r51_clo_cas/b.pion"
test "$("$TMP_DIR/r51_clo_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_clo_cas/b.pion" > "$TMP_DIR/r51_clo_cas/b2.pion" && mv "$TMP_DIR/r51_clo_cas/b2.pion" "$TMP_DIR/r51_clo_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_clo" "$PIONC" build -o "$TMP_DIR/r51_clo_h" "$TMP_DIR/r51_clo_cas/a.pion" "$TMP_DIR/r51_clo_cas/b.pion"
test "$("$TMP_DIR/r51_clo_h")" = "9"

# (5) default_let_int_shadow
cat > "$TMP_DIR/r51_def_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn g(x : Int = { let READ = 0; let _ = READ; READ() }) -> Int { x }
let A : Int = g()
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_def_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_def_cas/a.pion" <<'EOF'
let A : String = g().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_def_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn g(x : Int = { let READ = 0; let _ = READ; READ() }) -> Int { x }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_def" "$PIONC" build -o "$TMP_DIR/r51_def_c" "$TMP_DIR/r51_def_cas/a.pion" "$TMP_DIR/r51_def_cas/b.pion"
test "$("$TMP_DIR/r51_def_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_def_cas/b.pion" > "$TMP_DIR/r51_def_cas/b2.pion" && mv "$TMP_DIR/r51_def_cas/b2.pion" "$TMP_DIR/r51_def_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_def" "$PIONC" build -o "$TMP_DIR/r51_def_h" "$TMP_DIR/r51_def_cas/a.pion" "$TMP_DIR/r51_def_cas/b.pion"
test "$("$TMP_DIR/r51_def_h")" = "9"

# (6) body_let_tparam
cat > "$TMP_DIR/r51_tp_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn zero() -> Int { 0 }
fn g[F](x : F) -> Int { let READ = x; let _ = READ; READ() }
let A : Int = g(zero)
pub fn main() -> Int { A }
EOF
set +e; r51_o=$("$PIONC" check --json "$TMP_DIR/r51_tp_cyc/main.pion" 2>&1); r51_rc=$?; set -e
test "$r51_rc" -ne 0; printf '%s' "$r51_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r51_tp_cas/a.pion" <<'EOF'
let A : String = g(zero).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r51_tp_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn zero() -> Int { 0 }
fn g[F](x : F) -> Int { let READ = x; let _ = READ; READ() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r51_tp" "$PIONC" build -o "$TMP_DIR/r51_tp_c" "$TMP_DIR/r51_tp_cas/a.pion" "$TMP_DIR/r51_tp_cas/b.pion"
test "$("$TMP_DIR/r51_tp_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r51_tp_cas/b.pion" > "$TMP_DIR/r51_tp_cas/b2.pion" && mv "$TMP_DIR/r51_tp_cas/b2.pion" "$TMP_DIR/r51_tp_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r51_tp" "$PIONC" build -o "$TMP_DIR/r51_tp_h" "$TMP_DIR/r51_tp_cas/a.pion" "$TMP_DIR/r51_tp_cas/b.pion"
test "$("$TMP_DIR/r51_tp_h")" = "9"

echo "  R51 ground-truth call_pkg unification (local 42x5, xpkg 10-case matrix, 6x cycle + cold/hot CAS 7->9) (OK)"

echo "=== Wave J1 E2E [51/51]: R52 Astra #1-#5 + Opus Note 2 (Option::None/Some hygiene, call_nonlocal builtin/probe, non-exact hot CAS, const-closure RC guard, q1/q2 & match/is shadow) ==="
mkdir -p "$TMP_DIR/r52_opt" "$TMP_DIR/r52_bi" "$TMP_DIR/r52_probe" \
  "$TMP_DIR/r52_nonex_cyc" "$TMP_DIR/r52_nonex_cas" \
  "$TMP_DIR/r52_rc" "$TMP_DIR/r52_q12" \
  "$TMP_DIR/r52_mis_cyc" "$TMP_DIR/r52_mis_cas"

# 51a: Astra #1 — local `None` / `Some` must not hijack synthesized optional `Option::None` / `Option::Some`
cat > "$TMP_DIR/r52_opt/main.pion" <<'EOF'
fn pick(n? : Int) -> Int { n.unwrap_or(7) }
fn c1() -> Int { let None : Int = 9; let _ = None; pick() }
fn c2() -> Int { let None : Option[Int] = Some(9); let _ = None; pick() }
fn c3() -> Int { let Some : Int = 9; let _ = Some; pick(n=5) }
pub fn main(world : World) -> Unit {
  io_println(world, c1().to_string() + ":" + c2().to_string() + ":" + c3().to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_opt" "$PIONC" build -o "$TMP_DIR/r52_opt_b" "$TMP_DIR/r52_opt/main.pion"
test "$("$TMP_DIR/r52_opt_b")" = "7:7:5"
PION_CACHE_DIR="$TMP_DIR/cas_r52_opt_rel" "$PIONC" build --release -o "$TMP_DIR/r52_opt_rel_b" "$TMP_DIR/r52_opt/main.pion"
test "$("$TMP_DIR/r52_opt_rel_b")" = "7:7:5"

# 51b: Astra #2 — generic `let math_sqrt : T = x` specialized to `(Double) -> Double` must still call builtin `math_sqrt`
cat > "$TMP_DIR/r52_bi/main.pion" <<'EOF'
trait Tag { fn tag(self) -> Int }
impl Tag for Int { fn tag(self) -> Int { self } }
fn bad(x : Double) -> Double { let _ = x; 99.0 }
fn r14_builtin[U : Tag, T](u : U, x : T) -> Double {
  let _ = u.tag()
  let math_sqrt : T = x
  let _ = math_sqrt
  math_sqrt(9.0)
}
pub fn main(world : World) -> Unit {
  let r = r14_builtin(1, bad)
  io_println(world, if r == 3.0 { "3.0" } else { r.to_string() })
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_bi" "$PIONC" build -o "$TMP_DIR/r52_bi_b" "$TMP_DIR/r52_bi/main.pion"
test "$("$TMP_DIR/r52_bi_b")" = "3.0"
PION_CACHE_DIR="$TMP_DIR/cas_r52_bi_rel" "$PIONC" build --release -o "$TMP_DIR/r52_bi_rel_b" "$TMP_DIR/r52_bi/main.pion"
test "$("$TMP_DIR/r52_bi_rel_b")" = "3.0"

# 51c: Astra #3 — `qbe_probe_expr_ty_with` respects `call_nonlocal` under `--release` scalar opt inline
cat > "$TMP_DIR/r52_probe/main.pion" <<'EOF'
struct A { v : Int }
struct B { v : Int }
fn A::pick(self : A) -> Option[Int] { let _ = self.v; Some(42) }
fn B::pick(self : B) -> Option[Int] { let _ = self.v; Some(99) }
fn READ() -> A { A::{ v: 42 } }
fn bad_b() -> B { B::{ v: 99 } }
trait Tag { fn tag(self) -> Int }
impl Tag for Int { fn tag(self) -> Int { self } }
fn run[U : Tag, T](u : U, x : T) -> Int {
  let _ = u.tag()
  let READ : T = x
  let _ = READ
  match READ().pick() {
    Some(v) => v
    None => 0
  }
}
pub fn main(world : World) -> Unit {
  io_println(world, run(1, bad_b).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_probe" "$PIONC" build -o "$TMP_DIR/r52_probe_b" "$TMP_DIR/r52_probe/main.pion"
test "$("$TMP_DIR/r52_probe_b")" = "42"
PION_CACHE_DIR="$TMP_DIR/cas_r52_probe_rel" "$PIONC" build --release -o "$TMP_DIR/r52_probe_rel_b" "$TMP_DIR/r52_probe/main.pion"
test "$("$TMP_DIR/r52_probe_rel_b")" = "42"

# 51d: Astra #4 — non-exact local `let READ = zero(); READ()` cycle + 2-file cold/hot CAS (7 -> 9)
cat > "$TMP_DIR/r52_nonex_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn zero() -> Int { 0 }
fn go() -> Int { let READ = zero(); let _ = READ; READ() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r52_o=$("$PIONC" check --json "$TMP_DIR/r52_nonex_cyc/main.pion" 2>&1); r52_rc=$?; set -e
test "$r52_rc" -ne 0; printf '%s' "$r52_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r52_nonex_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r52_nonex_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn zero() -> Int { 0 }
fn go() -> Int { let READ = zero(); let _ = READ; READ() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_nonex" "$PIONC" build -o "$TMP_DIR/r52_nonex_c" "$TMP_DIR/r52_nonex_cas/a.pion" "$TMP_DIR/r52_nonex_cas/b.pion"
test "$("$TMP_DIR/r52_nonex_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r52_nonex_cas/b.pion" > "$TMP_DIR/r52_nonex_cas/b2.pion" && mv "$TMP_DIR/r52_nonex_cas/b2.pion" "$TMP_DIR/r52_nonex_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r52_nonex" "$PIONC" build -o "$TMP_DIR/r52_nonex_h" "$TMP_DIR/r52_nonex_cas/a.pion" "$TMP_DIR/r52_nonex_cas/b.pion"
test "$("$TMP_DIR/r52_nonex_h")" = "9"

# 51e: Astra #5 — unqualified `TFn` const call with early-return arg must not leak RC (ASan/LSan clean)
cat > "$TMP_DIR/r52_rc/main.pion" <<'EOF'
fn apply_impl(s : String, k : Int) -> Int { s.length() + k }
let APPLY : (String, Int) -> Int = apply_impl
fn step(n : Int, stop : Bool) -> Int {
  APPLY("dyn_" + n.to_string(), if stop { return 0 } else { 1 })
}
pub fn main(world : World) -> Unit {
  let mut acc = 0
  let mut i = 0
  while i < 100 {
    acc = acc + step(i, true)
    i = i + 1
  }
  acc = acc + step(7, false)
  io_println(world, acc.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_rc" "$PIONC" build -o "$TMP_DIR/r52_rc_b" "$TMP_DIR/r52_rc/main.pion"
test "$("$TMP_DIR/r52_rc_b")" = "6"
PION_CACHE_DIR="$TMP_DIR/cas_r52_rc_rel" "$PIONC" build --release -o "$TMP_DIR/r52_rc_rel_b" "$TMP_DIR/r52_rc/main.pion"
test "$("$TMP_DIR/r52_rc_rel_b")" = "6"
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/r52_asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/r52_pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/r52_libpionrt_asan.a" "$TMP_DIR/r52_pion_rt_asan.o"
  for R52_MODE in "" --release; do
    "$PIONC" build $R52_MODE --emit-obj "$TMP_DIR/r52_rc.o" "$TMP_DIR/r52_rc/main.pion"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/r52_rc.o" "$TMP_DIR/r52_libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/r52_rc_asan"
    r52_out=$("$TMP_DIR/r52_rc_asan")
    test "$r52_out" = "6"
  done
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: PION_REQUIRE_SANITIZERS=1 but cc -fsanitize=address unavailable for [51e]" >&2
  exit 1
fi

# 51f: Opus Note 2 — q1/q2 (generic F instantiated to String-returning & 1-arg closures) + match/is Int shadow cycle & CAS 7->9
cat > "$TMP_DIR/r52_q12/main.pion" <<'EOF'
fn READ() -> Int { 42 }
fn q1_fn() -> String { "bad" }
fn q2_fn(x : Int) -> Int { x + 99 }
fn q1[F](f : F) -> Int { let READ = f; let _ = READ; READ() }
fn q2[F](f : F) -> Int { let READ = f; let _ = READ; READ() }
pub fn main(world : World) -> Unit {
  io_println(world, q1(q1_fn).to_string() + ":" + q2(q2_fn).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_q12" "$PIONC" build -o "$TMP_DIR/r52_q12_b" "$TMP_DIR/r52_q12/main.pion"
test "$("$TMP_DIR/r52_q12_b")" = "42:42"
PION_CACHE_DIR="$TMP_DIR/cas_r52_q12_rel" "$PIONC" build --release -o "$TMP_DIR/r52_q12_rel_b" "$TMP_DIR/r52_q12/main.pion"
test "$("$TMP_DIR/r52_q12_rel_b")" = "42:42"

cat > "$TMP_DIR/r52_mis_cyc/main.pion" <<'EOF'
fn read() -> Int { A }
fn go_m(o : Option[Int]) -> Int { match o { Some(read) => { let _ = read; read() } None => 0 } }
fn go_is(o : Option[Int]) -> Int { if o is Some(read) { let _ = read; read() } else { 0 } }
let A : Int = go_m(Some(1)) + go_is(Some(1))
pub fn main() -> Int { A }
EOF
set +e; r52_o=$("$PIONC" check --json "$TMP_DIR/r52_mis_cyc/main.pion" 2>&1); r52_rc=$?; set -e
test "$r52_rc" -ne 0; printf '%s' "$r52_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r52_mis_cas/a.pion" <<'EOF'
let A : String = go_m(Some(1)).to_string() + ":" + go_is(Some(1)).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r52_mis_cas/b.pion" <<'EOF'
fn read() -> Int { B }
fn make_b() -> Int { 7 }
fn go_m(o : Option[Int]) -> Int { match o { Some(read) => { let _ = read; read() } None => 0 } }
fn go_is(o : Option[Int]) -> Int { if o is Some(read) { let _ = read; read() } else { 0 } }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r52_mis" "$PIONC" build -o "$TMP_DIR/r52_mis_c" "$TMP_DIR/r52_mis_cas/a.pion" "$TMP_DIR/r52_mis_cas/b.pion"
test "$("$TMP_DIR/r52_mis_c")" = "7:7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r52_mis_cas/b.pion" > "$TMP_DIR/r52_mis_cas/b2.pion" && mv "$TMP_DIR/r52_mis_cas/b2.pion" "$TMP_DIR/r52_mis_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r52_mis" "$PIONC" build -o "$TMP_DIR/r52_mis_h" "$TMP_DIR/r52_mis_cas/a.pion" "$TMP_DIR/r52_mis_cas/b.pion"
test "$("$TMP_DIR/r52_mis_h")" = "9:9"

echo "  R52 Astra #1-#5 + Opus Note 2 (Option::None/Some 7:7:5, math_sqrt==3, probe==42, non-exact 7->9, const-clo RC==6, q1/q2==42:42, match/is 7:7->9:9) (OK)"

echo "=== Wave J1 E2E [52/52]: R53 final Astra #1-#2 (xpkg mono_pkg builtin isolation, pkg-const alias & unannotated closure param hot CAS 7->9) ==="
mkdir -p "$TMP_DIR/r53_xbi/dep/src" "$TMP_DIR/r53_xbi/app/src" \
  "$TMP_DIR/r53_cal_cyc" "$TMP_DIR/r53_cal_cas" \
  "$TMP_DIR/r53_ucl_cyc" "$TMP_DIR/r53_ucl_cas"

# 52a: Astra #1 — cross-pkg mono_pkg generic calling builtin `math_sqrt(9.0)` with caller `fn math_sqrt` decoy
cat > "$TMP_DIR/r53_xbi/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r53_xbi/dep/src/lib.pion" <<'EOF'
pub trait Tag { fn tag(self) -> Int }
impl Tag for Int { fn tag(self) -> Int { self } }
pub fn dep_sqrt[U : Tag, T](u : U, x : T) -> Double {
  let _ = u.tag()
  let math_sqrt : T = x
  let _ = math_sqrt
  math_sqrt(9.0)
}
EOF
cat > "$TMP_DIR/r53_xbi/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r53_xbi/app/src/main.pion" <<'EOF'
import "dep"
fn math_sqrt(x : Double) -> Double { let _ = x; 99.0 }
pub fn main(world : World) -> Unit {
  let r = dep::dep_sqrt(1, math_sqrt)
  io_println(world, if r == 3.0 { "3.0" } else { r.to_string() })
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r53_xbi" "$PIONC" build -o "$TMP_DIR/r53_xbi_b" "$TMP_DIR/r53_xbi/app"
test "$("$TMP_DIR/r53_xbi_b")" = "3.0"
PION_CACHE_DIR="$TMP_DIR/cas_r53_xbi_rel" "$PIONC" build --release -o "$TMP_DIR/r53_xbi_rel_b" "$TMP_DIR/r53_xbi/app"
test "$("$TMP_DIR/r53_xbi_rel_b")" = "3.0"

# 52b: Astra #2 — package-level Int const alias `let READ = ZERO; READ()` cycle + 2-file cold/hot CAS (7 -> 9)
cat > "$TMP_DIR/r53_cal_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
let ZERO : Int = 0
fn go() -> Int { let READ = ZERO; let _ = READ; READ() }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r53_o=$("$PIONC" check --json "$TMP_DIR/r53_cal_cyc/main.pion" 2>&1); r53_rc=$?; set -e
test "$r53_rc" -ne 0; printf '%s' "$r53_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r53_cal_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r53_cal_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
let ZERO : Int = 0
fn go() -> Int { let READ = ZERO; let _ = READ; READ() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r53_cal" "$PIONC" build -o "$TMP_DIR/r53_cal_c" "$TMP_DIR/r53_cal_cas/a.pion" "$TMP_DIR/r53_cal_cas/b.pion"
test "$("$TMP_DIR/r53_cal_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r53_cal_cas/b.pion" > "$TMP_DIR/r53_cal_cas/b2.pion" && mv "$TMP_DIR/r53_cal_cas/b2.pion" "$TMP_DIR/r53_cal_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r53_cal" "$PIONC" build -o "$TMP_DIR/r53_cal_h" "$TMP_DIR/r53_cal_cas/a.pion" "$TMP_DIR/r53_cal_cas/b.pion"
test "$("$TMP_DIR/r53_cal_h")" = "9"

# 52c: Astra #2 — unannotated closure param `fn(READ) { READ() }` cycle + 2-file cold/hot CAS (7 -> 9)
cat > "$TMP_DIR/r53_ucl_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn go() -> Int { let c : (() -> Int) -> Int = fn(READ) { let _ = READ; READ() }; c(READ) }
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r53_o=$("$PIONC" check --json "$TMP_DIR/r53_ucl_cyc/main.pion" 2>&1); r53_rc=$?; set -e
test "$r53_rc" -ne 0; printf '%s' "$r53_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r53_ucl_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r53_ucl_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn go() -> Int { let c : (() -> Int) -> Int = fn(READ) { let _ = READ; READ() }; c(READ) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r53_ucl" "$PIONC" build -o "$TMP_DIR/r53_ucl_c" "$TMP_DIR/r53_ucl_cas/a.pion" "$TMP_DIR/r53_ucl_cas/b.pion"
test "$("$TMP_DIR/r53_ucl_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r53_ucl_cas/b.pion" > "$TMP_DIR/r53_ucl_cas/b2.pion" && mv "$TMP_DIR/r53_ucl_cas/b2.pion" "$TMP_DIR/r53_ucl_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r53_ucl" "$PIONC" build -o "$TMP_DIR/r53_ucl_h" "$TMP_DIR/r53_ucl_cas/a.pion" "$TMP_DIR/r53_ucl_cas/b.pion"
test "$("$TMP_DIR/r53_ucl_h")" = "9"

echo "  R53 final Astra #1-#2 (xpkg math_sqrt==3.0, const-alias 7->9, unannotated closure param 7->9) (OK)"

echo "=== Wave J1 E2E [53/53]: R54 Astra #1-#3 (xpkg default_expr builtin isolation, container-wrapped param local alias & unannotated factory alias hot CAS 7->9) ==="
mkdir -p "$TMP_DIR/r54_xdef/dep/src" "$TMP_DIR/r54_xdef/app/src" \
  "$TMP_DIR/r54_wrap_cyc" "$TMP_DIR/r54_wrap_cas" \
  "$TMP_DIR/r54_fac_cyc" "$TMP_DIR/r54_fac_cas"

# 53a: Astra #1 — cross-pkg default_expr builtin `math_sqrt(9.0)` isolated from caller's `fn math_sqrt(x : String) -> String`
cat > "$TMP_DIR/r54_xdef/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r54_xdef/dep/src/lib.pion" <<'EOF'
pub fn pick(x : Double = math_sqrt(9.0)) -> Double { x }
EOF
cat > "$TMP_DIR/r54_xdef/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r54_xdef/app/src/main.pion" <<'EOF'
import "dep"
fn math_sqrt(x : String) -> String { x }
pub fn main(world : World) -> Unit {
  let _ = math_sqrt("ok")
  let r = dep::pick()
  io_println(world, if r == 3.0 { "3.0" } else { r.to_string() })
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r54_xdef" "$PIONC" build -o "$TMP_DIR/r54_xdef_b" "$TMP_DIR/r54_xdef/app"
test "$("$TMP_DIR/r54_xdef_b")" = "3.0"
PION_CACHE_DIR="$TMP_DIR/cas_r54_xdef_rel" "$PIONC" build --release -o "$TMP_DIR/r54_xdef_rel_b" "$TMP_DIR/r54_xdef/app"
test "$("$TMP_DIR/r54_xdef_rel_b")" = "3.0"

# 53b: Astra #2 — `let READ = Some(f); READ()` container-wrapped callback param alias cycle + cold/hot CAS (7 -> 9)
cat > "$TMP_DIR/r54_wrap_cyc/main.pion" <<'EOF'
fn READ() -> Int { A }
fn zero() -> Int { 0 }
fn go(f : () -> Int) -> Int { let READ = Some(f); let _ = READ; READ() }
let A : Int = go(zero)
pub fn main() -> Int { A }
EOF
set +e; r54_o=$("$PIONC" check --json "$TMP_DIR/r54_wrap_cyc/main.pion" 2>&1); r54_rc=$?; set -e
test "$r54_rc" -ne 0; printf '%s' "$r54_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r54_wrap_cas/a.pion" <<'EOF'
let A : String = go(zero).to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r54_wrap_cas/b.pion" <<'EOF'
fn READ() -> Int { B }
fn make_b() -> Int { 7 }
fn zero() -> Int { 0 }
fn go(f : () -> Int) -> Int { let READ = Some(f); let _ = READ; READ() }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r54_wrap" "$PIONC" build -o "$TMP_DIR/r54_wrap_c" "$TMP_DIR/r54_wrap_cas/a.pion" "$TMP_DIR/r54_wrap_cas/b.pion"
test "$("$TMP_DIR/r54_wrap_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r54_wrap_cas/b.pion" > "$TMP_DIR/r54_wrap_cas/b2.pion" && mv "$TMP_DIR/r54_wrap_cas/b2.pion" "$TMP_DIR/r54_wrap_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r54_wrap" "$PIONC" build -o "$TMP_DIR/r54_wrap_h" "$TMP_DIR/r54_wrap_cas/a.pion" "$TMP_DIR/r54_wrap_cas/b.pion"
test "$("$TMP_DIR/r54_wrap_h")" = "9"

# 53c: Astra #3 — unannotated factory param aliased locally `let alias = mk; let f = alias(); f()` cycle + cold/hot CAS (7 -> 9)
cat > "$TMP_DIR/r54_fac_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn reader_maker() -> () -> Int { read_a }
fn go() -> Int {
  let c : (() -> (() -> Int)) -> Int = fn(mk) { let alias = mk; let f = alias(); f() }
  c(reader_maker)
}
let A : Int = go()
pub fn main() -> Int { A }
EOF
set +e; r54_o=$("$PIONC" check --json "$TMP_DIR/r54_fac_cyc/main.pion" 2>&1); r54_rc=$?; set -e
test "$r54_rc" -ne 0; printf '%s' "$r54_o" | grep -q "E_CONST_CYCLE"
cat > "$TMP_DIR/r54_fac_cas/a.pion" <<'EOF'
let A : String = go().to_string()
pub fn main(world : World) -> Unit { io_println(world, A) }
EOF
cat > "$TMP_DIR/r54_fac_cas/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn reader_maker() -> () -> Int { read_b }
fn go() -> Int {
  let c : (() -> (() -> Int)) -> Int = fn(mk) { let alias = mk; let f = alias(); f() }
  c(reader_maker)
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r54_fac" "$PIONC" build -o "$TMP_DIR/r54_fac_c" "$TMP_DIR/r54_fac_cas/a.pion" "$TMP_DIR/r54_fac_cas/b.pion"
test "$("$TMP_DIR/r54_fac_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r54_fac_cas/b.pion" > "$TMP_DIR/r54_fac_cas/b2.pion" && mv "$TMP_DIR/r54_fac_cas/b2.pion" "$TMP_DIR/r54_fac_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r54_fac" "$PIONC" build -o "$TMP_DIR/r54_fac_h" "$TMP_DIR/r54_fac_cas/a.pion" "$TMP_DIR/r54_fac_cas/b.pion"
test "$("$TMP_DIR/r54_fac_h")" = "9"

echo "  R54 Astra #1-#3 (xpkg default builtin==3.0, Some(f) alias 7->9, unannotated factory alias 7->9) (OK)"

echo "=== Wave J1 E2E [54/54]: R55 Astra #1-#2 (xpkg default_expr shadowed enum ctor & cold/hot CAS init-order parity via call?:) ==="
mkdir -p "$TMP_DIR/r55_xctor/dep/src" "$TMP_DIR/r55_xctor/app/src" "$TMP_DIR/r55_ord"

# 54a: Astra #1 — cross-pkg default_expr enum ctor shadowed by prior param (`pub fn pick(Hit : Int, e : E = Hit(Hit))`)
cat > "$TMP_DIR/r55_xctor/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r55_xctor/dep/src/lib.pion" <<'EOF'
pub enum E { Hit(Int) }
pub fn pick(Hit : Int, e : E = Hit(Hit)) -> E { e }
EOF
cat > "$TMP_DIR/r55_xctor/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/r55_xctor/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  let v = match dep::pick(7) {
    dep::E::Hit(x) => x
  }
  io_println(world, v.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r55_xctor" "$PIONC" build -o "$TMP_DIR/r55_xctor_b" "$TMP_DIR/r55_xctor/app"
test "$("$TMP_DIR/r55_xctor_b")" = "7"
PION_CACHE_DIR="$TMP_DIR/cas_r55_xctor_rel" "$PIONC" build --release -o "$TMP_DIR/r55_xctor_rel_b" "$TMP_DIR/r55_xctor/app"
test "$("$TMP_DIR/r55_xctor_rel_b")" = "7"

# 54b: Astra #2 — cold & hot CAS init-order parity (`let A = go(tick)` before `let B = tick()` -> 0:1, never flipped to 1:0)
cat > "$TMP_DIR/r55_ord/a.pion" <<'EOF'
let COUNTER : AtomicInt = AtomicInt::new(0)
let A : Int = go(tick)
let B : Int = tick()
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + B.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r55_ord/b.pion" <<'EOF'
fn tick() -> Int { COUNTER.fetch_add(1) }
fn go(f : () -> Int) -> Int { let B = f; B() }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r55_ord" "$PIONC" build -o "$TMP_DIR/r55_ord_c" "$TMP_DIR/r55_ord/a.pion" "$TMP_DIR/r55_ord/b.pion"
test "$("$TMP_DIR/r55_ord_c")" = "0:1:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r55_ord/b.pion" > "$TMP_DIR/r55_ord/b2.pion" && mv "$TMP_DIR/r55_ord/b2.pion" "$TMP_DIR/r55_ord/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r55_ord" "$PIONC" build -o "$TMP_DIR/r55_ord_h" "$TMP_DIR/r55_ord/a.pion" "$TMP_DIR/r55_ord/b.pion"
test "$("$TMP_DIR/r55_ord_h")" = "0:1:2"

echo "  R55 Astra #1-#2 (xpkg shadowed enum ctor==7, cold/hot CAS init-order parity 0:1:1 -> 0:1:2) (OK)"

echo "=== Wave J1 E2E [55/55]: R56 Astra #1-#2 (unconditional call?: ambig + tc_nonlocal_builtin: shadowed enum ctor & ignore builtin zero false cycles) ==="
mkdir -p "$TMP_DIR/r56_ctor" "$TMP_DIR/r56_ign"

# 55a: shadowed enum ctor `let Hit = f; let _ = Hit(7); 0` (generic T) with `let A = go(read_a)` (dev + --release + hot CAS -> 0)
cat > "$TMP_DIR/r56_ctor/a.pion" <<'EOF'
let A : Int = go(read_a)
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r56_ctor/b.pion" <<'EOF'
enum E { Hit(Int) }
fn read_a(x : Int) -> Int { A + x }
fn go[T](f : T) -> Int { let Hit = f; let _ = Hit; let _ = Hit(7); 0 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r56_ctor" "$PIONC" build -o "$TMP_DIR/r56_ctor_c" "$TMP_DIR/r56_ctor/a.pion" "$TMP_DIR/r56_ctor/b.pion"
test "$("$TMP_DIR/r56_ctor_c")" = "0:1"
PION_CACHE_DIR="$TMP_DIR/cas_r56_ctor_rel" "$PIONC" build --release -o "$TMP_DIR/r56_ctor_rel" "$TMP_DIR/r56_ctor/a.pion" "$TMP_DIR/r56_ctor/b.pion"
test "$("$TMP_DIR/r56_ctor_rel")" = "0:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r56_ctor/b.pion" > "$TMP_DIR/r56_ctor/b2.pion" && mv "$TMP_DIR/r56_ctor/b2.pion" "$TMP_DIR/r56_ctor/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r56_ctor" "$PIONC" build -o "$TMP_DIR/r56_ctor_h" "$TMP_DIR/r56_ctor/a.pion" "$TMP_DIR/r56_ctor/b.pion"
test "$("$TMP_DIR/r56_ctor_h")" = "0:2"

# 55b: shadowed builtin `let ignore = f; ignore(7); 0` (generic T) with `let A = go(read_a)` (dev + --release + hot CAS -> 0)
cat > "$TMP_DIR/r56_ign/a.pion" <<'EOF'
let A : Int = go(read_a)
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r56_ign/b.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn go[T](f : T) -> Int { let ignore = f; let _ = ignore; ignore(7); 0 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r56_ign" "$PIONC" build -o "$TMP_DIR/r56_ign_c" "$TMP_DIR/r56_ign/a.pion" "$TMP_DIR/r56_ign/b.pion"
test "$("$TMP_DIR/r56_ign_c")" = "0:1"
PION_CACHE_DIR="$TMP_DIR/cas_r56_ign_rel" "$PIONC" build --release -o "$TMP_DIR/r56_ign_rel" "$TMP_DIR/r56_ign/a.pion" "$TMP_DIR/r56_ign/b.pion"
test "$("$TMP_DIR/r56_ign_rel")" = "0:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r56_ign/b.pion" > "$TMP_DIR/r56_ign/b2.pion" && mv "$TMP_DIR/r56_ign/b2.pion" "$TMP_DIR/r56_ign/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r56_ign" "$PIONC" build -o "$TMP_DIR/r56_ign_h" "$TMP_DIR/r56_ign/a.pion" "$TMP_DIR/r56_ign/b.pion"
test "$("$TMP_DIR/r56_ign_h")" = "0:2"

echo "  R56 Astra #1-#2 (shadowed enum ctor & ignore builtin cold/hot/release 0:1 -> 0:2, zero false cycles) (OK)"

echo "=== Wave J1 E2E [56/56]: R57 sig_is_ctor_call skips forwarded param/alias arg (Some(f)+ignore(7) ok, unpacked g(7) cycle + 7->9 CAS) ==="
mkdir -p "$TMP_DIR/r57_ok" "$TMP_DIR/r57_cyc" "$TMP_DIR/r57_cas"

# 56a: positive — `let ignore = Some(f); ignore(7); 0` with `let A : Int = go(read_a)` (dev + --release + 2-file hot CAS 0:1 -> 0:2)
cat > "$TMP_DIR/r57_ok/a.pion" <<'EOF'
let A : Int = go(read_a)
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r57_ok/b.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn go(f : (Int) -> Int) -> Int { let ignore = Some(f); ignore(7); 0 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r57_ok" "$PIONC" build -o "$TMP_DIR/r57_ok_c" "$TMP_DIR/r57_ok/a.pion" "$TMP_DIR/r57_ok/b.pion"
test "$("$TMP_DIR/r57_ok_c")" = "0:1"
PION_CACHE_DIR="$TMP_DIR/cas_r57_ok_rel" "$PIONC" build --release -o "$TMP_DIR/r57_ok_rel" "$TMP_DIR/r57_ok/a.pion" "$TMP_DIR/r57_ok/b.pion"
test "$("$TMP_DIR/r57_ok_rel")" = "0:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r57_ok/b.pion" > "$TMP_DIR/r57_ok/b2.pion" && mv "$TMP_DIR/r57_ok/b2.pion" "$TMP_DIR/r57_ok/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r57_ok" "$PIONC" build -o "$TMP_DIR/r57_ok_h" "$TMP_DIR/r57_ok/a.pion" "$TMP_DIR/r57_ok/b.pion"
test "$("$TMP_DIR/r57_ok_h")" = "0:2"

# 56b: negative pair — unpacking Some(f) and calling g(7) still reports E_CONST_CYCLE, and non-cyclic 2-file cold/hot CAS outputs 7 -> 9
cat > "$TMP_DIR/r57_cyc/main.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn go(f : (Int) -> Int) -> Int {
  let ignore = Some(f)
  ignore(7)
  match ignore { Some(g) => g(7) None => 0 }
}
let A : Int = go(read_a)
pub fn main() -> Int { A }
EOF
set +e
r57_cyc_out=$("$PIONC" check --json "$TMP_DIR/r57_cyc/main.pion" 2>&1)
r57_cyc_rc=$?
set -e
test "$r57_cyc_rc" -ne 0
printf '%s' "$r57_cyc_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r57_cas/a.pion" <<'EOF'
let A : Int = go(read_b)
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string())
}
EOF
cat > "$TMP_DIR/r57_cas/b.pion" <<'EOF'
fn read_b(x : Int) -> Int { B + x }
fn make_b() -> Int { 0 }
fn go(f : (Int) -> Int) -> Int {
  let ignore = Some(f)
  ignore(7)
  match ignore { Some(g) => g(7) None => 0 }
}
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r57_cas" "$PIONC" build -o "$TMP_DIR/r57_cas_c" "$TMP_DIR/r57_cas/a.pion" "$TMP_DIR/r57_cas/b.pion"
test "$("$TMP_DIR/r57_cas_c")" = "7"
sed 's/fn make_b() -> Int { 0 }/fn make_b() -> Int { 2 }/' "$TMP_DIR/r57_cas/b.pion" > "$TMP_DIR/r57_cas/b2.pion" && mv "$TMP_DIR/r57_cas/b2.pion" "$TMP_DIR/r57_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r57_cas" "$PIONC" build -o "$TMP_DIR/r57_cas_h" "$TMP_DIR/r57_cas/a.pion" "$TMP_DIR/r57_cas/b.pion"
test "$("$TMP_DIR/r57_cas_h")" = "9"

echo "  R57 Some(f)+ignore(7) (ok dev/release/hot 0:1 -> 0:2, unpacked g(7) E_CONST_CYCLE + cold/hot CAS 7 -> 9) (OK)"

# 56c (R58): .Some(f) & Some(move f) positive (dev + --release + hot CAS 0:0:1 -> 0:0:2) + .Some(move f) unpacked & Some(f(7)) E_CONST_CYCLE
mkdir -p "$TMP_DIR/r58_ok" "$TMP_DIR/r58_cyc1" "$TMP_DIR/r58_cyc2"
cat > "$TMP_DIR/r58_ok/a.pion" <<'EOF'
let A : Int = go_dot(read_a)
let B : Int = go_mv(read_b)
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + B.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r58_ok/b.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn read_b(x : Int) -> Int { B + x }
fn go_dot(f : (Int) -> Int) -> Int { let ignore : Option[(Int) -> Int] = .Some(f); ignore(7); 0 }
fn go_mv(f : (Int) -> Int) -> Int { let ignore = Some(move f); ignore(7); 0 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r58_ok" "$PIONC" build -o "$TMP_DIR/r58_ok_c" "$TMP_DIR/r58_ok/a.pion" "$TMP_DIR/r58_ok/b.pion"
test "$("$TMP_DIR/r58_ok_c")" = "0:0:1"
PION_CACHE_DIR="$TMP_DIR/cas_r58_ok_rel" "$PIONC" build --release -o "$TMP_DIR/r58_ok_rel" "$TMP_DIR/r58_ok/a.pion" "$TMP_DIR/r58_ok/b.pion"
test "$("$TMP_DIR/r58_ok_rel")" = "0:0:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r58_ok/b.pion" > "$TMP_DIR/r58_ok/b2.pion" && mv "$TMP_DIR/r58_ok/b2.pion" "$TMP_DIR/r58_ok/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r58_ok" "$PIONC" build -o "$TMP_DIR/r58_ok_h" "$TMP_DIR/r58_ok/a.pion" "$TMP_DIR/r58_ok/b.pion"
test "$("$TMP_DIR/r58_ok_h")" = "0:0:2"

cat > "$TMP_DIR/r58_cyc1/main.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn go(f : (Int) -> Int) -> Int {
  let ignore : Option[(Int) -> Int] = .Some(move f)
  ignore(7)
  match ignore { Some(g) => g(7) None => 0 }
}
let A : Int = go(read_a)
pub fn main() -> Int { A }
EOF
set +e
r58_cyc1_out=$("$PIONC" check --json "$TMP_DIR/r58_cyc1/main.pion" 2>&1)
r58_cyc1_rc=$?
set -e
test "$r58_cyc1_rc" -ne 0
printf '%s' "$r58_cyc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r58_cyc2/main.pion" <<'EOF'
fn read_a(x : Int) -> Int { A + x }
fn go(f : (Int) -> Int) -> Int { let ignore = Some(f(7)); ignore(7); 0 }
let A : Int = go(read_a)
pub fn main() -> Int { A }
EOF
set +e
r58_cyc2_out=$("$PIONC" check --json "$TMP_DIR/r58_cyc2/main.pion" 2>&1)
r58_cyc2_rc=$?
set -e
test "$r58_cyc2_rc" -ne 0
printf '%s' "$r58_cyc2_out" | grep -q "E_CONST_CYCLE"

echo "  R58 .Some(f) & Some(move f) (ok dev/release/hot 0:0:1 -> 0:0:2, .Some(move f) unpacked & Some(f(7)) E_CONST_CYCLE) (OK)"

echo "=== Wave J1 E2E [57/57]: R59 Opus blockers (param_forward_ctor, alias_forward_ctor, const_opt_closure, param_ctor_nocall_clean) ==="
mkdir -p "$TMP_DIR/r59_pfc_cyc1" "$TMP_DIR/r59_pfc_cyc2" "$TMP_DIR/r59_pfc_cas" \
         "$TMP_DIR/r59_afc_cyc" "$TMP_DIR/r59_afc_cas" \
         "$TMP_DIR/r59_coc_cyc" "$TMP_DIR/r59_coc_cas" "$TMP_DIR/r59_coc_ok" \
         "$TMP_DIR/r59_nc_ok"

# 57a: param_forward_ctor (`Some(f)` & `let o = Some(f); o`) -> E_CONST_CYCLE + 2-file cold/hot CAS 7:7 -> 9:9
cat > "$TMP_DIR/r59_pfc_cyc1/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn wrap(f : () -> Int) -> Option[() -> Int] { Some(f) }
let A : Int = match wrap(read_a) { Some(g) => g() None => 0 }
pub fn main() -> Int { A }
EOF
set +e
r59_pfc1_out=$("$PIONC" check --json "$TMP_DIR/r59_pfc_cyc1/main.pion" 2>&1)
r59_pfc1_rc=$?
set -e
test "$r59_pfc1_rc" -ne 0
printf '%s' "$r59_pfc1_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r59_pfc_cyc2/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn wrap(f : () -> Int) -> Option[() -> Int] { let o = Some(f); o }
let A : Int = match wrap(read_a) { Some(g) => g() None => 0 }
pub fn main() -> Int { A }
EOF
set +e
r59_pfc2_out=$("$PIONC" check --json "$TMP_DIR/r59_pfc_cyc2/main.pion" 2>&1)
r59_pfc2_rc=$?
set -e
test "$r59_pfc2_rc" -ne 0
printf '%s' "$r59_pfc2_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r59_pfc_cas/a.pion" <<'EOF'
let A : Int = match wrap1(read_b) { Some(g) => g() None => 0 }
let C : Int = match wrap2(read_b) { Some(g) => g() None => 0 }
pub fn main(world : World) -> Unit { io_println(world, A.to_string() + ":" + C.to_string()) }
EOF
cat > "$TMP_DIR/r59_pfc_cas/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn wrap1(f : () -> Int) -> Option[() -> Int] { Some(f) }
fn wrap2(f : () -> Int) -> Option[() -> Int] { let o = Some(f); o }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r59_pfc" "$PIONC" build -o "$TMP_DIR/r59_pfc_c" "$TMP_DIR/r59_pfc_cas/a.pion" "$TMP_DIR/r59_pfc_cas/b.pion"
test "$("$TMP_DIR/r59_pfc_c")" = "7:7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r59_pfc_cas/b.pion" > "$TMP_DIR/r59_pfc_cas/b2.pion" && mv "$TMP_DIR/r59_pfc_cas/b2.pion" "$TMP_DIR/r59_pfc_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r59_pfc" "$PIONC" build -o "$TMP_DIR/r59_pfc_h" "$TMP_DIR/r59_pfc_cas/a.pion" "$TMP_DIR/r59_pfc_cas/b.pion"
test "$("$TMP_DIR/r59_pfc_h")" = "9:9"

# 57b: alias_forward_ctor (`let h = f; Some(h)`) -> E_CONST_CYCLE + 2-file cold/hot CAS 7 -> 9
cat > "$TMP_DIR/r59_afc_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
fn wrap(f : () -> Int) -> Option[() -> Int] { let h = f; Some(h) }
let A : Int = match wrap(read_a) { Some(g) => g() None => 0 }
pub fn main() -> Int { A }
EOF
set +e
r59_afc_out=$("$PIONC" check --json "$TMP_DIR/r59_afc_cyc/main.pion" 2>&1)
r59_afc_rc=$?
set -e
test "$r59_afc_rc" -ne 0
printf '%s' "$r59_afc_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r59_afc_cas/a.pion" <<'EOF'
let A : Int = match wrap(read_b) { Some(g) => g() None => 0 }
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r59_afc_cas/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
fn wrap(f : () -> Int) -> Option[() -> Int] { let h = f; Some(h) }
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r59_afc" "$PIONC" build -o "$TMP_DIR/r59_afc_c" "$TMP_DIR/r59_afc_cas/a.pion" "$TMP_DIR/r59_afc_cas/b.pion"
test "$("$TMP_DIR/r59_afc_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r59_afc_cas/b.pion" > "$TMP_DIR/r59_afc_cas/b2.pion" && mv "$TMP_DIR/r59_afc_cas/b2.pion" "$TMP_DIR/r59_afc_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r59_afc" "$PIONC" build -o "$TMP_DIR/r59_afc_h" "$TMP_DIR/r59_afc_cas/a.pion" "$TMP_DIR/r59_afc_cas/b.pion"
test "$("$TMP_DIR/r59_afc_h")" = "9"

# 57c: const_opt_closure (`let HC = Some(fn() { read_a() })`) -> E_CONST_CYCLE + 2-file cold/hot CAS 7 -> 9 + precision 0
cat > "$TMP_DIR/r59_coc_cyc/main.pion" <<'EOF'
fn read_a() -> Int { A }
let HC : Option[() -> Int] = Some(fn() -> Int { read_a() })
let A : Int = match HC { Some(f) => f() None => 0 }
pub fn main() -> Int { A }
EOF
set +e
r59_coc_out=$("$PIONC" check --json "$TMP_DIR/r59_coc_cyc/main.pion" 2>&1)
r59_coc_rc=$?
set -e
test "$r59_coc_rc" -ne 0
printf '%s' "$r59_coc_out" | grep -q "E_CONST_CYCLE"

cat > "$TMP_DIR/r59_coc_cas/a.pion" <<'EOF'
let A : Int = match HC { Some(f) => f() None => 0 }
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/r59_coc_cas/b.pion" <<'EOF'
fn read_b() -> Int { B }
fn make_b() -> Int { 7 }
let HC : Option[() -> Int] = Some(fn() -> Int { read_b() })
let B : Int = make_b()
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r59_coc" "$PIONC" build -o "$TMP_DIR/r59_coc_c" "$TMP_DIR/r59_coc_cas/a.pion" "$TMP_DIR/r59_coc_cas/b.pion"
test "$("$TMP_DIR/r59_coc_c")" = "7"
sed 's/fn make_b() -> Int { 7 }/fn make_b() -> Int { 9 }/' "$TMP_DIR/r59_coc_cas/b.pion" > "$TMP_DIR/r59_coc_cas/b2.pion" && mv "$TMP_DIR/r59_coc_cas/b2.pion" "$TMP_DIR/r59_coc_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r59_coc" "$PIONC" build -o "$TMP_DIR/r59_coc_h" "$TMP_DIR/r59_coc_cas/a.pion" "$TMP_DIR/r59_coc_cas/b.pion"
test "$("$TMP_DIR/r59_coc_h")" = "9"

cat > "$TMP_DIR/r59_coc_ok/main.pion" <<'EOF'
fn read_a() -> Int { A }
let HC : Option[() -> Int] = Some(fn() -> Int { read_a() })
let A : Int = match HC { Some(_) => 0 None => 0 }
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r59_coc_ok" "$PIONC" build -o "$TMP_DIR/r59_coc_ok_b" "$TMP_DIR/r59_coc_ok/main.pion"
test "$("$TMP_DIR/r59_coc_ok_b")" = "0"

# 57d: param_ctor_nocall_clean (`let _o = Some(f); 0`) -> zero false cycle, cold/hot CAS 0:1 -> 0:2
cat > "$TMP_DIR/r59_nc_ok/a.pion" <<'EOF'
let A : Int = g(read_a)
pub fn main(world : World) -> Unit { io_println(world, A.to_string() + ":" + pad().to_string()) }
EOF
cat > "$TMP_DIR/r59_nc_ok/b.pion" <<'EOF'
fn read_a() -> Int { A }
fn g(f : () -> Int) -> Int { let _o = Some(f); 0 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r59_nc" "$PIONC" build -o "$TMP_DIR/r59_nc_c" "$TMP_DIR/r59_nc_ok/a.pion" "$TMP_DIR/r59_nc_ok/b.pion"
test "$("$TMP_DIR/r59_nc_c")" = "0:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r59_nc_ok/b.pion" > "$TMP_DIR/r59_nc_ok/b2.pion" && mv "$TMP_DIR/r59_nc_ok/b2.pion" "$TMP_DIR/r59_nc_ok/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r59_nc" "$PIONC" build -o "$TMP_DIR/r59_nc_h" "$TMP_DIR/r59_nc_ok/a.pion" "$TMP_DIR/r59_nc_ok/b.pion"
test "$("$TMP_DIR/r59_nc_h")" = "0:2"

echo "  R59 Opus blockers (param_forward_ctor 7:7->9:9, alias_forward_ctor 7->9, const_opt_closure 7->9 & ok=0, param_ctor_nocall_clean 0:1->0:2) (OK)"

echo "=== Wave J1 E2E [58/58]: R61 package-level let Some shadowing builtin ctor (cold/hot CAS 16:1 -> 16:2 -> 18:2) ==="
mkdir -p "$TMP_DIR/r61_some"
cat > "$TMP_DIR/r61_some/a.pion" <<'EOF'
let Some : (Int) -> Int = read_b
let A : Int = Some(7)
let B : Int = make_b()
pub fn main(world : World) -> Unit {
  io_println(world, A.to_string() + ":" + pad().to_string())
}
EOF
cat > "$TMP_DIR/r61_some/b.pion" <<'EOF'
fn read_b(x : Int) -> Int { B + x }
fn make_b() -> Int { 9 }
fn pad() -> Int { 1 }
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r61_some" "$PIONC" build -o "$TMP_DIR/r61_some_c" "$TMP_DIR/r61_some/a.pion" "$TMP_DIR/r61_some/b.pion"
test "$("$TMP_DIR/r61_some_c")" = "16:1"
sed 's/fn pad() -> Int { 1 }/fn pad() -> Int { 2 }/' "$TMP_DIR/r61_some/b.pion" > "$TMP_DIR/r61_some/b2.pion" && mv "$TMP_DIR/r61_some/b2.pion" "$TMP_DIR/r61_some/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r61_some" "$PIONC" build -o "$TMP_DIR/r61_some_h1" "$TMP_DIR/r61_some/a.pion" "$TMP_DIR/r61_some/b.pion"
test "$("$TMP_DIR/r61_some_h1")" = "16:2"
sed 's/fn make_b() -> Int { 9 }/fn make_b() -> Int { 11 }/' "$TMP_DIR/r61_some/b.pion" > "$TMP_DIR/r61_some/b2.pion" && mv "$TMP_DIR/r61_some/b2.pion" "$TMP_DIR/r61_some/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_r61_some" "$PIONC" build -o "$TMP_DIR/r61_some_h2" "$TMP_DIR/r61_some/a.pion" "$TMP_DIR/r61_some/b.pion"
test "$("$TMP_DIR/r61_some_h2")" = "18:2"
echo "  R61 let Some shadowing builtin ctor (cold/hot CAS 16:1 -> 16:2 -> 18:2) (OK)"

echo "=== Wave J1 E2E [59/59]: R63 cross-pkg mono payload enum ctor resolves via mono_pkg alias, never caller g.tc.enums ==="
mkdir -p "$TMP_DIR/r63_mono/src" "$TMP_DIR/r63_mono/paint2/src" "$TMP_DIR/r63_mono/lg/src" "$TMP_DIR/r63_mono/app/src"
cat > "$TMP_DIR/r63_mono/pion.toml" <<'EOF'
[package]
name = "paint"
version = "0.1.0"

[workspace]
members = ["paint2", "lg", "app"]
EOF
cat > "$TMP_DIR/r63_mono/src/lib.pion" <<'EOF'
pub enum E {
  Miss(Int)
  Hit(Int)
}
pub fn root_tag(e : E) -> Int {
  match e {
    E::Miss(v) => v
    E::Hit(v) => v + 100
  }
}
EOF
cat > "$TMP_DIR/r63_mono/paint2/pion.toml" <<'EOF'
[package]
name = "paint2"
version = "0.1.0"
EOF
cat > "$TMP_DIR/r63_mono/paint2/src/lib.pion" <<'EOF'
pub enum E {
  Hit(Int)
  Miss(Int)
}
pub fn read_hit(e : E) -> Int {
  match e {
    E::Hit(v) => v
    E::Miss(v) => 0 - v
  }
}
EOF
cat > "$TMP_DIR/r63_mono/lg/pion.toml" <<'EOF'
[package]
name = "lg"
version = "0.1.0"

[dependencies]
paint = { package = "paint2", path = "../paint2" }
EOF
cat > "$TMP_DIR/r63_mono/lg/src/lib.pion" <<'EOF'
import "paint"
pub trait Tag {
  fn tag(self : Self) -> Int
}
pub fn make_hit[T : Tag](x : T) -> paint::E {
  paint::E::Hit(x.tag())
}
EOF
cat > "$TMP_DIR/r63_mono/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
rootp = { package = "paint", path = ".." }
paint2 = { path = "../paint2" }
lg = { path = "../lg" }
EOF
cat > "$TMP_DIR/r63_mono/app/src/main.pion" <<'EOF'
import "rootp"
import "paint2"
import "lg"

struct K { v : Int }
impl lg::Tag for K {
  fn tag(self : K) -> Int { self.v }
}

pub fn main(world : World) -> Unit {
  let _r = rootp::root_tag(rootp::E::Miss(1))
  let e = lg::make_hit(K::{ v: 7 })
  io_println(world, paint2::read_hit(e).to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_r63_dev" "$PIONC" build -o "$TMP_DIR/r63_dev" "$TMP_DIR/r63_mono/app"
test "$("$TMP_DIR/r63_dev")" = "7"
PION_CACHE_DIR="$TMP_DIR/cas_r63_rel" "$PIONC" build --release -o "$TMP_DIR/r63_rel" "$TMP_DIR/r63_mono/app"
test "$("$TMP_DIR/r63_rel")" = "7"
echo "  R63 cross-pkg mono payload enum ctor (dev==7, --release==7) (OK)"

echo "=== Wave J1 E2E [60/60]: P2 R5 cross-pkg 3-segment aliased EPath (paint::E::Hit) blocks LICM hoist ==="
mkdir -p "$TMP_DIR/p2_r5_alias/src" "$TMP_DIR/p2_r5_alias/paint2/src" "$TMP_DIR/p2_r5_alias/lg/src" "$TMP_DIR/p2_r5_alias/app/src"
cat > "$TMP_DIR/p2_r5_alias/pion.toml" <<'EOF'
[package]
name = "paint"
version = "0.1.0"

[workspace]
members = ["paint2", "lg", "app"]
EOF
cat > "$TMP_DIR/p2_r5_alias/src/lib.pion" <<'EOF'
pub enum E {
  Hit(Int)
}
pub fn root_tag(e : E) -> Int {
  match e {
    E::Hit(v) => v
  }
}
EOF
cat > "$TMP_DIR/p2_r5_alias/paint2/pion.toml" <<'EOF'
[package]
name = "paint2"
version = "0.1.0"
EOF
cat > "$TMP_DIR/p2_r5_alias/paint2/src/lib.pion" <<'EOF'
pub struct E {
  v : Int
}
pub fn E::Hit(a : Array[Int]) -> Byte {
  a.push(33)
  b'!'
}
EOF
cat > "$TMP_DIR/p2_r5_alias/lg/pion.toml" <<'EOF'
[package]
name = "lg"
version = "0.1.0"

[dependencies]
paint = { package = "paint2", path = "../paint2" }
EOF
cat > "$TMP_DIR/p2_r5_alias/lg/src/lib.pion" <<'EOF'
import "paint"
pub trait Tag {
  fn tag(self : Self) -> Int
}
pub fn run_hit[T : Tag](arr : Array[Int], alias : Array[Int], x : T) -> Int {
  let sb = StringBuilder::new()
  let mut i = 0
  let mut sum = 0
  while i < 40 {
    sum = sum + arr[i]
    sb.write_byte(paint::E::Hit(alias))
    i = i + 1
  }
  if sb.length() != 40 {
    return -1
  }
  sum + x.tag() * 0
}
EOF
cat > "$TMP_DIR/p2_r5_alias/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
rootp = { package = "paint", path = ".." }
paint2 = { path = "../paint2" }
lg = { path = "../lg" }
EOF
cat > "$TMP_DIR/p2_r5_alias/app/src/main.pion" <<'EOF'
import "rootp"
import "paint2"
import "lg"

struct K { v : Int }
impl lg::Tag for K {
  fn tag(self : K) -> Int { self.v }
}

pub fn main(world : World) -> Unit {
  let _r = rootp::root_tag(rootp::E::Hit(1))
  let a : Array[Int] = [5, 6, 7, 8]
  let sum = lg::run_hit(a, a, K::{ v: 1 })
  io_println(world, sum.to_string() + ":" + a.length().to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_p2_r5_dev" "$PIONC" build -o "$TMP_DIR/p2_r5_dev" "$TMP_DIR/p2_r5_alias/app"
test "$("$TMP_DIR/p2_r5_dev")" = "1214:44"
PION_CACHE_DIR="$TMP_DIR/cas_p2_r5_rel" "$PIONC" build --release -o "$TMP_DIR/p2_r5_rel" "$TMP_DIR/p2_r5_alias/app"
test "$("$TMP_DIR/p2_r5_rel")" = "1214:44"
# SSA assertion: monomorphized lg::run_hit MUST reload arr data ptr (+ 24) inside the loop body, never hoisted to preheader
P2_R5_SSA=$(find "$TMP_DIR/cas_p2_r5_rel" -name '*.ssa' -exec grep -l 'run_hit' {} + | head -n 1)
test -n "$P2_R5_SSA"
awk '/function w \$[^ ]*run_hit/,/^}/' "$P2_R5_SSA" > "$TMP_DIR/p2_r5_mono.ssa"
test -s "$TMP_DIR/p2_r5_mono.ssa"
awk '
  /^@wh_b_|^@wh_c_/ { in_loop = 1 }
  !in_loop && /, 24$/ { pre_hoist = 1 }
  in_loop && /, 24$/ { body_reload = 1 }
  END {
    if (pre_hoist) { print "FAIL: arr +24 hoisted to preheader"; exit 1 }
    if (!body_reload) { print "FAIL: arr +24 not reloaded in loop"; exit 1 }
  }
' "$TMP_DIR/p2_r5_mono.ssa"
echo "  P2 R5 3-segment aliased EPath paint::E::Hit (dev==1214:44, --release==1214:44, SSA no-hoist) (OK)"

echo "PASS: wave_j1_soundness"
