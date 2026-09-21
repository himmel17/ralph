#!/bin/bash
# Ralph PR publisher - pushes the Ralph branch and opens a PR from prd.json
# Usage: ./ralph-pr.sh [--dry-run] [--issue N] [--no-followups]
#
# Run this yourself after the loop has finished and you have looked at the
# result. It never merges: a human reviews and merges the PR.
#
# Entries the agent left in prd.json "followUps" are filed as new issues first
# (skip with --no-followups). They get the label $RALPH_FOLLOWUP_LABEL
# (default: ralph-followup) if the repository has it.

set -e

DRY_RUN=false
ISSUE_OVERRIDE=""
FILE_FOLLOWUPS=true
FOLLOWUP_LABEL="${RALPH_FOLLOWUP_LABEL-ralph-followup}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --issue)
      ISSUE_OVERRIDE="$2"
      shift 2
      ;;
    --issue=*)
      ISSUE_OVERRIDE="${1#*=}"
      shift
      ;;
    --no-followups)
      FILE_FOLLOWUPS=false
      shift
      ;;
    *)
      echo "Error: Unknown argument '$1'."
      echo "Usage: ./ralph-pr.sh [--dry-run] [--issue N] [--no-followups]"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
REMOTE="${RALPH_REMOTE:-origin}"

source "$SCRIPT_DIR/ralph-lib.sh"

# Check prerequisites
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required."
  exit 1
fi
if [ "$DRY_RUN" = false ] && ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh is required (or use --dry-run)."
  exit 1
fi
if [ ! -f "$PRD_FILE" ]; then
  echo "Error: $PRD_FILE not found."
  exit 1
fi

BRANCH=$(ralph_jq '.branchName // empty' "$PRD_FILE")
CURRENT_BRANCH=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)
if [ -z "$BRANCH" ]; then
  echo "Error: prd.json has no branchName."
  exit 1
fi
if [ "$BRANCH" != "$CURRENT_BRANCH" ]; then
  echo "Error: Current branch is '$CURRENT_BRANCH' but prd.json expects '$BRANCH'."
  exit 1
fi

TOTAL=$(ralph_jq '.userStories | length' "$PRD_FILE")
PASSED=$(ralph_jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")
if [ "$TOTAL" -eq 0 ]; then
  echo "Error: prd.json has no user stories."
  exit 1
fi

ISSUE="$ISSUE_OVERRIDE"
if [ -z "$ISSUE" ]; then
  ISSUE=$(ralph_jq '.source.issue // empty' "$PRD_FILE")
fi
if [ -n "$ISSUE" ] && [[ ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: Issue must be a number, got '$ISSUE'."
  exit 1
fi

# Ralph marks the last story as passing after its final commit, so prd.json and
# progress.txt are usually left modified. Commit those; refuse anything else.
PREFIX=$(git -C "$SCRIPT_DIR" rev-parse --show-prefix)
STATE_FILES=()
OTHER_FILES=()
while IFS= read -r -d '' ENTRY; do
  STATUS="${ENTRY:0:2}"
  FILE="${ENTRY:3}"
  if [[ "$STATUS" == R* || "$STATUS" == C* ]]; then
    # Renames and copies carry the original path as an extra field
    IFS= read -r -d '' _ORIGINAL || true
  fi
  case "$FILE" in
    "${PREFIX}prd.json"|"${PREFIX}progress.txt")
      STATE_FILES+=("$FILE")
      ;;
    "${PREFIX}.last-branch"|"${PREFIX}archive/"*)
      # Ralph working files that are optional to commit
      ;;
    *)
      OTHER_FILES+=("$FILE")
      ;;
  esac
done < <(git -C "$SCRIPT_DIR" status --porcelain -z)

