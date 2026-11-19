///| Unit tests for CAS SHA-256, LRU eviction, and QBE codegen determinism

///|
test "cas_sha256_nist_vectors" {
  assert_eq(
    @core.cas_sha256_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @core.cas_sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "cas_lru_eviction_to_80pct_watermark" {
  let idx_text = "k1\t400\t100\nk2\t400\t200\nk3\t300\t300\n"
  let entries = @core.cas_parse_index(idx_text)
  assert_eq(entries.length(), 3)
  // Adding k4 (200 bytes) brings total to 1300 > 1000 -> evicts down to <= 800
  // k1 (400) evicted -> 900 > 800 -> k2 (400) evicted -> 500 <= 800
  let res = @core.cas_touch_and_evict(entries, "k4", 200L, 400L, 1000L)
  assert_eq(res.evicted.length(), 2)
  assert_eq(res.evicted[0], "k1")
  assert_eq(res.evicted[1], "k2")
  assert_eq(res.kept.length(), 2)
}

///|
test "qbe_codegen_deterministic_and_release_strips_assert" {
  let src =
    #|pub fn main(world : World) -> Int {
    #|  debug_assert(true, "ok")
    #|  io_println(world, "hello")
    #|  0
    #|}
  let pkg = @core.parse_package("test", ["main.m2"], [src])
  let dev1 = @core.emit_qbe_package(pkg, false)
  let dev2 = @core.emit_qbe_package(pkg, false)
  assert_eq(dev1.ssa, dev2.ssa)
  assert_eq(dev1.has_main, true)
  assert_eq(dev1.ssa.contains("m2_debug_assert"), true)
  let rel = @core.emit_qbe_package(pkg, true)
  assert_eq(rel.ssa.contains("m2_debug_assert"), false)
}

///|
test "qbe_double_slot_and_cond_branch_fusion" {
  let src =
    #|pub fn loop_fp(n : Int) -> Double {
    #|  let mut s = 0.0
    #|  let mut i = 0
    #|  while i < n {
    #|    s = s + 1.5
    #|    if s > 10.0 {
    #|      break
    #|    }
    #|    i = i + 1
    #|  }
    #|  s
    #|}
  let pkg = @core.parse_package("test", ["fp.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Double slot must initialize with stored d_0.0 (not storel 0) for QBE mem2reg
  assert_eq(res.ssa.contains("stored d_0.0"), true)
  // Compare+branch fusion: no extuw in loop_fp
  assert_eq(res.ssa.contains("extuw"), false)
}

///|
test "qbe_borrow_elision_tree_and_arr_elem_and_bce" {
  let src =
    #|pub enum Tree {
    #|  Leaf
    #|  Node(Tree, Tree)
    #|}
    #|pub fn check_tree(t : Tree) -> Int {
    #|  match t {
    #|    Leaf => 1
    #|    Node(l, r) => 1 + check_tree(l) + check_tree(r)
    #|  }
    #|}
    #|pub struct Body {
    #|  mut x : Double
    #|}
    #|pub fn step(bodies : Array[Body]) -> Unit {
    #|  let n = bodies.length()
    #|  let mut i = 0
    #|  while i < n {
    #|    let b = bodies[i]
    #|    b.x = b.x + 1.0
    #|    i = i + 1
    #|  }
    #|}
  let pkg = @core.parse_package("test", ["opt.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Zero RC inc anywhere; zero RC dec inside check_tree / step (drop_enum_Tree is emitted before fns)
  assert_eq(res.ssa.contains("m2_rc_inc"), false)
  let fn_part = match res.ssa.find("$m2_fn_check_tree") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  assert_eq(fn_part.contains("m2_rc_dec"), false)
  // Conservative BCE removes m2_panic_oob inside `while i < n` where `n = bodies.length()`
  assert_eq(res.ssa.contains("m2_panic_oob"), false)
}

///|
test "qbe_pow2_signed_div_shift" {
  let src =
    #|pub fn half(x : Int) -> Int {
    #|  x / 2
    #|}
    #|pub fn quarter(x : Int) -> Int {
    #|  x / 4
    #|}
  let pkg = @core.parse_package("test", ["div.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  assert_eq(res.ssa.contains("=w div "), false)
  assert_eq(res.ssa.contains("=w sar "), true)
}

///|
test "sig_file_stub_and_sigs_hash_parity" {
  let s1 =
    #|pub struct Pt { x : Int; mut y : Double }
    #|pub let SCALE : Int = 42
    #|pub fn add_pt(p : Pt, k : Int) -> Int { p.x + k }
  let s2 =
    #|pub fn main(world : World) -> Int {
    #|  let p = Pt::{ x: 1, y: 2.0 }
    #|  io_println(world, add_pt(p, SCALE).to_string())
    #|  0
    #|}
  let prep = match @core.cli_prepare_qbe_units("demo", ["a.m2", "b.m2"], [s1, s2]) {
    Ok(p) => p
    Err(e) => fail(e)
  }
  let f0 = prep.pkg.files[0]
  let f1 = prep.pkg.files[1]
  let sig0 = @core.emit_file_sig_entries(f0)
  let sig1 = @core.emit_file_sig_entries(f1)
  let summary = @core.summarize_file_sigs("demo", [sig0, sig1])
  assert_eq(summary.sigs_hash, prep.sigs_hash)
  assert_eq(summary.has_main, true)
  assert_eq(summary.const_units.length(), 1)
  assert_eq(summary.const_units[0], 0)
  let stub0 = @core.emit_file_stub(f0)
  let spr = @core.parse_source("a.m2", stub0)
  assert_eq(spr.diagnostics.length(), 0)
}

///|
test "qbe_map_try_get_match_fusion_and_alloc_uninit" {
  let src =
    #|pub enum Tree {
    #|  Leaf
    #|  Node(Tree, Tree)
    #|}
    #|pub fn make_node(l : Tree, r : Tree) -> Tree {
    #|  Node(l, r)
    #|}
    #|pub fn lookup_int(m : Map[String, Int], k : String) -> Int {
    #|  match m.get(k) {
    #|    Some(v) => v + 1
    #|    None => 0
    #|  }
    #|}
    #|pub fn lookup_rev(m : Map[String, Int], k : String) -> Int {
    #|  match m.get(k) {
    #|    None => -1
    #|    Some(v) => v
    #|  }
    #|}
  let pkg = @core.parse_package("test", ["p3c.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Node(l, r) must use $m2_alloc_uninit (not $m2_alloc)
  assert_eq(res.ssa.contains("$m2_alloc_uninit("), true)
  assert_eq(res.ssa.contains("$m2_alloc("), false)
  // Fused match m.get(k) must emit $m2_map_try_get, never $m2_map_has, and zero Some allocation / RC in lookup_*
  assert_eq(res.ssa.contains("$m2_map_try_get("), true)
  assert_eq(res.ssa.contains("$m2_map_has("), false)
  let lookup_part = match res.ssa.find("$m2_fn_lookup_int") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  assert_eq(lookup_part.contains("$m2_alloc"), false)
  assert_eq(lookup_part.contains("m2_rc_inc"), false)
  assert_eq(lookup_part.contains("m2_rc_dec"), false)
}

///|
test "qbe_p4b_int32_w_regs_and_double_mul2_add" {
  let src =
    #|pub fn sum_int(n : Int) -> Int {
    #|  let mut acc = 0
    #|  let mut i = 0
    #|  while i < n {
    #|    acc = acc + (i * 3 - 1)
    #|    i = i + 1
    #|  }
    #|  acc
    #|}
    #|pub fn double_two(x : Double, y : Double) -> Double {
    #|  2.0 * x + y * 2.0
    #|}
  let pkg = @core.parse_package("test", ["p4b.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Native 32-bit w ABI & local slots, zero extsw in pure Int arithmetic/loops
  assert_eq(res.ssa.contains("function w $m2_fn_sum_int(w %p0)"), true)
  assert_eq(res.ssa.contains("alloc4 4"), true)
  assert_eq(res.ssa.contains("storew "), true)
  assert_eq(res.ssa.contains("=w loadsw "), true)
  assert_eq(res.ssa.contains("extsw"), false)
  // IEEE-754 exact `2.0 * x -> x + x` and `y * 2.0 -> y + y`
  let fn_dbl = match res.ssa.find("$m2_fn_double_two") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  assert_eq(fn_dbl.contains("=d mul "), false)
  assert_eq(fn_dbl.contains("=d add "), true)
}

///|
test "qbe_p4b_loop_invariant_readonly_struct_field_hoist" {
  let src =
    #|pub struct Body {
    #|  mut x : Double
    #|  mut vx : Double
    #|  mass : Double
    #|}
    #|pub fn advance_like(bodies : Array[Body], dt : Double) -> Unit {
    #|  let n = bodies.length()
    #|  let mut i = 0
    #|  while i < n {
    #|    let b = bodies[i]
    #|    let mut j = i + 1
    #|    while j < n {
    #|      let b2 = bodies[j]
    #|      let dx = b.x - b2.x
    #|      let d = math_sqrt(dx * dx)
    #|      let mag = dt / d
    #|      b.vx = b.vx - dx * b2.mass * mag
    #|      b2.vx = b2.vx + dx * b.mass * mag
    #|      j = j + 1
    #|    }
    #|    i = i + 1
    #|  }
    #|}
  let pkg = @core.parse_package("test", ["hoist.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Locate the inner loop (@wh_pinit_...) and verify b.x / b.mass are hoisted before it,
  // and b.vx is scalar-promoted into a local slot with alias guard (@wh_pb_, @wh_pbail_, @wh_pwb_)
  let fn_adv = match res.ssa.find("$m2_fn_advance_like") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  let outer_body = match fn_adv.find("\n@wh_b_") {
    Some(idx) => fn_adv.clamped_view(start=idx + 7).to_owned()
    None => ""
  }
  let inner_pinit = match outer_body.find("\n@wh_pinit_") {
    Some(idx) => idx
    None => 0
  }
  assert_eq(inner_pinit > 0, true)
  let pre_inner = outer_body.clamped_view(end=inner_pinit).to_owned()
  let inner_all = outer_body.clamped_view(start=inner_pinit).to_owned()
  // Both b.x and b.mass must be hoisted into pre_inner (exactly 2 `=d loadd ` before inner @wh_pinit_)
  let mut pre_loads = 0
  let mut ppos = 0
  while ppos < pre_inner.length() {
    let tail = pre_inner.clamped_view(start=ppos).to_owned()
    match tail.find("=d loadd ") {
      Some(off) => {
        pre_loads = pre_loads + 1
        ppos = ppos + off + 9
      }
      None => break
    }
  }
  assert_eq(pre_loads, 2)
  assert_eq(inner_all.contains("@wh_pb_"), true)
  assert_eq(inner_all.contains("@wh_pbail_"), true)
  assert_eq(inner_all.contains("@wh_pwb_"), true)
  assert_eq(inner_all.contains("=w ceql "), true)
}

///|
test "qbe_p4d_array_int_loadl_and_block_immut_field_cse" {
  let src =
    #|pub struct Particle {
    #|  mut vx : Double
    #|  mut vy : Double
    #|  mut vz : Double
    #|  mass : Double
    #|}
    #|pub fn read_int_elem(arr : Array[Int], i : Int) -> Int {
    #|  arr[i]
    #|}
    #|pub fn triple_mass(a : Particle, b : Particle) -> Unit {
    #|  a.vx = b.mass
    #|  a.vy = b.mass
    #|  a.vz = b.mass
    #|}
  let pkg = @core.parse_package("test", ["p4d.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_arr = match res.ssa.find("$m2_fn_read_int_elem") {
    Some(idx) => {
      let rest = res.ssa.clamped_view(start=idx).to_owned()
      match rest.find("\n}\n") {
        Some(e) => rest.clamped_view(end=e).to_owned()
        None => rest
      }
    }
    None => ""
  }
  // Array[Int] element load uses 64-bit `=l loadl` + `=w copy` for ARM64 [xBase, xIdx, lsl #3]
  let after_shl = match fn_arr.find("=l shl ") {
    Some(idx) => fn_arr.clamped_view(start=idx).to_owned()
    None => ""
  }
  assert_eq(after_shl.contains("=l loadl "), true)
  assert_eq(after_shl.contains("=w copy "), true)
  assert_eq(after_shl.contains("=w loadsw "), false)
  // Immutable primitive struct field `b.mass` loaded once across 3 reads in same basic block
  let fn_mass = match res.ssa.find("$m2_fn_triple_mass") {
    Some(idx) => {
      let rest = res.ssa.clamped_view(start=idx).to_owned()
      match rest.find("\n}\n") {
        Some(e) => rest.clamped_view(end=e).to_owned()
        None => rest
      }
    }
    None => ""
  }
  let mut dloads = 0
  let mut pos = 0
  while pos < fn_mass.length() {
    let tail = fn_mass.clamped_view(start=pos).to_owned()
    match tail.find("=d loadd ") {
      Some(off) => {
        dloads = dloads + 1
        pos = pos + off + 9
      }
      None => break
    }
  }
  assert_eq(dloads, 1)
}

///|
test "qbe_p5b_guarded_bottom_tested_loop_rotation" {
  let src =
    #|pub fn count_even(n : Int) -> Int {
    #|  let mut i = 0
    #|  let mut s = 0
    #|  while i < n {
    #|    i = i + 1
    #|    if (i & 1) == 1 {
    #|      continue
    #|    }
    #|    s = s + i
    #|  }
    #|  s
    #|}
  let pkg = @core.parse_package("test", ["rot.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_count_even") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  let b_pos = match fn_s.find("\n@wh_b_") {
    Some(idx) => idx
    None => -1
  }
  let c_pos = match fn_s.find("\n@wh_c_") {
    Some(idx) => idx
    None => -1
  }
  // Bottom-tested: @wh_b_ appears before @wh_c_
  assert_eq(b_pos > 0, true)
  assert_eq(c_pos > b_pos, true)
}

///|
test "qbe_p5b_preloop_bce_versioning_and_extsw_reuse" {
  let src =
    #|pub fn copy_rev_shift(
    #|  n : Int,
    #|  k : Int,
    #|  k2 : Int,
    #|  r : Int,
    #|  perm : Array[Int],
    #|  perm1 : Array[Int],
    #|) -> Unit {
    #|  let mut ci = 0
    #|  while ci < n {
    #|    perm[ci] = perm1[ci]
    #|    ci = ci + 1
    #|  }
    #|  let mut fi = 0
    #|  while fi < k2 {
    #|    let tmp = perm[fi]
    #|    perm[fi] = perm[k - fi]
    #|    perm[k - fi] = tmp
    #|    fi = fi + 1
    #|  }
    #|  let mut si = 0
    #|  while si < r {
    #|    perm1[si] = perm1[si + 1]
    #|    si = si + 1
    #|  }
    #|}
  let pkg = @core.parse_package("test", ["bce_v.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_copy_rev_shift") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  // All 3 loops must be versioned with @wh_vchk_ / @wh_fast_ / @wh_slow_
  let mut fast_count = 0
  let mut pos = 0
  while pos < fn_s.length() {
    let tail = fn_s.clamped_view(start=pos).to_owned()
    match tail.find("\n@wh_fast_") {
      Some(f_off) => {
        let after_fast = tail.clamped_view(start=f_off + 1).to_owned()
        let slow_off = match after_fast.find("\n@wh_slow_") {
          Some(s_off) => s_off
          None => after_fast.length()
        }
        let fast_region = after_fast.clamped_view(end=slow_off).to_owned()
        // Fast region must have zero m2_panic_oob
        assert_eq(fast_region.contains("m2_panic_oob"), false)
        // First loop (`perm[ci] = perm1[ci]`): zero redundant extsw for copied value
        if fast_count == 0 {
          assert_eq(fast_region.contains("=l loadl "), true)
          assert_eq(fast_region.contains("storel "), true)
          // Only index ci needs 1 extsw (for perm1[ci] / perm[ci] index); value copy reuses rl
          let mut ext_cnt = 0
          let mut ep = 0
          while ep < fast_region.length() {
            let et = fast_region.clamped_view(start=ep).to_owned()
            match et.find("=l extsw ") {
              Some(eo) => {
                ext_cnt = ext_cnt + 1
                ep = ep + eo + 9
              }
              None => break
            }
          }
          // 2 index extsw (ci for perm[ci], ci for perm1[ci]), 0 value extsw (would be 3 without Opt 5)
          assert_eq(ext_cnt, 2)
        }
        fast_count = fast_count + 1
        pos = pos + f_off + 10
      }
      None => break
    }
  }
  assert_eq(fast_count, 3)
  // Slow path still retains m2_panic_oob for safety
  assert_eq(fn_s.contains("m2_panic_oob"), true)
}

///|
test "qbe_p5b_loop_carried_square_reuse" {
  let src =
    #|pub fn mandel_iter(cr : Double, ci : Double) -> Bool {
    #|  let mut zr = 0.0
    #|  let mut zi = 0.0
    #|  let mut escaped = false
    #|  let mut iter = 0
    #|  while iter < 50 {
    #|    let tr = zr * zr - zi * zi + cr
    #|    let ti = 2.0 * zr * zi + ci
    #|    zr = tr
    #|    zi = ti
    #|    if zr * zr + zi * zi > 4.0 {
    #|      escaped = true
    #|      break
    #|    }
    #|    iter = iter + 1
    #|  }
    #|  escaped
    #|}
  let pkg = @core.parse_package("test", ["sq.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_mandel_iter") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  assert_eq(fn_s.contains("@wh_sqi_"), true)
  let body_part = match fn_s.find("\n@wh_b_") {
    Some(idx) => fn_s.clamped_view(start=idx).to_owned()
    None => ""
  }
  let mut mul_cnt = 0
  let mut pos = 0
  while pos < body_part.length() {
    let tail = body_part.clamped_view(start=pos).to_owned()
    match tail.find("=d mul ") {
      Some(off) => {
        mul_cnt = mul_cnt + 1
        pos = pos + off + 7
      }
      None => break
    }
  }
  // Only 3 fmul inside loop body (ti = (zr+zr)*zi, new zr*zr, new zi*zi), down from 5
  assert_eq(mul_cnt, 3)
}

///|
test "qbe_p5b_alias_guarded_struct_promotion_and_bailout" {
  let src =
    #|pub struct Acc {
    #|  mut v : Double
    #|  w : Double
    #|}
    #|pub fn pair_update(arr : Array[Acc]) -> Double {
    #|  let n = arr.length()
    #|  let b = arr[0]
    #|  let mut j = 0
    #|  while j < n {
    #|    let b2 = arr[j]
    #|    b.v = b.v + b2.w
    #|    b2.v = b2.v + b.w
    #|    j = j + 1
    #|  }
    #|  b.v
    #|}
  let pkg = @core.parse_package("test", ["alias_prom.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_pair_update") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  assert_eq(fn_s.contains("@wh_pinit_"), true)
  assert_eq(fn_s.contains("@wh_pb_"), true)
  assert_eq(fn_s.contains("=w ceql "), true)
  assert_eq(fn_s.contains("@wh_pbail_"), true)
  assert_eq(fn_s.contains("@wh_pslow_"), true)
  assert_eq(fn_s.contains("@wh_pwb_"), true)
}

///|
test "qbe_p5p_sq_reuse_dead_var_reorder" {
  let src =
    #|pub fn mandel_reorder(cr : Double, ci : Double) -> Bool {
    #|  let mut zr = 0.0
    #|  let mut zi = 0.0
    #|  let mut escaped = false
    #|  let mut iter = 0
    #|  while iter < 50 {
    #|    let tr = zr * zr - zi * zi + cr
    #|    let ti = 2.0 * zr * zi + ci
    #|    zr = tr
    #|    zi = ti
    #|    if zr * zr + zi * zi > 4.0 {
    #|      escaped = true
    #|      break
    #|    }
    #|    iter = iter + 1
    #|  }
    #|  escaped
    #|}
  let pkg = @core.parse_package("test", ["sq_reorder.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_mandel_reorder") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  let body_part = match fn_s.find("\n@wh_b_") {
    Some(idx) => fn_s.clamped_view(start=idx).to_owned()
    None => ""
  }
  // `ti = 2.0 * zr * zi + ci` (`=d mul`) must be emitted before `tr = sq_zr - sq_zi + cr` (`=d sub`)
  let mul_idx = match body_part.find("=d mul ") {
    Some(i) => i
    None => -1
  }
  let sub_idx = match body_part.find("=d sub ") {
    Some(i) => i
    None => -1
  }
  assert_eq(mul_idx >= 0, true)
  assert_eq(sub_idx >= 0, true)
  assert_eq(mul_idx < sub_idx, true)
}

///|
test "qbe_p5p_even_int_div2_sar" {
  let src =
    #|pub fn eval_even(ij : Int) -> Int {
    #|  let a = (ij * (ij + 1)) / 2
    #|  let b = ((ij - 1) * ij) / 2
    #|  let c = (-2 * -1) / 2
    #|  let d = (-10 * -9) / 2
    #|  let e = (ij << 1) / 2
    #|  let f = (2 * ij + 4) / 2
    #|  a + b + c + d + e + f
    #|}
    #|pub fn eval_general(x : Int) -> Int {
    #|  x / 2
    #|}
  let pkg = @core.parse_package("test", ["even_div2.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let even_start = match res.ssa.find("$m2_fn_eval_even") {
    Some(idx) => idx
    None => 0
  }
  let gen_start = match res.ssa.find("$m2_fn_eval_general") {
    Some(idx) => idx
    None => res.ssa.length()
  }
  let even_fn = res.ssa.clamped_view(start=even_start, end=gen_start).to_owned()
  let gen_fn = res.ssa.clamped_view(start=gen_start).to_owned()
  // All 6 even divisions emit direct `=w sar ..., 1` with zero `=w shr ..., 31` sign fixup
  assert_eq(even_fn.contains("=w sar "), true)
  assert_eq(even_fn.contains("=w shr "), false)
  // General unknown-parity x / 2 retains `=w shr ..., 31` sign fixup
  assert_eq(gen_fn.contains("=w shr "), true)
  assert_eq(gen_fn.contains("=w sar "), true)
}

///|
test "qbe_p5p_local_immut_w_to_l_ext_prop" {
  let src =
    #|pub fn rev_swap(perm : Array[Int], k : Int) -> Unit {
    #|  let n = perm.length()
    #|  if k >= n {
    #|    return
    #|  }
    #|  let mut fi = 0
    #|  while fi < k {
    #|    let tmp = perm[fi]
    #|    perm[fi] = perm[k - fi]
    #|    perm[k - fi] = tmp
    #|    fi = fi + 1
    #|  }
    #|}
  let pkg = @core.parse_package("test", ["w2l_local.m2"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$m2_fn_rev_swap") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => ""
  }
  let fast_start = match fn_s.find("\n@wh_fast_") {
    Some(idx) => idx
    None => 0
  }
  let after_fast = fn_s.clamped_view(start=fast_start + 1).to_owned()
  let slow_off = match after_fast.find("\n@wh_slow_") {
    Some(idx) => idx
    None => after_fast.length()
  }
  let fast_region = after_fast.clamped_view(end=slow_off).to_owned()
  assert_eq(fast_region.contains("m2_panic_oob"), false)
  let mut ext_cnt = 0
  let mut ep = 0
  while ep < fast_region.length() {
    let et = fast_region.clamped_view(start=ep).to_owned()
    match et.find("=l extsw ") {
      Some(eo) => {
        ext_cnt = ext_cnt + 1
        ep = ep + eo + 9
      }
      None => break
    }
  }
  // Only 4 index extsw (perm[fi], perm[fi], perm[k-fi], perm[k-fi]); 0 value extsw for `tmp` or `perm[k-fi]`
  assert_eq(ext_cnt, 4)
}
