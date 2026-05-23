# Measurement Schema v0.4.0

```
schema_name: measurement
schema_version: 0.4.0
```

`dev-cycle` 토큰 측정을 위한 v0 contract. legacy-manifest / legacy-upper / thin / kernel 4 mode의 read+write 토큰을 cycle 단위로 비교 가능하게 만드는 것이 목표.

도구 자체는 skill-agnostic. v0 적용 범위는 `dev-cycle`만.

## Changelog

### 0.4.0 (2026-05-23)

GPT Day 2 보정 반영. baseline inflation 문제 차단.

Breaking:
- `mode` enum 변경: `legacy` 제거. `legacy-manifest`, `legacy-upper`, `thin`, `kernel`.
- `legacy-manifest`만 **gate baseline**으로 사용. `legacy-upper`는 diagnostic 전용이며 Decision Gate 결정에 직접 사용 금지.

Additions:
- `bundles.py` + `bundle_legacy.sh` — manifest 기반 legacy bundle 생성기.
- repo별 `legacy-paths.tsv` manifest 포맷 정의 (§11).
- `--variant manifest` (default, required only) vs `--variant upper` (required + conditional).

Rationale (k-world-monitor 실측):
- `legacy-upper`가 `legacy-manifest` 대비 **+61% (133K tokens)** 큼.
- upper를 gate baseline으로 쓰면 thin/kernel 절감률이 약 6 percentage points 부풀려짐.
- gate는 항상 manifest-faithful baseline 기준.

### 0.3.1 (2026-05-23)

GPT 3차 sanity check 반영. 데이터 무결성 invariants 강화.

Behavior changes:
- `cycle-end`가 이미 ended된 cycle에 대해 reject (exit 4). 첫 `ended` row가 canonical.
- `record-rework`가 `days_after_end < 0`이면 reject (exit 4). 시계 오류/잘못된 ended.ts로부터 보호.
- `record-rework`가 같은 `(cycle_id, rework_pr_number)` row가 이미 있으면 reject (exit 4). 중복 record 방지.

Exit codes (정리):
- 0: success
- 1: I/O / 인자 에러
- 2: cycle_id / ended cycle 없음
- 3: schema_version mismatch
- 4: invariant violation (duplicate end / negative days / duplicate rework PR)

Additions:
- `smoke_test.sh` — README quickstart 그대로 실행하는 end-to-end 검증 스크립트.

Clarifications:
- `find_cycle_ended` / `find_cycle_started`는 동일 cycle_id 내 **첫** 매칭 row 반환. cycle_end의 invariant 강화로 ended는 항상 0개 또는 1개.
- schema mismatch check는 mutating subcommand (cycle-start/end, measure-bundle, record-rework)에만 적용. `count-tokens`는 read-only이므로 적용 안 함.

### 0.3.0 (2026-05-23)

GPT 2차 리뷰 반영 (P1×2 + P2×4).

Breaking:
- `record_rework`는 **ended cycle만** 받음. started-only cycle에 대한 rework_detected append는 거부 (exit 2).
- 모든 mutating subcommand가 호출 시점에 `schema_version` 호환 검사. mismatch면 reject (exit 3). 이전 v0.2는 다른 버전을 조용히 overwrite.

Additions:
- `rework_detected` row에 `skill`, `repo`, `repo_path`, `git_sha` 추가 (이전엔 cycle_id로만 join 가능).
- `usage.jsonl` row의 `parent_cycle_id`가 cycle_started row에서 자동 lookup. nested attribution 작동.

Fixes:
- `record_rework`가 `--days-after-end` 생략 시 ended.ts와 현재 시각으로 자동 계산 (이전엔 null로 기록).
- README quickstart가 `discover` phase 사용 (이전 `discovery`는 v0.2 enum에서 reject).

### 0.2.0 (2026-05-23)

GPT 리뷰 반영 (P1×4 + P2×4).

Breaking:
- `phase` enum 변경: `discovery` → `discover`. `sync` 추가. `unknown` fallback.
- `cycles.jsonl` ended event에서 `cycle_rework_signal` 필드 제거. 사후 신호는 새 `rework_detected` event로.
- `tokenizer_model` 필드 분리: `tokenizer` + `target_model`.

