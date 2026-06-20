---
name: improve
agents: claude
description: "한 repo에서 개선 후보를 카테고리별로 탐색해 candidate contract로 제안하고, 사용자가 multi-select한 후보들을 parallel_review 심의로 설계 잠근 뒤 /run으로 각각 구현·PR까지 자동 진행(merge는 batch HOLD)하고, batch confirm 후 일괄 land한다. 게이트는 2개(후보 선택·batch land)뿐이고 per-cycle 컨펌은 없다. 오버엔지니어링 금지 + 기술스택 컨벤션/아키텍처 준수가 1급 제약. Claude-only. 진입: /improve [<개선 대상 자유 입력>]"
---

# /improve

`/improve [<개선 대상 자유 입력>]`은 한 repo의 개선 작업을 **thin front-end**로 묶는다.
직접 새 구현/리뷰/land 엔진을 만들지 않고, 진짜 신규 로직 3개만 가진다:

1. **대상 결정** — 자유 입력(scope hint) + targets repo 선택.
2. **bounded discovery** — 선택 카테고리 안에서 개선 후보를 탐색·점수화해
   commit-sized 1개 단위의 **candidate contract**로 제안한다.
3. **handoff** — 사용자가 고른 후보들을 parallel_review 심의로 설계 잠근 뒤
   선택 repo의 `/run --hold-before-land`로 구현하고, batch confirm 후 일괄 land.

심의(pingpong)·verify·review·collision-guard·land는 모두 `/run`과
`pingpong-relay`가 이미 소유한 메커니즘을 재사용한다. 이 재사용이 곧
"오버엔지니어링 금지"를 툴링 자체에도 적용하는 길이다.

사용자에게 보이는 보고/질문/안내는 한국어로 작성한다. 명령, 파일명, JSON 키,
helper 인자, 코드 식별자는 원문 언어를 유지한다.

## 호출 표면

- `/improve` — scope hint 없이 진입(선택 repo 전체를 대상으로 하되 cap 적용).
- `/improve <scope hint>` — 자유 입력으로 탐색 범위를 좁힌다. scope hint는 파싱·변환하지
  않고 discovery의 범위 필터로 그대로 쓴다. 예:
  - `/improve run 스킬`
  - `/improve 결제 기능`
  - `/improve 전체 아키텍처`

## 1급 제약 — 오버엔지니어링 금지 (모든 단계에 우선)

이 제약은 discovery·심의·구현 전 단계에서 다른 어떤 휴리스틱보다 우선한다.

- **한 후보 = commit-sized 1개.** 스멜/이슈를 고치는 **최소 변경**만 한다.
- 투기적 추상화, 미래 확장용 옵션, 한 번만 쓰는 추상화, 불필요한 설정화를
  **추가하지 않는다.**
- repo에서 **실제로 관측된 기존 컨벤션·기술스택·아키텍처 패턴만** 사용한다.
  repo에 없는 외래 패턴/라이브러리/레이어를 도입하지 않는다.
- 근거 없는 "더 좋은 추상화" 제안은 후보 목록과 심의 synthesis에서 **제외한다.**
  모든 후보·설계 제안은 관측 근거(중복 위치, 컨벤션 드리프트 파일, 기존 패턴,
  예상 diff 범위)를 동반해야 한다.
- scope를 넓히는 발견은 임의로 구현하지 않고 후보로 보고한다(좁은 diff 원칙).

## 게이트는 2개뿐 (per-cycle 컨펌 없음)

per-cycle 컨펌 피로를 없애기 위해 사용자 결정 지점을 **2개의 자연 지점**으로 옮긴다.

- **게이트 1 — 후보 multi-select**: candidate contract 목록에서 작업할 후보를 고른다.
  이것이 **scope 잠금**이다. 후보를 고르는 순간 그 후보의 contract(scope/files/
  non-goals/risk/tests/예상 diff)가 작업 경계가 된다.
- **게이트 2 — batch 리뷰 → land**: 선택 후보들이 각각 PR open(merge 전 HOLD)까지
  자동 진행된 뒤, 전체를 **한 번에** 리뷰하고 land를 승인한다.

