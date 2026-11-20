#!/usr/bin/env python3
"""agent_eval harness: m2 vs MoonBit vs Rust vs Go, three dimensions.

  python3 agent_eval.py dim1 [--only t01,...] [--lang m2,...]
  python3 agent_eval.py dim2 [--only e01,...] [--lang ...] [--runs N]
  python3 agent_eval.py dim3 [--runs N]
  python3 agent_eval.py report

Every partial result is written to <repo>/out/agent_eval/<dim>.json; `report`
merges them into benchmarks/agent_eval/results.json and SUMMARY.md.
Nothing is written inside the source tree except those two files: MoonBit and
Rust projects are copied to <repo>/out/agent_eval/work before building (their
tools create `_build/` / `target/` in-tree), m2 and Go build in place (their
caches are global).
"""
import argparse
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
AE = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(AE))
OUT = os.path.join(ROOT, "out", "agent_eval")
WORK = os.path.join(OUT, "work")
M2C2 = os.path.join(ROOT, "out", "m2c2")
LANGS = ["m2", "moonbit", "rust", "go"]

sys.path.insert(0, HERE)
import metrics  # noqa: E402


def base_env():
    env = dict(os.environ)
    home = env.get("HOME", "")
    env["PATH"] = ":".join([home + "/.moon/bin", home + "/.cargo/bin", "/opt/homebrew/bin",
                            "/usr/local/go/bin", "/usr/bin", "/bin", env.get("PATH", "")])
    env["M2_QBE"] = os.path.join(ROOT, "out", "qbe")
    env["M2_RT_LIB"] = os.path.join(ROOT, "out", "libm2rt.a")
    env.setdefault("M2_CACHE_DIR", os.path.join(OUT, "m2cas"))
    env["CARGO_TERM_COLOR"] = "never"
    env["NO_COLOR"] = "1"
    return env


ENV = base_env()


def run(cmd, cwd, env=None, timeout=600, stdin=None):
    t0 = time.perf_counter()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env or ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        rc, so, se = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        rc, so, se = -999, e.stdout or b"", (e.stderr or b"") + b"\n[agent_eval] TIMEOUT"
    ms = (time.perf_counter() - t0) * 1000.0
    return rc, so.decode("utf-8", "replace"), se.decode("utf-8", "replace"), ms


