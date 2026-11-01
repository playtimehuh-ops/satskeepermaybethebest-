const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap } = require('./_lib/http');
const config = require('./_lib/config');

module.exports = wrap(async (req, res) => {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  const deviceId = await requireSession(req, res);
  if (!deviceId) return;

  const [deviceQ, availQ, cardsQ] = await Promise.all([
    supabase
      .from('devices')
      .select('points_balance, streak, opted_in, last_active_at, frozen')
      .eq('device_id', deviceId)
      .maybeSingle(),
    supabase.rpc('available_points', { p_device_id: deviceId }),
    supabase
      .from('redemptions')
      .select('id, status, product_id, code, created_at')
      .eq('device_id', deviceId)
      .order('id', { ascending: false })
      .limit(10),
  ]);
  if (deviceQ.error || availQ.error || cardsQ.error) {
    return res.status(500).json({ error: 'db_error' });
  }
  const data = deviceQ.data;
  const points = data ? Number(data.points_balance) : 0;
  const available = data && availQ.data !== null ? Math.min(points, Number(availQ.data)) : 0;

  return res.status(200).json({
    device_id: deviceId,
    points,
    available,
    threshold: config.threshold_points,
    streak: data ? data.streak : 0,
    opted_in: data ? data.opted_in : false,
    frozen: data ? data.frozen : false,
    last_active_at: data ? data.last_active_at : null,
    redemptions: cardsQ.data || [],
  });
});