Additions:
- 모든 row에 `schema_name` 필드 추가.
- 모든 row에 `repo_path` 필드 추가 (절대경로). 기존 `repo`는 display name.
- `usage.jsonl`에 `event_kind: "compile_failed"` 추가. failure row 명시.
- failure row 필드: `error_kind`, `error_message_hash`. token/hash/size는 null 허용.
- `cycles.jsonl`에 새 event type: `rework_detected` (cycle 종료 후 사후 append).
- `measure-bundle`이 `--bundle-file -`로 stdin 수용 (write payload 측정용).

Clarifications:
- `bundle_revisit_count`: `(cycle_id, phase, mode, event_kind, phase_attempt)` 4tuple이 동일한 row가 2개 이상일 때만 카운트. shadow 3-mode 측정은 mode가 다르므로 제외.
- v0 decision gate는 read-side 측정만으로 1차 결정. write payload 측정은 가능하지만 "참고용".

### 0.1.0 (2026-05-23)

초안.

## 1. Non-goals (v0)

- output token 정확 측정 — wrapper hook 도착 시 추가
- `reconciliation_resolve` 토큰 attribution — state provider 정식 구현 후
- multi-skill 적용 — verify/sitrep은 wave 2
- completeness 명시 측정 Tier 2/3 — 자동 skill에 부적합
- `bundle_supplement_count` proxy — tool call hook 필요
- 자동 schema migration tool
- billing-grade 정확도 — 상대 비교에 충분한 정확도만

## 2. Cycle Lifecycle

`cycle` = task attempt 1회.

```
None
  └─[new task entered]─→ started
started
  ├─[PR merged]─────────→ ended (outcome=merged)
  ├─[PR closed/dropped]─→ ended (outcome=abandoned)
  ├─[next task taken]───→ ended (outcome=next_iteration)
  └─[7d no activity]────→ ended (outcome=orphaned)

ended
  └─[delayed: follow-up PR detected within N days]
                        └─→ rework_detected (append-only sidecar event)
```

같은 task 내부 `implement → verify` 반복은 cycle end 아님. `phase_replay_count`로만 기록.

**nested cycle**: 큰 cycle 안에 sub-cycle 가능 (`parent_cycle_id`). 예: dev-cycle 안에서 `codex` 서브 job이 자체 cycle 보유.

**cycle_id 형식**: `c-YYYY-MM-DD-<8자 hex>` (예: `c-2026-05-23-7f3a91b2`).

## 3. Data Layout

도구 (canonical):
```
my-skill/scripts/measurements/
  SCHEMA.md (this file)
  measurement.py
  count_tokens.sh
  cycle_start.sh
  cycle_end.sh
  measure_bundle.sh
  record_rework.sh
  report.sh                # (deferred to Day 8)
  bundle_legacy.sh         # (deferred to Day 2-3)
  bundle_thin.sh           # (deferred to Day 2-3)
  bundle_kernel.sh         # (deferred to Day 2-3)
```

데이터 (per-repo):
```
<repo>/.project-state/measurements/
  schema_version             # "measurement/0.2.0" 표기
  cycles.jsonl               # lifecycle + delayed events
  usage.jsonl                # measurement events (ok + failed)
  bundles/<cycle_id>/
    <mode>-<phase>.txt
    <mode>-<phase>.meta.json
  reconciliation/
    <ts>-<cycle_id>.json     # deferred, v0에선 count만
```

데이터 디렉토리는 git ignore 권장. `schema_version` 파일만 commit.

## 4. Schemas

### 4.1 cycles.jsonl

lifecycle event 1개 = 1줄. 3가지 event type: `started`, `ended`, `rework_detected`.

#### started

```json
{
  "schema_name": "measurement",
  "schema_version": "0.4.0",
  "ts": "2026-05-23T12:34:56Z",
  "cycle_id": "c-2026-05-23-7f3a91b2",
  "parent_cycle_id": null,
  "event": "started",
  "skill": "dev-cycle",
  "repo": "k-world-monitor",
  "repo_path": "/Users/yngn/ws/k-world-monitor",
  "git_sha": "abc1234",
  "task_id": "INFRA-1A.x-...",
  "notes": ""
}
```

#### ended

```json
{
  "schema_name": "measurement",
  "schema_version": "0.4.0",
  "ts": "2026-05-23T18:00:00Z",
  "cycle_id": "c-2026-05-23-7f3a91b2",
  "parent_cycle_id": null,
  "event": "ended",
  "skill": "dev-cycle",
  "repo": "k-world-monitor",
  "repo_path": "/Users/yngn/ws/k-world-monitor",
  "git_sha": "def5678",
  "task_id": "INFRA-1A.x-...",
  "outcome": "merged|abandoned|next_iteration|orphaned",
  "pr_number": 123,
  "phase_replay_count": 3,
  "verify_failure_count": 2,
  "bundle_revisit_count": 1,
  "reconciliation_conflict_count": 0,
  "resolve_attempt_count": 0,
  "resolve_outcome": null,
  "notes": ""
}
```

