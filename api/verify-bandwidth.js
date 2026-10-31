const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');

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

  // Deterministic server-side checks only. No AI/NVIDIA verification call.
  // begin_report() atomically enforces elapsed-time, rate, per-report and daily limits.
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

  // The database has accepted the report under all deterministic limits.
  // Total = MB * 12; user share = floor(total * 0.8). SQL applies floor()
  // atomically when it updates bandwidth_logs.points_awarded and devices.points_balance.
  const { data: settled, error: settleErr } = await supabase.rpc('settle_report', {
    p_log_id: begun.log_id,
    p_valid: true,
    p_points_per_mb: config.total_points_per_mb * config.user_share,
    p_vest_hours: config.vest_hours,
  });
  if (settleErr || !settled) return res.status(500).json({ error: 'db_error' });

  const awarded = settled.status === 'awarded';
  return res.status(200).json({
    ok: true,
    valid: awarded,
    reason: awarded ? undefined : 'rejected',
    mb_shared: Number(begun.mb),
    points_awarded: Number(settled.points_awarded || 0),
  });
});
