# =============================================================================
# Issue-to-PR Deterministic Workflow
# =============================================================================
# This Lobster workflow defines the deterministic pipeline from GitHub issue
# to Pull Request. Each stage has clear entry/exit criteria and failure modes.
# =============================================================================

name: issue-to-pr
description: >
  End-to-end workflow: fetch GitHub issue → create branch → launch coding
  agent → verify tests → create PR → notify user.
version: "0.1.0"

# ---------------------------------------------------------------------------
# Input Parameters
# ---------------------------------------------------------------------------
inputs:
  issue_number:
    type: integer
    required: true
    description: "GitHub issue number to resolve"
  base_branch:
    type: string
    default: "main"
    description: "Base branch to create feature branch from"
  auto_pr:
    type: boolean
    default: true
    description: "Automatically create PR on completion"
  require_approval:
    type: boolean
    default: false
    description: "Require human approval before creating PR"
  notify_channel:
    type: string
    default: "system"
    description: "Notification channel (system|telegram|slack)"

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
stages:

  # -------------------------------------------------------------------------
  # Stage 1: Fetch Issue
  # -------------------------------------------------------------------------
  - name: fetch-issue
    description: "Retrieve issue details from GitHub"
    action: shell
    command: |
      gh issue view {{ inputs.issue_number }} \
        --json title,body,labels,assignees,milestone \
        > /tmp/issue-{{ inputs.issue_number }}.json
      echo "Issue fetched successfully"
    outputs:
      issue_json: "/tmp/issue-{{ inputs.issue_number }}.json"
    on_failure:
      - action: notify
        message: "Failed to fetch issue #{{ inputs.issue_number }}. Check gh auth status."
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 2: Setup Environment
  # -------------------------------------------------------------------------
  - name: setup
    description: "Create branch, worktree, and initialize tracking"
    depends_on: [fetch-issue]
    action: shell
    command: |
      TASK_ID="issue-{{ inputs.issue_number }}"
      BRANCH="fix/${TASK_ID}"
      WORKTREE_DIR="../worktrees/${TASK_ID}"
      ISSUE_BODY=$(cat /tmp/issue-{{ inputs.issue_number }}.json | jq -r '.body // ""')

      bash skills/turing-coding-orchestrator/scripts/setup.sh \
        "$TASK_ID" "$BRANCH" "$WORKTREE_DIR" "$ISSUE_BODY"
    outputs:
      task_id: "issue-{{ inputs.issue_number }}"
      branch: "fix/issue-{{ inputs.issue_number }}"
      worktree: "../worktrees/issue-{{ inputs.issue_number }}"
    on_failure:
      - action: notify
        message: "Setup failed for issue #{{ inputs.issue_number }}"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 3: Launch Agent
  # -------------------------------------------------------------------------
  - name: launch-agent
    description: "Start coding agent in tmux session"
    depends_on: [setup]
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      WORKTREE="{{ stages.setup.outputs.worktree }}"
      ISSUE_JSON="/tmp/issue-{{ inputs.issue_number }}.json"

      # Build prompt file from issue content
      PROMPT_FILE="/tmp/${TASK_ID}-prompt.md"
      TITLE=$(jq -r '.title // "No title"' "$ISSUE_JSON")
      BODY=$(jq -r '.body // "No description"' "$ISSUE_JSON")
      LABELS=$(jq -r '(.labels // []) | map(.name) | join(", ")' "$ISSUE_JSON")

      cat > "$PROMPT_FILE" <<EOF
      ## Issue #{{ inputs.issue_number }}: ${TITLE}

      **Labels**: ${LABELS}

      ### Description
      ${BODY}

      ### Requirements
      1. Read the codebase to understand the relevant code
      2. Implement the fix/feature as described
      3. Write or update tests
      4. Ensure all tests pass
      5. Commit your changes with a descriptive message
      EOF

      bash skills/turing-coding-orchestrator/scripts/launch.sh \
        "$TASK_ID" "$WORKTREE" "$PROMPT_FILE"
    on_failure:
      - action: notify
        message: "Agent launch failed for issue #{{ inputs.issue_number }}"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 4: Wait for Completion
  # -------------------------------------------------------------------------
  - name: wait-for-completion
    description: "Monitor agent until callback received"
    depends_on: [launch-agent]
    action: wait
    condition: |
      # Check for callback file created by watchdog
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"
      test -f "$CALLBACK_FILE"
    timeout: 3600  # 1 hour max
    poll_interval: 30  # Check every 30 seconds
    on_timeout:
      - action: notify
        message: "Agent timed out on issue #{{ inputs.issue_number }} (1 hour limit)"
      - action: shell
        command: |
          TASK_ID="{{ stages.setup.outputs.task_id }}"
          # Capture final state for debugging
          tmux -S /tmp/openclaw-tmux/openclaw.sock capture-pane -p \
            -t "$TASK_ID" -S -100 > ".clawdbot/${TASK_ID}-timeout-capture.txt" 2>/dev/null || true

  # -------------------------------------------------------------------------
  # Stage 5: Verify Results
  # -------------------------------------------------------------------------
  - name: verify
    description: "Validate callback and run independent test verification"
    depends_on: [wait-for-completion]
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"
      WORKTREE="{{ stages.setup.outputs.worktree }}"

      # Read callback
      STATUS=$(jq -r '.status' "$CALLBACK_FILE")
      FAILED=$(jq -r '.test_results.failed // 0' "$CALLBACK_FILE")

      if [ "$STATUS" != "completed" ]; then
        echo "VERIFY_RESULT=not_completed"
        exit 1
      fi

      if [ "$FAILED" -gt 0 ]; then
        echo "VERIFY_RESULT=tests_failing"
        exit 1
      fi

      # Independent test verification
      cd "$WORKTREE"
      if [ -f package.json ]; then
        npm test || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f Makefile ] && grep -q '^test:' Makefile; then
        make test || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f pytest.ini ] || [ -d tests ] || [ -f setup.py ]; then
        pytest || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      elif [ -f go.mod ]; then
        go test ./... || { echo "VERIFY_RESULT=independent_tests_failed"; exit 1; }
      fi

      echo "VERIFY_RESULT=passed"
    outputs:
      verify_result: "passed"
    on_failure:
      - action: notify
        message: "Verification failed for issue #{{ inputs.issue_number }}"
      # Don't abort — let the gate stage handle it

  # -------------------------------------------------------------------------
  # Stage 6: Approval Gate (Optional)
  # -------------------------------------------------------------------------
  - name: approval-gate
    description: "Optional human approval before PR creation"
    depends_on: [verify]
    skip_if: "{{ not inputs.require_approval }}"
    action: approval
    prompt: |
      Issue #{{ inputs.issue_number }} has been completed by the coding agent.

      Callback summary:
      {{ read_file('.clawdbot/' + stages.setup.outputs.task_id + '-callback.json') }}

      Create PR?
    approvers: ["user"]
    timeout: 86400  # 24 hours
    on_denied:
      - action: notify
        message: "PR creation denied for issue #{{ inputs.issue_number }}"
      - action: abort

  # -------------------------------------------------------------------------
  # Stage 7: Create PR
  # -------------------------------------------------------------------------
  - name: create-pr
    description: "Create pull request on GitHub"
    depends_on: [approval-gate]
    skip_if: "{{ not inputs.auto_pr }}"
    action: shell
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      BRANCH="{{ stages.setup.outputs.branch }}"
      CALLBACK_FILE=".clawdbot/${TASK_ID}-callback.json"

      TITLE=$(jq -r '.title // "No title"' /tmp/issue-{{ inputs.issue_number }}.json)
      SUMMARY=$(jq -r '.summary // "No summary"' "$CALLBACK_FILE")
      FILES=$(jq -r '.files_changed // [] | map("- `" + . + "`") | join("\n")' "$CALLBACK_FILE")
      PASSED=$(jq -r '.test_results.passed // 0' "$CALLBACK_FILE")
      FAILED=$(jq -r '.test_results.failed // 0' "$CALLBACK_FILE")
      SKIPPED=$(jq -r '.test_results.skipped // 0' "$CALLBACK_FILE")

      # Push branch
      cd "{{ stages.setup.outputs.worktree }}"
      git push -u origin "$BRANCH"

      # Create PR
      gh pr create \
        --title "fix: ${TITLE}" \
        --body "Closes #{{ inputs.issue_number }}

      ## Summary
      ${SUMMARY}

      ## Changes
      ${FILES}

      ## Test Results
      - Passed: ${PASSED}
      - Failed: ${FAILED}
      - Skipped: ${SKIPPED}

      ---
      *Automated by turing-coding-orchestrator*" \
        --base "{{ inputs.base_branch }}" \
        --head "$BRANCH"
    outputs:
      pr_url: "$(gh pr view --json url -q .url)"
    on_failure:
      - action: notify
        message: "PR creation failed for issue #{{ inputs.issue_number }}"

  # -------------------------------------------------------------------------
  # Stage 8: Notify
  # -------------------------------------------------------------------------
  - name: notify-completion
    description: "Send completion notification to user"
    depends_on: [create-pr]
    action: notify
    channel: "{{ inputs.notify_channel }}"
    message: |
      Issue #{{ inputs.issue_number }} resolved!
      PR: {{ stages.create-pr.outputs.pr_url }}
      {{ jq('.summary', read_file('.clawdbot/' + stages.setup.outputs.task_id + '-callback.json')) }}

  # -------------------------------------------------------------------------
  # Stage 9: Cleanup
  # -------------------------------------------------------------------------
  - name: cleanup
    description: "Remove worktree and clean up temporary files"
    depends_on: [notify-completion]
    action: shell
    always_run: true  # Run even if previous stages failed
    command: |
      TASK_ID="{{ stages.setup.outputs.task_id }}"
      WORKTREE="{{ stages.setup.outputs.worktree }}"

      # Kill tmux session if still running
      tmux -S /tmp/openclaw-tmux/openclaw.sock kill-session -t "$TASK_ID" 2>/dev/null || true

      # Kill watchdog if running
      WATCHDOG_PID_FILE=".clawdbot/${TASK_ID}-watchdog.pid"
      if [ -f "$WATCHDOG_PID_FILE" ]; then
        kill "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null || true
        rm -f "$WATCHDOG_PID_FILE"
      fi

      # Remove worktree
      git worktree remove "$WORKTREE" --force 2>/dev/null || true

      # Clean up temp files
      rm -f "/tmp/issue-{{ inputs.issue_number }}.json"
      rm -f "/tmp/${TASK_ID}-prompt.md"
      rm -f ".clawdbot/${TASK_ID}-prompt.md"

      # Keep callback JSON and logs for history
      echo "Cleanup complete for ${TASK_ID}"
