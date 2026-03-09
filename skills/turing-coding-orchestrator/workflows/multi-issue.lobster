# =============================================================================
# Multi-Issue Parallel Workflow — Fix multiple issues simultaneously
# =============================================================================

name: multi-issue
description: >
  Fix multiple GitHub issues in parallel. Each issue gets its own worktree,
  branch, and agent. Results are aggregated into a single notification.
version: "0.1.0"

inputs:
  issue_numbers:
    type: array
    items: { type: integer }
    required: true
    description: "List of issue numbers to fix"
  agent:
    type: string
    default: ""

stages:

  - name: setup-all
    description: "Setup environments for all issues in parallel"
    action: parallel
    foreach: "{{ inputs.issue_numbers }}"
    as: "issue_num"
    do:
      action: shell
      command: |
        bash skills/turing-coding-orchestrator/scripts/setup.sh \
          --task-id "issue-{{ issue_num }}" \
          --type issue \
          --issue {{ issue_num }} \
          --description "Fix GitHub issue #{{ issue_num }}" \
          --worktree \
          --completion create-pr

  - name: launch-all
    description: "Launch agents for all issues in parallel"
    depends_on: [setup-all]
    action: parallel
    foreach: "{{ inputs.issue_numbers }}"
    as: "issue_num"
    do:
      action: shell
      command: |
        WORKDIR="../worktrees/issue-{{ issue_num }}"
        bash skills/turing-coding-orchestrator/scripts/launch.sh \
          --task-id "issue-{{ issue_num }}" \
          --type issue \
          --workdir "$WORKDIR" \
          --description "Fix GitHub issue #{{ issue_num }}" \
          {{ if inputs.agent }}--agent {{ inputs.agent }}{{ endif }}

  - name: wait-all
    description: "Wait for all agents to complete"
    depends_on: [launch-all]
    action: wait
    condition: |
      ALL_DONE=true
      for num in {{ inputs.issue_numbers | join(' ') }}; do
        test -f ".clawdbot/issue-${num}-callback.json" || ALL_DONE=false
      done
      $ALL_DONE
    timeout: 7200
    poll_interval: 60

  - name: complete-all
    description: "Run completion for all issues"
    depends_on: [wait-all]
    action: parallel
    foreach: "{{ inputs.issue_numbers }}"
    as: "issue_num"
    do:
      action: shell
      command: |
        bash skills/turing-coding-orchestrator/scripts/complete.sh \
          --task-id "issue-{{ issue_num }}"

  - name: aggregate
    description: "Send summary notification"
    depends_on: [complete-all]
    action: shell
    command: |
      echo "=== Multi-Issue Summary ==="
      for num in {{ inputs.issue_numbers | join(' ') }}; do
        CB=".clawdbot/issue-${num}-callback.json"
        if [ -f "$CB" ]; then
          STATUS=$(jq -r '.status' "$CB")
          SUMMARY=$(jq -r '.summary' "$CB")
          echo "  #${num}: ${STATUS} — ${SUMMARY}"
        else
          echo "  #${num}: no callback received"
        fi
      done
