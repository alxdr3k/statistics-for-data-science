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
  init        --initiator codex|claude --topic <text> [--repo <path>] [--json]
  write       --session <id> --kind request|response|decision|note
              --sender codex|claude|user [--recipient <agent>]
              [--parent <message_id>] --body-file <path> [--json]
  read        --session <id> [--message <id>] [--json]
  list        [--session <id>] [--json]
  transcript  --session <id>
  abandon     --session <id> [--reason <text>] [--json]
  compose-context --session <id> [--from-decision <message_id>] [--json]

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
  # Symlink-based lock with atomic-rename stale salvage.
  #
  # `ln -s $$ lockfile` collapses lock acquisition and owner-PID recording
  # into one atomic syscall. Two racers cannot both create the lock.
  #
  # Stale recovery is the tricky part. Naive `rm -f $lockfile` after
  # observing a dead PID is racy: writer A removes the stale lock and
  # creates a new live one, then writer B (which already decided the lock
  # was stale a moment earlier) deletes A's live lock and creates its own.
  # Both writers would now believe they hold the lock.
  #
  # Fix: salvage the stale lock via atomic rename to a per-process unique
  # path. `mv` of a single file is atomic; only one racer can move the
  # current lockfile out from under everyone else. After moving it we
  # re-confirm the target was still dead before discarding the salvaged
  # entry. Other racers see "lockfile gone" and loop back to the create.
  #
  # The exit trap also re-checks ownership before removing — if some
  # later process took the lock (after our PID died or the lock was
  # released elsewhere), we must not delete their live lock.
  local sdir="$1" lockfile="$sdir/.write.lock"
  while true; do
    local ln_err
    ln_err="$(ln -s "$$" "$lockfile" 2>&1)" && {
      trap "_release_owned_lock '$lockfile' '$$'" EXIT
      return 0
    }

    # `ln -s` failed. The loop below assumes the failure was EEXIST
    # (lockfile already present — contention) and tries either live-PID
    # rejection or stale salvage. If the failure was for a different
    # reason — sandbox EACCES, read-only fs, ENOSPC, ENOENT — no
    # lockfile was ever created, `readlink` returns empty, the live-PID
    # check is skipped, salvage `mv` has nothing to move, and the loop
    # spins forever (observed under Codex sandbox writing into
    # $HOME/.agent-dialog).
    #
    # An absent lockfile after `ln -s` failure has two valid causes:
    #   (a) Real write failure — directory is unwritable so the symlink
    #       was never created.
    #   (b) Race — `ln -s` failed because the lockfile existed at the
    #       syscall, but another writer salvaged it before we reached
    #       this check.
    # Codex review 2026-05-27 (round 2) flagged the original bare
    # absence check: it died on (b) as well, turning a normal stale-
    # lock recovery race into a hard error. Codex review round 3
    # additionally flagged a regular-file writability probe as too
    # permissive — on filesystems that allow regular files but reject
    # symlinks (FAT/exFAT, some network mounts), the probe would
    # succeed while every `ln -s` keeps failing, recreating the
    # infinite loop. Probe with a symlink instead: it is the exact
    # syscall that drives lock creation, so its success/failure is
    # the correct discriminator. If the symlink probe succeeds we
    # are in case (b); retry the loop. If it fails the directory
    # rejects symlink creation; surface the captured `ln` error so
    # the caller does not hang.
    if [[ ! -L "$lockfile" && ! -e "$lockfile" ]]; then
      local probe="$lockfile.probe.$$.$RANDOM"
      if ln -s "probe-$$" "$probe" 2>/dev/null; then
        rm -f "$probe"
        continue
      fi
      die 5 "write lock cannot be created in $sdir: ${ln_err:-symlink creation failed without diagnostic}"
    fi

    # Lock exists. Read the target PID in one syscall.
    local existing_pid=""
    existing_pid="$(readlink "$lockfile" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      die 5 "write lock held by live PID $existing_pid at $lockfile"
    fi

    # Target PID is missing or dead. Salvage via atomic rename so that
    # at most one racer can claim the right to remove the stale lock.
    local salvage="$lockfile.salvage.$$.$RANDOM"
    local mv_err
    mv_err="$(mv "$lockfile" "$salvage" 2>&1)" && {
      # We hold the salvaged stale lock. Re-confirm the salvaged target
      # was indeed dead — if a fresh owner had grabbed the lock between
      # our readlink and mv, we would have salvaged a *live* lock by
      # mistake and must abort instead of silently consuming it.
      local salvaged_pid=""
      salvaged_pid="$(readlink "$salvage" 2>/dev/null || true)"
      if [[ -n "$salvaged_pid" ]] && kill -0 "$salvaged_pid" 2>/dev/null; then
        # Put the live lock back where we found it. If something else
        # already created a new lockfile in the meantime, drop ours
        # rather than overwrite — the other lock is the authoritative
        # one and ours is the salvaged stale state.
        if ! mv -n "$salvage" "$lockfile" 2>/dev/null; then
          rm -f "$salvage"
        fi
        die 5 "write lock raced from PID $salvaged_pid; aborting salvage"
      fi
      printf 'agent-dialog: stale lock from PID %s, recovering\n' "${existing_pid:-?}" >&2
      rm -f "$salvage"
      # Loop and try the atomic ln -s create.
      continue
    }
    # `mv` failed. Two cases must be distinguished:
    #   (a) Another racer salvaged the stale lockfile out from under us
    #       (the lockfile is now gone). Retry — our next `ln -s` should
    #       succeed.
    #   (b) The session directory is not writable (sandbox EACCES,
    #       read-only fs, ENOSPC). The stale lockfile is still present
    #       and cannot be renamed. The previous behaviour treated every
    #       `mv` failure as case (a) and looped forever; codex review
    #       2026-05-27 flagged this. Detect (b) by observing that the
    #       lockfile is still here and fail fast with the captured `mv`
    #       diagnostic so the caller can surface the real filesystem
    #       error instead of hanging.
    if [[ -L "$lockfile" || -e "$lockfile" ]]; then
      die 5 "write lock stale-salvage failed in $sdir: ${mv_err:-cannot rename .write.lock (filesystem not writable?)}"
    fi
    # Lockfile disappeared between our ln -s and mv — another racer
    # salvaged it. Loop and retry.
  done
}

