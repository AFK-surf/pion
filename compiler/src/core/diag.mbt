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
pub struct Diagnostic {
  file : String
  line : Int
  col : Int
  code : String
  message : String
  expected : String
  found : String
  fixit : String
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
  }
}

///|
pub fn str_code_at(s : String, idx : Int) -> Int {
  s[idx].to_int()
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
