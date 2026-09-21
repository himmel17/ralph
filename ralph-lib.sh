#!/bin/bash
# Shared helpers for ralph-safe.sh and ralph-pr.sh
# Source this file; do not run it directly.

# jq -r with carriage returns stripped (native Windows jq emits CRLF)
ralph_jq() {
  jq -r "$@" | tr -d '\r'
}

# Print [HOST/]OWNER/REPO for a git remote, or nothing if it cannot be parsed.
# Always pass the result to gh with -R: inside a fork, gh may otherwise
# resolve to the parent repository.
ralph_repo_slug() {
  local remote="$1" url rest host path
  url=$(git -C "$SCRIPT_DIR" remote get-url "$remote" 2>/dev/null || true)
  url="${url%/}"
  url="${url%.git}"
  case "$url" in
    *://*)
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    *@*:*)
      rest="${url#*@}"
      host="${rest%%:*}"
      path="${rest#*:}"
      ;;
    *)
      return 0
      ;;
  esac
  host="${host%%:*}"
  # Expect exactly OWNER/REPO
  if [[ ! "$path" =~ ^[^/]+/[^/]+$ ]]; then
    return 0
  fi
  if [ "$host" = "github.com" ]; then
    echo "$path"
  else
    echo "$host/$path"
  fi
}

# Print a one-line warning if the source issue changed after prd.json was
# derived from it. Prints nothing when there is no source issue, when gh is
# unavailable, or when the issue is unchanged.
ralph_issue_stale_warning() {
  local prd_file="$1" slug="$2" issue recorded current
  [ -n "$slug" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  issue=$(ralph_jq '.source.issue // empty' "$prd_file" 2>/dev/null || true)
  recorded=$(ralph_jq '.source.issueUpdatedAt // empty' "$prd_file" 2>/dev/null || true)
  [ -n "$issue" ] && [ -n "$recorded" ] || return 0
  current=$(gh issue view "$issue" -R "$slug" --json updatedAt --jq .updatedAt 2>/dev/null | tr -d '\r' || true)
  if [ -z "$current" ]; then
    echo "Could not check issue #$issue for changes (gh failed or not authenticated)."
  elif [ "$current" != "$recorded" ]; then
    echo "Issue #$issue changed after prd.json was derived from it (recorded $recorded, now $current). Comments and label changes also count; re-derive prd.json if the requirements changed."
  fi
}
