///| t05_json_patch: RFC 7386 merge patch + validation via checked `raise` (core/json)

///|
let base_src : String =
  #|{"server":{"host":"localhost","port":8080,"tls":false},"limits":{"max_conn":100,"timeout_ms":5000},"log":{"level":"info"},"features":["a","b"]}

///|
let patches : Array[String] = [
  #|{"server":{"port":9090,"tls":true},"log":{"level":"debug"},"features":["a","b","c"]}
  ,
  #|{"server":{"port":70000},"limits":{"timeout_ms":null}}
  ,
  #|{"server":{"host":null}}
  ,
  #|{"log":{"level":"verbose"},"limits":{"max_conn":0}}
  ,
  #|{"server": {"port": 1}
  ,
  #|{"server":"oops"}
  ,
]

///|
suberror ConfigError {
  ConfigError(String)
}

///| RFC 7386 JSON merge patch.
fn merge_patch(target : Json, patch : Json) -> Json {
  match patch {
    Object(p) => {
      let out : Map[String, Json] = match target {
        Object(t) => t.copy()
        _ => Map([])
      }
      for k, v in p {
        match v {
          Null => out.remove(k)
          _ => out[k] = merge_patch(out.get(k).unwrap_or(Json::null()), v)
        }
      }
      Json::object(out)
    }
    _ => patch
  }
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

///| Compact JSON with keys in byte order and integral numbers.
fn canonical(v : Json) -> String {
  match v {
    Number(n, ..) => n.to_int().to_string()
    Array(items) => "[" + items.map(canonical).join(",") + "]"
    Object(m) => {
      let keys = m.keys().to_array()
      keys.sort_by(byte_compare)
      let parts = keys.map(fn(k) { Json::string(k).stringify() + ":" + canonical(m[k]) })
      "{" + parts.join(",") + "}"
    }
    _ => v.stringify()
  }
}

///|
fn member(obj : Map[String, Json], key : String, path : String) -> Json raise ConfigError {
  match obj.get(key) {
    Some(v) => v
    None => raise ConfigError("\{path}: missing")
  }
}

///|
fn get_obj(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Map[String, Json] raise ConfigError {
  match member(obj, key, path) {
    Object(m) => m
    _ => raise ConfigError("\{path}: expected object")
  }
}

///|
fn get_str(obj : Map[String, Json], key : String, path : String) -> String raise ConfigError {
  match member(obj, key, path) {
    String(s) => s
    _ => raise ConfigError("\{path}: expected string")
  }
}

///|
fn get_int(obj : Map[String, Json], key : String, path : String) -> Int raise ConfigError {
  match member(obj, key, path) {
    Number(n, ..) if n == n.to_int().to_double() => n.to_int()
    _ => raise ConfigError("\{path}: expected int")
  }
}

///|
fn get_bool(obj : Map[String, Json], key : String, path : String) -> Bool raise ConfigError {
  match member(obj, key, path) {
    True => true
    False => false
    _ => raise ConfigError("\{path}: expected bool")
  }
}

///|
fn validate(cfg : Json) -> Unit raise ConfigError {
  guard cfg is Object(root) else { raise ConfigError("root: expected object") }
  let server = get_obj(root, "server", "server")
  if get_str(server, "host", "server.host").length() == 0 {
    raise ConfigError("server.host: expected string")
  }
  let port = get_int(server, "port", "server.port")
  if port < 1 || port > 65535 {
    raise ConfigError("server.port: \{port} out of range 1..65535")
  }
  ignore(get_bool(server, "tls", "server.tls"))
  let limits = get_obj(root, "limits", "limits")
  if get_int(limits, "max_conn", "limits.max_conn") <= 0 {
    raise ConfigError("limits.max_conn: must be > 0")
  }
  let log = get_obj(root, "log", "log")
  match get_str(log, "level", "log.level") {
    "debug" | "info" | "warn" | "error" => ()
    other => raise ConfigError("log.level: invalid value \{other}")
  }
}

///|
fn apply_one(base : Json, patch_src : String) -> String {
  let patch = @json.parse(patch_src) catch { _ => return "parse error" }
  let merged = merge_patch(base, patch)
  validate(merged) catch {
    ConfigError(msg) => return "invalid: \{msg}"
  }
  "ok: \{canonical(merged)}"
}

///|
fn main {
  let base = @json.parse(base_src) catch { e => abort("bad base: \{e}") }
  println("base: \{canonical(base)}")
  for i, p in patches {
    println("patch\{i + 1} \{apply_one(base, p)}")
  }
}

///|
test "merge patch semantics" {
  let t = @json.parse("{\"a\":{\"b\":1,\"c\":2},\"d\":3}")
  let p = @json.parse("{\"a\":{\"b\":null,\"e\":[1]},\"d\":{\"x\":true}}")
  assert_eq(canonical(merge_patch(t, p)), "{\"a\":{\"c\":2,\"e\":[1]},\"d\":{\"x\":true}}")
  assert_eq(canonical(merge_patch(t, @json.parse("7"))), "7")
}

///|
test "validation order" {
  let base = @json.parse(base_src)
  assert_eq(apply_one(base, "{\"server\":{\"tls\":\"yes\"}}"), "invalid: server.tls: expected bool")
  assert_eq(apply_one(base, "{\"log\":null}"), "invalid: log: missing")
  assert_eq(apply_one(base, "[1]"), "invalid: root: expected object")
  assert_eq(
    apply_one(base, "{\"server\":{\"port\":0},\"log\":{\"level\":\"x\"}}"),
    "invalid: server.port: 0 out of range 1..65535",
  )
}
