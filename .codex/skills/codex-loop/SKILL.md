---
name: codex-loop
description: 현재 PR의 codex 리뷰를 기다리고 코멘트 수정 후 push, 통과 reaction까지 반복
---

현재 작업 중인 PR에 대해 codex 리뷰를 기다리고, 코멘트가 달리면 수정 후 push. 통과 reaction까지 반복.

## ⚠️ 핵심 원칙: foreground sync로 한 번만 호출

**스크립트는 polling sleep 동안 idle**이라 그 시간 동안 토큰을 전혀 쓰지 않음. 한 번 호출하고 종료까지 기다리면 한 번의 결과만 받게 됨. **이게 이 스크립트의 존재 이유다.**

```bash
bash .claude/scripts/wait-codex-review.sh
```

다음 패턴은 **금지** — 매 cycle마다 stdout/상태를 확인하면 토큰을 그대로 다 쓰게 되어 스크립트의 의미가 사라짐:
- ❌ `bash ... &` (background로 띄우고 polling)
- ❌ `run_in_background: true` 후 매 cycle output check
- ❌ Monitor 도구로 stream watch
- ❌ 매 sleep 사이에 상태 polling

## 절차

1. PR 만든 직후, 또는 push 직후, 위 명령을 **foreground로 한 번** 실행한다.
2. 종료될 때까지 기다린다 (스크립트가 알아서 polling).
3. 종료 코드에 따라 처리:

   | exit | 의미 | 다음 행동 |
   |------|------|-----------|
   | 0 | codex가 👍 reaction 추가 — 리뷰 통과 | PR 머지 |
   | 1 | 새 코멘트/리뷰가 stdout에 출력됨 | 분석 → 코드 수정 → commit → push → 1번부터 재시도 |
   | 2 | 타임아웃 (default 10분) | 사용자에게 보고 |
   | 3 | PR 감지 실패 | 첫 인자로 PR 번호 또는 URL 전달 |
   | 4 | 영구 API 에러 (401/403/404) | 사용자에게 인증·권한 점검 요청 |

4. exit 1 후 push가 끝나면 다시 1번부터.

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CODEX_POLL_INTERVAL` | 20 | 폴링 간격 (초) |
| `CODEX_POLL_TIMEOUT` | 600 | 전체 대기 한도 (초) |
| `CODEX_BASELINE` | (auto) | 이 ISO timestamp 이전 활동 무시 |
| `CODEX_REPO` | (auto) | fork 워크플로 시 base repo 명시 (`owner/repo`) |
| `CODEX_PASS_ACTOR` | `chatgpt-codex-connector[bot]` | 통과 reaction을 다는 봇 login |
| `CODEX_PASS_REACTION` | `+1` | 통과를 의미하는 reaction content |

## 인자 형식

- 인자 없음: 현재 브랜치의 PR 자동 감지
- PR 번호: `bash ... 42`
- PR URL: `bash ... https://github.com/owner/repo/pull/42`

## 작업 지시 시 주의

코멘트가 모호하거나 우선순위 판단이 필요하면 코드 수정 전 사용자에게 확인. 합리적이지 않은 트집(이미 처리된 이슈, 비현실적 엣지케이스)은 무시하고 그대로 머지하는 것도 한 옵션.
