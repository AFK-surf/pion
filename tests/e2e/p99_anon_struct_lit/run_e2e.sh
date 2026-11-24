#!/bin/sh
# P99: anonymous struct literals `{ f: v }` / `{ ..base, f: v }` without a struct context
# must fail closed in `pionc check` (E_TYPE_MISMATCH) instead of type-checking as `TError`
# and lowering to a NULL struct pointer (runtime SIGSEGV). Every legal context
# (annotations, typed containers, Option/Result payloads, returns, branches, tuples,
# spread, closures, top-level constants, default/named arguments, nested fields, generic
# structs, methods, cross-package structs) still builds and runs identically on
# Native (Debug + --release) and Wasm32, with 0 ASan/LSan errors.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

echo "=== [P99] anonymous struct literal: fail-closed check + legal contexts ==="

# ---------------------------------------------------------------------
# Part 1: negative cases -> `check --json` non-zero + E_TYPE_MISMATCH, `build` refuses.
# ---------------------------------------------------------------------
mkdir -p "$TMP_DIR/neg"
cat > "$TMP_DIR/neg/n1_let.pion" <<'EOF'
pub fn main(w : World) -> Int {
  let ln = { start: 0, end: 1 }
  io_println(w, ln.start.to_string())
  0
}
EOF
cat > "$TMP_DIR/neg/n2_push_untyped.pion" <<'EOF'
pub fn main(w : World) -> Int {
  let parts = []
  parts.push({ start: 0, end: 1 })
  io_println(w, parts.length().to_string())
  0
}
EOF
cat > "$TMP_DIR/neg/n3_int_annot.pion" <<'EOF'
pub fn main(w : World) -> Int {
  let x : Int = { start: 0, end: 1 }
  io_println(w, x.to_string())
  0
}
EOF
cat > "$TMP_DIR/neg/n4_spread_int.pion" <<'EOF'
pub fn main(w : World) -> Int {
  let x = { ..42, start: 0 }
  io_println(w, "unreachable")
  0
}
EOF
cat > "$TMP_DIR/neg/n5_array_mixed.pion" <<'EOF'
struct Pt {
  x : Int
  y : Int
}

pub fn main(w : World) -> Int {
  let a = [{ x: 1, y: 2 }, Pt::{ x: 3, y: 4 }]
  io_println(w, a[0].x.to_string())
  0
}
EOF
cat > "$TMP_DIR/neg/n6_generic_arg.pion" <<'EOF'
fn id[T](v : T) -> T {
  v
}

pub fn main(w : World) -> Int {
  let p = id({ x: 1, y: 2 })
  io_println(w, "unreachable")
  0
}
EOF

