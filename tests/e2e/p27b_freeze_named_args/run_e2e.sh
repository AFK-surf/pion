#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

UI_DIR="$TMP_DIR/uilib"
APP_DIR="$TMP_DIR/app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$UI_DIR/src" "$APP_DIR/src" "$CAS_DIR"

# Upstream package: pub fn / pub methods with named, optional, default & generic params
cat > "$UI_DIR/pion.toml" <<'EOF'
[package]
name = "uilib"
version = "0.1.0"
EOF

cat > "$UI_DIR/src/lib.pion" <<'EOF'
pub struct View {
  name : String
  w : Double
  h : Double
  bg : Int64
  tag : String
}

pub fn View::new(name : String, w~ : Double = 0.0, h~ : Double = 0.0) -> View {
  View::{ name: name, w: w, h: h, bg: 0L, tag: "" }
}

pub fn View::pad(self : View, x~ : Double = 0.0, y~ : Double = 0.0) -> View {
  View::{ name: self.name, w: self.w + x, h: self.h + y, bg: self.bg, tag: self.tag }
}

pub fn View::ground(self : View, color? : Int64, tag? : String) -> View {
  let c = match color {
    Some(v) => v
    None => self.bg
  }
  let t = match tag {
    Some(s) => s
    None => self.tag
  }
  View::{ name: self.name, w: self.w, h: self.h, bg: c, tag: t }
}

pub fn box(w~ : Double = 0.0, h~ : Double = 0.0, bg? : Int64, label? : String) -> String {
  let b = match bg {
    Some(v) => v.to_string()
    None => "none"
  }
  let l = match label {
    Some(s) => s
    None => "-"
  }
  "\{w.to_int()}x\{h.to_int()} bg=\{b} label=\{l}"
}

pub fn pick_opt[T](base : T, alt? : T) -> T {
  match alt {
    Some(v) => v
    None => base
  }
}
EOF

# Downstream app: cross-package named/optional/default calls + Bug #5 cyclic graph deep freeze
cat > "$APP_DIR/pion.toml" <<EOF
[package]
name = "p27b_app"
version = "0.1.0"

[dependencies]
uilib = { path = "$UI_DIR" }
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "uilib" as ui

struct DomNode {
  id : Int
  mut parent : Option[DomNode]
  mut children : Array[DomNode]
}

let GLOBAL_DOM : Array[DomNode] = []

fn scale(x : Double, factor~ : Double = 2.0, offset~ : Double = 0.0) -> Double {
  x * factor + offset
}

fn local_box(w~ : Double = 10.0, h~ : Double = 20.0, bg? : Int64, label? : String) -> String {
  let b = match bg {
    Some(v) => v.to_string()
    None => "none"
  }
  let l = match label {
    Some(s) => s
    None => "-"
  }
  "\{w.to_int()}x\{h.to_int()}:\{b}:\{l}"
}

