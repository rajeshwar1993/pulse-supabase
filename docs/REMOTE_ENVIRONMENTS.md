# Remote Environments Setup Guide

This document provides detailed instructions for setting up **Staging** and **Production** Supabase environments for the Pulse platform.

---

## 📋 Overview

### Environment Architecture

| Environment | Type | Purpose | When to Use |
|-------------|------|---------|-------------|
| **Development** | Local (Docker) | Daily development work | Always (local machine) |
| **Staging** | Cloud (Supabase) | QA, integration testing, pre-release validation | Before production deployment |
| **Production** | Cloud (Supabase) | Live user-facing application | After staging validation |

### Key Principles

- **Separate Projects**: Each environment has its own Supabase project with isolated databases
- **Migration Flow**: Dev (local) → Staging (cloud) → Production (cloud)
- **Configuration as Code**: All schema changes version-controlled in this repository
- **Manual Production Deploys**: Production deployments require explicit approval

---

## 🏗️ Part 1: Creating Staging Environment

### Step 1: Create Staging Supabase Project

1. **Go to Supabase Dashboard**:
   - Navigate to https://supabase.com/dashboard
   - Click "New Project"

2. **Project Configuration**:
   - **Name**: `pulse-staging`
   - **Database Password**: Generate a strong password (save securely in password manager)
   - **Region**: Choose closest to your primary users (e.g., `ap-south-1` for India)
   - **Pricing Plan**: Free tier is fine for staging

3. **Wait for Provisioning**:
   - Takes ~2 minutes
   - You'll see "Project is ready" when complete

---

### Step 2: Save Staging Credentials

1. **Navigate to Project Settings**:
   - Click on your project
   - Go to Settings → API

2. **Copy the following**:
   - **Project URL**: `https://xxxxx.supabase.co`
   - **Project API keys**:
     - `anon` key (public)
     - `service_role` key (secret)

3. **Create `.env.staging` file** (in this repository):
   ```bash
   # Staging Environment
   SUPABASE_PROJECT_REF=<project-ref-from-url>
   SUPABASE_URL=https://xxxxx.supabase.co
   SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
   SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
   ```

   **🔒 Security**: Add `.env.staging` to `.gitignore`. Never commit credentials.

---

### Step 3: Link Staging Project with CLI

```bash
cd /Users/rajeshwarrudra/Documents/DevWork/pulse-supabase

# Link to staging project
supabase link --project-ref <your-staging-project-ref>

# You'll be prompted to enter your database password
```

**What this does:**
- Creates a connection between your local CLI and the remote staging project
- Allows you to push migrations and deploy Edge Functions

---

### Step 4: Deploy Initial Schema to Staging

```bash
# Push all migrations to staging
supabase db push

# This will:
# 1. Compare local migrations with remote database
# 2. Apply any missing migrations
# 3. Show you a diff before applying
```

**Verify**:
- Go to Supabase Dashboard → Table Editor
- Confirm tables are created

---

### Step 5: Deploy Edge Functions to Staging

```bash
# Deploy all functions
supabase functions deploy

# Or deploy specific function
supabase functions deploy daily-digest
```

---

### Step 6: Configure Client Apps for Staging

**For `pulse-web`** - Create `.env.staging`:
```bash
NEXT_PUBLIC_SUPABASE_URL=https://xxxxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<staging-anon-key>
NEXT_PUBLIC_ENV=staging
```

**For `pulse-app`** - Create `.env.staging`:
```bash
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=<staging-anon-key>
ENV=staging
```

**Build for staging**:
```bash
# Web
cd pulse-web
npm run build -- --mode staging

# Mobile (Flutter)
cd pulse-app
flutter build apk --dart-define=ENV=staging
```

---

## 🚀 Part 2: Creating Production Environment

### Step 1: Create Production Supabase Project

1. **Go to Supabase Dashboard**:
   - Navigate to https://supabase.com/dashboard
   - Click "New Project"

2. **Project Configuration**:
   - **Name**: `pulse-production`
   - **Database Password**: Generate a **different** strong password (save securely)
   - **Region**: Same as staging (e.g., `ap-south-1`)
   - **Pricing Plan**: Consider Pro plan for production (better performance, support)

3. **Wait for Provisioning**

---

### Step 2: Save Production Credentials

1. **Navigate to Project Settings** → API

2. **Copy credentials**:
   - Project URL
   - `anon` key
   - `service_role` key

3. **Create `.env.production` file**:
   ```bash
   # Production Environment
   SUPABASE_PROJECT_REF=<production-project-ref>
   SUPABASE_URL=https://yyyyy.supabase.co
   SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
   SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
   ```

   **🔒 Security**: Add `.env.production` to `.gitignore`.

---

### Step 3: Link Production Project

```bash
# Link to production project
supabase link --project-ref <your-production-project-ref>
```

---

### Step 4: Deploy to Production (WITH CAUTION)

**⚠️ IMPORTANT**: Production deployments affect live users. Always:
1. Test thoroughly in staging first
2. Create a database backup
3. Deploy during low-traffic hours
4. Have a rollback plan

**Deployment Process**:

