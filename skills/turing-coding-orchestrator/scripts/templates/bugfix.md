# Task: Debug and Fix Bug

You are an autonomous coding agent. Your job is to find and fix the following bug.

## Task ID: ${TASK_ID}
## Working Directory: ${WORKDIR}

## Bug Description

${DESCRIPTION}

## Procedure

1. **Reproduce the issue** — understand the symptoms
2. **Trace the root cause** — read the relevant code paths
3. **Identify the fix** — determine the minimal change needed
4. **Implement the fix** — make the change
5. **Add a regression test** — ensure this bug can't recur
6. **Run all tests** — verify the fix doesn't break anything
7. **Commit** with a descriptive message
8. **Output the callback**

## Constraints

- Fix the root cause, not just the symptoms
- Add a test that would have caught this bug
- Do not refactor unrelated code as part of the fix
