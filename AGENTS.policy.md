# AGENTS.policy.md

Boilerplate-owned agent policy. Synced to all repos — do not edit in project repos.
Project-specific guidance belongs in `AGENTS.md`.

## Working principles

- Think before editing: state assumptions and tradeoffs when ambiguity changes the solution. Ask before unsafe guesses.
- Keep it simple: add only what the request needs. No speculative features, abstractions, configuration, or docs.
- Make surgical changes: touch only relevant files, preserve local style, and clean up only debris introduced by your change.
- Separate planning from execution: record known scope with status, but execute only ready and authorized work.
- Verify goals: turn work into checkable outcomes, run documented checks, and report any validation you could not run.

## Branch and merge workflow

All repos use the same workflow unless a repo-local emergency runbook says
otherwise for a production incident.

- `main` is the single base and release branch.
- Do not commit or push directly on `main`.
- Do not use `dev` as an integration branch for normal work.
- Start each change from an up-to-date `main` branch in a separate worktree:
  `git fetch origin main` followed by
  `git worktree add ../<repo>-<branch> -b <branch> origin/main`.
- If the branch already exists, attach it with
  `git worktree add ../<repo>-<branch> <branch>` instead of switching the
  existing `main` checkout.
- Keep the `main` checkout clean for sync, review-base checks, and post-merge
  verification. Do implementation work only in the task worktree.
- Push the task branch, open a PR to `main`, and merge with squash
  (`gh pr merge --squash --delete-branch`) after required checks and reviews
  pass.
- If squash merge is unavailable because of repository settings, stop and
  report the blocker instead of choosing another merge strategy.

## Validation

Prefer terse output flags to reduce context size:

Tests:
- pytest: `-q --tb=short`
- go test: omit `-v` (quiet by default)
- jest / vitest: `--reporter=dot` or `--silent`
- rspec: `-f p` (default)
- cargo test: `-- --quiet`

Lint / typecheck / build:
- eslint: `--format compact`
- rubocop: `--format simple`
- tsc: `--noEmit --pretty false`

Package installs:
- npm: `npm ci --silent`
- yarn: `yarn install --silent`
- bundle: `bundle install --quiet`
- pip: `pip install -q`
- cargo: `cargo fetch -q`

Do not read generated or lock files (`package-lock.json`, `Gemfile.lock`, `yarn.lock`, `*.generated.*`, `schema.rb`, etc.) — they are not source of truth and waste context.

**Exception (round 68):** the cross-document invariant tracking artifacts in `docs/_generated/` (`scope_tree.yaml`, `term_usage.yaml`, `effective_invariant_policy.yaml`) MUST be read before authoring Q / DEC / ADR docs — see the "Cross-document invariant tracking" section below. They are not source of truth either, but they aggregate scope/term/policy state across the repo in a form the validator depends on for coverage cross-checks. Treat them as required context, not as authoritative facts: if they conflict with the underlying Q/DEC/ADR/glossary files, the source files win and the artifacts should be regenerated (`bun run scripts/validate_invariants.ts --regenerate`).

Do not invent commands.

If validation cannot be run, report why.

## Operator decision requests

When an agent needs the operator (the human supervising the session) to pick
between options or approve a non-trivial action, the request body MUST follow
this schema. **This section is the canonical runtime contract** — every agent
enforces the rules from this file alone. `docs/adr/0003-operator-decision-request-enforcement.md`
(ADR-0003) is the source-repo design record present in repos that carry the
boilerplate's numbered-docs structure; universal-profile adopter repos
(AGENTS.policy.md + CLAUDE.md only, no numbered docs) enforce the contract
directly from this section without needing ADR-0003. If this section ever
disagrees with ADR-0003, this section wins for runtime; ADR-0003 should be
updated to match in the source repo.

### Authority gate (run first, before drafting the request body)

Before composing a request, classify the decision against the gate. If it
matches **any** of the 10 categories below, the operator MUST be asked
(`authority_gate.requires_operator = true`):

1. `destructive_or_irreversible` — DROP/truncate with data loss, force-push,
   permanent deletion outside the repo; production data migrations, bulk
   updates, backfills, reprocessing, and any durable state mutation with
   corruption or duplication risk
2. `security_privacy` — auth/authz, permission boundaries, CORS/CSP, crypto,
   retention for user identifiers
