#!/usr/bin/env sh
# Wave 2 PR F E2E: Bytes / BytesView full LE+BE binary readers + blit_to / copy_from_string
# (Native dev & release + Wasm32 Node & Web + OOB/overflow/mmap_ro panics + Mutex frozen Bytes).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== Wave 2 PR F E2E: Bytes / BytesView LE+BE Readers & Blit Primitives ==="

cat > "$TMP_DIR/main.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic("FAIL: " + msg)
  }
}

fn make_test_buf() -> Bytes {
  // 32 bytes:
  // [0..1]   : 0x00, 0x7F, 0x80, 0xFF (i8/u8 edge values) -> offsets 0..3
  // [4..7]   : 0x12, 0x34, 0x80, 0x01 (i16/u16 BE & LE)
  // [8..11]  : 0x12, 0x34, 0x56, 0x78 (i32/u32 BE=0x12345678, LE=0x78563412)
  // [12..15] : 0x80, 0x00, 0x00, 0x01 (i32 BE=-2147483647, u32 BE=0x80000001)
  // [16..23] : 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 (i64/u64 BE & LE)
  // [24..27] : 0x3F, 0xC0, 0x00, 0x00 (f32 BE = 1.5f)
  // [28..35] : 0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18 (f64 BE = 3.141592653589793)
  // [36..39] : 0x00, 0x00, 0xC0, 0x3F (f32 LE = 1.5f)
  // [40..47] : 0x18, 0x2D, 0x44, 0x54, 0xFB, 0x21, 0x09, 0x40 (f64 LE = 3.141592653589793)
  // [48..55] : 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF (all-ones: -1 / max unsigned)
  // [56..59] : 0x80, 0x00, 0x00, 0x00 (f32 BE = -0.0f)
  // [60..67] : 0x7F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 (f64 BE = qNaN payload 1)
  let b = Bytes::new(68)
  b[0] = b'\x00'
  b[1] = b'\x7f'
  b[2] = b'\x80'
  b[3] = b'\xff'
  b[4] = b'\x12'
  b[5] = b'\x34'
  b[6] = b'\x80'
  b[7] = b'\x01'
  b[8] = b'\x12'
  b[9] = b'\x34'
  b[10] = b'\x56'
  b[11] = b'\x78'
  b[12] = b'\x80'
  b[13] = b'\x00'
  b[14] = b'\x00'
  b[15] = b'\x01'
  b[16] = b'\x01'
  b[17] = b'\x02'
  b[18] = b'\x03'
  b[19] = b'\x04'
  b[20] = b'\x05'
  b[21] = b'\x06'
  b[22] = b'\x07'
  b[23] = b'\x08'
  b[24] = b'\x3f'
  b[25] = b'\xc0'
  b[26] = b'\x00'
  b[27] = b'\x00'
  b[28] = b'\x40'
  b[29] = b'\x09'
  b[30] = b'\x21'
  b[31] = b'\xfb'
  b[32] = b'\x54'
  b[33] = b'\x44'
  b[34] = b'\x2d'
  b[35] = b'\x18'
  b[36] = b'\x00'
  b[37] = b'\x00'
  b[38] = b'\xc0'
  b[39] = b'\x3f'
  b[40] = b'\x18'
  b[41] = b'\x2d'
  b[42] = b'\x44'
  b[43] = b'\x54'
  b[44] = b'\xfb'
  b[45] = b'\x21'
  b[46] = b'\x09'
  b[47] = b'\x40'
  let mut k = 48
  while k < 56 {
    b[k] = b'\xff'
    k += 1
  }
  b[56] = b'\x80'
  b[60] = b'\x7f'
  b[61] = b'\xf8'
  b[67] = b'\x01'
  b
}

