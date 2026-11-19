pub fn race(world : World) -> Unit {
  let mut counter = 0
  scope(world, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let _ = counter
    })
  })
}
