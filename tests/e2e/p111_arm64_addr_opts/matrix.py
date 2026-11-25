"""P111 matrix and object-text helpers (stdlib only).

  matrix.py gen OUT.ssa            write the imm9 (4,608) + localaddr (112) cases
  matrix.py text OBJ OUT.bin       executable section bytes of a Mach-O / ELF object
  matrix.py imm9 BIN               count negative signed-imm9 ldur/stur words
"""
import struct
import sys
from pathlib import Path

LOADS = ([('w', op) for op in ['loadub', 'loadsb', 'loaduh', 'loadsh', 'loadw']]
         + [('l', op) for op in ['loadsb', 'loadsh', 'loadsw', 'loaduw', 'loadl']]
         + [('s', 'loads'), ('d', 'loadd')])
STORES = list(zip('bhwlsd', 'wwwlsd'))


def imm9_cases():
    # Every displacement -1..-256, every load width/extension through
    # `sub p, d`, every store width through `add p, -d`.
    for d in range(1, 257):
        for k, op in LOADS:
            yield f'{k} $fN(l %p)', f'%a =l sub %p, {d}\n  %x ={k} {op} %a\n  ret %x'
        for op, k in STORES:
            yield f'$fN(l %p, {k} %x)', f'%a =l add %p, -{d}\n  store{op} %x, %a\n  ret'


def local_cases():
    # Small and large frames, first/aligned/last fields, escaping address.
    kinds = list(zip('wwlwlsd', ['loadub', 'loadsh', 'loadsw', 'loadw', 'loadl', 'loads', 'loadd']))
    for sz in [32, 260, 16384, 32784]:
        for off in [0, 4, 8, sz - 8]:
            for k, op in kinds:
                yield (f'{k} $fN()', f'%p =l alloc8 {sz}\n  call $touch(l %p)\n'
                       f'  %addr =l add %p, {off}\n  %x ={k} {op} %addr\n  ret %x')


def gen(out):
    items = list(imm9_cases()) + list(local_cases())
    assert len(items) == 4608 + 112
    Path(out).write_text(''.join(
        'export function ' + sig.replace('fN', f'f{i}') + ' {\n@start\n  ' + body + '\n}\n'
        for i, (sig, body) in enumerate(items)))


def text(path):
    b = Path(path).read_bytes()
    if b[:4] == b'\x7fELF':
        shoff = struct.unpack_from('<Q', b, 40)[0]
        shentsize, shnum = struct.unpack_from('<HH', b, 58)
        parts = []
        for j in range(shnum):
            _, typ, flags, _, off, size = struct.unpack_from('<IIQQQQ', b, shoff + shentsize * j)
            if typ == 1 and flags & 4:  # SHT_PROGBITS, SHF_EXECINSTR
                parts.append(b[off:off + size])
        out = b''.join(parts)
        assert out, path
        return out
    assert b[:4] == bytes.fromhex('cffaedfe'), path
    p = 32
    for _ in range(struct.unpack_from('<I', b, 16)[0]):
        cmd, length = struct.unpack_from('<II', b, p)
        if cmd == 0x19:  # LC_SEGMENT_64
            for j in range(struct.unpack_from('<I', b, p + 64)[0]):
                s = p + 72 + j * 80
                if b[s:s + 16].rstrip(b'\0') == b'__text':
                    size, off = struct.unpack_from('<QI', b, s + 40)
                    return b[off:off + size]
        p += length
    raise SystemExit(f'no __text in {path}')


def imm9(path):
    words = [w for (w,) in struct.iter_unpack('<I', Path(path).read_bytes())]
    # LDUR/STUR (GPR and FP/SIMD): size 111 V 00 opc 0 imm9 00 Rn Rt.
    return sum((w & 0x3b200c00) == 0x38000000 and ((w >> 12) & 0x1ff) >= 256 for w in words)


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'gen':
        gen(sys.argv[2])
    elif cmd == 'text':
        Path(sys.argv[3]).write_bytes(text(sys.argv[2]))
    elif cmd == 'imm9':
        print(imm9(sys.argv[2]))
    else:
        raise SystemExit(__doc__)
