#!/usr/bin/env sh
# P86 E2E: QBE spill.c/rega.c RSS fix + unified native/Wasm caller inline budget.
# 1) 450-branch CSS dispatch stress test: verifies native caller inline budget
#    caps SSA explosion and keeps QBE peak RSS < 100 MB (vs > 1 GB baseline).
# 2) Multi-package + scalar-Option + POD-struct + HOF regression test: verifies
#    all 4 inline paths respect caller budget and produce exact checksums on
#    native release and Wasm32.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== P86 E2E: QBE RSS & Unified Native/Wasm Inline Budget ==="

python3 - "$TMP_DIR" <<'PYEOF'
import os, sys

out_dir = sys.argv[1]

# Workload 1: 450-branch CSS dispatch (simulating Farview CSS)
css_lines = [
    'fn parse_px(v : Int, scale : Int) -> Int {',
    '  let a = v * scale + 3',
    '  let b = a ^ (scale + 7)',
    '  let c = if b > 50 { b - 11 } else { b + 13 }',
    '  let d = c * 3 + scale',
    '  if d > 200 { d - 31 } else { d + 37 }',
    '}',
    '',
    'fn resolve_color(v : Int, k : Int) -> Int {',
    '  let r = (v * 7 + k) & 255',
    '  let g = (v * 11 + k * 3) & 255',
    '  let b = (v * 13 + k * 5) & 255',
    '  if r > g { (r << 16) | (g << 8) | b } else { (g << 16) | (r << 8) | b }',
    '}',
    '',
    'fn compute_layout(a : Int, b : Int, c : Int) -> Int {',
    '  let x = parse_px(a, 2) + parse_px(b, 3)',
    '  let y = resolve_color(x, c)',
    '  if (y & 1) == 0 { y + a } else { y - b }',
    '}',
    '',
    'pub fn apply_css_prop(prop_id : Int, arg_v : Int, tag : String) -> Int {',
    '  let mut out = tag.length()',
]
N1 = 450
for i in range(N1):
    kw = 'if' if i == 0 else 'else if'
    css_lines.append(f'  {kw} prop_id == {i} {{')
    css_lines.append(f'    let x1 = parse_px(arg_v + {i}, {(i % 5) + 1})')
    css_lines.append(f'    let x2 = resolve_color(arg_v + {i % 17}, {i % 11})')
    css_lines.append(f'    let x3 = compute_layout(x1, x2, {i % 7})')
    css_lines.append(f'    out = out + x1 + x2 + x3')
    css_lines.append('  }')
css_lines.extend([
    '  else { out = out - 1 }',
    '  out',
    '}',
    '',
    'pub fn main(w : World) -> Unit {',
    '  let mut total = 0',
    '  let mut i = 0',
    f'  while i < {N1} {{',
    '    total = total + apply_css_prop(i, i * 2 + 1, "css")',
    '    i = i + 1',
    '  }',
    '  io_println(w, "p86_css total=" + total.to_string())',
    '}',
])
with open(os.path.join(out_dir, "stress_css.pion"), "w") as f:
    f.write('\n'.join(css_lines) + '\n')

# Workload 2: multi-package (xpkg + scalar-Option + POD-struct + HOF)
os.makedirs(os.path.join(out_dir, "helper"), exist_ok=True)
os.makedirs(os.path.join(out_dir, "app"), exist_ok=True)

with open(os.path.join(out_dir, "helper", "pion.toml"), "w") as f:
    f.write('[package]\nname = "csshelper"\nversion = "0.1.0"\n')

with open(os.path.join(out_dir, "helper", "lib.pion"), "w") as f:
    f.write('''pub fn parse_px(v : Int, scale : Int) -> Int {
  let a = v * scale + 3
  let b = a ^ (scale + 7)
  if b > 50 { b - 11 } else { b + 13 }
}

pub fn opt_px(v : Int) -> Option[Int] {
  let r = v * 2 + 5
  if r >= 0 { Some(r) } else { None }
}
''')

with open(os.path.join(out_dir, "app", "pion.toml"), "w") as f:
    f.write('''[package]
name = "cssapp"
version = "0.1.0"

[dependencies]
csshelper = { path = "../helper" }
''')