3. `secrets_credentials` — API key, env var, secret store, credential rotation
4. `cost_billing` — paid resource scale, new vendor, quota raise
5. `product_scope` — PRD/HLD intent, accepted requirements
6. `legal_compliance` — license, ToS, HIPAA/GDPR, retention/deletion promise
7. `architecture_dependencies` — ADR-worthy decisions, module boundary,
   significant dependency/runtime
8. `third_party_external_side_effects` — new external API, publish, real
   notification/email/webhook
9. `release_deploy_ops` — production availability, deploy timing, rollback,
   required checks
10. `repo_workflow_history` — branch protection, shared branch deletion, merge
    strategy, force-push, auto-merge

If the decision matches **none** of the 10 categories AND falls under
must-not-ask, do not ask — act and report. Asking on must-not-ask items
trains the operator to approve reflexively (approval fatigue = security bug).

### Must-not-ask categories (proceed and report)

- typo / formatting fixes within touched files
- tests for behavior already requested or implemented
- lint / typecheck fixes preserving behavior
- small refactors required by local pattern and covered by tests
- docs updates triggered by code changes under existing policy
- read-only investigation and command output summarization
- creating issues for unresolved findings when policy says to stop
- reversible local cleanup
- implementing a phase/slice from an accepted ADR — ALL of the following
  must hold:
  1. the ADR has a **fenced YAML block** in its `Implementation phases` (or
     equivalent) section with a `phases:` map containing the named phase
  2. the phase entry has `applies_must_not_ask: true` (otherwise the 9th
     never applies; e.g. PHASE-5-style global config phases declare
     `applies_must_not_ask: false`)
  3. the phase entry's `fresh_operator_decision_required: false` OR a
     decision request for this phase has already been answered in the
     current session
  4. every changed file's repo-relative path matches at least one glob in
     that phase's `touched_paths` (POSIX shell glob: `*` single segment,
     `**` zero-or-more segments, `{a,b}` brace expansion; empty `touched_paths`
     means must-not-ask never applies)

  Prose / backtick path lists in ADR body text are NOT a substitute for the
  fenced YAML block. If the block is missing or malformed, this exception
  does NOT apply and the agent escalates.

  This exception is **subordinate to the authority gate**: if implementation
  surfaces any decision matching one of the 10 ask-categories that the
  ADR's accepted text did not explicitly pre-resolve (named in the Decision
  section, an invariant, or a precondition), re-apply the gate and ask. The
  ADR's acceptance pre-authorizes only what its body explicitly resolved —
  not arbitrary downstream choices that happen to live under its scope

### Request body schema

| Field | Required | Notes |
|---|---|---|
| `title` | yes | one line |
| `bluf` | yes | sender's own recommendation (1 line) + core reason (1 line). MUST NOT embed another sender's recommendation |
| `decision_question` | yes | exactly one sentence ending in `?` or imperative ask |
| `why_now` | yes | current blocker + delay impact, 2-3 sentences |
| `options[]` | yes | cardinality rule: **length 1 hard-rejected** (approve/reject decisions MUST be modelled as two explicit options, e.g. `approve` and `reject_or_wait`); **length 2 or 3 is the default allowed range**; **length 4 or 5 is allowed only when the body includes `allow_extra_options_reason: <string, ≥ 20 chars, ≤ 240 chars, explains why merging or trimming would harm the decision>`**; **length 6+ hard-rejected unconditionally** (split into separate decision requests instead). Each entry: `{id, label, outcome, tradeoff_or_risk}` — all four sub-fields required per option |
| `recommendation` | yes | option id, OR `no_recommendation_reason` |
| `reversibility` | yes | enum `reversible \| partly_reversible \| irreversible` + `rollback_path` (for reversible/partly) or `irreversible_reason` |
| `default_action` | yes | enum `proceed_safe \| wait \| do_read_only_only \| create_issue`. `proceed_safe` forbidden when `authority_gate.requires_operator = true` |
| `evidence[]` | yes | array with at least one entry. Base entry shape: `{type: path\|pr\|issue\|adr\|command\|url\|inference, value, confidence?, limitation?}`. **`type: inference`** REQUIRES `confidence` + `limitation`. **`type: command`** is informational only — it documents what was run but cannot authenticate execution from doc text alone; **`command` evidence does NOT satisfy the `authority_gate.requires_operator = true` gate** (cite the resulting file with `path` evidence if the command produced one). When `authority_gate.requires_operator = true`, at least one entry MUST be a verifiable non-`inference` AND non-`command` citation: `path` / `pr` / `issue` / `adr` / `url`. **Every non-`inference` entry MUST be verifiable in the current repo context**: `path` resolves to existing file (line anchors valid), `adr` resolves to existing `docs/adr/<num>-*.md` file (in universal-profile repos without `docs/adr/`, `type: adr` is REJECTED), `pr`/`issue` use `#<num>` or URL form, `command` is shape-valid command string (informational only), `url` is well-formed `http(s)://`. PHASE-3 validator may introduce authenticated command transcripts (wrapper-produced with cwd / timestamp / exit_code / output digest) later; until then, command evidence is non-gating. See "Hard reject vs soft warning" below for full verification rules |
| `out_of_scope` | yes | decisions intentionally deferred + rabbit-hole traps the agent might fall into |
| `authority_gate` | yes | `{category, self_decision_allowed, requires_operator, reason}` |

