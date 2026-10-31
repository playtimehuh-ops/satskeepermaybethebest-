const supabase = require('./_lib/supabase');
const { requireAdmin, isCron, validDeviceId } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const { refund, reconcile } = require('./_lib/payout');

// One endpoint, picked by ?action=
//   GET  overview                      abuse dashboard
//   GET  stuck                         redemptions waiting on delivery
//   GET  reconcile                     re-check stuck redemptions (also used by Vercel Cron)
//   POST freeze   {device_id, frozen, reason}
//   POST refund   {redemption_id}
module.exports = wrap(async (req, res) => {
  const action = String((req.query && req.query.action) || '');

  // Cron may only run reconcile; everything else needs the admin password.
  const cronOk = action === 'reconcile' && isCron(req);
  if (!cronOk) {
    await new Promise((r) => setTimeout(r, 300)); // makes password guessing slow
    if (!requireAdmin(req, res)) return;
  }

  if (action === 'overview' && req.method === 'GET') {
    const { data, error } = await supabase.rpc('admin_overview');
    if (error) return res.status(500).json({ error: 'db_error' });
    return res.status(200).json(data);
  }

  if (action === 'stuck' && req.method === 'GET') {
    const { data, error } = await supabase
      .from('redemptions')
      .select('id, device_id, status, product_id, invoice_id, created_at, updated_at')
      .in('status', ['pending', 'processing'])
      .order('id', { ascending: true })
      .limit(100);
    if (error) return res.status(500).json({ error: 'db_error' });
    return res.status(200).json({ redemptions: data });
  }

  if (action === 'reconcile' && (req.method === 'GET' || req.method === 'POST')) {
    return res.status(200).json({ results: await reconcile(20) });
  }

  if (action === 'freeze' && req.method === 'POST') {
    const { device_id, frozen, reason } = bodyOf(req);
    if (!validDeviceId(device_id) || typeof frozen !== 'boolean') {
      return res.status(400).json({ error: 'bad_request' });
    }
    const { data, error } = await supabase
      .from('devices')
      .update({ frozen, frozen_reason: frozen ? String(reason || '').slice(0, 200) : null })
      .eq('device_id', device_id)
      .select('device_id');
    if (error) return res.status(500).json({ error: 'db_error' });
    return res.status(200).json({ ok: true, updated: (data || []).length });
  }

  if (action === 'refund' && req.method === 'POST') {
    const id = Number(bodyOf(req).redemption_id);
    if (!Number.isInteger(id) || id <= 0) return res.status(400).json({ error: 'bad_request' });
    const done = await refund(id, 'admin');
    return res.status(200).json({ ok: true, refunded: done });
  }

  return res.status(400).json({ error: 'unknown_action' });
});
