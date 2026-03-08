---
name: turing-coding-orchestrator
description: >
  Launch coding agents on GitHub issues with automatic tmux session management,
  completion notifications via structured callbacks, and persistent context
  tracking via MEMORY.md. Supports parallel multi-agent execution with git
  worktrees. Use when user says: "fix issue", "start coding agent", "code this",
  "background task", or any request to have an AI agent write code autonomously.
user-invocable: true
---

# Turing Coding Orchestrator

> Unified skill that combines tmux session management, structured Callback
> notifications, and MEMORY.md context persistence into a single deterministic
> pipeline. One sentence in → PR out.

-----

## Overview

This skill orchestrates autonomous coding agents through six layers:

1. **Setup** — Fetch issue, create branch & worktree, initialize MEMORY.md
2. **Launch** — Start tmux session, inject agent with structured callback
3. **Observation** — Zero-token monitoring via capture-pane + milestone detection
4. **Callback** — Structured JSON completion events that drive deterministic routing
5. **Action** — Test verification, PR creation, user notification
6. **Recovery** — Detect orphaned sessions, resume or clean up on restart

-----

## Constants & Paths

```
ORCHESTRATOR_DIR     = .clawdbot
ACTIVE_TASKS_FILE   = .clawdbot/active-tasks.json
MEMORY_FILE          = MEMORY.md
DAILY_MEMORY_DIR     = memory/
TMUX_SOCKET          = /tmp/openclaw-tmux/openclaw.sock
WATCHDOG_INTERVAL    = 300        # seconds (5 minutes)
STALL_TIMEOUT        = 1800       # seconds (30 minutes)
SCRIPTS_DIR          = skills/turing-coding-orchestrator/scripts
```

-----

## Layer 1: Setup

### Trigger

User provides a task. The task can be:
- A GitHub issue reference: `fix issue #78`, `resolve #78`
- A free-text instruction: `add pagination to /api/users`
- Multiple issues: `fix #78 #79 #80`

### Procedure

For each task unit:

1. **Parse the task**
   - If issue reference → run `gh issue view <number> --json title,body,labels,assignees`
   - Extract title, description, acceptance criteria
   - Generate a `task_id` (e.g., `issue-78` or `task-<short-hash>`)

2. **Create branch**
   ```bash
   BRANCH="fix/${task_id}"
   git checkout -b "$BRANCH" origin/main
   ```

3. **Create git worktree** (for parallel execution)
   ```bash
   WORKTREE_DIR="../worktrees/${task_id}"
   git worktree add "$WORKTREE_DIR" "$BRANCH"
   ```

4. **Initialize MEMORY.md entry**
   Append to `MEMORY.md` under `## In-Flight Tasks`:
   ```markdown
   ### ${task_id}: ${title}
   - **Status**: pending
   - **Branch**: ${BRANCH}
   - **Session**: ${task_id}
   - **Agent**: Claude Code
   - **Started**: ${ISO_TIMESTAMP}
   - **Latest Milestone**: Initializing
   - **Callback Injected**: no
   ```

5. **Initialize active-tasks.json**
   ```bash
   scripts/setup.sh "$task_id" "$BRANCH" "$WORKTREE_DIR" "$ISSUE_BODY"
   ```

### Error Handling

- If `gh` is not installed → tell user to install GitHub CLI
- If issue does not exist → report and skip
- If branch already exists → reuse it (warn user)
- If worktree creation fails → fall back to same-directory checkout

-----

## Layer 2: Launch

### Procedure

1. **Ensure tmux socket directory**
   ```bash
   mkdir -p /tmp/openclaw-tmux
   ```

2. **Create tmux session**
   ```bash
   tmux -S "$TMUX_SOCKET" new-session -d -s "$task_id" -c "$WORKTREE_DIR"
   ```

3. **Compose agent prompt with structured callback**
   The agent receives:
   - The issue/task description
   - Repository context (README, key config files)
   - Explicit callback instruction:

   ```
   When you complete this task, you MUST output the following JSON block
   on a line by itself, wrapped in triple backticks with language tag
   "callback-json":

   ```callback-json
   {
     "task_id": "${task_id}",
     "status": "completed|failed|need_clarification",
     "branch": "${BRANCH}",
     "files_changed": ["list", "of", "files"],
     "test_results": { "passed": 0, "failed": 0, "skipped": 0 },
     "duration_minutes": 0,
     "summary": "Brief description of what was done"
   }
   ```

   This is MANDATORY. Do not skip the callback block.
   ```

