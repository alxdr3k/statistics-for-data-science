---
name: run
description: "단일 진입점 — run-registry로 active-run collision guard + register 후 전체 개발 사이클(sync → discover → implement → verify → review → land)을 실행하고 exit 시 release. dev-cycle 흡수(DEC-049). 플래그: --loop [N], --phase <id>, --opus-review, --opus-audit-every <N>"
---

# /run

`/run`은 단일 에이전트 개발 사이클의 **단일 진입점**이다. `scripts/run-registry.sh`로
현재 작업 세션을 register하고 (같은 logical repo의 두 번째 run을 collision으로
거부), 이어서 전체 개발 사이클(sync → discover → implement → verify → review →
land)을 실행한 뒤 exit 시 release한다. dev-cycle 커맨드를 흡수한 결과다(DEC-049)
— 별도 `/dev-cycle`은 더 이상 없다.

사용자에게 보이는 보고/에러/안내는 한국어로 작성한다. 명령, 파일명, JSON 키,
helper 인자는 원문 언어를 유지한다.

## 호출 표면

- 단일 에이전트: `/run "<topic 또는 task 요약>"`
- 멀티 에이전트(`/run-team`)는 본 커맨드 범위 밖이다 (PA-3.1). 첫 인자가 `--team`
  또는 `-team` literal flag form이면 즉시 안내 후 종료한다 (DEC-030 D6):

  ```
  ERROR: --team is not a valid flag for /run. Did you mean /run-team?
         (/run-team is tracked under PA-3.1 and is not implemented yet.)
  ```

  bare `team`이 첫 인자면 topic으로 받는다 (예: `/run "team productivity"`).

## 진입 시퀀스 (register → 개발 사이클 → release)

개발 사이클(아래 Flags ~ Loop) 본문에 들어가기 전에 run-registry로 세션을
등록한다. 이 진입부는 cooperative layer만 강제한다 (DEC-032) — 실제 `git switch
main` 거부는 run-helper sync guard가, merge 거부는 land-pr helper가 담당한다.

### run-registry 경로 resolution

워크플로 helper(`run-helper.sh`, 아래 Invariants)와 별개로 register/collision은
`run-registry.sh`가 담당한다. 둘 다 repo-local → user-level 순서로 찾는다.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
RUN_REGISTRY=""
if [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/.agents/scripts/run-registry.sh" ]; then
  RUN_REGISTRY="$REPO_ROOT/.agents/scripts/run-registry.sh"
elif [ -x "$HOME/.agents/scripts/run-registry.sh" ]; then
  RUN_REGISTRY="$HOME/.agents/scripts/run-registry.sh"
else
  echo "Missing run-registry.sh"; exit 4
fi
```

### 1. legacy state adopt (DEC-049 F5)

dev-cycle→run rename 이전의 in-flight run state(브리프 JSONL / `run.json` / loop
marker)는 **`run-helper`가 자기 startup에서 repo root 기준으로 `.run/`로 승계**하고
구 brief 파일명(`dev-cycle-run-id` / `dev-cycle-briefs.*` / `dev-cycle-run.json` 등)을
`run-*`로 rename한다. wrapper는 **여기서 inline `mv`를 하지 않는다** — wrapper가 먼저
단순 mv하면 그 뒤 helper adopt가 `.run/` 존재를 보고 fail-closed로 skip해 파일명
migration이 누락되고, 구 파일명이 남아 `validate-brief`/`finish-cycle-json`이 실패한다
(P2-A). adopt는 helper에 위임하고 wrapper는 collision/register만 담당한다. hook의 loop
marker는 dual-read(`.run/loop-active` ‖ `.dev-cycle/loop-active`)라 adopt 시점과
무관하게 인식되므로 wrapper 단계에서 marker를 옮길 필요도 없다.

### 2. collision reservation + register (DEC-049 F2/F3)

진입 순서는 **collision preflight/reservation을 canonical repo root에서 먼저**
수행하고, register로 run을 잠근 다음 개발 사이클(worktree는 Step 4에서 생성)로
들어간다. lock order는 **`registry` → `main_sync_holder`** 하나로 고정한다 —
registry lock은 register reservation/update의 짧은 임계구역에서만 잡고, 개발 사이클
helper(`run-helper` sync 등) 실행 중에는 보유하지 않는다 (F3 deadlock 방지).

```bash
WS="$(pwd -P)"
REPO_ID="$("$RUN_REGISTRY" identity --workspace "$WS")"      # origin-only 정규화; exit 2 = non-git
"$RUN_REGISTRY" gc --repo "$REPO_ID" >/dev/null 2>&1 || true # crashed run stale 회수 (best-effort)
ACTIVE_JSON="$("$RUN_REGISTRY" list --repo "$REPO_ID")"
if [ "$(printf '%s' "$ACTIVE_JSON" | jq 'length')" -gt 0 ]; then
  echo "ERROR: 이미 active 상태인 run이 이 logical repo ($REPO_ID)에 있다."
  printf '%s' "$ACTIVE_JSON" | jq -r '.[] | "  - \(.run_id) \(.workspace_path) \(.type) \(.started_at)"'
  echo "옵션: 기존 run 종료 대기 / 다른 worktree에서 실행 / stale이면 \"$RUN_REGISTRY\" gc --repo $REPO_ID"
  exit 6
fi
AGENT="${AGENT:-other}"; case "$AGENT" in claude|codex|other) ;; *) AGENT=other ;; esac
# register가 helper-side collision(preflight가 놓친 legacy/race)으로 exit 6을 낼 수
# 있다. 이 snippet은 set -e 하에 있지 않으므로 status를 명시적으로 확인하고, run_id가
# 없으면 개발 사이클로 진입하지 않는다 (P2-C — guard 우회 방지).
if ! REG_JSON="$("$RUN_REGISTRY" register --type solo --workspace "$WS" --agent "$AGENT")"; then
  echo "ERROR: register 거부 — preflight 이후 race 또는 legacy active_run_collision. 개발 사이클 진입 중단."
  printf '%s\n' "$REG_JSON" | jq -r '.active_runs[]? | "  - \(.run_id) \(.workspace_path)"' 2>/dev/null || true
  exit 6