- `outcome` 필수.
- count 필드는 cycle 누적값.
- `pr_number`는 outcome이 merged/abandoned일 때.
- `cycle_rework_signal`은 **제거됨** — 사후 신호는 `rework_detected` event로.

#### rework_detected (사후 append)

cycle 종료 후 N일 이내 follow-up PR이 발견되면 별도 row append. 절대 ended row 수정하지 않음.

**Preconditions**:
- `cycle_id`의 `ended` event가 cycles.jsonl에 있어야 한다. `started`만 있는 cycle에 대한 호출은 거부 (exit 2).
- `days_after_end` 생략 시 `ended.ts`와 현재 시각으로 자동 계산.

```json
{
  "schema_name": "measurement",
  "schema_version": "0.4.0",
  "ts": "2026-05-26T09:15:00Z",
  "cycle_id": "c-2026-05-23-7f3a91b2",
  "event": "rework_detected",
  "skill": "dev-cycle",
  "repo": "k-world-monitor",
  "repo_path": "/Users/yngn/ws/k-world-monitor",
  "git_sha": "def5678",
  "rework_pr_number": 130,
  "rework_kind": "revert|fix|amend|unknown",
  "days_after_end": 3,
  "notes": ""
}
```

reader는 cycle 집계 시 ended row에 rework_detected 정보를 join. ended row 자체는 불변.

### 4.2 usage.jsonl

measurement event 1개 = 1줄. `event_kind`가 `ok` 측정인지 `compile_failed`인지 구분.

#### ok 측정

```json
{
  "schema_name": "measurement",
  "schema_version": "0.4.0",
  "ts": "2026-05-23T12:34:56Z",
  "cycle_id": "c-2026-05-23-7f3a91b2",
  "parent_cycle_id": null,
  "skill": "dev-cycle",
  "phase": "sync|discover|implement|verify|review|land|unknown",
  "phase_attempt": 1,
  "event_kind": "read_compile|event_emit|validation|revalidation|reconciliation_check",
  "mode": "legacy-manifest|legacy-upper|thin|kernel",
  "repo": "k-world-monitor",
  "repo_path": "/Users/yngn/ws/k-world-monitor",
  "git_sha": "abc1234",
  "task_id": "INFRA-1A.x-...",
  "bundle_path": ".project-state/measurements/bundles/c-.../thin-discover.txt",
  "bundle_hash": "sha256:...",
  "bundle_size_bytes": 18234,
  "input_tokens": 4521,
  "output_tokens": null,
  "output_tokens_estimated": 678,
  "output_estimation_method": "fixed_ratio|measured|null",
  "compile_ms": 142,
  "tokenizer": "cl100k_base",
  "target_model": "claude-opus-4-7",
  "status": "ok",
  "notes": ""
}
```

#### compile_failed

```json
{
  "schema_name": "measurement",
  "schema_version": "0.4.0",
  "ts": "2026-05-23T12:34:56Z",
  "cycle_id": "c-2026-05-23-7f3a91b2",
  "parent_cycle_id": null,
  "skill": "dev-cycle",
  "phase": "discover",
  "phase_attempt": 1,
  "event_kind": "compile_failed",
  "mode": "kernel",
  "repo": "k-world-monitor",
  "repo_path": "/Users/yngn/ws/k-world-monitor",
  "git_sha": "abc1234",
  "task_id": "INFRA-1A.x-...",
  "bundle_path": null,
  "bundle_hash": null,
  "bundle_size_bytes": null,
  "input_tokens": null,
  "output_tokens": null,
  "output_tokens_estimated": null,
  "output_estimation_method": null,
  "compile_ms": 17,
  "tokenizer": "cl100k_base",
  "target_model": "claude-opus-4-7",
  "status": "failed",
  "error_kind": "task_info_missing|compile_error|timeout|other",
  "error_message_hash": "sha256:...",
  "notes": ""
}
```

failure row는 report 집계 시 mode별 success rate 산출에 사용. 단순 평균에서 빠지지 않도록 함 (survivor bias 방지).

### 4.3 Enum 정의

