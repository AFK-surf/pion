#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pionc_check_server_e2e.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[e2e] pionc_check_server: protocol, equivalence, query types, 19-case for-in matrix, pipe regression"

# 1. Protocol, 4-way equivalence, reload, filter_files, 64 MiB limit, query types, byte-identical diagnostics
python3 - "$PIONC" "$TMP_DIR" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

pionc = sys.argv[1]
tmp = sys.argv[2]

ws = os.path.join(tmp, "ws")
dep_dir = os.path.join(ws, "dep")
app_dir = os.path.join(ws, "app")
os.makedirs(os.path.join(dep_dir, "src"), exist_ok=True)
os.makedirs(os.path.join(app_dir, "src"), exist_ok=True)
os.makedirs(os.path.join(app_dir, "tests"), exist_ok=True)

with open(os.path.join(dep_dir, "pion.toml"), "w") as f:
    f.write('[package]\nname = "dep"\nversion = "0.1.0"\n')
with open(os.path.join(dep_dir, "src", "lib.pion"), "w") as f:
    f.write('pub struct Val { x : Int }\npub fn make(n : Int) -> Val { Val::{ x: n + 1 } }\n')

with open(os.path.join(app_dir, "pion.toml"), "w") as f:
    f.write('[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\ndep = { path = "../dep" }\n')

src_a = 'import "dep" as d\nfn main() -> Int { d::make(41).x }\n'
src_b = 'import "dep" as d\nfn main() -> Int { let v : String = d::make(41).x\n 0 }\n'
test_src = 'test "t1" { debug_assert(main() == 42, "ok") }\n'

with open(os.path.join(app_dir, "src", "main.pion"), "w") as f:
    f.write(src_a)
with open(os.path.join(app_dir, "tests", "app_test.pion"), "w") as f:
    f.write(test_src)

# Use isolated CAS dir so cold vs hot stub is deterministic
env_cold = os.environ.copy()
env_cold["PION_CACHE_DIR"] = os.path.join(tmp, "cas_cold")

def run_check_json(env):
    p = subprocess.run([pionc, "check", "--json", app_dir], capture_output=True, text=True, env=env)
    return p.returncode, p.stdout.strip()

def start_server(env, extra=None):
    cmd = [pionc, "check", "--server"] + (extra or []) + [app_dir]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)

def rpc(proc, line):
    proc.stdin.write(line + "\n")
    proc.stdin.flush()
    out = proc.stdout.readline()
    assert out, f"server exited early, stderr={proc.stderr.read()}"
    return out.rstrip("\r\n")

# (a) Cold source vs hot stub vs fresh process vs 50-round A -> B -> A equivalence + byte-for-byte diagnostic parity
rc_cli_a, out_cli_a = run_check_json(env_cold)
assert rc_cli_a == 0, f"cli check A failed: {out_cli_a}"

# Cold server (fresh CAS)
env_srv_cold = os.environ.copy()
env_srv_cold["PION_CACHE_DIR"] = os.path.join(tmp, "cas_srv_cold")
s1 = start_server(env_srv_cold)
r_cold_a = json.loads(rpc(s1, json.dumps({"id": 9007199254740993123456789})))
assert r_cold_a["ok"] is True and r_cold_a["diagnostics"] == []
# Verify big-int id echoed verbatim!
raw_big = rpc(s1, '{"id":9007199254740993123456789,"include_types":false}')
assert '"id":9007199254740993123456789' in raw_big, f"big-int id not preserved: {raw_big}"

# Check byte-for-byte diagnostic parity on broken root (src_b)
r_b_srv = json.loads(rpc(s1, json.dumps({"files": {"src/main.pion": src_b}})))
assert r_b_srv["ok"] is False and len(r_b_srv["diagnostics"]) > 0
with open(os.path.join(app_dir, "src", "main.pion"), "w") as f:
    f.write(src_b)
