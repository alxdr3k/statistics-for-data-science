CI E2E 테스트 실패를 Codex(디버깅·수정) + Claude(로컬 테스트) 루프로 고쳐줘.

## 역할 분담

- **Codex** — CI 로그 분석 + 코드 수정 + commit (PR은 열지 않음)
- **Claude(나)** — 로컬에서 Playwright 실행 → 실패 시 로그를 Codex에게 피드백 → 반복
- 테스트가 통과하면 push → PR 생성 → `/codex-loop` 실행

## 루프 절차

### 1단계: CI 실패 로그 수집

```bash
# 최신 실패 run ID 확인
gh run list --repo <owner>/<repo> --limit 5 --json databaseId,conclusion,headBranch,name

# 실패 로그 추출
gh run view <run-id> --repo <owner>/<repo> --log-failed 2>&1 | tail -150
```

### 2단계: Codex에게 수정 위임

`/codex:rescue` 로 위임. 프롬프트에 반드시 포함:
- 브랜치명 및 워크트리 경로 (있으면)
- CI 실패 로그 전문
- 앱 소스(`app/views/`, `app/controllers/` 등)에서 확인한 실제 텍스트·셀렉터
- "수정 후 commit만, PR은 열지 마" 명시

### 3단계: 로컬 테스트 (Claude 직접 실행)

Codex commit 확인 후 순서대로:

```bash
# 1. 에셋 빌드 (CSS 없으면 Rails 서버 기동 불가)
npm run build:css
npm run build

# 2. 테스트 DB 준비
RAILS_ENV=test bin/rails db:test:prepare
RAILS_ENV=test bin/rails db:seed

# 3. Playwright 전체 실행
npx playwright test --reporter=line
```

### 4단계: 결과 분기

| 결과 | 다음 행동 |
|------|-----------|
| 전부 pass | push → PR 생성 → `/codex-loop` |
| 실패 있음 | 실패 로그 정리 → 2단계로 돌아가 Codex에게 피드백 |

## Codex 위임 시 주의

- Codex 샌드박스는 네트워크·TCP 바인딩이 차단되어 로컬 서버 기동 불가 → 테스트 실행은 Claude가 담당
- 워크트리가 이미 있으면 경로를 명시해줘야 Codex가 올바른 위치에서 작업함
- 수정 범위를 좁게 줄수록 좋음: 실패 테스트 파일·라인·기대값을 정확히 지정

## 루프 종료 조건

`npx playwright test` 가 **0 failed** 로 끝나면 종료.
