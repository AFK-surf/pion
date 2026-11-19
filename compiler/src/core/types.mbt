///|
pub enum Ty {
  TInt
  TInt64
  TDouble
  TBool
  TByte
  TChar
  TString
  TUnit
  TStringBuilder
  TBytes
  TWorld
  TScope
  TAtomicInt
  TArray(Ty)
  TOption(Ty)
  TResult(Ty, Ty)
  TMap(Ty, Ty)
  TChannel(Ty)
  TMutex(Ty)
  TStruct(String, Array[Ty])
  TEnum(String, Array[Ty])
  TFn(Array[Ty], Ty)
  TTuple(Array[Ty])
  TParam(String)
  TNever
  TError
}

///|
pub fn ty_to_string(t : Ty) -> String {
  match t {
    TInt => "Int"
    TInt64 => "Int64"
    TDouble => "Double"
    TBool => "Bool"
    TByte => "Byte"
    TChar => "Char"
    TString => "String"
    TUnit => "Unit"
    TStringBuilder => "StringBuilder"
    TBytes => "Bytes"
    TWorld => "World"
    TScope => "Scope"
    TAtomicInt => "AtomicInt"
    TArray(e) => "Array[" + ty_to_string(e) + "]"
    TOption(e) => "Option[" + ty_to_string(e) + "]"
    TResult(ok, err) =>
      "Result[" + ty_to_string(ok) + ", " + ty_to_string(err) + "]"
    TMap(k, v) => "Map[" + ty_to_string(k) + ", " + ty_to_string(v) + "]"
    TChannel(e) => "Channel[" + ty_to_string(e) + "]"
    TMutex(e) => "Mutex[" + ty_to_string(e) + "]"
    TStruct(name, args) => format_named_ty(name, args)
    TEnum(name, args) => format_named_ty(name, args)
    TFn(params, ret) => {
      let sb = StringBuilder()
      sb.write_string("(")
      let mut i = 0
      while i < params.length() {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(ty_to_string(params[i]))
        i = i + 1
      }
      sb.write_string(") -> ")
      sb.write_string(ty_to_string(ret))
      sb.to_string()
    }
    TTuple(elems) => {
      let sb = StringBuilder()
      sb.write_string("(")
      let mut i = 0
      while i < elems.length() {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(ty_to_string(elems[i]))
        i = i + 1
      }
      sb.write_string(")")
      sb.to_string()
    }
    TParam(n) => n
    TNever => "Never"
    TError => "<error>"
  }
}

///|
fn format_named_ty(name : String, args : Array[Ty]) -> String {
  if args.length() == 0 {
    return name
  }
  let sb = StringBuilder()
  sb.write_string(name)
  sb.write_string("[")
  let mut i = 0
  while i < args.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(ty_to_string(args[i]))
    i = i + 1
  }
  sb.write_string("]")
  sb.to_string()
}

///|
pub struct StructInfo {
  decl : StructDecl
  field_names : Array[String]
  field_muts : Array[Bool]
  field_tys : Array[Ty]
}

///|
pub struct VariantInfo {
  name : String
  field_tys : Array[Ty]
}

///|
pub struct EnumInfo {
  decl : EnumDecl
  variants : Array[VariantInfo]
}

///|
pub struct FnInfo {
  decl : FnDecl
  param_tys : Array[Ty]
  ret_ty : Ty
}

///|
pub struct VarBinding {
  name : String
  ty : Ty
  is_mut : Bool
}

///|
pub struct Env {
  scopes : Array[Map[String, VarBinding]]
  moved : Map[String, Span]
  mut has_world : Bool
  ret_ty : Ty
  type_params : Array[String]
}

///|
pub struct TypeChecker {
  structs : Map[String, StructInfo]
  enums : Map[String, EnumInfo]
  variant_to_enum : Map[String, String]
  fns : Map[String, FnInfo]
  methods : Map[String, FnInfo]
  consts : Map[String, Ty]
  diagnostics : Array[Diagnostic]
}

///|
pub struct CheckResult {
  diagnostics : Array[Diagnostic]
}

///|
fn str_arr_contains(arr : Array[String], target : String) -> Bool {
  let mut i = 0
  while i < arr.length() {
    if arr[i] == target {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn env_new(ret_ty : Ty, type_params : Array[String]) -> Env {
  let scopes : Array[Map[String, VarBinding]] = []
  scopes.push(Map([]))
  Env::{
    scopes: scopes,
    moved: Map([]),
    has_world: false,
    ret_ty: ret_ty,
    type_params: type_params,
  }
}

///|
fn env_push(env : Env) -> Unit {
  env.scopes.push(Map([]))
}

///|
fn env_pop(env : Env) -> Unit {
  if env.scopes.length() > 1 {
    let _ = env.scopes.pop()
  }
}

///|
fn env_define(env : Env, name : String, ty : Ty, is_mut : Bool) -> Unit {
  let top = env.scopes[env.scopes.length() - 1]
  top.set(name, VarBinding::{ name: name, ty: ty, is_mut: is_mut })
  match ty {
    TWorld => env.has_world = true
    _ => ()
  }
  if env.moved.contains(name) {
    env.moved.remove(name)
  }
}

///|
fn env_lookup(env : Env, name : String) -> Option[VarBinding] {
  let mut i = env.scopes.length() - 1
  while i >= 0 {
    match env.scopes[i].get(name) {
      Some(b) => return Some(b)
      None => ()
    }
    i = i - 1
  }
  None
}

///|
fn tc_err(
  tc : TypeChecker,
  span : Span,
  code : String,
  message : String,
  expected : String,
  found : String,
  fixit : String,
) -> Unit {
  tc.diagnostics.push(diag_new(span, code, message, expected, found, fixit))
}

///|
fn resolve_type_expr(
  tc : TypeChecker,
  te : TypeExpr,
  tparams : Array[String],
) -> Ty {
  match te {
    TyMissing(_) => TError
    TyTuple(elems, _) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < elems.length() {
        out.push(resolve_type_expr(tc, elems[i], tparams))
        i = i + 1
      }
      TTuple(out)
    }
    TyFn(params, ret, _) => {
      let ptys : Array[Ty] = []
      let mut i = 0
      while i < params.length() {
        ptys.push(resolve_type_expr(tc, params[i], tparams))
        i = i + 1
      }
      TFn(ptys, resolve_type_expr(tc, ret, tparams))
    }
    TyName(name, args, sp) => {
      if str_arr_contains(tparams, name) {
        return TParam(name)
      }
      if name == "Int" {
        return TInt
      }
      if name == "Int64" {
        return TInt64
      }
      if name == "Double" {
        return TDouble
      }
      if name == "Bool" {
        return TBool
      }
      if name == "Byte" {
        return TByte
      }
      if name == "Char" {
        return TChar
      }
      if name == "String" {
        return TString
      }
      if name == "Unit" {
        return TUnit
      }
      if name == "StringBuilder" {
        return TStringBuilder
      }
      if name == "Bytes" {
        return TBytes
      }
      if name == "World" {
        return TWorld
      }
      if name == "Scope" {
        return TScope
      }
      if name == "AtomicInt" {
        return TAtomicInt
      }
      let rargs : Array[Ty] = []
      let mut i = 0
      while i < args.length() {
        rargs.push(resolve_type_expr(tc, args[i], tparams))
        i = i + 1
      }
      if name == "Array" {
        let elem = if rargs.length() >= 1 { rargs[0] } else { TError }
        return TArray(elem)
      }
      if name == "Option" {
        let elem = if rargs.length() >= 1 { rargs[0] } else { TError }
        return TOption(elem)
      }
      if name == "Result" {
        let ok = if rargs.length() >= 1 { rargs[0] } else { TError }
        let err = if rargs.length() >= 2 { rargs[1] } else { TError }
        return TResult(ok, err)
      }
      if name == "Map" {
        let k = if rargs.length() >= 1 { rargs[0] } else { TError }
        let v = if rargs.length() >= 2 { rargs[1] } else { TError }
        return TMap(k, v)
      }
      if name == "Channel" {
        let elem = if rargs.length() >= 1 { rargs[0] } else { TError }
        return TChannel(elem)
      }
      if name == "Mutex" {
        let elem = if rargs.length() >= 1 { rargs[0] } else { TError }
        return TMutex(elem)
      }
      if tc.structs.contains(name) {
        return TStruct(name, rargs)
      }
      if tc.enums.contains(name) {
        return TEnum(name, rargs)
      }
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "unknown type `" + name + "`",
        "defined type",
        name,
        "declare `" + name + "` or check its spelling",
      )
      TError
    }
  }
}

///|
fn subst_ty(t : Ty, subst : Map[String, Ty]) -> Ty {
  match t {
    TParam(n) =>
      match subst.get(n) {
        Some(rep) => rep
        None => t
      }
    TArray(e) => TArray(subst_ty(e, subst))
    TOption(e) => TOption(subst_ty(e, subst))
    TResult(ok, err) => TResult(subst_ty(ok, subst), subst_ty(err, subst))
    TMap(k, v) => TMap(subst_ty(k, subst), subst_ty(v, subst))
    TChannel(e) => TChannel(subst_ty(e, subst))
    TMutex(e) => TMutex(subst_ty(e, subst))
    TStruct(name, args) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < args.length() {
        out.push(subst_ty(args[i], subst))
        i = i + 1
      }
      TStruct(name, out)
    }
    TEnum(name, args) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < args.length() {
        out.push(subst_ty(args[i], subst))
        i = i + 1
      }
      TEnum(name, out)
    }
    TFn(params, ret) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < params.length() {
        out.push(subst_ty(params[i], subst))
        i = i + 1
      }
      TFn(out, subst_ty(ret, subst))
    }
    TTuple(elems) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < elems.length() {
        out.push(subst_ty(elems[i], subst))
        i = i + 1
      }
      TTuple(out)
    }
    _ => t
  }
}

