///| No capability system: any function may perform IO. The closest IO in the
///| standard library is printing; the helper prints as a hidden side effect.
fn load_config(path : String) -> String {
  println("reading \{path}")
  path
}

///|
fn main {
  println(load_config("/etc/hosts"))
}
