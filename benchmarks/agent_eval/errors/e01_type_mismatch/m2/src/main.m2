fn label(n : Int) -> Int {
  "n=" + n.to_string()
}

pub fn main(world : World) -> Int {
  io_println(world, label(3).to_string())
  0
}
