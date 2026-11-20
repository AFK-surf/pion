///| t08_concurrent_counter: Mutex[val struct] + AtomicInt across producer threads

pub val struct Stats {
  info : Int
  warn : Int
  error : Int
  debug : Int
  lat_sum : Int
}

pub fn zero_stats() -> Stats {
  Stats::{ info: 0, warn: 0, error: 0, debug: 0, lat_sum: 0 }
}

pub fn level_of(p : Int, j : Int) -> Int {
  (7 * j + 3 * p) % 10
}

pub fn latency_of(p : Int, j : Int) -> Int {
  (1000 * p + j) % 97
}

pub fn record(s : Stats, r : Int, lat : Int) -> Stats {
  Stats::{
    info: if r <= 5 { s.info + 1 } else { s.info },
    warn: if r == 6 || r == 7 { s.warn + 1 } else { s.warn },
    error: if r == 8 { s.error + 1 } else { s.error },
    debug: if r == 9 { s.debug + 1 } else { s.debug },
    lat_sum: s.lat_sum + lat,
  }
}

pub fn total(s : Stats) -> Int {
  s.info + s.warn + s.error + s.debug
}

pub fn sequential(producers : Int, per : Int) -> Stats {
  let mut s = zero_stats()
  for p in 0..producers {
    for j in 0..per {
      s = record(s, level_of(p, j), latency_of(p, j))
    }
  }
  s
}

/// Returns (shared stats, atomic event count).
pub fn concurrent(world : World, producers : Int, per : Int) -> (Stats, Int) {
  let shared : Mutex[Stats] = Mutex::new(zero_stats())
  let events = AtomicInt::new(0)
  scope(world, fn(sc : Scope) -> Unit {
    for p in 0..producers {
      spawn(sc, fn() -> Unit {
        for j in 0..per {
          let cur = shared.lock()
          shared.set(record(cur, level_of(p, j), latency_of(p, j)))
          shared.unlock()
          let _ = events.fetch_add(1)
        }
      })
    }
  })
  let fin = shared.lock()
  shared.unlock()
  (fin, events.load())
}

pub fn main(world : World) -> Int {
  let (s, n) = concurrent(world, 4, 25000)
  let seq = sequential(4, 25000)
  let same = s.info == seq.info && s.warn == seq.warn && s.error == seq.error && s.debug == seq.debug &&
    s.lat_sum == seq.lat_sum && n == total(seq)
  io_println(world, "producers=4 events=" + total(seq).to_string())
  io_println(world, "info=\{s.info} warn=\{s.warn} error=\{s.error} debug=\{s.debug}")
  io_println(world, "latency_sum=\{s.lat_sum}")
  io_println(world, "atomic_total=\{n} mutex_total=" + total(s).to_string())
  io_println(world, "consistent=\{same}")
  0
}

test "levels" {
  debug_assert(level_of(0, 0) == 0 && level_of(1, 1) == 0 && level_of(0, 3) == 1, "level formula")
  let s = record(record(zero_stats(), 9, 5), 6, 7)
  debug_assert(s.debug == 1 && s.warn == 1 && s.lat_sum == 12, "record")
}

test "sequential distribution" {
  let s = sequential(4, 25000)
  debug_assert(s.info == 60000 && s.warn == 20000 && s.error == 10000 && s.debug == 10000, "counts")
  debug_assert(total(s) == 100000, "total")
}
