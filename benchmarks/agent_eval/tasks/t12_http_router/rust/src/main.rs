//! t12_http_router: route matching + params + query parsing (std only)
use std::collections::BTreeMap;

pub struct Route {
    method: &'static str,
    pattern: &'static str,
    name: &'static str,
}

pub const ROUTES: [Route; 6] = [
    Route { method: "GET", pattern: "/health", name: "health" },
    Route { method: "GET", pattern: "/users", name: "user_list" },
    Route { method: "POST", pattern: "/users", name: "user_create" },
    Route { method: "GET", pattern: "/users/:id", name: "user_get" },
    Route { method: "DELETE", pattern: "/users/:id", name: "user_delete" },
    Route { method: "GET", pattern: "/files/*path", name: "file_get" },
];

#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub status: u16,
    pub route: &'static str,
    pub params: BTreeMap<String, String>,
    pub query: BTreeMap<String, String>,
    pub error: &'static str,
    pub allow: String,
}

fn segments(path: &str) -> Vec<&str> {
    path.split('/').filter(|s| !s.is_empty()).collect()
}

fn bind(pattern: &str, segs: &[&str]) -> Option<BTreeMap<String, String>> {
    let pat = segments(pattern);
    let mut params = BTreeMap::new();
    for (i, p) in pat.iter().enumerate() {
        if let Some(name) = p.strip_prefix('*') {
            if i >= segs.len() {
                return None;
            }
            params.insert(name.to_string(), segs[i..].join("/"));
            return Some(params);
        }
        let seg = segs.get(i)?;
        if let Some(name) = p.strip_prefix(':') {
            params.insert(name.to_string(), seg.to_string());
        } else if p != seg {
            return None;
        }
    }
    (pat.len() == segs.len()).then_some(params)
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() => {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 3;
                continue;
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_query(q: &str) -> BTreeMap<String, String> {
    q.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (url_decode(k), url_decode(v))
        })
        .collect()
}

pub fn dispatch(method: &str, target: &str) -> Outcome {
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, parse_query(q)),
        None => (target, BTreeMap::new()),
    };
    let segs = segments(path);
    let mut allowed: Vec<&str> = Vec::new();
    for r in &ROUTES {
        let Some(params) = bind(r.pattern, &segs) else { continue };
        if r.method != method {
            allowed.push(r.method);
            continue;
        }
        if let Some(id) = params.get("id") {
            if id.is_empty() || !id.bytes().all(|c| c.is_ascii_digit()) {
                return Outcome { status: 400, route: r.name, error: "invalid id", ..Default::default() };
            }
        }
        return Outcome { status: 200, route: r.name, params, query, ..Default::default() };
    }
    if !allowed.is_empty() {
        allowed.sort();
        return Outcome { status: 405, allow: allowed.join(","), ..Default::default() };
    }
    Outcome { status: 404, ..Default::default() }
}

fn kv(m: &BTreeMap<String, String>) -> String {
    m.iter().map(|(k, v)| format!("{}={}", k, v)).collect::<Vec<_>>().join(",")
}

pub fn render(method: &str, target: &str) -> String {
    let o = dispatch(method, target);
    let mut out = format!("{} {} -> {}", method, target, o.status);
    if !o.route.is_empty() {
        out += &format!(" route={}", o.route);
    }
    if !o.params.is_empty() {
        out += &format!(" params={}", kv(&o.params));
    }
    if !o.query.is_empty() {
        out += &format!(" query={}", kv(&o.query));
    }
    if !o.error.is_empty() {
        out += &format!(" error={}", o.error);
    }
    if !o.allow.is_empty() {
        out += &format!(" allow={}", o.allow);
    }
    out
}

fn main() {
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
    ];
    for r in reqs {
        let (m, t) = r.split_once(' ').unwrap();
        println!("{}", render(m, t));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching() {
        assert_eq!(dispatch("GET", "/users/12").route, "user_get");
        assert_eq!(dispatch("GET", "//users//12/").status, 200);
        assert_eq!(dispatch("GET", "/users/12/extra").status, 404);
        assert_eq!(dispatch("POST", "/health").allow, "GET");
        assert_eq!(render("GET", "/files/a/b/c"), "GET /files/a/b/c -> 200 route=file_get params=path=a/b/c");
    }

    #[test]
    fn query_decoding() {
        assert_eq!(
            render("GET", "/users?b=2&a=x%41+y"),
            "GET /users?b=2&a=x%41+y -> 200 route=user_list query=a=xA y,b=2"
        );
    }
}
