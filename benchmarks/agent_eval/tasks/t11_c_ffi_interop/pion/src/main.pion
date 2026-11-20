///| t11_c_ffi_interop: libc + zlib through `extern "C"`

extern "C" fn c_strlen(s : Ptr) -> Int64 = "strlen"
extern "C" fn c_abs(x : Int) -> Int = "abs"
extern "C" fn z_crc32(crc : Int64, buf : Ptr, len : Int) -> Int64 = "crc32"
extern "C" fn z_version() -> Ptr = "zlibVersion"

pub let FOX : String = "The quick brown fox jumps over the lazy dog"

pub fn hex32(v : Int64) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  let mut x = v
  let mut i = 0
  while i < 8 {
    let d = (x % 16L).to_int()
    out = digits.slice(d, d + 1) + out
    x = x / 16L
    i = i + 1
  }
  out
}

pub fn crc32_of(s : String) -> Int64 {
  z_crc32(0L, s.as_cstr(), s.length())
}

pub fn zlib_major() -> String {
  let v = cstr_to_str(z_version())
  let dot = v.index_of(".")
  if dot < 0 {
    v
  } else {
    v.slice(0, dot)
  }
}

pub fn main(world : World) -> Int {
  io_println(world, "strlen(\"hello, agent\")=" + c_strlen("hello, agent".as_cstr()).to_string())
  io_println(world, "abs(-42)=" + c_abs(-42).to_string())
  io_println(world, "crc32(\"" + FOX + "\")=" + hex32(crc32_of(FOX)))
  io_println(world, "zlib_major=" + zlib_major())
  0
}

test "ffi" {
  debug_assert(c_strlen("".as_cstr()) == 0L, "empty strlen")
  debug_assert(c_abs(7) == 7 && c_abs(-2147483647) == 2147483647, "abs")
  debug_assert(crc32_of("") == 0L, "crc32 of empty")
  debug_assert(hex32(crc32_of(FOX)) == "414fa339", "crc32 fox")
  debug_assert(hex32(255L) == "000000ff", "hex padding")
}
