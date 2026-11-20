///| inventory: parts lists over shapes

///|
pub(all) struct Part {
  name : String
  shape : @shapes.Shape
  qty : Int
}

///|
pub fn part(name : String, shape : @shapes.Shape, qty : Int) -> Part {
  { name, shape, qty }
}

///|
pub fn total_area2(parts : Array[Part]) -> Int {
  parts.fold(init=0, fn(acc, p) { acc + @shapes.area2(p.shape) * p.qty })
}

///| First part with the maximal single-piece area.
pub fn largest(parts : Array[Part]) -> String? {
  let mut best : (String, Int)? = None
  for p in parts {
    let a = @shapes.area2(p.shape)
    match best {
      Some((_, b)) if a <= b => ()
      _ => best = Some((p.name, a))
    }
  }
  best.map(fn(t) { t.0 })
}

///| Byte-order comparison.
fn byte_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let d = a.code_unit_at(i).to_int() - b.code_unit_at(i).to_int()
    if d != 0 {
      return d
    }
  }
  a.length() - b.length()
}

///|
pub fn qty_by_kind(parts : Array[Part]) -> Array[String] {
  let totals : Map[String, Int] = Map([])
  for p in parts {
    let k = @shapes.kind_name(p.shape)
    totals[k] = totals.get(k).unwrap_or(0) + p.qty
  }
  // `String::compare` (and `Bytes::compare`) order by length first: sort by bytes.
  let kinds = totals.keys().to_array()
  kinds.sort_by(byte_compare)
  kinds.map(fn(k) { "kind \{k} qty=\{totals[k]}" })
}

///|
test "totals" {
  let ps = [part("a", Square(1), 3), part("b", Rect(1, 2), 1)]
  assert_eq(total_area2(ps), 10)
  assert_eq(qty_by_kind(ps).join("|"), "kind rect qty=1|kind square qty=3")
  assert_eq(largest(ps), Some("b"))
}
