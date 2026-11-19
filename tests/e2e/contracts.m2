///| Contract test: debug_assert aborts in dev build, stripped to 0 bytes in --release
pub fn main(world : World) -> Int {
  debug_assert(1 == 2, "dev contract triggered")
  io_println(world, "release ok")
  0
}
