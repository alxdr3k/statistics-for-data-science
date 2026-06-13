#!/usr/bin/env bash
# Cross-agent /pingpong file-first session helper.
# XAR-1A.1 thin MVP: init / read / list / transcript and write --kind
# request|response|decision. Sessions live under AGENT_DIALOG_HOME and use a
# PID-based write lock with stale recovery. note/relay and the full validation
# chain land in XAR-1A.2.

set -euo pipefail
umask 077

AGENT_DIALOG_HOME="${AGENT_DIALOG_HOME:-$HOME/.agent-dialog}"
SESSIONS_DIR="$AGENT_DIALOG_HOME/sessions"
SCHEMA_VERSION="agent-dialog-file-v1"
WARNINGS_TEXT=""

die() {
  local code="$1"; shift
  printf 'agent-dialog: %s\n' "$*" >&2
  exit "$code"
}

add_warning() {
  local code="$1" message="$2"
  WARNINGS_TEXT="${WARNINGS_TEXT}${code}"$'\t'"${message}"$'\n'
}

emit_warnings_stderr() {
  [[ -n "$WARNINGS_TEXT" ]] || return 0
  local code message
  while IFS=$'\t' read -r code message; do
    [[ -n "$code" ]] || continue
    printf 'WARN: %s: %s\n' "$code" "$message" >&2
  done <<<"$WARNINGS_TEXT"
}

warnings_json() {
  if [[ -z "$WARNINGS_TEXT" ]]; then
    printf '[]'
    return 0
  fi
  printf '%s' "$WARNINGS_TEXT" | jq -R -s -c '
    split("\n")
    | map(select(length > 0) | split("\t") | {code: .[0], message: .[1]})
  '
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 4 "missing required command: $1"
}

usage() {
  cat <<'EOF'
usage: agent-dialog.sh <subcommand> [options]

Subcommands:
  init        --initiator codex|claude --topic <text> [--repo <path>]
              [--dialogue-mode adversarial_dialogue|parallel_review] [--json]
              (default dialogue mode: parallel_review)
  write       --session <id> --kind request|response|decision|note
              --sender codex|claude|user [--recipient <agent>]
              [--parent <message_id>] --body-file <path> [--json]
  read        --session <id> [--message <id>] [--json]
  list        [--session <id>] [--json]
  transcript  --session <id>
  abandon     --session <id> [--reason <text>] [--json]
  compose-context --session <id> [--from-decision <message_id>] [--json]
  cleanup     --session <id> [--force] [--json]
  whose-turn  --session <id> [--json]
  watch       --session <id> --agent codex|claude [--interval <sec>]
              [--timeout <sec>] [--notify desktop] [--json]

Note kinds:
  request     initiator's request body
  response    reviewer's response body (+ optional findings/convergence)
  decision    initiator's disposition body (+ next_action, session_close)
  note        operator-supplemental context; sender=user only; ignored by
              protocol turn/round/finding-coverage gates

Storage: ${AGENT_DIALOG_HOME:-$HOME/.agent-dialog}/sessions/<session_id>/
EOF
}

gen_session_id() {
  # Long random suffix (16 hex) plus second-granularity timestamp. With this
  # entropy a second-bucket collision is below ~2^-32, but cmd_init still
  # treats the directory as authoritative truth via mkdir-without-`-p`.
  local ts rand
  ts="$(date -u +%Y%m%d-%H%M%S)"
  rand="$(LC_ALL=C head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)"
  printf '%s-%s\n' "$ts" "$rand"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- Lock handling ----------------------------------------------------------

acquire_lock() {
  # Symlink-based lock with recovery-gated stale removal.
  #
  # `ln -s $$ lockfile` collapses lock acquisition and owner-PID recording
  # into one atomic syscall. Two racers cannot both create the lock.
  #
  # Stale recovery is the tricky part. The previous (pre-XAR-1A.2c.d)
  # design used an atomic-rename salvage: `mv $lockfile $salvage`, then
  # readlink-verify the salvaged entry, then put it back if the salvaged
  # target had become live. Codex review 2026-05-27 (round 4) flagged
  # a 3-way race in that approach: writer A salvages the dead lock and
  # acquires a fresh live lock; writer B (which already read the old
  # dead PID before A's recovery) reaches its own `mv` and renames A's
  # live lock into B's salvage path; while B is in the readlink-and-
  # putback window, writer C does `ln -s $lockfile` and acquires.
  # A and C now both believe they hold the lock, since A has no way
  # to observe that its symlink was moved out from under it.
  #
  # Fix (XAR-1A.2c.d): serialize stale removal under a separate
  # recovery lock at `$lockfile.recovery`. While we hold the recovery
  # lock, no other writer can rm the main lockfile (they would need
  # the same recovery lock first), so reading the main lockfile's
  # target and removing it become effectively atomic from the
  # perspective of other writers. The 3-way race is closed: B's
  # attempt to remove A's fresh live lock cannot happen because B is
  # blocked at the recovery lock until A finishes its rm and releases.
  # When B finally proceeds, B re-reads the lockfile, sees A's live
  # PID, and dies cleanly with `held by live PID`.
  #
  # The recovery lock itself can become stale (process dies mid-
  # recovery). Treat it symmetrically: a live recovery holder gives
  # exit code 5 "recovery in progress"; a dead recovery holder is
  # cleaned with rm and we retry. Recovery is short-lived (one
  # readlink + one rm), so the chance of a stuck recovery lock is
  # vanishingly small.
  #
  # The exit trap re-checks ownership before removing the main lock —
  # if some later process took the lock (after our PID died or the
  # lock was released elsewhere), we must not delete their live lock.
  local sdir="$1" lockfile="$sdir/.write.lock" recovery="$sdir/.write.recovery"
  # Install ownership-checked cleanup early so that *any* exit path
  # — normal, ERR via `set -e`, INT, TERM — releases the recovery
  # lock if we are mid-recovery and the main lock if we are holding
  # it. Codex review 2026-05-27 round 8 flagged that the previous
  # design only set the EXIT trap after a successful `ln -s` on the
  # main lock, leaving an interrupted recovery (SIGTERM, ERR, helper
  # `die` between recovery acquisition and recovery rm) to strand
  # the session in the stale-recovery diagnostic path.
  #
  # SIGKILL still bypasses this — no shell-only primitive can survive
  # SIGKILL during a half-completed recovery — but every reachable
  # bash-level termination path now runs `_release_owned_locks`.
  _LOCK_TRAP_LOCKFILE="$lockfile"
  _LOCK_TRAP_RECOVERY="$recovery"
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"' EXIT
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"; trap - INT; kill -INT $$' INT
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"; trap - TERM; kill -TERM $$' TERM
  while true; do
    local ln_err
    ln_err="$(ln -s "$$" "$lockfile" 2>&1)" && {
      # Opportunistic stale-recovery cleanup. Codex review
      # 2026-05-27 round 9: when a previous recovery process was
      # SIGKILL'd between `rm lockfile` and `rm recovery`, the main
      # lockfile is gone (so our `ln -s` just succeeded) but the
      # recovery symlink is left behind pointing at a dead PID.
      # Without this cleanup the next stale-main-lock recovery
      # would hit the manual-cleanup diagnostic. We hold the live
      # main lock, so no other writer can be inside the recovery
      # critical section right now — they would die on our PID at
      # the live-lock check before reaching recovery. That makes
      # `rm $recovery` safe under our exclusive ownership, with
      # one nuance: another writer's recovery may be mid-flight
      # right at this instant (they acquired recovery while the
      # main lock was still stale, then we won the race to claim
      # main after they rm'd lockfile). Skip the cleanup when the
      # recovery holder is still a live PID — they own that file.
      local _rpid_after
      _rpid_after="$(readlink "$recovery" 2>/dev/null || true)"
      if [[ -n "$_rpid_after" ]] && ! _pid_is_live "$_rpid_after"; then
        rm -f "$recovery"
      fi
      return 0
    }

    # `ln -s` failed. The loop below assumes the failure was EEXIST
    # (lockfile already present — contention) and goes through live-PID
    # rejection or recovery-gated cleanup. If the failure was for a
    # different reason — sandbox EACCES, read-only fs, ENOSPC, ENOENT
    # — no lockfile was ever created, `readlink` returns empty, the
    # live-PID check is skipped, and the loop must NOT spin forever
    # (observed under Codex sandbox writing into $HOME/.agent-dialog).
    #
    # An absent lockfile after `ln -s` failure has two valid causes:
    #   (a) Real write failure — directory is unwritable so the symlink
    #       was never created.
    #   (b) Race — `ln -s` failed because the lockfile existed at the
    #       syscall, but another writer's recovery removed it before
    #       we reached this check.
    # Probe with a symlink (the exact syscall that drives lock creation)
    # to distinguish: success → case (b), retry; failure → case (a),
    # die with the captured `ln` error.
    if [[ ! -L "$lockfile" && ! -e "$lockfile" ]]; then
      local probe="$lockfile.probe.$$.$RANDOM"
      if ln -s "probe-$$" "$probe" 2>/dev/null; then
        rm -f "$probe"
        continue
      fi
      die 5 "write lock cannot be created in $sdir: ${ln_err:-symlink creation failed without diagnostic}"
    fi

    # Lockfile exists. Read the target PID in one syscall.
    local existing_pid=""
    existing_pid="$(readlink "$lockfile" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && _pid_is_live "$existing_pid"; then
      die 5 "write lock held by live PID $existing_pid at $lockfile"
    fi

    # Dead lockfile owner. Recover under the recovery lock so that at
    # most one writer at a time can remove the main lockfile.
    _attempt_stale_recovery "$sdir" "$lockfile" "$recovery"
    # _attempt_stale_recovery either returned (retry) or died. Loop.
  done
}

_attempt_stale_recovery() {
  # Single attempt to remove a stale lockfile under the recovery lock.
  # Returns 0 on success (caller should re-enter the acquire loop) or
  # exits via `die 5` for unrecoverable conditions (writability,
  # live recovery contention).
  local sdir="$1" lockfile="$2" recovery="$3"

  local rec_err
  rec_err="$(ln -s "$$" "$recovery" 2>&1)" && {
    # Test-only hook: when `AGENT_DIALOG_TEST_PAUSE_AFTER_RECOVERY_ACQUIRE`
    # is set to a positive number, sleep that many seconds while
    # holding the recovery lock. This is the only deterministic way
    # to test the EXIT/INT/TERM trap path (recovery normally
    # completes in microseconds, far below any signal-delivery
    # window). The variable is intentionally noisy and undocumented
    # outside the test suite; production callers never set it.
    if [[ -n "${AGENT_DIALOG_TEST_PAUSE_AFTER_RECOVERY_ACQUIRE:-}" ]]; then
      sleep "${AGENT_DIALOG_TEST_PAUSE_AFTER_RECOVERY_ACQUIRE}"
    fi
    # We hold the recovery lock. Re-read the main lockfile under this
    # gate. The only writers who could change the main lockfile's
    # target are those that pass through this same recovery lock, so
    # we are guaranteed the target cannot mutate while we hold it.
    # Cases:
    #   - non-empty PID, dead: classic stale recovery — rm.
    #   - empty readlink: lockfile is either a regular file leftover
    #     (corruption, manual operator action, or a stray editor
    #     temp file) or a malformed symlink. Codex review 2026-05-27
    #     round 5 flagged that without explicit handling the loop
    #     would spin forever — the old `mv` salvage path handled
    #     these uniformly because `mv` does not care about file
    #     type. Under the recovery gate no other writer can replace
    #     the file, so it is safe to remove.
    #   - non-empty PID, live: a writer re-acquired the lock in the
    #     window between acquire_lock's liveness sample and our
    #     recovery acquisition (e.g., a kernel PID reuse hit a fresh
    #     live process at the same number, or an intervening recovery
    #     completed and a new writer claimed). Do NOT remove a live
    #     lock — fall through to the caller's retry, which will see
    #     the live PID on its next iteration and die cleanly.
    local current_pid
    current_pid="$(readlink "$lockfile" 2>/dev/null || true)"
    if [[ -z "$current_pid" ]]; then
      if [[ -L "$lockfile" || -e "$lockfile" ]]; then
        printf 'agent-dialog: ownerless lock at %s, recovering\n' "$lockfile" >&2
        rm -f "$lockfile"
      fi
    elif ! _pid_is_live "$current_pid"; then
      printf 'agent-dialog: stale lock from PID %s, recovering\n' "$current_pid" >&2
      rm -f "$lockfile"
    fi
    rm -f "$recovery"
    return 0
  }

  # Recovery `ln -s` failed. Same EACCES vs EEXIST distinction as the
  # main loop: if the recovery file is absent, this is a writability
  # failure and must die.
  if [[ ! -L "$recovery" && ! -e "$recovery" ]]; then
    local probe="$recovery.probe.$$.$RANDOM"
    if ln -s "probe-$$" "$probe" 2>/dev/null; then
      rm -f "$probe"
      return 0
    fi
    die 5 "write lock recovery cannot be created in $sdir: ${rec_err:-symlink creation failed without diagnostic}"
  fi

  # Recovery file exists — someone else is recovering, or it is stale.
  local rpid
  rpid="$(readlink "$recovery" 2>/dev/null || true)"
  if [[ -n "$rpid" ]] && _pid_is_live "$rpid"; then
    die 5 "write lock recovery in progress by live PID $rpid at $recovery"
  fi

  # rpid is empty or dead. Before declaring the recovery lock stale,
  # re-check existence: codex review 2026-05-27 round 7 flagged a
  # benign-completion race — writer A held the recovery lock at the
  # time of our ln-s, then completed and rm'd recovery between our
  # ln-s and our readlink. readlink now returns empty, but the file
  # is gone (not stale). Retry the main loop instead of demanding
  # manual cleanup for a normal completion event.
  if [[ ! -L "$recovery" && ! -e "$recovery" ]]; then
    return 0
  fi
  # File present at existence check. Codex round 14 follow-up flake:
  # readlink can return empty when the file was momentarily gone
  # between ln-s failure and readlink (writer A rm'd it), but by the
  # existence check below a new writer C may have re-created
  # recovery with C's PID. Re-readlink to avoid mistaking C's live
  # recovery for stale debris.
  if [[ -z "$rpid" ]]; then
    rpid="$(readlink "$recovery" 2>/dev/null || true)"
    if [[ -n "$rpid" ]] && _pid_is_live "$rpid"; then
      die 5 "write lock recovery in progress by live PID $rpid at $recovery"
    fi
    if [[ ! -L "$recovery" && ! -e "$recovery" ]]; then
      return 0
    fi
  fi

  # Recovery holder is dead — recovery lock itself went stale.
  #
  # Auto-cleanup of a stale recovery lock is intentionally NOT done
  # here. Codex review 2026-05-27 round 6 flagged that any auto-
  # cleanup of the recovery lock has the same TOCTOU race as the
  # original main-lock salvage: two concurrent writers can both read
  # the same dead recovery PID, both decide to clean, and the second
  # writer's `rm` deletes a fresh recovery symlink the first writer
  # has already acquired. The race recreates exactly the mutex
  # violation that the recovery lock was introduced to close.
  #
  # There is no ownership-preserving primitive in shell that can
  # safely auto-cleanup a stale symlink under concurrent contention
  # (every salvage-and-verify scheme has the same flaw, one level
  # deeper). So we die fast and surface a precise diagnostic that
  # tells the operator the exact path to remove. The cost is reduced
  # resilience to a recovery-mid-crash; the benefit is no race.
  # Recovery is a single readlink + single rm, so the crash window
  # is vanishingly small in practice — the file should almost never
  # be observed stale outside SIGKILL during that microsecond.
  die 5 "write lock recovery is stale at $recovery (was held by dead PID ${rpid:-<unknown>}); manually remove it ('rm $recovery') then run 'agent-dialog.sh cleanup --session <id>' to clear the stale main lock"
}

_pid_is_live() {
  # Validate-then-test PID liveness. Bare `kill -0 $pid` is unsafe
  # because bash interprets `0` as the current process group and
  # negative numbers as broadcast targets — a malformed or planted
  # lockfile pointing at `0`/`-1`/non-numeric content would
  # masquerade as a live owner and block recovery indefinitely.
  # Accept only positive decimal PIDs before signalling.
  local pid="${1:-}"
  if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# Trap state. The EXIT/INT/TERM traps installed by acquire_lock and
# cmd_cleanup reference these globals BY NAME inside single-quoted
# trap commands, so the path values are expanded when the trap fires,
# not interpolated into the trap string at install time. Codex review
# 2026-06-10 (P2) flagged the previous double-quoted interpolation:
# an AGENT_DIALOG_HOME containing a single quote produced a trap
# string with unbalanced quotes that raised a syntax error on EXIT
# and leaked `.write.recovery`. Only one lock acquisition happens per
# helper process, so a single global pair is unambiguous.
_LOCK_TRAP_LOCKFILE=""
_LOCK_TRAP_RECOVERY=""

_release_owned_locks() {
  # Composite cleanup for both the main and recovery locks, invoked
  # from the EXIT/INT/TERM trap installed at acquire_lock entry.
  # Each file is removed only if it still records our PID, so a
  # crash that races with another writer reclaiming the lock cannot
  # strip the new owner's symlink.
  local lockfile="$1" recovery="$2" my_pid="$3" f owner
  for f in "$lockfile" "$recovery"; do
    [[ -n "$f" ]] || continue
    owner="$(readlink "$f" 2>/dev/null || true)"
    if [[ "$owner" == "$my_pid" ]]; then
      rm -f "$f"
    fi
  done
}

# --- Validation -------------------------------------------------------------

# --- Redaction risk gate ----------------------------------------------------
#
# XAR-1A.2c.d / DEC-041 (answers Q-019): v1 redaction scope is
# (1) high-confidence bearer/secret catalog (this array) and (2) opt-in
# user regex import (`_load_user_redaction_patterns`). Entropy heuristics
# and stable placeholders are deferred to a named follow-up slice
# (`XAR-1A.2c.d.entropy`) with explicit dogfood-evidence revisit criteria.
# Design doc trust boundary calls redaction "a risk gate, not proof of
# safety" — known patterns + user-supplied catalog ship fail-closed.
#
# Each entry is "name|extended-regex". The body text is matched as a single
# string against each regex; the first hit blocks the write. Catalog entries
# are high-confidence shapes (per DEC-041 F2 narrowing): public/publishable
# keys (e.g., Stripe `pk_*`, Twilio Account SID `AC*`) are excluded to keep
# fail-closed behavior from blocking legitimate pingpong bodies.
REDACTION_PATTERNS=(
  # GitHub legacy prefixed tokens.
  'github_pat_classic|ghp_[A-Za-z0-9]{36,}'
  'github_oauth|gho_[A-Za-z0-9]{36,}'
  'github_app_user_token|ghu_[A-Za-z0-9]{36,}'
  'github_app_server_token|ghs_[A-Za-z0-9]{36,}'
  # GitHub fine-grained PAT (github_pat_<22 base62>_<59 base62>).
  'github_pat_fine_grained|github_pat_[A-Za-z0-9_]{60,}'
  # Anthropic and OpenAI keys. OpenAI now ships hyphenated prefixes
  # (sk-proj-, sk-svcacct-, sk-admin-, sk-None-…), so accept hyphens in
  # the body of the regex too.
  'anthropic_key|sk-ant-[A-Za-z0-9_-]{30,}'
  'openai_key|sk-[A-Za-z0-9_-]{30,}'
  # AWS access key id.
  'aws_access_key|AKIA[0-9A-Z]{16}'
  # PEM private key header.
  'pem_private_key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  # XAR-1A.2c.d additions (DEC-041 narrowed set):
  # Slack tokens: bot/user/app/refresh/etc. — workspace_id-channel_id-secret
  # form. xox[a-z]- covers xoxb (bot), xoxp (user), xoxe (refresh), xoxa
  # (legacy app), xoxs (legacy workspace secret), xoxr (refresh new).
  'slack_token|xox[a-z]-[0-9]+-[0-9]+-[A-Za-z0-9-]+'
  # Stripe secret/restricted keys (sk_*/rk_*). publishable (pk_*) is
  # excluded — public by design, would create false-positive UX blockers.
  'stripe_secret_key|sk_(live|test)_[A-Za-z0-9]{24,}'
  'stripe_restricted_key|rk_(live|test)_[A-Za-z0-9]{24,}'
  # Google API key (e.g., Maps/Cloud). Fixed 39-char shape.
  'google_api_key|AIza[A-Za-z0-9_-]{35}'
  # Twilio API key SID (SK + 32 hex, case-insensitive per Twilio docs
  # `^SK[0-9a-fA-F]{32}$`). Account SID (AC + 32 hex) is excluded — it
  # identifies the account but is not a credential by itself.
  'twilio_api_key_sid|SK[0-9a-fA-F]{32}'
  # SendGrid API key — three dot-separated base64url segments.
  'sendgrid_api_key|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'
  # JWT bearer — three base64url segments, all non-trivially sized. Header
  # and payload both start with "eyJ" (base64 of `{"`). Signature segment
  # requires ≥20 chars to keep docs/example `eyJabc.eyJdef.short` matches
  # out. Both header and payload also require ≥10 chars beyond the prefix.
  'jwt_bearer|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}'
)

_load_user_redaction_patterns() {
  # XAR-1A.2c.d / DEC-041 F1: opt-in user regex import.
  # Resolution order (path precedence):
  #   1. $AGENT_DIALOG_REDACTION_PATTERNS (env override, when non-empty)
  #   2. $AGENT_DIALOG_HOME/redaction-patterns.txt (canonical default)
  # File absence is a silent skip — a user who never creates the file and
  # never sets the env var sees no behavior change. File present but
  # malformed → startup die with file:line + pattern name diagnostics.
  #
  # File format (per line):
  #   <name>|<extended-regex>      — append to REDACTION_PATTERNS
  #   # comment                    — skip
  #   (blank)                      — skip
  # name pattern: [A-Za-z0-9._-]+ (deterministic, audit-friendly).
  # regex is validated by feeding the empty string through `grep -E`;
  # exit code ≥ 2 means malformed (1 = no match is fine).
  local path="${AGENT_DIALOG_REDACTION_PATTERNS:-}"
  if [[ -z "$path" ]]; then
    path="$AGENT_DIALOG_HOME/redaction-patterns.txt"
  fi
  [[ -f "$path" ]] || return 0

  local lineno=0 line stripped name regex rc
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Strip a single trailing CR so files edited on Windows (CRLF) match
    # cross-platform — otherwise the carriage return ends up embedded in the
    # regex and the intended secret pattern never matches (PR #62 codex F2).
    line="${line%$'\r'}"
    # Trim leading whitespace for blank/comment classification only.
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${stripped// /}" ]] && continue
    [[ "${stripped:0:1}" == "#" ]] && continue
    if [[ "$line" != *"|"* ]]; then
      die 3 "redaction-patterns: $path:$lineno: missing '|' separator (expected '<name>|<extended-regex>')"
    fi
    name="${line%%|*}"
    regex="${line#*|}"
    # Trim trailing whitespace from name only; regex keeps as-is because
    # whitespace inside regex may be significant.
    name="${name%"${name##*[![:space:]]}"}"
    if [[ -z "$name" ]]; then
      die 3 "redaction-patterns: $path:$lineno: empty pattern name"
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      die 3 "redaction-patterns: $path:$lineno: invalid pattern name '$name' (must match [A-Za-z0-9._-]+)"
    fi
    if [[ -z "$regex" ]]; then
      die 3 "redaction-patterns: $path:$lineno: '$name' has empty regex"
    fi
    rc=0
    printf '' | grep -E -- "$regex" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ge 2 ]]; then
      die 3 "redaction-patterns: $path:$lineno: '$name' has malformed regex (grep -E rejected)"
    fi
    REDACTION_PATTERNS+=("$name|$regex")
  done < "$path"
}

scan_for_secrets() {
  local body_json="$1"
  # Concatenate body as a single string for regex matching. jq's @text on
  # the whole document gives a representation that includes embedded
  # secrets in any string field (prompt, summary, finding text, etc.).
  # XAR-1A.2c.c: scanner receives the immutable JSON snapshot captured
  # in cmd_write so a TOCTOU swap of --body-file between scan and
  # persist cannot smuggle secrets past this gate (DEC-037).
  local body_text
  body_text="$(jq -r 'tostring' <<<"$body_json")"
  local pat name regex
  for pat in "${REDACTION_PATTERNS[@]}"; do
    name="${pat%%|*}"
    regex="${pat#*|}"
    if printf '%s' "$body_text" | grep -Eq -- "$regex"; then
      die 3 "redaction: body matches secret pattern '$name'; refusing to persist (XAR-1A.1 minimum gate)"
    fi
  done
}

validate_session_id() {
  # Strict pattern: gen_session_id produces YYYYMMDD-HHMMSS-<16 hex>.
  # Anything else is rejected to prevent path traversal via slashes or
  # `..` components in a copy-pasted session id.
  local sid="$1"
  if ! [[ "$sid" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{16}$ ]]; then
    die 3 "session id '$sid' does not match the expected format YYYYMMDD-HHMMSS-<16 hex>"
  fi
}

validate_message_id() {
  local mid="$1"
  if ! [[ "$mid" =~ ^[0-9]{6}$ ]]; then
    die 3 "message id '$mid' does not match the expected format <6 digits>"
  fi
}

validate_kind() {
  case "$1" in
    request|response|decision|note|relay) return 0 ;;
    *) die 3 "unknown kind: $1" ;;
  esac
}

