---
name: codex-loop
description: 현재 PR에 대해 codex 리뷰 wait + feedback fix + land까지 한 번에 처리하는 shim. 내부적으로 review-loop과 land-pr.sh를 위임 호출한다.
---
<!-- my-skill:generated
skill: codex-loop
base-sha256: 9b1ae7cc9dac4f1653c6654127d7f7c1a98fec26b9b07307568f868675a18f96
overlay-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
output-sha256: 9b1ae7cc9dac4f1653c6654127d7f7c1a98fec26b9b07307568f868675a18f96
do-not-edit: edit .codex/skill-overrides/codex-loop.md instead
-->

현재 작업 중인 PR에 대해 codex 리뷰를 기다리고, feedback 코멘트를 수정·push하고, 통과 신호를 받으면 정책에 맞게 PR을 land한다. codex-loop은 자체 review/land logic을 보유하지 않으며, 다음 두 building block을 위임 호출하는 **thin shim**이다:

1. `/review-loop` — codex review wait + feedback handling + pass 신호 인계 (worker도 호출 가능; merge 단계 없음).
2. `scripts/land-pr.sh --expected-head-sha <SHA>` — review-loop의 pass payload `review_loop_pass_signal.head_sha`를 그대로 받아 land. PR live head가 reviewed SHA와 다르면 `expected_head_mismatch` envelope으로 거부 (codex가 보지 않은 commit이 추가됐다는 신호).

이 SHA pin은 review wait와 land 사이의 push race를 닫는다. raw `gh pr merge`를 직접 호출하지 않는다.

사용자에게 보이는 보고, feedback 정리, 질문은 한국어로 작성한다. 코드, 명령, 파일명, 원문 인용은 원문 언어를 유지한다.

## Flags

- `--opus-review`: `/review-loop --opus-review`로 그대로 전달.

## 책임 경계

- codex-loop은 orchestrator-only다. worker context에서 호출하면 land 단계가 `LAND_FORBIDDEN=1`에 의해 거부된다 (PA-1.x worker guard + PA-2.2 land 거부의 3차 enforcement). worker는 `/review-loop`을 직접 호출해 pass 신호만 인계하고 후속 land는 orchestrator가 결정한다.
- codex-loop이 직접 실행하는 mutation은 (1) `scripts/land-pr.sh` 호출 (orchestrator land path), (2) `mcp__github__unsubscribe_pr_activity` (review-loop의 Path A subscription 정리)뿐이다. 모든 review wait/feedback/push는 review-loop이 담당한다.

## 절차

### 1. review-loop 위임

`/review-loop` 또는 동등한 호출 (Claude Code: `/review-loop`, Codex CLI: `$review-loop`, plain-language skill request)을 실행한다. flag와 env var는 그대로 review-loop으로 전달된다.

review-loop은 codex가 PR을 review하고 pass 신호를 emit할 때까지 (또는 terminal stop에 도달할 때까지) 동작한다. 종료 시 다음 둘 중 하나를 emit한다:

- **Pass payload** (`kind:"review_loop_pass_signal"`): `{schema_version, kind, repo, pr_number, head_sha, baseline, signal_source, path}`. `head_sha`가 codex가 실제로 review한 commit. → 2단계로 진행.
- **Terminal payload** (`kind:"review_loop_terminal_signal"`): `{result, exit_code, repo, pr_number, current_head_sha, baseline, path, retryable, failure_reason}`. timeout/PR 미감지/auth 실패/eyes ack 실패 등. → 3단계 terminal 처리.

### 2. Pass 신호 → SHA-pinned land

review-loop에서 pass payload를 받으면 다음 셋을 순서대로 확인하고 land를 실행한다.

1. PR이 draft가 아닌가? (`gh pr view <PR_NUMBER> --json isDraft -q .isDraft`)
2. required checks가 모두 SUCCESS인가? 미완료/실패 항목이 있으면 `gh pr checks <PR_NUMBER> --watch`로 완료를 기다린다.
3. baseline 이후 새 actionable comment/review가 없는가? (review-loop의 pass 신호 시점에는 0이어야 정상; 만약 그 사이 새로 도착했으면 review-loop을 한 번 더 재실행)

