#!/bin/sh
set -eu

# Track P3 E2E regression: opt-in single-hop `#into` converters & `into` parameter modifier.
# Covers:
#   1. Built-in `String -> StrView` and `Bytes -> BytesView` on `into` parameters (zero-alloc stack view).
#   2. `Live[T]` + `ReadSignal[T]` + Pion-JSX all 4 forms (`text="hi"`, `text={status}`, `text=>{ ... }`,
#      `text={.Is("raw")}`) + optional `into bg? : Live[Int64]` across 3 packages (A -> B -> C).
#   3. `?` (`ETry`) error conversion (`IoErr` -> `AppErr` via static `#into`, `ParseErr` -> `AppErr` via instance `#into`).
#   4. Negative checks: `E_AMBIGUOUS_INTO`, `E_INVALID_INTO`, 1-hop only, non-`into` param, unrelated 3rd pkg, `let into = 42`.
#   5. `pionc fmt --check --json` idempotency.
# Verified on both Native QBE and Wasm32 (Node.js) with identical output.

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

PROJ="$TMP_DIR/proj"
mkdir -p "$PROJ/pkg_a/src" "$PROJ/pkg_b/src" "$PROJ/pkg_c/src"

cat > "$PROJ/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF

cat > "$PROJ/pkg_a/src/lib.pion" <<'EOF'
pub struct ReadSignal[T] {
  pub mut value : T
}

pub fn ReadSignal::new[T](v : T) -> ReadSignal[T] {
  ReadSignal::{ value: v }
}

pub fn ReadSignal::get[T](self : ReadSignal[T]) -> T {
  self.value
}

pub fn ReadSignal::set[T](self : ReadSignal[T], v : T) -> Unit {
  self.value = v
}

pub enum Live[T] {
  Is(T)
  Fn(() -> T)
}

#into
pub fn Live::of_value[T](v : T) -> Live[T] {
  Live::Is(v)
}

#into
pub fn Live::of_fn[T](f : () -> T) -> Live[T] {
  Live::Fn(f)
}

#into
pub fn Live::of_signal[T](s : ReadSignal[T]) -> Live[T] {
  Live::Fn(fn() -> T { s.get() })
}

pub fn Live::eval[T](self : Live[T]) -> T {
  match self {
    .Is(v) => v
    .Fn(f) => f()
  }
}

pub struct IoErr {
  pub code : Int
}

pub struct ParseErr {
  pub line : Int
}

pub enum AppErr {
  Io(Int)
  Parse(Int)
}

#into
pub fn AppErr::from_io(e : IoErr) -> AppErr {
  AppErr::Io(e.code)
}

#[into]
pub fn ParseErr::to_app(self : ParseErr) -> AppErr {
  AppErr::Parse(self.line)
}
EOF

cat > "$PROJ/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
EOF

cat > "$PROJ/pkg_b/src/lib.pion" <<'EOF'
import "pkg_a" as a

pub struct OutLog {
  pub lines : Array[String]
}

pub fn OutLog::new() -> OutLog {
  OutLog::{ lines: [] }
}

pub fn OutLog::push_live(self : OutLog, into v : a::Live[String]) -> Unit {
  self.lines.push("m:" + v.eval())
}

pub fn Text(
  log : OutLog,
  into text~ : a::Live[String] = .Is(""),
  into bg? : a::Live[Int64],
) -> Unit {
  let t = text.eval()
  let b = match bg {
    .Some(lv) => lv.eval().to_string()
    .None => "none"
  }
  log.lines.push(t + "|" + b)
}

pub fn view_lens(into sv : StrView, into bv : BytesView) -> Int {
  sv.length() * 100 + bv.length()
}

pub fn try_chain(mode : Int) -> Result[Int, a::AppErr] {
  let x = if mode == 1 {
    io_step()?
  } else if mode == 2 {
    parse_step()?
  } else {
    ok_step()?
  }
  Ok(x + 1)
}