### Word budget

Counted on rendered markdown:

- **warn** at ≥ 450 words
- **reject** at ≥ 700 words unless body has `high_risk: true`
- **hard reject** at ≥ 900 words unconditionally

### Hard reject vs soft warning

This table is the deterministic enforcement contract that PHASE-2/3
validators MUST implement, sourced from this file. ADR-0003 records the
same table as the source-repo design history; if the two ever diverge,
**this section wins for runtime** and ADR-0003 must be updated to match.

Hard reject (regex / schema, deterministic):

- all required fields present (see schema table above)
- exactly one `decision_question`
- `options[]` cardinality: length 1 is hard-rejected (approve/reject MUST be
  two explicit options); length 2 or 3 is the default range; length 4 or 5
  is allowed only with `allow_extra_options_reason` (≥ 20 chars, ≤ 240
  chars); length 6+ is hard-rejected unconditionally
- each option has `id` + `label` + `outcome` + `tradeoff_or_risk` (all four
  sub-fields non-empty)
- `recommendation` references one of the option `id`s, OR
  `no_recommendation_reason` is present (string, ≥ 20 chars)
- `reversibility` is one of `reversible | partly_reversible | irreversible`;
  if `reversible` or `partly_reversible`, `rollback_path` is non-empty; if
  `irreversible`, `irreversible_reason` is non-empty
- `default_action` is one of `proceed_safe | wait | do_read_only_only |
  create_issue`; `proceed_safe` is rejected when
  `authority_gate.requires_operator = true`
- `evidence[]` has at least one entry; each entry has a `type` from
  `{path, pr, issue, adr, command, url, inference}` and a non-empty `value`;
  for `type: inference`, both `confidence` and `limitation` are required
- when `authority_gate.requires_operator = true`, `evidence[]` has at least
  one verifiable non-`inference` AND non-`command` entry (`path` / `pr` /
  `issue` / `adr` / `url`). `command` evidence is non-gating until PHASE-3
  introduces an authenticated transcript format
- **every non-`inference` evidence entry MUST be verifiable in the current
  repo context** (no dangling citations):
  - `path` — file MUST exist in the repo; line anchor (`path:N` or
    `path:N-M`) MUST point to valid line range
  - `adr` — value MUST resolve to an existing file matching
    `docs/adr/<number>-*.md` in the current repo. In universal-profile
    repos (no `docs/adr/` directory), `type: adr` evidence is REJECTED
    — agents MUST cite a different verifiable type or use `inference`
  - `pr` — value MUST be `#<number>` or full URL with numeric PR id;
    validator may verify via `gh pr view` when network available
  - `issue` — value MUST be `#<number>` or full URL with numeric issue
    id; validator may verify via `gh issue view` when network available
  - `command` — `value` MUST be a runnable command string (validator
    checks shape, does not execute). **`command` evidence is informational
    only and does NOT satisfy the `requires_operator=true` gate** — doc
    text cannot authenticate that the command actually ran with the
    claimed result. To cite execution, use `path` evidence pointing at
    the captured output file (which IS verified to exist). PHASE-3
    validator may later introduce a wrapper-produced transcript format
    (cwd / timestamp / exit_code / output digest) that re-enables
    `command` gating; until then, command evidence is non-gating
  - `url` — value MUST be a well-formed `http(s)://` URL
