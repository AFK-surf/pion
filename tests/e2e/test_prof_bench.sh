#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc2}"
if [ ! -x "$PIONC" ]; then
  echo "FAIL: pionc not executable at $PIONC" >&2
  exit 1
fi

T0_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PION_CACHE_DIR="$TMP/cas"
mkdir -p "$PION_CACHE_DIR"
unset PION_RT_LIB PION_RT_CLI_PROF_LIB 2>/dev/null || true
if [ -z "${PION_RT_PROF_LIB:-}" ] && [ -f "$ROOT_DIR/out/libpionrt_prof.a" ]; then
  export PION_RT_PROF_LIB="$ROOT_DIR/out/libpionrt_prof.a"
fi
if [ -z "${PION_QBE:-}" ] && [ -x "$ROOT_DIR/out/qbe" ]; then
  export PION_QBE="$ROOT_DIR/out/qbe"
fi

echo "=== [1/6] Native --profile=alloc,rc --retained --sample-rate 1 --json ==="
cat > "$TMP/alloc_rc.pion" <<'EOF'
struct Item {
  label : String
  val_n : Int
}

fn make_and_drop(n : Int) -> Int {
  let items : Array[Item] = []
  let aliases : Array[String] = []
  let mut i = 0
  while i < n {
    let s = "item_" + i.to_string()
    aliases.push(s)
    items.push(Item::{ label: s, val_n: i })
    i = i + 1
  }
  let mut sum = 0
  i = 0
  while i < items.length() {
    sum = sum + items[i].val_n + aliases[i].length() - aliases[i].length()
    i = i + 1
  }
  sum
}

pub fn main(_world : World) -> Int {
  let r = make_and_drop(200)
  if r == 19900 { 0 } else { 1 }
}
EOF

ALLOC_JSON="$("$PIONC" run --profile=alloc,rc --retained --sample-rate 1 --json "$TMP/alloc_rc.pion")"
printf '%s' "$ALLOC_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d["managed"]
rc = d["rc"]
assert d["schema_version"] == 1, d
assert d["retained"] is True, d
assert m["alloc_count"] > 0, m
assert m["alloc_bytes"] > 0, m
assert m["inuse_bytes"] == 0, "expected inuse_bytes==0, got %s" % (m,)
assert m["inuse_count"] == 0, "expected inuse_count==0, got %s" % (m,)
assert rc["inc"] > 0 and rc["dec"] > 0 and rc["destroy"] > 0, rc
names = [f["name"] for f in d["top_functions"]]
assert any("make_and_drop" in n for n in names), "make_and_drop missing from %s" % (names,)
print("OK alloc,rc: alloc_count=%d alloc_bytes=%d inuse=0 rc_inc=%d" % (m["alloc_count"], m["alloc_bytes"], rc["inc"]))
'

echo "=== [2/6] Native --profile=cpu --json ==="
cat > "$TMP/cpu_hot.pion" <<'EOF'
fn burn_cpu(iters : Int) -> Int64 {
  let mut acc = 1L
  let mut i = 0
  while i < iters {
    acc = (acc * 1103515245L + 12345L) & 0x7fffffffL
    i = i + 1
  }
  acc
}

pub fn main(_world : World) -> Int {
  let mut total = 0L
  let mut round = 0
  while round < 40 {
    total = total + burn_cpu(1000000)
    round = round + 1
  }
  if total >= 0L { 0 } else { 1 }
}
EOF

CPU_JSON="$("$PIONC" run --profile=cpu --json "$TMP/cpu_hot.pion")"
printf '%s' "$CPU_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1, d
assert d["cpu_stack_mode"] == "pc_only", d["cpu_stack_mode"]
total_samples = sum(f["self_cpu_samples"] for f in d["top_functions"])
assert total_samples >= 1, "expected cpu_samples >= 1, got %d" % (total_samples,)
for f in d["top_functions"]:
    assert f["cum_cpu_pct"] is None, "expected cum_cpu_pct null in pc_only mode, got %s" % (f,)
top_name = d["top_functions"][0]["name"] if d["top_functions"] else "none"
print("OK cpu: stack_mode=%s samples=%d top=%s" % (d["cpu_stack_mode"], total_samples, top_name))
'

echo "=== [3/6] Planted String Alloc Storm -> H_STRING_ALLOC_STORM + Optimized Negative Control + diff ==="
cat > "$TMP/storm.pion" <<'EOF'
fn build_report(n : Int) -> Int {
  let mut total = 0
  let mut i = 0
  while i < n {
    let s = "record_payload_prefix_" + i.to_string() + "_suffix_data_block"
    total = total + s.length()
    i = i + 1
  }
  total
}

pub fn main(_world : World) -> Int {
  let r = build_report(15000)
  if r > 0 { 0 } else { 1 }
}
EOF

