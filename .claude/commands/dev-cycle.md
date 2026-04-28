---
description: 전체 개발 사이클: pull → doc 정합성 감사(codex) → 구현 → verify → review → ship
argument-hint: [--loop [N]] [--phase <id>]
---

# Dev Cycle

## 플래그

- `--loop` : 한 사이클 완료 후 Phase 1부터 자동 재시작. Phase 3에서 **ALL CLEAR** 반환 시 종료.
- `--loop N` : 정확히 N회 반복 후 종료 (ALL CLEAR 무관).
- `--phase <id>` : 구현 대상을 프로젝트 로드맵의 특정 Phase로 한정한다. `<id>`는 프로젝트 문서에 있는 식별자를 그대로 전달한다 (예: `"Judgment System 1B"`, `TASK-011`, `"orchestrator Phase 4"`). 파싱하거나 변환하지 않는다. Phase 2(doc 감사)와 Phase 4(구현) 양쪽에서 이 id를 참고해 범위를 좁힌다.

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

Phase 시작 전 `git remote get-url origin` 으로 리포 이름을 확인하고, 이후 모든 분기 판단에 사용한다.

---

## Phase 1 — Sync (Claude 실행)

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

## Phase 2 — 문서 정합성 감사 (codex:rescue 위임)

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
---

## Phase 3 — 결과 판단 (Claude 실행)

- **ALL CLEAR:** 사용자에게 현재 상태를 보고하고 중단한다.
- **DOC FIX NEEDED:** Phase 4로 진행, 작업 유형은 `docs`
- **NEXT TASK:** Phase 4로 진행, 작업 유형은 codex가 반환한 내용에 따라 결정
---

## Phase 4 — 브랜치 생성 & 구현 (Claude 실행)

**브랜치 명명:** `<type>/<짧은-설명>`

`<type>`은 conventional commit 타입 중 적절한 것을 사용한다:
`feat` / `fix` / `docs` / `refactor` / `perf` / `test` / `chore` 등

**Direct-push 리포:** 브랜치 생성 없이 `main`에서 직접 작업

**Standard 리포:** 위 규칙에 따라 브랜치 생성 후 작업

`--phase <id>` 가 지정된 경우, 해당 프로젝트 Phase에 해당하는 작업만 구현한다. 범위를 벗어난 작업은 하지 않는다.

Phase 2에서 받은 프롬프트(DOC FIX NEEDED 또는 NEXT TASK)를 실행한다.
---

## Phase 5 — Verify (Claude 실행)

`/verify` 커맨드를 실행한다.
---

## Phase 6 — Code Review 루프 (Claude 실행)

### 리뷰 스킬 선택 기준

**Direct-push 리포:** 회차와 무관하게 항상 `/codex:adversarial-review` 를 사용한다.

**Standard 리포:** 구현 작업 규모를 판단한다.

깊은 리뷰 필요 기준: 변경된 파일 5개 초과, 또는 새 기능/아키텍처 변경, 또는 보안·인증 관련 코드 포함

| 회차 | 깊은 리뷰 필요 시 | 일반 시 |
|------|-----------------|---------|
| 1회차 | `/codex:adversarial-review` | `/codex:review` |
| 2회차 | `/codex:adversarial-review` | `/codex:review` |
| 3회차~ | `/codex:review` | `/codex:review` |

### 루프 절차

1. 위 기준에 따라 현재 회차에 맞는 리뷰 스킬을 **foreground**로 실행한다 (`run_in_background: false`, 완료될 때까지 대기)
2. 리뷰 결과가 **pass**이면 Phase 7로 진행한다
3. 리뷰 결과에 지적 사항이 있으면 수정 후, 다음 회차 리뷰 스킬로 즉시 반복한다
4. pass가 나올 때까지 반복한다
---

## Phase 7 — Ship (Claude 실행)

**Direct-push 리포:**

```bash
git push origin main
```

**Standard 리포:**

1. `gh pr create --base dev --draft=false` 로 PR 생성 (제목/본문 적절히 작성)
2. `/codex-loop` 커맨드를 실행한다
3. codex-loop 완료 후 해당 PR을 `dev` 브랜치에 **squash merge**한다

---

## 루프 재시작

Phase 7 완료 후 루프 모드에 따라 동작한다:

| 모드 | 종료 조건 |
|------|-----------|
| `--loop` | Phase 3에서 ALL CLEAR 반환 시 |
| `--loop N` | N회 완료 시 (ALL CLEAR 무관) |

종료 시 총 실행 횟수와 마지막 상태를 사용자에게 보고한다.