- word budget thresholds (warn ≥ 450, reject ≥ 700 unless `high_risk: true`,
  hard reject ≥ 900)
- `authority_gate` shape: `category` is one of the 10 ask-categories above,
  `self_decision_allowed` and `requires_operator` are booleans, `reason` is
  a non-empty string
- **authority_gate consistency**: whenever `category` is one of the 10
  ask-categories, `requires_operator` MUST be `true`, `self_decision_allowed`
  MUST be `false`, and `default_action` MUST NOT be `proceed_safe`. Validator
  implementations SHOULD derive `requires_operator` from `category` rather
  than trusting agent-supplied input — the booleans exist for display and
  audit, not as an escape hatch from the category enum

Soft warning (LLM-judge, advisory only):

- BLUF substantiveness (real recommendation vs "not sure")
- option distinctness and viability
- evidence relevance (path existence is hard; persuasive power is soft)
- risk severity classification

### Anti-patterns (do not ship)

1. **Dual labelling** (α/β + A/B at once) — pick one label system per request
2. **Embedding another sender's recommendation in BLUF** — use sender-own
   recommendation; cite others as "X recommends Y; I independently agree/disagree
   because Z"
3. **Irrelevant identity fact** — model branding, agent ID, or other facts
   unrelated to the reasoning
4. **Inference stated as evidence** — anything inferred MUST use
   `evidence: {type: inference, confidence, limitation}` rather than a bare
   path/PR/URL citation
5. **Mixing operator-facing body with dogfood/meta evaluation in one block** —
   keep meta as a separate fold/link

### Enforcement (5-defense stack)

The intended primary defense is the dev-cycle helper structured path (see
`.codex/skills/dev-cycle/SKILL.md` finish-cycle-json) — it becomes the
active primary once ADR-0003 PHASE-2 lands; until then it is planned, not
implemented. Until PHASE-2 ships, the canonical rule in this section (layer
2) and the agent's self-review checkpoint (layer 5) carry the load.
Layers 3-4 (agent-dialog kind, optional Claude Code Stop hook) are tracked
in ADR-0003 as later phases.

Glossary term files for `operator_decision_request`, `authority_gate`,
`must_not_ask_category`, and `defense_in_depth_stack` provide supporting
term ownership in repos that carry the boilerplate's numbered-docs structure
(under `docs/glossary/`). The runtime contract above is enforced from this
section alone — absent glossary files in universal-profile repos do NOT
weaken enforcement.

## Companion policy files

If this repo has boilerplate-structure docs, also read when present:
- `docs/04_IMPLEMENTATION_PLAN.policy.md` — feedback triage policy for the roadmap
- `docs/DOCUMENTATION.policy.md` — doc update trigger policy

## Project mode stop rule

This rule applies only to repos that use the boilerplate documentation
structure — specifically, repos that have `docs/context/current-state.md`.
Universal-profile repos that adopt only `AGENTS.policy.md` and `CLAUDE.md`
without the numbered docs are exempt from the rule because they have no
canonical place to record the mode. If `docs/context/current-state.md`
does not exist in this repo, treat the entire stop rule below as not
applicable and continue with normal work.

The boilerplate operates in two project modes — `greenfield` and `adoption`.
See `docs/DOCUMENTATION.policy.md` "Project mode" for mode definitions and
adoption work obligations. The mode is recorded in
`docs/context/current-state.md` under the `Project mode` block.

The `mode` value must be exactly `greenfield` or `adoption`. If the block
is missing, the value is `unset`, or the value is anything else, stop and
ask the project owner before any normal implementation work — do not
assume greenfield by default and do not skip to coding. Resolving the mode
is a prerequisite for implementation work, not a backfill-only checkpoint.
Once the mode is `adoption`, run the adoption work sections in
`docs/DOCUMENTATION.md` (and complete the relevant backfill) before
implementation work that depends on REQ/NFR/AC/TEST/TRACE state.

