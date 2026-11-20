///|
pub struct SigEntry {
  kind : String
  name : String
  signature : String
}

///|
pub struct PackageSig {
  pkg : String
  entries : Array[SigEntry]
}

///|
fn format_type_params(tparams : Array[String]) -> String {
  if tparams.length() == 0 {
    return ""
  }
  let sb = StringBuilder()
  sb.write_string("[")
  let mut i = 0
  while i < tparams.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(tparams[i])
    i = i + 1
  }
  sb.write_string("]")
  sb.to_string()
}

///|
pub fn format_struct_sig(sd : StructDecl) -> String {
  let sb = StringBuilder()
  if sd.is_val {
    sb.write_string("val ")
  }
  sb.write_string("struct ")
  sb.write_string(sd.name)
  sb.write_string(format_type_params(sd.type_params))
  sb.write_string(" { ")
  let mut i = 0
  while i < sd.fields.length() {
    if i > 0 {
      sb.write_string("; ")
    }
    let f = sd.fields[i]
    if f.is_mut {
      sb.write_string("mut ")
    }
    sb.write_string(f.name)
    sb.write_string(": ")
    sb.write_string(type_expr_to_string(f.ty))
    i = i + 1
  }
  sb.write_string(" }")
  sb.to_string()
}

///|
pub fn format_enum_sig(ed : EnumDecl) -> String {
  let sb = StringBuilder()
  sb.write_string("enum ")
  sb.write_string(ed.name)
  sb.write_string(format_type_params(ed.type_params))
  sb.write_string(" { ")
  let mut i = 0
  while i < ed.variants.length() {
    if i > 0 {
      sb.write_string("; ")
    }
    let v = ed.variants[i]
    sb.write_string(v.name)
    if v.fields.length() > 0 {
      sb.write_string("(")
      let mut j = 0
      while j < v.fields.length() {
        if j > 0 {
          sb.write_string(", ")
        }
        sb.write_string(type_expr_to_string(v.fields[j]))
        j = j + 1
      }
      sb.write_string(")")
    }
    i = i + 1
  }
  sb.write_string(" }")
  sb.to_string()
}

///|
pub fn format_fn_sig(fd : FnDecl) -> String {
  let sb = StringBuilder()
  sb.write_string("fn ")
  if fd.receiver_type != "" {
    sb.write_string(fd.receiver_type)
    sb.write_string("::")
  }
  sb.write_string(fd.name)
  sb.write_string(format_type_params(fd.type_params))
  sb.write_string("(")
  let mut i = 0
  while i < fd.params.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    let param = fd.params[i]
    sb.write_string(param.name)
    sb.write_string(": ")
    sb.write_string(type_expr_to_string(param.ty))
    i = i + 1
  }
  sb.write_string(") -> ")
  sb.write_string(type_expr_to_string(fd.ret_ty))
  sb.to_string()
}

///|
pub fn format_const_sig(cd : ConstDecl) -> String {
  "const " + cd.name + ": " + type_expr_to_string(cd.ty)
}

///|
fn sig_kind_rank(kind : String) -> Int {
  if kind == "struct" {
    0
  } else if kind == "enum" {
    1
  } else if kind == "const" {
    2
  } else {
    3
  }
}

///|
fn sig_entry_lt(a : SigEntry, b : SigEntry) -> Bool {
  let ra = sig_kind_rank(a.kind)
  let rb = sig_kind_rank(b.kind)
  if ra != rb {
    ra < rb
  } else {
    a.name < b.name
  }
}

///|
fn sort_sig_entries(entries : Array[SigEntry]) -> Unit {
  let n = entries.length()
  let mut i = 1
  while i < n {
    let key = entries[i]
    let mut j = i - 1
    while j >= 0 && sig_entry_lt(key, entries[j]) {
      entries[j + 1] = entries[j]
      j = j - 1
    }
    entries[j + 1] = key
    i = i + 1
  }
}

///|
pub fn extract_package_sig(pkg : Package) -> PackageSig {
  let entries : Array[SigEntry] = []
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) =>
          if sd.is_pub {
            entries.push(SigEntry::{
              kind: "struct",
              name: sd.name,
              signature: format_struct_sig(sd),
            })
          }
        DEnum(ed) =>
          if ed.is_pub {
            entries.push(SigEntry::{
              kind: "enum",
              name: ed.name,
              signature: format_enum_sig(ed),
            })
          }
        DFn(fd) =>
          if fd.is_pub {
            let full_name = if fd.receiver_type != "" {
              fd.receiver_type + "::" + fd.name
            } else {
              fd.name
            }
            entries.push(SigEntry::{
              kind: "fn",
              name: full_name,
              signature: format_fn_sig(fd),
            })
          }
        DConst(cd) =>
          if cd.is_pub {
            entries.push(SigEntry::{
              kind: "const",
              name: cd.name,
              signature: format_const_sig(cd),
            })
          }
        DTest(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  sort_sig_entries(entries)
  PackageSig::{ pkg: pkg.name, entries: entries }
}

