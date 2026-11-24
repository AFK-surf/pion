#!/usr/bin/env sh
# P85 E2E: Compact 4-byte Array/FixedArray for Int, UInt, Char
#          (Native dev + release + SSA audit + RSS + ASan/LSan + Wasm32 Node & Web).
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

echo "=== P85 E2E: Compact 4B Array/FixedArray[Int | UInt | Char] ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
fn generic_first_last[T](xs : Array[T]) -> (T, T) {
  (xs[0], xs[xs.length() - 1])
}

fn generic_push_pop[T](xs : Array[T], v : T) -> Option[T] {
  xs.push(v)
  xs.pop()
}

fn unroll_fill_i32(a : Array[Int], v : Int) -> Int {
  let mut i = 0
  let n = a.length()
  while i < n {
    a[i] = v
    i += 1
  }
  a[0] + a[n - 1]
}

fn unroll_fill_u32(a : FixedArray[UInt], v : UInt) -> UInt {
  let mut i = 0
  let n = a.length()
  while i < n {
    a[i] = v
    i += 1
  }
  a[0] ^ a[n - 1]
}

fn unroll_fill_char(a : Array[Char], c : Char) -> Int {
  let mut i = 0
  let n = a.length()
  while i < n {
    a[i] = c
    i += 1
  }
  a[0].to_int() + a[n - 1].to_int()
}

fn test_int_arrays() -> String {
  let imin = -2147483647 - 1
  let imax = 2147483647
  let lit : Array[Int] = [imin, -1, 0, 42, imax]
  // Adjacent elements must not clobber each other
  lit[1] = -999
  lit[2] += 7
  lit[3] = lit[3] + 1
  let adj = "\{lit[0]},\{lit[1]},\{lit[2]},\{lit[3]},\{lit[4]}"

  let a : Array[Int] = Array::make(4, -5)
  a.push(imin)
  a.push(imax)
  a.push(-1)
  a.push(0)
  // Trigger growth past initial capacity
  let mut k = 0
  while k < 16 {
    a.push(-k - 10)
    k += 1
  }
  let popped = a.pop().unwrap_or(0)
  let gp = generic_push_pop(a, imin).unwrap_or(0)
  let fl = generic_first_last(a)

  let s : Array[Int] = [imax, -1, imin, 42, 0, -100, 100]
  s.sort()
  let sorted = "\{s[0]},\{s[1]},\{s[2]},\{s[3]},\{s[4]},\{s[5]},\{s[6]}"
  s.reverse()
  let rev0 = s[0]
  let rev6 = s[6]
  s.swap(0, 6)
  let has_min = s.contains(imin)
  let has_no = s.contains(123456)

  let fa : FixedArray[Int] = FixedArray::makei(6, fn(i : Int) -> Int { i * -10 - 1 })
  let fb = fa.copy()
  fb.blit_to(fb, 3, 2, 0)
  let fc = fa.copy()
  fc.blit_to(fc, 3, 0, 2)
  let fd : FixedArray[Int] = FixedArray::make(5, 1)
  fd.fill(0)
  let fd0 = fd[4]
  fd.fill(-77)
  let fd1 = fd[3]

  let u : Array[Int] = Array::make(19, 0)
  let usum = unroll_fill_i32(u, -12345)

  let m : Map[Int, Int] = Map::new()
  m.set(imin, 1)
  m.set(-1, 2)
  m.set(0, 3)
  m.set(imax, 4)
  let ks = m.keys()
  ks.sort()
  let mkeys = "\{ks.length()}:\{ks[0]},\{ks[1]},\{ks[2]},\{ks[3]}"

  "i32:\{adj}|\{popped},\{gp},\{fl.0},\{fl.1}|\{sorted}|\{rev0},\{rev6},\{s[0]},\{has_min},\{has_no}|\{fb[0]},\{fb[2]},\{fc[2]},\{fc[4]},\{fd0},\{fd1}|\{usum},\{u[17]}|\{mkeys}"
}

