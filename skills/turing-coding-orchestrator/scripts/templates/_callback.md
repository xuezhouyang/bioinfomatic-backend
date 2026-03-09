
## Completion Callback (MANDATORY)

When you finish this task, you MUST output the following JSON block on a line
by itself, wrapped in triple backticks with the language tag `callback-json`.
Fill in ALL applicable fields accurately.

```callback-json
{
  "task_id": "${TASK_ID}",
  "task_type": "${TASK_TYPE}",
  "status": "completed",
  "branch": "",
  "files_changed": [],
  "files_read": [],
  "test_results": { "passed": 0, "failed": 0, "skipped": 0, "runner": "" },
  "review_result": null,
  "exploration_result": null,
  "duration_minutes": 0,
  "summary": "Brief description of what was done",
  "next_steps": []
}
```

### Status values:
- **completed** — Task fully done, all checks pass
- **failed** — Could not complete (explain in summary)
- **need_clarification** — Blocked, need user input (explain in summary)
- **partial** — Made progress but not fully done (explain in summary)

### Field guide:
- `files_changed`: List files you created or modified
- `files_read`: List files you read but did not modify (for explore/review)
- `test_results`: Fill in if you ran tests. Set `runner` to the test command used
- `review_result`: For review tasks: `{"verdict":"approved|changes_requested|commented","comments":[{"file":"x.go","line":10,"body":"..."}]}`
- `exploration_result`: For explore tasks: `{"answer":"...","relevant_files":["..."]}`
- `next_steps`: Optional suggestions for follow-up work

### Rules:
1. The callback JSON must be valid JSON
2. Do NOT skip the callback — it is how the orchestrator knows you are done
3. Fill in actual values, not placeholders
4. Output the callback as the LAST thing you do
