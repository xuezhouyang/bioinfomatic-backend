#!/usr/bin/env bash
# =============================================================================
# Layer C: OBSERVE — Universal zero-token monitoring for ALL task types
# =============================================================================
# Usage: watchdog.sh [task_id]
#   If task_id is provided, monitor only that task.
#   If omitted, monitor ALL running tasks in active-tasks.json.
# =============================================================================
# ZERO LLM tokens consumed. All monitoring via shell commands only.
# =============================================================================

set -euo pipefail

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

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-300}"   # 5 minutes
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"          # 30 minutes
CAPTURE_LINES=50

SINGLE_TASK="${1:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    echo "[watchdog $(date -u +%H:%M:%S)] $*"
}

daily_file() {
    local d
    d="$(date -u +%Y-%m-%d)"
    local f="${DAILY_MEMORY_DIR}/${d}.md"
    if ! [ -f "$f" ]; then
        mkdir -p "$DAILY_MEMORY_DIR"
        printf '# %s\n\n' "$d" > "$f"
    fi
    echo "$f"
}

write_milestone() {
    local task_id="$1"
    local milestone="$2"
    local t
    t="$(date -u +%H:%M)"
    echo "- **${t}** [${task_id}] ${milestone}" >> "$(daily_file)"

    if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
        sed -i "/### ${task_id}:/,/^### / {
            s|- \*\*Latest Milestone\*\*:.*|- **Latest Milestone**: ${t} - ${milestone}|
        }" "$MEMORY_FILE"
    fi
    log "${task_id}: ${milestone}"
}

update_task_status() {
    local task_id="$1" new_status="$2"
    if command -v jq &>/dev/null && [ -f "$ACTIVE_TASKS_FILE" ]; then
        local tmp; tmp=$(mktemp)
        jq --arg tid "$task_id" --arg st "$new_status" \
            '(.tasks[] | select(.task_id == $tid)).status = $st' \
            "$ACTIVE_TASKS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_TASKS_FILE"
    fi
    if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
        sed -i "/### ${task_id}:/,/^### / {
            s|- \*\*Status\*\*:.*|- **Status**: ${new_status}|
        }" "$MEMORY_FILE"
    fi
}

extract_callback_json() {
    echo "$1" | sed -n '/```callback-json/,/```/{/```/d;p}'
}

# ---------------------------------------------------------------------------
# Milestone detection — universal patterns for all task types
# ---------------------------------------------------------------------------
detect_milestones() {
    local task_id="$1" captured="$2"

    # Highest priority: callback completion
    if echo "$captured" | grep -q 'callback-json'; then
        write_milestone "$task_id" "Callback detected"
        handle_callback "$task_id" "$captured"
        return 0  # Task completed
    fi

    # Universal coding patterns
    local found=false

    # File operations
    if echo "$captured" | grep -qi 'creating file\|wrote file\|created.*\.\|write.*file\|new file'; then
        write_milestone "$task_id" "Creating/writing files"
        found=true
    fi

    # Testing
    if echo "$captured" | grep -qi 'running tests\|npm test\|pytest\|go test\|make test\|cargo test\|jest\|mocha\|rspec\|junit'; then
        write_milestone "$task_id" "Running tests"
        found=true
    fi
    if echo "$captured" | grep -qi 'tests\? passed\|✓\|PASS\|All tests passed\|tests ok'; then
        write_milestone "$task_id" "Tests passing"
        found=true
    fi
    if echo "$captured" | grep -qi 'tests\? failed\|✗\|FAIL\|AssertionError\|test.*error'; then
        write_milestone "$task_id" "Tests failing"
        found=true
    fi

    # Git operations
    if echo "$captured" | grep -qi 'git add\|git commit\|committed\|changes committed'; then
        write_milestone "$task_id" "Committing changes"
        found=true
    fi
    if echo "$captured" | grep -qi 'git push\|pushed to'; then
        write_milestone "$task_id" "Pushing changes"
        found=true
    fi

    # Build/compile
    if echo "$captured" | grep -qi 'compiling\|building\|compiled\|build succeeded\|build complete'; then
        write_milestone "$task_id" "Building/compiling"
        found=true
    fi

    # Code review patterns
    if echo "$captured" | grep -qi 'LGTM\|approved\|changes requested\|review complete'; then
        write_milestone "$task_id" "Review complete"
        found=true
    fi

    # Exploration patterns
    if echo "$captured" | grep -qi 'Summary:\|Conclusion:\|Answer:\|Findings:\|Analysis:'; then
        write_milestone "$task_id" "Analysis/report ready"
        found=true
    fi

    # Errors (lower priority — don't overwrite more specific milestones)
    if ! $found && echo "$captured" | grep -qi 'error\|Error\|FATAL\|panic\|traceback\|Traceback\|Exception'; then
        write_milestone "$task_id" "Error detected"
    fi

    return 1  # Still running
}

