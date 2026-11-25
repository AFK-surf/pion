#!/usr/bin/env python3
"""Native Zero-Leak RC Lifecycle Regression for lifted recursive local `fn` (Wave M1.2 A.2).

Transpiles a MoonBit source with an escaping recursive local `fn` capturing a `let mut`
variable + String payload via `mbt2pion --mode publish`, compiles the resulting Pion binary
for native execution, and runs 3 separate OS processes at 1,000 / 100,000 / 200,000
create-call-drop iterations. Asserts post-warmup peak RSS remains bounded (zero linear growth).
"""

import os
import re
import resource
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

MBT_SRC = r'''
pub fn make_rec_counter(seed : Int) -> (Int) -> Int {
  let mut acc : Int = seed
  let label : String = "payload_0123456789_abcdef_0123456789_abcdef"
  fn step(n : Int) -> Int {
    if n <= 0 {
      acc + label.length()
    } else {
      acc = acc + n
      step(n - 1)
    }
  }
  fn(k : Int) -> Int { step(k) }
}
'''

DRIVER_PION = r'''
pub fn main(world : World) -> Int {
  let args = world_args(world)
  let n = if args.length() > 1 {
    let s = args[1]
    if s == "1000" { 1000 }
    else if s == "100000" { 100000 }
    else if s == "200000" { 200000 }
    else { 1000 }
  } else {
    1000
  }
  let mut total = 0
  let mut i = 0
  while i < n {
    let f = make_rec_counter(i & 7)
    total = total + f(3)
    i = i + 1
  }
  // OrderedSet 0-RC-cycle & compaction stress (add/remove/clear + abandoned iterator)
  let s : mbt_compat::OrderedSet[Int] = mbt_compat::ordered_set_new()
  let mut j = 0
  while j < n {
    s.add(j)
    if (j & 1023) == 1023 {
      let it = s.iter()
      let _ = it.next()
      // abandon iterator mid-stream and remove prior elements to trigger compaction
      let mut k = j - 1023
      while k <= j {
        s.remove(k)
        k = k + 1
      }
      if s.slot_table_len() > 64 {
        panic("OrderedSet slot_table_len did not compact")
      }
    }
    j = j + 1
  }
  s.clear()
  total = total + s.length()
  io_println(world, "ok n=" + n.to_string() + " total=" + total.to_string())
  0
}
'''


def measure_peak_rss_kb(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    _, status, rusage = os.wait4(p.pid, 0)
    out = p.stdout.read().decode("utf-8", "replace").strip()
    err = p.stderr.read().decode("utf-8", "replace").strip()
    if status != 0:
        raise RuntimeError("child exited with status=%d stderr=%s" % (status, err))
    # macOS reports ru_maxrss in bytes; Linux reports ru_maxrss in KB.
    rss_kb = rusage.ru_maxrss // 1024 if sys.platform == "darwin" else rusage.ru_maxrss
    return rss_kb, out


def main():
    pionc = os.environ.get("PIONC") or shutil.which("pionc")
    if not pionc:
        print("missing PIONC", file=sys.stderr)
        return 2
    workdir = tempfile.mkdtemp(prefix="mbt2pion_rc_leak_")
    try:
        mbt_dir = os.path.join(workdir, "mbt_src")
        out_dir = os.path.join(workdir, "pion_pkg")
        out_src = os.path.join(out_dir, "src")
        os.makedirs(mbt_dir)
        os.makedirs(out_src)
        with open(os.path.join(mbt_dir, "leak.mbt"), "w") as f:
            f.write(MBT_SRC)

        cli_bin = os.path.join(workdir, "mbt2pion")
        subprocess.run([pionc, "build", CLI_DIR, "-o", cli_bin], check=True)
        subprocess.run([
            cli_bin,
            "--src", mbt_dir,
            "--out", out_src,
            "--target", "native",
            "--mode", "publish",
            "--mbt-compat", COMPAT_DIR,
            "--pionc", pionc,
        ], check=True)

        # Verify zero self-capturing `let mut step` in generated code
        gen = open(os.path.join(out_src, "leak.pion")).read()
        if "let mut step" in gen or "__mbt_local_make_rec_counter_step_" not in gen:
            print("FAIL: recursive local fn was not lifted cleanly:\n" + gen, file=sys.stderr)
            return 1

        with open(os.path.join(out_dir, "pion.toml"), "w") as f:
            f.write('[package]\nname = "rc_leak_test"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = { path = "%s" }\n' % COMPAT_DIR)
        with open(os.path.join(out_src, "main.pion"), "w") as f:
            f.write(DRIVER_PION)

        native_bin = os.path.join(workdir, "rc_leak_bin")
        subprocess.run([pionc, "build", out_dir, "-o", native_bin], check=True)

        rss = {}
        for n in (1000, 100000, 200000):
            kb, out = measure_peak_rss_kb([native_bin, str(n)])
            rss[n] = kb
            print("iter=%-7d peak_rss=%6d KB  (%s)" % (n, kb, out))

        # A self-capturing RC cycle leaks >= 64 bytes/iter -> +6.4 MB at 100k, +12.8 MB at 200k.
        # Assert post-warmup growth from 100k -> 200k is <= 2048 KB (flat / bounded).
        growth_100k_200k = rss[200000] - rss[100000]
        growth_1k_200k = rss[200000] - rss[1000]
        print("RSS delta 100k->200k: %+d KB (1k->200k: %+d KB)" % (growth_100k_200k, growth_1k_200k))
        if growth_100k_200k > 2048 or growth_1k_200k > 4096:
            print("FAIL: linear memory growth detected!", file=sys.stderr)
            return 1
        print("ZERO-LEAK RC LIFECYCLE REGRESSION GREEN")
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
