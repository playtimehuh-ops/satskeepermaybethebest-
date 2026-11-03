const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const { validateOrder } = require('./_lib/cryptorefills');

const COUNTRY_CODE = /^[A-Z]{2}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_TEXT = 120;

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  if (!(await requireSession(req, res))) return;

  const body = bodyOf(req);
  const brand_name = typeof body.brand_name === 'string' ? body.brand_name.trim() : '';
  const country_code = typeof body.country_code === 'string' ? body.country_code.toUpperCase() : '';
  const denomination = typeof body.denomination === 'string' ? body.denomination.trim() : '';
  const beneficiary_email = typeof body.beneficiary_email === 'string' ? body.beneficiary_email.trim() : '';

  if (
    !brand_name || brand_name.length > MAX_TEXT ||
    !COUNTRY_CODE.test(country_code) ||
    !denomination || denomination.length > MAX_TEXT ||
    !EMAIL.test(beneficiary_email) || beneficiary_email.length > 254
  ) {
    return res.status(400).json({ error: 'bad_request' });
  }

  const payload = {
    email: beneficiary_email,
    payment: {
      type: 'via',
      payment_via: 'USER_WALLET',
      coin: 'USDC',
    },
    deliveries: [{
      beneficiary_account: beneficiary_email,
      brand_name,
      country_code,
      denomination,
    }],
    lang: 'en',
  };

  try {
    const result = await validateOrder(req, payload);
    const problems = Array.isArray(result && result.problems) ? result.problems : [];
    return res.status(200).json({
      ok: problems.length === 0,
      provider: 'Cryptorefills',
      validation_only: true,
      valid: problems.length === 0,
      problems,
      message: problems.length === 0
        ? 'Cryptorefills validation passed. No order or payment was created.'
        : 'Cryptorefills returned validation issues. No order or payment was created.',
    });
  } catch (err) {
    const status = Number(err && err.status);
    if (status === 503 && err.message === 'cryptorefills_not_configured') {
      return res.status(503).json({ error: 'provider_not_configured' });
    }
    if (status === 400 && err.message === 'end_user_ip_unavailable') {
      return res.status(400).json({ error: 'request_ip_unavailable' });
    }
    return res.status(status >= 400 && status < 500 ? status : 502).json({
      error: 'provider_validation_failed',
      provider_status: status || null,
    });
  }
});
