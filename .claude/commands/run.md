---
name: run
description: "Thin /run wrapper over scripts/run-registry.sh — registers the current single-agent run, surfaces active-run collisions, releases on exit. /run-team은 PA-3.1 슬라이스로 분리."
---

# /run

`/run`은 단일 에이전트 dev cycle을 시작하기 전에 `scripts/run-registry.sh`로
현재 작업 세션을 register하는 thin wrapper다. PA-1.0 design
(`docs/design/systems/run-registry.md`) §1~§7과 PA-1.1 helper의 cooperative
file-lock contract를 그대로 따른다. 본 skill은 새 state machine을 만들지
않으며 helper 호출의 deterministic UX 층만 담당한다.

사용자에게 보이는 보고, 에러, 안내는 한국어로 작성한다. 명령, 파일명,
JSON 키, helper 인자는 원문 언어를 유지한다.

DEC-031 분기와 DEC-032 (Q-037) layered enforcement: 본 wrapper는 cooperative
layer만 강제한다. 실제 `git switch main` 거부는 PA-1.2 sync_repo guard가
담당하고, merge 거부는 PA-2.2 land-pr helper가 담당한다.

## 호출 표면

- 단일 에이전트: `/run "<topic 또는 task 요약>"`
- 멀티 에이전트 (`/run-team`): **본 슬라이스 범위 밖**이다. PA-3.1에서 별도
  skill로 추가한다. 본 wrapper는 `--team` flag form을 받으면 친절한
  redirect로 거부한다 (DEC-030/§7).

## 진입 규칙

### --team flag form 거부

helper의 `lock_path_for` 검증과 같은 규칙을 wrapper에서도 따라야 한다.
첫 인자가 `--team` 또는 `-team` literal flag form이면 즉시 안내 후 종료:

```
ERROR: --team is not a valid flag for /run. Did you mean /run-team?
       (/run-team is tracked under PA-3.1 and is not implemented yet.)
```

bare `team`이 첫 인자로 와도 wrapper는 topic으로 받는다 (예: `/run "team
productivity"`). DEC-030 D6.

### Helper 경로 resolution

dev-cycle-helper.sh와 같은 lookup 순서. F6 acceptance pin.

```bash
# Repo-local helper는 작업 디렉터리가 아니라 repo root 기준으로 찾는다.
# subdirectory에서 /run을 호출해도 같은 helper를 보도록 한다.
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

## Sub-actions (단일 진입)

`/run` 단일 호출이 다음을 순서대로 수행한다.

### 1. workspace identity resolution

```bash
WS="$(pwd -P)"
REPO_ID="$("$RUN_REGISTRY" identity --workspace "$WS")"
```

helper가 origin-only normalization을 적용한다. origin remote가 없는
git repo는 `local__<hash>` 형태로 정상 식별되므로 exit 0이다. exit 2는
workspace가 git repo가 아닐 때만 발생한다. wrapper는 exit 2면 사용자에게
"git repo가 아니다"를 보고하고 종료한다.

### 2. active-run collision check

```bash
# list 직전 silent gc로 crashed prior run의 stale entry를 회수한다.
# 회수 실패는 무시 — gc는 best-effort, list가 진짜 active만 남기게 한다.
"$RUN_REGISTRY" gc --repo "$REPO_ID" >/dev/null 2>&1 || true
ACTIVE_JSON="$("$RUN_REGISTRY" list --repo "$REPO_ID")"
ACTIVE_COUNT="$(printf '%s' "$ACTIVE_JSON" | jq 'length')"
```

`ACTIVE_COUNT > 0`이면 같은 logical repo에 다른 active run이 있다는 의미.
wrapper는 collision UX를 한국어로 출력한다:

```
ERROR: 이미 active 상태인 run이 이 logical repo (<REPO_ID>)에 있다.
  active runs: <jq로 run_id/workspace_path/type/started_at 줄 단위 출력>

옵션:
  1) 기존 run이 끝날 때까지 기다린다.
  2) 다른 worktree에서 실행한다 (concurrent workspace는 PA-1.x deferred).
  3) 기존 run을 끝낸 사용자가 직접 release하지 않은 stale이면:
       "$RUN_REGISTRY" gc --repo <REPO_ID>
     로 stale 회수를 시도할 수 있다. helper는 PATH에 없을 수 있으므로
     wrapper가 위에서 resolve한 $RUN_REGISTRY 경로를 그대로 사용한다.

본 wrapper는 cooperative-only다. 직접 git/gh를 호출해 main을 만지면
이 가드가 적용되지 않는다 (DEC-032). PA-1.2 sync_repo guard와 PA-2.2
land-pr helper가 land된 후에야 실제 거부가 강제된다.

