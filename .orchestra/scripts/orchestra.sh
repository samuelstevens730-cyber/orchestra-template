#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Orchestra — Semi-Automated Multi-Agent Workflow
# ============================================================================
# Usage: ./orchestra.sh [phase]
# Phases: plan | review-plan | implement | review-impl | close
# If no phase specified, starts interactive mode and walks through all phases.
# ============================================================================

# --- Configuration -----------------------------------------------------------
# Adjust these to match your CLI installations.
# Each command should accept a prompt string and output to stdout.

CLAUDE_CMD="claude -p"                    # Claude Code CLI (one-shot prompt mode)
CODEX_CMD="codex exec"                    # Codex for reviews (read-only sandbox)
CODEX_IMPL_CMD="codex --full-auto"        # Codex for implementation (file writes allowed)
GEMINI_STDIN_CMD="gemini"                 # Gemini CLI — prompt via stdin (all Gemini calls use this)

# Circuit breaker: max revision loops before forcing human intervention
MAX_PLAN_LOOPS=2             # Max Claude↔Codex plan revision cycles
MAX_IMPL_LOOPS=2             # Max Codex→Claude impl revision cycles

# --- Paths -------------------------------------------------------------------
ORCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT_DIR="$ORCH_DIR/context"
SOULS_DIR="$ORCH_DIR/souls"
PLANS_DIR="$ORCH_DIR/plans"
REVIEWS_DIR="$ORCH_DIR/reviews"
FEEDBACK_DIR="$ORCH_DIR/feedback"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Helpers -----------------------------------------------------------------
banner() {
  echo ""
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  🎼 Orchestra — $1${NC}"
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
  echo ""
}

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
prompt()  { echo -e "${BOLD}$1${NC}"; }

# Human gate — pauses for review and asks how to proceed
# Returns: 0=continue, 1=retry, 2=feedback given (re-run current phase)
gate() {
  local phase_name="$1"
  local next_phase="$2"
  local retry_phase="${3:-}"
  local phase_slug="${4:-unknown}"   # used for feedback file naming

  _gate_display() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    prompt "🚦 GATE: $phase_name complete. Review the output above."
    echo ""
    echo "  [c] Continue to $next_phase"
    if [ -n "$retry_phase" ]; then
      echo "  [r] Retry $retry_phase (loop back)"
    fi
    echo "  [f] Provide feedback — re-run this phase with your input"
    echo "  [n] Nuclear option — invoke Gemini to reconcile disagreements"
    echo "  [s] Stop here (resume later)"
    echo "  [q] Quit"
    echo ""
  }

  _gate_display

  while true; do
    read -rp "→ " choice </dev/tty
    case "$choice" in
      c|C) return 0 ;;
      r|R)
        if [ -n "$retry_phase" ]; then
          return 1
        else
          echo "  Retry not available at this gate."
        fi
        ;;
      f|F)
        collect_human_feedback "$phase_slug"
        return 2
        ;;
      n|N)
        phase_nuclear "$phase_slug"
        # Re-display gate after nuclear so user can continue or add more feedback
        _gate_display
        ;;
      s|S)
        info "Stopping. Resume by running: ./orchestra.sh"
        exit 0
        ;;
      q|Q)
        info "Quitting."
        exit 0
        ;;
      *) echo "  Invalid choice. Enter c, r, f, n, s, or q." ;;
    esac
  done
}

# Assemble context for a model (reads relevant files, prepends soul)
assemble_context() {
  local soul_file="$1"
  local extra_files="${2:-}"
  local context=""
  
  # Soul file
  if [ -f "$soul_file" ]; then
    context+="$(cat "$soul_file")"
    context+=$'\n\n---\n\n'
  fi
  
  # Core context files
  for f in REPO_CONTEXT.md PROJECT_STATE.md DECISIONS.md OPEN_LOOPS.md; do
    if [ -f "$CONTEXT_DIR/$f" ]; then
      context+="## $f"$'\n'
      context+="$(cat "$CONTEXT_DIR/$f")"
      context+=$'\n\n---\n\n'
    fi
  done
  
  # Extra files (plan packets, reviews, etc.)
  if [ -n "$extra_files" ]; then
    for f in $extra_files; do
      if [ -f "$f" ]; then
        context+="## $(basename "$f")"$'\n'
        context+="$(cat "$f")"
        context+=$'\n\n---\n\n'
      fi
    done
  fi
  
  echo "$context"
}

# Get the latest file matching a pattern in a directory
latest_file() {
  local dir="$1"
  local pattern="${2:-*.md}"
  local matched

  # Exclude template files
  matched=$(find "$dir" -name "$pattern" ! -name '_TEMPLATE*' -type f 2>/dev/null)
  [ -z "$matched" ] && echo "" && return

  echo "$matched" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -1
}

# Parse a structured verdict from model output
# Looks for [VERDICT: STATUS] blocks or falls back to keyword detection
parse_verdict() {
  local file="$1"
  local content
  content=$(cat "$file")
  
  # First try: structured block [VERDICT: STATUS]
  local verdict
  verdict=$(echo "$content" | grep -oP '\[VERDICT:\s*\K[A-Z_]+(?=\])' | tail -1)
  
  if [ -n "$verdict" ]; then
    echo "$verdict"
    return
  fi
  
  # Fallback: look for known verdict keywords on their own line or after "Verdict:"
  verdict=$(echo "$content" | grep -oP '(?:Verdict:\s*)\K(APPROVED_WITH_CHANGES|APPROVED|BLOCKED|PASS_WITH_FIXES|PASS|FAIL)' | tail -1)
  
  if [ -n "$verdict" ]; then
    echo "$verdict"
    return
  fi
  
  # Last resort: scan for keywords anywhere
  if echo "$content" | grep -q "BLOCKED"; then
    echo "BLOCKED"
  elif echo "$content" | grep -q "APPROVED_WITH_CHANGES"; then
    echo "APPROVED_WITH_CHANGES"
  elif echo "$content" | grep -q "APPROVED"; then
    echo "APPROVED"
  elif echo "$content" | grep -q "FAIL"; then
    echo "FAIL"
  elif echo "$content" | grep -q "PASS_WITH_FIXES"; then
    echo "PASS_WITH_FIXES"
  elif echo "$content" | grep -q "PASS"; then
    echo "PASS"
  else
    echo "UNKNOWN"
  fi
}

