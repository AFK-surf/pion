#!/bin/sh
set -eu

# P31-C permanent E2E regression:
#   1. Leading-dot `.Variant` / `.Variant(args...)` inference (local & cross-pkg enums, Option, Result,
#      optional named param `align? : view::Along` with `align=.Middle`, bidirectional `==` / `!=`,
#      leading-dot patterns in `match` and `is`).
#   2. Pure compile-time desugared Pion-JSX (`<Tag ... />`, `<Tag ...>...</Tag>`, `<>...</>`,
#      cross-pkg `<lg::Chip .../>`, `in={root}`, boolean attrs `row`/`dot`/`moves_window`,
#      string & interpolated attrs `label="电量 \{pct}%"`, `={expr}`, `=>{stmts}`, `for`/`if` children,
#      View-returning child as last statement of `children` closure with P31-A Unit tail discard + RC dec,
#      `<For items={...} render={fn(item_v, v) { <lg::Chip in={item_v} .../> }} />` local parent override).
#   3. `pionc fmt --check --json` passes on the JSX source files.
#   4. Negative checks: `.Foo` without expected type -> E_TYPE_MISMATCH, `<Box></Row>` -> E_PARSE,
#      attribute `<Icon />` isolated from outer parent stack -> E_TYPE_MISMATCH.
# Verified on: Native Release + ASan/LSan (0 UAF, 0 leaks) + Wasm32 Node.js (identical checksum).

PIONC="${1:-}"
if [ -z "$PIONC" ] || [ ! -x "$PIONC" ]; then
  echo "usage: $0 <path-to-pionc>" >&2
  exit 1
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# Multi-package project: view + lg + app
PKG_DIR="$TMP_DIR/proj"
mkdir -p "$PKG_DIR/view/src" "$PKG_DIR/lg/src" "$PKG_DIR/app/src"

cat > "$PKG_DIR/view/pion.toml" <<'EOF'
[package]
name = "view"
version = "0.1.0"
EOF

cat > "$PKG_DIR/view/src/lib.pion" <<'EOF'
pub enum Along {
  Start
  Middle
  Between
  End
}

pub enum Size {
  Small
  Medium
  Large
}

pub enum Border {
  None
  Is(Bool)
}

pub struct View {
  pub id : Int
  pub kind : String
  pub children : Array[View]
  pub props : Array[String]
  pub mut on_press : Option[() -> Unit]
  pub mut text_fn : Option[() -> String]
  pub mut selected_fn : Option[() -> Bool]
}

pub struct Signal[T] {
  pub mut value : T
}

pub fn Signal::new[T](v : T) -> Signal[T] {
  Signal::{ value: v }
}

pub fn Signal::get[T](self : Signal[T]) -> T {
  self.value
}

pub fn Signal::set[T](self : Signal[T], v : T) -> Unit {
  self.value = v
}

pub fn along_name(a : Along) -> String {
  match a {
    .Start => "start"
    .Middle => "middle"
    .Between => "between"
    .End => "end"
  }
}

pub fn size_name(s : Size) -> String {
  match s {
    .Small => "sm"
    .Medium => "md"
    .Large => "lg"
  }
}

pub fn root_view() -> View {
  View::{
    id: 0,
    kind: "Root",
    children: [],
    props: [],
    on_press: .None,
    text_fn: .None,
    selected_fn: .None,
  }
}

pub fn make_child(parent : View, kind : String) -> View {
  let node = View::{
    id: parent.children.length() + 1,
    kind: kind,
    children: [],
    props: [],
    on_press: .None,
    text_fn: .None,
    selected_fn: .None,
  }
  parent.children.push(node)
  node
}

pub fn Box(
  parent : View,
  row~ : Bool = false,
  moves_window~ : Bool = false,
  height~ : Double = 0.0,
  along? : Along,
  align? : Along,
  border~ : Border = .None,
  children? : (View) -> Unit,
) -> View {
  let node = make_child(parent, "Box")
  if row {
    node.props.push("row")
  }
  if moves_window {
    node.props.push("moves_window")
  }
  if height > 0.0 {
    node.props.push("h=" + height.to_int().to_string())
  }
  match along {
    .Some(a) => node.props.push("along=" + along_name(a))
    .None => ()
  }
  match align {
    .Some(a) => node.props.push("align=" + along_name(a))
    .None => ()
  }
  match border {
    .Is(true) => node.props.push("border=true")
    _ => ()
  }
  match children {
    .Some(f) => f(node)
    .None => ()
  }
  node
}

