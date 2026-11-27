#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

cat > "$TMP_DIR/main.pion" <<'EOF'
enum MyErr {
  A
  B(Int)
}

struct Computed[T] {
  item : T
}

fn computed_by[T](getter : (Option[T]) -> T, same~ : (T, T) -> Bool) -> Computed[T] {
  let v1 = getter(None)
  let v2 = getter(Some(v1))
  if same(v1, v2) {
    Computed::{ item: v1 }
  } else {
    Computed::{ item: v2 }
  }
}

struct Graph {
  base : Int
}

fn Graph::computed_by[T](self : Graph, getter : (Option[T]) -> T, same~ : (T, T) -> Bool) -> Computed[T] {
  let _ = self.base
  let v1 = getter(None)
  let v2 = getter(Some(v1))
  if same(v1, v2) {
    Computed::{ item: v1 }
  } else {
    Computed::{ item: v2 }
  }
}

fn wrap_computed[U](getter : (Option[U]) -> U, same : (U, U) -> Bool) -> Computed[(Int64, U)] {
  computed_by(
    fn(last) {
      match last {
        None => (0L, getter(None))
        Some((up_rev, before)) => {
          let next = getter(Some(before))
          if same(before, next) { (up_rev, next) } else { (up_rev + 1L, next) }
        }
      }
    },
    same=fn(a, b) { a.0 == b.0 },
  )
}

fn invoke[T](f : () -> T) -> T {
  f()
}

fn check_unit_pat(ok : Bool) -> Int {
  let r : Result[Unit, String] = if ok { Ok(()) } else { Err("nope") }
  let a = match r {
    Ok(()) => 10
    Err(e) => e.length()
  }
  let b = match () {
    () => 3
  }
  let () = ()
  a + b
}

fn check_res_str_inline(cond : Bool) -> Int {
  let f = fn() {
    if cond {
      return Err("bad")
    }
    Ok(42)
  }
  match f() {
    Ok(v) => v
    Err(e) => e.length()
  }
}

fn check_res_str_clo(cond : Bool) -> Int {
  let f = fn() {
    if cond {
      return Err("hello")
    }
    Ok(42)
  }
  match invoke(f) {
    Ok(v) => v
    Err(e) => e.length()
  }
}

fn check_res_enum_clo(mode : Int) -> Int {
  let f = fn() {
    if mode == 1 {
      return Err(MyErr::A)
    }
    if mode == 2 {
      return Err(MyErr::B(17))
    }
    Ok(99)
  }
  match invoke(f) {
    Ok(v) => v
    Err(MyErr::A) => -1
    Err(MyErr::B(n)) => n
  }
}

fn check_opt_niche_clo(cond : Bool) -> String {
  let f = fn() {
    if cond {
      return None
    }
    Some("hi")
  }
  match invoke(f) {
    Some(s) => s
    None => "none"
  }
}

fn check_opt_niche_rev_clo(cond : Bool) -> String {
  let f = fn() {
    if cond {
      return Some("yes")
    }
    None
  }
  match invoke(f) {
    Some(s) => s
    None => "no"
  }
}

fn check_opt_niche_var_clo(cond : Bool) -> String {
  let f = fn() {
    if cond {
      return if cond { None } else { None }
    }
    Some("var")
  }
  match invoke(f) {
    Some(s) => s
    None => "vnone"
  }
}

fn check_double_clo(cond : Bool) -> Double {
  let f = fn() {
    if cond {
      return 1.5
    }
    2.5
  }
  invoke(f)
}

fn check_float_clo(cond : Bool) -> Float {
  let f = fn() {
    if cond {
      return 1.25f
    }
    2.75f
  }
  invoke(f)
}

struct Acc {
  base : Int
}

fn Acc::add_step(self : Acc, x : Int) -> Int {
  self.base + x
}

fn run_fix_once[T](init : T, f : (T) -> T) -> T {
  f(init)
}

fn run_fix_opt[T](f : (Option[T]) -> T) -> T {
  let first = f(None)
  f(Some(first))
}

fn check_nested_fix_cache_e2e() -> Int {
  let acc = Acc::{ base: 3 }
  run_fix_opt(fn(p0) {
    let base0 = match p0 {
      None => 1
      Some(v) => v
    }
    let arr : Array[Int] = [base0]
    let m : Map[String, Int] = Map([("k", base0)])
    let mid = run_fix_opt(fn(p1) {
      let base1 = match p1 {
        None => arr[0]
        Some(v) => v + 1
      }
      let inner = run_fix_opt(fn(p2) {
        let base2 = match p2 {
          None => base1
          Some(v) => v + acc.add_step(base0)
        }
        let mv = match m.get("k") {
          Some(x) => x
          None => 0
        }
        base2 + mv
      })
      inner + arr.length()
    })
    run_fix_once(mid, fn(z) { z + acc.add_step(0) })
  })
}

