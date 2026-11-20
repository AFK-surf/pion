pub fn main(world : World) -> Int {
  let hits : Array[Int] = []
  scope(world, fn(s : Scope) -> Unit {
    for w in 0..4 {
      spawn(s, fn() -> Unit {
        hits.push(w)
      })
    }
  })
  io_println(world, hits.length().to_string())
  0
}
