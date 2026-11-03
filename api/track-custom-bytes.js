const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const config = require('./_lib/config');

const REQUEST_ID = /^[a-f0-9]{32}$/;

// Credit only server-recorded proxy traffic. The client never supplies trusted byte counts.
module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const body = bodyOf(req);
  const request_id = typeof body.request_id === 'string' ? body.request_id : '';
  if (!REQUEST_ID.test(request_id)) return res.status(400).json({ error: 'bad_request' });

  const { data: log, error: logError } = await supabase
    .from('proxy_logs')
    .select('request_id,device_id,bytes_used,credited')
    .eq('request_id', request_id)
    .eq('device_id', device_id)
    .maybeSingle();

  if (logError) return res.status(500).json({ error: 'db_error' });
  if (!log) return res.status(404).json({ error: 'proxy_log_not_found' });
  if (log.credited) return res.status(200).json({ ok: true, credited: false, already_credited: true, points_awarded: 0 });

  const points_per_mb = Number(config.points_per_mb);
  if (!Number.isFinite(points_per_mb) || points_per_mb < 0 || points_per_mb > 10) {
    return res.status(500).json({ error: 'invalid_reward_config' });
  }

  const { data, error } = await supabase.rpc('credit_proxy_log', {
    p_device_id: device_id,
    p_request_id: request_id,
    p_points_per_mb: points_per_mb,
  });
  if (error) return res.status(500).json({ error: 'credit_failed' });
  const result = Array.isArray(data) ? data[0] : data;
  if (!result || result.status === 'not_found') return res.status(404).json({ error: 'proxy_log_not_found' });
  if (result.status === 'wrong_device') return res.status(403).json({ error: 'forbidden' });
  return res.status(200).json({
    ok: true,
    credited: result.status === 'credited',
    already_credited: result.status === 'already_credited',
    bytes_used: Number(result.bytes_used || 0),
    points_awarded: Number(result.points_awarded || 0),
  });
});
