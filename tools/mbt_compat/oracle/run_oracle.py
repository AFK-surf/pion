#!/usr/bin/env python3
"""Differential oracle for tools/mbt_compat (test harness only).

Runs every semantic probe case on three engines and compares them:

  moon        `moon run --target wasm-gc`  (MoonBit reference, ../moon_probe)
  pion-native `pionc run`                  (pion_probe on the host target)
  pion-wasm32 `pionc run --target wasm32`  (pion_probe on Node.js)

For each case the three runs must agree on
  (a) the outcome class: `ok`, or a language-level panic of a given kind
      (div_zero, rem_zero, div_overflow, oob, abort); any other exit code,
      a crash (SIGSEGV 139 / signal), a raw Wasm trap on the Pion side, a
      timeout, or a case that prints nothing is a HARD FAIL;
  (b) the trace (`T key=value` lines, verbatim and in order);
  (c) the executed assertion ids (`A id` lines, in order),
and all of it must match the frozen expectation in CASES (outcome and
assertion count), so dropping an assertion on both sides is caught too.

A negative self-test then mutates copies of the Pion probe (drop an
assertion, swallow a panic, bypass a compat helper) and the harness itself
must report each mutant red. `bench` prints hot-path timings (informative,
not compared).

Usage: python3 tools/mbt_compat/oracle/run_oracle.py [--pionc PATH]
       [--moon PATH] [--no-self-test] [--no-bench] [--jobs N]
       [--report out.json] [--case NAME ...]
The pionc under test is --pionc, else $PIONC, else `pionc` on PATH (moon:
--moon, else $MOON, else PATH); an explicit path that is not an executable,
or a missing pionc / moon / node, is a hard failure (exit 2), never a
fallback to another installation. Exit status 0 only when everything is
green.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PKG_DIR = os.path.dirname(HERE)
MOON_PROBE = os.path.join(HERE, "moon_probe")
PION_PROBE = os.path.join(HERE, "pion_probe")
TIMEOUT_S = 180

DIV_TYPES = ["i32", "i64", "u32", "u64", "byte"]

# Frozen expectations: case -> (outcome, number of assertion ids).
CASES = {
    "utf16.basic": ("ok", 9),
    "utf16.long": ("ok", 1),
    "utf16.slices": ("ok", 5),
    "utf16.boundary": ("ok", 3),
    "utf16.exact_mid_pair": ("panic:abort", 0),
    "utf16.exact_oob": ("panic:abort", 0),
    "utf16.code_unit_oob": ("panic:oob", 0),
    "arrayview.grow": ("ok", 3),
    "arrayview.ops": ("ok", 4),
    "arrayview.exact_oob": ("panic:abort", 0),
    "arrayview.get_oob": ("panic:abort", 0),
    "map.order": ("ok", 3),
    "map.enum_keys": ("ok", 2),
    "double.golden": ("ok", 4),
    "double.compare_nan": ("ok", 6),
    "double.random": ("ok", 1),
    "div.nonzero": ("ok", 2),
    "collections": ("ok", 3),
    "opt.unwrap_none": ("panic:abort", 0),
    "arr.remove_oob": ("panic:abort", 0),
    "compat.basics": ("ok", 8),
    "compat.round2": ("ok", 5),
    "compat.parse_numbers": ("ok", 12),
}
for _t in DIV_TYPES:
    for _src in ("rt", "const"):
        CASES["div.%s.div.%s" % (_t, _src)] = ("panic:div_zero", 0)
        CASES["div.%s.mod.%s" % (_t, _src)] = ("panic:rem_zero", 0)
for _t in ("i32", "i64"):
    for _src in ("rt", "const"):
        CASES["div.%s.ovf.%s" % (_t, _src)] = ("panic:div_overflow", 0)

# MoonBit wasm-gc trap message -> panic kind.
MOON_TRAPS = {
    "divide by zero": "div_zero",
    "remainder by zero": "rem_zero",
    "divide result unrepresentable": "div_overflow",
    "integer overflow": "div_overflow",
    "unreachable": "abort",
    "array element access out of bounds": "oob",
}

# Pion panic message prefix -> panic kind (messages chosen in mbt_compat).
PION_PANICS = [
    ("divide by zero", "div_zero"),
    ("remainder by zero", "rem_zero"),
    ("divide result unrepresentable", "div_overflow"),
    ("index out of bounds", "oob"),
    ("abort:", "abort"),
    ("assertion failed", "abort"),
]

ENGINES = ["moon", "pion-native", "pion-wasm32"]


def resolve_tool(name, flag, env_var):
    """Tool path from --flag, else $ENV_VAR, else PATH; never a silent fallback.

    An explicit flag or variable that does not name an executable file is an
    error (None), not a reason to try the next source."""
    for value, src in ((flag, "--" + name), (os.environ.get(env_var, ""), "$" + env_var)):
        if value:
            path = os.path.abspath(os.path.expanduser(value))
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path, src
            return None, "%s=%s is not an executable file" % (src, value)
    path = shutil.which(name)
    return (path, "PATH") if path else (None, "not on PATH")


def run(cmd, cwd=None, env=None):
    """Runs a command; returns (rc, stdout, stderr, timed_out, seconds)."""
    t0 = time.time()
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_S,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
            False,
            time.time() - t0,
        )
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        err = (e.stderr or b"").decode("utf-8", "replace")
        return (None, out, err, True, time.time() - t0)


def classify(engine, rc, out, err, timed_out):
    """Outcome class of one run: ("ok"|"panic:<kind>"|"HARD:<why>")."""
    if timed_out:
        return "HARD:timeout"
    if rc == 0:
        return "ok"
    if engine == "moon":
        m = re.search(r"RuntimeError: ([^\n]+)", err + "\n" + out)
        if rc == 1 and m:
            msg = m.group(1).strip()
            kind = MOON_TRAPS.get(msg)
            if kind is None:
                return "HARD:unknown-moon-trap(%s)" % msg
            return "panic:" + kind
        return "HARD:moon-exit-%s" % rc
    m = re.search(r"pion panic at [^\n]*?:\d+: ([^\n]*)", err)
    native_panic_rc = rc in (134, -6)
    wasm_panic_rc = rc == 1
    if m and ((engine == "pion-native" and native_panic_rc) or
              (engine == "pion-wasm32" and wasm_panic_rc)):
        msg = m.group(1)
        for prefix, kind in PION_PANICS:
            if msg.startswith(prefix):
                return "panic:" + kind
        return "HARD:unclassified-pion-panic(%s)" % msg
    if engine == "pion-wasm32" and "RuntimeError:" in err:
        # A raw Wasm trap in Pion code: the target-dependent behaviour the
        # compat layer exists to remove (native would not trap the same way).
        t = re.search(r"RuntimeError: ([^\n]+)", err).group(1).strip()
        return "HARD:raw-wasm-trap(%s)" % t
    if rc in (139, -11):
        return "HARD:SIGSEGV"
    if rc in (136, -8):
        return "HARD:SIGFPE"
    if rc is not None and rc < 0:
        return "HARD:signal-%d" % (-rc)
    return "HARD:exit-%s" % rc


def parse_lines(out):
    traces, asserts, junk = [], [], []
    for line in out.splitlines():
        if line.startswith("T "):
            traces.append(line[2:])
        elif line.startswith("A "):
            asserts.append(line[2:])
        elif line.strip():
            junk.append(line)
    return traces, asserts, junk


def evaluate(case, results):
    """results: engine -> (rc, out, err, timed_out). Returns list of errors."""
    errors = []
    expect, n_asserts = CASES[case]
    parsed = {}
    for eng in ENGINES:
        rc, out, err, to = results[eng]
        cls = classify(eng, rc, out, err, to)
        traces, asserts, junk = parse_lines(out)
        parsed[eng] = (cls, traces, asserts)
        if cls.startswith("HARD:"):
            errors.append(("hard_fail:" + cls[5:], "%s: hard fail %s (rc=%s) stderr=%s" %
                           (eng, cls[5:], rc, err.strip()[-300:])))
        if not traces and not asserts:
            errors.append(("empty_run", "%s: executed nothing (0 traces, 0 assertions)" % eng))
        if junk:
            errors.append(("unexpected_output", "%s: unexpected output %r" % (eng, junk[:3])))
    classes = {eng: parsed[eng][0] for eng in ENGINES}
    for eng in ENGINES:
        if classes[eng] != expect:
            if not classes[eng].startswith("HARD:"):
                errors.append(("outcome_mismatch",
                               "%s: outcome %s, expected %s" % (eng, classes[eng], expect)))
    ref_t, ref_a = parsed["moon"][1], parsed["moon"][2]
    for eng in ENGINES[1:]:
        t, a = parsed[eng][1], parsed[eng][2]
        if t != ref_t:
            diff = next((i for i in range(min(len(t), len(ref_t))) if t[i] != ref_t[i]),
                        min(len(t), len(ref_t)))
            errors.append(("trace_mismatch", "%s: trace differs from moon at line %d: moon=%r %s=%r" % (
                eng, diff,
                ref_t[diff] if diff < len(ref_t) else "<end>", eng,
                t[diff] if diff < len(t) else "<end>")))
        if a != ref_a:
            errors.append(("assertion_id_mismatch",
                           "%s: assertion ids differ: moon=%s %s=%s" % (eng, ref_a, eng, a)))
    for eng in ENGINES:
        if len(parsed[eng][2]) != n_asserts:
            errors.append(("assertion_count_mismatch", "%s: %d assertions executed, expected %d" %
                           (eng, len(parsed[eng][2]), n_asserts)))
    return errors, parsed


class Env:
    def __init__(self, moon, pionc, workdir):
        self.moon = moon
        self.pionc = pionc
        self.workdir = workdir
        self.moon_dir = os.path.join(workdir, "moon_probe")


def prepare(env):
    shutil.copytree(MOON_PROBE, env.moon_dir)
    steps = [
        ([env.moon, "build", "--target", "wasm-gc"], env.moon_dir, "moon build --target wasm-gc"),
        ([env.pionc, "check", "--json", PION_PROBE], None, "pionc check pion_probe"),
        ([env.pionc, "build", PION_PROBE, "-o", os.path.join(env.workdir, "probe_native")], None,
         "pionc build pion_probe"),
        ([env.pionc, "build", "--target", "wasm32", PION_PROBE, "-o",
          os.path.join(env.workdir, "probe.wasm")], None, "pionc build --target wasm32 pion_probe"),
    ]
    for cmd, cwd, label in steps:
        rc, out, err, to, secs = run(cmd, cwd=cwd)
        if rc != 0:
            print("SETUP FAILED: %s (rc=%s)\n%s\n%s" % (label, rc, out[-2000:], err[-2000:]))
            return False
        print("setup ok   %-42s %.1fs" % (label, secs))
    return True


def run_moon(env, case):
    rc, out, err, to, _ = run([env.moon, "run", "--target", "wasm-gc", "main", "--", case],
                              cwd=env.moon_dir)
    return (rc, out, err, to)


def run_pion(env, probe_dir, target, case):
    cmd = [env.pionc, "run"]
    if target == "wasm32":
        cmd += ["--target", "wasm32"]
    cmd += [probe_dir, "--", case]
    rc, out, err, to, _ = run(cmd)
    return (rc, out, err, to)


def run_suite(env, cases, jobs):
    results = {c: {} for c in cases}
    # Warm the CAS serially first: concurrent cold `pionc run` invocations of
    # one package race on linking the same cached binary (ld errno 17).
    for target in ("native", "wasm32"):
        run_pion(env, PION_PROBE, target, cases[0])
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {}
        for c in cases:
            futs[ex.submit(run_pion, env, PION_PROBE, "native", c)] = (c, "pion-native")
            futs[ex.submit(run_pion, env, PION_PROBE, "wasm32", c)] = (c, "pion-wasm32")
        # moon shares one build directory: run it serially alongside the pool.
        for c in cases:
            results[c]["moon"] = run_moon(env, c)
        for f in concurrent.futures.as_completed(futs):
            c, eng = futs[f]
            results[c][eng] = f.result()
    return results


# --------------------------------------------------------------------------
# Negative self-test: every mutant must turn the oracle red.

# (name, case, anchor, replacement, required, allowed): the mutant is detected
# only when (1) some error has a category in `required` and (2) every error
# has a category in `allowed`. Anything else, for instance an infrastructure
# failure (a compile error, a missing Node.js runner `MODULE_NOT_FOUND`,
# `exit-1`), fails the self-test instead of counting as a detection.
MUTANTS = [
    ("drop-assertion", "map.order",
     'check(w, "map.insertion_order", ks == "zeta alpha mid beta k9")\n', "",
     {"assertion_id_mismatch"},
     {"assertion_id_mismatch", "assertion_count_mismatch"}),
    ("swallow-panic-div", "div.i32.div.rt",
     "mc::div_checked_i32(ZERO_I32[3], ZERO_I32[0])", "(ZERO_I32[3] / ZERO_I32[0])",
     # ARM64 native returns 0 (outcome ok), x86_64 native raises SIGFPE,
     # wasm32 traps outside a Pion panic.
     {"outcome_mismatch", "hard_fail:SIGFPE", "hard_fail:raw-wasm-trap(divide by zero)"},
     {"outcome_mismatch", "trace_mismatch", "hard_fail:SIGFPE",
      "hard_fail:raw-wasm-trap(divide by zero)"}),
    ("swallow-panic-unwrap", "opt.unwrap_none",
     "mc::opt_unwrap(n).to_string()", "mc::opt_or(n, 0).to_string()",
     {"outcome_mismatch"},
     {"outcome_mismatch", "trace_mismatch"}),
    ("raw-double-format", "double.golden",
     'trace(w, "d\\{i}", mc::double_to_string(d))', 'trace(w, "d\\{i}", "\\{d}")',
     {"trace_mismatch"},
     {"trace_mismatch"}),
    ("raw-utf8-length", "utf16.basic",
     'trace(w, "len", mc::utf16_len(s).to_string())', 'trace(w, "len", s.length().to_string())',
     {"trace_mismatch"},
     {"trace_mismatch"}),
    ("reinsert-keeps-position", "map.order",
     'm.remove("alpha")\n  m.set("alpha", 6)', 'm.set("alpha", 6)',
     {"outcome_mismatch"},
     {"outcome_mismatch", "trace_mismatch", "unexpected_output", "assertion_id_mismatch",
      "assertion_count_mismatch"}),
]


def mutant_detected(errs, required, allowed):
    """(detected, reason) for the errors the oracle reported on a mutant."""
    cats = [c for c, _ in errs]
    stray = [m for c, m in errs if c not in allowed]
    if stray:
        return False, "unexpected failure category: " + stray[0][:160]
    if not any(c in required for c in cats):
        return False, "stayed green" if not cats else "no expected category in %s" % sorted(set(cats))
    return True, "%s: %s" % (",".join(sorted(set(cats))), errs[0][1][:90])


def make_mutant(env, name, old, new):
    d = os.path.join(env.workdir, "mutant_" + name)
    shutil.copytree(PION_PROBE, d)
    toml = os.path.join(d, "pion.toml")
    with open(toml) as f:
        t = f.read()
    t = t.replace('path = "../.."', 'path = "%s"' % PKG_DIR)
    with open(toml, "w") as f:
        f.write(t)
    src = os.path.join(d, "src", "main.pion")
    with open(src) as f:
        s = f.read()
    if s.count(old) != 1:
        raise RuntimeError("mutant %s: anchor found %d times" % (name, s.count(old)))
    with open(src, "w") as f:
        f.write(s.replace(old, new))
    return d


def classifier_selftest():
    """The classifier must hard-fail crashes, timeouts and empty runs."""
    problems = []
    probes = [
        ("pion-native", 139, "", "", False, "HARD:SIGSEGV"),
        ("pion-native", -11, "", "", False, "HARD:SIGSEGV"),
        ("pion-native", None, "", "", True, "HARD:timeout"),
        ("pion-native", 2, "", "error: build failed", False, "HARD:exit-2"),
        ("moon", 1, "", "Error: something else", False, "HARD:moon-exit-1"),
        ("pion-wasm32", 1, "", "RuntimeError: divide by zero\n", False,
         "HARD:raw-wasm-trap(divide by zero)"),
        ("pion-native", 134, "", "pion panic at ./x.pion:3: divide by zero\n", False,
         "panic:div_zero"),
        ("moon", 1, "", "RuntimeError: remainder by zero\n", False, "panic:rem_zero"),
    ]
    for eng, rc, out, err, to, want in probes:
        got = classify(eng, rc, out, err, to)
        if got != want:
            problems.append("classify(%s, rc=%s) = %s, want %s" % (eng, rc, got, want))
    probes2 = [
        ("pion-native", 136, "", "", False, "HARD:SIGFPE"),
    ]
    for eng, rc, out, err, to, want in probes2:
        got = classify(eng, rc, out, err, to)
        if got != want:
            problems.append("classify(%s, rc=%s) = %s, want %s" % (eng, rc, got, want))
    empty = {e: (0, "", "", False) for e in ENGINES}
    errs, _ = evaluate("utf16.basic", empty)
    if not any(c == "empty_run" for c, _ in errs):
        problems.append("a run with 0 assertions was not reported")
    # An infrastructure failure must never count as a mutant detection.
    infra = ("swallow-panic-div", [
        ("hard_fail:exit-1", "pion-wasm32: hard fail exit-1 Error: Cannot find module "
         "'pion_wasm_rt.mjs' code: 'MODULE_NOT_FOUND'"),
        ("outcome_mismatch", "pion-native: outcome ok, expected panic:div_zero"),
    ])
    m = [x for x in MUTANTS if x[0] == infra[0]][0]
    if mutant_detected(infra[1], m[4], m[5])[0]:
        problems.append("an infrastructure failure was accepted as a mutant detection")
    if mutant_detected([], m[4], m[5])[0]:
        problems.append("a green mutant was accepted")
    return problems


def self_test(env, moon_results):
    print("\n== negative self-test (each mutant must be reported red)")
    ok = True
    for p in classifier_selftest():
        print("SELFTEST FAIL  classifier: " + p)
        ok = False
    if ok:
        print("selftest ok    classifier hard-fails SIGSEGV/SIGFPE/timeout/exit/raw trap/empty run;"
              " infrastructure failures never count as detections")
    for name, case, old, new, required, allowed in MUTANTS:
        d = make_mutant(env, name, old, new)
        res = {"moon": moon_results[case],
               "pion-native": run_pion(env, d, "native", case),
               "pion-wasm32": run_pion(env, d, "wasm32", case)}
        errs, _ = evaluate(case, res)
        detected, why = mutant_detected(errs, required, allowed)
        if detected:
            print("selftest ok    mutant %-24s on %-16s -> red [%s]" % (name, case, why))
        else:
            print("SELFTEST FAIL  mutant %-24s on %-16s %s" % (name, case, why))
            ok = False
    return ok


def bench(env):
    print("\n== hot-path micro-benchmarks (informative)")
    for target in ("native", "wasm32"):
        cmd = [env.pionc, "run", "--release"]
        if target == "wasm32":
            cmd += ["--target", "wasm32"]
        cmd += [PION_PROBE, "--", "bench"]
        rc, out, err, to, secs = run(cmd)
        if rc != 0:
            print("bench %s failed rc=%s %s" % (target, rc, err[-500:]))
            return False
        for line in out.splitlines():
            if line.startswith("B "):
                print("%-7s %s" % (target, line[2:]))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-self-test", action="store_true")
    ap.add_argument("--no-bench", action="store_true")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--report", default="")
    ap.add_argument("--case", action="append", default=[])
    ap.add_argument("--pionc", default="",
                    help="pionc under test (else $PIONC, else pionc on PATH)")
    ap.add_argument("--moon", default="",
                    help="reference moon (else $MOON, else moon on PATH)")
    args = ap.parse_args()

    pionc, pionc_src = resolve_tool("pionc", args.pionc, "PIONC")
    moon, moon_src = resolve_tool("moon", args.moon, "MOON")
    node = shutil.which("node")
    if not pionc or not moon or not node:
        print("HARD FAIL: missing tool: pionc=%s (%s) moon=%s (%s) node=%s" %
              (pionc, pionc_src, moon, moon_src, node))
        return 2
    for label, tool, src in (("pionc", pionc, pionc_src), ("moon", moon, moon_src)):
        rc, out, err, to, _ = run([tool, "version"] if label == "moon" else [tool, "--version"])
        if rc != 0:
            print("HARD FAIL: %s %s does not run (rc=%s): %s" % (label, tool, rc, err.strip()[:300]))
            return 2
        print("tool       %-5s %s [%s] %s" % (label, tool, src, out.strip().splitlines()[0]))
    for c in args.case:
        if c not in CASES:
            print("unknown case " + c)
            return 2
    cases = args.case or sorted(CASES)
    if not cases:
        print("HARD FAIL: 0 cases selected")
        return 1
    workdir = tempfile.mkdtemp(prefix="mbt_compat_oracle_")
    env = Env(moon, pionc, workdir)
    try:
        if not prepare(env):
            return 1
        t0 = time.time()
        results = run_suite(env, cases, args.jobs)
        print("\n== differential oracle: %d cases x %d engines (%.1fs)" %
              (len(cases), len(ENGINES), time.time() - t0))
        failed = 0
        total_asserts = 0
        total_traces = 0
        report = []
        for c in cases:
            errs, parsed = evaluate(c, results[c])
            cls = parsed["moon"][0]
            n_t = len(parsed["moon"][1])
            n_a = len(parsed["moon"][2])
            total_traces += n_t
            total_asserts += n_a
            status = "PASS" if not errs else "FAIL"
            print("%s %-24s outcome=%-19s traces=%-5d asserts=%-2d (moon=pion-native=pion-wasm32)"
                  % (status, c, cls, n_t, n_a) if not errs else "%s %s" % (status, c))
            for cat, e in errs:
                print("     [%s] %s" % (cat, e))
            if errs:
                failed += 1
            report.append({"case": c, "ok": not errs, "outcome": {e: parsed[e][0] for e in ENGINES},
                           "traces": n_t, "asserts": parsed["moon"][2],
                           "errors": [{"category": c, "message": m} for c, m in errs]})
        if total_asserts == 0:
            print("HARD FAIL: 0 assertions executed")
            failed += 1
        print("\nsummary: %d/%d cases identical on moon wasm-gc, pion native, pion wasm32; "
              "%d trace lines and %d assertions per engine" %
              (len(cases) - failed, len(cases), total_traces, total_asserts))
        ok = failed == 0
        if not args.no_self_test:
            moon_results = {c: results[c]["moon"] for c in cases}
            missing = [m[1] for m in MUTANTS if m[1] not in moon_results]
            for c in missing:
                moon_results[c] = run_moon(env, c)
            ok = self_test(env, moon_results) and ok
        if not args.no_bench:
            ok = bench(env) and ok
        if args.report:
            with open(args.report, "w") as f:
                json.dump({"ok": ok, "cases": report}, f, indent=1)
        print("\nORACLE " + ("GREEN" if ok else "RED"))
        return 0 if ok else 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