pub fn Text(
  parent : View,
  label~ : String = "",
  size~ : Size = .Medium,
  text? : () -> String,
) -> View {
  let node = make_child(parent, "Text")
  if label.length() > 0 {
    node.props.push("label=" + label)
  }
  node.props.push("size=" + size_name(size))
  node.text_fn = text
  node
}

pub fn Badge(parent : View, label~ : String, dot~ : Bool = false) -> View {
  let node = make_child(parent, "Badge")
  node.props.push("label=" + label)
  if dot {
    node.props.push("dot")
  }
  node
}

pub fn Show(
  parent : View,
  when~ : () -> Bool,
  children? : (View) -> Unit,
) -> View {
  let node = make_child(parent, "Show")
  if when() {
    match children {
      .Some(f) => f(node)
      .None => ()
    }
  }
  node
}

pub fn For[T](
  parent : View,
  items~ : Array[T],
  render~ : (View, T) -> Unit,
) -> View {
  let list_node = make_child(parent, "For")
  for item in items {
    let slot = make_child(list_node, "Slot")
    render(slot, item)
  }
  list_node
}
EOF

cat > "$PKG_DIR/lg/pion.toml" <<'EOF'
[package]
name = "lg"
version = "0.1.0"

[dependencies]
view = { path = "../view" }
EOF

cat > "$PKG_DIR/lg/src/lib.pion" <<'EOF'
import "view"

pub fn Chip(
  parent : view::View,
  label~ : String,
  selected? : () -> Bool,
  on_press? : () -> Unit,
) -> view::View {
  let node = view::make_child(parent, "lg::Chip")
  node.props.push("label=" + label)
  node.selected_fn = selected
  node.on_press = on_press
  node
}
EOF

cat > "$PKG_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
view = { path = "../view" }
lg = { path = "../lg" }
EOF

cat > "$PKG_DIR/app/src/main.pion" <<'EOF'
import "view"
import "lg"

fn count_and_trigger(v : view::View, press_target : String) -> (Int, Int, Int) {
  let mut nodes = 1
  let mut selected_count = 0
  let mut text_len = 0
  match v.text_fn {
    .Some(f) => text_len += f().length()
    .None => ()
  }
  match v.selected_fn {
    .Some(f) => {
      if f() {
        selected_count += 1
      }
    }
    .None => ()
  }
  if press_target.length() > 0 && v.props.length() > 0 && v.props[0] == press_target {
    match v.on_press {
      .Some(cb) => cb()
      .None => ()
    }
  }
  for c in v.children {
    let (cn, cs, ct) = count_and_trigger(c, press_target)
    nodes += cn
    selected_count += cs
    text_len += ct
  }
  (nodes, selected_count, text_len)
}

fn check_dot_variants() -> Int {
  let a : view::Along = .Middle
  debug_assert(a == .Middle, "rhs dot variant eq")
  debug_assert(.Middle == a, "lhs dot variant eq")
  debug_assert(a != .Between, "rhs dot variant ne")
  debug_assert(.Start != a, "lhs dot variant ne")
  let opt : Option[Int] = .Some(41)
  let r : Result[Int, String] = .Ok(1)
  let v1 = match opt {
    .Some(x) => x
    .None => 0
  }
  let v2 = if r is .Ok(x) { x } else { 0 }
  v1 + v2
}

