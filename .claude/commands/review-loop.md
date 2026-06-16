---
name: review-loop
description: 현재 PR의 codex 리뷰를 기다리고 코멘트 수정 후 push, 통과 reaction을 받으면 caller에게 pass 신호를 인계한다 (merge는 호출자가 결정)
---

현재 작업 중인 PR에 대해 codex 리뷰를 기다리고, 코멘트가 달리면 수정 후 push. 통과 reaction까지 반복한 뒤 **pass 신호를 caller에게 인계한다.** 이 skill은 PR을 merge하지 않는다. merge 정책 적용과 PR land는 호출자(`/codex-loop`, `/run-team` orchestrator 등)가 별도로 수행한다.

사용자에게 보이는 보고, feedback 정리, 질문은 한국어로 작성한다. 코드, 명령, 파일명, 원문 인용은 원문 언어를 유지한다.

## 책임 경계

review-loop이 실행하는 mutation은 아래 세 종류로 제한한다:

1. 자기 작업 branch에 commit/push.
2. 자기 PR에 review-request issue comment 게시 (`$CODEX_REVIEW_REQUEST_BODY`). Path A 진입과 feedback push 후 재게시 시 baseline당 1회 한정.
3. Path A에서 `mcp__github__subscribe_pr_activity` / `mcp__github__unsubscribe_pr_activity` 호출.

다음은 **명시적으로 제외한다**:

- `gh pr merge` 호출 또는 그에 준하는 merge API
- `scripts/land-pr.sh` 호출 또는 base branch 직접 mutation
- 자기 PR 이외의 PR/이슈에 대한 write
- 자기 branch 외 다른 branch에 대한 push

review-loop은 **worker context에서 호출 가능하다**. 워커가 자기 작업 branch의 PR에 대해 review feedback 처리·push·자기 PR comment까지 수행할 수 있고, land 권한이 없는 상태에서도 안전하다. 따라서 worker 호출 환경에서는 GitHub token이 자기 branch push + 자기 PR comment write를 허용해야 한다 (별도 land/merge 권한은 불필요).

pass 신호 감지 후 review-loop의 종료 동작은 아래 "Pass 신호 인계" 형식의 SHA-pinned payload를 caller에게 전달하는 것이다. 후속 merge/land 분기는 caller가 결정한다.

## Flags

- `--opus-review`: feedback 타당성 검토를 dossier 라우팅과 무관하게 항상 Opus sub-agent로 실행한다.

## 경로 선택

실행 중인 에이전트의 가용 도구 목록에 `mcp__github__subscribe_pr_activity`가 포함되어 있으면 (전형적으로 Claude Code 웹 세션 + GitHub MCP가 연결된 상태) **Path A: 이벤트 구독**을 사용한다. tool이 없으면 (local Claude Code CLI에서 GitHub MCP 미연결, opencode, codex CLI 등) **Path B: 폴링 스크립트**를 사용한다. 환경 이름이 아니라 실제 도구 가용성으로 판단한다.

Path A 실행 중 `subscribe_pr_activity`/`unsubscribe_pr_activity` 호출이나 probe용 `gh api` 호출이 auth/scope/네트워크 등 진행을 막는 오류로 실패하면 즉시 Path B로 fallback한다. transient 오류는 같은 wake-up에서 1회 재시도해도 되지만, 영구 오류는 지체 없이 Path B 스크립트를 foreground로 실행해 polling-based 흐름으로 계속한다.

GitHub은 codex bot의 pass reaction(`+1`)을 webhook으로 전달하지 않는다. 이를 보완하기 위해 Path A·B 모두 두 Pass 신호를 OR로 인식한다: (1) `$CODEX_PASS_ACTOR`의 reaction (REST `/reactions` 조회 필요), (2) `$CODEX_PASS_ACTOR`가 남긴 issue comment/review body가 `$CODEX_PASS_COMMENT_PATTERN`(기본 regex `didn['’]?t find any major issues`, case-insensitive)에 매칭 — 단 review의 state가 `CHANGES_REQUESTED` 또는 `DISMISSED`이면 매칭과 무관하게 actionable feedback으로 유지 (state veto). webhook으로 즉시 도착, reactions API 미가용 환경에서도 잡힌다.

## Model Routing

Claude Code에서 model-routed sub-agent를 사용할 수 있으면 아래 원칙을 따른다. 사용할 수 없거나 handoff 비용이 더 크면 같은 세션에서 수행한다.

- PR 감지, 구독/폴링, pass reaction 확인, review 요청 comment 작성은 Path A에서는 main session, Path B에서는 `wait-codex-review.sh`가 담당한다. 이 작업을 Haiku sub-agent로 대체하지 않는다.
- `--opus-review`가 있으면 새 feedback이 도착할 때마다 dossier 결과와 무관하게 항상 Opus sub-agent로 타당성 검토를 수행한다.
- `--opus-review`가 없을 때: feedback의 타당성 검토는 main session에서 수행한다. `run-helper.sh review-dossier`의 `risk_triggers`는 reviewer 입력 정보로 활용한다.
- feedback 수정은 Sonnet/main execution을 기본으로 하고, 작은 수정에는 별도 worker를 만들지 않는다.
- Haiku 또는 Explore는 PR metadata/comment를 짧게 요약하거나 넓은 read-only 탐색을 압축할 때만 사용한다.
- 같은 PR에서 동일 파일군에 대해 3회 이상 review/fix가 반복될 때만 Opus reviewer resume을 고려한다. 기본은 이전 finding 요약 + incremental diff를 새로 전달한다.

