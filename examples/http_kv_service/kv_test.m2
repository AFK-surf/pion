///| http_kv_service tests: REST routes, JSON bodies and counters.

test "health and unknown routes" {
  let svc = new_service()
  let h = handle(svc, "GET", "/health", "")
  debug_assert(h.status == 200 && h.content_type == "application/json", "health status")
  debug_assert(h.body == "{\"ok\":true,\"service\":\"m2-kv\"}", "health body " + h.body)
  debug_assert(handle(svc, "POST", "/health", "").status == 405, "health method")
  debug_assert(handle(svc, "GET", "/missing", "").status == 404, "no route")
  debug_assert(handle(svc, "PATCH", "/items/a", "").status == 405, "item method")
  debug_assert(handle(svc, "GET", "/items/", "").status == 400, "empty key")
  debug_assert(handle(svc, "GET", "/items/a/b", "").status == 400, "nested key")
}

test "put, get, delete and stats" {
  let svc = new_service()
  let p = handle(svc, "PUT", "/items/user%3A1", "{\"value\":\"ada\"}")
  debug_assert(p.status == 200, "put status")
  debug_assert(p.body == "{\"ok\":true,\"key\":\"user:1\",\"value\":\"ada\"}", "put body " + p.body)
  let g = handle(svc, "GET", "/items/user%3A1", "")
  debug_assert(g.status == 200 && g.body == "{\"key\":\"user:1\",\"value\":\"ada\"}", "get body " + g.body)
  let p2 = handle(svc, "PUT", "/items/user%3A1", "{\"value\":\"grace\", \"extra\": [1, 2]}")
  debug_assert(p2.status == 200, "overwrite")
  let g2 = handle(svc, "GET", "/items/user%3A1", "")
  debug_assert(g2.body == "{\"key\":\"user:1\",\"value\":\"grace\"}", "overwritten value " + g2.body)
  let m = handle(svc, "GET", "/items/ghost", "")
  debug_assert(m.status == 404 && m.body == "{\"error\":\"not found\"}", "miss " + m.body)
  let d = handle(svc, "DELETE", "/items/user%3A1", "")
  debug_assert(d.status == 200 && d.body == "{\"deleted\":true}", "delete " + d.body)
  debug_assert(handle(svc, "DELETE", "/items/user%3A1", "").status == 404, "delete missing")
  let st = handle(svc, "GET", "/stats", "")
  debug_assert(
    st.body == "{\"total_reqs\":8,\"keys\":0,\"hits\":2,\"misses\":1,\"puts\":2,\"deletes\":1}",
    "stats " + st.body
  )
}

test "invalid bodies are 400" {
  let svc = new_service()
  let bad = handle(svc, "PUT", "/items/k", "{\"value\":")
  debug_assert(bad.status == 400 && bad.body.contains("invalid json"), "truncated json " + bad.body)
  debug_assert(handle(svc, "PUT", "/items/k", "{\"v\":\"x\"}").status == 400, "missing value")
  debug_assert(handle(svc, "PUT", "/items/k", "{\"value\":null}").status == 400, "null value")
  debug_assert(handle(svc, "PUT", "/items/k", "").status == 400, "empty body")
  debug_assert(key_count(svc) == 0 && svc.bad_requests.load() == 4, "nothing stored")
}

test "raw HTTP text path" {
  let svc = new_service()
  let raw = handle_raw(svc, "PUT /items/k HTTP/1.1\r\nHost: x\r\nContent-Length: 14\r\n\r\n{\"value\":\"v1\"}")
  debug_assert(raw.starts_with("HTTP/1.1 200 OK\r\n"), "status line " + raw)
  debug_assert(raw.ends_with("\r\n\r\n{\"ok\":true,\"key\":\"k\",\"value\":\"v1\"}"), "body " + raw)
  let junk = handle_raw(svc, "garbage")
  debug_assert(junk.starts_with("HTTP/1.1 400 Bad Request\r\n"), "malformed request " + junk)
  debug_assert(json_ok(StatsResp::{ total_reqs: 1, keys: 2, hits: 3, misses: 4, puts: 5, deletes: 6 }).body ==
    "{\"total_reqs\":1,\"keys\":2,\"hits\":3,\"misses\":4,\"puts\":5,\"deletes\":6}", "ToJson StatsResp")
}
