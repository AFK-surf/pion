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
  let pkg = @core.parse_package("test", ["main.pion"], [src])
  let dev1 = @core.emit_qbe_package(pkg, false)
  let dev2 = @core.emit_qbe_package(pkg, false)
  assert_eq(dev1.ssa, dev2.ssa)
  assert_eq(dev1.has_main, true)
  assert_eq(dev1.ssa.contains("pion_debug_assert"), true)
  let rel = @core.emit_qbe_package(pkg, true)
  assert_eq(rel.ssa.contains("pion_debug_assert"), false)
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
  let pkg = @core.parse_package("test", ["fp.pion"], [src])
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
  let pkg = @core.parse_package("test", ["opt.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Zero RC inc anywhere; zero RC dec inside check_tree / step (drop_enum_Tree is emitted before fns)
  assert_eq(res.ssa.contains("pion_rc_inc"), false)
  let fn_part = match res.ssa.find("$pion_fn_check_tree") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  assert_eq(fn_part.contains("pion_rc_dec"), false)
  // Conservative BCE removes pion_panic_oob inside `while i < n` where `n = bodies.length()`
  assert_eq(res.ssa.contains("pion_panic_oob"), false)
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
  let pkg = @core.parse_package("test", ["div.pion"], [src])
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
  let prep = match @core.cli_prepare_qbe_units("demo", ["a.pion", "b.pion"], [s1, s2]) {
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
  let spr = @core.parse_source("a.pion", stub0)
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
  let pkg = @core.parse_package("test", ["p3c.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Node(l, r) must use $pion_alloc_uninit (not $pion_alloc)
  assert_eq(res.ssa.contains("$pion_alloc_uninit("), true)
  assert_eq(res.ssa.contains("$pion_alloc("), false)
  // Fused match m.get(k) must emit $pion_map_try_get, never $pion_map_has, and zero Some allocation / RC in lookup_*
  assert_eq(res.ssa.contains("$pion_map_try_get("), true)
  assert_eq(res.ssa.contains("$pion_map_has("), false)
  let lookup_part = match res.ssa.find("$pion_fn_lookup_int") {
    Some(idx) => res.ssa.clamped_view(start=idx).to_owned()
    None => res.ssa
  }
  assert_eq(lookup_part.contains("$pion_alloc"), false)
  assert_eq(lookup_part.contains("pion_rc_inc"), false)
  assert_eq(lookup_part.contains("pion_rc_dec"), false)
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
  let pkg = @core.parse_package("test", ["p4b.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Native 32-bit w ABI & local slots, zero extsw in pure Int arithmetic/loops
  assert_eq(res.ssa.contains("function w $pion_fn_sum_int(w %p0)"), true)
  assert_eq(res.ssa.contains("alloc4 4"), true)
  assert_eq(res.ssa.contains("storew "), true)
  assert_eq(res.ssa.contains("=w loadsw "), true)
  assert_eq(res.ssa.contains("extsw"), false)
  // IEEE-754 exact `2.0 * x -> x + x` and `y * 2.0 -> y + y`
  let fn_dbl = match res.ssa.find("$pion_fn_double_two") {
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
  let pkg = @core.parse_package("test", ["hoist.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  // Locate the inner loop (@wh_pinit_...) and verify b.x / b.mass are hoisted before it,
  // and b.vx is scalar-promoted into a local slot with alias guard (@wh_pb_, @wh_pbail_, @wh_pwb_)
  let fn_adv = match res.ssa.find("$pion_fn_advance_like") {
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
  let pkg = @core.parse_package("test", ["p4d.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_arr = match res.ssa.find("$pion_fn_read_int_elem") {
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
  let fn_mass = match res.ssa.find("$pion_fn_triple_mass") {
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
  let pkg = @core.parse_package("test", ["rot.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_count_even") {
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
  let pkg = @core.parse_package("test", ["bce_v.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_copy_rev_shift") {
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
        // Fast region must have zero pion_panic_oob
        assert_eq(fast_region.contains("pion_panic_oob"), false)
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
  // Slow path still retains pion_panic_oob for safety
  assert_eq(fn_s.contains("pion_panic_oob"), true)
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
  let pkg = @core.parse_package("test", ["sq.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_mandel_iter") {
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
  let pkg = @core.parse_package("test", ["alias_prom.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_pair_update") {
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
  let pkg = @core.parse_package("test", ["sq_reorder.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_mandel_reorder") {
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
  let pkg = @core.parse_package("test", ["even_div2.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let even_start = match res.ssa.find("$pion_fn_eval_even") {
    Some(idx) => idx
    None => 0
  }
  let gen_start = match res.ssa.find("$pion_fn_eval_general") {
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
  let pkg = @core.parse_package("test", ["w2l_local.pion"], [src])
  let res = @core.emit_qbe_package(pkg, true)
  let fn_s = match res.ssa.find("$pion_fn_rev_swap") {
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
  assert_eq(fast_region.contains("pion_panic_oob"), false)
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

///|
test "p6b_cas_compiler_fingerprint_invalidates_keys" {
  let fp1 = @core.cas_compiler_fp(1000L, 2000L, "")
  let fp2 = @core.cas_compiler_fp(1001L, 2000L, "")
  let fp3 = @core.cas_compiler_fp(1000L, 2000L, "salt-a")
  assert_not_eq(fp1, fp2)
  assert_not_eq(fp1, fp3)
  let k1 = @core.cas_compute_key("p", ["a.pion"], ["pub fn f() -> Int { 1 }"], [], "arm64_apple", false, fp1)
  let k2 = @core.cas_compute_key("p", ["a.pion"], ["pub fn f() -> Int { 1 }"], [], "arm64_apple", false, fp2)
  assert_not_eq(k1, k2)
  let u1 = @core.cas_compute_unit_key("p", 0, "a.pion", "h1", "s1", "arm64_apple", false, fp1)
  let u2 = @core.cas_compute_unit_key("p", 0, "a.pion", "h1", "s1", "arm64_apple", false, fp3)
  assert_not_eq(u1, u2)
}

///|
test "p6b_multi_pkg_qbe_mangling_and_test_runner_emit" {
  let math_src =
    #|pub let BASE : Int = 10
    #|pub fn add(a : Int, b : Int) -> Int { a + b + BASE }
  let math_cr = @core.check_source_files_with_imports("math", ["math.pion"], [math_src], [], true)
  assert_eq(math_cr.diagnostics.length(), 0)
  let math_qbe = @core.emit_qbe_package_multi(math_cr.pkg, math_cr.tc, false, false, [])
  assert_eq(math_qbe.ssa.contains("export function w $pion_pkg_math_fn_add("), true)
  assert_eq(math_qbe.ssa.contains("export function $pion_pkg_math_init_consts()"), true)
  assert_eq(math_qbe.ssa.contains("export data $pion_pkg_math_const_BASE"), true)
  assert_eq(math_qbe.has_main, false)

  let app_src =
    #|import "math"
    #|pub fn main() -> Int { math::add(1, 2) }
    #|test "adds" { debug_assert(math::add(1, 2) == 13, "sum") }
  let imported = [@core.imported_pkg_new("math", math_cr.tc)]
  let app_cr = @core.check_source_files_with_imports("app", ["app.pion"], [app_src], imported, true)
  assert_eq(app_cr.diagnostics.length(), 0)
  let build_qbe = @core.emit_qbe_package_multi(app_cr.pkg, app_cr.tc, true, true, ["math"])
  assert_eq(build_qbe.ssa.contains("call $pion_pkg_math_init_consts()"), true)
  assert_eq(build_qbe.ssa.contains("call $pion_pkg_math_fn_add("), true)
  assert_eq(build_qbe.ssa.contains("pion_test_fn_0"), false)

  let test_qbe = @core.emit_qbe_test_package(app_cr.pkg, app_cr.tc, ["math"])
  assert_eq(test_qbe.test_names.length(), 1)
  assert_eq(test_qbe.test_names[0], "adds")
  assert_eq(test_qbe.ssa.contains("function $pion_test_fn_0()"), true)
  assert_eq(test_qbe.ssa.contains("pion_debug_assert"), true)
  let rep = @core.format_test_report_json(["a", "b"], [true, false])
  assert_eq(rep, "{\"ok\":false,\"passed\":1,\"failed\":1,\"tests\":[{\"name\":\"a\",\"ok\":true},{\"name\":\"b\",\"ok\":false}]}")
}

///|
test "p6c_stdlib_qbe_codegen_symbols" {
  let src =
    #|pub fn main(world : World) -> Int {
    #|  let s = "  a,b  ".trim()
    #|  let _b1 = s.starts_with("a")
    #|  let _b2 = s.ends_with("b")
    #|  let _b3 = s.contains(",")
    #|  let _i = s.index_of(",")
    #|  let _sp = s.split(",")
    #|  let r = s.replace(",", "-")
    #|  let bs = r.to_bytes()
    #|  let buf = Bytes::new(2)
    #|  buf[0] = b'x'
    #|  let _c = buf[0]
    #|  let _n = buf.length()
    #|  let j = buf.slice(0, 1).concat(bs)
    #|  let _t = j.to_string()
    #|  let _m = math_abs(-1.0) + math_floor(1.5) + math_ceil(1.2) + math_sin(0.0) + math_cos(0.0) + math_pow(2.0, 3.0)
    #|  let _w = fs_write_bytes(world, "/tmp/p6c", j)
    #|  let _rb = fs_read_bytes(world, "/tmp/p6c")
    #|  let _ap = fs_append(world, "/tmp/p6c", "!")
    #|  let _mt = fs_mtime_ms(world, "/tmp/p6c")
    #|  let _ec = proc_exec_capture(world, ["echo", "ok"])
    #|  0
    #|}
  let cr = @core.check_source_files_with_imports("p6c_std", ["std.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  assert_eq(ssa.contains("call $pion_str_trim("), true)
  assert_eq(ssa.contains("call $pion_str_starts_with("), true)
  assert_eq(ssa.contains("call $pion_str_ends_with("), true)
  assert_eq(ssa.contains("call $pion_str_contains("), true)
  assert_eq(ssa.contains("call $pion_str_index_of("), true)
  assert_eq(ssa.contains("call $pion_str_split("), true)
  assert_eq(ssa.contains("call $pion_str_replace("), true)
  assert_eq(ssa.contains("call $pion_str_to_bytes("), true)
  assert_eq(ssa.contains("call $pion_bytes_new("), true)
  // Bytes set/get/length are inlined in QBE IR (storeb / loadub / @bytes_oob)
  assert_eq(ssa.contains("storeb "), true)
  assert_eq(ssa.contains("loadub "), true)
  assert_eq(ssa.contains("@bytes_oob"), true)
  assert_eq(ssa.contains("call $pion_bytes_slice("), true)
  assert_eq(ssa.contains("call $pion_bytes_concat("), true)
  assert_eq(ssa.contains("call $pion_bytes_to_str("), true)
  assert_eq(ssa.contains("call $pion_math_abs("), true)
  assert_eq(ssa.contains("call $pion_math_floor("), true)
  assert_eq(ssa.contains("call $pion_math_ceil("), true)
  assert_eq(ssa.contains("call $pion_math_sin("), true)
  assert_eq(ssa.contains("call $pion_math_cos("), true)
  assert_eq(ssa.contains("call $pion_math_pow("), true)
  assert_eq(ssa.contains("call $pion_world_fs_write_bytes("), true)
  assert_eq(ssa.contains("call $pion_world_fs_read_bytes("), true)
  assert_eq(ssa.contains("call $pion_world_fs_append("), true)
  assert_eq(ssa.contains("call $pion_world_fs_mtime_ms("), true)
  assert_eq(ssa.contains("call $pion_world_exec_capture("), true)
}

///|
test "p6c_perceus_lite_early_drop_before_subsequent_alloc" {
  let src =
    #|enum Tree {
    #|  Leaf
    #|  Node(Tree, Tree)
    #|}
    #|fn make_tree(d : Int) -> Tree {
    #|  if d <= 0 { Leaf } else { Node(make_tree(d - 1), make_tree(d - 1)) }
    #|}
    #|fn check_tree(t : Tree) -> Int {
    #|  match t {
    #|    Leaf => 1
    #|    Node(l, r) => 1 + check_tree(l) + check_tree(r)
    #|  }
    #|}
    #|pub fn run() -> Int {
    #|  let stretch = make_tree(4)
    #|  let c1 = check_tree(stretch)
    #|  let long_lived = make_tree(3)
    #|  let c2 = check_tree(long_lived)
    #|  c1 + c2
    #|}
  let cr = @core.check_source_files_with_imports("p6c_ed", ["ed.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  let fn_start = match ssa.find("fn_run(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(fn_start >= 0, true)
  let fn_body = ssa.clamped_view(start=fn_start).to_owned()
  // After first check_tree(stretch) and before second make_tree(3), stretch must be
  // early-dropped via pion_rc_dec + slot zeroing (`storel 0,`).
  let first_check = match fn_body.find("fn_check_tree(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(first_check >= 0, true)
  let after_first_check = fn_body.clamped_view(start=first_check).to_owned()
  let second_make = match after_first_check.find("fn_make_tree(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(second_make >= 0, true)
  let between = after_first_check.clamped_view(end=second_make).to_owned()
  assert_eq(between.contains("call $pion_rc_dec("), true)
  assert_eq(between.contains("storel 0, "), true)
}

///|
test "p7a_ergonomics_qbe_codegen_and_bce" {
  let src =
    "fn get_s(ok : Bool) -> Result[String, String] {\n" +
    "  if ok { Ok(\" hello \") } else { Err(\"bad\") }\n" +
    "}\n" +
    "fn try_res(ok : Bool) -> Result[Int, String] {\n" +
    "  let t = get_s(ok)?.trim()\n" +
    "  Ok(t.length())\n" +
    "}\n" +
    "fn try_opt(o : Option[Int]) -> Option[Int] {\n" +
    "  let v = o?\n" +
    "  Some(v * 2)\n" +
    "}\n" +
    "fn sum_arr(a : Array[Int]) -> Int {\n" +
    "  let mut acc = 0\n" +
    "  for x in a {\n" +
    "    acc = acc + x\n" +
    "  }\n" +
    "  acc\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let mut s = 0\n" +
    "  for i in 0..10 {\n" +
    "    if i == 2 { continue }\n" +
    "    s = s + i\n" +
    "  }\n" +
    "  let a : Array[Int] = [3, 1, 2]\n" +
    "  a.sort()\n" +
    "  a.reverse()\n" +
    "  let total = sum_arr(a)\n" +
    "  a.clear()\n" +
    "  let ws : Array[String] = [\"b\", \"a\"]\n" +
    "  ws.sort()\n" +
    "  let j = ws.join(\"-\")\n" +
    "  let d = 2.5\n" +
    "  let msg = \"j=\\{j}, t=\\{total}, d=\\{d}, ds=\\{d.to_string()}\"\n" +
    "  let m : Map[String, Int] = Map::new()\n" +
    "  m.set(\"x\", 1)\n" +
    "  let _h = m.contains(\"x\")\n" +
    "  let _ks = m.keys()\n" +
    "  m.remove(\"x\")\n" +
    "  let _r = try_res(true)\n" +
    "  let _o = try_opt(Some(3))\n" +
    "  s + msg.length()\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p7a_cg", ["cg.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  assert_eq(ssa.contains("@try_ok"), true)
  assert_eq(ssa.contains("@try_err"), true)
  assert_eq(ssa.contains("@try_some"), true)
  assert_eq(ssa.contains("@try_none"), true)
  assert_eq(ssa.contains("call $pion_double_to_str("), true)
  assert_eq(ssa.contains("call $pion_arr_sort_int("), true)
  assert_eq(ssa.contains("call $pion_arr_sort_str("), true)
  assert_eq(ssa.contains("call $pion_arr_reverse("), true)
  assert_eq(ssa.contains("call $pion_arr_clear("), true)
  assert_eq(ssa.contains("call $pion_arr_join("), true)
  assert_eq(ssa.contains("call $pion_map_has("), true)
  assert_eq(ssa.contains("call $pion_map_keys("), true)
  assert_eq(ssa.contains("call $pion_map_remove("), true)
  assert_eq(ssa.contains("@forr_s"), true)
  // Verify sum_arr (`for x in a` without continue) triggers BCE (zero pion_panic_oob in sum_arr)
  let sa_start = match ssa.find("fn_sum_arr(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(sa_start >= 0, true)
  let sa_rest = ssa.clamped_view(start=sa_start).to_owned()
  let sa_end = match sa_rest.find("\n}\n") {
    Some(idx) => idx
    None => sa_rest.length()
  }
  let sa_body = sa_rest.clamped_view(end=sa_end).to_owned()
  assert_eq(sa_body.contains("pion_panic_oob"), false)
}

///|
test "p8: tuple destructuring, match guards, and generic pair_swap codegen" {
  let src =
    "fn pair_swap[A, B](p : (A, B)) -> (B, A) {\n" +
    "  let (a, b) = p\n" +
    "  (b, a)\n" +
    "}\n" +
    "fn pick(opt : Option[String]) -> Int {\n" +
    "  match opt {\n" +
    "    Some(s) if s.length() > 3 => s.length()\n" +
    "    Some(s) => s.length() + 100\n" +
    "    None => 0\n" +
    "  }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let (k, _, v) : (String, String, Int) = (\"alpha\", \"dropme\", 9)\n" +
    "  let sw = pair_swap((k, v))\n" +
    "  let first = sw.0\n" +
    "  let second = sw.1\n" +
    "  first + pick(Some(second))\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p8_cg", ["p8_cg.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  assert_eq(ssa.contains("@match_guard_ok"), true)
  assert_eq(ssa.contains("@match_guard_fail"), true)
  assert_eq(ssa.contains("call $pion_rc_inc("), true)
  assert_eq(ssa.contains("call $pion_rc_dec("), true)
}

///|
test "p10a: const folding, binary dispatch tree, immut field borrow, inline str/bytes/sb/arr, deep freeze" {
  let src =
    "let OP_0 : Int = 0\n" +
    "let OP_1 : Int = 1\n" +
    "let OP_2 : Int = 2\n" +
    "let OP_3 : Int = 3\n" +
    "let OP_4 : Int = 4\n" +
    "let OP_5 : Int = 5\n" +
    "let OP_NEG : Int = -1\n" +
    "pub val struct Msg {\n" +
    "  id : Int\n" +
    "  body : String\n" +
    "}\n" +
    "struct Lexer {\n" +
    "  src : String\n" +
    "  len : Int\n" +
    "  mut pos : Int\n" +
    "}\n" +
    "fn skip_ws(p : Lexer) -> Unit {\n" +
    "  while p.pos < p.len {\n" +
    "    let ch = p.src.code_unit_at(p.pos)\n" +
    "    if ch == 32 || ch == 10 {\n" +
    "      p.pos = p.pos + 1\n" +
    "    } else {\n" +
    "      break\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "fn dispatch_if(op : Int) -> Int {\n" +
    "  if op == OP_0 { 10 }\n" +
    "  else if op == OP_1 { 20 }\n" +
    "  else if op == OP_2 { 30 }\n" +
    "  else if op == OP_3 { 40 }\n" +
    "  else if op == OP_4 { 50 }\n" +
    "  else if op == OP_5 { 60 }\n" +
    "  else if op == OP_NEG { -1 }\n" +
    "  else { 0 }\n" +
    "}\n" +
    "fn dispatch_match(op : Int) -> Int {\n" +
    "  match op {\n" +
    "    0 => 10\n" +
    "    1 => 20\n" +
    "    2 => 30\n" +
    "    3 => 40\n" +
    "    4 => 50\n" +
    "    5 => 60\n" +
    "    _ => 0\n" +
    "  }\n" +
    "}\n" +
    "fn fast_ops(b : Bytes, sb : StringBuilder, a : Array[Int]) -> Int {\n" +
    "  sb.write_char('A')\n" +
    "  a.push(42)\n" +
    "  b[0] = b[0]\n" +
    "  b.length()\n" +
    "}\n" +
    "fn send_msg(ch : Channel[Msg], m : Msg) -> Bool {\n" +
    "  ch.send(m)\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let lx = Lexer::{ src: \"  hi\", len: 4, pos: 0 }\n" +
    "  skip_ws(lx)\n" +
    "  let ch : Channel[Msg] = Channel::new(4)\n" +
    "  let _ = send_msg(ch, Msg::{ id: 1, body: \"hello\" })\n" +
    "  let b = Bytes::new(4)\n" +
    "  let sb = StringBuilder::new()\n" +
    "  let a : Array[Int] = []\n" +
    "  dispatch_if(OP_3) + dispatch_match(2) + fast_ops(b, sb, a)\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p10a_cg", ["p10a.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  // 1. skip_ws: no pion_str_byte_at, no pion_rc_inc/pion_rc_dec inside skip_ws
  let sw_start = match ssa.find("fn_skip_ws(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(sw_start >= 0, true)
  let sw_rest = ssa.clamped_view(start=sw_start).to_owned()
  let sw_end = match sw_rest.find("\n}\n") {
    Some(idx) => idx
    None => sw_rest.length()
  }
  let sw_body = sw_rest.clamped_view(end=sw_end).to_owned()
  assert_eq(sw_body.contains("pion_str_byte_at"), false)
  assert_eq(sw_body.contains("pion_rc_inc"), false)
  assert_eq(sw_body.contains("pion_rc_dec"), false)
  assert_eq(sw_body.contains("loadub"), true)
  // 2. dispatch_if: const folded (no loadsw $pion_const_) and native jtbl jump table
  let di_start = match ssa.find("fn_dispatch_if(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(di_start >= 0, true)
  let di_rest = ssa.clamped_view(start=di_start).to_owned()
  let di_end = match di_rest.find("\n}\n") {
    Some(idx) => idx
    None => di_rest.length()
  }
  let di_body = di_rest.clamped_view(end=di_end).to_owned()
  assert_eq(di_body.contains("$pion_const_"), false)
  assert_eq(di_body.contains("jtbl "), true)
  assert_eq(di_body.contains("@sw_arm"), true)
  // 3. dispatch_match: native jtbl jump table
  let dm_start = match ssa.find("fn_dispatch_match(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(dm_start >= 0, true)
  let dm_rest = ssa.clamped_view(start=dm_start).to_owned()
  let dm_end = match dm_rest.find("\n}\n") {
    Some(idx) => idx
    None => dm_rest.length()
  }
  let dm_body = dm_rest.clamped_view(end=dm_end).to_owned()
  assert_eq(dm_body.contains("jtbl "), true)
  assert_eq(dm_body.contains("@sw_arm"), true)
  // 4. fast_ops: inline bytes length/get/set, sb ASCII fast path, prim array push fast path
  let fo_start = match ssa.find("fn_fast_ops(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(fo_start >= 0, true)
  let fo_rest = ssa.clamped_view(start=fo_start).to_owned()
  let fo_end = match fo_rest.find("\n}\n") {
    Some(idx) => idx
    None => fo_rest.length()
  }
  let fo_body = fo_rest.clamped_view(end=fo_end).to_owned()
  assert_eq(fo_body.contains("pion_bytes_len"), false)
  assert_eq(fo_body.contains("pion_bytes_get"), false)
  assert_eq(fo_body.contains("pion_bytes_set"), false)
  assert_eq(fo_body.contains("@sb_fast"), true)
  assert_eq(fo_body.contains("@ap_fast"), true)
  // 5. deep freeze for Msg (nested String)
  assert_eq(ssa.contains("function $pion_freeze_st_Msg("), true)
  assert_eq(ssa.contains("call $pion_freeze_st_Msg("), true)
}

///|
test "p11b: perceus move, string bce, leaf-loop inline, array hoist budget" {
  let src =
    "struct Entry {\n" +
    "  k : String\n" +
    "  v : String\n" +
    "}\n" +
    "enum Val {\n" +
    "  VArr(Array[Entry])\n" +
    "}\n" +
    "struct Scan {\n" +
    "  src : String\n" +
    "  len : Int\n" +
    "  mut pos : Int\n" +
    "}\n" +
    "fn skip_sp(p : Scan) -> Unit {\n" +
    "  while p.pos < p.len {\n" +
    "    let c = p.src.code_unit_at(p.pos)\n" +
    "    if c == 32 || c == 9 {\n" +
    "      p.pos = p.pos + 1\n" +
    "    } else {\n" +
    "      break\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "fn build_obj(s : String) -> Val {\n" +
    "  let entries : Array[Entry] = []\n" +
    "  let k = s.slice(0, 1)\n" +
    "  let v = s.slice(1, 2)\n" +
    "  entries.push(Entry::{ k: k, v: v })\n" +
    "  return VArr(entries)\n" +
    "}\n" +
    "fn scan_str(s : String) -> Int {\n" +
    "  let n = s.length()\n" +
    "  let mut i = 0\n" +
    "  while i < n && s.code_unit_at(i) != 10 {\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  i\n" +
    "}\n" +
    "fn scan_slice(s : String, start : Int, end : Int) -> Int {\n" +
    "  let mut p = start\n" +
    "  let mut acc = 0\n" +
    "  while p < end && s.code_unit_at(p) != 32 {\n" +
    "    acc = acc + s.code_unit_at(p)\n" +
    "    p = p + 1\n" +
    "  }\n" +
    "  acc\n" +
    "}\n" +
    "fn use_skip(p : Scan) -> Int {\n" +
    "  skip_sp(p)\n" +
    "  p.pos\n" +
    "}\n" +
    "fn helper_call(x : Int) -> Int {\n" +
    "  let mut r = x\n" +
    "  let mut k = 0\n" +
    "  while k < 3 {\n" +
    "    r = r + k\n" +
    "    k = k + 1\n" +
    "  }\n" +
    "  let mut j = 0\n" +
    "  while j < 3 {\n" +
    "    r = r + j\n" +
    "    j = j + 1\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "fn budget_loop(a : Array[Int], b : Array[Int], c : Array[Int], d : Array[Int], e : Array[Int], n : Int) -> Int {\n" +
    "  let mut i = 0\n" +
    "  let mut s = 0\n" +
    "  while i < n {\n" +
    "    s = s + a[i] + a[i] + b[i] + b[i] + c[i] + c[i]\n" +
    "    if i == 0 {\n" +
    "      s = s + d[i] + e[i] + helper_call(i)\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  s\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let _ = build_obj(\"ab\")\n" +
    "  let sc = Scan::{ src: \"  x\", len: 3, pos: 0 }\n" +
    "  let a = [1, 2]\n" +
    "  scan_str(\"abc\\n\") + scan_slice(\"abc \", 0, 4) + use_skip(sc) + budget_loop(a, a, a, a, a, 2)\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p11b_cg", ["p11b.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  // 1. build_obj: owned push fast path + pion_arr_push_owned + zero rc_inc/rc_dec
  let bo_start = match ssa.find("fn_build_obj(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(bo_start >= 0, true)
  let bo_rest = ssa.clamped_view(start=bo_start).to_owned()
  let bo_end = match bo_rest.find("\n}\n") {
    Some(idx) => idx
    None => bo_rest.length()
  }
  let bo_body = bo_rest.clamped_view(end=bo_end).to_owned()
  assert_eq(bo_body.contains("@ap_fast"), true)
  assert_eq(bo_body.contains("pion_arr_push_owned"), true)
  assert_eq(bo_body.contains("pion_rc_inc"), false)
  assert_eq(bo_body.contains("pion_rc_dec"), false)
  // 2. scan_str: direct String BCE under `&&` -> zero pion_panic_oob
  let ss_start = match ssa.find("fn_scan_str(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(ss_start >= 0, true)
  let ss_rest = ssa.clamped_view(start=ss_start).to_owned()
  let ss_end = match ss_rest.find("\n}\n") {
    Some(idx) => idx
    None => ss_rest.length()
  }
  let ss_body = ss_rest.clamped_view(end=ss_end).to_owned()
  assert_eq(ss_body.contains("pion_panic_oob"), false)
  assert_eq(ss_body.contains("loadub"), true)
  // 3. scan_slice: BCE versioning for String under `&&` -> @wh_vchk + @wh_fast
  let sl_start = match ssa.find("fn_scan_slice(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(sl_start >= 0, true)
  let sl_rest = ssa.clamped_view(start=sl_start).to_owned()
  let sl_end = match sl_rest.find("\n}\n") {
    Some(idx) => idx
    None => sl_rest.length()
  }
  let sl_body = sl_rest.clamped_view(end=sl_end).to_owned()
  assert_eq(sl_body.contains("@wh_vchk"), true)
  assert_eq(sl_body.contains("@wh_fast"), true)
  // 4. use_skip: leaf-loop skip_sp inlined (no call $pion_fn_skip_sp)
  let us_start = match ssa.find("fn_use_skip(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(us_start >= 0, true)
  let us_rest = ssa.clamped_view(start=us_start).to_owned()
  let us_end = match us_rest.find("\n}\n") {
    Some(idx) => idx
    None => us_rest.length()
  }
  let us_body = us_rest.clamped_view(end=us_end).to_owned()
  assert_eq(us_body.contains("call $pion_fn_skip_sp"), false)
  assert_eq(us_body.contains("loadub"), true)
  // 5. budget_loop: emits cleanly with 5 arrays + call
  assert_eq(ssa.contains("fn_budget_loop("), true)
}

///|
test "p11c: native jtbl for dense int dispatch, sparse fallback, and dense TEnum match" {
  let src =
    "enum Expr {\n" +
    "  ENum(Int)\n" +
    "  EAdd(Int, Int)\n" +
    "  ESub(Int, Int)\n" +
    "  EMul(Int, Int)\n" +
    "  EDiv(Int, Int)\n" +
    "  ENeg(Int)\n" +
    "}\n" +
    "fn dense_int(x : Int) -> Int {\n" +
    "  match x {\n" +
    "    10 => 1\n" +
    "    11 => 2\n" +
    "    12 => 3\n" +
    "    14 => 5\n" +
    "    15 => 6\n" +
    "    16 => 7\n" +
    "    _ => 0\n" +
    "  }\n" +
    "}\n" +
    "fn sparse_int(x : Int) -> Int {\n" +
    "  match x {\n" +
    "    1 => 1\n" +
    "    100 => 2\n" +
    "    1000 => 3\n" +
    "    10000 => 4\n" +
    "    100000 => 5\n" +
    "    1000000 => 6\n" +
    "    _ => 0\n" +
    "  }\n" +
    "}\n" +
    "fn eval_enum(e : Expr) -> Int {\n" +
    "  match e {\n" +
    "    ENum(v) => v\n" +
    "    EAdd(a, b) => a + b\n" +
    "    ESub(a, b) => a - b\n" +
    "    EMul(a, b) => a * b\n" +
    "    EDiv(a, b) => a / b\n" +
    "    ENeg(v) => 0 - v\n" +
    "  }\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  dense_int(12) + sparse_int(100) + eval_enum(EAdd(3, 4))\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p11c_cg", ["p11c.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  // 1. dense_int: shifted jtbl
  let di_start = match ssa.find("fn_dense_int(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(di_start >= 0, true)
  let di_rest = ssa.clamped_view(start=di_start).to_owned()
  let di_end = match di_rest.find("\n}\n") {
    Some(idx) => idx
    None => di_rest.length()
  }
  let di_body = di_rest.clamped_view(end=di_end).to_owned()
  assert_eq(di_body.contains("jtbl "), true)
  assert_eq(di_body.contains("=w sub "), true)
  // 2. sparse_int: falls back to balanced binary tree (no jtbl)
  let si_start = match ssa.find("fn_sparse_int(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(si_start >= 0, true)
  let si_rest = ssa.clamped_view(start=si_start).to_owned()
  let si_end = match si_rest.find("\n}\n") {
    Some(idx) => idx
    None => si_rest.length()
  }
  let si_body = si_rest.clamped_view(end=si_end).to_owned()
  assert_eq(si_body.contains("jtbl "), false)
  assert_eq(si_body.contains("csltw"), true)
  // 3. eval_enum: dense TEnum match emits jtbl
  let ee_start = match ssa.find("fn_eval_enum(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(ee_start >= 0, true)
  let ee_rest = ssa.clamped_view(start=ee_start).to_owned()
  let ee_end = match ee_rest.find("\n}\n") {
    Some(idx) => idx
    None => ee_rest.length()
  }
  let ee_body = ee_rest.clamped_view(end=ee_end).to_owned()
  assert_eq(ee_body.contains("jtbl "), true)
  assert_eq(ee_body.contains("@em_arm"), true)
}

///|
test "p11c: same-index overwrite OOB dedup and pure EIf rhs array borrow" {
  let src =
    "fn cmp_overwrite(st : Array[Int], sp : Int) -> Unit {\n" +
    "  st[sp - 1] = if st[sp - 1] < st[sp] { 1 } else { 0 }\n" +
    "}\n" +
    "fn add_overwrite(st : Array[Int], sp : Int) -> Unit {\n" +
    "  st[sp - 1] = st[sp - 1] + st[sp]\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let st = [3, 5]\n" +
    "  add_overwrite(st, 1)\n" +
    "  cmp_overwrite(st, 1)\n" +
    "  st[0]\n" +
    "}\n"
  let cr = @core.check_source_files_with_imports("p11c_ow", ["p11c_ow.pion"], [src], [], true)
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_multi(cr.pkg, cr.tc, true, false, []).ssa
  // cmp_overwrite: zero rc_inc/rc_dec (pure EIf borrows st) and only 2 OOB checks (not 3)
  let co_start = match ssa.find("fn_cmp_overwrite(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(co_start >= 0, true)
  let co_rest = ssa.clamped_view(start=co_start).to_owned()
  let co_end = match co_rest.find("\n}\n") {
    Some(idx) => idx
    None => co_rest.length()
  }
  let co_body = co_rest.clamped_view(end=co_end).to_owned()
  assert_eq(co_body.contains("pion_rc_inc"), false)
  assert_eq(co_body.contains("pion_rc_dec"), false)
  // add_overwrite: only 2 OOB checks (st[sp-1] reused once, st[sp] checked once)
  let ao_start = match ssa.find("fn_add_overwrite(") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(ao_start >= 0, true)
  let ao_rest = ssa.clamped_view(start=ao_start).to_owned()
  let ao_end = match ao_rest.find("\n}\n") {
    Some(idx) => idx
    None => ao_rest.length()
  }
  let ao_body = ao_rest.clamped_view(end=ao_end).to_owned()
  let mut oob_cnt = 0
  let mut pos = 0
  while pos < ao_body.length() {
    match ao_body.clamped_view(start=pos).to_owned().find("pion_panic_oob") {
      Some(off) => {
        oob_cnt = oob_cnt + 1
        pos = pos + off + 12
      }
      None => break
    }
  }
  assert_eq(oob_cnt, 2)
}

///|
test "p12a: extern C FFI and trait monomorphization QBE codegen" {
  let src =
    "extern \"C\" fn c_strlen(s : Ptr) -> Int64 = \"strlen\"\n" +
    "extern \"C\" fn c_free(p : Ptr) -> Unit = \"free\"\n" +
    "pub trait Show {\n" +
    "  show(self : Self) -> String\n" +
    "}\n" +
    "pub struct User {\n" +
    "  id : Int\n" +
    "  name : String\n" +
    "}\n" +
    "impl Show for Int {\n" +
    "  fn show(self : Int) -> String { self.to_string() }\n" +
    "}\n" +
    "impl Show for User {\n" +
    "  fn show(self : User) -> String { self.name }\n" +
    "}\n" +
    "fn format_pair[A : Show, B : Show](a : A, b : B) -> String {\n" +
    "  a.show() + \":\" + b.show()\n" +
    "}\n" +
    "pub fn main() -> Int {\n" +
    "  let u = User::{ id: 1, name: \"ada\" }\n" +
    "  let s = format_pair(42, u)\n" +
    "  let n = c_strlen(s.as_cstr())\n" +
    "  let p = ptr_null()\n" +
    "  if ptr_is_null(p) { c_free(p) }\n" +
    "  n.to_int()\n" +
    "}\n"
  let cr = @core.check_source_files_full("p12a_cg", ["p12a_cg.pion"], [src])
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_with_tc(cr.pkg, cr.tc, true).ssa
  // Native C symbol call without $pion_fn_ prefix
  assert_eq(ssa.contains("call $strlen("), true)
  assert_eq(ssa.contains("call $free("), true)
  assert_eq(ssa.contains("$pion_fn_c_strlen"), false)
  // Static impl functions (zero vtable)
  assert_eq(ssa.contains("$pion_impl_Show_Int_show"), true)
  assert_eq(ssa.contains("$pion_impl_Show_User_show"), true)
  // Monomorphized generic function calling concrete $pion_impl_ directly
  assert_eq(ssa.contains("$pion_fn_format_pair__mono_Int_User"), true)
  assert_eq(ssa.contains("call $pion_impl_Show_Int_show("), true)
  assert_eq(ssa.contains("call $pion_impl_Show_User_show("), true)
}

///|
test "p15: == on a payload-less enum compares variant tags, not pointers" {
  let src =
    #|enum Color {
    #|  Red
    #|  Green
    #|}
    #|pub fn same(a : Color, b : Color) -> Bool {
    #|  a == b
    #|}
  let res = @core.emit_qbe_package(
    @core.parse_package("test", ["enum_eq.pion"], [src]),
    true,
  )
  // The only loads in `same` are the tag words of its two operands.
  assert_true(res.ssa.contains("=l loadl %"), res.ssa)
  let src2 =
    #|enum Color {
    #|  Red
    #|  Green
    #|}
    #|pub fn is_red(a : Color) -> Int {
    #|  if a == Red { 1 } else { 0 }
    #|}
  let res2 = @core.emit_qbe_package(
    @core.parse_package("test", ["enum_eq2.pion"], [src2]),
    true,
  )
  assert_true(res2.ssa.contains("=l loadl %"), res2.ssa)
}

///|
test "p17a: generic == is monomorphized per instantiation (String bytes, enum tags)" {
  let src =
    #|enum Color {
    #|  Red
    #|  Green
    #|}
    #|fn same[T](a : T, b : T) -> Bool {
    #|  a == b
    #|}
    #|fn ident[T](a : T) -> T {
    #|  a
    #|}
    #|fn count_same[U](xs : Array[U], x : U) -> Int {
    #|  let mut n = 0
    #|  for y in xs {
    #|    if same(x, y) {
    #|      n = n + 1
    #|    }
    #|  }
    #|  n
    #|}
    #|pub fn main(world : World) -> Int {
    #|  let x = "a" + "b"
    #|  let c = count_same([x], "ab")
    #|  let n = if same(x, "ab") && same(Red, Red) && same(3, 3) { c } else { 0 }
    #|  io_println(world, ident("k"))
    #|  n
    #|}
  let res = @core.emit_qbe_package(
    @core.parse_package("test", ["generic_eq.pion"], [src]),
    false,
  )
  let ssa = res.ssa
  assert_true(ssa.contains("same__mono_String"), ssa)
  assert_true(ssa.contains("same__mono_Color"), ssa)
  assert_true(ssa.contains("same__mono_Int"), ssa)
  // A generic forwarding its type param to a comparing generic is
  // monomorphized too, so the inner call compares concrete `String`s.
  assert_true(ssa.contains("count_same__mono_String"), ssa)
  // String instantiation compares bytes, never pointers.
  assert_true(ssa.contains("call $pion_str_eq("), ssa)
  // Generic fns without `==` keep the single erased body.
  assert_true(!ssa.contains("ident__mono"), ssa)
}

///|
test "p17a: String parse helpers, Option/Result helpers, expression debug_assert lower to QBE" {
  let src =
    #|pub fn main(world : World) -> Int {
    #|  let a = "42".to_int()
    #|  let b = "7".to_int64()
    #|  let c = "2.5".to_double()
    #|  match a {
    #|    Some(x) => debug_assert(x > 0, "pos")
    #|    None => ()
    #|  }
    #|  let r : Result[Int, String] = Ok(1)
    #|  if a.is_some() && b.is_some() && !c.is_none() && r.is_ok() && !r.is_err() {
    #|    io_println(world, "ok")
    #|  }
    #|  a.unwrap_or(0) + r.unwrap_or(0) + c.unwrap_or(0.0).to_int() + b.unwrap_or(0L).to_int()
    #|}
  let ssa = @core.emit_qbe_package(@core.parse_package("test", ["parse.pion"], [src]), false).ssa
  assert_true(ssa.contains("call $pion_str_to_int("), ssa)
  assert_true(ssa.contains("call $pion_str_to_double("), ssa)
  assert_true(ssa.contains("uwo_hit"), ssa)
  assert_true(ssa.contains("pion_debug_assert"), ssa)
}

///|
test "p17a: storing into a possibly-frozen container deep-freezes the element" {
  let src =
    #|pub val struct Msg {
    #|  id : Int
    #|  body : String
    #|}
    #|pub fn main(world : World) -> Int {
    #|  let q : Mutex[Array[Msg]] = Mutex::new([])
    #|  let nums : Array[Int] = []
    #|  scope(world, fn(s : Scope) -> Unit {
    #|    spawn(s, fn() -> Unit {
    #|      let a = q.lock()
    #|      a.push(Msg::{ id: 1, body: "x" })
    #|      q.unlock()
    #|    })
    #|  })
    #|  nums.push(1)
    #|  0
    #|}
  let ssa = @core.emit_qbe_package(@core.parse_package("test", ["adopt.pion"], [src]), false).ssa
  assert_true(ssa.contains("adopt_fz"), ssa)
  assert_true(ssa.contains("$pion_freeze_st_Msg"), ssa)
}

///|
test "p18: event-loop primitives lower to direct C calls with the World first" {
  let src =
    #|pub fn watch(world : World, pfd : Int, fd : Int) -> Bool {
    #|  poll_ctl(world, pfd, 1, fd, 1)
    #|}
    #|pub fn main(world : World) -> Int {
    #|  let lfd = tcp_listen_reuse(world, "127.0.0.1", 0)
    #|  let pfd = poll_create(world)
    #|  if !tcp_set_nonblock(world, lfd, true) || !poll_ctl(world, pfd, 1, lfd, 3) {
    #|    return 1
    #|  }
    #|  let fds : Array[Int] = []
    #|  let evs : Array[Int] = []
    #|  let buf = StringBuilder()
    #|  let n = poll_wait(world, pfd, fds, evs, 256, 10)
    #|  let c = tcp_accept_nb(world, lfd)
    #|  let r = tcp_read_nb(world, c, buf, 16384)
    #|  let w = tcp_write_nb(world, c, buf.to_string(), r)
    #|  poll_close(world, pfd)
    #|  n + w
    #|}
  let cr = @core.check_source_files_full("p18_cg", ["p18_cg.pion"], [src])
  assert_eq(cr.diagnostics.length(), 0)
  let ssa = @core.emit_qbe_package_with_tc(cr.pkg, cr.tc, true).ssa
  assert_true(ssa.contains("=w call $pion_tcp_listen_reuse(l "), ssa)
  assert_true(ssa.contains("=w call $pion_poll_create(l "), ssa)
  assert_true(ssa.contains("=w call $pion_tcp_set_nonblock(l "), ssa)
  assert_true(ssa.contains("=w call $pion_poll_ctl(l "), ssa)
  assert_true(ssa.contains("=w call $pion_poll_wait(l "), ssa)
  assert_true(ssa.contains("=w call $pion_tcp_accept_nb(l "), ssa)
  assert_true(ssa.contains("=w call $pion_tcp_read_nb(l "), ssa)
  assert_true(ssa.contains("=w call $pion_tcp_write_nb(l "), ssa)
  assert_true(ssa.contains("call $pion_poll_close(l "), ssa)
  // A C `int32_t` Bool result is widened into Pion's 64-bit Bool slot before `ret`.
  let fn_at = p18_find_from(ssa, "$pion_fn_watch(", 0)
  assert_true(fn_at >= 0, ssa)
  let fn_end = p18_find_from(ssa, "\n}", fn_at)
  let call_at = p18_find_from(ssa, "=w call $pion_poll_ctl(", fn_at)
  let ext_at = p18_find_from(ssa, " =l extuw ", call_at)
  assert_true(call_at > fn_at && ext_at > call_at && ext_at < fn_end, ssa)
}

///|
test "p19b: 24B header, null-niche Option[Ref], Bool enum singleton, N-way concat, chained borrow, struct String BCE, sb.length" {
  let src =
    #|pub struct Pair {
    #|  key : String
    #|  value : String
    #|}
    #|pub enum Val {
    #|  VNull
    #|  VBool(Bool)
    #|  VStr(String)
    #|}
    #|pub struct Scanner {
    #|  src : String
    #|  len : Int
    #|  mut pos : Int
    #|}
    #|pub fn lookup(entries : Array[Pair], k : String) -> Option[String] {
    #|  let n = entries.length()
    #|  let mut i = 0
    #|  while i < n {
    #|    if entries[i].key == k {
    #|      return Some(entries[i].value)
    #|    }
    #|    i = i + 1
    #|  }
    #|  None
    #|}
    #|pub fn nested_opt(flag : Int) -> Option[Option[String]] {
    #|  if flag == 0 {
    #|    None
    #|  } else if flag == 1 {
    #|    Some(None)
    #|  } else {
    #|    Some(Some("ok"))
    #|  }
    #|}
    #|pub fn scan_quote(p : Scanner) -> Int {
    #|  let mut i = p.pos
    #|  while i < p.len {
    #|    if p.src.code_unit_at(i) == 34 {
    #|      break
    #|    }
    #|    i = i + 1
    #|  }
    #|  i
    #|}
    #|pub fn build_alert(svc : String, lvl : String, msg : String) -> String {
    #|  "ALERT|" + svc + "|" + lvl + "|" + msg
    #|}
    #|pub fn mk_bools(b : Bool) -> Array[Val] {
    #|  let out : Array[Val] = []
    #|  out.push(VBool(true))
    #|  out.push(VBool(false))
    #|  out.push(VBool(b))
    #|  out
    #|}
    #|pub fn sb_len_and_closure() -> Int {
    #|  let sb = StringBuilder()
    #|  sb.write_string("abc")
    #|  let f = fn(x : Int) -> String {
    #|    if x > 0 {
    #|      return "yes"
    #|    }
    #|    "no"
    #|  }
    #|  sb.length() + f(1).length()
    #|}
  let cr = @core.check_source_files_full("p19b_cg", ["p19b_cg.pion"], [src])
  assert_true(
    cr.diagnostics.length() == 0,
    @core.check_result_to_json(cr.diagnostics),
  )
  let ssa = @core.emit_qbe_package_with_tc(cr.pkg, cr.tc, true).ssa
  // 24B header layout
  assert_true(ssa.contains("_hdr, 24"), ssa)
  assert_true(!ssa.contains("_hdr, 32"), ssa)
  // Null-niche Option[String] in lookup: no pion_alloc_uninit, returns 0 on None
  let lk_s = p18_find_from(ssa, "$pion_fn_lookup(", 0)
  let lk_e = p18_find_from(ssa, "\n}", lk_s)
  assert_true(lk_s >= 0 && lk_e > lk_s, ssa)
  let lk_alloc = p18_find_from(ssa, "$pion_alloc_uninit", lk_s)
  assert_true(lk_alloc < 0 || lk_alloc > lk_e, ssa)
  let lk_ret0 = p18_find_from(ssa, "ret 0", lk_s)
  assert_true(lk_ret0 > lk_s && lk_ret0 < lk_e, ssa)
  // Nested Option[Option[String]] uses boxed outer Option
  assert_true(ssa.contains("$pion_drop_opt_obj"), ssa)
  // Bool enum static immortal singletons
  assert_true(ssa.contains("_VBool_1_hdr"), ssa)
  assert_true(ssa.contains("_VBool_0_hdr"), ssa)
  // N-way string concat flattened to pion_str_concat_n
  assert_true(ssa.contains("$pion_str_concat_n("), ssa)
  // Struct String field BCE versioning in scan_quote
  let sq_s = p18_find_from(ssa, "$pion_fn_scan_quote(", 0)
  let sq_e = p18_find_from(ssa, "\n}", sq_s)
  let sq_fast = p18_find_from(ssa, "@wh_fast", sq_s)
  assert_true(sq_fast > sq_s && sq_fast < sq_e, ssa)
  // Local-only array push skips adopt_fz
  let mb_s = p18_find_from(ssa, "$pion_fn_mk_bools(", 0)
  let mb_e = p18_find_from(ssa, "\n}", mb_s)
  let mb_adopt = p18_find_from(ssa, "adopt_fz", mb_s)
  assert_true(mb_adopt < 0 || mb_adopt > mb_e, ssa)
}

///|
/// Index of `needle` in `hay` at or after `from`, or -1.
fn p18_find_from(hay : String, needle : String, from : Int) -> Int {
  let n = needle.length()
  let mut i = if from < 0 { 0 } else { from }
  while i + n <= hay.length() {
    let mut j = 0
    while j < n && @core.str_code_at(hay, i + j) == @core.str_code_at(needle, j) {
      j = j + 1
    }
    if j == n {
      return i
    }
    i = i + 1
  }
  -1
}
