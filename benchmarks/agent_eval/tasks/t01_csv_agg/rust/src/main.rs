//! t01_csv_agg: CSV parsing + grouped aggregation
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct RegionAgg {
    pub region: String,
    pub rows: i64,
    pub qty: i64,
    pub revenue: i64,
}

#[derive(Debug)]
pub struct Report {
    pub regions: Vec<RegionAgg>,
    pub invalid: i64,
}

pub const SAMPLE: &str = "region,product,qty,price_cents\nnorth,apple,3,120\nsouth,banana,12,25\n\n north , pear , 2 , 310 \r\neast,kiwi,x,50\nwest,plum,4\nsouth,apple,1,120\neast,grape,10,15\nnorth,apple,-1,120\n   \nwest,fig,0,999\n";

/// Unsigned decimal with 1..9 digits.
pub fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || s.len() > 9 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

pub fn aggregate(csv: &str) -> Report {
    let mut by_region: BTreeMap<String, RegionAgg> = BTreeMap::new();
    let mut invalid = 0;
    let mut seen_header = false;
    for raw in csv.split('\n') {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if !seen_header {
            seen_header = true;
            continue;
        }
        let fields: Vec<&str> = line.split(',').map(str::trim).collect();
        if fields.len() != 4 {
            invalid += 1;
            continue;
        }
        match (parse_uint(fields[2]), parse_uint(fields[3])) {
            (Some(q), Some(p)) => {
                let a = by_region
                    .entry(fields[0].to_string())
                    .or_insert_with(|| RegionAgg { region: fields[0].to_string(), rows: 0, qty: 0, revenue: 0 });
                a.rows += 1;
                a.qty += q;
                a.revenue += q * p;
            }
            _ => invalid += 1,
        }
    }
    Report { regions: by_region.into_values().collect(), invalid }
}

pub fn format_report(r: &Report) -> String {
    let mut out = String::new();
    let mut total = 0;
    for a in &r.regions {
        out.push_str(&format!("{} rows={} qty={} revenue={}\n", a.region, a.rows, a.qty, a.revenue));
        total += a.revenue;
    }
    out.push_str(&format!("invalid={}\ntotal_revenue={}", r.invalid, total));
    out
}

fn main() {
    println!("{}", format_report(&aggregate(SAMPLE)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_uint_cases() {
        assert_eq!(parse_uint("0"), Some(0));
        assert_eq!(parse_uint("120"), Some(120));
        assert_eq!(parse_uint(""), None);
        assert_eq!(parse_uint("-1"), None);
        assert_eq!(parse_uint("1x"), None);
        assert_eq!(parse_uint("1234567890"), None);
    }

    #[test]
    fn crlf_and_header_only() {
        let r = aggregate("region,product,qty,price_cents\r\n");
        assert!(r.regions.is_empty() && r.invalid == 0);
        let r2 = aggregate("region,product,qty,price_cents\r\na,b,2,5\r\na,c,1,1\r\n");
        assert_eq!(r2.regions.len(), 1);
        assert_eq!((r2.regions[0].qty, r2.regions[0].revenue), (3, 11));
    }

    #[test]
    fn sample() {
        let r = aggregate(SAMPLE);
        assert_eq!(r.invalid, 3);
        assert_eq!(r.regions.len(), 4);
        assert_eq!((r.regions[1].region.as_str(), r.regions[1].revenue), ("north", 980));
        assert!(format_report(&r).ends_with("total_revenue=1550"));
    }
}
