#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BENCH_DIR="$ROOT_DIR/benchmarks"
OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"

MODE="all"
if [ "${1:-}" = "--check-pion" ]; then
  MODE="check-pion"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pion-bench.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/exec" "$WORK/scale10k"

# Build pure-C benchmark tools (zero Python)
clang -O2 -Wall -Wextra -o "$WORK/bin/bench_measure" "$BENCH_DIR/tools/bench_measure.c"
clang -O2 -Wall -Wextra -o "$WORK/bin/gen_compile_bench" "$BENCH_DIR/tools/gen_compile_bench.c"

MEASURE="$WORK/bin/bench_measure"
GEN="$WORK/bin/gen_compile_bench"

# ---------------------------------------------------------------------------
# Mode: --check-pion (verify all benchmarks/pion/*.pion + 10k-LOC generated Pion)
# ---------------------------------------------------------------------------
check_pion_sources() {
  COMPILER_DIR="$ROOT_DIR/compiler"
  PIONC0="$COMPILER_DIR/_build/native/debug/build/compat_moon/compat_moon.exe"
  if [ ! -x "$PIONC0" ]; then
    echo "=== Building Stage 0 pionc0 (moon build --target native) ==="
    (cd "$COMPILER_DIR" && moon build --target native)
  fi

  echo "=== Checking benchmarks/pion/*.pion with pionc0 check --json ==="
  pion_fail=0
  for f in "$BENCH_DIR"/pion/*.pion; do
    base=$(basename "$f")
    set +e
    out=$("$PIONC0" check --json "$f" 2>&1)
    rc=$?
    set -e
    printf '  %-20s -> %s\n' "$base" "$out"
    if [ "$rc" -ne 0 ] || [ "$out" != '{"ok":true,"diagnostics":[]}' ]; then
      pion_fail=1
    fi
  done

  echo "=== Checking generated 10,000-LOC / 20-package pion project ==="
  "$GEN" "$WORK/scale10k"
  set +e
  out=$("$PIONC0" check --json "$WORK/scale10k/pion" 2>&1)
  rc=$?
  set -e
  printf '  %-20s -> %s\n' "scale10k/pion (20 pkg)" "$out"
  if [ "$rc" -ne 0 ] || [ "$out" != '{"ok":true,"diagnostics":[]}' ]; then
    pion_fail=1
  fi
  if [ "$pion_fail" -ne 0 ]; then
    echo "FAIL: one or more pion benchmark sources failed pionc0 check" >&2
    exit 1
  fi
  echo "ALL PION BENCHMARK SOURCES PASSED pionc0 check --json (ok:true)!"
}

if [ "$MODE" = "check-pion" ]; then
  check_pion_sources
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
file_bytes() {
  stat -f%z "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

dir_bytes() {
  if [ ! -d "$1" ]; then
    echo 0
    return
  fi
  # du -sk returns KiB; use find+stat for exact bytes on macOS
  find "$1" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {printf "%d\n", s+0}'
}

stripped_bytes() {
  src="$1"
  tmp="$WORK/bin/_strip_tmp"
  cp "$src" "$tmp"
  strip "$tmp" 2>/dev/null || true
  sz=$(file_bytes "$tmp")
  rm -f "$tmp"
  echo "$sz"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Detect available toolchains
HAS_C=0; command -v clang >/dev/null 2>&1 && HAS_C=1
HAS_MOON=0; command -v moon >/dev/null 2>&1 && HAS_MOON=1
HAS_ZIG=0; command -v zig >/dev/null 2>&1 && HAS_ZIG=1
HAS_RUST=0; command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 && HAS_RUST=1
HAS_PION=0
if [ -n "${PIONC:-}" ] && [ -x "${PIONC:-}" ]; then
  HAS_PION=1
fi

CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
OS_VER=$(uname -srm)
CLANG_VER=$(clang --version 2>&1 | head -n 1 || echo "N/A")
MOON_VER=$( [ "$HAS_MOON" -eq 1 ] && moon --version 2>&1 | head -n 1 || echo "N/A" )
ZIG_VER=$( [ "$HAS_ZIG" -eq 1 ] && zig version 2>&1 | head -n 1 || echo "N/A" )
RUST_VER=$( [ "$HAS_RUST" -eq 1 ] && rustc --version 2>&1 | head -n 1 || echo "N/A" )
CARGO_VER=$( [ "$HAS_RUST" -eq 1 ] && cargo --version 2>&1 | head -n 1 || echo "N/A" )
PION_VER=$( [ "$HAS_PION" -eq 1 ] && ("$PIONC" --version 2>&1 | head -n 1 || echo "$PIONC") || echo "not provided (pass PIONC=/path/to/pionc)" )

echo "================================================================="
echo " pion Multi-Language Objective Benchmark Suite (D5)"
echo "================================================================="
echo "Host   : $CPU_BRAND ($CPU_CORES cores) | $OS_VER"
echo "C      : $CLANG_VER"
echo "MoonBit: $MOON_VER"
echo "Zig    : $ZIG_VER"
echo "Rust   : $RUST_VER / $CARGO_VER"
echo "pion     : $PION_VER"
echo "================================================================="

# ---------------------------------------------------------------------------
# 1. Build execution benchmarks (hello + 6 classic benchmarks)
# ---------------------------------------------------------------------------
BENCHES="hello nbody binarytrees spectralnorm fannkuchredux mandelbrot_mt hashmap_str"

mkdir -p "$WORK/exec/c" "$WORK/exec/zig" "$WORK/exec/rust" "$WORK/exec/pion"

if [ "$HAS_C" -eq 1 ]; then
  echo ">>> Building C (-O2 -ffp-contract=off)..."
  for b in $BENCHES; do
    clang -O2 -ffp-contract=off -o "$WORK/exec/c/$b" "$BENCH_DIR/c/$b.c" -lm -lpthread
  done
fi

if [ "$HAS_MOON" -eq 1 ]; then
  echo ">>> Building MoonBit (moon build --target native --release)..."
  cp -R "$BENCH_DIR/moonbit" "$WORK/exec/moonbit"
  (cd "$WORK/exec/moonbit" && moon build --target native --release >/dev/null)
fi

if [ "$HAS_ZIG" -eq 1 ]; then
  echo ">>> Building Zig (-OReleaseFast)..."
  mkdir -p "$WORK/exec/zig-cache"
  for b in $BENCHES; do
    (cd "$WORK/exec/zig" && zig build-exe -OReleaseFast -lc \
      --cache-dir "$WORK/exec/zig-cache" \
      --global-cache-dir "$WORK/exec/zig-global-cache" \
      -femit-bin="$WORK/exec/zig/$b" \
      "$BENCH_DIR/zig/$b.zig")
  done
fi

if [ "$HAS_RUST" -eq 1 ]; then
  echo ">>> Building Rust (rustc -O)..."
  for b in $BENCHES; do
    rustc -O -o "$WORK/exec/rust/$b" "$BENCH_DIR/rust/$b.rs"
  done
fi

if [ "$HAS_PION" -eq 1 ]; then
  echo ">>> Building pion ($PIONC build --release)..."
  export PION_CACHE_DIR="$WORK/pion-cas"
  mkdir -p "$PION_CACHE_DIR"
  for b in $BENCHES; do
    "$PIONC" build --release "$BENCH_DIR/pion/$b.pion" -o "$WORK/exec/pion/$b"
  done
fi

bin_path() {
  lang="$1"
  bench="$2"
  case "$lang" in
    c)       echo "$WORK/exec/c/$bench" ;;
    moonbit) echo "$WORK/exec/moonbit/_build/native/release/build/$bench/$bench.exe" ;;
    zig)     echo "$WORK/exec/zig/$bench" ;;
    rust)    echo "$WORK/exec/rust/$bench" ;;
    pion)      echo "$WORK/exec/pion/$bench" ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. Run execution benchmarks (1 warmup + 5 timed runs, assert exact checksums)
# ---------------------------------------------------------------------------
EXEC_TSV="$WORK/exec_results.tsv"
: > "$EXEC_TSV"
CHECKSUM_FILE="$WORK/checksums.tsv"
: > "$CHECKSUM_FILE"

LANGS=""
[ "$HAS_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAS_MOON" -eq 1 ] && LANGS="$LANGS moonbit"
[ "$HAS_ZIG" -eq 1 ] && LANGS="$LANGS zig"
[ "$HAS_RUST" -eq 1 ] && LANGS="$LANGS rust"
[ "$HAS_PION" -eq 1 ] && LANGS="$LANGS pion"

run_case() {
  case_name="$1"
  bench_bin="$2"
  extra_arg="${3:-}"
  skip_moon="${4:-0}"

  expected_ck=""
  echo ">>> Benchmarking $case_name (1 warmup + 5 runs)..."
  for lang in $LANGS; do
    if [ "$lang" = "moonbit" ] && [ "$skip_moon" -eq 1 ]; then
      printf '%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\n' "$case_name" "$lang" >> "$EXEC_TSV"
      continue
    fi
    bp=$(bin_path "$lang" "$bench_bin")
    if [ -n "$extra_arg" ]; then
      line=$(BENCH_THREADS="$extra_arg" "$MEASURE" exec 1 5 -- "$bp" "$extra_arg")
    else
      line=$("$MEASURE" exec 1 5 -- "$bp")
    fi
    med=$(printf '%s' "$line" | cut -f1)
    min=$(printf '%s' "$line" | cut -f2)
    max=$(printf '%s' "$line" | cut -f3)
    rss=$(printf '%s' "$line" | cut -f4)
    ins=$(printf '%s' "$line" | cut -f5)
    ck=$(printf '%s' "$line" | cut -f6)

    if [ -z "$expected_ck" ]; then
      expected_ck="$ck"
    elif [ "$ck" != "$expected_ck" ]; then
      echo "FATAL: Checksum mismatch on $case_name! $lang produced '$ck', expected '$expected_ck'" >&2
      exit 1
    fi
    printf '  %-8s | %8s ms (min %s, max %s) | RSS %6s MB | instr %14s | checksum: %s\n' \
      "$lang" "$med" "$min" "$max" "$rss" "$ins" "$ck"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$case_name" "$lang" "$med" "$min" "$max" "$rss" "$ins" "$ck" >> "$EXEC_TSV"
  done
  printf '%s\t%s\n' "$case_name" "$expected_ck" >> "$CHECKSUM_FILE"
}

run_case "nbody"           "nbody"         ""  0
run_case "binarytrees"     "binarytrees"   ""  0
run_case "spectralnorm"    "spectralnorm"  ""  0
run_case "fannkuchredux"   "fannkuchredux" ""  0
run_case "mandelbrot_1t"   "mandelbrot_mt" "1" 0
run_case "mandelbrot_4t"   "mandelbrot_mt" "4" 1
run_case "hashmap_str"     "hashmap_str"   ""  0

# Verify mandelbrot_1t and mandelbrot_4t produced identical checksums
CK_M1=$(awk -F'\t' '$1=="mandelbrot_1t"{print $2}' "$CHECKSUM_FILE")
CK_M4=$(awk -F'\t' '$1=="mandelbrot_4t"{print $2}' "$CHECKSUM_FILE")
if [ "$CK_M1" != "$CK_M4" ]; then
  echo "FATAL: mandelbrot_1t ($CK_M1) != mandelbrot_4t ($CK_M4)" >&2
  exit 1
fi
echo ">>> All execution checksums verified bit-for-bit identical across languages!"

# ---------------------------------------------------------------------------
# 3. Compile Speed Benchmark (10,000 LOC / 20 packages: Cold + 1-line Incr)
# ---------------------------------------------------------------------------
echo ">>> Generating 10,000-LOC / 20-package projects..."
"$GEN" "$WORK/scale10k"

COMPILE_TSV="$WORK/compile_results.tsv"
: > "$COMPILE_TSV"

# Generate C Makefile (separate compilation of 20 packages + main)
cat > "$WORK/scale10k/c/Makefile" <<'EOF'
CC = clang
CFLAGS = -O2
OBJS = pkg00.o pkg01.o pkg02.o pkg03.o pkg04.o pkg05.o pkg06.o pkg07.o pkg08.o pkg09.o \
       pkg10.o pkg11.o pkg12.o pkg13.o pkg14.o pkg15.o pkg16.o pkg17.o pkg18.o pkg19.o main.o

app: $(OBJS)
	$(CC) $(CFLAGS) -o app $(OBJS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
EOF

COLD_CK=""
INCR_CK=""

check_scale_ck() {
  phase="$1"
  lang="$2"
  val="$3"
  if [ "$phase" = "cold" ]; then
    if [ -z "$COLD_CK" ]; then COLD_CK="$val"
    elif [ "$val" != "$COLD_CK" ]; then
      echo "FATAL: scale10k cold checksum mismatch: $lang=$val expected=$COLD_CK" >&2
      exit 1
    fi
  else
    if [ -z "$INCR_CK" ]; then INCR_CK="$val"
    elif [ "$val" != "$INCR_CK" ]; then
      echo "FATAL: scale10k incr checksum mismatch: $lang=$val expected=$INCR_CK" >&2
      exit 1
    fi
  fi
}

# Cold builds
if [ "$HAS_C" -eq 1 ]; then
  echo ">>> Cold compile (10k LOC / 20 pkgs): C (make -j8 clang -O2)..."
  C_COLD=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/c' && make -j8 >/dev/null")
  C_CK1=$("$WORK/scale10k/c/app")
  check_scale_ck cold c "$C_CK1"
  C_CACHE=$(find "$WORK/scale10k/c" -name '*.o' -exec stat -f%z {} + | awk '{s+=$1} END {printf "%d\n", s+0}')
fi

if [ "$HAS_MOON" -eq 1 ]; then
  echo ">>> Cold compile (10k LOC / 20 pkgs): MoonBit (moon build --target native --release)..."
  MOON_COLD=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/moonbit' && moon build --target native --release >/dev/null")
  MOON_CK1=$("$WORK/scale10k/moonbit/_build/native/release/build/app/app.exe")
  check_scale_ck cold moonbit "$MOON_CK1"
  MOON_CACHE=$(dir_bytes "$WORK/scale10k/moonbit/_build")
fi

if [ "$HAS_ZIG" -eq 1 ]; then
  echo ">>> Cold compile (10k LOC / 20 pkgs): Zig (zig build-exe -OReleaseFast)..."
  ZIG_COLD=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/zig' && zig build-exe -OReleaseFast -lc --cache-dir '$WORK/scale10k/zig/.zig-cache' --global-cache-dir '$WORK/scale10k/zig-global-cache' -femit-bin='$WORK/scale10k/zig/app' main.zig")
  ZIG_CK1=$("$WORK/scale10k/zig/app")
  check_scale_ck cold zig "$ZIG_CK1"
  ZIG_CACHE=$(dir_bytes "$WORK/scale10k/zig/.zig-cache")
fi

if [ "$HAS_RUST" -eq 1 ]; then
  echo ">>> Cold compile (10k LOC / 20 pkgs): Rust (cargo build --release)..."
  RUST_COLD=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/rust' && cargo build --release --quiet")
  RUST_CK1=$("$WORK/scale10k/rust/target/release/app")
  check_scale_ck cold rust "$RUST_CK1"
  RUST_CACHE=$(dir_bytes "$WORK/scale10k/rust/target")
fi

if [ "$HAS_PION" -eq 1 ]; then
  echo ">>> Cold compile (10k LOC / 20 pkgs): pion ($PIONC build)..."
  export PION_CACHE_DIR="$WORK/scale10k/pion-cas"
  mkdir -p "$PION_CACHE_DIR"
  PION_COLD=$("$MEASURE" once -- "$PIONC" build "$WORK/scale10k/pion" -o "$WORK/scale10k/pion_app")
  PION_CK1=$("$WORK/scale10k/pion_app")
  check_scale_ck cold pion "$PION_CK1"
  PION_INTREE_CACHE=0
  PION_CAS_CACHE=$(dir_bytes "$PION_CACHE_DIR")
fi

# Sleep 1 second so filesystem mtime (1s granularity in make) reliably sees pkg05 edit
sleep 1
echo ">>> Mutating 1 line in pkg05 function body (pub signature unchanged)..."
"$GEN" "$WORK/scale10k" --mutate

# Incremental builds
if [ "$HAS_C" -eq 1 ]; then
  C_INCR=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/c' && make -j8 >/dev/null")
  C_CK2=$("$WORK/scale10k/c/app")
  check_scale_ck incr c "$C_CK2"
  printf 'c\t%s\t%s\t%s\t0\t%s\t%s\n' "$C_COLD" "$C_INCR" "$C_CACHE" "$C_CK1" "$C_CK2" >> "$COMPILE_TSV"
fi

if [ "$HAS_MOON" -eq 1 ]; then
  MOON_INCR=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/moonbit' && moon build --target native --release >/dev/null")
  MOON_CK2=$("$WORK/scale10k/moonbit/_build/native/release/build/app/app.exe")
  check_scale_ck incr moonbit "$MOON_CK2"
  printf 'moonbit\t%s\t%s\t%s\t0\t%s\t%s\n' "$MOON_COLD" "$MOON_INCR" "$MOON_CACHE" "$MOON_CK1" "$MOON_CK2" >> "$COMPILE_TSV"
fi

if [ "$HAS_ZIG" -eq 1 ]; then
  ZIG_INCR=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/zig' && zig build-exe -OReleaseFast -lc --cache-dir '$WORK/scale10k/zig/.zig-cache' --global-cache-dir '$WORK/scale10k/zig-global-cache' -femit-bin='$WORK/scale10k/zig/app' main.zig")
  ZIG_CK2=$("$WORK/scale10k/zig/app")
  check_scale_ck incr zig "$ZIG_CK2"
  printf 'zig\t%s\t%s\t%s\t0\t%s\t%s\n' "$ZIG_COLD" "$ZIG_INCR" "$ZIG_CACHE" "$ZIG_CK1" "$ZIG_CK2" >> "$COMPILE_TSV"
fi

if [ "$HAS_RUST" -eq 1 ]; then
  RUST_INCR=$("$MEASURE" once -- sh -c "cd '$WORK/scale10k/rust' && cargo build --release --quiet")
  RUST_CK2=$("$WORK/scale10k/rust/target/release/app")
  check_scale_ck incr rust "$RUST_CK2"
  printf 'rust\t%s\t%s\t%s\t0\t%s\t%s\n' "$RUST_COLD" "$RUST_INCR" "$RUST_CACHE" "$RUST_CK1" "$RUST_CK2" >> "$COMPILE_TSV"
fi

if [ "$HAS_PION" -eq 1 ]; then
  PION_INCR=$("$MEASURE" once -- "$PIONC" build "$WORK/scale10k/pion" -o "$WORK/scale10k/pion_app")
  PION_CK2=$("$WORK/scale10k/pion_app")
  check_scale_ck incr pion "$PION_CK2"
  printf 'pion\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PION_COLD" "$PION_INCR" "$PION_INTREE_CACHE" "$PION_CAS_CACHE" "$PION_CK1" "$PION_CK2" >> "$COMPILE_TSV"
fi

if [ "$COLD_CK" = "$INCR_CK" ]; then
  echo "FATAL: incremental mutation did not change output checksum ($COLD_CK)" >&2
  exit 1
fi
echo ">>> Scale10k checksums verified: cold=$COLD_CK -> incr=$INCR_CK (identical across all languages)"

# ---------------------------------------------------------------------------
# 4. Artifact Sizes (Hello World & 6 Benchmarks, Default & Stripped)
# ---------------------------------------------------------------------------
SIZE_TSV="$WORK/size_results.tsv"
: > "$SIZE_TSV"

for lang in $LANGS; do
  for b in $BENCHES; do
    bp=$(bin_path "$lang" "$b")
    def_sz=$(file_bytes "$bp")
    str_sz=$(stripped_bytes "$bp")
    printf '%s\t%s\t%s\t%s\n' "$lang" "$b" "$def_sz" "$str_sz" >> "$SIZE_TSV"
  done
done

# ---------------------------------------------------------------------------
# 5. Emit Structured JSON (out/bench-results.json)
# ---------------------------------------------------------------------------
JSON_OUT="$OUT_DIR/bench-results.json"
{
  printf '{\n'
  printf '  "host": {\n'
  printf '    "cpu": "%s",\n' "$(json_escape "$CPU_BRAND")"
  printf '    "cores": %s,\n' "$CPU_CORES"
  printf '    "os": "%s"\n' "$(json_escape "$OS_VER")"
  printf '  },\n'
  printf '  "toolchains": {\n'
  printf '    "c": "%s",\n' "$(json_escape "$CLANG_VER")"
  printf '    "moonbit": "%s",\n' "$(json_escape "$MOON_VER")"
  printf '    "zig": "%s",\n' "$(json_escape "$ZIG_VER")"
  printf '    "rust": "%s",\n' "$(json_escape "$RUST_VER")"
  printf '    "cargo": "%s",\n' "$(json_escape "$CARGO_VER")"
  printf '    "pion": "%s"\n' "$(json_escape "$PION_VER")"
  printf '  },\n'

  printf '  "execution": [\n'
  awk -F'\t' '
    NR > 1 { printf ",\n" }
    {
      if ($3 == "N/A") {
        printf "    {\"bench\":\"%s\",\"lang\":\"%s\",\"median_ms\":null,\"min_ms\":null,\"max_ms\":null,\"peak_rss_mb\":null,\"instructions_retired\":null,\"checksum\":null}", $1, $2
      } else {
        printf "    {\"bench\":\"%s\",\"lang\":\"%s\",\"median_ms\":%s,\"min_ms\":%s,\"max_ms\":%s,\"peak_rss_mb\":%s,\"instructions_retired\":%s,\"checksum\":\"%s\"}", $1, $2, $3, $4, $5, $6, $7, $8
      }
    }
    END { printf "\n" }
  ' "$EXEC_TSV"
  printf '  ],\n'

  printf '  "compile_10k_loc_20_pkg": [\n'
  awk -F'\t' '
    NR > 1 { printf ",\n" }
    {
      printf "    {\"lang\":\"%s\",\"cold_ms\":%s,\"incr_1line_ms\":%s,\"worktree_cache_bytes\":%s,\"global_cas_bytes\":%s,\"cold_checksum\":\"%s\",\"incr_checksum\":\"%s\"}", $1, $2, $3, $4, $5, $6, $7
    }
    END { printf "\n" }
  ' "$COMPILE_TSV"
  printf '  ],\n'

  printf '  "binary_sizes": [\n'
  awk -F'\t' '
    NR > 1 { printf ",\n" }
    {
      printf "    {\"lang\":\"%s\",\"bench\":\"%s\",\"default_bytes\":%s,\"stripped_bytes\":%s}", $1, $2, $3, $4
    }
    END { printf "\n" }
  ' "$SIZE_TSV"
  printf '  ]\n'
  printf '}\n'
} > "$JSON_OUT"

# ---------------------------------------------------------------------------
# 6. Emit Clean Markdown Summary (out/bench-summary.md + stdout)
# ---------------------------------------------------------------------------
MD_OUT="$OUT_DIR/bench-summary.md"
{
  echo "# pion Multi-Language Objective Benchmark Report"
  echo ""
  echo "- **Machine**: \`$CPU_BRAND\` ($CPU_CORES cores), \`$OS_VER\`"
  echo "- **Methodology**: 1 warmup + 5 timed runs (median wall ms), Peak RSS (MB) & \`instructions retired\` via \`/usr/bin/time -l\`, strict bit-for-bit checksum assertion across all languages."
  echo "- **Toolchains**:"
  echo "  - C: \`$CLANG_VER\` (\`-O2\`)"
  echo "  - MoonBit: \`$MOON_VER\` (\`moon build --target native --release\`)"
  echo "  - Zig: \`$ZIG_VER\` (\`-OReleaseFast\`)"
  echo "  - Rust: \`$RUST_VER\` / \`$CARGO_VER\` (\`rustc -O\` / \`cargo build --release\`)"
  echo "  - pion: \`$PION_VER\`"
  echo ""
  echo "## 1. Execution Speed, Peak RSS & Instructions Retired"
  echo ""
  echo "| Benchmark | Lang | Median (ms) | Min–Max (ms) | Peak RSS (MB) | Instructions Retired | Checksum |"
  echo "|---|---:|---:|---:|---:|---:|---|"
  awk -F'\t' '{
    if ($3 == "N/A") {
      printf "| `%s` | %s | N/A (1T) | - | - | - | - |\n", $1, $2
    } else {
      printf "| `%s` | %s | %s | %s–%s | %s | %s | `%s` |\n", $1, $2, $3, $4, $5, $6, $7, $8
    }
  }' "$EXEC_TSV"
  echo ""
  echo "## 2. Compile Speed (10,000 LOC / 20 Packages) & Worktree Cache Pollution"
  echo ""
  echo "| Lang | Cold Compile (ms) | 1-Line Body Edit Incr (ms) | Worktree Cache (bytes / MB) | Global CAS (bytes) | Checksum (cold -> incr) |"
  echo "|---|---:|---:|---:|---:|---|"
  awk -F'\t' '{
    mb = $4 / 1048576.0
    printf "| %s | %s | %s | %s (%.2f MB) | %s | `%s` -> `%s` |\n", $1, $2, $3, $4, mb, $5, $6, $7
  }' "$COMPILE_TSV"
  echo ""
  echo "## 3. Binary Artifact Sizes (Default / Stripped, bytes)"
  echo ""
  echo '| Lang | `hello` (def / strip) | 6-Bench Total (def / strip) | `nbody` | `binarytrees` | `spectralnorm` | `fannkuchredux` | `mandelbrot_mt` | `hashmap_str` |'
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
  for lang in $LANGS; do
    awk -F'\t' -v L="$lang" '
      $1 == L {
        def[$2] = $3; str[$2] = $4
        if ($2 != "hello") { tot_d += $3; tot_s += $4 }
      }
      END {
        printf "| %s | %d / %d | %d / %d | %d | %d | %d | %d | %d | %d |\n",
          L, def["hello"], str["hello"], tot_d, tot_s,
          str["nbody"], str["binarytrees"], str["spectralnorm"],
          str["fannkuchredux"], str["mandelbrot_mt"], str["hashmap_str"]
      }
    ' "$SIZE_TSV"
  done
} > "$MD_OUT"

echo ""
cat "$MD_OUT"
echo ""
echo "JSON results written to: $JSON_OUT"
echo "Markdown summary written to: $MD_OUT"