**phase** (closed):
- `sync` — repo sync, branch alignment
- `discover` — context bundle 컴파일, next-task 결정
- `implement` — 코드 변경
- `verify` — test/lint/build 검증
- `review` — self-review, codex review
- `land` — PR open/merge
- `unknown` — 분류 안 됨 (fallback)

**event_kind** (closed):
- `read_compile` — context bundle을 LLM 입력으로 (read-side)
- `event_emit` — typed state mutation payload (write-side, state kernel용)
- `validation` — validation command 출력 토큰화
- `revalidation` — lazy marker resolve용 재compile
- `reconciliation_check` — snapshot↔events 일치 검증 (v0 deterministic, 토큰 0)
- `compile_failed` — bundle compile 실패 (mode별 success rate 추적용)

**mode** (closed):
- `legacy-manifest` — repo manifest의 `required` 항목만으로 만든 bundle. **canonical gate baseline**. dev-cycle이 실제로 읽는 read order를 충실히 재현.
- `legacy-upper` — manifest의 `required` + `conditional` 모두 포함한 bundle. **diagnostic only**, Decision Gate에 직접 사용 금지. 절감률 상한 참고용.
- `thin` — frontmatter+deterministic compiler bundle (shadow)
- `kernel` — state kernel bundle (shadow)

**gate vs diagnostic**:
- gate modes: `legacy-manifest`, `thin`, `kernel` — Decision Gate 비교에 사용.
- diagnostic modes: `legacy-upper` — report에만 노출, gate 의사결정에 직접 사용 금지.

**outcome** (closed): `merged`, `abandoned`, `next_iteration`, `orphaned`

**status** (closed): `ok`, `failed`

**error_kind** (closed): `task_info_missing`, `compile_error`, `timeout`, `other`

**rework_kind** (closed): `revert`, `fix`, `amend`, `unknown`

**output_estimation_method**: `fixed_ratio`, `measured`, `null`

## 5. Proxy Definitions (v0)

cycles.jsonl ended event에 누적값으로 기록.

| Proxy | 의미 | 수집 방법 | v0 reliable |
|---|---|---|---|
| `phase_replay_count` | cycle 내 phase 재실행 총 횟수 | dev-cycle skill 내부 counter | ✅ |
| `verify_failure_count` | verify phase가 fail한 횟수 | phase transition log | ✅ |
| `bundle_revisit_count` | 같은 4tuple `(cycle_id, phase, mode, event_kind, phase_attempt)` 중복 row 수 | usage.jsonl 사후 집계 | ✅ |
| `rework_detected` (event) | 사후 N일 내 follow-up PR | cycles.jsonl rework_detected event 별도 append | ✅ (delayed) |
| `bundle_supplement_count` | phase 내 추가 file read/grep 횟수 | tool call hook 필요 | ⚠️ deferred |

**bundle_revisit_count 정의 (clarified)**:
- shadow protocol은 legacy-manifest/legacy-upper/thin/kernel 4 mode를 같은 phase에 측정 → 정상. revisit 아님.
- 같은 cycle/phase/mode/event_kind/phase_attempt에서 두 번째 row가 발견되면 +1.
- 사후 집계로 산출. cycle ended event에 누적값 기록 (또는 report.sh가 매번 계산).

**해석 가이드**:
- mode 비교 시 토큰 같아도 proxy 신호 적은 mode가 승
- 토큰 절감 ≥ 10% AND proxy 신호 동등 이하 → 채택 근거
- 토큰 절감 ≥ 10% BUT proxy 신호 증가 → completeness 손실 가능성

## 6. Reconciliation v0

cycles.jsonl ended event에 누적값으로 기록. token attribution 없음.

```
reconciliation_conflict_count: int
resolve_attempt_count: int
resolve_outcome: "resolved" | "unresolved" | "deferred" | null
```

토큰 attribution은 state provider 정식 구현 후 추가.

## 7. Tooling Contract

각 script의 입출력 contract.

### 7.1 count_tokens.sh

```
용도: 텍스트 → token count
입력: stdin 또는 --file <path>
옵션: --model <name>   # default: claude-opus-4-7 (target_model 라벨, 실제 tokenizer는 cl100k_base)
출력: stdout에 integer
exit: 0 성공, 1 실패
```

### 7.2 cycle_start.sh

```
입력:
  --skill <name>             # 필수
  --repo <path>              # 필수
  --task-id <id>             # 선택
  --parent-cycle-id <id>     # 선택
출력: stdout에 cycle_id
exit: 0 성공
```

### 7.3 cycle_end.sh

