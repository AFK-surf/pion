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
  TPtr
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
    TPtr => "Ptr"
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
pub struct ExternFnInfo {
  decl : ExternFnDecl
  param_tys : Array[Ty]
  ret_ty : Ty
}

///|
pub struct TraitMethodInfo {
  name : String
  param_tys : Array[Ty]
  ret_ty : Ty
  span : Span
}

///|
pub struct TraitInfo {
  decl : TraitDecl
  methods : Array[TraitMethodInfo]
}

///|
pub struct ImplInfo {
  decl : ImplDecl
  pkg_name : String
  trait_name : String
  target_type : String
  methods : Map[String, FnInfo]
  method_names : Array[String]
}

///|
pub struct VarBinding {
  name : String
  ty : Ty
  is_mut : Bool
  /// Span of the `let` keyword that introduced the binding (line 0 for
  /// parameters, loop variables and pattern bindings).
  decl_span : Span
}

///|
pub struct Env {
  scopes : Array[Map[String, VarBinding]]
  moved : Map[String, Span]
  mut has_world : Bool
  mut ret_ty : Ty
  type_params : Array[String]
  type_bounds : Map[String, Array[String]]
  /// Decl key (`span_key`) of the generic fn whose body is being checked.
  mut fn_key : String
}

///|
/// A call `callee[tparam := concrete]` whose validity depends on whether the
/// callee compares `tparam` values with `==` / `!=`.
pub struct EqUse {
  callee_key : String
  callee_name : String
  tparam : String
  concrete : Ty
  caller_key : String
  span : Span
}

///|
pub struct ImportedPkg {
  name : String
  tc : TypeChecker
}

///|
pub fn imported_pkg_new(name : String, tc : TypeChecker) -> ImportedPkg {
  ImportedPkg::{ name: name, tc: tc }
}

///|
pub struct TypeChecker {
  pkg_name : String
  multi_pkg : Bool
  structs : Map[String, StructInfo]
  struct_names : Array[String]
  enums : Map[String, EnumInfo]
  enum_names : Array[String]
  variant_to_enum : Map[String, String]
  fns : Map[String, FnInfo]
  extern_fns : Map[String, ExternFnInfo]
  extern_fn_names : Array[String]
  methods : Map[String, FnInfo]
  method_names : Array[String]
  traits : Map[String, TraitInfo]
  trait_names : Array[String]
  impls : Map[String, ImplInfo]
  impl_keys : Array[String]
  consts : Map[String, Ty]
  const_pub : Map[String, Bool]
  import_aliases : Map[String, String]
  imported_pkgs : Map[String, ImportedPkg]
  diagnostics : Array[Diagnostic]
  /// Generic fn decl key -> type params its body compares with `==` / `!=`.
  eq_tparams : Map[String, Array[String]]
  eq_keys : Array[String]
  eq_uses : Array[EqUse]
  /// Dedup keys of machine-applicable edits already attached.
  edit_keys : Map[String, Bool]
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
    type_bounds: Map([]),
    fn_key: "",
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
  env_define_at(env, name, ty, is_mut, span_empty())
}

///|
fn env_define_at(
  env : Env,
  name : String,
  ty : Ty,
  is_mut : Bool,
  decl_span : Span,
) -> Unit {
  let top = env.scopes[env.scopes.length() - 1]
  top.set(name, VarBinding::{
    name: name,
    ty: ty,
    is_mut: is_mut,
    decl_span: decl_span,
  })
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
pub struct QualParts {
  prefix : String
  name : String
}

///|
pub fn split_qual_name(s : String) -> QualParts {
  let len = s.length()
  let mut i = 0
  while i + 1 < len {
    if str_code_at(s, i) == 58 && str_code_at(s, i + 1) == 58 {
      return QualParts::{
        prefix: slice_str(s, 0, i),
        name: slice_str(s, i + 2, len),
      }
    }
    i = i + 1
  }
  QualParts::{ prefix: "", name: s }
}

///|
fn has_qual_sep(s : String) -> Bool {
  split_qual_name(s).prefix.length() > 0
}

///|
pub fn qualify_imported_ty(pkg_name : String, t : Ty) -> Ty {
  match t {
    TArray(e) => TArray(qualify_imported_ty(pkg_name, e))
    TOption(e) => TOption(qualify_imported_ty(pkg_name, e))
    TResult(ok, err) =>
      TResult(
        qualify_imported_ty(pkg_name, ok),
        qualify_imported_ty(pkg_name, err),
      )
    TMap(k, v) =>
      TMap(qualify_imported_ty(pkg_name, k), qualify_imported_ty(pkg_name, v))
    TChannel(e) => TChannel(qualify_imported_ty(pkg_name, e))
    TMutex(e) => TMutex(qualify_imported_ty(pkg_name, e))
    TStruct(name, args) => {
      let qname = if has_qual_sep(name) {
        name
      } else {
        pkg_name + "::" + name
      }
      let out : Array[Ty] = []
      let mut i = 0
      while i < args.length() {
        out.push(qualify_imported_ty(pkg_name, args[i]))
        i = i + 1
      }
      TStruct(qname, out)
    }
    TEnum(name, args) => {
      let qname = if has_qual_sep(name) {
        name
      } else {
        pkg_name + "::" + name
      }
      let out : Array[Ty] = []
      let mut i = 0
      while i < args.length() {
        out.push(qualify_imported_ty(pkg_name, args[i]))
        i = i + 1
      }
      TEnum(qname, out)
    }
    TFn(params, ret) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < params.length() {
        out.push(qualify_imported_ty(pkg_name, params[i]))
        i = i + 1
      }
      TFn(out, qualify_imported_ty(pkg_name, ret))
    }
    TTuple(elems) => {
      let out : Array[Ty] = []
      let mut i = 0
      while i < elems.length() {
        out.push(qualify_imported_ty(pkg_name, elems[i]))
        i = i + 1
      }
      TTuple(out)
    }
    _ => t
  }
}

///|
fn qualify_fn_info(pkg_name : String, fi : FnInfo) -> FnInfo {
  let ptys : Array[Ty] = []
  let mut i = 0
  while i < fi.param_tys.length() {
    ptys.push(qualify_imported_ty(pkg_name, fi.param_tys[i]))
    i = i + 1
  }
  FnInfo::{
    decl: fi.decl,
    param_tys: ptys,
    ret_ty: qualify_imported_ty(pkg_name, fi.ret_ty),
  }
}

///|
fn import_pkg_into_tc(tc : TypeChecker, ipkg : ImportedPkg) -> Unit {
  tc.imported_pkgs.set(ipkg.name, ipkg)
  let mut ei = 0
  while ei < ipkg.tc.eq_keys.length() {
    let ek = ipkg.tc.eq_keys[ei]
    match ipkg.tc.eq_tparams.get(ek) {
      Some(tps) => eq_tparams_add_all(tc, ek, tps)
      None => ()
    }
    ei = ei + 1
  }
  let skeys = ipkg.tc.struct_names
  let mut i = 0
  while i < skeys.length() {
    let k = skeys[i]
    match ipkg.tc.structs.get(k) {
      Some(si) =>
        if has_qual_sep(k) {
          if !tc.structs.contains(k) {
            tc.structs.set(k, si)
            tc.struct_names.push(k)
          }
        } else if si.decl.is_pub {
          let qftys : Array[Ty] = []
          let mut j = 0
          while j < si.field_tys.length() {
            qftys.push(qualify_imported_ty(ipkg.name, si.field_tys[j]))
            j = j + 1
          }
          let qk = ipkg.name + "::" + k
          if !tc.structs.contains(qk) {
            tc.struct_names.push(qk)
          }
          tc.structs.set(
            qk,
            StructInfo::{
              decl: si.decl,
              field_names: si.field_names,
              field_muts: si.field_muts,
              field_tys: qftys,
            },
          )
        }
      None => ()
    }
    i = i + 1
  }
  let ekeys = ipkg.tc.enum_names
  i = 0
  while i < ekeys.length() {
    let k = ekeys[i]
    match ipkg.tc.enums.get(k) {
      Some(ei) =>
        if has_qual_sep(k) {
          if !tc.enums.contains(k) {
            tc.enums.set(k, ei)
            tc.enum_names.push(k)
          }
        } else if ei.decl.is_pub {
          let qvars : Array[VariantInfo] = []
          let mut vi = 0
          while vi < ei.variants.length() {
            let v = ei.variants[vi]
            let qvftys : Array[Ty] = []
            let mut j = 0
            while j < v.field_tys.length() {
              qvftys.push(qualify_imported_ty(ipkg.name, v.field_tys[j]))
              j = j + 1
            }
            qvars.push(VariantInfo::{ name: v.name, field_tys: qvftys })
            vi = vi + 1
          }
          let qk = ipkg.name + "::" + k
          if !tc.enums.contains(qk) {
            tc.enum_names.push(qk)
          }
          tc.enums.set(qk, EnumInfo::{ decl: ei.decl, variants: qvars })
        }
      None => ()
    }
    i = i + 1
  }
  let mkeys = ipkg.tc.method_names
  i = 0
  while i < mkeys.length() {
    let k = mkeys[i]
    match ipkg.tc.methods.get(k) {
      Some(mi) => {
        let pre = split_qual_name(k).prefix
        let is_already_pkg_qual = ipkg.tc.imported_pkgs.contains(pre)
        if is_already_pkg_qual {
          if !tc.methods.contains(k) {
            tc.methods.set(k, mi)
            tc.method_names.push(k)
          }
        } else if mi.decl.is_pub {
          let qk = ipkg.name + "::" + k
          if !tc.methods.contains(qk) {
            tc.method_names.push(qk)
          }
          tc.methods.set(qk, qualify_fn_info(ipkg.name, mi))
        }
      }
      None => ()
    }
    i = i + 1
  }
  let tkeys = ipkg.tc.trait_names
  i = 0
  while i < tkeys.length() {
    let k = tkeys[i]
    match ipkg.tc.traits.get(k) {
      Some(ti) =>
        if has_qual_sep(k) {
          if !tc.traits.contains(k) {
            tc.traits.set(k, ti)
            tc.trait_names.push(k)
          }
        } else if ti.decl.is_pub {
          let qms : Array[TraitMethodInfo] = []
          let mut mi = 0
          while mi < ti.methods.length() {
            let m = ti.methods[mi]
            let qptys : Array[Ty] = []
            let mut j = 0
            while j < m.param_tys.length() {
              qptys.push(qualify_imported_ty(ipkg.name, m.param_tys[j]))
              j = j + 1
            }
            qms.push(TraitMethodInfo::{
              name: m.name,
              param_tys: qptys,
              ret_ty: qualify_imported_ty(ipkg.name, m.ret_ty),
              span: m.span,
            })
            mi = mi + 1
          }
          let qk = ipkg.name + "::" + k
          if !tc.traits.contains(qk) {
            tc.trait_names.push(qk)
          }
          tc.traits.set(qk, TraitInfo::{ decl: ti.decl, methods: qms })
        }
      None => ()
    }
    i = i + 1
  }
  let ikeys = ipkg.tc.impl_keys
  i = 0
  while i < ikeys.length() {
    let k = ikeys[i]
    match ipkg.tc.impls.get(k) {
      Some(ii) =>
        if ii.pkg_name != ipkg.name {
          // Already normalized when `ipkg` imported it from its own dependency.
          if !tc.impls.contains(k) {
            tc.impls.set(k, ii)
            tc.impl_keys.push(k)
          }
        } else {
          let q_trait = if !has_qual_sep(ii.trait_name) &&
            ipkg.tc.traits.contains(ii.trait_name) {
            ipkg.name + "::" + ii.trait_name
          } else {
            ii.trait_name
          }
          let q_target = if !has_qual_sep(ii.target_type) &&
            (
              ipkg.tc.structs.contains(ii.target_type) ||
              ipkg.tc.enums.contains(ii.target_type)
            ) {
            ipkg.name + "::" + ii.target_type
          } else {
            ii.target_type
          }
          let qk = q_trait + "::" + q_target
          if !tc.impls.contains(qk) {
            let qms : Map[String, FnInfo] = Map([])
            let mut mi = 0
            while mi < ii.method_names.length() {
              let mn = ii.method_names[mi]
              match ii.methods.get(mn) {
                Some(mf) => qms.set(mn, qualify_fn_info(ipkg.name, mf))
                None => ()
              }
              mi = mi + 1
            }
            tc.impls.set(
              qk,
              ImplInfo::{
                decl: ii.decl,
                pkg_name: ii.pkg_name,
                trait_name: q_trait,
                target_type: q_target,
                methods: qms,
                method_names: ii.method_names,
              },
            )
            tc.impl_keys.push(qk)
          }
        }
      None => ()
    }
    i = i + 1
  }
}

