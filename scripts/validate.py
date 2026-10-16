#!/usr/bin/env python3
"""validate.py -- validate the TX8 / MX3 Agent Skills suite (Python 3.10+, stdlib only).

Usage:
    python scripts/validate.py [--repo PATH] [--skill NAME ...] [--quiet]

Checks every skills/*/SKILL.md:
  - YAML frontmatter present; only keys name, description, license, compatibility, metadata
  - name: ^[a-z0-9]+(-[a-z0-9]+)*$, <= 64 chars, equals the folder name
  - description: 1..1024 chars, contains "Use when" (warn if not a double-quoted single line)
  - compatibility <= 500 chars; metadata is a flat map of string values
  - body line count 80..150 (warning outside), error above 500
  - relative markdown links in SKILL.md and references/*.md resolve to existing files,
    stay inside the skill folder, and SKILL.md links go at most one directory deep
  - no file under skills/ larger than 500 KB (*.csv: warning only)
  - shared/AGENTS.tx8.md smaller than 24 KB
Exit code: 0 = no errors, 1 = errors found, 2 = usage problem.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ALLOWED_KEYS = {"name", "description", "license", "compatibility", "metadata"}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+[\"'][^\"']*[\"'])?\s*\)")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
NON_STRING_RE = re.compile(r"^(-?\d+(\.\d+)?([eE][-+]?\d+)?|true|false|yes|no|on|off|null|~)$", re.I)
MAX_FILE = 500 * 1024
MAX_AGENTS = 24 * 1024
BODY_MIN, BODY_MAX, BODY_HARD = 80, 150, 500


class Report:
    def __init__(self, name: str) -> None:
        self.name = name
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.body_lines = 0

    def err(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def unquote(raw: str, rep: Report, key: str) -> tuple[str, bool]:
    """Return (value, was_quoted) for a scalar."""
    v = raw.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        inner = v[1:-1]
        out = re.sub(r'\\(["\\/nt])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), inner)
        return out, True
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'"), True
    if v[:1] in ('"', "'"):
        rep.err(f"frontmatter '{key}': unterminated quoted string")
    # strip trailing comment for plain scalars
    v = re.sub(r"\s+#.*$", "", v)
    return v, False


def parse_frontmatter(text: str, rep: Report) -> tuple[dict, dict, list[str] | None]:
    """Minimal YAML subset parser. Returns (top, meta, body_lines)."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        rep.err("missing YAML frontmatter (file must start with '---')")
        return {}, {}, None
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        rep.err("frontmatter not closed with '---'")
        return {}, {}, None
    fm = lines[1:end]
    body = lines[end + 1:]

    top: dict[str, object] = {}
    meta: dict[str, object] = {}
    raw_line: dict[str, str] = {}
    current = None
    block_lines: list[str] = []
    block_style = None

    def flush_block() -> None:
        nonlocal block_lines, block_style
        if current is not None and block_style is not None:
            sep = "\n" if block_style.startswith("|") else " "
            top[current] = sep.join(s.strip() for s in block_lines).strip()
        block_lines = []
        block_style = None

    for ln in fm:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if ln[0] not in (" ", "\t"):
            flush_block()
            m = re.match(r"^([A-Za-z0-9_-]+):(.*)$", ln)
            if not m:
                rep.err(f"cannot parse frontmatter line: {ln!r}")
                current = None
                continue
            key, rest = m.group(1), m.group(2)
            if key in top:
                rep.err(f"duplicate frontmatter key '{key}'")
            current = key
            raw_line[key] = rest.strip()
            if rest.strip() in ("|", ">", "|-", ">-", "|+", ">+"):
                block_style = rest.strip()
                top[key] = ""
            elif rest.strip() == "":
                top[key] = {} if key == "metadata" else ""
            else:
                top[key] = unquote(rest, rep, key)[0]
        else:
            if block_style is not None:
                block_lines.append(ln)
            elif current == "metadata":
                m = re.match(r"^\s+([A-Za-z0-9_.-]+):(.*)$", ln)
                if not m:
                    rep.err(f"cannot parse metadata line: {ln!r}")
                    continue
                k, rest = m.group(1), m.group(2).strip()
                if rest == "":
                    rep.err(f"metadata.{k}: nested maps/lists are not allowed (values must be strings)")
                    meta[k] = None
                    continue
                if rest.startswith(("[", "{", "- ", "|", ">")):
                    rep.err(f"metadata.{k}: value must be a string, got {rest[:20]!r}")
                    meta[k] = None
                    continue
                val, quoted = unquote(rest, rep, f"metadata.{k}")
                if not quoted and NON_STRING_RE.match(val):
                    rep.err(f"metadata.{k}: {val!r} is not a YAML string; quote it")
                meta[k] = val
            else:
                rep.err(f"unexpected indented line in frontmatter: {ln!r}")
    flush_block()
    if isinstance(top.get("metadata"), dict):
        top["metadata"] = meta
    top["__raw__"] = raw_line
    return top, meta, body


