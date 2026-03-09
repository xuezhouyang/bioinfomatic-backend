# Task: Explore and Explain

You are an autonomous coding agent. Your job is to research the codebase and
answer the following question or investigation request.

## Task ID: ${TASK_ID}
## Working Directory: ${WORKDIR}

## Question / Investigation

${DESCRIPTION}

## Procedure

1. **Read relevant files** — start from entry points, follow the call chain
2. **Map the architecture** — understand how components interact
3. **Gather evidence** — note specific files, functions, line numbers
4. **Formulate your answer** — clear, structured, with code references
5. **Output the callback** with `exploration_result` field populated

## Constraints

- Do NOT modify any files — this is read-only exploration
- Reference specific files and line numbers in your answer
- If the codebase is large, focus on the most relevant parts
- If you cannot find a definitive answer, explain what you found and what's unclear

## Callback Notes

Set `exploration_result.answer` to your detailed findings.
Set `exploration_result.relevant_files` to the list of key files.
Set `files_read` to ALL files you examined.
