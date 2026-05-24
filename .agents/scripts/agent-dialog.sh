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

die() {
  local code="$1"; shift
  printf 'agent-dialog: %s\n' "$*" >&2
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 4 "missing required command: $1"
}

usage() {
  cat <<'EOF'
usage: agent-dialog.sh <subcommand> [options]

Subcommands:
  init        --initiator codex|claude --topic <text> [--repo <path>] [--json]
  write       --session <id> --kind request|response|decision
              --sender codex|claude|user [--recipient <agent>]
              [--parent <message_id>] --body-file <path> [--json]
  read        --session <id> [--message <id>] [--json]
  list        [--session <id>] [--json]
  transcript  --session <id>

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
    if ln -s "$$" "$lockfile" 2>/dev/null; then
      trap "_release_owned_lock '$lockfile' '$$'" EXIT
      return 0
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
    if mv "$lockfile" "$salvage" 2>/dev/null; then
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
    fi
    # Another racer salvaged the stale lock first. Loop and retry.
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
# Minimum deterministic patterns for v1. The full pattern set (entropy
# heuristics, user-supplied regex files, additional secret families) lands
# in XAR-1A.2. design doc trust boundary calls redaction "a risk gate, not
# proof of safety" — this v1 implementation covers high-confidence secret
# shapes and fails closed before any message file is written.
#
# Each entry is "name|extended-regex". The body text is matched as a single
# string against each regex; the first hit blocks the write.
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
)

scan_for_secrets() {
  local body_file="$1"
  # Concatenate body as a single string for regex matching. jq's @text on
  # the whole document gives a representation that includes embedded
  # secrets in any string field (prompt, summary, finding text, etc.).
  local body_text
  body_text="$(jq -r 'tostring' "$body_file")"
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
    request|response|decision) return 0 ;;
    note|relay) die 3 "kind '$1' is deferred to XAR-1A.2" ;;
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
  local kind="$1" body_file="$2"
  jq -e . "$body_file" >/dev/null 2>&1 || die 3 "body file is not valid JSON: $body_file"
  case "$kind" in
    request)
      jq -e '(.topic // "") != "" and (.prompt // "") != ""' "$body_file" >/dev/null \
        || die 3 "request body requires topic and prompt"
      ;;
    response)
      jq -e '(.summary // "") != ""' "$body_file" >/dev/null \
        || die 3 "response body requires summary"
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
      ' "$body_file" >/dev/null \
        || die 3 "response.findings[].finding_id must match ^[A-Za-z0-9._-]+$ (no whitespace, no control characters)"
      # Duplicate finding_id values silently collapse to one entry under
      # the decision coverage's sort -u and let a single decision satisfy
      # multiple findings. Reject duplicates here.
      jq -e '
        (.findings // []) | map(.finding_id // "") as $ids
        | ($ids | length) == ($ids | unique | length)
      ' "$body_file" >/dev/null \
        || die 3 "response.findings[] finding_id values must be unique"
      ;;
    decision)
      jq -e '(.next_action // "") != "" and ((.decisions // []) | type == "array")' "$body_file" >/dev/null \
        || die 3 "decision body requires next_action and decisions array"
      local next_action; next_action="$(jq -r '.next_action' "$body_file")"
      case "$next_action" in
        continue|relay|close|needs_user) ;;
        *) die 3 "decision next_action must be continue|relay|close|needs_user (got: $next_action)" ;;
      esac
      local session_close; session_close="$(jq -r '.session_close // false' "$body_file")"
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
      )' "$body_file" >/dev/null \
        || die 3 "each decision.decisions[] must have finding_id matching ^[A-Za-z0-9._-]+$ and action in accepted|rejected|deferred"
      # Duplicate decision finding_id values would let one row satisfy two
      # disposition slots; reject duplicates.
      jq -e '
        (.decisions // []) | map(.finding_id // "") as $ids
        | ($ids | length) == ($ids | unique | length)
      ' "$body_file" >/dev/null \
        || die 3 "decision.decisions[] finding_id values must be unique"
      ;;
  esac
}

validate_role() {
  local kind="$1" sender="$2" initiator="$3" reviewer="$4"
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

validate_sequencing() {
  local kind="$1" sdir="$2" body_file="${3:-}"
  local latest; latest="$(latest_message_kind "$sdir")"
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
      [[ "$na" == "continue" ]] \
        || die 4 "request requires preceding decision.next_action=continue (got: $na)"
      ;;
    response)
      [[ "$latest" == "request" ]] \
        || die 4 "response requires the latest message to be request (got: ${latest:-none})"
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
      new_next="$(jq -r '.next_action // ""' "$body_file")"
      new_close="$(jq -r '.session_close // false' "$body_file")"

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
            dec_ids="$(jq -r '(.decisions // []) | .[] | (.finding_id // "") | select(length > 0)' "$body_file" | sort -u)"
            missing="$(comm -23 <(printf '%s\n' "$resp_ids") <(printf '%s\n' "$dec_ids"))"
            if [[ -n "$missing" ]]; then
              die 4 "decision missing dispositions for findings: $(printf '%s' "$missing" | tr '\n' ' ')"
            fi
          fi
          ;;
        decision)
          # Two valid predecessors for a decision-after-decision:
          #   (a) continue → close: classic close-after-continue, the
          #       /pingpong stop path after a continue decision already
          #       disposed all findings.
          #   (b) close-intent → close: convergence path where the
          #       initiator first records `next_action=close,
          #       session_close=false` (intent) and the user later
          #       confirms with `session_close=true`. design doc
          #       Convergence section requires this two-step close.
          # In both cases the new decision must be the explicit close
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
            *) die 4 "decision after decision requires previous next_action in continue|close (got: ${prev_next:-none})" ;;
          esac
          if [[ "$new_next" != "close" || "$new_close" != "true" ]]; then
            die 4 "decision after decision is only allowed as explicit close (need next_action=close and session_close=true)"
          fi
          ;;
        *)
          die 4 "decision requires latest to be response, or decision(continue) followed by close (got: ${latest:-none})"
          ;;
      esac
      ;;
  esac
}

