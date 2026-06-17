#!/usr/bin/env bash
# pingpong-relay.sh — XAR-1Bb.1 true auto-relay orchestrator (adversarial only).
#
# One invocation = exactly ONE protocol turn (whose-turn → subprocess author →
# helper write → emit next state → return). The driver (a parent agent chat or
# a terminal while-loop) re-runs `step` per turn, exactly like
# wait-codex-review.sh / `agent-dialog.sh watch` run foreground per cycle. The
# cycle is never captured in a single long-running call, so the driver regains
# control between every turn and user intervention stays reachable (XAR-1Bb.2
# wires the actual intervention channel; this skeleton pauses on user-gated
# turns).
#
# Design source: docs/design/workflows/cross-agent-review-auto-relay.md
# (DEC-045 runtime/visibility/mutation-authority; DEC-048 subprocess CLI 규약:
# G1 redacted-argv provenance, G2 env-override allowlist, G3 full process
# boundary, G4 real write-probe, stdin-file prompt, portable timeout +
# process-group kill, CLI-specific output capture).
#
# Topology: adversarial_dialogue ONLY. parallel_review auto (synthesis +
# decision draft) is XAR-1Bb.4. The decision in parallel_review is sender=user
# (DEC-043/Q-052), which cannot be agent-authored, so this orchestrator refuses
# parallel_review sessions.
#
# Mutation authority is explicit: the subprocess returns body JSON text only;
# this orchestrator persists EXCLUSIVELY through `agent-dialog.sh write`, which
# re-runs every redaction/role/sequencing/lock validation. If the helper
# rejects, the step stops and reports — the orchestrator never writes session
# state directly.
#
# Subcommands:
#   capabilities --session <id> [--manual] [--auto-decision] [--json]
#   step         --session <id> [--manual] [--auto-decision]
#                [--instructions-file <path>] [--json] [--dry-run]
#
# auto-relay is the DEFAULT (DEC-054): a bare `step` collects/relays the turn.
# Pass --manual (alias --no-auto-relay) to opt out to per-turn pausing.
# --auto-relay is still accepted as a backward-compat no-op.
#
# Exit codes (step):
#   0  step completed OR cleanly paused/terminal (see emitted JSON `status`)
#   2  usage error
#   3  session not found / helper error
#   4  subprocess author failed (timeout, sandbox reject, bad output)
#   5  helper rejected the authored body (contract violation) — loop must stop
#
# Env:
#   AGENT_DIALOG_HELPER   path to agent-dialog.sh (default: alongside script)
#   AGENT_DIALOG_HOME     session store (passed through to the helper)
#   RELAY_CODEX_BIN       codex CLI (default: codex)
#   RELAY_CLAUDE_BIN      claude CLI (default: claude)
#   RELAY_MODEL_CODEX     pinned model for codex turns (G1/G2; default: unset)
#   RELAY_MODEL_CLAUDE    pinned model for claude turns (default: unset)
#   RELAY_TIMEOUT_SECS    per-subprocess timeout (default: 180)
#   RELAY_SANDBOX         auto | off  (default: auto; macOS uses sandbox-exec)
#   RELAY_MAX_ROUNDS      DEC-029 primary cap (default: 6)
#   RELAY_MAX_MESSAGES    DEC-029 secondary flood fuse (default: 20)
#   RELAY_REVIEWER_CMD    test hook: full reviewer command override (argv[0..]);
#                         when set, used verbatim for BOTH agents and sandbox is
#                         bypassed (stub-binary unit tests). Prompt is still fed
#                         on stdin from the finite prompt file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${AGENT_DIALOG_HELPER:-$SCRIPT_DIR/agent-dialog.sh}"
AGENT_DIALOG_HOME="${AGENT_DIALOG_HOME:-$HOME/.agent-dialog}"
SESSIONS_DIR="$AGENT_DIALOG_HOME/sessions"

RELAY_CODEX_BIN="${RELAY_CODEX_BIN:-codex}"
RELAY_CLAUDE_BIN="${RELAY_CLAUDE_BIN:-claude}"
RELAY_TIMEOUT_SECS="${RELAY_TIMEOUT_SECS:-180}"
RELAY_SANDBOX="${RELAY_SANDBOX:-auto}"
RELAY_MAX_ROUNDS="${RELAY_MAX_ROUNDS:-6}"
RELAY_MAX_MESSAGES="${RELAY_MAX_MESSAGES:-20}"

RELAY_SBX=()   # sandbox argv prefix (populated by _sandbox_prefix)
RELAY_CLI=()   # reviewer CLI argv (populated by _build_cli_argv)
RELAY_ENV=()   # env allowlist prefix (populated by _env_prefix)
# Repo root to deny-read in the sandbox. Resolve the git top-level so a driver
# invoking from a subdirectory still hides the WHOLE checkout (PR #91 codex P2),
# falling back to the invocation cwd outside a git repo.
RELAY_REPO_CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
# The SESSION's own repo (session.json .repo) — may differ from the driver cwd
# when a central driver runs the relay (PR #91 codex P1). Set per-step.
RELAY_SESSION_REPO=""

die() { local code="$1"; shift; printf 'pingpong-relay: %s\n' "$*" >&2; exit "$code"; }

# Reject a malformed / traversal session id BEFORE it is used to build any
# filesystem path (PR #93 codex P2). Format: agent-dialog gen_session_id
# (YYYYMMDD-HHMMSS-<16 hex>).
_validate_sid() {
  case "$1" in *[!0-9a-fA-F-]*|*..*|*/*) die 2 "invalid session id: $1" ;; esac
  printf '%s' "$1" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{16}$' \
    || die 2 "invalid session id format: $1"
}

# --- portable timeout (DEC-048 v) -------------------------------------------
# `timeout` is GNU coreutils and is commonly absent on stock macOS (where it
# only exists as `gtimeout` after coreutils install, or as a shell alias that
# does NOT apply inside scripts). Resolve a real binary; fall back to a
# perl-based process-group runner when neither exists.
_resolve_timeout_bin() {
  local b
  for b in timeout gtimeout; do
    if command -v "$b" >/dev/null 2>&1; then printf '%s\n' "$b"; return 0; fi
  done
  return 1
}

# Run "$@" with a wall-clock limit, killing the WHOLE process group on expiry
# so a hung reviewer's children (G3 child-containment) cannot survive the
# watchdog. GNU timeout (resolved above) runs the command in its own group and
# signals the group by default; the perl fallback creates a new process group
# via setpgrp and TERM→KILLs that group.
_run_guarded() {
  local secs="$1"; shift
  local tbin
  if tbin="$(_resolve_timeout_bin)"; then
    "$tbin" -k 5 "$secs" "$@"
    return $?
  fi
  # Fallback: no timeout/gtimeout. perl makes itself a group leader (setpgrp)
  # then exec's the command, so the command + its children share a new group.
  perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@" &
  local child=$!
  (
    sleep "$secs"
    # negative PID targets the process group led by $child
    kill -TERM "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
    sleep 5
    kill -KILL "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null
  ) &
  local watchdog=$!
  local rc=0
  wait "$child" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# --- OS sandbox (DEC-045 wrapper-enforced + DEC-048 G3) ---------------------
# Returns the sandbox prefix argv on stdout (empty when disabled/unavailable).
# macOS: sandbox-exec read-only profile that ALLOWS network (the reviewer needs
# the model API) and file-read, DENIES file-write everywhere except an explicit
# scratch dir + /dev. The session tree and repo are therefore not writable from
# inside the subprocess; the real-write-probe acceptance verifies this.
_sandbox_profile_path=""
# Canonicalize a path to its /private/... real form (macOS /var → /private/var,
# /tmp → /private/tmp symlinks) so subpath rules match what the kernel sees.
_canon() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" && pwd -P); else printf '%s\n' "$p"; fi
}
# Read-only profile. Allow network (reviewer needs the model API) and exec;
# DENY all file-write EXCEPT the single canonicalized scratch subtree + /dev
# essentials (session tree + repo are NOT writable — real-write-probe verifies).
# For READS (DEC-048 G3 + PR #91 codex P1): an `allow default` profile leaves
# every HOME secret (~/.netrc, ~/.git-credentials, ~/.docker/config.json, gh
# hosts, ssh/aws/gpg keys …) readable to a networked reviewer CLI, which could
# exfiltrate them. So deny HOME reads by DEFAULT and re-allow only the narrow
# auth/cache paths the CLI needs to run; also deny the repo + session store.
# System paths (binaries, libs) stay readable via `allow default`. The
# read-probe in `write-probe` verifies a HOME secret read is denied.
_make_sandbox_profile() {
  local scratch; scratch="$(_canon "$1")"
  local repo; repo="$(_canon "$RELAY_REPO_CWD")"
  local store; store="$(_canon "$SESSIONS_DIR")"
  local home="${HOME:-/dev/null}"
  local prof; prof="$(mktemp -t relay-sbpl.XXXXXX)"
  # The session's own repo (from session.json) is denied in addition to the
  # driver cwd, so a central driver still hides the actual target checkout.
  local sess_repo_rule=""
  if [ -n "$RELAY_SESSION_REPO" ] && [ -d "$RELAY_SESSION_REPO" ]; then
    sess_repo_rule="  (subpath \"$(_canon "$RELAY_SESSION_REPO")\")"
  fi
  # Re-allow READ of the reviewer CLI's own runtime even when it lives under
  # HOME (e.g. nvm: ~/.nvm/versions/node/<ver>/{bin,lib}). The deny-HOME rule
  # would otherwise block reading/exec'ing the binary + its node runtime (the
  # dogfood hit this). Allow ONLY the binary's own dir (node + the binary) and
  # its sibling `lib` (node_modules) — NOT the grandparent, which for a binary
  # in ~/bin would be $HOME itself and would defeat deny-HOME (PR #94 codex P1).
  local home_canon; home_canon="$(_canon "$home")"
  local runtime_rules="" b d bindir libdir
  for b in "$RELAY_CODEX_BIN" "$RELAY_CLAUDE_BIN"; do
    d="$(command -v "$b" 2>/dev/null || true)"; [ -n "$d" ] || continue
    bindir="$(_canon "$(dirname "$d")")"
    # Never re-allow $HOME or / as a "runtime" tree.
    if [ -n "$bindir" ] && [ "$bindir" != "$home_canon" ] && [ "$bindir" != "/" ]; then
      case "$runtime_rules" in *"\"$bindir\""*) ;; *) runtime_rules="$runtime_rules
  (subpath \"$bindir\")" ;; esac
    fi
    libdir="$(dirname "$(dirname "$d")")/lib"
    if [ -d "$libdir" ]; then
      libdir="$(_canon "$libdir")"
      if [ "$libdir" != "$home_canon" ] && [ "$libdir" != "/" ]; then
        case "$runtime_rules" in *"\"$libdir\""*) ;; *) runtime_rules="$runtime_rules
  (subpath \"$libdir\")" ;; esac
      fi
    fi
  done
  cat >"$prof" <<SBPL
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath "$scratch")
  (literal "/dev/null")
  (literal "/dev/zero")
  (literal "/dev/dtracehelper")
  (literal "/dev/random")
  (literal "/dev/urandom")
  (subpath "/dev/fd"))
(deny file-read*
  (subpath "$repo")
  (subpath "$store")
$sess_repo_rule
  (subpath "$home"))
(allow file-read*
  (subpath "$home/.codex")
  (subpath "$home/.claude")
  (subpath "$home/.config/codex")
  (subpath "$home/.config/claude")
  (subpath "$home/.cache")$runtime_rules)
(allow file-read-metadata
  (subpath "$home"))
(deny file-read*
  (subpath "$repo")
  (subpath "$store")
$sess_repo_rule)
SBPL
  printf '%s\n' "$prof"
}

# Build an env-allowlist prefix (DEC-048 G2): the subprocess gets only a vetted
# environment, NOT arbitrary inherited CODEX_*/CLAUDE_* that could silently
# change model/sandbox/network. TMPDIR is pinned to the writable scratch so the
# CLI's temp writes land inside the sandbox's only writable subtree.
_env_prefix() {
  local scratch="$1"
  # Put the reviewer-CLI dirs on PATH so the cleared env can find the binary's
  # own runtime (e.g. the nvm `node` that codex/claude's shebang needs) — the
  # dogfood hit `env: codex: No such file or directory` otherwise.
  local path="${PATH:-/usr/bin:/bin}" cdir ddir
  cdir="$(command -v "$RELAY_CODEX_BIN" 2>/dev/null || true)"; cdir="${cdir%/*}"
  ddir="$(command -v "$RELAY_CLAUDE_BIN" 2>/dev/null || true)"; ddir="${ddir%/*}"
  [ -n "$ddir" ] && case ":$path:" in *":$ddir:"*) ;; *) path="$ddir:$path" ;; esac
  [ -n "$cdir" ] && case ":$path:" in *":$cdir:"*) ;; *) path="$cdir:$path" ;; esac
  RELAY_ENV=(env -i
    "HOME=${HOME:-}" "PATH=$path" "USER=${USER:-}"
    "TERM=${TERM:-xterm}" "LANG=${LANG:-en_US.UTF-8}" "TMPDIR=$scratch")
  # Pass through the SUPPORTED reviewer-CLI auth credentials when set — API-key /
  # CI setups need these to make the model call; OAuth-in-HOME setups don't
  # (PR #91 codex P2). These are an explicit allowlist (not a wildcard
  # passthrough) and their VALUES are never written to provenance (only argv is).
  local v val
  for v in CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY \
           CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN; do
    val="${!v:-}"
    [ -n "$val" ] && RELAY_ENV+=("$v=$val")
  done
  return 0   # never let a trailing false test trip set -e
}

