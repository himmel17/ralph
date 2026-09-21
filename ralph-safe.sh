#!/bin/bash
# Ralph safe launcher - runs ralph.sh with GitHub access disabled
# Usage: ./ralph-safe.sh [--tool amp|claude] [max_iterations]
#
# While the loop runs, gh is logged out (empty GH_CONFIG_DIR) and the push URL
# of the remote is set to DISABLED. This is a guard against accidents, not a
# sandbox: the agent could undo both if it tried.
#
# ralph.sh is called one iteration at a time. Between iterations prd.json is
# checked, and the loop stops early when a human is needed:
#   exit 0  all stories pass
#   exit 1  max iterations reached
#   exit 2  a story is blocked
#   exit 3  no story passed for RALPH_STALL_LIMIT iterations in a row (default 3)
#   exit 4  prd.json is unreadable, its source changed, or more than
#           RALPH_MAX_ADDED_STORIES stories were added (default 3)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
REMOTE="${RALPH_REMOTE:-origin}"
STALL_LIMIT="${RALPH_STALL_LIMIT:-3}"
MAX_ADDED="${RALPH_MAX_ADDED_STORIES:-3}"
UNSET_MARKER="__unset__"

source "$SCRIPT_DIR/ralph-lib.sh"

# Split the arguments the way ralph.sh reads them: a bare number is
# max_iterations, everything else is passed through
MAX_ITERATIONS=10
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      PASS_ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        PASS_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

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

print_blocked() {
  ralph_jq '.userStories[] | select(.passes != true and .blocked == true) | "  " + .id + ": " + .title + "\n    " + (.blockedReason // "(no blockedReason given)")' "$PRD_FILE"
}

stop_banner() {
  echo ""
  echo "==============================================================="
  echo "  ralph-safe.sh stopped the loop: $1"
  echo "==============================================================="
}

if [ ! -f "$SCRIPT_DIR/ralph.sh" ]; then
  echo "Error: ralph.sh not found in $SCRIPT_DIR"
  exit 1
fi

# A previous run may have been killed before it could restore the push URL
restore_push_url

# Without prd.json there is nothing to watch: hand over to ralph.sh as before
WATCH=false
if [ -f "$PRD_FILE" ]; then
  if ! jq -e '.userStories | type == "array"' "$PRD_FILE" >/dev/null 2>&1; then
    echo "Error: $PRD_FILE is not valid JSON with a userStories array."
    exit 4
  fi
  WATCH=true

  if [ -n "$(print_blocked)" ]; then
    echo "Error: prd.json already has a blocked story:"
    print_blocked
    echo "Resolve it, remove \"blocked\" from the story, then run again."
    exit 2
  fi

  # Check the source issue while gh is still authenticated
  STALE_WARNING=$(ralph_issue_stale_warning "$PRD_FILE" "$(ralph_repo_slug "$REMOTE")")
  if [ -n "$STALE_WARNING" ]; then
    echo "Warning: $STALE_WARNING"
  fi

  # What the human approved. Older prd.json files have no approvedStoryIds,
  # so fall back to the stories present at startup.
  SOURCE_BASELINE=$(jq -c -S '.source // null' "$PRD_FILE" | tr -d '\r')
  APPROVED_IDS=$(jq -c '.source.approvedStoryIds // [.userStories[].id]' "$PRD_FILE" | tr -d '\r')
  BEST_PASSED=$(ralph_passed_count "$PRD_FILE")
fi

trap cleanup EXIT
trap 'exit 130' INT TERM

# Log gh out for every child process
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
GH_ISOLATED_DIR=$(mktemp -d)
export GH_CONFIG_DIR="$GH_ISOLATED_DIR"

disable_push_url

if [ "$WATCH" = false ]; then
  set +e
  bash "$SCRIPT_DIR/ralph.sh" "${PASS_ARGS[@]}" "$MAX_ITERATIONS"
  EXIT_CODE=$?
  set -e
  exit $EXIT_CODE
fi

STALLED=0
for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "ralph-safe.sh: iteration $i of $MAX_ITERATIONS (ralph.sh reports each one as \"1 of 1\")"

  set +e
  bash "$SCRIPT_DIR/ralph.sh" "${PASS_ARGS[@]}" 1
  EXIT_CODE=$?
  set -e

  if ! jq -e '.userStories | type == "array"' "$PRD_FILE" >/dev/null 2>&1; then
    stop_banner "prd.json is missing or no longer valid JSON"
    exit 4
  fi

  TOTAL=$(ralph_jq '.userStories | length' "$PRD_FILE")
  PASSED=$(ralph_passed_count "$PRD_FILE")

  if [ "$(jq -c -S '.source // null' "$PRD_FILE" | tr -d '\r')" != "$SOURCE_BASELINE" ]; then
    stop_banner "the agent changed the \"source\" field of prd.json"
    echo "Expected: $SOURCE_BASELINE"
    exit 4
  fi

  if [ -n "$(print_blocked)" ]; then
    stop_banner "a story is blocked and needs you ($PASSED of $TOTAL stories pass)"
    print_blocked
    echo ""
    echo "Resolve it, remove \"blocked\" from the story, then run ralph-safe.sh again."
    echo "If the requirements were wrong, fix the issue and convert it again with the ralph-issue skill."
    exit 2
  fi

  ADDED=$(ralph_jq --argjson approved "$APPROVED_IDS" '[.userStories[].id] - $approved | length' "$PRD_FILE")
  if [ "$ADDED" -gt "$MAX_ADDED" ]; then
    stop_banner "the agent added $ADDED stories (limit $MAX_ADDED)"
    ralph_jq --argjson approved "$APPROVED_IDS" '.userStories[] | select(.id as $id | $approved | index($id) | not) | "  " + .id + ": " + .title' "$PRD_FILE"
    exit 4
  fi

  if [ "$PASSED" -eq "$TOTAL" ]; then
    echo ""
    echo "ralph-safe.sh: all $TOTAL stories pass."
    exit 0
  fi
  if [ "$EXIT_CODE" -eq 0 ]; then
    echo "ralph-safe.sh: the agent reported COMPLETE but only $PASSED of $TOTAL stories pass. Continuing."
  fi

  # Progress means more passing stories than this run has ever had, so a story
  # flipping between pass and fail does not count
  if [ "$PASSED" -gt "$BEST_PASSED" ]; then
    BEST_PASSED=$PASSED
    STALLED=0
  else
    STALLED=$((STALLED + 1))
    if [ "$STALLED" -ge "$STALL_LIMIT" ]; then
      stop_banner "no story passed in the last $STALLED iterations ($PASSED of $TOTAL stories pass)"
      echo "Check progress.txt. The tool may also be failing to start (rate limit, authentication)."
      exit 3
    fi
  fi
done

echo ""
echo "ralph-safe.sh: reached max iterations ($MAX_ITERATIONS). $PASSED of $TOTAL stories pass."
exit 1
