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
pub struct QbeScope {
  locals : Array[QbeLocal]
}

///|
pub struct QbeGen {
  tc : TypeChecker
  release : Bool
  struct_order : Array[String]
  enum_order : Array[String]
  const_order : Array[String]
  strings : Array[String]
  string_ids : Map[String, Int]
  cstrings : Array[String]
  cstring_ids : Map[String, Int]
  slot_drop_masks : Array[Int]
  slot_drop_seen : Map[String, Bool]
  fn_wrappers : Array[String]
  fn_wrapper_seen : Map[String, Bool]
  extra_fns : Array[String]
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
fn qbe_new(tc : TypeChecker, release : Bool) -> QbeGen {
  QbeGen::{
    tc: tc,
    release: release,
    struct_order: [],
    enum_order: [],
    const_order: [],
    strings: [],
    string_ids: Map([]),
    cstrings: [],
    cstring_ids: Map([]),
    slot_drop_masks: [],
    slot_drop_seen: Map([]),
    fn_wrappers: [],
    fn_wrapper_seen: Map([]),
    extra_fns: [],
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
  let slot = qbe_alloc_slot(g)
  let loc = QbeLocal::{ name: name, slot: slot, ty: ty, owned: owned }
  let top = g.scopes[g.scopes.length() - 1]
  top.locals.push(loc)
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
  qbe_emit(g, obj + " =l call $m2_alloc(w 16, w 5, l " + drop_sym + ")")
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
  qbe_emit(g, obj + " =l call $m2_alloc(w 16, w 5, l " + drop_sym + ")")
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
  while i < arg_vals.length() {
    sb.write_string(", l ")
    sb.write_string(arg_vals[i])
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
  let arg_vals : Array[String] = []
  let arg_tys : Array[Ty] = []
  let mut i = 0
  while i < args.length() {
    let av = qbe_emit_expr(g, args[i], None)
    arg_vals.push(av.reg)
    arg_tys.push(av.ty)
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
  if name == "io_println" {
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
  } else if name == "args_get" {
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l call $m2_world_args(l " + w_val + ")")
    rty = TArray(TString)
  } else if name == "world_argc" {
    let r64 = qbe_tmp(g)
    qbe_emit(g, r64 + " =l call $m2_world_argc(l " + w_val + ")")
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w copy " + r64)
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extsw " + rw)
    rty = TInt
  } else if name == "world_argv" {
    let idx = if arg_vals.length() > off { arg_vals[off] } else { "0" }
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
    let rw = qbe_tmp(g)
    qbe_emit(g, rw + " =w call $m2_world_exec(l " + w_val + ", l " + arr + ")")
    res = qbe_tmp(g)
    qbe_emit(g, res + " =l extsw " + rw)
    rty = TInt
  }
  let mut j = 0
  while j < arg_vals.length() {
    qbe_rc_dec(g, arg_vals[j], arg_tys[j])
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
    return qval(qbe_emit_some(g, av.reg, av.ty), TOption(av.ty))
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
      return qval(qbe_emit_result(g, 0, av.reg, av.ty, ety), TResult(av.ty, ety))
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
      return qval(qbe_emit_result(g, 1, av.reg, oty, av.ty), TResult(oty, av.ty))
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
      let payload_sz = (1 + arg_vals.length()) * 8
      let drop_sym = if einfo.decl.type_params.length() == 0 {
        "$m2_drop_enum_" + resolved_enum
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
        " =l call $m2_alloc(w " +
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
        qbe_emit(g, "storel " + arg_vals[fi] + ", " + p)
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
    " =l call $m2_alloc(w " +
    (n_slots * 8).to_string() +
    ", w 6, l " +
    drop_sym +
    ")",
  )
  qbe_emit(g, "storel " + fn_sym + ", " + env_obj)
  let mut ki = 0
  while ki < cap_locals.length() {
    let loc = cap_locals[ki]
    let v = qbe_tmp(g)
    qbe_emit(g, v + " =l loadl " + loc.slot)
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
  let saved_term = g.block_term

  g.fn_allocs = StringBuilder()
  g.fn_body = StringBuilder()
  g.scopes = []
  g.loop_breaks = []
  g.loop_conts = []
  g.loop_depths = []
  g.cur_ret_ty = ret_ty
  g.block_term = false

  qbe_scope_push(g)
  ki = 0
  while ki < cap_locals.length() {
    let cap = cap_locals[ki]
    let loc = qbe_define_local(g, cap.name, cap.ty, false)
    let off = (ki + 1) * 8
    let p = qbe_tmp(g)
    qbe_emit(g, p + " =l add %env, " + off.to_string())
    let v = qbe_tmp(g)
    qbe_emit(g, v + " =l loadl " + p)
    qbe_emit(g, "storel " + v + ", " + loc.slot)
    ki = ki + 1
  }
  pi = 0
  while pi < params.length() {
    let loc = qbe_define_local(g, params[pi].name, ptys[pi], false)
    qbe_emit(g, "storel %p" + pi.to_string() + ", " + loc.slot)
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
      qbe_scope_pop(g)
      qbe_emit_term(g, "ret " + bres.reg)
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
  g.block_term = saved_term

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
  let obj_v = qbe_emit_expr(g, obj_expr, None)
  let obj_val = obj_v.reg
  let recv_ty = obj_v.ty
  match recv_ty {
    TInt => {
      if method_name == "to_string" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_int_to_str(l " + obj_val + ")")
        return qval(r, TString)
      }
      if method_name == "to_int64" {
        return qval(obj_val, TInt64)
      }
      if method_name == "to_int" {
        return qval(obj_val, TInt)
      }
      if method_name == "unsafe_to_char" {
        return qval(obj_val, TChar)
      }
      if method_name == "to_byte" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l and " + obj_val + ", 255")
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
        let r = qbe_tmp(g)
        qbe_emit(g, w + " =w copy " + obj_val)
        qbe_emit(g, r + " =l extsw " + w)
        return qval(r, TInt)
      }
      if method_name == "to_int64" {
        return qval(obj_val, TInt64)
      }
    }
    TDouble => {
      if method_name == "to_int" {
        let d = qbe_tmp(g)
        let w = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, d + " =d cast " + obj_val)
        qbe_emit(g, w + " =w dtosi " + d)
        qbe_emit(g, r + " =l extsw " + w)
        return qval(r, TInt)
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
        return qval(obj_val, TInt)
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
        return qval(obj_val, TInt)
      }
    TString => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_str_len(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, rw + " =w copy " + r64)
        qbe_emit(g, r + " =l extsw " + rw)
        return qval(r, TInt)
      }
      if method_name == "to_string" {
        return qval(obj_val, TString)
      }
      if method_name == "code_unit_at" {
        let iv = qbe_emit_expr(g, args[0], Some(TInt))
        let bw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, bw + " =w call $m2_str_byte_at(l " + obj_val + ", l " + iv.reg + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, r + " =l extsw " + bw)
        return qval(r, TInt)
      }
      if method_name == "slice" {
        let a = qbe_emit_expr(g, args[0], Some(TInt))
        let b = qbe_emit_expr(g, args[1], Some(TInt))
        let r = qbe_tmp(g)
        qbe_emit(
          g,
          r + " =l call $m2_str_slice(l " + obj_val + ", l " + a.reg + ", l " + b.reg + ")",
        )
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, TString)
      }
    }
    TStringBuilder => {
      if method_name == "write_string" {
        let sv = qbe_emit_expr(g, args[0], Some(TString))
        qbe_emit(g, "call $m2_strbuf_push_str(l " + obj_val + ", l " + sv.reg + ")")
        qbe_rc_dec(g, sv.reg, sv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "write_char" {
        let cv = qbe_emit_expr(g, args[0], Some(TChar))
        let cw = qbe_tmp(g)
        qbe_emit(g, cw + " =w copy " + cv.reg)
        qbe_emit(g, "call $m2_strbuf_push_char(l " + obj_val + ", w " + cw + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "to_string" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_strbuf_to_str(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, TString)
      }
      if method_name == "reset" {
        qbe_emit(g, "call $m2_strbuf_reset(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
    }
    TArray(elem) => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_arr_len(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, rw + " =w copy " + r64)
        qbe_emit(g, r + " =l extsw " + rw)
        return qval(r, TInt)
      }
      if method_name == "push" {
        let vv = qbe_emit_expr(g, args[0], Some(elem))
        qbe_emit(g, "call $m2_arr_push(l " + obj_val + ", l " + vv.reg + ")")
        qbe_rc_dec(g, vv.reg, vv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "pop" {
        let n = qbe_tmp(g)
        qbe_emit(g, n + " =l call $m2_arr_len(l " + obj_val + ")")
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
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(elem))
      }
      if method_name == "copy" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_arr_copy(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, TArray(elem))
      }
    }
    TMap(kty, vty) => {
      if method_name == "length" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_map_len(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, rw + " =w copy " + r64)
        qbe_emit(g, r + " =l extsw " + rw)
        return qval(r, TInt)
      }
      if method_name == "set" {
        let kv = qbe_emit_expr(g, args[0], Some(kty))
        let vv = qbe_emit_expr(g, args[1], Some(vty))
        qbe_emit(
          g,
          "call $m2_map_set(l " + obj_val + ", l " + kv.reg + ", l " + vv.reg + ")",
        )
        qbe_rc_dec(g, kv.reg, kv.ty)
        qbe_rc_dec(g, vv.reg, vv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "contains" {
        let kv = qbe_emit_expr(g, args[0], Some(kty))
        let hw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, hw + " =w call $m2_map_has(l " + obj_val + ", l " + kv.reg + ")")
        qbe_rc_dec(g, kv.reg, kv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, r + " =l extuw " + hw)
        return qval(r, TBool)
      }
      if method_name == "remove" {
        let kv = qbe_emit_expr(g, args[0], Some(kty))
        qbe_emit(g, "call $m2_map_remove(l " + obj_val + ", l " + kv.reg + ")")
        qbe_rc_dec(g, kv.reg, kv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "get" {
        let kv = qbe_emit_expr(g, args[0], Some(kty))
        let hw = qbe_tmp(g)
        qbe_emit(g, hw + " =w call $m2_map_has(l " + obj_val + ", l " + kv.reg + ")")
        let res_slot = qbe_alloc_slot(g)
        let l_hit = qbe_lbl(g, "mget_hit")
        let l_miss = qbe_lbl(g, "mget_miss")
        let l_end = qbe_lbl(g, "mget_end")
        qbe_emit_term(g, "jnz " + hw + ", " + l_hit + ", " + l_miss)
        qbe_emit_lbl(g, l_hit)
        let mv = qbe_tmp(g)
        qbe_emit(g, mv + " =l call $m2_map_get(l " + obj_val + ", l " + kv.reg + ")")
        qbe_rc_inc(g, mv, vty)
        let some_obj = qbe_emit_some(g, mv, vty)
        qbe_emit(g, "storel " + some_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_miss)
        let none_obj = qbe_emit_none(g)
        qbe_emit(g, "storel " + none_obj + ", " + res_slot)
        qbe_emit_term(g, "jmp " + l_end)
        qbe_emit_lbl(g, l_end)
        qbe_rc_dec(g, kv.reg, kv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(vty))
      }
      if method_name == "copy" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_map_copy(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, TMap(kty, vty))
      }
      if method_name == "keys" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_map_keys(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, TArray(kty))
      }
    }
    TChannel(elem) => {
      if method_name == "send" {
        let vv = qbe_emit_expr(g, args[0], Some(elem))
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, rw + " =w call $m2_chan_send(l " + obj_val + ", l " + vv.reg + ")")
        qbe_rc_dec(g, vv.reg, vv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
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
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l loadl " + res_slot)
        return qval(r, TOption(elem))
      }
      if method_name == "close" {
        qbe_emit(g, "call $m2_chan_close(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
    }
    TMutex(elem) => {
      if method_name == "lock" {
        let r = qbe_tmp(g)
        qbe_emit(g, r + " =l call $m2_mutex_lock(l " + obj_val + ")")
        qbe_rc_inc(g, r, elem)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval(r, elem)
      }
      if method_name == "set" {
        let vv = qbe_emit_expr(g, args[0], Some(elem))
        qbe_emit(g, "call $m2_mutex_set(l " + obj_val + ", l " + vv.reg + ")")
        qbe_rc_dec(g, vv.reg, vv.ty)
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "unlock" {
        qbe_emit(g, "call $m2_mutex_unlock(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "with_lock" {
        let fv = qbe_emit_expr(g, args[0], None)
        let cur_v = qbe_tmp(g)
        qbe_emit(g, cur_v + " =l call $m2_mutex_lock(l " + obj_val + ")")
        qbe_rc_inc(g, cur_v, elem)
        let r = qbe_emit_closure_call(g, fv.reg, [cur_v], [elem])
        qbe_emit(g, "call $m2_mutex_unlock(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        let rty = match fv.ty {
          TFn(_, rt) => rt
          _ =>
            match expected {
              Some(t) => t
              None => TUnit
            }
        }
        return qval(r, rty)
      }
    }
    TAtomicInt => {
      if method_name == "load" {
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(g, r64 + " =l call $m2_atomic_load(l " + obj_val + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, rw + " =w copy " + r64)
        qbe_emit(g, r + " =l extsw " + rw)
        return qval(r, TInt)
      }
      if method_name == "store" {
        let vv = qbe_emit_expr(g, args[0], Some(TInt))
        qbe_emit(g, "call $m2_atomic_store(l " + obj_val + ", l " + vv.reg + ")")
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        return qval("0", TUnit)
      }
      if method_name == "fetch_add" {
        let dv = qbe_emit_expr(g, args[0], Some(TInt))
        let r64 = qbe_tmp(g)
        let rw = qbe_tmp(g)
        let r = qbe_tmp(g)
        qbe_emit(
          g,
          r64 + " =l call $m2_atomic_fetch_add(l " + obj_val + ", l " + dv.reg + ")",
        )
        qbe_emit(g, "call $m2_rc_dec(l " + obj_val + ")")
        qbe_emit(g, rw + " =w copy " + r64)
        qbe_emit(g, r + " =l extsw " + rw)
        return qval(r, TInt)
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
          let mut i = 0
          while i < args.length() {
            let p_idx = i + 1
            let exp_p : Option[Ty] = if p_idx < minfo.param_tys.length() {
              Some(subst_ty(minfo.param_tys[p_idx], subst))
            } else {
              None
            }
            let av = qbe_emit_expr(g, args[i], exp_p)
            if p_idx < minfo.param_tys.length() {
              unify_tparams(minfo.param_tys[p_idx], av.ty, subst)
            }
            arg_vals.push(av.reg)
            arg_tys.push(av.ty)
            i = i + 1
          }
          let res = qbe_tmp(g)
          let sb = StringBuilder()
          sb.write_string(res)
          sb.write_string(" =l call $m2_m_")
          sb.write_string(sname)
          sb.write_string("__")
          sb.write_string(method_name)
          sb.write_string("(")
          let mut j = 0
          while j < arg_vals.length() {
            if j > 0 {
              sb.write_string(", ")
            }
            sb.write_string("l ")
            sb.write_string(arg_vals[j])
            j = j + 1
          }
          let mut tpi = 0
          while tpi < minfo.decl.type_params.length() {
            if arg_vals.length() > 0 || tpi > 0 {
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
            qbe_rc_dec(g, arg_vals[j], arg_tys[j])
            j = j + 1
          }
          return qval(res, subst_ty(minfo.ret_ty, subst))
        }
        None => ()
      }
    }
    _ => ()
  }
  qbe_rc_dec(g, obj_val, recv_ty)
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
      qbe_emit(g, eq + " =w ceql " + vreg + ", " + iv.to_string())
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
            let fv = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + vreg + ", " + (i * 8).to_string())
            qbe_emit(g, fv + " =l loadl " + p)
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
        let fv = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + vreg + ", " + ((fi + 1) * 8).to_string())
        qbe_emit(g, fv + " =l loadl " + p)
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
) -> Unit {
  match pat {
    PWild(_) | PBool(_, _) | PInt(_, _) | PString(_, _) | PChar(_, _) => ()
    PIdent(name, _) => {
      qbe_rc_inc(g, vreg, scrut_ty)
      let loc = qbe_define_local(g, name, scrut_ty, true)
      qbe_emit(g, "storel " + vreg + ", " + loc.slot)
    }
    PTuple(subs, _) =>
      match scrut_ty {
        TTuple(elems) => {
          let mut i = 0
          while i < subs.length() && i < elems.length() {
            let p = qbe_tmp(g)
            let fv = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + vreg + ", " + (i * 8).to_string())
            qbe_emit(g, fv + " =l loadl " + p)
            qbe_emit_pat_bind(g, subs[i], fv, elems[i])
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
        let fv = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + vreg + ", " + ((fi + 1) * 8).to_string())
        qbe_emit(g, fv + " =l loadl " + p)
        qbe_emit_pat_bind(g, subs[fi], fv, field_tys[fi])
        fi = fi + 1
      }
    }
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
      qbe_emit(g, t + " =l copy " + v32.to_string())
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
      let t = qbe_tmp(g)
      qbe_emit(g, d + " =d copy d_" + raw)
      qbe_emit(g, t + " =l cast " + d)
      qval(t, TDouble)
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
          let t = qbe_tmp(g)
          qbe_emit(g, t + " =l loadl " + loc.slot)
          qbe_rc_inc(g, t, loc.ty)
          return qval(t, loc.ty)
        }
        None => ()
      }
      match g.tc.consts.get(name) {
        Some(cty) => {
          let t = qbe_tmp(g)
          qbe_emit(g, t + " =l loadl $m2_const_" + name)
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
      qval("0", TError)
    }
    EMove(inner, _) => qbe_emit_expr(g, inner, expected)
    EAs(inner, target, _) => {
      let v = qbe_emit_expr(g, inner, None)
      let rty = resolve_type_expr(g.tc, target, g.cur_tparams)
      qval(v.reg, rty)
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
            let w = qbe_tmp(g)
            let nw = qbe_tmp(g)
            let r = qbe_tmp(g)
            qbe_emit(g, w + " =w copy " + iv.reg)
            qbe_emit(g, nw + " =w neg " + w)
            qbe_emit(g, r + " =l extsw " + nw)
            qval(r, TInt)
          }
          TDouble => {
            let d = qbe_tmp(g)
            let nd = qbe_tmp(g)
            let r = qbe_tmp(g)
            qbe_emit(g, d + " =d cast " + iv.reg)
            qbe_emit(g, nd + " =d neg " + d)
            qbe_emit(g, r + " =l cast " + nd)
            qval(r, TDouble)
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
      let lv = qbe_emit_expr(g, lhs, None)
      let rv = qbe_emit_expr(g, rhs, Some(lv.ty))
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
          let lw = qbe_tmp(g)
          let rw = qbe_tmp(g)
          qbe_emit(g, lw + " =w copy " + lv.reg)
          qbe_emit(g, rw + " =w copy " + rv.reg)
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
            let r = qbe_tmp(g)
            qbe_emit(g, aw + " =w " + aop + " " + lw + ", " + rw)
            qbe_emit(g, r + " =l extsw " + aw)
            qval(r, TInt)
          }
        }
        TDouble => {
          let ld = qbe_tmp(g)
          let rd = qbe_tmp(g)
          qbe_emit(g, ld + " =d cast " + lv.reg)
          qbe_emit(g, rd + " =d cast " + rv.reg)
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
            let r = qbe_tmp(g)
            qbe_emit(g, ad + " =d " + aop + " " + ld + ", " + rd)
            qbe_emit(g, r + " =l cast " + ad)
            qval(r, TDouble)
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
            let rw = qbe_tmp(g)
            let r = qbe_tmp(g)
            let sop = if op == "<<" { "shl" } else { "sar" }
            qbe_emit(g, rw + " =w copy " + rv.reg)
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
    ECall(callee, args, sp) =>
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
            let sv = qbe_emit_expr(g, args[0], Some(TString))
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_sha256_hex(l " + sv.reg + ")")
            qbe_rc_dec(g, sv.reg, sv.ty)
            return qval(r, TString)
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
              let arg_vals : Array[String] = []
              let arg_tys : Array[Ty] = []
              let mut i = 0
              while i < args.length() {
                let exp_p : Option[Ty] = if i < finfo.param_tys.length() {
                  Some(subst_ty(finfo.param_tys[i], subst))
                } else {
                  None
                }
                let av = qbe_emit_expr(g, args[i], exp_p)
                if i < finfo.param_tys.length() {
                  unify_tparams(finfo.param_tys[i], av.ty, subst)
                }
                arg_vals.push(av.reg)
                arg_tys.push(av.ty)
                i = i + 1
              }
              let res = qbe_tmp(g)
              let sb = StringBuilder()
              sb.write_string(res)
              sb.write_string(" =l call $m2_fn_")
              sb.write_string(name)
              sb.write_string("(")
              let mut j = 0
              while j < arg_vals.length() {
                if j > 0 {
                  sb.write_string(", ")
                }
                sb.write_string("l ")
                sb.write_string(arg_vals[j])
                j = j + 1
              }
              let mut tpi = 0
              while tpi < finfo.decl.type_params.length() {
                if arg_vals.length() > 0 || tpi > 0 {
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
              j = 0
              while j < arg_vals.length() {
                qbe_rc_dec(g, arg_vals[j], arg_tys[j])
                j = j + 1
              }
              return qval(res, subst_ty(finfo.ret_ty, subst))
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
              return qval(res, rty)
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
            let eo = if qbe_is_obj_ty(elem) { "1" } else { "0" }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_chan_new(l " + cap_v.reg + ", w " + eo + ")")
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
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_mutex_new(l " + iv.reg + ", w " + vo + ")")
            qbe_rc_dec(g, iv.reg, iv.ty)
            return qval(r, TMutex(iv.ty))
          }
          if qual == "AtomicInt" && mem == "new" {
            let iv = if args.length() >= 1 {
              qbe_emit_expr(g, args[0], Some(TInt))
            } else {
              qval("0", TInt)
            }
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l call $m2_atomic_new(l " + iv.reg + ")")
            return qval(r, TAtomicInt)
          }
          if qual == "Option" || qual == "Result" || g.tc.enums.contains(qual) {
            return qbe_emit_variant_ctor(g, qual, mem, args, expected)
          }
          let key = qual + "::" + mem
          match g.tc.methods.get(key) {
            Some(minfo) => {
              let subst : Map[String, Ty] = Map([])
              match expected {
                Some(et) => unify_tparams(minfo.ret_ty, et, subst)
                None => ()
              }
              let arg_vals : Array[String] = []
              let arg_tys : Array[Ty] = []
              let mut i = 0
              while i < args.length() {
                let exp_p : Option[Ty] = if i < minfo.param_tys.length() {
                  Some(subst_ty(minfo.param_tys[i], subst))
                } else {
                  None
                }
                let av = qbe_emit_expr(g, args[i], exp_p)
                if i < minfo.param_tys.length() {
                  unify_tparams(minfo.param_tys[i], av.ty, subst)
                }
                arg_vals.push(av.reg)
                arg_tys.push(av.ty)
                i = i + 1
              }
              let res = qbe_tmp(g)
              let sb = StringBuilder()
              sb.write_string(res)
              sb.write_string(" =l call $m2_m_")
              sb.write_string(qual)
              sb.write_string("__")
              sb.write_string(mem)
              sb.write_string("(")
              let mut j = 0
              while j < arg_vals.length() {
                if j > 0 {
                  sb.write_string(", ")
                }
                sb.write_string("l ")
                sb.write_string(arg_vals[j])
                j = j + 1
              }
              let mut tpi = 0
              while tpi < minfo.decl.type_params.length() {
                if arg_vals.length() > 0 || tpi > 0 {
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
                qbe_rc_dec(g, arg_vals[j], arg_tys[j])
                j = j + 1
              }
              return qval(res, subst_ty(minfo.ret_ty, subst))
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
          qval(res, rty)
        }
      }
    EField(obj, field_name, _) => {
      let ov = qbe_emit_expr(g, obj, None)
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
                  let r = qbe_tmp(g)
                  qbe_emit(g, p + " =l add " + ov.reg + ", " + (i * 8).to_string())
                  qbe_emit(g, r + " =l loadl " + p)
                  qbe_rc_inc(g, r, fty)
                  qbe_rc_dec(g, ov.reg, ov.ty)
                  return qval(r, fty)
                }
                i = i + 1
              }
              qbe_rc_dec(g, ov.reg, ov.ty)
              qval("0", TError)
            }
            None => {
              qbe_rc_dec(g, ov.reg, ov.ty)
              qval("0", TError)
            }
          }
        _ => {
          qbe_rc_dec(g, ov.reg, ov.ty)
          qval("0", TError)
        }
      }
    }
    EMethodCall(obj, method_name, args, _) =>
      qbe_emit_method_call(g, obj, method_name, args, expected)
    EIndex(obj, idx, _) => {
      let ov = qbe_emit_expr(g, obj, None)
      match ov.ty {
        TArray(elem) => {
          let iv = qbe_emit_expr(g, idx, Some(TInt))
          let r = qbe_tmp(g)
          qbe_emit(g, r + " =l call $m2_arr_get(l " + ov.reg + ", l " + iv.reg + ")")
          qbe_rc_inc(g, r, elem)
          qbe_rc_dec(g, ov.reg, ov.ty)
          qval(r, elem)
        }
        TMap(kty, vty) => {
          let kv = qbe_emit_expr(g, idx, Some(kty))
          let r = qbe_tmp(g)
          qbe_emit(g, r + " =l call $m2_map_get(l " + ov.reg + ", l " + kv.reg + ")")
          qbe_rc_inc(g, r, vty)
          qbe_rc_dec(g, kv.reg, kv.ty)
          qbe_rc_dec(g, ov.reg, ov.ty)
          qval(r, vty)
        }
        TString => {
          let iv = qbe_emit_expr(g, idx, Some(TInt))
          let bw = qbe_tmp(g)
          let r = qbe_tmp(g)
          qbe_emit(g, bw + " =w call $m2_str_byte_at(l " + ov.reg + ", l " + iv.reg + ")")
          qbe_rc_dec(g, ov.reg, ov.ty)
          qbe_emit(g, r + " =l extsw " + bw)
          qval(r, TInt)
        }
        _ => {
          let _ = qbe_emit_expr(g, idx, None)
          qbe_rc_dec(g, ov.reg, ov.ty)
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
        qbe_emit(g, "call $m2_arr_push(l " + arr + ", l " + elem_vals[i] + ")")
        qbe_rc_dec(g, elem_vals[i], elem_tys[i])
        i = i + 1
      }
      qval(arr, TArray(elem_ty))
    }
    EStructLit(sname, fields, _) => {
      let resolved_name = if sname != "" {
        sname
      } else {
        match expected {
          Some(TStruct(en, _)) => en
          _ => ""
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
            slot_vals.push("0")
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
              "$m2_drop_struct_" + resolved_name
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
          qbe_emit(
            g,
            obj +
            " =l call $m2_alloc(w " +
            payload_sz.to_string() +
            ", w 4, l " +
            drop_sym +
            ")",
          )
          let mut k = 0
          while k < n_fields {
            let p = qbe_tmp(g)
            qbe_emit(g, p + " =l add " + obj + ", " + (k * 8).to_string())
            qbe_emit(g, "storel " + slot_vals[k] + ", " + p)
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
      qbe_emit(
        g,
        obj + " =l call $m2_alloc(w " + sz.to_string() + ", w 4, l " + drop_sym + ")",
      )
      i = 0
      while i < vals.length() {
        let p = qbe_tmp(g)
        qbe_emit(g, p + " =l add " + obj + ", " + (i * 8).to_string())
        qbe_emit(g, "storel " + vals[i] + ", " + p)
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
      let cv = qbe_emit_expr(g, cond, Some(TBool))
      let res_slot = qbe_alloc_slot(g)
      let l_then = qbe_lbl(g, "if_t")
      let l_else = qbe_lbl(g, "if_f")
      let l_end = qbe_lbl(g, "if_e")
      match else_opt {
        None => {
          qbe_emit_term(g, "jnz " + cv.reg + ", " + l_then + ", " + l_end)
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
          qbe_emit_term(g, "jnz " + cv.reg + ", " + l_then + ", " + l_else)
          qbe_emit_lbl(g, l_then)
          qbe_scope_push(g)
          let tv = qbe_emit_stmts(g, then_stmts, expected)
          let then_term = g.block_term
          if !then_term {
            qbe_emit(g, "storel " + tv.reg + ", " + res_slot)
          }
          qbe_scope_pop(g)
          qbe_emit_term(g, "jmp " + l_end)
          qbe_emit_lbl(g, l_else)
          qbe_scope_push(g)
          let ev = qbe_emit_expr(g, el, expected)
          let else_term = g.block_term
          if !else_term {
            qbe_emit(g, "storel " + ev.reg + ", " + res_slot)
          }
          qbe_scope_pop(g)
          qbe_emit_term(g, "jmp " + l_end)
          qbe_emit_lbl(g, l_end)
          let out_ty = match tv.ty {
            TNever => ev.ty
            _ => tv.ty
          }
          if then_term && else_term {
            qval("0", TNever)
          } else {
            let r = qbe_tmp(g)
            qbe_emit(g, r + " =l loadl " + res_slot)
            qval(r, out_ty)
          }
        }
      }
    }
    EMatch(scrut, arms, sp) => {
      qbe_scope_push(g)
      let sv = qbe_emit_expr(g, scrut, None)
      let scrut_loc = qbe_define_local(g, "__match_scrut", sv.ty, true)
      qbe_emit(g, "storel " + sv.reg + ", " + scrut_loc.slot)
      let res_slot = qbe_alloc_slot(g)
      let l_end = qbe_lbl(g, "match_end")
      let mut res_ty : Option[Ty] = expected
      let mut i = 0
      while i < arms.length() {
        let arm = arms[i]
        let l_next = qbe_lbl(g, "match_next")
        let cur_sv = qbe_tmp(g)
        qbe_emit(g, cur_sv + " =l loadl " + scrut_loc.slot)
        qbe_emit_pat_test(g, arm.pat, cur_sv, sv.ty, l_next)
        qbe_scope_push(g)
        let bind_sv = qbe_tmp(g)
        qbe_emit(g, bind_sv + " =l loadl " + scrut_loc.slot)
        qbe_emit_pat_bind(g, arm.pat, bind_sv, sv.ty)
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
          qbe_emit(g, "storel " + bv.reg + ", " + res_slot)
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
      let r = qbe_tmp(g)
      qbe_emit(g, r + " =l loadl " + res_slot)
      qval(r, final_ty)
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
    SLet(name, _, ty_expr, init, _) => {
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
        let loc = qbe_define_local(g, name, final_ty, true)
        qbe_emit(g, "storel " + iv.reg + ", " + loc.slot)
      }
      qval("0", TUnit)
    }
    SAssign(lhs, rhs, _) => {
      match lhs {
        EIdent(name, _) =>
          match qbe_lookup_local(g, name) {
            Some(loc) => {
              let rv = qbe_emit_expr(g, rhs, Some(loc.ty))
              let old = qbe_tmp(g)
              qbe_emit(g, old + " =l loadl " + loc.slot)
              qbe_emit(g, "storel " + rv.reg + ", " + loc.slot)
              if loc.owned {
                qbe_rc_dec(g, old, loc.ty)
              }
            }
            None => {
              let rv = qbe_emit_expr(g, rhs, None)
              let loc = qbe_define_local(g, name, rv.ty, true)
              qbe_emit(g, "storel " + rv.reg + ", " + loc.slot)
            }
          }
        EField(obj, fname, _) => {
          let ov = qbe_emit_expr(g, obj, None)
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
                      let p = qbe_tmp(g)
                      let old = qbe_tmp(g)
                      qbe_emit(g, p + " =l add " + ov.reg + ", " + (i * 8).to_string())
                      qbe_emit(g, old + " =l loadl " + p)
                      qbe_emit(g, "storel " + rv.reg + ", " + p)
                      qbe_rc_dec(g, old, fty)
                      break
                    }
                    i = i + 1
                  }
                }
                None => ()
              }
            _ => ()
          }
          qbe_rc_dec(g, ov.reg, ov.ty)
        }
        EIndex(obj, idx, _) => {
          let ov = qbe_emit_expr(g, obj, None)
          match ov.ty {
            TArray(elem) => {
              let iv = qbe_emit_expr(g, idx, Some(TInt))
              let rv = qbe_emit_expr(g, rhs, Some(elem))
              qbe_emit(
                g,
                "call $m2_arr_set(l " + ov.reg + ", l " + iv.reg + ", l " + rv.reg + ")",
              )
              qbe_rc_dec(g, rv.reg, rv.ty)
            }
            TMap(kty, vty) => {
              let kv = qbe_emit_expr(g, idx, Some(kty))
              let rv = qbe_emit_expr(g, rhs, Some(vty))
              qbe_emit(
                g,
                "call $m2_map_set(l " + ov.reg + ", l " + kv.reg + ", l " + rv.reg + ")",
              )
              qbe_rc_dec(g, kv.reg, kv.ty)
              qbe_rc_dec(g, rv.reg, rv.ty)
            }
            _ => ()
          }
          qbe_rc_dec(g, ov.reg, ov.ty)
        }
        _ => {
          let rv = qbe_emit_expr(g, rhs, None)
          qbe_rc_dec(g, rv.reg, rv.ty)
        }
      }
      qval("0", TUnit)
    }
    SWhile(cond, body, _) => {
      let l_cond = qbe_lbl(g, "wh_c")
      let l_body = qbe_lbl(g, "wh_b")
      let l_end = qbe_lbl(g, "wh_e")
      qbe_emit_term(g, "jmp " + l_cond)
      qbe_emit_lbl(g, l_cond)
      let cv = qbe_emit_expr(g, cond, Some(TBool))
      qbe_emit_term(g, "jnz " + cv.reg + ", " + l_body + ", " + l_end)
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
      let cv = qbe_emit_expr(g, cond, Some(TBool))
      qbe_emit_term(g, "jnz " + cv.reg + ", " + l_body + ", " + l_end)
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
      let rv = match opt {
        Some(e) => qbe_emit_expr(g, e, Some(g.cur_ret_ty)).reg
        None => "0"
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
      g.block_term = false

      qbe_scope_push(g)
      let mut pi = 0
      while pi < fd.params.length() && pi < finfo.param_tys.length() {
        let loc = qbe_define_local(g, fd.params[pi].name, finfo.param_tys[pi], false)
        qbe_emit(g, "storel %p" + pi.to_string() + ", " + loc.slot)
        pi = pi + 1
      }
      let bres = qbe_emit_stmts(g, fd.body, Some(finfo.ret_ty))
      if !g.block_term {
        qbe_scope_pop(g)
        qbe_emit_term(g, "ret " + bres.reg)
      } else {
        let _ = g.scopes.pop()
      }

      let out = StringBuilder()
      let sym = if fd.receiver_type != "" {
        "$m2_m_" + fd.receiver_type + "__" + fd.name
      } else {
        "$m2_fn_" + fd.name
      }
      if fd.is_pub {
        out.write_string("export ")
      }
      out.write_string("function l ")
      out.write_string(sym)
      out.write_string("(")
      pi = 0
      while pi < fd.params.length() {
        if pi > 0 {
          out.write_string(", ")
        }
        out.write_string("l %p")
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
            out.write_string("function $m2_drop_struct_")
            out.write_string(sname)
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
          out.write_string("function $m2_drop_enum_")
          out.write_string(ename)
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
        out.write_string(") {\n@start\n    %r =l call $m2_fn_")
        out.write_string(fname)
        out.write_string("(")
        pi = 0
        while pi < finfo.param_tys.length() {
          if pi > 0 {
            out.write_string(", ")
          }
          out.write_string("l %p")
          out.write_string(pi.to_string())
          pi = pi + 1
        }
        out.write_string(")\n    ret %r\n}\n\n")
      }
      None => ()
    }
    i = i + 1
  }
}

///|
fn build_typechecker_for_codegen(pkg : Package) -> TypeChecker {
  let tc = TypeChecker::{
    structs: Map([]),
    enums: Map([]),
    variant_to_enum: Map([]),
    fns: Map([]),
    methods: Map([]),
    consts: Map([]),
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
        }
      }
      di = di + 1
    }
    fi = fi + 1
  }
  tc
}

