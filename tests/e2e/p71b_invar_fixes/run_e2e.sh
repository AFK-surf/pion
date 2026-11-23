#!/bin/sh
# P71-B E2E regression: Invar #1 (tuple Option[String] match + Mesh::open_k exact repro),
# #2 (user fn strictly precedes builtin), #3 (E_DUP_DEF across files),
# #6 (panic/abort prints full msg on Native + Wasm32), and T5 (math_log1p).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1. Multi-package Mesh::open_k exact repro + all #1/#2/T5 runtime checks (Native + Wasm32) ---
mkdir -p "$TMP_DIR/ws/codec/src" "$TMP_DIR/ws/app/src"

cat <<'EOF' > "$TMP_DIR/ws/codec/pion.toml"
[package]
name = "codec"
version = "0.1.0"
EOF

cat <<'EOF' > "$TMP_DIR/ws/codec/src/lib.pion"
pub enum Json {
  JNull
  JStr(String)
  JNum(Int)
}

pub fn json_tag(j : Json) -> String {
  match j {
    Json::JNull => "null"
    Json::JStr(s) => s
    Json::JNum(n) => n.to_string()
  }
}
EOF

cat <<'EOF' > "$TMP_DIR/ws/app/pion.toml"
[package]
name = "app"
version = "0.1.0"

[dependencies]
codec = { path = "../codec" }
EOF

cat <<'EOF' > "$TMP_DIR/ws/app/src/main.pion"
import "codec" as codec

struct Mesh {
  endpoint : codec::Json
}

fn Mesh::relays_for(self : Mesh, place : String) -> Array[String] {
  [place + "-r0"]
}

fn Mesh::ips(self : Mesh, place : String) -> Array[String] {
  [place + "-ip0"]
}

fn Mesh::said_at(self : Mesh, place : String, kind : String) -> Array[String] {
  [place + "-" + kind]
}

fn relay_host(p : String) -> String {
  "h(" + p + ")"
}

// Variant A: exact Mesh::open_k with explicit type annotation + cross-pkg codec::Json
fn Mesh::open_k_annotated(self : Mesh, place : String, on : Option[(String, codec::Json)]) -> String {
  let lan_name = "lan"
  let tailnet_name = "tailnet"
  let (pin, endpoint, relays, ips) : (Option[String], codec::Json, Array[String], Array[String]) = match on {
    None => (None, self.endpoint, self.relays_for(place), self.ips(place))
    Some((kind, ep)) => if kind == lan_name || kind == tailnet_name {
      (Some(kind), ep, [], self.said_at(place, kind))
    } else {
      (Some(kind), ep, [kind], [])
    }
  }
  let via = match pin {
    None => if ips.length() > 0 { "main+addresses" } else { "main" }
    Some(p) => if p == lan_name || p == tailnet_name { p } else { "relay:" + relay_host(p) }
  }
  via + "|" + codec::json_tag(endpoint) + "|" + relays.length().to_string() + "|" + ips.length().to_string()
}

// Variant B: unannotated let-tuple with None first, then Some + nested if/else with []
fn Mesh::open_k_unannotated(self : Mesh, place : String, on : Option[(String, codec::Json)]) -> String {
  let lan_name = "lan"
  let tailnet_name = "tailnet"
  let (pin, endpoint, relays, ips) = match on {
    None => (None, self.endpoint, self.relays_for(place), self.ips(place))
    Some((kind, ep)) => if kind == lan_name || kind == tailnet_name {
      (Some(kind), ep, [], self.said_at(place, kind))
    } else {
      (Some(kind), ep, [kind], [])
    }
  }
  let via = match pin {
    None => if ips.length() > 0 { "main+addresses" } else { "main" }
    Some(p) => if p == lan_name || p == tailnet_name { p } else { "relay:" + relay_host(p) }
  }
  via + "|" + codec::json_tag(endpoint) + "|" + relays.length().to_string() + "|" + ips.length().to_string()
}

// Variant C: switch fast path (>= 6 arms) returning (Bool, Option[String], Int, Int)
// plus complementary (Option[String], Option[String])
fn switch_tuple_opt(code : Int) -> (Bool, Option[String], Int, Int) {
  let res = match code {
    0 => (false, None, 0, 10)
    1 => (true, Some("one"), 1, 11)
    2 => (false, None, 2, 12)
    3 => (true, Some("three"), 3, 13)
    4 => (false, None, 4, 14)
    5 => (true, Some("five"), 5, 15)
    _ => (true, Some("other"), code, 99)
  }
  res
}

fn complementary_opts(flag : Bool) -> (Option[String], Option[String]) {
  let pair = match flag {
    true => (None, Some("right"))
    false => (Some("left"), None)
  }
  pair
}

// Invar #2: user-defined sha256_hex(Bytes) must strictly precede builtin sha256_hex(String)
pub fn sha256_hex(b : Bytes) -> String {
  "user-sha:" + b.length().to_string()
}

