---
name: dev-cycle
description: "전체 개발 사이클: sync → discover → implement → verify → review → ship. 플래그: --loop [N], --phase <id>"
---

# Dev Cycle

## Flags

- `--loop`: cycle 완료 후 Step 1부터 반복한다. Step 3에서 **ALL CLEAR**이면 종료한다.
- `--loop N`: 정확히 N회 반복한다.
- `--phase <id>`: 탐색과 구현 범위를 해당 roadmap/task/phase id로 제한한다. 값을 파싱하거나 변환하지 않는다.

## Invariants

- Step이 끝나면 사용자 입력 없이 다음 Step으로 진행한다.
- 멈추는 경우: **ALL CLEAR**, 사용자 승인 없이는 안전하지 않은 분기, 인증/권한/destructive git state, 해결 불가 blocker.
- 사용자에게 보이는 보고, brief, finding, 질문은 한국어로 작성한다. 코드, 명령, 파일명, 원문 인용은 원문 언어를 유지한다.
- repo type, review base, sync, brief log, risk issue 처리는 helper가 담당한다.
- helper 경로는 아래 순서로 찾는다.

```bash
DEV_CYCLE_HELPER=".agents/scripts/dev-cycle-helper.sh"
[ -x "$DEV_CYCLE_HELPER" ] || DEV_CYCLE_HELPER="$HOME/.agents/scripts/dev-cycle-helper.sh"
[ -x "$DEV_CYCLE_HELPER" ] || { echo "Missing dev-cycle-helper.sh"; exit 1; }
```

## Brief Log

새 실행의 첫 cycle에서만 초기화한다.
`init-brief`는 `.dev-cycle/dev-cycle-run-id`와 `.dev-cycle/dev-cycle-briefs.md`를 만들고 export를 출력한다. Bash 호출 사이에 export가 사라져도 `finish-cycle`과 `summary`는 저장된 state를 검증해 이어 쓴다.

```bash
eval "$("$DEV_CYCLE_HELPER" init-brief)"
```

이어서 실행하는 cycle이라면 `DEV_CYCLE_RUN_ID`와 `DEV_CYCLE_BRIEF_LOG`를 재사용하기 전에 반드시 검증한다.

```bash
"$DEV_CYCLE_HELPER" validate-brief "$DEV_CYCLE_RUN_ID" "$DEV_CYCLE_BRIEF_LOG"
```

검증 실패 또는 확신이 없으면 새 실행으로 보고 `init-brief`를 다시 실행한다. 단, cycle 종료 시점의 누락된 환경변수를 복구하려고 `init-brief`를 다시 실행하지 않는다. 그것은 새 brief log를 시작한다.

Cycle 종료 시 아래 값을 채워 helper로 brief를 출력하고 append한다. **ALL CLEAR, blocked, publish 금지로 종료하는 경우도 먼저 `finish-cycle`을 실행한다.** `Risk`가 비어 있지 않으면 helper가 GitHub issue를 만들고 issue URL을 brief에 기록한다. issue 생성에 실패하면 helper가 `blocked` brief를 append하고 중단한다.
`finish-cycle`의 stdout은 tool output일 뿐 사용자에게 자동 전달되지 않는다. `finish-cycle` 직후에는 출력된 cycle brief를 사용자에게 한국어로 보고한다. `--loop` 또는 `--loop N`이면 이 보고를 마친 뒤에만 다음 Step 1로 돌아간다.

```bash
DEV_CYCLE_CYCLE=<N> \
DEV_CYCLE_RESULT="<DOC FIX / NEXT TASK / ALL CLEAR / shipped / blocked>" \
DEV_CYCLE_WORK="<주요 변경 또는 판단 1줄>" \
DEV_CYCLE_VERIFICATION="<검증 결과>" \
DEV_CYCLE_REVIEW_SHIP="<review/ship 결과>" \
DEV_CYCLE_RISK="<남은 리스크 또는 없음>" \
DEV_CYCLE_NEXT_ACTION="<리스크 후속 작업>" \
"$DEV_CYCLE_HELPER" finish-cycle
```

## Step 1 - Sync

```bash
"$DEV_CYCLE_HELPER" sync
REPO_TYPE="$("$DEV_CYCLE_HELPER" repo-type)"
REVIEW_BASE="$("$DEV_CYCLE_HELPER" review-base)"
echo "Repo type: $REPO_TYPE"
echo "Review base: $REVIEW_BASE"
```

## Step 2 - Discover

