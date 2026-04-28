---
name: dev-cycle
description: "전체 개발 사이클: sync -> implementation discovery -> implement -> verify -> review -> ship. 플래그: --loop [N], --phase <id>"
---

# Dev Cycle

## 플래그

- `--loop`: 한 사이클 완료 후 Step 1부터 재시작한다. Step 3에서 **ALL CLEAR**
  반환 시 종료한다.
- `--loop N`: 정확히 N회 반복 후 종료한다.
- `--phase <id>`: 구현 대상을 프로젝트 로드맵의 특정 Phase로 한정한다.
  `<id>`는 프로젝트 문서에 있는 식별자를 그대로 전달한다.

## 실행 원칙

각 단계가 완료되면 사용자 입력 없이 다음 단계로 진행한다. 중간 결과만 보고하고
대기하지 않는다.

멈추는 경우는 아래뿐이다:

- Step 3에서 **ALL CLEAR** 반환
- 사용자 승인 없이는 안전하게 진행할 수 없는 분기
- 사이클 전체 완료
- 인증, 권한, destructive git state 등으로 진행 불가

## Branch / PR 원칙

기본은 PR-first workflow다.

- `main` / `master` / default branch에서는 작업 브랜치를 만든다.
- 이미 작업 브랜치에 있으면 현재 브랜치를 유지한다.
- direct push는 사용자가 명시적으로 요청한 경우에만 한다.
- stage는 항상 의도한 파일만 명시한다.

## Review / PR base 결정

리뷰와 PR 생성에 사용할 base는 매번 명시적으로 계산한다.

```bash
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
case "$REPO_NAME" in
  actwyn|concluv|boilerplate|statistics-for-data-science)
    REVIEW_BASE=main
    ;;
  *)
    REVIEW_BASE="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)"
    if [ -z "$REVIEW_BASE" ]; then
      if git show-ref --verify --quiet refs/remotes/origin/dev; then
        REVIEW_BASE=dev
      else
        REVIEW_BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
        if [ -z "$REVIEW_BASE" ]; then
          REVIEW_BASE="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)"
        fi
        [ -z "$REVIEW_BASE" ] && REVIEW_BASE=main
      fi
    fi
    ;;
esac
echo "Review base: $REVIEW_BASE"
```

판단 기준:

- Direct-push 리포의 ship target은 항상 `main`이다. review diff 선택은 Step 6의
  "Direct-push diff 기준"을 따른다.
- 현재 브랜치에 PR이 있으면 그 PR의 base branch를 사용한다.
- PR이 없고 `origin/dev`가 있으면 `dev`를 사용한다.
- 둘 다 없으면 원격 default branch를 사용하고, 감지 실패 시 `main`으로 fallback한다.
- 코드 리뷰 도구를 호출할 때는 계산된 base를 `--base <branch>`로 명시한다.

## 사이클 브리핑 로그

각 사이클이 끝날 때 사용자가 바로 읽을 수 있는 짧은 브리핑을 출력하고, loop 종료 시
종합 브리핑할 수 있도록 이번 `dev-cycle` 실행 동안만 repo-local 임시 로그에 누적한다.

로그 파일은 git에 잡히지 않도록 `.git` 내부에 둔다. 새 `dev-cycle` 실행을 시작할
때마다 파일을 overwrite하므로 이전 실행 브리핑은 섞지 않는다.

```bash
DEV_CYCLE_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
DEV_CYCLE_BRIEF_LOG="$(git rev-parse --git-dir)/dev-cycle-briefs.md"
printf "# Dev Cycle Briefs %s\n\n" "$DEV_CYCLE_RUN_ID" > "$DEV_CYCLE_BRIEF_LOG"
```

새 `dev-cycle` 실행의 첫 사이클을 시작할 때만 위 초기화를 수행한다. context compaction
이후 이어받은 사이클에서는 context에 남은 `DEV_CYCLE_RUN_ID`와 `DEV_CYCLE_BRIEF_LOG`를
재사용하고 기존 내용을 읽어 계속 append한다. 즉, 한 파일에 계속 쌓이는 범위는 현재
loop 실행 하나뿐이다.

각 사이클 종료 시 아래 형식으로 5줄 이내 브리핑을 출력하고 같은 내용을
`$DEV_CYCLE_BRIEF_LOG`에 append한다:

```md
## Cycle <N>
- Result: <DOC FIX / NEXT TASK / ALL CLEAR / shipped / blocked>
- Work: <주요 변경 또는 판단 1줄>
- Verification: <실행한 검증과 결과>
- Review/Ship: <review 결과, PR/merge/push 결과>
- Risk: <남은 리스크 또는 없음>
```

loop 모드가 끝나면 `$DEV_CYCLE_BRIEF_LOG`를 읽어 전체 iteration의 종합 브리핑을
8줄 이내로 다시 출력한다. 로그 파일이 없으면 `git log`, `git status`, 현재 context
요약을 근거로 복원하되, 복원임을 명시한다.

## Step 1 - Sync

1. repo와 현재 브랜치를 확인한다.

   ```bash
   git status -sb
   git branch --show-current
   git remote get-url origin
   ```

2. 원격을 가져온다.

   ```bash
   git fetch origin
   ```

3. default branch에서 시작했다면 최신 원격 default branch로 fast-forward한다.
   fast-forward가 불가능하면 멈추고 원인을 보고한다.

## Step 2 - 구현 후보 탐색

로컬에서 직접 탐색한다. 문서는 구현 의도를 파악하기 위한 입력이며, 선택된 구현 작업의
acceptance criteria에 필요한 문서 정합성 복구를 포함한다. 단, 구현 후보가 있는데
문서 수정만 하는 사이클로 빠지지 않는다.

읽기 순서:

1. `AGENTS.md`, README, repo-local guidance 중 존재하는 파일
2. roadmap, `docs/ARCHITECTURE.md`, `docs/CODE_MAP.md`, `docs/TESTING.md` 등 얇은 핵심 문서
3. task/phase와 직접 관련된 소스, 테스트, 문서

긴 설계 문서, archive, generated file은 기본으로 열지 않는다. `--phase <id>`가
지정된 경우 해당 Phase 범위에 필요한 문서와 코드만 읽는다.

탐색 항목:

- 문서에 있지만 미구현된 기능
- 미완성 구현, TODO, 알려진 버그, 테스트 공백
- 구현은 있지만 검증/문서 갱신이 필요한 기능
- 코드가 맞고 문서만 오래된 경우의 docs-only 불일치

판단 기준:

- 문서가 맞고 코드가 부족하면 구현 작업으로 반환한다.
- 코드가 맞고 문서만 오래됐으면 문서 작업으로 반환한다.
- 구현과 문서가 둘 다 필요하면 구현 작업으로 반환하고 문서 갱신을 acceptance criteria에 포함한다.
- 구현 도중 문서가 더 틀어질 수 있는 항목은 Step 4/5에서 같이 갱신하도록 명시한다.

반환 형식은 아래 중 정확히 하나다:

**## NEXT TASK**

다음 구현할 기능, 버그 수정, 테스트 보강, 또는 코드 개선 작업의 명확한 작업 설명.
파일/영역, acceptance criteria, 필요한 문서 갱신, 필요한 검증을 포함한다.
구현과 문서가 둘 다 필요하면 이 형식을 선택한다.

**## DOC FIX NEEDED**

구현할 코드 작업이 없고 문서만 틀렸을 때만 선택한다. 파일명과 수정 내용을 포함한
구체적인 문서 수정 목록을 작성한다.

**## ALL CLEAR**

구현 작업도 문서 수정도 없을 때만 선택한다. 현재 상태 요약.

## Step 3 - 결과 판단

- **ALL CLEAR:** 현재 상태를 보고하고 중단한다.
- **NEXT TASK:** Step 4로 진행, 작업 유형은 내용에 따라 정한다.
- **DOC FIX NEEDED:** 구현 후보가 없고 문서만 틀린 경우에만 Step 4로 진행, 작업 유형은 `docs`.

## Step 4 - 브랜치 생성 & 구현

브랜치 명명: `codex/<짧은-설명>` 또는 `<type>/<짧은-설명>`.

`<type>`은 conventional commit 타입 중 적절한 것을 사용한다:
`feat` / `fix` / `docs` / `refactor` / `perf` / `test` / `chore`.

구현 원칙:

- `update_plan`으로 작은 작업 단위를 만든다.
- 기존 코드 스타일과 repo 경계를 따른다.
- 수동 편집은 `apply_patch`를 사용한다.
- 런타임 동작, schema, env, validation command를 바꾸면 repo guidance의 문서
  갱신 규칙을 따른다.
- Step 2가 문서 갱신을 acceptance criteria로 포함했다면 코드/테스트 변경과 같은
  사이클 안에서 처리한다.
