//! inventory: parts lists over shapes
use shapes::{area2, kind_name, Shape};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct Part {
    pub name: String,
    pub shape: Shape,
    pub qty: i64,
}

pub fn part(name: &str, shape: Shape, qty: i64) -> Part {
    Part { name: name.to_string(), shape, qty }
}

pub fn total_area2(parts: &[Part]) -> i64 {
    parts.iter().map(|p| area2(p.shape) * p.qty).sum()
}

/// First part with the maximal single-piece area.
pub fn largest(parts: &[Part]) -> Option<&str> {
    let mut best: Option<(&str, i64)> = None;
    for p in parts {
        let a = area2(p.shape);
        if best.map_or(true, |(_, b)| a > b) {
            best = Some((&p.name, a));
        }
    }
    best.map(|(n, _)| n)
}

pub fn qty_by_kind(parts: &[Part]) -> Vec<String> {
    let mut totals: BTreeMap<&str, i64> = BTreeMap::new();
    for p in parts {
        *totals.entry(kind_name(p.shape)).or_insert(0) += p.qty;
    }
    totals.into_iter().map(|(k, n)| format!("kind {} qty={}", k, n)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totals() {
        let ps = vec![part("a", Shape::Square(1), 3), part("b", Shape::Rect(1, 2), 1)];
        assert_eq!(total_area2(&ps), 10);
        assert_eq!(qty_by_kind(&ps).join("|"), "kind rect qty=1|kind square qty=3");
        assert_eq!(largest(&ps), Some("b"));
    }
}
