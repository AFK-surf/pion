// V2 Benchmark 1: json_query (Rust, pure std, hand-written lexer + recursive-descent AST)
use std::collections::HashMap;
use std::env;
use std::fs;

enum JsonValue {
    Null,
    Bool(bool),
    Int(i32),
    Str(String),
    Arr(Vec<JsonValue>),
    Obj(Vec<(String, JsonValue)>),
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b' ' | b'\n' | b'\r' | b'\t' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn parse_string_raw(&mut self) -> String {
        assert_eq!(self.src[self.pos], b'"');
        self.pos += 1;
        let start = self.pos;
        let mut scan = start;
        let mut has_escape = false;
        while scan < self.src.len() {
            let b = self.src[scan];
            if b == b'"' {
                break;
            }
            if b == b'\\' {
                has_escape = true;
                break;
            }
            scan += 1;
        }
        if !has_escape {
            let s = String::from_utf8(self.src[start..scan].to_vec()).unwrap();
            self.pos = scan + 1;
            return s;
        }
        let mut buf: Vec<u8> = Vec::with_capacity(64);
        while self.pos < self.src.len() {
            let b = self.src[self.pos];
            self.pos += 1;
            if b == b'"' {
                return String::from_utf8(buf).unwrap();
            }
            if b == b'\\' && self.pos < self.src.len() {
                let e = self.src[self.pos];
                self.pos += 1;
                match e {
                    b'"' => buf.push(b'"'),
                    b'\\' => buf.push(b'\\'),
                    b'/' => buf.push(b'/'),
                    b'b' => buf.push(8),
                    b'f' => buf.push(12),
                    b'n' => buf.push(b'\n'),
                    b'r' => buf.push(b'\r'),
                    b't' => buf.push(b'\t'),
                    _ => buf.push(e),
                }
            } else {
                buf.push(b);
            }
        }
        panic!("unterminated string");
    }

    fn parse_array(&mut self) -> JsonValue {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.pos < self.src.len() && self.src[self.pos] == b']' {
            self.pos += 1;
            return JsonValue::Arr(items);
        }
        while self.pos < self.src.len() {
            items.push(self.parse_value());
            self.skip_ws();
            if self.pos < self.src.len() {
                let b = self.src[self.pos];
                if b == b',' {
                    self.pos += 1;
                    self.skip_ws();
                } else if b == b']' {
                    self.pos += 1;
                    return JsonValue::Arr(items);
                } else {
                    panic!("expected ',' or ']'");
                }
            }
        }
        panic!("unterminated array");
    }

    fn parse_object(&mut self) -> JsonValue {
        self.pos += 1; // '{'
        let mut entries = Vec::new();
        self.skip_ws();
        if self.pos < self.src.len() && self.src[self.pos] == b'}' {
            self.pos += 1;
            return JsonValue::Obj(entries);
        }
        while self.pos < self.src.len() {
            self.skip_ws();
            let key = self.parse_string_raw();
            self.skip_ws();
            assert_eq!(self.src[self.pos], b':');
            self.pos += 1;
            let val = self.parse_value();
            entries.push((key, val));
            self.skip_ws();
            if self.pos < self.src.len() {
                let b = self.src[self.pos];
                if b == b',' {
                    self.pos += 1;
                    self.skip_ws();
                } else if b == b'}' {
                    self.pos += 1;
                    return JsonValue::Obj(entries);
                } else {
                    panic!("expected comma or rbrace");
                }
            }
        }
        panic!("unterminated object");
    }

    fn parse_value(&mut self) -> JsonValue {
        self.skip_ws();
        let b = self.src[self.pos];
        match b {
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b'"' => JsonValue::Str(self.parse_string_raw()),
            b't' => {
                self.pos += 4;
                JsonValue::Bool(true)
            }
            b'f' => {
                self.pos += 5;
                JsonValue::Bool(false)
            }
            b'n' => {
                self.pos += 4;
                JsonValue::Null
            }
            _ => {
                let mut neg = false;
                if b == b'-' {
                    neg = true;
                    self.pos += 1;
                }
                let mut acc: i32 = 0;
                while self.pos < self.src.len() {
                    let d = self.src[self.pos];
                    if d >= b'0' && d <= b'9' {
                        acc = acc * 10 + (d - b'0') as i32;
                        self.pos += 1;
                    } else {
                        break;
                    }
                }
                JsonValue::Int(if neg { -acc } else { acc })
            }
        }
    }
}

