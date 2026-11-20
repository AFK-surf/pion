///| t12_http_router: route matching + params + query parsing (hand-written decoding)

///|
struct Route {
  meth : String
  pattern : String
  name : String
}

///|
struct Outcome {
  status : Int
  route : String
  params : Map[String, String]
  query : Map[String, String]
  error : String
  allow : String
}

///|
let routes : Array[Route] = [
  { meth: "GET", pattern: "/health", name: "health" },
  { meth: "GET", pattern: "/users", name: "user_list" },
  { meth: "POST", pattern: "/users", name: "user_create" },
  { meth: "GET", pattern: "/users/:id", name: "user_get" },
  { meth: "DELETE", pattern: "/users/:id", name: "user_delete" },
  { meth: "GET", pattern: "/files/*path", name: "file_get" },
]

///|
fn segments(path : String) -> Array[String] {
  path.split("/").filter(fn(s) { s.length() > 0 }).map(fn(s) { s.to_owned() }).to_array()
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

///| Substring by code-unit offsets (ASCII inputs).
fn sub(s : String, start : Int, end : Int) -> String {
  s.unsafe_substring(start~, end~)
}

///|
fn bind(pattern : String, segs : Array[String]) -> Map[String, String]? {
  let pat = segments(pattern)
  let params = Map([])
  for i, p in pat {
    if p.has_prefix("*") {
      if i >= segs.length() {
        return None
      }
      params[sub(p, 1, p.length())] = segs[i:].to_array().join("/")
      return Some(params)
    }
    if i >= segs.length() {
      return None
    }
    if p.has_prefix(":") {
      params[sub(p, 1, p.length())] = segs[i]
    } else if p != segs[i] {
      return None
    }
  }
  if pat.length() == segs.length() {
    Some(params)
  } else {
    None
  }
}

///|
fn hex_val(c : Int) -> Int {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    -1
  }
}

///| Percent-decoding (ASCII payloads) with `+` as space.
fn url_decode(s : String) -> String {
  let sb = StringBuilder()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if c == '+'.to_int() {
      sb.write_char(' ')
      i += 1
    } else if c == '%'.to_int() &&
      i + 2 < n &&
      hex_val(s.code_unit_at(i + 1).to_int()) >= 0 &&
      hex_val(s.code_unit_at(i + 2).to_int()) >= 0 {
      let v = hex_val(s.code_unit_at(i + 1).to_int()) * 16 +
        hex_val(s.code_unit_at(i + 2).to_int())
      sb.write_char(v.unsafe_to_char())
      i += 3
    } else {
      sb.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  sb.to_string()
}

///|
fn parse_query(q : String) -> Map[String, String] {
  let out = Map([])
  for pair in q.split("&") {
    if pair.length() == 0 {
      continue
    }
    let parts = pair.split("=").to_array()
    let key = url_decode(parts[0].to_owned())
    let value = if parts.length() > 1 {
      url_decode(sub(pair.to_owned(), parts[0].length() + 1, pair.length()))
    } else {
      ""
    }
    out[key] = value
  }
  out
}

///|
fn all_digits(s : String) -> Bool {
  s.length() > 0 && s.iter().all(fn(c) { c >= '0' && c <= '9' })
}

///|
fn dispatch(meth : String, target : String) -> Outcome {
  let (path, query) = match target.find("?") {
    Some(q) =>
      (
        sub(target, 0, q),
        parse_query(sub(target, q + 1, target.length())),
      )
    None => (target, Map([]))
  }
  let segs = segments(path)
  let allowed = []
  for r in routes {
    guard bind(r.pattern, segs) is Some(params) else { continue }
    if r.meth != meth {
      allowed.push(r.meth)
      continue
    }
    if params.get("id") is Some(id) && !all_digits(id) {
      return {
        status: 400,
        route: r.name,
        params: Map([]),
        query: Map([]),
        error: "invalid id",
        allow: "",
      }
    }
    return { status: 200, route: r.name, params, query, error: "", allow: "" }
  }
  if allowed.length() > 0 {
    allowed.sort_by(byte_compare)
    return {
      status: 405,
      route: "",
      params: Map([]),
      query: Map([]),
      error: "",
      allow: allowed.join(","),
    }
  }
  { status: 404, route: "", params: Map([]), query: Map([]), error: "", allow: "" }
}

///|
fn kv(m : Map[String, String]) -> String {
  let keys = m.keys().to_array()
  keys.sort_by(byte_compare)
  keys.map(fn(k) { "\{k}=\{m[k]}" }).join(",")
}

///|
fn render(meth : String, target : String) -> String {
  let o = dispatch(meth, target)
  let sb = StringBuilder()
  sb.write_string("\{meth} \{target} -> \{o.status}")
  if o.route.length() > 0 {
    sb.write_string(" route=\{o.route}")
  }
  if o.params.length() > 0 {
    sb.write_string(" params=\{kv(o.params)}")
  }
  if o.query.length() > 0 {
    sb.write_string(" query=\{kv(o.query)}")
  }
  if o.error.length() > 0 {
    sb.write_string(" error=\{o.error}")
  }
  if o.allow.length() > 0 {
    sb.write_string(" allow=\{o.allow}")
  }
  sb.to_string()
}

///|
fn main {
  let reqs = [
    "GET /users?limit=10&sort=name", "GET /users/42?verbose=1", "GET /users/abc", "DELETE /users/7",
    "PUT /users/7", "GET /files/docs/readme.md?dl=true", "GET /nope", "GET /health?q=a%20b+c&q=last%2Bone",
    "POST /users/", "GET /files/",
  ]
  for r in reqs {
    let sp = r.find(" ").unwrap()
    println(render(sub(r, 0, sp), sub(r, sp + 1, r.length())))
  }
}

///|
test "matching" {
  assert_eq(dispatch("GET", "/users/12").route, "user_get")
  assert_eq(dispatch("GET", "//users//12/").status, 200)
  assert_eq(dispatch("GET", "/users/12/extra").status, 404)
  assert_eq(dispatch("POST", "/health").allow, "GET")
  assert_eq(
    render("GET", "/files/a/b/c"),
    "GET /files/a/b/c -> 200 route=file_get params=path=a/b/c",
  )
}

///|
test "query decoding" {
  assert_eq(
    render("GET", "/users?b=2&a=x%41+y"),
    "GET /users?b=2&a=x%41+y -> 200 route=user_list query=a=xA y,b=2",
  )
}
