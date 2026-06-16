#!/usr/bin/env bash
# PA-3.2-impl resource-lock — named lock primitive for canonical ledger
# protection and PA-3.4 dispatch slice claim.
#
# Design: docs/design/systems/canonical-ledger-protection.md §1.1-1.5
# Decision: DEC-040 (Q-045/046/047 lock).
# Pattern: PA-1.1 scripts/run-registry.sh:227-322 (atomic rename salvage)
# generalized to named locks.
#
# Subcommands:
#   acquire <name> [--wait <sec>] [--ttl <sec>] [--caller-pid <pid>] [--json]
#       → response envelope `.extra.nonce` MUST be captured by the caller;
#         subsequent release/heartbeat present it via `--nonce` or
#         `RESOURCE_LOCK_NONCE`. PR #64 round 3 F2/F3 (DEC-040): when
#         holder.json carries a nonce, missing/mismatched nonce is rejected
#         as `not_holder` — no caller_pid-only fallback.
#   release <name> [--caller-pid <pid>] [--nonce <hex>] [--json]
#   heartbeat <name> [--caller-pid <pid>] [--nonce <hex>] [--json]
#   status <name> [--json]
#   list [--json]
#
# Lock name: <scope>:<resource>. Examples: `ledger:all`, `slice:PA-3.2`.
#
# Env:
#   RESOURCE_LOCK_HOME       default `${XDG_STATE_HOME:-$HOME/.local/state}/my-skill/resource-locks`
#   RESOURCE_LOCK_TTL        default 300 (heartbeat expiry; design §1.4)
#   RESOURCE_LOCK_GRACE      default 60 (in-flight acquire grace; design §1.4)
#   RESOURCE_LOCK_OUTPUT     `json` enables JSON observation on stdout. Default
#                            `human`. Equivalent CLI flag: --json.
#   RESOURCE_LOCK_CALLER_PID stable caller identity used as holder ownership.
#                            CLI flag --caller-pid takes precedence; default
#                            is $PPID (helper's parent shell — same caller
#                            across acquire/heartbeat/release in same shell).
#
# Exit codes:
#   0 → operation succeeded (acquired / released / heartbeat / status ok)
#   1 → bad arguments (missing name, invalid flag, unknown subcommand)
#   2 → busy (acquire timed out)
#   4 → required command missing
#   5 → split-brain race during salvage (caller should retry)
#   6 → not_holder (release/heartbeat called by non-owner; or non-existent
#       lock for those subcommands)

set -euo pipefail

# --- Defaults --------------------------------------------------------------

RESOURCE_LOCK_HOME_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/my-skill/resource-locks"
RESOURCE_LOCK_HOME="${RESOURCE_LOCK_HOME:-$RESOURCE_LOCK_HOME_DEFAULT}"
RESOURCE_LOCK_TTL="${RESOURCE_LOCK_TTL:-300}"
RESOURCE_LOCK_GRACE="${RESOURCE_LOCK_GRACE:-60}"
RESOURCE_LOCK_OUTPUT="${RESOURCE_LOCK_OUTPUT:-human}"

# --- Generic helpers (lifted from PA-1.1 run-registry.sh) ------------------

die() {
  local code="$1"; shift
  printf 'resource-lock: %s\n' "$*" >&2
  exit "$code"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 4 "missing required command: $1"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# mtime_epoch <path>: GNU/BSD stat split (run-registry.sh:91-107).
mtime_epoch() {
  local path="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$path" 2>/dev/null || echo 0
  else
    stat -c %Y -- "$path" 2>/dev/null || echo 0
  fi
}

_iso_after_seconds() {
  local secs="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    date -u -v+"${secs}"S +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "+${secs} seconds" +%Y-%m-%dT%H:%M:%SZ
  fi
}

_validate_positive_int() {
  local var_name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) \
    || die 1 "$var_name must be a positive integer (got: $value)"
}

_validate_positive_int RESOURCE_LOCK_TTL "$RESOURCE_LOCK_TTL"
# GRACE 0 is semantically valid (disable in-flight grace; treat any
# holderless dir as immediately stale). Allow non-negative.
[[ "$RESOURCE_LOCK_GRACE" =~ ^[0-9]+$ ]] \
  || die 1 "RESOURCE_LOCK_GRACE must be a non-negative integer (got: $RESOURCE_LOCK_GRACE)"

case "$RESOURCE_LOCK_OUTPUT" in
  human|json) ;;
  *) die 1 "RESOURCE_LOCK_OUTPUT must be 'human' or 'json' (got: $RESOURCE_LOCK_OUTPUT)" ;;
esac

require_cmd jq

# --- Lock name validation --------------------------------------------------

