#!/bin/sh
# P93 end-to-end regression suite (pionc CLI):
#   1) A symlinked `pionc` (relative / absolute / multi-hop links, called by
#      path, via PATH and by a relative path) resolves its real directory and
#      finds the sibling qbe / libpionrt.a / share/pion with zero PION_* env.
#   2) Linking is atomic: the linker writes a unique `<bin>.tmp.<pid>.<seq>`
#      sibling that is renamed into place only after it succeeds, so
#      - a link in progress never exposes a partial `-o` / CAS binary,
#      - a second cold `pionc run` racing a stalled link of the same CAS
#        binary builds and runs its own copy, and both succeed,
#      - a failed link leaves neither the binary nor temp files behind,
#      - a failed `-o` link never passes off an older `-o` file as its output.
#      - identical cold links (CAS or `-o`) from separate processes are
#        byte-identical (macOS: the ad-hoc signature identifier is the final
#        basename), and a ~240-byte output basename still links,
#      - a directory or 0-byte file at a CAS binary path is never a hit,
#      - concurrent CAS index updates lose no key, and `cache prune` fails
#        loudly when it cannot write the index; an unlockable / unreadable
#        index is never rewritten (prune / clean fail, cached files intact),
#      - a linker or wasm-opt that exits 0 without real output never
#        replaces an old `-o` file or adds a CAS entry,
#      - on POSIX a backslash is part of the output file name, and the
#        staging directory (nested side files, symlinks) is removed without
#        following links.
#   3) Wasm32 `-o` output is published the same way; single-package Wasm CAS
#      keys separate wasm-opt on/off, and a failing wasm-opt leaves no
#      temp/raw file and the old output untouched.
# A fake `CC` wrapper stalls (FIFO barrier) or fails the link step; the test
# synchronizes only through FIFOs and `wait` (never `sleep`).
# Usage: sh tests/e2e/p93_cli_link_symlink/run_e2e.sh <pionc>
set -eu

PIONC=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT_DIR="$ROOT_DIR/out"
REAL_CC="${CC:-cc}"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAKE_PID=""
fail() {
  # Never leave a stalled fake linker (and the pionc waiting on it) behind.
  if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null || true; wait 2>/dev/null || true; fi
  echo "FAIL (p93_cli_link_symlink): $*" >&2
  exit 1
}
expect() {
  printf '%s' "$1" | grep -q -- "$2" || fail "$3: expected '$2' in '$1'"
}
no_tmp() {
  left=$(find "$1" \( -name '*.tmp.*' -o -name '.pion_ld.*' -o -name '*.raw.*' \) 2>/dev/null || true)
  [ -z "$left" ] || fail "$2: temp files left behind: $left"
}

mkdir -p "$W/app" "$W/out"
cat > "$W/app/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "p93 ok")
  0
}
EOF
PROG="$W/app/main.pion"

# --- 1) Symlinked pionc ------------------------------------------------------
PREFIX="$W/prefix"
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share/pion/runtime"
cp "$PIONC" "$PREFIX/bin/pionc"
cp "$OUT_DIR/qbe" "$PREFIX/bin/qbe"
chmod +x "$PREFIX/bin/pionc" "$PREFIX/bin/qbe"
cp "$OUT_DIR/libpionrt.a" "$PREFIX/lib/libpionrt.a"
cp "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$PREFIX/share/pion/pion_wasm_rt.mjs"
cp "$ROOT_DIR/runtime/pion_rt.c" "$ROOT_DIR/runtime/pion_rt.h" "$PREFIX/share/pion/runtime/"
PREFIX_REAL=$(cd -P "$PREFIX" && pwd)
mkdir -p "$W/l1" "$W/l2" "$W/l3"
ln -s ../prefix/bin/pionc "$W/l1/pionc"   # relative, 1 hop
ln -s "$W/l1/pionc" "$W/l2/pionc"         # absolute, 2 hops
ln -s ../l2/pionc "$W/l3/pc"              # relative, 3 hops, renamed
(
  unset PION_QBE PION_RT_LIB PION_WASM_RT PION_SRC PION_TARGET PION_REGISTRY || true
  export PION_CACHE_DIR="$W/cas_sym"
  VER=$("$W/l2/pionc" --version --json)
  expect "$VER" '"version":' "--version via absolute 2-hop symlink"
  DOC=$(PATH="$W/l3:$PATH" pc doctor --json)
  echo "p93 doctor --json via PATH 3-hop symlink -> $DOC"
  expect "$DOC" '"ok":true' "doctor via PATH symlink"
  expect "$DOC" "$PREFIX_REAL/bin/qbe" "doctor resolves qbe through symlinks"
  expect "$DOC" "$PREFIX_REAL/lib/libpionrt.a" "doctor resolves rt_lib through symlinks"
  expect "$DOC" "$PREFIX_REAL/share/pion/pion_wasm_rt.mjs" "doctor resolves wasm_rt through symlinks"
  cd "$W"
  ./l3/pc build -o "$W/out/sym_app" "$PROG"
  [ "$("$W/out/sym_app")" = "p93 ok" ] || fail "binary built by relative-path symlinked pionc"
  # An explicit override still wins over the resolved directory.
  DOC2=$(PION_QBE=/nonexistent/qbe ./l1/pionc doctor --json || true)
  expect "$DOC2" '/nonexistent/qbe' "PION_QBE overrides the symlink-resolved qbe"
)
echo "p93 symlinked pionc (relative/absolute/3-hop, by path, PATH, relative path): OK"