///|
pub fn emit_qbe_package(pkg : Package, release : Bool) -> QbeEmitResult {
  let tc = build_typechecker_for_codegen(pkg)
  let g = qbe_new(tc, release)
  let const_decls : Array[ConstDecl] = []
  let fn_decls : Array[FnDecl] = []

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
        DFn(fd) => fn_decls.push(fd)
      }
      di = di + 1
    }
    fi = fi + 1
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
      qbe_emit(g, "storel " + cv.reg + ", $m2_const_" + cd.name)
      ci = ci + 1
    }
    qbe_scope_pop(g)
    qbe_emit_term(g, "ret")
    let csb = StringBuilder()
    csb.write_string("function $m2_init_consts() {\n@start\n")
    csb.write_string(g.fn_allocs.to_string())
    csb.write_string(g.fn_body.to_string())
    csb.write_string("}\n\n")
    init_consts_code = csb.to_string()
  }

  let fns_buf = StringBuilder()
  let mut fni = 0
  while fni < fn_decls.length() {
    fns_buf.write_string(qbe_emit_fn_decl(g, fn_decls[fni]))
    fni = fni + 1
  }

  let out = StringBuilder()
  out.write_string("# Generated by m2c QBE backend (deterministic)\n\n")

  if g.need_none_const {
    out.write_string(
      "data $m2_none_hdr = align 8 { l 0, w 0, w 1, h 5, h 3, w 8, l 0, l 0 }\n",
    )
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
    out.write_string("data $m2_const_")
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

  let mut has_main = false
  match tc.fns.get("main") {
    Some(minfo) => {
      has_main = true
      out.write_string("export function w $main(w %argc, l %argv) {\n@start\n")
      out.write_string("    %w =l call $m2_world_init(w %argc, l %argv)\n")
      if const_decls.length() > 0 {
        out.write_string("    call $m2_init_consts()\n")
      }
      if minfo.param_tys.length() >= 1 {
        out.write_string("    %r =l call $m2_fn_main(l %w)\n")
      } else {
        out.write_string("    %r =l call $m2_fn_main()\n")
      }
      out.write_string("    call $m2_rc_dec(l %w)\n")
      match minfo.ret_ty {
        TInt | TInt64 => {
          out.write_string("    %rw =w copy %r\n")
          out.write_string("    ret %rw\n")
        }
        _ => out.write_string("    ret 0\n")
      }
      out.write_string("}\n")
    }
    None => ()
  }

  QbeEmitResult::{ ssa: out.to_string(), has_main: has_main }
}

///|
pub fn cli_compile_qbe(
  pkg_name : String,
  paths : Array[String],
  sources : Array[String],
  release : Bool,
) -> Result[CompileQbeOut, String] {
  let cr = check_source_files(pkg_name, paths, sources)
  if cr.diagnostics.length() > 0 {
    return Err(check_result_to_json(cr.diagnostics))
  }
  let pkg = parse_package(pkg_name, paths, sources)
  let sig_text = emit_m2sig(pkg)
  let res = emit_qbe_package(pkg, release)
  Ok(CompileQbeOut::{ sig: sig_text, ssa: res.ssa, has_main: res.has_main })
}
