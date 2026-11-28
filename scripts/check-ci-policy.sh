#!/bin/sh
# Static CI policy linter for Pion ecosystem GitHub Actions workflows.
# Zero external dependencies (POSIX sh + Python 3 standard library; no PyYAML).
#
# Usage:
#   sh scripts/check-ci-policy.sh [--default-branch <name>] [--allow-legacy-shard <workflow>:<job>=<max_total>]... [--allow-notarize-timeout <workflow>:<job>]... [repo_root]
#   sh scripts/check-ci-policy.sh --self-test
set -eu

exec python3 - "$@" <<'PYEOF'
import os
import re
import subprocess
import sys
import tempfile

FORBIDDEN_MATRIX_KEYS = frozenset({"shard", "shards", "chunk", "split", "part", "batch"})
FORBIDDEN_JOB_SUFFIX_RE = re.compile(r"-(?:shard|part|split)-?\d+$", re.IGNORECASE)
PION_REF_RE = re.compile(r"\b(?:pion|pionc|PION_CACHE_DIR)\b")
TIMEOUT_EXPR_RE = re.compile(r"^\$\{\{(.*)\}\}$", re.DOTALL)
TIMEOUT_FALLBACK_3_END_RE = re.compile(r"^(.+?)\s*\|\|\s*3$")
TIMEOUT_COND_AND_N_RE = re.compile(r"^(.+?)\s+&&\s+([1-9]\d*)$")
SAFE_RELEASE_ATOM_RES = (
    re.compile(r"^startsWith\(\s*github\.ref\s*,\s*['\"]refs/tags/['\"]\s*\)$"),
    re.compile(r"^github\.ref_type\s*==\s*['\"]tag['\"]$"),
    re.compile(r"^github\.event_name\s*==\s*['\"]workflow_dispatch['\"]$"),
)
END_TEST_WAIT_RE = re.compile(
    r"^\s*(?:\[\[.*?\]\]|\[[^\]]*\]|test\s+.+?)\s*&&\s*wait(?:\s|$)"
)
BLOCK_SCALAR_HDR_RE = re.compile(r"^([|>])([+-]?\d*|\d*[+-]?)$")


# ---------------------------------------------------------------------------
# Pure Python stdlib recursive-descent YAML subset parser
# Supports: block mappings, block sequences (including same-indent sequences
# under mapping keys), multiline flow mappings/sequences, single/double quoted
# and plain scalars, literal (|) and folded (>) block scalars with chomping
# indicators, and comment stripping outside quotes/block scalars.
# ---------------------------------------------------------------------------

class YamlParseError(Exception):
    pass


def strip_yaml_comment(text: str) -> str:
    """Strip an unquoted YAML comment (# at start or preceded by whitespace)."""
    in_single = False
    in_double = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "'" and not in_double:
            if in_single and i + 1 < n and text[i + 1] == "'":
                i += 2
                continue
            in_single = not in_single
        elif ch == '"' and not in_single:
            if in_double and ch == '"':
                # count preceding backslashes
                bs = 0
                j = i - 1
                while j >= 0 and text[j] == "\\":
                    bs += 1
                    j -= 1
                if bs % 2 == 0:
                    in_double = False
            else:
                in_double = True
        elif ch == "#" and not in_single and not in_double:
            if i == 0 or text[i - 1].isspace():
                return text[:i].rstrip()
        i += 1
    return text.rstrip()


def decode_double_quoted(inner: str) -> str:
    out = []
    i = 0
    n = len(inner)
    escapes = {
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "\\": "\\",
        '"': '"',
        "/": "/",
        "0": "\0",
        " ": " ",
    }
    while i < n:
        ch = inner[i]
        if ch == "\\" and i + 1 < n:
            nxt = inner[i + 1]
            if nxt in escapes:
                out.append(escapes[nxt])
                i += 2
                continue
            if nxt == "x" and i + 3 < n:
                try:
                    out.append(chr(int(inner[i + 2 : i + 4], 16)))
                    i += 4
                    continue
                except ValueError:
                    pass
            if nxt == "u" and i + 5 < n:
                try:
                    out.append(chr(int(inner[i + 2 : i + 6], 16)))
                    i += 6
                    continue
                except ValueError:
                    pass
            out.append(nxt)
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def decode_scalar(raw: str):
    s = raw.strip()
    if s == "" or s in ("null", "Null", "NULL", "~"):
        return None
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return decode_double_quoted(s[1:-1])
    return s


def find_mapping_colon(text: str) -> int:
    """Return index of ':' that separates key and value in a block mapping line, or -1."""
    in_single = False
    in_double = False
    flow_depth = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "'" and not in_double:
            if in_single and i + 1 < n and text[i + 1] == "'":
                i += 2
                continue
            in_single = not in_single
        elif ch == '"' and not in_single:
            if in_double:
                bs = 0
                j = i - 1
                while j >= 0 and text[j] == "\\":
                    bs += 1
                    j -= 1
                if bs % 2 == 0:
                    in_double = False
            else:
                in_double = True
        elif not in_single and not in_double:
            if ch in "[{":
                flow_depth += 1
            elif ch in "]}":
                flow_depth = max(0, flow_depth - 1)
            elif ch == ":" and flow_depth == 0:
                if i + 1 == n or text[i + 1].isspace():
                    return i
            elif ch == "#" and (i == 0 or text[i - 1].isspace()):
                return -1
        i += 1
    return -1


