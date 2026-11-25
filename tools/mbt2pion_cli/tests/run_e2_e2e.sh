#!/bin/sh
# Wave M2-E2 E2E positive & negative fail-closed verification gate.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIONC="${1:-${PIONC:-$HOME/.pion/bin/pionc}}"; [ -x "$PIONC" ] || PIONC="$(command -v pionc)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-e2-e2e.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/mbt2pion"; "$PIONC" build "$REPO_ROOT/tools/mbt2pion_cli" -o "$BIN"
COMPAT_DIR="$REPO_ROOT/tools/mbt_compat"; NEG_OUT="$WORK/neg_out"; mkdir -p "$NEG_OUT"; echo "SENTINEL" > "$NEG_OUT/sentinel.pion"

expect_fail() {
  tag="$1"; code="$2"; src="$3"; shift 3
  if "$BIN" --src "$src" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r_${tag}.json" --pionc "$PIONC" "$@" 2>/dev/null; then echo "[e2-e2e] FAIL: $tag"; exit 1; fi
  grep -q "$code" "$WORK/r_${tag}.json" && test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"
}

ORIG_SRC="$WORK/orig_src"; ORIG_PKG="$WORK/orig_pkg"; mkdir -p "$ORIG_SRC" "$ORIG_PKG/src"
printf 'pub struct Box { v : Int }\nfn priv_fn() -> Int { 1 }\npub fn make_box(x : Int) -> Box { Box::{ v: x } }\n' > "$ORIG_SRC/orig.mbt"
printf '[package]\nname = "orig"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = { path = "%s" }\n' "$COMPAT_DIR" > "$ORIG_PKG/pion.toml"
"$BIN" --src "$ORIG_SRC" --out "$ORIG_PKG/src" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC"

# 1. Astra P1-3: unused nonexistent / private / wrong-kind `pub using` -> MBT2PION_DEP_ABI_ERROR
for pair in "missing:pub using @orig { type Ghost }" "priv:pub using @orig { priv_fn }" "wrongkind_t:pub using @orig { type make_box }" "wrongkind_v:pub using @orig { Box }"; do
  name="${pair%%:*}"; body="${pair#*:}"
  d="$WORK/s_$name"; mkdir -p "$d"
  printf '%s\npub fn ok() -> Int { 1 }\n' "$body" > "$d/m.mbt"
  expect_fail "$name" "MBT2PION_DEP_ABI_ERROR" "$d" --dep "orig=$ORIG_PKG"
done

# 2. Valid `mid` publish, missing transitive `--dep orig`, and tampered `reexports`
MID_SRC="$WORK/mid_src"; MID_PKG="$WORK/mid_pkg"; mkdir -p "$MID_SRC" "$MID_PKG/src"
printf 'pub using @orig { type Box, make_box }\npub fn ping() -> Int { 1 }\n' > "$MID_SRC/mid.mbt"
printf '[package]\nname = "mid"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = { path = "%s" }\norig = { path = "%s" }\n' "$COMPAT_DIR" "$ORIG_PKG" > "$MID_PKG/pion.toml"
"$BIN" --src "$MID_SRC" --out "$MID_PKG/src" --target native --mode publish --mbt-compat "$COMPAT_DIR" --dep "orig=$ORIG_PKG" --pionc "$PIONC"
LEAF_SRC="$WORK/leaf_src"; mkdir -p "$LEAF_SRC"
printf 'pub fn use_b() -> @mid.Box { @mid.make_box(7) }\n' > "$LEAF_SRC/l.mbt"
expect_fail "missing_trans_dep" "MBT2PION_DEP_ABI_ERROR" "$LEAF_SRC" --dep "mid=$MID_PKG"
cp -r "$MID_PKG" "$WORK/mid_tamp"
python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("make_box","make_b0x"))' "$WORK/mid_tamp/src/mbt2pion_abi.json"
expect_fail "tampered_reexports" "MBT2PION_DEP_ABI_ERROR" "$LEAF_SRC" --dep "orig=$ORIG_PKG" --dep "mid=$WORK/mid_tamp"