```
입력:
  --cycle-id <id>                                    # 필수
  --repo <path>                                      # 필수
  --outcome merged|abandoned|next_iteration|orphaned # 필수
  --pr-number <n>                                    # outcome=merged/abandoned일 때
  --task-id <id>                                     # 선택
  --proxy-json <path>                                # phase_replay_count 등 누적값
  --reconciliation-json <path>                       # 선택
  --notes <text>                                     # 선택
출력: 없음
exit: 0 성공, 2 cycle_id 못찾음
```

### 7.4 measure_bundle.sh

```
입력:
  --cycle-id <id>                       # 필수
  --repo <path>                         # 필수
  --skill <name>                        # 필수
  --phase <name>                        # 필수 (enum)
  --phase-attempt <n>                   # default: 1
  --event-kind <kind>                   # 필수 (enum, compile_failed 포함)
  --mode <legacy-manifest|legacy-upper|thin|kernel>  # 필수
  --bundle-file <path>                  # 필수 (- 이면 stdin → temp file)
  --task-id <id>                        # 선택
  --output-tokens <n>                   # 선택
  --compile-ms <n>                      # 선택
  --tokenizer <name>                    # default: cl100k_base
  --target-model <name>                 # default: claude-opus-4-7
  --status <ok|failed>                  # default: ok
  --error-kind <kind>                   # status=failed일 때
  --error-message <text>                # status=failed일 때 (해시만 저장)
  --notes <text>                        # 선택
출력: usage.jsonl row (stdout echo)
exit: 0 성공
```

**stdin mode**: `--bundle-file -`이면 stdin을 읽어 임시 파일에 저장한 뒤 측정. `bundle_path`는 임시 파일 경로 또는 `--bundle-store-as <name>` 지정 시 `bundles/<cycle_id>/<name>.txt`로 저장.

**failure mode**: `--status failed` + `--error-kind` 필수. `--bundle-file`은 옵셔널 (없으면 token/hash/size 모두 null).

### 7.5 record_rework.sh

```
용도: cycle 종료 후 follow-up PR 발견 시 rework_detected event append.
      cycle이 ended 되어야만 동작. started-only cycle은 거부 (exit 2).
입력:
  --cycle-id <id>            # 필수
  --repo <path>              # 필수
  --rework-pr-number <n>     # 필수
  --rework-kind <kind>       # 필수 (enum: revert|fix|amend|unknown)
  --days-after-end <n>       # 선택. 생략 시 ended.ts와 현재 시각으로 자동 계산.
  --notes <text>             # 선택
출력: 없음
exit: 0 성공, 2 cycle ended 안 됨/cycle_id 없음, 3 schema_version mismatch
```

### 7.6 bundle_legacy.sh

```
용도: repo manifest로부터 legacy bundle 생성
입력:
  --repo <path>                       # 필수
  --variant manifest|upper            # default: manifest
  --manifest <path>                   # default: <repo>/.project-state/measurements/legacy-paths.tsv
  --output <path>                     # 필수
  --task-id <id>                      # 예약 (v0에선 미사용)
  --phase <name>                      # 예약 (v0에선 미사용)
출력: 없음 (--output 파일에 bundle 본문)
exit:
  0 성공
  3 manifest 없음 또는 비었음
  4 manifest의 required entry 중 실제 파일이 없는 항목 있음 (silent skip 금지)
  4 manifest는 있지만 어떤 entry도 실제 파일로 해소되지 않음
```

required entry가 missing이면 hard fail. 사용자는 manifest를 정정 (entry 제거 또는 conditional로 강등)해야 함. conditional entry의 missing은 silent skip (조건부니까 없을 수 있음).

bundle 본문은 각 entry마다 `=== <relpath> (kind=<k>, reason=<r>) ===` 헤더 + 파일 내용 + 빈 줄로 구성. concat 순서는 manifest TSV 순서.

### 7.7 bundle_thin.sh / bundle_kernel.sh

Day 3 작업. v0.4.0 시점에는 미구현.

### 7.7 report.sh

Day 8 작업. Group-by mode|phase|skill|cycle, mean/median/p95, failure rate, rework rate 산출.

## 8. Schema Versioning

semver. `MAJOR.MINOR.PATCH`.

- **PATCH**: 문서 정정, non-breaking
- **MINOR**: 새 필드 추가 (optional). 기존 reader 호환.
- **MAJOR**: 필드 제거, enum 값 제거, 의미 변경. reader 강제 업데이트.

각 row에 `schema_name="measurement"` + `schema_version` 박음.

