#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BENCH_DIR="$ROOT_DIR/benchmarks"
OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"

export PION_QBE="${PION_QBE:-$OUT_DIR/qbe}"
export PION_RT_LIB="${PION_RT_LIB:-$OUT_DIR/libpionrt.a}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pion-v2-compile.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/base" "$WORK/wt5"

# Build pure-C benchmark tools (zero Python)
clang -O2 -Wall -Wextra -o "$WORK/bin/bench_measure" "$BENCH_DIR/tools/bench_measure.c"
clang -O2 -Wall -Wextra -o "$WORK/bin/gen_scale50k" "$BENCH_DIR/v2/tools/gen_scale50k.c"

MEASURE="$WORK/bin/bench_measure"
GEN="$WORK/bin/gen_scale50k"

dir_bytes() {
  if [ ! -d "$1" ]; then
    echo 0
    return
  fi
  find "$1" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {printf "%d\n", s+0}'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sum_floats() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f\n", a + b }'
}

# Detect toolchains
HAS_C=0; command -v clang >/dev/null 2>&1 && HAS_C=1
HAS_MOON=0; command -v moon >/dev/null 2>&1 && HAS_MOON=1
HAS_ZIG=0; command -v zig >/dev/null 2>&1 && HAS_ZIG=1
HAS_RUST=0; command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 && HAS_RUST=1
HAS_GO=0; command -v go >/dev/null 2>&1 && HAS_GO=1
HAS_PION=0
if [ -n "${PIONC:-}" ] && [ -x "${PIONC:-}" ]; then
  HAS_PION=1
elif [ -x "$OUT_DIR/pionc2" ]; then
  PIONC="$OUT_DIR/pionc2"
  HAS_PION=1
fi

CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
OS_VER=$(uname -srm)
CLANG_VER=$( [ "$HAS_C" -eq 1 ] && clang --version 2>&1 | head -n 1 || echo "N/A" )
MOON_VER=$( [ "$HAS_MOON" -eq 1 ] && moon --version 2>&1 | head -n 1 || echo "N/A" )
ZIG_VER=$( [ "$HAS_ZIG" -eq 1 ] && zig version 2>&1 | head -n 1 || echo "N/A" )
RUST_VER=$( [ "$HAS_RUST" -eq 1 ] && rustc --version 2>&1 | head -n 1 || echo "N/A" )
CARGO_VER=$( [ "$HAS_RUST" -eq 1 ] && cargo --version 2>&1 | head -n 1 || echo "N/A" )
GO_VER=$( [ "$HAS_GO" -eq 1 ] && go version 2>&1 | head -n 1 || echo "N/A" )
PION_VER=$( [ "$HAS_PION" -eq 1 ] && ("$PIONC" --version 2>&1 | head -n 1 || echo "$PIONC") || echo "not provided" )

LANGS=""
[ "$HAS_C" -eq 1 ] && LANGS="$LANGS c"
[ "$HAS_MOON" -eq 1 ] && LANGS="$LANGS moonbit"
[ "$HAS_ZIG" -eq 1 ] && LANGS="$LANGS zig"
[ "$HAS_RUST" -eq 1 ] && LANGS="$LANGS rust"
[ "$HAS_GO" -eq 1 ] && LANGS="$LANGS go"
[ "$HAS_PION" -eq 1 ] && LANGS="$LANGS pion"

echo "========================================================================="
echo " pion V2 Real-Engineering 6-Language Compile Benchmark (50k LOC / 50 Pkgs)"
echo "========================================================================="
echo "Host   : $CPU_BRAND ($CPU_CORES cores) | $OS_VER"
echo "C      : $CLANG_VER"
echo "MoonBit: $MOON_VER"
echo "Zig    : $ZIG_VER"
echo "Rust   : $RUST_VER / $CARGO_VER"
echo "Go     : $GO_VER"
echo "pion     : $PION_VER"
echo "========================================================================="

# ---------------------------------------------------------------------------
# 1. Generate 50,000-LOC / 50-package 4-layer diamond projects & count LOC
# ---------------------------------------------------------------------------
echo ">>> Generating 50,000-LOC / 50-package 4-layer diamond projects..."
"$GEN" "$WORK/base"

