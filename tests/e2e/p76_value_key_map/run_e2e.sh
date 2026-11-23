#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== P76 E2E: Compile-Time Monomorphized Value-Key Map[K, V] ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
struct Tri {
  w0 : Int,
  w1 : Int,
  w2 : Int,
}

fn assert_eq(got : Int, want : Int, label : String) -> Unit {
  if got != want {
    panic(label + ": got=" + got.to_string() + " want=" + want.to_string())
  }
}

fn assert_str(got : String, want : String, label : String) -> Unit {
  if got != want {
    panic(label + ": got=" + got + " want=" + want)
  }
}

fn test_scalar_keys() -> Unit {
  let mi : Map[Int, Int] = Map::with_capacity(64)
  let mut idx = 0
  while idx < 100 {
    mi.set(idx * 3 - 50, idx * 7)
    idx += 1
  }
  assert_eq(mi.length(), 100, "mi_len")
  let mi_copy = mi.copy()
  idx = 0
  while idx < 50 {
    mi.remove(idx * 3 - 50)
    idx += 1
  }
  assert_eq(mi.length(), 50, "mi_after_rm")
  assert_eq(mi_copy.length(), 100, "mi_copy_unchanged")
  let mi_ks = mi.keys()
  assert_eq(mi_ks.length(), 50, "mi_ks_len")
  let mut mi_ksum = 0
  idx = 0
  while idx < mi_ks.length() {
    mi_ksum += mi_ks[idx]
    idx += 1
  }
  // Sum of (idx*3 - 50) for idx=50..99 = 3*(50*149/2) - 50*50 = 11175 - 2500 = 8675
  assert_eq(mi_ksum, 8675, "mi_ksum")
  mi.clear()
  assert_eq(mi.length(), 0, "mi_cleared")

  let mi64 : Map[Int64, String] = Map::with_capacity(32)
  mi64.set(-9000000000000L, "neg")
  mi64.set(0L, "zero")
  mi64.set(9000000000000L, "pos")
  assert_str(mi64[-9000000000000L], "neg", "i64_neg")
  assert_str(mi64[9000000000000L], "pos", "i64_pos")
  let i64_ks = mi64.keys()
  assert_eq(i64_ks.length(), 3, "i64_ks_len")
  let mut i64_sum = 0L
  idx = 0
  while idx < i64_ks.length() {
    i64_sum += i64_ks[idx]
    idx += 1
  }
  if i64_sum != 0L {
    panic("i64_ks_sum mismatch")
  }
  mi64.remove(0L)
  assert_eq(mi64.length(), 2, "i64_after_rm")

  // Bit-63 HashDoS anti-collision check on Map[Int64, Int]
  let mdos : Map[Int64, Int] = Map::with_capacity(4096)
  let bit63 = 1L << 63
  idx = 0
  while idx < 2048 {
    let k0 = idx.to_int64()
    let k1 = k0 | bit63
    mdos.set(k0, idx)
    mdos.set(k1, idx + 10000)
    idx += 1
  }
  assert_eq(mdos.length(), 4096, "mdos_len")
  idx = 0
  while idx < 2048 {
    let k0 = idx.to_int64()
    let k1 = k0 | bit63
    assert_eq(mdos[k0], idx, "mdos_k0")
    assert_eq(mdos[k1], idx + 10000, "mdos_k1")
    idx += 1
  }

  let mu : Map[UInt, Int] = Map([])
  mu.set(1U, 10)
  mu.set(4000000000U, 20)
  assert_eq(mu[1U], 10, "uint1")
  assert_eq(mu[4000000000U], 20, "uint2")

  let mu64 : Map[UInt64, String] = Map([])
  mu64.set(0UL, "zero")
  mu64.set(18446744073709551615UL, "max")
  assert_str(mu64[0UL], "zero", "u64_0")
  assert_str(mu64[18446744073709551615UL], "max", "u64_max")

  let mb : Map[Byte, Int] = Map([])
  mb.set((0).to_byte(), 1)
  mb.set((255).to_byte(), 99)
  assert_eq(mb[(0).to_byte()], 1, "byte0")
  assert_eq(mb[(255).to_byte()], 99, "byte255")
  let mb_ks = mb.keys()
  assert_eq(mb_ks.length(), 2, "mb_ks_len")
  assert_eq(mb_ks[0].to_int() + mb_ks[1].to_int(), 255, "mb_ks_sum")

  let mi8 : Map[Int8, Int] = Map([])
  mi8.set((-128).to_int8(), 128)
  mi8.set((127).to_int8(), 127)
  assert_eq(mi8[(-128).to_int8()], 128, "i8_min")
  assert_eq(mi8[(127).to_int8()], 127, "i8_max")
  let mi8_ks = mi8.keys()
  assert_eq(mi8_ks.length(), 2, "mi8_ks_len")
  assert_eq(mi8_ks[0].to_int() + mi8_ks[1].to_int(), -1, "mi8_ks_sum")

  let mc : Map[Char, Int] = Map([])
  mc.set('a', 97)
  mc.set('中', 20013)
  assert_eq(mc['a'], 97, "char_a")
  assert_eq(mc['中'], 20013, "char_zh")
  let mc_ks = mc.keys()
  assert_eq(mc_ks.length(), 2, "mc_ks_len")
  assert_eq(mc_ks[0].to_int() + mc_ks[1].to_int(), 20110, "mc_ks_sum")

  let mbool : Map[Bool, String] = Map([])
  mbool.set(true, "T")
  mbool.set(false, "F")
  assert_str(mbool[true], "T", "bool_t")
  assert_str(mbool[false], "F", "bool_f")
  let mbool_ks = mbool.keys()
  assert_eq(mbool_ks.length(), 2, "mbool_ks_len")
  if mbool_ks[0] == mbool_ks[1] {
    panic("mbool_ks duplicate")
  }
}