///|
fn make_subst(tparams : Array[String], targs : Array[Ty]) -> Map[String, Ty] {
  let m : Map[String, Ty] = Map([])
  let mut i = 0
  while i < tparams.length() && i < targs.length() {
    m.set(tparams[i], targs[i])
    i = i + 1
  }
  m
}

///|
fn unify_tparams(pattern : Ty, actual : Ty, subst : Map[String, Ty]) -> Unit {
  match pattern {
    TParam(n) =>
      if !subst.contains(n) {
        match actual {
          TError => ()
          _ => subst.set(n, actual)
        }
      }
    TArray(pe) =>
      match actual {
        TArray(ae) => unify_tparams(pe, ae, subst)
        _ => ()
      }
    TOption(pe) =>
      match actual {
        TOption(ae) => unify_tparams(pe, ae, subst)
        _ => ()
      }
    TResult(po, pe) =>
      match actual {
        TResult(ao, ae) => {
          unify_tparams(po, ao, subst)
          unify_tparams(pe, ae, subst)
        }
        _ => ()
      }
    TMap(pk, pv) =>
      match actual {
        TMap(ak, av) => {
          unify_tparams(pk, ak, subst)
          unify_tparams(pv, av, subst)
        }
        _ => ()
      }
    TChannel(pe) =>
      match actual {
        TChannel(ae) => unify_tparams(pe, ae, subst)
        _ => ()
      }
    TMutex(pe) =>
      match actual {
        TMutex(ae) => unify_tparams(pe, ae, subst)
        _ => ()
      }
    TStruct(pn, pargs) =>
      match actual {
        TStruct(an, aargs) =>
          if pn == an {
            let mut i = 0
            while i < pargs.length() && i < aargs.length() {
              unify_tparams(pargs[i], aargs[i], subst)
              i = i + 1
            }
          }
        _ => ()
      }
    TEnum(pn, pargs) =>
      match actual {
        TEnum(an, aargs) =>
          if pn == an {
            let mut i = 0
            while i < pargs.length() && i < aargs.length() {
              unify_tparams(pargs[i], aargs[i], subst)
              i = i + 1
            }
          }
        _ => ()
      }
    TFn(pp, pr) =>
      match actual {
        TFn(ap, ar) => {
          let mut i = 0
          while i < pp.length() && i < ap.length() {
            unify_tparams(pp[i], ap[i], subst)
            i = i + 1
          }
          unify_tparams(pr, ar, subst)
        }
        _ => ()
      }
    TTuple(pe) =>
      match actual {
        TTuple(ae) => {
          let mut i = 0
          while i < pe.length() && i < ae.length() {
            unify_tparams(pe[i], ae[i], subst)
            i = i + 1
          }
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn ty_compat(expected : Ty, found : Ty) -> Bool {
  match expected {
    TError | TNever => return true
    _ => ()
  }
  match found {
    TError | TNever => return true
    _ => ()
  }
  match expected {
    TInt =>
      match found {
        TInt => true
        _ => false
      }
    TInt64 =>
      match found {
        TInt64 => true
        _ => false
      }
    TDouble =>
      match found {
        TDouble => true
        _ => false
      }
    TBool =>
      match found {
        TBool => true
        _ => false
      }
    TByte =>
      match found {
        TByte => true
        _ => false
      }
    TChar =>
      match found {
        TChar => true
        _ => false
      }
    TString =>
      match found {
        TString => true
        _ => false
      }
    TUnit =>
      match found {
        TUnit => true
        _ => false
      }
    TStringBuilder =>
      match found {
        TStringBuilder => true
        _ => false
      }
    TBytes =>
      match found {
        TBytes => true
        _ => false
      }
    TWorld =>
      match found {
        TWorld => true
        _ => false
      }
    TScope =>
      match found {
        TScope => true
        _ => false
      }
    TAtomicInt =>
      match found {
        TAtomicInt => true
        _ => false
      }
    TParam(a) =>
      match found {
        TParam(b) => a == b
        _ => false
      }
    TArray(e1) =>
      match found {
        TArray(e2) => ty_compat(e1, e2)
        _ => false
      }
    TOption(e1) =>
      match found {
        TOption(e2) => ty_compat(e1, e2)
        _ => false
      }
    TResult(o1, e1) =>
      match found {
        TResult(o2, e2) => ty_compat(o1, o2) && ty_compat(e1, e2)
        _ => false
      }
    TMap(k1, v1) =>
      match found {
        TMap(k2, v2) => ty_compat(k1, k2) && ty_compat(v1, v2)
        _ => false
      }
    TChannel(e1) =>
      match found {
        TChannel(e2) => ty_compat(e1, e2)
        _ => false
      }
    TMutex(e1) =>
      match found {
        TMutex(e2) => ty_compat(e1, e2)
        _ => false
      }
    TStruct(n1, a1) =>
      match found {
        TStruct(n2, a2) => {
          if n1 != n2 || a1.length() != a2.length() {
            return false
          }
          let mut i = 0
          while i < a1.length() {
            if !ty_compat(a1[i], a2[i]) {
              return false
            }
            i = i + 1
          }
          true
        }
        _ => false
      }
    TEnum(n1, a1) =>
      match found {
        TEnum(n2, a2) => {
          if n1 != n2 || a1.length() != a2.length() {
            return false
          }
          let mut i = 0
          while i < a1.length() {
            if !ty_compat(a1[i], a2[i]) {
              return false
            }
            i = i + 1
          }
          true
        }
        _ => false
      }
    TFn(p1, r1) =>
      match found {
        TFn(p2, r2) => {
          if p1.length() != p2.length() {
            return false
          }
          let mut i = 0
          while i < p1.length() {
            if !ty_compat(p1[i], p2[i]) {
              return false
            }
            i = i + 1
          }
          ty_compat(r1, r2)
        }
        _ => false
      }
    TTuple(e1) =>
      match found {
        TTuple(e2) => {
          if e1.length() != e2.length() {
            return false
          }
          let mut i = 0
          while i < e1.length() {
            if !ty_compat(e1[i], e2[i]) {
              return false
            }
            i = i + 1
          }
          true
        }
        _ => false
      }
    TNever | TError => true
  }
}

///|
fn is_send_ty(tc : TypeChecker, t : Ty, visiting : Array[String]) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TChar | TString | TUnit => true
    TAtomicInt | TScope | TNever | TError => true
    TArray(_) | TBytes | TMap(_, _) | TStringBuilder | TWorld => false
    TParam(_) => false
    TOption(e) => is_send_ty(tc, e, visiting)
    TResult(ok, err) =>
      is_send_ty(tc, ok, visiting) && is_send_ty(tc, err, visiting)
    TChannel(e) => is_send_ty(tc, e, visiting)
    TMutex(e) => is_send_ty(tc, e, visiting)
    TFn(_, _) => false
    TTuple(elems) => {
      let mut i = 0
      while i < elems.length() {
        if !is_send_ty(tc, elems[i], visiting) {
          return false
        }
        i = i + 1
      }
      true
    }
    TStruct(name, args) => {
      if str_arr_contains(visiting, name) {
        return true
      }
      match tc.structs.get(name) {
        None => false
        Some(sinfo) => {
          let next_vis = visiting.copy()
          next_vis.push(name)
          let subst = make_subst(sinfo.decl.type_params, args)
          let mut i = 0
          while i < sinfo.field_tys.length() {
            if sinfo.field_muts[i] {
              return false
            }
            let fty = subst_ty(sinfo.field_tys[i], subst)
            if !is_send_ty(tc, fty, next_vis) {
              return false
            }
            i = i + 1
          }
          true
        }
      }
    }
    TEnum(name, args) => {
      if str_arr_contains(visiting, name) {
        return true
      }
      match tc.enums.get(name) {
        None => false
        Some(einfo) => {
          let next_vis = visiting.copy()
          next_vis.push(name)
          let subst = make_subst(einfo.decl.type_params, args)
          let mut vi = 0
          while vi < einfo.variants.length() {
            let v = einfo.variants[vi]
            let mut fi = 0
            while fi < v.field_tys.length() {
              let fty = subst_ty(v.field_tys[fi], subst)
              if !is_send_ty(tc, fty, next_vis) {
                return false
              }
              fi = fi + 1
            }
            vi = vi + 1
          }
          true
        }
      }
    }
  }
}

///|
fn is_world_builtin(name : String) -> Bool {
  name == "io_println" ||
  name == "io_eprintln" ||
  name == "fs_read" ||
  name == "fs_write" ||
  name == "fs_exists" ||
  name == "fs_mkdir_p" ||
  name == "fs_list_dir" ||
  name == "clock_now_ms" ||
  name == "proc_exec" ||
  name == "env_get" ||
  name == "args_get"
}

///|
fn check_world_builtin_call(
  tc : TypeChecker,
  env : Env,
  name : String,
  args : Array[Expr],
  sp : Span,
) -> Ty {
  let arg_tys : Array[Ty] = []
  let mut i = 0
  while i < args.length() {
    arg_tys.push(check_expr(tc, env, args[i], None))
    i = i + 1
  }
  let mut has_world_arg = false
  if arg_tys.length() > 0 {
    match arg_tys[0] {
      TWorld => has_world_arg = true
      _ => ()
    }
  }
  if !env.has_world && !has_world_arg {
    tc_err(
      tc,
      sp,
      "E_CAPABILITY_MISSING",
      "calling `" + name + "` requires a `World` capability in scope",
      "World",
      "none",
      "add `world : World` parameter to the enclosing function",
    )
  }
  let offset = if has_world_arg { 1 } else { 0 }
  if name == "io_println" || name == "io_eprintln" {
    if arg_tys.length() > offset && !ty_compat(TString, arg_tys[offset]) {
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "`" + name + "` expects `String` argument",
        "String",
        ty_to_string(arg_tys[offset]),
        "pass a `String` value",
      )
    }
    TUnit
  } else if name == "fs_read" {
    TResult(TString, TString)
  } else if name == "fs_write" {
    TResult(TUnit, TString)
  } else if name == "fs_exists" || name == "fs_mkdir_p" {
    TBool
  } else if name == "fs_list_dir" || name == "args_get" {
    TArray(TString)
  } else if name == "clock_now_ms" {
    TInt64
  } else if name == "proc_exec" {
    TInt
  } else if name == "env_get" {
    TOption(TString)
  } else {
    TUnit
  }
}

///|
pub struct CaptureInfo {
  name : String
  is_moved : Bool
  span : Span
}

///|
fn collect_pat_bindings(pat : Pattern, bound : Map[String, Bool]) -> Unit {
  match pat {
    PWild(_) | PBool(_, _) | PInt(_, _) | PString(_, _) | PChar(_, _) => ()
    PIdent(n, _) => bound.set(n, true)
    PVariant(_, _, sub, _) => {
      let mut i = 0
      while i < sub.length() {
        collect_pat_bindings(sub[i], bound)
        i = i + 1
      }
    }
    PTuple(sub, _) => {
      let mut i = 0
      while i < sub.length() {
        collect_pat_bindings(sub[i], bound)
        i = i + 1
      }
    }
  }
}

///|
fn collect_stmts_captures(
  stmts : Array[Stmt],
  locals : Map[String, Bool],
  out : Array[CaptureInfo],
) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    match stmts[i] {
      SLet(name, _, _, init, _) => {
        collect_expr_captures(init, locals, out)
        locals.set(name, true)
      }
      SAssign(lhs, rhs, _) => {
        collect_expr_captures(lhs, locals, out)
        collect_expr_captures(rhs, locals, out)
      }
      SWhile(cond, body, _) => {
        collect_expr_captures(cond, locals, out)
        collect_stmts_captures(body, locals, out)
      }
      SFor(init_s, cond, step_s, body, _) => {
        collect_stmts_captures([init_s], locals, out)
        collect_expr_captures(cond, locals, out)
        collect_stmts_captures([step_s], locals, out)
        collect_stmts_captures(body, locals, out)
      }
      SReturn(opt, _) =>
        match opt {
          Some(e) => collect_expr_captures(e, locals, out)
          None => ()
        }
      SBreak(_) | SContinue(_) => ()
      SDebugAssert(c, m, _) => {
        collect_expr_captures(c, locals, out)
        collect_expr_captures(m, locals, out)
      }
      SExpr(e, _) => collect_expr_captures(e, locals, out)
    }
    i = i + 1
  }
}