LOC_C=$(find "$WORK/base/c" \( -name '*.c' -o -name '*.h' \) -exec cat {} + | wc -l | tr -d ' ')
LOC_MOON=$(find "$WORK/base/moonbit/src" -name '*.mbt' -exec cat {} + | wc -l | tr -d ' ')
LOC_ZIG=$(find "$WORK/base/zig" -name '*.zig' -exec cat {} + | wc -l | tr -d ' ')
LOC_RUST=$(find "$WORK/base/rust" -name '*.rs' -exec cat {} + | wc -l | tr -d ' ')
LOC_GO=$(find "$WORK/base/go" -name '*.go' -exec cat {} + | wc -l | tr -d ' ')
LOC_PION=$(find "$WORK/base/pion" -name '*.pion' -exec cat {} + | wc -l | tr -d ' ')

echo ">>> Source LOC verification (50 lib pkgs + app):"
printf '  %-8s : %s LOC\n' "c" "$LOC_C"
printf '  %-8s : %s LOC\n' "moonbit" "$LOC_MOON"
printf '  %-8s : %s LOC\n' "zig" "$LOC_ZIG"
printf '  %-8s : %s LOC\n' "rust" "$LOC_RUST"
printf '  %-8s : %s LOC\n' "go" "$LOC_GO"
printf '  %-8s : %s LOC\n' "pion" "$LOC_PION"

# Helper: build one project root for a given language, printing elapsed ms to stdout
build_lang() {
  lang="$1"
  proj="$2"
  gocache="$3"
  pioncas="$4"
  zig_gcache="$5"
  case "$lang" in
    c)
      "$MEASURE" once -- sh -c "cd '$proj/c' && make -j12 >/dev/null"
      ;;
    moonbit)
      "$MEASURE" once -- sh -c "cd '$proj/moonbit' && moon build --target native --release >/dev/null"
      ;;
    zig)
      "$MEASURE" once -- sh -c "cd '$proj/zig' && zig build-exe -OReleaseFast -lc --cache-dir '$proj/zig/.zig-cache' --global-cache-dir '$zig_gcache' -femit-bin='$proj/zig/app' main.zig"
      ;;
    rust)
      "$MEASURE" once -- sh -c "cd '$proj/rust' && cargo build --release --quiet"
      ;;
    go)
      "$MEASURE" once -- sh -c "cd '$proj/go' && GOCACHE='$gocache' go build -o '$proj/go/app' ./cmd/app"
      ;;
    pion)
      "$MEASURE" once -- sh -c "cd '$proj/pion' && PION_CACHE_DIR='$pioncas' '$PIONC' build --release app -o '$proj/pion_app'"
      ;;
  esac
}

run_lang_ck() {
  lang="$1"
  proj="$2"
  case "$lang" in
    c)       "$proj/c/app" ;;
    moonbit) "$proj/moonbit/_build/native/release/build/app/app.exe" ;;
    zig)     "$proj/zig/app" ;;
    rust)    "$proj/rust/target/release/app" ;;
    go)      "$proj/go/app" ;;
    pion)      "$proj/pion_app" ;;
  esac
}

mkdir -p "$WORK/base-go-cache" "$WORK/base-pion-cas" "$WORK/base-zig-gcache"

PHASE_TSV="$WORK/phases.tsv"
: > "$PHASE_TSV"

run_phase() {
  phase="$1"
  expected_ck=""
  echo ">>> Phase [$phase]..."
  for lang in $LANGS; do
    ms=$(build_lang "$lang" "$WORK/base" "$WORK/base-go-cache" "$WORK/base-pion-cas" "$WORK/base-zig-gcache")
    ck=$(run_lang_ck "$lang" "$WORK/base")
    if [ -z "$expected_ck" ]; then
      expected_ck="$ck"
    elif [ "$ck" != "$expected_ck" ]; then
      echo "FATAL: checksum mismatch in phase '$phase'! $lang=$ck expected=$expected_ck" >&2
      exit 1
    fi
    printf '  %-8s | %9s ms | checksum=%s\n' "$lang" "$ms" "$ck"
    printf '%s\t%s\t%s\t%s\n' "$phase" "$lang" "$ms" "$ck" >> "$PHASE_TSV"
  done
}

