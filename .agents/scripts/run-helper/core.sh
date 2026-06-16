# shellcheck shell=bash

script_dir() {
  local source dir
  if [[ -n "${RUN_HELPER_SCRIPT_DIR:-}" ]]; then
    printf '%s\n' "$RUN_HELPER_SCRIPT_DIR"
    return
  fi

  source="${BASH_SOURCE[0]}"
  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

repo_root() {
  git rev-parse --show-toplevel
}

repo_name() {
  local remote name
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$remote" ]]; then
    remote="${remote%.git}"
    name="${remote##*/}"
    [[ "$remote" == *:* && "$remote" != http* ]] && name="${remote##*:}"
    name="${name##*/}"
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return
    fi
  fi
  basename "$(repo_root)"
}

repo_type() {
  # Per PR #28 every repo uses the standard PR-based workflow. The function
  # is retained because run briefs record `repo.type` in their schema;
  # callers see a single value rather than a missing field.
  echo "standard"
}

default_branch() {
  local branch
  branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [[ -z "$branch" ]]; then
    branch="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)"
  fi
  echo "${branch:-main}"
}

review_base() {
  local base
  base="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)"
  if [[ -n "$base" ]]; then
    echo "$base"
  elif git show-ref --verify --quiet refs/remotes/origin/dev; then
    echo "dev"
  else
    default_branch
  fi
}

sync_repo() {
  local current default
  current="$(git branch --show-current)"
  default="$(default_branch)"

  # PA-1.2 guard (DEC-031 / DEC-032 layered enforcement). When the
  # caller declares worker context via AGENT_ROLE=worker, refuse to
  # mutate the shared main worktree. The orchestrator owns main sync.
  # This is the first concrete enforcement layer above the
  # cooperative file lock primitive (PA-1.1). Workers still get
  # `git fetch origin` for visibility, but `git switch main` and
  # `git pull` on the default branch are no-ops with a reported
  # 'sync deferred to orchestrator' note.
  if [[ "${AGENT_ROLE:-}" == "worker" ]]; then
    git fetch origin
    echo "sync deferred to orchestrator (AGENT_ROLE=worker; PA-1.2 guard)" >&2
    return 0
  fi

  git fetch origin

  if [[ -z "$current" ]]; then
    echo "Detached HEAD: cannot run sync safely" >&2
    return 1
  fi

  if git show-ref --verify --quiet refs/remotes/origin/dev; then
    if [[ "$current" == "dev" ]]; then
      git pull --ff-only origin dev
    elif [[ -z "$(git status --porcelain)" ]]; then
      git switch dev
      git pull --ff-only origin dev
      git switch "$current"
    else
      echo "Dirty worktree: fetched origin/dev, skipped local dev checkout" >&2
    fi
  elif [[ "$current" == "$default" ]]; then
    git pull --ff-only origin "$default"
  fi
}

# 3-signal entry gate: refuse to start run mutation in an unsafe cwd.
# Codex pingpong session 20260527-044012 (option D sub-decision (a)) concluded
# that a single branch-name check is insufficient — a canonical main checkout
# temporarily holding a feature branch would false-pass. The gate combines:
#   (1) cwd toplevel == primary worktree path (the first entry in
#       `git worktree list --porcelain`).
#   (2) current branch == default branch or review_base.
#   (3) detached HEAD state.
# Any (1) or (2) match rejects with rc=2. (3) also rejects so commits land
# on a named ref. Read-only discovery is allowed in main worktree; only
# mutation-bearing steps (auto-promotion file edits, Step 4 implement) call
# this gate.
mutation_entry_check() {
  require_jq || return 1
  local cwd_toplevel
  if ! cwd_toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    jq -nc --arg cwd "$(pwd)" '{
      schema_version:1, kind:"run_mutation_entry_check", ok:false,
      reason:"not_in_git_tree",
      hint:"run mutation must run inside a git worktree.",
      cwd:$cwd
    }'
    return 2
  fi

  local primary_worktree
  primary_worktree="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print; exit}' \
    | sed 's/^worktree //')"

  local current_branch
  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  # Discover base branches WITHOUT the "main" fallback that default_branch()
  # and review_base() use. If origin/HEAD is unset and there is no open PR
  # and origin/dev does not exist, fallback to "main" would let a linked
  # worktree on `master` / `develop` / etc. silently pass the branch_is_base
  # check. The gate fails closed instead.
  local default_discovered=""
  default_discovered="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [[ -z "$default_discovered" ]]; then
    default_discovered="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)"
    [[ "$default_discovered" == "(unknown)" ]] && default_discovered=""
  fi
  local review_discovered=""
  local review_from_gh
  review_from_gh="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)"
  if [[ -n "$review_from_gh" && "$review_from_gh" != "null" ]]; then
    review_discovered="$review_from_gh"
  elif git show-ref --verify --quiet refs/remotes/origin/dev; then
    review_discovered="dev"
  fi

  if [[ -n "$primary_worktree" && "$cwd_toplevel" == "$primary_worktree" ]]; then
    jq -nc \
      --arg cwd "$cwd_toplevel" \
      --arg primary "$primary_worktree" \
      --arg branch "$current_branch" \
      '{schema_version:1, kind:"run_mutation_entry_check", ok:false,
        reason:"primary_worktree",
        hint:"cwd is the primary worktree (canonical main checkout). Create a task worktree (`git worktree add ../<repo>-<branch> -b <branch> origin/<base>`) and cd into it before mutation.",
        cwd:$cwd, primary_worktree:$primary,
        current_branch:(if $branch == "" then null else $branch end)}'
    return 2
  fi

  if [[ -z "$current_branch" ]]; then
    jq -nc \
      --arg cwd "$cwd_toplevel" \
      '{schema_version:1, kind:"run_mutation_entry_check", ok:false,
        reason:"detached_head",
        hint:"cwd is on a detached HEAD. Create a working branch (`git checkout -b <branch>`) before mutation so commits attach to a named ref.",
        cwd:$cwd}'
    return 2
  fi

  if [[ -z "$default_discovered" && -z "$review_discovered" ]]; then
    jq -nc \
      --arg cwd "$cwd_toplevel" \
      --arg branch "$current_branch" \
      '{schema_version:1, kind:"run_mutation_entry_check", ok:false,
        reason:"base_branch_undetermined",
        hint:"Could not discover the base branch (no origin/HEAD, no open PR for the current branch, no origin/dev). Set origin/HEAD (`git remote set-head origin --auto`) or open the PR against the intended base before retrying.",
        cwd:$cwd, current_branch:$branch}'
    return 2
  fi

  if { [[ -n "$default_discovered" ]] && [[ "$current_branch" == "$default_discovered" ]]; } || \
     { [[ -n "$review_discovered" ]] && [[ "$current_branch" == "$review_discovered" ]]; }; then
    jq -nc \
      --arg cwd "$cwd_toplevel" \
      --arg branch "$current_branch" \
      --arg default "$default_discovered" \
      --arg review "$review_discovered" \
      '{schema_version:1, kind:"run_mutation_entry_check", ok:false,
        reason:"branch_is_base",
        hint:"current branch is the base branch. Create or switch to a working branch (`codex/<task>` or `<type>/<task>`) before mutation.",
        cwd:$cwd, current_branch:$branch,
        default_branch:(if $default == "" then null else $default end),
        review_base:(if $review == "" then null else $review end)}'
    return 2
  fi

  jq -nc \
    --arg cwd "$cwd_toplevel" \
    --arg branch "$current_branch" \
    --arg default "$default_discovered" \
    --arg review "$review_discovered" \
    --arg primary "$primary_worktree" \
    '{schema_version:1, kind:"run_mutation_entry_check", ok:true,
      cwd:$cwd, current_branch:$branch,
      default_branch:(if $default == "" then null else $default end),
      review_base:(if $review == "" then null else $review end),
      primary_worktree:(if $primary == "" then null else $primary end)}'
}

