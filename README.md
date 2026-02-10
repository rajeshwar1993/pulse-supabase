# Pulse Supabase - Local Development Setup

This repository contains all Supabase-related infrastructure for the Pulse platform, including database schemas, migrations, Row Level Security (RLS) policies, Edge Functions, and environment configurations.

---

## 📋 Overview

### Technology Stack
- **Database**: PostgreSQL (via Supabase)
- **Authentication**: Supabase Auth
- **Storage**: Supabase Storage
- **Edge Functions**: Deno-based serverless functions
- **CLI**: Supabase CLI for local development

### Environment Strategy
- **Development**: Local Supabase (Docker-based) - This guide
- **Staging & Production**: Remote Supabase projects - See `docs/REMOTE_ENVIRONMENTS.md`

---

## 🚀 Local Development Setup

### Prerequisites

Before you begin, ensure you have the following installed:

1. **Docker Desktop** (required for local Supabase)
   - Download: https://www.docker.com/products/docker-desktop
   - Verify: `docker --version` (should be 20.10.0 or higher)
   - **Important**: Docker Desktop must be running before starting Supabase

2. **Supabase CLI**
   ```bash
   brew install supabase/tap/supabase
   ```
   - Verify: `supabase --version` (should be 1.150.0 or higher)

3. **Node.js** (for Edge Functions)
   - Version: 18.x or higher
   - Verify: `node --version`

---

### Step 1: Initialize Supabase

```bash
cd /Users/rajeshwarrudra/Documents/DevWork/pulse-supabase

# Initialize Supabase (creates supabase/ directory)
supabase init
```

**What this creates:**
```
supabase/
├── config.toml          # Supabase project configuration
├── migrations/          # SQL migration files (timestamped)
├── functions/           # Edge Functions (Deno)
└── seed.sql            # Seed data for development
```

---

### Step 2: Start Local Supabase

```bash
supabase start
```

**What happens:**
- Downloads and starts Docker containers for:
  - PostgreSQL database
  - Supabase Studio (local dashboard)
  - GoTrue (Auth server)
  - PostgREST (API server)
  - Realtime server
  - Storage server
  - Inbucket (email testing)

**Expected output:**
```
Started supabase local development setup.

         API URL: http://localhost:54321
     GraphQL URL: http://localhost:54321/graphql/v1
          DB URL: postgresql://postgres:postgres@localhost:54322/postgres
      Studio URL: http://localhost:54323
    Inbucket URL: http://localhost:54324
      JWT secret: super-secret-jwt-token-with-at-least-32-characters-long
        anon key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
service_role key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

**⚠️ Important:** Save these credentials! You'll need them for local development.

---

### Step 3: Create Environment File

Create a `.env.local` file in the root of this repository:

```bash
# .env.local (for local development)
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=<anon-key-from-supabase-start>
SUPABASE_SERVICE_ROLE_KEY=<service-role-key-from-supabase-start>
SUPABASE_DB_URL=postgresql://postgres:postgres@localhost:54322/postgres
```

**🔒 Security Note:** This file is gitignored. Never commit credentials to version control.

---

### Step 4: Access Supabase Studio

Open your browser and navigate to:
```
http://localhost:54323
```

**Supabase Studio** is your local database management interface where you can:
- View and edit tables
- Test SQL queries
- Manage authentication users
- Configure storage buckets
- View API documentation

---

### Step 5: Verify Setup

```bash
# Check database status
supabase status

# Should show all services running
```

---

## 📁 Repository Structure

```
pulse-supabase/
├── supabase/
│   ├── config.toml                    # Supabase project configuration
│   ├── migrations/                    # SQL migration files (timestamped)
│   │   ├── 20260210000001_initial_schema.sql
│   │   └── ...
│   ├── functions/                     # Edge Functions (Deno)
│   │   ├── daily-digest/
│   │   │   └── index.ts
│   │   └── self-nudge/
│   │       └── index.ts
│   └── seed.sql                       # Seed data for development
├── docs/
│   └── REMOTE_ENVIRONMENTS.md         # Staging/Production setup guide
├── scripts/
│   └── (deployment scripts - future)
├── .env.local                         # Local environment variables (gitignored)
├── .env.example                       # Example environment file
├── .gitignore
├── README.md                          # This file
└── package.json                       # For Edge Functions dependencies
```

---

## 🔄 Development Workflow

### Creating a New Migration

```bash
# 1. Create a new migration file
supabase migration new add_feature_name