rc_cli_b, out_cli_b = run_check_json(env_cold)
assert rc_cli_b == 1
assert json.dumps(r_b_srv["diagnostics"], separators=(",", ":")) == json.dumps(json.loads(out_cli_b)["diagnostics"], separators=(",", ":")), \
    f"diag mismatch:\nserver={r_b_srv['diagnostics']}\ncli={json.loads(out_cli_b)['diagnostics']}"
with open(os.path.join(app_dir, "src", "main.pion"), "w") as f:
    f.write(src_a)

# 50-round A -> B -> A stability (stateless overlay + no ImportedPkg mutation)
dig_a_ref = hashlib.sha256(rpc(s1, json.dumps({"files": {"src/main.pion": src_a}, "include_types": True})).encode()).hexdigest()
dig_b_ref = hashlib.sha256(rpc(s1, json.dumps({"files": {"src/main.pion": src_b}, "include_types": True})).encode()).hexdigest()
for r in range(50):
    da = hashlib.sha256(rpc(s1, json.dumps({"files": {"src/main.pion": src_a}, "include_types": True})).encode()).hexdigest()
    db = hashlib.sha256(rpc(s1, json.dumps({"files": {"src/main.pion": src_b}, "include_types": True})).encode()).hexdigest()
    assert da == dig_a_ref and db == dig_b_ref, f"round {r} diverged!"

# Hot stub server (reusing populated CAS)
s2 = start_server(env_srv_cold)
da_hot = hashlib.sha256(rpc(s2, json.dumps({"files": {"src/main.pion": src_a}, "include_types": True})).encode()).hexdigest()
assert da_hot == dig_a_ref, "hot stub server diverged from cold source server!"

# (b) 3-state filter_files + include_tests
r_f_all = json.loads(rpc(s2, json.dumps({"include_types": True, "include_tests": True})))
assert len(r_f_all["types"]) == 2, f"expected 2 files with include_tests, got {len(r_f_all['types'])}"
r_f_empty = json.loads(rpc(s2, json.dumps({"include_types": True, "filter_files": []})))
assert r_f_empty["types"] == [], f"expected empty types for filter_files:[], got {r_f_empty['types']}"
r_f_one = json.loads(rpc(s2, json.dumps({"include_types": True, "include_tests": True, "filter_files": ["src/main.pion"]})))
assert [f["file"] for f in r_f_one["types"]] == ["src/main.pion"]

# (c) Duplicate JSON key rejection, mixing quit/reload, path validation
r_dup = json.loads(rpc(s2, '{"id":1,"id":2}'))
assert "protocol_error" in r_dup
r_mix = json.loads(rpc(s2, '{"quit":true,"files":{}}'))
assert "protocol_error" in r_mix
r_badp = json.loads(rpc(s2, '{"files":{"../escape.pion":"fn f() {}"}}'))
assert "protocol_error" in r_badp
r_rem_miss = json.loads(rpc(s2, '{"removed":["src/does_not_exist.pion"]}'))
assert "protocol_error" in r_rem_miss
r_overlap = json.loads(rpc(s2, '{"files":{"src/main.pion":"fn main() -> Int { 0 }"},"removed":["src/main.pion"]}'))
assert "protocol_error" in r_overlap

# (c2) Priority `id` extraction on invalid fields + verbatim raw string `id` (`\u0061`) + case-insensitive filter_files collision
r_id_err1 = rpc(s2, '{"quit":1,"id":5}')
j_id_err1 = json.loads(r_id_err1)
assert j_id_err1["ok"] is False and j_id_err1["id"] == 5 and "protocol_error" in j_id_err1
r_id_err2 = rpc(s2, '{"include_types":"x","id":"\\u0061"}')
assert '"id":"\\u0061"' in r_id_err2 and json.loads(r_id_err2)["ok"] is False
r_ci_filter = json.loads(rpc(s2, '{"id":"ci1","include_types":true,"filter_files":["src/main.pion","src/MAIN.pion"]}'))
assert r_ci_filter["ok"] is False and r_ci_filter["id"] == "ci1" and "protocol_error" in r_ci_filter

