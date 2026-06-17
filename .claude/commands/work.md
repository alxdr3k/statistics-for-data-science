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

Codex work must run async: the launcher returns quickly and no wall-clock timeout can kill Codex.

**Default — harness-tracked background.** Write the prompt to a file (never on argv — DEC-048), then wrap a *foreground* companion call in `Bash(run_in_background)`:

```bash
Bash(run_in_background):  node codex-companion.mjs task --cwd <worktree> --write < <prompt-file>
```

The harness tracks the job, auto-notifies the session on exit, and preserves exit code + output — so there is no manual job state to record and no supervision poller to run (DEC-051). Keep the companion in *foreground* mode (not `--background`) so its safety wrapper — sandbox, redaction, provenance, output capture — still applies; do not substitute a raw `codex exec`. Pass the prompt via a finite stdin file (`< prompt.txt`) or `--prompt-file` — **never as a `--write "<prompt>"` argv string** (DEC-048: argv leakage / context blowup); a finite stdin file also avoids the codex stdin-hang. Never wrap Codex in a foreground or timed Bash call (see Hard Rule).

**Escape hatch (rare).** Only for an in-flight job that must keep running after the Claude Code session is *fully closed* — a non-goal for normal interactive `/work`. harness-bg already survives turns, context compaction, and long runs (verified: a 32-min harness-bg job ran to completion with all heartbeats + exit code + auto-notification intact), so neither long duration, result durability (write output to a durable file/registry — harness-bg can do this), nor codex thread resume (`--resume-last`, disk-persisted, works with harness-bg) is a reason to detach. If you genuinely need session-close survival, detach via companion `--background`. That leaves harness tracking, so the global AGENTS.md "백그라운드 작업 completion 수신 보장 (backstop poller)" rules apply: record job state (id / cwd / pid / log / result / exit-marker) under `~/.claude/codex-managed/<repo-slug>/jobs/<job-id>/` (or repo-local `.codex-managed/` only if gitignored), then supervise per the next section.

## Supervision

This section applies to the **detached managed-job fallback only**. Harness-tracked background jobs (the default) need no manual supervision — the harness re-invokes the session on completion with the exit code, so there is no self-reported status to distrust.

For a detached job, Claude Code owns lifecycle supervision. Poll independent signals:

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
- substantial/ambiguous: harness-tracked background Codex job (companion foreground wrapped in `Bash(run_in_background)`; detached `--background` only for the rare must-outlive-session-close case)

After Codex completes, Claude Code reviews the result before applying, landing, or declaring the work done.
