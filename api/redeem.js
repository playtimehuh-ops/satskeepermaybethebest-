const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');

const PRODUCT_ID = /^[A-Za-z0-9._-]{1,128}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MANUAL_BRANDS = { roblox: 'Roblox Gift Card', steam: 'Steam Wallet', playstation: 'PlayStation Store', xbox: 'Xbox Gift Card', google_play: 'Google Play', apple: 'Apple Gift Card' };
const COUNTRY_CURRENCY = { SA:'SAR', AE:'AED', EG:'EGP', GB:'GBP', US:'USD', CA:'CAD', AU:'AUD', NZ:'NZD', IN:'INR', PK:'PKR', BD:'BDT', PH:'PHP', ID:'IDR', MY:'MYR', SG:'SGD', TH:'THB', JP:'JPY', KR:'KRW', CN:'CNY', HK:'HKD', TW:'TWD', TR:'TRY', KW:'KWD', QA:'QAR', BH:'BHD', OM:'OMR', JO:'JOD', BR:'BRL', MX:'MXN', ZA:'ZAR', CH:'CHF', DE:'EUR', FR:'EUR', ES:'EUR', IT:'EUR', NL:'EUR', BE:'EUR', AT:'EUR', IE:'EUR', PT:'EUR', FI:'EUR', GR:'EUR' };
function isManualItem(productId, productName, currency, amount) {
  const match = /^manual_(roblox|steam|playstation|xbox|google_play|apple)_([A-Z]{2})$/.exec(String(productId || ''));
  if (!match || MANUAL_BRANDS[match[1]] !== productName || (COUNTRY_CURRENCY[match[2]] || 'USD') !== currency) return false;
  const values = currency === 'SAR' || currency === 'AED' ? [10,20,40]
    : currency === 'EGP' ? [100,250,500]
    : currency === 'GBP' ? [2,5,8]
    : currency === 'EUR' ? [2,5,9] : [2,5,10];
  return values.includes(amount);
}


async function sendAdminNotice(redemption, accountEmail) {
  const to = process.env.REDEMPTION_NOTIFY_EMAIL || 'playtimehuh@gmail.com';
  const { GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN, GMAIL_SENDER } = process.env;
  if (!GMAIL_CLIENT_ID || !GMAIL_CLIENT_SECRET || !GMAIL_REFRESH_TOKEN || !GMAIL_SENDER) {
    return { sent: false, reason: 'gmail_not_configured' };
  }
  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: GMAIL_CLIENT_ID, client_secret: GMAIL_CLIENT_SECRET,
      refresh_token: GMAIL_REFRESH_TOKEN, grant_type: 'refresh_token',
    }),
  });
  if (!tokenResp.ok) throw new Error('gmail_token_failed');
  const token = await tokenResp.json();
  const subject = 'GainDeep redemption request #' + redemption.id;
  const lines = [
    'A new manual payout request was submitted.',
    '',
    'Reference: #' + redemption.id,
    'Account email: ' + accountEmail,
    'Payout email: ' + redemption.beneficiary_email,
    'Reward: ' + redemption.product_name,
    'Amount: ' + redemption.reward_amount + ' ' + redemption.reward_currency,
    'Points spent: ' + redemption.points_spent,
    'Status: PENDING — manual review required',
    'Requested: ' + redemption.created_at,
  ];
  const enc = (s) => Buffer.from(s, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  const raw = [
    'To: ' + to, 'From: ' + GMAIL_SENDER, 'Subject: ' + subject,
    'MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64', '', enc(lines.join('\r\n')),
  ].join('\r\n');
  const mailResp = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token.access_token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ raw: Buffer.from(raw, 'utf8').toString('base64url') }),
  });
  if (!mailResp.ok) throw new Error('gmail_send_failed');
  return { sent: true };
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  const device_id = await requireSession(req, res);
  if (!device_id) return;
  const body = bodyOf(req);
  const product_id = body.product_id;
  const product_name = typeof body.product_name === 'string' ? body.product_name.trim() : '';
  const beneficiary_email = typeof body.beneficiary_email === 'string' ? body.beneficiary_email.trim().toLowerCase() : '';
  const reward_currency = typeof body.currency === 'string' ? body.currency.trim().toUpperCase() : '';
  const reward_amount = Number(body.value);
  if (!PRODUCT_ID.test(String(product_id || '')) || !product_name || product_name.length > 128 ||
      !EMAIL.test(beneficiary_email) || beneficiary_email.length > 254 ||
      !Number.isFinite(reward_amount) || reward_amount <= 0 ||\n      reward_amount > (config.hasCardValueCap(reward_currency) ? config.maxCardValue(reward_currency) : 10) ||
      !/^[A-Z]{3,12}$/.test(reward_currency) ||
      !isManualItem(product_id, product_name, reward_currency, reward_amount)) {
    return res.status(400).json({ error: 'bad_request' });
  }
  const { data: userResult, error: userError } = await supabase.auth.admin.getUserById(device_id);
  if (userError || !userResult || !userResult.user) return res.status(500).json({ error: 'account_lookup_failed' });
  const accountEmail = userResult.user.email || '';
  if (!accountEmail) return res.status(400).json({ error: 'account_email_missing' });

  const points = config.threshold_points;
  const { data: reserved, error: reserveErr } = await supabase.rpc('reserve_redemption', {
    p_device_id: device_id,
    p_points: points,
    p_product_id: product_id,
    p_product_name: product_name,
    p_reward_amount: reward_amount,
    p_reward_currency: reward_currency,
    p_beneficiary_email: beneficiary_email,
    p_user_limit: config.max_redemptions_per_user_day,
    p_global_limit: config.max_redemptions_global_day,
  });
  if (reserveErr || !reserved) return res.status(500).json({ error: 'db_error' });
  switch (reserved.status) {
    case 'ok': break;
    case 'insufficient_points':
      return res.status(402).json({ error: 'insufficient_points', available: Number(reserved.available || 0) });
    case 'frozen': return res.status(403).json({ error: 'account_frozen' });
    case 'limit_user': return res.status(429).json({ error: 'daily_limit' });
    case 'limit_global': return res.status(503).json({ error: 'store_busy' });
    default: return res.status(500).json({ error: 'db_error' });
  }
  const { data: row, error: rowError } = await supabase.from('redemptions')
    .select('id, points_spent, beneficiary_email, product_name, reward_amount, reward_currency, created_at')
    .eq('id', reserved.id).single();
  if (rowError || !row) return res.status(500).json({ error: 'redemption_saved_notification_lookup_failed', redemption_id: reserved.id });
  let notification = { sent: false, reason: 'gmail_not_configured' };
  try {
    notification = await sendAdminNotice(row, accountEmail);
    await supabase.from('redemptions').update({ notification_status: notification.sent ? 'sent' : 'pending' }).eq('id', row.id);
  } catch (_) {
    notification = { sent: false, reason: 'send_failed' };
    await supabase.from('redemptions').update({ notification_status: 'failed' }).eq('id', row.id);
  }
  return res.status(200).json({
    ok: true, status: 'pending', manual_payout: true, redemption_id: row.id,
    points_spent: Number(row.points_spent), notification_sent: notification.sent,
    message: 'Manual payout request submitted. Estimated processing time: 0–48 hours.',
  });
});
