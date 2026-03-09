# =============================================================================
# Issue-to-PR Workflow (using universal orchestrator scripts)
# =============================================================================
# One of many possible workflows. Uses the universal setup/launch/complete
# scripts with task_type=issue.
# =============================================================================

name: issue-to-pr
description: >
  End-to-end: fetch GitHub issue → setup environment → launch agent →
  monitor → verify → create PR → notify.
version: "0.2.0"

inputs:
  issue_number:
    type: integer
    required: true
  base_branch:
    type: string
    default: "main"
  auto_pr:
    type: boolean
    default: true
  require_approval:
    type: boolean
    default: false
  agent:
    type: string
    default: ""
    description: "Override agent (claude|openclaw|aider|codex|gemini)"

stages:

  - name: setup
    description: "Prepare environment for issue"
    action: shell
    command: |
      TASK_ID="issue-{{ inputs.issue_number }}"
      bash skills/turing-coding-orchestrator/scripts/setup.sh \
        --task-id "$TASK_ID" \
        --type issue \
        --issue {{ inputs.issue_number }} \
        --description "Fix GitHub issue #{{ inputs.issue_number }}" \
        --worktree \
        --completion create-pr
    on_failure:
      - action: notify
        message: "Setup failed for issue #{{ inputs.issue_number }}"
      - action: abort

  - name: launch
    description: "Start coding agent"
    depends_on: [setup]
    action: shell
    command: |
      TASK_ID="issue-{{ inputs.issue_number }}"
      WORKDIR="../worktrees/${TASK_ID}"
      bash skills/turing-coding-orchestrator/scripts/launch.sh \
        --task-id "$TASK_ID" \
        --type issue \
        --workdir "$WORKDIR" \
        --description "Fix GitHub issue #{{ inputs.issue_number }}" \
        {{ if inputs.agent }}--agent {{ inputs.agent }}{{ endif }}
    on_failure:
      - action: notify
        message: "Agent launch failed for issue #{{ inputs.issue_number }}"
      - action: abort

  - name: wait
    description: "Wait for agent callback"
    depends_on: [launch]
    action: wait
    condition: |
      test -f ".clawdbot/issue-{{ inputs.issue_number }}-callback.json"
    timeout: 3600
    poll_interval: 30
    on_timeout:
      - action: notify
        message: "Agent timed out on issue #{{ inputs.issue_number }} (1h limit)"

  - name: approval-gate
    description: "Optional human approval"
    depends_on: [wait]
    skip_if: "{{ not inputs.require_approval }}"
    action: approval
    prompt: "Issue #{{ inputs.issue_number }} done. Create PR?"
    timeout: 86400

  - name: complete
    description: "Execute completion actions (test verify + PR + notify)"
    depends_on: [approval-gate]
    action: shell
    command: |
      bash skills/turing-coding-orchestrator/scripts/complete.sh \
        --task-id "issue-{{ inputs.issue_number }}"

  - name: cleanup
    description: "Clean up session and worktree"
    depends_on: [complete]
    always_run: true
    action: shell
    command: |
      TASK_ID="issue-{{ inputs.issue_number }}"
      tmux -S /tmp/openclaw-tmux/openclaw.sock kill-session -t "$TASK_ID" 2>/dev/null || true
      PIDFILE=".clawdbot/${TASK_ID}-watchdog.pid"
      [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"
      git worktree remove "../worktrees/${TASK_ID}" --force 2>/dev/null || true
      rm -f "/tmp/issue-{{ inputs.issue_number }}.json"
