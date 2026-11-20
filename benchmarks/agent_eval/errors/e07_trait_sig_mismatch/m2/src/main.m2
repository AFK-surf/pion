pub trait Area {
  area(self : Self) -> Int
}

pub struct Sq {
  side : Int
}

impl Area for Sq {
  fn area(self : Sq) -> String {
    (self.side * self.side).to_string()
  }
}

fn total[T : Area](x : T) -> Int {
  x.area()
}

pub fn main(world : World) -> Int {
  io_println(world, total(Sq::{ side: 3 }).to_string())
  0
}