pub fn main(world : World) -> Int {
  let root = view::root_view()
  let dpi = view::Signal::new(800)
  let pct = 87
  let presets = [400, 800, 1600, 3200]
  let show_pro = true

  let _ = <view::Box
    in={root}
    row
    moves_window
    height={56.0}
    along={.Between}
    align={.Middle}
    border={.Is(true)}
  >
    <>
      <view::Text label="电量 \{pct}%" size={.Small} />
      <view::Text text=>{dpi.get().to_string()} size={.Large} />
    </>
    <view::Show when=>{show_pro}>
      for p in presets {
        <lg::Chip
          label="\{p}"
          selected=>{dpi.get() == p}
          on_press=>{
            dpi.set(p)
          }
        />
      }
    </view::Show>
    <view::For
      items={presets}
      render={fn(item_v, v) {
        <lg::Chip
          in={item_v}
          label="slot-\{v}"
          selected=>{dpi.get() == v}
          on_press=>{
            dpi.set(v)
          }
        />
      }}
    />
    if show_pro {
      <view::Badge label="PRO" dot />
    }
    <view::Badge label="TAIL" dot />
  </view::Box>

  // Verify <For> item_v override: each Slot child must own its own lg::Chip (not leaked to outer Box)
  let top_box = root.children[0]
  let for_node = top_box.children[3]
  debug_assert(for_node.kind == "For" && for_node.children.length() == 4, "For has 4 slots")
  debug_assert(for_node.children[2].children.length() == 1, "Slot[2] owns 1 Chip via in={item_v}")
  debug_assert(for_node.children[2].children[0].props[0] == "label=slot-1600", "Slot[2] Chip label")

  // First pass: dpi=800 -> 2 selected chips (one in Show, one in For)
  let (n1, s1, t1) = count_and_trigger(root, "label=slot-1600")
  debug_assert(dpi.get() == 1600, "on_press updated dpi signal to 1600")
  let (n2, s2, t2) = count_and_trigger(root, "")
  let dv = check_dot_variants()
  io_println(
    world,
    "p31c_jsx_dot ok n=" + n1.to_string() + "," + n2.to_string() +
    " sel=" + s1.to_string() + "," + s2.to_string() +
    " tlen=" + t1.to_string() + "," + t2.to_string() +
    " dpi=" + dpi.get().to_string() +
    " dv=" + dv.to_string(),
  )
  0
}
EOF

# 1. Verify pionc fmt --check --json passes on all JSX source files
FMT_CHK=$("$PIONC" fmt --check --json "$PKG_DIR/view" "$PKG_DIR/lg" "$PKG_DIR/app")
echo "p31c_jsx_dot fmt --check -> $FMT_CHK"
if ! printf '%s' "$FMT_CHK" | grep -q '"ok":true'; then
  echo "FAIL: p31c_jsx_dot fmt --check failed: $FMT_CHK" >&2
  exit 1
fi

