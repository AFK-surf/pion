///| Pure m2 ∩ MoonBit QBE IL native backend with Biased RC (Perceus-lite)

///|
pub struct QbeVal {
  reg : String
  ty : Ty
}

///|
pub struct QbeCloRes {
  env : String
  fn_sym : String
  ty : Ty
}

///|
pub struct QbeEmitResult {
  ssa : String
  has_main : Bool
}

///|
pub struct CompileQbeOut {
  sig : String
  ssa : String
  has_main : Bool
}

///|
pub struct QbeLocal {
  name : String
  slot : String
  ty : Ty
  owned : Bool
}

///|
pub struct QbeEnumConst {
  sym : String
  tag : Int
}

///|
pub struct QbeScope {
  locals : Array[QbeLocal]
}

///|
///|
pub struct QbeArgVal {
  qv : QbeVal
  borrowed : Bool
}

///|
pub struct QbeBceGuard {
  arr : String
  kind : Int
  offset : Int64
  vname : String
  key : String
}

///|
pub struct QbeSqCand {
  name : String
  assign_idx : Int
}

///|
pub struct QbePromField {
  name : String
  field_idx : Int
  ty : Ty
}

///|
pub struct QbeGen {
  tc : TypeChecker
  release : Bool
  unit_mode : Bool
  pkg_prefix : String
  struct_order : Array[String]
  enum_order : Array[String]
  const_order : Array[String]
  strings : Array[String]
  string_ids : Map[String, Int]
  cstrings : Array[String]
  cstring_ids : Map[String, Int]
  enum_consts : Array[QbeEnumConst]
  enum_const_seen : Map[String, Bool]
  slot_drop_masks : Array[Int]
  slot_drop_seen : Map[String, Bool]
  fn_wrappers : Array[String]
  fn_wrapper_seen : Map[String, Bool]
  extra_fns : Array[String]
  mut inline_fns : Map[String, FnDecl]
  mut inline_depth : Int
  inline_stack : Array[String]
  mut hoisted_arr_len : Map[String, String]
  mut hoisted_arr_dp : Map[String, String]
  mut hoisted_fields : Map[String, QbeVal]
  mut block_immut_fields : Map[String, QbeVal]
  mut len_aliases : Map[String, String]
  mut len_alias_keys : Array[String]
  mut nonneg_vars : Map[String, Bool]
  mut bce_safe_indices : Map[String, String]
  mut bce_safe_exprs : Map[String, Bool]
  mut sq_reuse_slot : Map[String, String]
  mut sq_reuse_state : Map[String, Int]
  mut promoted_fields : Map[String, String]
  mut promoted_field_tys : Map[String, Ty]
  mut w_to_l_ext : Map[String, String]
  mut local_w_to_l_ext : Map[String, String]
  mut next_tmp : Int
  mut next_lbl : Int
  mut next_clo : Int
  mut fn_allocs : StringBuilder
  mut fn_body : StringBuilder
  mut scopes : Array[QbeScope]
  mut loop_breaks : Array[String]
  mut loop_conts : Array[String]
  mut loop_depths : Array[Int]
  mut cur_tparams : Array[String]
  mut cur_ret_ty : Ty
  mut cur_ret_abi_ty : Ty
  mut block_term : Bool
  mut need_none_const : Bool
  mut need_drop_opt_obj : Bool
  mut need_drop_res_ok : Bool
  mut need_drop_res_err : Bool
  mut need_drop_res_both : Bool
}

///|
fn qval(reg : String, ty : Ty) -> QbeVal {
  QbeVal::{ reg: reg, ty: ty }
}

///|
fn qbe_is_obj_ty(t : Ty) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TChar | TUnit | TNever | TError =>
      false
    TParam(_) => false
    _ => true
  }
}

///|
fn qbe_is_double_ty(t : Ty) -> Bool {
  match t {
    TDouble => true
    _ => false
  }
}

///|
fn qbe_is_int32_ty(t : Ty) -> Bool {
  match t {
    TInt => true
    _ => false
  }
}

///|
fn qbe_is_prim_array_elem(t : Ty) -> Bool {
  match t {
    TInt | TInt64 | TDouble | TBool | TByte | TChar => true
    _ => false
  }
}

///|
fn qbe_abi_ty(t : Ty) -> String {
  if qbe_is_double_ty(t) {
    "d"
  } else if qbe_is_int32_ty(t) {
    "w"
  } else {
    "l"
  }
}

///|
fn qbe_zero_reg(t : Ty) -> String {
  if qbe_is_double_ty(t) {
    "d_0.0"
  } else {
    "0"
  }
}

///|
fn qbe_as_l(g : QbeGen, v : QbeVal) -> String {
  if qbe_is_double_ty(v.ty) {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =l cast " + v.reg)
    t
  } else if qbe_is_int32_ty(v.ty) {
    match g.w_to_l_ext.get(v.reg) {
      Some(rl) => rl
      None => {
        let t = qbe_tmp(g)
        qbe_emit(g, t + " =l extsw " + v.reg)
        g.w_to_l_ext.set(v.reg, t)
        t
      }
    }
  } else {
    v.reg
  }
}

///|
fn qbe_from_l(g : QbeGen, reg_l : String, ty : Ty) -> String {
  if qbe_is_double_ty(ty) {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =d cast " + reg_l)
    t
  } else if qbe_is_int32_ty(ty) {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =w copy " + reg_l)
    t
  } else {
    reg_l
  }
}

///|
fn qbe_coerce_val(g : QbeGen, v : QbeVal, target_ty : Ty) -> String {
  let src_abi = qbe_abi_ty(v.ty)
  let dst_abi = qbe_abi_ty(target_ty)
  if src_abi == dst_abi {
    v.reg
  } else if src_abi == "d" && dst_abi == "l" {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =l cast " + v.reg)
    t
  } else if src_abi == "l" && dst_abi == "d" {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =d cast " + v.reg)
    t
  } else if src_abi == "w" && dst_abi == "l" {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =l extsw " + v.reg)
    t
  } else if src_abi == "l" && dst_abi == "w" {
    let t = qbe_tmp(g)
    qbe_emit(g, t + " =w copy " + v.reg)
    t
  } else if src_abi == "w" && dst_abi == "d" {
    let lreg = qbe_tmp(g)
    let dreg = qbe_tmp(g)
    qbe_emit(g, lreg + " =l extsw " + v.reg)
    qbe_emit(g, dreg + " =d cast " + lreg)
    dreg
  } else {
    let lreg = qbe_tmp(g)
    let wreg = qbe_tmp(g)
    qbe_emit(g, lreg + " =l cast " + v.reg)
    qbe_emit(g, wreg + " =w copy " + lreg)
    wreg
  }
}

///|
fn qbe_store_local_slot(g : QbeGen, reg : String, slot : String, ty : Ty) -> Unit {
  if qbe_is_double_ty(ty) {
    qbe_emit(g, "stored " + reg + ", " + slot)
  } else if qbe_is_int32_ty(ty) {
    qbe_emit(g, "storew " + reg + ", " + slot)
  } else {
    qbe_emit(g, "storel " + reg + ", " + slot)
  }
}

///|
fn qbe_load_local_slot(g : QbeGen, slot : String, ty : Ty) -> String {
  let t = qbe_tmp(g)
  if qbe_is_double_ty(ty) {
    qbe_emit(g, t + " =d loadd " + slot)
  } else if qbe_is_int32_ty(ty) {
    qbe_emit(g, t + " =w loadsw " + slot)
  } else {
    qbe_emit(g, t + " =l loadl " + slot)
  }
  t
}

///|
fn qbe_store_heap_slot(g : QbeGen, reg : String, slot : String, ty : Ty) -> Unit {
  if qbe_is_double_ty(ty) {
    qbe_emit(g, "stored " + reg + ", " + slot)
  } else if qbe_is_int32_ty(ty) {
    let rl = match g.w_to_l_ext.get(reg) {
      Some(existing) => existing
      None => {
        let t = qbe_tmp(g)
        qbe_emit(g, t + " =l extsw " + reg)
        g.w_to_l_ext.set(reg, t)
        t
      }
    }
    qbe_emit(g, "storel " + rl + ", " + slot)
  } else {
    qbe_emit(g, "storel " + reg + ", " + slot)
  }
}

///|
fn qbe_load_heap_slot(g : QbeGen, slot : String, ty : Ty) -> String {
  let t = qbe_tmp(g)
  if qbe_is_double_ty(ty) {
    qbe_emit(g, t + " =d loadd " + slot)
  } else if qbe_is_int32_ty(ty) {
    qbe_emit(g, t + " =w loadsw " + slot)
  } else {
    qbe_emit(g, t + " =l loadl " + slot)
  }
  t
}

///|
fn qbe_sanitize_sym(s : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < s.length() {
    let c = str_code_at(s, i)
    if (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 95 {
      sb.write_char(c.unsafe_to_char())
    } else {
      sb.write_char('_')
    }
    i = i + 1
  }
  sb.to_string()
}

///|
fn qbe_pkg_prefix_for(pkg_name : String, multi_pkg : Bool) -> String {
  if multi_pkg {
    "pkg_" + qbe_sanitize_sym(pkg_name) + "_"
  } else {
    ""
  }
}

///|
fn qbe_local_fn_sym(g : QbeGen, name : String) -> String {
  "$m2_" + g.pkg_prefix + "fn_" + name
}

///|
fn qbe_local_method_sym(g : QbeGen, recv : String, name : String) -> String {
  "$m2_" + g.pkg_prefix + "m_" + recv + "__" + name
}

///|
fn qbe_local_const_sym(g : QbeGen, name : String) -> String {
  "$m2_" + g.pkg_prefix + "const_" + name
}

///|
fn qbe_ext_fn_sym(canon_pkg : String, name : String) -> String {
  "$m2_pkg_" + qbe_sanitize_sym(canon_pkg) + "_fn_" + name
}

///|
fn qbe_ext_method_sym(
  canon_pkg : String,
  recv : String,
  name : String,
) -> String {
  "$m2_pkg_" + qbe_sanitize_sym(canon_pkg) + "_m_" + recv + "__" + name
}

///|
fn qbe_ext_const_sym(canon_pkg : String, name : String) -> String {
  "$m2_pkg_" + qbe_sanitize_sym(canon_pkg) + "_const_" + name
}

///|
fn qbe_method_call_sym(
  g : QbeGen,
  sname : String,
  method_name : String,
) -> String {
  let qp = split_qual_name(sname)
  let canon_pkg = qp.prefix
  let st_name = qp.name
  if canon_pkg.length() > 0 {
    qbe_ext_method_sym(canon_pkg, st_name, method_name)
  } else {
    qbe_local_method_sym(g, sname, method_name)
  }
}

///|
fn qbe_register_enum_const(
  g : QbeGen,
  enum_name : String,
  vname : String,
  tag : Int,
) -> String {
  let sym = "$m2_enum_" + qbe_sanitize_sym(enum_name) + "__" + vname + "_hdr"
  if !g.enum_const_seen.contains(sym) {
    g.enum_const_seen.set(sym, true)
    g.enum_consts.push(QbeEnumConst::{ sym: sym, tag: tag })
  }
  sym
}

///|
fn qbe_expr_has_assign(e : Expr) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_expr_has_assign(inner)
    EBinary(_, l, r, _) => qbe_expr_has_assign(l) || qbe_expr_has_assign(r)
    EField(o, _, _) => qbe_expr_has_assign(o)
    EIndex(o, i, _) => qbe_expr_has_assign(o) || qbe_expr_has_assign(i)
    ECall(callee, args, _) => {
      if qbe_expr_has_assign(callee) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_assign(args[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_has_assign(obj) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_assign(args[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_has_assign(elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_has_assign(fields[i].value) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(_, _) | EIf(_, _, _, _) | EMatch(_, _, _) | EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) =>
      true
  }
}

///|
fn qbe_args_have_assign(args : Array[Expr]) -> Bool {
  let mut i = 0
  while i < args.length() {
    if qbe_expr_has_assign(args[i]) {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn qbe_emit_arg_maybe_borrow(
  g : QbeGen,
  arg : Expr,
  expected : Option[Ty],
  can_borrow : Bool,
) -> QbeArgVal {
  if can_borrow {
    match arg {
      EIdent(lname, _) =>
        match qbe_lookup_local(g, lname) {
          Some(loc) => {
            let t = qbe_load_local_slot(g, loc.slot, loc.ty)
            return QbeArgVal::{ qv: qval(t, loc.ty), borrowed: true }
          }
          None => ()
        }
      _ => ()
    }
  }
  QbeArgVal::{ qv: qbe_emit_expr(g, arg, expected), borrowed: false }
}

///|
fn qbe_pat_binds_name(pat : Pattern, name : String) -> Bool {
  match pat {
    PWild(_) | PBool(_, _) | PInt(_, _) | PString(_, _) | PChar(_, _) => false
    PIdent(n, _) => n == name
    PTuple(subs, _) | PVariant(_, _, subs, _) => {
      let mut i = 0
      while i < subs.length() {
        if qbe_pat_binds_name(subs[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
  }
}

///|
fn qbe_expr_assigns_ident(e : Expr, name : String) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_assigns_ident(inner, name)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_assigns_ident(l, name) || qbe_expr_assigns_ident(r, name)
    ECall(callee, args, _) => {
      if qbe_expr_assigns_ident(callee, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_assigns_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_assigns_ident(obj, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_assigns_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_assigns_ident(elems[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_assigns_ident(fields[i].value, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(stmts, _) => qbe_stmts_assigns_ident(stmts, name)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_assigns_ident(cond, name) || qbe_stmts_assigns_ident(then_stmts, name) {
        return true
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_assigns_ident(el, name)
      }
    }
    EMatch(scrut, arms, _) => {
      if qbe_expr_assigns_ident(scrut, name) {
        return true
      }
      let mut i = 0
      while i < arms.length() {
        if qbe_expr_assigns_ident(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EClosure(_, _, body, _) => qbe_stmts_assigns_ident(body, name)
  }
}

///|
fn qbe_stmt_assigns_ident(s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_assigns_ident(init, name)
    SAssign(lhs, rhs, _) => {
      match lhs {
        EIdent(n, _) =>
          if n == name {
            return true
          }
        _ => ()
      }
      qbe_expr_assigns_ident(lhs, name) || qbe_expr_assigns_ident(rhs, name)
    }
    SWhile(cond, body, _) =>
      qbe_expr_assigns_ident(cond, name) || qbe_stmts_assigns_ident(body, name)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_stmt_assigns_ident(init_s, name) ||
      qbe_expr_assigns_ident(cond, name) ||
      qbe_stmt_assigns_ident(step_s, name) ||
      qbe_stmts_assigns_ident(body, name)
    SReturn(opt, _) =>
      match opt {
        None => false
        Some(e) => qbe_expr_assigns_ident(e, name)
      }
    SBreak(_) | SContinue(_) => false
    SDebugAssert(c, m, _) =>
      qbe_expr_assigns_ident(c, name) || qbe_expr_assigns_ident(m, name)
    SExpr(e, _) => qbe_expr_assigns_ident(e, name)
  }
}

///|
fn qbe_stmts_assigns_ident(stmts : Array[Stmt], name : String) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if qbe_stmt_assigns_ident(stmts[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn qbe_expr_mentions_ident(e : Expr, name : String) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EIdent(n, _) => n == name
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_mentions_ident(inner, name)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_mentions_ident(l, name) || qbe_expr_mentions_ident(r, name)
    ECall(callee, args, _) => {
      if qbe_expr_mentions_ident(callee, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_mentions_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_mentions_ident(obj, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_mentions_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_mentions_ident(elems[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_mentions_ident(fields[i].value, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(stmts, _) => qbe_stmts_mentions_ident(stmts, name)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_mentions_ident(cond, name) || qbe_stmts_mentions_ident(then_stmts, name) {
        return true
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_mentions_ident(el, name)
      }
    }
    EMatch(scrut, arms, _) => {
      if qbe_expr_mentions_ident(scrut, name) {
        return true
      }
      let mut i = 0
      while i < arms.length() {
        if qbe_expr_mentions_ident(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EClosure(_, _, body, _) => qbe_stmts_mentions_ident(body, name)
  }
}

///|
fn qbe_stmt_mentions_ident(s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_mentions_ident(init, name)
    SAssign(lhs, rhs, _) =>
      qbe_expr_mentions_ident(lhs, name) || qbe_expr_mentions_ident(rhs, name)
    SWhile(cond, body, _) =>
      qbe_expr_mentions_ident(cond, name) || qbe_stmts_mentions_ident(body, name)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_stmt_mentions_ident(init_s, name) ||
      qbe_expr_mentions_ident(cond, name) ||
      qbe_stmt_mentions_ident(step_s, name) ||
      qbe_stmts_mentions_ident(body, name)
    SReturn(opt, _) =>
      match opt {
        None => false
        Some(e) => qbe_expr_mentions_ident(e, name)
      }
    SBreak(_) | SContinue(_) => false
    SDebugAssert(c, m, _) =>
      qbe_expr_mentions_ident(c, name) || qbe_expr_mentions_ident(m, name)
    SExpr(e, _) => qbe_expr_mentions_ident(e, name)
  }
}

///|
fn qbe_stmts_mentions_ident(stmts : Array[Stmt], name : String) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if qbe_stmt_mentions_ident(stmts[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Conservative static check: returns true only when `name` never escapes
/// (never returned, never reassigned, never stored in any container/struct/enum/tuple/closure)
/// and only appears in borrow-safe positions (direct call args, field/index receiver, match scrutinee).
fn qbe_ident_is_borrow_safe_expr(g : QbeGen, e : Expr, name : String) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EPath(_, _, _)
    | EUnit(_) => true
    EIdent(n, _) => n != name
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_ident_is_borrow_safe_expr(g, inner, name)
    EBinary(_, l, r, _) =>
      qbe_ident_is_borrow_safe_expr(g, l, name) &&
      qbe_ident_is_borrow_safe_expr(g, r, name)
    EField(obj, _, _) =>
      match obj {
        EIdent(n, _) =>
          if n == name {
            true
          } else {
            true
          }
        _ => qbe_ident_is_borrow_safe_expr(g, obj, name)
      }
    EIndex(obj, idx, _) => {
      if !qbe_ident_is_borrow_safe_expr(g, idx, name) {
        return false
      }
      match obj {
        EIdent(n, _) =>
          if n == name {
            !qbe_expr_has_assign(idx)
          } else {
            true
          }
        _ => qbe_ident_is_borrow_safe_expr(g, obj, name)
      }
    }
    ECall(callee, args, _) => {
      let is_direct_borrow_callee = match callee {
        EIdent(fname, _) =>
          g.tc.fns.contains(fname) ||
          fname == "sha256_hex" ||
          is_world_builtin(fname)
        EPath(qual, mem, _) => g.tc.methods.contains(qual + "::" + mem)
        _ => false
      }
      if is_direct_borrow_callee && !qbe_args_have_assign(args) {
        let mut i = 0
        while i < args.length() {
          match args[i] {
            EIdent(n, _) =>
              if n != name {
                ()
              }
            _ =>
              if !qbe_ident_is_borrow_safe_expr(g, args[i], name) {
                return false
              }
          }
          i = i + 1
        }
        true
      } else {
        if !qbe_ident_is_borrow_safe_expr(g, callee, name) {
          return false
        }
        let mut i = 0
        while i < args.length() {
          if !qbe_ident_is_borrow_safe_expr(g, args[i], name) {
            return false
          }
          i = i + 1
        }
        true
      }
    }
    EMethodCall(obj, mname, args, _) => {
      if mname != "to_string" &&
        !qbe_expr_has_assign(obj) &&
        !qbe_args_have_assign(args) {
        let obj_ok = match obj {
          EIdent(n, _) => if n == name { true } else { true }
          _ => qbe_ident_is_borrow_safe_expr(g, obj, name)
        }
        if !obj_ok {
          return false
        }
        let mut i = 0
        while i < args.length() {
          match args[i] {
            EIdent(n, _) => if n != name { () }
            _ =>
              if !qbe_ident_is_borrow_safe_expr(g, args[i], name) {
                return false
              }
          }
          i = i + 1
        }
        true
      } else {
        if !qbe_ident_is_borrow_safe_expr(g, obj, name) {
          return false
        }
        let mut i = 0
        while i < args.length() {
          if !qbe_ident_is_borrow_safe_expr(g, args[i], name) {
            return false
          }
          i = i + 1
        }
        true
      }
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if !qbe_ident_is_borrow_safe_expr(g, elems[i], name) {
          return false
        }
        i = i + 1
      }
      true
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if !qbe_ident_is_borrow_safe_expr(g, fields[i].value, name) {
          return false
        }
        i = i + 1
      }
      true
    }
    EBlock(stmts, _) => qbe_ident_is_borrow_safe_stmts(g, stmts, 0, name)
    EIf(cond, then_stmts, else_opt, _) => {
      if !qbe_ident_is_borrow_safe_expr(g, cond, name) ||
        !qbe_ident_is_borrow_safe_stmts(g, then_stmts, 0, name) {
        return false
      }
      match else_opt {
        None => true
        Some(el) => qbe_ident_is_borrow_safe_expr(g, el, name)
      }
    }
    EMatch(scrut, arms, _) => {
      let scrut_ok = match scrut {
        EIdent(n, _) =>
          if n == name {
            let mut ai = 0
            let mut ok = true
            while ai < arms.length() {
              if qbe_expr_assigns_ident(arms[ai].body, name) {
                ok = false
                break
              }
              ai = ai + 1
            }
            ok
          } else {
            true
          }
        _ => qbe_ident_is_borrow_safe_expr(g, scrut, name)
      }
      if !scrut_ok {
        return false
      }
      let mut i = 0
      while i < arms.length() {
        if !qbe_pat_binds_name(arms[i].pat, name) {
          if !qbe_ident_is_borrow_safe_expr(g, arms[i].body, name) {
            return false
          }
        }
        i = i + 1
      }
      true
    }
    EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) =>
      !qbe_expr_mentions_ident(e, name)
  }
}

///|
fn qbe_ident_is_borrow_safe_stmt(g : QbeGen, s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_ident_is_borrow_safe_expr(g, init, name)
    SAssign(lhs, rhs, _) => {
      if !qbe_ident_is_borrow_safe_expr(g, rhs, name) {
        return false
      }
      match lhs {
        EIdent(n, _) => n != name
        EField(obj, _, _) =>
          match obj {
            EIdent(n, _) =>
              if n == name {
                !qbe_expr_has_assign(rhs)
              } else {
                true
              }
            _ => qbe_ident_is_borrow_safe_expr(g, obj, name)
          }
        EIndex(obj, idx, _) => {
          if !qbe_ident_is_borrow_safe_expr(g, idx, name) {
            return false
          }
          match obj {
            EIdent(n, _) =>
              if n == name {
                !qbe_expr_has_assign(idx) && !qbe_expr_has_assign(rhs)
              } else {
                true
              }
            _ => qbe_ident_is_borrow_safe_expr(g, obj, name)
          }
        }
        _ => qbe_ident_is_borrow_safe_expr(g, lhs, name)
      }
    }
    SWhile(cond, body, _) =>
      qbe_ident_is_borrow_safe_expr(g, cond, name) &&
      qbe_ident_is_borrow_safe_stmts(g, body, 0, name)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_ident_is_borrow_safe_stmt(g, init_s, name) &&
      qbe_ident_is_borrow_safe_expr(g, cond, name) &&
      qbe_ident_is_borrow_safe_stmt(g, step_s, name) &&
      qbe_ident_is_borrow_safe_stmts(g, body, 0, name)
    SReturn(opt, _) =>
      match opt {
        None => true
        Some(e) => qbe_ident_is_borrow_safe_expr(g, e, name)
      }
    SBreak(_) | SContinue(_) => true
    SDebugAssert(c, m, _) =>
      qbe_ident_is_borrow_safe_expr(g, c, name) &&
      qbe_ident_is_borrow_safe_expr(g, m, name)
    SExpr(e, _) => qbe_ident_is_borrow_safe_expr(g, e, name)
  }
}

///|
fn qbe_ident_is_borrow_safe_stmts(
  g : QbeGen,
  stmts : Array[Stmt],
  start_idx : Int,
  name : String,
) -> Bool {
  let mut i = start_idx
  while i < stmts.length() {
    match stmts[i] {
      SLet(lname, _, _, init, _) => {
        if !qbe_ident_is_borrow_safe_expr(g, init, name) {
          return false
        }
        if lname == name {
          return true
        }
      }
      _ =>
        if !qbe_ident_is_borrow_safe_stmt(g, stmts[i], name) {
          return false
        }
    }
    i = i + 1
  }
  true
}

///|
/// Check that local array `aname` is never mutated in container structure
/// (no reassignment, no `.push`/`.pop`, never passed to any function/closure;
/// if `allow_elem_assign` is false, also disallows `aname[...] = ...`).
fn qbe_arr_is_stable_expr(
  e : Expr,
  aname : String,
  allow_elem_assign : Bool,
) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EPath(_, _, _)
    | EUnit(_) => true
    EIdent(n, _) => n != aname
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_arr_is_stable_expr(inner, aname, allow_elem_assign)
    EBinary(_, l, r, _) =>
      qbe_arr_is_stable_expr(l, aname, allow_elem_assign) &&
      qbe_arr_is_stable_expr(r, aname, allow_elem_assign)
    EIndex(obj, idx, _) => {
      if !qbe_arr_is_stable_expr(idx, aname, allow_elem_assign) {
        return false
      }
      match obj {
        EIdent(n, _) => if n == aname { true } else { true }
        _ => qbe_arr_is_stable_expr(obj, aname, allow_elem_assign)
      }
    }
    EMethodCall(obj, mname, args, _) => {
      let mut i = 0
      while i < args.length() {
        if !qbe_arr_is_stable_expr(args[i], aname, allow_elem_assign) {
          return false
        }
        i = i + 1
      }
      match obj {
        EIdent(n, _) =>
          if n == aname {
            mname == "length" && args.length() == 0
          } else {
            true
          }
        _ => qbe_arr_is_stable_expr(obj, aname, allow_elem_assign)
      }
    }
    ECall(callee, args, _) => {
      if !qbe_arr_is_stable_expr(callee, aname, allow_elem_assign) {
        return false
      }
      let mut i = 0
      while i < args.length() {
        if !qbe_arr_is_stable_expr(args[i], aname, allow_elem_assign) {
          return false
        }
        i = i + 1
      }
      true
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if !qbe_arr_is_stable_expr(elems[i], aname, allow_elem_assign) {
          return false
        }
        i = i + 1
      }
      true
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if !qbe_arr_is_stable_expr(fields[i].value, aname, allow_elem_assign) {
          return false
        }
        i = i + 1
      }
      true
    }
    EBlock(stmts, _) => qbe_arr_is_stable_stmts(stmts, 0, aname, allow_elem_assign)
    EIf(cond, then_stmts, else_opt, _) => {
      if !qbe_arr_is_stable_expr(cond, aname, allow_elem_assign) ||
        !qbe_arr_is_stable_stmts(then_stmts, 0, aname, allow_elem_assign) {
        return false
      }
      match else_opt {
        None => true
        Some(el) => qbe_arr_is_stable_expr(el, aname, allow_elem_assign)
      }
    }
    EMatch(scrut, arms, _) => {
      if !qbe_arr_is_stable_expr(scrut, aname, allow_elem_assign) {
        return false
      }
      let mut i = 0
      while i < arms.length() {
        if !qbe_pat_binds_name(arms[i].pat, aname) {
          if !qbe_arr_is_stable_expr(arms[i].body, aname, allow_elem_assign) {
            return false
          }
        }
        i = i + 1
      }
      true
    }
    EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) =>
      !qbe_expr_mentions_ident(e, aname)
  }
}

///|
fn qbe_arr_is_stable_stmt(
  s : Stmt,
  aname : String,
  allow_elem_assign : Bool,
) -> Bool {
  match s {
    SLet(_, _, _, init, _) =>
      qbe_arr_is_stable_expr(init, aname, allow_elem_assign)
    SAssign(lhs, rhs, _) => {
      if !qbe_arr_is_stable_expr(rhs, aname, allow_elem_assign) {
        return false
      }
      match lhs {
        EIdent(n, _) => n != aname
        EIndex(EIdent(n, _), idx, _) =>
          if n == aname {
            allow_elem_assign &&
            qbe_arr_is_stable_expr(idx, aname, allow_elem_assign)
          } else {
            qbe_arr_is_stable_expr(idx, aname, allow_elem_assign)
          }
        _ => qbe_arr_is_stable_expr(lhs, aname, allow_elem_assign)
      }
    }
    SWhile(cond, body, _) =>
      qbe_arr_is_stable_expr(cond, aname, allow_elem_assign) &&
      qbe_arr_is_stable_stmts(body, 0, aname, allow_elem_assign)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_arr_is_stable_stmt(init_s, aname, allow_elem_assign) &&
      qbe_arr_is_stable_expr(cond, aname, allow_elem_assign) &&
      qbe_arr_is_stable_stmt(step_s, aname, allow_elem_assign) &&
      qbe_arr_is_stable_stmts(body, 0, aname, allow_elem_assign)
    SReturn(opt, _) =>
      match opt {
        None => true
        Some(e) => qbe_arr_is_stable_expr(e, aname, allow_elem_assign)
      }
    SBreak(_) | SContinue(_) => true
    SDebugAssert(c, m, _) =>
      qbe_arr_is_stable_expr(c, aname, allow_elem_assign) &&
      qbe_arr_is_stable_expr(m, aname, allow_elem_assign)
    SExpr(e, _) => qbe_arr_is_stable_expr(e, aname, allow_elem_assign)
  }
}

///|
fn qbe_arr_is_stable_stmts(
  stmts : Array[Stmt],
  start_idx : Int,
  aname : String,
  allow_elem_assign : Bool,
) -> Bool {
  let mut i = start_idx
  while i < stmts.length() {
    match stmts[i] {
      SLet(lname, _, _, init, _) => {
        if !qbe_arr_is_stable_expr(init, aname, allow_elem_assign) {
          return false
        }
        if lname == aname {
          return true
        }
      }
      _ =>
        if !qbe_arr_is_stable_stmt(stmts[i], aname, allow_elem_assign) {
          return false
        }
    }
    i = i + 1
  }
  true
}

///|
fn qbe_collect_indexed_arrs_expr(e : Expr, out : Array[String]) -> Unit {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => ()
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_collect_indexed_arrs_expr(inner, out)
    EBinary(_, l, r, _) => {
      qbe_collect_indexed_arrs_expr(l, out)
      qbe_collect_indexed_arrs_expr(r, out)
    }
    EIndex(obj, idx, _) => {
      match obj {
        EIdent(aname, _) =>
          if !str_arr_contains(out, aname) {
            out.push(aname)
          }
        _ => qbe_collect_indexed_arrs_expr(obj, out)
      }
      qbe_collect_indexed_arrs_expr(idx, out)
    }
    ECall(callee, args, _) => {
      qbe_collect_indexed_arrs_expr(callee, out)
      let mut i = 0
      while i < args.length() {
        qbe_collect_indexed_arrs_expr(args[i], out)
        i = i + 1
      }
    }
    EMethodCall(obj, _, args, _) => {
      qbe_collect_indexed_arrs_expr(obj, out)
      let mut i = 0
      while i < args.length() {
        qbe_collect_indexed_arrs_expr(args[i], out)
        i = i + 1
      }
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        qbe_collect_indexed_arrs_expr(elems[i], out)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        qbe_collect_indexed_arrs_expr(fields[i].value, out)
        i = i + 1
      }
    }
    EBlock(stmts, _) => qbe_collect_indexed_arrs_stmts(stmts, out)
    EIf(cond, then_stmts, else_opt, _) => {
      qbe_collect_indexed_arrs_expr(cond, out)
      qbe_collect_indexed_arrs_stmts(then_stmts, out)
      match else_opt {
        None => ()
        Some(el) => qbe_collect_indexed_arrs_expr(el, out)
      }
    }
    EMatch(scrut, arms, _) => {
      qbe_collect_indexed_arrs_expr(scrut, out)
      let mut i = 0
      while i < arms.length() {
        qbe_collect_indexed_arrs_expr(arms[i].body, out)
        i = i + 1
      }
    }
    EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) => ()
  }
}

///|
fn qbe_collect_indexed_arrs_stmt(s : Stmt, out : Array[String]) -> Unit {
  match s {
    SLet(_, _, _, init, _) => qbe_collect_indexed_arrs_expr(init, out)
    SAssign(lhs, rhs, _) => {
      qbe_collect_indexed_arrs_expr(lhs, out)
      qbe_collect_indexed_arrs_expr(rhs, out)
    }
    SWhile(cond, body, _) => {
      qbe_collect_indexed_arrs_expr(cond, out)
      qbe_collect_indexed_arrs_stmts(body, out)
    }
    SFor(init_s, cond, step_s, body, _) => {
      qbe_collect_indexed_arrs_stmt(init_s, out)
      qbe_collect_indexed_arrs_expr(cond, out)
      qbe_collect_indexed_arrs_stmt(step_s, out)
      qbe_collect_indexed_arrs_stmts(body, out)
    }
    SReturn(opt, _) =>
      match opt {
        None => ()
        Some(e) => qbe_collect_indexed_arrs_expr(e, out)
      }
    SBreak(_) | SContinue(_) => ()
    SDebugAssert(c, m, _) => {
      qbe_collect_indexed_arrs_expr(c, out)
      qbe_collect_indexed_arrs_expr(m, out)
    }
    SExpr(e, _) => qbe_collect_indexed_arrs_expr(e, out)
  }
}

///|
fn qbe_collect_indexed_arrs_stmts(stmts : Array[Stmt], out : Array[String]) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    qbe_collect_indexed_arrs_stmt(stmts[i], out)
    i = i + 1
  }
}

///|
fn qbe_is_double_two(e : Expr) -> Bool {
  match e {
    EDouble(raw, _) => raw == "2.0" || raw == "2." || raw == "2.00" || raw == "2.000"
    _ => false
  }
}

///|
/// Conservative check: returns true only when `e` contains no calls (except pure `math_sqrt`)
/// and no closures/scope/spawn, guaranteeing zero hidden aliasing writes.
fn qbe_loop_has_no_calls_expr(e : Expr) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => true
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_loop_has_no_calls_expr(inner)
    EBinary(_, l, r, _) | EIndex(l, r, _) =>
      qbe_loop_has_no_calls_expr(l) && qbe_loop_has_no_calls_expr(r)
    ECall(callee, args, _) =>
      match callee {
        EIdent(fname, _) =>
          if fname == "math_sqrt" {
            let mut i = 0
            while i < args.length() {
              if !qbe_loop_has_no_calls_expr(args[i]) {
                return false
              }
              i = i + 1
            }
            true
          } else {
            false
          }
        _ => false
      }
    EMethodCall(_, _, _, _) | EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) =>
      false
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if !qbe_loop_has_no_calls_expr(elems[i]) {
          return false
        }
        i = i + 1
      }
      true
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if !qbe_loop_has_no_calls_expr(fields[i].value) {
          return false
        }
        i = i + 1
      }
      true
    }
    EBlock(stmts, _) => qbe_loop_has_no_calls_stmts(stmts)
    EIf(cond, then_stmts, else_opt, _) => {
      if !qbe_loop_has_no_calls_expr(cond) || !qbe_loop_has_no_calls_stmts(then_stmts) {
        return false
      }
      match else_opt {
        None => true
        Some(el) => qbe_loop_has_no_calls_expr(el)
      }
    }
    EMatch(scrut, arms, _) => {
      if !qbe_loop_has_no_calls_expr(scrut) {
        return false
      }
      let mut i = 0
      while i < arms.length() {
        if !qbe_loop_has_no_calls_expr(arms[i].body) {
          return false
        }
        i = i + 1
      }
      true
    }
  }
}

///|
fn qbe_loop_has_no_calls_stmt(s : Stmt) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_loop_has_no_calls_expr(init)
    SAssign(lhs, rhs, _) =>
      qbe_loop_has_no_calls_expr(lhs) && qbe_loop_has_no_calls_expr(rhs)
    SWhile(cond, body, _) =>
      qbe_loop_has_no_calls_expr(cond) && qbe_loop_has_no_calls_stmts(body)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_loop_has_no_calls_stmt(init_s) &&
      qbe_loop_has_no_calls_expr(cond) &&
      qbe_loop_has_no_calls_stmt(step_s) &&
      qbe_loop_has_no_calls_stmts(body)
    SReturn(opt, _) =>
      match opt {
        None => true
        Some(e) => qbe_loop_has_no_calls_expr(e)
      }
    SBreak(_) | SContinue(_) => true
    SDebugAssert(c, m, _) =>
      qbe_loop_has_no_calls_expr(c) && qbe_loop_has_no_calls_expr(m)
    SExpr(e, _) => qbe_loop_has_no_calls_expr(e)
  }
}

///|
fn qbe_loop_has_no_calls_stmts(stmts : Array[Stmt]) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if !qbe_loop_has_no_calls_stmt(stmts[i]) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn qbe_collect_written_fields_expr(e : Expr, out : Map[String, Bool]) -> Unit {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => ()
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_collect_written_fields_expr(inner, out)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) => {
      qbe_collect_written_fields_expr(l, out)
      qbe_collect_written_fields_expr(r, out)
    }
    ECall(callee, args, _) => {
      qbe_collect_written_fields_expr(callee, out)
      let mut i = 0
      while i < args.length() {
        qbe_collect_written_fields_expr(args[i], out)
        i = i + 1
      }
    }
    EMethodCall(obj, _, args, _) => {
      qbe_collect_written_fields_expr(obj, out)
      let mut i = 0
      while i < args.length() {
        qbe_collect_written_fields_expr(args[i], out)
        i = i + 1
      }
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        qbe_collect_written_fields_expr(elems[i], out)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        qbe_collect_written_fields_expr(fields[i].value, out)
        i = i + 1
      }
    }
    EBlock(stmts, _) => qbe_collect_written_fields_stmts(stmts, out)
    EIf(cond, then_stmts, else_opt, _) => {
      qbe_collect_written_fields_expr(cond, out)
      qbe_collect_written_fields_stmts(then_stmts, out)
      match else_opt {
        Some(el) => qbe_collect_written_fields_expr(el, out)
        None => ()
      }
    }
    EMatch(scrut, arms, _) => {
      qbe_collect_written_fields_expr(scrut, out)
      let mut i = 0
      while i < arms.length() {
        qbe_collect_written_fields_expr(arms[i].body, out)
        i = i + 1
      }
    }
    EClosure(_, _, body, _) => qbe_collect_written_fields_stmts(body, out)
  }
}

