#!/usr/bin/env bash
# Resolve the local worktree that has a PR head branch checked out.

set -uo pipefail

usage() {
  echo "Usage: resolve-pr-worktree.sh <repo-nwo> <head-branch> [head-sha]" >&2
}

lowercase() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

normalize_to_nwo() {
  local value="$1"

  value="${value%/}"
  value="${value%.git}"

  if [[ "$value" =~ ^[^@]+@github\.com:(.+)$ ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    value="${value#*://}"
    value="${value#*@}"
    value="${value#github.com/}"
  elif [[ "$value" =~ ^github\.com/(.+)$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi

  value="${value%/}"
  value="${value%.git}"

  if [[ "$value" =~ ^([^/]+)/([^/]+)$ ]]; then
    lowercase "$value"
    return 0
  fi

  return 1
}

add_candidate() {
  local dir="$1" top existing

  [[ -n "$dir" && -d "$dir" ]] || return 0
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 0

  if [[ "${#candidates[@]}" -gt 0 ]]; then
    for existing in "${candidates[@]}"; do
      [[ "$existing" == "$top" ]] && return 0
    done
  fi
  candidates+=("$top")
}

repo_matches_target() {
  local repo="$1" remote remote_nwo

  remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  [[ -n "$remote" ]] || return 1

  remote_nwo="$(normalize_to_nwo "$remote" 2>/dev/null || true)"
  [[ -n "$remote_nwo" && "$remote_nwo" == "$target_nwo" ]]
}

find_branch_worktrees() {
  local repo="$1" branch="$2" ref

  ref="refs/heads/$branch"
  git -C "$repo" worktree list --porcelain 2>/dev/null \
    | awk -v ref="$ref" '
        /^worktree / {
          wt=$0
          sub(/^worktree /, "", wt)
          next
        }
        /^branch / {
          branch=$0
          sub(/^branch /, "", branch)
          if (branch == ref && wt != "") {
            print wt
            found=1
          }
        }
        END { exit found ? 0 : 1 }
      '
}

if [[ "$#" -ne 2 && "$#" -ne 3 ]]; then
  usage
  exit 64
fi

repo_nwo="$1"
head_branch="$2"
head_sha="${3:-}"

target_nwo="$(normalize_to_nwo "$repo_nwo" 2>/dev/null || true)"
if [[ -z "$target_nwo" ]]; then
  echo "ERROR: repo must be owner/repo: $repo_nwo" >&2
  exit 64
fi
if [[ -z "$head_branch" ]]; then
  echo "ERROR: head branch must not be empty" >&2
  exit 64
fi
if [[ "$#" -eq 3 && -z "$head_sha" ]]; then
  echo "ERROR: head sha must not be empty when provided" >&2
  exit 64
fi

candidates=()
add_candidate "$PWD"

repo_name="${target_nwo##*/}"
ws_root="${HOME:-}/ws"
if [[ -n "${HOME:-}" ]]; then
  add_candidate "$ws_root/$target_nwo"
  add_candidate "$ws_root/$repo_name"
fi

if [[ -d "$ws_root" ]]; then
  for dir in "$ws_root"/*; do
    [[ -d "$dir" ]] || continue
    add_candidate "$dir"
  done
fi

found_branch_worktree=0
if [[ "${#candidates[@]}" -gt 0 ]]; then
  for candidate in "${candidates[@]}"; do
    repo_matches_target "$candidate" || continue
    while IFS= read -r worktree; do
      found_branch_worktree=1
      if [[ -n "$worktree" && -d "$worktree" ]]; then
        if [[ -n "$head_sha" ]]; then
          worktree_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
          [[ "$worktree_head" == "$head_sha" ]] || continue
        fi
        if abs_worktree="$(cd "$worktree" 2>/dev/null && pwd -P)"; then
          printf '%s\n' "$abs_worktree"
        else
          printf '%s\n' "$worktree"
        fi
        exit 0
      fi
    done < <(find_branch_worktrees "$candidate" "$head_branch" || true)
  done
fi

if [[ -n "$head_sha" && "$found_branch_worktree" -eq 1 ]]; then
  echo "ERROR: found local worktree(s) for $repo_nwo branch $head_branch, but none has HEAD $head_sha; update or checkout the PR head branch at that SHA first" >&2
  exit 1
fi

echo "ERROR: could not find local worktree for $repo_nwo branch $head_branch; checkout the PR head branch into a worktree first" >&2
exit 1
