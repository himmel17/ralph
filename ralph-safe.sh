#!/bin/bash
# Ralph safe launcher - runs ralph.sh with GitHub access disabled
# Usage: ./ralph-safe.sh [ralph.sh arguments...]
#
# While the loop runs, gh is logged out (empty GH_CONFIG_DIR) and the push URL
# of the remote is set to DISABLED. This is a guard against accidents, not a
# sandbox: the agent could undo both if it tried.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
REMOTE="${RALPH_REMOTE:-origin}"
UNSET_MARKER="__unset__"

source "$SCRIPT_DIR/ralph-lib.sh"

# Restore the push URL saved by this or a previous (killed) run
restore_push_url() {
  local saved saved_remote
  saved=$(git -C "$SCRIPT_DIR" config --get ralph.savedPushUrl 2>/dev/null || true)
  saved_remote=$(git -C "$SCRIPT_DIR" config --get ralph.savedPushRemote 2>/dev/null || true)
  if [ -z "$saved" ] || [ -z "$saved_remote" ]; then
    return 0
  fi
  if [ "$saved" = "$UNSET_MARKER" ]; then
    git -C "$SCRIPT_DIR" config --unset-all "remote.$saved_remote.pushurl" 2>/dev/null || true
  else
    git -C "$SCRIPT_DIR" remote set-url --push "$saved_remote" "$saved"
  fi
  git -C "$SCRIPT_DIR" config --unset ralph.savedPushUrl
  git -C "$SCRIPT_DIR" config --unset ralph.savedPushRemote
  echo "Restored push URL of remote '$saved_remote'."
}

disable_push_url() {
  local current
  if ! git -C "$SCRIPT_DIR" remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "Remote '$REMOTE' not found. Skipping push protection."
    return 0
  fi
  current=$(git -C "$SCRIPT_DIR" config --get "remote.$REMOTE.pushurl" 2>/dev/null || true)
  git -C "$SCRIPT_DIR" config ralph.savedPushUrl "${current:-$UNSET_MARKER}"
  git -C "$SCRIPT_DIR" config ralph.savedPushRemote "$REMOTE"
  git -C "$SCRIPT_DIR" remote set-url --push "$REMOTE" DISABLED
  echo "Disabled push to remote '$REMOTE' for the duration of the loop."
}

cleanup() {
  restore_push_url
  if [ -n "$GH_ISOLATED_DIR" ] && [ -d "$GH_ISOLATED_DIR" ]; then
    rm -rf "$GH_ISOLATED_DIR"
  fi
}

if [ ! -f "$SCRIPT_DIR/ralph.sh" ]; then
  echo "Error: ralph.sh not found in $SCRIPT_DIR"
  exit 1
fi

# A previous run may have been killed before it could restore the push URL
restore_push_url

# Check the source issue while gh is still authenticated
if [ -f "$PRD_FILE" ]; then
  STALE_WARNING=$(ralph_issue_stale_warning "$PRD_FILE" "$(ralph_repo_slug "$REMOTE")")
  if [ -n "$STALE_WARNING" ]; then
    echo "Warning: $STALE_WARNING"
  fi
fi

trap cleanup EXIT
trap 'exit 130' INT TERM

# Log gh out for every child process
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
GH_ISOLATED_DIR=$(mktemp -d)
export GH_CONFIG_DIR="$GH_ISOLATED_DIR"

disable_push_url

set +e
bash "$SCRIPT_DIR/ralph.sh" "$@"
EXIT_CODE=$?
set -e

exit $EXIT_CODE
