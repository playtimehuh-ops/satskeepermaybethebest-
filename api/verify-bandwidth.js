const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');

// The auditor is a second opinion. The hard limits (rate, per-report, per-day,
// elapsed-time plausibility) are enforced atomically in SQL by begin_report().
async function audit(report) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const resp = await fetch(config.nim_url, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + process.env.NVIDIA_API_KEY,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({
        model: config.nim_model,
        messages: [
          {
            role: 'system',
            content:
              'Auditor. Reply VALID or INVALID. You audit bandwidth-sharing telemetry from a ' +
              'mobile device. Reply INVALID if the numbers look fabricated, inconsistent with ' +
              'the recent history, or physically implausible for the elapsed time. ' +
              'Reply with exactly one word.',
          },
          { role: 'user', content: JSON.stringify(report) },
        ],
        temperature: 0,
        max_tokens: 32,
      }),
      signal: controller.signal,
    });
    if (!resp.ok) throw new Error('nim_http_' + resp.status);
    const json = await resp.json();
    const text = String(
      (json && json.choices && json.choices[0] && json.choices[0].message &&
        json.choices[0].message.content) || ''
    );
    const word = (text.toUpperCase().match(/[A-Z]+/) || [''])[0];
    if (word === 'VALID') return true;
    if (word === 'INVALID') return false;
    throw new Error('nim_unparseable');
  } finally {
    clearTimeout(timer);
  }
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const body = bodyOf(req);
  const mb = typeof body.mb_shared === 'number' ? Math.round(body.mb_shared * 1000) / 1000 : NaN;
  const report_id = typeof body.report_id === 'string' ? body.report_id : '';
  if (
    !Number.isFinite(mb) ||
    mb <= 0 ||
    mb > config.max_mb_per_report ||
    !/^[A-Za-z0-9_-]{16,64}$/.test(report_id)
  ) {
    return res.status(400).json({ error: 'bad_request' });
  }

  const { data: begun, error: beginErr } = await supabase.rpc('begin_report', {
    p_device_id: device_id,
    p_report_id: report_id,
    p_mb: mb,
    p_min_interval_s: config.min_report_interval_s,
    p_max_per_report: config.max_mb_per_report,
    p_max_per_s: config.max_mb_per_second,
    p_max_per_day: config.max_mb_per_day,
  });
  if (beginErr || !begun) return res.status(500).json({ error: 'db_error' });

  switch (begun.status) {
    case 'ok':
      break;
    case 'existing':
      // Same report_id seen before: answer from the stored result unless still pending.
      if (begun.log_status !== 'pending') {
        return res.status(200).json({
          ok: true,
          valid: begun.log_status === 'awarded',
          duplicate: true,
          points_awarded: Number(begun.points_awarded || 0),
        });
      }
      break;
    case 'not_opted_in':
      return res.status(403).json({ error: 'not_opted_in' });
    case 'frozen':
      return res.status(403).json({ error: 'account_frozen' });
    case 'too_frequent':
      return res.status(429).json({ error: 'too_frequent' });
    case 'daily_cap':
      return res.status(200).json({ ok: true, valid: false, reason: 'daily_cap', points_awarded: 0 });
    case 'implausible':
      return res.status(200).json({ ok: true, valid: false, reason: 'implausible', points_awarded: 0 });
    default:
      return res.status(400).json({ error: 'bad_request' });
  }

  // Ask the AI auditor. If it is down the report stays 'pending' and the app retries.
  const reportedMb = Number(begun.mb);
  const elapsed = Math.max(Number(begun.elapsed_s) || 60, 1);
  let valid;
  try {
    valid = await audit({
      mb_shared: reportedMb,
      seconds_since_last_report: Math.round(elapsed),
      average_mbps: Number(((reportedMb * 8) / elapsed).toFixed(3)),
      max_plausible_mb: Number(Number(begun.max_mb).toFixed(2)),
      recent_reports_mb: Array.isArray(begun.recent) ? begun.recent.map(Number) : [],
    });
  } catch (_) {
    return res.status(502).json({ error: 'auditor_unavailable' });
  }

  const { data: settled, error: settleErr } = await supabase.rpc('settle_report', {
    p_log_id: begun.log_id,
    p_valid: valid,
    p_points_per_mb: config.points_per_mb,
    p_vest_hours: config.vest_hours,
  });
  if (settleErr || !settled) return res.status(500).json({ error: 'db_error' });

  const awarded = settled.status === 'awarded';
  return res.status(200).json({
    ok: true,
    valid: awarded,
    reason: awarded ? undefined : 'rejected',
    mb_shared: reportedMb,
    points_awarded: Number(settled.points_awarded || 0),
  });
});
