const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');
const { bitrefill, normalizeProduct, resolveSelection } = require('./_lib/bitrefill');
const { FAILED, sleep, unwrap, findCode, refund, advance } = require('./_lib/payout');

const POLL_BUDGET_MS = 40000;

// Returns true if the invoice price is known to exceed our hard ceiling.
function overPriceCeiling(invoice) {
  const pay = invoice && invoice.payment;
  if (!pay) return true;
  const currency = String(pay.currency || '').toUpperCase();
  const rawPrice = pay.price;
  const price = Number(rawPrice);
  // Fail closed when the invoice price/currency cannot be checked.
  if (rawPrice === null || rawPrice === undefined || rawPrice === '' || !Number.isFinite(price) || price <= 0 || !currency || !config.hasCardValueCap(currency)) return true;
  // Apply the product's own currency cap, not only the USD ceiling.
  const currencyCap = config.maxCardValue(currency);
  const cap = currency === 'USD' ? Math.min(currencyCap, config.max_invoice_usd) : currencyCap;
  return price > cap;
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const body = bodyOf(req);
  const product_id = body.product_id;
  if (typeof product_id !== 'string' || !/^[A-Za-z0-9._-]{1,128}$/.test(product_id)) {
    return res.status(400).json({ error: 'bad_request' });
  }
  const pkg = body.package_id;
  if (pkg !== undefined && pkg !== null && !(typeof pkg === 'string' || typeof pkg === 'number')) {
    return res.status(400).json({ error: 'bad_request' });
  }
  if (body.value !== undefined && body.value !== null && !Number.isFinite(Number(body.value))) {
    return res.status(400).json({ error: 'bad_request' });
  }

  // Validate against the live catalog BEFORE spending any points.
  let product;
  try {
    product = normalizeProduct(unwrap(await bitrefill('/products/' + encodeURIComponent(product_id))));
  } catch (err) {
    return res.status(err.http && err.status === 404 ? 404 : 502).json({ error: 'catalog_unavailable' });
  }
  if (!product) return res.status(409).json({ error: 'product_unavailable' });

  const selection = resolveSelection(product, pkg, body.value);
  if (!selection) return res.status(400).json({ error: 'invalid_selection' });

  // 1. Spend points and create the redemption row in ONE database transaction.
  const { data: reserved, error: reserveErr } = await supabase.rpc('reserve_redemption', {
    p_device_id: device_id,
    p_points: config.threshold_points,
    p_product_id: product.id,
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
  const redemptionId = reserved.id;

  // 2. Create the invoice WITHOUT paying, check the price, then pay.
  const line = { product_id: product.id, quantity: 1 };
  if (selection.package_id) line.package_id = selection.package_id;
  else line.value = selection.value;

  let invoice;
  try {
    invoice = unwrap(
      await bitrefill('/invoices', {
        method: 'POST',
        body: { products: [line], payment_method: 'balance', auto_pay: false },
        timeoutMs: 25000,
      })
    );
  } catch (err) {
    if (err.http && err.status >= 400 && err.status < 500) {
      await refund(redemptionId, 'invoice_rejected');
      return res.status(502).json({ error: 'payout_failed', refunded: true });
    }
    // Network failure or 5xx: the invoice may exist. Keep points spent, flag for review.
    await advance(redemptionId, 'processing');
    return res.status(502).json({ error: 'payout_unknown', redemption_id: redemptionId });
  }

  const invoiceId = invoice.id ? String(invoice.id) : null;
  if (!invoiceId) {
    await refund(redemptionId, 'no_invoice_id');
    return res.status(502).json({ error: 'payout_failed', refunded: true });
  }
  await advance(redemptionId, 'processing', { invoiceId });

  if (overPriceCeiling(invoice)) {
    await refund(redemptionId, 'price_over_ceiling');
    return res.status(502).json({ error: 'payout_failed', refunded: true });
  }

  if (invoice.status !== 'complete' && !FAILED.has(invoice.status)) {
    try {
      const paid = unwrap(
        await bitrefill('/invoices/' + encodeURIComponent(invoiceId) + '/pay', { method: 'POST', timeoutMs: 25000 })
      );
      if (paid && paid.status) invoice = paid;
    } catch (err) {
      if (err.http && err.status >= 400 && err.status < 500) {
        await refund(redemptionId, 'pay_rejected');
        return res.status(502).json({ error: 'payout_failed', refunded: true });
      }
      return res.status(202).json({ ok: true, status: 'processing', redemption_id: redemptionId });
    }
  }

  // 3. Wait for delivery, then store and return the code.
  const deadline = Date.now() + POLL_BUDGET_MS;
  try {
    while (invoice.status !== 'complete' && !FAILED.has(invoice.status) && Date.now() < deadline) {
      await sleep(2000);
      invoice = unwrap(await bitrefill('/invoices/' + encodeURIComponent(invoiceId)));
    }
  } catch (_) {
    // fall through: reported as processing below
  }

  if (FAILED.has(invoice.status)) {
    await refund(redemptionId, 'invoice_' + invoice.status);
    return res.status(502).json({ error: 'payout_failed', refunded: true, status: invoice.status });
  }

  const code = invoice.status === 'complete' ? await findCode(invoice) : null;
  if (code) {
    await advance(redemptionId, 'completed', { code });
    return res.status(200).json({ ok: true, status: 'completed', code, redemption_id: redemptionId });
  }

  return res.status(202).json({ ok: true, status: 'processing', redemption_id: redemptionId, invoice_id: invoiceId });
});
