///| Pure Pion ∩ MoonBit SHA-256 + Global Content-Addressed Cache (CAS) & LRU manager

///|
fn ushr32(x : Int, n : Int) -> Int {
  if n <= 0 {
    x
  } else {
    ((x >> 1) & 0x7FFFFFFF) >> (n - 1)
  }
}

///|
fn rotr32(x : Int, n : Int) -> Int {
  ushr32(x, n) | (x << (32 - n))
}

///|
fn sha256_k_table() -> Array[Int] {
  [
    0x428a2f98L.to_int(),
    0x71374491L.to_int(),
    0xb5c0fbcfL.to_int(),
    0xe9b5dba5L.to_int(),
    0x3956c25bL.to_int(),
    0x59f111f1L.to_int(),
    0x923f82a4L.to_int(),
    0xab1c5ed5L.to_int(),
    0xd807aa98L.to_int(),
    0x12835b01L.to_int(),
    0x243185beL.to_int(),
    0x550c7dc3L.to_int(),
    0x72be5d74L.to_int(),
    0x80deb1feL.to_int(),
    0x9bdc06a7L.to_int(),
    0xc19bf174L.to_int(),
    0xe49b69c1L.to_int(),
    0xefbe4786L.to_int(),
    0x0fc19dc6L.to_int(),
    0x240ca1ccL.to_int(),
    0x2de92c6fL.to_int(),
    0x4a7484aaL.to_int(),
    0x5cb0a9dcL.to_int(),
    0x76f988daL.to_int(),
    0x983e5152L.to_int(),
    0xa831c66dL.to_int(),
    0xb00327c8L.to_int(),
    0xbf597fc7L.to_int(),
    0xc6e00bf3L.to_int(),
    0xd5a79147L.to_int(),
    0x06ca6351L.to_int(),
    0x14292967L.to_int(),
    0x27b70a85L.to_int(),
    0x2e1b2138L.to_int(),
    0x4d2c6dfcL.to_int(),
    0x53380d13L.to_int(),
    0x650a7354L.to_int(),
    0x766a0abbL.to_int(),
    0x81c2c92eL.to_int(),
    0x92722c85L.to_int(),
    0xa2bfe8a1L.to_int(),
    0xa81a664bL.to_int(),
    0xc24b8b70L.to_int(),
    0xc76c51a3L.to_int(),
    0xd192e819L.to_int(),
    0xd6990624L.to_int(),
    0xf40e3585L.to_int(),
    0x106aa070L.to_int(),
    0x19a4c116L.to_int(),
    0x1e376c08L.to_int(),
    0x2748774cL.to_int(),
    0x34b0bcb5L.to_int(),
    0x391c0cb3L.to_int(),
    0x4ed8aa4aL.to_int(),
    0x5b9cca4fL.to_int(),
    0x682e6ff3L.to_int(),
    0x748f82eeL.to_int(),
    0x78a5636fL.to_int(),
    0x84c87814L.to_int(),
    0x8cc70208L.to_int(),
    0x90befffaL.to_int(),
    0xa4506cebL.to_int(),
    0xbef9a3f7L.to_int(),
    0xc67178f2L.to_int(),
  ]
}

///|
fn str_to_utf8_ints(s : String) -> Array[Int] {
  let out : Array[Int] = []
  let len = s.length()
  let mut mode = 0
  let mut i = 0
  while i < len {
    let c = str_code_at(s, i)
    if c < 0x80 {
      out.push(c)
      i = i + 1
      continue
    }
    if mode == 0 {
      mode = if host_str_is_utf8() { 1 } else { 2 }
    }
    let utf8 = mode == 1
    // Decode one scalar from the host encoding (UTF-8 bytes in Pion, UTF-16
    // units in MoonBit) and re-encode it, so both hosts emit identical bytes.
    let cp = str_scalar_at(s, i, utf8)
    i = i + str_scalar_len(s, i, utf8)
    if cp >= 0xE080 && cp <= 0xE0FF {
      // Raw byte escape (\x80..\xFF) encoded by lexer as PUA sentinel so
      // Stage 0 (UTF-16 MoonBit) and Stage 1 (UTF-8 Pion) emit identical bytes.
      out.push(cp - 0xE000)
    } else if cp < 0x800 {
      out.push(0xC0 | (cp >> 6))
      out.push(0x80 | (cp & 0x3F))
    } else if cp < 0x10000 {
      out.push(0xE0 | (cp >> 12))
      out.push(0x80 | ((cp >> 6) & 0x3F))
      out.push(0x80 | (cp & 0x3F))
    } else {
      out.push(0xF0 | (cp >> 18))
      out.push(0x80 | ((cp >> 12) & 0x3F))
      out.push(0x80 | ((cp >> 6) & 0x3F))
      out.push(0x80 | (cp & 0x3F))
    }
  }
  out
}

