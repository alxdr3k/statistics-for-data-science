---
name: codex-loop
description: 현재 PR의 codex 리뷰를 기다리고 코멘트 수정 후 push, 통과 reaction을 받으면 정책에 맞춰 merge
---

현재 작업 중인 PR에 대해 codex 리뷰를 기다리고, 코멘트가 달리면 수정 후 push. 통과 reaction까지 반복한 뒤 PR을 정책에 맞춰 merge한다.

## 핵심 원칙: foreground wait

긴 대기는 한 번의 foreground 명령으로 처리한다. background polling을 띄운 뒤
짧은 간격으로 상태를 다시 확인하지 않는다.

가능하면 GitHub app으로 PR 댓글/리뷰를 읽고, GitHub Actions 상태나 현재 브랜치
PR 탐지는 `gh` CLI를 사용한다.

## 준비

1. 현재 브랜치의 PR을 확인한다.

   ```bash
   gh pr view --json number,url,baseRefName,headRefName,mergeStateStatus
   ```

2. PR을 찾지 못하면 사용자에게 PR 번호 또는 URL을 요청한다.
3. push 직후라면 그 시점을 baseline으로 삼는다. 새 feedback은 baseline 이후
   생성된 issue comment, review submission, inline review comment, pass reaction만
   대상으로 한다.

## 대기

1. PR check는 foreground watch로 한 번 기다린다.

   ```bash
   gh pr checks <PR_NUMBER> --watch
   ```

2. check 완료 후 GitHub app 또는 `gh`로 PR comments/reviews/reactions를 읽는다.
3. 결과에 따라 분기한다.

| 상태 | 다음 행동 |
| ---- | --------- |
| pass reaction이 있고 check가 통과 | PR merge |
| 새 actionable comment/review가 있음 | `apply-review` 절차로 수정 → commit → push → 다시 대기 |
| check 실패 | 실패 로그 확인 → 수정 → commit → push → 다시 대기 |
| PR 감지 실패 | PR 번호 또는 URL 요청 |
| 인증/권한 오류 | 사용자에게 `gh auth status` / 권한 점검 요청 |

## Feedback 처리

- 코멘트가 모호하거나 우선순위 판단이 필요하면 코드 수정 전 사용자에게 확인한다.
- 이미 처리된 이슈, 재현 불가 항목, 범위 밖 요구는 근거를 남기고 제외할 수 있다.
- 수정은 최소 diff로 하고, 관련 테스트와 repo가 정의한 검증 명령을 다시 실행한다.
- push 후 baseline을 새 push 시점으로 갱신하고 루프를 반복한다.

## Merge 처리

pass reaction이 있고 checks가 통과하면 사용자의 추가 확인을 기다리지 말고 PR을 merge한다. 단, merge 전 다음을 확인한다.

1. PR이 draft가 아니어야 한다.
2. required checks가 통과해야 한다.
3. 새 actionable comment/review가 없어야 한다.
4. repo-local guidance 또는 GitHub repo 설정이 정한 merge 방식을 따른다.

권장 확인:

```bash
gh pr view --json number,url,isDraft,baseRefName,headRefName,mergeStateStatus,reviewDecision
gh pr checks <PR_NUMBER> --watch
gh api "repos/<owner>/<repo>" --jq '{allow_merge_commit, allow_squash_merge, allow_rebase_merge}'
```

merge 방식 선택:

- repo-local guidance가 `squash merge`를 요구하면 `gh pr merge <PR_NUMBER> --squash --delete-branch`.
- repo가 merge commit만 허용하면 `gh pr merge <PR_NUMBER> --merge --delete-branch`.
- repo가 rebase merge만 허용하면 `gh pr merge <PR_NUMBER> --rebase --delete-branch`.
- 명시 정책이 없고 여러 방식이 허용되면 기존 repo 관례를 따른다. 관례가 불명확하면 `--squash`를 기본값으로 사용한다.

branch protection, merge queue, required check pending 때문에 즉시 merge가 막히면 같은 방식에 `--auto`를 붙여 auto-merge를 걸 수 있다. 그래도 막히면 차단 사유와 PR URL을 사용자에게 보고한다.

## 완료

PR URL, merge 방식, check 결과, 처리한 feedback, 남은 리스크를 보고한다.
