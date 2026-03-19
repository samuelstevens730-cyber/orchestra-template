# Plan: orchestra.sh v1 Bug Fixes — Windows Compatibility & Workflow Correctness

- **Date:** 2026-03-19
- **Author:** Claude (Architect)
- **Status:** DRAFT (revised after Codex APPROVED_WITH_CHANGES — 2026-03-19)

## Problem

Six bugs identified during initial code review (Codex, session 1) prevent reliable use on Windows and break core traceability guarantees:

1. VS Code tasks invoke `orchestra.sh` with no shell specified — defaults to PowerShell on Windows, breaking all tasks.
2. Plan revision loop calls `phase_plan` after Codex feedback, creating a new plan file instead of revising the existing one — breaks review continuity and the "locked after approval" guarantee.
3. `latest_file()` sorts by filename string, not modification time — selects the wrong plan when multiple plans exist on the same date.
4. Session close gathers every review file ever written, not just the current session's — pollutes Gemini's close prompt with stale history, worsening context drift.
5. Implementation phase streams Codex output to stdout only — no artifact is saved, losing the deviation log and "files changed" summary.
6. `CLAUDE.md` documents plan naming as `YYYY-MM-DD-short-description.md` but the script writes `plan-YYYY-MM-DD-slug.md` — docs and code are out of sync from day one.

Additionally, `history/` subdirectories (`decisions/`, `sessions/`, `research/`) are referenced in the README and Gemini's soul but don't exist in the template. Two malformed literal directories also exist from a failed brace-expansion bootstrap: `.orchestra/{souls,context,plans,reviews,history` and `.orchestra/history/{decisions,sessions,research}` — both are empty and must be deleted.

## Goal

All six bugs are fixed, naming convention is consistent across code and docs, the `history/` directories exist, and the malformed brace-expansion directories are removed. The workflow runs end-to-end in VS Code on Windows (requires Git for Windows with bash on PATH, which is the default installation option) without any manual shell reconfiguration.

## Affected Files / Modules

- `.vscode/tasks.json` — add explicit bash shell option to all 6 task definitions
- `.orchestra/scripts/orchestra.sh` — fix `latest_file()`, plan revision loop, implementation artifact, session close scope
- `CLAUDE.md` — align plan naming convention to match script
- `.orchestra/history/decisions/.gitkeep` — create (new file)
- `.orchestra/history/sessions/.gitkeep` — create (new file)
- `.orchestra/history/research/.gitkeep` — create (new file)
- `.orchestra/{souls,context,plans,reviews,history` — delete (malformed literal directory)
- `.orchestra/history/{decisions,sessions,research}` — delete (malformed literal directory)

## Implementation Steps

### Step 1 — `.vscode/tasks.json`: Add bash shell to all tasks

Add an `"options"` block to each of the 6 task objects:

```json
"options": {
  "shell": {
    "executable": "bash",
    "args": ["-c"]
  }
}
```

Insert this after `"group": "none"` in every task. Full example structure:

```json
{
  "label": "🎼 Orchestra: Full Workflow (Interactive)",
  "type": "shell",
  "command": "./.orchestra/scripts/orchestra.sh",
  "group": "none",
  "options": {
    "shell": {
      "executable": "bash",
      "args": ["-c"]
    }
  },
  "presentation": {
    "reveal": "always",
    "panel": "dedicated",
    "focus": true
  },
  "problemMatcher": []
}
```

Apply identically to all 6 tasks.

---

### Step 2 — `latest_file()`: Sort by modification time, guard empty case

Replace the current body with:

```bash
local matched
matched=$(find "$dir" -name "$pattern" ! -name '_TEMPLATE*' -type f 2>/dev/null)
[ -z "$matched" ] && echo "" && return
echo "$matched" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -1
```