def median_stats(samples):
    return {
        "median_ms": round(statistics.median(samples), 1),
        "min_ms": round(min(samples), 1),
        "max_ms": round(max(samples), 1),
        "runs": len(samples),
    }


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=1, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, path)


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def fresh_copy(src, dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
    return dst


def tool_versions():
    out = {}
    for name, cmd in [("moon", ["moon", "version"]), ("cargo", ["cargo", "--version"]),
                      ("rustc", ["rustc", "--version"]), ("go", ["go", "version"]),
                      ("clang", ["clang", "--version"])]:
        rc, so, se, _ = run(cmd, ROOT)
        out[name] = (so or se).strip().splitlines()[0] if rc == 0 else "unavailable"
    out["m2c2_bytes"] = os.path.getsize(M2C2) if os.path.exists(M2C2) else None
    rc, so, _, _ = run(["git", "rev-parse", "--short", "HEAD"], ROOT)
    out["repo_commit"] = so.strip() or os.environ.get("AE_REPO_COMMIT", "unknown (run directory has no .git)")
    out["host"] = platform.node()
    out["machine"] = platform.machine()
    rc, so, _, _ = run(["sysctl", "-n", "machdep.cpu.brand_string"], ROOT)
    out["cpu"] = so.strip()
    rc, so, _, _ = run(["sysctl", "-n", "hw.ncpu"], ROOT)
    out["ncpu"] = so.strip()
    return out


def loadavg():
    try:
        return [round(x, 2) for x in os.getloadavg()]
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Dimension 1: 12 tasks x 4 languages
# ---------------------------------------------------------------------------

def list_tasks(only):
    tdir = os.path.join(AE, "tasks")
    names = sorted(d for d in os.listdir(tdir) if re.match(r"t\d\d_", d))
    if only:
        keys = only.split(",")
        names = [n for n in names if any(n.startswith(k) for k in keys)]
    return names


def m2_test_dirs(d):
    dirs = []
    for dirpath, dirnames, filenames in os.walk(d):
        dirnames.sort()
        if "m2.toml" in filenames:
            dirs.append(dirpath)
    return dirs


def lang_run_test(lang, src, workdir):
    """Returns (run_result, test_result) dicts for one implementation."""
    if lang == "m2":
        d = src
        rc, so, se, ms = run([M2C2, "run", d], d)
        runr = {"rc": rc, "stdout": so, "stderr": se, "ms": ms}
        passed = failed = 0
        ok = True
        details = []
        tms = 0.0
        for td in m2_test_dirs(d):
            trc, tso, tse, tm = run([M2C2, "test", "--json", td], td)
            tms += tm
            try:
                j = json.loads(tso.strip().splitlines()[-1])
                passed += int(j.get("passed", 0))
                failed += int(j.get("failed", 0))
                ok = ok and bool(j.get("ok")) and trc == 0
            except (ValueError, IndexError):
                ok = False
            details.append((tso + tse)[-2000:])
        return runr, {"ok": ok and failed == 0 and passed > 0, "passed": passed, "failed": failed,
                      "ms": tms, "log": "\n".join(details)[-4000:]}
    if lang == "moonbit":
        d = fresh_copy(src, workdir)
        rc, so, se, ms = run(["moon", "run", "src/main", "--target", "native"], d)
        runr = {"rc": rc, "stdout": so, "stderr": se, "ms": ms}
        trc, tso, tse, tm = run(["moon", "test", "--target", "native"], d)
        m = re.search(r"Total tests: (\d+), passed: (\d+), failed: (\d+)", tso + tse)
        passed = int(m.group(2)) if m else 0
        failed = int(m.group(3)) if m else -1
        return runr, {"ok": trc == 0 and failed == 0 and passed > 0, "passed": passed, "failed": failed,
                      "ms": tm, "log": (tso + tse)[-4000:]}
    if lang == "rust":
        d = fresh_copy(src, workdir)
        rc, so, se, ms = run(["cargo", "run", "-q", "--offline"], d)
        runr = {"rc": rc, "stdout": so, "stderr": se, "ms": ms}
        trc, tso, tse, tm = run(["cargo", "test", "-q", "--offline", "--workspace"], d)
        passed = sum(int(x) for x in re.findall(r"test result: ok\. (\d+) passed", tso))
        failed = sum(int(x) for x in re.findall(r"(\d+) failed", tso))
        return runr, {"ok": trc == 0 and failed == 0 and passed > 0, "passed": passed, "failed": failed,
                      "ms": tm, "log": (tso + tse)[-4000:]}
    if lang == "go":
        d = src
        rc, so, se, ms = run(["go", "run", "."], d)
        runr = {"rc": rc, "stdout": so, "stderr": se, "ms": ms}
        trc, tso, tse, tm = run(["go", "test", "-count=1", "-v", "./..."], d)
        passed = len(re.findall(r"^\s*--- PASS: ", tso, re.M))
        failed = len(re.findall(r"^\s*--- FAIL: ", tso, re.M))
        return runr, {"ok": trc == 0 and failed == 0 and passed > 0, "passed": passed, "failed": failed,
                      "ms": tm, "log": (tso + tse)[-4000:]}
    raise ValueError(lang)


def cmd_dim1(args):
    path = os.path.join(OUT, "dim1.json")
    res = load_json(path, {}) if (args.only or args.lang) else {}
    res.setdefault("tasks", {})
    langs = args.lang.split(",") if args.lang else LANGS
    for task in list_tasks(args.only):
        tdir = os.path.join(AE, "tasks", task)
        with open(os.path.join(tdir, "expected.txt"), "r", encoding="utf-8") as fh:
            expected = fh.read().rstrip("\n")
        entry = res["tasks"].setdefault(task, {})
        for lang in langs:
            src = os.path.join(tdir, lang)
            if not os.path.isdir(src):
                entry[lang] = {"present": False, "pass": False}
                print("[dim1] %s %-7s MISSING" % (task, lang), flush=True)
                continue
            runr, testr = lang_run_test(lang, src, os.path.join(WORK, "dim1", task, lang))
            out_ok = runr["rc"] == 0 and runr["stdout"].rstrip("\n") == expected
            m = metrics.measure_dir(src)
            e = {
                "present": True,
                "run_ok": out_ok,
                "run_rc": runr["rc"],
                "run_ms": round(runr["ms"], 1),
                "test_ok": testr["ok"],
                "tests_passed": testr["passed"],
                "tests_failed": testr["failed"],
                "test_ms": round(testr["ms"], 1),
                "pass": out_ok and testr["ok"],
                "metrics": m,
            }
            if not out_ok:
                e["stdout_tail"] = runr["stdout"][-1500:]
                e["stderr_tail"] = runr["stderr"][-2500:]
            if not testr["ok"]:
                e["test_log_tail"] = testr["log"]
            entry[lang] = e
            print("[dim1] %s %-7s run=%s test=%s (%d passed) loc=%d tok=%d" % (
                task, lang, "OK" if out_ok else "FAIL", "OK" if testr["ok"] else "FAIL",
                testr["passed"], m["loc"], m["lex_tokens"]), flush=True)
            if not e["pass"]:
                print(e.get("stdout_tail", "") + e.get("stderr_tail", "") + e.get("test_log_tail", ""),
                      flush=True)
    write_json(path, res)
    total = sum(1 for t in res["tasks"].values() for e in t.values())
    passed = sum(1 for t in res["tasks"].values() for e in t.values() if e.get("pass"))
    print("[dim1] %d/%d implementations pass" % (passed, total), flush=True)
    return 0 if passed == total else 1


# ---------------------------------------------------------------------------
# Dimension 2: 12 agent error classes x 4 languages
# ---------------------------------------------------------------------------

CHECK_CMDS = {
    "m2": lambda d: [M2C2, "check", "--json", d],
    "moonbit": lambda d: ["moon", "check", "--target", "native", "--output-json"],
    "rust": lambda d: ["cargo", "check", "--offline", "--message-format=json"],
    "go": lambda d: ["go", "build", "-json", "-o", os.devnull, "./..."],
}
CHECK_CMD_TEXT = {
    "m2": "m2c2 check --json <dir>",
    "moonbit": "moon check --target native --output-json",
    "rust": "cargo check --offline --message-format=json",
    "go": "go build -json -o /dev/null ./...",
}


def list_errors(only):
    edir = os.path.join(AE, "errors")
    names = sorted(d for d in os.listdir(edir) if re.match(r"e\d\d_", d))
    if only:
        keys = only.split(",")
        names = [n for n in names if any(n.startswith(k) for k in keys)]
    return names


def touch_sources(d):
    for p in metrics.source_files(d):
        with open(p, "rb") as fh:
            data = fh.read()
        with open(p, "wb") as fh:
            fh.write(data)


FIXIT_TEXT = [""]


def parse_diags(lang, so, se):
    """Returns (errors, warnings, has_fixit, structured, first_error_message).
    The first fix suggestion seen is left in FIXIT_TEXT[0]."""
    FIXIT_TEXT[0] = ""
    errors = warnings = 0
    has_fixit = False
    structured = False
    first = ""
    if lang == "m2":
        try:
            j = json.loads(so.strip().splitlines()[-1])
            structured = True
            for dg in j.get("diagnostics", []):
                errors += 1
                if dg.get("fixit"):
                    has_fixit = True
                    if not FIXIT_TEXT[0]:
                        FIXIT_TEXT[0] = "hint: " + dg.get("fixit")
                if not first:
                    first = "%s: %s" % (dg.get("code"), dg.get("message"))
        except (ValueError, IndexError):
            pass
    elif lang == "rust":
        for line in so.splitlines():
            try:
                j = json.loads(line)
            except ValueError:
                continue
            structured = True
            if j.get("reason") != "compiler-message":
                continue
            msg = j.get("message", {})
            lvl = msg.get("level")
            if lvl == "error":
                if msg.get("message", "").startswith("aborting due to"):
                    continue
                errors += 1
                if not first:
                    code = (msg.get("code") or {}).get("code") or ""
                    first = ("%s: %s" % (code, msg.get("message"))).strip(": ")
            elif lvl == "warning":
                warnings += 1
                if not first and errors == 0:
                    pass
            for ch in msg.get("children", []) + [msg]:
                for sp in ch.get("spans", []):
                    if sp.get("suggested_replacement") is not None and lvl in ("error", "warning"):
                        has_fixit = True
                        appl = sp.get("suggestion_applicability") or "Unspecified"
                        if not FIXIT_TEXT[0] or (appl == "MachineApplicable" and "MachineApplicable" not in FIXIT_TEXT[0]):
                            FIXIT_TEXT[0] = "edit (%s): %s -> %r" % (appl, ch.get("message", "")[:80],
                                                                    sp.get("suggested_replacement")[:80])
        # warnings only (no error): keep the first warning text for the record
        if errors == 0 and warnings:
            for line in so.splitlines():
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                msg = j.get("message", {}) if j.get("reason") == "compiler-message" else {}
                if msg.get("level") == "warning" and not msg.get("message", "").startswith("unused import"):
                    first = "warning: " + msg.get("message", "")
                    break
    elif lang == "moonbit":
        for line in (so + "\n" + se).splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                j = json.loads(line)
            except ValueError:
                continue
            structured = True
            lvl = (j.get("level") or "").lower()
            if lvl == "error":
                errors += 1
                if not first:
                    first = "%s: %s" % (j.get("error_code"), j.get("message", "").splitlines()[0])
            elif lvl == "warning":
                warnings += 1
            if j.get("fix") or j.get("fixit") or j.get("suggestion"):
                has_fixit = True
        if errors == 0 and warnings and not first:
            for line in (so + "\n" + se).splitlines():
                if line.strip().startswith("{"):
                    try:
                        j = json.loads(line.strip())
                    except ValueError:
                        continue
                    if (j.get("level") or "").lower() == "warning":
                        first = "warning: %s" % j.get("message", "").splitlines()[0]
                        break
    elif lang == "go":
        texts = []
        for line in so.splitlines():
            try:
                j = json.loads(line)
            except ValueError:
                continue
            structured = True
            if j.get("Action") == "build-output" or "Output" in j:
                texts.append(j.get("Output", ""))
        text = "".join(texts) + se
        for line in text.splitlines():
            if re.match(r"^\S+\.go:\d+:\d+: ", line) or re.match(r"^\./\S+\.go:\d+", line):
                errors += 1
                if not first:
                    first = line.split(": ", 1)[1] if ": " in line else line
    return errors, warnings, has_fixit, structured, first.strip()


def cmd_dim2(args):
    path = os.path.join(OUT, "dim2.json")
    res = load_json(path, {}) if (args.only or args.lang) else {}
    res.setdefault("errors", {})
    res["check_commands"] = CHECK_CMD_TEXT
    langs = args.lang.split(",") if args.lang else LANGS
    runs = args.runs
    gate_ok = True
    for err in list_errors(args.only):
        edir = os.path.join(AE, "errors", err)
        expect = load_json(os.path.join(edir, "expect.json"), {})
        entry = res["errors"].setdefault(err, {"title": expect.get("title", err)})
        entry["title"] = expect.get("title", err)
        for lang in langs:
            src = os.path.join(edir, lang)
            if not os.path.isdir(src):
                entry[lang] = {"present": False}
                gate_ok = False
                print("[dim2] %s %-7s MISSING" % (err, lang), flush=True)
                continue
            if lang in ("moonbit", "rust"):
                d = fresh_copy(src, os.path.join(WORK, "dim2", err, lang))
            else:
                d = src
            cmd = CHECK_CMDS[lang](d)
            samples = []
            last = None
            for i in range(runs + 1):
                touch_sources(d)
                rc, so, se, ms = run(cmd, d)
                last = (rc, so, se)
                if i > 0:
                    samples.append(ms)
            rc, so, se = last
            errors, warnings, has_fixit, structured, first = parse_diags(lang, so, se)
            out_bytes = len((so + se).encode("utf-8"))
            exp = expect.get(lang, {})
            want_caught = exp.get("caught")
            pattern = exp.get("pattern")
            caught = rc != 0 and errors > 0
            matched = True
            if caught and pattern:
                matched = re.search(pattern, first + "\n" + so + se, re.S) is not None
            consistent = (want_caught is None or want_caught == caught) and matched
            if not consistent:
                gate_ok = False
            e = {
                "present": True,
                "caught_compile_time": caught,
                "check_rc": rc,
                "errors": errors,
                "warnings": warnings,
                "first_diagnostic": first[:300],
                "latency": median_stats(samples),
                "output_bytes": out_bytes,
                "output_est_tokens": (out_bytes + 3) // 4,
                "structured_json": structured,
                "has_fixit": has_fixit,
                "fixit_sample": FIXIT_TEXT[0][:240],
                "machine_applicable_fix": "MachineApplicable" in FIXIT_TEXT[0],
                "matches_expectation": consistent,
                "note": exp.get("note", ""),
                "applicable": exp.get("applicable", True),
            }
            if lang == "go" and exp.get("race_probe"):
                rrc, rso, rse, rms = run(["go", "run", "-race", "."], d, timeout=300)
                e["runtime_race_detector"] = {
                    "cmd": "go run -race .",
                    "rc": rrc,
                    "detected": "WARNING: DATA RACE" in (rso + rse),
                    "ms": round(rms, 1),
                }
            if not consistent:
                e["raw_tail"] = (so + se)[-3000:]
            entry[lang] = e
            print("[dim2] %s %-7s caught=%s errs=%d warns=%d %.0fms %dB json=%s fixit=%s ok=%s | %s" % (
                err, lang, caught, errors, warnings, e["latency"]["median_ms"], out_bytes, structured,
                has_fixit, consistent, first[:110]), flush=True)
            if not consistent:
                print((so + se)[-2000:], flush=True)
    write_json(path, res)
    print("[dim2] gate %s" % ("PASS" if gate_ok else "FAIL"), flush=True)
    return 0 if gate_ok else 1


# ---------------------------------------------------------------------------
# Dimension 3: edit->test loop, API exploration cost, 5 concurrent worktrees
# ---------------------------------------------------------------------------

T06 = os.path.join(AE, "tasks", "t06_multi_pkg_refactor")

TEST_CMDS = {
    # `m2c2 test <workspace>` runs only the root package's tests, so every package
    # directory is tested in turn (cargo --workspace / go ./... / moon test cover all three).
    "m2": lambda d: ["/bin/sh", "-c", " && ".join("%s test --json %s" % (_q(M2C2), _q(t)) for t in m2_test_dirs(d))],
    "moonbit": lambda d: ["moon", "test", "--target", "native"],
    "rust": lambda d: ["cargo", "test", "-q", "--offline", "--workspace"],
    "go": lambda d: ["go", "test", "./..."],
}
CHECK3_CMDS = {
    "m2": lambda d: [M2C2, "check", "--json", d],
    "moonbit": lambda d: ["moon", "check", "--target", "native"],
    "rust": lambda d: ["cargo", "check", "-q", "--offline", "--workspace"],
    "go": lambda d: ["go", "vet", "./..."],
}
TEST_CMD_TEXT = {
    "m2": "m2c2 test --json <pkg> for each of the 3 package dirs",
    "moonbit": "moon test --target native",
    "rust": "cargo test -q --offline --workspace",
    "go": "go test ./...",
}

EDIT_MARK = {"body": "AE_EDIT_BODY", "iface": "AE_EDIT_IFACE"}


def apply_edit(d, mark, n):
    """Rewrites the single line tagged `mark` into a never-seen-before but equivalent form, so no
    content-addressed cache (m2 CAS, Go build/test cache) can short-circuit the edit:
    a body edit sets the private constant to `<n+1> - <n>`; an interface edit renames the exported
    (unused) probe function to a fresh name `ae_probe_k<n>` / `AeProbeK<n>`."""
    hits = 0
    for p in metrics.source_files(d):
        with open(p, "r", encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        changed = False
        for i, line in enumerate(lines):
            if mark not in line:
                continue
            if mark == EDIT_MARK["body"]:
                new = re.sub(r"(=\s*)[^=/;]+?(\s*;?\s*//)", lambda m: "%s%d - %d%s" % (m.group(1), n + 1, n, m.group(2)),
                             line, count=1)
            else:
                new = re.sub(r"\b(ae_probe_|AeProbe)\w*", lambda m: m.group(1) + ("k%d" % n if m.group(1) == "ae_probe_"
                                                                                  else "K%d" % n), line, count=1)
            if new != line:
                lines[i] = new
                changed = True
                hits += 1
        if changed:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines))
    return hits