# --- 2) Atomic link ------------------------------------------------------------
cat > "$W/fakecc" <<'EOF'
#!/bin/sh
# Link steps (an `-o`, no -c/-S/-E) of FAKE_LD_MODE=block first write junk to
# the output, report on FAKE_LD_READY and wait on FAKE_LD_GO; FAKE_LD_MODE=fail
# writes junk and fails. Everything else runs the real compiler.
out=""; link=1; prev=""
for a in "$@"; do
  case "$a" in -c|-S|-E) link=0 ;; esac
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
if [ "$link" = 1 ] && [ -n "$out" ]; then
  case "${FAKE_LD_MODE:-}" in
    empty)
      : > "$out"
      exit 0
      ;;
    rostage)
      # A read-only subdirectory with a file: the staging cleanup after the
      # publish cannot remove it (as a non-root user).
      "$FAKE_REAL_CC" "$@" || exit $?
      mkdir -p "$(dirname "$out")/ro"
      echo x > "$(dirname "$out")/ro/f"
      chmod 0500 "$(dirname "$out")/ro"
      exit 0
      ;;
    nest)
      "$FAKE_REAL_CC" "$@" || exit $?
      mkdir -p "$out.dSYM/Contents"
      echo plist > "$out.dSYM/Contents/Info.plist"
      ln -s "$FAKE_SENTINEL" "$(dirname "$out")/sentinel_link"
      ln -s "$(dirname "$FAKE_SENTINEL")" "$out.dSYM/outside_dir"
      exit 0
      ;;
    block)
      printf 'partial' > "$out"
      echo "ready $$ $out" > "$FAKE_LD_READY"
      read _go < "$FAKE_LD_GO"
      ;;
    fail)
      printf 'partial' > "$out"
      exit 1
      ;;
  esac
fi
exec "$FAKE_REAL_CC" "$@"
EOF
chmod +x "$W/fakecc"
export FAKE_REAL_CC="$REAL_CC"
mkfifo "$W/ready" "$W/go"
# Held open read-write, so writers to `ready` never block on a reader.
exec 3<>"$W/ready"

# Starts `pionc "$@"` with a stalled link in the background; returns once the
# link has started (line "ready <fake-ld pid> <tmp>" in $STALL_LINE) or pionc
# has exited.
start_stalled() {
  (
    set +e
    FAKE_LD_MODE=block FAKE_LD_READY="$W/ready" FAKE_LD_GO="$W/go" CC="$W/fakecc" \
      "$PIONC" "$@" > "$W/stalled.out" 2>&1
    echo "exit $?" > "$W/ready"
  ) &
  STALL_PID=$!
  read -r STALL_LINE <&3
  case "$STALL_LINE" in
    ready*) ;;
    *) cat "$W/stalled.out" >&2; fail "stalled pionc $* ended before linking ($STALL_LINE)" ;;
  esac
  set -- $STALL_LINE
  FAKE_PID=$2
  STALL_TMP=$3
}
finish_stalled() {
  echo go > "$W/go"
  FAKE_PID=""
  read -r STALL_END <&3
  wait "$STALL_PID"
  [ "$STALL_END" = "exit 0" ] || { cat "$W/stalled.out" >&2; fail "stalled pionc failed ($STALL_END)"; }
}

