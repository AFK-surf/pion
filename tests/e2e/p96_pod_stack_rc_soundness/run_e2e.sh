#!/bin/sh
# P96 E2E regression:
# 1. Stack-promoted POD structs and StrView/BytesView buffers carry a valid 24B immortal
#    PionHeader (owner_tid=0, local_rc=0, shared_rc=1, type_tag=PION_TAG_STRUCT(4),
#    flags=FROZEN|IMMORTAL|DEEP_FROZEN(11), drop_fn=NULL) across multi-hop borrowed RC calls.
# 2. Single-field POD structs (`struct One { n : Int }`) are pointer-stored in arrays (flat-POD
#    requires 2..=6 fields) and MUST heap-allocate on `push` / index-assign, while 2-field flat-POD
#    (`struct Two`) remains stack-promoted with 0 heap allocs.
# 3. Subsequent local bindings (`let save = fn(...)`, `if opt is Some(save)`) shadowing a read-only
#    top-level function `fn save` MUST prevent stack promotion so heap holders never store a
#    dangling stack address.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
CC_BIN="${CC:-cc}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<'EOF' > "$TMP_DIR/p96_repro.pion"
pub struct Cfg {
  pub a : Int
  pub b : UInt64
  pub c : Bool
}

struct Budget {
  mut total : UInt64
}

fn Budget::consume(self : Budget, n : Int, cfg : Cfg) -> Result[Unit, Int] {
  let next = self.total + n.to_int64().to_uint64()
  if next > cfg.b {
    return Err(1)
  }
  self.total = next
  Ok(())
}

pub fn leaf(data : Bytes, b : Budget, cfg : Cfg) -> Result[Bytes, Int] {
  let mut x = data
  if x.length() > 1000000 {
    return Err(2)
  }
  match b.consume(x.length(), cfg) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  Ok(x)
}