fn test_tuple_keys() -> Unit {
  let m2 : Map[(Int, Int), Int] = Map([])
  let mut i = 0
  while i < 500 {
    m2.set((i, i * 3 - 7), i * 10)
    i += 1
  }
  assert_eq(m2.length(), 500, "m2_len")
  i = 0
  while i < 500 {
    assert_eq(m2.get((i, i * 3 - 7)).unwrap_or(-1), i * 10, "m2_get")
    i += 1
  }
  assert_eq(m2.get((999, 999)).unwrap_or(-42), -42, "m2_miss")

  // RC value overwrite, remove, copy, clear
  let ms : Map[(Int64, Int), String] = Map::with_capacity(64)
  i = 0
  while i < 120 {
    ms.set((i.to_int64() * 1000000007L, i), "v_" + i.to_string())
    i += 1
  }
  // Overwrite
  ms.set((0L, 0), "v_0_new")
  assert_str(ms[(0L, 0)], "v_0_new", "ms_overwrite")
  // Copy + mutate original
  let ms2 = ms.copy()
  assert_eq(ms2.length(), 120, "ms2_len")
  i = 0
  while i < 60 {
    ms.remove((i.to_int64() * 1000000007L, i))
    i += 1
  }
  assert_eq(ms.length(), 60, "ms_after_rm")
  assert_eq(ms2.length(), 120, "ms2_unchanged")
  i = 60
  while i < 120 {
    assert_str(ms[(i.to_int64() * 1000000007L, i)], "v_" + i.to_string(), "ms_survive")
    i += 1
  }
  let ks = ms.keys()
  assert_eq(ks.length(), 60, "ms_keys_len")
  ms.clear()
  assert_eq(ms.length(), 0, "ms_cleared")
  if ms.contains((60.to_int64() * 1000000007L, 60)) {
    panic("ms_cleared_miss")
  }

  // P81 (P76-C): Packed 64-bit hash edge check with signed Int8 (-128/-1) + Byte/Bool
  let m_i8b : Map[(Int8, Byte), Int] = Map([])
  m_i8b.set(((-128).to_int8(), (0).to_byte()), 101)
  m_i8b.set(((-1).to_int8(), (255).to_byte()), 202)
  m_i8b.set(((0).to_int8(), (128).to_byte()), 303)
  m_i8b.set(((127).to_int8(), (1).to_byte()), 404)
  assert_eq(m_i8b.get(((-128).to_int8(), (0).to_byte())).unwrap_or(-1), 101, "i8b_min")
  assert_eq(m_i8b.get(((-1).to_int8(), (255).to_byte())).unwrap_or(-1), 202, "i8b_neg1")
  assert_eq(m_i8b.get(((0).to_int8(), (128).to_byte())).unwrap_or(-1), 303, "i8b_zero")
  assert_eq(m_i8b.get(((127).to_int8(), (1).to_byte())).unwrap_or(-1), 404, "i8b_max")
  assert_eq(m_i8b.get(((-1).to_int8(), (0).to_byte())).unwrap_or(-9), -9, "i8b_miss")

  let m_bi8 : Map[(Bool, Int8), Int] = Map([])
  m_bi8.set((true, (-1).to_int8()), 11)
  m_bi8.set((false, (-1).to_int8()), 22)
  m_bi8.set((true, (-128).to_int8()), 33)
  assert_eq(m_bi8.get((true, (-1).to_int8())).unwrap_or(-1), 11, "bi8_t_neg1")
  assert_eq(m_bi8.get((false, (-1).to_int8())).unwrap_or(-1), 22, "bi8_f_neg1")
  assert_eq(m_bi8.get((true, (-128).to_int8())).unwrap_or(-1), 33, "bi8_t_min")
}

