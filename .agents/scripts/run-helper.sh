#!/usr/bin/env bash
# Shared entrypoint for run commands/skills.

set -euo pipefail

source_path="${BASH_SOURCE[0]}"
while [[ -L "$source_path" ]]; do
  source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
  source_path="$(readlink "$source_path")"
  [[ "$source_path" != /* ]] && source_path="$source_dir/$source_path"
done

RUN_HELPER_SCRIPT_DIR="$(cd -P "$(dirname "$source_path")" && pwd)"
RUN_HELPER_LIB_DIR="$RUN_HELPER_SCRIPT_DIR/run-helper"

source "$RUN_HELPER_LIB_DIR/core.sh"
source "$RUN_HELPER_LIB_DIR/change-scope.sh"
source "$RUN_HELPER_LIB_DIR/brief-state.sh"
source "$RUN_HELPER_LIB_DIR/brief-render.sh"
source "$RUN_HELPER_LIB_DIR/test-plan.sh"
source "$RUN_HELPER_LIB_DIR/dispatch.sh"

# F5 (DEC-049): adopt a legacy `.dev-cycle/` workspace-state dir into `.run/`.
# Resolved from the git repo ROOT (not cwd) so subdirectory invocations adopt the
# same dir that fresh_state_dir() uses (<root>/.run). The mv also renames the legacy
# brief filenames (dev-cycle-run-id → run-id, dev-cycle-run.json → run.json,
# dev-cycle-briefs* → run-briefs*, …) so the renamed helper finds them after
# adoption. no-op when absent; fail-closed (warn, leave both) when both dirs exist.
run_adopt_legacy_state() {
  local root legacy new
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$root" ]] || return 0
  legacy="$root/.dev-cycle"; new="$root/.run"
  [[ -d "$legacy" ]] || return 0
  if [[ -e "$new" ]]; then
    printf 'WARN: both %s and %s exist — legacy state not adopted; resolve manually (DEC-049)\n' "$legacy" "$new" >&2
    return 0
  fi
  # adopt_legacy_state_dir (core.sh) renames brief filenames + gitignores .run/ (P3-A).
  if adopt_legacy_state_dir "$legacy" "$new"; then
    printf 'NOTE: adopted legacy .dev-cycle/ → .run/ at %s (brief filenames migrated, DEC-049)\n' "$root" >&2
  else
    printf 'WARN: legacy %s present but adopt failed — resolve manually (DEC-049)\n' "$legacy" >&2
  fi
}
run_adopt_legacy_state

run_helper_main "$@"
