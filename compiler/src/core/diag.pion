///|
pub struct Span {
  file : String
  line : Int
  col : Int
}

///|
pub fn span_new(file : String, line : Int, col : Int) -> Span {
  Span::{ file: file, line: line, col: col }
}

///|
pub fn span_empty() -> Span {
  Span::{ file: "", line: 0, col: 0 }
}

///|
/// A machine-applicable source patch: replace `[line:col, end_line:end_col)`
/// (1-based, end exclusive; an empty range is an insertion) in `file` with
/// `replacement`.
pub struct TextEdit {
  file : String
  line : Int
  col : Int
  end_line : Int
  end_col : Int
  replacement : String
}

///|
pub fn text_edit_insert(sp : Span, col_delta : Int, text : String) -> TextEdit {
  TextEdit::{
    file: sp.file,
    line: sp.line,
    col: sp.col + col_delta,
    end_line: sp.line,
    end_col: sp.col + col_delta,
    replacement: text,
  }
}

///|
pub struct Diagnostic {
  file : String
  line : Int
  col : Int
  code : String
  message : String
  expected : String
  found : String
  fixit : String
  edits : Array[TextEdit]
}

///|
pub fn diag_new(
  span : Span,
  code : String,
  message : String,
  expected : String,
  found : String,
  fixit : String,
) -> Diagnostic {
  Diagnostic::{
    file: span.file,
    line: span.line,
    col: span.col,
    code: code,
    message: message,
    expected: expected,
    found: found,
    fixit: fixit,
    edits: [],
  }
}

///|
pub fn str_code_at(s : String, idx : Int) -> Int {
  s[idx].to_int()
}

///|
/// True when `String` code units are UTF-8 bytes (Pion Stage 1/2), false when
/// they are UTF-16 units (MoonBit Stage 0). Text handling that goes beyond
/// ASCII must decode scalars with `str_scalar_at` / `str_scalar_len` instead
/// of turning one code unit into one `Char`.
pub fn host_str_is_utf8() -> Bool {
  let sb = StringBuilder()
  sb.write_char((0x4E2D).unsafe_to_char())
  sb.to_string().length() != 1
}

///|
fn utf8_is_cont(s : String, idx : Int) -> Bool {
  idx < s.length() && (str_code_at(s, idx) & 0xC0) == 0x80
}

///|
/// Number of code units of the Unicode scalar starting at `idx` (1 for ASCII,
/// stray or malformed units).
pub fn str_scalar_len(s : String, idx : Int, utf8 : Bool) -> Int {
  let c = str_code_at(s, idx)
  if c < 0x80 {
    return 1
  }
  if utf8 {
    let n = if c >= 0xC2 && c <= 0xDF {
      2
    } else if c >= 0xE0 && c <= 0xEF {
      3
    } else if c >= 0xF0 && c <= 0xF4 {
      4
    } else {
      1
    }
    let mut k = 1
    while k < n {
      if !utf8_is_cont(s, idx + k) {
        return 1
      }
      k = k + 1
    }
    n
  } else if c >= 0xD800 && c <= 0xDBFF && idx + 1 < s.length() {
    let lo = str_code_at(s, idx + 1)
    if lo >= 0xDC00 && lo <= 0xDFFF {
      2
    } else {
      1
    }
  } else {
    1
  }
}

///|
/// Unicode scalar starting at `idx` (U+FFFD for malformed UTF-8 or lone surrogates).
pub fn str_scalar_at(s : String, idx : Int, utf8 : Bool) -> Int {
  let c = str_code_at(s, idx)
  if c < 0x80 {
    return c
  }
  let n = str_scalar_len(s, idx, utf8)
  if utf8 {
    if n == 2 {
      ((c & 0x1F) << 6) | (str_code_at(s, idx + 1) & 0x3F)
    } else if n == 3 {
      ((c & 0x0F) << 12) |
      ((str_code_at(s, idx + 1) & 0x3F) << 6) |
      (str_code_at(s, idx + 2) & 0x3F)
    } else if n == 4 {
      ((c & 0x07) << 18) |
      ((str_code_at(s, idx + 1) & 0x3F) << 12) |
      ((str_code_at(s, idx + 2) & 0x3F) << 6) |
      (str_code_at(s, idx + 3) & 0x3F)
    } else {
      0xFFFD
    }
  } else if n == 2 {
    0x10000 + ((c - 0xD800) << 10) + (str_code_at(s, idx + 1) - 0xDC00)
  } else if c >= 0xD800 && c <= 0xDFFF {
    0xFFFD
  } else {
    c
  }
}

