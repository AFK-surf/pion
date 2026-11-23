#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi
RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
CC_BIN="${CC:-cc}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"

echo "=== P71-A E2E: staticlib / extern C init / c_sources -O3 / AR / -shared / --entry-symbol / --no-main ==="

# ----------------------------------------------------------------------------
# 1. T1-single: single-package --emit-staticlib with top-level const + extern "C"
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/t1_single"
cat > "$TMP_DIR/t1_single/lib.pion" <<'EOF'
let table : Array[String] = ["a", "b", "c"]

pub extern "C" fn single_get_len() -> Int {
  table.length()
}
EOF
"$PIONC" build --release --emit-staticlib "$TMP_DIR/t1_single/libsingle.a" "$TMP_DIR/t1_single/lib.pion"
cat > "$TMP_DIR/t1_single/main.c" <<'EOF'
#include <stdio.h>
extern int single_get_len(void);
int main(void) {
  int a = single_get_len();
  int b = single_get_len();
  printf("single=%d,%d\n", a, b);
  return (a == 3 && b == 3) ? 0 : 1;
}
EOF
"$CC_BIN" "$TMP_DIR/t1_single/main.c" "$TMP_DIR/t1_single/libsingle.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/t1_single/run"
OUT_S="$("$TMP_DIR/t1_single/run")"
echo "T1-single -> $OUT_S"
[ "$OUT_S" = "single=3,3" ]

# ----------------------------------------------------------------------------
# 2. T1-multi: two-package workspace (dep const -> app extern "C") + idempotency
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/t1_multi/dep/src" "$TMP_DIR/t1_multi/app/src"
cat > "$TMP_DIR/t1_multi/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/t1_multi/dep/src/lib.pion" <<'EOF'
pub let table : Array[String] = ["a", "b", "c"]
EOF
cat > "$TMP_DIR/t1_multi/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/t1_multi/app/src/lib.pion" <<'EOF'
import "dep"

pub extern "C" fn multi_get_len() -> Int {
  dep::table.length()
}
EOF
"$PIONC" build --release --emit-staticlib "$TMP_DIR/t1_multi/libapp.a" "$TMP_DIR/t1_multi/app"
cat > "$TMP_DIR/t1_multi/main.c" <<'EOF'
#include <stdio.h>
extern int multi_get_len(void);
int main(void) {
  int a = multi_get_len();
  int b = multi_get_len();
  printf("multi=%d,%d\n", a, b);
  return (a == 3 && b == 3) ? 0 : 1;
}
EOF
"$CC_BIN" "$TMP_DIR/t1_multi/main.c" "$TMP_DIR/t1_multi/libapp.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/t1_multi/run"
OUT_M="$("$TMP_DIR/t1_multi/run")"
echo "T1-multi -> $OUT_M"
[ "$OUT_M" = "multi=3,3" ]

# ----------------------------------------------------------------------------
# 3. T2: c_sources -O3 in --release, 0 in debug, and user -O0 override
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/t2_opt/src"
cat > "$TMP_DIR/t2_opt/opt_check.c" <<'EOF'
int c_is_optimized(void) {
#ifdef __OPTIMIZE__
  return 1;
#else
  return 0;
#endif
}
EOF
cat > "$TMP_DIR/t2_opt/src/main.pion" <<'EOF'
extern "C" fn c_is_optimized() -> Int

pub fn main(world : World) -> Int {
  io_println(world, "opt=" + c_is_optimized().to_string())
  0
}
EOF
cat > "$TMP_DIR/t2_opt/pion.toml" <<'EOF'
[package]
name = "t2_opt"
version = "0.1.0"

[link]
c_sources = ["opt_check.c"]
EOF
"$PIONC" build --release -o "$TMP_DIR/t2_opt/bin_rel" "$TMP_DIR/t2_opt"
OUT_REL="$("$TMP_DIR/t2_opt/bin_rel")"
echo "T2 release -> $OUT_REL"
[ "$OUT_REL" = "opt=1" ]