///|
pub fn cas_sha256_hex(s : String) -> String {
  let bytes = str_to_utf8_ints(s)
  let msg_len = bytes.length()
  let bit_len = msg_len.to_int64() * 8L
  bytes.push(0x80)
  while bytes.length() % 64 != 56 {
    bytes.push(0)
  }
  let mut bi = 56
  while bi >= 0 {
    bytes.push(((bit_len >> bi) & 255L).to_int())
    bi = bi - 8
  }

  let k = sha256_k_table()
  let st : Array[Int] = [
    0x6a09e667L.to_int(),
    0xbb67ae85L.to_int(),
    0x3c6ef372L.to_int(),
    0xa54ff53aL.to_int(),
    0x510e527fL.to_int(),
    0x9b05688cL.to_int(),
    0x1f83d9abL.to_int(),
    0x5be0cd19L.to_int(),
  ]
  let w : Array[Int] = []
  let mut wi = 0
  while wi < 64 {
    w.push(0)
    wi = wi + 1
  }

  let mut off = 0
  let total = bytes.length()
  while off < total {
    let mut i = 0
    while i < 16 {
      let b0 = bytes[off + i * 4]
      let b1 = bytes[off + i * 4 + 1]
      let b2 = bytes[off + i * 4 + 2]
      let b3 = bytes[off + i * 4 + 3]
      w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
      i = i + 1
    }
    while i < 64 {
      let w15 = w[i - 15]
      let w2 = w[i - 2]
      let s0 = rotr32(w15, 7) ^ rotr32(w15, 18) ^ ushr32(w15, 3)
      let s1 = rotr32(w2, 17) ^ rotr32(w2, 19) ^ ushr32(w2, 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
      i = i + 1
    }

    let mut a = st[0]
    let mut b = st[1]
    let mut c = st[2]
    let mut d = st[3]
    let mut e = st[4]
    let mut f = st[5]
    let mut g = st[6]
    let mut h = st[7]

    i = 0
    while i < 64 {
      let big_s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let not_e = e ^ -1
      let ch = (e & f) ^ (not_e & g)
      let t1 = h + big_s1 + ch + k[i] + w[i]
      let big_s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let t2 = big_s0 + maj
      h = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
      i = i + 1
    }

    st[0] = st[0] + a
    st[1] = st[1] + b
    st[2] = st[2] + c
    st[3] = st[3] + d
    st[4] = st[4] + e
    st[5] = st[5] + f
    st[6] = st[6] + g
    st[7] = st[7] + h
    off = off + 64
  }

  let sb = StringBuilder()
  let mut si = 0
  while si < 8 {
    let word = st[si]
    let mut shift = 28
    while shift >= 0 {
      let nib = ushr32(word, shift) & 15
      sb.write_char(hex_digit(nib))
      shift = shift - 4
    }
    si = si + 1
  }
  sb.to_string()
}

///|
pub struct CasEntry {
  key : String
  bytes : Int64
  last_access_ms : Int64
}

///|
pub fn pion_compiler_abi_rev() -> String {
  "pionc-v0.14"
}

///|
pub fn cas_compiler_fp(
  qbe_size : Int64,
  rt_size : Int64,
  salt : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string(pion_compiler_abi_rev())
  sb.write_string("|qbe:")
  sb.write_string(qbe_size.to_string())
  sb.write_string("|rt:")
  sb.write_string(rt_size.to_string())
  if salt.length() > 0 {
    sb.write_string("|salt:")
    sb.write_string(salt)
  }
  cas_sha256_hex(sb.to_string())
}

///|
pub fn cas_compute_key(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
  upstream_sigs : Array[String],
  target : String,
  release : Bool,
  compiler_fp : String,
) -> String {
  let fp = if compiler_fp.length() > 0 {
    compiler_fp
  } else {
    pion_compiler_abi_rev()
  }
  let sb = StringBuilder()
  sb.write_string("pion-cas-v2\n")
  sb.write_string("fp:")
  sb.write_string(fp)
  sb.write_string("\npkg:")
  sb.write_string(pkg_name)
  sb.write_string("\ntarget:")
  sb.write_string(target)
  sb.write_string("\nrelease:")
  sb.write_string(if release { "1" } else { "0" })
  sb.write_string("\n")
  let mut i = 0
  while i < upstream_sigs.length() {
    sb.write_string("sig:")
    sb.write_string(upstream_sigs[i].length().to_string())
    sb.write_string(":")
    sb.write_string(upstream_sigs[i])
    sb.write_string("\n")
    i = i + 1
  }
  let mut j = 0
  while j < paths.length() && j < sources.length() {
    sb.write_string("src:")
    sb.write_string(paths[j])
    sb.write_string(":")
    sb.write_string(sources[j].length().to_string())
    sb.write_string(":")
    sb.write_string(sources[j])
    sb.write_string("\n")
    j = j + 1
  }
  cas_sha256_hex(sb.to_string())
}

///|
pub fn cas_compute_unit_key(
  pkg_name : String,
  unit_idx : Int,
  unit_path : String,
  unit_src_hash : String,
  sigs_hash : String,
  target : String,
  release : Bool,
  compiler_fp : String,
) -> String {
  let fp = if compiler_fp.length() > 0 {
    compiler_fp
  } else {
    pion_compiler_abi_rev()
  }
  let sb = StringBuilder()
  sb.write_string("pion-unit-cas-v2\n")
  sb.write_string("fp:")
  sb.write_string(fp)
  sb.write_string("\npkg:")
  sb.write_string(pkg_name)
  sb.write_string("\nidx:")
  sb.write_string(unit_idx.to_string())
  sb.write_string("\npath:")
  sb.write_string(unit_path)
  sb.write_string("\nsigs:")
  sb.write_string(sigs_hash)
  sb.write_string("\ntarget:")
  sb.write_string(target)
  sb.write_string("\nrelease:")
  sb.write_string(if release { "1" } else { "0" })
  sb.write_string("\nsrc:")
  sb.write_string(unit_src_hash)
  sb.write_string("\n")
  cas_sha256_hex(sb.to_string())
}

///|
fn parse_int64_dec(s : String) -> Int64 {
  let len = s.length()
  if len == 0 {
    return 0L
  }
  let mut i = 0
  let mut neg = false
  if str_code_at(s, 0) == 45 {
    neg = true
    i = 1
  }
  let mut acc = 0L
  while i < len {
    let ch = str_code_at(s, i)
    if ch >= 48 && ch <= 57 {
      acc = acc * 10L + (ch - 48).to_int64()
    }
    i = i + 1
  }
  if neg {
    -acc
  } else {
    acc
  }
}

///|
pub fn cas_parse_index(text : String) -> Array[CasEntry] {
  let out : Array[CasEntry] = []
  let lines = split_lines(text)
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if line.length() == 0 {
      i = i + 1
      continue
    }
    let mut tab1 = -1
    let mut tab2 = -1
    let mut j = 0
    while j < line.length() {
      if str_code_at(line, j) == 9 {
        if tab1 < 0 {
          tab1 = j
        } else if tab2 < 0 {
          tab2 = j
          break
        }
      }
      j = j + 1
    }
    if tab1 > 0 && tab2 > tab1 {
      let key = slice_str(line, 0, tab1)
      let bytes_s = slice_str(line, tab1 + 1, tab2)
      let ts_s = slice_str(line, tab2 + 1, line.length())
      out.push(CasEntry::{
        key: key,
        bytes: parse_int64_dec(bytes_s),
        last_access_ms: parse_int64_dec(ts_s),
      })
    }
    i = i + 1
  }
  out
}

