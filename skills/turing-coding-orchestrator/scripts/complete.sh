#!/usr/bin/env bash
# =============================================================================
# Layer D: COMPLETE — Task-specific completion actions
# =============================================================================
# Usage: complete.sh --task-id ID [--callback-file FILE]
#
# Reads the task's callback JSON and active-tasks.json entry, then executes
# the appropriate completion action based on task_type and completion_action.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TASK_ID=""
CALLBACK_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)       TASK_ID="$2"; shift 2 ;;
        --callback-file) CALLBACK_FILE="$2"; shift 2 ;;
        *) echo "[complete] Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$TASK_ID" ]; then
    echo "Usage: complete.sh --task-id ID [--callback-file FILE]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCHESTRATOR_DIR="${REPO_ROOT}/.clawdbot"
ACTIVE_TASKS_FILE="${ORCHESTRATOR_DIR}/active-tasks.json"
MEMORY_FILE="${REPO_ROOT}/MEMORY.md"
DAILY_MEMORY_DIR="${REPO_ROOT}/memory"
DATE_TODAY="$(date -u +%Y-%m-%d)"
TIME_NOW="$(date -u +%H:%M)"
TMUX_SOCKET="/tmp/openclaw-tmux/openclaw.sock"

[ -z "$CALLBACK_FILE" ] && CALLBACK_FILE="${ORCHESTRATOR_DIR}/${TASK_ID}-callback.json"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if ! [ -f "$CALLBACK_FILE" ]; then
    echo "[complete] ERROR: Callback file not found: ${CALLBACK_FILE}"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "[complete] ERROR: jq is required for completion actions."
    exit 1
fi

# ---------------------------------------------------------------------------
# Read callback and task data
# ---------------------------------------------------------------------------
CB_STATUS=$(jq -r '.status // "unknown"' "$CALLBACK_FILE")
CB_TASK_TYPE=$(jq -r '.task_type // "unknown"' "$CALLBACK_FILE")
CB_BRANCH=$(jq -r '.branch // ""' "$CALLBACK_FILE")
CB_SUMMARY=$(jq -r '.summary // "No summary"' "$CALLBACK_FILE")
CB_FILES=$(jq -r '(.files_changed // []) | join(", ")' "$CALLBACK_FILE")
CB_TEST_PASSED=$(jq -r '.test_results.passed // 0' "$CALLBACK_FILE")
CB_TEST_FAILED=$(jq -r '.test_results.failed // 0' "$CALLBACK_FILE")
CB_TEST_SKIPPED=$(jq -r '.test_results.skipped // 0' "$CALLBACK_FILE")

# Read task metadata from active-tasks.json
COMPLETION_ACTION="notify"
ISSUE_NUM=""
WORKDIR=""
if [ -f "$ACTIVE_TASKS_FILE" ]; then
    COMPLETION_ACTION=$(jq -r --arg tid "$TASK_ID" \
        '(.tasks[] | select(.task_id == $tid)).completion_action // "notify"' \
        "$ACTIVE_TASKS_FILE")
    ISSUE_NUM=$(jq -r --arg tid "$TASK_ID" \
        '(.tasks[] | select(.task_id == $tid)).issue_number // ""' \
        "$ACTIVE_TASKS_FILE")
    WORKDIR=$(jq -r --arg tid "$TASK_ID" \
        '(.tasks[] | select(.task_id == $tid)).workdir // ""' \
        "$ACTIVE_TASKS_FILE")
fi

echo "[complete] Task: ${TASK_ID} (${CB_TASK_TYPE})"
echo "[complete] Status: ${CB_STATUS}"
echo "[complete] Action: ${COMPLETION_ACTION}"

# ---------------------------------------------------------------------------
# Helper: send notification
# ---------------------------------------------------------------------------
notify() {
    local message="$1"
    echo "[complete] NOTIFICATION: ${message}"

    # Try openclaw system event
    if command -v openclaw &>/dev/null; then
        echo "$message" | openclaw system event --mode now 2>/dev/null || true
    fi

    # Write to daily memory
    local daily_file="${DAILY_MEMORY_DIR}/${DATE_TODAY}.md"
    [ -f "$daily_file" ] && echo "- **${TIME_NOW}** [${TASK_ID}] ${message}" >> "$daily_file"
}

# ---------------------------------------------------------------------------
# Helper: update MEMORY.md task to completed section
# ---------------------------------------------------------------------------
mark_completed_in_memory() {
    local final_status="$1"
    local extra_info="${2:-}"

    if [ -f "$MEMORY_FILE" ] && command -v sed &>/dev/null; then
        sed -i "/### ${TASK_ID}:/,/^### / {
            s|- \*\*Status\*\*:.*|- **Status**: ${final_status}|
            s|- \*\*Latest Milestone\*\*:.*|- **Latest Milestone**: ${TIME_NOW} - ${final_status}|
        }" "$MEMORY_FILE"

        # Append extra info if provided
        if [ -n "$extra_info" ]; then
            sed -i "/### ${TASK_ID}:/,/^### / {
                /- \*\*Completion Action\*\*:/a\\- **Result**: ${extra_info}
            }" "$MEMORY_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Helper: cleanup session
