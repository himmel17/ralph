#!/bin/bash
# Tests for ralph-pr.sh. Runs offline: gh is replaced by a stub, and pushes go
# to a local bare repository.
# Usage: bash tests/test-ralph-pr.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok   - $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL - $1"
}

assert_contains() {
  if grep -qF -- "$2" <<< "$OUTPUT"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

assert_not_contains() {
  if grep -qF -- "$2" <<< "$OUTPUT"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}

assert_exit() {
  if [ "$EXIT_CODE" -eq "$2" ]; then pass "$1"; else fail "$1 (exit $EXIT_CODE, expected $2)"; fi
}

# Stub gh: logs every call to $GH_LOG, numbers created issues from 1, and keeps
# the body files it was given in $GH_BODY_DIR
STUB_DIR="$WORK_DIR/bin"
export GH_LOG="$WORK_DIR/gh.log"
export GH_BODY_DIR="$WORK_DIR/gh-bodies"
mkdir -p "$STUB_DIR" "$GH_BODY_DIR"
: > "$GH_LOG"
cat > "$STUB_DIR/gh" << 'EOF'
#!/bin/bash
echo "$*" >> "$GH_LOG"
COMMAND="$1 $2"
BODY_FILE=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--body-file" ]; then BODY_FILE="$2"; fi
  shift
done
case "$COMMAND" in
  "issue view")
    echo "${FAKE_GH_UPDATED_AT:-}"
    ;;
  "label list")
    echo "${FAKE_GH_LABELS:-}"
    ;;
  "issue create")
    if [ "${FAKE_GH_ISSUE_FAIL:-}" = 1 ]; then
      echo "gh stub: issues are disabled" >&2
      exit 1
    fi
    N=$(( $(grep -c "^issue create" "$GH_LOG") ))
    cp "$BODY_FILE" "$GH_BODY_DIR/issue-$N.md"
    echo "https://github.com/example-owner/example-repo/issues/$N"
    ;;
  "pr list")
    ;;
  "repo view")
    echo "main"
    ;;
  "pr create")
    cp "$BODY_FILE" "$GH_BODY_DIR/pr.md"
    echo "https://github.com/example-owner/example-repo/pull/100"
    ;;
  *)
    echo "gh stub: unexpected call: $COMMAND" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

# A project repo with Ralph copied into scripts/ralph, as the README describes
PROJECT="$WORK_DIR/project"
RALPH_DIR="$PROJECT/scripts/ralph"
mkdir -p "$RALPH_DIR"
cp "$REPO_DIR/ralph-pr.sh" "$REPO_DIR/ralph-lib.sh" "$RALPH_DIR/"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name "Ralph Test"
git -C "$PROJECT" config user.email "ralph-test@example.invalid"
git -C "$PROJECT" config core.autocrlf false
git -C "$PROJECT" remote add origin https://github.com/example-owner/example-repo.git
git -C "$PROJECT" add .
git -C "$PROJECT" commit -q -m "initial"
git -C "$PROJECT" checkout -q -b ralph/test-feature

# write_prd <passes of US-002> <source JSON or null>
write_prd() {
  cat > "$RALPH_DIR/prd.json" << EOF
{
  "project": "TestApp",
  "branchName": "ralph/test-feature",
  "description": "Test Feature - exercise ralph-pr.sh",
  "source": $2,
  "userStories": [
    {"id": "US-002", "title": "Second story", "priority": 2, "passes": $1, "notes": ""},
    {"id": "US-001", "title": "First story", "priority": 1, "passes": true, "notes": "Used the existing badge component."}
  ]
}
EOF
}

# Output goes through a file: Git Bash drops carriage returns inside $(...),
# which would hide the CRLF that native Windows jq emits.
OUTPUT_FILE="$WORK_DIR/output.txt"
run_pr() {
  bash "$RALPH_DIR/ralph-pr.sh" "$@" > "$OUTPUT_FILE" 2>&1
  EXIT_CODE=$?
  OUTPUT=$(cat "$OUTPUT_FILE")
}

SOURCE='{"type": "github-issue", "issue": 12, "url": "https://github.com/example-owner/example-repo/issues/12", "issueUpdatedAt": "2026-09-01T00:00:00Z"}'
export FAKE_GH_UPDATED_AT="2026-09-01T00:00:00Z"

