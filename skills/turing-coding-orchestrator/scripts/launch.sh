#!/usr/bin/env bash
# =============================================================================
# Layer 2: Launch — Create tmux session, inject agent with structured callback
# =============================================================================
# Usage: launch.sh <task_id> <worktree_dir> <prompt_file>
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TASK_ID="${1:?Usage: launch.sh <task_id> <worktree_dir> <prompt_file>}"
WORKTREE_DIR="${2:?Usage: launch.sh <task_id> <worktree_dir> <prompt_file>}"
PROMPT_FILE="${3:?Usage: launch.sh <task_id> <worktree_dir> <prompt_file>}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TMUX_SOCKET="/tmp/openclaw-tmux/openclaw.sock"
REPO_ROOT="$(git rev-parse --show-toplevel)"
ORCHESTRATOR_DIR="${REPO_ROOT}/.clawdbot"
ACTIVE_TASKS_FILE="${ORCHESTRATOR_DIR}/active-tasks.json"
MEMORY_FILE="${REPO_ROOT}/MEMORY.md"
DAILY_MEMORY_DIR="${REPO_ROOT}/memory"
DATE_TODAY="$(date -u +%Y-%m-%d)"
TIME_NOW="$(date -u +%H:%M)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Ensure tmux socket directory exists
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$TMUX_SOCKET")"

# ---------------------------------------------------------------------------
# 1. Kill existing session if present (idempotent re-launch)
# ---------------------------------------------------------------------------
if tmux -S "$TMUX_SOCKET" has-session -t "$TASK_ID" 2>/dev/null; then
    echo "[launch] Session '${TASK_ID}' already exists. Killing and re-creating."
    tmux -S "$TMUX_SOCKET" kill-session -t "$TASK_ID"
fi

# ---------------------------------------------------------------------------
# 2. Create tmux session
# ---------------------------------------------------------------------------
tmux -S "$TMUX_SOCKET" new-session -d -s "$TASK_ID" -c "$WORKTREE_DIR"
echo "[launch] Created tmux session '${TASK_ID}' in '${WORKTREE_DIR}'."

# ---------------------------------------------------------------------------
# 3. Build the agent prompt with structured callback instruction
# ---------------------------------------------------------------------------
FULL_PROMPT_FILE=$(mktemp)

cat > "$FULL_PROMPT_FILE" <<PROMPT_HEADER
# Task Assignment

You are an autonomous coding agent. Complete the following task in this
repository. When finished, you MUST output a structured callback.

## Working Directory
$(realpath "$WORKTREE_DIR")

## Task Description
$(cat "$PROMPT_FILE")

## Structured Callback (MANDATORY)

When you complete this task, output the following JSON block on a line by
itself, wrapped in triple backticks with language tag "callback-json":

