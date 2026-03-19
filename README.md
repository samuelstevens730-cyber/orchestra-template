# 🎼 Orchestra — Multi-Agent Engineering Workflow

A file-based, CLI-driven multi-agent workflow for VS Code where Claude plans, Codex implements, and Gemini handles research and session hygiene.

## Quick Start

### 1. Prerequisites

Install the CLIs for each model:

```bash
# Claude Code CLI (check: https://docs.anthropic.com)
# Verify with:
claude --version

# Codex CLI (OpenAI)
# Verify with:
codex --version

# Gemini CLI (Google)
# Verify with:
gemini --version
```

### 2. Drop Into Your Project

Copy the `.orchestra/` directory, `CLAUDE.md`, and `.vscode/tasks.json` into your project root.

```
your-project/
├── CLAUDE.md                    ← Claude Code reads this automatically
├── .vscode/tasks.json           ← VS Code task definitions
├── .orchestra/
│   ├── souls/                   ← Identity/role files per model
│   │   ├── claude.soul.md
│   │   ├── codex.soul.md
│   │   └── gemini.soul.md
│   ├── context/                 ← Shared project context (all agents read these)
│   │   ├── REPO_CONTEXT.md      ← Token-saving repo map
│   │   ├── PROJECT_STATE.md     ← Current status and priorities
│   │   ├── DECISIONS.md         ← Durable decisions with traceability
│   │   ├── OPEN_LOOPS.md        ← Unresolved items
│   │   ├── SESSION_LOG.md       ← Session history
│   │   └── RESEARCH_LOG.md      ← Research findings
│   ├── plans/                   ← Plan packets (Claude writes these)
│   │   └── _TEMPLATE.md
│   ├── reviews/                 ← Reviews (Codex reviews plans, Claude reviews impl)
│   │   ├── _TEMPLATE_PLAN_REVIEW.md
│   │   └── _TEMPLATE_IMPL_REVIEW.md
│   ├── feedback/                ← Human feedback + nuclear reconciliations (phase-scoped)
│   ├── history/                 ← Archived sessions, decisions, research
│   │   ├── decisions/
│   │   ├── sessions/
│   │   └── research/
│   └── scripts/
│       └── orchestra.sh         ← Semi-auto workflow orchestrator
└── ... (your project files)
```

### 3. Fill In Your Context

Before first use, populate these files:

1. **`.orchestra/context/REPO_CONTEXT.md`** — Fill in your tech stack, directory structure, patterns, and gotchas. This is the most important file for reducing token waste.
2. **`.orchestra/context/PROJECT_STATE.md`** — Set your current priorities and what's in flight.

The rest will populate organically as you use the system.

### 4. Configure CLI Commands

Edit the top of `.orchestra/scripts/orchestra.sh` to match your CLI installations:

```bash
CLAUDE_CMD="claude -p"             # Claude: one-shot prompt mode
CODEX_CMD="codex exec"             # Codex: read-only sandbox (reviews)
CODEX_IMPL_CMD="codex --full-auto" # Codex: file-write mode (implementation)
GEMINI_STDIN_CMD="gemini"          # Gemini: prompt via stdin (all Gemini calls)

MAX_PLAN_LOOPS=2                  # Max plan revision cycles before circuit breaker
MAX_IMPL_LOOPS=2                  # Max impl revision cycles before circuit breaker
```

### 5. Run It

**Interactive mode** (walks through all phases with human gates):
```bash
./.orchestra/scripts/orchestra.sh
```

**Individual phases** (for when you want to run just one step):
```bash
./.orchestra/scripts/orchestra.sh plan
./.orchestra/scripts/orchestra.sh review-plan
./.orchestra/scripts/orchestra.sh implement
./.orchestra/scripts/orchestra.sh review-impl
./.orchestra/scripts/orchestra.sh close
```

**VS Code tasks** (Ctrl+Shift+P → "Run Task" → pick an Orchestra task):
All phases are available as VS Code tasks for one-click invocation.

---

## The Workflow

