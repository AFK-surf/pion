///| app: report over an inventory

///|
fn parts() -> Array[@inv.Part] {
  [
    @inv.part("panel", Rect(4, 3), 2),
    @inv.part("tile", Square(2), 10),
    @inv.part("brace", RightTri(3, 4), 4),
    @inv.part("door", Rect(2, 7), 1),
  ]
}

///|
fn report(ps : Array[@inv.Part]) -> Array[String] {
  let out = ps.map(fn(p) {
    "\{p.name} \{@shapes.kind_name(p.shape)} area2=\{@shapes.area2(p.shape)} qty=\{p.qty}"
  })
  out.push("total_area2=\{@inv.total_area2(ps)}")
  out.push("largest=\{@inv.largest(ps).unwrap_or("none")}")
  out.append(@inv.qty_by_kind(ps))
  out
}

///|
fn main {
  for line in report(parts()) {
    println(line)
  }
}

///|
test "report" {
  let lines = report(parts())
  assert_eq(lines.length(), 9)
  assert_eq(lines[4], "total_area2=204")
  assert_eq(lines[5], "largest=door")
}