# ---------------------------------------------------------------------------
cleanup_session() {
    # Kill tmux session
    tmux -S "$TMUX_SOCKET" kill-session -t "$TASK_ID" 2>/dev/null || true

    # Kill watchdog
    local pidfile="${ORCHESTRATOR_DIR}/${TASK_ID}-watchdog.pid"
    if [ -f "$pidfile" ]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi

    # Update active-tasks.json
    if [ -f "$ACTIVE_TASKS_FILE" ]; then
        local tmp=$(mktemp)
        jq --arg tid "$TASK_ID" \
            '(.tasks[] | select(.task_id == $tid)).status = "completed"' \
            "$ACTIVE_TASKS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_TASKS_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Action: Create PR
# ---------------------------------------------------------------------------
action_create_pr() {
    echo "[complete] Creating pull request..."

    if ! command -v gh &>/dev/null; then
        echo "[complete] ERROR: gh CLI not found. Cannot create PR."
        notify "Task ${TASK_ID} completed but could not create PR (gh not found): ${CB_SUMMARY}"
        return 1
    fi

    if [ -z "$CB_BRANCH" ] || [ "$CB_BRANCH" = "none" ] || [ "$CB_BRANCH" = "null" ]; then
        echo "[complete] ERROR: No branch available. Cannot create PR."
        notify "Task ${TASK_ID} completed but no branch to create PR from: ${CB_SUMMARY}"
        return 1
    fi

    # Independent test verification
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        echo "[complete] Running independent test verification..."
        cd "$WORKDIR"
        local test_ok=true
        if [ -f package.json ]; then
            npm test 2>&1 || test_ok=false
        elif [ -f Makefile ] && grep -q '^test:' Makefile; then
            make test 2>&1 || test_ok=false
        elif [ -f pytest.ini ] || [ -d tests ] || [ -f setup.py ] || [ -f pyproject.toml ]; then
            pytest 2>&1 || test_ok=false
        elif [ -f go.mod ]; then
            go test ./... 2>&1 || test_ok=false
        elif [ -f Cargo.toml ]; then
            cargo test 2>&1 || test_ok=false
        fi

        if ! $test_ok; then
            echo "[complete] WARNING: Independent test verification failed."
            notify "Task ${TASK_ID}: tests failed on independent verification. PR not created."
            return 1
        fi
    fi

    # Push branch
    cd "$WORKDIR"
    git push -u origin "$CB_BRANCH" 2>/dev/null || {
        echo "[complete] WARNING: git push failed."
        notify "Task ${TASK_ID}: could not push branch ${CB_BRANCH}"
        return 1
    }

    # Build PR title
    local pr_title=""
    case "$CB_TASK_TYPE" in
        issue)    pr_title="fix: ${CB_SUMMARY}" ;;
        feature)  pr_title="feat: ${CB_SUMMARY}" ;;
        bugfix)   pr_title="fix: ${CB_SUMMARY}" ;;
        refactor) pr_title="refactor: ${CB_SUMMARY}" ;;
        test)     pr_title="test: ${CB_SUMMARY}" ;;
        docs)     pr_title="docs: ${CB_SUMMARY}" ;;
        migrate)  pr_title="migrate: ${CB_SUMMARY}" ;;
        ops)      pr_title="ops: ${CB_SUMMARY}" ;;
        *)        pr_title="${CB_SUMMARY}" ;;
    esac

    # Build PR body
    local pr_body="## Summary
${CB_SUMMARY}

## Changes
${CB_FILES}

## Test Results
- Passed: ${CB_TEST_PASSED}
- Failed: ${CB_TEST_FAILED}
- Skipped: ${CB_TEST_SKIPPED}

---
*Automated by turing-coding-orchestrator (task: ${TASK_ID})*"

    # Add closes clause for issues
    if [ -n "$ISSUE_NUM" ] && [ "$ISSUE_NUM" != "null" ]; then
        pr_body="Closes #${ISSUE_NUM}

${pr_body}"
    fi

    # Detect base branch
    local base="main"
    git show-ref --verify --quiet "refs/remotes/origin/main" 2>/dev/null || base="master"

    # Create PR
    local pr_url
    pr_url=$(gh pr create \
        --title "$pr_title" \
        --body "$pr_body" \
        --base "$base" \
        --head "$CB_BRANCH" 2>&1) || {
        echo "[complete] WARNING: PR creation failed: ${pr_url}"
        notify "Task ${TASK_ID}: PR creation failed — ${pr_url}"
        return 1
    }

    echo "[complete] PR created: ${pr_url}"
    mark_completed_in_memory "completed" "PR: ${pr_url}"
    notify "Task ${TASK_ID} completed! PR created: ${pr_url} — ${CB_SUMMARY}"
}