///|
/// Resolves the trait names of an imported function's bounds in the package that
/// declared it, so bound checks in the importer look up `pkg::Trait::Type` impls.
fn qualify_fn_bounds(ipkg : ImportedPkg, fi : FnInfo) -> FnInfo {
  if fi.decl.type_bounds.length() == 0 {
    return fi
  }
  let qbounds : Array[TypeBound] = []
  let mut bi = 0
  while bi < fi.decl.type_bounds.length() {
    let tb = fi.decl.type_bounds[bi]
    let qtrs : Array[String] = []
    let mut ti = 0
    while ti < tb.traits.length() {
      let tn = tb.traits[ti]
      if !has_qual_sep(tn) && ipkg.tc.traits.contains(tn) {
        qtrs.push(ipkg.name + "::" + tn)
      } else {
        qtrs.push(canon_trait_name(ipkg.tc, tn))
      }
      ti = ti + 1
    }
    qbounds.push(TypeBound::{ param: tb.param, traits: qtrs })
    bi = bi + 1
  }
  let d = fi.decl
  FnInfo::{
    decl: FnDecl::{
      is_pub: d.is_pub,
      receiver_type: d.receiver_type,
      name: d.name,
      type_params: d.type_params,
      type_bounds: qbounds,
      params: d.params,
      ret_ty: d.ret_ty,
      body: d.body,
      span: d.span,
    },
    param_tys: fi.param_tys,
    ret_ty: fi.ret_ty,
  }
}

///|
pub fn resolve_alias_pkg(
  tc : TypeChecker,
  alias_name : String,
) -> Option[ImportedPkg] {
  match tc.import_aliases.get(alias_name) {
    Some(canon) => tc.imported_pkgs.get(canon)
    None => None
  }
}

///|
/// Private symbol with a known declaration: also patch `pub ` onto it.
fn emit_private_err_at(
  tc : TypeChecker,
  sp : Span,
  kind : String,
  pkg_name : String,
  sym : String,
  decl_span : Span,
) -> Unit {
  emit_private_err(tc, sp, kind, pkg_name, sym)
  if decl_span.file != "" {
    tc_add_edit(tc, text_edit_insert(decl_span, 0, "pub "))
  }
}

///|
fn emit_private_err(
  tc : TypeChecker,
  sp : Span,
  kind : String,
  pkg_name : String,
  sym : String,
) -> Unit {
  tc_err(
    tc,
    sp,
    "E_PRIVATE_SYMBOL",
    kind + " `" + sym + "` in package `" + pkg_name + "` is private",
    "pub " + kind,
    "private " + kind + " `" + pkg_name + "::" + sym + "`",
    "mark `" + kind + " " + sym + "` as `pub` in package `" + pkg_name + "`",
  )
}

///|
/// Attaches a machine-applicable edit to the diagnostic just reported (once
/// per distinct edit, so repeated errors never yield conflicting patches).
fn tc_add_edit(tc : TypeChecker, edit : TextEdit) -> Unit {
  tc_add_edit_at(tc, tc.diagnostics.length() - 1, edit)
}

///|
fn tc_add_edit_at(tc : TypeChecker, idx : Int, edit : TextEdit) -> Unit {
  if idx < 0 || idx >= tc.diagnostics.length() || edit.line <= 0 || edit.col <= 0 {
    return
  }
  let key = edit.file +
    ":" +
    edit.line.to_string() +
    ":" +
    edit.col.to_string() +
    ":" +
    edit.end_line.to_string() +
    ":" +
    edit.end_col.to_string() +
    ":" +
    edit.replacement
  if tc.edit_keys.contains(key) {
    return
  }
  tc.edit_keys.set(key, true)
  tc.diagnostics[idx].edits.push(edit)
}

///|
/// Index of the latest diagnostic `code` reported at `sp`, or -1.
fn tc_find_diag(tc : TypeChecker, code : String, sp : Span) -> Int {
  let mut i = tc.diagnostics.length() - 1
  while i >= 0 {
    let d = tc.diagnostics[i]
    if d.code == code && d.line == sp.line && d.col == sp.col && d.file == sp.file {
      return i
    }
    i = i - 1
  }
  -1
}

///|
pub fn span_key(sp : Span) -> String {
  sp.file + ":" + sp.line.to_string() + ":" + sp.col.to_string()
}

///|
/// Column just past a single-line type expression written in canonical
/// (`pionc fmt`) spacing, or -1 when it cannot be located exactly.
fn type_expr_end_col(te : TypeExpr) -> Int {
  match te {
    TyName(name, args, sp) => {
      if args.length() == 0 {
        return sp.col + name.length()
      }
      let mut i = 0
      while i < args.length() {
        if type_expr_span(args[i]).line != sp.line {
          return -1
        }
        i = i + 1
      }
      let last_end = type_expr_end_col(args[args.length() - 1])
      if last_end < 0 {
        -1
      } else {
        last_end + 1
      }
    }
    _ => -1
  }
}

///|
fn eq_tparams_has(tc : TypeChecker, key : String, tparam : String) -> Bool {
  match tc.eq_tparams.get(key) {
    Some(tps) => str_arr_contains(tps, tparam)
    None => false
  }
}

///|
fn eq_tparams_add(tc : TypeChecker, key : String, tparam : String) -> Bool {
  match tc.eq_tparams.get(key) {
    Some(tps) =>
      if str_arr_contains(tps, tparam) {
        false
      } else {
        tps.push(tparam)
        true
      }
    None => {
      tc.eq_tparams.set(key, [tparam])
      tc.eq_keys.push(key)
      true
    }
  }
}

///|
fn eq_tparams_add_all(tc : TypeChecker, key : String, tps : Array[String]) -> Unit {
  let mut i = 0
  while i < tps.length() {
    let _ = eq_tparams_add(tc, key, tps[i])
    i = i + 1
  }
}

