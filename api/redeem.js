const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');
const { refund } = require('./_lib/payout');

const POINTS_PER_USD = 10000;
const COUNTRY_CODE = /^[A-Z]{2}$/;
const PRODUCT_ID = /^[A-Za-z0-9._-]{1,128}$/;

// Safe integration dry-run: no Cryptorefills order is created and no crypto is sent.
// A real x402 signer/payment adapter must be added by the authorized service operator.
module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const body = bodyOf(req);
  const product_id = body.product_id;
  const country_code = typeof body.country_code === 'string' ? body.country_code.toUpperCase() : '';
  const amount = Number(body.amount);

  if (
    typeof product_id !== 'string' || !PRODUCT_ID.test(product_id) ||
    !COUNTRY_CODE.test(country_code) ||
    body.amount === null || body.amount === undefined || body.amount === '' ||
    !Number.isFinite(amount) || amount <= 0 || amount > config.max_invoice_usd
  ) {
    return res.status(400).json({ error: 'bad_request' });
  }

  if (process.env.CRYPTOREFILLS_MOCK_MODE !== 'true') {
    return res.status(503).json({
      error: 'payment_adapter_not_configured',
      message: 'Cryptorefills x402 payment is not enabled. No order was created and no points were deducted.',
    });
  }

  const points = Math.ceil(amount * POINTS_PER_USD);
  const { data: reserved, error: reserveErr } = await supabase.rpc('reserve_redemption', {
    p_device_id: device_id,
    p_points: points,
    p_product_id: product_id,
    p_user_limit: config.max_redemptions_per_user_day,
    p_global_limit: config.max_redemptions_global_day,
  });

  if (reserveErr || !reserved) return res.status(500).json({ error: 'db_error' });
  switch (reserved.status) {
    case 'ok':
      break;
    case 'insufficient_points':
      return res.status(402).json({ error: 'insufficient_points', available: Number(reserved.available || 0) });
    case 'frozen':
      return res.status(403).json({ error: 'account_frozen' });
    case 'limit_user':
      return res.status(429).json({ error: 'daily_limit' });
    case 'limit_global':
      return res.status(503).json({ error: 'store_busy' });
    default:
      return res.status(500).json({ error: 'db_error' });
  }

  // Exercise the same atomic reserve/refund SQL path without creating a purchase.
  // The refund is immediate, so dry-runs never consume user points.
  try {
    await refund(reserved.id, 'cryptorefills_mock_dry_run');
  } catch (_) {
    return res.status(500).json({
      error: 'dry_run_refund_failed',
      redemption_id: reserved.id,
      message: 'Do not retry automatically; this reservation needs reconciliation.',
    });
  }

  return res.status(200).json({
    ok: true,
    test_mode: true,
    status: 'dry_run_refunded',
    provider: 'Cryptorefills',
    product_id,
    country_code,
    amount_usd: amount,
    points_required: points,
    points_refunded: true,
    code: null,
    message: 'Validation and atomic reserve/refund passed. No Cryptorefills order or payment was made.',
  });
});