# This creates: supabase/migrations/YYYYMMDDHHMMSS_add_feature_name.sql

# 2. Edit the migration file with your SQL changes

# 3. Apply the migration locally
supabase db reset

# 4. Verify changes in Supabase Studio (http://localhost:54323)

# 5. Test your changes

# 6. Commit the migration
git add supabase/migrations/
git commit -m "feat(db): add feature_name"
```

---

### Creating an Edge Function

```bash
# 1. Create a new Edge Function
supabase functions new my-function

# This creates: supabase/functions/my-function/index.ts

# 2. Implement your function logic

# 3. Test locally
supabase functions serve my-function

# 4. Test with curl
curl -i --location --request POST 'http://localhost:54321/functions/v1/my-function' \
  --header 'Authorization: Bearer YOUR_ANON_KEY' \
  --header 'Content-Type: application/json' \
  --data '{"name":"Test"}'

# 5. Commit the function
git add supabase/functions/my-function/
git commit -m "feat(functions): add my-function"
```

---

### Seeding Development Data

Edit `supabase/seed.sql` to add test data:

```sql
-- Insert test users
INSERT INTO public.profiles (id, display_name, email, avatar_id, timezone)
VALUES 
  ('11111111-1111-1111-1111-111111111111', 'Test User 1', 'test1@example.com', 'male_style1', 'Asia/Kolkata'),
  ('22222222-2222-2222-2222-222222222222', 'Test User 2', 'test2@example.com', 'female_style2', 'America/New_York');
```

Apply seed data:
```bash
supabase db reset
```

---

## 🛠️ Common Commands

### Local Development

```bash
# Start Supabase
supabase start

# Stop Supabase
supabase stop

# Restart Supabase (useful after config changes)
supabase stop && supabase start

# Reset database (drop + recreate + apply migrations + seed)
supabase db reset

# View logs
supabase logs

# Check status
supabase status
```

### Migrations

```bash
# Create new migration
supabase migration new <migration_name>

# Apply migrations
supabase db reset

# Check for schema drift
supabase db diff
```

### Database Access

```bash
# Open PostgreSQL shell
supabase db psql

# Execute SQL file
supabase db psql < my_script.sql
```

---

## 🐛 Troubleshooting

### Issue: "Docker daemon is not running"

**Solution:**
```bash
# Start Docker Desktop application
# Wait for Docker to fully start
# Then run: supabase start
```

---

### Issue: "Port already in use"

**Solution:**
```bash
# Stop Supabase
supabase stop

# Check what's using the port
lsof -i :54321

# Kill the process or change Supabase ports in config.toml
```

---

### Issue: "Migration failed"

**Solution:**
```bash
# Check migration syntax
cat supabase/migrations/<your_migration>.sql

# Reset database
supabase db reset

# If still failing, check logs
supabase logs
```

---

### Issue: "Can't connect to local Supabase"

**Solution:**
```bash
# Check status
supabase status

# Restart Supabase
supabase stop && supabase start

# Verify Docker containers are running
docker ps | grep supabase
```

---

## 🔗 Connecting Client Apps

### Flutter (pulse-app)

Create `.env` file in `pulse-app`:
```bash
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=<your-anon-key>
```

### Next.js (pulse-web)

Create `.env.local` file in `pulse-web`:
```bash
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-anon-key>
```

---

## 📚 Additional Resources

- **Supabase CLI Documentation**: https://supabase.com/docs/guides/cli
- **Supabase Local Development**: https://supabase.com/docs/guides/cli/local-development
- **PostgreSQL Documentation**: https://www.postgresql.org/docs/
- **Edge Functions Guide**: https://supabase.com/docs/guides/functions

---

## 🚀 Next Steps

- For setting up **Staging** and **Production** environments, see `docs/REMOTE_ENVIRONMENTS.md`
- For deployment workflows, see the scripts in `scripts/` directory (coming soon)

---

**Last Updated**: 2026-02-10  
**Maintained By**: Pulse Development Team
