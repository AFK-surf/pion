fn main {
  let n = 100000
  let m : Map[String, Int] = Map([])
  for i = 0; i < n; i = i + 1 {
    let tag = (i * 2654435) & 0xffff
    let key = "k_" + i.to_string() + "_" + tag.to_string()
    let val = (i * 7 + 13) & 0x3fffffff
    m.set(key, val)
  }
  let mut hits = 0
  let mut val_sum = 0
  for round = 0; round < 2; round = round + 1 {
    for i = 0; i < n; i = i + 1 {
      let tag = (i * 2654435) & 0xffff
      let key = "k_" + i.to_string() + "_" + tag.to_string()
      match m.get(key) {
        Some(v) => {
          hits = hits + 1
          val_sum = (val_sum + v) & 0x3fffffff
        }
        None => ()
      }
      let miss = "miss_" + i.to_string()
      match m.get(miss) {
        Some(v) => {
          hits = hits + 1
          val_sum = (val_sum + v) & 0x3fffffff
        }
        None => ()
      }
    }
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    let tag = (i * 2654435) & 0xffff
    let key = "k_" + i.to_string() + "_" + tag.to_string()
    match m.get(key) {
      Some(v) => {
        sb.write_string(key)
        sb.write_char('=')
        sb.write_string(v.to_string())
        sb.write_char(';')
      }
      None => ()
    }
    i = i + 10
  }
  let out = sb.to_string()
  let mut sb_hash = 0
  for j = 0; j < out.length(); j = j + 1 {
    let b = out.code_unit_at(j).to_int()
    sb_hash = (sb_hash * 31 + b) & 0x3fffffff
  }
  println(
    hits.to_string() +
    " " +
    val_sum.to_string() +
    " " +
    out.length().to_string() +
    " " +
    sb_hash.to_string(),
  )
}
