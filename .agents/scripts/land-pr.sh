#!/usr/bin/env bash
# PA-2.2 land-pr — orchestrator-only PR merge helper.
#
# Closes the review/land split: reviewers (wait-codex-review.sh) observe the
# pass signal and the orchestrator alone owns the actual merge. Worker contexts
# call this with LAND_FORBIDDEN=1 in their environment and are refused before
# any GitHub mutation runs. This is the third enforcement layer over the
# cooperative file lock primitive (PA-1.1) and the sync_repo guard (PA-1.2).
#
# Exit codes:
#   0 → PR merged (or auto-merge enabled and accepted by GitHub)
#   1 → bad arguments (missing PR number, invalid flag)
#   3 → API failure that prevents progress (auth/scope/network/branch-protect)
#   4 → PR detection or state lookup failed
#   6 → land refused (LAND_FORBIDDEN=1, draft PR, dirty PR state, etc.)
#
# Usage:
#   land-pr.sh [--json] [--method squash|merge|rebase] [--auto]
#              [--expected-head-sha SHA] PR_NUMBER|PR_URL
#
# Env:
#   LAND_FORBIDDEN     non-empty value (most often "1") refuses the call
#                      immediately with exit 6 and the
#                      `land_forbidden_worker_context` envelope. PA-3.1
#                      orchestrator sets this on every worker shell so a
#                      worker can never land via this helper even if it
#                      bypasses the cooperative gate.
#   LAND_PR_METHOD     default merge method when --method not passed.
#                      Recognised: squash | merge | rebase. Default: squash.
#                      Caller must set this (or pass --method) for repos
#                      that disable squash; the helper does not silently
#                      pick a different method on failure.
#   LAND_PR_PRUNE_HEAD_WORKTREE
#                        `1` opts into the helper pre-pruning a local
#                        worktree that holds the PR head ref (so
#                        `gh pr merge --delete-branch` does not fail
#                        with "branch used by worktree"). Off by default:
#                        the prune surface has too many host/env/repo
#                        edge cases to be safe as default behaviour;
#                        orchestrators that own the worktree layout
#                        (PA-3.1) explicitly opt in. When on, the
#                        prune is guarded by: positive same-repo
#                        identity (owner/repo + host), clean+ignored
#                        check, cwd != worktree, submodule retry --force.
#   LAND_PR_ADMIN_FALLBACK
#                      `1` enables `gh pr merge --admin` retry when branch
#                      protection rejects the first attempt. Off by default;
#                      caller must opt in because admin bypass is a policy
#                      decision, not the helper's choice.
#   LAND_PR_REPO       owner/repo override (helpful in fork workflows). If
#                      empty, the helper auto-detects with `gh pr view`.
#   LAND_PR_OUTPUT     `json` enables structured observation stdout. Default
#                      `human`. Equivalent CLI flag: --json.
#   LAND_PR_EXPECTED_HEAD_SHA
#                      Expected PR head SHA (7-40 hex). When set, the helper
#                      refuses to merge if `gh pr view`'s `headRefOid` does
#                      not start with this value (`expected_head_mismatch`
#                      envelope + exit 6). Used to enforce review-loop's
#                      `review_loop_pass_signal.head_sha` at the land
#                      boundary: a push between pass and land changes
#                      live head and would otherwise merge an unreviewed
#                      commit. Equivalent CLI flag: --expected-head-sha SHA.

set -euo pipefail

output_mode="${LAND_PR_OUTPUT:-human}"
method="${LAND_PR_METHOD:-squash}"
auto=0
pr_arg=""
expected_head_sha="${LAND_PR_EXPECTED_HEAD_SHA:-}"

