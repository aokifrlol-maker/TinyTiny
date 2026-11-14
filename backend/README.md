# TinyTiny License + Encrypted Share Worker (Cloudflare Free Tier)

This Cloudflare Worker runs:
- Your **Telegram Bot Admin Panel** (`/gen`, `/info`, `/list`, `/extend`, `/unbind`, `/revoke`)
- **License Key Activation & Verification** (`/v1/activate`, `/v1/verify`) with per-device binding and timer starting on first activation
- **Zero-Knowledge Encrypted Cloud Profile Backup** (`/v1/backup`, `/v1/backup/get`) so Likes, Follows, and taste survive passcode recovery & IPA reinstalls (server sees only AES-256-GCM ciphertext)
- **Hidden End-to-End Encrypted Share Drops** (`/v1/share`, `/v1/blob`) backed silently by your 2 TB Seedr WebDAV vault (`https://dav.seedr.cc/tt_drops/`) so users never see Seedr credentials, UI, or plaintext files

> **Never commit `TELEGRAM_BOT_TOKEN`, `ADMIN_USER_ID`, `WEBHOOK_SECRET`, `SEEDR_EMAIL`, or `SEEDR_PASSWORD` to git.** Always store them via `wrangler secret put`.

## 1. Quick Deploy (5 minutes)

```bash
npm install -g wrangler
wrangler login

cd backend
wrangler kv namespace create LICENSES
# Copy the returned "id" into backend/wrangler.toml

wrangler secret put TELEGRAM_BOT_TOKEN
wrangler secret put ADMIN_USER_ID      # Send /myid to your bot first if you don't know it
wrangler secret put WEBHOOK_SECRET     # Any random secret string, e.g. tinytiny_wh_9f3c...
wrangler secret put SEEDR_EMAIL        # Hidden backend encrypted storage account email
wrangler secret put SEEDR_PASSWORD     # Hidden backend encrypted storage account password

wrangler deploy
```

## 2. Register Telegram Bot Webhook

Replace `<WORKER_URL>`, `<WEBHOOK_SECRET>`, and `<BOT_TOKEN>` and run once:

```bash
curl "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://<WORKER_URL>/telegram/<WEBHOOK_SECRET>"
```

Then open Telegram and send `/myid` or `/gen 30d` to your bot.

## 3. Connect App Default Server URL (Optional)

In `TinyTiny/LicenseManager.swift`, `defaultServerURL` is preconfigured to `https://tinytiny-license.aokifrlol.workers.dev` (and users can still customize it in-app under **Server Settings** on the License Key gate).