두 게이트 사이의 per-candidate 심의·구현·검증·리뷰는 자동으로 진행되며 사용자에게
중간 컨펌을 묻지 않는다. 단, **authority gate**(AGENTS.policy.md의 10개 카테고리:
secrets, security/privacy, destructive, cost, product scope 등)에 해당하는 결정이
구현 중 새로 드러나면 그때는 멈추고 사용자에게 묻는다 — over-engineering 회피가
authority gate를 무력화하지 않는다.

## 진입 카테고리

진입 시 아래 카테고리에서 하나 이상 선택한다. 분류는 **behavior-preserving 여부로
먼저 가른다** — 이 축이 `/run` 리뷰·테스트 강도를 결정한다.

| 카테고리 | 정의 | behavior | discovery 특이사항 |
|---|---|---|---|
| 리팩토링 | 구조/가독성/중복 제거 | **보존** | 동작 불변. 리뷰 가벼움 |
| 성능 개선 | 속도/메모리/효율 | 보존 + **측정 필요** | contract엔 **baseline(개선 전) 측정 + 측정 plan/test**만 담는다(after는 discovery 시점에 없음 — /run verify가 개선 후 metric을 기록) |
| 로직 개선 | 알고리즘/접근 개선 | **변경 가능** | 강한 test/review 게이트 |
| 버그 개선 | 결함 수정(정확성) | **변경 가능** | **investigate-first**(아래) |
| 보안 | 취약점/인젝션/authz/시크릿 | **변경 가능** | **investigate-first** + authority gate 자주 해당 |

- behavior-changing(로직/버그/보안) 후보는 `/run`에서 더 강한 테스트·리뷰를 받도록
  contract에 required tests를 명시한다.
- **버그·보안은 investigate-first**: 증상/위협 → 재현 → 영향 범위를 먼저 확인한
  결과가 candidate contract가 된 뒤에만 batch 실행 후보로 **승격**한다. root cause
  없이 증상 패치만 하는 후보는 만들지 않는다(`/investigate` 또는 동등한 조사
  단계를 discovery에서 수행).

카테고리 목록 자체에도 over-engineering 금지를 적용한다 — 5개를 넘기지 않는다.

## helper / 입력 resolution

```bash
# targets.tsv: repo root에 있으면 cross-repo 선택 활성, 없으면 현재 repo만 대상.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
TARGETS=""
[ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/targets.tsv" ] && TARGETS="$REPO_ROOT/targets.tsv"

# pingpong-relay: repo root → user-level (run.md Step 3.5와 동일 resolver).
RELAY=""
for c in "$REPO_ROOT/.agents/scripts/pingpong-relay.sh" \
         "$HOME/.agents/scripts/pingpong-relay.sh" \
         "$REPO_ROOT/scripts/pingpong-relay.sh"; do
  [ -x "$c" ] && { RELAY="$c"; break; }
done

# agent-dialog (pingpong helper) — relay와 동일하게 source-tree fallback 포함
HELPER=""
for c in "$REPO_ROOT/.agents/scripts/agent-dialog.sh" \
         "$HOME/.agents/scripts/agent-dialog.sh" \
         "$REPO_ROOT/scripts/agent-dialog.sh"; do
  [ -x "$c" ] && { HELPER="$c"; break; }
done
```

`targets.tsv`는 헤더 없는 TSV다: `name`, `path`, `branch`, `profile`(boilerplate|
universal), `flag`. discovery·구현은 선택한 repo의 `path`로 cd해서 수행한다.

## Flow

### Step 0 — scope hint 파싱

호출 인자를 scope hint로 받는다(없으면 빈 값). 변환하지 않고 그대로 discovery의
범위 필터 텍스트로 보관한다. 빈 값이면 repo 전체가 대상이되 Step 3의 cap이 적용된다.

### Step 1 — 대상 repo 선택

