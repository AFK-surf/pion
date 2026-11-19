///| Positive end-to-end m2 frontend fixture
pub val struct Task {
  id : Int
  label : String
}

pub struct Wrapper[T] {
  item : T
}

pub fn Wrapper::unwrap[T](self : Wrapper[T]) -> T {
  self.item
}

pub enum Outcome {
  Pass(Int)
  Fail(String)
}

pub fn score(o : Outcome) -> Int {
  match o {
    Pass(n) => n
    Fail(_) => 0
  }
}

pub fn main(world : World) -> Int {
  debug_assert(true, "sanity")
  let w : Wrapper[Int] = Wrapper::{ item: 7 }
  let ch : Channel[Task] = Channel::new(4)
  let mx : Mutex[Int] = Mutex::new(0)
  let hits = AtomicInt::new(0)
  let t = Task::{ id: w.unwrap(), label: "job" }
  scope(world, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let _ = ch.send(t)
      let _ = hits.fetch_add(1)
      let v = mx.lock()
      mx.set(v + 1)
      mx.unlock()
    })
  })
  let _ = ch.recv()
  ch.close()
  io_println(world, "ok")
  score(Pass(hits.load()))
}
