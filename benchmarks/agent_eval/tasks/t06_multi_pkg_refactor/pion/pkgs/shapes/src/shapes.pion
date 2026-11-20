///| shapes: geometry primitives (leaf package)

pub enum Shape {
  Rect(Int, Int)
  Square(Int)
  RightTri(Int, Int)
}

fn unit_scale() -> Int {
  let unit = 1 // AE_EDIT_BODY
  unit
}

/// Twice the area (keeps right triangles integral).
pub fn area2(s : Shape) -> Int {
  let k = unit_scale()
  match s {
    Rect(w, h) => 2 * w * h * k
    Square(a) => 2 * a * a * k
    RightTri(b, h) => b * h * k
  }
}

pub fn kind_name(s : Shape) -> String {
  match s {
    Rect(_, _) => "rect"
    Square(_) => "square"
    RightTri(_, _) => "tri"
  }
}

pub fn ae_probe_a() -> Int { 1 } // AE_EDIT_IFACE

test "area2" {
  debug_assert(area2(Rect(4, 3)) == 24, "rect")
  debug_assert(area2(Square(2)) == 8, "square")
  debug_assert(area2(RightTri(3, 4)) == 12, "tri")
  debug_assert(kind_name(RightTri(1, 1)) == "tri", "kind")
}