_release_owned_lock() {
  # Only remove the lock if it still records our PID. Otherwise a later
  # process has already claimed it and we must not strip them.
  local lockfile="$1" my_pid="$2" owner
  owner="$(readlink "$lockfile" 2>/dev/null || true)"
  if [[ "$owner" == "$my_pid" ]]; then
    rm -f "$lockfile"
  fi
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

validate_role() {
  # XAR-1A.2c.c: body input is the JSON snapshot from cmd_write
  # (DEC-037) so target_agent enforcement reads the same bytes that
  # validate_body checked and persist will write.
  local kind="$1" sender="$2" initiator="$3" reviewer="$4" body_json="${5:-}"
  case "$kind" in
    request)
      [[ "$sender" == "$initiator" ]] \
        || die 4 "request sender must be initiator ($initiator), got $sender"
      ;;
    response)
      [[ "$sender" == "$reviewer" ]] \
        || die 4 "response sender must be reviewer ($reviewer), got $sender"
      ;;
    decision)
      [[ "$sender" == "$initiator" || "$sender" == "user" ]] \
        || die 4 "decision sender must be initiator ($initiator) or user, got $sender"
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

  local response_file; response_file="$(preceding_response_file_for_decision "$sdir" "$decision_file")"
  [[ -n "$response_file" ]] || return 1

  local resp_findings; resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$response_file")"
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