///|
/// Closes the generic `==` / `!=` check: a type parameter compared in a
/// generic body must be instantiated with a value-comparable type.
/// Requirements propagate through generic callers before reporting.
fn resolve_eq_uses(tc : TypeChecker) -> Unit {
  let mut changed = true
  let mut rounds = 0
  while changed && rounds < 16 {
    changed = false
    let mut i = 0
    while i < tc.eq_uses.length() {
      let u = tc.eq_uses[i]
      if u.caller_key != "" && eq_tparams_has(tc, u.callee_key, u.tparam) {
        match u.concrete {
          TParam(outer) =>
            if eq_tparams_add(tc, u.caller_key, outer) {
              changed = true
            }
          _ => ()
        }
      }
      i = i + 1
    }
    rounds = rounds + 1
  }
  let mut i = 0
  while i < tc.eq_uses.length() {
    let u = tc.eq_uses[i]
    if eq_tparams_has(tc, u.callee_key, u.tparam) && !eq_comparable(tc, u.concrete) {
      let cname = ty_to_string(u.concrete)
      tc_err(
        tc,
        u.span,
        "E_TYPE_MISMATCH",
        "generic `" +
        u.callee_name +
        "` compares `" +
        u.tparam +
        "` values with `==`/`!=`, but `" +
        u.tparam +
        "` = `" +
        cname +
        "` is not value-comparable (no implicit pointer-identity comparison)",
        "value-comparable type for `" + u.tparam + "`",
        cname,
        "instantiate `" +
        u.callee_name +
        "` with a scalar, `String` or payload-less enum, or compare `" +
        cname +
        "` values with `match`",
      )
    }
    i = i + 1
  }
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
      if name == "Ptr" {
        return TPtr
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
      let qp = split_qual_name(name)
      let q_alias = qp.prefix
      let q_type = qp.name
      if q_alias.length() > 0 {
        match resolve_alias_pkg(tc, q_alias) {
          Some(ipkg) => {
            match ipkg.tc.structs.get(q_type) {
              Some(si) => {
                if !si.decl.is_pub {
                  emit_private_err_at(tc, sp, "struct", ipkg.name, q_type, si.decl.span)
                }
                return TStruct(ipkg.name + "::" + q_type, rargs)
              }
              None => ()
            }
            match ipkg.tc.enums.get(q_type) {
              Some(ei) => {
                if !ei.decl.is_pub {
                  emit_private_err_at(tc, sp, "enum", ipkg.name, q_type, ei.decl.span)
                }
                return TEnum(ipkg.name + "::" + q_type, rargs)
              }
              None => ()
            }
          }
          None => ()
        }
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
    TPtr =>
      match found {
        TPtr => true
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
/// Containers a `Mutex` may share across threads: `Array[T]` and
/// `Map[String, V]` whose elements are `Send` or themselves such containers
/// (`Mutex[Map[String, Array[String]]]`). The runtime freezes them
/// recursively on `Mutex::new` / `set`, and every object later stored into a
/// frozen container is frozen on insertion, so element RC stays atomic.
/// Bare `Array` / `Map` (no `Mutex`), `Ptr` and closures stay `!Send`.
fn is_mutex_inner_send(tc : TypeChecker, t : Ty, visiting : Array[String]) -> Bool {
  match t {
    TArray(e) => is_send_ty(tc, e, visiting) || is_mutex_inner_send(tc, e, visiting)
    TMap(k, v) =>
      match k {
        TString =>
          is_send_ty(tc, v, visiting) || is_mutex_inner_send(tc, v, visiting)
        _ => false
      }
    _ => false
  }
}

///|
fn is_send_ty(tc : TypeChecker, t : Ty, visiting : Array[String]) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TChar | TString | TUnit => true
    TAtomicInt | TScope | TNever | TError => true
    // The `World` capability is a frozen, immutable handle whose IO/TCP
    // primitives are thread-safe syscalls: spawned workers may capture it.
    TWorld => true
    TPtr | TArray(_) | TBytes | TMap(_, _) | TStringBuilder => false
    TParam(_) => false
    TOption(e) => is_send_ty(tc, e, visiting)
    TResult(ok, err) =>
      is_send_ty(tc, ok, visiting) && is_send_ty(tc, err, visiting)
    TChannel(e) => is_send_ty(tc, e, visiting)
    TMutex(e) =>
      is_send_ty(tc, e, visiting) || is_mutex_inner_send(tc, e, visiting)
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
  name == "io_print" ||
  name == "io_println" ||
  name == "io_eprintln" ||
  name == "fs_read" ||
  name == "fs_write" ||
  name == "fs_read_bytes" ||
  name == "fs_write_bytes" ||
  name == "fs_append" ||
  name == "fs_mtime_ms" ||
  name == "fs_exists" ||
  name == "fs_is_dir" ||
  name == "fs_mkdir_p" ||
  name == "fs_list_dir" ||
  name == "fs_remove" ||
  name == "fs_rename" ||
  name == "fs_size" ||
  name == "clock_now_ms" ||
  name == "proc_exec" ||
  name == "proc_exec_capture" ||
  name == "env_get" ||
  name == "args_get" ||
  name == "world_args" ||
  name == "world_argc" ||
  name == "world_argv"
}

///|
pub struct RtPrim {
  c_sym : String
  world : Bool
  param_tys : Array[Ty]
  ret_ty : Ty
}

///|
/// Runtime primitives that lower to one direct `$pion_*` C call. `world` ones take an
/// explicit leading `World` argument (not part of `param_tys`).
fn rt_prim_info(name : String) -> Option[RtPrim] {
  if name == "ptr_alloc" {
    Some(RtPrim::{ c_sym: "pion_ptr_alloc", world: false, param_tys: [TInt64], ret_ty: TPtr })
  } else if name == "ptr_free" {
    Some(RtPrim::{ c_sym: "pion_ptr_free", world: false, param_tys: [TPtr], ret_ty: TUnit })
  } else if name == "ptr_offset" {
    Some(RtPrim::{ c_sym: "pion_ptr_offset", world: false, param_tys: [TPtr, TInt64], ret_ty: TPtr })
  } else if name == "ptr_read_ptr" {
    Some(RtPrim::{ c_sym: "pion_ptr_read_ptr", world: false, param_tys: [TPtr, TInt64], ret_ty: TPtr })
  } else if name == "ptr_write_ptr" {
    Some(RtPrim::{ c_sym: "pion_ptr_write_ptr", world: false, param_tys: [TPtr, TInt64, TPtr], ret_ty: TUnit })
  } else if name == "ptr_read_i32" {
    Some(RtPrim::{ c_sym: "pion_ptr_read_i32", world: false, param_tys: [TPtr, TInt64], ret_ty: TInt })
  } else if name == "ptr_write_i32" {
    Some(RtPrim::{ c_sym: "pion_ptr_write_i32", world: false, param_tys: [TPtr, TInt64, TInt], ret_ty: TUnit })
  } else if name == "ptr_read_i64" {
    Some(RtPrim::{ c_sym: "pion_ptr_read_i64", world: false, param_tys: [TPtr, TInt64], ret_ty: TInt64 })
  } else if name == "ptr_write_i64" {
    Some(RtPrim::{ c_sym: "pion_ptr_write_i64", world: false, param_tys: [TPtr, TInt64, TInt64], ret_ty: TUnit })
  } else if name == "cstr_to_str" {
    Some(RtPrim::{ c_sym: "pion_cstr_to_str", world: false, param_tys: [TPtr], ret_ty: TString })
  } else if name == "tcp_listen" {
    Some(RtPrim::{ c_sym: "pion_tcp_listen", world: true, param_tys: [TString, TInt], ret_ty: TInt })
  } else if name == "tcp_local_port" {
    Some(RtPrim::{ c_sym: "pion_tcp_local_port", world: true, param_tys: [TInt], ret_ty: TInt })
  } else if name == "tcp_accept" {
    Some(RtPrim::{ c_sym: "pion_tcp_accept", world: true, param_tys: [TInt], ret_ty: TInt })
  } else if name == "tcp_connect" {
    Some(RtPrim::{ c_sym: "pion_tcp_connect", world: true, param_tys: [TString, TInt], ret_ty: TInt })
  } else if name == "tcp_read" {
    Some(RtPrim::{ c_sym: "pion_tcp_read", world: true, param_tys: [TInt, TInt], ret_ty: TString })
  } else if name == "tcp_write" {
    Some(RtPrim::{ c_sym: "pion_tcp_write", world: true, param_tys: [TInt, TString], ret_ty: TInt })
  } else if name == "tcp_close" {
    Some(RtPrim::{ c_sym: "pion_tcp_close", world: true, param_tys: [TInt], ret_ty: TUnit })
  } else if name == "sleep_ms" {
    Some(RtPrim::{ c_sym: "pion_sleep_ms", world: true, param_tys: [TInt], ret_ty: TUnit })
  } else if name == "tcp_listen_reuse" {
    Some(RtPrim::{ c_sym: "pion_tcp_listen_reuse", world: true, param_tys: [TString, TInt], ret_ty: TInt })
  } else if name == "tcp_set_nonblock" {
    Some(RtPrim::{ c_sym: "pion_tcp_set_nonblock", world: true, param_tys: [TInt, TBool], ret_ty: TBool })
  } else if name == "tcp_accept_nb" {
    Some(RtPrim::{ c_sym: "pion_tcp_accept_nb", world: true, param_tys: [TInt], ret_ty: TInt })
  } else if name == "tcp_read_nb" {
    Some(RtPrim::{ c_sym: "pion_tcp_read_nb", world: true, param_tys: [TInt, TStringBuilder, TInt], ret_ty: TInt })
  } else if name == "tcp_write_nb" {
    Some(RtPrim::{ c_sym: "pion_tcp_write_nb", world: true, param_tys: [TInt, TString, TInt], ret_ty: TInt })
  } else if name == "poll_create" {
    Some(RtPrim::{ c_sym: "pion_poll_create", world: true, param_tys: [], ret_ty: TInt })
  } else if name == "poll_ctl" {
    Some(RtPrim::{ c_sym: "pion_poll_ctl", world: true, param_tys: [TInt, TInt, TInt, TInt], ret_ty: TBool })
  } else if name == "poll_wait" {
    Some(
      RtPrim::{
        c_sym: "pion_poll_wait",
        world: true,
        param_tys: [TInt, TArray(TInt), TArray(TInt), TInt, TInt],
        ret_ty: TInt,
      },
    )
  } else if name == "poll_close" {
    Some(RtPrim::{ c_sym: "pion_poll_close", world: true, param_tys: [TInt], ret_ty: TUnit })
  } else {
    None
  }
}

///|
fn is_world_rt_prim(name : String) -> Bool {
  match rt_prim_info(name) {
    Some(pr) => pr.world
    None => false
  }
}

///|
fn check_rt_prim_call(
  tc : TypeChecker,
  env : Env,
  name : String,
  pr : RtPrim,
  args : Array[Expr],
  sp : Span,
) -> Ty {
  let off = if pr.world { 1 } else { 0 }
  let want = pr.param_tys.length() + off
  if pr.world {
    let mut has_world = false
    if args.length() > 0 {
      match check_expr(tc, env, args[0], Some(TWorld)) {
        TWorld => has_world = true
        _ => ()
      }
    }
    if !has_world {
      tc_err(
        tc,
        sp,
        "E_CAPABILITY_MISSING",
        "calling `" + name + "` requires an explicit `World` capability as its first argument",
        "World",
        "none",
        "pass the `World` value as the first argument of `" + name + "`",
      )
    }
  }
  if args.length() != want {
    tc_err(
      tc,
      sp,
      "E_TYPE_MISMATCH",
      "`" + name + "` expects " + want.to_string() + " argument(s), found " + args.length().to_string(),
      want.to_string() + " args",
      args.length().to_string() + " args",
      "pass " + want.to_string() + " argument(s) to `" + name + "`",
    )
  }
  let mut i = off
  while i < args.length() {
    let pi = i - off
    if pi < pr.param_tys.length() {
      let pty = pr.param_tys[pi]
      let aty = check_expr(tc, env, args[i], Some(pty))
      if !ty_compat(pty, aty) {
        tc_err(
          tc,
          expr_span(args[i]),
          "E_TYPE_MISMATCH",
          "argument " + (i + 1).to_string() + " of `" + name + "` expects `" + ty_to_string(pty) + "`",
          ty_to_string(pty),
          ty_to_string(aty),
          "pass a `" + ty_to_string(pty) + "` value",
        )
      }
    } else {
      let _ = check_expr(tc, env, args[i], None)
    }
    i = i + 1
  }
  pr.ret_ty
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
  if name == "io_print" || name == "io_println" || name == "io_eprintln" {
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
  } else if name == "fs_write" || name == "fs_append" {
    TResult(TUnit, TString)
  } else if name == "fs_read_bytes" {
    TResult(TBytes, TString)
  } else if name == "fs_write_bytes" {
    if arg_tys.length() > offset + 1 && !ty_compat(TBytes, arg_tys[offset + 1]) {
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "`fs_write_bytes` expects `Bytes` data argument",
        "Bytes",
        ty_to_string(arg_tys[offset + 1]),
        "pass a `Bytes` value",
      )
    }
    TResult(TUnit, TString)
  } else if name == "fs_mtime_ms" {
    TInt64
  } else if name == "fs_exists" || name == "fs_is_dir" || name == "fs_mkdir_p" || name == "fs_remove" || name == "fs_rename" {
    TBool
  } else if name == "fs_size" {
    TInt64
  } else if name == "fs_list_dir" || name == "args_get" || name == "world_args" {
    TArray(TString)
  } else if name == "clock_now_ms" {
    TInt64
  } else if name == "proc_exec" || name == "world_argc" {
    TInt
  } else if name == "proc_exec_capture" {
    if arg_tys.length() > offset && !ty_compat(TArray(TString), arg_tys[offset]) {
      tc_err(
        tc,
        sp,
        "E_TYPE_MISMATCH",
        "`proc_exec_capture` expects `Array[String]` argv argument",
        "Array[String]",
        ty_to_string(arg_tys[offset]),
        "pass an `Array[String]`",
      )
    }
    TResult(TString, TString)
  } else if name == "world_argv" {
    TString
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
      SLetTuple(names, _, init, _) => {
        collect_expr_captures(init, locals, out)
        let mut ni = 0
        while ni < names.length() {
          if names[ni] != "_" {
            locals.set(names[ni], true)
          }
          ni = ni + 1
        }
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
      SForRange(vname, start_e, end_e, body, _) => {
        collect_expr_captures(start_e, locals, out)
        collect_expr_captures(end_e, locals, out)
        let inner_locals = locals.copy()
        inner_locals.set(vname, true)
        collect_stmts_captures(body, inner_locals, out)
      }
      SForIn(vname, iter_e, body, _) => {
        collect_expr_captures(iter_e, locals, out)
        let inner_locals = locals.copy()
        inner_locals.set(vname, true)
        collect_stmts_captures(body, inner_locals, out)
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
        match arms[i].guard_expr {
          Some(ge) => collect_expr_captures(ge, locals, out)
          None => ()
        }
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
    EAs(inner, _, _) | ETry(inner, _) => collect_expr_captures(inner, locals, out)
    EInterp(parts, _) => {
      let mut i = 0
      while i < parts.length() {
        collect_expr_captures(parts[i], locals, out)
        i = i + 1
      }
    }
  }
}

///|
/// Inserts the missing arms (one per line, `panic`-bodied) before the first
/// existing arm, keeping its indentation.
fn add_missing_arms_edit(
  tc : TypeChecker,
  arms : Array[MatchArm],
  pats : Array[String],
) -> Unit {
  if arms.length() == 0 || pats.length() == 0 {
    return
  }
  let first = arms[0].span
  let indent = StringBuilder()
  let mut k = 1
  while k < first.col {
    indent.write_string(" ")
    k = k + 1
  }
  let ind = indent.to_string()
  let sb = StringBuilder()
  let mut i = 0
  while i < pats.length() {
    sb.write_string(pats[i])
    sb.write_string(" => panic(\"unhandled ")
    sb.write_string(pats[i])
    sb.write_string("\")\n")
    sb.write_string(ind)
    i = i + 1
  }
  tc_add_edit(tc, text_edit_insert(first, 0, sb.to_string()))
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
    let has_guard = match arms[i].guard_expr {
      Some(_) => true
      None => false
    }
    if !has_guard {
      match arms[i].pat {
        PWild(_) | PIdent(_, _) => has_wild = true
        PBool(b, _) => covered.push(if b { "true" } else { "false" })
        PVariant(_, vname, _, _) => covered.push(vname)
        _ => ()
      }
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
        add_missing_arms_edit(tc, arms, missing)
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
        add_missing_arms_edit(tc, arms, missing)
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
        add_missing_arms_edit(tc, arms, missing)
      }
    }
    TEnum(ename, _) =>
      match tc.enums.get(ename) {
        None => ()
        Some(einfo) => {
          let missing : Array[String] = []
          let missing_pats : Array[String] = []
          let mut vi = 0
          while vi < einfo.variants.length() {
            let v = einfo.variants[vi]
            if !str_arr_contains(covered, v.name) {
              missing.push(v.name)
              let nf = v.field_tys.length()
              if nf == 0 {
                missing_pats.push(v.name)
              } else {
                let psb = StringBuilder()
                psb.write_string(v.name)
                psb.write_string("(")
                let mut fj = 0
                while fj < nf {
                  if fj > 0 {
                    psb.write_string(", ")
                  }
                  psb.write_string("_")
                  fj = fj + 1
                }
                psb.write_string(")")
                missing_pats.push(psb.to_string())
              }
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
            add_missing_arms_edit(tc, arms, missing_pats)
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
pub fn parse_tuple_index(s : String) -> Int {
  let n = s.length()
  if n == 0 {
    return -1
  }
  let mut acc = 0
  let mut i = 0
  while i < n {
    let c = str_code_at(s, i)
    if c < 48 || c > 57 {
      return -1
    }
    acc = acc * 10 + (c - 48)
    i = i + 1
  }
  acc
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
  check_stmts_ex(tc, env, stmts, expected, true)
}

///|
/// `tail_used` is false for bodies whose tail value is discarded (loop and
/// test bodies): there the tail statement is also checked for an unhandled
/// `Result`.
fn check_stmts_ex(
  tc : TypeChecker,
  env : Env,
  stmts : Array[Stmt],
  expected : Option[Ty],
  tail_used : Bool,
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
    if !is_last || !tail_used {
      check_unhandled_result(tc, stmts[i], last_ty)
    }
    i = i + 1
  }
  last_ty
}

///|
fn check_unhandled_result(tc : TypeChecker, stmt : Stmt, ty : Ty) -> Unit {
  match stmt {
    SExpr(_, sp) =>
      match ty {
        TResult(_, _) => {
          tc_err(
            tc,
            sp,
            "E_UNHANDLED_RESULT",
            "value of type `" +
            ty_to_string(ty) +
            "` is silently discarded",
            "handled Result",
            ty_to_string(ty),
            "handle the Result with `match`, `?`, or explicitly discard with `let _ = ...`",
          )
          tc_add_edit(tc, text_edit_insert(sp, 0, "let _ = "))
        }
        _ => ()
      }
    _ => ()
  }
}

///|
/// Types `==`/`!=` compare by value: scalars, `String`, `Ptr`, and enums whose
/// variants carry no payload (immortal constants, so identity is the tag).
fn eq_comparable(tc : TypeChecker, t : Ty) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TChar | TString | TPtr => true
    TUnit | TParam(_) | TNever | TError => true
    TEnum(name, _) => {
      let found : Option[EnumInfo] = match tc.enums.get(name) {
        Some(ei) => Some(ei)
        None => {
          let qp = split_qual_name(name)
          match tc.imported_pkgs.get(qp.prefix) {
            Some(ipkg) => ipkg.tc.enums.get(qp.name)
            None => None
          }
        }
      }
      match found {
        None => true
        Some(einfo) => {
          let mut vi = 0
          while vi < einfo.variants.length() {
            if einfo.variants[vi].field_tys.length() != 0 {
              return false
            }
            vi = vi + 1
          }
          true
        }
      }
    }
    _ => false
  }
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
        env_define_at(env, name, final_ty, is_mut, sp)
      }
      TUnit
    }
    SLetTuple(names, ty_expr, init, sp) => {
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
              "type mismatch in tuple destructuring `let (...)`",
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
      match final_ty {
        TTuple(elem_tys) =>
          if elem_tys.length() != names.length() {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "tuple destructuring arity mismatch: expected " +
              names.length().to_string() +
              " element(s), found " +
              elem_tys.length().to_string(),
              names.length().to_string() + "-tuple",
              ty_to_string(final_ty),
              "match the number of bindings to the tuple's length",
            )
          } else {
            let mut ni = 0
            while ni < names.length() {
              if names[ni] != "_" {
                env_define(env, names[ni], elem_tys[ni], false)
              }
              ni = ni + 1
            }
          }
        TError => {
          let mut ni = 0
          while ni < names.length() {
            if names[ni] != "_" {
              env_define(env, names[ni], TError, false)
            }
            ni = ni + 1
          }
        }
        _ =>
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "cannot destructure non-tuple type `" + ty_to_string(final_ty) + "`",
            "tuple of " + names.length().to_string() + " element(s)",
            ty_to_string(final_ty),
            "destructure a tuple value or use a plain `let x = ...` binding",
          )
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
                // `let x` -> `let mut x` at the declaration.
                if b.decl_span.line > 0 {
                  tc_add_edit(tc, text_edit_insert(b.decl_span, 4, "mut "))
                }
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
      let _ = check_stmts_ex(tc, env, body, None, false)
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
      let _ = check_stmts_ex(tc, env, body, None, false)
      env_pop(env)
      TUnit
    }
    SForRange(vname, start_e, end_e, body, sp) => {
      let sty = check_expr(tc, env, start_e, Some(TInt))
      let expected_end = match sty {
        TInt64 => TInt64
        _ => TInt
      }
      let ety = check_expr(tc, env, end_e, Some(expected_end))
      let valid_start = match sty {
        TInt | TInt64 | TError => true
        _ => false
      }
      if !valid_start {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`for ... in start..end` range start must be `Int` or `Int64`",
          "Int or Int64",
          ty_to_string(sty),
          "use an `Int` or `Int64` range bound",
        )
      }
      if valid_start && !ty_compat(sty, ety) {
        tc_err(
          tc,
          sp,
          "E_TYPE_MISMATCH",
          "`for ... in start..end` range bounds must have the same type",
          ty_to_string(sty),
          ty_to_string(ety),
          "make both range bounds `" + ty_to_string(sty) + "`",
        )
      }
      let loop_var_ty = if valid_start { sty } else { TInt }
      env_push(env)
      env_define(env, vname, loop_var_ty, false)
      let _ = check_stmts_ex(tc, env, body, None, false)
      env_pop(env)
      TUnit
    }
    SForIn(vname, iter_e, body, sp) => {
      let ity = check_expr(tc, env, iter_e, None)
      let elem_ty = match ity {
        TArray(et) => et
        TError => TError
        _ => {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "`for ... in` requires an `Array[T]`",
            "Array[T]",
            ty_to_string(ity),
            "iterate over an `Array` or use `start..end` range",
          )
          TError
        }
      }
      env_push(env)
      env_define(env, vname, elem_ty, false)
      let _ = check_stmts_ex(tc, env, body, None, false)
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
pub fn ty_base_name(t : Ty) -> String {
  match t {
    TInt => "Int"
    TInt64 => "Int64"
    TDouble => "Double"
    TBool => "Bool"
    TByte => "Byte"
    TChar => "Char"
    TString => "String"
    TUnit => "Unit"
    TPtr => "Ptr"
    TStringBuilder => "StringBuilder"
    TBytes => "Bytes"
    TWorld => "World"
    TScope => "Scope"
    TAtomicInt => "AtomicInt"
    TArray(_) => "Array"
    TOption(_) => "Option"
    TResult(_, _) => "Result"
    TMap(_, _) => "Map"
    TChannel(_) => "Channel"
    TMutex(_) => "Mutex"
    TStruct(name, _) => name
    TEnum(name, _) => name
    _ => ty_to_string(t)
  }
}

///|
fn is_c_abi_param_ty(t : Ty) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TPtr | TError => true
    _ => false
  }
}