cat > "$TMP/storm_opt.pion" <<'EOF'
fn build_report(n : Int) -> Int {
  let prefix = "record_payload_prefix_"
  let suffix = "_suffix_data_block"
  let base_len = prefix.length() + suffix.length()
  let mut total = 0
  let mut i = 0
  while i < n {
    let digits = if i < 10 { 1 } else if i < 100 { 2 } else if i < 1000 { 3 } else if i < 10000 { 4 } else { 5 }
    total = total + base_len + digits
    i = i + 1
  }
  let summary = "done_" + total.to_string()
  if summary.length() > 0 { total } else { 0 }
}

pub fn main(_world : World) -> Int {
  let r = build_report(15000)
  if r > 0 { 0 } else { 1 }
}
EOF

"$PIONC" run --profile=alloc --sample-rate 1 --profile-out "$TMP/storm_base.json" --json "$TMP/storm.pion" > /dev/null
"$PIONC" run --profile=alloc --sample-rate 1 --profile-out "$TMP/storm_opt.json" --json "$TMP/storm_opt.pion" > /dev/null

SUMMARY_JSON="$("$PIONC" profile summary "$TMP/storm_base.json" --top 5 --sort alloc_bytes --json)"
DIFF_JSON="$("$PIONC" profile diff "$TMP/storm_base.json" "$TMP/storm_opt.json" --json)"

python3 - "$TMP/storm_base.json" "$TMP/storm_opt.json" "$SUMMARY_JSON" "$DIFF_JSON" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
opt = json.load(open(sys.argv[2]))
summ = json.loads(sys.argv[3])
diff = json.loads(sys.argv[4])

base_codes = [h["code"] for h in base["hints"]]
assert "H_STRING_ALLOC_STORM" in base_codes, f"expected H_STRING_ALLOC_STORM, got {base['hints']}"

opt_high = [h for h in opt["hints"] if h["severity"] == "high"]
assert len(opt_high) == 0, f"expected 0 high hints in optimized version, got {opt_high}"

assert summ["schema_version"] == 1
assert diff["schema_version"] == 1
assert diff["summary"]["managed_alloc_bytes"]["delta"] < 0, f"expected alloc reduction, got {diff['summary']['managed_alloc_bytes']}"
assert len(diff["improved"]) > 0, f"expected improved functions in diff, got {diff}"
assert any("build_report" in f["name"] for f in diff["improved"]), f"expected user fn build_report in diff.improved, got {diff['improved']}"
print(f"OK storm->opt: base_alloc={base['managed']['alloc_bytes']}B -> opt_alloc={opt['managed']['alloc_bytes']}B, base_hints={base_codes}, opt_high=0, diff_improved={len(diff['improved'])}")
PY

echo "=== [4/6] Native pionc bench (--iters 1 --samples 1 --save/--compare + --profile=alloc window) ==="
cat > "$TMP/bench_sample.pion" <<'EOF'
fn helper_alloc(k : Int) -> Int {
  let s = "bench_item_" + k.to_string()
  s.length()
}

bench "work" {
  let setup_items : Array[String] = []
  let mut si = 0
  while si < 500 {
    setup_items.push("setup_noise_string_" + si.to_string())
    si = si + 1
  }
  let base_len = setup_items.length()
  bench_loop {
    black_box(helper_alloc(base_len))
  }
}

pub fn main(_world : World) -> Int {
  0
}
EOF

BENCH_JSON="$("$PIONC" bench --iters 1 --samples 1 --json --save "$TMP/bench_base.json" "$TMP/bench_sample.pion")"
CMP_JSON="$("$PIONC" bench --iters 1 --samples 1 --json --compare "$TMP/bench_base.json" "$TMP/bench_sample.pion")"
BENCH_PROF_JSON="$("$PIONC" bench --profile=alloc --sample-rate 1 --iters 5 --json "$TMP/bench_sample.pion")"

python3 - "$BENCH_JSON" "$CMP_JSON" "$BENCH_PROF_JSON" <<'PY'
import json, sys
b = json.loads(sys.argv[1])
c = json.loads(sys.argv[2])
p = json.loads(sys.argv[3])

assert b["schema_version"] == 1
assert b["machine_fp"]["cpu_count"] >= 1
assert len(b["benchmarks"]) == 1 and b["benchmarks"][0]["name"] == "work", b
assert b["benchmarks"][0]["iters"] == 1 and b["benchmarks"][0]["samples"] == 1

assert c["schema_version"] == 1
assert c["incomparable"] is False, c
assert len(c["comparisons"]) == 1 and c["comparisons"][0]["name"] == "work", c

