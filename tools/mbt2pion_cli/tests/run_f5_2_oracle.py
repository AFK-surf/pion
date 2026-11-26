#!/usr/bin/env python3
r"""4-Target Differential Oracle for map-pattern `if`/`guard ... is` chains and C-ABI FFI bridges:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32,
plus real C-compiled FFI bridge verification on Pion native.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")

MAP_IS_MBT = r'''
pub fn run_map_is_1() -> String {
  let m : Map[String, Int] = { "a": 10, "b": 25 }
  let r1 = if m is { "a": x, "b": y, .. } && x < y {
    x * 100 + y
  } else {
    -1
  }
  let r2 = if m is { "a": x, "missing": z, .. } {
    x + z
  } else {
    -2
  }
  let r3 = if m is { "a": x, "b": y, .. } && x > y {
    x + y
  } else {
    -3
  }
  r1.to_string() + "|" + r2.to_string() + "|" + r3.to_string()
}

pub fn run_map_is_guard() -> String {
  let m1 : Map[String, Int] = { "k": 7, "extra": 3 }
  let m2 : Map[String, Int] = { "k": 7 }
  let f = fn(m : Map[String, Int]) -> Int {
    guard m is { "k": v, "extra"?: ex, .. } else {
      return -9
    }
    match ex {
      Some(e) => v * 10 + e
      None => v * 10
    }
  }
  let m3 : Map[String, Int] = { "other": 1 }
  f(m1).to_string() + "|" + f(m2).to_string() + "|" + f(m3).to_string()
}

pub fn run_map_is_shadow() -> String {
  let x = 999
  let m : Map[String, Int] = { "a": 5 }
  let hit = if m is { "a": x, .. } && x == 5 {
    x
  } else {
    x
  }
  let miss = if m is { "a": x, .. } && x == 6 {
    x
  } else {
    x
  }
  hit.to_string() + "|" + miss.to_string() + "|" + x.to_string()
}

pub struct Bag {
  mut gets : Int
  log : Array[String]
  data : Map[String, Int]
}

pub fn Bag::get(self : Bag, k : String) -> Int? {
  self.gets = self.gets + 1
  self.log.push(k)
  self.data.get(k)
}

pub fn run_map_short_circuit() -> String {
  // 1. if: first key missing -> second key must NEVER be queried
  let b1 : Bag = { gets: 0, log: [], data: { "b": 2 } }
  let r1 = if b1 is { "a": _, "b": _, .. } { 1 } else { 0 }

  // 2. guard: first key missing -> second key must NEVER be queried
  let b2 : Bag = { gets: 0, log: [], data: { "b": 2 } }
  let fg = fn(b : Bag) -> Int {
    guard b is { "a": _, "b": _, .. } else {
      return 0
    }
    1
  }
  let r2 = fg(b2)

  // 3. first key present but value pattern fails -> second key must NEVER be queried
  let b3 : Bag = { gets: 0, log: [], data: { "a": 1, "b": 2 } }
  let r3 = if b3 is { "a": 99, "b": _, .. } { 1 } else { 0 }

  // 4. both keys match -> strict left-to-right order ("a" then "b")
  let b4 : Bag = { gets: 0, log: [], data: { "a": 1, "b": 2 } }
  let r4 = if b4 is { "a": x, "b": y, .. } { x * 10 + y } else { 0 }

  // 5. bare map pattern followed by `&& { block }` condition
  let m5 : Map[String, Int] = { "k": 4 }
  let r5 = if m5 is { "k": v, .. } && { let n = 2; v > n } { v } else { 0 }

  r1.to_string() + ":" + b1.gets.to_string() + "|" +
    r2.to_string() + ":" + b2.gets.to_string() + "|" +
    r3.to_string() + ":" + b3.gets.to_string() + "|" +
    r4.to_string() + ":" + b4.gets.to_string() + ":" + b4.log.join(",") + "|" +
    r5.to_string()
}

pub struct NBag {
  log : Array[String]
  inner : NBag?
  vals : Map[String, Int]
}

pub fn NBag::get(self : NBag, k : String) -> NBag? {
  self.log.push(k)
  if k == "a" {
    self.inner
  } else if k == "b" {
    Some(self)
  } else if self.vals.get(k) is Some(v) && v == 1 {
    Some(self)
  } else {
    None
  }
}

pub fn run_nested_map_dfs() -> String {
  // 1. Nested hit: strict depth-first order must be "a" -> "x" -> "b" ("axb")
  let log1 : Array[String] = []
  let in1 : NBag = { log: log1, inner: None, vals: { "x": 1 } }
  let out1 : NBag = { log: log1, inner: Some(in1), vals: {} }
  let h1 = if out1 is { "a": { "x": _, .. }, "b": _, .. } { 1 } else { 0 }

  // 2. Inner key fails in guard: must stop at "x", NEVER query "b" ("ax")
  let log2 : Array[String] = []
  let in2 : NBag = { log: log2, inner: None, vals: { "x": 2 } }
  let out2 : NBag = { log: log2, inner: Some(in2), vals: {} }
  let f2 = fn(nb : NBag) -> Int {
    guard nb is { "a": { "x": _, .. }, "b": _, .. } else {
      return 0
    }
    1
  }
  let h2 = f2(out2)

  h1.to_string() + ":" + log1.join("") + "|" + h2.to_string() + ":" + log2.join("")
}

pub fn run_all() -> String {
  run_map_is_1() + " :: " + run_map_is_guard() + " :: " + run_map_is_shadow() + " :: " + run_map_short_circuit() + " :: " + run_nested_map_dfs()
}
'''

FFI_E2E_MBT = r'''
pub extern "C" fn scalar_add(a : Int, b : Int) -> Int = "raw_scalar_add"

#borrow(data_dir, cloud)
pub extern "C" fn ffi_start(data_dir : String, cloud : String, beta : Int) -> Int = "demo_start"

#borrow(msg, data)
pub extern "C" fn ffi_send_bytes(msg : String, data : Bytes) -> Int = "demo_send_bytes"

#borrow(data)
pub extern "C" fn ffi_pick(data : Bytes, tag : Int) -> Int = "demo_pick"

pub extern "C" fn ffi_scheme() -> String = "demo_scheme"

pub extern "C" fn ffi_null_str() -> String = "demo_null_str"

pub extern "C" fn ffi_nul_trunc() -> String = "demo_nul_trunc"

#borrow(tag)
pub extern "C" fn ffi_read_buf(tag : String) -> Bytes = "demo_read_buf"

#borrow(a, b)
pub extern "C" fn ffi_mutate_and_alias(a : Bytes, b : Bytes) -> Int = "demo_mutate_and_alias"

pub extern "C" fn greeting() -> String = "greeting"
'''

FFI_SHADOW_MBT = r'''
pub fn[T] cstr_to_str(_x : T) -> String {
  "custom"
}

pub fn unrelated(mbt_compat : Int) -> Int {
  mbt_compat
}
'''

FFI_COLLIDE_MBT = r'''
pub extern "C" fn raw_collide(x : Int) -> Int = "pion_dup_sym"

#borrow(s)
pub extern "C" fn bridged_collide(s : String) -> Int = "dup_sym"
'''

FFI_E2E_C = r'''
#include <stdint.h>
#include <string.h>

static uint8_t g_buf[64];
static int32_t g_buf_len = 0;

int32_t raw_scalar_add(int32_t a, int32_t b) {
  return a + b;
}

int32_t pion_demo_start(const char *dir_ptr, int32_t dir_len, const char *url_ptr, int32_t url_len, int32_t beta) {
  int32_t sum = dir_len * 100 + url_len * 10 + beta;
  if (dir_len > 0 && dir_ptr[0] == '/') sum += 1;
  if (url_len > 0 && url_ptr[0] == 'h') sum += 2;
  return sum;
}

int32_t pion_demo_send_bytes(const char *msg_ptr, int32_t msg_len, const uint8_t *data_ptr, int32_t data_len) {
  (void)msg_ptr;
  int32_t n = data_len < 64 ? data_len : 64;
  for (int32_t i = 0; i < n; i++) {
    g_buf[i] = (uint8_t)(data_ptr[i] ^ (uint8_t)(msg_len & 0xff));
  }
  g_buf_len = n;
  return msg_len * 100 + data_len;
}

int32_t pion_demo_pick(const uint8_t *data_ptr, int32_t data_len, int32_t tag) {
  int32_t first = (data_len > 0 && data_ptr != NULL) ? (int32_t)data_ptr[0] : -1;
  return tag * 1000 + data_len * 10 + (first >= 0 ? first : 0);
}

const char *pion_demo_scheme(void) {
  return "pion-scheme";
}

const char *pion_demo_null_str(void) {
  return NULL;
}

const char *pion_demo_nul_trunc(void) {
  static const char buf[6] = { 'a', 'b', '\0', 'c', 'd', '\0' };
  return buf;
}

const uint8_t *pion_demo_read_buf(const char *tag_ptr, int32_t tag_len, int32_t *out_len) {
  (void)tag_ptr;
  if (tag_len <= 0) {
    *out_len = 0;
    return NULL;
  }
  *out_len = g_buf_len;
  return g_buf;
}

int32_t pion_demo_mutate_and_alias(uint8_t *a_ptr, int32_t a_len, const uint8_t *b_ptr, int32_t b_len) {
  int32_t same_ptr = (a_ptr == b_ptr) ? 1 : 0;
  if (a_len > 0 && a_ptr != NULL) {
    a_ptr[0] = 0xFF;
  }
  return same_ptr * 100 + a_len * 10 + b_len;
}

const char *pion_greeting(void) {
  return "ok";
}
'''

FFI_E2E_MAIN_PION = r'''
pub fn main(w : World) -> Int {
  let sc = scalar_add(19, 23)
  let s = ffi_start("/tmp", "https://ex", 1)
  let u = ffi_start("/你好🚀", "h", 0)
  let e_str = ffi_start("", "", 5)
  let payload = "\x10\x00\x30".to_bytes()
  let send_rc = ffi_send_bytes("abcd", payload)
  let out = ffi_read_buf("ok")
  let empty_b = ffi_read_buf("")
  let empty_send = ffi_send_bytes("", "".to_bytes())
  let null_s = ffi_null_str()
  let nul_trunc = ffi_nul_trunc()
  let picked = ffi_pick("\x05\x06".to_bytes(), 7)
  let picked_empty = ffi_pick("".to_bytes(), 3)
  let orig = "\x2a\x2b".to_bytes()
  let alias_rc = ffi_mutate_and_alias(orig, orig)
  let orig0 = orig[0].to_int()
  let b0 = out[0].to_int()
  let b1 = out[1].to_int()
  let b2 = out[2].to_int()
  let gr = greeting()
  io_println(
    w,
    sc.to_string() + "|" + s.to_string() + "|" + u.to_string() + "|" + e_str.to_string() + "|" +
    send_rc.to_string() + "|" + empty_send.to_string() + "|" + ffi_scheme() + "|" +
    null_s.length().to_string() + "|" + nul_trunc + ":" + nul_trunc.length().to_string() + "|" +
    empty_b.length().to_string() + "|" + picked.to_string() + "|" + picked_empty.to_string() + "|" +
    alias_rc.to_string() + ":" + orig0.to_string() + "|" + gr + "|" +
    out.length().to_string() + ":" + b0.to_string() + "," + b1.to_string() + "," + b2.to_string(),
  )
  0
}
'''

FFI_BRIDGE_C = r'''
#include <stdint.h>
#include <string.h>

static uint8_t g_buf[64];
static int32_t g_buf_len = 0;

int32_t pion_demo_start(const char *dir_ptr, int32_t dir_len, const char *url_ptr, int32_t url_len, int32_t beta) {
  int32_t sum = dir_len * 100 + url_len * 10 + beta;
  if (dir_len > 0 && dir_ptr[0] == '/') sum += 1;
  if (url_len > 0 && url_ptr[0] == 'h') sum += 2;
  return sum;
}

void pion_demo_send_bytes(const char *msg_ptr, int32_t msg_len, const uint8_t *data_ptr, int32_t data_len) {
  int32_t n = data_len < 64 ? data_len : 64;
  for (int32_t i = 0; i < n; i++) {
    g_buf[i] = (uint8_t)(data_ptr[i] ^ (uint8_t)(msg_len & 0xff));
  }
  g_buf_len = n;
}

const char *pion_demo_scheme(void) {
  return "pion-scheme";
}

const char *pion_demo_null_str(void) {
  return NULL;
}

const uint8_t *pion_demo_read_buf(const char *tag_ptr, int32_t tag_len, int32_t *out_len) {
  (void)tag_ptr;
  if (tag_len <= 0) {
    *out_len = 0;
    return NULL;
  }
  *out_len = g_buf_len;
  return g_buf;
}

int32_t pion_demo_pick(const uint8_t *data_ptr, int32_t data_len, int32_t tag) {
  (void)data_ptr;
  (void)data_len;
  return tag;
}
'''

FFI_BRIDGE_PION = r'''
import "mbt_compat" as mbt_compat

extern "C" fn __mbt_c_ffi_ffi_start(data_dir_ptr : Ptr, data_dir_len : Int, cloud_ptr : Ptr, cloud_len : Int, beta : Int) -> Int = "pion_demo_start"
fn ffi_start(data_dir : String, cloud : String, beta : Int) -> Int {
  let __ffi_res = __mbt_c_ffi_ffi_start(data_dir.as_cstr(), data_dir.to_bytes().length(), cloud.as_cstr(), cloud.to_bytes().length(), beta)
  __ffi_res
}

extern "C" fn __mbt_c_ffi_ffi_send_bytes(msg_ptr : Ptr, msg_len : Int, data_ptr : Ptr, data_len : Int) -> Unit = "pion_demo_send_bytes"
fn ffi_send_bytes(msg : String, data : Bytes) -> Unit {
  let __ffi_data_len = data.length()
  let __ffi_data_buf = mbt_compat::mbt_ffi_ptr_alloc(if __ffi_data_len > 0 { __ffi_data_len.to_int64() } else { 1L })
  if __ffi_data_len > 0 { mbt_compat::mbt_ffi_bytes_copy_to_ptr(data, 0, __ffi_data_buf, __ffi_data_len) }
  __mbt_c_ffi_ffi_send_bytes(msg.as_cstr(), msg.to_bytes().length(), __ffi_data_buf, __ffi_data_len)
  mbt_compat::mbt_ffi_ptr_free(__ffi_data_buf)
}

extern "C" fn __mbt_c_ffi_ffi_scheme() -> Ptr = "pion_demo_scheme"
fn ffi_scheme() -> String {
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_scheme()
  let __ffi_ret_str = if mbt_compat::mbt_ffi_ptr_is_null(__ffi_ret_ptr) { "" } else { mbt_compat::mbt_ffi_cstr_to_str(__ffi_ret_ptr) }
  __ffi_ret_str
}

extern "C" fn __mbt_c_ffi_ffi_null_str() -> Ptr = "pion_demo_null_str"
fn ffi_null_str() -> String {
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_null_str()
  let __ffi_ret_str = if mbt_compat::mbt_ffi_ptr_is_null(__ffi_ret_ptr) { "" } else { mbt_compat::mbt_ffi_cstr_to_str(__ffi_ret_ptr) }
  __ffi_ret_str
}

extern "C" fn __mbt_c_ffi_ffi_read_buf(tag_ptr : Ptr, tag_len : Int, __out_len : Ptr) -> Ptr = "pion_demo_read_buf"
fn ffi_read_buf(tag : String) -> Bytes {
  let __ffi_out_len = mbt_compat::mbt_ffi_ptr_alloc(4L)
  mbt_compat::mbt_ffi_ptr_write_i32(__ffi_out_len, 0L, 0)
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_read_buf(tag.as_cstr(), tag.to_bytes().length(), __ffi_out_len)
  let __ffi_ret_len = mbt_compat::mbt_ffi_ptr_read_i32(__ffi_out_len, 0L)
  mbt_compat::mbt_ffi_ptr_free(__ffi_out_len)
  let __ffi_ret_bytes = if mbt_compat::mbt_ffi_ptr_is_null(__ffi_ret_ptr) || __ffi_ret_len <= 0 { "".to_bytes() } else { mbt_compat::mbt_ffi_bytes_from_ptr(__ffi_ret_ptr, __ffi_ret_len) }
  __ffi_ret_bytes
}

extern "C" fn __mbt_c_ffi_pick(data_ptr : Ptr, data_len : Int, __ffi_data_len : Int) -> Int = "pion_demo_pick"
fn pick(data : Bytes, __ffi_data_len : Int) -> Int {
  let __ffi_data_len_1 = data.length()
  let __ffi_data_buf = mbt_compat::mbt_ffi_ptr_alloc(if __ffi_data_len_1 > 0 { __ffi_data_len_1.to_int64() } else { 1L })
  if __ffi_data_len_1 > 0 { mbt_compat::mbt_ffi_bytes_copy_to_ptr(data, 0, __ffi_data_buf, __ffi_data_len_1) }
  let __ffi_res = __mbt_c_ffi_pick(__ffi_data_buf, __ffi_data_len_1, __ffi_data_len)
  mbt_compat::mbt_ffi_ptr_free(__ffi_data_buf)
  __ffi_res
}

pub fn main(w : World) -> Int {
  let s = ffi_start("/tmp", "https://ex", 1)
  let u = ffi_start("/你好🚀", "h", 0)
  let payload = "\x10\x20\x30".to_bytes()
  ffi_send_bytes("abcd", payload)
  let out = ffi_read_buf("ok")
  let empty_b = ffi_read_buf("")
  let null_s = ffi_null_str()
  let picked = pick(payload, 77)
  let b0 = out[0].to_int()
  let b1 = out[1].to_int()
  let b2 = out[2].to_int()
  io_println(w, s.to_string() + "|" + u.to_string() + "|" + ffi_scheme() + "|" + null_s.length().to_string() + "|" + empty_b.length().to_string() + "|" + picked.to_string() + "|" + out.length().to_string() + ":" + b0.to_string() + "," + b1.to_string() + "," + b2.to_string())
  0
}
'''


def run_cmd(cmd, cwd=None, env=None):
    res = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {' '.join(cmd)}\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")
    return res.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", required=True)
    ap.add_argument("--mbt2pion", default="")
    ap.add_argument("--wasm-rt", default=os.path.join(REPO_ROOT, "runtime", "pion_wasm_rt.mjs"))
    ap.add_argument("--moon", default=shutil.which("moon") or "")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="mbt2pion_f5_2_oracle_")
    try:
        mbt2pion_bin = args.mbt2pion
        if not mbt2pion_bin:
            mbt2pion_bin = os.path.join(tmp, "mbt2pion_cli")
            run_cmd([args.pionc, "build", "-o", mbt2pion_bin, os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")])

        # 1. Transpile MAP_IS_MBT via mbt2pion in --mode publish
        mbt_src = os.path.join(tmp, "mbt_pkg")
        os.makedirs(mbt_src)
        with open(os.path.join(mbt_src, "map_is.mbt"), "w") as f:
            f.write(MAP_IS_MBT)
        with open(os.path.join(mbt_src, "moon.pkg.json"), "w") as f:
            f.write("{}\n")

        pion_out = os.path.join(tmp, "pion_pkg")
        os.makedirs(pion_out)
        run_cmd([
            mbt2pion_bin,
            "--src", mbt_src,
            "--out", pion_out,
            "--mode", "publish",
            "--no-fmt",
            "--mbt-compat", COMPAT_DIR,
            "--pionc", args.pionc,
        ])
        with open(os.path.join(pion_out, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "map_is_pkg"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        # Generate split-next Pion expressions via the real production `mbt2pion::lower_string_split_next` helper
        split_gen_pkg = os.path.join(tmp, "split_gen_pkg")
        os.makedirs(split_gen_pkg)
        mbt2pion_dir = os.path.join(REPO_ROOT, "tools", "mbt2pion")
        with open(os.path.join(split_gen_pkg, "pion.toml"), "w") as f:
            f.write(
                f'[package]\nname = "split_gen"\nversion = "0.1.0"\n\n'
                f'[dependencies]\nmbt2pion = {{ path = "{mbt2pion_dir}" }}\n'
            )
        with open(os.path.join(split_gen_pkg, "main.pion"), "w") as f:
            f.write(
                'import "mbt2pion" as m2p\n\n'
                'pub fn main(w : World) -> Int {\n'
                '  io_println(w, m2p::lower_string_split_next("\\"\\"", "\\",\\"", "__sp1"))\n'
                '  io_println(w, m2p::lower_string_split_next("\\"ab,cd\\"", "\\",\\"", "__sp2"))\n'
                '  0\n'
                '}\n'
            )
        split_exprs = run_cmd([args.pionc, "run", split_gen_pkg]).splitlines()
        assert len(split_exprs) == 2, f"expected 2 lowered split expressions, got: {split_exprs!r}"
        empty_split_expr, non_empty_split_expr = split_exprs[0], split_exprs[1]

        with open(os.path.join(pion_out, "main.pion"), "w") as f:
            f.write(
                'fn run_split_next() -> String {\n'
                f'  let e = match ({empty_split_expr}) {{\n'
                '    Some(s) => "Some(" + s.length().to_string() + ":" + s + ")"\n'
                '    None => "None"\n'
                '  }\n'
                f'  let ne = match ({non_empty_split_expr}) {{\n'
                '    Some(s) => "Some(" + s.length().to_string() + ":" + s + ")"\n'
                '    None => "None"\n'
                '  }\n'
                '  e + "|" + ne\n'
                '}\n\n'
                'pub fn main(w : World) -> Int {\n'
                '  io_println(w, run_all() + " :: " + run_split_next())\n'
                '  0\n'
                '}\n'
            )

        # Pion native
        nat_bin = os.path.join(tmp, "map_is_nat")
        run_cmd([args.pionc, "build", "-o", nat_bin, pion_out])
        pion_nat_out = run_cmd([nat_bin])
        expected = "1025|-2|-3 :: 73|70|-9 :: 5|999|999 :: 0:1|0:1|0:1|12:2:a,b|4 :: 1:axb|0:ax :: Some(0:)|Some(2:ab)"
        assert pion_nat_out == expected, f"Pion native mismatch: {pion_nat_out!r} != {expected!r}"
        print(f"[PASS] Pion native map-is: {pion_nat_out}")

        # Pion wasm32
        if shutil.which("node") and os.path.isfile(args.wasm_rt):
            wasm_bin = os.path.join(tmp, "map_is.wasm")
            run_cmd([args.pionc, "build", "--target", "wasm32", "-o", wasm_bin, pion_out])
            pion_wasm_out = run_cmd(["node", args.wasm_rt, wasm_bin])
            assert pion_wasm_out == pion_nat_out, f"Pion wasm32 mismatch: {pion_wasm_out!r} != {pion_nat_out!r}"
            print(f"[PASS] Pion wasm32 map-is: {pion_wasm_out}")

        # MoonBit native + wasm-gc (when moon is available on host)
        if args.moon and os.path.isfile(args.moon):
            mbt_mod = os.path.join(tmp, "mbt_mod")
            os.makedirs(os.path.join(mbt_mod, "src"))
            with open(os.path.join(mbt_mod, "moon.mod"), "w") as f:
                f.write('name = "oracle/map_is"\n')
            with open(os.path.join(mbt_mod, "src", "moon.pkg"), "w") as f:
                f.write('options("is-main": true)\n')
            with open(os.path.join(mbt_mod, "src", "main.mbt"), "w") as f:
                f.write(
                    MAP_IS_MBT
                    + '\nfn run_split_next() -> String {\n'
                    + '  let e = match "".split(",").next() {\n'
                    + '    Some(s) => "Some(" + s.length().to_string() + ":" + s.to_string() + ")"\n'
                    + '    None => "None"\n'
                    + '  }\n'
                    + '  let ne = match "ab,cd".split(",").next() {\n'
                    + '    Some(s) => "Some(" + s.length().to_string() + ":" + s.to_string() + ")"\n'
                    + '    None => "None"\n'
                    + '  }\n'
                    + '  e + "|" + ne\n'
                    + '}\n'
                    + '\nfn main {\n  println(run_all() + " :: " + run_split_next())\n}\n'
                )
            for target in ("native", "wasm-gc"):
                m_out = run_cmd([args.moon, "run", "--target", target, "src"], cwd=mbt_mod)
                assert m_out == pion_nat_out, f"MoonBit {target} mismatch: {m_out!r} != {pion_nat_out!r}"
                print(f"[PASS] MoonBit {target} map-is: {m_out}")

        # 2. Real C-ABI FFI bridge test (compile C + link with Pion native)
        ffi_pkg = os.path.join(tmp, "ffi_pkg")
        os.makedirs(os.path.join(ffi_pkg, "csrc"))
        with open(os.path.join(ffi_pkg, "csrc", "bridge.c"), "w") as f:
            f.write(FFI_BRIDGE_C)
        with open(os.path.join(ffi_pkg, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "ffi_bridge_oracle"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n\n[link.macos]\nc_sources = ["csrc/bridge.c"]\n\n[link.linux]\nc_sources = ["csrc/bridge.c"]\n')
        with open(os.path.join(ffi_pkg, "main.pion"), "w") as f:
            f.write(FFI_BRIDGE_PION)
        ffi_bin = os.path.join(tmp, "ffi_bridge_nat")
        run_cmd([args.pionc, "build", "-o", ffi_bin, ffi_pkg])
        ffi_out = run_cmd([ffi_bin])
        # s: 4*100 + 10*10 + 1 + 1 + 2 = 504
        # u: "/你好🚀" is 1 + 3 + 3 + 4 = 11 UTF-8 bytes -> 11*100 + 1*10 + 0 + 1 + 2 = 1113
        # null_s.length() = 0, empty_b.length() = 0, picked = 77; 0x10^4=20, 0x20^4=36, 0x30^4=52
        expected_ffi = "504|1113|pion-scheme|0|0|77|3:20,36,52"
        assert ffi_out == expected_ffi, f"FFI bridge native mismatch: {ffi_out!r} != {expected_ffi!r}"
        print(f"[PASS] Pion native C-ABI FFI bridge: {ffi_out}")

        # 3. End-to-end CLI `--ffi-shim-prefix` + real C object link & execution
        ffi_src_dir = os.path.join(tmp, "ffi_mbt_pkg")
        os.makedirs(ffi_src_dir)
        with open(os.path.join(ffi_src_dir, "ffi_e2e.mbt"), "w") as f:
            f.write(FFI_E2E_MBT)
        with open(os.path.join(ffi_src_dir, "shadow.mbt"), "w") as f:
            f.write(FFI_SHADOW_MBT)
        with open(os.path.join(ffi_src_dir, "moon.pkg.json"), "w") as f:
            f.write("{}\n")

        # 3a. Default (no --ffi-shim-prefix) in --mode publish MUST fail closed and leave --out empty
        ffi_out_def = os.path.join(tmp, "ffi_out_default")
        os.makedirs(ffi_out_def)
        rep_def_path = os.path.join(tmp, "ffi_report_default.json")
        def_proc = subprocess.run(
            [
                mbt2pion_bin,
                "--src", ffi_src_dir,
                "--out", ffi_out_def,
                "--mode", "publish",
                "--no-fmt",
                "--report", rep_def_path,
                "--mbt-compat", COMPAT_DIR,
                "--pionc", args.pionc,
            ],
            capture_output=True,
            text=True,
        )
        assert def_proc.returncode != 0, "default (no --ffi-shim-prefix) must fail closed in --mode publish"
        assert os.listdir(ffi_out_def) == [], f"default failed publish must leave --out empty, got: {os.listdir(ffi_out_def)}"
        with open(rep_def_path) as f:
            rep_def = json.load(f)
        def_codes = {d["code"] for d in rep_def.get("diagnostics", [])}
        assert "MBT2PION_UNSUPPORTED_FFI_SIGNATURE" in def_codes, f"expected MBT2PION_UNSUPPORTED_FFI_SIGNATURE, got {def_codes}"
        print("[PASS] CLI default fail-closed on bridged extern \"C\" (--out empty)")

        # 3b. Opt-in `--ffi-shim-prefix pion_` in --mode publish MUST succeed with accurate report & ABI
        ffi_out_pfx = os.path.join(tmp, "ffi_out_pion")
        os.makedirs(ffi_out_pfx)
        rep_pfx_path = os.path.join(tmp, "ffi_report_pion.json")
        run_cmd([
            mbt2pion_bin,
            "--src", ffi_src_dir,
            "--out", ffi_out_pfx,
            "--mode", "publish",
            "--no-fmt",
            "--ffi-shim-prefix", "pion_",
            "--report", rep_pfx_path,
            "--mbt-compat", COMPAT_DIR,
            "--pionc", args.pionc,
        ])
        with open(rep_pfx_path) as f:
            rep_pfx = json.load(f)
        assert rep_pfx.get("ffi_shim_prefix") == "pion_", f"report ffi_shim_prefix mismatch: {rep_pfx.get('ffi_shim_prefix')!r}"
        sym_by_fn = {item["fn_name"]: item for item in rep_pfx.get("ffi_symbols", [])}
        assert sym_by_fn["scalar_add"] == {
            "file": "ffi_e2e.mbt",
            "fn_name": "scalar_add",
            "raw_c_symbol": "raw_scalar_add",
            "emitted_c_symbol": "raw_scalar_add",
            "bridged": False,
        }, f"scalar_add mapping mismatch: {sym_by_fn.get('scalar_add')}"
        assert sym_by_fn["ffi_start"]["emitted_c_symbol"] == "pion_demo_start" and sym_by_fn["ffi_start"]["bridged"] is True
        assert sym_by_fn["ffi_mutate_and_alias"]["emitted_c_symbol"] == "pion_demo_mutate_and_alias" and sym_by_fn["ffi_mutate_and_alias"]["bridged"] is True
        with open(os.path.join(ffi_out_pfx, "mbt2pion_abi.json")) as f:
            abi_pion = json.load(f)
        assert abi_pion["payload"].get("ffi_shim_prefix") == "pion_", "mbt2pion_abi.json must record ffi_shim_prefix"

        # Different prefix must produce a different abi_sha256 (cache/ABI separation)
        ffi_out_alt = os.path.join(tmp, "ffi_out_alt")
        os.makedirs(ffi_out_alt)
        run_cmd([
            mbt2pion_bin,
            "--src", ffi_src_dir,
            "--out", ffi_out_alt,
            "--mode", "publish",
            "--no-fmt",
            "--ffi-shim-prefix", "alt_",
            "--mbt-compat", COMPAT_DIR,
            "--pionc", args.pionc,
        ])
        with open(os.path.join(ffi_out_alt, "mbt2pion_abi.json")) as f:
            abi_alt = json.load(f)
        assert abi_alt["abi_sha256"] != abi_pion["abi_sha256"], "distinct --ffi-shim-prefix must yield distinct abi_sha256"
        print("[PASS] CLI --ffi-shim-prefix publish, report symbol table, and ABI separation")

        # 3c. Compile real C shim with `cc -c` to `.o` + link transpiled `.pion` via `pionc build` and run
        csrc_dir = os.path.join(ffi_out_pfx, "csrc")
        os.makedirs(csrc_dir)
        c_file = os.path.join(csrc_dir, "e2e_shim.c")
        o_file = os.path.join(csrc_dir, "e2e_shim.o")
        with open(c_file, "w") as f:
            f.write(FFI_E2E_C)
        cc_bin = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        assert cc_bin, "C compiler (cc/gcc/clang) required for real C-link FFI verification"
        run_cmd([cc_bin, "-O2", "-c", c_file, "-o", o_file])
        with open(os.path.join(ffi_out_pfx, "pion.toml"), "w") as f:
            f.write(
                f'[package]\nname = "ffi_e2e_pkg"\nversion = "0.1.0"\n\n'
                f'[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n\n'
                f'[link.macos]\nflags = ["{o_file}"]\n\n'
                f'[link.linux]\nflags = ["{o_file}"]\n'
            )
        with open(os.path.join(ffi_out_pfx, "main.pion"), "w") as f:
            f.write(FFI_E2E_MAIN_PION)
        e2e_bin = os.path.join(tmp, "ffi_e2e_nat")
        run_cmd([args.pionc, "build", "-o", e2e_bin, ffi_out_pfx])
        e2e_out = run_cmd([e2e_bin])
        # sc=42, s=504, u=1113, e_str=5, send_rc=403, empty_send=0, scheme=pion-scheme, null_s_len=0,
        # nul_trunc="ab":2, empty_b_len=0, picked=7025 (7*1000+2*10+5), picked_empty=3000 (3*1000+0+0),
        # alias_rc=22 (same_ptr=0, a_len=2, b_len=2) & orig0=42 (0x2a unchanged!), gr="ok" (not hijacked by shadow.mbt cstr_to_str),
        # out="3:20,4,52" (0x10^4=20, 0x00^4=4, 0x30^4=52)
        expected_e2e = "42|504|1113|5|403|0|pion-scheme|0|ab:2|0|7025|3000|22:42|ok|3:20,4,52"
        assert e2e_out == expected_e2e, f"CLI E2E C-linked FFI mismatch: {e2e_out!r} != {expected_e2e!r}"
        print(f"[PASS] CLI E2E C-linked FFI execution: {e2e_out}")

        # 3d. Negative CLI tests: invalid --ffi-shim-prefix (including explicit empty "") and same-package C symbol collision
        for bad_pfx in ("", "123_bad", "bad-pfx", " pion_"):
            bad_out = os.path.join(tmp, f"ffi_out_bad_{abs(hash(bad_pfx))}")
            os.makedirs(bad_out)
            bad_proc = subprocess.run(
                [
                    mbt2pion_bin,
                    "--src", ffi_src_dir,
                    "--out", bad_out,
                    "--mode", "publish",
                    "--ffi-shim-prefix", bad_pfx,
                    "--mbt-compat", COMPAT_DIR,
                    "--pionc", args.pionc,
                ],
                capture_output=True,
                text=True,
            )
            assert bad_proc.returncode != 0, f"invalid --ffi-shim-prefix {bad_pfx!r} must fail"
            assert os.listdir(bad_out) == [], f"invalid --ffi-shim-prefix {bad_pfx!r} must leave --out empty"

        col_src = os.path.join(tmp, "ffi_col_pkg")
        os.makedirs(col_src)
        with open(os.path.join(col_src, "collide.mbt"), "w") as f:
            f.write(FFI_COLLIDE_MBT)
        with open(os.path.join(col_src, "moon.pkg.json"), "w") as f:
            f.write("{}\n")
        col_out = os.path.join(tmp, "ffi_col_out")
        os.makedirs(col_out)
        col_rep = os.path.join(tmp, "ffi_col_report.json")
        col_proc = subprocess.run(
            [
                mbt2pion_bin,
                "--src", col_src,
                "--out", col_out,
                "--mode", "publish",
                "--no-fmt",
                "--ffi-shim-prefix", "pion_",
                "--report", col_rep,
                "--mbt-compat", COMPAT_DIR,
                "--pionc", args.pionc,
            ],
            capture_output=True,
            text=True,
        )
        assert col_proc.returncode != 0, "same-package C symbol collision must fail closed"
        assert os.listdir(col_out) == [], f"symbol collision must leave --out empty, got: {os.listdir(col_out)}"
        with open(col_rep) as f:
            col_rep_json = json.load(f)
        col_codes = {d["code"] for d in col_rep_json.get("diagnostics", [])}
        assert "MBT2PION_UNSUPPORTED_FFI_SIGNATURE" in col_codes, f"expected MBT2PION_UNSUPPORTED_FFI_SIGNATURE on collision, got {col_codes}"
        print("[PASS] CLI negative tests: invalid --ffi-shim-prefix & C symbol collision fail-closed")

        print("[SUMMARY] map-is & ffi-bridge oracle: ALL PASS")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