echo "All stories pass"
write_prd true "$SOURCE"
run_pr --dry-run
assert_exit "exits 0" 0
assert_contains "closes the issue" "Closes #12"
assert_not_contains "is not a draft" "--draft"
assert_contains "targets the origin repo explicitly" "-R example-owner/example-repo"
assert_contains "lists stories in priority order" "- [x] US-001: First story
- [x] US-002: Second story"
assert_contains "includes story notes" "Used the existing badge component."
assert_contains "would commit the state file" "Would commit: scripts/ralph/prd.json"
assert_not_contains "has no stale warning" "[!WARNING]"
# Count with tr: grep on Git Bash reads files in text mode and never sees \r
if [ "$(tr -cd '\r' < "$OUTPUT_FILE" | wc -c)" -gt 0 ]; then fail "output has no carriage returns"; else pass "output has no carriage returns"; fi

echo "One story incomplete"
write_prd false "$SOURCE"
run_pr --dry-run
assert_exit "exits 0" 0
assert_contains "references the issue" "Refs #12"
assert_not_contains "does not close the issue" "Closes #12"
assert_contains "is a draft" "--draft"
assert_contains "shows the incomplete story unchecked" "- [ ] US-002: Second story"

echo "Issue changed after prd.json was derived"
write_prd true "$SOURCE"
FAKE_GH_UPDATED_AT="2026-09-05T12:00:00Z" run_pr --dry-run
assert_contains "warns in the PR body" "[!WARNING]"
assert_contains "names the issue" "Issue #12 changed"

echo "No source in prd.json"
write_prd true null
run_pr --dry-run
assert_exit "exits 0" 0
assert_not_contains "has no Closes line" "Closes #"
assert_not_contains "has no Refs line" "Refs #"
run_pr --dry-run --issue 34
assert_contains "--issue supplies the number" "Closes #34"
run_pr --dry-run --issue abc
assert_exit "rejects a non-numeric issue" 1

echo "Guards"
write_prd true "$SOURCE"
echo "stray" > "$PROJECT/stray.txt"
run_pr --dry-run
assert_exit "refuses unrelated uncommitted changes" 1
assert_contains "names the offending file" "stray.txt"
rm "$PROJECT/stray.txt"
echo "main" > "$RALPH_DIR/.last-branch"
run_pr --dry-run
assert_exit "ignores .last-branch" 0
rm "$RALPH_DIR/.last-branch"
git -C "$PROJECT" checkout -q main
run_pr --dry-run
assert_exit "refuses the wrong branch" 1
assert_contains "explains the branch mismatch" "expects 'ralph/test-feature'"
git -C "$PROJECT" checkout -q ralph/test-feature

# patch_prd <jq filter>
patch_prd() {
  jq "$1" "$RALPH_DIR/prd.json" | tr -d '' > "$RALPH_DIR/prd.json.tmp"
  mv "$RALPH_DIR/prd.json.tmp" "$RALPH_DIR/prd.json"
}

count_calls() {
  grep -c -- "^$1" "$GH_LOG" || true
}

FOLLOWUPS='[
  {"id": "FU-001", "title": "Flaky date test", "body": "The date test fails around midnight.", "kind": "bug", "foundIn": "US-002", "evidence": "tests/date.test.ts:40", "issue": null},
  {"id": "FU-002", "title": "Old one", "body": "Already filed.", "kind": "debt", "issue": 40}
]'

echo "Blocked story, added story and follow-ups (dry run)"
write_prd false "$SOURCE"
patch_prd ".followUps = $FOLLOWUPS | .source.approvedStoryIds = [\"US-001\"] | (.userStories[] | select(.id == \"US-002\")) |= . + {blocked: true, blockedReason: \"STRIPE_KEY is not set\"}"
: > "$GH_LOG"
run_pr --dry-run
assert_exit "exits 0" 0
assert_contains "marks the blocked and unapproved story" "- [ ] US-002: Second story - **blocked** - _added during the loop, not approved by a human_"
assert_not_contains "leaves approved stories unmarked" "First story - _added"
assert_contains "has a blocked section" "## Blocked - needs a human"
assert_contains "gives the blocked reason" "STRIPE_KEY is not set"
assert_contains "is a draft" "--draft"
assert_contains "announces the follow-up it would file" "  Flaky date test"
assert_contains "lists the unfiled follow-up" "- Flaky date test (bug, found in US-002) - not filed"
assert_contains "lists the filed follow-up with its number" "- #40 Old one (debt)"
if [ "$(count_calls "issue create")" -eq 0 ]; then pass "files nothing in a dry run"; else fail "files nothing in a dry run"; fi
run_pr --dry-run --no-followups
assert_not_contains "--no-followups announces no filing" "Would file these follow-ups"

