///| t10_graph_topo: Kahn's algorithm, smallest-first, cycle detection

///|
struct Topo {
  order : Array[String]
  blocked : Array[String]
}

///|
let graph1 : String = "shirt -> tie\ntie -> jacket\npants -> shoes\npants -> belt\nbelt -> jacket\nshirt -> belt\nsocks -> shoes\nundershorts -> pants\nundershorts -> shoes\nwatch\n"

///|
let graph2 : String = "a -> b\nb -> c\nc -> a\nc -> d\ne -> d\n"

///|
let graph3 : String = "a -> b\nb ->\n"

///|
suberror GraphError {
  Malformed(Int, String)
}

///| Byte-order comparison (`String::compare` orders by length first).
fn byte_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let d = a.code_unit_at(i).to_int() - b.code_unit_at(i).to_int()
    if d != 0 {
      return d
    }
  }
  a.length() - b.length()
}

///|
fn toposort(text : String) -> Topo raise GraphError {
  let ids : Map[String, Int] = Map([])
  let names : Array[String] = []
  let adj : Array[Array[Int]] = []
  let indeg : Array[Int] = []
  let seen : Set[(Int, Int)] = Set([])
  fn intern(name : String) -> Int {
    match ids.get(name) {
      Some(i) => i
      None => {
        names.push(name)
        adj.push([])
        indeg.push(0)
        ids[name] = names.length() - 1
        names.length() - 1
      }
    }
  }

  for ln, raw in text.split("\n").to_array() {
    let line = raw.trim().to_owned()
    if line.length() == 0 {
      continue
    }
    let parts = line.split("->").to_array()
    match parts.length() {
      1 => ignore(intern(line))
      _ => {
        let u = parts[0].trim().to_owned()
        let rest = StringBuilder()
        for i in 1..<parts.length() {
          if i > 1 {
            rest.write_string("->")
          }
          rest.write_string(parts[i].to_owned())
        }
        let v = rest.to_string().trim().to_owned()
        if u.length() == 0 || v.length() == 0 {
          raise Malformed(ln + 1, line)
        }
        let a = intern(u)
        let b = intern(v)
        if !seen.contains((a, b)) {
          seen.add((a, b))
          adj[a].push(b)
          indeg[b] += 1
        }
      }
    }
  }
  let ready = []
  for i, d in indeg {
    if d == 0 {
      ready.push(i)
    }
  }
  let order = []
  while ready.length() > 0 {
    // smallest ready name (byte order)
    let mut bi = 0
    for i in 1..<ready.length() {
      if byte_compare(names[ready[i]], names[ready[bi]]) < 0 {
        bi = i
      }
    }
    let n = ready.remove(bi)
    order.push(names[n])
    for m in adj[n] {
      indeg[m] -= 1
      if indeg[m] == 0 {
        ready.push(m)
      }
    }
  }
  let blocked = []
  for i, d in indeg {
    if d > 0 {
      blocked.push(names[i])
    }
  }
  blocked.sort_by(byte_compare)
  { order, blocked }
}

///|
fn describe(label : String, text : String) -> String {
  let t = toposort(text) catch {
    Malformed(ln, line) => return "\{label} error: line \{ln}: malformed edge '\{line}'"
  }
  if t.blocked.length() == 0 {
    "\{label} order: \{t.order.join(" ")}"
  } else {
    "\{label} cycle: ordered=\{t.order.join(",")} blocked=\{t.blocked.join(",")}"
  }
}

///|
fn main {
  println(describe("graph1", graph1))
  println(describe("graph2", graph2))
  println(describe("graph3", graph3))
}

///|
test "duplicates and self loops" {
  assert_eq(describe("g", "b -> a\nb -> a\nc"), "g order: b a c")
  assert_eq(describe("g", "x -> x\ny"), "g cycle: ordered=y blocked=x")
  assert_eq(describe("g", ""), "g order: ")
}

///|
test "errors" {
  assert_eq(describe("g", "\n -> b"), "g error: line 2: malformed edge '-> b'")
}