fn main(world : World) -> Unit {
  let m = Mesh::{ endpoint: codec::Json::JStr("ep0") }
  let a0 = m.open_k_annotated("p", None)
  let a1 = m.open_k_annotated("p", Some(("lan", codec::Json::JStr("ep1"))))
  let a2 = m.open_k_annotated("p", Some(("r9", codec::Json::JNum(9))))
  let b0 = m.open_k_unannotated("p", None)
  let b1 = m.open_k_unannotated("p", Some(("tailnet", codec::Json::JStr("ep2"))))
  let b2 = m.open_k_unannotated("p", Some(("r7", codec::Json::JNull)))

  let (f0, o0, _, _) = switch_tuple_opt(0)
  let (f1, o1, _, _) = switch_tuple_opt(1)
  let (f9, o9, _, _) = switch_tuple_opt(9)
  let s0 = match o0 {
    None => "N"
    Some(x) => "S:" + x
  }
  let s1 = match o1 {
    None => "N"
    Some(x) => "S:" + x
  }
  let s9 = match o9 {
    None => "N"
    Some(x) => "S:" + x
  }

  let (c1a, c1b) = complementary_opts(true)
  let (c2a, c2b) = complementary_opts(false)
  let cs = (match c1a { None => "N"; Some(x) => x }) + "," +
    (match c1b { None => "N"; Some(x) => x }) + "," +
    (match c2a { None => "N"; Some(x) => x }) + "," +
    (match c2b { None => "N"; Some(x) => x })

  let raw = Bytes::new(4)
  let uh = sha256_hex(raw)

  let m0 = math_exp(0.0) + math_log(1.0) + math_log1p(0.0)
  let m1 = math_log1p(1.0)
  let log1p_ok = m0 > 0.999999 && m0 < 1.000001 && m1 > 0.693146 && m1 < 0.693148

  io_println(
    world,
    a0 + " ; " + a1 + " ; " + a2 + " ; " +
    b0 + " ; " + b1 + " ; " + b2 + " ; " +
    f0.to_string() + ":" + s0 + "," + f1.to_string() + ":" + s1 + "," + f9.to_string() + ":" + s9 + " ; " +
    cs + " ; " + uh + " ; log1p=" + log1p_ok.to_string()
  )
}
EOF

EXPECTED="main+addresses|ep0|1|1 ; lan|ep1|0|1 ; relay:h(r9)|9|1|0 ; main+addresses|ep0|1|1 ; tailnet|ep2|0|1 ; relay:h(r7)|null|1|0 ; false:N,true:S:one,true:S:other ; N,right,left,N ; user-sha:4 ; log1p=true"

(cd "$TMP_DIR/ws/app" && "$PIONC" build --release -o "$TMP_DIR/p71b_native" .)
OUT_NATIVE=$("$TMP_DIR/p71b_native")
echo "p71b native -> $OUT_NATIVE"
test "$OUT_NATIVE" = "$EXPECTED"

(cd "$TMP_DIR/ws/app" && "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p71b.wasm" .)
OUT_WASM=$(node "$WASM_RT" "$TMP_DIR/p71b.wasm")
echo "p71b wasm32 -> $OUT_WASM"
test "$OUT_WASM" = "$EXPECTED"

# --- 2. Invar #3: cross-file duplicate top-level fn -> E_DUP_DEF ---
mkdir -p "$TMP_DIR/dup_pkg/src"
cat <<'EOF' > "$TMP_DIR/dup_pkg/pion.toml"
[package]
name = "dup_pkg"
version = "0.1.0"
EOF
cat <<'EOF' > "$TMP_DIR/dup_pkg/src/a.pion"
pub fn dup_fn(x : Int) -> Int {
  x + 1
}
EOF
cat <<'EOF' > "$TMP_DIR/dup_pkg/src/b.pion"
pub fn dup_fn(x : Int) -> Int {
  x + 2
}
EOF
set +e
DUP_JSON=$(cd "$TMP_DIR/dup_pkg" && "$PIONC" check --json .)
DUP_RC=$?
set -e
echo "p71b dup_def rc=$DUP_RC -> $DUP_JSON"
test "$DUP_RC" -ne 0
echo "$DUP_JSON" | grep -q '"E_DUP_DEF"'
echo "$DUP_JSON" | grep -q 'a.pion:1'

# --- 3. Invar #6: panic(msg) prints full dynamic message on Native & Wasm32 ---
cat <<'EOF' > "$TMP_DIR/panic_msg.pion"
fn main(world : World) -> Unit {
  panic("invar_reason_42: " + (40 + 2).to_string())
}
EOF
"$PIONC" build --release -o "$TMP_DIR/panic_native" "$TMP_DIR/panic_msg.pion"
set +e
PANIC_NAT_ERR=$("$TMP_DIR/panic_native" 2>&1 >/dev/null)
PANIC_NAT_RC=$?
set -e
echo "p71b panic native rc=$PANIC_NAT_RC -> $PANIC_NAT_ERR"
test "$PANIC_NAT_RC" -ne 0
echo "$PANIC_NAT_ERR" | grep -q "invar_reason_42: 42"

"$PIONC" build --release --target wasm32 -o "$TMP_DIR/panic.wasm" "$TMP_DIR/panic_msg.pion"
set +e
PANIC_WASM_ERR=$(node "$WASM_RT" "$TMP_DIR/panic.wasm" 2>&1 >/dev/null)
PANIC_WASM_RC=$?
set -e
echo "p71b panic wasm32 rc=$PANIC_WASM_RC -> $PANIC_WASM_ERR"
test "$PANIC_WASM_RC" -ne 0
echo "$PANIC_WASM_ERR" | grep -q "invar_reason_42: 42"

echo "PASS: p71b_invar_fixes (Native + Wasm32)"
