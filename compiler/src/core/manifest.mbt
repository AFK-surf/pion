///| Pure m2 ∩ MoonBit `m2.toml` manifest parser & package dependency graph

///|
pub struct ManifestDep {
  name : String
  path : String
}

///|
pub struct PackageManifest {
  name : String
  version : String
  deps : Array[ManifestDep]
  link_libs : Array[String]
}

///|
pub struct PkgNodeInput {
  name : String
  dir : String
  deps : Array[String]
  paths : Array[String]
  sources : Array[String]
  link_libs : Array[String]
}

///|
pub fn pkg_node_input_new(
  name : String,
  dir : String,
  deps : Array[String],
  paths : Array[String],
  sources : Array[String],
) -> PkgNodeInput {
  PkgNodeInput::{
    name: name,
    dir: dir,
    deps: deps,
    paths: paths,
    sources: sources,
    link_libs: [],
  }
}

///|
pub struct TopoSortResult {
  order : Array[Int]
  diagnostics : Array[Diagnostic]
}

///|
fn toml_trim(s : String) -> String {
  let len = s.length()
  let mut a = 0
  while a < len {
    let c = str_code_at(s, a)
    if c == 32 || c == 9 || c == 13 || c == 10 {
      a = a + 1
    } else {
      break
    }
  }
  let mut b = len
  while b > a {
    let c = str_code_at(s, b - 1)
    if c == 32 || c == 9 || c == 13 || c == 10 {
      b = b - 1
    } else {
      break
    }
  }
  slice_str(s, a, b)
}

///|
fn toml_strip_comment(line : String) -> String {
  let len = line.length()
  let mut in_str = false
  let mut esc = false
  let mut i = 0
  while i < len {
    let c = str_code_at(line, i)
    if in_str {
      if esc {
        esc = false
      } else if c == 92 {
        esc = true
      } else if c == 34 {
        in_str = false
      }
    } else if c == 34 {
      in_str = true
    } else if c == 35 {
      return slice_str(line, 0, i)
    }
    i = i + 1
  }
  line
}

