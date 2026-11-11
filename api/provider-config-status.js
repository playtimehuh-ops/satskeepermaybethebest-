// Admin-only configuration diagnostic. Never returns secret values and never
// starts a provider, routes traffic, or enables earning.
const { requireAdmin } = require('./_lib/auth');

module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');

  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  if (!requireAdmin(req, res)) return;

  return res.status(200).json({
    provider: 'MystNodes',
    api_key_configured: Boolean(
      typeof process.env.MYSTNODES_API_KEY === 'string' &&
      process.env.MYSTNODES_API_KEY.trim().length > 0
    ),
    activation: 'disabled_pending_adult_operator_and_provider_review',
    traffic_routing: 'disabled',
    points_earning: 'disabled',
    secret_exposed: false
  });
};