## Path A: 이벤트 구독

### 진입

1. PR을 식별한다. 인자로 받은 PR 번호/URL이 있으면 그대로, 없으면 `gh pr view --json number,url,baseRepository,headRefName,headRepository,headRefOid -q .`로 현재 브랜치 PR을 찾는다. 감지 실패 시 사용자에게 PR 번호/URL을 요청한다.
2. baseline timestamp + **reviewed_head_sha**를 한 번에 캡처한다. baseline 우선순위: ① Events API PushEvent (`repos/<head_repo>/events`의 `refs/heads/<branch>` push 중 최신 `created_at`) → ② PR timeline (`repos/<owner>/<repo>/issues/<pr>/timeline`의 `committed`/`head_ref_force_pushed`) → ③ HEAD 커밋 `committer.date`. 미래 시각은 현재로 클램프한다. 이후 wake-up에서 baseline 이전 활동은 무시한다. **이 baseline을 `last_push_at`으로도 기억해 둔다 — silent-approval probe의 기준 시각이 된다.** 동시에 `gh pr view <PR> --json headRefOid -q .headRefOid`로 현재 head SHA를 `reviewed_head_sha`에 기록한다. 이 SHA가 codex 리뷰가 평가하는 commit이며, Pass 신호 인계 시 payload에 들어가는 head_sha다.
3. `$CODEX_REVIEW_REQUEST_BODY` 본문의 issue comment를 1개 남긴다 — codex의 reaction 상태와 무관하게 baseline당 무조건 1회. codex가 처음부터 리뷰할 게 없으면 PR 본문에 reaction만 달고 끝낼 수 있는데, 그러면 webhook으로 도착하는 pass-comment를 받을 기회가 없다. 기본 본문은 "이슈 없으면 reaction 대신 'Didn't find any major issues' 같은 코멘트로 답해달라"는 명시적 부탁을 포함한다. 이 코멘트는 feedback으로 처리하지 않는다 (작성자가 자신이고 본문이 정확히 `$CODEX_REVIEW_REQUEST_BODY`이면 제외).
4. **구독 인계 (skill takes ownership)**: 진입 시점에 이미 같은 PR에 대한 구독이 존재할 수 있다 (예: harness가 사용자 "watch/babysit/monitor PR" 요청을 받아 자동 구독했거나, 다른 skill이 이전 작업 맥락에서 직접 `subscribe_pr_activity`를 호출했음). 처리 규칙:
   - **이번 `/review-loop` invocation 시작 이후 본 entry 단계에서 직접 `subscribe_pr_activity`를 이미 호출한 흔적이 conversation에 있으면** (예: 이전 wake-up 사이클의 entry) → 그대로 유지하고 추가 호출하지 않는다. 같은 invocation 경계 내에서만 "skill이 소유한" 구독으로 간주한다.
   - **그 외 모든 경우** (이전 invocation의 잔여 구독, harness 자동 구독, 다른 skill/명령에서 한 구독) → 먼저 `mcp__github__unsubscribe_pr_activity { owner, repo, pullNumber }`를 호출해 외부/오래된 구독을 끊고, 이어서 `mcp__github__subscribe_pr_activity { owner, repo, pullNumber }`를 호출해 skill 명의로 다시 구독한다. 이 PR의 구독 lifecycle은 현 invocation의 skill이 단독으로 관리한다.
   - 판단이 모호하면 unsubscribe → subscribe 시퀀스를 실행한다. 둘 다 idempotent이고 비용도 작다.
5. **턴을 종료한다**. background polling이나 sleep loop를 절대 만들지 않는다.

### Wake-up 처리

`<github-webhook-activity>` 메시지가 도착하면 다음 순서로 처리한다.