app_lines = [
    'import "csshelper"',
    'struct StyleVal { kind : Int; a : Int; b : Int }',
    'fn make_style(kind : Int, x : Int) -> StyleVal { let a = x * 3 + kind; let b = (a ^ 19) + kind * 2; StyleVal::{ kind: kind, a: a, b: b } }',
    'fn local_calc(x : Int, y : Int) -> Int { let p = x * 5 + y; let q = (p ^ (x + 13)) + y * 3; if q > 100 { q - 23 } else { q + 29 } }',
    'fn local_opt(x : Int) -> Option[Int] { let v = x * 3 + 1; if v >= 0 { Some(v + 2) } else { None } }',
    'fn hof_twice(x : Int, f : (Int) -> Int) -> Int { let r1 = f(x); let r2 = f(r1 + 1); r1 + r2 }',
    'pub fn dispatch_all(prop_id : Int, arg_v : Int) -> Int {',
    '  let mut out = 0',
]
N2 = 120
for i in range(N2):
    kw = 'if' if i == 0 else 'else if'
    app_lines.append(f'  {kw} prop_id == {i} {{')
    app_lines.append(f'    let st = make_style({i}, arg_v + {i % 7})')
    app_lines.append(f'    let x1 = local_calc(st.a, st.b)')
    app_lines.append(f'    let x2 = csshelper::parse_px(arg_v + {i}, {(i % 5) + 1})')
    app_lines.append(f'    let x3 = local_opt(arg_v + {i % 11}).unwrap_or(0)')
    app_lines.append(f'    let x4 = csshelper::opt_px(arg_v + {i % 13}).unwrap_or(0)')
    app_lines.append(f'    let x5 = hof_twice(arg_v + {i % 3}, fn(v : Int) -> Int {{ v + {(i % 9) + 1} }})')
    app_lines.append(f'    out = out + x1 + x2 + x3 + x4 + x5')
    app_lines.append('  }')
app_lines.extend([
    '  else { out = out - 1 }',
    '  out',
    '}',
    'pub fn main(w : World) -> Unit {',
    '  let mut total = 0',
    '  let mut i = 0',
    f'  while i < {N2} {{ total = total + dispatch_all(i, i * 2 + 1); i = i + 1 }}',
    '  io_println(w, "p86_xpkg total=" + total.to_string())',
    '}',
])
with open(os.path.join(out_dir, "app", "main.pion"), "w") as f:
    f.write('\n'.join(app_lines) + '\n')
PYEOF

# 1. Build & verify 450-branch CSS stress test
"$PIONC" build --release --emit-ssa "$TMP_DIR/stress_css.ssa" -o "$TMP_DIR/stress_css" "$TMP_DIR/stress_css.pion"
OUT_CSS="$("$TMP_DIR/stress_css")"
echo "p86 450-branch CSS output: $OUT_CSS"
if [ "$OUT_CSS" != "p86_css total=-1008898243" ]; then
  echo "FAIL: p86_css output mismatch: got='$OUT_CSS'" >&2
  exit 1
fi

# Verify native caller inline budget capped inlining inside apply_css_prop's own body
python3 - "$TMP_DIR/stress_css.ssa" <<'PYEOF'
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r'export function [^{]+\$pion_fn_apply_css_prop\([^{]+\{(.*?)\n\}', txt, re.S)
if not m:
    sys.stderr.write("FAIL: $pion_fn_apply_css_prop body not found in stress_css.ssa\n")
    sys.exit(1)
body = m.group(1)
for sym in ("$pion_fn_parse_px(", "$pion_fn_compute_layout("):
    if f"call {sym}" not in body:
        sys.stderr.write(f"FAIL: expected call {sym} inside $pion_fn_apply_css_prop body once caller inline budget exceeded\n")
        sys.exit(1)
PYEOF

# Measure QBE peak RSS via python3 resource.getrusage (portable across Linux & macOS,
# no external /usr/bin/time dependency; enforces 0 < RSS <= 100 MB on both platforms)
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Linux" ] || [ "$UNAME_S" = "Darwin" ]; then
  if [ ! -x "$QBE" ]; then
    echo "FAIL: QBE binary not found at $QBE" >&2
    exit 1
  fi
  python3 - "$UNAME_S" "$(uname -m)" "$QBE" "$TMP_DIR" <<'PYEOF'
import os, resource, subprocess, sys, time

os_name, arch, qbe, tmp_dir = sys.argv[1:5]
ssa = os.path.join(tmp_dir, "stress_css.ssa")
if os_name == "Darwin" and arch in ("arm64", "aarch64"):
    cmd = [qbe, "-t", "arm64_apple", "--obj", "-o", os.path.join(tmp_dir, "stress_css.o"), ssa]
elif os_name == "Linux" and arch == "x86_64":
    cmd = [qbe, "-t", "amd64_sysv", "--obj", "-o", os.path.join(tmp_dir, "stress_css.o"), ssa]
elif os_name == "Linux" and arch in ("aarch64", "arm64"):
    cmd = [qbe, "-t", "arm64", "-o", os.path.join(tmp_dir, "stress_css.s"), ssa]
elif os_name == "Linux" and arch == "riscv64":
    cmd = [qbe, "-t", "rv64", "-o", os.path.join(tmp_dir, "stress_css.s"), ssa]
