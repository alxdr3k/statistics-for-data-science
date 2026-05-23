#!/usr/bin/env python3
"""Measurement toolchain for dev-cycle token tracking.

Schema: measurement/0.2.0 — see SCHEMA.md.

Subcommands:
  count-tokens     count tokens in stdin or --file
  cycle-start      start a new cycle, emit cycle_id on stdout
  cycle-end        end a cycle, append ended event to cycles.jsonl
  measure-bundle   measure a bundle (file or stdin), append usage event
  record-rework    append a rework_detected event (post-hoc, after cycle end)
"""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SCHEMA_NAME = "measurement"
SCHEMA_VERSION = "0.4.0"

DEFAULT_TOKENIZER = "cl100k_base"
DEFAULT_TARGET_MODEL = "claude-opus-4-7"

PHASE_CHOICES = [
    "sync",
    "discover",
    "implement",
    "verify",
    "review",
    "land",
    "unknown",
]

EVENT_KIND_CHOICES = [
    "read_compile",
    "event_emit",
    "validation",
    "revalidation",
    "reconciliation_check",
    "compile_failed",
]

MODE_CHOICES = ["legacy-manifest", "legacy-upper", "thin", "kernel"]
OUTCOME_CHOICES = ["merged", "abandoned", "next_iteration", "orphaned"]
STATUS_CHOICES = ["ok", "failed"]
ERROR_KIND_CHOICES = ["task_info_missing", "compile_error", "timeout", "other"]
REWORK_KIND_CHOICES = ["revert", "fix", "amend", "unknown"]

OUTPUT_ESTIMATION_FACTORS = {
    ("dev-cycle", "discover"): 0.05,
    ("dev-cycle", "implement"): 0.15,
    ("dev-cycle", "verify"): 0.08,
    ("dev-cycle", "review"): 0.10,
    ("dev-cycle", "land"): 0.03,
    ("dev-cycle", "sync"): 0.02,
}

# `legacy-manifest` is the canonical gate baseline (read-order-faithful).
# `legacy-upper` is a diagnostic upper bound: report only, never gate.
GATE_MODES = {"legacy-manifest", "thin", "kernel"}
DIAGNOSTIC_MODES = {"legacy-upper"}
DEFAULT_OUTPUT_FACTOR = 0.10


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_path_abs(repo: str) -> str:
    return str(Path(repo).resolve())


def repo_display(repo: str) -> str:
    return Path(repo).resolve().name


def project_state_dir(repo: str) -> Path:
    return Path(repo) / ".project-state" / "measurements"


def expected_schema_label() -> str:
    return f"{SCHEMA_NAME}/{SCHEMA_VERSION}"


def check_schema_compat(repo: str) -> None:
    """Reject if data dir has a different schema_version than this tool.

    Fresh dirs (no schema_version file yet) pass; cycle_start writes it.
    """
    sv = project_state_dir(repo) / "schema_version"
    if not sv.exists():
        return
    existing = sv.read_text().strip()
    expected = expected_schema_label()
    if existing != expected:
        print(
            f"schema_version mismatch in {sv}: file has {existing!r}, "
            f"tool is {expected!r}. Use a fresh data dir or migrate explicitly.",
            file=sys.stderr,
        )
        sys.exit(3)


def ensure_data_dir(repo: str) -> Path:
    check_schema_compat(repo)
    d = project_state_dir(repo)
    d.mkdir(parents=True, exist_ok=True)
    (d / "bundles").mkdir(exist_ok=True)
    (d / "reconciliation").mkdir(exist_ok=True)
    sv = d / "schema_version"
    if not sv.exists():
        sv.write_text(expected_schema_label() + "\n")
    return d


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def git_sha(repo: str) -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip()
    except Exception:
        return ""