# Scenario 1: Cold compile
run_phase "cold"

# Scenario 2: Mutate leaf09 body (1 line, signature unchanged)
sleep 1
echo ">>> Applying --mutate-leaf-body (leaf09 only)..."
"$GEN" "$WORK/base" --mutate-leaf-body
run_phase "incr_leaf_body"

# Scenario 3: Mutate core00 body (1 line, signature unchanged)
sleep 1
echo ">>> Applying --mutate-core-body (core00 only)..."
"$GEN" "$WORK/base" --mutate-core-body
run_phase "incr_core_body"

# Scenario 4: Mutate core00 public signature + direct callers
sleep 1
echo ">>> Applying --mutate-core-sig (core00 + 10 direct callers)..."
"$GEN" "$WORK/base" --mutate-core-sig
run_phase "incr_core_sig"

CK_COLD=$(awk -F'\t' '$1=="cold"{print $4; exit}' "$PHASE_TSV")
CK_LEAF=$(awk -F'\t' '$1=="incr_leaf_body"{print $4; exit}' "$PHASE_TSV")
CK_CORE=$(awk -F'\t' '$1=="incr_core_body"{print $4; exit}' "$PHASE_TSV")
CK_SIG=$(awk -F'\t' '$1=="incr_core_sig"{print $4; exit}' "$PHASE_TSV")

if [ "$CK_COLD" = "$CK_LEAF" ] || [ "$CK_LEAF" = "$CK_CORE" ] || [ "$CK_CORE" = "$CK_SIG" ]; then
  echo "FATAL: mutation did not change checksum! cold=$CK_COLD leaf=$CK_LEAF core=$CK_CORE sig=$CK_SIG" >&2
  exit 1
fi
echo ">>> Checksums verified (all 6 langs bit-for-bit identical, all mutations distinct):"
echo "    cold=$CK_COLD -> leaf_body=$CK_LEAF -> core_body=$CK_CORE -> core_sig=$CK_SIG"

# ---------------------------------------------------------------------------
# 2. Scenario 5: 5-Worktree Multi-Branch Build (wt0..wt4)
# ---------------------------------------------------------------------------
echo ">>> Generating 5 independent worktrees (wt0..wt4)..."
for k in 0 1 2 3 4; do
  "$GEN" "$WORK/wt5" --branch "$k"
done

mkdir -p "$WORK/wt5-go-cache" "$WORK/wt5-pion-cas" "$WORK/wt5-zig-gcache"

WT5_TSV="$WORK/wt5.tsv"
: > "$WT5_TSV"
WT5_CK_FILE="$WORK/wt5_cks.tsv"
: > "$WT5_CK_FILE"

