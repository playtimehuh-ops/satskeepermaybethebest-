# GainDeep launch site

This folder contains a same-origin, static pre-launch website:
- `index.html`: public project overview and live feature-status panel.
- `legal.html`: pre-launch Terms of Service and Privacy Policy drafts.
- `site.css` and `site.js`: local assets only; no third-party scripts or analytics.

The site reads `GET /api/public-status`. That endpoint is informational only and does not query private tables, disclose environment variables, authenticate users, relay traffic, or verify device activity.

## Important launch restrictions

The legal pages are drafts. The legal operator, support contact, governing law, exact retention periods, and provider contracts still need confirmation. Do not describe these documents as final or accept them as binding until an eligible adult operator and qualified reviewer approve them.

The public status API deliberately marks points earning, network sharing, and buyer traffic as not cleared for public launch. It must not be used as proof of commercial traffic delivery or earnings.