Explanation:
- Collect matching files into `matched` first.
- If none found, return empty string immediately. Callers already guard with `if [ -z "$..." ]`, so this is safe and correct.
- `tr '\n' '\0' | xargs -0 ls -t` passes the file list to `ls -t`, which sorts by modification time (newest first). This avoids the `xargs` empty-stdin edge case (BSD `xargs` without `-r` runs the command with no args if stdin is empty).
- Filenames are slugs with no spaces or newlines, so the `echo "$matched"` approach is safe for this project.

This is portable across macOS, Linux, and Git Bash on Windows.

---

### Step 3 — Plan revision loop: Remove `phase_plan`, show plan path

In the `interactive)` case of `main()`, the current structure is:

```
phase_plan          ← runs once before loop
while true:
  gate(...)         ← gate before every review (redundant after first iteration)
  phase_review_plan
  if APPROVED: break
  ...
  gate(...)
  phase_plan        ← BUG: creates a new plan file
done
```

The fix restructures to:

```
phase_plan          ← runs once, unchanged

gate "Planning" "Plan Review" ""   ← move outside loop (fires once, before first review)

while true:
  phase_review_plan
  parse verdict
  if APPROVED:
    gate "Plan Review (APPROVED)" "Implementation" ""
    break
  increment loop / circuit break
  show verdict warning
  show plan file path for human to edit
  gate "Plan Revision Needed" "Plan Re-Review" ""
  ← loop naturally returns to phase_review_plan
done
```

Specific changes to `orchestra.sh`:

1. Move `gate "Planning" "Plan Review" ""` to just before the `while true` loop (remove it from inside the loop).
2. Delete the `phase_plan` call at the end of the loop body (the last ~3 lines before `done`).
3. Before the `gate "Plan Revision Needed"` call, add these two lines so the human knows which file to edit:
   ```bash
   local current_plan
   current_plan=$(latest_file "$PLANS_DIR")
   prompt "Plan file to edit: $current_plan"
   ```
4. Change the `gate` call to: `gate "Plan Revision Needed" "Plan Re-Review" ""`

The gate's second argument is display-only. After the human presses `[c]`, the `while true` loop returns to `phase_review_plan` automatically — no other control flow change needed.

---

### Step 4 — `phase_implement()`: Save implementation artifact

After the `info "Implementing plan: ..."` line, derive an artifact path from the plan filename and `tee` to it.

**Naming convention (uniform across Steps 4 and 5):** Strip `.md` from the plan basename, then append `.md` explicitly when constructing artifact filenames. This makes the derivation unambiguous.

```bash
local plan_basename
plan_basename=$(basename "$plan_file" .md)          # e.g. "plan-2026-03-19-add-auth"
local impl_log="$REVIEWS_DIR/impl-log-${plan_basename}.md"   # → "impl-log-plan-2026-03-19-add-auth.md"
```

Change the Codex invocation from:
```bash
$CODEX_CMD "$(cat "$tmp_prompt")" 2>&1
```
To:
```bash
$CODEX_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$impl_log"
```

After the invocation, add:
```bash
info "Implementation log saved to: $impl_log"
```

If implement runs multiple times for the same plan, the log is overwritten — acceptable, latest run is the relevant one.

---

### Step 5 — `phase_close()`: Scope artifacts to current session

Replace the current review-gathering loop:

```bash
for f in "$REVIEWS_DIR"/*.md; do
  if [ -f "$f" ] && [[ "$f" != *"_TEMPLATE"* ]]; then
    artifacts+="$f "
  fi
done
```

With a targeted lookup keyed on the current plan's basename. **Use the same naming convention as Step 4: strip `.md`, then append it explicitly.**

```bash
if [ -n "$latest_plan" ]; then
  local plan_basename
  plan_basename=$(basename "$latest_plan" .md)      # e.g. "plan-2026-03-19-add-auth"
  for prefix in "review-plan-" "impl-log-" "review-impl-"; do
    local candidate="$REVIEWS_DIR/${prefix}${plan_basename}.md"   # → "review-plan-plan-2026-03-19-add-auth.md" etc.
    if [ -f "$candidate" ]; then
      artifacts+="$candidate "
    fi
  done
fi
```