class FlowParser:
    """Recursive-descent parser for YAML flow collections ({...} and [...])."""

    def __init__(self, text: str):
        self.text = text
        self.n = len(text)
        self.pos = 0

    def skip_ws_and_comments(self):
        while self.pos < self.n:
            ch = self.text[self.pos]
            if ch in " \t\r\n":
                self.pos += 1
            elif ch == "#":
                while self.pos < self.n and self.text[self.pos] != "\n":
                    self.pos += 1
            else:
                break

    def parse(self):
        self.skip_ws_and_comments()
        val = self.parse_value()
        self.skip_ws_and_comments()
        if self.pos != self.n:
            raise YamlParseError(f"unexpected trailing flow token at pos {self.pos}: {self.text[self.pos:]!r}")
        return val

    def parse_value(self):
        self.skip_ws_and_comments()
        if self.pos >= self.n:
            return None
        ch = self.text[self.pos]
        if ch == "{":
            return self.parse_mapping()
        if ch == "[":
            return self.parse_sequence()
        if ch == "'":
            return self.parse_single_quoted()
        if ch == '"':
            return self.parse_double_quoted()
        return self.parse_plain(stop_chars=",]}")

    def parse_single_quoted(self) -> str:
        self.pos += 1  # skip opening '
        out = []
        while self.pos < self.n:
            ch = self.text[self.pos]
            if ch == "'":
                if self.pos + 1 < self.n and self.text[self.pos + 1] == "'":
                    out.append("'")
                    self.pos += 2
                else:
                    self.pos += 1
                    return "".join(out)
            else:
                out.append(ch)
                self.pos += 1
        raise YamlParseError("unterminated single-quoted string in flow collection")

    def parse_double_quoted(self) -> str:
        self.pos += 1  # skip opening "
        start = self.pos
        while self.pos < self.n:
            ch = self.text[self.pos]
            if ch == "\\":
                self.pos += 2
            elif ch == '"':
                inner = self.text[start : self.pos]
                self.pos += 1
                return decode_double_quoted(inner)
            else:
                self.pos += 1
        raise YamlParseError("unterminated double-quoted string in flow collection")

    def parse_plain(self, stop_chars: str):
        start = self.pos
        while self.pos < self.n:
            ch = self.text[self.pos]
            if ch in stop_chars:
                break
            if ch == ":" and ":" in stop_chars:
                break
            if ch == "#" and self.pos > start and self.text[self.pos - 1].isspace():
                break
            self.pos += 1
        return decode_scalar(self.text[start : self.pos].strip())

    def parse_sequence(self):
        self.pos += 1  # skip [
        items = []
        while True:
            self.skip_ws_and_comments()
            if self.pos >= self.n:
                raise YamlParseError("unterminated flow sequence '['")
            if self.text[self.pos] == "]":
                self.pos += 1
                return items
            items.append(self.parse_value())
            self.skip_ws_and_comments()
            if self.pos < self.n and self.text[self.pos] == ",":
                self.pos += 1
                continue
            if self.pos < self.n and self.text[self.pos] == "]":
                self.pos += 1
                return items
            raise YamlParseError(f"expected ',' or ']' in flow sequence at pos {self.pos}")

    def parse_mapping(self):
        self.pos += 1  # skip {
        mapping = {}
        while True:
            self.skip_ws_and_comments()
            if self.pos >= self.n:
                raise YamlParseError("unterminated flow mapping '{'")
            if self.text[self.pos] == "}":
                self.pos += 1
                return mapping
            ch = self.text[self.pos]
            if ch == "'":
                key = self.parse_single_quoted()
            elif ch == '"':
                key = self.parse_double_quoted()
            else:
                # Key stops at ':' followed by whitespace/comma/}/] or end
                start = self.pos
                while self.pos < self.n:
                    c = self.text[self.pos]
                    if c == ":" and (
                        self.pos + 1 == self.n
                        or self.text[self.pos + 1] in " \t\r\n,}]"
                    ):
                        break
                    if c in ",}":
                        break
                    self.pos += 1
                key = self.text[start : self.pos].strip()
            self.skip_ws_and_comments()
            if self.pos < self.n and self.text[self.pos] == ":":
                self.pos += 1
                self.skip_ws_and_comments()
                if self.pos < self.n and self.text[self.pos] in ",}":
                    val = None
                else:
                    val = self.parse_value()
            else:
                val = None
            mapping[str(key)] = val
            self.skip_ws_and_comments()
            if self.pos < self.n and self.text[self.pos] == ",":
                self.pos += 1
                continue
            if self.pos < self.n and self.text[self.pos] == "}":
                self.pos += 1
                return mapping
            raise YamlParseError(f"expected ',' or '}}' in flow mapping at pos {self.pos}")


def flow_balance_delta(text: str) -> int:
    """Compute net bracket depth change for a flow line (ignoring quotes & comments)."""
    in_single = False
    in_double = False
    delta = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "'" and not in_double:
            if in_single and i + 1 < n and text[i + 1] == "'":
                i += 2
                continue
            in_single = not in_single
        elif ch == '"' and not in_single:
            if in_double:
                bs = 0
                j = i - 1
                while j >= 0 and text[j] == "\\":
                    bs += 1
                    j -= 1
                if bs % 2 == 0:
                    in_double = False
            else:
                in_double = True
        elif not in_single and not in_double:
            if ch in "[{":
                delta += 1
            elif ch in "]}":
                delta -= 1
            elif ch == "#" and (i == 0 or text[i - 1].isspace()):
                break
        i += 1
    return delta