# ---------------------------------------------------------------------------
# Action: Post review comments
# ---------------------------------------------------------------------------
action_post_comments() {
    echo "[complete] Posting review comments..."

    local review_result
    review_result=$(jq -r '.review_result // empty' "$CALLBACK_FILE" 2>/dev/null)

    if [ -z "$review_result" ]; then
        # Fall back to summary as a general comment
        notify "Review ${TASK_ID} complete: ${CB_SUMMARY}"
    else
        local verdict
        verdict=$(jq -r '.review_result.verdict // "commented"' "$CALLBACK_FILE")
        notify "Review ${TASK_ID} complete (${verdict}): ${CB_SUMMARY}"

        # If we have a PR number, post comments
        local pr_num
        pr_num=$(jq -r --arg tid "$TASK_ID" \
            '(.tasks[] | select(.task_id == $tid)).pr_number // ""' \
            "$ACTIVE_TASKS_FILE" 2>/dev/null)

        if [ -n "$pr_num" ] && [ "$pr_num" != "null" ] && command -v gh &>/dev/null; then
            gh pr review "$pr_num" --comment --body "## Code Review by ${TASK_ID}

${CB_SUMMARY}

---
*Automated review by turing-coding-orchestrator*" 2>/dev/null || true
        fi
    fi

    mark_completed_in_memory "completed" "Review: ${CB_SUMMARY}"
}

# ---------------------------------------------------------------------------
# Action: Report (exploration results)
# ---------------------------------------------------------------------------
action_report() {
    echo "[complete] Generating report..."

    local exploration
    exploration=$(jq -r '.exploration_result.answer // .summary // "No findings"' "$CALLBACK_FILE")

    # Save report
    local report_file="${ORCHESTRATOR_DIR}/${TASK_ID}-report.md"
    cat > "$report_file" <<REPORT
# Exploration Report: ${TASK_ID}

## Question / Task
$(jq -r '.description // "N/A"' "$ACTIVE_TASKS_FILE" 2>/dev/null || echo "N/A")

## Findings
${exploration}

## Relevant Files
$(jq -r '(.exploration_result.relevant_files // .files_read // []) | map("- `" + . + "`") | join("\n")' "$CALLBACK_FILE" 2>/dev/null || echo "- None identified")

---
*Generated at ${TIME_NOW} by turing-coding-orchestrator*
REPORT

    echo "[complete] Report saved: ${report_file}"
    mark_completed_in_memory "completed" "Report: ${report_file}"
    notify "Exploration ${TASK_ID} complete: ${CB_SUMMARY}"
}

# ---------------------------------------------------------------------------
# Action: Notify only
# ---------------------------------------------------------------------------
action_notify() {
    notify "Task ${TASK_ID} (${CB_TASK_TYPE}) ${CB_STATUS}: ${CB_SUMMARY}"
    mark_completed_in_memory "${CB_STATUS}" "${CB_SUMMARY}"
}

# ---------------------------------------------------------------------------
# Main routing
# ---------------------------------------------------------------------------
if [ "$CB_STATUS" = "failed" ]; then
    mark_completed_in_memory "failed" "${CB_SUMMARY}"
    notify "Task ${TASK_ID} FAILED: ${CB_SUMMARY}"
    cleanup_session
    exit 0
fi

if [ "$CB_STATUS" = "need_clarification" ]; then
    notify "Task ${TASK_ID} needs your input: ${CB_SUMMARY}"
    # Don't cleanup — task is paused, not done
    exit 0
fi

if [ "$CB_STATUS" = "partial" ]; then
    notify "Task ${TASK_ID} partial progress: ${CB_SUMMARY}"
    # Don't cleanup — task is still running
    exit 0
fi

# Status is "completed" — route by completion_action
case "$COMPLETION_ACTION" in
    create-pr|create-pr+notify)
        if [ "$CB_TEST_FAILED" -gt 0 ] 2>/dev/null; then
            echo "[complete] Tests failing (${CB_TEST_FAILED}). Not creating PR."
            notify "Task ${TASK_ID} completed but ${CB_TEST_FAILED} tests failing. Agent asked to fix."
            # Tell agent to fix tests
            if tmux -S "$TMUX_SOCKET" has-session -t "$TASK_ID" 2>/dev/null; then
                tmux -S "$TMUX_SOCKET" send-keys -t "$TASK_ID" \
                    "There are ${CB_TEST_FAILED} failing tests. Fix them and output a new callback-json." Enter
            fi
            exit 0
        fi
        action_create_pr
        cleanup_session
        ;;
    post-comments|post-comments+notify)
        action_post_comments
        cleanup_session
        ;;
    report|report+notify)
        action_report
        cleanup_session
        ;;
    notify)
        action_notify
        cleanup_session
        ;;
    none)
        echo "[complete] No completion action configured."
        mark_completed_in_memory "completed" "${CB_SUMMARY}"
        ;;
    aggregate)
        # For multi-tasks: just mark this sub-task done
        mark_completed_in_memory "completed" "${CB_SUMMARY}"
        notify "Sub-task ${TASK_ID} completed: ${CB_SUMMARY}"
        cleanup_session
        ;;
    *)
        echo "[complete] Unknown completion action: ${COMPLETION_ACTION}"
        action_notify
        cleanup_session
        ;;
esac

echo "[complete] ✓ Completion actions done for '${TASK_ID}'."