1. baseline 이후 새 `issue_comment` / `review` / `review_comment`가 있는가? 단 다음 두 종류는 actionable feedback으로 처리하지 않고 분류 단계에서 제외한다:
   - 본인(`gh api user -q .login`로 얻는 self login)이 작성자인 `issue_comment` / `review` / `review_comment` 전부. review-request 코멘트뿐 아니라 codex 코멘트에 단 inline reply("Fixed in <sha>"), 진행 메모 등 자기 자신이 남긴 것은 모두 제외한다 — loop은 자기 코멘트를 자기에게 줄 feedback으로 처리하지 않는다. baseline을 자기 reply보다 이르게 잡으면 이 reply가 "새 actionable feedback"으로 둔갑해 조기 종료하므로, 작성자 기준 제외가 본문 패턴 매칭보다 우선이다. **단 self login을 얻지 못한 경우(예: `gh api user` 실패)**에는 login으로 self를 식별할 수 없으므로, `issue_comment`에 한해 본문이 `$CODEX_REVIEW_REQUEST_BODY`와 정확히 일치하는 것만 제외한다 (이 degraded 상태에서 `@codex review please fix flaky test` 같은 제3자 코멘트는 반드시 surface해야 하므로 prefix 매칭은 쓰지 않는다).
   - `$CODEX_PASS_ACTOR`(기본 `chatgpt-codex-connector[bot]`)가 남긴 `issue_comment` 또는 `review` body가 `$CODEX_PASS_COMMENT_PATTERN`(기본 regex `didn['’]?t find any major issues`, case-insensitive)에 매칭하는 경우 (pass-comment). **단 review의 `state == "CHANGES_REQUESTED"` 또는 `state == "DISMISSED"`이면 매칭 여부와 무관하게 actionable feedback으로 남긴다 (state veto)** — 명시적 변경 요청은 본문에 우연히 pass phrase가 들어가도 caller에게 pass로 인계되어서는 안 된다. **또한 `review` 형태의 pass-comment는 그 `review.commit_id`가 `reviewed_head_sha`와 일치할 때만 pass로 인정한다 (stale-pass 가드)** — codex가 superseded된 commit A에 "Didn't find any major issues" review를 늦게 올리면 현재 head B를 pass로 오인해 caller가 codex가 보지 않은 commit을 land할 수 있는데, live-head drift 가드는 live head == `reviewed_head_sha`(=B)라 이 경우를 잡지 못한다. `issue_comment` 형태 pass-comment는 commit_id가 없어 pin 불가(baseline + drift 가드가 backstop).
   - **stale-commit `review` / `review_comment` (단 `$CODEX_PASS_ACTOR` 작성분에 한함)** — codex가 작성한 항목의 `commit_id`가 존재하고 `reviewed_head_sha`(이번 baseline 시점에 기록한, codex가 평가해야 하는 현재 head SHA)와 불일치하면 stale로 보고 제외한다. codex 리뷰 지연(~수 분)이 fix-and-push 지연보다 길어, 이미 superseded된 commit에 대한 codex의 뒤늦은 리뷰가 새 baseline 이후 도착하면 fresh actionable feedback으로 둔갑해 이미 고친 이슈를 재적용시키기 때문이다. **scope**: 이 stale-drop은 codex 작성 항목에만 적용한다. 사람 reviewer가 이전 commit에서 pending review를 시작해 새 push 뒤 제출하면 GitHub가 그 review를 옛 commit_id로 기록하지만 이는 유효한 actionable feedback이므로 commit_id와 무관하게 반드시 surface한다 — non-codex 항목은 절대 stale-drop하지 않는다. **fail open** (codex 항목에도): `reviewed_head_sha`를 모르거나 항목에 `commit_id`가 없으면 유지한다(baseline-pin만 적용). `issue_comment`는 commit 연관 정보가 없어 적용 불가(baseline-pin only). stale 항목을 모두 제외한 결과 actionable feedback이 비면 추가 행동 없이 turn을 종료하고 현재 head에 대한 codex 리뷰를 계속 기다린다 — 다음 wake-up에서 fresh 리뷰(commit_id == `reviewed_head_sha`)가 도착하면 그때 처리한다. 이 actionable-feedback 분류용 stale 가드는 pass 신호의 "SHA drift 가드"(아래)와 별개로, feedback 경로에도 동일한 commit 핀을 적용한다.

   분류 후 흐름:
   - **분류 후 남은 actionable feedback이 있다면** → "Feedback 처리"로 진행. codex 본인뿐 아니라 다른 reviewer/사용자 코멘트도 포함.
   - **actionable feedback이 비어 있고 pass-comment가 있었다면** → "Pass 신호 인계"로 진행.
   - 둘 다 없으면 다음 항목(2/3)으로.

   순서가 중요: pass-comment를 우선 처리하지 않는다. 동일 wake-up window에 다른 reviewer의 actionable comment가 함께 있을 수 있어 그것을 무시하고 pass 인계로 가면 안 된다.
2. 새 코멘트는 없고 CI/check 완료 등 다른 이벤트만 있으면 상태만 기록한 뒤, `last_push_at` 이후 경과 시간을 보고 **silent-approval probe** 조건을 확인한다 (아래 참조).
3. 처리할 항목이 없으면 즉시 turn을 종료해 다음 이벤트를 기다린다. sleep/polling으로 깨어 있지 않는다.

silent-approval probe는 codex의 reaction-only 통과를 잡기 위한 것이고, 1번 항목(새 코멘트 존재)이 충족된 wake-up에서는 따로 실행하지 않는다. 코멘트 처리 후 push하면 baseline이 갱신되며 그 이후의 reaction은 다음 사이클의 probe가 평가한다.

### Silent-approval probe

GitHub은 reaction(👍)을 webhook event로 전달하지 않으므로 codex가 코멘트 없이 reaction만 다는 경우는 wake-up이 오지 않을 수 있다. 이를 보완하기 위해 **`last_push_at` 이후 5분(`CODEX_SILENT_PROBE_DELAY`, 기본 300초)이 지났고 baseline 이후 codex 코멘트가 도착하지 않은** 상황에서만 다음 probe를 실행한다.

`wait-codex-review.sh`(Path B)와 동일한 신호 분류를 따른다. Pass actor / Pass reaction / pass-comment pattern / review-request body는 환경변수 `CODEX_PASS_ACTOR` / `CODEX_PASS_REACTION` / `CODEX_PASS_COMMENT_PATTERN` / `CODEX_REVIEW_REQUEST_BODY` (모두 Path A·B 공통)로 override 가능하므로 probe 명령은 이 변수를 반드시 사용한다. hardcode하면 override 사용 repo에서 pass를 놓친다.

