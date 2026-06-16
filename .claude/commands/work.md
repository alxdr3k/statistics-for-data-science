---
name: work
description: Route work between Claude Code direct execution and managed Codex delegation without Codex wall-clock timeouts.
argument-hint: "[task brief]"
agents: claude
---

# Work

Use this command before delegating substantial design, implementation, investigation, or review work to Codex.

Claude Code is the harness, reviewer, orchestrator, and direct executor for small work.
Codex is a worker for substantial work only.

Task brief from the invocation:

```text
$ARGUMENTS
```

## Route First

Before launching Codex, decide whether the handoff is worth it.

Claude Code handles the work directly when it is:

- frontend work: UI, styling, components, client-side state, browser interaction, responsive layout, visual QA, or accessibility
- 1-2 files, local, mechanical, or low ambiguity
- docs wording, typo fixes, config tweaks, small bug fixes, or simple refactors
- mostly search/edit/test
- faster to do than to write a precise Codex handoff prompt

Do not delegate frontend work to Codex, even when it is broad, ambiguous, design-heavy, or explicitly involves multiple files.
Claude Code owns frontend implementation and frontend QA directly. This frontend rule has priority over the Codex criteria below.

Use Codex only when the work is:

- broad, multi-file, ambiguous, or design-heavy
- substantial enough that independent implementation reasoning is useful
- complex investigation or root-cause analysis
- architecture, protocol, lifecycle, or workflow design
- explicitly requested by the user

If the task becomes smaller after inspection, finish it directly. If a direct task becomes larger than expected,
create a managed Codex job with a compact handoff brief.

## Hard Rule

Never run Codex model work as one blocking timed Bash, Agent, or Hook call.

Do not wrap Codex with wall-clock timeout behavior:

- Bash tool `timeout: <ms>` around Codex model work
- `timeout`, `gtimeout`, `perl alarm`, or watchdog kill loops
- `CODEX_*_TIMEOUT`, `RELAY_TIMEOUT_SECS`, or equivalent env limits
- hook or subagent paths that can kill Codex after elapsed time
- legacy gstack `/codex` timeout wrappers for real Codex work

This applies to:

- `codex`
- `codex exec`
- `codex review`
- `codex app-server`
- `codex-companion.mjs task`
- `codex-companion.mjs review`
- `codex-companion.mjs adversarial-review`

If the only available path is a fixed-timeout Codex call, stop and report that the Codex lifecycle path is unsafe.
Do not fall back to a timed run.

## Managed Lifecycle

Codex work must run as a managed background job. The launcher must return quickly after starting Codex.
The long-running Codex process must not be the direct child of a Claude Code Bash call that stays open until Codex finishes.

Record job state before reporting launch:

- job id
- cwd
- prompt or request file
- pid
- log file
- result file
- exit marker path
- start time

Default state root:

```bash
~/.claude/codex-managed/<repo-slug>/jobs/<job-id>/
```

Use repo-local state only when the target repo is trusted and writable, and only after adding `.codex-managed/`
to `.git/info/exclude` before creating any job files:

```bash
.codex-managed/jobs/<job-id>/
```

If the exclude cannot be verified, use the default user-local state root.

## Supervision

Claude Code owns lifecycle supervision. Poll independent signals:

- pid liveness: `kill -0 <pid>`
- progress: log/result file mtime
- terminal marker: `COMPLETED`, `FAILED`, `DEAD`, `STALLED`, or `CANCELLED`

Do not trust a self-reported `status: running` without pid/progress cross-checks.

Polling and wakeup jobs may have limits for reporting or resuming Claude Code, but those limits must not terminate Codex.
Elapsed wall-clock time alone is not a valid reason to kill Codex.

## Cancellation

Terminate Codex only when:

- the user explicitly cancels
- the job is superseded and the reason is recorded
- safety, auth, permission, or destructive-state policy requires stopping
- the pid is already dead and cleanup is being performed

Distinguish cancellation and failure in state. Do not report a dead or stalled job as completed.

## Handoff Brief

Keep Codex prompts compact and execution-oriented:

- objective
- relevant files or commands already inspected
- constraints and non-goals
- expected output shape
- whether file edits are allowed
- validation expectations

Do not paste large context by default. Include paths and focused excerpts unless the full text is required.

## User Interaction

Do not ask the user whether Codex should run foreground or background. Choose the lane:

- small/simple: Claude Code direct
- frontend: Claude Code direct
- substantial/ambiguous: managed Codex background job

After Codex completes, Claude Code reviews the result before applying, landing, or declaring the work done.
