# Repo Context

> **Purpose:** Token-efficient repo map so agents don't need to scan the full codebase.
> **Update frequency:** After any structural change (new modules, moved files, changed architecture).
> **Owner:** Human or Gemini (during session close, if structural changes occurred).

## Project Name
<!-- e.g., Shift Happens, My SaaS App -->

## One-Line Description
<!-- What this project does in one sentence -->

## Tech Stack
<!-- e.g., Next.js 14, Supabase/Postgres, Tailwind, Vercel -->

## Directory Structure
```
<!-- Paste a trimmed `tree` output here. Only include directories and key files, not every file. -->
<!-- Example:
├── src/
│   ├── app/           # Next.js app router pages
│   ├── components/    # Shared React components
│   ├── lib/           # Utility functions, DB clients, API helpers
│   ├── hooks/         # Custom React hooks
│   └── types/         # TypeScript type definitions
├── supabase/
│   └── migrations/    # Database migration files
├── public/            # Static assets
├── .orchestra/        # Multi-agent orchestration (this system)
└── package.json
-->
```

## Key Architectural Patterns
<!-- How is the code organized? What conventions does the project follow?
     e.g., "Server components by default, client components only when interactivity needed"
     e.g., "All DB queries go through lib/db.ts, never direct Supabase calls from components"
     e.g., "API routes follow REST conventions in src/app/api/"
-->

## Entry Points
<!-- Where does execution start? What are the main user-facing routes/endpoints?
     e.g., "Main dashboard: src/app/dashboard/page.tsx"
     e.g., "API: src/app/api/ — payroll, employees, reports"
-->

## Data Flow
<!-- High-level: how does data move through the system?
     e.g., "Browser → Next.js API routes → Supabase RPC → Postgres → Response"
-->

## External Dependencies / Integrations
<!-- Third-party services, APIs, or systems this project talks to
     e.g., "Supabase Auth for authentication"
     e.g., "OpenWeather API for weather data"
     e.g., "Vercel for hosting and edge functions"
-->

## Environment / Config
<!-- Where are env vars? What's required to run locally?
     e.g., ".env.local with SUPABASE_URL, SUPABASE_ANON_KEY, etc."
-->

## Known Gotchas
<!-- Things that trip people (and agents) up
     e.g., "Supabase RLS policies are strict — new tables need explicit policies"
     e.g., "The payroll calculation uses fiscal weeks, not calendar weeks"
-->