Exemption: this rule polices project implementation work in repos that
have copied this boilerplate. The boilerplate source repo (where the docs
tree is the canonical template, not a project's state) is exempt because
its work is template maintenance — editing policies, schemas, validators,
sync scripts, and examples — not project implementation against
REQ/NFR/AC/TEST/TRACE state. If you are unsure whether your work counts as
project implementation, treat it as implementation and resolve mode first.
File-state markers (`Status: template.`, `mode: unset`) are not
exemptions; they are the exact states the rule is meant to police.

### Reachability precondition

This rule lives in a synced policy file, so it only fires for agents that
actually read `AGENTS.policy.md`. Existing adopter repos must ensure their
project-owned `AGENTS.md` references this file (Claude Code receives it
via the `@AGENTS.policy.md` import in `CLAUDE.md`; agents that follow
`AGENTS.md` directly need a corresponding "see `AGENTS.policy.md`" line in
the "Companion policy files" reading order or equivalent). Adopter repos
that synced policy without first running
`boilerplate-sync-docs.sh refs <repo>` (or equivalent) may receive the
file without the rule becoming reachable from the agent entrypoint;
running `refs` once resolves this and is a precondition for the stop rule
to fire as designed.

### One-time migration for existing adopter repos

Repos that copied the boilerplate before this rule landed will receive the
rule via policy sync but will not have the `Project mode` block in their
project-owned `docs/context/current-state.md`. The first time the rule
fires after sync, resolve it once by adding the block below to
`docs/context/current-state.md` (place it under the file's main heading or
near the top of the project state) and setting `mode` to the correct
value. This is a one-time migration step, not a recurring blocker.

```markdown
## Project mode

- mode: unset  (set to exactly `greenfield` or `adoption`; see `docs/DOCUMENTATION.policy.md` Project mode)
- adopted on: unset  (set to `YYYY-MM-DD` or `n/a` for greenfield)
- adoption notes: unset  (link to migration tracking slice or set to `n/a`)
```

After the block exists with a valid `mode`, the rule moves from "block
absent" to its normal enforcement and only fires again if mode becomes
`unset` or invalid.

## Cross-document invariant tracking

If this repo uses `docs/templates/relation_enum.yaml` (boilerplate-owned invariant
tracking system; see `docs/adr/0002-invariant-tracking-system.md`), Q / DEC / ADR
authoring has additional read obligations.

### Before writing a new Q / DEC / ADR

Always read the following before populating `touches[]` / `term_effects[]` /
`scope` / `invariants[]` / `defines[]`:

1. **Generated artifacts** in `docs/_generated/` (regenerate first if stale —
   `bun run scripts/validate_invariants.ts --regenerate`):
   - `scope_tree.yaml` — namespace tree built from existing ADR scope.in/out
   - `term_usage.yaml` — glossary term usage map
   - `effective_invariant_policy.yaml` — boilerplate base + .local merged schema

2. **Upstream Q / DEC / ADR** referenced by `touches[].id` — read each one's
   `scope`, `invariants[]`, `preconditions[]`, `defines[]`. If your new doc
   extends or challenges any of these, encode the relation explicitly in
   `touches[]` (see `docs/templates/relation_enum.yaml` for value-specific
   payload requirements).

3. **Glossary term files** for any term you mention. If you change a term's
   attribute (e.g., add a new `release_paths` value), record it as a
   `term_effects[]` entry — not just in body prose. Body-only term changes
   create silent drift (Case 2).

### After writing

- `reviewed_terms[]` and `reviewed_scopes[]`: list every glossary term and every
  namespace your body cites. Validator cross-checks; coverage gaps become
  warnings.
- `invariant_review.status`: set `pending` for new docs. Foreground runs of
  `bun run scripts/validate_invariants.ts --write-warnings` will populate
  `unresolved_warnings[]` automatically.
- Do NOT run `--write-warnings` from CI or background — that mode is foreground
  only (CI is annotation-only, never modifies docs).

### Why these obligations exist

LLMs miss subtle cross-document dependencies when scope/invariant/term details
live only in body prose. Two failure cases drove this design:

- **Scope creep (Case 1)**: a new Q silently extends an ADR's scope, breaking the
  ADR's premise (e.g., cheap-model recommendation that depended on `control-plane`
  scope). Detected via `touches[].relation: extends_scope` payload + capability
  term `forbidden_paths` cross-check.
- **Glossary drift (Case 2)**: a DEC body changes a glossary term's attribute,
  but the term file is untouched. Detected via mandatory `term_effects[]`
  declaration.