wrapper의 cooperative pre-check는 한국어 UX만 담당한다. race-free 보장은
helper `cmd_register`가 PA-1.1c에서 repo-scoped lock 안에 active scan을
다시 수행하고 collision이면 자체로 exit 6 + `active_run_collision` JSON을
반환한다. wrapper가 active=0을 봤더라도 helper가 race condition을 막는다.
```

`--allow-additional` 같은 force flag는 본 슬라이스에서 만들지 않는다. PA-3.1
`/run-team` orchestrator 슬라이스에서 explicit UX로 추가한다.

### 3. register

collision 없으면 register:

```bash
# AGENT는 wrapper를 호출하는 surface로 설정한다 — Claude Code면 "claude",
# Codex면 "codex", 그 외엔 "other". 본 skill은 두 surface로 모두 렌더되므로
# 본문에 literal을 박지 않고, surface가 미리 export하지 않은 환경에서도
# helper가 거부하지 않도록 "other" fallback을 둔다.
AGENT="${AGENT:-other}"
case "$AGENT" in claude|codex|other) ;; *) AGENT=other ;; esac
REG_JSON="$("$RUN_REGISTRY" register --type solo --workspace "$WS" --agent "$AGENT")"
RUN_ID="$(printf '%s' "$REG_JSON" | jq -r .run_id)"
echo "registered: $RUN_ID"
```

`--agent`는 현재 실행 중인 agent surface로 설정 (Claude Code = `claude`,
Codex = `codex`, 기타 = `other`). helper의 numeric env validation은
caller PID 해석을 PPID로 fallback한다 — wrapper는 명시적
`--pid` 전달이 필요한 경우에만 사용.

### 4. exit trap: release

wrapper가 호출한 shell에 trap을 건다. 정상 종료, SIGINT, SIGTERM 모두 release를
실행한다 (PA-1.0 §8 caller-side SIGINT/SIGTERM trap 책임).

```bash
trap "'$RUN_REGISTRY' release '$RUN_ID' >/dev/null 2>&1 || true" EXIT INT TERM
```

trap이 자동으로 acquire한 모든 lock도 동시에 release한다 (helper의
release subcommand가 release_all_locks_for_run을 호출).

### 5. heartbeat (선택)

긴 작업이면 wrapper가 background에서 주기적으로 heartbeat를 보낼 수
있다. 본 슬라이스는 시점만 명시: dev-cycle / `/run-team` 같은 상위
workflow가 자체 heartbeat loop를 둔다. wrapper 자체는 heartbeat 자동화를
추가하지 않는다 — PA-1.3 brief preservation 슬라이스에서 함께 다룰
가능성이 있다.

## 신뢰 경계

- helper output은 untrusted input이다. wrapper는 helper의 JSON 응답을
  jq로만 파싱하고, 사용자 메시지로 들어간 자유 텍스트(예: workspace path)는
  쉘 단어 분리 위험을 피해 따옴표로 감싼다.
- cooperative-only enforcement: wrapper는 advisory layer다. PA-1.2/PA-2.2가
  실제 거부 layer를 만들기 전까지 caller가 helper를 우회하면 가드가
  작동하지 않는다. 메시지에 명시한다.

## 테스트

`/run` skill 자체는 LLM-driven instruction이라 unit test로 fully 검증
불가능하다. 다음을 acceptance로 둔다 (`TEST-PA-1a`):

- helper script가 PR #16 evidence(`run-registry.sh` + 51/51 tests)로
  이미 검증되어 있다.
- skill markdown contract — `--team` rejection 문구, helper lookup 순서,
  collision UX 한국어 본문, exit trap의 release 호출 — 가 명시적으로
  적혀 있다.
- caller-side SIGINT/SIGTERM trap이 release를 호출한다는 점을 design doc
  §8과 본 skill 양쪽에서 일관되게 명시.

자동 검증: PR diff에 본 skill이 위 contract를 모두 포함하는지 작성자가
확인한다. dogfood는 첫 사용자가 `/run`을 실행해보고 collision UX가 한국어로
정상 출력되는지 보고 `docs/current/DOGFOOD-LOG.md`에 기록한다.

## Lineage

- Source: PA-1.0 design doc §1~§7 + DEC-030 D6 (`--team` rejection) +
  DEC-031 (PA slice inventory) + DEC-032 (Q-037 layered enforcement).
- 본 슬라이스 (`PA-1.1b`)는 `/run` 단일 에이전트 wrapper만 다룬다.
  `/run-team` orchestrator는 PA-3.1.
