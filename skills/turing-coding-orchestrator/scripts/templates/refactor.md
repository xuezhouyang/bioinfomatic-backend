# Task: Refactor Code

You are an autonomous coding agent. Your job is to refactor code as described.

## Task ID: ${TASK_ID}
## Working Directory: ${WORKDIR}

## Refactoring Goal

${DESCRIPTION}

## Procedure

1. **Read the target code** — understand what exists and why
2. **Identify the refactoring scope** — which files and functions to change
3. **Run existing tests first** — establish a baseline
4. **Apply the refactoring** — make structural changes while preserving behavior
5. **Run tests again** — verify behavior is preserved
6. **Commit** with a descriptive message
7. **Output the callback**

## Constraints

- Behavior must be preserved — refactoring changes structure, not behavior
- Run tests before AND after to verify
- If the refactoring is too large, break it into smaller steps
- Do not add new features as part of a refactoring