\`\`\`callback-json
{
  "task_id": "${TASK_ID}",
  "status": "completed",
  "branch": "$(cd "$WORKTREE_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')",
  "files_changed": ["list all files you modified"],
  "test_results": { "passed": 0, "failed": 0, "skipped": 0 },
  "duration_minutes": 0,
  "summary": "Brief description of what was done"
}
\`\`\`

### Callback Status Values
- **completed**: Task is done (fill in test_results and files_changed)
- **failed**: Task could not be completed (explain in summary)
- **need_clarification**: Task is blocked, need user input (explain in summary)

### Rules
1. Always commit your changes before outputting the callback
2. Run tests and report accurate test_results
3. The callback JSON must be valid JSON
4. Do not skip the callback — it is how the orchestrator knows you are done
PROMPT_HEADER

echo "[launch] Built agent prompt ($(wc -l < "$FULL_PROMPT_FILE") lines)."

# ---------------------------------------------------------------------------
# 4. Detect and launch the coding agent
# ---------------------------------------------------------------------------
AGENT_CMD=""

# Try to find a suitable agent
if command -v claude &>/dev/null; then
    AGENT_CMD="claude --print"
elif command -v openclaw &>/dev/null; then
    AGENT_CMD="openclaw"
elif command -v aider &>/dev/null; then
    AGENT_CMD="aider"
fi

if [ -z "$AGENT_CMD" ]; then
    echo "[launch] WARNING: No coding agent found (tried: claude, openclaw, aider)."
    echo "[launch] Sending prompt to tmux session for manual agent startup."
    # Just display the prompt in the session
    tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" "cat '${FULL_PROMPT_FILE}'" Enter
else
    echo "[launch] Launching agent: ${AGENT_CMD}"
    # Send agent command with prompt piped in
    tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" \
        "${AGENT_CMD} < '${FULL_PROMPT_FILE}'" Enter
fi

# Record the pane PID for monitoring
PANE_PID=$(tmux -S "$TMUX_SOCKET" display-message -t "$TASK_ID" -p '#{pane_pid}' 2>/dev/null || echo "unknown")

# ---------------------------------------------------------------------------
# 5. Update active-tasks.json — mark as running
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
    TEMP_FILE=$(mktemp)
    jq --arg tid "$TASK_ID" \
       --arg ts "$TIMESTAMP" \
       --arg pid "$PANE_PID" \
       '(.tasks[] | select(.task_id == $tid)) |= . + {
           "status": "running",
           "launched_at": $ts,
           "pid": ($pid | tonumber? // $pid)
       }' "$ACTIVE_TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$ACTIVE_TASKS_FILE"
elif command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$ACTIVE_TASKS_FILE', 'r') as f:
    data = json.load(f)
for t in data['tasks']:
    if t['task_id'] == '$TASK_ID':
        t['status'] = 'running'
        t['launched_at'] = '$TIMESTAMP'
        t['pid'] = '$PANE_PID'
with open('$ACTIVE_TASKS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
fi

# ---------------------------------------------------------------------------
# 6. Update MEMORY.md — mark as in-progress
# ---------------------------------------------------------------------------
if command -v sed &>/dev/null; then
    # Update status
    sed -i "s/\(### ${TASK_ID}:.*\)/\1/" "$MEMORY_FILE"
    sed -i "/### ${TASK_ID}:/,/^### / {
        s/- \*\*Status\*\*: pending/- **Status**: in-progress/
        s/- \*\*Callback Injected\*\*: no/- **Callback Injected**: yes/
        s/- \*\*Latest Milestone\*\*: Initializing/- **Latest Milestone**: ${TIME_NOW} - Agent launched/
    }" "$MEMORY_FILE"
fi

# ---------------------------------------------------------------------------
# 7. Write daily memory entry
# ---------------------------------------------------------------------------
DAILY_FILE="${DAILY_MEMORY_DIR}/${DATE_TODAY}.md"
if [ -f "$DAILY_FILE" ]; then
    echo "- **${TIME_NOW}** [${TASK_ID}] Agent launched in tmux session (PID: ${PANE_PID})" >> "$DAILY_FILE"
fi

# ---------------------------------------------------------------------------
# 8. Start watchdog in background
# ---------------------------------------------------------------------------
WATCHDOG_SCRIPT="${REPO_ROOT}/skills/turing-coding-orchestrator/scripts/watchdog.sh"
if [ -f "$WATCHDOG_SCRIPT" ] && [ -x "$WATCHDOG_SCRIPT" ]; then
    echo "[launch] Starting watchdog for task '${TASK_ID}'."
    nohup "$WATCHDOG_SCRIPT" "$TASK_ID" > "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.log" 2>&1 &
    WATCHDOG_PID=$!
    echo "$WATCHDOG_PID" > "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.pid"
    echo "[launch] Watchdog PID: ${WATCHDOG_PID}"
else
    echo "[launch] WARNING: Watchdog script not found or not executable at '${WATCHDOG_SCRIPT}'."
    echo "[launch] Run 'chmod +x ${WATCHDOG_SCRIPT}' to enable automatic monitoring."
fi

# ---------------------------------------------------------------------------
# Cleanup temp file (agent has already received it via tmux)
# ---------------------------------------------------------------------------
# Keep prompt file for debugging — clean up after task completes
mv "$FULL_PROMPT_FILE" "${ORCHESTRATOR_DIR}/${TASK_ID}-prompt.md"

# ---------------------------------------------------------------------------
echo ""
echo "[launch] ✓ Launch complete for task '${TASK_ID}'."
echo "[launch]   Session:   tmux -S ${TMUX_SOCKET} attach -t ${TASK_ID}"
echo "[launch]   Agent:     ${AGENT_CMD:-manual}"
echo "[launch]   PID:       ${PANE_PID}"
echo "[launch]   Watchdog:  $([ -f "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.pid" ] && cat "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.pid" || echo 'not started')"
