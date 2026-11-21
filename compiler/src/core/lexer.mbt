///|
pub enum TokenKind {
  IntLit(String)
  Int64Lit(String)
  DoubleLit(String)
  StringLit(String)
  InterpStart(String)
  InterpMid(String)
  InterpEnd(String)
  CharLit(String)
  ByteLit(String)
  BoolLit(Bool)
  Ident(String)
  KwFn
  KwPub
  KwStruct
  KwEnum
  KwLet
  KwMut
  KwIf
  KwElse
  KwMatch
  KwWhile
  KwFor
  KwIn
  KwBreak
  KwContinue
  KwReturn
  KwAs
  KwVal
  KwMove
  KwScope
  KwSpawn
  KwDebugAssert
  KwType
  KwImport
  KwExtern
  KwTrait
  KwImpl
  LParen
  RParen
  LBrace
  RBrace
  LBracket
  RBracket
  Comma
  Semi
  Colon
  ColonColon
  Dot
  DotDot
  Ellipsis
  Question
  Arrow
  FatArrow
  Plus
  Minus
  Star
  Slash
  Percent
  Eq
  EqEq
  BangEq
  Lt
  LtEq
  Gt
  GtEq
  AmpAmp
  PipePipe
  Bang
  Amp
  Pipe
  Caret
  LtLt
  GtGt
  Eof
  Invalid(String)
}

///|
pub struct Token {
  kind : TokenKind
  span : Span
  raw : String
  newline_before : Bool
}

///|
pub struct LexResult {
  tokens : Array[Token]
  diagnostics : Array[Diagnostic]
}