echo "Filing follow-ups (real run against a local remote)"
git init -q --bare "$WORK_DIR/remote.git"
BARE=$(cd "$WORK_DIR/remote.git" && { pwd -W 2>/dev/null || pwd; })
git -C "$PROJECT" config "url.$BARE.pushInsteadOf" "https://github.com/example-owner/example-repo.git"
write_prd true "$SOURCE"
patch_prd ".followUps = $FOLLOWUPS"
: > "$GH_LOG"
run_pr
assert_exit "exits 0" 0
if [ "$(jq '.followUps[0].issue' "$RALPH_DIR/prd.json" | tr -d '')" = "1" ]; then pass "records the issue number in prd.json"; else fail "records the issue number in prd.json"; fi
if grep -qF -- "issue create -R example-owner/example-repo --title Flaky date test" "$GH_LOG"; then pass "files in the origin repo explicitly"; else fail "files in the origin repo explicitly"; fi
if grep -F -- "issue create" "$GH_LOG" | grep -qF -- "--label"; then fail "adds no label the repo does not have"; else pass "adds no label the repo does not have"; fi
if grep -qF "while working on #12 (story US-002)" "$GH_BODY_DIR/issue-1.md" && grep -qF "tests/date.test.ts:40" "$GH_BODY_DIR/issue-1.md"; then pass "issue body names the origin and the evidence"; else fail "issue body names the origin and the evidence"; fi
if grep -qF -- "- #1 Flaky date test" "$GH_BODY_DIR/pr.md"; then pass "PR body links the new issue"; else fail "PR body links the new issue"; fi
if [ -z "$(git -C "$PROJECT" status --porcelain)" ]; then pass "commits prd.json with the number"; else fail "commits prd.json with the number"; fi
if [ "$(git -C "$WORK_DIR/remote.git" rev-parse refs/heads/ralph/test-feature)" = "$(git -C "$PROJECT" rev-parse HEAD)" ]; then pass "pushes the branch"; else fail "pushes the branch"; fi
run_pr
if [ "$(count_calls "issue create")" -eq 1 ]; then pass "does not file the same follow-up twice"; else fail "does not file the same follow-up twice"; fi

patch_prd '.followUps += [{"id": "FU-003", "title": "Second finding", "body": "x", "issue": null}]'
: > "$GH_LOG"
FAKE_GH_ISSUE_FAIL=1 run_pr
assert_exit "a failed filing does not stop the PR" 0
assert_contains "warns about the failed filing" "Could not file follow-up 'Second finding'"
if [ "$(jq '.followUps[2].issue' "$RALPH_DIR/prd.json" | tr -d '')" = "null" ]; then pass "keeps the follow-up for a retry"; else fail "keeps the follow-up for a retry"; fi
: > "$GH_LOG"
run_pr --no-followups
if [ "$(count_calls "issue create")" -eq 0 ]; then pass "--no-followups files nothing"; else fail "--no-followups files nothing"; fi
FAKE_GH_LABELS="ralph-followup" run_pr
if grep -F -- "issue create" "$GH_LOG" | grep -qF -- "--label ralph-followup"; then pass "adds the label when the repo has it"; else fail "adds the label when the repo has it"; fi

echo "Remote URL forms"
SCRIPT_DIR="$RALPH_DIR"
source "$REPO_DIR/ralph-lib.sh"
check_slug() {
  git -C "$PROJECT" remote set-url origin "$1"
  OUTPUT=$(ralph_repo_slug origin)
  if [ "$OUTPUT" = "$2" ]; then pass "$1"; else fail "$1 (got '$OUTPUT', expected '$2')"; fi
}
check_slug "https://github.com/owner/repo.git" "owner/repo"
check_slug "https://github.com/owner/repo" "owner/repo"
check_slug "git@github.com:owner/repo.git" "owner/repo"
check_slug "ssh://git@github.com/owner/repo.git" "owner/repo"
check_slug "https://ghe.example.com/owner/repo.git" "ghe.example.com/owner/repo"
check_slug "/some/local/path" ""

echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
