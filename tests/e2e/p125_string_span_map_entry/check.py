"""P125 checker: run the string-span / scalar-map-entry / file-read programs
built by run_e2e.sh and compare exit status, stdout, stderr and SSA shape."""
from pathlib import Path
import re
import signal
import subprocess
import sys

root = Path(sys.argv[1])
mode = sys.argv[2]
files = root / 'files'


def run(name, *args):
    return subprocess.run([str(root / mode / name), *args], capture_output=True)


def ssa(name):
    return (root / mode / (name + '.ssa')).read_text()


def fail(msg):
    print('FAIL [%s]: %s' % (mode, msg), file=sys.stderr)
    sys.exit(1)


# 1. Semantics, aliasing, fallbacks and owners: exact exit status and output.
for name in ('semantics', 'fallback', 'scanner', 'owners'):
    r = run(name)
    if (r.returncode, r.stdout, r.stderr) != (0, b'ok\n', b''):
        fail('%s: rc=%d stdout=%r stderr=%r' % (name, r.returncode, r.stdout, r.stderr))

# 2. Out-of-bounds slices trap at the original site after the same side effects.
for args, prefix in (((), b'1\n2\n3\n2\n'), (('first',), b'1\n7\n')):
    r = run('order', *args)
    if r.returncode != -signal.SIGABRT or r.stdout != b'':
        fail('order %r: rc=%d stdout=%r' % (args, r.returncode, r.stdout))
    pat = re.escape(prefix) + rb'pion panic at pion_rt\.c:[0-9]+: string slice out of bounds\n'
    if not re.fullmatch(pat, r.stderr):
        fail('order %r: stderr=%r' % (args, r.stderr))

# 3. Managed String file reads.
def byte_sum(data):
    t = 0
    for b in data:
        t = t * 31 % 1000003 + b
    return t


expected = []
for name in ('empty.txt', 'lines.txt', 'binary.bin', 'big.txt'):
    data = (files / name).read_bytes()
    expected.append('%s ok len=%d sum=%d bytes=same' % (name, len(data), byte_sum(data)))
expected += [
    'missing.txt err msg bytes=err',
    'abc;xy;abc;abc;xy;',
    'tally 322',
    'tally_missing -1',
]
r = run('fileread', str(files))
want = ('\n'.join(expected) + '\n').encode()
if (r.returncode, r.stdout, r.stderr) != (0, want, b''):
    fail('fileread: rc=%d\nstdout=%r\nwant  =%r\nstderr=%r' % (r.returncode, r.stdout, want, r.stderr))

# 4. SSA shape: the native primitives fire where expected and not on fallbacks.
for name, primitive in (('semantics', 'str_concat_spans'), ('semantics', 'map_scalar_entry'),
                        ('semantics', 'str_slice_data'), ('scanner', 'map_scalar_entry'),
                        ('scanner', 'strbuf_push_span'), ('owners', 'str_concat_spans'),
                        ('order', 'str_concat_spans'), ('fileread', 'str_concat_spans'),
                        ('fileread', 'map_scalar_entry')):
    if 'call $pion_' + primitive + '(' not in ssa(name):
        fail('%s.ssa lacks call $pion_%s' % (name, primitive))
fb = ssa('fallback')
if 'call $pion_map_scalar_entry(' in fb or 'call $pion_map_set(' not in fb:
    fail('fallback.ssa must keep the ordinary map lookup')
print('p125 [%s]: 6 programs, exit status / stdout / stderr / SSA OK' % mode)
