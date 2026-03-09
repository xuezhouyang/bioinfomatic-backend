---
name: turing-coding-orchestrator
description: >
  Universal coding orchestrator for ALL development scenarios. Manages autonomous
  coding agents with tmux sessions, structured callbacks, MEMORY.md persistence,
  and zero-token monitoring. Covers: issue fixing, feature building, refactoring,
  debugging, code review, exploration, prototyping, test writing, documentation,
  migration, multi-repo changes, and interactive REPL sessions. Use when user says
  anything about coding tasks, background agents, or autonomous development work.
user-invocable: true
---

# Turing Coding Orchestrator — Universal Edition

> One skill to orchestrate ALL coding scenarios. Not just "issue → PR"—any task
> that involves an agent writing, reading, reviewing, or exploring code.

-----

## Core Philosophy

Traditional orchestrators hardcode a single flow (issue → branch → agent → PR).
Real development is far more diverse. This skill treats **task type** as a
first-class concept and routes each scenario through the appropriate pipeline.

The three primitives remain the same:
1. **Session Management** — tmux sessions with PTY support
2. **Structured Callbacks** — JSON completion events for deterministic routing
3. **Memory Persistence** — MEMORY.md + daily logs survive compaction & restarts

But the **pipelines** are now pluggable.

-----

## Task Types & Routing

When a user request comes in, classify it into one of these task types:

| Task Type        | Trigger Phrases                                          | Creates Branch? | Creates PR? | Needs Tests? |
|------------------|----------------------------------------------------------|-----------------|-------------|--------------|
| `issue`          | "fix issue #N", "resolve #N"                             | yes             | yes         | yes          |
| `feature`        | "add X", "implement Y", "build Z"                       | yes             | yes         | yes          |
| `bugfix`         | "fix bug", "debug X", "this crashes when..."             | yes             | yes         | yes          |
| `refactor`       | "refactor X", "clean up Y", "extract Z"                  | yes             | yes         | yes          |
| `test`           | "write tests for X", "add test coverage"                 | yes             | yes         | N/A (is test) |
| `review`         | "review PR #N", "review this code", "code review"       | no              | no          | no           |
| `explore`        | "how does X work?", "explain Y", "find where Z happens"  | no              | no          | no           |
| `docs`           | "document X", "add README for Y", "write API docs"      | yes             | yes         | no           |
| `migrate`        | "migrate from X to Y", "upgrade Z", "rename A to B"     | yes             | yes         | yes          |
| `prototype`      | "try out X", "prototype Y", "spike on Z"                | optional        | no          | no           |
| `ops`            | "set up CI", "configure Docker", "deploy script"        | yes             | yes         | optional     |
| `interactive`    | "start a session", "open a REPL", "let me direct"       | optional        | optional    | optional     |
| `multi`          | "fix #1 #2 #3", "do A and B and C"                      | per-task        | per-task    | per-task     |

### Classification Rules

1. If user mentions an issue number → `issue`
2. If user mentions a PR number and "review" → `review`
3. If user says "explore/explain/how/find/where" → `explore`
4. If user says "test/coverage/spec" → `test`
5. If user says "refactor/clean/extract/move" → `refactor`
6. If user says "docs/document/README" → `docs`
7. If user says "migrate/upgrade/rename across" → `migrate`
8. If user says "prototype/spike/try" → `prototype`
9. If user says "session/REPL/direct" → `interactive`
10. If user lists multiple items → `multi` (decompose into sub-tasks)
11. If user says "CI/Docker/deploy/infra" → `ops`
12. If user describes a bug → `bugfix`
13. Default → `feature`

-----

## Architecture: Four Layers (Universal)

The old six-layer design was over-specified for issue→PR. The universal design
has four composable layers, each applicable to ANY task type:

```
┌─────────────────────────────────────────────────────┐
│  Layer A: PREPARE                                   │
│  Parse task → classify type → set up environment    │
│  (branch? worktree? same-dir? no-git?)              │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Layer B: EXECUTE                                   │
│  Launch agent in tmux (pty:true) with task-specific │
│  prompt template → inject callback contract         │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Layer C: OBSERVE                                   │
│  Zero-token watchdog → milestone detection →        │
│  MEMORY.md persistence → crash/stall alerts         │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│  Layer D: COMPLETE                                  │
│  Callback routing → task-specific completion action │
│  (PR? report? comments? notification? nothing?)     │
└─────────────────────────────────────────────────────┘
```

### Layer A: PREPARE

**What varies by task type:**

| Task Type     | Git Setup                      | Working Directory          | Context Gathered                        |
|---------------|-------------------------------|----------------------------|-----------------------------------------|
| `issue`       | branch + worktree             | worktree                   | `gh issue view` + repo README           |
| `feature`     | branch + worktree             | worktree                   | user description + repo structure       |
| `bugfix`      | branch + worktree             | worktree                   | error logs + relevant source files      |
| `refactor`    | branch + worktree             | worktree                   | target files + dependency graph         |
| `test`        | branch + worktree             | worktree                   | target source + existing test patterns  |
| `review`      | none (read-only)              | current dir                | PR diff + PR comments                   |
| `explore`     | none (read-only)              | current dir                | user question + repo structure          |
| `docs`        | branch + worktree             | worktree                   | source code + existing docs             |
| `migrate`     | branch + worktree             | worktree                   | old pattern examples + new pattern spec |
| `prototype`   | branch (no worktree) or temp  | branch or temp dir         | user idea + minimal context             |
| `ops`         | branch + worktree             | worktree                   | existing CI/infra + user requirements   |
| `interactive` | optional                      | user choice                | whatever user provides                  |

**Procedure:**

```bash
scripts/setup.sh \
  --task-id "$TASK_ID" \
  --type "$TASK_TYPE" \
  --description "$DESCRIPTION" \
  [--issue "$ISSUE_NUM"] \
  [--branch "$BRANCH"] \
  [--worktree] \
  [--workdir "$DIR"] \
  [--context-files "file1,file2,..."]
```

### Layer B: EXECUTE

**Agent Launch with PTY:**

Critical: coding agents (Claude Code, OpenClaw, Aider, Codex) are interactive
terminal applications. They MUST run with PTY enabled. This means:

```bash
# CORRECT: tmux provides PTY automatically
tmux new-session -d -s "$SESSION" -c "$WORKDIR"
tmux send-keys -t "$SESSION" "claude --print '$PROMPT'" Enter

# WRONG: no PTY
echo "$PROMPT" | claude --print  # Agent may hang or crash
```

**Prompt Templates by Task Type:**

Each task type has a specific prompt template that tells the agent:
1. What to do (task-specific)
2. What constraints apply (task-specific)
3. How to signal completion (universal callback)

Templates are in `scripts/templates/`:

```
scripts/templates/
├── issue.md          # Fix GitHub issue
├── feature.md        # Build new feature
├── bugfix.md         # Debug and fix bug
├── refactor.md       # Refactor code
├── test.md           # Write tests
├── review.md         # Review code/PR
├── explore.md        # Explore and explain
├── docs.md           # Write documentation
├── migrate.md        # Migration/upgrade
├── prototype.md      # Quick prototype
├── ops.md            # Infrastructure/DevOps
├── interactive.md    # REPL mode (minimal prompt)
└── _callback.md      # Universal callback contract (appended to all)
```

**Agent Selection:**

The orchestrator auto-detects available agents and selects the best one for the task:

| Agent         | Best For                           | Detection                     |
|---------------|------------------------------------|-------------------------------|
| Claude Code   | Complex multi-file tasks           | `command -v claude`           |
| OpenClaw      | Tasks requiring OpenClaw skills    | `command -v openclaw`         |
| Aider         | Focused single-file edits          | `command -v aider`            |
| Codex CLI     | Quick code generation              | `command -v codex`            |
| Gemini CLI    | Fast Q&A, large context            | `command -v gemini`           |
| Custom        | User-specified agent               | `--agent "$CMD"`              |

