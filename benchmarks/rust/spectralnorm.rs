#[inline]
fn eval_a(i: usize, j: usize) -> f64 {
    let ij = i + j;
    1.0 / ((ij * (ij + 1) / 2 + i + 1) as f64)
}

fn eval_a_times_u(u: &[f64], au: &mut [f64]) {
    let n = u.len();
    for i in 0..n {
        let mut sum = 0.0;
        for j in 0..n {
            sum += eval_a(i, j) * u[j];
        }
        au[i] = sum;
    }
}

fn eval_at_times_u(u: &[f64], au: &mut [f64]) {
    let n = u.len();
    for i in 0..n {
        let mut sum = 0.0;
        for j in 0..n {
            sum += eval_a(j, i) * u[j];
        }
        au[i] = sum;
    }
}

fn eval_ata_times_u(u: &[f64], atau: &mut [f64], tmp: &mut [f64]) {
    eval_a_times_u(u, tmp);
    eval_at_times_u(tmp, atau);
}

fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2000);
    let mut u = vec![1.0_f64; n];
    let mut v = vec![0.0_f64; n];
    let mut tmp = vec![0.0_f64; n];
    for _ in 0..10 {
        eval_ata_times_u(&u, &mut v, &mut tmp);
        eval_ata_times_u(&v, &mut u, &mut tmp);
    }
    let mut vbv = 0.0;
    let mut vv = 0.0;
    for i in 0..n {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    println!("{:.9}", (vbv / vv).sqrt());
}