///|
pub fn serialize_m2sig(sig : PackageSig) -> String {
  let sb = StringBuilder()
  sb.write_string("m2sig v1\n")
  sb.write_string("pkg ")
  sb.write_string(sig.pkg)
  sb.write_string("\n")
  let mut i = 0
  while i < sig.entries.length() {
    sb.write_string(sig.entries[i].signature)
    sb.write_string("\n")
    i = i + 1
  }
  sb.to_string()
}

///|
pub fn emit_m2sig(pkg : Package) -> String {
  serialize_m2sig(extract_package_sig(pkg))
}

///|
/// Extract all declarations (pub and package-private signatures, no function bodies)
/// for sound unit-level incremental CAS invalidation across files in a package.
pub fn emit_all_sigs(pkg : Package) -> String {
  let entries : Array[SigEntry] = []
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) =>
          entries.push(SigEntry::{
            kind: "struct",
            name: sd.name,
            signature: format_struct_sig(sd),
          })
        DEnum(ed) =>
          entries.push(SigEntry::{
            kind: "enum",
            name: ed.name,
            signature: format_enum_sig(ed),
          })
        DFn(fd) => {
          let full_name = if fd.receiver_type != "" {
            fd.receiver_type + "::" + fd.name
          } else {
            fd.name
          }
          entries.push(SigEntry::{
            kind: "fn",
            name: full_name,
            signature: format_fn_sig(fd),
          })
        }
        DConst(cd) =>
          entries.push(SigEntry::{
            kind: "const",
            name: cd.name,
            signature: format_const_sig(cd),
          })
        DTest(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  sort_sig_entries(entries)
  serialize_m2sig(PackageSig::{ pkg: pkg.name, entries: entries })
}

///|
/// Emit canonical per-file declaration signatures (one per line, no header)
/// for incremental unit-level CAS hashing without re-parsing unchanged files.
pub fn emit_file_sig_entries(f : SourceFile) -> String {
  let sb = StringBuilder()
  let mut di = 0
  while di < f.decls.length() {
    match f.decls[di] {
      DStruct(sd) => {
        sb.write_string(format_struct_sig(sd))
        sb.write_string("\n")
      }
      DEnum(ed) => {
        sb.write_string(format_enum_sig(ed))
        sb.write_string("\n")
      }
      DFn(fd) => {
        sb.write_string(format_fn_sig(fd))
        sb.write_string("\n")
      }
      DConst(cd) => {
        sb.write_string(format_const_sig(cd))
        sb.write_string("\n")
      }
      DTest(_) => ()
    }
    di = di + 1
  }
  sb.to_string()
}

///|
/// Emit a minimal parseable `.m2` stub containing only top-level declarations
/// (structs, enums, const types, and fn signatures with `{ panic() }` bodies).
pub fn emit_file_stub(f : SourceFile) -> String {
  let sb = StringBuilder()
  let mut di = 0
  while di < f.decls.length() {
    match f.decls[di] {
      DStruct(sd) => {
        if sd.is_pub {
          sb.write_string("pub ")
        }
        if sd.is_val {
          sb.write_string("val ")
        }
        sb.write_string("struct ")
        sb.write_string(sd.name)
        sb.write_string(format_type_params(sd.type_params))
        sb.write_string(" {\n")
        let mut i = 0
        while i < sd.fields.length() {
          let fld = sd.fields[i]
          sb.write_string("  ")
          if fld.is_mut {
            sb.write_string("mut ")
          }
          sb.write_string(fld.name)
          sb.write_string(" : ")
          sb.write_string(type_expr_to_string(fld.ty))
          sb.write_string("\n")
          i = i + 1
        }
        sb.write_string("}\n")
      }
      DEnum(ed) => {
        if ed.is_pub {
          sb.write_string("pub ")
        }
        sb.write_string("enum ")
        sb.write_string(ed.name)
        sb.write_string(format_type_params(ed.type_params))
        sb.write_string(" {\n")
        let mut i = 0
        while i < ed.variants.length() {
          let v = ed.variants[i]
          sb.write_string("  ")
          sb.write_string(v.name)
          if v.fields.length() > 0 {
            sb.write_string("(")
            let mut j = 0
            while j < v.fields.length() {
              if j > 0 {
                sb.write_string(", ")
              }
              sb.write_string(type_expr_to_string(v.fields[j]))
              j = j + 1
            }
            sb.write_string(")")
          }
          sb.write_string("\n")
          i = i + 1
        }
        sb.write_string("}\n")
      }
      DFn(fd) => {
        if fd.is_pub {
          sb.write_string("pub ")
        }
        sb.write_string("fn ")
        if fd.receiver_type != "" {
          sb.write_string(fd.receiver_type)
          sb.write_string("::")
        }
        sb.write_string(fd.name)
        sb.write_string(format_type_params(fd.type_params))
        sb.write_string("(")
        let mut i = 0
        while i < fd.params.length() {
          if i > 0 {
            sb.write_string(", ")
          }
          let param = fd.params[i]
          sb.write_string(param.name)
          sb.write_string(" : ")
          sb.write_string(type_expr_to_string(param.ty))
          i = i + 1
        }
        sb.write_string(") -> ")
        sb.write_string(type_expr_to_string(fd.ret_ty))
        sb.write_string(" { panic() }\n")
      }
      DConst(cd) => {
        if cd.is_pub {
          sb.write_string("pub ")
        }
        sb.write_string("let ")
        sb.write_string(cd.name)
        sb.write_string(" : ")
        sb.write_string(type_expr_to_string(cd.ty))
        sb.write_string(" = panic()\n")
      }
      DTest(_) => ()
    }
    di = di + 1
  }
  sb.to_string()
}