"$PIONC" build -o "$TMP_DIR/t2_opt/bin_dbg" "$TMP_DIR/t2_opt"
OUT_DBG="$("$TMP_DIR/t2_opt/bin_dbg")"
echo "T2 debug   -> $OUT_DBG"
[ "$OUT_DBG" = "opt=0" ]

cat > "$TMP_DIR/t2_opt/pion.toml" <<'EOF'
[package]
name = "t2_opt"
version = "0.1.0"

[link]
c_sources = ["opt_check.c"]
cc_flags = ["-O0"]
EOF
"$PIONC" build --release -o "$TMP_DIR/t2_opt/bin_o0" "$TMP_DIR/t2_opt"
OUT_O0="$("$TMP_DIR/t2_opt/bin_o0")"
echo "T2 -O0     -> $OUT_O0"
[ "$OUT_O0" = "opt=0" ]

# ----------------------------------------------------------------------------
# 4. T3: $AR override, sibling llvm-ar priority, and Android missing-NDK error
# ----------------------------------------------------------------------------
REAL_AR="$(command -v ar)"
cat > "$TMP_DIR/fake_ar.sh" <<EOF
#!/usr/bin/env sh
echo "USED_CUSTOM_AR" > "$TMP_DIR/ar_marker"
exec "$REAL_AR" "\$@"
EOF
chmod +x "$TMP_DIR/fake_ar.sh"
AR="$TMP_DIR/fake_ar.sh" "$PIONC" build --release --emit-staticlib "$TMP_DIR/t3_ar.a" "$TMP_DIR/t1_single/lib.pion"
[ -f "$TMP_DIR/ar_marker" ]
echo "T3 custom AR -> OK"

mkdir -p "$TMP_DIR/fake_tc"
cat > "$TMP_DIR/fake_tc/fake-clang" <<EOF
#!/usr/bin/env sh
exec "$CC_BIN" "\$@"
EOF
cat > "$TMP_DIR/fake_tc/llvm-ar" <<EOF
#!/usr/bin/env sh
echo "USED_SIBLING_LLVM_AR" > "$TMP_DIR/llvm_ar_marker"
exec "$REAL_AR" "\$@"
EOF
chmod +x "$TMP_DIR/fake_tc/fake-clang" "$TMP_DIR/fake_tc/llvm-ar"
env -u AR CC="$TMP_DIR/fake_tc/fake-clang" "$PIONC" build --release --emit-staticlib "$TMP_DIR/t3_llvmar.a" "$TMP_DIR/t1_single/lib.pion"
[ -f "$TMP_DIR/llvm_ar_marker" ]
echo "T3 sibling llvm-ar -> OK"

mkdir -p "$TMP_DIR/empty_home"
env -u ANDROID_NDK_HOME -u ANDROID_NDK_ROOT -u ANDROID_HOME -u ANDROID_SDK_ROOT -u PION_ANDROID_CC -u CC HOME="$TMP_DIR/empty_home" \
  "$PIONC" build --target android_arm64 --emit-asm "$TMP_DIR/android_ok.s" "$TMP_DIR/t1_single/lib.pion"
[ -s "$TMP_DIR/android_ok.s" ]
env -u ANDROID_NDK_HOME -u ANDROID_NDK_ROOT -u ANDROID_HOME -u ANDROID_SDK_ROOT -u PION_ANDROID_CC -u CC HOME="$TMP_DIR/empty_home" \
  "$PIONC" build --target android_arm64 --emit-ssa "$TMP_DIR/android_ok.ssa" "$TMP_DIR/t1_single/lib.pion"
[ -s "$TMP_DIR/android_ok.ssa" ]
echo "T3 Android --emit-asm / --emit-ssa without NDK/CC -> OK"

