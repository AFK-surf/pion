///|
pub fn parse_package(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> Package {
  let files : Array[SourceFile] = []
  let mut i = 0
  while i < paths.length() && i < sources.length() {
    let pr = parse_source(paths[i], sources[i])
    files.push(pr.file)
    i = i + 1
  }
  Package::{ name: pkg_name, files: files }
}

///|
pub fn query_defs_json(pkg : Package) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"defs\":[")
  let mut count = 0
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      if count > 0 {
        sb.write_string(",")
      }
      count = count + 1
      match f.decls[di] {
        DStruct(sd) => {
          sb.write_string("{\"pkg\":")
          sb.write_string(json_quote(pkg.name))
          sb.write_string(",\"name\":")
          sb.write_string(json_quote(sd.name))
          sb.write_string(",\"kind\":\"struct\",\"pub\":")
          sb.write_string(if sd.is_pub { "true" } else { "false" })
          sb.write_string(",\"file\":")
          sb.write_string(json_quote(sd.span.file))
          sb.write_string(",\"line\":")
          sb.write_string(sd.span.line.to_string())
          sb.write_string(",\"sig\":")
          sb.write_string(json_quote(format_struct_sig(sd)))
          sb.write_string("}")
        }
        DEnum(ed) => {
          sb.write_string("{\"pkg\":")
          sb.write_string(json_quote(pkg.name))
          sb.write_string(",\"name\":")
          sb.write_string(json_quote(ed.name))
          sb.write_string(",\"kind\":\"enum\",\"pub\":")
          sb.write_string(if ed.is_pub { "true" } else { "false" })
          sb.write_string(",\"file\":")
          sb.write_string(json_quote(ed.span.file))
          sb.write_string(",\"line\":")
          sb.write_string(ed.span.line.to_string())
          sb.write_string(",\"sig\":")
          sb.write_string(json_quote(format_enum_sig(ed)))
          sb.write_string("}")
        }
        DFn(fd) => {
          let full_name = if fd.receiver_type != "" {
            fd.receiver_type + "::" + fd.name
          } else {
            fd.name
          }
          sb.write_string("{\"pkg\":")
          sb.write_string(json_quote(pkg.name))
          sb.write_string(",\"name\":")
          sb.write_string(json_quote(full_name))
          sb.write_string(",\"kind\":\"fn\",\"pub\":")
          sb.write_string(if fd.is_pub { "true" } else { "false" })
          sb.write_string(",\"file\":")
          sb.write_string(json_quote(fd.span.file))
          sb.write_string(",\"line\":")
          sb.write_string(fd.span.line.to_string())
          sb.write_string(",\"sig\":")
          sb.write_string(json_quote(format_fn_sig(fd)))
          sb.write_string("}")
        }
        DConst(cd) => {
          sb.write_string("{\"pkg\":")
          sb.write_string(json_quote(pkg.name))
          sb.write_string(",\"name\":")
          sb.write_string(json_quote(cd.name))
          sb.write_string(",\"kind\":\"const\",\"pub\":")
          sb.write_string(if cd.is_pub { "true" } else { "false" })
          sb.write_string(",\"file\":")
          sb.write_string(json_quote(cd.span.file))
          sb.write_string(",\"line\":")
          sb.write_string(cd.span.line.to_string())
          sb.write_string(",\"sig\":")
          sb.write_string(json_quote(format_const_sig(cd)))
          sb.write_string("}")
        }
        DTest(td) => {
          sb.write_string("{\"pkg\":")
          sb.write_string(json_quote(pkg.name))
          sb.write_string(",\"name\":")
          sb.write_string(json_quote(td.name))
          sb.write_string(",\"kind\":\"test\",\"pub\":false,\"file\":")
          sb.write_string(json_quote(td.span.file))
          sb.write_string(",\"line\":")
          sb.write_string(td.span.line.to_string())
          sb.write_string(",\"sig\":")
          sb.write_string(json_quote("test \"" + td.name + "\""))
          sb.write_string("}")
        }
      }
      di = di + 1
    }
    fi = fi + 1
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
pub fn query_sig_json(pkg : Package) -> String {
  package_sig_to_json(extract_package_sig(pkg))
}