///|
fn qbe_collect_written_fields_stmt(s : Stmt, out : Map[String, Bool]) -> Unit {
  match s {
    SLet(_, _, _, init, _) => qbe_collect_written_fields_expr(init, out)
    SAssign(lhs, rhs, _) => {
      match lhs {
        EField(_, fname, _) => out.set(fname, true)
        _ => ()
      }
      qbe_collect_written_fields_expr(lhs, out)
      qbe_collect_written_fields_expr(rhs, out)
    }
    SWhile(cond, body, _) => {
      qbe_collect_written_fields_expr(cond, out)
      qbe_collect_written_fields_stmts(body, out)
    }
    SFor(init_s, cond, step_s, body, _) => {
      qbe_collect_written_fields_stmt(init_s, out)
      qbe_collect_written_fields_expr(cond, out)
      qbe_collect_written_fields_stmt(step_s, out)
      qbe_collect_written_fields_stmts(body, out)
    }
    SReturn(opt, _) =>
      match opt {
        Some(e) => qbe_collect_written_fields_expr(e, out)
        None => ()
      }
    SBreak(_) | SContinue(_) => ()
    SDebugAssert(c, m, _) => {
      qbe_collect_written_fields_expr(c, out)
      qbe_collect_written_fields_expr(m, out)
    }
    SExpr(e, _) => qbe_collect_written_fields_expr(e, out)
  }
}

///|
fn qbe_collect_written_fields_stmts(stmts : Array[Stmt], out : Map[String, Bool]) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    qbe_collect_written_fields_stmt(stmts[i], out)
    i = i + 1
  }
}

///|
fn qbe_collect_read_fields_expr(
  e : Expr,
  out_vars : Array[String],
  out_fields : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => ()
    EField(obj, fname, _) =>
      match obj {
        EIdent(vname, _) => {
          let key = vname + "." + fname
          if !seen.contains(key) {
            seen.set(key, true)
            out_vars.push(vname)
            out_fields.push(fname)
          }
        }
        _ => qbe_collect_read_fields_expr(obj, out_vars, out_fields, seen)
      }
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_collect_read_fields_expr(inner, out_vars, out_fields, seen)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) => {
      qbe_collect_read_fields_expr(l, out_vars, out_fields, seen)
      qbe_collect_read_fields_expr(r, out_vars, out_fields, seen)
    }
    ECall(callee, args, _) => {
      qbe_collect_read_fields_expr(callee, out_vars, out_fields, seen)
      let mut i = 0
      while i < args.length() {
        qbe_collect_read_fields_expr(args[i], out_vars, out_fields, seen)
        i = i + 1
      }
    }
    EMethodCall(obj, _, args, _) => {
      qbe_collect_read_fields_expr(obj, out_vars, out_fields, seen)
      let mut i = 0
      while i < args.length() {
        qbe_collect_read_fields_expr(args[i], out_vars, out_fields, seen)
        i = i + 1
      }
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        qbe_collect_read_fields_expr(elems[i], out_vars, out_fields, seen)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        qbe_collect_read_fields_expr(fields[i].value, out_vars, out_fields, seen)
        i = i + 1
      }
    }
    EBlock(stmts, _) =>
      qbe_collect_read_fields_stmts(stmts, out_vars, out_fields, seen)
    EIf(cond, then_stmts, else_opt, _) => {
      qbe_collect_read_fields_expr(cond, out_vars, out_fields, seen)
      qbe_collect_read_fields_stmts(then_stmts, out_vars, out_fields, seen)
      match else_opt {
        Some(el) => qbe_collect_read_fields_expr(el, out_vars, out_fields, seen)
        None => ()
      }
    }
    EMatch(scrut, arms, _) => {
      qbe_collect_read_fields_expr(scrut, out_vars, out_fields, seen)
      let mut i = 0
      while i < arms.length() {
        qbe_collect_read_fields_expr(arms[i].body, out_vars, out_fields, seen)
        i = i + 1
      }
    }
    EClosure(_, _, body, _) =>
      qbe_collect_read_fields_stmts(body, out_vars, out_fields, seen)
  }
}

///|
fn qbe_collect_read_fields_stmt(
  s : Stmt,
  out_vars : Array[String],
  out_fields : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  match s {
    SLet(_, _, _, init, _) =>
      qbe_collect_read_fields_expr(init, out_vars, out_fields, seen)
    SAssign(lhs, rhs, _) => {
      match lhs {
        EField(obj, _, _) =>
          qbe_collect_read_fields_expr(obj, out_vars, out_fields, seen)
        _ => qbe_collect_read_fields_expr(lhs, out_vars, out_fields, seen)
      }
      qbe_collect_read_fields_expr(rhs, out_vars, out_fields, seen)
    }
    SWhile(cond, body, _) => {
      qbe_collect_read_fields_expr(cond, out_vars, out_fields, seen)
      qbe_collect_read_fields_stmts(body, out_vars, out_fields, seen)
    }
    SFor(init_s, cond, step_s, body, _) => {
      qbe_collect_read_fields_stmt(init_s, out_vars, out_fields, seen)
      qbe_collect_read_fields_expr(cond, out_vars, out_fields, seen)
      qbe_collect_read_fields_stmt(step_s, out_vars, out_fields, seen)
      qbe_collect_read_fields_stmts(body, out_vars, out_fields, seen)
    }
    SReturn(opt, _) =>
      match opt {
        Some(e) => qbe_collect_read_fields_expr(e, out_vars, out_fields, seen)
        None => ()
      }
    SBreak(_) | SContinue(_) => ()
    SDebugAssert(c, m, _) => {
      qbe_collect_read_fields_expr(c, out_vars, out_fields, seen)
      qbe_collect_read_fields_expr(m, out_vars, out_fields, seen)
    }
    SExpr(e, _) => qbe_collect_read_fields_expr(e, out_vars, out_fields, seen)
  }
}

///|
fn qbe_collect_read_fields_stmts(
  stmts : Array[Stmt],
  out_vars : Array[String],
  out_fields : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    qbe_collect_read_fields_stmt(stmts[i], out_vars, out_fields, seen)
    i = i + 1
  }
}

///|
fn qbe_expr_rebinds_ident(e : Expr, name : String) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_rebinds_ident(inner, name)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_rebinds_ident(l, name) || qbe_expr_rebinds_ident(r, name)
    ECall(callee, args, _) => {
      if qbe_expr_rebinds_ident(callee, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_rebinds_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_rebinds_ident(obj, name) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_rebinds_ident(args[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_rebinds_ident(elems[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_rebinds_ident(fields[i].value, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(stmts, _) => qbe_stmts_rebinds_ident(stmts, name)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_rebinds_ident(cond, name) || qbe_stmts_rebinds_ident(then_stmts, name) {
        return true
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_rebinds_ident(el, name)
      }
    }
    EMatch(scrut, arms, _) => {
      if qbe_expr_rebinds_ident(scrut, name) {
        return true
      }
      let mut i = 0
      while i < arms.length() {
        if qbe_pat_binds_name(arms[i].pat, name) ||
          qbe_expr_rebinds_ident(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EClosure(_, _, body, _) => qbe_stmts_rebinds_ident(body, name)
  }
}

///|
fn qbe_stmt_rebinds_ident(s : Stmt, name : String) -> Bool {
  match s {
    SLet(n, _, _, init, _) => n == name || qbe_expr_rebinds_ident(init, name)
    SAssign(lhs, rhs, _) =>
      qbe_expr_rebinds_ident(lhs, name) || qbe_expr_rebinds_ident(rhs, name)
    SWhile(cond, body, _) =>
      qbe_expr_rebinds_ident(cond, name) || qbe_stmts_rebinds_ident(body, name)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_stmt_rebinds_ident(init_s, name) ||
      qbe_expr_rebinds_ident(cond, name) ||
      qbe_stmt_rebinds_ident(step_s, name) ||
      qbe_stmts_rebinds_ident(body, name)
    SReturn(opt, _) =>
      match opt {
        None => false
        Some(e) => qbe_expr_rebinds_ident(e, name)
      }
    SBreak(_) | SContinue(_) => false
    SDebugAssert(c, m, _) =>
      qbe_expr_rebinds_ident(c, name) || qbe_expr_rebinds_ident(m, name)
    SExpr(e, _) => qbe_expr_rebinds_ident(e, name)
  }
}

///|
fn qbe_stmts_rebinds_ident(stmts : Array[Stmt], name : String) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if qbe_stmt_rebinds_ident(stmts[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn qbe_stmt_is_inc_by_one(s : Stmt, name : String) -> Bool {
  match s {
    SAssign(EIdent(lhs_n, _), EBinary("+", EIdent(rhs_n, _), EInt(raw, _), _), _) =>
      lhs_n == name && rhs_n == name && qbe_parse_int64_lit(raw) == 1L
    _ => false
  }
}

///|
fn qbe_cond_node_count(e : Expr) -> Int {
  match e {
    EIdent(_, _)
    | EInt(_, _)
    | EInt64(_, _)
    | EBool(_, _)
    | EDouble(_, _)
    | EByte(_, _)
    | EChar(_, _) => 1
    EUnary(_, inner, _) => {
      let n = qbe_cond_node_count(inner)
      if n < 0 { -1 } else { n + 1 }
    }
    EBinary(_, lhs, rhs, _) => {
      let nl = qbe_cond_node_count(lhs)
      if nl < 0 {
        return -1
      }
      let nr = qbe_cond_node_count(rhs)
      if nr < 0 { -1 } else { nl + nr + 1 }
    }
    _ => -1
  }
}

///|
fn qbe_is_pure_small_cond(cond : Expr, max_nodes : Int) -> Bool {
  let n = qbe_cond_node_count(cond)
  n > 0 && n <= max_nodes
}

///|
fn qbe_expr_has_nested_loop(e : Expr) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_has_nested_loop(inner)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_has_nested_loop(l) || qbe_expr_has_nested_loop(r)
    ECall(callee, args, _) => {
      if qbe_expr_has_nested_loop(callee) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_nested_loop(args[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_has_nested_loop(obj) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_nested_loop(args[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_has_nested_loop(elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_has_nested_loop(fields[i].value) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(stmts, _) => qbe_stmts_has_nested_loop(stmts)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_has_nested_loop(cond) || qbe_stmts_has_nested_loop(then_stmts) {
        return true
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_has_nested_loop(el)
      }
    }
    EMatch(scrut, arms, _) => {
      if qbe_expr_has_nested_loop(scrut) {
        return true
      }
      let mut i = 0
      while i < arms.length() {
        if qbe_expr_has_nested_loop(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    EClosure(_, _, body, _) => qbe_stmts_has_nested_loop(body)
  }
}

///|
fn qbe_stmt_has_nested_loop(s : Stmt) -> Bool {
  match s {
    SWhile(_, _, _) | SFor(_, _, _, _, _) => true
    SLet(_, _, _, init, _) => qbe_expr_has_nested_loop(init)
    SAssign(lhs, rhs, _) =>
      qbe_expr_has_nested_loop(lhs) || qbe_expr_has_nested_loop(rhs)
    SReturn(opt, _) =>
      match opt {
        None => false
        Some(e) => qbe_expr_has_nested_loop(e)
      }
    SBreak(_) | SContinue(_) => false
    SDebugAssert(c, m, _) =>
      qbe_expr_has_nested_loop(c) || qbe_expr_has_nested_loop(m)
    SExpr(e, _) => qbe_expr_has_nested_loop(e)
  }
}

///|
fn qbe_stmts_has_nested_loop(stmts : Array[Stmt]) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if qbe_stmt_has_nested_loop(stmts[i]) {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn qbe_expr_has_cf(
  e : Expr,
  check_break : Bool,
  check_cont : Bool,
  check_ret : Bool,
) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => false
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_has_cf(inner, check_break, check_cont, check_ret)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_has_cf(l, check_break, check_cont, check_ret) ||
      qbe_expr_has_cf(r, check_break, check_cont, check_ret)
    ECall(callee, args, _) => {
      if qbe_expr_has_cf(callee, check_break, check_cont, check_ret) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_cf(args[i], check_break, check_cont, check_ret) {
          return true
        }
        i = i + 1
      }
      false
    }
    EMethodCall(obj, _, args, _) => {
      if qbe_expr_has_cf(obj, check_break, check_cont, check_ret) {
        return true
      }
      let mut i = 0
      while i < args.length() {
        if qbe_expr_has_cf(args[i], check_break, check_cont, check_ret) {
          return true
        }
        i = i + 1
      }
      false
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if qbe_expr_has_cf(elems[i], check_break, check_cont, check_ret) {
          return true
        }
        i = i + 1
      }
      false
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if qbe_expr_has_cf(fields[i].value, check_break, check_cont, check_ret) {
          return true
        }
        i = i + 1
      }
      false
    }
    EBlock(stmts, _) => qbe_stmts_has_cf(stmts, check_break, check_cont, check_ret)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_has_cf(cond, check_break, check_cont, check_ret) ||
        qbe_stmts_has_cf(then_stmts, check_break, check_cont, check_ret) {
        return true
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_has_cf(el, check_break, check_cont, check_ret)
      }
    }
    EMatch(scrut, arms, _) => {
      if qbe_expr_has_cf(scrut, check_break, check_cont, check_ret) {
        return true
      }
      let mut i = 0
      while i < arms.length() {
        if qbe_expr_has_cf(arms[i].body, check_break, check_cont, check_ret) {
          return true
        }
        i = i + 1
      }
      false
    }
    EClosure(_, _, _, _) => false
  }
}

///|
fn qbe_stmt_has_cf(
  s : Stmt,
  check_break : Bool,
  check_cont : Bool,
  check_ret : Bool,
) -> Bool {
  match s {
    SBreak(_) => check_break
    SContinue(_) => check_cont
    SReturn(opt, _) =>
      if check_ret {
        true
      } else {
        match opt {
          None => false
          Some(e) => qbe_expr_has_cf(e, check_break, check_cont, check_ret)
        }
      }
    SLet(_, _, _, init, _) =>
      qbe_expr_has_cf(init, check_break, check_cont, check_ret)
    SAssign(lhs, rhs, _) =>
      qbe_expr_has_cf(lhs, check_break, check_cont, check_ret) ||
      qbe_expr_has_cf(rhs, check_break, check_cont, check_ret)
    SWhile(cond, body, _) =>
      qbe_expr_has_cf(cond, check_break, check_cont, check_ret) ||
      qbe_stmts_has_cf(body, false, false, check_ret)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_stmt_has_cf(init_s, check_break, check_cont, check_ret) ||
      qbe_expr_has_cf(cond, check_break, check_cont, check_ret) ||
      qbe_stmt_has_cf(step_s, false, false, check_ret) ||
      qbe_stmts_has_cf(body, false, false, check_ret)
    SDebugAssert(c, m, _) =>
      qbe_expr_has_cf(c, check_break, check_cont, check_ret) ||
      qbe_expr_has_cf(m, check_break, check_cont, check_ret)
    SExpr(e, _) => qbe_expr_has_cf(e, check_break, check_cont, check_ret)
  }
}

///|
fn qbe_stmts_has_cf(
  stmts : Array[Stmt],
  check_break : Bool,
  check_cont : Bool,
  check_ret : Bool,
) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if qbe_stmt_has_cf(stmts[i], check_break, check_cont, check_ret) {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn qbe_bce_expr_is_safe(g : QbeGen, arr : String, idx : Expr) -> Bool {
  match idx {
    EIdent(iname, _) =>
      g.bce_safe_indices.contains(iname + ":" + arr) ||
      g.bce_safe_exprs.contains(arr + ":iv:" + iname)
    EBinary("+", EIdent(iname, _), EInt(raw, _), _) => {
      let c = qbe_parse_int64_lit(raw)
      g.bce_safe_exprs.contains(arr + ":iv+:" + iname + ":" + c.to_string())
    }
    EBinary("+", EInt(raw, _), EIdent(iname, _), _) => {
      let c = qbe_parse_int64_lit(raw)
      g.bce_safe_exprs.contains(arr + ":iv+:" + iname + ":" + c.to_string())
    }
    EBinary("-", EIdent(vname, _), EIdent(iname, _), _) =>
      g.bce_safe_exprs.contains(arr + ":v-iv:" + vname + ":" + iname)
    _ => false
  }
}

///|
fn qbe_bce_try_add_guard(
  g : QbeGen,
  body : Array[Stmt],
  iv : String,
  arr : String,
  idx : Expr,
  out : Array[QbeBceGuard],
  seen : Map[String, Bool],
) -> Unit {
  if !g.hoisted_arr_len.contains(arr) || qbe_stmts_rebinds_ident(body, arr) {
    return
  }
  match idx {
    EIdent(iname, _) =>
      if iname == iv && !g.bce_safe_indices.contains(iv + ":" + arr) {
        let key = arr + ":iv:" + iv
        if !seen.contains(key) {
          seen.set(key, true)
          out.push(QbeBceGuard::{ arr: arr, kind: 0, offset: 0L, vname: "", key: key })
        }
      }
    EBinary("+", EIdent(iname, _), EInt(raw, _), _) =>
      if iname == iv {
        let c = qbe_parse_int64_lit(raw)
        if c > 0L && c <= 2147483647L {
          let key = arr + ":iv+:" + iv + ":" + c.to_string()
          if !seen.contains(key) {
            seen.set(key, true)
            out.push(QbeBceGuard::{ arr: arr, kind: 1, offset: c, vname: "", key: key })
          }
        }
      }
    EBinary("+", EInt(raw, _), EIdent(iname, _), _) =>
      if iname == iv {
        let c = qbe_parse_int64_lit(raw)
        if c > 0L && c <= 2147483647L {
          let key = arr + ":iv+:" + iv + ":" + c.to_string()
          if !seen.contains(key) {
            seen.set(key, true)
            out.push(QbeBceGuard::{ arr: arr, kind: 1, offset: c, vname: "", key: key })
          }
        }
      }
    EBinary("-", EIdent(vname, _), EIdent(iname, _), _) =>
      if iname == iv &&
        vname != iv &&
        !qbe_stmts_assigns_ident(body, vname) &&
        !qbe_stmts_rebinds_ident(body, vname) {
        match qbe_lookup_local(g, vname) {
          Some(vloc) =>
            if qbe_is_int32_ty(vloc.ty) {
              let key = arr + ":v-iv:" + vname + ":" + iv
              if !seen.contains(key) {
                seen.set(key, true)
                out.push(QbeBceGuard::{ arr: arr, kind: 2, offset: 0L, vname: vname, key: key })
              }
            }
          None => ()
        }
      }
    _ => ()
  }
}

///|
fn qbe_collect_bce_guards_expr(
  g : QbeGen,
  body : Array[Stmt],
  iv : String,
  e : Expr,
  out : Array[QbeBceGuard],
  seen : Map[String, Bool],
) -> Unit {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => ()
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_collect_bce_guards_expr(g, body, iv, inner, out, seen)
    EBinary(_, l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, l, out, seen)
      qbe_collect_bce_guards_expr(g, body, iv, r, out, seen)
    }
    EIndex(obj, idx, _) => {
      match obj {
        EIdent(arr, _) => qbe_bce_try_add_guard(g, body, iv, arr, idx, out, seen)
        _ => qbe_collect_bce_guards_expr(g, body, iv, obj, out, seen)
      }
      qbe_collect_bce_guards_expr(g, body, iv, idx, out, seen)
    }
    ECall(callee, args, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, callee, out, seen)
      let mut i = 0
      while i < args.length() {
        qbe_collect_bce_guards_expr(g, body, iv, args[i], out, seen)
        i = i + 1
      }
    }
    EMethodCall(obj, _, args, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, obj, out, seen)
      let mut i = 0
      while i < args.length() {
        qbe_collect_bce_guards_expr(g, body, iv, args[i], out, seen)
        i = i + 1
      }
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        qbe_collect_bce_guards_expr(g, body, iv, elems[i], out, seen)
        i = i + 1
      }
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        qbe_collect_bce_guards_expr(g, body, iv, fields[i].value, out, seen)
        i = i + 1
      }
    }
    EBlock(stmts, _) => qbe_collect_bce_guards_stmts(g, body, iv, stmts, out, seen)
    EIf(cond, then_stmts, else_opt, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, cond, out, seen)
      qbe_collect_bce_guards_stmts(g, body, iv, then_stmts, out, seen)
      match else_opt {
        None => ()
        Some(el) => qbe_collect_bce_guards_expr(g, body, iv, el, out, seen)
      }
    }
    EMatch(scrut, arms, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, scrut, out, seen)
      let mut i = 0
      while i < arms.length() {
        qbe_collect_bce_guards_expr(g, body, iv, arms[i].body, out, seen)
        i = i + 1
      }
    }
    EClosure(_, _, _, _) => ()
  }
}

///|
fn qbe_collect_bce_guards_stmt(
  g : QbeGen,
  body : Array[Stmt],
  iv : String,
  s : Stmt,
  out : Array[QbeBceGuard],
  seen : Map[String, Bool],
) -> Unit {
  match s {
    SLet(_, _, _, init, _) =>
      qbe_collect_bce_guards_expr(g, body, iv, init, out, seen)
    SAssign(lhs, rhs, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, lhs, out, seen)
      qbe_collect_bce_guards_expr(g, body, iv, rhs, out, seen)
    }
    SReturn(opt, _) =>
      match opt {
        None => ()
        Some(e) => qbe_collect_bce_guards_expr(g, body, iv, e, out, seen)
      }
    SDebugAssert(c, m, _) => {
      qbe_collect_bce_guards_expr(g, body, iv, c, out, seen)
      qbe_collect_bce_guards_expr(g, body, iv, m, out, seen)
    }
    SExpr(e, _) => qbe_collect_bce_guards_expr(g, body, iv, e, out, seen)
    SWhile(_, _, _) | SFor(_, _, _, _, _) | SBreak(_) | SContinue(_) => ()
  }
}

///|
fn qbe_collect_bce_guards_stmts(
  g : QbeGen,
  body : Array[Stmt],
  iv : String,
  stmts : Array[Stmt],
  out : Array[QbeBceGuard],
  seen : Map[String, Bool],
) -> Unit {
  let mut i = 0
  while i < stmts.length() {
    qbe_collect_bce_guards_stmt(g, body, iv, stmts[i], out, seen)
    i = i + 1
  }
}

///|
fn qbe_expr_count_assigns_ident(e : Expr, name : String) -> Int {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => 0
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_count_assigns_ident(inner, name)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_expr_count_assigns_ident(l, name) + qbe_expr_count_assigns_ident(r, name)
    ECall(callee, args, _) => {
      let mut n = qbe_expr_count_assigns_ident(callee, name)
      let mut i = 0
      while i < args.length() {
        n = n + qbe_expr_count_assigns_ident(args[i], name)
        i = i + 1
      }
      n
    }
    EMethodCall(obj, _, args, _) => {
      let mut n = qbe_expr_count_assigns_ident(obj, name)
      let mut i = 0
      while i < args.length() {
        n = n + qbe_expr_count_assigns_ident(args[i], name)
        i = i + 1
      }
      n
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut n = 0
      let mut i = 0
      while i < elems.length() {
        n = n + qbe_expr_count_assigns_ident(elems[i], name)
        i = i + 1
      }
      n
    }
    EStructLit(_, fields, _) => {
      let mut n = 0
      let mut i = 0
      while i < fields.length() {
        n = n + qbe_expr_count_assigns_ident(fields[i].value, name)
        i = i + 1
      }
      n
    }
    EBlock(stmts, _) => qbe_stmts_count_assigns_ident(stmts, name)
    EIf(cond, then_stmts, else_opt, _) => {
      let mut n = qbe_expr_count_assigns_ident(cond, name) +
        qbe_stmts_count_assigns_ident(then_stmts, name)
      match else_opt {
        None => ()
        Some(el) => n = n + qbe_expr_count_assigns_ident(el, name)
      }
      n
    }
    EMatch(scrut, arms, _) => {
      let mut n = qbe_expr_count_assigns_ident(scrut, name)
      let mut i = 0
      while i < arms.length() {
        n = n + qbe_expr_count_assigns_ident(arms[i].body, name)
        i = i + 1
      }
      n
    }
    EClosure(_, _, body, _) => qbe_stmts_count_assigns_ident(body, name)
  }
}

///|
fn qbe_stmt_count_assigns_ident(s : Stmt, name : String) -> Int {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_count_assigns_ident(init, name)
    SAssign(lhs, rhs, _) => {
      let self_hit = match lhs {
        EIdent(n, _) => if n == name { 1 } else { 0 }
        _ => 0
      }
      self_hit +
      qbe_expr_count_assigns_ident(lhs, name) +
      qbe_expr_count_assigns_ident(rhs, name)
    }
    SWhile(cond, body, _) =>
      qbe_expr_count_assigns_ident(cond, name) +
      qbe_stmts_count_assigns_ident(body, name)
    SFor(init_s, cond, step_s, body, _) =>
      qbe_stmt_count_assigns_ident(init_s, name) +
      qbe_expr_count_assigns_ident(cond, name) +
      qbe_stmt_count_assigns_ident(step_s, name) +
      qbe_stmts_count_assigns_ident(body, name)
    SReturn(opt, _) =>
      match opt {
        None => 0
        Some(e) => qbe_expr_count_assigns_ident(e, name)
      }
    SBreak(_) | SContinue(_) => 0
    SDebugAssert(c, m, _) =>
      qbe_expr_count_assigns_ident(c, name) +
      qbe_expr_count_assigns_ident(m, name)
    SExpr(e, _) => qbe_expr_count_assigns_ident(e, name)
  }
}

///|
fn qbe_stmts_count_assigns_ident(stmts : Array[Stmt], name : String) -> Int {
  let mut n = 0
  let mut i = 0
  while i < stmts.length() {
    n = n + qbe_stmt_count_assigns_ident(stmts[i], name)
    i = i + 1
  }
  n
}