# Compute the workspace-local .run from cwd, always. Used by
# init_brief, which must create / overwrite the state at the location
# the operator is currently in, regardless of stale env vars from a
# previous cycle in the same shell.
fresh_state_dir() {
  local root git_dir state_dir exclude_file
  root="$(repo_root)" || return 1
  git_dir="$(git rev-parse --git-dir)" || return 1
  state_dir="$root/.run"
  exclude_file="$git_dir/info/exclude"
  mkdir -p "$state_dir"
  if [[ -f "$exclude_file" ]]; then
    grep -qxF ".run/" "$exclude_file" 2>/dev/null || echo ".run/" >> "$exclude_file"
  fi
  echo "$state_dir"
}

# DEC-049: adopt a legacy dev-cycle state dir ($1) into the new .run name ($2),
# renaming the brief filenames (dev-cycle-run-id → run-id, …) so the renamed helper
# finds them, and gitignoring the adopted .run/ (P3-A) so diff classifiers skip the
# migrated state. Returns 1 on mv failure. Caller checks preconditions ($1 exists,
# $2 absent) and owns user-facing messaging.
adopt_legacy_state_dir() {
  local legacy="$1" new="$2" f b nb git_dir
  mv "$legacy" "$new" 2>/dev/null || return 1
  for f in "$new"/dev-cycle-*; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f")"
    case "$b" in
      dev-cycle-run-id)             nb="run-id" ;;
      dev-cycle-run.json)           nb="run.json" ;;
      dev-cycle-start-epoch)        nb="run-start-epoch" ;;
      dev-cycle-briefs.jsonl)       nb="run-briefs.jsonl" ;;
      dev-cycle-briefs.md)          nb="run-briefs.md" ;;
      dev-cycle-audit-passes.jsonl) nb="run-audit-passes.jsonl" ;;
      *)                            nb="run-${b#dev-cycle-}" ;;
    esac
    mv "$f" "$new/$nb" 2>/dev/null || true
  done
  : > "$new/.adopted-from-dev-cycle" 2>/dev/null || true
  git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [[ -n "$git_dir" && -f "$git_dir/info/exclude" ]]; then
    grep -qxF ".run/" "$git_dir/info/exclude" 2>/dev/null || echo ".run/" >> "$git_dir/info/exclude"
  fi
  return 0
}

