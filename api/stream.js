const supabase = require('./_lib/supabase');
const { requireSession } = require('./_lib/auth');
const { wrap, bodyOf } = require('./_lib/http');
const clean = (value, max) => typeof value === 'string' ? value.trim().slice(0, max) : '';

module.exports = wrap(async (req, res) => {
  const userId = await requireSession(req, res);
  if (!userId) return;
  if (req.method === 'GET') {
    const { data, error } = await supabase.from('stream_sessions')
      .select('id, title, creator_name, status, created_at')
      .eq('status', 'live').eq('moderation_status', 'approved')
      .order('created_at', { ascending: false }).limit(50);
    if (error) {
      console.error('stream_list_failed', error.code);
      return res.status(503).json({ error: 'streams_unavailable' });
    }
    return res.status(200).json({ streams: data || [], video_ready: Boolean(process.env.STREAM_PROVIDER_URL && process.env.STREAM_PROVIDER_SECRET) });
  }
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  const body = bodyOf(req);

  if (body.action === 'apply') {
    const displayName = clean(body.display_name, 32);
    const reason = clean(body.reason, 500);
    if (displayName.length < 3 || reason.length < 20) return res.status(400).json({ error: 'invalid_application' });
    const { data: existing, error: lookupError } = await supabase.from('stream_creator_applications')
      .select('id, status').eq('user_id', userId).in('status', ['pending', 'approved']).limit(1);
    if (lookupError) return res.status(503).json({ error: 'streams_unavailable' });
    if (existing && existing.length && existing[0].status !== 'rejected') {
      return res.status(409).json({ error: 'application_already_exists', status: existing[0].status });
    }
    const { error } = existing && existing.length
      ? await supabase.from('stream_creator_applications').update({
          display_name: displayName, reason, status: 'pending', reviewed_at: null, adult_verified_at: null,
        }).eq('id', existing[0].id)
      : await supabase.from('stream_creator_applications').insert({
          user_id: userId, display_name: displayName, reason, status: 'pending',
        });
    if (error) {
      console.error('creator_application_failed', error.code);
      return res.status(503).json({ error: 'streams_unavailable' });
    }
    return res.status(201).json({ status: 'pending_review' });
  }

  if (body.action === 'donate') {
    const streamId = clean(body.stream_id, 64);
    const points = Number(body.points);
    if (!/^[0-9a-f-]{36}$/i.test(streamId) || !Number.isSafeInteger(points) || points < 10 || points > 10000 || points % 10 !== 0)
      return res.status(400).json({ error: 'invalid_donation' });
    const { data, error } = await supabase.rpc('donate_stream_points', {
      p_donor_id: userId, p_stream_id: streamId, p_points: points,
    });
    if (error) {
      console.error('stream_donation_failed', error.code, error.message);
      return res.status(503).json({ error: 'donation_unavailable' });
    }
    const result = typeof data === 'string' ? JSON.parse(data) : data;
    if (result.status === 'insufficient_points') return res.status(409).json({ error: 'insufficient_points' });
    if (result.status === 'not_live') return res.status(409).json({ error: 'stream_not_live' });
    if (result.status === 'self_donation') return res.status(400).json({ error: 'self_donation_not_allowed' });
    if (result.status === 'creator_unavailable') return res.status(409).json({ error: 'creator_unavailable' });
    if (result.status !== 'donated') return res.status(400).json({ error: 'invalid_donation' });
    return res.status(200).json(result);
  }

  if (body.action === 'report') {
    const streamId = clean(body.stream_id, 64);
    const reason = clean(body.reason, 120);
    if (!/^[0-9a-f-]{36}$/i.test(streamId) || reason.length < 3) return res.status(400).json({ error: 'invalid_report' });
    const { error } = await supabase.from('stream_reports').insert({ stream_id: streamId, reporter_id: userId, reason });
    if (error) {
      console.error('stream_report_failed', error.code);
      return res.status(503).json({ error: 'report_unavailable' });
    }
    return res.status(201).json({ status: 'received' });
  }
  return res.status(400).json({ error: 'invalid_action' });
});