# Circuit breaker — tripped when agents cannot converge within MAX loops.
# Instead of exiting immediately, presents a deadlock gate so the human can
# invoke nuclear reconciliation ([n]) or override and continue ([c]).
# Returns 0 if the human chooses to continue — caller must reset its loop counter.
circuit_break() {
  local phase_name="$1"
  local loop_count="$2"
  local max_loops="$3"
  local plan_file="${4:-}"
  local phase_slug="${5:-unknown}"

  error "═══════════════════════════════════════════════════════"
  error "  CIRCUIT BREAKER TRIPPED"
  error "  Phase: $phase_name"
  error "  Loops exhausted: $loop_count / $max_loops"
  error "═══════════════════════════════════════════════════════"
  echo ""
  warn "Claude and Codex could not reach agreement within $max_loops revision cycles."
  echo ""

  # Log to OPEN_LOOPS.md
  local loop_id="LOOP-$(date +%Y%m%d%H%M%S)"
  local loop_entry="
### $loop_id: Circuit breaker — $phase_name deadlock
- **Opened:** $(date +%Y-%m-%d)
- **Context:** $phase_name failed to converge after $loop_count revision cycles. Plan file: $(basename "${plan_file:-unknown}")
- **Waiting on:** Human review to break the tie between Claude and Codex
- **Priority:** High
"
  # Append under ## Open
  sed -i "/^## Open$/a\\$loop_entry" "$CONTEXT_DIR/OPEN_LOOPS.md" 2>/dev/null || \
    echo "$loop_entry" >> "$CONTEXT_DIR/OPEN_LOOPS.md"

  info "Logged to OPEN_LOOPS.md as $loop_id"
  echo ""

  # Deadlock gate — nuclear can rescue the loop; [c] lets human override.
  # Returning 0 signals to the caller that the loop counter should be reset.
  _cb_display() {
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    prompt "🚫 DEADLOCK — Choose how to proceed:"
    echo ""
    echo "  [n] Nuclear — invoke Gemini to reconcile, then continue (resets loop)"
    echo "  [c] Override — continue anyway without reconciliation (resets loop)"
    echo "  [s] Stop here (resume later)"
    echo "  [q] Quit"
    echo ""
  }

  _cb_display

  while true; do
    read -rp "→ " choice </dev/tty
    case "$choice" in
      n|N)
        phase_nuclear "$phase_slug"
        _cb_display
        ;;
      c|C)
        info "Overriding circuit breaker. Loop counter reset — continuing."
        return 0
        ;;
      s|S)
        info "Stopping. Resume by running: ./orchestra.sh"
        exit 0
        ;;
      q|Q)
        info "Quitting."
        exit 0
        ;;
      *) echo "  Enter n, c, s, or q." ;;
    esac
  done
}

# Generate a timestamped filename
timestamped_name() {
  local prefix="$1"
  local slug="$2"
  echo "${prefix}-$(date +%Y-%m-%d)-${slug}.md"
}

# Extract content between exact delimiter lines from a file
extract_section() {
  local file="$1"
  local start="$2"
  local end="$3"
  sed -n "/^${start}$/,/^${end}$/{/^${start}$/d;/^${end}$/d;p}" "$file"
}

# Ensure all required directories exist
init_dirs() {
  mkdir -p "$PLANS_DIR" "$REVIEWS_DIR" "$FEEDBACK_DIR" \
           "$ORCH_DIR/history/sessions" "$ORCH_DIR/history/decisions" \
           "$ORCH_DIR/history/research"
}

# Return all feedback files (human notes + reconciled outputs), sorted by timestamp
collect_feedback_files() {
  find "$FEEDBACK_DIR" -name "*.md" -type f 2>/dev/null | sort
}

# Prompt the human for multi-line feedback and save it to the feedback dir
collect_human_feedback() {
  local phase_slug="$1"
  local feedback_file="$FEEDBACK_DIR/feedback-${phase_slug}-$(date +%Y%m%d%H%M%S).md"

  echo ""
  echo -e "${BOLD}Enter your feedback (blank line to finish):${NC}"
  echo ""

  local lines=()
  local line
  while IFS= read -r line </dev/tty; do
    [[ -z "$line" ]] && break
    lines+=("$line")
  done

  {
    echo "## Human Feedback — Phase: $phase_slug — $(date '+%Y-%m-%d %H:%M')"
    echo ""
    printf '%s\n' "${lines[@]}"
  } > "$feedback_file"

  info "Feedback saved → $(basename "$feedback_file")"
}

# Format feedback files for a given phase into a prompt-injectable block (empty string if none)
# Phase-scoped: only injects files named feedback-{phase_slug}-* or reconciled-{phase_slug}-*
# This prevents stale feedback from earlier tasks or unrelated phases from bleeding in.
inject_feedback_section() {
  local phase_slug="${1:-}"
  local fb_files

  if [ -n "$phase_slug" ]; then
    # Scoped: only inject feedback belonging to this specific phase
    fb_files=$(find "$FEEDBACK_DIR" \
      \( -name "feedback-${phase_slug}-*.md" -o -name "reconciled-${phase_slug}-*.md" \) \
      -type f 2>/dev/null | sort)
  else
    fb_files=$(collect_feedback_files)
  fi
  [ -z "$fb_files" ] && echo "" && return

  local section
  section=$'\n'"━━━ HUMAN FEEDBACK — AUTHORITATIVE CONSTRAINTS (address every point) ━━━"$'\n\n'
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    section+="$(cat "$f")"$'\n\n'
  done <<< "$fb_files"
  section+="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"$'\n'
  echo "$section"
}

