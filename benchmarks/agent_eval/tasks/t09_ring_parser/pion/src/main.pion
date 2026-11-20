///| t09_ring_parser: incremental frame parser over a 16-byte ring buffer

pub let CAP : Int = 16
pub let MAGIC : Int = 170

pub struct FrameParser {
  buf : Bytes
  mut head : Int
  mut count : Int
  frames : Array[String]
  mut bad_checksum : Int
  mut bad_length : Int
  mut skipped : Int
  mut overflow : Int
}

pub fn new_parser() -> FrameParser {
  FrameParser::{
    buf: Bytes::new(CAP),
    head: 0,
    count: 0,
    frames: [],
    bad_checksum: 0,
    bad_length: 0,
    skipped: 0,
    overflow: 0,
  }
}

fn FrameParser::peek(self : FrameParser, i : Int) -> Int {
  self.buf[(self.head + i) % CAP].to_int()
}

fn FrameParser::drop_front(self : FrameParser, n : Int) -> Unit {
  self.head = (self.head + n) % CAP
  self.count = self.count - n
}

fn hex_byte(v : Int) -> String {
  let digits = "0123456789abcdef"
  digits.slice(v / 16, v / 16 + 1) + digits.slice(v % 16, v % 16 + 1)
}

fn FrameParser::parse_available(self : FrameParser) -> Unit {
  while self.count > 0 {
    if self.peek(0) != MAGIC {
      self.drop_front(1)
      self.skipped = self.skipped + 1
      continue
    }
    if self.count < 2 {
      return
    }
    let len = self.peek(1)
    if len > 8 {
      self.bad_length = self.bad_length + 1
      self.drop_front(1)
      continue
    }
    if self.count < len + 3 {
      return
    }
    let mut sum = 0
    let mut hex = ""
    let mut i = 0
    while i < len {
      let b = self.peek(2 + i)
      sum = sum + b
      hex = hex + hex_byte(b)
      i = i + 1
    }
    if sum % 256 != self.peek(2 + len) {
      self.bad_checksum = self.bad_checksum + 1
      self.drop_front(1)
      continue
    }
    self.frames.push(if len == 0 { "-" } else { hex })
    self.drop_front(len + 3)
  }
}

pub fn FrameParser::feed(self : FrameParser, chunk : Array[Int]) -> Unit {
  for b in chunk {
    if self.count == CAP {
      self.overflow = self.overflow + 1
    } else {
      self.buf[(self.head + self.count) % CAP] = b.to_byte()
      self.count = self.count + 1
    }
  }
  self.parse_available()
}

pub fn stream() -> Array[Int] {
  [
    1, 2,
    170, 3, 16, 32, 48, 96,
    170, 2, 5, 6, 0,
    170, 0, 0,
    170, 9,
    170, 4, 222, 173, 190, 239, 56,
    170, 1, 170, 170,
    170, 5, 1, 2,
  ]
}

pub fn run(chunk_size : Int) -> FrameParser {
  let p = new_parser()
  let data = stream()
  let mut i = 0
  while i < data.length() {
    let chunk : Array[Int] = []
    let mut j = i
    while j < data.length() && j < i + chunk_size {
      chunk.push(data[j])
      j = j + 1
    }
    p.feed(chunk)
    i = j
  }
  p
}

pub fn summary(p : FrameParser) -> String {
  "ok=\{p.frames.length()} bad_checksum=\{p.bad_checksum} bad_length=\{p.bad_length} skipped=\{p.skipped} pending=\{p.count}"
}

pub fn main(world : World) -> Int {
  let p = run(5)
  for f in p.frames {
    io_println(world, "frame " + f)
  }
  io_println(world, summary(p))
  0
}

test "chunking invariance" {
  let a = run(1)
  let b = run(5)
  let c = run(16)
  debug_assert(summary(a) == summary(b) && summary(b) == summary(c), "summaries")
  debug_assert(a.frames.join(",") == c.frames.join(","), "frames")
  debug_assert(a.overflow == 0 && c.overflow == 0, "no overflow")
}

test "frame details" {
  let p = new_parser()
  p.feed([170, 2, 255, 1])
  debug_assert(p.frames.length() == 0 && p.count == 4, "needs checksum byte")
  p.feed([0])
  debug_assert(p.frames.length() == 1 && p.frames[0] == "ff01", "checksum wraps mod 256")
  debug_assert(stream().length() == 33, "stream length")
}