ensure_state_dir() {
  # RUN_STATE_DIR opt-in: pin the state directory to an absolute
  # path so cycle state survives a cwd change into a linked worktree.
  # init_brief exports the variable; subsequent helper calls in the
  # same shell session (or any child shell that inherits the env) see
  # the same .run regardless of which worktree they run from.
  # Without this, `git rev-parse --show-toplevel` resolves to the
  # cwd's worktree root and a linked worktree gets a brand-new empty
  # state directory, breaking finish-cycle-json / summary-json after
  # Step 4 (worktree creation).
  if [[ -n "${RUN_STATE_DIR:-}" ]]; then
    if [[ ! -d "$RUN_STATE_DIR" ]]; then
      echo "RUN_STATE_DIR=$RUN_STATE_DIR does not exist; run init-brief first or unset the variable." >&2
      return 1
    fi
    echo "$RUN_STATE_DIR"
    return 0
  fi
  # P2-A (DEC-049): a pre-rename run pinned by DEV_CYCLE_STATE_DIR points at a
  # <orig>/.dev-cycle dir, possibly in a different worktree. Adopt it into the
  # sibling <orig>/.run and use that, so a resumed in-flight run finds its brief
  # state instead of a fresh empty .run in the current worktree.
  if [[ -n "${DEV_CYCLE_STATE_DIR:-}" ]]; then
    local pin="$DEV_CYCLE_STATE_DIR" sib="${DEV_CYCLE_STATE_DIR%.dev-cycle}.run"
    if [[ "$pin" == *.dev-cycle && -d "$pin" && ! -e "$sib" ]]; then
      adopt_legacy_state_dir "$pin" "$sib" && { echo "$sib"; return 0; }
    elif [[ -d "$sib" ]]; then
      echo "$sib"; return 0
    fi
  fi
  fresh_state_dir
}

shell_export() {
  local key="$1" value="$2"
  printf 'export %s=%q\n' "$key" "$value"
}

brief_run_id_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/run-id"
}

brief_start_epoch_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/run-start-epoch"
}

format_duration() {
  local total="$1" days hours minutes seconds parts
  (( total < 0 )) && total=0
  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))

  parts=()
  if (( days > 0 )); then parts+=("${days}d"); fi
  if (( hours > 0 )); then parts+=("${hours}h"); fi
  if (( minutes > 0 )); then parts+=("${minutes}m"); fi
  if (( seconds > 0 || ${#parts[@]} == 0 )); then parts+=("${seconds}s"); fi
  printf '%s\n' "${parts[*]}"
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for run JSON brief handling" >&2
    return 1
  fi
}

brief_jsonl_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/run-briefs.jsonl"
}

brief_run_json_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/run.json"
}