fn test_uint_arrays() -> String {
  let umax : UInt = 0xFFFFFFFFU
  let uhi : UInt = 0x80000000U
  let lit : Array[UInt] = [0U, 1U, uhi, umax]
  lit[1] = 0xDEADBEEFU
  lit[2] = lit[2] + 1U
  let adj = "\{lit[0]},\{lit[1]},\{lit[2]},\{lit[3]}"

  let a : Array[UInt] = Array::make(3, uhi)
  let mut k = 0
  while k < 12 {
    a.push(umax - k.to_uint())
    k += 1
  }
  let popped = a.pop().unwrap_or(0U)
  let gp = generic_push_pop(a, umax).unwrap_or(0U)
  let fl = generic_first_last(a)
  let has_hi = a.contains(uhi)
  let has_no = a.contains(12345U)
  let cp = a.copy()
  cp.reverse()
  cp.swap(0, 1)

  let fa : FixedArray[UInt] = FixedArray::makei(6, fn(i : Int) -> UInt { uhi + i.to_uint() })
  let fb = fa.copy()
  fb.blit_to(fb, 3, 2, 0)
  let fc = fa.copy()
  fc.blit_to(fc, 3, 0, 2)
  let fd : FixedArray[UInt] = FixedArray::make(19, 0U)
  let ux = unroll_fill_u32(fd, 0xCAFEBABEU)
  fd.fill(0U)
  let f0 = fd[18]
  fd.fill(umax)
  let f1 = fd[17]

  let m : Map[UInt, Int] = Map::new()
  m.set(0U, 1)
  m.set(uhi, 2)
  m.set(umax, 3)
  let ks = m.keys()
  let mut ksum : UInt64 = 0UL
  for kv in ks {
    ksum = ksum + kv.to_uint64()
  }

  "u32:\{adj}|\{popped},\{gp},\{fl.0},\{fl.1},\{has_hi},\{has_no},\{cp[0]},\{cp[1]}|\{fb[0]},\{fb[2]},\{fc[2]},\{fc[4]}|\{ux},\{f0},\{f1}|\{ks.length()}:\{ksum}"
}

fn test_char_arrays() -> String {
  let rocket : Char = '🚀'
  let zh : Char = '中'
  let lit : Array[Char] = ['a', rocket, zh, 'Z']
  lit[0] = '!'
  let adj = "\{lit[0].to_int()},\{lit[1].to_int()},\{lit[2].to_int()},\{lit[3].to_int()}"

  let a : Array[Char] = Array::make(3, rocket)
  let mut k = 0
  while k < 10 {
    a.push(zh)
    k += 1
  }
  let popped = a.pop().unwrap_or('x')
  let gp = generic_push_pop(a, rocket).unwrap_or('x')
  let fl = generic_first_last(a)
  let has_r = a.contains(rocket)
  let has_x = a.contains('x')
  let cp = a.copy()
  cp.reverse()
  cp.swap(0, 1)

  let fa : FixedArray[Char] = FixedArray::make(4, zh)
  fa[0] = 'A'
  fa[1] = rocket
  let fb = fa.copy()
  fb.blit_to(fb, 2, 0, 2)

  let u : Array[Char] = Array::make(19, 'a')
  let usum = unroll_fill_char(u, rocket)

  let m : Map[Char, Int] = Map::new()
  m.set('a', 1)
  m.set(zh, 2)
  m.set(rocket, 3)
  let ks = m.keys()
  let mut csum = 0
  for ck in ks {
    csum += ck.to_int()
  }

  "chr:\{adj}|\{popped.to_int()},\{gp.to_int()},\{fl.0.to_int()},\{fl.1.to_int()},\{has_r},\{has_x},\{cp[0].to_int()},\{cp[1].to_int()}|\{fb[2].to_int()},\{fb[3].to_int()}|\{usum},\{u[17].to_int()}|\{ks.length()}:\{csum}"
}

pub fn main(world : World) -> Int {
  io_println(world, test_int_arrays())
  io_println(world, test_uint_arrays())
  io_println(world, test_char_arrays())
  0
}
EOF

EXPECTED="$(cat <<'EOF'
i32:-2147483648,-999,7,43,2147483647|-25,-2147483648,-5,-24|-2147483648,-100,-1,0,42,100,2147483647|2147483647,-2147483648,-2147483648,true,false|-21,-41,-1,-21,0,-77|-24690,-12345|4:-2147483648,-1,0,2147483647
u32:0,3735928559,2147483649,4294967295|4294967284,4294967295,2147483648,4294967285,true,false,4294967286,4294967285|2147483650,2147483652,2147483648,2147483650|0,0,4294967295|3:6442450943
chr:33,128640,20013,90|20013,128640,128640,20013,true,false,20013,20013|65,128640|257280,128640|3:148750
EOF
)"

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p85_rel" "$TMP_DIR/main.pion"
OUT_REL="$("$TMP_DIR/p85_rel")"
if [ "$OUT_REL" != "$EXPECTED" ]; then
  echo "FAIL: native release mismatch" >&2
  echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
  echo "--- got ---" >&2; printf '%s\n' "$OUT_REL" >&2
  exit 1
fi
echo "1a. Native release -> OK"

"$PIONC" build -o "$TMP_DIR/p85_dev" "$TMP_DIR/main.pion"
OUT_DEV="$("$TMP_DIR/p85_dev")"
if [ "$OUT_DEV" != "$EXPECTED" ]; then
  echo "FAIL: native dev mismatch" >&2
  exit 1
fi
echo "1b. Native dev -> OK"