pub fn main(w : World) -> Unit {
  let u = check_unit_pat(true) * 100 + check_unit_pat(false)
  let c1 = wrap_computed(
    fn(prev : Option[Int]) -> Int {
      match prev {
        None => 10
        Some(x) => x + 5
      }
    },
    fn(a : Int, b : Int) -> Bool { a == b },
  )
  let g = Graph::{ base: 1 }
  let c2 = g.computed_by(
    fn(last) {
      match last {
        None => (1L, 20)
        Some((rev, prev)) => (rev + 2L, prev + 7)
      }
    },
    same=fn(a, b) { a.0 == b.0 },
  )
  let r1 = check_res_str_inline(false) * 10 + check_res_str_inline(true)
  let r2 = check_res_str_clo(false) * 10 + check_res_str_clo(true)
  let r3 = check_res_enum_clo(0) + check_res_enum_clo(1) + check_res_enum_clo(2)
  let o1 = check_opt_niche_clo(false) + "/" + check_opt_niche_clo(true)
  let o2 = check_opt_niche_rev_clo(true) + "/" + check_opt_niche_rev_clo(false)
  let o3 = check_opt_niche_var_clo(false) + "/" + check_opt_niche_var_clo(true)
  let d = check_double_clo(true) + check_double_clo(false)
  let fl = (check_float_clo(true) + check_float_clo(false)).to_double()
  let nf = check_nested_fix_cache_e2e()
  let out = "u=" + u.to_string() +
    " c1=" + c1.item.0.to_string() + ":" + c1.item.1.to_string() +
    " c2=" + c2.item.0.to_string() + ":" + c2.item.1.to_string() +
    " r=" + r1.to_string() + ":" + r2.to_string() + ":" + r3.to_string() +
    " o=" + o1 + "|" + o2 + "|" + o3 +
    " f=" + d.to_string() + ":" + fl.to_string() +
    " nf=" + nf.to_string()
  io_println(w, out)
}
EOF

EXPECTED="u=1307 c1=1:15 c2=3:27 r=423:425:115 o=hi/none|yes/no|var/vnone f=4:4 nf=145"

"$PIONC" build -o "$TMP_DIR/app_dev" "$TMP_DIR/main.pion"
"$PIONC" build --release -o "$TMP_DIR/app_rel" "$TMP_DIR/main.pion"
DEV_OUT="$("$TMP_DIR/app_dev")"
REL_OUT="$("$TMP_DIR/app_rel")"
echo "closure_early_ret_and_infer dev=$DEV_OUT"
echo "closure_early_ret_and_infer rel=$REL_OUT"
[ "$DEV_OUT" = "$EXPECTED" ] || { echo "FAIL: dev mismatch: got '$DEV_OUT', expected '$EXPECTED'" >&2; exit 1; }
[ "$REL_OUT" = "$EXPECTED" ] || { echo "FAIL: rel mismatch: got '$REL_OUT', expected '$EXPECTED'" >&2; exit 1; }

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/app.wasm" "$TMP_DIR/main.pion"
  WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/app.wasm")"
  echo "closure_early_ret_and_infer wasm32=$WASM_OUT"
  [ "$WASM_OUT" = "$EXPECTED" ] || { echo "FAIL: wasm32 mismatch: got '$WASM_OUT', expected '$EXPECTED'" >&2; exit 1; }
fi

CC_BIN="${CC:-cc}"
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  "$PIONC" build --release --emit-obj "$TMP_DIR/app.o" "$TMP_DIR/main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/app.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/app_asan"
  ASAN_OUT="$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/app_asan")"
  echo "closure_early_ret_and_infer ASan ($UNAME_S)=$ASAN_OUT"
  [ "$ASAN_OUT" = "$EXPECTED" ] || { echo "FAIL: ASan mismatch: got '$ASAN_OUT', expected '$EXPECTED'" >&2; exit 1; }
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: ASan required by PION_REQUIRE_SANITIZERS=1" >&2
  exit 1
fi

echo "closure_early_ret_and_infer: ALL PASSED"