# 2. Native Release run (multi-package)
"$PIONC" build --release -o "$TMP_DIR/p31c_rel" "$PKG_DIR/app"
REL_OUT=$("$TMP_DIR/p31c_rel")
echo "p31c_jsx_dot native release -> $REL_OUT"
EXPECTED="p31c_jsx_dot ok n=20,20 sel=2,2 tlen=3,4 dpi=1600 dv=42"
if [ "$REL_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p31c_jsx_dot native release expected '$EXPECTED', got '$REL_OUT'" >&2
  exit 1
fi

# 3. Negative checks
cat > "$TMP_DIR/bad_dot.pion" <<'EOF'
pub fn main() -> Int {
  let x = .Foo
  let _ = x
  0
}
EOF
BAD_DOT=$("$PIONC" check --json "$TMP_DIR/bad_dot.pion" || true)
if ! printf '%s' "$BAD_DOT" | grep -q '"code":"E_TYPE_MISMATCH"'; then
  echo "FAIL: expected E_TYPE_MISMATCH for untyped .Foo, got: $BAD_DOT" >&2
  exit 1
fi

cat > "$TMP_DIR/bad_jsx_close.pion" <<'EOF'
fn Box(children? : (Int) -> Unit) -> Unit { let _ = children }
pub fn main() -> Int {
  <Box></Row>
  0
}
EOF
BAD_CLOSE=$("$PIONC" check --json "$TMP_DIR/bad_jsx_close.pion" || true)
if ! printf '%s' "$BAD_CLOSE" | grep -q '"code":"E_PARSE"'; then
  echo "FAIL: expected E_PARSE for mismatched </Row>, got: $BAD_CLOSE" >&2
  exit 1
fi

cat > "$TMP_DIR/bad_jsx_attr_parent.pion" <<'EOF'
fn Icon(parent : Int) -> Int { parent }
fn Box(in_p : Int, icon~ : Int = 0, children? : (Int) -> Unit) -> Unit {
  let _ = in_p
  let _ = icon
  let _ = children
}
pub fn main() -> Int {
  <Box in={1}>
    <Box icon={<Icon />} />
  </Box>
  0
}
EOF
BAD_ATTR=$("$PIONC" check --json "$TMP_DIR/bad_jsx_attr_parent.pion" || true)
if ! printf '%s' "$BAD_ATTR" | grep -q '"code":"E_TYPE_MISMATCH"'; then
  echo "FAIL: expected E_TYPE_MISMATCH for <Icon /> inside JSX attr (must not inherit outer parent), got: $BAD_ATTR" >&2
  exit 1
fi
echo "p31c_jsx_dot negative checks (.Foo, </Row>, attr parent isolation): OK"

# 4. Single-file mirror for ASan/LSan + Wasm32 (identical checksum)
cat > "$TMP_DIR/p31c_single.pion" <<'EOF'
enum Along {
  Start
  Middle
  Between
  End
}

enum Size {
  Small
  Medium
  Large
}

enum Border {
  None
  Is(Bool)
}

struct View {
  id : Int
  kind : String
  children : Array[View]
  props : Array[String]
  mut on_press : Option[() -> Unit]
  mut text_fn : Option[() -> String]
  mut selected_fn : Option[() -> Bool]
}

struct Signal[T] {
  mut value : T
}

fn Signal::new[T](v : T) -> Signal[T] {
  Signal::{ value: v }
}

fn Signal::get[T](self : Signal[T]) -> T {
  self.value
}

fn Signal::set[T](self : Signal[T], v : T) -> Unit {
  self.value = v
}

fn along_name(a : Along) -> String {
  match a {
    .Start => "start"
    .Middle => "middle"
    .Between => "between"
    .End => "end"
  }
}

fn size_name(s : Size) -> String {
  match s {
    .Small => "sm"
    .Medium => "md"
    .Large => "lg"
  }
}

fn root_view() -> View {
  View::{
    id: 0,
    kind: "Root",
    children: [],
    props: [],
    on_press: .None,
    text_fn: .None,
    selected_fn: .None,
  }
}

fn make_child(parent : View, kind : String) -> View {
  let node = View::{
    id: parent.children.length() + 1,
    kind: kind,
    children: [],
    props: [],
    on_press: .None,
    text_fn: .None,
    selected_fn: .None,
  }
  parent.children.push(node)
  node
}

fn Box(
  parent : View,
  row~ : Bool = false,
  moves_window~ : Bool = false,
  height~ : Double = 0.0,
  along? : Along,
  align? : Along,
  border~ : Border = .None,
  children? : (View) -> Unit,
) -> View {
  let node = make_child(parent, "Box")
  if row { node.props.push("row") }
  if moves_window { node.props.push("moves_window") }
  if height > 0.0 { node.props.push("h=" + height.to_int().to_string()) }
  match along {
    .Some(a) => node.props.push("along=" + along_name(a))
    .None => ()
  }
  match align {
    .Some(a) => node.props.push("align=" + along_name(a))
    .None => ()
  }
  match border {
    .Is(true) => node.props.push("border=true")
    _ => ()
  }
  match children {
    .Some(f) => f(node)
    .None => ()
  }
  node
}

fn Text(
  parent : View,
  label~ : String = "",
  size~ : Size = .Medium,
  text? : () -> String,
) -> View {
  let node = make_child(parent, "Text")
  if label.length() > 0 { node.props.push("label=" + label) }
  node.props.push("size=" + size_name(size))
  node.text_fn = text
  node
}

fn Badge(parent : View, label~ : String, dot~ : Bool = false) -> View {
  let node = make_child(parent, "Badge")
  node.props.push("label=" + label)
  if dot { node.props.push("dot") }
  node
}

fn Show(parent : View, when~ : () -> Bool, children? : (View) -> Unit) -> View {
  let node = make_child(parent, "Show")
  if when() {
    match children {
      .Some(f) => f(node)
      .None => ()
    }
  }
  node
}

fn For[T](parent : View, items~ : Array[T], render~ : (View, T) -> Unit) -> View {
  let list_node = make_child(parent, "For")
  for item in items {
    let slot = make_child(list_node, "Slot")
    render(slot, item)
  }
  list_node
}

fn Chip(
  parent : View,
  label~ : String,
  selected? : () -> Bool,
  on_press? : () -> Unit,
) -> View {
  let node = make_child(parent, "Chip")
  node.props.push("label=" + label)
  node.selected_fn = selected
  node.on_press = on_press
  node
}

fn count_and_trigger(v : View, press_target : String) -> (Int, Int, Int) {
  let mut nodes = 1
  let mut selected_count = 0
  let mut text_len = 0
  match v.text_fn {
    .Some(f) => text_len += f().length()
    .None => ()
  }
  match v.selected_fn {
    .Some(f) => if f() { selected_count += 1 }
    .None => ()
  }
  if press_target.length() > 0 && v.props.length() > 0 && v.props[0] == press_target {
    match v.on_press {
      .Some(cb) => cb()
      .None => ()
    }
  }
  for c in v.children {
    let (cn, cs, ct) = count_and_trigger(c, press_target)
    nodes += cn
    selected_count += cs
    text_len += ct
  }
  (nodes, selected_count, text_len)
}

pub fn main(world : World) -> Int {
  let root = root_view()
  let dpi = Signal::new(800)
  let pct = 87
  let presets = [400, 800, 1600, 3200]
  let show_pro = true

  let _ = <Box
    in={root}
    row
    moves_window
    height={56.0}
    along={.Between}
    align={.Middle}
    border={.Is(true)}
  >
    <>
      <Text label="电量 \{pct}%" size={.Small} />
      <Text text=>{dpi.get().to_string()} size={.Large} />
    </>
    <Show when=>{show_pro}>
      for p in presets {
        <Chip
          label="\{p}"
          selected=>{dpi.get() == p}
          on_press=>{ dpi.set(p) }
        />
      }
    </Show>
    <For
      items={presets}
      render={fn(item_v, v) {
        <Chip
          in={item_v}
          label="slot-\{v}"
          selected=>{dpi.get() == v}
          on_press=>{ dpi.set(v) }
        />
      }}
    />
    if show_pro {
      <Badge label="PRO" dot />
    }
    <Badge label="TAIL" dot />
  </Box>

  let (n1, s1, t1) = count_and_trigger(root, "label=slot-1600")
  let (n2, s2, t2) = count_and_trigger(root, "")
  let a : Along = .Middle
  let dv = if a == .Middle && .Middle == a && .Start != a { 42 } else { 0 }
  io_println(
    world,
    "p31c_jsx_dot ok n=" + n1.to_string() + "," + n2.to_string() +
    " sel=" + s1.to_string() + "," + s2.to_string() +
    " tlen=" + t1.to_string() + "," + t2.to_string() +
    " dpi=" + dpi.get().to_string() +
    " dv=" + dv.to_string(),
  )
  0
}
EOF

CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p31c_single.o" "$TMP_DIR/p31c_single.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p31c_single.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p31c_asan"
  ASAN_OUT=$("$TMP_DIR/p31c_asan")
  echo "p31c_jsx_dot ASan/LSan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p31c_jsx_dot ASan/LSan mismatch or leak: '$ASAN_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p31c ASan check"
fi

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p31c_single.wasm" "$TMP_DIR/p31c_single.pion"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p31c_single.wasm")
  echo "p31c_jsx_dot wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p31c_jsx_dot wasm32 mismatch: expected '$EXPECTED', got '$WASM_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: node unavailable; skipping p31c wasm32 check"
fi

echo "PASS: p31c_jsx_dot"