- `targets.tsv`가 있으면 대상 repo는 **free-text 파라미터**로 받는다 — scope hint나
  사용자가 타이핑한 repo 이름/path를 `targets.tsv`에 매칭·resolve한다. **현재 cwd가
  targets의 한 repo면 그 repo가 기본값**이고, scope hint가 특정 repo를 명시하면 그
  repo다. 16+ 행 전체를 "옵션 중 선택"으로 제시하지 않는다 — AGENTS.policy.md는
  옵션-선택 요청을 operator decision 스키마로 강제하고 6+ 옵션을 hard-reject하므로
  목록 나열은 정책 위반/stall이다(free-form 라벨로도 우회되지 않는다). 입력이 모호해
  매칭이 여럿이면 그때만 **≤5개로 좁힌** 작은 확인 pick을 쓴다(여전히 6+ 금지).
- `targets.tsv`가 없으면 현재 repo를 대상으로 한다(선택 단계 생략).
- 선택한 repo의 `path`로 cd하고, **discovery 전에 그 repo를 targets.tsv의 `branch`
  컬럼(선언 base branch)으로 정렬한다** — checkout이 feature/stale branch에 있으면
  candidate contract·locked design이 잘못된 tree 기준이 되고, 이후 `/run`의 sync/
  review-base가 사용자 승인본과 다른 base로 구현하게 된다. 더티 변경 없이 선언 branch를
  clean하게 sync한 base를 확보한 뒤(또는 그 branch의 worktree에서) Step 3 discovery를
  시작한다. 이후 모든 discovery·`/run` 호출은 그 repo cwd에서 수행한다 —
  collision-guard/worktree는 전부 `/run`이 소유하므로 우회 경로를 만들지 않는다.

### Step 2 — 카테고리 선택

위 "진입 카테고리"에서 하나 이상 고르게 한다. 선택은 discovery의 lens가 된다.

### Step 3 — Discover → candidate contracts

선택 repo ∩ scope hint ∩ 선택 카테고리 범위에서만 탐색한다. 메인 세션이 직접
탐색하며(위임하지 않음), repo의 `AGENTS.md`/`CLAUDE.md`/`README` 등 entrypoint와
관측 가능한 컨벤션·아키텍처를 먼저 읽어 **그 repo의 스택/패턴**을 파악한다.

- 후보를 **점수화**한다: 관측 근거 강도, 예상 blast radius, 검증 가능성,
  stack-convention 적합성. 근거가 약하거나 검증 경로가 없는 제안은 카테고리 cap
  안이라도 **제외**한다.
- **카테고리별 top-N cap**으로 flood를 막는다. 후보 선택(게이트 1)은 **구조화된
  operator decision request(options[] 스키마)가 아니라 번호 매긴 free-form 목록**으로
  제시하고 사용자가 번호를 타이핑해 고르게 한다 — 이래야 AGENTS.policy.md의 옵션
  cardinality 규칙(2~3 기본, 4~5는 `allow_extra_options_reason` 필요, 6+ hard-reject)에
  걸리지 않는다. 목록이 길면 가독성을 위해 점수 상위로 페이지를 나눈다(긴 목록 =
  per-cycle 컨펌과 같은 friction). 부득이 구조화된 decision request로 물어야 하면 그
  스키마 한도(≤5, 4~5는 reason 필수)를 따른다.
- 버그·보안 후보는 investigate-first 결과(증상/위협·재현·영향)를 contract에 담는다.

각 후보는 **candidate contract**로 제안한다:

```text
[후보 id] <한 줄 요약>  (카테고리: …)
  scope:        무엇을 바꾸는가 (commit-sized 1개)
  files:        닿는 파일/모듈
  non-goals:    이 후보에서 하지 않는 것 (scope creep 차단)
  risk:         behavior 변경 여부 + blast radius
  tests:        검증 방법 / required tests
  expected_diff: 예상 변경 규모
  evidence:     관측 근거 (중복 위치 / 드리프트 파일 / 기존 패턴 / 측정값 등)
```

### Step 4 — 게이트 1: 후보 multi-select (scope 잠금)