# parse_lock_name <name>
# stdout: "<scope>\t<resource>" on success.
# die 1 on invalid input. Names are <scope>:<resource> where scope and
# resource consist of [A-Za-z0-9._-]+.
parse_lock_name() {
  local name="$1"
  [[ -z "$name" ]] && die 1 "lock name required"
  if [[ ! "$name" =~ ^([A-Za-z0-9._-]+):([A-Za-z0-9._-]+)$ ]]; then
    die 1 "lock name must be <scope>:<resource> with [A-Za-z0-9._-]+ parts (got: $name)"
  fi
  # PR #64 round 4 F2: reject `.` and `..` components. A name like
  # `ledger:..` would map onto the parent lock namespace via mkdir /
  # stale_lock_dir (path traversal) rather than a private lock dir.
  local s="${BASH_REMATCH[1]}" r="${BASH_REMATCH[2]}"
  for part in "$s" "$r"; do
    if [[ "$part" == "." || "$part" == ".." ]]; then
      die 1 "lock name components '.'/'..' are not allowed (got: $name)"
    fi
  done
  printf '%s\t%s\n' "$s" "$r"
}

# --- Repo identity (lifted from PA-1.1 run-registry.sh §2) -----------------

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print substr($1, 1, 16)}'
  else
    sha256sum | awk '{print substr($1, 1, 16)}'
  fi
}