# 2a) An explicit -o is invisible until the link succeeded.
export PION_CACHE_DIR="$W/cas_a"
start_stalled build -o "$W/out/app" "$PROG"
[ ! -e "$W/out/app" ] || fail "-o binary visible while its link is still running"
TMP_OUT=$STALL_TMP
case "$TMP_OUT" in
  "$W/out/.pion_ld."*/app) ;;
  *) fail "linker output '$TMP_OUT' is not $W/out/.pion_ld.<pid>.<seq>/app" ;;
esac
finish_stalled
[ "$("$W/out/app")" = "p93 ok" ] || fail "-o binary after the stalled link"
no_tmp "$W/out" "-o link"
echo "p93 atomic -o link (no partial binary while linking): OK"

# 2b) Two cold `pionc run` of one CAS binary: the second one finishes while the
# first is stalled mid-link, and neither sees a partial binary.
export PION_CACHE_DIR="$W/cas_b"
start_stalled run "$PROG"
B_OUT=$("$PIONC" run "$PROG") || fail "second cold pionc run while the first links"
[ "$B_OUT" = "p93 ok" ] || fail "second cold pionc run output '$B_OUT'"
finish_stalled
grep -qx "p93 ok" "$W/stalled.out" || fail "stalled pionc run output '$(cat "$W/stalled.out")'"
C_OUT=$("$PIONC" run "$PROG")
[ "$C_OUT" = "p93 ok" ] || fail "warm pionc run output '$C_OUT'"
no_tmp "$W/cas_b" "concurrent CAS link"
echo "p93 concurrent cold pionc run (stalled link + racing run): OK"

# 2c) A failed CAS link leaves no binary and no temp file.
export PION_CACHE_DIR="$W/cas_c"
if FAKE_LD_MODE=fail CC="$W/fakecc" "$PIONC" build "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build succeeded with a failing linker"
fi
no_tmp "$W/cas_c" "failed CAS link"
if [ -d "$W/cas_c/bin" ] && [ -n "$(ls -A "$W/cas_c/bin")" ]; then
  fail "failed CAS link left $(ls -A "$W/cas_c/bin")"
fi
# ...and the next good build links and runs normally.
[ "$("$PIONC" run "$PROG")" = "p93 ok" ] || fail "run after a failed CAS link"

# 2d) A failed -o link never reuses (or touches) an older -o file.
"$PIONC" build -o "$W/out/keep" "$PROG"
KEEP_SUM=$(cksum < "$W/out/keep")
if FAKE_LD_MODE=fail CC="$W/fakecc" "$PIONC" build -o "$W/out/keep" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build -o succeeded with a failing linker although an old -o file exists"
fi
[ "$(cksum < "$W/out/keep")" = "$KEEP_SUM" ] || fail "failed -o link modified the old -o file"
no_tmp "$W/out" "failed -o link"
# 2e) ...nor does a -o whose final rename fails (a non-empty directory).
mkdir -p "$W/out/isdir/sub"
if "$PIONC" build -o "$W/out/isdir" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build -o <non-empty dir> succeeded"
fi
[ -d "$W/out/isdir/sub" ] || fail "-o <dir> clobbered the directory"
no_tmp "$W/out" "failed -o rename"
echo "p93 failed links (CAS, -o over an old file, -o over a directory): OK"

