///| std/http over real 127.0.0.1 TCP (Linux gate): an in-process request/response
///| exchange, then `http_request` against the server whose port is `args[1]`.

import "http"
import "json"

fn read_all(world : World, fd : Int) -> String {
  let sb = StringBuilder()
  while true {
    let chunk = tcp_read(world, fd, 4096)
    if chunk.length() == 0 {
      break
    }
    sb.write_string(chunk)
  }
  sb.to_string()
}

fn in_process(world : World) -> Int {
  let lfd = tcp_listen(world, "127.0.0.1", 0)
  if lfd < 0 {
    return 1
  }
  let port = tcp_local_port(world, lfd)
  let cfd = tcp_connect(world, "127.0.0.1", port)
  if cfd < 0 {
    return 2
  }
  let req = http::format_request("POST", "127.0.0.1", port, "/echo?n=1&tag=a%2Bb", "{\"n\":1}")
  if tcp_write(world, cfd, req) != req.length() {
    return 3
  }
  let sfd = tcp_accept(world, lfd)
  if sfd < 0 {
    return 4
  }
  match http::read_http_request(world, sfd) {
    Ok(r) => {
      let q = http::query_params(r.query)
      let tag = match q.get("tag") {
        Some(t) => t
        None => ""
      }
      if r.method != "POST" || r.path != "/echo" || tag != "a+b" {
        return 5
      }
      let n = match json::parse(r.body) {
        Ok(v) =>
        match json::obj_get(v, "n") {
          Some(nv) =>
          match json::as_int(nv) {
            Some(x) => x
            None => -1L
          }
          None => -1L
        }
        Err(_) => -1L
      }
      let out = json::JObj([json::field("echo", json::JInt(n + 1L))])
      if !http::write_http_response(world, sfd, http::ok_json(json::stringify(out))) {
        return 6
      }
    }
    Err(e) => {
      io_eprintln(world, "read_http_request: " + e)
      return 7
    }
  }
  tcp_close(world, sfd)
  let raw = read_all(world, cfd)
  tcp_close(world, cfd)
  tcp_close(world, lfd)
  match http::parse_response(raw) {
    Ok(resp) =>
    if resp.status != 200 || resp.body != "{\"echo\":2}" {
      io_eprintln(world, "unexpected response: " + raw)
      return 8
    }
    Err(e) => {
      io_eprintln(world, "parse_response: " + e)
      return 9
    }
  }
  io_println(world, "http in-process ok")
  0
}

fn parse_port(s : String) -> Int {
  let mut v = 0
  let mut i = 0
  while i < s.length() {
    let c = s.code_unit_at(i)
    if c < 48 || c > 57 {
      return 0
    }
    v = v * 10 + (c - 48)
    i = i + 1
  }
  v
}

pub fn main(world : World) -> Int {
  let rc = in_process(world)
  if rc != 0 {
    return rc
  }
  let args = world_args(world)
  if args.length() > 1 {
    let port = parse_port(args[1])
    match http::http_request(world, "127.0.0.1", port, "GET", "/hello", "") {
      Ok(resp) => {
        if resp.status != 200 || resp.body != "hello from server" {
          io_eprintln(world, "http_request got status " + resp.status.to_string() + " body " + resp.body)
          return 10
        }
        io_println(world, "http_request ok: " + resp.status.to_string() + " " + resp.content_type)
      }
      Err(e) => {
        io_eprintln(world, "http_request: " + e)
        return 11
      }
    }
  }
  0
}
