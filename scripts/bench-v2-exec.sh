#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BENCH_DIR="$ROOT_DIR/benchmarks/v2"
TOOLS_DIR="$ROOT_DIR/benchmarks/tools"
OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"

WARMUP=1
RUNS=5
MODE_LABEL="full (1 warmup + 5 runs)"
if [ "${1:-}" = "--quick" ]; then
  WARMUP=1
  RUNS=1
  MODE_LABEL="quick (1 warmup + 1 run)"
fi

if [ -z "${PIONC:-}" ] && [ -x "$OUT_DIR/pionc2" ]; then
  PIONC="$OUT_DIR/pionc2"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pion-bench-v2.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/data" "$WORK/exec/c" "$WORK/exec/zig" "$WORK/exec/rust" "$WORK/exec/go" "$WORK/exec/pion"

# Build pure-C benchmark tools (zero Python)
clang -O2 -Wall -Wextra -o "$WORK/bin/bench_measure" "$TOOLS_DIR/bench_measure.c"
clang -O2 -Wall -Wextra -o "$WORK/bin/gen_v2_data" "$BENCH_DIR/tools/gen_v2_data.c"

MEASURE="$WORK/bin/bench_measure"
GEN_DATA="$WORK/bin/gen_v2_data"

file_bytes() {
  stat -f%z "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
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
HAS_RUST=0; command -v rustc >/dev/null 2>&1 && HAS_RUST=1
HAS_GO=0; command -v go >/dev/null 2>&1 && HAS_GO=1
HAS_PION=0
if [ -n "${PIONC:-}" ] && [ -x "${PIONC:-}" ]; then
  HAS_PION=1
fi

CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
OS_VER=$(uname -srm)
CLANG_VER=$( [ "$HAS_C" -eq 1 ] && clang --version 2>&1 | head -n 1 || echo "N/A" )
MOON_VER=$( [ "$HAS_MOON" -eq 1 ] && moon --version 2>&1 | head -n 1 || echo "N/A" )
ZIG_VER=$( [ "$HAS_ZIG" -eq 1 ] && zig version 2>&1 | head -n 1 || echo "N/A" )
RUST_VER=$( [ "$HAS_RUST" -eq 1 ] && rustc --version 2>&1 | head -n 1 || echo "N/A" )
GO_VER=$( [ "$HAS_GO" -eq 1 ] && go version 2>&1 | head -n 1 || echo "N/A" )
PION_VER=$( [ "$HAS_PION" -eq 1 ] && ("$PIONC" --version 2>&1 | head -n 1 || echo "$PIONC") || echo "not provided (pass PIONC=/path/to/pionc2)" )

echo "================================================================="
echo " pion V2 Real-Workload 6-Language Execution Benchmark Suite"
echo "================================================================="
echo "Mode   : $MODE_LABEL"
echo "Host   : $CPU_BRAND ($CPU_CORES cores) | $OS_VER"
echo "C      : $CLANG_VER"
echo "MoonBit: $MOON_VER"
echo "Zig    : $ZIG_VER"
echo "Rust   : $RUST_VER"
echo "Go     : $GO_VER"
echo "pion     : $PION_VER"
echo "================================================================="

# 1. Generate deterministic datasets
echo ">>> Generating deterministic V2 datasets..."
"$GEN_DATA" "$WORK/data"
JSON_BYTES=$(file_bytes "$WORK/data/dataset.json")
LOGS_BYTES=$(file_bytes "$WORK/data/logs.txt")
echo "  dataset.json: $JSON_BYTES bytes"
echo "  logs.txt    : $LOGS_BYTES bytes"

# 2. Build all 3 benchmarks x 6 languages
BENCHES="json_query bytecode_vm mt_log_pipeline"

if [ "$HAS_C" -eq 1 ]; then
  echo ">>> Building C (-O2)..."
  for b in $BENCHES; do
    clang -O2 -o "$WORK/exec/c/$b" "$BENCH_DIR/c/$b.c" -lm -lpthread
  done
fi

if [ "$HAS_MOON" -eq 1 ]; then
  echo ">>> Building MoonBit (moon build --target native --release)..."
  cp -R "$BENCH_DIR/moonbit" "$WORK/exec/moonbit"
  (cd "$WORK/exec/moonbit" && moon build --target native --release >/dev/null)
fi

if [ "$HAS_ZIG" -eq 1 ]; then
  echo ">>> Building Zig (-OReleaseFast)..."
  mkdir -p "$WORK/exec/zig-cache" "$WORK/exec/zig-global-cache"
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

if [ "$HAS_GO" -eq 1 ]; then
  echo ">>> Building Go (go build)..."
  export GOCACHE="$WORK/go-cache"
  mkdir -p "$GOCACHE"
  for b in $BENCHES; do
    go build -o "$WORK/exec/go/$b" "$BENCH_DIR/go/$b.go"
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
    go)      echo "$WORK/exec/go/$bench" ;;
    pion)      echo "$WORK/exec/pion/$bench" ;;
  esac
}

LANGS=""
[ "$HAS_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAS_MOON" -eq 1 ] && LANGS="$LANGS moonbit"
[ "$HAS_ZIG" -eq 1 ] && LANGS="$LANGS zig"
[ "$HAS_RUST" -eq 1 ] && LANGS="$LANGS rust"
[ "$HAS_GO" -eq 1 ] && LANGS="$LANGS go"
[ "$HAS_PION" -eq 1 ] && LANGS="$LANGS pion"

