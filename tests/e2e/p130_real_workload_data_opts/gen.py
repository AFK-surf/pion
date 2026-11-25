"""P130 program generator.

usage: python3 -E gen.py OUT_DIR

Writes four deterministic Pion programs and their reference outputs (computed
here, independently of the compiler) into OUT_DIR:

  strings.pion  long string literals: Base64, quotes, backslashes, `$`, `#`,
                `,`, tabs, NUL, CR/LF escapes and multibyte UTF-8;
  ints.pion     1,024+ element Array / FixedArray / ImmArray[Int] literals
                (0, positive, negative, -2147483648, 2147483647, hex,
                underscores), fresh mutable copies per call, and a 1,100
                element literal with side-effecting elements;
  records.pion  128+ row tables of 2- and 3-field all-String records with
                cross-row shared strings, plus dynamic-field, reordered-field
                and single-row tables;
  sparse.pion   a 2,048 word table that is mostly zero (sparse Wasm32 data).

Also writes sparse.table (the little-endian image of the sparse table) and
strings.base64 (the Base64 literal) for check.py.
"""
import base64
import os
import sys

OUT = sys.argv[1]
MOD = 1000000007


def cmod(a, b):
    r = abs(a) % b
    return -r if a < 0 else r


def checksum(xs):
    h = 0
    for x in xs:
        h = cmod(h * 31 + x, MOD)
    return h