contract 목록을 **번호 매긴 free-form 목록**으로 보이고, 사용자가 작업할 후보 번호를
타이핑해 고르게 한다(구조화된 options[] decision request가 아니라 자유 입력 선택 —
위 Step 3 참조).

- **batch 크기 제한**: 기본 2~3개, **상한 5개**. 더 고르면 여러 batch로 나눈다.
- **같은 파일/모듈을 만지는 후보는 반드시 별도 batch로 분리한다**(한 batch에 같이
  넣지 않는다). Step 5는 batch 내 모든 후보의 held PR을 *먼저* 열고, 각 `/run`은
  시작 시 main에서 review base를 새로 잡으므로(`commands/run.md` Step 1), 같은 batch
  안의 "의존 순서"만으로는 먼저 만든 held PR의 변경이 뒤 후보의 base에 반영되지
  않아 stale-base 충돌·prerequisite 누락이 생긴다. stacked-PR 메커니즘이 없는 한
  batch 내 순서는 보장이 아니다 — 의존 관계가 있으면 batch를 나눠 앞 batch를 land한
  뒤 다음 batch를 시작한다.
- 선택된 각 후보의 contract가 그 작업의 경계다. 이후 단계는 contract를 벗어나지
  않는다.
- **authority-gate 후보는 free-form 선택으로 승인하지 않는다.** 후보가
  AGENTS.policy.md의 10개 authority 카테고리(security/secrets/destructive/product
  scope/cost 등 — 특히 `보안` 카테고리)에 해당하면, free-form 선택 자체가 그 민감
  작업의 *구현 승인*이 되어버린다. 그런 후보는 일반 후보와 분리해 **구조화된 operator
  decision request(verifiable evidence 포함)** 로 개별 escalate해 승인받은 뒤에만
  /run으로 넘긴다. free-form 일괄 선택은 non-authority 후보 전용이다.

선택이 곧 scope 승인이다 — 이 시점 이후 **non-authority 후보에 한해** per-candidate
컨펌은 묻지 않는다. authority-gate 후보는 위 구조화된 승인을 거친다.

### Step 5 — per-candidate 자동 루프 (심의 → 구현, 컨펌 0)

선택된 각 후보를 **순차로(sequential)** 다음을 자동 수행한다 — 같은 logical repo라
`/run`이 active-run을 register하고 두 번째 동시 run을 `active_run_collision`으로
거부하므로, 병렬 `/run`은 구현 전에 실패한다. same-repo 동시성은 team/worker
orchestrator가 그 repo의 동시성을 소유하기 전까지 직렬로 둔다.

