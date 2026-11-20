///| t07_parallel_map: Collatz map/reduce over scope/spawn/Channel

pub val struct Partial {
  sum : Int64
  best_n : Int
  best_steps : Int
}

pub fn steps(n : Int) -> Int {
  let mut x = n.to_int64()
  let mut k = 0
  while x != 1L {
    if x % 2L == 0L {
      x = x / 2L
    } else {
      x = 3L * x + 1L
    }
    k = k + 1
  }
  k
}

/// Map + reduce over the inclusive range [lo, hi].
pub fn chunk(lo : Int, hi : Int) -> Partial {
  let mut sum = 0L
  let mut best_n = 0
  let mut best_steps = -1
  let mut n = lo
  while n <= hi {
    let k = steps(n)
    sum = sum + k.to_int64()
    if k > best_steps {
      best_steps = k
      best_n = n
    }
    n = n + 1
  }
  Partial::{ sum: sum, best_n: best_n, best_steps: best_steps }
}

pub fn merge(a : Partial, b : Partial) -> Partial {
  let take_b = b.best_steps > a.best_steps || (b.best_steps == a.best_steps && b.best_n < a.best_n)
  Partial::{
    sum: a.sum + b.sum,
    best_n: if take_b { b.best_n } else { a.best_n },
    best_steps: if take_b { b.best_steps } else { a.best_steps },
  }
}

pub fn parallel(world : World, n : Int, workers : Int) -> Partial {
  let ch : Channel[Partial] = Channel::new(workers)
  let size = n / workers
  scope(world, fn(s : Scope) -> Unit {
    for w in 0..workers {
      let lo = w * size + 1
      let hi = if w == workers - 1 { n } else { (w + 1) * size }
      spawn(s, fn() -> Unit {
        let _ = ch.send(chunk(lo, hi))
      })
    }
  })
  ch.close()
  let mut acc = Partial::{ sum: 0L, best_n: 0, best_steps: -1 }
  let mut done = false
  while !done {
    match ch.recv() {
      Some(p) => acc = merge(acc, p)
      None => done = true
    }
  }
  acc
}

pub fn main(world : World) -> Int {
  let n = 100000
  let par = parallel(world, n, 4)
  let seq = chunk(1, n)
  let same = par.sum == seq.sum && par.best_n == seq.best_n && par.best_steps == seq.best_steps
  io_println(world, "n=\{n} chunks=4")
  io_println(world, "total_steps=" + par.sum.to_string())
  io_println(world, "longest=\{par.best_n} steps=\{par.best_steps}")
  io_println(world, "parallel_matches_sequential=\{same}")
  0
}

test "steps" {
  debug_assert(steps(1) == 0, "1")
  debug_assert(steps(6) == 8, "6")
  debug_assert(steps(27) == 111, "27")
  debug_assert(steps(77031) == 350, "77031 needs 64-bit")
}

test "merge is order independent with smallest-n tie break" {
  let a = Partial::{ sum: 10L, best_n: 9, best_steps: 19 }
  let b = Partial::{ sum: 5L, best_n: 7, best_steps: 19 }
  let ab = merge(a, b)
  let ba = merge(b, a)
  debug_assert(ab.best_n == 7 && ba.best_n == 7, "tie -> smaller n")
  debug_assert(ab.sum == 15L && ba.sum == 15L, "sum")
  let whole = chunk(1, 1000)
  let split = merge(merge(chunk(1, 300), chunk(301, 700)), chunk(701, 1000))
  debug_assert(whole.sum == split.sum && whole.best_n == split.best_n, "chunking")
}