# Nuclear option — invoke Gemini as a neutral reconciler when humans and agents disagree
phase_nuclear() {
  local phase_slug="${1:-unknown}"
  banner "☢️  Nuclear Option — Gemini Reconciliation"

  # Gather every artifact available
  local extra_files=""
  local plan_file; plan_file=$(latest_file "$PLANS_DIR")
  [ -n "$plan_file" ] && extra_files+="$plan_file "

  local plan_review; plan_review=$(latest_file "$REVIEWS_DIR" "review-plan-*")
  [ -n "$plan_review" ] && extra_files+="$plan_review "

  local impl_review; impl_review=$(latest_file "$REVIEWS_DIR" "review-impl-*")
  [ -n "$impl_review" ] && extra_files+="$impl_review "

  # Include feedback files scoped to this phase — same discipline as inject_feedback_section.
  # Prevents plan-phase feedback from contaminating an implementation-review reconciliation.
  local fb_files
  if [ -n "$phase_slug" ] && [ "$phase_slug" != "unknown" ]; then
    fb_files=$(find "$FEEDBACK_DIR" \
      \( -name "feedback-${phase_slug}-*.md" -o -name "reconciled-${phase_slug}-*.md" \) \
      -type f 2>/dev/null | sort)
  else
    fb_files=$(collect_feedback_files)
  fi
  for f in $fb_files; do [ -f "$f" ] && extra_files+="$f "; done

  local context
  context=$(assemble_context "$SOULS_DIR/gemini.soul.md" "$extra_files")

  local reconcile_prompt="You are Gemini, acting as the Reconciler in the Orchestra workflow.

You have been invoked because Claude, Codex, and/or the human stakeholder cannot reach agreement.
Your job: find the path that best satisfies all constraints. Do not simply pick a side — synthesize.

FULL CONTEXT (plan, reviews, and human feedback):
$context

RECONCILIATION TASK:
1. Identify every point of disagreement or conflicting constraint
2. For each conflict: state whose constraint should yield and explain why
3. Produce a RECONCILED RECOMMENDATION — concrete, actionable guidance for the next phase
4. Flag any genuinely unresolvable conflicts explicitly

OUTPUT FORMAT (use exactly these headers):
## Conflicts Identified
[list each conflict clearly — one per bullet]

## Resolution Rationale
[for each conflict: who yields, why, and what the compromise looks like]

## Reconciled Recommendation
[written as instructions to the next phase agent — specific, actionable, unambiguous]

## Unresolvable Conflicts
[only include if constraints truly cannot be reconciled — otherwise omit entirely]"

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$reconcile_prompt" > "$tmp_prompt"

  local reconciled_file="$FEEDBACK_DIR/reconciled-${phase_slug}-$(date +%Y%m%d%H%M%S).md"

  info "Invoking Gemini to reconcile..."
  echo ""

  $GEMINI_STDIN_CMD < "$tmp_prompt" 2>&1 | tee "$reconciled_file"

  rm -f "$tmp_prompt"

  echo ""
  info "Reconciliation saved → $(basename "$reconciled_file")"
  info "Press [c] to continue with this reconciliation injected as context."
  info "Press [f] to add more feedback before continuing."
}

# ============================================================================
# Phase Functions
# ============================================================================

