function envInt(name, fallback, min, max) {
  const n = Number.parseInt(process.env[name], 10);
  return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

module.exports = {
  payout_pct: 0.2,
  total_points_per_mb: 12,
  user_share: 0.8,
  points_per_mb: 9.6,
  threshold_points: 10000,
  points_per_usd: 10000,

  // Bandwidth report limits (enforced in SQL).
  max_mb_per_report: 2048,
  max_mb_per_second: 12.5,
  max_mb_per_day: envInt('MAX_MB_PER_DAY', 10000, 100, 100000),
  min_report_interval_s: 20,

  // TESTING ONLY: immediate availability. Restore the 24-hour vest before launch.
  vest_hours: 0,

  // Redemption frequency safeguards remain enabled.
  max_redemptions_per_user_day: envInt('MAX_REDEMPTIONS_PER_USER_DAY', 1, 1, 20),
  max_redemptions_global_day: envInt('MAX_REDEMPTIONS_PER_DAY', 20, 1, 1000),

  nim_url: 'https://integrate.api.nvidia.com/v1/chat/completions',
  nim_model: process.env.NIM_MODEL || 'moonshotai/kimi-k3-instruct',

  bitrefill_base: (process.env.BITREFILL_BASE_URL || 'https://api.bitrefill.com/v2').replace(/\\/+$/, ''),

  pointsForUsd(usd) {
    const amount = Number(usd);
    if (!Number.isFinite(amount) || amount <= 0) return null;
    return Math.ceil(amount * this.points_per_usd);
  },

  maxCardValue() {
    return Infinity;
  },
};