///|
fn qbe_expr_has_sq(e : Expr, name : String) -> Bool {
  match e {
    EBinary("*", EIdent(a, _), EIdent(b, _), _) => a == name && b == name
    EBinary(_, l, r, _) | EIndex(l, r, _) =>
      qbe_expr_has_sq(l, name) || qbe_expr_has_sq(r, name)
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_has_sq(inner, name)
    EBlock(stmts, _) => {
      let mut i = 0
      while i < stmts.length() {
        if qbe_stmt_has_sq(stmts[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_has_sq(cond, name) {
        return true
      }
      let mut i = 0
      while i < then_stmts.length() {
        if qbe_stmt_has_sq(then_stmts[i], name) {
          return true
        }
        i = i + 1
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_has_sq(el, name)
      }
    }
    _ => false
  }
}

///|
fn qbe_stmt_has_sq(s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_has_sq(init, name)
    SAssign(lhs, rhs, _) =>
      qbe_expr_has_sq(lhs, name) || qbe_expr_has_sq(rhs, name)
    SExpr(e, _) => qbe_expr_has_sq(e, name)
    SReturn(opt, _) =>
      match opt {
        None => false
        Some(e) => qbe_expr_has_sq(e, name)
      }
    _ => false
  }
}

///|
fn qbe_expr_uncond_has_sq(e : Expr, name : String) -> Bool {
  match e {
    EBinary("*", EIdent(a, _), EIdent(b, _), _) => a == name && b == name
    EBinary(op, l, r, _) =>
      if op == "&&" || op == "||" {
        qbe_expr_uncond_has_sq(l, name)
      } else {
        qbe_expr_uncond_has_sq(l, name) || qbe_expr_uncond_has_sq(r, name)
      }
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_uncond_has_sq(inner, name)
    EIf(cond, _, _, _) => qbe_expr_uncond_has_sq(cond, name)
    _ => false
  }
}

///|
fn qbe_stmt_uncond_has_sq(s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_uncond_has_sq(init, name)
    SAssign(_, rhs, _) => qbe_expr_uncond_has_sq(rhs, name)
    SExpr(e, _) => qbe_expr_uncond_has_sq(e, name)
    _ => false
  }
}

///|
fn qbe_expr_has_branch_sq(e : Expr, name : String) -> Bool {
  match e {
    EBinary(op, l, r, _) =>
      if op == "&&" || op == "||" {
        qbe_expr_has_branch_sq(l, name) || qbe_expr_has_sq(r, name)
      } else {
        qbe_expr_has_branch_sq(l, name) || qbe_expr_has_branch_sq(r, name)
      }
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) =>
      qbe_expr_has_branch_sq(inner, name)
    EIf(cond, then_stmts, else_opt, _) => {
      if qbe_expr_has_branch_sq(cond, name) {
        return true
      }
      let mut i = 0
      while i < then_stmts.length() {
        if qbe_stmt_has_sq(then_stmts[i], name) {
          return true
        }
        i = i + 1
      }
      match else_opt {
        None => false
        Some(el) => qbe_expr_has_sq(el, name)
      }
    }
    EMatch(_, arms, _) => {
      let mut i = 0
      while i < arms.length() {
        if qbe_expr_has_sq(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    _ => false
  }
}

///|
fn qbe_stmt_has_branch_sq(s : Stmt, name : String) -> Bool {
  match s {
    SLet(_, _, _, init, _) => qbe_expr_has_branch_sq(init, name)
    SAssign(lhs, rhs, _) =>
      qbe_expr_has_branch_sq(lhs, name) || qbe_expr_has_branch_sq(rhs, name)
    SExpr(e, _) => qbe_expr_has_branch_sq(e, name)
    _ => false
  }
}

///|
fn qbe_collect_field_access_expr(
  e : Expr,
  write_vars : Array[String],
  write_fields : Array[String],
  read_vars : Array[String],
  read_fields : Array[String],
  all_vars : Array[String],
  seen_all : Map[String, Bool],
) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => true
    EField(obj, fname, _) =>
      match obj {
        EIdent(vname, _) => {
          read_vars.push(vname)
          read_fields.push(fname)
          if !seen_all.contains(vname) {
            seen_all.set(vname, true)
            all_vars.push(vname)
          }
          true
        }
        _ => false
      }
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_collect_field_access_expr(inner, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    EBinary(_, l, r, _) | EIndex(l, r, _) | EScope(l, r, _) | ESpawn(l, r, _) =>
      qbe_collect_field_access_expr(l, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) &&
      qbe_collect_field_access_expr(r, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    ECall(callee, args, _) => {
      if !qbe_collect_field_access_expr(callee, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
        return false
      }
      let mut i = 0
      while i < args.length() {
        if !qbe_collect_field_access_expr(args[i], write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
          return false
        }
        i = i + 1
      }
      true
    }
    EMethodCall(obj, _, args, _) => {
      if !qbe_collect_field_access_expr(obj, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
        return false
      }
      let mut i = 0
      while i < args.length() {
        if !qbe_collect_field_access_expr(args[i], write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
          return false
        }
        i = i + 1
      }
      true
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut i = 0
      while i < elems.length() {
        if !qbe_collect_field_access_expr(elems[i], write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
          return false
        }
        i = i + 1
      }
      true
    }
    EStructLit(_, fields, _) => {
      let mut i = 0
      while i < fields.length() {
        if !qbe_collect_field_access_expr(fields[i].value, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
          return false
        }
        i = i + 1
      }
      true
    }
    EBlock(stmts, _) =>
      qbe_collect_field_access_stmts(stmts, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    EIf(cond, then_stmts, else_opt, _) => {
      if !qbe_collect_field_access_expr(cond, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) ||
        !qbe_collect_field_access_stmts(then_stmts, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
        return false
      }
      match else_opt {
        None => true
        Some(el) =>
          qbe_collect_field_access_expr(el, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
      }
    }
    EMatch(scrut, arms, _) => {
      if !qbe_collect_field_access_expr(scrut, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
        return false
      }
      let mut i = 0
      while i < arms.length() {
        if !qbe_collect_field_access_expr(arms[i].body, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
          return false
        }
        i = i + 1
      }
      true
    }
    EClosure(_, _, _, _) => false
  }
}

///|
fn qbe_collect_field_access_stmt(
  s : Stmt,
  write_vars : Array[String],
  write_fields : Array[String],
  read_vars : Array[String],
  read_fields : Array[String],
  all_vars : Array[String],
  seen_all : Map[String, Bool],
) -> Bool {
  match s {
    SLet(_, _, _, init, _) =>
      qbe_collect_field_access_expr(init, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    SAssign(lhs, rhs, _) => {
      let lhs_ok = match lhs {
        EField(EIdent(vname, _), fname, _) => {
          write_vars.push(vname)
          write_fields.push(fname)
          if !seen_all.contains(vname) {
            seen_all.set(vname, true)
            all_vars.push(vname)
          }
          true
        }
        EField(_, _, _) => false
        _ =>
          qbe_collect_field_access_expr(lhs, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
      }
      lhs_ok &&
      qbe_collect_field_access_expr(rhs, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    }
    SReturn(opt, _) =>
      match opt {
        None => true
        Some(e) =>
          qbe_collect_field_access_expr(e, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
      }
    SDebugAssert(c, m, _) =>
      qbe_collect_field_access_expr(c, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) &&
      qbe_collect_field_access_expr(m, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    SExpr(e, _) =>
      qbe_collect_field_access_expr(e, write_vars, write_fields, read_vars, read_fields, all_vars, seen_all)
    SWhile(_, _, _) | SFor(_, _, _, _, _) | SBreak(_) | SContinue(_) => true
  }
}

///|
fn qbe_collect_field_access_stmts(
  stmts : Array[Stmt],
  write_vars : Array[String],
  write_fields : Array[String],
  read_vars : Array[String],
  read_fields : Array[String],
  all_vars : Array[String],
  seen_all : Map[String, Bool],
) -> Bool {
  let mut i = 0
  while i < stmts.length() {
    if !qbe_collect_field_access_stmt(stmts[i], write_vars, write_fields, read_vars, read_fields, all_vars, seen_all) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn qbe_invalidate_len_aliases_for(g : QbeGen, arr_name : String) -> Unit {
  let mut i = 0
  while i < g.len_alias_keys.length() {
    let k = g.len_alias_keys[i]
    match g.len_aliases.get(k) {
      Some(v) =>
        if v == arr_name {
          g.len_aliases.remove(k)
        }
      None => ()
    }
    i = i + 1
  }
}

///|
fn qbe_expr_inline_cost(e : Expr, self_name : String) -> Int {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EString(_, _)
    | EIdent(_, _)
    | EPath(_, _, _)
    | EUnit(_) => 1
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) | EField(inner, _, _) => {
      let c = qbe_expr_inline_cost(inner, self_name)
      if c < 0 { -1 } else { c + 1 }
    }
    EBinary(_, l, r, _) | EIndex(l, r, _) => {
      let cl = qbe_expr_inline_cost(l, self_name)
      if cl < 0 {
        return -1
      }
      let cr = qbe_expr_inline_cost(r, self_name)
      if cr < 0 { -1 } else { cl + cr + 1 }
    }
    ECall(callee, args, _) => {
      match callee {
        EIdent(cname, _) =>
          if cname == self_name {
            return -1
          }
        _ => ()
      }
      let mut tot = qbe_expr_inline_cost(callee, self_name)
      if tot < 0 {
        return -1
      }
      let mut i = 0
      while i < args.length() {
        let ca = qbe_expr_inline_cost(args[i], self_name)
        if ca < 0 {
          return -1
        }
        tot = tot + ca
        i = i + 1
      }
      tot + 2
    }
    EMethodCall(obj, _, args, _) => {
      let mut tot = qbe_expr_inline_cost(obj, self_name)
      if tot < 0 {
        return -1
      }
      let mut i = 0
      while i < args.length() {
        let ca = qbe_expr_inline_cost(args[i], self_name)
        if ca < 0 {
          return -1
        }
        tot = tot + ca
        i = i + 1
      }
      tot + 2
    }
    EArrayLit(elems, _) | ETuple(elems, _) => {
      let mut tot = 2
      let mut i = 0
      while i < elems.length() {
        let ca = qbe_expr_inline_cost(elems[i], self_name)
        if ca < 0 {
          return -1
        }
        tot = tot + ca
        i = i + 1
      }
      tot
    }
    EStructLit(_, fields, _) => {
      let mut tot = 2
      let mut i = 0
      while i < fields.length() {
        let ca = qbe_expr_inline_cost(fields[i].value, self_name)
        if ca < 0 {
          return -1
        }
        tot = tot + ca
        i = i + 1
      }
      tot
    }
    EBlock(stmts, _) => qbe_stmts_inline_cost(stmts, self_name)
    EIf(cond, then_stmts, else_opt, _) => {
      let cc = qbe_expr_inline_cost(cond, self_name)
      if cc < 0 {
        return -1
      }
      let ct = qbe_stmts_inline_cost(then_stmts, self_name)
      if ct < 0 {
        return -1
      }
      let ce = match else_opt {
        None => 0
        Some(el) => qbe_expr_inline_cost(el, self_name)
      }
      if ce < 0 { -1 } else { cc + ct + ce + 2 }
    }
    EMatch(_, _, _) | EClosure(_, _, _, _) | EScope(_, _, _) | ESpawn(_, _, _) =>
      -1
  }
}

///|
fn qbe_stmts_inline_cost(stmts : Array[Stmt], self_name : String) -> Int {
  let mut tot = 0
  let mut i = 0
  while i < stmts.length() {
    match stmts[i] {
      SLet(_, _, _, init, _) => {
        let c = qbe_expr_inline_cost(init, self_name)
        if c < 0 {
          return -1
        }
        tot = tot + c + 1
      }
      SAssign(lhs, rhs, _) => {
        let cl = qbe_expr_inline_cost(lhs, self_name)
        if cl < 0 {
          return -1
        }
        let cr = qbe_expr_inline_cost(rhs, self_name)
        if cr < 0 {
          return -1
        }
        tot = tot + cl + cr + 1
      }
      SExpr(e, _) => {
        let c = qbe_expr_inline_cost(e, self_name)
        if c < 0 {
          return -1
        }
        tot = tot + c
      }
      SWhile(_, _, _) | SFor(_, _, _, _, _) | SReturn(_, _) | SBreak(_) | SContinue(_) | SDebugAssert(_, _, _) =>
        return -1
    }
    if tot > 40 {
      return -1
    }
    i = i + 1
  }
  tot
}

///|
fn qbe_collect_file_inline_fns(f : SourceFile) -> Map[String, FnDecl] {
  let m : Map[String, FnDecl] = Map([])
  let mut di = 0
  while di < f.decls.length() {
    match f.decls[di] {
      DFn(fd) =>
        if fd.receiver_type == "" &&
          fd.type_params.length() == 0 &&
          fd.name != "main" &&
          fd.body.length() >= 1 &&
          fd.body.length() <= 8 {
          let cost = qbe_stmts_inline_cost(fd.body, fd.name)
          if cost >= 0 && cost <= 40 {
            m.set(fd.name, fd)
          }
        }
      _ => ()
    }
    di = di + 1
  }
  m
}

///|
fn qbe_new(tc : TypeChecker, release : Bool, unit_mode : Bool) -> QbeGen {
  QbeGen::{
    tc: tc,
    release: release,
    unit_mode: unit_mode,
    pkg_prefix: qbe_pkg_prefix_for(tc.pkg_name, tc.multi_pkg),
    struct_order: [],
    enum_order: [],
    const_order: [],
    strings: [],
    string_ids: Map([]),
    cstrings: [],
    cstring_ids: Map([]),
    enum_consts: [],
    enum_const_seen: Map([]),
    slot_drop_masks: [],
    slot_drop_seen: Map([]),
    fn_wrappers: [],
    fn_wrapper_seen: Map([]),
    extra_fns: [],
    inline_fns: Map([]),
    inline_depth: 0,
    inline_stack: [],
    hoisted_arr_len: Map([]),
    hoisted_arr_dp: Map([]),
    hoisted_fields: Map([]),
    block_immut_fields: Map([]),
    len_aliases: Map([]),
    len_alias_keys: [],
    nonneg_vars: Map([]),
    bce_safe_indices: Map([]),
    bce_safe_exprs: Map([]),
    sq_reuse_slot: Map([]),
    sq_reuse_state: Map([]),
    promoted_fields: Map([]),
    promoted_field_tys: Map([]),
    w_to_l_ext: Map([]),
    local_w_to_l_ext: Map([]),
    next_tmp: 0,
    next_lbl: 0,
    next_clo: 0,
    fn_allocs: StringBuilder(),
    fn_body: StringBuilder(),
    scopes: [],
    loop_breaks: [],
    loop_conts: [],
    loop_depths: [],
    cur_tparams: [],
    cur_ret_ty: TUnit,
    cur_ret_abi_ty: TUnit,
    block_term: false,
    need_none_const: false,
    need_drop_opt_obj: false,
    need_drop_res_ok: false,
    need_drop_res_err: false,
    need_drop_res_both: false,
  }
}

///|
fn qbe_tmp(g : QbeGen) -> String {
  let id = g.next_tmp
  g.next_tmp = id + 1
  "%t" + id.to_string()
}

///|
fn qbe_lbl(g : QbeGen, prefix : String) -> String {
  let id = g.next_lbl
  g.next_lbl = id + 1
  "@" + prefix + "_" + id.to_string()
}

///|
fn qbe_emit(g : QbeGen, line : String) -> Unit {
  if !g.block_term {
    g.fn_body.write_string("    ")
    g.fn_body.write_string(line)
    g.fn_body.write_string("\n")
  }
}

///|
fn qbe_emit_term(g : QbeGen, line : String) -> Unit {
  if !g.block_term {
    g.fn_body.write_string("    ")
    g.fn_body.write_string(line)
    g.fn_body.write_string("\n")
    g.block_term = true
  }
}

///|
fn qbe_emit_lbl(g : QbeGen, lbl : String) -> Unit {
  g.fn_body.write_string(lbl)
  g.fn_body.write_string("\n")
  g.block_term = false
  g.block_immut_fields = Map([])
  g.w_to_l_ext = Map([])
  g.local_w_to_l_ext = Map([])
}

///|
fn qbe_alloc_slot(g : QbeGen) -> String {
  let s = qbe_tmp(g)
  g.fn_allocs.write_string("    ")
  g.fn_allocs.write_string(s)
  g.fn_allocs.write_string(" =l alloc8 8\n")
  g.fn_allocs.write_string("    storel 0, ")
  g.fn_allocs.write_string(s)
  g.fn_allocs.write_string("\n")
  s
}

///|
fn qbe_alloc_slot_for(g : QbeGen, ty : Ty) -> String {
  let s = qbe_tmp(g)
  g.fn_allocs.write_string("    ")
  g.fn_allocs.write_string(s)
  if qbe_is_double_ty(ty) {
    g.fn_allocs.write_string(" =l alloc8 8\n")
    g.fn_allocs.write_string("    stored d_0.0, ")
  } else if qbe_is_int32_ty(ty) {
    g.fn_allocs.write_string(" =l alloc4 4\n")
    g.fn_allocs.write_string("    storew 0, ")
  } else {
    g.fn_allocs.write_string(" =l alloc8 8\n")
    g.fn_allocs.write_string("    storel 0, ")
  }
  g.fn_allocs.write_string(s)
  g.fn_allocs.write_string("\n")
  s
}

///|
fn qbe_alloc_slot4(g : QbeGen) -> String {
  let s = qbe_tmp(g)
  g.fn_allocs.write_string("    ")
  g.fn_allocs.write_string(s)
  g.fn_allocs.write_string(" =l alloc4 4\n")
  g.fn_allocs.write_string("    storew 0, ")
  g.fn_allocs.write_string(s)
  g.fn_allocs.write_string("\n")
  s
}

///|
fn qbe_intern_string(g : QbeGen, s : String) -> Int {
  match g.string_ids.get(s) {
    Some(id) => id
    None => {
      let id = g.strings.length()
      g.strings.push(s)
      g.string_ids.set(s, id)
      id
    }
  }
}

///|
fn qbe_intern_cstring(g : QbeGen, s : String) -> Int {
  match g.cstring_ids.get(s) {
    Some(id) => id
    None => {
      let id = g.cstrings.length()
      g.cstrings.push(s)
      g.cstring_ids.set(s, id)
      id
    }
  }
}

///|
fn qbe_register_slot_drop(g : QbeGen, mask : Int) -> String {
  if mask == 0 {
    return "0"
  }
  let key = mask.to_string()
  if !g.slot_drop_seen.contains(key) {
    g.slot_drop_seen.set(key, true)
    g.slot_drop_masks.push(mask)
  }
  "$m2_drop_slots_" + key
}

///|
fn qbe_register_fn_wrapper(g : QbeGen, fname : String) -> String {
  if !g.fn_wrapper_seen.contains(fname) {
    g.fn_wrapper_seen.set(fname, true)
    g.fn_wrappers.push(fname)
  }
  "$m2_wrap_" + fname
}

///|
fn qbe_scope_push(g : QbeGen) -> Unit {
  g.scopes.push(QbeScope::{ locals: [] })
  g.block_immut_fields = Map([])
  g.w_to_l_ext = Map([])
  g.local_w_to_l_ext = Map([])
}

///|
fn qbe_release_scope_locals(g : QbeGen, sc : QbeScope) -> Unit {
  let mut i = sc.locals.length() - 1
  while i >= 0 {
    let loc = sc.locals[i]
    if loc.owned {
      match loc.ty {
        TParam(_) => {
          let v = qbe_tmp(g)
          qbe_emit(g, v + " =l loadl " + loc.slot)
          qbe_rc_dec(g, v, loc.ty)
        }
        _ =>
          if qbe_is_obj_ty(loc.ty) {
            let v = qbe_tmp(g)
            qbe_emit(g, v + " =l loadl " + loc.slot)
            qbe_emit(g, "call $m2_rc_dec(l " + v + ")")
          }
      }
    }
    i = i - 1
  }
}

///|
fn qbe_scope_pop(g : QbeGen) -> Unit {
  if g.scopes.length() > 0 {
    let sc = g.scopes[g.scopes.length() - 1]
    if !g.block_term {
      qbe_release_scope_locals(g, sc)
    }
    let _ = g.scopes.pop()
  }
  g.block_immut_fields = Map([])
  g.w_to_l_ext = Map([])
  g.local_w_to_l_ext = Map([])
}

///|
fn qbe_release_scopes_down_to(g : QbeGen, target_depth : Int) -> Unit {
  let mut i = g.scopes.length() - 1
  while i >= target_depth {
    qbe_release_scope_locals(g, g.scopes[i])
    i = i - 1
  }
}

///|
fn qbe_define_local(
  g : QbeGen,
  name : String,
  ty : Ty,
  owned : Bool,
) -> QbeLocal {
  let slot = qbe_alloc_slot_for(g, ty)
  let loc = QbeLocal::{ name: name, slot: slot, ty: ty, owned: owned }
  let top = g.scopes[g.scopes.length() - 1]
  top.locals.push(loc)
  g.block_immut_fields = Map([])
  g.w_to_l_ext = Map([])
  g.local_w_to_l_ext.remove(name)
  loc
}

///|
fn qbe_lookup_local(g : QbeGen, name : String) -> Option[QbeLocal] {
  let mut si = g.scopes.length() - 1
  while si >= 0 {
    let sc = g.scopes[si]
    let mut li = sc.locals.length() - 1
    while li >= 0 {
      if sc.locals[li].name == name {
        return Some(sc.locals[li])
      }
      li = li - 1
    }
    si = si - 1
  }
  None
}

///|
fn qbe_find_world_slot(g : QbeGen) -> Option[String] {
  let mut si = g.scopes.length() - 1
  while si >= 0 {
    let sc = g.scopes[si]
    let mut li = sc.locals.length() - 1
    while li >= 0 {
      match sc.locals[li].ty {
        TWorld => return Some(sc.locals[li].slot)
        _ => ()
      }
      li = li - 1
    }
    si = si - 1
  }
  None
}

///|
fn qbe_is_obj_flag(g : QbeGen, t : Ty) -> String {
  match t {
    TParam(tn) =>
      if str_arr_contains(g.cur_tparams, tn) {
        "%tp_" + tn
      } else {
        "0"
      }
    _ => if qbe_is_obj_ty(t) { "1" } else { "0" }
  }
}

///|
fn qbe_rc_inc(g : QbeGen, vreg : String, ty : Ty) -> Unit {
  match ty {
    TParam(tn) =>
      if str_arr_contains(g.cur_tparams, tn) {
        let l_do = qbe_lbl(g, "rci_do")
        let l_sk = qbe_lbl(g, "rci_sk")
        qbe_emit_term(g, "jnz %tp_" + tn + ", " + l_do + ", " + l_sk)
        qbe_emit_lbl(g, l_do)
        qbe_emit(g, "call $m2_rc_inc(l " + vreg + ")")
        qbe_emit_term(g, "jmp " + l_sk)
        qbe_emit_lbl(g, l_sk)
      }
    _ =>
      if qbe_is_obj_ty(ty) {
        qbe_emit(g, "call $m2_rc_inc(l " + vreg + ")")
      }
  }
}

///|
fn qbe_rc_dec(g : QbeGen, vreg : String, ty : Ty) -> Unit {
  match ty {
    TParam(tn) =>
      if str_arr_contains(g.cur_tparams, tn) {
        let l_do = qbe_lbl(g, "rcd_do")
        let l_sk = qbe_lbl(g, "rcd_sk")
        qbe_emit_term(g, "jnz %tp_" + tn + ", " + l_do + ", " + l_sk)
        qbe_emit_lbl(g, l_do)
        qbe_emit(g, "call $m2_rc_dec(l " + vreg + ")")
        qbe_emit_term(g, "jmp " + l_sk)
        qbe_emit_lbl(g, l_sk)
      }
    _ =>
      if qbe_is_obj_ty(ty) {
        qbe_emit(g, "call $m2_rc_dec(l " + vreg + ")")
      }
  }
}

///|
fn qbe_parse_int64_lit(raw : String) -> Int64 {
  let mut len = raw.length()
  if len > 0 && str_code_at(raw, len - 1) == 76 {
    len = len - 1
  }
  if len >= 2 &&
    str_code_at(raw, 0) == 48 &&
    (str_code_at(raw, 1) == 120 || str_code_at(raw, 1) == 88) {
    let mut acc = 0L
    let mut i = 2
    while i < len {
      let c = str_code_at(raw, i)
      if c == 95 {
        i = i + 1
        continue
      }
      let d = if c >= 48 && c <= 57 {
        c - 48
      } else if c >= 65 && c <= 70 {
        c - 55
      } else if c >= 97 && c <= 102 {
        c - 87
      } else {
        0
      }
      acc = (acc << 4) | d.to_int64()
      i = i + 1
    }
    acc
  } else {
    let mut acc = 0L
    let mut i = 0
    while i < len {
      let c = str_code_at(raw, i)
      if c >= 48 && c <= 57 {
        acc = acc * 10L + (c - 48).to_int64()
      }
      i = i + 1
    }
    acc
  }
}

///|
fn qbe_hex_val(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 65 && c <= 70 {
    c - 55
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    0
  }
}

///|
fn qbe_parse_char_lit(raw : String) -> Int {
  let len = raw.length()
  if len == 0 {
    return 0
  }
  let c0 = str_code_at(raw, 0)
  if c0 == 92 && len >= 2 {
    let c1 = str_code_at(raw, 1)
    if c1 == 110 {
      10
    } else if c1 == 114 {
      13
    } else if c1 == 116 {
      9
    } else if c1 == 92 {
      92
    } else if c1 == 39 {
      39
    } else if c1 == 34 {
      34
    } else if c1 == 48 {
      0
    } else if c1 == 120 && len >= 4 {
      let h1 = qbe_hex_val(str_code_at(raw, 2))
      let h2 = qbe_hex_val(str_code_at(raw, 3))
      (h1 << 4) | h2
    } else {
      c1
    }
  } else {
    c0
  }
}

///|
fn qbe_emit_none(g : QbeGen) -> String {
  g.need_none_const = true
  let t = qbe_tmp(g)
  qbe_emit(g, t + " =l add $m2_none_hdr, 32")
  t
}

///|
fn qbe_emit_some(g : QbeGen, vreg : String, inner_ty : Ty) -> String {
  let drop_sym = if qbe_is_obj_ty(inner_ty) {
    g.need_drop_opt_obj = true
    "$m2_drop_opt_obj"
  } else {
    "0"
  }
  let obj = qbe_tmp(g)
  qbe_emit(g, obj + " =l call $m2_alloc_uninit(w 16, w 5, l " + drop_sym + ")")
  qbe_emit(g, "storel 1, " + obj)
  let p1 = qbe_tmp(g)
  qbe_emit(g, p1 + " =l add " + obj + ", 8")
  qbe_emit(g, "storel " + vreg + ", " + p1)
  obj
}

///|
fn qbe_result_drop_sym(g : QbeGen, ok_ty : Ty, err_ty : Ty) -> String {
  let ok_obj = qbe_is_obj_ty(ok_ty)
  let err_obj = qbe_is_obj_ty(err_ty)
  if ok_obj && err_obj {
    g.need_drop_res_both = true
    "$m2_drop_res_both"
  } else if ok_obj {
    g.need_drop_res_ok = true
    "$m2_drop_res_ok"
  } else if err_obj {
    g.need_drop_res_err = true
    "$m2_drop_res_err"
  } else {
    "0"
  }
}

///|
fn qbe_emit_result(
  g : QbeGen,
  tag : Int,
  vreg : String,
  ok_ty : Ty,
  err_ty : Ty,
) -> String {
  let drop_sym = qbe_result_drop_sym(g, ok_ty, err_ty)
  let obj = qbe_tmp(g)
  qbe_emit(g, obj + " =l call $m2_alloc_uninit(w 16, w 5, l " + drop_sym + ")")
  qbe_emit(g, "storel " + tag.to_string() + ", " + obj)
  let p1 = qbe_tmp(g)
  qbe_emit(g, p1 + " =l add " + obj + ", 8")
  qbe_emit(g, "storel " + vreg + ", " + p1)
  obj
}

///|
fn qbe_emit_string_lit(g : QbeGen, s : String) -> String {
  let id = qbe_intern_string(g, s)
  let t = qbe_tmp(g)
  qbe_emit(g, t + " =l add $m2_str_" + id.to_string() + "_hdr, 32")
  t
}

///|
fn qbe_emit_closure_call(
  g : QbeGen,
  clo_val : String,
  arg_vals : Array[String],
  arg_tys : Array[Ty],
) -> String {
  let l_args : Array[String] = []
  let mut k = 0
  while k < arg_vals.length() {
    l_args.push(qbe_as_l(g, qval(arg_vals[k], arg_tys[k])))
    k = k + 1
  }
  let fn_ptr = qbe_tmp(g)
  qbe_emit(g, fn_ptr + " =l loadl " + clo_val)
  let res = qbe_tmp(g)
  let sb = StringBuilder()
  sb.write_string(res)
  sb.write_string(" =l call ")
  sb.write_string(fn_ptr)
  sb.write_string("(l ")
  sb.write_string(clo_val)
  let mut i = 0
  while i < l_args.length() {
    sb.write_string(", l ")
    sb.write_string(l_args[i])
    i = i + 1
  }
  sb.write_string(")")
  qbe_emit(g, sb.to_string())
  let mut j = 0
  while j < arg_vals.length() {
    qbe_rc_dec(g, arg_vals[j], arg_tys[j])
    j = j + 1
  }
  qbe_emit(g, "call $m2_rc_dec(l " + clo_val + ")")
  res
}

///|
fn qbe_emit_world_builtin(
  g : QbeGen,
  name : String,
  args : Array[Expr],
) -> QbeVal {
  let can_borrow = !qbe_args_have_assign(args)
  let arg_vals : Array[String] = []
  let arg_tys : Array[Ty] = []
  let arg_borrowed : Array[Bool] = []
  let mut i = 0
  while i < args.length() {
    let av = qbe_emit_arg_maybe_borrow(g, args[i], None, can_borrow)
    arg_vals.push(av.qv.reg)
    arg_tys.push(av.qv.ty)
    arg_borrowed.push(av.borrowed)
    i = i + 1
  }
  let mut has_w = false
  let mut w_val = "0"
  if arg_tys.length() > 0 {
    match arg_tys[0] {
      TWorld => {
        has_w = true
        w_val = arg_vals[0]
      }
      _ => ()
    }
  }
  if !has_w {
    match qbe_find_world_slot(g) {
      Some(ws) => {
        let wt = qbe_tmp(g)
        qbe_emit(g, wt + " =l loadl " + ws)
        w_val = wt
      }
      None => w_val = "0"
    }
  }
  let off = if has_w { 1 } else { 0 }
  let mut res = "0"
  let mut rty = TUnit
  if name == "io_print" {
    let s = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    qbe_emit(g, "call $m2_world_print(l " + w_val + ", l " + s + ")")
    rty = TUnit
  } else if name == "io_println" {
    let s = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    qbe_emit(g, "call $m2_world_println(l " + w_val + ", l " + s + ")")
    rty = TUnit
  } else if name == "io_eprintln" {
    let s = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    qbe_emit(g, "call $m2_world_eprintln(l " + w_val + ", l " + s + ")")
    rty = TUnit
  } else if name == "fs_read" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let ok_slot = qbe_alloc_slot4(g)
    let raw_s = qbe_tmp(g)
    qbe_emit(
      g,
      raw_s +
      " =l call $m2_world_fs_read(l " +
      w_val +
      ", l " +
      p +
      ", l " +
      ok_slot +
      ")",
    )
    let ok_w = qbe_tmp(g)
    qbe_emit(g, ok_w + " =w loadw " + ok_slot)
    let res_slot = qbe_alloc_slot(g)
    let l_ok = qbe_lbl(g, "fsr_ok")
    let l_err = qbe_lbl(g, "fsr_err")
    let l_end = qbe_lbl(g, "fsr_end")
    qbe_emit_term(g, "jnz " + ok_w + ", " + l_ok + ", " + l_err)
    qbe_emit_lbl(g, l_ok)
    let ok_obj = qbe_emit_result(g, 0, raw_s, TString, TString)
    qbe_emit(g, "storel " + ok_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_err)
    qbe_emit(g, "call $m2_rc_dec(l " + raw_s + ")")
    let err_s = qbe_emit_string_lit(g, "fs_read failed")
    let err_obj = qbe_emit_result(g, 1, err_s, TString, TString)
    qbe_emit(g, "storel " + err_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_end)
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l loadl " + res_slot)
    rty = TResult(TString, TString)
  } else if name == "fs_write" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let c = if arg_vals.length() > off + 1 { arg_vals[off + 1] } else { "0" }
    let ok_w = qbe_tmp(g)
    qbe_emit(
      g,
      ok_w + " =w call $m2_world_fs_write(l " + w_val + ", l " + p + ", l " + c + ")",
    )
    let res_slot = qbe_alloc_slot(g)
    let l_ok = qbe_lbl(g, "fsw_ok")
    let l_err = qbe_lbl(g, "fsw_err")
    let l_end = qbe_lbl(g, "fsw_end")
    qbe_emit_term(g, "jnz " + ok_w + ", " + l_ok + ", " + l_err)
    qbe_emit_lbl(g, l_ok)
    let ok_obj = qbe_emit_result(g, 0, "0", TUnit, TString)
    qbe_emit(g, "storel " + ok_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_err)
    let err_s = qbe_emit_string_lit(g, "fs_write failed")
    let err_obj = qbe_emit_result(g, 1, err_s, TUnit, TString)
    qbe_emit(g, "storel " + err_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_end)
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l loadl " + res_slot)
    rty = TResult(TUnit, TString)
  } else if name == "fs_exists" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w call $m2_world_fs_exists(l " + w_val + ", l " + p + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extuw " + rw)
    rty = TBool
  } else if name == "fs_is_dir" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w call $m2_world_fs_is_dir(l " + w_val + ", l " + p + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extuw " + rw)
    rty = TBool
  } else if name == "fs_mkdir_p" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w call $m2_world_fs_mkdir_p(l " + w_val + ", l " + p + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extuw " + rw)
    rty = TBool
  } else if name == "fs_remove" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w call $m2_world_fs_remove(l " + w_val + ", l " + p + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extuw " + rw)
    rty = TBool
  } else if name == "fs_rename" {
    let p1 = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let p2 = if arg_vals.length() > off + 1 { arg_vals[off + 1] } else { "0" }
    let rw = qbe_tmp(g)
    qbe_emit(
      g,
      rw +
      " =w call $m2_world_fs_rename(l " +
      w_val +
      ", l " +
      p1 +
      ", l " +
      p2 +
      ")",
    )
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extuw " + rw)
    rty = TBool
  } else if name == "fs_size" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_fs_size(l " + w_val + ", l " + p + ")")
    rty = TInt64
  } else if name == "fs_list_dir" {
    let p = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_fs_list_dir(l " + w_val + ", l " + p + ")")
    rty = TArray(TString)
  } else if name == "args_get" || name == "world_args" {
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_args(l " + w_val + ")")
    rty = TArray(TString)
  } else if name == "world_argc" {
    let r64 = qbe_tmp(g)
    qbe_emit(g, r64 + " =l call $m2_world_argc(l " + w_val + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =w copy " + r64)
    rty = TInt
  } else if name == "world_argv" {
    let idx = if arg_vals.length() > off {
      qbe_as_l(g, qval(arg_vals[off], arg_tys[off]))
    } else {
      "0"
    }
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_argv(l " + w_val + ", l " + idx + ")")
    rty = TString
  } else if name == "env_get" {
    let k = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    let ok_slot = qbe_alloc_slot4(g)
    let raw_s = qbe_tmp(g)
    qbe_emit(
      g,
      raw_s +
      " =l call $m2_world_env_get(l " +
      w_val +
      ", l " +
      k +
      ", l " +
      ok_slot +
      ")",
    )
    let ok_w = qbe_tmp(g)
    qbe_emit(g, ok_w + " =w loadw " + ok_slot)
    let res_slot = qbe_alloc_slot(g)
    let l_some = qbe_lbl(g, "env_some")
    let l_none = qbe_lbl(g, "env_none")
    let l_end = qbe_lbl(g, "env_end")
    qbe_emit_term(g, "jnz " + ok_w + ", " + l_some + ", " + l_none)
    qbe_emit_lbl(g, l_some)
    let some_obj = qbe_emit_some(g, raw_s, TString)
    qbe_emit(g, "storel " + some_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_none)
    qbe_emit(g, "call $m2_rc_dec(l " + raw_s + ")")
    let none_obj = qbe_emit_none(g)
    qbe_emit(g, "storel " + none_obj + ", " + res_slot)
    qbe_emit_term(g, "jmp " + l_end)
    qbe_emit_lbl(g, l_end)
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l loadl " + res_slot)
    rty = TOption(TString)
  } else if name == "clock_now_ms" {
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_clock_ms(l " + w_val + ")")
    rty = TInt64
  } else if name == "proc_exec" {
    let arr = if arg_vals.length() > off { arg_vals[off] } else { "0" }
    res = qbe_tmp(g)
    qbe_emit(g, res + " =w call $m2_world_exec(l " + w_val + ", l " + arr + ")")
    rty = TInt
  }
  let mut j = 0
  while j < arg_vals.length() {
    if !arg_borrowed[j] {
      qbe_rc_dec(g, arg_vals[j], arg_tys[j])
    }
    j = j + 1
  }
  qval(res, rty)
}

///|
fn qbe_emit_variant_ctor(
  g : QbeGen,
  enum_name : String,
  vname : String,
  args : Array[Expr],
  expected : Option[Ty],
) -> QbeVal {
  if enum_name == "Option" || (enum_name == "" && (vname == "Some" || vname == "None")) {
    let exp_inner : Option[Ty] = match expected {
      Some(TOption(inner)) => Some(inner)
      _ => None
    }
    if vname == "None" {
      let inner_ty = match exp_inner {
        Some(t) => t
        None => TError
      }
      return qval(qbe_emit_none(g), TOption(inner_ty))
    }
    let av = if args.length() >= 1 {
      qbe_emit_expr(g, args[0], exp_inner)
    } else {
      qval("0", TError)
    }
    return qval(qbe_emit_some(g, qbe_as_l(g, av), av.ty), TOption(av.ty))
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
      let av = if args.length() >= 1 {
        qbe_emit_expr(g, args[0], exp_ok)
      } else {
        qval("0", TError)
      }
      let ety = match exp_err {
        Some(e) => e
        None => TError
      }
      return qval(qbe_emit_result(g, 0, qbe_as_l(g, av), av.ty, ety), TResult(av.ty, ety))
    } else {
      let av = if args.length() >= 1 {
        qbe_emit_expr(g, args[0], exp_err)
      } else {
        qval("0", TError)
      }
      let oty = match exp_ok {
        Some(o) => o
        None => TError
      }
      return qval(qbe_emit_result(g, 1, qbe_as_l(g, av), oty, av.ty), TResult(oty, av.ty))
    }
  }
  let resolved_enum = if enum_name != "" {
    enum_name
  } else {
    match g.tc.variant_to_enum.get(vname) {
      Some(en) => en
      None => ""
    }
  }
  match g.tc.enums.get(resolved_enum) {
    None => qval("0", TError)
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
      let mut tag = 0
      let arg_vals : Array[String] = []
      let arg_tys : Array[Ty] = []
      let mut vi = 0
      while vi < einfo.variants.length() {
        let v = einfo.variants[vi]
        if v.name == vname {
          tag = vi
          let mut fi = 0
          while fi < args.length() {
            let exp_f : Option[Ty] = if fi < v.field_tys.length() {
              Some(subst_ty(v.field_tys[fi], subst))
            } else {
              None
            }
            let av = qbe_emit_expr(g, args[fi], exp_f)
            if fi < v.field_tys.length() {
              unify_tparams(v.field_tys[fi], av.ty, subst)
            }
            arg_vals.push(av.reg)
            arg_tys.push(av.ty)
            fi = fi + 1
          }
          break
        }
        vi = vi + 1
      }
      if arg_vals.length() == 0 {
        let sym = qbe_register_enum_const(g, resolved_enum, vname, tag)
        let obj = qbe_tmp(g)
        qbe_emit(g, obj + " =l add " + sym + ", 32")
        let targs : Array[Ty] = []
        let mut ti = 0
        while ti < einfo.decl.type_params.length() {
          match subst.get(einfo.decl.type_params[ti]) {
            Some(t) => targs.push(t)
            None => targs.push(TError)
          }
          ti = ti + 1
        }
        return qval(obj, TEnum(resolved_enum, targs))
      }
      let payload_sz = (1 + arg_vals.length()) * 8
      let drop_sym = if einfo.decl.type_params.length() == 0 {
        if has_qual_sep(resolved_enum) && !str_arr_contains(g.enum_order, resolved_enum) {
          g.enum_order.push(resolved_enum)
        }
        "$m2_drop_enum_" + qbe_sanitize_sym(resolved_enum)
      } else {
        let mut mask = 0
        let mut fi = 0
        while fi < arg_tys.length() {
          if qbe_is_obj_ty(arg_tys[fi]) {
            mask = mask | (1 << (fi + 1))
          }
          fi = fi + 1
        }
        qbe_register_slot_drop(g, mask)
      }
      let obj = qbe_tmp(g)
      qbe_emit(
        g,
        obj +
        " =l call $m2_alloc_uninit(w " +
        payload_sz.to_string() +
        ", w 5, l " +
        drop_sym +
        ")",
      )
      qbe_emit(g, "storel " + tag.to_string() + ", " + obj)
      let mut fi = 0
      while fi < arg_vals.length() {
        let off = (fi + 1) * 8
        let p = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + obj + ", " + off.to_string())
        qbe_store_heap_slot(g, arg_vals[fi], p, arg_tys[fi])
        fi = fi + 1
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
      qval(obj, TEnum(resolved_enum, targs))
    }
  }
}

///|
fn qbe_emit_closure_obj(
  g : QbeGen,
  params : Array[Param],
  ret_te : TypeExpr,
  body : Array[Stmt],
  is_spawn : Bool,
) -> QbeCloRes {
  let locals : Map[String, Bool] = Map([])
  let mut pi = 0
  while pi < params.length() {
    locals.set(params[pi].name, true)
    pi = pi + 1
  }
  let raw_caps : Array[CaptureInfo] = []
  collect_stmts_captures(body, locals, raw_caps)
  let cap_locals : Array[QbeLocal] = []
  let seen : Map[String, Bool] = Map([])
  let mut ci = 0
  while ci < raw_caps.length() {
    let cname = raw_caps[ci].name
    if !seen.contains(cname) {
      match qbe_lookup_local(g, cname) {
        Some(loc) => {
          seen.set(cname, true)
          cap_locals.push(loc)
        }
        None => ()
      }
    }
    ci = ci + 1
  }

  let clo_id = g.next_clo
  g.next_clo = clo_id + 1
  let fn_sym = if is_spawn {
    "$m2_spawn_" + clo_id.to_string()
  } else {
    "$m2_clo_" + clo_id.to_string()
  }

  let ptys : Array[Ty] = []
  pi = 0
  while pi < params.length() {
    let pty = match params[pi].ty {
      TyMissing(_) => TError
      _ => resolve_type_expr(g.tc, params[pi].ty, g.cur_tparams)
    }
    ptys.push(pty)
    pi = pi + 1
  }
  let ret_ty = match ret_te {
    TyMissing(_) => TUnit
    _ => resolve_type_expr(g.tc, ret_te, g.cur_tparams)
  }

  let n_slots = 1 + cap_locals.length()
  let mut drop_mask = 0
  let mut mi = 0
  while mi < cap_locals.length() {
    if qbe_is_obj_ty(cap_locals[mi].ty) {
      drop_mask = drop_mask | (1 << (mi + 1))
    }
    mi = mi + 1
  }
  let drop_sym = qbe_register_slot_drop(g, drop_mask)
  let env_obj = qbe_tmp(g)
  qbe_emit(
    g,
    env_obj +
    " =l call $m2_alloc_uninit(w " +
    (n_slots * 8).to_string() +
    ", w 6, l " +
    drop_sym +
    ")",
  )
  qbe_emit(g, "storel " + fn_sym + ", " + env_obj)
  let mut ki = 0
  while ki < cap_locals.length() {
    let loc = cap_locals[ki]
    let dv = qbe_load_local_slot(g, loc.slot, loc.ty)
    let v = qbe_as_l(g, qval(dv, loc.ty))
    if qbe_is_obj_ty(loc.ty) {
      if is_spawn {
        qbe_emit(g, "call $m2_rc_freeze(l " + v + ")")
      }
      qbe_emit(g, "call $m2_rc_inc(l " + v + ")")
    }
    let off = (ki + 1) * 8
    let p = qbe_tmp(g)
    qbe_emit(g, p + " =l add " + env_obj + ", " + off.to_string())
    qbe_emit(g, "storel " + v + ", " + p)
    ki = ki + 1
  }

  let saved_allocs = g.fn_allocs
  let saved_body = g.fn_body
  let saved_scopes = g.scopes
  let saved_breaks = g.loop_breaks
  let saved_conts = g.loop_conts
  let saved_depths = g.loop_depths
  let saved_ret = g.cur_ret_ty
  let saved_ret_abi = g.cur_ret_abi_ty
  let saved_term = g.block_term
  let saved_hlen = g.hoisted_arr_len
  let saved_hdp = g.hoisted_arr_dp
  let saved_hfields = g.hoisted_fields
  let saved_bfields = g.block_immut_fields
  let saved_lalias = g.len_aliases
  let saved_lkeys = g.len_alias_keys
  let saved_nonneg = g.nonneg_vars
  let saved_bce = g.bce_safe_indices
  let saved_bce_exprs = g.bce_safe_exprs
  let saved_sq_slot = g.sq_reuse_slot
  let saved_sq_state = g.sq_reuse_state
  let saved_prom = g.promoted_fields
  let saved_prom_tys = g.promoted_field_tys
  let saved_w2l = g.w_to_l_ext
  let saved_local_w2l = g.local_w_to_l_ext

  g.fn_allocs = StringBuilder()
  g.fn_body = StringBuilder()
  g.scopes = []
  g.loop_breaks = []
  g.loop_conts = []
  g.loop_depths = []
  g.cur_ret_ty = ret_ty
  g.cur_ret_abi_ty = TInt64
  g.block_term = false
  g.hoisted_arr_len = Map([])
  g.hoisted_arr_dp = Map([])
  g.hoisted_fields = Map([])
  g.block_immut_fields = Map([])
  g.len_aliases = Map([])
  g.len_alias_keys = []
  g.nonneg_vars = Map([])
  g.bce_safe_indices = Map([])
  g.bce_safe_exprs = Map([])
  g.sq_reuse_slot = Map([])
  g.sq_reuse_state = Map([])
  g.promoted_fields = Map([])
  g.promoted_field_tys = Map([])
  g.w_to_l_ext = Map([])
  g.local_w_to_l_ext = Map([])

  qbe_scope_push(g)
  ki = 0
  while ki < cap_locals.length() {
    let cap = cap_locals[ki]
    let loc = qbe_define_local(g, cap.name, cap.ty, false)
    let off = (ki + 1) * 8
    let p = qbe_tmp(g)
    qbe_emit(g, p + " =l add %env, " + off.to_string())
    let v = qbe_load_heap_slot(g, p, cap.ty)
    qbe_store_local_slot(g, v, loc.slot, cap.ty)
    ki = ki + 1
  }
  pi = 0
  while pi < params.length() {
    let loc = qbe_define_local(g, params[pi].name, ptys[pi], false)
    let pv = qbe_from_l(g, "%p" + pi.to_string(), ptys[pi])
    qbe_store_local_slot(g, pv, loc.slot, ptys[pi])
    pi = pi + 1
  }

  let bres = qbe_emit_stmts(g, body, Some(ret_ty))
  let actual_ret = match ret_te {
    TyMissing(_) => bres.ty
    _ => ret_ty
  }
  if !g.block_term {
    if is_spawn {
      qbe_rc_dec(g, bres.reg, bres.ty)
      qbe_scope_pop(g)
      qbe_emit_term(g, "ret")
    } else {
      let ret_l = qbe_as_l(g, bres)
      qbe_scope_pop(g)
      qbe_emit_term(g, "ret " + ret_l)
    }
  } else {
    let _ = g.scopes.pop()
  }

  let hdr = StringBuilder()
  if is_spawn {
    hdr.write_string("function ")
    hdr.write_string(fn_sym)
    hdr.write_string("(l %env) {\n@start\n")
  } else {
    hdr.write_string("function l ")
    hdr.write_string(fn_sym)
    hdr.write_string("(l %env")
    pi = 0
    while pi < params.length() {
      hdr.write_string(", l %p")
      hdr.write_string(pi.to_string())
      pi = pi + 1
    }
    hdr.write_string(") {\n@start\n")
  }
  hdr.write_string(g.fn_allocs.to_string())
  hdr.write_string(g.fn_body.to_string())
  hdr.write_string("}\n\n")
  g.extra_fns.push(hdr.to_string())

  g.fn_allocs = saved_allocs
  g.fn_body = saved_body
  g.scopes = saved_scopes
  g.loop_breaks = saved_breaks
  g.loop_conts = saved_conts
  g.loop_depths = saved_depths
  g.cur_ret_ty = saved_ret
  g.cur_ret_abi_ty = saved_ret_abi
  g.block_term = saved_term
  g.hoisted_arr_len = saved_hlen
  g.hoisted_arr_dp = saved_hdp
  g.hoisted_fields = saved_hfields
  g.block_immut_fields = saved_bfields
  g.len_aliases = saved_lalias
  g.len_alias_keys = saved_lkeys
  g.nonneg_vars = saved_nonneg
  g.bce_safe_indices = saved_bce
  g.bce_safe_exprs = saved_bce_exprs
  g.sq_reuse_slot = saved_sq_slot
  g.sq_reuse_state = saved_sq_state
  g.promoted_fields = saved_prom
  g.promoted_field_tys = saved_prom_tys
  g.w_to_l_ext = saved_w2l
  g.local_w_to_l_ext = saved_local_w2l

  QbeCloRes::{ env: env_obj, fn_sym: fn_sym, ty: TFn(ptys, actual_ret) }
}

///|
fn qbe_emit_method_call(
  g : QbeGen,
  obj_expr : Expr,
  method_name : String,
  args : Array[Expr],
  expected : Option[Ty],
) -> QbeVal {
  // Fast zero-RC borrow path for `local.length()` on String / Array
  if method_name == "length" && args.length() == 0 {
    match obj_expr {
      EIdent(lname, _) =>
        match qbe_lookup_local(g, lname) {
          Some(loc) =>
            match loc.ty {
              TString | TArray(_) => {
                let r64 = match g.hoisted_arr_len.get(lname) {
                  Some(hlen) => hlen
                  None => {
                    let obj_p = qbe_tmp(g)
                    let t64 = qbe_tmp(g)
                    qbe_emit(g, obj_p + " =l loadl " + loc.slot)
                    qbe_emit(g, t64 + " =l loadl " + obj_p)
                    t64
                  }
                }
                let rw = qbe_tmp(g)
                qbe_emit(g, rw + " =w copy " + r64)
                return qval(rw, TInt)
              }
              _ => ()
            }
          None => ()
        }
      _ => ()
    }
  }
  // Invalidate length aliases if array is mutated via push/pop
  if method_name == "push" || method_name == "pop" {
    match obj_expr {
      EIdent(lname, _) => qbe_invalidate_len_aliases_for(g, lname)
      _ => ()
    }
  }
  let args_pure = !qbe_args_have_assign(args)
  let can_borrow_obj = args_pure && method_name != "to_string"
  let obj_av = qbe_emit_arg_maybe_borrow(g, obj_expr, None, can_borrow_obj)
  let obj_val = obj_av.qv.reg
  let recv_ty = obj_av.qv.ty
  let obj_borrowed = obj_av.borrowed
  match recv_ty {
    TInt => {
      if method_name == "to_string" {
        let v64 = qbe_as_l(g, qval(obj_val, TInt))
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_int_to_str(l " + v64 + ")")
        return qval(r, TString)
      }
      if method_name == "to_int64" {
        return qval(qbe_as_l(g, qval(obj_val, TInt)), TInt64)
      }
      if method_name == "to_int" {
        return qval(obj_val, TInt)
      }
      if method_name == "unsafe_to_char" {
        return qval(qbe_as_l(g, qval(obj_val, TInt)), TChar)
      }
      if method_name == "to_byte" {
        let v64 = qbe_as_l(g, qval(obj_val, TInt))
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l and " + v64 + ", 255")
        return qval(r, TByte)
      }
    }
    TInt64 => {
      if method_name == "to_string" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_int_to_str(l " + obj_val + ")")
        return qval(r, TString)
      }
      if method_name == "to_int" {
        let w = qbe_tmp(g)
        qbe_emit(g, w + " =w copy " + obj_val)
        return qval(w, TInt)
      }
      if method_name == "to_int64" {
        return qval(obj_val, TInt64)
      }
    }
    TDouble => {
      if method_name == "to_int" {
        let w = qbe_tmp(g)
        qbe_emit(g, w + " =w dtosi " + obj_val)
        return qval(w, TInt)
      }
    }
    TBool =>
      if method_name == "to_string" {
        let res_slot = qbe_alloc_slot(g)
        let l_t = qbe_lbl(g, "bstr_t")
        let l_f = qbe_lbl(g, "bstr_f")
        let l_e = qbe_lbl(g, "bstr_e")
        qbe_emit_term(g, "jnz " + obj_val + ", " + l_t + ", " + l_f)
        qbe_emit_lbl(g, l_t)
        let st = qbe_emit_string_lit(g, "true")
        qbe_emit(g, "storel " + st + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_e)
        qbe_emit_lbl(g, l_f)
        let sf = qbe_emit_string_lit(g, "false")
        qbe_emit(g, "storel " + sf + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_e)
        qbe_emit_lbl(g, l_e)
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TString)
      }
    TChar => {
      if method_name == "to_int" {
        let w = qbe_tmp(g)
        qbe_emit(g, w + " =w copy " + obj_val)
        return qval(w, TInt)
      }
      if method_name == "to_string" {
        let sb = qbe_tmp(g)
        let cw = qbe_tmp(g)
        let s = qbe_tmp(g)
        qbe_emit(g, sb + " =l call $m2_strbuf_new(l 4)")
        qbe_emit(g, cw + " =w copy " + obj_val)
        qbe_emit(g, "call $m2_strbuf_push_char(l " + sb + ", w " + cw + ")")
        qbe_emit(g, s + " =l call $m2_strbuf_to_str(l " + sb + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + sb + ")")
        return qval(s, TString)
      }
    }
    TByte =>
      if method_name == "to_int" {
        let w = qbe_tmp(g)
        qbe_emit(g, w + " =w copy " + obj_val)
        return qval(w, TInt)
      }
    TString => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        qbe_emit(g, r64 + " =l loadl " + obj_val)
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, rw + " =w copy " + r64)
        return qval(rw, TInt)
      }
      if method_name == "to_string" {
        return qval(obj_val, TString)
      }
      if method_name == "code_unit_at" {
        let iv = qbe_emit_expr(g, args[0], Some(TInt))
        let il = qbe_as_l(g, iv)
        let bw = qbe_tmp(g)
        qbe_emit(g, bw + " =w call $m2_str_byte_at(l " + obj_val + ", l " + il + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(bw, TInt)
      }
      if method_name == "slice" {
        let a = qbe_emit_expr(g, args[0], Some(TInt))
        let b = qbe_emit_expr(g, args[1], Some(TInt))
        let al = qbe_as_l(g, a)
        let bl = qbe_as_l(g, b)
        let r = qbe_tmp(g)
        qbe_emit(
          g,
          r + " =l call $m2_str_slice(l " + obj_val + ", l " + al + ", l " + bl + ")",
        )
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(r, TString)
      }
    }
    TStringBuilder => {
      if method_name == "write_string" {
        let sa = qbe_emit_arg_maybe_borrow(g, args[0], Some(TString), args_pure)
        let sv = sa.qv
        qbe_emit(g, "call $m2_strbuf_push_str(l " + obj_val + ", l " + sv.reg + ")")
        if !sa.borrowed {
          qbe_rc_dec(g, sv.reg, sv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "write_char" {
        let cv = qbe_emit_expr(g, args[0], Some(TChar))
        let cw = qbe_tmp(g)
        qbe_emit(g, cw + " =w copy " + cv.reg)
        qbe_emit(g, "call $m2_strbuf_push_char(l " + obj_val + ", w " + cw + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "to_string" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_strbuf_to_str(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(r, TString)
      }
      if method_name == "reset" {
        qbe_emit(g, "call $m2_strbuf_reset(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
    }
    TArray(elem) => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        qbe_emit(g, r64 + " =l loadl " + obj_val)
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, rw + " =w copy " + r64)
        return qval(rw, TInt)
      }
      if method_name == "push" {
        let va = qbe_emit_arg_maybe_borrow(g, args[0], Some(elem), args_pure)
        let vv = va.qv
        let vl = qbe_as_l(g, vv)
        qbe_emit(g, "call $m2_arr_push(l " + obj_val + ", l " + vl + ")")
        if !va.borrowed {
          qbe_rc_dec(g, vv.reg, vv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "pop" {
        let n = qbe_tmp(g)
        qbe_emit(g, n + " =l loadl " + obj_val)
        let res_slot = qbe_alloc_slot(g)
        let l_some = qbe_lbl(g, "pop_some")
        let l_none = qbe_lbl(g, "pop_none")
        let l_end = qbe_lbl(g, "pop_end")
        qbe_emit_term(g, "jnz " + n + ", " + l_some + ", " + l_none)
        qbe_emit_lbl(g, l_some)
        let pv = qbe_tmp(g)
        qbe_emit(g, pv + " =l call $m2_arr_pop(l " + obj_val + ")")
        let some_obj = qbe_emit_some(g, pv, elem)
        qbe_emit(g, "storel " + some_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_none)
        let none_obj = qbe_emit_none(g)
        qbe_emit(g, "storel " + none_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(elem))
      }
      if method_name == "copy" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_arr_copy(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(r, TArray(elem))
      }
    }
    TMap(kty, vty) => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_map_len(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, rw + " =w copy " + r64)
        return qval(rw, TInt)
      }
      if method_name == "set" {
        let ka = qbe_emit_arg_maybe_borrow(g, args[0], Some(kty), args_pure)
        let va = qbe_emit_arg_maybe_borrow(g, args[1], Some(vty), args_pure)
        let kv = ka.qv
        let vv = va.qv
        let vl = qbe_as_l(g, vv)
        qbe_emit(
          g,
          "call $m2_map_set(l " + obj_val + ", l " + kv.reg + ", l " + vl + ")",
        )
        if !ka.borrowed {
          qbe_rc_dec(g, kv.reg, kv.ty)
        }
        if !va.borrowed {
          qbe_rc_dec(g, vv.reg, vv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "contains" {
        let ka = qbe_emit_arg_maybe_borrow(g, args[0], Some(kty), args_pure)
        let kv = ka.qv
        let hw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, hw + " =w call $m2_map_has(l " + obj_val + ", l " + kv.reg + ")")
        if !ka.borrowed {
          qbe_rc_dec(g, kv.reg, kv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, r + " =l extuw " + hw)
        return qval(r, TBool)
      }
      if method_name == "remove" {
        let ka = qbe_emit_arg_maybe_borrow(g, args[0], Some(kty), args_pure)
        let kv = ka.qv
        qbe_emit(g, "call $m2_map_remove(l " + obj_val + ", l " + kv.reg + ")")
        if !ka.borrowed {
          qbe_rc_dec(g, kv.reg, kv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "get" {
        let ka = qbe_emit_arg_maybe_borrow(g, args[0], Some(kty), args_pure)
        let kv = ka.qv
        let out_slot = qbe_alloc_slot(g)
        let hw = qbe_tmp(g)
        qbe_emit(
          g,
          hw +
          " =w call $m2_map_try_get(l " +
          obj_val +
          ", l " +
          kv.reg +
          ", l " +
          out_slot +
          ")",
        )
        let res_slot = qbe_alloc_slot(g)
        let l_hit = qbe_lbl(g, "mget_hit")
        let l_miss = qbe_lbl(g, "mget_miss")
        let l_end = qbe_lbl(g, "mget_end")
        qbe_emit_term(g, "jnz " + hw + ", " + l_hit + ", " + l_miss)
        qbe_emit_lbl(g, l_hit)
        let mv = qbe_tmp(g)
        qbe_emit(g, mv + " =l loadl " + out_slot)
        qbe_rc_inc(g, mv, vty)
        let some_obj = qbe_emit_some(g, mv, vty)
        qbe_emit(g, "storel " + some_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_miss)
        let none_obj = qbe_emit_none(g)
        qbe_emit(g, "storel " + none_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        if !ka.borrowed {
          qbe_rc_dec(g, kv.reg, kv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(vty))
      }
      if method_name == "copy" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_map_copy(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(r, TMap(kty, vty))
      }
      if method_name == "keys" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_map_keys(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(r, TArray(kty))
      }
    }
    TChannel(elem) => {
      if method_name == "send" {
        let va = qbe_emit_arg_maybe_borrow(g, args[0], Some(elem), args_pure)
        let vv = va.qv
        let vl = qbe_as_l(g, vv)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, rw + " =w call $m2_chan_send(l " + obj_val + ", l " + vl + ")")
        if !va.borrowed {
          qbe_rc_dec(g, vv.reg, vv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, r + " =l extuw " + rw)
        return qval(r, TBool)
      }
      if method_name == "recv" {
        let out_slot = qbe_alloc_slot(g)
        let ok_w = qbe_tmp(g)
        qbe_emit(
          g,
          ok_w + " =w call $m2_chan_recv(l " + obj_val + ", l " + out_slot + ")",
        )
        let res_slot = qbe_alloc_slot(g)
        let l_some = qbe_lbl(g, "crecv_some")
        let l_none = qbe_lbl(g, "crecv_none")
        let l_end = qbe_lbl(g, "crecv_end")
        qbe_emit_term(g, "jnz " + ok_w + ", " + l_some + ", " + l_none)
        qbe_emit_lbl(g, l_some)
        let rv = qbe_tmp(g)
        qbe_emit(g, rv + " =l loadl " + out_slot)
        let some_obj = qbe_emit_some(g, rv, elem)
        qbe_emit(g, "storel " + some_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_none)
        let none_obj = qbe_emit_none(g)
        qbe_emit(g, "storel " + none_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(elem))
      }
      if method_name == "close" {
        qbe_emit(g, "call $m2_chan_close(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
    }
    TMutex(elem) => {
      if method_name == "lock" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_mutex_lock(l " + obj_val + ")")
        qbe_rc_inc(g, r, elem)
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval(qbe_from_l(g, r, elem), elem)
      }
      if method_name == "set" {
        let va = qbe_emit_arg_maybe_borrow(g, args[0], Some(elem), args_pure)
        let vv = va.qv
        let vl = qbe_as_l(g, vv)
        qbe_emit(g, "call $m2_mutex_set(l " + obj_val + ", l " + vl + ")")
        if !va.borrowed {
          qbe_rc_dec(g, vv.reg, vv.ty)
        }
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "unlock" {
        qbe_emit(g, "call $m2_mutex_unlock(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "with_lock" {
        let fv = qbe_emit_expr(g, args[0], None)
        let cur_v = qbe_tmp(g)
        qbe_emit(g, cur_v + " =l call $m2_mutex_lock(l " + obj_val + ")")
        qbe_rc_inc(g, cur_v, elem)
        let cur_typed = qbe_from_l(g, cur_v, elem)
        let r = qbe_emit_closure_call(g, fv.reg, [cur_typed], [elem])
        qbe_emit(g, "call $m2_mutex_unlock(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        let rty = match fv.ty {
          TFn(_, rt) => rt
          _ =>
            match expected {
              Some(t) => t
              None => TUnit
            }
        }
        return qval(qbe_from_l(g, r, rty), rty)
      }
    }
    TAtomicInt => {
      if method_name == "load" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_atomic_load(l " + obj_val + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, rw + " =w copy " + r64)
        return qval(rw, TInt)
      }
      if method_name == "store" {
        let vv = qbe_emit_expr(g, args[0], Some(TInt))
        let vl = qbe_as_l(g, vv)
        qbe_emit(g, "call $m2_atomic_store(l " + obj_val + ", l " + vl + ")")
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        return qval("0", TUnit)
      }
      if method_name == "fetch_add" {
        let dv = qbe_emit_expr(g, args[0], Some(TInt))
        let dl = qbe_as_l(g, dv)
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        qbe_emit(
          g,
          r64 + " =l call $m2_atomic_fetch_add(l " + obj_val + ", l " + dl + ")",
        )
        if !obj_borrowed {
          qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        }
        qbe_emit(g, rw + " =w copy " + r64)
        return qval(rw, TInt)
      }
    }
    TStruct(sname, sargs) => {
      let key = sname + "::" + method_name
      match g.tc.methods.get(key) {
        Some(minfo) => {
          let subst = make_subst(minfo.decl.type_params, sargs)
          match expected {
            Some(et) => unify_tparams(minfo.ret_ty, et, subst)
            None => ()
          }
          let arg_vals : Array[String] = [obj_val]
          let arg_tys : Array[Ty] = [recv_ty]
          let arg_borrowed : Array[Bool] = [obj_borrowed]
          let mut i = 0
          while i < args.length() {
            let p_idx = i + 1
            let exp_p : Option[Ty] = if p_idx < minfo.param_tys.length() {
              Some(subst_ty(minfo.param_tys[p_idx], subst))
            } else {
              None
            }
            let aa = qbe_emit_arg_maybe_borrow(g, args[i], exp_p, args_pure)
            let av = aa.qv
            if p_idx < minfo.param_tys.length() {
              unify_tparams(minfo.param_tys[p_idx], av.ty, subst)
            }
            arg_vals.push(av.reg)
            arg_tys.push(av.ty)
            arg_borrowed.push(aa.borrowed)
            i = i + 1
          }
          let call_args : Array[String] = []
          let call_abis : Array[String] = []
          let mut j = 0
          while j < arg_vals.length() {
            let decl_pty = if j < minfo.param_tys.length() {
              minfo.param_tys[j]
            } else {
              arg_tys[j]
            }
            call_args.push(qbe_coerce_val(g, qval(arg_vals[j], arg_tys[j]), decl_pty))
            call_abis.push(qbe_abi_ty(decl_pty))
            j = j + 1
          }
          let ret_abi = qbe_abi_ty(minfo.ret_ty)
          let res = qbe_tmp(g)
          let sb = StringBuilder()
          sb.write_string(res)
          sb.write_string(" =")
          sb.write_string(ret_abi)
          sb.write_string(" call ")
          sb.write_string(qbe_method_call_sym(g, sname, method_name))
          sb.write_string("(")
          j = 0
          while j < call_args.length() {
            if j > 0 {
              sb.write_string(", ")
            }
            sb.write_string(call_abis[j])
            sb.write_string(" ")
            sb.write_string(call_args[j])
            j = j + 1
          }
          let mut tpi = 0
          while tpi < minfo.decl.type_params.length() {
            if call_args.length() > 0 || tpi > 0 {
              sb.write_string(", ")
            }
            let tp_ty = match subst.get(minfo.decl.type_params[tpi]) {
              Some(t) => t
              None => TError
            }
            sb.write_string("l ")
            sb.write_string(qbe_is_obj_flag(g, tp_ty))
            tpi = tpi + 1
          }
          sb.write_string(")")
          qbe_emit(g, sb.to_string())
          j = 0
          while j < arg_vals.length() {
            if !arg_borrowed[j] {
              qbe_rc_dec(g, arg_vals[j], arg_tys[j])
            }
            j = j + 1
          }
          let concrete_ret = subst_ty(minfo.ret_ty, subst)
          let final_res = qbe_coerce_val(g, qval(res, minfo.ret_ty), concrete_ret)
          return qval(final_res, concrete_ret)
        }
        None => ()
      }
    }
    _ => ()
  }
  if !obj_borrowed {
    qbe_rc_dec(g, obj_val, recv_ty)
  }
  qval("0", TError)
}

///|
fn qbe_emit_pat_test(
  g : QbeGen,
  pat : Pattern,
  vreg : String,
  scrut_ty : Ty,
  fail_lbl : String,
) -> Unit {
  match pat {
    PWild(_) | PIdent(_, _) => ()
    PBool(b, _) => {
      let bv = if b { "1" } else { "0" }
      let eq = qbe_tmp(g)
      let ok_lbl = qbe_lbl(g, "pat_ok")
      qbe_emit(g, eq + " =w ceql " + vreg + ", " + bv)
      qbe_emit_term(g, "jnz " + eq + ", " + ok_lbl + ", " + fail_lbl)
      qbe_emit_lbl(g, ok_lbl)
    }
    PInt(raw, _) => {
      let iv = qbe_parse_int64_lit(raw)
      let eq = qbe_tmp(g)
      let ok_lbl = qbe_lbl(g, "pat_ok")
      if qbe_is_int32_ty(scrut_ty) {
        let v32 = iv.to_int().to_int64().to_string()
        qbe_emit(g, eq + " =w ceqw " + vreg + ", " + v32)
      } else {
        qbe_emit(g, eq + " =w ceql " + vreg + ", " + iv.to_string())
      }
      qbe_emit_term(g, "jnz " + eq + ", " + ok_lbl + ", " + fail_lbl)
      qbe_emit_lbl(g, ok_lbl)
    }
    PChar(raw, _) => {
      let cv = qbe_parse_char_lit(raw)
      let eq = qbe_tmp(g)
      let ok_lbl = qbe_lbl(g, "pat_ok")
      qbe_emit(g, eq + " =w ceql " + vreg + ", " + cv.to_string())
      qbe_emit_term(g, "jnz " + eq + ", " + ok_lbl + ", " + fail_lbl)
      qbe_emit_lbl(g, ok_lbl)
    }
    PString(s, _) => {
      let lit = qbe_emit_string_lit(g, s)
      let eq = qbe_tmp(g)
      let ok_lbl = qbe_lbl(g, "pat_ok")
      qbe_emit(g, eq + " =w call $m2_str_eq(l " + vreg + ", l " + lit + ")")
      qbe_emit_term(g, "jnz " + eq + ", " + ok_lbl + ", " + fail_lbl)
      qbe_emit_lbl(g, ok_lbl)
    }
    PTuple(subs, _) =>
      match scrut_ty {
        TTuple(elems) => {
          let mut i = 0
          while i < subs.length() && i < elems.length() {
            let p = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + vreg + ", " + (i * 8).to_string())
            let fv = qbe_load_heap_slot(g, p, elems[i])
            qbe_emit_pat_test(g, subs[i], fv, elems[i], fail_lbl)
            i = i + 1
          }
        }
        _ => ()
      }
    PVariant(_, vname, subs, _) => {
      let mut tag = 0
      let field_tys : Array[Ty] = []
      match scrut_ty {
        TOption(inner) =>
          if vname == "None" {
            tag = 0
          } else {
            tag = 1
            field_tys.push(inner)
          }
        TResult(ok, err) =>
          if vname == "Ok" {
            tag = 0
            field_tys.push(ok)
          } else {
            tag = 1
            field_tys.push(err)
          }
        TEnum(ename, eargs) =>
          match g.tc.enums.get(ename) {
            Some(einfo) => {
              let subst = make_subst(einfo.decl.type_params, eargs)
              let mut vi = 0
              while vi < einfo.variants.length() {
                let v = einfo.variants[vi]
                if v.name == vname {
                  tag = vi
                  let mut fi = 0
                  while fi < v.field_tys.length() {
                    field_tys.push(subst_ty(v.field_tys[fi], subst))
                    fi = fi + 1
                  }
                  break
                }
                vi = vi + 1
              }
            }
            None => ()
          }
        _ => ()
      }
      let actual_tag = qbe_tmp(g)
      let eq = qbe_tmp(g)
      let ok_lbl = qbe_lbl(g, "tag_ok")
      qbe_emit(g, actual_tag + " =l loadl " + vreg)
      qbe_emit(g, eq + " =w ceql " + actual_tag + ", " + tag.to_string())
      qbe_emit_term(g, "jnz " + eq + ", " + ok_lbl + ", " + fail_lbl)
      qbe_emit_lbl(g, ok_lbl)
      let mut fi = 0
      while fi < subs.length() && fi < field_tys.length() {
        let p = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + vreg + ", " + ((fi + 1) * 8).to_string())
        let fv = qbe_load_heap_slot(g, p, field_tys[fi])
        qbe_emit_pat_test(g, subs[fi], fv, field_tys[fi], fail_lbl)
        fi = fi + 1
      }
    }
  }
}

///|
fn qbe_emit_pat_bind(
  g : QbeGen,
  pat : Pattern,
  vreg : String,
  scrut_ty : Ty,
  allow_borrow : Bool,
  arm_body : Expr,
) -> Unit {
  match pat {
    PWild(_) | PBool(_, _) | PInt(_, _) | PString(_, _) | PChar(_, _) => ()
    PIdent(name, _) => {
      let borrow_this = allow_borrow &&
        qbe_is_obj_ty(scrut_ty) &&
        qbe_ident_is_borrow_safe_expr(g, arm_body, name)
      if !borrow_this {
        qbe_rc_inc(g, vreg, scrut_ty)
      }
      let loc = qbe_define_local(g, name, scrut_ty, !borrow_this)
      qbe_store_local_slot(g, vreg, loc.slot, scrut_ty)
    }
    PTuple(subs, _) =>
      match scrut_ty {
        TTuple(elems) => {
          let mut i = 0
          while i < subs.length() && i < elems.length() {
            let p = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + vreg + ", " + (i * 8).to_string())
            let fv = qbe_load_heap_slot(g, p, elems[i])
            qbe_emit_pat_bind(g, subs[i], fv, elems[i], allow_borrow, arm_body)
            i = i + 1
          }
        }
        _ => ()
      }
    PVariant(_, vname, subs, _) => {
      let field_tys : Array[Ty] = []
      match scrut_ty {
        TOption(inner) =>
          if vname == "Some" {
            field_tys.push(inner)
          }
        TResult(ok, err) =>
          if vname == "Ok" {
            field_tys.push(ok)
          } else {
            field_tys.push(err)
          }
        TEnum(ename, eargs) =>
          match g.tc.enums.get(ename) {
            Some(einfo) => {
              let subst = make_subst(einfo.decl.type_params, eargs)
              let mut vi = 0
              while vi < einfo.variants.length() {
                let v = einfo.variants[vi]
                if v.name == vname {
                  let mut fi = 0
                  while fi < v.field_tys.length() {
                    field_tys.push(subst_ty(v.field_tys[fi], subst))
                    fi = fi + 1
                  }
                  break
                }
                vi = vi + 1
              }
            }
            None => ()
          }
        _ => ()
      }
      let mut fi = 0
      while fi < subs.length() && fi < field_tys.length() {
        let p = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + vreg + ", " + ((fi + 1) * 8).to_string())
        let fv = qbe_load_heap_slot(g, p, field_tys[fi])
        qbe_emit_pat_bind(g, subs[fi], fv, field_tys[fi], allow_borrow, arm_body)
        fi = fi + 1
      }
    }
  }
}

///|
/// Emit fused compare-and-branch (no `extuw` before `jnz`) so QBE arm64 `seljmp`
/// fuses `cmp/fcmp + b.cc` directly, and short-circuits `!`, `&&`, `||` with zero stack slots.
fn qbe_emit_cond_branch(
  g : QbeGen,
  cond : Expr,
  l_true : String,
  l_false : String,
) -> Unit {
  match cond {
    EUnary(op, inner, _) =>
      if op == "!" {
        qbe_emit_cond_branch(g, inner, l_false, l_true)
        return
      }
    EBinary(op, lhs, rhs, _) => {
      if op == "&&" {
        let l_rhs = qbe_lbl(g, "and_r")
        qbe_emit_cond_branch(g, lhs, l_rhs, l_false)
        qbe_emit_lbl(g, l_rhs)
        qbe_emit_cond_branch(g, rhs, l_true, l_false)
        return
      }
      if op == "||" {
        let l_rhs = qbe_lbl(g, "or_r")
        qbe_emit_cond_branch(g, lhs, l_true, l_rhs)
        qbe_emit_lbl(g, l_rhs)
        qbe_emit_cond_branch(g, rhs, l_true, l_false)
        return
      }
      if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
        let can_borrow = !qbe_expr_has_assign(lhs) && !qbe_expr_has_assign(rhs)
        let la = match lhs {
          EInt(raw, _) => {
            let v32 = qbe_parse_int64_lit(raw).to_int().to_int64().to_string()
            QbeArgVal::{ qv: qval(v32, TInt), borrowed: true }
          }
          _ => qbe_emit_arg_maybe_borrow(g, lhs, None, can_borrow)
        }
        let lv = la.qv
        let ra = match lv.ty {
          TInt =>
            match rhs {
              EInt(raw, _) => {
                let v32 = qbe_parse_int64_lit(raw).to_int().to_int64().to_string()
                QbeArgVal::{ qv: qval(v32, TInt), borrowed: true }
              }
              _ => qbe_emit_arg_maybe_borrow(g, rhs, Some(lv.ty), can_borrow)
            }
          _ => qbe_emit_arg_maybe_borrow(g, rhs, Some(lv.ty), can_borrow)
        }
        let rv = ra.qv
        match lv.ty {
          TInt => {
            let lw = lv.reg
            let rw = qbe_coerce_val(g, rv, TInt)
            let cop = if op == "==" {
              "ceqw"
            } else if op == "!=" {
              "cnew"
            } else if op == "<" {
              "csltw"
            } else if op == "<=" {
              "cslew"
            } else if op == ">" {
              "csgtw"
            } else {
              "csgew"
            }
            let cw = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + lw + ", " + rw)
            qbe_emit_term(g, "jnz " + cw + ", " + l_true + ", " + l_false)
            return
          }
          TDouble => {
            let ld = lv.reg
            let rd = qbe_coerce_val(g, rv, TDouble)
            let cop = if op == "==" {
              "ceqd"
            } else if op == "!=" {
              "cned"
            } else if op == "<" {
              "cltd"
            } else if op == "<=" {
              "cled"
            } else if op == ">" {
              "cgtd"
            } else {
              "cged"
            }
            let cw = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + ld + ", " + rd)
            qbe_emit_term(g, "jnz " + cw + ", " + l_true + ", " + l_false)
            return
          }
          TInt64 | TBool | TByte | TChar => {
            let cop = if op == "==" {
              "ceql"
            } else if op == "!=" {
              "cnel"
            } else if op == "<" {
              "csltl"
            } else if op == "<=" {
              "cslel"
            } else if op == ">" {
              "csgtl"
            } else {
              "csgel"
            }
            let cw = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + lv.reg + ", " + rv.reg)
            qbe_emit_term(g, "jnz " + cw + ", " + l_true + ", " + l_false)
            return
          }
          TString => {
            if op == "==" || op == "!=" {
              let eq = qbe_tmp(g)
              qbe_emit(g, eq + " =w call $m2_str_eq(l " + lv.reg + ", l " + rv.reg + ")")
              if !la.borrowed {
                qbe_rc_dec(g, lv.reg, lv.ty)
              }
              if !ra.borrowed {
                qbe_rc_dec(g, rv.reg, rv.ty)
              }
              if op == "==" {
                qbe_emit_term(g, "jnz " + eq + ", " + l_true + ", " + l_false)
              } else {
                qbe_emit_term(g, "jnz " + eq + ", " + l_false + ", " + l_true)
              }
              return
            } else {
              let cmp = qbe_tmp(g)
              qbe_emit(g, cmp + " =w call $m2_str_cmp(l " + lv.reg + ", l " + rv.reg + ")")
              if !la.borrowed {
                qbe_rc_dec(g, lv.reg, lv.ty)
              }
              if !ra.borrowed {
                qbe_rc_dec(g, rv.reg, rv.ty)
              }
              let cop = if op == "<" {
                "csltw"
              } else if op == "<=" {
                "cslew"
              } else if op == ">" {
                "csgtw"
              } else {
                "csgew"
              }
              let cw = qbe_tmp(g)
              qbe_emit(g, cw + " =w " + cop + " " + cmp + ", 0")
              qbe_emit_term(g, "jnz " + cw + ", " + l_true + ", " + l_false)
              return
            }
          }
          _ => {
            let cop = if op == "==" {
              "ceql"
            } else if op == "!=" {
              "cnel"
            } else if op == "<" {
              "csltl"
            } else if op == "<=" {
              "cslel"
            } else if op == ">" {
              "csgtl"
            } else {
              "csgel"
            }
            let cw = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + lv.reg + ", " + rv.reg)
            if !la.borrowed {
              qbe_rc_dec(g, lv.reg, lv.ty)
            }
            if !ra.borrowed {
              qbe_rc_dec(g, rv.reg, rv.ty)
            }
            qbe_emit_term(g, "jnz " + cw + ", " + l_true + ", " + l_false)
            return
          }
        }
      }
    }
    _ => ()
  }
  let cv = qbe_emit_expr(g, cond, Some(TBool))
  qbe_emit_term(g, "jnz " + cv.reg + ", " + l_true + ", " + l_false)
}

///|
fn qbe_peek_expr_ty(g : QbeGen, e : Expr) -> Option[Ty] {
  match e {
    EIdent(name, _) =>
      match qbe_lookup_local(g, name) {
        Some(loc) => Some(loc.ty)
        None => g.tc.consts.get(name)
      }
    EField(base, fname, _) =>
      match qbe_peek_expr_ty(g, base) {
        Some(TStruct(sname, sargs)) =>
          match g.tc.structs.get(sname) {
            Some(sinfo) => {
              let subst = make_subst(sinfo.decl.type_params, sargs)
              let mut i = 0
              while i < sinfo.field_names.length() {
                if sinfo.field_names[i] == fname {
                  return Some(subst_ty(sinfo.field_tys[i], subst))
                }
                i = i + 1
              }
              None
            }
            None => None
          }
        _ => None
      }
    EMove(inner, _) => qbe_peek_expr_ty(g, inner)
    _ => None
  }
}

///|
fn qbe_try_emit_map_get_match(
  g : QbeGen,
  scrut : Expr,
  arms : Array[MatchArm],
  expected : Option[Ty],
) -> Option[QbeVal] {
  match scrut {
    EMethodCall(map_expr, mname, margs, _) => {
      if mname != "get" || margs.length() != 1 || arms.length() != 2 {
        return None
      }
      let mut kty = TError
      let mut vty = TError
      match qbe_peek_expr_ty(g, map_expr) {
        Some(TMap(k, v)) => {
          kty = k
          vty = v
        }
        _ => return None
      }
      let mut matched = false
      let mut some_idx = 0
      let mut none_idx = 1
      let mut some_bind = ""
      match arms[0].pat {
        PVariant(q, vn, subs, _) =>
          if (q == "" || q == "Option") && vn == "Some" && subs.length() == 1 {
            let mut sub_ok = false
            match subs[0] {
              PIdent(vname, _) => {
                some_bind = vname
                sub_ok = true
              }
              PWild(_) => {
                some_bind = ""
                sub_ok = true
              }
              _ => ()
            }
            if sub_ok {
              match arms[1].pat {
                PVariant(q2, vn2, subs2, _) =>
                  if (q2 == "" || q2 == "Option") &&
                    vn2 == "None" &&
                    subs2.length() == 0 {
                    matched = true
                    some_idx = 0
                    none_idx = 1
                  }
                PWild(_) => {
                  matched = true
                  some_idx = 0
                  none_idx = 1
                }
                _ => ()
              }
            }
          } else if (q == "" || q == "Option") &&
            vn == "None" &&
            subs.length() == 0 {
            match arms[1].pat {
              PVariant(q2, vn2, subs2, _) =>
                if (q2 == "" || q2 == "Option") &&
                  vn2 == "Some" &&
                  subs2.length() == 1 {
                  match subs2[0] {
                    PIdent(vname, _) => {
                      some_bind = vname
                      matched = true
                      some_idx = 1
                      none_idx = 0
                    }
                    PWild(_) => {
                      some_bind = ""
                      matched = true
                      some_idx = 1
                      none_idx = 0
                    }
                    _ => ()
                  }
                }
              _ => ()
            }
          }
        _ => ()
      }
      if !matched {
        return None
      }
      qbe_scope_push(g)
      let key_expr = margs[0]
      let args_pure = !qbe_expr_has_assign(key_expr)
      let obj_av = qbe_emit_arg_maybe_borrow(g, map_expr, None, args_pure)
      let ka = qbe_emit_arg_maybe_borrow(g, key_expr, Some(kty), args_pure)
      let out_slot = qbe_alloc_slot(g)
      let hw = qbe_tmp(g)
      qbe_emit(
        g,
        hw +
        " =w call $m2_map_try_get(l " +
        obj_av.qv.reg +
        ", l " +
        ka.qv.reg +
        ", l " +
        out_slot +
        ")",
      )
      if !ka.borrowed {
        qbe_rc_dec(g, ka.qv.reg, ka.qv.ty)
      }
      if !obj_av.borrowed {
        let mloc = qbe_define_local(g, "__mget_map", obj_av.qv.ty, true)
        qbe_store_local_slot(g, obj_av.qv.reg, mloc.slot, obj_av.qv.ty)
      }
      let l_hit = qbe_lbl(g, "mget_some")
      let l_miss = qbe_lbl(g, "mget_none")
      let l_end = qbe_lbl(g, "mget_end")
      qbe_emit_term(g, "jnz " + hw + ", " + l_hit + ", " + l_miss)
      let mut res_slot = ""
      let mut res_ty : Option[Ty] = expected
      qbe_emit_lbl(g, l_hit)
      qbe_scope_push(g)
      if some_bind != "" {
        let raw_l = qbe_tmp(g)
        qbe_emit(g, raw_l + " =l loadl " + out_slot)
        let v_val = qbe_from_l(g, raw_l, vty)
        qbe_rc_inc(g, v_val, vty)
        let vloc = qbe_define_local(g, some_bind, vty, true)
        qbe_store_local_slot(g, v_val, vloc.slot, vty)
      }
      let sv = qbe_emit_expr(g, arms[some_idx].body, res_ty)
      match res_ty {
        None =>
          match sv.ty {
            TNever => ()
            _ => res_ty = Some(sv.ty)
          }
        Some(_) => ()
      }
      let some_term = g.block_term
      if !some_term {
        let store_ty = match res_ty {
          Some(t) => t
          None => sv.ty
        }
        if res_slot == "" {
          res_slot = qbe_alloc_slot_for(g, store_ty)
        }
        qbe_store_local_slot(g, qbe_coerce_val(g, sv, store_ty), res_slot, store_ty)
      }
      qbe_scope_pop(g)
      qbe_emit_term(g, "jmp " + l_end)
      qbe_emit_lbl(g, l_miss)
      qbe_scope_push(g)
      let nv = qbe_emit_expr(g, arms[none_idx].body, res_ty)
      match res_ty {
        None =>
          match nv.ty {
            TNever => ()
            _ => res_ty = Some(nv.ty)
          }
        Some(_) => ()
      }
      let none_term = g.block_term
      if !none_term {
        let store_ty = match res_ty {
          Some(t) => t
          None => nv.ty
        }
        if res_slot == "" {
          res_slot = qbe_alloc_slot_for(g, store_ty)
        }
        qbe_store_local_slot(g, qbe_coerce_val(g, nv, store_ty), res_slot, store_ty)
      }
      qbe_scope_pop(g)
      qbe_emit_term(g, "jmp " + l_end)
      qbe_emit_lbl(g, l_end)
      qbe_scope_pop(g)
      let final_ty = match res_ty {
        Some(t) => t
        None =>
          if some_term && none_term {
            TNever
          } else {
            TUnit
          }
      }
      if res_slot == "" {
        Some(qval(qbe_zero_reg(final_ty), final_ty))
      } else {
        let r = qbe_load_local_slot(g, res_slot, final_ty)
        Some(qval(r, final_ty))
      }
    }
    _ => None
  }
}

///|
fn qbe_emit_expr(
  g : QbeGen,
  expr : Expr,
  expected : Option[Ty],
) -> QbeVal {
  match expr {
    EInt(raw, _) => {
      let v64 = qbe_parse_int64_lit(raw)
      let v32 = v64.to_int().to_int64()
      let t = qbe_tmp(g)
      qbe_emit(g, t + " =w copy " + v32.to_string())
      qval(t, TInt)
    }
    EInt64(raw, _) => {
      let v64 = qbe_parse_int64_lit(raw)
      let t = qbe_tmp(g)
      qbe_emit(g, t + " =l copy " + v64.to_string())
      qval(t, TInt64)
    }
    EDouble(raw, _) => {
      let d = qbe_tmp(g)
      qbe_emit(g, d + " =d copy d_" + raw)
      qval(d, TDouble)
    }
    EBool(b, _) => {
      let t = qbe_tmp(g)
      qbe_emit(g, t + " =l copy " + (if b { "1" } else { "0" }))
      qval(t, TBool)
    }
    EByte(raw, _) => {
      let v = qbe_parse_char_lit(raw) & 255
      let t = qbe_tmp(g)
      qbe_emit(g, t + " =l copy " + v.to_string())
      qval(t, TByte)
    }
    EChar(raw, _) => {
      let v = qbe_parse_char_lit(raw)
      let t = qbe_tmp(g)
      qbe_emit(g, t + " =l copy " + v.to_string())
      qval(t, TChar)
    }
    EString(s, _) => qval(qbe_emit_string_lit(g, s), TString)
    EUnit(_) => qval("0", TUnit)
    EIdent(name, _) => {
      match qbe_lookup_local(g, name) {
        Some(loc) => {
          let t = qbe_load_local_slot(g, loc.slot, loc.ty)
          if qbe_is_int32_ty(loc.ty) {
            match g.local_w_to_l_ext.get(name) {
              Some(rl) => g.w_to_l_ext.set(t, rl)
              None => ()
            }
          }
          qbe_rc_inc(g, t, loc.ty)
          return qval(t, loc.ty)
        }
        None => ()
      }
      match g.tc.consts.get(name) {
        Some(cty) => {
          let t = qbe_load_heap_slot(g, qbe_local_const_sym(g, name), cty)
          qbe_rc_inc(g, t, cty)
          return qval(t, cty)
        }
        None => ()
      }
      match g.tc.fns.get(name) {
        Some(finfo) => {
          let wrap = qbe_register_fn_wrapper(g, name)
          let clo = qbe_tmp(g)
          qbe_emit(g, clo + " =l call $m2_alloc(w 8, w 6, l 0)")
          qbe_emit(g, "storel " + wrap + ", " + clo)
          return qval(clo, TFn(finfo.param_tys, finfo.ret_ty))
        }
        None => ()
      }
      if name == "None" {
        return qbe_emit_variant_ctor(g, "Option", "None", [], expected)
      }
      if g.tc.variant_to_enum.contains(name) {
        return qbe_emit_variant_ctor(g, "", name, [], expected)
      }
      qval("0", TError)
    }
    EPath(qual, mem, _) => {
      if qual == "Option" && mem == "None" {
        return qbe_emit_variant_ctor(g, "Option", "None", [], expected)
      }
      if g.tc.enums.contains(qual) {
        return qbe_emit_variant_ctor(g, qual, mem, [], expected)
      }
      let qp = split_qual_name(qual)
      let q_alias = qp.prefix
      let q_sub = qp.name
      if q_alias.length() > 0 {
        match resolve_alias_pkg(g.tc, q_alias) {
          Some(ipkg) =>
            if ipkg.tc.enums.contains(q_sub) {
              return qbe_emit_variant_ctor(
                g,
                ipkg.name + "::" + q_sub,
                mem,
                [],
                expected,
              )
            }
          None => ()
        }
      }
      match resolve_alias_pkg(g.tc, qual) {
        Some(ipkg) => {
          match ipkg.tc.consts.get(mem) {
            Some(cty) => {
              let qcty = qualify_imported_ty(ipkg.name, cty)
              let t = qbe_load_heap_slot(g, qbe_ext_const_sym(ipkg.name, mem), qcty)
              qbe_rc_inc(g, t, qcty)
              return qval(t, qcty)
            }
            None => ()
          }
          match ipkg.tc.variant_to_enum.get(mem) {
            Some(en) =>
              return qbe_emit_variant_ctor(
                g,
                ipkg.name + "::" + en,
                mem,
                [],
                expected,
              )
            None => ()
          }
        }
        None => ()
      }
      qval("0", TError)
    }
    EMove(inner, _) => qbe_emit_expr(g, inner, expected)
    EAs(inner, target, _) => {
      let v = qbe_emit_expr(g, inner, None)
      let rty = resolve_type_expr(g.tc, target, g.cur_tparams)
      match rty {
        TDouble =>
          match v.ty {
            TInt => {
              let d = qbe_tmp(g)
              qbe_emit(g, d + " =d swtof " + v.reg)
              qval(d, TDouble)
            }
            TInt64 | TByte | TChar => {
              let d = qbe_tmp(g)
              qbe_emit(g, d + " =d sltof " + v.reg)
              qval(d, TDouble)
            }
            TDouble => qval(v.reg, TDouble)
            _ => qval(qbe_from_l(g, v.reg, TDouble), TDouble)
          }
        TInt =>
          match v.ty {
            TDouble => {
              let w = qbe_tmp(g)
              qbe_emit(g, w + " =w dtosi " + v.reg)
              qval(w, TInt)
            }
            TInt => qval(v.reg, TInt)
            _ => qval(qbe_coerce_val(g, v, TInt), TInt)
          }
        TInt64 =>
          match v.ty {
            TDouble => {
              let r = qbe_tmp(g)
              qbe_emit(g, r + " =l dtosi " + v.reg)
              qval(r, TInt64)
            }
            TInt => {
              let r = qbe_tmp(g)
              qbe_emit(g, r + " =l extsw " + v.reg)
              qval(r, TInt64)
            }
            _ => qval(v.reg, TInt64)
          }
        TByte =>
          match v.ty {
            TDouble => {
              let w = qbe_tmp(g)
              let u = qbe_tmp(g)
              let r = qbe_tmp(g)
              qbe_emit(g, w + " =w dtosi " + v.reg)
              qbe_emit(g, u + " =l extuw " + w)
              qbe_emit(g, r + " =l and " + u + ", 255")
              qval(r, TByte)
            }
            _ => {
              let vl = qbe_as_l(g, v)
              let r = qbe_tmp(g)
              qbe_emit(g, r + " =l and " + vl + ", 255")
              qval(r, TByte)
            }
          }
        _ => qval(qbe_coerce_val(g, v, rty), rty)
      }
    }
    EUnary(op, inner, _) => {
      let iv = qbe_emit_expr(g, inner, expected)
      if op == "!" {
        let w = qbe_tmp(g)
        let nw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, w + " =w copy " + iv.reg)
        qbe_emit(g, nw + " =w ceqw " + w + ", 0")
        qbe_emit(g, r + " =l extuw " + nw)
        qval(r, TBool)
      } else {
        match iv.ty {
          TInt => {
            let nw = qbe_tmp(g)
            qbe_emit(g, nw + " =w neg " + iv.reg)
            qval(nw, TInt)
          }
          TDouble => {
            let nd = qbe_tmp(g)
            qbe_emit(g, nd + " =d neg " + iv.reg)
            qval(nd, TDouble)
          }
          _ => {
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l neg " + iv.reg)
            qval(r, iv.ty)
          }
        }
      }
    }
    EBinary(op, lhs, rhs, _) => {
      if op == "&&" {
        let res_slot = qbe_alloc_slot(g)
        let lv = qbe_emit_expr(g, lhs, Some(TBool))
        let l_rhs = qbe_lbl(g, "and_rhs")
        let l_false = qbe_lbl(g, "and_f")
        let l_end = qbe_lbl(g, "and_e")
        qbe_emit_term(g, "jnz " + lv.reg + ", " + l_rhs + ", " + l_false)
        qbe_emit_lbl(g, l_rhs)
        let rv = qbe_emit_expr(g, rhs, Some(TBool))
        qbe_emit(g, "storel " + rv.reg + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_false)
        qbe_emit(g, "storel 0, " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TBool)
      }
      if op == "||" {
        let res_slot = qbe_alloc_slot(g)
        let lv = qbe_emit_expr(g, lhs, Some(TBool))
        let l_true = qbe_lbl(g, "or_t")
        let l_rhs = qbe_lbl(g, "or_rhs")
        let l_end = qbe_lbl(g, "or_e")
        qbe_emit_term(g, "jnz " + lv.reg + ", " + l_true + ", " + l_rhs)
        qbe_emit_lbl(g, l_true)
        qbe_emit(g, "storel 1, " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_rhs)
        let rv = qbe_emit_expr(g, rhs, Some(TBool))
        qbe_emit(g, "storel " + rv.reg + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TBool)
      }
      // Loop-carried square reuse (`v * v` for TDouble local)
      if op == "*" {
        match lhs {
          EIdent(v1, _) =>
            match rhs {
              EIdent(v2, _) =>
                if v1 == v2 {
                  match g.sq_reuse_state.get(v1) {
                    Some(st) =>
                      match g.sq_reuse_slot.get(v1) {
                        Some(sq_slot) =>
                          if st == 1 {
                            let d = qbe_tmp(g)
                            qbe_emit(g, d + " =d loadd " + sq_slot)
                            return qval(d, TDouble)
                          } else if st == 2 {
                            let lv = qbe_emit_expr(g, lhs, Some(TDouble))
                            let ld = qbe_coerce_val(g, lv, TDouble)
                            let nsq = qbe_tmp(g)
                            qbe_emit(g, nsq + " =d mul " + ld + ", " + ld)
                            qbe_emit(g, "stored " + nsq + ", " + sq_slot)
                            g.sq_reuse_state.set(v1, 1)
                            return qval(nsq, TDouble)
                          }
                        None => ()
                      }
                    None => ()
                  }
                }
              _ => ()
            }
          _ => ()
        }
      }
      // IEEE-754 exact `2.0 * x -> x + x` strength reduction
      if op == "*" && qbe_is_double_two(lhs) {
        let rv = qbe_emit_expr(g, rhs, Some(TDouble))
        let rd = qbe_coerce_val(g, rv, TDouble)
        let ad = qbe_tmp(g)
        qbe_emit(g, ad + " =d add " + rd + ", " + rd)
        return qval(ad, TDouble)
      }
      let lv = match lhs {
        EInt(raw, _) => {
          let v32 = qbe_parse_int64_lit(raw).to_int().to_int64().to_string()
          qval(v32, TInt)
        }
        _ => qbe_emit_expr(g, lhs, None)
      }
      if op == "*" && qbe_is_double_ty(lv.ty) && qbe_is_double_two(rhs) {
        let ad = qbe_tmp(g)
        qbe_emit(g, ad + " =d add " + lv.reg + ", " + lv.reg)
        return qval(ad, TDouble)
      }
      let rv = match lv.ty {
        TInt =>
          match rhs {
            EInt(raw, _) => {
              let v32 = qbe_parse_int64_lit(raw).to_int().to_int64().to_string()
              qval(v32, TInt)
            }
            _ => qbe_emit_expr(g, rhs, Some(lv.ty))
          }
        _ => qbe_emit_expr(g, rhs, Some(lv.ty))
      }
      match lv.ty {
        TString => {
          if op == "+" {
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_str_concat(l " + lv.reg + ", l " + rv.reg + ")")
            qbe_rc_dec(g, lv.reg, lv.ty)
            qbe_rc_dec(g, rv.reg, rv.ty)
            return qval(r, TString)
          }
          if op == "==" || op == "!=" {
            let eq = qbe_tmp(g)
            qbe_emit(g, eq + " =w call $m2_str_eq(l " + lv.reg + ", l " + rv.reg + ")")
            qbe_rc_dec(g, lv.reg, lv.ty)
            qbe_rc_dec(g, rv.reg, rv.ty)
            if op == "==" {
              let r = qbe_tmp(g)
              qbe_emit(g, r + " =l extuw " + eq)
              return qval(r, TBool)
            } else {
              let ne = qbe_tmp(g)
              let r = qbe_tmp(g)
              qbe_emit(g, ne + " =w ceqw " + eq + ", 0")
              qbe_emit(g, r + " =l extuw " + ne)
              return qval(r, TBool)
            }
          }
          let cmp = qbe_tmp(g)
          qbe_emit(g, cmp + " =w call $m2_str_cmp(l " + lv.reg + ", l " + rv.reg + ")")
          qbe_rc_dec(g, lv.reg, lv.ty)
          qbe_rc_dec(g, rv.reg, rv.ty)
          let cop = if op == "<" {
            "csltw"
          } else if op == "<=" {
            "cslew"
          } else if op == ">" {
            "csgtw"
          } else {
            "csgew"
          }
          let cw = qbe_tmp(g)
          let r = qbe_tmp(g)
          qbe_emit(g, cw + " =w " + cop + " " + cmp + ", 0")
          qbe_emit(g, r + " =l extuw " + cw)
          qval(r, TBool)
        }
        TInt => {
          let lw = lv.reg
          let rw = qbe_coerce_val(g, rv, TInt)
          if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
            let cop = if op == "==" {
              "ceqw"
            } else if op == "!=" {
              "cnew"
            } else if op == "<" {
              "csltw"
            } else if op == "<=" {
              "cslew"
            } else if op == ">" {
              "csgtw"
            } else {
              "csgew"
            }
            let cw = qbe_tmp(g)
            let r = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + lw + ", " + rw)
            qbe_emit(g, r + " =l extuw " + cw)
            qval(r, TBool)
          } else {
            // Power-of-2 signed division shift optimization (truncating toward zero)
            if op == "/" {
              match rhs {
                EInt(raw, _) => {
                  let d = qbe_parse_int64_lit(raw)
                  if d >= 2L && d <= 1073741824L && (d & (d - 1L)) == 0L {
                    let mut k = 0
                    let mut p2 = 1L
                    while p2 < d {
                      p2 = p2 << 1
                      k = k + 1
                    }
                    let aw = qbe_tmp(g)
                    if k == 1 {
                      if qbe_expr_is_even_int(lhs) {
                        qbe_emit(g, aw + " =w sar " + lw + ", 1")
                      } else {
                        let s = qbe_tmp(g)
                        let a = qbe_tmp(g)
                        qbe_emit(g, s + " =w shr " + lw + ", 31")
                        qbe_emit(g, a + " =w add " + lw + ", " + s)
                        qbe_emit(g, aw + " =w sar " + a + ", 1")
                      }
                    } else {
                      let s = qbe_tmp(g)
                      let b = qbe_tmp(g)
                      let a = qbe_tmp(g)
                      let mask = (d - 1L).to_string()
                      qbe_emit(g, s + " =w sar " + lw + ", 31")
                      qbe_emit(g, b + " =w and " + s + ", " + mask)
                      qbe_emit(g, a + " =w add " + lw + ", " + b)
                      qbe_emit(g, aw + " =w sar " + a + ", " + k.to_string())
                    }
                    return qval(aw, TInt)
                  }
                }
                _ => ()
              }
            }
            let aop = if op == "+" {
              "add"
            } else if op == "-" {
              "sub"
            } else if op == "*" {
              "mul"
            } else if op == "/" {
              "div"
            } else if op == "%" {
              "rem"
            } else if op == "&" {
              "and"
            } else if op == "|" {
              "or"
            } else if op == "^" {
              "xor"
            } else if op == "<<" {
              "shl"
            } else {
              "sar"
            }
            let aw = qbe_tmp(g)
            qbe_emit(g, aw + " =w " + aop + " " + lw + ", " + rw)
            qval(aw, TInt)
          }
        }
        TDouble => {
          let ld = lv.reg
          let rd = qbe_coerce_val(g, rv, TDouble)
          if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
            let cop = if op == "==" {
              "ceqd"
            } else if op == "!=" {
              "cned"
            } else if op == "<" {
              "cltd"
            } else if op == "<=" {
              "cled"
            } else if op == ">" {
              "cgtd"
            } else {
              "cged"
            }
            let cw = qbe_tmp(g)
            let r = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + ld + ", " + rd)
            qbe_emit(g, r + " =l extuw " + cw)
            qval(r, TBool)
          } else {
            let aop = if op == "+" {
              "add"
            } else if op == "-" {
              "sub"
            } else if op == "*" {
              "mul"
            } else {
              "div"
            }
            let ad = qbe_tmp(g)
            qbe_emit(g, ad + " =d " + aop + " " + ld + ", " + rd)
            qval(ad, TDouble)
          }
        }
        _ => {
          if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
            let cop = if op == "==" {
              "ceql"
            } else if op == "!=" {
              "cnel"
            } else if op == "<" {
              "csltl"
            } else if op == "<=" {
              "cslel"
            } else if op == ">" {
              "csgtl"
            } else {
              "csgel"
            }
            let cw = qbe_tmp(g)
            let r = qbe_tmp(g)
            qbe_emit(g, cw + " =w " + cop + " " + lv.reg + ", " + rv.reg)
            qbe_rc_dec(g, lv.reg, lv.ty)
            qbe_rc_dec(g, rv.reg, rv.ty)
            qbe_emit(g, r + " =l extuw " + cw)
            qval(r, TBool)
          } else if op == "<<" || op == ">>" {
            let rw = qbe_coerce_val(g, rv, TInt)
            let r = qbe_tmp(g)
            let sop = if op == "<<" { "shl" } else { "sar" }
            qbe_emit(g, r + " =l " + sop + " " + lv.reg + ", " + rw)
            qval(r, lv.ty)
          } else {
            let aop = if op == "+" {
              "add"
            } else if op == "-" {
              "sub"
            } else if op == "*" {
              "mul"
            } else if op == "/" {
              "div"
            } else if op == "%" {
              "rem"
            } else if op == "&" {
              "and"
            } else if op == "|" {
              "or"
            } else {
              "xor"
            }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l " + aop + " " + lv.reg + ", " + rv.reg)
            qval(r, lv.ty)
          }
        }
      }
    }
    ECall(callee, args, sp) => {
      g.block_immut_fields = Map([])
      match callee {
        EIdent(name, _) => {
          if name == "StringBuilder" {
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_strbuf_new(l 32)")
            return qval(r, TStringBuilder)
          }
          if name == "Map" {
            let mut kty = TString
            let mut vty = TError
            match expected {
              Some(TMap(k, v)) => {
                kty = k
                vty = v
              }
              _ => ()
            }
            let vo = if qbe_is_obj_ty(vty) { "1" } else { "0" }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_map_new(w " + vo + ")")
            return qval(r, TMap(kty, vty))
          }
          if name == "sha256_hex" {
            let can_b = !qbe_args_have_assign(args)
            let sa = qbe_emit_arg_maybe_borrow(g, args[0], Some(TString), can_b)
            let sv = sa.qv
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_sha256_hex(l " + sv.reg + ")")
            if !sa.borrowed {
              qbe_rc_dec(g, sv.reg, sv.ty)
            }
            return qval(r, TString)
          }
          if name == "math_sqrt" {
            let xv = qbe_emit_expr(g, args[0], Some(TDouble))
            let xd = qbe_coerce_val(g, xv, TDouble)
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =d sqrt " + xd)
            return qval(r, TDouble)
          }
          if is_world_builtin(name) {
            return qbe_emit_world_builtin(g, name, args)
          }
          if name == "abort" || name == "panic" {
            let file_id = qbe_intern_cstring(g, sp.file)
            let msg_id = qbe_intern_cstring(g, "panic")
            qbe_emit(
              g,
              "call $m2_panic(l $m2_cstr_" +
              msg_id.to_string() +
              ", l $m2_cstr_" +
              file_id.to_string() +
              ", w " +
              sp.line.to_string() +
              ")",
            )
            return qval("0", TNever)
          }
          if name == "Some" || name == "Ok" || name == "Err" || g.tc.variant_to_enum.contains(name) {
            return qbe_emit_variant_ctor(g, "", name, args, expected)
          }
          match g.tc.fns.get(name) {
            Some(finfo) => {
              let subst : Map[String, Ty] = Map([])
              match expected {
                Some(et) => unify_tparams(finfo.ret_ty, et, subst)
                None => ()
              }
              let can_borrow = !qbe_args_have_assign(args)
              let arg_vals : Array[String] = []
              let arg_tys : Array[Ty] = []
              let arg_borrowed : Array[Bool] = []
              let mut i = 0
              while i < args.length() {
                match args[i] {
                  EIdent(aname, _) => qbe_invalidate_len_aliases_for(g, aname)
                  _ => ()
                }
                let exp_p : Option[Ty] = if i < finfo.param_tys.length() {
                  Some(subst_ty(finfo.param_tys[i], subst))
                } else {
                  None
                }
                let aa = qbe_emit_arg_maybe_borrow(g, args[i], exp_p, can_borrow)
                let av = aa.qv
                if i < finfo.param_tys.length() {
                  unify_tparams(finfo.param_tys[i], av.ty, subst)
                }
                arg_vals.push(av.reg)
                arg_tys.push(av.ty)
                arg_borrowed.push(aa.borrowed)
                i = i + 1
              }
              // Small-function / leaf-function single-pass inlining (same-file only)
              if g.inline_depth < 2 &&
                finfo.decl.type_params.length() == 0 &&
                !str_arr_contains(g.inline_stack, name) {
                match g.inline_fns.get(name) {
                  Some(inl_fd) =>
                    if arg_vals.length() == inl_fd.params.length() &&
                      arg_vals.length() == finfo.param_tys.length() {
                      g.inline_depth = g.inline_depth + 1
                      g.inline_stack.push(name)
                      qbe_scope_push(g)
                      let mut pi = 0
                      while pi < inl_fd.params.length() {
                        let pty = finfo.param_tys[pi]
                        let loc = qbe_define_local(
                          g,
                          inl_fd.params[pi].name,
                          pty,
                          !arg_borrowed[pi],
                        )
                        let pv = qbe_coerce_val(g, qval(arg_vals[pi], arg_tys[pi]), pty)
                        qbe_store_local_slot(g, pv, loc.slot, pty)
                        pi = pi + 1
                      }
                      let bres = qbe_emit_stmts(g, inl_fd.body, Some(finfo.ret_ty))
                      let out_reg = qbe_coerce_val(g, bres, finfo.ret_ty)
                      qbe_scope_pop(g)
                      let _ = g.inline_stack.pop()
                      g.inline_depth = g.inline_depth - 1
                      return qval(out_reg, finfo.ret_ty)
                    }
                  None => ()
                }
              }
              let call_args : Array[String] = []
              let call_abis : Array[String] = []
              let mut j = 0
              while j < arg_vals.length() {
                let decl_pty = if j < finfo.param_tys.length() {
                  finfo.param_tys[j]
                } else {
                  arg_tys[j]
                }
                call_args.push(qbe_coerce_val(g, qval(arg_vals[j], arg_tys[j]), decl_pty))
                call_abis.push(qbe_abi_ty(decl_pty))
                j = j + 1
              }
              let ret_abi = qbe_abi_ty(finfo.ret_ty)
              let res = qbe_tmp(g)
              let sb = StringBuilder()
              sb.write_string(res)
              sb.write_string(" =")
              sb.write_string(ret_abi)
              sb.write_string(" call ")
              sb.write_string(qbe_local_fn_sym(g, name))
              sb.write_string("(")
              j = 0
              while j < call_args.length() {
                if j > 0 {
                  sb.write_string(", ")
                }
                sb.write_string(call_abis[j])
                sb.write_string(" ")
                sb.write_string(call_args[j])
                j = j + 1
              }
              let mut tpi = 0
              while tpi < finfo.decl.type_params.length() {
                if call_args.length() > 0 || tpi > 0 {
                  sb.write_string(", ")
                }
                let tp_ty = match subst.get(finfo.decl.type_params[tpi]) {
                  Some(t) => t
                  None => TError
                }
                sb.write_string("l ")
                sb.write_string(qbe_is_obj_flag(g, tp_ty))
                tpi = tpi + 1
              }
              sb.write_string(")")
              qbe_emit(g, sb.to_string())
              g.block_immut_fields = Map([])
              j = 0
              while j < arg_vals.length() {
                if !arg_borrowed[j] {
                  qbe_rc_dec(g, arg_vals[j], arg_tys[j])
                }
                j = j + 1
              }
              let concrete_ret = subst_ty(finfo.ret_ty, subst)
              let final_res = qbe_coerce_val(g, qval(res, finfo.ret_ty), concrete_ret)
              return qval(final_res, concrete_ret)
            }
            None => ()
          }
          match qbe_lookup_local(g, name) {
            Some(loc) => {
              let clo_v = qbe_tmp(g)
              qbe_emit(g, clo_v + " =l loadl " + loc.slot)
              qbe_emit(g, "call $m2_rc_inc(l " + clo_v + ")")
              let mut ptys : Array[Ty] = []
              let mut rty = TError
              match loc.ty {
                TFn(ps, rt) => {
                  ptys = ps
                  rty = rt
                }
                _ => ()
              }
              let arg_vals : Array[String] = []
              let arg_tys : Array[Ty] = []
              let mut i = 0
              while i < args.length() {
                let ep : Option[Ty] = if i < ptys.length() {
                  Some(ptys[i])
                } else {
                  None
                }
                let av = qbe_emit_expr(g, args[i], ep)
                arg_vals.push(av.reg)
                arg_tys.push(av.ty)
                i = i + 1
              }
              let res = qbe_emit_closure_call(g, clo_v, arg_vals, arg_tys)
              return qval(qbe_from_l(g, res, rty), rty)
            }
            None => qval("0", TError)
          }
        }
        EPath(qual, mem, _) => {
          if qual == "StringBuilder" && mem == "new" {
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_strbuf_new(l 32)")
            return qval(r, TStringBuilder)
          }
          if qual == "Map" && mem == "new" {
            let mut kty = TString
            let mut vty = TError
            match expected {
              Some(TMap(k, v)) => {
                kty = k
                vty = v
              }
              _ => ()
            }
            let vo = if qbe_is_obj_ty(vty) { "1" } else { "0" }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_map_new(w " + vo + ")")
            return qval(r, TMap(kty, vty))
          }
          if qual == "Array" && mem == "new" {
            let elem = match expected {
              Some(TArray(e)) => e
              _ => TError
            }
            let eo = if qbe_is_obj_ty(elem) { "1" } else { "0" }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_arr_new(l 0, w " + eo + ")")
            return qval(r, TArray(elem))
          }
          if qual == "Channel" && mem == "new" {
            let elem = match expected {
              Some(TChannel(e)) => e
              _ => TError
            }
            let cap_v = if args.length() >= 1 {
              qbe_emit_expr(g, args[0], Some(TInt))
            } else {
              qval("0", TInt)
            }
            let cap_l = qbe_as_l(g, cap_v)
            let eo = if qbe_is_obj_ty(elem) { "1" } else { "0" }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_chan_new(l " + cap_l + ", w " + eo + ")")
            return qval(r, TChannel(elem))
          }
          if qual == "Mutex" && mem == "new" {
            let exp_inner : Option[Ty] = match expected {
              Some(TMutex(e)) => Some(e)
              _ => None
            }
            let iv = if args.length() >= 1 {
              qbe_emit_expr(g, args[0], exp_inner)
            } else {
              qval("0", TError)
            }
            let vo = if qbe_is_obj_ty(iv.ty) { "1" } else { "0" }
            let il = qbe_as_l(g, iv)
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_mutex_new(l " + il + ", w " + vo + ")")
            qbe_rc_dec(g, iv.reg, iv.ty)
            return qval(r, TMutex(iv.ty))
          }
          if qual == "AtomicInt" && mem == "new" {
            let iv = if args.length() >= 1 {
              qbe_emit_expr(g, args[0], Some(TInt))
            } else {
              qval("0", TInt)
            }
            let il = qbe_as_l(g, iv)
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_atomic_new(l " + il + ")")
            return qval(r, TAtomicInt)
          }
          if qual == "Option" || qual == "Result" || g.tc.enums.contains(qual) {
            return qbe_emit_variant_ctor(g, qual, mem, args, expected)
          }
          let mut target_finfo : Option[FnInfo] = None
          let mut target_sym = ""
          let qp = split_qual_name(qual)
          let q_alias = qp.prefix
          let q_sub = qp.name
          if q_alias.length() > 0 {
            match resolve_alias_pkg(g.tc, q_alias) {
              Some(ipkg) => {
                if ipkg.tc.enums.contains(q_sub) {
                  return qbe_emit_variant_ctor(
                    g,
                    ipkg.name + "::" + q_sub,
                    mem,
                    args,
                    expected,
                  )
                }
                match ipkg.tc.methods.get(q_sub + "::" + mem) {
                  Some(mi) => {
                    target_finfo = Some(qualify_fn_info(ipkg.name, mi))
                    target_sym = qbe_ext_method_sym(ipkg.name, q_sub, mem)
                  }
                  None => ()
                }
              }
              None => ()
            }
          }
          match target_finfo {
            None =>
              match resolve_alias_pkg(g.tc, qual) {
                Some(ipkg) => {
                  match ipkg.tc.fns.get(mem) {
                    Some(fi) => {
                      target_finfo = Some(qualify_fn_info(ipkg.name, fi))
                      target_sym = qbe_ext_fn_sym(ipkg.name, mem)
                    }
                    None => ()
                  }
                  match target_finfo {
                    None =>
                      match ipkg.tc.variant_to_enum.get(mem) {
                        Some(en) =>
                          return qbe_emit_variant_ctor(
                            g,
                            ipkg.name + "::" + en,
                            mem,
                            args,
                            expected,
                          )
                        None => ()
                      }
                    Some(_) => ()
                  }
                }
                None => ()
              }
            Some(_) => ()
          }
          match target_finfo {
            None => {
              let key = qual + "::" + mem
              match g.tc.methods.get(key) {
                Some(minfo) => {
                  target_finfo = Some(minfo)
                  target_sym = qbe_local_method_sym(g, qual, mem)
                }
                None => ()
              }
            }
            Some(_) => ()
          }
          match target_finfo {
            Some(minfo) => {
              let subst : Map[String, Ty] = Map([])
              match expected {
                Some(et) => unify_tparams(minfo.ret_ty, et, subst)
                None => ()
              }
              let can_borrow = !qbe_args_have_assign(args)
              let arg_vals : Array[String] = []
              let arg_tys : Array[Ty] = []
              let arg_borrowed : Array[Bool] = []
              let mut i = 0
              while i < args.length() {
                match args[i] {
                  EIdent(aname, _) => qbe_invalidate_len_aliases_for(g, aname)
                  _ => ()
                }
                let exp_p : Option[Ty] = if i < minfo.param_tys.length() {
                  Some(subst_ty(minfo.param_tys[i], subst))
                } else {
                  None
                }
                let aa = qbe_emit_arg_maybe_borrow(g, args[i], exp_p, can_borrow)
                let av = aa.qv
                if i < minfo.param_tys.length() {
                  unify_tparams(minfo.param_tys[i], av.ty, subst)
                }
                arg_vals.push(av.reg)
                arg_tys.push(av.ty)
                arg_borrowed.push(aa.borrowed)
                i = i + 1
              }
              let call_args : Array[String] = []
              let call_abis : Array[String] = []
              let mut j = 0
              while j < arg_vals.length() {
                let decl_pty = if j < minfo.param_tys.length() {
                  minfo.param_tys[j]
                } else {
                  arg_tys[j]
                }
                call_args.push(qbe_coerce_val(g, qval(arg_vals[j], arg_tys[j]), decl_pty))
                call_abis.push(qbe_abi_ty(decl_pty))
                j = j + 1
              }
              let ret_abi = qbe_abi_ty(minfo.ret_ty)
              let res = qbe_tmp(g)
              let sb = StringBuilder()
              sb.write_string(res)
              sb.write_string(" =")
              sb.write_string(ret_abi)
              sb.write_string(" call ")
              sb.write_string(target_sym)
              sb.write_string("(")
              j = 0
              while j < call_args.length() {
                if j > 0 {
                  sb.write_string(", ")
                }
                sb.write_string(call_abis[j])
                sb.write_string(" ")
                sb.write_string(call_args[j])
                j = j + 1
              }
              let mut tpi = 0
              while tpi < minfo.decl.type_params.length() {
                if call_args.length() > 0 || tpi > 0 {
                  sb.write_string(", ")
                }
                let tp_ty = match subst.get(minfo.decl.type_params[tpi]) {
                  Some(t) => t
                  None => TError
                }
                sb.write_string("l ")
                sb.write_string(qbe_is_obj_flag(g, tp_ty))
                tpi = tpi + 1
              }
              sb.write_string(")")
              qbe_emit(g, sb.to_string())
              g.block_immut_fields = Map([])
              j = 0
              while j < arg_vals.length() {
                if !arg_borrowed[j] {
                  qbe_rc_dec(g, arg_vals[j], arg_tys[j])
                }
                j = j + 1
              }
              let concrete_ret = subst_ty(minfo.ret_ty, subst)
              let final_res = qbe_coerce_val(g, qval(res, minfo.ret_ty), concrete_ret)
              return qval(final_res, concrete_ret)
            }
            None => qval("0", TError)
          }
        }
        _ => {
          let cv = qbe_emit_expr(g, callee, None)
          let mut ptys : Array[Ty] = []
          let mut rty = TError
          match cv.ty {
            TFn(ps, rt) => {
              ptys = ps
              rty = rt
            }
            _ => ()
          }
          let arg_vals : Array[String] = []
          let arg_tys : Array[Ty] = []
          let mut i = 0
          while i < args.length() {
            let ep : Option[Ty] = if i < ptys.length() {
              Some(ptys[i])
            } else {
              None
            }
            let av = qbe_emit_expr(g, args[i], ep)
            arg_vals.push(av.reg)
            arg_tys.push(av.ty)
            i = i + 1
          }
          let res = qbe_emit_closure_call(g, cv.reg, arg_vals, arg_tys)
          g.block_immut_fields = Map([])
          qval(qbe_from_l(g, res, rty), rty)
        }
      }
    }
    EField(obj, field_name, _) => {
      let mut cache_key = ""
      match obj {
        EIdent(lname, _) => {
          cache_key = lname + "." + field_name
          match g.promoted_fields.get(cache_key) {
            Some(pslot) =>
              match g.promoted_field_tys.get(cache_key) {
                Some(pty) => {
                  let r = qbe_load_local_slot(g, pslot, pty)
                  return qval(r, pty)
                }
                None => ()
              }
            None => ()
          }
          match g.hoisted_fields.get(cache_key) {
            Some(hv) => return hv
            None => ()
          }
          match g.block_immut_fields.get(cache_key) {
            Some(bv) => return bv
            None => ()
          }
        }
        _ => ()
      }
      let mut borrowed = false
      let mut ov = qval("0", TError)
      match obj {
        EIdent(lname, _) =>
          match qbe_lookup_local(g, lname) {
            Some(loc) =>
              match loc.ty {
                TStruct(_, _) => {
                  let r = qbe_tmp(g)
                  qbe_emit(g, r + " =l loadl " + loc.slot)
                  ov = qval(r, loc.ty)
                  borrowed = true
                }
                _ => ()
              }
            None => ()
          }
        _ => ()
      }
      if !borrowed {
        ov = qbe_emit_expr(g, obj, None)
      }
      match ov.ty {
        TStruct(sname, sargs) =>
          match g.tc.structs.get(sname) {
            Some(sinfo) => {
              let subst = make_subst(sinfo.decl.type_params, sargs)
              let mut i = 0
              while i < sinfo.field_names.length() {
                if sinfo.field_names[i] == field_name {
                  let fty = subst_ty(sinfo.field_tys[i], subst)
                  let p = qbe_tmp(g)
                  qbe_emit(g, p + " =l add " + ov.reg + ", " + (i * 8).to_string())
                  let r = qbe_load_heap_slot(g, p, fty)
                  qbe_rc_inc(g, r, fty)
                  if !borrowed {
                    qbe_rc_dec(g, ov.reg, ov.ty)
                  }
                  let res_val = qval(r, fty)
                  if borrowed && cache_key != "" && !sinfo.field_muts[i] {
                    let is_prim = match fty {
                      TInt | TInt64 | TDouble | TBool | TByte | TChar => true
                      _ => false
                    }
                    if is_prim {
                      g.block_immut_fields.set(cache_key, res_val)
                    }
                  }
                  return res_val
                }
                i = i + 1
              }
              if !borrowed {
                qbe_rc_dec(g, ov.reg, ov.ty)
              }
              qval("0", TError)
            }
            None => {
              if !borrowed {
                qbe_rc_dec(g, ov.reg, ov.ty)
              }
              qval("0", TError)
            }
          }
        _ => {
          if !borrowed {
            qbe_rc_dec(g, ov.reg, ov.ty)
          }
          qval("0", TError)
        }
      }
    }
    EMethodCall(obj, method_name, args, _) => {
      g.block_immut_fields = Map([])
      let r = qbe_emit_method_call(g, obj, method_name, args, expected)
      g.block_immut_fields = Map([])
      r
    }
    EIndex(obj, idx, _) => {
      let mut borrowed = false
      let mut ov = qval("0", TError)
      let mut arr_local_name = ""
      if !qbe_expr_has_assign(idx) {
        match obj {
          EIdent(lname, _) =>
            match qbe_lookup_local(g, lname) {
              Some(loc) =>
                match loc.ty {
                  TArray(_) => {
                    arr_local_name = lname
                    borrowed = true
                    if g.hoisted_arr_len.contains(lname) &&
                      g.hoisted_arr_dp.contains(lname) {
                      ov = qval("0", loc.ty)
                    } else {
                      let r = qbe_tmp(g)
                      qbe_emit(g, r + " =l loadl " + loc.slot)
                      ov = qval(r, loc.ty)
                    }
                  }
                  _ => ()
                }
              None => ()
            }
          _ => ()
        }
      }
      if !borrowed {
        ov = qbe_emit_expr(g, obj, None)
      }
      match ov.ty {
        TArray(elem) => {
          let iv = qbe_emit_expr(g, idx, Some(TInt))
          let il = qbe_as_l(g, iv)
          let bce_safe = if arr_local_name != "" {
            qbe_bce_expr_is_safe(g, arr_local_name, idx)
          } else {
            false
          }
          if !bce_safe {
            let alen = match g.hoisted_arr_len.get(arr_local_name) {
              Some(hlen) => hlen
              None => {
                let t = qbe_tmp(g)
                qbe_emit(g, t + " =l loadl " + ov.reg)
                t
              }
            }
            let oob = qbe_tmp(g)
            let l_oob = qbe_lbl(g, "arr_oob")
            let l_ok = qbe_lbl(g, "arr_ok")
            qbe_emit(g, oob + " =w cugel " + il + ", " + alen)
            qbe_emit_term(g, "jnz " + oob + ", " + l_oob + ", " + l_ok)
            qbe_emit_lbl(g, l_oob)
            qbe_emit(g, "call $m2_panic_oob(l " + il + ", l " + alen + ")")
            qbe_emit_term(g, "hlt")
            qbe_emit_lbl(g, l_ok)
          }
          let dp = match g.hoisted_arr_dp.get(arr_local_name) {
            Some(hdp) => hdp
            None => {
              let dp_p = qbe_tmp(g)
              let t = qbe_tmp(g)
              qbe_emit(g, dp_p + " =l add " + ov.reg + ", 24")
              qbe_emit(g, t + " =l loadl " + dp_p)
              t
            }
          }
          let off = qbe_tmp(g)
          let ep = qbe_tmp(g)
          qbe_emit(g, off + " =l shl " + il + ", 3")
          qbe_emit(g, ep + " =l add " + dp + ", " + off)
          let r = if qbe_is_int32_ty(elem) {
            let rl = qbe_tmp(g)
            let rw = qbe_tmp(g)
            qbe_emit(g, rl + " =l loadl " + ep)
            qbe_emit(g, rw + " =w copy " + rl)
            g.w_to_l_ext.set(rw, rl)
            rw
          } else {
            qbe_load_heap_slot(g, ep, elem)
          }
          qbe_rc_inc(g, r, elem)
          if !borrowed {
            qbe_rc_dec(g, ov.reg, ov.ty)
          }
          qval(r, elem)
        }
        TMap(kty, vty) => {
          let kv = qbe_emit_expr(g, idx, Some(kty))
          let r = qbe_tmp(g)
          qbe_emit(g, r + " =l call $m2_map_get(l " + ov.reg + ", l " + kv.reg + ")")
          qbe_rc_inc(g, r, vty)
          qbe_rc_dec(g, kv.reg, kv.ty)
          qbe_rc_dec(g, ov.reg, ov.ty)
          qval(qbe_from_l(g, r, vty), vty)
        }
        TString => {
          let iv = qbe_emit_expr(g, idx, Some(TInt))
          let il = qbe_as_l(g, iv)
          let bw = qbe_tmp(g)
          qbe_emit(g, bw + " =w call $m2_str_byte_at(l " + ov.reg + ", l " + il + ")")
          qbe_rc_dec(g, ov.reg, ov.ty)
          qval(bw, TInt)
        }
        _ => {
          let _ = qbe_emit_expr(g, idx, None)
          if !borrowed {
            qbe_rc_dec(g, ov.reg, ov.ty)
          }
          qval("0", TError)
        }
      }
    }
    EArrayLit(elems, _) => {
      let exp_elem : Option[Ty] = match expected {
        Some(TArray(e)) => Some(e)
        _ => None
      }
      let elem_vals : Array[String] = []
      let elem_tys : Array[Ty] = []
      let mut elem_ty = match exp_elem {
        Some(e) => e
        None => TError
      }
      let mut i = 0
      while i < elems.length() {
        let exp_cur : Option[Ty] = if i == 0 { exp_elem } else { Some(elem_ty) }
        let ev = qbe_emit_expr(g, elems[i], exp_cur)
        if i == 0 {
          match exp_elem {
            Some(_) => ()
            None => elem_ty = ev.ty
          }
        }
        elem_vals.push(ev.reg)
        elem_tys.push(ev.ty)
        i = i + 1
      }
      let eo = if qbe_is_obj_ty(elem_ty) { "1" } else { "0" }
      let arr = qbe_tmp(g)
      qbe_emit(
        g,
        arr + " =l call $m2_arr_new(l " + elems.length().to_string() + ", w " + eo + ")",
      )
      i = 0
      while i < elem_vals.length() {
        let el = qbe_as_l(g, qval(elem_vals[i], elem_tys[i]))
        qbe_emit(g, "call $m2_arr_push(l " + arr + ", l " + el + ")")
        qbe_rc_dec(g, elem_vals[i], elem_tys[i])
        i = i + 1
      }
      qval(arr, TArray(elem_ty))
    }
    EStructLit(sname, fields, _) => {
      let mut resolved_name = if sname != "" {
        sname
      } else {
        match expected {
          Some(TStruct(en, _)) => en
          _ => ""
        }
      }
      if resolved_name != "" && !g.tc.structs.contains(resolved_name) {
        let qp = split_qual_name(resolved_name)
        let q_alias = qp.prefix
        let q_st = qp.name
        if q_alias.length() > 0 {
          match resolve_alias_pkg(g.tc, q_alias) {
            Some(ipkg) =>
              if ipkg.tc.structs.contains(q_st) {
                resolved_name = ipkg.name + "::" + q_st
              }
            None => ()
          }
        }
      }
      match g.tc.structs.get(resolved_name) {
        None => qval("0", TError)
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
          let n_fields = sinfo.field_names.length()
          let slot_vals : Array[String] = []
          let slot_tys : Array[Ty] = []
          let mut init_i = 0
          while init_i < n_fields {
            slot_vals.push(qbe_zero_reg(sinfo.field_tys[init_i]))
            slot_tys.push(sinfo.field_tys[init_i])
            init_i = init_i + 1
          }
          let mut fi = 0
          while fi < fields.length() {
            let f = fields[fi]
            let mut j = 0
            while j < n_fields {
              if sinfo.field_names[j] == f.name {
                let exp_f = subst_ty(sinfo.field_tys[j], subst)
                let fv = qbe_emit_expr(g, f.value, Some(exp_f))
                unify_tparams(sinfo.field_tys[j], fv.ty, subst)
                slot_vals[j] = fv.reg
                slot_tys[j] = fv.ty
                break
              }
              j = j + 1
            }
            fi = fi + 1
          }
          let payload_sz = if n_fields == 0 { 8 } else { n_fields * 8 }
          let drop_sym = if sinfo.decl.type_params.length() == 0 {
            let mut has_obj = false
            let mut k = 0
            while k < n_fields {
              if qbe_is_obj_ty(sinfo.field_tys[k]) {
                has_obj = true
                break
              }
              k = k + 1
            }
            if has_obj {
              if has_qual_sep(resolved_name) && !str_arr_contains(g.struct_order, resolved_name) {
                g.struct_order.push(resolved_name)
              }
              "$m2_drop_struct_" + qbe_sanitize_sym(resolved_name)
            } else {
              "0"
            }
          } else {
            let mut mask = 0
            let mut k = 0
            while k < n_fields {
              let concrete_ty = subst_ty(sinfo.field_tys[k], subst)
              if qbe_is_obj_ty(concrete_ty) || qbe_is_obj_ty(slot_tys[k]) {
                mask = mask | (1 << k)
              }
              k = k + 1
            }
            qbe_register_slot_drop(g, mask)
          }
          let obj = qbe_tmp(g)
          let alloc_fn = if n_fields > 0 { "$m2_alloc_uninit" } else { "$m2_alloc" }
          qbe_emit(
            g,
            obj +
            " =l call " +
            alloc_fn +
            "(w " +
            payload_sz.to_string() +
            ", w 4, l " +
            drop_sym +
            ")",
          )
          let mut k = 0
          while k < n_fields {
            let p = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + obj + ", " + (k * 8).to_string())
            qbe_store_heap_slot(g, slot_vals[k], p, slot_tys[k])
            k = k + 1
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
          qval(obj, TStruct(resolved_name, targs))
        }
      }
    }
    ETuple(elems, _) => {
      let vals : Array[String] = []
      let tys : Array[Ty] = []
      let mut mask = 0
      let mut i = 0
      while i < elems.length() {
        let ev = qbe_emit_expr(g, elems[i], None)
        vals.push(ev.reg)
        tys.push(ev.ty)
        if qbe_is_obj_ty(ev.ty) {
          mask = mask | (1 << i)
        }
        i = i + 1
      }
      let sz = if elems.length() == 0 { 8 } else { elems.length() * 8 }
      let drop_sym = qbe_register_slot_drop(g, mask)
      let obj = qbe_tmp(g)
      let alloc_fn = if elems.length() > 0 {
        "$m2_alloc_uninit"
      } else {
        "$m2_alloc"
      }
      qbe_emit(
        g,
        obj +
        " =l call " +
        alloc_fn +
        "(w " +
        sz.to_string() +
        ", w 4, l " +
        drop_sym +
        ")",
      )
      i = 0
      while i < vals.length() {
        let p = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + obj + ", " + (i * 8).to_string())
        qbe_store_heap_slot(g, vals[i], p, tys[i])
        i = i + 1
      }
      qval(obj, TTuple(tys))
    }
    EBlock(stmts, _) => {
      qbe_scope_push(g)
      let r = qbe_emit_stmts(g, stmts, expected)
      qbe_scope_pop(g)
      r
    }
    EIf(cond, then_stmts, else_opt, _) => {
      let l_then = qbe_lbl(g, "if_t")
      let l_else = qbe_lbl(g, "if_f")
      let l_end = qbe_lbl(g, "if_e")
      match else_opt {
        None => {
          qbe_emit_cond_branch(g, cond, l_then, l_end)
          qbe_emit_lbl(g, l_then)
          qbe_scope_push(g)
          let tv = qbe_emit_stmts(g, then_stmts, None)
          if !g.block_term {
            qbe_rc_dec(g, tv.reg, tv.ty)
          }
          qbe_scope_pop(g)
          qbe_emit_term(g, "jmp " + l_end)
          qbe_emit_lbl(g, l_end)
          qval("0", TUnit)
        }
        Some(el) => {
          qbe_emit_cond_branch(g, cond, l_then, l_else)
          qbe_emit_lbl(g, l_then)
          qbe_scope_push(g)
          let tv = qbe_emit_stmts(g, then_stmts, expected)
          let then_term = g.block_term
          let then_ty = match expected {
            Some(et) => et
            None => tv.ty
          }
          let mut res_slot = ""
          if !then_term {
            res_slot = qbe_alloc_slot_for(g, then_ty)
            qbe_store_local_slot(g, qbe_coerce_val(g, tv, then_ty), res_slot, then_ty)
          }
          qbe_scope_pop(g)
          qbe_emit_term(g, "jmp " + l_end)
          qbe_emit_lbl(g, l_else)
          qbe_scope_push(g)
          let ev = qbe_emit_expr(g, el, expected)
          let else_term = g.block_term
          let out_ty = match expected {
            Some(et) => et
            None =>
              if then_term {
                ev.ty
              } else {
                match tv.ty {
                  TNever => ev.ty
                  _ => tv.ty
                }
              }
          }
          if !else_term {
            if res_slot == "" {
              res_slot = qbe_alloc_slot_for(g, out_ty)
            }
            qbe_store_local_slot(g, qbe_coerce_val(g, ev, out_ty), res_slot, out_ty)
          }
          qbe_scope_pop(g)
          qbe_emit_term(g, "jmp " + l_end)
          qbe_emit_lbl(g, l_end)
          if then_term && else_term {
            qval("0", TNever)
          } else {
            let r = qbe_load_local_slot(g, res_slot, out_ty)
            qval(r, out_ty)
          }
        }
      }
    }
    EMatch(scrut, arms, sp) => {
      match qbe_try_emit_map_get_match(g, scrut, arms, expected) {
        Some(qv) => return qv
        None => ()
      }
      qbe_scope_push(g)
      let mut scrut_borrowed = false
      let mut sv = qval("0", TError)
      match scrut {
        EIdent(xname, _) =>
          match qbe_lookup_local(g, xname) {
            Some(loc) => {
              let mut reassigned = false
              let mut ai = 0
              while ai < arms.length() {
                if qbe_expr_assigns_ident(arms[ai].body, xname) {
                  reassigned = true
                  break
                }
                ai = ai + 1
              }
              if !reassigned {
                let r = qbe_load_local_slot(g, loc.slot, loc.ty)
                sv = qval(r, loc.ty)
                scrut_borrowed = true
              }
            }
            None => ()
          }
        _ => ()
      }
      if !scrut_borrowed {
        sv = qbe_emit_expr(g, scrut, None)
      }
      let scrut_loc = qbe_define_local(g, "__match_scrut", sv.ty, !scrut_borrowed)
      qbe_store_local_slot(g, sv.reg, scrut_loc.slot, sv.ty)
      let mut res_slot = ""
      let l_end = qbe_lbl(g, "match_end")
      let mut res_ty : Option[Ty] = expected
      let mut i = 0
      while i < arms.length() {
        let arm = arms[i]
        let l_next = qbe_lbl(g, "match_next")
        let cur_sv = qbe_load_local_slot(g, scrut_loc.slot, sv.ty)
        qbe_emit_pat_test(g, arm.pat, cur_sv, sv.ty, l_next)
        qbe_scope_push(g)
        let bind_sv = qbe_load_local_slot(g, scrut_loc.slot, sv.ty)
        qbe_emit_pat_bind(g, arm.pat, bind_sv, sv.ty, scrut_borrowed, arm.body)
        let bv = qbe_emit_expr(g, arm.body, res_ty)
        match res_ty {
          None =>
            match bv.ty {
              TNever => ()
              _ => res_ty = Some(bv.ty)
            }
          Some(_) => ()
        }
        if !g.block_term {
          let store_ty = match res_ty {
            Some(t) => t
            None => bv.ty
          }
          if res_slot == "" {
            res_slot = qbe_alloc_slot_for(g, store_ty)
          }
          qbe_store_local_slot(g, qbe_coerce_val(g, bv, store_ty), res_slot, store_ty)
        }
        qbe_scope_pop(g)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_next)
        i = i + 1
      }
      let file_id = qbe_intern_cstring(g, sp.file)
      let msg_id = qbe_intern_cstring(g, "non-exhaustive match")
      qbe_emit(
        g,
        "call $m2_panic(l $m2_cstr_" +
        msg_id.to_string() +
        ", l $m2_cstr_" +
        file_id.to_string() +
        ", w " +
        sp.line.to_string() +
        ")",
      )
      qbe_emit_term(g, "jmp " + l_end)
      qbe_emit_lbl(g, l_end)
      qbe_scope_pop(g)
      let final_ty = match res_ty {
        Some(t) => t
        None => TUnit
      }
      if res_slot == "" {
        qval(qbe_zero_reg(final_ty), final_ty)
      } else {
        let r = qbe_load_local_slot(g, res_slot, final_ty)
        qval(r, final_ty)
      }
    }
    EClosure(params, ret_te, body, _) => {
      let cres = qbe_emit_closure_obj(g, params, ret_te, body, false)
      qval(cres.env, cres.ty)
    }
    EScope(w_expr, f_expr, _) => {
      let wv = qbe_emit_expr(g, w_expr, Some(TWorld))
      qbe_rc_dec(g, wv.reg, wv.ty)
      let sc = qbe_tmp(g)
      qbe_emit(g, sc + " =l call $m2_scope_begin()")
      match f_expr {
        EClosure(params, _, body, _) => {
          qbe_scope_push(g)
          if params.length() >= 1 {
            let sloc = qbe_define_local(g, params[0].name, TScope, false)
            qbe_emit(g, "storel " + sc + ", " + sloc.slot)
          }
          let bv = qbe_emit_stmts(g, body, Some(TUnit))
          if !g.block_term {
            qbe_rc_dec(g, bv.reg, bv.ty)
          }
          qbe_scope_pop(g)
        }
        _ => {
          let fv = qbe_emit_expr(g, f_expr, Some(TFn([TScope], TUnit)))
          qbe_emit(g, "call $m2_rc_inc(l " + sc + ")")
          let _ = qbe_emit_closure_call(g, fv.reg, [sc], [TScope])
        }
      }
      qbe_emit(g, "call $m2_scope_end(l " + sc + ")")
      qval("0", TUnit)
    }
    ESpawn(s_expr, f_expr, _) => {
      let sv = qbe_emit_expr(g, s_expr, Some(TScope))
      match f_expr {
        EClosure(params, ret_te, body, _) => {
          let cres = qbe_emit_closure_obj(g, params, ret_te, body, true)
          qbe_emit(
            g,
            "call $m2_scope_spawn(l " +
            sv.reg +
            ", l " +
            cres.fn_sym +
            ", l " +
            cres.env +
            ")",
          )
          qbe_emit(g, "call $m2_rc_dec(l " + cres.env + ")")
        }
        _ => {
          let fv = qbe_emit_expr(g, f_expr, Some(TFn([], TUnit)))
          let fn_ptr = qbe_tmp(g)
          qbe_emit(g, fn_ptr + " =l loadl " + fv.reg)
          qbe_emit(
            g,
            "call $m2_scope_spawn(l " + sv.reg + ", l " + fn_ptr + ", l " + fv.reg + ")",
          )
          qbe_emit(g, "call $m2_rc_dec(l " + fv.reg + ")")
        }
      }
      qbe_rc_dec(g, sv.reg, sv.ty)
      qval("0", TUnit)
    }
  }
}

