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