# 2f) Identical cold links from separate processes are byte-identical (the
# linker sees the final basename, never a pid-tagged temp name).
mkdir -p "$W/o1" "$W/o2"
PION_CACHE_DIR="$W/cas_f1" "$PIONC" build -o "$W/o1/same_name" "$PROG"
PION_CACHE_DIR="$W/cas_f2" "$PIONC" build -o "$W/o2/same_name" "$PROG"
cmp "$W/o1/same_name" "$W/o2/same_name" || fail "two cold -o links of one program differ"
PION_CACHE_DIR="$W/cas_f1" "$PIONC" build "$PROG"
PION_CACHE_DIR="$W/cas_f2" "$PIONC" build "$PROG"
F1=$(ls "$W/cas_f1/bin")
[ "$(ls "$W/cas_f2/bin")" = "$F1" ] || fail "CAS binary names differ"
cmp "$W/cas_f1/bin/$F1" "$W/cas_f2/bin/$F1" || fail "two cold CAS links of one program differ"
if [ "$(uname -s)" = "Darwin" ]; then
  for f in "$W/o1/same_name" "$W/cas_f1/bin/$F1"; do
    ID=$(codesign -dv "$f" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$ID" = "$(basename "$f")" ] || fail "code-signature identifier '$ID' of $f is not its basename"
  done
fi
# A basename near NAME_MAX (240 bytes) links: the staged name is no longer.
LONG=$(printf '%0240d' 0 | tr 0 n)
"$PIONC" build -o "$W/out/$LONG" "$PROG"
[ "$("$W/out/$LONG")" = "p93 ok" ] || fail "240-byte -o basename"
no_tmp "$W/out" "long -o name"
echo "p93 byte-identical cold links + 240-byte basename: OK"

# 2g) A directory or 0-byte file at the CAS binary path is never a hit.
PION_CACHE_DIR="$W/cas_g1" "$PIONC" build "$PROG"
GBIN=$(ls "$W/cas_g1/bin")
mkdir -p "$W/cas_g2/bin/$GBIN"
if PION_CACHE_DIR="$W/cas_g2" "$PIONC" run "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc run reported success with a directory at its CAS binary path"
fi
no_tmp "$W/cas_g2" "CAS path is a directory"
mkdir -p "$W/cas_g3/bin"
: > "$W/cas_g3/bin/$GBIN"
G3=$(PION_CACHE_DIR="$W/cas_g3" "$PIONC" run "$PROG") || fail "run over a 0-byte CAS binary"
[ "$G3" = "p93 ok" ] || fail "run over a 0-byte CAS binary printed '$G3'"
[ -s "$W/cas_g3/bin/$GBIN" ] || fail "0-byte CAS binary was not replaced"
echo "p93 CAS hits need a non-empty regular file: OK"

# 2h) Concurrent CAS index updates (index.tsv under index.tsv.lock) keep every key.
mkdir -p "$W/app2"
sed 's/p93 ok/p93 two/' "$PROG" > "$W/app2/main.pion"
PION_CACHE_DIR="$W/cas_h1" "$PIONC" build "$PROG"
PION_CACHE_DIR="$W/cas_h2" "$PIONC" build "$W/app2/main.pion"
K1=$(cut -f1 "$W/cas_h1/index.tsv" | sort)
K2=$(cut -f1 "$W/cas_h2/index.tsv" | sort)
[ -n "$K1" ] && [ -n "$K2" ] || fail "CAS index empty after a build"
for round in 1 2 3 4; do
  HC="$W/cas_h_$round"
  PION_CACHE_DIR="$HC" "$PIONC" build "$PROG" > "$W/h1.out" 2>&1 &
  HP1=$!
  PION_CACHE_DIR="$HC" "$PIONC" build "$W/app2/main.pion" > "$W/h2.out" 2>&1 &
  HP2=$!
  wait "$HP1" || fail "concurrent build 1 (round $round)"
  wait "$HP2" || fail "concurrent build 2 (round $round)"
  GOT=$(cut -f1 "$HC/index.tsv" | sort)
  for k in $K1 $K2; do
    printf '%s\n' "$GOT" | grep -qx "$k" || fail "index.tsv lost key $k (round $round)"
  done
done
# `cache prune` fails (non-zero, ok:false) when it cannot write the index.
mkdir -p "$W/cas_p/index.tsv/sub"
if PION_CACHE_DIR="$W/cas_p" "$PIONC" cache prune --json > "$W/prune.out" 2>&1; then
  fail "pionc cache prune succeeded although index.tsv cannot be written"
fi
grep -q '"ok":false' "$W/prune.out" || fail "cache prune error: $(cat "$W/prune.out")"
echo "p93 concurrent CAS index updates + cache prune failure: OK"

# 2i) No index lock (index.tsv.lock is a directory): builds never rewrite the
# index; prune and clean fail with ok:false; index and cached files intact.
export PION_CACHE_DIR="$W/cas_i"
"$PIONC" build "$PROG"
[ -s "$W/cas_i/index.tsv" ] || fail "no CAS index after a build"
rm -f "$W/cas_i/index.tsv.lock"
mkdir -p "$W/cas_i/index.tsv.lock"
snap() { (cd "$W/cas_i" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done); }
SNAP1=$(snap)
"$PIONC" build "$PROG" > "$W/i.out" 2>&1 || true
for cmd in "cache prune --json" "clean --json"; do
  if "$PIONC" $cmd > "$W/i.out" 2>&1; then
    fail "pionc $cmd succeeded without the CAS index lock"
  fi
  grep -q '"ok":false' "$W/i.out" || fail "pionc $cmd error: $(cat "$W/i.out")"
done
[ "$(snap)" = "$SNAP1" ] || fail "CAS files changed without the index lock"
echo "p93 unlockable CAS index left intact (build, prune, clean): OK"

# 2i') With the lock available, anything but a regular file at index.tsv (a
# directory, a dangling symlink) makes prune / clear / clean fail and leaves
# the index and every cached file alone.
export PION_CACHE_DIR="$W/cas_i2"
"$PIONC" build "$PROG"
cp "$W/cas_i2/index.tsv" "$W/index_saved.tsv"
snap2() { (cd "$W/cas_i2" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done); }
for kind in dir dangling; do
  rm -f "$W/cas_i2/index.tsv"
  if [ "$kind" = dir ]; then
    mkdir -p "$W/cas_i2/index.tsv/sub"
  else
    ln -s "$W/no_such_index" "$W/cas_i2/index.tsv"
  fi
  SNAPI=$(snap2)
  for cmd in "cache prune --json" "cache clear --json" "clean --json"; do
    if "$PIONC" $cmd > "$W/i.out" 2>&1; then
      fail "pionc $cmd succeeded with a $kind index.tsv"
    fi
    grep -q '"ok":false' "$W/i.out" || fail "pionc $cmd ($kind index.tsv): $(cat "$W/i.out")"
    [ "$(snap2)" = "$SNAPI" ] || fail "pionc $cmd changed cached files ($kind index.tsv)"
  done
  if [ "$kind" = dir ]; then
    [ -d "$W/cas_i2/index.tsv/sub" ] || fail "directory index.tsv was touched"
    rm -rf "$W/cas_i2/index.tsv"
  else
    [ -L "$W/cas_i2/index.tsv" ] && [ "$(readlink "$W/cas_i2/index.tsv")" = "$W/no_such_index" ] ||
      fail "dangling index.tsv symlink was touched"
    rm -f "$W/cas_i2/index.tsv"
  fi
  cp "$W/index_saved.tsv" "$W/cas_i2/index.tsv"
done
echo "p93 non-regular index.tsv left intact (prune, clear, clean): OK"

# 2i'') An lstat *error* (not ENOENT) is never taken for "missing": an
# LD_PRELOAD shim (Linux, dynamically linked pionc) makes lstat fail with
# EACCES for index.tsv only — the lock still works — and, separately, for
# the staging directory root after the publish.
if [ "$(uname -s)" = Linux ]; then
  cat > "$W/lstat_shim.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
/* Only inside pionc itself (comm "pionc..."), never in cc / ld / qbe. */
static int active(void) {
    static int on = -1;
    if (on < 0) {
        char comm[64] = {0};
        FILE *f = fopen("/proc/self/comm", "r");
        on = f && fgets(comm, sizeof comm, f) && strncmp(comm, "pionc", 5) == 0;
        if (f) fclose(f);
    }
    return on;
}
static int hit(const char *p) {
    const char *ex = getenv("J0_LSTAT_FAIL_EXACT"), *pre = getenv("J0_LSTAT_FAIL_PREFIX");
    if (!p || !active()) return 0;
    const char *b = strrchr(p, '/');
    b = b ? b + 1 : p;
    return (ex && strcmp(b, ex) == 0) || (pre && strncmp(b, pre, strlen(pre)) == 0);
}
int lstat(const char *p, struct stat *st) {
    static int (*real)(const char *, struct stat *);
    if (hit(p)) { errno = EACCES; return -1; }
    if (!real) real = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, "lstat");
    return real(p, st);
}
int lstat64(const char *p, struct stat64 *st) {
    static int (*real)(const char *, struct stat64 *);
    if (hit(p)) { errno = EACCES; return -1; }
    if (!real) real = (int (*)(const char *, struct stat64 *))dlsym(RTLD_NEXT, "lstat64");
    return real(p, st);
}
EOF
  "$REAL_CC" -shared -fPIC -O1 -o "$W/lstat_shim.so" "$W/lstat_shim.c" -ldl
  export PION_CACHE_DIR="$W/cas_ls"
  "$PIONC" build "$PROG"
  ISUM=$(cksum < "$W/cas_ls/index.tsv")
  # A build still succeeds (its LRU update is skipped) and leaves the index.
  LD_PRELOAD="$W/lstat_shim.so" J0_LSTAT_FAIL_EXACT=index.tsv "$PIONC" build "$W/app2/main.pion"
  [ "$(cksum < "$W/cas_ls/index.tsv")" = "$ISUM" ] || fail "index.tsv rewritten although its lstat failed"
  snap3() { (cd "$W/cas_ls" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done); }
  SNAPL=$(snap3)
  for cmd in "cache prune --json" "cache clear --json" "clean --json"; do
    if LD_PRELOAD="$W/lstat_shim.so" J0_LSTAT_FAIL_EXACT=index.tsv "$PIONC" $cmd > "$W/i.out" 2>&1; then
      fail "pionc $cmd succeeded although lstat(index.tsv) failed"
    fi
    grep -q '"ok":false' "$W/i.out" || fail "pionc $cmd (lstat error): $(cat "$W/i.out")"
    [ "$(snap3)" = "$SNAPL" ] || fail "pionc $cmd changed cached files although lstat(index.tsv) failed"
  done
  # lstat of the staging root fails after the publish: reported, not "removed".
  set +e
  LD_PRELOAD="$W/lstat_shim.so" J0_LSTAT_FAIL_PREFIX=.pion_ld. "$PIONC" build -o "$W/out/lsapp" "$PROG" > "$W/ls.out" 2>&1
  LS_RC=$?
  set -e
  [ "$LS_RC" -ne 0 ] || fail "staging lstat error after publish was not reported"
  grep -q "published $W/out/lsapp" "$W/ls.out" || fail "error does not name the published output: $(cat "$W/ls.out")"
  grep -q "failed to remove staging directory" "$W/ls.out" || fail "error does not name the staging dir: $(cat "$W/ls.out")"
  [ "$("$W/out/lsapp")" = "p93 ok" ] || fail "published binary after a staging lstat error"
  ls -d "$W/out"/.pion_ld.* > /dev/null 2>&1 || fail "staging dir reported as removed although its lstat failed"
  rm -rf "$W/out"/.pion_ld.*
  echo "p93 lstat errors never read as missing (index.tsv, staging root): OK"