assert p["schema_version"] == 1
# Setup allocated 500+ strings outside bench_loop and runner allocated World+argv;
# bench_loop profiler window must see EXACTLY the 5 iterations (2 strings/iter = 10, inuse=0)!
ac = p["managed"]["alloc_count"]
inuse_c = p["managed"]["inuse_count"]
assert ac == 10, f"expected exact bench_loop alloc_count==10 (5 iters x 2 strings), got {ac}"
assert inuse_c == 0, f"expected exact bench_loop inuse_count==0, got {inuse_c}"
print(f"OK bench: median_ns={b['benchmarks'][0]['median_ns']}, compare_status={c['comparisons'][0]['status']}, prof_win_alloc_count={ac}")
PY

echo "=== [5/6] Wasm32 --profile=alloc,rc + --profile=cpu + pionc bench --target wasm32 ==="
if command -v node >/dev/null 2>&1; then
  WASM_ALLOC_JSON="$("$PIONC" run --target wasm32 --profile=alloc,rc --retained --sample-rate 1 --json "$TMP/alloc_rc.pion")"
  WASM_CPU_JSON="$("$PIONC" run --target wasm32 --profile=cpu --json "$TMP/cpu_hot.pion")"
  WASM_BENCH_JSON="$("$PIONC" bench --target wasm32 --iters 1 --samples 1 --json "$TMP/bench_sample.pion")"
  python3 - "$WASM_ALLOC_JSON" "$WASM_CPU_JSON" "$WASM_BENCH_JSON" <<'PY'
import json, sys
wa = json.loads(sys.argv[1])
wc = json.loads(sys.argv[2])
wb = json.loads(sys.argv[3])

assert wa["schema_version"] == 1 and wa["target"] == "wasm32", wa
assert wa["managed"]["alloc_count"] > 0, wa["managed"]
assert wa["managed"]["inuse_bytes"] == 0, f"wasm32 expected inuse_bytes==0, got {wa['managed']}"
assert wa["rc"]["inc"] > 0 and wa["rc"]["dec"] > 0, wa["rc"]

assert wc["schema_version"] == 1 and wc["target"] == "wasm32", wc
assert wc["cpu_stack_mode"] == "full", wc["cpu_stack_mode"]

assert wb["schema_version"] == 1 and wb["machine_fp"]["target"] == "wasm32", wb
assert len(wb["benchmarks"]) == 1 and wb["benchmarks"][0]["name"] == "work", wb
print(f"OK wasm32: alloc_count={wa['managed']['alloc_count']} inuse=0 cpu_mode={wc['cpu_stack_mode']} bench={wb['benchmarks'][0]['name']}")
PY
else
  echo "SKIP wasm32 (node not on PATH)"
fi

echo "=== [6/6] Error Gates & Help (E_PROFILE_STRIPPED, E_PROFILE_UNSUPPORTED_TARGET, PION_RT_LIB conflict) ==="
STRIP_ERR="$("$PIONC" build --profile -Wl,-x -o "$TMP/stripped_bin" "$TMP/alloc_rc.pion" 2>&1 || true)"
printf '%s' "$STRIP_ERR" | grep -q 'E_PROFILE_STRIPPED' || {
  echo "FAIL: expected E_PROFILE_STRIPPED, got: $STRIP_ERR" >&2
  exit 1
}

WIN_ERR="$("$PIONC" build --profile --target amd64_win -o "$TMP/win_bin" "$TMP/alloc_rc.pion" 2>&1 || true)"
printf '%s' "$WIN_ERR" | grep -q 'E_PROFILE_UNSUPPORTED_TARGET' || {
  echo "FAIL: expected E_PROFILE_UNSUPPORTED_TARGET, got: $WIN_ERR" >&2
  exit 1
}

RT_ERR="$(env -u PION_RT_PROF_LIB -u PION_RT_CLI_PROF_LIB PION_RT_LIB="$TMP/fake.a" "$PIONC" build --profile -o "$TMP/rt_bin" "$TMP/alloc_rc.pion" 2>&1 || true)"
printf '%s' "$RT_ERR" | grep -q 'E_PROFILE_RT_CONFLICT' || {
  echo "FAIL: expected E_PROFILE_RT_CONFLICT, got: $RT_ERR" >&2
  exit 1
}

"$PIONC" profile --help | grep -q 'pionc profile summary'
"$PIONC" bench --help | grep -q 'pionc bench'

echo "=== [7/7] Regression Gates (bench+test index, CAS-hit .syms, strip pass-through, rc_partial, multi-bench --profile) ==="
cat > "$TMP/mixed_bt.pion" <<'EOF'
bench "b_first" {
  let x = 1 + 1
  let _ = black_box(x)
}

bench "b_second" {
  let y = 2 + 2
  let _ = black_box(y)
}

test "t_pass" {
  if 1 + 1 != 2 { abort("no") }
}