def du_bytes(path):
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):
        for f in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, f)).st_size
            except OSError:
                pass
    return total


def cmd_dim3(args):
    runs = args.runs
    res = {"project": "tasks/t06_multi_pkg_refactor", "test_commands": TEST_CMD_TEXT, "loadavg_start": loadavg()}

    # 3.1 edit -> test loop (body-only edit and exported-interface edit)
    loop = {}
    for lang in LANGS:
        d = fresh_copy(os.path.join(T06, lang), os.path.join(WORK, "dim3", "loop", lang))
        env = dict(ENV)
        # cold = fresh copy *and* fresh global caches (m2 CAS, Go build/test cache)
        for c in ("m2cas", "gocache"):
            shutil.rmtree(os.path.join(WORK, "dim3", "loop", c), ignore_errors=True)
        env["M2_CACHE_DIR"] = os.path.join(WORK, "dim3", "loop", "m2cas")
        env["GOCACHE"] = os.path.join(WORK, "dim3", "loop", "gocache")
        rc, so, se, cold_ms = run(TEST_CMDS[lang](d), d, env=env)
        entry = {"cold_test_ms": round(cold_ms, 1), "cold_ok": rc == 0}
        for kind in ("body", "iface"):
            samples = []
            ok = True
            for i in range(runs + 1):
                hits = apply_edit(d, EDIT_MARK[kind], 1000 * (1 if kind == "body" else 2) + i)
                if hits == 0:
                    ok = False
                rc, so, se, ms = run(TEST_CMDS[lang](d), d, env=env)
                if rc != 0:
                    ok = False
                    entry[kind + "_fail_tail"] = (so + se)[-2000:]
                if i > 0:
                    samples.append(ms)
            entry[kind + "_edit"] = dict(median_stats(samples), ok=ok)
            entry[kind + "_last_output"] = (so + se)[-400:]
        loop[lang] = entry
        print("[dim3] loop %-7s cold=%.0fms body=%.0fms iface=%.0fms ok=%s/%s" % (
            lang, cold_ms, entry["body_edit"]["median_ms"], entry["iface_edit"]["median_ms"],
            entry["body_edit"]["ok"], entry["iface_edit"]["ok"]), flush=True)
    res["edit_test_loop"] = loop

    # 3.2 API exploration token cost
    explore = {}
    for lang in LANGS:
        src = os.path.join(T06, lang)
        full = metrics.measure_dir(src)
        e = {"full_source_bytes": full["bytes"], "full_source_est_tokens": full["est_tokens_bytes_div4"]}
        if lang == "m2":
            parts = {}
            for name, cmd in [("doc_json", [M2C2, "doc", "--json", src]),
                              # `query` takes source files (a workspace directory yields an empty table)
                              ("query_defs_json", [M2C2, "query", "defs", "--json"] + metrics.source_files(src)),
                              ("query_callers_json", [M2C2, "query", "callers", "--json"] + metrics.source_files(src)),
                              ("doc_text", [M2C2, "doc", src])]:
                rc, so, se, ms = run(cmd, src)
                parts[name] = {"rc": rc, "bytes": len(so.encode()), "ms": round(ms, 1)}
            e["api_tool"] = "m2c2 doc --json"
            e["api_bytes"] = parts["doc_json"]["bytes"]
            e["api_ok"] = parts["doc_json"]["rc"] == 0
            e["extra"] = parts
            stdp = {}
            for pkg in ("std/json", "std/http"):
                pdir = os.path.join(ROOT, pkg)
                rc, so, se, ms = run([M2C2, "doc", "--json", pdir], pdir)
                stdp[pkg] = {"doc_json_bytes": len(so.encode()), "rc": rc,
                             "source_bytes": metrics.measure_dir(pdir)["bytes"]}
            e["m2_std_packages"] = stdp
        elif lang == "go":
            d = src
            rc, so, se, ms = run(["go", "list", "./..."], d)
            pkgs = [p for p in so.split() if p]
            total = 0
            ok = rc == 0
            for p in pkgs:
                rc2, so2, se2, _ = run(["go", "doc", "-all", p], d)
                ok = ok and rc2 == 0
                total += len(so2.encode())
            e["api_tool"] = "go doc -all <pkg> (every package)"
            e["api_bytes"] = total
            e["api_ok"] = ok
        elif lang == "moonbit":
            d = fresh_copy(src, os.path.join(WORK, "dim3", "explore", lang))
            rc, so, se, ms = run(["moon", "info", "--target", "native"], d)
            total = 0
            for dirpath, dirnames, filenames in os.walk(d):
                dirnames[:] = [x for x in dirnames if x not in ("_build", "target", ".mooncakes")]
                for f in filenames:
                    if f.endswith(".mbti"):
                        total += os.path.getsize(os.path.join(dirpath, f))
            e["api_tool"] = "moon info (generated .mbti files)"
            e["api_bytes"] = total
            e["api_ok"] = rc == 0 and total > 0
        elif lang == "rust":
            e["api_tool"] = "none on stable (cargo doc emits HTML; rustdoc JSON is nightly-only) -> read sources"
            e["api_bytes"] = full["bytes"]
            e["api_ok"] = True
        e["api_est_tokens"] = (e["api_bytes"] + 3) // 4
        explore[lang] = e
        print("[dim3] explore %-7s api=%dB full=%dB (%s)" % (lang, e["api_bytes"], e["full_source_bytes"],
                                                          e["api_tool"]), flush=True)
    res["api_exploration"] = explore

    # 3.3 five concurrent agent worktrees (cold caches), check + test each
    conc = {}
    for lang in LANGS:
        walls = []
        last = None
        for i in range(runs + 1):
            base = os.path.join(WORK, "dim3", "wt", lang)
            if os.path.exists(base):
                shutil.rmtree(base)
            os.makedirs(base)
            env = dict(ENV)
            env["M2_CACHE_DIR"] = os.path.join(base, "_global_m2cas")
            env["GOCACHE"] = os.path.join(base, "_global_gocache")
            wts = [fresh_copy(os.path.join(T06, lang), os.path.join(base, "wt%d" % k)) for k in range(5)]
            src_bytes = du_bytes(wts[0])
            t0 = time.perf_counter()
            procs = []
            for w in wts:
                sh = "%s && %s" % (" ".join(_q(x) for x in CHECK3_CMDS[lang](w)),
                                   " ".join(_q(x) for x in TEST_CMDS[lang](w)))
                procs.append(subprocess.Popen(["/bin/sh", "-c", sh], cwd=w, env=env, stdout=subprocess.PIPE,
                                              stderr=subprocess.STDOUT))
            outs = [p.communicate()[0].decode("utf-8", "replace") for p in procs]
            wall = (time.perf_counter() - t0) * 1000.0
            rcs = [p.returncode for p in procs]
            in_tree = [du_bytes(w) - src_bytes for w in wts]
            glob = du_bytes(env["M2_CACHE_DIR"]) + du_bytes(env["GOCACHE"])
            last = {"rcs": rcs, "in_tree_bytes": in_tree, "global_cache_bytes": glob, "sample": outs[0][-600:],
                    "fail_tail": [o[-1500:] for o, r in zip(outs, rcs) if r != 0][:1]}
            if i > 0:
                walls.append(wall)
        e = dict(median_stats(walls))
        e["all_ok"] = all(r == 0 for r in last["rcs"])
        e["in_tree_bytes_total"] = sum(last["in_tree_bytes"])
        e["in_tree_mb_total"] = round(sum(last["in_tree_bytes"]) / 1048576.0, 2)
        e["global_cache_mb"] = round(last["global_cache_bytes"] / 1048576.0, 2)
        e["sample_output_wt0"] = last["sample"]
        if not e["all_ok"]:
            e["fail_tail"] = last["fail_tail"]
        conc[lang] = e
        print("[dim3] 5wt %-7s wall=%.0fms in_tree=%.2fMB global=%.2fMB ok=%s" % (
            lang, e["median_ms"], e["in_tree_mb_total"], e["global_cache_mb"], e["all_ok"]), flush=True)
        shutil.rmtree(os.path.join(WORK, "dim3", "wt", lang), ignore_errors=True)
    res["concurrent_worktrees"] = conc
    res["loadavg_end"] = loadavg()
    write_json(os.path.join(OUT, "dim3.json"), res)
    ok = all(v["body_edit"]["ok"] and v["iface_edit"]["ok"] for v in loop.values()) and \
        all(v["all_ok"] for v in conc.values()) and all(v["api_ok"] for v in explore.values())
    print("[dim3] gate %s" % ("PASS" if ok else "FAIL"), flush=True)
    return 0 if ok else 1


