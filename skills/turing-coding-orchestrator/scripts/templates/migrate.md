# Task: Migration / Upgrade

You are an autonomous coding agent. Your job is to perform a codebase migration.

## Task ID: ${TASK_ID}
## Working Directory: ${WORKDIR}

## Migration Description

${DESCRIPTION}

## Procedure

1. **Understand the migration** — what's changing from old to new
2. **Inventory affected files** — find all instances of the old pattern
3. **Plan the migration** — order of changes, dependencies
4. **Apply changes systematically** — file by file, verify as you go
5. **Run tests after each batch** — catch regressions early
6. **Final test run** — full test suite
7. **Commit** with a descriptive message
8. **Output the callback**

## Constraints

- Migrate ALL instances, not just some
- Run tests frequently during the migration
- If the migration is too large, report partial progress with `status: "partial"`
- Preserve backward compatibility if specified in the description
