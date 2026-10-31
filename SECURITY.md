# SatsKeeper security notes

## What protects the money
- **Atomic database logic.** Reports, awards, spends and refunds are Postgres functions with row locks (`supabase/schema.sql`). Double taps and parallel requests cannot double-spend or double-award.
- **Retry-safe reports.** Each report has an id; the same id is never counted twice, even if the phone retries.
- **Hard limits, enforced in SQL.** 20 s between reports, at most 2048 MB per report and 12.5 MB/s of elapsed time, 10 000 MB per user per 24 h.
- **24 h vesting.** New points cannot be spent for 24 h, which gives you time to freeze a cheater.
- **Redemption caps.** 1 per user per day, 20 per day for the whole app, invoice price ceiling, per-currency face-value caps.
- **Verify before pay.** The Bitrefill invoice is created unpaid, its price is checked, and only then paid. A failed or refused order refunds exactly once.
- **Accounts.** Confirmed e-mail required. Every call needs the app key plus a valid login token. The user id comes from the token, never from the request.
- **Lockdown.** Tables have RLS on with no policies; functions are callable only by the service role. Errors never include internal details.

## Honest limits
- A modified app can lie about bandwidth. The limits above cap how much a liar can earn; they cannot prove traffic. Watch `GET /api/admin?action=overview`.
- The app key inside the APK can be extracted. It is a speed bump, not a secret. Login tokens are the real gate.
- Keep your Bitrefill balance small. It is the final cap on any loss.

## Do this before real users
1. Supabase > Authentication: keep **Confirm email** ON, enable CAPTCHA and rate limits, set a minimum password length of 10.
2. Vercel > Firewall: add a rate-limit rule on `/api/*` (for example 60 requests per minute per IP).
3. Set `ADMIN_USER`, `ADMIN_PASS` (20+ chars) and `CRON_SECRET` (16+ chars) in Vercel.
4. Make a release key and add four GitHub secrets, so every build is signed with the same key:
   `keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias satskeeper`
   - Windows PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks")) | Set-Clipboard`
   - Mac/Linux: `base64 -w0 release.jks`
   - Secrets: `ANDROID_KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` (satskeeper), `KEY_PASSWORD`. Back the keystore up somewhere private.
5. Never put `SUPABASE_SERVICE_ROLE_KEY` in the app or in GitHub secrets for the app build.

## Admin (HTTP Basic auth)
- Overview: `curl -u USER:PASS "https://YOUR-APP.vercel.app/api/admin?action=overview"`
- Freeze a user: `curl -u USER:PASS -X POST -H "Content-Type: application/json" -d '{"device_id":"USER-UUID","frozen":true,"reason":"abuse"}' "https://YOUR-APP.vercel.app/api/admin?action=freeze"`
- Stuck orders: `action=stuck`. Re-check them: `action=reconcile` (also runs daily by cron). Refund one: POST `action=refund` with `{"redemption_id":123}`.

## Not done (future)
Play Integrity attestation, certificate pinning, device-level duplicate-account detection.
