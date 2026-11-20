///| t05_json_patch: RFC 7386 merge patch + validation via Result/`?` chains (std/json)
import "json"

pub let BASE : String = "{\"server\":{\"host\":\"localhost\",\"port\":8080,\"tls\":false},\"limits\":{\"max_conn\":100,\"timeout_ms\":5000},\"log\":{\"level\":\"info\"},\"features\":[\"a\",\"b\"]}"

pub fn patches() -> Array[String] {
  [
    "{\"server\":{\"port\":9090,\"tls\":true},\"log\":{\"level\":\"debug\"},\"features\":[\"a\",\"b\",\"c\"]}",
    "{\"server\":{\"port\":70000},\"limits\":{\"timeout_ms\":null}}",
    "{\"server\":{\"host\":null}}",
    "{\"log\":{\"level\":\"verbose\"},\"limits\":{\"max_conn\":0}}",
    "{\"server\": {\"port\": 1}",
    "{\"server\":\"oops\"}",
  ]
}

fn index_of_key(fields : Array[json::JsonField], key : String) -> Int {
  let mut i = 0
  while i < fields.length() {
    if fields[i].key == key {
      return i
    }
    i = i + 1
  }
  -1
}

fn without(fields : Array[json::JsonField], idx : Int) -> Array[json::JsonField] {
  let out : Array[json::JsonField] = []
  let mut i = 0
  while i < fields.length() {
    if i != idx {
      out.push(fields[i])
    }
    i = i + 1
  }
  out
}

/// RFC 7386 JSON merge patch.
pub fn merge_patch(target : json::JsonValue, patch : json::JsonValue) -> json::JsonValue {
  match patch {
    json::JObj(pfields) => {
      let mut out : Array[json::JsonField] = match target {
        json::JObj(tf) => tf.copy()
        _ => []
      }
      for pf in pfields {
        let idx = index_of_key(out, pf.key)
        match pf.value {
          json::JNull => if idx >= 0 { out = without(out, idx) }
          _ => {
            let cur = if idx >= 0 { out[idx].value } else { json::JNull }
            let merged = json::field(pf.key, merge_patch(cur, pf.value))
            if idx >= 0 {
              out[idx] = merged
            } else {
              out.push(merged)
            }
          }
        }
      }
      json::JObj(out)
    }
    _ => patch
  }
}

/// Compact JSON with object keys sorted in byte order.
pub fn canonical(v : json::JsonValue) -> String {
  match v {
    json::JArr(items) => {
      let parts : Array[String] = []
      for it in items {
        parts.push(canonical(it))
      }
      "[" + parts.join(",") + "]"
    }
    json::JObj(fields) => {
      let keys : Array[String] = []
      for f in fields {
        keys.push(f.key)
      }
      keys.sort()
      let parts : Array[String] = []
      for k in keys {
        let f = fields[index_of_key(fields, k)]
        parts.push(json::stringify(json::JStr(k)) + ":" + canonical(f.value))
      }
      "{" + parts.join(",") + "}"
    }
    _ => json::stringify(v)
  }
}

fn member(obj : json::JsonValue, key : String, path : String) -> Result[json::JsonValue, String] {
  match json::obj_get(obj, key) {
    Some(v) => Ok(v)
    None => Err(path + ": missing")
  }
}

fn get_obj(obj : json::JsonValue, key : String, path : String) -> Result[json::JsonValue, String] {
  let v = member(obj, key, path)?
  match v {
    json::JObj(_) => Ok(v)
    _ => Err(path + ": expected object")
  }
}

fn get_str(obj : json::JsonValue, key : String, path : String) -> Result[String, String] {
  let v = member(obj, key, path)?
  match json::as_str(v) {
    Some(s) => Ok(s)
    None => Err(path + ": expected string")
  }
}

fn get_int(obj : json::JsonValue, key : String, path : String) -> Result[Int64, String] {
  let v = member(obj, key, path)?
  match json::as_int(v) {
    Some(n) => Ok(n)
    None => Err(path + ": expected int")
  }
}

fn get_bool(obj : json::JsonValue, key : String, path : String) -> Result[Bool, String] {
  let v = member(obj, key, path)?
  match json::as_bool(v) {
    Some(b) => Ok(b)
    None => Err(path + ": expected bool")
  }
}

pub fn validate(cfg : json::JsonValue) -> Result[Unit, String] {
  match cfg {
    json::JObj(_) => ()
    _ => return Err("root: expected object")
  }
  let server = get_obj(cfg, "server", "server")?
  let host = get_str(server, "host", "server.host")?
  if host.length() == 0 {
    return Err("server.host: expected string")
  }
  let port = get_int(server, "port", "server.port")?
  if port < 1L || port > 65535L {
    return Err("server.port: " + port.to_string() + " out of range 1..65535")
  }
  let _ = get_bool(server, "tls", "server.tls")?
  let limits = get_obj(cfg, "limits", "limits")?
  let max_conn = get_int(limits, "max_conn", "limits.max_conn")?
  if max_conn <= 0L {
    return Err("limits.max_conn: must be > 0")
  }
  let log = get_obj(cfg, "log", "log")?
  let level = get_str(log, "level", "log.level")?
  if level != "debug" && level != "info" && level != "warn" && level != "error" {
    return Err("log.level: invalid value " + level)
  }
  Ok(())
}

pub fn apply_one(base : json::JsonValue, patch_src : String) -> String {
  match json::parse(patch_src) {
    Err(_) => "parse error"
    Ok(p) => {
      let merged = merge_patch(base, p)
      match validate(merged) {
        Ok(_) => "ok: " + canonical(merged)
        Err(msg) => "invalid: " + msg
      }
    }
  }
}

pub fn main(world : World) -> Int {
  let base = match json::parse(BASE) {
    Ok(v) => v
    Err(e) => {
      io_eprintln(world, "bad base: " + e)
      return 1
    }
  }
  io_println(world, "base: " + canonical(base))
  let ps = patches()
  let mut i = 0
  while i < ps.length() {
    io_println(world, "patch" + (i + 1).to_string() + " " + apply_one(base, ps[i]))
    i = i + 1
  }
  0
}

fn parse_or_null(src : String) -> json::JsonValue {
  match json::parse(src) {
    Ok(v) => v
    Err(_) => json::JNull
  }
}

test "merge patch semantics" {
  let t = parse_or_null("{\"a\":{\"b\":1,\"c\":2},\"d\":3}")
  let p = parse_or_null("{\"a\":{\"b\":null,\"e\":[1]},\"d\":{\"x\":true}}")
  debug_assert(canonical(merge_patch(t, p)) == "{\"a\":{\"c\":2,\"e\":[1]},\"d\":{\"x\":true}}", "rfc7386")
  debug_assert(canonical(merge_patch(t, parse_or_null("7"))) == "7", "scalar replaces")
}

test "validation order" {
  let base = parse_or_null(BASE)
  debug_assert(apply_one(base, "{\"server\":{\"tls\":\"yes\"}}") == "invalid: server.tls: expected bool", "tls type")
  debug_assert(apply_one(base, "{\"log\":null}") == "invalid: log: missing", "log missing")
  debug_assert(apply_one(base, "[1]") == "invalid: root: expected object", "root")
  debug_assert(apply_one(base, "{\"server\":{\"port\":0},\"log\":{\"level\":\"x\"}}") == "invalid: server.port: 0 out of range 1..65535", "first error wins")
}