///|
fn qbe_try_emit_borrowed_arr_elem_let(
  g : QbeGen,
  stmts : Array[Stmt],
  idx : Int,
) -> Bool {
  match stmts[idx] {
    SLet(bname, is_mut, ty_expr, EIndex(EIdent(aname, _), idx_expr, _), _) => {
      if is_mut || bname == "_" || bname == aname || qbe_expr_has_assign(idx_expr) {
        return false
      }
      match qbe_lookup_local(g, aname) {
        Some(aloc) =>
          match aloc.ty {
            TArray(elem) => {
              if !qbe_is_obj_ty(elem) {
                return false
              }
              if !qbe_arr_is_stable_stmts(stmts, idx + 1, aname, false) {
                return false
              }
              if !qbe_ident_is_borrow_safe_stmts(g, stmts, idx + 1, bname) {
                return false
              }
              let final_ty = match ty_expr {
                TyMissing(_) => elem
                _ => resolve_type_expr(g.tc, ty_expr, g.cur_tparams)
              }
              let arr_reg = if g.hoisted_arr_len.contains(aname) &&
                g.hoisted_arr_dp.contains(aname) {
                "0"
              } else {
                let r = qbe_tmp(g)
                qbe_emit(g, r + " =l loadl " + aloc.slot)
                r
              }
              let iv = qbe_emit_expr(g, idx_expr, Some(TInt))
              let il = qbe_as_l(g, iv)
              let bce_safe = qbe_bce_expr_is_safe(g, aname, idx_expr)
              if !bce_safe {
                let alen = match g.hoisted_arr_len.get(aname) {
                  Some(hlen) => hlen
                  None => {
                    let t = qbe_tmp(g)
                    qbe_emit(g, t + " =l loadl " + arr_reg)
                    t
                  }
                }
                let oob = qbe_tmp(g)
                let l_oob = qbe_lbl(g, "arr_oob")
                let l_ok = qbe_lbl(g, "arr_ok")
                qbe_emit(g, oob + " =w cugel " + il + ", " + alen)
                qbe_emit_term(g, "jnz " + oob + ", " + l_oob + ", " + l_ok)
                qbe_emit_lbl(g, l_oob)
                qbe_emit(g, "call $m2_panic_oob(l " + il + ", l " + alen + ")")
                qbe_emit_term(g, "hlt")
                qbe_emit_lbl(g, l_ok)
              }
              let dp = match g.hoisted_arr_dp.get(aname) {
                Some(hdp) => hdp
                None => {
                  let dp_p = qbe_tmp(g)
                  let t = qbe_tmp(g)
                  qbe_emit(g, dp_p + " =l add " + arr_reg + ", 24")
                  qbe_emit(g, t + " =l loadl " + dp_p)
                  t
                }
              }
              let off = qbe_tmp(g)
              let ep = qbe_tmp(g)
              qbe_emit(g, off + " =l shl " + il + ", 3")
              qbe_emit(g, ep + " =l add " + dp + ", " + off)
              let r = qbe_load_heap_slot(g, ep, elem)
              let loc = qbe_define_local(g, bname, final_ty, false)
              qbe_store_local_slot(g, qbe_coerce_val(g, qval(r, elem), final_ty), loc.slot, final_ty)
              true
            }
            _ => false
          }
        None => false
      }
    }
    _ => false
  }
}

