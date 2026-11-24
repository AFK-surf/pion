#!/bin/sh
# P108: QbeReadPair (hoisted pair headers + merged bounds check) & bounded memchr byte scan.
# Verifies:
# 1. SSA emits @pair_setup/@pair_oob on eligible pair-read loops and falls back on
#    alias_push/byref/rebind; emits @scan_fast + `call $memchr` on counted byte scan.
# 2. Exact stdout, panic stderr (`pion panic: index X out of bounds (len Y)`), and exit
#    status across Native dev & --release for all edge cases.
# 3. Native == Wasm32 parity (dev & --release) for all non-trapping and trapping cases.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p108_read_pair_and_byte_scan"
SRC="$DIR/edges.pion"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

# 1 & 2. Native dev and --release: SSA check + exact edge-case behavior
for MODE in dev release; do
  EXE="$TMP_DIR/edges_$MODE"
  SSA="$TMP_DIR/edges_$MODE.ssa"
  if [ "$MODE" = "release" ]; then
    "$PIONC" build --release --emit-ssa "$SSA" -o "$EXE" "$SRC"
  else
    "$PIONC" build --emit-ssa "$SSA" -o "$EXE" "$SRC"
  fi
  python3 - "$SSA" "$EXE" "$MODE" <<'PYEOF'
import re, resource, subprocess, sys
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
ssa_path, exe, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ir = open(ssa_path).read()

funcs = {
    m.group(1): m.group(0)
    for m in re.finditer(r'^function [^\n]*\$pion_fn_([\w]+)\([^\n]*\{.*?^\}', ir, re.M | re.S)
}
pairs = {k for k, v in funcs.items() if '@pair_setup' in v and '@pair_oob' in v}
scans = {k for k, v in funcs.items() if '@scan_fast' in v and 'call $memchr(' in v}

want_pairs = {'pair_read', 'repeated', 'frozen_read', 'alias_store', 'views', 'pair_continue'}
forbid_pairs = {'alias_push', 'byref', 'rebind'}
assert want_pairs <= pairs, f"{mode}: missing pair_setup/pair_oob in {want_pairs - pairs} (got {sorted(pairs)})"
assert not (forbid_pairs & pairs), f"{mode}: unexpectedly optimized {forbid_pairs & pairs}"
assert 'scan' in scans, f"{mode}: scan missing @scan_fast / call $memchr (got {sorted(scans)})"

cases = {
    'ok': 24,
    'both': (3, 2),
    'second': (1, 1),
    'neg': (-1, 2),
    'empty': (0, 0),
    'skip': 0,
    'repeat': 4,
    'frozen': 4,
    'views': 100,
    'cont': 22,
    'alias': 24,
    'payload': 16,
    'ref': 16,
    'rebind': 15,
    's1': 1,
    's2': 3,
    's3': 1,
    's4': (3, 3),
    's5': (-1, 3),
    's6': -1,
    's7': 3,
    's8': 2,
    's9': 0,
    's10': 3,
}
for k, want in cases.items():
    r = subprocess.run([exe, k], capture_output=True)
    if isinstance(want, int):
        assert r.returncode == 0 and r.stdout == f"{want}\n".encode() and r.stderr == b"", (
            f"{mode} {k}: got rc={r.returncode} out={r.stdout!r} err={r.stderr!r}, want {want}"
        )
    else:
        exp_err = f"pion panic: index {want[0]} out of bounds (len {want[1]})\n".encode()
        assert r.returncode != 0 and r.stdout == b"" and r.stderr == exp_err, (
            f"{mode} {k}: got rc={r.returncode} out={r.stdout!r} err={r.stderr!r}, want err={exp_err!r}"
        )
print(f"p108 native {mode}: SSA + {len(cases)}/{len(cases)} edge cases ok")
PYEOF
done

# 3. Wasm32 dev & --release parity
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    WASM="$TMP_DIR/edges_$MODE.wasm"
    if [ "$MODE" = "release" ]; then
      "$PIONC" build --release --target wasm32 -o "$WASM" "$SRC"
    else
      "$PIONC" build --target wasm32 -o "$WASM" "$SRC"
    fi
    python3 - "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$WASM" "$MODE" <<'PYEOF'
import subprocess, sys
rt, wasm, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ok_cases = {
    'ok': 24, 'skip': 0, 'repeat': 4, 'frozen': 4, 'views': 100, 'cont': 22,
    'alias': 24, 'payload': 16, 'ref': 16, 'rebind': 15,
    's1': 1, 's2': 3, 's3': 1, 's6': -1, 's7': 3, 's8': 2, 's9': 0, 's10': 3,
}
trap_cases = ['both', 'second', 'neg', 'empty', 's4', 's5']
for k, want in ok_cases.items():
    r = subprocess.run(['node', rt, wasm, k], capture_output=True)
    assert r.returncode == 0 and r.stdout == f"{want}\n".encode(), (
        f"wasm32 {mode} {k}: got rc={r.returncode} out={r.stdout!r} err={r.stderr!r}, want {want}"
    )
for k in trap_cases:
    r = subprocess.run(['node', rt, wasm, k], capture_output=True)
    assert r.returncode != 0, f"wasm32 {mode} {k}: expected trap, got rc=0 out={r.stdout!r}"
print(f"p108 wasm32 {mode}: {len(ok_cases)} ok + {len(trap_cases)} traps ok")
PYEOF
  done
else
  echo "NOTE: node unavailable; skipping p108 Wasm32 checks"
fi

echo "PASS: p108_read_pair_and_byte_scan"