else:
    sys.stderr.write(f"FAIL: unsupported host {os_name}/{arch} for QBE peak RSS check\n")
    sys.exit(1)

t0 = time.monotonic()
res = subprocess.run(cmd)
dt = time.monotonic() - t0
if res.returncode != 0:
    sys.stderr.write(f"FAIL: QBE exited with {res.returncode}\n")
    sys.exit(res.returncode)

ru = resource.getrusage(resource.RUSAGE_CHILDREN)
rss_kb = ru.ru_maxrss // 1024 if os_name == "Darwin" else ru.ru_maxrss
if rss_kb <= 0:
    sys.stderr.write(f"FAIL: invalid ru_maxrss={ru.ru_maxrss} (rss_kb={rss_kb})\n")
    sys.exit(1)
print(f"p86 QBE peak RSS: {rss_kb} KB, elapsed: {dt:.2f}s")
if rss_kb > 102400:
    sys.stderr.write(f"FAIL: QBE peak RSS {rss_kb} KB exceeded 100 MB budget\n")
    sys.exit(1)
PYEOF
fi

# 2. Multi-package (xpkg + scalar-Option + POD-struct + HOF) native release build
"$PIONC" build --release -o "$TMP_DIR/cssapp_bin" "$TMP_DIR/app"
OUT_XPKG="$("$TMP_DIR/cssapp_bin")"
echo "p86 multi-pkg 4-path output: $OUT_XPKG"
EXPECTED_XPKG="$(python3 - <<'PYEOF'
def parse_px(v, scale):
    a = v * scale + 3
    b = a ^ (scale + 7)
    return (b - 11) if b > 50 else (b + 13)
def opt_px(v):
    r = v * 2 + 5
    return r if r >= 0 else 0
def make_style(kind, x):
    a = x * 3 + kind
    b = (a ^ 19) + kind * 2
    return (kind, a, b)
def local_calc(x, y):
    p = x * 5 + y
    q = (p ^ (x + 13)) + y * 3
    return (q - 23) if q > 100 else (q + 29)
def local_opt(x):
    v = x * 3 + 1
    return (v + 2) if v >= 0 else 0
def hof_twice(x, f):
    r1 = f(x)
    r2 = f(r1 + 1)
    return r1 + r2
total = 0
for i in range(120):
    v = i * 2 + 1
    _, a, b = make_style(i, v + (i % 7))
    total += local_calc(a, b) + parse_px(v + i, (i % 5) + 1) + local_opt(v + (i % 11)) + opt_px(v + (i % 13)) + hof_twice(v + (i % 3), lambda z, k=(i % 9) + 1: z + k)
print(f"p86_xpkg total={total}")
PYEOF
)"
if [ "$OUT_XPKG" != "$EXPECTED_XPKG" ]; then
  echo "FAIL: p86_xpkg output mismatch: got='$OUT_XPKG' expected='$EXPECTED_XPKG'" >&2
  exit 1
fi

# 3. Wasm32 build + real Node.js runtime execution (multi-pkg 4-path + 450-branch CSS)
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required to execute Wasm32 regression checks" >&2
  exit 1
fi
"$PIONC" build --release --target wasm32 -o "$TMP_DIR/cssapp.wasm" "$TMP_DIR/app"
if [ ! -s "$TMP_DIR/cssapp.wasm" ]; then
  echo "FAIL: cssapp.wasm not produced" >&2
  exit 1
fi
OUT_WASM_XPKG="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/cssapp.wasm")"
echo "p86 multi-pkg Wasm32 output: $OUT_WASM_XPKG"
if [ "$OUT_WASM_XPKG" != "$EXPECTED_XPKG" ]; then
  echo "FAIL: p86 multi-pkg Wasm32 output mismatch: got='$OUT_WASM_XPKG' expected='$EXPECTED_XPKG'" >&2
  exit 1
fi

"$PIONC" build --release --target wasm32 -o "$TMP_DIR/stress_css.wasm" "$TMP_DIR/stress_css.pion"
if [ ! -s "$TMP_DIR/stress_css.wasm" ]; then
  echo "FAIL: stress_css.wasm not produced" >&2
  exit 1
fi
OUT_WASM_CSS="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/stress_css.wasm")"
echo "p86 450-branch CSS Wasm32 output: $OUT_WASM_CSS"
if [ "$OUT_WASM_CSS" != "p86_css total=-1008898243" ]; then
  echo "FAIL: p86_css Wasm32 output mismatch: got='$OUT_WASM_CSS'" >&2
  exit 1
fi

echo "[PASS] P86 E2E: QBE RSS & unified native/Wasm inline budget passed!"