else
  echo "p93 lstat error injection: SKIPPED (LD_PRELOAD shim is Linux-only; test_rt covers EACCES)"
fi

# 2j) A linker that exits 0 with an empty output never replaces -o or adds a
# CAS entry; nested side files and symlinks in the staging dir are removed
# without touching what the links point to.
export PION_CACHE_DIR="$W/cas_j"
KEEP_SUM=$(cksum < "$W/out/keep")
if FAKE_LD_MODE=empty CC="$W/fakecc" "$PIONC" build -o "$W/out/keep" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build -o succeeded although the linker wrote an empty file"
fi
[ "$(cksum < "$W/out/keep")" = "$KEEP_SUM" ] || fail "empty link output replaced the old -o file"
if FAKE_LD_MODE=empty CC="$W/fakecc" "$PIONC" build "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build succeeded although the linker wrote an empty CAS binary"
fi
if [ -d "$W/cas_j/bin" ] && [ -n "$(find "$W/cas_j/bin" -type f -size 0)" ]; then
  fail "empty link output became a CAS entry"
fi
no_tmp "$W/out" "empty link output"
no_tmp "$W/cas_j" "empty CAS link output"
mkdir -p "$W/outside"
echo sentinel > "$W/outside/sentinel"
FAKE_SENTINEL="$W/outside/sentinel" FAKE_LD_MODE=nest CC="$W/fakecc" "$PIONC" build -o "$W/out/nested" "$PROG"
[ "$("$W/out/nested")" = "p93 ok" ] || fail "binary linked next to nested side files"
[ "$(cat "$W/outside/sentinel")" = sentinel ] || fail "staging cleanup touched a symlink target"
[ -d "$W/outside" ] || fail "staging cleanup followed a directory symlink"
no_tmp "$W/out" "nested staging side files"
echo "p93 empty link output rejected + nested staging cleanup: OK"