echo ">>> Phase [wt5] (building 5 independent worktrees wt0..wt4)..."
for lang in $LANGS; do
  tot_ms="0.00"
  wt_ck_summary=""
  for k in 0 1 2 3 4; do
    proj="$WORK/wt5/wt$k"
    ms=$(build_lang "$lang" "$proj" "$WORK/wt5-go-cache" "$WORK/wt5-pion-cas" "$WORK/wt5-zig-gcache")
    ck=$(run_lang_ck "$lang" "$proj")
    tot_ms=$(sum_floats "$tot_ms" "$ms")
    printf '%s\t%s\t%s\n' "$k" "$lang" "$ck" >> "$WT5_CK_FILE"
    if [ -z "$wt_ck_summary" ]; then
      wt_ck_summary="$ck"
    else
      wt_ck_summary="${wt_ck_summary},$ck"
    fi
  done

  wt_bytes=0
  glob_bytes=0
  case "$lang" in
    c)
      for k in 0 1 2 3 4; do
        b=$(find "$WORK/wt5/wt$k/c" -name '*.o' -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {printf "%d\n", s+0}')
        wt_bytes=$((wt_bytes + b))
      done
      glob_bytes=0
      ;;
    moonbit)
      for k in 0 1 2 3 4; do
        b=$(dir_bytes "$WORK/wt5/wt$k/moonbit/_build")
        wt_bytes=$((wt_bytes + b))
      done
      glob_bytes=0
      ;;
    zig)
      for k in 0 1 2 3 4; do
        b=$(dir_bytes "$WORK/wt5/wt$k/zig/.zig-cache")
        wt_bytes=$((wt_bytes + b))
      done
      glob_bytes=$(dir_bytes "$WORK/wt5-zig-gcache")
      ;;
    rust)
      for k in 0 1 2 3 4; do
        b=$(dir_bytes "$WORK/wt5/wt$k/rust/target")
        wt_bytes=$((wt_bytes + b))
      done
      glob_bytes=0
      ;;
    go)
      wt_bytes=0
      glob_bytes=$(dir_bytes "$WORK/wt5-go-cache")
      ;;
    pion)
      wt_bytes=0
      glob_bytes=$(dir_bytes "$WORK/wt5-pion-cas")
      ;;
  esac

  printf '  %-8s | 5-wt total %9s ms | in-tree cache %11d B | global cache %11d B\n' \
    "$lang" "$tot_ms" "$wt_bytes" "$glob_bytes"
  printf '%s\t%s\t%s\t%s\t%s\n' "$lang" "$tot_ms" "$wt_bytes" "$glob_bytes" "$wt_ck_summary" >> "$WT5_TSV"
done

# Verify all 6 languages matched bit-for-bit on every wt0..wt4 and differed from cold
for k in 0 1 2 3 4; do
  uniq_cks=$(awk -F'\t' -v K="$k" '$1==K{print $3}' "$WT5_CK_FILE" | sort -u)
  n_uniq=$(printf '%s\n' "$uniq_cks" | wc -l | tr -d ' ')
  if [ "$n_uniq" -ne 1 ]; then
    echo "FATAL: wt$k checksum mismatch across languages: $uniq_cks" >&2
    exit 1
  fi
  if [ "$uniq_cks" = "$CK_COLD" ]; then
    echo "FATAL: wt$k checksum equals baseline cold checksum ($CK_COLD)" >&2
    exit 1
  fi
done
echo ">>> All 5 worktree checksums (wt0..wt4) verified bit-for-bit identical across all 6 languages!"

# ---------------------------------------------------------------------------
# 3. Combine per-language metrics into summary TSV
# ---------------------------------------------------------------------------
FINAL_TSV="$WORK/final.tsv"
: > "$FINAL_TSV"

get_phase_ms() {
  awk -F'\t' -v P="$1" -v L="$2" '$1==P && $2==L {print $3; exit}' "$PHASE_TSV"
}

get_loc() {
  case "$1" in
    c)       echo "$LOC_C" ;;
    moonbit) echo "$LOC_MOON" ;;
    zig)     echo "$LOC_ZIG" ;;
    rust)    echo "$LOC_RUST" ;;
    go)      echo "$LOC_GO" ;;
    pion)      echo "$LOC_PION" ;;
  esac
}

for lang in $LANGS; do
  loc=$(get_loc "$lang")
  c_ms=$(get_phase_ms "cold" "$lang")
  lb_ms=$(get_phase_ms "incr_leaf_body" "$lang")
  cb_ms=$(get_phase_ms "incr_core_body" "$lang")
  cs_ms=$(get_phase_ms "incr_core_sig" "$lang")
  wt_line=$(awk -F'\t' -v L="$lang" '$1==L {print $2"\t"$3"\t"$4; exit}' "$WT5_TSV")
  wt_ms=$(printf '%s' "$wt_line" | cut -f1)
  wt_b=$(printf '%s' "$wt_line" | cut -f2)
  gl_b=$(printf '%s' "$wt_line" | cut -f3)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$lang" "$loc" "$c_ms" "$lb_ms" "$cb_ms" "$cs_ms" "$wt_ms" "$wt_b" "$gl_b" >> "$FINAL_TSV"
done