def _q(s):
    if re.match(r"^[A-Za-z0-9_./=:-]+$", s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def cmd_report(args):
    import report  # noqa: E402
    d1 = load_json(os.path.join(OUT, "dim1.json"), {})
    d2 = load_json(os.path.join(OUT, "dim2.json"), {})
    d3 = load_json(os.path.join(OUT, "dim3.json"), {})
    results = {
        "suite": "benchmarks/agent_eval",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": tool_versions(),
        "loadavg_at_report": loadavg(),
        "protocol": "dim2/dim3 timings: 1 warmup + %s timed runs, median" % (args.runs,),
        "dim1_tasks": d1,
        "dim2_diagnostics": d2,
        "dim3_loop": d3,
    }
    results["summary"] = report.summarize(results)
    write_json(os.path.join(AE, "results.json"), results)
    with open(os.path.join(AE, "SUMMARY.md"), "w", encoding="utf-8") as fh:
        fh.write(report.markdown(results))
    print("[report] wrote results.json and SUMMARY.md", flush=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["dim1", "dim2", "dim3", "report"])
    ap.add_argument("--only", default="")
    ap.add_argument("--lang", default="")
    ap.add_argument("--runs", type=int, default=5)
    args = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)
    return {"dim1": cmd_dim1, "dim2": cmd_dim2, "dim3": cmd_dim3, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
