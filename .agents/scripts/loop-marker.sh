#!/usr/bin/env bash
# loop-marker.sh — create/remove the autonomous-loop marker with a session-owner stamp.
#
# The loop-stop-guard Stop hook (config/agents/hooks/loop-stop-guard.sh) only blocks the
# session that OWNS the marker: it compares the marker's `owner_session` to the turn's
# session_id and stays inert for every other session in the same cwd. This helper is the
# canonical way to create the marker so the owner is ALWAYS stamped — agents must not
# hand-write it. A marker without owner_session is inert (the hook ignores it).
#
# owner id source: $CLAUDE_CODE_SESSION_ID (Claude Code injects it into the tool shell;
# equals the Stop hook payload .session_id) or $LOOP_OWNER_SESSION. If neither is set,
# `start` FAILS (exit 4): an un-owned marker is inert in the hook (no stop guard) yet
# `status` would report it active, so we refuse to create that silent gap.
#
# Usage:
#   loop-marker.sh start "<one-line task summary>"   # create  <cwd>/.run/loop-active
#   loop-marker.sh stop                              # remove  <cwd>/.run/loop-active (+ legacy)
#   loop-marker.sh status                            # print owner; exit 0 if active else 1
set -uo pipefail

run_dir=".run"
marker="$run_dir/loop-active"
legacy_marker=".dev-cycle/loop-active"   # DEC-049 dual-read: the hook still honors this path
state_file="$run_dir/.loop-stop-state"

usage() { printf 'usage: loop-marker.sh {start "<desc>"|stop|status}\n' >&2; exit 2; }

# Ensure .run/ is gitignored in the current repo so `start` never dirties an arbitrary
# target repo (matches what run-helper does). No-op outside a git repo or if already excluded.
ensure_run_ignored() {
  local gitdir excl
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
  excl="$gitdir/info/exclude"
  mkdir -p "$gitdir/info" 2>/dev/null || true
  [ -f "$excl" ] && grep -qxF '.run/' "$excl" 2>/dev/null && return 0
  printf '.run/\n' >> "$excl" 2>/dev/null || true
}

cmd="${1:-}"
case "$cmd" in
  start)
    desc="${2:-autonomous loop}"
    # Strip CR/LF from desc so it can't inject a second `owner_session:` line into the
    # marker (the hook reads the FIRST owner_session and would then see a mismatch → inert).
    desc="$(printf '%s' "$desc" | tr -d '\r\n')"
    owner="${CLAUDE_CODE_SESSION_ID:-${LOOP_OWNER_SESSION:-}}"
    # Require an owner. An un-owned marker is inert (the hook ignores it) but `status` would
    # report it active — a silent "guard looks on but isn't" gap. Fail rather than create it.
    if [ -z "$owner" ]; then
      printf 'loop-marker: refusing to start without an owner.\n' >&2
      printf '  CLAUDE_CODE_SESSION_ID / LOOP_OWNER_SESSION unset → the marker would be inert (no stop guard).\n' >&2
      exit 4
    fi
    # Refuse to clobber a marker owned by a DIFFERENT session: truncating it would stamp us
    # as owner and silently disable the original session's guard (owner != session_id).
    if [ -f "$marker" ]; then
      existing="$(sed -n 's/^owner_session:[[:space:]]*//p' "$marker" 2>/dev/null | head -1 | tr -d '[:space:]')"
      if [ -n "$existing" ] && [ "$existing" != "$owner" ]; then
        printf 'loop-marker: refusing to overwrite marker owned by another session (%s != %s).\n' "$existing" "$owner" >&2
        printf '  Run `loop-marker.sh stop` in that session first, or start the loop in a separate cwd.\n' >&2
        exit 3
      fi
    fi
    ensure_run_ignored
    if ! mkdir -p "$run_dir" 2>/dev/null; then
      printf 'loop-marker: cannot create %s/ (a file named %s exists, or permission denied).\n' "$run_dir" "$run_dir" >&2
      exit 5
    fi
    rm -f "$state_file"   # reset stale nudge-cap state so the cap is scoped to THIS loop
    if ! {
      printf 'active: %s\n' "$desc"
      printf 'owner_session: %s\n' "$owner"
      printf 'started: %s\n' "$(date +%F 2>/dev/null || echo unknown)"
      printf 'rule: 진짜 stop 조건(ALL CLEAR/authority gate/인증·권한·destructive git/해결 불가 blocker) 시 이 파일 rm (또는 loop-marker.sh stop)\n'
    } > "$marker"; then
      printf 'loop-marker: failed to write marker %s — not started.\n' "$marker" >&2
      exit 5
    fi
    printf 'loop-marker: started; owner_session=%s\n' "$owner"
    ;;
  stop)
    rm -f "$marker" "$legacy_marker"   # also clear the DEC-049 legacy marker the hook honors
    # The hook adopts a marker THIS session owns from a sibling worktree (loop-root recovery),
    # so a stop issued from a task worktree must also remove the owner-matched marker living
    # under another worktree — otherwise the next Stop re-adopts it and the loop never stops.
    owner="${CLAUDE_CODE_SESSION_ID:-${LOOP_OWNER_SESSION:-}}"
    if [ -n "$owner" ]; then
      while IFS= read -r wt; do
        for d in .run .dev-cycle; do
          m="$wt/$d/loop-active"
          [ -f "$m" ] || continue
          o="$(sed -n 's/^owner_session:[[:space:]]*//p' "$m" 2>/dev/null | head -1 | tr -d '[:space:]')"
          [ "$o" = "$owner" ] && rm -f "$m"
        done
      done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
    fi
    printf 'loop-marker: stopped\n'
    ;;
  status)
    if [ -f "$marker" ]; then
      o="$(sed -n 's/^owner_session:[[:space:]]*//p' "$marker" 2>/dev/null | head -1)"
      printf 'active; owner_session=%s\n' "${o:-<none/legacy>}"
      exit 0
    fi
    printf 'inactive\n'
    exit 1
    ;;
  ""|-h|--help) usage ;;
  *) printf 'loop-marker: unknown command %s\n' "$cmd" >&2; usage ;;
esac
