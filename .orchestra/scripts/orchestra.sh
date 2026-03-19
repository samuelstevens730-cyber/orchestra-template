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
GEMINI_CMD="gemini -p"                    # Google Gemini CLI (prompt as arg)
GEMINI_STDIN_CMD="gemini"                 # Google Gemini CLI (prompt via stdin, for large contexts)

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
    read -rp "→ " choice </dev/tty
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

# Extract content between exact delimiter lines from a file
extract_section() {
  local file="$1"
  local start="$2"
  local end="$3"
  sed -n "/^${start}$/,/^${end}$/{/^${start}$/d;/^${end}$/d;p}" "$file"
}

# ============================================================================
# Phase Functions
# ============================================================================

phase_plan() {
  banner "Phase 1: PLAN (Claude)"
  
  read -rp "Describe the feature/task to plan: " task_description </dev/tty
  read -rp "Short slug for filename (e.g., add-auth, refactor-api): " task_slug </dev/tty
  
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

  local revise_prompt="You are the Architect in the Orchestra workflow.

CONTEXT:
$context

Codex has reviewed your plan and returned feedback (see the review file above).
Revise the plan to address ALL of Codex's feedback.

Rules:
- Address every point Codex raised
- Keep the same plan format and structure
- Do not add scope beyond what Codex's feedback requires
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

  $CODEX_IMPL_CMD "$(cat "$tmp_prompt")"

  rm -f "$tmp_prompt"

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

  # Archive session entry and decisions to history
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

  rm -f "$tmp_output"

  echo ""
  info "Context files updated. Review them in .orchestra/context/ if needed."
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
      if [ "$start_at" -le "1" ]; then
        phase_plan
        gate "Planning" "Plan Review" ""
      fi

      # ---- Phase 2: Review Plan (with circuit breaker) ----
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
          prompt "Claude will now revise the plan based on Codex's feedback."

          if ! gate "Plan Revision Needed" "Plan Revision (Claude)" ""; then
            break
          fi

          phase_revise_plan
          gate "Plan Revised" "Plan Re-Review (Codex)" ""
        done
      fi

      # ---- Phase 3: Implement ----
      if [ "$start_at" -le "3" ]; then
        phase_implement
        gate "Implementation" "Implementation Review" ""
      fi

      # ---- Phase 4: Review Implementation (with circuit breaker) ----
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
      fi

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
