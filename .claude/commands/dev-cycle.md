---
name: dev-cycle
description: "전체 개발 사이클: pull → doc 정합성 감사(codex) → 구현 → verify → review → ship. 플래그: --loop [N], --phase <id>"
---

# Dev Cycle

## 플래그

- `--loop` : 한 사이클 완료 후 Step 1부터 자동 재시작. Step 3에서 **ALL CLEAR** 반환 시 종료. (총 8단계)
- `--loop N` : 정확히 N회 반복 후 종료 (ALL CLEAR 무관).
- `--phase <id>` : 구현 대상을 프로젝트 로드맵의 특정 Phase로 한정한다. `<id>`는 프로젝트 문서에 있는 식별자를 그대로 전달한다 (예: `"Judgment System 1B"`, `TASK-011`, `"orchestrator Phase 4"`). 파싱하거나 변환하지 않는다. Step 2(doc 감사)와 Step 4(구현) 양쪽에서 이 id를 참고해 범위를 좁힌다.

---

## 실행 원칙

**각 단계가 완료되면 사용자 입력 없이 즉시 다음 단계로 진행한다.** 스킬(verify, codex:rescue 등)이 완료되어 제어가 돌아와도 멈추지 않는다. 중간 결과를 보고하며 대기하지 않는다.

멈추는 경우는 아래뿐이다:
- Step 3에서 **ALL CLEAR** 반환
- Step 3에서 **DOC FIX NEEDED** 또는 **NEXT TASK** 반환 후 사용자 승인이 명시적으로 필요한 경우
- 사이클 전체 완료
- 오류로 인해 진행 불가

---

아래 단계를 순서대로 실행하라.

---

## 리포지토리 유형 정의

**Direct-push 리포 (main에 직접 커밋/push):**
- actwyn
- concluv
- boilerplate
- statistics-for-data-science

리포 이름이 위 목록에 있으면 Direct-push 리포로 취급한다.