///|
fn is_ident_start(ch : Int) -> Bool {
  (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95
}

///|
fn is_ident_part(ch : Int) -> Bool {
  is_ident_start(ch) || (ch >= 48 && ch <= 57)
}

///|
fn is_digit(ch : Int) -> Bool {
  ch >= 48 && ch <= 57
}

///|
fn is_hex_digit(ch : Int) -> Bool {
  (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 70) || (ch >= 97 && ch <= 102)
}

///|
fn keyword_or_ident(word : String) -> TokenKind {
  if word == "fn" {
    KwFn
  } else if word == "pub" {
    KwPub
  } else if word == "struct" {
    KwStruct
  } else if word == "enum" {
    KwEnum
  } else if word == "let" {
    KwLet
  } else if word == "mut" {
    KwMut
  } else if word == "if" {
    KwIf
  } else if word == "else" {
    KwElse
  } else if word == "match" {
    KwMatch
  } else if word == "while" {
    KwWhile
  } else if word == "for" {
    KwFor
  } else if word == "in" {
    KwIn
  } else if word == "break" {
    KwBreak
  } else if word == "continue" {
    KwContinue
  } else if word == "return" {
    KwReturn
  } else if word == "true" {
    BoolLit(true)
  } else if word == "false" {
    BoolLit(false)
  } else if word == "as" {
    KwAs
  } else if word == "val" {
    KwVal
  } else if word == "move" {
    KwMove
  } else if word == "scope" {
    KwScope
  } else if word == "spawn" {
    KwSpawn
  } else if word == "debug_assert" {
    KwDebugAssert
  } else if word == "type" {
    KwType
  } else if word == "import" {
    KwImport
  } else if word == "extern" {
    KwExtern
  } else if word == "trait" {
    KwTrait
  } else if word == "impl" {
    KwImpl
  } else {
    Ident(word)
  }
}

///|
fn slice_str(s : String, start : Int, end_pos : Int) -> String {
  let sb = StringBuilder()
  sb_write_range(sb, s, start, end_pos)
  sb.to_string()
}

///|
pub fn lex(file : String, source : String) -> LexResult {
  let utf8 = host_str_is_utf8()
  let tokens : Array[Token] = []
  let diags : Array[Diagnostic] = []
  let len = source.length()
  let mut pos = 0
  let mut line = 1
  let mut col = 1
  let mut saw_newline = true
  let interp_depths : Array[Int] = []

  while pos < len {
    let ch = str_code_at(source, pos)

    // Whitespace
    if ch == 32 || ch == 9 || ch == 13 {
      pos = pos + 1
      col = col + 1
      continue
    }
    if ch == 10 {
      pos = pos + 1
      line = line + 1
      col = 1
      saw_newline = true
      continue
    }

    // Line comment (including ///|)
    if ch == 47 && pos + 1 < len && str_code_at(source, pos + 1) == 47 {
      pos = pos + 2
      col = col + 2
      while pos < len && str_code_at(source, pos) != 10 {
        pos = pos + 1
        col = col + 1
      }
      continue
    }

    let start_line = line
    let start_col = col
    let start_pos = pos
    let nl = saw_newline
    saw_newline = false

    // Byte literal: b'a', b'\n', b'\x00'
    if ch == 98 && pos + 1 < len && str_code_at(source, pos + 1) == 39 {
      pos = pos + 2
      col = col + 2
      let sb = StringBuilder()
      let mut closed = false
      while pos < len {
        let c = str_code_at(source, pos)
        if c == 10 {
          break
        }
        if c == 39 {
          pos = pos + 1
          col = col + 1
          closed = true
          break
        }
        if c == 92 && pos + 1 < len {
          let next_c = str_code_at(source, pos + 1)
          sb.write_char(c.unsafe_to_char())
          sb.write_char(next_c.unsafe_to_char())
          pos = pos + 2
          col = col + 2
        } else {
          let un = str_scalar_len(source, pos, utf8)
          sb.write_char(str_scalar_at(source, pos, utf8).unsafe_to_char())
          pos = pos + un
          col = col + 1
        }
      }
      let sp = span_new(file, start_line, start_col)
      let raw = slice_str(source, start_pos, pos)
      if closed {
        tokens.push(Token::{
          kind: ByteLit(sb.to_string()),
          span: sp,
          raw: raw,
          newline_before: nl,
        })
      } else {
        diags.push(
          diag_new(
            sp,
            "E_PARSE",
            "unterminated byte literal",
            "closing `'`",
            "end of line",
            "close the byte literal with `'`",
          ),
        )
      }
      continue
    }

    // Char literal: 'a', '\n'
    if ch == 39 {
      pos = pos + 1
      col = col + 1
      let sb = StringBuilder()
      let mut closed = false
      while pos < len {
        let c = str_code_at(source, pos)
        if c == 10 {
          break
        }
        if c == 39 {
          pos = pos + 1
          col = col + 1
          closed = true
          break
        }
        if c == 92 && pos + 1 < len {
          let next_c = str_code_at(source, pos + 1)
          sb.write_char(c.unsafe_to_char())
          sb.write_char(next_c.unsafe_to_char())
          pos = pos + 2
          col = col + 2
        } else {
          let un = str_scalar_len(source, pos, utf8)
          sb.write_char(str_scalar_at(source, pos, utf8).unsafe_to_char())
          pos = pos + un
          col = col + 1
        }
      }
      let sp = span_new(file, start_line, start_col)
      let raw = slice_str(source, start_pos, pos)
      if closed {
        tokens.push(Token::{
          kind: CharLit(sb.to_string()),
          span: sp,
          raw: raw,
          newline_before: nl,
        })
      } else {
        diags.push(
          diag_new(
            sp,
            "E_PARSE",
            "unterminated char literal",
            "closing `'`",
            "end of line",
            "close the char literal with `'`",
          ),
        )
      }
      continue
    }

    // String literal: "..." or interpolated "...\{expr}..."
    if ch == 34 {
      pos = pos + 1
      col = col + 1
      let sb = StringBuilder()
      let mut closed = false
      let mut hit_interp = false
      while pos < len {
        let c = str_code_at(source, pos)
        if c == 10 {
          break
        }
        if c == 34 {
          pos = pos + 1
          col = col + 1
          closed = true
          break
        }
        if c == 92 && pos + 1 < len {
          let next_c = str_code_at(source, pos + 1)
          if next_c == 123 {
            pos = pos + 2
            col = col + 2
            hit_interp = true
            break
          }
          if next_c == 110 {
            sb.write_char('\n')
          } else if next_c == 114 {
            sb.write_char('\r')
          } else if next_c == 116 {
            sb.write_char('\t')
          } else if next_c == 92 {
            sb.write_char('\\')
          } else if next_c == 34 {
            sb.write_char('"')
          } else if next_c == 48 {
            let nul = 0
            sb.write_char(nul.unsafe_to_char())
          } else {
            sb.write_char(next_c.unsafe_to_char())
          }
          pos = pos + 2
          col = col + 2
        } else {
          let un = str_scalar_len(source, pos, utf8)
          sb.write_char(str_scalar_at(source, pos, utf8).unsafe_to_char())
          pos = pos + un
          col = col + 1
        }
      }
      let sp = span_new(file, start_line, start_col)
      let raw = slice_str(source, start_pos, pos)
      if hit_interp {
        interp_depths.push(0)
        tokens.push(Token::{
          kind: InterpStart(sb.to_string()),
          span: sp,
          raw: raw,
          newline_before: nl,
        })
      } else if closed {
        tokens.push(Token::{
          kind: StringLit(sb.to_string()),
          span: sp,
          raw: raw,
          newline_before: nl,
        })
      } else {
        diags.push(
          diag_new(
            sp,
            "E_PARSE",
            "unterminated string literal",
            "closing `\"`",
            "end of line",
            "close the string literal with `\"`",
          ),
        )
      }
      continue
    }

    // Closing `}` of a string interpolation segment resumes scanning the string
    if ch == 125 && interp_depths.length() > 0 {
      let top_idx = interp_depths.length() - 1
      if interp_depths[top_idx] == 0 {
        pos = pos + 1
        col = col + 1
        let sb = StringBuilder()
        let mut closed = false
        let mut hit_interp = false
        while pos < len {
          let c = str_code_at(source, pos)
          if c == 10 {
            break
          }
          if c == 34 {
            pos = pos + 1
            col = col + 1
            closed = true
            break
          }
          if c == 92 && pos + 1 < len {
            let next_c = str_code_at(source, pos + 1)
            if next_c == 123 {
              pos = pos + 2
              col = col + 2
              hit_interp = true
              break
            }
            if next_c == 110 {
              sb.write_char('\n')
            } else if next_c == 114 {
              sb.write_char('\r')
            } else if next_c == 116 {
              sb.write_char('\t')
            } else if next_c == 92 {
              sb.write_char('\\')
            } else if next_c == 34 {
              sb.write_char('"')
            } else if next_c == 48 {
              let nul = 0
              sb.write_char(nul.unsafe_to_char())
            } else {
              sb.write_char(next_c.unsafe_to_char())
            }
            pos = pos + 2
            col = col + 2
          } else {
            let un = str_scalar_len(source, pos, utf8)
            sb.write_char(str_scalar_at(source, pos, utf8).unsafe_to_char())
            pos = pos + un
            col = col + 1
          }
        }
        let sp = span_new(file, start_line, start_col)
        let raw = slice_str(source, start_pos, pos)
        if hit_interp {
          tokens.push(Token::{
            kind: InterpMid(sb.to_string()),
            span: sp,
            raw: raw,
            newline_before: nl,
          })
        } else if closed {
          let _ = interp_depths.pop()
          tokens.push(Token::{
            kind: InterpEnd(sb.to_string()),
            span: sp,
            raw: raw,
            newline_before: nl,
          })
        } else {
          let _ = interp_depths.pop()
          diags.push(
            diag_new(
              sp,
              "E_PARSE",
              "unterminated interpolated string literal",
              "closing `\"`",
              "end of line",
              "close the string literal with `\"`",
            ),
          )
        }
        continue
      }
    }

    // Identifiers and keywords
    if is_ident_start(ch) {
      pos = pos + 1
      col = col + 1
      while pos < len && is_ident_part(str_code_at(source, pos)) {
        pos = pos + 1
        col = col + 1
      }
      let word = slice_str(source, start_pos, pos)
      let sp = span_new(file, start_line, start_col)
      tokens.push(Token::{
        kind: keyword_or_ident(word),
        span: sp,
        raw: word,
        newline_before: nl,
      })
      continue
    }

    // Numbers: decimal, hex 0x..., Int64 ...L, Double ... . ...
    if is_digit(ch) {
      if ch == 48 &&
        pos + 1 < len &&
        (str_code_at(source, pos + 1) == 120 || str_code_at(source, pos + 1) == 88) {
        pos = pos + 2
        col = col + 2
        while pos < len &&
          (is_hex_digit(str_code_at(source, pos)) || str_code_at(source, pos) == 95) {
          pos = pos + 1
          col = col + 1
        }
        let mut is_i64 = false
        if pos < len && str_code_at(source, pos) == 76 {
          is_i64 = true
          pos = pos + 1
          col = col + 1
        }
        let raw = slice_str(source, start_pos, pos)
        let sp = span_new(file, start_line, start_col)
        let k = if is_i64 { Int64Lit(raw) } else { IntLit(raw) }
        tokens.push(Token::{ kind: k, span: sp, raw: raw, newline_before: nl })
        continue
      }
      pos = pos + 1
      col = col + 1
      while pos < len &&
        (is_digit(str_code_at(source, pos)) || str_code_at(source, pos) == 95) {
        pos = pos + 1
        col = col + 1
      }
      let mut is_double = false
      if pos + 1 < len &&
        str_code_at(source, pos) == 46 &&
        is_digit(str_code_at(source, pos + 1)) {
        is_double = true
        pos = pos + 1
        col = col + 1
        while pos < len &&
          (is_digit(str_code_at(source, pos)) || str_code_at(source, pos) == 95) {
          pos = pos + 1
          col = col + 1
        }
      }
      let mut is_i64 = false
      if !is_double && pos < len && str_code_at(source, pos) == 76 {
        is_i64 = true
        pos = pos + 1
        col = col + 1
      }
      let raw = slice_str(source, start_pos, pos)
      let sp = span_new(file, start_line, start_col)
      let k = if is_double {
        DoubleLit(raw)
      } else if is_i64 {
        Int64Lit(raw)
      } else {
        IntLit(raw)
      }
      tokens.push(Token::{ kind: k, span: sp, raw: raw, newline_before: nl })
      continue
    }

    // Three-char and two-char operators
    let sp = span_new(file, start_line, start_col)
    if pos + 2 < len &&
      ch == 46 &&
      str_code_at(source, pos + 1) == 46 &&
      str_code_at(source, pos + 2) == 46 {
      pos = pos + 3
      col = col + 3
      tokens.push(Token::{ kind: Ellipsis, span: sp, raw: "...", newline_before: nl })
      continue
    }
    if pos + 1 < len {
      let c2 = str_code_at(source, pos + 1)
      if ch == 46 && c2 == 46 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: DotDot, span: sp, raw: "..", newline_before: nl })
        continue
      }
      if ch == 58 && c2 == 58 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: ColonColon, span: sp, raw: "::", newline_before: nl })
        continue
      }
      if ch == 45 && c2 == 62 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: Arrow, span: sp, raw: "->", newline_before: nl })
        continue
      }
      if ch == 61 && c2 == 62 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: FatArrow, span: sp, raw: "=>", newline_before: nl })
        continue
      }
      if ch == 61 && c2 == 61 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: EqEq, span: sp, raw: "==", newline_before: nl })
        continue
      }
      if ch == 33 && c2 == 61 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: BangEq, span: sp, raw: "!=", newline_before: nl })
        continue
      }
      if ch == 60 && c2 == 61 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: LtEq, span: sp, raw: "<=", newline_before: nl })
        continue
      }
      if ch == 62 && c2 == 61 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: GtEq, span: sp, raw: ">=", newline_before: nl })
        continue
      }
      if ch == 38 && c2 == 38 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: AmpAmp, span: sp, raw: "&&", newline_before: nl })
        continue
      }
      if ch == 124 && c2 == 124 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: PipePipe, span: sp, raw: "||", newline_before: nl })
        continue
      }
      if ch == 60 && c2 == 60 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: LtLt, span: sp, raw: "<<", newline_before: nl })
        continue
      }
      if ch == 62 && c2 == 62 {
        pos = pos + 2
        col = col + 2
        tokens.push(Token::{ kind: GtGt, span: sp, raw: ">>", newline_before: nl })
        continue
      }
    }

    // Single-char tokens
    pos = pos + 1
    col = col + 1
    let one = slice_str(source, start_pos, pos)
    let tok_kind = if ch == 40 {
      LParen
    } else if ch == 41 {
      RParen
    } else if ch == 123 {
      if interp_depths.length() > 0 {
        let top_idx = interp_depths.length() - 1
        interp_depths[top_idx] = interp_depths[top_idx] + 1
      }
      LBrace
    } else if ch == 125 {
      if interp_depths.length() > 0 {
        let top_idx = interp_depths.length() - 1
        if interp_depths[top_idx] > 0 {
          interp_depths[top_idx] = interp_depths[top_idx] - 1
        }
      }
      RBrace
    } else if ch == 91 {
      LBracket
    } else if ch == 93 {
      RBracket
    } else if ch == 44 {
      Comma
    } else if ch == 59 {
      Semi
    } else if ch == 58 {
      Colon
    } else if ch == 46 {
      Dot
    } else if ch == 63 {
      Question
    } else if ch == 43 {
      Plus
    } else if ch == 45 {
      Minus
    } else if ch == 42 {
      Star
    } else if ch == 47 {
      Slash
    } else if ch == 37 {
      Percent
    } else if ch == 61 {
      Eq
    } else if ch == 60 {
      Lt
    } else if ch == 62 {
      Gt
    } else if ch == 33 {
      Bang
    } else if ch == 38 {
      Amp
    } else if ch == 124 {
      Pipe
    } else if ch == 94 {
      Caret
    } else {
      diags.push(
        diag_new(
          sp,
          "E_PARSE",
          "unexpected character `" + one + "`",
          "valid token",
          one,
          "remove or replace unexpected character `" + one + "`",
        ),
      )
      Invalid(one)
    }
    tokens.push(Token::{ kind: tok_kind, span: sp, raw: one, newline_before: nl })
  }

  tokens.push(Token::{
    kind: Eof,
    span: span_new(file, line, col),
    raw: "",
    newline_before: true,
  })
  LexResult::{ tokens: tokens, diagnostics: diags }
}
