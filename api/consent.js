const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const device_id = await requireSession(req, res);
  if (!device_id) return;

  const { opted_in } = bodyOf(req);
  if (typeof opted_in !== 'boolean') {
    return res.status(400).json({ error: 'bad_request' });
  }

  // Only opted_in is written, so a client can never touch balance or freeze state.
  const { error } = await supabase.from('devices').upsert({ device_id, opted_in }, { onConflict: 'device_id' });
  if (error) return res.status(500).json({ error: 'db_error' });
  return res.status(200).json({ ok: true, opted_in });
});