class YamlParser:
    """Recursive-descent parser for the GitHub Actions YAML subset."""

    def __init__(self, text: str):
        self.lines = text.splitlines()
        self.n = len(self.lines)
        self.idx = 0

    def skip_blank_and_comments(self):
        while self.idx < self.n:
            s = self.lines[self.idx].strip()
            if s == "" or s.startswith("#") or s in ("---", "..."):
                self.idx += 1
            else:
                break

    def peek_indent_and_text(self):
        self.skip_blank_and_comments()
        if self.idx >= self.n:
            return None, None
        raw = self.lines[self.idx]
        if "\t" in raw[: len(raw) - len(raw.lstrip(" \t"))]:
            raise YamlParseError(f"line {self.idx + 1}: tabs not allowed in indentation")
        indent = len(raw) - len(raw.lstrip(" "))
        return indent, raw[indent:]

    def parse(self):
        indent, text = self.peek_indent_and_text()
        if indent is None:
            return None
        return self.parse_block_node(indent)

    def parse_block_node(self, min_indent: int):
        indent, text = self.peek_indent_and_text()
        if indent is None or indent < min_indent:
            return None
        if text == "-" or text.startswith("- "):
            return self.parse_block_sequence(indent)
        if text.startswith("{") or text.startswith("["):
            return self.parse_multiline_flow(text)
        if find_mapping_colon(text) != -1:
            return self.parse_block_mapping(indent)
        # Plain/quoted scalar
        self.idx += 1
        return decode_scalar(strip_yaml_comment(text))

    def parse_multiline_flow(self, first_text: str):
        buf = [first_text]
        depth = flow_balance_delta(first_text)
        self.idx += 1
        while depth > 0 and self.idx < self.n:
            line = self.lines[self.idx]
            buf.append(line)
            depth += flow_balance_delta(line)
            self.idx += 1
        if depth != 0:
            raise YamlParseError(f"unbalanced flow collection near line {self.idx}")
        return FlowParser("\n".join(buf)).parse()

    def parse_block_scalar(self, header: str, parent_indent: int) -> str:
        m = BLOCK_SCALAR_HDR_RE.match(header)
        if not m:
            raise YamlParseError(f"invalid block scalar header: {header!r}")
        style = m.group(1)  # '|' or '>'
        mods = m.group(2)
        chomp = "clip"
        explicit_indent = None
        for ch in mods:
            if ch == "-":
                chomp = "strip"
            elif ch == "+":
                chomp = "keep"
            elif ch.isdigit():
                explicit_indent = int(ch)

        raw_lines = []
        block_indent = (parent_indent + explicit_indent) if explicit_indent else None
        while self.idx < self.n:
            raw = self.lines[self.idx]
            if raw.strip() == "":
                raw_lines.append("")
                self.idx += 1
                continue
            ind = len(raw) - len(raw.lstrip(" "))
            if ind <= parent_indent:
                break
            if block_indent is None:
                block_indent = ind
            if ind < block_indent:
                break
            raw_lines.append(raw[block_indent:])
            self.idx += 1

        # Count trailing empty lines for chomping
        trailing_empty = 0
        while raw_lines and raw_lines[-1] == "":
            raw_lines.pop()
            trailing_empty += 1

        if not raw_lines:
            return "\n" * trailing_empty if chomp == "keep" else ""

        if style == "|":
            body = "\n".join(raw_lines)
        else:
            # YAML folded scalar (>): fold single newlines between non-indented
            # non-empty lines into spaces; preserve blank lines and newlines
            # around more-indented lines.
            parts = []
            i = 0
            m_len = len(raw_lines)
            while i < m_len:
                cur = raw_lines[i]
                if cur == "":
                    parts.append("\n")
                    i += 1
                    continue
                is_more_indented = cur[0] in (" ", "\t")
                parts.append(cur)
                if i + 1 < m_len:
                    nxt = raw_lines[i + 1]
                    if nxt == "":
                        # Blank line(s) follow: first blank line separates paragraphs
                        if is_more_indented:
                            parts.append("\n")
                    else:
                        nxt_more_indented = nxt[0] in (" ", "\t")
                        if is_more_indented or nxt_more_indented:
                            parts.append("\n")
                        else:
                            parts.append(" ")
                i += 1
            body = "".join(parts)

        if chomp == "strip":
            return body
        if chomp == "keep":
            return body + "\n" + ("\n" * trailing_empty)
        return body + "\n"

    def parse_inline_value(self, rest: str, parent_indent: int):
        rest_clean = strip_yaml_comment(rest).strip()
        if rest_clean == "":
            nxt_indent, nxt_text = self.peek_indent_and_text()
            if nxt_indent is None:
                return None
            if nxt_indent > parent_indent:
                return self.parse_block_node(nxt_indent)
            # Same-indent block sequence under a mapping key (valid YAML, e.g. `steps:\n- run:`)
            if nxt_indent == parent_indent and (nxt_text == "-" or nxt_text.startswith("- ")):
                return self.parse_block_sequence(nxt_indent)
            return None

        if BLOCK_SCALAR_HDR_RE.match(rest_clean):
            return self.parse_block_scalar(rest_clean, parent_indent)

        if rest_clean.startswith("{") or rest_clean.startswith("["):
            # Rewind idx by 1 so parse_multiline_flow consumes from current line's remainder
            buf = [rest_clean]
            depth = flow_balance_delta(rest_clean)
            while depth > 0 and self.idx < self.n:
                line = self.lines[self.idx]
                buf.append(line)
                depth += flow_balance_delta(line)
                self.idx += 1
            if depth != 0:
                raise YamlParseError(f"unbalanced flow collection near line {self.idx}")
            return FlowParser("\n".join(buf)).parse()

        # Check for multiline plain scalar continuation
        val_parts = [rest_clean]
        if not (
            (rest_clean.startswith("'") and rest_clean.endswith("'") and len(rest_clean) >= 2)
            or (rest_clean.startswith('"') and rest_clean.endswith('"') and len(rest_clean) >= 2)
        ):
            while self.idx < self.n:
                raw = self.lines[self.idx]
                s = raw.strip()
                if s == "" or s.startswith("#"):
                    break
                ind = len(raw) - len(raw.lstrip(" "))
                if ind <= parent_indent:
                    break
                if s == "-" or s.startswith("- ") or find_mapping_colon(s) != -1:
                    break
                val_parts.append(strip_yaml_comment(s).strip())
                self.idx += 1
        return decode_scalar(" ".join(val_parts))

    def parse_block_mapping(self, map_indent: int, initial_entry=None):
        mapping = {}
        if initial_entry is not None:
            k, v = initial_entry
            mapping[str(k)] = v

        while True:
            indent, text = self.peek_indent_and_text()
            if indent is None or indent < map_indent:
                break
            if indent > map_indent:
                raise YamlParseError(
                    f"line {self.idx + 1}: unexpected indentation {indent} (expected {map_indent})"
                )
            if text == "-" or text.startswith("- "):
                break
            colon = find_mapping_colon(text)
            if colon == -1:
                raise YamlParseError(f"line {self.idx + 1}: expected mapping key: value, got {text!r}")
            key = decode_scalar(text[:colon].strip())
            rest = text[colon + 1 :]
            self.idx += 1
            val = self.parse_inline_value(rest, map_indent)
            mapping["" if key is None else str(key)] = val
        return mapping

    def parse_block_sequence(self, seq_indent: int):
        items = []
        while True:
            indent, text = self.peek_indent_and_text()
            if indent is None or indent < seq_indent:
                break
            if indent != seq_indent:
                break
            if not (text == "-" or text.startswith("- ")):
                break

            after_dash_raw = text[1:]
            after_dash_stripped = after_dash_raw.lstrip(" ")
            spaces_after_dash = len(after_dash_raw) - len(after_dash_stripped)
            item_col = seq_indent + 1 + spaces_after_dash
            self.idx += 1

            clean_after = strip_yaml_comment(after_dash_stripped).strip()
            if clean_after == "":
                nxt_indent, _ = self.peek_indent_and_text()
                if nxt_indent is not None and nxt_indent > seq_indent:
                    items.append(self.parse_block_node(nxt_indent))
                else:
                    items.append(None)
                continue

            if BLOCK_SCALAR_HDR_RE.match(clean_after):
                items.append(self.parse_block_scalar(clean_after, seq_indent))
                continue

            if clean_after.startswith("{") or clean_after.startswith("["):
                buf = [clean_after]
                depth = flow_balance_delta(clean_after)
                while depth > 0 and self.idx < self.n:
                    line = self.lines[self.idx]
                    buf.append(line)
                    depth += flow_balance_delta(line)
                    self.idx += 1
                if depth != 0:
                    raise YamlParseError(f"unbalanced flow collection near line {self.idx}")
                items.append(FlowParser("\n".join(buf)).parse())
                continue

            colon = find_mapping_colon(after_dash_stripped)
            if colon != -1:
                k = decode_scalar(after_dash_stripped[:colon].strip())
                rest = after_dash_stripped[colon + 1 :]
                first_val = self.parse_inline_value(rest, item_col)
                items.append(
                    self.parse_block_mapping(
                        item_col, initial_entry=("" if k is None else str(k), first_val)
                    )
                )
                continue

            # Scalar sequence item
            items.append(decode_scalar(clean_after))
        return items


def parse_yaml(text: str):
    return YamlParser(text).parse()


# ---------------------------------------------------------------------------
# Policy validation helpers
# ---------------------------------------------------------------------------

def ast_contains_pion_ref(node) -> bool:
    if isinstance(node, str):
        return bool(PION_REF_RE.search(node))
    if isinstance(node, list):
        return any(ast_contains_pion_ref(x) for x in node)
    if isinstance(node, dict):
        return any(ast_contains_pion_ref(k) or ast_contains_pion_ref(v) for k, v in node.items())
    return False


