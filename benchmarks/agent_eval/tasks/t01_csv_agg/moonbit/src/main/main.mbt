///| t01_csv_agg: CSV parsing + grouped aggregation

///|
struct RegionAgg {
  region : String
  mut rows : Int
  mut qty : Int
  mut revenue : Int
}

///|
struct Report {
  regions : Array[RegionAgg]
  invalid : Int
}

///|
let sample : String = "region,product,qty,price_cents\nnorth,apple,3,120\nsouth,banana,12,25\n\n north , pear , 2 , 310 \r\neast,kiwi,x,50\nwest,plum,4\nsouth,apple,1,120\neast,grape,10,15\nnorth,apple,-1,120\n   \nwest,fig,0,999\n"

///| Unsigned decimal with 1..9 digits.
fn parse_uint(s : StringView) -> Int? {
  if s.length() == 0 || s.length() > 9 {
    return None
  }
  let mut v = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  Some(v)
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

///|
fn aggregate(csv : String) -> Report {
  let by_region : Map[String, RegionAgg] = Map([])
  let mut invalid = 0
  let mut seen_header = false
  for raw in csv.split("\n") {
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if !seen_header {
      seen_header = true
      continue
    }
    let fields = line.split(",").map(fn(f) { f.trim() }).to_array()
    if fields.length() != 4 {
      invalid += 1
      continue
    }
    match (parse_uint(fields[2]), parse_uint(fields[3])) {
      (Some(q), Some(p)) => {
        let region = fields[0].to_owned()
        let a = match by_region.get(region) {
          Some(a) => a
          None => {
            let a = { region, rows: 0, qty: 0, revenue: 0 }
            by_region[region] = a
            a
          }
        }
        a.rows += 1
        a.qty += q
        a.revenue += q * p
      }
      _ => invalid += 1
    }
  }
  let regions = by_region.values().to_array()
  regions.sort_by(fn(a, b) { byte_compare(a.region, b.region) })
  { regions, invalid }
}

///|
fn format_report(r : Report) -> String {
  let sb = StringBuilder()
  let mut total = 0
  for a in r.regions {
    sb.write_string("\{a.region} rows=\{a.rows} qty=\{a.qty} revenue=\{a.revenue}\n")
    total += a.revenue
  }
  sb.write_string("invalid=\{r.invalid}\ntotal_revenue=\{total}")
  sb.to_string()
}

///|
fn main {
  println(format_report(aggregate(sample)))
}

///|
test "parse_uint" {
  assert_eq(parse_uint("0"), Some(0))
  assert_eq(parse_uint("120"), Some(120))
  assert_eq(parse_uint(""), None)
  assert_eq(parse_uint("-1"), None)
  assert_eq(parse_uint("1x"), None)
  assert_eq(parse_uint("1234567890"), None)
}

///|
test "crlf and header only" {
  let r = aggregate("region,product,qty,price_cents\r\n")
  assert_true(r.regions.length() == 0 && r.invalid == 0)
  let r2 = aggregate("region,product,qty,price_cents\r\na,b,2,5\r\na,c,1,1\r\n")
  assert_eq(r2.regions.length(), 1)
  assert_eq((r2.regions[0].qty, r2.regions[0].revenue), (3, 11))
}

///|
test "sample" {
  let r = aggregate(sample)
  assert_eq(r.invalid, 3)
  assert_eq(r.regions.length(), 4)
  assert_eq(r.regions[1].region, "north")
  assert_eq(r.regions[1].revenue, 980)
  assert_true(format_report(r).has_suffix("total_revenue=1550"))
}