그 외 모든 리포는 **Standard 리포** (feat/* → dev → main PR 워크플로우).

사이클 시작 전 `git remote get-url origin` 으로 리포 이름을 확인하고, 이후 모든 분기 판단에 사용한다.

---

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

- Direct-push 리포는 항상 `main`을 base로 사용하고, review command에도 `--base main`을 직접 쓴다.
- 현재 브랜치에 PR이 있으면 그 PR의 base branch를 사용한다.
- PR이 없고 `origin/dev`가 있으면 `dev`를 사용한다.
- 둘 다 없으면 원격 default branch를 사용하고, 감지 실패 시 `main`으로 fallback한다.
- slash command에서 shell 변수 확장이 보장되지 않으면 계산된 실제 branch 이름을 넣는다.

---

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

새 `dev-cycle` 실행의 첫 사이클을 시작할 때만 위 초기화를 수행한다. `/compact` 이후
이어받은 사이클에서는 요약에 남은 `DEV_CYCLE_RUN_ID`와 `DEV_CYCLE_BRIEF_LOG`를 재사용하고
기존 내용을 읽어 계속 append한다. 즉, 한 파일에 계속 쌓이는 범위는 현재 loop 실행
하나뿐이다.

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
8줄 이내로 다시 출력한다. 로그 파일이 없으면 `git log`, `git status`, 현재 대화
요약을 근거로 복원하되, 복원임을 명시한다.

---

## Step 1 — Sync (Claude 실행)

```bash
git fetch origin
git pull origin main
```

**Standard 리포:** dev 브랜치도 최신화한다.

```bash
git checkout dev
git pull origin dev
git checkout -  # 원래 브랜치로 복귀
```

---

## Step 2 — 문서 정합성 감사 (codex:rescue 위임)

`codex:rescue` 스킬을 호출하여 다음 프롬프트를 전달하라.
**반드시 이전 codex 스레드를 이어받지 말고 새 세션으로 시작할 것** (`--no-continue` 또는 새 스레드 옵션 명시).

`--phase <id>` 가 지정된 경우, 프롬프트에 "구현 대상: `<id>`" 를 명시하여 codex가 해당 Phase 범위에 집중하도록 한다.

---

이 리포지토리의 문서와 구현 상태의 정합성을 감사하고, 다음 작업을 식별하라.

**수행 절차:**

1. 모든 문서 파일을 읽어라 (README.md, CLAUDE.md, ARCHITECTURE.md, docs/**, 기타 문서 파일)
2. 현재 구현 상태를 파악하라:
   - `git log --oneline -30`으로 최근 커밋 흐름 확인
   - 주요 소스 디렉토리 및 파일 탐색
3. 문서와 코드 사이의 불일치를 식별하라:
   - 문서에 있지만 미구현된 기능
   - 구현되었지만 문서에 없는 기능
   - 오래되거나 잘못된 설명
4. TODO, 미완성 구현, 개선 가능한 부분에서 다음 작업을 도출하라
   - `--phase <id>` 가 지정된 경우, 해당 Phase 범위의 작업만 도출한다

**반환 형식 — 아래 중 정확히 하나를 선택:**

**## DOC FIX NEEDED**
[파일명과 수정 내용을 포함한 구체적인 불일치 목록. Claude가 바로 실행 가능한 프롬프트 형태로 작성.]

**## NEXT TASK**
[다음 구현할 기능이나 개선 작업의 명확한 프롬프트. 충분한 컨텍스트 포함.]

**## ALL CLEAR**
[현재 상태 요약. 추가 작업 없음.]

---

## Step 3 — 결과 판단 (Claude 실행)

- **ALL CLEAR:** 사용자에게 현재 상태를 보고하고 중단한다.
- **DOC FIX NEEDED:** Step 4로 진행, 작업 유형은 `docs`
- **NEXT TASK:** Step 4로 진행, 작업 유형은 codex가 반환한 내용에 따라 결정

---

## Step 4 — 브랜치 생성 & 구현 (Claude 실행)

**브랜치 명명:** `<type>/<짧은-설명>`

`<type>`은 conventional commit 타입 중 적절한 것을 사용한다:
`feat` / `fix` / `docs` / `refactor` / `perf` / `test` / `chore` 등

**Direct-push 리포:** 브랜치 생성 없이 `main`에서 직접 작업

**Standard 리포:** 위 규칙에 따라 브랜치 생성 후 작업

`--phase <id>` 가 지정된 경우, 해당 프로젝트 Phase에 해당하는 작업만 구현한다. 범위를 벗어난 작업은 하지 않는다.

Step 2에서 받은 프롬프트(DOC FIX NEEDED 또는 NEXT TASK)를 실행한다.

---

## Step 5 — Verify (Claude 실행)

`/verify` 커맨드를 실행한다.

---

## Step 6 — Code Review 루프 (Claude 실행)

리뷰 루프 시작 전 `REVIEW_BASE`를 계산한다. Direct-push 리포에서는 `REVIEW_BASE`가
반드시 `main`이어야 한다. 모든 `/codex:*review` 호출에는 `--base "$REVIEW_BASE"`를
붙인다.

### 리뷰 스킬 선택 기준

**Direct-push 리포:** 회차와 무관하게 항상 `/codex:adversarial-review --base main` 을 사용한다.

**Standard 리포:** 구현 작업 규모를 판단한다.

깊은 리뷰 필요 기준: 변경된 파일 5개 초과, 또는 새 기능/아키텍처 변경, 또는 보안·인증 관련 코드 포함

| 회차 | 깊은 리뷰 필요 시 | 일반 시 |
|------|-----------------|---------|
| 1회차 | `/codex:adversarial-review --base "$REVIEW_BASE"` | `/codex:review --base "$REVIEW_BASE"` |
| 2회차 | `/codex:adversarial-review --base "$REVIEW_BASE"` | `/codex:review --base "$REVIEW_BASE"` |
| 3회차~ | `/codex:review --base "$REVIEW_BASE"` | `/codex:review --base "$REVIEW_BASE"` |

### 루프 절차

1. 위 기준에 따라 현재 회차에 맞는 리뷰 스킬을 **foreground**로 즉시 실행한다. bg/fg를 사용자에게 묻지 않는다.
2. 리뷰 결과가 **pass**이면 Step 7로 진행한다
3. 리뷰 결과에 지적 사항이 있으면 수정 후, 다음 회차 리뷰 스킬로 즉시 반복한다
4. **5회 초과 시:** pass 여부와 무관하게 루프를 종료한다. 미해결 지적 사항은 `gh issue create`로 GitHub issue를 생성하고 (제목: `[review] <한 줄 요약>`, 본문: 미해결 항목 목록) Step 7로 진행한다. 멈추지 않는다.

---

## Step 7 — 로컬 테스트 & CI 검증 (Claude 실행)

프로젝트의 테스트 스위트와 정적 분석을 로컬에서 실행한다.

**테스트 명령 자동 감지 순서:**
- `Makefile` → `make test` 또는 `make ci`
- `package.json` → `npm test` / `yarn test` / `bun test`
- `pyproject.toml` / `pytest.ini` → `pytest`
- `go.mod` → `go test ./...`
- `Gemfile` → `bundle exec rspec` / `bundle exec rails test`
- 위 어느 것도 없으면 사용자에게 확인 후 진행

**검사 항목 (해당하는 것만):**
- Unit test / integration test 전체 실행
- 타입 체커 (tsc, mypy, pyright 등)
- 린터 (eslint, rubocop, golangci-lint 등)
- 빌드 검증 (`npm run build`, `go build` 등)

**결과 분기:**
- 전부 통과 → Step 8로 진행
- 실패 → 원인 파악 후 수정, Step 7 재실행

---

## Step 8 — Ship (Claude 실행)

**Direct-push 리포:**

```bash
git push origin main
```

**Standard 리포:**

1. `gh pr create --base "$REVIEW_BASE" --draft=false` 로 PR 생성 (제목/본문 적절히 작성)
2. `/codex-loop` 커맨드를 실행한다
3. codex-loop 완료 후 해당 PR을 `$REVIEW_BASE` 브랜치에 **squash merge**한다

---

## 루프 재시작

Step 8 완료 후 루프 모드에 따라 동작한다:

| 모드 | 종료 조건 |
|------|-----------|
| `--loop` | Step 3에서 ALL CLEAR 반환 시 |
| `--loop N` | N회 완료 시 (ALL CLEAR 무관) |

**각 사이클 종료 시:** `/compact` 전에 반드시 "사이클 브리핑 로그" 절차를 수행한다.
즉, 이번 사이클 브리핑을 출력하고 `$DEV_CYCLE_BRIEF_LOG`에 append한 뒤 `/compact`를
실행해 컨텍스트를 요약·압축한다. `/compact`에 넘기는 요약에는
`DEV_CYCLE_RUN_ID`, `DEV_CYCLE_BRIEF_LOG` 경로, 직전 Cycle 브리핑을 포함한다. 이후 Step 1부터 재시작한다.
컨텍스트가 압축되더라도 `$DEV_CYCLE_BRIEF_LOG`, git log, 문서에서 이전 사이클 작업
내역을 재확인할 수 있다.

종료 시 총 실행 횟수, 마지막 상태, `$DEV_CYCLE_BRIEF_LOG` 기반 종합 브리핑을
사용자에게 보고한다.