///|
fn qbe_try_emit_while_bce_versioned(
  g : QbeGen,
  cond : Expr,
  body : Array[Stmt],
) -> Bool {
  if body.length() == 0 || body.length() > 16 || qbe_stmts_has_nested_loop(body) {
    return false
  }
  let mut iv = ""
  let mut bound_is_lit = false
  let mut bound_lit = 0L
  let mut bound_name = ""
  match cond {
    EBinary("<", EIdent(iv_n, _), bound_e, _) => {
      iv = iv_n
      match bound_e {
        EInt(raw, _) => {
          bound_is_lit = true
          bound_lit = qbe_parse_int64_lit(raw).to_int().to_int64()
        }
        EIdent(bn, _) => bound_name = bn
        _ => return false
      }
    }
    _ => return false
  }
  let iv_slot = match qbe_lookup_local(g, iv) {
    Some(iloc) =>
      if qbe_is_int32_ty(iloc.ty) {
        iloc.slot
      } else {
        return false
      }
    None => return false
  }
  if !qbe_stmt_is_inc_by_one(body[body.length() - 1], iv) {
    return false
  }
  let mut bi = 0
  while bi < body.length() - 1 {
    if qbe_stmt_assigns_ident(body[bi], iv) || qbe_stmt_rebinds_ident(body[bi], iv) {
      return false
    }
    bi = bi + 1
  }
  let mut bound_slot = ""
  if !bound_is_lit {
    if bound_name == iv ||
      qbe_stmts_assigns_ident(body, bound_name) ||
      qbe_stmts_rebinds_ident(body, bound_name) {
      return false
    }
    match qbe_lookup_local(g, bound_name) {
      Some(bloc) =>
        if qbe_is_int32_ty(bloc.ty) {
          bound_slot = bloc.slot
        } else {
          return false
        }
      None => return false
    }
  }
  let guards : Array[QbeBceGuard] = []
  let seen : Map[String, Bool] = Map([])
  qbe_collect_bce_guards_stmts(g, body, iv, body, guards, seen)
  if guards.length() == 0 {
    return false
  }

  let l_vchk = qbe_lbl(g, "wh_vchk")
  let l_fast = qbe_lbl(g, "wh_fast")
  let l_fcond = qbe_lbl(g, "wh_fc")
  let l_slow = qbe_lbl(g, "wh_slow")
  let l_scond = qbe_lbl(g, "wh_sc")
  let l_end = qbe_lbl(g, "wh_e")

  // Entry check: iv0 < bound (0 iterations -> skip directly to @wh_e)
  let iv0_w = qbe_tmp(g)
  qbe_emit(g, iv0_w + " =w loadsw " + iv_slot)
  let bnd_w = if bound_is_lit {
    bound_lit.to_string()
  } else {
    let bw = qbe_tmp(g)
    qbe_emit(g, bw + " =w loadsw " + bound_slot)
    bw
  }
  let enter_ok = qbe_tmp(g)
  qbe_emit(g, enter_ok + " =w csltw " + iv0_w + ", " + bnd_w)
  qbe_emit_term(g, "jnz " + enter_ok + ", " + l_vchk + ", " + l_end)

  // Single-branch 64-bit pre-loop bounds guard
  qbe_emit_lbl(g, l_vchk)
  let iv0_l = qbe_tmp(g)
  qbe_emit(g, iv0_l + " =l extsw " + iv0_w)
  let bnd_l = if bound_is_lit {
    let bl = qbe_tmp(g)
    qbe_emit(g, bl + " =l copy " + bound_lit.to_string())
    bl
  } else {
    let bl = qbe_tmp(g)
    qbe_emit(g, bl + " =l extsw " + bnd_w)
    bl
  }
  let mut all_ok = qbe_tmp(g)
  qbe_emit(g, all_ok + " =w csgel " + iv0_l + ", 0")
  let mut gi = 0
  while gi < guards.length() {
    let gd = guards[gi]
    let alen = match g.hoisted_arr_len.get(gd.arr) {
      Some(hl) => hl
      None => "0"
    }
    if gd.kind == 0 {
      let c1 = qbe_tmp(g)
      let nxt = qbe_tmp(g)
      qbe_emit(g, c1 + " =w cslel " + bnd_l + ", " + alen)
      qbe_emit(g, nxt + " =w and " + all_ok + ", " + c1)
      all_ok = nxt
    } else if gd.kind == 1 {
      let bc = qbe_tmp(g)
      let c_ov = qbe_tmp(g)
      let c_len = qbe_tmp(g)
      let t1 = qbe_tmp(g)
      let nxt = qbe_tmp(g)
      qbe_emit(g, bc + " =l add " + bnd_l + ", " + gd.offset.to_string())
      qbe_emit(g, c_ov + " =w cslel " + bc + ", 2147483648")
      qbe_emit(g, c_len + " =w cslel " + bc + ", " + alen)
      qbe_emit(g, t1 + " =w and " + c_ov + ", " + c_len)
      qbe_emit(g, nxt + " =w and " + all_ok + ", " + t1)
      all_ok = nxt
    } else {
      let v_slot = match qbe_lookup_local(g, gd.vname) {
        Some(vloc) => vloc.slot
        None => ""
      }
      let vw = qbe_tmp(g)
      let vl = qbe_tmp(g)
      let vmb = qbe_tmp(g)
      let vmin = qbe_tmp(g)
      let vmax = qbe_tmp(g)
      let c_lo = qbe_tmp(g)
      let c_hi = qbe_tmp(g)
      let t1 = qbe_tmp(g)
      let nxt = qbe_tmp(g)
      qbe_emit(g, vw + " =w loadsw " + v_slot)
      qbe_emit(g, vl + " =l extsw " + vw)
      qbe_emit(g, vmb + " =l sub " + vl + ", " + bnd_l)
      qbe_emit(g, vmin + " =l add " + vmb + ", 1")
      qbe_emit(g, vmax + " =l sub " + vl + ", " + iv0_l)
      qbe_emit(g, c_lo + " =w csgel " + vmin + ", 0")
      qbe_emit(g, c_hi + " =w csltl " + vmax + ", " + alen)
      qbe_emit(g, t1 + " =w and " + c_lo + ", " + c_hi)
      qbe_emit(g, nxt + " =w and " + all_ok + ", " + t1)
      all_ok = nxt
    }
    gi = gi + 1
  }
  qbe_emit_term(g, "jnz " + all_ok + ", " + l_fast + ", " + l_slow)

  // Fast bottom-tested loop (zero OOB checks on versioned accesses)
  let added_keys : Array[String] = []
  gi = 0
  while gi < guards.length() {
    let k = guards[gi].key
    if !g.bce_safe_exprs.contains(k) {
      g.bce_safe_exprs.set(k, true)
      added_keys.push(k)
    }
    gi = gi + 1
  }
  qbe_emit_lbl(g, l_fast)
  let loop_depth = g.scopes.length()
  g.loop_breaks.push(l_end)
  g.loop_conts.push(l_fcond)
  g.loop_depths.push(loop_depth)
  qbe_scope_push(g)
  let fbv = qbe_emit_stmts(g, body, None)
  if !g.block_term {
    qbe_rc_dec(g, fbv.reg, fbv.ty)
  }
  qbe_scope_pop(g)
  let _ = g.loop_breaks.pop()
  let _ = g.loop_conts.pop()
  let _ = g.loop_depths.pop()
  qbe_emit_term(g, "jmp " + l_fcond)
  qbe_emit_lbl(g, l_fcond)
  qbe_emit_cond_branch(g, cond, l_fast, l_end)

  // Clear fast-path BCE keys before emitting slow path
  let mut ki = 0
  while ki < added_keys.length() {
    g.bce_safe_exprs.remove(added_keys[ki])
    ki = ki + 1
  }

  // Slow bottom-tested loop (full OOB checks preserved)
  qbe_emit_lbl(g, l_slow)
  g.loop_breaks.push(l_end)
  g.loop_conts.push(l_scond)
  g.loop_depths.push(loop_depth)
  qbe_scope_push(g)
  let sbv = qbe_emit_stmts(g, body, None)
  if !g.block_term {
    qbe_rc_dec(g, sbv.reg, sbv.ty)
  }
  qbe_scope_pop(g)
  let _ = g.loop_breaks.pop()
  let _ = g.loop_conts.pop()
  let _ = g.loop_depths.pop()
  qbe_emit_term(g, "jmp " + l_scond)
  qbe_emit_lbl(g, l_scond)
  qbe_emit_cond_branch(g, cond, l_slow, l_end)

  qbe_emit_lbl(g, l_end)
  true
}