fn test_struct_pod_keys() -> Unit {
  let m : Map[Tri, Int] = Map::with_capacity(256)
  let mut i = 0
  while i < 1000 {
    let k = Tri::{ w0: i, w1: i ^ 0x55, w2: -i }
    m[k] = i + 1
    m[Tri::{ w0: i, w1: i ^ 0x55, w2: -i }] += 10
    i += 1
  }
  assert_eq(m.length(), 1000, "tri_len")

  // Delete every odd key to stress backward-shift probe chains
  i = 1
  while i < 1000 {
    m.remove(Tri::{ w0: i, w1: i ^ 0x55, w2: -i })
    i += 2
  }
  assert_eq(m.length(), 500, "tri_after_rm")
  i = 0
  while i < 1000 {
    let got = match m.get(Tri::{ w0: i, w1: i ^ 0x55, w2: -i }) {
      Some(v) => v
      None => -1
    }
    if i % 2 == 0 {
      assert_eq(got, i + 11, "tri_even")
    } else {
      assert_eq(got, -1, "tri_odd_gone")
    }
    i += 1
  }
  let ks = m.keys()
  assert_eq(ks.length(), 500, "tri_keys_len")
  let mut ksum = 0
  i = 0
  while i < ks.length() {
    ksum += ks[i].w0
    i += 1
  }
  // Sum of even numbers 0..998 = 2 * (499 * 500 / 2) = 249500
  assert_eq(ksum, 249500, "tri_keys_sum")

  // Map[Tri, Array[Int]] RC container value
  let ma : Map[Tri, Array[Int]] = Map([])
  ma.set(Tri::{ w0: 1, w1: 2, w2: 3 }, [10, 20, 30])
  ma.set(Tri::{ w0: 4, w1: 5, w2: 6 }, [40, 50])
  let ma2 = ma.copy()
  ma.remove(Tri::{ w0: 1, w1: 2, w2: 3 })
  assert_eq(ma2[Tri::{ w0: 1, w1: 2, w2: 3 }][2], 30, "ma2_arr")
  ma.clear()
}