This picks up exactly the three artifacts that belong to the current plan: the plan review, the implementation log, and the implementation review. Nothing else.

Cross-check: `phase_review_plan` names its output `review-plan-$(basename "$plan_file")` which includes `.md`, producing e.g. `review-plan-plan-2026-03-19-add-auth.md`. Step 5's lookup of `review-plan-${plan_basename}.md` where `plan_basename` = `plan-2026-03-19-add-auth` produces the same filename. ✓

---

### Step 6 — `CLAUDE.md`: Align plan naming convention

In `CLAUDE.md`, the Plans section currently says:

> Save completed plans to `.orchestra/plans/` with the naming convention: `YYYY-MM-DD-short-description.md`

Change to:

> Save completed plans to `.orchestra/plans/` with the naming convention: `plan-YYYY-MM-DD-short-description.md`

---

### Step 7 — Remove malformed brace-expansion directories

Two empty directories were created by a failed brace-expansion bootstrap and must be deleted:

```bash
rmdir ".orchestra/{souls,context,plans,reviews,history"
rmdir ".orchestra/history/{decisions,sessions,research}"
```

Both are confirmed empty. If either `rmdir` fails because a directory is not empty, stop and flag — do not use `rm -rf`.

---

### Step 8 — Create `history/` directory structure

Create the following files (empty, for git tracking):

- `.orchestra/history/decisions/.gitkeep`
- `.orchestra/history/sessions/.gitkeep`
- `.orchestra/history/research/.gitkeep`

## Risks

- The empty-case guard in `latest_file()` (Step 2) uses `echo "$matched" | tr '\n' '\0'`. If a filename somehow contained a newline (impossible with our slug convention), this would corrupt the list. This is acceptable given the naming constraints enforced by `timestamped_name()`.
- Moving the `gate "Planning" "Plan Review"` outside the loop removes a gate that previously fired on every revision loop iteration. This was double-gating (confirming to start review, then again to "retry"). The new behavior fires once before the first review, then loops with a single gate at the revision step. This is correct UX.
- Overwriting the impl log on repeated `phase_implement` runs is intentional. Codex should not add deduplication logic.
- The malformed directory names contain `{` and `,` characters which are special in some shells. Using `rmdir` with the literal quoted path is safe; do not use glob expansion on these names.

## Non-Goals

- No PowerShell wrapper or WSL-specific logic
- No changes to soul files, context files, or templates
- No automation of Gemini's file writes during session close (future enhancement)
- No model-specific config directories (`.claude/`, `.codex/`, `.gemini/`)
- No changes to README beyond what's implied by the history dir creation

## Acceptance Criteria

- [ ] All 6 VS Code tasks in `tasks.json` include `"options": {"shell": {"executable": "bash", "args": ["-c"]}}`
- [ ] `latest_file()` uses `ls -t` (mtime sort), not `sort -r` (lexicographic)
- [ ] In interactive mode after a BLOCKED/APPROVED_WITH_CHANGES verdict, the loop does NOT call `phase_plan`; it shows the current plan file path and returns to `phase_review_plan`
- [ ] After `phase_implement` runs, a file named `impl-log-plan-YYYY-MM-DD-slug.md` exists in `.orchestra/reviews/`
- [ ] `phase_close` only passes the current plan + its three matched review/log files to Gemini — not all historical review files
- [ ] `CLAUDE.md` plan naming reads `plan-YYYY-MM-DD-short-description.md`
- [ ] `.orchestra/history/decisions/`, `.orchestra/history/sessions/`, and `.orchestra/history/research/` directories exist (with `.gitkeep`)
- [ ] `.orchestra/{souls,context,plans,reviews,history` directory no longer exists
- [ ] `.orchestra/history/{decisions,sessions,research}` directory no longer exists

## Definition of Done

- [ ] Code implemented per steps above
- [ ] Implementation reviewed and PASSED by Claude
- [ ] No regressions introduced
- [ ] Context files updated by Gemini