4. **Send prompt to agent via tmux**
   ```bash
   scripts/launch.sh "$task_id" "$WORKTREE_DIR" "$PROMPT_FILE"
   ```

5. **Register in active-tasks.json**
   ```json
   {
     "tasks": [
       {
         "task_id": "issue-78",
         "session": "issue-78",
         "branch": "fix/issue-78",
         "worktree": "../worktrees/issue-78",
         "started_at": "2026-03-06T14:30:00Z",
         "status": "running",
         "pid": 12345
       }
     ]
   }
   ```

6. **Update MEMORY.md**
   - Set status to `in-progress`
   - Set `Callback Injected: yes`

-----

## Layer 3: Observation

### Zero-Token Monitoring

The watchdog runs as a background process (cron or loop) with **zero LLM token
consumption**. It uses only shell commands:

```bash
# Capture last 50 lines of agent output
tmux -S "$TMUX_SOCKET" capture-pane -p -t "$task_id" -S -50
```

### Milestone Detection

The watchdog scans captured output for patterns:

| Pattern                          | Milestone Label            |
|----------------------------------|----------------------------|
| `creating file`                  | Creating files             |
| `running tests`, `npm test`      | Running tests              |
| `test.*passed`, `✓`             | Tests passing              |
| `test.*failed`, `✗`             | Tests failing              |
| `git add`, `git commit`          | Committing changes         |
| `callback-json`                  | Agent completed (callback) |
| `error`, `Error`, `FATAL`        | Error detected             |

### Milestone Persistence

When a milestone is detected, write to `memory/YYYY-MM-DD.md`:
```markdown
- **${HH:MM}** [${task_id}] ${milestone_label}
```

And update MEMORY.md:
```markdown
- **Latest Milestone**: ${HH:MM} - ${milestone_label}
```

### Script

```bash
scripts/watchdog.sh
```

Runs in a loop with `WATCHDOG_INTERVAL` sleep between iterations.

-----

## Layer 4: Callback

### Structured Callback Processing

When the watchdog detects `callback-json` in the captured pane output:

1. **Extract the JSON block** from the captured output
2. **Parse and validate** the JSON structure
3. **Route by status**:

| `status`              | Action                                                       |
|-----------------------|--------------------------------------------------------------|
| `completed` + 0 fails | → Proceed to Layer 5 (Action): create PR                     |
| `completed` + fails>0 | → Send agent instruction: "fix failing tests"                |
| `failed`              | → Update MEMORY.md, notify user with error details           |
| `need_clarification`  | → Forward the `summary` field to user via notification       |

4. **Update active-tasks.json** with callback data
5. **Update MEMORY.md** with final status

### Callback JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["task_id", "status", "branch", "files_changed", "test_results", "summary"],
  "properties": {
    "task_id": { "type": "string" },
    "status": { "enum": ["completed", "failed", "need_clarification"] },
    "branch": { "type": "string" },
    "files_changed": {
      "type": "array",
      "items": { "type": "string" }
    },
    "test_results": {
      "type": "object",
      "properties": {
        "passed": { "type": "integer" },
        "failed": { "type": "integer" },
        "skipped": { "type": "integer" }
      }
    },
    "duration_minutes": { "type": "number" },
    "summary": { "type": "string" }
  }
}
```

-----

## Layer 5: Action

### PR Creation

When callback indicates success (`completed` + 0 failures):

1. **Verify tests pass** (independent verification)
   ```bash
   cd "$WORKTREE_DIR"
   # Auto-detect test runner
   if [ -f package.json ]; then npm test
   elif [ -f Makefile ]; then make test
   elif [ -f pytest.ini ] || [ -d tests ]; then pytest
   elif [ -f go.mod ]; then go test ./...
   fi
   ```

2. **Create PR**
   ```bash
   gh pr create \
     --title "fix: ${issue_title}" \
     --body "Closes #${issue_number}

   ## Summary
   ${callback.summary}

   ## Changes
   ${callback.files_changed formatted as list}

   ## Test Results
   ✅ ${callback.test_results.passed} passed
   ❌ ${callback.test_results.failed} failed
   ⏭️  ${callback.test_results.skipped} skipped

   ---
   *Automated by turing-coding-orchestrator*" \
     --base main \
     --head "$BRANCH"
   ```

3. **Notify user**
   ```
   openclaw system event --mode now "issue #78 的 PR 已创建，改了 3 个文件，单测全过"
   ```

4. **Update MEMORY.md**
   - Set status to `completed`
   - Add PR number and link

### Approval Gate (Optional)

If the workflow includes a Lobster approval gate:
- Pause before PR creation
- Notify user: "Agent completed issue #78. Create PR? [yes/no]"
- Wait for explicit approval

-----

## Layer 6: Recovery

### On Startup

When the orchestrator skill is invoked, **always** run recovery first:

1. **Read active-tasks.json**
   - For each task with `status: "running"`:
     a. Check if tmux session exists: `tmux -S "$TMUX_SOCKET" has-session -t "$task_id"`
     b. If session alive → report status to user
     c. If session dead → mark as `crashed` in MEMORY.md, notify user

2. **Read MEMORY.md**
   - Find tasks marked `in-progress` that are NOT in active-tasks.json
   - These are orphaned entries → mark as `unknown` and notify user

3. **Offer recovery options**
   For crashed tasks:
   - **Retry**: Re-launch agent in new tmux session on same branch
   - **Abandon**: Clean up worktree, mark task as `abandoned`
   - **Resume**: Attach to existing session (if alive but stalled)

### Cleanup

When a task is completed or abandoned:
```bash
# Remove worktree
git worktree remove "$WORKTREE_DIR" --force

