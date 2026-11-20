"""Source-size metrics shared by the agent_eval harness (stdlib only)."""
import os
import re

CODE_EXT = {".pion": "pion", ".mbt": "moonbit", ".rs": "rust", ".go": "go", ".c": "c"}

# One alternation, scanned left to right, so `//` inside a string literal is
# never mistaken for a comment.
_TOKEN_RE = re.compile(
    r"""
    (?P<comment>//[^\n]*|/\*.*?\*/)
  | (?P<string>"(?:\\.|[^"\\\n])*"|`[^`]*`)
  | (?P<char>b?'(?:\\.|[^'\\\n])+')
  | (?P<number>0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?[A-Za-z]*)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>->|=>|::|==|!=|<=|>=|&&|\|\||:=|\.\.=?|<<|>>|\+=|-=|\*=|/=|%=|\?\.|[^\sA-Za-z0-9_])
  | (?P<ws>\s+)
    """,
    re.VERBOSE | re.DOTALL,
)


def lex_tokens(text):
    """Number of lexical tokens (identifiers, literals, operators), comments and whitespace excluded."""
    n = 0
    pos = 0
    while pos < len(text):
        m = _TOKEN_RE.match(text, pos)
        if m is None:  # unreachable in practice; count a stray byte as a token
            n += 1
            pos += 1
            continue
        kind = m.lastgroup
        if kind not in ("comment", "ws"):
            n += 1
        pos = m.end()
    return n


def effective_loc(text):
    """Non-blank lines that are not pure `//` comments (block comments are rare here and counted)."""
    loc = 0
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        loc += 1
    return loc


def source_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in ("_build", "target", ".mooncakes"))
        for f in sorted(filenames):
            ext = os.path.splitext(f)[1]
            if ext in CODE_EXT:
                out.append(os.path.join(dirpath, f))
    return out


def measure_dir(root):
    files = source_files(root)
    loc = 0
    nbytes = 0
    toks = 0
    for p in files:
        with open(p, "r", encoding="utf-8") as fh:
            t = fh.read()
        loc += effective_loc(t)
        nbytes += len(t.encode("utf-8"))
        toks += lex_tokens(t)
    return {
        "files": len(files),
        "loc": loc,
        "bytes": nbytes,
        "est_tokens_bytes_div4": (nbytes + 3) // 4,
        "lex_tokens": toks,
    }
