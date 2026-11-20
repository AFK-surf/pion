///| t10_graph_topo: Kahn's algorithm, smallest-first, cycle detection

pub struct Topo {
  order : Array[String]
  blocked : Array[String]
}

pub let GRAPH1 : String = "shirt -> tie\ntie -> jacket\npants -> shoes\npants -> belt\nbelt -> jacket\nshirt -> belt\nsocks -> shoes\nundershorts -> pants\nundershorts -> shoes\nwatch\n"
pub let GRAPH2 : String = "a -> b\nb -> c\nc -> a\nc -> d\ne -> d\n"
pub let GRAPH3 : String = "a -> b\nb ->\n"

struct Graph {
  ids : Map[String, Int]
  names : Array[String]
  adj : Array[Array[Int]]
  indeg : Array[Int]
  edges : Map[String, Bool]
}

fn node_id(g : Graph, name : String) -> Int {
  match g.ids.get(name) {
    Some(i) => i
    None => {
      g.names.push(name)
      g.adj.push([])
      g.indeg.push(0)
      g.ids.set(name, g.names.length() - 1)
      g.names.length() - 1
    }
  }
}

fn parse_graph(text : String) -> Result[Graph, String] {
  let g = Graph::{ ids: Map::new(), names: [], adj: [], indeg: [], edges: Map::new() }
  let lines = text.split("\n")
  let mut ln = 0
  while ln < lines.length() {
    let line = lines[ln].trim()
    ln = ln + 1
    if line.length() == 0 {
      continue
    }
    let arrow = line.index_of("->")
    if arrow < 0 {
      let _ = node_id(g, line)
      continue
    }
    let u = line.slice(0, arrow).trim()
    let v = line.slice(arrow + 2, line.length()).trim()
    if u.length() == 0 || v.length() == 0 {
      return Err("line \{ln}: malformed edge '\{line}'")
    }
    let a = node_id(g, u)
    let b = node_id(g, v)
    let key = u + "\n" + v
    if !g.edges.contains(key) {
      g.edges.set(key, true)
      g.adj[a].push(b)
      g.indeg[b] = g.indeg[b] + 1
    }
  }
  Ok(g)
}

/// Index (into `ready`) of the byte-wise smallest name.
fn smallest(g : Graph, ready : Array[Int]) -> Int {
  let mut best = 0
  let mut i = 1
  while i < ready.length() {
    if g.names[ready[i]] < g.names[ready[best]] {
      best = i
    }
    i = i + 1
  }
  best
}

pub fn toposort(text : String) -> Result[Topo, String] {
  let g = parse_graph(text)?
  let indeg = g.indeg.copy()
  let ready : Array[Int] = []
  let mut i = 0
  while i < indeg.length() {
    if indeg[i] == 0 {
      ready.push(i)
    }
    i = i + 1
  }
  let order : Array[String] = []
  while ready.length() > 0 {
    let bi = smallest(g, ready)
    let n = ready[bi]
    let last = match ready.pop() {
      Some(x) => x
      None => n
    }
    if bi < ready.length() {
      ready[bi] = last
    }
    order.push(g.names[n])
    for m in g.adj[n] {
      indeg[m] = indeg[m] - 1
      if indeg[m] == 0 {
        ready.push(m)
      }
    }
  }
  let blocked : Array[String] = []
  i = 0
  while i < indeg.length() {
    if indeg[i] > 0 {
      blocked.push(g.names[i])
    }
    i = i + 1
  }
  blocked.sort()
  Ok(Topo::{ order: order, blocked: blocked })
}

pub fn describe(label : String, text : String) -> String {
  match toposort(text) {
    Err(e) => label + " error: " + e
    Ok(t) =>
      if t.blocked.length() == 0 {
        label + " order: " + t.order.join(" ")
      } else {
        label + " cycle: ordered=" + t.order.join(",") + " blocked=" + t.blocked.join(",")
      }
  }
}

pub fn main(world : World) -> Int {
  io_println(world, describe("graph1", GRAPH1))
  io_println(world, describe("graph2", GRAPH2))
  io_println(world, describe("graph3", GRAPH3))
  0
}

test "duplicates and self loops" {
  debug_assert(describe("g", "b -> a\nb -> a\nc") == "g order: b a c", "duplicate edge counted once")
  debug_assert(describe("g", "x -> x\ny") == "g cycle: ordered=y blocked=x", "self loop")
  debug_assert(describe("g", "") == "g order: ", "empty graph")
}

test "errors" {
  debug_assert(describe("g", "\n -> b") == "g error: line 2: malformed edge '-> b'", "line numbers count blanks")
}