normalize_identity() {
  local url="$1"
  [[ -z "$url" ]] && return 0
  local hostpath=""
  if [[ "$url" =~ ^(([^@:/]+)@)?([^@:/]+):([^/].*)$ ]] && [[ "$url" != http*://* ]] && [[ "$url" != ssh://* ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  elif [[ "$url" =~ ^ssh://(([^@/]+)@)?([^/]+)/(.+)$ ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  elif [[ "$url" =~ ^https?://(([^@/]+)@)?([^/]+)/(.+)$ ]]; then
    hostpath="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  else
    hostpath="$url"
  fi
  hostpath="${hostpath%.git}"
  while [[ "$hostpath" == */ ]]; do hostpath="${hostpath%/}"; done
  local host="${hostpath%%/*}" path="${hostpath#*/}" host_lc
  host_lc="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  if [[ "$host" == "$hostpath" ]]; then
    printf '%s\n' "$host_lc"
  else
    printf '%s/%s\n' "$host_lc" "$path"
  fi
}

repo_identity_for() {
  local workspace="$1"
  [[ -d "$workspace/.git" || -f "$workspace/.git" ]] \
    || git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1 \
    || return 0
  local origin_url=""
  origin_url="$(git -C "$workspace" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin_url" ]]; then
    normalize_identity "$origin_url"
    return 0
  fi
  local common_dir canonical
  common_dir="$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -z "$common_dir" ]] && return 0
  if [[ "$common_dir" != /* ]]; then
    common_dir="$(cd "$workspace" && cd "$common_dir" 2>/dev/null && pwd)"
  fi
  canonical="$(cd "$common_dir" 2>/dev/null && pwd -P || printf '%s' "$common_dir")"
  local hash
  hash="$(printf '%s' "$canonical" | sha256_hex)"
  printf 'local__%s\n' "$hash"
}

repo_dir_key() {
  local identity="$1"
  [[ -z "$identity" ]] && return 0
  local slug hash
  slug="$(printf '%s' "$identity" | tr '/' '_' | LC_ALL=C sed 's/[^A-Za-z0-9._-]//g')"
  hash="$(printf '%s' "$identity" | sha256_hex)"
  printf '%s__%s\n' "$slug" "$hash"
}

# Resolve repo id from cwd; fall back to `local__<workspace-hash>` if no
# origin is available.
resolve_repo_id() {
  local id
  id="$(repo_identity_for "$(pwd)" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    id="local__$(printf '%s' "$(pwd)" | sha256_hex)"
  fi
  repo_dir_key "$id"
}

# lock_path_for <scope> <resource>
# Stdout: full lock directory path under RESOURCE_LOCK_HOME/<repo_id>/<scope>/<resource>.
lock_path_for() {
  local scope="$1" resource="$2"
  local repo_id
  repo_id="$(resolve_repo_id)"
  printf '%s/%s/%s/%s\n' "$RESOURCE_LOCK_HOME" "$repo_id" "$scope" "$resource"
}

# --- Stale judgement (design §1.4) -----------------------------------------

# is_pid_alive <pid>: kill -0 success. echo 0/1 on stdout.
is_pid_alive() {
  local pid="$1"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then echo 0; return; fi
  if kill -0 "$pid" 2>/dev/null; then echo 1; else echo 0; fi
}

# holder_is_stale <lock_path>
# Returns 0 (stale) or 1 (live) via exit code. Two signals (design §1.4):
#   - caller_pid dead
#   - heartbeat_at older than RESOURCE_LOCK_TTL seconds
holder_is_stale() {
  local lock_path="$1"
  [[ -f "$lock_path/holder.json" ]] || return 0  # no holder file = stale
  local pid host hb_at ttl
  pid="$(jq -r '.caller_pid // empty' "$lock_path/holder.json" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$lock_path/holder.json" 2>/dev/null || true)"
  hb_at="$(jq -r '.heartbeat_at // empty' "$lock_path/holder.json" 2>/dev/null || true)"
  # ttl from holder.json (acquire-time per-call --ttl override is persisted).
  # Fall back to env default when holder.json predates ttl_seconds field.
  ttl="$(jq -r '.ttl_seconds // empty' "$lock_path/holder.json" 2>/dev/null || true)"
  [[ -z "$ttl" || ! "$ttl" =~ ^[0-9]+$ ]] && ttl="$RESOURCE_LOCK_TTL"
  # host mismatch signal (DEC-040 round 2 F2): if RESOURCE_LOCK_HOME is on
  # a shared/networked path, holder.host names another machine. Local PID
  # number may coincidentally exist on this host (unrelated process); only
  # same-host alive PID is a valid holder. Treat host-mismatched holder as
  # stale so the local caller does not block on an unrelated remote PID.
  if [[ -n "$host" ]] && [[ "$host" != "$(current_host)" ]]; then
    return 0
  fi
  # pid signal
  if [[ -n "$pid" ]] && [[ "$(is_pid_alive "$pid")" == "0" ]]; then
    return 0
  fi
  # heartbeat signal (uses ttl from holder.json so per-call --ttl is honored).
  if [[ -n "$hb_at" ]]; then
    local hb_epoch now_epoch
    if [[ "$(uname -s)" == "Darwin" ]]; then
      hb_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$hb_at" +%s 2>/dev/null || echo 0)"
    else
      hb_epoch="$(date -u -d "$hb_at" +%s 2>/dev/null || echo 0)"
    fi
    now_epoch="$(date -u +%s)"
    if (( now_epoch - hb_epoch > ttl )); then
      return 0
    fi
  fi
  return 1
}

# stale_lock_dir <lock_path>
# Empty/holderless dir grace (design §1.4): if holder.json missing AND no
# .creator.* marker (or marker pid dead) AND dir mtime older than
# RESOURCE_LOCK_GRACE, it is stale. Otherwise treat as in-flight acquire.
# For non-empty holder.json case, delegate to holder_is_stale.
stale_lock_dir() {
  local lock_path="$1"
  [[ -d "$lock_path" ]] || return 1   # dir doesn't exist → not stale (nothing to salvage)
  if [[ -f "$lock_path/holder.json" ]]; then
    if holder_is_stale "$lock_path"; then return 0; else return 1; fi
  fi
  # holderless: look at creator marker
  local creator_files=()
  for f in "$lock_path"/.creator.*; do
    [[ -e "$f" ]] && creator_files+=("$f")
  done
  if (( ${#creator_files[@]} > 0 )); then
    # any alive creator → in-flight → not stale
    for cf in "${creator_files[@]}"; do
      local cpid="${cf##*.creator.}"
      if [[ "$(is_pid_alive "$cpid")" == "1" ]]; then return 1; fi
    done
  fi
  # No alive creator. Check grace window (mtime).
  # Use `>= RESOURCE_LOCK_GRACE` so GRACE=0 means "no grace at all" — any
  # holderless dir is immediately stale; with default 60 it stays in-flight
  # while younger than 60 seconds.
  local mt now_epoch
  mt="$(mtime_epoch "$lock_path")"
  now_epoch="$(date -u +%s)"
  if (( now_epoch - mt >= RESOURCE_LOCK_GRACE )); then
    return 0   # stale holderless dir past grace
  fi
  return 1     # in-flight grace window
}

# --- JSON observation envelope --------------------------------------------

# emit_envelope <subcommand> <result> <lock_name> <exit_code> [<extra_json>]
emit_envelope() {
  local subcommand="$1" result="$2" name="$3" exit_code="$4"
  local extra="${5:-}"
  [[ -z "$extra" ]] && extra='{}'
  if [[ "$RESOURCE_LOCK_OUTPUT" == "json" ]]; then
    jq -cn \
      --arg sub "$subcommand" \
      --arg result "$result" \
      --arg name "$name" \
      --argjson exit_code "$exit_code" \
      --argjson extra "$extra" '{
        schema_version: 1,
        kind: "resource_lock_observation",
        subcommand: $sub,
        result: $result,
        lock_name: $name,
        exit_code: $exit_code,
        extra: $extra
      }'
  else
    printf '%s: %s lock=%s rc=%s\n' "$subcommand" "$result" "$name" "$exit_code"
  fi
}

# --- Acquire (design §1.3) -------------------------------------------------

current_host() {
  hostname -s 2>/dev/null || hostname || echo unknown
}

# gen_nonce: 16 random hex chars. Per-acquire unique ownership token —
# release/heartbeat ownership checks compare `(caller_pid, nonce)` so
# same-shell same-second reclaims after stale recovery still distinguish
# the old snapshot from a new holder (DEC-040 round 2 F1).
gen_nonce() {
  LC_ALL=C head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16
}

# write_holder_json <lock_path> <caller_pid> [<recovered_from_json>]
write_holder_json() {
  local lock_path="$1" caller_pid="$2" recovered_from="${3:-null}"
  local host acquired expires hb tmp nonce
  host="$(current_host)"
  acquired="$(now_utc)"
  expires="$(_iso_after_seconds "$RESOURCE_LOCK_TTL")"
  hb="$acquired"
  nonce="$(gen_nonce)"
  tmp="$lock_path/holder.tmp.$caller_pid"
  jq -n --arg pid "$caller_pid" --arg host "$host" \
        --arg acq "$acquired" --arg exp "$expires" --arg hb "$hb" \
        --arg nonce "$nonce" \
        --argjson ttl "$RESOURCE_LOCK_TTL" \
        --argjson recovered "$recovered_from" '{
    schema_version: 1,
    kind: "resource_lock_holder",
    caller_pid: ($pid | tonumber),
    host: $host,
    nonce: $nonce,
    acquired_at: $acq,
    expires_at: $exp,
    heartbeat_at: $hb,
    ttl_seconds: $ttl,
    recovered_from: $recovered
  }' > "$tmp"
  mv "$tmp" "$lock_path/holder.json"
}

# snapshot_stale_holder <lock_path> → JSON string (or "null").
snapshot_stale_holder() {
  local lock_path="$1"
  if [[ -f "$lock_path/holder.json" ]]; then
    jq -c '. + {salvaged_at: now | strftime("%Y-%m-%dT%H:%M:%SZ")}' \
      "$lock_path/holder.json" 2>/dev/null || echo null
  else
    echo null
  fi
}

cmd_acquire() {
  local name="$1" wait_sec="$2" ttl_arg="$3" caller_pid="$4"
  local scope resource pair
  pair="$(parse_lock_name "$name")"
  scope="${pair%%$'\t'*}"
  resource="${pair##*$'\t'}"

  # canonical-ledger-protection §2.3 + run-team-orchestrator §5.2:
  # workers set LEDGER_EDIT_FORBIDDEN=1 to refuse `ledger:*` lock
  # acquisition. PA-3.1 orchestrator sets this env on every worker shell
  # so a worker cannot acquire a ledger lock even if it bypasses the
  # cooperative gate at the caller layer.
  if [[ "$scope" == "ledger" && "${LEDGER_EDIT_FORBIDDEN:-}" == "1" ]]; then
    local extra
    extra="$(jq -nc --arg scope "$scope" --arg res "$resource" \
      '{scope: $scope, resource: $res, reason: "LEDGER_EDIT_FORBIDDEN=1 worker context"}')"
    emit_envelope acquire forbidden_worker_context "$name" 6 "$extra"
    exit 6
  fi

  # Per-call TTL override.
  if [[ -n "$ttl_arg" ]]; then
    _validate_positive_int "--ttl" "$ttl_arg"
    RESOURCE_LOCK_TTL="$ttl_arg"
  fi

  local lock_path parent
  lock_path="$(lock_path_for "$scope" "$resource")"
  parent="$(dirname "$lock_path")"
  mkdir -p "$parent"

  local started now_epoch
  started="$(date -u +%s)"

  while true; do
    if mkdir "$lock_path" 2>/dev/null; then
      # Step 2: creator marker.
      : > "$lock_path/.creator.$$" 2>/dev/null || true
      # Step 3+4: write holder.json atomically.
      write_holder_json "$lock_path" "$caller_pid"
      # Step 5: remove creator marker.
      rm -f "$lock_path/.creator.$$" 2>/dev/null || true
      # Emit nonce in envelope so caller can stash + pass to
      # heartbeat/release (DEC-040 round 3 F2 ownership token).
      local emit_nonce
      emit_nonce="$(jq -r '.nonce' "$lock_path/holder.json")"
      local extra
      extra="$(jq -nc --arg path "$lock_path" --arg nonce "$emit_nonce" \
        '{lock_path: $path, nonce: $nonce}')"
      emit_envelope acquire acquired "$name" 0 "$extra"
      return 0
    fi
    # mkdir failed → contention or stale. Check stale.
    if stale_lock_dir "$lock_path"; then
      local salvage="$lock_path.salvage.$caller_pid.$RANDOM"
      if mv "$lock_path" "$salvage" 2>/dev/null; then
        # Re-check inside salvage (design §1.4 R2 finding F2c —
        # distinguish stale snapshot from live holder).
        if [[ -f "$salvage/holder.json" ]]; then
          if holder_is_stale "$salvage"; then
            # Confirmed stale snapshot. Capture for audit + remove + retry.
            local snap
            snap="$(snapshot_stale_holder "$salvage")"
            rm -rf "$salvage"
            # Loop back to mkdir; if we win, write holder.json with
            # recovered_from set.
            if mkdir "$lock_path" 2>/dev/null; then
              : > "$lock_path/.creator.$$" 2>/dev/null || true
              write_holder_json "$lock_path" "$caller_pid" "$snap"
              rm -f "$lock_path/.creator.$$" 2>/dev/null || true
              local emit_nonce
              emit_nonce="$(jq -r '.nonce' "$lock_path/holder.json")"
              local extra
              extra="$(jq -nc --arg path "$lock_path" --arg nonce "$emit_nonce" --argjson rec "$snap" \
                '{lock_path: $path, nonce: $nonce, recovered_from: $rec}')"
              emit_envelope acquire stale_reclaimed "$name" 0 "$extra"
              return 0
            fi
            # Another racer claimed it after our salvage — continue loop.
            continue
          else
            # Live holder appeared during salvage race. Try to put back.
            if ! mv -n "$salvage" "$lock_path" 2>/dev/null; then
              rm -rf "$salvage"
            fi
            local extra
            extra="$(jq -nc --arg path "$lock_path" \
              '{lock_path: $path, reason: "salvage_race_live_holder"}')"
            emit_envelope acquire split_brain_abort "$name" 5 "$extra"
            exit 5
          fi
        else
          # holderless in-flight crash recovery: just retry.
          rm -rf "$salvage"
          continue
        fi
      fi
      # Another racer salvaged first; loop and retry.
      continue
    fi
    # Live holder; wait if --wait remaining.
    now_epoch="$(date -u +%s)"
    if (( now_epoch - started >= wait_sec )); then
      local holder_pid
      holder_pid="$(jq -r '.caller_pid // empty' "$lock_path/holder.json" 2>/dev/null || true)"
      local extra
      extra="$(jq -nc --arg path "$lock_path" --arg pid "$holder_pid" \
        '{lock_path: $path, holder_caller_pid: (if $pid == "" then null else ($pid | tonumber) end)}')"
      emit_envelope acquire busy "$name" 2 "$extra"
      exit 2
    fi
    sleep 1
  done
}

# --- Release ---------------------------------------------------------------

cmd_release() {
  local name="$1" caller_pid="$2" expected_nonce="${3:-}"
  local pair scope resource lock_path
  pair="$(parse_lock_name "$name")"
  scope="${pair%%$'\t'*}"
  resource="${pair##*$'\t'}"
  lock_path="$(lock_path_for "$scope" "$resource")"

  if [[ ! -d "$lock_path" ]]; then
    local extra
    extra="$(jq -nc '{reason: "lock_dir_absent"}')"
    emit_envelope release not_holder "$name" 6 "$extra"
    exit 6
  fi
  if [[ ! -f "$lock_path/holder.json" ]]; then
    local extra
    extra="$(jq -nc '{reason: "holder_absent"}')"
    emit_envelope release not_holder "$name" 6 "$extra"
    exit 6
  fi

  # Capture (caller_pid, nonce) ownership token. nonce is a 16-hex
  # per-acquire random string written by write_holder_json (DEC-040 round 2
  # F1). The caller MUST supply the nonce it received from acquire's
  # JSON envelope (DEC-040 round 3 F2) — otherwise same-caller_pid
  # background jobs from the same parent shell can release locks they
  # never acquired. Compatibility: when expected_nonce is empty, fall
  # back to caller_pid-only check (legacy callers); emit a warning.
  local holder_pid holder_nonce
  holder_pid="$(jq -r '.caller_pid' "$lock_path/holder.json")"
  holder_nonce="$(jq -r '.nonce // empty' "$lock_path/holder.json")"
  if [[ "$holder_pid" != "$caller_pid" ]]; then
    local extra
    extra="$(jq -nc --arg owner "$holder_pid" --arg me "$caller_pid" \
      '{holder_caller_pid: ($owner | tonumber), requested_caller_pid: ($me | tonumber)}')"
    emit_envelope release not_holder "$name" 6 "$extra"
    exit 6
  fi
  # DEC-040 round 3 F2/F3: when holder.json has a nonce, the caller MUST
  # present it. The previous behavior fell back to caller_pid-only on empty
  # `--nonce`, which let a sibling background job (same default `$PPID`)
  # release a lock it never acquired. Empty nonce vs nonce-bearing holder
  # is now treated as `not_holder`, not a legacy fallback.
  if [[ -n "$holder_nonce" ]] && [[ "$expected_nonce" != "$holder_nonce" ]]; then
    local reason
    if [[ -z "$expected_nonce" ]]; then
      reason="release_nonce_required"
    else
      reason="release_nonce_mismatch"
    fi
    local extra
    extra="$(jq -nc --arg owner_nonce "$holder_nonce" --arg requested "$expected_nonce" --arg r "$reason" \
      '{holder_nonce: $owner_nonce, requested_nonce: $requested, reason: $r}')"
    emit_envelope release not_holder "$name" 6 "$extra"
    exit 6
  fi

  # Atomic salvage rename to release-our-snapshot path. If another racer
  # already salvaged the stale dir and a new holder appears between our
  # token capture and rename, mv will succeed but the salvaged content
  # carries the new holder (different nonce) — we restore.
  local salvage="$lock_path.release.$caller_pid.$RANDOM"
  if ! mv "$lock_path" "$salvage" 2>/dev/null; then
    # Someone else removed it (a parallel release/reclaim) — accept idempotent.
    local extra
    extra="$(jq -nc --arg path "$lock_path" '{lock_path: $path, reason: "dir_vanished_during_release"}')"
    emit_envelope release released "$name" 0 "$extra"
    return 0
  fi
  if [[ -f "$salvage/holder.json" ]]; then
    local cur_pid cur_nonce
    cur_pid="$(jq -r '.caller_pid' "$salvage/holder.json")"
    cur_nonce="$(jq -r '.nonce // empty' "$salvage/holder.json")"
    if [[ "$cur_pid" != "$holder_pid" || "$cur_nonce" != "$holder_nonce" ]]; then
      # New holder appeared during salvage race. Put back; if a newer
      # acquire happened concurrently, drop the salvage to avoid clobber.
      if ! mv -n "$salvage" "$lock_path" 2>/dev/null; then
        rm -rf "$salvage"
      fi
      local extra
      extra="$(jq -nc --arg owner "$cur_pid" --arg me "$caller_pid" \
        --arg own_nonce "$cur_nonce" --arg my_nonce "$holder_nonce" \
        '{holder_caller_pid: ($owner | tonumber), requested_caller_pid: ($me | tonumber),
          holder_nonce: $own_nonce, requested_nonce: $my_nonce,
          reason: "release_race_new_holder"}')"
      emit_envelope release not_holder "$name" 6 "$extra"
      exit 6
    fi
  fi
  # Our snapshot — discard it (canonical path is already gone via the
  # rename, so a future acquire will mkdir fresh).
  rm -rf "$salvage"
  local extra
  extra="$(jq -nc --arg path "$lock_path" '{lock_path: $path}')"
  emit_envelope release released "$name" 0 "$extra"
}

# --- Heartbeat -------------------------------------------------------------

cmd_heartbeat() {
  local name="$1" caller_pid="$2" expected_nonce="${3:-}"
  local pair scope resource lock_path
  pair="$(parse_lock_name "$name")"
  scope="${pair%%$'\t'*}"
  resource="${pair##*$'\t'}"
  lock_path="$(lock_path_for "$scope" "$resource")"

  if [[ ! -f "$lock_path/holder.json" ]]; then
    local extra
    extra="$(jq -nc '{reason: "holder_absent"}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi
  # Capture (caller_pid, nonce) ownership token snapshot — same as release.
  local holder_pid holder_nonce
  holder_pid="$(jq -r '.caller_pid' "$lock_path/holder.json")"
  holder_nonce="$(jq -r '.nonce // empty' "$lock_path/holder.json")"
  if [[ "$holder_pid" != "$caller_pid" ]]; then
    local extra
    extra="$(jq -nc --arg owner "$holder_pid" --arg me "$caller_pid" \
      '{holder_caller_pid: ($owner | tonumber), requested_caller_pid: ($me | tonumber)}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi
  # DEC-040 round 3 F2/F3: when holder.json has a nonce, the caller MUST
  # present it. Empty nonce against a nonce-bearing holder is `not_holder`,
  # not a legacy fallback. Sibling background jobs with the same default
  # `$PPID` cannot refresh without the acquire-time nonce.
  if [[ -n "$holder_nonce" ]] && [[ "$expected_nonce" != "$holder_nonce" ]]; then
    local reason
    if [[ -z "$expected_nonce" ]]; then
      reason="heartbeat_nonce_required"
    else
      reason="heartbeat_nonce_mismatch"
    fi
    local extra
    extra="$(jq -nc --arg owner_nonce "$holder_nonce" --arg requested "$expected_nonce" --arg r "$reason" \
      '{holder_nonce: $owner_nonce, requested_nonce: $requested, reason: $r}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi

  # Atomic update of holder.json itself (not lock_dir). Rationale (DEC-040
  # round 3 F1): renaming lock_dir away vacates the canonical path so a
  # waiter mkdir's a new lock during the refresh window. Keep lock_dir
  # present throughout heartbeat and do a single rename inside it.
  #
  # DEC-040 round 3 F4: build the tmp from a CAPTURED snapshot of
  # holder.json rather than re-reading the file; then do a tight pre-mv
  # re-check just before the rename. This prevents an expired holder
  # whose heartbeat call races a concurrent stale-reclaim from
  # overwriting the new holder's metadata.
  local snapshot_content
  snapshot_content="$(cat "$lock_path/holder.json" 2>/dev/null || true)"
  if [[ -z "$snapshot_content" ]]; then
    local extra
    extra="$(jq -nc '{reason: "holder_vanished_during_heartbeat"}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi
  local snap_pid snap_nonce holder_ttl
  snap_pid="$(printf '%s' "$snapshot_content" | jq -r '.caller_pid' 2>/dev/null || echo "")"
  snap_nonce="$(printf '%s' "$snapshot_content" | jq -r '.nonce // empty' 2>/dev/null || echo "")"
  holder_ttl="$(printf '%s' "$snapshot_content" | jq -r '.ttl_seconds // empty' 2>/dev/null || true)"
  if [[ "$snap_pid" != "$caller_pid" || "$snap_nonce" != "$holder_nonce" ]]; then
    local extra
    extra="$(jq -nc --arg owner "$snap_pid" --arg me "$caller_pid" \
      --arg own_nonce "$snap_nonce" --arg my_nonce "$holder_nonce" \
      '{holder_caller_pid: ($owner | tonumber? // null), requested_caller_pid: ($me | tonumber),
        holder_nonce: $own_nonce, requested_nonce: $my_nonce,
        reason: "heartbeat_race_owner_changed"}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi
  if [[ -z "$holder_ttl" || ! "$holder_ttl" =~ ^[0-9]+$ ]]; then
    holder_ttl="$RESOURCE_LOCK_TTL"
  fi
  local now exp tmp
  now="$(now_utc)"
  exp="$(_iso_after_seconds "$holder_ttl")"
  tmp="$lock_path/holder.tmp.hb.$caller_pid.$RANDOM"
  # Build tmp from the CAPTURED snapshot (not the live file). If a
  # concurrent reclaim wrote a new holder.json after our snapshot, the
  # tmp still reflects our owned content; the pre-mv guard below catches
  # the divergence and refuses to overwrite.
  printf '%s' "$snapshot_content" \
    | jq --arg hb "$now" --arg exp "$exp" --argjson ttl "$holder_ttl" \
         '. + {heartbeat_at: $hb, expires_at: $exp, ttl_seconds: $ttl}' \
    > "$tmp"
  # DEC-040 round 3 F4 — tight pre-mv re-check. Race window between this
  # check and the mv is microseconds; cooperative-lock callers (run
  # 5-minute cycles, codex-loop second-granular polling) tolerate this.
  local premv_pid premv_nonce
  premv_pid="$(jq -r '.caller_pid' "$lock_path/holder.json" 2>/dev/null || echo "")"
  premv_nonce="$(jq -r '.nonce // empty' "$lock_path/holder.json" 2>/dev/null || echo "")"
  if [[ "$premv_pid" != "$caller_pid" || "$premv_nonce" != "$holder_nonce" ]]; then
    rm -f "$tmp"
    local extra
    extra="$(jq -nc --arg owner "$premv_pid" --arg me "$caller_pid" \
      --arg own_nonce "$premv_nonce" --arg my_nonce "$holder_nonce" \
      '{holder_caller_pid: ($owner | tonumber? // null), requested_caller_pid: ($me | tonumber),
        holder_nonce: $own_nonce, requested_nonce: $my_nonce,
        reason: "heartbeat_race_pre_mv_owner_changed"}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi
  mv "$tmp" "$lock_path/holder.json"
  # Post-mv verify retained for diagnostic — but the pre-mv guard above is
  # the actual safety check. A change between pre-mv and mv (microsecond
  # window) shows up here as a `heartbeat_overwritten_by_new_holder` event.
  local post_pid post_nonce
  post_pid="$(jq -r '.caller_pid' "$lock_path/holder.json" 2>/dev/null || echo "")"
  post_nonce="$(jq -r '.nonce // empty' "$lock_path/holder.json" 2>/dev/null || echo "")"
  if [[ "$post_pid" != "$caller_pid" || "$post_nonce" != "$holder_nonce" ]]; then
    local extra
    extra="$(jq -nc --arg owner "$post_pid" --arg me "$caller_pid" \
      --arg own_nonce "$post_nonce" --arg my_nonce "$holder_nonce" \
      '{holder_caller_pid: ($owner | tonumber? // null), requested_caller_pid: ($me | tonumber),
        holder_nonce: $own_nonce, requested_nonce: $my_nonce,
        reason: "heartbeat_overwritten_by_new_holder"}')"
    emit_envelope heartbeat not_holder "$name" 6 "$extra"
    exit 6
  fi

  local extra
  extra="$(jq -nc --arg hb "$now" --arg exp "$exp" --argjson ttl "$holder_ttl" \
    '{heartbeat_at: $hb, expires_at: $exp, ttl_seconds: $ttl}')"
  emit_envelope heartbeat refreshed "$name" 0 "$extra"
}

# --- Status / List ---------------------------------------------------------

cmd_status() {
  local name="$1"
  local pair scope resource lock_path
  pair="$(parse_lock_name "$name")"
  scope="${pair%%$'\t'*}"
  resource="${pair##*$'\t'}"
  lock_path="$(lock_path_for "$scope" "$resource")"

  if [[ ! -d "$lock_path" ]]; then
    local extra
    extra="$(jq -nc '{state: "absent"}')"
    emit_envelope status absent "$name" 0 "$extra"
    return 0
  fi
  if [[ -f "$lock_path/holder.json" ]]; then
    local state holder
    if holder_is_stale "$lock_path"; then state="stale"; else state="live"; fi
    holder="$(cat "$lock_path/holder.json")"
    local extra
    extra="$(jq -nc --arg state "$state" --argjson h "$holder" \
      '{state: $state, holder: $h}')"
    emit_envelope status "$state" "$name" 0 "$extra"
  else
    local extra
    extra="$(jq -nc '{state: "in_flight_or_holderless"}')"
    emit_envelope status in_flight "$name" 0 "$extra"
  fi
}

cmd_list() {
  local repo_id root
  repo_id="$(resolve_repo_id)"
  root="$RESOURCE_LOCK_HOME/$repo_id"
  local rows='[]'
  if [[ -d "$root" ]]; then
    while IFS= read -r holder_path; do
      [[ -z "$holder_path" ]] && continue
      local rel_dir="${holder_path%/holder.json}"
      local relative="${rel_dir#$root/}"
      local sc="${relative%%/*}"
      local res="${relative#*/}"
      local nm="$sc:$res"
      local state holder
      if holder_is_stale "$rel_dir"; then state="stale"; else state="live"; fi
      holder="$(cat "$holder_path")"
      rows="$(jq --arg name "$nm" --arg state "$state" --argjson h "$holder" \
        '. + [{lock_name: $name, state: $state, holder: $h}]' <<<"$rows")"
    done < <(find "$root" -mindepth 3 -maxdepth 3 -name holder.json -type f 2>/dev/null)
  fi
  if [[ "$RESOURCE_LOCK_OUTPUT" == "json" ]]; then
    jq -cn --argjson locks "$rows" '{
      schema_version: 1,
      kind: "resource_lock_observation",
      subcommand: "list",
      result: "listed",
      locks: $locks,
      exit_code: 0
    }'
  else
    local count
    count="$(jq -r 'length' <<<"$rows")"
    printf 'list: %s locks (use --json for details)\n' "$count"
  fi
}