if [ ${#OTHER_FILES[@]} -gt 0 ]; then
  echo "Error: Uncommitted changes outside Ralph's state files:"
  printf '  %s\n' "${OTHER_FILES[@]}"
  echo "Commit or discard them, then run again."
  exit 1
fi

# Decide between a closing PR and a draft
if [ "$PASSED" -eq "$TOTAL" ]; then
  DRAFT=false
  ISSUE_LINE="Closes #$ISSUE"
else
  DRAFT=true
  ISSUE_LINE="Refs #$ISSUE - $PASSED of $TOTAL stories pass, so this PR does not close the issue."
fi

SLUG=$(ralph_repo_slug "$REMOTE")
if [ "$DRY_RUN" = false ] && [ -z "$SLUG" ]; then
  echo "Error: Could not determine OWNER/REPO from remote '$REMOTE'."
  exit 1
fi

# File the follow-ups the agent recorded, one issue each. The number is written
# back to prd.json right away, so running again never files one twice. A
# failure here (issues disabled, for example) does not stop the PR.
PENDING_FOLLOWUPS=$(ralph_jq '(.followUps // []) | to_entries[] | select(.value.issue == null) | .key' "$PRD_FILE")
if [ "$FILE_FOLLOWUPS" = true ] && [ "$DRY_RUN" = false ] && [ -n "$PENDING_FOLLOWUPS" ]; then
  LABEL_ARGS=()
  if [ -n "$FOLLOWUP_LABEL" ] && gh label list -R "$SLUG" --search "$FOLLOWUP_LABEL" --json name --jq '.[].name' 2>/dev/null | tr -d '' | grep -qxF -- "$FOLLOWUP_LABEL"; then
    LABEL_ARGS=(--label "$FOLLOWUP_LABEL")
  fi
  FOLLOWUP_BODY=$(mktemp)
  FILED_ANY=false
  for INDEX in $PENDING_FOLLOWUPS; do
    FOLLOWUP_TITLE=$(ralph_jq --argjson i "$INDEX" '.followUps[$i].title // empty' "$PRD_FILE")
    if [ -z "$FOLLOWUP_TITLE" ]; then
      echo "Warning: followUps[$INDEX] has no title. Skipped."
      continue
    fi
    ralph_jq --argjson i "$INDEX" --arg issue "$ISSUE" '.followUps[$i] |
      (.body // "") + "

"
      + (if (.evidence // "") != "" then "**Evidence:** " + .evidence + "

" else "" end)
      + "---
Found by the Ralph loop"
      + (if $issue != "" then " while working on #" + $issue else "" end)
      + (if (.foundIn // "") != "" then " (story " + .foundIn + ")" else "" end)
      + ". Reported by an agent and not verified by a human."' "$PRD_FILE" > "$FOLLOWUP_BODY"
    FOLLOWUP_URL=$(gh issue create -R "$SLUG" --title "$FOLLOWUP_TITLE" --body-file "$FOLLOWUP_BODY" "${LABEL_ARGS[@]}" | tr -d '' | tail -n 1)
    FOLLOWUP_NUMBER="${FOLLOWUP_URL##*/}"
    if [[ ! "$FOLLOWUP_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "Warning: Could not file follow-up '$FOLLOWUP_TITLE'. It stays in prd.json; run again to retry."
      continue
    fi
    jq --argjson i "$INDEX" --argjson n "$FOLLOWUP_NUMBER" '.followUps[$i].issue = $n' "$PRD_FILE" | tr -d '' > "$PRD_FILE.tmp"
    mv "$PRD_FILE.tmp" "$PRD_FILE"
    FILED_ANY=true
    echo "Filed follow-up #$FOLLOWUP_NUMBER: $FOLLOWUP_TITLE"
  done
  rm -f "$FOLLOWUP_BODY"
  if [ "$FILED_ANY" = true ] && [[ ! " ${STATE_FILES[*]} " == *" ${PREFIX}prd.json "* ]]; then
    STATE_FILES+=("${PREFIX}prd.json")
  fi
fi

STALE_WARNING=$(ralph_issue_stale_warning "$PRD_FILE" "$SLUG")

TITLE=$(ralph_jq '.description // empty' "$PRD_FILE")
if [ -z "$TITLE" ]; then
  TITLE="$BRANCH"
fi

# Build the PR body
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT
{
  echo "## Summary"
  echo ""
  echo "$TITLE"
  echo ""
  if [ -n "$ISSUE" ]; then
    echo "$ISSUE_LINE"
    echo ""
  fi
  echo "## Stories ($PASSED/$TOTAL passing)"
  echo ""
  ralph_jq '(.source.approvedStoryIds // null) as $approved | .userStories | sort_by(.priority)[]
    | "- [" + (if .passes == true then "x" else " " end) + "] " + .id + ": " + .title
    + (if .passes != true and .blocked == true then " - **blocked**" else "" end)
    + (if $approved != null and (.id as $id | $approved | index($id) | not) then " - _added during the loop, not approved by a human_" else "" end)' "$PRD_FILE"
  echo ""
  BLOCKED=$(ralph_jq '.userStories | sort_by(.priority)[] | select(.passes != true and .blocked == true) | "### " + .id + ": " + .title + "

" + (.blockedReason // "(no blockedReason given)") + "
"' "$PRD_FILE")
  if [ -n "$BLOCKED" ]; then
    echo "## Blocked - needs a human"
    echo ""
    echo "$BLOCKED"
    echo ""
  fi
  NOTES=$(ralph_jq '.userStories | sort_by(.priority)[] | select((.notes // "") != "") | "### " + .id + ": " + .title + "\n\n" + .notes + "\n"' "$PRD_FILE")
  if [ -n "$NOTES" ]; then
    echo "## Notes"
    echo ""
    echo "$NOTES"
    echo ""
  fi
  FOLLOWUPS=$(ralph_jq '(.followUps // [])[]
    | ([.kind, (if (.foundIn // "") != "" then "found in " + .foundIn else null end)] | map(select(. != null and . != "")) | join(", ")) as $details
    | "- " + (if .issue != null then "#" + (.issue | tostring) + " " else "" end) + (.title // "(no title)")
    + (if $details != "" then " (" + $details + ")" else "" end)
    + (if .issue == null then " - not filed" else "" end)' "$PRD_FILE")
  if [ -n "$FOLLOWUPS" ]; then
    echo "## Follow-ups found during the loop"
    echo ""
    echo "Outside the scope of this PR, reported by the agent and not verified."
    echo ""
    echo "$FOLLOWUPS"
    echo ""
  fi
  if [ -n "$STALE_WARNING" ]; then
    echo "> [!WARNING]"
    echo "> $STALE_WARNING"
    echo ""
  fi
  echo "---"
  echo "Generated by ralph-pr.sh from prd.json. Story status is reported by the agent itself; review before merging."
} > "$BODY_FILE"

CREATE_ARGS=(--head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE")
if [ "$DRAFT" = true ]; then
  CREATE_ARGS+=(--draft)
fi

if [ "$DRY_RUN" = true ]; then
  echo "Dry run - nothing will be committed, pushed or created."
  echo ""
  if [ ${#STATE_FILES[@]} -gt 0 ]; then
    echo "Would commit: ${STATE_FILES[*]}"
  fi
  if [ "$FILE_FOLLOWUPS" = true ] && [ -n "$PENDING_FOLLOWUPS" ]; then
    echo "Would file these follow-ups as issues in ${SLUG:-<unknown>}, then record the numbers in prd.json:"
    ralph_jq '(.followUps // [])[] | select(.issue == null) | "  " + (.title // "(no title)")' "$PRD_FILE"
  fi
  echo "Would run: git push -u $REMOTE $BRANCH"
  echo "Would run: gh pr create -R ${SLUG:-<unknown>} --base <default branch> ${CREATE_ARGS[*]}"
  echo "  (or gh pr edit --body-file if a PR for $BRANCH is already open)"
  echo ""
  echo "----- PR body -----"
  cat "$BODY_FILE"
  exit 0
fi

if [ ${#STATE_FILES[@]} -gt 0 ]; then
  ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
  git -C "$ROOT" add -- "${STATE_FILES[@]}"
  git -C "$ROOT" commit -m "chore: update Ralph state" -- "${STATE_FILES[@]}"
fi

git -C "$SCRIPT_DIR" push -u "$REMOTE" "$BRANCH"

EXISTING_PR=$(gh pr list -R "$SLUG" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' | tr -d '\r')
if [ -n "$EXISTING_PR" ]; then
  gh pr edit "$EXISTING_PR" -R "$SLUG" --body-file "$BODY_FILE"
  echo "Updated the body of PR #$EXISTING_PR. Its draft state was left unchanged."
else
  BASE=$(gh repo view "$SLUG" --json defaultBranchRef --jq .defaultBranchRef.name | tr -d '\r')
  gh pr create -R "$SLUG" --base "$BASE" "${CREATE_ARGS[@]}"
fi

echo ""
echo "Done. Review and merge the PR yourself; the issue closes when a 'Closes' PR is merged into the default branch."
