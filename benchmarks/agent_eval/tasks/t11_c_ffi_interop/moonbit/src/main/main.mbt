///| t11_c_ffi_interop: libc + zlib through native `extern "C"`

///|
#borrow(s)
extern "C" fn c_strlen(s : Bytes) -> UInt64 = "strlen"

///|
extern "C" fn c_abs(x : Int) -> Int = "abs"

///|
#borrow(buf)
extern "C" fn z_crc32(crc : UInt64, buf : Bytes, len : UInt) -> UInt64 = "crc32"

///| C stub: zlibVersion() copied into Bytes.
extern "C" fn ae_zlib_version() -> Bytes = "ae_zlib_version"

///|
let fox : String = "The quick brown fox jumps over the lazy dog"

///| ASCII string -> bytes, optionally NUL-terminated for C.
fn ascii_bytes(s : String, nul~ : Bool = false) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push(s.code_unit_at(i).to_int().to_byte())
  }
  if nul {
    out.push(b'\x00')
  }
  Bytes::from_array(out)
}

///|
fn strlen_of(s : String) -> Int {
  c_strlen(ascii_bytes(s, nul=true)).to_int()
}

///|
fn crc32_of(s : String) -> UInt64 {
  z_crc32(0UL, ascii_bytes(s), s.length().reinterpret_as_uint())
}

///|
fn hex32(v : UInt64) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for shift = 28; shift >= 0; shift = shift - 4 {
    let d = ((v >> shift) & 15UL).to_int()
    sb.write_char(digits[d].to_char().unwrap())
  }
  sb.to_string()
}

///|
fn zlib_major() -> String {
  let v = ae_zlib_version()
  let sb = StringBuilder()
  for b in v {
    if b == b'.' {
      break
    }
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn main {
  println("strlen(\"hello, agent\")=\{strlen_of("hello, agent")}")
  println("abs(-42)=\{c_abs(-42)}")
  println("crc32(\"\{fox}\")=\{hex32(crc32_of(fox))}")
  println("zlib_major=\{zlib_major()}")
}

///|
test "ffi" {
  assert_eq(strlen_of(""), 0)
  assert_eq((c_abs(7), c_abs(-2147483647)), (7, 2147483647))
  assert_eq(crc32_of(""), 0UL)
  assert_eq(hex32(crc32_of(fox)), "414fa339")
  assert_eq(hex32(255UL), "000000ff")
}
