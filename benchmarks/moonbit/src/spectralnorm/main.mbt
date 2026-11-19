fn fmt_fixed9(v : Double) -> String {
  let neg = v < 0.0
  let av = if neg { -v } else { v }
  let scaled = (av * 1000000000.0 + 0.5).to_int()
  let whole = scaled / 1000000000
  let frac = scaled % 1000000000
  let frac_s = frac.to_string()
  let sb = StringBuilder()
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
  1.0 / (ij * (ij + 1) / 2 + i + 1).to_double()
}

fn eval_a_times_u(n : Int, u : Array[Double], au : Array[Double]) -> Unit {
  for i = 0; i < n; i = i + 1 {
    let mut sum = 0.0
    for j = 0; j < n; j = j + 1 {
      sum = sum + eval_a(i, j) * u[j]
    }
    au[i] = sum
  }
}

fn eval_at_times_u(n : Int, u : Array[Double], au : Array[Double]) -> Unit {
  for i = 0; i < n; i = i + 1 {
    let mut sum = 0.0
    for j = 0; j < n; j = j + 1 {
      sum = sum + eval_a(j, i) * u[j]
    }
    au[i] = sum
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

fn main {
  let n = 2000
  let u = Array::make(n, 1.0)
  let v = Array::make(n, 0.0)
  let tmp = Array::make(n, 0.0)
  for i = 0; i < 10; i = i + 1 {
    eval_ata_times_u(n, u, v, tmp)
    eval_ata_times_u(n, v, u, tmp)
  }
  let mut vbv = 0.0
  let mut vv = 0.0
  for i = 0; i < n; i = i + 1 {
    vbv = vbv + u[i] * v[i]
    vv = vv + v[i] * v[i]
  }
  println(fmt_fixed9((vbv / vv).sqrt()))
}
