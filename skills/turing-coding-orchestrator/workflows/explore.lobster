# =============================================================================
# Exploration Workflow — Read-only codebase research
# =============================================================================

name: explore
description: >
  Launch an agent to explore/explain a codebase topic. No git changes.
  Agent reads code, produces a report, and sends it to the user.
version: "0.1.0"

inputs:
  question:
    type: string
    required: true
    description: "What to explore or explain"
  agent:
    type: string
    default: ""

stages:

  - name: setup
    action: shell
    command: |
      HASH=$(echo "{{ inputs.question }}" | md5sum | cut -c1-8)
      TASK_ID="explore-${HASH}"
      bash skills/turing-coding-orchestrator/scripts/setup.sh \
        --task-id "$TASK_ID" \
        --type explore \
        --description "{{ inputs.question }}" \
        --no-git \
        --completion report

  - name: launch
    depends_on: [setup]
    action: shell
    command: |
      HASH=$(echo "{{ inputs.question }}" | md5sum | cut -c1-8)
      TASK_ID="explore-${HASH}"
      bash skills/turing-coding-orchestrator/scripts/launch.sh \
        --task-id "$TASK_ID" \
        --type explore \
        --workdir "$(pwd)" \
        --description "{{ inputs.question }}" \
        {{ if inputs.agent }}--agent {{ inputs.agent }}{{ endif }}

  - name: wait
    depends_on: [launch]
    action: wait
    condition: |
      HASH=$(echo "{{ inputs.question }}" | md5sum | cut -c1-8)
      test -f ".clawdbot/explore-${HASH}-callback.json"
    timeout: 1800
    poll_interval: 30

  - name: complete
    depends_on: [wait]
    action: shell
    command: |
      HASH=$(echo "{{ inputs.question }}" | md5sum | cut -c1-8)
      bash skills/turing-coding-orchestrator/scripts/complete.sh \
        --task-id "explore-${HASH}"