validate_sequencing() {
  # XAR-1A.2c.c: body input is cmd_write's JSON snapshot (DEC-037).
  # source_message_ids existence still resolves against $sdir/messages,
  # which is filesystem state outside operator-controlled inputs.
  local kind="$1" sdir="$2" body_json="${3:-}"
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
      local _last_resp_for_sup; _last_resp_for_sup="$(ls "$sdir/messages" 2>/dev/null \
        | grep -E '^[0-9]{6}-response\.json$' \
        | sort -n | tail -1)"
      if [[ -n "$_last_resp_for_sup" ]]; then
        local _resp_findings; _resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$_last_resp_for_sup")"
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
      [[ "$latest" == "request" ]] \
        || die 4 "response requires the latest message to be request (got: ${latest:-none})"
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
          # Finding coverage: if the latest response recorded findings, the
          # decision must dispose every finding_id. Empty findings keeps an
          # empty decisions array valid (used by /pingpong stop on clean reviews).
          local last_response_file; last_response_file="$(ls "$sdir/messages" 2>/dev/null \
            | grep -E '^[0-9]{6}-response\.json$' \
            | sort -n | tail -1)"
          local resp_findings; resp_findings="$(jq -c '.body.findings // []' "$sdir/messages/$last_response_file")"
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
  local kind="$1" sender="$2" sdir="$3" body_json="$4"
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
  local kind_ids; kind_ids="$(ls "$sdir/messages" 2>/dev/null \
    | grep -E "^[0-9]{6}-${kind}\.json$" \
    | sed -E "s/-${kind}\.json$//" \
    | sort)"
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
  #     greater than target_id (any kind in request/response/decision)
  local target_num=$((10#$target_id))
  local downstream=""
  while IFS= read -r mfile; do
    [[ -n "$mfile" ]] || continue
    local mbase; mbase="$(basename "$mfile")"
    local mid_str; mid_str="$(echo "$mbase" | cut -c1-6)"
    local mid_num=$((10#$mid_str))
    if (( mid_num > target_num )); then
      downstream="${downstream}${mbase} "
    fi
  done < <(find "$sdir/messages" -maxdepth 1 -type f \( -name "*-request.json" -o -name "*-response.json" -o -name "*-decision.json" \) | sort)
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
  jq -e '(has("prior_decision_context") | not)' <<<"$body_json" >/dev/null && return 0
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
  local initiator="" topic="" repo="" emit_json="false"
  while (( $# )); do
    case "$1" in
      --initiator) initiator="$2"; shift 2 ;;
      --topic)     topic="$2";     shift 2 ;;
      --repo)      repo="$2";      shift 2 ;;
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

  jq -n \
    --arg schema "$SCHEMA_VERSION" \
    --arg sid "$sid" \
    --arg ts "$created_at" \
    --arg topic "$topic" \
    --arg initiator "$initiator" \
    --arg reviewer "$reviewer" \
    --argjson repo "$repo_json" \
    '{schema_version: $schema, session_id: $sid, created_at: $ts, status: "open", topic: $topic, initiator_agent: $initiator, reviewer_agent: $reviewer, mode: "peer-required", repo: $repo}' \
    > "$sdir/session.json.tmp"
  mv "$sdir/session.json.tmp" "$sdir/session.json"

  if [[ "$emit_json" == "true" ]]; then
    jq -n --arg sid "$sid" --arg sdir "$sdir" \
      '{schema_version: 1, kind: "agent_dialog_init", session_id: $sid, session_dir: $sdir}'
  else
    printf 'Session: %s\n' "$sid"
    printf 'Dir:     %s\n' "$sdir"
    printf 'Roles:   initiator=%s reviewer=%s\n' "$initiator" "$reviewer"
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

  validate_role "$kind" "$sender" "$initiator" "$reviewer" "$body_json"

  acquire_lock "$sdir"
  # Re-read status under lock to close the abandon/close race: cmd_abandon
  # and cmd_write's terminal close both flip session.json.status without
  # writing a protocol message, so an out-of-lock status snapshot can be
  # stale by the time we hold the lock. Sequencing alone cannot catch this
  # because there is no terminal message to compare against (abandon is a
  # status-only transition).
  local status_locked; status_locked="$(jq -r '.status' "$sj")"
  [[ "$status_locked" == "open" ]] || die 4 "write: session $session is $status_locked (after lock)"
  # Re-read latest under lock and validate sequencing (decision coverage
  # needs the body to compare against the latest response's findings).
  validate_sequencing "$kind" "$sdir" "$body_json"

  # XAR-1A.6b (ADR-0004 INV-0004-5/-6/-7): supersedes 5-check under the
  # same lock. validate-if-present — no-op when body has no supersedes.
  validate_supersedes "$kind" "$sender" "$sdir" "$body_json"

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
    -h|--help|help) usage ;;
    *) usage >&2; exit 3 ;;
  esac
}

main "$@"