fn test_mutex_mt(world : World) -> Unit {
  let init : Map[Tri, String] = Map([])
  init.set(Tri::{ w0: 0, w1: 0, w2: 0 }, "seed")
  let mtx = Mutex::new(init)
  scope(world, fn(s : Scope) -> Unit {
    let mut t = 0
    while t < 4 {
      let tid = t
      spawn(s, fn() -> Unit {
        let mut i = 0
        while i < 50 {
          let m = mtx.lock()
          m.set(Tri::{ w0: tid, w1: i, w2: tid + i }, "t" + tid.to_string() + "_" + i.to_string())
          mtx.unlock()
          i += 1
        }
      })
      t += 1
    }
  })
  let m = mtx.lock()
  assert_eq(m.length(), 200, "mt_len")
  assert_str(m[Tri::{ w0: 0, w1: 0, w2: 0 }], "t0_0", "mt_overwritten")
  assert_str(m[Tri::{ w0: 3, w1: 49, w2: 52 }], "t3_49", "mt_last")
  mtx.unlock()

  // Also test Mutex[Map[Int, String]] scalar-key vmap MT stress
  let init_i : Map[Int, String] = Map::with_capacity(64)
  init_i.set(0, "seed_i")
  let mtx_i = Mutex::new(init_i)
  scope(world, fn(s : Scope) -> Unit {
    let mut t = 0
    while t < 4 {
      let tid = t
      spawn(s, fn() -> Unit {
        let mut i = 0
        while i < 50 {
          let mi = mtx_i.lock()
          mi.set(tid * 100 + i, "s" + tid.to_string() + "_" + i.to_string())
          mtx_i.unlock()
          i += 1
        }
      })
      t += 1
    }
  })
  let mi = mtx_i.lock()
  assert_eq(mi.length(), 200, "mt_i_len")
  assert_str(mi[0], "s0_0", "mt_i_0")
  assert_str(mi[349], "s3_49", "mt_i_last")
  mtx_i.unlock()
}

pub fn main(world : World) -> Int {
  test_scalar_keys()
  test_tuple_keys()
  test_struct_pod_keys()
  test_mutex_mt(world)
  io_println(world, "p76_vmap ok")
  0
}
EOF

# 1. Native release + dev
"$PIONC" build --release -o "$TMP_DIR/p76_rel" "$TMP_DIR/main.pion"
[ "$("$TMP_DIR/p76_rel")" = "p76_vmap ok" ]
echo "1a. Native release -> p76_vmap ok"

"$PIONC" build -o "$TMP_DIR/p76_dev" "$TMP_DIR/main.pion"
[ "$("$TMP_DIR/p76_dev")" = "p76_vmap ok" ]
echo "1b. Native dev -> p76_vmap ok"

# 2. Negative typecheck cases (E_MAP_KEY_TYPE)
check_bad_key() {
  label="$1"
  src="$2"
  cat > "$TMP_DIR/bad_${label}.pion" <<EOF
$src
EOF
  OUT="$("$PIONC" check --json "$TMP_DIR/bad_${label}.pion" 2>&1 || true)"
  if ! printf '%s' "$OUT" | grep -q 'E_MAP_KEY_TYPE'; then
    echo "FAIL: bad key $label did not report E_MAP_KEY_TYPE: $OUT" >&2
    exit 1
  fi
}
check_bad_key "float" 'pub fn main() -> Int { let _m : Map[Float, Int] = Map([]); 0 }'
check_bad_key "tuple_double" 'pub fn main() -> Int { let _m : Map[(Int, Double), Int] = Map([]); 0 }'
check_bad_key "mut_struct" 'struct Bad { mut a : Int, b : Int } pub fn main() -> Int { let _m : Map[Bad, Int] = Map([]); 0 }'
echo "2. Negative E_MAP_KEY_TYPE checks (3 cases) -> OK"