1. **설계 심의 (parallel_review auto-relay)**: 후보 contract를 initiator request로
   넣어 `pingpong-relay`를 driver loop로 구동한다. 양측 reviewer가 패턴·invariant·
   tests 후보를 제시·검토하고(synthesis는 그 findings/agreements/conflicts만 담는다 —
   design 압축은 아래 (b)에서 main session이 수행), over-engineering·외래 패턴 제안은
   배제한다.

   ```bash
   # 후보별 세션 init(parallel_review) → request + 양측 response 자동수집 → synthesis
   #   driver: pingpong-relay step 반복(run.md Step 3.5 패턴과 동일, repo root resolver)
   ```
   step의 emit status로 분기한다 (`commands/pingpong.md` parallel auto 계약):
   - `synthesis_ready`: synthesis(`responses`/`union_findings`/`agreements`/
     `conflicts`/`next_action_options`) + confirm-only decision draft가 나온 상태.
     **synthesis는 design이 아니라 advisory 입력이다** — chosen pattern/invariant/
     tests를 담지 않는다(`scripts/pingpong-relay.sh`). lock은 (a)+(b) 둘 다 만족해야 한다:
     - **(a) 모든 finding 처분** — `synthesis.conflicts`가 비어 있고, **draft에
       `deferred`/미처리 single-agent finding이 없다.** relay는 single-agent 비-conflict
       finding을 `conflicts`에서 빼고 draft에 `deferred`로 prefill하므로, `conflicts`만
       보면 그 concern을 조용히 건너뛴다 — `deferred`가 하나라도 있으면 lock 아님. (그리고
       `next_action`은 비-conflict round에도 항상 `needs_user`라 conflict 신호로 쓰지
       않는다.) conflict나 미처리 concern이 있으면 사용자 resolution 전까지 구현에 넘기지
       않고 게이트 2로 보류하거나 묻는다.
     - **(b) design matrix 압축** — (a) 통과 시 **main session이** responses+synthesis를
       `/run` Step 3.5 **Design Decision Matrix**(risk → chosen pattern → rejected
       alternatives → invariant → required tests → residual risk)로 압축한다. **이
       압축본이 locked design**이고, /run에 넘기는 것은 synthesis raw가 아니라 이 matrix다.
   - `converged` (양측 0 findings): (a)는 자동 통과 — main session이 (b) design matrix만
     작성해 locked design으로 쓴다(이 경우 `synthesis_ready`가 아니라 `converged`가 온다).
   - 그 외(`paused` 등 비진행): 구현으로 넘기지 말고 사용자에게 surface한다.

   - **G3 불변식 준수**: parallel_review의 decision은 `sender=user`다. 스킬은
     per-candidate 단계에서 **agent 명의의 자동 decision을 쓰지 않는다.** synthesis는
     orchestrator-only 설계 입력(advisory)으로 소비하고, 그 후보의 작업 승인은
     이미 **게이트 1의 사용자 선택**이 담당한다(최종 승인은 게이트 2). 즉 심의는
     설계를 잠그되 "무인 land"를 의미하지 않는다.
   - 심의가 contract로 풀 수 없는 **authority-gate 결정**(security/secrets/
     destructive 등)을 드러내면 루프를 멈추고 사용자에게 묻는다.
   - **세션 정리(필수, 즉시)**: 그 후보의 synthesis/convergence를 소비한 **직후 곧바로**
     해당 세션을 **exact session id로 닫는다** — **다음 `/run`이나 다음 후보 세션 생성
     전에** 닫아야 한다. 게이트 2까지 미루면 batch의 2~5개 세션이 후속 `/run`·신규
     세션과 겹쳐 sticky-pointer active-set을 오염시킨다(같은 대화의 이후 `/pingpong`이
     다중 active/stale 세션을 보게 됨). synthesis/convergence 시점엔 이미 양측 response가
     있어 `abandon`은 helper가 거부하므로(init-only/orphan 전용 — `tests/agent-dialog.test.sh`),
     정리는 **`/pingpong stop <sid>`(= `sender=user` close decision)** 로 한다. 반려/포기
     세션도 같은 방식으로 즉시 닫는다.

2. **구현 handoff (locked design → /run, merge 전 HOLD)**: 잠근 설계를
   **locked-design context**로 전달해 그 후보를 선택 repo에서 구현한다.

   ```bash
   # 생성된 후보 id(C1 등)는 roadmap/ledger label이 아니므로 `--phase <id>`만으로는
   # /run discover가 구현할 scope/files/tests/design을 찾지 못한다(/run은 ledger 기반
   # discover). 따라서 candidate contract + (b)의 design matrix를 task brief로 전달한다.
   # 대상 repo가 ledger 전용 discover면, 먼저 그 repo ledger에 최소 슬라이스를
   # 등록하거나 IMPROVE-2의 brief 직접 전달 경로를 사용한다.
   /run "<candidate contract + locked design matrix>" --hold-before-land
   ```

   - `/run`이 collision-guard/worktree/sync/implement/verify/review/PR publish를
     소유한다. `--hold-before-land`는 **PR open까지만** 진행하고 **merge는 하지
     않는다**(게이트 2 대기).
   - **locked design을 넘기므로 `/run`의 Design Risk Gate(Step 3.5)는 재심의가
     아니라 잠긴 설계의 검증만** 수행한다(F2). `/run`이 다시 pingpong을 돌리지
     않도록 설계가 잠겨 있음을 context로 명시한다.
   - 열린 PR 번호를 누적한다(`PR_LIST`).

   > 의존성: `--hold-before-land` 모드와 batch land entrypoint(Step 7)는 `/run`의
   > 표면 추가가 필요하다(아래 "의존성" 참조). 해당 모드가 없는 repo에서는 그
   > 사실을 사용자에게 보고하고 land까지 가는 일반 `/run`으로 진행할지 묻는다 —
   > 조용히 batch HOLD 계약을 깨지 않는다.

