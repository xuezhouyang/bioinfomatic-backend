#!/usr/bin/env bash
# =============================================================================
# Task Router — Classify user intent into task type + parameters
# =============================================================================
# Usage: router.sh "user input text"
# Output: JSON with task_type, task_id, and extracted parameters
# =============================================================================
# This script does basic pattern matching for task classification.
# For LLM-powered classification, the orchestrator (SKILL.md) handles it
# directly. This script is a fallback for deterministic routing.
# =============================================================================

set -euo pipefail

INPUT="${1:?Usage: router.sh \"user input text\"}"
INPUT_LOWER="$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------------------
# Extract structured data from input
# ---------------------------------------------------------------------------

# Extract issue numbers (#N or issue N)
ISSUE_NUMS=$(echo "$INPUT" | grep -oP '(?:#|issue\s+)\K\d+' | head -20)
ISSUE_COUNT=$(echo "$ISSUE_NUMS" | grep -c '[0-9]' || echo 0)

# Extract PR numbers (PR #N or pull request N)
PR_NUMS=$(echo "$INPUT_LOWER" | grep -oP '(?:pr\s*#?|pull\s+request\s*#?)\K\d+' | head -5)

# Generate task ID
SHORT_HASH=$(echo "$INPUT" | md5sum | cut -c1-8)

# ---------------------------------------------------------------------------
# Classification logic (order matters — more specific patterns first)
# ---------------------------------------------------------------------------
TASK_TYPE=""
TASK_ID=""
EXTRA_ARGS=""

# 1. Multiple issues → multi
if [ "$ISSUE_COUNT" -gt 1 ]; then
    TASK_TYPE="multi"
    TASK_ID="multi-${SHORT_HASH}"
    # Output sub-tasks for each issue
    SUBTASKS="["
    FIRST=true
    for num in $ISSUE_NUMS; do
        $FIRST || SUBTASKS="${SUBTASKS},"
        SUBTASKS="${SUBTASKS}{\"type\":\"issue\",\"issue_number\":${num},\"task_id\":\"issue-${num}\"}"
        FIRST=false
    done
    SUBTASKS="${SUBTASKS}]"
    EXTRA_ARGS="\"subtasks\": ${SUBTASKS},"

# 2. Review PR
elif [ -n "$PR_NUMS" ]; then
    PR_NUM=$(echo "$PR_NUMS" | head -1)
    if echo "$INPUT_LOWER" | grep -qP 'review|check|look\s+at|examine'; then
        TASK_TYPE="review"
        TASK_ID="review-pr-${PR_NUM}"
        EXTRA_ARGS="\"pr_number\": ${PR_NUM},"
    else
        TASK_TYPE="feature"
        TASK_ID="task-${SHORT_HASH}"
    fi

# 3. Single issue
elif [ "$ISSUE_COUNT" -eq 1 ]; then
    ISSUE_NUM=$(echo "$ISSUE_NUMS" | head -1)
    TASK_TYPE="issue"
    TASK_ID="issue-${ISSUE_NUM}"
    EXTRA_ARGS="\"issue_number\": ${ISSUE_NUM},"

# 4. Explore / explain / research
elif echo "$INPUT_LOWER" | grep -qP 'how\s+does|explain|find\s+(where|all|every)|explore|understand|what\s+is|where\s+is|architecture|flow|diagram'; then
    TASK_TYPE="explore"
    TASK_ID="explore-${SHORT_HASH}"

# 5. Code review (without PR number)
elif echo "$INPUT_LOWER" | grep -qP 'review\s+(this|the|my)\s+code|code\s+review'; then
    TASK_TYPE="review"
    TASK_ID="review-${SHORT_HASH}"

# 6. Test writing
elif echo "$INPUT_LOWER" | grep -qP 'write\s+tests?|add\s+tests?|test\s+coverage|add\s+specs?|unit\s+tests?'; then
    TASK_TYPE="test"
    TASK_ID="test-${SHORT_HASH}"

# 7. Refactor
elif echo "$INPUT_LOWER" | grep -qP 'refactor|clean\s*up|restructure|extract|decouple|simplif'; then
    TASK_TYPE="refactor"
    TASK_ID="refactor-${SHORT_HASH}"

