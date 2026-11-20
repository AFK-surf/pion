//! t09_ring_parser: incremental frame parser over a 16-byte ring buffer

pub const CAP: usize = 16;
pub const MAGIC: u8 = 0xAA;

#[derive(Default)]
pub struct FrameParser {
    buf: [u8; CAP],
    head: usize,
    pub count: usize,
    pub frames: Vec<String>,
    pub bad_checksum: u32,
    pub bad_length: u32,
    pub skipped: u32,
    pub overflow: u32,
}

impl FrameParser {
    fn peek(&self, i: usize) -> u8 {
        self.buf[(self.head + i) % CAP]
    }

    fn drop_front(&mut self, n: usize) {
        self.head = (self.head + n) % CAP;
        self.count -= n;
    }

    fn parse_available(&mut self) {
        while self.count > 0 {
            if self.peek(0) != MAGIC {
                self.drop_front(1);
                self.skipped += 1;
                continue;
            }
            if self.count < 2 {
                return;
            }
            let len = self.peek(1) as usize;
            if len > 8 {
                self.bad_length += 1;
                self.drop_front(1);
                continue;
            }
            if self.count < len + 3 {
                return;
            }
            let payload: Vec<u8> = (0..len).map(|i| self.peek(2 + i)).collect();
            let sum = payload.iter().fold(0u8, |a, &b| a.wrapping_add(b));
            if sum != self.peek(2 + len) {
                self.bad_checksum += 1;
                self.drop_front(1);
                continue;
            }
            let hex: String = payload.iter().map(|b| format!("{:02x}", b)).collect();
            self.frames.push(if len == 0 { "-".to_string() } else { hex });
            self.drop_front(len + 3);
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) {
        for &b in chunk {
            if self.count == CAP {
                self.overflow += 1;
            } else {
                self.buf[(self.head + self.count) % CAP] = b;
                self.count += 1;
            }
        }
        self.parse_available();
    }
}

pub const STREAM: [u8; 33] = [
    1, 2, //
    0xAA, 3, 0x10, 0x20, 0x30, 0x60, //
    0xAA, 2, 5, 6, 0, //
    0xAA, 0, 0, //
    0xAA, 9, //
    0xAA, 4, 0xDE, 0xAD, 0xBE, 0xEF, 0x38, //
    0xAA, 1, 0xAA, 0xAA, //
    0xAA, 5, 1, 2,
];

pub fn run(chunk_size: usize) -> FrameParser {
    let mut p = FrameParser::default();
    for chunk in STREAM.chunks(chunk_size) {
        p.feed(chunk);
    }
    p
}

pub fn summary(p: &FrameParser) -> String {
    format!(
        "ok={} bad_checksum={} bad_length={} skipped={} pending={}",
        p.frames.len(),
        p.bad_checksum,
        p.bad_length,
        p.skipped,
        p.count
    )
}

fn main() {
    let p = run(5);
    for f in &p.frames {
        println!("frame {}", f);
    }
    println!("{}", summary(&p));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunking_invariance() {
        let (a, b, c) = (run(1), run(5), run(16));
        assert_eq!(summary(&a), summary(&b));
        assert_eq!(summary(&b), summary(&c));
        assert_eq!(a.frames, c.frames);
        assert_eq!((a.overflow, c.overflow), (0, 0));
    }

    #[test]
    fn frame_details() {
        let mut p = FrameParser::default();
        p.feed(&[0xAA, 2, 0xFF, 1]);
        assert_eq!((p.frames.len(), p.count), (0, 4));
        p.feed(&[0]);
        assert_eq!(p.frames, vec!["ff01".to_string()]);
    }
}
