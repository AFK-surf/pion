///| t07_parallel_map: Collatz map/reduce.
///| MoonBit has no shared-memory threads: the four chunks run sequentially
///| (single-threaded baseline with the same chunk/merge structure).

///|
struct Partial {
  sum : Int64
  best_n : Int
  best_steps : Int
} derive(Eq, Debug)

///|
fn steps(n : Int) -> Int {
  let mut x = n.to_int64()
  let mut k = 0
  while x != 1L {
    x = if x % 2L == 0L { x / 2L } else { 3L * x + 1L }
    k += 1
  }
  k
}

///| Map + reduce over the inclusive range [lo, hi].
fn chunk(lo : Int, hi : Int) -> Partial {
  let mut sum = 0L
  let mut best_n = 0
  let mut best_steps = -1
  for n in lo..=hi {
    let k = steps(n)
    sum += k.to_int64()
    if k > best_steps {
      best_steps = k
      best_n = n
    }
  }
  { sum, best_n, best_steps }
}

///|
fn merge(a : Partial, b : Partial) -> Partial {
  let take_b = b.best_steps > a.best_steps ||
    (b.best_steps == a.best_steps && b.best_n < a.best_n)
  let best = if take_b { b } else { a }
  { sum: a.sum + b.sum, best_n: best.best_n, best_steps: best.best_steps }
}

///| Same partitioning as the threaded versions, evaluated one chunk after another.
fn chunked(n : Int, chunks : Int) -> Partial {
  let size = n / chunks
  let mut acc = { sum: 0L, best_n: 0, best_steps: -1 }
  for w in 0..<chunks {
    let hi = if w == chunks - 1 { n } else { (w + 1) * size }
    acc = merge(acc, chunk(w * size + 1, hi))
  }
  acc
}

///|
fn main {
  let n = 100000
  let par = chunked(n, 4)
  let seq = chunk(1, n)
  println("n=\{n} chunks=4")
  println("total_steps=\{par.sum}")
  println("longest=\{par.best_n} steps=\{par.best_steps}")
  println("parallel_matches_sequential=\{par == seq}")
}

///|
test "steps" {
  assert_eq(steps(1), 0)
  assert_eq(steps(6), 8)
  assert_eq(steps(27), 111)
  assert_eq(steps(77031), 350)
}

///|
test "merge tie break and chunking" {
  let a = { sum: 10L, best_n: 9, best_steps: 19 }
  let b = { sum: 5L, best_n: 7, best_steps: 19 }
  assert_eq(merge(a, b).best_n, 7)
  assert_eq(merge(b, a).best_n, 7)
  assert_eq(merge(a, b).sum, 15L)
  assert_eq(merge(merge(chunk(1, 300), chunk(301, 700)), chunk(701, 1000)), chunk(1, 1000))
}

///|
test "chunked equals sequential" {
  assert_eq(chunked(5000, 4), chunk(1, 5000))
}
