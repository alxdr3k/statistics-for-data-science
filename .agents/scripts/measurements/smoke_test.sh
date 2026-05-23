#!/usr/bin/env bash
# Smoke test: runs the README quickstart end-to-end in a throwaway repo.
# Exit 0 if all steps succeed, non-zero otherwise.
set -e

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/measurement-smoke.XXXX)"
trap 'rm -rf "$TMP" "$TMP.proxy.json"' EXIT

cd "$TMP"
git init -q
git commit --allow-empty -q -m "init"

CID="$("$SCRIPTS/cycle_start.sh" --skill dev-cycle --repo "$TMP" --task-id TASK-123)"
echo "[smoke] cycle_id=$CID"

cat > legacy-discover.txt <<'EOF'
# fake legacy discover bundle
section 1 docs/context/current-state.md content
section 2 docs/04_IMPLEMENTATION_PLAN.md content
section 3 docs/current/CODE_MAP.md content
EOF

"$SCRIPTS/measure_bundle.sh" \
  --cycle-id "$CID" --repo "$TMP" \
  --skill dev-cycle --phase discover \
  --event-kind read_compile --mode legacy-manifest \
  --bundle-file legacy-discover.txt \
  --task-id TASK-123 --compile-ms 5 > /dev/null
echo "[smoke] measure_bundle legacy-manifest OK"

echo "fake thin compacted bundle" | \
  "$SCRIPTS/measure_bundle.sh" \
    --cycle-id "$CID" --repo "$TMP" \
    --skill dev-cycle --phase discover \
    --event-kind read_compile --mode thin \
    --bundle-file - --bundle-store-as thin-discover \
    --task-id TASK-123 --compile-ms 12 > /dev/null
echo "[smoke] measure_bundle thin (stdin) OK"

cat > "$TMP.proxy.json" <<'EOF'
{"phase_replay_count": 2, "verify_failure_count": 1}
EOF

"$SCRIPTS/cycle_end.sh" \
  --cycle-id "$CID" --repo "$TMP" \
  --outcome merged --pr-number 42 \
  --proxy-json "$TMP.proxy.json"
echo "[smoke] cycle_end OK"

"$SCRIPTS/record_rework.sh" \
  --cycle-id "$CID" --repo "$TMP" \
  --rework-pr-number 50 --rework-kind fix
echo "[smoke] record_rework (auto days) OK"

# verify written rows
ROWS=$(wc -l < .project-state/measurements/cycles.jsonl | tr -d ' ')
[ "$ROWS" = "3" ] || { echo "[smoke] FAIL: expected 3 cycles rows, got $ROWS"; exit 1; }

USAGE=$(wc -l < .project-state/measurements/usage.jsonl | tr -d ' ')
[ "$USAGE" = "2" ] || { echo "[smoke] FAIL: expected 2 usage rows, got $USAGE"; exit 1; }

echo "[smoke] all checks PASS"
