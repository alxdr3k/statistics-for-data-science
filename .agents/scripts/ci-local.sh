#!/usr/bin/env bash
# Run the gating GitHub Actions CI jobs locally.
#
# This repo's CI is two workflow jobs:
#   - .github/workflows/doc-governance.yml  → `ruby scripts/check-doc-governance.rb`
#   - .github/workflows/docs-size-monitor.yml → bundle_legacy + count_tokens
#
# When GitHub Actions cannot run (e.g. private free-tier minutes exhausted),
# this script reproduces the *gating* parts of both jobs so a PR can still be
# verified locally before merge. It intentionally skips the non-gating side
# effects that require the GitHub API and never fail a job: PR comments,
# threshold issues, and artifact uploads.
#
# Faithful-mirror notes:
#   - doc-governance: the workflow runs the checker with full history
#     (`fetch-depth: 0`) for SHA ancestry verification. A local checkout has
#     full history, so this is a strict mirror. We actively STRIP any inherited
#     DOC_GOVERNANCE_SKIP_SHA_VERIFY (that waiver is for CI-only large repos) so
#     local results can never be weaker than CI.
#   - docs-size-monitor: CI installs tiktoken before measuring, so this script
#     REQUIRES tiktoken too and fails clearly if it is missing — otherwise
#     count_tokens silently falls back to a len/4 approximation that diverges
#     from CI's cl100k_base count.
#   - docs-size-monitor: the `measure` job only fails on the "Verify deployed
#     measurement tooling" step (missing tooling/manifest) or a bundle/count
#     error. Crossing THRESHOLD_TOKENS opens an issue but does NOT fail the
#     job, so this script reports over-threshold as a warning, not a failure —
#     matching CI exactly.
#
# Exit codes:
#   0 → all gating jobs passed (threshold warnings do not fail)
#   1 → a gating job failed (governance error, or missing/erroring measurement)
#   2 → usage error
#
# Usage:
#   scripts/ci-local.sh [--repo DIR]
#
# Env:
#   THRESHOLD_TOKENS  docs-size warn threshold (default 20000, matches workflow)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THRESHOLD_TOKENS="${THRESHOLD_TOKENS:-20000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ci-local: unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$REPO" && pwd)"
cd "$REPO"

fail=0
section() { printf '\n=== %s ===\n' "$1"; }

# --- Job 1: Doc Governance (doc-governance.yml → check) ---------------------
section "Job 1/2: doc-governance"
# CI runs the checker WITHOUT the SHA-skip waiver. If the developer's shell has
# DOC_GOVERNANCE_SKIP_SHA_VERIFY set, inheriting it would make the local mirror
# weaker than CI (report PASS while skipping SHA header existence/ancestry). So
# strip it for this call — local strictness must always match CI.
if [ -n "${DOC_GOVERNANCE_SKIP_SHA_VERIFY:-}" ]; then
  echo "ci-local: ignoring inherited DOC_GOVERNANCE_SKIP_SHA_VERIFY=${DOC_GOVERNANCE_SKIP_SHA_VERIFY} (CI runs without it)" >&2
fi
if [ ! -f scripts/check-doc-governance.rb ]; then
  echo "ci-local: scripts/check-doc-governance.rb not found" >&2
  fail=1
elif env -u DOC_GOVERNANCE_SKIP_SHA_VERIFY ruby scripts/check-doc-governance.rb; then
  echo "doc-governance: PASS"
else
  echo "doc-governance: FAIL" >&2
  fail=1
fi

# --- Job 2: Docs Size Monitor (docs-size-monitor.yml → measure) ------------
section "Job 2/2: docs-size-monitor"
TOOL_DIR="scripts/measurements"
MANIFEST=".project-state/measurements/legacy-paths.tsv"

# Mirror the workflow's "Verify deployed measurement tooling" step (the only
# gating failure path in the measure job).
if [ ! -x "$TOOL_DIR/bundle_legacy.sh" ]; then
  echo "ci-local: measurement tooling not found at $TOOL_DIR/bundle_legacy.sh" >&2
  fail=1
elif [ ! -f "$MANIFEST" ]; then
  echo "ci-local: manifest not found at $MANIFEST" >&2
  fail=1
elif ! python3 -c "import tiktoken" >/dev/null 2>&1; then
  # CI installs tiktoken (`pip install tiktoken`) before measuring; without it
  # count_tokens.sh silently falls back to a len/4 approximation that diverges
  # from CI's cl100k_base count (and can land on the wrong side of the
  # threshold). Fail clearly rather than report a weaker-than-CI number.
  echo "ci-local: tiktoken not importable — CI installs it; run: pip install tiktoken" >&2
  echo "ci-local: refusing to measure with the len/4 fallback (would diverge from CI)" >&2
  fail=1
else
  BUNDLE="$(mktemp -t my-skill-legacy-manifest.XXXXXX)"
  if "$TOOL_DIR/bundle_legacy.sh" --repo "$REPO" --variant manifest --output "$BUNDLE" \
     && TOK="$("$TOOL_DIR/count_tokens.sh" --file "$BUNDLE")"; then
    BYTES="$(wc -c < "$BUNDLE" | tr -d ' ')"
    echo "docs-size-monitor: legacy-manifest baseline = ${TOK} tokens (${BYTES} bytes)"
    echo "docs-size-monitor: threshold = ${THRESHOLD_TOKENS} tokens"
    if [ "$TOK" -gt "$THRESHOLD_TOKENS" ]; then
      # CI opens a compaction issue here but does NOT fail the job. Mirror that:
      # warn only.
      echo "docs-size-monitor: WARN — over threshold (non-gating, matches CI)" >&2
    fi
    echo "docs-size-monitor: PASS"
  else
    echo "docs-size-monitor: FAIL — bundle/count errored" >&2
    fail=1
  fi
  rm -f "$BUNDLE"
fi

# --- Summary ----------------------------------------------------------------
section "ci-local summary"
if [ "$fail" -eq 0 ]; then
  echo "ci-local: ALL GATING JOBS PASSED"
else
  echo "ci-local: ONE OR MORE GATING JOBS FAILED" >&2
fi
exit "$fail"
