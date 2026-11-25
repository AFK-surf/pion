#!/usr/bin/env python3
"""Write main_<m>.c: vendor/qbe/main.c with one replicatedispatch condition
removed (usage: mk_mutants.py main.c outdir). Each mutant must make exactly
the control function of gen_il.py that targets this condition get copies."""
import sys

src, out = sys.argv[1:3]
s = open(src).read()
MUT = {
    'len': ('\tif (b->nins > 16)\n\t\treturn 0;', '\tif (0)\n\t\treturn 0;'),
    'call': ('b->ins[j].op == Ocall || ', ''),
    'big': ('t->njtbl <= MaxTable && ', ''),
    'shared': ('t->npred == 1', '1'),
    'npred': ('head->npred < 3', 'head->npred < 2'),
    'loop': ('head->loop <= 1 || ', ''),
    'sites23': ('MaxSites = 24', 'MaxSites = 23'),
    'sites25': ('MaxSites = 24', 'MaxSites = 25'),
}
for name, (a, b) in MUT.items():
    if s.count(a) != 1:
        raise SystemExit(f'FAIL: p122 mutant {name}: {a!r} found {s.count(a)} times in {src}')
    open(f'{out}/main_{name}.c', 'w').write(s.replace(a, b))
print(' '.join(MUT))
