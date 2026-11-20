///| inventory: parts lists over shapes
import "shapes"

pub struct Part {
  name : String
  shape : shapes::Shape
  qty : Int
}

pub fn part(name : String, shape : shapes::Shape, qty : Int) -> Part {
  Part::{ name: name, shape: shape, qty: qty }
}

pub fn total_area2(parts : Array[Part]) -> Int {
  let mut sum = 0
  for p in parts {
    sum = sum + shapes::area2(p.shape) * p.qty
  }
  sum
}

/// First part with the maximal single-piece area.
pub fn largest(parts : Array[Part]) -> Option[String] {
  let mut best = -1
  let mut name = ""
  for p in parts {
    let a = shapes::area2(p.shape)
    if a > best {
      best = a
      name = p.name
    }
  }
  if best < 0 {
    None
  } else {
    Some(name)
  }
}

pub fn qty_by_kind(parts : Array[Part]) -> Array[String] {
  let totals : Map[String, Int] = Map::new()
  for p in parts {
    let k = shapes::kind_name(p.shape)
    let cur = match totals.get(k) {
      Some(n) => n
      None => 0
    }
    totals.set(k, cur + p.qty)
  }
  let kinds = totals.keys()
  kinds.sort()
  let out : Array[String] = []
  for k in kinds {
    match totals.get(k) {
      Some(n) => out.push("kind \{k} qty=\{n}")
      None => ()
    }
  }
  out
}

test "totals" {
  let ps = [part("a", shapes::Square(1), 3), part("b", shapes::Rect(1, 2), 1)]
  debug_assert(total_area2(ps) == 10, "total")
  debug_assert(qty_by_kind(ps).join("|") == "kind rect qty=1|kind square qty=3", "kinds")
  match largest(ps) {
    Some(n) => { debug_assert(n == "b", "largest") }
    None => { debug_assert(false, "largest missing") }
  }
}