# Remove from active-tasks.json
jq "del(.tasks[] | select(.task_id == \"$task_id\"))" active-tasks.json > tmp && mv tmp active-tasks.json

# Keep MEMORY.md entry (for history)
```

-----

## Usage Modes

### Mode A: Full Automation (Elvis Mode)

User says:
```
fix issue #78 #79 #80, ping me when done
```

Orchestrator:
1. Runs Setup for all 3 issues in parallel (3 worktrees, 3 branches)
2. Launches 3 tmux sessions with 3 agents
3. Watchdog monitors all 3
4. As each completes → callback → PR → accumulate
5. When all done → single notification: "3 PRs created, please review"

### Mode B: Human-in-the-Loop (steipete Mode)

User says:
```
start an agent session for API refactoring
```

Orchestrator:
1. Creates tmux session + worktree
2. Launches agent in REPL mode (no auto-PR)
3. Reports: "Session `api-refactor` is running. You can send instructions."

User can then:
- `tell api-refactor to start with interface definitions`
  → `tmux send-keys -t api-refactor "..." Enter`
- `how is api-refactor doing?`
  → `tmux capture-pane` → summarize last 10 lines
- `api-refactor is done, create a PR`
  → Manual PR creation flow

-----

## Important Notes

### Memory Flush

For long-running tasks that approach the context window limit, the orchestrator
ensures task state is preserved by writing to MEMORY.md BEFORE compaction
occurs. The watchdog's milestone detection serves as continuous state
persistence — even if the main session is compacted, MEMORY.md retains the
full task history.

### Multi-Agent Conflict Detection

When running multiple agents in parallel:
- Each agent works in its own git worktree (isolated file system)
- Before PR creation, check for file conflicts between branches:
  ```bash
  git diff --name-only main..branch-a > /tmp/files-a
  git diff --name-only main..branch-b > /tmp/files-b
  comm -12 <(sort /tmp/files-a) <(sort /tmp/files-b)
  ```
- If conflicts detected → notify user before creating PRs

### Security

- Never pass secrets or tokens through tmux send-keys
- Agent prompts should not include API keys or credentials
- Watchdog captures are stored in memory/ directory — add to .gitignore
- active-tasks.json may contain PIDs — add to .gitignore

-----

## Quick Reference

| Command                                    | What it does                        |
|--------------------------------------------|-------------------------------------|
| `fix issue #78`                            | Full automation for single issue    |
| `fix #78 #79 #80, ping me when done`      | Parallel multi-issue automation     |
| `start agent session for X`               | Human-in-the-loop mode              |
| `tell <session> to do Y`                  | Send instruction to running agent   |
| `how is <session> doing?`                 | Check agent progress                |
| `status`                                   | List all active tasks               |
| `stop <session>`                           | Kill agent session, keep worktree   |
| `cleanup <session>`                        | Remove session + worktree           |
| `retry <task_id>`                          | Re-launch crashed task              |