# 3. SSA audit: zero pion_alloc_uninit in hot vmap set/get loop
cat > "$TMP_DIR/audit.pion" <<'EOF'
pub fn hot_vmap(m : Map[(Int, Int, Int), Int], n : Int) -> Int {
  let mut i = 0
  let mut acc = 0
  while i < n {
    let cur = m.get((i, i + 1, i + 2)).unwrap_or(0)
    m.set((i, i + 1, i + 2), cur + 1)
    acc += cur
    i += 1
  }
  acc
}
pub fn main() -> Int {
  let m : Map[(Int, Int, Int), Int] = Map::with_capacity(64)
  hot_vmap(m, 10)
}
EOF
"$PIONC" build --release --emit-ssa "$TMP_DIR/audit.ssa" "$TMP_DIR/audit.pion"
HOT_BODY="$(awk '/\$pion_fn_hot_vmap/,/^}/' "$TMP_DIR/audit.ssa")"
if printf '%s' "$HOT_BODY" | grep -q 'pion_alloc_uninit'; then
  echo "FAIL: hot_vmap SSA still allocates inside loop!" >&2
  printf '%s\n' "$HOT_BODY" >&2
  exit 1
fi
  if ! printf '%s' "$HOT_BODY" | grep -q 'pion_vmap_get_or_'; then
    echo "FAIL: hot_vmap SSA did not lower m.get().unwrap_or() to pion_vmap_get_or_" >&2
    exit 1
  fi
  echo "3. SSA audit (0 pion_alloc_uninit in hot_vmap + register-return pion_vmap_get_or_) -> OK"

# 4. Native ASan/LSan (0 leaks)
CC_BIN="${CC:-cc}"
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'EOF' >/dev/null 2>&1
int main(void) { return 0; }
EOF
then
  "$PIONC" build --release --emit-asm "$TMP_DIR/p76.s" "$TMP_DIR/main.pion"
  "$CC_BIN" -fsanitize=address -g -O1 "$TMP_DIR/p76.s" "$ROOT_DIR/runtime/pion_rt.c" -lm -lpthread -o "$TMP_DIR/p76_asan"
  [ "$("$TMP_DIR/p76_asan")" = "p76_vmap ok" ]
  echo "4. Native ASan/LSan (0 leaks) -> OK"
else
  echo "4. Native ASan/LSan -> SKIP (cc lacks -fsanitize=address)"
fi

# 5. Wasm32 (Node + Web runtimes)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p76.wasm" "$TMP_DIR/main.pion"
  OUT_NODE="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p76.wasm")"
  [ "$OUT_NODE" = "p76_vmap ok" ]
  OUT_WEB="$(node --input-type=module -e '
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
  ' "$TMP_DIR/p76.wasm" "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs")"
  [ "$OUT_WEB" = "p76_vmap ok" ]
  echo "5. Wasm32 (Node + Web runtimes) -> OK"
else
  echo "5. Wasm32 -> SKIP (no node)"
fi

# 6. M4-isomorphic 200K trigram RSS & latency benchmark
cat > "$TMP_DIR/bench_vmap.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let n = 200000
  let t0 = clock_now_ms(world)
  let m : Map[(Int, Int, Int), Int] = Map::with_capacity(n)
  let mut i = 0
  while i < n {
    let a = i % 500
    let b = (i * 7 + 3) % 500
    let c = i
    let prev = m.get((a, b, c)).unwrap_or(0)
    m.set((a, b, c), prev + 1)
    i += 1
  }
  let mut sum = 0
  i = 0
  while i < n {
    let a = i % 500
    let b = (i * 7 + 3) % 500
    let c = i
    sum += m.get((a, b, c)).unwrap_or(0)
    i += 1
  }
  let t1 = clock_now_ms(world)
  if sum != n {
    panic("vmap sum mismatch")
  }
  io_println(world, "vmap_200k_ms=" + (t1 - t0).to_string() + " len=" + m.length().to_string())
  0
}
EOF

