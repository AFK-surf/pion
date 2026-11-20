///| app: report over an inventory
import "shapes"
import "inventory" as inv

pub fn parts() -> Array[inv::Part] {
  [
    inv::part("panel", shapes::Rect(4, 3), 2),
    inv::part("tile", shapes::Square(2), 10),
    inv::part("brace", shapes::RightTri(3, 4), 4),
    inv::part("door", shapes::Rect(2, 7), 1),
  ]
}

pub fn report(ps : Array[inv::Part]) -> Array[String] {
  let out : Array[String] = []
  for p in ps {
    out.push(p.name + " " + shapes::kind_name(p.shape) + " area2=" + shapes::area2(p.shape).to_string() + " qty=" + p.qty.to_string())
  }
  out.push("total_area2=" + inv::total_area2(ps).to_string())
  match inv::largest(ps) {
    Some(n) => out.push("largest=" + n)
    None => out.push("largest=none")
  }
  for line in inv::qty_by_kind(ps) {
    out.push(line)
  }
  out
}

pub fn main(world : World) -> Int {
  for line in report(parts()) {
    io_println(world, line)
  }
  0
}

test "report" {
  let lines = report(parts())
  debug_assert(lines.length() == 9, "nine lines")
  debug_assert(lines[4] == "total_area2=204", "total")
  debug_assert(lines[5] == "largest=door", "largest")
}