///|
fn toml_find_char(s : String, ch : Int, start : Int) -> Int {
  let len = s.length()
  let mut in_str = false
  let mut esc = false
  let mut i = start
  while i < len {
    let c = str_code_at(s, i)
    if in_str {
      if esc {
        esc = false
      } else if c == 92 {
        esc = true
      } else if c == 34 {
        in_str = false
      }
    } else if c == 34 {
      in_str = true
    } else if c == ch {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn toml_unquote(raw : String) -> Result[String, String] {
  let s = toml_trim(raw)
  let len = s.length()
  if len < 2 || str_code_at(s, 0) != 34 || str_code_at(s, len - 1) != 34 {
    return Err("expected quoted string, found `" + s + "`")
  }
  let sb = StringBuilder()
  let mut i = 1
  while i < len - 1 {
    let c = str_code_at(s, i)
    if c == 92 && i + 1 < len - 1 {
      let nc = str_code_at(s, i + 1)
      if nc == 110 {
        sb.write_char('\n')
      } else if nc == 116 {
        sb.write_char('\t')
      } else if nc == 114 {
        sb.write_char('\r')
      } else if nc == 34 {
        sb.write_char('"')
      } else if nc == 92 {
        sb.write_char('\\')
      } else {
        sb.write_char(nc.unsafe_to_char())
      }
      i = i + 2
    } else {
      sb.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  Ok(sb.to_string())
}

///|
fn toml_parse_dep_path(rhs : String) -> Result[String, String] {
  let s = toml_trim(rhs)
  if s.length() >= 2 && str_code_at(s, 0) == 34 {
    return toml_unquote(s)
  }
  if s.length() < 2 ||
    str_code_at(s, 0) != 123 ||
    str_code_at(s, s.length() - 1) != 125 {
    return Err("expected `{ path = \"...\" }` in [dependencies], found `" + s + "`")
  }
  let inner = toml_trim(slice_str(s, 1, s.length() - 1))
  let mut pos = 0
  let ilen = inner.length()
  while pos < ilen {
    let comma = toml_find_char(inner, 44, pos)
    let end_p = if comma < 0 { ilen } else { comma }
    let entry = toml_trim(slice_str(inner, pos, end_p))
    if entry.length() > 0 {
      let eq = toml_find_char(entry, 61, 0)
      if eq > 0 {
        let k = toml_trim(slice_str(entry, 0, eq))
        let v = toml_trim(slice_str(entry, eq + 1, entry.length()))
        if k == "path" {
          return toml_unquote(v)
        }
      }
    }
    if comma < 0 {
      break
    }
    pos = comma + 1
  }
  Err("missing `path = \"...\"` in dependency table `" + s + "`")
}

///|
/// Parses a TOML string array `["a", "b"]` (or a single quoted string).
fn toml_parse_str_array(rhs : String) -> Result[Array[String], String] {
  let s = toml_trim(rhs)
  let out : Array[String] = []
  if s.length() >= 2 && str_code_at(s, 0) == 34 {
    match toml_unquote(s) {
      Ok(v) => out.push(v)
      Err(e) => return Err(e)
    }
    return Ok(out)
  }
  if s.length() < 2 ||
    str_code_at(s, 0) != 91 ||
    str_code_at(s, s.length() - 1) != 93 {
    return Err("expected `[\"...\", ...]`, found `" + s + "`")
  }
  let inner = slice_str(s, 1, s.length() - 1)
  let ilen = inner.length()
  let mut pos = 0
  while pos < ilen {
    let comma = toml_find_char(inner, 44, pos)
    let end_p = if comma < 0 { ilen } else { comma }
    let entry = toml_trim(slice_str(inner, pos, end_p))
    if entry.length() > 0 {
      match toml_unquote(entry) {
        Ok(v) => out.push(v)
        Err(e) => return Err(e)
      }
    }
    if comma < 0 {
      break
    }
    pos = comma + 1
  }
  Ok(out)
}

///|
/// Appends `lib` to `libs` unless already present (keeps first-seen order).
pub fn push_unique_lib(libs : Array[String], lib : String) -> Unit {
  if lib.length() == 0 {
    return
  }
  let mut i = 0
  while i < libs.length() {
    if libs[i] == lib {
      return
    }
    i = i + 1
  }
  libs.push(lib)
}

///|
pub fn parse_m2_toml(text : String) -> Result[PackageManifest, String] {
  let lines = split_lines(text)
  let mut section = ""
  let mut pkg_name = ""
  let mut version = "0.1.0"
  let deps : Array[ManifestDep] = []
  let link_libs : Array[String] = []
  let mut i = 0
  while i < lines.length() {
    let clean = toml_trim(toml_strip_comment(lines[i]))
    if clean.length() == 0 {
      i = i + 1
      continue
    }
    if str_code_at(clean, 0) == 91 &&
      str_code_at(clean, clean.length() - 1) == 93 {
      section = toml_trim(slice_str(clean, 1, clean.length() - 1))
      i = i + 1
      continue
    }
    let eq = toml_find_char(clean, 61, 0)
    if eq <= 0 {
      return Err(
        "m2.toml line " + (i + 1).to_string() + ": expected `key = value`",
      )
    }
    let key = toml_trim(slice_str(clean, 0, eq))
    let raw_val = toml_trim(slice_str(clean, eq + 1, clean.length()))
    if section == "package" {
      if key == "name" {
        match toml_unquote(raw_val) {
          Ok(v) => pkg_name = v
          Err(e) => return Err("m2.toml line " + (i + 1).to_string() + ": " + e)
        }
      } else if key == "version" {
        match toml_unquote(raw_val) {
          Ok(v) => version = v
          Err(e) => return Err("m2.toml line " + (i + 1).to_string() + ": " + e)
        }
      }
    } else if section == "dependencies" {
      match toml_parse_dep_path(raw_val) {
        Ok(p) => deps.push(ManifestDep::{ name: key, path: p })
        Err(e) => return Err("m2.toml line " + (i + 1).to_string() + ": " + e)
      }
    } else if section == "link" {
      if key == "libs" || key == "lib" {
        match toml_parse_str_array(raw_val) {
          Ok(vs) => {
            let mut vi = 0
            while vi < vs.length() {
              push_unique_lib(link_libs, vs[vi])
              vi = vi + 1
            }
          }
          Err(e) => return Err("m2.toml line " + (i + 1).to_string() + ": " + e)
        }
      }
    }
    i = i + 1
  }
  if pkg_name.length() == 0 {
    return Err("m2.toml: missing `[package]` `name = \"...\"`")
  }
  Ok(PackageManifest::{
    name: pkg_name,
    version: version,
    deps: deps,
    link_libs: link_libs,
  })
}

///|
fn topo_dfs(
  idx : Int,
  names : Array[String],
  deps : Array[Array[String]],
  name_to_idx : Map[String, Int],
  color : Array[Int],
  stack : Array[String],
  order : Array[Int],
  diags : Array[Diagnostic],
) -> Unit {
  color[idx] = 1
  stack.push(names[idx])
  let cur_deps = deps[idx]
  let mut i = 0
  while i < cur_deps.length() {
    let dep_name = cur_deps[i]
    match name_to_idx.get(dep_name) {
      None =>
        diags.push(
          diag_new(
            span_new(names[idx] + "/m2.toml", 1, 1),
            "E_UNKNOWN_PACKAGE",
            "unknown dependency package `" + dep_name + "` required by `" + names[idx] + "`",
            "defined package in [dependencies]",
            dep_name,
            "add `" + dep_name + " = { path = \"...\" }` to `m2.toml`",
          ),
        )
      Some(didx) =>
        if color[didx] == 1 {
          let sb = StringBuilder()
          let mut k = 0
          let mut started = false
          while k < stack.length() {
            if stack[k] == dep_name {
              started = true
            }
            if started {
              sb.write_string(stack[k])
              sb.write_string(" -> ")
            }
            k = k + 1
          }
          sb.write_string(dep_name)
          let cycle_str = sb.to_string()
          diags.push(
            diag_new(
              span_new(names[idx] + "/m2.toml", 1, 1),
              "E_IMPORT_CYCLE",
              "cyclic package dependency detected: " + cycle_str,
              "acyclic package dependency graph",
              cycle_str,
              "break the dependency cycle involving `" + dep_name + "`",
            ),
          )
        } else if color[didx] == 0 {
          topo_dfs(didx, names, deps, name_to_idx, color, stack, order, diags)
        }
    }
    i = i + 1
  }
  let _ = stack.pop()
  color[idx] = 2
  order.push(idx)
}

///|
pub fn topo_sort_packages(
  pkg_names : Array[String],
  pkg_deps : Array[Array[String]],
) -> TopoSortResult {
  let n = pkg_names.length()
  let name_to_idx : Map[String, Int] = Map([])
  let color : Array[Int] = []
  let mut i = 0
  while i < n {
    name_to_idx.set(pkg_names[i], i)
    color.push(0)
    i = i + 1
  }
  let order : Array[Int] = []
  let diags : Array[Diagnostic] = []
  let stack : Array[String] = []
  i = 0
  while i < n {
    if color[i] == 0 {
      topo_dfs(i, pkg_names, pkg_deps, name_to_idx, color, stack, order, diags)
    }
    i = i + 1
  }
  TopoSortResult::{ order: order, diagnostics: diags }
}

///|
pub fn query_workspace_deps_json(
  pkg_names : Array[String],
  pkg_deps : Array[Array[String]],
  sig_hashes : Array[String],
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"packages\":[")
  let mut i = 0
  while i < pkg_names.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":")
    sb.write_string(json_quote(pkg_names[i]))
    sb.write_string(",\"deps\":[")
    let ds = pkg_deps[i]
    let mut j = 0
    while j < ds.length() {
      if j > 0 {
        sb.write_string(",")
      }
      sb.write_string(json_quote(ds[j]))
      j = j + 1
    }
    sb.write_string("],\"sig_hash\":")
    let h = if i < sig_hashes.length() { sig_hashes[i] } else { "" }
    sb.write_string(json_quote(h))
    sb.write_string("}")
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}
