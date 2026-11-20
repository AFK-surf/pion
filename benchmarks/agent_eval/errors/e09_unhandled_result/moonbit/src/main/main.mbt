///|
suberror SaveError {
  Negative
}

///| Idiomatic MoonBit fallible function: a checked `raise` effect.
fn save(x : Int) -> Unit raise SaveError {
  if x < 0 {
    raise Negative
  }
}

///|
fn main {
  save(-1)
  println("saved")
}
