///| t03_lru_cache: O(1) LRU with a hash map + index-linked recency list

pub struct Lru {
  cap : Int
  index : Map[String, Int]
  keys : Array[String]
  vals : Array[Int]
  prev : Array[Int]
  next : Array[Int]
  mut head : Int
  mut tail : Int
  mut hits : Int
  mut misses : Int
  mut evictions : Int
}

pub fn new_lru(cap : Int) -> Lru {
  Lru::{
    cap: cap,
    index: Map::new(),
    keys: [],
    vals: [],
    prev: [],
    next: [],
    head: -1,
    tail: -1,
    hits: 0,
    misses: 0,
    evictions: 0,
  }
}

fn Lru::unlink(self : Lru, i : Int) -> Unit {
  let p = self.prev[i]
  let n = self.next[i]
  if p >= 0 {
    self.next[p] = n
  } else {
    self.head = n
  }
  if n >= 0 {
    self.prev[n] = p
  } else {
    self.tail = p
  }
}

fn Lru::push_front(self : Lru, i : Int) -> Unit {
  self.prev[i] = -1
  self.next[i] = self.head
  if self.head >= 0 {
    self.prev[self.head] = i
  }
  self.head = i
  if self.tail < 0 {
    self.tail = i
  }
}

pub fn Lru::get(self : Lru, key : String) -> Option[Int] {
  match self.index.get(key) {
    Some(i) => {
      self.hits = self.hits + 1
      self.unlink(i)
      self.push_front(i)
      Some(self.vals[i])
    }
    None => {
      self.misses = self.misses + 1
      None
    }
  }
}

pub fn Lru::put(self : Lru, key : String, value : Int) -> Option[String] {
  match self.index.get(key) {
    Some(i) => {
      self.vals[i] = value
      self.unlink(i)
      self.push_front(i)
      return None
    }
    None => ()
  }
  if self.keys.length() < self.cap {
    self.keys.push(key)
    self.vals.push(value)
    self.prev.push(-1)
    self.next.push(-1)
    let i = self.keys.length() - 1
    self.index.set(key, i)
    self.push_front(i)
    return None
  }
  let victim = self.tail
  let old = self.keys[victim]
  self.unlink(victim)
  self.index.remove(old)
  self.keys[victim] = key
  self.vals[victim] = value
  self.index.set(key, victim)
  self.push_front(victim)
  self.evictions = self.evictions + 1
  Some(old)
}

pub fn Lru::order(self : Lru) -> Array[String] {
  let out : Array[String] = []
  let mut i = self.head
  while i >= 0 {
    out.push(self.keys[i])
    i = self.next[i]
  }
  out
}

fn log_get(c : Lru, key : String, out : Array[String]) -> Unit {
  match c.get(key) {
    Some(v) => out.push("get \{key} = \{v}")
    None => out.push("get \{key} = miss")
  }
}

fn log_put(c : Lru, key : String, v : Int, out : Array[String]) -> Unit {
  match c.put(key, v) {
    Some(old) => out.push("evict \{old}")
    None => ()
  }
}

pub fn run_script() -> Array[String] {
  let c = new_lru(3)
  let out : Array[String] = []
  log_put(c, "a", 1, out)
  log_put(c, "b", 2, out)
  log_put(c, "c", 3, out)
  log_get(c, "a", out)
  log_put(c, "d", 4, out)
  log_get(c, "b", out)
  log_put(c, "c", 30, out)
  log_put(c, "e", 5, out)
  log_get(c, "a", out)
  log_get(c, "c", out)
  log_get(c, "d", out)
  log_get(c, "e", out)
  out.push("order=" + c.order().join(",") + " hits=\{c.hits} misses=\{c.misses} evictions=\{c.evictions}")
  out
}

pub fn main(world : World) -> Int {
  for line in run_script() {
    io_println(world, line)
  }
  0
}

// NOTE: `Option == Some(..)` type-checks in m2 today but compares object
// identity, so tests match explicitly.
fn some_str(o : Option[String], want : String) -> Bool {
  match o {
    Some(v) => v == want
    None => false
  }
}

fn some_int(o : Option[Int], want : Int) -> Bool {
  match o {
    Some(v) => v == want
    None => false
  }
}

fn is_none(o : Option[Int]) -> Bool {
  match o {
    Some(_) => false
    None => true
  }
}

test "update promotes without eviction" {
  let c = new_lru(2)
  let _ = c.put("x", 1)
  let _ = c.put("y", 2)
  let _ = c.put("x", 10)
  let ev = c.put("z", 3)
  debug_assert(some_str(ev, "y"), "y is LRU after x was updated")
  debug_assert(some_int(c.get("x"), 10), "x updated")
  debug_assert(c.order().join(",") == "x,z", "order")
}

test "capacity one" {
  let c = new_lru(1)
  let _ = c.put("a", 1)
  debug_assert(some_str(c.put("b", 2), "a"), "evict a")
  debug_assert(is_none(c.get("a")), "a gone")
  debug_assert(c.evictions == 1 && c.misses == 1, "stats")
}

test "script" {
  let lines = run_script()
  debug_assert(lines.length() == 9, "nine lines")
  debug_assert(lines[8] == "order=e,d,c hits=4 misses=2 evictions=2", "summary")
}