///|
pub fn cas_format_index(entries : Array[CasEntry]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < entries.length() {
    let e = entries[i]
    sb.write_string(e.key)
    sb.write_string("\t")
    sb.write_string(e.bytes.to_string())
    sb.write_string("\t")
    sb.write_string(e.last_access_ms.to_string())
    sb.write_string("\n")
    i = i + 1
  }
  sb.to_string()
}

///|
fn cas_entry_older(a : CasEntry, b : CasEntry) -> Bool {
  if a.last_access_ms != b.last_access_ms {
    a.last_access_ms < b.last_access_ms
  } else {
    a.key < b.key
  }
}

///|
fn sort_cas_entries_lru(entries : Array[CasEntry]) -> Unit {
  let n = entries.length()
  let mut i = 1
  while i < n {
    let cur = entries[i]
    let mut j = i - 1
    while j >= 0 && cas_entry_older(cur, entries[j]) {
      entries[j + 1] = entries[j]
      j = j - 1
    }
    entries[j + 1] = cur
    i = i + 1
  }
}

///|
pub struct CasEvictResult {
  kept : Array[CasEntry]
  evicted : Array[String]
}

///|
pub fn cas_touch_and_evict(
  entries : Array[CasEntry],
  key : String,
  bytes : Int64,
  now_ms : Int64,
  max_bytes : Int64,
) -> CasEvictResult {
  let updated : Array[CasEntry] = []
  let mut found = false
  let mut i = 0
  while i < entries.length() {
    let e = entries[i]
    if e.key == key {
      updated.push(CasEntry::{
        key: key,
        bytes: bytes,
        last_access_ms: now_ms,
      })
      found = true
    } else {
      updated.push(e)
    }
    i = i + 1
  }
  if !found {
    updated.push(CasEntry::{
      key: key,
      bytes: bytes,
      last_access_ms: now_ms,
    })
  }

  let mut total = 0L
  i = 0
  while i < updated.length() {
    total = total + updated[i].bytes
    i = i + 1
  }

  let evicted : Array[String] = []
  if max_bytes <= 0L || total <= max_bytes {
    return CasEvictResult::{ kept: updated, evicted: evicted }
  }

  sort_cas_entries_lru(updated)
  let watermark = (max_bytes * 80L) / 100L
  let kept : Array[CasEntry] = []
  i = 0
  while i < updated.length() {
    let e = updated[i]
    if total > watermark && e.key != key {
      total = total - e.bytes
      evicted.push(e.key)
    } else {
      kept.push(e)
    }
    i = i + 1
  }
  CasEvictResult::{ kept: kept, evicted: evicted }
}