- **Pass 신호** (아래 둘 중 하나만으로도 Pass):
  - PR body에 `$CODEX_PASS_ACTOR`의 `$CODEX_PASS_REACTION` reaction이 baseline 이후 추가됨, 또는
  - baseline 이후 `$CODEX_PASS_ACTOR`가 남긴 `issue_comment` 또는 `review` body가 `$CODEX_PASS_COMMENT_PATTERN`을 case-insensitive substring으로 포함 (단 `review` 형태는 `review.commit_id == reviewed_head_sha`일 때만 Pass로 인정 — stale-pass 가드; `issue_comment`는 commit_id가 없어 pin 불가)
- **Eyes 신호**: PR body에 누구든 `eyes` reaction이 있거나, 본인이 이번 baseline에 남긴 `$CODEX_REVIEW_REQUEST_BODY` issue comment의 `reactions.eyes` count가 1 이상

조회 예시 (모두 `--paginate` + `jq -s 'add // []'` 패턴. `gh api --jq`는 jq의 `--arg`를 받지 못하므로 pipe로 jq에 직접 넘긴다. `wait-codex-review.sh`의 `fetch_list_or_empty`와 같은 방식):

```bash
: "${CODEX_PASS_ACTOR:=chatgpt-codex-connector[bot]}"
: "${CODEX_PASS_REACTION:=+1}"
# CODEX_PASS_COMMENT_PATTERN은 case-insensitive Oniguruma regex. default는
# straight/curly apostrophe 모두 흡수하면서 "did find ..." 같은 opposite
# meaning은 거부한다. $'...'로 빌드해야 apostrophe가 살아남는다.
default_pass_comment_pattern=$'didn[\'’]?t find any major issues'
: "${CODEX_PASS_COMMENT_PATTERN:=$default_pass_comment_pattern}"
# CODEX_REVIEW_REQUEST_BODY의 실제 default는 multi-line이며 환경변수 표에
# 정의돼 있다. literal `@codex review` 한 줄로 default를 잡으면 multi-line
# 본문으로 게시된 자기 코멘트와 정확 일치가 실패해 query #3의 dedup이
# 깨진다. 호출자가 같은 본문을 미리 export하거나 아래처럼 $'...'로 일치시킨다.
default_review_request_body=$'@codex review\n\nIf you have no major issues to flag, please reply with a comment containing "Didn\'t find any major issues" rather than only adding a reaction. This lets the automated review loop confirm pass via webhook without polling reactions.'
: "${CODEX_REVIEW_REQUEST_BODY:=$default_review_request_body}"

# 1a) PR body의 pass reaction (Pass 신호 A)
gh api --paginate "repos/<owner>/<repo>/issues/<pr>/reactions" \
  | jq -s --arg base "<baseline>" \
         --arg actor "$CODEX_PASS_ACTOR" \
         --arg react "$CODEX_PASS_REACTION" '
      add // []
      | [.[] | select(.user.login==$actor)
             | select(.content==$react)
             | select(.created_at > $base)] | length'

# 1b) baseline 이후 codex bot이 남긴 pass-comment (Pass 신호 B). regex 매칭,
#     CHANGES_REQUESTED/DISMISSED state는 본문 매칭 여부와 무관하게 veto.
#     review 형태(=commit_id 보유) pass-comment는 reviewed_head와 일치할 때만
#     인정한다 (stale-pass 가드). issue_comment는 commit_id가 없어 fail open.
#     두 fetch를 별도 캡처하고 둘 다 성공한 경우에만 합산해서 매칭한다 —
#     brace group {a;b;} | jq는 마지막 명령의 exit status만 반영하므로
#     issue_comments fetch가 실패하고 reviews만 성공해도 silent하게 부분
#     데이터로 pass를 잘못 판정할 위험이 있다.
ic_json=$(gh api --paginate "repos/<owner>/<repo>/issues/<pr>/comments") || ic_json=""
rv_json=$(gh api --paginate "repos/<owner>/<repo>/pulls/<pr>/reviews")  || rv_json=""
if [ -n "$ic_json" ] && [ -n "$rv_json" ]; then
  printf '%s\n%s\n' "$ic_json" "$rv_json" \
    | jq -s --arg base "<baseline>" \
           --arg actor "$CODEX_PASS_ACTOR" \
           --arg reviewed_head "<reviewed_head_sha>" \
           --arg pat "$CODEX_PASS_COMMENT_PATTERN" '
        def at_field: (.created_at // .submitted_at // "");
        def matches: ($pat | length) > 0 and ((.body // "") | test($pat; "i"));
        def state_ok: ((.state // "") | (. != "CHANGES_REQUESTED" and . != "DISMISSED"));
        def fresh_commit: ((.commit_id // "") | length) == 0 or (.commit_id == $reviewed_head);
        add // []
        | [.[] | select(.user.login==$actor)
               | select(at_field > $base)
               | select(matches)
               | select(state_ok)
               | select(fresh_commit)] | length'
else
  echo "WARN: deferring pass-comment probe — incomplete fetch (ic_ok=$([ -n "$ic_json" ] && echo 1 || echo 0), rv_ok=$([ -n "$rv_json" ] && echo 1 || echo 0))" >&2
  echo 0
fi

# 2) PR body의 baseline 이후 `eyes` (Eyes 신호 1)
gh api --paginate "repos/<owner>/<repo>/issues/<pr>/reactions" \
  | jq -s --arg base "<baseline>" '
      add // []
      | [.[] | select(.content=="eyes")
             | select(.created_at > $base)] | length'

# 3) 이번 baseline 안에 본인이 남긴 review-request 코멘트의 eyes count (Eyes 신호 2)
#    self_login은 `gh api user -q .login`으로 얻는다.
gh api --paginate "repos/<owner>/<repo>/issues/<pr>/comments" \
  | jq -s --arg base "<baseline>" \
         --arg me "<self_login>" \
         --arg req "$CODEX_REVIEW_REQUEST_BODY" '
      add // []
      | [.[] | select(.user.login==$me)
             | select(.body==$req)
             | select(.created_at > $base)
             | (.reactions.eyes // 0)] | add // 0'
```

