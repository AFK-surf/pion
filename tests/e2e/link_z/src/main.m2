///| Links against libz (`[link] libs = ["z"]` or `-lz`) and prints its version.

extern "C" fn zlib_version() -> Ptr = "zlibVersion"

pub fn main(world : World) -> Int {
  let v = cstr_to_str(zlib_version())
  if v.length() == 0 || !v.contains(".") {
    return 1
  }
  io_println(world, "zlib " + v)
  0
}