- `--phase <id>`가 지정된 경우 범위를 벗어난 작업은 하지 않는다.

## Step 5 - Verify

`verify` 스킬의 절차를 같은 세션에서 수행한다.

- 요구사항을 체크리스트로 재분해한다.
- 구현/테스트/문서 누락을 찾는다.
- 누락이 있으면 수정하고 관련 검증을 다시 실행한다.
- 구현 완료 후 관련 thin docs가 실제 코드와 맞는지 확인한다.
- 최종적으로 repo가 정의한 full/pre-PR 검증 명령을 실행한다.

verify가 완료되면 사용자 입력을 기다리지 말고 즉시 아래 기준으로 분기한다:

- verify가 pass이면 Step 6으로 진행한다.
- verify가 누락을 수정했다면 수정 결과를 확인하고 Step 6으로 진행한다.
- verify가 해결 불가 blocker를 보고했을 때만 사용자에게 blocker를 보고하고 멈춘다.

## Step 6 - Code Review Pass

`REVIEW_BASE`를 계산한 뒤 로컬 code-review stance로 자체 리뷰를 수행한다. 결과는
findings first로 정리한다.

Direct-push diff 기준:

- `main...HEAD`가 비었다고 리뷰 대상이 없다고 판단하지 않는다.
- worktree/staged/untracked 변경이 있으면 `git diff`, `git diff --cached`,
  `git ls-files --others --exclude-standard` 기준으로 로컬 변경사항을 리뷰한다.
- worktree가 clean이고 unpublished commit이 있으면 `origin/main...HEAD` 기준으로
  리뷰한다. `origin/main`이 없을 때만 `main...HEAD`를 fallback으로 사용한다.

집중 기준:

- 버그, behavioral regression, missing test
- security/auth/data-loss 위험
- schema/runtime/docs 불일치
- 변경 범위를 벗어난 refactor

루프 절차:

1. 현재 diff를 리뷰한다. Direct-push는 위 "Direct-push diff 기준"을 따르고,
   Standard 리포는 `$REVIEW_BASE...HEAD` 기준으로 리뷰한다.
2. actionable finding이 있으면 수정하고 관련 테스트를 실행한다.
3. 최대 5회 반복한다.
4. 5회 초과 후에도 남은 항목은 GitHub issue로 남기고 Step 7로 진행한다.

## Step 7 - 로컬 테스트 & CI 검증

프로젝트의 문서화된 검증 명령을 실행한다.

일반 자동 감지 순서:

- `docs/TESTING.md`
- `package.json#scripts`
- `Makefile`
- 언어별 표준 test config (`pyproject.toml`, `go.mod`, `Gemfile` 등)

결과 분기:

- 전부 통과 -> Step 8로 진행
- 실패 -> 원인 파악 후 수정, Step 7 재실행

## Step 8 - Ship

사용자가 ship/PR/merge를 요청한 경우에만 publish한다.

1. `git status -sb`와 staged diff를 확인한다.
2. 의도한 파일만 stage한다.
3. commit한다.
4. push한다.
5. GitHub app 또는 `gh pr create --base "$REVIEW_BASE"`로 PR을 연다.
6. review 대기가 필요하면 `codex-loop` 절차를 수행한다.
7. 사용자가 merge까지 요청했고 checks/review가 통과하면 PR을 merge한다.

## 루프 재시작

Step 8 완료 후 루프 모드에 따라 동작한다:

| 모드 | 종료 조건 |
| ---- | --------- |
| `--loop` | Step 3에서 ALL CLEAR 반환 시 |
| `--loop N` | N회 완료 시 |

각 사이클 종료 시 반드시 "사이클 브리핑 로그" 절차를 수행한다. 즉, 이번 사이클
브리핑을 출력하고 `$DEV_CYCLE_BRIEF_LOG`에 append한 뒤 다음 iteration으로 넘어간다.
context가 압축되더라도 `DEV_CYCLE_RUN_ID`, `$DEV_CYCLE_BRIEF_LOG`, git log, 문서에서
이전 사이클 작업 내역을 재확인할 수 있다.

루프를 재시작할 때는 `git log`, `git status`, 관련 문서를 다시 확인해 이전 사이클
결과를 복원한다. 종료 시 총 실행 횟수, 마지막 상태, `$DEV_CYCLE_BRIEF_LOG` 기반
종합 브리핑을 사용자에게 보고한다.