```bash
# 1. Create backup (via Supabase Dashboard)
# Go to Database → Backups → Create Backup

# 2. Dry run to preview changes
supabase db push --dry-run

# 3. Review the diff carefully

# 4. Apply migrations
supabase db push

# 5. Deploy Edge Functions
supabase functions deploy
```

---

### Step 5: Configure Client Apps for Production

**For `pulse-web`** - Create `.env.production`:
```bash
NEXT_PUBLIC_SUPABASE_URL=https://yyyyy.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<production-anon-key>
NEXT_PUBLIC_ENV=production
```

**For `pulse-app`** - Create `.env.production`:
```bash
SUPABASE_URL=https://yyyyy.supabase.co
SUPABASE_ANON_KEY=<production-anon-key>
ENV=production
```

---

## 🔄 Deployment Workflow

### Typical Migration Flow

```
┌─────────────┐
│ Development │  1. Create migration locally
│   (Local)   │  2. Test with `supabase db reset`
└──────┬──────┘  3. Commit to git
       │
       ▼
┌─────────────┐
│   Staging   │  4. Deploy to staging
│   (Cloud)   │  5. QA team tests
└──────┬──────┘  6. Approve for production
       │
       ▼
┌─────────────┐
│ Production  │  7. Create backup
│   (Cloud)   │  8. Deploy to production
└─────────────┘  9. Monitor for issues
```

---

## 🛠️ Common Operations

### Switching Between Environments

```bash
# Link to staging
supabase link --project-ref <staging-ref>

# Link to production
supabase link --project-ref <production-ref>

# Link back to local
supabase stop && supabase start
```

---

### Deploying a New Migration

**To Staging**:
```bash
# 1. Ensure you're linked to staging
supabase link --project-ref <staging-ref>

# 2. Push migration
supabase db push

# 3. Verify in Supabase Dashboard
```

**To Production**:
```bash
# 1. Create backup first!

# 2. Link to production
supabase link --project-ref <production-ref>

# 3. Dry run
supabase db push --dry-run

# 4. Review changes carefully

# 5. Push
supabase db push
```

---

### Deploying Edge Functions

```bash
# Deploy all functions
supabase functions deploy

# Deploy specific function
supabase functions deploy daily-digest --project-ref <project-ref>
```

---

### Rolling Back a Migration

**If a migration causes issues in production**:

```bash
# 1. Restore from backup (via Supabase Dashboard)
# Database → Backups → Restore

# 2. Fix the migration locally

# 3. Create a new migration to correct the issue
supabase migration new fix_issue

# 4. Test locally

# 5. Deploy to staging, then production
```

---

## 🔐 Security Best Practices

### Environment Variables

1. **Never commit** `.env.staging` or `.env.production` to git
2. **Use different passwords** for each environment
3. **Rotate keys** if they are ever exposed
4. **Store secrets** in a password manager (1Password, LastPass, etc.)

### Access Control

1. **Limit production access** to senior developers only
2. **Use service role key** only in backend/server contexts
3. **Never expose service role key** in client apps

---

## 📊 Monitoring & Observability

### Supabase Dashboard

Monitor each environment via:
- **Database**: Query performance, table sizes
- **Auth**: User signups, login attempts
- **Storage**: File uploads, bandwidth
- **Logs**: API requests, errors

### Alerts

Set up alerts for:
- Database connection limits
- Storage quota
- API rate limits
- Error rates

---

## 🚨 Emergency Procedures

### Production Database Issue

1. **Immediate**: Restore from latest backup
2. **Investigate**: Check logs in Supabase Dashboard
3. **Fix**: Create corrective migration
4. **Test**: Thoroughly test in staging
5. **Deploy**: Apply fix to production

### Edge Function Failure

1. **Rollback**: Deploy previous working version
   ```bash
   git checkout <previous-commit>
   supabase functions deploy <function-name>
   ```
2. **Fix**: Debug locally
3. **Test**: Verify in staging
4. **Redeploy**: Push to production

---

## 📚 Additional Resources

- **Supabase CLI Reference**: https://supabase.com/docs/reference/cli
- **Database Migrations**: https://supabase.com/docs/guides/cli/local-development#database-migrations
- **Edge Functions Deployment**: https://supabase.com/docs/guides/functions/deploy
- **Backup & Restore**: https://supabase.com/docs/guides/platform/backups

---

## ✅ Checklist: Before Going Live

### Staging Environment
- [ ] Staging Supabase project created
- [ ] All migrations applied successfully
- [ ] Edge Functions deployed and tested
- [ ] Client apps configured with staging credentials
- [ ] QA testing completed
- [ ] Performance testing done

### Production Environment
- [ ] Production Supabase project created
- [ ] Database backup created
- [ ] All migrations tested in staging
- [ ] Edge Functions tested in staging
- [ ] Client apps configured with production credentials
- [ ] Monitoring and alerts set up
- [ ] Rollback plan documented
- [ ] Team notified of deployment

---

**Last Updated**: 2026-02-10  
**Maintained By**: Pulse Development Team  
**Questions?**: Refer to main README.md or Supabase documentation