def strip_shell_comments(script: str) -> str:
    """Remove shell/pwsh full-line comments and unquoted inline comments."""
    cleaned_lines = []
    for raw in script.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        # Strip unquoted inline '#' preceded by whitespace (preserving ${#var}, ${a#b}, etc.)
        in_single = False
        in_double = False
        cut = len(raw)
        i = 0
        while i < len(raw):
            ch = raw[i]
            if ch == "'" and not in_double:
                in_single = not in_single
            elif ch == '"' and not in_single:
                if i == 0 or raw[i - 1] != "\\":
                    in_double = not in_double
            elif ch == "#" and not in_single and not in_double:
                if i > 0 and raw[i - 1].isspace():
                    cut = i
                    break
            i += 1
        line = raw[:cut].strip()
        if line:
            cleaned_lines.append(line)
    return "\n".join(cleaned_lines)


def last_executable_shell_line(script: str) -> str:
    cleaned = strip_shell_comments(script)
    if not cleaned:
        return ""
    return cleaned.splitlines()[-1].strip()


def is_always_if(val) -> bool:
    if not isinstance(val, str):
        return False
    s = val.strip()
    if s.startswith("${{") and s.endswith("}}"):
        s = s[3:-2].strip()
    return s.lower() == "always()"


def strip_balanced_parens(s: str) -> str:
    s = s.strip()
    while s.startswith("(") and s.endswith(")"):
        depth = 0
        balanced = True
        for idx, ch in enumerate(s):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and idx < len(s) - 1:
                    balanced = False
                    break
        if balanced and depth == 0:
            s = s[1:-1].strip()
        else:
            break
    return s


def is_valid_timeout_expr(tm: str) -> bool:
    m = TIMEOUT_EXPR_RE.match(tm.strip())
    if not m:
        return False
    inner = strip_balanced_parens(m.group(1))
    fm = TIMEOUT_FALLBACK_3_END_RE.match(inner)
    if not fm:
        return False
    lhs = strip_balanced_parens(fm.group(1))
    bm = TIMEOUT_COND_AND_N_RE.match(lhs)
    if not bm:
        return False
    cond = strip_balanced_parens(bm.group(1))
    if not cond:
        return False
    atoms = [strip_balanced_parens(part) for part in cond.split("||")]
    if not atoms or any(not a for a in atoms):
        return False
    return all(any(rx.match(a) for rx in SAFE_RELEASE_ATOM_RES) for a in atoms)


def is_release_gated_if(if_val) -> bool:
    """Return True if step `if:` guarantees execution only on tag/workflow_dispatch."""
    if not isinstance(if_val, str):
        return False
    s = if_val.strip()
    if s.startswith("${{") and s.endswith("}}"):
        s = s[3:-2].strip()
    s = strip_balanced_parens(s)
    if not s:
        return False
    or_branches = [strip_balanced_parens(b) for b in s.split("||")]
    if not or_branches or any(not b for b in or_branches):
        return False
    for branch in or_branches:
        and_atoms = [strip_balanced_parens(a) for a in branch.split("&&")]
        if not any(any(rx.match(a) for rx in SAFE_RELEASE_ATOM_RES) for a in and_atoms):
            return False
    return True


def is_step_timeout_le_3(st: dict) -> bool:
    tm = st.get("timeout-minutes")
    if tm is None:
        return False
    s = str(tm).strip()
    return bool(re.fullmatch(r"\d+", s)) and 1 <= int(s) <= 3


def compute_matrix_total_jobs(matrix: dict):
    """Return total expanded matrix job count (Cartesian product + added include items), or None if non-static."""
    base_axes = {
        k: v for k, v in matrix.items() if k not in ("include", "exclude")
    }
    combos = [{}]
    for k, v in base_axes.items():
        if not isinstance(v, list):
            return None
        if len(v) == 0:
            combos = []
            break
        next_combos = []
        for c in combos:
            for item in v:
                nc = dict(c)
                nc[k] = item
                next_combos.append(nc)
                if len(next_combos) > 10000:
                    return 10001
        combos = next_combos

    total = len(combos) if base_axes else 0
    inc = matrix.get("include")
    if inc is not None:
        if not isinstance(inc, list):
            return None
        for item in inc:
            if not isinstance(item, dict):
                return None
            if not base_axes:
                total += 1
                continue
            shared_keys = [k for k in base_axes if k in item]
            if not shared_keys:
                # Merges into all existing combos without adding new jobs
                continue
            matched = any(
                all(c.get(k) == item.get(k) for k in shared_keys) for c in combos
            )
            if not matched:
                total += 1
    return total


