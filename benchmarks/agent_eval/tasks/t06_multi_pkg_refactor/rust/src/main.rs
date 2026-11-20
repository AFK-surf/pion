//! app: report over an inventory
use inventory::{largest, part, qty_by_kind, total_area2, Part};
use shapes::{area2, kind_name, Shape};

pub fn parts() -> Vec<Part> {
    vec![
        part("panel", Shape::Rect(4, 3), 2),
        part("tile", Shape::Square(2), 10),
        part("brace", Shape::RightTri(3, 4), 4),
        part("door", Shape::Rect(2, 7), 1),
    ]
}

pub fn report(ps: &[Part]) -> Vec<String> {
    let mut out: Vec<String> = ps
        .iter()
        .map(|p| format!("{} {} area2={} qty={}", p.name, kind_name(p.shape), area2(p.shape), p.qty))
        .collect();
    out.push(format!("total_area2={}", total_area2(ps)));
    out.push(format!("largest={}", largest(ps).unwrap_or("none")));
    out.extend(qty_by_kind(ps));
    out
}

fn main() {
    for line in report(&parts()) {
        println!("{}", line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_lines() {
        let lines = report(&parts());
        assert_eq!(lines.len(), 9);
        assert_eq!(lines[4], "total_area2=204");
        assert_eq!(lines[5], "largest=door");
    }
}