cat > "$TMP_DIR/bench_str.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let n = 200000
  let t0 = clock_now_ms(world)
  let m : Map[String, Int] = Map([])
  let mut i = 0
  while i < n {
    let a = i % 500
    let b = (i * 7 + 3) % 500
    let c = i
    let k = a.to_string() + ":" + b.to_string() + ":" + c.to_string()
    let prev = m.get(k).unwrap_or(0)
    m.set(k, prev + 1)
    i += 1
  }
  let mut sum = 0
  i = 0
  while i < n {
    let a = i % 500
    let b = (i * 7 + 3) % 500
    let c = i
    let k = a.to_string() + ":" + b.to_string() + ":" + c.to_string()
    sum += m.get(k).unwrap_or(0)
    i += 1
  }
  let t1 = clock_now_ms(world)
  if sum != n {
    panic("strmap sum mismatch")
  }
  io_println(world, "strmap_200k_ms=" + (t1 - t0).to_string() + " len=" + m.length().to_string())
  0
}
EOF

"$PIONC" build --release -o "$TMP_DIR/bench_vmap" "$TMP_DIR/bench_vmap.pion"
"$PIONC" build --release -o "$TMP_DIR/bench_str" "$TMP_DIR/bench_str.pion"

RSS_KB=0
STR_RSS_KB=0
if command -v python3 >/dev/null 2>&1; then
  VMAP_OUT="$("$TMP_DIR/bench_vmap")"
  RSS_KB="$(python3 -c '
