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

CLAUDE_CMD="claude -p"       # Claude Code CLI (one-shot prompt mode)
CODEX_CMD="codex exec"       # OpenAI Codex CLI
GEMINI_CMD="gemini -p"       # Google Gemini CLI

# Circuit breaker: max revision loops before forcing human intervention
MAX_PLAN_LOOPS=2             # Max Claude↔Codex plan revision cycles
MAX_IMPL_LOOPS=2             # Max Codex→Claude impl revision cycles

# --- Paths -------------------------------------------------------------------
ORCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT_DIR="$ORCH_DIR/context"
SOULS_DIR="$ORCH_DIR/souls"
PLANS_DIR="$ORCH_DIR/plans"
REVIEWS_DIR="$ORCH_DIR/reviews"

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
gate() {
  local phase_name="$1"
  local next_phase="$2"
  local retry_phase="${3:-}"
  
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  prompt "🚦 GATE: $phase_name complete. Review the output above."
  echo ""
  echo "  [c] Continue to $next_phase"
  if [ -n "$retry_phase" ]; then
    echo "  [r] Retry $retry_phase (loop back)"
  fi
  echo "  [s] Stop here (resume later)"
  echo "  [q] Quit"
  echo ""
  
  while true; do
    read -rp "→ " choice
    case "$choice" in
      c|C) return 0 ;;
      r|R) 
        if [ -n "$retry_phase" ]; then
          return 1
        else
          echo "Retry not available for this gate."
        fi
        ;;
      s|S) 
        info "Stopping. Resume by running: ./orchestra.sh $next_phase"
        exit 0 
        ;;
      q|Q) 
        info "Quitting."
        exit 0 
        ;;
      *) echo "Invalid choice. Enter c, r, s, or q." ;;
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

# Circuit breaker — halts the loop and logs to OPEN_LOOPS
circuit_break() {
  local phase_name="$1"
  local loop_count="$2"
  local max_loops="$3"
  local plan_file="${4:-}"
  
  error "═══════════════════════════════════════════════════════"
  error "  CIRCUIT BREAKER TRIPPED"
  error "  Phase: $phase_name"
  error "  Loops exhausted: $loop_count / $max_loops"
  error "═══════════════════════════════════════════════════════"
  echo ""
  warn "Claude and Codex could not reach agreement within $max_loops revision cycles."
  warn "This requires human intervention to break the tie."
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
  info "Review the plan and review files, resolve manually, then resume."
  exit 1
}

# Generate a timestamped filename
timestamped_name() {
  local prefix="$1"
  local slug="$2"
  echo "${prefix}-$(date +%Y-%m-%d)-${slug}.md"
}

# ============================================================================
# Phase Functions
# ============================================================================

phase_plan() {
  banner "Phase 1: PLAN (Claude)"
  
  read -rp "Describe the feature/task to plan: " task_description
  read -rp "Short slug for filename (e.g., add-auth, refactor-api): " task_slug
  
  local plan_file="$PLANS_DIR/$(timestamped_name "plan" "$task_slug")"
  local template="$PLANS_DIR/_TEMPLATE.md"
  
  info "Invoking Claude to generate a plan..."
  info "Output will be saved to: $plan_file"
  echo ""
  
  local context
  context=$(assemble_context "$SOULS_DIR/claude.soul.md")
  
  local plan_prompt="You are the Architect in the Orchestra workflow.

CONTEXT:
$context

PLAN TEMPLATE:
$(cat "$template")

TASK:
$task_description

Generate a complete plan packet using the template above. Be specific about files, steps, and acceptance criteria. The plan must be detailed enough that Codex can implement it without asking clarifying questions."

  # Write prompt to temp file to avoid shell escaping issues
  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$plan_prompt" > "$tmp_prompt"
  
  # Invoke Claude — ADJUST THIS COMMAND TO YOUR CLI
  $CLAUDE_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$plan_file"
  
  rm -f "$tmp_prompt"
  
  info "Plan saved to: $plan_file"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Review the plan above. Edit $plan_file directly if needed."
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
  
  local review_prompt="You are the Implementer/Reviewer in the Orchestra workflow.

CONTEXT:
$context

REVIEW TEMPLATE:
$(cat "$template")

Review the plan above against the repo context. Check file paths, integration points, existing patterns, scope, and feasibility. Use the review template to structure your response.

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
  local impl_log="$REVIEWS_DIR/impl-log-${plan_basename}.md"
  
  local context
  context=$(assemble_context "$SOULS_DIR/codex.soul.md" "$plan_file")
  
  local impl_prompt="You are the Implementer in the Orchestra workflow.

CONTEXT:
$context

The plan above has been APPROVED. Implement it now.

Rules:
- Follow the plan steps exactly
- If you must deviate, document why
- Do not silently redesign the feature
- Flag any blockers immediately
- When done, list all files changed/created"

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$impl_prompt" > "$tmp_prompt"
  
  info "Invoking Codex to implement..."
  info "(This may take a while for larger changes)"
  echo ""
  
  $CODEX_CMD "$(cat "$tmp_prompt")" 2>&1 | tee "$impl_log"
  
  rm -f "$tmp_prompt"
  
  info "Implementation log saved to: $impl_log"
  info "Implementation complete. Review the changes before proceeding."
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
  
  local review_prompt="You are the Architect reviewing an implementation in the Orchestra workflow.

CONTEXT AND PLAN:
$context

REVIEW TEMPLATE:
$(cat "$template")

The plan above was implemented by Codex. Review the current state of the codebase against the plan.
Check: plan adherence, acceptance criteria, code quality, and edge cases.
Use the review template.

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
  local latest_plan
  latest_plan=$(latest_file "$PLANS_DIR")
  if [ -n "$latest_plan" ]; then
    artifacts+="$latest_plan "

    local plan_basename
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

SESSION LOG:
$(cat "$CONTEXT_DIR/SESSION_LOG.md")

Close this session by:
1. Writing a SESSION_LOG entry (max 20 lines, newest first format)
2. Extracting any new DECISIONS with full traceability — this is NON-NEGOTIABLE:
   - Every decision MUST include rejected alternatives and why they were killed
   - If a messy compromise was made, document the mess — do not sanitize it
   - Record what was actually decided, not a cleaned-up version of it
3. Updating OPEN_LOOPS (add new, mark resolved as closed)
4. Noting any RESEARCH findings if applicable
5. Flagging any context files that need pruning
6. MANDATORY: Updating REPO_CONTEXT.md to reflect any structural changes made this session:
   - New files/modules created
   - Files moved or renamed
   - New architectural patterns introduced
   - New dependencies added
   - Changed entry points or data flows
   If no structural changes occurred, explicitly state 'No REPO_CONTEXT changes needed.'

Output each update as a clearly labeled markdown section so the human can review before applying.
Use --- dividers between sections."

  local tmp_prompt
  tmp_prompt=$(mktemp)
  echo "$close_prompt" > "$tmp_prompt"
  
  info "Invoking Gemini to close the session..."
  echo ""
  
  $GEMINI_CMD "$(cat "$tmp_prompt")" 2>&1
  
  rm -f "$tmp_prompt"
  
  echo ""
  info "Review Gemini's output above, then manually apply updates to context files."
  info "(Automation of file writes is a future enhancement — for now, human applies.)"
}

