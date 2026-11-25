#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== Wave L1-A E2E [1/6]: A1 Constant patterns (SkippingIterator, dual consts, literals, cold/hot CAS 7->9, 3-pkg mono) ==="
cat > "$TMP_DIR/a1_exec.pion" <<'EOF'
enum Mode { A; B; C; D }
let MATCH : Int = 7
let MATCH2 : Int = 7
let OTHER : Int = 9
let S_TAG : String = "go"
let SV_TAG : StrView = "go".as_view()
let DEF_MODE : Mode = Mode::B
let B_TAG : Byte = b'k'

struct SkippingIter {
  data : Array[Int]
  mut idx : Int
}

fn SkippingIter::next(self : SkippingIter) -> Option[Int] {
  while self.idx < self.data.length() {
    let cur = self.data[self.idx]
    self.idx = self.idx + 1
    match cur {
      MATCH => continue
      _ => return Some(cur)
    }
  }
  None
}

fn dual_first(x : Int) -> Int {
  match x {
    MATCH => 10
    MATCH2 => 20
    7 => 30
    OTHER => 40
    _ => 50
  }
}

fn check_str(s : String, sv : StrView, m : Mode, b : Byte) -> Int {
  let r1 = match s { S_TAG => 1; _ => 0 }
  let r2 = match sv { SV_TAG => 2; _ => 0 }
  let r3 = match m { DEF_MODE => 4; Mode::A => 8; _ => 0 }
  let r4 = match b { B_TAG => 16; _ => 0 }
  r1 + r2 + r3 + r4
}

pub fn main(world : World) -> Unit {
  let it = SkippingIter::{ data: [7, 1, 7, 2, 7, 3], idx: 0 }
  let mut sum = 0
  while true {
    match it.next() {
      Some(v) => sum = sum * 10 + v
      None => break
    }
  }
  let d = dual_first(7) * 100 + dual_first(9)
  let s = check_str("go", "go".as_view(), Mode::B, b'k')
  io_println(world, "a1=" + sum.to_string() + ":" + d.to_string() + ":" + s.to_string())
}
EOF
"$PIONC" build -o "$TMP_DIR/a1_dev" "$TMP_DIR/a1_exec.pion"
"$PIONC" build --release -o "$TMP_DIR/a1_rel" "$TMP_DIR/a1_exec.pion"
A1_DEV="$("$TMP_DIR/a1_dev")"
A1_REL="$("$TMP_DIR/a1_rel")"
echo "  a1_exec dev=$A1_DEV rel=$A1_REL"
[ "$A1_DEV" = "a1=123:1040:23" ]
[ "$A1_REL" = "a1=123:1040:23" ]