fn main(world : World) -> Unit {
  // 1. Bug #5: Farview 7-line cyclic DOM graph pushed to module-level `let`
  let a = DomNode::{ id: 1, parent: None, children: [] }
  let b = DomNode::{ id: 2, parent: Some(a), children: [] }
  a.children.push(b)
  GLOBAL_DOM.push(a)
  debug_assert(GLOBAL_DOM.length() == 1 && GLOBAL_DOM[0].children[0].id == 2, "bug5 farview repro")

  // 2. Bug #5: 3-node deep cycle a -> b -> c -> a frozen via GLOBAL_DOM & Mutex, read across 4 threads
  let n1 = DomNode::{ id: 101, parent: None, children: [] }
  let n2 = DomNode::{ id: 202, parent: Some(n1), children: [] }
  let n3 = DomNode::{ id: 303, parent: Some(n2), children: [] }
  n1.children.push(n2)
  n2.children.push(n3)
  n3.children.push(n1)
  n1.parent = Some(n3)
  GLOBAL_DOM.push(n1)
  let mx : Mutex[DomNode] = Mutex::new(n1)
  let locked_root = mx.lock()
  debug_assert(locked_root.children[0].children[0].id == 303, "bug5 Mutex 3-node cycle")
  mx.unlock(locked_root)
  let acc = AtomicInt::new(0)
  scope(world, fn(s) -> Unit {
    let mut t = 0
    while t < 4 {
      spawn(s, fn() -> Unit {
        let root = GLOBAL_DOM[1]
        let c = root.children[0].children[0]
        let back_id = c.children[0].id
        let _ = acc.fetch_add(c.id + back_id)
      })
      t = t + 1
    }
  })
  debug_assert(acc.load() == 4 * (303 + 101), "bug5 3-node cycle MT concurrent read")

  // 3. Bug #5: Map[String, DomNode] cyclic freeze via Mutex
  let m : Map[String, DomNode] = Map::new()
  let m1 = DomNode::{ id: 11, parent: None, children: [] }
  let m2 = DomNode::{ id: 22, parent: Some(m1), children: [] }
  m1.children.push(m2)
  m.set("root", m1)
  let mmx : Mutex[Map[String, DomNode]] = Mutex::new(m)
  let mv = mmx.lock()
  let got_root = mv.get("root")
  debug_assert(got_root.is_some(), "bug5 map freeze")
  mmx.unlock(mv)

  // 4. Named & optional default params: same-package
  debug_assert(local_box() == "10x20:none:-", "local all defaults")
  debug_assert(local_box(bg=255L, w=120.0) == "120x20:255:-", "local out-of-order")
  let w = 64.0
  debug_assert(local_box(w~, label="btn") == "64x20:none:btn", "local punned")
  let opt_bg : Option[Int64] = Some(42L)
  let opt_none : Option[Int64] = None
  debug_assert(local_box(bg?=opt_bg) == "10x20:42:-", "local opt forward Some")
  debug_assert(local_box(bg?=opt_none) == "10x20:none:-", "local opt forward None")
  debug_assert((10.0 |> scale(factor=2.5)).to_int() == 25, "pipe with named arg")
  debug_assert((10.0 |> scale(offset=5.0)).to_int() == 25, "pipe with default + named")

  // 5. Cross-package named & optional default params + methods + generics (null-niche String)
  debug_assert(ui::box() == "0x0 bg=none label=-", "xpkg all defaults")
  debug_assert(ui::box(bg=255L, w=120.0) == "120x0 bg=255 label=-", "xpkg out-of-order")
  debug_assert(ui::box(w~, label="hello") == "64x0 bg=none label=hello", "xpkg punned + String")
  let opt_lbl : Option[String] = Some("fwd-str")
  let opt_lbl_none : Option[String] = None
  debug_assert(ui::box(bg?=opt_bg, label?=opt_lbl) == "0x0 bg=42 label=fwd-str", "xpkg opt forward Some String")
  debug_assert(ui::box(label?=opt_lbl_none) == "0x0 bg=none label=-", "xpkg opt forward None String")

  let v = ui::View::new("card", w=100.0).pad(x=12.0, y=8.0).ground(color=0xFFFFFFL, tag="primary")
  debug_assert(
    v.name == "card" && v.w.to_int() == 112 && v.h.to_int() == 8 && v.bg == 16777215L && v.tag == "primary",
    "xpkg method chain",
  )
  let v_def = ui::View::new("plain").pad().ground()
  debug_assert(v_def.w.to_int() == 0 && v_def.h.to_int() == 0 && v_def.bg == 0L, "xpkg method defaults")

  debug_assert(ui::pick_opt(10) == 10, "xpkg generic optional default")
  debug_assert(ui::pick_opt(10, alt=99) == 99, "xpkg generic optional Some")
  debug_assert(ui::pick_opt("a", alt="b") == "b", "xpkg generic optional String Some")

  io_println(world, "p27b_freeze_named_args ok")
}
EOF

OUT=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "p27b_freeze_named_args -> $OUT"
if [ "$OUT" != "p27b_freeze_named_args ok" ]; then
  echo "FAIL: p27b_freeze_named_args output mismatch: $OUT" >&2
  exit 1
fi
echo "[PASS] p27b_freeze_named_args (Bug #5 cyclic freeze + named/optional default params)"