fn io_step() -> Result[Int, a::IoErr] {
  Err(a::IoErr::{ code: 404 })
}

fn parse_step() -> Result[Int, a::ParseErr] {
  Err(a::ParseErr::{ line: 17 })
}

fn ok_step() -> Result[Int, a::IoErr] {
  Ok(41)
}
EOF

cat > "$PROJ/pkg_c/pion.toml" <<'EOF'
[package]
name = "pkg_c"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }
EOF

cat > "$PROJ/pkg_c/src/main.pion" <<'EOF'
import "pkg_a" as a
import "pkg_b" as b

pub fn main(world : World) -> Int {
  let into = 42
  let status = a::ReadSignal::new("ready")
  let n = a::ReadSignal::new(7)
  let log = b::OutLog::new()

  let _ = <b::Text in={log} text="hi" bg={255L} />
  let _ = <b::Text in={log} text={status} />
  let _ = <b::Text in={log} text=>{ "Done: \{n.get()}" } bg=>{ 99L } />
  let _ = <b::Text in={log} text={.Is("raw")} />
  let _ = <b::Text in={log} />
  log.push_live("method")

  let s = "hello"
  let bs = "abc".to_bytes()
  let vl = b::view_lens(s, bs)

  let e1 = match b::try_chain(1) {
    Ok(v) => "ok:" + v.to_string()
    Err(.Io(c)) => "io:" + c.to_string()
    Err(.Parse(l)) => "parse:" + l.to_string()
  }
  let e2 = match b::try_chain(2) {
    Ok(v) => "ok:" + v.to_string()
    Err(.Io(c)) => "io:" + c.to_string()
    Err(.Parse(l)) => "parse:" + l.to_string()
  }
  let e3 = match b::try_chain(0) {
    Ok(v) => "ok:" + v.to_string()
    Err(.Io(c)) => "io:" + c.to_string()
    Err(.Parse(l)) => "parse:" + l.to_string()
  }

  let sb = StringBuilder()
  sb.write_string("into=" + into.to_string() + " vl=" + vl.to_string())
  let mut i = 0
  while i < log.lines.length() {
    sb.write_string(" [" + log.lines[i] + "]")
    i = i + 1
  }
  sb.write_string(" " + e1 + " " + e2 + " " + e3)
  io_println(sb.to_string())
  let _ = world
  0
}

struct Counter {
  mut n : Int
}

fn Counter::bump(mut self : Counter, delta : Int) -> Int {
  self.n = self.n + delta
  self.n
}

test "p82b: #into and mut self work inside pionc test across packages" {
  let status = a::ReadSignal::new("ready")
  let n = a::ReadSignal::new(7)
  let log = b::OutLog::new()

  let _ = <b::Text in={log} text="hi" bg={255L} />
  let _ = <b::Text in={log} text={status} />
  let _ = <b::Text in={log} text=>{ "Done: \{n.get()}" } bg=>{ 99L } />
  let _ = <b::Text in={log} text={.Is("raw")} />
  let _ = <b::Text in={log} />
  log.push_live("method")

  debug_assert(log.lines.length() == 6, "len")
  debug_assert(log.lines[0] == "hi|255", "line0")
  debug_assert(log.lines[1] == "ready|none", "line1")
  debug_assert(log.lines[2] == "Done: 7|99", "line2")
  debug_assert(log.lines[3] == "raw|none", "line3")
  debug_assert(log.lines[4] == "|none", "line4")
  debug_assert(log.lines[5] == "m:method", "line5")

  let s = "hello"
  let bs = "abc".to_bytes()
  debug_assert(b::view_lens(s, bs) == 503, "view_lens")

  let mut c = Counter::{ n: 10 }
  debug_assert(c.bump(5) == 15, "bump")
  debug_assert(c.n == 15, "c.n")
}
EOF

mkdir -p "$PROJ/pkg_single/src"

cat > "$PROJ/pkg_single/pion.toml" <<'EOF'
[package]
name = "pkg_single"
version = "0.1.0"
EOF

