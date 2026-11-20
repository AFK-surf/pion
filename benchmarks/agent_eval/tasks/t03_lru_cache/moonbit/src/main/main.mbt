///| t03_lru_cache: O(1) LRU with a hash map + index-linked recency list

///|
struct Lru {
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

///|
fn Lru::new(cap : Int) -> Lru {
  {
    cap,
    index: Map([]),
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

///|
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

///|
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

///|
fn Lru::get(self : Lru, key : String) -> Int? {
  match self.index.get(key) {
    Some(i) => {
      self.hits += 1
      self.unlink(i)
      self.push_front(i)
      Some(self.vals[i])
    }
    None => {
      self.misses += 1
      None
    }
  }
}

///|
fn Lru::put(self : Lru, key : String, value : Int) -> String? {
  if self.index.get(key) is Some(i) {
    self.vals[i] = value
    self.unlink(i)
    self.push_front(i)
    return None
  }
  if self.keys.length() < self.cap {
    self.keys.push(key)
    self.vals.push(value)
    self.prev.push(-1)
    self.next.push(-1)
    let i = self.keys.length() - 1
    self.index[key] = i
    self.push_front(i)
    return None
  }
  let victim = self.tail
  let old = self.keys[victim]
  self.unlink(victim)
  self.index.remove(old)
  self.keys[victim] = key
  self.vals[victim] = value
  self.index[key] = victim
  self.push_front(victim)
  self.evictions += 1
  Some(old)
}

///|
fn Lru::order(self : Lru) -> Array[String] {
  let out = []
  let mut i = self.head
  while i >= 0 {
    out.push(self.keys[i])
    i = self.next[i]
  }
  out
}

///|
fn run_script() -> Array[String] {
  let c = Lru::new(3)
  let out = []
  fn put(k : String, v : Int) {
    if c.put(k, v) is Some(old) {
      out.push("evict \{old}")
    }
  }

  fn get(k : String) {
    match c.get(k) {
      Some(v) => out.push("get \{k} = \{v}")
      None => out.push("get \{k} = miss")
    }
  }

  put("a", 1)
  put("b", 2)
  put("c", 3)
  get("a")
  put("d", 4)
  get("b")
  put("c", 30)
  put("e", 5)
  get("a")
  get("c")
  get("d")
  get("e")
  out.push(
    "order=\{c.order().join(",")} hits=\{c.hits} misses=\{c.misses} evictions=\{c.evictions}",
  )
  out
}

///|
fn main {
  for line in run_script() {
    println(line)
  }
}

///|
test "update promotes without eviction" {
  let c = Lru::new(2)
  ignore(c.put("x", 1))
  ignore(c.put("y", 2))
  ignore(c.put("x", 10))
  assert_eq(c.put("z", 3), Some("y"))
  assert_eq(c.get("x"), Some(10))
  assert_eq(c.order().join(","), "x,z")
}

///|
test "capacity one" {
  let c = Lru::new(1)
  ignore(c.put("a", 1))
  assert_eq(c.put("b", 2), Some("a"))
  assert_eq(c.get("a"), None)
  assert_eq((c.evictions, c.misses), (1, 1))
}

///|
test "script" {
  let lines = run_script()
  assert_eq(lines.length(), 9)
  assert_eq(lines[8], "order=e,d,c hits=4 misses=2 evictions=2")
}