세 query 모두 `--paginate`를 기본으로 둔다. GitHub REST는 페이지당 30개가 기본이라 활성 PR에서는 후속 페이지에 codex의 신호가 위치할 수 있고, 누락 시 분기가 잘못된다.

결과 분기:

- 1a 또는 1b가 > 0 → **Pass**. "Pass 신호 인계"로 진행 후 `mcp__github__unsubscribe_pr_activity` 호출.
- Pass 신호 없음 + (2번 또는 3번 > 0) → codex가 작업 중이라는 신호. 추가 행동 없이 turn 종료해 다음 이벤트를 기다린다.
- 넷 다 0 → entry에서 이미 `@codex review`를 남겼는데도 codex가 어떤 reaction도 달지 않은 상태. 사용자에게 codex 미응답을 보고하고 turn 종료. probe에서 `@codex review`를 다시 게시하지 않는다 — 동일 baseline 동안 entry의 1회로 한정한다. 진입 시 stale `eyes`가 있어 entry가 게시를 건너뛴 드문 경우라도 같다.

probe 시점은 자연스러운 wake-up에 piggyback한다. 자체 timer나 sleep loop는 만들지 않는다. wake-up이 5분보다 일찍 도착해서 probe 조건을 만족하지 못하면 그냥 wake-up 1번 항목 흐름만 처리하고 종료한다 — 다음 wake-up에서 조건이 충족되면 그때 probe한다. push 후 5분이 지났는데 wake-up이 전혀 오지 않는 무이벤트 케이스는 사용자가 다시 명령을 줄 때 처리하며, 그 호출 시점에 probe 1회를 실행한다.

### feedback 수정 후 push

1. 수정 → commit → push.
2. `last_push_at`을 새 push timestamp로 갱신한다 (baseline 재계산: 위 "진입" 2단계와 동일). **`reviewed_head_sha`도 새 push 후 head SHA로 갱신한다** (`gh pr view <PR> --json headRefOid -q .headRefOid`). 이후 review 사이클은 이 새 SHA를 기준으로 평가된다.
3. **review-request 재게시** (entry 3단계와 동일): 새 baseline 기준으로 `$CODEX_REVIEW_REQUEST_BODY` 코멘트를 1회 무조건 남긴다 (eyes 체크 없이). 자동으로 codex 리뷰가 트리거되지 않는 repo에서는 이 재요청이 없으면 무한 대기에 빠지고, 트리거되는 repo에서도 codex가 reaction-only로 끝낼 가능성을 막기 위해 무조건 게시한다. 이 게시는 동일 baseline 1회 한정.
4. subscribe는 이미 active이므로 재호출하지 않는다 (idempotent이지만 불필요).
5. turn 종료.

### 종료

- Pass 신호 감지 직후 `mcp__github__unsubscribe_pr_activity` 호출. caller-visible pass 보고 작성 후 review-loop 종료. **후속 merge/land 분기는 호출자가 결정한다.**
- 사용자가 watch 중단을 지시하면 즉시 unsubscribe하고 추가 push를 중단한다.
- PR이 close되거나 외부에서 merge되어 후속 review가 불필요해지면 unsubscribe 후 종료.

## Path B: 폴링 스크립트

각 대기 사이클은 `wait-codex-review.sh`를 foreground로 1회 실행해 처리한다. 스크립트가 내부 polling을 담당하고 종료 시점에 필요한 결과만 반환한다. GitHub app으로 즉시 확인 가능한 상태가 있어도 대기/polling은 스크립트에 맡긴다. feedback을 수정하고 push한 뒤에는 다음 대기 사이클로 보고 스크립트를 다시 실행한다.

```bash
CODEX_REVIEW_HELPER=".agents/scripts/wait-codex-review.sh"
[ -x "$CODEX_REVIEW_HELPER" ] || CODEX_REVIEW_HELPER="$HOME/.agents/scripts/wait-codex-review.sh"
[ -x "$CODEX_REVIEW_HELPER" ] || { echo "Missing wait-codex-review.sh"; exit 1; }
bash "$CODEX_REVIEW_HELPER"
```

기본 stdout은 사람이 읽는 feedback 출력이다. 구조화된 관찰이 필요하면 동일한 foreground 호출에 `--json`을 붙이거나 `CODEX_REVIEW_OUTPUT=json`을 설정한다. 이 모드는 exit code를 바꾸지 않고 stdout에 compact `schema_version:1`, `kind:"codex_review_observation"` JSON 1개를 출력한다.

다음 패턴은 금지한다.

- `bash ... &` 로 background polling
- background 실행 후 주기적 output 확인
- 매 sleep 사이에 PR 상태를 다시 polling
- 별도 monitor 도구로 stream watch

### 절차

1. PR 만든 직후, 또는 push 직후, 스크립트를 foreground로 1회 실행한다.
2. 종료될 때까지 기다린다. 스크립트가 PR 감지, baseline 계산, feedback/reaction polling을 처리한다.
3. 종료 코드에 따라 처리한다.

