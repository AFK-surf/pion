#!/usr/bin/env python3
r"""4-Target Differential Oracle for map-pattern `if`/`guard ... is` chains and C-ABI FFI bridges:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32,
plus real C-compiled FFI bridge verification on Pion native.
"""
import argparse, os, shutil, subprocess, sys, tempfile

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

pub fn run_all() -> String {
  run_map_is_1() + " :: " + run_map_is_guard() + " :: " + run_map_is_shadow()
}
'''

FFI_BRIDGE_C = r'''
#include <stdint.h>
#include <string.h>

static uint8_t g_buf[64];
static int32_t g_buf_len = 0;

int32_t demo_start(const char *dir_ptr, int32_t dir_len, const char *url_ptr, int32_t url_len, int32_t beta) {
  int32_t sum = dir_len * 100 + url_len * 10 + beta;
  if (dir_len > 0 && dir_ptr[0] == '/') sum += 1;
  if (url_len > 0 && url_ptr[0] == 'h') sum += 2;
  return sum;
}

void demo_send_bytes(const char *msg_ptr, int32_t msg_len, const uint8_t *data_ptr, int32_t data_len) {
  int32_t n = data_len < 64 ? data_len : 64;
  for (int32_t i = 0; i < n; i++) {
    g_buf[i] = (uint8_t)(data_ptr[i] ^ (uint8_t)(msg_len & 0xff));
  }
  g_buf_len = n;
}

const char *demo_scheme(void) {
  return "pion-scheme";
}

const char *demo_null_str(void) {
  return NULL;
}

const uint8_t *demo_read_buf(const char *tag_ptr, int32_t tag_len, int32_t *out_len) {
  (void)tag_ptr;
  if (tag_len <= 0) {
    *out_len = 0;
    return NULL;
  }
  *out_len = g_buf_len;
  return g_buf;
}
'''

FFI_BRIDGE_PION = r'''
extern "C" fn __mbt_c_ffi_ffi_start(data_dir_ptr : Ptr, data_dir_len : Int, cloud_ptr : Ptr, cloud_len : Int, beta : Int) -> Int = "demo_start"
fn ffi_start(data_dir : String, cloud : String, beta : Int) -> Int {
  let __ffi_res = __mbt_c_ffi_ffi_start(data_dir.as_cstr(), data_dir.to_bytes().length(), cloud.as_cstr(), cloud.to_bytes().length(), beta)
  __ffi_res
}

extern "C" fn __mbt_c_ffi_ffi_send_bytes(msg_ptr : Ptr, msg_len : Int, data_ptr : Ptr, data_len : Int) -> Unit = "demo_send_bytes"
fn ffi_send_bytes(msg : String, data : Bytes) -> Unit {
  let __ffi_data_len = data.length()
  let __ffi_data_buf = ptr_alloc(if __ffi_data_len > 0 { __ffi_data_len.to_int64() } else { 1L })
  if __ffi_data_len > 0 { bytes_copy_to_ptr(data, 0, __ffi_data_buf, __ffi_data_len) }
  __mbt_c_ffi_ffi_send_bytes(msg.as_cstr(), msg.to_bytes().length(), __ffi_data_buf, __ffi_data_len)
  ptr_free(__ffi_data_buf)
}

extern "C" fn __mbt_c_ffi_ffi_scheme() -> Ptr = "demo_scheme"
fn ffi_scheme() -> String {
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_scheme()
  let __ffi_ret_str = if ptr_is_null(__ffi_ret_ptr) { "" } else { cstr_to_str(__ffi_ret_ptr) }
  __ffi_ret_str
}

extern "C" fn __mbt_c_ffi_ffi_null_str() -> Ptr = "demo_null_str"
fn ffi_null_str() -> String {
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_null_str()
  let __ffi_ret_str = if ptr_is_null(__ffi_ret_ptr) { "" } else { cstr_to_str(__ffi_ret_ptr) }
  __ffi_ret_str
}

