#!/usr/bin/env python3
"""Validate syntaxes/pion.tmLanguage.json against compiler/src/core/lexer.pion."""

from __future__ import annotations

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
GRAMMAR_PATH = ROOT / "syntaxes" / "pion.tmLanguage.json"
LEXER_PATH = ROOT / "compiler" / "src" / "core" / "lexer.pion"
SAMPLE_PATH = ROOT / "syntaxes" / "samples" / "example.pion"


def walk_rules(obj, repo_keys: set[str], regexes: list[tuple[str, str]], errors: list[str], path: str = "$") -> None:
    if isinstance(obj, dict):
        inc = obj.get("include")
        if isinstance(inc, str) and inc.startswith("#"):
            target = inc[1:]
            if target not in repo_keys:
                errors.append(f"{path}: unresolved repository include #{target}")
        for field in ("match", "begin", "end", "while"):
            val = obj.get(field)
            if isinstance(val, str):
                regexes.append((f"{path}.{field}", val))
        for k, v in obj.items():
            walk_rules(v, repo_keys, regexes, errors, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            walk_rules(item, repo_keys, regexes, errors, f"{path}[{i}]")


def extract_lexer_keywords(lexer_src: str) -> set[str]:
    m = re.search(r"fn keyword_or_ident\b.*?^}", lexer_src, flags=re.M | re.S)
    if not m:
        raise RuntimeError("Could not locate keyword_or_ident in lexer.pion")
    return set(re.findall(r'word == "([a-z_]+)"', m.group(0)))


def main() -> int:
    grammar = json.loads(GRAMMAR_PATH.read_text(encoding="utf-8"))
    errors: list[str] = []

    if grammar.get("scopeName") != "source.pion":
        errors.append(f"Expected scopeName 'source.pion', got {grammar.get('scopeName')!r}")
    if "pion" not in (grammar.get("fileTypes") or []):
        errors.append("fileTypes must include 'pion'")

    repo = grammar.get("repository") or {}
    repo_keys = set(repo.keys())
    regexes: list[tuple[str, str]] = []
    walk_rules(grammar, repo_keys, regexes, errors)

    compiled: list[tuple[str, re.Pattern[str]]] = []
    for loc, pattern in regexes:
        try:
            compiled.append((loc, re.compile(pattern)))
        except re.error as exc:
            errors.append(f"{loc}: invalid regex {pattern!r}: {exc}")

    # Verify every keyword in compiler/src/core/lexer.pion is matched by the grammar's keyword/constant rules.
    lexer_kws = extract_lexer_keywords(LEXER_PATH.read_text(encoding="utf-8"))
    kw_patterns = []
    for section in ("keywords", "constants"):
        for rule in repo.get(section, {}).get("patterns", []):
            if "match" in rule:
                kw_patterns.append(re.compile(rule["match"]))
    missing_kws = sorted(kw for kw in lexer_kws if not any(p.search(kw) for p in kw_patterns))
    if missing_kws:
        errors.append(f"Keywords from lexer.pion missing in grammar: {missing_kws}")

    # Smoke-check sample file: every non-empty sample line matches at least one grammar rule.
    sample_lines = SAMPLE_PATH.read_text(encoding="utf-8").splitlines()
    for lineno, line in enumerate(sample_lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue
        if not any(p.search(line) for _, p in compiled):
            errors.append(f"Sample line {lineno} matched no grammar pattern: {line!r}")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(
        f"OK: {GRAMMAR_PATH.relative_to(ROOT)} validated "
        f"({len(repo_keys)} repo rules, {len(compiled)} regexes, "
        f"{len(lexer_kws)}/{len(lexer_kws)} lexer keywords covered, "
        f"{len(sample_lines)} sample lines checked)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
