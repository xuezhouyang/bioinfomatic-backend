#!/usr/bin/env bash
# =============================================================================
# Layer A: PREPARE — Universal environment setup for any coding task
# =============================================================================
# Usage: setup.sh --task-id ID --type TYPE --description DESC [options]
#
# Options:
#   --task-id ID          Unique task identifier
#   --type TYPE           Task type (issue|feature|bugfix|refactor|test|review|
#                         explore|docs|migrate|prototype|ops|interactive)
#   --description DESC    Task description
#   --issue NUM           GitHub issue number (for type=issue)
#   --pr NUM              GitHub PR number (for type=review)
#   --branch NAME         Custom branch name (auto-generated if omitted)
#   --worktree            Create git worktree for isolation
#   --workdir DIR         Custom working directory
#   --context-files LIST  Comma-separated list of files to include as context
#   --no-git              Skip all git operations (for non-repo tasks)
#   --agent AGENT         Preferred agent (claude|openclaw|aider|codex|gemini)
#   --completion ACTION   Completion action (create-pr|post-comments|notify|
#                         report|none)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TASK_ID=""
TASK_TYPE=""
DESCRIPTION=""
ISSUE_NUM=""
PR_NUM=""
BRANCH=""
USE_WORKTREE=false
WORKDIR=""
CONTEXT_FILES=""
NO_GIT=false
AGENT=""
COMPLETION_ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)      TASK_ID="$2"; shift 2 ;;
        --type)         TASK_TYPE="$2"; shift 2 ;;
        --description)  DESCRIPTION="$2"; shift 2 ;;
        --issue)        ISSUE_NUM="$2"; shift 2 ;;
        --pr)           PR_NUM="$2"; shift 2 ;;
        --branch)       BRANCH="$2"; shift 2 ;;
        --worktree)     USE_WORKTREE=true; shift ;;
        --workdir)      WORKDIR="$2"; shift 2 ;;
        --context-files) CONTEXT_FILES="$2"; shift 2 ;;
        --no-git)       NO_GIT=true; shift ;;
        --agent)        AGENT="$2"; shift 2 ;;
        --completion)   COMPLETION_ACTION="$2"; shift 2 ;;
        *) echo "[setup] Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required args
if [ -z "$TASK_ID" ] || [ -z "$TASK_TYPE" ]; then
    echo "Usage: setup.sh --task-id ID --type TYPE --description DESC [options]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Defaults based on task type
# ---------------------------------------------------------------------------
NEEDS_BRANCH=true
NEEDS_WORKTREE=false

case "$TASK_TYPE" in
    issue|feature|bugfix|refactor|test|docs|migrate|ops)
        NEEDS_BRANCH=true
        NEEDS_WORKTREE=true
        [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="create-pr"
        ;;
    review|explore)
        NEEDS_BRANCH=false
        NEEDS_WORKTREE=false
        NO_GIT=true
        if [ "$TASK_TYPE" = "review" ]; then
            [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="post-comments"
        else
            [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="report"
        fi
        ;;
    prototype)
        NEEDS_BRANCH=true
        NEEDS_WORKTREE=false
        [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="notify"
        ;;
    interactive)
        NEEDS_BRANCH=false
        NEEDS_WORKTREE=false
        [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="none"
        ;;
    multi)
        echo "[setup] ERROR: multi tasks should be decomposed before calling setup.sh"
        exit 1
        ;;
    *)
        echo "[setup] WARNING: Unknown task type '${TASK_TYPE}'. Using defaults."
        [ -z "$COMPLETION_ACTION" ] && COMPLETION_ACTION="notify"
        ;;
esac

# Override with explicit flags
$USE_WORKTREE && NEEDS_WORKTREE=true

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ORCHESTRATOR_DIR="${REPO_ROOT}/.clawdbot"
ACTIVE_TASKS_FILE="${ORCHESTRATOR_DIR}/active-tasks.json"
MEMORY_FILE="${REPO_ROOT}/MEMORY.md"
DAILY_MEMORY_DIR="${REPO_ROOT}/memory"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DATE_TODAY="$(date -u +%Y-%m-%d)"
TIME_NOW="$(date -u +%H:%M)"

mkdir -p "$ORCHESTRATOR_DIR"
mkdir -p "$DAILY_MEMORY_DIR"

# ---------------------------------------------------------------------------
# 1. Generate branch name if needed
# ---------------------------------------------------------------------------
WORKTREE_DIR=""