///|
fn qbe_try_emit_while_field_promoted(
  g : QbeGen,
  cond : Expr,
  body : Array[Stmt],
) -> Bool {
  if body.length() == 0 ||
    !qbe_is_pure_small_cond(cond, 12) ||
    !qbe_loop_has_no_calls_expr(cond) ||
    !qbe_loop_has_no_calls_stmts(body) ||
    qbe_stmts_has_nested_loop(body) ||
    qbe_stmts_has_cf(body, true, true, true) {
    return false
  }
  let write_vars : Array[String] = []
  let write_fields : Array[String] = []
  let read_vars : Array[String] = []
  let read_fields : Array[String] = []
  let all_vars : Array[String] = []
  let seen_all : Map[String, Bool] = Map([])
  if !qbe_collect_field_access_stmts(
    body,
    write_vars,
    write_fields,
    read_vars,
    read_fields,
    all_vars,
    seen_all,
  ) {
    return false
  }
  if write_vars.length() == 0 {
    return false
  }
  // Find an outer struct variable `b` with at least one primitive field both read and written
  let mut b_name = ""
  let mut b_slot = ""
  let mut b_sname = ""
  let mut b_sargs : Array[Ty] = []
  let mut wi = 0
  while wi < write_vars.length() {
    let cand = write_vars[wi]
    if !qbe_expr_assigns_ident(cond, cand) &&
      !qbe_stmts_assigns_ident(body, cand) &&
      !qbe_expr_rebinds_ident(cond, cand) &&
      !qbe_stmts_rebinds_ident(body, cand) {
      match qbe_lookup_local(g, cand) {
        Some(loc) =>
          match loc.ty {
            TStruct(sn, sa) => {
              b_name = cand
              b_slot = loc.slot
              b_sname = sn
              b_sargs = sa
              break
            }
            _ => ()
          }
        None => ()
      }
    }
    wi = wi + 1
  }
  if b_name == "" {
    return false
  }
  // Check all other variables with field accesses in `body`: must be at most 1 (`b2`)
  let mut has_b2 = false
  let mut b2_name = ""
  let mut ai = 0
  while ai < all_vars.length() {
    let vn = all_vars[ai]
    if vn != b_name {
      if has_b2 {
        return false
      }
      has_b2 = true
      b2_name = vn
    }
    ai = ai + 1
  }
  let mut b2_idx = -1
  if has_b2 {
    if qbe_stmts_assigns_ident(body, b2_name) {
      return false
    }
    let mut b2_count = 0
    let mut si = 0
    while si < body.length() {
      match body[si] {
        SLet(ln, is_mut, _, init, _) =>
          if ln == b2_name {
            if is_mut || qbe_expr_has_assign(init) {
              return false
            }
            b2_idx = si
            b2_count = b2_count + 1
          }
        _ => ()
      }
      si = si + 1
    }
    if b2_count != 1 || b2_idx < 0 {
      return false
    }
    // Ensure body[0 .. b2_idx - 1] has only pure SLet with no assignments, and b2 is not rebound later
    si = 0
    while si < b2_idx {
      match body[si] {
        SLet(_, _, _, init, _) =>
          if qbe_expr_has_assign(init) {
            return false
          }
        _ => return false
      }
      si = si + 1
    }
    si = b2_idx + 1
    while si < body.length() {
      if qbe_stmt_rebinds_ident(body[si], b2_name) {
        return false
      }
      si = si + 1
    }
    // Also ensure body[0 .. b2_idx] does not read any field of `b_name`
    let pre_wvars : Array[String] = []
    let pre_wfields : Array[String] = []
    let pre_rvars : Array[String] = []
    let pre_rfields : Array[String] = []
    let pre_all : Array[String] = []
    let pre_seen : Map[String, Bool] = Map([])
    si = 0
    while si <= b2_idx {
      let _ = qbe_collect_field_access_stmt(
        body[si],
        pre_wvars,
        pre_wfields,
        pre_rvars,
        pre_rfields,
        pre_all,
        pre_seen,
      )
      si = si + 1
    }
    if pre_seen.contains(b_name) {
      return false
    }
  }
  // Collect promotable primitive fields of `b_name` (both read and written)
  let sinfo = match g.tc.structs.get(b_sname) {
    Some(si) => si
    None => return false
  }
  let subst = make_subst(sinfo.decl.type_params, b_sargs)
  let prom_fields : Array[QbePromField] = []
  let prom_seen : Map[String, Bool] = Map([])
  wi = 0
  while wi < write_vars.length() {
    if write_vars[wi] == b_name {
      let fname = write_fields[wi]
      let pkey = b_name + "." + fname
      if !prom_seen.contains(fname) &&
        !g.promoted_fields.contains(pkey) &&
        !g.hoisted_fields.contains(pkey) {
        // Must also be read on `b_name`
        let mut is_read = false
        let mut ri = 0
        while ri < read_vars.length() {
          if read_vars[ri] == b_name && read_fields[ri] == fname {
            is_read = true
            break
          }
          ri = ri + 1
        }
        if is_read {
          let mut fi = 0
          while fi < sinfo.field_names.length() {
            if sinfo.field_names[fi] == fname {
              let fty = subst_ty(sinfo.field_tys[fi], subst)
              let is_prom_ty = match fty {
                TDouble | TInt | TInt64 => true
                _ => false
              }
              if is_prom_ty {
                prom_seen.set(fname, true)
                prom_fields.push(QbePromField::{
                  name: fname,
                  field_idx: fi,
                  ty: fty,
                })
              }
              break
            }
            fi = fi + 1
          }
        }
      }
    }
    wi = wi + 1
  }
  if prom_fields.length() == 0 {
    return false
  }

  let l_init = qbe_lbl(g, "wh_pinit")
  let l_fast = qbe_lbl(g, "wh_pb")
  let l_wb = qbe_lbl(g, "wh_pwb")
  let l_end = qbe_lbl(g, "wh_e")
  let l_cont = if has_b2 { qbe_lbl(g, "wh_pc") } else { "" }
  let l_bail = if has_b2 { qbe_lbl(g, "wh_pbail") } else { "" }
  let l_slow = if has_b2 { qbe_lbl(g, "wh_pslow") } else { "" }

  // Entry guard
  qbe_emit_cond_branch(g, cond, l_init, l_end)

  // Pre-loop promotion init: load b_ptr and initial field values into local slots
  qbe_emit_lbl(g, l_init)
  let b_ptr = qbe_tmp(g)
  qbe_emit(g, b_ptr + " =l loadl " + b_slot)
  let slots : Array[String] = []
  let mut pi = 0
  while pi < prom_fields.length() {
    let pf = prom_fields[pi]
    let slot = qbe_alloc_slot_for(g, pf.ty)
    slots.push(slot)
    let fp = qbe_tmp(g)
    qbe_emit(g, fp + " =l add " + b_ptr + ", " + (pf.field_idx * 8).to_string())
    let fv = qbe_load_heap_slot(g, fp, pf.ty)
    qbe_store_local_slot(g, fv, slot, pf.ty)
    pi = pi + 1
  }
  qbe_emit_term(g, "jmp " + l_fast)

  // Activate promoted field mappings for the fast loop
  pi = 0
  while pi < prom_fields.length() {
    let pf = prom_fields[pi]
    let pkey = b_name + "." + pf.name
    g.promoted_fields.set(pkey, slots[pi])
    g.promoted_field_tys.set(pkey, pf.ty)
    pi = pi + 1
  }

  // Fast bottom-tested loop
  qbe_emit_lbl(g, l_fast)
  qbe_scope_push(g)
  let bail_locals : Array[QbeLocal] = []
  if has_b2 {
    let mut si = 0
    while si <= b2_idx {
      if g.block_term {
        break
      }
      let is_last = si == body.length() - 1
      if !is_last && qbe_try_emit_borrowed_arr_elem_let(g, body, si) {
        si = si + 1
        continue
      }
      let sv = qbe_emit_stmt(g, body[si], None, is_last)
      if !g.block_term {
        qbe_rc_dec(g, sv.reg, sv.ty)
      }
      si = si + 1
    }
    // Snapshot scope locals bound in body[0 .. b2_idx] for alias bailout cleanup
    let cur_sc = g.scopes[g.scopes.length() - 1]
    let mut li = 0
    while li < cur_sc.locals.length() {
      bail_locals.push(cur_sc.locals[li])
      li = li + 1
    }
    let b2_slot = match qbe_lookup_local(g, b2_name) {
      Some(b2loc) => b2loc.slot
      None => ""
    }
    let b2_ptr = qbe_tmp(g)
    let is_alias = qbe_tmp(g)
    qbe_emit(g, b2_ptr + " =l loadl " + b2_slot)
    qbe_emit(g, is_alias + " =w ceql " + b_ptr + ", " + b2_ptr)
    qbe_emit_term(g, "jnz " + is_alias + ", " + l_bail + ", " + l_cont)
    qbe_emit_lbl(g, l_cont)
    si = b2_idx + 1
    while si < body.length() {
      if g.block_term {
        break
      }
      let is_last = si == body.length() - 1
      if !is_last && qbe_try_emit_borrowed_arr_elem_let(g, body, si) {
        si = si + 1
        continue
      }
      let sv = qbe_emit_stmt(g, body[si], None, is_last)
      if !g.block_term {
        qbe_rc_dec(g, sv.reg, sv.ty)
      }
      si = si + 1
    }
  } else {
    let bv = qbe_emit_stmts(g, body, None)
    if !g.block_term {
      qbe_rc_dec(g, bv.reg, bv.ty)
    }
  }
  qbe_scope_pop(g)
  qbe_emit_cond_branch(g, cond, l_fast, l_wb)

  // Clear promoted field mappings
  pi = 0
  while pi < prom_fields.length() {
    let pkey = b_name + "." + prom_fields[pi].name
    g.promoted_fields.remove(pkey)
    g.promoted_field_tys.remove(pkey)
    pi = pi + 1
  }

  // Normal exit writeback
  qbe_emit_lbl(g, l_wb)
  pi = 0
  while pi < prom_fields.length() {
    let pf = prom_fields[pi]
    let v = qbe_load_local_slot(g, slots[pi], pf.ty)
    let fp = qbe_tmp(g)
    qbe_emit(g, fp + " =l add " + b_ptr + ", " + (pf.field_idx * 8).to_string())
    qbe_store_heap_slot(g, v, fp, pf.ty)
    pi = pi + 1
  }
  qbe_emit_term(g, "jmp " + l_end)

  // Cold alias bailout + unpromoted slow loop
  if has_b2 {
    qbe_emit_lbl(g, l_bail)
    qbe_release_scope_locals(g, QbeScope::{ locals: bail_locals })
    pi = 0
    while pi < prom_fields.length() {
      let pf = prom_fields[pi]
      let v = qbe_load_local_slot(g, slots[pi], pf.ty)
      let fp = qbe_tmp(g)
      qbe_emit(g, fp + " =l add " + b_ptr + ", " + (pf.field_idx * 8).to_string())
      qbe_store_heap_slot(g, v, fp, pf.ty)
      pi = pi + 1
    }
    qbe_emit_term(g, "jmp " + l_slow)

    qbe_emit_lbl(g, l_slow)
    qbe_scope_push(g)
    let sbv = qbe_emit_stmts(g, body, None)
    if !g.block_term {
      qbe_rc_dec(g, sbv.reg, sbv.ty)
    }
    qbe_scope_pop(g)
    qbe_emit_cond_branch(g, cond, l_slow, l_end)
  }

  qbe_emit_lbl(g, l_end)
  true
}