`/codex:rescue --fresh --wait`를 foreground로 실행한다. `--phase <id>`가 있으면 프롬프트에 그대로 넣는다.
`/codex:rescue`에 전달하는 프롬프트는 영어로 작성한다. 반환 결과를 사용자에게 보고할 때는 한국어로 정리한다.

Prompt:

```text
Choose one task for the next cycle based on this repo's guidance, README, roadmap, thin docs, source, and tests.
Read long design/archive/generated documents only when needed.
Prefer implementation candidates. Choose docs-only only when there is no code work to do and only docs are wrong.
If both docs and code are needed, return it as an implementation task and include docs update in the acceptance criteria.
If --phase is present, inspect only that id's scope.

Return one of:
## NEXT TASK
<one task including files/areas, acceptance criteria, docs update, and validation>

## DOC FIX NEEDED
<docs-only fix list>

## ALL CLEAR
<current state summary>
```

## Step 3 - Decide

- **ALL CLEAR**: `DEV_CYCLE_RESULT="ALL CLEAR"`로 `finish-cycle`을 실행한 뒤 종료한다.
- **NEXT TASK**: Step 4로 간다.
- **DOC FIX NEEDED**: Step 4로 가되 작업 type은 `docs`.

## Step 4 - Implement

- Direct-push repo: `main`에서 직접 작업한다.
- Standard repo: default branch에서 시작했다면 `<type>/<short-description>` 브랜치를 만들고, 이미 작업 브랜치면 유지한다.
- Step 2의 task를 구현한다. docs update가 acceptance criteria면 같은 cycle에서 처리한다.
- `--phase <id>` 범위를 벗어난 작업은 하지 않는다.

## Step 5 - Verify

`/verify`를 실행한다. 완료 후 멈추지 말고 분기한다.

- pass 또는 누락 수정 완료: Step 6.
- 해결 불가 blocker: `DEV_CYCLE_RESULT="blocked"`로 `finish-cycle`을 실행하고 중단.

## Step 6 - Review

리뷰 직전 다시 계산한다.

```bash
REVIEW_BASE="$("$DEV_CYCLE_HELPER" review-base)"
```

- Direct-push repo: local diff, staged diff, untracked files, 또는 unpublished `origin/main...HEAD`를 리뷰한다.
- Standard repo: `$REVIEW_BASE...HEAD` 기준으로 리뷰한다.
- Review Pass는 diff review와 impact triage/scan이 함께 통과한 상태다. impact scan을 review OK 이후 별도 단계로 두지 않는다.
- Impact triage: docs/typo/leaf/test-only처럼 외부 surface가 없으면 `Impact: local only`로 끝낸다.
- 위험 trigger: shared helper/API, command/skill, deploy/build/test infra, config/env/schema, persistence, auth/security, public CLI/output, 파일 경로/계약 변경, 변경 파일 5개 초과. 해당하면 변경된 symbol/path/env/command를 `rg`로 repo 전체에서 추적해 call site/docs/tests/deploy refs를 확인한다.
- findings는 batch로 정리한다. actionable finding은 같은 cycle에서 한 번에 수정하고 targeted verify 후 Review Pass를 반복한다. fix가 surface를 넓히지 않았으면 다음 pass는 추가 diff 중심으로 본다.
- 새 기능/아키텍처 변경, 보안/인증 관련이면 adversarial review를 우선한다.
- 최대 5회 반복한다. 5회 후 남은 actionable finding은 GitHub issue로 남기고 Step 7로 간다.

## Step 7 - Local Checks

repo guidance와 docs/testing에 정의된 full/pre-PR 검증을 실행한다. 실패하면 수정 후 Step 7을 반복한다.

## Step 8 - Ship

- Direct-push repo: 의도한 파일만 stage, commit, `git push origin main`. PR은 만들지 않는다.
- Standard repo: 의도한 파일만 stage, commit, 현재 branch push, `gh pr create --base "$REVIEW_BASE" --draft=false`, `/codex-loop`, 통과 시 squash merge.
- 사용자가 publish 금지를 명시했으면 여기서 멈추고 local state만 보고한다.

## Loop

`--loop` 또는 `--loop N`이면 cycle brief를 append하고 사용자에게 보여준 뒤 Step 1로 돌아간다. 이어받은 cycle에서는 brief log의 run id와 git log를 확인해 현재 loop의 이전 cycle만 복원한다.

종료 시 `"$DEV_CYCLE_HELPER" summary`를 근거로 전체 결과를 8줄 이내로 보고한다.