| exit | 의미 | review-loop의 다음 행동 |
| ---- | ---- | ----------------------- |
| 0 | Codex pass 신호(reaction 또는 pass-comment 매칭) 감지 | **caller에게 pass 신호 인계 후 종료.** merge/land는 caller가 결정. |
| 1 | 새 comment/review가 stdout에 출력됨 | 분석 -> 수정 -> commit -> push -> 스크립트 재실행 |
| 2 | 두 번째 timeout 또는 review 요청 미확인 | loop 종료, 사용자에게 타임아웃 보고 |
| 3 | PR 감지 실패 | PR 번호 또는 URL 요청 후 스크립트 인자로 재실행 |
| 4 | 진행을 막는 API 오류 | 인증/권한/네트워크 문제 보고 |

첫 successful 조회에서 PR의 comment/review/reaction이 모두 비어 있으면 helper는 한 번만 `CODEX_INITIAL_EMPTY_DELAY`초, 기본 300초를 쉰 뒤 기존 `CODEX_POLL_INTERVAL`로 계속 조회한다.

각 polling iter에서 helper는 PR 본문 reaction, 인증 사용자 comment의 reaction, 그리고 codex bot이 남긴 issue comment/review body의 pass-comment 매칭을 확인한다. reaction 또는 pass-comment 매칭 중 하나라도 baseline 이후 발견되면 exit 0으로 종료한다.

- 첫 polling iter에서 review 요청을 아직 남기지 않았으면 PR에 `$CODEX_REVIEW_REQUEST_BODY` (기본 본문: codex에게 pass-comment로 답해달라고 부탁) 코멘트를 1회 무조건 남긴다. codex의 reaction 상태는 게시 조건에 영향을 주지 않는다.
- 게시 후 PR 본문 또는 내 코멘트에 `eyes` reaction이 생기면 acknowledge로 인식하고 계속 대기한다.
- review 요청 comment 자체는 새 feedback으로 처리하지 않는다.
- 게시 후 다음 3번의 polling iter 안에 PR 본문 또는 내 comment에 `eyes` reaction이 생기지 않으면 exit 2로 종료한다.
- 일반 polling timeout은 한 번 더 대기하고, 두 번째 timeout에서 exit 2로 종료한다.

## Feedback 처리

- codex review 결과를 그대로 작업 목록으로 받아들이지 말고 적대적/비판적으로 재평가한다. 각 comment/review item마다 주장, 근거, 재현 가능성, 실제 영향, severity, 범위 적합성을 먼저 판정한다.
- Opus reviewer를 사용할 경우 raw PR 전체를 넘기지 말고 새 feedback, 관련 diff, helper-generated review dossier 또는 수동 risk summary, 재현/검증 출력, 이전 finding 요약만 전달한다.
- 유효한 item은 가장 합리적인 해결 방식을 선택한다: root-cause code fix, test 보강, 문서/계약 정정, 요구사항 clarification, 또는 사용자 결정 요청. 리뷰를 만족시키려고 보안/검증/계약을 약화하거나 symptom-only patch를 만들지 않는다.
- 코멘트가 모호하거나 우선순위 판단이 필요하면 코드 수정 전 사용자에게 확인한다.
- 이미 처리된 이슈, 재현 불가 항목, 범위 밖 요구는 근거를 남기고 제외할 수 있다.
- 수정은 최소 diff로 하고, 관련 테스트와 repo가 정의한 검증 명령을 다시 실행한다.
- push 후:
  - **Path A**: `last_push_at`/baseline을 갱신하고 turn을 종료한다. subscription은 그대로 유효하다. silent-approval probe는 wake-up 시점의 조건 충족 여부에 따라 자동 실행된다.
  - **Path B**: 스크립트를 foreground로 다시 실행한다.

## Pass 신호 인계

Path A의 Pass 신호(reaction 또는 pass-comment 매칭) 감지 또는 Path B의 exit 0은 Codex pass를 의미한다. review-loop은 여기서 종료하고 caller에게 **SHA-pinned pass payload**를 인계한다. 자유 문구 보고만으로 끝내지 않는다. caller가 stale pass로 다른 head를 잘못 land하지 않도록 PR/head SHA/baseline/signal source를 반드시 포함한다.

### Pass payload schema

`schema_version:1`, `kind:"review_loop_pass_signal"` 필드를 가진 한 줄 JSON. 필수 필드:

| 필드 | 의미 |
|------|------|
| `schema_version` | 정수 1 |
| `kind` | `"review_loop_pass_signal"` |
| `repo` | `owner/repo` |
| `pr_number` | 정수 PR 번호 |
| `head_sha` | **codex 리뷰가 평가한 commit의 SHA** (= 마지막 baseline 시점의 `reviewed_head_sha`). live PR head가 아니다. |
| `baseline` | review 마지막 baseline ISO timestamp |
| `signal_source` | `"reaction"`, `"pass_comment"`, 또는 `"exit_zero"` 중 하나 |
| `path` | `"path_a"` 또는 `"path_b"` |

caller는 이 payload의 `head_sha`를 후속 land helper 호출 시점에 expected SHA로 전달해야 한다. `scripts/land-pr.sh`는 `--expected-head-sha SHA` (또는 `LAND_PR_EXPECTED_HEAD_SHA` env)를 받아 PR live head가 `head_sha`와 다르면 `expected_head_mismatch` envelope으로 land를 거부한다 (rc=6). 이게 SHA chain의 land 단계 enforcement다.