fn check_readers_bytes(b : Bytes) -> Unit {
  must(b.read_i8(0).to_int() == 0, "b.read_i8(0)")
  must(b.read_i8(1).to_int() == 127, "b.read_i8(1)")
  must(b.read_i8(2).to_int() == -128, "b.read_i8(2)")
  must(b.read_i8(3).to_int() == -1, "b.read_i8(3)")

  must(b.read_u8(0) == 0, "b.read_u8(0)")
  must(b.read_u8(1) == 127, "b.read_u8(1)")
  must(b.read_u8(2) == 128, "b.read_u8(2)")
  must(b.read_u8(3) == 255, "b.read_u8(3)")

  must(b.read_u16_be(4) == 0x1234, "b.read_u16_be(4)")
  must(b.read_i16_be(4) == 0x1234, "b.read_i16_be(4)")
  must(b.read_u16_le(4) == 0x3412, "b.read_u16_le(4)")
  must(b.read_i16_le(4) == 0x3412, "b.read_i16_le(4)")
  must(b.read_u16_be(6) == 0x8001, "b.read_u16_be(6)")
  must(b.read_i16_be(6) == -32767, "b.read_i16_be(6)")
  must(b.read_u16_le(6) == 0x0180, "b.read_u16_le(6)")
  must(b.read_i16_be(48) == -1, "b.read_i16_be(48)")
  must(b.read_u16_be(48) == 65535, "b.read_u16_be(48)")
  must(b.read_i16_le(48) == -1, "b.read_i16_le(48)")
  must(b.read_u16_le(48) == 65535, "b.read_u16_le(48)")

  must(b.read_i32_be(8) == 0x12345678, "b.read_i32_be(8)")
  must(b.read_u32_be(8) == 0x12345678U, "b.read_u32_be(8)")
  must(b.read_i32_le(8) == 0x78563412, "b.read_i32_le(8)")
  must(b.read_u32_le(8) == 0x78563412U, "b.read_u32_le(8)")
  must(b.read_i32_be(12) == -2147483647, "b.read_i32_be(12)")
  must(b.read_u32_be(12) == 0x80000001U, "b.read_u32_be(12)")
  must(b.read_i32_be(48) == -1, "b.read_i32_be(48)")
  must(b.read_u32_be(48) == 0xFFFFFFFFU, "b.read_u32_be(48)")
  must(b.read_i32_le(48) == -1, "b.read_i32_le(48)")
  must(b.read_u32_le(48) == 0xFFFFFFFFU, "b.read_u32_le(48)")

  // Unaligned 32-bit BE/LE at offset 9: [0x34, 0x56, 0x78, 0x80]
  must(b.read_u32_be(9) == 0x34567880U, "b.read_u32_be unaligned")
  must(b.read_u32_le(9) == 0x80785634U, "b.read_u32_le unaligned")

  must(b.read_i64_be(16) == 0x0102030405060708L, "b.read_i64_be(16)")
  must(b.read_u64_be(16) == 0x0102030405060708UL, "b.read_u64_be(16)")
  must(b.read_i64_le(16) == 0x0807060504030201L, "b.read_i64_le(16)")
  must(b.read_u64_le(16) == 0x0807060504030201UL, "b.read_u64_le(16)")
  must(b.read_i64_be(48) == -1L, "b.read_i64_be(48)")
  must(b.read_u64_be(48) == 0xFFFFFFFFFFFFFFFFUL, "b.read_u64_be(48)")
  must(b.read_i64_le(48) == -1L, "b.read_i64_le(48)")
  must(b.read_u64_le(48) == 0xFFFFFFFFFFFFFFFFUL, "b.read_u64_le(48)")

  // Unaligned 64-bit BE at offset 17: [0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x3f]
  must(b.read_u64_be(17) == 0x020304050607083FUL, "b.read_u64_be unaligned")

  must(b.read_f32_be(24) == 1.5f, "b.read_f32_be(24)")
  must(b.read_f32_le(36) == 1.5f, "b.read_f32_le(36)")
  must(b.read_f32_be(56).to_bits() == -2147483648, "b.read_f32_be(-0.0f)")
  must(b.read_f64_be(28) == 3.141592653589793, "b.read_f64_be(28)")
  must(b.read_f64_le(40) == 3.141592653589793, "b.read_f64_le(40)")
  must(b.read_f64_be(60).is_nan(), "b.read_f64_be(60) is_nan")
  must(b.read_f64_be(60).to_bits() == 0x7FF8000000000001L, "b.read_f64_be(60) payload")
}

