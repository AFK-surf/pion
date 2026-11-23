#!/bin/sh
# Wave G Track G3-B (P85): Pure-scalar small enum / nested Result[Enum, E] SROA
# stack allocation + local single-use `let r = call(); match r`.
# Verifies:
#   1. Native release vs dev bit-for-bit identical output across:
#      - nested `match decode(...) { Ok(Complete(ok, n)) => ..., Ok(Incomplete) => ..., Err(e) => ... }`
#      - two-step `match decode(...) { Ok(st) => match st { ... }, Err(e) => ... }`
#      - `let st = decode(...)?; match st { ... }` (incl. repeated `Err(String)` paths)
#      - local single-use `let r = decode(...); match r { ... }`
#      - `Option[DecodeStatus]` scalarized match + `let st = opt_decode(...)?`
#      - escape fallbacks (returning enum, pushing into `Array[DecodeStatus]`, passing to helper)
#   2. Release SSA audit: 0 `$pion_alloc_uninit` in hot `Ok` paths + immortal header (`storeh 11,`).
#   3. ASan + LSan (0 leaks, 0 double-free, 0 stack UAF, 0 OOB read on unit variant).
#   4. Wasm32 (Node.js) bit-for-bit identical output.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/p85.pion" <<'PION'
pub enum DecodeStatus {
  Incomplete
  Complete(Bool, Int)
  TagOnly(Int64)
}

fn decode(tag : Int, ok : Bool, n : Int) -> Result[DecodeStatus, String] {
  if tag < 0 {
    return Err("err_" + tag.to_string())
  }
  if tag == 0 {
    return Ok(DecodeStatus::Incomplete)
  }
  Ok(DecodeStatus::Complete(ok, n))
}

fn opt_decode(tag : Int, ok : Bool, n : Int) -> Option[DecodeStatus] {
  if tag < 0 {
    return None
  }
  if tag == 0 {
    return Some(DecodeStatus::Incomplete)
  }
  if tag == 2 {
    return Some(DecodeStatus::TagOnly(n.to_int64()))
  }
  Some(DecodeStatus::Complete(ok, n))
}

fn hot_nested_match(tag : Int, ok : Bool, n : Int) -> Int {
  match decode(tag, ok, n) {
    Ok(DecodeStatus::Complete(flag, k)) => if flag { k * 2 + 1 } else { k * 2 }
    Ok(DecodeStatus::TagOnly(v)) => v.to_int()
    Ok(DecodeStatus::Incomplete) => -1
    Err(e) => -100 - e.length()
  }
}

fn hot_two_step_match(tag : Int, ok : Bool, n : Int) -> Int {
  match decode(tag, ok, n) {
    Ok(st) =>
      match st {
        DecodeStatus::Complete(flag, k) => if flag { k + 10 } else { k + 20 }
        DecodeStatus::TagOnly(v) => v.to_int() + 5
        DecodeStatus::Incomplete => -3
      }
    Err(e) => -200 - e.length()
  }
}

fn hot_try_let_match(tag : Int, ok : Bool, n : Int) -> Result[Int, String] {
  let st = decode(tag, ok, n)?
  match st {
    DecodeStatus::Complete(flag, k) => Ok(if flag { k + 100 } else { k + 200 })
    DecodeStatus::TagOnly(v) => Ok(v.to_int() + 300)
    DecodeStatus::Incomplete => Ok(0)
  }
}

fn hot_let_r_match(tag : Int, ok : Bool, n : Int) -> Int {
  let r = decode(tag, ok, n)
  match r {
    Ok(DecodeStatus::Complete(flag, k)) => if flag { k + 7 } else { k + 9 }
    Ok(DecodeStatus::TagOnly(v)) => v.to_int() + 11
    Ok(DecodeStatus::Incomplete) => -5
    Err(e) => -300 - e.length()
  }
}

fn hot_opt_match(tag : Int, ok : Bool, n : Int) -> Int {
  match opt_decode(tag, ok, n) {
    Some(DecodeStatus::Complete(flag, k)) => if flag { k + 3 } else { k }
    Some(DecodeStatus::Incomplete) => 1
    Some(DecodeStatus::TagOnly(v)) => v.to_int()
    None => -9
  }
}

fn inspect_escaped(st : DecodeStatus) -> Int {
  match st {
    DecodeStatus::Complete(flag, k) => if flag { k + 50 } else { k + 60 }
    DecodeStatus::TagOnly(v) => v.to_int()
    DecodeStatus::Incomplete => 7
  }
}

fn escape_cases(tag : Int, ok : Bool, n : Int) -> Int {
  let arr : Array[DecodeStatus] = []
  let s1 = match decode(tag, ok, n) {
    Ok(st) => {
      arr.push(st)
      inspect_escaped(arr[0])
    }
    Err(_) => -1
  }
  let s2 = match decode(tag, ok, n) {
    Ok(st) => inspect_escaped(st)
    Err(_) => -1
  }
  s1 + s2
}