EXEC_TSV="$WORK/exec_results.tsv"
: > "$EXEC_TSV"
CHECKSUM_FILE="$WORK/checksums.tsv"
: > "$CHECKSUM_FILE"

run_case() {
  case_name="$1"
  bench_bin="$2"
  skip_moon="$3"
  shift 3

  expected_ck=""
  echo ">>> Benchmarking $case_name ($WARMUP warmup + $RUNS runs)..."
  for lang in $LANGS; do
    if [ "$lang" = "moonbit" ] && [ "$skip_moon" -eq 1 ]; then
      printf '%s\t%s\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\n' "$case_name" "$lang" >> "$EXEC_TSV"
      continue
    fi
    bp=$(bin_path "$lang" "$bench_bin")
    if [ "$#" -gt 0 ]; then
      line=$("$MEASURE" exec "$WARMUP" "$RUNS" -- "$bp" "$@")
    else
      line=$("$MEASURE" exec "$WARMUP" "$RUNS" -- "$bp")
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

run_case "json_query"          "json_query"      0 "$WORK/data/dataset.json"
run_case "bytecode_vm"         "bytecode_vm"     0
run_case "mt_log_pipeline_1t"  "mt_log_pipeline" 0 "$WORK/data/logs.txt" "1"
run_case "mt_log_pipeline_4t"  "mt_log_pipeline" 1 "$WORK/data/logs.txt" "4"

CK_MT1=$(awk -F'\t' '$1=="mt_log_pipeline_1t"{print $2}' "$CHECKSUM_FILE")
CK_MT4=$(awk -F'\t' '$1=="mt_log_pipeline_4t"{print $2}' "$CHECKSUM_FILE")
if [ "$CK_MT1" != "$CK_MT4" ]; then
  echo "FATAL: mt_log_pipeline_1t ($CK_MT1) != mt_log_pipeline_4t ($CK_MT4)" >&2
  exit 1
fi
echo ">>> All V2 execution checksums verified 100% bit-for-bit identical across all 6 languages (and 1T == 4T)!"

# 3. Binary sizes (default & stripped)
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

# 4. Emit structured JSON (out/v2-exec-results.json)
JSON_OUT="$OUT_DIR/v2-exec-results.json"
{
  printf '{\n'
  printf '  "mode": "%s",\n' "$(json_escape "$MODE_LABEL")"
  printf '  "host": {\n'
  printf '    "cpu": "%s",\n' "$(json_escape "$CPU_BRAND")"
  printf '    "cores": %s,\n' "$CPU_CORES"
  printf '    "os": "%s"\n' "$(json_escape "$OS_VER")"
  printf '  },\n'
  printf '  "datasets": {\n'
  printf '    "dataset_json_bytes": %s,\n' "$JSON_BYTES"
  printf '    "logs_txt_bytes": %s\n' "$LOGS_BYTES"
  printf '  },\n'
  printf '  "toolchains": {\n'
  printf '    "c": "%s",\n' "$(json_escape "$CLANG_VER")"
  printf '    "moonbit": "%s",\n' "$(json_escape "$MOON_VER")"
  printf '    "zig": "%s",\n' "$(json_escape "$ZIG_VER")"
  printf '    "rust": "%s",\n' "$(json_escape "$RUST_VER")"
  printf '    "go": "%s",\n' "$(json_escape "$GO_VER")"
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

# 5. Emit Markdown summary (out/v2-exec-summary.md)
MD_OUT="$OUT_DIR/v2-exec-summary.md"
{
  echo "# pion V2 Real-Workload 6-Language Execution Benchmark Report"
  echo ""
  echo "- **Mode**: $MODE_LABEL"
  echo "- **Machine**: \`$CPU_BRAND\` ($CPU_CORES cores), \`$OS_VER\`"
  echo "- **Datasets**: \`dataset.json\` ($JSON_BYTES bytes), \`logs.txt\` ($LOGS_BYTES bytes)"
  echo "- **Toolchains**:"
  echo "  - C: \`$CLANG_VER\` (\`-O2\`)"
  echo "  - MoonBit: \`$MOON_VER\` (\`moon build --target native --release\`)"
  echo "  - Zig: \`$ZIG_VER\` (\`-OReleaseFast\`)"
  echo "  - Rust: \`$RUST_VER\` (\`rustc -O\`)"
  echo "  - Go: \`$GO_VER\` (\`go build\`)"
  echo "  - pion: \`$PION_VER\` (\`pionc2 build --release\`)"
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
  echo "## 2. Binary Artifact Sizes (Default / Stripped, bytes)"
  echo ""
  echo '| Lang | `json_query` (def / strip) | `bytecode_vm` (def / strip) | `mt_log_pipeline` (def / strip) | Total (def / strip) |'
  echo "|---|---:|---:|---:|---:|"
  for lang in $LANGS; do
    awk -F'\t' -v L="$lang" '
      $1 == L {
        def[$2] = $3; str[$2] = $4
        tot_d += $3; tot_s += $4
      }
      END {
        printf "| %s | %d / %d | %d / %d | %d / %d | %d / %d |\n",
          L,
          def["json_query"], str["json_query"],
          def["bytecode_vm"], str["bytecode_vm"],
          def["mt_log_pipeline"], str["mt_log_pipeline"],
          tot_d, tot_s
      }
    ' "$SIZE_TSV"
  done
} > "$MD_OUT"

echo ""
cat "$MD_OUT"
echo ""
echo "JSON results written to: $JSON_OUT"
echo "Markdown summary written to: $MD_OUT"