fi
RUN_ID="$(printf '%s' "$REG_JSON" | jq -r '.run_id // empty')"
[ -n "$RUN_ID" ] || { echo "ERROR: register가 run_id를 반환하지 않음 — 중단."; exit 6; }
echo "registered: $RUN_ID"
```

cooperative pre-check가 active=0을 본 뒤에도 helper `cmd_register`가 repo-scoped lock
안에서 active scan을 다시 수행해 race면 exit 6 + `active_run_collision`을 반환한다
(PA-1.1c). collision이면 개발 사이클로 진입하지 않는다.

### 3. exit trap: run_id 기반 release (DEC-049 F2)

release는 cwd가 아니라 **run_id 기반**으로 idempotent하게 동작한다. Step 4에서 task
worktree로 cd하더라도 같은 `RUN_ID`를 release하므로 cwd 이동과 무관하다.

```bash
# 장기 workflow(sync→…→land, codex 리뷰 대기 등)가 RUN_HEARTBEAT_TTL(기본 300s)을
# 넘겨도 registry entry가 살아있도록 background heartbeat를 띄운다 — 다른 /run의 gc가
# still-running entry를 TTL 초과로 abort하고 두 번째 run을 등록하는 것을 막는다(DEC-049 #2).
( while sleep "${RUN_HEARTBEAT_INTERVAL:-30}"; do "$RUN_REGISTRY" heartbeat "$RUN_ID" >/dev/null 2>&1 || break; done ) &
RUN_HEARTBEAT_PID=$!
trap "kill \"\$RUN_HEARTBEAT_PID\" 2>/dev/null || true; '$RUN_REGISTRY' release '$RUN_ID' >/dev/null 2>&1 || true" EXIT INT TERM
```

trap은 heartbeat loop를 정리하고, run이 자동 acquire한 모든 lock도 함께 release한다
(helper release가 `release_all_locks_for_run` 호출).

### 4. 개발 사이클 진입

register가 끝나면 아래 Flags ~ Loop의 개발 사이클을 그대로 수행한다. Step 4에서
task worktree를 만들면 registry record의 workspace는 진입 시점 값으로 남되 collision
guard는 origin 기준 logical-repo scope(`REPO_ID`)로 동작하므로 정확성에는 영향이
없다 (run-registry update API가 생기면 actual worktree path로 갱신; 현재는 known
limitation). 본 wrapper는 advisory layer이므로 caller가 helper를 우회해 main을
직접 만지면 가드가 적용되지 않는다 (DEC-032).

## Flags

- `--loop`: cycle 완료 후 반복한다. Step 3에서 **ALL CLEAR**이고 자동 승격한 후보가 없으면 종료한다.
- `--loop N`: 최대 N회 반복한다. **ALL CLEAR**이고 자동 승격한 후보가 없으면 N회 전에도 종료한다.
- `--phase <id>`: 탐색과 구현 범위를 해당 roadmap / task / milestone / track / phase / slice id로 제한한다. 값을 파싱하거나 변환하지 않는다.
- `--opus-review`: Review Pass를 항상 Opus sub-agent로 실행한다. Step 9에서 `/codex-loop`를 실행할 때도 `--opus-review`를 전달한다.
- `--opus-audit-every <N>`: cycle 종료 후 직전 cycle index가 N의 배수면 read-only Opus 환기 audit pass를 1회 수행한다. N은 양의 정수다. 누적된 변경 방향성을 Opus가 검토하고 결과만 brief log에 기록한다. 코드 수정/commit/push는 하지 않는다.

## Invariants

- Step이 끝나면 사용자 입력 없이 다음 Step으로 진행한다.
- 멈추는 경우: 자동 승격할 후보가 없는 **ALL CLEAR**, 사용자 승인 없이는 안전하지 않은 분기, 인증/권한/destructive git state, 해결 불가 blocker.
- 사용자에게 보이는 보고, brief, finding, 질문은 한국어로 작성한다. 코드, 명령, 파일명, 원문 인용은 원문 언어를 유지한다.
- repo type, review base, sync, brief log, risk issue 처리는 helper가 담당한다.
- JSON brief 처리는 `jq`가 필요하다. `jq`가 없어서 helper가 실패하면 dependency blocker로 보고한다.
- 자동 승격은 repo의 현재 source of truth가 blocker 해소를 명시적으로 증명하는 status-only 변경에만 허용한다. 사용자 결정, 외부 관찰, 권한, 제품 판단, 추측이 필요하면 승격하지 않는다.
- helper 경로는 아래 순서로 찾는다.

```bash
# run-registry와 동일하게 repo root 기준으로 찾는다 — subdirectory에서 호출해도
# repo-local helper(<root>/.agents/scripts/)를 보도록 (DEC-049 #6).
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
RUN_HELPER=""
if [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/.agents/scripts/run-helper.sh" ]; then
  RUN_HELPER="$REPO_ROOT/.agents/scripts/run-helper.sh"
elif [ -x "$HOME/.agents/scripts/run-helper.sh" ]; then
  RUN_HELPER="$HOME/.agents/scripts/run-helper.sh"
else
  echo "Missing run-helper.sh"; exit 1
fi
```

## Model Routing

Claude Code에서 model-routed sub-agent를 사용할 수 있으면 비용/품질 균형을 위해 아래 원칙을 따른다. 사용할 수 없거나 handoff 비용이 더 크면 같은 세션에서 수행한다.

- Review Pass round-1은 구현자의 반대편 reviewer를 쓴다. codex 구현이면 Opus, Claude 구현이면 Codex가 기본이다. `--opus-review`는 기존처럼 전 round Opus를 강제한다.
- Design Risk Gate에서 high-risk이고 설계가 열려 있으면 pingpong-relay를 **per-turn driver loop**로 구동해 Codex<->Claude 적대 설계 리뷰를 실행한다 (단일 full-auto 명령이 아니다 — 경로 resolve·step loop·종료·fallback 규약은 Step 3.5 참조). locked design이면 검증만 한다.
- 구현과 finding 수정은 Sonnet/main execution을 기본으로 한다. 단순 수정에 별도 Sonnet worker를 만들지 않는다.
- PR polling, pass reaction 확인, comment fetch 같은 상태 확인은 `codex-loop`/helper script에 맡긴다. LLM이 필요한 요약/분류가 있을 때만 Haiku 또는 read-only Explore를 쓴다.
- Opus reviewer resume은 기본값이 아니다. 같은 파일군에서 3회 이상 리뷰/반박/재검토가 이어지고 이전 판단 맥락이 중요할 때만 resume한다. 보통은 이전 finding 요약 + incremental diff로 새 리뷰를 요청한다.

## Brief Log

새 실행의 첫 cycle에서만 초기화한다.
`init-brief`는 `.run/run-id`, `.run/run-start-epoch`, `.run/run.json`, `.run/run-briefs.jsonl`, `.run/run-briefs.md`를 만들고 export를 출력한다. Bash 호출 사이에 export가 사라져도 `finish-cycle-json`과 `summary-json`은 저장된 state를 검증해 이어 쓴다. JSONL이 canonical 기록이고 Markdown은 helper가 렌더링한 human log다.

```bash
eval "$("$RUN_HELPER" init-brief)"
```

이어서 실행하는 cycle이라면 `RUN_RUN_ID`와 `RUN_BRIEF_LOG`를 재사용하기 전에 반드시 검증한다.

```bash
"$RUN_HELPER" validate-brief "$RUN_RUN_ID" "$RUN_BRIEF_LOG"
```

검증 실패 또는 확신이 없으면 새 실행으로 보고 `init-brief`를 다시 실행한다. 단, cycle 종료 시점의 누락된 환경변수를 복구하려고 `init-brief`를 다시 실행하지 않는다. 그것은 새 brief log를 시작한다.

Cycle 종료 시 JSON payload를 `finish-cycle-json` stdin으로 넘긴다. **ALL CLEAR, blocked, publish 금지로 종료하는 경우도 먼저 `finish-cycle-json`을 실행한다.** helper는 JSON을 검증하고 repo/run metadata를 보강한 뒤 `.run/run-briefs.jsonl`에 append한다. 그 다음 사용자 브리핑 Markdown을 렌더링해 `.run/run-briefs.md`에 append하고 stdout ack JSON의 `rendered_markdown`에 넣는다.

```bash
"$RUN_HELPER" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "implementer": "codex",
  "actions": [
    {"kind": "implement", "summary_ko": "이번 cycle에서 실제로 한 일"}
  ],
  "conclusion": {"summary_ko": "사용자가 바로 이해할 결론", "reason_ko": "선택"},
  "changes": [
    {"path": "수정 파일 또는 영역", "summary_ko": "선택"}
  ],
  "design_risk": {"level": "low|medium|high", "triggers": ["선택"], "summary_ko": "선택"},
  "design_decisions": [
    {"risk_ko": "선택", "chosen_pattern_ko": "선택", "invariant_ko": "선택", "tests_ko": "선택", "residual_risk_ko": "선택"}
  ],
  "change_scope": {"kind": "docs_only_contract", "changed_files_count": 2, "contract_surface": true, "review_required": true},
  "verification_plan": {"profile": "docs_contract", "full_ci_required": false},
  "verification": [
    {"kind": "test", "status": "pass", "summary_ko": "검증 결과"}
  ],
  "review_land": {"status": "pushed", "summary_ko": "리뷰/반영 결과"},
  "next_candidates": [
    {"id": "후보 id", "status": "planned", "summary_ko": "무슨 작업인지", "unblock_ko": "시작 조건"}
  ],
  "auto_promotion_candidates": [
    {"id": "검토한 후보 id", "status": "planned", "summary_ko": "검토한 후보", "eligible": true, "reason_ko": "자동 승격 가능/불가 이유"}
  ],
  "auto_promotions": [
    {"id": "승격한 후보 id", "status_before": "planned", "status_after": "ready", "summary_ko": "승격 내용", "path": "수정한 status 파일", "reason_ko": "승격 근거"}
  ],
  "risks": [
    {"summary_ko": "남은 실제 리스크", "next_action_ko": "후속 조치"}
  ]
}
JSON
```

필수 필드: `schema_version`, `cycle`, `result`, `actions`, `conclusion.summary_ko`,
`verification`, `review_land`, `risks`. 구현 또는 승격 cycle은 `implementer`도
기록한다. 값은 `codex` 또는 `claude`다. `review_ship`은 legacy alias로만 허용한다.
`cycle`은 1부터 시작하는 정수이고, `actions`와 `verification`은 비어 있으면 안 되며
각 항목에 사용자-visible `summary_ko`를 쓴다. 권장 `result` 값은 `landed`,
`blocked`, `all_clear`, `doc_fix_needed`다. 리스크가 없으면 `risks: []`를 쓴다.
Ready slice가 없어 `ALL CLEAR`로 끝낼 때는 실제 수행한 탐색/판단을 `actions`와
`conclusion`에 쓰고, ready가 아닌 다음 검토 후보는 최대 3개까지 `next_candidates`에
둔다. 자동 승격을 검토했다면 `auto_promotion_candidates`에 검토한 후보와 가능/불가
이유를 쓰고, 실제 승격한 항목은 `auto_promotions`에 쓴다. `change_scope`,
`verification_plan`, `design_risk`, `design_decisions`, 후보/승격 필드는
schema_version 1의 optional extension이다. 후보는 후속 안내이지 risk issue 대상이
아니므로 실제 리스크가 없으면 `risks: []`다.

`finish-cycle-json` stdout은 tool output일 뿐 사용자에게 자동 전달되지 않는다. stdout ack JSON에서 `rendered_markdown`만 추출해 사용자에게 그대로 보여준다. 이 메시지가 사용자에게 보이기 전에는 다음 `update_plan`, Step 1, Step 2, discovery, 파일 탐색, 또는 tool call을 하지 않는다. 한 줄짜리 "사이클 N 완료" 요약으로 대체하면 안 된다. `--loop` 또는 `--loop N`이면 user-visible brief를 보낸 뒤 ack의 `auto_promotions_count`로 loop 지속 여부를 판단한다.

`.run/run-briefs.jsonl`과 `.run/run-briefs.md`는 helper가 관리하는 append-only state다. cycle 결과를 고치려고 직접 편집하지 않는다. 특히 issue 생성 실패를 숨기려고 남은 risk를 `없음`으로 바꾸면 안 된다. 기존 env var 기반 `finish-cycle`은 legacy shim으로만 사용한다.

## Step 1 - Sync

새 실행의 첫 cycle에서는 항상 실행한다. `--loop` 또는 `--loop N`의 두 번째 이후 cycle에서도 PR merge 후 main sync가 필요하므로 Step 1을 다시 실행한다.

- 새 실행, context reset 이후 확신이 없는 경우, 직전 cycle이 `landed`가 아닌 경우, branch/working tree가 예상과 다르면 첫 cycle처럼 Step 1을 실행한다.

```bash
"$RUN_HELPER" sync
REPO_TYPE="$("$RUN_HELPER" repo-type)"
REVIEW_BASE="$("$RUN_HELPER" review-base)"
"$RUN_HELPER" record-audit-baseline
echo "Repo type: $REPO_TYPE"
echo "Review base: $REVIEW_BASE"
```

`record-audit-baseline`은 첫 cycle이 끝나기 전 한 번만 post-sync HEAD를 `run.json.base_sha`에 기록하고, 그 이후 호출은 idempotent로 무시한다. 첫 audit window의 START_SHA fallback이 sync로 가져온 upstream commits를 포함하지 않도록 한다.

## Step 2 - Discover

스킬을 호출한 메인 세션이 직접 탐색한다. `/codex:rescue`나 다른 sub-agent로 위임하지 않는다. 사용자에게 보고할 때는 한국어로 정리한다.

### 진입 정합

- repo에 `AGENTS.md`가 있으면 그 파일의 "Read order" 섹션을 canonical로 따른다. 본 Step의 읽기 순서는 기본값이고, repo가 자체 read order를 정의했으면 그쪽이 우선한다.
- **Project mode stop rule은 `AGENTS.policy.md`가 존재하고 그 파일이 "Project mode stop rule" 섹션을 정의한 repo에서만 발동한다**. 그 조건을 만족하면, `docs/context/current-state.md`의 `Project mode` 블록을 확인해 `mode`가 `greenfield` 또는 `adoption`이 아닐 때 (블록 없음 / `unset` / 다른 값) 정책이 정의한 대로 사용자에게 모드 결정을 요청하고 Step 2를 중단한다. mode가 `adoption`이면 `docs/DOCUMENTATION.md`가 정의한 adoption backfill이 끝났는지 같이 확인한다. `AGENTS.policy.md`가 없거나 해당 섹션이 없으면 stop rule을 적용하지 않고 그냥 진행한다.

### Profile 분기

본 Step의 읽기 순서는 repo가 boilerplate 구조를 얼마나 채택했는지로 분기한다. **반드시 어느 한 profile에 매칭되도록 fallback이 정의되어 있다.**

| Profile | 조건 (둘 다 만족) | 동작 |
|---------|------|------|
| **Boilerplate-full** | `docs/context/current-state.md` 존재 **AND** `docs/04_IMPLEMENTATION_PLAN.md` 존재 | 아래 "Boilerplate-structure 읽기 순서" 적용 |
| **Boilerplate-partial** | 위 두 파일 중 하나만 존재 (staged adoption / migration 중간 상태) | "Boilerplate-structure 읽기 순서"를 **best-effort로 적용** — 존재하는 boilerplate 파일은 그대로 읽고, 누락 파일에 해당하는 단계는 건너뛰며, 누락된 파일이 ready 판정에 필요한 정보를 담는 경우 그 정리 자체를 DOC FIX NEEDED 후보로 보고한다. IMPL_PLAN vocabulary 강제 규칙(아래 "공통 규칙")은 IMPL_PLAN이 존재할 때만 적용 |
| **Universal** | 위 두 파일 모두 없음 | 아래 "Universal profile 읽기 순서" 적용 |

### Boilerplate-structure 읽기 순서

위 표 기준 **Boilerplate-full** 또는 **Boilerplate-partial** profile에서 적용. 각 단계에서 task 후보가 좁혀지면 거기서 멈추고 다음 단계는 task가 실제로 닿는 부분만 읽는다. 누락 파일은 건너뛰고 진행한다.

1. `docs/context/current-state.md` — 활성 milestone / track / phase / slice, hardening 현황, blocker, project mode
2. `docs/04_IMPLEMENTATION_PLAN.md` — status ledger (milestone → track → phase → slice, gate, acceptance, evidence, dependency, next, blocks 컬럼). `## Risks (open)` 섹션은 ready 판정 직전 반드시 본다
3. `docs/current/CODE_MAP.md`, `docs/current/RUNTIME.md`, `docs/current/DATA_MODEL.md`, `docs/current/TESTING.md`, `docs/current/OPERATIONS.md` 중 task가 닿는 thin nav docs
4. CI/CD, release, deployment pipeline 또는 required check를 바꾸는 task면 `docs/11_CI_CD.md`
5. AC/TEST/TRACE 상태 변경이 필요하면 `docs/06_ACCEPTANCE_TESTS.md`, `docs/09_TRACEABILITY_MATRIX.md`
6. 제품 scope 결정이 영향을 받으면 `docs/01_PRD.md`, 아키텍처 결정이 영향을 받으면 `docs/02_HLD.md` + 관련 `docs/adr/*.md`
7. 미해결 결정이 task ready 판정을 막을 수 있으면 `docs/07_QUESTIONS_REGISTER.md`, `docs/08_DECISION_REGISTER.md`
8. 작업 후보와 직접 관련된 source / tests / migrations / config

