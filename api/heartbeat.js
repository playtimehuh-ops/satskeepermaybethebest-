const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap } = require('./_lib/http');

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const { data, error } = await supabase.rpc('touch_device', { p_device_id: device_id });
  if (error) return res.status(500).json({ error: 'db_error' });
  return res.status(200).json({ ok: true, streak: Number(data) || 1 });
});