phase_plan() {
  banner "Phase 1: PLAN (Claude)"

  local feedback_section
  feedback_section=$(inject_feedback_section "plan")

  local existing_plan
  existing_plan=$(latest_file "$PLANS_DIR")

  local plan_file task_description task_slug
  local template="$PLANS_DIR/_TEMPLATE.md"

  if [ -n "$feedback_section" ] && [ -n "$existing_plan" ]; then
    # ── Feedback revision mode: human pressed [f], re-run with their notes ──
    info "Revising plan based on human feedback..."
    info "Plan: $(basename "$existing_plan")"
    plan_file="$existing_plan"
    task_slug=$(basename "$existing_plan" .md | sed 's/^plan-[0-9-]*-//')
    task_description="Revise the current plan per the human feedback below."
  else
    # ── New task mode: clear stale artifacts from a previous task ──
    rm -f "$FEEDBACK_DIR"/*.md 2>/dev/null || true
    rm -f "$ORCH_DIR/tmp-impl-baseline.sha" "$ORCH_DIR/tmp-impl-prompt.md" 2>/dev/null || true
    read -rp "Describe the feature/task to plan: " task_description </dev/tty
    read -rp "Short slug for filename (e.g., add-auth, refactor-api): " task_slug </dev/tty
    plan_file="$PLANS_DIR/$(timestamped_name "plan" "$task_slug")"
  fi

  info "Invoking Claude to generate/revise plan..."
  info "Output → $(basename "$plan_file")"
  echo ""

  local context
  context=$(assemble_context "$SOULS_DIR/claude.soul.md")

  # Include existing plan content when revising
  local existing_plan_block=""
  if [ -n "$existing_plan" ] && [ -f "$existing_plan" ] && [ "$plan_file" = "$existing_plan" ]; then
    existing_plan_block="CURRENT PLAN (to be revised):
$(cat "$existing_plan")

---
"
  fi

  local plan_prompt="You are the Architect in the Orchestra workflow.

CONTEXT:
$context

PLAN TEMPLATE:
$(cat "$template")

${existing_plan_block}${feedback_section}TASK:
$task_description

Generate a complete plan packet using the template above. Be specific about files, steps, and acceptance criteria. The plan must be detailed enough that Codex can implement it without asking clarifying questions.${feedback_section:+

ADDRESS ALL HUMAN FEEDBACK POINTS — these are authoritative constraints.}"

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$plan_prompt" > "$tmp_prompt"

  $CLAUDE_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$plan_file"

  rm -f "$tmp_prompt"

  info "Plan saved to: $plan_file"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Review the plan above. Edit $plan_file directly if needed."
}

phase_revise_plan() {
  banner "Plan Revision (Claude)"

  local plan_file
  plan_file=$(latest_file "$PLANS_DIR")

  local review_file
  review_file=$(latest_file "$REVIEWS_DIR" "review-plan-*")

  if [ -z "$plan_file" ]; then
    error "No plan file found."
    exit 1
  fi

  if [ -z "$review_file" ]; then
    error "No plan review found."
    exit 1
  fi

  info "Revising plan based on Codex feedback..."
  info "Plan:   $(basename "$plan_file")"
  info "Review: $(basename "$review_file")"
  echo ""

  local context
  context=$(assemble_context "$SOULS_DIR/claude.soul.md" "$plan_file $review_file")

  local feedback_section
  feedback_section=$(inject_feedback_section "review-plan")

  local revise_prompt="You are the Architect in the Orchestra workflow.

CONTEXT:
$context

${feedback_section}Codex has reviewed your plan and returned feedback (see the review file above).
Revise the plan to address ALL of Codex's feedback${feedback_section:+ AND all human feedback above}.

Rules:
- Address every point Codex raised
- Address every human feedback point (human feedback is authoritative)
- Keep the same plan format and structure
- Do not add scope beyond what feedback requires
- If you disagree with a Codex finding, note the disagreement explicitly in the plan with your rationale

Output the COMPLETE revised plan — not just the changes, the full plan."

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$revise_prompt" > "$tmp_prompt"

  $CLAUDE_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$plan_file"

  rm -f "$tmp_prompt"

  info "Plan revised: $plan_file"
}

phase_review_plan() {
  banner "Phase 2: REVIEW PLAN (Codex)"
  
  local plan_file
  plan_file=$(latest_file "$PLANS_DIR")
  
  if [ -z "$plan_file" ]; then
    error "No plan files found in $PLANS_DIR. Run the plan phase first."
    exit 1
  fi
  
  info "Reviewing plan: $(basename "$plan_file")"
  
  local review_name
  review_name="review-plan-$(basename "$plan_file")"
  local review_file="$REVIEWS_DIR/$review_name"
  local template="$REVIEWS_DIR/_TEMPLATE_PLAN_REVIEW.md"
  
  local context
  context=$(assemble_context "$SOULS_DIR/codex.soul.md" "$plan_file")
  
  local feedback_section
  feedback_section=$(inject_feedback_section "review-plan")

  local review_prompt="You are the Implementer/Reviewer in the Orchestra workflow.

CONTEXT:
$context

${feedback_section}REVIEW TEMPLATE:
$(cat "$template")

Review the plan above against the repo context. Check file paths, integration points, existing patterns, scope, and feasibility. Use the review template to structure your response.${feedback_section:+

NOTE: Human feedback is present above. Verify the plan addresses all human feedback points — flag it as BLOCKED if it does not.}

CRITICAL OUTPUT REQUIREMENT:
End your response with a verdict block on its own line in exactly this format:
[VERDICT: APPROVED] or [VERDICT: APPROVED_WITH_CHANGES] or [VERDICT: BLOCKED]
Do not wrap it in prose. The verdict line must be parseable by automation."

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$review_prompt" > "$tmp_prompt"
  
  info "Invoking Codex to review the plan..."
  echo ""
  
  $CODEX_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$review_file"
  
  rm -f "$tmp_prompt"
  
  info "Review saved to: $review_file"
}

phase_implement() {
  banner "Phase 3: IMPLEMENT (Codex)"

  local plan_file
  plan_file=$(latest_file "$PLANS_DIR")

  if [ -z "$plan_file" ]; then
    error "No plan files found. Run the plan phase first."
    exit 1
  fi

  info "Implementing plan: $(basename "$plan_file")"

  local plan_basename
  plan_basename=$(basename "$plan_file" .md)

  # Assemble the implementation prompt and save it to a context packet
  # so Codex can be run manually in a separate terminal (codex --full-auto
  # is an interactive TUI and cannot be reliably invoked as a subprocess).
  local context
  context=$(assemble_context "$SOULS_DIR/codex.soul.md" "$plan_file")

  local feedback_section
  feedback_section=$(inject_feedback_section "implement")

  local impl_prompt="You are the Implementer in the Orchestra workflow.

CONTEXT:
$context

${feedback_section}The plan above has been APPROVED. Implement it now.

Rules:
- Follow the plan steps exactly
- If you must deviate, document why
- Do not silently redesign the feature
- Flag any blockers immediately
- When done, list all files changed/created${feedback_section:+
- Human feedback is present above — it is authoritative; honour it even if it means a minor deviation from the plan}"

  local tmp_prompt="$ORCH_DIR/tmp-impl-prompt.md"
  echo "$impl_prompt" > "$tmp_prompt"

  # Record the current HEAD SHA as the implementation baseline.
  # phase_review_impl uses this to diff only what Codex changed, not the whole repo.
  local repo_root
  repo_root=$(cd "$ORCH_DIR/.." && pwd)
  if git -C "$repo_root" rev-parse HEAD > /dev/null 2>&1; then
    git -C "$repo_root" rev-parse HEAD > "$ORCH_DIR/tmp-impl-baseline.sha" 2>/dev/null || true
    info "Git baseline SHA recorded for scoped diff in review phase."
  fi

  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  prompt "📋 IMPLEMENT — Manual Step Required"
  echo ""
  local abs_prompt
  abs_prompt=$(realpath "$tmp_prompt" 2>/dev/null || echo "$tmp_prompt")

  echo "  The implementation context packet has been saved to:"
  echo ""
  echo -e "    ${BOLD}${abs_prompt}${NC}"
  echo ""

  echo "  Open a NEW terminal in this project's root and run one of:"
  echo ""
  echo "  bash / Git Bash / WSL:"
  echo -e "    ${BOLD}$CODEX_IMPL_CMD \"\$(cat '$abs_prompt')\"${NC}"
  echo ""
  echo "  PowerShell:"
  echo -e "    ${BOLD}$CODEX_IMPL_CMD (Get-Content '$abs_prompt' -Raw)${NC}"
  echo ""
  echo "  When Codex finishes, return here and press [c] to continue."
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

phase_review_impl() {
  banner "Phase 4: REVIEW IMPLEMENTATION (Claude)"

  local plan_file
  plan_file=$(latest_file "$PLANS_DIR")

  if [ -z "$plan_file" ]; then
    error "No plan files found."
    exit 1
  fi

  local review_name
  review_name="review-impl-$(basename "$plan_file")"
  local review_file="$REVIEWS_DIR/$review_name"
  local template="$REVIEWS_DIR/_TEMPLATE_IMPL_REVIEW.md"

  local context
  context=$(assemble_context "$SOULS_DIR/claude.soul.md" "$plan_file")

  # Collect git diff for reviewer context — scoped to what Codex changed this session.
  # If a baseline SHA was recorded during phase_implement, diff against that; otherwise
  # fall back to HEAD (all uncommitted changes) so the reviewer always gets something.
  local git_diff_section=""
  local repo_root
  repo_root=$(cd "$ORCH_DIR/.." && pwd)
  local plan_basename
  plan_basename=$(basename "$plan_file" .md)

  if git -C "$repo_root" rev-parse --git-dir > /dev/null 2>&1; then
    local baseline_sha=""
    local baseline_sha_file="$ORCH_DIR/tmp-impl-baseline.sha"
    if [ -f "$baseline_sha_file" ]; then
      baseline_sha=$(tr -d '[:space:]' < "$baseline_sha_file")
    fi

    local diff_stat diff_full diff_label
    if [ -n "$baseline_sha" ]; then
      # Compare the WORKING TREE against the baseline commit (not commit-to-commit).
      # This captures all change types in one call:
      #   - Committed changes  (Codex committed)
      #   - Staged changes     (Codex staged but didn't commit)
      #   - Unstaged changes   (Codex edited without staging)
      # ${baseline_sha}..HEAD is intentionally NOT used here — if Codex edits without
      # committing, HEAD == baseline and that range is empty, missing the implementation.
      diff_label="GIT DIFF — Working tree vs implementation baseline (${baseline_sha:0:7}):"
      diff_stat=$(git -C "$repo_root" diff --stat "${baseline_sha}" 2>/dev/null || true)
      diff_full=$(git -C "$repo_root" diff "${baseline_sha}" 2>/dev/null || true)

      if [ -z "$diff_stat" ]; then
        # Worktree is clean vs baseline — check if changes exist only in the index
        # (staged-only workflow where Codex staged without touching the worktree)
        diff_stat=$(git -C "$repo_root" diff --cached --stat "${baseline_sha}" 2>/dev/null || true)
        diff_full=$(git -C "$repo_root" diff --cached "${baseline_sha}" 2>/dev/null || true)
        [ -n "$diff_stat" ] && diff_label="GIT DIFF (staged) — Index vs baseline (${baseline_sha:0:7}):"
      fi

      if [ -n "$diff_stat" ]; then
        git_diff_section="
$diff_label
$diff_stat

FULL DIFF (first 200 lines):
$(echo "$diff_full" | head -200)
"
      else
        git_diff_section="
NOTE: No changes detected vs baseline ${baseline_sha:0:7}.
If Codex committed and this seems wrong, run: git log --oneline ${baseline_sha}..HEAD
"
      fi
    else
      # No baseline recorded — fall back to showing all uncommitted changes vs HEAD
      diff_label="GIT DIFF — Files changed since last commit (no baseline recorded):"
      diff_stat=$(git -C "$repo_root" diff --stat HEAD 2>/dev/null || git -C "$repo_root" diff --stat 2>/dev/null || true)
      diff_full=$(git -C "$repo_root" diff HEAD 2>/dev/null || git -C "$repo_root" diff 2>/dev/null || true)

      if [ -n "$diff_stat" ]; then
        git_diff_section="
$diff_label
$diff_stat

FULL DIFF (first 200 lines):
$(echo "$diff_full" | head -200)
"
      else
        # Try staged changes (maybe Codex staged but didn't commit)
        diff_stat=$(git -C "$repo_root" diff --cached --stat 2>/dev/null || true)
        diff_full=$(git -C "$repo_root" diff --cached 2>/dev/null || true)
        if [ -n "$diff_stat" ]; then
          git_diff_section="
GIT DIFF (staged) — Files staged since last commit:
$diff_stat

FULL STAGED DIFF (first 200 lines):
$(echo "$diff_full" | head -200)
"
        else
          git_diff_section="
NOTE: No git diff available (no changes staged or unstaged vs HEAD).
If Codex committed directly, check 'git log -1 --stat' for the most recent commit.
"
        fi
      fi
    fi
  else
    git_diff_section="
NOTE: This directory is not a git repository. Cannot show diff.
Review changed files manually.
"
  fi

  # Auto-generate impl-log artifact from the git diff so phase_close can include it.
  local impl_log_file="$REVIEWS_DIR/impl-log-${plan_basename}.md"
  {
    echo "# Implementation Log — ${plan_basename}"
    echo ""
    echo "Generated: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "$git_diff_section"
  } > "$impl_log_file"
  info "Impl log generated: $(basename "$impl_log_file")"

  local feedback_section
  feedback_section=$(inject_feedback_section "review-impl")

  local review_prompt="You are the Architect reviewing an implementation in the Orchestra workflow.

CONTEXT AND PLAN:
$context

${feedback_section}WHAT CODEX CHANGED:
$git_diff_section

REVIEW TEMPLATE:
$(cat "$template")

The plan above was implemented by Codex. Review the changes (diff above) against the plan.
Check: plan adherence, acceptance criteria, code quality, and edge cases.
Use the review template.${feedback_section:+

NOTE: Human feedback is present above. Verify the implementation honours all human feedback points — mark as FAIL if it does not.}

CRITICAL OUTPUT REQUIREMENT:
End your response with a verdict block on its own line in exactly this format:
[VERDICT: PASS] or [VERDICT: PASS_WITH_FIXES] or [VERDICT: FAIL]
Do not wrap it in prose. The verdict line must be parseable by automation."

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$review_prompt" > "$tmp_prompt"
  
  info "Invoking Claude to review implementation..."
  echo ""
  
  $CLAUDE_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$review_file"
  
  rm -f "$tmp_prompt"
  
  info "Review saved to: $review_file"
}

phase_close() {
  banner "Phase 5: CLOSE SESSION (Gemini)"

  # Gather all artifacts from this session
  local artifacts=""
  local plan_basename=""
  local latest_plan
  latest_plan=$(latest_file "$PLANS_DIR")
  if [ -n "$latest_plan" ]; then
    artifacts+="$latest_plan "
    plan_basename=$(basename "$latest_plan" .md)
    for prefix in "review-plan-" "impl-log-" "review-impl-"; do
      local candidate="$REVIEWS_DIR/${prefix}${plan_basename}.md"
      if [ -f "$candidate" ]; then
        artifacts+="$candidate "
      fi
    done
  fi

  local context
  context=$(assemble_context "$SOULS_DIR/gemini.soul.md" "$artifacts")

  local close_prompt="You are the Session Closer in the Orchestra workflow.

CONTEXT AND SESSION ARTIFACTS:
$context

CURRENT SESSION LOG:
$(cat "$CONTEXT_DIR/SESSION_LOG.md" 2>/dev/null)

CURRENT PROJECT STATE:
$(cat "$CONTEXT_DIR/PROJECT_STATE.md" 2>/dev/null)

Close this session. Your output MUST use the exact delimiters below — the script parses
these automatically to write the context files. Do not add prose outside the delimited sections.

===SESSION_LOG_ENTRY_START===
[New session log entry — max 20 lines, newest-first format. Will be PREPENDED to SESSION_LOG.md.]
===SESSION_LOG_ENTRY_END===

===DECISIONS_ENTRY_START===
[Any new decisions with full traceability: what/when/why/who/alternatives-rejected/compromises.
If no new decisions this session, output exactly: NONE]
===DECISIONS_ENTRY_END===

===OPEN_LOOPS_CONTENT_START===
[Complete updated content for OPEN_LOOPS.md — add new items, mark resolved ones closed.
If no changes needed, output exactly: UNCHANGED]
===OPEN_LOOPS_CONTENT_END===

===REPO_CONTEXT_CONTENT_START===
[Complete updated content for REPO_CONTEXT.md reflecting structural changes this session.
If no structural changes occurred, output exactly: UNCHANGED]
===REPO_CONTEXT_CONTENT_END===

===PROJECT_STATE_CONTENT_START===
[Complete updated content for PROJECT_STATE.md — move completed tasks to Recently Completed,
update In Flight, update Active Priorities based on what was accomplished this session.
If no changes needed, output exactly: UNCHANGED]
===PROJECT_STATE_CONTENT_END===

===RESEARCH_LOG_ENTRY_START===
[Any new research findings discovered this session (sources, facts, decisions informed by research).
If no research was done this session, output exactly: NONE]
===RESEARCH_LOG_ENTRY_END===

RULES:
- Use EXACTLY these delimiter lines — no variations, no extra text outside them
- Anti-sanitization: record what actually happened, not a polished version
- Every decision MUST include rejected alternatives with real rationale
- Do NOT editorialize in session logs — facts only"

  local tmp_prompt tmp_output
  tmp_prompt=$(mktemp)
  tmp_output=$(mktemp)
  echo "$close_prompt" > "$tmp_prompt"

  info "Invoking Gemini to close the session..."
  echo ""

  $GEMINI_STDIN_CMD < "$tmp_prompt" 2>&1 | tee "$tmp_output"

  rm -f "$tmp_prompt"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Applying context file updates..."
  echo ""

  # SESSION_LOG — prepend new entry
  local session_entry
  session_entry=$(extract_section "$tmp_output" "===SESSION_LOG_ENTRY_START===" "===SESSION_LOG_ENTRY_END===")
  if [ -n "$session_entry" ]; then
    local tmp_log
    tmp_log=$(mktemp)
    { printf "%s\n\n---\n\n" "$session_entry"; cat "$CONTEXT_DIR/SESSION_LOG.md" 2>/dev/null; } > "$tmp_log"
    mv "$tmp_log" "$CONTEXT_DIR/SESSION_LOG.md"
    info "SESSION_LOG.md updated."
  else
    warn "No SESSION_LOG entry found in Gemini output — SESSION_LOG.md not updated."
  fi

  # DECISIONS — append new entries
  local decisions_entry
  decisions_entry=$(extract_section "$tmp_output" "===DECISIONS_ENTRY_START===" "===DECISIONS_ENTRY_END===")
  local decisions_trimmed
  decisions_trimmed=$(echo "$decisions_entry" | tr -d '[:space:]')
  if [ -n "$decisions_entry" ] && [ "$decisions_trimmed" != "NONE" ]; then
    { echo ""; echo "$decisions_entry"; } >> "$CONTEXT_DIR/DECISIONS.md"
    info "DECISIONS.md updated."
  else
    info "No new decisions to record."
  fi

  # OPEN_LOOPS — full replacement if changed
  local open_loops_content
  open_loops_content=$(extract_section "$tmp_output" "===OPEN_LOOPS_CONTENT_START===" "===OPEN_LOOPS_CONTENT_END===")
  local open_loops_trimmed
  open_loops_trimmed=$(echo "$open_loops_content" | tr -d '[:space:]')
  if [ -n "$open_loops_content" ] && [ "$open_loops_trimmed" != "UNCHANGED" ]; then
    echo "$open_loops_content" > "$CONTEXT_DIR/OPEN_LOOPS.md"
    info "OPEN_LOOPS.md updated."
  else
    info "OPEN_LOOPS.md unchanged."
  fi

  # REPO_CONTEXT — full replacement if changed
  local repo_context_content
  repo_context_content=$(extract_section "$tmp_output" "===REPO_CONTEXT_CONTENT_START===" "===REPO_CONTEXT_CONTENT_END===")
  local repo_context_trimmed
  repo_context_trimmed=$(echo "$repo_context_content" | tr -d '[:space:]')
  if [ -n "$repo_context_content" ] && [ "$repo_context_trimmed" != "UNCHANGED" ]; then
    echo "$repo_context_content" > "$CONTEXT_DIR/REPO_CONTEXT.md"
    info "REPO_CONTEXT.md updated."
  else
    info "REPO_CONTEXT.md unchanged."
  fi

  # PROJECT_STATE — full replacement if changed
  local project_state_content
  project_state_content=$(extract_section "$tmp_output" "===PROJECT_STATE_CONTENT_START===" "===PROJECT_STATE_CONTENT_END===")
  local project_state_trimmed
  project_state_trimmed=$(echo "$project_state_content" | tr -d '[:space:]')
  if [ -n "$project_state_content" ] && [ "$project_state_trimmed" != "UNCHANGED" ]; then
    echo "$project_state_content" > "$CONTEXT_DIR/PROJECT_STATE.md"
    info "PROJECT_STATE.md updated."
  else
    info "PROJECT_STATE.md unchanged."
  fi

  # RESEARCH_LOG — append new entries
  local research_entry
  research_entry=$(extract_section "$tmp_output" "===RESEARCH_LOG_ENTRY_START===" "===RESEARCH_LOG_ENTRY_END===")
  local research_trimmed
  research_trimmed=$(echo "$research_entry" | tr -d '[:space:]')
  if [ -n "$research_entry" ] && [ "$research_trimmed" != "NONE" ]; then
    { echo ""; echo "$research_entry"; } >> "$CONTEXT_DIR/RESEARCH_LOG.md"
    info "RESEARCH_LOG.md updated."
  else
    info "No new research to record."
  fi

  # Archive session entry, decisions, and research to history
  local archive_slug="${plan_basename:-$(date +%H%M%S)}"
  local archive_date
  archive_date=$(date +%Y-%m-%d)

  if [ -n "$session_entry" ]; then
    local session_archive="$ORCH_DIR/history/sessions/session-${archive_date}-${archive_slug}.md"
    echo "$session_entry" > "$session_archive"
    info "Session archived to: history/sessions/$(basename "$session_archive")"
  fi

  if [ -n "$decisions_entry" ] && [ "$decisions_trimmed" != "NONE" ]; then
    local decisions_archive="$ORCH_DIR/history/decisions/decisions-${archive_date}-${archive_slug}.md"
    echo "$decisions_entry" > "$decisions_archive"
    info "Decisions archived to: history/decisions/$(basename "$decisions_archive")"
  fi

  if [ -n "$research_entry" ] && [ "$research_trimmed" != "NONE" ]; then
    local research_archive="$ORCH_DIR/history/research/research-${archive_date}-${archive_slug}.md"
    echo "$research_entry" > "$research_archive"
    info "Research archived to: history/research/$(basename "$research_archive")"
  fi

  rm -f "$tmp_output"

  echo ""
  info "Context files updated. Review them in .orchestra/context/ if needed."
}

# ============================================================================
# Main — Interactive Workflow
# ============================================================================

main() {
  local phase="${1:-interactive}"

  # Ensure all directories exist on every run
  init_dirs

  case "$phase" in
    plan)         phase_plan ;;
    review-plan)  phase_review_plan ;;
    implement)    phase_implement ;;
    review-impl)  phase_review_impl ;;
    close)        phase_close ;;
    interactive)
      banner "Interactive Workflow"
      info "This will walk you through the full plan → review → implement → review → close cycle."
      info "You'll have a decision gate after each phase."
      info "Circuit breaker: max $MAX_PLAN_LOOPS plan revision loops, $MAX_IMPL_LOOPS impl revision loops."
      info "At any gate: [f] injects your feedback, [n] invokes Gemini to reconcile disagreements."
      echo ""

      # --- Resume detection ---
      local start_at="1"
      local existing_plan
      existing_plan=$(latest_file "$PLANS_DIR")

      if [ -n "$existing_plan" ]; then
        echo -e "  Existing plan found: ${BOLD}$(basename "$existing_plan")${NC}"
        echo ""
        echo "  [n] Start a new task"
        echo "  [2] Resume → Review Plan (Codex)"
        echo "  [3] Resume → Implement (Codex)"
        echo "  [4] Resume → Review Implementation (Claude)"
        echo "  [5] Resume → Close Session (Gemini)"
        echo ""
        read -rp "→ " rc </dev/tty
        case "$rc" in
          2) start_at="2" ;;
          3) start_at="3" ;;
          4) start_at="4" ;;
          5) start_at="5" ;;
          *) start_at="1" ;;
        esac
        echo ""
      fi

      # ---- Phase 1: Plan ----
      # Feedback loop: [f] at gate re-runs phase_plan in revision mode with the feedback injected.
      if [ "$start_at" -le "1" ]; then
        while true; do
          phase_plan
          gate_rc=0; gate "Planning" "Plan Review" "" "plan" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback saved → re-run plan with it
          break
        done
      fi

      # ---- Phase 2: Review Plan (with circuit breaker + feedback) ----
      if [ "$start_at" -le "2" ]; then
        local plan_loops=0
        local plan_verdict="NONE"

        while true; do
          phase_review_plan

          local latest_review
          latest_review=$(latest_file "$REVIEWS_DIR" "review-plan-*")
          if [ -n "$latest_review" ]; then
            plan_verdict=$(parse_verdict "$latest_review")
            info "Parsed verdict: $plan_verdict"
          fi

          if [ "$plan_verdict" = "APPROVED" ]; then
            info "Plan APPROVED. Moving to implementation."
            gate_rc=0; gate "Plan Review (APPROVED)" "Implementation" "" "review-plan" || gate_rc=$?
            [ "$gate_rc" -eq 2 ] && { plan_loops=$((plan_loops + 1)); continue; }
            break
          fi

          plan_loops=$((plan_loops + 1))

          if [ "$plan_loops" -ge "$MAX_PLAN_LOOPS" ]; then
            local latest_plan_cb; latest_plan_cb=$(latest_file "$PLANS_DIR")
            circuit_break "Plan Review" "$plan_loops" "$MAX_PLAN_LOOPS" "$latest_plan_cb" "review-plan"
            plan_loops=0   # circuit_break returned — nuclear ran or human overrode; reset counter
          fi

          if [ "$plan_verdict" = "BLOCKED" ]; then
            warn "Plan BLOCKED by Codex (loop $plan_loops/$MAX_PLAN_LOOPS)."
          elif [ "$plan_verdict" = "APPROVED_WITH_CHANGES" ]; then
            warn "Plan APPROVED_WITH_CHANGES (loop $plan_loops/$MAX_PLAN_LOOPS)."
          else
            warn "Verdict unclear: $plan_verdict (loop $plan_loops/$MAX_PLAN_LOOPS)."
          fi

          echo ""
          prompt "Claude will now revise the plan based on Codex's feedback."

          gate_rc=0; gate "Plan Revision Needed" "Plan Revision (Claude)" "" "review-plan" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback → skip agent revision, re-review with human note

          phase_revise_plan
          gate_rc=0; gate "Plan Revised" "Plan Re-Review (Codex)" "" "plan" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback on revised plan → loop again
        done
      fi

      # ---- Phase 3: Implement ----
      # Feedback loop: [f] regenerates the context packet with new human notes, user re-runs Codex.
      if [ "$start_at" -le "3" ]; then
        while true; do
          phase_implement
          gate_rc=0; gate "Implementation" "Implementation Review" "" "implement" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback → regenerate packet, user re-runs Codex
          break
        done
      fi

      # ---- Phase 4: Review Implementation (with circuit breaker + feedback) ----
      if [ "$start_at" -le "4" ]; then
        local impl_loops=0
        local impl_verdict="NONE"

        while true; do
          phase_review_impl

          local latest_impl_review
          latest_impl_review=$(latest_file "$REVIEWS_DIR" "review-impl-*")
          if [ -n "$latest_impl_review" ]; then
            impl_verdict=$(parse_verdict "$latest_impl_review")
            info "Parsed verdict: $impl_verdict"
          fi

          if [ "$impl_verdict" = "PASS" ]; then
            info "Implementation PASSED. Moving to session close."
            gate_rc=0; gate "Implementation Review (PASS)" "Session Close" "" "review-impl" || gate_rc=$?
            [ "$gate_rc" -eq 2 ] && { impl_loops=$((impl_loops + 1)); continue; }
            break
          fi

          impl_loops=$((impl_loops + 1))

          if [ "$impl_loops" -ge "$MAX_IMPL_LOOPS" ]; then
            local latest_plan_cb; latest_plan_cb=$(latest_file "$PLANS_DIR")
            circuit_break "Implementation Review" "$impl_loops" "$MAX_IMPL_LOOPS" "$latest_plan_cb" "review-impl"
            impl_loops=0   # circuit_break returned — nuclear ran or human overrode; reset counter
          fi

          if [ "$impl_verdict" = "FAIL" ]; then
            warn "Implementation FAILED review (loop $impl_loops/$MAX_IMPL_LOOPS)."
          elif [ "$impl_verdict" = "PASS_WITH_FIXES" ]; then
            warn "Implementation needs fixes (loop $impl_loops/$MAX_IMPL_LOOPS)."
          else
            warn "Verdict unclear: $impl_verdict (loop $impl_loops/$MAX_IMPL_LOOPS)."
          fi

          echo ""
          prompt "Address the review feedback, then continue."

          gate_rc=0; gate "Implementation Fixes Needed" "Re-implement" "" "review-impl" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback → re-run review with human note

          phase_implement
          gate_rc=0; gate "Implementation (revised)" "Implementation Review" "" "implement" || gate_rc=$?
          [ "$gate_rc" -eq 2 ] && continue   # feedback on re-impl → loop again
        done
      fi

      # ---- Phase 5: Close ----
      phase_close

      echo ""
      banner "Workflow Complete"
      info "Session closed. Context files updated."
      ;;
    *)
      error "Unknown phase: $phase"
      echo "Usage: ./orchestra.sh [plan|review-plan|implement|review-impl|close]"
      echo "       ./orchestra.sh          (interactive mode)"
      exit 1
      ;;
  esac
}

main "$@"
