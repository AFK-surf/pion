pub trait Describe {
  describe(self : Self) -> String
}

pub struct Point {
  x : Int
  y : Int
}

impl Describe for Int {
  fn describe(self : Int) -> String {
    "int " + self.to_string()
  }
}

fn show_all[T : Describe](x : T) -> String {
  x.describe()
}

pub fn main(world : World) -> Int {
  io_println(world, show_all(1))
  io_println(world, show_all(Point::{ x: 1, y: 2 }))
  0
}