fn check_readers_view(b : Bytes) -> Unit {
  // Non-zero base offset slice (base = 4), plus nested subview!
  let v = b.view(4, 68)
  must(v.read_i8(0).to_int() == 0x12, "v.read_i8(0)")
  must(v.read_u8(2) == 0x80, "v.read_u8(2)")
  must(v.read_u16_be(0) == 0x1234, "v.read_u16_be(0)")
  must(v.read_i16_be(2) == -32767, "v.read_i16_be(2)")
  must(v.read_u16_le(0) == 0x3412, "v.read_u16_le(0)")
  must(v.read_i16_le(44) == -1, "v.read_i16_le(44)")
  must(v.read_i32_be(4) == 0x12345678, "v.read_i32_be(4)")
  must(v.read_u32_be(8) == 0x80000001U, "v.read_u32_be(8)")
  must(v.read_i32_le(4) == 0x78563412, "v.read_i32_le(4)")
  must(v.read_u32_le(44) == 0xFFFFFFFFU, "v.read_u32_le(44)")
  must(v.read_i64_be(12) == 0x0102030405060708L, "v.read_i64_be(12)")
  must(v.read_u64_be(12) == 0x0102030405060708UL, "v.read_u64_be(12)")
  must(v.read_i64_le(12) == 0x0807060504030201L, "v.read_i64_le(12)")
  must(v.read_u64_le(44) == 0xFFFFFFFFFFFFFFFFUL, "v.read_u64_le(44)")
  must(v.read_f32_be(20) == 1.5f, "v.read_f32_be(20)")
  must(v.read_f32_le(32) == 1.5f, "v.read_f32_le(32)")
  must(v.read_f64_be(24) == 3.141592653589793, "v.read_f64_be(24)")
  must(v.read_f64_le(36) == 3.141592653589793, "v.read_f64_le(36)")

  // Nested subview starting at byte 16 of b (offset 12 of v)
  let sv = v.subview(12, 32)
  must(sv.read_i64_be(0) == 0x0102030405060708L, "sv.read_i64_be(0)")
  must(sv.read_f32_be(8) == 1.5f, "sv.read_f32_be(8)")
  must(sv.read_f64_be(12) == 3.141592653589793, "sv.read_f64_be(12)")
}