import resource, subprocess, sys
p = subprocess.run([sys.argv[1]], stdout=subprocess.DEVNULL, check=True)
r = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(r // 1024 if sys.platform == "darwin" else r)
' "$TMP_DIR/bench_vmap")"
  STR_OUT="$("$TMP_DIR/bench_str")"
  STR_RSS_KB="$(python3 -c '
import resource, subprocess, sys
p = subprocess.run([sys.argv[1]], stdout=subprocess.DEVNULL, check=True)
r = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(r // 1024 if sys.platform == "darwin" else r)
' "$TMP_DIR/bench_str")"
elif [ -x /usr/bin/time ]; then
  if [ "$(uname -s)" = "Linux" ]; then
    VMAP_OUT="$("$TMP_DIR/bench_vmap")"
    RSS_KB="$(/usr/bin/time -f '%M' "$TMP_DIR/bench_vmap" 2>&1 >/dev/null | tr -dc '0-9')"
  else
    VMAP_OUT="$("$TMP_DIR/bench_vmap")"
    RSS_BYTES="$(/usr/bin/time -l "$TMP_DIR/bench_vmap" 2>&1 >/dev/null | awk '/maximum resident set size/{print $1}')"
    RSS_KB="$((RSS_BYTES / 1024))"
  fi
  STR_OUT="$("$TMP_DIR/bench_str")"
else
  VMAP_OUT="$("$TMP_DIR/bench_vmap")"
  STR_OUT="$("$TMP_DIR/bench_str")"
fi
echo "6. 200K trigram: $VMAP_OUT rss_kb=$RSS_KB | $STR_OUT rss_kb=$STR_RSS_KB"
if [ "$RSS_KB" -gt 0 ] && [ "$RSS_KB" -gt 16384 ]; then
  echo "FAIL: 200K trigram vmap RSS ${RSS_KB} KB > 16384 KB (16 MB)" >&2
  exit 1
fi

# 7. P76-B: Map[Int64, Int64] 100K write + 500K lookup RSS gate (<= 12288 KB / 12 MB)
cat > "$TMP_DIR/bench_i64.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let n = 100000
  let t0 = clock_now_ms(world)
  let m : Map[Int64, Int64] = Map::with_capacity(n)
  let mut i = 0
  while i < n {
    let k = i.to_int64() * 6364136223846793005L + 1L
    m.set(k, i.to_int64() + 1L)
    i += 1
  }
  let mut sum = 0L
  let mut round = 0
  while round < 5 {
    i = 0
    while i < n {
      let k = i.to_int64() * 6364136223846793005L + 1L
      sum += m.get(k).unwrap_or(0L)
      i += 1
    }
    round += 1
  }
  let t1 = clock_now_ms(world)
  // sum = 5 * (100000 * 100001 / 2) = 25000250000
  if sum != 25000250000L {
    panic("i64 map sum mismatch")
  }
  io_println(world, "i64map_100k_w_500k_r_ms=" + (t1 - t0).to_string() + " len=" + m.length().to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/bench_i64" "$TMP_DIR/bench_i64.pion"
I64_RSS_KB=0
I64_OUT="$("$TMP_DIR/bench_i64")"
if command -v python3 >/dev/null 2>&1; then
  I64_RSS_KB="$(python3 -c '
import os, sys
pid = os.posix_spawn(sys.argv[1], [sys.argv[1]], os.environ, file_actions=[(os.POSIX_SPAWN_OPEN, 1, os.devnull, os.O_WRONLY, 0)])
_, st, ru = os.wait4(pid, 0)
if st != 0:
    sys.exit(1)
r = ru.ru_maxrss
print(r // 1024 if sys.platform == "darwin" else r)
' "$TMP_DIR/bench_i64")"
fi
echo "7. 100K Map[Int64, Int64] (100K w + 500K r): $I64_OUT rss_kb=$I64_RSS_KB"
if [ "$I64_RSS_KB" -gt 0 ] && [ "$I64_RSS_KB" -gt 12288 ]; then
  echo "FAIL: 100K Map[Int64, Int64] RSS ${I64_RSS_KB} KB > 12288 KB (12 MB)" >&2
  exit 1
fi

# 8. P81 (P76-C): Map[(Int, Int), Int64] 100K write + 500K get().unwrap_or(0L) + SSA audit
cat > "$TMP_DIR/bench_pair_i64.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let n = 100000
  let t0 = clock_now_ms(world)
  let m : Map[(Int, Int), Int64] = Map::with_capacity(n)
  let mut i = 0
  while i < n {
    let a = i % 1000
    let b = i / 1000
    m.set((a, b), i.to_int64() + 1L)
    i += 1
  }
  let mut sum = 0L
  let mut round = 0
  while round < 5 {
    i = 0
    while i < n {
      let a = i % 1000
      let b = i / 1000
      sum += m.get((a, b)).unwrap_or(0L)
      i += 1
    }
    round += 1
  }
  let t1 = clock_now_ms(world)
  if sum != 25000250000L {
    panic("pair_i64 map sum mismatch")
  }
  io_println(world, "pair_i64_100k_w_500k_r_ms=" + (t1 - t0).to_string() + " len=" + m.length().to_string())
  0
}
EOF
"$PIONC" build --release --emit-ssa "$TMP_DIR/bench_pair_i64.ssa" "$TMP_DIR/bench_pair_i64.pion"
PAIR_GET_OR="$(awk '/function .* \$pion_vmap_get_or_/,/^}/' "$TMP_DIR/bench_pair_i64.ssa")"
if ! printf '%s' "$PAIR_GET_OR" | grep -q '%sk_go =l loadl %sp'; then
  echo "FAIL: Map[(Int, Int), Int64] get_or did not emit single 64-bit loadl key_cmp" >&2
  printf '%s\n' "$PAIR_GET_OR" >&2
  exit 1
fi
if ! printf '%s' "$PAIR_GET_OR" | grep -q '%keq_go =w ceql %kpk_go, %sk_go'; then
  echo "FAIL: Map[(Int, Int), Int64] get_or did not emit single 64-bit ceql key_cmp" >&2
  printf '%s\n' "$PAIR_GET_OR" >&2
  exit 1
fi
"$PIONC" build --release -o "$TMP_DIR/bench_pair_i64" "$TMP_DIR/bench_pair_i64.pion"
PAIR_OUT="$("$TMP_DIR/bench_pair_i64")"
echo "8. P81 Map[(Int, Int), Int64] (100K w + 500K r, 64-bit packed hash+cmp+get_or): $PAIR_OUT"

echo "PASS: p76_value_key_map"