긴 `docs/design/archive/*`, `docs/discovery/*`, `docs/generated/*`, `docs/_generated/*`는 위 단계로 task를 좁힌 뒤 그 task에 직접 필요한 경우에만 본다. invariant tracking 시스템(`docs/templates/relation_enum.yaml`)을 쓰는 repo에서 Q/DEC/ADR 작성이 task 본문에 포함되면 `AGENTS.policy.md` "Cross-document invariant tracking"이 정의한 generated artifacts(`docs/_generated/scope_tree.yaml`, `term_usage.yaml`, `effective_invariant_policy.yaml`)를 함께 읽는다.

### Universal profile 읽기 순서

위 표 기준 **Universal** profile에서 적용.

1. `AGENTS.md` / `CLAUDE.md` / `README` 등 entrypoint 문서
2. repo가 정의한 status/issue tracker (있으면)
3. 작업 후보와 직접 관련된 source / tests

### 공통 규칙

- `--phase <id>`가 있으면 그 id의 milestone / track / phase / slice / roadmap label 범위에 속하는 문서·source만 본다. 범위 밖 candidate는 무시한다.
- **Boilerplate-full / Boilerplate-partial profile에 한해**, `docs/04_IMPLEMENTATION_PLAN.md`가 존재하면 그 파일의 status vocabulary와 단계 hierarchy(milestone / track / phase / slice / gate / acceptance / evidence)를 보고에 그대로 사용한다. 임의 단어로 paraphrase하지 않는다. **Universal profile 및 IMPL_PLAN이 없는 Boilerplate-partial 케이스에서는 이 규칙을 적용하지 않고**, repo가 실제로 사용하는 status/issue tracker의 용어를 그대로 따른다.