///|
fn is_c_abi_ret_ty(t : Ty) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TPtr | TUnit | TError => true
    _ => false
  }
}

///|
fn canon_trait_name(tc : TypeChecker, name : String) -> String {
  if tc.traits.contains(name) {
    return name
  }
  let qp = split_qual_name(name)
  if qp.prefix.length() > 0 {
    match resolve_alias_pkg(tc, qp.prefix) {
      Some(ipkg) => return ipkg.name + "::" + qp.name
      None => ()
    }
  }
  name
}

///|
fn lookup_trait(tc : TypeChecker, name : String) -> Option[TraitInfo] {
  let cname = canon_trait_name(tc, name)
  tc.traits.get(cname)
}

///|
fn canon_target_type_name(tc : TypeChecker, name : String) -> String {
  let qp = split_qual_name(name)
  if qp.prefix.length() > 0 {
    match resolve_alias_pkg(tc, qp.prefix) {
      Some(ipkg) => return ipkg.name + "::" + qp.name
      None => ()
    }
  }
  name
}

///|
fn format_method_sig_types(
  name : String,
  ptys : Array[Ty],
  rty : Ty,
) -> String {
  let sb = StringBuilder()
  sb.write_string("fn ")
  sb.write_string(name)
  sb.write_string("(")
  let mut i = 0
  while i < ptys.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(ty_to_string(ptys[i]))
    i = i + 1
  }
  sb.write_string(") -> ")
  sb.write_string(ty_to_string(rty))
  sb.to_string()
}

///|
fn find_impl_method(
  tc : TypeChecker,
  recv_ty : Ty,
  method_name : String,
) -> Option[FnInfo] {
  let tname = ty_base_name(recv_ty)
  let mut i = 0
  while i < tc.impl_keys.length() {
    let k = tc.impl_keys[i]
    match tc.impls.get(k) {
      Some(ii) =>
        if ii.target_type == tname {
          match ii.methods.get(method_name) {
            Some(fi) => return Some(fi)
            None => ()
          }
        }
      None => ()
    }
    i = i + 1
  }
  None
}

