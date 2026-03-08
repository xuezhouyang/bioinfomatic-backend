#!/usr/bin/env bash
# =============================================================================
# Layer 3 + Layer 6: Watchdog — Observation, crash detection, and recovery
# =============================================================================
# Usage: watchdog.sh [task_id]
#   If task_id is provided, monitor only that task.
#   If omitted, monitor ALL tasks in active-tasks.json.
# =============================================================================
# This script uses ZERO LLM tokens. All monitoring is done via shell commands.
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

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-300}"   # 5 minutes
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"          # 30 minutes
CAPTURE_LINES=50                                # Lines to capture from pane

SINGLE_TASK="${1:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    echo "[watchdog $(date -u +%H:%M:%S)] $*"
}

daily_file() {
    local date_today
    date_today="$(date -u +%Y-%m-%d)"
    local fpath="${DAILY_MEMORY_DIR}/${date_today}.md"
    if ! [ -f "$fpath" ]; then
        mkdir -p "$DAILY_MEMORY_DIR"
        echo "# ${date_today}" > "$fpath"
        echo "" >> "$fpath"
    fi
    echo "$fpath"
}

write_milestone() {
    local task_id="$1"
    local milestone="$2"
    local time_now
    time_now="$(date -u +%H:%M)"
    local df
    df="$(daily_file)"

    # Append to daily memory
    echo "- **${time_now}** [${task_id}] ${milestone}" >> "$df"

    # Update MEMORY.md latest milestone
    if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
        sed -i "/### ${task_id}:/,/^### / {
            s|- \*\*Latest Milestone\*\*:.*|- **Latest Milestone**: ${time_now} - ${milestone}|
        }" "$MEMORY_FILE"
    fi

    log "${task_id}: milestone — ${milestone}"
}

update_task_status() {
    local task_id="$1"
    local new_status="$2"

    # Update active-tasks.json
    if command -v jq &>/dev/null && [ -f "$ACTIVE_TASKS_FILE" ]; then
        local tmp
        tmp=$(mktemp)
        jq --arg tid "$task_id" --arg st "$new_status" \
            '(.tasks[] | select(.task_id == $tid)).status = $st' \
            "$ACTIVE_TASKS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_TASKS_FILE"
    fi

    # Update MEMORY.md
    if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
        sed -i "/### ${task_id}:/,/^### / {
            s|- \*\*Status\*\*:.*|- **Status**: ${new_status}|
        }" "$MEMORY_FILE"
    fi
}

extract_callback_json() {
    local captured="$1"
    # Extract JSON between ```callback-json and ```
    echo "$captured" | sed -n '/```callback-json/,/```/{/```/d;p}'
}

detect_milestones() {
    local task_id="$1"
    local captured="$2"

    # Check for callback completion (highest priority)
    if echo "$captured" | grep -q 'callback-json'; then
        write_milestone "$task_id" "Agent completed (callback detected)"
        handle_callback "$task_id" "$captured"
        return 0  # Signal: task completed
    fi

    # Pattern-based milestone detection
    if echo "$captured" | grep -qi 'creating file\|wrote file\|created.*\.'; then
        write_milestone "$task_id" "Creating files"
    fi
    if echo "$captured" | grep -qi 'running tests\|npm test\|pytest\|go test\|make test'; then
        write_milestone "$task_id" "Running tests"
    fi
    if echo "$captured" | grep -qi 'tests\? passed\|✓\|PASS'; then
        write_milestone "$task_id" "Tests passing"
    fi
    if echo "$captured" | grep -qi 'tests\? failed\|✗\|FAIL'; then
        write_milestone "$task_id" "Tests failing"
    fi
    if echo "$captured" | grep -qi 'git add\|git commit\|committed'; then
        write_milestone "$task_id" "Committing changes"
    fi
    if echo "$captured" | grep -qi 'error\|Error\|FATAL\|panic\|traceback'; then
        write_milestone "$task_id" "Error detected"
    fi

    return 1  # Signal: task still running
}

handle_callback() {
    local task_id="$1"
    local captured="$2"

    local callback_json
    callback_json="$(extract_callback_json "$captured")"

    if [ -z "$callback_json" ]; then
        log "${task_id}: callback-json tag found but could not extract JSON"
        return
    fi

    # Validate JSON
    if ! echo "$callback_json" | jq empty 2>/dev/null; then
        log "${task_id}: invalid callback JSON"
        write_milestone "$task_id" "Invalid callback JSON received"
        return
    fi

    local status
    status=$(echo "$callback_json" | jq -r '.status // "unknown"')
    local failed
    failed=$(echo "$callback_json" | jq -r '.test_results.failed // 0')
    local summary
    summary=$(echo "$callback_json" | jq -r '.summary // "No summary"')

    log "${task_id}: callback received — status=${status}, failed=${failed}"

    case "${status}" in
        completed)
            if [ "$failed" -eq 0 ] 2>/dev/null; then
                update_task_status "$task_id" "completed"
                write_milestone "$task_id" "Completed successfully: ${summary}"

                # Save callback for Layer 5 (Action) to process
                echo "$callback_json" > "${ORCHESTRATOR_DIR}/${task_id}-callback.json"

                # Notify via openclaw system event if available
                if command -v openclaw &>/dev/null; then
                    echo "Task ${task_id} completed: ${summary}" | openclaw system event --mode now 2>/dev/null || true
                fi
            else
                write_milestone "$task_id" "Completed with ${failed} test failures — requesting fix"
                # Send fix instruction to agent
                if tmux -S "$TMUX_SOCKET" has-session -t "$task_id" 2>/dev/null; then
                    tmux -S "$TMUX_SOCKET" send-keys -t "$task_id" \
                        "There are ${failed} failing tests. Please fix them and output a new callback-json block." Enter
                fi
            fi
            ;;
        failed)
            update_task_status "$task_id" "failed"
            write_milestone "$task_id" "Failed: ${summary}"
            echo "$callback_json" > "${ORCHESTRATOR_DIR}/${task_id}-callback.json"
            if command -v openclaw &>/dev/null; then
                echo "Task ${task_id} FAILED: ${summary}" | openclaw system event --mode now 2>/dev/null || true
            fi
            ;;
        need_clarification)
            update_task_status "$task_id" "blocked"
            write_milestone "$task_id" "Needs clarification: ${summary}"
            echo "$callback_json" > "${ORCHESTRATOR_DIR}/${task_id}-callback.json"
            if command -v openclaw &>/dev/null; then
                echo "Task ${task_id} needs clarification: ${summary}" | openclaw system event --mode now 2>/dev/null || true
            fi
            ;;
        *)
            log "${task_id}: unknown callback status '${status}'"
            ;;
    esac
}

