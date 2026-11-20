///|
trait Describe {
  describe(Self) -> String
}

///|
struct Point {
  x : Int
  y : Int
}

///|
impl Describe for Int with describe(self) {
  "int \{self}"
}

///|
fn[T : Describe] show_all(x : T) -> String {
  Describe::describe(x)
}

///|
fn main {
  println(show_all(1))
  let p : Point = { x: 1, y: 2 }
  println(show_all(p))
}
