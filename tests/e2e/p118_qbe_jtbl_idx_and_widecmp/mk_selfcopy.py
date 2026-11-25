"""usage: python3 -E mk_selfcopy.py OUT_DIR

Writes selfcopy.s (text: `addl $64, %eax; cmpl $8, %eax`, then the dispatch)
and minimal ELF64 objects:
  selfcopy_ok.o    the same instructions;
  selfcopy_bad.o   `movl %eax, %eax` before the compare, after an immediate that
                   looks like a REX prefix;
  selfcopy_gap.o   the same with a store of %rax between it and the compare;
  bad_entry.o / bad_jae.o / bad_lea.o   selfcopy_ok.o with the first table entry,
                   the `jae` or the `lea` displacement one too large;
plus selfcopy_expect.txt. wide.s / wide_ok.o / wide_expect.txt are the same
dispatch with 128 entries, wide_bad.o compares with `83 f8 80` ($-128).
"""
import struct
import sys
from pathlib import Path

NAME = 'selfcopy'


def text(n):
    table = '\t.long .Lbb1 - .Ljt0\n' * n
    return f'''.text
{NAME}:
\taddl $64, %eax
\tcmpl ${n}, %eax
\tjae .Lbb1
\tleaq .Ljt0(%rip), %r11
\tmovslq (%r11,%rax,4), %r10
\taddq %r10, %r11
\tjmpq *%r11
\t.balign 4
.Ljt0:
{table}.Lbb1:
\tret
/* end function {NAME} */
'''


def code(before=b'', n=8, compare=b'\x83\xf8\x08', jae_off=0, lea_off=0, entry_off=0):
    c = b'\x83\xc0\x40' + before + compare
    jae, lea = len(c) + 6, len(c) + 13
    end = lea + 10  # movslq, addq, jmpq
    table = (end + 3) & ~3
    ret = table + 4 * n
    c += b'\x0f\x83' + struct.pack('<i', ret - jae + jae_off)
    c += b'\x4c\x8d\x1d' + struct.pack('<i', table - lea + lea_off)
    c += b'\x4d\x63\x14\x83\x4d\x01\xd3\x41\xff\xe3'
    rel = ret - table
    return c.ljust(table, b'\0') + struct.pack(f'<{n}i', rel + entry_off, *[rel] * (n - 1)) + b'\xc3'


def elf(text):
    strtab = b'\0' + NAME.encode() + b'\0'
    shstr = b'\0.text\0.symtab\0.strtab\0.shstrtab\0'
    symtab = bytes(24) + struct.pack('<IBBHQQ', 1, 0x12, 0, 1, 0, len(text))
    body, at = b'', []
    for part in (text, symtab, strtab, shstr):
        body = body.ljust(-(-len(body) // 16) * 16, b'\0')
        at.append((64 + len(body), len(part)))
        body += part
    body = body.ljust(-(-len(body) // 16) * 16, b'\0')
    sh = lambda n, t, f, k, link, info, al, es: struct.pack('<IIQQQQIIQQ', shstr.index(n), t, f, 0, *at[k], link, info, al, es)
    secs = bytes(64) + sh(b'.text', 1, 6, 0, 0, 0, 16, 0) + sh(b'.symtab', 2, 0, 1, 3, 1, 8, 24) \
        + sh(b'.strtab', 3, 0, 2, 0, 0, 1, 0) + sh(b'.shstrtab', 3, 0, 3, 0, 0, 1, 0)
    head = b'\x7fELF\x02\x01\x01' + bytes(9) + struct.pack('<HHIQQQIHHHHHH', 1, 62, 1, 0, 0, 64 + len(body), 0, 64, 0, 0, 64, 5, 4)
    return head + body + secs


out = Path(sys.argv[1])
COPY = b'\x89\xc0'
WIDE = b'\x3d' + struct.pack('<I', 128)
(out / 'selfcopy.s').write_text(text(8))
(out / 'wide.s').write_text(text(128))
(out / 'selfcopy_expect.txt').write_text(f'{NAME} live 8\n')
(out / 'wide_expect.txt').write_text(f'{NAME} live 128\n')
for name, body in (
        ('selfcopy_ok', code()),
        ('selfcopy_bad', code(COPY)),
        ('selfcopy_gap', code(COPY + b'\x48\x89\x06')),  # movq %rax, (%rsi)
        ('bad_entry', code(entry_off=1)),
        ('bad_jae', code(jae_off=1)),
        ('bad_lea', code(lea_off=1)),
        ('wide_ok', code(n=128, compare=WIDE)),
        ('wide_bad', code(n=128, compare=b'\x83\xf8\x80'))):
    (out / f'{name}.o').write_bytes(elf(body))
