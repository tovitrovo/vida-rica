# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Vida Rica** is a personal finance SPA (Single Page Application) for Portuguese-speaking users, focused on conscious spending. It supports individual users, casais (couples), and trisais (throuple) sharing expenses together.

## Architecture

### Frontend
- Single file: `index.html` (~1,600 lines) — pure HTML + Vanilla JS + Tailwind CSS via CDN
- No build step, no bundler, no npm dependencies
- Multiple screens toggled via `.screen.active` CSS class: `screen-auth`, `screen-plans`, `screen-dashboard`, `screen-wishlist`
- Language: Portuguese (pt-BR) throughout UI

### Backend (Supabase)
- **Project ID:** `ndgxuhakaqycnmojopae`
- **Edge Functions** (TypeScript/Deno) in `supabase/functions/`:
  - `mp-create-subscription/` — creates Mercado Pago recurring subscription (JWT required)
  - `mp-webhook/` — receives payment notifications from Mercado Pago (no JWT, public endpoint)
  - `_shared/cors.ts` — shared CORS headers
- **Schema:** `supabase_setup.sql` (full schema) + `supabase/migrations/` (incremental fixes)

### Database Schema (key tables)
- `profiles` — extends auth.users with name, whatsapp, role, premium status, `group_id` for partner linking
- `cards` — bank accounts/credit cards per user
- `transactions` — expense records; four pillars: `income`, `fixed`, `invest`, `free`; supports installments
- `wishes` — goals/wish list, can be shared or personal, linked via `wishes_group`
- `subscriptions` — Mercado Pago subscription tracking
- `plan_prices` — pricing matrix for Individual/Casal/Trisal plans

All tables use **Row Level Security (RLS)**. Partners share data via `group_id` on `profiles`.

## Development Commands

### Edge Functions
```bash
# Deploy individual functions
supabase functions deploy mp-create-subscription
supabase functions deploy mp-webhook --no-verify-jwt

# Set required secrets
supabase secrets set MP_ACCESS_TOKEN="..."
supabase secrets set APP_RETURN_URL="..."
```

### Database Migrations
```bash
# Apply a new migration to remote project
supabase db push

# Or use the Supabase MCP tool: mcp__Supabase__apply_migration
```

### Running Locally
Since the frontend is a static HTML file, just open `index.html` in a browser or serve it:
```bash
python3 -m http.server 8080
# then open http://localhost:8080
```

## Key Environment Secrets (not in repo)
- `MP_ACCESS_TOKEN` — Mercado Pago API token
- `APP_RETURN_URL` — redirect URL after checkout
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` — auto-injected by Supabase runtime

## Important Patterns

### Partner/Group Access
Users in the same group share cards, transactions, and wishes. The `group_id` on `profiles` is the join key. RLS policies use this to allow cross-user data access within a group.

### Admin Check
```sql
SELECT public.is_admin();  -- checks against hardcoded admin emails in the function
```

### Subscription Plans
Three tiers: Individual, Casal (2 users), Trisal (3 users). Plan prices stored in `plan_prices` table. Admins can share invite codes without an active subscription.

### Mercado Pago Flow
1. Frontend calls `mp-create-subscription` Edge Function (authenticated)
2. User completes checkout on Mercado Pago
3. Mercado Pago POSTs to `mp-webhook` Edge Function
4. Webhook updates `subscriptions` table and activates premium on `profiles`
