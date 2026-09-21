#!/bin/bash
# Tests for ralph-pr.sh --dry-run. Runs offline: gh is replaced by a stub.
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

# Stub gh: answers "issue view" with $FAKE_GH_UPDATED_AT, fails on anything else
STUB_DIR="$WORK_DIR/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo "${FAKE_GH_UPDATED_AT:-}"
  exit 0
fi
echo "gh stub: unexpected call: $*" >&2
exit 1
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
