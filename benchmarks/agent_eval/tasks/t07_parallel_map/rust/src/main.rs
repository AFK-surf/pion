//! t07_parallel_map: Collatz map/reduce over std::thread::scope + mpsc
use std::sync::mpsc;
use std::thread;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Partial {
    pub sum: u64,
    pub best_n: u64,
    pub best_steps: i64,
}

pub fn steps(n: u64) -> i64 {
    let (mut x, mut k) = (n, 0);
    while x != 1 {
        x = if x % 2 == 0 { x / 2 } else { 3 * x + 1 };
        k += 1;
    }
    k
}

/// Map + reduce over the inclusive range [lo, hi].
pub fn chunk(lo: u64, hi: u64) -> Partial {
    let mut acc = Partial { sum: 0, best_n: 0, best_steps: -1 };
    for n in lo..=hi {
        let k = steps(n);
        acc.sum += k as u64;
        if k > acc.best_steps {
            acc.best_steps = k;
            acc.best_n = n;
        }
    }
    acc
}

pub fn merge(a: Partial, b: Partial) -> Partial {
    let take_b = b.best_steps > a.best_steps || (b.best_steps == a.best_steps && b.best_n < a.best_n);
    let best = if take_b { b } else { a };
    Partial { sum: a.sum + b.sum, best_n: best.best_n, best_steps: best.best_steps }
}

pub fn parallel(n: u64, workers: u64) -> Partial {
    let (tx, rx) = mpsc::channel();
    let size = n / workers;
    thread::scope(|s| {
        for w in 0..workers {
            let tx = tx.clone();
            let lo = w * size + 1;
            let hi = if w == workers - 1 { n } else { (w + 1) * size };
            s.spawn(move || tx.send(chunk(lo, hi)).unwrap());
        }
    });
    drop(tx);
    rx.iter().fold(Partial { sum: 0, best_n: 0, best_steps: -1 }, merge)
}

fn main() {
    let n = 100_000;
    let par = parallel(n, 4);
    let seq = chunk(1, n);
    println!("n={} chunks=4", n);
    println!("total_steps={}", par.sum);
    println!("longest={} steps={}", par.best_n, par.best_steps);
    println!("parallel_matches_sequential={}", par == seq);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_known() {
        assert_eq!(steps(1), 0);
        assert_eq!(steps(6), 8);
        assert_eq!(steps(27), 111);
        assert_eq!(steps(77031), 350);
    }

    #[test]
    fn merge_tie_break_and_chunking() {
        let a = Partial { sum: 10, best_n: 9, best_steps: 19 };
        let b = Partial { sum: 5, best_n: 7, best_steps: 19 };
        assert_eq!(merge(a, b).best_n, 7);
        assert_eq!(merge(b, a).best_n, 7);
        assert_eq!(merge(a, b).sum, 15);
        let split = merge(merge(chunk(1, 300), chunk(301, 700)), chunk(701, 1000));
        assert_eq!(split, chunk(1, 1000));
    }

    #[test]
    fn parallel_equals_sequential() {
        assert_eq!(parallel(5000, 4), chunk(1, 5000));
    }
}