### 판단 기준

아래 규칙에서 "ledger"는 Boilerplate-full/Boilerplate-partial profile에서는 `docs/04_IMPLEMENTATION_PLAN.md`를, Universal profile (또는 IMPL_PLAN이 없는 Boilerplate-partial 케이스)에서는 repo가 실제 사용하는 status/issue tracker를 가리킨다.

- 구현 후보를 우선하되 commit 가능한 task/slice 크기로 자른다.
- `NEXT TASK`는 ready, unblocked, authorized 작업만 선택한다. `planned`, `deferred`, `blocked`에 해당하는 scope (또는 universal repo에서 그에 상응하는 tracker 상태)는 inventory로 보고할 수 있지만 실행 큐로 보지 않는다.
- ready 판정 전 ledger의 dependency · gate · acceptance · 활성 risk (또는 universal repo의 동등 신호 — blocking issue, missing test/PR, 명시된 prerequisite 등)가 해당 task의 시작을 막지 않는지 확인한다. Boilerplate profile에서 직전 cycle merge로 이미 해소된 항목이 IMPL_PLAN에 반영되지 않은 경우, 그 정리 자체가 docs-only DOC FIX NEEDED 후보가 될 수 있다.
- 문서와 코드가 둘 다 필요하면 구현 작업으로 반환하고 docs update를 acceptance criteria에 포함한다.
- docs-only는 구현할 코드 작업이 없고 문서만 틀린 경우에만 선택한다.
- ready task/slice가 없으면 `ALL CLEAR`로 판단하되, 다음에 검토할 non-ready 후보를 최대 3개까지 함께 기록한다. 각 후보에는 ledger상의 status (universal repo에서는 tracker의 실제 상태값), 검토/해제 조건, 필요한 사용자 결정이나 외부 입력을 포함한다. 기계적으로 자동 승격 가능해 보이는 후보(선행 dependency가 ledger 기준으로 closed)도 표시하되 Step 2에서는 파일을 수정하지 않는다.

### 반환 형식

탐색 결과를 사용자에게 보고할 때 아래 중 정확히 하나의 형식을 사용한다. Profile에 따라 boilerplate 전용 필드(`milestone / track / phase / slice id`, `IMPL_PLAN 문서 참조`)가 universal repo의 동등 신호로 대체된다.

**## NEXT TASK** — 작업 식별자 (Boilerplate-full/partial: milestone / track / phase / slice id; Universal: roadmap / issue / ticket id 또는 source 경로), 파일·영역, gate / acceptance criteria (또는 universal repo의 done criteria), 필요한 docs update, validation 명령을 포함한 하나의 작업.

**## DOC FIX NEEDED** — docs-only 수정 목록. 어느 문서가 잘못됐는지 명시한다 (Boilerplate-full/partial: `current-state.md` / `04_IMPLEMENTATION_PLAN.md` / thin current docs / 06/07/08 / ADR 중 어디; Universal: README / repo가 사용하는 문서 경로).

**## ALL CLEAR** — 현재 상태 요약 (Boilerplate-full/partial: 활성 milestone / track / phase / 마지막 landed slice; Universal: 최근 작업·릴리스 요약). ready 후보가 없어서 종료하는 경우 다음 검토 후보(최대 3개)와 각 후보의 status (ledger 또는 tracker의 실제 값), 해제 조건을 포함한다.

## Step 3 - Decide

- **ALL CLEAR**: 종료하기 전에 Auto-Promotion Gate를 실행한다.
- **NEXT TASK**: Step 3.5로 간다.
- **DOC FIX NEEDED**: Step 3.5로 가되 작업 type은 `docs`.

### Auto-Promotion Gate

Step 2가 **ALL CLEAR**를 반환하면 아래 순서로 ready 자동 승격 가능성을 확인한다.

1. Step 2의 `Next review candidates`와 같은 roadmap/status ledger의 인접 slice를 확인한다. `--phase <id>`가 있으면 그 범위 밖 후보는 제외한다.
2. 후보가 자동 승격 가능한 조건은 모두 만족해야 한다: 현재 repo 문서/ledger/source가 선행 dependency나 gate 완료를 명시적으로 증명한다, 남은 조건이 status-only 문서 변경이다, 사용자 결정/외부 관찰/권한/제품 판단이 필요하지 않다, 승격 후 실행할 acceptance가 충분히 구체적이다.
3. 검토한 후보는 모두 `auto_promotion_candidates`에 기록한다. 자동 승격하지 않은 후보도 `eligible:false`와 이유를 남긴다.
4. 자동 승격 가능한 후보가 있으면 파일 수정 전에 `"$RUN_HELPER" mutation-entry-check`를 호출해 cwd가 mutation 작업 위치로 안전한지 확인한다 (`ok:false`이면 hint대로 task worktree 생성 후 재진입). 통과하면 Step 4의 worktree 규칙을 적용하고, 새 branch를 `RUN_WORK_BRANCH`에 기록한다. base branch에서 직접 수정하지 않는다.
5. authoritative roadmap/status 파일을 수정해 `ready`로 승격하고, 각 변경을 `auto_promotions`와 `changes`에 기록한다. 여러 후보가 같은 근거로 기계적으로 승격 가능하면 모두 승격한다.
6. 승격 변경이 있으면 이번 cycle은 promotion-only cycle로 보고 Step 5부터 진행한다. promotion-only cycle은 Step 4를 거치지 않으므로 status flip을 직접 수행한 main session agent로 여기서 `implementer`를 기록한다 (Claude Code=`claude` / Codex `$run`=`codex`) — Step 6 round-1 reviewer 선택의 입력이 된다. 검증/리뷰/반영/PR merge gate는 일반 변경과 동일하게 적용한다. cycle 결과는 `result:"all_clear"`로 기록하고, `review_land`에는 승격 변경의 push/PR/merge 결과를 쓴다.
7. 승격 변경이 없으면 `result:"all_clear"` payload로 `finish-cycle-json`을 실행한 뒤 종료한다. 실제 탐색 행동과 결론은 `actions`/`conclusion`에 쓰고, Step 2의 후보는 `next_candidates`에 포함한다. 실제 리스크가 없으면 `risks: []`다.

`--loop`가 아닌 실행에서는 자동 승격 후 새로 ready가 된 작업을 같은 invocation에서 구현하지 않는다. 승격 내역을 brief에 남기고 종료한다. `--loop` 실행에서는 승격 변경이 원격 반영된 뒤 user-visible brief를 보여주고 다음 cycle로 계속 진행한다.

## Step 3.5 - Design Risk Gate