# ---------------------------------------------------------------------------
# Callback handling — delegates to complete.sh for action execution
# ---------------------------------------------------------------------------
handle_callback() {
    local task_id="$1" captured="$2"

    local callback_json
    callback_json="$(extract_callback_json "$captured")"

    if [ -z "$callback_json" ]; then
        log "${task_id}: callback tag found but could not extract JSON"
        return
    fi

    if ! echo "$callback_json" | jq empty 2>/dev/null; then
        log "${task_id}: invalid callback JSON"
        write_milestone "$task_id" "Invalid callback JSON"
        return
    fi

    local status summary
    status=$(echo "$callback_json" | jq -r '.status // "unknown"')
    summary=$(echo "$callback_json" | jq -r '.summary // "No summary"')

    log "${task_id}: callback — status=${status}"

    # Save callback file
    echo "$callback_json" > "${ORCHESTRATOR_DIR}/${task_id}-callback.json"

    # Delegate to complete.sh for task-specific actions
    local complete_script="${SCRIPTS_DIR}/complete.sh"
    if [ -f "$complete_script" ] && [ -x "$complete_script" ]; then
        "$complete_script" --task-id "$task_id" \
            --callback-file "${ORCHESTRATOR_DIR}/${task_id}-callback.json" || {
            log "${task_id}: complete.sh returned non-zero"
        }
    else
        # Fallback: basic notification
        log "${task_id}: complete.sh not found. Basic notification only."
        update_task_status "$task_id" "$status"
        write_milestone "$task_id" "${status}: ${summary}"
        if command -v openclaw &>/dev/null; then
            echo "Task ${task_id} ${status}: ${summary}" | \
                openclaw system event --mode now 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Stall detection
# ---------------------------------------------------------------------------
check_stall() {
    local task_id="$1" started_at="$2"

    local now; now=$(date +%s)
    local started_epoch
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo 0)
    [ "$started_epoch" -eq 0 ] && return

    local elapsed=$(( now - started_epoch ))
    if [ "$elapsed" -gt "$STALL_TIMEOUT" ]; then
        local last
        last=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t "$task_id" -S -1 2>/dev/null || echo "")
        if [ -z "$last" ]; then
            write_milestone "$task_id" "WARNING: Possible stall (${STALL_TIMEOUT}s no output)"
            if command -v openclaw &>/dev/null; then
                echo "Task ${task_id} may be stalled" | \
                    openclaw system event --mode now 2>/dev/null || true
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Recovery (Layer 6) — run on startup
# ---------------------------------------------------------------------------
run_recovery() {
    log "Running recovery check..."
    [ -f "$ACTIVE_TASKS_FILE" ] || return
    command -v jq &>/dev/null || return

    local task_ids
    task_ids=$(jq -r '.tasks[] | select(.status == "running") | .task_id' "$ACTIVE_TASKS_FILE")

    for tid in $task_ids; do
        if tmux -S "$TMUX_SOCKET" has-session -t "$tid" 2>/dev/null; then
            log "Recovery: '${tid}' — alive"
        else
            log "Recovery: '${tid}' — DEAD"
            update_task_status "$tid" "crashed"
            write_milestone "$tid" "Session crashed (detected on startup)"
            if command -v openclaw &>/dev/null; then
                echo "Task ${tid} crashed — session gone" | \
                    openclaw system event --mode now 2>/dev/null || true
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Monitor a single task
# ---------------------------------------------------------------------------
monitor_task() {
    local task_id="$1"

    if ! tmux -S "$TMUX_SOCKET" has-session -t "$task_id" 2>/dev/null; then
        log "${task_id}: session not found"
        update_task_status "$task_id" "crashed"
        write_milestone "$task_id" "Session crashed (not found)"
        return 0  # Stop monitoring
    fi

    local captured
    captured=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t "$task_id" -S -"$CAPTURE_LINES" 2>/dev/null || echo "")

    if [ -z "$captured" ]; then
        log "${task_id}: empty capture"
        return 1
    fi

    # Strip ANSI
    captured=$(echo "$captured" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null || echo "$captured")

    if detect_milestones "$task_id" "$captured"; then
        return 0  # Completed
    fi

    # Stall check
    if command -v jq &>/dev/null && [ -f "$ACTIVE_TASKS_FILE" ]; then
        local sa
        sa=$(jq -r --arg tid "$task_id" \
            '.tasks[] | select(.task_id == $tid) | .launched_at // .started_at // ""' \
            "$ACTIVE_TASKS_FILE")
        [ -n "$sa" ] && check_stall "$task_id" "$sa"
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Monitor all running tasks
# ---------------------------------------------------------------------------
monitor_all() {
    [ -f "$ACTIVE_TASKS_FILE" ] && command -v jq &>/dev/null || return

    local ids
    ids=$(jq -r '.tasks[] | select(.status == "running") | .task_id' "$ACTIVE_TASKS_FILE")
    [ -z "$ids" ] && { log "No running tasks."; return; }

    for tid in $ids; do
        monitor_task "$tid" || true
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "Watchdog started (universal)."
    log "  Socket:   ${TMUX_SOCKET}"
    log "  Interval: ${WATCHDOG_INTERVAL}s"
    log "  Stall:    ${STALL_TIMEOUT}s"
    log "  Mode:     $([ -n "$SINGLE_TASK" ] && echo "single (${SINGLE_TASK})" || echo "all tasks")"

    run_recovery

    while true; do
        if [ -n "$SINGLE_TASK" ]; then
            if monitor_task "$SINGLE_TASK"; then
                log "'${SINGLE_TASK}' completed/crashed. Exiting."
                break
            fi
        else
            monitor_all
        fi
        sleep "$WATCHDOG_INTERVAL"
    done

    log "Watchdog stopped."
}

main
