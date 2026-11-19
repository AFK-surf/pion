///| Benchmarks Game: Spectral Norm (N = 2000) in m2
fn sqrt_d(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut g = if x > 1.0 { x * 0.5 } else { 1.0 }
  let mut i = 0
  while i < 16 {
    g = 0.5 * (g + x / g)
    i = i + 1
  }
  g
}

fn fmt_fixed9(v : Double) -> String {
  let neg = v < 0.0
  let av = if neg { -v } else { v }
  let scaled = (av * 1000000000.0 + 0.5).to_int()
  let whole = scaled / 1000000000
  let frac = scaled % 1000000000
  let frac_s = frac.to_string()
  let sb = StringBuilder::new()
  if neg && scaled != 0 {
    sb.write_char('-')
  }
  sb.write_string(whole.to_string())
  sb.write_char('.')
  let mut pad = 9 - frac_s.length()
  while pad > 0 {
    sb.write_char('0')
    pad = pad - 1
  }
  sb.write_string(frac_s)
  sb.to_string()
}

fn eval_a(i : Int, j : Int) -> Double {
  let ij = i + j
  1.0 / ((ij * (ij + 1) / 2 + i + 1) as Double)
}

fn eval_a_times_u(n : Int, u : Array[Double], au : Array[Double]) -> Unit {
  let mut i = 0
  while i < n {
    let mut sum = 0.0
    let mut j = 0
    while j < n {
      sum = sum + eval_a(i, j) * u[j]
      j = j + 1
    }
    au[i] = sum
    i = i + 1
  }
}

fn eval_at_times_u(n : Int, u : Array[Double], au : Array[Double]) -> Unit {
  let mut i = 0
  while i < n {
    let mut sum = 0.0
    let mut j = 0
    while j < n {
      sum = sum + eval_a(j, i) * u[j]
      j = j + 1
    }
    au[i] = sum
    i = i + 1
  }
}

fn eval_ata_times_u(
  n : Int,
  u : Array[Double],
  atau : Array[Double],
  tmp : Array[Double],
) -> Unit {
  eval_a_times_u(n, u, tmp)
  eval_at_times_u(n, tmp, atau)
}

pub fn main(world : World) -> Int {
  let n = 2000
  let u : Array[Double] = []
  let v : Array[Double] = []
  let tmp : Array[Double] = []
  let mut k = 0
  while k < n {
    u.push(1.0)
    v.push(0.0)
    tmp.push(0.0)
    k = k + 1
  }
  let mut iter = 0
  while iter < 10 {
    eval_ata_times_u(n, u, v, tmp)
    eval_ata_times_u(n, v, u, tmp)
    iter = iter + 1
  }
  let mut vbv = 0.0
  let mut vv = 0.0
  let mut i = 0
  while i < n {
    vbv = vbv + u[i] * v[i]
    vv = vv + v[i] * v[i]
    i = i + 1
  }
  io_println(world, fmt_fixed9(sqrt_d(vbv / vv)))
  0
}