# ---------------------------------------------------------------------------
# 4. Emit JSON (out/v2-compile-results.json)
# ---------------------------------------------------------------------------
JSON_OUT="$OUT_DIR/v2-compile-results.json"
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
  printf '    "go": "%s",\n' "$(json_escape "$GO_VER")"
  printf '    "pion": "%s"\n' "$(json_escape "$PION_VER")"
  printf '  },\n'
  printf '  "checksums": {\n'
  printf '    "cold": "%s",\n' "$CK_COLD"
  printf '    "incr_leaf_body": "%s",\n' "$CK_LEAF"
  printf '    "incr_core_body": "%s",\n' "$CK_CORE"
  printf '    "incr_core_sig": "%s"\n' "$CK_SIG"
  printf '  },\n'
  printf '  "results": [\n'
  awk -F'\t' '
    NR > 1 { printf ",\n" }
    {
      printf "    {\"lang\":\"%s\",\"loc\":%s,\"cold_ms\":%s,\"incr_leaf_body_ms\":%s,\"incr_core_body_ms\":%s,\"incr_core_sig_ms\":%s,\"wt5_total_ms\":%s,\"wt5_worktree_cache_bytes\":%s,\"wt5_global_cache_bytes\":%s}",
        $1, $2, $3, $4, $5, $6, $7, $8, $9
    }
    END { printf "\n" }
  ' "$FINAL_TSV"
  printf '  ]\n'
  printf '}\n'
} > "$JSON_OUT"

# ---------------------------------------------------------------------------
# 5. Emit Markdown Summary (out/v2-compile-summary.md + stdout)
# ---------------------------------------------------------------------------
MD_OUT="$OUT_DIR/v2-compile-summary.md"
{
  echo "# pion V2 Real-Engineering 6-Language Compile Benchmark (50k LOC / 50 Packages)"
  echo ""
  echo "- **Host**: \`$CPU_BRAND\` ($CPU_CORES cores), \`$OS_VER\`"
  echo "- **Project Graph**: 50 library packages + 1 \`app\` entry package, 4-layer diamond DAG (\`core00..04\` -> \`mid00..14\` -> \`svc00..19\` -> \`leaf00..09\` -> \`app\`), structs + tagged ADTs + generics instantiated per package."
  echo "- **Toolchains**:"
  echo "  - C: \`$CLANG_VER\` (\`make -j12\`, \`-O2\`, exact header deps)"
  echo "  - MoonBit: \`$MOON_VER\` (\`moon build --target native --release\`)"
  echo "  - Zig: \`$ZIG_VER\` (\`zig build-exe -OReleaseFast -lc\`)"
  echo "  - Rust: \`$RUST_VER\` / \`$CARGO_VER\` (\`cargo build --release\`)"
  echo "  - Go: \`$GO_VER\` (\`go build\`, isolated \`GOCACHE\`)"
  echo "  - pion: \`$PION_VER\` (\`pionc2 build --release app\`, isolated \`PION_CACHE_DIR\`)"
  echo "- **Checksums (bit-for-bit identical across all 6 languages)**:"
  echo "  - \`cold\`: \`$CK_COLD\` | \`incr_leaf_body\`: \`$CK_LEAF\` | \`incr_core_body\`: \`$CK_CORE\` | \`incr_core_sig\`: \`$CK_SIG\`"
  echo ""
  echo "| Lang | LOC | Cold (ms) | Leaf Body Incr (ms) | Core Body Incr (ms) | Core Sig Incr (ms) | 5-WT Total (ms) | 5-WT In-Tree Cache (MB) | 5-WT Global Cache (MB) |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
  awk -F'\t' '{
    wt_mb = $8 / 1048576.0
    gl_mb = $9 / 1048576.0
    printf "| %s | %s | %s | %s | %s | %s | %s | %.2f (%s B) | %.2f (%s B) |\n",
      $1, $2, $3, $4, $5, $6, $7, wt_mb, $8, gl_mb, $9
  }' "$FINAL_TSV"
} > "$MD_OUT"

echo ""
cat "$MD_OUT"
echo ""
echo "JSON results written to: $JSON_OUT"
echo "Markdown summary written to: $MD_OUT"
