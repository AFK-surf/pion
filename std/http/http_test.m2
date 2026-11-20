///| std/http tests

fn req_ok(raw : String) -> HttpRequest {
  match parse_request(raw) {
    Ok(r) => r
    Err(e) => {
      debug_assert(false, "unexpected request parse error: " + e)
      HttpRequest::{ method: "", path: "", query: "", headers: Map::new(), body: "" }
    }
  }
}

fn resp_ok(raw : String) -> HttpResponse {
  match parse_response(raw) {
    Ok(r) => r
    Err(e) => {
      debug_assert(false, "unexpected response parse error: " + e)
      HttpResponse::{ status: 0, status_text: "", content_type: "", body: "" }
    }
  }
}

fn req_err(raw : String) -> String {
  match parse_request(raw) {
    Ok(_) => ""
    Err(e) => e
  }
}

fn resp_err(raw : String) -> String {
  match parse_response(raw) {
    Ok(_) => ""
    Err(e) => e
  }
}

fn opt_is(o : Option[String], want : String) -> Bool {
  match o {
    Some(s) => s == want
    None => false
  }
}

test "parse request line, query and body" {
  let r = req_ok(
    "POST /api/items?id=42&name=a%20b HTTP/1.1\r\nHost: localhost:8080\r\nContent-Length: 11\r\n\r\n{\"x\":true}\n"
  )
  debug_assert(r.method == "POST", "method")
  debug_assert(r.path == "/api/items", "path")
  debug_assert(r.query == "id=42&name=a%20b", "query")
  debug_assert(r.body == "{\"x\":true}\n", "body")
  let q = query_params(r.query)
  debug_assert(opt_is(q.get("id"), "42"), "query id")
  debug_assert(opt_is(q.get("name"), "a b"), "query name decoded")
  debug_assert(q.length() == 2, "query param count")
}

test "query params splitting and decoding" {
  let q = query_params("a=1&b=&c&d=x+y%2Fz&a=2&%zz=bad%2")
  debug_assert(opt_is(q.get("a"), "2"), "later duplicate wins")
  debug_assert(opt_is(q.get("b"), ""), "empty value")
  debug_assert(opt_is(q.get("c"), ""), "bare key")
  debug_assert(opt_is(q.get("d"), "x y/z"), "plus and percent")
  debug_assert(opt_is(q.get("%zz"), "bad%2"), "malformed escapes kept")
  debug_assert(query_params("").length() == 0, "empty query")
  debug_assert(url_decode("%41%62c") == "Abc", "url_decode")
}

test "headers are case-insensitive" {
  let r = req_ok(
    "GET / HTTP/1.0\nX-Trace-ID: abc\nCONTENT-TYPE:  text/plain \ncontent-length: 0\n\n"
  )
  debug_assert(r.method == "GET" && r.path == "/" && r.query == "", "request line")
  debug_assert(opt_is(header(r, "x-trace-id"), "abc"), "lowercase lookup")
  debug_assert(opt_is(header(r, "Content-Type"), "text/plain"), "mixed-case lookup, trimmed")
  debug_assert(opt_is(r.headers.get("content-type"), "text/plain"), "stored lowercase")
  debug_assert(r.body == "", "empty body")
  match header(r, "missing") {
    Some(_) => {
      debug_assert(false, "missing header found")
    }
    None => ()
  }
  debug_assert(ascii_lower("AbC-xY9") == "abc-xy9", "ascii_lower")
}

test "body without content-length runs to the end" {
  let r = req_ok("PUT /k HTTP/1.1\r\n\r\nraw body")
  debug_assert(r.body == "raw body", "body")
  let cut = req_ok("PUT /k HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcdef")
  debug_assert(cut.body == "abc", "content-length cuts the body")
}

test "parse and format responses" {
  let resp = resp_ok(
    "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\nContent-Length: 17\r\n\r\n{\"error\":\"nope\"}\n"
  )
  debug_assert(resp.status == 404, "status")
  debug_assert(resp.status_text == "Not Found", "status text")
  debug_assert(resp.content_type == "application/json", "content type")
  debug_assert(resp.body == "{\"error\":\"nope\"}\n", "body")

  let ok = ok_json("{\"a\":1}")
  let text = format_response(ok)
  debug_assert(
    text ==
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\nConnection: close\r\n\r\n{\"a\":1}",
    "format_response: " + text
  )
  let back = resp_ok(text)
  debug_assert(back.status == 200 && back.status_text == "OK", "roundtrip status")
  debug_assert(back.content_type == "application/json" && back.body == "{\"a\":1}", "roundtrip body")

  let e = err_json(400, "bad \"input\"")
  debug_assert(e.status == 400 && e.status_text == "Bad Request", "err_json status")
  debug_assert(e.body == "{\"error\":\"bad \\\"input\\\"\"}", "err_json body: " + e.body)
  debug_assert(status_text_for(500) == "Internal Server Error", "status_text_for")
  debug_assert(status_text_for(799) == "Unknown", "unknown status")

  let req = format_request("POST", "127.0.0.1", 8080, "/x", "hi")
  let pr = req_ok(req)
  debug_assert(pr.method == "POST" && pr.path == "/x" && pr.body == "hi", "format_request roundtrip")
  debug_assert(opt_is(header(pr, "host"), "127.0.0.1:8080"), "host header")
}

test "error handling" {
  debug_assert(req_err("") == "incomplete request head", "empty request")
  debug_assert(req_err("GET / HTTP/1.1\r\nHost: x\r\n") == "incomplete request head", "no blank line")
  debug_assert(req_err("GET /\r\n\r\n") == "malformed request line `GET /`", "short request line")
  debug_assert(req_err("GET / SPDY/3\r\n\r\n") == "unsupported protocol `SPDY/3`", "protocol")
  debug_assert(
    req_err("GET / HTTP/1.1\r\nbroken\r\n\r\n") == "malformed header line 1: `broken`",
    "malformed header"
  )
  debug_assert(
    req_err("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") ==
    "incomplete body: expected 10 bytes, got 3",
    "incomplete body"
  )
  debug_assert(
    req_err("POST / HTTP/1.1\r\nContent-Length: ten\r\n\r\n") == "invalid content-length `ten`",
    "bad content-length"
  )
  debug_assert(resp_err("") == "incomplete response head", "empty response")
  debug_assert(resp_err("FTP 200 OK\r\n\r\n") == "malformed status line `FTP 200 OK`", "status line")
  debug_assert(resp_err("HTTP/1.1 20x OK\r\n\r\n") == "invalid status code `20x`", "status code")
  debug_assert(resp_err("HTTP/1.1 2000 OK\r\n\r\n") == "invalid status code `2000`", "status width")
}