if env -u ANDROID_NDK_HOME -u ANDROID_NDK_ROOT -u ANDROID_HOME -u ANDROID_SDK_ROOT -u PION_ANDROID_CC -u CC HOME="$TMP_DIR/empty_home" \
  "$PIONC" build --target android_arm64 --emit-staticlib "$TMP_DIR/android_fail.a" "$TMP_DIR/t1_single/lib.pion" \
  > "$TMP_DIR/android.out" 2> "$TMP_DIR/android.err"; then
  echo "FAIL: android_arm64 without NDK should have failed" >&2
  exit 1
fi
grep -q "requires Android NDK" "$TMP_DIR/android.err"
echo "T3 Android missing NDK error -> OK"

# ----------------------------------------------------------------------------
# 5. T4b/4c: ELF -shared -fPIC WITHOUT -Wl,-Bsymbolic + STV_HIDDEN check
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/t4_shared/dep/src" "$TMP_DIR/t4_shared/app/src"
cat > "$TMP_DIR/t4_shared/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/t4_shared/dep/src/lib.pion" <<'EOF'
pub let base_items : Array[String] = ["x", "y", "z"]
EOF
cat > "$TMP_DIR/t4_shared/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/t4_shared/app/src/lib.pion" <<'EOF'
import "dep"

pub extern "C" fn push_and_count() -> Int {
  let out : Array[String] = []
  let mut i = 0
  while i < dep::base_items.length() {
    out.push(dep::base_items[i])
    i = i + 1
  }
  out.push("w")
  out.length()
}
EOF
"$PIONC" build --release --emit-staticlib "$TMP_DIR/t4_shared/libapp.a" "$TMP_DIR/t4_shared/app"
"$CC_BIN" -std=c11 -O2 -fPIC -fno-asynchronous-unwind-tables -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/t4_shared/pion_rt.o"

UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Linux" ]; then
  # Strictly NO -Wl,-Bsymbolic!
  "$CC_BIN" -shared -fPIC -Wl,--no-undefined \
    -Wl,--whole-archive "$TMP_DIR/t4_shared/libapp.a" -Wl,--no-whole-archive \
    "$TMP_DIR/t4_shared/pion_rt.o" -lm -lpthread \
    -o "$TMP_DIR/t4_shared/libp71a.so"

  if command -v readelf >/dev/null 2>&1; then
    OBJ_SYMS="$(readelf -Ws "$TMP_DIR/t4_shared/pion_rt.o" "$TMP_DIR/t4_shared/libapp.a")"
    echo "$OBJ_SYMS" | grep -E "HIDDEN[[:space:]]+[0-9]+[[:space:]]+pion_mt_flag$" >/dev/null
    echo "$OBJ_SYMS" | grep -E "HIDDEN[[:space:]]+[0-9]+[[:space:]]+pion_pkg_dep_const_base_items$" >/dev/null
    echo "$OBJ_SYMS" | grep -E "DEFAULT[[:space:]]+[0-9]+[[:space:]]+push_and_count$" >/dev/null
    DYN_SYMS="$(readelf --dyn-syms -W "$TMP_DIR/t4_shared/libp71a.so")"
    echo "$DYN_SYMS" | grep -E "DEFAULT[[:space:]]+[0-9]+[[:space:]]+push_and_count$" >/dev/null
    if echo "$DYN_SYMS" | grep -E "pion_mt_flag$|pion_pkg_dep_const_base_items$" >/dev/null; then
      echo "FAIL: internal hidden symbols leaked into .dynsym" >&2
      exit 1
    fi
    echo "T4b/4c readelf visibility (HIDDEN pion_mt_flag & pion_pkg_*, DEFAULT push_and_count) -> OK"
  fi

  cat > "$TMP_DIR/t4_shared/dl_host.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
  int (*fn)(void) = (int (*)(void))dlsym(h, "push_and_count");
  if (!fn) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 3; }
  int r1 = fn();
  int r2 = fn();
  printf("shared=%d,%d\n", r1, r2);
  dlclose(h);
  return (r1 == 4 && r2 == 4) ? 0 : 1;
}
EOF
  "$CC_BIN" "$TMP_DIR/t4_shared/dl_host.c" -ldl -o "$TMP_DIR/t4_shared/dl_host"
  OUT_SH="$("$TMP_DIR/t4_shared/dl_host" "$TMP_DIR/t4_shared/libp71a.so")"
  echo "T4b/4c -shared (no -Bsymbolic) dlopen -> $OUT_SH"
  [ "$OUT_SH" = "shared=4,4" ]
