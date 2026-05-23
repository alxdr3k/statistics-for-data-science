#!/usr/bin/env python3
"""Bundle generators for legacy/thin/kernel modes.

v0.5.0: `legacy` and `thin` subcommands. `kernel` lands next.

`legacy` mode emits two distinct shapes:

  --variant manifest  (default, gate baseline)
                      include only entries with kind=required.
                      reproduces the dev-cycle read order as declared by
                      AGENTS.md / repo policy.

  --variant upper     (diagnostic upper bound, never used as gate)
                      include kind=required AND kind=conditional.
                      shows the theoretical maximum read cost.

`thin` mode is a deterministic heading-tree extractor over the same
manifest `required` set. No LLM calls. Three rules:

  Rule 1  small files (<= --small-threshold bytes, default 5KB):
          include entire file.
  Rule 2  matched sections: any markdown heading section whose body
          contains the literal task_id (or --phase keyword) is kept,
          along with its ancestor heading chain (parent context).
  Rule 3  always-include: every file gets at least its first heading
          section (intro/TOC), so the file's presence is visible even
          when no anchor matched.
  Fallback: if a file has no anchor match and no Rule-3 first section
            (e.g. headingless), keep its first --fallback-lines lines.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable


def parse_manifest(path: str):
    """TSV: kind<TAB>path-or-glob<TAB>reason

    kind: required | conditional
    path-or-glob: file path or glob pattern, repo-relative
    reason: free text, for drift tracking

    Lines starting with `#` and blank lines are ignored.
    """
    entries = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                print(f"bad manifest line (need at least 2 tab-fields): {raw!r}", file=sys.stderr)
                continue
            kind = parts[0].strip()
            target = parts[1].strip()
            reason = parts[2].strip() if len(parts) > 2 else ""
            if kind not in ("required", "conditional"):
                print(f"unknown manifest kind {kind!r}; skipping", file=sys.stderr)
                continue
            entries.append({"kind": kind, "path": target, "reason": reason})
    return entries


def expand_targets(repo: Path, entry: dict) -> Iterable[Path]:
    target = entry["path"]
    if any(ch in target for ch in "*?[]"):
        yield from sorted(repo.glob(target))
    else:
        p = repo / target
        if p.exists():
            yield p


def build_legacy_bundle(repo: Path, entries: list, include_conditional: bool):
    """Return (bundle_text, missing_required_paths).

    A `required` entry that resolves to zero existing files (including
    no-match globs) is reported in `missing_required_paths`. Callers
    should hard-fail if this list is non-empty: silent skip would let
    the gate baseline understate its real read cost.

    `conditional` entries silently skip on miss (by definition optional).
    """
    chunks = []
    missing_required = []
    for entry in entries:
        is_required = entry["kind"] == "required"
        if entry["kind"] == "conditional" and not include_conditional:
            continue
        resolved = list(expand_targets(repo, entry))
        if not resolved and is_required:
            missing_required.append(entry["path"])
            continue
        for path in resolved:
            try:
                rel = path.relative_to(repo)
            except ValueError:
                rel = path
            header = (
                f"=== {rel} "
                f"(kind={entry['kind']}, reason={entry['reason']}) ===\n"
            )
            try:
                body = path.read_text(encoding="utf-8")
            except Exception as e:
                body = f"[read error: {e}]\n"
            chunks.append(header)
            chunks.append(body)
            if not body.endswith("\n"):
                chunks.append("\n")
            chunks.append("\n")
    return "".join(chunks), missing_required


HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")


def parse_markdown_sections(text: str):
    """Segment text by ATX heading. Returns list of dicts:
       {level, heading, start_line, lines}
       The first segment may have level=0 (prelude before any heading).
    """
    sections = []
    current = {"level": 0, "heading": "(prelude)", "start_line": 1, "lines": []}
    for i, line in enumerate(text.splitlines(), start=1):
        m = HEADING_RE.match(line)
        if m:
            if current["lines"] or current["heading"] != "(prelude)":
                sections.append(current)
            current = {
                "level": len(m.group(1)),
                "heading": m.group(2),
                "start_line": i,
                "lines": [line],
            }
        else:
            current["lines"].append(line)
    if current["lines"]:
        sections.append(current)
    return sections


def ancestor_indices(sections, idx):
    """Indices of strictly-shallower heading sections preceding idx."""
    out = set()
    target_level = sections[idx]["level"]
    if target_level <= 1:
        return out
    cursor_level = target_level
    for j in range(idx - 1, -1, -1):
        lvl = sections[j]["level"]
        if 0 < lvl < cursor_level:
            out.add(j)
            cursor_level = lvl
            if cursor_level == 1:
                break
    return out


def narrow_to_window(section_lines, needles, window: int):
    """Return narrowed copy of section_lines keeping only lines within
    `window` lines of any needle hit. Non-adjacent kept ranges are joined
    with a '...' separator line. If no needle hits, returns the input as-is
    (caller decides whether the section is kept at all).
    """
    if not needles or window < 0:
        return section_lines, 0
    keep_idx = set()
    hits = 0
    for i, line in enumerate(section_lines):
        if any(n in line for n in needles):
            hits += 1
            for j in range(max(0, i - window), min(len(section_lines), i + window + 1)):
                keep_idx.add(j)
    if not keep_idx:
        return section_lines, 0
    out = []
    last = -2
    for i in sorted(keep_idx):
        if last >= 0 and i > last + 1:
            out.append("...")
        out.append(section_lines[i])
        last = i
    return out, hits


def extract_thin(
    path: Path,
    task_id: str,
    phase: str,
    small_threshold: int,
    fallback_lines: int,
    ancestor_cascade: bool = False,
    match_window: int = -1,
):
    """Returns (extracted_text, diagnostics_dict).

    Diagnostics include: rule_applied, total_bytes, kept_bytes,
    match_count_by_needle, sections_total, sections_kept.
    """
    raw = path.read_text(encoding="utf-8")
    total_bytes = len(raw.encode("utf-8"))

    diag = {
        "path": str(path),
        "total_bytes": total_bytes,
        "rule_applied": None,
        "kept_bytes": 0,
        "match_count_by_needle": {},
        "sections_total": 0,
        "sections_kept": 0,
    }

    needles = [n for n in (task_id, phase) if n]
    for n in needles:
        diag["match_count_by_needle"][n] = raw.count(n)

    # Rule 1: small file → whole.
    if total_bytes <= small_threshold:
        diag["rule_applied"] = "small_whole"
        diag["kept_bytes"] = total_bytes
        return raw, diag

    sections = parse_markdown_sections(raw)
    diag["sections_total"] = len(sections)
    keep = set()

    # Rule 2: anchor match. With cascade=False, only the matched section itself
    # is kept (no ancestor chain). This isolates the cascade contribution.
    for i, sec in enumerate(sections):
        body = "\n".join(sec["lines"])
        if any(n in body for n in needles):
            keep.add(i)
            if ancestor_cascade:
                keep |= ancestor_indices(sections, i)

    # Rule 3: always include the first heading section (intro/TOC).
    heading_indices = [i for i, s in enumerate(sections) if s["level"] > 0]
    if heading_indices:
        keep.add(heading_indices[0])
    if sections and sections[0]["level"] == 0:
        keep.add(0)

    if not keep:
        diag["rule_applied"] = "fallback_lines"
        head = "\n".join(raw.splitlines()[:fallback_lines])
        diag["kept_bytes"] = len(head.encode("utf-8"))
        return head, diag

    base_rule = (
        "section_match_with_cascade" if ancestor_cascade else "section_match_no_cascade"
    )
    diag["sections_kept"] = len(keep)

    # Identify which kept sections are "matched" (Rule 2) vs "first-section/prelude" (Rule 3).
    first_heading_idx = heading_indices[0] if heading_indices else None
    prelude_idx = 0 if (sections and sections[0]["level"] == 0) else None
    rule3_indices = {idx for idx in (first_heading_idx, prelude_idx) if idx is not None}

    parts = []
    narrowing_active = match_window >= 0
    total_hits_in_windows = 0
    sections_narrowed = 0
    for i in sorted(keep):
        sec_lines = sections[i]["lines"]
        # Only apply line-window narrowing to sections kept BY Rule 2 (anchor match).
        # Sections kept only because they are the always-include first section
        # (Rule 3) are left whole — that is an explicit Rule-3 contract.
        if narrowing_active and i not in rule3_indices:
            narrowed, hits = narrow_to_window(sec_lines, needles, match_window)
            if hits > 0:
                sec_lines = narrowed
                total_hits_in_windows += hits
                sections_narrowed += 1
            # If hits == 0 the section was kept only because Rule 3 also matched
            # this same index OR ancestor_cascade brought it in; keep whole.
        parts.append("\n".join(sec_lines))

    diag["rule_applied"] = (
        f"{base_rule}+window{match_window}" if narrowing_active else base_rule
    )
    diag["match_window"] = match_window
    diag["sections_narrowed"] = sections_narrowed
    diag["hits_in_windows"] = total_hits_in_windows
    joined = "\n\n".join(parts)
    diag["kept_bytes"] = len(joined.encode("utf-8"))
    return joined, diag


def cmd_thin(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    manifest_path = args.manifest or str(
        repo / ".project-state" / "measurements" / "legacy-paths.tsv"
    )
    if not Path(manifest_path).exists():
        print(f"manifest not found: {manifest_path}", file=sys.stderr)
        return 3

    entries = [
        e for e in parse_manifest(manifest_path) if e["kind"] == "required"
    ]
    if not entries:
        print(f"manifest has no required entries: {manifest_path}", file=sys.stderr)
        return 3

    missing_required = []
    chunks = []
    all_diags = []
    for entry in entries:
        resolved = list(expand_targets(repo, entry))
        if not resolved:
            missing_required.append(entry["path"])
            continue
        for path in resolved:
            extracted, diag = extract_thin(
                path,
                args.task_id,
                args.phase,
                args.small_threshold,
                args.fallback_lines,
                ancestor_cascade=args.ancestor_cascade,
                match_window=args.match_window,
            )
            all_diags.append(diag)
            try:
                rel = path.relative_to(repo)
            except ValueError:
                rel = path
            header = (
                f"=== {rel} (thin: task={args.task_id} phase={args.phase} "
                f"cascade={args.ancestor_cascade}) ===\n"
            )
            chunks.append(header)
            chunks.append(extracted)
            if not extracted.endswith("\n"):
                chunks.append("\n")
            chunks.append("\n")

    if missing_required:
        print(
            f"manifest declares required entries that do not exist under {repo}:",
            file=sys.stderr,
        )
        for p in missing_required:
            print(f"  - {p}", file=sys.stderr)
        print(
            "fix the manifest before measuring; silent skip would understate "
            "the thin baseline.",
            file=sys.stderr,
        )
        return 4

    bundle = "".join(chunks)
    if not bundle.strip():
        print("thin bundle is empty", file=sys.stderr)
        return 4

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(bundle, encoding="utf-8")

    if args.diagnostics_json:
        Path(args.diagnostics_json).write_text(
            json.dumps(
                {
                    "task_id": args.task_id,
                    "phase": args.phase,
                    "ancestor_cascade": args.ancestor_cascade,
                    "small_threshold": args.small_threshold,
                    "fallback_lines": args.fallback_lines,
                    "per_file": all_diags,
                    "total_kept_bytes": sum(d["kept_bytes"] for d in all_diags),
                    "total_source_bytes": sum(d["total_bytes"] for d in all_diags),
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

    return 0


def cmd_legacy(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    manifest_path = args.manifest or str(
        repo / ".project-state" / "measurements" / "legacy-paths.tsv"
    )
    if not Path(manifest_path).exists():
        print(f"manifest not found: {manifest_path}", file=sys.stderr)
        return 3

    entries = parse_manifest(manifest_path)
    if not entries:
        print(f"manifest is empty: {manifest_path}", file=sys.stderr)
        return 3

    include_conditional = args.variant == "upper"
    bundle, missing_required = build_legacy_bundle(repo, entries, include_conditional)

    if missing_required:
        print(
            f"manifest declares required entries that do not exist under {repo}:",
            file=sys.stderr,
        )
        for p in missing_required:
            print(f"  - {p}", file=sys.stderr)
        print(
            "fix the manifest (remove the entry or move it to conditional) "
            "before measuring; silent skip would understate the gate baseline.",
            file=sys.stderr,
        )
        return 4

    if not bundle.strip():
        print(
            f"bundle is empty; no manifest entries resolved to existing files "
            f"under {repo}",
            file=sys.stderr,
        )
        return 4

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(bundle, encoding="utf-8")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="bundles")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("legacy")
    p.add_argument("--repo", required=True)
    p.add_argument("--task-id", help="reserved for future conditional resolution")
    p.add_argument("--phase", help="reserved for future conditional resolution")
    p.add_argument("--manifest",
                   help="default: <repo>/.project-state/measurements/legacy-paths.tsv")
    p.add_argument("--variant", default="manifest", choices=["manifest", "upper"],
                   help="manifest=gate baseline (required only); "
                        "upper=diagnostic (required + conditional)")
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_legacy)

    p = sub.add_parser("thin")
    p.add_argument("--repo", required=True)
    p.add_argument("--task-id", required=True)
    p.add_argument("--phase", required=True)
    p.add_argument("--manifest",
                   help="default: <repo>/.project-state/measurements/legacy-paths.tsv")
    p.add_argument("--small-threshold", type=int, default=5 * 1024,
                   help="files smaller than this many bytes are included whole (default 5120)")
    p.add_argument("--fallback-lines", type=int, default=100,
                   help="for headingless files with no anchor match (default 100)")
    p.add_argument("--ancestor-cascade", action="store_true",
                   help="include ancestor heading sections when a descendant matches "
                        "(default off in S1)")
    p.add_argument("--match-window", type=int, default=-1,
                   help="S2-A: narrow each matched section to lines within N lines "
                        "of any needle hit (-1 = disabled, keep whole section)")
    p.add_argument("--diagnostics-json",
                   help="optional path: write per-file diagnostics as JSON")
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_thin)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
