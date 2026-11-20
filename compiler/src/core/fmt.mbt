///| Canonical, comment-preserving deterministic formatter for m2 / MoonBit (pure m2 ∩ MoonBit)

///|
fn fmt_is_hspace(c : Int) -> Bool {
  c == 32 || c == 9
}

///|
fn fmt_is_opener(c : Int) -> Bool {
  c == 123 || c == 40 || c == 91
}

///|
fn fmt_is_closer(c : Int) -> Bool {
  c == 125 || c == 41 || c == 93
}

///|
fn fmt_write_indent(sb : StringBuilder, level : Int) -> Unit {
  let mut i = 0
  while i < level {
    sb.write_string("  ")
    i = i + 1
  }
}

///|
/// Normalize intra-line horizontal whitespace outside string/char/byte literals
/// and line comments (`//`), collapsing runs of spaces/tabs to a single space
/// while preserving comments and literals verbatim.
fn fmt_normalize_line_body(line : String, start : Int, end : Int) -> String {
  let sb = StringBuilder()
  let utf8 = host_str_is_utf8()
  let mut i = start
  let mut in_space = false
  while i < end {
    let c = str_code_at(line, i)
    // Line comment: copy rest of trimmed line verbatim
    if c == 47 && i + 1 < end && str_code_at(line, i + 1) == 47 {
      if in_space {
        sb.write_char(' ')
        in_space = false
      }
      sb_write_range(sb, line, i, end)
      break
    }
    // String literal "..." or char / byte literal '...' (also covers the
    // '...' part of b'...'): copied verbatim up to the matching quote.
    if c == 34 || c == 39 {
      if in_space {
        sb.write_char(' ')
        in_space = false
      }
      let lit_start = i
      i = i + 1
      while i < end {
        let sc = str_code_at(line, i)
        i = i + 1
        if sc == 92 && i < end {
          i = i + 1
        } else if sc == c {
          break
        }
      }
      sb_write_range(sb, line, lit_start, i)
      continue
    }
    if fmt_is_hspace(c) {
      in_space = true
      i = i + 1
      continue
    }
    if in_space {
      sb.write_char(' ')
      in_space = false
    }
    if c < 0x80 {
      sb.write_char(c.unsafe_to_char())
      i = i + 1
    } else {
      sb.write_char(str_scalar_at(line, i, utf8).unsafe_to_char())
      i = i + str_scalar_len(line, i, utf8)
    }
  }
  sb.to_string()
}

///|
/// Format m2 / MoonBit source code deterministically:
/// - 2-space indentation aligned by `{`/`}`, `(`/`)`, `[`/`]` nesting
/// - strips trailing horizontal whitespace and normalizes CRLF to LF
/// - collapses consecutive blank lines to at most 1 (and strips leading/trailing blanks)
/// - preserves all comments (`//`, `///|`) and string/char/byte literals verbatim
/// - ensures non-empty files end with exactly one trailing newline
/// - strictly idempotent: `format_source(format_source(s)) == format_source(s)`
pub fn format_source(source : String) -> String {
  let len = source.length()
  let out = StringBuilder()
  let opener_indents : Array[Int] = []
  let mut cur_indent = 0
  let mut pending_blank = false
  let mut wrote_any = false

  let mut pos = 0
  while pos < len {
    let line_start = pos
    while pos < len && str_code_at(source, pos) != 10 {
      pos = pos + 1
    }
    let mut line_end = pos
    if pos < len && str_code_at(source, pos) == 10 {
      pos = pos + 1
    }
    // Strip trailing CR / spaces / tabs
    while line_end > line_start {
      let tc = str_code_at(source, line_end - 1)
      if tc == 13 || fmt_is_hspace(tc) {
        line_end = line_end - 1
      } else {
        break
      }
    }
    // Strip leading spaces / tabs
    let mut trim_start = line_start
    while trim_start < line_end && fmt_is_hspace(str_code_at(source, trim_start)) {
      trim_start = trim_start + 1
    }
    if trim_start >= line_end {
      if wrote_any {
        pending_blank = true
      }
      continue
    }

    if pending_blank {
      out.write_char('\n')
      pending_blank = false
    }

    let body = fmt_normalize_line_body(source, trim_start, line_end)
    let blen = body.length()

    // Consume leading closing delimiters (`}`, `)`, `]`) to compute this line's indent
    let mut line_indent = cur_indent
    let mut i = 0
    while i < blen && fmt_is_closer(str_code_at(body, i)) {
      match opener_indents.pop() {
        Some(prev_indent) => line_indent = prev_indent
        None => line_indent = 0
      }
      i = i + 1
    }

    fmt_write_indent(out, line_indent)
    out.write_string(body)
    out.write_char('\n')
    wrote_any = true

    // Scan remaining characters on this line outside literals/comments to update indent stack
    let mut cur_base = line_indent
    let mut opened_unclosed = 0
    while i < blen {
      let c = str_code_at(body, i)
      // Line comment: ignore rest of line for delimiter tracking
      if c == 47 && i + 1 < blen && str_code_at(body, i + 1) == 47 {
        break
      }
      // String literal
      if c == 34 {
        i = i + 1
        while i < blen {
          let sc = str_code_at(body, i)
          i = i + 1
          if sc == 92 && i < blen {
            i = i + 1
          } else if sc == 34 {
            break
          }
        }
        continue
      }
      // Char / byte literal
      if c == 39 {
        i = i + 1
        while i < blen {
          let cc = str_code_at(body, i)
          i = i + 1
          if cc == 92 && i < blen {
            i = i + 1
          } else if cc == 39 {
            break
          }
        }
        continue
      }
      if fmt_is_opener(c) {
        opener_indents.push(cur_base)
        opened_unclosed = opened_unclosed + 1
      } else if fmt_is_closer(c) {
        if opened_unclosed > 0 {
          opened_unclosed = opened_unclosed - 1
          let _ = opener_indents.pop()
        } else {
          match opener_indents.pop() {
            Some(prev_indent) => cur_base = prev_indent
            None => cur_base = 0
          }
        }
      }
      i = i + 1
    }
    if opened_unclosed > 0 {
      cur_indent = cur_base + 1
    } else {
      cur_indent = cur_base
    }
  }

  out.to_string()
}

///|
/// Format `m2c fmt --check --json` output: `{"ok":bool,"unformatted":[...]}`
pub fn fmt_check_result_to_json(unformatted : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"ok\":")
  if unformatted.length() == 0 {
    sb.write_string("true")
  } else {
    sb.write_string("false")
  }
  sb.write_string(",\"unformatted\":[")
  let mut i = 0
  while i < unformatted.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(json_quote(unformatted[i]))
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}