///|
fn collect_expr_captures(
  e : Expr,
  locals : Map[String, Bool],
  out : Array[CaptureInfo],
) -> Unit {
  match e {
    EInt(_, _) | EInt64(_, _) | EDouble(_, _) | EBool(_, _) => ()
    EByte(_, _) | EChar(_, _) | EString(_, _) | EUnit(_) | EPath(_, _, _) => ()
    EIdent(name, sp) =>
      if !locals.contains(name) {
        out.push(CaptureInfo::{ name: name, is_moved: false, span: sp })
      }
    EMove(inner, sp) =>
      match inner {
        EIdent(name, _) =>
          if !locals.contains(name) {
            out.push(CaptureInfo::{ name: name, is_moved: true, span: sp })
          }
        _ => collect_expr_captures(inner, locals, out)
      }
    EUnary(_, inner, _) => collect_expr_captures(inner, locals, out)
    EBinary(_, l, r, _) => {
      collect_expr_captures(l, locals, out)
      collect_expr_captures(r, locals, out)
    }
    ECall(callee, args, _) => {
      collect_expr_captures(callee, locals, out)
      let mut i = 0
      while i < args.length() {
        collect_expr_captures(args[i], locals, out)
        i = i + 1
      }
    }
    EField(obj, _, _) => collect_expr_captures(obj, locals, out)
    EMethodCall(obj, _, args, _) => {
      collect_expr_captures(obj, locals, out)
      let mut i = 0
      while i < args.length() {
        collect_expr_captures(args[i], locals, out)
        i = i + 1
      }
    }
    EIndex(obj, idx, _) => {
      collect_expr_captures(obj, locals, out)
      collect_expr_captures(idx, locals, out)
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        collect_expr_captures(elems[i], locals, out)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        collect_expr_captures(fields[i].value, locals, out)
        i = i + 1
      }
    }
    EBlock(stmts, _) => collect_stmts_captures(stmts, locals, out)
    EIf(cond, then_s, else_opt, _) => {
      collect_expr_captures(cond, locals, out)
      collect_stmts_captures(then_s, locals, out)
      match else_opt {
        Some(el) => collect_expr_captures(el, locals, out)
        None => ()
      }
    }
    EMatch(scrut, arms, _) => {
      collect_expr_captures(scrut, locals, out)
      let mut i = 0
      while i < arms.length() {
        collect_pat_bindings(arms[i].pat, locals)
        collect_expr_captures(arms[i].body, locals, out)
        i = i + 1
      }
    }
    EClosure(params, _, body, _) => {
      let mut i = 0
      while i < params.length() {
        locals.set(params[i].name, true)
        i = i + 1
      }
      collect_stmts_captures(body, locals, out)
    }
    EScope(w, f, _) => {
      collect_expr_captures(w, locals, out)
      collect_expr_captures(f, locals, out)
    }
    ESpawn(s, f, _) => {
      collect_expr_captures(s, locals, out)
      collect_expr_captures(f, locals, out)
    }
    EAs(inner, _, _) => collect_expr_captures(inner, locals, out)
  }
}

///|
fn check_match_exhaustiveness(
  tc : TypeChecker,
  scrut_ty : Ty,
  arms : Array[MatchArm],
  sp : Span,
) -> Unit {
  let mut has_wild = false
  let covered : Array[String] = []
  let mut i = 0
  while i < arms.length() {
    match arms[i].pat {
      PWild(_) | PIdent(_, _) => has_wild = true
      PBool(b, _) => covered.push(if b { "true" } else { "false" })
      PVariant(_, vname, _, _) => covered.push(vname)
      _ => ()
    }
    i = i + 1
  }
  if has_wild {
    return
  }
  match scrut_ty {
    TError | TNever => ()
    TBool => {
      let missing : Array[String] = []
      if !str_arr_contains(covered, "true") {
        missing.push("true")
      }
      if !str_arr_contains(covered, "false") {
        missing.push("false")
      }
      if missing.length() > 0 {
        let miss_str = join_strs(missing, ", ")
        tc_err(
          tc,
          sp,
          "E_NON_EXHAUSTIVE",
          "non-exhaustive `match` on `Bool`: missing " + miss_str,
          "exhaustive match",
          "missing " + miss_str,
          "add missing match arm(s): " + miss_str + " => ...",
        )
      }
    }
    TOption(_) => {
      let missing : Array[String] = []
      if !str_arr_contains(covered, "Some") {
        missing.push("Some(_)")
      }
      if !str_arr_contains(covered, "None") {
        missing.push("None")
      }
      if missing.length() > 0 {
        let miss_str = join_strs(missing, ", ")
        tc_err(
          tc,
          sp,
          "E_NON_EXHAUSTIVE",
          "non-exhaustive `match` on `Option`: missing " + miss_str,
          "exhaustive match",
          "missing " + miss_str,
          "add missing match arm(s): " + miss_str + " => ...",
        )
      }
    }
    TResult(_, _) => {
      let missing : Array[String] = []
      if !str_arr_contains(covered, "Ok") {
        missing.push("Ok(_)")
      }
      if !str_arr_contains(covered, "Err") {
        missing.push("Err(_)")
      }
      if missing.length() > 0 {
        let miss_str = join_strs(missing, ", ")
        tc_err(
          tc,
          sp,
          "E_NON_EXHAUSTIVE",
          "non-exhaustive `match` on `Result`: missing " + miss_str,
          "exhaustive match",
          "missing " + miss_str,
          "add missing match arm(s): " + miss_str + " => ...",
        )
      }
    }
    TEnum(ename, _) =>
      match tc.enums.get(ename) {
        None => ()
        Some(einfo) => {
          let missing : Array[String] = []
          let mut vi = 0
          while vi < einfo.variants.length() {
            let v = einfo.variants[vi]
            if !str_arr_contains(covered, v.name) {
              missing.push(v.name)
            }
            vi = vi + 1
          }
          if missing.length() > 0 {
            let miss_str = join_strs(missing, ", ")
            tc_err(
              tc,
              sp,
              "E_NON_EXHAUSTIVE",
              "non-exhaustive `match` on `" + ename + "`: missing " + miss_str,
              "exhaustive match",
              "missing " + miss_str,
              "add missing match arm(s): " + miss_str + " => ...",
            )
          }
        }
      }
    _ =>
      tc_err(
        tc,
        sp,
        "E_NON_EXHAUSTIVE",
        "non-exhaustive `match` on `" + ty_to_string(scrut_ty) + "`",
        "exhaustive match",
        "missing wildcard `_`",
        "add a wildcard arm `_ => ...`",
      )
  }
}

///|
fn join_strs(items : Array[String], sep : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < items.length() {
    if i > 0 {
      sb.write_string(sep)
    }
    sb.write_string(items[i])
    i = i + 1
  }
  sb.to_string()
}