fn check_blit_and_copy() -> Unit {
  let src = "0123456789ABCDEF".to_bytes()
  let dst = Bytes::new(16)
  // 1. Non-overlapping Bytes::blit_to
  src.blit_to(dst, 2, 4, 6)
  must(dst.slice(4, 10).to_string() == "234567", "Bytes::blit_to non-overlap")
  must(dst[3] == b'\x00' && dst[10] == b'\x00', "Bytes::blit_to untouched neighbors")

  // 2. Self-overlapping Bytes::blit_to (reverse: dst_off > src_off)
  let ov = "ABCDEFGH".to_bytes()
  ov.blit_to(ov, 0, 2, 5)
  must(ov.to_string() == "ABABCDEH", "Bytes::blit_to overlap right: " + ov.to_string())

  // 3. Self-overlapping Bytes::blit_to (forward: dst_off < src_off)
  ov.blit_to(ov, 2, 0, 5)
  must(ov.to_string() == "ABCDEDEH", "Bytes::blit_to overlap left check: " + ov.to_string())
  let ov2 = "ABCDEFGH".to_bytes()
  ov2.blit_to(ov2, 3, 1, 4)
  must(ov2.to_string() == "ADEFGFGH", "Bytes::blit_to overlap left: " + ov2.to_string())

  // 4. BytesView::blit_to (non-overlapping + overlapping into owner Bytes!)
  let v = src.view(4, 12) // "456789AB"
  let dst2 = Bytes::new(10)
  v.blit_to(dst2, 1, 2, 5) // "56789"
  must(dst2.slice(2, 7).to_string() == "56789", "BytesView::blit_to non-overlap")

  let own = "0123456789".to_bytes()
  let own_v = own.view(1, 7) // "123456"
  own_v.blit_to(own, 0, 3, 6) // copy own[1..7] to own[3..9] -> "0121234569"
  must(own.to_string() == "0121234569", "BytesView::blit_to overlap right: " + own.to_string())

  // 5. Bytes::copy_from_string (ASCII + UTF-8 + zero-length boundary)
  let sb = Bytes::new(12)
  sb.copy_from_string(2, "hello world!", 6, 5)
  must(sb.slice(2, 7).to_string() == "world", "copy_from_string slice")
  let utf8_s = "Hi中文!"
  let ub = Bytes::new(utf8_s.length())
  ub.copy_from_string(0, utf8_s, 0, utf8_s.length())
  must(ub.to_string() == "Hi中文!", "copy_from_string utf8")

  // 6. Zero-length valid boundary calls (including empty Bytes)
  let empty = Bytes::new(0)
  empty.blit_to(empty, 0, 0, 0)
  empty.as_view().blit_to(empty, 0, 0, 0)
  empty.copy_from_string(0, "", 0, 0)
  sb.blit_to(sb, 12, 12, 0)
  sb.copy_from_string(12, "abc", 3, 0)
}

pub fn main(w : World) -> Int {
  let b = make_test_buf()
  check_readers_bytes(b)
  check_readers_view(b)
  check_blit_and_copy()
  io_println(w, "wave2f_ok")
  0
}
EOF

# 1. Native dev + release
DEV_OUT="$("$PIONC" run "$TMP_DIR/main.pion")"
[ "$DEV_OUT" = "wave2f_ok" ] || { echo "FAIL: native dev output=$DEV_OUT" >&2; exit 1; }
"$PIONC" build --release -o "$TMP_DIR/main_rel" "$TMP_DIR/main.pion"
REL_OUT="$("$TMP_DIR/main_rel")"
[ "$REL_OUT" = "wave2f_ok" ] || { echo "FAIL: native release output=$REL_OUT" >&2; exit 1; }
echo "1. Native dev & release -> OK"

# 2. Wasm32 Node + Web runtime parity
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/main.wasm" "$TMP_DIR/main.pion"
  WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/main.wasm")"
  [ "$WASM_OUT" = "wave2f_ok" ] || { echo "FAIL: wasm32 node output=$WASM_OUT" >&2; exit 1; }
  WEB_OUT="$(node --input-type=module -e '
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
    process.stdout.write(out.join("").trim());
  ' "$TMP_DIR/main.wasm" "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs")"
  [ "$WEB_OUT" = "wave2f_ok" ] || { echo "FAIL: wasm32 web output=$WEB_OUT" >&2; exit 1; }
  echo "2. Wasm32 Node & Web runtime parity -> OK"
fi

# 3. Mutex[Bytes] lock-held mutation + read-only fs_mmap_ro trap (Native)
cat > "$TMP_DIR/mt_mmap.pion" <<EOF
pub fn main(w : World) -> Int {
  let m = Mutex::new("abcdefgh".to_bytes())
  let b = m.lock()
  let src = "XYZ".to_bytes()
  src.blit_to(b, 0, 2, 3)
  b.copy_from_string(5, "123", 0, 3)
  let s = b.to_string()
  m.unlock()
  if s != "abXYZ123" {
    panic("mutex bytes mismatch: " + s)
  }
  io_println(w, "mt_ok")
  0
}
EOF
MT_OUT="$("$PIONC" run "$TMP_DIR/mt_mmap.pion")"
[ "$MT_OUT" = "mt_ok" ] || { echo "FAIL: mutex bytes output=$MT_OUT" >&2; exit 1; }