if $NEEDS_BRANCH && ! $NO_GIT; then
    if [ -z "$BRANCH" ]; then
        case "$TASK_TYPE" in
            issue)    BRANCH="fix/${TASK_ID}" ;;
            feature)  BRANCH="feat/${TASK_ID}" ;;
            bugfix)   BRANCH="fix/${TASK_ID}" ;;
            refactor) BRANCH="refactor/${TASK_ID}" ;;
            test)     BRANCH="test/${TASK_ID}" ;;
            docs)     BRANCH="docs/${TASK_ID}" ;;
            migrate)  BRANCH="migrate/${TASK_ID}" ;;
            ops)      BRANCH="ops/${TASK_ID}" ;;
            prototype) BRANCH="proto/${TASK_ID}" ;;
            *)        BRANCH="task/${TASK_ID}" ;;
        esac
    fi

    # Create branch
    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
        echo "[setup] Branch '${BRANCH}' already exists — reusing."
    else
        BASE_BRANCH="main"
        if ! git show-ref --verify --quiet "refs/heads/main" && \
           ! git show-ref --verify --quiet "refs/remotes/origin/main"; then
            BASE_BRANCH="master"
        fi
        git branch "$BRANCH" "origin/${BASE_BRANCH}" 2>/dev/null || \
            git branch "$BRANCH" "${BASE_BRANCH}" 2>/dev/null || \
            git branch "$BRANCH" 2>/dev/null || true
        echo "[setup] Created branch '${BRANCH}'."
    fi

    # Create worktree if needed
    if $NEEDS_WORKTREE; then
        WORKTREE_DIR="../worktrees/${TASK_ID}"
        if [ -d "$WORKTREE_DIR" ]; then
            echo "[setup] Worktree '${WORKTREE_DIR}' already exists — reusing."
        else
            git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null || {
                echo "[setup] WARNING: worktree failed. Falling back to checkout."
                git checkout "$BRANCH" 2>/dev/null || true
                WORKTREE_DIR="$REPO_ROOT"
            }
            echo "[setup] Created worktree at '${WORKTREE_DIR}'."
        fi
    fi
fi

# Set working directory
if [ -n "$WORKDIR" ]; then
    WORKTREE_DIR="$WORKDIR"
elif [ -z "$WORKTREE_DIR" ]; then
    WORKTREE_DIR="$REPO_ROOT"
fi

# ---------------------------------------------------------------------------
# 2. Fetch context based on task type
# ---------------------------------------------------------------------------
CONTEXT_DIR="${ORCHESTRATOR_DIR}/${TASK_ID}-context"
mkdir -p "$CONTEXT_DIR"

case "$TASK_TYPE" in
    issue)
        if [ -n "$ISSUE_NUM" ] && command -v gh &>/dev/null; then
            gh issue view "$ISSUE_NUM" --json title,body,labels,assignees,milestone \
                > "${CONTEXT_DIR}/issue.json" 2>/dev/null || \
                echo '{"title":"Issue fetch failed","body":"Could not fetch issue"}' \
                > "${CONTEXT_DIR}/issue.json"
            TITLE=$(jq -r '.title // "Unknown"' "${CONTEXT_DIR}/issue.json" 2>/dev/null || echo "$TASK_ID")
            echo "[setup] Fetched issue #${ISSUE_NUM}: ${TITLE}"
        fi
        ;;
    review)
        if [ -n "$PR_NUM" ] && command -v gh &>/dev/null; then
            gh pr view "$PR_NUM" --json title,body,files,comments,reviews \
                > "${CONTEXT_DIR}/pr.json" 2>/dev/null || true
            gh pr diff "$PR_NUM" > "${CONTEXT_DIR}/pr.diff" 2>/dev/null || true
            echo "[setup] Fetched PR #${PR_NUM} for review."
        fi
        ;;
esac

# Copy specified context files
if [ -n "$CONTEXT_FILES" ]; then
    IFS=',' read -ra FILES <<< "$CONTEXT_FILES"
    for f in "${FILES[@]}"; do
        if [ -f "$f" ]; then
            cp "$f" "${CONTEXT_DIR}/" 2>/dev/null || true
        fi
    done
fi

# Always capture repo structure (for agents to understand the project)
if [ -f "${REPO_ROOT}/README.md" ]; then
    cp "${REPO_ROOT}/README.md" "${CONTEXT_DIR}/README.md" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Initialize MEMORY.md
# ---------------------------------------------------------------------------
if ! [ -f "$MEMORY_FILE" ]; then
    cat > "$MEMORY_FILE" <<'HEADER'
# Project Memory

## In-Flight Tasks

## Completed Tasks

HEADER
    echo "[setup] Created ${MEMORY_FILE}."
fi

if ! grep -q "## In-Flight Tasks" "$MEMORY_FILE"; then
    printf '\n## In-Flight Tasks\n\n' >> "$MEMORY_FILE"
fi

TASK_TITLE="${DESCRIPTION:-${TASK_ID}}"

if grep -q "### ${TASK_ID}:" "$MEMORY_FILE"; then
    echo "[setup] Task '${TASK_ID}' already in MEMORY.md — skipping."
else
    # Insert after "## In-Flight Tasks" line
    cat >> "$MEMORY_FILE" <<ENTRY