///|
fn bind_pattern(
  tc : TypeChecker,
  env : Env,
  pat : Pattern,
  scrut_ty : Ty,
) -> Unit {
  match pat {
    PWild(_) => ()
    PIdent(name, _) => env_define(env, name, scrut_ty, false)
    PBool(_, sp) =>
      if !ty_compat(TBool, scrut_ty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "bool pattern cannot match `" + ty_to_string(scrut_ty) + "`",
          "Bool",
          ty_to_string(scrut_ty),
          "use a pattern matching `" + ty_to_string(scrut_ty) + "`",
        )
      }
    PInt(_, sp) =>
      if !ty_compat(TInt, scrut_ty) && !ty_compat(TInt64, scrut_ty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "integer pattern cannot match `" + ty_to_string(scrut_ty) + "`",
          "Int",
          ty_to_string(scrut_ty),
          "use a pattern matching `" + ty_to_string(scrut_ty) + "`",
        )
      }
    PString(_, sp) =>
      if !ty_compat(TString, scrut_ty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "string pattern cannot match `" + ty_to_string(scrut_ty) + "`",
          "String",
          ty_to_string(scrut_ty),
          "use a pattern matching `" + ty_to_string(scrut_ty) + "`",
        )
      }
    PChar(_, sp) =>
      if !ty_compat(TChar, scrut_ty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "char pattern cannot match `" + ty_to_string(scrut_ty) + "`",
          "Char",
          ty_to_string(scrut_ty),
          "use a pattern matching `" + ty_to_string(scrut_ty) + "`",
        )
      }
    PTuple(sub, _) =>
      match scrut_ty {
        TTuple(elems) => {
          let mut i = 0
          while i < sub.length() && i < elems.length() {
            bind_pattern(tc, env, sub[i], elems[i])
            i = i + 1
          }
        }
        _ => ()
      }
    PVariant(_, vname, sub, _) =>
      match scrut_ty {
        TOption(inner) =>
          if vname == "Some" && sub.length() >= 1 {
            bind_pattern(tc, env, sub[0], inner)
          }
        TResult(ok, err) =>
          if vname == "Ok" && sub.length() >= 1 {
            bind_pattern(tc, env, sub[0], ok)
          } else if vname == "Err" && sub.length() >= 1 {
            bind_pattern(tc, env, sub[0], err)
          }
        TEnum(ename, args) =>
          match tc.enums.get(ename) {
            None => ()
            Some(einfo) => {
              let subst = make_subst(einfo.decl.type_params, args)
              let mut vi = 0
              while vi < einfo.variants.length() {
                let v = einfo.variants[vi]
                if v.name == vname {
                  let mut fi = 0
                  while fi < sub.length() && fi < v.field_tys.length() {
                    let fty = subst_ty(v.field_tys[fi], subst)
                    bind_pattern(tc, env, sub[fi], fty)
                    fi = fi + 1
                  }
                  break
                }
                vi = vi + 1
              }
            }
          }
        _ => ()
      }
  }
}

///|
fn check_stmts(
  tc : TypeChecker,
  env : Env,
  stmts : Array[Stmt],
  expected : Option[Ty],
) -> Ty {
  if stmts.length() == 0 {
    return TUnit
  }
  let mut i = 0
  let mut last_ty = TUnit
  while i < stmts.length() {
    let is_last = i == stmts.length() - 1
    let exp = if is_last { expected } else { None }
    last_ty = check_stmt(tc, env, stmts[i], exp)
    i = i + 1
  }
  last_ty
}

///|
fn check_stmt(
  tc : TypeChecker,
  env : Env,
  stmt : Stmt,
  expected : Option[Ty],
) -> Ty {
  match stmt {
    SLet(name, is_mut, ty_expr, init, sp) => {
      let ann_opt : Option[Ty] = match ty_expr {
        TyMissing(_) => None
        _ => Some(resolve_type_expr(tc, ty_expr, env.type_params))
      }
      let init_ty = check_expr(tc, env, init, ann_opt)
      let final_ty = match ann_opt {
        Some(ann) => {
          if !ty_compat(ann, init_ty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "type mismatch in `let " + name + "`",
              ty_to_string(ann),
              ty_to_string(init_ty),
              "change the initializer or the type annotation to `" +
              ty_to_string(ann) +
              "`",
            )
          }
          ann
        }
        None => init_ty
      }
      if name != "_" {
        env_define(env, name, final_ty, is_mut)
      }
      TUnit
    }
    SAssign(lhs, rhs, sp) => {
      match lhs {
        EIdent(name, lsp) =>
          match env_lookup(env, name) {
            Some(b) => {
              if !b.is_mut {
                tc_err(
                  tc,
                  lsp,
                  "E_TYPE_MISMATCH",
                  "cannot assign to immutable variable `" + name + "`",
                  "mutable binding",
                  "immutable `" + name + "`",
                  "declare `" + name + "` with `let mut " + name + "`",
                )
              }
              let rty = check_expr(tc, env, rhs, Some(b.ty))
              if !ty_compat(b.ty, rty) {
                tc_err(
                  tc,
                  sp,
                  "E_TYPE_MISMATCH",
                  "type mismatch in assignment to `" + name + "`",
                  ty_to_string(b.ty),
                  ty_to_string(rty),
                  "assign a value of type `" + ty_to_string(b.ty) + "`",
                )
              }
              if env.moved.contains(name) {
                env.moved.remove(name)
              }
            }
            None => {
              // Allow `for i = 0; ...` style init if not yet bound
              let rty = check_expr(tc, env, rhs, None)
              env_define(env, name, rty, true)
            }
          }
        _ => {
          let lty = check_expr(tc, env, lhs, None)
          let rty = check_expr(tc, env, rhs, Some(lty))
          if !ty_compat(lty, rty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "type mismatch in assignment",
              ty_to_string(lty),
              ty_to_string(rty),
              "assign a value of type `" + ty_to_string(lty) + "`",
            )
          }
        }
      }
      TUnit
    }
    SWhile(cond, body, sp) => {
      let cty = check_expr(tc, env, cond, Some(TBool))
      if !ty_compat(TBool, cty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`while` condition must be `Bool`",
          "Bool",
          ty_to_string(cty),
          "use a boolean condition",
        )
      }
      env_push(env)
      let _ = check_stmts(tc, env, body, None)
      env_pop(env)
      TUnit
    }
    SFor(init_s, cond, step_s, body, sp) => {
      env_push(env)
      let _ = check_stmt(tc, env, init_s, None)
      let cty = check_expr(tc, env, cond, Some(TBool))
      if !ty_compat(TBool, cty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`for` condition must be `Bool`",
          "Bool",
          ty_to_string(cty),
          "use a boolean condition",
        )
      }
      let _ = check_stmt(tc, env, step_s, None)
      let _ = check_stmts(tc, env, body, None)
      env_pop(env)
      TUnit
    }
    SReturn(opt, sp) => {
      let rty = match opt {
        Some(e) => check_expr(tc, env, e, Some(env.ret_ty))
        None => TUnit
      }
      if !ty_compat(env.ret_ty, rty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "return type mismatch",
          ty_to_string(env.ret_ty),
          ty_to_string(rty),
          "return a value of type `" + ty_to_string(env.ret_ty) + "`",
        )
      }
      TNever
    }
    SBreak(_) | SContinue(_) => TNever
    SDebugAssert(cond, msg, sp) => {
      let cty = check_expr(tc, env, cond, Some(TBool))
      if !ty_compat(TBool, cty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`debug_assert` condition must be `Bool`",
          "Bool",
          ty_to_string(cty),
          "pass a `Bool` expression as the first argument",
        )
      }
      let mty = check_expr(tc, env, msg, Some(TString))
      if !ty_compat(TString, mty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`debug_assert` message must be `String`",
          "String",
          ty_to_string(mty),
          "pass a `String` message as the second argument",
        )
      }
      TUnit
    }
    SExpr(e, _) => check_expr(tc, env, e, expected)
  }
}

///|
fn check_variant_ctor(
  tc : TypeChecker,
  env : Env,
  enum_name : String,
  vname : String,
  args : Array[Expr],
  expected : Option[Ty],
  sp : Span,
) -> Ty {
  if enum_name == "Option" || (enum_name == "" && (vname == "Some" || vname == "None")) {
    let exp_inner : Option[Ty] = match expected {
      Some(TOption(inner)) => Some(inner)
      _ => None
    }
    if vname == "None" {
      return match exp_inner {
        Some(t) => TOption(t)
        None => TOption(TError)
      }
    }
    let aty = if args.length() >= 1 {
      check_expr(tc, env, args[0], exp_inner)
    } else {
      TError
    }
    return TOption(aty)
  }
  if enum_name == "Result" || (enum_name == "" && (vname == "Ok" || vname == "Err")) {
    let mut exp_ok : Option[Ty] = None
    let mut exp_err : Option[Ty] = None
    match expected {
      Some(TResult(o, e)) => {
        exp_ok = Some(o)
        exp_err = Some(e)
      }
      _ => ()
    }
    if vname == "Ok" {
      let oty = if args.length() >= 1 {
        check_expr(tc, env, args[0], exp_ok)
      } else {
        TError
      }
      let ety = match exp_err {
        Some(e) => e
        None => TError
      }
      return TResult(oty, ety)
    } else {
      let ety = if args.length() >= 1 {
        check_expr(tc, env, args[0], exp_err)
      } else {
        TError
      }
      let oty = match exp_ok {
        Some(o) => o
        None => TError
      }
      return TResult(oty, ety)
    }
  }
  let resolved_enum = if enum_name != "" {
    enum_name
  } else {
    match tc.variant_to_enum.get(vname) {
      Some(en) => en
      None => ""
    }
  }
  if resolved_enum == "" {
    return TError
  }
  match tc.enums.get(resolved_enum) {
    None => TError
    Some(einfo) => {
      let subst : Map[String, Ty] = Map([])
      match expected {
        Some(TEnum(en, eargs)) =>
          if en == resolved_enum {
            let mut k = 0
            while k < einfo.decl.type_params.length() && k < eargs.length() {
              subst.set(einfo.decl.type_params[k], eargs[k])
              k = k + 1
            }
          }
        _ => ()
      }
      let mut vi = 0
      while vi < einfo.variants.length() {
        let v = einfo.variants[vi]
        if v.name == vname {
          if args.length() != v.field_tys.length() {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "variant `" +
              vname +
              "` expects " +
              v.field_tys.length().to_string() +
              " argument(s), found " +
              args.length().to_string(),
              v.field_tys.length().to_string() + " args",
              args.length().to_string() + " args",
              "pass the exact number of fields for `" + vname + "`",
            )
          }
          let mut fi = 0
          while fi < args.length() && fi < v.field_tys.length() {
            let exp_f = subst_ty(v.field_tys[fi], subst)
            let aty = check_expr(tc, env, args[fi], Some(exp_f))
            unify_tparams(v.field_tys[fi], aty, subst)
            let exp_f2 = subst_ty(v.field_tys[fi], subst)
            if !ty_compat(exp_f2, aty) {
              tc_err(
                tc,
                expr_span(args[fi]),
                "E_TYPE_MISMATCH",
                "variant `" + vname + "` argument type mismatch",
                ty_to_string(exp_f2),
                ty_to_string(aty),
                "pass a value of type `" + ty_to_string(exp_f2) + "`",
              )
            }
            fi = fi + 1
          }
          break
        }
        vi = vi + 1
      }
      let targs : Array[Ty] = []
      let mut ti = 0
      while ti < einfo.decl.type_params.length() {
        match subst.get(einfo.decl.type_params[ti]) {
          Some(t) => targs.push(t)
          None => targs.push(TError)
        }
        ti = ti + 1
      }
      TEnum(resolved_enum, targs)
    }
  }
}