///|
fn qbe_is_ident_plus_minus_one(base : String, other : Expr) -> Bool {
  match other {
    EBinary("+", EIdent(x, _), EInt(raw, _), _) =>
      x == base && qbe_parse_int64_lit(raw) == 1L
    EBinary("+", EInt(raw, _), EIdent(x, _), _) =>
      x == base && qbe_parse_int64_lit(raw) == 1L
    EBinary("-", EIdent(x, _), EInt(raw, _), _) =>
      x == base && qbe_parse_int64_lit(raw) == 1L
    _ => false
  }
}

///|
fn qbe_are_consecutive_int_exprs(l : Expr, r : Expr) -> Bool {
  match l {
    EIdent(x, _) =>
      if qbe_is_ident_plus_minus_one(x, r) {
        return true
      }
    _ => ()
  }
  match r {
    EIdent(x, _) => qbe_is_ident_plus_minus_one(x, l)
    _ => false
  }
}

///|
fn qbe_expr_is_even_int(e : Expr) -> Bool {
  match e {
    EInt(raw, _) => (qbe_parse_int64_lit(raw) & 1L) == 0L
    EUnary("-", inner, _) | EMove(inner, _) => qbe_expr_is_even_int(inner)
    EBinary("*", l, r, _) =>
      qbe_expr_is_even_int(l) ||
      qbe_expr_is_even_int(r) ||
      qbe_are_consecutive_int_exprs(l, r)
    EBinary("<<", _, EInt(raw, _), _) => {
      let sh = qbe_parse_int64_lit(raw)
      sh >= 1L && sh <= 31L
    }
    EBinary("+", l, r, _) | EBinary("-", l, r, _) =>
      qbe_expr_is_even_int(l) && qbe_expr_is_even_int(r)
    _ => false
  }
}

///|
fn qbe_expr_is_pure_arith(e : Expr) -> Bool {
  match e {
    EInt(_, _)
    | EInt64(_, _)
    | EDouble(_, _)
    | EBool(_, _)
    | EByte(_, _)
    | EChar(_, _)
    | EIdent(_, _) => true
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_expr_is_pure_arith(inner)
    EBinary(op, l, r, _) =>
      if op == "/" || op == "%" {
        false
      } else {
        qbe_expr_is_pure_arith(l) && qbe_expr_is_pure_arith(r)
      }
    _ => false
  }
}

///|
fn qbe_expr_bare_reads_ident(e : Expr, name : String) -> Bool {
  match e {
    EIdent(n, _) => n == name
    EBinary("*", EIdent(a, _), EIdent(b, _), _) =>
      if a == name && b == name {
        false
      } else {
        a == name || b == name
      }
    EBinary(_, l, r, _) =>
      qbe_expr_bare_reads_ident(l, name) || qbe_expr_bare_reads_ident(r, name)
    EUnary(_, inner, _) | EMove(inner, _) | EAs(inner, _, _) =>
      qbe_expr_bare_reads_ident(inner, name)
    _ => false
  }
}

///|
fn qbe_try_emit_while_sq_reuse(
  g : QbeGen,
  cond : Expr,
  body : Array[Stmt],
) -> Bool {
  if body.length() < 2 ||
    !qbe_loop_has_no_calls_expr(cond) ||
    !qbe_loop_has_no_calls_stmts(body) ||
    qbe_stmts_has_nested_loop(body) ||
    qbe_stmts_has_cf(body, false, true, false) {
    return false
  }
  let cands : Array[QbeSqCand] = []
  let seen : Map[String, Bool] = Map([])
  let mut si = 0
  while si < body.length() {
    match body[si] {
      SAssign(EIdent(vname, _), rhs, _) =>
        if !seen.contains(vname) &&
          !g.sq_reuse_slot.contains(vname) &&
          !qbe_expr_mentions_ident(cond, vname) &&
          !qbe_stmts_rebinds_ident(body, vname) &&
          !qbe_expr_assigns_ident(rhs, vname) &&
          qbe_stmts_count_assigns_ident(body, vname) == 1 {
          match qbe_lookup_local(g, vname) {
            Some(vloc) =>
              if qbe_is_double_ty(vloc.ty) {
                // Must have v * v in body[0 .. si - 1]
                let mut has_before = false
                let mut bi = 0
                while bi < si {
                  if qbe_stmt_has_sq(body[bi], vname) {
                    has_before = true
                    break
                  }
                  bi = bi + 1
                }
                if has_before {
                  // Must have an unconditionally-executed v * v in body[si + 1 .. len - 1]
                  // with no earlier branch-only v * v and no earlier break/return
                  let mut has_after = false
                  let mut ok_after = true
                  let mut ai = si + 1
                  while ai < body.length() {
                    if qbe_stmt_uncond_has_sq(body[ai], vname) {
                      has_after = true
                      break
                    }
                    if qbe_stmt_has_branch_sq(body[ai], vname) ||
                      qbe_stmt_has_cf(body[ai], true, true, true) {
                      ok_after = false
                      break
                    }
                    ai = ai + 1
                  }
                  if has_after && ok_after {
                    seen.set(vname, true)
                    cands.push(QbeSqCand::{
                      name: vname,
                      assign_idx: si,
                    })
                  }
                }
              }
            None => ()
          }
        }
      _ => ()
    }
    si = si + 1
  }
  if cands.length() == 0 {
    return false
  }

  let rotated = qbe_is_pure_small_cond(cond, 12)
  let l_init = qbe_lbl(g, "wh_sqi")
  let l_body = qbe_lbl(g, "wh_b")
  let l_cond = qbe_lbl(g, "wh_c")
  let l_end = qbe_lbl(g, "wh_e")

  if rotated {
    qbe_emit_cond_branch(g, cond, l_init, l_end)
    qbe_emit_lbl(g, l_init)
  }
  let mut ci = 0
  while ci < cands.length() {
    let cname = cands[ci].name
    let cslot = match qbe_lookup_local(g, cname) {
      Some(cloc) => cloc.slot
      None => ""
    }
    let sq_slot = qbe_alloc_slot_for(g, TDouble)
    let v0 = qbe_tmp(g)
    let sq0 = qbe_tmp(g)
    qbe_emit(g, v0 + " =d loadd " + cslot)
    qbe_emit(g, sq0 + " =d mul " + v0 + ", " + v0)
    qbe_emit(g, "stored " + sq0 + ", " + sq_slot)
    g.sq_reuse_slot.set(cname, sq_slot)
    g.sq_reuse_state.set(cname, 1)
    ci = ci + 1
  }

  if rotated {
    qbe_emit_term(g, "jmp " + l_body)
  } else {
    qbe_emit_term(g, "jmp " + l_cond)
    qbe_emit_lbl(g, l_cond)
    qbe_emit_cond_branch(g, cond, l_body, l_end)
  }

  // Reorder adjacent pure immutable `let` statements before the first candidate
  // assignment so statements that bare-read an old candidate variable run before
  // statements that only use its precomputed square, shortening live ranges.
  let eff_body : Array[Stmt] = []
  let mut bi = 0
  while bi < body.length() {
    eff_body.push(body[bi])
    bi = bi + 1
  }
  let mut min_assign = body.length()
  ci = 0
  while ci < cands.length() {
    if cands[ci].assign_idx < min_assign {
      min_assign = cands[ci].assign_idx
    }
    ci = ci + 1
  }
  let mut ri = 0
  while ri + 1 < min_assign {
    let mut do_swap = false
    match eff_body[ri] {
      SLet(n0, false, _, e0, _) =>
        match eff_body[ri + 1] {
          SLet(n1, false, _, e1, _) =>
            if n0 != n1 &&
              qbe_expr_is_pure_arith(e0) &&
              qbe_expr_is_pure_arith(e1) &&
              !qbe_expr_mentions_ident(e1, n0) &&
              !qbe_expr_mentions_ident(e0, n1) {
              let mut e0_bare = false
              let mut e1_bare = false
              let mut k = 0
              while k < cands.length() {
                let cn = cands[k].name
                if qbe_expr_bare_reads_ident(e0, cn) {
                  e0_bare = true
                }
                if qbe_expr_bare_reads_ident(e1, cn) {
                  e1_bare = true
                }
                k = k + 1
              }
              if !e0_bare && e1_bare {
                do_swap = true
              }
            }
          _ => ()
        }
      _ => ()
    }
    if do_swap {
      let tmp = eff_body[ri]
      eff_body[ri] = eff_body[ri + 1]
      eff_body[ri + 1] = tmp
      ri = ri + 2
    } else {
      ri = ri + 1
    }
  }

  qbe_emit_lbl(g, l_body)
  let loop_depth = g.scopes.length()
  g.loop_breaks.push(l_end)
  g.loop_conts.push(l_cond)
  g.loop_depths.push(loop_depth)
  qbe_scope_push(g)
  si = 0
  while si < eff_body.length() {
    if g.block_term {
      break
    }
    let is_last = si == eff_body.length() - 1
    if !is_last && qbe_try_emit_borrowed_arr_elem_let(g, eff_body, si) {
      si = si + 1
      continue
    }
    let sv = qbe_emit_stmt(g, eff_body[si], None, is_last)
    if !g.block_term {
      qbe_rc_dec(g, sv.reg, sv.ty)
    }
    // After emitting assign_idx for a candidate, switch it to SqUpdate (state 2)
    ci = 0
    while ci < cands.length() {
      if cands[ci].assign_idx == si {
        g.sq_reuse_state.set(cands[ci].name, 2)
      }
      ci = ci + 1
    }
    si = si + 1
  }
  qbe_scope_pop(g)
  let _ = g.loop_breaks.pop()
  let _ = g.loop_conts.pop()
  let _ = g.loop_depths.pop()
  qbe_emit_term(g, "jmp " + l_cond)
  if rotated {
    qbe_emit_lbl(g, l_cond)
    qbe_emit_cond_branch(g, cond, l_body, l_end)
  }
  qbe_emit_lbl(g, l_end)

  ci = 0
  while ci < cands.length() {
    g.sq_reuse_slot.remove(cands[ci].name)
    g.sq_reuse_state.remove(cands[ci].name)
    ci = ci + 1
  }
  true
}

///|
fn qbe_emit_stmts(
  g : QbeGen,
  stmts : Array[Stmt],
  expected : Option[Ty],
) -> QbeVal {
  if stmts.length() == 0 {
    return qval("0", TUnit)
  }
  let mut i = 0
  let mut last = qval("0", TUnit)
  while i < stmts.length() {
    if g.block_term {
      break
    }
    let is_last = i == stmts.length() - 1
    if !is_last && qbe_try_emit_borrowed_arr_elem_let(g, stmts, i) {
      last = qval("0", TUnit)
      i = i + 1
      continue
    }
    let exp = if is_last { expected } else { None }
    last = qbe_emit_stmt(g, stmts[i], exp, is_last)
    i = i + 1
  }
  last
}

///|
fn qbe_emit_stmt(
  g : QbeGen,
  stmt : Stmt,
  expected : Option[Ty],
  is_tail : Bool,
) -> QbeVal {
  match stmt {
    SLet(name, is_mut, ty_expr, init, _) => {
      let ann_opt : Option[Ty] = match ty_expr {
        TyMissing(_) => None
        _ => Some(resolve_type_expr(g.tc, ty_expr, g.cur_tparams))
      }
      let iv = qbe_emit_expr(g, init, ann_opt)
      let final_ty = match ann_opt {
        Some(a) => a
        None => iv.ty
      }
      if name == "_" {
        qbe_rc_dec(g, iv.reg, final_ty)
      } else {
        let iv_ext : Option[String] = if !is_mut &&
          qbe_is_int32_ty(final_ty) &&
          qbe_is_int32_ty(iv.ty) {
          g.w_to_l_ext.get(iv.reg)
        } else {
          None
        }
        let loc = qbe_define_local(g, name, final_ty, true)
        qbe_store_local_slot(g, qbe_coerce_val(g, iv, final_ty), loc.slot, final_ty)
        match iv_ext {
          Some(rl) => g.local_w_to_l_ext.set(name, rl)
          None => ()
        }
        // Track immutable `let n = arr.length()` aliases for BCE
        g.len_aliases.remove(name)
        if !is_mut {
          match init {
            EMethodCall(EIdent(aname, _), mname, margs, _) =>
              if mname == "length" && margs.length() == 0 {
                match qbe_lookup_local(g, aname) {
                  Some(aloc) =>
                    match aloc.ty {
                      TArray(_) => {
                        g.len_aliases.set(name, aname)
                        if !str_arr_contains(g.len_alias_keys, name) {
                          g.len_alias_keys.push(name)
                        }
                      }
                      _ => ()
                    }
                  None => ()
                }
              }
            _ => ()
          }
        }
        // Track provably non-negative `Int` locals for conservative BCE
        match final_ty {
          TInt => {
            let mut is_nonneg = false
            match init {
              EInt(raw, _) => {
                let v = qbe_parse_int64_lit(raw).to_int()
                if v >= 0 {
                  is_nonneg = true
                }
              }
              EBinary("+", EIdent(base_v, _), EInt(raw, _), _) =>
                if qbe_parse_int64_lit(raw) == 1L {
                  match g.nonneg_vars.get(base_v) {
                    Some(true) => is_nonneg = true
                    _ => ()
                  }
                }
              _ => ()
            }
            if is_nonneg {
              g.nonneg_vars.set(name, true)
            } else {
              g.nonneg_vars.remove(name)
            }
          }
          _ => g.nonneg_vars.remove(name)
        }
      }
      qval("0", TUnit)
    }
    SAssign(lhs, rhs, _) => {
      match lhs {
        EIdent(name, _) => {
          g.len_aliases.remove(name)
          qbe_invalidate_len_aliases_for(g, name)
          g.local_w_to_l_ext.remove(name)
          match rhs {
            EInt(raw, _) =>
              if qbe_parse_int64_lit(raw).to_int() >= 0 {
                g.nonneg_vars.set(name, true)
              } else {
                g.nonneg_vars.remove(name)
              }
            EBinary("+", EIdent(rhs_n, _), EInt(raw, _), _) =>
              if rhs_n != name || qbe_parse_int64_lit(raw) != 1L {
                g.nonneg_vars.remove(name)
              }
            _ => g.nonneg_vars.remove(name)
          }
          match qbe_lookup_local(g, name) {
            Some(loc) => {
              let rv = qbe_emit_expr(g, rhs, Some(loc.ty))
              let rval_reg = qbe_coerce_val(g, rv, loc.ty)
              let need_dec = if loc.owned {
                match loc.ty {
                  TParam(_) => true
                  _ => qbe_is_obj_ty(loc.ty)
                }
              } else {
                false
              }
              if need_dec {
                let old = qbe_tmp(g)
                qbe_emit(g, old + " =l loadl " + loc.slot)
                qbe_store_local_slot(g, rval_reg, loc.slot, loc.ty)
                qbe_rc_dec(g, old, loc.ty)
              } else {
                qbe_store_local_slot(g, rval_reg, loc.slot, loc.ty)
              }
              g.block_immut_fields = Map([])
            }
            None => {
              let rv = qbe_emit_expr(g, rhs, None)
              let loc = qbe_define_local(g, name, rv.ty, true)
              qbe_store_local_slot(g, rv.reg, loc.slot, rv.ty)
              g.block_immut_fields = Map([])
            }
          }
        }
        EField(obj, fname, _) => {
          let mut prom_handled = false
          match obj {
            EIdent(lname, _) => {
              let pkey = lname + "." + fname
              match g.promoted_fields.get(pkey) {
                Some(pslot) =>
                  match g.promoted_field_tys.get(pkey) {
                    Some(pty) => {
                      let rv = qbe_emit_expr(g, rhs, Some(pty))
                      let rval_reg = qbe_coerce_val(g, rv, pty)
                      qbe_store_local_slot(g, rval_reg, pslot, pty)
                      g.block_immut_fields.remove(pkey)
                      prom_handled = true
                    }
                    None => ()
                  }
                None => ()
              }
            }
            _ => ()
          }
          if !prom_handled {
          let mut borrowed = false
          let mut ov = qval("0", TError)
          if !qbe_expr_has_assign(rhs) {
            match obj {
              EIdent(lname, _) =>
                match qbe_lookup_local(g, lname) {
                  Some(loc) =>
                    match loc.ty {
                      TStruct(_, _) => {
                        let r = qbe_tmp(g)
                        qbe_emit(g, r + " =l loadl " + loc.slot)
                        ov = qval(r, loc.ty)
                        borrowed = true
                      }
                      _ => ()
                    }
                  None => ()
                }
              _ => ()
            }
          }
          if !borrowed {
            ov = qbe_emit_expr(g, obj, None)
          }
          match ov.ty {
            TStruct(sname, sargs) =>
              match g.tc.structs.get(sname) {
                Some(sinfo) => {
                  let subst = make_subst(sinfo.decl.type_params, sargs)
                  let mut i = 0
                  while i < sinfo.field_names.length() {
                    if sinfo.field_names[i] == fname {
                      let fty = subst_ty(sinfo.field_tys[i], subst)
                      let rv = qbe_emit_expr(g, rhs, Some(fty))
                      let rval_reg = qbe_coerce_val(g, rv, fty)
                      let p = qbe_tmp(g)
                      qbe_emit(g, p + " =l add " + ov.reg + ", " + (i * 8).to_string())
                      let need_dec = match fty {
                        TParam(_) => true
                        _ => qbe_is_obj_ty(fty)
                      }
                      if need_dec {
                        let old = qbe_tmp(g)
                        qbe_emit(g, old + " =l loadl " + p)
                        qbe_store_heap_slot(g, rval_reg, p, fty)
                        qbe_rc_dec(g, old, fty)
                      } else {
                        qbe_store_heap_slot(g, rval_reg, p, fty)
                      }
                      break
                    }
                    i = i + 1
                  }
                }
                None => ()
              }
            _ => ()
          }
          if !borrowed {
            qbe_rc_dec(g, ov.reg, ov.ty)
          }
          }
        }
        EIndex(obj, idx, _) => {
          let mut borrowed = false
          let mut ov = qval("0", TError)
          let mut arr_local_name = ""
          if !qbe_expr_has_assign(idx) && !qbe_expr_has_assign(rhs) {
            match obj {
              EIdent(lname, _) =>
                match qbe_lookup_local(g, lname) {
                  Some(loc) =>
                    match loc.ty {
                      TArray(elem) => {
                        arr_local_name = lname
                        borrowed = true
                        if qbe_is_prim_array_elem(elem) &&
                          g.hoisted_arr_len.contains(lname) &&
                          g.hoisted_arr_dp.contains(lname) {
                          ov = qval("0", loc.ty)
                        } else {
                          let r = qbe_tmp(g)
                          qbe_emit(g, r + " =l loadl " + loc.slot)
                          ov = qval(r, loc.ty)
                        }
                      }
                      _ => ()
                    }
                  None => ()
                }
              _ => ()
            }
          }
          if !borrowed {
            ov = qbe_emit_expr(g, obj, None)
          }
          match ov.ty {
            TArray(elem) => {
              let iv = qbe_emit_expr(g, idx, Some(TInt))
              let il = qbe_as_l(g, iv)
              let rv = qbe_emit_expr(g, rhs, Some(elem))
              if qbe_is_prim_array_elem(elem) {
                let bce_safe = if arr_local_name != "" {
                  qbe_bce_expr_is_safe(g, arr_local_name, idx)
                } else {
                  false
                }
                if !bce_safe {
                  let alen = match g.hoisted_arr_len.get(arr_local_name) {
                    Some(hlen) => hlen
                    None => {
                      let t = qbe_tmp(g)
                      qbe_emit(g, t + " =l loadl " + ov.reg)
                      t
                    }
                  }
                  let oob = qbe_tmp(g)
                  let l_oob = qbe_lbl(g, "arr_oob")
                  let l_ok = qbe_lbl(g, "arr_ok")
                  qbe_emit(g, oob + " =w cugel " + il + ", " + alen)
                  qbe_emit_term(g, "jnz " + oob + ", " + l_oob + ", " + l_ok)
                  qbe_emit_lbl(g, l_oob)
                  qbe_emit(g, "call $m2_panic_oob(l " + il + ", l " + alen + ")")
                  qbe_emit_term(g, "hlt")
                  qbe_emit_lbl(g, l_ok)
                }
                let dp = match g.hoisted_arr_dp.get(arr_local_name) {
                  Some(hdp) => hdp
                  None => {
                    let dp_p = qbe_tmp(g)
                    let t = qbe_tmp(g)
                    qbe_emit(g, dp_p + " =l add " + ov.reg + ", 24")
                    qbe_emit(g, t + " =l loadl " + dp_p)
                    t
                  }
                }
                let off = qbe_tmp(g)
                let ep = qbe_tmp(g)
                qbe_emit(g, off + " =l shl " + il + ", 3")
                qbe_emit(g, ep + " =l add " + dp + ", " + off)
                qbe_store_heap_slot(g, qbe_coerce_val(g, rv, elem), ep, elem)
              } else {
                let vl = qbe_as_l(g, rv)
                qbe_emit(
                  g,
                  "call $m2_arr_set(l " + ov.reg + ", l " + il + ", l " + vl + ")",
                )
                qbe_rc_dec(g, rv.reg, rv.ty)
              }
            }
            TMap(kty, vty) => {
              let kv = qbe_emit_expr(g, idx, Some(kty))
              let rv = qbe_emit_expr(g, rhs, Some(vty))
              let vl = qbe_as_l(g, rv)
              qbe_emit(
                g,
                "call $m2_map_set(l " + ov.reg + ", l " + kv.reg + ", l " + vl + ")",
              )
              qbe_rc_dec(g, kv.reg, kv.ty)
              qbe_rc_dec(g, rv.reg, rv.ty)
            }
            _ => ()
          }
          if !borrowed {
            qbe_rc_dec(g, ov.reg, ov.ty)
          }
        }
        _ => {
          let rv = qbe_emit_expr(g, rhs, None)
          qbe_rc_dec(g, rv.reg, rv.ty)
        }
      }
      qval("0", TUnit)
    }
    SWhile(cond, body, _) => {
      // Loop-invariant Array header (len + data pointer) hoisting
      let cand_arrs : Array[String] = []
      qbe_collect_indexed_arrs_expr(cond, cand_arrs)
      qbe_collect_indexed_arrs_stmts(body, cand_arrs)
      let newly_hoisted : Array[String] = []
      let mut ai = 0
      while ai < cand_arrs.length() {
        let aname = cand_arrs[ai]
        if !g.hoisted_arr_len.contains(aname) {
          match qbe_lookup_local(g, aname) {
            Some(aloc) =>
              match aloc.ty {
                TArray(_) =>
                  if qbe_arr_is_stable_expr(cond, aname, true) &&
                    qbe_arr_is_stable_stmts(body, 0, aname, true) {
                    let ap = qbe_tmp(g)
                    let alen = qbe_tmp(g)
                    let dp_p = qbe_tmp(g)
                    let adp = qbe_tmp(g)
                    qbe_emit(g, ap + " =l loadl " + aloc.slot)
                    qbe_emit(g, alen + " =l loadl " + ap)
                    qbe_emit(g, dp_p + " =l add " + ap + ", 24")
                    qbe_emit(g, adp + " =l loadl " + dp_p)
                    g.hoisted_arr_len.set(aname, alen)
                    g.hoisted_arr_dp.set(aname, adp)
                    newly_hoisted.push(aname)
                  }
                _ => ()
              }
            None => ()
          }
        }
        ai = ai + 1
      }
      // Conservative provably-safe Bounds Check Elimination (BCE)
      let mut added_bce_key = ""
      match cond {
        EBinary("<", EIdent(iv, _), bound, _) => {
          let mut iv_ok = false
          match qbe_lookup_local(g, iv) {
            Some(iloc) =>
              match iloc.ty {
                TInt =>
                  match g.nonneg_vars.get(iv) {
                    Some(true) => iv_ok = true
                    _ => ()
                  }
                _ => ()
              }
            None => ()
          }
          if iv_ok && body.length() >= 1 && qbe_stmt_is_inc_by_one(body[body.length() - 1], iv) {
            // Ensure `iv` is never assigned anywhere else in `body[0 .. len-2]`
            let mut other_write = false
            let mut bi = 0
            while bi < body.length() - 1 {
              if qbe_stmt_assigns_ident(body[bi], iv) {
                other_write = true
                break
              }
              bi = bi + 1
            }
            if !other_write {
              let bound_arr = match bound {
                EMethodCall(EIdent(an, _), mn, ma, _) =>
                  if mn == "length" && ma.length() == 0 {
                    an
                  } else {
                    ""
                  }
                EIdent(n_name, _) =>
                  if !qbe_stmts_assigns_ident(body, n_name) {
                    match g.len_aliases.get(n_name) {
                      Some(an) => an
                      None => ""
                    }
                  } else {
                    ""
                  }
                _ => ""
              }
              if bound_arr != "" &&
                (g.hoisted_arr_len.contains(bound_arr) ||
                  (qbe_arr_is_stable_expr(cond, bound_arr, true) &&
                    qbe_arr_is_stable_stmts(body, 0, bound_arr, true))) {
                let bkey = iv + ":" + bound_arr
                if !g.bce_safe_indices.contains(bkey) {
                  g.bce_safe_indices.set(bkey, "1")
                  added_bce_key = bkey
                }
              }
            }
          }
        }
        _ => ()
      }
      // Loop-invariant read-only primitive struct field hoisting
      let newly_hoisted_fields : Array[String] = []
      if qbe_loop_has_no_calls_expr(cond) && qbe_loop_has_no_calls_stmts(body) {
        let written_fields : Map[String, Bool] = Map([])
        qbe_collect_written_fields_expr(cond, written_fields)
        qbe_collect_written_fields_stmts(body, written_fields)
        let read_vars : Array[String] = []
        let read_fnames : Array[String] = []
        let read_seen : Map[String, Bool] = Map([])
        qbe_collect_read_fields_expr(cond, read_vars, read_fnames, read_seen)
        qbe_collect_read_fields_stmts(body, read_vars, read_fnames, read_seen)
        let loaded_ptrs : Map[String, String] = Map([])
        let mut rfi = 0
        while rfi < read_vars.length() {
          let vname = read_vars[rfi]
          let fname = read_fnames[rfi]
          let fkey = vname + "." + fname
          if !g.hoisted_fields.contains(fkey) && !written_fields.contains(fname) {
            match qbe_lookup_local(g, vname) {
              Some(loc) =>
                match loc.ty {
                  TStruct(sname, sargs) =>
                    if !qbe_expr_assigns_ident(cond, vname) &&
                      !qbe_stmts_assigns_ident(body, vname) &&
                      !qbe_expr_rebinds_ident(cond, vname) &&
                      !qbe_stmts_rebinds_ident(body, vname) {
                      match g.tc.structs.get(sname) {
                        Some(sinfo) => {
                          let subst = make_subst(sinfo.decl.type_params, sargs)
                          let mut fi = 0
                          while fi < sinfo.field_names.length() {
                            if sinfo.field_names[fi] == fname {
                              let fty = subst_ty(sinfo.field_tys[fi], subst)
                              let is_prim = match fty {
                                TInt | TInt64 | TDouble | TBool | TByte | TChar => true
                                _ => false
                              }
                              if is_prim {
                                let ptr_reg = match loaded_ptrs.get(vname) {
                                  Some(pr) => pr
                                  None => {
                                    let pr = qbe_tmp(g)
                                    qbe_emit(g, pr + " =l loadl " + loc.slot)
                                    loaded_ptrs.set(vname, pr)
                                    pr
                                  }
                                }
                                let fp = qbe_tmp(g)
                                qbe_emit(
                                  g,
                                  fp + " =l add " + ptr_reg + ", " + (fi * 8).to_string(),
                                )
                                let fv = qbe_load_heap_slot(g, fp, fty)
                                g.hoisted_fields.set(fkey, qval(fv, fty))
                                newly_hoisted_fields.push(fkey)
                              }
                              break
                            }
                            fi = fi + 1
                          }
                        }
                        None => ()
                      }
                    }
                  _ => ()
                }
              None => ()
            }
          }
          rfi = rfi + 1
        }
      }
      let mut emitted_loop = false
      if !emitted_loop {
        emitted_loop = qbe_try_emit_while_bce_versioned(g, cond, body)
      }
      if !emitted_loop {
        emitted_loop = qbe_try_emit_while_field_promoted(g, cond, body)
      }
      if !emitted_loop {
        emitted_loop = qbe_try_emit_while_sq_reuse(g, cond, body)
      }
      if !emitted_loop {
        if qbe_is_pure_small_cond(cond, 12) {
          let l_body = qbe_lbl(g, "wh_b")
          let l_cond = qbe_lbl(g, "wh_c")
          let l_end = qbe_lbl(g, "wh_e")
          qbe_emit_cond_branch(g, cond, l_body, l_end)
          qbe_emit_lbl(g, l_body)
          let loop_depth = g.scopes.length()
          g.loop_breaks.push(l_end)
          g.loop_conts.push(l_cond)
          g.loop_depths.push(loop_depth)
          qbe_scope_push(g)
          let bv = qbe_emit_stmts(g, body, None)
          if !g.block_term {
            qbe_rc_dec(g, bv.reg, bv.ty)
          }
          qbe_scope_pop(g)
          let _ = g.loop_breaks.pop()
          let _ = g.loop_conts.pop()
          let _ = g.loop_depths.pop()
          qbe_emit_term(g, "jmp " + l_cond)
          qbe_emit_lbl(g, l_cond)
          qbe_emit_cond_branch(g, cond, l_body, l_end)
          qbe_emit_lbl(g, l_end)
        } else {
          let l_cond = qbe_lbl(g, "wh_c")
          let l_body = qbe_lbl(g, "wh_b")
          let l_end = qbe_lbl(g, "wh_e")
          qbe_emit_term(g, "jmp " + l_cond)
          qbe_emit_lbl(g, l_cond)
          qbe_emit_cond_branch(g, cond, l_body, l_end)
          qbe_emit_lbl(g, l_body)
          let loop_depth = g.scopes.length()
          g.loop_breaks.push(l_end)
          g.loop_conts.push(l_cond)
          g.loop_depths.push(loop_depth)
          qbe_scope_push(g)
          let bv = qbe_emit_stmts(g, body, None)
          if !g.block_term {
            qbe_rc_dec(g, bv.reg, bv.ty)
          }
          qbe_scope_pop(g)
          let _ = g.loop_breaks.pop()
          let _ = g.loop_conts.pop()
          let _ = g.loop_depths.pop()
          qbe_emit_term(g, "jmp " + l_cond)
          qbe_emit_lbl(g, l_end)
        }
      }
      if added_bce_key != "" {
        g.bce_safe_indices.remove(added_bce_key)
      }
      let mut hi = 0
      while hi < newly_hoisted.length() {
        let aname = newly_hoisted[hi]
        g.hoisted_arr_len.remove(aname)
        g.hoisted_arr_dp.remove(aname)
        hi = hi + 1
      }
      let mut hfi = 0
      while hfi < newly_hoisted_fields.length() {
        g.hoisted_fields.remove(newly_hoisted_fields[hfi])
        hfi = hfi + 1
      }
      qval("0", TUnit)
    }
    SFor(init_s, cond, step_s, body, _) => {
      qbe_scope_push(g)
      let _ = qbe_emit_stmt(g, init_s, None, false)
      let l_cond = qbe_lbl(g, "for_c")
      let l_body = qbe_lbl(g, "for_b")
      let l_step = qbe_lbl(g, "for_s")
      let l_end = qbe_lbl(g, "for_e")
      qbe_emit_term(g, "jmp " + l_cond)
      qbe_emit_lbl(g, l_cond)
      qbe_emit_cond_branch(g, cond, l_body, l_end)
      qbe_emit_lbl(g, l_body)
      let loop_depth = g.scopes.length()
      g.loop_breaks.push(l_end)
      g.loop_conts.push(l_step)
      g.loop_depths.push(loop_depth)
      qbe_scope_push(g)
      let bv = qbe_emit_stmts(g, body, None)
      if !g.block_term {
        qbe_rc_dec(g, bv.reg, bv.ty)
      }
      qbe_scope_pop(g)
      let _ = g.loop_breaks.pop()
      let _ = g.loop_conts.pop()
      let _ = g.loop_depths.pop()
      qbe_emit_term(g, "jmp " + l_step)
      qbe_emit_lbl(g, l_step)
      let _ = qbe_emit_stmt(g, step_s, None, false)
      qbe_emit_term(g, "jmp " + l_cond)
      qbe_emit_lbl(g, l_end)
      qbe_scope_pop(g)
      qval("0", TUnit)
    }
    SReturn(opt, _) => {
      let target_abi_ty = g.cur_ret_abi_ty
      let rv = match opt {
        Some(e) => {
          let ev = qbe_emit_expr(g, e, Some(g.cur_ret_ty))
          qbe_coerce_val(g, ev, target_abi_ty)
        }
        None => qbe_zero_reg(target_abi_ty)
      }
      qbe_release_scopes_down_to(g, 0)
      qbe_emit_term(g, "ret " + rv)
      qval("0", TNever)
    }
    SBreak(_) => {
      if g.loop_breaks.length() > 0 {
        let lbl = g.loop_breaks[g.loop_breaks.length() - 1]
        let depth = g.loop_depths[g.loop_depths.length() - 1]
        qbe_release_scopes_down_to(g, depth)
        qbe_emit_term(g, "jmp " + lbl)
      }
      qval("0", TNever)
    }
    SContinue(_) => {
      if g.loop_conts.length() > 0 {
        let lbl = g.loop_conts[g.loop_conts.length() - 1]
        let depth = g.loop_depths[g.loop_depths.length() - 1]
        qbe_release_scopes_down_to(g, depth)
        qbe_emit_term(g, "jmp " + lbl)
      }
      qval("0", TNever)
    }
    SDebugAssert(cond, msg, sp) => {
      if !g.release {
        let cv = qbe_emit_expr(g, cond, Some(TBool))
        let mv = qbe_emit_expr(g, msg, Some(TString))
        let cw = qbe_tmp(g)
        qbe_emit(g, cw + " =w copy " + cv.reg)
        let file_id = qbe_intern_cstring(g, sp.file)
        qbe_emit(
          g,
          "call $m2_debug_assert(w " +
          cw +
          ", l " +
          mv.reg +
          ", l $m2_cstr_" +
          file_id.to_string() +
          ", w " +
          sp.line.to_string() +
          ")",
        )
        qbe_rc_dec(g, mv.reg, mv.ty)
      }
      qval("0", TUnit)
    }
    SExpr(e, _) => {
      let v = qbe_emit_expr(g, e, if is_tail { expected } else { None })
      if !is_tail {
        qbe_rc_dec(g, v.reg, v.ty)
        qval("0", TUnit)
      } else {
        v
      }
    }
  }
}

///|
fn qbe_emit_bytes_data(sb : StringBuilder, s : String) -> Int {
  let bytes = str_to_utf8_ints(s)
  let mut i = 0
  while i < bytes.length() {
    sb.write_string("b ")
    sb.write_string(bytes[i].to_string())
    sb.write_string(", ")
    i = i + 1
  }
  sb.write_string("b 0")
  bytes.length()
}

