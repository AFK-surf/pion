"""usage: python3 -E mk_selfcopy.py OUT_DIR

Writes selfcopy.s (text: `addl $64, %eax; cmpl $8, %eax`, then the dispatch),
selfcopy_ok.o (the same instructions) and selfcopy_bad.o (with `movl %eax, %eax`
before the compare, after an immediate that looks like a REX prefix) as minimal
ELF64 objects, plus selfcopy_expect.txt.
"""
import struct
import sys
from pathlib import Path

NAME = 'selfcopy'
TEXT = f'''.text
{NAME}:
\taddl $64, %eax
\tcmpl $8, %eax
\tjae .Lbb1
\tleaq .Ljt0(%rip), %r11
\tmovslq (%r11,%rax,4), %r10
\taddq %r10, %r11
\tjmpq *%r11
.Lbb1:
\tret
/* end function {NAME} */
'''


def code(selfcopy):
    c = b'\x83\xc0\x40' + (b'\x89\xc0' if selfcopy else b'') + b'\x83\xf8\x08'
    jae, lea = len(c) + 6, len(c) + 13
    end = lea + 10  # movslq, addq, jmpq
    table = (end + 3) & ~3
    ret = table + 32
    c += b'\x0f\x83' + struct.pack('<i', ret - jae)
    c += b'\x4c\x8d\x1d' + struct.pack('<i', table - lea)
    c += b'\x4d\x63\x14\x83\x4d\x01\xd3\x41\xff\xe3'
    return c.ljust(table, b'\0') + struct.pack('<i', ret - table) * 8 + b'\xc3'


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
(out / 'selfcopy.s').write_text(TEXT)
(out / 'selfcopy_ok.o').write_bytes(elf(code(False)))
(out / 'selfcopy_bad.o').write_bytes(elf(code(True)))
(out / 'selfcopy_expect.txt').write_text(f'{NAME} live 8\n')
