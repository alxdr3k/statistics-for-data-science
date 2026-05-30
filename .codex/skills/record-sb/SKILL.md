---
name: record-sb
description: "Second Brain에 기록: /Users/yngn/ws/second-brain에 노트를 만들고 템플릿/frontmatter/index 검증을 거쳐 worktree에서 main으로 로컬 merge한다."
---
<!-- my-skill:generated
skill: record-sb
base-sha256: ac8c6770e23ca0a0fa1ed38dc755448f08ff166e53cb478d0f9740a2897c2ab6
overlay-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
output-sha256: ac8c6770e23ca0a0fa1ed38dc755448f08ff166e53cb478d0f9740a2897c2ab6
do-not-edit: edit .codex/skill-overrides/record-sb.md instead
-->

# Second Brain에 기록

Second Brain (`/Users/yngn/ws/second-brain/`)에 노트를 기록한다.
다른 세션이 main을 사용 중일 수 있으므로 **워크트리에서 작업 후 로컬 merge**한다.

## 1. 노트 유형 → 폴더 + 템플릿

| 내용 | 폴더 | 템플릿 |
|---|---|---|
| cross-project / personal 결정 | `03. Decisions/` | `DecisionNoteTemplate.md` |
| 결론 없는 사유·질문 흐름 | `01. Explorations/` | `ExplorationTemplate.md` |
| 다회차 AI 상담·리서치 세션 | `02. Ideation/` | `IdeationSessionTemplate.md` |
| 재사용 가능한 lesson·원칙 | `04. Slip Box/` | `LessonTemplate.md` |
| 참고 자료·레퍼런스 | `07. Resources/` | `ResourceTemplate.md` |
| 분류 불명 | `00. Inbox/` | `NoteTemplate.md` |

**절대 여기에 쓰지 않는다**: project-specific PRD/HLD/ADR (project repo에 존재).
재사용 가능한 lesson만 project repo에서 승격한다.

## 2. 절차

`/Users/yngn/ws/second-brain` 아래 임시 worktree에서 작업하고, 완료 후 main에 로컬 merge한 뒤 worktree를 정리한다.

1. **Hook bootstrap (idempotent)**:
   - 기록 작업 시작 시 먼저 canonical checkout에서 실행:
     ```bash
     cd /Users/yngn/ws/second-brain
     [ -x scripts/install-hooks.sh ] && bash scripts/install-hooks.sh
     ```
   - 목적: `core.hooksPath=.githooks`를 이 checkout/common git config에 보장해서
     pre-commit hook이 `build_index.ts` 후 `_System/Indexes/`를 자동 re-stage하게 한다.
   - 이미 설치돼 있으면 동일 설정을 다시 쓰는 no-op으로 취급한다.
   - 보안상 Git clone/worktree가 hook을 자동 활성화하지 않으므로 `/record-sb` entrypoint가
     이 bootstrap을 책임진다.
2. `_System/Templates/<Template>.md` 기반으로 새 파일 생성
3. frontmatter 필수 필드 채우기:
   - `id`: `type-kebab-case-title` (unique)
   - `type`, `title`, `status`
   - `created_at`, `updated_at`: ISO 8601 (`2026-05-03T00:00:00+09:00`)
   - `ai_include: true`
   - `provenance`: `user_confirmed` (직접 기술) / `assistant_generated` (AI가 작성)
4. 본문 작성
5. 검증 + generated index sync:
   ```bash
   node --experimental-strip-types --no-warnings scripts/validate_frontmatter.ts
   node --experimental-strip-types --no-warnings scripts/build_index.ts
   git add <변경한 노트 파일들> _System/Indexes/
   node --experimental-strip-types --no-warnings scripts/build_index.ts --check
   ```
   pre-commit hook도 같은 일을 한 번 더 수행하지만, agent는 hook 설치 여부에 의존하지 않고
   커밋 전에 index를 명시적으로 stage한다.
6. 커밋 → main merge → push → worktree 정리

## 3. 예시 id 형식

- `dec-actwyn-auth-strategy-2026`
- `lesson-optimistic-lock-pattern`
- `exp-pkm-tool-comparison`