pub fn mid(data : Bytes, cfg : Cfg, b : Budget) -> Result[Bytes, Int] {
  let mut i = 0
  while i < 1 {
    i += 1
    let r = match leaf(data, Budget::{ total: 0UL }, cfg) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match b.consume(r.length(), cfg) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  Ok(data)
}

fn outer(data : Bytes, rounds : Int) -> Int {
  let mut guard0 : Int64 = 0L
  let mut guard1 : Int64 = 0L
  let mut guard2 : Int64 = 0L
  let mut sum = 0
  let mut i = 0
  while i < rounds {
    i += 1
    let dec_cfg = Cfg::{ a: 4 + (i % 3), b: 4294967296UL, c: false }
    match mid(data, dec_cfg, Budget::{ total: 0UL }) {
      Ok(v) => sum += v.length() + dec_cfg.a
      Err(e) => sum += e
    }
    guard0 = guard0 + 0L
    guard1 = guard1 + 0L
    guard2 = guard2 + 0L
  }
  if guard0 != 0L || guard1 != 0L || guard2 != 0L {
    panic("stack guard corrupted")
  }
  sum
}

struct ViewAcc {
  mut total : Int
}

fn ViewAcc::add_sv(self : ViewAcc, n : Int, v : StrView) -> Result[Unit, Int] {
  self.total = self.total + n + v.length()
  Ok(())
}

fn ViewAcc::add_bv(self : ViewAcc, n : Int, v : BytesView) -> Result[Unit, Int] {
  self.total = self.total + n + v.length()
  Ok(())
}

pub fn sv_leaf(data : Bytes, acc : ViewAcc, v : StrView) -> Result[Bytes, Int] {
  let mut x = data
  match acc.add_sv(x.length(), v) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  Ok(x)
}

pub fn sv_mid(data : Bytes, v : StrView, acc : ViewAcc) -> Result[Bytes, Int] {
  let mut i = 0
  while i < 1 {
    i += 1
    let r = match sv_leaf(data, ViewAcc::{ total: 0 }, v) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
    match acc.add_sv(r.length(), v) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  Ok(data)
}

pub fn bv_leaf(data : Bytes, acc : ViewAcc, v : BytesView) -> Result[Bytes, Int] {
  let mut x = data
  match acc.add_bv(x.length(), v) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  Ok(x)
}

pub fn bv_mid(data : Bytes, v : BytesView, acc : ViewAcc) -> Result[Bytes, Int] {
  let mut i = 0
  while i < 1 {
    i += 1
    let r = match bv_leaf(data, ViewAcc::{ total: 0 }, v) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
    match acc.add_bv(r.length(), v) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  Ok(data)
}

fn view_outer(s : String, data : Bytes, rounds : Int) -> Int {
  let mut guard0 : Int64 = 0L
  let mut guard1 : Int64 = 0L
  let mut sum = 0
  let mut i = 0
  while i < rounds {
    i += 1
    let sv = s.as_view()
    let acc1 = ViewAcc::{ total: 0 }
    match sv_mid(data, sv, acc1) {
      Ok(_) => sum += acc1.total
      Err(e) => sum += e
    }
    let bv = data.as_view()
    let acc2 = ViewAcc::{ total: 0 }
    match bv_mid(data, bv, acc2) {
      Ok(_) => sum += acc2.total
      Err(e) => sum += e
    }
    guard0 = guard0 + 0L
    guard1 = guard1 + 0L
  }
  if guard0 != 0L || guard1 != 0L {
    panic("view stack guard corrupted")
  }
  sum
}

// Case 3: Single-field POD (`One`) is pointer-stored in arrays -> MUST heap-allocate on push & assign.
// Positive 2-field POD (`Two`) is flat-stored inline in arrays -> stays stack-promoted with 24B header.
pub struct One {
  pub n : Int
}

pub struct Two {
  pub a : Int
  pub b : Int
}

pub fn collect_one_push() -> Array[One] {
  let xs : Array[One] = []
  let mut i = 0
  while i < 4 {
    let p = One::{ n: i }
    xs.push(p)
    i += 1
  }
  xs
}

pub fn collect_one_assign() -> Array[One] {
  let ys : Array[One] = [One::{ n: -1 }, One::{ n: -1 }, One::{ n: -1 }, One::{ n: -1 }]
  let mut i = 0
  while i < 4 {
    let q = One::{ n: 100 + i }
    ys[i] = q
    i += 1
  }
  ys
}

pub fn collect_two_flat() -> Int {
  let xs : Array[Two] = []
  let mut i = 0
  while i < 4 {
    let p = Two::{ a: i, b: i * 10 }
    xs.push(p)
    i += 1
  }
  xs[0].a + xs[1].a + xs[2].b + xs[3].b
}

// Case 4: Top-level read-only `save(p)` shadowed by a local closure declared AFTER `let p = ...`.
struct PairHolder {
  mut item : Option[Two]
}

fn save(p : Two) -> Int {
  p.a + p.b
}

pub fn shadow_save_into(h : PairHolder, k : Int) -> Unit {
  let p = Two::{ a: k, b: k * 10 }
  let save = fn(x : Two) -> Unit { h.item = Some(x) }
  save(p)
}

pub fn shadow_save_is_into(h : PairHolder, k : Int) -> Unit {
  let p = Two::{ a: k + 1, b: k * 100 }
  let cb : Option[(Two) -> Unit] = Some(fn(x : Two) -> Unit { h.item = Some(x) })
  if cb is Some(save) {
    save(p)
  }
}

fn clobber_stack(x : Int) -> Int {
  let a = x * 3 + 1
  let b = a * 5 + 2
  let c = b * 7 + 3
  a + b + c
}

pub fn main(world : World) -> Int {
  let data = "hello".to_bytes()
  let r1 = outer(data, 300)
  let r2 = view_outer("abcdef", data, 300)

  let ones_p = collect_one_push()
  let ones_a = collect_one_assign()
  let _ = clobber_stack(99)
  if ones_p[0].n != 0 || ones_p[1].n != 1 || ones_p[2].n != 2 || ones_p[3].n != 3 {
    panic("One push corrupted/aliased stack slot")
  }
  if ones_a[0].n != 100 || ones_a[1].n != 101 || ones_a[2].n != 102 || ones_a[3].n != 103 {
    panic("One assign corrupted/aliased stack slot")
  }
  let r3 = collect_two_flat()

  let h1 = PairHolder::{ item: None }
  shadow_save_into(h1, 7)
  let h2 = PairHolder::{ item: None }
  shadow_save_is_into(h2, 8)
  let _ = clobber_stack(12345)
  let s1 = match h1.item {
    Some(v) => v.a * 1000 + v.b
    None => -1
  }
  let s2 = match h2.item {
    Some(v) => v.a * 1000 + v.b
    None => -1
  }
  let _ = save(Two::{ a: 1, b: 2 })
  io_println(
    world,
    "p96=" +
    r1.to_string() +
    "," +
    r2.to_string() +
    "," +
    r3.to_string() +
    "," +
    s1.to_string() +
    "," +
    s2.to_string(),
  )
  0
}
EOF

# Expected:
# r1 = 3000, r2 = 6300, r3 = 0+1+20+30 = 51, s1 = 7070, s2 = 9800
WANT="p96=3000,6300,51,7070,9800"

# 1. Precise SSA audit:
#    - `outer`: dec_cfg arg passed to `mid` traces to `alloc8 48` + immortal header (type_tag=4, flags=11) + `add raw, 24`.
#    - `view_outer`: BOTH `sv_mid`'s `v` arg AND `bv_mid`'s `v` arg trace independently to DISTINCT `alloc8 48` immortal headers.
#    - `collect_one_push` / `collect_one_assign`: heap-allocated `$pion_alloc_uninit(w 8, ...)`, NEVER `alloc8 32`.
#    - `collect_two_flat`: stack-promoted `alloc8 40` + immortal header, 0 `$pion_alloc_uninit(w 16, ...)`.
#    - `shadow_save_into` / `shadow_save_is_into`: heap-allocated `$pion_alloc_uninit(w 16, ...)`, NEVER `alloc8 40`.
"$PIONC" build --release --emit-ssa "$TMP_DIR/p96.ssa" "$TMP_DIR/p96_repro.pion"
python3 - "$TMP_DIR/p96.ssa" <<'PYEOF'
import sys, re

ssa = open(sys.argv[1]).read()

def fn_body(name):
    m = re.search(rf"function [^\n]*\$[^\s(]*{re.escape(name)}\([^\n]*\)\s*\{{(.*?)\n\}}", ssa, re.S)
    assert m, f"function *{name} not found in SSA"
    return m.group(1)

def trace_immortal_stack_arg(body, callee_substr, arg_idx, expected_alloc_bytes):
    # Parse def maps for `add %raw, 24`, `storel/loadl` slots, and `alloc8`.
    add24 = {}   # %body -> %raw
    allocs = {}  # %raw -> size
    stores = {}  # %slot -> set of stored vals
    loads = {}   # %reg -> %slot
    copies = {}  # %dst -> %src
    for line in body.splitlines():
        s = line.strip()
        m = re.match(r"^(%\S+)\s*=l\s+alloc8\s+(\d+)$", s)
        if m:
            allocs[m.group(1)] = int(m.group(2))
            continue
        m = re.match(r"^(%\S+)\s*=l\s+add\s+(%\S+),\s*24$", s)
        if m:
            add24[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^(%\S+)\s*=l\s+copy\s+(%\S+)$", s)
        if m:
            copies[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^storel\s+(%\S+),\s*(%\S+)$", s)
        if m:
            stores.setdefault(m.group(2), set()).add(m.group(1))
            continue
        m = re.match(r"^(%\S+)\s*=l\s+loadl\s+(%\S+)$", s)
        if m:
            loads[m.group(1)] = m.group(2)
            continue

    m_call = re.search(rf"call \$[^\s(]*{re.escape(callee_substr)}\(([^)]*)\)", body)
    assert m_call, f"call to *{callee_substr} not found"
    raw_args = [a.strip().split()[-1] for a in m_call.group(1).split(",")]
    arg_reg = raw_args[arg_idx]

    # Walk back through copies/loads/stores to find `%body =l add %raw, 24`.
    seen = set()
    work = [arg_reg]
    found_raw = None
    while work:
        cur = work.pop()
        if cur in seen:
            continue
        seen.add(cur)
        if cur in add24:
            found_raw = add24[cur]
            break
        if cur in copies:
            work.append(copies[cur])
        if cur in loads:
            slot = loads[cur]
            for v in stores.get(slot, ()):
                work.append(v)
    assert found_raw is not None, f"arg {arg_idx} ({arg_reg}) of {callee_substr} did not trace to `add %raw, 24`"
    assert allocs.get(found_raw) == expected_alloc_bytes, (
        f"{callee_substr} raw {found_raw} alloc size={allocs.get(found_raw)}, expected {expected_alloc_bytes}"
    )
    # Verify header stores anchored on `found_raw`:
    assert re.search(rf"storel 0, {re.escape(found_raw)}\b", body), f"missing storel 0 on {found_raw}"
    m12 = re.search(rf"(%\S+)\s*=l\s+add\s+{re.escape(found_raw)},\s*12\b", body)
    m14 = re.search(rf"(%\S+)\s*=l\s+add\s+{re.escape(found_raw)},\s*14\b", body)
    assert m12 and re.search(rf"storeh 4, {re.escape(m12.group(1))}\b", body), f"missing type_tag=4 on {found_raw}"
    assert m14 and re.search(rf"storeh 11, {re.escape(m14.group(1))}\b", body), f"missing flags=11 on {found_raw}"
    return found_raw

outer_body = fn_body("outer")
assert "alloc8 24" not in outer_body, "outer must not emit headerless alloc8 24"
outer_raw = trace_immortal_stack_arg(outer_body, "mid", 1, 48)

vo_body = fn_body("view_outer")
assert "alloc8 24" not in vo_body, "view_outer must not emit headerless alloc8 24"
sv_raw = trace_immortal_stack_arg(vo_body, "sv_mid", 1, 48)
bv_raw = trace_immortal_stack_arg(vo_body, "bv_mid", 1, 48)
assert sv_raw != bv_raw, f"sv_mid and bv_mid must trace to distinct stack buffers (both {sv_raw})"

for name in ("collect_one_push", "collect_one_assign"):
    b = fn_body(name)
    assert "call $pion_alloc_uninit(w 8," in b, f"{name} must heap-allocate 1-field One"
    assert "alloc8 32" not in b, f"{name} must NOT stack-promote 1-field One"

two_b = fn_body("collect_two_flat")
assert "alloc8 40" in two_b and "storeh 11, " in two_b, "collect_two_flat must stack-promote 2-field Two with 24B header"
assert "call $pion_alloc_uninit(w 16," not in two_b, "collect_two_flat must not heap-allocate Two"

for name in ("shadow_save_into", "shadow_save_is_into"):
    b = fn_body(name)
    assert "call $pion_alloc_uninit(w 16," in b, f"{name} must heap-allocate Two when local `save` shadows top-level fn"
    assert "alloc8 40" not in b, f"{name} must NOT stack-promote Two when shadowed by local `save`"

print(f"p96 SSA check OK (outer={outer_raw}, sv={sv_raw}, bv={bv_raw}; One=heap, Two=flat-stack, shadow_save=heap)")
PYEOF

# 2. Native dev + Native --release
"$PIONC" build -o "$TMP_DIR/p96_dev" "$TMP_DIR/p96_repro.pion"
DEV_OUT=$("$TMP_DIR/p96_dev")
echo "p96 native dev -> $DEV_OUT"
test "$DEV_OUT" = "$WANT"

"$PIONC" build --release -o "$TMP_DIR/p96_rel" "$TMP_DIR/p96_repro.pion"
REL_OUT=$("$TMP_DIR/p96_rel")
echo "p96 native release -> $REL_OUT"
test "$REL_OUT" = "$WANT"

# 3. Wasm32 (dev + --release)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p96_dev.wasm" "$TMP_DIR/p96_repro.pion"
  WASM_DEV=$(node "$WASM_RT" "$TMP_DIR/p96_dev.wasm")
  echo "p96 wasm32 dev -> $WASM_DEV"
  test "$WASM_DEV" = "$WANT"

  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p96_rel.wasm" "$TMP_DIR/p96_repro.pion"
  WASM_REL=$(node "$WASM_RT" "$TMP_DIR/p96_rel.wasm")
  echo "p96 wasm32 release -> $WASM_REL"
  test "$WASM_REL" = "$WANT"
fi

# 4. Native ASan/LSan (dev + --release)
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then

  "$PIONC" build --emit-staticlib "$TMP_DIR/libp96_dev.a" "$TMP_DIR/p96_repro.pion"
  "$CC_BIN" -fsanitize=address -Wl,--whole-archive "$TMP_DIR/libp96_dev.a" -Wl,--no-whole-archive "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p96_asan_dev" 2>/dev/null \
    || "$CC_BIN" -fsanitize=address -Wl,-force_load,"$TMP_DIR/libp96_dev.a" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p96_asan_dev"
  ASAN_DEV=$("$TMP_DIR/p96_asan_dev")
  echo "p96 ASan/LSan dev -> $ASAN_DEV"
  test "$ASAN_DEV" = "$WANT"

  "$PIONC" build --release --emit-staticlib "$TMP_DIR/libp96_rel.a" "$TMP_DIR/p96_repro.pion"
  "$CC_BIN" -fsanitize=address -Wl,--whole-archive "$TMP_DIR/libp96_rel.a" -Wl,--no-whole-archive "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p96_asan_rel" 2>/dev/null \
    || "$CC_BIN" -fsanitize=address -Wl,-force_load,"$TMP_DIR/libp96_rel.a" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p96_asan_rel"
  ASAN_REL=$("$TMP_DIR/p96_asan_rel")
  echo "p96 ASan/LSan release -> $ASAN_REL"
  test "$ASAN_REL" = "$WANT"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p96 ASan check"
fi

echo "PASS: p96_pod_stack_rc_soundness (POD+View 24B immortal header, 1-field One=heap, 2-field Two=flat-stack, shadow_save=heap, Native+ASan+Wasm32+SSA)"

# --- Case 5: Cross-package same-name static methods (`Reader::pick` vs `Keeper::pick`) in BOTH call orders ---
# Note: non-inlinable loops ensure calls stay distinct in `--release` SSA so exact arg origins are verified.
mkdir -p "$TMP_DIR/c5/dep/src" "$TMP_DIR/c5/app1/src" "$TMP_DIR/c5/app2/src"
cat <<'P5' > "$TMP_DIR/c5/dep/pion.toml"
[package]
name = "dep_views"
version = "0.1.0"
P5
cat <<'P5' > "$TMP_DIR/c5/dep/src/lib.pion"
pub struct Reader { pub tag : Int }
pub struct Keeper { pub tag : Int }

pub fn Reader::pick(v : StrView) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  acc + v.length()
}

pub fn Keeper::pick(v : StrView) -> StrView {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  if acc < 0 {
    return "".as_view()
  }
  v
}
P5
for ORD in 1 2; do
  cat <<'P5' > "$TMP_DIR/c5/app${ORD}/pion.toml"
[package]
name = "app_c5"
version = "0.1.0"

[dependencies]
dep_views = { path = "../dep" }
P5
done
cat <<'P5' > "$TMP_DIR/c5/app1/src/main.pion"
import "dep_views"

fn keep_view(s : String) -> StrView {
  let _ = dep_views::Reader::pick(s.as_view())
  dep_views::Keeper::pick(s.as_view())
}

fn clobber(x : Int) -> Int {
  let a = x * 7 + 3
  let b = a * 11 + 5
  a + b
}

pub fn main(w : World) -> Int {
  let s = "hello-keeper-" + "123"
  let v = keep_view(s)
  let _ = clobber(42)
  io_println(w, "c5_1=" + v.to_string())
  0
}
P5
cat <<'P5' > "$TMP_DIR/c5/app2/src/main.pion"
import "dep_views"

fn keep_view(s : String) -> StrView {
  let v = dep_views::Keeper::pick(s.as_view())
  let _ = dep_views::Reader::pick(s.as_view())
  v
}

fn clobber(x : Int) -> Int {
  let a = x * 7 + 3
  let b = a * 11 + 5
  a + b
}

pub fn main(w : World) -> Int {
  let s = "hello-keeper-" + "123"
  let v = keep_view(s)
  let _ = clobber(42)
  io_println(w, "c5_2=" + v.to_string())
  0
}
P5
for ORD in 1 2; do
  CAS_C5="$TMP_DIR/cas_c5_${ORD}"
  mkdir -p "$CAS_C5"
  PION_KEEP_NATIVE_SSA=1 PION_CACHE_DIR="$CAS_C5" "$PIONC" build --release -o "$TMP_DIR/c5_${ORD}_rel" "$TMP_DIR/c5/app${ORD}"
  OUT_C5=$("$TMP_DIR/c5_${ORD}_rel")
  echo "p96 Case 5 order ${ORD} native rel -> $OUT_C5"
  test "$OUT_C5" = "c5_${ORD}=hello-keeper-123"
  C5_SSA=$(grep -l "fn_keep_view(" "$CAS_C5"/ssa/*.ssa | head -n 1)
  test -n "$C5_SSA"
  python3 - "$C5_SSA" <<'PY5'
import sys, re
ssa = open(sys.argv[1]).read()
m = re.search(r"function [^\n]*fn_keep_view\([^\n]*\)\s*\{(.*?)\n\}", ssa, re.S)
assert m, "keep_view not found in SSA"
body = m.group(1)

def trace_origin(fn_body, callee_substr, arg_idx):
    alloc_heap, add24, stores, loads, copies = set(), {}, {}, {}, {}
    for line in fn_body.splitlines():
        st = line.strip()
        mh = re.match(r"^(%\S+)\s*=l\s+call\s+\$pion_alloc_uninit\(w 24, w 4,", st)
        if mh: alloc_heap.add(mh.group(1)); continue
        ma = re.match(r"^(%\S+)\s*=l\s+add\s+(%\S+),\s*24$", st)
        if ma: add24[ma.group(1)] = ma.group(2); continue
        mc = re.match(r"^(%\S+)\s*=l\s+copy\s+(%\S+)$", st)
        if mc: copies[mc.group(1)] = mc.group(2); continue
        ms = re.match(r"^storel\s+(%\S+),\s*(%\S+)$", st)
        if ms: stores.setdefault(ms.group(2), set()).add(ms.group(1)); continue
        ml = re.match(r"^(%\S+)\s*=l\s+loadl\s+(%\S+)$", st)
        if ml: loads[ml.group(1)] = ml.group(2); continue
    mc = re.search(rf"call \$[^\s(]*{re.escape(callee_substr)}\(([^)]*)\)", fn_body)
    assert mc, f"call *{callee_substr} not found in:\n" + fn_body
    arg_reg = [a.strip().split()[-1] for a in mc.group(1).split(",")][arg_idx]
    seen, work = set(), [arg_reg]
    while work:
        cur = work.pop()
        if cur in seen: continue
        seen.add(cur)
        if cur in alloc_heap: return "heap"
        if cur in add24: return "stack"
        if cur in copies: work.append(copies[cur])
        if cur in loads:
            for v in stores.get(loads[cur], ()): work.append(v)
    return "unknown"

assert trace_origin(body, "Keeper__pick", 0) == "heap", "Keeper::pick arg0 MUST trace to heap:\n" + body
assert trace_origin(body, "Reader__pick", 0) == "stack", "Reader::pick arg0 should trace to stack:\n" + body
PY5
  if command -v node >/dev/null 2>&1; then
    PION_CACHE_DIR="$CAS_C5" "$PIONC" build --release --target wasm32 -o "$TMP_DIR/c5_${ORD}.wasm" "$TMP_DIR/c5/app${ORD}"
    WASM_C5=$(node "$WASM_RT" "$TMP_DIR/c5_${ORD}.wasm")
    test "$WASM_C5" = "c5_${ORD}=hello-keeper-123"
  fi
done
echo "p96 Case 5 OK (Reader::pick=stack vs Keeper::pick=heap verified by exact arg origin in both orders)"

# --- Case 6: Cross-package dependency alias collision (`app` `x -> safe_helper`, `bridge` `x -> keep_helper`) ---
# Verified on BOTH cold build (real source bodies in memory) AND hot CAS rebuild (bridge loaded from `.pionstub` `{ panic() }`).
mkdir -p "$TMP_DIR/c6/safe_helper/src" "$TMP_DIR/c6/keep_helper/src" "$TMP_DIR/c6/bridge/src" "$TMP_DIR/c6/app/src"
cat <<'P6' > "$TMP_DIR/c6/safe_helper/pion.toml"
[package]
name = "safe_helper"
version = "0.1.0"
P6
cat <<'P6' > "$TMP_DIR/c6/safe_helper/src/lib.pion"
pub fn inspect(v : StrView) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  acc + v.length()
}
P6
cat <<'P6' > "$TMP_DIR/c6/keep_helper/pion.toml"
[package]
name = "keep_helper"
version = "0.1.0"
P6
cat <<'P6' > "$TMP_DIR/c6/keep_helper/src/lib.pion"
pub fn inspect(v : StrView) -> StrView {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  if acc < 0 {
    return "".as_view()
  }
  v
}
P6
cat <<'P6' > "$TMP_DIR/c6/bridge/pion.toml"
[package]
name = "bridge"
version = "0.1.0"

[dependencies]
x = { package = "keep_helper", path = "../keep_helper" }
P6
cat <<'P6' > "$TMP_DIR/c6/bridge/src/lib.pion"
import "x"

pub fn forward(v : StrView) -> StrView {
  x::inspect(v)
}
P6
cat <<'P6' > "$TMP_DIR/c6/app/pion.toml"
[package]
name = "app_c6"
version = "0.1.0"

[dependencies]
x = { package = "safe_helper", path = "../safe_helper" }
bridge = { path = "../bridge" }
P6
cat <<'P6' > "$TMP_DIR/c6/app/src/main.pion"
import "x"
import "bridge"

fn run_fwd(s : String) -> StrView {
  let _ = x::inspect(s.as_view())
  bridge::forward(s.as_view())
}

fn clobber(n : Int) -> Int {
  let a = n * 13 + 7
  let b = a * 17 + 9
  a + b
}

pub fn main(w : World) -> Int {
  let s = "alias-bridge-" + "999"
  let v = run_fwd(s)
  let _ = clobber(77)
  io_println(w, "c6=" + v.to_string())
  0
}
P6
check_c6_ssa() {
  _ssa_file="$1"
  _label="$2"
  _want_safe="$3"
  python3 - "$_ssa_file" "$_label" "$_want_safe" <<'PY6'
import sys, re
ssa = open(sys.argv[1]).read()
lbl = sys.argv[2]
want_safe = sys.argv[3]
m = re.search(r"function [^\n]*fn_run_fwd\([^\n]*\)\s*\{(.*?)\n\}", ssa, re.S)
assert m, f"[{lbl}] run_fwd not found in SSA"
body = m.group(1)
alloc_heap, add24, stores, loads, copies = set(), {}, {}, {}, {}
for line in body.splitlines():
    st = line.strip()
    mh = re.match(r"^(%\S+)\s*=l\s+call\s+\$pion_alloc_uninit\(w 24, w 4,", st)
    if mh: alloc_heap.add(mh.group(1)); continue
    ma = re.match(r"^(%\S+)\s*=l\s+add\s+(%\S+),\s*24$", st)
    if ma: add24[ma.group(1)] = ma.group(2); continue
    mc = re.match(r"^(%\S+)\s*=l\s+copy\s+(%\S+)$", st)
    if mc: copies[mc.group(1)] = mc.group(2); continue
    ms = re.match(r"^storel\s+(%\S+),\s*(%\S+)$", st)
    if ms: stores.setdefault(ms.group(2), set()).add(ms.group(1)); continue
    ml = re.match(r"^(%\S+)\s*=l\s+loadl\s+(%\S+)$", st)
    if ml: loads[ml.group(1)] = ml.group(2); continue
def trace(callee_sub):
    mc = re.search(rf"call \$[^\s(]*{re.escape(callee_sub)}\(([^)]*)\)", body)
    assert mc, f"[{lbl}] call *{callee_sub} not found in:\n" + body
    arg_reg = [a.strip().split()[-1] for a in mc.group(1).split(",")][0]
    seen, work = set(), [arg_reg]
    while work:
        cur = work.pop()
        if cur in seen: continue
        seen.add(cur)
        if cur in alloc_heap: return "heap"
        if cur in add24: return "stack"
        if cur in copies: work.append(copies[cur])
        if cur in loads:
            for v in stores.get(loads[cur], ()): work.append(v)
    return "unknown"
fwd_orig = trace("fn_forward")
safe_orig = trace("fn_inspect")
assert fwd_orig == "heap", f"[{lbl}] bridge::forward arg0 MUST trace to heap, got {fwd_orig}:\n" + body
assert safe_orig == want_safe, f"[{lbl}] safe x::inspect arg0 expected {want_safe}, got {safe_orig}:\n" + body
PY6
}
CAS_C6="$TMP_DIR/cas_c6"
mkdir -p "$CAS_C6"
# Cold CAS build (all deps parsed from real source -> recursive alias resolution in `bridge::forward`)
PION_KEEP_NATIVE_SSA=1 PION_CACHE_DIR="$CAS_C6" "$PIONC" build --release -o "$TMP_DIR/c6_cold" "$TMP_DIR/c6/app"
OUT_C6_COLD=$("$TMP_DIR/c6_cold")
echo "p96 Case 6 cold CAS -> $OUT_C6_COLD"
test "$OUT_C6_COLD" = "c6=alias-bridge-999"
C6_COLD_SSA=$(ls -t $(grep -l "fn_run_fwd(" "$CAS_C6"/ssa/*.ssa) | head -n 1)
check_c6_ssa "$C6_COLD_SSA" "cold-source" "stack"
# Verify both bridge's and safe_helper's `.pionstub` files exist with `{ panic() }` placeholders
BRIDGE_STUB=$(grep -l "pub fn forward(v : StrView)" "$CAS_C6"/sig/*.pionstub | head -n 1)
test -n "$BRIDGE_STUB"
grep -q "panic()" "$BRIDGE_STUB"
SAFE_STUB=$(grep -l "pub fn inspect(v : StrView) -> Int" "$CAS_C6"/sig/*.pionstub | head -n 1)
test -n "$SAFE_STUB"
grep -q "panic()" "$SAFE_STUB"
# Hot CAS rebuild (app re-emits against cached `.pionstub`s: both `bridge::forward` & stubbed `safe_helper::inspect` must be heap)
printf '// hot rebuild\n' >> "$TMP_DIR/c6/app/src/main.pion"
PION_KEEP_NATIVE_SSA=1 PION_CACHE_DIR="$CAS_C6" "$PIONC" build --release -o "$TMP_DIR/c6_hot" "$TMP_DIR/c6/app"
OUT_C6_HOT=$("$TMP_DIR/c6_hot")
echo "p96 Case 6 hot CAS -> $OUT_C6_HOT"
test "$OUT_C6_HOT" = "c6=alias-bridge-999"
C6_HOT_SSA=$(ls -t $(grep -l "fn_run_fwd(" "$CAS_C6"/ssa/*.ssa) | head -n 1)
test "$C6_HOT_SSA" != "$C6_COLD_SSA"
check_c6_ssa "$C6_HOT_SSA" "hot-stub" "heap"
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$CAS_C6" "$PIONC" build --release --target wasm32 -o "$TMP_DIR/c6.wasm" "$TMP_DIR/c6/app"
  WASM_C6=$(node "$WASM_RT" "$TMP_DIR/c6.wasm")
  test "$WASM_C6" = "c6=alias-bridge-999"
fi
echo "p96 Case 6 OK (cold real-source stack/heap + hot stub conservative heap verified by exact arg origin)"

# --- Case 7: Enum variant constructor vs same-name static method, local enum == import alias, AND Option/Result == import alias ---
mkdir -p "$TMP_DIR/c7/dep/src" "$TMP_DIR/c7/shadow_dep/src" "$TMP_DIR/c7/opt_shadow/src" "$TMP_DIR/c7/res_shadow/src" "$TMP_DIR/c7/app/src"
cat <<'P7' > "$TMP_DIR/c7/dep/pion.toml"
[package]
name = "dep_ev"
version = "0.1.0"
P7
cat <<'P7' > "$TMP_DIR/c7/dep/src/lib.pion"
pub struct Pod2 {
  pub a : Int
  pub b : Int
}

pub enum Ev {
  WrapV(StrView)
  WrapP(Pod2)
}

pub fn Ev::WrapV(v : StrView) -> Int {
  v.length()
}

pub fn Ev::WrapP(p : Pod2) -> Int {
  p.a + p.b
}

pub fn Ev::peek_v(v : StrView) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  acc + v.length()
}

pub fn Ev::peek_p(p : Pod2) -> Int {
  let mut acc = p.a + p.b
  let mut i = 0
  while i < 2 {
    acc = acc + i
    i += 1
  }
  acc
}
P7
cat <<'P7' > "$TMP_DIR/c7/shadow_dep/pion.toml"
[package]
name = "shadow_dep"
version = "0.1.0"

[dependencies]
dep_ev = { path = "../dep" }
P7
cat <<'P7' > "$TMP_DIR/c7/shadow_dep/src/lib.pion"
import "dep_ev"

// Same-name read-only functions exported under alias `LocalEv` in app,
// taking the EXACT SAME `StrView` and 2-field POD `dep_ev::Pod2` types!
pub fn WrapV(v : StrView) -> Int {
  v.length()
}
pub fn WrapP(p : dep_ev::Pod2) -> Int {
  p.a + p.b
}
P7
cat <<'P7' > "$TMP_DIR/c7/opt_shadow/pion.toml"
[package]
name = "opt_shadow"
version = "0.1.0"
P7
cat <<'P7' > "$TMP_DIR/c7/opt_shadow/src/lib.pion"
// Read-only `Some(v : StrView)` exported under alias `Option` in app!
pub fn Some(v : StrView) -> Int {
  v.length()
}
P7
cat <<'P7' > "$TMP_DIR/c7/res_shadow/pion.toml"
[package]
name = "res_shadow"
version = "0.1.0"

[dependencies]
dep_ev = { path = "../dep" }
P7
cat <<'P7' > "$TMP_DIR/c7/res_shadow/src/lib.pion"
import "dep_ev"

// Read-only `Ok(p : dep_ev::Pod2)` exported under alias `Result` in app!
pub fn Ok(p : dep_ev::Pod2) -> Int {
  p.a + p.b
}
P7
cat <<'P7' > "$TMP_DIR/c7/app/pion.toml"
[package]
name = "app_c7"
version = "0.1.0"

[dependencies]
dep_ev = { path = "../dep" }
LocalEv = { package = "shadow_dep", path = "../shadow_dep" }
Option = { package = "opt_shadow", path = "../opt_shadow" }
Result = { package = "res_shadow", path = "../res_shadow" }
P7
cat <<'P7' > "$TMP_DIR/c7/app/src/main.pion"
import "dep_ev"
import "LocalEv"
import "Option"
import "Result"

// Local enum name `LocalEv` intentionally collides with import alias `LocalEv` (`shadow_dep`),
// AND defines read-only static methods `LocalEv::WrapV` / `LocalEv::WrapP` on the exact same
// `StrView` / `dep_ev::Pod2` payload types.
// Builtin `Option` / `Result` also collide with import aliases `Option` / `Result`.
// Enum variant constructor MUST win over both import alias and static method!
enum LocalEv {
  WrapV(StrView)
  WrapP(dep_ev::Pod2)
}

fn LocalEv::WrapV(v : StrView) -> Int {
  v.length()
}

fn LocalEv::WrapP(p : dep_ev::Pod2) -> Int {
  p.a + p.b
}

fn LocalEv::peek_v(v : StrView) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  acc + v.length()
}

fn LocalEv::peek_p(p : dep_ev::Pod2) -> Int {
  let mut acc = p.a + p.b
  let mut i = 0
  while i < 2 {
    acc = acc + i
    i += 1
  }
  acc
}

// Same-package read-only free functions shadowing unqualified builtin `Some` / `Ok` / `Err`.
// Builtin variant constructors MUST win over free functions (`types.pion:11296` / `qbe.pion:37206`).
fn Some(v : StrView) -> Int {
  v.length()
}

fn Ok(p : dep_ev::Pod2) -> Int {
  p.a + p.b
}

fn Err(p : dep_ev::Pod2) -> Int {
  p.a + p.b
}

fn check_ext_peek_p(k : Int) -> Int {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  dep_ev::Ev::peek_p(p)
}

fn make_local_v(s : String) -> LocalEv {
  let v = s.as_view()
  LocalEv::WrapV(v)
}

fn make_local_p(k : Int) -> LocalEv {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  LocalEv::WrapP(p)
}

fn make_ext_v(s : String) -> dep_ev::Ev {
  let _ = dep_ev::Ev::peek_v(s.as_view())
  let v = s.as_view()
  dep_ev::Ev::WrapV(v)
}

fn make_ext_p(k : Int) -> dep_ev::Ev {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  dep_ev::Ev::WrapP(p)
}

fn make_opt_v(s : String) -> Option[StrView] {
  let v = s.as_view()
  Option::Some(v)
}

fn make_res_p(k : Int) -> Result[dep_ev::Pod2, Int] {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  Result::Ok(p)
}

fn make_unqual_some_v(s : String) -> Option[StrView] {
  let v = s.as_view()
  Some(v)
}

fn make_unqual_ok_p(k : Int) -> Result[dep_ev::Pod2, dep_ev::Pod2] {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  Ok(p)
}

fn make_unqual_err_p(k : Int) -> Result[Int, dep_ev::Pod2] {
  let p = dep_ev::Pod2::{ a: k, b: k * 10 }
  Err(p)
}

fn clobber(x : Int) -> Int {
  let a = x * 5 + 1
  let b = a * 9 + 2
  a + b
}

pub fn main(w : World) -> Int {
  let s = "enum-var-" + "ok"
  let pk = check_ext_peek_p(2)
  let lv = make_local_v(s)
  let lp = make_local_p(3)
  let ev = make_ext_v(s)
  let ep = make_ext_p(4)
  let ov = make_opt_v(s)
  let rp = make_res_p(5)
  let us = make_unqual_some_v(s)
  let uo = make_unqual_ok_p(6)
  let ue = make_unqual_err_p(7)
  let _ = clobber(1234)
  let r1 = match lv { LocalEv::WrapV(v) => v.to_string(); _ => "bad" }
  let r2 = match lp { LocalEv::WrapP(p) => p.a * 100 + p.b; _ => -1 }
  let r3 = match ev { dep_ev::Ev::WrapV(v) => v.to_string(); _ => "bad" }
  let r4 = match ep { dep_ev::Ev::WrapP(p) => p.a * 100 + p.b; _ => -1 }
  let r5 = match ov { Some(v) => v.to_string(); None => "bad" }
  let r6 = match rp { Ok(p) => p.a * 100 + p.b; Err(_) => -1 }
  let r7 = match us { Some(v) => v.to_string(); None => "bad" }
  let r8 = match uo { Ok(p) => p.a * 100 + p.b; Err(_) => -1 }
  let r9 = match ue { Err(p) => p.a * 100 + p.b; Ok(_) => -1 }
  io_println(
    w,
    "c7=" +
    r1 +
    ":" +
    r2.to_string() +
    ":" +
    r3 +
    ":" +
    r4.to_string() +
    ":" +
    r5 +
    ":" +
    r6.to_string() +
    ":" +
    r7 +
    ":" +
    r8.to_string() +
    ":" +
    r9.to_string() +
    ":" +
    pk.to_string(),
  )
  0
}
P7
CAS_C7="$TMP_DIR/cas_c7"
mkdir -p "$CAS_C7"
PION_KEEP_NATIVE_SSA=1 PION_CACHE_DIR="$CAS_C7" "$PIONC" build --release -o "$TMP_DIR/c7_rel" "$TMP_DIR/c7/app"
OUT_C7=$("$TMP_DIR/c7_rel")
echo "p96 Case 7 native rel -> $OUT_C7"
test "$OUT_C7" = "c7=enum-var-ok:330:enum-var-ok:440:enum-var-ok:550:enum-var-ok:660:770:23"
C7_SSA=$(grep -l "fn_make_local_v(" "$CAS_C7"/ssa/*.ssa | head -n 1)
python3 - "$C7_SSA" <<'PY7'
import sys, re
ssa = open(sys.argv[1]).read()
def fn_b(name):
    m = re.search(rf"function [^\n]*fn_{name}\([^\n]*\)\s*\{{(.*?)\n\}}", ssa, re.S)
    assert m, f"{name} not found"
    return m.group(1)

def trace_enum_payload_and_peek(body, peek_sub):
    alloc_heap24, alloc_heap16, alloc_enum = set(), set(), set()
    add24, add8, stores, loads, copies = {}, {}, {}, {}, {}
    ret_regs = []
    for line in body.splitlines():
        st = line.strip()
        m24 = re.match(r"^(%\S+)\s*=l\s+call\s+\$pion_alloc_uninit\(w 24, w 4,", st)
        if m24: alloc_heap24.add(m24.group(1)); continue
        m16 = re.match(r"^(%\S+)\s*=l\s+call\s+\$pion_alloc_uninit\(w 16, w 4,", st)
        if m16: alloc_heap16.add(m16.group(1)); continue
        me = re.match(r"^(%\S+)\s*=l\s+call\s+\$pion_alloc(?:_uninit)?\(w \d+, w 5,", st)
        if me: alloc_enum.add(me.group(1)); continue
        ma = re.match(r"^(%\S+)\s*=l\s+add\s+(%\S+),\s*24$", st)
        if ma: add24[ma.group(1)] = ma.group(2); continue
        m8 = re.match(r"^(%\S+)\s*=l\s+add\s+(%\S+),\s*8$", st)
        if m8: add8[m8.group(1)] = m8.group(2); continue
        mc = re.match(r"^(%\S+)\s*=l\s+copy\s+(%\S+)$", st)
        if mc: copies[mc.group(1)] = mc.group(2); continue
        ms = re.match(r"^storel\s+(%\S+),\s*(%\S+)$", st)
        if ms: stores.setdefault(ms.group(2), set()).add(ms.group(1)); continue
        ml = re.match(r"^(%\S+)\s*=l\s+loadl\s+(%\S+)$", st)
        if ml: loads[ml.group(1)] = ml.group(2); continue
        mr = re.match(r"^ret\s+(%\S+)$", st)
        if mr: ret_regs.append(mr.group(1)); continue

    def origin(reg):
        seen, work = set(), [reg]
        while work:
            cur = work.pop()
            if cur in seen: continue
            seen.add(cur)
            if cur in alloc_heap24: return "heap24"
            if cur in alloc_heap16: return "heap16"
            if cur in add24: return "stack"
            if cur in copies: work.append(copies[cur])
            if cur in loads:
                for v in stores.get(loads[cur], ()): work.append(v)
        return "unknown"

    # Trace payload stored at `enum_obj + 8`
    enum_payload_orig = "unknown"
    for dst_ptr, base_reg in add8.items():
        if base_reg in alloc_enum:
            for stored_val in stores.get(dst_ptr, ()):
                o = origin(stored_val)
                if o != "unknown":
                    enum_payload_orig = o
    # Trace direct return value (for null-niche Option[StrView])
    ret_orig = "unknown"
    for rr in ret_regs:
        o = origin(rr)
        if o != "unknown":
            ret_orig = o
    # Trace arg0 passed to peek_v / peek_p (if present)
    peek_orig = None
    if peek_sub:
        mc = re.search(rf"call \$[^\s(]*{re.escape(peek_sub)}\(([^)]*)\)", body)
        assert mc, f"call *{peek_sub} not found in:\n" + body
        peek_orig = origin([a.strip().split()[-1] for a in mc.group(1).split(",")][0])
    return enum_payload_orig, ret_orig, peek_orig

b_lv = fn_b("make_local_v")
po_lv, _, _ = trace_enum_payload_and_peek(b_lv, None)
assert po_lv == "heap24", f"make_local_v enum payload MUST trace to heap24, got {po_lv}:\n" + b_lv

b_ev = fn_b("make_ext_v")
po_ev, _, pko_ev = trace_enum_payload_and_peek(b_ev, "peek_v")
assert po_ev == "heap24", f"make_ext_v enum payload MUST trace to heap24, got {po_ev}:\n" + b_ev
assert pko_ev == "stack", f"make_ext_v dep_ev::Ev::peek_v arg0 should trace to stack, got {pko_ev}:\n" + b_ev

for fn in ("make_local_p", "make_ext_p", "make_res_p", "make_unqual_ok_p", "make_unqual_err_p"):
    b = fn_b(fn)
    po, _, _ = trace_enum_payload_and_peek(b, None)
    assert po == "heap16", f"{fn} enum payload MUST trace to heap16, got {po}:\n" + b
    assert "alloc8 40" not in b, f"{fn} must NOT stack-promote POD passed to enum variant:\n" + b

# Null-niche Option[StrView] returns the StrView pointer directly -> trace `ret %r` to heap24
for fn in ("make_opt_v", "make_unqual_some_v"):
    b = fn_b(fn)
    _, ro, _ = trace_enum_payload_and_peek(b, None)
    assert ro == "heap24", f"{fn} null-niche Option::Some ret MUST trace to heap24, got {ro}:\n" + b

# Positive POD borrow check in its own isolated unambiguous function (dep_ev::Ev::peek_p)
b_pk = fn_b("check_ext_peek_p")
_, _, pk_orig = trace_enum_payload_and_peek(b_pk, "peek_p")
assert pk_orig == "stack", f"check_ext_peek_p dep_ev::Ev::peek_p arg0 should trace to stack, got {pk_orig}:\n" + b_pk
PY7
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$CAS_C7" "$PIONC" build --release --target wasm32 -o "$TMP_DIR/c7.wasm" "$TMP_DIR/c7/app"
  WASM_C7=$(node "$WASM_RT" "$TMP_DIR/c7.wasm")
  test "$WASM_C7" = "c7=enum-var-ok:330:enum-var-ok:440:enum-var-ok:550:enum-var-ok:660:770:23"
fi
echo "p96 Case 7 OK (enum variant & qualified/unqualified Option/Result beat aliases/free-fns; exact payload/ret verified)"
