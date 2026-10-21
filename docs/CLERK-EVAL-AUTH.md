# Clerk auth for live Meztli evals

Live Promptfoo runs hit the production chat API (`https://miraai-backend1.onrender.com/api/chat` by default). Render rejects the local eval API key; every request needs a **Clerk session JWT** from the **live** Clerk app (`sk_live` / production sessions). Local/`sk_test` tokens fail with `jwk-kid-mismatch`.

Billing, connectors, and plan quota are **per active workspace (org)**. Switching which Clerk user (and therefore which workspace) you authenticate as is how you avoid Discord hangs, free-plan `PLAN_LIMIT`, or missing connectors.

Never commit `.env`, JWTs, Clerk secrets, or API keys.

---

## Required `.env` variables (names only)

| Variable | Role |
|----------|------|
| `MEZTLI_EVAL_CLERK_SECRET` | Live Clerk Backend API secret (`sk_live_…`) for `npm run refresh-jwt` |
| `MEZTLI_EVAL_CLERK_USER_ID` | Clerk user to mint a token for (`user_…`) |
| `MEZTLI_EVAL_CLERK_SESSION_ID` | Optional pin to a specific session (`sess_…`); omit to auto-pick an active session for the user |
| `MEZTLI_EVAL_CLERK_JWT` | Session JWT sent as `Authorization: Bearer …` on chat requests |
| `MEZTLI_EVAL_CLERK_JWT_TTL` | Optional token TTL in seconds (default `3600`) |
| `MEZTLI_EVAL_CHAT_URL` | Optional chat URL override (default: live Render `/api/chat`) |

Also needed for generation / grading: `ANTHROPIC_API_KEY`.

Copy from `.env.example` → `.env` and fill values locally.

---

## Why switch users / workspaces?

- **Connectors differ per workspace.** A Discord-connected org that rate-limits or hangs will stall evals that touch Discord. Another user’s workspace may have healthier connectors (or none — which fails differently).
- **Plan quota is per workspace.** Free plans allow ~15 assistant queries/month. Prior eval runs can exhaust quota → `PLAN_LIMIT` / HTTP 402. Elite (or higher) must show on the **active** org via `GET /api/me` → `subscription.planId`.
- **Wrong active workspace** = JWT is valid but tools/quota look “broken.” Confirm `/api/me` and `/api/connectors` after switching.

### Known accounts from prior runs (emails only — no secrets)

| Account | Notes |
|---------|--------|
| `dasarivirajmahipaul@gmail.com` | Recent `.env` target (`user_3KvWHFAEnuh5tNbbkNQJfe0MRkV`) |
| `sudheerbez9@gmail.com` | Earlier successful probe (mezli workspace); free plan can be exhausted |
| `yaswanth.wuyyuru@letmeapply.com` | Rasuverse workspace — Discord probes hung |

Use these as orientation only; always re-verify plan + connectors before a long eval.

---

## How to switch Clerk user (seamless future runs)

1. **Sign in** at [https://www.meztli.ai/assistant](https://www.meztli.ai/assistant) as the target user so Clerk has an **active** browser session.
2. In `.env`, set `MEZTLI_EVAL_CLERK_USER_ID=user_…` for that user.
3. **Clear or update** `MEZTLI_EVAL_CLERK_SESSION_ID` if you had pinned another user’s session (stale `sess_…` will mint the wrong token or fail). Prefer leaving it unset so refresh auto-picks an active session for the new user.
4. Refresh the JWT:
   ```bash
   npm run refresh-jwt
   # or: bash scripts/refresh-clerk-jwt.sh
   ```
5. **Verify** identity and workspace before spending quota on a full suite:
   ```bash
   npm run preflight
   ```
   Or manually (with the JWT in `.env`):
   ```bash
   # Active user / plan / org
   curl -sS -H "Authorization: Bearer $MEZTLI_EVAL_CLERK_JWT" \
     https://miraai-backend1.onrender.com/api/me | jq '{email, subscription, activeOrganization}'

   # Connectors present for this workspace
   curl -sS -H "Authorization: Bearer $MEZTLI_EVAL_CLERK_JWT" \
     https://miraai-backend1.onrender.com/api/connectors | jq .

   # Discord hang check (should return promptly, not hang)
   curl -sS -m 30 -H "Authorization: Bearer $MEZTLI_EVAL_CLERK_JWT" \
     https://miraai-backend1.onrender.com/api/connectors/discord/guilds | jq .
   ```

Manual JWT paste (no secret): DevTools → Network → any `/api/proxy` request → copy `Authorization: Bearer` token only into `MEZTLI_EVAL_CLERK_JWT`.

---

## Pre-eval checklist

- [ ] Browser session is signed in on meztli.ai for the **same** Clerk user as `MEZTLI_EVAL_CLERK_USER_ID`
- [ ] JWT refreshed recently (`npm run refresh-jwt`) and not expired
- [ ] `GET /api/me` shows expected user + `subscription.planId` with remaining quota (Elite if you need heavy runs)
- [ ] Discord is not hanging: `GET /api/connectors/discord/guilds` returns within ~30s
- [ ] Connectors needed by the suite exist on this workspace
- [ ] `npm run preflight` passes (or you intentionally set `MEZTLI_EVAL_SKIP_PROBE=1`)

---

## Known pitfalls

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| Probe / Discord call hangs | Discord rate-limit or bad guild state on that workspace | Switch user/workspace; or skip Discord-heavy cases; use `MEZTLI_EVAL_SKIP_PROBE=1` only if you accept blind runs |
| HTTP 402 / `PLAN_LIMIT` | Free plan quota exhausted (≈15 queries/month per workspace) | Switch to a workspace with Elite/quota, wait for reset, or use local opt-in (`MEZTLI_EVAL_USE_LOCAL=1`) |
| Gemini / model `402` fallback noise | Upstream billing or plan gating mid-turn | Check workspace plan; re-run after quota/plan fix |
| Auth OK but wrong tools/data | JWT user ≠ intended active org | Confirm `/api/me` and switch org in the UI, then refresh JWT |
| `jwk-kid-mismatch` / 401 | `sk_test` secret or local JWT against live Render | Use live `sk_live` + production session JWT only |
| Free plan exhausted mid-suite | Prior evals burned the 15 queries | Switch user/workspace before continuing |

---

## Commands

```bash
# Mint / refresh JWT into .env
npm run refresh-jwt
# bash scripts/refresh-clerk-jwt.sh

# Auth + chat smoke (uses quota for a short probe)
npm run preflight

# Eval (manual / auto / both — see README)
npm run eval:manual
npm run eval

# Skip chat probe (timeouts / Discord hang / conserve quota) — use sparingly
MEZTLI_EVAL_SKIP_PROBE=1 npm run eval:manual
```

Local backend bypass (not for Render): `MEZTLI_EVAL_USE_LOCAL=1` + `MEZTLI_EVAL_API_KEY` + localhost `MEZTLI_EVAL_CHAT_URL`. See README.
