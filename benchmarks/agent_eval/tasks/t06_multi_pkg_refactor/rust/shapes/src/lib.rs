//! shapes: geometry primitives (leaf crate)

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Shape {
    Rect(i64, i64),
    Square(i64),
    RightTri(i64, i64),
}

fn unit_scale() -> i64 {
    let unit = 1; // AE_EDIT_BODY
    unit
}

/// Twice the area (keeps right triangles integral).
pub fn area2(s: Shape) -> i64 {
    let k = unit_scale();
    match s {
        Shape::Rect(w, h) => 2 * w * h * k,
        Shape::Square(a) => 2 * a * a * k,
        Shape::RightTri(b, h) => b * h * k,
    }
}

pub fn kind_name(s: Shape) -> &'static str {
    match s {
        Shape::Rect(..) => "rect",
        Shape::Square(_) => "square",
        Shape::RightTri(..) => "tri",
    }
}

pub fn ae_probe_a() -> i64 { 1 } // AE_EDIT_IFACE

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn area2_cases() {
        assert_eq!(area2(Shape::Rect(4, 3)), 24);
        assert_eq!(area2(Shape::Square(2)), 8);
        assert_eq!(area2(Shape::RightTri(3, 4)), 12);
        assert_eq!(kind_name(Shape::RightTri(1, 1)), "tri");
    }
}
