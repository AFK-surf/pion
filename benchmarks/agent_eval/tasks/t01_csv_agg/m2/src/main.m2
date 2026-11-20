///| t01_csv_agg: CSV parsing + grouped aggregation

pub struct RegionAgg {
  region : String
  mut rows : Int
  mut qty : Int
  mut revenue : Int
}

pub struct Report {
  regions : Array[RegionAgg]
  invalid : Int
}

pub let SAMPLE : String = "region,product,qty,price_cents\nnorth,apple,3,120\nsouth,banana,12,25\n\n north , pear , 2 , 310 \r\neast,kiwi,x,50\nwest,plum,4\nsouth,apple,1,120\neast,grape,10,15\nnorth,apple,-1,120\n   \nwest,fig,0,999\n"

/// Unsigned decimal with 1..9 digits.
pub fn parse_uint(s : String) -> Option[Int] {
  let n = s.length()
  if n == 0 || n > 9 {
    return None
  }
  let mut v = 0
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i)
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10 + (c - 48)
    i = i + 1
  }
  Some(v)
}

pub fn aggregate(csv : String) -> Report {
  let lines = csv.replace("\r\n", "\n").split("\n")
  let index : Map[String, Int] = Map::new()
  let aggs : Array[RegionAgg] = []
  let mut invalid = 0
  let mut seen_header = false
  for raw in lines {
    let line = raw.trim()
    if line.length() == 0 {
      continue
    }
    if !seen_header {
      seen_header = true
      continue
    }
    let fields = line.split(",")
    if fields.length() != 4 {
      invalid = invalid + 1
      continue
    }
    let region = fields[0].trim()
    match (parse_uint(fields[2].trim()), parse_uint(fields[3].trim())) {
      (Some(q), Some(p)) => {
        let idx = match index.get(region) {
          Some(i) => i
          None => {
            aggs.push(RegionAgg::{ region: region, rows: 0, qty: 0, revenue: 0 })
            index.set(region, aggs.length() - 1)
            aggs.length() - 1
          }
        }
        let a = aggs[idx]
        a.rows = a.rows + 1
        a.qty = a.qty + q
        a.revenue = a.revenue + q * p
      }
      _ => invalid = invalid + 1
    }
  }
  let names = index.keys()
  names.sort()
  let sorted : Array[RegionAgg] = []
  for name in names {
    match index.get(name) {
      Some(i) => sorted.push(aggs[i])
      None => ()
    }
  }
  Report::{ regions: sorted, invalid: invalid }
}

pub fn format_report(r : Report) -> String {
  let sb = StringBuilder()
  let mut total = 0
  for a in r.regions {
    sb.write_string("\{a.region} rows=\{a.rows} qty=\{a.qty} revenue=\{a.revenue}\n")
    total = total + a.revenue
  }
  sb.write_string("invalid=\{r.invalid}\ntotal_revenue=\{total}")
  sb.to_string()
}

pub fn main(world : World) -> Int {
  io_println(world, format_report(aggregate(SAMPLE)))
  0
}

// NOTE: `Option == Some(..)` type-checks in m2 today but compares object
// identity (always false for fresh boxes), so tests match explicitly.
fn uint_is(s : String, want : Int) -> Bool {
  match parse_uint(s) {
    Some(v) => v == want
    None => want < 0
  }
}

test "parse_uint" {
  debug_assert(uint_is("0", 0), "zero")
  debug_assert(uint_is("120", 120), "120")
  debug_assert(uint_is("", -1), "empty")
  debug_assert(uint_is("-1", -1), "negative")
  debug_assert(uint_is("1x", -1), "junk")
  debug_assert(uint_is("1234567890", -1), "too long")
}

test "crlf and header only" {
  let r = aggregate("region,product,qty,price_cents\r\n")
  debug_assert(r.regions.length() == 0 && r.invalid == 0, "header only")
  let r2 = aggregate("region,product,qty,price_cents\r\na,b,2,5\r\na,c,1,1\r\n")
  debug_assert(r2.regions.length() == 1, "one region")
  debug_assert(r2.regions[0].qty == 3 && r2.regions[0].revenue == 11, "crlf sums")
}

test "sample" {
  let r = aggregate(SAMPLE)
  debug_assert(r.invalid == 3, "invalid rows")
  debug_assert(r.regions.length() == 4, "regions")
  debug_assert(r.regions[1].region == "north" && r.regions[1].revenue == 980, "north")
  debug_assert(format_report(r).ends_with("total_revenue=1550"), "total")
}
