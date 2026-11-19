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
