///|
trait Area {
  area(Self) -> Int
}

///|
struct Sq {
  side : Int
}

///|
impl Area for Sq with area(self) -> String {
  (self.side * self.side).to_string()
}

///|
fn[T : Area] total(x : T) -> Int {
  Area::area(x)
}

///|
fn main {
  let s : Sq = { side: 3 }
  println(total(s))
}