validate_sender() {
  case "$1" in
    codex|claude|user) return 0 ;;
    *) die 3 "sender must be codex|claude|user (got: $1)" ;;
  esac
}

validate_body() {
  # XAR-1A.2c.c: receives the canonical JSON snapshot captured by
  # cmd_write (DEC-037). No `jq … "$body_file"` reads here — every
  # check runs against the snapshot string so a mutator that swaps
  # --body-file between this call and the persist step cannot land
  # an unvalidated body.
  local kind="$1" body_json="$2"
  case "$kind" in
    request)
      jq -e '(.topic // "") != "" and (.prompt // "") != ""' <<<"$body_json" >/dev/null \
        || die 3 "request body requires topic and prompt"
      # XAR-1A.6b (ADR-0004 INV-0004-4): optional `original_user_instructions`
      # — delegation 모드 body 의 provenance. shape: non-empty string when
      # present. Required enforcement는 XAR-1A.6c에서 flip.
      jq -e '(has("original_user_instructions") | not) or ((.original_user_instructions | type == "string") and (.original_user_instructions | length > 0))' <<<"$body_json" >/dev/null \
        || die 3 "request.original_user_instructions must be a non-empty string when present"
      # XAR-1A.6b (ADR-0004 INV-0004-5/-6/-7): optional `supersedes` — 6-digit
      # message id when present (sequencing 5-check는 validate_sequencing에서).
      jq -e '(has("supersedes") | not) or ((.supersedes | type == "string") and (.supersedes | test("^[0-9]{6}$")))' <<<"$body_json" >/dev/null \
        || die 3 "request.supersedes must be a 6-digit message_id string when present"
      # XAR-1A.6b (ADR-0004 INV-0004-9): optional `prior_decision_context` —
      # needs_user resume hybrid mechanism. shape: array (may be empty) of
      # {finding_id, action, reason_one_line}. Empty array means "no prior
      # dispositions" which is the valid output of compose-context on a
      # needs_user decision with no findings (PR review pass 2 F2 round-trip
      # dead-end fix). helper-recompute equality는 validate_sequencing 직후
      # validate_prior_decision_context_equality에서 빈 set 비교 포함.
      jq -e '
        (has("prior_decision_context") | not) or (
          (.prior_decision_context | type == "array") and
          (.prior_decision_context | all(
            ((.finding_id // "") | type == "string") and ((.finding_id // "") | length > 0) and
            ((.action // "") == "accepted" or (.action // "") == "rejected" or (.action // "") == "deferred") and
            ((.reason_one_line // "") | type == "string") and ((.reason_one_line // "") | length > 0)
          ))
        )
      ' <<<"$body_json" >/dev/null \
        || die 3 "request.prior_decision_context (when present) must be array (may be empty) of {finding_id:non-empty string, action:accepted|rejected|deferred, reason_one_line:non-empty string}"
      ;;
    response)
      jq -e '(.summary // "") != ""' <<<"$body_json" >/dev/null \
        || die 3 "response body requires summary"
      # XAR-1A.6b (ADR-0004 INV-0004-5): optional `supersedes` shape.
      jq -e '(has("supersedes") | not) or ((.supersedes | type == "string") and (.supersedes | test("^[0-9]{6}$")))' <<<"$body_json" >/dev/null \
        || die 3 "response.supersedes must be a 6-digit message_id string when present"
      # findings is optional, but if present must be an array and every
      # entry must have a non-empty string finding_id. Otherwise the
      # decision coverage gate can be bypassed by writing reviewer
      # findings without ids — those entries get silently filtered when
      # the initiator's decision is checked.
      jq -e '
        (.findings // [] | type == "array") and
        (.findings // [] | all(
          ((.finding_id // "") | type == "string") and
          ((.finding_id // "") | test("^[A-Za-z0-9._-]+$"))
        ))
      ' <<<"$body_json" >/dev/null \
        || die 3 "response.findings[].finding_id must match ^[A-Za-z0-9._-]+$ (no whitespace, no control characters)"
      # Duplicate finding_id values silently collapse to one entry under
      # the decision coverage's sort -u and let a single decision satisfy
      # multiple findings. Reject duplicates here.
      jq -e '
        (.findings // []) | map(.finding_id // "") as $ids
        | ($ids | length) == ($ids | unique | length)
      ' <<<"$body_json" >/dev/null \
        || die 3 "response.findings[] finding_id values must be unique"
      ;;
    decision)
      jq -e '(.next_action // "") != "" and ((.decisions // []) | type == "array")' <<<"$body_json" >/dev/null \
        || die 3 "decision body requires next_action and decisions array"
      # XAR-1A.6b (ADR-0004 INV-0004-4): optional `original_user_instructions`.
      jq -e '(has("original_user_instructions") | not) or ((.original_user_instructions | type == "string") and (.original_user_instructions | length > 0))' <<<"$body_json" >/dev/null \
        || die 3 "decision.original_user_instructions must be a non-empty string when present"
      # XAR-1A.6b (ADR-0004 INV-0004-5): optional `supersedes` shape.
      jq -e '(has("supersedes") | not) or ((.supersedes | type == "string") and (.supersedes | test("^[0-9]{6}$")))' <<<"$body_json" >/dev/null \
        || die 3 "decision.supersedes must be a 6-digit message_id string when present"
      local next_action; next_action="$(jq -r '.next_action' <<<"$body_json")"
      case "$next_action" in
        continue|close|needs_user) ;;
        relay)
          # XAR-1A.2c.b: the post-relay-decision sequencing/resume path
          # is undefined — the next request would be rejected by the
          # `continue|needs_user` request guard and stop would land in
          # the decision-after-decision allowlist that only accepts
          # close. Accepting `relay` here would dead-end the session
          # (round-2 codex P2). Reject until a separate slice designs
          # the resume path. Canonical design doc and DEC-036 confirm
          # this is a deferred contract (round-7 codex F1).
          die 3 "decision next_action=relay is not yet supported (session would dead-end); use kind=relay message instead, decision next_action must be continue|close|needs_user (got: $next_action)"
          ;;
        *) die 3 "decision next_action must be continue|close|needs_user (got: $next_action)" ;;
      esac
      local session_close; session_close="$(jq -r '.session_close // false' <<<"$body_json")"
      if [[ "$session_close" == "true" && "$next_action" != "close" ]]; then
        die 3 "decision session_close=true requires next_action=close"
      fi
      # Each entry in decisions must have a valid action allowlist and a
      # finding_id. This prevents empty placeholder rows from satisfying the
      # audit gate when the reviewer recorded specific findings.
      jq -e '(.decisions // []) | all(
        ((.action // "") == "accepted" or (.action // "") == "rejected" or (.action // "") == "deferred")
        and ((.finding_id // "") | type == "string")
        and ((.finding_id // "") | test("^[A-Za-z0-9._-]+$"))
        and ((.reason_one_line // "") | type == "string")
        and ((.reason_one_line // "") | length > 0)
      )' <<<"$body_json" >/dev/null \
        || die 3 "each decision.decisions[] must have finding_id matching ^[A-Za-z0-9._-]+$, action in accepted|rejected|deferred, and non-empty reason_one_line (XAR-1A.6b: required so compose-context round-trip never emits null reason_one_line)"
      # Duplicate decision finding_id values would let one row satisfy two
      # disposition slots; reject duplicates.
      jq -e '
        (.decisions // []) | map(.finding_id // "") as $ids
        | ($ids | length) == ($ids | unique | length)
      ' <<<"$body_json" >/dev/null \
        || die 3 "decision.decisions[] finding_id values must be unique"
      ;;
    note)
      # `note` is the operator's supplemental context — a single non-empty
      # text body. Round/finding coverage gates ignore notes (DEC-029), and
      # role/sequencing accept notes in any open session state (see
      # validate_role / validate_sequencing).
      jq -e '(.text // "") | type == "string" and length > 0' <<<"$body_json" >/dev/null \
        || die 3 "note body requires non-empty string 'text'"
      ;;
    relay)
      # `relay` (XAR-1A.2c.b): explicit cross-reference of prior messages
      # from one side to the other. Body schema per
      # docs/design/workflows/cross-agent-review-workflow.md §relay:
      #   - source_message_ids: non-empty array of valid 6-digit ids
      #   - target_agent: codex|claude (validated against session agents
      #     elsewhere — here we only check the shape)
      #   - text: non-empty string (user's framing of the relayed content)
      # target_agent must differ from sender for agent senders; that check
      # is in validate_role because it needs initiator/reviewer context.
      jq -e '
        ((.source_message_ids // []) | type == "array" and length > 0) and
        ((.source_message_ids // []) | all((. | type == "string") and (. | test("^[0-9]{6}$")))) and
        ((.target_agent // "") == "codex" or (.target_agent // "") == "claude") and
        ((.text // "") | type == "string" and length > 0)
      ' <<<"$body_json" >/dev/null \
        || die 3 "relay body requires source_message_ids[] (6-digit ids), target_agent (codex|claude), text (non-empty string)"
      # Duplicate source_message_ids waste relay artifact and obscure intent;
      # reject so the operator's reference set stays clean.
      jq -e '
        .source_message_ids as $ids
        | ($ids | length) == ($ids | unique | length)
      ' <<<"$body_json" >/dev/null \
        || die 3 "relay source_message_ids[] must be unique"
      ;;
  esac
}

_session_dialogue_mode() {
  # XAR-1A.7 (ADR-0004 INV-0004-10): dialogue topology mode getter with
  # read-path backward compatibility. Sessions created before XAR-1A.7
  # have no dialogue_mode field — they were all sequential adversarial
  # exchanges, so the absent-field default is adversarial_dialogue, NOT
  # the new-session default (parallel_review). Silently reclassifying an
  # old session as parallel would flip its role/sequencing rules
  # mid-flight.
  local sj="$1"
  jq -r '.dialogue_mode // "adversarial_dialogue"' "$sj"
}

validate_role() {
  # XAR-1A.2c.c: body input is the JSON snapshot from cmd_write
  # (DEC-037) so target_agent enforcement reads the same bytes that
  # validate_body checked and persist will write.
  #
  # XAR-1A.7 (INV-0004-10): role rules are dialogue_mode-dependent for
  # response and decision. adversarial_dialogue keeps the v1 rules.
  # parallel_review: both agents act as reviewers of the user's question
  # (each writes its own response), and the decision artifact belongs to
  # the user alone (Q-052 — agent self-dispositions would recreate the
  # adversarial topology inside parallel mode; agents' positions are
  # already their response artifacts).
  local kind="$1" sender="$2" initiator="$3" reviewer="$4" body_json="${5:-}" dmode="${6:-adversarial_dialogue}"
  case "$kind" in
    request)
      [[ "$sender" == "$initiator" ]] \
        || die 4 "request sender must be initiator ($initiator), got $sender"
      ;;
    response)
      if [[ "$dmode" == "parallel_review" ]]; then
        [[ "$sender" == "$initiator" || "$sender" == "$reviewer" ]] \
          || die 4 "response sender must be a session agent ($initiator|$reviewer) in parallel_review, got $sender"
      else
        [[ "$sender" == "$reviewer" ]] \
          || die 4 "response sender must be reviewer ($reviewer), got $sender"
      fi
      ;;
    decision)
      if [[ "$dmode" == "parallel_review" ]]; then
        [[ "$sender" == "user" ]] \
          || die 4 "decision sender must be user in parallel_review (Q-052: the user decision is the only decision artifact), got $sender"
      else
        [[ "$sender" == "$initiator" || "$sender" == "user" ]] \
          || die 4 "decision sender must be initiator ($initiator) or user, got $sender"
      fi
      ;;
    note)
      # design/workflows/cross-agent-review-workflow.md: note sender is `user`.
      # The operator adds supplemental context the agents would otherwise
      # have to weave into their own protocol turns.
      [[ "$sender" == "user" ]] \
        || die 4 "note sender must be user, got $sender"
      ;;
    relay)
      # XAR-1A.2c.b: relay sender ∈ {user, codex, claude}. When an agent
      # relays its own side's content, target_agent must be the opposite
      # session agent (codex relays to claude, claude relays to codex).
      # When the user relays, either agent is a valid target.
      [[ "$sender" == "user" || "$sender" == "$initiator" || "$sender" == "$reviewer" ]] \
        || die 4 "relay sender must be user|codex|claude, got $sender"
      local target_agent
      target_agent="$(jq -r '.target_agent // ""' <<<"$body_json")"
      if [[ "$target_agent" != "$initiator" && "$target_agent" != "$reviewer" ]]; then
        die 4 "relay target_agent ($target_agent) must be one of session agents ($initiator|$reviewer)"
      fi
      if [[ "$sender" != "user" && "$sender" == "$target_agent" ]]; then
        die 4 "relay target_agent must not equal sender when sender is an agent (sender=$sender)"
      fi
      ;;
  esac
}

latest_message_kind() {
  # Only consider final protocol files of shape NNNNNN-kind.json.
  # Anything else (orphan .tmp from an interrupted write, editor backups,
  # etc.) is recovery debris, not protocol state.
  local sdir="$1" last
  last="$(ls "$sdir/messages" 2>/dev/null \
            | grep -E '^[0-9]{6}-(request|response|decision)\.json$' \
            | sort -n | tail -1 || true)"
  if [[ -z "$last" ]]; then
    echo ""
  else
    echo "${last#*-}" | sed 's/\.json$//'
  fi
}

_heal_interrupted_terminal_close() {
  # XAR-1A.2c close partial-failure self-repair. cmd_write persists the
  # terminal close decision message and flips session.json.status in two
  # separate steps inside the same lock window. A crash between the two
  # (SIGKILL, power loss — the EXIT trap cannot run) leaves a session
  # whose latest protocol message is a session_close=true decision while
  # session.json still says "open". Every later write would then pass the
  # status gate and append to a session whose protocol history already
  # ended with a terminal close.
  #
  # Callers invoke this while HOLDING the write lock, right after the
  # under-lock status re-read confirms "open". When the mismatch is
  # present, flip status to closed (with a self-repair timestamp so the
  # healed transition is distinguishable from a normal close in audit)
  # and return 0; the caller then rejects its operation as closed-session.
  # Returns 1 when the session state is consistent (no heal performed).
  #
  # latest_message_kind is protocol-only, so trailing note/relay messages
  # written after the interrupted close do not mask the mismatch.
  local sdir="$1" sj="$sdir/session.json"
  local latest_kind; latest_kind="$(latest_message_kind "$sdir")"
  [[ "$latest_kind" == "decision" ]] || return 1
  local latest_decision_file
  latest_decision_file="$(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-decision\.json$' \
    | sort -n | tail -1)"
  [[ -n "$latest_decision_file" ]] || return 1
  local close_flag
  close_flag="$(jq -r '.body.session_close // false' \
    "$sdir/messages/$latest_decision_file" 2>/dev/null)"
  [[ "$close_flag" == "true" ]] || return 1
  local healed_at; healed_at="$(now_utc)"
  jq --arg ts "$healed_at" \
     '.status = "closed" | .status_self_repaired_at = $ts' \
     "$sj" > "$sj.tmp"
  mv "$sj.tmp" "$sj"
  return 0
}

response_findings_all_deferred_in_decision() {
  # XAR-1A.2c.c: decision body comes from cmd_write's snapshot
  # (DEC-037). resp_findings is already an in-memory JSON string from
  # the persisted response file (read under lock; outside operator
  # influence).
  local resp_findings="$1" body_json="$2"
  jq -e --argjson resp "$resp_findings" '
    (.body // .) as $decision
    |
    ($resp | length > 0)
    and (
      ($resp | map(.finding_id)) as $ids
      | all($ids[]; . as $id
          | any(($decision.decisions // [])[]; (.finding_id == $id) and (.action == "deferred")))
    )
  ' <<<"$body_json" >/dev/null
}

preceding_response_file_for_decision() {
  local sdir="$1" decision_file="$2" decision_num best="" raw num
  decision_num="${decision_file%%-*}"
  for raw in $(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-response\.json$' \
    | sort -n); do
    num="${raw%%-*}"
    if (( 10#$num < 10#$decision_num )); then
      best="$raw"
    fi
  done
  printf '%s\n' "$best"
}

is_all_deferred_continue_decision_round() {
  local sdir="$1" decision_file="$2"
  jq -e '(.body.next_action // "") == "continue"' \
    "$sdir/messages/$decision_file" >/dev/null || return 1

  # PR #81 codex P2: in parallel_review a round's findings are the UNION
  # across both reviewers' effective responses, so the loop-breaker
  # counter must classify prior decisions against the same union the
  # decision was validated with. Inspecting only the single immediately
  # preceding response would let a clean second response mask the first
  # response's deferred findings, skipping the round in the count and
  # never forcing needs_user on the third repeat.
  local resp_findings
  if [[ "$(_session_dialogue_mode "$sdir/session.json")" == "parallel_review" ]]; then
    resp_findings="$(_round_findings_union "$sdir" "${decision_file%%-*}")"
  else
    local response_file; response_file="$(preceding_response_file_for_decision "$sdir" "$decision_file")"
    [[ -n "$response_file" ]] || return 1
    resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$response_file")"
  fi
  # XAR-1A.2c.c: response_findings_all_deferred_in_decision now expects
  # a JSON string. Read the persisted decision file (helper-owned,
  # under-lock) into the same shape. The `(.body // .)` filter in the
  # callee then resolves the body wrapper.
  local decision_json
  decision_json="$(jq -c . "$sdir/messages/$decision_file")"
  response_findings_all_deferred_in_decision "$resp_findings" "$decision_json"
}

count_trailing_all_deferred_continue_decisions() {
  local sdir="$1" extra_excluded="${2:-}" count=0 mf
  # XAR-1A.6b PR review pass 2 F1: collect superseded decision ids so we
  # walk only the "effective" decision chain. Without this, a non-deferred
  # decision that is later superseded by an all-deferred continue still
  # counts as a chain-breaker and resets the trailing counter — the
  # supersedes path could then chain unbounded all-deferred continues.
  # `extra_excluded` lets the supersedes-aware decision branch treat the
  # supersedes target as already removed from the chain when computing the
  # count for the new (not-yet-written) decision.
  local _superseded_ids=" ${extra_excluded:+${extra_excluded} }" _d_mf _sup
  while IFS= read -r _d_mf; do
    [[ -n "$_d_mf" ]] || continue
    _sup="$(jq -r '.body.supersedes // ""' "$sdir/messages/$_d_mf" 2>/dev/null)"
    [[ -n "$_sup" ]] && _superseded_ids="${_superseded_ids}${_sup} "
  done < <(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-decision\.json$')
  for mf in $(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-decision\.json$' \
    | sort -r); do
    local _mid; _mid="$(echo "$mf" | cut -c1-6)"
    if [[ "$_superseded_ids" == *" $_mid "* ]]; then
      continue  # skip superseded — not part of effective decision chain
    fi
    if is_all_deferred_continue_decision_round "$sdir" "$mf"; then
      count=$((count + 1))
    else
      break
    fi
  done
  printf '%s\n' "$count"
}

_round_response_files() {
  # Effective response files of one round, excluding superseded responses
  # (a replacement supersedes its target, so the target drops out of the
  # effective round set). The round is bounded by the latest request
  # BELOW the optional upper id (default: unbounded → current round) and
  # the upper id itself — passing a prior decision's id reconstructs THAT
  # decision's round (PR #81 codex P2: the all-deferred loop counter must
  # classify prior parallel rounds from the same union the decision was
  # validated against).
  local sdir="$1" upper_id="${2:-999999}"
  local last_req_id="000000" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local id="${f%%-*}"
    [[ "$id" < "$upper_id" ]] || continue
    last_req_id="$id"
  done < <(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-request\.json$' | sort -n)
  local superseded=" "
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local sup; sup="$(jq -r '.body.supersedes // ""' "$sdir/messages/$f" 2>/dev/null)"
    [[ -n "$sup" ]] && superseded="${superseded}${sup} "
  done < <(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-response\.json$')
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local id="${f%%-*}"
    [[ "$id" > "$last_req_id" && "$id" < "$upper_id" ]] || continue
    [[ "$superseded" == *" $id "* ]] && continue
    printf '%s\n' "$f"
  done < <(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-response\.json$' | sort -n)
}

_round_findings_union() {
  # XAR-1A.7 parallel_review: the decision must dispose the union of
  # findings across every effective response of the round, not just the
  # latest one. finding_id collisions across the two reviewers are merged
  # by id — with the skill's round-local F<N> naming, one disposition for
  # an id covers both reviewers' findings under that id. Optional second
  # arg bounds the round to a prior decision's window (see
  # _round_response_files).
  #
  # Q-056 (G4 defense-in-depth): the write-time collision reject is the
  # primary guard, but union/coverage must NOT be its single point of
  # failure. If two effective responses of the round still carry the same
  # finding_id for distinct findings (legacy data, manual edit, a guard
  # bypass), silently de-duping would feed a false 1:1 disposition map to
  # the decision audit. Detect the duplicate here and die instead — the
  # decision write fails loudly rather than recording an ambiguous audit.
  local sdir="$1" upper_id="${2:-999999}" union='[]' f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local fl; fl="$(jq -c '.body.findings // []' "$sdir/messages/$f")"
    union="$(jq -c --argjson add "$fl" '. + $add' <<<"$union")"
  done < <(_round_response_files "$sdir" "$upper_id")
  local _dups; _dups="$(jq -r '[.[] | (.finding_id // "") | select(length > 0)] | group_by(.) | map(select(length > 1)) | map(.[0]) | join(" ")' <<<"$union")"
  if [[ -n "$_dups" ]]; then
    die 4 "parallel_review round has duplicate finding_id across effective responses: $_dups. Each finding_id must be distinct across agents (Q-056) — disposition would be ambiguous."
  fi
  jq -c 'unique_by(.finding_id)' <<<"$union"
}

validate_sequencing() {
  # XAR-1A.2c.c: body input is cmd_write's JSON snapshot (DEC-037).
  # source_message_ids existence still resolves against $sdir/messages,
  # which is filesystem state outside operator-controlled inputs.
  #
  # XAR-1A.7 (INV-0004-10): sequencing is dialogue_mode-dependent for
  # response and decision — see the per-kind branches.
  local kind="$1" sdir="$2" body_json="${3:-}" dmode="${4:-adversarial_dialogue}" sender="${5:-}"
  local latest; latest="$(latest_message_kind "$sdir")"

  # XAR-1A.6b (ADR-0004 INV-0004-6): supersedes-aware sequencing. When the
  # new body carries body.supersedes, the message is a same-kind replacement,
  # and validate_supersedes (called from cmd_write right after this) enforces
  # the 5-check (target exists / same kind / same sender role / latest
  # effective / no downstream consumer). Those checks subsume the normal
  # "latest must be X" sequencing rules for the replacement case. For
  # decision replacement we still apply finding coverage against the latest
  # response (the same response findings the original decision was supposed
  # to dispose remain relevant).
  if [[ "$kind" =~ ^(request|response|decision)$ ]] \
       && jq -e 'has("supersedes")' <<<"$body_json" >/dev/null; then
    # Q-056 (PR #85 codex P2): a parallel_review response carrying
    # `supersedes` returns from this branch before reaching the `response)`
    # case, so the write-time peer-collision check would be skipped — a
    # replacement could reuse the peer's finding_id and only fail later at
    # the decision's audit-time invariant. Run the same collision check
    # here for supersedes-replacement responses, EXCLUDING the superseded
    # target (which this write replaces) but still comparing against the
    # peer's effective response. adversarial_dialogue has one reviewer per
    # round, so this is parallel-only.
    if [[ "$kind" == "response" && "$dmode" == "parallel_review" ]]; then
      local _sup_target_r; _sup_target_r="$(jq -r '.supersedes' <<<"$body_json")"
      local _my_ids_r; _my_ids_r="$(jq -r '(.findings // []) | .[] | (.finding_id // "") | select(length > 0)' <<<"$body_json" | sort -u)"
      if [[ -n "$_my_ids_r" ]]; then
        local _rf2
        while IFS= read -r _rf2; do
          [[ -n "$_rf2" ]] || continue
          [[ "${_rf2%%-*}" == "$_sup_target_r" ]] && continue  # skip the target we replace
          local _rsender2; _rsender2="$(jq -r '.sender // ""' "$sdir/messages/$_rf2")"
          [[ "$_rsender2" == "$sender" ]] && continue           # skip our own (non-target) — sequencing handles duplicate-self elsewhere
          local _peer_ids2; _peer_ids2="$(jq -r '(.body.findings // []) | .[] | (.finding_id // "") | select(length > 0)' "$sdir/messages/$_rf2" | sort -u)"
          if [[ -n "$_peer_ids2" ]]; then
            local _clash2; _clash2="$(comm -12 <(printf '%s\n' "$_my_ids_r") <(printf '%s\n' "$_peer_ids2") | tr '\n' ' ')"
            if [[ -n "${_clash2// /}" ]]; then
              die 4 "finding_id collides with peer ($_rsender2) response in this round (supersedes replacement): ${_clash2% }. parallel_review disposes the round's finding_id union, so ids must be distinct across agents (peer used: $(printf '%s' "$_peer_ids2" | tr '\n' ' '))."
            fi
          fi
        done < <(_round_response_files "$sdir")
      fi
    fi
    if [[ "$kind" == "decision" ]]; then
      # XAR-1A.6b PR review pass 2 F1: supersedes-aware decision must keep
      # the normal-path safety guards (coverage + all-deferred warning +
      # 3rd-consecutive-deferred reject + session_close consistency). Without
      # these, operator can write a valid decision then immediately replace
      # with all-deferred continue, bypassing the loop breaker.
      local _new_next _new_close
      _new_next="$(jq -r '.next_action // ""' <<<"$body_json")"
      _new_close="$(jq -r '.session_close // false' <<<"$body_json")"
      if [[ "$_new_close" == "true" && "$_new_next" != "close" ]]; then
        die 4 "decision (supersedes) session_close=true requires next_action=close"
      fi
      # PR #81 codex P2: the replacement decision must satisfy the same
      # coverage source as a normal decision — in parallel_review that is
      # the round-wide findings UNION, not just the latest response.
      # Otherwise the user could write a full decision and supersede it
      # with one disposing only the latest reviewer's findings, silently
      # dropping the other reviewer's.
      local _resp_findings=""
      if [[ "$dmode" == "parallel_review" ]]; then
        _resp_findings="$(_round_findings_union "$sdir")"
      else
        local _last_resp_for_sup; _last_resp_for_sup="$(ls "$sdir/messages" 2>/dev/null \
          | grep -E '^[0-9]{6}-response\.json$' \
          | sort -n | tail -1)"
        if [[ -n "$_last_resp_for_sup" ]]; then
          _resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$_last_resp_for_sup")"
        fi
      fi
      if [[ -n "$_resp_findings" ]]; then
        local _fcount; _fcount="$(jq 'length' <<<"$_resp_findings")"
        if (( _fcount > 0 )); then
          local _resp_ids _dec_ids _missing
          _resp_ids="$(jq -r '.[] | (.finding_id // "") | select(length > 0)' <<<"$_resp_findings" | sort -u)"
          _dec_ids="$(jq -r '(.decisions // []) | .[] | (.finding_id // "") | select(length > 0)' <<<"$body_json" | sort -u)"
          _missing="$(comm -23 <(printf '%s\n' "$_resp_ids") <(printf '%s\n' "$_dec_ids"))"
          if [[ -n "$_missing" ]]; then
            die 4 "decision (supersedes) missing dispositions for findings: $(printf '%s' "$_missing" | tr '\n' ' ')"
          fi
          if response_findings_all_deferred_in_decision "$_resp_findings" "$body_json"; then
            case "$_new_next" in
              continue)
                # XAR-1A.6b PR review pass 2 F1: supersedes target must be
                # excluded from the effective chain when counting, since this
                # write is replacing it. Without this, the target acts as a
                # chain-breaker (if non-deferred) and the new write becomes
                # the 1st all-deferred continue instead of being detected as
                # the (count+1)th.
                local _sup_target; _sup_target="$(jq -r '.supersedes' <<<"$body_json")"
                local _prior_defer_count
                _prior_defer_count="$(count_trailing_all_deferred_continue_decisions "$sdir" "$_sup_target")"
                if (( _prior_defer_count >= 2 )); then
                  die 4 "all-deferred continue repeated after two prior rounds (supersedes); set next_action=needs_user or make a non-deferred disposition"
                fi
                add_warning \
                  "PINGPONG_ALL_DEFERRED_CONTINUE" \
                  "all findings were deferred while continuing (supersedes); explain the next request or escalate with next_action=needs_user"
                ;;
              needs_user) ;;
            esac
          fi
        fi
      fi
    fi
    return 0
  fi

  case "$kind" in
    request)
      if [[ -z "$latest" ]]; then
        return 0
      fi
      [[ "$latest" == "decision" ]] \
        || die 4 "request requires no previous message or a preceding decision (latest: $latest)"
      local last_file; last_file="$(ls "$sdir/messages" 2>/dev/null \
        | grep -E '^[0-9]{6}-decision\.json$' \
        | sort -n | tail -1)"
      local na; na="$(jq -r '.body.next_action // "continue"' "$sdir/messages/$last_file")"
      case "$na" in
        continue|needs_user) ;;
        *) die 4 "request requires preceding decision.next_action=continue|needs_user (got: $na)" ;;
      esac
      ;;
    response)
      if [[ "$dmode" == "parallel_review" ]]; then
        # XAR-1A.7 parallel_review: both agents respond to the same
        # request, order free, one effective response per agent per
        # round. A decision closes the round — late responses must wait
        # for the next request.
        case "$latest" in
          request|response) ;;
          *) die 4 "response requires an open round (latest: ${latest:-none}); write a request first" ;;
        esac
        # Q-056: finding_id collision reject (under the write lock, so the
        # sibling round state is re-read atomically — G1). In
        # parallel_review both agents respond to the same request, and the
        # decision disposes the round's finding_id UNION; if two agents use
        # the same finding_id for DIFFERENT findings, a single disposition
        # is ambiguous and audit becomes false. Reject a response whose
        # finding_ids collide with a sibling (peer) effective response's
        # ids this round. The skill convention assigns distinct prefixes
        # (initiator F.., reviewer G..) so the natural path never collides;
        # this is the deterministic backstop. The reject message lists the
        # peer's used ids so the author can renumber (G3).
        local _my_ids; _my_ids="$(jq -r '(.findings // []) | .[] | (.finding_id // "") | select(length > 0)' <<<"$body_json" | sort -u)"
        local rf
        while IFS= read -r rf; do
          [[ -n "$rf" ]] || continue
          local rsender; rsender="$(jq -r '.sender // ""' "$sdir/messages/$rf")"
          if [[ "$rsender" == "$sender" ]]; then
            die 4 "response from $sender already exists in this round; use supersedes to replace it or wait for the next request"
          fi
          if [[ -n "$_my_ids" ]]; then
            local _peer_ids; _peer_ids="$(jq -r '(.body.findings // []) | .[] | (.finding_id // "") | select(length > 0)' "$sdir/messages/$rf" | sort -u)"
            if [[ -n "$_peer_ids" ]]; then
              local _clash; _clash="$(comm -12 <(printf '%s\n' "$_my_ids") <(printf '%s\n' "$_peer_ids") | tr '\n' ' ')"
              if [[ -n "${_clash// /}" ]]; then
                die 4 "finding_id collides with peer ($rsender) response in this round: ${_clash% }. parallel_review disposes the round's finding_id union, so ids must be distinct across agents — use a distinct prefix (peer used: $(printf '%s' "$_peer_ids" | tr '\n' ' '))."
              fi
            fi
          fi
        done < <(_round_response_files "$sdir")
      else
        [[ "$latest" == "request" ]] \
          || die 4 "response requires the latest message to be request (got: ${latest:-none})"
      fi
      ;;
    note)
      # `note` is a supplemental artifact and does not advance the
      # protocol turn machine — latest_message_kind ignores notes, the
      # round counter (DEC-029) ignores notes, and the finding-coverage
      # gate ignores notes. Notes are allowed in any open session state
      # (cmd_write already rejects closed/abandoned sessions before this
      # point). No additional sequencing check is required.
      :
      ;;
    relay)
      # XAR-1A.2c.b: `relay` is a supplemental cross-reference, same
      # sequencing rules as `note` — does not advance the protocol turn,
      # ignored by round/finding-coverage gates, allowed in any open
      # session state. The cross-reference targets validated below.
      #
      # source_message_ids reference existing messages. Each id must
      # correspond to an existing protocol/note message file; without
      # this check operators can build relay artifacts that point at
      # nothing, defeating audit value.
      #
      # Use `find` with a literal directory path + `-name` pattern so
      # glob metacharacters in $AGENT_DIALOG_HOME (`[`, `?`, `*`) do not
      # expand against the filesystem. The previous `compgen -G` form
      # globbed the full path, false-missing valid ids whenever an
      # operator pointed AGENT_DIALOG_HOME at a path containing `[`/`?`.
      # `-print -quit` short-circuits on the first hit; the directory
      # argument is passed as a value, not expanded.
      local sid_ref missing_refs="" match
      while IFS= read -r sid_ref; do
        [[ -n "$sid_ref" ]] || continue
        match="$(find "$sdir/messages" -maxdepth 1 -type f -name "${sid_ref}-*.json" -print -quit 2>/dev/null)"
        if [[ -z "$match" ]]; then
          missing_refs="${missing_refs}${sid_ref} "
        fi
      done < <(jq -r '.source_message_ids[]' <<<"$body_json")
      if [[ -n "$missing_refs" ]]; then
        die 4 "relay source_message_ids reference non-existent messages: ${missing_refs% }"
      fi
      ;;
    decision)
      # Three valid predecessors:
      #   1. response (normal path) — finding coverage applies.
      #   2. decision with next_action=continue, when the new body is a
      #      close decision (next_action=close + session_close=true).
      #      This is the /pingpong stop case after a continue decision
      #      already disposed all findings.
      #   3. nothing else.
      local new_next new_close
      new_next="$(jq -r '.next_action // ""' <<<"$body_json")"
      new_close="$(jq -r '.session_close // false' <<<"$body_json")"

      case "$latest" in
        response)
          # Finding coverage: the decision must dispose every finding_id
          # the round produced. adversarial_dialogue reads the latest
          # response (one reviewer per round); parallel_review reads the
          # union across all effective responses of the round (XAR-1A.7 —
          # disposing only one reviewer's findings would silently drop
          # the other reviewer's). Empty findings keeps an empty
          # decisions array valid (used by /pingpong stop on clean reviews).
          local resp_findings
          if [[ "$dmode" == "parallel_review" ]]; then
            resp_findings="$(_round_findings_union "$sdir")"
          else
            local last_response_file; last_response_file="$(ls "$sdir/messages" 2>/dev/null \
              | grep -E '^[0-9]{6}-response\.json$' \
              | sort -n | tail -1)"
            resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$last_response_file")"
          fi
          local fcount; fcount="$(jq 'length' <<<"$resp_findings")"
          if (( fcount > 0 )); then
            local resp_ids dec_ids missing
            resp_ids="$(jq -r '.[] | (.finding_id // "") | select(length > 0)' <<<"$resp_findings" | sort -u)"
            dec_ids="$(jq -r '(.decisions // []) | .[] | (.finding_id // "") | select(length > 0)' <<<"$body_json" | sort -u)"
            missing="$(comm -23 <(printf '%s\n' "$resp_ids") <(printf '%s\n' "$dec_ids"))"
            if [[ -n "$missing" ]]; then
              die 4 "decision missing dispositions for findings: $(printf '%s' "$missing" | tr '\n' ' ')"
            fi
            if response_findings_all_deferred_in_decision "$resp_findings" "$body_json"; then
              case "$new_next" in
                continue)
                  local prior_defer_count
                  prior_defer_count="$(count_trailing_all_deferred_continue_decisions "$sdir")"
                  if (( prior_defer_count >= 2 )); then
                    die 4 "all-deferred continue repeated after two prior rounds; set next_action=needs_user or make a non-deferred disposition"
                  fi
                  add_warning \
                    "PINGPONG_ALL_DEFERRED_CONTINUE" \
                    "all findings were deferred while continuing; explain the next request or escalate with next_action=needs_user"
                  ;;
                needs_user)
                  ;;
              esac
            fi
          fi
          ;;
        decision)
          # Three valid predecessors for a decision-after-decision:
          #   (a) continue → close: classic close-after-continue, the
          #       /pingpong stop path after a continue decision already
          #       disposed all findings.
          #   (b) close-intent → close: convergence path where the
          #       initiator first records `next_action=close,
          #       session_close=false` (intent) and the user later
          #       confirms with `session_close=true`. design doc
          #       Convergence section requires this two-step close.
          #   (c) needs_user → close: operator decides to end after an
          #       escalation instead of resuming with a new request.
          # In all cases the new decision must be the explicit close
          # (next_action=close + session_close=true). No new findings
          # since the last response, so no coverage check is needed.
          local last_decision_file; last_decision_file="$(ls "$sdir/messages" 2>/dev/null \
            | grep -E '^[0-9]{6}-decision\.json$' \
            | sort -n | tail -1)"
          local prev_next prev_close
          prev_next="$(jq -r '.body.next_action // ""' "$sdir/messages/$last_decision_file")"
          prev_close="$(jq -r '.body.session_close // false' "$sdir/messages/$last_decision_file")"
          case "$prev_next" in
            continue) : ;;
            close)
              # Previous close decision must have been intent (session_close=false).
              # If session_close was true, the helper would already have
              # flipped session.json.status to closed and the early status
              # check in cmd_write would have refused this write.
              [[ "$prev_close" == "false" ]] \
                || die 4 "decision after a session-closing decision is not allowed"
              ;;
            needs_user) : ;;
            *) die 4 "decision after decision requires previous next_action in continue|close|needs_user (got: ${prev_next:-none})" ;;
          esac
          if [[ "$new_next" != "close" || "$new_close" != "true" ]]; then
            die 4 "decision after decision is only allowed as explicit close (need next_action=close and session_close=true)"
          fi
          ;;
        *)
          die 4 "decision requires latest to be response, or decision(continue|close|needs_user) followed by close (got: ${latest:-none})"
          ;;
      esac
      ;;
  esac
}

allocate_message_id() {
  # Allocate the next id based on final stored message files. .tmp orphan
  # files must not push the id forward, or a leftover 000002-foo.json.tmp
  # would silently skip 000002 for the next real write.
  #
  # Note (XAR-1A.2c.a): `note` files share the same numeric id namespace as
  # request/response/decision because they are stored under the same
  # `messages/` directory and addressed by the same `--message <id>` read
  # path. Excluding notes here would let two consecutive `note` writes
  # collide on the same id and silently overwrite the first one. Sequencing
  # still ignores notes via `latest_message_kind`; that protocol-vs-storage
  # distinction is intentional.
  local sdir="$1" last_num=0
  if [[ -d "$sdir/messages" ]]; then
    local raw
    raw="$(ls "$sdir/messages" 2>/dev/null \
            | grep -E '^[0-9]{6}-(request|response|decision|note|relay)\.json$' \
            | sed -n 's/^\([0-9]\{6\}\)-.*/\1/p' \
            | sort -n | tail -1 || true)"
    last_num="${raw:-0}"
    last_num=$((10#$last_num))
  fi
  printf '%06d\n' $((last_num + 1))
}

_compute_available_note_ids() {
  # XAR-1A.2c.a.det / DEC-038: write-time note availability evidence.
  # Helper-owned envelope metadata recording which note ids existed in the
  # session at this protocol-kind write's lock window. Claim scope is
  # write-time availability only — NOT prompt eligibility, NOT consumption.
  #
  # Inputs:
  #   $1 sdir       — session directory
  #   $2 next_id    — 6-digit id this write will use
  #   $3 cur_kind   — current write kind (request|response|decision)
  #
  # 3-way base-window rule (top-down first match):
  #   (a) no prior protocol message → base = "000000"
  #       (first protocol write in session, typically first request)
  #   (b) cur_kind == "response" AND no prior kind=response in session
  #       → base = "000000"
  #       (first reviewer response — join contract inherits pre-request notes)
  #   (c) otherwise → base = latest prior protocol message id
  #
  # Output: compact JSON array `[{"message_id":"NNNNNN"}, ...]` on stdout.
  local sdir="$1" next_id="$2" cur_kind="$3"
  local msgs_dir="$sdir/messages"
  if [[ ! -d "$msgs_dir" ]]; then echo "[]"; return; fi

  # Only consider final files of shape NNNNNN-(protocol|note).json. Relays
  # don't shift base and aren't notes, so they're excluded here entirely.
  local entries
  entries="$(ls "$msgs_dir" 2>/dev/null \
              | grep -E '^[0-9]{6}-(request|response|decision|note)\.json$' \
              | sort || true)"

  local prev_protocol_id="" has_prior_response="false"
  local line id kind
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    id="${line%%-*}"
    kind="${line#*-}"; kind="${kind%.json}"
    # Zero-padded 6-digit ids compare lexicographically the same as numeric.
    [[ "$id" < "$next_id" ]] || continue
    case "$kind" in
      request|response|decision)
        prev_protocol_id="$id"
        [[ "$kind" == "response" ]] && has_prior_response="true"
        ;;
    esac
  done <<< "$entries"

  local base
  if [[ -z "$prev_protocol_id" ]]; then
    base="000000"
  elif [[ "$cur_kind" == "response" && "$has_prior_response" == "false" ]]; then
    base="000000"
  else
    base="$prev_protocol_id"
  fi

  local result='[]'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    id="${line%%-*}"
    kind="${line#*-}"; kind="${kind%.json}"
    [[ "$kind" == "note" ]] || continue
    [[ "$id" > "$base" && "$id" < "$next_id" ]] || continue
    result="$(jq -c --arg id "$id" '. += [{"message_id": $id}]' <<<"$result")"
  done <<< "$entries"

  echo "$result"
}

# XAR-1A.6b (ADR-0004 INV-0004-5/-6/-7): supersedes 5-check syntactic
# validation. Called from cmd_write under the same lock as validate_sequencing.
# Inputs: kind, sender, sdir, body_json (snapshot per DEC-037). Each check
# corresponds to a 5-tuple item in INV-0004-5; failing any one rejects the
# write.
validate_supersedes() {
  local kind="$1" sender="$2" sdir="$3" body_json="$4" dmode="${5:-adversarial_dialogue}"
  case "$kind" in
    request|response|decision) ;;
    *)
      # note/relay supersedes not introduced in this slice (ADR-0004
      # INV-0004-5: "note/relay supersedes는 도입하지 않는다"). If body
      # somehow carries one, reject defensively.
      jq -e '(has("supersedes") | not)' <<<"$body_json" >/dev/null \
        || die 3 "kind=$kind does not support body.supersedes (protocol-only per ADR-0004 INV-0004-5)"
      return 0
      ;;
  esac
  jq -e '(has("supersedes") | not)' <<<"$body_json" >/dev/null && return 0
  local target_id; target_id="$(jq -r '.supersedes' <<<"$body_json")"
  # (1) target id exists in session
  local target_file
  target_file="$(find "$sdir/messages" -maxdepth 1 -type f -name "${target_id}-*.json" -print -quit 2>/dev/null)"
  [[ -n "$target_file" ]] \
    || die 4 "supersedes target $target_id does not exist in session"
  # (2) target same kind
  local target_kind; target_kind="$(jq -r '.kind' "$target_file")"
  [[ "$target_kind" == "$kind" ]] \
    || die 4 "supersedes target $target_id is kind=$target_kind, expected $kind"
  # (3) target same sender role (initiator-vs-reviewer)
  local target_sender; target_sender="$(jq -r '.sender' "$target_file")"
  [[ "$target_sender" == "$sender" ]] \
    || die 4 "supersedes target $target_id was written by sender=$target_sender, expected $sender"
  # (4) target is latest effective of that kind in current state
  #     "latest effective" = highest message_id of that kind that is not
  #     itself superseded by another message of the same kind. We compute
  #     by walking the message list for that kind, marking superseded ids,
  #     and asserting target is the maximum non-superseded id.
  #
  #     PR #81 codex P2: in parallel_review the two reviewers' responses
  #     are siblings, not a sequence — the first responder must be able
  #     to replace its OWN response while the round is still open, even
  #     after the peer responded. So for parallel response supersedes the
  #     "latest effective" scope narrows to the SENDER's responses
  #     (check 3 already pinned target_sender == sender).
  local kind_ids
  if [[ "$kind" == "response" && "$dmode" == "parallel_review" ]]; then
    local rid rfile
    kind_ids=""
    while IFS= read -r rid; do
      [[ -n "$rid" ]] || continue
      rfile="$sdir/messages/${rid}-response.json"
      if [[ "$(jq -r '.sender' "$rfile")" == "$sender" ]]; then
        kind_ids="${kind_ids}${rid}
"
      fi
    done < <(ls "$sdir/messages" 2>/dev/null \
      | grep -E '^[0-9]{6}-response\.json$' \
      | sed -E 's/-response\.json$//' \
      | sort)
  else
    kind_ids="$(ls "$sdir/messages" 2>/dev/null \
      | grep -E "^[0-9]{6}-${kind}\.json$" \
      | sed -E "s/-${kind}\.json$//" \
      | sort)"
  fi
  # collect supersedes targets among existing messages of this kind
  local superseded_ids="" mid mfile sup
  while IFS= read -r mid; do
    [[ -n "$mid" ]] || continue
    mfile="$sdir/messages/${mid}-${kind}.json"
    sup="$(jq -r '.body.supersedes // ""' "$mfile" 2>/dev/null)"
    [[ -n "$sup" ]] && superseded_ids="${superseded_ids}${sup} "
  done <<< "$kind_ids"
  # latest effective = max id in kind_ids that is not in superseded_ids
  local latest_effective="" candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ " $superseded_ids" != *" $candidate "* ]]; then
      latest_effective="$candidate"
    fi
  done <<< "$kind_ids"
  [[ "$latest_effective" == "$target_id" ]] \
    || die 4 "supersedes target $target_id is not latest effective of kind=$kind (latest effective: ${latest_effective:-none})"
  # (5) no downstream protocol consumer — no protocol message with id
  #     greater than target_id (any kind in request/response/decision).
  #
  #     PR #81 codex P2: in parallel_review the peer's sibling response
  #     answers the same request and does NOT consume this sender's
  #     response — only a decision (or a later request, which sequencing
  #     forbids without a decision anyway) consumes responses. So for
  #     parallel response supersedes the downstream scan skips sibling
  #     responses; once the round's decision lands, replacement is
  #     rejected here as before.
  local target_num=$((10#$target_id))
  local downstream=""
  local -a _ds_patterns
  if [[ "$kind" == "response" && "$dmode" == "parallel_review" ]]; then
    _ds_patterns=(-name "*-request.json" -o -name "*-decision.json")
  else
    _ds_patterns=(-name "*-request.json" -o -name "*-response.json" -o -name "*-decision.json")
  fi
  while IFS= read -r mfile; do
    [[ -n "$mfile" ]] || continue
    local mbase; mbase="$(basename "$mfile")"
    local mid_str; mid_str="$(echo "$mbase" | cut -c1-6)"
    local mid_num=$((10#$mid_str))
    if (( mid_num > target_num )); then
      downstream="${downstream}${mbase} "
    fi
  done < <(find "$sdir/messages" -maxdepth 1 -type f \( "${_ds_patterns[@]}" \) | sort)
  [[ -z "$downstream" ]] \
    || die 4 "supersedes target $target_id already has downstream protocol consumer(s): ${downstream% }"
}

# XAR-1A.6b (ADR-0004 INV-0004-9): needs_user resume helper-recomputed
# element-wise equality check. Called from cmd_write when latest protocol
# message is decision.needs_user AND new body has prior_decision_context.
# set equality on (finding_id, action, reason_one_line) triples — order
# irrelevant. PR review pass 6 F1: gate strictly to needs_user predecessor —
# general continue extension is Q-054 follow-up, not part of this slice.
validate_prior_decision_context_equality() {
  local sdir="$1" body_json="$2"
  if jq -e '(has("prior_decision_context") | not)' <<<"$body_json" >/dev/null; then
    # XAR-1A.6c (ADR-0004 INV-0004-9 full acceptance): a request that
    # resumes after a needs_user decision must carry the deterministic
    # prior_decision_context — field absence is now rejected, not
    # accepted. XAR-1A.6b shipped validate-if-present only; this is the
    # staged flip. Non-resume requests (no prior decision, or latest
    # decision is continue) legitimately omit the field.
    local last_dec; last_dec="$(ls "$sdir/messages" 2>/dev/null \
      | grep -E '^[0-9]{6}-decision\.json$' \
      | sort -n | tail -1 || true)"
    if [[ -n "$last_dec" ]]; then
      local last_req; last_req="$(ls "$sdir/messages" 2>/dev/null \
        | grep -E '^[0-9]{6}-request\.json$' \
        | sort -n | tail -1 || true)"
      # The resume is the FIRST request after the needs_user decision;
      # once a newer request exists past the decision, later requests are
      # ordinary continue turns. One exception: a supersedes-replacement
      # of that resume request is itself the (new effective) resume —
      # accepting it without pdc would silently drop the context from
      # the effective request, defeating the INV-0004-9 guarantee.
      local replaces_post_decision_request="false"
      if [[ -n "$last_req" && "${last_req%%-*}" > "${last_dec%%-*}" ]] \
         && jq -e --arg t "${last_req%%-*}" '.supersedes == $t' <<<"$body_json" >/dev/null 2>&1; then
        replaces_post_decision_request="true"
      fi
      if [[ -z "$last_req" || "${last_req%%-*}" < "${last_dec%%-*}" || "$replaces_post_decision_request" == "true" ]]; then
        local last_dec_next
        last_dec_next="$(jq -r '.body.next_action // ""' "$sdir/messages/$last_dec")"
        if [[ "$last_dec_next" == "needs_user" ]]; then
          die 4 "request: prior_decision_context is required when resuming after a needs_user decision (XAR-1A.6c enforcement flip; run 'compose-context --session <sid> --from-decision ${last_dec%%-*}' and embed its output verbatim)"
        fi
      fi
    fi
    return 0
  fi
  # find latest decision file
  local last_decision_file; last_decision_file="$(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-decision\.json$' \
    | sort -n | tail -1)"
  [[ -n "$last_decision_file" ]] \
    || die 4 "prior_decision_context provided but no prior decision exists"
  local prior_path="$sdir/messages/$last_decision_file"
  local prior_next_action; prior_next_action="$(jq -r '.body.next_action // ""' "$prior_path")"
  [[ "$prior_next_action" == "needs_user" ]] \
    || die 4 "prior_decision_context only allowed when latest decision.next_action=needs_user (got: ${prior_next_action:-none}); general continue extension is Q-054 follow-up"
  # expected: prior decision's decisions[] projected to {finding_id, action,
  # reason_one_line} triples
  local expected_json; expected_json="$(jq -c '
    [ .body.decisions[] | {finding_id, action, reason_one_line} ]
  ' "$prior_path")"
  local actual_json; actual_json="$(jq -c '
    [ .prior_decision_context[] | {finding_id, action, reason_one_line} ]
  ' <<<"$body_json")"
  # set equality: sort by finding_id and compare
  local expected_sorted actual_sorted
  expected_sorted="$(jq -c 'sort_by(.finding_id)' <<<"$expected_json")"
  actual_sorted="$(jq -c 'sort_by(.finding_id)' <<<"$actual_json")"
  [[ "$expected_sorted" == "$actual_sorted" ]] \
    || die 4 "prior_decision_context does not match prior decision dispositions (set equality on triples); expected=$expected_sorted actual=$actual_sorted"
}

# --- Subcommands ------------------------------------------------------------

cmd_init() {
  # XAR-1A.7 (INV-0004-10): --dialogue-mode selects the session topology.
  # Default is parallel_review (Q-053 — the user's recorded preference,
  # effective now that the behavior lands with this slice). The mode
  # switch is this named flag — no implicit/keyword inference (R2-F7).
  local initiator="" topic="" repo="" emit_json="false" dialogue_mode="parallel_review"
  while (( $# )); do
    case "$1" in
      --initiator) initiator="$2"; shift 2 ;;
      --topic)     topic="$2";     shift 2 ;;
      --repo)      repo="$2";      shift 2 ;;
      --dialogue-mode) dialogue_mode="$2"; shift 2 ;;
      --json)      emit_json="true"; shift ;;
      *) die 3 "init: unknown argument: $1" ;;
    esac
  done

  case "$initiator" in
    codex)  reviewer="claude" ;;
    claude) reviewer="codex"  ;;
    *) die 3 "init: --initiator must be codex|claude" ;;
  esac
  [[ -n "$topic" ]] || die 3 "init: --topic required"
  case "$dialogue_mode" in
    adversarial_dialogue|parallel_review) ;;
    *) die 3 "init: --dialogue-mode must be adversarial_dialogue|parallel_review (got: $dialogue_mode)" ;;
  esac

  # Run the redaction scanner on init metadata before creating any session
  # artifact. /pingpong start passes user text as --topic; without this,
  # a secret in the very first prompt line would already be persisted in
  # session.json before the cmd_write redaction gate runs.
  #
  # XAR-1A.2c.c (DEC-037): scan_for_secrets now accepts the canonical
  # JSON string directly, so we no longer need a temp probe file or its
  # EXIT-trap cleanup path.
  local topic_probe_json
  topic_probe_json="$(jq -n --arg topic "$topic" --arg repo "$repo" '{topic: $topic, repo: $repo}')"
  scan_for_secrets "$topic_probe_json"

  local sid sdir created_at attempt=0
  while true; do
    sid="$(gen_session_id)"
    sdir="$SESSIONS_DIR/$sid"
    # `mkdir` without `-p` fails on collision instead of reusing the directory.
    # Reusing would let two starts in the same timestamp bucket overwrite
    # one session.json with another's metadata.
    if mkdir "$sdir" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    if (( attempt > 5 )); then
      die 4 "init: too many session_id collisions; ${SESSIONS_DIR} may be unwritable"
    fi
  done
  mkdir "$sdir/messages"
  created_at="$(now_utc)"

  local repo_json="null"
  if [[ -n "$repo" ]]; then
    local head_sha=""
    if git -C "$repo" rev-parse HEAD >/dev/null 2>&1; then
      head_sha="$(git -C "$repo" rev-parse HEAD)"
    fi
    repo_json="$(jq -n --arg path "$repo" --arg head "$head_sha" '{path: $path, head_sha: ($head | select(length > 0)) }')"
  fi

  # XAR-1A.7 (B) collision-resolving rename: the old `mode` field carried
  # DEC-006 peer availability semantics — new sessions write it as
  # `peer_availability` and the dialogue topology lives in the new
  # `dialogue_mode` field. Old sessions are lazily migrated on their next
  # write (cmd_write lock window).
  jq -n \
    --arg schema "$SCHEMA_VERSION" \
    --arg sid "$sid" \
    --arg ts "$created_at" \
    --arg topic "$topic" \
    --arg initiator "$initiator" \
    --arg reviewer "$reviewer" \
    --arg dmode "$dialogue_mode" \
    --argjson repo "$repo_json" \
    '{schema_version: $schema, session_id: $sid, created_at: $ts, status: "open", topic: $topic, initiator_agent: $initiator, reviewer_agent: $reviewer, peer_availability: "peer-required", dialogue_mode: $dmode, repo: $repo}' \
    > "$sdir/session.json.tmp"
  mv "$sdir/session.json.tmp" "$sdir/session.json"

  if [[ "$emit_json" == "true" ]]; then
    jq -n --arg sid "$sid" --arg sdir "$sdir" --arg dmode "$dialogue_mode" \
      '{schema_version: 1, kind: "agent_dialog_init", session_id: $sid, session_dir: $sdir, dialogue_mode: $dmode}'
  else
    printf 'Session: %s\n' "$sid"
    printf 'Dir:     %s\n' "$sdir"
    printf 'Roles:   initiator=%s reviewer=%s\n' "$initiator" "$reviewer"
    printf 'Mode:    %s\n' "$dialogue_mode"
    printf 'Join:    (in the other agent) /pingpong join %s\n' "$sid"
  fi
}

