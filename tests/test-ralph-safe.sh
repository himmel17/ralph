#!/bin/bash
# Tests for the stop conditions of ralph-safe.sh. Runs offline: ralph.sh is
# replaced by a stub that edits prd.json the way an agent would, and gh by a
# stub that fails.
# Usage: bash tests/test-ralph-safe.sh

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

assert_exit() {
  if [ "$EXIT_CODE" -eq "$2" ]; then pass "$1"; else fail "$1 (exit $EXIT_CODE, expected $2)"; fi
}

assert_calls() {
  local calls
  calls=$(wc -l < "$RALPH_DIR/calls.log" | tr -d ' ')
  if [ "$calls" -eq "$2" ]; then pass "$1"; else fail "$1 ($calls iterations ran, expected $2)"; fi
}

STUB_DIR="$WORK_DIR/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

PROJECT="$WORK_DIR/project"
RALPH_DIR="$PROJECT/scripts/ralph"
mkdir -p "$RALPH_DIR"
cp "$REPO_DIR/ralph-safe.sh" "$REPO_DIR/ralph-lib.sh" "$RALPH_DIR/"

# Stub ralph.sh: on its Nth call it applies steps/N.jq to prd.json, records its
# arguments and the push URL it saw, and exits with steps/N.exit (default 1,
# which is what ralph.sh returns when its single iteration did not complete)
cat > "$RALPH_DIR/ralph.sh" << 'EOF'
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "$*|$(git -C "$DIR" remote get-url --push origin)|${GH_CONFIG_DIR:+isolated}" >> "$DIR/calls.log"
N=$(wc -l < "$DIR/calls.log" | tr -d ' ')
if [ -f "$DIR/steps/$N.jq" ]; then
  jq -f "$DIR/steps/$N.jq" "$DIR/prd.json" | tr -d '\r' > "$DIR/prd.json.tmp"
  mv "$DIR/prd.json.tmp" "$DIR/prd.json"
fi
if [ -f "$DIR/steps/$N.raw" ]; then
  cp "$DIR/steps/$N.raw" "$DIR/prd.json"
fi
if [ -f "$DIR/steps/$N.exit" ]; then
  exit "$(cat "$DIR/steps/$N.exit")"
fi
exit 1
EOF

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name "Ralph Test"
git -C "$PROJECT" config user.email "ralph-test@example.invalid"
git -C "$PROJECT" remote add origin https://github.com/example-owner/example-repo.git

# reset_case <approvedStoryIds JSON or null>: three failing stories, no steps
reset_case() {
  rm -rf "$RALPH_DIR/steps" "$RALPH_DIR/calls.log"
  mkdir -p "$RALPH_DIR/steps"
  : > "$RALPH_DIR/calls.log"
  cat > "$RALPH_DIR/prd.json" << EOF
{
  "project": "TestApp",
  "branchName": "ralph/test-feature",
  "description": "Test Feature",
  "source": {"type": "github-issue", "issue": 12, "approvedStoryIds": $1},
  "userStories": [
    {"id": "US-001", "title": "First story", "priority": 1, "passes": false, "notes": ""},
    {"id": "US-002", "title": "Second story", "priority": 2, "passes": false, "notes": ""},
    {"id": "US-003", "title": "Third story", "priority": 3, "passes": false, "notes": ""}
  ]
}
EOF
}

step() {
  echo "$2" > "$RALPH_DIR/steps/$1.jq"
}

pass_story() {
  step "$1" "(.userStories[] | select(.id == \"$2\") | .passes) = true"
}

run_safe() {
  OUTPUT=$(bash "$RALPH_DIR/ralph-safe.sh" "$@" 2>&1)
  EXIT_CODE=$?
}

APPROVED='["US-001", "US-002", "US-003"]'

