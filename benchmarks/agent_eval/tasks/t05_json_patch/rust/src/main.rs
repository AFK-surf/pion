//! t05_json_patch: RFC 7386 merge patch + validation with `?` chains.
//! Rust's std has no JSON, so this carries a small recursive-descent parser (no crates).
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.pos < self.s.len() && matches!(self.s[self.pos], b' ' | b'\t' | b'\n' | b'\r') {
            self.pos += 1;
        }
    }
    fn peek(&self) -> Option<u8> {
        self.s.get(self.pos).copied()
    }
    fn expect(&mut self, c: u8) -> Result<(), String> {
        self.ws();
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!("expected '{}' at {}", c as char, self.pos))
        }
    }
    fn lit(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.s[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(v)
        } else {
            Err(format!("bad literal at {}", self.pos))
        }
    }
    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            let c = self.peek().ok_or("unterminated string")?;
            self.pos += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let e = self.peek().ok_or("bad escape")?;
                    self.pos += 1;
                    out.push(match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'n' => '\n',
                        b't' => '\t',
                        b'r' => '\r',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'u' => {
                            let hex = std::str::from_utf8(self.s.get(self.pos..self.pos + 4).ok_or("bad \\u")?)
                                .map_err(|e| e.to_string())?;
                            self.pos += 4;
                            char::from_u32(u32::from_str_radix(hex, 16).map_err(|e| e.to_string())?)
                                .ok_or("bad code point")?
                        }
                        _ => return Err("bad escape".into()),
                    });
                }
                _ => {
                    // Copy one UTF-8 sequence verbatim.
                    let start = self.pos - 1;
                    while self.pos < self.s.len() && (self.s[self.pos] & 0xC0) == 0x80 {
                        self.pos += 1;
                    }
                    out.push_str(std::str::from_utf8(&self.s[start..self.pos]).map_err(|e| e.to_string())?);
                }
            }
        }
    }
    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.peek().ok_or("unexpected end")? {
            b'n' => self.lit("null", Json::Null),
            b't' => self.lit("true", Json::Bool(true)),
            b'f' => self.lit("false", Json::Bool(false)),
            b'"' => Ok(Json::Str(self.string()?)),
            b'[' => {
                self.pos += 1;
                let mut items = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.pos += 1;
                    return Ok(Json::Arr(items));
                }
                loop {
                    items.push(self.value()?);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b']') => {
                            self.pos += 1;
                            return Ok(Json::Arr(items));
                        }
                        _ => return Err(format!("expected ',' or ']' at {}", self.pos)),
                    }
                }
            }
            b'{' => {
                self.pos += 1;
                let mut m = BTreeMap::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                    return Ok(Json::Obj(m));
                }
                loop {
                    self.ws();
                    let k = self.string()?;
                    self.expect(b':')?;
                    let v = self.value()?;
                    m.insert(k, v);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b'}') => {
                            self.pos += 1;
                            return Ok(Json::Obj(m));
                        }
                        _ => return Err(format!("expected ',' or '}}' at {}", self.pos)),
                    }
                }
            }
            b'-' | b'0'..=b'9' => {
                let start = self.pos;
                self.pos += 1;
                while self.pos < self.s.len() && self.s[self.pos].is_ascii_digit() {
                    self.pos += 1;
                }
                let txt = std::str::from_utf8(&self.s[start..self.pos]).unwrap();
                txt.parse().map(Json::Int).map_err(|e| e.to_string())
            }
            c => Err(format!("unexpected '{}' at {}", c as char, self.pos)),
        }
    }
}

pub fn parse(src: &str) -> Result<Json, String> {
    let mut p = Parser { s: src.as_bytes(), pos: 0 };
    let v = p.value()?;
    p.ws();
    if p.pos != p.s.len() {
        return Err("trailing data".into());
    }
    Ok(v)
}

pub const BASE: &str = r#"{"server":{"host":"localhost","port":8080,"tls":false},"limits":{"max_conn":100,"timeout_ms":5000},"log":{"level":"info"},"features":["a","b"]}"#;

pub const PATCHES: [&str; 6] = [
    r#"{"server":{"port":9090,"tls":true},"log":{"level":"debug"},"features":["a","b","c"]}"#,
    r#"{"server":{"port":70000},"limits":{"timeout_ms":null}}"#,
    r#"{"server":{"host":null}}"#,
    r#"{"log":{"level":"verbose"},"limits":{"max_conn":0}}"#,
    r#"{"server": {"port": 1}"#,
    r#"{"server":"oops"}"#,
];

/// RFC 7386 JSON merge patch.
pub fn merge_patch(target: &Json, patch: &Json) -> Json {
    match patch {
        Json::Obj(p) => {
            let mut out = match target {
                Json::Obj(t) => t.clone(),
                _ => BTreeMap::new(),
            };
            for (k, v) in p {
                if *v == Json::Null {
                    out.remove(k);
                } else {
                    let merged = merge_patch(out.get(k).unwrap_or(&Json::Null), v);
                    out.insert(k.clone(), merged);
                }
            }
            Json::Obj(out)
        }
        _ => patch.clone(),
    }
}

fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Compact JSON; BTreeMap already keeps keys in byte order.
pub fn canonical(v: &Json) -> String {
    match v {
        Json::Null => "null".into(),
        Json::Bool(b) => b.to_string(),
        Json::Int(n) => n.to_string(),
        Json::Str(s) => quote(s),
        Json::Arr(items) => format!("[{}]", items.iter().map(canonical).collect::<Vec<_>>().join(",")),
        Json::Obj(m) => format!(
            "{{{}}}",
            m.iter().map(|(k, v)| format!("{}:{}", quote(k), canonical(v))).collect::<Vec<_>>().join(",")
        ),
    }
}

fn member<'a>(obj: &'a BTreeMap<String, Json>, key: &str, path: &str) -> Result<&'a Json, String> {
    obj.get(key).ok_or_else(|| format!("{}: missing", path))
}
fn get_obj<'a>(obj: &'a BTreeMap<String, Json>, key: &str, path: &str) -> Result<&'a BTreeMap<String, Json>, String> {
    match member(obj, key, path)? {
        Json::Obj(m) => Ok(m),
        _ => Err(format!("{}: expected object", path)),
    }
}
fn get_str<'a>(obj: &'a BTreeMap<String, Json>, key: &str, path: &str) -> Result<&'a str, String> {
    match member(obj, key, path)? {
        Json::Str(s) => Ok(s),
        _ => Err(format!("{}: expected string", path)),
    }
}
fn get_int(obj: &BTreeMap<String, Json>, key: &str, path: &str) -> Result<i64, String> {
    match member(obj, key, path)? {
        Json::Int(n) => Ok(*n),
        _ => Err(format!("{}: expected int", path)),
    }
}
fn get_bool(obj: &BTreeMap<String, Json>, key: &str, path: &str) -> Result<bool, String> {
    match member(obj, key, path)? {
        Json::Bool(b) => Ok(*b),
        _ => Err(format!("{}: expected bool", path)),
    }
}

pub fn validate(cfg: &Json) -> Result<(), String> {
    let Json::Obj(root) = cfg else {
        return Err("root: expected object".into());
    };
    let server = get_obj(root, "server", "server")?;
    if get_str(server, "host", "server.host")?.is_empty() {
        return Err("server.host: expected string".into());
    }
    let port = get_int(server, "port", "server.port")?;
    if !(1..=65535).contains(&port) {
        return Err(format!("server.port: {} out of range 1..65535", port));
    }
    get_bool(server, "tls", "server.tls")?;
    let limits = get_obj(root, "limits", "limits")?;
    if get_int(limits, "max_conn", "limits.max_conn")? <= 0 {
        return Err("limits.max_conn: must be > 0".into());
    }
    let log = get_obj(root, "log", "log")?;
    match get_str(log, "level", "log.level")? {
        "debug" | "info" | "warn" | "error" => Ok(()),
        other => Err(format!("log.level: invalid value {}", other)),
    }
}

pub fn apply_one(base: &Json, patch_src: &str) -> String {
    match parse(patch_src) {
        Err(_) => "parse error".into(),
        Ok(p) => {
            let merged = merge_patch(base, &p);
            match validate(&merged) {
                Ok(()) => format!("ok: {}", canonical(&merged)),
                Err(m) => format!("invalid: {}", m),
            }
        }
    }
}

fn main() {
    let base = parse(BASE).expect("base parses");
    println!("base: {}", canonical(&base));
    for (i, p) in PATCHES.iter().enumerate() {
        println!("patch{} {}", i + 1, apply_one(&base, p));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_patch_semantics() {
        let t = parse(r#"{"a":{"b":1,"c":2},"d":3}"#).unwrap();
        let p = parse(r#"{"a":{"b":null,"e":[1]},"d":{"x":true}}"#).unwrap();
        assert_eq!(canonical(&merge_patch(&t, &p)), r#"{"a":{"c":2,"e":[1]},"d":{"x":true}}"#);
        assert_eq!(canonical(&merge_patch(&t, &parse("7").unwrap())), "7");
    }

    #[test]
    fn validation_order() {
        let base = parse(BASE).unwrap();
        assert_eq!(apply_one(&base, r#"{"server":{"tls":"yes"}}"#), "invalid: server.tls: expected bool");
        assert_eq!(apply_one(&base, r#"{"log":null}"#), "invalid: log: missing");
        assert_eq!(apply_one(&base, "[1]"), "invalid: root: expected object");
        assert_eq!(
            apply_one(&base, r#"{"server":{"port":0},"log":{"level":"x"}}"#),
            "invalid: server.port: 0 out of range 1..65535"
        );
    }
}
