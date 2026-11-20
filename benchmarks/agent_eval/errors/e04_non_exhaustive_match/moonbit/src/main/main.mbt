///|
enum Color {
  Red
  Green
  Blue
}

///|
fn hex(c : Color) -> String {
  match c {
    Red => "#f00"
    Green => "#0f0"
  }
}

///|
fn main {
  println(hex(Blue))
}
