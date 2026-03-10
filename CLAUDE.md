# CLAUDE.md — pulse-supabase

## Overview

Backend for Pulse — PostgreSQL schema, migrations, RLS policies, and Deno Edge Functions. Managed with the Supabase CLI.

## Build & Development

```bash
supabase start           # Start local stack (needs Docker)
supabase stop            # Stop local stack
supabase db reset        # Reapply all migrations + seed data
supabase migration new <description>   # Create new migration
supabase db diff         # Diff local vs remote schema
supabase db push         # Push migrations to remote
```

**Local ports:** API 54321, DB 54322, Studio 54323 (http://localhost:54323), Inbucket 54324

## Key Conventions

- Migration filenames: `YYYYMMDDHHMMSS_description.sql`
- Never edit existing migrations after deployment; create new ones
- RLS on all tables; policies named `{table}_{action}_{description}`
- SQL style: UPPERCASE keywords, lowercase snake_case identifiers
- Column conventions: `id uuid default gen_random_uuid()`, `created_at timestamptz default now()`, FK as `{table}_id`
- CHECK constraints for validation (e.g., `CHECK (col ~ '^[a-z]{2}(-[A-Z]{2})?$')` for BCP 47 lang codes)
- `DEFAULT` values with `NOT NULL` for backward-compatible column additions

## Database Tables

`profiles`, `daily_pulses`, `connections`, `invite_codes`, `missed_pulse_surveys` — all with RLS enforced via `auth.uid()`.