# 2-file cross-file function match const cold/hot CAS 7 -> 9
mkdir -p "$TMP_DIR/a1_cas"
cat > "$TMP_DIR/a1_cas/a.pion" <<'EOF'
let RES : Int = check_val(9)
pub fn main(world : World) -> Unit { io_println(world, RES.to_string()) }
EOF
cat > "$TMP_DIR/a1_cas/b.pion" <<'EOF'
fn make_target() -> Int { 7 }
let TARGET : Int = make_target()
fn check_val(x : Int) -> Int {
  match x {
    TARGET => 100
    _ => 200
  }
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_a1_2f" "$PIONC" build -o "$TMP_DIR/a1_2f_c" "$TMP_DIR/a1_cas/a.pion" "$TMP_DIR/a1_cas/b.pion"
[ "$("$TMP_DIR/a1_2f_c")" = "200" ]
sed 's/fn make_target() -> Int { 7 }/fn make_target() -> Int { 9 }/' "$TMP_DIR/a1_cas/b.pion" > "$TMP_DIR/a1_cas/b2.pion" && mv "$TMP_DIR/a1_cas/b2.pion" "$TMP_DIR/a1_cas/b.pion"
PION_CACHE_DIR="$TMP_DIR/cas_a1_2f" "$PIONC" build -o "$TMP_DIR/a1_2f_h" "$TMP_DIR/a1_cas/a.pion" "$TMP_DIR/a1_cas/b.pion"
[ "$("$TMP_DIR/a1_2f_h")" = "100" ]

# 3-pkg cross-pkg instantiation: dep uses tools::MATCH, app has decoy MATCH
mkdir -p "$TMP_DIR/a1_3pkg/tools/src" "$TMP_DIR/a1_3pkg/dep/src" "$TMP_DIR/a1_3pkg/app/src"
cat > "$TMP_DIR/a1_3pkg/tools/pion.toml" <<'EOF'
[package]
name = "tools"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a1_3pkg/tools/src/tools.pion" <<'EOF'
pub let MATCH : Int = 77
EOF
cat > "$TMP_DIR/a1_3pkg/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
[dependencies]
tools = { path = "../tools" }
EOF
cat > "$TMP_DIR/a1_3pkg/dep/src/dep.pion" <<'EOF'
import "tools"
pub trait Key {
  key(self : Self) -> Int
}
pub fn is_match[T : Key](x : T) -> Int {
  match x.key() {
    tools::MATCH => 1
    _ => 0
  }
}
EOF
cat > "$TMP_DIR/a1_3pkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/a1_3pkg/app/src/main.pion" <<'EOF'
import "dep"
let MATCH : Int = 99
struct Boxed { k : Int }
impl dep::Key for Boxed {
  fn key(self : Boxed) -> Int { self.k }
}
pub fn main(world : World) -> Unit {
  let a = dep::is_match(Boxed::{ k: 77 })
  let b = dep::is_match(Boxed::{ k: 99 })
  let c = match 99 { MATCH => 1; _ => 0 }
  io_println(world, "xpkg=" + a.to_string() + ":" + b.to_string() + ":" + c.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_a1_3pkg" "$PIONC" build -o "$TMP_DIR/a1_3pkg_dev" "$TMP_DIR/a1_3pkg/app"
PION_CACHE_DIR="$TMP_DIR/cas_a1_3pkg" "$PIONC" build --release -o "$TMP_DIR/a1_3pkg_rel" "$TMP_DIR/a1_3pkg/app"
[ "$("$TMP_DIR/a1_3pkg_dev")" = "xpkg=1:0:1" ]
[ "$("$TMP_DIR/a1_3pkg_rel")" = "xpkg=1:0:1" ]
# Hot rebuild
PION_CACHE_DIR="$TMP_DIR/cas_a1_3pkg" "$PIONC" build -o "$TMP_DIR/a1_3pkg_hot" "$TMP_DIR/a1_3pkg/app"
[ "$("$TMP_DIR/a1_3pkg_hot")" = "xpkg=1:0:1" ]

# 1d: Non-generic, no-default-arg `dep` small fn --release inline + .pionstub hot build (private scalar const + pub unit enum const)
mkdir -p "$TMP_DIR/a1_xinline/dep/src" "$TMP_DIR/a1_xinline/app/src"
cat > "$TMP_DIR/a1_xinline/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a1_xinline/dep/src/dep.pion" <<'EOF'
let SECRET : Int = 77
fn make7() -> Int { 7 }
let Some : Int = make7()
pub enum C { A; B }
pub let DEF_C : C = C::B
pub fn is_secret(x : Int) -> Int {
  match x {
    SECRET => 1
    _ => 0
  }
}
pub fn hit_some(x : Int) -> Int {
  match x {
    Some => 1
    _ => 0
  }
}
pub fn is_def(c : C) -> Int {
  match c {
    DEF_C => 1
    _ => 0
  }
}
EOF
cat > "$TMP_DIR/a1_xinline/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/a1_xinline/app/src/main.pion" <<'EOF'
import "dep"
let SECRET : Int = 99
let DEF_C : dep::C = dep::C::A
pub fn main(world : World) -> Unit {
  let r1 = dep::is_secret(77)
  let r2 = dep::is_secret(99)
  let r3 = dep::is_def(dep::C::B)
  let r4 = dep::is_def(dep::C::A)
  let r5 = match 99 { SECRET => 1; _ => 0 }
  let r6 = match dep::C::A { DEF_C => 1; _ => 0 }
  let r7 = dep::hit_some(7)
  let r8 = dep::hit_some(9)
  io_println(
    world,
    "xinline=" + r1.to_string() + ":" + r2.to_string() + ":" + r3.to_string() + ":" +
    r4.to_string() + ":" + r5.to_string() + ":" + r6.to_string() + ":" +
    r7.to_string() + ":" + r8.to_string(),
  )
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_a1_xinline" "$PIONC" build -o "$TMP_DIR/a1_xinline_dev" "$TMP_DIR/a1_xinline/app"
[ "$("$TMP_DIR/a1_xinline_dev")" = "xinline=1:0:1:0:1:1:1:0" ]
PION_CACHE_DIR="$TMP_DIR/cas_a1_xinline" "$PIONC" build --release -o "$TMP_DIR/a1_xinline_rel_cold" "$TMP_DIR/a1_xinline/app"
[ "$("$TMP_DIR/a1_xinline_rel_cold")" = "xinline=1:0:1:0:1:1:1:0" ]
PION_CACHE_DIR="$TMP_DIR/cas_a1_xinline" "$PIONC" build --release -o "$TMP_DIR/a1_xinline_rel_hot" "$TMP_DIR/a1_xinline/app"
[ "$("$TMP_DIR/a1_xinline_rel_hot")" = "xinline=1:0:1:0:1:1:1:0" ]

# 1e: Cross-pkg private default-arg constant pattern + caller decoy
mkdir -p "$TMP_DIR/a1_xdef/dep/src" "$TMP_DIR/a1_xdef/app/src"
cat > "$TMP_DIR/a1_xdef/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a1_xdef/dep/src/dep.pion" <<'EOF'
let DEF_TAG : Int = 42
pub fn with_def(x~ : Int = match 42 { DEF_TAG => 1; _ => 0 }) -> Int { x }
EOF
cat > "$TMP_DIR/a1_xdef/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/a1_xdef/app/src/main.pion" <<'EOF'
import "dep"
let DEF_TAG : Int = 99
pub fn main(world : World) -> Unit {
  let r1 = dep::with_def()
  let r2 = match 99 { DEF_TAG => 1; _ => 0 }
  io_println(world, "xdef=" + r1.to_string() + ":" + r2.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_a1_xdef" "$PIONC" build -o "$TMP_DIR/a1_xdef_dev_cold" "$TMP_DIR/a1_xdef/app"
[ "$("$TMP_DIR/a1_xdef_dev_cold")" = "xdef=1:1" ]
PION_CACHE_DIR="$TMP_DIR/cas_a1_xdef" "$PIONC" build --release -o "$TMP_DIR/a1_xdef_rel_cold" "$TMP_DIR/a1_xdef/app"
[ "$("$TMP_DIR/a1_xdef_rel_cold")" = "xdef=1:1" ]
PION_CACHE_DIR="$TMP_DIR/cas_a1_xdef" "$PIONC" build -o "$TMP_DIR/a1_xdef_dev_hot" "$TMP_DIR/a1_xdef/app"
[ "$("$TMP_DIR/a1_xdef_dev_hot")" = "xdef=1:1" ]
PION_CACHE_DIR="$TMP_DIR/cas_a1_xdef" "$PIONC" build --release -o "$TMP_DIR/a1_xdef_rel_hot" "$TMP_DIR/a1_xdef/app"
[ "$("$TMP_DIR/a1_xdef_rel_hot")" = "xdef=1:1" ]

# 1f: Lean extraction with shadowed import alias (`import "paint" as rootp`, `import "decoy" as paint`)
mkdir -p "$TMP_DIR/a1_lean/paint/src" "$TMP_DIR/a1_lean/decoy/src" "$TMP_DIR/a1_lean/app/src"
cat > "$TMP_DIR/a1_lean/paint/pion.toml" <<'EOF'
[package]
name = "paint"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a1_lean/paint/src/lib.pion" <<'EOF'
pub let MATCH : Int = 7
EOF
cat > "$TMP_DIR/a1_lean/decoy/pion.toml" <<'EOF'
[package]
name = "decoy"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a1_lean/decoy/src/lib.pion" <<'EOF'
pub let MATCH : Int = 9
EOF
cat > "$TMP_DIR/a1_lean/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
paint = { path = "../paint" }
decoy = { path = "../decoy" }
EOF
cat > "$TMP_DIR/a1_lean/app/src/main.pion" <<'EOF'
import "paint" as rootp
import "decoy" as paint
#verify
pub fn hit_paint(x : Int) -> Bool {
  match x {
    rootp::MATCH => true
    _ => false
  }
}
pub fn main(world : World) -> Unit {
  let a = if hit_paint(7) { 1 } else { 0 }
  let b = if hit_paint(9) { 1 } else { 0 }
  io_println(world, "a1lean=" + a.to_string() + ":" + b.to_string())
}
EOF
"$PIONC" extract-lean --json --out "$TMP_DIR/a1_lean_out" "$TMP_DIR/a1_lean/app" | grep -q '"ok":true'
python3 -c '
import glob, sys
files = glob.glob(sys.argv[1] + "/**/*.lean", recursive=True)
assert files, "no lean files generated"
text = "\n".join(open(f).read() for f in files)
assert "paint" in text and "7" in text, f"expected paint/7 in Lean:\n{text}"
assert "decoy" not in text, f"alias-shadowed decoy leaked into Lean:\n{text}"
' "$TMP_DIR/a1_lean_out"
echo "  [PASS] A1"

echo "=== Wave L1-A E2E [2/6]: A2 Unified EIs scoping + ASan/LSan 0-leak ==="
cat > "$TMP_DIR/a2_exec.pion" <<'EOF'
struct Gate {
  set : Bool
  label : String
}

fn mk_label(s : String) -> String {
  let sb = StringBuilder::new()
  sb.write_string(s)
  sb.write_string("_heap")
  sb.to_string()
}

fn check_neg(g : Option[Gate]) -> Int {
  if !(g is Some(g) && g.set) {
    match g {
      Some(outer) => outer.label.length()
      None => 0
    }
  } else {
    100
  }
}

fn check_or_and(flag : Bool, p : Option[Gate]) -> Int {
  if flag || (p is Some(x) && x.set) { 1 } else { 0 }
}

fn check_val_and(p : Option[Gate]) -> Int {
  let b = (p is Some(x) && x.set)
  if b { 1 } else { 0 }
}

fn check_guard_and_closure(a : Option[String], b : Option[Gate]) -> Int {
  match a {
    Some(s) if b is Some(g) && g.set => {
      let f = fn() -> Int { s.length() + g.label.length() }
      f()
    }
    _ => -1
  }
}

fn check_early_return(p : Option[Gate]) -> Int {
  let _ = !(p is Some(g) && {
    if g.set { return g.label.length() }
    false
  })
  99
}

fn check_early_break(p : Option[Gate]) -> Int {
  let mut out = 0
  let mut i = 0
  while i < 3 {
    i = i + 1
    let _ = !(p is Some(g) && {
      if g.set {
        out = g.label.length()
        break
      }
      false
    })
  }
  out
}

fn check_try(p : Option[Gate], r : Result[Int, String]) -> Result[Int, String] {
  let ok = !(p is Some(g) && {
    let v = r?
    v > 0 && g.set
  })
  if ok { Ok(1) } else { Ok(2) }
}

pub fn main(world : World) -> Unit {
  let g_t = Some(Gate::{ set: true, label: mk_label("yes") })
  let g_f = Some(Gate::{ set: false, label: mk_label("no") })
  let g_n : Option[Gate] = None
  let r1 = check_neg(g_t) + check_neg(g_f) + check_neg(g_n)
  let r2 = check_or_and(false, g_t) * 10 + check_or_and(false, g_f) + check_or_and(true, g_n) * 100
  let r3 = check_val_and(g_t) * 10 + check_val_and(g_f) + check_val_and(g_n)
  let r4 = check_guard_and_closure(Some(mk_label("hi")), g_t) + check_guard_and_closure(Some(mk_label("hi")), g_f)
  let r5 = check_early_return(g_t) * 100 + check_early_return(g_f)
  let r6 = check_early_break(g_t)
  let r7 = match check_try(g_t, Err(mk_label("e"))) { Err(e) => e.length(); Ok(v) => v }
  let r8 = match check_try(g_t, Ok(5)) { Err(_) => -1; Ok(v) => v }
  io_println(
    world,
    "a2=" + r1.to_string() + ":" + r2.to_string() + ":" + r3.to_string() + ":" +
    r4.to_string() + ":" + r5.to_string() + ":" + r6.to_string() + ":" +
    r7.to_string() + ":" + r8.to_string(),
  )
}
EOF
"$PIONC" build -o "$TMP_DIR/a2_dev" "$TMP_DIR/a2_exec.pion"
"$PIONC" build --release -o "$TMP_DIR/a2_rel" "$TMP_DIR/a2_exec.pion"
A2_DEV="$("$TMP_DIR/a2_dev")"
A2_REL="$("$TMP_DIR/a2_rel")"
echo "  a2_exec dev=$A2_DEV rel=$A2_REL"
[ "$A2_DEV" = "a2=107:110:10:14:899:8:6:2" ]
[ "$A2_REL" = "a2=107:110:10:14:899:8:6:2" ]

# ASan/LSan 0-leak run
CC_BIN="${CC:-cc}"
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/a2_exec.o" "$TMP_DIR/a2_exec.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/a2_exec.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/a2_asan"
  A2_ASAN="$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/a2_asan")"
  echo "  a2_exec ASan ($UNAME_S) -> $A2_ASAN"
  [ "$A2_ASAN" = "a2=107:110:10:14:899:8:6:2" ]
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: ASan required by PION_REQUIRE_SANITIZERS=1" >&2
  exit 1
fi

# 2b: Cross-pkg default-arg EIs inside match guard & && must NOT be hijacked by dep's top-level `let x`
mkdir -p "$TMP_DIR/a2_xdef/dep/src" "$TMP_DIR/a2_xdef/app/src"
cat > "$TMP_DIR/a2_xdef/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a2_xdef/dep/src/lib.pion" <<'EOF'
let x : Int = 99
pub fn pick(
  p : Option[Int],
  n~ : Int = match 0 { _ if p is Some(x) => x; _ => 0 },
  b~ : Bool = (p is Some(x) && x == 7),
) -> Int {
  if b { n * 10 + 1 } else { n * 10 }
}
EOF
cat > "$TMP_DIR/a2_xdef/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/a2_xdef/app/src/main.pion" <<'EOF'
import "dep"
pub fn main(world : World) -> Unit {
  let r1 = dep::pick(Some(7))
  let r2 = dep::pick(Some(5))
  let r3 = dep::pick(None)
  io_println(world, "a2xdef=" + r1.to_string() + ":" + r2.to_string() + ":" + r3.to_string())
}
EOF
PION_CACHE_DIR="$TMP_DIR/cas_a2_xdef" "$PIONC" build -o "$TMP_DIR/a2_xdef_dev" "$TMP_DIR/a2_xdef/app"
PION_CACHE_DIR="$TMP_DIR/cas_a2_xdef" "$PIONC" build --release -o "$TMP_DIR/a2_xdef_rel_cold" "$TMP_DIR/a2_xdef/app"
PION_CACHE_DIR="$TMP_DIR/cas_a2_xdef" "$PIONC" build --release -o "$TMP_DIR/a2_xdef_rel_hot" "$TMP_DIR/a2_xdef/app"
[ "$("$TMP_DIR/a2_xdef_dev")" = "a2xdef=71:50:0" ]
[ "$("$TMP_DIR/a2_xdef_rel_cold")" = "a2xdef=71:50:0" ]
[ "$("$TMP_DIR/a2_xdef_rel_hot")" = "a2xdef=71:50:0" ]

# 2c: #verify + extract-lean for match guard `is` and standalone `p is Some(x) && x == 7` with shadowed outer `x`
mkdir -p "$TMP_DIR/a2_lean/src"
cat > "$TMP_DIR/a2_lean/pion.toml" <<'EOF'
[package]
name = "a2_lean"
version = "0.1.0"
EOF
cat > "$TMP_DIR/a2_lean/src/main.pion" <<'EOF'
#verify
pub fn pick_v(p : Option[Int], x : Int) -> Int {
  match 0 {
    _ if p is Some(x) => x
    _ => 0
  }
}
#verify
pub fn and_v(p : Option[Int], x : Int) -> Bool {
  p is Some(x) && x == 7
}
pub fn main(world : World) -> Unit {
  let a = pick_v(Some(7), 99)
  let b = if and_v(Some(7), 99) { 1 } else { 0 }
  let c = if and_v(Some(5), 7) { 1 } else { 0 }
  io_println(world, "a2lean=" + a.to_string() + ":" + b.to_string() + ":" + c.to_string())
}
EOF
"$PIONC" build -o "$TMP_DIR/a2_lean_bin" "$TMP_DIR/a2_lean"
[ "$("$TMP_DIR/a2_lean_bin")" = "a2lean=7:1:0" ]
"$PIONC" extract-lean --json --out "$TMP_DIR/a2_lean_out" "$TMP_DIR/a2_lean" | grep -q '"ok":true'
python3 -c '
import glob, re, sys
files = glob.glob(sys.argv[1] + "/**/*.lean", recursive=True)
assert files, "no lean files generated"
text = "\n".join(open(f).read() for f in files)
# In pick_v, the `some <bound>` arm must return `<bound>` (distinct from outer param `x`)
m_pick = re.search(r"def pick_v.*?def and_v", text, re.S)
assert m_pick, f"pick_v not found in Lean:\n{text}"
pick_body = m_pick.group(0)
m_pick_arm = re.search(r"\|\s*(?:Option\.|\.)?some\s+([A-Za-z0-9_]+)\s*=>\s*(.*)", pick_body, re.S)
assert m_pick_arm, f"pick_v missing .some arm in Lean:\n{pick_body}"
bound_pick = m_pick_arm.group(1)
arm_rhs = re.split(r"\|\s*(?:_|(?:Option\.|\.)?none)\b", m_pick_arm.group(2), maxsplit=1)[0]
assert bound_pick != "x", f"pick_v bound var should shadow outer x, got {bound_pick}:\n{pick_body}"
assert re.search(r"\b" + re.escape(bound_pick) + r"\b", arm_rhs), f"pick_v some arm must use bound var {bound_pick}, got:\n{arm_rhs}"
assert not re.search(r"\bx\b", arm_rhs), f"pick_v some arm leaked outer param x:\n{arm_rhs}"
# In and_v, the `some <bound>` arm must compare `<bound> == 7` (not outer param `x`)
m_and = re.search(r"def and_v.*", text, re.S)
assert m_and, f"and_v not found in Lean:\n{text}"
and_body = m_and.group(0)
m_and_arm = re.search(r"\|\s*(?:Option\.|\.)?some\s+([A-Za-z0-9_]+)\s*=>\s*(.*)", and_body, re.S)
assert m_and_arm, f"and_v missing .some arm in Lean:\n{and_body}"
bound_and = m_and_arm.group(1)
and_rhs = re.split(r"\|\s*(?:_|(?:Option\.|\.)?none)\b", m_and_arm.group(2), maxsplit=1)[0]
assert bound_and != "x", f"and_v bound var should shadow outer x, got {bound_and}:\n{and_body}"
assert re.search(r"\b" + re.escape(bound_and) + r"\b", and_rhs), f"and_v some arm must use bound var {bound_and}, got:\n{and_rhs}"
assert not re.search(r"\bx\b", and_rhs), f"and_v some arm leaked outer param x:\n{and_rhs}"
' "$TMP_DIR/a2_lean_out"
echo "  [PASS] A2"

echo "=== Wave L1-A E2E [3/6]: A3 Two-pass closure inference & fail-closed ==="
cat > "$TMP_DIR/a3_ok.pion" <<'EOF'
fn fold[T, U](xs : Array[T], init : U, f : (U, T) -> U) -> U {
  let mut acc = init
  for x in xs { acc = f(acc, x) }
  acc
}
fn apply[T, U](f : (T) -> U, x : T) -> U { f(x) }
fn apply_opt[T](f? : (T) -> Int, v : T) -> Int {
  match f {
    Some(cb) => cb(v)
    None => 0
  }
}
fn f_move[T](g : (Int) -> Int, s : T) -> Int { let _ = s; g(1) }
fn fg_move[T](g : (T) -> Int, s : T) -> Int { g(s) }
fn f_h3[T](g : (T) -> Int, x : T, a : Array[Int]) -> Int { g(x) + a.length() }
fn take_named[T](n~ : Int, s~ : String, v~ : T, f~ : (T) -> Int) -> Int { n + s.length() + f(v) }
pub fn main(world : World) -> Unit {
  let a = fold([1, 2, 3, 4], 0, fn(acc, x) { acc + x })
  let b = apply(fn(x) { x + 1 }, 3)
  let c = apply_opt(3, f=fn(x) { x + 1 })
  let v1 = [1, 2, 3]
  let d = f_move(fn(x) { x + v1.length() }, move v1)
  let v2 = [1, 2, 3]
  let e = fg_move(fn(x) { let _ = x; v2.length() }, move v2)
  let v3 = [1, 2, 3]
  let h3 = f_h3(fn(x) { v3.length() + x }, 1, v3)
  let s1 = "abc"
  let t1 = take_named(n=s1.length(), s=move s1, v=1, f=fn(i) { i })
  let mut s2 = "old"
  let _ = move s2
  let _ = apply(fn(x) { x + 1 }, { s2 = "new"; 1 })
  let r2 = s2.length()
  io_println(
    world,
    "a3=" + a.to_string() + ":" + b.to_string() + ":" + c.to_string() + ":" +
    d.to_string() + ":" + e.to_string() + ":" + h3.to_string() + ":" +
    t1.to_string() + ":" + r2.to_string(),
  )
}
EOF
"$PIONC" build -o "$TMP_DIR/a3_bin" "$TMP_DIR/a3_ok.pion"
[ "$("$TMP_DIR/a3_bin")" = "a3=10:4:4:4:3:7:7:3" ]
cat > "$TMP_DIR/a3_bad.pion" <<'EOF'
pub fn main() -> Int { let g = fn(x) { x + 7 }; g(1) }
EOF
set +e; A3_BAD="$("$PIONC" check --json "$TMP_DIR/a3_bad.pion" 2>&1)"; A3_RC=$?; set -e
[ "$A3_RC" -ne 0 ]
printf '%s' "$A3_BAD" | grep -q "E_TYPE_MISMATCH"
echo "  [PASS] A3"

echo "=== Wave L1-A E2E [4/6]: A4 Builtin ::new / ::with_capacity ==="
cat > "$TMP_DIR/a4_bad.pion" <<'EOF'
pub fn main() -> Unit {
  let _ = StringBuilder::new(1)
  let _ = AtomicInt::new()
}
EOF
set +e; A4_BAD="$("$PIONC" check --json "$TMP_DIR/a4_bad.pion" 2>&1)"; A4_RC=$?; set -e
[ "$A4_RC" -ne 0 ]
printf '%s' "$A4_BAD" | grep -q "E_ARITY_MISMATCH"
echo "  [PASS] A4"

echo "=== Wave L1-A E2E [5/6]: A5 pionc test --json single valid JSON on all error paths ==="
check_single_json() {
  LABEL="$1"
  OUT="$2"
  EXPECT_OK="$3"
  python3 -c '
import json, sys
raw = sys.argv[1]
expect_ok = sys.argv[2] == "true"
obj = json.loads(raw)
assert isinstance(obj, dict), f"not dict: {raw}"
assert obj.get("ok") is expect_ok, f"ok mismatch ({expect_ok}): {raw}"
if not expect_ok:
    assert ("error" in obj) or ("diagnostics" in obj) or ("tests" in obj), f"no error/diagnostics/tests: {raw}"
' "$OUT" "$EXPECT_OK" || { echo "FAIL [$LABEL]: invalid JSON stdout: $OUT" >&2; exit 1; }
}

# 5a: passing single file
cat > "$TMP_DIR/t_pass.pion" <<'EOF'
test "ok" { debug_assert(1 + 1 == 2, "math") }
EOF
OUT="$("$PIONC" test --json "$TMP_DIR/t_pass.pion")"
check_single_json "pass" "$OUT" "true"

# 5b: failing test assertion
cat > "$TMP_DIR/t_fail.pion" <<'EOF'
test "boom" { debug_assert(1 == 2, "nope") }
EOF
set +e; OUT="$("$PIONC" test --json "$TMP_DIR/t_fail.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "assert_fail" "$OUT" "false"
printf '%s' "$OUT" | grep -q '"tests":'

# 5c: arg error (mutually exclusive & unknown flag & missing --filter value)
set +e; OUT="$("$PIONC" test --json --deps --no-deps "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "arg_mutex" "$OUT" "false"
set +e; OUT="$("$PIONC" test --bogus-flag --json "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "arg_unknown" "$OUT" "false"
set +e; OUT="$("$PIONC" test --json --filter)"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "arg_missing_filter" "$OUT" "false"

# 5d: nonexistent --package in workspace
mkdir -p "$TMP_DIR/ws_ok/src"
cat > "$TMP_DIR/ws_ok/pion.toml" <<'EOF'
[package]
name = "ws_ok"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws_ok/src/lib.pion" <<'EOF'
test "t1" { debug_assert(true, "ok") }
EOF
set +e; OUT="$("$PIONC" test --json -p no_such_pkg "$TMP_DIR/ws_ok")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "missing_pkg" "$OUT" "false"

# 5e: broken manifest
mkdir -p "$TMP_DIR/ws_bad_mf"
printf '[package\nbroken' > "$TMP_DIR/ws_bad_mf/pion.toml"
set +e; OUT="$("$PIONC" test --json "$TMP_DIR/ws_bad_mf")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "bad_manifest" "$OUT" "false"

# 5f: multi-manifest where 1st passes and 2nd fails (must NOT mix partial test JSON + error JSON!)
set +e; OUT="$("$PIONC" test --json "$TMP_DIR/ws_ok" "$TMP_DIR/ws_bad_mf")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "multi_manifest_partial_fail" "$OUT" "false"

# 5g: link error (nonexistent -l library)
set +e; OUT="$("$PIONC" test --json -l definitely_nonexistent_lib_xyz_999 "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "link_fail" "$OUT" "false"

# 5h: child test stdout pollution (Pion + C puts/fflush) in --json mode (cold + cached)
mkdir -p "$TMP_DIR/ws_noisy/src" "$TMP_DIR/ws_noisy/csrc"
cat > "$TMP_DIR/ws_noisy/csrc/noisy.c" <<'EOF'
#include <stdio.h>
void pion_noisy_puts(void) {
  puts("child_c_stdout_noise");
  fflush(stdout);
}
EOF
cat > "$TMP_DIR/ws_noisy/pion.toml" <<'EOF'
[package]
name = "ws_noisy"
version = "0.1.0"

[link]
c_sources = ["csrc/noisy.c"]
EOF
cat > "$TMP_DIR/ws_noisy/src/lib.pion" <<'EOF'
extern "C" fn pion_noisy_puts() -> Unit
test "noisy_fail" {
  pion_noisy_puts()
  debug_assert(false, "noisy_boom")
}
EOF
set +e; OUT="$("$PIONC" test --json "$TMP_DIR/ws_noisy")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "noisy_child_cold" "$OUT" "false"
set +e; OUT="$("$PIONC" test --json "$TMP_DIR/ws_noisy")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "noisy_child_cached" "$OUT" "false"

# 5i: invalid --jobs values (0, -1, abc, missing)
set +e; OUT="$("$PIONC" test --json --jobs 0 "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "jobs_zero" "$OUT" "false"
set +e; OUT="$("$PIONC" test --json --jobs=-1 "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "jobs_neg" "$OUT" "false"
set +e; OUT="$("$PIONC" test --json --jobs abc "$TMP_DIR/t_pass.pion")"; RC=$?; set -e
[ "$RC" -ne 0 ]
check_single_json "jobs_abc" "$OUT" "false"

# 5j: CC wrapper writing stdout noise and exiting 1 during cold-cache c_sources compile in --json mode
cat > "$TMP_DIR/cc_noisy_fail.sh" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    *noisy.c)
      echo "cc-noise"
      exit 1
      ;;
  esac
done
exec "$CC_BIN" "\$@"
EOF
chmod +x "$TMP_DIR/cc_noisy_fail.sh"
set +e
OUT="$(PION_CACHE_DIR="$TMP_DIR/cas_cc_noisy" CC="$TMP_DIR/cc_noisy_fail.sh" "$PIONC" test --json "$TMP_DIR/ws_noisy")"
RC=$?
set -e
[ "$RC" -ne 0 ]
check_single_json "cc_noisy_cold_fail" "$OUT" "false"

# 5k: Windows rc_sources tool writing stdout noise and exiting 1 in --json mode
mkdir -p "$TMP_DIR/ws_rc/src" "$TMP_DIR/rc_bin_dir"
cat > "$TMP_DIR/ws_rc/app.rc" <<'EOF'
1 VERSIONINFO
BEGIN
END
EOF
cat > "$TMP_DIR/ws_rc/pion.toml" <<'EOF'
[package]
name = "ws_rc"
version = "0.1.0"

[link.windows]
rc_sources = ["app.rc"]
EOF
cat > "$TMP_DIR/ws_rc/src/lib.pion" <<'EOF'
test "rc_t" { debug_assert(true, "ok") }
EOF
for rcname in windres x86_64-w64-mingw32-windres llvm-rc; do
  cat > "$TMP_DIR/rc_bin_dir/$rcname" <<EOF
#!/bin/sh
touch "$TMP_DIR/rc_invoked.flag"
echo "rc-noise"
exit 1
EOF
  chmod +x "$TMP_DIR/rc_bin_dir/$rcname"
done
printf 'dummy-rt' > "$TMP_DIR/fake_pionrt.a"
set +e
OUT="$(PION_TARGET=amd64_win PION_RT_LIB="$TMP_DIR/fake_pionrt.a" PION_CACHE_DIR="$TMP_DIR/cas_rc_noisy" PATH="$TMP_DIR/rc_bin_dir:$PATH" "$PIONC" test --json "$TMP_DIR/ws_rc")"
RC=$?
set -e
[ "$RC" -ne 0 ]
[ -f "$TMP_DIR/rc_invoked.flag" ]
printf '%s' "$OUT" | grep -q "app.rc"
check_single_json "rc_noisy_cold_fail" "$OUT" "false"
echo "  [PASS] A5"

echo "=== Wave L1-A E2E [6/6]: A6 Struct literal dup/missing & add_missing_impl_edit ==="
cat > "$TMP_DIR/a6_bad.pion" <<'EOF'
struct S { x : Int, y : Int, z : Int }
pub fn main() -> Unit {
  let _ = S::{ x: 1, x: 2, y: 3, z: 4 }
  let _ = S::{ y: 2 }
}
EOF
set +e; A6_OUT="$("$PIONC" check --json "$TMP_DIR/a6_bad.pion" 2>&1)"; A6_RC=$?; set -e
[ "$A6_RC" -ne 0 ]
printf '%s' "$A6_OUT" | grep -q "duplicate field"
printf '%s' "$A6_OUT" | grep -q "missing fields \`x\`, \`z\`"
echo "  [PASS] A6"

echo "=== Wave L1-A E2E [7/7]: QBE f_guards stack alignment (dmath::ln + nested &&/|| + 2.0*x ASan 0-leak) ==="
cat > "$TMP_DIR/qbe_fguards.pion" <<'EOF'
let SQRT2 : Double = 1.4142135623730951
let LN2_HI : Double = 6.93147180369123816490e-01
let LN2_LO : Double = 1.90821492927058770002e-10
let KIND : Int = 64

fn match_kind(v : Int) -> Int {
  match v {
    KIND => 1
    _ => 0
  }
}

fn frexp_stub(x : Double) -> (Double, Int) {
  let _ = x
  (0.6425, 3)
}

pub fn ln(x : Double) -> Double {
  let l1 = 6.666666666666735130e-01
  if x < 0.0 {
  }
  let (f1, ki) = frexp_stub(x)
  let (f, k) = if f1 < SQRT2 / 2.0 {
    (f1 * 2.0 - 1.0, (ki - 1).to_double())
  } else {
    (f1 - 1.0, ki.to_double())
  }
  let s = f / (2.0 + f)
  let hfsq = 0.5 * f * f
  let r = l1 * s * s
  k * LN2_HI - (hfsq - (s * (hfsq + r) + k * LN2_LO) - f)
}

fn mk_str(tag : String) -> String {
  let sb = StringBuilder::new()
  sb.write_string(tag)
  sb.write_string("_heap")
  sb.to_string()
}

fn check_nested_guards(a : Bool, b : Bool, c : Bool, d : Bool, x : Double, flag : Bool) -> Int {
  let cmp = (a && b) == (c || d)
  let dbl = (2.0 * x - 1.0) + (x * 2.0 - 1.0)
  let s = mk_str("lhs") + (if flag { return 42 } else { "x" })
  let mut out = s.length()
  if cmp { out = out + 10 }
  if dbl > 0.0 { out = out + 1 }
  out
}

pub fn main(world : World) -> Unit {
  let v = ln(5.14)
  let g1 = check_nested_guards(true, true, false, true, 1.5, false)
  let g2 = check_nested_guards(true, false, false, false, 1.5, true)
  let k1 = match_kind(64) * 10 + match_kind(63)
  io_println(world, v.to_string() + "|" + g1.to_string() + ":" + g2.to_string() + ":" + k1.to_string())
}
EOF
"$PIONC" build -o "$TMP_DIR/qbe_fg_dev" "$TMP_DIR/qbe_fguards.pion"
"$PIONC" build --release -o "$TMP_DIR/qbe_fg_rel" "$TMP_DIR/qbe_fguards.pion"
FG_DEV="$("$TMP_DIR/qbe_fg_dev")"
FG_REL="$("$TMP_DIR/qbe_fg_rel")"
echo "  qbe_fguards dev=$FG_DEV rel=$FG_REL"
[ "$FG_DEV" = "1.6370408695984282|20:42:10" ]
[ "$FG_REL" = "1.6370408695984282|20:42:10" ]
if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/qbe_fg.o" "$TMP_DIR/qbe_fguards.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/qbe_fg.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/qbe_fg_asan"
  FG_ASAN="$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/qbe_fg_asan")"
  echo "  qbe_fguards ASan ($UNAME_S) -> $FG_ASAN"
  [ "$FG_ASAN" = "1.6370408695984282|20:42:10" ]
fi
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/qbe_fg.wasm" "$TMP_DIR/qbe_fguards.pion"
  FG_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/qbe_fg.wasm")"
  echo "  qbe_fguards wasm32 -> $FG_WASM"
  [ "$FG_WASM" = "1.6370408695984282|20:42:10" ]
fi
echo "  [PASS] QBE f_guards"
echo "=== Wave L1-A E2E ALL 7/7 PASSED ==="