# 2j') A staging cleanup failure after the publish fails the command, naming
# the published output and the leftover directory; the output works. Needs a
# non-root user (root ignores 0500): as root, rerun through setpriv as nobody.
RO="$W/ro_case"
mkdir -p "$RO/out" "$RO/tools"
cp "$PIONC" "$RO/tools/pionc"
cp "$OUT_DIR/qbe" "$OUT_DIR/libpionrt.a" "$W/fakecc" "$RO/tools/"
cp "$PROG" "$RO/main.pion"
RO_RUN=""
if [ "$(id -u)" -ne 0 ]; then
  RO_RUN=" "
elif command -v setpriv >/dev/null 2>&1; then
  chmod 0755 "$W"
  chown -R 65534:65534 "$RO"
  RO_RUN="setpriv --reuid=65534 --regid=65534 --clear-groups"
fi
if [ -n "$RO_RUN" ]; then
  set +e
  $RO_RUN env PION_CACHE_DIR="$RO/cas" PION_QBE="$RO/tools/qbe" PION_RT_LIB="$RO/tools/libpionrt.a" \
    FAKE_REAL_CC="$REAL_CC" FAKE_LD_MODE=rostage CC="$RO/tools/fakecc" TMPDIR="$RO" \
    "$RO/tools/pionc" build -o "$RO/out/roapp" "$RO/main.pion" > "$W/ro.out" 2>&1
  RO_RC=$?
  set -e
  [ "$RO_RC" -ne 0 ] || fail "post-publish staging cleanup failure was not reported"
  grep -q "published $RO/out/roapp" "$W/ro.out" || fail "error does not name the published output: $(cat "$W/ro.out")"
  grep -q "failed to remove staging directory" "$W/ro.out" || fail "error does not name the staging dir: $(cat "$W/ro.out")"
  [ "$("$RO/out/roapp")" = "p93 ok" ] || fail "published binary after a cleanup failure"
  find "$RO/out" -type d -exec chmod 0700 {} + 2>/dev/null || true
  rm -rf "$RO/out"/.pion_ld.*
  echo "p93 post-publish staging cleanup failure reported: OK"