def strip_code(text: str) -> str:
    out = []
    in_fence = False
    for ln in text.splitlines():
        if FENCE_RE.match(ln):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        out.append(re.sub(r"`[^`]*`", "", ln))
    return "\n".join(out)


def check_links(md: Path, skill_dir: Path, rep: Report, from_skill_md: bool) -> None:
    text = strip_code(md.read_text(encoding="utf-8", errors="replace"))
    rel_name = md.relative_to(skill_dir).as_posix()
    for m in LINK_RE.finditer(text):
        target = m.group(1)
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("#"):
            continue  # URL, mailto:, anchor
        path_part = target.split("#", 1)[0].split("?", 1)[0]
        if not path_part:
            continue
        resolved = (md.parent / path_part).resolve()
        try:
            inside = resolved.relative_to(skill_dir.resolve())
        except ValueError:
            rep.err(f"{rel_name}: link '{target}' leaves the skill folder (name the sibling skill instead)")
            continue
        if not resolved.exists():
            rep.err(f"{rel_name}: broken link '{target}'")
            continue
        if from_skill_md and len(inside.parts) > 2:
            rep.err(f"{rel_name}: link '{target}' is more than one level deep (use references/<file>)")


def validate_skill(skill_dir: Path) -> Report:
    rep = Report(skill_dir.name)
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        rep.err("SKILL.md missing")
        return rep
    raw = skill_md.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        rep.warn("SKILL.md has a UTF-8 BOM")
    text = raw.decode("utf-8", errors="replace").lstrip("\ufeff")
    top, meta, body = parse_frontmatter(text, rep)
    raw_lines = top.pop("__raw__", {}) if top else {}

    if body is not None:
        for key in top:
            if key not in ALLOWED_KEYS:
                rep.err(f"frontmatter key '{key}' not allowed (allowed: {', '.join(sorted(ALLOWED_KEYS))})")
        name = top.get("name")
        if not isinstance(name, str) or not name:
            rep.err("name missing")
        else:
            if not NAME_RE.match(name):
                rep.err(f"name '{name}' does not match ^[a-z0-9]+(-[a-z0-9]+)*$")
            if len(name) > 64:
                rep.err(f"name longer than 64 chars ({len(name)})")
            if name != skill_dir.name:
                rep.err(f"name '{name}' != folder name '{skill_dir.name}'")
        desc = top.get("description")
        if not isinstance(desc, str) or not desc.strip():
            rep.err("description missing or empty")
        else:
            if len(desc) > 1024:
                rep.err(f"description longer than 1024 chars ({len(desc)})")
            if "Use when" not in desc:
                rep.err("description does not contain 'Use when'")
            if not str(raw_lines.get("description", "")).startswith('"'):
                rep.warn("description should be a single-line double-quoted string")
        comp = top.get("compatibility")
        if comp is not None:
            if not isinstance(comp, str):
                rep.err("compatibility must be a string")
            elif len(comp) > 500:
                rep.err(f"compatibility longer than 500 chars ({len(comp)})")
        if "metadata" in top and not isinstance(top["metadata"], dict):
            rep.err("metadata must be a map of string values")
        for k, v in meta.items():
            if v is not None and not isinstance(v, str):
                rep.err(f"metadata.{k} must be a string")

        # body length: ignore trailing blank lines
        while body and not body[-1].strip():
            body.pop()
        rep.body_lines = len(body)
        if rep.body_lines > BODY_HARD:
            rep.err(f"body has {rep.body_lines} lines (> {BODY_HARD})")
        elif not (BODY_MIN <= rep.body_lines <= BODY_MAX):
            rep.warn(f"body has {rep.body_lines} lines (target {BODY_MIN}-{BODY_MAX})")

    check_links(skill_md, skill_dir, rep, from_skill_md=True)
    ref_dir = skill_dir / "references"
    if ref_dir.is_dir():
        for sub in ref_dir.iterdir():
            if sub.is_dir():
                rep.err(f"references/{sub.name}/ is a subfolder; references must be one level deep")
        for md in sorted(ref_dir.glob("*.md")):
            check_links(md, skill_dir, rep, from_skill_md=False)

    for f in skill_dir.rglob("*"):
        if f.is_file() and f.stat().st_size > MAX_FILE:
            rel = f.relative_to(skill_dir).as_posix()
            size_kb = f.stat().st_size // 1024
            if f.suffix.lower() == ".csv":
                rep.warn(f"{rel} is {size_kb} KB (> 500 KB, csv allowed)")
            else:
                rep.err(f"{rel} is {size_kb} KB (> 500 KB)")
    return rep


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate skills/*/SKILL.md of the TX8 skill suite.")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent), help="repository root")
    ap.add_argument("--skill", action="append", default=[], help="validate only this skill (repeatable)")
    ap.add_argument("--quiet", action="store_true", help="print only problems and the summary")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    skills_root = repo / "skills"
    if not skills_root.is_dir():
        print(f"error: {skills_root} not found", file=sys.stderr)
        return 2

    total_err = 0
    total_warn = 0

    agents = repo / "shared" / "AGENTS.tx8.md"
    if not agents.is_file():
        print("ERROR shared/AGENTS.tx8.md missing")
        total_err += 1
    elif agents.stat().st_size >= MAX_AGENTS:
        print(f"ERROR shared/AGENTS.tx8.md is {agents.stat().st_size} bytes (must be < {MAX_AGENTS})")
        total_err += 1
    elif not args.quiet:
        print(f"OK    shared/AGENTS.tx8.md ({agents.stat().st_size} bytes)")

    dirs = sorted(d for d in skills_root.iterdir() if d.is_dir())
    if args.skill:
        dirs = [d for d in dirs if d.name in args.skill]
        missing = set(args.skill) - {d.name for d in dirs}
        for name in sorted(missing):
            print(f"ERROR skill '{name}' not found")
            total_err += 1

    rows = []
    for d in dirs:
        rep = validate_skill(d)
        total_err += len(rep.errors)
        total_warn += len(rep.warnings)
        for e in rep.errors:
            print(f"ERROR [{rep.name}] {e}")
        for w in rep.warnings:
            print(f"WARN  [{rep.name}] {w}")
        status = "FAIL" if rep.errors else ("WARN" if rep.warnings else "OK")
        rows.append((rep.name, status, rep.body_lines, len(rep.errors), len(rep.warnings)))

    print()
    print(f"{'Skill':<28} {'Status':<6} {'Body':>5} {'Err':>4} {'Warn':>5}")
    print(f"{'-' * 28} {'-' * 6} {'-' * 5} {'-' * 4} {'-' * 5}")
    for name, status, body, ne, nw in rows:
        print(f"{name:<28} {status:<6} {body:>5} {ne:>4} {nw:>5}")
    print()
    print(f"{len(rows)} skill(s), {total_err} error(s), {total_warn} warning(s)")
    return 1 if total_err else 0


if __name__ == "__main__":
    sys.exit(main())
