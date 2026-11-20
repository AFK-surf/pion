///| MoonBit has no shared-memory threads, so this bug class cannot be written:
///| the closest program runs the four "workers" sequentially and is race-free.

///|
fn main {
  let hits : Array[Int] = []
  let workers : Array[() -> Unit] = []
  for w in 0..<4 {
    workers.push(fn() { hits.push(w) })
  }
  for f in workers {
    f()
  }
  println(hits.length())
}