For `review` and `explore` tasks, prefer lighter agents (Gemini, Aider).
For `feature`, `migrate`, `refactor`, prefer heavier agents (Claude Code, OpenClaw).

**Launch:**

```bash
scripts/launch.sh \
  --task-id "$TASK_ID" \
  --type "$TASK_TYPE" \
  --workdir "$WORKDIR" \
  --prompt "$PROMPT_FILE" \
  [--agent "$AGENT_CMD"] \
  [--background] \
  [--interactive]
```

### Layer C: OBSERVE

Same zero-token watchdog for ALL task types. The watchdog doesn't care what kind
of task is running—it monitors the tmux session for universal signals:

**Universal Patterns (all task types):**

| Pattern                               | Milestone                |
|---------------------------------------|--------------------------|
| `callback-json`                       | Task completed           |
| `error`, `Error`, `FATAL`, `panic`    | Error detected           |
| Shell prompt idle > N minutes         | Possible stall           |
| Session dead                          | Crash                    |

**Task-Specific Patterns (optional enrichment):**

| Task Type | Additional Patterns                    | Milestone           |
|-----------|----------------------------------------|----------------------|
| any       | `git commit`, `committed`              | Code committed       |
| any       | `test`, `pytest`, `jest`, `go test`    | Running tests        |
| any       | `PASS`, `✓`, `passed`                 | Tests passing        |
| any       | `FAIL`, `✗`, `failed`                 | Tests failing        |
| review    | `LGTM`, `approved`, `changes requested`| Review complete     |
| explore   | `Summary:`, `Conclusion:`, `Answer:`   | Analysis complete   |

**Memory Persistence:**

Milestones are written to:
1. `memory/YYYY-MM-DD.md` — daily log (append-only)
2. `MEMORY.md` — latest milestone per task (updated in-place)

### Layer D: COMPLETE

**Completion Actions by Task Type:**