echo "All stories pass"
reset_case "$APPROVED"
pass_story 1 US-001
pass_story 2 US-002
pass_story 3 US-003
echo 0 > "$RALPH_DIR/steps/3.exit"
run_safe --tool claude 10
assert_exit "exits 0" 0
assert_calls "stops after the last story" 3
if [ "$(head -1 "$RALPH_DIR/calls.log")" = "--tool claude 1|DISABLED|isolated" ]; then
  pass "runs ralph.sh one iteration at a time, isolated"
else
  fail "runs ralph.sh one iteration at a time, isolated (got: $(head -1 "$RALPH_DIR/calls.log"))"
fi
if [ "$(git -C "$PROJECT" remote get-url --push origin)" = "https://github.com/example-owner/example-repo.git" ]; then
  pass "restores the push URL"
else
  fail "restores the push URL"
fi

echo "A story becomes blocked"
reset_case "$APPROVED"
pass_story 1 US-001
step 2 '(.userStories[] | select(.id == "US-002")) |= . + {blocked: true, blockedReason: "STRIPE_KEY is not set"}'
pass_story 3 US-003
run_safe --tool claude 10
assert_exit "exits 2" 2
assert_calls "stops at the first blocked story" 2
assert_contains "names the story" "US-002: Second story"
assert_contains "prints the reason" "STRIPE_KEY is not set"
run_safe --tool claude 10
assert_exit "refuses to start while a story is blocked" 2
assert_calls "runs no further iteration" 2

echo "No progress"
reset_case "$APPROVED"
pass_story 1 US-001
run_safe --tool claude 10
assert_exit "exits 3" 3
assert_calls "stops after 3 iterations without a new pass" 4
reset_case "$APPROVED"
pass_story 1 US-001
step 2 '(.userStories[] | select(.id == "US-001") | .passes) = false'
pass_story 3 US-001
step 4 '(.userStories[] | select(.id == "US-001") | .passes) = false'
run_safe --tool claude 10
assert_exit "a story flipping between pass and fail is not progress" 3
assert_calls "stops the flip-flop" 4
reset_case "$APPROVED"
RALPH_STALL_LIMIT=1 run_safe --tool claude 10
assert_calls "RALPH_STALL_LIMIT changes the limit" 1

echo "Max iterations"
reset_case "$APPROVED"
pass_story 1 US-001
pass_story 2 US-002
run_safe 2
assert_exit "exits 1" 1
assert_calls "runs exactly max_iterations" 2

echo "False COMPLETE"
reset_case "$APPROVED"
echo 0 > "$RALPH_DIR/steps/1.exit"
pass_story 2 US-001
run_safe --tool claude 2
assert_contains "does not trust COMPLETE over prd.json" "reported COMPLETE but only 0 of 3"
assert_calls "keeps going" 2

echo "Guards"
reset_case "$APPROVED"
step 1 '.source.issue = 99'
run_safe --tool claude 10
assert_exit "stops when source changes" 4
assert_contains "explains the source change" 'changed the "source" field'
reset_case "$APPROVED"
step 1 '.userStories += [range(4; 8) | {id: "US-00\(.)", title: "Added \(.)", priority: ., passes: false}]'
run_safe --tool claude 10
assert_exit "stops when too many stories are added" 4
assert_contains "lists the added stories" "US-007: Added 7"
reset_case "$APPROVED"
step 1 '.userStories += [{id: "US-004", title: "Added", priority: 4, passes: false}] | (.userStories[] | select(.id == "US-001") | .passes) = true'
pass_story 2 US-002
pass_story 3 US-003
pass_story 4 US-004
run_safe --tool claude 10
assert_exit "allows a few added stories" 0
assert_calls "finishes the added story too" 4
reset_case "$APPROVED"
echo "{ not json" > "$RALPH_DIR/steps/1.raw"
run_safe --tool claude 10
assert_exit "stops when prd.json is corrupted" 4

echo "No approvedStoryIds"
reset_case null
step 1 '.userStories += [range(4; 8) | {id: "US-00\(.)", title: "Added \(.)", priority: ., passes: false}]'
run_safe --tool claude 10
assert_exit "falls back to the stories present at startup" 4

echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
