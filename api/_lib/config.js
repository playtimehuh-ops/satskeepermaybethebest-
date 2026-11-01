const DEFAULT_CAPS = { USD: 10, GBP: 8, EUR: 9, SAR: 40, EGP: 500, AED: 40 };

function loadCaps() {
  try {
    if (process.env.MAX_CARD_VALUE_JSON) {
      return Object.assign({}, DEFAULT_CAPS, JSON.parse(process.env.MAX_CARD_VALUE_JSON));
    }
  } catch (_) {
    // fall through to defaults
  }
  return DEFAULT_CAPS;
}

function envInt(name, fallback, min, max) {
  const n = Number.parseInt(process.env[name], 10);
  return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

const caps = loadCaps();

module.exports = {
  payout_pct: 0.2,
  points_per_mb: 0.1,
  threshold_points: 5000,

  // Bandwidth report limits (enforced in SQL, not just here).
  max_mb_per_report: 2048,
  max_mb_per_second: 12.5,
  max_mb_per_day: envInt('MAX_MB_PER_DAY', 10000, 100, 100000),
  min_report_interval_s: 20,
  vest_hours: envInt('VEST_HOURS', 24, 0, 720),

  // Redemption limits.
  max_redemptions_per_user_day: envInt('MAX_REDEMPTIONS_PER_USER_DAY', 1, 1, 20),
  max_redemptions_global_day: envInt('MAX_REDEMPTIONS_PER_DAY', 20, 1, 1000),
  max_invoice_usd: envInt('MAX_INVOICE_USD', 12, 1, 500),

  nim_url: 'https://integrate.api.nvidia.com/v1/chat/completions',
  nim_model: process.env.NIM_MODEL || 'moonshotai/kimi-k3-instruct',

  bitrefill_base: (process.env.BITREFILL_BASE_URL || 'https://api.bitrefill.com/v2').replace(/\/+$/, ''),

  // Max face value of one card (in the product's own currency). Redemption
  // always costs threshold_points, so this bounds the payout per redemption.
  maxCardValue(currency) {
    const v = caps[String(currency || '').toUpperCase()];
    return Number.isFinite(v) ? v : 10;
  },
};