else
  echo "p93 post-publish staging cleanup failure: SKIPPED (root without setpriv)"
fi

# 2k) On POSIX a backslash is an ordinary file-name character.
export PION_CACHE_DIR="$W/cas_k"
# Even with OS=Windows_NT in the environment (the host is a compile-time
# fact, pion_cli_is_windows): build for the real host target.
HOST_T=$("$PIONC" --version --json | sed -n 's/.*"target":"\([^"]*\)".*/\1/p')
[ -n "$HOST_T" ] || fail "no host target in pionc --version --json"
mkdir -p "$W/tmp_k"
winenv() { (cd "$W" && OS=Windows_NT PION_TARGET="$HOST_T" TMPDIR="$W/tmp_k" "$@"); }
: > "$W/out/a"
OUTB="$W/out/"'a\b'
winenv "$PIONC" build -o "$OUTB" "$PROG"
[ "$("$OUTB")" = "p93 ok" ] || fail "binary named 'a\\b'"
[ -f "$W/out/a" ] && [ ! -s "$W/out/a" ] || fail "'$W/out/a' was changed by -o 'a\\b'"
OUTC="$W/out/"'c\d'
winenv "$PIONC" build -o "$OUTC" "$PROG"
[ "$("$OUTC")" = "p93 ok" ] || fail "binary named 'c\\d'"
[ ! -e "$W/out/c" ] || fail "stray directory '$W/out/c' created by -o 'c\\d'"
no_tmp "$W/out" "backslash -o"
echo "p93 POSIX backslash file name: OK"