cmd_write() {
  local session="" kind="" sender="" recipient="" parent="" body_file="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session)    session="$2";    shift 2 ;;
      --kind)       kind="$2";       shift 2 ;;
      --sender)     sender="$2";     shift 2 ;;
      --recipient)  recipient="$2";  shift 2 ;;
      --parent)     parent="$2";     shift 2 ;;
      --body-file)  body_file="$2";  shift 2 ;;
      --json)       emit_json="true"; shift ;;
      *) die 3 "write: unknown argument: $1" ;;
    esac
  done

  [[ -n "$session"   ]] || die 3 "write: --session required"
  validate_session_id "$session"
  [[ -n "$kind"      ]] || die 3 "write: --kind required"
  [[ -n "$sender"    ]] || die 3 "write: --sender required"
  [[ -n "$body_file" && -f "$body_file" ]] || die 3 "write: --body-file required and must exist"

  validate_kind "$kind"
  validate_sender "$sender"

  # XAR-1A.2c.c (DEC-037): snapshot the body file exactly once into an
  # in-memory canonical JSON string and route every downstream check
  # (validate_body, scan_for_secrets, validate_role, validate_sequencing,
  # relay target-agent equality, persist) through the same bytes. A
  # process that mutates --body-file after this read cannot influence
  # any later step — validation, redaction, audit-equality, and the
  # persisted message all see the snapshot.
  #
  # `--slurp` requires the file to contain exactly one top-level JSON
  # document. `jq -c .` alone would accept a multi-document JSON
  # stream and broadcast each document through every downstream
  # `<<<"$body_json"` filter, corrupting persistence with multiple
  # envelopes per file (PR #39 round-2 codex P1).
  local body_json
  body_json="$(jq -ce --slurp '
    if length == 1 then .[0]
    else error("body file must contain exactly one top-level JSON document")
    end
  ' "$body_file" 2>/dev/null)" \
    || die 3 "body file must be a single JSON document: $body_file"

  validate_body "$kind" "$body_json"
  scan_for_secrets "$body_json"

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "write: session not found: $session"
  local sj="$sdir/session.json"
  [[ -f "$sj" ]] || die 3 "write: session.json missing in $sdir"

  local status initiator reviewer
  status="$(jq -r '.status' "$sj")"
  initiator="$(jq -r '.initiator_agent' "$sj")"
  reviewer="$(jq -r '.reviewer_agent' "$sj")"
  [[ "$status" == "open" ]] || die 4 "write: session $session status is $status"

  # XAR-1A.7 (INV-0004-10): dialogue topology mode drives role and
  # sequencing rules below. Old sessions without the field default to
  # adversarial_dialogue (see _session_dialogue_mode).
  local dmode; dmode="$(_session_dialogue_mode "$sj")"

  validate_role "$kind" "$sender" "$initiator" "$reviewer" "$body_json" "$dmode"

  # XAR-1A.6c (ADR-0004 INV-0004-4 full acceptance): delegation provenance
  # is now REQUIRED, not validate-if-present. Agent-sender protocol bodies
  # that the delegation contract composes (request, decision) must carry a
  # non-empty original_user_instructions. user-sender decisions are the
  # operator's own words — the body itself is the provenance, so no field
  # is required there. note/relay are passthrough kinds (INV-0004-3) and
  # never carry the field. Shape (string + non-empty when present) is
  # still validated for every kind in validate_body.
  case "$kind" in
    request|decision)
      if [[ "$sender" == "codex" || "$sender" == "claude" ]]; then
        jq -e '(.original_user_instructions | type == "string") and (.original_user_instructions | length > 0)' <<<"$body_json" >/dev/null \
          || die 3 "$kind: original_user_instructions is required for agent-composed protocol bodies (XAR-1A.6c enforcement flip; ADR-0004 INV-0004-4)"
      fi
      ;;
  esac

  acquire_lock "$sdir"
  # Re-read status under lock to close the abandon/close race: cmd_abandon
  # and cmd_write's terminal close both flip session.json.status without
  # writing a protocol message, so an out-of-lock status snapshot can be
  # stale by the time we hold the lock. Sequencing alone cannot catch this
  # because there is no terminal message to compare against (abandon is a
  # status-only transition).
  local status_locked; status_locked="$(jq -r '.status' "$sj")"
  [[ "$status_locked" == "open" ]] || die 4 "write: session $session is $status_locked (after lock)"
  # XAR-1A.2c close partial-failure self-repair: an interrupted terminal
  # close (decision persisted, status flip lost to a crash) leaves
  # status=open with a session_close=true latest decision. Heal the
  # status under the lock we already hold, then reject this write the
  # same way a normally-closed session would.
  if _heal_interrupted_terminal_close "$sdir"; then
    die 4 "write: session $session is closed (status self-repaired: latest decision carries session_close=true but an interrupted close left status=open)"
  fi
  # XAR-1A.7 lazy schema migration under the write lock: pre-XAR-1A.7
  # sessions carry `mode: "peer-required"` (DEC-006 peer availability
  # semantics). Rename it to `peer_availability` once; dialogue_mode is
  # deliberately NOT added — the absent-field default in
  # _session_dialogue_mode keeps old sessions adversarial_dialogue.
  if jq -e 'has("mode") and (has("peer_availability") | not)' "$sj" >/dev/null; then
    jq '.peer_availability = .mode | del(.mode)' "$sj" > "$sj.tmp"
    mv "$sj.tmp" "$sj"
  fi
  # Re-read latest under lock and validate sequencing (decision coverage
  # needs the body to compare against the round's response findings).
  validate_sequencing "$kind" "$sdir" "$body_json" "$dmode" "$sender"

  # XAR-1A.6b (ADR-0004 INV-0004-5/-6/-7): supersedes 5-check under the
  # same lock. validate-if-present — no-op when body has no supersedes.
  validate_supersedes "$kind" "$sender" "$sdir" "$body_json" "$dmode"

  # XAR-1A.6b (ADR-0004 INV-0004-9): needs_user resume helper-recomputed
  # equality. validate-if-present — only fires when body has
  # prior_decision_context.
  if [[ "$kind" == "request" ]]; then
    validate_prior_decision_context_equality "$sdir" "$body_json"
  fi

  local next_id; next_id="$(allocate_message_id "$sdir")"
  local created_at; created_at="$(now_utc)"

  # XAR-1A.2c.a.det / DEC-038: only protocol-kind writes carry the
  # write-time note availability evidence. note/relay envelopes do not get a
  # `meta.available_note_ids` field — they are not the message kinds whose
  # context the slice tracks.
  local available_note_ids_json="null"
  case "$kind" in
    request|response|decision)
      available_note_ids_json="$(_compute_available_note_ids "$sdir" "$next_id" "$kind")"
      ;;
  esac

  # relay carries body.target_agent — envelope recipient must equal that
  # single target so list/transcript output does not contradict the body
  # (round-5 codex P2). Round-6 codex P2 also requires this when the
  # caller supplies an explicit --recipient: without the equality check,
  # `write --kind relay --recipient both` overrides the body invariant
  # and lies to routing/audit consumers. Enforce equality regardless of
  # whether --recipient was supplied.
  if [[ "$kind" == "relay" ]]; then
    local relay_target; relay_target="$(jq -r '.target_agent' <<<"$body_json")"
    if [[ -z "$recipient" ]]; then
      recipient="$relay_target"
    elif [[ "$recipient" != "$relay_target" ]]; then
      die 3 "relay --recipient '$recipient' does not match body.target_agent '$relay_target'"
    fi
  elif [[ -z "$recipient" ]]; then
    if [[ "$sender" == "$initiator" ]]; then
      recipient="$reviewer"
    elif [[ "$sender" == "$reviewer" ]]; then
      recipient="$initiator"
    else
      recipient="both"
    fi
  fi

  local parent_json="null"
  if [[ -n "$parent" ]]; then
    parent_json="$(jq -n --arg p "$parent" '$p')"
  fi

  local out_file="$sdir/messages/${next_id}-${kind}.json"
  # XAR-1A.2c.c PR #39 round-1 codex P1: feed the body snapshot to jq
  # over stdin instead of `--argjson body "$body_json"`. Passing the
  # full body via argv enforces ARG_MAX (1 MB on macOS) on otherwise
  # valid prompts/responses and would regress the file-first contract.
  # Heredoc streams the snapshot through stdin (pipe-backed, not argv),
  # restoring the previous file-sized ceiling.
  #
  # XAR-1A.2c.a.det PR #50 round-1 codex P2: same principle applies to
  # `meta.available_note_ids`. Long sessions can grow the array unbounded,
  # so `--argjson` would re-introduce the ARG_MAX failure mode. Stream the
  # value through a temp file via `--slurpfile` instead (printf is a bash
  # builtin so the variable→file write does not transit argv either).
  local avail_tmp; avail_tmp="$(mktemp -t adt-avail-XXXXXX.json)"
  printf '%s\n' "$available_note_ids_json" > "$avail_tmp"
  jq \
    --arg schema "$SCHEMA_VERSION" \
    --arg sid "$session" \
    --arg mid "$next_id" \
    --arg kind "$kind" \
    --arg sender "$sender" \
    --arg recipient "$recipient" \
    --arg ts "$created_at" \
    --argjson parent "$parent_json" \
    --slurpfile available_notes_arr "$avail_tmp" \
    '. as $body
     | ($available_notes_arr[0]) as $available_notes
     | {schema_version: $schema, session_id: $sid, message_id: $mid, kind: $kind, sender: $sender, recipient: $recipient, created_at: $ts, parent_message_id: $parent, body: $body}
     + (if $available_notes == null then {} else {meta: {available_note_ids: $available_notes}} end)' \
    <<<"$body_json" \
    > "$out_file.tmp"
  mv "$out_file.tmp" "$out_file"

  # session_close updates session.json under the same lock window.
  if [[ "$kind" == "decision" ]]; then
    local session_close; session_close="$(jq -r '.session_close // false' <<<"$body_json")"
    if [[ "$session_close" == "true" ]]; then
      jq '.status = "closed"' "$sj" > "$sj.tmp"
      mv "$sj.tmp" "$sj"
    fi
  fi

  emit_warnings_stderr

  if [[ "$emit_json" == "true" ]]; then
    local warnings_json_payload; warnings_json_payload="$(warnings_json)"
    # codex PR #50 P2 same rationale: ack also echoes the (potentially large)
    # available_notes array. Reuse the same temp file written before persist.
    jq -n \
      --arg sid "$session" \
      --arg mid "$next_id" \
      --arg kind "$kind" \
      --arg path "$out_file" \
      --argjson warnings "$warnings_json_payload" \
      --slurpfile available_notes_arr "$avail_tmp" \
      '($available_notes_arr[0]) as $available_notes
       | {schema_version: 1, kind: "agent_dialog_write", session_id: $sid, message_id: $mid, message_kind: $kind, path: $path, warnings: $warnings}
       + (if $available_notes == null then {} else {meta: {available_note_ids: $available_notes}} end)'
  else
    printf 'Wrote %s-%s\n' "$next_id" "$kind"
    printf 'Path: %s\n' "$out_file"
  fi

  rm -f "$avail_tmp"
}