///|
/// Emit a minimal parseable `.m2` package stub preserving imports and all
/// top-level declaration signatures (with `{ panic() }` / `= panic()` bodies)
/// so downstream packages can typecheck against CAS-hit dependencies without
/// re-parsing or typechecking upstream function bodies.
pub fn emit_m2_stub(pkg : Package) -> String {
  let sb = StringBuilder()
  let seen_imports : Map[String, Bool] = Map([])
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut ii = 0
    while ii < f.imports.length() {
      let imp = f.imports[ii]
      let key = imp.path + "\n" + imp.alias_name
      if !seen_imports.contains(key) {
        seen_imports.set(key, true)
        sb.write_string("import ")
        sb.write_string(json_quote(imp.path))
        sb.write_string(" as ")
        sb.write_string(imp.alias_name)
        sb.write_string("\n")
      }
      ii = ii + 1
    }
    fi = fi + 1
  }
  fi = 0
  while fi < pkg.files.length() {
    sb.write_string(emit_file_stub(pkg.files[fi]))
    fi = fi + 1
  }
  sb.to_string()
}

///|
pub struct FileSigsSummary {
  sigs_hash : String
  const_units : Array[Int]
  has_main : Bool
}

///|
/// Reconstruct the exact same `sigs_hash` and `const_units` as `cli_prepare_qbe_units`
/// from per-file signature texts (`emit_file_sig_entries`).
pub fn summarize_file_sigs(
  pkg_name : String,
  file_sigs : Array[String],
) -> FileSigsSummary {
  let entries : Array[SigEntry] = []
  let const_units : Array[Int] = []
  let mut has_main = false
  let mut fi = 0
  while fi < file_sigs.length() {
    let lines = split_lines(file_sigs[fi])
    let mut has_const = false
    let mut i = 0
    while i < lines.length() {
      let line = lines[i]
      if line.length() == 0 {
        i = i + 1
        continue
      }
      if starts_with_str(line, "val struct ") {
        entries.push(SigEntry::{
          kind: "struct",
          name: extract_sig_name(line, 11),
          signature: line,
        })
      } else if starts_with_str(line, "struct ") {
        entries.push(SigEntry::{
          kind: "struct",
          name: extract_sig_name(line, 7),
          signature: line,
        })
      } else if starts_with_str(line, "enum ") {
        entries.push(SigEntry::{
          kind: "enum",
          name: extract_sig_name(line, 5),
          signature: line,
        })
      } else if starts_with_str(line, "fn ") {
        let fname = extract_sig_name(line, 3)
        if fname == "main" {
          has_main = true
        }
        entries.push(SigEntry::{
          kind: "fn",
          name: fname,
          signature: line,
        })
      } else if starts_with_str(line, "const ") {
        has_const = true
        entries.push(SigEntry::{
          kind: "const",
          name: extract_sig_name(line, 6),
          signature: line,
        })
      }
      i = i + 1
    }
    if has_const {
      const_units.push(fi)
    }
    fi = fi + 1
  }
  sort_sig_entries(entries)
  let all_sigs = serialize_m2sig(PackageSig::{ pkg: pkg_name, entries: entries })
  let sig_sb = StringBuilder()
  sig_sb.write_string(all_sigs)
  sig_sb.write_string("const_units:")
  let mut ci = 0
  while ci < const_units.length() {
    if ci > 0 {
      sig_sb.write_string(",")
    }
    sig_sb.write_string(const_units[ci].to_string())
    ci = ci + 1
  }
  sig_sb.write_string("\n")
  FileSigsSummary::{
    sigs_hash: cas_sha256_hex(sig_sb.to_string()),
    const_units: const_units,
    has_main: has_main,
  }
}

