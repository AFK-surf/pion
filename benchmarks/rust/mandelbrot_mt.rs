use std::thread;

fn compute_stripe(n: usize, y_start: usize, y_end: usize) -> (i32, i32) {
    let inv_n = 2.0 / (n as f64);
    let mut in_set: i32 = 0;
    let mut xhash: i32 = 0;

    for y in y_start..y_end {
        let ci = (y as f64) * inv_n - 1.0;
        let mut row_h: i32 = 0;
        let mut byte_acc: i32 = 0;
        let mut bit_num: i32 = 0;
        for x in 0..n {
            let cr = (x as f64) * inv_n - 1.5;
            let mut zr = 0.0_f64;
            let mut zi = 0.0_f64;
            let mut escaped = false;
            for _ in 0..50 {
                let tr = zr * zr - zi * zi + cr;
                let ti = 2.0 * zr * zi + ci;
                zr = tr;
                zi = ti;
                if zr * zr + zi * zi > 4.0 {
                    escaped = true;
                    break;
                }
            }
            byte_acc = (byte_acc << 1) | if escaped { 0 } else { 1 };
            if !escaped {
                in_set += 1;
            }
            bit_num += 1;
            if bit_num == 8 {
                row_h = (row_h.wrapping_mul(31).wrapping_add(byte_acc)) & 0x3fffffff;
                byte_acc = 0;
                bit_num = 0;
            }
        }
        if bit_num > 0 {
            byte_acc <<= 8 - bit_num;
            row_h = (row_h.wrapping_mul(31).wrapping_add(byte_acc)) & 0x3fffffff;
        }
        let row_mix = (row_h ^ (((y as i32).wrapping_mul(2654435)) & 0x3fffffff)) & 0x3fffffff;
        xhash ^= row_mix;
    }

    (in_set, xhash)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let threads: usize = args
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
        .clamp(1, 64);
    let n: usize = args
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4000);

    if threads == 1 {
        let (in_set, xhash) = compute_stripe(n, 0, n);
        println!("{} {}", in_set, xhash);
        return;
    }

    let mut handles = Vec::with_capacity(threads);
    for t in 0..threads {
        let y_start = (n * t) / threads;
        let y_end = (n * (t + 1)) / threads;
        handles.push(thread::spawn(move || compute_stripe(n, y_start, y_end)));
    }

    let mut total_in_set: i32 = 0;
    let mut total_xhash: i32 = 0;
    for h in handles {
        let (c, x) = h.join().unwrap();
        total_in_set += c;
        total_xhash ^= x;
    }

    println!("{} {}", total_in_set, total_xhash);
}