///|
fn check_extern_fn_call(
  tc : TypeChecker,
  env : Env,
  einfo : ExternFnInfo,
  args : Array[Expr],
  sp : Span,
) -> Ty {
  if args.length() != einfo.param_tys.length() {
    tc_err(
      tc,
      sp,
      "E_TYPE_MISMATCH",
      "extern function `" +
      einfo.decl.name +
      "` expects " +
      einfo.param_tys.length().to_string() +
      " argument(s), found " +
      args.length().to_string(),
      einfo.param_tys.length().to_string() + " args",
      args.length().to_string() + " args",
      "pass " + einfo.param_tys.length().to_string() + " argument(s)",
    )
  }
  let mut i = 0
  while i < args.length() {
    let exp_p : Option[Ty] = if i < einfo.param_tys.length() {
      Some(einfo.param_tys[i])
    } else {
      None
    }
    let aty = check_expr(tc, env, args[i], exp_p)
    if i < einfo.param_tys.length() && !ty_compat(einfo.param_tys[i], aty) {
      let fix = match einfo.param_tys[i] {
        TPtr =>
          match aty {
            TString => "pass `s.as_cstr()` to convert `String` to `Ptr`"
            _ => "pass a value of type `Ptr`"
          }
        _ => "pass a value of type `" + ty_to_string(einfo.param_tys[i]) + "`"
      }
      tc_err(
        tc,
        expr_span(args[i]),
        "E_TYPE_MISMATCH",
        "argument " +
        (i + 1).to_string() +
        " type mismatch in call to extern function `" +
        einfo.decl.name +
        "`",
        ty_to_string(einfo.param_tys[i]),
        ty_to_string(aty),
        fix,
      )
    }
    i = i + 1
  }
  einfo.ret_ty
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
  // Validate trait bounds on generic type parameters
  let mut bi = 0
  while bi < finfo.decl.type_bounds.length() {
    let tb = finfo.decl.type_bounds[bi]
    match subst.get(tb.param) {
      Some(concrete_ty) =>
        match concrete_ty {
          TError | TNever => ()
          TParam(other_tp) => {
            let mut ti = 0
            while ti < tb.traits.length() {
              let req_tr = canon_trait_name(tc, tb.traits[ti])
              let has_bound = match env.type_bounds.get(other_tp) {
                Some(btrs) => str_arr_contains(btrs, req_tr)
                None => false
              }
              if !has_bound {
                tc_err(
                  tc,
                  sp,
                  "E_TRAIT_NOT_IMPLEMENTED",
                  "type parameter `" +
                  other_tp +
                  "` does not satisfy trait bound `" +
                  req_tr +
                  "` required by `" +
                  finfo.decl.name +
                  "`",
                  other_tp + " : " + req_tr,
                  other_tp,
                  "add `: " + req_tr + "` bound to type parameter `" + other_tp + "`",
                )
              }
              ti = ti + 1
            }
          }
          _ => {
            let tname = ty_base_name(concrete_ty)
            let mut ti = 0
            while ti < tb.traits.length() {
              let req_tr = canon_trait_name(tc, tb.traits[ti])
              let impl_key = req_tr + "::" + tname
              if !tc.impls.contains(impl_key) {
                tc_err(
                  tc,
                  sp,
                  "E_TRAIT_NOT_IMPLEMENTED",
                  "type `" +
                  ty_to_string(concrete_ty) +
                  "` does not implement trait `" +
                  req_tr +
                  "` required by `" +
                  finfo.decl.name +
                  "`",
                  "impl " + req_tr + " for " + ty_to_string(concrete_ty),
                  ty_to_string(concrete_ty),
                  "add `impl " + req_tr + " for " + ty_to_string(concrete_ty) + " { ... }`",
                )
              }
              ti = ti + 1
            }
          }
        }
      None => ()
    }
    bi = bi + 1
  }
  // Record instantiations; `resolve_eq_uses` rejects non-comparable ones once
  // every generic body (and its `==` uses) has been checked.
  let mut ti = 0
  while ti < finfo.decl.type_params.length() {
    let tp = finfo.decl.type_params[ti]
    match subst.get(tp) {
      Some(concrete) =>
        tc.eq_uses.push(EqUse::{
          callee_key: span_key(finfo.decl.span),
          callee_name: finfo.decl.name,
          tparam: tp,
          concrete: concrete,
          caller_key: env.fn_key,
          span: sp,
        })
      None => ()
    }
    ti = ti + 1
  }
  subst_ty(finfo.ret_ty, subst)
}

///|
fn check_no_args(
  tc : TypeChecker,
  env : Env,
  method_name : String,
  args : Array[Expr],
  sp : Span,
) -> Unit {
  if args.length() != 0 {
    let mut i = 0
    while i < args.length() {
      let _ = check_expr(tc, env, args[i], None)
      i = i + 1
    }
    tc_err(
      tc,
      sp,
      "E_TYPE_MISMATCH",
      "`" + method_name + "` takes no arguments, found " + args.length().to_string(),
      "0 args",
      args.length().to_string() + " args",
      "call `." + method_name + "()`",
    )
  }
}