brief_audit_jsonl_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/run-audit-passes.jsonl"
}

# --- PA-1.3 brief preservation -------------------------------------------
#
# Workspace `.run/` lives inside the worktree and is erased by
# `git worktree remove`. PA-1.0 dogfood (PR #13 closeout) observed the
# brief log going dark immediately after cleanup, making post-mortem
# review impossible. PA-1.3 mirrors the live brief log to a central
# state path so it survives worktree cleanup.
#
# The workspace path remains source of truth for live writes; the
# central path is a mirror updated at cycle close (finish_cycle_json)
# and on demand via `run-helper.sh mirror-brief`. Source of truth
# during a live cycle is still the workspace; only after cycle close
# does the central copy become useful.

central_brief_root() {
  # `${RUN_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/run}/briefs/`
  # Aligned with PA-1.1 run-registry state root for consistency.
  local home
  if [[ -n "${RUN_STATE_HOME:-}" ]]; then
    home="$RUN_STATE_HOME"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    home="$XDG_STATE_HOME/run"
  else
    home="$HOME/.local/state/run"
  fi
  printf '%s/briefs\n' "$home"
}

central_brief_dir_for_run() {
  # central_brief_dir_for_run <run_id>
  local run_id="$1"
  [[ -n "$run_id" ]] || return 1
  # repo identifier: prefer git remote origin (collision-safe via
  # path-safe rewrite); fall back to canonical git common-dir basename.
  local repo_key origin
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin" ]]; then
    # Reuse a simple normalization: strip protocol/auth, trailing .git/
    # trailing slash, then sanitize separators to underscore. PA-1.1
    # run-registry has the full normalization; for brief mirror we only
    # need a stable filesystem-safe key, so a lighter sanitizer is fine.
    repo_key="$(printf '%s' "$origin" \
                  | sed -E -e 's#^[a-z]+://([^/]*@)?##' \
                          -e 's#^[^@]+@##' \
                          -e 's#:#/#' \
                          -e 's#\.git$##' \
                          -e 's#/$##' \
                  | LC_ALL=C tr '/[:upper:]' '_[:lower:]' \
                  | LC_ALL=C sed 's/[^a-z0-9._-]/_/g')"
  else
    local common_dir
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    [[ -n "$common_dir" ]] || return 1
    repo_key="local_$(printf '%s' "$common_dir" | LC_ALL=C tr '/' '_' | LC_ALL=C sed 's/[^a-z0-9._-]/_/g')"
  fi
  printf '%s/%s/%s\n' "$(central_brief_root)" "$repo_key" "$run_id"
}

mirror_brief_to_central() {
  # mirror_brief_to_central [<state_dir>]
  # Copy the current workspace brief log to the central path. Idempotent
  # — overwrite files with the latest content each call so callers can
  # invoke at every finish_cycle_json without coordination.
  local state_dir="${1:-}"
  if [[ -z "$state_dir" ]]; then
    state_dir="$(ensure_state_dir)" || return 1
  fi
  local run_id_file run_id central
  run_id_file="$(brief_run_id_file "$state_dir")"
  [[ -f "$run_id_file" ]] || return 0
  run_id="$(cat "$run_id_file" 2>/dev/null || true)"
  [[ -n "$run_id" ]] || return 0
  central="$(central_brief_dir_for_run "$run_id")" || return 0
  mkdir -p "$central" || return 1
  local f
  for f in run-id run-start-epoch run.json \
           run-briefs.jsonl run-briefs.md \
           run-audit-passes.jsonl; do
    if [[ -f "$state_dir/$f" ]]; then
      # Atomic-ish replace: write to .tmp then mv. cp -p preserves
      # timestamps so consumers see the live workspace mtime.
      cp -p "$state_dir/$f" "$central/$f.tmp.$$" 2>/dev/null && \
        mv "$central/$f.tmp.$$" "$central/$f"
    fi
  done
  printf '%s\n' "$central"
}