fn obj_get<'a>(v: &'a JsonValue, key: &str) -> Option<&'a JsonValue> {
    if let JsonValue::Obj(entries) = v {
        for (k, val) in entries {
            if k == key {
                return Some(val);
            }
        }
    }
    None
}

fn push_json_escaped(out: &mut String, s: &str) {
    for b in s.bytes() {
        match b {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            _ => out.push(b as char),
        }
    }
}

fn poly_hash(s: &[u8]) -> i32 {
    let mut h: u32 = 0;
    for &b in s {
        h = (h.wrapping_mul(31).wrapping_add(b as u32)) & 0x3fffffff;
    }
    h as i32
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: {} <dataset.json>", args[0]);
        std::process::exit(2);
    }
    let data = fs::read(&args[1]).expect("read dataset.json");
    let mut parser = Parser { src: &data, pos: 0 };
    let root = parser.parse_value();

    let records = match obj_get(&root, "records") {
        Some(JsonValue::Arr(a)) => a,
        _ => panic!("missing records"),
    };

    let mut role_counts: HashMap<String, i32> = HashMap::new();
    let mut tag_counts: HashMap<String, i32> = HashMap::new();
    let mut out = String::with_capacity(4096);

    let mut total: i32 = 0;
    let mut matched: i32 = 0;
    let mut sum_lat: i32 = 0;

    for rec in records {
        total += 1;
        let user = obj_get(rec, "user").unwrap();
        let metrics = obj_get(rec, "metrics").unwrap();
        let note = match obj_get(rec, "note") {
            Some(JsonValue::Str(s)) => s.as_str(),
            _ => "",
        };
        let id_val = match obj_get(user, "id") {
            Some(JsonValue::Int(v)) => *v,
            _ => 0,
        };
        let role = match obj_get(user, "role") {
            Some(JsonValue::Str(s)) => s.as_str(),
            _ => "",
        };
        let active = match obj_get(user, "active") {
            Some(JsonValue::Bool(b)) => *b,
            _ => false,
        };
        let lat = match obj_get(metrics, "latency_ms") {
            Some(JsonValue::Int(v)) => *v,
            _ => 0,
        };
        let tags = match obj_get(metrics, "tags") {
            Some(JsonValue::Arr(a)) => a,
            _ => panic!("missing tags"),
        };

        if let Some(c) = role_counts.get_mut(role) {
            *c += 1;
        } else {
            role_counts.insert(role.to_string(), 1);
        }

        let mut has_prod = false;
        for tv in tags {
            if let JsonValue::Str(ts) = tv {
                if let Some(c) = tag_counts.get_mut(ts.as_str()) {
                    *c += 1;
                } else {
                    tag_counts.insert(ts.clone(), 1);
                }
                if ts == "prod" {
                    has_prod = true;
                }
            }
        }

        if active && lat >= 150 && has_prod {
            matched += 1;
            sum_lat += lat;
            out.push_str("{\"id\":");
            out.push_str(&id_val.to_string());
            out.push_str(",\"role\":\"");
            push_json_escaped(&mut out, role);
            out.push_str("\",\"lat\":");
            out.push_str(&lat.to_string());
            out.push_str(",\"note\":\"");
            push_json_escaped(&mut out, note);
            out.push_str("\"}\n");
        }
    }

    let mut role_tag_hash: i32 = 0;
    for (k, &v) in &role_counts {
        let kh = poly_hash(k.as_bytes()) as u32;
        let eh = ((kh.wrapping_mul(17).wrapping_add(v as u32)) ^ 0x13579) & 0x3fffffff;
        role_tag_hash ^= eh as i32;
    }
    for (k, &v) in &tag_counts {
        let kh = poly_hash(k.as_bytes()) as u32;
        let eh = ((kh.wrapping_mul(29).wrapping_add(v as u32)) ^ 0x2468a) & 0x3fffffff;
        role_tag_hash ^= eh as i32;
    }

    let out_hash = poly_hash(out.as_bytes());
    println!(
        "{} {} {} {} {} {}",
        total,
        matched,
        sum_lat,
        role_tag_hash,
        out.len(),
        out_hash
    );
}