### SHA drift 가드

Pass 신호 감지 시 payload emit **직전**에 PR live head를 다시 fetch한다 (`gh pr view <PR> --json headRefOid -q .headRefOid` → `live_head_sha`).

- `live_head_sha == reviewed_head_sha`이면 정상 → 아래 Path A/B 인계 진행.
- `live_head_sha != reviewed_head_sha`이면 **pass 폐기**. codex가 본 commit 이후 다른 commit이 추가됐으므로, 이전 pass 신호로 새 commit을 land로 인계해서는 안 된다. 처리:
  - `reviewed_head_sha`를 `live_head_sha`로 갱신, baseline을 새 push 기준으로 재계산.
  - Path A에서는 새 baseline에 review-request comment 재게시 후 turn 종료해 다음 wake-up을 기다린다 ("feedback 수정 후 push" 단계 2~5와 동일 처리).
  - Path B에서는 wait-codex-review.sh를 새 baseline으로 재실행한다.

이 drift 가드는 worker context에서도 동작한다: worker는 자기 branch push 권한이 있으므로 새 push가 발생했으면 `reviewed_head_sha` 갱신이 가능하다.

### Path A 인계

drift 가드를 통과한 뒤, `mcp__github__unsubscribe_pr_activity { owner, repo, pullNumber }` 호출 후, conversation에 위 schema의 JSON 1줄을 fenced code block으로 emit하고 caller-visible 한국어 요약 1줄을 추가한다. 예:

```json
{"schema_version":1,"kind":"review_loop_pass_signal","repo":"owner/repo","pr_number":41,"head_sha":"a15a9a2ed287869c306a1ca71ad76a8a59118516","baseline":"2026-05-26T15:36:52Z","signal_source":"pass_comment","path":"path_a"}
```

`signal_source`는 어느 Pass 신호로 감지됐는지에 따라 `reaction` (PR body reaction) 또는 `pass_comment` (codex bot 코멘트 매칭) 중 하나다.

### Path B 인계

`wait-codex-review.sh`를 `--json` 또는 `CODEX_REVIEW_OUTPUT=json`으로 실행한다. exit 0과 함께 stdout에 `kind:"codex_review_observation"` JSON이 출력된다. 이 observation은 helper가 baseline 캡처와 동시에 캡처한 `reviewed_head_sha` 필드를 포함한다 — review-loop이 별도로 head SHA를 fetch할 필요가 없고 baseline과 SHA의 시점 불일치도 없다. review-loop은 exit 0을 받은 후 observation의 `reviewed_head_sha`를 `reviewed_head_sha` 로 채택한 뒤 위 "SHA drift 가드"를 적용한다. 가드를 통과하면 observation의 `repo`/`pr_number`/`baseline`/`reviewed_head_sha`와 pass 신호 종류를 합쳐 위 `review_loop_pass_signal` payload를 caller에게 emit한다. `signal_source`는 observation의 pass 신호 종류를 따른다 (reaction이면 `reaction`, pass-comment이면 `pass_comment`, 그 외 exit-zero이면 `exit_zero`). drift가 감지되면 helper를 새 baseline + 새 `reviewed_head_sha`로 재실행한다.

review-loop은 PR을 merge하지 않는다. 후속 행동(checks 확인, merge 정책 적용, land 실행)은 호출자(`/codex-loop`, `/run-team`, 또는 사용자)가 결정한다.

worker context에서 호출됐다면 pass 인계가 review-loop의 정상 종료점이다. land 권한이 없는 worker는 여기서 더 진행하지 않고 작업 상태(위 pass payload 포함)를 orchestrator에게 보고한다.

## Terminal 신호 인계 (non-pass)

review-loop이 pass 없이 종료하는 경로(타임아웃, PR 미감지, auth/API 실패, eyes ack 실패, 사용자 중단, 외부 close)도 worker → orchestrator 인계가 필요하다. prose 보고만으로는 caller가 retry/escalate 판단을 자동화할 수 없으므로 **terminal payload schema**를 동시에 emit한다.

### Terminal payload schema

`schema_version:1`, `kind:"review_loop_terminal_signal"` 필드를 가진 한 줄 JSON. 필수 필드:

| 필드 | 의미 |
|------|------|
| `schema_version` | 정수 1 |
| `kind` | `"review_loop_terminal_signal"` |
| `result` | `"timeout"`, `"pr_not_detected"`, `"api_error"`, `"review_request_unacknowledged"`, `"user_stopped"`, `"externally_closed"` 중 하나. `wait-codex-review.sh`의 `result` enum과 정렬되어 있어 Path B에서 helper observation을 그대로 사용 가능. |
| `exit_code` | Path B면 wait-codex-review.sh exit code (1/2/3/4 등); Path A면 review-loop이 stop 분기에 따라 부여하는 정수 (2 timeout/review_request_unacknowledged, 3 PR 미감지, 4 API 실패, 5 user stop/external close) |
| `repo` | `owner/repo` (PR 감지 실패면 빈 문자열 가능) |
| `pr_number` | 정수 PR 번호 (PR 감지 실패면 `null`) |
| `current_head_sha` | terminal 시점 PR live head (PR 감지 실패면 `null`) |
| `baseline` | 마지막 baseline ISO timestamp (없으면 `null`) |
| `path` | `"path_a"` 또는 `"path_b"` |
| `retryable` | bool. `timeout`/`api_error`/`review_request_unacknowledged`는 보통 true, `pr_not_detected`/`user_stopped`/`externally_closed`는 false. |
| `failure_reason` | 짧은 자연어 설명 (영어/한국어 무관, 80자 이내 권장) |