printf 'hello-mmap-readonly' > "$TMP_DIR/ro.bin"
cat > "$TMP_DIR/mmap_trap.pion" <<EOF
pub fn main() -> Int {
  match fs_mmap_ro("$TMP_DIR/ro.bin") {
    Ok(ro) => {
      let src = "ABCD".to_bytes()
      src.blit_to(ro, 0, 0, 4)
      0
    }
    Err(e) => { panic("mmap failed: " + e); 1 }
  }
}
EOF
"$PIONC" build -o "$TMP_DIR/mmap_trap" "$TMP_DIR/mmap_trap.pion"
set +e
MMAP_ERR="$("$TMP_DIR/mmap_trap" 2>&1)"
MMAP_RC=$?
set -e
if [ "$MMAP_RC" -eq 0 ] || ! printf '%s' "$MMAP_ERR" | grep -qi 'read-only mmap'; then
  echo "FAIL: expected mmap_ro blit_to to trap with read-only mmap (rc=$MMAP_RC, err=$MMAP_ERR)" >&2
  exit 1
fi
echo "3. Mutex[Bytes] lock-held mutation & fs_mmap_ro write trap -> OK (rc=$MMAP_RC)"

# 4. OOB / negative / INT_MAX overflow panic cases (Native + Wasm32)
check_oob() {
  LABEL="$1"
  BODY="$2"
  cat > "$TMP_DIR/oob_${LABEL}.pion" <<EOF
pub fn main() -> Int {
  ${BODY}
  0
}
EOF
  "$PIONC" build -o "$TMP_DIR/oob_${LABEL}" "$TMP_DIR/oob_${LABEL}.pion"
  set +e
  NERR="$("$TMP_DIR/oob_${LABEL}" 2>&1)"
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] || ! printf '%s' "$NERR" | grep -qi 'out of bounds'; then
    echo "FAIL: native OOB case '$LABEL' did not trap with out of bounds (rc=$RC, err=$NERR)" >&2
    exit 1
  fi
  if command -v node >/dev/null 2>&1; then
    "$PIONC" build --target wasm32 -o "$TMP_DIR/oob_${LABEL}.wasm" "$TMP_DIR/oob_${LABEL}.pion"
    set +e
    WERR="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/oob_${LABEL}.wasm" 2>&1)"
    WRC=$?
    set -e
    if [ "$WRC" -eq 0 ] || ! printf '%s' "$WERR" | grep -qi 'out of bounds'; then
      echo "FAIL: wasm32 OOB case '$LABEL' did not trap with out of bounds (rc=$WRC, err=$WERR)" >&2
      exit 1
    fi
  fi
}

check_oob "u16_neg" 'let b = Bytes::new(8); let _ = b.read_u16_be(-1)'
check_oob "u16_short" 'let b = Bytes::new(1); let _ = b.read_u16_be(0)'
check_oob "u32_imax" 'let b = Bytes::new(16); let _ = b.read_u32_be(2147483647)'
check_oob "u64_tail" 'let b = Bytes::new(12); let _ = b.read_u64_be(5)'
check_oob "f64_view_tail" 'let b = Bytes::new(16); let v = b.view(4, 11); let _ = v.read_f64_be(0)'
check_oob "blit_neg_len" 'let a = Bytes::new(8); let b = Bytes::new(8); a.blit_to(b, 0, 0, -1)'
check_oob "blit_imax" 'let a = Bytes::new(8); let b = Bytes::new(8); a.blit_to(b, 4, 0, 2147483647)'
check_oob "blit_dst_oob" 'let a = Bytes::new(8); let b = Bytes::new(4); a.blit_to(b, 0, 1, 4)'
check_oob "cstr_oob" 'let b = Bytes::new(8); b.copy_from_string(0, "abc", 1, 3)'
echo "4. 9 OOB / INT_MAX overflow panic cases (Native + Wasm32) -> OK"
echo "=== Wave 2 PR F E2E: ALL PASSED ==="