# --- Argument parsing ------------------------------------------------------

if (( $# == 0 )); then
  sed -n '2,40p' "$0"
  exit 0
fi

SUBCOMMAND="$1"; shift

# Common: --json, --caller-pid, --wait, --ttl. Sub-specific filtering below.
WAIT_SEC=0
TTL_ARG=""
CALLER_PID="${RESOURCE_LOCK_CALLER_PID:-$PPID}"
NONCE_ARG="${RESOURCE_LOCK_NONCE:-}"
POSITIONAL=()

while (( $# > 0 )); do
  case "$1" in
    --json)         RESOURCE_LOCK_OUTPUT=json; shift ;;
    --wait)         [[ -n "${2:-}" ]] || die 1 "--wait requires value"; WAIT_SEC="$2"; shift 2 ;;
    --ttl)          [[ -n "${2:-}" ]] || die 1 "--ttl requires value"; TTL_ARG="$2"; shift 2 ;;
    --caller-pid)   [[ -n "${2:-}" ]] || die 1 "--caller-pid requires value"; CALLER_PID="$2"; shift 2 ;;
    --nonce)        [[ -n "${2:-}" ]] || die 1 "--nonce requires value"; NONCE_ARG="$2"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    --)             shift; while (( $# > 0 )); do POSITIONAL+=("$1"); shift; done; break ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done

_validate_positive_int RESOURCE_LOCK_CALLER_PID "$CALLER_PID"
[[ "$WAIT_SEC" =~ ^[0-9]+$ ]] || die 1 "--wait must be non-negative integer (got: $WAIT_SEC)"

case "$SUBCOMMAND" in
  acquire)
    (( ${#POSITIONAL[@]} >= 1 )) || die 1 "acquire <name> required"
    cmd_acquire "${POSITIONAL[0]}" "$WAIT_SEC" "$TTL_ARG" "$CALLER_PID"
    ;;
  release)
    (( ${#POSITIONAL[@]} >= 1 )) || die 1 "release <name> required"
    cmd_release "${POSITIONAL[0]}" "$CALLER_PID" "$NONCE_ARG"
    ;;
  heartbeat)
    (( ${#POSITIONAL[@]} >= 1 )) || die 1 "heartbeat <name> required"
    cmd_heartbeat "${POSITIONAL[0]}" "$CALLER_PID" "$NONCE_ARG"
    ;;
  status)
    (( ${#POSITIONAL[@]} >= 1 )) || die 1 "status <name> required"
    cmd_status "${POSITIONAL[0]}"
    ;;
  list)
    cmd_list
    ;;
  *)
    die 1 "unknown subcommand: $SUBCOMMAND (use acquire|release|heartbeat|status|list)"
    ;;
esac