def git_ref_exists(repo_root: str, ref: str) -> bool:
    try:
        r = subprocess.run(
            ["git", "-C", repo_root, "show-ref", "--verify", "--quiet", ref],
            capture_output=True,
            timeout=5,
        )
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def detect_default_branch(repo_root: str) -> str:
    """Detect default branch from trusted remote refs only (never local feature-branch HEAD)."""
    try:
        r = subprocess.run(
            ["git", "-C", repo_root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            ref = r.stdout.strip()
            if ref.startswith("origin/"):
                ref = ref[len("origin/") :]
            if ref:
                return ref
    except (OSError, subprocess.SubprocessError):
        pass
    has_main = git_ref_exists(repo_root, "refs/remotes/origin/main")
    has_master = git_ref_exists(repo_root, "refs/remotes/origin/master")
    if has_master and not has_main:
        return "master"
    return "main"


def glob_matches_branch(branch: str, pattern: str) -> bool:
    if pattern in ("*", "**"):
        return True
    # GitHub Actions '**' matches across '/', '*' matches within a segment
    regex = "^"
    i = 0
    n = len(pattern)
    while i < n:
        if pattern[i : i + 2] == "**":
            regex += ".*"
            i += 2
        elif pattern[i] == "*":
            regex += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            regex += "[^/]"
            i += 1
        else:
            regex += re.escape(pattern[i])
            i += 1
    regex += "$"
    return bool(re.match(regex, branch))


def branch_list_matches(branch: str, patterns) -> bool:
    matched = False
    for pat in patterns:
        if not isinstance(pat, str):
            continue
        if pat.startswith("!"):
            if glob_matches_branch(branch, pat[1:]):
                matched = False
        else:
            if glob_matches_branch(branch, pat):
                matched = True
    return matched


def as_str_list(val):
    if val is None:
        return []
    if isinstance(val, list):
        return [str(x) for x in val if x is not None]
    return [str(val)]


def parse_on_triggers(on_node, default_branch: str):
    """Return (has_pull_request, push_covers_default_branch) from parsed 'on' AST."""
    if on_node is None:
        return False, False
    if isinstance(on_node, str):
        ev = on_node.strip()
        return ev in ("pull_request", "pull_request_target"), ev == "push"
    if isinstance(on_node, list):
        evs = {str(x).strip() for x in on_node if x is not None}
        return bool(evs & {"pull_request", "pull_request_target"}), "push" in evs
    if not isinstance(on_node, dict):
        return False, False

    has_pr = "pull_request" in on_node or "pull_request_target" in on_node
    if "push" not in on_node:
        return has_pr, False

    push_cfg = on_node["push"]
    if push_cfg is None:
        return has_pr, True
    if not isinstance(push_cfg, dict) or len(push_cfg) == 0:
        return has_pr, True

    has_branches = "branches" in push_cfg
    has_branches_ignore = "branches-ignore" in push_cfg
    has_tags = "tags" in push_cfg or "tags-ignore" in push_cfg

    if has_branches:
        pats = as_str_list(push_cfg.get("branches"))
        return has_pr, branch_list_matches(default_branch, pats)

    if has_tags and not has_branches_ignore:
        return has_pr, False

    if has_branches_ignore:
        ign = as_str_list(push_cfg.get("branches-ignore"))
        return has_pr, (not branch_list_matches(default_branch, ign))

    # push with only e.g. paths: / paths-ignore:
    return has_pr, True


def check_workflow_file(
    wf_path: str,
    allow_legacy_shards: dict,
    default_branch: str = "main",
    allow_notarize_timeouts=None,
):
    if allow_notarize_timeouts is None:
        allow_notarize_timeouts = set()
    errors = []
    wf_name = os.path.basename(wf_path)
    try:
        with open(wf_path, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        return [f"{wf_name}: failed to read workflow: {e}"]

    try:
        doc = parse_yaml(content)
    except YamlParseError as e:
        return [f"{wf_name}: YAML parse error (fail-closed): {e}"]

    if not isinstance(doc, dict):
        return [f"{wf_name}: workflow root must be a YAML mapping (fail-closed)"]

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        return [f"{wf_name}: no parseable 'jobs:' mapping found (fail-closed)"]

    # Rule (d): cache warming on default-branch push for Pion workflows with pull_request
    on_node = doc.get("on")
    has_pr, push_ok = parse_on_triggers(on_node, default_branch)
    uses_pion = ast_contains_pion_ref(doc)
    if uses_pion and has_pr and not push_ok:
        errors.append(
            f"{wf_name}: [cache-warm] workflow references pion/pionc/PION_CACHE_DIR and "
            f"triggers on pull_request, so it MUST also trigger on push to default branch "
            f"`{default_branch}` (e.g. `push: branches: [{default_branch}]`) to prevent PR cache starvation"
        )

    for job_id, job in jobs.items():
        loc = f"{wf_name}:{job_id}"
        if not isinstance(job, dict):
            errors.append(f"{loc}: job definition must be a mapping (fail-closed)")
            continue

        # Rule (c) part 1: job name suffix check applies to ALL jobs including reusable `uses:` calls
        if FORBIDDEN_JOB_SUFFIX_RE.search(job_id):
            errors.append(
                f"{loc}: [no-shard] forbidden sharded job name `{job_id}`; NEVER split CI jobs "
                f"into `-shard-N`/`-part-N`/`-split-N`"
            )

        # Rule (c) part 2: strategy.matrix sharding check (top-level keys + matrix.include + total cap)
        strategy = job.get("strategy")
        if isinstance(strategy, dict):
            matrix = strategy.get("matrix")
            if isinstance(matrix, dict):
                legacy_key = f"{wf_name}:{job_id}"
                max_legacy = allow_legacy_shards.get(legacy_key)
                has_forbidden_key = False
                for mk in matrix.keys():
                    if mk.lower() in FORBIDDEN_MATRIX_KEYS:
                        has_forbidden_key = True
                        if max_legacy is None:
                            errors.append(
                                f"{loc}: [no-shard] forbidden `strategy.matrix.{mk}` key; NEVER "
                                f"split CI jobs or add matrix shards — optimize inside the "
                                f"existing single job"
                            )
                if has_forbidden_key and max_legacy is not None:
                    total_jobs = compute_matrix_total_jobs(matrix)
                    if total_jobs is None:
                        errors.append(
                            f"{loc}: [no-shard] legacy shard matrix must be statically expandable "
                            f"(cap={max_legacy})"
                        )
                    elif total_jobs > max_legacy:
                        errors.append(
                            f"{loc}: [no-shard] legacy shard matrix expands to {total_jobs} total "
                            f"jobs, exceeding allowlist cap of {max_legacy}"
                        )
                inc = matrix.get("include")
                if isinstance(inc, list):
                    for item in inc:
                        if isinstance(item, dict):
                            for ik in item.keys():
                                if ik.lower() in FORBIDDEN_MATRIX_KEYS:
                                    errors.append(
                                        f"{loc}: [no-shard] forbidden `strategy.matrix.include.{ik}` "
                                        f"key; NEVER add matrix shards via `include`"
                                    )

        # Reusable workflow calls skip runner-step/timeout checks
        if "uses" in job and job["uses"] is not None:
            continue

        steps = job.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append(f"{loc}: [timing] job has no steps")
            steps = []

        # Rule (a): timeout-minutes
        tm_raw = job.get("timeout-minutes")
        tm = "" if tm_raw is None else str(tm_raw).strip()
        if not tm:
            errors.append(f"{loc}: [timeout] missing required `timeout-minutes` (must be <= 3)")
        elif re.fullmatch(r"-?\d+", tm):
            val = int(tm)
            if val < 1 or val > 3:
                errors.append(
                    f"{loc}: [timeout] `timeout-minutes: {val}` exceeds hard cap of 3 minutes"
                )
        elif TIMEOUT_EXPR_RE.match(tm):
            if loc not in allow_notarize_timeouts:
                errors.append(
                    f"{loc}: [timeout] expression `timeout-minutes: {tm}` requires explicit "
                    f"`--allow-notarize-timeout {loc}`; all normal jobs must use integer <= 3"
                )
            else:
                if not is_valid_timeout_expr(tm):
                    errors.append(
                        f"{loc}: [timeout] expression `timeout-minutes: {tm}` MUST only use "
                        f"tag/workflow_dispatch predicates combined with `||`, followed by `&& <N> || 3`"
                    )
                # Every non-tag/dispatch-gated middle `run:` step MUST explicitly set timeout-minutes <= 3,
                # and at least one middle `run:` step must be tag/dispatch-gated (for external notarization).
                middle_steps = steps[1:-1] if len(steps) >= 3 else []
                middle_run_steps = [
                    (idx, st)
                    for idx, st in enumerate(middle_steps, 2)
                    if isinstance(st, dict)
                    and isinstance(st.get("run"), str)
                    and st.get("run").strip() != ""
                ]
                gated_runs = [
                    (idx, st)
                    for idx, st in middle_run_steps
                    if is_release_gated_if(st.get("if"))
                ]
                ungated_runs = [
                    (idx, st)
                    for idx, st in middle_run_steps
                    if not is_release_gated_if(st.get("if"))
                ]
                if not ungated_runs:
                    errors.append(
                        f"{loc}: [timeout] notarization-allowed job must have at least one "
                        f"build/test `run:` step with explicit `timeout-minutes: 3`"
                    )
                for st_idx, st in ungated_runs:
                    if not is_step_timeout_le_3(st):
                        st_name = st.get("name") or f"step {st_idx}"
                        errors.append(
                            f"{loc}: [timeout] non-release-gated `run:` step `{st_name}` MUST "
                            f"explicitly set integer `timeout-minutes <= 3`"
                        )
                if not gated_runs:
                    errors.append(
                        f"{loc}: [timeout] notarization-allowed job must contain at least one "
                        f"tag/workflow_dispatch-gated `run:` step"
                    )
        else:
            errors.append(
                f"{loc}: [timeout] invalid `timeout-minutes: {tm}` (expected integer <= 3)"
            )

        # Rule (b): JOB_START_EPOCH first step (no skipping `if:`) & if: always() + CI duration > 60s last step
        if steps:
            first_step = steps[0] if isinstance(steps[0], dict) else {}
            first_if = first_step.get("if")
            if first_if is not None and not is_always_if(first_if):
                errors.append(
                    f"{loc}: [timing] first step must not set a conditional `if:` (`{first_if}`) "
                    f"that can skip recording `JOB_START_EPOCH`"
                )
            first_run = strip_shell_comments(str(first_step.get("run") or ""))
            if "JOB_START_EPOCH" not in first_run:
                errors.append(
                    f"{loc}: [timing] first step must record `JOB_START_EPOCH` in executable shell code"
                )
            last_step = steps[-1] if isinstance(steps[-1], dict) else {}
            if not is_always_if(last_step.get("if")):
                errors.append(
                    f"{loc}: [timing] last step must set `if: always()` so duration warnings "
                    f"still run on failure"
                )
            last_run = strip_shell_comments(str(last_step.get("run") or ""))
            if "CI duration > 60s" not in last_run:
                errors.append(
                    f"{loc}: [timing] last step must emit `::warning title=CI duration > 60s::...` "
                    f"in executable shell code"
                )

        # Rule (e): known pitfalls in steps
        for idx, st in enumerate(steps, 1):
            if not isinstance(st, dict):
                continue
            uses = str(st.get("uses") or "").strip()
            if uses.startswith("actions/cache"):
                w = st.get("with")
                if isinstance(w, dict) and w.get("path") is not None:
                    wpath = str(w["path"])
                    for pline in wpath.splitlines():
                        p = pline.strip()
                        if p.startswith("!"):
                            errors.append(
                                f"{loc}: [cache-negation] step {idx} (`{uses}`) uses `!` negation "
                                f"(`{p}`) in `with.path`; list explicit paths or split "
                                f"`actions/cache/restore` + `actions/cache/save` instead"
                            )
                            break

            shell = str(st.get("shell") or "").strip().lower()
            run_body = st.get("run")
            if isinstance(run_body, str) and shell not in ("pwsh", "powershell", "cmd"):
                last_line = last_executable_shell_line(run_body)
                if END_TEST_WAIT_RE.match(last_line):
                    errors.append(
                        f"{loc}: [shell-wait] step {idx} ends with `{last_line}` which exits "
                        f"non-zero when the condition is false; use `if [ ... ]; then wait ...; fi`"
                    )

    return errors


def check_repo(
    repo_root: str,
    allow_legacy_shards: dict,
    default_branch=None,
    allow_notarize_timeouts=None,
):
    wf_dir = os.path.join(repo_root, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        return [f"{wf_dir}: workflows directory not found"]
    wf_files = sorted(
        os.path.join(wf_dir, name)
        for name in os.listdir(wf_dir)
        if name.endswith(".yml") or name.endswith(".yaml")
    )
    if not wf_files:
        return [f"{wf_dir}: no .yml/.yaml workflow files found"]
    branch = default_branch or detect_default_branch(repo_root)
    all_errors = []
    for wf in wf_files:
        all_errors.extend(
            check_workflow_file(wf, allow_legacy_shards, branch, allow_notarize_timeouts)
        )
    return all_errors


def run_self_test():
    GOOD_SINGLE_JOB = """name: ci
on:
  push:
    branches: [main]
  pull_request:

jobs:
  linux:
    runs-on: ubuntu-latest
    timeout-minutes: 3
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"
      - uses: actions/checkout@v4
      - uses: actions/cache/restore@v4
        with:
          path: |
            ~/.cache/pion/cas
            out/pionc
          key: pion-linux-v1
      - name: Build and test
        run: |
          set -eu
          pionc check
          pid=""
          if [ -n "$pid" ]; then wait "$pid"; fi
      - name: Check 60s duration target
        if: always()
        run: |
          ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
          if [ "$ELAPSED" -gt 60 ]; then
            echo "::warning title=CI duration > 60s::linux took ${ELAPSED}s"
          fi
"""

    GOOD_NOTARY_AND_REUSABLE = """name: release
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  call-shared:
    uses: ./.github/workflows/shared.yml

  macos-release:
    runs-on: macos-15
    timeout-minutes: ${{ (github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/')) && 15 || 3 }}
    strategy:
      matrix:
        arch: [arm64]
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"
      - uses: actions/checkout@v4
      - name: Build and test
        timeout-minutes: 3
        run: pionc test
      - name: Notarize macOS bundle
        if: startsWith(github.ref, 'refs/tags/')
        run: xcrun notarytool submit dist/app.zip --wait
      - name: Check 60s duration target
        if: ${{ always() }}
        run: |
          ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
          if [ "$ELAPSED" -gt 60 ]; then
            echo "::warning title=CI duration > 60s::macos-release took ${ELAPSED}s"
          fi
"""

    GOOD_SAME_INDENT_SEQ = """name: ci
on:
  push:
    branches:
    - main
  pull_request:

jobs:
  linux:
    runs-on: ubuntu-latest
    timeout-minutes: 3
    steps:
    - name: Record job start
      run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"
    - run: pionc test
    - name: Check 60s duration target
      if: always()
      run: |
        ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
        if [ "$ELAPSED" -gt 60 ]; then
          echo "::warning title=CI duration > 60s::linux took ${ELAPSED}s"
        fi
"""

    GOOD_NON_PION_WITH_COMMENT = """name: docs
# mentions pion and pionc and PION_CACHE_DIR only in comments
on:
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 2 # pion comment
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"
      - run: echo "docs ok"
      - name: Check 60s duration target
        if: always()
        run: |
          echo "::warning title=CI duration > 60s::ok"
"""

    NEGATIVE_CASES = [
        (
            "missing-timeout",
            "[timeout]",
            GOOD_SINGLE_JOB.replace("    timeout-minutes: 3\n", ""),
        ),
        (
            "timeout-5",
            "[timeout]",
            GOOD_SINGLE_JOB.replace("timeout-minutes: 3", "timeout-minutes: 5"),
        ),
        (
            "timeout-expr-without-allowlist",
            "[timeout]",
            GOOD_NOTARY_AND_REUSABLE,
        ),
        (
            "first-step-conditional-if",
            "[timing]",
            GOOD_SINGLE_JOB.replace(
                "      - name: Record job start\n        run:",
                "      - name: Record job start\n        if: github.event_name == 'workflow_dispatch'\n        run:",
            ),
        ),
        (
            "pr-wrong-default-branch-master",
            "[cache-warm]",
            GOOD_SINGLE_JOB.replace("branches: [main]", "branches: [master]"),
        ),
        (
            "missing-job-start-epoch",
            "[timing]",
            GOOD_SINGLE_JOB.replace("JOB_START_EPOCH", "START_TS"),
        ),
        (
            "job-start-epoch-in-comment",
            "[timing]",
            GOOD_SINGLE_JOB.replace(
                'run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"',
                'run: |\n          # JOB_START_EPOCH=$(date +%s)\n          echo ok',
            ),
        ),
        (
            "missing-if-always",
            "[timing]",
            GOOD_SINGLE_JOB.replace("        if: always()\n", ""),
        ),
        (
            "missing-60s-warning",
            "[timing]",
            GOOD_SINGLE_JOB.replace("CI duration > 60s", "slow job"),
        ),
        (
            "60s-warning-in-comment",
            "[timing]",
            GOOD_SINGLE_JOB.replace(
                'echo "::warning title=CI duration > 60s::linux took ${ELAPSED}s"',
                '# echo "::warning title=CI duration > 60s::linux took ${ELAPSED}s"\n            echo ok',
            ),
        ),
        (
            "matrix-shard-block",
            "[no-shard]",
            GOOD_SINGLE_JOB.replace(
                "    timeout-minutes: 3\n",
                "    timeout-minutes: 3\n    strategy:\n      matrix:\n        shard: [0, 1]\n",
            ),
        ),
        (
            "matrix-shard-flow",
            "[no-shard]",
            GOOD_SINGLE_JOB.replace(
                "    timeout-minutes: 3\n",
                "    timeout-minutes: 3\n    strategy: {matrix: {shard: [0, 1]}}\n",
            ),
        ),
        (
            "matrix-include-shard",
            "[no-shard]",
            GOOD_SINGLE_JOB.replace(
                "    timeout-minutes: 3\n",
                "    timeout-minutes: 3\n    strategy:\n      matrix:\n        include:\n          - os: ubuntu-latest\n            shard: 0\n",
            ),
        ),
        (
            "job-name-shard-suffix",
            "[no-shard]",
            GOOD_SINGLE_JOB.replace("  linux:\n", "  linux-shard-0:\n"),
        ),
        (
            "reusable-job-name-shard-suffix",
            "[no-shard]",
            GOOD_NOTARY_AND_REUSABLE.replace("  call-shared:\n", "  e2e-shard-1:\n"),
        ),
        (
            "pr-without-push",
            "[cache-warm]",
            GOOD_SINGLE_JOB.replace("  push:\n    branches: [main]\n", ""),
        ),
        (
            "pr-with-flow-tag-only-push",
            "[cache-warm]",
            GOOD_SINGLE_JOB.replace("  push:\n    branches: [main]\n", "  push: {tags: ['v*']}\n"),
        ),
        (
            "pr-with-negated-main-branch",
            "[cache-warm]",
            GOOD_SINGLE_JOB.replace("branches: [main]", "branches: ['**', '!main']"),
        ),
        (
            "cache-negation-block",
            "[cache-negation]",
            GOOD_SINGLE_JOB.replace("            out/pionc\n", "            !~/.cache/pion/tmp\n"),
        ),
        (
            "cache-negation-flow",
            "[cache-negation]",
            GOOD_SINGLE_JOB.replace(
                "        with:\n          path: |\n            ~/.cache/pion/cas\n            out/pionc\n          key: pion-linux-v1\n",
                "        with: {path: \"~/.cache/pion/cas\\n!foo\", key: pion-linux-v1}\n",
            ),
        ),
        (
            "trailing-test-and-wait-literal",
            "[shell-wait]",
            GOOD_SINGLE_JOB.replace(
                '          if [ -n "$pid" ]; then wait "$pid"; fi\n',
                '          [ -n "$pid" ] && wait "$pid"\n',
            ),
        ),
        (
            "trailing-test-and-wait-folded",
            "[shell-wait]",
            GOOD_SINGLE_JOB.replace(
                '        run: |\n          set -eu\n          pionc check\n          pid=""\n          if [ -n "$pid" ]; then wait "$pid"; fi\n',
                '        run: >-\n          [ -n "$pid" ] &&\n          wait "$pid"\n',
            ),
        ),
    ]

    with tempfile.TemporaryDirectory(prefix="pion-ci-policy-selftest-") as tmp:
        wf_dir = os.path.join(tmp, ".github", "workflows")
        os.makedirs(wf_dir)

        # 1. Positive fixtures (strict default mode: no allowlists)
        positives = (
            ("good-single.yml", GOOD_SINGLE_JOB),
            ("good-same-indent.yml", GOOD_SAME_INDENT_SEQ),
            ("good-non-pion-comment.yml", GOOD_NON_PION_WITH_COMMENT),
        )
        for name, body in positives:
            p = os.path.join(wf_dir, name)
            with open(p, "w", encoding="utf-8") as f:
                f.write(body)
            errs = check_workflow_file(p, {})
            if errs:
                print(f"SELF-TEST FAIL (expected pass for {name}):", file=sys.stderr)
                for e in errs:
                    print(f"  {e}", file=sys.stderr)
                return 1

        # 2. Negative fixtures (strict default mode)
        for case_name, expected_tag, body in NEGATIVE_CASES:
            p = os.path.join(wf_dir, f"bad-{case_name}.yml")
            with open(p, "w", encoding="utf-8") as f:
                f.write(body)
            errs = check_workflow_file(p, {})
            if not any(expected_tag in e for e in errs):
                print(
                    f"SELF-TEST FAIL (case {case_name}: expected {expected_tag}, got {errs})",
                    file=sys.stderr,
                )
                return 1

        # 3. Explicit --allow-notarize-timeout positive & negative fixtures
        notary_p = os.path.join(wf_dir, "good-notary.yml")
        with open(notary_p, "w", encoding="utf-8") as f:
            f.write(GOOD_NOTARY_AND_REUSABLE)
        errs = check_workflow_file(
            notary_p, {}, allow_notarize_timeouts={"good-notary.yml:macos-release"}
        )
        if errs:
            print(f"SELF-TEST FAIL (good-notary.yml with allowlist): {errs}", file=sys.stderr)
            return 1

        NOTARY_NEGATIVES = [
            (
                "notary-no-fallback-3",
                GOOD_NOTARY_AND_REUSABLE.replace("&& 15 || 3", "&& 15 || 5"),
            ),
            (
                "notary-always-true-5-or-3",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "(github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/')) && 15 || 3",
                    "5 || 3",
                ),
            ),
            (
                "notary-pr-predicate",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "github.event_name == 'workflow_dispatch'",
                    "github.event_name == 'pull_request'",
                ),
            ),
            (
                "notary-only-first-step-timeout",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "      - name: Record job start\n        run:",
                    "      - name: Record job start\n        timeout-minutes: 3\n        run:",
                ).replace(
                    "        timeout-minutes: 3\n        run: pionc test",
                    "        run: pionc test",
                ),
            ),
            (
                "notary-uses-step-only",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "      - uses: actions/checkout@v4",
                    "      - uses: actions/checkout@v4\n        timeout-minutes: 3",
                ).replace(
                    "        timeout-minutes: 3\n        run: pionc test",
                    "        run: pionc test",
                ),
            ),
            (
                "notary-untimed-pionc-test-alongside-timed-echo",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "      - name: Build and test\n        timeout-minutes: 3\n        run: pionc test",
                    "      - name: Placeholder\n        timeout-minutes: 3\n        run: echo ok\n      - name: Build and test\n        run: pionc test",
                ),
            ),
            (
                "notary-missing-gated-step",
                GOOD_NOTARY_AND_REUSABLE.replace(
                    "      - name: Notarize macOS bundle\n        if: startsWith(github.ref, 'refs/tags/')\n        run: xcrun notarytool submit dist/app.zip --wait\n",
                    "",
                ),
            ),
        ]
        for case_name, body in NOTARY_NEGATIVES:
            p = os.path.join(wf_dir, f"bad-{case_name}.yml")
            with open(p, "w", encoding="utf-8") as f:
                f.write(body)
            errs = check_workflow_file(
                p, {}, allow_notarize_timeouts={f"bad-{case_name}.yml:macos-release"}
            )
            if not any("[timeout]" in e for e in errs):
                print(
                    f"SELF-TEST FAIL (notary case {case_name}: expected [timeout], got {errs})",
                    file=sys.stderr,
                )
                return 1

        # 4. Default branch detection must NEVER treat local feature branch HEAD as default branch
        feat_repo = os.path.join(tmp, "feat-repo")
        os.makedirs(feat_repo)
        subprocess.run(["git", "init", "-q", "-b", "ci/feature-branch", feat_repo], check=True)
        detected = detect_default_branch(feat_repo)
        if detected != "main":
            print(
                f"SELF-TEST FAIL (feature branch without origin/HEAD detected '{detected}', expected 'main')",
                file=sys.stderr,
            )
            return 1

        # 5. Legacy shard allowlist with max-total cap
        legacy_4 = os.path.join(wf_dir, "legacy.yml")
        with open(legacy_4, "w", encoding="utf-8") as f:
            f.write(
                GOOD_SINGLE_JOB.replace(
                    "    timeout-minutes: 3\n",
                    "    timeout-minutes: 3\n    strategy:\n      matrix:\n        shard: [0, 1, 2, 3]\n",
                )
            )
        if not check_workflow_file(legacy_4, {}):
            print("SELF-TEST FAIL (legacy.yml should fail without allowlist)", file=sys.stderr)
            return 1
        errs = check_workflow_file(legacy_4, {"legacy.yml:linux": 4})
        if errs:
            print(f"SELF-TEST FAIL (legacy.yml should pass with cap=4): {errs}", file=sys.stderr)
            return 1

        # Expanding 4 -> 5 shards must be rejected against cap=4
        with open(legacy_4, "w", encoding="utf-8") as f:
            f.write(
                GOOD_SINGLE_JOB.replace(
                    "    timeout-minutes: 3\n",
                    "    timeout-minutes: 3\n    strategy:\n      matrix:\n        shard: [0, 1, 2, 3, 4]\n",
                )
            )
        errs_5 = check_workflow_file(legacy_4, {"legacy.yml:linux": 4})
        if not any("[no-shard]" in e and "exceeding allowlist cap of 4" in e for e in errs_5):
            print(f"SELF-TEST FAIL (5 shards must exceed cap=4, got {errs_5})", file=sys.stderr)
            return 1

        # Cartesian expansion 4 x 2 = 8 total jobs must be rejected against cap=4
        with open(legacy_4, "w", encoding="utf-8") as f:
            f.write(
                GOOD_SINGLE_JOB.replace(
                    "    timeout-minutes: 3\n",
                    "    timeout-minutes: 3\n    strategy:\n      matrix:\n        shard: [0, 1, 2, 3]\n        slice: [a, b]\n",
                )
            )
        errs_8 = check_workflow_file(legacy_4, {"legacy.yml:linux": 4})
        if not any("[no-shard]" in e and "expands to 8 total" in e for e in errs_8):
            print(f"SELF-TEST FAIL (4x2=8 must exceed cap=4, got {errs_8})", file=sys.stderr)
            return 1

    print(
        f"PASS: check-ci-policy.sh --self-test "
        f"({len(positives) + 1} positive + {len(NEGATIVE_CASES) + len(NOTARY_NEGATIVES)} negative + branch & legacy-cap cases)"
    )
    return 0