# (c3) Nested duplicate-key error preserves unique top-level `id`; duplicate top-level `id` omits `id`
r_nested_dup = json.loads(rpc(s2, '{"id":42,"files":{"src/a.pion":"","src/a.pion":""}}'))
assert r_nested_dup["ok"] is False and r_nested_dup["id"] == 42 and "protocol_error" in r_nested_dup
r_top_dup_id = json.loads(rpc(s2, '{"id":1,"id":2}'))
assert r_top_dup_id["ok"] is False and "id" not in r_top_dup_id and "protocol_error" in r_top_dup_id

# (c4) Cross-set case-insensitive collisions for `filter_files` vs `files`, `removed`, and active files
r_ci_f_flt = json.loads(rpc(s2, '{"id":"ci2","files":{"src/a.pion":"fn a() -> Int { 1 }"},"filter_files":["src/A.pion"]}'))
assert r_ci_f_flt["ok"] is False and r_ci_f_flt["id"] == "ci2" and "protocol_error" in r_ci_f_flt
r_ci_r_flt = json.loads(rpc(s2, '{"id":"ci3","removed":["src/main.pion"],"filter_files":["src/MAIN.pion"]}'))
assert r_ci_r_flt["ok"] is False and r_ci_r_flt["id"] == "ci3" and "protocol_error" in r_ci_r_flt
r_ci_act_flt = json.loads(rpc(s2, '{"id":"ci4","filter_files":["src/MAIN.pion"]}'))
assert r_ci_act_flt["ok"] is False and r_ci_act_flt["id"] == "ci4" and "protocol_error" in r_ci_act_flt
# Exact spelling match between `files`/`active` and `filter_files` must succeed
r_ci_exact = json.loads(rpc(s2, '{"id":"ci5","include_types":true,"filter_files":["src/main.pion"]}'))
assert r_ci_exact["ok"] is True and r_ci_exact["id"] == "ci5" and len(r_ci_exact["types"]) == 1

# (d) Atomic reload: missing or broken pion.toml MUST NOT fall back to directory mode and MUST retain old snapshot
os.rename(os.path.join(app_dir, "pion.toml"), os.path.join(app_dir, "pion.toml.bak"))
r_rel_missing = json.loads(rpc(s2, '{"id":"r0","reload":true}'))
assert r_rel_missing["ok"] is False and r_rel_missing["id"] == "r0" and "protocol_error" in r_rel_missing
r_after_missing = json.loads(rpc(s2, '{"id":"r0_chk","include_types":true}'))
assert r_after_missing["ok"] is True and len(r_after_missing["types"]) == 1
os.rename(os.path.join(app_dir, "pion.toml.bak"), os.path.join(app_dir, "pion.toml"))

with open(os.path.join(app_dir, "pion.toml"), "w") as f:
    f.write("not valid toml [[[")
r_rel_fail = json.loads(rpc(s2, '{"id":"r1","reload":true}'))
assert r_rel_fail["ok"] is False and "protocol_error" in r_rel_fail
# Old snapshot must still work!
r_after_fail = json.loads(rpc(s2, '{"id":"r2"}'))
assert r_after_fail["ok"] is True

# Restore manifest & break upstream dep -> reload preserves upstream diags
with open(os.path.join(app_dir, "pion.toml"), "w") as f:
    f.write('[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\ndep = { path = "../dep" }\n')
with open(os.path.join(dep_dir, "src", "lib.pion"), "w") as f:
    f.write('pub struct Val { x : Int }\npub fn make(n : Int) -> Val { Val::{ x: "bad" } }\n')
r_rel_bad_up = json.loads(rpc(s2, '{"id":"r3","reload":true}'))
assert r_rel_bad_up["reloaded"] is True and r_rel_bad_up["ok"] is False and len(r_rel_bad_up["diagnostics"]) > 0
# Checking root still includes upstream diags
r_chk_bad_up = json.loads(rpc(s2, '{"id":"r4"}'))
assert r_chk_bad_up["ok"] is False and len(r_chk_bad_up["diagnostics"]) > 0

