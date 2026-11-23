#!/usr/bin/env sh
# P73 E2E: Iterative worklist drop in pion_rc_dec (Native C + Wasm32 Node & Web + MT + ASan/LSan).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== P73 E2E: Deep RC Iterative Drop Worklist (Native + MT + ASan/LSan + Wasm32 Node & Web) ==="

cat > "$TMP_DIR/native_deep.pion" <<'EOF'
enum List {
  Nil
  Cons(Int, List)
}

struct AstNode {
  id : Int
  kids : Array[AstNode]
}

struct MapNode {
  id : Int
  m : Map[String, MapNode]
}

fn drop_deep_list(depth : Int) -> Int {
  let mut cur = List::Nil
  let mut i = 1
  while i <= depth {
    cur = List::Cons(i, cur)
    i = i + 1
  }
  match cur {
    Cons(v, _) => v
    Nil => 0
  }
}

fn drop_deep_ast(depth : Int) -> Int {
  let mut cur = AstNode::{ id: 0, kids: [] }
  let mut i = 1
  while i <= depth {
    let kids : Array[AstNode] = [cur]
    if i % 1000 == 0 {
      kids.push(AstNode::{ id: -i, kids: [] })
    }
    cur = AstNode::{ id: i, kids: kids }
    i = i + 1
  }
  cur.id
}

fn drop_deep_map(depth : Int) -> Int {
  let mut cur = MapNode::{ id: 0, m: Map([]) }
  let mut i = 1
  while i <= depth {
    let mp : Map[String, MapNode] = Map([])
    mp.set("next", cur)
    cur = MapNode::{ id: i, m: mp }
    i = i + 1
  }
  cur.id
}

fn spawn_worker(s : Scope, ch : Channel[Int], tid : Int) -> Unit {
  spawn(s, fn() -> Unit {
    let a = drop_deep_list(20000 + tid)
    let b = drop_deep_ast(20000 + tid)
    let c = drop_deep_map(5000 + tid)
    ch.send(a + b + c)
  })
}

pub fn main(world : World) -> Int {
  let r_list = drop_deep_list(50000)
  let r_ast = drop_deep_ast(50000)
  let r_map = drop_deep_map(10000)

  let ch : Channel[Int] = Channel::new(4)
  scope(world, fn(s : Scope) -> Unit {
    let mut t = 0
    while t < 4 {
      spawn_worker(s, ch, t)
      t = t + 1
    }
  })
  let mut mt_sum = 0
  let mut k = 0
  while k < 4 {
    match ch.recv() {
      Some(v) => mt_sum = mt_sum + v
      None => ()
    }
    k = k + 1
  }

  io_println(
    world,
    "p73_native:" +
    r_list.to_string() +
    ":" +
    r_ast.to_string() +
    ":" +
    r_map.to_string() +
    ":" +
    mt_sum.to_string(),
  )
  0
}
EOF

# Expected MT sum: sum_{t=0..3} ((20000+t) + (20000+t) + (5000+t)) = 4*45000 + 3*(0+1+2+3) = 180018
WANT_NAT="p73_native:50000:50000:10000:180018"
"$PIONC" build --release -o "$TMP_DIR/native_deep" "$TMP_DIR/native_deep.pion"
OUT_NAT="$("$TMP_DIR/native_deep")"
echo "1. Native release (50k List + 50k Ast + 10k Map + 4-thread MT) -> $OUT_NAT"
if [ "$OUT_NAT" != "$WANT_NAT" ]; then
  echo "FAIL: native_deep mismatch: expected '$WANT_NAT', got '$OUT_NAT'" >&2
  exit 1
fi

# 2. Native ASan/LSan (0 leaks across main thread + 4 worker threads)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$TMP_DIR/cas_asan" "$PIONC" build --emit-obj "$TMP_DIR/native_deep.o" "$TMP_DIR/native_deep.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/native_deep.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/native_deep_asan"
  OUT_ASAN="$("$TMP_DIR/native_deep_asan")"
  echo "2. Native ASan/LSan -> $OUT_ASAN"
  if [ "$OUT_ASAN" != "$WANT_NAT" ]; then
    echo "FAIL: native_deep ASan/LSan mismatch: expected '$WANT_NAT', got '$OUT_ASAN'" >&2
    exit 1
  fi
else
  echo "2. Native ASan/LSan -> skipped (host cc lacks -fsanitize=address)"
fi

# 3. Wasm32 (Node + Web runtimes): 10,000-deep List + AstNode + MapNode
cat > "$TMP_DIR/wasm_deep.pion" <<'EOF'
enum List {
  Nil
  Cons(Int, List)
}

struct AstNode {
  id : Int
  kids : Array[AstNode]
}

struct MapNode {
  id : Int
  m : Map[String, MapNode]
}

fn drop_deep_list(depth : Int) -> Int {
  let mut cur = List::Nil
  let mut i = 1
  while i <= depth {
    cur = List::Cons(i, cur)
    i = i + 1
  }
  match cur {
    Cons(v, _) => v
    Nil => 0
  }
}

fn drop_deep_ast(depth : Int) -> Int {
  let mut cur = AstNode::{ id: 0, kids: [] }
  let mut i = 1
  while i <= depth {
    let kids : Array[AstNode] = [cur]
    if i % 500 == 0 {
      kids.push(AstNode::{ id: -i, kids: [] })
    }
    cur = AstNode::{ id: i, kids: kids }
    i = i + 1
  }
  cur.id
}

fn drop_deep_map(depth : Int) -> Int {
  let mut cur = MapNode::{ id: 0, m: Map([]) }
  let mut i = 1
  while i <= depth {
    let mp : Map[String, MapNode] = Map([])
    mp.set("next", cur)
    cur = MapNode::{ id: i, m: mp }
    i = i + 1
  }
  cur.id
}

pub fn main(world : World) -> Int {
  let r_list = drop_deep_list(10000)
  let r_ast = drop_deep_ast(10000)
  let r_map = drop_deep_map(10000)
  io_println(
    world,
    "p73_wasm:" +
    r_list.to_string() +
    ":" +
    r_ast.to_string() +
    ":" +
    r_map.to_string(),
  )
  0
}
EOF

if command -v node >/dev/null 2>&1; then
  WASM_OUT="$TMP_DIR/wasm_deep.wasm"
  "$PIONC" build --release --target wasm32 -o "$WASM_OUT" "$TMP_DIR/wasm_deep.pion"
  PION_WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
  PION_WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
  for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
    node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const outLines = [];
const rt = createPionRuntime({
  print: (s) => outLines.push(s),
  println: (s) => outLines.push(s + "\n"),
});
const bytes = fs.readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
if ((rc | 0) !== 0) {
  console.error("FAIL (" + rtLabel + "): wasm_deep exited with", rc);
  process.exit(1);
}
const out = outLines.join("").trim();
const want = "p73_wasm:10000:10000:10000";
if (out !== want) {
  console.error("FAIL (" + rtLabel + "): wasm_deep mismatch: expected", want, "got", JSON.stringify(out));
  process.exit(1);
}
console.log("3. Wasm32 (" + rtLabel + ", 10k List + 10k Ast + 10k Map) -> " + out);
' "$WASM_OUT" "$rt_path"
  done
else
  echo "3. Wasm32 -> skipped (node not found)"
fi

echo "PASS: p73_deep_rc_drop"