///|
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let len = s.length()
  let mut start = 0
  let mut i = 0
  while i < len {
    if str_code_at(s, i) == 10 {
      out.push(slice_str(s, start, i))
      start = i + 1
    }
    i = i + 1
  }
  if start < len {
    out.push(slice_str(s, start, len))
  }
  out
}

///|
fn starts_with_str(s : String, prefix : String) -> Bool {
  if prefix.length() > s.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if str_code_at(s, i) != str_code_at(prefix, i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn extract_sig_name(line : String, start_idx : Int) -> String {
  let mut i = start_idx
  let len = line.length()
  while i < len {
    let ch = str_code_at(line, i)
    if ch == 32 || ch == 40 || ch == 91 || ch == 58 {
      if ch == 58 && i + 1 < len && str_code_at(line, i + 1) == 58 {
        i = i + 2
        continue
      }
      break
    }
    i = i + 1
  }
  slice_str(line, start_idx, i)
}

///|
pub fn parse_m2sig(text : String) -> Result[PackageSig, String] {
  let lines = split_lines(text)
  if lines.length() < 2 {
    return Err("m2sig too short: missing header")
  }
  if lines[0] != "m2sig v1" {
    return Err("unsupported m2sig header: " + lines[0])
  }
  if !starts_with_str(lines[1], "pkg ") {
    return Err("missing pkg line in m2sig")
  }
  let pkg_name = slice_str(lines[1], 4, lines[1].length())
  let entries : Array[SigEntry] = []
  let mut i = 2
  while i < lines.length() {
    let line = lines[i]
    if line.length() == 0 {
      i = i + 1
      continue
    }
    if starts_with_str(line, "val struct ") {
      entries.push(SigEntry::{
        kind: "struct",
        name: extract_sig_name(line, 11),
        signature: line,
      })
    } else if starts_with_str(line, "struct ") {
      entries.push(SigEntry::{
        kind: "struct",
        name: extract_sig_name(line, 7),
        signature: line,
      })
    } else if starts_with_str(line, "enum ") {
      entries.push(SigEntry::{
        kind: "enum",
        name: extract_sig_name(line, 5),
        signature: line,
      })
    } else if starts_with_str(line, "fn ") {
      entries.push(SigEntry::{
        kind: "fn",
        name: extract_sig_name(line, 3),
        signature: line,
      })
    } else if starts_with_str(line, "const ") {
      entries.push(SigEntry::{
        kind: "const",
        name: extract_sig_name(line, 6),
        signature: line,
      })
    } else {
      return Err("unrecognized m2sig entry: " + line)
    }
    i = i + 1
  }
  Ok(PackageSig::{ pkg: pkg_name, entries: entries })
}

///|
pub fn sig_hash_hex(text : String) -> String {
  // Deterministic 64-bit FNV-1a hash formatted as 16 lowercase hex digits
  let mut h : Int64 = -3750763034362895579L
  let prime : Int64 = 1099511628211L
  let len = text.length()
  let mut i = 0
  while i < len {
    let ch = str_code_at(text, i).to_int64()
    h = (h ^ ch) * prime
    i = i + 1
  }
  let sb = StringBuilder()
  let mut shift = 60
  while shift >= 0 {
    let nibble = ((h >> shift) & 15L).to_int()
    sb.write_char(hex_digit(nibble))
    shift = shift - 4
  }
  sb.to_string()
}

///|
pub fn package_sig_to_json(sig : PackageSig) -> String {
  let raw = serialize_m2sig(sig)
  let hash = sig_hash_hex(raw)
  let sb = StringBuilder()
  sb.write_string("{\"pkg\":")
  sb.write_string(json_quote(sig.pkg))
  sb.write_string(",\"sig_hash\":")
  sb.write_string(json_quote(hash))
  sb.write_string(",\"m2sig\":")
  sb.write_string(json_quote(raw))
  sb.write_string(",\"exports\":[")
  let mut i = 0
  while i < sig.entries.length() {
    if i > 0 {
      sb.write_string(",")
    }
    let e = sig.entries[i]
    sb.write_string("{\"kind\":")
    sb.write_string(json_quote(e.kind))
    sb.write_string(",\"name\":")
    sb.write_string(json_quote(e.name))
    sb.write_string(",\"sig\":")
    sb.write_string(json_quote(e.signature))
    sb.write_string("}")
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}