while (( $# > 0 )); do
  case "$1" in
    --json)
      output_mode="json"; shift ;;
    --method)
      [[ -n "${2:-}" ]] || { echo "ERROR: --method requires value" >&2; exit 1; }
      method="$2"; shift 2 ;;
    --expected-head-sha)
      # SHA pin received from review-loop's review_loop_pass_signal.head_sha.
      # If PR live head differs at land time, reject — codex did not review
      # the live head, so merging it would land an unreviewed commit.
      [[ -n "${2:-}" ]] || { echo "ERROR: --expected-head-sha requires value" >&2; exit 1; }
      expected_head_sha="$2"; shift 2 ;;
    --auto)
      auto=1; shift ;;
    --)
      # End-of-options sentinel. Remaining args are positional. Many
      # wrappers emit `--` defensively, so we must consume rather than
      # discard the rest of the line.
      shift
      while (( $# > 0 )); do
        if [[ -z "$pr_arg" ]]; then
          pr_arg="$1"; shift
        else
          echo "ERROR: unexpected positional arg after --: $1" >&2; exit 1
        fi
      done
      break ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *)
      if [[ -z "$pr_arg" ]]; then
        pr_arg="$1"; shift
      else
        echo "ERROR: unexpected positional arg: $1" >&2; exit 1
      fi ;;
  esac
done

case "$output_mode" in
  human|json) ;;
  *) echo "ERROR: LAND_PR_OUTPUT must be 'human' or 'json'" >&2; exit 1 ;;
esac

case "$method" in
  squash|merge|rebase) ;;
  *) echo "ERROR: --method must be squash|merge|rebase (got: $method)" >&2; exit 1 ;;
esac

