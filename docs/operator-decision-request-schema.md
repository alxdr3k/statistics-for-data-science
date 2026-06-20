# Operator decision request — body schema and enforcement contract

Boilerplate-owned. Synced verbatim into adopter repos alongside `AGENTS.policy.md`
— do not edit in project repos.

This file is the deterministic contract for **how** an operator decision request
is shaped and validated. **Whether** to ask — the authority gate's 10 categories
and the must-not-ask categories — lives in `AGENTS.policy.md` under "Operator
decision requests"; read that first. When the authority gate says to ask, an
operator decision request **MUST** be generated through the schema below; a
request not produced through it is **invalid** (treat as hard reject).

**This file plus the `AGENTS.policy.md` "Operator decision requests" section are
the canonical runtime contract.** If either ever disagrees with
`docs/adr/0003-operator-decision-request-enforcement.md` (ADR-0003), they win for
runtime; ADR-0003 should be updated to match in the source repo.

## Request body schema

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

## Word budget

Counted on rendered markdown:

- **warn** at ≥ 450 words
- **reject** at ≥ 700 words unless body has `high_risk: true`
- **hard reject** at ≥ 900 words unconditionally

## Hard reject vs soft warning

This table is the deterministic enforcement contract that PHASE-2/3
validators MUST implement, sourced from this file. ADR-0003 records the
same table as the source-repo design history; if the two ever diverge,
**this file wins for runtime** and ADR-0003 must be updated to match.

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
- `authority_gate` shape: `category` is one of the 10 ask-categories in
  `AGENTS.policy.md`, `self_decision_allowed` and `requires_operator` are
  booleans, `reason` is a non-empty string
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

## Anti-patterns (do not ship)

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

## Enforcement (5-defense stack)

The intended primary defense is the dev-cycle helper structured path (see
`.codex/skills/dev-cycle/SKILL.md` finish-cycle-json) — it becomes the
active primary once ADR-0003 PHASE-2 lands; until then it is planned, not
implemented. Until PHASE-2 ships, the canonical rule (the `AGENTS.policy.md`
authority gate plus the schema in this file, layer 2) and the agent's
self-review checkpoint (layer 5) carry the load. Layers 3-4 (agent-dialog
kind, optional Claude Code Stop hook) are tracked in ADR-0003 as later phases.

Glossary term files for `operator_decision_request`, `authority_gate`,
`must_not_ask_category`, and `defense_in_depth_stack` provide supporting
term ownership in repos that carry the boilerplate's numbered-docs structure
(under `docs/glossary/`). The runtime contract above is enforced from this
file plus the `AGENTS.policy.md` authority gate alone — absent glossary files
in universal-profile repos do NOT weaken enforcement.