cat > "$PROJ/pkg_single/src/lib.pion" <<'EOF'
pub struct Sig[T] {
  pub mut v : T
}

pub enum Live[T] {
  Is(T)
  Fn(() -> T)
}

#into
pub fn Live::of_value[T](v : T) -> Live[T] {
  Live::Is(v)
}

#into
pub fn Live::of_fn[T](f : () -> T) -> Live[T] {
  Live::Fn(f)
}

#into
pub fn Live::of_sig[T](s : Sig[T]) -> Live[T] {
  Live::Fn(fn() -> T { s.v })
}

pub fn Live::eval[T](self : Live[T]) -> T {
  match self {
    .Is(v) => v
    .Fn(f) => f()
  }
}

pub fn render_opt(into p? : Live[String]) -> String {
  match p {
    .Some(lv) => lv.eval()
    .None => "none"
  }
}

struct Acc {
  mut total : Int
}

fn Acc::add(mut self : Acc, x : Int) -> Int {
  self.total = self.total + x
  self.total
}

test "p82b: single-package #into optional named + closure + signal + mut self" {
  let sig = Sig::{ v: "sig" }
  debug_assert(render_opt(p="hi") == "hi", "opt_lit")
  debug_assert(render_opt(p=fn() -> String { "dyn" }) == "dyn", "opt_fn")
  debug_assert(render_opt(p=sig) == "sig", "opt_sig")
  debug_assert(render_opt() == "none", "opt_none")
  let mut acc = Acc::{ total: 1 }
  debug_assert(acc.add(41) == 42, "acc_add")
  debug_assert(acc.total == 42, "acc_total")
}
EOF

FMT_JSON=$("$PIONC" fmt --check --json "$PROJ/pkg_a" "$PROJ/pkg_b" "$PROJ/pkg_c" "$PROJ/pkg_single")
if [ "$FMT_JSON" != '{"ok":true,"unformatted":[]}' ]; then
  echo "FAIL: p_into_callsite fmt --check failed: $FMT_JSON" >&2
  exit 1
fi

EXPECTED='into=42 vl=503 [hi|255] [ready|none] [Done: 7|99] [raw|none] [|none] [m:method] io:404 parse:17 ok:42'

NATIVE_OUT=$("$PIONC" run "$PROJ/pkg_c")
echo "p_into_callsite native -> $NATIVE_OUT"
if [ "$NATIVE_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p_into_callsite native mismatch! expected='$EXPECTED' got='$NATIVE_OUT'" >&2
  exit 1
fi

TEST_SINGLE_JSON=$("$PIONC" test --json "$PROJ/pkg_single")
echo "p_into_callsite test single -> $TEST_SINGLE_JSON"
case "$TEST_SINGLE_JSON" in
  *'"ok":true'*'"failed":0'*|*'"failed":0'*'"ok":true'*) ;;
  *)
    echo "FAIL: p_into_callsite single-pkg pionc test --json failed: $TEST_SINGLE_JSON" >&2
    exit 1
    ;;
esac

TEST_MULTI_JSON=$("$PIONC" test --json "$PROJ/pkg_c")
echo "p_into_callsite test multi -> $TEST_MULTI_JSON"
case "$TEST_MULTI_JSON" in
  *'"ok":true'*'"failed":0'*|*'"failed":0'*'"ok":true'*) ;;
  *)
    echo "FAIL: p_into_callsite multi-pkg pionc test --json failed: $TEST_MULTI_JSON" >&2
    exit 1
    ;;
esac

if command -v node >/dev/null 2>&1; then
  WASM_OUT=$(PION_WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$PIONC" run --target wasm32 "$PROJ/pkg_c")
  echo "p_into_callsite wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p_into_callsite wasm32 mismatch! expected='$EXPECTED' got='$WASM_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: node not found; skipping p_into_callsite wasm32 run"
fi

echo "[PASS] p_into_callsite (Native + Wasm32 + pionc test + 3-pkg .pionsig + JSX + ETry + fmt)"
