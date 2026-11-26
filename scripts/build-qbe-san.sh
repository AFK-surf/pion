#!/bin/sh
# Build ASan+UBSan QBE once into <out_dir> with bounded parallelism:
#
#   sh scripts/build-qbe-san.sh <out_dir>
#
# Outputs:
#   <out_dir>/config.h
#   <out_dir>/obj/<path_with_underscores>.o  (e.g. main.c.o, arm64_macho.c.o)
#   <out_dir>/qbe
#   <out_dir>/qbe.cc
#
# Exits 77 when ${CC:-cc} cannot compile, link and run a minimal
# `-fsanitize=address,undefined -fno-sanitize-recover=all` program.
set -eu

OUT_DIR="${1:?usage: build-qbe-san.sh <out_dir>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
QBE_DIR="$ROOT_DIR/vendor/qbe"
CC_BIN="${CC:-cc}"

mkdir -p "$OUT_DIR/obj"

# Probe ASan+UBSan toolchain support.
PROBE_BIN="$OUT_DIR/.san_probe"
if ! printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address,undefined -fno-sanitize-recover=all -o "$PROBE_BIN" 2>/dev/null \
  || ! "$PROBE_BIN" 2>/dev/null; then
  rm -f "$PROBE_BIN"
  exit 77
fi
rm -f "$PROBE_BIN"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  *Darwin*)
    case "$ARCH" in
      *arm64*) DEFTGT="T_arm64_apple" ;;
      *)       DEFTGT="T_amd64_apple" ;;
    esac
    ;;
  *MINGW*|*MSYS*|*CYGWIN*)
    DEFTGT="T_amd64_win"
    ;;
  *)
    case "$ARCH" in
      *aarch64*|*arm64*) DEFTGT="T_arm64" ;;
      *riscv64*)         DEFTGT="T_rv64" ;;
      *)                 DEFTGT="T_amd64_sysv" ;;
    esac
    ;;
esac
printf '#define Deftgt %s\n' "$DEFTGT" > "$OUT_DIR/config.h"

# Remove stale objects before building.
rm -f "$OUT_DIR"/obj/*.o "$OUT_DIR/qbe" "$OUT_DIR/qbe.cc"

python3 - "$CC_BIN" "$QBE_DIR" "$OUT_DIR" <<'PYEOF'
import os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

cc, qbe_dir, out_dir = sys.argv[1:4]
obj_dir = os.path.join(out_dir, "obj")

def usable_cpus():
    try:
        n = len(os.sched_getaffinity(0))
    except AttributeError:
        n = os.cpu_count() or 1
    try:
        q, p = open("/sys/fs/cgroup/cpu.max").read().split()[:2]
        if q != "max":
            n = min(n, max(1, int(q) // int(p)))
    except (OSError, ValueError):
        pass
    return max(1, n)

jobs_env = os.environ.get("PION_QBE_SAN_JOBS", "")
jobs = int(jobs_env) if jobs_env.isdigit() and int(jobs_env) > 0 else min(usable_cpus(), 8)

srcs = [
    "main.c", "util.c", "parse.c", "abi.c", "cfg.c", "mem.c", "ssa.c",
    "alias.c", "load.c", "copy.c", "fold.c", "gvn.c", "gcm.c", "simpl.c",
    "ifopt.c", "live.c", "spill.c", "rega.c", "emit.c",
    "amd64/targ.c", "amd64/sysv.c", "amd64/isel.c", "amd64/emit.c", "amd64/winabi.c", "amd64/elf.c",
    "arm64/targ.c", "arm64/abi.c", "arm64/isel.c", "arm64/emit.c", "arm64/macho.c",
    "rv64/targ.c", "rv64/abi.c", "rv64/isel.c", "rv64/emit.c",
]

san_flags = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
t0 = time.time()

def compile_one(src):
    obj = os.path.join(obj_dir, src.replace("/", "_") + ".o")
    cmd = [cc, "-std=c99", "-O1", "-g", "-w", *san_flags, "-fno-omit-frame-pointer",
           "-I", out_dir, "-I", qbe_dir, "-c", os.path.join(qbe_dir, src), "-o", obj]
    r = subprocess.run(cmd)
    if r.returncode != 0:
        raise SystemExit(f"FAIL: build-qbe-san.sh failed compiling {src} (exit {r.returncode})")
    return obj

with ThreadPoolExecutor(max_workers=jobs) as pool:
    objs = list(pool.map(compile_one, srcs))

qbe_bin = os.path.join(out_dir, "qbe")
r = subprocess.run([cc, *san_flags, *objs, "-o", qbe_bin])
if r.returncode != 0:
    raise SystemExit(f"FAIL: build-qbe-san.sh failed linking {qbe_bin} (exit {r.returncode})")

dt_ms = int((time.time() - t0) * 1000)
print(f"Built {qbe_bin} (ASan+UBSan, -j {jobs}) in {dt_ms} ms")
PYEOF

printf '%s\n' "$CC_BIN" > "$OUT_DIR/qbe.cc"
