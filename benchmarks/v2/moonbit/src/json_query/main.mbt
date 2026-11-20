///| V2 Benchmark 1: json_query (MoonBit, hand-written lexer + recursive-descent JSON AST)

#borrow(path)
extern "C" fn m2_v2_read_file(path : Bytes) -> Bytes = "m2_v2_read_file"

fn str_to_utf8(s : String) -> Bytes {
  let out : Array[Byte] = []
  let len = s.length()
  for i = 0; i < len; i = i + 1 {
    out.push(s.code_unit_at(i).to_int().to_byte())
  }
  Bytes::from_array(out)
}

fn bytes_slice_ascii(b : Bytes, start : Int, end : Int) -> String {
  let sb = StringBuilder(capacity=end - start)
  for i = start; i < end; i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

struct JsonEntry {
  key : String
  val : JsonValue
}

enum JsonValue {
  JNull
  JBool(Bool)
  JInt(Int)
  JStr(String)
  JArr(Array[JsonValue])
  JObj(Array[JsonEntry])
}

struct Parser {
  src : Bytes
  len : Int
  mut pos : Int
}

fn skip_ws(p : Parser) -> Unit {
  while p.pos < p.len {
    let c = p.src[p.pos].to_int()
    if c == 32 || c == 10 || c == 13 || c == 9 {
      p.pos = p.pos + 1
    } else {
      break
    }
  }
}

fn parse_string_raw(p : Parser) -> String {
  p.pos = p.pos + 1
  let start = p.pos
  let mut has_escape = false
  let mut scan = start
  while scan < p.len {
    let c = p.src[scan].to_int()
    if c == 34 {
      break
    }
    if c == 92 {
      has_escape = true
      break
    }
    scan = scan + 1
  }
  if !has_escape {
    let s = bytes_slice_ascii(p.src, start, scan)
    p.pos = scan + 1
    return s
  }
  let sb = StringBuilder()
  while p.pos < p.len {
    let c = p.src[p.pos].to_int()
    p.pos = p.pos + 1
    if c == 34 {
      return sb.to_string()
    }
    if c == 92 && p.pos < p.len {
      let e = p.src[p.pos].to_int()
      p.pos = p.pos + 1
      match e {
        34 => sb.write_char('"')
        92 => sb.write_char('\\')
        47 => sb.write_char('/')
        98 => sb.write_char((8).unsafe_to_char())
        102 => sb.write_char((12).unsafe_to_char())
        110 => sb.write_char('\n')
        114 => sb.write_char('\r')
        116 => sb.write_char('\t')
        _ => sb.write_char(e.unsafe_to_char())
      }
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  sb.to_string()
}

fn parse_array(p : Parser) -> JsonValue {
  p.pos = p.pos + 1
  let items : Array[JsonValue] = []
  skip_ws(p)
  if p.pos < p.len && p.src[p.pos].to_int() == 93 {
    p.pos = p.pos + 1
    return JArr(items)
  }
  while p.pos < p.len {
    items.push(parse_value(p))
    skip_ws(p)
    if p.pos < p.len {
      let c = p.src[p.pos].to_int()
      if c == 44 {
        p.pos = p.pos + 1
        skip_ws(p)
      } else if c == 93 {
        p.pos = p.pos + 1
        return JArr(items)
      } else {
        break
      }
    }
  }
  JArr(items)
}

fn parse_object(p : Parser) -> JsonValue {
  p.pos = p.pos + 1
  let entries : Array[JsonEntry] = []
  skip_ws(p)
  if p.pos < p.len && p.src[p.pos].to_int() == 125 {
    p.pos = p.pos + 1
    return JObj(entries)
  }
  while p.pos < p.len {
    skip_ws(p)
    let key = parse_string_raw(p)
    skip_ws(p)
    if p.pos < p.len && p.src[p.pos].to_int() == 58 {
      p.pos = p.pos + 1
    }
    let val = parse_value(p)
    entries.push({ key, val })
    skip_ws(p)
    if p.pos < p.len {
      let c = p.src[p.pos].to_int()
      if c == 44 {
        p.pos = p.pos + 1
        skip_ws(p)
      } else if c == 125 {
        p.pos = p.pos + 1
        return JObj(entries)
      } else {
        break
      }
    }
  }
  JObj(entries)
}

fn parse_value(p : Parser) -> JsonValue {
  skip_ws(p)
  if p.pos >= p.len {
    return JNull
  }
  let c = p.src[p.pos].to_int()
  if c == 123 {
    return parse_object(p)
  }
  if c == 91 {
    return parse_array(p)
  }
  if c == 34 {
    return JStr(parse_string_raw(p))
  }
  if c == 116 {
    p.pos = p.pos + 4
    return JBool(true)
  }
  if c == 102 {
    p.pos = p.pos + 5
    return JBool(false)
  }
  if c == 110 {
    p.pos = p.pos + 4
    return JNull
  }
  let mut neg = false
  if c == 45 {
    neg = true
    p.pos = p.pos + 1
  }
  let mut acc = 0
  while p.pos < p.len {
    let d = p.src[p.pos].to_int()
    if d >= 48 && d <= 57 {
      acc = acc * 10 + (d - 48)
      p.pos = p.pos + 1
    } else {
      break
    }
  }
  if neg { JInt(-acc) } else { JInt(acc) }
}

fn obj_get(obj : JsonValue, key : String) -> JsonValue? {
  match obj {
    JObj(entries) => {
      for i = 0; i < entries.length(); i = i + 1 {
        if entries[i].key == key {
          return Some(entries[i].val)
        }
      }
      None
    }
    _ => None
  }
}

fn map_inc(m : Map[String, Int], k : String) -> Unit {
  match m.get(k) {
    Some(v) => m.set(k, v + 1)
    None => m.set(k, 1)
  }
}

fn write_json_escaped(sb : StringBuilder, s : String) -> Unit {
  let n = s.length()
  for i = 0; i < n; i = i + 1 {
    let c = s.code_unit_at(i).to_int()
    if c == 34 {
      sb.write_string("\\\"")
    } else if c == 92 {
      sb.write_string("\\\\")
    } else if c == 10 {
      sb.write_string("\\n")
    } else if c == 13 {
      sb.write_string("\\r")
    } else if c == 9 {
      sb.write_string("\\t")
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
}

fn poly_hash(s : String) -> Int {
  let n = s.length()
  let mut h = 0
  for i = 0; i < n; i = i + 1 {
    h = (h * 31 + s.code_unit_at(i).to_int()) & 0x3fffffff
  }
  h
}

fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: json_query <dataset.json>")
    return
  }
  let raw = m2_v2_read_file(str_to_utf8(args[1]))
  let p : Parser = { src: raw, len: raw.length(), pos: 0 }
  let root = parse_value(p)
  let records = match obj_get(root, "records") {
    Some(JArr(arr)) => arr
    _ => return
  }

  let role_counts : Map[String, Int] = Map([])
  let tag_counts : Map[String, Int] = Map([])
  let out_sb = StringBuilder()

  let mut total = 0
  let mut matched = 0
  let mut sum_lat = 0

  for i = 0; i < records.length(); i = i + 1 {
    total = total + 1
    let rec = records[i]
    let user = match obj_get(rec, "user") {
      Some(v) => v
      None => JNull
    }
    let metrics = match obj_get(rec, "metrics") {
      Some(v) => v
      None => JNull
    }
    let note = match obj_get(rec, "note") {
      Some(JStr(s)) => s
      _ => ""
    }
    let id_val = match obj_get(user, "id") {
      Some(JInt(v)) => v
      _ => 0
    }
    let role = match obj_get(user, "role") {
      Some(JStr(s)) => s
      _ => ""
    }
    let active = match obj_get(user, "active") {
      Some(JBool(b)) => b
      _ => false
    }
    let lat = match obj_get(metrics, "latency_ms") {
      Some(JInt(v)) => v
      _ => 0
    }
    let tags = match obj_get(metrics, "tags") {
      Some(JArr(a)) => a
      _ => []
    }

    map_inc(role_counts, role)
    let mut has_prod = false
    for t = 0; t < tags.length(); t = t + 1 {
      match tags[t] {
        JStr(ts) => {
          map_inc(tag_counts, ts)
          if ts == "prod" {
            has_prod = true
          }
        }
        _ => ()
      }
    }

    if active && lat >= 150 && has_prod {
      matched = matched + 1
      sum_lat = sum_lat + lat
      out_sb.write_string("{\"id\":")
      out_sb.write_string(id_val.to_string())
      out_sb.write_string(",\"role\":\"")
      write_json_escaped(out_sb, role)
      out_sb.write_string("\",\"lat\":")
      out_sb.write_string(lat.to_string())
      out_sb.write_string(",\"note\":\"")
      write_json_escaped(out_sb, note)
      out_sb.write_string("\"}\n")
    }
  }

  let mut role_tag_hash = 0
  role_counts.each(fn(k, v) {
    let kh = poly_hash(k)
    let eh = ((kh * 17 + v) ^ 0x13579) & 0x3fffffff
    role_tag_hash = role_tag_hash ^ eh
  })
  tag_counts.each(fn(k, v) {
    let kh = poly_hash(k)
    let eh = ((kh * 29 + v) ^ 0x2468a) & 0x3fffffff
    role_tag_hash = role_tag_hash ^ eh
  })

  let out_str = out_sb.to_string()
  let out_hash = poly_hash(out_str)
  println(
    total.to_string() +
    " " +
    matched.to_string() +
    " " +
    sum_lat.to_string() +
    " " +
    role_tag_hash.to_string() +
    " " +
    out_str.length().to_string() +
    " " +
    out_hash.to_string(),
  )
}
