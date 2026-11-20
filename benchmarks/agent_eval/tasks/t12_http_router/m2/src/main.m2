///| t12_http_router: route matching + params + query parsing (std/http)
import "http"

pub struct Route {
  method : String
  pattern : Array[String]
  name : String
}

pub struct Outcome {
  status : Int
  route : String
  params : Map[String, String]
  query : Map[String, String]
  error : String
  allow : String
}

fn segments(path : String) -> Array[String] {
  let out : Array[String] = []
  for s in path.split("/") {
    if s.length() > 0 {
      out.push(s)
    }
  }
  out
}

pub fn routes() -> Array[Route] {
  [
    Route::{ method: "GET", pattern: segments("/health"), name: "health" },
    Route::{ method: "GET", pattern: segments("/users"), name: "user_list" },
    Route::{ method: "POST", pattern: segments("/users"), name: "user_create" },
    Route::{ method: "GET", pattern: segments("/users/:id"), name: "user_get" },
    Route::{ method: "DELETE", pattern: segments("/users/:id"), name: "user_delete" },
    Route::{ method: "GET", pattern: segments("/files/*path"), name: "file_get" },
  ]
}

/// Binds the pattern against the path segments; None when it does not match.
fn bind(pattern : Array[String], segs : Array[String]) -> Option[Map[String, String]] {
  let params : Map[String, String] = Map::new()
  let mut i = 0
  while i < pattern.length() {
    let p = pattern[i]
    if p.starts_with("*") {
      if i >= segs.length() {
        return None
      }
      let rest : Array[String] = []
      let mut j = i
      while j < segs.length() {
        rest.push(segs[j])
        j = j + 1
      }
      params.set(p.slice(1, p.length()), rest.join("/"))
      return Some(params)
    }
    if i >= segs.length() {
      return None
    }
    if p.starts_with(":") {
      params.set(p.slice(1, p.length()), segs[i])
    } else if p != segs[i] {
      return None
    }
    i = i + 1
  }
  if i == segs.length() {
    Some(params)
  } else {
    None
  }
}

fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  let mut i = 0
  while i < s.length() {
    let c = s.code_unit_at(i)
    if c < 48 || c > 57 {
      return false
    }
    i = i + 1
  }
  true
}

pub fn dispatch(method : String, target : String) -> Outcome {
  let q = target.index_of("?")
  let path = if q >= 0 { target.slice(0, q) } else { target }
  let query = if q >= 0 { http::query_params(target.slice(q + 1, target.length())) } else { Map::new() }
  let segs = segments(path)
  let allowed : Array[String] = []
  for r in routes() {
    match bind(r.pattern, segs) {
      None => ()
      Some(params) => {
        if r.method != method {
          allowed.push(r.method)
          continue
        }
        let id_ok = match params.get("id") {
          Some(id) => all_digits(id)
          None => true
        }
        if !id_ok {
          return Outcome::{ status: 400, route: r.name, params: Map::new(), query: Map::new(), error: "invalid id", allow: "" }
        }
        return Outcome::{ status: 200, route: r.name, params: params, query: query, error: "", allow: "" }
      }
    }
  }
  if allowed.length() > 0 {
    allowed.sort()
    return Outcome::{ status: 405, route: "", params: Map::new(), query: Map::new(), error: "", allow: allowed.join(",") }
  }
  Outcome::{ status: 404, route: "", params: Map::new(), query: Map::new(), error: "", allow: "" }
}

fn kv(m : Map[String, String]) -> String {
  let keys = m.keys()
  keys.sort()
  let parts : Array[String] = []
  for k in keys {
    match m.get(k) {
      Some(v) => parts.push(k + "=" + v)
      None => ()
    }
  }
  parts.join(",")
}

pub fn render(method : String, target : String) -> String {
  let o = dispatch(method, target)
  let mut out = method + " " + target + " -> " + o.status.to_string()
  if o.route.length() > 0 {
    out = out + " route=" + o.route
  }
  if o.params.length() > 0 {
    out = out + " params=" + kv(o.params)
  }
  if o.query.length() > 0 {
    out = out + " query=" + kv(o.query)
  }
  if o.error.length() > 0 {
    out = out + " error=" + o.error
  }
  if o.allow.length() > 0 {
    out = out + " allow=" + o.allow
  }
  out
}

pub fn main(world : World) -> Int {
  let reqs = [
    "GET /users?limit=10&sort=name",
    "GET /users/42?verbose=1",
    "GET /users/abc",
    "DELETE /users/7",
    "PUT /users/7",
    "GET /files/docs/readme.md?dl=true",
    "GET /nope",
    "GET /health?q=a%20b+c&q=last%2Bone",
    "POST /users/",
    "GET /files/",
  ]
  for r in reqs {
    let sp = r.index_of(" ")
    io_println(world, render(r.slice(0, sp), r.slice(sp + 1, r.length())))
  }
  0
}

test "matching" {
  debug_assert(dispatch("GET", "/users/12").route == "user_get", "param route")
  debug_assert(dispatch("GET", "//users//12/").status == 200, "empty segments ignored")
  debug_assert(dispatch("GET", "/users/12/extra").status == 404, "extra segment")
  debug_assert(dispatch("POST", "/health").allow == "GET", "405 allow")
  debug_assert(render("GET", "/files/a/b/c") == "GET /files/a/b/c -> 200 route=file_get params=path=a/b/c", "wildcard")
}

test "query decoding" {
  debug_assert(render("GET", "/users?b=2&a=x%41+y") == "GET /users?b=2&a=x%41+y -> 200 route=user_list query=a=xA y,b=2", "decode + sort")
}
