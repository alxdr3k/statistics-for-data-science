---
name: sitrep
description: 현재 프로젝트 상태, 개발 로드맵, 현재 위치를 문서에서 읽어 요약 보고
---

# Sitrep — Situation Report

프로젝트의 현재 상황을 파악하여 아래 형식으로 보고한다.

## 수집 절차

다음을 순서대로 읽어라:

1. `git log --oneline -20` — 최근 커밋 흐름
2. `git status -sb` — 현재 워킹트리 상태
3. `git branch --show-current` — 현재 브랜치
4. `AGENTS.md`, README 등 repo-local guidance 중 존재하는 파일
5. `docs/ARCHITECTURE.md`, `docs/CODE_MAP.md`, `docs/TESTING.md` 등 존재하고 필요한 핵심 문서
6. 로드맵이 별도 파일에 있으면 해당 파일 (ROADMAP.md, docs/ROADMAP.md 등)

긴 P0 설계 문서 (PRD, HLD 등), archive, generated file은 기본으로 열지 않는다.
현재 상태 판단에 꼭 필요할 때만 이유를 밝히고 필요한 부분만 읽는다.

## 보고 형식

아래 섹션을 순서대로 출력한다. 정보가 없는 섹션은 "확인 불가"로 표시한다.

---

### 📍 현재 위치
- 브랜치: `<branch>`
- 마지막 커밋: `<sha> <message>`
- 워킹트리: clean / 변경 파일 N개

### 🗺 로드맵
문서에서 파악한 전체 개발 로드맵을 단계별로 나열한다.
완료된 단계는 `✅`, 진행 중은 `🔄`, 미착수는 `⬜`로 표시한다.

### 📌 현재 단계
로드맵 기준으로 지금 어느 단계에 있는지 한 줄로 명시한다.
(예: "Phase 2/5 — 인증 모듈 구현 중")

### ✅ 최근 완료
git log와 문서를 기반으로 최근에 완료된 작업 목록 (최대 5개).

### 🔜 다음 작업
문서와 TODO, 미완성 구현에서 파악한 다음 우선순위 작업 (최대 3개).

### ⚠️ 이슈 / 주의사항
문서-코드 불일치, 미해결 TODO, 알려진 문제 등. 없으면 생략.