fi

# ----------------------------------------------------------------------------
# 6. #5: --entry-symbol <name> & --no-main (plus mutual exclusion & validation)
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/t5_entry"
cat > "$TMP_DIR/t5_entry/app.pion" <<'EOF'
let items : Array[String] = ["one", "two"]

pub extern "C" fn extra_api() -> Int {
  items.length() + 10
}

pub fn main(world : World) -> Int {
  let args = args_get(world)
  items.length() * 10 + args.length()
}
EOF

# Mutual exclusion
if "$PIONC" build --entry-symbol invar_entry --no-main --emit-staticlib "$TMP_DIR/t5_entry/bad.a" "$TMP_DIR/t5_entry/app.pion" 2>"$TMP_DIR/t5_entry/err1"; then
  echo "FAIL: --entry-symbol + --no-main should fail" >&2
  exit 1
fi
grep -q "mutually exclusive" "$TMP_DIR/t5_entry/err1"

# Invalid identifier
if "$PIONC" build --entry-symbol 123bad --emit-staticlib "$TMP_DIR/t5_entry/bad2.a" "$TMP_DIR/t5_entry/app.pion" 2>"$TMP_DIR/t5_entry/err2"; then
  echo "FAIL: invalid --entry-symbol should fail" >&2
  exit 1
fi
grep -q "invalid --entry-symbol" "$TMP_DIR/t5_entry/err2"

# --entry-symbol invar_entry
"$PIONC" build --release --entry-symbol invar_entry --emit-staticlib "$TMP_DIR/t5_entry/libentry.a" "$TMP_DIR/t5_entry/app.pion"
cat > "$TMP_DIR/t5_entry/host_entry.c" <<'EOF'
#include <stdio.h>
extern int invar_entry(int argc, char **argv);
int main(int argc, char **argv) {
  int r = invar_entry(argc, argv);
  printf("entry=%d\n", r);
  return (r == 20 + argc) ? 0 : 1;
}
EOF
"$CC_BIN" "$TMP_DIR/t5_entry/host_entry.c" "$TMP_DIR/t5_entry/libentry.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/t5_entry/run_entry"
OUT_E="$("$TMP_DIR/t5_entry/run_entry" foo bar)"
echo "#5 --entry-symbol -> $OUT_E"
[ "$OUT_E" = "entry=23" ]

# --no-main (links cleanly with C host main() without duplicate main symbol)
"$PIONC" build --release --no-main --emit-staticlib "$TMP_DIR/t5_entry/libnomain.a" "$TMP_DIR/t5_entry/app.pion"
cat > "$TMP_DIR/t5_entry/host_nomain.c" <<'EOF'
#include <stdio.h>
extern int extra_api(void);
int main(void) {
  int r = extra_api();
  printf("nomain=%d\n", r);
  return (r == 12) ? 0 : 1;
}
EOF
"$CC_BIN" "$TMP_DIR/t5_entry/host_nomain.c" "$TMP_DIR/t5_entry/libnomain.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/t5_entry/run_nomain"
OUT_N="$("$TMP_DIR/t5_entry/run_nomain")"
echo "#5 --no-main -> $OUT_N"
[ "$OUT_N" = "nomain=12" ]

echo "PASS: p71a_staticlib_android"