check_stall() {
    local task_id="$1"
    local started_at="$2"

    # Get current epoch
    local now
    now=$(date +%s)

    # Parse started_at to epoch (best effort)
    local started_epoch
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo 0)

    if [ "$started_epoch" -eq 0 ]; then
        return  # Cannot parse date, skip stall check
    fi

    local elapsed=$(( now - started_epoch ))

    if [ "$elapsed" -gt "$STALL_TIMEOUT" ]; then
        # Check if there's recent output
        local last_output
        last_output=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t "$task_id" -S -1 2>/dev/null || echo "")
        if [ -z "$last_output" ]; then
            write_milestone "$task_id" "WARNING: Possible stall (${STALL_TIMEOUT}s with no output)"
            if command -v openclaw &>/dev/null; then
                echo "Task ${task_id} may be stalled (no output for ${STALL_TIMEOUT}s)" | \
                    openclaw system event --mode now 2>/dev/null || true
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Recovery: Check for orphaned tasks on startup (Layer 6)
# ---------------------------------------------------------------------------
run_recovery() {
    log "Running recovery check..."

    if ! [ -f "$ACTIVE_TASKS_FILE" ]; then
        log "No active-tasks.json found — nothing to recover."
        return
    fi

    if ! command -v jq &>/dev/null; then
        log "WARNING: jq not installed — cannot run recovery."
        return
    fi

    local task_ids
    task_ids=$(jq -r '.tasks[] | select(.status == "running") | .task_id' "$ACTIVE_TASKS_FILE")

    for tid in $task_ids; do
        if tmux -S "$TMUX_SOCKET" has-session -t "$tid" 2>/dev/null; then
            log "Recovery: task '${tid}' — session alive."
        else
            log "Recovery: task '${tid}' — session DEAD. Marking as crashed."
            update_task_status "$tid" "crashed"
            write_milestone "$tid" "Session crashed (detected on startup)"
            if command -v openclaw &>/dev/null; then
                echo "Task ${tid} crashed — tmux session no longer exists" | \
                    openclaw system event --mode now 2>/dev/null || true
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Main monitoring loop
# ---------------------------------------------------------------------------
monitor_task() {
    local task_id="$1"

    # Check if tmux session exists
    if ! tmux -S "$TMUX_SOCKET" has-session -t "$task_id" 2>/dev/null; then
        log "${task_id}: session not found — marking as crashed."
        update_task_status "$task_id" "crashed"
        write_milestone "$task_id" "Session crashed (not found)"
        return 0  # Remove from monitoring
    fi

    # Capture pane output
    local captured
    captured=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t "$task_id" -S -"$CAPTURE_LINES" 2>/dev/null || echo "")

    if [ -z "$captured" ]; then
        log "${task_id}: empty capture (session may be idle)."
        return 1  # Keep monitoring
    fi

    # Strip ANSI escape codes
    captured=$(echo "$captured" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null || echo "$captured")

    # Detect milestones (returns 0 if task completed)
    if detect_milestones "$task_id" "$captured"; then
        return 0  # Task completed, stop monitoring
    fi

    # Check for stalls
    if command -v jq &>/dev/null && [ -f "$ACTIVE_TASKS_FILE" ]; then
        local started_at
        started_at=$(jq -r --arg tid "$task_id" '.tasks[] | select(.task_id == $tid) | .launched_at // .started_at // ""' "$ACTIVE_TASKS_FILE")
        if [ -n "$started_at" ]; then
            check_stall "$task_id" "$started_at"
        fi
    fi

    return 1  # Keep monitoring
}

monitor_all() {
    if ! [ -f "$ACTIVE_TASKS_FILE" ] || ! command -v jq &>/dev/null; then
        log "No tasks to monitor."
        return
    fi

    local task_ids
    task_ids=$(jq -r '.tasks[] | select(.status == "running") | .task_id' "$ACTIVE_TASKS_FILE")

    if [ -z "$task_ids" ]; then
        log "No running tasks."
        return
    fi

    for tid in $task_ids; do
        monitor_task "$tid" || true
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    log "Watchdog started."
    log "  Socket:   ${TMUX_SOCKET}"
    log "  Interval: ${WATCHDOG_INTERVAL}s"
    log "  Stall:    ${STALL_TIMEOUT}s"
    log "  Mode:     $([ -n "$SINGLE_TASK" ] && echo "single (${SINGLE_TASK})" || echo "all tasks")"

    # Run recovery on startup
    run_recovery

    # Main loop
    while true; do
        if [ -n "$SINGLE_TASK" ]; then
            if monitor_task "$SINGLE_TASK"; then
                log "Task '${SINGLE_TASK}' completed or crashed. Exiting watchdog."
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