# 2. SSA audit: unroll4 uses storew (never stores) + shl 2 / shr 2
"$PIONC" build --release --emit-ssa "$TMP_DIR/p85.ssa" "$TMP_DIR/main.pion"
python3 - "$TMP_DIR/p85.ssa" <<'SSA_AUDIT'
import sys, re
ssa = open(sys.argv[1]).read()
def fn_body(name):
    m = re.search(rf'function [^\n]*\${name}\([^)]*\) \{{(.*?)\n\}}', ssa, re.S)
    assert m, f"missing function {name}"
    return m.group(1)

for fn in ("pion_fn_unroll_fill_i32", "pion_fn_unroll_fill_u32", "pion_fn_unroll_fill_char"):
    body = fn_body(fn)
    assert "storew " in body, f"{fn} missing storew"
    assert "stores " not in body, f"{fn} unexpectedly uses stores (float store on 4B int!)"
    assert not re.search(r"=l shl [^\n]+, 3\b", body), f"{fn} unexpectedly uses shl 3"
    assert not re.search(r"=l shr [^\n]+, 3\b", body), f"{fn} unexpectedly uses shr 3"
print("2. SSA audit (unroll_fill i32/u32/char = storew, no stores, no shl3/shr3) -> OK")
SSA_AUDIT

# 3. Compact 4B RSS proof: Array::make(4_000_000, 0) = 16 MB data (< 28 MB RSS)
cat > "$TMP_DIR/rss.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let a : Array[Int] = Array::make(4_000_000, 0)
  a[0] = -1
  a[3_999_999] = 5
  let sum = a[0] + a[3_999_999]
  io_println(world, sum.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/p85_rss" "$TMP_DIR/rss.pion"
python3 - "$TMP_DIR/p85_rss" <<'RSS_CHK'
import resource, subprocess, sys
out = subprocess.check_output([sys.argv[1]], text=True).strip()
assert out == "4", f"expected 4, got {out!r}"
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
rss_kb = ru.ru_maxrss // 1024 if sys.platform == "darwin" else ru.ru_maxrss
assert rss_kb <= 28672, f"Array[Int](4M) RSS {rss_kb} KB > 28672 KB (expected compact 4B = ~16MB)"
print(f"3. Compact 4B Array::make(4M, 0) RSS={rss_kb} KB (<= 28672 KB) -> OK")
RSS_CHK

# 4. Native ASan/LSan (0 leaks, 0 memory errors)
CC_BIN="${CC:-cc}"
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'EOF' >/dev/null 2>&1
int main(void) { return 0; }
EOF
then
  "$PIONC" build --release --emit-asm "$TMP_DIR/p85.s" "$TMP_DIR/main.pion"
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  "$CC_BIN" -fsanitize=address -g -O1 "$TMP_DIR/p85.s" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p85_asan"
  OUT_ASAN="$("$TMP_DIR/p85_asan")"
  if [ "$OUT_ASAN" != "$EXPECTED" ]; then
    echo "FAIL: ASan output mismatch" >&2
    exit 1
  fi
  echo "4. Native ASan/LSan (0 leaks) -> OK"
else
  echo "4. Native ASan/LSan -> SKIP (cc lacks -fsanitize=address)"
fi

# 5. Wasm32 (Node runtime + Web runtime)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p85.wasm" "$TMP_DIR/main.pion"
  OUT_WASM_NODE="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p85.wasm")"
  if [ "$OUT_WASM_NODE" != "$EXPECTED" ]; then
    echo "FAIL: Wasm32 Node output mismatch" >&2
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
    echo "--- got ---" >&2; printf '%s\n' "$OUT_WASM_NODE" >&2
    exit 1
  fi
  OUT_WASM_WEB="$(node --input-type=module -e '
    import fs from "node:fs";
    import { pathToFileURL } from "node:url";
    const { createPionRuntime } = await import(pathToFileURL(process.argv[2]).href);
    const out = [];
    const rt = createPionRuntime({ print: (s) => out.push(s), println: (s) => out.push(s + "\n") });
    const bytes = fs.readFileSync(process.argv[1]);
    const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
    rt.bindExports(instance.exports);
    const rc = instance.exports.main(0, 0n);
    if ((rc | 0) !== 0) process.exit(1);
    process.stdout.write(out.join("").replace(/\n$/, ""));
  ' "$TMP_DIR/p85.wasm" "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs")"
  if [ "$OUT_WASM_WEB" != "$EXPECTED" ]; then
    echo "FAIL: Wasm32 Web output mismatch" >&2
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" >&2
    echo "--- got ---" >&2; printf '%s\n' "$OUT_WASM_WEB" >&2
    exit 1
  fi
  echo "5. Wasm32 (Node + Web runtimes) -> OK"
else
  echo "5. Wasm32 -> SKIP (no node)"
fi

echo "PASS: p85_compact_4b_arr"