구현 전에 semantic design risk를 분류한다. 이 gate는 Review Pass를 약화하지 않으며, reviewer가 설계를 새로 발견하게 두지 않고 이미 잠긴 설계를 검증하게 만들기 위한 것이다.

### Risk Trigger

아래 trigger가 2개 이상이면 기본값은 **medium** 이상이다. 하나라도 failure blast radius가 크거나 외부 비용/데이터 손상이 가능하면 **high**로 올린다.

- concurrency, heartbeat, lease, reservation, recovery, retry, idempotency, worker ownership
- schema, migration, backfill, audit ledger, data repair, persistence
- external API, LLM call, billing/cost accounting, transport failure, partial success
- auth, security, policy, permission, secret handling
- public CLI/output, command/skill contract, deploy/build/test infra
- multi-surface 반영 필요: `commands/`, `codex/skills/`, `.agents/scripts/`, docs/tests가 같은 계약을 공유
- Step 2의 acceptance 또는 reviewer prompt에 "adversarial focus"가 필요하지만 대응 pattern이 아직 정해지지 않은 경우

### Route

- **Low**: main session이 1-3줄 design note를 `actions` 또는 `conclusion`에 남기고 Step 4로 간다.
- **Medium**: main session이 최소 2개 대안을 비교하고 `design_risk` / `design_decisions`에 선택 근거를 남긴 뒤 Step 4로 간다.
- **High**: design이 genuinely open(accepted DEC, locked design doc, ADR 등 설계 lock 없음)이면
  구현 전에 **adversarial pingpong 설계 리뷰**(XAR-1Bb, Codex<->Claude)를 실행한다. pingpong-relay는
  단일 full-auto 명령이 아니라 **per-turn `step` orchestrator**이므로 driver가 반복 구동한다:
  (1) relay를 RUN_HELPER resolver와 동일하게 **repo root 기준**으로 resolve한다 (subdirectory
  호출 대응, DEC-049 #6) — `$REPO_ROOT/.agents/scripts/pingpong-relay.sh` →
  `$HOME/.agents/scripts/pingpong-relay.sh` → `$REPO_ROOT/scripts/pingpong-relay.sh`. (2) `adversarial_dialogue`
  세션을 init하고 설계 질문을 initiator request로 넣는다. (3) `pingpong-relay.sh step --session <id>
  --auto-relay --auto-decision --json`을 driver loop로 반복하되, **step이 실제로 진행 turn을 author한
  동안에만 계속**한다(positive invariant). 그 외 모든 결과는 loop를 멈추고 emit JSON `status`로 분기한다 —
  terminal/converged/cap(DEC-029 `RELAY_MAX_ROUNDS`=6 / `RELAY_MAX_MESSAGES`=20)이면 design verdict로,
  `paused`/needs-user 등 비진행 status이면 사용자에게 surface, helper-rejection/subprocess/세션 오류 등
  nonzero exit이나 relay 구동 불가이면 fallback(아래). 구체적 status 값·exit code 의미는 relay 헤더 +
  `commands/pingpong.md`가 canonical이므로 여기서 열거하지 않는다(열거는 불완전해지기 쉽다).
  (4) transcript를 design verdict로 압축한다.
  세션/driver 패턴은 `commands/pingpong.md`와 relay 헤더 참조. `RELAY_MAX_ROUNDS`는 design용으로 낮춰도
  되며 새 cost cap은 만들지 않는다. 이미 잠긴 설계를 구현하는 slice면 pingpong을 실행하지 않고 구현 계획을
  locked design에 맞춰 검증만 한다. **relay design review를 실제로 구동할 수 없는 어떤 사유든**
  — 경로에서 relay를 못 찾음, codex/claude subprocess 부재, sandbox 부재로 `step`이 exit 6/`no_sandbox`로
  authoring 거부, 기타 step이 정상 진행 못 하는 exit — 이면 `/codex:rescue` 또는 같은 세션 read-only
  design review로 fallback한다 (Step 6 Opus fallback과 동일한 capability adaptation; 규칙은 동일).
  즉 pingpong은 실제로 authoring turn이 성공할 때만 사용하고, 그렇지 않으면 fallback이다. reviewer
  결과는 그대로 위임하지 말고 main session이 아래 matrix로 압축해 최종 결정을 잠근다.

### Design Decision Matrix

High/medium risk 작업은 "위험 인식"만 기록하지 않는다. 각 의미 있는 risk마다 아래 형식으로 구체화한다.

```text
risk -> chosen pattern -> rejected alternatives -> invariant -> required tests -> residual risk
```

예시:

```text
Risk: stale worker release
Chosen pattern: reservation_token fencing
Rejected alternatives: worker_id-only ownership because worker_id reuse can release newer work
Invariant: release/heartbeat/sweep must match token, not worker_id alone
Required tests: reused worker_id cannot release a newer reservation
Residual risk: manual repair remains operator-only
```

논문, 블로그, vendor experience report를 참고할 수 있지만 citation 자체를 권위로 취급하지 않는다. 출처 유형(peer-reviewed paper, white paper, arXiv preprint, blog, vendor report), 실험 범위, 전제, 현재 repo 문제와의 차이를 짧게 적고, paper는 결정 근거가 아니라 risk lens로 사용한다. repo evidence 또는 현재 incident 관찰 없이 paper만으로 workflow rule을 강제하지 않는다.

## Step 4 - Implement

- 작업 전 entry-check를 호출해 cwd가 mutation 작업 위치로 안전한지 확인한다. cwd가 primary worktree (canonical main checkout), base/default branch, detached HEAD, 또는 base discovery 실패면 helper가 `rc=2`로 거부한다.

  ```bash
  "$RUN_HELPER" mutation-entry-check
  # ok:false인 경우 hint대로 task worktree를 만들고 cd한 뒤 재진입:
  #   git worktree add ../<repo>-<branch> -b <branch> "origin/$REVIEW_BASE"
  #   cd ../<repo>-<branch>
  # 그 후 다시 entry-check 통과.
  ```

- entry-check가 통과하면 cwd는 이미 task worktree 안이고, branch는 working branch이거나 비-base branch다. 새 작업 cycle을 시작하는 경우 작업 branch를 명시한다 (`codex/<short-description>` 또는 `<type>/<short-description>` 형태). 이미 working branch에 있으면 그대로 사용.
- 작업 브랜치 이름은 `RUN_WORK_BRANCH`로 기록해 Step 8 push, Step 9 merge/cleanup에서 같은 브랜치를 사용한다.
- 실제 diff를 작성한 구현 주체를 `implementer`로 기록한다. 값은 `codex` 또는 `claude`다.
  Codex 위임/직접 Codex 작성은 `codex`, Claude Code/Opus main session 직접 구현은 `claude`다.
  이 값으로 Step 6 round-1의 반대편 reviewer를 고른다.
- Step 3.5에서 medium/high design decision matrix가 작성됐다면 그 invariant와 required tests를 구현 scope에 포함한다. 구현 중 선택한 pattern이 틀렸다고 드러나면 조용히 우회하지 말고 Step 3.5 matrix를 갱신한 뒤 계속한다.
- Step 2의 task/slice를 구현한다. docs update가 acceptance criteria면 같은 cycle에서 처리한다.
- 모델 라우팅이 가능해도 구현 handoff가 현재 작업 맥락보다 커지면 sub-agent를 만들지 말고 main/Sonnet execution에서 최소 diff로 수정한다.
- `--phase <id>` 범위를 벗어난 작업은 하지 않는다.

## Step 5 - Verify

먼저 변경 범위와 검증 프로필을 계산한다.

```bash
CHANGE_SCOPE_JSON="$("$RUN_HELPER" change-scope)"
```

- `verification_profile.full_ci_required == true`: `/verify`를 실행하고 repo guidance에 맞는 targeted verify를 수행한다.
- `verification_profile.full_ci_required == false`: 문서/계약 변경에 맞는 검증만 수행한다. 기본은 `git diff --check`이고, command/skill/schema/status 같은 contract docs는 render/generated consistency, schema/example validation처럼 실제로 의미 있는 검증을 추가한다. unit/app CI는 repo guidance가 touched docs에 명시적으로 요구할 때만 실행한다.
- 어떤 profile이든 Review Pass는 생략하지 않는다. 문서는 코드만큼 리뷰 대상이다.
- cycle payload에는 `CHANGE_SCOPE_JSON.change_scope`를 `change_scope`로, `CHANGE_SCOPE_JSON.verification_profile`을 `verification_plan`으로 기록한다.

- pass 또는 누락 수정 완료: Step 6.
- 해결 불가 blocker: `result:"blocked"` payload로 `finish-cycle-json`을 실행하고 중단.

## Step 6 - Review

리뷰 직전 다시 계산한다.

```bash
REVIEW_BASE="$("$RUN_HELPER" review-base)"
CHANGE_SCOPE_JSON="$("$RUN_HELPER" change-scope)"
REVIEW_DOSSIER_JSON="$("$RUN_HELPER" review-dossier)"
```

- `REVIEW_DOSSIER_JSON.review_dossier`는 diff 크기, 파일 확산, 계약/중요 경로처럼 script가 계산 가능한 신호만 담는다. dossier가 없거나 helper가 실패하면 `CHANGE_SCOPE_JSON`과 아래 위험 trigger를 수동으로 적용한다.

### 리뷰어 선택

| 조건 | 리뷰어 |
|------|--------|
| `--opus-review` | Opus sub-agent (Codex 리뷰 스킵) |
| small local-only (`--opus-review` 부재) | Step 6 로컬 review loop skip; Step 7 -> Step 8 -> Step 9 |
| 1회차, `implementer=codex` | Opus sub-agent; Opus 없는 surface는 Codex fallback |
| 1회차, `implementer=claude` | `/codex:adversarial-review --base "$REVIEW_BASE" --model gpt-5.5` |
| 2~3회차 기본 | `/codex:adversarial-review --base "$REVIEW_BASE" --model gpt-5.5` |
| 4회차~ 기본 | `/codex:review --base "$REVIEW_BASE" --model gpt-5.5` |

Codex 리뷰어는 항상 `--model gpt-5.5`를 명시적으로 전달한다. 사용자별 `~/.codex/config.toml` default model이 달라도 run Step 6 리뷰는 동일한 reviewer 모델로 고정되어, cycle 간 finding 품질이 model 선택에 의해 흔들리지 않도록 한다.

- small local-only는 `--opus-review`가 없을 때만, 그리고 나머지 reviewer row보다 먼저 판정한다.
  `--opus-review`가 있으면 small이어도 skip하지 않고 Step 6 Opus review를 수행한다(flag가 명시한 리뷰 보장).
  small 판정 조건은 `Impact: local only`, 위험 trigger 0개,
  dossier small diff가 모두 참인 경우다.
  dossier small diff는 `review_dossier.summary.changed_lines <= 200`이고
  `review_dossier.summary.changed_files_count <= 5`인 상태다. 이 경우 Step 6만 건너뛰고
  Step 7 -> Step 8(PR open, `PR_NUMBER` 초기화) -> Step 9(PR codex review)로 진행한다.
  Step 8은 Step 9가 소비할 PR을 만들기 때문에 건너뛰지 않는다. 단 사용자가 publish
  금지를 지시해 Step 8이 PR 없이 멈추는 경우엔 Step 9 PR review가 없으므로 small-skip을
  적용하지 않고 Step 6 로컬 review를 수행한다 — skip은 Step 9가 실제로 실행될 때만 유효하다.
- 현재 surface에 Opus sub-agent가 없으면 `implementer=codex` round-1은
  `/codex:adversarial-review --base "$REVIEW_BASE" --model gpt-5.5`로 fallback한다.
  이는 Codex `$run` surface의 capability adaptation이며, 규칙 자체는 구현자 반대편
  reviewer를 고른다는 동일한 contract다.
- 리뷰어(Codex 또는 Opus)에게 넘기는 입력은 full repo가 아니라 `CHANGE_SCOPE_JSON.review_inputs`, dossier summary/risk triggers, 필요한 call site/검증 출력으로 제한한다. 이전 pass의 전체 transcript를 재사용하지 말고, 필요한 경우 이전 actionable finding 요약만 넘긴다.
- Step 3.5에서 `design_risk` / `design_decisions`를 만들었다면 reviewer 입력에 matrix와 residual risk를 포함한다. reviewer에게 "corner를 찾아라"만 요청하지 말고, 각 corner의 chosen pattern / invariant / required tests가 구현됐는지 검증하게 한다.
- 모든 repo는 같은 입력 규칙을 쓴다. commit 전 local diff와 untracked files가 있으면 반드시 포함한다.
- Review Pass는 diff review와 impact triage/scan이 함께 통과한 상태다.
- Impact triage: docs/typo/slice/test-only처럼 외부 surface가 없으면 `Impact: local only`로 끝낸다.
- 위험 trigger: shared helper/API, command/skill, deploy/build/test infra, config/env/schema, persistence, auth/security, public CLI/output, 파일 경로/계약 변경, 변경 파일 5개 초과. 해당하면 변경된 symbol/path/env/command를 `rg`로 repo 전체에서 추적해 call site/docs/tests/deploy refs를 확인한다.
- 리뷰 결과는 그대로 수용하지 말고 적대적/비판적으로 재평가한다. 각 finding마다 주장, 근거, 재현 가능성, 실제 영향, severity, 범위 적합성을 확인하고 duplicate/이미 처리됨/추측성 edge/단순 취향이면 근거와 함께 제외한다.
- 유효한 finding은 가장 합리적인 해결 방식을 고른다: root-cause code fix, test 보강, 문서/계약 정정, 요구사항 clarification, 또는 사용자 결정 요청. 리뷰를 만족시키려고 보안/검증/계약을 약화하거나 symptom-only patch를 만들지 않는다.
### Review Loop

**Step 6 pass 조건: 리뷰어가 직접 실행되어 actionable finding 0을 반환한 경우에만 통과한다.** finding을 수정했다고 스스로 "pass"를 선언하는 것은 금지다. 수정 후에는 반드시 리뷰어를 재실행해야 한다. **예외 — small-skip**: small local-only(+`--opus-review` 부재 + publish 예정으로 Step 9가 실제 실행)로 판정돼 Step 6 로컬 review를 건너뛴 cycle은 이 pass 조건의 명시적 예외다 — 로컬 reviewer를 실행하지 않고 Step 7→8→9로 진행하며 리뷰는 Step 9 PR codex review가 담당한다. 그 외 모든 cycle은 위 pass 조건을 그대로 강제한다.

각 pass는 다음 순서를 엄격히 따른다:

1. **리뷰어 실행** (Codex 또는 Opus) → finding 목록 수신
2. finding을 적대적/비판적으로 재평가 → 유효한 actionable finding 분류
3. 유효한 actionable finding이 **0이면**: Step 7로 간다 (**Review Pass**)
4. 유효한 actionable finding이 **있으면**: batch 수정 → targeted verify → **1로 돌아가 리뷰어를 반드시 재실행한다**

fix가 surface를 넓히지 않았으면 다음 pass는 추가 diff 중심으로 본다.

### Review Burn Controller

반복 리뷰는 pass 조건을 약화하지 않는다. 다만 같은 design class의 finding이 계속 나오면 더 많은 patch/review 반복이 아니라 design regroup 신호로 취급한다.

- **3회차**: 같은 파일군 또는 같은 risk class에서 반복 finding이 있으면 Step 3.5 matrix를 다시 열고, 누락된 pattern/invariant/test를 명시한다.
- **5회차**: 사용자에게 짧은 중간 브리핑을 남긴다. 현재 유효 finding 수, 반복되는 risk class, design regroup 여부, 다음 pass 목표를 기록한다.
- **8회차**: design issue가 아직 새로 발견되는 중이면 Step 3.5 High route의
  read-only design reviewer를 호출하거나, 사용자 결정이 필요한 항목을 issue로 분리한다.
  단순히 review command만 계속 반복하지 않는다.
- **12회차 이후**: normal review loop가 아니라 incident mode로 취급한다. 남은 finding을 root cause category로 묶고, 계속 진행/분리/중단 중 안전한 선택지를 사용자에게 보고한다.

합리적인 finding이 더 이상 나오지 않을 때까지 반복하되 hard upper는 20회다. 사용자 결정이 필요한 finding, 또는 fix를 적용했는데 같은 위치에 같은 주장이 다시 올라와 합의가 어려운 disagreement는 GitHub issue로 남기고 Step 7로 간다. 20회를 채우고도 남은 actionable finding이 있으면 GitHub issue로 남기고 Step 7로 간다. pass 횟수는 매 pass 시작 시 TodoWrite 체크박스에 `[Review pass N/20]` 형태로 기록해 context reset 이후에도 복원할 수 있도록 한다.

## Step 7 - Local Checks

`CHANGE_SCOPE_JSON.verification_profile`을 다시 확인한다.

- `full_ci_required == true`: repo guidance와 docs/testing에 정의된 full/pre-PR 검증을 실행한다.
- `full_ci_required == false`: Step 5에서 정한 문서/계약 검증 프로필만 반복한다. docs-only 변경 때문에 의미 없는 unit/app CI나 전체 CI를 기본 실행하지 않는다.
- 실패하면 수정 후 Step 5 또는 Step 7의 관련 검증을 반복한다.

## Step 8 - Land

- 의도한 파일만 stage, commit, `RUN_WORK_BRANCH` push. 이어서 PR body를 `PR_BODY_FILE` 경로의 파일로 작성하고 (아래 'Test plan 섹션' 참고) `check-test-plan`을 통과한 뒤 `gh pr create`로 **draft가 아닌 open PR**을 생성한다. 생성 결과 URL에서 PR 번호를 추출해 `PR_NUMBER`에 저장하고 Step 9에서 같은 변수를 사용한다.

  ```bash
  PR_BODY_FILE="$(mktemp -t run-pr-body-XXXXXX.md)"
  # ...PR body를 "$PR_BODY_FILE"에 작성한다 ('Test plan 섹션' 포함)...
  "$RUN_HELPER" check-test-plan < "$PR_BODY_FILE"   # ack ok:true 확인
  PR_URL="$(gh pr create --base "$REVIEW_BASE" --head "$RUN_WORK_BRANCH" \
            --body-file "$PR_BODY_FILE" --draft=false)"
  PR_NUMBER="${PR_URL##*/}"
  ```
- 사용자가 publish 금지를 명시했으면 여기서 멈추고 local state만 보고한다.

### Test plan 섹션

PR body에는 반드시 `## Test plan` 섹션을 포함한다. reviewer가 그대로 따라 확인할 수 있는 단위로 적는다.

- 추가/수정한 자동화 테스트: 파일 경로, describe/it 또는 함수명, 각 케이스가 assert하는 contract 한 줄.
- 실행한 verify 명령과 결과: pass/fail count, 가능하면 before/after 수, skip 사유.
- 자동화 테스트가 없는 변경 (docs-only contract, command/skill 문구, status ledger 등)이면 대신 실행한 contract 검증 (render/generated consistency, schema/example validation, lint 등)과 결과를 적고, 자동화 테스트를 추가하지 않은 이유를 한 줄로 명시한다.
- Step 5/7에서 본 검증 결과와 test plan 내용이 일치해야 한다. 실행하지 않은 검증을 적지 않는다.

생성 전 (Step 8)과 merge 직전 (Step 9) 모두 helper로 검증한다.

```bash
"$RUN_HELPER" check-test-plan < "$PR_BODY_FILE"
```

ack JSON이 `{"ok":true,...}`가 아니면 body를 보강한 뒤 다시 실행한다. `check-test-plan`은 H2 또는 H3 ATX 헤더만 인식한다 (`## Test plan`, `### Test plan`, CommonMark의 closing `#` 마커 `## Test plan ##` 포함). 한국어 `## 테스트 계획`도 인식하며 case-insensitive다. 동급 또는 상위 레벨 헤더만 섹션을 종결하므로 `## Test plan` 아래의 `### Automated tests` 같은 하위 헤더는 본문으로 카운트된다. fenced code block (```` ``` ```` 또는 `~~~`) 내부의 헤더는 무시한다. HTML comment (`<!-- ... -->`) 내부의 헤더-처럼-생긴 라인과 섹션 안의 comment-only 라인은 reviewer에게 보이지 않으므로 content로 카운트하지 않는다. setext 헤더 (`Text\n---`)는 지원하지 않는다.

## Step 8.5 - Cycle Brief Gate

- 반영(land), ALL CLEAR, blocked, publish 금지 등 cycle을 끝내는 모든 경로에서 `finish-cycle-json`을 실행한다.
- `finish-cycle-json` ack JSON의 `rendered_markdown`을 사용자에게 먼저 보여준다.
- 이 브리핑이 사용자에게 보이기 전에는 `update_plan`으로 다음 task를 열거나, 다음 loop discovery를 시작하거나, 파일을 읽거나, 다른 tool을 호출하지 않는다.
- "사이클 N 완료" 같은 임의 요약은 허용되지 않는다. helper가 생성한 `rendered_markdown`을 임의로 축약하지 않는다.

## Step 9 - PR Merge Gate

- Step 8에서 저장한 `PR_NUMBER`와 `PR_BODY_FILE`을 사용해 방금 연 open PR의 body를 다시 검증한다. context reset 등으로 두 변수를 잃었으면 `PR_NUMBER="$(gh pr view --json number -q .number)"`로 현재 branch의 open PR을 다시 찾고, `PR_BODY_FILE`은 `PR_BODY_FILE="$(mktemp -t run-pr-body-XXXXXX.md)"`로 새 임시 파일을 만든 뒤 Step 8 본문을 재작성하거나 `gh pr view "$PR_NUMBER" --json body -q .body > "$PR_BODY_FILE"`로 복구한다.

  ```bash
  gh pr view "$PR_NUMBER" --json body -q .body | "$RUN_HELPER" check-test-plan
  ```

  ack가 `ok:false`면 (생성 직후 body가 누락됐거나, 사람/리뷰어가 섹션을 지운 경우) `gh pr edit "$PR_NUMBER" --body-file "$PR_BODY_FILE"`로 test plan을 복구한 뒤 다음 단계로 간다. 복구가 불가능하면 `result:"blocked"`로 종료한다.
- 검증을 통과하면 `/codex-loop "$PR_NUMBER"`를 실행한다. `--opus-review`가 있으면 `/codex-loop --opus-review "$PR_NUMBER"`로 실행한다.
- cwd는 그대로 task worktree 안이어도 안전하다. `/codex-loop` shim은 review/feedback 단계는 cwd에서 처리하고, land 단계만 자체적으로 safe non-head cwd로 이동해 `scripts/land-pr.sh`를 호출한다 (PR #68에서 land cwd split 도입). 호출이 끝난 뒤 caller cwd는 서브셸 격리로 그대로 유지된다.
- `/codex-loop`이 review feedback 처리, checks 확인, merge까지 완료해야 한다. 해당 PR이 merge되기 전에는 cycle을 마치거나 다음 loop로 넘어가지 않는다.
- merge 완료 후 Step 9 cleanup. `/codex-loop`은 cwd를 보존하므로 호출 직후 cwd는 task worktree 안이다. 다음을 그 순서대로 수행한다.

  ```bash
  # 1) cwd를 task worktree 밖으로 이동. 이 단계 없이 worktree를 제거하면 shell의 cwd가
  #    사라져 후속 명령이 "Unable to read current working directory"로 실패한다.
  MAIN_WT="$(git worktree list --porcelain | awk '/^worktree /{print; exit}' | sed 's/^worktree //')"
  cd "$MAIN_WT"

  # 2) base branch sync. $REVIEW_BASE를 어느 worktree가 잡고 있는지 먼저 찾는다 —
  #    primary일 수도 있고, 별도 linked worktree (operator가 base 전용으로 둔 경우) 일 수도 있다.
  BASE_WT="$(git -C "$MAIN_WT" worktree list --porcelain | awk -v ref="refs/heads/$REVIEW_BASE" '
    /^worktree /{wt=$0; sub(/^worktree /,"",wt)}
    $0 == "branch " ref {print wt; exit}
  ')"
  if [[ -n "$BASE_WT" ]]; then
    # base를 점유한 worktree에서 직접 ff-pull. 실패 (dirty, 충돌 등) 시 errors를 surface해 cycle을 멈춘다.
    git -C "$BASE_WT" fetch origin "$REVIEW_BASE" -q
    git -C "$BASE_WT" pull --ff-only origin "$REVIEW_BASE"
  else
    # 어느 worktree도 $REVIEW_BASE를 잡고 있지 않으면 local ref만 fast-forward.
    git -C "$MAIN_WT" fetch origin "$REVIEW_BASE:$REVIEW_BASE" -q
  fi

  # 3) task worktree 제거. squash merge --delete-branch 가 이미 remote/local branch를 지운 경우
  #    branch -D 는 no-op. 강제 삭제(--force) 는 사용하지 않는다.
  git -C "$MAIN_WT" worktree remove <task-worktree-path>
  git -C "$MAIN_WT" branch -D "$RUN_WORK_BRANCH" 2>/dev/null || true
  ```

- 이 cleanup이 끝나기 전에는 cycle을 마치거나 다음 loop로 넘어가지 않는다. base sync 단계가 dirty/충돌로 실패하면 그 errors를 그대로 surface해 사용자 정리 후 재시도하게 한다 (silent swallow 금지).

- 다음 task를 같은 worktree directory에서 시작하고 싶은 operator는 위 cleanup 대신 본인이 별도로 처리한다 (예: `cd <task-worktree-path> && git fetch origin "$REVIEW_BASE" -q && git checkout -B "<new>" "origin/$REVIEW_BASE"`). run의 canonical cleanup은 worktree 제거를 가정하고, 재사용 흐름은 cycle 외부에서 다음 cycle Step 1 sync 직전에 한다 (Step 1이 base를 또 fetch하므로 stale 위험을 피한다).

- Step 1 기준 상태가 깨끗한지 확인한 뒤 cycle 종료 처리를 한다.
- timeout, merge block, unresolved actionable feedback이면 `result:"blocked"` payload로 `finish-cycle-json`을 실행하고 중단한다.

## Step 10 - Opus Audit Gate

`--opus-audit-every <N>` flag가 있고 직전 cycle index가 N의 배수일 때만 수행한다. 그 외에는 이 step을 건너뛴다.

- read-only Opus sub-agent를 호출한다. 입력은 다음으로 제한한다:
  - 직전 N cycle의 brief log entries (`$RUN_BRIEF_JSONL` 또는 `${RUN_STATE_DIR:-.run}/run-briefs.jsonl`의 마지막 N개). **이게 canonical 검토 단위다.** cycle ↔ commit은 1:1이 아닐 수 있으므로 (zero-commit `all_clear` cycle, PR 피드백 다중 commit, rebase merge로 history 보존 등) git range는 commit 갯수가 아니라 cycle entry의 `repo.head` 기준으로 잡는다.
  - 직전 N cycle의 누적 git log와 diff. range는 brief log에서 뽑는다:
    ```bash
    # after_cycle = 방금 끝낸 cycle, N = audit_every
    # init-brief가 export한 RUN_BRIEF_JSONL / RUN_RUN_JSON 을 우선 사용한다.
    # 환경 변수가 누락된 context에서는 RUN_STATE_DIR을 통해 원래 .run을 찾는다.
    BRIEFS_JSONL="${RUN_BRIEF_JSONL:-${RUN_STATE_DIR:-.run}/run-briefs.jsonl}"
    RUN_JSON="${RUN_RUN_JSON:-${RUN_STATE_DIR:-.run}/run.json}"
    START_SHA="$(jq -r --argjson c "$((after_cycle - N))" 'select(.cycle == $c) | .repo.head' "$BRIEFS_JSONL" | head -1)"
    END_SHA="$(jq -r --argjson c "$after_cycle" 'select(.cycle == $c) | .repo.head' "$BRIEFS_JSONL" | head -1)"
    # 첫 audit (after_cycle == N)이면 cycle 0이 없어 START_SHA가 비어있다. init-brief가 run.json에 저장한 base_sha를 fallback으로 쓴다.
    if [[ -z "$START_SHA" ]]; then
      START_SHA="$(jq -r '.base_sha // empty' "$RUN_JSON")"
    fi
    git log --oneline "${START_SHA}..${END_SHA:-HEAD}"
    git diff --stat "${START_SHA}..${END_SHA:-HEAD}"
    ```
  - 현재 `docs/context/current-state.md` 또는 동등한 status ledger (있으면)
  - 직전 N cycle 동안 누적된 dossier `risk_triggers` 요약 (선택)
- Opus는 누적된 변경 방향성, codex finding 적용으로 인한 over-fit, 일관성 침식, 누적 ad-hoc 패턴, 빠진 후속 작업을 본다. 코드 수정/commit/push/PR 변경은 하지 않는다.
- 결과를 `audit-pass-json`에 넘기되 `--opus-audit-every`의 N을 첫 인자로 전달해 정확한 window 길이를 helper가 강제하도록 한다.

```bash
"$RUN_HELPER" audit-pass-json "$N" <<'JSON'
{
  "schema_version": 1,
  "after_cycle": <방금 끝낸 cycle 번호>,
  "over_cycles": [<검토한 cycle 번호 배열>],
  "summary_ko": "audit 결론",
  "findings": [
    {"summary_ko": "발견한 패턴", "severity": "high|medium|low (선택)"}
  ],
  "recommended_next": [
    {"id": "후속 task id 또는 라벨", "summary_ko": "권장 작업", "unblock_ko": "시작 조건 (선택)"}
  ],
  "no_action_reason_ko": "환기 결과 actionable 없음 (선택)"
}
JSON
```

- `over_cycles`는 정확히 N개, 1씩 증가하는 contiguous 배열로 채우고 마지막 항목이 `after_cycle`과 일치해야 한다 (예: `after_cycle=6`, `N=3`이면 `[4, 5, 6]`). 길이가 N이 아니거나 누락/future/non-contiguous cycle이면 helper가 거부한다.
- ack JSON의 `rendered_markdown`을 사용자에게 그대로 보여준 뒤 다음 cycle 또는 종료로 진행한다.
- audit pass가 실패하면 (Opus 실행 오류, `audit-pass-json` 거부, helper 오류 등 valid한 audit record가 만들어지지 않은 모든 케이스) **loop를 그 자리에서 멈추고 사용자에게 사유를 보고한다.** fail-open으로 진행하면 환기가 누락된 채로 후속 cycle이 돌아 audit gate가 무의미해진다. 사용자가 명시적으로 "이번 audit 건너뛰고 진행"을 지시한 경우에만 다음 cycle로 넘어간다.
- `recommended_next`는 다음 cycle Step 2 discovery에 참고 정보로 첨부할 수 있다.

## Loop

`--loop` 또는 `--loop N`이면 cycle brief를 append하고 사용자에게 보여준 뒤, Step 10 (Opus Audit Gate) 진입 조건이 맞으면 audit pass를 1회 수행한 다음 다음 cycle로 간다. 단, 직전 cycle이 `all_clear`이고 ack의 `auto_promotions_count`가 `0`이면 loop를 종료한다. 직전 cycle이 `all_clear`라도 `auto_promotions_count > 0`이면 새 ready 작업이 생긴 것이므로 다음 cycle로 계속 진행한다. 그 외에는 Step 1로 돌아간다. 이어받은 cycle에서는 brief log의 run id와 git log를 확인해 현재 loop의 이전 cycle만 복원한다.

종료 시 `"$RUN_HELPER" summary-json`을 실행하고 summary JSON의 `rendered_markdown`을 `최종 브리핑`으로 사용자에게 보여준다. 임의로 축약하지 않는다.
