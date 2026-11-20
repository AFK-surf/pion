//! t10_graph_topo: Kahn's algorithm, smallest-first, cycle detection
use std::cmp::Reverse;
use std::collections::{BTreeSet, BinaryHeap, HashMap, HashSet};

#[derive(Debug, PartialEq)]
pub struct Topo {
    pub order: Vec<String>,
    pub blocked: Vec<String>,
}

pub const GRAPH1: &str = "shirt -> tie\ntie -> jacket\npants -> shoes\npants -> belt\nbelt -> jacket\nshirt -> belt\nsocks -> shoes\nundershorts -> pants\nundershorts -> shoes\nwatch\n";
pub const GRAPH2: &str = "a -> b\nb -> c\nc -> a\nc -> d\ne -> d\n";
pub const GRAPH3: &str = "a -> b\nb ->\n";

pub fn toposort(text: &str) -> Result<Topo, String> {
    let mut ids: HashMap<&str, usize> = HashMap::new();
    let mut names: Vec<&str> = Vec::new();
    let mut adj: Vec<Vec<usize>> = Vec::new();
    let mut indeg: Vec<usize> = Vec::new();
    let mut seen: HashSet<(usize, usize)> = HashSet::new();
    for (ln, raw) in text.split('\n').enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let mut intern = |name| {
            *ids.entry(name).or_insert_with(|| {
                names.push(name);
                adj.push(Vec::new());
                indeg.push(0);
                names.len() - 1
            })
        };
        match line.split_once("->") {
            None => {
                intern(line);
            }
            Some((u, v)) => {
                let (u, v) = (u.trim(), v.trim());
                if u.is_empty() || v.is_empty() {
                    return Err(format!("line {}: malformed edge '{}'", ln + 1, line));
                }
                let (a, b) = (intern(u), intern(v));
                if seen.insert((a, b)) {
                    adj[a].push(b);
                    indeg[b] += 1;
                }
            }
        }
    }
    let mut ready: BinaryHeap<Reverse<(&str, usize)>> =
        (0..names.len()).filter(|&i| indeg[i] == 0).map(|i| Reverse((names[i], i))).collect();
    let mut order = Vec::new();
    while let Some(Reverse((name, n))) = ready.pop() {
        order.push(name.to_string());
        for &m in &adj[n] {
            indeg[m] -= 1;
            if indeg[m] == 0 {
                ready.push(Reverse((names[m], m)));
            }
        }
    }
    let blocked: BTreeSet<&str> = (0..names.len()).filter(|&i| indeg[i] > 0).map(|i| names[i]).collect();
    Ok(Topo { order, blocked: blocked.into_iter().map(String::from).collect() })
}

pub fn describe(label: &str, text: &str) -> String {
    match toposort(text) {
        Err(e) => format!("{} error: {}", label, e),
        Ok(t) if t.blocked.is_empty() => format!("{} order: {}", label, t.order.join(" ")),
        Ok(t) => format!("{} cycle: ordered={} blocked={}", label, t.order.join(","), t.blocked.join(",")),
    }
}

fn main() {
    println!("{}", describe("graph1", GRAPH1));
    println!("{}", describe("graph2", GRAPH2));
    println!("{}", describe("graph3", GRAPH3));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicates_and_self_loops() {
        assert_eq!(describe("g", "b -> a\nb -> a\nc"), "g order: b a c");
        assert_eq!(describe("g", "x -> x\ny"), "g cycle: ordered=y blocked=x");
        assert_eq!(describe("g", ""), "g order: ");
    }

    #[test]
    fn errors() {
        assert_eq!(describe("g", "\n -> b"), "g error: line 2: malformed edge '-> b'");
    }
}
