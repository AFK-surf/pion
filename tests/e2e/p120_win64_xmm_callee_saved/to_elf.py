"""Rewrite `qbe -t amd64_win` text so a non-PE (ELF) GNU assembler takes it:
only the COFF section directives change (`.section .text$NAME,"xr"` becomes
`.section .text.NAME,"ax",@progbits`, `.linkonce` and the `.seh_*` unwind
directives go); every instruction line is copied unchanged.

usage: python3 -E to_elf.py IN.s OUT.s
"""
import re
import sys

out = []
for line in open(sys.argv[1]):
    m = re.match(r'\.section \.(text|data|bss)\$([^,]+),"(\w+)"\s*$', line)
    if m:
        kind, name, _ = m.groups()
        flags = {'text': '"ax",@progbits', 'data': '"aw",@progbits',
                 'bss': '"aw",@nobits'}[kind]
        out.append(f'.section .{kind}.{name},{flags}\n')
    elif line.startswith('.linkonce') or line.lstrip().startswith('.seh_'):
        continue
    else:
        out.append(line)
out.append('.section .note.GNU-stack,"",@progbits\n')
open(sys.argv[2], 'w').write(''.join(out))