# 8. Documentation
elif echo "$INPUT_LOWER" | grep -qP 'document|readme|api\s+docs|write\s+docs|jsdoc|docstring'; then
    TASK_TYPE="docs"
    TASK_ID="docs-${SHORT_HASH}"

# 9. Migration
elif echo "$INPUT_LOWER" | grep -qP 'migrate|upgrade|convert|rename\s+.*across|move\s+from.*to'; then
    TASK_TYPE="migrate"
    TASK_ID="migrate-${SHORT_HASH}"

# 10. Prototype
elif echo "$INPUT_LOWER" | grep -qP 'prototype|spike|try\s+out|experiment|poc|proof\s+of\s+concept'; then
    TASK_TYPE="prototype"
    TASK_ID="proto-${SHORT_HASH}"

# 11. Interactive session
elif echo "$INPUT_LOWER" | grep -qP 'start\s+(a\s+)?session|open\s+(a\s+)?repl|let\s+me\s+direct|interactive'; then
    TASK_TYPE="interactive"
    TASK_ID="session-${SHORT_HASH}"

# 12. DevOps / Infrastructure
elif echo "$INPUT_LOWER" | grep -qP 'ci[/\s]cd|docker|deploy|infra|kubernetes|k8s|terraform|ansible|github\s+actions|pipeline'; then
    TASK_TYPE="ops"
    TASK_ID="ops-${SHORT_HASH}"

# 13. Bug fix (distinct from issue — described as a bug without issue number)
elif echo "$INPUT_LOWER" | grep -qP 'bug|crash|broken|doesn.t\s+work|failing|error\s+when|fix\s+(the|this|a)'; then
    TASK_TYPE="bugfix"
    TASK_ID="bugfix-${SHORT_HASH}"

# 14. Default → feature
else
    TASK_TYPE="feature"
    TASK_ID="task-${SHORT_HASH}"
fi

# ---------------------------------------------------------------------------
# Determine completion action
# ---------------------------------------------------------------------------
COMPLETION_ACTION=""
case "$TASK_TYPE" in
    issue|feature|bugfix|refactor|test|docs|migrate|ops) COMPLETION_ACTION="create-pr" ;;
    review)     COMPLETION_ACTION="post-comments" ;;
    explore)    COMPLETION_ACTION="report" ;;
    prototype)  COMPLETION_ACTION="notify" ;;
    interactive) COMPLETION_ACTION="none" ;;
    multi)      COMPLETION_ACTION="aggregate" ;;
    *)          COMPLETION_ACTION="notify" ;;
esac

# Check if user explicitly wants a PR
if echo "$INPUT_LOWER" | grep -qP 'create\s+(a\s+)?pr|make\s+(a\s+)?pr|pull\s+request'; then
    COMPLETION_ACTION="create-pr"
fi

# Check if user wants notification
if echo "$INPUT_LOWER" | grep -qP 'ping\s+me|notify|tell\s+me\s+when|let\s+me\s+know'; then
    COMPLETION_ACTION="${COMPLETION_ACTION}+notify"
fi

# ---------------------------------------------------------------------------
# Determine if branch/worktree needed
# ---------------------------------------------------------------------------
NEEDS_BRANCH=false
NEEDS_WORKTREE=false
case "$TASK_TYPE" in
    issue|feature|bugfix|refactor|test|docs|migrate|ops)
        NEEDS_BRANCH=true
        NEEDS_WORKTREE=true
        ;;
    prototype)
        NEEDS_BRANCH=true
        ;;
esac

# ---------------------------------------------------------------------------
# Output classification as JSON
# ---------------------------------------------------------------------------
cat <<EOF
{
  "input": $(echo "$INPUT" | jq -Rs . 2>/dev/null || echo "\"$INPUT\""),
  "task_type": "${TASK_TYPE}",
  "task_id": "${TASK_ID}",
  ${EXTRA_ARGS}
  "completion_action": "${COMPLETION_ACTION}",
  "needs_branch": ${NEEDS_BRANCH},
  "needs_worktree": ${NEEDS_WORKTREE},
  "description": $(echo "$INPUT" | jq -Rs . 2>/dev/null || echo "\"$INPUT\"")
}
EOF