# Fix upstream & reload
with open(os.path.join(dep_dir, "src", "lib.pion"), "w") as f:
    f.write('pub struct Val { x : Int }\npub fn make(n : Int) -> Val { Val::{ x: n + 1 } }\n')
r_rel_ok = json.loads(rpc(s2, '{"id":"r5","reload":true}'))
assert r_rel_ok["reloaded"] is True and r_rel_ok["ok"] is True

# (e) Quit & clean EOF + no-trailing-LF EOF
r_quit = json.loads(rpc(s2, '{"id":"q1","quit":true}'))
assert r_quit == {"id": "q1", "ok": True, "quit": True}
assert s2.wait(timeout=10) == 0

# Quit s1 via clean EOF after a line with no trailing LF
s1.stdin.write('{"id":"last_no_lf"}')
s1.stdin.close()
last_line = s1.stdout.readline().strip()
assert json.loads(last_line)["id"] == "last_no_lf" and json.loads(last_line)["ok"] is True
assert s1.wait(timeout=10) == 0

# (f) Exact 64 MiB frame & >64 MiB frame recovery followed by valid frame
s3 = start_server(env_srv_cold)
limit = 64 * 1024 * 1024
prefix = '{"id":"exact","files":{"src/main.pion":"fn main() -> Int { 0 } //'
suffix = '"}}'
pad_exact = "a" * (limit - len(prefix) - len(suffix))
exact_line = prefix + pad_exact + suffix
assert len(exact_line) == limit
r_exact = json.loads(rpc(s3, exact_line))
assert r_exact["id"] == "exact" and r_exact["ok"] is True

over_line = prefix + ("b" * (limit - len(prefix) - len(suffix) + 16)) + suffix
r_over = json.loads(rpc(s3, over_line))
assert r_over["ok"] is False and "64 MiB" in r_over["protocol_error"]
# Valid frame right after oversized frame must succeed cleanly!
r_recover = json.loads(rpc(s3, '{"id":"after_over"}'))
assert r_recover["id"] == "after_over" and r_recover["ok"] is True
s3.stdin.close()
assert s3.wait(timeout=10) == 0

# (g) `pionc query types --json` CLI
qt_p = subprocess.run([pionc, "query", "types", "--json", app_dir], capture_output=True, text=True, env=env_srv_cold)
assert qt_p.returncode == 0, f"query types failed: {qt_p.stderr}"
qt_j = json.loads(qt_p.stdout)
assert qt_j["ok"] is True and len(qt_j["files"]) == 1 and qt_j["files"][0]["file"] == "src/main.pion"

# (h) `reload` pins startup-selected workspace member package root directory
ws_dir = os.path.join(tmp, "ws_pin")
os.makedirs(os.path.join(ws_dir, "first", "src"), exist_ok=True)
os.makedirs(os.path.join(ws_dir, "second", "src"), exist_ok=True)
with open(os.path.join(ws_dir, "pion.toml"), "w") as f:
    f.write('[workspace]\nmembers = ["first"]\n')
with open(os.path.join(ws_dir, "first", "pion.toml"), "w") as f:
    f.write('[package]\nname = "app"\nversion = "0.1.0"\n')
with open(os.path.join(ws_dir, "first", "src", "main.pion"), "w") as f:
    f.write('fn main() -> Int { 1 }\n')
with open(os.path.join(ws_dir, "second", "pion.toml"), "w") as f:
    f.write('[package]\nname = "app"\nversion = "0.1.0"\n')
with open(os.path.join(ws_dir, "second", "src", "main.pion"), "w") as f:
    f.write('fn main() -> Int { "bad_second" }\n')
s_ws = subprocess.Popen(
    [pionc, "check", "--server", "--package", "app", ws_dir],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, env=env_srv_cold,
)
r_ws0 = json.loads(rpc(s_ws, '{"id":"ws0"}'))
assert r_ws0["ok"] is True
# Repoint workspace member `app` from `first/` to `second/` -> reload must fail and retain `first/`
with open(os.path.join(ws_dir, "pion.toml"), "w") as f:
    f.write('[workspace]\nmembers = ["second"]\n')