///|
fn push_unique(arr : Array[String], item : String) -> Unit {
  if !str_arr_contains(arr, item) {
    arr.push(item)
  }
}

///|
fn collect_stmt_calls(stmts : Array[Stmt], out : Array[String]) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    match stmts[i] {
      SLet(_, _, _, init, _) => collect_expr_calls(init, out)
      SAssign(lhs, rhs, _) => {
        collect_expr_calls(lhs, out)
        collect_expr_calls(rhs, out)
      }
      SWhile(cond, body, _) => {
        collect_expr_calls(cond, out)
        collect_stmt_calls(body, out)
      }
      SFor(init_s, cond, step_s, body, _) => {
        collect_stmt_calls([init_s], out)
        collect_expr_calls(cond, out)
        collect_stmt_calls([step_s], out)
        collect_stmt_calls(body, out)
      }
      SForRange(_, start_e, end_e, body, _) => {
        collect_expr_calls(start_e, out)
        collect_expr_calls(end_e, out)
        collect_stmt_calls(body, out)
      }
      SForIn(_, iter_e, body, _) => {
        collect_expr_calls(iter_e, out)
        collect_stmt_calls(body, out)
      }
      SReturn(opt, _) =>
        match opt {
          Some(e) => collect_expr_calls(e, out)
          None => ()
        }
      SBreak(_) | SContinue(_) => ()
      SDebugAssert(c, m, _) => {
        push_unique(out, "debug_assert")
        collect_expr_calls(c, out)
        collect_expr_calls(m, out)
      }
      SExpr(e, _) => collect_expr_calls(e, out)
    }
    i = i + 1
  }
}

///|
fn collect_expr_calls(e : Expr, out : Array[String]) -> Unit {
  match e {
    EInt(_, _) | EInt64(_, _) | EDouble(_, _) | EBool(_, _) => ()
    EByte(_, _) | EChar(_, _) | EString(_, _) | EUnit(_) => ()
    EIdent(_, _) | EPath(_, _, _) => ()
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | ETry(inner, _) =>
      collect_expr_calls(inner, out)
    EInterp(parts, _) => {
      let mut i = 0
      while i < parts.length() {
        collect_expr_calls(parts[i], out)
        i = i + 1
      }
    }
    EBinary(_, l, r, _) => {
      collect_expr_calls(l, out)
      collect_expr_calls(r, out)
    }
    ECall(callee, args, _) => {
      match callee {
        EIdent(name, _) => push_unique(out, name)
        EPath(qual, mem, _) => push_unique(out, qual + "::" + mem)
        _ => collect_expr_calls(callee, out)
      }
      let mut i = 0
      while i < args.length() {
        collect_expr_calls(args[i], out)
        i = i + 1
      }
    }
    EField(obj, _, _) => collect_expr_calls(obj, out)
    EMethodCall(obj, method_name, args, _) => {
      push_unique(out, "." + method_name)
      collect_expr_calls(obj, out)
      let mut i = 0
      while i < args.length() {
        collect_expr_calls(args[i], out)
        i = i + 1
      }
    }
    EIndex(obj, idx, _) => {
      collect_expr_calls(obj, out)
      collect_expr_calls(idx, out)
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        collect_expr_calls(elems[i], out)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        collect_expr_calls(fields[i].value, out)
        i = i + 1
      }
    }
    EBlock(stmts, _) => collect_stmt_calls(stmts, out)
    EIf(cond, then_s, else_opt, _) => {
      collect_expr_calls(cond, out)
      collect_stmt_calls(then_s, out)
      match else_opt {
        Some(el) => collect_expr_calls(el, out)
        None => ()
      }
    }
    EMatch(scrut, arms, _) => {
      collect_expr_calls(scrut, out)
      let mut i = 0
      while i < arms.length() {
        collect_expr_calls(arms[i].body, out)
        i = i + 1
      }
    }
    EClosure(_, _, body, _) => collect_stmt_calls(body, out)
    EScope(w, f, _) => {
      push_unique(out, "scope")
      collect_expr_calls(w, out)
      collect_expr_calls(f, out)
    }
    ESpawn(s, f, _) => {
      push_unique(out, "spawn")
      collect_expr_calls(s, out)
      collect_expr_calls(f, out)
    }
  }
}