# ============================================================================
# Main — Interactive Workflow
# ============================================================================

main() {
  local phase="${1:-interactive}"
  
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
      echo ""
      
      # ---- Phase 1 & 2: Plan + Plan Review (with circuit breaker) ----
      local plan_loops=0
      local plan_verdict="NONE"
      
      phase_plan
      gate "Planning" "Plan Review" ""
      
      while true; do
        phase_review_plan
        
        # Parse the verdict
        local latest_review
        latest_review=$(latest_file "$REVIEWS_DIR" "review-plan-*")
        if [ -n "$latest_review" ]; then
          plan_verdict=$(parse_verdict "$latest_review")
          info "Parsed verdict: $plan_verdict"
        fi
        
        if [ "$plan_verdict" = "APPROVED" ]; then
          info "Plan APPROVED. Moving to implementation."
          gate "Plan Review (APPROVED)" "Implementation" ""
          break
        fi
        
        plan_loops=$((plan_loops + 1))
        
        if [ "$plan_loops" -ge "$MAX_PLAN_LOOPS" ]; then
          local latest_plan
          latest_plan=$(latest_file "$PLANS_DIR")
          circuit_break "Plan Review" "$plan_loops" "$MAX_PLAN_LOOPS" "$latest_plan"
        fi
        
        if [ "$plan_verdict" = "BLOCKED" ]; then
          warn "Plan BLOCKED by Codex (loop $plan_loops/$MAX_PLAN_LOOPS)."
        elif [ "$plan_verdict" = "APPROVED_WITH_CHANGES" ]; then
          warn "Plan APPROVED_WITH_CHANGES (loop $plan_loops/$MAX_PLAN_LOOPS)."
        else
          warn "Verdict unclear: $plan_verdict (loop $plan_loops/$MAX_PLAN_LOOPS)."
        fi
        
        echo ""
        prompt "Revise the plan to address Codex's feedback, then continue."
        local current_plan
        current_plan=$(latest_file "$PLANS_DIR")
        prompt "Plan file to edit: $current_plan"
        
        if ! gate "Plan Revision Needed" "Plan Re-Review" ""; then
          break
        fi
      done
      
      # ---- Phase 3: Implement ----
      phase_implement
      gate "Implementation" "Implementation Review" ""
      
      # ---- Phase 4: Review Implementation (with circuit breaker) ----
      local impl_loops=0
      local impl_verdict="NONE"
      
      while true; do
        phase_review_impl
        
        # Parse the verdict
        local latest_impl_review
        latest_impl_review=$(latest_file "$REVIEWS_DIR" "review-impl-*")
        if [ -n "$latest_impl_review" ]; then
          impl_verdict=$(parse_verdict "$latest_impl_review")
          info "Parsed verdict: $impl_verdict"
        fi
        
        if [ "$impl_verdict" = "PASS" ]; then
          info "Implementation PASSED. Moving to session close."
          gate "Implementation Review (PASS)" "Session Close" ""
          break
        fi
        
        impl_loops=$((impl_loops + 1))
        
        if [ "$impl_loops" -ge "$MAX_IMPL_LOOPS" ]; then
          local latest_plan
          latest_plan=$(latest_file "$PLANS_DIR")
          circuit_break "Implementation Review" "$impl_loops" "$MAX_IMPL_LOOPS" "$latest_plan"
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
        
        if ! gate "Implementation Fixes Needed" "Re-implement" ""; then
          break
        fi
        
        phase_implement
        gate "Implementation (revised)" "Implementation Review" ""
      done
      
      # ---- Phase 5: Close ----
      phase_close
      
      echo ""
      banner "Workflow Complete"
      info "Session closed. Context files ready for update."
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
