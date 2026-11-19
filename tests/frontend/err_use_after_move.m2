pub fn reuse_after_move() -> Int {
  let xs : Array[Int] = [1, 2, 3]
  let ys = move xs
  let _ = ys.length()
  xs.length()
}