### Path A terminal 인계

stop 분기에 도달하면 `mcp__github__unsubscribe_pr_activity` 호출 후 terminal payload JSON 1줄을 fenced code block으로 emit한다. caller-visible 한국어 요약 1줄(원인 + retry 권장 여부)을 추가한다.

### Path B terminal 인계

`wait-codex-review.sh` exit code를 result/exit_code/retryable mapping에 따라 변환한다:

| exit code | result | retryable |
| --------- | ------ | --------- |
| 2 | `timeout` 또는 `review_request_unacknowledged` (helper observation의 `.result`로 분기) | true |
| 3 | `pr_not_detected` | false |
| 4 | `api_error` | true |

helper exit code만으로 timeout과 review_request_unacknowledged를 구분할 수 없으므로 (둘 다 exit 2), review-loop은 **반드시 helper observation JSON의 `.result` 필드를 사용**해 terminal payload의 `result`를 결정한다. `exit_code` 필드는 helper의 원래 exit code를 그대로 넣는다 (loss-of-info 방지). review-loop은 terminal payload를 emit한 뒤 같은 exit code로 caller에게 종료한다.

worker context에서 호출됐다면 worker는 이 terminal payload를 orchestrator에게 보고하고, orchestrator가 retry/escalate 정책을 결정한다.

## 환경변수

Path A·B 공통 (둘 다 동일 시맨틱으로 사용):

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CODEX_PASS_ACTOR` | `chatgpt-codex-connector[bot]` | 통과 reaction/코멘트를 남기는 봇 login |
| `CODEX_PASS_REACTION` | `+1` | 통과를 의미하는 reaction content |
| `CODEX_PASS_COMMENT_PATTERN` | `didn['’]?t find any major issues` | case-insensitive Oniguruma regex. `$CODEX_PASS_ACTOR`가 남긴 `issue_comment` 또는 `review` body가 매칭하면 Pass로 인식 (단 `review`의 state가 `CHANGES_REQUESTED`/`DISMISSED`이면 매칭과 무관하게 actionable feedback으로 유지). 기본 regex는 straight/curly apostrophe 모두, 그리고 apostrophe 없는 변형까지 흡수하면서 "did find …" 같은 opposite-meaning 문구는 거부한다. |
| `CODEX_REVIEW_REQUEST_BODY` | (다중 줄, 아래 참조) | baseline당 1회 무조건 남기는 issue comment 본문. 기본 본문은 codex에게 reaction이 아닌 pass-comment 형태로 답해달라고 명시 — webhook으로 도착하는 신호를 확보하기 위함. 정확 일치 비교로 자기 자신의 코멘트를 feedback에서 제외하므로, override 시에도 게시 본문과 동일하게 둔다. |

`CODEX_REVIEW_REQUEST_BODY` 기본 본문 (그대로 PR comment로 게시됨):

```
@codex review

If you have no major issues to flag, please reply with a comment containing "Didn't find any major issues" rather than only adding a reaction. This lets the automated review loop confirm pass via webhook without polling reactions.
```

Path A 전용:

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CODEX_SILENT_PROBE_DELAY` | 300 | 마지막 push 이후 이 시간(초) 이상 경과하고 codex 코멘트가 도착하지 않았을 때만 reaction probe를 실행 |

Path B (`wait-codex-review.sh`) 전용:

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CODEX_POLL_INTERVAL` | 20 | 폴링 간격 (초) |
| `CODEX_POLL_TIMEOUT` | 600 | 전체 대기 한도 (초) |
| `CODEX_INITIAL_EMPTY_DELAY` | 300 | 첫 successful 조회에서 comment/review/reaction이 모두 없을 때 한 번만 쉬는 시간 (초) |
| `CODEX_BASELINE` | (auto) | 이 ISO timestamp 이전 활동 무시 |
| `CODEX_REPO` | (auto) | fork 워크플로 시 base repo 명시 (`owner/repo`) |
| `CODEX_REVIEW_OUTPUT` | `human` | `json`이면 structured observation을 stdout에 출력 |

## 인자 형식 (Path B)

- 인자 없음: 현재 브랜치의 PR 자동 감지
- PR 번호: `bash "$CODEX_REVIEW_HELPER" 42`
- PR URL: `bash "$CODEX_REVIEW_HELPER" https://github.com/owner/repo/pull/42`
- structured observation: `bash "$CODEX_REVIEW_HELPER" --json 42`

## Structured Observation (Path B)

`--json` 출력은 DevDeck 같은 projection layer가 나중에 읽을 수 있는 작은 상태 스냅샷이다. 한 줄 compact JSON이므로 필요하면 호출자가 그대로 JSONL log에 append할 수 있다. 필드는 versioned envelope, repo/PR/baseline, pass reaction 관찰 상태, pass-comment 관찰 상태, feedback items, timeout 상태, review request/eyes acknowledgement 상태, API error classification, `next_allowed_actions`를 포함한다. 이 JSON은 machine state이고, Markdown/stdout human feedback을 대체하지 않는다. review-loop 자체는 기존 exit code 기반 분기를 유지한다.
