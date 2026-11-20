///| t09_ring_parser: incremental frame parser over a 16-byte ring buffer

///|
const CAP : Int = 16

///|
const MAGIC : Int = 0xAA

///|
struct FrameParser {
  buf : FixedArray[Byte]
  mut head : Int
  mut count : Int
  frames : Array[String]
  mut bad_checksum : Int
  mut bad_length : Int
  mut skipped : Int
  mut overflow : Int
}

///|
fn FrameParser::new() -> FrameParser {
  {
    buf: FixedArray::make(CAP, b'\x00'),
    head: 0,
    count: 0,
    frames: [],
    bad_checksum: 0,
    bad_length: 0,
    skipped: 0,
    overflow: 0,
  }
}

///|
fn FrameParser::peek(self : FrameParser, i : Int) -> Int {
  self.buf[(self.head + i) % CAP].to_int()
}

///|
fn FrameParser::drop_front(self : FrameParser, n : Int) -> Unit {
  self.head = (self.head + n) % CAP
  self.count -= n
}

///|
fn hex_byte(v : Int) -> String {
  let digits = "0123456789abcdef"
  "\{digits[v / 16].to_char().unwrap()}\{digits[v % 16].to_char().unwrap()}"
}

///|
fn FrameParser::parse_available(self : FrameParser) -> Unit {
  while self.count > 0 {
    if self.peek(0) != MAGIC {
      self.drop_front(1)
      self.skipped += 1
      continue
    }
    if self.count < 2 {
      return
    }
    let len = self.peek(1)
    if len > 8 {
      self.bad_length += 1
      self.drop_front(1)
      continue
    }
    if self.count < len + 3 {
      return
    }
    let mut sum = 0
    let hex = StringBuilder()
    for i in 0..<len {
      let b = self.peek(2 + i)
      sum += b
      hex.write_string(hex_byte(b))
    }
    if sum % 256 != self.peek(2 + len) {
      self.bad_checksum += 1
      self.drop_front(1)
      continue
    }
    self.frames.push(if len == 0 { "-" } else { hex.to_string() })
    self.drop_front(len + 3)
  }
}

///|
fn FrameParser::feed(self : FrameParser, chunk : ArrayView[Int]) -> Unit {
  for b in chunk {
    if self.count == CAP {
      self.overflow += 1
    } else {
      self.buf[(self.head + self.count) % CAP] = b.to_byte()
      self.count += 1
    }
  }
  self.parse_available()
}

///|
let stream : Array[Int] = [
  1, 2, 0xAA, 3, 0x10, 0x20, 0x30, 0x60, 0xAA, 2, 5, 6, 0, 0xAA, 0, 0, 0xAA, 9, 0xAA,
  4, 0xDE, 0xAD, 0xBE, 0xEF, 0x38, 0xAA, 1, 0xAA, 0xAA, 0xAA, 5, 1, 2,
]

///|
fn run(chunk_size : Int) -> FrameParser {
  let p = FrameParser::new()
  let mut i = 0
  while i < stream.length() {
    let j = if i + chunk_size < stream.length() {
      i + chunk_size
    } else {
      stream.length()
    }
    p.feed(stream[i:j])
    i = j
  }
  p
}

///|
fn summary(p : FrameParser) -> String {
  "ok=\{p.frames.length()} bad_checksum=\{p.bad_checksum} bad_length=\{p.bad_length} skipped=\{p.skipped} pending=\{p.count}"
}

///|
fn main {
  let p = run(5)
  for f in p.frames {
    println("frame \{f}")
  }
  println(summary(p))
}

///|
test "chunking invariance" {
  let a = run(1)
  let b = run(5)
  let c = run(16)
  assert_eq(summary(a), summary(b))
  assert_eq(summary(b), summary(c))
  assert_eq(a.frames, c.frames)
  assert_eq((a.overflow, c.overflow), (0, 0))
}

///|
test "frame details" {
  let p = FrameParser::new()
  p.feed([0xAA, 2, 0xFF, 1])
  assert_eq((p.frames.length(), p.count), (0, 4))
  p.feed([0])
  assert_eq(p.frames, ["ff01"])
}
