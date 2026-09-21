# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Amp or Claude Code) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Amp (default)
./ralph.sh [max_iterations]

# Run Ralph with Claude Code
./ralph.sh --tool claude [max_iterations]
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh AI instances (supports `--tool amp` or `--tool claude`)
- `prompt.md` - Instructions given to each AMP instance
-  `CLAUDE.md` - Instructions given to each Claude Code instance
- `prd.json.example` - Example PRD format
- `ralph-safe.sh` - Runs `ralph.sh` one iteration at a time with `gh` logged out and pushing disabled; stops on a blocked story, on no progress, and on its prd.json guards
- `ralph-pr.sh` - Files `followUps` as issues, pushes the branch and opens the PR from `prd.json` after the loop (never merges)
- `ralph-lib.sh` - Helpers shared by `ralph-safe.sh` and `ralph-pr.sh`
- `skills/ralph-issue/` - Skill that converts a GitHub Issue to `prd.json`
- `tests/test-ralph-pr.sh` - Offline tests for `ralph-pr.sh` (`bash tests/test-ralph-pr.sh`)
- `tests/test-ralph-safe.sh` - Offline tests for the stop conditions of `ralph-safe.sh`, using a stub `ralph.sh`
- `README.ja.md` - Japanese translation of `README.md`
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh AI instance (Amp or Claude Code) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
- `README.md` is the source of truth; when you change it, update `README.ja.md` to match (same sections, same order)
- Stop conditions and PR content are decided from `prd.json` with `jq`, never from what the agent says; the agent only records (`blocked`, `followUps`, added stories)
- The loop never talks to GitHub: issues are read before it (`ralph-issue` skill) and PRs are opened after it (`ralph-pr.sh`)
- Read `jq` output through `ralph_jq` in `ralph-lib.sh`: native Windows `jq` emits CRLF, and on Git Bash both `$(...)` and `grep` hide the `\r`, so check for it with `tr -cd '\r' | wc -c`