for f in "$TMP_DIR"/neg/*.pion; do
  name=$(basename "$f" .pion)
  set +e
  out=$("$PIONC" check --json "$f" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $name: check --json must exit non-zero: $out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q '"code":"E_TYPE_MISMATCH"'; then
    echo "FAIL: $name: expected E_TYPE_MISMATCH: $out" >&2
    exit 1
  fi
  case "$name" in
    n4_*) want='struct update base must be a struct type' ;;
    *) want='cannot infer struct type for anonymous struct literal' ;;
  esac
  if ! printf '%s' "$out" | grep -q "$want"; then
    echo "FAIL: $name: expected message '$want': $out" >&2
    exit 1
  fi
  set +e
  "$PIONC" build -o "$TMP_DIR/neg/$name.bin" "$f" > "$TMP_DIR/neg/$name.build.log" 2>&1
  brc=$?
  set -e
  if [ "$brc" -eq 0 ] || [ -e "$TMP_DIR/neg/$name.bin" ]; then
    echo "FAIL: $name: build must refuse (rc=$brc)" >&2
    cat "$TMP_DIR/neg/$name.build.log" >&2
    exit 1
  fi
  echo "PASS: $name rejected (check rc=$rc, build rc=$brc)"
done

# ---------------------------------------------------------------------
# Part 2: legal contexts -> 0 diagnostics, Native Debug == --release == Wasm32 == expected.
# ---------------------------------------------------------------------
SRC="$TMP_DIR/p99_pos.pion"
cat > "$SRC" <<'EOF'
struct Pt {
  x : Int
  y : Int
}

struct Named {
  label : String
  n : Int
}

struct Outer {
  inner : Pt
  tag : String
  opt : Option[Pt]
}

struct Box[T] {
  a : T
  b : Int
}

struct Holder {
  mut p : Pt
}

enum Shape {
  Dot(Pt)
  Seg(Pt, Pt)
}

let ORIGIN : Pt = { x: 7, y: 8 }

fn Pt::add(self : Pt, o : Pt) -> Pt {
  { x: self.x + o.x, y: self.y + o.y }
}

fn mk() -> Pt {
  { x: 1, y: 2 }
}

fn mk_ret(c : Bool) -> Pt {
  if c {
    return { x: 3, y: 4 }
  }
  { x: 5, y: 6 }
}

fn mk_named(i : Int) -> Named {
  { label: "nm" + i.to_string(), n: i }
}

fn wrap[T](v : T) -> Box[T] {
  { a: v, b: 1 }
}

fn take(p : Pt) -> Int {
  p.x * 10 + p.y
}

fn take_def(p : Pt = { x: 4, y: 2 }) -> Int {
  p.x * 10 + p.y
}

fn take_lbl(base~ : Pt = { x: 1, y: 1 }, d~ : Pt) -> Int {
  take(base) + take(d)
}

fn sum_pts(ps : Array[Pt]) -> Int {
  let mut s = 0
  for p in ps {
    s = s + p.x + p.y
  }
  s
}

fn shape_sum(s : Shape) -> Int {
  match s {
    Dot(p) => take(p)
    Seg(a, b) => take(a) + take(b)
  }
}

pub fn main(w : World) -> Int {
  let acc : Array[String] = []
  let a : Pt = { x: 1, y: 2 }
  acc.push("let=" + take(a).to_string())
  let arr : Array[Pt] = []
  arr.push({ x: 2, y: 3 })
  arr.push({ x: 4, y: 5 })
  acc.push("push=" + sum_pts(arr).to_string())
  let arr2 : Array[Pt] = [{ x: 1, y: 1 }, { x: 2, y: 2 }]
  acc.push("arrlit=" + sum_pts(arr2).to_string())
  let arr3 = [Pt::{ x: 3, y: 3 }, { x: 4, y: 4 }]
  acc.push("arrqual=" + sum_pts(arr3).to_string())
  let imm : ImmArray[Pt] = [{ x: 5, y: 5 }, { x: 6, y: 6 }]
  let mut si = 0
  for p in imm {
    si = si + p.x + p.y
  }
  acc.push("imm=" + si.to_string())
  let m : Map[String, Pt] = Map([])
  m.set("k", { x: 9, y: 1 })
  match m.get("k") {
    Some(p) => acc.push("map=" + take(p).to_string())
    None => acc.push("map=none")
  }
  let o : Option[Pt] = Some({ x: 1, y: 9 })
  match o {
    Some(p) => acc.push("opt=" + take(p).to_string())
    None => acc.push("opt=none")
  }
  let r : Result[Pt, Int] = Ok({ x: 2, y: 8 })
  match r {
    Ok(p) => acc.push("res=" + take(p).to_string())
    Err(_) => acc.push("res=err")
  }
  let opts : Array[Option[Pt]] = []
  opts.push(Some({ x: 3, y: 7 }))
  match opts[0] {
    Some(p) => acc.push("pushopt=" + take(p).to_string())
    None => acc.push("pushopt=none")
  }
  acc.push("ret=" + take(mk()).to_string())
  acc.push("early=" + take(mk_ret(true)).to_string() + "," + take(mk_ret(false)).to_string())
  let nm = mk_named(3)
  acc.push("named=" + nm.label + "/" + nm.n.to_string())
  let c = acc.length() > 3
  let ip : Pt = if c { { x: 1, y: 0 } } else { { x: 0, y: 1 } }
  acc.push("if=" + take(ip).to_string())
  let mp : Pt = match c {
    true => { x: 2, y: 0 }
    false => { x: 0, y: 2 }
  }
  acc.push("match=" + take(mp).to_string())
  let t : (Int, Pt) = (1, { x: 3, y: 1 })
  acc.push("tuple=" + take(t.1).to_string())
  let base : Pt = { x: 5, y: 5 }
  let sp1 : Pt = { ..base, y: 6 }
  let sp2 = { ..base, x: 9 }
  acc.push("spread=" + take(sp1).to_string() + "," + take(sp2).to_string())
  let f : () -> Pt = fn() -> Pt { { x: 6, y: 1 } }
  acc.push("closure=" + take(f()).to_string())
  let g = fn(k : Int) -> Pt { { x: k, y: k + 1 } }
  acc.push("closure2=" + take(g(4)).to_string())
  acc.push("const=" + take(ORIGIN).to_string())
  acc.push("default=" + take_def().to_string())
  acc.push("labeled=" + take_lbl(d={ x: 2, y: 2 }).to_string())
  acc.push("arg=" + take({ x: 8, y: 2 }).to_string())
  acc.push("method=" + take(a.add({ x: 1, y: 1 })).to_string())
  let ou = Outer::{ inner: { x: 1, y: 3 }, tag: "t", opt: Some({ x: 2, y: 4 }) }
  let oo = match ou.opt {
    Some(p) => take(p)
    None => 0
  }
  acc.push("nested=" + take(ou.inner).to_string() + ou.tag + oo.to_string())
  let bx : Box[Int] = { a: 41, b: 1 }
  acc.push("box=" + (bx.a + bx.b).to_string())
  let bp : Box[Pt] = { a: { x: 1, y: 1 }, b: 2 }
  acc.push("boxpt=" + take(bp.a).to_string())
  let ws = wrap("s")
  acc.push("wrap=" + ws.a + ws.b.to_string())
  acc.push("enum=" + shape_sum(Dot({ x: 1, y: 2 })).to_string() + "," +
    shape_sum(Seg({ x: 1, y: 1 }, { x: 2, y: 2 })).to_string())
  let h = Holder::{ p: { x: 0, y: 0 } }
  h.p = { x: 7, y: 7 }
  acc.push("field=" + take(h.p).to_string())
  arr[0] = { x: 0, y: 1 }
  acc.push("index=" + take(arr[0]).to_string())
  let mut mv : Pt = { x: 1, y: 1 }
  mv = { x: 2, y: 2 }
  acc.push("assign=" + take(mv).to_string())
  let names : Array[Named] = []
  let mut i = 0
  while i < 3 {
    names.push({ label: "n" + i.to_string(), n: i })
    i = i + 1
  }
  let mut joined = ""
  for nn in names {
    joined = joined + nn.label
  }
  acc.push("loop=" + joined)
  for s in acc {
    io_println(w, s)
  }
  0
}
EOF

EXPECTED='let=12
push=14
arrlit=6
arrqual=14
imm=22
map=91
opt=19
res=28
pushopt=37
ret=12
early=34,56
named=nm3/3
if=10
match=20
tuple=31
spread=56,95
closure=61
closure2=45
const=78
default=42
labeled=33
arg=82
method=23
nested=13t24
box=42
boxpt=11
wrap=s1
enum=12,33
field=77
index=1
assign=22
loop=n0n1n2'

CHK="$("$PIONC" check --json "$SRC")"
if [ "$CHK" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: positive contexts must check clean: $CHK" >&2
  exit 1
fi
NAT_DBG="$("$PIONC" run "$SRC")"
NAT_REL="$("$PIONC" run --release "$SRC")"
if [ "$NAT_DBG" != "$EXPECTED" ]; then
  echo "FAIL: native debug output mismatch" >&2
  printf 'got:\n%s\nwant:\n%s\n' "$NAT_DBG" "$EXPECTED" >&2
  exit 1
fi
if [ "$NAT_REL" != "$EXPECTED" ]; then
  echo "FAIL: native release output mismatch" >&2
  printf 'got:\n%s\n' "$NAT_REL" >&2
  exit 1
fi
echo "PASS: legal contexts Native (Debug + --release)"

CC_BIN="${CC:-cc}"
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p99_pos.o" "$SRC"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p99_pos.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p99_asan"
  ASAN_OUT="$("$TMP_DIR/p99_asan")"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: ASan/LSan run mismatch or leak" >&2
    printf 'got:\n%s\n' "$ASAN_OUT" >&2
    exit 1
  fi
  echo "PASS: legal contexts ASan/LSan (0 errors)"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping P99 ASan leg"
fi

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p99_dbg.wasm" "$SRC"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p99_rel.wasm" "$SRC"
  for mode in dbg rel; do
    OUT_W="$(node "$WASM_RT" "$TMP_DIR/p99_$mode.wasm")"
    if [ "$OUT_W" != "$EXPECTED" ]; then
      echo "FAIL: Wasm32 ($mode) diverges from expected" >&2
      printf 'got:\n%s\n' "$OUT_W" >&2
      exit 1
    fi
  done
  echo "PASS: legal contexts Wasm32 (Debug + --release)"
else
  echo "NOTE: node unavailable; skipping P99 Wasm32 execution leg"
fi

# ---------------------------------------------------------------------
# Part 3: cross-package struct in annotated / spread / container contexts.
# ---------------------------------------------------------------------
mkdir -p "$TMP_DIR/ws/geo/src" "$TMP_DIR/ws/app/src"
cat > "$TMP_DIR/ws/geo/pion.toml" <<'EOF'
[package]
name = "geo"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws/geo/src/lib.pion" <<'EOF'
pub struct Span {
  start : Int
  end : Int
}

pub fn Span::len(self : Span) -> Int {
  self.end - self.start
}

pub fn shift(s : Span, d : Int) -> Span {
  { start: s.start + d, end: s.end + d }
}
EOF
cat > "$TMP_DIR/ws/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
geo = { path = "../geo" }
EOF
cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "geo"

fn total(xs : Array[geo::Span]) -> Int {
  let mut s = 0
  for x in xs {
    s = s + x.len()
  }
  s
}

pub fn main(w : World) -> Int {
  let a : geo::Span = { start: 1, end: 4 }
  let b : geo::Span = { ..a, end: 10 }
  let xs : Array[geo::Span] = [{ start: 0, end: 2 }]
  xs.push({ start: 5, end: 8 })
  let sh = geo::shift({ start: 2, end: 3 }, 10)
  io_println(w, "xpkg=" + a.len().to_string() + "," + b.len().to_string() + "," +
    total(xs).to_string() + "," + sh.start.to_string())
  0
}
EOF
XCHK="$("$PIONC" check --json "$TMP_DIR/ws/app")"
if [ "$XCHK" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: cross-package positive must check clean: $XCHK" >&2
  exit 1
fi
XNAT="$("$PIONC" run "$TMP_DIR/ws/app")"
if [ "$XNAT" != "xpkg=3,9,5,12" ]; then
  echo "FAIL: cross-package anonymous struct literal: native=$XNAT" >&2
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  XWASM="$("$PIONC" run --target wasm32 "$TMP_DIR/ws/app")"
  if [ "$XWASM" != "$XNAT" ]; then
    echo "FAIL: cross-package anonymous struct literal: native=$XNAT wasm32=$XWASM" >&2
    exit 1
  fi
fi
echo "PASS: cross-package struct contexts (Native == Wasm32)"

cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "geo"

pub fn main(w : World) -> Int {
  let a = { start: 1, end: 4 }
  io_println(w, a.start.to_string())
  0
}
EOF
set +e
XNEG="$("$PIONC" check --json "$TMP_DIR/ws/app" 2>&1)"
xrc=$?
set -e
if [ "$xrc" -eq 0 ] || ! printf '%s' "$XNEG" | grep -q '"code":"E_TYPE_MISMATCH"'; then
  echo "FAIL: cross-package untyped anonymous literal must be rejected: $XNEG" >&2
  exit 1
fi
echo "PASS: cross-package untyped anonymous literal rejected"

echo "[PASS] P99 anonymous struct literals fail closed without context; legal contexts agree on Native/Wasm32"
