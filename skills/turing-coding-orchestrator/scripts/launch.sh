#!/usr/bin/env bash
# =============================================================================
# Layer B: EXECUTE — Universal agent launch with PTY via tmux
# =============================================================================
# Usage: launch.sh --task-id ID --type TYPE --workdir DIR --prompt FILE [opts]
#
# Options:
#   --task-id ID       Task identifier
#   --type TYPE        Task type (determines prompt template)
#   --workdir DIR      Working directory for the agent
#   --prompt FILE      Path to prompt file (or use --description for auto-gen)
#   --description DESC Auto-generate prompt from description + template
#   --agent CMD        Override agent command (claude|openclaw|aider|codex|gemini)
#   --background       Don't start watchdog (for interactive sessions)
#   --interactive      Launch agent in interactive/REPL mode
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TASK_ID=""
TASK_TYPE=""
WORKDIR=""
PROMPT_FILE=""
DESCRIPTION=""
AGENT_OVERRIDE=""
BACKGROUND=false
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)     TASK_ID="$2"; shift 2 ;;
        --type)        TASK_TYPE="$2"; shift 2 ;;
        --workdir)     WORKDIR="$2"; shift 2 ;;
        --prompt)      PROMPT_FILE="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --agent)       AGENT_OVERRIDE="$2"; shift 2 ;;
        --background)  BACKGROUND=true; shift ;;
        --interactive) INTERACTIVE=true; shift ;;
        *) echo "[launch] Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$TASK_ID" ] || [ -z "$TASK_TYPE" ]; then
    echo "Usage: launch.sh --task-id ID --type TYPE --workdir DIR [--prompt FILE|--description DESC]"
    exit 1
fi

[ -z "$WORKDIR" ] && WORKDIR="$(pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TMUX_SOCKET="/tmp/openclaw-tmux/openclaw.sock"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCHESTRATOR_DIR="${REPO_ROOT}/.clawdbot"
ACTIVE_TASKS_FILE="${ORCHESTRATOR_DIR}/active-tasks.json"
MEMORY_FILE="${REPO_ROOT}/MEMORY.md"
DAILY_MEMORY_DIR="${REPO_ROOT}/memory"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="${SCRIPTS_DIR}/templates"
DATE_TODAY="$(date -u +%Y-%m-%d)"
TIME_NOW="$(date -u +%H:%M)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$TMUX_SOCKET")"
mkdir -p "$ORCHESTRATOR_DIR"

# ---------------------------------------------------------------------------
# 1. Build prompt from template if no prompt file given
# ---------------------------------------------------------------------------
if [ -z "$PROMPT_FILE" ] && [ -n "$DESCRIPTION" ]; then
    PROMPT_FILE=$(mktemp)
    TEMPLATE_FILE="${TEMPLATES_DIR}/${TASK_TYPE}.md"
    CALLBACK_TEMPLATE="${TEMPLATES_DIR}/_callback.md"
    CONTEXT_DIR="${ORCHESTRATOR_DIR}/${TASK_ID}-context"

    # Start with template header if available
    if [ -f "$TEMPLATE_FILE" ]; then
        # Substitute variables in template
        sed -e "s|\${TASK_ID}|${TASK_ID}|g" \
            -e "s|\${TASK_TYPE}|${TASK_TYPE}|g" \
            -e "s|\${DESCRIPTION}|${DESCRIPTION}|g" \
            -e "s|\${WORKDIR}|${WORKDIR}|g" \
            "$TEMPLATE_FILE" > "$PROMPT_FILE"
    else
        # Generic prompt
        cat > "$PROMPT_FILE" <<GENERIC
# Task: ${DESCRIPTION}

You are an autonomous coding agent. Complete the following task:

${DESCRIPTION}

## Working Directory
${WORKDIR}