pub fn main(world : World) -> Int {
  let mut acc = 0
  let mut err_cnt = 0
  let mut i = -5
  while i < 20 {
    let tag = if i < 0 { i } else { i % 3 }
    let ok = (i & 1) == 0
    acc = acc + hot_nested_match(tag, ok, i + 10)
    acc = acc + hot_two_step_match(tag, ok, i + 10)
    acc = acc + hot_let_r_match(tag, ok, i + 10)
    acc = acc + hot_opt_match(tag, ok, i + 10)
    acc = acc + escape_cases(tag, ok, i + 10)
    match hot_try_let_match(tag, ok, i + 10) {
      Ok(v) => acc = acc + v
      Err(e) => err_cnt = err_cnt + e.length()
    }
    i = i + 1
  }
  io_println(world, "p85 ok acc=" + acc.to_string() + " err=" + err_cnt.to_string())
  0
}
PION

"$PIONC" build --release --emit-ssa "$TMP_DIR/p85.ssa" -o "$TMP_DIR/p85_rel" "$TMP_DIR/p85.pion"
"$PIONC" build -o "$TMP_DIR/p85_dev" "$TMP_DIR/p85.pion"

REL_OUT="$("$TMP_DIR/p85_rel")"
DEV_OUT="$("$TMP_DIR/p85_dev")"
echo "p85 native release -> $REL_OUT"
echo "p85 native dev -> $DEV_OUT"
if [ "$REL_OUT" != "$DEV_OUT" ]; then
  echo "FAIL: p85 release vs dev mismatch: '$REL_OUT' vs '$DEV_OUT'" >&2
  exit 1
fi
case "$REL_OUT" in
  "p85 ok acc="*) ;;
  *) echo "FAIL: unexpected p85 output: $REL_OUT" >&2; exit 1 ;;
esac

# Release SSA audit: hot_nested_match, hot_two_step_match, hot_let_r_match, hot_opt_match have 0 $pion_alloc_uninit.
python3 - "$TMP_DIR/p85.ssa" <<'PYEOF'
import sys
ssa = open(sys.argv[1]).read()
funcs = ssa.split("function ")
want_zero = ["hot_nested_match(", "hot_two_step_match(", "hot_let_r_match(", "hot_opt_match("]
for name in want_zero:
    matched = [f for f in funcs if name in f.splitlines()[0]]
    assert matched, f"missing function {name}"
    body = matched[0]
    assert "$pion_alloc_uninit" not in body, f"{name} unexpectedly calls $pion_alloc_uninit:\n{body}"
    assert "storeh 11," in body, f"{name} missing immortal stack enum header:\n{body}"
print("p85 SSA audit: PASS (0 $pion_alloc_uninit + immortal header in all 4 hot functions)")
PYEOF

# ASan/LSan check (0 leaks, 0 UAF, 0 OOB read on unit variant).
CC_BIN="${CC:-cc}"
ASAN_RT="$TMP_DIR/libpionrt_asan.a"
"$CC_BIN" -std=c11 -O1 -g -fsanitize=address -fno-omit-frame-pointer \
  -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o"
ar rcs "$ASAN_RT" "$TMP_DIR/pion_rt_asan.o"
printf '#!/bin/sh\nexec %s -fsanitize=address -fno-omit-frame-pointer "$@"\n' "$CC_BIN" > "$TMP_DIR/cc-asan"
chmod +x "$TMP_DIR/cc-asan"
CC="$TMP_DIR/cc-asan" PION_RT_LIB="$ASAN_RT" PION_CACHE_DIR="$TMP_DIR/cas_asan" \
  "$PIONC" build --release -o "$TMP_DIR/p85_asan" "$TMP_DIR/p85.pion"
if [ "$(uname -s)" = "Linux" ]; then
  ASAN_OUT="$(ASAN_OPTIONS="detect_leaks=1:halt_on_error=1" "$TMP_DIR/p85_asan")"
else
  ASAN_OUT="$(ASAN_OPTIONS="halt_on_error=1" "$TMP_DIR/p85_asan")"
fi
echo "p85 ASan/LSan -> $ASAN_OUT"
if [ "$ASAN_OUT" != "$REL_OUT" ]; then
  echo "FAIL: p85 ASan output mismatch: '$ASAN_OUT' vs '$REL_OUT'" >&2
  exit 1
fi

# Wasm32 check (Node.js)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p85.wasm" "$TMP_DIR/p85.pion"
  WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85.wasm")"
  echo "p85 wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$REL_OUT" ]; then
    echo "FAIL: p85 wasm32 output mismatch: '$WASM_OUT' vs '$REL_OUT'" >&2
    exit 1
  fi
fi

echo "PASS: p85_enum_sroa (Native rel+dev + SSA 0 alloc + ASan/LSan + Wasm32)"
