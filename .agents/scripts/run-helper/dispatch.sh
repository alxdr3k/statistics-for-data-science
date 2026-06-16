# shellcheck shell=bash

usage() {
  cat <<'EOF'
usage: run-helper.sh <command>

commands:
  repo-name
  repo-type
  default-branch
  review-base
  mutation-entry-check
  change-scope
  review-dossier
  sync
  init-brief
  validate-brief <run-id> <brief-log>
  finish-cycle
  finish-cycle-json
  audit-pass-json [audit_every]
  record-audit-baseline
  check-test-plan
  summary
  summary-json
  mirror-brief
EOF
}

run_helper_main() {
  local cmd
  cmd="${1:-}"
  case "$cmd" in
    repo-name) repo_name ;;
    repo-type) repo_type ;;
    default-branch) default_branch ;;
    review-base) review_base ;;
    mutation-entry-check) mutation_entry_check ;;
    change-scope) change_scope ;;
    review-dossier) review_dossier ;;
    sync) sync_repo ;;
    init-brief) init_brief ;;
    validate-brief) shift; validate_brief "$@" ;;
    finish-cycle) finish_cycle ;;
    finish-cycle-json) finish_cycle_json ;;
    audit-pass-json) shift; audit_pass_json "$@" ;;
    record-audit-baseline) record_audit_baseline ;;
    check-test-plan) check_test_plan ;;
    summary) summary ;;
    summary-json) summary_json ;;
    mirror-brief) mirror_brief_to_central ;;
    help|-h|--help|"") usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; return 2 ;;
  esac
}