## Guidelines
- Read the codebase first to understand the context
- Make minimal, focused changes
- Follow existing code conventions
- Test your changes when applicable
GENERIC
    fi

    # Append issue/PR context if available
    if [ -f "${CONTEXT_DIR}/issue.json" ]; then
        echo "" >> "$PROMPT_FILE"
        echo "## GitHub Issue Context" >> "$PROMPT_FILE"
        echo '```json' >> "$PROMPT_FILE"
        cat "${CONTEXT_DIR}/issue.json" >> "$PROMPT_FILE"
        echo '```' >> "$PROMPT_FILE"
    fi

    if [ -f "${CONTEXT_DIR}/pr.json" ]; then
        echo "" >> "$PROMPT_FILE"
        echo "## Pull Request Context" >> "$PROMPT_FILE"
        echo '```json' >> "$PROMPT_FILE"
        cat "${CONTEXT_DIR}/pr.json" >> "$PROMPT_FILE"
        echo '```' >> "$PROMPT_FILE"
    fi

    if [ -f "${CONTEXT_DIR}/pr.diff" ]; then
        echo "" >> "$PROMPT_FILE"
        echo "## PR Diff" >> "$PROMPT_FILE"
        echo '```diff' >> "$PROMPT_FILE"
        head -500 "${CONTEXT_DIR}/pr.diff" >> "$PROMPT_FILE"  # Limit diff size
        echo '```' >> "$PROMPT_FILE"
    fi

    # Append callback contract (universal)
    if [ -f "$CALLBACK_TEMPLATE" ]; then
        echo "" >> "$PROMPT_FILE"
        sed -e "s|\${TASK_ID}|${TASK_ID}|g" \
            -e "s|\${TASK_TYPE}|${TASK_TYPE}|g" \
            "$CALLBACK_TEMPLATE" >> "$PROMPT_FILE"
    else
        # Inline callback contract
        cat >> "$PROMPT_FILE" <<CALLBACK

## Completion Callback (MANDATORY)

When you finish this task, output the following JSON block on a line by itself:

\`\`\`callback-json
{
  "task_id": "${TASK_ID}",
  "task_type": "${TASK_TYPE}",
  "status": "completed",
  "branch": "$(cd "$WORKDIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'none')",
  "files_changed": [],
  "files_read": [],
  "test_results": { "passed": 0, "failed": 0, "skipped": 0, "runner": "" },
  "duration_minutes": 0,
  "summary": "Brief description of what was done",
  "next_steps": []
}
\`\`\`

### Status values:
- **completed**: Task fully done
- **failed**: Could not complete (explain in summary)
- **need_clarification**: Blocked on user input (explain in summary)
- **partial**: Made progress but not done yet (explain in summary)

### Rules:
1. Fill in ALL applicable fields accurately
2. The callback JSON must be valid JSON
3. Do NOT skip the callback — it is how the system knows you are done
CALLBACK
    fi

    echo "[launch] Generated prompt from template ($(wc -l < "$PROMPT_FILE") lines)."
elif [ -z "$PROMPT_FILE" ]; then
    echo "[launch] ERROR: Must provide --prompt FILE or --description DESC"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Select agent
# ---------------------------------------------------------------------------
AGENT_CMD=""
AGENT_NAME=""

if [ -n "$AGENT_OVERRIDE" ]; then
    case "$AGENT_OVERRIDE" in
        claude)   AGENT_CMD="claude --print"; AGENT_NAME="claude" ;;
        openclaw) AGENT_CMD="openclaw"; AGENT_NAME="openclaw" ;;
        aider)    AGENT_CMD="aider"; AGENT_NAME="aider" ;;
        codex)    AGENT_CMD="codex"; AGENT_NAME="codex" ;;
        gemini)   AGENT_CMD="gemini"; AGENT_NAME="gemini" ;;
        *)        AGENT_CMD="$AGENT_OVERRIDE"; AGENT_NAME="custom" ;;
    esac
else
    # Auto-select based on task type and available agents
    case "$TASK_TYPE" in
        review|explore)
            # Prefer lighter agents for read-only tasks
            if command -v gemini &>/dev/null; then
                AGENT_CMD="gemini"; AGENT_NAME="gemini"
            elif command -v claude &>/dev/null; then
                AGENT_CMD="claude --print"; AGENT_NAME="claude"
            elif command -v openclaw &>/dev/null; then
                AGENT_CMD="openclaw"; AGENT_NAME="openclaw"
            fi
            ;;
        *)
            # Prefer heavier agents for write tasks
            if command -v claude &>/dev/null; then
                AGENT_CMD="claude --print"; AGENT_NAME="claude"
            elif command -v openclaw &>/dev/null; then
                AGENT_CMD="openclaw"; AGENT_NAME="openclaw"
            elif command -v aider &>/dev/null; then
                AGENT_CMD="aider"; AGENT_NAME="aider"
            elif command -v codex &>/dev/null; then
                AGENT_CMD="codex"; AGENT_NAME="codex"
            fi
            ;;
    esac
fi

if [ -z "$AGENT_CMD" ]; then
    echo "[launch] WARNING: No coding agent found."
    AGENT_NAME="manual"
fi

echo "[launch] Agent selected: ${AGENT_NAME}"

# ---------------------------------------------------------------------------
# 3. Create tmux session with PTY
# ---------------------------------------------------------------------------
if tmux -S "$TMUX_SOCKET" has-session -t "$TASK_ID" 2>/dev/null; then
    echo "[launch] Session '${TASK_ID}' exists. Killing and re-creating."
    tmux -S "$TMUX_SOCKET" kill-session -t "$TASK_ID"
fi

tmux -S "$TMUX_SOCKET" new-session -d -s "$TASK_ID" -c "$WORKDIR"
echo "[launch] Created tmux session '${TASK_ID}' (PTY enabled, workdir: ${WORKDIR})."

# ---------------------------------------------------------------------------
# 4. Launch agent in session
# ---------------------------------------------------------------------------
if $INTERACTIVE; then
    # Interactive mode: launch agent in REPL, don't pipe prompt
    if [ -n "$AGENT_CMD" ] && [ "$AGENT_NAME" != "manual" ]; then
        tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" "$AGENT_CMD" Enter
        echo "[launch] Agent started in interactive/REPL mode."
    else
        echo "[launch] Session ready for manual agent startup."
    fi
elif [ -n "$AGENT_CMD" ] && [ "$AGENT_NAME" != "manual" ]; then
    # Save prompt file to persistent location
    SAVED_PROMPT="${ORCHESTRATOR_DIR}/${TASK_ID}-prompt.md"
    cp "$PROMPT_FILE" "$SAVED_PROMPT"

    # Send agent command with prompt
    tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" \
        "${AGENT_CMD} < '${SAVED_PROMPT}'" Enter
    echo "[launch] Agent launched with prompt."
else
    SAVED_PROMPT="${ORCHESTRATOR_DIR}/${TASK_ID}-prompt.md"
    cp "$PROMPT_FILE" "$SAVED_PROMPT"
    tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" "cat '${SAVED_PROMPT}'" Enter
    echo "[launch] Prompt displayed in session (no agent auto-detected)."
fi

# Record pane PID
PANE_PID=$(tmux -S "$TMUX_SOCKET" display-message -t "$TASK_ID" -p '#{pane_pid}' 2>/dev/null || echo "unknown")

# ---------------------------------------------------------------------------
# 5. Update active-tasks.json
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null && [ -f "$ACTIVE_TASKS_FILE" ]; then
    TEMP_FILE=$(mktemp)
    jq --arg tid "$TASK_ID" \
       --arg ts "$TIMESTAMP" \
       --arg pid "$PANE_PID" \
       --arg ag "$AGENT_NAME" \
       '(.tasks[] | select(.task_id == $tid)) |= . + {
           "status": "running",
           "launched_at": $ts,
           "pid": ($pid | tonumber? // $pid),
           "agent": $ag
       }' "$ACTIVE_TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$ACTIVE_TASKS_FILE"
fi

# ---------------------------------------------------------------------------
# 6. Update MEMORY.md
# ---------------------------------------------------------------------------
if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
    sed -i "/### ${TASK_ID}:/,/^### / {
        s|- \*\*Status\*\*: pending|- **Status**: in-progress|
        s|- \*\*Agent\*\*: auto|- **Agent**: ${AGENT_NAME}|
        s|- \*\*Latest Milestone\*\*: Initializing|- **Latest Milestone**: ${TIME_NOW} - Agent launched|
    }" "$MEMORY_FILE"
fi

# ---------------------------------------------------------------------------
# 7. Write daily memory
# ---------------------------------------------------------------------------
DAILY_FILE="${DAILY_MEMORY_DIR}/${DATE_TODAY}.md"
if [ -f "$DAILY_FILE" ]; then
    echo "- **${TIME_NOW}** [${TASK_ID}] (${TASK_TYPE}) Agent '${AGENT_NAME}' launched (PID: ${PANE_PID})" >> "$DAILY_FILE"
fi

# ---------------------------------------------------------------------------
# 8. Start watchdog (unless interactive/background-disabled)
# ---------------------------------------------------------------------------
if ! $INTERACTIVE && ! $BACKGROUND; then
    WATCHDOG_SCRIPT="${SCRIPTS_DIR}/watchdog.sh"
    if [ -f "$WATCHDOG_SCRIPT" ] && [ -x "$WATCHDOG_SCRIPT" ]; then
        nohup "$WATCHDOG_SCRIPT" "$TASK_ID" > "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.log" 2>&1 &
        WATCHDOG_PID=$!
        echo "$WATCHDOG_PID" > "${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.pid"
        echo "[launch] Watchdog started (PID: ${WATCHDOG_PID})."
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "[launch] ✓ Launch complete."
echo "[launch]   Task:      ${TASK_ID} (${TASK_TYPE})"
echo "[launch]   Session:   tmux -S ${TMUX_SOCKET} attach -t ${TASK_ID}"
echo "[launch]   Agent:     ${AGENT_NAME}"
echo "[launch]   PID:       ${PANE_PID}"
echo "[launch]   Mode:      $($INTERACTIVE && echo "interactive" || echo "autonomous")"
