use std::collections::HashMap;
use std::fmt::Write;

fn main() {
    let n: i32 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(100_000);

    let mut map: HashMap<String, i32> = HashMap::new();
    for i in 0..n {
        let tag = (i.wrapping_mul(2654435)) & 0xffff;
        let key = format!("k_{}_{}", i, tag);
        let val = (i.wrapping_mul(7).wrapping_add(13)) & 0x3fffffff;
        map.insert(key, val);
    }

    let mut hits: i32 = 0;
    let mut val_sum: i32 = 0;
    for _ in 0..2 {
        for i in 0..n {
            let tag = (i.wrapping_mul(2654435)) & 0xffff;
            let key = format!("k_{}_{}", i, tag);
            if let Some(&v) = map.get(&key) {
                hits += 1;
                val_sum = (val_sum + v) & 0x3fffffff;
            }
            let miss = format!("miss_{}", i);
            if let Some(&v) = map.get(&miss) {
                hits += 1;
                val_sum = (val_sum + v) & 0x3fffffff;
            }
        }
    }

    let mut sb = String::new();
    let mut i = 0;
    while i < n {
        let tag = (i.wrapping_mul(2654435)) & 0xffff;
        let key = format!("k_{}_{}", i, tag);
        if let Some(&v) = map.get(&key) {
            let _ = write!(&mut sb, "{}={};", key, v);
        }
        i += 10;
    }

    let mut sb_hash: i32 = 0;
    for b in sb.as_bytes() {
        sb_hash = (sb_hash.wrapping_mul(31).wrapping_add(*b as i32)) & 0x3fffffff;
    }

    println!("{} {} {} {}", hits, val_sum, sb.len(), sb_hash);
}