# Redirect the reviewer CLI's mutable state ($CODEX_HOME / Claude config dir)
# into a scratch subdir, copying only the auth/config it needs to read, so the
# CLI authenticates while every write it makes lands inside the sandbox's only
# writable subtree — keeping ~/.codex|~/.claude read-only (PR #94 codex P1).
# Appends the *_HOME var(s) to RELAY_ENV.
_redirect_cli_home() {
  local actor="$1" scratch="$2" src dst
  case "$actor" in
    codex)
      src="${CODEX_HOME:-$HOME/.codex}"; dst="$scratch/.codex"
      mkdir -p "$dst"
      [ -f "$src/auth.json" ]   && cp "$src/auth.json"   "$dst/" 2>/dev/null || true
      [ -f "$src/config.toml" ] && cp "$src/config.toml" "$dst/" 2>/dev/null || true
      RELAY_ENV+=("CODEX_HOME=$dst")
      ;;
    claude)
      # Claude Code reads its config dir from CLAUDE_CONFIG_DIR (falling back to
      # ~/.claude). Mirror auth into scratch and point the CLI there.
      src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; dst="$scratch/.claude"
      mkdir -p "$dst"
      [ -f "$src/.credentials.json" ] && cp "$src/.credentials.json" "$dst/" 2>/dev/null || true
      [ -f "$src/settings.json" ]     && cp "$src/settings.json"     "$dst/" 2>/dev/null || true
      RELAY_ENV+=("CLAUDE_CONFIG_DIR=$dst")
      ;;
  esac
  return 0
}

# Populates the global array RELAY_SBX with the sandbox argv prefix (empty when
# disabled/unavailable). Sets _sandbox_profile_path for cleanup. scratch is the
# only writable subtree handed to the subprocess. (Global array + bash-3.2
# compatibility: no namerefs/mapfile.)
_sandbox_prefix() {
  local scratch="$1"
  RELAY_SBX=()
  [ "$RELAY_SANDBOX" = "off" ] && return 0
  if [ "$(uname -s)" = "Darwin" ] && command -v sandbox-exec >/dev/null 2>&1; then
    _sandbox_profile_path="$(_make_sandbox_profile "$scratch")"
    RELAY_SBX=(sandbox-exec -f "$_sandbox_profile_path")
    return 0
  fi
  # Linux/other: NO sandbox is wired yet. A naive `bwrap --ro-bind / /` would
  # make the host read-only but still fully READABLE, letting the reviewer CLI
  # slurp repo/session/home secrets and exfiltrate them via its model call
  # (PR #91 codex P1). Shipping that is worse than refusing, so leave RELAY_SBX
  # empty → `step` refuses real authoring (no_sandbox). A proper read-isolating
  # bwrap/namespace profile (bind only the CLI install + auth, hide repo/session/
  # home-secrets) is a follow-up before Linux auto-relay is enabled.
  return 0
}

_sandbox_available() {
  [ "$RELAY_SANDBOX" = "off" ] && { echo "off"; return; }
  if [ "$(uname -s)" = "Darwin" ] && command -v sandbox-exec >/dev/null 2>&1; then
    echo "sandbox-exec"; return
  fi
  # Linux read-isolating sandbox not wired yet (see _sandbox_prefix); report
  # none so capabilities + step surface the missing boundary.
  echo "none"
}

# --- helper passthrough ------------------------------------------------------
_helper() { AGENT_DIALOG_HOME="$AGENT_DIALOG_HOME" bash "$HELPER" "$@"; }

# Load the session's own repo path so the sandbox profile can deny-read the
# actual target checkout, not just the driver cwd. session.json stores `repo`
# as an OBJECT `{path, head_sha}` (PR #91 codex P1), but tolerate a bare string
# too.
_load_session_repo() {
  RELAY_SESSION_REPO="$(jq -r '(.repo | if type=="object" then .path else . end) // ""' "$SESSIONS_DIR/$1/session.json" 2>/dev/null || true)"
  if [ "$RELAY_SESSION_REPO" = "null" ]; then RELAY_SESSION_REPO=""; fi
  return 0
}

