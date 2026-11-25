"""P127 checker.

  check.py out PROG_OUT REF_OUT WANT_MODE
      The program printed 256 "V" lines (all exceptions masked) and 256 "S"
      lines (divide-by-zero trap enabled) that are identical, field for field,
      and a final "mode A B" line equal to WANT_MODE ("1 1": both FP states
      read back; "any": not required). Every V field equals ref.c's, except
      that a NaN in ref.c only requires a NaN (the winning payload of two NaN
      operands is target-defined; the V == S comparison pins it exactly).
  check.py asm FILE.s TARGET
      drift / orbit / kick in the QBE text for amd64_sysv or arm64_apple carry
      the trap-mask entry test, the packed operations listed in WANT, a
      retained scalar arm, and (kick) a 16-byte aligned frame slot written
      with the whole packet before the foreign call and reloaded after it;
      shear, whose packing would move a read of one base across a write of
      another that may alias it, has no entry test and no packed code.
  check.py objcmp DIRECT.dis TEXT.dis
      objdump listings of the direct-object and assembled-text executables
      have the same multiset of packed / MXCSR mnemonics in drift, orbit and
      kick (amd64_sysv).
"""
import re
import sys
from collections import Counter

FUNCS = ("drift", "orbit", "kick")


def fail(msg):
    raise SystemExit(f"FAIL: p127 {msg}")


def is_nan(bits):
    u = bits & 0xFFFFFFFFFFFFFFFF
    return (u & 0x7FF0000000000000) == 0x7FF0000000000000 and (u & 0xFFFFFFFFFFFFF) != 0


def check_out(prog, ref, want_mode):
    lines = open(prog).read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    v = [l[2:] for l in lines if l.startswith("V ")]
    s = [l[2:] for l in lines if l.startswith("S ")]
    mode = [l for l in lines if l.startswith("mode ")]
    if len(v) != 256 or len(s) != 256 or len(mode) != 1 or len(lines) != 513:
        fail(f"{prog}: {len(v)} V / {len(s)} S / {len(mode)} mode lines of {len(lines)}")
    if want_mode != "any" and mode[0] != "mode " + want_mode:
        fail(f"{prog}: '{mode[0]}', want 'mode {want_mode}'")
    for n, (a, b) in enumerate(zip(v, s)):
        if a != b:
            fail(f"{prog}: vector and scalar arms differ on row {n}\n  V {a}\n  S {b}")
    r = [l[2:] for l in open(ref).read().split("\n") if l.startswith("V ")]
    if len(r) != 256:
        fail(f"{ref}: {len(r)} rows")
    nan_only = 0
    for a, b in zip(v, r):
        fa, fb = a.split(), b.split()
        if len(fa) != len(fb):
            fail(f"row shape differs from ref.c\n  pion {a}\n  ref  {b}")
        for x, y in zip(fa, fb):
            if x == y:
                continue
            try:
                xi, yi = int(x), int(y)
            except ValueError:
                fail(f"row differs from ref.c\n  pion {a}\n  ref  {b}")
            if is_nan(xi) and is_nan(yi):
                nan_only += 1
                continue
            fail(f"row differs from ref.c ({x} vs {y})\n  pion {a}\n  ref  {b}")
    print(f"p127 {prog.rsplit('/', 1)[-1]}: 256 vector rows == 256 scalar rows, "
          f"{mode[0]}, equal to ref.c ({nan_only} NaN payload choices)")


def bodies(path, names=FUNCS + ("shear",)):
    text = open(path).read().split("\n")
    out = {}
    for f in names:
        start = None
        for i, l in enumerate(text):
            if re.fullmatch(rf"_?pion_fn_{f}:", l):
                start = i
                break
        if start is None:
            fail(f"{path}: no function pion_fn_{f}")
        body = []
        for l in text[start + 1:]:
            if l.startswith("/* end function"):
                break
            body.append(l.strip())
        out[f] = body
    return out


AMD64 = {
    "all": [r"stmxcsr ", r"andl \$8064, ", r"cmpl \$8064, ", r"addsd ", r"mulsd "],
    "drift": [r"movupd \(", r"movupd %xmm\d+, \(", r"pshufd \$68, ", r"mulpd ", r"addpd ",
              r"pshufd \$238, "],
    "orbit": [r"movupd \(", r"movupd %xmm\d+, \(", r"pshufd \$68, ", r"mulpd ", r"subpd ",
              r"addpd ", r"pshufd \$238, "],
    "kick": [r"mulpd ", r"addpd ", r"movupd %xmm\d+, \("],
}
ARM64 = {
    "all": [r"mrs\tx17, fpcr", r"mov\tw16, #0x9f00", r"tst\tw17, w16", r"fadd\td", r"fmul\td"],
    "drift": [r"ldu?r\tq\d+, \[x\d+", r"stu?r\tq\d+, \[x\d+", r"dup\tv\d+\.2d, v\d+\.d\[0\]", r"fmul\tv\d+\.2d, ",
              r"fadd\tv\d+\.2d, ", r"faddp\td\d+, v\d+\.2d"],
    "orbit": [r"ldu?r\tq\d+, \[x\d+", r"stu?r\tq\d+, \[x\d+", r"dup\tv\d+\.2d, v\d+\.d\[0\]", r"fmul\tv\d+\.2d, ",
              r"fsub\tv\d+\.2d, ", r"fadd\tv\d+\.2d, ", r"faddp\td\d+, v\d+\.2d"],
    "kick": [r"dup\tv\d+\.2d, v\d+\.d\[0\]", r"fmul\tv\d+\.2d, ", r"fadd\tv\d+\.2d, ", r"stu?r\tq\d+, \[x\d+"],
}