```
┌─────────┐     ┌──────────────┐     ┌───────────┐     ┌──────────────┐     ┌─────────┐
│  PLAN   │────▶│ REVIEW PLAN  │────▶│ IMPLEMENT │────▶│ REVIEW IMPL  │────▶│  CLOSE  │
│ (Claude)│◀────│   (Codex)    │     │  (Codex)  │◀────│   (Claude)   │     │(Gemini) │
└─────────┘     └──────────────┘     └───────────┘     └──────────────┘     └─────────┘
    │            APPROVED /              │               PASS /                  │
    │            APPROVED_WITH_CHANGES   │               PASS_WITH_FIXES        │
    │◀───────── BLOCKED (loop back)     │◀──────────── FAIL (loop back)        │
    │                                    │                                       │
    ▼                                    ▼                                       ▼
  Human gate                          Human gate                             Human gate
```

Each transition has a **human gate** — you review the output, can edit files directly, and decide whether to continue, loop back, or stop.

### Gate options

At every gate you have these choices:

| Key | Action |
|-----|--------|
| `c` | **Continue** — proceed to the next phase |
| `r` | **Retry** — loop back (available at revision gates) |
| `f` | **Feedback** — type notes; the current phase re-runs with your input injected |
| `n` | **Nuclear** — invoke Gemini as a neutral reconciler to break disagreements |
| `s` | **Stop** — save progress and exit (resume later) |
| `q` | **Quit** — exit immediately |

**Feedback (`[f]`):** Your notes are saved to `.orchestra/feedback/feedback-{phase}-{timestamp}.md` and injected as authoritative constraints into the re-run. Feedback is phase-scoped — notes you leave during plan review only affect that phase, not later phases.

**Nuclear (`[n]`):** Gathers the current plan, reviews, and all feedback for the phase, then asks Gemini to identify conflicts and produce a reconciled recommendation. The output is saved to `.orchestra/feedback/reconciled-{phase}-{timestamp}.md` and injected the next time that phase runs.

**Circuit breaker:** If Claude and Codex fail to converge within the configured loop limit, a deadlock gate appears instead of an automatic exit. You can invoke `[n]` nuclear to let Gemini reconcile, or `[c]` to override and continue with the loop counter reset.

### Implement phase

Orchestra invokes `codex --full-auto` directly, passing the assembled implementation prompt (plan + context + feedback) as an argument. Because `codex --full-auto` is an interactive TUI, it takes over the terminal for the duration of the implementation.

**When Codex finishes, press `Ctrl+D` to exit the Codex session and return to Orchestra.**

The context packet is also saved to `.orchestra/tmp-impl-prompt.md` for reference or debugging.

### Session close — auto-apply

The close phase (Gemini) uses structured delimiters in its output. Orchestra parses these automatically and writes the context files directly — no copy-paste required. Files updated: `SESSION_LOG.md`, `DECISIONS.md`, `OPEN_LOOPS.md`, `REPO_CONTEXT.md`, `PROJECT_STATE.md`, `RESEARCH_LOG.md`. Session summaries and decisions are also archived to `.orchestra/history/`.

---

## Design Principles

**Separation of cognition.** Claude thinks abstractly (architecture, planning, judgment). Codex thinks concretely (repo reality, implementation, feasibility). Gemini thinks structurally (research, records, hygiene).

**File-based communication.** No APIs, no databases, no middleware. Models communicate through markdown files on disk. The filesystem IS the protocol.

**Human in the loop.** Every phase transition requires human approval. No model can lock a plan or ship code without you signing off.

**Traceability over convenience.** Every decision records what, when, why, who, and what was rejected. This prevents context drift where cleaned-up summaries slowly diverge from reality.

---

## Context Drift Prevention

The biggest risk in multi-agent workflows is context drift: Claude plans one thing, Codex implements something slightly different, Gemini records a polished version, and later sessions treat the polished version as truth.

Defenses built into this system:
- **Decisions are append-only** — never edit, only add reversals that reference the original
- **Plans are locked after approval** — deviations must be flagged, not silently absorbed
- **Session logs are factual** — Gemini records what happened, not a narrative
- **Review verdicts are explicit** — PASS/FAIL, not "looks good I guess"

---

## Customization

### Adding a Model
1. Create a new soul file in `.orchestra/souls/`
2. Add the CLI command to `orchestra.sh`
3. Update peer awareness sections in other soul files
4. Add a VS Code task in `.vscode/tasks.json`

### Changing the Workflow
The phases are just bash functions. Reorder them, add new ones, or skip phases by editing `orchestra.sh`. The individual phase commands work independently — you don't have to use interactive mode.

### Project-Specific Tuning
The soul files are intentionally generic. Once you drop this into a project, add project-specific constraints to the soul files (e.g., "This project uses server components by default" or "All DB access goes through the repository pattern").
