#!/usr/bin/env bash
# Run registry helper for /run + /run-team parallel agent substrate.
#
# PA-1.1 implementation of docs/design/systems/run-registry.md.
# Cooperative file-first contract (DEC-031: layered single-user enforcement).
# This helper provides the advisory cooperative layer only — sync_repo/land-pr
# refusal helpers and orchestrator-created isolated worker workspaces are
# separate layers (PA-1.2, PA-2.2, PA-3.1).
#
# Subcommands:
#   identity     --workspace <path>
#   register     --type solo|team --workspace <path> [--agent claude|codex|other]
#   release      <run_id>
#   acquire-lock --run <run_id> --lock <name> [--origin <text>]
#   release-lock --run <run_id> --lock <name>
#   heartbeat    <run_id>
#   list         [--repo <identity>] [--all-status]
#   gc           [--repo <identity>]
#
# Env vars:
#   RUN_STATE_HOME       override registry root parent (XDG_STATE_HOME or
#                              $HOME/.local/state by default)
#   RUN_HEARTBEAT_INTERVAL  default 30 seconds
#   RUN_HEARTBEAT_TTL       default 300 seconds
#   RUN_LOCK_RECLAIM_GRACE  default 60 seconds
#
# Exit codes:
#   0  success
#   1  generic error / usage
#   2  PR/workspace detection failure
#   3  invalid input / schema violation
#   4  missing required command
#   5  lock contention or registry conflict
#
# Lock semantics (design doc §5):
#   acquire: mkdir <lock_dir> (atomic) -> touch <lock_dir>/.creator.<pid>
#            -> write owner.tmp.<pid> JSON -> rename to owner.json.
#   release: rm owner.json + rm .creator.* + rmdir.
#   stale (design doc §6): owner.json absent AND creator pid dead/absent
#            AND lock_path mtime > RUN_LOCK_RECLAIM_GRACE.
#            Salvage via atomic-rename of the lock directory.

set -euo pipefail
umask 077

# --- Env / defaults --------------------------------------------------------

state_home_default() {
  if [[ -n "${RUN_STATE_HOME:-}" ]]; then
    printf '%s\n' "$RUN_STATE_HOME"
    return
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/run\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/run\n' "$HOME"
  fi
}

# Legacy state home (pre-DEC-049 `dev-cycle` naming) for transition dual-read.
# Mirrors the OLD resolution order: an explicit DEV_CYCLE_STATE_HOME wins (a run
# started under that override lives there), then XDG_STATE_HOME/dev-cycle, then
# $HOME/.local/state/dev-cycle. Independent of RUN_STATE_HOME — the new-tree home
# being explicit does not mean the legacy run wasn't under a custom dev-cycle home.
legacy_state_home() {
  if [[ -n "${DEV_CYCLE_STATE_HOME:-}" ]]; then
    printf '%s\n' "$DEV_CYCLE_STATE_HOME"
    return 0
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/dev-cycle\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/dev-cycle\n' "$HOME"
  fi
}

HEARTBEAT_INTERVAL="${RUN_HEARTBEAT_INTERVAL:-30}"
HEARTBEAT_TTL="${RUN_HEARTBEAT_TTL:-300}"
LOCK_RECLAIM_GRACE="${RUN_LOCK_RECLAIM_GRACE:-60}"

# Numeric validation. These values are consumed in arithmetic contexts;
# unvalidated text would either propagate as `unbound variable` under
# `set -u` (`$((abc))` evaluates `abc` as a variable name) or silently
# return 0 and break stale checks. Fail closed with a clear schema error.
_validate_positive_int() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'run-registry: %s must be a positive integer (got: %q)\n' "$name" "$value" >&2
    exit 3
  fi
}
_validate_positive_int RUN_HEARTBEAT_INTERVAL "$HEARTBEAT_INTERVAL"
_validate_positive_int RUN_HEARTBEAT_TTL      "$HEARTBEAT_TTL"
_validate_positive_int RUN_LOCK_RECLAIM_GRACE "$LOCK_RECLAIM_GRACE"

# --- Generic helpers -------------------------------------------------------