r_ws_rel = json.loads(rpc(s_ws, '{"id":"ws1","reload":true}'))
assert r_ws_rel["ok"] is False and r_ws_rel["id"] == "ws1" and "protocol_error" in r_ws_rel
r_ws_after = json.loads(rpc(s_ws, '{"id":"ws2"}'))
assert r_ws_after["ok"] is True and r_ws_after["id"] == "ws2"
s_ws.stdin.close()
assert s_ws.wait(timeout=10) == 0

print("  protocol + equivalence + 64MiB + query types + reload pin: OK")
PY

# 2. 19-case `for x in arr` adversarial matrix + pipe regression (Native dev/release + Wasm32 dev/release)
cat > "$TMP_DIR/for_in_matrix.pion" <<'PION'
fn check(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn mk_arr(counter : Array[Int]) -> Array[Int] {
  counter.push(1)
  [10, 20, 30]
}

fn pipe_sum(xs : Array[(Int, Int)]) -> Int {
  let mut s = 0
  for p in xs {
    s = s + p.0 * 100 + p.1
  }
  s
}

fn main(world : World) -> Int {
  // Case 1: iterable evaluated once (non-place call)
  let c : Array[Int] = []
  let mut s1 = 0
  for x in mk_arr(c) {
    s1 = s1 + x
  }
  check(c.length() == 1 && s1 == 60, "case 1")

  // Case 2: push inside loop does not extend iteration count (entry-length fixed)
  let a2 = [1, 2, 3]
  let mut s2 = 0
  for x in a2 {
    s2 = s2 + x
    a2.push(99)
  }
  check(s2 == 6 && a2.length() == 6, "case 2")

  // Case 3: push with index `for i, x in a`
  let a3 = [5, 6]
  let mut s3 = 0
  for i, x in a3 {
    s3 = s3 + i * 10 + x
    a3.push(100)
  }
  check(s3 == 21 && a3.length() == 4, "case 3")

  // Case 4: empty array
  let a4 : Array[Int] = []
  let mut s4 = 0
  for x in a4 {
    s4 = s4 + x
  }
  check(s4 == 0, "case 4")

  // Case 5: mutate element in place seen by subsequent iterations
  let a5 = [1, 2, 3]
  let mut s5 = 0
  for i, x in a5 {
    s5 = s5 + x
    if i == 0 {
      a5[2] = 30
    }
  }
  check(s5 == 33, "case 5")

  // Case 6: shrink + immediate break does NOT trap
  let a6 = [10, 20, 30]
  let mut s6 = 0
  for x in a6 {
    s6 = s6 + x
    let _ = a6.pop()
    let _ = a6.pop()
    break
  }
  check(s6 == 10 && a6.length() == 1, "case 6")

  // Case 7: shrink at last iteration (no further read) does NOT trap
  let a7 = [7, 8]
  let mut s7 = 0
  for i, x in a7 {
    s7 = s7 + x
    if i == 1 {
      let _ = a7.pop()
    }
  }
  check(s7 == 15 && a7.length() == 1, "case 7")

  // Case 8: continue skips body tail and advances index
  let a8 = [1, 2, 3, 4]
  let mut s8 = 0
  for x in a8 {
    if x % 2 == 0 {
      continue
    }
    s8 = s8 + x
  }
  check(s8 == 4, "case 8")

  // Case 9: nested for-in over same array
  let a9 = [1, 2, 3]
  let mut s9 = 0
  for x in a9 {
    for y in a9 {
      s9 = s9 + x * y
    }
  }
  check(s9 == 36, "case 9")

  // Case 10: FixedArray iteration
  let a10 : FixedArray[Int] = [4, 5, 6]
  let mut s10 = 0
  for i, x in a10 {
    s10 = s10 + i + x
  }
  check(s10 == 18, "case 10")

  // Case 11: ImmArray iteration
  let a11 : ImmArray[Int] = [2, 4, 6]
  let mut s11 = 0
  for x in a11 {
    s11 = s11 + x
  }
  check(s11 == 12, "case 11")

  // Case 12: String elements (RC-managed)
  let a12 = ["a", "bb", "ccc"]
  let mut s12 = 0
  for s in a12 {
    s12 = s12 + s.length()
    a12.push("zzzz")
  }
  check(s12 == 6 && a12.length() == 6, "case 12")

  // Case 13: rebinding `let mut a` inside loop still iterates original entry object
  let mut a13 = [10, 20]
  let mut s13 = 0
  for x in a13 {
    s13 = s13 + x
    a13 = [999]
  }
  check(s13 == 30 && a13.length() == 1, "case 13")

  // Case 14: array of tuples
  let a14 = [(1, 2), (3, 4)]
  let mut s14 = 0
  for p in a14 {
    s14 = s14 + p.0 + p.1
  }
  check(s14 == 10, "case 14")

  // Case 15: early return from helper after shrinking does NOT trap
  let s15 = helper_shrink_return([10, 20, 30])
  check(s15 == 10, "case 15")

  // Case 16: pop then push (same length) stays valid
  let a16 = [1, 2, 3]
  let mut s16 = 0
  for x in a16 {
    s16 = s16 + x
    let _ = a16.pop()
    a16.push(9)
  }
  check(s16 == 12, "case 16")

  // Case 17: shadowed loop variable inside body
  let a17 = [3, 4]
  let mut s17 = 0
  for x in a17 {
    let x = x * 2
    s17 = s17 + x
  }
  check(s17 == 14, "case 17")

  // Case 18: pipe regression `[(1, 10), (2, 20), (1, 30)] |> pipe_sum`
  let s18 = [(1, 10), (2, 20), (1, 30)] |> pipe_sum
  check(s18 == 460, "case 18 pipe")

  io_println(world, "MATRIX_OK")
  0
}

fn helper_shrink_return(a : Array[Int]) -> Int {
  for x in a {
    let _ = a.pop()
    let _ = a.pop()
    return x
  }
  0
}
PION

# Case 19: shrinking below init_len and continuing MUST trap (non-zero exit)!
cat > "$TMP_DIR/for_in_shrink_trap.pion" <<'PION'
fn main(world : World) -> Int {
  let a = [10, 20, 30]
  let mut s = 0
  for x in a {
    s = s + x
    let _ = a.pop()
  }
  io_println(world, s.to_string())
  0
}
PION

# Native dev
OUT_DEV="$("$PIONC" run "$TMP_DIR/for_in_matrix.pion")"
[ "$OUT_DEV" = "MATRIX_OK" ] || { echo "FAIL native dev: $OUT_DEV"; exit 1; }

# Native release
"$PIONC" build --release -o "$TMP_DIR/matrix_rel" "$TMP_DIR/for_in_matrix.pion"
OUT_REL="$("$TMP_DIR/matrix_rel")"
[ "$OUT_REL" = "MATRIX_OK" ] || { echo "FAIL native release: $OUT_REL"; exit 1; }

# Case 19 trap check (native dev & release)
if "$PIONC" run "$TMP_DIR/for_in_shrink_trap.pion" >/dev/null 2>&1; then
  echo "FAIL: Case 19 shrink-without-break must trap in native dev"
  exit 1
fi
"$PIONC" build --release -o "$TMP_DIR/trap_rel" "$TMP_DIR/for_in_shrink_trap.pion"
if "$TMP_DIR/trap_rel" >/dev/null 2>&1; then
  echo "FAIL: Case 19 shrink-without-break must trap in native release"
  exit 1
fi

# Wasm32 dev & release (when node is available)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/matrix_dev.wasm" "$TMP_DIR/for_in_matrix.pion"
  OUT_WDEV="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/matrix_dev.wasm")"
  [ "$OUT_WDEV" = "MATRIX_OK" ] || { echo "FAIL wasm32 dev: $OUT_WDEV"; exit 1; }

  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/matrix_rel.wasm" "$TMP_DIR/for_in_matrix.pion"
  OUT_WREL="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/matrix_rel.wasm")"
  [ "$OUT_WREL" = "MATRIX_OK" ] || { echo "FAIL wasm32 release: $OUT_WREL"; exit 1; }

  "$PIONC" build --target wasm32 -o "$TMP_DIR/trap_dev.wasm" "$TMP_DIR/for_in_shrink_trap.pion"
  if node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/trap_dev.wasm" >/dev/null 2>&1; then
    echo "FAIL: Case 19 shrink-without-break must trap in wasm32 dev"
    exit 1
  fi

  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/trap_rel.wasm" "$TMP_DIR/for_in_shrink_trap.pion"
  if node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/trap_rel.wasm" >/dev/null 2>&1; then
    echo "FAIL: Case 19 shrink-without-break must trap in wasm32 release"
    exit 1
  fi
  echo "  for-in 19-case matrix + pipe regression (native + wasm32 dev/release): OK"
