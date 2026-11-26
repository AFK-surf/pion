#!/usr/bin/env python3
r"""Wave F6-3a 4-Target Differential Oracle & Adversarial Soundness Suite:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Positive 4-target parity cases:
  1. Gate A: non-escaping local array `for v in faded { ... }; faded.clear(); faded.shrink_to_fit()`.
  2. Gate B: pure `Array::search_by` penetrating method body `View::same`.
  3. Gate C: pure immediate `.iter().any` / `.all` / `.find_first` penetrating `View::alive -> live`,
     including an uncalled sibling closure containing `clear()` / `remove(0)`.
  4. Gate D: `for x in recv()[lo():hi()]` where `hi()` appends `3` to `[1, 2]` and returns `3`
     (exact trace `recv -> lo -> hi`, yields `2,3`), `[1,2,3][-2:99]` -> `1,2,3`, `[2:1]` -> empty,
     empty array `arr[1:]`, and `for k in visible[1:]` with multiple `break`s.

Negative fail-closed soundness cases (ALL 7 mutation_summary classes + Gate A/B/C/D adversaries):
  1. Class 1: trait dispatch (`dyn Checker` / generic trait bound) inside callback -> fail-closed.
  2. Class 2: operator `impl Add` mutating array inside callback -> fail-closed.
  3. Class 3: re-entrant stored closure in array/struct called inside `.iter().any` -> fail-closed.
  4. Class 3b: public API `KeyWhen::All(ws)` + `has : (String) -> Bool` callback -> fail-closed.
  5. Class 4: unknown external / opaque callback mutating array -> fail-closed.
  6. Class 5: generic `fn[T]` writing `Array[T]` called inside `.search_by` -> fail-closed.
  7. Class 6: field reassignment `self.items = []` inside `.iter().any` -> fail-closed.
  8. Class 7: mutating `Array` method / index write `ws[1] = ...` inside `for k in ws[1:]` -> fail-closed.
  9. Gate A adversary: capacity 8, `[1]`, kept `let it = a.iter()`, `a.shrink_to_fit()`, `a[0] = 9` -> fail-closed.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

POSITIVE_MBT = r'''
pub struct View {
  id : Int
  alive_flag : Bool
}

fn View::same(self : View, other : View) -> Bool {
  self.id == other.id
}

fn live(v : View) -> Bool {
  v.alive_flag && v.id > 0
}

fn View::alive(self : View) -> Bool {
  live(self)
}

fn score(v : Int) -> Int {
  v * 2 + 1
}

// Gate A: non-escaping local array allocated via `Array::make` iterated then cleared and shrunk
// (unlocks `mutation_summary_allow_a` in drift_ledger)
pub fn run_gate_a() -> String {
  let faded : Array[Int] = Array::make(3, 10)
  let mut total = 0
  for v in faded {
    total = total + score(v)
  }
  faded.clear()
  faded.shrink_to_fit()
  total.to_string() + ":" + faded.length().to_string()
}

// Gate B: pure `search_by` penetrating `View::same`
pub fn run_gate_b() -> String {
  let v1 = View::{ id: 1, alive_flag: true }
  let v2 = View::{ id: 2, alive_flag: false }
  let v3 = View::{ id: 3, alive_flag: true }
  let entries : Array[(View, Int)] = [(v1, 100), (v2, 200), (v3, 300)]
  let r1 = match entries.search_by(fn(e) { e.0.same(v2) }) {
    Some(i) => i.to_string()
    None => "none"
  }
  let missing = View::{ id: 99, alive_flag: true }
  let r2 = match entries.search_by(fn(e) { e.0.same(missing) }) {
    Some(i) => i.to_string()
    None => "none"
  }
  r1 + "|" + r2
}

// Gate C: pure immediate `.iter().any` / `.all` / `.find_first` penetrating `View::alive -> live`,
// with an uncalled sibling closure that contains `clear()` and `remove(0)`.
pub fn run_gate_c() -> String {
  let xs : Array[View] = [
    View::{ id: 1, alive_flag: false },
    View::{ id: 2, alive_flag: true },
    View::{ id: 3, alive_flag: true },
  ]
  let sibling_mut = fn() {
    if xs.length() > 0 {
      let _ = xs.remove(0)
    }
    xs.clear()
  }
  let _ = sibling_mut
  let has_any = xs.iter().any(fn(o) { o.alive() })
  let all_alive = xs.iter().all(fn(o) { o.alive() })
  let first_id = match xs.iter().find_first(fn(o) { o.alive() }) {
    Some(v) => v.id
    None => -1
  }
  has_any.to_string() + "|" + all_alive.to_string() + "|" + first_id.to_string() + "|" + xs.length().to_string()
}

// Gate D: borrowed slice loops with exact eval order, clamping, empty array, and multiple breaks
pub fn run_gate_d() -> String {
  let trace : Array[String] = []
  let arr : Array[Int] = [1, 2]
  let get_recv = fn() -> Array[Int] {
    trace.push("recv")
    arr
  }
  let get_lo = fn() -> Int {
    trace.push("lo")
    1
  }
  let get_hi = fn() -> Int {
    trace.push("hi")
    arr.push(3)
    3
  }
  let seen1 : Array[String] = []
  for x in get_recv()[get_lo():get_hi()] {
    seen1.push(x.to_string())
  }

  let base : Array[Int] = [1, 2, 3]
  let seen2 : Array[String] = []
  for x in base[-2:99] {
    seen2.push(x.to_string())
  }
  let seen3 : Array[String] = []
  for x in base[2:1] {
    seen3.push(x.to_string())
  }
  let empty_a : Array[Int] = []
  let seen4 : Array[String] = []
  for x in empty_a[1:] {
    seen4.push(x.to_string())
  }

  let visible : Array[View] = [
    View::{ id: 10, alive_flag: true },
    View::{ id: 20, alive_flag: true },
    View::{ id: 30, alive_flag: false },
    View::{ id: 40, alive_flag: true },
  ]
  let mut stop_id = -1
  let seen5 : Array[String] = []
  for k in visible[1:] {
    if !k.alive() {
      stop_id = k.id
      break
    }
    seen5.push(k.id.to_string())
    if k.id == 99 {
      stop_id = 99
      break
    }
  }

  trace.join(">") + ":" + seen1.join(",") + "|" +
    seen2.join(",") + "|" + seen3.join(",") + "|" + seen4.join(",") + "|" +
    seen5.join(",") + ":" + stop_id.to_string()
}

pub fn run_all() -> String {
  run_gate_a() + " :: " + run_gate_b() + " :: " + run_gate_c() + " :: " + run_gate_d()
}
'''

NEGATIVE_CASES = [
    (
        "neg_class1_trait_dispatch",
        r'''
trait Pred {
  test_it(Self) -> Bool
}
fn run[T : Pred](xs : Array[T]) -> Bool {
  xs.iter().any(fn(x) { x.test_it() })
}
''',
    ),
    (
        "neg_class2_impl_add_mutates",
        r'''
struct BadNum {
  xs : Array[Int]
}
impl Add for BadNum with add(self, other) {
  self.xs.clear()
  other
}
fn run(xs : Array[Int], b : BadNum) -> Option[Int] {
  xs.search_by(fn(_x) {
    let _ = b + b
    false
  })
}
''',
    ),
    (
        "neg_class3_reentrant_stored_closure",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  let killer = fn() { xs.clear() }
  let box_cb : Array[() -> Unit] = [killer]
  xs.iter().any(fn(x) {
    (box_cb[0])()
    x > 0
  })
}
''',
    ),
    (
        "neg_class3b_keywhen_param_cb",
        r'''
pub(all) enum KeyWhen {
  All(Array[String])
}
pub fn matches(kw : KeyWhen, has : (String) -> Bool) -> Bool {
  match kw {
    All(ws) => ws.iter().all(fn(k) { has(k) })
  }
}
''',
    ),
    (
        "neg_class5_generic_array_write",
        r'''
fn[T] push_any(xs : Array[T], v : T) -> Unit {
  xs.push(v)
}
pub fn run(xs : Array[Int]) -> Option[Int] {
  xs.search_by(fn(x) {
    push_any(xs, x)
    false
  })
}
''',
    ),
    (
        "neg_class6_field_reassign",
        r'''
struct Bag {
  mut items : Array[Int]
}
fn Bag::reset(self : Bag) -> Unit {
  self.items = []
}
pub fn run(b : Bag) -> Bool {
  b.items.iter().any(fn(x) {
    b.reset()
    x > 0
  })
}
''',
    ),
    (
        "neg_class7_slice_loop_index_write",
        r'''
pub fn run(ws : Array[Int]) -> Int {
  let mut acc = 0
  for k in ws[1:] {
    ws[0] = k
    acc = acc + k
  }
  acc
}
''',
    ),
    (
        "neg_gate_a_cap8_kept_iter_shrink",
        r'''
pub fn run() -> Int {
  let a : Array[Int] = Array::new(capacity=8)
  a.push(1)
  let it = a.iter()
  a.shrink_to_fit()
  a[0] = 9
  match it.head() {
    Some(v) => v
    None => -1
  }
}
''',
    ),
    (
        "neg_class2_impl_eq_with_equal",
        r'''
struct EvilEq {
  xs : Array[Int]
}
impl Eq for EvilEq with equal(self, other) {
  self.xs.clear()
  let _ = other
  true
}
pub fn run(xs : Array[Int], a : EvilEq, b : EvilEq) -> Option[Int] {
  xs.search_by(fn(_x) {
    a == b
  })
}
''',
    ),
    (
        "neg_class2_unary_neg_newline",
        r'''
struct EvilNeg {
  xs : Array[Int]
}
impl Neg for EvilNeg with neg(self) {
  self.xs.clear()
  self
}
pub fn run(xs : Array[Int], b : EvilNeg) -> Option[Int] {
  xs.search_by(fn(_x) {
    let y = 1
    let _ = y
    let _ =
    -(b)
    false
  })
}
''',
    ),
    (
        "neg_iter_next_lazy_mut",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  let it = xs.iter().map(fn(x) {
    xs.clear()
    x
  })
  xs.iter().any(fn(_x) {
    let _ = it.next()
    true
  })
}
''',
    ),
    (
        "neg_static_hof_fixed_array_makei",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(_x) {
    let _ = FixedArray::makei(1, fn(_) {
      xs.clear()
      0
    })
    true
  })
}
''',
    ),
    (
        "neg_static_hof_option_map",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(_x) {
    let _ = Option::map(Some(1), fn(_) {
      xs.clear()
      0
    })
    true
  })
}
''',
    ),
    (
        "neg_pattern_shadow_pure_fn",
        r'''
fn helper() -> Unit {
  ()
}
pub fn run(xs : Array[Int], opt : Option[() -> Unit]) -> Bool {
  xs.iter().any(fn(_x) {
    match opt {
      Some(helper) => helper()
      None => ()
    }
    true
  })
}
''',
    ),
    (
        "neg_gate_c_fresh_local_reentrant",
        r'''
pub fn run() -> Bool {
  let xs : Array[Int] = [1, 2, 3]
  let k = fn() { xs.clear() }
  let bs : Array[() -> Unit] = [k]
  xs.iter().any(fn(_) {
    (bs[0])()
    true
  })
}
''',
    ),
    (
        "neg_gate_d_labeled_for_slice",
        r'''
pub fn run(xs : Array[Int]) -> Int {
  let mut acc = 0
  outer~: for x in xs[1:] {
    acc = acc + x
    if x > 10 {
      break outer~
    }
  }
  acc
}
''',
    ),
    (
        "neg_gate_a_kept_iter2_shrink",
        r'''
pub fn run() -> Int {
  let a : Array[Int] = Array::make(3, 1)
  let it = a.iter2()
  a.shrink_to_fit()
  a[0] = 9
  let _ = it
  a.length()
}
''',
    ),
]


def run_cmd(cmd, cwd=None, check=True, env=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
    if check and p.returncode != 0:
        raise RuntimeError(
            f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}"
        )
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", required=True)
    args = ap.parse_args()
    pionc = os.path.abspath(args.pionc)

    moon = shutil.which("moon")
    if not moon:
        cand = os.path.expanduser("~/.moon/bin/moon")
        if os.path.isfile(cand):
            moon = cand
    node = shutil.which("node")
    if not moon or not node:
        print(f"FAIL: missing required tools: moon={moon} node={node}", file=sys.stderr)
        sys.exit(2)

    with tempfile.TemporaryDirectory(prefix="f6_3_oracle_") as tmp:
        # 1. Build mbt2pion CLI
        cli_bin = os.path.join(tmp, "mbt2pion_cli")
        run_cmd([pionc, "build", "-o", cli_bin, CLI_DIR], cwd=REPO_ROOT)

        # 2. Run MoonBit native & wasm-gc reference oracle
        mbt_dir = os.path.join(tmp, "mbt_ref")
        os.makedirs(os.path.join(mbt_dir, "src"), exist_ok=True)
        with open(os.path.join(mbt_dir, "moon.mod"), "w") as f:
            f.write('name = "oracle/f63"\n')
        with open(os.path.join(mbt_dir, "src", "moon.pkg"), "w") as f:
            f.write('options("is-main": true)\n')
        with open(os.path.join(mbt_dir, "src", "main.mbt"), "w") as f:
            f.write(POSITIVE_MBT + "\nfn main {\n  println(run_all())\n}\n")

        moon_native_out = run_cmd([moon, "run", "--target", "native", "src"], cwd=mbt_dir).stdout.strip()
        moon_wasm_out = run_cmd([moon, "run", "--target", "wasm-gc", "src"], cwd=mbt_dir).stdout.strip()
        if moon_native_out != moon_wasm_out:
            raise RuntimeError(f"MoonBit native vs wasm-gc mismatch:\n  native: {moon_native_out}\n  wasm-gc: {moon_wasm_out}")
        print(f"[MOONBIT] native == wasm-gc: {moon_native_out}")

        # 3. Transpile positive package with mbt2pion
        src_dir = os.path.join(tmp, "pos_src")
        out_dir = os.path.join(tmp, "pos_out")
        ledger_path = os.path.join(tmp, "pos_ledger.json")
        os.makedirs(src_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(src_dir, "lib.mbt"), "w") as f:
            f.write(POSITIVE_MBT)
        with open(os.path.join(src_dir, "moon.pkg.json"), "w") as f:
            f.write("{}\n")
        run_cmd([
            cli_bin,
            "--src", src_dir,
            "--out", out_dir,
            "--drift-ledger", ledger_path,
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)

        # Verify drift_ledger records allow entries for B, C, D (and A where applicable)
        with open(ledger_path) as f:
            ledger = json.load(f)
        cats = set(e.get("category", "") for e in ledger.get("entries", []))
        print(f"[LEDGER] categories: {sorted(cats)} unresolved={ledger.get('unresolved_entries')}")
        if ledger.get("unresolved_entries", 1) != 0:
            raise RuntimeError(f"Unexpected unresolved ledger entries: {ledger}")
        for req_cat in ("mutation_summary_allow_a", "mutation_summary_allow_b", "mutation_summary_allow_c", "mutation_summary_allow_d"):
            if req_cat not in cats:
                raise RuntimeError(f"Missing expected allow ledger category `{req_cat}` in {sorted(cats)}")

        # 4. Build & run Pion native and wasm32
        with open(os.path.join(out_dir, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "f63_app"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        with open(os.path.join(out_dir, "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n")

        pion_native_bin = os.path.join(tmp, "f63_native")
        run_cmd([pionc, "build", "-o", pion_native_bin, out_dir], cwd=REPO_ROOT)
        pion_native_out = run_cmd([pion_native_bin]).stdout.strip()

        pion_wasm_bin = os.path.join(tmp, "f63_wasm.wasm")
        run_cmd([pionc, "build", "--target", "wasm32", "-o", pion_wasm_bin, out_dir], cwd=REPO_ROOT)
        pion_wasm_out = run_cmd([node, os.path.join(REPO_ROOT, "runtime", "pion_wasm_rt.mjs"), pion_wasm_bin]).stdout.strip()

        if pion_native_out != moon_native_out:
            raise RuntimeError(f"Pion native mismatch!\n  expected: {moon_native_out}\n  got:      {pion_native_out}")
        if pion_wasm_out != moon_native_out:
            raise RuntimeError(f"Pion wasm32 mismatch!\n  expected: {moon_native_out}\n  got:      {pion_wasm_out}")
        print(f"[PION] native == wasm32 == MoonBit: {pion_native_out}")

        # 5. Negative adversarial fail-closed cases: EVERY ONE MUST fail closed (non-zero exit, no --out emitted)
        for name, mbt_code in NEGATIVE_CASES:
            nsrc = os.path.join(tmp, f"{name}_src")
            nout = os.path.join(tmp, f"{name}_out")
            nrep = os.path.join(tmp, f"{name}_rep")
            os.makedirs(nsrc, exist_ok=True)
            with open(os.path.join(nsrc, "bad.mbt"), "w") as f:
                f.write(mbt_code)
            with open(os.path.join(nsrc, "moon.pkg.json"), "w") as f:
                f.write("{}\n")
            p = run_cmd([
                cli_bin,
                "--src", nsrc,
                "--out", nout,
                "--drift-ledger", nrep + ".json",
                "--pionc", pionc,
                "--mbt-compat", COMPAT_DIR,
                "--no-fmt",
                "--mode", "publish",
            ], cwd=REPO_ROOT, check=False)
            if p.returncode == 0 or os.path.exists(nout):
                raise RuntimeError(
                    f"SOUNDNESS FAILURE: negative case `{name}` was NOT fail-closed! rc={p.returncode}, out_exists={os.path.exists(nout)}\n{p.stdout}\n{p.stderr}"
                )
            print(f"[NEG PASS] {name}: fail-closed (rc={p.returncode})")

    print(f"[PASS] Wave F6-3a 4-target oracle + {len(NEGATIVE_CASES)} adversarial fail-closed cases: ALL OK")


if __name__ == "__main__":
    main()