allocate_message_id() {
  # Allocate the next id based on final protocol files only. .tmp orphan
  # files must not push the id forward, or a leftover 000002-foo.json.tmp
  # would silently skip 000002 for the next real write.
  local sdir="$1" last_num=0
  if [[ -d "$sdir/messages" ]]; then
    local raw
    raw="$(ls "$sdir/messages" 2>/dev/null \
            | grep -E '^[0-9]{6}-(request|response|decision)\.json$' \
            | sed -n 's/^\([0-9]\{6\}\)-.*/\1/p' \
            | sort -n | tail -1 || true)"
    last_num="${raw:-0}"
    last_num=$((10#$last_num))
  fi
  printf '%06d\n' $((last_num + 1))
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
  # The probe must be cleaned up even on rejection. `die` calls `exit`
  # which skips the next statement, so install an EXIT trap before the
  # scan runs and unset it on the success path.
  local topic_probe; topic_probe="$(mktemp -t agent-dialog-init-XXXXXX.json)"
  trap "rm -f '$topic_probe'" EXIT
  jq -n --arg topic "$topic" --arg repo "$repo" '{topic: $topic, repo: $repo}' > "$topic_probe"
  scan_for_secrets "$topic_probe"
  rm -f "$topic_probe"
  trap - EXIT

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
  validate_body "$kind" "$body_file"
  scan_for_secrets "$body_file"

  local sdir="$SESSIONS_DIR/$session"
  [[ -d "$sdir" ]] || die 3 "write: session not found: $session"
  local sj="$sdir/session.json"
  [[ -f "$sj" ]] || die 3 "write: session.json missing in $sdir"

  local status initiator reviewer
  status="$(jq -r '.status' "$sj")"
  initiator="$(jq -r '.initiator_agent' "$sj")"
  reviewer="$(jq -r '.reviewer_agent' "$sj")"
  [[ "$status" == "open" ]] || die 4 "write: session $session status is $status"

  validate_role "$kind" "$sender" "$initiator" "$reviewer"

  acquire_lock "$sdir"
  # Re-read latest under lock and validate sequencing (decision coverage
  # needs the body to compare against the latest response's findings).
  validate_sequencing "$kind" "$sdir" "$body_file"

  local next_id; next_id="$(allocate_message_id "$sdir")"
  local created_at; created_at="$(now_utc)"

  if [[ -z "$recipient" ]]; then
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
  jq -n \
    --arg schema "$SCHEMA_VERSION" \
    --arg sid "$session" \
    --arg mid "$next_id" \
    --arg kind "$kind" \
    --arg sender "$sender" \
    --arg recipient "$recipient" \
    --arg ts "$created_at" \
    --argjson parent "$parent_json" \
    --slurpfile body "$body_file" \
    '{schema_version: $schema, session_id: $sid, message_id: $mid, kind: $kind, sender: $sender, recipient: $recipient, created_at: $ts, parent_message_id: $parent, body: $body[0]}' \
    > "$out_file.tmp"
  mv "$out_file.tmp" "$out_file"

  # session_close updates session.json under the same lock window.
  if [[ "$kind" == "decision" ]]; then
    local session_close; session_close="$(jq -r '.session_close // false' "$body_file")"
    if [[ "$session_close" == "true" ]]; then
      jq '.status = "closed"' "$sj" > "$sj.tmp"
      mv "$sj.tmp" "$sj"
    fi
  fi

  if [[ "$emit_json" == "true" ]]; then
    jq -n --arg sid "$session" --arg mid "$next_id" --arg kind "$kind" --arg path "$out_file" \
      '{schema_version: 1, kind: "agent_dialog_write", session_id: $sid, message_id: $mid, message_kind: $kind, path: $path}'
  else
    printf 'Wrote %s-%s\n' "$next_id" "$kind"
    printf 'Path: %s\n' "$out_file"
  fi
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
        jq -c '{session_id, status, topic, initiator_agent, reviewer_agent, created_at}' "$sj"
      done
      printf ']}\n'
    else
      for sd in "$SESSIONS_DIR"/*/; do
        [[ -d "$sd" ]] || continue
        local sj="$sd/session.json"
        [[ -f "$sj" ]] || continue
        local sid st topic; sid="$(jq -r '.session_id' "$sj")"; st="$(jq -r '.status' "$sj")"; topic="$(jq -r '.topic' "$sj")"
        printf '%s  [%s]  %s\n' "$sid" "$st" "$topic"
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

  for mf in $(ls "$sdir/messages"/*.json 2>/dev/null | sort); do
    [[ -f "$mf" ]] || continue
    local mid kind sender ts
    mid="$(jq -r '.message_id' "$mf")"
    kind="$(jq -r '.kind' "$mf")"
    sender="$(jq -r '.sender' "$mf")"
    ts="$(jq -r '.created_at' "$mf")"
    printf '## %s — %s — %s — %s\n\n' "$mid" "$kind" "$sender" "$ts"
    printf '```json\n'
    jq '.body' "$mf"
    printf '```\n\n'
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

  local sub="$1"; shift
  case "$sub" in
    init)       cmd_init "$@" ;;
    write)      cmd_write "$@" ;;
    read)       cmd_read "$@" ;;
    list)       cmd_list "$@" ;;
    transcript) cmd_transcript "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 3 ;;
  esac
}

main "$@"
