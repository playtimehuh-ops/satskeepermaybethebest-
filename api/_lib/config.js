function envInt(name, fallback, min, max) {
  const n = Number.parseInt(process.env[name], 10);
  return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

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

  // Redemption frequency safeguards remain enabled.
  max_redemptions_per_user_day: envInt('MAX_REDEMPTIONS_PER_USER_DAY', 1, 1, 20),
  max_redemptions_global_day: envInt('MAX_REDEMPTIONS_PER_DAY', 20, 1, 1000),

  nim_url: 'https://integrate.api.nvidia.com/v1/chat/completions',
  nim_model: process.env.NIM_MODEL || 'moonshotai/kimi-k3-instruct',

  bitrefill_base: (process.env.BITREFILL_BASE_URL || 'https://api.bitrefill.com/v2').replace(/\\/+$/, ''),

  // No face-value cap: show valid Bitrefill packages and ranges in every supported country.
  maxCardValue() {
    return Infinity;
  },
};