extern "C" fn __mbt_c_ffi_ffi_read_buf(tag_ptr : Ptr, tag_len : Int, __out_len : Ptr) -> Ptr = "demo_read_buf"
fn ffi_read_buf(tag : String) -> Bytes {
  let __ffi_out_len = ptr_alloc(4L)
  ptr_write_i32(__ffi_out_len, 0L, 0)
  let __ffi_ret_ptr = __mbt_c_ffi_ffi_read_buf(tag.as_cstr(), tag.to_bytes().length(), __ffi_out_len)
  let __ffi_ret_len = ptr_read_i32(__ffi_out_len, 0L)
  ptr_free(__ffi_out_len)
  let __ffi_ret_bytes = if ptr_is_null(__ffi_ret_ptr) || __ffi_ret_len <= 0 { "".to_bytes() } else { bytes_from_ptr(__ffi_ret_ptr, __ffi_ret_len) }
  __ffi_ret_bytes
}

pub fn main(w : World) -> Int {
  let s = ffi_start("/tmp", "https://ex", 1)
  let u = ffi_start("/你好🚀", "h", 0)
  let payload = "\x10\x20\x30".to_bytes()
  ffi_send_bytes("abcd", payload)
  let out = ffi_read_buf("ok")
  let empty_b = ffi_read_buf("")
  let null_s = ffi_null_str()
  let b0 = out[0].to_int()
  let b1 = out[1].to_int()
  let b2 = out[2].to_int()
  io_println(w, s.to_string() + "|" + u.to_string() + "|" + ffi_scheme() + "|" + null_s.length().to_string() + "|" + empty_b.length().to_string() + "|" + out.length().to_string() + ":" + b0.to_string() + "," + b1.to_string() + "," + b2.to_string())
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
    ap.add_argument("--mbt2pion", required=True)
    ap.add_argument("--wasm-rt", default=os.path.join(REPO_ROOT, "runtime", "pion_wasm_rt.mjs"))
    ap.add_argument("--moon", default=shutil.which("moon") or "")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="mbt2pion_f5_2_oracle_")
    try:
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
            args.mbt2pion,
            "--src", mbt_src,
            "--out", pion_out,
            "--mode", "publish",
            "--no-fmt",
            "--mbt-compat", COMPAT_DIR,
            "--pionc", args.pionc,
        ])
        with open(os.path.join(pion_out, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "map_is_pkg"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        with open(os.path.join(pion_out, "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n")

        # Pion native
        nat_bin = os.path.join(tmp, "map_is_nat")
        run_cmd([args.pionc, "build", "-o", nat_bin, pion_out])
        pion_nat_out = run_cmd([nat_bin])
        expected = "1025|-2|-3 :: 73|70|-9 :: 5|999|999"
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
                f.write(MAP_IS_MBT + "\nfn main {\n  println(run_all())\n}\n")
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
            f.write('[package]\nname = "ffi_bridge_oracle"\nversion = "0.1.0"\n\n[link.macos]\nc_sources = ["csrc/bridge.c"]\n\n[link.linux]\nc_sources = ["csrc/bridge.c"]\n')
        with open(os.path.join(ffi_pkg, "main.pion"), "w") as f:
            f.write(FFI_BRIDGE_PION)
        ffi_bin = os.path.join(tmp, "ffi_bridge_nat")
        run_cmd([args.pionc, "build", "-o", ffi_bin, ffi_pkg])
        ffi_out = run_cmd([ffi_bin])
        # s: 4*100 + 10*10 + 1 + 1 + 2 = 504
        # u: "/你好🚀" is 1 + 3 + 3 + 4 = 11 UTF-8 bytes -> 11*100 + 1*10 + 0 + 1 + 2 = 1113
        # null_s.length() = 0, empty_b.length() = 0; 0x10^4=20, 0x20^4=36, 0x30^4=52
        expected_ffi = "504|1113|pion-scheme|0|0|3:20,36,52"
        assert ffi_out == expected_ffi, f"FFI bridge native mismatch: {ffi_out!r} != {expected_ffi!r}"
        print(f"[PASS] Pion native C-ABI FFI bridge: {ffi_out}")

        print("[SUMMARY] map-is & ffi-bridge oracle: ALL PASS")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