| Mismatch | reader 동작 |
|---|---|
| `schema_name` 다름 | reject |
| MAJOR 다름 | reject |
| MINOR `row > reader` | unknown field ignore |
| MINOR `row < reader` | default 적용 |
| PATCH 다름 | 무시 |

v0.4.0은 v0이라 운영 시작 전 → breaking change 허용. v1.0.0은 첫 dogfood 1주 + lessons 반영 후.

**도구의 schema 호환 검사**: 모든 mutating subcommand (cycle-start / cycle-end / measure-bundle / record-rework)는 호출 시점에 `<repo>/.project-state/measurements/schema_version` 파일을 확인하고, 도구의 expected label (`measurement/0.4.0`)과 다르면 exit 3로 거부한다. fresh 디렉토리 (schema_version 파일 없음)는 통과하고, cycle-start가 새 label을 쓴다. mixed-version 데이터를 조용히 만들지 않는다.

## 9. v0 → v1 진입 조건

- k-world-monitor에 1주 shadow 측정 누적
- 최소 20 cycle 데이터 (rework_detected 포함하면 1개월+ 관찰 필요)
- mode별 input_tokens 분포 안정 (p95/median 비율 일관)
- bundle_thin / bundle_kernel 정확도 검토 완료
- proxy 4종이 실제 신호 보임
- failure rate가 mode별로 명백 차이 (kernel이 너무 자주 fail하면 별도 판단)

위 조건 만족 시 v1: lessons 반영 + reconciliation attribution + multi-skill 확장 + frontmatter parser hook 정식화.

## 10. Decision Gate (data-driven)

shadow 측정 1주 후. **v0 gate는 read-side 측정만으로 1차 결정**. write payload 측정은 가능하지만 참고용.

**중요**: 모든 비교의 baseline은 `legacy-manifest`만. `legacy-upper`는 diagnostic 전용이며 gate에 직접 사용하지 않음 (k-world 실측 결과 upper가 manifest보다 +61% 큼).

| 조건 | 결정 |
|---|---|
| thin이 `legacy-manifest` 대비 read 합산 ≥ 30% 절감 AND proxy 동등 이하 AND failure rate 동등 이하 | thin compiler 정식 도입 |
| kernel이 thin 대비 추가 ≥ 10% 절감 AND proxy 동등 이하 AND failure rate 동등 이하 | state kernel 정식 진입 (Phase 2) |
| thin이 `legacy-manifest` 대비 < 10% 절감 | 측정 방법 재검토 또는 기존 markdown 유지 |
| kernel이 thin 대비 < 5% 절감 | state kernel 보류 |
| kernel이 thin보다 명백히 높은 failure rate | 토큰 절감 무관하게 보류 |
| proxy 신호가 mode별 명백 차이 | 토큰 절감과 분리해서 평가 |
| rework_detected 비율이 mode별 명백 차이 | 4주 추적 후 재평가 |

`legacy-upper`는 별도 report 라인에 "diagnostic upper bound" 라벨로만 노출. 절감률 자랑/비교에 쓰지 않음.

write-side 측정 데이터가 read-side와 다른 결론을 시사하면 v1에서 정식 gate에 포함.

## 11. Legacy Manifest Format

`<repo>/.project-state/measurements/legacy-paths.tsv`

```
# header comments allowed (#-prefix), blank lines ignored
# format: kind<TAB>path-or-glob<TAB>reason

required	docs/context/current-state.md	always: active milestone/blockers
required	docs/04_IMPLEMENTATION_PLAN.md	always: status ledger
required	docs/current/CODE_MAP.md	always per repo AGENTS.md
conditional	docs/11_CI_CD.md	CI/CD or required check changes
conditional	docs/adr/*.md	architecture/scope decision changes
```

필드:
- `kind`: `required` | `conditional`
  - `required`: dev-cycle이 항상 읽는 docs. gate baseline에 항상 포함.
  - `conditional`: task 종류/scope에 따라 선택적으로 읽는 docs. v0 manifest variant에는 미포함, upper variant에만 포함.
- `path-or-glob`: repo-relative. glob 지원 (`*`, `?`, `[]`).
- `reason`: drift 추적용. AGENTS.md의 어느 read order 항목에서 왔는지 명시 권장.

`source: AGENTS.md` 등 출처 메타는 파일 상단 주석으로 기록. AGENTS.md의 Read order가 바뀌면 manifest도 동기 갱신.

v0에서는 manifest를 사람이 직접 작성. v1에서 AGENTS.md 파서로 자동 생성 검토.