def check_asm(path, target):
    want = AMD64 if target == "amd64_sysv" else ARM64
    fns = bodies(path)
    shear = fns.pop("shear")
    packed = re.compile(r"stmxcsr|fpcr|[a-z]+pd |\.2d|\bq\d+")
    bad = [l for l in shear if packed.search(l)]
    if bad:
        fail(f"{path} {target}: pion_fn_shear (two bases that may alias) has packed code: {bad[:3]}")
    for f, body in fns.items():
        for pat in want["all"] + want[f]:
            if not any(re.search(pat, l) for l in body):
                fail(f"{path} {target}: pion_fn_{f} has no /{pat}/")
        n_test = sum(1 for l in body if re.search(want["all"][0], l))
        if n_test != 1:
            fail(f"{path} {target}: pion_fn_{f} reads the FP control register {n_test} times")
    # kick: the packet crosses p127_clobber_vectors in a private aligned slot.
    body = fns["kick"]
    if target == "amd64_sysv":
        st = re.compile(r"movupd %xmm\d+, (-?\d+)\(%rbp\)")
        ld = re.compile(r"movupd (-?\d+)\(%rbp\), %xmm\d+")
        call = re.compile(r"call[q]? _?p127_clobber_vectors")
    else:
        st = re.compile(r"stu?r\tq\d+, \[x29, #(-?\d+)\]")
        ld = re.compile(r"ldu?r\tq\d+, \[x29, #(-?\d+)\]")
        call = re.compile(r"bl\t_?p127_clobber_vectors")
    calls = [i for i, l in enumerate(body) if call.search(l)]
    if len(calls) != 2:
        fail(f"{path} {target}: pion_fn_kick calls p127_clobber_vectors {len(calls)} times, want 2 (packet and scalar arms)")
    found = False
    for c in calls:
        before = {m.group(1) for l in body[:c] for m in [st.search(l)] if m}
        after = {m.group(1) for l in body[c + 1:] for m in [ld.search(l)] if m}
        for off in before & after:
            if int(off) % 16 == 0:
                found = True
    if not found:
        fail(f"{path} {target}: pion_fn_kick does not keep the packet in a 16-byte aligned slot across the call")
    print(f"p127 {path.rsplit('/', 1)[-1]} {target}: drift / orbit / kick packed, "
          f"trap-mask entry test, scalar arm, packet spilled across the call; "
          f"shear (aliasing bases) scalar only")


def dis_counts(path):
    cur = None
    out = {f: Counter() for f in FUNCS}
    for l in open(path):
        # Single-file builds name a function pion_fn_<f>, packages
        # pion_pkg_<id>_<pkg>_fn_<f>.
        m = re.match(r"^[0-9a-f]+ <_?pion_(?:pkg_\w+?_)?fn_(\w+)>:$", l)
        if m:
            cur = m.group(1) if m.group(1) in FUNCS else None
            continue
        if cur and re.match(r"^[0-9a-f]+ <", l):
            cur = None
        if cur:
            m = re.search(r"\b(movupd|addpd|subpd|mulpd|pshufd|unpcklpd|stmxcsr)\b", l)
            if m:
                out[cur][m.group(1)] += 1
    return out


def check_objcmp(direct, text):
    a, b = dis_counts(direct), dis_counts(text)
    for f in FUNCS:
        if not a[f]["addpd"] or not a[f]["mulpd"] or a[f]["stmxcsr"] != 1:
            fail(f"{direct}: pion_fn_{f} lacks packed code in the direct object: {dict(a[f])}")
        if a[f] != b[f]:
            fail(f"pion_fn_{f}: direct object {dict(a[f])} != assembled text {dict(b[f])}")
    print("p127 direct object == assembled text packed mnemonics: " +
          ", ".join(f"{f} {sum(a[f].values())}" for f in FUNCS))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "out":
        check_out(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "asm":
        check_asm(sys.argv[2], sys.argv[3])
    elif cmd == "objcmp":
        check_objcmp(sys.argv[2], sys.argv[3])
    else:
        fail(f"unknown command {cmd}")