///|
fn check_fn_call(
  tc : TypeChecker,
  env : Env,
  finfo : FnInfo,
  args : Array[Expr],
  expected : Option[Ty],
  sp : Span,
) -> Ty {
  let subst : Map[String, Ty] = Map([])
  match expected {
    Some(exp_ty) => unify_tparams(finfo.ret_ty, exp_ty, subst)
    None => ()
  }
  if args.length() != finfo.param_tys.length() {
    tc_err(
      tc,
      sp,
      "E_TYPE_MISMATCH",
      "function `" +
      finfo.decl.name +
      "` expects " +
      finfo.param_tys.length().to_string() +
      " argument(s), found " +
      args.length().to_string(),
      finfo.param_tys.length().to_string() + " args",
      args.length().to_string() + " args",
      "pass " + finfo.param_tys.length().to_string() + " argument(s)",
    )
  }
  let mut i = 0
  while i < args.length() {
    let exp_p : Option[Ty] = if i < finfo.param_tys.length() {
      Some(subst_ty(finfo.param_tys[i], subst))
    } else {
      None
    }
    let aty = check_expr(tc, env, args[i], exp_p)
    if i < finfo.param_tys.length() {
      unify_tparams(finfo.param_tys[i], aty, subst)
      let pty = subst_ty(finfo.param_tys[i], subst)
      if !ty_compat(pty, aty) {
        tc_err(
          tc,
          expr_span(args[i]),
          "E_TYPE_MISMATCH",
          "argument " + (i + 1).to_string() + " type mismatch in call to `" + finfo.decl.name + "`",
          ty_to_string(pty),
          ty_to_string(aty),
          "pass a value of type `" + ty_to_string(pty) + "`",
        )
      }
    }
    i = i + 1
  }
  subst_ty(finfo.ret_ty, subst)
}

