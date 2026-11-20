///| Non-ASCII source text: string, interpolation and char literals keep their
///| UTF-8 bytes through the self-hosted lexer and QBE data emitter.

fn classify(c : Char) -> Int {
  match c {
    '中' => 1
    '🚀' => 2
    _ => 0
  }
}

pub fn main(world : World) -> Int {
  let s = "中文🚀"
  if s.length() != 10 {
    io_eprintln(world, "byte length " + s.length().to_string())
    return 1
  }
  let n = 2
  let t = "共\{n}个键"
  if t.length() != 10 {
    return 2
  }
  let sb = StringBuilder()
  sb.write_char('中')
  sb.write_char('🚀')
  if sb.to_string() != "中🚀" {
    return 3
  }
  if classify('中') != 1 || classify('🚀') != 2 || classify('a') != 0 {
    return 4
  }
  // 你好 = E4 BD A0 E5 A5 BD
  if s.code_unit_at(0) != 0xE4 || "你好".code_unit_at(5) != 0xBD {
    return 5
  }
  io_println(world, "utf8 ok: " + s + " " + t)
  0
}