### Step 6 — 게이트 2: batch 리뷰 → confirm

batch land는 merge(release_deploy_ops/repo_workflow authority) 결정이므로 **구조화된
operator decision request 스키마**(AGENTS.policy.md "Operator decision requests")로
묻는다 — informal "보고 후 결정" 금지. 각 후보의 **(locked design matrix + 열린 PR +
diff)를 verifiable evidence**(PR 번호/path 인용)로 담는다. **options는 land될 PR을
구체적으로 지목**한다 — vague한 `land_subset` 금지(어느 PR을 승인했는지 불명확하면
3번째 selection을 또 묻거나 미승인 PR을 land할 위험). batch가 작으면(≤4 PR) PR별
`land`/`skip`을 한 decision으로 묻고, 그보다 크면 **batch를 PR 단위(또는 ≤4 묶음)로
쪼개** 각 decision의 옵션이 land할 정확한 PR 집합을 named outcome으로 갖게 한다(policy
옵션 한도 ≤5 준수). `authority_gate`는 release/repo-workflow, `default_action`은
`proceed_safe` 금지. 승인된 PR만 land하고 미승인 PR은 사유와 함께 보고한다.

### Step 7 — 일괄 land

confirm된 PR들을 `/run`의 land entrypoint로 일괄 land한다.

```bash
/run land <pr-list>      # 또는 동등한 land 표면 (의존성 참조)
```

- land 소유권은 `/run`에 유지된다 — 스킬은 land **시점만** batch로 미룬다.
- 같은 파일/모듈 후보는 Step 4에서 이미 **별도 batch로 분리**되므로 한 batch 안에서
  순서대로 land하는 경로는 없다. 의존 batch는 앞 batch가 land된 뒤 다음 batch를 시작한다.

## 의존성

- **`/run --hold-before-land` + batch land entrypoint** (`commands/run.md`,
  `run-helper`): 현재 `/run`은 land까지 자동 진행한다. batch 워크플로우는 PR open
  후 merge를 보류했다가 게이트 2 이후 일괄 land하는 **명시적 표면**을 필요로 한다.
  이 표면이 없으면 스킬은 그 사실을 보고하고 사용자 결정을 받는다(조용한 우회 금지).
- **`pingpong-relay` / `agent-dialog`**: per-candidate 설계 심의 구동.
- **`targets.tsv`**: cross-repo 선택(없으면 현재 repo).

## Invariants

- 단계가 끝나면 사용자 입력 없이 다음 단계로 진행한다 — 단 게이트 1·2와 authority
  gate에서만 멈춘다.
- 한 후보는 commit-sized 1개로 유지한다. 커지면 후보를 쪼개 contract를 다시 만든다.
- 후보·설계 제안은 항상 관측 근거를 동반한다. 근거 없는 추상화는 제외한다.
- `/run`의 collision-guard/worktree/land 소유권을 우회하지 않는다.
- per-candidate 단계에서 agent 명의 parallel decision을 자동으로 쓰지 않는다(G3).
- 사용자에게 보이는 보고/질문은 한국어, 명령·식별자는 원문 언어.

## 비목표 (non-goals)

- 새 verify/review/land 파이프라인 재구현(=`/run` 재사용).
- 전체 repo 일괄 리팩토링(=후보당 commit-sized 1개).
- per-cycle 사용자 컨펌(=게이트 2개로 대체).
- adversarial `--auto-decision` 무인 land(=parallel decision은 sender=user, 게이트 2 사람 확인).
