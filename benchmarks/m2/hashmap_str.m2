///| Real-world hotspot: String-keyed HashMap (100,000 keys) + StringBuilder checksum in m2
pub fn main(world : World) -> Int {
  let n = 100000
  let m : Map[String, Int] = Map::new()
  let mut i = 0
  while i < n {
    let tag = (i * 2654435) & 0xffff
    let key = "k_" + i.to_string() + "_" + tag.to_string()
    let entry_val = (i * 7 + 13) & 0x3fffffff
    m.set(key, entry_val)
    i = i + 1
  }
  let mut hits = 0
  let mut val_sum = 0
  let mut round = 0
  while round < 2 {
    let mut k = 0
    while k < n {
      let tag = (k * 2654435) & 0xffff
      let key = "k_" + k.to_string() + "_" + tag.to_string()
      match m.get(key) {
        Some(v) => {
          hits = hits + 1
          val_sum = (val_sum + v) & 0x3fffffff
        }
        None => ()
      }
      let miss = "miss_" + k.to_string()
      match m.get(miss) {
        Some(v) => {
          hits = hits + 1
          val_sum = (val_sum + v) & 0x3fffffff
        }
        None => ()
      }
      k = k + 1
    }
    round = round + 1
  }
  let sb = StringBuilder::new()
  let mut j = 0
  while j < n {
    let tag = (j * 2654435) & 0xffff
    let key = "k_" + j.to_string() + "_" + tag.to_string()
    match m.get(key) {
      Some(v) => {
        sb.write_string(key)
        sb.write_char('=')
        sb.write_string(v.to_string())
        sb.write_char(';')
      }
      None => ()
    }
    j = j + 10
  }
  let out = sb.to_string()
  let mut sb_hash = 0
  let mut p = 0
  while p < out.length() {
    let b = out.code_unit_at(p)
    sb_hash = (sb_hash * 31 + b) & 0x3fffffff
    p = p + 1
  }
  io_println(
    world,
    hits.to_string() +
    " " +
    val_sum.to_string() +
    " " +
    out.length().to_string() +
    " " +
    sb_hash.to_string(),
  )
  0
}
