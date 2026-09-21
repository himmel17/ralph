# Ralph

[日本語](README.ja.md)

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Amp](https://ampcode.com) or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Amp CLI](https://ampcode.com) (default)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project
- Optional: [GitHub CLI](https://cli.github.com) (`gh`) installed and authenticated, for the [GitHub Issue workflow](#github-issue-workflow-optional)

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the prompt template for your AI tool of choice:
cp /path/to/ralph/prompt.md scripts/ralph/prompt.md    # For Amp
# OR
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code

chmod +x scripts/ralph/ralph.sh

# Optional: GitHub Issue workflow (all three files are needed)
cp /path/to/ralph/ralph-safe.sh /path/to/ralph/ralph-pr.sh /path/to/ralph/ralph-lib.sh scripts/ralph/
chmod +x scripts/ralph/ralph-safe.sh scripts/ralph/ralph-pr.sh
```

### Option 2: Install skills globally (Amp)

Copy the skills to your Amp or Claude config for use across all projects:

For AMP
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
cp -r skills/ralph-issue ~/.config/amp/skills/
```

For Claude Code (manual)
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
cp -r skills/ralph-issue ~/.claude/skills/
```

### Option 3: Use as Claude Code Marketplace

Add this fork's marketplace to Claude Code:

```bash
/plugin marketplace add himmel17/ralph
```

Use this fork, not `snarktank/ralph`: the upstream marketplace does not include the `ralph-issue` skill. Both marketplaces are named `ralph-marketplace`, and Claude Code keeps one marketplace per name, so adding this one replaces an upstream registration.

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format
- `/ralph-issue` - Convert a GitHub Issue to prd.json format

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"
- "convert issue to prd.json", "run ralph on issue #12"

The plugin installs the skills only. `ralph.sh`, `ralph-safe.sh`, `ralph-pr.sh` and `ralph-lib.sh` still have to be copied into your project as in Option 1.

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Using Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]
```

Default is 10 iterations. Use `--tool amp` or `--tool claude` to select your AI coding tool.

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `progress.txt`
8. Repeat until all stories pass or max iterations reached

## GitHub Issue Workflow (Optional)

Use this when your requirements live in GitHub Issues. The loop itself never talks to GitHub: the issue is read before the loop, and the pull request is opened after it, by you.

**One issue = one `prd.json` = one branch = one PR.** The issue describes a feature. The user stories it is split into exist only in `prd.json`; do not create one issue per story.

### 1. Write the issue

The issue body is the requirements document. You can write it with the PRD skill and post it:

```bash
gh issue create --title "Task Priority System" --body-file tasks/prd-task-priority.md
```

### 2. Convert the issue to prd.json

```
Load the ralph-issue skill and convert issue #12 to prd.json
```

The skill reads the issue, applies the same rules as the `ralph` skill, shows you the story split for approval, and records the origin in `prd.json`:

```json
"source": {
  "type": "github-issue",
  "issue": 12,
  "url": "https://github.com/OWNER/REPO/issues/12",
  "issueUpdatedAt": "2026-09-01T12:34:56Z",
  "approvedStoryIds": ["US-001", "US-002"]
}
```

`prd.json` is a snapshot. If the issue's requirements change, convert it again instead of editing `prd.json` by hand. `ralph-safe.sh` and `ralph-pr.sh` warn when the issue changed after conversion (comments and label changes also trigger the warning).

### 3. Run the loop with GitHub access disabled

```bash
./scripts/ralph/ralph-safe.sh --tool claude [max_iterations]
```

`ralph-safe.sh` takes the same arguments as `ralph.sh`. While the loop runs, `gh` is logged out (an empty `GH_CONFIG_DIR`) and the push URL of `origin` is set to `DISABLED`. Both are restored when the loop ends; if the script is killed, the next run restores the push URL first. Set `RALPH_REMOTE` to protect a remote other than `origin`.

This guards against accidents. It is not a sandbox: an agent running without permission checks could undo it.

#### Problems the agent finds while you are away

Nobody watches the loop, so the agent records what it finds in `prd.json` (the rules are in `CLAUDE.md` and `prompt.md`):

| What it finds | What the agent does | What happens next |
|---|---|---|
| The issue cannot be finished without it | Adds or splits a story, with the reason in `notes` | The PR marks every story that is not in `source.approvedStoryIds` |
| Anything outside the issue (a bug, tech debt, an idea) | Does not fix it; appends it to `followUps` | `ralph-pr.sh` files it as a new issue |
| A story it cannot finish itself | Sets `blocked` and `blockedReason` on the story | The loop stops |

#### When the loop stops early

`ralph-safe.sh` runs `ralph.sh` one iteration at a time and reads `prd.json` in between, so it does not depend on what the agent says:

```bash
echo $?   # 0 done, 1 max iterations, 2 blocked, 3 no progress, 4 guard
```

- **2 - blocked:** a story has `blocked: true`. The loop stops at the first one, because later stories usually build on it. The reason is printed and goes into the draft PR.
- **3 - no progress:** no new story passed for 3 iterations in a row (`RALPH_STALL_LIMIT`). This also catches a tool that fails to start, such as a rate limit.
- **4 - guard:** `prd.json` became unreadable, its `source` changed, or more than 3 stories were added (`RALPH_MAX_ADDED_STORIES`).

To resume after a block: if the cause was the environment (a missing credential), fix it, remove `blocked` from the story, and run `ralph-safe.sh` again. If the requirements were wrong, fix the issue and convert it again; the skill keeps the finished stories. `ralph-safe.sh` refuses to start while a story is blocked.

Running `ralph.sh` directly gives you none of these stops.

### 4. Review locally, then open the PR

Until you push, a bad run costs nothing: reset the branch and run again. When the result looks right:

```bash
./scripts/ralph/ralph-pr.sh --dry-run   # Print the PR body and the commands, change nothing
./scripts/ralph/ralph-pr.sh             # Commit leftover Ralph state, push, open the PR
```

- All stories pass: a regular PR with `Closes #12`.
- Some stories still fail: a **draft** PR with `Refs #12`, so merging it cannot close the issue.
- A PR for the branch is already open: only its body is updated.
- `prd.json` has no `source`: pass `--issue 12`, or omit it to open a PR that references no issue.
- `prd.json` has `followUps`: each one is filed as a new issue first, and its number is written back to `prd.json`, so running again files nothing twice. They get the label `ralph-followup` if the repository has it (`RALPH_FOLLOWUP_LABEL`). Check them with `--dry-run`, skip them with `--no-followups`. A failed filing (issues disabled, for example) does not stop the PR.

The PR body lists every story with its status and notes, marks blocked stories and stories added during the loop, and links the follow-ups. `ralph-pr.sh` refuses to run on the wrong branch or with uncommitted changes other than `prd.json` and `progress.txt`.

### 5. Merge it yourself

Nothing in Ralph merges. Story status is reported by the agent itself, so review the PR like any other. GitHub closes the issue when a PR with `Closes #12` is merged into the **default branch**; opening the PR, or merging it elsewhere, does not.

Keep issues small. Every story lands in one PR, and the loop does not pick up changes made to the default branch while it runs.

### Windows

Run the scripts through Git Bash: `bash scripts/ralph/ralph-safe.sh --tool claude 10`. Native Windows builds of `jq` write CRLF line endings; the scripts strip them.

### Tests

```bash
bash tests/test-ralph-pr.sh
bash tests/test-ralph-safe.sh
```

The tests run in a temporary repository with a stub `gh`, a stub `ralph.sh` and a local bare remote, so they need no network access.

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop that spawns fresh AI instances (supports `--tool amp` or `--tool claude`) |
| `prompt.md` | Prompt template for Amp |
| `CLAUDE.md` | Prompt template for Claude Code |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON (works with Amp and Claude Code) |
| `skills/ralph-issue/` | Skill for converting a GitHub Issue to JSON |
| `ralph-safe.sh` | Runs `ralph.sh` with `gh` logged out and pushing disabled |
| `ralph-pr.sh` | Pushes the branch and opens the PR from `prd.json` after the loop |
| `ralph-lib.sh` | Helpers shared by `ralph-safe.sh` and `ralph-pr.sh` |
| `tests/` | Offline tests for `ralph-pr.sh` and `ralph-safe.sh` |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Amp or Claude Code) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See which stories are done
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## Customizing the Prompt

After copying `prompt.md` (for Amp) or `CLAUDE.md` (for Claude Code) to your project, customize it for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
