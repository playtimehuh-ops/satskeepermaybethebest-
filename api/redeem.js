const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');
const { bitrefill, normalizeProduct, resolveSelection } = require('./_lib/bitrefill');
const { FAILED, sleep, unwrap, findCode, refund, advance } = require('./_lib/payout');

const POLL_BUDGET_MS = 40000;
const FX_URL = 'https://open.er-api.com/v6/latest/USD';
const FX_TIMEOUT_MS = 8000;
const FX_MAX_CACHE_MS = 24 * 60 * 60 * 1000;

// Reuse the provider's daily rate table across warm serverless invocations.
let fxCache = null;
let fxRequest = null;

async function getUsdRates() {
  if (fxCache && Date.now() < fxCache.expiresAt) return fxCache.rates;
  if (fxRequest) return fxRequest;

  fxRequest = (async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FX_TIMEOUT_MS);
    try {
      const response = await fetch(FX_URL, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error('fx_http_' + response.status);

      const data = await response.json();
      if (!data || data.result !== 'success' || data.base_code !== 'USD' ||
          !data.rates || typeof data.rates !== 'object') {
        throw new Error('fx_invalid_response');
      }

      const nextUpdate = Number(data.time_next_update_unix) * 1000;
      const fallbackExpiry = Date.now() + 60 * 60 * 1000;
      const expiresAt = Number.isFinite(nextUpdate) && nextUpdate > Date.now()
        ? Math.min(nextUpdate, Date.now() + FX_MAX_CACHE_MS)
        : fallbackExpiry;

      fxCache = { rates: data.rates, expiresAt };
      return data.rates;
    } finally {
      clearTimeout(timer);
      fxRequest = null;
    }
  })();

  return fxRequest;
}

async function invoiceUsdPrice(payment) {
  const currency = String((payment && payment.currency) || '').trim().toUpperCase();
  const localPrice = Number(payment && payment.price);
  if (!/^[A-Z]{3}$/.test(currency) || !Number.isFinite(localPrice) || localPrice <= 0) {
    throw new Error('invalid_invoice_pricing');
  }
  if (currency === 'USD') return localPrice;

  const rates = await getUsdRates();
  const localPerUsd = Number(rates[currency]);
  if (!Number.isFinite(localPerUsd) || localPerUsd <= 0) {
    throw new Error('unsupported_invoice_currency');
  }

  // Rates are quoted as local-currency units per 1 USD.
  const usdPrice = localPrice / localPerUsd;
  if (!Number.isFinite(usdPrice) || usdPrice <= 0) {
    throw new Error('invalid_converted_invoice_price');
  }
  return usdPrice;
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

  // Validate the selection against Bitrefill before creating an invoice.
  let product;
  try {
    product = normalizeProduct(unwrap(await bitrefill('/products/' + encodeURIComponent(product_id))));
  } catch (err) {
    console.error('[redeem] product lookup failed', {
      productId: product_id,
      status: Number.isFinite(err && err.status) ? err.status : null,
      message: String((err && err.message) || 'unknown_error').slice(0, 240),
    });
    return res.status(err.http && err.status === 404 ? 404 : 502).json({ error: 'catalog_unavailable' });
  }
  if (!product) return res.status(409).json({ error: 'product_unavailable' });

  const selection = resolveSelection(product, pkg, body.value);
  if (!selection) return res.status(400).json({ error: 'invalid_selection' });

  // Create an unpaid invoice first; its payment currency and price are authoritative.
  const line = { product_id: product.id, quantity: 1 };
  if (selection.package_id) line.package_id = selection.package_id;
  else line.value = selection.value;

  let invoice;
  try {
    invoice = unwrap(await bitrefill('/invoices', {
      method: 'POST',
      body: { products: [line], payment_method: 'balance', auto_pay: false },
      timeoutMs: 25000,
    }));
  } catch (err) {
    console.error('[redeem] Bitrefill invoice creation failed', {
      productId: product.id,
      productCountry: product.country,
      status: Number.isFinite(err && err.status) ? err.status : null,
      providerCode: String((err && err.providerCode) || '').slice(0, 100),
      message: String((err && err.message) || 'unknown_error').slice(0, 240),
    });
    return res.status(502).json({ error: 'invoice_unavailable' });
  }

  const invoiceId = invoice && invoice.id ? String(invoice.id) : null;
  if (!invoiceId) {
    return res.status(502).json({ error: 'invalid_invoice' });
  }

  let usdPrice;
  try {
    usdPrice = await invoiceUsdPrice(invoice.payment);
  } catch (err) {
    // The invoice is still unpaid and no points have been reserved.
    const unavailable = err.message === 'unsupported_invoice_currency' ||
      err.message === 'invalid_invoice_pricing';
    return res.status(unavailable ? 502 : 503).json({
      error: unavailable ? err.message : 'exchange_rates_unavailable',
    });
  }

  const pointsRequired = config.pointsForUsd(usdPrice);
  if (!Number.isSafeInteger(pointsRequired) || pointsRequired <= 0) {
    return res.status(502).json({ error: 'invalid_invoice_pricing' });
  }

  // reserve_redemption locks the device row and reserves the exact converted cost atomically.
  const { data: reserved, error: reserveErr } = await supabase.rpc('reserve_redemption', {
    p_device_id: device_id,
    p_points: pointsRequired,
    p_product_id: product.id,
    p_user_limit: config.max_redemptions_per_user_day,
    p_global_limit: config.max_redemptions_global_day,
  });
  if (reserveErr || !reserved) return res.status(500).json({ error: 'db_error' });
  switch (reserved.status) {
    case 'ok':
      break;
    case 'insufficient_points':
      return res.status(402).json({
        error: 'insufficient_points',
        available: Number(reserved.available || 0),
        required: pointsRequired,
      });
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

  await advance(redemptionId, 'processing', { invoiceId });

  // Pay only after points have been reserved successfully.
  if (invoice.status !== 'complete' && !FAILED.has(invoice.status)) {
    try {
      const paid = unwrap(await bitrefill(
        '/invoices/' + encodeURIComponent(invoiceId) + '/pay',
        { method: 'POST', timeoutMs: 25000 }
      ));
      if (paid && paid.status) invoice = paid;
    } catch (err) {
      if (err.http && err.status >= 400 && err.status < 500) {
        await refund(redemptionId, 'pay_rejected');
        return res.status(502).json({ error: 'payout_failed', refunded: true });
      }
      return res.status(202).json({ ok: true, status: 'processing', redemption_id: redemptionId });
    }
  }

  // Wait for delivery, then store and return the code.
  const deadline = Date.now() + POLL_BUDGET_MS;
  try {
    while (invoice.status !== 'complete' && !FAILED.has(invoice.status) && Date.now() < deadline) {
      await sleep(2000);
      invoice = unwrap(await bitrefill('/invoices/' + encodeURIComponent(invoiceId)));
    }
  } catch (_) {
    // Report as processing; the reconciliation job can check the invoice later.
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

  return res.status(202).json({
    ok: true,
    status: 'processing',
    redemption_id: redemptionId,
    invoice_id: invoiceId,
  });
});
