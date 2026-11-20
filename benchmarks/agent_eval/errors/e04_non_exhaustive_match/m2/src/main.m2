pub enum Color {
  Red
  Green
  Blue
}

fn hex(c : Color) -> String {
  match c {
    Red => "#f00"
    Green => "#0f0"
  }
}

pub fn main(world : World) -> Int {
  io_println(world, hex(Blue))
  0
}