///|
pub fn query_callers_json(pkg : Package) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"callers\":[")
  let mut count = 0
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DFn(fd) => {
          if count > 0 {
            sb.write_string(",")
          }
          count = count + 1
          let full_name = if fd.receiver_type != "" {
            fd.receiver_type + "::" + fd.name
          } else {
            fd.name
          }
          let calls : Array[String] = []
          collect_stmt_calls(fd.body, calls)
          sb.write_string("{\"fn\":")
          sb.write_string(json_quote(full_name))
          sb.write_string(",\"calls\":[")
          let mut ci = 0
          while ci < calls.length() {
            if ci > 0 {
              sb.write_string(",")
            }
            sb.write_string(json_quote(calls[ci]))
            ci = ci + 1
          }
          sb.write_string("]}")
        }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
pub fn query_deps_json(pkg : Package) -> String {
  let sig_text = emit_m2sig(pkg)
  let hash = sig_hash_hex(sig_text)
  let deps : Array[String] = []
  let local_types : Map[String, Bool] = Map([])
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) => local_types.set(sd.name, true)
        DEnum(ed) => local_types.set(ed.name, true)
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  // Collect builtin/runtime capability dependencies used by this package
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DFn(fd) => {
          let calls : Array[String] = []
          collect_stmt_calls(fd.body, calls)
          let mut ci = 0
          while ci < calls.length() {
            let c = calls[ci]
            if c == "scope" || c == "spawn" || starts_with_str(c, "Channel::") || starts_with_str(c, "Mutex::") || starts_with_str(c, "AtomicInt::") {
              push_unique(deps, "m2/runtime/concurrency")
            } else if is_world_builtin(c) {
              push_unique(deps, "m2/runtime/world")
            }
            ci = ci + 1
          }
        }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  let sb = StringBuilder()
  sb.write_string("{\"packages\":[{\"name\":")
  sb.write_string(json_quote(pkg.name))
  sb.write_string(",\"deps\":[")
  let mut i = 0
  while i < deps.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(json_quote(deps[i]))
    i = i + 1
  }
  sb.write_string("],\"sig_hash\":")
  sb.write_string(json_quote(hash))
  sb.write_string("}]}")
  sb.to_string()
}

///|
pub fn cli_check_json(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> (Bool, String) {
  let cr = check_source_files(pkg_name, paths, sources)
  let ok = cr.diagnostics.length() == 0
  (ok, check_result_to_json(cr.diagnostics))
}

///|
pub fn cli_query_json(
  kind : String,
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> Result[String, String] {
  let pkg = parse_package(pkg_name, paths, sources)
  if kind == "defs" {
    Ok(query_defs_json(pkg))
  } else if kind == "sig" {
    Ok(query_sig_json(pkg))
  } else if kind == "callers" {
    Ok(query_callers_json(pkg))
  } else if kind == "deps" {
    Ok(query_deps_json(pkg))
  } else {
    Err("unknown query kind `" + kind + "` (expected defs|sig|callers|deps)")
  }
}

///|
pub fn cli_emit_sig(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> String {
  let pkg = parse_package(pkg_name, paths, sources)
  emit_m2sig(pkg)
}
