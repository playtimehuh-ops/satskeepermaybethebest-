const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');

const PLAN_COSTS = { free: 0, plus: 2500, pro: 7500, elite: 15000 };

module.exports = wrap(async (req, res) => {
  const deviceId = await requireSession(req, res);
  if (!deviceId) return;

  if (req.method === 'GET') {
    const [membershipQ, spinQ] = await Promise.all([
      supabase.from('device_memberships').select('plan, starts_at, expires_at').eq('device_id', deviceId).maybeSingle(),
      supabase.from('wheel_spins').select('created_at, points_awarded').eq('device_id', deviceId).order('created_at', { ascending: false }).limit(1),
    ]);
    if (membershipQ.error || spinQ.error) return res.status(500).json({ error: 'db_error' });
    const m = membershipQ.data;
    const active = Boolean(m && m.plan !== 'free' && m.expires_at && new Date(m.expires_at).getTime() > Date.now());
    const plan = active ? m.plan : 'free';
    const lastSpin = spinQ.data && spinQ.data[0] ? spinQ.data[0].created_at : null;
    const nextSpin = lastSpin ? new Date(new Date(lastSpin).getTime() + 24 * 60 * 60 * 1000).toISOString() : null;
    let history = [];
    if (active) {
      const days = plan === 'plus' ? 30 : plan === 'pro' ? 90 : 365;
      const since = new Date(Date.now() - days * 86400000).toISOString();
      const historyQ = await supabase.from('bandwidth_logs')
        .select('created_at, mb_shared, points_awarded, status')
        .eq('device_id', deviceId).gte('created_at', since)
        .order('created_at', { ascending: false }).limit(100);
      if (historyQ.error) return res.status(500).json({ error: 'db_error' });
      history = historyQ.data || [];
    }
    return res.status(200).json({
      plan, plan_cost: PLAN_COSTS[plan], expires_at: active ? m.expires_at : null,
      wheel_last_spin_at: lastSpin, wheel_next_spin_at: nextSpin,
      wheel_available: !nextSpin || new Date(nextSpin).getTime() <= Date.now(),
      wheel_prizes: [0, 5, 10, 15, 25, 50], history_days: active ? (plan === 'plus' ? 30 : plan === 'pro' ? 90 : 365) : 0,
      history,
    });
  }

  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  const body = bodyOf(req);
  if (body.action === 'spin') {
    const { data, error } = await supabase.rpc('spin_gain_deep_wheel', { p_device_id: deviceId });
    if (error) return res.status(500).json({ error: 'db_error' });
    const result = typeof data === 'string' ? JSON.parse(data) : data;
    if (result.status === 'cooldown') return res.status(429).json({ error: 'wheel_cooldown', next_spin_at: result.next_spin_at });
    if (result.status === 'account_frozen') return res.status(403).json({ error: 'account_frozen' });
    if (result.status !== 'awarded') return res.status(400).json({ error: 'bad_request' });
    return res.status(200).json(result);
  }
  if (body.action === 'purchase_plan') {
    if (!['plus', 'pro', 'elite'].includes(body.plan)) return res.status(400).json({ error: 'invalid_plan' });
    const { data, error } = await supabase.rpc('purchase_gain_deep_plan', { p_device_id: deviceId, p_plan: body.plan });
    if (error) return res.status(500).json({ error: 'db_error' });
    const result = typeof data === 'string' ? JSON.parse(data) : data;
    if (result.status === 'insufficient_points') return res.status(409).json({ error: 'insufficient_points', required: result.required, available: result.available });
    if (result.status === 'account_frozen') return res.status(403).json({ error: 'account_frozen' });
    if (result.status === 'already_active') return res.status(409).json({ error: 'plan_already_active' });
    if (result.status === 'downgrade_not_allowed') return res.status(409).json({ error: 'downgrade_not_allowed' });
    if (result.status !== 'purchased') return res.status(400).json({ error: 'invalid_plan' });
    return res.status(200).json(result);
  }
  return res.status(400).json({ error: 'invalid_action' });
});