///|
fn check_method_call(
  tc : TypeChecker,
  env : Env,
  recv_ty : Ty,
  method_name : String,
  args : Array[Expr],
  expected : Option[Ty],
  sp : Span,
) -> Ty {
  // Builtin methods on standard types
  match recv_ty {
    TError => {
      let mut i = 0
      while i < args.length() {
        let _ = check_expr(tc, env, args[i], None)
        i = i + 1
      }
      return TError
    }
    TInt => {
      if method_name == "to_string" {
        return TString
      }
      if method_name == "to_int64" {
        return TInt64
      }
      if method_name == "to_int" {
        return TInt
      }
      if method_name == "unsafe_to_char" {
        return TChar
      }
    }
    TInt64 => {
      if method_name == "to_string" {
        return TString
      }
      if method_name == "to_int" {
        return TInt
      }
    }
    TDouble => {
      if method_name == "to_string" {
        return TString
      }
      if method_name == "to_int" {
        return TInt
      }
    }
    TBool =>
      if method_name == "to_string" {
        return TString
      }
    TChar => {
      if method_name == "to_int" {
        return TInt
      }
      if method_name == "to_string" {
        return TString
      }
    }
    TByte =>
      if method_name == "to_int" {
        return TInt
      }
    TString => {
      if method_name == "length" {
        return TInt
      }
      if method_name == "to_string" {
        return TString
      }
      if method_name == "code_unit_at" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        return TInt
      }
    }
    TStringBuilder => {
      if method_name == "write_string" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`StringBuilder::write_string` expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String`",
            )
          }
        }
        return TUnit
      }
      if method_name == "write_char" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TChar))
          if !ty_compat(TChar, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`StringBuilder::write_char` expects `Char`",
              "Char",
              ty_to_string(aty),
              "pass a `Char`",
            )
          }
        }
        return TUnit
      }
      if method_name == "to_string" {
        return TString
      }
    }
    TBytes =>
      if method_name == "length" {
        return TInt
      }
    TArray(elem) => {
      if method_name == "length" {
        return TInt
      }
      if method_name == "push" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(elem))
          if !ty_compat(elem, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Array::push` element type mismatch",
              ty_to_string(elem),
              ty_to_string(aty),
              "push a value of type `" + ty_to_string(elem) + "`",
            )
          }
        }
        return TUnit
      }
      if method_name == "pop" {
        return TOption(elem)
      }
      if method_name == "copy" {
        return TArray(elem)
      }
      if method_name == "contains" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(elem))
        }
        return TBool
      }
    }
    TMap(kty, vty) => {
      if method_name == "length" {
        return TInt
      }
      if method_name == "set" {
        if args.length() >= 2 {
          let ak = check_expr(tc, env, args[0], Some(kty))
          let av = check_expr(tc, env, args[1], Some(vty))
          if !ty_compat(kty, ak) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Map::set` key type mismatch",
              ty_to_string(kty),
              ty_to_string(ak),
              "use a key of type `" + ty_to_string(kty) + "`",
            )
          }
          if !ty_compat(vty, av) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Map::set` value type mismatch",
              ty_to_string(vty),
              ty_to_string(av),
              "use a value of type `" + ty_to_string(vty) + "`",
            )
          }
        }
        return TUnit
      }
      if method_name == "get" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(kty))
        }
        return TOption(vty)
      }
      if method_name == "contains" || method_name == "remove" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(kty))
        }
        return if method_name == "contains" { TBool } else { TUnit }
      }
      if method_name == "keys" {
        return TArray(kty)
      }
    }
    TChannel(elem) => {
      if method_name == "send" {
        if args.length() >= 1 {
          let arg = args[0]
          let is_explicit_move = match arg {
            EMove(_, _) => true
            _ => false
          }
          let aty = check_expr(tc, env, arg, Some(elem))
          if !ty_compat(elem, aty) {
            tc_err(
              tc,
              expr_span(arg),
              "E_TYPE_MISMATCH",
              "`Channel::send` value type mismatch",
              ty_to_string(elem),
              ty_to_string(aty),
              "send a value of type `" + ty_to_string(elem) + "`",
            )
          }
          if !is_explicit_move && !is_send_ty(tc, aty, []) {
            tc_err(
              tc,
              expr_span(arg),
              "E_NOT_SEND",
              "cannot send non-Send value of type `" +
              ty_to_string(aty) +
              "` over `Channel`",
              "Send",
              ty_to_string(aty),
              "wrap value in `Mutex::new(...)` or transfer ownership with `move`",
            )
          }
        }
        return TBool
      }
      if method_name == "recv" {
        return TOption(elem)
      }
      if method_name == "close" {
        return TUnit
      }
    }
    TMutex(elem) => {
      if method_name == "lock" {
        return elem
      }
      if method_name == "set" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(elem))
          if !ty_compat(elem, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Mutex::set` value type mismatch",
              ty_to_string(elem),
              ty_to_string(aty),
              "pass a value of type `" + ty_to_string(elem) + "`",
            )
          }
        }
        return TUnit
      }
      if method_name == "unlock" {
        return TUnit
      }
      if method_name == "with_lock" {
        if args.length() >= 1 {
          let fty = check_expr(tc, env, args[0], None)
          match fty {
            TFn(_, ret) => return ret
            _ => ()
          }
        }
        return match expected {
          Some(t) => t
          None => TUnit
        }
      }
    }
    TAtomicInt => {
      if method_name == "load" {
        return TInt
      }
      if method_name == "store" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        return TUnit
      }
      if method_name == "fetch_add" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        return TInt
      }
    }
    TStruct(sname, sargs) => {
      let key = sname + "::" + method_name
      match tc.methods.get(key) {
        Some(minfo) => {
          let subst = make_subst(minfo.decl.type_params, sargs)
          match expected {
            Some(exp_ty) => unify_tparams(minfo.ret_ty, exp_ty, subst)
            None => ()
          }
          // Skip `self` parameter (index 0)
          let mut i = 0
          while i < args.length() {
            let p_idx = i + 1
            let exp_p : Option[Ty] = if p_idx < minfo.param_tys.length() {
              Some(subst_ty(minfo.param_tys[p_idx], subst))
            } else {
              None
            }
            let aty = check_expr(tc, env, args[i], exp_p)
            if p_idx < minfo.param_tys.length() {
              unify_tparams(minfo.param_tys[p_idx], aty, subst)
              let pty = subst_ty(minfo.param_tys[p_idx], subst)
              if !ty_compat(pty, aty) {
                tc_err(
                  tc,
                  expr_span(args[i]),
                  "E_TYPE_MISMATCH",
                  "argument type mismatch in method `" + key + "`",
                  ty_to_string(pty),
                  ty_to_string(aty),
                  "pass a value of type `" + ty_to_string(pty) + "`",
                )
              }
            }
            i = i + 1
          }
          return subst_ty(minfo.ret_ty, subst)
        }
        None => ()
      }
    }
    _ => ()
  }
  tc_err(
    tc,
    sp,
    "E_TYPE_MISMATCH",
    "unknown method `" + method_name + "` on type `" + ty_to_string(recv_ty) + "`",
    "defined method",
    method_name,
    "define `fn " + ty_to_string(recv_ty) + "::" + method_name + "` or check method name",
  )
  TError
}

///|
fn check_expr(
  tc : TypeChecker,
  env : Env,
  expr : Expr,
  expected : Option[Ty],
) -> Ty {
  match expr {
    EInt(_, _) => TInt
    EInt64(_, _) => TInt64
    EDouble(_, _) => TDouble
    EBool(_, _) => TBool
    EByte(_, _) => TByte
    EChar(_, _) => TChar
    EString(_, _) => TString
    EUnit(_) => TUnit
    EIdent(name, sp) => {
      if env.moved.contains(name) {
        tc_err(
          tc,
          sp,
          "E_USE_AFTER_MOVE",
          "use of moved value `" + name + "`",
          "live binding",
          "moved variable `" + name + "`",
          "do not use `" + name + "` after `move`, or pass a separate value",
        )
      }
      match env_lookup(env, name) {
        Some(b) => return b.ty
        None => ()
      }
      match tc.consts.get(name) {
        Some(cty) => return cty
        None => ()
      }
      match tc.fns.get(name) {
        Some(finfo) => return TFn(finfo.param_tys, finfo.ret_ty)
        None => ()
      }
      if name == "None" {
        return check_variant_ctor(tc, env, "Option", "None", [], expected, sp)
      }
      if tc.variant_to_enum.contains(name) {
        return check_variant_ctor(tc, env, "", name, [], expected, sp)
      }
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "undefined identifier `" + name + "`",
        "defined variable or function",
        name,
        "declare `" + name + "` before use",
      )
      TError
    }
    EPath(qual, mem, sp) => {
      if qual == "Option" && mem == "None" {
        return check_variant_ctor(tc, env, "Option", "None", [], expected, sp)
      }
      if tc.enums.contains(qual) {
        return check_variant_ctor(tc, env, qual, mem, [], expected, sp)
      }
      let key = qual + "::" + mem
      match tc.methods.get(key) {
        Some(minfo) => return TFn(minfo.param_tys, minfo.ret_ty)
        None => ()
      }
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "unknown path `" + key + "`",
        "defined item",
        key,
        "check type and member name `" + key + "`",
      )
      TError
    }
    EMove(inner, sp) =>
      match inner {
        EIdent(name, isp) => {
          if env.moved.contains(name) {
            tc_err(
              tc,
              isp,
              "E_USE_AFTER_MOVE",
              "value `" + name + "` was already moved",
              "live binding",
              "moved variable `" + name + "`",
              "move `" + name + "` at most once",
            )
          }
          let ty = match env_lookup(env, name) {
            Some(b) => b.ty
            None => {
              tc_err(
                tc,
                isp,
                "E_TYPE_MISMATCH",
                "undefined variable `" + name + "` in `move`",
                "defined variable",
                name,
                "declare `" + name + "` before moving it",
              )
              TError
            }
          }
          env.moved.set(name, sp)
          ty
        }
        _ => check_expr(tc, env, inner, expected)
      }
    EUnary(op, inner, sp) => {
      let ity = check_expr(tc, env, inner, expected)
      if op == "!" {
        if !ty_compat(TBool, ity) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "unary `!` expects `Bool`",
            "Bool",
            ty_to_string(ity),
            "apply `!` to a `Bool` expression",
          )
        }
        TBool
      } else {
        ity
      }
    }
    EBinary(op, lhs, rhs, sp) => {
      let lty = check_expr(tc, env, lhs, None)
      let rty = check_expr(tc, env, rhs, Some(lty))
      if op == "&&" || op == "||" {
        if !ty_compat(TBool, lty) || !ty_compat(TBool, rty) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "operator `" + op + "` requires `Bool` operands",
            "Bool",
            ty_to_string(lty) + " and " + ty_to_string(rty),
            "use `Bool` operands with `" + op + "`",
          )
        }
        TBool
      } else if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
        if !ty_compat(lty, rty) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "comparison `" + op + "` operand type mismatch",
            ty_to_string(lty),
            ty_to_string(rty),
            "compare values of the same type",
          )
        }
        TBool
      } else if op == "<<" || op == ">>" {
        if !ty_compat(TInt, rty) && !ty_compat(lty, rty) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "shift operator `" + op + "` count must be `Int`",
            "Int",
            ty_to_string(rty),
            "use an `Int` shift count for `" + op + "`",
          )
        }
        lty
      } else {
        if !ty_compat(lty, rty) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "binary operator `" + op + "` operand type mismatch",
            ty_to_string(lty),
            ty_to_string(rty),
            "use matching operand types for `" + op + "`",
          )
        }
        lty
      }
    }
    ECall(callee, args, sp) =>
      match callee {
        EIdent(name, _) => {
          if name == "StringBuilder" {
            return TStringBuilder
          }
          if name == "Map" {
            return match expected {
              Some(TMap(k, v)) => TMap(k, v)
              _ => TMap(TString, TError)
            }
          }
          if is_world_builtin(name) {
            return check_world_builtin_call(tc, env, name, args, sp)
          }
          if name == "abort" || name == "panic" {
            let mut i = 0
            while i < args.length() {
              let _ = check_expr(tc, env, args[i], None)
              i = i + 1
            }
            return TNever
          }
          if name == "Some" || name == "Ok" || name == "Err" || tc.variant_to_enum.contains(name) {
            return check_variant_ctor(tc, env, "", name, args, expected, sp)
          }
          match tc.fns.get(name) {
            Some(finfo) => return check_fn_call(tc, env, finfo, args, expected, sp)
            None => ()
          }
          match env_lookup(env, name) {
            Some(b) => {
              if env.moved.contains(name) {
                tc_err(
                  tc,
                  sp,
                  "E_USE_AFTER_MOVE",
                  "use of moved closure `" + name + "`",
                  "live binding",
                  "moved variable `" + name + "`",
                  "do not call `" + name + "` after `move`",
                )
              }
              match b.ty {
                TFn(ptys, rty) => {
                  let mut i = 0
                  while i < args.length() {
                    let ep : Option[Ty] = if i < ptys.length() {
                      Some(ptys[i])
                    } else {
                      None
                    }
                    let aty = check_expr(tc, env, args[i], ep)
                    if i < ptys.length() && !ty_compat(ptys[i], aty) {
                      tc_err(
                        tc,
                        expr_span(args[i]),
                        "E_TYPE_MISMATCH",
                        "closure argument type mismatch",
                        ty_to_string(ptys[i]),
                        ty_to_string(aty),
                        "pass `" + ty_to_string(ptys[i]) + "`",
                      )
                    }
                    i = i + 1
                  }
                  return rty
                }
                _ => ()
              }
            }
            None => ()
          }
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "cannot call undefined function `" + name + "`",
            "function",
            name,
            "define `fn " + name + "` before calling it",
          )
          TError
        }
        EPath(qual, mem, _) => {
          if qual == "StringBuilder" && mem == "new" {
            return TStringBuilder
          }
          if qual == "Map" && mem == "new" {
            return match expected {
              Some(TMap(k, v)) => TMap(k, v)
              _ => TMap(TString, TError)
            }
          }
          if qual == "Array" && mem == "new" {
            return match expected {
              Some(TArray(e)) => TArray(e)
              _ => TArray(TError)
            }
          }
          if qual == "Channel" && mem == "new" {
            if args.length() >= 1 {
              let cty = check_expr(tc, env, args[0], Some(TInt))
              if !ty_compat(TInt, cty) {
                tc_err(
                  tc,
                  sp,
                  "E_TYPE_MISMATCH",
                  "`Channel::new` capacity must be `Int`",
                  "Int",
                  ty_to_string(cty),
                  "pass an `Int` capacity",
                )
              }
            }
            return match expected {
              Some(TChannel(e)) => TChannel(e)
              _ => TChannel(TError)
            }
          }
          if qual == "Mutex" && mem == "new" {
            let exp_inner : Option[Ty] = match expected {
              Some(TMutex(e)) => Some(e)
              _ => None
            }
            let vty = if args.length() >= 1 {
              check_expr(tc, env, args[0], exp_inner)
            } else {
              TError
            }
            return TMutex(vty)
          }
          if qual == "AtomicInt" && mem == "new" {
            if args.length() >= 1 {
              let _ = check_expr(tc, env, args[0], Some(TInt))
            }
            return TAtomicInt
          }
          if qual == "Option" || qual == "Result" || tc.enums.contains(qual) {
            return check_variant_ctor(tc, env, qual, mem, args, expected, sp)
          }
          let key = qual + "::" + mem
          match tc.methods.get(key) {
            Some(minfo) => return check_fn_call(tc, env, minfo, args, expected, sp)
            None => ()
          }
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "unknown static function `" + key + "`",
            "defined function",
            key,
            "check `" + key + "` spelling",
          )
          TError
        }
        _ => {
          let cty = check_expr(tc, env, callee, None)
          match cty {
            TFn(ptys, rty) => {
              let mut i = 0
              while i < args.length() {
                let ep : Option[Ty] = if i < ptys.length() {
                  Some(ptys[i])
                } else {
                  None
                }
                let _ = check_expr(tc, env, args[i], ep)
                i = i + 1
              }
              rty
            }
            _ => TError
          }
        }
      }
    EField(obj, field_name, sp) => {
      let oty = check_expr(tc, env, obj, None)
      match oty {
        TError => TError
        TStruct(sname, sargs) =>
          match tc.structs.get(sname) {
            None => TError
            Some(sinfo) => {
              let subst = make_subst(sinfo.decl.type_params, sargs)
              let mut i = 0
              while i < sinfo.field_names.length() {
                if sinfo.field_names[i] == field_name {
                  return subst_ty(sinfo.field_tys[i], subst)
                }
                i = i + 1
              }
              tc_err(
                tc,
                sp,
                "E_TYPE_MISMATCH",
                "struct `" + sname + "` has no field `" + field_name + "`",
                "valid field of `" + sname + "`",
                field_name,
                "check field name on `" + sname + "`",
              )
              TError
            }
          }
        _ => {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "cannot access field `" + field_name + "` on `" + ty_to_string(oty) + "`",
            "struct",
            ty_to_string(oty),
            "access fields only on struct values",
          )
          TError
        }
      }
    }
    EMethodCall(obj, method_name, args, sp) => {
      let oty = check_expr(tc, env, obj, None)
      check_method_call(tc, env, oty, method_name, args, expected, sp)
    }
    EIndex(obj, idx, sp) => {
      let oty = check_expr(tc, env, obj, None)
      match oty {
        TError => {
          let _ = check_expr(tc, env, idx, None)
          TError
        }
        TArray(elem) => {
          let ity = check_expr(tc, env, idx, Some(TInt))
          if !ty_compat(TInt, ity) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "array index must be `Int`",
              "Int",
              ty_to_string(ity),
              "use an `Int` index",
            )
          }
          elem
        }
        TMap(kty, vty) => {
          let ity = check_expr(tc, env, idx, Some(kty))
          if !ty_compat(kty, ity) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "map index key type mismatch",
              ty_to_string(kty),
              ty_to_string(ity),
              "use a key of type `" + ty_to_string(kty) + "`",
            )
          }
          vty
        }
        TString => {
          let _ = check_expr(tc, env, idx, Some(TInt))
          TInt
        }
        TBytes => {
          let _ = check_expr(tc, env, idx, Some(TInt))
          TByte
        }
        _ => {
          let _ = check_expr(tc, env, idx, None)
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "cannot index into type `" + ty_to_string(oty) + "`",
            "Array, Map, String, or Bytes",
            ty_to_string(oty),
            "index only into indexable collections",
          )
          TError
        }
      }
    }
    EArrayLit(elems, sp) => {
      let exp_elem : Option[Ty] = match expected {
        Some(TArray(e)) => Some(e)
        _ => None
      }
      if elems.length() == 0 {
        return match exp_elem {
          Some(e) => TArray(e)
          None => TArray(TError)
        }
      }
      let first_ty = check_expr(tc, env, elems[0], exp_elem)
      let mut i = 1
      while i < elems.length() {
        let ety = check_expr(tc, env, elems[i], Some(first_ty))
        if !ty_compat(first_ty, ety) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "array literal element type mismatch",
            ty_to_string(first_ty),
            ty_to_string(ety),
            "ensure all array elements have type `" + ty_to_string(first_ty) + "`",
          )
        }
        i = i + 1
      }
      TArray(first_ty)
    }
    EStructLit(sname, fields, sp) => {
      let resolved_name = if sname != "" {
        sname
      } else {
        match expected {
          Some(TStruct(en, _)) => en
          _ => ""
        }
      }
      if resolved_name == "" {
        let mut i = 0
        while i < fields.length() {
          let _ = check_expr(tc, env, fields[i].value, None)
          i = i + 1
        }
        return TError
      }
      match tc.structs.get(resolved_name) {
        None => {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "unknown struct `" + resolved_name + "`",
            "defined struct",
            resolved_name,
            "declare `struct " + resolved_name + "`",
          )
          TError
        }
        Some(sinfo) => {
          let subst : Map[String, Ty] = Map([])
          match expected {
            Some(TStruct(en, eargs)) =>
              if en == resolved_name {
                let mut k = 0
                while k < sinfo.decl.type_params.length() && k < eargs.length() {
                  subst.set(sinfo.decl.type_params[k], eargs[k])
                  k = k + 1
                }
              }
            _ => ()
          }
          let mut fi = 0
          while fi < fields.length() {
            let f = fields[fi]
            let mut found_idx = -1
            let mut j = 0
            while j < sinfo.field_names.length() {
              if sinfo.field_names[j] == f.name {
                found_idx = j
                break
              }
              j = j + 1
            }
            if found_idx < 0 {
              tc_err(
                tc,
                f.span,
                "E_TYPE_MISMATCH",
                "unknown field `" + f.name + "` on struct `" + resolved_name + "`",
                "valid field",
                f.name,
                "remove or rename field `" + f.name + "`",
              )
              let _ = check_expr(tc, env, f.value, None)
            } else {
              let exp_f = subst_ty(sinfo.field_tys[found_idx], subst)
              let vty = check_expr(tc, env, f.value, Some(exp_f))
              unify_tparams(sinfo.field_tys[found_idx], vty, subst)
              let exp_f2 = subst_ty(sinfo.field_tys[found_idx], subst)
              if !ty_compat(exp_f2, vty) {
                tc_err(
                  tc,
                  f.span,
                  "E_TYPE_MISMATCH",
                  "field `" + f.name + "` type mismatch in `" + resolved_name + "`",
                  ty_to_string(exp_f2),
                  ty_to_string(vty),
                  "provide a value of type `" + ty_to_string(exp_f2) + "`",
                )
              }
            }
            fi = fi + 1
          }
          let targs : Array[Ty] = []
          let mut ti = 0
          while ti < sinfo.decl.type_params.length() {
            match subst.get(sinfo.decl.type_params[ti]) {
              Some(t) => targs.push(t)
              None => targs.push(TError)
            }
            ti = ti + 1
          }
          TStruct(resolved_name, targs)
        }
      }
    }
    ETuple(elems, _) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < elems.length() {
        out.push(check_expr(tc, env, elems[i], None))
        i = i + 1
      }
      TTuple(out)
    }
    EBlock(stmts, _) => {
      env_push(env)
      let t = check_stmts(tc, env, stmts, expected)
      env_pop(env)
      t
    }
    EIf(cond, then_stmts, else_opt, sp) => {
      let cty = check_expr(tc, env, cond, Some(TBool))
      if !ty_compat(TBool, cty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`if` condition must be `Bool`",
          "Bool",
          ty_to_string(cty),
          "use a `Bool` condition",
        )
      }
      env_push(env)
      let then_ty = check_stmts(tc, env, then_stmts, expected)
      env_pop(env)
      match else_opt {
        None => TUnit
        Some(el) => {
          let else_ty = check_expr(tc, env, el, expected)
          if !ty_compat(then_ty, else_ty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`if` and `else` branch types do not match",
              ty_to_string(then_ty),
              ty_to_string(else_ty),
              "make both branches return `" + ty_to_string(then_ty) + "`",
            )
          }
          match then_ty {
            TNever => else_ty
            _ => then_ty
          }
        }
      }
    }
    EMatch(scrut, arms, sp) => {
      let scrut_ty = check_expr(tc, env, scrut, None)
      check_match_exhaustiveness(tc, scrut_ty, arms, sp)
      let mut res_ty : Option[Ty] = expected
      let mut i = 0
      while i < arms.length() {
        env_push(env)
        bind_pattern(tc, env, arms[i].pat, scrut_ty)
        let bty = check_expr(tc, env, arms[i].body, res_ty)
        env_pop(env)
        match res_ty {
          None =>
            match bty {
              TNever => ()
              _ => res_ty = Some(bty)
            }
          Some(rt) =>
            if !ty_compat(rt, bty) {
              tc_err(
                tc,
                arms[i].span,
                "E_TYPE_MISMATCH",
                "`match` arm type mismatch",
                ty_to_string(rt),
                ty_to_string(bty),
                "return `" + ty_to_string(rt) + "` from every arm",
              )
            }
        }
        i = i + 1
      }
      match res_ty {
        Some(t) => t
        None => TUnit
      }
    }
    EClosure(params, ret_te, body, _) => {
      let ptys : Array[Ty] = []
      let mut i = 0
      while i < params.length() {
        let pty = match params[i].ty {
          TyMissing(_) => TError
          _ => resolve_type_expr(tc, params[i].ty, env.type_params)
        }
        ptys.push(pty)
        i = i + 1
      }
      let ret_opt : Option[Ty] = match ret_te {
        TyMissing(_) => None
        _ => Some(resolve_type_expr(tc, ret_te, env.type_params))
      }
      env_push(env)
      let mut j = 0
      while j < params.length() {
        env_define(env, params[j].name, ptys[j], false)
        j = j + 1
      }
      let body_ty = check_stmts(tc, env, body, ret_opt)
      env_pop(env)
      let final_ret = match ret_opt {
        Some(r) => r
        None => body_ty
      }
      TFn(ptys, final_ret)
    }
    EScope(w_expr, f_expr, sp) => {
      let wty = check_expr(tc, env, w_expr, Some(TWorld))
      if !ty_compat(TWorld, wty) {
        tc_err(
          tc,
          sp,
          "E_CAPABILITY_MISSING",
          "`scope` requires a `World` capability as its first argument",
          "World",
          ty_to_string(wty),
          "pass `world : World` to `scope(world, fn(s : Scope) -> Unit { ... })`",
        )
      }
      let _ = check_expr(tc, env, f_expr, Some(TFn([TScope], TUnit)))
      TUnit
    }
    ESpawn(s_expr, f_expr, sp) => {
      let sty = check_expr(tc, env, s_expr, Some(TScope))
      if !ty_compat(TScope, sty) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`spawn` requires a `Scope` as its first argument",
          "Scope",
          ty_to_string(sty),
          "pass the `Scope` from `scope(world, fn(s : Scope) -> Unit { ... })`",
        )
      }
      // Static Send / linear-move capture check for spawned closure
      match f_expr {
        EClosure(params, _, body, _) => {
          let locals : Map[String, Bool] = Map([])
          let mut pi = 0
          while pi < params.length() {
            locals.set(params[pi].name, true)
            pi = pi + 1
          }
          let caps : Array[CaptureInfo] = []
          collect_stmts_captures(body, locals, caps)
          let checked : Map[String, Bool] = Map([])
          let mut ci = 0
          while ci < caps.length() {
            let cap = caps[ci]
            if checked.contains(cap.name) {
              ci = ci + 1
              continue
            }
            match env_lookup(env, cap.name) {
              Some(b) => {
                checked.set(cap.name, true)
                if cap.is_moved {
                  // Linear ownership transfer into spawned thread is allowed;
                  // inner check_expr will mark `cap.name` as moved in `env`.
                  ()
                } else if b.is_mut {
                  tc_err(
                    tc,
                    cap.span,
                    "E_NOT_SEND",
                    "cannot capture mutable variable `" + cap.name + "` inside `spawn`",
                    "Send",
                    "mut " + ty_to_string(b.ty),
                    "wrap `" + cap.name + "` in `Mutex::new(...)` or `AtomicInt::new(...)`",
                  )
                } else if !is_send_ty(tc, b.ty, []) {
                  tc_err(
                    tc,
                    cap.span,
                    "E_NOT_SEND",
                    "cannot capture non-Send value `" + cap.name + "` inside `spawn`",
                    "Send",
                    ty_to_string(b.ty),
                    "wrap `" + cap.name + "` in `Mutex::new(...)` or transfer ownership with `move " + cap.name + "`",
                  )
                }
              }
              None => ()
            }
            ci = ci + 1
          }
        }
        _ => ()
      }
      let _ = check_expr(tc, env, f_expr, Some(TFn([], TUnit)))
      TUnit
    }
    EAs(inner, target, _) => {
      let _ = check_expr(tc, env, inner, None)
      resolve_type_expr(tc, target, env.type_params)
    }
  }
}

///|
pub fn check_package(pkg : Package) -> CheckResult {
  let tc = TypeChecker::{
    structs: Map([]),
    enums: Map([]),
    variant_to_enum: Map([]),
    fns: Map([]),
    methods: Map([]),
    consts: Map([]),
    diagnostics: [],
  }

  // Pass 1: register type names (structs & enums)
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) =>
          tc.structs.set(
            sd.name,
            StructInfo::{
              decl: sd,
              field_names: [],
              field_muts: [],
              field_tys: [],
            },
          )
        DEnum(ed) => {
          tc.enums.set(ed.name, EnumInfo::{ decl: ed, variants: [] })
          let mut vi = 0
          while vi < ed.variants.length() {
            tc.variant_to_enum.set(ed.variants[vi].name, ed.name)
            vi = vi + 1
          }
        }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  // Pass 2: resolve struct fields, enum variants, function signatures, const types
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) => {
          let fnames : Array[String] = []
          let fmuts : Array[Bool] = []
          let ftys : Array[Ty] = []
          let mut j = 0
          while j < sd.fields.length() {
            let fld = sd.fields[j]
            fnames.push(fld.name)
            fmuts.push(fld.is_mut)
            ftys.push(resolve_type_expr(tc, fld.ty, sd.type_params))
            j = j + 1
          }
          tc.structs.set(
            sd.name,
            StructInfo::{
              decl: sd,
              field_names: fnames,
              field_muts: fmuts,
              field_tys: ftys,
            },
          )
        }
        DEnum(ed) => {
          let vinfos : Array[VariantInfo] = []
          let mut vi = 0
          while vi < ed.variants.length() {
            let v = ed.variants[vi]
            let vftys : Array[Ty] = []
            let mut j = 0
            while j < v.fields.length() {
              vftys.push(resolve_type_expr(tc, v.fields[j], ed.type_params))
              j = j + 1
            }
            vinfos.push(VariantInfo::{ name: v.name, field_tys: vftys })
            vi = vi + 1
          }
          tc.enums.set(ed.name, EnumInfo::{ decl: ed, variants: vinfos })
        }
        DFn(fd) => {
          let ptys : Array[Ty] = []
          let mut pi = 0
          while pi < fd.params.length() {
            let param = fd.params[pi]
            match param.ty {
              TyMissing(psp) => {
                tc_err(
                  tc,
                  psp,
                  "E_MISSING_TYPE",
                  "missing explicit type annotation on parameter `" + param.name + "` of `" + fd.name + "`",
                  "explicit parameter type",
                  "missing",
                  "add `: Type` to parameter `" + param.name + "`",
                )
                ptys.push(TError)
              }
              _ => ptys.push(resolve_type_expr(tc, param.ty, fd.type_params))
            }
            pi = pi + 1
          }
          let rty = match fd.ret_ty {
            TyMissing(rsp) => {
              tc_err(
                tc,
                rsp,
                "E_MISSING_TYPE",
                "missing explicit return type on function `" + fd.name + "`",
                "explicit return type `-> Type`",
                "missing",
                "add `-> ReturnType` to `" + fd.name + "`",
              )
              TError
            }
            _ => resolve_type_expr(tc, fd.ret_ty, fd.type_params)
          }
          let finfo = FnInfo::{ decl: fd, param_tys: ptys, ret_ty: rty }
          if fd.receiver_type != "" {
            tc.methods.set(fd.receiver_type + "::" + fd.name, finfo)
          } else {
            tc.fns.set(fd.name, finfo)
          }
        }
        DConst(cd) => {
          let cty = match cd.ty {
            TyMissing(csp) => {
              tc_err(
                tc,
                csp,
                "E_MISSING_TYPE",
                "missing explicit type annotation on top-level constant `" + cd.name + "`",
                "explicit type `: Type`",
                "missing",
                "add `: Type` to `let " + cd.name + "`",
              )
              TError
            }
            _ => resolve_type_expr(tc, cd.ty, [])
          }
          tc.consts.set(cd.name, cty)
        }
      }
      di = di + 1
    }
    fi = fi + 1
  }

  // Pass 2.5: check `val struct` invariants (zero `mut` fields, all fields `Send`)
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) =>
          if sd.is_val {
            match tc.structs.get(sd.name) {
              Some(sinfo) => {
                let mut j = 0
                while j < sinfo.field_tys.length() {
                  let fld = sd.fields[j]
                  if fld.is_mut {
                    tc_err(
                      tc,
                      fld.span,
                      "E_NOT_SEND",
                      "`val struct` `" + sd.name + "` cannot have `mut` field `" + fld.name + "`",
                      "immutable Send field",
                      "mut " + ty_to_string(sinfo.field_tys[j]),
                      "remove `mut` from `" + fld.name + "` or remove `val` from `" + sd.name + "`",
                    )
                  } else if !is_send_ty(tc, sinfo.field_tys[j], []) {
                    tc_err(
                      tc,
                      fld.span,
                      "E_NOT_SEND",
                      "`val struct` `" + sd.name + "` field `" + fld.name + "` has non-Send type `" + ty_to_string(sinfo.field_tys[j]) + "`",
                      "Send",
                      ty_to_string(sinfo.field_tys[j]),
                      "replace `" + fld.name + "` with a `Send` type or remove `val` from `" + sd.name + "`",
                    )
                  }
                  j = j + 1
                }
              }
              None => ()
            }
          }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  // Pass 3: type-check function bodies and constant initializers
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DFn(fd) => {
          let finfo_opt = if fd.receiver_type != "" {
            tc.methods.get(fd.receiver_type + "::" + fd.name)
          } else {
            tc.fns.get(fd.name)
          }
          match finfo_opt {
            Some(finfo) => {
              let env = env_new(finfo.ret_ty, fd.type_params)
              let mut pi = 0
              while pi < fd.params.length() && pi < finfo.param_tys.length() {
                env_define(env, fd.params[pi].name, finfo.param_tys[pi], false)
                pi = pi + 1
              }
              let body_ty = check_stmts(tc, env, fd.body, Some(finfo.ret_ty))
              if !ty_compat(finfo.ret_ty, body_ty) {
                tc_err(
                  tc,
                  fd.span,
                  "E_TYPE_MISMATCH",
                  "function `" + fd.name + "` body type does not match declared return type",
                  ty_to_string(finfo.ret_ty),
                  ty_to_string(body_ty),
                  "return a value of type `" + ty_to_string(finfo.ret_ty) + "`",
                )
              }
            }
            None => ()
          }
        }
        DConst(cd) => {
          let cty = match tc.consts.get(cd.name) {
            Some(t) => t
            None => TError
          }
          let env = env_new(cty, [])
          let vty = check_expr(tc, env, cd.value, Some(cty))
          if !ty_compat(cty, vty) {
            tc_err(
              tc,
              cd.span,
              "E_TYPE_MISMATCH",
              "constant `" + cd.name + "` initializer type mismatch",
              ty_to_string(cty),
              ty_to_string(vty),
              "initialize `" + cd.name + "` with a value of type `" + ty_to_string(cty) + "`",
            )
          }
        }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  CheckResult::{ diagnostics: tc.diagnostics }
}

///|
pub fn check_source_files(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> CheckResult {
  let all_diags : Array[Diagnostic] = []
  let files : Array[SourceFile] = []
  let mut i = 0
  while i < paths.length() && i < sources.length() {
    let pr = parse_source(paths[i], sources[i])
    let mut j = 0
    while j < pr.diagnostics.length() {
      all_diags.push(pr.diagnostics[j])
      j = j + 1
    }
    files.push(pr.file)
    i = i + 1
  }
  let pkg = Package::{ name: pkg_name, files: files }
  let cr = check_package(pkg)
  let mut k = 0
  while k < cr.diagnostics.length() {
    all_diags.push(cr.diagnostics[k])
    k = k + 1
  }
  CheckResult::{ diagnostics: all_diags }
}