The validator runs warning-level only; it never blocks merges. The validity
guarantee is built from frontmatter `reviewed_*` artifacts (verifiable) plus
generated coverage cross-checks — not from agent self-reports (unverifiable).

## Scheduled / wake-up agent execution

Scheduled wake-ups, retry timers, and any agent that fires outside the
operator's interactive turn run with **degraded context**. The full
conversation, current intent, and prior decisions that the interactive
agent had are not available to the wake-up. Treat the wake-up as a
disposable status probe, not as a continuation of the original task.

**Permitted actions for scheduled / wake-up agents:**

- Re-run an exact previously-issued command verbatim (e.g. retry the
  same `gh pr create` with the same title/body when a rate limit
  resolves).
- Poll status of an external system (`gh pr view --json state`, CI
  workflow status, deploy health probe).
- Read-only inspection that does not mutate the repo or the upstream:
  fetching, viewing logs, checking lock files.
- Report findings back to the next interactive turn so the operator
  can decide what to do next.

**Forbidden actions for scheduled / wake-up agents:**

- Implementing code: writing new files, refactoring, generating PR
  bodies, designing fixtures or runners, choosing patterns.
- Creating PRs, branches, or worktrees from a wake-up context (as
  opposed to retrying an already-prepared `gh pr create` invocation).
- Mutating the `main` or default branch worktree: commits, pushes,
  stash drops, branch deletions, rebases, force-pushes.
- Editing adopter-facing template documents
  (`docs/04_IMPLEMENTATION_PLAN.md`, `docs/01_PRD.md`,
  `docs/02_HLD.md`, `docs/06_ACCEPTANCE_TESTS.md`, and other
  boilerplate templates that downstream repos copy).
- "Picking up where the previous turn left off" by inferring intent.
  If a non-trivial decision is needed, defer to the next interactive
  turn.

**Why these limits:** a wake-up agent has no way to verify that the
operator still wants the originally-intended outcome, that an
interactive agent in a parallel worktree is not already doing the
same work (worse, in a different design), or that the surrounding
context has not shifted. The 2026-05-17 incident in this repo
(`#17`) saw a ScheduleWakeup agent implement a parallel PR-2 in the
`main` worktree with a different design AND inject a `DOC-GOV`
track row into `docs/04_IMPLEMENTATION_PLAN.md`, the canonical
adopter-facing template. The interactive PR-2 had already landed
(`#16`) with the correct design; the parallel work had to be
stashed, dropped, and the IMPL_PLAN pollution reverted.

**Prompt-construction rule:** when constructing a `ScheduleWakeup`
or equivalent prompt, restrict the requested action to a single
verb in the Permitted list above (e.g. "re-run", "poll", "report").
Do not include "implement", "create", "design", "fix", "refactor",
"continue", or any other action verb that would invite the wake-up
agent to perform new work. If the wake-up agent receives a prompt
that crosses into the Forbidden list, it MUST stop and surface the
ambiguity rather than proceed.

`.claude/commands/codex-loop.md` describes the codex review wait
loop, which is the canonical "polling + retry" wake-up shape and
honours this policy by design (foreground helper, no background
mutation, exit codes drive interactive turns). Other scheduled
agents must follow the same shape.

## Extraction tasks

When asked to prepare external knowledge-base extraction (e.g. for a personal
`second-brain`-style vault, team wiki, or other curated knowledge system):

1. Read the project's extraction template (path defined in `AGENTS.md`) — it is canonical.
2. Read the relevant retrospective / discovery / Q / DEC / ADR source.
3. Prepare an extraction candidate table with `Kind` and `Action` from the template's allowed values.
4. Distinguish candidate vs promoted — every row is a candidate. Do not claim a candidate has been promoted unless the target knowledge base has accepted it.
5. Do not promote raw transcript, stale drafts, rejected recommendations, or project-only implementation details. List them under `Do not promote` with rationale.
6. `Do not promote` must not be left blank. Use `None — reviewed` only after explicit review.
7. Preserve source anchors (repo / path / commit / PR / ADR / DEC / Q). If unknown, write `anchor missing`. Do not fabricate.
8. Report results as Created / Modified / Promoted / Dropped (omit empty groups).
9. Do not modify the external knowledge base unless explicitly asked. Boilerplate prepares the packet; the target knowledge base owns final placement, schema, and validation.