///|
fn check_unwrap_or_arg(
  tc : TypeChecker,
  env : Env,
  inner : Ty,
  args : Array[Expr],
  sp : Span,
) -> Unit {
  if args.length() != 1 {
    tc_err(
      tc,
      sp,
      "E_TYPE_MISMATCH",
      "`unwrap_or` expects 1 argument (the default), found " + args.length().to_string(),
      "1 arg",
      args.length().to_string() + " args",
      "call `.unwrap_or(<default : " + ty_to_string(inner) + ">)`",
    )
  }
  let mut i = 0
  while i < args.length() {
    let aty = check_expr(tc, env, args[i], Some(inner))
    if i == 0 && !ty_compat(inner, aty) {
      tc_err(
        tc,
        expr_span(args[i]),
        "E_TYPE_MISMATCH",
        "`unwrap_or` default type mismatch",
        ty_to_string(inner),
        ty_to_string(aty),
        "pass a default of type `" + ty_to_string(inner) + "`",
      )
    }
    i = i + 1
  }
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
      if method_name == "to_byte" {
        return TByte
      }
    }
    TInt64 => {
      if method_name == "to_string" {
        return TString
      }
      if method_name == "to_int" {
        return TInt
      }
      if method_name == "to_int64" {
        return TInt64
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
    TOption(inner) => {
      if method_name == "is_some" || method_name == "is_none" {
        check_no_args(tc, env, method_name, args, sp)
        return TBool
      }
      if method_name == "unwrap_or" {
        check_unwrap_or_arg(tc, env, inner, args, sp)
        return inner
      }
    }
    TResult(ok, _) => {
      if method_name == "is_ok" || method_name == "is_err" {
        check_no_args(tc, env, method_name, args, sp)
        return TBool
      }
      if method_name == "unwrap_or" {
        check_unwrap_or_arg(tc, env, ok, args, sp)
        return ok
      }
    }
    TString => {
      if method_name == "length" {
        return TInt
      }
      if method_name == "to_string" {
        return TString
      }
      // Parsing never panics: malformed or out-of-range text is `None`.
      if method_name == "to_int" {
        check_no_args(tc, env, method_name, args, sp)
        return TOption(TInt)
      }
      if method_name == "to_int64" {
        check_no_args(tc, env, method_name, args, sp)
        return TOption(TInt64)
      }
      if method_name == "to_double" {
        check_no_args(tc, env, method_name, args, sp)
        return TOption(TDouble)
      }
      if method_name == "code_unit_at" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        return TInt
      }
      if method_name == "slice" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        if args.length() >= 2 {
          let _ = check_expr(tc, env, args[1], Some(TInt))
        }
        return TString
      }
      if method_name == "starts_with" ||
        method_name == "ends_with" ||
        method_name == "contains" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`String::" + method_name + "` expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String`",
            )
          }
        }
        return TBool
      }
      if method_name == "index_of" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`String::index_of` expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String`",
            )
          }
        }
        return TInt
      }
      if method_name == "trim" {
        return TString
      }
      if method_name == "split" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`String::split` expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String`",
            )
          }
        }
        return TArray(TString)
      }
      if method_name == "replace" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`String::replace` argument 1 expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String`",
            )
          }
        }
        if args.length() >= 2 {
          let bty = check_expr(tc, env, args[1], Some(TString))
          if !ty_compat(TString, bty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`String::replace` argument 2 expects `String`",
              "String",
              ty_to_string(bty),
              "pass a `String`",
            )
          }
        }
        return TString
      }
      if method_name == "to_bytes" {
        return TBytes
      }
      if method_name == "as_cstr" {
        return TPtr
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
      if method_name == "length" {
        return TInt
      }
      if method_name == "reset" {
        return TUnit
      }
    }
    TBytes => {
      if method_name == "length" {
        return TInt
      }
      if method_name == "slice" {
        if args.length() >= 1 {
          let _ = check_expr(tc, env, args[0], Some(TInt))
        }
        if args.length() >= 2 {
          let _ = check_expr(tc, env, args[1], Some(TInt))
        }
        return TBytes
      }
      if method_name == "concat" {
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TBytes))
          if !ty_compat(TBytes, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Bytes::concat` expects `Bytes`",
              "Bytes",
              ty_to_string(aty),
              "pass a `Bytes` value",
            )
          }
        }
        return TBytes
      }
      if method_name == "to_string" {
        return TString
      }
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
      if method_name == "clear" || method_name == "reverse" {
        return TUnit
      }
      if method_name == "join" {
        if !ty_compat(TString, elem) {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "`Array::join` is only supported on `Array[String]`",
            "Array[String]",
            ty_to_string(TArray(elem)),
            "convert elements to `String` before calling `.join(...)`",
          )
        }
        if args.length() >= 1 {
          let aty = check_expr(tc, env, args[0], Some(TString))
          if !ty_compat(TString, aty) {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "`Array::join` separator expects `String`",
              "String",
              ty_to_string(aty),
              "pass a `String` separator",
            )
          }
        }
        return TString
      }
      if method_name == "sort" {
        let sortable = match elem {
          TInt | TInt64 | TString | TError => true
          _ => false
        }
        if !sortable {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "`Array::sort` is only supported on `Array[Int]`, `Array[Int64]`, or `Array[String]`",
            "Array[Int], Array[Int64], or Array[String]",
            ty_to_string(TArray(elem)),
            "sort an array of `Int`, `Int64`, or `String`",
          )
        }
        return TUnit
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
      if method_name == "copy" {
        return TMap(kty, vty)
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
        None => {
          let qp = split_qual_name(sname)
          let canon_pkg = qp.prefix
          let st_name = qp.name
          if canon_pkg.length() > 0 {
            match tc.imported_pkgs.get(canon_pkg) {
              Some(ipkg) =>
                match ipkg.tc.methods.get(st_name + "::" + method_name) {
                  Some(mi) =>
                    if !mi.decl.is_pub {
                      emit_private_err(
                        tc,
                        sp,
                        "fn",
                        canon_pkg,
                        st_name + "::" + method_name,
                      )
                      return qualify_imported_ty(canon_pkg, mi.ret_ty)
                    }
                  None => ()
                }
              None => ()
            }
          }
        }
      }
    }
    TParam(tp_name) => {
      match env.type_bounds.get(tp_name) {
        Some(bound_traits) => {
          let self_subst : Map[String, Ty] = Map([])
          self_subst.set("Self", TParam(tp_name))
          let mut bi = 0
          while bi < bound_traits.length() {
            match lookup_trait(tc, bound_traits[bi]) {
              Some(tinfo) => {
                let mut mi = 0
                while mi < tinfo.methods.length() {
                  let tm = tinfo.methods[mi]
                  if tm.name == method_name {
                    let mut ai = 0
                    while ai < args.length() {
                      let p_idx = ai + 1
                      let exp_p : Option[Ty] = if p_idx < tm.param_tys.length() {
                        Some(subst_ty(tm.param_tys[p_idx], self_subst))
                      } else {
                        None
                      }
                      let aty = check_expr(tc, env, args[ai], exp_p)
                      if p_idx < tm.param_tys.length() {
                        let pty = subst_ty(tm.param_tys[p_idx], self_subst)
                        if !ty_compat(pty, aty) {
                          tc_err(
                            tc,
                            expr_span(args[ai]),
                            "E_TYPE_MISMATCH",
                            "argument type mismatch in trait method `" +
                            bound_traits[bi] +
                            "::" +
                            method_name +
                            "`",
                            ty_to_string(pty),
                            ty_to_string(aty),
                            "pass a value of type `" + ty_to_string(pty) + "`",
                          )
                        }
                      }
                      ai = ai + 1
                    }
                    return subst_ty(tm.ret_ty, self_subst)
                  }
                  mi = mi + 1
                }
              }
              None => ()
            }
            bi = bi + 1
          }
        }
        None => ()
      }
    }
    _ => ()
  }
  match find_impl_method(tc, recv_ty, method_name) {
    Some(minfo) => {
      let mut i = 0
      while i < args.length() {
        let p_idx = i + 1
        let exp_p : Option[Ty] = if p_idx < minfo.param_tys.length() {
          Some(minfo.param_tys[p_idx])
        } else {
          None
        }
        let aty = check_expr(tc, env, args[i], exp_p)
        if p_idx < minfo.param_tys.length() && !ty_compat(minfo.param_tys[p_idx], aty) {
          tc_err(
            tc,
            expr_span(args[i]),
            "E_TYPE_MISMATCH",
            "argument type mismatch in trait method `" + method_name + "`",
            ty_to_string(minfo.param_tys[p_idx]),
            ty_to_string(aty),
            "pass a value of type `" + ty_to_string(minfo.param_tys[p_idx]) + "`",
          )
        }
        i = i + 1
      }
      return minfo.ret_ty
    }
    None => ()
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
      match tc.extern_fns.get(name) {
        Some(einfo) => return TFn(einfo.param_tys, einfo.ret_ty)
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
      let qp = split_qual_name(qual)
      let q_alias = qp.prefix
      let q_sub = qp.name
      if q_alias.length() > 0 {
        match resolve_alias_pkg(tc, q_alias) {
          Some(ipkg) => {
            match ipkg.tc.enums.get(q_sub) {
              Some(ei) => {
                if !ei.decl.is_pub {
                  emit_private_err(tc, sp, "enum", ipkg.name, q_sub)
                }
                return check_variant_ctor(
                  tc,
                  env,
                  ipkg.name + "::" + q_sub,
                  mem,
                  [],
                  expected,
                  sp,
                )
              }
              None => ()
            }
            match ipkg.tc.methods.get(q_sub + "::" + mem) {
              Some(mi) => {
                if !mi.decl.is_pub {
                  emit_private_err(tc, sp, "fn", ipkg.name, q_sub + "::" + mem)
                }
                let qmi = qualify_fn_info(ipkg.name, mi)
                return TFn(qmi.param_tys, qmi.ret_ty)
              }
              None => ()
            }
          }
          None => ()
        }
      }
      match resolve_alias_pkg(tc, qual) {
        Some(ipkg) => {
          match ipkg.tc.consts.get(mem) {
            Some(cty) => {
              let is_p = match ipkg.tc.const_pub.get(mem) {
                Some(b) => b
                None => false
              }
              if !is_p {
                emit_private_err(tc, sp, "let", ipkg.name, mem)
              }
              return qualify_imported_ty(ipkg.name, cty)
            }
            None => ()
          }
          match ipkg.tc.fns.get(mem) {
            Some(fi) => {
              if !fi.decl.is_pub {
                emit_private_err_at(tc, sp, "fn", ipkg.name, mem, fi.decl.span)
              }
              let qfi = qualify_fn_info(ipkg.name, fi)
              return TFn(qfi.param_tys, qfi.ret_ty)
            }
            None => ()
          }
          match ipkg.tc.variant_to_enum.get(mem) {
            Some(en) => {
              match ipkg.tc.enums.get(en) {
                Some(ei) =>
                  if !ei.decl.is_pub {
                    emit_private_err(tc, sp, "enum", ipkg.name, en)
                  }
                None => ()
              }
              return check_variant_ctor(
                tc,
                env,
                ipkg.name + "::" + en,
                mem,
                [],
                expected,
                sp,
              )
            }
            None => ()
          }
        }
        None => ()
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
        if op == "==" || op == "!=" {
          match lty {
            TParam(tp) =>
              if env.fn_key != "" && str_arr_contains(env.type_params, tp) {
                let _ = eq_tparams_add(tc, env.fn_key, tp)
              }
            _ => ()
          }
        }
        if (op == "==" || op == "!=") && !eq_comparable(tc, lty) {
          let lname = ty_to_string(lty)
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "operator `" +
            op +
            "` is not supported on `" +
            lname +
            "` (no implicit pointer-identity comparison)",
            "value-comparable type",
            lname,
            "use `match` to inspect `" + lname + "` values",
          )
        } else if !ty_compat(lty, rty) {
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
          if name == "sha256_hex" {
            if args.length() >= 1 {
              let _ = check_expr(tc, env, args[0], Some(TString))
            }
            return TString
          }
          match rt_prim_info(name) {
            Some(pr) => return check_rt_prim_call(tc, env, name, pr, args, sp)
            None => ()
          }
          if name == "ptr_null" {
            if args.length() != 0 {
              tc_err(
                tc,
                sp,
                "E_TYPE_MISMATCH",
                "`ptr_null` takes 0 arguments",
                "0 args",
                args.length().to_string() + " args",
                "call `ptr_null()` with no arguments",
              )
            }
            return TPtr
          }
          if name == "ptr_is_null" {
            if args.length() >= 1 {
              let aty = check_expr(tc, env, args[0], Some(TPtr))
              if !ty_compat(TPtr, aty) {
                tc_err(
                  tc,
                  expr_span(args[0]),
                  "E_TYPE_MISMATCH",
                  "`ptr_is_null` expects `Ptr`",
                  "Ptr",
                  ty_to_string(aty),
                  "pass a `Ptr` value",
                )
              }
            }
            return TBool
          }
          if name == "ptr_addr" {
            if args.length() >= 1 {
              let aty = check_expr(tc, env, args[0], Some(TPtr))
              if !ty_compat(TPtr, aty) {
                tc_err(
                  tc,
                  expr_span(args[0]),
                  "E_TYPE_MISMATCH",
                  "`ptr_addr` expects `Ptr`",
                  "Ptr",
                  ty_to_string(aty),
                  "pass a `Ptr` value",
                )
              }
            }
            return TInt64
          }
          if name == "math_sqrt" ||
            name == "math_abs" ||
            name == "math_floor" ||
            name == "math_ceil" ||
            name == "math_sin" ||
            name == "math_cos" {
            if args.length() >= 1 {
              let aty = check_expr(tc, env, args[0], Some(TDouble))
              if !ty_compat(TDouble, aty) {
                tc_err(
                  tc,
                  expr_span(args[0]),
                  "E_TYPE_MISMATCH",
                  "argument 1 of `" + name + "` expects `Double`",
                  "Double",
                  ty_to_string(aty),
                  "pass a `Double` to `" + name + "`",
                )
              }
            }
            return TDouble
          }
          if name == "math_pow" {
            if args.length() >= 1 {
              let aty = check_expr(tc, env, args[0], Some(TDouble))
              if !ty_compat(TDouble, aty) {
                tc_err(
                  tc,
                  expr_span(args[0]),
                  "E_TYPE_MISMATCH",
                  "argument 1 of `math_pow` expects `Double`",
                  "Double",
                  ty_to_string(aty),
                  "pass a `Double` to `math_pow`",
                )
              }
            }
            if args.length() >= 2 {
              let bty = check_expr(tc, env, args[1], Some(TDouble))
              if !ty_compat(TDouble, bty) {
                tc_err(
                  tc,
                  expr_span(args[1]),
                  "E_TYPE_MISMATCH",
                  "argument 2 of `math_pow` expects `Double`",
                  "Double",
                  ty_to_string(bty),
                  "pass a `Double` to `math_pow`",
                )
              }
            }
            return TDouble
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
          match tc.extern_fns.get(name) {
            Some(einfo) => return check_extern_fn_call(tc, env, einfo, args, sp)
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
          if qual == "Bytes" && mem == "new" {
            if args.length() >= 1 {
              let lty = check_expr(tc, env, args[0], Some(TInt))
              if !ty_compat(TInt, lty) {
                tc_err(
                  tc,
                  sp,
                  "E_TYPE_MISMATCH",
                  "`Bytes::new` length must be `Int`",
                  "Int",
                  ty_to_string(lty),
                  "pass an `Int` length",
                )
              }
            }
            return TBytes
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
          let qp = split_qual_name(qual)
          let q_alias = qp.prefix
          let q_sub = qp.name
          if q_alias.length() > 0 {
            match resolve_alias_pkg(tc, q_alias) {
              Some(ipkg) => {
                match ipkg.tc.enums.get(q_sub) {
                  Some(ei) => {
                    if !ei.decl.is_pub {
                      emit_private_err(tc, sp, "enum", ipkg.name, q_sub)
                    }
                    return check_variant_ctor(
                      tc,
                      env,
                      ipkg.name + "::" + q_sub,
                      mem,
                      args,
                      expected,
                      sp,
                    )
                  }
                  None => ()
                }
                match ipkg.tc.methods.get(q_sub + "::" + mem) {
                  Some(mi) => {
                    if !mi.decl.is_pub {
                      emit_private_err(
                        tc,
                        sp,
                        "fn",
                        ipkg.name,
                        q_sub + "::" + mem,
                      )
                    }
                    return check_fn_call(
                      tc,
                      env,
                      qualify_fn_info(ipkg.name, mi),
                      args,
                      expected,
                      sp,
                    )
                  }
                  None => ()
                }
              }
              None => ()
            }
          }
          match resolve_alias_pkg(tc, qual) {
            Some(ipkg) => {
              match ipkg.tc.fns.get(mem) {
                Some(fi) => {
                  if !fi.decl.is_pub {
                    emit_private_err_at(tc, sp, "fn", ipkg.name, mem, fi.decl.span)
                  }
                  return check_fn_call(
                    tc,
                    env,
                    qualify_fn_bounds(ipkg, qualify_fn_info(ipkg.name, fi)),
                    args,
                    expected,
                    sp,
                  )
                }
                None => ()
              }
              match ipkg.tc.extern_fns.get(mem) {
                Some(ei) => {
                  if !ei.decl.is_pub {
                    emit_private_err(tc, sp, "extern fn", ipkg.name, mem)
                  }
                  return check_extern_fn_call(tc, env, ei, args, sp)
                }
                None => ()
              }
              match ipkg.tc.variant_to_enum.get(mem) {
                Some(en) => {
                  match ipkg.tc.enums.get(en) {
                    Some(ei) =>
                      if !ei.decl.is_pub {
                        emit_private_err(tc, sp, "enum", ipkg.name, en)
                      }
                    None => ()
                  }
                  return check_variant_ctor(
                    tc,
                    env,
                    ipkg.name + "::" + en,
                    mem,
                    args,
                    expected,
                    sp,
                  )
                }
                None => ()
              }
            }
            None => ()
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
        TTuple(elems) => {
          let idx = parse_tuple_index(field_name)
          if idx >= 0 && idx < elems.length() {
            elems[idx]
          } else {
            tc_err(
              tc,
              sp,
              "E_TYPE_MISMATCH",
              "tuple `" + ty_to_string(oty) + "` has no element `." + field_name + "`",
              "index in 0.." + elems.length().to_string(),
              field_name,
              "use a valid tuple element index",
            )
            TError
          }
        }
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
      let mut resolved_name = if sname != "" {
        sname
      } else {
        match expected {
          Some(TStruct(en, _)) => en
          _ => ""
        }
      }
      if resolved_name != "" && !tc.structs.contains(resolved_name) {
        let qp = split_qual_name(resolved_name)
        let q_alias = qp.prefix
        let q_st = qp.name
        if q_alias.length() > 0 {
          match resolve_alias_pkg(tc, q_alias) {
            Some(ipkg) =>
              match ipkg.tc.structs.get(q_st) {
                Some(si) => {
                  if !si.decl.is_pub {
                    emit_private_err(tc, sp, "struct", ipkg.name, q_st)
                  }
                  resolved_name = ipkg.name + "::" + q_st
                }
                None => ()
              }
            None => ()
          }
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
        match arms[i].guard_expr {
          Some(ge) => {
            let gty = check_expr(tc, env, ge, Some(TBool))
            if !ty_compat(TBool, gty) {
              tc_err(
                tc,
                expr_span(ge),
                "E_TYPE_MISMATCH",
                "`match` guard condition must be `Bool`",
                "Bool",
                ty_to_string(gty),
                "use a boolean expression after `if` in match arm",
              )
            }
          }
          None => ()
        }
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
        TyMissing(_) =>
          match expected {
            Some(TFn(_, er)) => Some(er)
            _ => None
          }
        _ => Some(resolve_type_expr(tc, ret_te, env.type_params))
      }
      let saved_ret_ty = env.ret_ty
      env.ret_ty = match ret_opt {
        Some(r) => r
        None => TError
      }
      env_push(env)
      let mut j = 0
      while j < params.length() {
        env_define(env, params[j].name, ptys[j], false)
        j = j + 1
      }
      let body_ty = check_stmts(tc, env, body, ret_opt)
      env_pop(env)
      env.ret_ty = saved_ret_ty
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
    ETry(inner, sp) => {
      let ity = check_expr(tc, env, inner, None)
      match ity {
        TError => TError
        TResult(ok_ty, err_ty) =>
          match env.ret_ty {
            TResult(_, fn_err_ty) => {
              if !ty_compat(fn_err_ty, err_ty) {
                tc_err(
                  tc,
                  sp,
                  "E_TYPE_MISMATCH",
                  "`?` error type `" +
                  ty_to_string(err_ty) +
                  "` does not match enclosing function error type `" +
                  ty_to_string(fn_err_ty) +
                  "`",
                  ty_to_string(fn_err_ty),
                  ty_to_string(err_ty),
                  "return a matching error type `" + ty_to_string(fn_err_ty) + "`",
                )
              }
              ok_ty
            }
            _ => {
              tc_err(
                tc,
                sp,
                "E_TYPE_MISMATCH",
                "`?` on `Result` requires enclosing function to return `Result[_, " +
                ty_to_string(err_ty) +
                "]`",
                "Result[_, " + ty_to_string(err_ty) + "]",
                ty_to_string(env.ret_ty),
                "change the function return type to `Result[_, " +
                ty_to_string(err_ty) +
                "]` or handle with `match`",
              )
              ok_ty
            }
          }
        TOption(inner_ty) =>
          match env.ret_ty {
            TOption(_) => inner_ty
            _ => {
              tc_err(
                tc,
                sp,
                "E_TYPE_MISMATCH",
                "`?` on `Option` requires enclosing function to return `Option[_]`",
                "Option[_]",
                ty_to_string(env.ret_ty),
                "change the function return type to `Option[_]` or handle with `match`",
              )
              inner_ty
            }
          }
        _ => {
          tc_err(
            tc,
            sp,
            "E_TYPE_MISMATCH",
            "`?` operator requires `Result[T, E]` or `Option[T]`",
            "Result[T, E] or Option[T]",
            ty_to_string(ity),
            "apply `?` only to `Result` or `Option` expressions",
          )
          TError
        }
      }
    }
    EInterp(parts, sp) => {
      let mut i = 0
      while i < parts.length() {
        let pty = check_expr(tc, env, parts[i], None)
        let ok = match pty {
          TString | TInt | TInt64 | TDouble | TBool | TChar | TError => true
          _ => false
        }
        if !ok {
          tc_err(
            tc,
            expr_span(parts[i]),
            "E_TYPE_MISMATCH",
            "string interpolation does not support type `" +
            ty_to_string(pty) +
            "`",
            "String, Int, Int64, Double, Bool, or Char",
            ty_to_string(pty),
            "convert the value to `String` before interpolating",
          )
        }
        i = i + 1
      }
      let _ = sp
      TString
    }
  }
}

///|
///|
pub struct CheckedPackage {
  pkg : Package
  tc : TypeChecker
  diagnostics : Array[Diagnostic]
}

///|
pub fn check_package_with_imports(
  pkg : Package,
  check_file : Array[Bool],
  imported : Array[ImportedPkg],
  multi_pkg : Bool,
) -> CheckedPackage {
  let tc = TypeChecker::{
    pkg_name: pkg.name,
    multi_pkg: multi_pkg,
    structs: Map([]),
    struct_names: [],
    enums: Map([]),
    enum_names: [],
    variant_to_enum: Map([]),
    fns: Map([]),
    extern_fns: Map([]),
    extern_fn_names: [],
    methods: Map([]),
    method_names: [],
    traits: Map([]),
    trait_names: [],
    impls: Map([]),
    impl_keys: [],
    consts: Map([]),
    const_pub: Map([]),
    import_aliases: Map([]),
    imported_pkgs: Map([]),
    diagnostics: [],
    eq_tparams: Map([]),
    eq_keys: [],
    eq_uses: [],
    edit_keys: Map([]),
  }

  let mut ipi = 0
  while ipi < imported.length() {
    import_pkg_into_tc(tc, imported[ipi])
    ipi = ipi + 1
  }

  // Register file-level imports and validate package existence
  let mut fi_imp = 0
  while fi_imp < pkg.files.length() {
    let f = pkg.files[fi_imp]
    let mut ii = 0
    while ii < f.imports.length() {
      let imp = f.imports[ii]
      if tc.imported_pkgs.contains(imp.path) {
        tc.import_aliases.set(imp.alias_name, imp.path)
      } else {
        tc_err(
          tc,
          imp.span,
          "E_UNKNOWN_PACKAGE",
          "unknown imported package `" + imp.path + "`",
          "declared dependency in pion.toml",
          imp.path,
          "add `" + imp.path + " = { path = \"...\" }` to `[dependencies]` in `pion.toml`",
        )
      }
      ii = ii + 1
    }
    fi_imp = fi_imp + 1
  }

  // Pass 1: register type names (structs & enums)
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) => {
          if !tc.structs.contains(sd.name) {
            tc.struct_names.push(sd.name)
          }
          tc.structs.set(
            sd.name,
            StructInfo::{
              decl: sd,
              field_names: [],
              field_muts: [],
              field_tys: [],
            },
          )
        }
        DEnum(ed) => {
          if !tc.enums.contains(ed.name) {
            tc.enum_names.push(ed.name)
          }
          tc.enums.set(ed.name, EnumInfo::{ decl: ed, variants: [] })
          let mut vi = 0
          while vi < ed.variants.length() {
            tc.variant_to_enum.set(ed.variants[vi].name, ed.name)
            vi = vi + 1
          }
        }
        DTrait(td) => {
          if !tc.traits.contains(td.name) {
            tc.trait_names.push(td.name)
          }
          tc.traits.set(td.name, TraitInfo::{ decl: td, methods: [] })
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
          let mut bi = 0
          while bi < fd.type_bounds.length() {
            let tb = fd.type_bounds[bi]
            let mut ti = 0
            while ti < tb.traits.length() {
              let tr_name = tb.traits[ti]
              match lookup_trait(tc, tr_name) {
                Some(_) => ()
                None =>
                  tc_err(
                    tc,
                    fd.span,
                    "E_UNKNOWN_TRAIT",
                    "unknown trait `" + tr_name + "` in generic bound of `" + fd.name + "`",
                    "defined trait",
                    tr_name,
                    "declare `trait " + tr_name + " { ... }` before using it as a bound",
                  )
              }
              ti = ti + 1
            }
            bi = bi + 1
          }
          if fd.receiver_type != "" {
            let mk = fd.receiver_type + "::" + fd.name
            if !tc.methods.contains(mk) {
              tc.method_names.push(mk)
            }
            tc.methods.set(mk, finfo)
          } else {
            tc.fns.set(fd.name, finfo)
          }
        }
        DExternFn(ed) => {
          let ptys : Array[Ty] = []
          let mut pi = 0
          while pi < ed.params.length() {
            let param = ed.params[pi]
            let pty = match param.ty {
              TyMissing(psp) => {
                tc_err(
                  tc,
                  psp,
                  "E_MISSING_TYPE",
                  "missing explicit type annotation on extern parameter `" + param.name + "` of `" + ed.name + "`",
                  "explicit C-ABI parameter type",
                  "missing",
                  "add `: Type` to parameter `" + param.name + "`",
                )
                TError
              }
              _ => resolve_type_expr(tc, param.ty, [])
            }
            if !is_c_abi_param_ty(pty) {
              let fix = match pty {
                TString =>
                  "change parameter `" + param.name + "` to `Ptr` and pass `s.as_cstr()` at call sites"
                _ =>
                  "use a C-ABI safe type (`Int`, `Int64`, `Double`, `Bool`, `Byte`, or `Ptr`)"
              }
              tc_err(
                tc,
                param.span,
                "E_TYPE_MISMATCH",
                "extern \"C\" parameter `" + param.name + "` has non-C-ABI type `" + ty_to_string(pty) + "`",
                "Int, Int64, Double, Bool, Byte, or Ptr",
                ty_to_string(pty),
                fix,
              )
            }
            ptys.push(pty)
            pi = pi + 1
          }
          let rty = match ed.ret_ty {
            TyMissing(rsp) => {
              tc_err(
                tc,
                rsp,
                "E_MISSING_TYPE",
                "missing explicit return type on extern function `" + ed.name + "`",
                "explicit C-ABI return type `-> Type`",
                "missing",
                "add `-> ReturnType` to `" + ed.name + "`",
              )
              TError
            }
            _ => resolve_type_expr(tc, ed.ret_ty, [])
          }
          if !is_c_abi_ret_ty(rty) {
            let fix = match rty {
              TString => "return `Ptr` from `extern \"C\" fn` instead of managed `String`"
              _ => "use a C-ABI safe return type (`Int`, `Int64`, `Double`, `Bool`, `Byte`, `Ptr`, or `Unit`)"
            }
            tc_err(
              tc,
              ed.span,
              "E_TYPE_MISMATCH",
              "extern \"C\" function `" + ed.name + "` has non-C-ABI return type `" + ty_to_string(rty) + "`",
              "Int, Int64, Double, Bool, Byte, Ptr, or Unit",
              ty_to_string(rty),
              fix,
            )
          }
          if !tc.extern_fns.contains(ed.name) {
            tc.extern_fn_names.push(ed.name)
          }
          tc.extern_fns.set(
            ed.name,
            ExternFnInfo::{ decl: ed, param_tys: ptys, ret_ty: rty },
          )
        }
        DTrait(td) => {
          let tmethods : Array[TraitMethodInfo] = []
          let self_tp : Array[String] = ["Self"]
          let mut mi = 0
          while mi < td.methods.length() {
            let tm = td.methods[mi]
            let ptys : Array[Ty] = []
            let mut pi = 0
            while pi < tm.params.length() {
              ptys.push(resolve_type_expr(tc, tm.params[pi].ty, self_tp))
              pi = pi + 1
            }
            let rty = resolve_type_expr(tc, tm.ret_ty, self_tp)
            tmethods.push(TraitMethodInfo::{
              name: tm.name,
              param_tys: ptys,
              ret_ty: rty,
              span: tm.span,
            })
            mi = mi + 1
          }
          tc.traits.set(td.name, TraitInfo::{ decl: td, methods: tmethods })
        }
        DImpl(_) => ()
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
          tc.const_pub.set(cd.name, cd.is_pub)
        }
        DTest(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  // Pass 2.2: resolve and validate `impl Trait for Type` declarations
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DImpl(id) => {
          let c_trait = canon_trait_name(tc, id.trait_name)
          let c_target = canon_target_type_name(tc, id.target_type)
          let target_ty = resolve_type_expr(
            tc,
            TyName(id.target_type, [], id.span),
            [],
          )
          let self_subst : Map[String, Ty] = Map([])
          self_subst.set("Self", target_ty)
          let self_tp : Array[String] = ["Self"]
          let impl_methods : Map[String, FnInfo] = Map([])
          let impl_mnames : Array[String] = []
          let mut mi = 0
          while mi < id.methods.length() {
            let md = id.methods[mi]
            let ptys : Array[Ty] = []
            let mut pi = 0
            while pi < md.params.length() {
              let raw_p = resolve_type_expr(tc, md.params[pi].ty, self_tp)
              ptys.push(subst_ty(raw_p, self_subst))
              pi = pi + 1
            }
            let raw_r = resolve_type_expr(tc, md.ret_ty, self_tp)
            let rty = subst_ty(raw_r, self_subst)
            let finfo = FnInfo::{ decl: md, param_tys: ptys, ret_ty: rty }
            if !impl_methods.contains(md.name) {
              impl_mnames.push(md.name)
            }
            impl_methods.set(md.name, finfo)
            mi = mi + 1
          }
          let impl_key = c_trait + "::" + c_target
          if !tc.impls.contains(impl_key) {
            tc.impl_keys.push(impl_key)
          }
          tc.impls.set(
            impl_key,
            ImplInfo::{
              decl: id,
              pkg_name: pkg.name,
              trait_name: c_trait,
              target_type: c_target,
              methods: impl_methods,
              method_names: impl_mnames,
            },
          )
          match lookup_trait(tc, id.trait_name) {
            None =>
              tc_err(
                tc,
                id.span,
                "E_UNKNOWN_TRAIT",
                "unknown trait `" + id.trait_name + "` in `impl`",
                "defined trait",
                id.trait_name,
                "declare `trait " + id.trait_name + " { ... }` or check its spelling",
              )
            Some(tinfo) => {
              let mut tmi = 0
              while tmi < tinfo.methods.length() {
                let tm = tinfo.methods[tmi]
                let exp_ptys : Array[Ty] = []
                let mut j = 0
                while j < tm.param_tys.length() {
                  exp_ptys.push(subst_ty(tm.param_tys[j], self_subst))
                  j = j + 1
                }
                let exp_rty = subst_ty(tm.ret_ty, self_subst)
                let exp_sig = format_method_sig_types(tm.name, exp_ptys, exp_rty)
                match impl_methods.get(tm.name) {
                  None =>
                    tc_err(
                      tc,
                      id.span,
                      "E_TRAIT_METHOD_MISSING",
                      "`impl " +
                      id.trait_name +
                      " for " +
                      id.target_type +
                      "` is missing required method `" +
                      tm.name +
                      "`",
                      exp_sig,
                      "missing `" + tm.name + "`",
                      "add `" + exp_sig + " { ... }` to `impl " + id.trait_name + " for " + id.target_type + "`",
                    )
                  Some(impl_fi) => {
                    let mut sig_ok = impl_fi.param_tys.length() == exp_ptys.length() &&
                      ty_compat(exp_rty, impl_fi.ret_ty)
                    if sig_ok {
                      let mut k = 0
                      while k < exp_ptys.length() {
                        if !ty_compat(exp_ptys[k], impl_fi.param_tys[k]) {
                          sig_ok = false
                          break
                        }
                        k = k + 1
                      }
                    }
                    if !sig_ok {
                      let act_sig = format_method_sig_types(
                        tm.name,
                        impl_fi.param_tys,
                        impl_fi.ret_ty,
                      )
                      tc_err(
                        tc,
                        impl_fi.decl.span,
                        "E_TRAIT_METHOD_SIGNATURE",
                        "method `" +
                        tm.name +
                        "` in `impl " +
                        id.trait_name +
                        " for " +
                        id.target_type +
                        "` does not match trait signature",
                        exp_sig,
                        act_sig,
                        "change signature to `" + exp_sig + "`",
                      )
                      // Return type alone differs: replace it in place.
                      let mut params_ok = impl_fi.param_tys.length() ==
                        exp_ptys.length()
                      let mut k2 = 0
                      while params_ok && k2 < exp_ptys.length() {
                        if !ty_compat(exp_ptys[k2], impl_fi.param_tys[k2]) {
                          params_ok = false
                        }
                        k2 = k2 + 1
                      }
                      let exp_rs = ty_to_string(exp_rty)
                      if params_ok && !has_qual_sep(exp_rs) {
                        let rte = impl_fi.decl.ret_ty
                        let rsp = type_expr_span(rte)
                        let end_col = type_expr_end_col(rte)
                        if end_col > 0 {
                          tc_add_edit(tc, TextEdit::{
                            file: rsp.file,
                            line: rsp.line,
                            col: rsp.col,
                            end_line: rsp.line,
                            end_col: end_col,
                            replacement: exp_rs,
                          })
                        }
                      }
                    }
                  }
                }
                tmi = tmi + 1
              }
            }
          }
        }
        _ => ()
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
    if fi < check_file.length() && !check_file[fi] {
      fi = fi + 1
      continue
    }
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
              if fd.type_params.length() > 0 {
                env.fn_key = span_key(fd.span)
              }
              let mut bi = 0
              while bi < fd.type_bounds.length() {
                let tb = fd.type_bounds[bi]
                let ctrs : Array[String] = []
                let mut ti = 0
                while ti < tb.traits.length() {
                  ctrs.push(canon_trait_name(tc, tb.traits[ti]))
                  ti = ti + 1
                }
                env.type_bounds.set(tb.param, ctrs)
                bi = bi + 1
              }
              let mut pi = 0
              while pi < fd.params.length() && pi < finfo.param_tys.length() {
                env_define(env, fd.params[pi].name, finfo.param_tys[pi], false)
                pi = pi + 1
              }
              let body_ty = check_stmts(tc, env, fd.body, Some(finfo.ret_ty))
              match fd.ret_ty {
                // Missing `-> T`: patch in the type the body actually produces.
                TyMissing(rsp) =>
                  match body_ty {
                    TError | TNever => ()
                    _ => {
                      let rs = ty_to_string(body_ty)
                      if !has_qual_sep(rs) {
                        tc_add_edit_at(
                          tc,
                          tc_find_diag(tc, "E_MISSING_TYPE", rsp),
                          text_edit_insert(rsp, 0, "-> " + rs + " "),
                        )
                      }
                    }
                  }
                _ => ()
              }
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
        DImpl(id) => {
          let impl_key = canon_trait_name(tc, id.trait_name) +
            "::" +
            canon_target_type_name(tc, id.target_type)
          match tc.impls.get(impl_key) {
            Some(iinfo) => {
              let mut mi = 0
              while mi < id.methods.length() {
                let md = id.methods[mi]
                match iinfo.methods.get(md.name) {
                  Some(finfo) => {
                    let env = env_new(finfo.ret_ty, [])
                    let mut pi = 0
                    while pi < md.params.length() && pi < finfo.param_tys.length() {
                      env_define(env, md.params[pi].name, finfo.param_tys[pi], false)
                      pi = pi + 1
                    }
                    let body_ty = check_stmts(tc, env, md.body, Some(finfo.ret_ty))
                    if !ty_compat(finfo.ret_ty, body_ty) {
                      tc_err(
                        tc,
                        md.span,
                        "E_TYPE_MISMATCH",
                        "impl method `" +
                        id.trait_name +
                        "::" +
                        md.name +
                        "` body type does not match declared return type",
                        ty_to_string(finfo.ret_ty),
                        ty_to_string(body_ty),
                        "return a value of type `" + ty_to_string(finfo.ret_ty) + "`",
                      )
                    }
                  }
                  None => ()
                }
                mi = mi + 1
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
          let env = env_new(TUnit, [])
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
        DTest(td) => {
          let env = env_new(TUnit, [])
          let _ = check_stmts_ex(tc, env, td.body, None, false)
        }
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  resolve_eq_uses(tc)
  CheckedPackage::{ pkg: pkg, tc: tc, diagnostics: tc.diagnostics }
}

///|
pub fn check_package_selective(
  pkg : Package,
  check_file : Array[Bool],
) -> CheckedPackage {
  check_package_with_imports(pkg, check_file, [], false)
}

///|
pub fn check_package_full(pkg : Package) -> CheckedPackage {
  check_package_selective(pkg, [])
}

///|
pub fn check_package(pkg : Package) -> CheckResult {
  let r = check_package_full(pkg)
  CheckResult::{ diagnostics: r.diagnostics }
}

///|
pub fn check_source_files_with_imports(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
  imported : Array[ImportedPkg],
  multi_pkg : Bool,
) -> CheckedPackage {
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
  let cr = check_package_with_imports(pkg, [], imported, multi_pkg)
  let mut k = 0
  while k < cr.diagnostics.length() {
    all_diags.push(cr.diagnostics[k])
    k = k + 1
  }
  CheckedPackage::{ pkg: pkg, tc: cr.tc, diagnostics: all_diags }
}

///|
pub fn check_source_files_full(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> CheckedPackage {
  check_source_files_with_imports(pkg_name, paths, sources, [], false)
}

///|
pub fn check_source_files(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> CheckResult {
  let cr = check_source_files_full(pkg_name, paths, sources)
  CheckResult::{ diagnostics: cr.diagnostics }
}
