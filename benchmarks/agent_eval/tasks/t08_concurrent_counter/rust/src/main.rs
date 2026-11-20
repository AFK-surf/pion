//! t08_concurrent_counter: Mutex<Stats> + AtomicU64 across producer threads
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::thread;

#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Stats {
    pub info: u64,
    pub warn: u64,
    pub error: u64,
    pub debug: u64,
    pub lat_sum: u64,
}

impl Stats {
    pub fn record(&mut self, r: u64, lat: u64) {
        match r {
            0..=5 => self.info += 1,
            6 | 7 => self.warn += 1,
            8 => self.error += 1,
            _ => self.debug += 1,
        }
        self.lat_sum += lat;
    }
    pub fn total(&self) -> u64 {
        self.info + self.warn + self.error + self.debug
    }
}

pub fn level_of(p: u64, j: u64) -> u64 {
    (7 * j + 3 * p) % 10
}

pub fn latency_of(p: u64, j: u64) -> u64 {
    (1000 * p + j) % 97
}

pub fn sequential(producers: u64, per: u64) -> Stats {
    let mut s = Stats::default();
    for p in 0..producers {
        for j in 0..per {
            s.record(level_of(p, j), latency_of(p, j));
        }
    }
    s
}

pub fn concurrent(producers: u64, per: u64) -> (Stats, u64) {
    let shared = Mutex::new(Stats::default());
    let events = AtomicU64::new(0);
    thread::scope(|sc| {
        for p in 0..producers {
            let (shared, events) = (&shared, &events);
            sc.spawn(move || {
                for j in 0..per {
                    shared.lock().unwrap().record(level_of(p, j), latency_of(p, j));
                    events.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    (shared.into_inner().unwrap(), events.load(Ordering::SeqCst))
}

fn main() {
    let (s, n) = concurrent(4, 25_000);
    let seq = sequential(4, 25_000);
    println!("producers=4 events={}", seq.total());
    println!("info={} warn={} error={} debug={}", s.info, s.warn, s.error, s.debug);
    println!("latency_sum={}", s.lat_sum);
    println!("atomic_total={} mutex_total={}", n, s.total());
    println!("consistent={}", s == seq && n == seq.total());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels() {
        assert!(level_of(0, 0) == 0 && level_of(1, 1) == 0 && level_of(0, 3) == 1);
        let mut s = Stats::default();
        s.record(9, 5);
        s.record(6, 7);
        assert_eq!((s.debug, s.warn, s.lat_sum), (1, 1, 12));
    }

    #[test]
    fn sequential_distribution() {
        let s = sequential(4, 25_000);
        assert_eq!((s.info, s.warn, s.error, s.debug), (60_000, 20_000, 10_000, 10_000));
        assert_eq!(s.total(), 100_000);
    }

    #[test]
    fn concurrent_matches() {
        let (s, n) = concurrent(4, 2_000);
        assert_eq!(s, sequential(4, 2_000));
        assert_eq!(n, 8_000);
    }
}
