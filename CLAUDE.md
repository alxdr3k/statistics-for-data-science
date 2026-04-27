# Project: statistics-for-data-science

## Git Branch Policy (이 프로젝트 한정)

글로벌 정책의 `dev` 브랜치 단계를 생략하고 **`feat/* → main` 직행** 방식을 사용한다.

### 브랜치 워크플로우

```
main (protected) ← PR only
  ↑
feat/* or fix/* or claude/*
```

### PR 머지 전략

```
feat/* ──squash──▶ main ──squash──▶ Release PR
```

| PR 유형 | 머지 방식 | 이유 |
|--------|----------|------|
| feat/* → main | Squash | WIP 커밋 정리, 깔끔한 히스토리 |
| Release PR | Squash | 이미 정리된 내용, `chore: release x.y.z` 하나로 충분 |

### 작업 시작 전 체크리스트

1. `git branch` — 현재 브랜치 확인
2. main이면 새 브랜치 생성: `git checkout -b feat/<name>`

### 커밋 규칙

- Conventional Commits 형식 사용
- main에 직접 push 금지
