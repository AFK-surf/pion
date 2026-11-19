fn main {
  let n = 4000
  let inv_n = 2.0 / n.to_double()
  let mut in_set = 0
  let mut xhash = 0
  for y = 0; y < n; y = y + 1 {
    let ci = y.to_double() * inv_n - 1.0
    let mut row_h = 0
    let mut byte_acc = 0
    let mut bit_num = 0
    for x = 0; x < n; x = x + 1 {
      let cr = x.to_double() * inv_n - 1.5
      let mut zr = 0.0
      let mut zi = 0.0
      let mut escaped = false
      for iter = 0; iter < 50; iter = iter + 1 {
        let tr = zr * zr - zi * zi + cr
        let ti = 2.0 * zr * zi + ci
        zr = tr
        zi = ti
        if zr * zr + zi * zi > 4.0 {
          escaped = true
          break
        }
      }
      byte_acc = (byte_acc << 1) | (if escaped { 0 } else { 1 })
      if !escaped {
        in_set = in_set + 1
      }
      bit_num = bit_num + 1
      if bit_num == 8 {
        row_h = (row_h * 31 + byte_acc) & 0x3fffffff
        byte_acc = 0
        bit_num = 0
      }
    }
    if bit_num > 0 {
      byte_acc = byte_acc << (8 - bit_num)
      row_h = (row_h * 31 + byte_acc) & 0x3fffffff
    }
    let row_mix = (row_h ^ ((y * 2654435) & 0x3fffffff)) & 0x3fffffff
    xhash = xhash ^ row_mix
  }
  println(in_set.to_string() + " " + xhash.to_string())
}
