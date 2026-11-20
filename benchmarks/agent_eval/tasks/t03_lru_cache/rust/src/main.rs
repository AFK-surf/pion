//! t03_lru_cache: O(1) LRU with a hash map + index-linked recency list
use std::collections::HashMap;

const NIL: usize = usize::MAX;

struct Node {
    key: String,
    val: i64,
    prev: usize,
    next: usize,
}

pub struct Lru {
    cap: usize,
    index: HashMap<String, usize>,
    nodes: Vec<Node>,
    head: usize,
    tail: usize,
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
}

impl Lru {
    pub fn new(cap: usize) -> Self {
        Lru { cap, index: HashMap::new(), nodes: Vec::new(), head: NIL, tail: NIL, hits: 0, misses: 0, evictions: 0 }
    }

    fn unlink(&mut self, i: usize) {
        let (p, n) = (self.nodes[i].prev, self.nodes[i].next);
        if p != NIL { self.nodes[p].next = n } else { self.head = n }
        if n != NIL { self.nodes[n].prev = p } else { self.tail = p }
    }

    fn push_front(&mut self, i: usize) {
        self.nodes[i].prev = NIL;
        self.nodes[i].next = self.head;
        if self.head != NIL {
            self.nodes[self.head].prev = i;
        }
        self.head = i;
        if self.tail == NIL {
            self.tail = i;
        }
    }

    pub fn get(&mut self, key: &str) -> Option<i64> {
        match self.index.get(key).copied() {
            Some(i) => {
                self.hits += 1;
                self.unlink(i);
                self.push_front(i);
                Some(self.nodes[i].val)
            }
            None => {
                self.misses += 1;
                None
            }
        }
    }

    pub fn put(&mut self, key: &str, val: i64) -> Option<String> {
        if let Some(&i) = self.index.get(key) {
            self.nodes[i].val = val;
            self.unlink(i);
            self.push_front(i);
            return None;
        }
        if self.nodes.len() < self.cap {
            self.nodes.push(Node { key: key.to_string(), val, prev: NIL, next: NIL });
            let i = self.nodes.len() - 1;
            self.index.insert(key.to_string(), i);
            self.push_front(i);
            return None;
        }
        let victim = self.tail;
        self.unlink(victim);
        let old = std::mem::replace(&mut self.nodes[victim].key, key.to_string());
        self.index.remove(&old);
        self.nodes[victim].val = val;
        self.index.insert(key.to_string(), victim);
        self.push_front(victim);
        self.evictions += 1;
        Some(old)
    }

    pub fn order(&self) -> Vec<String> {
        let mut out = Vec::new();
        let mut i = self.head;
        while i != NIL {
            out.push(self.nodes[i].key.clone());
            i = self.nodes[i].next;
        }
        out
    }
}

pub fn run_script() -> Vec<String> {
    let mut c = Lru::new(3);
    let mut out = Vec::new();
    let mut put = |c: &mut Lru, k: &str, v: i64, out: &mut Vec<String>| {
        if let Some(old) = c.put(k, v) {
            out.push(format!("evict {}", old));
        }
    };
    let get = |c: &mut Lru, k: &str, out: &mut Vec<String>| match c.get(k) {
        Some(v) => out.push(format!("get {} = {}", k, v)),
        None => out.push(format!("get {} = miss", k)),
    };
    put(&mut c, "a", 1, &mut out);
    put(&mut c, "b", 2, &mut out);
    put(&mut c, "c", 3, &mut out);
    get(&mut c, "a", &mut out);
    put(&mut c, "d", 4, &mut out);
    get(&mut c, "b", &mut out);
    put(&mut c, "c", 30, &mut out);
    put(&mut c, "e", 5, &mut out);
    get(&mut c, "a", &mut out);
    get(&mut c, "c", &mut out);
    get(&mut c, "d", &mut out);
    get(&mut c, "e", &mut out);
    out.push(format!(
        "order={} hits={} misses={} evictions={}",
        c.order().join(","),
        c.hits,
        c.misses,
        c.evictions
    ));
    out
}

fn main() {
    for line in run_script() {
        println!("{}", line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_promotes_without_eviction() {
        let mut c = Lru::new(2);
        c.put("x", 1);
        c.put("y", 2);
        c.put("x", 10);
        assert_eq!(c.put("z", 3), Some("y".to_string()));
        assert_eq!(c.get("x"), Some(10));
        assert_eq!(c.order().join(","), "x,z");
    }

    #[test]
    fn capacity_one() {
        let mut c = Lru::new(1);
        c.put("a", 1);
        assert_eq!(c.put("b", 2), Some("a".to_string()));
        assert_eq!(c.get("a"), None);
        assert_eq!((c.evictions, c.misses), (1, 1));
    }

    #[test]
    fn script() {
        let lines = run_script();
        assert_eq!(lines.len(), 9);
        assert_eq!(lines[8], "order=e,d,c hits=4 misses=2 evictions=2");
    }
}