def write(name, text):
    with open(os.path.join(OUT, name), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def pion_str(s):
    out = []
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\0':
            out.append('\\0')
        else:
            out.append(ch)
    return '"' + ''.join(out) + '"'


# ---------------------------------------------------------------- strings
B64 = base64.b64encode(bytes((i * 37 + 11) % 256 for i in range(3072))).decode()
MIXED = ''.join(
    'row %d: "quoted" \\back\\slash $dollar #hash, comma\ttab é中文\U0001F680 %s\n'
    % (i, 'x' * (i % 7)) for i in range(40))
ESCAPED = 'nul\0inside\r\nCRLF ' + '{"k":"v\\n","n":[1,2,3]} ' * 30
STRINGS = [B64, MIXED, ESCAPED, 'ab', 'a', '']
src = ['// Long string literals reach static data as quoted byte runs.']
for i, s in enumerate(STRINGS):
    src.append('fn s%d() -> String {\n  %s\n}\n' % (i, pion_str(s)))
src.append('fn main(world : World) -> Int {')
for i in range(len(STRINGS)):
    src.append('  io_println(world, "[" + s%d() + "]")' % i)
src.append('  0\n}\n')
write('strings.pion', '\n'.join(src))
write('strings.expected', ''.join('[' + s + ']\n' for s in STRINGS))
write('strings.base64', B64)

# ---------------------------------------------------------------- ints
SPECIAL = [(0, '0'), (1, '1'), (-1, '-1'), (2147483647, '2147483647'),
           (-2147483648, '-2147483648'), (2147483647, '0x7fff_ffff'),
           (-2147483647, '-0x7FFF_FFFF'), (1000000, '1_000_000'),
           (-1000000, '-1_000_000'), (255, '0xFF'), (-16, '-0x10'), (0, '0x0')]


def int_values(n, seed):
    vals = list(SPECIAL)
    i = 0
    while len(vals) < n:
        v = (i * 7919 + seed) % 200003 - 100000
        vals.append((v, str(v)))
        i += 1
    return vals


ARR = int_values(1100, 1)
FIX = int_values(1030, 2)
IMM = int_values(1024, 3)


def lit(vals):
    lines = []
    for k in range(0, len(vals), 16):
        lines.append('    ' + ', '.join(t for _, t in vals[k:k + 16]) + ',')
    return '\n'.join(lines)


DYN = [(i * 13) % 977 - 400 for i in range(1100)]
DYN_TICKS = {0: 1, 517: 2, 1099: 3}


def dyn_lit():
    items = []
    for i, v in enumerate(DYN):
        items.append('tick(log, %d)' % DYN_TICKS[i] if i in DYN_TICKS else str(v))
    return '\n'.join('    ' + ', '.join(items[k:k + 16]) + ',' for k in range(0, len(items), 16))


src = '''// 1,024+ element Int literal arrays are copied from a private word table.
fn make_array() -> Array[Int] {
  let a : Array[Int] = [
%s
  ]
  a
}

fn make_fixed() -> FixedArray[Int] {
  [
%s
  ]
}

fn make_imm() -> ImmArray[Int] {
  let a : ImmArray[Int] = [
%s
  ]
  a
}

fn tick(log : Array[Int], v : Int) -> Int {
  log.push(v)
  v * 1000
}

// Elements with side effects keep element-by-element evaluation in order.
fn dyn_array(log : Array[Int]) -> Array[Int] {
  let a : Array[Int] = [
%s
  ]
  a
}

fn sum_array(xs : Array[Int]) -> Int64 {
  let mut h = 0L
  let mut i = 0
  while i < xs.length() {
    h = (h * 31L + xs[i].to_int64()) %% 1000000007L
    i = i + 1
  }
  h
}

fn sum_fixed(xs : FixedArray[Int]) -> Int64 {
  let mut h = 0L
  let mut i = 0
  while i < xs.length() {
    h = (h * 31L + xs[i].to_int64()) %% 1000000007L
    i = i + 1
  }
  h
}

fn sum_imm(xs : ImmArray[Int]) -> Int64 {
  let mut h = 0L
  let mut i = 0
  while i < xs.length() {
    h = (h * 31L + xs[i].to_int64()) %% 1000000007L
    i = i + 1
  }
  h
}

fn main(world : World) -> Int {
  let a1 = make_array()
  let a2 = make_array()
  a1[0] = 99
  a1[1099] = -5
  a1.push(7)
  io_println(world, "array " + a1.length().to_string() + " " + a2.length().to_string() + " " + a1[0].to_string() + " " + a2[0].to_string() + " " + a2[1099].to_string())
  io_println(world, "array edges " + a2[3].to_string() + " " + a2[4].to_string() + " " + a2[6].to_string() + " " + a2[10].to_string())
  io_println(world, "array sums " + sum_array(a1).to_string() + " " + sum_array(a2).to_string())
  let f1 = make_fixed()
  let f2 = make_fixed()
  f1[5] = -7
  io_println(world, "fixed " + f1.length().to_string() + " " + f1[5].to_string() + " " + f2[5].to_string() + " " + sum_fixed(f1).to_string() + " " + sum_fixed(f2).to_string())
  let m = make_imm()
  io_println(world, "imm " + m.length().to_string() + " " + m[4].to_string() + " " + m[1023].to_string() + " " + sum_imm(m).to_string())
  let log : Array[Int] = []
  let d = dyn_array(log)
  io_println(world, "dyn " + log.length().to_string() + " " + log[0].to_string() + log[1].to_string() + log[2].to_string() + " " + d[0].to_string() + " " + d[517].to_string() + " " + d[1099].to_string() + " " + sum_array(d).to_string())
  0
}
''' % (lit(ARR), lit(FIX), lit(IMM), dyn_lit())
write('ints.pion', src)
a2 = [v for v, _ in ARR]
a1 = list(a2)
a1[0] = 99
a1[1099] = -5
a1.append(7)
f2 = [v for v, _ in FIX]
f1 = list(f2)
f1[5] = -7
m = [v for v, _ in IMM]
d = list(DYN)
for i, t in DYN_TICKS.items():
    d[i] = t * 1000
exp = [
    'array %d %d %d %d %d' % (len(a1), len(a2), a1[0], a2[0], a2[1099]),
    'array edges %d %d %d %d' % (a2[3], a2[4], a2[6], a2[10]),
    'array sums %d %d' % (checksum(a1), checksum(a2)),
    'fixed %d %d %d %d %d' % (len(f1), f1[5], f2[5], checksum(f1), checksum(f2)),
    'imm %d %d %d %d' % (len(m), m[4], m[1023], checksum(m)),
    'dyn 3 123 %d %d %d %d' % (d[0], d[517], d[1099], checksum(d)),
]
write('ints.expected', '\n'.join(exp) + '\n')

# ---------------------------------------------------------------- records
SHARED = ['&', '<', '>', '"', ' ', 'é', '—', '\U0001D504']
ENT = [('amp', '&'), ('lt', '<'), ('gt', '>'), ('quot', '"')]
for i in range(len(ENT), 140):
    ENT.append(('ent%d' % i, SHARED[i % len(SHARED)] if i % 3 else 'U+%04X\\' % (i * 97)))
TRI = [('k%d' % i, SHARED[i % 5], 'v%d' % (i % 11)) for i in range(130)]


def rows(name, fields, data):
    out = []
    for row in data:
        out.append('    %s::{ %s },' % (name, ', '.join(
            '%s: %s' % (f, pion_str(v)) for f, v in zip(fields, row))))
    return '\n'.join(out)


src = '''// Tables of all-String records are stored straight into the array slots.
struct Entity {
  name : String
  chars : String
}

struct Triple {
  a : String
  b : String
  c : String
}

fn entities() -> Array[Entity] {
  [
%s
  ]
}

fn triples() -> Array[Triple] {
  [
%s
  ]
}

// Fallbacks: a dynamic field, reordered fields, a single row.
fn dyn_rows(s : String) -> Array[Entity] {
  [Entity::{ name: s, chars: "dyn" }, Entity::{ name: "fixed", chars: s }]
}

fn reordered_rows() -> Array[Entity] {
  [Entity::{ chars: "c1", name: "n1" }, Entity::{ name: "n2", chars: "c2" }]
}

fn single_row() -> Array[Entity] {
  [Entity::{ name: "only", chars: "one" }]
}

// The row outlives the array it was read from.
fn pick(i : Int) -> Entity {
  let t = entities()
  t[i]
}

fn main(world : World) -> Int {
  let es = entities()
  let again = entities()
  let mut i = 0
  while i < es.length() {
    io_println(world, es[i].name + "=" + es[i].chars)
    i = i + 1
  }
  let ts = triples()
  let mut j = 0
  while j < ts.length() {
    io_println(world, ts[j].a + "|" + ts[j].b + "|" + ts[j].c)
    j = j + 1
  }
  let p = pick(7)
  let q = pick(15)
  io_println(world, "pick " + p.name + "=" + p.chars + " " + q.name + "=" + q.chars + " " + again.length().to_string())
  let dr = dyn_rows("x" + "y")
  io_println(world, "dyn " + dr[0].name + " " + dr[0].chars + " " + dr[1].name + " " + dr[1].chars)
  let rr = reordered_rows()
  io_println(world, "reordered " + rr[0].name + " " + rr[0].chars + " " + rr[1].name + " " + rr[1].chars)
  let sr = single_row()
  io_println(world, "single " + sr.length().to_string() + " " + sr[0].name + " " + sr[0].chars)
  0
}
''' % (rows('Entity', ['name', 'chars'], ENT), rows('Triple', ['a', 'b', 'c'], TRI))
write('records.pion', src)
exp = ['%s=%s' % r for r in ENT] + ['%s|%s|%s' % r for r in TRI]
exp.append('pick %s=%s %s=%s 140' % (ENT[7] + ENT[15]))
exp.append('dyn xy dyn fixed xy')
exp.append('reordered n1 c1 n2 c2')
exp.append('single 1 only one')
write('records.expected', '\n'.join(exp) + '\n')

# ---------------------------------------------------------------- sparse
SPARSE = {0: 0x11223344, 100: 0x55667788, 101: 9, 1000: 7, 1500: -2, 2047: 0x0A0B0C0D}
words = [SPARSE.get(i, 0) for i in range(2048)]
items = [str(w) for w in words]
src = '''// A mostly-zero table: its Wasm32 data needs only a few active segments.
fn table() -> Array[Int] {
  let a : Array[Int] = [
%s
  ]
  a
}

fn main(world : World) -> Int {
  let t = table()
  let mut s = 0L
  let mut nz = 0
  let mut i = 0
  while i < t.length() {
    s = s + t[i].to_int64()
    if t[i] != 0 {
      nz = nz + 1
    }
    i = i + 1
  }
  io_println(world, "sparse-marker " + t.length().to_string() + " " + nz.to_string() + " " + s.to_string() + " " + t[100].to_string() + " " + t[2047].to_string())
  0
}
''' % '\n'.join('    ' + ', '.join(items[k:k + 32]) + ',' for k in range(0, len(items), 32))
write('sparse.pion', src)
write('sparse.expected', 'sparse-marker 2048 %d %d %d %d\n' % (
    sum(1 for w in words if w), sum(words), words[100], words[2047]))
with open(os.path.join(OUT, 'sparse.table'), 'wb') as f:
    f.write(b''.join((w & 0xFFFFFFFF).to_bytes(4, 'little') for w in words))