# DEC-029 convergence signal (정밀화 — matches "양쪽 finding 0"): TRUE only when
# the CURRENT round has at least one effective (post-last-decision, non-
# superseded) response AND every one of them has zero findings. In parallel_review
# that means BOTH reviewers came back clean — a single clean response is NOT
# convergence (PR #95). In adversarial it reduces to the single reviewer. Using
# the effective set (same last-decision + supersedes filter as the synthesis)
# avoids treating a prior round's clean response or a superseded one as
# convergence. Returns 0 (true) / 1 (false); a round with no effective response
# is false (nothing has converged yet).
_effective_responses_all_zero() {
  local sid="$1" sdir="$SESSIONS_DIR/$sid"
  local last_dec last_dec_id="000000"
  last_dec="$(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-decision\.json$' | sort -n | tail -1 || true)"
  [ -n "$last_dec" ] && last_dec_id="${last_dec%%-*}"
  local superseded
  superseded="$(cat "$sdir"/messages/*.json 2>/dev/null \
    | jq -r '.body.supersedes // empty' 2>/dev/null | sort -u || true)"
  local count=0 nonzero=0 f id n
  for f in "$sdir"/messages/*-response.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f")"; id="${id%%-*}"
    [ "$((10#$id))" -gt "$((10#$last_dec_id))" ] || continue
    if [ -n "$superseded" ] && printf '%s\n' "$superseded" | grep -qx "$id"; then continue; fi
    count=$((count + 1))
    n="$(jq -r '(.body.findings // []) | length' "$f" 2>/dev/null || echo 1)"
    [ "$n" = "0" ] || nonzero=$((nonzero + 1))
  done
  [ "$count" -ge 1 ] && [ "$nonzero" -eq 0 ]
}

# original_user_instructions of the LATEST request (the current round's user
# input) — used to carry provenance across a 0-input adversarial continuation.
_latest_request_oui() {
  local sdir="$SESSIONS_DIR/$1" latest_req
  latest_req="$(ls "$sdir/messages" 2>/dev/null \
    | grep -E '^[0-9]{6}-request\.json$' | sort -n | tail -1 || true)"
  [ -n "$latest_req" ] || return 0
  jq -r '.body.original_user_instructions // ""' "$sdir/messages/$latest_req" 2>/dev/null || true
}

_whose_turn() { _helper whose-turn --session "$1" --json; }

# Count full rounds and protocol messages for the DEC-029 cap.
_round_count() {
  # DEC-029 primary cap = full deliberation rounds. A decision corrected via
  # body.supersedes is a replacement EDGE, not a new round, so exclude
  # superseded decisions (their 6-digit ids appear as another message's
  # body.supersedes target) from the count (PR #91 codex P2).
  local sdir="$SESSIONS_DIR/$1"
  [ -d "$sdir/messages" ] || { echo 0; return; }
  local superseded
  superseded="$(cat "$sdir"/messages/*.json 2>/dev/null \
    | jq -r '.body.supersedes // empty' 2>/dev/null | sort -u || true)"
  local count=0 f id
  for f in "$sdir"/messages/*-decision.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f")"; id="${id%%-*}"
    if [ -n "$superseded" ] && printf '%s\n' "$superseded" | grep -qx "$id"; then
      continue
    fi
    count=$((count + 1))
  done
  echo "$count"
}
_message_count() {
  # DEC-029 secondary flood fuse counts ALL protocol artifacts including the
  # supplemental note + relay kinds (note/relay are excluded from round count
  # but included in message count).
  local sdir="$SESSIONS_DIR/$1"
  ls "$sdir/messages" 2>/dev/null \
    | grep -cE '^[0-9]{6}-(request|response|decision|note|relay)\.json$' || true
}

# --- reviewer / initiator subprocess invocation (DEC-048) -------------------
# Build the role instruction + transcript-bounded context into a prompt file,
# spawn the actor's CLI under sandbox + guarded timeout, capture the body JSON.
# Echoes the path to the captured body JSON on success.
_author_turn() {
  local sid="$1" actor="$2" kind="$3" instructions="$4"
  local sdir="$SESSIONS_DIR/$sid"
  # _author_turn runs inside a $(...) subshell, so a failure cause cannot be
  # returned via a global; hand it to the caller through a session file instead.
  local diag_file="$sdir/.relay/last_author_error"
  rm -f "$diag_file" 2>/dev/null || true
  _load_session_repo "$sid"
  local scratch; scratch="$(mktemp -d -t relay-scratch.XXXXXX)"
  local prompt_file="$scratch/prompt.txt"
  local out_file="$scratch/out.json"
  local schema_file="$scratch/schema.json"

  # dialogue mode gates the parallel-only response schema fields (concurs_with/
  # disputes); request/decision schemas are mode-independent.
  local dmode_aut; dmode_aut="$(jq -r '.dialogue_mode // ""' <<<"$(_whose_turn "$sid")" 2>/dev/null || printf '')"
  _write_schema "$kind" "$schema_file" "$dmode_aut"
  _render_prompt "$sid" "$actor" "$kind" "$instructions" >"$prompt_file"

  # G1 provenance: record a REDACTED argv (flags/model/version only — never the
  # prompt body, which lives in the file referenced by hash) plus the prompt
  # file's content hash, into an orchestrator-owned area (NOT a helper message:
  # keeps the protocol store thin per DEC-006/011).
  local model="" body_path
  case "$actor" in
    codex)  model="${RELAY_MODEL_CODEX:-}" ;;
    claude) model="${RELAY_MODEL_CLAUDE:-}" ;;
  esac

  local -a cmd
  if [ -n "${RELAY_REVIEWER_CMD:-}" ]; then
    # Test hook: verbatim stub command for BOTH agents, no sandbox.
    # shellcheck disable=SC2206
    cmd=($RELAY_REVIEWER_CMD)
    _provenance "$sid" "$actor" "$kind" "$prompt_file" "stub:${RELAY_REVIEWER_CMD}" "$model"
    if ! _run_guarded "$RELAY_TIMEOUT_SECS" "${cmd[@]}" <"$prompt_file" >"$out_file" 2>"$scratch/err.log"; then
      _cleanup_scratch "$scratch"; return 4
    fi
  else
    _sandbox_prefix "$scratch"      # → RELAY_SBX (global array; may be empty)
    if [ "${#RELAY_SBX[@]}" -eq 0 ]; then
      # No OS sandbox = no primary mutation boundary. Bare agent CLIs can expose
      # file-edit/Bash, so authoring a real turn without the wrapper would let a
      # turn mutate the repo/session outside agent-dialog.sh write. Refuse
      # (PR #91 codex P1). RELAY_SANDBOX=off is for stub tests only.
      _cleanup_scratch "$scratch"; return 6
    fi
    _env_prefix "$scratch"          # → RELAY_ENV (env allowlist, G2)
    # Redirect the reviewer CLI's mutable state into the scratch tree instead of
    # write-allowing ~/.codex|~/.claude — that would let the subprocess overwrite
    # local agent credentials/config outside agent-dialog.sh write (PR #94 codex
    # P1). The CLI's auth is COPIED into the scratch home so it still
    # authenticates while all its writes land in the only writable subtree.
    _redirect_cli_home "$actor" "$scratch"   # appends *_HOME=scratch to RELAY_ENV
    _build_cli_argv "$actor" "$model" "$out_file" "$schema_file"  # → RELAY_CLI
    _provenance "$sid" "$actor" "$kind" "$prompt_file" "${RELAY_CLI[*]}" "$model"
    # prompt is fed on stdin from the finite prompt file (EOF → no hang; argv
    # stays prompt-free for clean provenance — DEC-048 v). cwd is moved into the
    # scratch dir (outside repo/session) so the subprocess cannot reach repo
    # files by relative path. Invocation order: sandbox-exec → env -i → CLI.
    if ! ( cd "$scratch" && _run_guarded "$RELAY_TIMEOUT_SECS" \
         "${RELAY_SBX[@]}" "${RELAY_ENV[@]}" "${RELAY_CLI[@]}" \
         <"$prompt_file" >"$scratch/stdout.log" 2>"$scratch/err.log" ); then
      [ -n "$_sandbox_profile_path" ] && rm -f "$_sandbox_profile_path"
      # claude -p signals auth/runtime errors via an is_error envelope on stdout
      # AND (under --json-schema) exits non-zero, so capture its own message here
      # before the run is discarded — else the cause degrades to an opaque rc=4.
      { [ "$actor" = "claude" ] && _capture_claude_diag "$scratch/stdout.log" "$diag_file"; } || true
      _cleanup_scratch "$scratch"; return 4
    fi
    [ -n "$_sandbox_profile_path" ] && rm -f "$_sandbox_profile_path"
    # codex writes the final message to $out_file (-o); claude emits JSON on
    # stdout (--output-format json). Normalize to $out_file.
    if [ "$actor" = "claude" ]; then
      # claude -p can also exit 0 while still carrying an is_error envelope (e.g.
      # --output-format json without a schema). Detect that and surface the cause
      # rather than failing to parse "Not logged in ..." as a free-text body. The
      # common macOS trigger is keychain-only auth: with CLAUDE_CONFIG_DIR
      # redirected to scratch (G3 process boundary) the keychain is intentionally
      # NOT inherited — provide auth via the G2 env allowlist
      # (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY) or ~/.claude/.credentials.json.
      if _capture_claude_diag "$scratch/stdout.log" "$diag_file"; then
        _cleanup_scratch "$scratch"; return 4
      fi
      _extract_claude_json "$scratch/stdout.log" >"$out_file" || { _cleanup_scratch "$scratch"; return 4; }
    fi
  fi

  if ! jq -e . "$out_file" >/dev/null 2>&1; then
    _cleanup_scratch "$scratch"; return 4
  fi
  # Move the captured body somewhere stable for the caller, then clean scratch.
  body_path="$(mktemp -t relay-body.XXXXXX)"
  cp "$out_file" "$body_path"
  _cleanup_scratch "$scratch"
  printf '%s\n' "$body_path"
}

_cleanup_scratch() { rm -rf "$1" 2>/dev/null || true; }

# If a claude -p envelope reports is_error, record its message into the session
# diag file (so cmd_step can surface it across the $(...) subshell boundary) and
# return 0 (true = "this was an error"); return 1 when no is_error is present.
_capture_claude_diag() {
  local log="$1" diag_file="$2"
  jq -e '.is_error == true' "$log" >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$diag_file")"
  printf 'claude reported is_error: %s' \
    "$(jq -r '.result // "unknown"' "$log" 2>/dev/null | tr '\n' ' ' | head -c 160)" >"$diag_file"
  return 0
}

# Build the real CLI argv (DEC-048 stdin-file prompt + CLI-specific capture)
# into the global array RELAY_CLI (bash-3.2 compatible; no namerefs).
_build_cli_argv() {
  local actor="$1" model="$2" out_file="$3" schema_file="$4"
  RELAY_CLI=()
  # Resolve the binary to an ABSOLUTE path so `env -i` (cleared env) does not
  # have to find it on PATH, and remember its dir so _env_prefix can put the
  # node/runtime alongside it on PATH (the dogfood hit `env: codex: No such
  # file or directory` when the cleared PATH lacked the nvm bin dir).
  local bin
  case "$actor" in
    codex)  bin="$(command -v "$RELAY_CODEX_BIN" 2>/dev/null || printf '%s' "$RELAY_CODEX_BIN")" ;;
    claude) bin="$(command -v "$RELAY_CLAUDE_BIN" 2>/dev/null || printf '%s' "$RELAY_CLAUDE_BIN")" ;;
  esac
  case "$actor" in
    codex)
      # --ephemeral: do NOT load $CODEX_HOME/config.toml (auth still uses
      # CODEX_HOME) — this disables MCP servers configured there AND avoids
      # rollout-file persistence that the deny-HOME-write sandbox would block as
      # author_failed (PR #91 codex P1). -c mcp_servers={} also overrides any
      # managed-config MCP servers (defense in depth — a write-capable MCP/IDE
      # server could mutate state outside agent-dialog.sh write).
      RELAY_CLI=("$bin" exec - --ephemeral --skip-git-repo-check
                 -s read-only -c approval_policy=never -c "mcp_servers={}"
                 -o "$out_file" --output-schema "$schema_file")
      [ -n "$model" ] && RELAY_CLI+=(-m "$model")
      ;;
    claude)
      # --json-schema takes the schema VALUE inline (not a file path), so pass
      # the compact schema content (PR #91 codex P1). This constrains print-mode
      # output like codex's --output-schema so a free-text/shape-drift response
      # can't reach the helper as an unvalidated body.
      local schema_inline; schema_inline="$(jq -c . "$schema_file" 2>/dev/null || cat "$schema_file")"
      RELAY_CLI=("$bin" -p --output-format json --json-schema "$schema_inline")
      [ -n "$model" ] && RELAY_CLI+=(--model "$model")
      ;;
    *) die 2 "unknown actor: $actor" ;;
  esac
  return 0   # never let a trailing false test trip set -e
}

# claude -p --output-format json wraps the result. With --json-schema the
# validated object is returned in `.structured_output` (PR #91 codex P1); read
# that first, then fall back to `.result`/`.text` (which may themselves contain
# JSON) for unconstrained or older output.
_extract_claude_json() {
  local log="$1"
  if jq -e '(.structured_output // null) != null' "$log" >/dev/null 2>&1; then
    jq -c '.structured_output' "$log" 2>/dev/null && return 0
  fi
  jq -r '.result // .text // empty' "$log" 2>/dev/null \
    | jq -e . 2>/dev/null && return 0
  # Some versions stream JSONL; take the last object's result field.
  tail -1 "$log" | jq -r '.result // empty' 2>/dev/null | jq -e . 2>/dev/null
}

# Orchestrator-owned provenance log (NOT a protocol message). Records the
# resolved binary PATH rather than running `<cli> --version` here: that probe
# would execute the configured binary OUTSIDE the sandbox + env allowlist, and a
# wrapper/CLI that writes cache/telemetry on startup would then mutate outside
# the boundary (PR #91 codex P2). The live version, if needed, is captured from
# the sandboxed authoring run's logs (follow-up); the path + redacted argv keep
# provenance reproducible without an out-of-boundary exec.
_provenance() {
  local sid="$1" actor="$2" kind="$3" prompt_file="$4" argv="$5" model="$6"
  local rdir="$SESSIONS_DIR/$sid/.relay"
  mkdir -p "$rdir"
  local hash; hash="$(_sha256 "$prompt_file")"
  local cli_path=""
  case "$actor" in
    codex)  cli_path="$(command -v "$RELAY_CODEX_BIN" 2>/dev/null || printf '%s' "$RELAY_CODEX_BIN")" ;;
    claude) cli_path="$(command -v "$RELAY_CLAUDE_BIN" 2>/dev/null || printf '%s' "$RELAY_CLAUDE_BIN")" ;;
  esac
  jq -n --arg actor "$actor" --arg kind "$kind" --arg argv "$argv" \
        --arg model "$model" --arg cli_path "$cli_path" --arg hash "$hash" \
    '{schema_version:1, kind:"relay_provenance", actor:$actor, turn_kind:$kind,
      redacted_argv:$argv, model:$model, cli_path:$cli_path,
      prompt_sha256:$hash}' >>"$rdir/provenance.jsonl"
}

_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else echo "nohash"; fi
}

# --- role instruction + output schema ---------------------------------------
_render_prompt() {
  local sid="$1" actor="$2" kind="$3" instructions="$4"
  local role
  # In parallel_review BOTH agents review independently; finding_ids must be
  # distinct per agent or the helper rejects the collision (Q-056/DEC-046):
  # initiator uses F.., reviewer uses G... Instruct the right prefix.
  local prefix="F" rev="" dmode2=""
  if [ "$kind" = "response" ]; then
    dmode2="$(jq -r '.dialogue_mode' <<<"$(_whose_turn "$sid")")"
    if [ "$dmode2" = "parallel_review" ]; then
      rev="$(jq -r '.reviewer_agent // ""' "$SESSIONS_DIR/$sid/session.json" 2>/dev/null || true)"
      [ "$actor" = "$rev" ] && prefix="G"
    fi
  fi
  local par_resp_role="You are a REVIEWER ($actor) in a PARALLEL review. Author a response body as JSON: {\"summary\":..., \"findings\":[{\"finding_id\":\"${prefix}1\",\"claim\":..., \"concurs_with\":\"\", \"disputes\":\"\"}]}. Use finding_id prefix '${prefix}' (e.g. ${prefix}1, ${prefix}2). If the transcript already contains the OTHER agent's findings (a different prefix), then for each of your findings set concurs_with to a peer finding_id you independently confirm, OR disputes to a peer finding_id you directly contradict — never both; otherwise leave both \"\". If you are the first mover (no peer findings yet) leave both \"\". Give sharp, specific findings on the latest request."
  case "$kind" in
    request)  role="You are the INITIATOR ($actor). Author the next request body as JSON: {\"topic\":..., \"prompt\":..., \"original_user_instructions\":...}. Use the user instructions below verbatim for original_user_instructions." ;;
    response)
      if [ "$dmode2" = "parallel_review" ]; then role="$par_resp_role"
      else role="You are a REVIEWER ($actor). Author a response body as JSON: {\"summary\":..., \"findings\":[{\"finding_id\":\"${prefix}1\",\"claim\":...}], \"convergence\":null}. Use finding_id prefix '${prefix}' (e.g. ${prefix}1, ${prefix}2). Give sharp, specific findings on the latest request."
      fi ;;
    decision) role="You are the INITIATOR ($actor). Disposition the reviewer's findings. Author a decision body as JSON: {\"decisions\":[{\"finding_id\":...,\"action\":\"accepted|rejected|deferred\",\"reason_one_line\":...}], \"next_action\":\"continue|close|needs_user\", \"session_close\":true|false, \"summary\":..., \"original_user_instructions\":...}. Close when converged." ;;
  esac
  printf '%s\n\n' "$role"
  if [ -n "$instructions" ]; then
    printf 'USER INSTRUCTIONS (verbatim for original_user_instructions):\n%s\n\n' "$instructions"
  fi
  printf '=== SESSION TRANSCRIPT ===\n'
  _helper transcript --session "$sid"
}

# OpenAI/codex structured output (strict mode) requires EVERY object to set
# `additionalProperties: false` and to list all its properties in `required`
# (else codex exec --output-schema fails with HTTP 400 "additionalProperties is
# required ... to be false"). The dogfood (XAR-1Bb.3) surfaced this. original_
# user_instructions is intentionally omitted from the decision schema — the
# orchestrator injects the authoritative value post-hoc via _set_oui — so the
# model never authors provenance.
#
# XAR-1Bb.5 (DEC-047 iv): the parallel_review response schema additionally
# requires per-finding `concurs_with` / `disputes` (peer finding_id or "") so the
# second mover can declare an explicit agreement/conflict stance toward the first
# mover's findings (which it sees in the transcript). The synthesis consumes
# these to pre-fill the confirm-only decision draft (agreement → accepted,
# conflict → deferred+needs_user). The adversarial response schema is left
# byte-identical so the already-accepted adversarial e2e path is unchanged.
_write_schema() {
  local kind="$1" path="$2" mode="${3:-}"
  case "$kind" in
    response)
      if [ "$mode" = "parallel_review" ]; then
        cat >"$path" <<'JSON'
{"type":"object","additionalProperties":false,"required":["summary","findings"],"properties":{
"summary":{"type":"string"},
"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["finding_id","claim","concurs_with","disputes"],
"properties":{"finding_id":{"type":"string"},"claim":{"type":"string"},
"concurs_with":{"type":"string"},"disputes":{"type":"string"}}}}}}
JSON
      else
        cat >"$path" <<'JSON'
{"type":"object","additionalProperties":false,"required":["summary","findings"],"properties":{
"summary":{"type":"string"},
"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["finding_id","claim"],
"properties":{"finding_id":{"type":"string"},"claim":{"type":"string"}}}}}}
JSON
      fi
      ;;
    decision)
      cat >"$path" <<'JSON'
{"type":"object","additionalProperties":false,"required":["decisions","next_action","session_close","summary"],"properties":{
"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["finding_id","action","reason_one_line"],
"properties":{"finding_id":{"type":"string"},"action":{"type":"string"},"reason_one_line":{"type":"string"}}}},
"next_action":{"type":"string"},"session_close":{"type":"boolean"},"summary":{"type":"string"}}}
JSON
      ;;
    request)
      cat >"$path" <<'JSON'
{"type":"object","additionalProperties":false,"required":["topic","prompt","original_user_instructions"],"properties":{
"topic":{"type":"string"},"prompt":{"type":"string"},"original_user_instructions":{"type":"string"}}}
JSON
      ;;
  esac
}

# --- subcommands -------------------------------------------------------------
cmd_capabilities() {
  # XAR-1Bb.6 (DEC-054): auto-relay default-on; --manual (alias --no-auto-relay)
  # reports the opted-out capability set.
  local sid="" auto_relay="true" auto_decision="false" json="false"
  while (($#)); do case "$1" in
    --session) sid="$2"; shift 2 ;;
    --auto-relay) shift ;;  # no-op: auto-relay is the default (DEC-054); kept for backward compat
    --manual|--no-auto-relay) auto_relay="false"; shift ;;  # explicit opt-out always wins, order-independent
    --auto-decision) auto_decision="true"; shift ;;
    --json) json="true"; shift ;;
    *) die 2 "capabilities: unknown arg: $1" ;;
  esac; done
  [ -n "$sid" ] || die 2 "capabilities: --session required"
  local obs; obs="$(_whose_turn "$sid")" || die 3 "session not found: $sid"
  local dmode; dmode="$(jq -r '.dialogue_mode' <<<"$obs")"
  local sbx; sbx="$(_sandbox_available)"
  local caps
  if [ "$auto_relay" != "true" ]; then
    # DEC-054: --manual opt-out — report the per-turn pause mode so the caps
    # text never contradicts auto_relay=false (R-F2).
    caps="manual (per-turn pause; auto-relay off — driver advances each turn)"
    [ "$auto_decision" = "true" ] && caps="$caps; --auto-decision set"
  elif [ "$dmode" = "parallel_review" ]; then
    # DEC-047: parallel auto = auto-relay (collect both responses) + synthesis
    # (orchestrator-only) + decision DRAFT. The final disposition stays
    # user-required (decision sender=user, DEC-043/Q-052) — --auto-decision is
    # NOT honored here.
    caps="auto-relay (양측 response 자동수집) + synthesis (orchestrator-only) + decision draft (confirm-only); disposition은 user confirm-required"
  else
    caps="auto-relay (response 자동수집+relay)"
    [ "$auto_decision" = "true" ] && caps="$caps + auto-decision (0-input adversarial cycle)"
  fi
  if [ "$json" = "true" ]; then
    jq -n --arg dmode "$dmode" --arg caps "$caps" --arg sbx "$sbx" \
      --argjson ar "$auto_relay" --argjson ad "$auto_decision" \
      '{dialogue_mode:$dmode, capabilities:$caps, sandbox:$sbx,
        auto_relay:$ar, auto_decision:$ad}'
  else
    printf 'topology: %s\ncapabilities: %s\nsandbox: %s\n' "$dmode" "$caps" "$sbx"
  fi
}

# --- real write-probe acceptance (DEC-048 G4) -------------------------------
# Runs a probe through the SAME wrapper a real turn uses (sandbox + env -i +
# cwd=scratch) and attempts the representative filesystem escape paths the
# design requires — repo, session, HOME, parent dir, symlink target, atomic
# rename — asserting every one is DENIED while only the scratch dir is writable.
# This is not a stub argv check and not a bare /bin/sh redirection: it proves
# the configured wrapper contains an arbitrary process. Fails (exit 4) if no OS
# sandbox is available (the boundary then cannot be proven).
cmd_write_probe() {
  local sid="" json="false" reviewer=""
  while (($#)); do case "$1" in
    --session) sid="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --json) json="true"; shift ;;
    *) die 2 "write-probe: unknown arg: $1" ;;
  esac; done
  [ -n "$sid" ] || die 2 "write-probe: --session required"
  case "$reviewer" in ""|codex|claude) ;; *) die 2 "write-probe: --reviewer must be codex|claude" ;; esac
  # Validate the session id BEFORE using it in a path: reject traversal /
  # injection, and require an existing session — never mkdir an untrusted
  # directory in a diagnostic subcommand.
  _validate_sid "$sid"
  local sdir="$SESSIONS_DIR/$sid"
  [ -d "$sdir" ] || die 3 "write-probe: session not found: $sid"
  _load_session_repo "$sid"

  local scratch; scratch="$(mktemp -d -t relay-probe.XXXXXX)"
  _sandbox_prefix "$scratch"
  _env_prefix "$scratch"
  if [ "${#RELAY_SBX[@]}" -eq 0 ]; then
    _cleanup_scratch "$scratch"
    if [ "$json" = "true" ]; then
      jq -nc '{kind:"relay_write_probe", result:"no_sandbox", passed:false}'
    else
      printf 'write-probe: no OS sandbox available — boundary cannot be proven\n' >&2
    fi
    exit 4
  fi

  # Run a probe through the SAME wrapper the real turn uses (sandbox + env -i +
  # cwd=scratch), not bare /bin/sh. NOTE: this proves the OS wrapper contains an
  # ARBITRARY process — the sandbox-exec boundary applies to whatever runs
  # inside it regardless of the program. CLI-specific argv construction is
  # covered by the step tests; an opt-in real-CLI acceptance (driving the
  # configured codex/claude through this wrapper) is a follow-up that needs
  # network/auth (PR #91 codex P2). The probe attempts the filesystem escape
  # paths the design requires — WRITE to repo/session/HOME/parent/symlink/rename
  # and READ of the session store + a HOME secret (the G3 read-isolation the
  # deny-HOME profile must enforce). A pass means ONLY the scratch write landed
  # and NO protected read succeeded.
  local results="$scratch/results"; : >"$results"
  local probe="$scratch/probe.sh"
  # Unique marker name keyed to this scratch dir so the probe + its cleanup can
  # never touch a pre-existing user file at a fixed path (PR #91 codex P2).
  local mk=".relay-write-probe.$(basename "$scratch")"
  local t_repo="$RELAY_REPO_CWD/$mk"
  local t_session="$sdir/$mk"
  local t_home="${HOME:-/dev/null}/$mk"
  local t_parent; t_parent="$(dirname "$scratch")/$mk"
  local link="$scratch/link-to-repo"
  ln -s "$t_repo" "$link" 2>/dev/null || true
  rm -f "$t_repo" "$t_session" "$t_home" "$t_parent" 2>/dev/null || true
  # A unique HOME secret to read-probe (created OUTSIDE the sandbox, removed
  # after; reading it from inside the sandbox must be denied by the deny-HOME
  # profile). The session.json is the no-setup read-probe target.
  local home_secret="${HOME:-/tmp}/.relay-read-secret.$(basename "$scratch")"
  printf 'SECRET' >"$home_secret" 2>/dev/null || true
  # A unique secret in the SESSION's own repo, to verify _load_session_repo's
  # path resolution actually feeds the deny-read rule (PR #91 codex P1).
  local sess_secret="/dev/null/none"
  if [ -n "$RELAY_SESSION_REPO" ] && [ -d "$RELAY_SESSION_REPO" ]; then
    sess_secret="$RELAY_SESSION_REPO/.relay-read-secret.$(basename "$scratch")"
    printf 'SECRET' >"$sess_secret" 2>/dev/null || true
  fi
  cat >"$probe" <<PROBE
#!/bin/sh
# escape attempts — each appends a marker to \$TMPDIR/results on success
tryw() { ( echo x > "\$1" ) 2>/dev/null && echo "WROTE \$2" >> "\$TMPDIR/results"; }
tryr() { cat "\$1" >/dev/null 2>&1 && echo "READ \$2" >> "\$TMPDIR/results"; }
tryw "$t_repo" repo
tryw "$t_session" session
tryw "$t_home" home
tryw "$t_parent" parent
( echo x > "$link" ) 2>/dev/null && echo "WROTE symlink" >> "\$TMPDIR/results"
( echo s > "\$TMPDIR/seed" && mv "\$TMPDIR/seed" "$t_repo" ) 2>/dev/null && echo "WROTE rename" >> "\$TMPDIR/results"
tryr "$sdir/session.json" read-session
tryr "$home_secret" read-home
tryr "$sess_secret" read-session-repo
( echo x > "\$TMPDIR/ok" ) 2>/dev/null && echo "WROTE scratch" >> "\$TMPDIR/results"
PROBE
  ( cd "$scratch" && _run_guarded 30 "${RELAY_SBX[@]}" "${RELAY_ENV[@]}" /bin/sh "$probe" ) 2>/dev/null || true

  # Opt-in: also verify the CONFIGURED reviewer binary actually starts under the
  # SAME wrapper (PR #91 codex P2). The shell probe proves the OS boundary
  # contains an arbitrary process, but it can't catch a missing binary, a
  # startup read the sandbox blocks, or an auth/cache path the env allowlist
  # omits — all of which would let write-probe pass while the first real `step`
  # fails. `<bin> --version` boots the binary through sandbox+env+cwd without a
  # model/network call.
  local reviewer_reachable="n/a"
  if [ -n "$reviewer" ]; then
    local rbin=""
    case "$reviewer" in codex) rbin="$RELAY_CODEX_BIN" ;; claude) rbin="$RELAY_CLAUDE_BIN" ;; esac
    if ( cd "$scratch" && _run_guarded 30 "${RELAY_SBX[@]}" "${RELAY_ENV[@]}" "$rbin" --version </dev/null >/dev/null 2>&1 ); then
      reviewer_reachable="true"
    else
      reviewer_reachable="false"
    fi
  fi

  local total scratch_hits escapes
  total="$(grep -cE 'WROTE|READ' "$results" 2>/dev/null || true)"
  scratch_hits="$(grep -c 'WROTE scratch' "$results" 2>/dev/null || true)"
  escapes=$((total - scratch_hits))
  local scratch_ok="false"; [ "$scratch_hits" -ge 1 ] && scratch_ok="true"
  local leaked; leaked="$(grep -vE 'WROTE scratch' "$results" 2>/dev/null | tr '\n' ',' || true)"

  rm -f "$t_repo" "$t_session" "$t_home" "$t_parent" "$home_secret" 2>/dev/null || true
  [ "$sess_secret" != "/dev/null/none" ] && rm -f "$sess_secret" 2>/dev/null || true
  [ -n "$_sandbox_profile_path" ] && rm -f "$_sandbox_profile_path"
  _cleanup_scratch "$scratch"

  local passed="false"
  if [ "$escapes" -eq 0 ] && [ "$scratch_ok" = "true" ] \
     && { [ "$reviewer_reachable" != "false" ]; }; then
    passed="true"
  fi
  if [ "$json" = "true" ]; then
    jq -nc --argjson esc "$escapes" --argjson so "$scratch_ok" --argjson p "$passed" \
      --arg leaked "$leaked" --arg rr "$reviewer_reachable" \
      '{kind:"relay_write_probe", probe:"wrapper-containment (arbitrary process; CLI argv via step tests)",
        escapes:$esc, scratch_writable:$so, leaked:$leaked, reviewer_reachable:$rr, passed:$p}'
  else
    printf 'write-probe (wrapper-containment): escapes=%s scratch_ok=%s reviewer_reachable=%s leaked=[%s] → %s\n' \
      "$escapes" "$scratch_ok" "$reviewer_reachable" "$leaked" \
      "$([ "$passed" = "true" ] && echo PASS || echo FAIL)"
  fi
  [ "$passed" = "true" ] || exit 4
}

_emit_step() {
  # $1=status $2=detail ; plus optional --json passthrough via global
  local status="$1" detail="$2"
  if [ "$STEP_JSON" = "true" ]; then
    jq -nc --arg s "$status" --arg d "$detail" --arg sid "$STEP_SID" \
      '{kind:"relay_step", session_id:$sid, status:$s, detail:$d}'
  else
    printf 'relay step: %s — %s\n' "$status" "$detail"
  fi
}

# --- intervention routing (XAR-1Bb.2) ---------------------------------------
# Gathers an explicit-verb intervention from --intervene / control file / stdin
# (in that precedence) and processes it. The payload is JSON: {"verb": ...}.
#   note   {"verb":"note","text":"..."}            → write note (sender=user)
#   relay  {"verb":"relay","to":"codex|claude",
#           "messages":["000002"],"text":"..."}     → write relay (sender=user)
#   stop   {"verb":"stop"}                          → halt the loop (no write)
#   resume {"verb":"resume"}                         → proceed with the auto turn
# note/relay/stop emit + EXIT (auto turn defers a step); resume / no-intervention
# return 0 to fall through. Unsupported/malformed → emit + exit 2 (ask the user).
# The control file is consumed (renamed) so it is processed at most once.

# Consume the between-step control file: rename → `.consumed` for audit (fall back
# to delete). No-op for the --intervene/stdin channels. Idempotent.
_consume_control() {
  local from="$1" control_file="$2"
  [ "$from" = "control" ] || return 0
  mv "$control_file" "$control_file.consumed" 2>/dev/null || rm -f "$control_file" 2>/dev/null || true
  return 0
}

_handle_intervention() {
  local sid="$1" intervene="$2" control_file="$3" read_stdin="$4" dry="$5"
  local payload="" from=""
  if [ -n "$intervene" ]; then
    payload="$intervene"; from="arg"
  elif [ -f "$control_file" ]; then
    payload="$(cat "$control_file")"; from="control"
  elif [ "$read_stdin" = "true" ]; then
    # Non-blocking-ish: bounded 1s read so a pipe/FIFO with no queued line (or a
    # TTY with nothing typed) means "no intervention" rather than hanging the
    # loop (PR #93 codex P2). bash 3.2 supports integer -t only.
    IFS= read -r -t 1 payload 2>/dev/null || payload=""; from="stdin"
  fi
  [ -n "$payload" ] || return 0   # no intervention → normal turn

  # --dry-run must not mutate session state: report what WOULD happen and leave
  # the control file in place (PR #93 codex P2).
  if [ "$dry" = "true" ]; then
    local dverb; dverb="$(jq -r '.verb // "?"' <<<"$payload" 2>/dev/null || echo '?')"
    _emit_step "dry_run" "would process intervention verb='$dverb' (from $from); no write/consume"; exit 0
  fi

  # Mid-cycle resume / crash-safety (Q-057): the orchestrator holds no cross-step
  # state — a restart just re-runs `step`, which re-derives the turn from the
  # file-first store (whose messages are atomic-rename-complete). The one
  # non-idempotent step-local side effect is consuming the control file, so the
  # consume order matters per verb. For the DURABLE verbs (stop/resume) the
  # `.stopped` marker is idempotent, so apply it BEFORE consuming `.control`: a
  # crash in the apply→consume window then re-reads `.control` next step and
  # re-applies (no dropped stop — a dropped stop would let the loop keep running).
  # For note/relay/malformed we consume FIRST so a malformed payload can't loop
  # and a crash can't duplicate the appended message (a dropped note is
  # recoverable; the user re-sends).
  local verb; verb="$(jq -r '.verb // ""' <<<"$payload" 2>/dev/null || true)"
  case "$verb" in
    resume)
      rm -f "$SESSIONS_DIR/$sid/.stopped" 2>/dev/null || true  # clear durable stop (F2) — idempotent, before consume
      _consume_control "$from" "$control_file"
      return 0 ;;  # fall through to author the normal turn
    stop)
      # Durable stop (PR/dogfood F2): a runtime-only stop would let a later step
      # observe an open session and resume. Persist a `.stopped` marker that
      # step/status honor until `resume` clears it. Written BEFORE consume so a
      # crash in the window cannot drop the stop.
      : >"$SESSIONS_DIR/$sid/.stopped" 2>/dev/null || true
      _consume_control "$from" "$control_file"
      _emit_step "stopped" "user stop — durable .stopped marker written (resume clears it)"; exit 0 ;;
    note)
      _consume_control "$from" "$control_file"   # consume first: malformed/dup guard
      # text MUST be a JSON string (explicit-JSON channel; a coerced number etc.
      # must be rejected, not recorded — PR #93 codex P2).
      jq -e '(.text|type)=="string"' <<<"$payload" >/dev/null 2>&1 \
        || { _emit_step "intervention_rejected" "note text must be a JSON string"; exit 2; }
      local text; text="$(jq -r '.text' <<<"$payload" 2>/dev/null || true)"
      [ -n "$text" ] || { _emit_step "intervention_rejected" "note requires non-empty text"; exit 2; }
      local nb; nb="$(mktemp -t relay-note.XXXXXX)"
      jq -n --arg t "$text" '{text:$t}' >"$nb"
      local wrc=0
      _helper write --session "$sid" --kind note --sender user --body-file "$nb" >/dev/null 2>"$nb.err" || wrc=$?
      if [ "$wrc" -ne 0 ]; then _emit_step "intervention_rejected" "note: $(head -1 "$nb.err" 2>/dev/null)"; rm -f "$nb" "$nb.err"; exit 2; fi
      rm -f "$nb" "$nb.err"
      _emit_step "intervened" "note recorded (sender=user); auto turn defers to next step"; exit 0 ;;
    relay)
      _consume_control "$from" "$control_file"   # consume first: malformed/dup guard
      jq -e '(.to|type)=="string" and (.text|type)=="string"' <<<"$payload" >/dev/null 2>&1 \
        || { _emit_step "intervention_rejected" "relay to/text must be JSON strings"; exit 2; }
      local to text; to="$(jq -r '.to' <<<"$payload" 2>/dev/null || true)"
      text="$(jq -r '.text' <<<"$payload" 2>/dev/null || true)"
      local msgs; msgs="$(jq -c '(.messages // [])' <<<"$payload" 2>/dev/null || echo '[]')"
      [ -n "$to" ] && [ -n "$text" ] || { _emit_step "intervention_rejected" "relay requires to + text"; exit 2; }
      local rb; rb="$(mktemp -t relay-relay.XXXXXX)"
      jq -n --arg ta "$to" --arg t "$text" --argjson m "$msgs" \
        '{source_message_ids:$m, target_agent:$ta, text:$t}' >"$rb"
      local wrc=0
      _helper write --session "$sid" --kind relay --sender user --body-file "$rb" >/dev/null 2>"$rb.err" || wrc=$?
      if [ "$wrc" -ne 0 ]; then _emit_step "intervention_rejected" "relay: $(head -1 "$rb.err" 2>/dev/null)"; rm -f "$rb" "$rb.err"; exit 2; fi
      rm -f "$rb" "$rb.err"
      _emit_step "intervened" "relay to $to recorded (sender=user); auto turn defers to next step"; exit 0 ;;
    *)
      _consume_control "$from" "$control_file"   # malformed → consume so it can't loop
      _emit_step "intervention_rejected" "unsupported/ambiguous verb '$verb' (use note|relay|stop|resume) — not processed"; exit 2 ;;
  esac
}

# Parallel auto (DEC-047 / XAR-1Bb.4): when both responses of the round are in,
# emit (a) a SYNTHESIS artifact and (b) a decision DRAFT — both orchestrator-only
# (never written to the session). The synthesis collects both responses, traces
# each finding to its source, and offers a next-action OPTION SET with **no
# disposition token** (G5). The draft is a confirm-only `sender=user` decision
# proposal (per-finding `deferred`, next_action `needs_user`) that the user
# confirms/edits to actually close the round (user authority preserved).
_emit_parallel_synthesis() {
  local sid="$1" sdir="$SESSIONS_DIR/$sid"
  local last_dec last_dec_id="000000"
  last_dec="$(ls "$sdir/messages" 2>/dev/null | grep -E '^[0-9]{6}-decision\.json$' | sort -n | tail -1 || true)"
  [ -n "$last_dec" ] && last_dec_id="${last_dec%%-*}"
  # Effective round set only (PR #95 codex P2): exclude responses that have been
  # replaced via body.supersedes, matching the helper's coverage union — else
  # the synthesis/draft would ask the user to disposition stale findings.
  local superseded
  superseded="$(cat "$sdir"/messages/*.json 2>/dev/null \
    | jq -r '.body.supersedes // empty' 2>/dev/null | sort -u || true)"
  local resp_files=() f id
  for f in "$sdir"/messages/*-response.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f")"; id="${id%%-*}"
    [ "$((10#$id))" -gt "$((10#$last_dec_id))" ] || continue
    if [ -n "$superseded" ] && printf '%s\n' "$superseded" | grep -qx "$id"; then continue; fi
    resp_files+=("$f")
  done
  if [ "${#resp_files[@]}" -eq 0 ]; then
    _emit_step "paused" "parallel decision turn but no round responses found"; return 0
  fi
  # XAR-1Bb.5 (DEC-047 iv): classify each union finding by the explicit peer
  # stance the second mover declared (concurs_with → agreement, disputes →
  # conflict; conflict wins if both). A stance reference is honored ONLY when it
  # names an EXISTING finding from a DIFFERENT agent (PR #97 codex P2): a
  # hallucinated id (e.g. `concurs_with: "F99"`) or a self/own-agent reference is
  # dropped, so the finding stays `single`/deferred and a user can't confirm an
  # unreviewed singleton as accepted. Honored links are stored BIDIRECTIONALLY
  # (PR #97 codex P3) so the referenced finding's row also carries the peer link
  # (else its draft reason / synthesis trace would show an empty counterpart).
  # Missing stance fields (older data / stubs / a model that left them "")
  # degrade gracefully to "single" = the prior all-deferred behaviour. Computed
  # once and injected into BOTH the synthesis (trace only — NO disposition token,
  # DEC-047 v) and the confirm-only decision draft (agreement → accepted
  # suggestion, conflict/single → deferred).
  local classified summaries synth draft
  classified="$(jq -s '
    ( [ .[] | .sender as $s | (.body.findings[]? |
          {finding_id, source:$s, claim:(.claim // ""),
           concurs_with:(.concurs_with // ""), disputes:(.disputes // "")}) ] ) as $all
    | ( reduce $all[] as $f ({}; . + {($f.finding_id): $f.source}) ) as $src
    | ( [ $all[] | select(.concurs_with != "" and $src[.concurs_with] != null
                          and $src[.concurs_with] != .source)
          | {self:.finding_id, peer:.concurs_with} ] ) as $agl
    | ( [ $all[] | select(.disputes != "" and $src[.disputes] != null
                          and $src[.disputes] != .source)
          | {self:.finding_id, peer:.disputes} ] ) as $cfl
    | ( reduce $agl[] as $l ({}; .[$l.self] += [$l.peer] | .[$l.peer] += [$l.self]) ) as $ap
    | ( reduce $cfl[] as $l ({}; .[$l.self] += [$l.peer] | .[$l.peer] += [$l.self]) ) as $cp
    | [ $all[] | .finding_id as $id
        | . + (if   ($cp[$id]) then {klass:"conflict",  peers:($cp[$id]|unique)}
               elif ($ap[$id]) then {klass:"agreement", peers:($ap[$id]|unique)}
               else {klass:"single", peers:[]} end) ]' \
    "${resp_files[@]}")"
  summaries="$(jq -s '[ .[] | {source:.sender, summary:(.body.summary // ""),
                              findings:[ .body.findings[]?.finding_id ]} ]' "${resp_files[@]}")"
  synth="$(jq -n --argjson c "$classified" --argjson r "$summaries" '
    {kind:"relay_synthesis",
     note:"orchestrator-only — NOT a session message; NO disposition token (option set + agreement/conflict trace only)",
     responses:$r,
     union_findings:[ $c[] | {finding_id, source, claim} ],
     agreements:[ $c[] | select(.klass=="agreement") | {finding_id, source, peers} ],
     conflicts:[ $c[] | select(.klass=="conflict") | {finding_id, source, peers} ],
     next_action_options:["accept_all","reject_all","mixed","continue","needs_user"]}')"
  draft="$(jq -n --argjson c "$classified" '
    {kind:"relay_decision_draft",
     note:"confirm-only — sender=user; NOT written until you confirm/edit; you own the final disposition. Pre-filled actions are SUGGESTIONS: agreement (peer-confirmed) → accepted; conflict/single-agent → deferred.",
     decisions:[ $c[] |
       {finding_id, source,
        action:(if .klass=="agreement" then "accepted" else "deferred" end),
        reason_one_line:(
          if   .klass=="agreement" then ("agreement: peer-confirmed with " + (.peers|join(", ")) + " — confirm accepted or override")
          elif .klass=="conflict"  then ("conflict: disputed with " + (.peers|join(", ")) + " — adjudicate accepted or rejected")
          else ("single-agent (" + .source + ") finding — confirm accepted, rejected or deferred") end)} ],
     next_action:"needs_user", session_close:false}')"
  if [ "$STEP_JSON" = "true" ]; then
    jq -nc --argjson syn "$synth" --argjson drf "$draft" --arg sid "$sid" \
      '{kind:"relay_step", session_id:$sid, status:"synthesis_ready",
        detail:"both responses collected; confirm/edit the sender=user decision draft to close the round",
        synthesis:$syn, decision_draft:$drf}'
  else
    printf 'relay step: synthesis_ready — confirm the sender=user decision draft\n--- synthesis (orchestrator-only) ---\n'
    printf '%s\n' "$synth" | jq .
    printf -- '--- decision draft (confirm-only) ---\n'
    printf '%s\n' "$draft" | jq .
  fi
}

# Parallel convergence (정밀화): both reviewers returned 0 findings, so there is
# nothing to disposition. Surface an explicit `converged` step carrying a
# confirm-only close DRAFT (empty decisions, next_action close, session_close).
# Like the synthesis draft it is orchestrator-only and NOT written to the helper
# — DEC-047 keeps the parallel decision sender=user, so the user confirms the
# close. This replaces the generic empty synthesis for the both-clean case.
_emit_convergence_close_draft() {
  local sid="$1" draft
  draft="$(jq -n '{kind:"relay_decision_draft",
    note:"confirm-only — sender=user; convergence close (both reviewers returned 0 findings); nothing to disposition",
    decisions:[], next_action:"close", session_close:true}')"
  if [ "$STEP_JSON" = "true" ]; then
    jq -nc --argjson drf "$draft" --arg sid "$sid" \
      '{kind:"relay_step", session_id:$sid, status:"converged",
        detail:"both reviewers returned 0 findings — converged; confirm the sender=user close to end the round",
        decision_draft:$drf}'
  else
    printf 'relay step: converged — both reviewers returned 0 findings; confirm the sender=user close\n'
    printf '%s\n' "$draft" | jq .
  fi
}

# Deterministically author a CLOSE decision on convergence (0-finding response):
# empty dispositions (nothing to dispose) + next_action close + session_close.
# Persisted through the helper like any other turn (validation still applies).
_close_on_convergence() {
  local sid="$1" actor="$2"
  local body; body="$(mktemp -t relay-conv.XXXXXX)"
  jq -n '{decisions:[], next_action:"close", session_close:true,
          summary:"converged: reviewer returned no findings"}' >"$body"
  body="$(_set_oui "$body" "" "$sid")"
  local wrc=0
  _helper write --session "$sid" --kind decision --sender "$actor" \
    --body-file "$body" >/dev/null 2>"$body.err" || wrc=$?
  if [ "$wrc" -ne 0 ]; then
    _emit_step "helper_rejected" "convergence close: $(head -1 "$body.err" 2>/dev/null)"; rm -f "$body" "$body.err"; exit 5
  fi
  rm -f "$body" "$body.err"
  _emit_step "converged_closed" "0-finding response → deterministic convergence close (DEC-029)"
}

cmd_step() {
  # XAR-1Bb.6 (DEC-054): auto-relay is the DEFAULT — a bare `step` collects and
  # relays the next turn automatically. `--manual` (alias `--no-auto-relay`)
  # opts back out to the original pause-on-every-turn behavior. `--auto-relay`
  # is still accepted (now a no-op) for backward compatibility. `--auto-decision`
  # stays opt-in (adversarial decision authoring).
  local sid="" auto_relay="true" auto_decision="false" dry="false"
  local instr_file="" intervene="" control_file="" read_stdin="false"
  STEP_JSON="false"
  while (($#)); do case "$1" in
    --session) sid="$2"; shift 2 ;;
    --auto-relay) shift ;;  # no-op: auto-relay is the default (DEC-054); kept for backward compat
    --manual|--no-auto-relay) auto_relay="false"; shift ;;  # explicit opt-out always wins, order-independent
    --auto-decision) auto_decision="true"; shift ;;
    --instructions-file) instr_file="$2"; shift 2 ;;
    --intervene) intervene="$2"; shift 2 ;;
    --control-file) control_file="$2"; shift 2 ;;
    --read-stdin) read_stdin="true"; shift ;;
    --json) STEP_JSON="true"; shift ;;
    --dry-run) dry="true"; shift ;;
    *) die 2 "step: unknown arg: $1" ;;
  esac; done
  [ -n "$sid" ] || die 2 "step: --session required"
  _validate_sid "$sid"   # before any path is built from $sid (incl. control file)
  STEP_SID="$sid"
  [ -n "$control_file" ] || control_file="$SESSIONS_DIR/$sid/.control"

  # XAR-1Bb.2 intervention routing: a user message between steps is delivered as
  # an explicit-verb JSON via --intervene, the <session>/.control file, or (with
  # --read-stdin) one line of stdin. It is processed BEFORE the auto turn
  # (pause-first), so an intervention always wins over auto-authoring. note/relay
  # land this step and the auto turn defers to the next step (1-turn latency);
  # resume falls through to author now; stop halts. The control file is consumed
  # so it is not reprocessed. note/relay/stop/rejected emit + exit inside the
  # handler; resume / no-intervention return 0 and fall through to the auto turn.
  _handle_intervention "$sid" "$intervene" "$control_file" "$read_stdin" "$dry"

  # F2: a durable user stop halts every subsequent step (not just the one that
  # issued it) until `resume` clears the marker.
  if [ -f "$SESSIONS_DIR/$sid/.stopped" ]; then
    _emit_step "stopped" "durable user-stop marker (.stopped) present; send {\"verb\":\"resume\"} to continue"; exit 0
  fi

  local obs; obs="$(_whose_turn "$sid")" || die 3 "step: session not found: $sid"
  local dmode terminal next_actor next_kind waiting latest_na
  dmode="$(jq -r '.dialogue_mode' <<<"$obs")"
  terminal="$(jq -r '.terminal' <<<"$obs")"
  next_actor="$(jq -r '.next_actor' <<<"$obs")"
  next_kind="$(jq -r '.next_kind' <<<"$obs")"
  waiting="$(jq -r '.waiting_on_user' <<<"$obs")"
  latest_na="$(jq -r '.latest_protocol.next_action // ""' <<<"$obs")"
  # parallel_review can have BOTH agents pending a response — pick the first.
  local next_actors0; next_actors0="$(jq -r '.next_actors[0] // ""' <<<"$obs")"

  if [ "$terminal" = "true" ]; then
    _emit_step "terminal" "session closed; no further turns"; exit 0
  fi

  # DEC-029 cap — preflight HARD gate (before authoring; `-ge`, never `>`).
  local rounds messages
  rounds="$(_round_count "$sid")"; messages="$(_message_count "$sid")"
  if [ "$rounds" -ge "$RELAY_MAX_ROUNDS" ] || [ "$messages" -ge "$RELAY_MAX_MESSAGES" ]; then
    _emit_step "cap_reached" "rounds=$rounds/$RELAY_MAX_ROUNDS messages=$messages/$RELAY_MAX_MESSAGES (DEC-029)"; exit 0
  fi

  # DEC-029 deterministic convergence (PR #94 codex P2) — ADVERSARIAL ONLY here
  # (PR #95 codex P1): when the reviewer's effective response(s) this round are
  # ALL zero-finding (정밀화 PR — `_effective_responses_all_zero`, not just the
  # latest message), the orchestrator CLOSES deterministically rather than
  # authoring another `continue`. Parallel convergence is handled separately in
  # the decision branch below because its decision is sender=user (DEC-047) — the
  # orchestrator must NOT auto-write it, so it surfaces a converged close-draft
  # for the user to confirm instead of closing here.
  if [ "$dmode" != "parallel_review" ] \
     && [ "$next_kind" = "decision" ] && _effective_responses_all_zero "$sid"; then
    if [ "$auto_decision" = "true" ]; then
      _close_on_convergence "$sid" "$next_actor"; exit 0
    fi
    _emit_step "converged" "reviewer returned 0 findings — convergence; author a close decision (sender=$next_actor)"; exit 0
  fi

  # User-gated turns: a `continue`/`needs_user` request needs fresh user
  # instructions (delegation provenance — orchestrator must not fabricate).
  # XAR-1Bb.2 wires the intervention/instructions channel; here we pause.
  local instructions=""
  [ -n "$instr_file" ] && instructions="$(cat "$instr_file")"

  case "$next_kind" in
    response)
      [ "$auto_relay" = "true" ] || { _emit_step "paused" "manual mode: response turn paused (--manual set; omit it to auto-relay)"; exit 0; }
      ;;
    decision)
      if [ "$dmode" = "parallel_review" ]; then
        # DEC-047: both responses are in. Emit the synthesis (orchestrator-only,
        # NOT a helper message, NO disposition token) + the decision DRAFT
        # (confirm-only) and pause — the parallel decision is sender=user, so the
        # orchestrator never writes it and --auto-decision is NOT honored.
        # Gate on --auto-relay (PR #95 codex P3): a plain `step` probe must pause,
        # not produce a draft.
        [ "$auto_relay" = "true" ] || { _emit_step "paused" "manual mode: parallel decision turn paused (--manual set; omit it to emit synthesis + decision draft)"; exit 0; }
        # DEC-029 convergence (정밀화 PR): if BOTH reviewers came back clean
        # (_effective_responses_all_zero), there is nothing to disposition — surface
        # an explicit `converged` close-draft (next_action close, empty decisions)
        # instead of a generic empty synthesis. It stays confirm-only (sender=user,
        # NOT helper-written) because DEC-047 reserves the parallel decision for the
        # user; the user confirms the close. A single clean response does NOT trigger
        # this (the helper falls through to the normal synthesis over the union).
        if _effective_responses_all_zero "$sid"; then
          _emit_convergence_close_draft "$sid"; exit 0
        fi
        _emit_parallel_synthesis "$sid"; exit 0
      fi
      [ "$auto_decision" = "true" ] || { _emit_step "paused" "decision turn — needs --auto-decision or user disposition"; exit 0; }
      ;;
    request)
      case "$latest_na" in
        needs_user)
          # A needs_user resume needs the exact prior_decision_context from
          # compose-context (INV-0004-9); a plain authored request is rejected
          # (exit 5). That's a user-gated flow (/pingpong continue + XAR-1Bb.2).
          _emit_step "paused" "needs_user resume requires prior_decision_context (use /pingpong continue; XAR-1Bb.2)"; exit 0 ;;
        continue)
          # 0-input adversarial continuation: the cycle keeps going on the SAME
          # user intent that started it. Carry the latest request's instructions
          # as provenance (not forged — it's the existing user instruction) so
          # --auto-relay can run a multi-round cycle without input after every
          # continue decision (the documented 0-input adversarial path).
          [ "$auto_relay" = "true" ] || { _emit_step "paused" "manual mode: continue request paused (--manual set; omit it to auto-relay)"; exit 0; }
          [ -n "$instructions" ] || instructions="$(_latest_request_oui "$sid")"
          [ -n "$instructions" ] || { _emit_step "paused" "continue request but no prior instructions to carry"; exit 0; }
          ;;
        *)
          # First request (empty session) — needs explicit user instructions.
          [ -n "$instructions" ] || { _emit_step "paused" "first request needs --instructions-file"; exit 0; } ;;
      esac
      ;;
    *) _emit_step "paused" "no actionable turn (next_kind=$next_kind)"; exit 0 ;;
  esac

  # parallel_review can have BOTH agents pending a response (next_actor reports
  # "multiple"); author the first pending agent's response this step (the next
  # step authors the other). For every other turn the actor is unambiguous.
  local author_actor="$next_actor"
  if [ "$dmode" = "parallel_review" ] && [ "$next_kind" = "response" ]; then
    author_actor="$next_actors0"
  fi

  if [ "$dry" = "true" ]; then
    _emit_step "dry_run" "would author $next_kind via $author_actor"; exit 0
  fi

  # Author the turn via the actor's CLI subprocess (sandbox + guarded timeout +
  # stdin-file prompt), then persist EXCLUSIVELY through the helper.
  local body_path rc=0
  body_path="$(_author_turn "$sid" "$author_actor" "$next_kind" "$instructions")" || rc=$?
  if [ "$rc" -eq 6 ]; then
    _emit_step "no_sandbox" "no OS sandbox available — refusing to author a real turn without the mutation boundary (set RELAY_SANDBOX appropriately / install sandbox-exec|bwrap)"; exit 6
  fi
  if [ "$rc" -ne 0 ]; then
    local _diag="" _diag_file="$SESSIONS_DIR/$sid/.relay/last_author_error"
    [ -f "$_diag_file" ] && _diag=" — $(cat "$_diag_file")"
    _emit_step "author_failed" "$author_actor $next_kind subprocess failed (rc=$rc: timeout/sandbox/bad-output)$_diag"; exit 4
  fi

  # For agent-authored decisions/requests, the delegation contract requires
  # original_user_instructions. Overwrite the model's value with the
  # authoritative carried/latest-request instructions (model is not a trusted
  # provenance source).
  if [ "$next_kind" = "decision" ] || [ "$next_kind" = "request" ]; then
    body_path="$(_set_oui "$body_path" "$instructions" "$sid")"
  fi

  local write_rc=0
  _helper write --session "$sid" --kind "$next_kind" --sender "$author_actor" \
    --body-file "$body_path" >/dev/null 2>"$body_path.err" || write_rc=$?
  if [ "$write_rc" -ne 0 ]; then
    _emit_step "helper_rejected" "$(head -1 "$body_path.err" 2>/dev/null)"; rm -f "$body_path" "$body_path.err"; exit 5
  fi
  rm -f "$body_path" "$body_path.err"

  local next; next="$(_whose_turn "$sid")"
  local nk; nk="$(jq -r '.next_kind' <<<"$next")"
  local na; na="$(jq -r '.next_actor' <<<"$next")"
  local term; term="$(jq -r '.terminal' <<<"$next")"
  if [ "$term" = "true" ]; then
    _emit_step "authored_terminal" "wrote $next_kind by $author_actor; session now terminal"
  else
    _emit_step "authored" "wrote $next_kind by $author_actor; next: $na/$nk"
  fi
}

# --- status panel (XAR-1Bb.3) -----------------------------------------------
# Surfaces the DEC-029 4-way OR termination state + counters + next turn so a
# driver (or the user) can see how close the cycle is to a cap. Read-only.
cmd_status() {
  local sid="" json="false"
  while (($#)); do case "$1" in
    --session) sid="$2"; shift 2 ;;
    --json) json="true"; shift ;;
    *) die 2 "status: unknown arg: $1" ;;
  esac; done
  [ -n "$sid" ] || die 2 "status: --session required"
  _validate_sid "$sid"

  local obs; obs="$(_whose_turn "$sid")" || die 3 "status: session not found: $sid"
  local dmode terminal next_actor next_kind latest_na
  dmode="$(jq -r '.dialogue_mode' <<<"$obs")"
  terminal="$(jq -r '.terminal' <<<"$obs")"
  next_actor="$(jq -r '.next_actor' <<<"$obs")"
  next_kind="$(jq -r '.next_kind' <<<"$obs")"
  latest_na="$(jq -r '.latest_protocol.next_action // ""' <<<"$obs")"

  # rounds = conversational progress (EXCLUDES superseded decisions); messages =
  # raw flood pressure (INCLUDES superseded churn) — same counters the step gate
  # uses, so the panel can never disagree with the runner (dogfood F1).
  local rounds messages
  rounds="$(_round_count "$sid")"; messages="$(_message_count "$sid")"

  # DEC-029 4-way OR — surface ALL four conditions:
  local rounds_cap="false" messages_cap="false" closed="false" stopped="false"
  local convergence="false" reason="active"
  [ "$rounds" -ge "$RELAY_MAX_ROUNDS" ] && { rounds_cap="true"; reason="rounds_cap"; }
  [ "$messages" -ge "$RELAY_MAX_MESSAGES" ] && { messages_cap="true"; reason="messages_cap"; }
  # convergence (F3, 정밀화 PR): the round is COMPLETE (next is the decision turn,
  # so every reviewer of the round has responded) AND every effective response has
  # zero findings — "양쪽 finding 0" for parallel, the single reviewer for
  # adversarial. Gating on the decision turn + the effective set (not just the
  # latest message) stops a half-finished parallel round (one clean response, the
  # other pending) or a prior round's clean response from reading as convergence.
  if [ "$next_kind" = "decision" ] && _effective_responses_all_zero "$sid"; then convergence="true"; fi
  [ -f "$SESSIONS_DIR/$sid/.stopped" ] && { stopped="true"; reason="user_stop"; }   # durable (F2)
  if [ "$terminal" = "true" ]; then closed="true"; reason="closed"; fi
  [ "$reason" = "active" ] && [ "$convergence" = "true" ] && reason="convergence"

  if [ "$json" = "true" ]; then
    jq -nc --arg sid "$sid" --arg dmode "$dmode" \
      --argjson rounds "$rounds" --argjson maxr "$RELAY_MAX_ROUNDS" \
      --argjson msgs "$messages" --argjson maxm "$RELAY_MAX_MESSAGES" \
      --argjson term "$terminal" --arg na "$next_actor" --arg nk "$next_kind" \
      --arg lna "$latest_na" --arg reason "$reason" \
      --argjson rc "$rounds_cap" --argjson mc "$messages_cap" --argjson cl "$closed" \
      --argjson st "$stopped" --argjson cv "$convergence" \
      '{kind:"relay_status", session_id:$sid, dialogue_mode:$dmode,
        rounds:$rounds, max_rounds:$maxr, messages:$msgs, max_messages:$maxm,
        terminal:$term, next_actor:$na, next_kind:$nk, latest_next_action:$lna,
        termination:{reason:$reason, rounds_cap:$rc, messages_cap:$mc, closed:$cl,
          user_stopped:$st, convergence:$cv,
          note:"DEC-029 4-way OR: rounds(progress, excl superseded) | messages(raw flood, incl superseded) | user-stop(.stopped durable) | convergence(decision turn + all effective responses 0 findings)"}}'
  else
    printf 'status %s [%s]\n  rounds: %s/%s (progress)   messages: %s/%s (raw flood)\n  next: %s/%s   terminal: %s   stopped: %s   convergence: %s   (%s)\n' \
      "$sid" "$dmode" "$rounds" "$RELAY_MAX_ROUNDS" "$messages" "$RELAY_MAX_MESSAGES" \
      "$next_actor" "$next_kind" "$terminal" "$stopped" "$convergence" "$reason"
  fi
}

# Set original_user_instructions to the AUTHORITATIVE value (delegation
# contract provenance). The orchestrator OVERWRITES whatever the model emitted —
# the model is not a trusted provenance source, and the helper only checks
# non-empty, so a stale/fabricated field would otherwise persist as audit
# provenance (PR #91 codex P2). Authoritative value = the carried
# --instructions, else the LATEST request's original_user_instructions (the
# current round's real user input — never the session's original start text).
_set_oui() {
  local body="$1" instructions="$2" sid="$3"
  [ -n "$instructions" ] || instructions="$(_latest_request_oui "$sid")"
  # No authoritative value available → leave the body unchanged and let the
  # helper's non-empty check decide (the model's value is the only candidate).
  [ -n "$instructions" ] || { printf '%s\n' "$body"; return 0; }
  local merged; merged="$(mktemp -t relay-body.XXXXXX)"
  jq --arg oui "$instructions" '.original_user_instructions = $oui' "$body" >"$merged"
  rm -f "$body"; printf '%s\n' "$merged"
}

main() {
  [ $# -ge 1 ] || die 2 "usage: pingpong-relay.sh {capabilities|step} --session <id> [...]"
  local sub="$1"; shift
  case "$sub" in
    capabilities) cmd_capabilities "$@" ;;
    step)         cmd_step "$@" ;;
    status)       cmd_status "$@" ;;
    write-probe)  cmd_write_probe "$@" ;;
    -h|--help)    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die 2 "unknown subcommand: $sub" ;;
  esac
}

# Only dispatch when executed directly; sourcing (e.g. unit tests) loads the
# functions without running a subcommand.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
