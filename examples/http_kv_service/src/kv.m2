///| The KV store, its counters, JSON response types and the REST router.
///| `handle` is pure (no `World`): the TCP server and `--self-test` share it.

import "json"
import "http"

/// Shared service state: every field is `Send`, so worker threads capture it.
pub struct Service {
  store : Mutex[Map[String, String]]
  total_reqs : AtomicInt
  hits : AtomicInt
  misses : AtomicInt
  puts : AtomicInt
  deletes : AtomicInt
  bad_requests : AtomicInt
}

pub fn new_service() -> Service {
  let store : Mutex[Map[String, String]] = Mutex::new(Map::new())
  Service::{
    store: store,
    total_reqs: AtomicInt::new(0),
    hits: AtomicInt::new(0),
    misses: AtomicInt::new(0),
    puts: AtomicInt::new(0),
    deletes: AtomicInt::new(0),
    bad_requests: AtomicInt::new(0),
  }
}

pub struct HealthResp {
  ok : Bool
  service : String
}

pub struct PutResp {
  key : String
  value : String
}

pub struct ItemResp {
  key : String
  value : String
}

pub struct DeletedResp {
  deleted : Bool
}

pub struct StatsResp {
  total_reqs : Int
  keys : Int
  hits : Int
  misses : Int
  puts : Int
  deletes : Int
}

impl json::ToJson for HealthResp {
  fn to_json(self : HealthResp) -> json::JsonValue {
    json::JObj([json::field("ok", json::JBool(self.ok)), json::field("service", json::JStr(self.service))])
  }
}

impl json::ToJson for PutResp {
  fn to_json(self : PutResp) -> json::JsonValue {
    json::JObj([
      json::field("ok", json::JBool(true)),
      json::field("key", json::JStr(self.key)),
      json::field("value", json::JStr(self.value)),
    ])
  }
}

impl json::ToJson for ItemResp {
  fn to_json(self : ItemResp) -> json::JsonValue {
    json::JObj([json::field("key", json::JStr(self.key)), json::field("value", json::JStr(self.value))])
  }
}

impl json::ToJson for DeletedResp {
  fn to_json(self : DeletedResp) -> json::JsonValue {
    json::JObj([json::field("deleted", json::JBool(self.deleted))])
  }
}

impl json::ToJson for StatsResp {
  fn to_json(self : StatsResp) -> json::JsonValue {
    json::JObj([
      json::field("total_reqs", self.total_reqs.to_json()),
      json::field("keys", self.keys.to_json()),
      json::field("hits", self.hits.to_json()),
      json::field("misses", self.misses.to_json()),
      json::field("puts", self.puts.to_json()),
      json::field("deletes", self.deletes.to_json()),
    ])
  }
}

/// `200 OK` with any `ToJson` value as the body (monomorphized per type).
pub fn json_ok[T : json::ToJson](v : T) -> http::HttpResponse {
  http::ok_json(json::encode(v))
}

fn bad_request(svc : Service, msg : String) -> http::HttpResponse {
  let _ = svc.bad_requests.fetch_add(1)
  http::err_json(400, msg)
}

/// Number of keys currently stored.
pub fn key_count(svc : Service) -> Int {
  let m = svc.store.lock()
  let n = m.length()
  svc.store.unlock()
  n
}

pub fn stats(svc : Service) -> StatsResp {
  StatsResp::{
    total_reqs: svc.total_reqs.load(),
    keys: key_count(svc),
    hits: svc.hits.load(),
    misses: svc.misses.load(),
    puts: svc.puts.load(),
    deletes: svc.deletes.load(),
  }
}

fn put_item(svc : Service, key : String, body : String) -> http::HttpResponse {
  let value = match json::parse(body) {
    Ok(v) =>
    match json::obj_get(v, "value") {
      Some(jv) =>
      match json::as_str(jv) {
        Some(s) => s
        None => return bad_request(svc, "field `value` must be a string")
      }
      None => return bad_request(svc, "missing field `value`")
    }
    Err(e) => return bad_request(svc, "invalid json: " + e)
  }
  let m = svc.store.lock()
  m.set(key, value)
  svc.store.unlock()
  let _ = svc.puts.fetch_add(1)
  json_ok(PutResp::{ key: key, value: value })
}

fn get_item(svc : Service, key : String) -> http::HttpResponse {
  let m = svc.store.lock()
  let found = m.get(key)
  svc.store.unlock()
  match found {
    Some(v) => {
      let _ = svc.hits.fetch_add(1)
      json_ok(ItemResp::{ key: key, value: v })
    }
    None => {
      let _ = svc.misses.fetch_add(1)
      http::err_json(404, "not found")
    }
  }
}

fn delete_item(svc : Service, key : String) -> http::HttpResponse {
  let m = svc.store.lock()
  let existed = match m.get(key) {
    Some(_) => {
      m.remove(key)
      true
    }
    None => false
  }
  svc.store.unlock()
  if existed {
    let _ = svc.deletes.fetch_add(1)
    json_ok(DeletedResp::{ deleted: true })
  } else {
    http::err_json(404, "not found")
  }
}

/// Routes one request. Every call counts towards `total_reqs`.
pub fn handle(svc : Service, method : String, path : String, body : String) -> http::HttpResponse {
  let _ = svc.total_reqs.fetch_add(1)
  if path == "/health" {
    if method != "GET" {
      return http::err_json(405, "method not allowed")
    }
    return json_ok(HealthResp::{ ok: true, service: "m2-kv" })
  }
  if path == "/stats" {
    if method != "GET" {
      return http::err_json(405, "method not allowed")
    }
    return json_ok(stats(svc))
  }
  if path.starts_with("/items/") {
    let key = http::url_decode(path.slice(7, path.length()))
    if key.length() == 0 || key.contains("/") {
      return bad_request(svc, "invalid key")
    }
    if method == "PUT" {
      return put_item(svc, key, body)
    } else if method == "GET" {
      return get_item(svc, key)
    } else if method == "DELETE" {
      return delete_item(svc, key)
    }
    return http::err_json(405, "method not allowed")
  }
  http::err_json(404, "no route for " + path)
}

/// Parses a raw HTTP/1.1 request, routes it and serializes the response.
pub fn handle_raw(svc : Service, raw : String) -> String {
  match http::parse_request(raw) {
    Ok(req) => http::format_response(handle(svc, req.method, req.path, req.body))
    Err(e) => http::format_response(bad_request(svc, e))
  }
}