### ${TASK_ID}: ${TASK_TITLE}
- **Type**: ${TASK_TYPE}
- **Status**: pending
- **Branch**: ${BRANCH:-none}
- **Session**: ${TASK_ID}
- **Agent**: ${AGENT:-auto}
- **Started**: ${TIMESTAMP}
- **Latest Milestone**: Initializing
- **Completion Action**: ${COMPLETION_ACTION}
ENTRY
    echo "[setup] Added task '${TASK_ID}' to MEMORY.md."
fi

# ---------------------------------------------------------------------------
# 4. Initialize active-tasks.json
# ---------------------------------------------------------------------------
if ! [ -f "$ACTIVE_TASKS_FILE" ]; then
    echo '{"tasks":[]}' > "$ACTIVE_TASKS_FILE"
fi

if command -v jq &>/dev/null; then
    EXISTING=$(jq -r --arg tid "$TASK_ID" '.tasks[] | select(.task_id == $tid) | .task_id' "$ACTIVE_TASKS_FILE" 2>/dev/null)
    if [ -z "$EXISTING" ]; then
        TEMP_FILE=$(mktemp)
        jq --arg tid "$TASK_ID" \
           --arg ttype "$TASK_TYPE" \
           --arg sess "$TASK_ID" \
           --arg br "${BRANCH:-}" \
           --arg wt "${WORKTREE_DIR}" \
           --arg ts "$TIMESTAMP" \
           --arg ca "$COMPLETION_ACTION" \
           --arg desc "$TASK_TITLE" \
           --arg ag "${AGENT:-auto}" \
           --arg inum "${ISSUE_NUM:-}" \
           --arg prnum "${PR_NUM:-}" \
           '.tasks += [{
               "task_id": $tid,
               "task_type": $ttype,
               "session": $sess,
               "branch": (if $br == "" then null else $br end),
               "worktree": $wt,
               "workdir": $wt,
               "agent": $ag,
               "started_at": $ts,
               "status": "pending",
               "pid": null,
               "completion_action": $ca,
               "issue_number": (if $inum == "" then null else ($inum | tonumber? // null) end),
               "pr_number": (if $prnum == "" then null else ($prnum | tonumber? // null) end),
               "description": $desc
           }]' "$ACTIVE_TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$ACTIVE_TASKS_FILE"
        echo "[setup] Registered task in active-tasks.json."
    fi
elif command -v python3 &>/dev/null; then
    python3 << PYEOF
import json
with open('$ACTIVE_TASKS_FILE', 'r') as f:
    data = json.load(f)
if not any(t['task_id'] == '$TASK_ID' for t in data['tasks']):
    data['tasks'].append({
        'task_id': '$TASK_ID',
        'task_type': '$TASK_TYPE',
        'session': '$TASK_ID',
        'branch': '${BRANCH}' or None,
        'worktree': '${WORKTREE_DIR}',
        'workdir': '${WORKTREE_DIR}',
        'agent': '${AGENT:-auto}',
        'started_at': '$TIMESTAMP',
        'status': 'pending',
        'pid': None,
        'completion_action': '$COMPLETION_ACTION',
        'issue_number': ${ISSUE_NUM:-None},
        'pr_number': ${PR_NUM:-None},
        'description': '''$TASK_TITLE'''
    })
    with open('$ACTIVE_TASKS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
PYEOF
fi

# ---------------------------------------------------------------------------
# 5. Write daily memory
# ---------------------------------------------------------------------------
DAILY_FILE="${DAILY_MEMORY_DIR}/${DATE_TODAY}.md"
if ! [ -f "$DAILY_FILE" ]; then
    echo "# ${DATE_TODAY}" > "$DAILY_FILE"
    echo "" >> "$DAILY_FILE"
fi
echo "- **${TIME_NOW}** [${TASK_ID}] (${TASK_TYPE}) Task initialized — ${TASK_TITLE}" >> "$DAILY_FILE"

# ---------------------------------------------------------------------------
# 6. Ensure .gitignore
# ---------------------------------------------------------------------------
GITIGNORE="${REPO_ROOT}/.gitignore"
[ -f "$GITIGNORE" ] || touch "$GITIGNORE"
for PATTERN in ".clawdbot/active-tasks.json" ".clawdbot/*-context/" "memory/" ".clawdbot/*.pid" ".clawdbot/*.log"; do
    grep -qF "$PATTERN" "$GITIGNORE" || echo "$PATTERN" >> "$GITIGNORE"
done

# ---------------------------------------------------------------------------
# Output summary as JSON (for scripts to consume)
# ---------------------------------------------------------------------------
cat <<SUMMARY_JSON
{
  "task_id": "${TASK_ID}",
  "task_type": "${TASK_TYPE}",
  "branch": "${BRANCH:-null}",
  "worktree": "${WORKTREE_DIR}",
  "workdir": "${WORKTREE_DIR}",
  "completion_action": "${COMPLETION_ACTION}",
  "context_dir": "${CONTEXT_DIR}",
  "status": "prepared"
}
SUMMARY_JSON

echo ""
echo "[setup] ✓ Setup complete for ${TASK_TYPE} task '${TASK_ID}'."