///|
/// Appends `s[start, end)` to `sb` unchanged on both hosts (never one `Char`
/// per UTF-8 byte).
pub fn sb_write_range(sb : StringBuilder, s : String, start : Int, end : Int) -> Unit {
  let mut mode = 0
  let mut i = start
  while i < end {
    let c = str_code_at(s, i)
    if c < 0x80 {
      sb.write_char(c.unsafe_to_char())
      i = i + 1
    } else {
      // Host encoding is probed lazily: ASCII-only ranges (identifiers) stay cheap.
      if mode == 0 {
        mode = if host_str_is_utf8() { 1 } else { 2 }
      }
      let utf8 = mode == 1
      sb.write_char(str_scalar_at(s, i, utf8).unsafe_to_char())
      i = i + str_scalar_len(s, i, utf8)
    }
  }
}

///|
pub fn hex_digit(n : Int) -> Char {
  if n == 0 {
    '0'
  } else if n == 1 {
    '1'
  } else if n == 2 {
    '2'
  } else if n == 3 {
    '3'
  } else if n == 4 {
    '4'
  } else if n == 5 {
    '5'
  } else if n == 6 {
    '6'
  } else if n == 7 {
    '7'
  } else if n == 8 {
    '8'
  } else if n == 9 {
    '9'
  } else if n == 10 {
    'a'
  } else if n == 11 {
    'b'
  } else if n == 12 {
    'c'
  } else if n == 13 {
    'd'
  } else if n == 14 {
    'e'
  } else {
    'f'
  }
}

///|
pub fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  let len = s.length()
  let mut i = 0
  while i < len {
    let ch = str_code_at(s, i)
    if ch == 34 {
      sb.write_string("\\\"")
    } else if ch == 92 {
      sb.write_string("\\\\")
    } else if ch == 10 {
      sb.write_string("\\n")
    } else if ch == 13 {
      sb.write_string("\\r")
    } else if ch == 9 {
      sb.write_string("\\t")
    } else if ch < 32 {
      sb.write_string("\\u00")
      sb.write_char(hex_digit((ch >> 4) & 15))
      sb.write_char(hex_digit(ch & 15))
    } else {
      sb.write_char(ch.unsafe_to_char())
    }
    i = i + 1
  }
  sb.to_string()
}

///|
pub fn json_quote(s : String) -> String {
  "\"" + json_escape(s) + "\""
}

///|
pub fn diagnostic_to_json(d : Diagnostic) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"file\":")
  sb.write_string(json_quote(d.file))
  sb.write_string(",\"line\":")
  sb.write_string(d.line.to_string())
  sb.write_string(",\"col\":")
  sb.write_string(d.col.to_string())
  sb.write_string(",\"code\":")
  sb.write_string(json_quote(d.code))
  sb.write_string(",\"message\":")
  sb.write_string(json_quote(d.message))
  sb.write_string(",\"expected\":")
  sb.write_string(json_quote(d.expected))
  sb.write_string(",\"found\":")
  sb.write_string(json_quote(d.found))
  sb.write_string(",\"fixit\":")
  sb.write_string(json_quote(d.fixit))
  // Only diagnostics with a machine-applicable patch pay for the field.
  if d.edits.length() > 0 {
    sb.write_string(",\"edits\":[")
    let mut i = 0
    while i < d.edits.length() {
      if i > 0 {
        sb.write_string(",")
      }
      let e = d.edits[i]
      sb.write_string("{\"file\":")
      sb.write_string(json_quote(e.file))
      sb.write_string(",\"line\":")
      sb.write_string(e.line.to_string())
      sb.write_string(",\"col\":")
      sb.write_string(e.col.to_string())
      sb.write_string(",\"end_line\":")
      sb.write_string(e.end_line.to_string())
      sb.write_string(",\"end_col\":")
      sb.write_string(e.end_col.to_string())
      sb.write_string(",\"replacement\":")
      sb.write_string(json_quote(e.replacement))
      sb.write_string("}")
      i = i + 1
    }
    sb.write_string("]")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
pub fn check_result_to_json(diags : Array[Diagnostic]) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"ok\":")
  if diags.length() == 0 {
    sb.write_string("true")
  } else {
    sb.write_string("false")
  }
  sb.write_string(",\"diagnostics\":[")
  let mut i = 0
  while i < diags.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(diagnostic_to_json(diags[i]))
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}
