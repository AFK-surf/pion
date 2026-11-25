#!/bin/sh
# P125: native String slice spans, scalar Map entries, managed String file reads
# and Channel[String].send without a duplicate deep freeze
# (compiler/src/core/qbe.pion `qbe_emit_span_concat` / `qbe_try_span_bindings` /
# `qbe_entry_plan` / `qbe_try_slice_entry`; runtime `pion_str_slice_data`,
# `pion_str_concat_spans`, `pion_strbuf_push_slice`, `pion_map_scalar_entry`,
# `pion_read_file_obj`; Lean: tests/lean/proofs/QbeStringSpanMapEntry.lean).
# Verifies, in both --release and dev builds:
#   1. semantics / fallback / scanner / owners exit 0 with exactly "ok\n":
#      slice bounds side-effect order, early return inside a bound, chained
#      slices, Map[String, Int64] entry hit / miss / rehash, fresh-key identity,
#      a call that mutates the map (ordinary lookup kept), StringBuilder spans,
#      contains / set pairs, owners replaced inside a bound, 13-part chains.
#   2. order traps at the original slice site after the same side effects
#      (stderr "1 2 3 2" resp. "1 7", then the slice panic, SIGABRT, no stdout).
#   3. fileread: empty, multi-line, binary / UTF-8 / NUL and 300,000-byte files read
#      as String equal fs_read_bytes byte-for-byte; a missing file is Err for
#      both; file text feeds slice spans and scalar map entries.
#   4. SSA: pion_str_concat_spans / pion_str_slice_data / pion_map_scalar_entry /
#      pion_strbuf_push_slice calls are present, fallback keeps pion_map_set.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR" "$TMP_DIR/files" "$TMP_DIR/release" "$TMP_DIR/dev"

python3 -E - "$TMP_DIR/files" <<'PY'
import sys
from pathlib import Path
d = Path(sys.argv[1])
(d / 'empty.txt').write_bytes(b'')
(d / 'lines.txt').write_bytes(b'abcdef\nxy\nabc\n\nabcz\nxy')
(d / 'binary.bin').write_bytes(bytes(range(256)) + '日本語'.encode() + b'\x00tail\x00')
(d / 'big.txt').write_bytes(b''.join(b'line %06d %s\n' % (i, b'x' * (i % 23)) for i in range(16000))[:300000])
PY

for MODE in release dev; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  for NAME in semantics order fallback owners scanner fileread; do
    "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/$MODE/$NAME.ssa" -o "$TMP_DIR/$MODE/$NAME" "$DIR/$NAME.pion"
  done
  python3 -E "$DIR/check.py" "$TMP_DIR" "$MODE"
done
echo "PASS: p125_string_span_map_entry"
