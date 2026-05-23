# Measurement Toolchain v0.4.0

`dev-cycle` 토큰 측정 도구. legacy-manifest / legacy-upper / thin / kernel 4 mode의 read+write 토큰을 cycle 단위로 비교. gate baseline은 `legacy-manifest`, `legacy-upper`는 diagnostic 전용.

상세 contract와 changelog는 [SCHEMA.md](./SCHEMA.md).

## 의존성

- Python 3.9+
- `tiktoken` (없으면 `len/4` fallback — 절대값 부정확, mode 비교는 가능)

```sh
pip3 install --user tiktoken
```

## 도구

| Script | 책임 |
|---|---|
| `count_tokens.sh` | 텍스트 → token count (cl100k_base proxy) |
| `cycle_start.sh` | 새 cycle 시작, `cycle_id` 발급 |
| `cycle_end.sh` | cycle 종료, proxy/reconciliation 기록. `bundle_revisit_count`는 4tuple 기준 자동 산출 |
| `measure_bundle.sh` | bundle (file 또는 `-`=stdin) → token count + hash → `usage.jsonl` append. `--status failed`로 compile failure도 기록 |
| `record_rework.sh` | cycle 종료 후 follow-up PR 발견 시 `rework_detected` event append (사후, ended row 불변) |
| `bundle_legacy.sh` | repo manifest로 legacy bundle 생성. `--variant manifest` (gate baseline) 또는 `--variant upper` (diagnostic) |
| `smoke_test.sh` | README quickstart end-to-end 검증 |

`measurement.py` (count/cycle/measure/rework) + `bundles.py` (bundle 생성기)로 책임 분리.

## 빠른 시작

```sh
SCRIPTS=/path/to/my-skill/scripts/measurements
REPO=/path/to/your/repo

# 1. cycle 시작
CID=$("$SCRIPTS/cycle_start.sh" --skill dev-cycle --repo "$REPO" --task-id TASK-123)
echo "$CID"   # → c-2026-05-23-a2db83fc

# 2. 매 phase 진입 시 mode별 bundle 만들고 측정 (shadow)
#    (bundle_legacy.sh / bundle_thin.sh / bundle_kernel.sh는 Day 2~3 작업)
"$SCRIPTS/measure_bundle.sh" \
  --cycle-id "$CID" --repo "$REPO" \
  --skill dev-cycle --phase discover \
  --event-kind read_compile --mode legacy-manifest \
  --bundle-file path/to/legacy-discover.txt \
  --task-id TASK-123 --compile-ms 5

# (thin/kernel mode도 같은 task에 대해 동일하게 호출)

# 3. cycle 종료 (PR merge 시점에)
cat > /tmp/proxy.json <<EOF
{"phase_replay_count": 2, "verify_failure_count": 1}
EOF
# bundle_revisit_count는 cycle_end가 4tuple 기준으로 자동 산출.
# cycle_rework_signal은 v0.3.0에서 제거됨 — 사후 rework는 record_rework.sh로 별도 event.

"$SCRIPTS/cycle_end.sh" \
  --cycle-id "$CID" --repo "$REPO" \
  --outcome merged --pr-number 42 \
  --proxy-json /tmp/proxy.json
```

데이터는 `$REPO/.project-state/measurements/` 아래 누적:
- `cycles.jsonl` — lifecycle events
- `usage.jsonl` — measurement events
- `bundles/<cycle_id>/` — bundle 본문 (선택)
- `schema_version` — 현재 데이터의 schema 버전

## Cycle outcome 4종

| outcome | 의미 |
|---|---|
| `merged` | PR 머지로 종료 |
| `abandoned` | PR close 또는 task drop |
| `next_iteration` | dev-cycle이 명시적으로 다음 task로 넘어감 |
| `orphaned` | 7일 무활동 timeout |

## 측정만 하고 LLM 호출 안 함

4 mode 중 실제 작업에 쓰이는 건 `legacy-manifest`만 (사용자가 평소 운영하는 방식의 manifest-faithful 재현). `legacy-upper`, `thin`, `kernel`은 같은 task에 대해 bundle만 만들고 token count만 — **LLM 호출 비용 0**.

shadow mode의 `output_tokens`는 항상 `null`. `legacy-manifest`도 wrapper hook 없으면 `output_tokens=null` + `output_tokens_estimated` (fixed_ratio).

## 다음 단계

- Day 2~3: `bundle_legacy.sh`, `bundle_thin.sh`, `bundle_kernel.sh` 작성
- Day 4~7: k-world-monitor에 shadow attach, dev-cycle iteration마다 자동 측정
- Day 8: `report.sh`로 집계, phase gate decision