else
  echo "  for-in 19-case matrix + pipe regression (native): OK (node absent)"
fi

# Optional one-command ASan/LSan verification (`PION_E2E_ASAN=1 sh tests/e2e/pionc_check_server/run_e2e.sh <pionc>`)
if [ "${PION_E2E_ASAN:-0}" = "1" ]; then
  QBE_BIN="${PION_QBE:-}"
  if [ -n "$QBE_BIN" ] && [ -x "$QBE_BIN" ]; then
    "$PIONC" build --emit-ssa "$TMP_DIR/for_in_matrix.ssa" "$TMP_DIR/for_in_matrix.pion"
    "$QBE_BIN" -t amd64_sysv "$TMP_DIR/for_in_matrix.ssa" -o "$TMP_DIR/for_in_matrix.s"
    cc -fsanitize=address,leak -fno-omit-frame-pointer -O1 -g -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o"
    cc -fsanitize=address,leak -fno-omit-frame-pointer -O1 -g "$TMP_DIR/for_in_matrix.s" "$TMP_DIR/pion_rt_asan.o" -lm -o "$TMP_DIR/for_in_matrix_asan"
    OUT_ASAN="$(ASAN_OPTIONS=detect_leaks=1 "$TMP_DIR/for_in_matrix_asan")"
    [ "$OUT_ASAN" = "MATRIX_OK" ] || { echo "FAIL ASan/LSan: $OUT_ASAN"; exit 1; }
    "$PIONC" build --emit-ssa "$TMP_DIR/for_in_shrink_trap.ssa" "$TMP_DIR/for_in_shrink_trap.pion"
    "$QBE_BIN" -t amd64_sysv "$TMP_DIR/for_in_shrink_trap.ssa" -o "$TMP_DIR/for_in_shrink_trap.s"
    cc -fsanitize=address,leak -fno-omit-frame-pointer -O1 -g "$TMP_DIR/for_in_shrink_trap.s" "$TMP_DIR/pion_rt_asan.o" -lm -o "$TMP_DIR/for_in_shrink_trap_asan"
    if ASAN_OPTIONS=detect_leaks=1 "$TMP_DIR/for_in_shrink_trap_asan" >"$TMP_DIR/trap_asan.out" 2>"$TMP_DIR/trap_asan.err"; then
      echo "FAIL: Case 19 shrink-without-break must trap under ASan/LSan"
      exit 1
    fi
    if grep -qE "ERROR: (AddressSanitizer|LeakSanitizer)" "$TMP_DIR/trap_asan.err"; then
      echo "FAIL: Case 19 triggered ASan/LSan error:"
      cat "$TMP_DIR/trap_asan.err"
      exit 1
    fi
    if ! grep -qE "out of bounds" "$TMP_DIR/trap_asan.err"; then
      echo "FAIL: Case 19 did not emit expected out-of-bounds panic:"
      cat "$TMP_DIR/trap_asan.err"
      exit 1
    fi
    echo "  for-in 19-case matrix + Case 19 trap (ASan/LSan): OK"
  else
    echo "FAIL: PION_E2E_ASAN=1 requires executable PION_QBE"
    exit 1
  fi
fi

echo "[PASS] pionc_check_server e2e"