def parse_legacy_spec(spec: str):
    if "=" not in spec or ":" not in spec:
        return None
    left, right = spec.rsplit("=", 1)
    if ":" not in left or not re.fullmatch(r"[1-9]\d*", right):
        return None
    return left, int(right)


def main(argv):
    allow_legacy_shards = {}
    allow_notarize_timeouts = set()
    default_branch = None
    repo_root = "."
    saw_root = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--self-test":
            return run_self_test()
        if arg == "--default-branch":
            if i + 1 >= len(argv) or not argv[i + 1].strip():
                print("error: --default-branch requires <name>", file=sys.stderr)
                return 2
            default_branch = argv[i + 1].strip()
            i += 2
            continue
        if arg == "--allow-notarize-timeout":
            if i + 1 >= len(argv) or ":" not in argv[i + 1]:
                print(
                    "error: --allow-notarize-timeout requires <workflow>:<job>",
                    file=sys.stderr,
                )
                return 2
            allow_notarize_timeouts.add(argv[i + 1].strip())
            i += 2
            continue
        if arg == "--allow-legacy-shard":
            if i + 1 >= len(argv):
                print(
                    "error: --allow-legacy-shard requires <workflow>:<job>=<max_total>",
                    file=sys.stderr,
                )
                return 2
            parsed = parse_legacy_spec(argv[i + 1])
            if parsed is None:
                print(
                    f"error: invalid --allow-legacy-shard '{argv[i + 1]}' "
                    f"(expected <workflow>:<job>=<max_total>)",
                    file=sys.stderr,
                )
                return 2
            key, cap = parsed
            allow_legacy_shards[key] = cap
            i += 2
            continue
        if arg in ("-h", "--help"):
            print(
                "Usage: sh scripts/check-ci-policy.sh "
                "[--default-branch <name>] "
                "[--allow-legacy-shard <workflow>:<job>=<max_total>]... "
                "[--allow-notarize-timeout <workflow>:<job>]... [repo_root]\n"
                "       sh scripts/check-ci-policy.sh --self-test"
            )
            return 0
        if arg.startswith("-"):
            print(f"error: unknown option: {arg}", file=sys.stderr)
            return 2
        if saw_root:
            print(f"error: unexpected extra argument: {arg}", file=sys.stderr)
            return 2
        repo_root = arg
        saw_root = True
        i += 1

    errors = check_repo(repo_root, allow_legacy_shards, default_branch, allow_notarize_timeouts)
    if errors:
        print(f"FAIL: CI policy violations found ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"PASS: CI policy check passed for {os.path.abspath(repo_root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
