const API_BASE = 'https://api.cryptorefills.com';

function getHeaders(req) {
  const partnerId = process.env.CRYPTOREFILLS_PARTNER_ID;
  if (!partnerId) {
    const err = new Error('cryptorefills_not_configured');
    err.status = 503;
    throw err;
  }

  const forwarded = req && req.headers && req.headers['x-forwarded-for'];
  const ip = typeof forwarded === 'string' ? forwarded.split(',')[0].trim() : '';
  const userAgent = String((req && req.headers && req.headers['user-agent']) || 'SatsKeeper/1.0');

  if (!ip) {
    const err = new Error('end_user_ip_unavailable');
    err.status = 400;
    throw err;
  }

  return {
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'X-Cr-Application': partnerId,
    'X-Cr-Version': process.env.CRYPTOREFILLS_APP_VERSION || '1.0.0',
    'X-Forwarded-For': ip,
    'User-Agent': userAgent,
  };
}

async function request(req, path, options) {
  const response = await fetch(API_BASE + path, {
    ...options,
    headers: { ...getHeaders(req), ...((options && options.headers) || {}) },
    signal: AbortSignal.timeout(15000),
  });

  let data = null;
  try {
    data = await response.json();
  } catch (_) {}

  if (!response.ok) {
    const error = new Error('cryptorefills_http_' + response.status);
    error.status = response.status;
    error.data = data;
    throw error;
  }
  return data;
}

async function validateOrder(req, payload) {
  // This endpoint only validates. It never creates /v5/orders or requests payment.
  return request(req, '/v5/orders/validations', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
}

module.exports = { validateOrder };