cmd_read() {
  local session="" message="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --message) message="$2"; shift 2 ;;
      --json)    emit_json="true"; shift ;;
      *) die 3 "read: unknown argument: $1" ;;
    esac
  done
  [[ -n "$session" ]] || die 3 "read: --session required"
  validate_session_id "$session"

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "read: session not found: $session"

  if [[ -n "$message" ]]; then
    validate_message_id "$message"
    local match
    match="$(ls "$sdir/messages/${message}-"*.json 2>/dev/null | head -1 || true)"
    [[ -n "$match" ]] || die 3 "read: message $message not found in $session"
    if [[ "$emit_json" == "true" ]]; then
      jq -c . "$match"
    else
      jq . "$match"
    fi
  else
    if [[ "$emit_json" == "true" ]]; then
      jq -c . "$sdir/session.json"
    else
      jq . "$sdir/session.json"
    fi
  fi
}

cmd_list() {
  local session="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --json)    emit_json="true"; shift ;;
      *) die 3 "list: unknown argument: $1" ;;
    esac
  done

  if [[ -z "$session" ]]; then
    if [[ ! -d "$SESSIONS_DIR" ]]; then
      [[ "$emit_json" == "true" ]] && jq -n '{schema_version:1,kind:"agent_dialog_list_sessions",sessions:[]}' || echo "(no sessions)"
      return 0
    fi
    if [[ "$emit_json" == "true" ]]; then
      local first=1
      printf '{"schema_version":1,"kind":"agent_dialog_list_sessions","sessions":['
      for sd in "$SESSIONS_DIR"/*/; do
        [[ -d "$sd" ]] || continue
        local sj="$sd/session.json"
        [[ -f "$sj" ]] || continue
        if (( first )); then first=0; else printf ','; fi
        # Lifecycle classification (XAR-1A.2b.cont/2c.a; DEC-026):
        #   - status==open + no protocol message (request/response/decision)
        #     → "init_only" (operator started /pingpong but no protocol turn
        #     yet — note-only sessions still count as init_only because
        #     reviewers cannot respond until the first request lands)
        #   - status==open + >=1 protocol message → "active"
        #   - status=="abandoned" or "closed" → use status directly
        # message_count counts every stored message (note included);
        # protocol_count counts only request/response/decision and drives
        # lifecycle. Notes are deliberately exposed in message_count so
        # note-only sessions are not hidden from list summaries.
        local st_v msg_count protocol_count note_count relay_count lifecycle msgs_dir
        st_v="$(jq -r '.status' "$sj")"
        msgs_dir="$sd/messages"
        if [[ -d "$msgs_dir" ]]; then
          msg_count="$(ls "$msgs_dir" 2>/dev/null \
                        | grep -cE '^[0-9]{6}-(request|response|decision|note|relay)\.json$' || true)"
          protocol_count="$(ls "$msgs_dir" 2>/dev/null \
                              | grep -cE '^[0-9]{6}-(request|response|decision)\.json$' || true)"
          note_count="$(ls "$msgs_dir" 2>/dev/null \
                          | grep -cE '^[0-9]{6}-note\.json$' || true)"
          relay_count="$(ls "$msgs_dir" 2>/dev/null \
                          | grep -cE '^[0-9]{6}-relay\.json$' || true)"
        else
          msg_count=0
          protocol_count=0
          note_count=0
          relay_count=0
        fi
        if [[ "$st_v" == "open" ]]; then
          if (( protocol_count == 0 )); then lifecycle="init_only"; else lifecycle="active"; fi
        else
          lifecycle="$st_v"
        fi
        jq -c --arg lifecycle "$lifecycle" --argjson mc "$msg_count" --argjson pc "$protocol_count" --argjson nc "$note_count" --argjson rc "$relay_count" \
          '{session_id, status, lifecycle: $lifecycle, message_count: $mc, protocol_count: $pc, note_count: $nc, relay_count: $rc, topic, initiator_agent, reviewer_agent, created_at}' "$sj"
      done
      printf ']}\n'
    else
      for sd in "$SESSIONS_DIR"/*/; do
        [[ -d "$sd" ]] || continue
        local sj="$sd/session.json"
        [[ -f "$sj" ]] || continue
        local sid st topic msg_count protocol_count note_count relay_count lifecycle msgs_dir
        sid="$(jq -r '.session_id' "$sj")"
        st="$(jq -r '.status' "$sj")"
        topic="$(jq -r '.topic' "$sj")"
        msgs_dir="$sd/messages"
        if [[ -d "$msgs_dir" ]]; then
          msg_count="$(ls "$msgs_dir" 2>/dev/null \
                        | grep -cE '^[0-9]{6}-(request|response|decision|note|relay)\.json$' || true)"
          protocol_count="$(ls "$msgs_dir" 2>/dev/null \
                              | grep -cE '^[0-9]{6}-(request|response|decision)\.json$' || true)"
          note_count="$(ls "$msgs_dir" 2>/dev/null \
                          | grep -cE '^[0-9]{6}-note\.json$' || true)"
          relay_count="$(ls "$msgs_dir" 2>/dev/null \
                          | grep -cE '^[0-9]{6}-relay\.json$' || true)"
        else
          msg_count=0
          protocol_count=0
          note_count=0
          relay_count=0
        fi
        if [[ "$st" == "open" && "$protocol_count" == "0" ]]; then
          lifecycle="init_only"
        elif [[ "$st" == "open" ]]; then
          lifecycle="active"
        else
          lifecycle="$st"
        fi
        printf '%s  [%s]  msgs=%s (proto=%s, note=%s, relay=%s)  %s\n' "$sid" "$lifecycle" "$msg_count" "$protocol_count" "$note_count" "$relay_count" "$topic"
      done
    fi
    return 0
  fi

  validate_session_id "$session"
  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "list: session not found: $session"

  if [[ "$emit_json" == "true" ]]; then
    local first=1
    printf '{"schema_version":1,"kind":"agent_dialog_list_messages","session_id":"%s","messages":[' "$session"
    for mf in $(ls "$sdir/messages"/*.json 2>/dev/null | sort); do
      [[ -f "$mf" ]] || continue
      if (( first )); then first=0; else printf ','; fi
      jq -c '{message_id, kind, sender, recipient, created_at}' "$mf"
    done
    printf ']}\n'
  else
    for mf in $(ls "$sdir/messages"/*.json 2>/dev/null | sort); do
      [[ -f "$mf" ]] || continue
      local mid kind sender; mid="$(jq -r '.message_id' "$mf")"; kind="$(jq -r '.kind' "$mf")"; sender="$(jq -r '.sender' "$mf")"
      printf '%s  %s  from %s\n' "$mid" "$kind" "$sender"
    done
  fi
}

cmd_transcript() {
  local session=""
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      *) die 3 "transcript: unknown argument: $1" ;;
    esac
  done
  [[ -n "$session" ]] || die 3 "transcript: --session required"
  validate_session_id "$session"

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "transcript: session not found: $session"

  local sj="$sdir/session.json"
  printf '# Pingpong transcript: %s\n\n' "$session"
  printf -- '- Topic: %s\n' "$(jq -r '.topic' "$sj")"
  printf -- '- Initiator: %s\n' "$(jq -r '.initiator_agent' "$sj")"
  printf -- '- Reviewer:  %s\n' "$(jq -r '.reviewer_agent' "$sj")"
  printf -- '- Status:    %s\n' "$(jq -r '.status' "$sj")"
  printf -- '- Created:   %s\n\n' "$(jq -r '.created_at' "$sj")"

  # XAR-1A.6b PR review pass 5 F1: build a reverse supersedes map so each
  # superseded source message shows `Superseded-by: <replacement_id>` in
  # addition to the replacement message's `Supersedes` block. ADR-0004
  # INV-0004-8 requires both directions visible — without this, a stale
  # source message remains visually indistinguishable from live state.
  local _superseded_by_map="" _mf _sup_target _replacement_id
  for _mf in $(ls "$sdir/messages"/*.json 2>/dev/null | sort); do
    [[ -f "$_mf" ]] || continue
    _sup_target="$(jq -r '.body.supersedes // ""' "$_mf" 2>/dev/null)"
    if [[ -n "$_sup_target" ]]; then
      _replacement_id="$(jq -r '.message_id' "$_mf")"
      _superseded_by_map="${_superseded_by_map}${_sup_target}=${_replacement_id} "
    fi
  done

  for mf in $(ls "$sdir/messages"/*.json 2>/dev/null | sort); do
    [[ -f "$mf" ]] || continue
    local mid kind sender ts
    mid="$(jq -r '.message_id' "$mf")"
    kind="$(jq -r '.kind' "$mf")"
    sender="$(jq -r '.sender' "$mf")"
    ts="$(jq -r '.created_at' "$mf")"
    # XAR-1A.2c.a (round-2 codex F3 visibility): notes are supplemental and
    # must be visually distinguishable from protocol turns so a reviewer
    # scanning the transcript sees which messages drive the turn machine
    # and which are operator-supplemental context.
    case "$kind" in
      note)
        printf '### [NOTE] %s — %s — %s\n\n' "$mid" "$sender" "$ts"
        ;;
      relay)
        printf '### [RELAY] %s — %s → %s — %s\n\n' "$mid" "$sender" \
          "$(jq -r '.body.target_agent // "?"' "$mf")" "$ts"
        ;;
      *)
        printf '## %s — %s — %s — %s\n\n' "$mid" "$kind" "$sender" "$ts"
        ;;
    esac
    printf '```json\n'
    jq '.body' "$mf"
    printf '```\n\n'

    # XAR-1A.6b (ADR-0004 INV-0004-8): adjacent labeled blocks for new
    # delegation fields. Each present field gets its own labeled section so
    # a transcript reader sees Original instructions / Composed body /
    # Supersedes / Prior decision context as distinct semantic blocks
    # without parsing the raw JSON body above.
    if jq -e '.body.original_user_instructions // empty' "$mf" >/dev/null; then
      printf '**Original instructions:**\n\n```\n'
      jq -r '.body.original_user_instructions' "$mf"
      printf '```\n\n'
    fi
    if jq -e '.body.supersedes // empty' "$mf" >/dev/null; then
      printf '**Supersedes:** message_id `%s`\n\n' \
        "$(jq -r '.body.supersedes' "$mf")"
    fi
    # XAR-1A.6b PR review pass 5 F1: reverse-link rendering — show
    # `Superseded-by` on each source message whose id appears in the map.
    local _entry _replacement_for_this=""
    for _entry in $_superseded_by_map; do
      if [[ "$_entry" == "${mid}="* ]]; then
        _replacement_for_this="${_entry#*=}"
        break
      fi
    done
    if [[ -n "$_replacement_for_this" ]]; then
      printf '**Superseded-by:** message_id `%s` (this message is stale; the replacement carries the effective content)\n\n' \
        "$_replacement_for_this"
    fi
    if jq -e '(.body.prior_decision_context // []) | length > 0' "$mf" >/dev/null; then
      printf '**Prior decision context (auto-attached):**\n\n'
      jq -r '.body.prior_decision_context[] | "- `\(.finding_id)` \(.action): \(.reason_one_line)"' "$mf"
      printf '\n'
    fi
  done
}

cmd_abandon() {
  # Deterministic close path for init-only or mid-cycle orphan sessions.
  # `init` creates session.json in status="open" before any request is
  # written, so an interrupted /pingpong start leaves an empty open session
  # that the normal close path (write --kind decision) cannot terminate —
  # sequencing requires a preceding response, or a continue-decision, neither
  # of which exists in an init-only session. Without `abandon` operators had
  # to hand-edit session.json.status.
  #
  # The subcommand is intentionally separate from `write --kind decision`:
  # an abandoned session has no audit decision artifact, only a status
  # transition with an optional human reason. Treating it as a close decision
  # would force a finding-coverage gate that does not apply.
  local session="" reason="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --reason)  reason="$2";  shift 2 ;;
      --json)    emit_json="true"; shift ;;
      *) die 3 "abandon: unknown argument: $1" ;;
    esac
  done

  [[ -n "$session" ]] || die 3 "abandon: --session required"
  validate_session_id "$session"

  # Redaction risk gate for --reason. cmd_init scans --topic and cmd_write
  # scans body bodies, so abandon must run the same scan or operators could
  # paste a token into the reason and leak it into session.json + JSON
  # output untouched. Scan before any session-directory access so a rejected
  # reason produces a clean failure.
  if [[ -n "$reason" ]]; then
    # XAR-1A.2c.c (DEC-037): scan in-memory JSON probe; no temp file
    # required.
    local reason_probe_json
    reason_probe_json="$(jq -n --arg reason "$reason" '{abandon_reason: $reason}')"
    scan_for_secrets "$reason_probe_json"
  fi

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "abandon: session not found: $session"
  local sj="$sdir/session.json"
  [[ -f "$sj" ]] || die 3 "abandon: session.json missing in $sdir"

  local status; status="$(jq -r '.status' "$sj")"
  case "$status" in
    open) ;;
    abandoned)
      # Idempotent: re-abandoning is a no-op so operator tooling can call
      # abandon without first reading status.
      if [[ "$emit_json" == "true" ]]; then
        jq -n --arg sid "$session" \
          '{schema_version:1, kind:"agent_dialog_abandon", session_id:$sid, status:"abandoned", already:true}'
      else
        printf 'Session %s already abandoned\n' "$session"
      fi
      return 0
      ;;
    closed)
      die 4 "abandon: session $session is already closed; closed sessions cannot be re-abandoned"
      ;;
    *)
      die 4 "abandon: session $session has unknown status: $status"
      ;;
  esac

  acquire_lock "$sdir"

  # Re-read status under lock — another writer may have closed or abandoned
  # the session between our pre-lock check and lock acquisition. Treat the
  # raced abandon-after-abandon case as idempotent (round-5 codex P3): two
  # concurrent abandon attempts sample status=open in parallel, one commits
  # status=abandoned, and the second must still return the documented
  # already:true response instead of erroring out. Only "closed" is a real
  # conflict because abandon must not silently re-overwrite a closed
  # session.
  local status_locked; status_locked="$(jq -r '.status' "$sj")"
  case "$status_locked" in
    open) ;;
    abandoned)
      if [[ "$emit_json" == "true" ]]; then
        jq -n --arg sid "$session" \
          '{schema_version:1, kind:"agent_dialog_abandon", session_id:$sid, status:"abandoned", already:true}'
      else
        printf 'Session %s already abandoned (raced under lock)\n' "$session"
      fi
      return 0
      ;;
    closed)
      die 4 "abandon: session $session transitioned to closed under lock; not abandoning"
      ;;
    *)
      die 4 "abandon: session $session has unknown status under lock: $status_locked"
      ;;
  esac

  # XAR-1A.2c close partial-failure self-repair: same mismatch as the
  # cmd_write call site — a session whose latest protocol message is a
  # terminal close decision must not be re-classified as abandoned just
  # because the status flip was lost to a crash. Heal to closed, then
  # reject like the normal closed path.
  if _heal_interrupted_terminal_close "$sdir"; then
    die 4 "abandon: session $session is closed (status self-repaired from interrupted terminal close); closed sessions cannot be re-abandoned"
  fi

  # Orphan-only restriction (DEC-026; codex review rounds 3, 4, 7): abandon
  # is for sessions that have NOT received the next reviewer response yet —
  # init-only, request-only first round, or a multi-round session sitting
  # on a fresh round-N+1 request while waiting on the reviewer.
  #
  # Rule lock (round 7 design regroup): only the latest message kind
  # matters. The "prior response/decision exists" check that round 4
  # added (rejecting any multi-round session whose history includes a
  # response) was over-strict — it created a dead-end for the realistic
  # state `request → response → decision(continue) → request` where
  # neither abandon nor write --kind decision could close the session
  # (round 7 codex P2). The original audit concern from round 4 is
  # satisfied without that check because:
  #   - Any prior response's findings were already disposed by the
  #     prior decision (the helper's existing finding-coverage gate);
  #     the new abandon does not bypass that completed audit.
  #   - For an active reviewer response that still has undisposed
  #     findings, latest_kind == response and we reject below.
  #   - session.json gains `abandoned_at` + optional `abandon_reason`,
  #     which is the close-trail equivalent for status-only termination.
  #
  # The check runs under the lock because the latest message file set
  # can change between the pre-lock validation and the actual rename.
  local latest_kind; latest_kind="$(latest_message_kind "$sdir")"
  case "$latest_kind" in
    ""|request) ;;
    *) die 4 "abandon: latest message kind is '$latest_kind'; abandon is restricted to sessions waiting on a (next) reviewer response. Use /pingpong stop (close decision) instead." ;;
  esac

  local abandoned_at; abandoned_at="$(now_utc)"
  if [[ -n "$reason" ]]; then
    jq --arg reason "$reason" --arg ts "$abandoned_at" \
       '.status = "abandoned" | .abandoned_at = $ts | .abandon_reason = $reason' \
       "$sj" > "$sj.tmp"
  else
    jq --arg ts "$abandoned_at" \
       '.status = "abandoned" | .abandoned_at = $ts' \
       "$sj" > "$sj.tmp"
  fi
  mv "$sj.tmp" "$sj"

  if [[ "$emit_json" == "true" ]]; then
    if [[ -n "$reason" ]]; then
      jq -n --arg sid "$session" --arg ts "$abandoned_at" --arg reason "$reason" \
        '{schema_version:1, kind:"agent_dialog_abandon", session_id:$sid, status:"abandoned", abandoned_at:$ts, reason:$reason}'
    else
      jq -n --arg sid "$session" --arg ts "$abandoned_at" \
        '{schema_version:1, kind:"agent_dialog_abandon", session_id:$sid, status:"abandoned", abandoned_at:$ts}'
    fi
  else
    printf 'Session %s abandoned at %s\n' "$session" "$abandoned_at"
    [[ -n "$reason" ]] && printf 'Reason: %s\n' "$reason" || true
  fi
}

# XAR-1A.6b (ADR-0004 INV-0004-9): `compose-context` subcommand. Reads the
# prior decision body (--from-decision <message_id>; defaults to the latest
# decision in the session) and emits the `prior_decision_context` field
# value — a deterministic projection of decisions[] to {finding_id, action,
# reason_one_line} triples. Skill calls this on needs_user resume to populate
# the new request body's prior_decision_context, which helper then re-verifies
# under lock via validate_prior_decision_context_equality.
cmd_compose_context() {
  local session="" from_decision="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session)        session="$2";        shift 2 ;;
      --from-decision)  from_decision="$2";  shift 2 ;;
      --json)           emit_json="true";    shift ;;
      *) die 3 "compose-context: unknown argument: $1" ;;
    esac
  done

  [[ -n "$session" ]] || die 3 "compose-context: --session required"
  validate_session_id "$session"
  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "compose-context: session not found: $session"

  local decision_file
  if [[ -n "$from_decision" ]]; then
    validate_message_id "$from_decision"
    decision_file="$sdir/messages/${from_decision}-decision.json"
    [[ -f "$decision_file" ]] \
      || die 3 "compose-context: decision $from_decision not found in session $session"
  else
    local latest; latest="$(ls "$sdir/messages" 2>/dev/null \
      | grep -E '^[0-9]{6}-decision\.json$' \
      | sort -n | tail -1)"
    [[ -n "$latest" ]] \
      || die 3 "compose-context: no decision in session $session"
    decision_file="$sdir/messages/$latest"
    from_decision="$(echo "$latest" | cut -c1-6)"
  fi

  # XAR-1A.6b PR review pass 6 F1: gate compose-context to needs_user source
  # decisions only. ADR-0004 INV-0004-9 scopes the hybrid mechanism to
  # needs_user resume; general continue extension is Q-054 follow-up. Without
  # this gate, callers could ship Q-054 behavior accidentally.
  local _source_next_action; _source_next_action="$(jq -r '.body.next_action // ""' "$decision_file")"
  [[ "$_source_next_action" == "needs_user" ]] \
    || die 4 "compose-context: source decision $from_decision has next_action=${_source_next_action:-none}; only needs_user decisions are valid source (general continue extension is Q-054 follow-up)"
  # XAR-1A.6b PR review pass 4 F1: legacy decisions persisted before the
  # XAR-1A.6b schema tightening may have decisions[] entries missing
  # reason_one_line. Such projections produce null and the request-side
  # prior_decision_context validator rejects them — silent emission would
  # dead-end resume. Detect upfront and fail with an explicit migration error.
  local _legacy_count; _legacy_count="$(jq -c '
    [ .body.decisions[] | select((.reason_one_line // "") | type != "string" or length == 0) ] | length
  ' "$decision_file")"
  if [[ "$_legacy_count" != "0" ]]; then
    die 4 "compose-context: source decision $from_decision has $_legacy_count entry(s) missing non-empty reason_one_line (legacy schema pre-XAR-1A.6b). Resume needs a new decision write with full triples."
  fi
  local triples_json; triples_json="$(jq -c '
    [ .body.decisions[] | {finding_id, action, reason_one_line} ]
  ' "$decision_file")"

  if [[ "$emit_json" == "true" ]]; then
    jq -n \
      --arg sid "$session" \
      --arg did "$from_decision" \
      --argjson ctx "$triples_json" \
      '{schema_version: 1, kind: "agent_dialog_compose_context", session_id: $sid, from_decision: $did, prior_decision_context: $ctx}'
  else
    printf 'Session: %s\n' "$session"
    printf 'From decision: %s\n' "$from_decision"
    printf 'prior_decision_context:\n'
    jq -r '.[] | "  - finding_id=\(.finding_id) action=\(.action) reason=\(.reason_one_line)"' <<<"$triples_json"
  fi
}

cmd_cleanup() {
  # Operator-facing recovery from a stale-lock outage that
  # `acquire_lock` cannot self-recover (SIGKILL during the recovery
  # critical section). Removes `.write.lock` and `.write.recovery`
  # only when no live writer would race with the removal.
  #
  # Serialization: cleanup acquires `.write.recovery` itself before
  # touching `.write.lock`, using the same recovery-lock primitive
  # that normal recovery uses. This closes the cleanup TOCTOU codex
  # review 2026-05-27 round 8 flagged — a writer cannot complete
  # stale-lock recovery and acquire a fresh live lock between
  # cleanup's liveness check and its `rm`, because the recovery
  # lock serialises both paths through the same gate.
  #
  # If `.write.recovery` is already stale, cleanup force-removes it
  # (that is the very reason cleanup exists) and then competes to
  # claim a fresh recovery lock. Two concurrent cleanups resolve
  # the same way two concurrent recoveries do: one wins, the other
  # observes the live winner and refuses with `recovery in progress`
  # — the operator retries.
  local session="" emit_json="false" force="false"
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --json)    emit_json="true"; shift ;;
      --force)   force="true"; shift ;;
      *) die 3 "cleanup: unknown argument: $1" ;;
    esac
  done

  [[ -n "$session" ]] || die 3 "cleanup: --session required"
  validate_session_id "$session"

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "cleanup: session not found: $session"

  local lockfile="$sdir/.write.lock"
  local recovery="$sdir/.write.recovery"
  local removed=()

  _check_and_remove_stale_lock() {
    local f="$1" label="$2"
    if [[ ! -L "$f" && ! -e "$f" ]]; then
      return 0
    fi

    if [[ -L "$f" ]]; then
      # Symlink backend: liveness via readlink + _pid_is_live
      # (positive-decimal PID validation + kill -0).
      local pid
      pid="$(readlink "$f" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && _pid_is_live "$pid"; then
        # Live PID owns the lock. Codex review 2026-05-27 round 10
        # flagged that `--force` previously removed live locks here,
        # which would let `cleanup --force` strip an in-flight
        # writer's mutex and let a second process `ln -s` a new
        # lockfile and enter the critical section concurrently.
        # Live locks ALWAYS refuse regardless of --force; --force is
        # only for ownerless / dead-PID / foreign-regular-file
        # debris.
        die 4 "cleanup: $label held by live PID $pid; live locks are never removed by cleanup (stop or kill the writer first if needed)"
      fi
      rm -f "$f"
      removed+=("$label (symlink, was PID ${pid:-<malformed>})")
      return 0
    fi

    # Regular file at the lockfile path. The current backend only
    # creates symlinks, so a regular file is foreign — it could be
    # a manual `touch` from the operator, debris from a different
    # tool, or an unexpected file. Without an out-of-band liveness
    # primitive we cannot prove no live process depends on it, so
    # refuse to remove unless the operator explicitly overrides.
    if [[ "$force" != "true" ]]; then
      die 4 "cleanup: $label is an unexpected regular file (not a symlink lock); pass --force to remove"
    fi
    rm -f "$f"
    removed+=("$label (forced removal of regular file)")
  }

  # Claim the recovery lock for ourselves so our lockfile rm is
  # serialised against any concurrent helper recovery path. Codex
  # review 2026-05-27 round 9 flagged two earlier designs:
  #   (a) auto-removing stale recovery before re-acquiring opens a
  #       concurrent-cleanup race — two cleanups both observe stale
  #       state, one acquires fresh, the other rm's the fresh
  #       acquisition; same TOCTOU the recovery primitive was meant
  #       to close.
  #   (b) holding recovery across `die` paths leaks the lock when
  #       cleanup refuses (foreign regular file, live main lock).
  #
  # Resolution: do not auto-rm stale recovery. Try `ln -s` directly;
  # any failure surfaces a precise diagnostic naming what to do
  # next. Install an ownership-checked EXIT trap so any exit path
  # (success, die, signal) releases the recovery we hold.
  # Arm ownership-checked traps BEFORE the `ln -s` syscall. Codex
  # review 2026-05-27 round 11 flagged the previous post-acquire
  # trap installation: a kill in the gap between `ln -s` returning
  # and `trap` being installed would leave `.write.recovery` owned
  # by a dead PID. The traps only rm when the owner matches our PID,
  # so installing them before acquisition is safe — if we never end
  # up owning recovery, the trap is a no-op on exit.
  _LOCK_TRAP_LOCKFILE=""
  _LOCK_TRAP_RECOVERY="$recovery"
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"' EXIT
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"; trap - INT; kill -INT $$' INT
  trap '_release_owned_locks "$_LOCK_TRAP_LOCKFILE" "$_LOCK_TRAP_RECOVERY" "$$"; trap - TERM; kill -TERM $$' TERM

  local rec_err
  rec_err="$(ln -s "$$" "$recovery" 2>&1)" || {
    local rpid
    rpid="$(readlink "$recovery" 2>/dev/null || true)"
    if [[ -n "$rpid" ]] && _pid_is_live "$rpid"; then
      # PID-only liveness can produce false positives when the OS
      # has reused the recovered PID for an unrelated process
      # (codex review 2026-05-27 round 12). Recovery is a single
      # readlink + single rm, so an observed live recovery that
      # persists for any noticeable time is more likely a false
      # positive than a real in-flight recovery. Operators can
      # verify with \`ps $rpid\` and, if the PID is not an
      # agent-dialog writer, escape via manual rm.
      die 4 "cleanup: recovery at $recovery appears held by live PID $rpid; if this is a real active recovery, wait for it to finish; if PID $rpid is unrelated (kernel PID reuse — verify with 'ps $rpid'), remove the file manually: rm '$recovery'; then rerun cleanup --session $session"
    fi
    if [[ -L "$recovery" || -e "$recovery" ]]; then
      # Stale recovery file (dead owner) blocking our acquisition.
      # Codex review round 14: the original "operator must rm
      # manually" UX defeated cleanup's purpose. Allow --force to
      # rm-and-retry inside cleanup, with an explicit trade-off
      # acknowledgment: concurrent --force cleanups can race on
      # this rm, same shape as the 3-way race we closed for normal
      # writers. The operator who passes --force accepts that
      # multiple concurrent cleanup invocations are unsafe.
      if [[ "$force" != "true" ]]; then
        die 4 "cleanup: stale recovery at $recovery (was PID ${rpid:-<unknown>}); pass --force to clear it and proceed (single-cleanup-at-a-time contract — do not run concurrent --force cleanups)"
      fi
      rm -f "$recovery"
      removed+=(".write.recovery (forced clear of stale PID ${rpid:-<unknown>})")
      # Retry acquisition. If a concurrent --force cleanup grabbed
      # the slot in between, refuse — we will not steal a freshly-
      # acquired recovery lock even with --force.
      if ! ln -s "$$" "$recovery" 2>/dev/null; then
        local rpid_now
        rpid_now="$(readlink "$recovery" 2>/dev/null || true)"
        die 4 "cleanup: recovery taken by PID ${rpid_now:-?} during --force clear; retry"
      fi
    else
      die 4 "cleanup: recovery cannot be created in $sdir: ${rec_err:-symlink creation failed}"
    fi
  }

  _check_and_remove_stale_lock "$lockfile" ".write.lock"

  if [[ "$emit_json" == "true" ]]; then
    local removed_json
    removed_json="$(printf '%s\n' "${removed[@]:-}" | jq -R . | jq -s -c 'map(select(length > 0))')"
    jq -n --arg sid "$session" --argjson removed "$removed_json" \
      '{schema_version:1, kind:"agent_dialog_cleanup", session_id:$sid, removed:$removed}'
  else
    if [[ "${#removed[@]}" -eq 0 ]]; then
      printf 'Session %s: no stale lock files to clean\n' "$session"
    else
      printf 'Session %s: cleaned\n' "$session"
      local entry
      for entry in "${removed[@]}"; do
        printf '  - %s\n' "$entry"
      done
    fi
  fi
}

# --- Readiness-assist (XAR-1Ba.0) -------------------------------------------
#
# Deterministic "whose turn is it" projection + foreground poller. Both are
# READ-ONLY: they never mutate session state, never take the write lock, and
# never author message content. Turn detection is computed from the latest
# protocol message (kind + session roles), NOT from an inbox cursor or lease
# (DEC-011's cursor rejection stays intact). A stale answer is harmless by
# design — the worst case is a notification for a turn that just changed,
# and actual write correctness is still enforced by cmd_write's under-lock
# sequencing validation. This is what makes the poller safe to run from
# wake-up/scheduled contexts (AGENTS.policy.md: poll + report only).

_whose_turn_json() {
  # Emits a compact JSON object describing the next protocol actor for a
  # session, or returns non-zero with a message on stderr for hard errors
  # (missing session). Terminal sessions are NOT errors — they emit
  # next_actor=none so pollers can distinguish "ended" from "broken".
  local session="$1"
  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || { echo "whose-turn: session not found: $session" >&2; return 3; }
  local sj="$sdir/session.json"
  [[ -f "$sj" ]] || { echo "whose-turn: session.json missing in $sdir" >&2; return 3; }

  local status initiator reviewer
  status="$(jq -r '.status' "$sj")"
  initiator="$(jq -r '.initiator_agent' "$sj")"
  reviewer="$(jq -r '.reviewer_agent' "$sj")"

  local latest_file latest_kind="" latest_id="" latest_sender="" latest_next_action=""
  latest_file="$(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-(request|response|decision)\.json$' \
    | sort -n | tail -1 || true)"
  if [[ -n "$latest_file" ]]; then
    latest_id="${latest_file%%-*}"
    latest_kind="${latest_file#*-}"; latest_kind="${latest_kind%.json}"
    latest_sender="$(jq -r '.sender // ""' "$sdir/messages/$latest_file")"
    if [[ "$latest_kind" == "decision" ]]; then
      latest_next_action="$(jq -r '.body.next_action // ""' "$sdir/messages/$latest_file")"
    fi
  fi

  # next_actors is an ARRAY: adversarial_dialogue always yields zero or
  # one entry, but parallel_review rounds can have BOTH agents pending a
  # response at once, so the schema is plural from day one.
  local dmode; dmode="$(_session_dialogue_mode "$sj")"
  # terminal: no further protocol turns will ever occur. True for
  # closed/abandoned status AND for the interrupted-terminal-close state
  # (latest decision session_close=true while a crash left status=open).
  local next_actors='[]' next_kind="none" waiting_on_user="false" terminal="false"
  [[ "$status" == "open" ]] || terminal="true"
  if [[ "$status" == "open" ]]; then
    case "$latest_kind" in
      "")        next_actors="$(jq -cn --arg a "$initiator" '[$a]')"; next_kind="request" ;;
      request|response)
        if [[ "$dmode" == "parallel_review" ]]; then
          # XAR-1A.7 parallel_review: every session agent that has not
          # yet written its effective response this round is pending.
          # When both responses are in, the protocol waits on the USER's
          # decision (Q-052) — no agent owes a protocol message, but a
          # transcribing chat can act once the user supplies dispositions.
          local pending; pending='[]'
          local responded=" " rf rsender
          while IFS= read -r rf; do
            [[ -n "$rf" ]] || continue
            rsender="$(jq -r '.sender // ""' "$sdir/messages/$rf")"
            responded="${responded}${rsender} "
          done < <(_round_response_files "$sdir")
          local a
          for a in "$initiator" "$reviewer"; do
            [[ "$responded" == *" $a "* ]] && continue
            pending="$(jq -c --arg a "$a" '. + [$a]' <<<"$pending")"
          done
          if [[ "$pending" != "[]" ]]; then
            next_actors="$pending"; next_kind="response"
          else
            next_kind="decision"; waiting_on_user="true"
          fi
        else
          if [[ "$latest_kind" == "request" ]]; then
            next_actors="$(jq -cn --arg a "$reviewer" '[$a]')"; next_kind="response"
          else
            next_actors="$(jq -cn --arg a "$initiator" '[$a]')"; next_kind="decision"
          fi
        fi
        ;;
      decision)
        case "$latest_next_action" in
          continue)
            # Next protocol step is the initiator's next request, but the
            # delegation contract needs fresh user instructions first.
            next_actors="$(jq -cn --arg a "$initiator" '[$a]')"; next_kind="request"; waiting_on_user="true" ;;
          needs_user)
            next_actors="$(jq -cn --arg a "$initiator" '[$a]')"; next_kind="request"; waiting_on_user="true" ;;
          close)
            # PR #82 codex P2: distinguish close-intent from an
            # interrupted terminal close. close-intent
            # (session_close=false) waits on the operator's explicit
            # /pingpong stop. session_close=true with status still open
            # is the crash window the next WRITE self-repairs — this
            # read-only projection must not mutate, but it must report
            # the session as terminal so pollers stop waiting on it.
            local _close_flag
            _close_flag="$(jq -r '.body.session_close // false' "$sdir/messages/$latest_file" 2>/dev/null)"
            if [[ "$_close_flag" == "true" ]]; then
              terminal="true"; next_kind="none"
            else
              next_kind="none"; waiting_on_user="true"
            fi ;;
          *)
            next_kind="none" ;;
        esac
        ;;
    esac
  fi

  jq -n \
    --arg sid "$session" \
    --arg status "$status" \
    --arg dmode "$dmode" \
    --arg lid "$latest_id" \
    --arg lkind "$latest_kind" \
    --arg lsender "$latest_sender" \
    --arg lnext "$latest_next_action" \
    --argjson next_actors "$next_actors" \
    --arg next_kind "$next_kind" \
    --argjson waiting "$waiting_on_user" \
    --argjson terminal "$terminal" \
    '{schema_version: 1, kind: "agent_dialog_whose_turn", session_id: $sid,
      status: $status, dialogue_mode: $dmode, terminal: $terminal,
      latest_protocol: (if $lid == "" then null else
        ({message_id: $lid, kind: $lkind, sender: $lsender}
         + (if $lnext == "" then {} else {next_action: $lnext} end)) end),
      next_actors: $next_actors,
      next_actor: (if ($next_actors | length) == 1 then $next_actors[0] else (if ($next_actors | length) == 0 then "none" else "multiple" end) end),
      next_kind: $next_kind,
      waiting_on_user: $waiting}'
}

cmd_whose_turn() {
  local session="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      --json)    emit_json="true"; shift ;;
      *) die 3 "whose-turn: unknown argument: $1" ;;
    esac
  done
  [[ -n "$session" ]] || die 3 "whose-turn: --session required"
  validate_session_id "$session"

  local obs rc=0
  obs="$(_whose_turn_json "$session")" || rc=$?
  (( rc == 0 )) || exit "$rc"

  if [[ "$emit_json" == "true" ]]; then
    printf '%s\n' "$obs"
  else
    local actor kind_v waiting status terminal_flag
    actor="$(jq -r '.next_actor' <<<"$obs")"
    kind_v="$(jq -r '.next_kind' <<<"$obs")"
    waiting="$(jq -r '.waiting_on_user' <<<"$obs")"
    status="$(jq -r '.status' <<<"$obs")"
    terminal_flag="$(jq -r '.terminal' <<<"$obs")"
    if [[ "$terminal_flag" == "true" ]]; then
      printf 'Turn: none (session terminal; status: %s)\n' "$status"
    elif [[ "$actor" == "none" ]]; then
      printf 'Turn: none (session status: %s)\n' "$status"
    else
      printf 'Turn: %s (next: %s)%s\n' "$actor" "$kind_v" \
        "$([[ "$waiting" == "true" ]] && printf ' — waiting on user input' || true)"
    fi
  fi
}

cmd_watch() {
  # Foreground readiness poller. Re-computes whose-turn every --interval
  # seconds and exits as soon as the watched agent owns the next protocol
  # turn. Exit codes follow the codex-loop polling shape so interactive
  # turns (or a poll-only ScheduleWakeup re-run) can branch on them:
  #   0  ready — it is --agent's turn now (details on stdout)
  #   2  timeout — turn did not arrive within --timeout
  #   4  terminal — session closed/abandoned (no further turns)
  #   3  usage / session not found
  # No daemonization, no background loop: callers re-run this foreground
  # command per wait cycle, exactly like wait-codex-review.sh.
  local session="" agent="" interval=10 timeout=600 notify="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --session)  session="$2";  shift 2 ;;
      --agent)    agent="$2";    shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout)  timeout="$2";  shift 2 ;;
      --notify)   notify="$2";   shift 2 ;;
      --json)     emit_json="true"; shift ;;
      *) die 3 "watch: unknown argument: $1" ;;
    esac
  done
  [[ -n "$session" ]] || die 3 "watch: --session required"
  validate_session_id "$session"
  case "$agent" in
    codex|claude) ;;
    *) die 3 "watch: --agent must be codex|claude" ;;
  esac
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || die 3 "watch: --interval must be a positive integer"
  [[ "$timeout"  =~ ^[1-9][0-9]*$ ]] || die 3 "watch: --timeout must be a positive integer"
  case "$notify" in
    ""|desktop) ;;
    *) die 3 "watch: --notify supports only: desktop" ;;
  esac

  local waited=0 polls=0
  while true; do
    local obs rc=0
    obs="$(_whose_turn_json "$session")" || rc=$?
    (( rc == 0 )) || exit "$rc"
    polls=$((polls + 1))

    local status kind_v waiting agent_ready terminal_flag
    status="$(jq -r '.status' <<<"$obs")"
    kind_v="$(jq -r '.next_kind' <<<"$obs")"
    waiting="$(jq -r '.waiting_on_user' <<<"$obs")"
    agent_ready="$(jq -r --arg a "$agent" '.next_actors | index($a) != null' <<<"$obs")"
    terminal_flag="$(jq -r '.terminal' <<<"$obs")"

    # PR #82 codex P2: .terminal covers closed/abandoned status AND the
    # interrupted-terminal-close state (session_close=true decision with
    # status stuck open) — pollers must stop waiting either way.
    if [[ "$terminal_flag" == "true" ]]; then
      # PR #82 codex P2: machine callers need the observation on
      # non-ready exits too — emit the JSON before the exit code.
      if [[ "$emit_json" == "true" ]]; then
        jq -n --arg sid "$session" --arg agent "$agent" --arg status "$status" \
          --argjson polls "$polls" \
          '{schema_version: 1, kind: "agent_dialog_watch", session_id: $sid,
            agent: $agent, ready: false, result: "terminal",
            session_status: $status, polls: $polls}'
      fi
      echo "watch: session $session is terminal (status: $status) — no further turns" >&2
      exit 4
    fi

    if [[ "$agent_ready" == "true" ]]; then
      if [[ "$notify" == "desktop" ]] && command -v osascript >/dev/null 2>&1; then
        # Best-effort notification; readiness signaling itself is the
        # stdout line + exit code, so a notification failure is non-fatal.
        osascript -e "display notification \"pingpong: ${agent} turn (${kind_v}) — session ${session}\" with title \"agent-dialog watch\"" \
          >/dev/null 2>&1 || true
      fi
      if [[ "$emit_json" == "true" ]]; then
        jq -n --arg sid "$session" --arg agent "$agent" --arg next_kind "$kind_v" \
          --argjson waiting "$waiting" --argjson polls "$polls" \
          '{schema_version: 1, kind: "agent_dialog_watch", session_id: $sid,
            agent: $agent, ready: true, next_kind: $next_kind,
            waiting_on_user: $waiting, polls: $polls}'
      else
        printf 'READY: %s turn (next: %s) in session %s%s\n' "$agent" "$kind_v" "$session" \
          "$([[ "$waiting" == "true" ]] && printf ' — waiting on user input' || true)"
      fi
      return 0
    fi

    if (( waited >= timeout )); then
      local current_turn
      current_turn="$(jq -r '.next_actors | join(",") | if . == "" then "none" else . end' <<<"$obs")"
      if [[ "$emit_json" == "true" ]]; then
        jq -n --arg sid "$session" --arg agent "$agent" --arg turn "$current_turn" \
          --arg next_kind "$kind_v" --argjson waiting "$waiting" --argjson polls "$polls" \
          --argjson waited "$waited" \
          '{schema_version: 1, kind: "agent_dialog_watch", session_id: $sid,
            agent: $agent, ready: false, result: "timeout",
            current_turn: $turn, next_kind: $next_kind,
            waiting_on_user: $waiting, waited_seconds: $waited, polls: $polls}'
      fi
      echo "watch: timeout after ${waited}s — current turn: $current_turn (next: $kind_v)" >&2
      exit 2
    fi
    # PR #82 codex P3: never sleep past the deadline — an interval larger
    # than the remaining budget would block beyond the advertised
    # timeout (and could even report ready after it elapsed).
    local remaining=$((timeout - waited))
    local nap=$(( interval < remaining ? interval : remaining ))
    sleep "$nap"
    waited=$((waited + nap))
  done
}

# --- Main -------------------------------------------------------------------

main() {
  if [[ $# -lt 1 ]]; then
    usage >&2
    exit 3
  fi
  require_cmd jq
  mkdir -p "$SESSIONS_DIR"
  _load_user_redaction_patterns

  local sub="$1"; shift
  case "$sub" in
    init)       cmd_init "$@" ;;
    write)      cmd_write "$@" ;;
    read)       cmd_read "$@" ;;
    list)       cmd_list "$@" ;;
    transcript) cmd_transcript "$@" ;;
    abandon)    cmd_abandon "$@" ;;
    compose-context) cmd_compose_context "$@" ;;
    cleanup)    cmd_cleanup "$@" ;;
    whose-turn) cmd_whose_turn "$@" ;;
    watch)      cmd_watch "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 3 ;;
  esac
}

main "$@"