def count_tokens(text: str) -> int:
    """tiktoken cl100k_base as Claude-proxy tokenizer.

    Absolute counts approximate; mode-to-mode comparisons stay consistent
    as long as the same tokenizer is used throughout.
    """
    try:
        import tiktoken
        enc = tiktoken.get_encoding(DEFAULT_TOKENIZER)
        return len(enc.encode(text))
    except ImportError:
        return max(1, len(text) // 4)


def cmd_count_tokens(args: argparse.Namespace) -> int:
    if args.file:
        text = Path(args.file).read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()
    print(count_tokens(text))
    return 0


def make_cycle_id() -> str:
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return f"c-{today}-{uuid.uuid4().hex[:8]}"


def cmd_cycle_start(args: argparse.Namespace) -> int:
    ensure_data_dir(args.repo)
    cycle_id = make_cycle_id()
    row = {
        "schema_name": SCHEMA_NAME,
        "schema_version": SCHEMA_VERSION,
        "ts": utc_now_iso(),
        "cycle_id": cycle_id,
        "parent_cycle_id": args.parent_cycle_id,
        "event": "started",
        "skill": args.skill,
        "repo": repo_display(args.repo),
        "repo_path": repo_path_abs(args.repo),
        "git_sha": git_sha(args.repo),
        "task_id": args.task_id,
        "notes": "",
    }
    append_jsonl(project_state_dir(args.repo) / "cycles.jsonl", row)
    print(cycle_id)
    return 0


def _find_cycle_event(repo: str, cycle_id: str, event: str) -> Optional[dict]:
    """Return the FIRST matching row. Callers wanting all matches should iterate."""
    path = project_state_dir(repo) / "cycles.jsonl"
    if not path.exists():
        return None
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("cycle_id") == cycle_id and row.get("event") == event:
                return row
    return None


def find_rework_for_pr(repo: str, cycle_id: str, pr_number: int) -> Optional[dict]:
    path = project_state_dir(repo) / "cycles.jsonl"
    if not path.exists():
        return None
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                row.get("cycle_id") == cycle_id
                and row.get("event") == "rework_detected"
                and row.get("rework_pr_number") == pr_number
            ):
                return row
    return None


def find_cycle_started(repo: str, cycle_id: str) -> Optional[dict]:
    return _find_cycle_event(repo, cycle_id, "started")


def find_cycle_ended(repo: str, cycle_id: str) -> Optional[dict]:
    return _find_cycle_event(repo, cycle_id, "ended")


def parse_ts(ts: str) -> datetime:
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def compute_bundle_revisit_count(repo: str, cycle_id: str) -> int:
    """4tuple (phase, mode, event_kind, phase_attempt) 중복 row 수."""
    path = project_state_dir(repo) / "usage.jsonl"
    if not path.exists():
        return 0
    buckets: dict = {}
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("cycle_id") != cycle_id:
                continue
            key = (
                row.get("phase"),
                row.get("mode"),
                row.get("event_kind"),
                row.get("phase_attempt"),
            )
            buckets[key] = buckets.get(key, 0) + 1
    return sum(c - 1 for c in buckets.values() if c > 1)


def cmd_cycle_end(args: argparse.Namespace) -> int:
    check_schema_compat(args.repo)
    started = find_cycle_started(args.repo, args.cycle_id)
    if not started:
        print(f"cycle_id not found: {args.cycle_id}", file=sys.stderr)
        return 2
    existing_end = find_cycle_ended(args.repo, args.cycle_id)
    if existing_end:
        print(
            f"cycle already ended: {args.cycle_id} at {existing_end['ts']} "
            f"(outcome={existing_end.get('outcome')}); refusing duplicate end",
            file=sys.stderr,
        )
        return 4

    proxy = {}
    if args.proxy_json:
        proxy = json.loads(Path(args.proxy_json).read_text(encoding="utf-8"))

    reconciliation = {}
    if args.reconciliation_json:
        reconciliation = json.loads(
            Path(args.reconciliation_json).read_text(encoding="utf-8")
        )

    bundle_revisit_count = proxy.get(
        "bundle_revisit_count",
        compute_bundle_revisit_count(args.repo, args.cycle_id),
    )

    row = {
        "schema_name": SCHEMA_NAME,
        "schema_version": SCHEMA_VERSION,
        "ts": utc_now_iso(),
        "cycle_id": args.cycle_id,
        "parent_cycle_id": started.get("parent_cycle_id"),
        "event": "ended",
        "skill": started.get("skill"),
        "repo": started.get("repo"),
        "repo_path": started.get("repo_path"),
        "git_sha": git_sha(args.repo),
        "task_id": args.task_id or started.get("task_id"),
        "outcome": args.outcome,
        "pr_number": args.pr_number,
        "phase_replay_count": int(proxy.get("phase_replay_count", 0)),
        "verify_failure_count": int(proxy.get("verify_failure_count", 0)),
        "bundle_revisit_count": int(bundle_revisit_count),
        "reconciliation_conflict_count": int(reconciliation.get("conflict_count", 0)),
        "resolve_attempt_count": int(reconciliation.get("attempt_count", 0)),
        "resolve_outcome": reconciliation.get("outcome"),
        "notes": args.notes or "",
    }
    append_jsonl(project_state_dir(args.repo) / "cycles.jsonl", row)
    return 0