test "t_fail" {
  abort("expected_fail")
}
EOF
MIXED_JSON="$("$PIONC" test --json "$TMP/mixed_bt.pion" || true)"
python3 - "$MIXED_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["passed"] == 1 and d["failed"] == 1, d
tests = [(t["name"], t["ok"]) for t in d["tests"]]
assert tests == [("t_pass", True), ("t_fail", False)], f"bench shifted test indices: {tests}"
print("OK mixed bench+test: exact indices", tests)
PY

if "$PIONC" bench --profile=alloc --iters 1 "$TMP/mixed_bt.pion" >/dev/null 2>&1; then
  echo "FAIL: multi-bench --profile without --filter must fail" >&2
  exit 1
fi

# CAS-hit .syms sidecar: warm CAS with --release first, then run --profile=alloc
cat > "$TMP/cas_syms.pion" <<'EOF'
fn cas_alloc_fn(n : Int) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < n {
    let s = "cas_sym_item_" + i.to_string()
    acc = acc + s.length()
    i = i + 1
  }
  acc
}
pub fn main(_world : World) -> Int {
  if cas_alloc_fn(50) > 0 { 0 } else { 1 }
}
EOF
"$PIONC" run --release "$TMP/cas_syms.pion" > /dev/null
CAS_PROF_JSON="$("$PIONC" run --profile=alloc --sample-rate 1 --json "$TMP/cas_syms.pion")"
python3 - "$CAS_PROF_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
matches = [f for f in d["top_functions"] if "cas_alloc_fn" in f["name"]]
assert matches and matches[0]["file"].endswith("cas_syms.pion") and matches[0]["line"] == 1, f"CAS hit lost file/line: {d['top_functions']}"
print("OK CAS-hit .syms:", matches[0]["name"], matches[0]["file"], matches[0]["line"])
PY

# Default build must not silently swallow -s when --profile is absent
if "$PIONC" build -s "$TMP/cas_syms.pion" >/dev/null 2>&1; then
  echo "FAIL: pionc build -s without --profile should fail (baseline behavior)" >&2
  exit 1
fi

# Native build_modes accuracy: --profile=alloc binary run with PION_PROF_MODES=4 must report rc_partial=true
"$PIONC" build --profile=alloc -o "$TMP/alloc_only_bin" "$TMP/alloc_rc.pion"
PION_PROF_OUT="$TMP/rc_partial.raw" PION_PROF_MODES=4 PION_PROF_SAMPLE_RATE=1 "$TMP/alloc_only_bin"
RCP_JSON="$("$PIONC" profile summary "$TMP/rc_partial.raw" --json)"
python3 - "$RCP_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["build_modes"] == 3, f"expected build_modes==3 for --profile=alloc binary, got {d['build_modes']}"
assert d["rc_partial"] is True, f"expected rc_partial==True when running RC mode on alloc-only binary, got {d}"
print("OK native build_modes=3 rc_partial=True")
PY

# Multi-RC setup locals must stay alive across bench_loop and teardown (Native + Wasm32).
# Uses --iters 5 (multiple iterations, still <1ms) to reliably exercise loop-backedge RC lifetime.
cat > "$TMP/multi_rc_bench.pion" <<'EOF'
fn pair_len(a : String, b : String) -> Int {
  a.length() + b.length()
}

bench "multi_rc_setup" {
  let n = 42
  let a = "hello_world_" + n.to_string()
  let b = "foobar_baz_" + n.to_string()
  let mut acc = 0
  bench_loop {
    acc = acc + pair_len(a, b)
    black_box(acc)
  }
  if a.length() + b.length() == 0 { abort("bad_setup") }
}
EOF
MULTI_RC_JSON="$("$PIONC" bench --iters 5 --samples 1 --json "$TMP/multi_rc_bench.pion")"
python3 - "$MULTI_RC_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert len(d["benchmarks"]) == 1 and d["benchmarks"][0]["name"] == "multi_rc_setup", d
print("OK native multi-RC bench setup:", d["benchmarks"][0]["name"])
PY
if command -v node >/dev/null 2>&1; then
  WASM_MULTI_RC_JSON="$("$PIONC" bench --target wasm32 --iters 5 --samples 1 --json "$TMP/multi_rc_bench.pion")"
  python3 - "$WASM_MULTI_RC_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert len(d["benchmarks"]) == 1 and d["benchmarks"][0]["name"] == "multi_rc_setup", d
print("OK wasm32 multi-RC bench setup:", d["benchmarks"][0]["name"])
PY
fi

T1_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
ELAPSED_MS=$((T1_MS - T0_MS))
echo "ALL PROF & BENCH E2E TESTS PASSED in ${ELAPSED_MS}ms!"
