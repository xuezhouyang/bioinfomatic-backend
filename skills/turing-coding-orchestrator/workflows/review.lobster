# =============================================================================
# Code Review Workflow — Read-only review with comments
# =============================================================================

name: review
description: >
  Launch an agent to review a PR or code. Agent reads the diff, analyzes
  the code, and posts review comments.
version: "0.1.0"

inputs:
  pr_number:
    type: integer
    required: true
  agent:
    type: string
    default: ""

stages:

  - name: setup
    action: shell
    command: |
      TASK_ID="review-pr-{{ inputs.pr_number }}"
      bash skills/turing-coding-orchestrator/scripts/setup.sh \
        --task-id "$TASK_ID" \
        --type review \
        --pr {{ inputs.pr_number }} \
        --description "Review PR #{{ inputs.pr_number }}" \
        --no-git \
        --completion post-comments

  - name: launch
    depends_on: [setup]
    action: shell
    command: |
      TASK_ID="review-pr-{{ inputs.pr_number }}"
      bash skills/turing-coding-orchestrator/scripts/launch.sh \
        --task-id "$TASK_ID" \
        --type review \
        --workdir "$(pwd)" \
        --description "Review PR #{{ inputs.pr_number }}" \
        {{ if inputs.agent }}--agent {{ inputs.agent }}{{ endif }}

  - name: wait
    depends_on: [launch]
    action: wait
    condition: |
      test -f ".clawdbot/review-pr-{{ inputs.pr_number }}-callback.json"
    timeout: 1800
    poll_interval: 30

  - name: complete
    depends_on: [wait]
    action: shell
    command: |
      bash skills/turing-coding-orchestrator/scripts/complete.sh \
        --task-id "review-pr-{{ inputs.pr_number }}"
