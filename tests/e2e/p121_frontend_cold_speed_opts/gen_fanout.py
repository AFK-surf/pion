#!/usr/bin/env python3
"""P121 generators (stdlib only, deterministic).

fanout <dir>: high fan-out `mut` callable slots. `go()` keeps M local callables
and passes each of them to the same 3 installers `install_k(mut f)` in every
one of R rounds (later rounds in reverse order), so (R - 1) / R of the calls
repeat a `#fmutlink` row that `slot_mut_seen` has already seen. A callback
closure reads all of them (shared `$cslot_`). Writes a.pion / b.pion /
expect.txt and links.txt (the rows in first-occurrence order).

cslots <dir> <kind> <n>: a `kind` loop (while, while_is, cfor, range, for_in)
rotating n + 1 container-holding `mut` locals by one per run; the `[read_b]`
cslot moves one local per dependency pass, so the fixed point needs n + 1
passes (n >= 63 exhausts the 64-pass budget: fallback). Same shape as
`ott_cslot_chain_src` in compiler/src/core/frontend_test.pion, which checks
the resulting plans. Writes a.pion / b.pion / expect.txt.

rotate <dir> <n>: a `while` loop rotating n + 1 plain callable locals; the
fixed point converges after one pass (the analysis keeps slot references),
but the loop edge carries n + 1 live values: n >= 64 puts more than 64 copies
in one QBE parallel move (vendor/qbe/rega.c). Writes a.pion / b.pion /
expect.txt.
"""
import os
import sys


def fanout(out):
    k_inst, m_locals, rounds = 12, 16, 4
    b_val, c_val = 5, 7
    lines = [
        "fn zero() -> Int { 0 }",
        "fn read_b() -> Int { B }",
        "fn read_c() -> Int { C }",
        "fn make_b() -> Int { %d }" % b_val,
        "fn make_c() -> Int { %d }" % c_val,
    ]
    for k in range(k_inst):
        tgt = "read_b" if k % 2 == 0 else "read_c"
        lines.append("fn install_%d(mut f : () -> Int) -> Unit { f = %s }" % (k, tgt))
    lines.append("fn go() -> Int {")
    for j in range(m_locals):
        lines.append("  let mut f%d = zero" % j)
    final = {}
    links = []
    for r in range(rounds):
        order = range(3) if r % 2 == 0 else range(2, -1, -1)
        for j in range(m_locals):
            for d in order:
                k = (j * 5 + d) % k_inst
                lines.append("  install_%d(mut f%d)" % (k, j))
                final[j] = b_val if k % 2 == 0 else c_val
                row = "#fmutlink $slot_fn_go_%d|install_%d|0" % (j, k)
                if row not in links:
                    links.append(row)
    lines.append("  let cb = fn() -> Int { " + " + ".join("f%d()" % j for j in range(m_locals)) + " }")
    lines.append("  cb() * 1000 + " + " + ".join("f%d()" % j for j in range(m_locals)))
    lines.append("}")
    lines.append("let B : Int = make_b()")
    lines.append("let C : Int = make_c()")
    total = sum(final.values())
    expect = total * 1000 + total
    with open(os.path.join(out, "b.pion"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "a.pion"), "w") as f:
        f.write("let A : Int = go()\n")
        f.write("pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }\n")
    with open(os.path.join(out, "expect.txt"), "w") as f:
        f.write("%d\n" % expect)
    with open(os.path.join(out, "links.txt"), "w") as f:
        f.write("\n".join(links) + "\n")


def cslots(out, kind, n):
    lines = [
        "fn zero() -> Int { 0 }",
        "fn read_b() -> Int { B }",
        "fn read_c() -> Int { C }",
        "fn make_b() -> Int { 11 }",
        "fn make_c() -> Int { 13 }",
        "fn go() -> Int {",
        "  let other = [read_c]",
    ]
    for j in range(n + 1):
        lines.append("  let mut a%d = [zero]" % j)
    shift = "".join("a%d = a%d; " % (j, j - 1) for j in range(n, 0, -1)) + "a0 = [read_b]"
    runs = n + 1
    if kind == "while":
        lines += ["  let mut i = 0", "  while i < %d { %s; i = i + 1 }" % (runs, shift)]
    elif kind == "while_is":
        lines += [
            "  let mut it : Option[Int] = Some(%d)" % runs,
            "  while it is Some(m) { %s; it = if m > 1 { Some(m - 1) } else { None } }" % shift,
        ]
    elif kind == "cfor":
        lines += ["  for i = 0; i < %d; i = i + 1 { %s }" % (runs, shift)]
    elif kind == "range":
        lines += ["  for i in 0..<%d { %s }" % (runs, shift)]
    elif kind == "for_in":
        lines += [
            "  let xs : Array[Int] = []",
            "  let mut q = 0",
            "  while q < %d { xs.push(q); q = q + 1 }" % runs,
            "  for x in xs { %s }" % shift,
        ]
    else:
        sys.exit("unknown loop kind " + kind)
    lines += ["  let f = a%d[0]" % n, "  f() + 0 * other.length()", "}"]
    with open(os.path.join(out, "b.pion"), "w") as f:
        f.write("\n".join(lines + ["let B : Int = make_b()", "let C : Int = make_c()"]) + "\n")
    with open(os.path.join(out, "a.pion"), "w") as f:
        f.write("let A : Int = go()\n")
        f.write("pub fn main(world : World) -> Unit { io_println(world, A.to_string() + \",\" + C.to_string()) }\n")
    with open(os.path.join(out, "expect.txt"), "w") as f:
        f.write("11,13\n")


def rotate(out, n):
    b_val = 11
    lines = [
        "fn zero() -> Int { 0 }",
        "fn read_b() -> Int { B }",
        "fn make_b() -> Int { %d }" % b_val,
        "fn go() -> Int {",
    ]
    for j in range(n + 1):
        lines.append("  let mut f%d = zero" % j)
    lines.append("  let mut i = 0")
    shift = " ".join("f%d = f%d;" % (j, j - 1) for j in range(n, 0, -1))
    lines.append("  while i < %d { %s f0 = read_b; i = i + 1 }" % (n + 1, shift))
    lines.append("  f%d()" % n)
    lines.append("}")
    lines.append("let B : Int = make_b()")
    with open(os.path.join(out, "b.pion"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "a.pion"), "w") as f:
        f.write("let A : Int = go()\n")
        f.write("pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }\n")
    with open(os.path.join(out, "expect.txt"), "w") as f:
        f.write("%d\n" % b_val)


if __name__ == "__main__":
    mode, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    if mode == "fanout":
        fanout(out)
    elif mode == "cslots":
        cslots(out, sys.argv[3], int(sys.argv[4]))
    elif mode == "rotate":
        rotate(out, int(sys.argv[3]))
    else:
        sys.exit("unknown mode " + mode)