확인이 모두 통과하면 `scripts/land-pr.sh`를 호출한다. caller cwd는 PR head branch를 잡고 있는 worktree일 수 있으므로 (dev-cycle Step 9의 일반 흐름), land-pr 호출은 두 단계로 나뉜다 — review cwd에서 식별자를 캡처한 다음 git context가 없는 safe cwd로 이동해서 호출.

#### Why cwd split

caller cwd가 PR head worktree와 같으면 land-pr의 `cwd_is_head_worktree` 가드 (PR #60)가 `rc=6`으로 거부한다. 이 가드는 `gh pr merge --delete-branch`가 그 worktree의 HEAD를 main으로 강제 이동시키다가 canonical main이 다른 worktree에 잡혀 있으면 `fatal: '<base>' is already used by worktree`로 깨지는 패턴을 방어한다. codex-loop은 그 가드를 우회하지 않고 cwd를 safe non-head 위치로 옮긴 다음 호출한다. 모든 gh 호출은 `LAND_PR_REPO` env로 repo를 명시하므로 cwd가 비-git이어도 정상 동작한다.

#### 절차

```bash
# 2.1 review cwd에서 캡처 — 아직 PR head worktree일 수 있다.
#  - land-pr.sh 절대 경로 (deployed: .agents/scripts/, source: scripts/, user fallback: ~/.agents/scripts/)
#  - repo nwo + PR_NUMBER: review-loop pass payload에서 그대로 인계. local
#    `gh repo view`는 사용하지 않는다 — cross-repo PR이나 CODEX_REPO/URL-style
#    호출에서 caller checkout과 PR repo가 다를 수 있고, 그 경우 local origin을
#    `LAND_PR_REPO`로 넘기면 land-pr이 잘못된 repo에서 PR_NUMBER를 조회/merge하거나
#    pr_view_failed로 실패한다. pass payload의 `repo`/`pr_number`가 review-loop이
#    실제로 review한 PR의 source of truth.
LAND_HELPER=""
for candidate in scripts/land-pr.sh .agents/scripts/land-pr.sh "$HOME/.agents/scripts/land-pr.sh"; do
  if [ -x "$candidate" ]; then
    LAND_HELPER="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    break
  fi
done
[ -n "$LAND_HELPER" ] || { echo "land-pr.sh 헬퍼를 찾지 못함" >&2; exit 1; }
# review-loop pass payload의 repo / pr_number 필드 그대로 사용 (REVIEW_LOOP_HEAD_SHA와 동일한 출처).
LAND_PR_REPO_VALUE="$REVIEW_LOOP_PASS_REPO"
PR_NUMBER_VALUE="$REVIEW_LOOP_PASS_PR_NUMBER"

# 2.2 safe non-head cwd에서 land 호출. 서브셸로 cd를 격리해 caller cwd를 보존한다.
(
  cd /tmp
  LAND_PR_REPO="$LAND_PR_REPO_VALUE" bash "$LAND_HELPER" \
    --expected-head-sha "$REVIEW_LOOP_HEAD_SHA" \
    "$PR_NUMBER_VALUE"
)
```

`REVIEW_LOOP_PASS_REPO` / `REVIEW_LOOP_PASS_PR_NUMBER` / `REVIEW_LOOP_HEAD_SHA`는 모두 review-loop pass payload (`kind:"review_loop_pass_signal"`)의 `repo` / `pr_number` / `head_sha` 필드와 1:1 대응한다. 별도 변수명을 쓰는 이유는 (a) bash snippet에서 어디서 왔는지 명확히 하기 위함, (b) caller가 직접 변수에 담을지 jq로 직접 추출할지 선택할 수 있게 하기 위함이다.

caller cwd는 서브셸로 격리되므로 land-pr이 끝난 뒤에도 그대로 유지된다. dev-cycle 같은 후속 cleanup (linked task worktree 제거, base branch sync 등) 은 caller가 자기 cwd 기준으로 이어서 처리한다.

#### land-pr 동작

- `REVIEW_LOOP_HEAD_SHA`는 review-loop pass payload의 `head_sha` 그대로.
- land-pr.sh는 `LAND_PR_METHOD` env (default `squash`) 또는 `--method squash|merge|rebase` flag를 받아 그에 맞는 merge를 호출한다. repo-local guidance가 squash를 요구하지 않으면 caller가 명시한다.
- live head가 expected와 다르면 land-pr이 `expected_head_mismatch` (rc=6)로 거부한다. 이 경우 baseline이 갱신된 새 commit이 있으므로 review-loop을 처음부터 다시 호출해야 한다 (1단계로).
- branch protection / merge queue / required check pending으로 즉시 land가 막히면 `--auto`를 추가하거나 `LAND_PR_ADMIN_FALLBACK=1`로 admin bypass를 켤 수 있다. 그래도 막히면 차단 사유 + PR URL을 사용자에게 보고한다.

land-pr.sh가 rc=0으로 성공하면 envelope의 `result`로 분기:
- `result: merged` → main에 즉시 land. Path A subscription이 있었다면 `mcp__github__unsubscribe_pr_activity` 호출.
- `result: queued` (merge queue / auto-merge enabled) → caller에게 enqueued 상태 보고. 후속 모니터링은 caller 책임.

Path A에서는 land 성공 또는 unrecoverable land 실패 직후 `mcp__github__unsubscribe_pr_activity { owner, repo, pullNumber }`로 구독을 해제한다.

### 3. Terminal 신호 처리

review-loop이 terminal payload를 emit하면 codex-loop은 추가 land 시도를 하지 않고 caller에게 상태를 인계한다.

- `result: timeout` / `api_error` / `review_request_unacknowledged` (retryable=true): 사용자에게 사유 보고. 필요시 caller가 재호출.
- `result: pr_not_detected` / `user_stopped` / `externally_closed` (retryable=false): 사용자에게 사유 보고 후 종료.

terminal payload는 codex-loop이 그대로 caller-visible로 출력한다 (재포장 없음).

## 환경변수

review-loop과 land-pr이 사용하는 env var를 그대로 따른다. codex-loop 자체가 추가하는 env var는 없다.

- review-loop 측: `CODEX_PASS_ACTOR`, `CODEX_PASS_REACTION`, `CODEX_PASS_COMMENT_PATTERN`, `CODEX_REVIEW_REQUEST_BODY`, `CODEX_SILENT_PROBE_DELAY` (Path A), `CODEX_POLL_INTERVAL`, `CODEX_POLL_TIMEOUT`, `CODEX_INITIAL_EMPTY_DELAY`, `CODEX_BASELINE`, `CODEX_REPO`, `CODEX_REVIEW_OUTPUT` (Path B). 자세한 의미는 `commands/review-loop.md` 환경변수 표 참조.
- land-pr 측: `LAND_FORBIDDEN`, `LAND_PR_METHOD`, `LAND_PR_PRUNE_HEAD_WORKTREE`, `LAND_PR_ADMIN_FALLBACK`, `LAND_PR_REPO`, `LAND_PR_OUTPUT`, `LAND_PR_EXPECTED_HEAD_SHA`. 자세한 의미는 `scripts/land-pr.sh` header 참조.

`LAND_PR_EXPECTED_HEAD_SHA`는 codex-loop이 review-loop pass payload의 `head_sha`로 자동 설정한다. caller가 별도로 export할 필요 없다.

## 인자

- 인자 없음: 현재 branch의 PR 자동 감지.
- PR 번호 또는 URL: 첫 positional 인자로 전달. 그대로 review-loop / land-pr에 propagate.

`$ codex-loop` 또는 `/codex-loop`만으로 충분. 명시적 PR 번호를 받으면 `/codex-loop 47` 형식.