# Validate --expected-head-sha format if provided. Accept lowercase
# 7-40 hex characters (git short or full SHA). Invalid format is a hard
# error rather than silently skipping the check.
if [[ -n "$expected_head_sha" ]]; then
  if ! [[ "$expected_head_sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "ERROR: --expected-head-sha must be 7-40 lowercase hex chars" >&2
    exit 1
  fi
fi

# emit_envelope <result> <reason> <pr_number_or_empty> <exit_code> [<extra_json>]
# JSON-mode observation envelope. Always emits versioned schema. Human mode
# is a one-line summary for shell consumption. Pass empty string for missing
# pr_number; the helper converts to JSON null.
emit_envelope() {
  local result="$1" reason="$2" pr="$3" exit_code="$4"
  local extra="${5:-}"
  [[ -z "$extra" ]] && extra='{}'
  local pr_json
  if [[ -z "$pr" || "$pr" == "null" ]]; then
    pr_json="null"
  else
    pr_json="$pr"
  fi
  if [[ "$output_mode" == "json" ]]; then
    jq -cn \
      --arg result "$result" \
      --arg reason "$reason" \
      --arg method "$method" \
      --argjson pr "$pr_json" \
      --argjson exit_code "$exit_code" \
      --argjson auto "$auto" \
      --argjson extra "$extra" '{
        schema_version: 1,
        kind: "land_pr_observation",
        result: $result,
        reason: $reason,
        pr_number: $pr,
        method: $method,
        auto_merge: ($auto == 1),
        exit_code: $exit_code,
        extra: $extra
      }'
  else
    printf '%s: pr=%s reason=%s method=%s rc=%s\n' \
      "$result" "${pr:-?}" "$reason" "$method" "$exit_code"
  fi
}

# PA-2.2 worker rejection gate. Runs BEFORE any GitHub call so a worker
# context cannot leak intent through gh CLI side effects. The check is a
# simple env presence test on purpose: orchestrator owns the env, and
# cheap deterministic checks compose with the other PA-1.x/PA-2.x layers
# more cleanly than introspecting run-registry.
if [[ -n "${LAND_FORBIDDEN:-}" ]]; then
  # Reject before any GitHub mutation. Coerce pr_arg to a numeric form when
  # possible so the envelope's pr_number stays JSON-safe; otherwise drop to
  # null. URL parsing happens later (orchestrator path); we do NOT want a
  # rejected envelope to fail-emit because of a bare URL.
  pr_for_envelope=""
  if [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
    pr_for_envelope="$pr_arg"
  elif [[ "$pr_arg" =~ ^https?://.*/([0-9]+)$ ]]; then
    pr_for_envelope="${BASH_REMATCH[1]}"
  fi
  emit_envelope rejected land_forbidden_worker_context "$pr_for_envelope" 6
  exit 6
fi

if [[ -z "$pr_arg" ]]; then
  emit_envelope rejected missing_pr_argument "" 1
  exit 1
fi

# Normalise PR argument: accept either "<number>" or a PR URL.
# URL form additionally pins LAND_PR_REPO so that gh pr view/merge target
# the repo named in the URL, not the local origin. Without this, passing
# a URL from a different repo would silently merge a different PR with
# the same number against the local origin — a correctness/safety bug.
pr_repo_from_url=""
pr_host_from_url=""
pr_url_trimmed="${pr_arg%/}"
if [[ "$pr_url_trimmed" =~ ^https?://([^/]+)/([^/]+/[^/]+)/pull/([0-9]+)$ ]]; then
  pr_host_from_url="${BASH_REMATCH[1]}"
  pr_repo_from_url="${BASH_REMATCH[2]}"
  pr_number="${BASH_REMATCH[3]}"
elif [[ "$pr_arg" =~ ^https?:// ]]; then
  # URL shape but no recognisable owner/repo/pull/N. Reject explicitly
  # rather than silently fall through to numeric parsing.
  emit_envelope rejected invalid_pr_argument "" 1
  exit 1
else
  pr_number="$pr_arg"
fi
# `gh --repo` accepts both `OWNER/REPO` (api.github.com) and
# `HOST/OWNER/REPO` (GitHub Enterprise / non-default host). Preserve the
# host from the URL when it is not GitHub.com so GHE invocations are not
# silently rerouted to api.github.com.
pr_repo_qualified="$pr_repo_from_url"
if [[ -n "$pr_repo_from_url" && -n "$pr_host_from_url" \
      && "$pr_host_from_url" != "github.com" \
      && "$pr_host_from_url" != "www.github.com" ]]; then
  pr_repo_qualified="${pr_host_from_url}/${pr_repo_from_url}"
fi
if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
  emit_envelope rejected invalid_pr_argument "" 1
  exit 1
fi

repo_flag=()
# Repo precedence: URL-derived owner/repo wins over LAND_PR_REPO env.
# The URL is the most explicit operator intent for this single call; an
# orchestrator's default env should never cause a URL-shaped invocation
# to land a different PR. If env disagrees with URL, surface the conflict
# as a rejection rather than silently picking one.
effective_repo=""
if [[ -n "$pr_repo_qualified" ]]; then
  effective_repo="$pr_repo_qualified"
  if [[ -n "${LAND_PR_REPO:-}" ]]; then
    # Normalise both sides before deciding "conflict". `gh --repo` accepts
    # both `OWNER/REPO` (github.com implied) and `HOST/OWNER/REPO`, so
    # `github.com/o/r` and `o/r` represent the same target for a
    # github.com URL and must not be flagged as conflicting.
    env_repo_short="$LAND_PR_REPO"
    case "$env_repo_short" in
      github.com/*|www.github.com/*)
        env_repo_short="${env_repo_short#*/}" ;;
    esac
    url_repo_short="$pr_repo_from_url"  # always OWNER/REPO (no host)
    if [[ "$env_repo_short" != "$url_repo_short" \
          && "${LAND_PR_REPO}" != "$pr_repo_qualified" ]]; then
      extra="$(jq -nc --arg url_repo "$pr_repo_qualified" \
                      --arg env_repo "$LAND_PR_REPO" '{
        url_repo: $url_repo, env_repo: $env_repo,
        hint: "LAND_PR_REPO and URL repo disagree; pick one or unset env"
      }')"
      emit_envelope rejected repo_conflict "$pr_number" 1 "$extra"
      exit 1
    fi
  fi
elif [[ -n "${LAND_PR_REPO:-}" ]]; then
  effective_repo="$LAND_PR_REPO"
fi
if [[ -n "$effective_repo" ]]; then
  repo_flag=(--repo "$effective_repo")
fi

# Pre-merge state probe. The pr view is the single source of truth for
# draft / merge state / head ref; we keep one call and pass the parsed
# values down so the helper does not race against eventual-consistency
# updates to PR state.
pr_view_json=""
if ! pr_view_json="$(gh pr view "$pr_number" ${repo_flag[@]+"${repo_flag[@]}"} \
      --json number,isDraft,baseRefName,headRefName,mergeStateStatus,mergeable,url,headRefOid,headRepository,headRepositoryOwner 2>/dev/null)"; then
  emit_envelope api_error pr_view_failed "$pr_number" 4
  exit 4
fi

is_draft="$(printf '%s' "$pr_view_json" | jq -r '.isDraft')"
if [[ "$is_draft" == "true" ]]; then
  emit_envelope rejected draft_pr "$pr_number" 6
  exit 6
fi

head_ref="$(printf '%s' "$pr_view_json" | jq -r '.headRefName')"
head_sha="$(printf '%s' "$pr_view_json" | jq -r '.headRefOid')"

# Expected-head-sha enforcement. review-loop emits
# review_loop_pass_signal.head_sha = the SHA codex actually reviewed.
# Reject if PR live head no longer matches — that means a new commit was
# pushed after pass but before land, and merging it would land an
# unreviewed commit. Accept short-SHA (7+ chars) match via prefix.
#
# Fail-closed: if expected was supplied but live head is empty/null/
# non-hex, we cannot verify the chain — refuse rather than silently
# letting `gh pr merge` proceed without `--match-head-commit`.
if [[ -n "$expected_head_sha" ]]; then
  if [[ -z "$head_sha" || "$head_sha" == "null" ]] \
     || ! [[ "$head_sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    extra="$(jq -nc --arg expected "$expected_head_sha" \
                    --arg live "$head_sha" '{
      expected_head_sha: $expected,
      live_head_sha: (if $live == "" then null else $live end)
    }')"
    emit_envelope rejected head_sha_unavailable "$pr_number" 6 "$extra"
    exit 6
  fi
  if [[ "$head_sha" != "$expected_head_sha"* ]]; then
    extra="$(jq -nc --arg expected "$expected_head_sha" \
                    --arg live "$head_sha" '{
      expected_head_sha: $expected, live_head_sha: $live
    }')"
    emit_envelope rejected expected_head_mismatch "$pr_number" 6 "$extra"
    exit 6
  fi
fi

merge_state="$(printf '%s' "$pr_view_json" | jq -r '.mergeStateStatus')"
mergeable="$(printf '%s' "$pr_view_json" | jq -r '.mergeable')"
head_repo_owner="$(printf '%s' "$pr_view_json" | jq -r '.headRepositoryOwner.login // empty')"
head_repo_name="$(printf '%s' "$pr_view_json" | jq -r '.headRepository.name // empty')"
head_repo_nwo=""
if [[ -n "$head_repo_owner" && -n "$head_repo_name" ]]; then
  head_repo_nwo="${head_repo_owner}/${head_repo_name}"
fi

# Worktree-aware --delete-branch. `gh pr merge --delete-branch` fails with
# "cannot delete branch X used by worktree" when the head ref is still
# checked out somewhere. The block below handles two related but
# independently gated concerns:
#
# (1) cwd_is_head_worktree rejection — runs unconditionally. Invoking
#     `gh pr merge --delete-branch` from inside the PR head worktree
#     causes gh to switch that worktree's HEAD to main, which fails
#     noisily with `fatal: 'main' is already used by worktree` when the
#     canonical main checkout lives in a different worktree. Rejecting
#     the call up-front gives orchestrators a clean rc=6 instead of
#     leaking git's error into the merge output.
#
# (2) Actual worktree pruning (git worktree remove + uncommitted/ignored
#     safety checks) — opt-in via LAND_PR_PRUNE_HEAD_WORKTREE=1. Codex
#     review rounds 1-6 surfaced a long tail of host/env/scope edge
#     cases (cross-fork PRs, GHE vs github.com, GH_HOST/GH_REPO
#     overrides, ignored content, submodules). The PA-3.1 orchestrator
#     owns worker workspaces and is the intended opt-in caller; ad-hoc
#     usage should let `gh pr merge --delete-branch` succeed or fail on
#     its own (after the cwd guard above), then resolve out of band.
#
# Same-repo identity discovery is shared by both concerns: without it a
# cross-repo worktree holding the same branch name would be falsely
# matched. Discovery runs once and gates both the cwd rejection and the
# prune step.
#
# Submodule edge case: clean worktrees with initialized submodules fail
# the non-force `git worktree remove`. After confirming clean we retry
# with --force, which is safe because submodule content lives in
# `.git/modules/` and is not destroyed by the worktree removal.
worktree_path=""
# pruned_worktree tracks what the helper ACTUALLY removed. The earlier
# refactor leaked worktree_path (discovery output) into the success
# envelope, telling callers "I pruned this" even when the opt-in was
# absent and the worktree was deliberately left intact. Only assign
# pruned_worktree after `git worktree remove` succeeds.
pruned_worktree=""
local_origin_nwo=""
local_origin_host=""
if local_origin_url="$(git remote get-url origin 2>/dev/null)"; then
  # Extract host so the same-repo identity check is host-aware.
  # Otherwise a local clone of `github.com/o/r` would be treated as the
  # same repo as a PR from `ghe.example.com/o/r` (or vice versa), which
  # would silently target unrelated local worktree branches.
  local_origin_host="$(printf '%s' "$local_origin_url" | sed -nE '
    s#^git@([^:]+):.*#\1#p
    s#^ssh://([^@]+@)?([^/:]+).*#\2#p
    s#^https?://([^@]+@)?([^/]+)/.*#\2#p
  ' | head -1)"
  # Normalise origin URL to owner/repo. Covers:
  #   git@host:owner/repo[.git]
  #   ssh://[user@]host[:port]/owner/repo[.git]
  #   https://[user@]host/owner/repo[.git]
  local_origin_nwo="$(printf '%s' "$local_origin_url" | sed -E '
    s#^git@[^:]+:##
    s#^ssh://([^@]+@)?[^/]+/##
    s#^https?://([^@]+@)?[^/]+/##
    s#\.git$##
    s#/$##
  ')"
fi
# Default-skip semantics: only set 1 when we can positively prove
# same-repo identity (owner/repo AND host both match). Any unknown
# (missing head repo or missing local origin) leaves
# should_check_worktree at 0 so neither the cwd guard nor the optional
# prune act on a speculative worktree match.
should_check_worktree=0
if [[ -n "$head_repo_nwo" && -n "$local_origin_nwo" && "$head_repo_nwo" == "$local_origin_nwo" ]]; then
  # Host disambiguation. The effective target host comes from (in order):
  #   1. pr_host_from_url — explicit URL form
  #   2. host prefix in LAND_PR_REPO when host-qualified
  #      (`HOST/OWNER/REPO`) — orchestrator env that pins a non-default
  #      gh host
  #   3. otherwise unknown → fall back to "trust local origin" because
  #      gh resolves against local origin context in that case
  # Local origin's host must match the effective host for the prune
  # guard to fire. Without LAND_PR_REPO host parsing, a numeric PR
  # against a non-default host would still false-match a local clone
  # on the default host with identical owner/repo.
  effective_pr_host=""
  if [[ -n "$pr_host_from_url" ]]; then
    effective_pr_host="$pr_host_from_url"
  elif [[ -n "${LAND_PR_REPO:-}" && "$LAND_PR_REPO" =~ ^([^/]+)/[^/]+/[^/]+$ ]]; then
    effective_pr_host="${BASH_REMATCH[1]}"
  elif [[ -n "${GH_HOST:-}" ]]; then
    # gh CLI honours GH_HOST to target non-default GitHub hosts (e.g.
    # Enterprise). When neither URL nor host-qualified LAND_PR_REPO is
    # present, GH_HOST is the effective target — treat it as the PR's
    # host for worktree prune disambiguation so a local clone on the
    # default host is not pruned for a PR on a different host.
    effective_pr_host="$GH_HOST"
  fi
  if [[ -z "$effective_pr_host" ]] \
       || [[ -z "$local_origin_host" ]] \
       || [[ "$effective_pr_host" == "$local_origin_host" ]]; then
    should_check_worktree=1
  fi
fi
if (( should_check_worktree == 1 )) && [[ -n "$head_ref" && "$head_ref" != "null" ]]; then
  worktree_path="$(git worktree list --porcelain 2>/dev/null \
    | awk -v ref="refs/heads/$head_ref" '
        /^worktree /{wt=$0; sub(/^worktree /,"",wt)}
        $0 == "branch " ref {print wt; exit}
      ')"
fi
if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
  # cwd_is_head_worktree rejection runs unconditionally. Running gh pr
  # merge --delete-branch from inside the head worktree forces gh to
  # switch that worktree's HEAD to main, which fails when the canonical
  # main checkout lives elsewhere. Surface a clear rejection so the
  # orchestrator can re-invoke from a safe directory (or pass an
  # explicit --repo).
  current_toplevel=""
  current_toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$current_toplevel" && "$current_toplevel" == "$worktree_path" ]]; then
    extra="$(jq -nc --arg wt "$worktree_path" --arg head "$head_ref" '{
      worktree: $wt, head_ref: $head,
      hint: "cwd is the PR head worktree; re-invoke from a different directory or pass LAND_PR_REPO/URL"
    }')"
    emit_envelope rejected cwd_is_head_worktree "$pr_number" 6 "$extra"
    exit 6
  fi

  # Actual worktree pruning is opt-in. Without LAND_PR_PRUNE_HEAD_WORKTREE=1
  # the helper leaves the head worktree intact and lets gh pr merge
  # --delete-branch succeed or fail on its own.
  if [[ "${LAND_PR_PRUNE_HEAD_WORKTREE:-}" == "1" ]]; then
    # `--ignored` widens the check so explicitly-ignored content (e.g.
    # local `.env` files) cannot be silently destroyed by the prune.
    # ignored content does not block git worktree remove, so without this
    # the helper would happily delete the directory and the ignored
    # files with it.
    if [[ -n "$(git -C "$worktree_path" status --porcelain --ignored 2>/dev/null)" ]]; then
      extra="$(jq -nc --arg wt "$worktree_path" --arg head "$head_ref" '{
        worktree: $wt, head_ref: $head,
        hint: "uncommitted or ignored content present; commit/stash/discard/.gitignore-clean before landing"
      }')"
      emit_envelope rejected dirty_head_worktree "$pr_number" 6 "$extra"
      exit 6
    fi
    worktree_remove_out=""
    if ! worktree_remove_out="$(git worktree remove "$worktree_path" 2>&1)"; then
      # Clean retry with --force handles the initialized-submodule case
      # where Git refuses non-force removal even on a clean worktree.
      if ! git worktree remove "$worktree_path" --force >/dev/null 2>&1; then
        extra="$(jq -nc --arg wt "$worktree_path" --arg head "$head_ref" \
                        --arg out "$worktree_remove_out" '{
          worktree: $wt, head_ref: $head, first_attempt_stderr: $out,
          hint: "git worktree remove failed even with --force; resolve manually"
        }')"
        emit_envelope rejected head_worktree_remove_failed "$pr_number" 6 "$extra"
        exit 6
      fi
    fi
    # Only now does the helper actually own the removal. Recording the
    # value here keeps the success envelope's pruned_worktree honest.
    pruned_worktree="$worktree_path"
  fi
fi

run_merge() {
  local extra_flag=("$@")
  # --match-head-commit pins the merge to the SHA we inspected. Closes the
  # TOCTOU gap between `pr view` and `pr merge`: a fresh push during this
  # helper invocation would cause gh to refuse rather than silently merge
  # an unreviewed head update under the same PR number.
  local match_flag=()
  if [[ -n "$head_sha" && "$head_sha" != "null" ]]; then
    match_flag=(--match-head-commit "$head_sha")
  fi
  gh pr merge "$pr_number" \
    ${repo_flag[@]+"${repo_flag[@]}"} \
    --"$method" --delete-branch \
    ${match_flag[@]+"${match_flag[@]}"} \
    ${extra_flag[@]+"${extra_flag[@]}"} 2>&1
}

merge_out=""
merge_rc=0
if (( auto == 1 )); then
  merge_out="$(run_merge --auto)" || merge_rc=$?
else
  merge_out="$(run_merge)" || merge_rc=$?
fi

if (( merge_rc == 0 )); then
  # `gh pr merge` exits 0 even when the target branch uses a GitHub merge
  # queue or accepts auto-merge — in those cases the PR is enqueued, not
  # yet landed on base. Verify post-merge state so orchestrators do not
  # treat "queued" as "already merged".
  post_state_json="$(gh pr view "$pr_number" ${repo_flag[@]+"${repo_flag[@]}"} \
    --json state,mergedAt 2>/dev/null || printf '{}')"
  pr_post_state="$(printf '%s' "$post_state_json" | jq -r '.state // ""')"
  pr_merged_at="$(printf '%s' "$post_state_json" | jq -r '.mergedAt // ""')"
  immediately_merged=0
  if [[ "$pr_post_state" == "MERGED" \
        && -n "$pr_merged_at" && "$pr_merged_at" != "null" ]]; then
    immediately_merged=1
  fi
  extra="$(jq -nc --arg url "$(printf '%s' "$pr_view_json" | jq -r .url)" \
                  --arg head "$head_ref" \
                  --arg worktree_pruned "$pruned_worktree" \
                  --arg post_state "$pr_post_state" \
                  --arg merged_at "$pr_merged_at" '{
    url: $url,
    head_ref: $head,
    pruned_worktree: (if $worktree_pruned == "" then null else $worktree_pruned end),
    post_state: (if $post_state == "" then null else $post_state end),
    merged_at: (if $merged_at == "" or $merged_at == "null" then null else $merged_at end)
  }')"
  if (( immediately_merged == 1 )); then
    # Reason must reflect actual code path. ${auto:+...} expanded whenever
    # `auto` was set, but `auto` is initialised to "0" — non-empty — so the
    # success reason was always "auto_merge_set" even on the immediate-merge
    # path. Use the numeric check that already gates --auto on the merge call.
    if (( auto == 1 )); then
      reason="auto_merge_set"
    else
      reason="immediate_merge"
    fi
    emit_envelope merged "$reason" "$pr_number" 0 "$extra"
    exit 0
  fi
  # Success rc without MERGED state = enqueued (merge queue) or
  # auto-merge enabled but not yet executed. Distinct result so
  # callers can poll for completion instead of assuming land.
  if (( auto == 1 )); then
    reason="auto_merge_set"
  else
    reason="enqueued"
  fi
  emit_envelope queued "$reason" "$pr_number" 0 "$extra"
  exit 0
fi

# Optional admin-merge retry. Opted into via LAND_PR_ADMIN_FALLBACK=1
# because admin bypass is a policy decision the caller must own — the
# helper does not silently escalate.
if [[ "${LAND_PR_ADMIN_FALLBACK:-}" == "1" ]] && (( auto == 0 )); then
  if printf '%s' "$merge_out" | grep -q -i -E 'branch protection|required (status|review|check)|not allowed'; then
    admin_out=""
    admin_rc=0
    admin_match_flag=()
    if [[ -n "$head_sha" && "$head_sha" != "null" ]]; then
      admin_match_flag=(--match-head-commit "$head_sha")
    fi
    admin_out="$(gh pr merge "$pr_number" ${repo_flag[@]+"${repo_flag[@]}"} \
      --"$method" --delete-branch \
      ${admin_match_flag[@]+"${admin_match_flag[@]}"} --admin 2>&1)" || admin_rc=$?
    if (( admin_rc == 0 )); then
      extra="$(jq -nc --arg url "$(printf '%s' "$pr_view_json" | jq -r .url)" \
                      --arg head "$head_ref" \
                      --arg out "$admin_out" '{
        url: $url, head_ref: $head, admin_fallback: true, admin_output: $out
      }')"
      emit_envelope merged admin_fallback "$pr_number" 0 "$extra"
      exit 0
    fi
    extra="$(jq -nc --arg merge_out "$merge_out" --arg admin_out "$admin_out" \
                    --arg state "$merge_state" --arg mergeable "$mergeable" '{
      merge_state: $state, mergeable: $mergeable,
      merge_stderr: $merge_out, admin_stderr: $admin_out
    }')"
    emit_envelope api_error admin_fallback_failed "$pr_number" 3 "$extra"
    exit 3
  fi
fi

extra="$(jq -nc --arg merge_out "$merge_out" \
                --arg state "$merge_state" --arg mergeable "$mergeable" '{
  merge_state: $state, mergeable: $mergeable, merge_stderr: $merge_out
}')"
emit_envelope api_error merge_failed "$pr_number" 3 "$extra"
exit 3
