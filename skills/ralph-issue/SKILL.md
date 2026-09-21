---
name: ralph-issue
description: "Convert a GitHub Issue into prd.json for the Ralph autonomous agent system. Use when the requirements live in a GitHub Issue and you want to run Ralph on them. Triggers on: convert issue to prd.json, ralph from issue, run ralph on issue #N, create prd.json from this issue."
user-invocable: true
---

# Ralph Issue Converter

Converts one GitHub Issue into the `prd.json` that Ralph uses, and records which issue it came from.

**One issue = one prd.json = one branch = one PR.** The issue describes a feature; the user stories you split it into are an implementation detail that lives only in `prd.json`. Do not create one issue per story.

---

## The Job

1. Fetch the issue with `gh`
2. Convert it to `prd.json` using the rules of the `ralph` skill
3. Add the `source` field
4. Show the stories to the user and wait for approval
5. Save `prd.json` in the ralph directory

**Important:** Never edit, comment on, label or close the issue. This skill only reads from GitHub.

---

## Step 1: Fetch the Issue

Work out `OWNER/REPO` from the push remote and pass it explicitly. Inside a fork, `gh` may otherwise resolve to the parent repository.

```bash
git remote get-url origin
gh issue view <N> -R <OWNER/REPO> --json number,title,body,url,updatedAt,comments
```

The issue body is the requirements document. Read the comments too: if they change or narrow the requirements, follow the latest agreed version and tell the user which comment you relied on.

If the body is too vague to split into verifiable stories, stop and say what is missing. Do not invent requirements. Suggest the `prd` skill to write a proper PRD, which the user can paste into the issue.

---

## Step 2: Convert

Load the `ralph` skill and apply **all** of its rules: story size, dependency ordering, verifiable acceptance criteria, the conversion rules, and archiving a previous run. This skill adds to those rules and does not replace them.

---

## Step 3: Add the `source` Field

Add `source` at the top level of `prd.json`, copying `number`, `url` and `updatedAt` exactly as `gh` returned them:

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature description from the issue title/intro]",
  "source": {
    "type": "github-issue",
    "issue": 123,
    "url": "https://github.com/OWNER/REPO/issues/123",
    "issueUpdatedAt": "2026-09-01T12:34:56Z"
  },
  "userStories": []
}
```

- `issue` tells `ralph-pr.sh` which issue the PR closes.
- `issueUpdatedAt` lets `ralph-safe.sh` and `ralph-pr.sh` warn when the issue changed after conversion. Copy the value verbatim; do not use the current time.

`prd.json` is a snapshot. If the issue's requirements change later, convert again instead of patching `prd.json` by hand.

---

## Step 4: Get Approval

How the issue is split decides whether the loop succeeds, so a human checks it. Before saving, show:

- The branch name
- Each story: id, title, and acceptance criteria
- Anything in the issue you left out, and why

Save only after the user approves.

---

## Keep Issues Small

Every story of the issue lands in one PR that a human reviews. If the issue needs more than about 8 stories, tell the user and suggest splitting the issue before converting it.

---

## After Saving

Tell the user the next steps:

```bash
./scripts/ralph/ralph-safe.sh --tool claude [max_iterations]   # run the loop with GitHub access disabled
./scripts/ralph/ralph-pr.sh --dry-run                          # preview the PR
./scripts/ralph/ralph-pr.sh                                    # push and open the PR
```

---

## Checklist Before Saving

- [ ] Every item of the `ralph` skill's checklist holds
- [ ] `source.issue`, `source.url` and `source.issueUpdatedAt` are copied verbatim from `gh`
- [ ] The issue was not modified
- [ ] The user approved the story split