| Task Type     | On Success                                              | On Failure                        |
|---------------|--------------------------------------------------------|-----------------------------------|
| `issue`       | Run tests → create PR (closes #N) → notify             | Notify with error details         |
| `feature`     | Run tests → create PR → notify                         | Notify with error details         |
| `bugfix`      | Run tests → create PR → notify                         | Notify with error details         |
| `refactor`    | Run tests → create PR → notify                         | Notify with error details         |
| `test`        | Run new tests → create PR → notify                     | Notify with error details         |
| `review`      | Post review comments → notify                          | Notify incomplete review          |
| `explore`     | Format report → send to user → save to memory          | Notify with partial findings      |
| `docs`        | Create PR → notify                                     | Notify with error details         |
| `migrate`     | Run tests → conflict check → create PR → notify        | Notify with partial progress      |
| `prototype`   | Notify user "prototype ready in branch X"              | Notify with what was attempted    |
| `ops`         | Run validation → create PR → notify                    | Notify with error details         |
| `interactive` | Whatever user says                                     | Report last state                 |
| `multi`       | Aggregate all sub-task results → batch notification    | Report per-task status            |

-----

## Structured Callback (Universal)

The callback JSON is the same for ALL task types, but with type-specific fields:

```json
{
  "task_id": "issue-78",
  "task_type": "issue",
  "status": "completed|failed|need_clarification|partial",
  "branch": "fix/issue-78",
  "files_changed": ["src/handler.go", "src/handler_test.go"],
  "files_read": ["src/config.go"],
  "test_results": {
    "passed": 42,
    "failed": 0,
    "skipped": 1,
    "runner": "go test"
  },
  "review_result": {
    "verdict": "approved|changes_requested|commented",
    "comments": [{"file": "x.go", "line": 10, "body": "..."}]
  },
  "exploration_result": {
    "answer": "The auth flow works by...",
    "relevant_files": ["src/auth.go", "src/middleware.go"]
  },
  "duration_minutes": 12,
  "summary": "Implemented XXX, added 2 tests",
  "next_steps": ["Consider also updating the docs", "CI may need env var X"]
}
```

**Only populate the fields relevant to the task type.** The router ignores
fields it doesn't need.

### Callback Status Values

| Status              | Meaning                                              |
|---------------------|------------------------------------------------------|
| `completed`         | Task fully done, all checks pass                     |
| `failed`            | Task could not be completed                          |
| `need_clarification`| Blocked on user input                                |
| `partial`           | Made progress but not fully done (for long tasks)    |

### Callback Routing Logic

```
callback.status == "completed"
  AND task_type in (issue, feature, bugfix, refactor, test, docs, migrate, ops)
  AND callback.test_results.failed == 0
  → Create PR + notify

callback.status == "completed"
  AND callback.test_results.failed > 0
  → Tell agent: "fix failing tests, send new callback"

callback.status == "completed"
  AND task_type == "review"
  → Post review comments + notify

callback.status == "completed"
  AND task_type == "explore"
  → Format exploration_result + send to user

callback.status == "completed"
  AND task_type == "prototype"
  → Notify: "prototype ready on branch X"

callback.status == "partial"
  → Update MEMORY.md with progress, keep monitoring

callback.status == "failed"
  → Update MEMORY.md, notify user with summary

callback.status == "need_clarification"
  → Forward summary to user, pause task
```

-----

## MEMORY.md Format (Universal)

```markdown
# Project Memory

## In-Flight Tasks

### task-abc: Add pagination to /api/users
- **Type**: feature
- **Status**: in-progress
- **Branch**: feat/pagination
- **Session**: task-abc
- **Agent**: Claude Code
- **Started**: 2026-03-06T14:30:00Z
- **Latest Milestone**: 14:42 - Running tests
- **Completion Action**: create-pr

### review-pr-45: Review authentication changes
- **Type**: review
- **Status**: in-progress
- **Branch**: (none — read-only)
- **Session**: review-pr-45
- **Agent**: Gemini CLI
- **Started**: 2026-03-06T14:35:00Z
- **Latest Milestone**: 14:38 - Reviewing src/auth.go
- **Completion Action**: post-comments

## Completed Tasks

### issue-78: Fix NPE in user handler
- **Type**: issue
- **Status**: completed
- **PR**: #234 (merged)
- **Duration**: 12 min
- **Summary**: Added null check, 2 new tests
```

-----

## active-tasks.json Schema

```json
{
  "tasks": [
    {
      "task_id": "issue-78",
      "task_type": "issue",
      "session": "issue-78",
      "branch": "fix/issue-78",
      "worktree": "../worktrees/issue-78",
      "workdir": "/path/to/worktree",
      "agent": "claude",
      "started_at": "2026-03-06T14:30:00Z",
      "launched_at": "2026-03-06T14:30:05Z",
      "status": "running",
      "pid": 12345,
      "completion_action": "create-pr",
      "issue_number": 78,
      "pr_number": null,
      "description": "Fix NPE in user handler"
    }
  ]
}
```

-----

## Usage Modes

### Mode A: Full Automation (Fire-and-Forget)

```
User: fix issue #78, ping me when done
→ type=issue, completion=create-pr+notify

User: add rate limiting to the API, make a PR
→ type=feature, completion=create-pr+notify

User: write tests for src/auth/, create PR
→ type=test, completion=create-pr+notify

User: review PR #45, post your comments
→ type=review, completion=post-comments+notify

User: fix #78 #79 #80, all at once
→ type=multi, spawns 3 parallel agents

User: migrate all callbacks from v1 to v2 format
→ type=migrate, completion=create-pr+notify
```

### Mode B: Human-in-the-Loop (Interactive)

```
User: start a session for API refactoring
→ type=interactive, no auto-completion

User: tell api-refactor to focus on the handler layer first
→ tmux send-keys to session

User: how's api-refactor doing?
→ capture-pane + summarize

User: api-refactor is done, make a PR
→ manual trigger of PR creation
```

### Mode C: Research / Exploration (No Git Changes)

```
User: how does the authentication flow work?
→ type=explore, agent reads code, returns report

User: find all places we use deprecated API v1
→ type=explore, agent greps + analyzes, returns list

User: explain the data pipeline architecture
→ type=explore, agent reads + diagrams, returns explanation
```

-----

## Scripts

| Script               | Purpose                                              |
|----------------------|------------------------------------------------------|
| `scripts/setup.sh`   | Universal environment setup (branch, worktree, memory)|
| `scripts/launch.sh`  | Universal agent launch (tmux + PTY + prompt + callback)|
| `scripts/watchdog.sh` | Universal monitoring (zero-token, all task types)    |
| `scripts/router.sh`  | Task classification + pipeline selection             |
| `scripts/complete.sh` | Task-specific completion actions (PR, comments, etc) |

-----

## Prompt Templates

Located in `scripts/templates/`. Each template:
1. Sets the agent's role and goal for the task type
2. Provides task-specific constraints
3. Includes the universal callback contract (from `_callback.md`)

The callback contract is ALWAYS appended, regardless of task type.

-----

## Recovery (On Startup)

1. Read `active-tasks.json` — check each `running` task's tmux session
2. Read `MEMORY.md` — find orphaned entries
3. For dead sessions: mark `crashed`, notify user, offer retry
4. For alive sessions: report status, continue monitoring

-----

## Integration with Other Skills

This orchestrator does NOT replace individual skills. It **delegates** to them:

| Scenario              | Delegation                                       |
|-----------------------|--------------------------------------------------|
| Need Codex for a task | `--agent codex` flag to launch.sh                |
| Need Gemini for Q&A   | `--agent gemini` flag to launch.sh               |
| Existing coding-agent | Can wrap coding-agent's tmux launch              |
| tmux skill            | Used as underlying transport layer               |
| oh-my-opencode roles  | Can adopt role-based prompts into templates       |

The key value is **orchestration**, not reimplementing what already exists.

-----

## Quick Reference

| Command                                          | What it does                          |
|--------------------------------------------------|---------------------------------------|
| `fix issue #78`                                  | Issue → agent → PR (full auto)        |
| `add pagination to /api/users`                   | Feature → agent → PR (full auto)      |
| `refactor the auth module`                       | Refactor → agent → PR (full auto)     |
| `write tests for src/handler.go`                 | Test → agent → PR (full auto)         |
| `review PR #45`                                  | Review → agent → comments             |
| `how does auth work in this repo?`               | Explore → agent → report              |
| `prototype a WebSocket endpoint`                 | Prototype → agent → branch            |
| `document the API endpoints`                     | Docs → agent → PR                     |
| `migrate from REST to gRPC`                      | Migrate → agent → PR                  |
| `fix #78 #79 #80 in parallel`                    | Multi → 3 parallel agents → 3 PRs    |
| `start session for backend work`                 | Interactive → REPL mode               |
| `tell <session> do X`                            | Send instruction to running agent     |
| `status`                                         | List all active tasks                 |
| `how is <session> doing?`                        | Capture + summarize progress          |
| `stop <session>`                                 | Kill session, keep branch             |
| `retry <task>`                                   | Re-launch crashed/failed task         |

-----

## Security Notes

- Never pass secrets through tmux send-keys
- Agent prompts must not include API keys
- Watchdog captures stored in `memory/` — added to .gitignore
- `active-tasks.json` contains PIDs — added to .gitignore
- Read-only tasks (review, explore) should not modify files