# --- 3) Wasm32 -o ------------------------------------------------------------------
export PION_CACHE_DIR="$W/cas_w"
"$PIONC" build --target wasm32 -o "$W/out/app.wasm" "$PROG"
[ -s "$W/out/app.wasm" ] || fail "wasm32 -o output missing"
no_tmp "$W/out" "wasm32 -o"
mkdir -p "$W/out/wdir/sub"
if "$PIONC" build --target wasm32 -o "$W/out/wdir" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build --target wasm32 -o <non-empty dir> succeeded"
fi
no_tmp "$W/out" "failed wasm32 -o"
# wasm-opt on/off address different single-package CAS modules; a failing
# wasm-opt leaves no raw/temp file and the old -o output untouched.
mkdir -p "$W/wopt"
cat > "$W/wopt/wasm-opt" <<'EOF'
#!/bin/sh
[ "${FAKE_WOPT_FAIL:-0}" = 1 ] && exit 1
in=""; out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  case "$a" in -*) ;; *) [ "$prev" = "-o" ] || in="$a" ;; esac
  prev="$a"
done
# The input must never be the output file, not even case-insensitively.
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
[ "$(lc "$in")" != "$(lc "$out")" ] || { echo "wasm-opt: input is the output $out" >&2; exit 3; }
if [ "${FAKE_WOPT_EMPTY:-0}" = 1 ]; then : > "$out"; exit 0; fi
cp "$in" "$out"
EOF
chmod +x "$W/wopt/wasm-opt"
export PION_CACHE_DIR="$W/cas_wo"
PATH="$W/wopt:$PATH" "$PIONC" build --release --target wasm32 "$PROG"
N1=$(ls "$W/cas_wo/bin" | grep -c '\.wasm$')
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 "$PROG"
N2=$(ls "$W/cas_wo/bin" | grep -c '\.wasm$')
[ "$N1" = 1 ] && [ "$N2" = 2 ] || fail "wasm-opt on/off share a CAS module ($N1 then $N2 .wasm files)"
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 -o "$W/out/keep.wasm" "$PROG"
WSUM=$(cksum < "$W/out/keep.wasm")
if FAKE_WOPT_FAIL=1 PATH="$W/wopt:$PATH" "$PIONC" build --release --target wasm32 -o "$W/out/keep.wasm" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build succeeded with a failing wasm-opt"
fi
[ "$(cksum < "$W/out/keep.wasm")" = "$WSUM" ] || fail "failed wasm-opt modified the old -o output"
no_tmp "$W/out" "failed wasm-opt"
# A wasm-opt that exits 0 with an empty output fails the build.
if FAKE_WOPT_EMPTY=1 PATH="$W/wopt:$PATH" "$PIONC" build --release --target wasm32 -o "$W/out/keep.wasm" "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build succeeded although wasm-opt wrote an empty file"
fi
[ "$(cksum < "$W/out/keep.wasm")" = "$WSUM" ] || fail "empty wasm-opt output replaced the old -o output"
export PION_CACHE_DIR="$W/cas_we"
if FAKE_WOPT_EMPTY=1 PATH="$W/wopt:$PATH" "$PIONC" build --release --target wasm32 "$PROG" > "$W/fail.out" 2>&1; then
  fail "pionc build succeeded although wasm-opt wrote an empty CAS module"
fi
if [ -d "$W/cas_we/bin" ] && [ -n "$(find "$W/cas_we/bin" -type f -size 0)" ]; then
  fail "empty wasm-opt output became a CAS entry"
fi
no_tmp "$W/cas_we" "empty wasm-opt CAS"
# wasm-opt's input never aliases the output, even for `-o RAW.WASM`.
PATH="$W/wopt:$PATH" "$PIONC" build --release --target wasm32 -o "$W/out/RAW.WASM" "$PROG"
[ -s "$W/out/RAW.WASM" ] || fail "-o RAW.WASM output missing"
no_tmp "$W/out" "failed wasm-opt"
no_tmp "$W/cas_wo" "wasm-opt CAS"
echo "p93 wasm32 -o publish + wasm-opt CAS key + failure cleanup: OK"
echo "p93_cli_link_symlink: ALL OK"
