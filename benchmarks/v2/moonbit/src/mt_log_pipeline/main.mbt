///| V2 Benchmark 3: mt_log_pipeline (MoonBit, 1-thread baseline with identical chunk/parse/alert pipeline)
///| Usage: mt_log_pipeline <logs.txt> [1]

#borrow(path)
extern "C" fn pion_v2_read_file(path : Bytes) -> Bytes = "pion_v2_read_file"

fn str_to_utf8(s : String) -> Bytes {
  let out : Array[Byte] = []
  let len = s.length()
  for i = 0; i < len; i = i + 1 {
    out.push(s.code_unit_at(i).to_int().to_byte())
  }
  Bytes::from_array(out)
}

fn bytes_slice_ascii(b : Bytes, start : Int, end : Int) -> String {
  let sb = StringBuilder(capacity=end - start)
  for i = start; i < end; i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

fn poly_hash(s : String) -> Int {
  let n = s.length()
  let mut h = 0
  for i = 0; i < n; i = i + 1 {
    h = (h * 31 + s.code_unit_at(i).to_int()) & 0x3fffffff
  }
  h
}

fn poly_hash_slice(s : String, start : Int, end : Int) -> Int {
  let mut h = 0
  for i = start; i < end; i = i + 1 {
    h = (h * 31 + s.code_unit_at(i).to_int()) & 0x3fffffff
  }
  h
}

fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: mt_log_pipeline <logs.txt> [1]")
    return
  }
  let raw = pion_v2_read_file(str_to_utf8(args[1]))
  let total_len = raw.length()

  let svc_lat : Map[String, Int64] = Map([])
  let mut lines = 0
  let mut errs = 0
  let mut slow = 0
  let mut sum_lat : Int64 = 0L
  let mut msg_xor = 0
  let mut alert_cnt = 0
  let mut alert_len_sum : Int64 = 0L
  let mut alert_xor = 0

  let mut pos = 0
  while pos < total_len {
    let cstart = pos
    let mut nl = 0
    while pos < total_len && nl < 10 {
      if raw[pos].to_int() == 10 {
        nl = nl + 1
      }
      pos = pos + 1
    }
    let chunk = bytes_slice_ascii(raw, cstart, pos)
    let cn = chunk.length()
    let mut i = 0
    while i < cn {
      let line_start = i
      while i < cn && chunk.code_unit_at(i).to_int() != 10 {
        i = i + 1
      }
      let line_end = i
      if i < cn && chunk.code_unit_at(i).to_int() == 10 {
        i = i + 1
      }
      if line_end <= line_start {
        continue
      }
      lines = lines + 1
      let mut p = line_start
      while p < line_end && chunk.code_unit_at(p).to_int() != 32 {
        p = p + 1
      }
      if p < line_end { p = p + 1 }
      p = p + 6 // level=
      let lvl_s = p
      while p < line_end && chunk.code_unit_at(p).to_int() != 32 {
        p = p + 1
      }
      let lvl_e = p
      if p < line_end { p = p + 1 }
      p = p + 4 // svc=
      let svc_s = p
      while p < line_end && chunk.code_unit_at(p).to_int() != 32 {
        p = p + 1
      }
      let svc_e = p
      if p < line_end { p = p + 1 }
      p = p + 4 // lat=
      let mut lat = 0
      while p < line_end && chunk.code_unit_at(p).to_int() != 32 {
        lat = lat * 10 + (chunk.code_unit_at(p).to_int() - 48)
        p = p + 1
      }
      if p < line_end { p = p + 1 }
      p = p + 4 // msg=
      let msg_s = p

      let lat64 = lat.to_int64()
      sum_lat = sum_lat + lat64
      let svc = chunk.unsafe_substring(start=svc_s, end=svc_e)
      match svc_lat.get(svc) {
        Some(prev) => svc_lat.set(svc, prev + lat64)
        None => svc_lat.set(svc, lat64)
      }
      msg_xor = msg_xor ^ poly_hash_slice(chunk, msg_s, line_end)

      let is_err = (lvl_e - lvl_s == 3) &&
        chunk.code_unit_at(lvl_s).to_int() == 69 &&
        chunk.code_unit_at(lvl_s + 1).to_int() == 82 &&
        chunk.code_unit_at(lvl_s + 2).to_int() == 82
      let is_slow = lat >= 500
      if is_err { errs = errs + 1 }
      if is_slow { slow = slow + 1 }
      if is_err || is_slow {
        let lvl = chunk.unsafe_substring(start=lvl_s, end=lvl_e)
        let msg = chunk.unsafe_substring(start=msg_s, end=line_end)
        let alert = "ALERT|" + svc + "|" + lvl + "|" + lat.to_string() + "|" + msg
        alert_cnt = alert_cnt + 1
        alert_len_sum = alert_len_sum + alert.length().to_int64()
        alert_xor = alert_xor ^ poly_hash(alert)
      }
    }
  }

  let mut svc_sum : Int64 = 0L
  svc_lat.each(fn(_k, v) { svc_sum = svc_sum + v })
  if svc_sum != sum_lat {
    println("svc_sum mismatch")
    return
  }

  println(
    lines.to_string() +
    " " +
    errs.to_string() +
    " " +
    slow.to_string() +
    " " +
    sum_lat.to_string() +
    " " +
    msg_xor.to_string() +
    " " +
    alert_cnt.to_string() +
    " " +
    alert_len_sum.to_string() +
    " " +
    alert_xor.to_string(),
  )
}
