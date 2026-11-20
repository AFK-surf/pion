///| t08_concurrent_counter.
///| MoonBit has no shared-memory threads: the four producers run one after
///| another into one mutable aggregate (single-threaded baseline, no locks).

///|
struct Stats {
  mut info : Int
  mut warn : Int
  mut error : Int
  mut debug : Int
  mut lat_sum : Int
} derive(Eq, Debug)

///|
fn Stats::new() -> Stats {
  { info: 0, warn: 0, error: 0, debug: 0, lat_sum: 0 }
}

///|
fn Stats::record(self : Stats, r : Int, lat : Int) -> Unit {
  match r {
    0..=5 => self.info += 1
    6 | 7 => self.warn += 1
    8 => self.error += 1
    _ => self.debug += 1
  }
  self.lat_sum += lat
}

///|
fn Stats::total(self : Stats) -> Int {
  self.info + self.warn + self.error + self.debug
}

///|
fn level_of(p : Int, j : Int) -> Int {
  (7 * j + 3 * p) % 10
}

///|
fn latency_of(p : Int, j : Int) -> Int {
  (1000 * p + j) % 97
}

///|
fn sequential(producers : Int, per : Int) -> Stats {
  let s = Stats::new()
  for p in 0..<producers {
    for j in 0..<per {
      s.record(level_of(p, j), latency_of(p, j))
    }
  }
  s
}

///| "Producers" as sequential tasks feeding a shared aggregate and a counter.
fn producers_serial(producers : Int, per : Int) -> (Stats, Int) {
  let shared = Stats::new()
  let mut events = 0
  let tasks : Array[() -> Unit] = []
  for p in 0..<producers {
    tasks.push(fn() {
      for j in 0..<per {
        shared.record(level_of(p, j), latency_of(p, j))
        events += 1
      }
    })
  }
  for t in tasks {
    t()
  }
  (shared, events)
}

///|
fn main {
  let (s, n) = producers_serial(4, 25000)
  let seq = sequential(4, 25000)
  println("producers=4 events=\{seq.total()}")
  println("info=\{s.info} warn=\{s.warn} error=\{s.error} debug=\{s.debug}")
  println("latency_sum=\{s.lat_sum}")
  println("atomic_total=\{n} mutex_total=\{s.total()}")
  println("consistent=\{s == seq && n == seq.total()}")
}

///|
test "levels" {
  assert_true(level_of(0, 0) == 0 && level_of(1, 1) == 0 && level_of(0, 3) == 1)
  let s = Stats::new()
  s.record(9, 5)
  s.record(6, 7)
  assert_eq((s.debug, s.warn, s.lat_sum), (1, 1, 12))
}

///|
test "sequential distribution" {
  let s = sequential(4, 25000)
  assert_eq((s.info, s.warn, s.error, s.debug), (60000, 20000, 10000, 10000))
  assert_eq(s.total(), 100000)
}

///|
test "serial producers match" {
  let (s, n) = producers_serial(4, 2000)
  assert_eq(s, sequential(4, 2000))
  assert_eq(n, 8000)
}
