# GainDeep security and launch gates

This file describes the current implementation honestly. A successful GitHub Actions build is not a security audit or proof that the live app works end to end.

## Controls currently present

- API account routes require the app key and a valid Supabase user session; the user ID is derived from the verified token.
- Confirmed email is required by the API session helper.
- The Supabase service-role key is referenced only by server-side API code and must never be added to Flutter, static website files, or public GitHub files.
- Points, wheel, membership, and redemption balance changes use server-side database functions, including row locks and idempotency checks in the relevant SQL functions.
- Reward redemption is currently a manual-review request, not an automatically paid gift-card order.
- The public launch status endpoint returns a fixed, non-sensitive readiness summary. It does not expose secrets or account information.
- Vercel applies restrictive browser security headers and disables caching for responses.

## Known blockers — do not call this production-ready

1. `api/verify-bandwidth.js` rejects client-reported measurements with `409 untrusted_measurement_source`. That prevents those reports from earning points. Do not remove this guard or trust client-supplied byte counts to make the dashboard look functional.
2. The Android traffic counters do not independently prove that bytes belong exclusively to an authorized provider process.
3. The custom proxy gateway is not approved for public commercial traffic resale. Buyer-to-device authorization, buyer billing/quotas, provider authorization, abuse handling, and a live end-to-end service test are not complete. The proxy schema and policies must not be assumed live merely because a SQL file exists in the repository.
4. The gateway's shared API-key model is not a complete buyer identity, quota, or billing system. Do not distribute a shared key to buyers.
5. Membership and wheel database functions have been tested transactionally, but full production app-to-API flows still need real-device verification.
6. Gift-card catalogue visibility is not a promise of local stock. Current manual redemption requests require human review and fulfilment.
7. A prior Android workflow configuration permits debug signing when no release keystore is configured. A debug-signed APK is for testing only and is not a Play Store release artifact.
8. Independent security review, Play Integrity/device-abuse protections, a verified account deletion workflow, and an exact data-retention schedule are not complete.
9. Supabase security-advisor items such as leaked-password protection and RLS-without-policies warnings still need review. Service-role-only tables with no client policies may be intentional, but the configuration must be checked against the live project.
10. Legal operator identity, public support/privacy contact, governing law, and provider contracts have not been finalized.

## Required before public launch

- An eligible adult legal operator must own and approve the service, provider accounts, legal notices, payment/reward arrangements, and production credentials. Do not bypass provider age or operator requirements.
- Keep Supabase email confirmation enabled; configure strong password rules, CAPTCHA, and authentication rate limits.
- Configure Vercel rate limits for all sensitive API routes, including authentication-adjacent and redemption endpoints.
- Store `APP_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `ADMIN_USER`, `ADMIN_PASS`, `CRON_SECRET`, and provider credentials only in the correct server-side secret stores. Never commit their values.
- Use a permanent Android release keystore. Verify all four signing secrets: `ANDROID_KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD`. Back up the keystore securely. Do not distribute debug-signed builds.
- Test account creation, email confirmation, sign-in, sign-out, consent on/off, points ledger, membership purchase, wheel cooldown, reward request, manual fulfilment, and account deletion on real devices.
- Verify every provider contract, allowed use, regional eligibility, user disclosure, and adult-operator requirement before enabling network sharing.
- Complete an independent security/privacy review and publish finalized Terms and Privacy Policy with the operator identity, contact, jurisdiction, retention schedule, and user-rights process.

## Secret handling

- Never put `SUPABASE_SERVICE_ROLE_KEY`, provider secrets, admin passwords, refresh tokens, private keys, or release keystores in Flutter code, the launch website, or committed files.
- The Flutter app's app key is extractable from the APK. Treat it as a public client identifier, not a secret; user authentication and server-side authorization must provide the real access control.
- Do not log bearer tokens, passwords, gift-card codes, or private keys.
- Rotate any credential that may have been exposed.

## Admin operations

The admin API uses HTTP Basic authentication and must be protected with a long unique password, rate limiting, and restricted access. Do not place admin credentials in browser JavaScript or share them with users. Reconciliation and manual refund actions must be reviewed before execution.

## Security contact

A public security-reporting email has not been selected yet. Add a monitored contact before public launch; do not invent or publish an unmonitored address.
