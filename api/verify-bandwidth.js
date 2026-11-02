const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');

// One source of truth for the configured reward rate.
// Reports are rule-checked; they are not independently verified by an AI auditor.
const POINTS_PER_MB = config.points_per_mb;

// 100% deterministic checks. The same limits are also enforced atomically in SQL by
// begin_report(); this second pass only looks at the numbers the database returned.
function validate(report) {
  const { mb, elapsed, maxMb } = report;
  if (!Number.isFinite(mb) || mb <= 0) return 'bad_amount';
  if (!Number.isFinite(elapsed) || elapsed < 1) return 'bad_time';
  if (Number.isFinite(maxMb) && mb > maxMb + 1e-9) return 'over_limit';
  const mbPerSecond = mb / elapsed;
  if (mbPerSecond > config.max_mb_per_second) return 'too_fast';
  return null;
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const body = bodyOf(req);
  const requestedMb = typeof body.mb_shared === 'number' ? body.mb_shared : NaN;
  const requestedReportId = typeof body.report_id === 'string' ? body.report_id : '';
  if (!Number.isFinite(requestedMb) || requestedMb <= 0 ||
      requestedMb > config.max_mb_per_report ||
      !/^[A-Za-z0-9_-]{16,64}$/.test(requestedReportId)) {
    return res.status(400).json({ error: 'bad_request' });
  }
  // Client-reported process counters cannot prove Mysterium traffic. Never award points
  // from them; the proxy gateway records bytes measured server-side after successful relay.
  return res.status(409).json({ error: 'untrusted_measurement_source', valid: false, points_awarded: 0 });

  /* Legacy report validation retained temporarily for migration comparison only.
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

  // Step 1 (database, atomic): rate limit, per-report cap, speed vs. elapsed time,
  // daily cap, and a retry-safe record of the report.
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
      // Same report_id seen before: answer from the stored result unless it never settled.
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

  // Step 2 (deterministic): speed and time checks on what the database recorded.
  const reportedMb = Number(begun.mb);
  const problem = validate({
    mb: reportedMb,
    elapsed: Number(begun.elapsed_s),
    maxMb: Number(begun.max_mb),
  });

  // Step 3 (database, atomic): credit the points instantly, or reject the report.
  const { data: settled, error: settleErr } = await supabase.rpc('settle_report', {
    p_log_id: begun.log_id,
    p_valid: problem === null,
    p_points_per_mb: POINTS_PER_MB,
    p_vest_hours: config.vest_hours,
  });
  if (settleErr || !settled) return res.status(500).json({ error: 'db_error' });

  const awarded = settled.status === 'awarded';
  return res.status(200).json({
    ok: true,
    valid: awarded,
    reason: awarded ? undefined : problem || 'rejected',
    mb_shared: reportedMb,
    points_awarded: Number(settled.points_awarded || 0),
    gross_revenue_usd: Number(settled.gross_revenue_usd || 0),
    business_revenue_usd: Number(settled.business_revenue_usd || 0),
  });
  */
});