# 3. Category A & B negative cases + old v1/v2 ABI backward compat & publishable:false rejection
python3 - "$BIN" "$PIONC" "$COMPAT_DIR" "$WORK" "$NEG_OUT" << 'PY'
import hashlib, json, os, subprocess, sys
bin_p, pionc, compat, work, neg_out = sys.argv[1:6]
neg_cases = [
    ("astra_p01", "t_wbtest.mbt", 'fn a() -> Unit raise { fail("x") }\nfn via(f : () -> Unit raise) -> Int raise { f(); 1 }\ntest { let _ = try { via(a) } catch { _ => 9 } }\n', ["--with-tests"]),
    ("opus_p13", "t_wbtest.mbt", 'fn helper(x : Int) -> Int raise { assert_eq(x, 1); x }\ntest { let _ = try { helper(2) } catch { _ => -4 } }\n', ["--with-tests"]),
    ("astra_v2_p0_notry", "t_wbtest.mbt", 'fn h(x : Int) -> Unit raise { assert_eq(x, 1) }\ntest { let f = h; f(1) }\n', ["--with-tests"]),
    ("fn_alias", "a.mbt", 'priv suberror Bad\nfn bad() -> Int raise Bad { raise Bad }\npub fn f() -> Int { let g = bad; let _ = g; 10 }\n', []),
    ("meth_alias", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\npub fn f() -> Int { let g = P::bad; let _ = g; 10 }\n', []),
    ("failure_m", "a.mbt", 'fn f() -> Int raise Failure { fail("boom") }\npub fn g() -> Int { try { f() } catch { Failure(m) => m.length() } }\n', []),
    ("noraise", "a.mbt", 'priv suberror E\nfn f() -> Int raise E { raise E }\npub fn g() -> Int { try { f() } catch { E => 0 } noraise { v => v } }\n', []),
    ("pub_raise", "a.mbt", 'priv suberror E\npub fn f() -> Int raise E { raise E }\n', []),
    ("unknown_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\npub fn f() -> Int { let a = [P::{ x: 1 }]; try { let _ = a[0].bad(); 1 } catch { Bad => 0 } }\n', []),
    ("interp_meth_val", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\npub fn f() -> String { "\\{ { let g = P::bad; let _ = g; 3 } }" }\n', []),
    ("cat_a_meth_val", "t_wbtest.mbt", 'struct P { x : Int }\nfn P::check1(self : P) -> Unit raise { assert_eq(self.x, 1) }\ntest { let g = P::check1; g(P::{ x: 1 }) }\n', ["--with-tests"]),
    ("holder_field_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nstruct H { p : P }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\nfn holder() -> H { H::{ p: P::{ x: 1 } } }\npub fn f() -> Int { let p = holder().p; try { let _ = p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("field_chain_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nstruct H { p : P }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\npub fn f() -> Int { let h = H::{ p: P::{ x: 1 } }; try { let _ = h.p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("generic_keep_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\nfn[T] keep(x : T) -> T { x }\npub fn f() -> Int { let p = keep(P::{ x: 0 }); try { let _ = p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("shadow_holder_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nstruct H { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\nfn holder() -> H { H::{ x: 0 } }\npub fn f() -> Int { let holder = fn() -> P { P::{ x: 0 } }; let p = holder(); try { let _ = p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("type_alias_recv", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\ntype Alias = P\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\npub fn f() -> Int { let p : Alias = P::{ x: 0 }; try { let _ = p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("local_named_fn_shadow", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nstruct H { x : Int }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\nfn holder() -> H { H::{ x: 0 } }\npub fn f() -> Int { fn holder() -> P { P::{ x: 0 } }; let p = holder(); try { let _ = p.bad(); 10 } catch { Bad => 9 } }\n', []),
    ("match_pat_shadow", "a.mbt", 'priv suberror Bad\nstruct P { x : Int }\nstruct H { p : P }\nfn P::bad(self : P) -> Int raise Bad { raise Bad }\nfn H::bad(self : H) -> Int { 8 }\nfn holder() -> H { H::{ p: P::{ x: 0 } } }\npub fn f() -> Int { let p : H = holder(); let a = p.bad(); match Some(p.p) { Some(p) => try { let _ = p.bad(); a + 2 } catch { Bad => 9 }; None => 0 } }\n', []),
]
for tag, fn, code, extra in neg_cases:
    sd = os.path.join(work, "n_" + tag); os.makedirs(sd)
    open(os.path.join(sd, fn), "w").write(code)
    rep = os.path.join(work, f"r_{tag}.json")
    r = subprocess.run([bin_p, "--src", sd, "--out", neg_out, "--target", "native", "--mode", "publish",
                        "--mbt-compat", compat, "--report", rep, "--pionc", pionc] + extra, capture_output=True, text=True)
    assert r.returncode != 0 and "MBT2PION_UNSUPPORTED_SYNTAX" in open(rep).read(), f"{tag} failed: rc={r.returncode}"
    assert open(os.path.join(neg_out, "sentinel.pion")).read().strip() == "SENTINEL"

root = os.path.join(work, "abi_compat"); cons = os.path.join(root, "cons"); os.makedirs(cons)
open(os.path.join(cons, "c.mbt"), "w").write("pub fn f() -> Int { @d.g() }\n")
for tag, sv, extra, ok in [("v1", 1, {}, True), ("v2_old", 2, {}, True), ("v2_unpub", 2, {"publishable": False}, False)]:
    dp = os.path.join(root, tag); os.makedirs(os.path.join(dp, "src"))
    open(os.path.join(dp, "pion.toml"), "w").write('[package]\nname = "d"\nversion = "0.1.0"\n')
    pl = {"schema_version": sv, "package": "d", "enums": [], "struct_val_fields": [], **extra}
    asha = hashlib.sha256(json.dumps(pl, separators=(",", ":")).encode()).hexdigest()
    ptxt = f"// GENERATED BY mbt2pion\n// abi-sha256: {asha}\npub fn g() -> Int {{ 1 }}\n"
    open(os.path.join(dp, "src", "g.pion"), "w").write(ptxt)
    fsha = hashlib.sha256(f"g.pion:{len(ptxt)}:{hashlib.sha256(ptxt.encode()).hexdigest()}\n".encode()).hexdigest()
    open(os.path.join(dp, "src", "mbt2pion_abi.json"), "w").write(json.dumps({"schema_version": sv, "package": "d", "abi_sha256": asha, "files_sha256": fsha, "payload": pl}))
    r = subprocess.run([bin_p, "--src", cons, "--out", os.path.join(root, "o_" + tag), "--target", "native", "--mode", "publish",
                        "--dep", f"d={dp}", "--mbt-compat", compat, "--pionc", pionc], capture_output=True, text=True)
    assert (r.returncode == 0) if ok else (r.returncode != 0 and "MBT2PION_DEP_ABI_ERROR" in (r.stdout + r.stderr)), f"{tag} rc={r.returncode}"
PY
echo "[e2-e2e] PASS: all Wave M2-E2 positive & negative fail-closed gates verified"