die() {
  local code="$1"; shift
  printf 'run-registry: %s\n' "$*" >&2
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 4 "missing required command: $1"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

mtime_epoch() {
  local path="$1"
  # GNU stat (Linux): `stat -c %Y -- <path>`. BSD stat (macOS): does not
  # support GNU-style `--` argument terminator; using it makes stat fail
  # and the function would return 0, fooling stale_lock_dir into seeing
  # fresh empty dirs as ancient and reclaiming them during the legitimate
  # owner.json write window. Detect OS and pick the right invocation.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$path" 2>/dev/null || echo 0
  else
    stat -c %Y -- "$path" 2>/dev/null || echo 0
  fi
}

sha256_hex() {
  # First 16 hex chars of sha256 of stdin.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print substr($1, 1, 16)}'
  else
    sha256sum | awk '{print substr($1, 1, 16)}'
  fi
}

# --- Identity normalization (design doc §2) --------------------------------

# normalize_identity <remote_url>
# Stdout: normalized identity string (host/path with host lowercased,
# path-case preserved, no protocol, no trailing .git, no trailing /).
# Empty stdout if input is empty or unrecognized.
normalize_identity() {
  local url="$1"
  [[ -z "$url" ]] && return 0
  local hostpath=""
  # scp-style SSH `[<user>@]host:path`. User prefix is stripped so that
  # `git@`, `alice@`, `deploy@` all collapse to the same identity. The
  # bash regex below uses an optional `[^@:/]+@` capture before the host.
  # Requires no slash before the first colon (scp-style) and that the
  # host portion not contain `/` (to avoid eating an HTTPS prefix).
  if [[ "$url" =~ ^(([^@:/]+)@)?([^@:/]+):([^/].*)$ ]] && [[ "$url" != http*://* ]] && [[ "$url" != ssh://* ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  # ssh://[<user>@]host/path
  elif [[ "$url" =~ ^ssh://(([^@/]+)@)?([^/]+)/(.+)$ ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  # https://[userinfo@]host/path or http://[userinfo@]host/path.
  # Userinfo (`<user>:<token>@`) is stripped so credentialed remotes
  # like `https://oauth2:<token>@github.com/org/repo.git` map to the
  # same identity as the bare HTTPS / SSH form.
  elif [[ "$url" =~ ^https?://(([^@/]+)@)?([^/]+)/(.+)$ ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  else
    # Unknown form: pass through (lowercased host portion if any).
    hostpath="$url"
  fi
  # Strip trailing .git.
  hostpath="${hostpath%.git}"
  # Strip trailing slashes.
  while [[ "$hostpath" == */ ]]; do hostpath="${hostpath%/}"; done
  # Lowercase host (everything before first /). Preserve path case.
  local host="${hostpath%%/*}"
  local path="${hostpath#*/}"
  local host_lc
  host_lc="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  if [[ "$host" == "$hostpath" ]]; then
    # No slash in input; treat entire string as host.
    printf '%s\n' "$host_lc"
  else
    printf '%s/%s\n' "$host_lc" "$path"
  fi
}

# repo_identity_for <workspace>
# Resolves the workspace's origin remote URL, normalizes it, and falls back
# to `local__<hash>` if no origin remote exists. Empty stdout on hard
# failure (workspace is not a git repo).
repo_identity_for() {
  local workspace="$1"
  [[ -d "$workspace/.git" || -f "$workspace/.git" ]] || \
    git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1 || \
    return 0
  local origin_url=""
  origin_url="$(git -C "$workspace" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin_url" ]]; then
    normalize_identity "$origin_url"
    return 0
  fi
  # Local-only fallback: hash canonical common-dir absolute path.
  local common_dir canonical
  common_dir="$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -z "$common_dir" ]] && return 0
  # Resolve to absolute path. git --git-common-dir may return a relative path.
  if [[ "$common_dir" != /* ]]; then
    common_dir="$(cd "$workspace" && cd "$common_dir" 2>/dev/null && pwd)"
  fi
  canonical="$(cd "$common_dir" 2>/dev/null && pwd -P || printf '%s' "$common_dir")"
  local hash
  hash="$(printf '%s' "$canonical" | sha256_hex)"
  printf 'local__%s\n' "$hash"
}

# repo_dir_key <normalized_identity>
# Stdout: <slug>__<sha256[:16]> (collision-safe directory key).
repo_dir_key() {
  local identity="$1"
  [[ -z "$identity" ]] && return 0
  # slug = identity with / -> _, only [A-Za-z0-9._-] retained.
  local slug
  slug="$(printf '%s' "$identity" | tr '/' '_' | LC_ALL=C sed 's/[^A-Za-z0-9._-]//g')"
  local hash
  hash="$(printf '%s' "$identity" | sha256_hex)"
  printf '%s__%s\n' "$slug" "$hash"
}

# branch_lock_key <branch_name> / slice_lock_key <slice_id>
# Same collision-safe encoding as repo_dir_key.
branch_lock_key() { repo_dir_key "$1"; }
slice_lock_key()  { repo_dir_key "$1"; }

# registry_root_for <repo_identity>
# Stdout: absolute path to ${state_home}/registry/<repo_dir_key>/
registry_root_for() {
  local identity="$1"
  [[ -z "$identity" ]] && die 3 "registry_root_for: empty identity"
  local key
  key="$(repo_dir_key "$identity")"
  printf '%s/registry/%s\n' "$(state_home_default)" "$key"
}

# legacy_registry_root_for <repo_identity>
# Stdout: absolute path to the legacy ${dev-cycle home}/registry/<key>/, or empty
# when there is no legacy home (RUN_STATE_HOME set) or no identity. DEC-049 #1.
legacy_registry_root_for() {
  local identity="$1" home key
  home="$(legacy_state_home)"
  [[ -n "$home" ]] || return 0
  [[ -z "$identity" ]] && return 0
  key="$(repo_dir_key "$identity")"
  printf '%s/registry/%s\n' "$home" "$key"
}

# ensure_repo_manifest <registry_root> <identity> <original_url>
ensure_repo_manifest() {
  local root="$1" identity="$2" original="$3"
  local manifest="$root/manifest.json"
  if [[ -f "$manifest" ]]; then return 0; fi
  mkdir -p "$root"
  local key
  key="$(repo_dir_key "$identity")"
  jq -n --arg orig "$original" --arg id "$identity" --arg key "$key" \
        --arg seen "$(now_utc)" '{
    schema_version: 1,
    kind: "run_registry_manifest",
    original_remote_url: $orig,
    normalized_identity: $id,
    directory_key: $key,
    first_seen_at: $seen
  }' > "$manifest.tmp.$$"
  mv "$manifest.tmp.$$" "$manifest"
}

# --- Run id ---------------------------------------------------------------

gen_run_id() {
  local ts rand
  ts="$(date -u +%Y%m%d-%H%M%S)"
  rand="$(LC_ALL=C head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
  printf '%s-%s\n' "$ts" "$rand"
}

# --- Lock primitives (design doc §5/§6) ------------------------------------

# acquire_lock_dir <lock_path> <run_id> <holder_pid> <holder_workspace>
#                  <lock_name> <lock_origin>
# Stdout: nothing on success. Exit 5 on contention.
acquire_lock_dir() {
  local lock_path="$1" run_id="$2" pid="$3" workspace="$4"
  local lock_name="$5" origin="${6:-}"

  while true; do
    if mkdir "$lock_path" 2>/dev/null; then
      # Step 2: creator marker (best-effort, ms window).
      : > "$lock_path/.creator.$pid" 2>/dev/null || true
      # Step 3+4: write owner JSON atomically.
      local tmp="$lock_path/owner.tmp.$pid"
      local acquired
      acquired="$(now_utc)"
      local expires
      expires="$(_iso_after_seconds "$HEARTBEAT_TTL")"
      local origin_json
      if [[ -z "$origin" ]]; then origin_json="null"; else origin_json="$(printf '%s' "$origin" | jq -R .)"; fi
      jq -n --arg name "$lock_name" --argjson origin "$origin_json" \
            --arg run "$run_id" --arg pid "$pid" --arg ws "$workspace" \
            --arg acq "$acquired" --arg exp "$expires" '{
        schema_version: 1,
        kind: "run_registry_lock",
        lock_name: $name,
        lock_origin: $origin,
        holder_run_id: $run,
        holder_pid: ($pid | tonumber),
        holder_workspace: $ws,
        acquired_at: $acq,
        expires_at: $exp
      }' > "$tmp"
      mv "$tmp" "$lock_path/owner.json"
      # Step 5: remove creator marker (owner.json is now authoritative).
      rm -f "$lock_path/.creator.$pid" 2>/dev/null || true
      return 0
    fi

    # mkdir failed -> contention or stale lock dir. Check.
    if stale_lock_dir "$lock_path"; then
      # Salvage via atomic rename (only one racer wins).
      local salvage="$lock_path.salvage.$pid.$RANDOM"
      if mv "$lock_path" "$salvage" 2>/dev/null; then
        # Re-check after salvage: if a live owner appeared in the window,
        # restore and abort instead of consuming a live lock.
        if [[ -f "$salvage/owner.json" ]]; then
          # Live owner appeared during salvage. Try to put back; if a new
          # lock has been created in the meantime, drop ours.
          if ! mv -n "$salvage" "$lock_path" 2>/dev/null; then
            rm -rf "$salvage"
          fi
          die 5 "lock $lock_path raced during salvage; aborting"
        fi
        rm -rf "$salvage"
        # Loop and retry the mkdir.
        continue
      fi
      # Another racer salvaged first; loop and retry.
      continue
    fi

    # Lock is held by a live or recent holder. Report contention.
    die 5 "lock $lock_path held by another run"
  done
}

# release_lock_dir <lock_path> <holder_run_id>
# Exit:
#   0  released (or lock did not exist; cleanup was a no-op for our run)
#   2  owner.json belongs to a different run; refused to release
#   3  owner.json absent but lock dir is in an active in-flight acquire
#      window (creator pid live OR mtime within reclaim grace); refused.
release_lock_dir() {
  local lock_path="$1" holder_run="$2"
  [[ -d "$lock_path" ]] || return 0
  if [[ -f "$lock_path/owner.json" ]]; then
    local owner
    owner="$(jq -r '.holder_run_id // empty' "$lock_path/owner.json" 2>/dev/null || true)"
    if [[ -n "$owner" && "$owner" != "$holder_run" ]]; then
      # Not ours; refuse to delete another holder's lock and signal so
      # the caller does not interpret the no-op as a successful release.
      return 2
    fi
    rm -f "$lock_path/owner.json"
    rm -f "$lock_path"/.creator.* 2>/dev/null || true
    rmdir "$lock_path" 2>/dev/null || true
    return 0
  fi
  # owner.json absent. This is exactly the transient state inside another
  # caller's legitimate acquire (between mkdir and owner.json rename).
  # Unconditional cleanup would tear down their in-flight acquisition and
  # break mutual exclusion. Only proceed if the lock dir already meets all
  # stale-reclaim conditions (no live creator marker AND mtime past grace);
  # otherwise refuse so the caller surfaces an error instead of silently
  # destroying a peer's acquire.
  if stale_lock_dir "$lock_path"; then
    rm -f "$lock_path"/.creator.* 2>/dev/null || true
    rmdir "$lock_path" 2>/dev/null || true
    return 0
  fi
  return 3
}

# stale_lock_dir <lock_path>
# Returns 0 if stale (safe to reclaim), 1 otherwise.
stale_lock_dir() {
  local lock_path="$1"
  [[ -d "$lock_path" ]] || return 1
  # 1. owner.json must be absent.
  [[ -f "$lock_path/owner.json" ]] && return 1
  # 2. creator marker (if present) must reference a dead PID.
  local marker
  marker="$(ls -1 "$lock_path"/.creator.* 2>/dev/null | head -1 || true)"
  if [[ -n "$marker" ]]; then
    local marker_pid="${marker##*.creator.}"
    if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
      return 1
    fi
  fi
  # 3. lock_path mtime must be older than reclaim grace.
  local now mtime age
  now="$(date +%s)"
  mtime="$(mtime_epoch "$lock_path")"
  age=$((now - mtime))
  (( age >= LOCK_RECLAIM_GRACE )) || return 1
  return 0
}

_iso_after_seconds() {
  local seconds="$1"
  if date -u -v+"${seconds}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return 0
  fi
  date -u -d "@$(( $(date +%s) + seconds ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# --- Registry entry I/O ----------------------------------------------------

entry_path() {
  local root="$1" run_id="$2"
  printf '%s/runs/%s.json\n' "$root" "$run_id"
}

write_entry_atomic() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  local tmp="$path.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$path"
}

# update_entry_field <path> <jq_expr>
# Updates the JSON entry at <path> by applying <jq_expr> (using --argjson now).
update_entry_field() {
  local path="$1" expr="$2"
  [[ -f "$path" ]] || die 3 "registry entry not found: $path"
  local now updated tmp
  now="$(now_utc)"
  updated="$(jq --arg now "$now" "$expr" "$path")"
  tmp="$path.tmp.$$"
  printf '%s' "$updated" > "$tmp"
  mv "$tmp" "$path"
}

# --- Subcommands ----------------------------------------------------------

cmd_identity() {
  local workspace=""
  while (( $# > 0 )); do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      *) die 1 "identity: unknown arg $1" ;;
    esac
  done
  [[ -n "$workspace" ]] || die 1 "identity: --workspace required"
  local identity
  identity="$(repo_identity_for "$workspace")"
  [[ -n "$identity" ]] || die 2 "identity: cannot resolve repo identity for $workspace"
  printf '%s\n' "$identity"
}

# entry_is_stale <entry-path> [legacy_dead_pid_only]
# Returns 0 if the active entry is stale. Dead owner pid is always stale. An
# expired heartbeat is stale ONLY when the second arg is empty — for legacy
# entries (second arg non-empty) a live pid with an old heartbeat is NOT stale,
# because the pre-rename helper had no background heartbeat loop (introduced by
# DEC-049) so its last_heartbeat_at is always old; treating that as stale would
# let a still-running legacy run be ignored and a second /run register (P2:479).
# DEC-049 #1 P2-B / P2:479.
entry_is_stale() {
  local entry="$1" legacy_dead_pid_only="${2:-}" status pid last now_e last_e age
  status="$(jq -r .status "$entry" 2>/dev/null || echo "")"
  [[ "$status" == "active" ]] || return 1
  pid="$(jq -r .pid "$entry" 2>/dev/null || echo "0")"
  if [[ "$pid" != "0" ]] && ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # legacy entries: only a dead pid marks them stale (heartbeat contract differs).
  [[ -n "$legacy_dead_pid_only" ]] && return 1
  last="$(jq -r .last_heartbeat_at "$entry" 2>/dev/null || echo "")"
  if [[ -n "$last" ]]; then
    now_e="$(date +%s)"
    last_e="$(_iso_to_epoch "$last")"
    age=$((now_e - last_e))
    (( age >= HEARTBEAT_TTL )) && return 0
  fi
  return 1
}

# list_active_runs_for_repo <root> <identity>
# stdout: JSON array of active entries (status == "active") for the logical
# repo at $identity. Used by the PA-1.1c register collision gate and by
# tests that need to inspect post-register state. Always emits valid JSON
# (`[]` when none); never errors on missing dirs.
list_active_runs_for_repo() {
  local root="$1" identity="$2"
  local entries=()
  local scan_root legacy_root
  legacy_root="$(legacy_registry_root_for "$identity")"
  # 새 root + (transition) legacy dev-cycle root 둘 다 스캔한다 (DEC-049 #1).
  # 전환기에 구 `${…}/dev-cycle/registry`에 active run이 남아 있으면 register
  # collision gate가 그것을 보게 한다. legacy entry는 새 helper의 gc/release가
  # 닿지 못하므로, stale(pid 사망 / heartbeat 만료)인 legacy entry는 collision
  # 판정에서 제외해 crashed pre-rename run이 모든 /run을 영구 차단하지 않게 한다
  # (P2-B). live legacy entry는 그대로 collision으로 남는다(구 도구로 release).
  for scan_root in "$root" "$legacy_root"; do
    [[ -n "$scan_root" && -d "$scan_root/runs" ]] || continue
    while IFS= read -r entry; do
      local id status
      id="$(jq -r .repo_identity "$entry" 2>/dev/null || echo "")"
      status="$(jq -r .status "$entry" 2>/dev/null || echo "")"
      [[ "$id" == "$identity" && "$status" == "active" ]] || continue
      if [[ "$scan_root" == "$legacy_root" ]] && entry_is_stale "$entry" legacy; then
        continue
      fi
      entries+=("$entry")
    done < <(find "$scan_root/runs" -maxdepth 1 -name '*.json' 2>/dev/null | sort)
  done
  if (( ${#entries[@]} == 0 )); then
    printf '[]\n'
  else
    jq -s '.' "${entries[@]}"
  fi
}

cmd_register() {
  local rtype="" workspace="" agent="other" owner_pid=""
  while (( $# > 0 )); do
    case "$1" in
      --type)      rtype="$2"; shift 2 ;;
      --workspace) workspace="$2"; shift 2 ;;
      --agent)     agent="$2"; shift 2 ;;
      --pid)       owner_pid="$2"; shift 2 ;;
      *) die 1 "register: unknown arg $1" ;;
    esac
  done
  [[ "$rtype" == "solo" || "$rtype" == "team" ]] || \
    die 3 "register: --type must be solo or team"
  [[ -n "$workspace" ]] || die 1 "register: --workspace required"
  case "$agent" in claude|codex|other) ;; *) die 3 "register: --agent must be claude|codex|other" ;; esac

  # Caller PID resolution. The helper itself is short-lived; storing $$ would
  # cause gc to immediately mark the entry stale on the next sweep. Resolve
  # in order: --pid override (explicit), PA_REGISTRY_OWNER_PID env var,
  # PPID (the caller process that invoked the helper).
  if [[ -z "$owner_pid" ]]; then
    owner_pid="${PA_REGISTRY_OWNER_PID:-}"
  fi
  if [[ -z "$owner_pid" ]]; then
    owner_pid="$PPID"
  fi
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || die 3 "register: invalid owner pid '$owner_pid'"

  # Canonicalize workspace path. Callers may pass `.`, `../foo`, or
  # symlinked paths; later overlap/isolation checks (PA-3.x) and
  # heartbeat self-checks must compare on a stable absolute form.
  local workspace_canonical
  workspace_canonical="$(cd "$workspace" 2>/dev/null && pwd -P || true)"
  [[ -n "$workspace_canonical" ]] || die 2 "register: workspace path does not exist or is not accessible: $workspace"
  workspace="$workspace_canonical"

  local identity
  identity="$(repo_identity_for "$workspace")"
  [[ -n "$identity" ]] || die 2 "register: cannot resolve repo identity for $workspace"

  local root
  root="$(registry_root_for "$identity")"
  mkdir -p "$root/runs" "$root/locks/branches" "$root/locks/slices"
  local original
  original="$(git -C "$workspace" remote get-url origin 2>/dev/null || true)"
  [[ -z "$original" ]] && original="$identity"
  ensure_repo_manifest "$root" "$identity" "$original"

  # PA-1.1c atomic active-run collision gate.
  #
  # Serialize concurrent register calls for this logical repo by acquiring
  # a repo-scoped advisory lock dir before scanning active entries. Without
  # this gate, two concurrent registrations could both observe active=0
  # (via /run wrapper's cooperative pre-check or via a direct caller) and
  # both write active entries, violating the single-run invariant.
  #
  # The lock window is short — active scan + run_id allocation + entry
  # write — so contention sleeps are bounded. acquire_lock_dir's existing
  # stale-lock salvage path recovers from a SIGKILL'd holder past the
  # heartbeat TTL.
  local register_lock="$root/locks/register"
  local register_lock_run
  register_lock_run="register-$$-${RANDOM}-$(now_utc | tr ':T' '--')"
  local register_lock_attempts=0
  while ! ( acquire_lock_dir "$register_lock" "$register_lock_run" "$$" \
              "$workspace" "register" "$identity" ) 2>/dev/null; do
    register_lock_attempts=$((register_lock_attempts + 1))
    if (( register_lock_attempts > 50 )); then
      die 5 "register: register lock contention timeout after $register_lock_attempts attempts"
    fi
    sleep 0.1
  done
  # Release the lock on any unexpected exit from this function. The trap
  # is reset before the function returns or exits explicitly.
  # shellcheck disable=SC2064  # we want the variables expanded NOW.
  trap "release_lock_dir '$register_lock' '$register_lock_run' >/dev/null 2>&1 || true" EXIT

  local active_runs_json active_count
  active_runs_json="$(list_active_runs_for_repo "$root" "$identity")"
  active_count="$(printf '%s' "$active_runs_json" | jq 'length')"
  if (( active_count > 0 )); then
    release_lock_dir "$register_lock" "$register_lock_run" >/dev/null 2>&1 || true
    trap - EXIT
    jq -n --arg id "$identity" --argjson runs "$active_runs_json" '{
      schema_version: 1,
      kind: "run_registry_active_run_collision",
      result: "rejected",
      reason: "active_run_collision",
      logical_repo: $id,
      active_runs: $runs,
      escape_hint: "Force-add is deferred to PA-3.1 (--allow-additional on /run-team)."
    }'
    exit 6
  fi

  # Run identifier with a uniqueness retry on improbable timestamp collision.
  local run_id epath now
  # Acquire the run_id slot atomically. `set -C` + `>` on a non-existent
  # path is O_CREAT|O_EXCL; if two concurrent registrations generate the
  # same run_id in the same second, only one wins the placeholder write
  # and the loser retries. This replaces the previous check-then-write
  # sequence that could silently overwrite a peer entry.
  local placeholder_attempts=0
  while :; do
    run_id="$(gen_run_id)"
    epath="$(entry_path "$root" "$run_id")"
    if ( set -C; : > "$epath" ) 2>/dev/null; then
      break
    fi
    placeholder_attempts=$((placeholder_attempts + 1))
    if (( placeholder_attempts > 16 )); then
      die 5 "register: could not allocate a unique run_id slot after 16 attempts"
    fi
  done
  now="$(now_utc)"

  local entry
  entry="$(jq -n --arg run "$run_id" --arg type "$rtype" --arg id "$identity" \
                 --arg ws "$workspace" --arg agent "$agent" --arg pid "$owner_pid" \
                 --arg now "$now" '{
    schema_version: 1,
    kind: "run_registry_entry",
    run_id: $run,
    type: $type,
    repo_identity: $id,
    workspace_path: $ws,
    agent_session: $agent,
    pid: ($pid | tonumber),
    started_at: $now,
    last_heartbeat_at: $now,
    status: "active",
    owned_branches: [],
    owned_slices: [],
    holds: { main_sync: false, land_queue: false },
    team: null,
    finished_at: null,
    abort_reason: null
  }')"
  write_entry_atomic "$epath" "$entry"
  # PA-1.1c: release the register gate now that the entry is durable.
  release_lock_dir "$register_lock" "$register_lock_run" >/dev/null 2>&1 || true
  trap - EXIT
  jq -nc --arg run "$run_id" --arg id "$identity" --arg root "$root" '{
    schema_version: 1,
    kind: "run_registry_register",
    run_id: $run,
    repo_identity: $id,
    registry_root: $root
  }'
}

cmd_release() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || die 1 "release: <run_id> required"
  local epath root
  epath="$(find_entry_path_by_run_id "$run_id")"
  [[ -n "$epath" ]] || die 3 "release: run_id $run_id not found"
  root="$(dirname "$(dirname "$epath")")"
  # First sweep: release locks currently visible (owner.json already written).
  release_all_locks_for_run "$root" "$run_id"
  # Update entry status; acquire-lock's post-mkdir status re-check now sees
  # 'finished' and will surrender any lock it just produced.
  update_entry_field "$epath" '.status = "finished" | .finished_at = $now | .holds = { main_sync: false, land_queue: false }'
  # Second sweep: catch any lock whose owner.json was written between the
  # first sweep and the status update (concurrent acquire-lock racing). The
  # acquire-lock helper also surrenders on its own status re-check; this
  # sweep narrows the residual window further by mopping any lock that
  # landed with our run_id as holder during status update.
  release_all_locks_for_run "$root" "$run_id"
  jq -nc --arg run "$run_id" '{schema_version:1, kind:"run_registry_release", run_id:$run, status:"finished"}'
}

cmd_acquire_lock() {
  local run_id="" lock_name="" origin=""
  while (( $# > 0 )); do
    case "$1" in
      --run)    run_id="$2"; shift 2 ;;
      --lock)   lock_name="$2"; shift 2 ;;
      --origin) origin="$2"; shift 2 ;;
      *) die 1 "acquire-lock: unknown arg $1" ;;
    esac
  done
  [[ -n "$run_id" && -n "$lock_name" ]] || die 1 "acquire-lock: --run and --lock required"
  local epath root entry workspace status
  epath="$(find_entry_path_by_run_id "$run_id")"
  [[ -n "$epath" ]] || die 3 "acquire-lock: run_id $run_id not found"
  root="$(dirname "$(dirname "$epath")")"
  status="$(jq -r .status "$epath")"
  # Refuse to bind a new lock to a non-active run. Otherwise a finished/
  # aborted run could orphan locks that gc only reclaims via active-entry
  # stale handling or empty-dir recovery.
  [[ "$status" == "active" ]] || die 3 "acquire-lock: run_id $run_id status is '$status'; only 'active' may acquire locks"
  workspace="$(jq -r .workspace_path "$epath")"
  local lock_path
  lock_path="$(lock_path_for "$root" "$lock_name" "$origin")"
  acquire_lock_dir "$lock_path" "$run_id" "$$" "$workspace" "$lock_name" "$origin"
  # TOCTOU re-check: the initial status read happened before mkdir/owner.json
  # creation. A concurrent `release <run_id>` may have flipped status from
  # active to finished between the check and the owner.json rename, and its
  # release_all_locks_for_run sweep would not see this lock (owner.json was
  # not yet present when release ran). Re-read status after owner.json is in
  # place; if the run is no longer active, surrender the lock immediately so
  # a finished/aborted run cannot hold main_sync/land_queue indefinitely.
  local status_after
  status_after="$(jq -r .status "$epath" 2>/dev/null || echo "")"
  if [[ "$status_after" != "active" ]]; then
    release_lock_dir "$lock_path" "$run_id" >/dev/null 2>&1 || true
    die 5 "acquire-lock: run_id $run_id transitioned to '$status_after' during acquire; lock surrendered"
  fi
  # Update cached holds for fixed-name locks.
  case "$lock_name" in
    main_sync|land_queue)
      update_entry_field "$epath" ".holds.$lock_name = true | .last_heartbeat_at = \$now"
      ;;
  esac
  jq -nc --arg run "$run_id" --arg name "$lock_name" --arg path "$lock_path" '{
    schema_version:1, kind:"run_registry_acquire", run_id:$run, lock_name:$name, lock_path:$path
  }'
}

cmd_release_lock() {
  local run_id="" lock_name="" origin=""
  while (( $# > 0 )); do
    case "$1" in
      --run)    run_id="$2"; shift 2 ;;
      --lock)   lock_name="$2"; shift 2 ;;
      --origin) origin="$2"; shift 2 ;;
      *) die 1 "release-lock: unknown arg $1" ;;
    esac
  done
  [[ -n "$run_id" && -n "$lock_name" ]] || die 1 "release-lock: --run and --lock required"
  local epath root
  epath="$(find_entry_path_by_run_id "$run_id")"
  [[ -n "$epath" ]] || die 3 "release-lock: run_id $run_id not found"
  root="$(dirname "$(dirname "$epath")")"
  local lock_path
  lock_path="$(lock_path_for "$root" "$lock_name" "$origin")"
  set +e
  release_lock_dir "$lock_path" "$run_id"
  local rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) die 5 "release-lock: lock $lock_name is held by another run; refused to release" ;;
    3) die 5 "release-lock: lock $lock_name is in an in-flight acquire window (no owner.json, creator marker live or mtime within grace); refused" ;;
    *) die 1 "release-lock: unexpected release_lock_dir status $rc" ;;
  esac
  case "$lock_name" in
    main_sync|land_queue)
      update_entry_field "$epath" ".holds.$lock_name = false | .last_heartbeat_at = \$now"
      ;;
  esac
  jq -nc --arg run "$run_id" --arg name "$lock_name" '{
    schema_version:1, kind:"run_registry_release_lock", run_id:$run, lock_name:$name
  }'
}

cmd_heartbeat() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || die 1 "heartbeat: <run_id> required"
  local epath
  epath="$(find_entry_path_by_run_id "$run_id")"
  [[ -n "$epath" ]] || die 3 "heartbeat: run_id $run_id not found"
  # Self-check: if status flipped away from active, surface the actual
  # status instead of refreshing the timestamp. This covers both
  # externally-aborted entries (self-heartbeat-check) and finished
  # entries (callers must not treat a completed run as active).
  local status
  status="$(jq -r .status "$epath")"
  if [[ "$status" != "active" ]]; then
    local note=""
    case "$status" in
      aborted)  note="self-heartbeat-check: entry already marked aborted" ;;
      finished) note="heartbeat on finished run is a no-op" ;;
      *)        note="entry status is '$status'; heartbeat skipped" ;;
    esac
    jq -nc --arg run "$run_id" --arg status "$status" --arg note "$note" \
      '{schema_version:1, kind:"run_registry_heartbeat", run_id:$run, status:$status, note:$note}'
    return 0
  fi
  update_entry_field "$epath" '.last_heartbeat_at = $now'
  jq -nc --arg run "$run_id" '{schema_version:1, kind:"run_registry_heartbeat", run_id:$run, status:"active"}'
}

cmd_list() {
  local target_repo="" all_status=false
  while (( $# > 0 )); do
    case "$1" in
      --repo)       target_repo="$2"; shift 2 ;;
      --all-status) all_status=true; shift ;;
      *) die 1 "list: unknown arg $1" ;;
    esac
  done
  local registry_parent
  registry_parent="$(state_home_default)/registry"
  if [[ ! -d "$registry_parent" ]]; then
    printf '[]\n'
    return 0
  fi
  local entries=()
  while IFS= read -r entry; do
    if [[ -n "$target_repo" ]]; then
      local id
      id="$(jq -r .repo_identity "$entry" 2>/dev/null || echo "")"
      [[ "$id" == "$target_repo" ]] || continue
    fi
    local status
    status="$(jq -r .status "$entry" 2>/dev/null || echo "")"
    if [[ "$all_status" != "true" && "$status" != "active" ]]; then
      continue
    fi
    entries+=("$entry")
  done < <(find "$registry_parent" -mindepth 3 -maxdepth 3 -name '*.json' -path '*/runs/*' 2>/dev/null | sort)
  if (( ${#entries[@]} == 0 )); then
    printf '[]\n'
  else
    jq -s '.' "${entries[@]}"
  fi
}

cmd_gc() {
  local target_repo=""
  while (( $# > 0 )); do
    case "$1" in
      --repo) target_repo="$2"; shift 2 ;;
      *) die 1 "gc: unknown arg $1" ;;
    esac
  done
  local registry_parent scan_root
  registry_parent="$(state_home_default)/registry"
  if [[ ! -d "$registry_parent" ]]; then
    jq -nc '{schema_version:1, kind:"run_registry_gc", reclaimed:[]}'
    return 0
  fi
  # Constrain both entry and lock-dir sweeps to the requested repo when
  # --repo is set. Without this scoping, a per-repo gc could reclaim lock
  # dirs belonging to unrelated repos sharing the same state home.
  if [[ -n "$target_repo" ]]; then
    local target_key
    target_key="$(repo_dir_key "$target_repo")"
    scan_root="$registry_parent/$target_key"
    if [[ ! -d "$scan_root" ]]; then
      jq -nc '{schema_version:1, kind:"run_registry_gc", reclaimed:[]}'
      return 0
    fi
  else
    scan_root="$registry_parent"
  fi
  local reclaimed_count=0
  local reclaimed_runs=()
  while IFS= read -r entry; do
    if [[ -n "$target_repo" ]]; then
      local id
      id="$(jq -r .repo_identity "$entry" 2>/dev/null || echo "")"
      [[ "$id" == "$target_repo" ]] || continue
    fi
    local status pid last
    status="$(jq -r .status "$entry" 2>/dev/null || echo "")"
    [[ "$status" == "active" ]] || continue
    pid="$(jq -r .pid "$entry" 2>/dev/null || echo "0")"
    last="$(jq -r .last_heartbeat_at "$entry" 2>/dev/null || echo "")"
    local reason=""
    if [[ "$pid" != "0" ]] && ! kill -0 "$pid" 2>/dev/null; then
      reason="stale (pid $pid dead)"
    elif [[ -n "$last" ]]; then
      local now_e last_e age
      now_e="$(date +%s)"
      last_e="$(_iso_to_epoch "$last")"
      age=$((now_e - last_e))
      if (( age >= HEARTBEAT_TTL )); then
        reason="stale (heartbeat expired, age=${age}s, ttl=${HEARTBEAT_TTL}s)"
      fi
    fi
    if [[ -n "$reason" ]]; then
      local run_id
      run_id="$(jq -r .run_id "$entry")"
      local root
      root="$(dirname "$(dirname "$entry")")"
      # Reclaim with same salvage discipline as lock stale-recovery.
      release_all_locks_for_run "$root" "$run_id"
      update_entry_field "$entry" ".status = \"aborted\" | .abort_reason = \"$reason\" | .finished_at = \$now"
      reclaimed_runs+=("$run_id")
      reclaimed_count=$((reclaimed_count + 1))
    fi
  done < <(find "$scan_root" -mindepth 1 -maxdepth 3 -name '*.json' -path '*/runs/*' 2>/dev/null)
  # Scan lock directories for stale (no associated active run). Scoped to
  # the same scan_root as the entry sweep so --repo gc cannot reclaim
  # locks belonging to other repos.
  while IFS= read -r ldir; do
    if stale_lock_dir "$ldir"; then
      # Try salvage rename + remove.
      local salvage="$ldir.gcsalvage.$$.$RANDOM"
      if mv "$ldir" "$salvage" 2>/dev/null; then
        rm -rf "$salvage"
      fi
    fi
  done < <(find "$scan_root" -mindepth 1 -type d -name '*.lock' 2>/dev/null)
  if (( ${#reclaimed_runs[@]} == 0 )); then
    jq -nc '{schema_version:1, kind:"run_registry_gc", reclaimed:[]}'
  else
    printf '%s\n' "${reclaimed_runs[@]}" | jq -Rsc 'split("\n") | map(select(length>0)) | {schema_version:1, kind:"run_registry_gc", reclaimed: .}'
  fi
}

# --- Internal lookups -----------------------------------------------------

find_entry_path_by_run_id() {
  local run_id="$1"
  local registry_parent
  registry_parent="$(state_home_default)/registry"
  [[ -d "$registry_parent" ]] || return 0
  # run_id uniqueness is enforced per repo (placeholder O_EXCL inside
  # cmd_register), but the 8-hex suffix has a non-zero collision chance
  # across repos. Refuse to act if more than one repo holds the same
  # run_id filename — caller would otherwise mutate the wrong run.
  local matches
  matches=$(find "$registry_parent" -mindepth 3 -maxdepth 3 -name "$run_id.json" -path '*/runs/*' 2>/dev/null)
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if (( count > 1 )); then
    die 5 "find_entry_path_by_run_id: run_id $run_id ambiguous across repos: $(printf '%s' "$matches" | tr '\n' ' ')"
  fi
  printf '%s\n' "$matches" | head -1
}

lock_path_for() {
  local root="$1" name="$2" origin="${3:-}"
  case "$name" in
    main_sync|land_queue)
      printf '%s/locks/%s.lock\n' "$root" "$name"
      ;;
    branch:*|slice:*)
      local kind="${name%%:*}" raw="${name#*:}"
      # Empty suffix would yield an empty repo_dir_key and create a
      # shared `.lock` directory. Unrelated callers with malformed
      # lock names would then false-contend with each other.
      [[ -n "$raw" ]] || die 3 "lock_path_for: '$kind:' requires a non-empty identifier (got '$name')"
      local key
      key="$(repo_dir_key "$raw")"
      local dir
      if [[ "$kind" == "branch" ]]; then dir="branches"; else dir="slices"; fi
      printf '%s/locks/%s/%s.lock\n' "$root" "$dir" "$key"
      ;;
    *)
      die 3 "lock_path_for: unknown lock name '$name'"
      ;;
  esac
}

release_all_locks_for_run() {
  local root="$1" run_id="$2"
  local lf
  while IFS= read -r lf; do
    [[ -f "$lf" ]] || continue
    local owner
    owner="$(jq -r '.holder_run_id // empty' "$lf" 2>/dev/null || true)"
    if [[ "$owner" == "$run_id" ]]; then
      # We pre-filtered by ownership, so release_lock_dir's mismatch
      # branch (rc=2) cannot fire. Use set +e defensively so a stat
      # race between the owner check and the rmdir does not abort the
      # whole sweep.
      set +e
      release_lock_dir "$(dirname "$lf")" "$run_id"
      set -e
    fi
  done < <(find "$root/locks" -type f -name 'owner.json' 2>/dev/null)
}

_iso_to_epoch() {
  local iso="$1"
  # Try GNU date, then BSD date.
  date -u -d "$iso" +%s 2>/dev/null || \
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || \
    echo 0
}

# --- Dispatch -------------------------------------------------------------

require_cmd jq
require_cmd date
require_cmd find

usage_short() {
  cat <<'EOF'
usage: run-registry.sh <subcommand> [options]
  identity --workspace <path>
  register --type solo|team --workspace <path> [--agent claude|codex|other]
  release <run_id>
  acquire-lock --run <run_id> --lock <name> [--origin <text>]
  release-lock --run <run_id> --lock <name>
  heartbeat <run_id>
  list [--repo <identity>] [--all-status]
  gc [--repo <identity>]
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    identity)     cmd_identity "$@" ;;
    register)     cmd_register "$@" ;;
    release)      cmd_release "$@" ;;
    acquire-lock) cmd_acquire_lock "$@" ;;
    release-lock) cmd_release_lock "$@" ;;
    heartbeat)    cmd_heartbeat "$@" ;;
    list)         cmd_list "$@" ;;
    gc)           cmd_gc "$@" ;;
    help|-h|--help|"") usage_short ;;
    *) usage_short >&2; die 1 "unknown subcommand: $cmd" ;;
  esac
}

main "$@"