///|
fn qbe_emit_fn_decl(g : QbeGen, fd : FnDecl) -> String {
  let finfo_opt = if fd.receiver_type != "" {
    g.tc.methods.get(fd.receiver_type + "::" + fd.name)
  } else {
    g.tc.fns.get(fd.name)
  }
  match finfo_opt {
    None => ""
    Some(finfo) => {
      g.fn_allocs = StringBuilder()
      g.fn_body = StringBuilder()
      g.scopes = []
      g.loop_breaks = []
      g.loop_conts = []
      g.loop_depths = []
      g.cur_tparams = fd.type_params
      g.cur_ret_ty = finfo.ret_ty
      g.cur_ret_abi_ty = finfo.ret_ty
      g.block_term = false
      g.hoisted_arr_len = Map([])
      g.hoisted_arr_dp = Map([])
      g.hoisted_fields = Map([])
      g.block_immut_fields = Map([])
      g.len_aliases = Map([])
      g.len_alias_keys = []
      g.nonneg_vars = Map([])
      g.bce_safe_indices = Map([])
      g.bce_safe_exprs = Map([])
      g.sq_reuse_slot = Map([])
      g.sq_reuse_state = Map([])
      g.promoted_fields = Map([])
      g.promoted_field_tys = Map([])
      g.w_to_l_ext = Map([])
      g.local_w_to_l_ext = Map([])

      qbe_scope_push(g)
      let mut pi = 0
      while pi < fd.params.length() && pi < finfo.param_tys.length() {
        let loc = qbe_define_local(g, fd.params[pi].name, finfo.param_tys[pi], false)
        qbe_store_local_slot(g, "%p" + pi.to_string(), loc.slot, finfo.param_tys[pi])
        pi = pi + 1
      }
      let bres = qbe_emit_stmts(g, fd.body, Some(finfo.ret_ty))
      if !g.block_term {
        let ret_reg = qbe_coerce_val(g, bres, finfo.ret_ty)
        qbe_scope_pop(g)
        qbe_emit_term(g, "ret " + ret_reg)
      } else {
        let _ = g.scopes.pop()
      }

      let out = StringBuilder()
      let sym = if fd.receiver_type != "" {
        qbe_local_method_sym(g, fd.receiver_type, fd.name)
      } else {
        qbe_local_fn_sym(g, fd.name)
      }
      if fd.is_pub || g.unit_mode {
        out.write_string("export ")
      }
      out.write_string("function ")
      out.write_string(qbe_abi_ty(finfo.ret_ty))
      out.write_string(" ")
      out.write_string(sym)
      out.write_string("(")
      pi = 0
      while pi < fd.params.length() {
        if pi > 0 {
          out.write_string(", ")
        }
        let p_abi = if pi < finfo.param_tys.length() {
          qbe_abi_ty(finfo.param_tys[pi])
        } else {
          "l"
        }
        out.write_string(p_abi)
        out.write_string(" %p")
        out.write_string(pi.to_string())
        pi = pi + 1
      }
      let mut tpi = 0
      while tpi < fd.type_params.length() {
        if fd.params.length() > 0 || tpi > 0 {
          out.write_string(", ")
        }
        out.write_string("l %tp_")
        out.write_string(fd.type_params[tpi])
        tpi = tpi + 1
      }
      out.write_string(") {\n@start\n")
      out.write_string(g.fn_allocs.to_string())
      out.write_string(g.fn_body.to_string())
      out.write_string("}\n\n")
      out.to_string()
    }
  }
}

///|
fn qbe_emit_struct_drops(g : QbeGen, out : StringBuilder) -> Unit {
  let mut i = 0
  while i < g.struct_order.length() {
    let sname = g.struct_order[i]
    match g.tc.structs.get(sname) {
      Some(sinfo) =>
        if sinfo.decl.type_params.length() == 0 {
          let obj_slots : Array[Int] = []
          let mut fi = 0
          while fi < sinfo.field_tys.length() {
            if qbe_is_obj_ty(sinfo.field_tys[fi]) {
              obj_slots.push(fi)
            }
            fi = fi + 1
          }
          if obj_slots.length() > 0 {
            if g.unit_mode && !has_qual_sep(sname) {
              out.write_string("export ")
            }
            out.write_string("function $m2_drop_struct_")
            out.write_string(qbe_sanitize_sym(sname))
            out.write_string("(l %p) {\n@start\n")
            let mut j = 0
            while j < obj_slots.length() {
              let off = obj_slots[j] * 8
              out.write_string("    %a")
              out.write_string(j.to_string())
              out.write_string(" =l add %p, ")
              out.write_string(off.to_string())
              out.write_string("\n    %v")
              out.write_string(j.to_string())
              out.write_string(" =l loadl %a")
              out.write_string(j.to_string())
              out.write_string("\n    call $m2_rc_dec(l %v")
              out.write_string(j.to_string())
              out.write_string(")\n")
              j = j + 1
            }
            out.write_string("    ret\n}\n\n")
          }
        }
      None => ()
    }
    i = i + 1
  }
}

///|
fn qbe_emit_enum_drops(g : QbeGen, out : StringBuilder) -> Unit {
  let mut i = 0
  while i < g.enum_order.length() {
    let ename = g.enum_order[i]
    match g.tc.enums.get(ename) {
      Some(einfo) =>
        if einfo.decl.type_params.length() == 0 {
          if g.unit_mode && !has_qual_sep(ename) {
            out.write_string("export ")
          }
          out.write_string("function $m2_drop_enum_")
          out.write_string(qbe_sanitize_sym(ename))
          out.write_string("(l %p) {\n@start\n")
          out.write_string("    %tag =l loadl %p\n")
          let mut vi = 0
          while vi < einfo.variants.length() {
            let v = einfo.variants[vi]
            let obj_slots : Array[Int] = []
            let mut fi = 0
            while fi < v.field_tys.length() {
              if qbe_is_obj_ty(v.field_tys[fi]) {
                obj_slots.push(fi)
              }
              fi = fi + 1
            }
            if obj_slots.length() > 0 {
              out.write_string("    %c")
              out.write_string(vi.to_string())
              out.write_string(" =w ceql %tag, ")
              out.write_string(vi.to_string())
              out.write_string("\n    jnz %c")
              out.write_string(vi.to_string())
              out.write_string(", @v")
              out.write_string(vi.to_string())
              out.write_string(", @n")
              out.write_string(vi.to_string())
              out.write_string("\n@v")
              out.write_string(vi.to_string())
              out.write_string("\n")
              let mut j = 0
              while j < obj_slots.length() {
                let off = (obj_slots[j] + 1) * 8
                out.write_string("    %a")
                out.write_string(vi.to_string())
                out.write_string("_")
                out.write_string(j.to_string())
                out.write_string(" =l add %p, ")
                out.write_string(off.to_string())
                out.write_string("\n    %v")
                out.write_string(vi.to_string())
                out.write_string("_")
                out.write_string(j.to_string())
                out.write_string(" =l loadl %a")
                out.write_string(vi.to_string())
                out.write_string("_")
                out.write_string(j.to_string())
                out.write_string("\n    call $m2_rc_dec(l %v")
                out.write_string(vi.to_string())
                out.write_string("_")
                out.write_string(j.to_string())
                out.write_string(")\n")
                j = j + 1
              }
              out.write_string("    ret\n@n")
              out.write_string(vi.to_string())
              out.write_string("\n")
            }
            vi = vi + 1
          }
          out.write_string("    ret\n}\n\n")
        }
      None => ()
    }
    i = i + 1
  }
}

///|
fn qbe_emit_helper_drops(g : QbeGen, out : StringBuilder) -> Unit {
  if g.need_drop_opt_obj {
    out.write_string(
      "function $m2_drop_opt_obj(l %p) {\n@start\n    %tag =l loadl %p\n    %is1 =w ceql %tag, 1\n    jnz %is1, @dec, @done\n@dec\n    %a =l add %p, 8\n    %v =l loadl %a\n    call $m2_rc_dec(l %v)\n@done\n    ret\n}\n\n",
    )
  }
  if g.need_drop_res_ok {
    out.write_string(
      "function $m2_drop_res_ok(l %p) {\n@start\n    %tag =l loadl %p\n    %is0 =w ceql %tag, 0\n    jnz %is0, @dec, @done\n@dec\n    %a =l add %p, 8\n    %v =l loadl %a\n    call $m2_rc_dec(l %v)\n@done\n    ret\n}\n\n",
    )
  }
  if g.need_drop_res_err {
    out.write_string(
      "function $m2_drop_res_err(l %p) {\n@start\n    %tag =l loadl %p\n    %is1 =w ceql %tag, 1\n    jnz %is1, @dec, @done\n@dec\n    %a =l add %p, 8\n    %v =l loadl %a\n    call $m2_rc_dec(l %v)\n@done\n    ret\n}\n\n",
    )
  }
  if g.need_drop_res_both {
    out.write_string(
      "function $m2_drop_res_both(l %p) {\n@start\n    %a =l add %p, 8\n    %v =l loadl %a\n    call $m2_rc_dec(l %v)\n    ret\n}\n\n",
    )
  }
  let mut i = 0
  while i < g.slot_drop_masks.length() {
    let mask = g.slot_drop_masks[i]
    out.write_string("function $m2_drop_slots_")
    out.write_string(mask.to_string())
    out.write_string("(l %p) {\n@start\n")
    let mut bit = 0
    while bit < 31 {
      if ((mask >> bit) & 1) != 0 {
        let off = bit * 8
        out.write_string("    %a")
        out.write_string(bit.to_string())
        out.write_string(" =l add %p, ")
        out.write_string(off.to_string())
        out.write_string("\n    %v")
        out.write_string(bit.to_string())
        out.write_string(" =l loadl %a")
        out.write_string(bit.to_string())
        out.write_string("\n    call $m2_rc_dec(l %v")
        out.write_string(bit.to_string())
        out.write_string(")\n")
      }
      bit = bit + 1
    }
    out.write_string("    ret\n}\n\n")
    i = i + 1
  }
}

///|
fn qbe_emit_fn_wrappers(g : QbeGen, out : StringBuilder) -> Unit {
  let mut i = 0
  while i < g.fn_wrappers.length() {
    let fname = g.fn_wrappers[i]
    match g.tc.fns.get(fname) {
      Some(finfo) => {
        out.write_string("function l $m2_wrap_")
        out.write_string(fname)
        out.write_string("(l %env")
        let mut pi = 0
        while pi < finfo.param_tys.length() {
          out.write_string(", l %p")
          out.write_string(pi.to_string())
          pi = pi + 1
        }
        out.write_string(") {\n@start\n")
        pi = 0
        while pi < finfo.param_tys.length() {
          if qbe_is_double_ty(finfo.param_tys[pi]) {
            out.write_string("    %dp")
            out.write_string(pi.to_string())
            out.write_string(" =d cast %p")
            out.write_string(pi.to_string())
            out.write_string("\n")
          } else if qbe_is_int32_ty(finfo.param_tys[pi]) {
            out.write_string("    %wp")
            out.write_string(pi.to_string())
            out.write_string(" =w copy %p")
            out.write_string(pi.to_string())
            out.write_string("\n")
          }
          pi = pi + 1
        }
        let ret_d = qbe_is_double_ty(finfo.ret_ty)
        let ret_w = qbe_is_int32_ty(finfo.ret_ty)
        let fn_sym = qbe_local_fn_sym(g, fname)
        if ret_d {
          out.write_string("    %rd =d call ")
        } else if ret_w {
          out.write_string("    %rw =w call ")
        } else {
          out.write_string("    %r =l call ")
        }
        out.write_string(fn_sym)
        out.write_string("(")
        pi = 0
        while pi < finfo.param_tys.length() {
          if pi > 0 {
            out.write_string(", ")
          }
          if qbe_is_double_ty(finfo.param_tys[pi]) {
            out.write_string("d %dp")
          } else if qbe_is_int32_ty(finfo.param_tys[pi]) {
            out.write_string("w %wp")
          } else {
            out.write_string("l %p")
          }
          out.write_string(pi.to_string())
          pi = pi + 1
        }
        out.write_string(")\n")
        if ret_d {
          out.write_string("    %r =l cast %rd\n")
        } else if ret_w {
          out.write_string("    %r =l extsw %rw\n")
        }
        out.write_string("    ret %r\n}\n\n")
      }
      None => ()
    }
    i = i + 1
  }
}

///|
fn build_typechecker_for_codegen(pkg : Package) -> TypeChecker {
  let tc = TypeChecker::{
    pkg_name: pkg.name,
    multi_pkg: false,
    structs: Map([]),
    struct_names: [],
    enums: Map([]),
    enum_names: [],
    variant_to_enum: Map([]),
    fns: Map([]),
    methods: Map([]),
    method_names: [],
    consts: Map([]),
    const_pub: Map([]),
    import_aliases: Map([]),
    imported_pkgs: Map([]),
    diagnostics: [],
  }
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
            ptys.push(resolve_type_expr(tc, fd.params[pi].ty, fd.type_params))
            pi = pi + 1
          }
          let rty = resolve_type_expr(tc, fd.ret_ty, fd.type_params)
          let finfo = FnInfo::{ decl: fd, param_tys: ptys, ret_ty: rty }
          if fd.receiver_type != "" {
            tc.methods.set(fd.receiver_type + "::" + fd.name, finfo)
          } else {
            tc.fns.set(fd.name, finfo)
          }
        }
        DConst(cd) => {
          let cty = resolve_type_expr(tc, cd.ty, [])
          tc.consts.set(cd.name, cty)
          tc.const_pub.set(cd.name, cd.is_pub)
        }
        DTest(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }
  tc
}

///|
pub fn emit_qbe_package_multi(
  pkg : Package,
  tc : TypeChecker,
  release : Bool,
  is_entry : Bool,
  dep_pkg_names : Array[String],
) -> QbeEmitResult {
  let g = qbe_new(tc, release, false)
  let const_decls : Array[ConstDecl] = []

  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) => g.struct_order.push(sd.name)
        DEnum(ed) => g.enum_order.push(ed.name)
        DConst(cd) => {
          g.const_order.push(cd.name)
          const_decls.push(cd)
        }
        DFn(_) | DTest(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  let init_sym = "$m2_" + g.pkg_prefix + "init_consts"
  let mut init_consts_code = ""
  if const_decls.length() > 0 || tc.multi_pkg {
    g.fn_allocs = StringBuilder()
    g.fn_body = StringBuilder()
    g.scopes = []
    g.loop_breaks = []
    g.loop_conts = []
    g.loop_depths = []
    g.cur_tparams = []
    g.cur_ret_ty = TUnit
    g.cur_ret_abi_ty = TUnit
    g.block_term = false
    qbe_scope_push(g)
    let mut ci = 0
    while ci < const_decls.length() {
      let cd = const_decls[ci]
      let cty = match tc.consts.get(cd.name) {
        Some(t) => t
        None => TError
      }
      let cv = qbe_emit_expr(g, cd.value, Some(cty))
      qbe_store_heap_slot(
        g,
        qbe_coerce_val(g, cv, cty),
        qbe_local_const_sym(g, cd.name),
        cty,
      )
      ci = ci + 1
    }
    qbe_scope_pop(g)
    qbe_emit_term(g, "ret")
    let csb = StringBuilder()
    if tc.multi_pkg {
      csb.write_string("export ")
    }
    csb.write_string("function ")
    csb.write_string(init_sym)
    csb.write_string("() {\n@start\n")
    csb.write_string(g.fn_allocs.to_string())
    csb.write_string(g.fn_body.to_string())
    csb.write_string("}\n\n")
    init_consts_code = csb.to_string()
  }

  let fns_buf = StringBuilder()
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    g.inline_fns = qbe_collect_file_inline_fns(f)
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DFn(fd) => fns_buf.write_string(qbe_emit_fn_decl(g, fd))
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  let out = StringBuilder()
  out.write_string("# Generated by m2c QBE backend (deterministic)\n\n")

  if g.need_none_const {
    out.write_string(
      "data $m2_none_hdr = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l 0 }\n",
    )
  }

  let mut eci = 0
  while eci < g.enum_consts.length() {
    let ec = g.enum_consts[eci]
    out.write_string("data ")
    out.write_string(ec.sym)
    out.write_string(" = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l ")
    out.write_string(ec.tag.to_string())
    out.write_string(" }\n")
    eci = eci + 1
  }

  let mut si = 0
  while si < g.strings.length() {
    let s = g.strings[si]
    let bytes = str_to_utf8_ints(s)
    let payload_sz = 8 + bytes.length() + 1
    out.write_string("data $m2_str_")
    out.write_string(si.to_string())
    out.write_string("_hdr = align 8 { l 0, w 0, w 1, h 1, h 3, w ")
    out.write_string(payload_sz.to_string())
    out.write_string(", l 0, l ")
    out.write_string(bytes.length().to_string())
    out.write_string(", ")
    let _ = qbe_emit_bytes_data(out, s)
    out.write_string(" }\n")
    si = si + 1
  }

  let mut csi = 0
  while csi < g.cstrings.length() {
    out.write_string("data $m2_cstr_")
    out.write_string(csi.to_string())
    out.write_string(" = { ")
    let _ = qbe_emit_bytes_data(out, g.cstrings[csi])
    out.write_string(" }\n")
    csi = csi + 1
  }

  let mut kci = 0
  while kci < g.const_order.length() {
    let cname = g.const_order[kci]
    let is_pub_c = match tc.const_pub.get(cname) {
      Some(b) => b
      None => false
    }
    if tc.multi_pkg && is_pub_c {
      out.write_string("export ")
    }
    out.write_string("data ")
    out.write_string(qbe_local_const_sym(g, cname))
    out.write_string(" = align 8 { l 0 }\n")
    kci = kci + 1
  }
  out.write_string("\n")

  qbe_emit_struct_drops(g, out)
  qbe_emit_enum_drops(g, out)
  qbe_emit_helper_drops(g, out)
  qbe_emit_fn_wrappers(g, out)

  let mut ei = 0
  while ei < g.extra_fns.length() {
    out.write_string(g.extra_fns[ei])
    ei = ei + 1
  }

  out.write_string(init_consts_code)
  out.write_string(fns_buf.to_string())

  let mut has_main = false
  if is_entry {
    match tc.fns.get("main") {
      Some(minfo) => {
        has_main = true
        out.write_string("export function w $main(w %argc, l %argv) {\n@start\n")
        out.write_string("    %w =l call $m2_world_init(w %argc, l %argv)\n")
        let mut dpi = 0
        while dpi < dep_pkg_names.length() {
          out.write_string("    call $m2_pkg_")
          out.write_string(qbe_sanitize_sym(dep_pkg_names[dpi]))
          out.write_string("_init_consts()\n")
          dpi = dpi + 1
        }
        if const_decls.length() > 0 || tc.multi_pkg {
          out.write_string("    call ")
          out.write_string(init_sym)
          out.write_string("()\n")
        }
        let ret_abi = qbe_abi_ty(minfo.ret_ty)
        let main_fn_sym = qbe_local_fn_sym(g, "main")
        if minfo.param_tys.length() >= 1 {
          out.write_string("    %r =")
          out.write_string(ret_abi)
          out.write_string(" call ")
          out.write_string(main_fn_sym)
          out.write_string("(l %w)\n")
        } else {
          out.write_string("    %r =")
          out.write_string(ret_abi)
          out.write_string(" call ")
          out.write_string(main_fn_sym)
          out.write_string("()\n")
        }
        out.write_string("    call $m2_rc_dec(l %w)\n")
        match minfo.ret_ty {
          TInt => out.write_string("    ret %r\n")
          TInt64 => {
            out.write_string("    %rw =w copy %r\n")
            out.write_string("    ret %rw\n")
          }
          _ => out.write_string("    ret 0\n")
        }
        out.write_string("}\n")
      }
      None => ()
    }
  }

  QbeEmitResult::{ ssa: out.to_string(), has_main: has_main }
}

///|
pub fn emit_qbe_package_with_tc(
  pkg : Package,
  tc : TypeChecker,
  release : Bool,
) -> QbeEmitResult {
  emit_qbe_package_multi(pkg, tc, release, true, [])
}

///|
pub fn emit_qbe_package(pkg : Package, release : Bool) -> QbeEmitResult {
  let tc = build_typechecker_for_codegen(pkg)
  emit_qbe_package_with_tc(pkg, tc, release)
}

///|
pub struct PreparedPackage {
  pkg : Package
  tc : TypeChecker
  sig : String
  sigs_hash : String
  const_units : Array[Int]
  has_main : Bool
}

///|
pub fn cli_prepare_qbe_units(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
) -> Result[PreparedPackage, String] {
  let checked = check_source_files_full(pkg_name, paths, sources)
  if checked.diagnostics.length() > 0 {
    return Err(check_result_to_json(checked.diagnostics))
  }
  let pkg = checked.pkg
  let tc = checked.tc
  let sig_text = emit_m2sig(pkg)
  let all_sigs = emit_all_sigs(pkg)
  let const_units : Array[Int] = []
  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut has_const = false
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DConst(_) => {
          has_const = true
          break
        }
        _ => ()
      }
      di = di + 1
    }
    if has_const {
      const_units.push(fi)
    }
    fi = fi + 1
  }
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
  let sigs_hash = cas_sha256_hex(sig_sb.to_string())
  let has_main = tc.fns.contains("main")
  Ok(PreparedPackage::{
    pkg: pkg,
    tc: tc,
    sig: sig_text,
    sigs_hash: sigs_hash,
    const_units: const_units,
    has_main: has_main,
  })
}

///|
/// Selective incremental preparation: `files` contains full ASTs for dirty units
/// and lightweight stub ASTs for cached units; type-checking Pass 3 runs only on
/// units where `check_file[i] == true`.
pub fn cli_prepare_qbe_units_selective(
  pkg_name : String,
  files : Array[SourceFile],
  check_file : Array[Bool],
  sigs_hash : String,
  const_units : Array[Int],
) -> Result[PreparedPackage, String] {
  let pkg = Package::{ name: pkg_name, files: files }
  let checked = check_package_selective(pkg, check_file)
  if checked.diagnostics.length() > 0 {
    return Err(check_result_to_json(checked.diagnostics))
  }
  let tc = checked.tc
  let has_main = tc.fns.contains("main")
  Ok(PreparedPackage::{
    pkg: pkg,
    tc: tc,
    sig: "",
    sigs_hash: sigs_hash,
    const_units: const_units,
    has_main: has_main,
  })
}

///|
pub fn emit_qbe_unit(
  prep : PreparedPackage,
  unit_idx : Int,
  release : Bool,
) -> String {
  let tc = prep.tc
  let g = qbe_new(tc, release, true)
  let f = prep.pkg.files[unit_idx]
  let const_decls : Array[ConstDecl] = []
  let mut unit_has_main = false

  let mut di = 0
  while di < f.decls.length() {
    match f.decls[di] {
      DStruct(sd) => g.struct_order.push(sd.name)
      DEnum(ed) => g.enum_order.push(ed.name)
      DConst(cd) => {
        g.const_order.push(cd.name)
        const_decls.push(cd)
      }
      DFn(fd) =>
        if fd.receiver_type == "" && fd.name == "main" {
          unit_has_main = true
        }
      DTest(_) => ()
    }
    di = di + 1
  }

  let mut init_consts_code = ""
  if const_decls.length() > 0 {
    g.fn_allocs = StringBuilder()
    g.fn_body = StringBuilder()
    g.scopes = []
    g.loop_breaks = []
    g.loop_conts = []
    g.loop_depths = []
    g.cur_tparams = []
    g.cur_ret_ty = TUnit
    g.cur_ret_abi_ty = TUnit
    g.block_term = false
    qbe_scope_push(g)
    let mut ci = 0
    while ci < const_decls.length() {
      let cd = const_decls[ci]
      let cty = match tc.consts.get(cd.name) {
        Some(t) => t
        None => TError
      }
      let cv = qbe_emit_expr(g, cd.value, Some(cty))
      qbe_store_heap_slot(g, qbe_coerce_val(g, cv, cty), "$m2_const_" + cd.name, cty)
      ci = ci + 1
    }
    qbe_scope_pop(g)
    qbe_emit_term(g, "ret")
    let csb = StringBuilder()
    csb.write_string("export function $m2_init_consts_")
    csb.write_string(unit_idx.to_string())
    csb.write_string("() {\n@start\n")
    csb.write_string(g.fn_allocs.to_string())
    csb.write_string(g.fn_body.to_string())
    csb.write_string("}\n\n")
    init_consts_code = csb.to_string()
  }

  g.inline_fns = qbe_collect_file_inline_fns(f)
  let fns_buf = StringBuilder()
  di = 0
  while di < f.decls.length() {
    match f.decls[di] {
      DFn(fd) => fns_buf.write_string(qbe_emit_fn_decl(g, fd))
      _ => ()
    }
    di = di + 1
  }

  let out = StringBuilder()
  out.write_string("# Generated by m2c QBE unit backend (deterministic)\n\n")

  if g.need_none_const {
    out.write_string(
      "data $m2_none_hdr = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l 0 }\n",
    )
  }

  let mut eci = 0
  while eci < g.enum_consts.length() {
    let ec = g.enum_consts[eci]
    out.write_string("data ")
    out.write_string(ec.sym)
    out.write_string(" = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l ")
    out.write_string(ec.tag.to_string())
    out.write_string(" }\n")
    eci = eci + 1
  }

  let mut si = 0
  while si < g.strings.length() {
    let s = g.strings[si]
    let bytes = str_to_utf8_ints(s)
    let payload_sz = 8 + bytes.length() + 1
    out.write_string("data $m2_str_")
    out.write_string(si.to_string())
    out.write_string("_hdr = align 8 { l 0, w 0, w 1, h 1, h 3, w ")
    out.write_string(payload_sz.to_string())
    out.write_string(", l 0, l ")
    out.write_string(bytes.length().to_string())
    out.write_string(", ")
    let _ = qbe_emit_bytes_data(out, s)
    out.write_string(" }\n")
    si = si + 1
  }

  let mut csi = 0
  while csi < g.cstrings.length() {
    out.write_string("data $m2_cstr_")
    out.write_string(csi.to_string())
    out.write_string(" = { ")
    let _ = qbe_emit_bytes_data(out, g.cstrings[csi])
    out.write_string(" }\n")
    csi = csi + 1
  }

  let mut kci = 0
  while kci < g.const_order.length() {
    out.write_string("export data $m2_const_")
    out.write_string(g.const_order[kci])
    out.write_string(" = align 8 { l 0 }\n")
    kci = kci + 1
  }
  out.write_string("\n")

  qbe_emit_struct_drops(g, out)
  qbe_emit_enum_drops(g, out)
  qbe_emit_helper_drops(g, out)
  qbe_emit_fn_wrappers(g, out)

  let mut ei = 0
  while ei < g.extra_fns.length() {
    out.write_string(g.extra_fns[ei])
    ei = ei + 1
  }

  out.write_string(init_consts_code)
  out.write_string(fns_buf.to_string())

  if unit_has_main {
    match tc.fns.get("main") {
      Some(minfo) => {
        out.write_string("export function w $main(w %argc, l %argv) {\n@start\n")
        out.write_string("    %w =l call $m2_world_init(w %argc, l %argv)\n")
        let mut ci = 0
        while ci < prep.const_units.length() {
          out.write_string("    call $m2_init_consts_")
          out.write_string(prep.const_units[ci].to_string())
          out.write_string("()\n")
          ci = ci + 1
        }
        let ret_abi = qbe_abi_ty(minfo.ret_ty)
        if minfo.param_tys.length() >= 1 {
          out.write_string("    %r =")
          out.write_string(ret_abi)
          out.write_string(" call $m2_fn_main(l %w)\n")
        } else {
          out.write_string("    %r =")
          out.write_string(ret_abi)
          out.write_string(" call $m2_fn_main()\n")
        }
        out.write_string("    call $m2_rc_dec(l %w)\n")
        match minfo.ret_ty {
          TInt => out.write_string("    ret %r\n")
          TInt64 => {
            out.write_string("    %rw =w copy %r\n")
            out.write_string("    ret %rw\n")
          }
          _ => out.write_string("    ret 0\n")
        }
        out.write_string("}\n")
      }
      None => ()
    }
  }

  out.to_string()
}

///|
pub fn cli_compile_qbe(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
  release : Bool,
) -> Result[CompileQbeOut, String] {
  let checked = check_source_files_full(pkg_name, paths, sources)
  if checked.diagnostics.length() > 0 {
    return Err(check_result_to_json(checked.diagnostics))
  }
  let sig_text = emit_m2sig(checked.pkg)
  let res = emit_qbe_package_with_tc(checked.pkg, checked.tc, release)
  Ok(CompileQbeOut::{ sig: sig_text, ssa: res.ssa, has_main: res.has_main })
}

///|
pub struct QbeTestEmitResult {
  ssa : String
  test_names : Array[String]
}

///|
pub fn qbe_test_emit_empty() -> QbeTestEmitResult {
  QbeTestEmitResult::{ ssa: "", test_names: [] }
}

///|
pub fn emit_qbe_test_package(
  pkg : Package,
  tc : TypeChecker,
  dep_pkg_names : Array[String],
) -> QbeTestEmitResult {
  let g = qbe_new(tc, false, false)
  let const_decls : Array[ConstDecl] = []
  let test_decls : Array[TestDecl] = []
  let test_names : Array[String] = []

  let mut fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DStruct(sd) => g.struct_order.push(sd.name)
        DEnum(ed) => g.enum_order.push(ed.name)
        DConst(cd) => {
          g.const_order.push(cd.name)
          const_decls.push(cd)
        }
        DTest(td) => {
          test_decls.push(td)
          test_names.push(td.name)
        }
        DFn(_) => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  let init_sym = "$m2_" + g.pkg_prefix + "init_consts"
  let mut init_consts_code = ""
  if const_decls.length() > 0 || tc.multi_pkg {
    g.fn_allocs = StringBuilder()
    g.fn_body = StringBuilder()
    g.scopes = []
    g.loop_breaks = []
    g.loop_conts = []
    g.loop_depths = []
    g.cur_tparams = []
    g.cur_ret_ty = TUnit
    g.cur_ret_abi_ty = TUnit
    g.block_term = false
    qbe_scope_push(g)
    let mut ci = 0
    while ci < const_decls.length() {
      let cd = const_decls[ci]
      let cty = match tc.consts.get(cd.name) {
        Some(t) => t
        None => TError
      }
      let cv = qbe_emit_expr(g, cd.value, Some(cty))
      qbe_store_heap_slot(
        g,
        qbe_coerce_val(g, cv, cty),
        qbe_local_const_sym(g, cd.name),
        cty,
      )
      ci = ci + 1
    }
    qbe_scope_pop(g)
    qbe_emit_term(g, "ret")
    let csb = StringBuilder()
    csb.write_string("function ")
    csb.write_string(init_sym)
    csb.write_string("() {\n@start\n")
    csb.write_string(g.fn_allocs.to_string())
    csb.write_string(g.fn_body.to_string())
    csb.write_string("}\n\n")
    init_consts_code = csb.to_string()
  }

  let fns_buf = StringBuilder()
  fi = 0
  while fi < pkg.files.length() {
    let f = pkg.files[fi]
    g.inline_fns = qbe_collect_file_inline_fns(f)
    let mut di = 0
    while di < f.decls.length() {
      match f.decls[di] {
        DFn(fd) => fns_buf.write_string(qbe_emit_fn_decl(g, fd))
        _ => ()
      }
      di = di + 1
    }
    fi = fi + 1
  }

  let tests_buf = StringBuilder()
  let mut ti = 0
  while ti < test_decls.length() {
    let td = test_decls[ti]
    g.fn_allocs = StringBuilder()
    g.fn_body = StringBuilder()
    g.scopes = []
    g.loop_breaks = []
    g.loop_conts = []
    g.loop_depths = []
    g.cur_tparams = []
    g.cur_ret_ty = TUnit
    g.cur_ret_abi_ty = TUnit
    g.block_term = false
    g.hoisted_arr_len = Map([])
    g.hoisted_arr_dp = Map([])
    g.hoisted_fields = Map([])
    g.block_immut_fields = Map([])
    g.len_aliases = Map([])
    g.len_alias_keys = []
    g.nonneg_vars = Map([])
    g.bce_safe_indices = Map([])
    g.bce_safe_exprs = Map([])
    g.sq_reuse_slot = Map([])
    g.sq_reuse_state = Map([])
    g.promoted_fields = Map([])
    g.promoted_field_tys = Map([])
    g.w_to_l_ext = Map([])
    g.local_w_to_l_ext = Map([])
    qbe_scope_push(g)
    let bres = qbe_emit_stmts(g, td.body, None)
    if !g.block_term {
      qbe_rc_dec(g, bres.reg, bres.ty)
      qbe_scope_pop(g)
      qbe_emit_term(g, "ret")
    } else {
      let _ = g.scopes.pop()
    }
    tests_buf.write_string("function $m2_test_fn_")
    tests_buf.write_string(ti.to_string())
    tests_buf.write_string("() {\n@start\n")
    tests_buf.write_string(g.fn_allocs.to_string())
    tests_buf.write_string(g.fn_body.to_string())
    tests_buf.write_string("}\n\n")
    ti = ti + 1
  }

  let out = StringBuilder()
  out.write_string("# Generated by m2c QBE test runner backend (deterministic)\n\n")

  if g.need_none_const {
    out.write_string(
      "data $m2_none_hdr = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l 0 }\n",
    )
  }

  let mut eci = 0
  while eci < g.enum_consts.length() {
    let ec = g.enum_consts[eci]
    out.write_string("data ")
    out.write_string(ec.sym)
    out.write_string(" = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l ")
    out.write_string(ec.tag.to_string())
    out.write_string(" }\n")
    eci = eci + 1
  }

  let mut si = 0
  while si < g.strings.length() {
    let s = g.strings[si]
    let bytes = str_to_utf8_ints(s)
    let payload_sz = 8 + bytes.length() + 1
    out.write_string("data $m2_str_")
    out.write_string(si.to_string())
    out.write_string("_hdr = align 8 { l 0, w 0, w 1, h 1, h 3, w ")
    out.write_string(payload_sz.to_string())
    out.write_string(", l 0, l ")
    out.write_string(bytes.length().to_string())
    out.write_string(", ")
    let _ = qbe_emit_bytes_data(out, s)
    out.write_string(" }\n")
    si = si + 1
  }

  let mut csi = 0
  while csi < g.cstrings.length() {
    out.write_string("data $m2_cstr_")
    out.write_string(csi.to_string())
    out.write_string(" = { ")
    let _ = qbe_emit_bytes_data(out, g.cstrings[csi])
    out.write_string(" }\n")
    csi = csi + 1
  }

  let mut kci = 0
  while kci < g.const_order.length() {
    out.write_string("data ")
    out.write_string(qbe_local_const_sym(g, g.const_order[kci]))
    out.write_string(" = align 8 { l 0 }\n")
    kci = kci + 1
  }
  out.write_string("\n")

  qbe_emit_struct_drops(g, out)
  qbe_emit_enum_drops(g, out)
  qbe_emit_helper_drops(g, out)
  qbe_emit_fn_wrappers(g, out)

  let mut ei = 0
  while ei < g.extra_fns.length() {
    out.write_string(g.extra_fns[ei])
    ei = ei + 1
  }

  out.write_string(init_consts_code)
  out.write_string(fns_buf.to_string())
  out.write_string(tests_buf.to_string())

  out.write_string("export function w $main(w %argc, l %argv) {\n@start\n")
  out.write_string("    %ok_slot =l alloc4 4\n")
  out.write_string("    %w =l call $m2_world_init(w %argc, l %argv)\n")
  let mut dpi = 0
  while dpi < dep_pkg_names.length() {
    out.write_string("    call $m2_pkg_")
    out.write_string(qbe_sanitize_sym(dep_pkg_names[dpi]))
    out.write_string("_init_consts()\n")
    dpi = dpi + 1
  }
  if const_decls.length() > 0 || tc.multi_pkg {
    out.write_string("    call ")
    out.write_string(init_sym)
    out.write_string("()\n")
  }
  if test_decls.length() > 0 {
    out.write_string("    %arg1 =l call $m2_world_argv(l %w, l 1)\n")
    out.write_string("    %idx =l call $m2_str_to_int(l %arg1, l %ok_slot)\n")
    out.write_string("    call $m2_rc_dec(l %arg1)\n")
    ti = 0
    while ti < test_decls.length() {
      let s_i = ti.to_string()
      out.write_string("    %c")
      out.write_string(s_i)
      out.write_string(" =w ceql %idx, ")
      out.write_string(s_i)
      out.write_string("\n    jnz %c")
      out.write_string(s_i)
      out.write_string(", @test_")
      out.write_string(s_i)
      out.write_string(", @next_")
      out.write_string(s_i)
      out.write_string("\n@test_")
      out.write_string(s_i)
      out.write_string("\n    call $m2_test_fn_")
      out.write_string(s_i)
      out.write_string("()\n    jmp @done\n@next_")
      out.write_string(s_i)
      out.write_string("\n")
      ti = ti + 1
    }
    out.write_string("@done\n")
  }
  out.write_string("    call $m2_rc_dec(l %w)\n")
  out.write_string("    ret 0\n}\n")

  QbeTestEmitResult::{ ssa: out.to_string(), test_names: test_names }
}

///|
pub fn format_test_report_json(
  names : Array[String],
  passed_flags : Array[Bool],
) -> String {
  let mut passed = 0
  let mut failed = 0
  let mut i = 0
  while i < names.length() && i < passed_flags.length() {
    if passed_flags[i] {
      passed = passed + 1
    } else {
      failed = failed + 1
    }
    i = i + 1
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":")
  sb.write_string(if failed == 0 { "true" } else { "false" })
  sb.write_string(",\"passed\":")
  sb.write_string(passed.to_string())
  sb.write_string(",\"failed\":")
  sb.write_string(failed.to_string())
  sb.write_string(",\"tests\":[")
  i = 0
  while i < names.length() && i < passed_flags.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":")
    sb.write_string(json_quote(names[i]))
    sb.write_string(",\"ok\":")
    sb.write_string(if passed_flags[i] { "true" } else { "false" })
    sb.write_string("}")
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}