def cmd_record_rework(args: argparse.Namespace) -> int:
    check_schema_compat(args.repo)
    ended = find_cycle_ended(args.repo, args.cycle_id)
    if not ended:
        print(
            f"cycle not ended yet (or cycle_id not found): {args.cycle_id}",
            file=sys.stderr,
        )
        return 2

    days_after_end = args.days_after_end
    if days_after_end is None:
        days_after_end = (datetime.now(timezone.utc) - parse_ts(ended["ts"])).days
    if days_after_end < 0:
        print(
            f"days_after_end is negative ({days_after_end}); "
            f"ended at {ended['ts']}, refusing rework record",
            file=sys.stderr,
        )
        return 4

    duplicate = find_rework_for_pr(args.repo, args.cycle_id, args.rework_pr_number)
    if duplicate:
        print(
            f"rework_detected already recorded for PR {args.rework_pr_number} "
            f"on cycle {args.cycle_id} at {duplicate['ts']}; refusing duplicate",
            file=sys.stderr,
        )
        return 4

    row = {
        "schema_name": SCHEMA_NAME,
        "schema_version": SCHEMA_VERSION,
        "ts": utc_now_iso(),
        "cycle_id": args.cycle_id,
        "event": "rework_detected",
        "skill": ended.get("skill"),
        "repo": ended.get("repo"),
        "repo_path": ended.get("repo_path"),
        "git_sha": git_sha(args.repo),
        "rework_pr_number": args.rework_pr_number,
        "rework_kind": args.rework_kind,
        "days_after_end": days_after_end,
        "notes": args.notes or "",
    }
    append_jsonl(project_state_dir(args.repo) / "cycles.jsonl", row)
    return 0


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def text_sha256(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def resolve_bundle_source(args: argparse.Namespace, repo: str, cycle_id: str):
    """Return (bundle_path_str, text, size_bytes, hash_str) or None for failure rows.

    `--bundle-file -` reads stdin and stores under bundles/<cycle_id>/<name>.txt
    if --bundle-store-as is given, otherwise a tempfile.
    """
    if args.bundle_file is None:
        return None

    if args.bundle_file == "-":
        text = sys.stdin.read()
        if args.bundle_store_as:
            dest_dir = project_state_dir(repo) / "bundles" / cycle_id
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = dest_dir / f"{args.bundle_store_as}.txt"
            dest.write_text(text, encoding="utf-8")
            bundle_path = str(dest)
        else:
            tmp = tempfile.NamedTemporaryFile(
                mode="w", suffix=".bundle.txt", delete=False, encoding="utf-8"
            )
            tmp.write(text)
            tmp.close()
            bundle_path = tmp.name
        size = len(text.encode("utf-8"))
        return bundle_path, text, size, text_sha256(text)

    p = Path(args.bundle_file)
    if not p.exists():
        return None
    text = p.read_text(encoding="utf-8")
    return str(p), text, p.stat().st_size, file_sha256(p)


def cmd_measure_bundle(args: argparse.Namespace) -> int:
    check_schema_compat(args.repo)
    started = find_cycle_started(args.repo, args.cycle_id)
    parent_cycle_id = started.get("parent_cycle_id") if started else None
    status = args.status

    if status == "failed":
        if not args.error_kind:
            print("--error-kind required when --status failed", file=sys.stderr)
            return 1
        bundle_path = None
        bundle_hash = None
        bundle_size_bytes = None
        input_tokens = None
        output_tokens = None
        output_tokens_estimated = None
        output_estimation_method = None
        error_kind = args.error_kind
        error_message_hash = (
            text_sha256(args.error_message) if args.error_message else None
        )
        event_kind = (
            "compile_failed" if args.event_kind == "read_compile" else args.event_kind
        )
        # 호출자가 event-kind를 compile_failed로 안 줬으면 강제 보정
        if args.event_kind != "compile_failed":
            event_kind = "compile_failed"
    else:
        src = resolve_bundle_source(args, args.repo, args.cycle_id)
        if src is None:
            print(f"bundle file not found: {args.bundle_file}", file=sys.stderr)
            return 1
        bundle_path, text, bundle_size_bytes, bundle_hash = src
        input_tokens = count_tokens(text)
        if args.output_tokens is not None:
            output_tokens = args.output_tokens
            output_tokens_estimated = None
            output_estimation_method = "measured"
        else:
            output_tokens = None
            factor = OUTPUT_ESTIMATION_FACTORS.get(
                (args.skill, args.phase), DEFAULT_OUTPUT_FACTOR
            )
            output_tokens_estimated = int(input_tokens * factor)
            output_estimation_method = "fixed_ratio"
        error_kind = None
        error_message_hash = None
        event_kind = args.event_kind

    row = {
        "schema_name": SCHEMA_NAME,
        "schema_version": SCHEMA_VERSION,
        "ts": utc_now_iso(),
        "cycle_id": args.cycle_id,
        "parent_cycle_id": parent_cycle_id,
        "skill": args.skill,
        "phase": args.phase,
        "phase_attempt": args.phase_attempt,
        "event_kind": event_kind,
        "mode": args.mode,
        "repo": repo_display(args.repo),
        "repo_path": repo_path_abs(args.repo),
        "git_sha": git_sha(args.repo),
        "task_id": args.task_id,
        "bundle_path": bundle_path,
        "bundle_hash": bundle_hash,
        "bundle_size_bytes": bundle_size_bytes,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "output_tokens_estimated": output_tokens_estimated,
        "output_estimation_method": output_estimation_method,
        "compile_ms": args.compile_ms,
        "tokenizer": args.tokenizer,
        "target_model": args.target_model,
        "status": status,
        "error_kind": error_kind,
        "error_message_hash": error_message_hash,
        "notes": args.notes or "",
    }
    append_jsonl(project_state_dir(args.repo) / "usage.jsonl", row)
    print(json.dumps(row, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="measurement")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("count-tokens")
    p.add_argument("--file")
    p.add_argument("--model", default=DEFAULT_TARGET_MODEL,
                   help="target_model label only; tokenizer is always cl100k_base")
    p.set_defaults(func=cmd_count_tokens)

    p = sub.add_parser("cycle-start")
    p.add_argument("--skill", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--task-id")
    p.add_argument("--parent-cycle-id")
    p.set_defaults(func=cmd_cycle_start)

    p = sub.add_parser("cycle-end")
    p.add_argument("--cycle-id", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--outcome", required=True, choices=OUTCOME_CHOICES)
    p.add_argument("--pr-number", type=int)
    p.add_argument("--task-id")
    p.add_argument("--proxy-json")
    p.add_argument("--reconciliation-json")
    p.add_argument("--notes")
    p.set_defaults(func=cmd_cycle_end)

    p = sub.add_parser("record-rework")
    p.add_argument("--cycle-id", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--rework-pr-number", type=int, required=True)
    p.add_argument("--rework-kind", required=True, choices=REWORK_KIND_CHOICES)
    p.add_argument("--days-after-end", type=int)
    p.add_argument("--notes")
    p.set_defaults(func=cmd_record_rework)

    p = sub.add_parser("measure-bundle")
    p.add_argument("--cycle-id", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--skill", required=True)
    p.add_argument("--phase", required=True, choices=PHASE_CHOICES)
    p.add_argument("--phase-attempt", type=int, default=1)
    p.add_argument("--event-kind", required=True, choices=EVENT_KIND_CHOICES)
    p.add_argument("--mode", required=True, choices=MODE_CHOICES)
    p.add_argument("--bundle-file", help="path or '-' for stdin (omit if status=failed and no bundle)")
    p.add_argument("--bundle-store-as",
                   help="when --bundle-file is '-', persist to bundles/<cycle_id>/<name>.txt")
    p.add_argument("--task-id")
    p.add_argument("--output-tokens", type=int)
    p.add_argument("--compile-ms", type=int)
    p.add_argument("--tokenizer", default=DEFAULT_TOKENIZER)
    p.add_argument("--target-model", default=DEFAULT_TARGET_MODEL)
    p.add_argument("--status", default="ok", choices=STATUS_CHOICES)
    p.add_argument("--error-kind", choices=ERROR_KIND_CHOICES)
    p.add_argument("--error-message")
    p.add_argument("--notes")
    p.set_defaults(func=cmd_measure_bundle)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
